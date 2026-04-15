param(
    [string]$WorkspacePath = (Get-Location).Path,
    [string]$BaseUrl = 'http://localhost:1234',
    [string]$AuthToken = 'lmstudio',
    [string]$UserDataDir = '',
    [switch]$ResetIsolatedSession
)

$ErrorActionPreference = 'Stop'

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

    if (-not (Test-Path -LiteralPath $Path)) {
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
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth 50
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Resolve-VsCodeCommand {
    $codeCmd = Get-Command code -ErrorAction SilentlyContinue
    if ($codeCmd) {
        return $codeCmd.Source
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path ${env:ProgramFiles} 'Microsoft VS Code\bin\code.cmd')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw "VS Code CLI 'code' was not found. Install VS Code and ensure 'code' command is available."
}

if (-not $UserDataDir) {
    $UserDataDir = Join-Path $PSScriptRoot '.vscode-local-userdata'
}

$UserDataDir = [System.IO.Path]::GetFullPath($UserDataDir)
$WorkspacePath = [System.IO.Path]::GetFullPath($WorkspacePath)

$settingsPath = Join-Path $UserDataDir 'User\settings.json'
$settings = Read-JsonObject -Path $settingsPath
$envVars = @(
    [pscustomobject]@{ name = 'ANTHROPIC_BASE_URL'; value = $BaseUrl },
    [pscustomobject]@{ name = 'ANTHROPIC_AUTH_TOKEN'; value = $AuthToken }
)

Set-Or-AddProperty -Object $settings -Name 'claudeCode.environmentVariables' -Value $envVars
Set-Or-AddProperty -Object $settings -Name 'claudeCode.disableLoginPrompt' -Value $true

Write-JsonObjectNoBom -Path $settingsPath -Object $settings
Write-Output "updated: $settingsPath"

if ($ResetIsolatedSession) {
    $globalStoragePath = Join-Path $UserDataDir 'User\globalStorage'
    $workspaceStoragePath = Join-Path $UserDataDir 'User\workspaceStorage'
    if (Test-Path -LiteralPath $globalStoragePath) {
        Get-ChildItem -LiteralPath $globalStoragePath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'claude|anthropic' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $workspaceStoragePath) {
        Get-ChildItem -LiteralPath $workspaceStoragePath -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'claude|anthropic' } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            }
    }
    Write-Output "isolated Claude/Anthropic session cache reset under: $UserDataDir"
}

$codeExe = Resolve-VsCodeCommand
$args = @('--user-data-dir', $UserDataDir, '--profile', 'Claude Local LM Studio', $WorkspacePath)

Write-Output "launching VS Code local profile..."
Write-Output "code command: $codeExe"
Write-Output "user-data-dir: $UserDataDir"
Write-Output "workspace: $WorkspacePath"

Start-Process -FilePath $codeExe -ArgumentList $args | Out-Null
Write-Output 'done.'
