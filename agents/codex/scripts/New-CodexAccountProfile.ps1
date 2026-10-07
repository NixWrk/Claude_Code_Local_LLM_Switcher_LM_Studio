[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$ProfilesRoot,
    [string]$CodexHome,
    [string]$VSCodeUserData,
    [switch]$CopyVsCodeSettings,
    [switch]$CreateDesktopShortcuts
)

. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Windows
if ([string]::IsNullOrWhiteSpace($ProfilesRoot)) { $ProfilesRoot = Get-DefaultProfilesRoot }

$safeName = ConvertTo-SafeProfileName $Name
$defaults = Get-CodexProfileConfig -Name $safeName -ProfilesRoot $ProfilesRoot
if ([string]::IsNullOrWhiteSpace($CodexHome)) { $CodexHome = $defaults.CodexHome }
if ([string]::IsNullOrWhiteSpace($VSCodeUserData)) { $VSCodeUserData = $defaults.VSCodeUserData }

Assert-IsolatedStatePath $CodexHome
Assert-IsolatedStatePath $VSCodeUserData

$null = Find-VSCodeExecutable
$null = Find-CodexCli
New-Item -ItemType Directory -Force -Path $defaults.ProfileDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $VSCodeUserData 'User') | Out-Null

$profile = [ordered]@{
    version = 1
    name = $safeName
    codexHome = [IO.Path]::GetFullPath($CodexHome)
    vscodeUserData = [IO.Path]::GetFullPath($VSCodeUserData)
    createdOrUpdated = (Get-Date).ToString('o')
}
Write-JsonFile $defaults.ConfigPath ([pscustomobject]$profile)

if ($CopyVsCodeSettings) {
    $sourceUser = Join-Path $env:APPDATA 'Code\User'
    $destinationUser = Join-Path $VSCodeUserData 'User'
    foreach ($fileName in @('settings.json', 'keybindings.json')) {
        $source = Join-Path $sourceUser $fileName
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $destinationUser $fileName) -Force }
    }
    $sourceSnippets = Join-Path $sourceUser 'snippets'
    if (Test-Path -LiteralPath $sourceSnippets) { Copy-Item -LiteralPath $sourceSnippets -Destination $destinationUser -Recurse -Force }
}

if ($CreateDesktopShortcuts) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $powerShell = (Get-Command powershell.exe).Source
    $codeExe = Find-VSCodeExecutable
    $shell = New-Object -ComObject WScript.Shell

    $startScript = Join-Path $PSScriptRoot 'Start-VSCodeCodexProfile.ps1'
    $startShortcut = $shell.CreateShortcut((Join-Path $desktop ("VS Code Codex ({0}).lnk" -f $safeName)))
    $startShortcut.TargetPath = $powerShell
    $startShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`" -Name `"$safeName`" -ProfilesRoot `"$ProfilesRoot`""
    $startShortcut.WorkingDirectory = $env:USERPROFILE
    $startShortcut.IconLocation = "$codeExe,0"
    $startShortcut.Save()

    $loginScript = Join-Path $PSScriptRoot 'Login-CodexAccountProfile.ps1'
    $loginShortcut = $shell.CreateShortcut((Join-Path $desktop ("Login Codex ({0}).lnk" -f $safeName)))
    $loginShortcut.TargetPath = $powerShell
    $loginShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$loginScript`" -Name `"$safeName`" -ProfilesRoot `"$ProfilesRoot`""
    $loginShortcut.WorkingDirectory = $env:USERPROFILE
    $loginShortcut.IconLocation = "$codeExe,0"
    $loginShortcut.Save()
}

Write-Host "Profile '$safeName' is ready." -ForegroundColor Green
Write-Host "CODEX_HOME: $CodexHome"
Write-Host "VS Code data: $VSCodeUserData"
Write-Host "Next: run Login-CodexAccountProfile.ps1 -Name $safeName"
