#Requires -Version 7.4
# SPDX-License-Identifier: MIT
param([Parameter(Mandatory)][string]$Library)
$ErrorActionPreference='Stop'
$icon=Join-Path $PSScriptRoot 'assets\Library.ico'
if(-not (Test-Path -LiteralPath $icon)){return}
if(-not (Test-Path -LiteralPath $Library -PathType Container)){return}
$ini=Join-Path $Library 'Desktop.ini'
$attributes=if(Test-Path -LiteralPath $ini){[IO.File]::GetAttributes($ini)}else{[IO.FileAttributes]::Archive}
if(Test-Path -LiteralPath $ini){[IO.File]::SetAttributes($ini,[IO.FileAttributes]::Normal)}
try{[IO.File]::WriteAllText($ini,"[.ShellClassInfo]`r`nIconResource=$icon,0`r`n",[Text.Encoding]::Unicode)}
finally{if(Test-Path -LiteralPath $ini){[IO.File]::SetAttributes($ini,($attributes -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System))}}
[IO.File]::SetAttributes($Library,([IO.File]::GetAttributes($Library) -bor [IO.FileAttributes]::ReadOnly))
