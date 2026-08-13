@echo off
setlocal

set "CODEX_HOME=C:\Users\ELVIS_NIX\AppData\Local\Codex-Account-B\codex-home"
set "CODEX_ACCOUNT_B_CLI=C:\Users\ELVIS_NIX\.vscode\extensions\openai.chatgpt-26.727.40816-win32-x64\bin\windows-x86_64\codex.exe"

echo Signing in to isolated Codex Account B.
echo This uses device authorization so you can choose the correct browser profile manually.
echo.
"%CODEX_ACCOUNT_B_CLI%" login --device-auth
echo.
if errorlevel 1 (
  echo Sign-in did not complete. You can run this shortcut again.
) else (
  echo Account B sign-in completed. Launch "VS Code - Account B" from the desktop.
)
echo.
pause

endlocal
