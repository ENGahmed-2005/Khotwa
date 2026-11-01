$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mobile = Join-Path $root 'mobile'
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Error 'Flutter SDK not found. Install it from https://docs.flutter.dev/get-started/install'
    exit 1
}
if ((Test-Path (Join-Path $mobile 'android')) -or (Test-Path (Join-Path $mobile 'ios'))) {
    Write-Host 'Native runner folders already exist. Not overwriting.'
    exit 0
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('khotwa-' + [Guid]::NewGuid().ToString('N'))
try {
    flutter create --project-name khotwa --org org.khotwa --platforms android,ios (Join-Path $temp 'khotwa')
    if ($LASTEXITCODE -ne 0) { throw 'flutter create failed' }
    Copy-Item (Join-Path $temp 'khotwa/android') (Join-Path $mobile 'android') -Recurse
    Copy-Item (Join-Path $temp 'khotwa/ios') (Join-Path $mobile 'ios') -Recurse
    Copy-Item (Join-Path $temp 'khotwa/.metadata') (Join-Path $mobile '.metadata')
    python (Join-Path $root 'scripts/prepare_android_manifest.py') (Join-Path $mobile 'android/app/src/main/AndroidManifest.xml')
    Push-Location $mobile
    try {
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
        flutter analyze
        if ($LASTEXITCODE -ne 0) { throw 'flutter analyze failed' }
        flutter test
        if ($LASTEXITCODE -ne 0) { throw 'flutter test failed' }
    } finally { Pop-Location }
    Write-Host 'Project ready. Go to mobile and run flutter run.'
} finally {
    if (Test-Path $temp) { Remove-Item -Recurse -Force $temp }
}
