Set-StrictMode -Version 2.0
$sharedRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'shared'
. (Join-Path $sharedRoot 'json.ps1')
. (Join-Path $sharedRoot 'profiles.ps1')
. (Join-Path $sharedRoot 'vscode.ps1')

function Get-StatePaths {
    param([string]$StateRoot = '')
    if (-not $StateRoot) { $StateRoot = Join-Path (Get-AgentProfilesRoot Claude) 'account-b' }
    $root = [IO.Path]::GetFullPath($StateRoot)
    Assert-IsolatedStatePath $root
    [pscustomobject]@{
        Root = $root; Name = (Split-Path $root -Leaf); Config = (Join-Path $root 'switcher.json')
        Claude = (Join-Path $root 'claude'); Code = (Join-Path $root 'vscode-local')
        LoginCode = (Join-Path $root 'vscode-login'); Extensions = (Join-Path $root 'extensions')
    }
}

function Get-SwitcherConfig {
    param([string]$StateRoot = '')
    $paths = Get-StatePaths $StateRoot
    $config = Read-JsonFile $paths.Config
    if (-not (Get-Field $config 'schemaVersion')) { Set-Field $config 'schemaVersion' 1 }
    if (-not (Get-Field $config 'provider')) {
        Set-Field $config 'provider' ([pscustomobject]@{ Kind = 'LMStudio'; BaseUrl = 'http://localhost:1234'; TokenProtected = '' })
    }
    if (-not (Get-Field $config 'bindings')) { Set-Field $config 'bindings' ([pscustomobject]@{}) }
    if ($null -eq (Get-Field $config 'projects')) { Set-Field $config 'projects' @() }
    return $config
}

function Protect-BackendToken {
    param([string]$Token)
    if (-not $Token) { return '' }
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($Token)
    return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
}

function Get-BackendToken {
    param($Provider)
    $protected = Get-Field $Provider 'TokenProtected' ''
    if (-not $protected) {
        if ($Provider.Kind -eq 'Ollama') { return 'ollama' }
        return 'local-backend'
    }
    Add-Type -AssemblyName System.Security
    return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($protected), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
}

function New-Provider {
    param([ValidateSet('LMStudio','Ollama','Anthropic','OpenAI')][string]$Kind, [string]$BaseUrl = '', [string]$AuthToken = '')
    if (-not $BaseUrl) {
        $BaseUrl = switch ($Kind) { 'LMStudio' { 'http://localhost:1234' } 'Ollama' { 'http://localhost:11434' } default { 'http://localhost:8080' } }
    }
    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Enter an HTTP(S) base URL without credentials, query or fragment.'
    }
    # This tool is intentionally local. No accidental cloud model/backend selection.
    if (-not $uri.IsLoopback) { throw 'Use a localhost/127.0.0.1 local server URL.' }
    if ($uri.AbsolutePath.TrimEnd('/') -eq '/v1') { $BaseUrl = $BaseUrl.TrimEnd('/').Substring(0, $BaseUrl.TrimEnd('/').Length - 3) }
    [pscustomobject]@{ Kind = $Kind; BaseUrl = $BaseUrl.TrimEnd('/'); TokenProtected = (Protect-BackendToken $AuthToken) }
}

function Invoke-Backend {
    param($Provider, [string]$Path, [string]$Method = 'GET', $Body = $null, [int]$TimeoutSec = 15)
    $token = Get-BackendToken $Provider
    $request = @{ Uri = ($Provider.BaseUrl.TrimEnd('/') + $Path); Method = $Method; TimeoutSec = $TimeoutSec; UseBasicParsing = $true; MaximumRedirection = 0
        Headers = @{ Authorization = "Bearer $token"; 'x-api-key' = $token; 'anthropic-version' = '2023-06-01' } }
    if ($null -ne $Body) { $request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 60 -Compress)); $request.ContentType = 'application/json' }
    try {
        $response = Invoke-WebRequest @request
        $json = $response.Content | ConvertFrom-Json
        if (Get-Field $json 'error') { throw 'The server returned an error response.' }
        return $json
    } catch {
        $status = ''
        $errorResponse=Get-Field $_.Exception 'Response'
        if ($errorResponse) { $status = ' HTTP ' + [int]$errorResponse.StatusCode }
        throw "$($Provider.Kind) request failed:$status $Method $Path. Check the server, API support and token."
    }
}

