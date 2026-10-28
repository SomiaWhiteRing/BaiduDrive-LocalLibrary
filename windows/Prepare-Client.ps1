#Requires -Version 7.4
# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ClientPath,
    [Parameter(Mandatory)][string]$CacheDirectory,
    [string]$PackageFile,
    [string]$PayloadDirectory,
    [switch]$Check,
    [switch]$Elevated
)
$ErrorActionPreference='Stop'
$ClientPath=[IO.Path]::GetFullPath($ClientPath)
$CacheDirectory=[IO.Path]::GetFullPath($CacheDirectory)
if([IO.Path]::GetFileName($ClientPath) -ine 'nextcloud.exe'){throw 'ClientPath 必须指向 nextcloud.exe。'}
$release=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\nextcloud\desktop\release.json') -Raw | ConvertFrom-Json
$files=@('nextcloud.exe','nextcloudsync.dll','nextcloud_csync.dll','nextcloudsync_vfs_cfapi.dll','nextcloudsync_vfs_suffix.dll')
$clientDirectory=Split-Path -Parent $ClientPath
$stateFile=Join-Path $CacheDirectory 'installed.json'
function Get-ClientState {
    $version=if(Test-Path -LiteralPath $ClientPath){(Get-Item -LiteralPath $ClientPath).VersionInfo.FileVersion}else{$null}
    $state=if(Test-Path -LiteralPath $stateFile){Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json}else{$null}
    $missing=@($files | Where-Object {-not (Test-Path -LiteralPath (Join-Path $clientDirectory $_) -PathType Leaf)})
    [pscustomobject]@{prepared=[bool]($state -and $state.release_tag -eq $release.release_tag -and $state.client_path -eq $ClientPath -and $version -eq $release.file_version -and -not $missing.Count);version=$version;expected=$release.file_version;client_path=$ClientPath}
}
$current=Get-ClientState
if($Check -or $current.prepared){return $current}
if(-not $current.version -or $current.version -notlike ($release.base_version+'.*')){throw ('先安装官方 Nextcloud Desktop '+$release.base_version+' x64，再执行 PrepareClient。')}
New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
if(-not $PayloadDirectory){
    if(-not $PackageFile){
        $PackageFile=Join-Path $CacheDirectory ([IO.Path]::GetFileName(([uri]$release.package_url).AbsolutePath))
        if(-not (Test-Path -LiteralPath $PackageFile)){Invoke-WebRequest -Uri $release.package_url -OutFile $PackageFile}
    }
    $PayloadDirectory=Join-Path $CacheDirectory $release.release_tag
    Expand-Archive -LiteralPath $PackageFile -DestinationPath $PayloadDirectory -Force
}
$PayloadDirectory=[IO.Path]::GetFullPath($PayloadDirectory)
$packageRelease=Get-Content -LiteralPath (Join-Path $PayloadDirectory 'release.json') -Raw | ConvertFrom-Json
if($packageRelease.release_tag -cne $release.release_tag -or (Get-Item -LiteralPath (Join-Path $PayloadDirectory 'nextcloud.exe')).VersionInfo.FileVersion -ne $release.file_version){throw '覆盖包版本不符合本项目的固定版本。'}
$same=$true
foreach($name in $files){
    $from=Join-Path $PayloadDirectory $name; $to=Join-Path $clientDirectory $name
    if(-not (Test-Path -LiteralPath $from -PathType Leaf)){throw ('覆盖包缺少文件：'+$name)}
    if(-not (Test-Path -LiteralPath $to) -or -not [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($from),[byte[]][IO.File]::ReadAllBytes($to))){$same=$false}
}
if(-not $same){
    $running=@(Get-CimInstance Win32_Process -Filter "Name='nextcloud.exe'" | Where-Object {$_.ExecutablePath -eq $ClientPath})
    if($running.Count){throw '先退出使用该程序的 Nextcloud 客户端，再执行 PrepareClient。'}
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not $admin){
        if($Elevated){throw '覆盖客户端需要 Windows 管理员权限。'}
        $arguments='-NoLogo -NoProfile -NonInteractive -File "'+$PSCommandPath+'" -ClientPath "'+$ClientPath+'" -CacheDirectory "'+$CacheDirectory+'" -PayloadDirectory "'+$PayloadDirectory+'" -Elevated'
        $process=Start-Process -FilePath (Get-Command pwsh -ErrorAction Stop).Source -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
        $process.WaitForExit()
        if($process.ExitCode -ne 0){throw ('客户端安装未完成。请查看 '+(Join-Path $CacheDirectory 'install.log'))}
        return Get-ClientState
    }
    Start-Transcript -Path (Join-Path $CacheDirectory 'install.log') -Force | Out-Null
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup=Join-Path $CacheDirectory ('backup-'+$stamp)
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach($name in $files){if(Test-Path -LiteralPath (Join-Path $clientDirectory $name)){Copy-Item -LiteralPath (Join-Path $clientDirectory $name) -Destination (Join-Path $backup $name)}}
    foreach($name in $files){
        $target=Join-Path $clientDirectory $name
        if(Test-Path -LiteralPath $target){Rename-Item -LiteralPath $target -NewName ($name+'.pre-locallibrary-'+$stamp)}
        Copy-Item -LiteralPath (Join-Path $PayloadDirectory $name) -Destination $target
    }
    foreach($name in $files){if(-not [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes((Join-Path $PayloadDirectory $name)),[byte[]][IO.File]::ReadAllBytes((Join-Path $clientDirectory $name)))){throw ('安装文件与覆盖包不一致：'+$name)}}
    Stop-Transcript | Out-Null
}
[ordered]@{release_tag=$release.release_tag;client_path=$ClientPath;version=$release.file_version} | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
Get-ClientState
