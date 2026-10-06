param([string]$Repo = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Repo 'local_switcher_core.ps1')
$script:checks=0
function Assert {param([bool]$Condition,[string]$Message); if (-not $Condition) {throw $Message}; $script:checks++}
function Assert-Throws {param([scriptblock]$Action,[string]$Message); $thrown=$false;try {& $Action | Out-Null} catch {$thrown=$true};Assert $thrown $Message}
$root=Join-Path ([IO.Path]::GetTempPath()) ('switcher-tests-' + [guid]::NewGuid().ToString('N'))
$paths=Get-StatePaths $root
[void][IO.Directory]::CreateDirectory($root)

$json=ConvertFrom-Jsonc '{/* keep strings */ "url":"http://localhost:1234/a//b", "quote":"a\"//b", "nested":[1,2,], // comment
"flag":true,}'
Assert ($json.url -eq 'http://localhost:1234/a//b') 'JSONC URL changed'
Assert ($json.quote -eq 'a"//b' -and $json.nested.Count -eq 2) 'JSONC escaping/trailing comma failed'
Assert-Throws {ConvertFrom-Jsonc '{/* never closed'} 'Unterminated comments must fail'
Write-JsonFile $paths.Config ([pscustomobject]@{value=1})
Write-JsonFile $paths.Config ([pscustomobject]@{value=2})
Assert ((Read-JsonFile $paths.Config).value -eq 2 -and (Read-JsonFile ($paths.Config + '.bak')).value -eq 1) 'Atomic write/backup failed'
Assert-Throws {Get-StatePaths (Join-Path $env:USERPROFILE '.claude\nested')} 'Main Claude directory accepted'
Assert-Throws {Get-StatePaths (Join-Path $env:APPDATA 'Code')} 'Main VS Code directory accepted'
Assert-Throws {New-Provider OpenAI 'https://api.openai.com'} 'Cloud endpoint accepted'
Assert ((New-Provider Ollama 'http://127.0.0.1:11434/v1/').BaseUrl -eq 'http://127.0.0.1:11434') 'v1 URL normalization failed'
$provider=New-Provider Ollama '' 'fixture-token'
Assert ((Get-BackendToken $provider) -eq 'fixture-token') 'DPAPI round trip failed'
Assert ($provider.TokenProtected -ne 'fixture-token') 'Token persisted in plaintext'

$models=@(
    [pscustomobject]@{ModelKey='small';DisplayName='Small';Publisher='';SizeBytes=9e9;Params='900M';Architecture=''},
    [pscustomobject]@{ModelKey='large';DisplayName='Large';Publisher='';SizeBytes=12e9;Params='12B';Architecture=''},
    [pscustomobject]@{ModelKey='unknown';DisplayName='Unknown';Publisher='';SizeBytes=$null;Params='';Architecture=''}
)
$sorted=Get-SortedModels $models
Assert ($sorted[0].ModelKey -eq 'large' -and $sorted[-1].ModelKey -eq 'unknown') 'Default largest-first sort failed'
$sorted=Get-SortedModels $models 3 $false
Assert ($sorted[0].ModelKey -eq 'small' -and $sorted[-1].ModelKey -eq 'unknown') 'Ascending sort or missing size ordering failed'
$sorted=Get-SortedModels $models 4 $true
Assert ($sorted[0].ModelKey -eq 'large') 'M/B parameter units sorted incorrectly'
Assert ((Get-ParameterCount '8x7B') -eq 56e9) 'MoE parameter count sorted incorrectly'
$next=Get-NextSort -1 $true 3
Assert $next.Descending 'First size click must descend'
$next=Get-NextSort $next.Column $next.Descending 3
Assert (-not $next.Descending) 'Repeated size click must toggle'
Assert (@(Get-SortedModels $models 3 $true 'LARGE').Count -eq 1) 'Case-insensitive cached filter failed'

