<#
.SYNOPSIS
  Publishes the project to a GitHub repository: git init (if needed), safety checks, commit, push.
  Before running: create an EMPTY repository on GitHub (no README) and copy its URL.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\qa\publish-git.ps1
#>
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
[Console]::OutputEncoding = [Text.Encoding]::UTF8

git --version | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'git is not installed'; exit 1 }
if (-not (Test-Path (Join-Path $root '.git'))) { git init -b main | Out-Null; Write-Host 'git repository created' }
# identity is set AFTER git init (a repository-level setting cannot be written outside a repository)
if (-not (git config user.name))  { git config user.name  (Read-Host 'Your name for git commits (e.g. Avigail R.)') }
if (-not (git config user.email)) { git config user.email (Read-Host 'Your email for git commits (the one on your GitHub account)') }

git add -A
$files = @(git diff --cached --name-only)
Write-Host "files to commit: $($files.Count)"

# --- safety checks: no build output, logs or secrets ---
$bad = @($files | Where-Object { $_ -match '(^|/)(bin|obj|node_modules|dist|\.venv|\.angular)/' -or $_ -match '\.(log|pem|pfx|env)$' -or $_ -match '(^|/)qa/.*\.txt$' })
if ($bad.Count -gt 0) { Write-Host "STOP - files that must not be committed:`n$($bad -join "`n")" -ForegroundColor Red; git reset | Out-Null; exit 1 }
$secretHits = @()
foreach ($f in $files) {
    if (-not (Test-Path $f) -or (Get-Item $f).Length -gt 2MB) { continue }
    $text = Get-Content $f -Raw -ErrorAction SilentlyContinue
    if ($text -match 'AIza[0-9A-Za-z_\-]{30,}|sk-[A-Za-z0-9]{20,}|-----BEGIN (RSA |EC )?PRIVATE KEY-----|(?i)password\s*=\s*[^;"\s]{4,}') { $secretHits += $f }
}
if ($secretHits.Count -gt 0) { Write-Host "STOP - possible secrets in:`n$($secretHits -join "`n")" -ForegroundColor Red; git reset | Out-Null; exit 1 }
Write-Host 'safety checks passed: no build output, logs or secrets' -ForegroundColor Green

$msg = Read-Host 'Commit message (Enter for default)'
if (-not $msg) { $msg = 'Dynamic data-controls system: .NET API, rule engine, Angular UI, Python AI advisor, SQL Server' }
git commit -m $msg
if ($LASTEXITCODE -ne 0 -and -not (git rev-parse --verify HEAD 2>$null)) { Write-Host 'STOP - the commit was not created (see the message above)' -ForegroundColor Red; exit 1 }
git log --oneline -1

$remote = (git remote 2>$null) -contains 'origin'
if (-not $remote) {
    $url = Read-Host 'Paste the GitHub repository URL (e.g. https://github.com/avigailro/data-controls.git)'
    git remote add origin $url.Trim()
}
git branch -M main
Write-Host 'pushing to GitHub (a sign-in window may open)...'
git push -u origin main
if ($LASTEXITCODE -ne 0) { Write-Host 'push failed - check the URL and that the GitHub repository is empty' -ForegroundColor Red; exit 1 }
Write-Host "done: $(git remote get-url origin)" -ForegroundColor Green
