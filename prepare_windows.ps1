param(
    [ValidateSet('LMStudio','Ollama','Anthropic','OpenAI')][string]$Backend = '',
    [string]$BaseUrl = '', [string]$AuthToken = '', [string]$StateRoot = '', [string]$WorkspacePath = '',
    [switch]$InstallExtension, [switch]$DryRun
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'local_switcher_core.ps1')
try {
    $paths=Get-StatePaths $StateRoot
    $config=Get-SwitcherConfig $StateRoot
    if ($Backend) {
        $provider=New-Provider $Backend $BaseUrl $AuthToken
        if ($config.provider.Kind -ne $provider.Kind -or $config.provider.BaseUrl -ne $provider.BaseUrl) {Set-Field $config 'bindings' ([pscustomobject]@{})}
        Set-Field $config 'provider' $provider
    } elseif ($BaseUrl -or $AuthToken) {throw 'Specify -Backend when configuring an endpoint/token.'}
    if ($WorkspacePath) {
        $WorkspacePath=[IO.Path]::GetFullPath($WorkspacePath)
        if (-not (Test-Path -LiteralPath $WorkspacePath -PathType Container)) {throw 'Project directory does not exist.'}
        Assert-LocalProject $WorkspacePath
        Set-Field $config 'projects' @(@($config.projects) + $WorkspacePath | Select-Object -Unique)
    }
    if ($DryRun) {
        [pscustomobject]@{StateRoot=$paths.Root;ClaudeConfig=$paths.Claude;VSCodeData=$paths.Code;Provider=$config.provider.Kind
            BaseUrl=$config.provider.BaseUrl;Projects=$config.projects;InstallExtension=[bool]$InstallExtension} | ConvertTo-Json -Depth 5
        exit 0
    }
    Write-JsonFile $paths.Config $config
    [void][IO.Directory]::CreateDirectory($paths.Claude)
    [void][IO.Directory]::CreateDirectory($paths.Extensions)
    Write-Output "Prepared isolated account B state: $($paths.Root)"
    foreach ($command in @('lms','ollama','code','python')) {
        $found=Get-Command $command -ErrorAction SilentlyContinue
        Write-Output ("{0}: {1}" -f $command,$(if ($found) {$found.Source} else {'not in PATH'}))
    }
    try {$models=@(Get-ProviderModels $config.provider); Write-Output "Server available: $($models.Count) local model(s)."}
    catch {Write-Output 'No usable local server detected. Install/start a runtime and refresh the switcher.'; Write-Output 'Ollama: https://ollama.com/download/windows | LM Studio: https://lmstudio.ai/download'}
    if ($InstallExtension) {
        & (Join-Path $PSScriptRoot 'launch_claude_local_vscode.ps1') -StateRoot $paths.Root -LoginAccountB -InstallExtension
        if ($LASTEXITCODE -ne 0) {throw 'Isolated VS Code setup failed.'}
    }
    Write-Output 'Next: run_login_account_b.cmd, bind a sonnet model in run_switcher_gui.cmd, then select a registered project.'
} catch {Write-Error $_ -ErrorAction Continue; exit 1}
exit 0
