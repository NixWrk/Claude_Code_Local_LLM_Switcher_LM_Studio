param([string]$StateRoot = '', [switch]$DryRun)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'local_switcher_core.ps1')
try {
    $paths=Get-StatePaths $StateRoot
    $targets=@((Join-Path $paths.Claude 'projects'),(Join-Path $paths.Claude 'history.jsonl'),
        (Join-Path $paths.Code 'User\workspaceStorage'),(Join-Path $paths.Code 'User\globalStorage'))
    # Resolve every target and reject reparse points before any recursive deletion.
    foreach ($target in $targets) {
        $absolute=[IO.Path]::GetFullPath($target)
        if (-not $absolute.StartsWith($paths.Root.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Chat target escaped the isolated state directory.'}
        $parent=$absolute
        while ($parent) {
            if (Test-Path -LiteralPath $parent) {
                if ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Chat reset does not follow junctions or symlinks.'}
            }
            $parent=Split-Path $parent -Parent
        }
        if (Test-Path -LiteralPath $absolute -PathType Container) {
            if (@(Get-ChildItem -LiteralPath $absolute -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count) {throw 'Chat reset does not follow junctions or symlinks.'}
        }
    }
    if ($DryRun) {$targets | ForEach-Object {Write-Output "Would remove: $_"};exit 0}
    try {$codeProcesses=@(Get-CimInstance Win32_Process -Filter "Name = 'Code.exe'")}
    catch {throw 'Cannot inspect running VS Code processes in this execution environment. Chats have not been cleared.'}
    $running=@($codeProcesses | Where-Object {
        $_.CommandLine -and ($_.CommandLine.IndexOf($paths.Code,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.CommandLine.IndexOf($paths.LoginCode,[StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
    if ($running.Count) {throw 'Close account B local/login VS Code windows before clearing chats.'}
    foreach ($target in $targets) {if (Test-Path -LiteralPath $target) {Remove-Item -LiteralPath $target -Recurse -Force}}
    Write-Output 'Account B local histories and VS Code chat caches cleared. Claude login credentials, bindings and project registrations retained.'
} catch {Write-Error $_ -ErrorAction Continue;exit 1}
exit 0
