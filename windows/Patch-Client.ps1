#Requires -Version 7.4
# SPDX-License-Identifier: MIT
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceDirectory,[switch]$Check)
$ErrorActionPreference='Stop'
$SourceDirectory=[IO.Path]::GetFullPath($SourceDirectory)
$patch=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\nextcloud\desktop\sync-display.patch'))
$revision=& git -C $SourceDirectory rev-parse HEAD
if($LASTEXITCODE -ne 0 -or $revision -ne 'ce977e31810bc9f2cdffc4828cc0a14bd0792110'){throw '客户端源码必须位于 Nextcloud Desktop v35.0.0 的指定提交。'}
$null=& git -C $SourceDirectory apply --reverse --check $patch 2>$null
if($LASTEXITCODE -eq 0){Write-Output '客户端补丁已应用。'; return}
& git -C $SourceDirectory apply --check $patch
if($LASTEXITCODE -ne 0){throw '客户端补丁与现有源码冲突。请检查源码差异。'}
if($Check){Write-Output '客户端补丁可应用。源码保持原样。'; return}
& git -C $SourceDirectory apply $patch
if($LASTEXITCODE -ne 0){throw '客户端补丁应用失败。'}
Write-Output '客户端补丁已应用。编译并安装客户端后生效。'
