#Requires -Version 7.4
# SPDX-License-Identifier: MIT
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PolicyFile,[Parameter(Mandatory)][string]$UserSid,[switch]$Elevated)
$ErrorActionPreference='Stop'
$PolicyFile=[IO.Path]::GetFullPath($PolicyFile)
if([IO.Path]::GetFileName($PolicyFile) -cne 'sync-exclude.lst' -or -not (Test-Path -LiteralPath $PolicyFile -PathType Leaf)){throw '目标必须是现有的 sync-exclude.lst 文件。'}
if((Get-Item -LiteralPath $PolicyFile).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '规则文件必须是普通本机文件。'}
$sid=[Security.Principal.SecurityIdentifier]::new($UserSid)
if(-not $Elevated){
    $arguments='-NoLogo -NoProfile -NonInteractive -File "'+$PSCommandPath+'" -PolicyFile "'+$PolicyFile+'" -UserSid "'+$UserSid+'" -Elevated'
    $process=Start-Process -FilePath (Get-Command pwsh -ErrorAction Stop).Source -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if($process.ExitCode -ne 0){throw '全局规则权限修复尚未完成。'}
    return
}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw '该步骤需要 Windows 管理员权限。'}
$acl=Get-Acl -LiteralPath $PolicyFile
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::Modify,[Security.AccessControl.AccessControlType]::Allow))
Set-Acl -LiteralPath $PolicyFile -AclObject $acl
