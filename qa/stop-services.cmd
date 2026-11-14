@echo off
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\qa\stop-services.ps1" 
echo.
pause
