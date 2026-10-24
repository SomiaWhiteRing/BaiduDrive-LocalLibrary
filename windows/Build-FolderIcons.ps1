# SPDX-License-Identifier: MIT
# Code-drawn folder icons; no external image libraries or downloaded artwork.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$assets = Join-Path $PSScriptRoot 'assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
. (Join-Path $PSScriptRoot 'Build-Icon.ps1')
Copy-Item -LiteralPath (Join-Path $assets 'BaiduDrive.ico') -Destination (Join-Path $assets 'Library.ico') -Force

$canvas = [Drawing.Bitmap]::new(512,512)
$g = [Drawing.Graphics]::FromImage($canvas)
$g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.ScaleTransform(2,2)
$tile = New-RoundedPath 12 12 232 232 52
$gradient = [Drawing.Drawing2D.LinearGradientBrush]::new([Drawing.Point]::new(12,12),[Drawing.Point]::new(244,244),[Drawing.ColorTranslator]::FromHtml('#455366'),[Drawing.ColorTranslator]::FromHtml('#202A39'))
$g.FillPath($gradient,$tile)
$teal = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#20D4B5'))
$dark = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#354359'))
foreach ($y in @(51,105,159)) {
    $rack = New-RoundedPath 49 $y 158 43 11
    $g.FillPath([Drawing.Brushes]::White,$rack)
    $g.FillEllipse($teal,65,($y+13),16,16)
    $g.FillRectangle($dark,100,($y+14),58,5)
    $g.FillRectangle($dark,100,($y+24),75,5)
    $rack.Dispose()
}
$g.Dispose()
$images = @()
foreach ($size in @(16,24,32,48,64,128,256)) {
    $bitmap = [Drawing.Bitmap]::new($size,$size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.DrawImage($canvas,0,0,$size,$size)
    $graphics.Dispose()
    $stream = [IO.MemoryStream]::new()
    $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
    $images += [pscustomobject]@{Size=$size;Bytes=$stream.ToArray()}
    if ($size -eq 256) { $bitmap.Save((Join-Path $assets 'Service.png'),[Drawing.Imaging.ImageFormat]::Png) }
    $stream.Dispose()
    $bitmap.Dispose()
}
$writer = [IO.BinaryWriter]::new([IO.File]::Create((Join-Path $assets 'Service.ico')))
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$images.Count)
    $offset = 6+16*$images.Count
    foreach ($item in $images) {
        $dimension = if ($item.Size -eq 256) { 0 } else { $item.Size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$item.Bytes.Length)
        $writer.Write([uint32]$offset)
        $offset += $item.Bytes.Length
    }
    foreach ($item in $images) { $writer.Write([byte[]]$item.Bytes) }
} finally {
    $writer.Dispose()
    $canvas.Dispose()
    $tile.Dispose()
    $gradient.Dispose()
    $teal.Dispose()
    $dark.Dispose()
}
