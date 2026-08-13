Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Windows {
    if ($env:OS -ne 'Windows_NT') { throw 'These scripts currently support Windows only.' }
}

function ConvertTo-SafeProfileName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $trimmed = $Name.Trim()
    if ($trimmed -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'Profile name must be 1-64 characters and use only letters, numbers, dot, underscore, or dash.'
    }
    return $trimmed
}

function Get-DefaultProfilesRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_MULTI_ACCOUNT_ROOT)) { return $env:CODEX_MULTI_ACCOUNT_ROOT }
    return (Join-Path $env:LOCALAPPDATA 'CodexAccounts')
}

function Get-CodexProfileConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ProfilesRoot = (Get-DefaultProfilesRoot)
    )
    $safeName = ConvertTo-SafeProfileName $Name
    $profileDirectory = Join-Path $ProfilesRoot $safeName
    $configPath = Join-Path $profileDirectory 'profile.json'
    if (Test-Path -LiteralPath $configPath) {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        return [pscustomobject]@{
            Name = $safeName
            ProfileDirectory = $profileDirectory
            ConfigPath = $configPath
            CodexHome = [string]$config.codexHome
            VSCodeUserData = [string]$config.vscodeUserData
        }
    }
    return [pscustomobject]@{
        Name = $safeName
        ProfileDirectory = $profileDirectory
        ConfigPath = $configPath
        CodexHome = (Join-Path $profileDirectory 'codex-home')
        VSCodeUserData = (Join-Path $profileDirectory 'vscode-user-data')
    }
}

function Find-VSCodeExecutable {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe')) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\Code.exe')) }
    $candidates.Add('C:\PC\Visual_studio_code\Microsoft VS Code\Code.exe')
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    foreach ($commandName in @('code.cmd', 'code.exe', 'code')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    throw 'VS Code was not found. Install VS Code or add the code command to PATH.'
}

function Find-CodexCli {
    $extensionRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
    if (Test-Path -LiteralPath $extensionRoot) {
        $extensions = Get-ChildItem -LiteralPath $extensionRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'openai.chatgpt-*-win32-x64' } |
            Sort-Object -Property @{ Expression = 'LastWriteTime'; Descending = $true }, @{ Expression = 'Name'; Descending = $true }
        foreach ($extension in $extensions) {
            $candidate = Join-Path $extension.FullName 'bin\windows-x86_64\codex.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    foreach ($commandName in @('codex.exe', 'codex')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    throw 'Codex CLI was not found. Install or update the official OpenAI/Codex VS Code extension.'
}

function ConvertFrom-JwtPayload {
    param([AllowNull()][string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    while (($payload.Length % 4) -ne 0) { $payload += '=' }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

function Get-ShortFingerprint {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').Substring(0, 12)
    } finally { $sha.Dispose() }
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-CodexAuthSummary {
    param(
        [Parameter(Mandatory = $true)][string]$AuthPath,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $AuthPath)) {
        return [pscustomobject]@{ Profile=$Label; LoggedIn=$false; Email=$null; Name=$null; Fingerprint=$null; AuthUpdated=$null }
    }
    try {
        $authFile = Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json
        $tokens = Get-OptionalPropertyValue -InputObject $authFile -Name 'tokens'
        $idToken = ConvertFrom-JwtPayload (Get-OptionalPropertyValue -InputObject $tokens -Name 'id_token')
        $accessToken = ConvertFrom-JwtPayload (Get-OptionalPropertyValue -InputObject $tokens -Name 'access_token')
        $claims = @($idToken, $accessToken) | Where-Object { $null -ne $_ }
        $authClaims = $claims | ForEach-Object {
            Get-OptionalPropertyValue -InputObject $_ -Name 'https://api.openai.com/auth'
        } | Where-Object { $null -ne $_ }
        $profileClaims = $claims | ForEach-Object {
            Get-OptionalPropertyValue -InputObject $_ -Name 'https://api.openai.com/profile'
        } | Where-Object { $null -ne $_ }
        $email = @(
            $claims | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'email' }
            $profileClaims | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'email' }
        ) | Where-Object { $_ } | Select-Object -First 1
        $displayName = @(
            $claims | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'name' }
            $claims | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'nickname' }
            $claims | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'preferred_username' }
            $profileClaims | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'name' }
        ) | Where-Object { $_ } | Select-Object -First 1
        $accountId = @(
            Get-OptionalPropertyValue -InputObject $tokens -Name 'account_id'
            $authClaims | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'chatgpt_account_id' }
            $authClaims | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'account_id' }
        ) | Where-Object { $_ } | Select-Object -First 1
        return [pscustomobject]@{
            Profile=$Label
            LoggedIn=((Get-OptionalPropertyValue -InputObject $authFile -Name 'auth_mode') -eq 'chatgpt' -and $null -ne $tokens)
            Email=$email
            Name=$displayName
            Fingerprint=(Get-ShortFingerprint ([string]$accountId))
            AuthUpdated=(Get-Item -LiteralPath $AuthPath).LastWriteTime
        }
    } catch {
        return [pscustomobject]@{ Profile=$Label; LoggedIn=$true; Email='<unreadable>'; Name=$null; Fingerprint=$null; AuthUpdated=(Get-Item -LiteralPath $AuthPath).LastWriteTime }
    }
}

function Open-ChatGptSecurityPrivate {
    $url = 'https://chatgpt.com/#settings/Security'
    $browserCandidates = @(
        [pscustomobject]@{ Path='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; PrivateArgument='--inprivate' },
        [pscustomobject]@{ Path='C:\Program Files\Microsoft\Edge\Application\msedge.exe'; PrivateArgument='--inprivate' },
        [pscustomobject]@{ Path=(Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe'); PrivateArgument='--incognito' },
        [pscustomobject]@{ Path='C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'; PrivateArgument='--incognito' },
        [pscustomobject]@{ Path='C:\Program Files\Google\Chrome\Application\chrome.exe'; PrivateArgument='--incognito' }
    )
    foreach ($browser in $browserCandidates) {
        if (Test-Path -LiteralPath $browser.Path) {
            Start-Process -FilePath $browser.Path -ArgumentList @($browser.PrivateArgument, $url)
            return
        }
    }
    Start-Process $url
}
