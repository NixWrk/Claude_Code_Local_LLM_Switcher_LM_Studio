param(
    [string]$BaseUrl = 'http://localhost:1234',
    [string]$AuthToken = 'lmstudio',
    [switch]$SkipVsCodeSettings,
    [switch]$SkipIsolatedVsCodeProfile
)

$ErrorActionPreference = 'Stop'

$isWindowsHost = ($env:OS -eq 'Windows_NT') -or ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
if (-not $isWindowsHost) {
    throw 'This setup script is for Windows only.'
}

function Set-Or-AddProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        $prop.Value = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Read-JsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{}
    }

    $raw = [System.IO.File]::ReadAllText($Path)
    if (-not $raw.Trim()) {
        return [pscustomobject]@{}
    }

    try {
        return ($raw | ConvertFrom-Json)
    }
    catch {
        throw "Invalid JSON in $Path"
    }
}

function Write-JsonObjectNoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Object
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth 50
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

Write-Output '[1/5] Checking LM Studio CLI (lms)...'
$lmsCmd = Get-Command lms -ErrorAction SilentlyContinue
if (-not $lmsCmd) {
    throw "LM Studio CLI 'lms' was not found in PATH."
}
Write-Output ("  lms: {0}" -f $lmsCmd.Source)

Write-Output '[2/5] Updating ~/.claude/settings.json...'
$claudeSettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$claudeSettings = Read-JsonObject -Path $claudeSettingsPath
if (-not ($claudeSettings.PSObject.Properties.Name -contains 'env')) {
    Set-Or-AddProperty -Object $claudeSettings -Name 'env' -Value ([pscustomobject]@{})
}

Set-Or-AddProperty -Object $claudeSettings.env -Name 'ANTHROPIC_BASE_URL' -Value $BaseUrl
Set-Or-AddProperty -Object $claudeSettings.env -Name 'ANTHROPIC_AUTH_TOKEN' -Value $AuthToken
Set-Or-AddProperty -Object $claudeSettings.env -Name 'CLAUDE_CODE_ATTRIBUTION_HEADER' -Value '0'

# Remove known-corrupt model values like "sonnet[1m]" if they appear.
if ($claudeSettings.PSObject.Properties.Name -contains 'model') {
    $modelValue = [string]$claudeSettings.model
    if ($modelValue -match '\[[0-9;]*m\]?$') {
        $claudeSettings.PSObject.Properties.Remove('model')
        Write-Output "  Removed suspicious model value from ~/.claude/settings.json: $modelValue"
    }
}

Write-JsonObjectNoBom -Path $claudeSettingsPath -Object $claudeSettings
Write-Output "  updated: $claudeSettingsPath"

if (-not $SkipVsCodeSettings) {
    Write-Output '[3/5] Updating VS Code user settings...'
    $vsCodeSettingsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
    $vsCodeSettings = Read-JsonObject -Path $vsCodeSettingsPath

    $envVars = @(
        [pscustomobject]@{ name = 'ANTHROPIC_BASE_URL'; value = $BaseUrl },
        [pscustomobject]@{ name = 'ANTHROPIC_AUTH_TOKEN'; value = $AuthToken }
    )
    Set-Or-AddProperty -Object $vsCodeSettings -Name 'claudeCode.environmentVariables' -Value $envVars
    Set-Or-AddProperty -Object $vsCodeSettings -Name 'claudeCode.disableLoginPrompt' -Value $true

    Write-JsonObjectNoBom -Path $vsCodeSettingsPath -Object $vsCodeSettings
    Write-Output "  updated: $vsCodeSettingsPath"
}
else {
    Write-Output '[3/5] Skipping VS Code settings (requested).'
}

Write-Output '[4/5] Checking endpoint health...'
try {
    $modelsUrl = "$BaseUrl/v1/models"
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $modelsUrl -Method Get -TimeoutSec 15
    Write-Output ("  endpoint ok: {0} (HTTP {1})" -f $modelsUrl, $resp.StatusCode)
}
catch {
    Write-Output "  warning: endpoint check failed for $BaseUrl/v1/models"
    Write-Output "  details: $($_.Exception.Message)"
}

if (-not $SkipIsolatedVsCodeProfile) {
    Write-Output '[5/5] Preparing isolated VS Code local profile settings...'
    $isolatedUserDataDir = Join-Path $PSScriptRoot '.vscode-local-userdata'
    $isolatedSettingsPath = Join-Path $isolatedUserDataDir 'User\settings.json'
    $isolatedSettings = Read-JsonObject -Path $isolatedSettingsPath
    $isolatedEnvVars = @(
        [pscustomobject]@{ name = 'ANTHROPIC_BASE_URL'; value = $BaseUrl },
        [pscustomobject]@{ name = 'ANTHROPIC_AUTH_TOKEN'; value = $AuthToken }
    )
    Set-Or-AddProperty -Object $isolatedSettings -Name 'claudeCode.environmentVariables' -Value $isolatedEnvVars
    Set-Or-AddProperty -Object $isolatedSettings -Name 'claudeCode.disableLoginPrompt' -Value $true
    Write-JsonObjectNoBom -Path $isolatedSettingsPath -Object $isolatedSettings
    Write-Output "  prepared: $isolatedSettingsPath"
}
else {
    Write-Output '[5/5] Skipping isolated VS Code profile prep (requested).'
}

Write-Output ''
Write-Output 'Setup complete.'
Write-Output 'Next steps:'
Write-Output '1) Start LM Studio Local Server on the configured BaseUrl.'
Write-Output '2) For isolated local-only mode run: run_local_vscode.cmd'
Write-Output '3) In switcher GUI, bind sonnet/opus/haiku to loaded local models.'
Write-Output '4) Test a short prompt in Claude Code chat.'
