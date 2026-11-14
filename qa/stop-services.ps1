# Stops the API (5080), the AI service (8000) and the Angular dev server (4200) started by run-qa.ps1
foreach ($port in 5080, 8000, 4200) {
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue; Write-Host "stopped process on port $port" }
}
# the venv python launcher keeps a parent process alive - stop any uvicorn of this project as well
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'uvicorn' -and $_.CommandLine -match 'app\.main:app' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "stopped AI service process $($_.ProcessId)" }
