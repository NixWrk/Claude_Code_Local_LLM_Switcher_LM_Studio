[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$ProfilesRoot,
    [string]$Path,
    [switch]$NoLogin
)

. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Windows
if ([string]::IsNullOrWhiteSpace($ProfilesRoot)) { $ProfilesRoot = Get-DefaultProfilesRoot }

$profile = Get-CodexProfileConfig -Name $Name -ProfilesRoot $ProfilesRoot
if (-not (Test-Path -LiteralPath $profile.ConfigPath)) { throw "Profile '$Name' does not exist. Create it first." }
$authPath = Join-Path $profile.CodexHome 'auth.json'
if (-not (Test-Path -LiteralPath $authPath)) {
    if ($NoLogin) { throw "Profile '$Name' is not signed in." }
    $loginScript = Join-Path $PSScriptRoot 'Login-CodexAccountProfile.ps1'
    & $loginScript -Name $profile.Name -ProfilesRoot $ProfilesRoot
    if (-not (Test-Path -LiteralPath $authPath)) { throw "Profile '$Name' is still not signed in." }
}

$codeExe = Find-VSCodeExecutable
$extensionRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
$arguments = @('--user-data-dir', ('"{0}"' -f $profile.VSCodeUserData), '--extensions-dir', ('"{0}"' -f $extensionRoot), '--new-window')
if (-not [string]::IsNullOrWhiteSpace($Path)) { $arguments += ('"{0}"' -f [IO.Path]::GetFullPath($Path)) }

$previousCodexHome = $env:CODEX_HOME
try {
    $env:CODEX_HOME = $profile.CodexHome
    Start-Process -FilePath $codeExe -ArgumentList $arguments
} finally {
    if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $previousCodexHome }
}
Write-Host "Started isolated VS Code profile '$($profile.Name)'." -ForegroundColor Green
