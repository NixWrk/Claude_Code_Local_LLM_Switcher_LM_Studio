@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reset_local_chats.ps1" %*
exit /b %errorlevel%
