[CmdletBinding()]
param(
    [ValidateSet('Claude','Codex')][string]$Agent,
    [ValidateSet('Menu','Gui','Prepare','Create','Login','Start','Status','ResetChats')][string]$Action='Menu',
    [string]$Name='', [string]$ProfilesRoot='', [string]$StateRoot='', [string]$WorkspacePath='',
    [switch]$Force, [switch]$CopyVsCodeSettings, [switch]$CreateDesktopShortcuts, [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'manager.ps1')
try {
    if ($Action -ne 'Menu') {
        if (-not $Agent) { throw 'Choose -Agent Claude or -Agent Codex.' }
        $parameters = @{}
        foreach ($key in $PSBoundParameters.Keys) { if ($key -ne 'DryRun') { $parameters[$key] = $PSBoundParameters[$key] } }
        $command = Get-ManagerCommand @parameters
        if ($DryRun) { $command | ConvertTo-Json -Depth 5; exit 0 }
        exit (Invoke-ManagerCommand $command)
    }
    if ($DryRun) { throw 'Choose an -Agent and -Action to inspect a command.' }
    if ($Name -or $ProfilesRoot -or $StateRoot -or $WorkspacePath -or $Force -or $CopyVsCodeSettings -or $CreateDesktopShortcuts) {
        throw 'Profile options require an explicit -Action.'
    }
    if ($Agent) { Show-AgentMenu $Agent; exit 0 }
    while ($true) {
        Write-Host "`nAI Workspace Manager" -ForegroundColor Cyan
        Write-Host '1. Claude Code - локальные модели и профили'
        Write-Host '2. Codex - профили аккаунтов'
        Write-Host '0. Выход'
        switch (Read-Host 'Выберите инструмент') {
            '1' { Show-AgentMenu Claude }
            '2' { Show-AgentMenu Codex }
            '0' { exit 0 }
        }
    }
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }
