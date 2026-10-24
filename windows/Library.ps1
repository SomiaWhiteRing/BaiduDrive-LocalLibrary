#Requires -Version 7.4
# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [ValidateSet('Init','Prepare','StartServer','Pair','Start','Stop','Status','SaveCredential','EnableStartup','DisableStartup','CreateShortcut','ConfigureStorage','Setup','StartClient','ApplyPolicy','PrepareDownloads','Build','PublishMetadata','RefreshMetadata','StopClient')]
    [string]$Action = 'Status',
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)
$ErrorActionPreference = 'Stop'
$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if (-not $IsWindows) { throw '此入口需要 Windows 和 PowerShell 7.4 或更高版本。' }
$RepoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$EnvFile = [IO.Path]::GetFullPath($EnvFile)
if (-not (Test-Path -LiteralPath $EnvFile)) { throw '先将 .env.example 复制为 .env，再修改配置。' }
$AllowedKeys = @('COMPOSE_PROJECT_NAME','DATA_DIR','LIBRARY_DIR','NEXTCLOUD_CLIENT','NEXTCLOUD_USER','OPENLIST_USER','CLIENT_REMOTE_PATH','SERVER_PORT','OPENLIST_PORT','CODEC_PORT','TZ','OPENLIST_DAV_PATH','CLIENT_MAX_PARALLEL','PCS_DOWNLOAD_MODE','SHARED_METADATA','METADATA_DAV_PATH','STARTUP_NAME')
$Settings = @{OPENLIST_DAV_PATH='/dav/baidu';CLIENT_MAX_PARALLEL='24';PCS_DOWNLOAD_MODE='fallback';SHARED_METADATA='1';METADATA_DAV_PATH=''}
$seenKeys = @{}
foreach ($line in [IO.File]::ReadAllLines($EnvFile)) {
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $parts = $line.Split('=',2)
    if ($parts.Count -ne 2 -or $parts[0] -notin $AllowedKeys) { throw '配置文件含有未知字段。' }
    $value = $parts[1].Trim()
    if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) { $value = $value.Substring(1,$value.Length-2) }
    if ($seenKeys.ContainsKey($parts[0])) { throw '配置文件含有重复字段。' }
    $seenKeys[$parts[0]]=$true
    $Settings[$parts[0]] = $value
}
if(-not $Settings.METADATA_DAV_PATH){$Settings.METADATA_DAV_PATH=$Settings.OPENLIST_DAV_PATH}
if(-not $Settings.STARTUP_NAME){$Settings.STARTUP_NAME='BaiduDriveLocal-'+$Settings.COMPOSE_PROJECT_NAME}
foreach ($key in $AllowedKeys) { if (-not $Settings.ContainsKey($key) -or -not $Settings[$key]) { throw ('缺少配置字段：'+$key) } }
if($Settings.SHARED_METADATA -notin @('0','1')){throw 'SHARED_METADATA 使用 0 或 1。'}
if ($Settings.CLIENT_MAX_PARALLEL -notmatch '^[0-9]+$' -or [int]$Settings.CLIENT_MAX_PARALLEL -notin 1..64) { throw 'CLIENT_MAX_PARALLEL 必须在 1 至 64 之间。' }
if ($Settings.PCS_DOWNLOAD_MODE -notin @('fallback','prefer','0')) { throw 'PCS_DOWNLOAD_MODE 使用 fallback、prefer 或 0。' }
$DavPath=$Settings.OPENLIST_DAV_PATH.TrimEnd('/')
if ($DavPath -notmatch '^/dav(?:/[^/?#\\]+)*$' -or @($DavPath.Split('/') | Where-Object { $_ -in @('.','..') }).Count) { throw 'OPENLIST_DAV_PATH 必须是 /dav 下的目录。' }
if($Settings.METADATA_DAV_PATH -notmatch '^/dav(?:/[^/?#\\]+)*$' -or @($Settings.METADATA_DAV_PATH.Split('/') | Where-Object { $_ -in @('.','..') }).Count){throw 'METADATA_DAV_PATH 必须是 /dav 下的目录。'}
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
$RunName = $Settings.STARTUP_NAME
$StartupArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "'+$PSCommandPath+'" -Action Start -EnvFile "'+$EnvFile+'"'

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
function Invoke-Compose([string[]]$Arguments, [string]$InputText) {
    $docker = (Get-Command docker -ErrorAction Stop).Source
    $previous = @{}
    try {
        foreach ($key in $Settings.Keys) { $previous[$key] = [Environment]::GetEnvironmentVariable($key,'Process'); [Environment]::SetEnvironmentVariable($key,$Settings[$key],'Process') }
        $composeArgs=@('compose','--project-directory',$RepoRoot,'--env-file',$EnvFile,'-f',(Join-Path $RepoRoot 'compose.yaml'),'-p',$Project)+$Arguments
        $output = if ($PSBoundParameters.ContainsKey('InputText')) { $InputText | & $docker @composeArgs 2>&1 } else { & $docker @composeArgs 2>&1 }
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
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'config\nextcloud.local.config.php') -Destination (Join-Path $DataRoot 'nextcloud\config\zzzz-local-library.config.php') -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'nextcloud\baidudrive_quota') -Destination (Join-Path $DataRoot 'nextcloud\custom_apps') -Recurse -Force
    $null = Invoke-Compose -Arguments @('up','-d','--pull','never','--no-build')
    $ready = $false
    for ($attempt=0; $attempt -lt 60; $attempt++) {
        try { $status = Invoke-RestMethod ($BaseUrl+'/status.php') -TimeoutSec 3; if ($status.installed -and -not $status.maintenance) { $ready=$true; break } } catch {}
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw '本地服务尚未就绪。请查看容器日志。' }
    $apps = Invoke-Compose -Arguments @('exec','-T','-u','www-data','nextcloud','php','occ','app:list','--output=json') | ConvertFrom-Json -AsHashtable
    $disable = @('updatenotification','nextcloud_announcements','survey_client','files_lock') | Where-Object { $apps.enabled.ContainsKey($_) }
    if ($disable.Count) { $null = Invoke-Compose -Arguments (@('exec','-T','-u','www-data','nextcloud','php','occ','app:disable')+$disable) }
    $null=Invoke-Compose -Arguments @('exec','-T','-u','www-data','nextcloud','php','occ','app:enable','files_external','baidudrive_quota')
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
function Assert-LocalAccess([int]$TimeoutSec=20) {
    $credential = Import-Clixml -LiteralPath $CredentialFile
    if ($credential.UserName -cne $Settings.NEXTCLOUD_USER) { throw '保存的本地凭据不属于配置中的账号。' }
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credential.UserName+':'+$credential.GetNetworkCredential().Password))
    $path=(@($RemotePath.Trim('/').Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    $uri=$BaseUrl+'/remote.php/dav/files/'+[uri]::EscapeDataString($credential.UserName)+'/'+$path
    $response=Invoke-WebRequest $uri -CustomMethod PROPFIND -Headers @{Authorization='Basic '+$encoded;Depth='0'} -Body '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>' -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
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
    if($Settings.SHARED_METADATA -eq '1' -and (Test-Path -LiteralPath (Join-Path $DataRoot 'secrets\webdav.xml'))){Invoke-Metadata 'join'}
    Assert-LocalAccess
    Retire-EmptyDefaultClient
    if (@(Get-ManagedClients).Count) { return }
    $previousParallel=[Environment]::GetEnvironmentVariable('OWNCLOUD_MAX_PARALLEL','Process')
    $previousMode=[Environment]::GetEnvironmentVariable('OWNCLOUD_SQLITE_LOCKING_MODE','Process')
    try {
        [Environment]::SetEnvironmentVariable('OWNCLOUD_SQLITE_LOCKING_MODE','NORMAL','Process')
        [Environment]::SetEnvironmentVariable('OWNCLOUD_MAX_PARALLEL',$Settings.CLIENT_MAX_PARALLEL,'Process')
        $child=Start-Process -FilePath $Client -ArgumentList @('--background','--confdir',('"'+$ClientConfig+'"'),'--logdir',('"'+(Join-Path $DataRoot 'logs\client')+'"'),'--logexpire','24') -WindowStyle Hidden -PassThru
    } finally {
        [Environment]::SetEnvironmentVariable('OWNCLOUD_SQLITE_LOCKING_MODE',$previousMode,'Process')
        [Environment]::SetEnvironmentVariable('OWNCLOUD_MAX_PARALLEL',$previousParallel,'Process')
    }
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
function Configure-Storage {
    Assert-Instance
    $password=Read-Host '输入 OpenList 专用 WebDAV 用户的密码' -AsSecureString
    $credential=[pscredential]::new($Settings.OPENLIST_USER,$password)
    $credential | Export-Clixml -LiteralPath (Join-Path $DataRoot 'secrets\webdav.xml')
    if($Settings.SHARED_METADATA -eq '1'){Invoke-Metadata 'join' $credential}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credential.UserName+':'+$credential.GetNetworkCredential().Password))
    $davUrl='http://127.0.0.1:'+$Settings.CODEC_PORT+(@($DavPath.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    $response=Invoke-WebRequest $davUrl -CustomMethod PROPFIND -Headers @{Authorization='Basic '+$encoded;Depth='0'} -TimeoutSec 30 -SkipHttpErrorCheck
    if ([int]$response.StatusCode -ne 207) { throw '先确认 OpenList 百度存储和专用 WebDAV 用户可用。' }
    $mounts=@(Invoke-Compose -Arguments @('exec','-T','-u','www-data','nextcloud','php','occ','files_external:export') | ConvertFrom-Json)
    $existing=@($mounts | Where-Object { $_.mount_point -ceq $RemotePath })
    if ($existing.Count) {
        if ($existing.Count -ne 1 -or $existing[0].storage -ne '\OC\Files\Storage\DAV' -or $existing[0].configuration.host -ne 'empty-codec:8080' -or $existing[0].configuration.root.Trim('/') -cne $DavPath.Trim('/') -or $existing[0].configuration.user -cne $Settings.OPENLIST_USER -or $Settings.NEXTCLOUD_USER -notin $existing[0].applicable_users) { throw '目标外部存储属于其他配置。请在 Nextcloud 管理界面核对。' }
    } else {
        $mount=@{mount_id=$null;mount_point=$RemotePath;storage='\OC\Files\Storage\DAV';authentication_type='password::password';configuration=@{host='empty-codec:8080';root=$DavPath;secure=$false;user=$Settings.OPENLIST_USER;password=$credential.GetNetworkCredential().Password};options=@{enable_sharing=$false;filesystem_check_changes=1};applicable_users=@($Settings.NEXTCLOUD_USER);applicable_groups=@()}
        $null=Invoke-Compose -Arguments @('exec','-T','-u','www-data','nextcloud','php','occ','files_external:import','-') -InputText (ConvertTo-Json -InputObject @($mount) -Depth 12 -Compress)
    }
    Assert-LocalAccess
    Write-LibraryLog 'Dedicated WebDAV mount verified.'
}
function Invoke-Metadata([string]$MetadataAction,[pscredential]$Credential) {
    Assert-Instance
    if(-not $Credential){
        $file=Join-Path $DataRoot 'secrets\webdav.xml'
        if(Test-Path -LiteralPath $file){$Credential=Import-Clixml -LiteralPath $file}
        else{$Credential=[pscredential]::new($Settings.OPENLIST_USER,(Read-Host '输入 OpenList 专用 WebDAV 用户的密码' -AsSecureString));$Credential | Export-Clixml -LiteralPath $file}
    }
    if($Credential.UserName -cne $Settings.OPENLIST_USER){throw '保存的 WebDAV 凭据与配置不一致。'}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Credential.UserName+':'+$Credential.GetNetworkCredential().Password))
    $result=Invoke-RestMethod ('http://127.0.0.1:'+$Settings.CODEC_PORT+'/__library_metadata') -Method Post -Headers @{Authorization='Basic '+$encoded} -ContentType 'application/json' -Body (@{action=$MetadataAction}|ConvertTo-Json -Compress) -TimeoutSec 600
    if(-not $result.ready){throw '共享元数据尚未就绪。'}
    Write-LibraryLog ('Shared metadata ready; pending='+$result.pending)
}
function Connect-Client {
    if (-not (Test-Path -LiteralPath $Client)) { throw '先安装 Nextcloud 桌面客户端，再检查 NEXTCLOUD_CLIENT。' }
    $profile=Read-Ini (Join-Path $ClientConfig 'nextcloud.cfg')
    if ($profile.ContainsKey('Accounts') -and @($profile.Accounts.Keys | Where-Object { $_ -ne 'version' }).Count) { Start-Client; return }
    Assert-LocalAccess
    Retire-EmptyDefaultClient
    if ((Test-Path -LiteralPath $Library) -and @(Get-ChildItem -LiteralPath $Library -Force).Count) { throw '首次配对使用空文件库目录。' }
    New-Item -ItemType Directory -Path $Library -Force | Out-Null
    $answer=Invoke-Compose -Arguments @('exec','-T','-u','www-data','nextcloud','php','occ','user:auth-tokens:add','--no-interaction','--name=BaiduDrive LocalLibrary',$Settings.NEXTCLOUD_USER)
    $token=($answer.Trim() -split '\r?\n')[-1].Trim()
    if ($token -cnotmatch '^[A-Za-z0-9]{72}$') { throw '本地应用凭据创建失败。' }
    $credential=[pscredential]::new($Settings.NEXTCLOUD_USER,(ConvertTo-SecureString $token -AsPlainText -Force))
    $credential | Export-Clixml -LiteralPath $CredentialFile
    [IO.File]::WriteAllText((Join-Path $ClientConfig 'nextcloud.cfg'),"[General]`nskipUpdateCheck=true`nlaunchOnSystemStartup=false`noptionalDesktopNotifications=false`n[Nextcloud]`nlanguage=zh_CN`nshowInExplorerNavigationPane=true`n",[Text.UTF8Encoding]::new($false))
    $info=[Diagnostics.ProcessStartInfo]::new($Client)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    foreach($arg in @('--background','--confdir',$ClientConfig,'--logdir',(Join-Path $DataRoot 'logs\client'),'--logexpire','24','--userid',$Settings.NEXTCLOUD_USER,'--apppassword',$token,'--serverurl',$BaseUrl,'--localdirpath',$Library,'--remotedirpath',$RemotePath,'--isvfsenabled','1')) { $info.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::Start($info)
    if (-not $process.WaitForExit(90000) -or $process.ExitCode -ne 0) { throw '本地客户端配对尚未完成。请查看客户端日志。' }
    Assert-LocalProfile
    Set-SyncPolicy
    Start-Client
}
function Set-SyncPolicy {
    Assert-Instance
    $pattern='[nN][oO][dD][eE]_[mM][oO][dD][uU][lL][eE][sS]/'
    $userFile=Join-Path $ClientConfig 'sync-exclude.lst'
    foreach($file in @($userFile,(Join-Path (Split-Path -Parent $Client) 'sync-exclude.lst'))) {
        $lines=if(Test-Path -LiteralPath $file){@([IO.File]::ReadAllLines($file) | Where-Object { $_.Trim() -notin @('*~','*.crdownload') })}else{@()}
        if($file -eq $userFile -and $pattern -notin $lines){$lines+=@('# BaiduDrive LocalLibrary: node_modules directories.',$pattern)}
        $text=($lines -join [Environment]::NewLine)+[Environment]::NewLine
        if((Test-Path -LiteralPath $file) -and [IO.File]::ReadAllText($file) -eq $text){continue}
        try{[IO.File]::WriteAllText($file,$text,[Text.UTF8Encoding]::new($false))}
        catch [UnauthorizedAccessException] {
            if($file -eq $userFile){throw}
            & (Join-Path $PSScriptRoot 'Repair-Policy.ps1') -PolicyFile $file -UserSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            [IO.File]::WriteAllText($file,$text,[Text.UTF8Encoding]::new($false))
        }
    }
}
function Prepare-Downloads {
    Assert-Instance
    $directory=Join-Path $DataRoot 'tools'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $archive=Join-Path $directory 'BaiduPCS-Go-v4.0.1-linux-amd64.zip'
    Invoke-WebRequest 'https://github.com/qjfoidnh/BaiduPCS-Go/releases/download/v4.0.1/BaiduPCS-Go-v4.0.1-linux-amd64.zip' -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $directory 'pcs-release') -Force
    $binary=@(Get-ChildItem -LiteralPath (Join-Path $directory 'pcs-release') -Recurse -File -Filter BaiduPCS-Go)
    if($binary.Count -ne 1){throw '下载后端发行包结构与预期不一致。'}
    Copy-Item -LiteralPath $binary[0].FullName -Destination (Join-Path $directory 'BaiduPCS-Go') -Force
    $null=Invoke-Compose -Arguments @('exec','-T','empty-codec','chmod','755','/state/tools/BaiduPCS-Go')
    Write-LibraryLog 'Prepared the pinned optional PCS executable.'
}
function Get-Status {
    $server=$false
    $profileReady=$false
    $metadataReady=$false
    $fileAccessible=$false
    try{$health=Invoke-RestMethod ('http://127.0.0.1:'+$Settings.CODEC_PORT+'/health') -TimeoutSec 3;$metadataReady=($health.service -eq 'empty-codec' -and ($Settings.SHARED_METADATA -eq '0' -or $health.shared_metadata.ready))}catch{}
    try { $status=Invoke-RestMethod ($BaseUrl+'/status.php') -TimeoutSec 3; $server=$status.installed -and -not $status.maintenance } catch {}
    try { Assert-LocalProfile; $profileReady=$true } catch {}
    if($server -and $profileReady){try{Assert-LocalAccess -TimeoutSec 3;$fileAccessible=$true}catch{}}
    [ordered]@{project=$Project;initialized=(Test-Path -LiteralPath $Marker);server_running=[bool]$server;client_running=(@(Get-ManagedClients).Count -gt 0);profile_ready=$profileReady;metadata_ready=[bool]$metadataReady;file_accessible=$fileAccessible;server_url=$BaseUrl;library=$Library;data_root=$DataRoot;startup_enabled=($null -ne (Get-ItemProperty -LiteralPath $RunKey -Name $RunName -ErrorAction SilentlyContinue));ready=($server -and $profileReady -and $metadataReady -and $fileAccessible -and (@(Get-ManagedClients).Count -gt 0));openlist_url=('http://127.0.0.1:'+$Settings.OPENLIST_PORT);log_directory=(Join-Path $DataRoot 'logs');startup_log=(Join-Path $DataRoot 'logs\startup.log')}
}
try {
    switch ($Action) {
        'Setup' {
            Initialize-Instance
            Start-Docker
            $null=Invoke-Compose -Arguments @('pull','--ignore-buildable','--policy','always')
            $null=Invoke-Compose -Arguments @('build','empty-codec')
            Start-Server
            Configure-Storage
            Connect-Client
            & (Join-Path $PSScriptRoot 'Build.ps1')
            & (Join-Path $PSScriptRoot 'Set-FolderIcon.ps1') -Library $Library
            & $PSCommandPath -Action EnableStartup -EnvFile $EnvFile
            if($LASTEXITCODE -ne 0){throw '登记自启失败。'}
            & $PSCommandPath -Action CreateShortcut -EnvFile $EnvFile
        }
        'ConfigureStorage' { Start-Server; Configure-Storage }
        'PublishMetadata' { Invoke-Metadata 'publish' }
        'RefreshMetadata' { Invoke-Metadata 'refresh' }
        'StartClient' { Assert-Instance; Start-Client }
        'StopClient' { Assert-Instance; Stop-Client }
        'ApplyPolicy' { Set-SyncPolicy }
        'PrepareDownloads' { Prepare-Downloads }
        'Build' { & (Join-Path $PSScriptRoot 'Build.ps1') }
        'Init' { Initialize-Instance }
        'Prepare' { Assert-Instance; Start-Docker; $null=Invoke-Compose -Arguments @('pull','--ignore-buildable','--policy','always'); $null=Invoke-Compose -Arguments @('build','empty-codec') }
        'StartServer' { Start-Server }
        'Pair' { Start-Server; Connect-Client }
        'Start' { Start-Server; Start-Client }
        'Stop' { Assert-Instance; Stop-Client; $null=Invoke-Compose -Arguments @('stop','--timeout','60') }
        'Status' {}
        'SaveCredential' { Assert-Instance; $password=Read-Host '输入本地 Nextcloud 账号的密码或应用密码' -AsSecureString; [pscredential]::new($Settings.NEXTCLOUD_USER,$password) | Export-Clixml -LiteralPath $CredentialFile }
        'EnableStartup' {
            Assert-Instance; Assert-LocalProfile
            $pwsh=(Get-Command pwsh -ErrorAction Stop).Source
            $command='"'+$pwsh+'" '+$StartupArguments
            New-ItemProperty -LiteralPath $RunKey -Name $RunName -Value $command -PropertyType String -Force | Out-Null
        }
        'DisableStartup' { Remove-ItemProperty -LiteralPath $RunKey -Name $RunName -ErrorAction SilentlyContinue }
        'CreateShortcut' {
            Assert-Instance
            $shell=New-Object -ComObject WScript.Shell
            $link=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) ('BaiduLibrary-'+$Project+'.lnk')))
            $control=Join-Path $RepoRoot 'BaiduDrive.exe'
            if(Test-Path -LiteralPath $control){$link.TargetPath=$control;$link.Arguments='--env-file "'+$EnvFile+'"'}else{$link.TargetPath=(Get-Command pwsh -ErrorAction Stop).Source;$link.Arguments=$StartupArguments}
            $link.WorkingDirectory=$RepoRoot; $link.WindowStyle=7; $link.Save()
        }
    }
    Get-Status | ConvertTo-Json -Compress
    exit 0
} catch {
    Write-LibraryLog ('FAILED action='+$Action+' type='+$_.Exception.GetType().Name+' reason='+$_.Exception.Message)
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
