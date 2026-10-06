function New-WorkflowState {
    [pscustomobject]@{
        Step=1; Backend='LMStudio'; RuntimeReady=$false; ConnectionValid=$false; TokenReady=$true
        ServerValid=$false; ModelValid=$false; AccountValid=$false; IdentityConfirmed=$false; ProjectValid=$false
        ModelCount=0; SelectedModel=$false; AuthRequired=$false; AdvancedConnection=$false; AdvancedModel=$false
        Busy=''; Unloading=$false; CanTargetServer=$false; Generation=0; Error=''; AccountEmail=''
    }
}

function Get-WorkflowPolicy {
    param($State)
    $native=$State.Backend -in @('LMStudio','Ollama')
    $idle=-not $State.Busy -and -not $State.Unloading
    $server=$State.ServerValid
    $model=$server -and $State.ModelValid
    $account=$model -and $State.AccountValid -and $State.IdentityConfirmed
    [pscustomobject]@{
        CanGoServer=$idle; CanGoModel=$idle -and $server; CanGoAccount=$idle -and $model; CanGoProject=$idle -and $account
        CanCheckServer=$idle -and ($State.RuntimeReady -or -not $native) -and $State.ConnectionValid -and $State.TokenReady
        CanVerifyModel=$idle -and $server -and $State.ModelCount -gt 0 -and $State.SelectedModel
        CanCheckAccount=$idle -and $model; CanConfirmIdentity=$idle -and $model -and $State.AccountValid
        CanChooseProject=$idle -and $account; CanLaunch=$idle -and $account -and $State.ProjectValid
        CanUnload=$State.CanTargetServer -and -not $State.Unloading
        ShowInstall=$native -and -not $State.RuntimeReady
        ShowEndpoint=$State.AdvancedConnection -or -not $native
        ShowAuthOption=$State.AdvancedConnection -or -not $native -or $State.AuthRequired
        ShowToken=$State.AuthRequired
        ShowContext=$State.AdvancedModel -and $native
        ShowAliases=$State.AdvancedModel -and $model
        ShowModelDiagnostics=$State.AdvancedModel -and $model
    }
}

function Reset-WorkflowServer {
    param($State)
    $State.ServerValid=$false; $State.ModelValid=$false; $State.ModelCount=0; $State.SelectedModel=$false
    $State.Generation++; $State.Error=''; $State.Step=1
}

function Reset-WorkflowModel {
    param($State)
    $State.ModelValid=$false; $State.Generation++; $State.Error=''
}

function Resolve-IsolatedClaudeExecutable {
    param($Paths)
    $folders=@(Get-ChildItem -LiteralPath $Paths.Extensions -Directory -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($folder in $folders) {
        $candidate=Join-Path $folder.FullName 'resources\native-binary\claude.exe'
        if (Test-Path -LiteralPath $candidate) {return $candidate}
    }
    throw 'The isolated Claude Code extension is missing. Open the account B sign-in window to install it.'
}

function ConvertTo-IsolatedAccountStatus {
    param($Data, $Paths)
    $reported=Get-Field $Data 'configDirectory' ''
    if ($reported -and [IO.Path]::GetFullPath($reported) -ne $Paths.Claude) {throw 'Claude reported a different configuration directory.'}
    $method=[string](Get-Field $Data 'authMethod' 'none')
    [pscustomobject]@{LoggedIn=([bool](Get-Field $Data 'loggedIn' $false) -and $method -eq 'claude.ai');Method=$method;Email=[string](Get-Field $Data 'email' '')}
}

function Get-IsolatedAccountStatus {
    param([string]$StateRoot)
    $paths=Get-StatePaths $StateRoot
    $exe=Resolve-IsolatedClaudeExecutable $paths
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$exe; $start.Arguments='auth status --json'; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    foreach ($key in @($start.EnvironmentVariables.Keys)) {
        if ($key -match '^(ANTHROPIC_|CLAUDE_CODE_|CLAUDE_CONFIG_DIR|OLLAMA_)') {$start.EnvironmentVariables.Remove($key)}
    }
    $start.EnvironmentVariables['CLAUDE_CONFIG_DIR']=$paths.Claude
    $start.EnvironmentVariables['DISABLE_TELEMETRY']='1'
    $start.EnvironmentVariables['DISABLE_ERROR_REPORTING']='1'
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(12000)) {$process.Kill();throw 'Claude account check timed out. Retry after closing the login window.'}
        try {$data=$stdout.Result | ConvertFrom-Json} catch {throw 'Cannot read Claude account status. Update the isolated Claude Code extension.'}
        return ConvertTo-IsolatedAccountStatus $data $paths
    } finally {$process.Dispose()}
}
