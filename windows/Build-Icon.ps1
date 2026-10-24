# SPDX-License-Identifier: MIT
# Editable vector drawing; requires only Windows System.Drawing.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$assets = Join-Path $PSScriptRoot 'assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$radius) {
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x+$w-$d, $y, $d, $d, 270, 90)
    $path.AddArc($x+$w-$d, $y+$h-$d, $d, $d, 0, 90)
    $path.AddArc($x, $y+$h-$d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

$canvas = New-Object Drawing.Bitmap 512,512
$graphics = [Drawing.Graphics]::FromImage($canvas)
$graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.ScaleTransform(2,2)
$tile = New-RoundedPath 12 12 232 232 52
$gradient = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(12,12)),([Drawing.Point]::new(244,244)),([Drawing.ColorTranslator]::FromHtml('#1685EE')),([Drawing.ColorTranslator]::FromHtml('#2342B3'))
$graphics.FillPath($gradient, $tile)
# A cloud above a disk, with a small green activity light.
$white = [Drawing.Brushes]::White
$graphics.FillEllipse($white, 78, 49, 78, 78)
$graphics.FillEllipse($white, 133, 76, 52, 52)
$graphics.FillEllipse($white, 52, 87, 50, 50)
$cloudBase = New-RoundedPath 60 105 126 33 16
$graphics.FillPath($white, $cloudBase)
$disk = New-RoundedPath 55 154 146 55 16
$graphics.FillPath($white, $disk)
$slot = New-RoundedPath 73 176 58 9 4.5
$blue = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#2256C9'))
$green = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#16B886'))
$graphics.FillPath($blue, $slot)
$graphics.FillEllipse($green, 170, 175, 12, 12)
$graphics.Dispose()

$images = @()
foreach ($size in @(16,24,32,48,64,128,256)) {
    $bitmap = New-Object Drawing.Bitmap $size,$size
    $g = [Drawing.Graphics]::FromImage($bitmap)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($canvas, 0, 0, $size, $size)
    $g.Dispose()
    $stream = New-Object IO.MemoryStream
    $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    $images += [pscustomobject]@{Size=$size;Bytes=$stream.ToArray()}
    if ($size -eq 256) { $bitmap.Save((Join-Path $assets 'BaiduDrive.png'), [Drawing.Imaging.ImageFormat]::Png) }
    $stream.Dispose()
    $bitmap.Dispose()
}
$file = [IO.File]::Create((Join-Path $assets 'BaiduDrive.ico'))
$writer = New-Object IO.BinaryWriter $file
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
    $offset = 6 + 16*$images.Count
    foreach ($item in $images) {
        $dimension = if ($item.Size -eq 256) { 0 } else { $item.Size }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$item.Bytes.Length); $writer.Write([uint32]$offset)
        $offset += $item.Bytes.Length
    }
    foreach ($item in $images) { $writer.Write([byte[]]$item.Bytes) }
} finally {
    $writer.Dispose()
    $canvas.Dispose()
    $tile.Dispose(); $cloudBase.Dispose(); $disk.Dispose(); $slot.Dispose()
    $gradient.Dispose(); $blue.Dispose(); $green.Dispose()
}
