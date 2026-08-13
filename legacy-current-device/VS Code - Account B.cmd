@echo off
setlocal

set "CODEX_HOME=C:\Users\ELVIS_NIX\AppData\Local\Codex-Account-B\codex-home"
set "CODEX_ACCOUNT_B_USER_DATA=C:\Users\ELVIS_NIX\AppData\Local\Codex-Account-B\vscode-user-data"

if not exist "%CODEX_HOME%\auth.json" (
  start "" "%~dp0Login Codex Account B.cmd"
  exit /b 0
)

start "" "C:\PC\Visual_studio_code\Microsoft VS Code\Code.exe" ^
  --user-data-dir "%CODEX_ACCOUNT_B_USER_DATA%" ^
  --extensions-dir "C:\Users\ELVIS_NIX\.vscode\extensions" ^
  %*

endlocal
