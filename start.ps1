<#
.SYNOPSIS
  One command to set up and run the whole system locally (Windows):
    1. checks prerequisites (.NET 10, Node.js, Python 3.12, SQL Server)
    2. creates the DataControls database with sample data - only if it does not exist yet
    3. installs Python and npm dependencies - only the first time
    4. starts the API, the AI recommendation service and the Angular UI, and opens the browser

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 [-Server .\SQLEXPRESS]
  (or double-click start.cmd)
  Stop everything with: qa\stop-services.cmd
#>
param([string]$Server = '.\SQLEXPRESS')
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$logs = Join-Path $root 'qa'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
function Step([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Fail([string]$t) { Write-Host "STOP: $t" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 1. prerequisites
Step 'Checking prerequisites'
foreach ($t in @(@('dotnet', '--version', '.NET SDK 10'), @('node', '-v', 'Node.js 20.19+'), @('python', '--version', 'Python 3.12'))) {
    $v = & $t[0] $t[1] 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v) { Fail "$($t[2]) is not installed (command '$($t[0])' not found)" }
    Write-Host "  $($t[0]): $v"
}

# ---------------------------------------------------------------- 2. database
Step "Database on $Server"
function New-Conn([string]$db) {
    $c = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=$db;Integrated Security=True;TrustServerCertificate=True;Pooling=False")
    $c.Open(); return $c
}
try { $c = New-Conn 'master'; $cmd = $c.CreateCommand(); $cmd.CommandText = "SELECT DB_ID(N'DataControls')"; $exists = $cmd.ExecuteScalar(); $c.Close() }
catch { Fail "cannot connect to SQL Server '$Server' with Windows Authentication. Use -Server <name> if your instance is different." }
if ($exists -is [DBNull] -or $null -eq $exists) {
    Write-Host '  creating DataControls with sample data...'
    foreach ($f in Get-ChildItem (Join-Path $root 'db') -Filter '0*.sql' | Sort-Object Name) {
        $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $c = New-Conn 'master'
        try {
            foreach ($b in ([regex]::Split($text, '(?im)^\s*GO\s*$') | Where-Object { $_.Trim() })) {
                $cmd = $c.CreateCommand(); $cmd.CommandText = $b; $cmd.CommandTimeout = 300; [void]$cmd.ExecuteNonQuery()
            }
            Write-Host "  ok  $($f.Name)"
        } catch { Fail "$($f.Name): $($_.Exception.Message)" } finally { $c.Close() }
    }
} else { Write-Host '  DataControls already exists - kept as is (db\reset.ps1 recreates it)' }
$connString = "Server=$Server;Database=DataControls;Trusted_Connection=True;TrustServerCertificate=True;Encrypt=False"

# ---------------------------------------------------------------- 3. dependencies (first run only)
Step 'Dependencies'
$aiDir = Join-Path $root 'ai-service'
$py = Join-Path $aiDir '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) {
    Write-Host '  creating Python virtual environment and installing packages...'
    Push-Location $aiDir; python -m venv .venv; & $py -m pip install -q -r requirements.txt; Pop-Location
    if ($LASTEXITCODE -ne 0) { Fail 'pip install failed' }
} else { Write-Host '  Python packages: already installed' }
$fe = Join-Path $root 'frontend'
if (-not (Test-Path (Join-Path $fe 'node_modules'))) {
    Write-Host '  installing npm packages (a few minutes the first time)...'
    Push-Location $fe; npm.cmd install --no-audit --no-fund; Pop-Location
    if ($LASTEXITCODE -ne 0) { Fail 'npm install failed' }
} else { Write-Host '  npm packages: already installed' }

# ---------------------------------------------------------------- 4. start services
Step 'Starting services'
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'uvicorn' -and $_.CommandLine -match 'app\.main:app' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
foreach ($port in 5080, 8000, 4200) {
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Seconds 2
function Get-FreePort([int]$preferred, [int]$from) {
    if (@(Get-NetTCPConnection -LocalPort $preferred -State Listen -ErrorAction SilentlyContinue).Count -eq 0) { return $preferred }
    foreach ($p in $from..($from + 30)) { if (@(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue).Count -eq 0) { return $p } }
    return $preferred
}
function Wait-Url([string]$url, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) { try { if ((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) { return $true } } catch {}; Start-Sleep 1 }
    return $false
}
$apiPort = Get-FreePort 5080 5090; $aiPort = Get-FreePort 8000 8010; $webPort = Get-FreePort 4200 4210
$api = "http://localhost:$apiPort"

# AI service: local analysis by default (an LLM is enabled only through DQ_LLM_* environment variables, see README)
$env:DQ_DB_SERVER = $Server
Start-Process -FilePath $py -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--port', "$aiPort") -WorkingDirectory $aiDir -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $logs 'demo-ai.out.log') -RedirectStandardError (Join-Path $logs 'demo-ai.err.log') | Out-Null
Write-Host "  AI service  -> http://127.0.0.1:$aiPort"

$apiProj = Join-Path $root 'backend\src\DataControls.Api'
Start-Process -FilePath 'dotnet' -ArgumentList @('run', '--project', "`"$apiProj`"", '--', '--urls', $api,
    "--Advisor:BaseUrl=http://127.0.0.1:$aiPort", "`"--Database:ConnectionString=$connString`"") -WorkingDirectory $apiProj -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $logs 'demo-api.out.log') -RedirectStandardError (Join-Path $logs 'demo-api.err.log') | Out-Null
Write-Host "  API         -> $api   (the first start builds the backend, ~30-60s)"

$webArgs = @('ng', 'serve', '--port', "$webPort")
if ($apiPort -ne 5080) {
    $proxyFile = Join-Path $logs 'proxy.qa.json'
    Set-Content $proxyFile ('{ "/api": { "target": "' + $api + '", "secure": false, "changeOrigin": true } }') -Encoding ASCII
    $webArgs += @('--proxy-config', "`"$proxyFile`"")
}
Start-Process -FilePath 'npx.cmd' -ArgumentList $webArgs -WorkingDirectory $fe -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $logs 'demo-web.out.log') -RedirectStandardError (Join-Path $logs 'demo-web.err.log') | Out-Null
Write-Host "  UI          -> http://localhost:$webPort"

Step 'Waiting for the services'
$apiUp = Wait-Url "$api/health/ready" 180
$webUp = Wait-Url "http://localhost:$webPort/" 180
Write-Host ('  API: ' + $(if ($apiUp) { 'running' } else { 'NOT running - see qa\demo-api.err.log / demo-api.out.log' }))
Write-Host ('  UI:  ' + $(if ($webUp) { 'running' } else { 'NOT running - see qa\demo-web.err.log' }))
if ($apiUp -and $webUp) {
    Start-Process "http://localhost:$webPort/"
    Write-Host ''
    Write-Host "Ready: http://localhost:$webPort  (opened in your browser)" -ForegroundColor Green
}
Write-Host 'Stop everything with qa\stop-services.cmd'
