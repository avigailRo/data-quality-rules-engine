@echo off
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\qa\run-llm-e2e.ps1" -Local
echo.
pause