function Get-ProviderModels {
    param($Provider)
    switch ($Provider.Kind) {
        'LMStudio' {
            $response = Invoke-Backend $Provider '/api/v1/models'
            foreach ($m in @($response.models)) {
                if ($m.type -ne 'llm') { continue }
                [pscustomobject]@{ ModelKey=$m.key; DisplayName=$m.display_name; Publisher=$m.publisher
                    SizeBytes=(Get-Field $m 'size_bytes'); Params=(Get-Field $m 'params_string' ''); Architecture=(Get-Field $m 'architecture' '')
                    MaxContext=(Get-Field $m 'max_context_length' 0); Instances=@(Get-Field $m 'loaded_instances' @()) }
            }
        }
        'Ollama' {
            $response = Invoke-Backend $Provider '/api/tags'
            foreach ($m in @($response.models)) {
                # Ollama can expose cloud aliases through its local server; exclude those.
                if ($m.name -match '(?i)(:cloud|[-:]cloud(?:[-:]|$))' -or (Get-Field $m 'remote_host') -or (Get-Field $m 'remote_model')) { continue }
                [pscustomobject]@{ ModelKey=$m.name; DisplayName=$m.name; Publisher=''; SizeBytes=$m.size
                    Params=(Get-Field $m.details 'parameter_size' ''); Architecture=(Get-Field $m.details 'family' ''); MaxContext=0; Instances=@() }
            }
        }
        default {
            $response = Invoke-Backend $Provider '/v1/models'
            foreach ($m in @($response.data)) {
                [pscustomobject]@{ ModelKey=$m.id; DisplayName=$m.id; Publisher=(Get-Field $m 'owned_by' '')
                    SizeBytes=(Get-Field $m 'size_bytes'); Params=(Get-Field $m 'params_string' ''); Architecture=''; MaxContext=0; Instances=@() }
            }
        }
    }
}

