#Requires -Version 7.4
# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [ValidateSet('Init','Prepare','StartServer','Pair','Start','Stop','Status','SaveCredential','EnableStartup','DisableStartup','CreateShortcut')]
    [string]$Action = 'Status',
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw '此入口需要 Windows 和 PowerShell 7.4 或更高版本。' }
$RepoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$EnvFile = [IO.Path]::GetFullPath($EnvFile)
if (-not (Test-Path -LiteralPath $EnvFile)) { throw '先将 .env.example 复制为 .env，再修改配置。' }
$AllowedKeys = @('COMPOSE_PROJECT_NAME','DATA_DIR','LIBRARY_DIR','NEXTCLOUD_CLIENT','NEXTCLOUD_USER','OPENLIST_USER','CLIENT_REMOTE_PATH','SERVER_PORT','OPENLIST_PORT','CODEC_PORT','TZ')
$Settings = @{}
foreach ($line in [IO.File]::ReadAllLines($EnvFile)) {
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $parts = $line.Split('=',2)
    if ($parts.Count -ne 2 -or $parts[0] -notin $AllowedKeys) { throw '配置文件含有未知字段。' }
    $value = $parts[1].Trim()
    if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) { $value = $value.Substring(1,$value.Length-2) }
    if ($Settings.ContainsKey($parts[0])) { throw '配置文件含有重复字段。' }
    $Settings[$parts[0]] = $value
}
foreach ($key in $AllowedKeys) { if (-not $Settings.ContainsKey($key) -or -not $Settings[$key]) { throw ('缺少配置字段：'+$key) } }
$Project = $Settings.COMPOSE_PROJECT_NAME
if ($Project -cnotmatch '^[a-z][a-z0-9_-]{1,31}$') { throw '项目名必须使用 2 至 32 个小写字母、数字、下划线或短横线。' }
foreach ($key in @('NEXTCLOUD_USER','OPENLIST_USER')) { if ($Settings[$key] -cnotmatch '^[A-Za-z0-9._-]+$') { throw ('账号名只支持字母、数字、点、下划线和短横线：'+$key) } }
$ports = foreach ($key in @('SERVER_PORT','OPENLIST_PORT','CODEC_PORT')) {
    $port = 0
    if (-not [int]::TryParse($Settings[$key],[ref]$port) -or $port -lt 1024 -or $port -gt 65535) { throw ('端口必须在 1024 至 65535 之间：'+$key) }
    $port
}
if (@($ports | Select-Object -Unique).Count -ne 3) { throw '三个本机端口必须不同。' }
function Resolve-SettingPath([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Value))
}
$DataRoot = Resolve-SettingPath $Settings.DATA_DIR
$Library = Resolve-SettingPath $Settings.LIBRARY_DIR
$Client = Resolve-SettingPath $Settings.NEXTCLOUD_CLIENT
$ClientConfig = Join-Path $DataRoot 'client'
$ClientProfilePattern = '(?:^|\s)--confdir(?:=|\s+)(?:"'+[regex]::Escape($ClientConfig)+'"|'+[regex]::Escape($ClientConfig)+'(?=\s|$))'
$Marker = Join-Path $DataRoot 'instance.json'
$CredentialFile = Join-Path $DataRoot 'secrets\local-account.xml'
$BaseUrl = 'http://127.0.0.1:'+$Settings.SERVER_PORT
$RemotePath = $Settings.CLIENT_REMOTE_PATH.TrimEnd('/')
if (-not $RemotePath.StartsWith('/') -or -not $RemotePath.Trim('/') -or $RemotePath.Contains('\') -or @($RemotePath.Split('/') | Where-Object { $_ -in @('.','..') }).Count) { throw 'CLIENT_REMOTE_PATH 必须是安全的绝对远端目录。' }
foreach ($path in @($DataRoot,$Library)) {
    if ($path.TrimEnd('\') -eq [IO.Path]::GetPathRoot($path).TrimEnd('\') -or $path -eq $RepoRoot -or $path.StartsWith($RepoRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '运行目录和文件库必须位于仓库目录之外，且不能是磁盘根目录。' }
}
if ($DataRoot -eq $Library -or $Library.StartsWith($DataRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $DataRoot.StartsWith($Library+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '运行目录与文件库不能互相包含。' }
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'BaiduDriveLocal-'+$Project

function Write-LibraryLog([string]$Message) {
    $directory = Join-Path $DataRoot 'logs'
    if (-not (Test-Path -LiteralPath $directory)) { return }
    $path = Join-Path $directory 'startup.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) { Move-Item -LiteralPath $path -Destination ($path+'.1') -Force }
    Add-Content -LiteralPath $path -Value ((Get-Date).ToString('o')+' '+$Message) -Encoding utf8
}
function Assert-Instance {
    if (-not (Test-Path -LiteralPath $Marker)) { throw '运行目录尚未初始化。先执行 Init。' }
    $instance = Get-Content -LiteralPath $Marker -Raw | ConvertFrom-Json
    if ($instance.project -cne $Project -or $instance.data_root -ne $DataRoot -or $instance.user -cne $Settings.NEXTCLOUD_USER -or [int]$instance.port -ne [int]$Settings.SERVER_PORT) { throw '运行目录属于不同的配置。不要复用或重置该目录。' }
}
function Invoke-Compose([string[]]$Arguments) {
    $docker = (Get-Command docker -ErrorAction Stop).Source
    $previous = @{}
    try {
        foreach ($key in $Settings.Keys) { $previous[$key] = [Environment]::GetEnvironmentVariable($key,'Process'); [Environment]::SetEnvironmentVariable($key,$Settings[$key],'Process') }
        $output = & $docker compose --project-directory $RepoRoot --env-file $EnvFile -f (Join-Path $RepoRoot 'compose.yaml') -p $Project @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('Docker 操作失败。请检查 Docker Desktop、本地镜像和运行目录。退出码：'+$LASTEXITCODE) }
        return ($output -join [Environment]::NewLine)
    } finally {
        foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key,$previous[$key],'Process') }
    }
}
function Start-Docker {
    $docker = (Get-Command docker -ErrorAction Stop).Source
    $null = & $docker info --format '{{.ServerVersion}}' 2>&1
    if ($LASTEXITCODE -eq 0) { return }
    $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path -LiteralPath $desktop)) { throw '请先安装并启动 Docker Desktop。' }
    Start-Process -FilePath $desktop -WindowStyle Hidden
    for ($attempt=0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Seconds 3
        $null = & $docker info --format '{{.ServerVersion}}' 2>&1
        if ($LASTEXITCODE -eq 0) { return }
    }
    throw 'Docker Desktop 尚未就绪。请查看其运行状态。'
}
function Initialize-Instance {
    if (Test-Path -LiteralPath $Marker) { Assert-Instance; return }
    if ((Test-Path -LiteralPath $DataRoot) -and @(Get-ChildItem -LiteralPath $DataRoot -Force).Count) { throw '运行目录非空且缺少实例记录。工具不会自动接管该目录。' }
    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
    $acl = Get-Acl -LiteralPath $DataRoot
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sidText in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $DataRoot -AclObject $acl
    foreach ($name in @('secrets','logs','logs\client','client','database','openlist','empty-codec','nextcloud\config','nextcloud\data','nextcloud\data\tmp','nextcloud\custom_apps')) { New-Item -ItemType Directory -Path (Join-Path $DataRoot $name) -Force | Out-Null }
    foreach ($name in @('database-password.txt','database-root-password.txt','nextcloud-admin-password.txt')) {
        $bytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        [IO.File]::WriteAllText((Join-Path $DataRoot ('secrets\'+$name)),[Convert]::ToBase64String($bytes)+"`n",[Text.UTF8Encoding]::new($false))
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'config\nextcloud.local.config.php') -Destination (Join-Path $DataRoot 'nextcloud\config\zzzz-local-library.config.php')
    $password = [IO.File]::ReadAllText((Join-Path $DataRoot 'secrets\nextcloud-admin-password.txt')).Trim()
    $credential = [pscredential]::new($Settings.NEXTCLOUD_USER,(ConvertTo-SecureString $password -AsPlainText -Force))
    $credential | Export-Clixml -LiteralPath $CredentialFile
    [ordered]@{version=1;project=$Project;data_root=$DataRoot;user=$Settings.NEXTCLOUD_USER;port=[int]$Settings.SERVER_PORT} | ConvertTo-Json | Set-Content -LiteralPath $Marker -Encoding utf8
    Write-LibraryLog 'Initialized a new private runtime directory.'
}
function Start-Server {
    Assert-Instance
    Start-Docker
    $null = Invoke-Compose -Arguments @('up','-d','--pull','never','--no-build')
    $ready = $false
    for ($attempt=0; $attempt -lt 60; $attempt++) {
        try { $status = Invoke-RestMethod ($BaseUrl+'/status.php') -TimeoutSec 3; if ($status.installed -and -not $status.maintenance) { $ready=$true; break } } catch {}
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw '本地服务尚未就绪。请查看容器日志。' }
    $apps = Invoke-Compose -Arguments @('exec','-T','-u','www-data','nextcloud','php','occ','app:list','--output=json') | ConvertFrom-Json -AsHashtable
    $disable = @('updatenotification','nextcloud_announcements','survey_client') | Where-Object { $apps.enabled.ContainsKey($_) }
    if ($disable.Count) { $null = Invoke-Compose -Arguments (@('exec','-T','-u','www-data','nextcloud','php','occ','app:disable')+$disable) }
    Write-LibraryLog 'Local server ready; no image pull or build was requested.'
}
function Read-Ini([string]$Path) {
    $result=@{}; $section=''
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\[([^\]]+)\]$') { $section=$Matches[1]; $result[$section]=@{} }
        elseif ($section -and $line.Contains('=')) { $parts=$line.Split('=',2); $result[$section][$parts[0]]=$parts[1] }
    }
    return $result
}
function Get-ManagedClients {
    @(Get-CimInstance Win32_Process -Filter "Name='nextcloud.exe'" | Where-Object { $_.ExecutablePath -eq $Client -and $_.CommandLine -and $_.CommandLine -match $ClientProfilePattern })
}
function Assert-LocalProfile {
    $profile = Read-Ini (Join-Path $ClientConfig 'nextcloud.cfg')
    if (-not $profile.ContainsKey('Accounts')) { throw '客户端尚未配对。先执行 Pair，并连接本地服务。' }
    $accounts=$profile.Accounts
    $keys=@($accounts.Keys | Where-Object { $_ -match '^\d+\\url$' })
    if ($keys.Count -ne 1) { throw '专用配置必须只包含一个本地账号。' }
    $prefix=$keys[0].Substring(0,$keys[0].Length-3)
    $uri=[uri]$accounts[$keys[0]]
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.Port -ne [int]$Settings.SERVER_PORT -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw '客户端账号没有指向本地入口。工具不会打开登录网页。' }
    if ($accounts[$prefix+'webflow_user'] -cne $Settings.NEXTCLOUD_USER) { throw '客户端账号与本地账号不一致。' }
    $folders=@($accounts.Keys | Where-Object { $_.StartsWith($prefix) -and $_.EndsWith('\localPath',[StringComparison]::OrdinalIgnoreCase) -and $_ -like '*\FoldersWithPlaceholders\*' })
    if ($folders.Count -ne 1) { throw '专用配置必须只包含一个虚拟文件库。' }
    $folder=$folders[0].Substring(0,$folders[0].Length-9)
    if ($accounts[$folders[0]].Replace('\\','\').TrimEnd('\') -ne $Library.TrimEnd('\') -or $accounts[$folder+'targetPath'].TrimEnd('/') -cne $RemotePath -or $accounts[$folder+'virtualFilesMode'] -ne 'wincfapi') { throw '文件库路径或虚拟文件模式不符合配置。' }
}
function Assert-LocalAccess {
    $credential = Import-Clixml -LiteralPath $CredentialFile
    if ($credential.UserName -cne $Settings.NEXTCLOUD_USER) { throw '保存的本地凭据不属于配置中的账号。' }
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credential.UserName+':'+$credential.GetNetworkCredential().Password))
    $path=(@($RemotePath.Trim('/').Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    $uri=$BaseUrl+'/remote.php/dav/files/'+[uri]::EscapeDataString($credential.UserName)+'/'+$path
    $response=Invoke-WebRequest $uri -Method PROPFIND -Headers @{Authorization='Basic '+$encoded;Depth='0'} -Body '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>' -TimeoutSec 20 -SkipHttpErrorCheck
    if ([int]$response.StatusCode -ne 207) { throw ('本地文件库验证失败。HTTP 状态码：'+[int]$response.StatusCode) }
}
function Retire-EmptyDefaultClient {
    $foreign=@(Get-CimInstance Win32_Process -Filter "Name='nextcloud.exe'" | Where-Object { $_.ExecutablePath -eq $Client -and $_.CommandLine -and $_.CommandLine -notmatch $ClientProfilePattern })
    $defaultPath=Join-Path $env:APPDATA 'Nextcloud\nextcloud.cfg'
    $default=Read-Ini $defaultPath
    if ($default.ContainsKey('Accounts') -and @($default.Accounts.Keys | Where-Object { $_ -ne 'version' }).Count) {
        if ($foreign.Count) { throw '默认客户端已有账号。请先自行退出该实例；工具保留其配置。' }
        return
    }
    foreach ($process in $foreign) {
        $command=$process.CommandLine.Replace('"','').Trim()
        if ($command -notin @($Client,($Client+' --background'))) { throw '存在其他客户端启动参数。请先自行退出该实例。' }
    }
    foreach ($process in $foreign) { Stop-Process -Id $process.ProcessId -Force; Wait-Process -Id $process.ProcessId -Timeout 15 -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $defaultPath) {
        $section=''
        $lines=foreach ($line in [IO.File]::ReadAllLines($defaultPath)) {
            if ($line.StartsWith('[')) { $section=$line }
            if ($section -eq '[General]' -and $line.StartsWith('launchOnSystemStartup=')) { 'launchOnSystemStartup=false' } else { $line }
        }
        [IO.File]::WriteAllLines($defaultPath,$lines,[Text.UTF8Encoding]::new($false))
    }
    $nativeStartup=(Get-ItemProperty -LiteralPath $RunKey -Name 'Nextcloud' -ErrorAction SilentlyContinue).Nextcloud
    if ($nativeStartup -and $nativeStartup.IndexOf($Client,[StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-ItemProperty -LiteralPath $RunKey -Name 'Nextcloud' }
}
function Start-Client {
    if (-not (Test-Path -LiteralPath $Client)) { throw '未找到客户端。请修改 NEXTCLOUD_CLIENT。' }
    Assert-LocalProfile
    Assert-LocalAccess
    Retire-EmptyDefaultClient
    if (@(Get-ManagedClients).Count) { return }
    $previousMode=[Environment]::GetEnvironmentVariable('OWNCLOUD_SQLITE_LOCKING_MODE','Process')
    try {
        [Environment]::SetEnvironmentVariable('OWNCLOUD_SQLITE_LOCKING_MODE','NORMAL','Process')
        $child=Start-Process -FilePath $Client -ArgumentList @('--background','--confdir',('"'+$ClientConfig+'"'),'--logdir',('"'+(Join-Path $DataRoot 'logs\client')+'"'),'--logexpire','24') -WindowStyle Hidden -PassThru
    } finally { [Environment]::SetEnvironmentVariable('OWNCLOUD_SQLITE_LOCKING_MODE',$previousMode,'Process') }
    for ($attempt=0; $attempt -lt 30; $attempt++) { if (@(Get-ManagedClients).Count) { Write-LibraryLog 'Saved local client profile started.'; return }; if ($child.HasExited) { break }; Start-Sleep -Seconds 1 }
    throw '专用客户端没有启动。工具没有创建新账号。'
}
function Stop-Client {
    if (-not @(Get-ManagedClients).Count) { return }
    $quit=Start-Process -FilePath $Client -ArgumentList @('--quit','--confdir',('"'+$ClientConfig+'"')) -WindowStyle Hidden -PassThru
    if (-not $quit.WaitForExit(10000)) { throw '客户端退出请求超时。服务仍保留。' }
    for ($attempt=0; $attempt -lt 30; $attempt++) { if (-not @(Get-ManagedClients).Count) { return }; Start-Sleep -Seconds 1 }
    throw '客户端尚未退出。工具没有强制停止同步或容器。'
}
function Get-Status {
    $server=$false
    $profileReady=$false
    try { $status=Invoke-RestMethod ($BaseUrl+'/status.php') -TimeoutSec 3; $server=$status.installed -and -not $status.maintenance } catch {}
    try { Assert-LocalProfile; $profileReady=$true } catch {}
    [ordered]@{project=$Project;initialized=(Test-Path -LiteralPath $Marker);server_running=[bool]$server;client_running=(@(Get-ManagedClients).Count -gt 0);profile_ready=$profileReady;server_url=$BaseUrl;library=$Library;data_root=$DataRoot;startup_enabled=($null -ne (Get-ItemProperty -LiteralPath $RunKey -Name $RunName -ErrorAction SilentlyContinue));startup_log=(Join-Path $DataRoot 'logs\startup.log')}
}
try {
    switch ($Action) {
        'Init' { Initialize-Instance }
        'Prepare' { Assert-Instance; Start-Docker; $null=Invoke-Compose -Arguments @('pull','--ignore-buildable','--policy','always'); $null=Invoke-Compose -Arguments @('build','empty-codec') }
        'StartServer' { Start-Server }
        'Pair' {
            Start-Server
            if (-not (Test-Path -LiteralPath $Client)) { throw '未找到客户端。请修改 NEXTCLOUD_CLIENT。' }
            $pairProfile=Read-Ini (Join-Path $ClientConfig 'nextcloud.cfg')
            if ($pairProfile.ContainsKey('Accounts') -and @($pairProfile.Accounts.Keys | Where-Object { $_ -match '^\d+\\url$' }).Count) { Start-Client; break }
            Retire-EmptyDefaultClient
            if ((Test-Path -LiteralPath $Library) -and @(Get-ChildItem -LiteralPath $Library -Force).Count) { throw '首次配对需要空文件库目录。工具不会合并已有文件。' }
            New-Item -ItemType Directory -Path $Library -Force | Out-Null
            if (-not (Test-Path -LiteralPath (Join-Path $ClientConfig 'nextcloud.cfg'))) { [IO.File]::WriteAllText((Join-Path $ClientConfig 'nextcloud.cfg'),"[General]`nskipUpdateCheck=true`nlaunchOnSystemStartup=false`noptionalDesktopNotifications=false`n[Nextcloud]`nlanguage=zh_CN`n",[Text.UTF8Encoding]::new($false)) }
            Start-Process -FilePath $Client -ArgumentList @('--confdir',('"'+$ClientConfig+'"'),'--logdir',('"'+(Join-Path $DataRoot 'logs\client')+'"'),'--logexpire','24') -WindowStyle Normal | Out-Null
        }
        'Start' { Start-Server; Start-Client }
        'Stop' { Assert-Instance; Stop-Client; $null=Invoke-Compose -Arguments @('stop','--timeout','60') }
        'Status' {}
        'SaveCredential' { Assert-Instance; $password=Read-Host '输入本地 Nextcloud 账号的密码或应用密码' -AsSecureString; [pscredential]::new($Settings.NEXTCLOUD_USER,$password) | Export-Clixml -LiteralPath $CredentialFile }
        'EnableStartup' {
            Assert-Instance; Assert-LocalProfile
            $pwsh=(Get-Command pwsh -ErrorAction Stop).Source
            $command='"'+$pwsh+'" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "'+$PSCommandPath+'" -Action Start -EnvFile "'+$EnvFile+'"'
            New-ItemProperty -LiteralPath $RunKey -Name $RunName -Value $command -PropertyType String -Force | Out-Null
        }
        'DisableStartup' { Remove-ItemProperty -LiteralPath $RunKey -Name $RunName -ErrorAction SilentlyContinue }
        'CreateShortcut' {
            Assert-Instance
            $shell=New-Object -ComObject WScript.Shell
            $link=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) ('BaiduLibrary-'+$Project+'.lnk')))
            $link.TargetPath=(Get-Command pwsh -ErrorAction Stop).Source
            $link.Arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "'+$PSCommandPath+'" -Action Start -EnvFile "'+$EnvFile+'"'
            $link.WorkingDirectory=$RepoRoot; $link.WindowStyle=7; $link.Save()
        }
    }
    Get-Status | ConvertTo-Json -Compress
} catch {
    Write-LibraryLog ('FAILED action='+$Action+' type='+$_.Exception.GetType().Name+' reason='+$_.Exception.Message)
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
