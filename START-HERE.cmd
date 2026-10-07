@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
exit /b %errorlevel%
