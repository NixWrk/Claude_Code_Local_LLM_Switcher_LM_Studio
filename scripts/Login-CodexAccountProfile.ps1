[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$ProfilesRoot,
    [switch]$Force,
    [switch]$SkipSecurityPage
)

. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Windows
if ([string]::IsNullOrWhiteSpace($ProfilesRoot)) { $ProfilesRoot = Get-DefaultProfilesRoot }

$profile = Get-CodexProfileConfig -Name $Name -ProfilesRoot $ProfilesRoot
if (-not (Test-Path -LiteralPath $profile.ConfigPath)) { throw "Profile '$Name' does not exist. Create it first." }
New-Item -ItemType Directory -Force -Path $profile.CodexHome | Out-Null
$authPath = Join-Path $profile.CodexHome 'auth.json'

if ((Test-Path -LiteralPath $authPath) -and -not $Force) {
    Get-CodexAuthSummary -AuthPath $authPath -Label $profile.Name | Format-List
    Write-Host 'This profile is already signed in. Use -Force to replace its account.' -ForegroundColor Yellow
    exit 0
}

$cli = Find-CodexCli
$previousCodexHome = $env:CODEX_HOME
try {
    $env:CODEX_HOME = $profile.CodexHome
    if ($Force -and (Test-Path -LiteralPath $authPath)) {
        & $cli logout
        if ($LASTEXITCODE -ne 0) { throw 'Codex logout failed.' }
    }
    if (-not $SkipSecurityPage) { Open-ChatGptSecurityPrivate }
    Write-Host ''
    Write-Host "Signing in profile '$($profile.Name)' with device authorization." -ForegroundColor Cyan
    Write-Host 'In the private browser window, sign in to the TARGET ChatGPT account.'
    Write-Host 'Enable Codex device-code authorization in ChatGPT Security settings if requested.'
    Write-Host ''
    & $cli login --device-auth
    if ($LASTEXITCODE -ne 0) { throw 'Codex device authorization did not complete.' }
} finally {
    if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $previousCodexHome }
}

if (-not (Test-Path -LiteralPath $authPath)) { throw 'Login succeeded, but the isolated auth.json was not created.' }
Write-Host ''
Write-Host 'Sign-in completed:' -ForegroundColor Green
Get-CodexAuthSummary -AuthPath $authPath -Label $profile.Name | Format-List