function Get-ParameterCount {
    param([string]$Text)
    $match = [regex]::Match($Text, '(?i)(?:(\d+)\s*x\s*)?(\d+(?:\.\d+)?)\s*([KMBT])?')
    if (-not $match.Success) { return $null }
    $value = [double]::Parse($match.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($match.Groups[1].Success) {$value *= [int]$match.Groups[1].Value}
    $scale = switch ($match.Groups[3].Value.ToUpperInvariant()) { 'K' {1e3} 'M' {1e6} 'B' {1e9} 'T' {1e12} default {1} }
    return $value * $scale
}

function Get-ModelSortValue {
    param($Model, [int]$Column)
    switch ($Column) {
        0 { return $Model.ModelKey } 1 { return $Model.DisplayName } 2 { return $Model.Publisher }
        3 { return $Model.SizeBytes } 4 { return Get-ParameterCount $Model.Params } 5 { return $Model.Architecture }
    }
}

function Get-SortedModels {
    param([object[]]$Models, [int]$Column = 3, [bool]$Descending = $true, [string]$Filter = '')
    $items = @($Models | Where-Object { -not $Filter -or (($_.ModelKey + ' ' + $_.DisplayName + ' ' + $_.Publisher).IndexOf($Filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) })
    # Missing sizes always go last in either direction; compare actual numeric bytes.
    return @($items | Sort-Object @{Expression={ $null -eq (Get-ModelSortValue $_ $Column) };Ascending=$true},
        @{Expression={ Get-ModelSortValue $_ $Column };Descending=$Descending}, @{Expression={$_.ModelKey};Ascending=$true})
}

function Get-NextSort {
    param([int]$CurrentColumn, [bool]$Descending, [int]$ClickedColumn)
    [pscustomobject]@{ Column=$ClickedColumn; Descending=$(if ($CurrentColumn -eq $ClickedColumn) { -not $Descending } else { $ClickedColumn -in @(3,4) }) }
}

function Test-ModelEndpoint {
    param($Provider, [string]$ModelId, [switch]$Tools)
    $body = @{ model=$ModelId; max_tokens=128; messages=@(@{role='user';content='Reply with OK.'}) }
    if ($Provider.Kind -eq 'OpenAI') {
        $path = '/v1/chat/completions'
        if ($Tools) { $body.messages=@(@{role='system';content='Use the provided local_probe tool to return the requested value. Do not answer in prose.'},@{role='user';content='Call local_probe with value OK.'}); $body.tools=@(@{type='function';function=@{name='local_probe';description='Return a probe value';parameters=@{type='object';properties=@{value=@{type='string'}};required=@('value')}}}); $body.tool_choice=@{type='function';function=@{name='local_probe'}} }
        $response = Invoke-Backend $Provider $path 'POST' $body 120
        if (-not (Get-Field $response 'choices')) { throw 'Invalid chat-completions response: choices missing.' }
        $message = $response.choices[0].message
        if ($Tools) {
            $call=@(Get-Field $message 'tool_calls' @()) | Where-Object {(Get-Field (Get-Field $_ 'function') 'name') -eq 'local_probe'} | Select-Object -First 1
            if (-not $call -or -not (Get-Field $call 'id')) {throw 'Model did not return the requested tool call.'}
            try {$inputObject=$call.function.arguments | ConvertFrom-Json} catch {throw 'Model returned invalid JSON tool arguments.'}
            if ((Get-Field $inputObject 'value') -isnot [string]) {throw 'Model returned invalid probe arguments.'}
        }
        elseif (-not (Get-Field $message 'content')) { throw 'Model did not return text.' }
    } else {
        # Health/tool probes need an answer, not a thinking-only token-budget exhaustion.
        $body.thinking=@{type='disabled'}
        if ($Tools) { $body.system='Use the provided local_probe tool to return the requested value. Do not answer in prose.'; $body.messages[0].content='Call local_probe with value OK.'; $body.tools=@(@{name='local_probe';description='Return a probe value';input_schema=@{type='object';properties=@{value=@{type='string'}};required=@('value')}}); $body.tool_choice=@{type='tool';name='local_probe'} }
        $response = Invoke-Backend $Provider '/v1/messages' 'POST' $body 120
        if ((Get-Field $response 'type') -ne 'message' -or (Get-Field $response 'role') -ne 'assistant' -or -not (Get-Field $response 'content')) { throw 'Invalid Anthropic Messages response.' }
        $type = if ($Tools) { 'tool_use' } else { 'text' }
        $blocks=@($response.content | Where-Object { $_.type -eq $type })
        if (-not $blocks.Count) {throw "Model did not return a $type block."}
        if ($Tools) {
            $call=$blocks | Where-Object {(Get-Field $_ 'name') -eq 'local_probe'} | Select-Object -First 1
            if (-not $call -or -not (Get-Field $call 'id') -or (Get-Field (Get-Field $call 'input') 'value') -isnot [string]) {throw 'Model returned an invalid probe tool call.'}
        } elseif (-not @($blocks | Where-Object {(Get-Field $_ 'text' '').Trim()}).Count) {throw 'Model returned empty text.'}
    }
    return 'Endpoint response validated.'
}

function Set-ModelBinding {
    param([string]$StateRoot, $Provider, [ValidateSet('sonnet','opus','haiku')][string]$Alias, [string]$ModelKey, [int]$ContextLength = 0, [switch]$VerifyTools)
    if ($ContextLength -lt 0) { throw 'ContextLength must be >= 0.' }
    $config = Get-SwitcherConfig $StateRoot
    $models = @(Get-ProviderModels $Provider)
    $model = $models | Where-Object { $_.ModelKey -eq $ModelKey } | Select-Object -First 1
    if (-not $model) { throw 'Select an installed model listed by the server.' }
    if ($model.MaxContext -gt 0 -and $ContextLength -gt $model.MaxContext) { throw "Requested context exceeds model limit $($model.MaxContext)." }
    $modelId = $ModelKey; $effectiveContext = $ContextLength
    switch ($Provider.Kind) {
        'LMStudio' {
            $instance = @($model.Instances | Where-Object { $ContextLength -eq 0 -or $_.config.context_length -eq $ContextLength }) | Select-Object -First 1
            if ($instance) { $modelId=$instance.id; $effectiveContext=$instance.config.context_length }
            else {
                $body=@{model=$ModelKey;echo_load_config=$true}
                if ($ContextLength -gt 0) { $body.context_length=$ContextLength }
                $loaded=Invoke-Backend $Provider '/api/v1/models/load' 'POST' $body 300
                if ((Get-Field $loaded 'status') -ne 'loaded' -or -not (Get-Field $loaded 'instance_id')) { throw 'LM Studio did not confirm model loading.' }
                $modelId=$loaded.instance_id
                $effectiveContext=Get-Field (Get-Field $loaded 'load_config') 'context_length' $ContextLength
            }
        }
        'Ollama' {
            $details=Invoke-Backend $Provider '/api/show' 'POST' @{model=$ModelKey}
            if ((Get-Field $details 'remote_host') -or (Get-Field $details 'remote_model')) { throw 'Cloud Ollama models are not allowed in local mode.' }
            $limits=@((Get-Field $details 'model_info' ([pscustomobject]@{})).PSObject.Properties | Where-Object { $_.Name -like '*.context_length' } | ForEach-Object {$_.Value})
            if ($limits.Count -and $ContextLength -gt [int]$limits[0]) { throw 'Requested context exceeds the Ollama model limit.' }
            if ($ContextLength -gt 0) {
                # Keep the user's original tag intact. Content-addressed variants are reusable.
                $hash=[Security.Cryptography.SHA256]::Create()
                try { $suffix=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($ModelKey + ':' + $ContextLength)))).Replace('-','').Substring(0,16).ToLowerInvariant() } finally {$hash.Dispose()}
                $modelId='local-switcher-ctx-' + $suffix + ':latest'
                $created=Invoke-Backend $Provider '/api/create' 'POST' @{model=$modelId;from=$ModelKey;parameters=@{num_ctx=$ContextLength};stream=$false} 300
                if ((Get-Field $created 'status') -ne 'success') { throw 'Ollama did not confirm context variant creation.' }
            }
        }
        default {
            if ($ContextLength -gt 0) { throw 'Set context in this server application. This connector cannot change its context.' }
        }
    }
    # Validate before committing: old mapping and loaded models survive any failure.
    [void](Test-ModelEndpoint $Provider $modelId)
    if ($VerifyTools) {[void](Test-ModelEndpoint $Provider $modelId -Tools)}
    if ($config.provider.Kind -ne $Provider.Kind -or $config.provider.BaseUrl -ne $Provider.BaseUrl) { Set-Field $config 'bindings' ([pscustomobject]@{}) }
    Set-Field $config 'provider' $Provider
    Set-Field $config.bindings $Alias ([pscustomobject]@{ModelKey=$ModelKey;ModelId=$modelId;ContextLength=$effectiveContext})
    Write-JsonFile (Get-StatePaths $StateRoot).Config $config
    return "Saved $Alias -> $ModelId. Restart the local Claude chat to apply the mapping."
}

