# Recreates the demo database from scratch.
# Usage:  .\db\reset.ps1                (default server .\SQLEXPRESS, Windows authentication)
#         .\db\reset.ps1 -Server "(localdb)\MSSQLLocalDB"
param([string]$Server = ".\SQLEXPRESS")

$ErrorActionPreference = "Stop"
$files = Get-ChildItem -Path $PSScriptRoot -Filter "0*.sql" | Sort-Object Name

$sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
if (-not $sqlcmd) {
    Write-Host "sqlcmd was not found on PATH." -ForegroundColor Yellow
    Write-Host "Alternative: open db\setup_all.sql in SSMS, connect to $Server and press F5." -ForegroundColor Yellow
    exit 1
}

foreach ($f in $files) {
    Write-Host "Running $($f.Name) ..."
    # -f 65001 = read the script as UTF-8 (Hebrew text)
    & sqlcmd -S $Server -E -C -b -f 65001 -i $f.FullName
    if ($LASTEXITCODE -ne 0) { throw "Script failed: $($f.Name)" }
}
Write-Host "Database DataControls is ready." -ForegroundColor Green
