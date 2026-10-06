param(
    [string]$WorkspacePath = '', [string]$StateRoot = '',
    [switch]$LoginAccountB, [switch]$InstallExtension, [switch]$DryRun, [string]$ReadyFile=''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local_switcher_core.ps1')
. (Join-Path $PSScriptRoot 'gui_workflow.ps1')
$reported=$false
function Write-LauncherResult {
    param([bool]$Success,[string]$Message='')
    if ($ReadyFile -and -not $script:reported) {
        Write-JsonFile $ReadyFile ([pscustomobject]@{Source='switcher-vscode-launch';Success=$Success;Error=$Message;ProcessId=$PID})
        $script:reported=$true
    }
}
try {
    $paths=Get-StatePaths $StateRoot
    if ($ReadyFile -and [IO.Path]::GetFullPath((Split-Path $ReadyFile -Parent)) -ne $paths.Root) {throw 'Launcher result file must be inside the isolated state root.'}
    $config=Get-SwitcherConfig $StateRoot
    if ($LoginAccountB) {
        $variables=[ordered]@{CLAUDE_CONFIG_DIR=$paths.Claude}
        $codeRoot=$paths.LoginCode
    } else {
        if (-not $WorkspacePath) {throw 'Choose a registered local project (-WorkspacePath). Login uses -LoginAccountB.'}
        $WorkspacePath=[IO.Path]::GetFullPath($WorkspacePath)
        if ($WorkspacePath -notin @($config.projects)) {throw 'Register this separate project first: prepare_windows.ps1 -WorkspacePath <path>.'}
        if (-not (Test-Path -LiteralPath $WorkspacePath -PathType Container)) {throw 'Project directory does not exist.'}
        Assert-LocalProject $WorkspacePath
        $variables=Get-LocalEnvironment $config $paths
        $codeRoot=$paths.Code
    }
    $codeExe=Resolve-CodeExecutable
    if ($DryRun) {
        [pscustomobject]@{Mode=$(if ($LoginAccountB) {'Account B login'} else {'Local models'});Executable=$codeExe
            UserDataDir=$codeRoot;ExtensionsDir=$paths.Extensions;ClaudeConfigDir=$paths.Claude;Workspace=$WorkspacePath
            Provider=$(if ($LoginAccountB) {'Anthropic account login'} else {$config.provider.Kind});EnvironmentNames=@($variables.Keys)} | ConvertTo-Json -Depth 5
        exit 0
    }
    [void][IO.Directory]::CreateDirectory($paths.Claude)
    [void][IO.Directory]::CreateDirectory($paths.Extensions)
    $snapshot=Get-ProcessEnvironmentSnapshot
    $bridgeProcess=$null; $readyPath=$null
    try {
        Set-IsolatedProcessEnvironment $variables
        if ($InstallExtension -or -not @(Get-ChildItem -LiteralPath $paths.Extensions -Directory -Filter 'anthropic.claude-code-*').Count) {
            $extensionArgs=@('--user-data-dir',$codeRoot,'--extensions-dir',$paths.Extensions,'--install-extension','anthropic.claude-code')
            $install=Start-CodeCli $codeExe $extensionArgs -Wait
            if ($install.ExitCode -ne 0) {throw 'Claude Code extension installation failed.'}
        }
        if (-not $LoginAccountB -and $config.provider.Kind -eq 'OpenAI') {
            $python=Assert-OpenAiRuntime
            $readyPath=Join-Path $paths.Root ('bridge-' + [guid]::NewGuid().ToString('N') + '.json')
            $clientToken=[guid]::NewGuid().ToString('N')
            $env:LOCAL_SWITCHER_CLIENT_TOKEN=$clientToken
            $env:LOCAL_SWITCHER_UPSTREAM_TOKEN=Get-BackendToken $config.provider
            $env:LOCAL_SWITCHER_PARENT_PID=[string]$PID
            $bridgeArgs=@((Join-Path $PSScriptRoot 'openai_bridge.py'),'--config',$paths.Config,'--ready-file',$readyPath)
            $bridgeProcess=Start-Process -FilePath $python -ArgumentList (($bridgeArgs | ForEach-Object {ConvertTo-ProcessArgument $_}) -join ' ') -WindowStyle Hidden -PassThru
            $deadline=[DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $readyPath)) {
                if ($bridgeProcess.HasExited -or [DateTime]::UtcNow -gt $deadline) {throw 'Local OpenAI adapter did not start.'}
                Start-Sleep -Milliseconds 100
            }
            $ready=Read-JsonFile $readyPath
            $variables=Get-LocalEnvironment $config $paths ('http://127.0.0.1:' + $ready.port)
            $variables['ANTHROPIC_AUTH_TOKEN']=$clientToken
            Set-IsolatedProcessEnvironment $variables
            $health=Invoke-RestMethod -Uri ($variables.ANTHROPIC_BASE_URL + '/health') -Headers @{'x-api-key'=$clientToken} -TimeoutSec 5
            if ($health.adapter -ne 'claude-local-openai' -or $health.pid -ne $bridgeProcess.Id) {throw 'Unexpected local adapter instance.'}
        }
        Update-IsolatedCodeSettings $paths $variables -Login:$LoginAccountB
        $launchArgs=@('--new-window','--user-data-dir',$codeRoot,'--extensions-dir',$paths.Extensions)
        if ($bridgeProcess) {$launchArgs += '--wait'}
        if (-not $LoginAccountB) {$launchArgs += $WorkspacePath}
        Write-Output "Opening isolated VS Code. Claude configuration: $($paths.Claude)"
        if ($LoginAccountB) {Write-Output 'Open Claude Code and sign in with account B. Use a separate browser profile to select the correct account.'}
        $process=Start-CodeCli $codeExe $launchArgs
        if ($bridgeProcess) {
            if ($process.WaitForExit(1000) -and $process.ExitCode -ne 0) {throw 'VS Code rejected the local launch command.'}
        } else {
            if (-not $process.WaitForExit(30000)) {throw 'VS Code did not acknowledge the launch command within 30 seconds.'}
            if ($process.ExitCode -ne 0) {throw 'VS Code rejected the launch command.'}
        }
        Write-LauncherResult $true
        if ($bridgeProcess) {Write-Output 'The adapter stays active until this VS Code window closes.'; $process.WaitForExit()}
    } finally {
        if ($bridgeProcess -and -not $bridgeProcess.HasExited) {Stop-Process -Id $bridgeProcess.Id -ErrorAction SilentlyContinue}
        if ($readyPath -and (Test-Path -LiteralPath $readyPath)) {Remove-Item -LiteralPath $readyPath -Force}
        Restore-ProcessEnvironment $snapshot
    }
} catch {
    # Do not write to an arbitrary ReadyFile after rejecting its location.
    if ($ReadyFile -and (Get-Variable paths -ErrorAction SilentlyContinue) -and [IO.Path]::GetFullPath((Split-Path $ReadyFile -Parent)) -eq $paths.Root) {Write-LauncherResult $false $_.Exception.Message}
    Write-Error $_ -ErrorAction Continue; exit 1
}
exit 0