function Add-LocalProject {
    param([string]$StateRoot, [string]$WorkspacePath)
    $path=[IO.Path]::GetFullPath($WorkspacePath)
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Project directory does not exist.' }
    $config=Get-SwitcherConfig $StateRoot
    Set-Field $config 'projects' @(@($config.projects) + $path | Select-Object -Unique)
    Write-JsonFile (Get-StatePaths $StateRoot).Config $config
}

function Assert-LocalProject {
    param([string]$WorkspacePath)
    foreach ($name in @('.claude\settings.json','.claude\settings.local.json','.vscode\settings.json')) {
        $file=Join-Path $WorkspacePath $name
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $settings=Read-JsonFile $file
        $routing=Get-Field $settings 'env'
        if ($routing) {
            foreach ($p in $routing.PSObject.Properties) {
                if ($p.Name -match '^(ANTHROPIC_|CLAUDE_CONFIG_DIR|CLAUDE_CODE_USE_|CLAUDE_CODE_SUBAGENT_MODEL)') { throw "Project routing override in $name ($($p.Name)). Remove it before isolated local launch." }
            }
        }
        foreach ($key in @('model','fallbackModel','modelOverrides','forceLoginMethod','forceLoginOrgUUID','claudeCode.environmentVariables','claudeCode.claudeProcessWrapper','claudeCode.selectedModel')) {
            if ($null -ne $settings.PSObject.Properties[$key]) { throw "Conflicting $key in $name. Use the isolated profile configuration instead." }
        }
    }
}