# Provider fixtures exercise HTTP adaptation and failure paths without any real runtime.
$script:failValidation=$false; $script:requests=New-Object Collections.Generic.List[string]
function Invoke-Backend {
    param($Provider,[string]$Path,[string]$Method='GET',$Body=$null,[int]$TimeoutSec=15)
    $script:requests.Add($Path)
    switch ($Path) {
        '/api/v1/models' {return [pscustomobject]@{models=@([pscustomobject]@{type='llm';key='model-a';display_name='Model A';publisher='fixture';size_bytes=12000000000;params_string='12B';max_context_length=65536;loaded_instances=@()})}}
        '/api/v1/models/load' {Assert ($Body.context_length -eq 32768) 'LM Studio context not forwarded';return [pscustomobject]@{status='loaded';instance_id='fixture-instance';load_config=[pscustomobject]@{context_length=32768}}}
        '/api/tags' {return [pscustomobject]@{models=@([pscustomobject]@{name='local:latest';size=5000000000;details=[pscustomobject]@{family='qwen';parameter_size='8B'}},[pscustomobject]@{name='remote:cloud';size=0;details=[pscustomobject]@{family='qwen';parameter_size='100B'}})}}
        '/api/show' {return [pscustomobject]@{model_info=[pscustomobject]@{'qwen.context_length'=65536}}}
        '/api/create' {Assert ($Body.parameters.num_ctx -eq 32768 -and $Body.from -eq 'local:latest') 'Ollama context/source wrong';return [pscustomobject]@{status='success'}}
        '/v1/models' {return [pscustomobject]@{data=@([pscustomobject]@{id='custom-model';owned_by='local'})}}
        '/v1/messages' {
            if ($script:failValidation) {throw 'Fixture validation failure'}
            $content=if ($Body.ContainsKey('tools')) {@([pscustomobject]@{type='tool_use';id='probe';name='local_probe';input=[pscustomobject]@{value='OK'}})} else {@([pscustomobject]@{type='text';text='OK'})}
            return [pscustomobject]@{type='message';role='assistant';content=$content}
        }
        '/v1/chat/completions' {return [pscustomobject]@{choices=@([pscustomobject]@{message=[pscustomobject]@{content='OK'}})}}
        default {throw "Unexpected fixture request: $Path"}
    }
}
$config=Get-SwitcherConfig $root
Set-Field $config 'bindings' ([pscustomobject]@{})
Write-JsonFile $paths.Config $config
$lm=New-Provider LMStudio
[void](Set-ModelBinding $root $lm sonnet 'model-a' 32768)
$saved=Get-SwitcherConfig $root
Assert ($saved.bindings.sonnet.ModelId -eq 'fixture-instance') 'LM Studio instance ID not mapped'
Assert (-not @($script:requests | Where-Object {$_ -like '*unload*'}).Count) 'Old model unloaded before validation'
$before=[IO.File]::ReadAllText($paths.Config)
$script:failValidation=$true
Assert-Throws {Set-ModelBinding $root $lm sonnet 'model-a' 32768} 'Validation failure accepted'
Assert ([IO.File]::ReadAllText($paths.Config) -eq $before) 'Failed binding changed saved configuration'
$script:failValidation=$false
Assert-Throws {Set-ModelBinding $root $lm sonnet 'model-a' 131072} 'Oversized context accepted'
$ollama=New-Provider Ollama
Assert (@(Get-ProviderModels $ollama).Count -eq 1) 'Ollama cloud alias not excluded'
[void](Set-ModelBinding $root $ollama sonnet 'local:latest' 32768)
$saved=Get-SwitcherConfig $root
Assert ($saved.bindings.sonnet.ModelId -like 'local-switcher-ctx-*:latest') 'Ollama original tag overwritten'
$savedId=$saved.bindings.sonnet.ModelId
[void](Set-ModelBinding $root $ollama sonnet 'local:latest' 32768)
Assert ((Get-SwitcherConfig $root).bindings.sonnet.ModelId -eq $savedId) 'Ollama context variant not reusable'
[void](Test-ModelEndpoint $ollama $savedId -Tools)
$custom=New-Provider Anthropic
Assert-Throws {Set-ModelBinding $root $custom sonnet 'custom-model' 32768} 'Unsupported context falsely accepted'
[void](Set-ModelBinding $root $custom sonnet 'custom-model')
$saved=Get-SwitcherConfig $root
Assert ($saved.provider.Kind -eq 'Anthropic' -and @($saved.bindings.PSObject.Properties.Name).Count -eq 1) 'Provider change did not reset mappings'

