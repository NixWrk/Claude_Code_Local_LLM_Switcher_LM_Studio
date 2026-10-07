param(
    [switch]$Headless,
    [ValidateSet('LMStudio','Ollama','Anthropic','OpenAI')][string]$Backend = '',
    [string]$BaseUrl = '', [string]$AuthToken = '', [string]$StateRoot = '',
    [ValidateSet('sonnet','opus','haiku')][string]$Alias = 'sonnet',
    [string]$ModelKey = '', [int]$ContextLength = 0,
    [switch]$TestAlias, [switch]$TestTools, [switch]$ShowLoaded, [switch]$ListModels,
    [switch]$UnloadAll, [switch]$ForceUnload,
    [switch]$DisableClaudeAliasSync,
    [string]$PreviewPath = '', [string]$PreviewModelsFile = '',
    [ValidateSet('Server','Install','Model','Account','Project','Busy','NoModels','AuthRequired','CustomServer')][string]$PreviewScenario = 'Server',
    [switch]$GuiTest
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'local_switcher_core.ps1')
$paths=Get-StatePaths $StateRoot
$config=Get-SwitcherConfig $StateRoot
$provider=$config.provider
if ($Backend) {$provider=New-Provider $Backend $BaseUrl $AuthToken}
elseif ($BaseUrl -or $AuthToken) {throw 'Specify -Backend with endpoint/token overrides.'}
if ($ContextLength -lt 0) {throw 'ContextLength must be >= 0.'}

if ($Headless) {
    try {
        if ($UnloadAll -or $ForceUnload) {Unload-AllModels $provider -Force:$ForceUnload;exit 0}
        if ($ListModels -or $ShowLoaded) {
            if ($ShowLoaded -and $provider.Kind -eq 'Ollama') {Invoke-Backend $provider '/api/ps' | ConvertTo-Json -Depth 20}
            elseif ($ShowLoaded -and $provider.Kind -eq 'LMStudio') {
                $instances=@(Get-ProviderModels $provider | ForEach-Object {$_.Instances})
                ConvertTo-Json -InputObject $instances -Depth 20
            } elseif ($ShowLoaded) {throw 'This connector cannot report loaded instances. Use -ListModels for the catalog.'}
            else {Get-SortedModels @(Get-ProviderModels $provider) | ConvertTo-Json -Depth 20}
        }
        if (-not $ModelKey -and $ContextLength -gt 0) {
            $binding=Get-Field $config.bindings $Alias
            if (-not $binding) {throw 'Bind this alias before updating context.'}
            $ModelKey=$binding.ModelKey
        }
        if ($ModelKey) {Set-ModelBinding $paths.Root $provider $Alias $ModelKey $ContextLength}
        if ($TestAlias -or $TestTools) {
            $current=Get-SwitcherConfig $paths.Root
            $binding=Get-Field $current.bindings $Alias
            if (-not $binding) {throw 'No saved binding for this alias.'}
            Test-ModelEndpoint $current.provider $binding.ModelId -Tools:$TestTools
        }
        if (-not ($ListModels -or $ShowLoaded -or $ModelKey -or $TestAlias -or $TestTools)) {Write-Output 'Use -ListModels, -ShowLoaded, -Alias sonnet -ModelKey <installed-model>, -TestAlias or -TestTools.'}
        exit 0
    } catch {Write-Error $_ -ErrorAction Continue; exit 1}
}

. (Join-Path $PSScriptRoot 'local_switcher_gui.ps1')
