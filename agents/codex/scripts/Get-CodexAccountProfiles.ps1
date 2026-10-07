[CmdletBinding()]
param([string]$ProfilesRoot)

. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Windows
if ([string]::IsNullOrWhiteSpace($ProfilesRoot)) { $ProfilesRoot = Get-DefaultProfilesRoot }

$results = New-Object System.Collections.Generic.List[object]
$defaultAuth = Join-Path $env:USERPROFILE '.codex\auth.json'
$defaultSummary = Get-CodexAuthSummary -AuthPath $defaultAuth -Label 'Desktop/default'
$defaultSummary | Add-Member -NotePropertyName Running -NotePropertyValue $null
$results.Add($defaultSummary)

if (Test-Path -LiteralPath $ProfilesRoot) {
    $profileFiles = Get-ChildItem -LiteralPath $ProfilesRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'profile.json' } | Where-Object { Test-Path -LiteralPath $_ }
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Code.exe' }
    foreach ($profileFile in $profileFiles) {
        $stored = Get-Content -LiteralPath $profileFile -Raw | ConvertFrom-Json
        $summary = Get-CodexAuthSummary -AuthPath (Join-Path ([string]$stored.codexHome) 'auth.json') -Label ([string]$stored.name)
        $isRunning = [bool]($processes | Where-Object { $_.CommandLine -like ("*{0}*" -f [string]$stored.vscodeUserData) })
        $summary | Add-Member -NotePropertyName Running -NotePropertyValue $isRunning
        $results.Add($summary)
    }
}

$results | Sort-Object Profile | Format-Table Profile, LoggedIn, Running, Email, Name, Fingerprint, AuthUpdated -AutoSize
$duplicates = $results | Where-Object { $_.Fingerprint } | Group-Object Fingerprint | Where-Object { $_.Count -gt 1 }
foreach ($duplicate in $duplicates) {
    $names = ($duplicate.Group | ForEach-Object { $_.Profile }) -join ', '
    Write-Warning "These profiles use the same ChatGPT account: $names"
}
