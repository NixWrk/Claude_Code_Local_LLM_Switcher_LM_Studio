[CmdletBinding()]
param([switch]$SkipGui)
$ErrorActionPreference='Stop'
$shell=(Get-Process -Id $PID).Path
$suites=@('tests\shared\test_manager.ps1','tests\codex\test_profiles.ps1','tests\claude\test_core.ps1','tests\claude\test_runtime_control.ps1')
if (-not $SkipGui) { $suites+='tests\claude\test_gui_workflow.ps1' }
foreach ($suite in $suites) {
    & $shell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $suite)
    if ($LASTEXITCODE -ne 0) { throw "Test suite failed: $suite" }
}
if ($SkipGui) {
    & python -m unittest discover -s (Join-Path $PSScriptRoot 'tests\claude') -p test_bridge.py -v
} else {
    & python -m unittest discover -s (Join-Path $PSScriptRoot 'tests\claude') -p 'test_*.py' -v
}
if ($LASTEXITCODE -ne 0) { throw 'Python test suite failed.' }
Write-Output 'PASS: all selected test suites.'
