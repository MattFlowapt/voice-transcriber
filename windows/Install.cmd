@echo off
rem Double-click to install Voice Transcriber. Runs install.ps1 without changing
rem the machine's PowerShell policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
