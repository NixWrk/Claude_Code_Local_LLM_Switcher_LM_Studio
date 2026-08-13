@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0scripts"
:menu
cls
echo Codex multi-account manager
echo.
echo   1. Create an isolated VS Code profile
echo   2. Sign in or switch the account for a profile
echo   3. Start VS Code with an isolated profile
echo   4. Show account status
echo   0. Exit
echo.
choice /c 12340 /n /m "Choose: "
if errorlevel 5 goto end
if errorlevel 4 goto status
if errorlevel 3 goto start
if errorlevel 2 goto login
if errorlevel 1 goto create
:create
set "PROFILE_NAME="
set /p "PROFILE_NAME=Profile name (for example work or personal): "
if not defined PROFILE_NAME goto menu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\New-CodexAccountProfile.ps1" -Name "%PROFILE_NAME%" -CopyVsCodeSettings -CreateDesktopShortcuts
pause
goto menu
:login
set "PROFILE_NAME="
set /p "PROFILE_NAME=Profile name: "
if not defined PROFILE_NAME goto menu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Login-CodexAccountProfile.ps1" -Name "%PROFILE_NAME%" -Force
pause
goto menu
:start
set "PROFILE_NAME="
set /p "PROFILE_NAME=Profile name: "
if not defined PROFILE_NAME goto menu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Start-VSCodeCodexProfile.ps1" -Name "%PROFILE_NAME%"
pause
goto menu
:status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Get-CodexAccountProfiles.ps1"
pause
goto menu
:end
endlocal
