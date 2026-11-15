param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$workspace = Split-Path -Parent $PSScriptRoot
$masterPath = Join-Path $workspace 'mobile/assets/branding/khotwa-icon-master.png'
$source = [System.Drawing.Image]::FromFile($masterPath)

function Write-Icon([string]$RelativePath, [int]$Size, [double]$Scale = 1) {
    $destination = Join-Path $workspace $RelativePath
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    # Opaque RGB is required for the iOS marketing icon. Insets here only prepare
    # the finished artwork for the Android adaptive mask; they do not redraw it.
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml('#F8F5EF'))
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $edge = [int][Math]::Round($Size * $Scale)
        $offset = [int][Math]::Floor(($Size - $edge) / 2)
        $graphics.DrawImage($source, $offset, $offset, $edge, $edge)
        $bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

try {
    foreach ($density in @(@('mdpi',48,108), @('hdpi',72,162), @('xhdpi',96,216), @('xxhdpi',144,324), @('xxxhdpi',192,432))) {
        Write-Icon "mobile/android/app/src/main/res/mipmap-$($density[0])/ic_launcher.png" $density[1]
        Write-Icon "mobile/android/app/src/main/res/mipmap-$($density[0])/ic_launcher_foreground.png" $density[2] 0.84
    }
    $catalog = 'mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset'
    $entries = (Get-Content -LiteralPath (Join-Path $workspace "$catalog/Contents.json") -Raw | ConvertFrom-Json).images
    foreach ($entry in $entries) {
        $points = [double]::Parse(($entry.size -split 'x')[0], [System.Globalization.CultureInfo]::InvariantCulture)
        $factor = [int]($entry.scale -replace 'x','')
        Write-Icon "$catalog/$($entry.filename)" ([int]($points * $factor))
    }
    Write-Icon 'mobile/assets/branding/khotwa-icon.png' 512
    Write-Icon 'mobile/web/favicon.png' 48
    Write-Output 'Generated opaque Android, adaptive Android, iOS and Flutter brand icons from the original master.'
} finally { $source.Dispose() }