$envs=Get-LocalEnvironment $saved $paths
Assert ($envs.CLAUDE_CONFIG_DIR -eq $paths.Claude) 'Wrong configuration directory'
Assert ($envs.ANTHROPIC_DEFAULT_HAIKU_MODEL -eq 'custom-model' -and $envs.ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'custom-model') 'Unbound helper families can escape to cloud'
$settingsPath=Join-Path $paths.Code 'User\settings.json'
Write-JsonFile $settingsPath ([pscustomobject]@{'editor.fontSize'=17;'claudeCode.environmentVariables'=@([pscustomobject]@{name='CUSTOM_FLAG';value='keep'},[pscustomobject]@{name='ANTHROPIC_API_KEY';value='must-remove'})})
Update-IsolatedCodeSettings $paths $envs
$settings=Read-JsonFile $settingsPath
Assert ($settings.'editor.fontSize' -eq 17) 'Unrelated VS Code setting lost'
Assert (@($settings.'claudeCode.environmentVariables' | Where-Object {$_.name -eq 'CUSTOM_FLAG'}).Count -eq 1) 'Unrelated extension variable lost'
Assert (@($settings.'claudeCode.environmentVariables' | Where-Object {$_.name -eq 'ANTHROPIC_API_KEY'}).Count -eq 0) 'Old cloud credential variable retained'
Update-IsolatedCodeSettings $paths ([ordered]@{CLAUDE_CONFIG_DIR=$paths.Claude}) -Login
$login=Read-JsonFile (Join-Path $paths.LoginCode 'User\settings.json')
Assert (-not $login.'claudeCode.disableLoginPrompt') 'Account B login disabled'
Assert ($login.'claudeCode.environmentVariables'.Count -eq 1) 'Local routing leaked into login window'

$snapshot=Get-ProcessEnvironmentSnapshot
try {
    $env:ANTHROPIC_API_KEY='fixture-cloud';$env:CLAUDE_CODE_OAUTH_TOKEN='fixture-oauth';$env:CLAUDE_CODE_USE_BEDROCK='1'
    Set-IsolatedProcessEnvironment $envs
    Assert (-not $env:ANTHROPIC_API_KEY -and -not $env:CLAUDE_CODE_OAUTH_TOKEN -and -not $env:CLAUDE_CODE_USE_BEDROCK) 'Inherited provider credentials not cleared'
} finally {Restore-ProcessEnvironment $snapshot}
Assert ([string][Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY','Process') -eq [string]$snapshot['ANTHROPIC_API_KEY']) 'Parent environment not restored'

$project=Join-Path $root 'Separate project'
[void][IO.Directory]::CreateDirectory($project)
Add-LocalProject $root $project
Assert (@((Get-SwitcherConfig $root).projects).Count -eq 1) 'Project registration failed'
Assert-LocalProject $project
Write-JsonFile (Join-Path $project '.claude\settings.local.json') ([pscustomobject]@{env=[pscustomobject]@{ANTHROPIC_BASE_URL='https://cloud.invalid'}})
Assert-Throws {Assert-LocalProject $project} 'Project routing override not detected'

# Real child-process argv round trip with spaces, Cyrillic, quotes and backslashes.
$argScript=Join-Path $root 'argv.ps1'
[IO.File]::WriteAllText($argScript,'[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); ConvertTo-Json -Compress -InputObject @($args)',(New-Object Text.UTF8Encoding($false)))
$outFile=Join-Path $root 'argv.json'
$values=@('Claude Local LM Studio','C:\My Project\','quote"value','',([string][char]0x041F + [char]0x0430))
$processArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$argScript) + $values
$process=Start-Process powershell.exe -ArgumentList (($processArgs | ForEach-Object {ConvertTo-ProcessArgument $_}) -join ' ') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $outFile
Assert ($process.ExitCode -eq 0) 'Argv test subprocess failed'
$received=[IO.File]::ReadAllText($outFile) | ConvertFrom-Json
for ($i=0;$i -lt $values.Count;$i++) {Assert ($received[$i] -eq $values[$i]) 'Windows argument quoting failed'}
Write-Output "PASS: $script:checks core checks (PowerShell $($PSVersionTable.PSVersion)). Fixtures: $root"
