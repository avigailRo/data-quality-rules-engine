@echo off
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\qa\gemini-probe.ps1"
echo.
pause
