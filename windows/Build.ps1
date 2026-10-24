#Requires -Version 7.4
# SPDX-License-Identifier: MIT
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Build-FolderIcons.ps1')
$root=Split-Path -Parent $PSScriptRoot
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:winexe /platform:x64 /codepage:65001 /utf8output /optimize+ ("/out:$root\BaiduDrive.exe") ("/win32icon:$PSScriptRoot\assets\BaiduDrive.ico") /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'Control.cs')
if($LASTEXITCODE -ne 0){throw '控制程序构建失败。关闭已有控制窗口后重试。'}
