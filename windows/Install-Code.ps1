#Requires -Version 7.4
# SPDX-License-Identifier: MIT
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination,[switch]$Check)
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$Destination=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
if($Destination -eq $source -or $Destination.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($Destination+'\',[StringComparison]::OrdinalIgnoreCase) -or $Destination -eq [IO.Path]::GetPathRoot($Destination).TrimEnd('\')){throw '安装目录与仓库使用独立目录树。'}
$relativeFiles=@('.env.example','.gitattributes','.gitignore','LICENSE','README.md','CONTRIBUTING.md','SECURITY.md','THIRD_PARTY_NOTICES.md','compose.yaml')
foreach($directory in @('codec','config','windows','docs','nextcloud')){
    $relativeFiles+=Get-ChildItem -LiteralPath (Join-Path $source $directory) -Recurse -File |
        Where-Object { $_.Extension -in @('.py','.ps1','.cs','.yaml','.php','.conf','.ini','.md','.txt','.xml') -or $_.Name -in @('Dockerfile','.dockerignore','COPYING') } |
        ForEach-Object { [IO.Path]::GetRelativePath($source,$_.FullName) }
}
$changed=@()
foreach($relative in $relativeFiles){
    $from=Join-Path $source $relative; $to=Join-Path $Destination $relative
    if((Test-Path -LiteralPath $to) -and [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($from),[byte[]][IO.File]::ReadAllBytes($to))){continue}
    $changed+=$relative
    if($Check){continue}
    New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
    if(Test-Path -LiteralPath $to){
        $backup=Join-Path $Destination ('backups\code-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'\'+$relative)
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        Copy-Item -LiteralPath $to -Destination $backup
    }
    Copy-Item -LiteralPath $from -Destination $to -Force
}
[ordered]@{destination=$Destination;check=[bool]$Check;changed=$changed;files=$relativeFiles.Count} | ConvertTo-Json -Depth 4
