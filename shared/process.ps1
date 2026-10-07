# Windows argument quoting and temporary process environment isolation.
function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW quoting, including trailing backslashes.
    return '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function Get-ProcessEnvironmentSnapshot {
    return [Environment]::GetEnvironmentVariables('Process')
}

function Restore-ProcessEnvironment {
    param($Snapshot)
    foreach ($key in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        if (-not $Snapshot.Contains($key)) { [Environment]::SetEnvironmentVariable($key,$null,'Process') }
    }
    foreach ($key in $Snapshot.Keys) { [Environment]::SetEnvironmentVariable($key,[string]$Snapshot[$key],'Process') }
}

function Set-AgentProcessEnvironment {
    param($Variables)
    # Clear routing and credentials for both agents before selecting this profile.
    foreach ($key in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        if ($key -match '^(ANTHROPIC_|CLAUDE_CODE_|CLAUDE_CONFIG_DIR$|OLLAMA_|LM_API_TOKEN$|DISABLE_COMPACT$|ENABLE_PROMPT_CACHING$|DISABLE_PROMPT_CACHING$|CODEX_HOME$|OPENAI_API_KEY$|OPENAI_BASE_URL$|LOCAL_SWITCHER_)') {
            [Environment]::SetEnvironmentVariable($key, $null, 'Process')
        }
    }
    foreach ($key in $Variables.Keys) {
        [Environment]::SetEnvironmentVariable($key, [string]$Variables[$key], 'Process')
    }
}
