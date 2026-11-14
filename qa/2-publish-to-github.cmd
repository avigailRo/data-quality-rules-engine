@echo off
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\qa\publish-git.ps1"
echo.
pause
