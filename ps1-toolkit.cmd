@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps1-toolkit.ps1" -Interactive -KeepOpen
