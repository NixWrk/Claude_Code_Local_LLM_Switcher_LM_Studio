param([string]$StateRoot='')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try {
    # Only this disposable child process is changed, never the GUI environment.
    $inherited=[Environment]::GetEnvironmentVariables('Process')
    foreach ($group in @($inherited.Keys | Group-Object {([string]$_).ToUpperInvariant()} | Where-Object {$_.Count -gt 1})) {
        $name=[string]$group.Group[0];$value=[Environment]::GetEnvironmentVariable($name,'Process')
        foreach ($duplicate in $group.Group) {[Environment]::SetEnvironmentVariable([string]$duplicate,$null,'Process')}
        [Environment]::SetEnvironmentVariable($name,$value,'Process')
    }
    . (Join-Path $PSScriptRoot 'local_switcher_core.ps1')
    . (Join-Path $PSScriptRoot 'gui_workflow.ps1')
    Get-IsolatedAccountStatus $StateRoot -InChild | ConvertTo-Json -Compress
    exit 0
} catch {
    [pscustomobject]@{Error=$_.Exception.Message} | ConvertTo-Json -Compress
    exit 1
}
