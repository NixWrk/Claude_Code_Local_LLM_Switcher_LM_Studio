@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_claude_local_vscode.ps1" %*
exit /b %errorlevel%
