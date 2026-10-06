@echo off
setlocal
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0lmstudio_alias_switcher_gui.ps1" %*
exit /b %errorlevel%
