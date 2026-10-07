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
if (-not (Get-CodexAuthSummary -AuthPath $authPath -Label $profile.Name).LoggedIn) {
    if ($NoLogin) { throw "Profile '$Name' is not signed in." }
    $loginScript = Join-Path $PSScriptRoot 'Login-CodexAccountProfile.ps1'
    & $loginScript -Name $profile.Name -ProfilesRoot $ProfilesRoot
    if (-not (Get-CodexAuthSummary -AuthPath $authPath -Label $profile.Name).LoggedIn) { throw "Profile '$Name' is still not signed in." }
}

$codeExe = Find-VSCodeExecutable
$extensionRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
$arguments = @('--user-data-dir', $profile.VSCodeUserData, '--extensions-dir', $extensionRoot, '--new-window')
if (-not [string]::IsNullOrWhiteSpace($Path)) { $arguments += [IO.Path]::GetFullPath($Path) }

$environmentSnapshot = Get-ProcessEnvironmentSnapshot
$launchProcess = $null
try {
    Set-AgentProcessEnvironment ([ordered]@{CODEX_HOME=$profile.CodexHome})
    $launchProcess = Start-CodeCli $codeExe $arguments
    if (-not $launchProcess.WaitForExit(30000)) { throw 'VS Code did not acknowledge the launch command within 30 seconds.' }
    if ($launchProcess.ExitCode -ne 0) { throw 'VS Code rejected the profile launch command.' }
} finally {
    Restore-ProcessEnvironment $environmentSnapshot
    if ($launchProcess) { $launchProcess.Dispose() }
}
Write-Host "Started isolated VS Code profile '$($profile.Name)'." -ForegroundColor Green
