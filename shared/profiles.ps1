function ConvertTo-SafeProfileName {
    param([Parameter(Mandatory=$true)][string]$Name)
    $trimmed = $Name.Trim()
    if ($trimmed -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $trimmed.EndsWith('.') -or
        $trimmed -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw 'Profile name must be 1-64 letters, numbers, dots, underscores or dashes, and cannot be a Windows reserved name.'
    }
    return $trimmed
}

function Get-AgentProfilesRoot {
    param([ValidateSet('Claude','Codex')][string]$Agent)
    if ($Agent -eq 'Codex') {
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_MULTI_ACCOUNT_ROOT)) {
            return [IO.Path]::GetFullPath($env:CODEX_MULTI_ACCOUNT_ROOT)
        }
        return Join-Path $env:LOCALAPPDATA 'CodexAccounts'
    }
    return Join-Path $env:LOCALAPPDATA 'ClaudeLocalSwitcher'
}

function Assert-IsolatedStatePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An isolated state path is required.' }
    $absolute = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($protectedRoot in @(
        (Join-Path $env:USERPROFILE '.claude'),
        (Join-Path $env:USERPROFILE '.codex'),
        (Join-Path $env:APPDATA 'Code')
    )) {
        $protected = [IO.Path]::GetFullPath($protectedRoot).TrimEnd('\')
        if ($absolute.Equals($protected, [StringComparison]::OrdinalIgnoreCase) -or
            $absolute.StartsWith($protected + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Profile state must be separate from the main Claude, Codex and VS Code directories.'
        }
    }
}
