@echo off
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\qa\run-qa.ps1" 
echo.
pause
