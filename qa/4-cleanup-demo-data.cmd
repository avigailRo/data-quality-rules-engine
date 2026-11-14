@echo off
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\qa\cleanup-demo-data.ps1"
echo.
pause
