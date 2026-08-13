[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$ProfilesRoot
)
$loginScript = Join-Path $PSScriptRoot 'Login-CodexAccountProfile.ps1'
$arguments = @{ Name = $Name; Force = $true }
if (-not [string]::IsNullOrWhiteSpace($ProfilesRoot)) { $arguments.ProfilesRoot = $ProfilesRoot }
& $loginScript @arguments
