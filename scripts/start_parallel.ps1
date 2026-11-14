$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$parent = Split-Path $root -Parent
Push-Location $root
try {
    $base = git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Commit the reviewed foundation first.' }
    foreach ($entry in @(@('khotwa-backend', 'feat/sec-01-backend'), @('khotwa-mobile', 'feat/stu-01-mobile'))) {
        $target = Join-Path $parent $entry[0]
        if (Test-Path -LiteralPath $target) {
            Write-Output ('Preserving existing worktree: ' + $target)
            continue
        }
        git worktree add $target -b $entry[1] $base
        if ($LASTEXITCODE -ne 0) { throw 'Worktree creation failed; no existing content was removed.' }
    }
    git worktree list
} finally { Pop-Location }