function Get-LocalEnvironment {
    param($Config, $Paths, [string]$BaseUrl = '')
    if (-not $BaseUrl) { $BaseUrl=$Config.provider.BaseUrl }
    $vars=[ordered]@{ CLAUDE_CONFIG_DIR=$Paths.Claude; ANTHROPIC_BASE_URL=$BaseUrl; ANTHROPIC_AUTH_TOKEN=(Get-BackendToken $Config.provider)
        CLAUDE_CODE_ATTRIBUTION_HEADER='0'; DISABLE_TELEMETRY='1'; DISABLE_ERROR_REPORTING='1' }
    foreach ($alias in @('SONNET','OPUS','HAIKU')) {
        $binding=Get-Field $Config.bindings $alias.ToLowerInvariant()
        if ($binding) { $vars['ANTHROPIC_DEFAULT_' + $alias + '_MODEL']=$binding.ModelId }
    }
    $sonnet=Get-Field $Config.bindings 'sonnet'
    if (-not $sonnet) { throw 'Bind a sonnet model before launching local Claude Code.' }
    $vars['ANTHROPIC_MODEL']=$sonnet.ModelId
    $vars['CLAUDE_CODE_SUBAGENT_MODEL']=$sonnet.ModelId
    # Pin all helper families locally, even when only one model was selected.
    foreach ($alias in @('SONNET','OPUS','HAIKU')) { if (-not $vars.Contains('ANTHROPIC_DEFAULT_' + $alias + '_MODEL')) { $vars['ANTHROPIC_DEFAULT_' + $alias + '_MODEL']=$sonnet.ModelId } }
    $contexts=@($Config.bindings.PSObject.Properties | ForEach-Object {$_.Value.ContextLength} | Where-Object {$_ -gt 0})
    if ($contexts.Count) { $vars['CLAUDE_CODE_MAX_CONTEXT_TOKENS']=[string](($contexts | Measure-Object -Minimum).Minimum) }
    return $vars
}

function Update-IsolatedCodeSettings {
    param($Paths, $Variables, [switch]$Login)
    $codeRoot=if ($Login) {$Paths.LoginCode} else {$Paths.Code}
    $settingsPath=Join-Path $codeRoot 'User\settings.json'
    $settings=Read-JsonFile $settingsPath
    $existing=@(Get-Field $settings 'claudeCode.environmentVariables' @())
    $envList=@($existing | Where-Object {$_.name -notmatch '^(ANTHROPIC_|CLAUDE_CONFIG_DIR|CLAUDE_CODE_|DISABLE_TELEMETRY|DISABLE_ERROR_REPORTING)'})
    foreach ($key in $Variables.Keys) { $envList += [pscustomobject]@{name=$key;value=[string]$Variables[$key]} }
    Set-Field $settings 'claudeCode.environmentVariables' $envList
    Set-Field $settings 'claudeCode.disableLoginPrompt' (-not [bool]$Login)
    Set-Field $settings 'window.title' $(if ($Login) {($Paths.Name + ' - sign in | ${appName}')} else {('LOCAL MODELS - ' + $Paths.Name + ' | ${rootName} | ${appName}')})
    Write-JsonFile $settingsPath $settings
}

function Set-IsolatedProcessEnvironment {
    param($Variables)
    Set-AgentProcessEnvironment $Variables
}

. (Join-Path $PSScriptRoot 'runtime_control.ps1')
