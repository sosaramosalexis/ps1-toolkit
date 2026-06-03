@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps1-toolkit.ps1" -Interactive -Elevate -KeepOpen
