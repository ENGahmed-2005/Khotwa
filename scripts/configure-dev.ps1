$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envFile = Join-Path $root 'backend/.env'
if (Test-Path -LiteralPath $envFile) {
    throw 'backend/.env already exists; keep existing credentials and use its configured PostgreSQL instance.'
}
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
function New-RandomBase64 {
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    return [Convert]::ToBase64String($bytes)
}
$password = (New-RandomBase64).Replace('+', 'a').Replace('/', 'b').Replace('=', '')
$key = New-RandomBase64
$content = @(
    "DATABASE_URL=postgresql://khotwa:$password@127.0.0.1:55432/khotwa",
    "STORAGE_KEY=$key", 'HOST=127.0.0.1', 'PORT=3000',
    'NODE_ENV=development', 'AI_ENABLED=false'
)
[IO.File]::WriteAllLines($envFile, $content, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $root '.env'), "POSTGRES_PASSWORD=$password`n", [Text.UTF8Encoding]::new($false))
$rng.Dispose()
Write-Output 'Created ignored local secrets. Run docker compose up -d, then npm ci and npm run db:migrate:ci in backend.'
