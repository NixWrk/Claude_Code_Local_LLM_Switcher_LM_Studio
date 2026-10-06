function New-WorkflowState {
    [pscustomobject]@{
        Step=1; Backend='LMStudio'; RuntimeReady=$false; ConnectionValid=$false; TokenReady=$true
        ServerValid=$false; ModelValid=$false; AccountValid=$false; IdentityConfirmed=$false; ProjectValid=$false
        ModelCount=0; SelectedModel=$false; AuthRequired=$false; AdvancedConnection=$false; AdvancedModel=$false
        Busy=''; Unloading=$false; CanTargetServer=$false; Generation=0; Error=''; Notice=''; AccountEmail=''; InstallHelp=$false;AdapterMissing=$false
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
        CanCheckServer=$idle -and $State.ConnectionValid -and $State.TokenReady
        CanVerifyModel=$idle -and $server -and $State.ModelCount -gt 0 -and $State.SelectedModel
        CanCheckAccount=$idle -and $model; CanConfirmIdentity=$idle -and $model -and $State.AccountValid
        CanChooseProject=$idle -and $account; CanLaunch=$idle -and $account -and $State.ProjectValid
        CanUnload=$State.CanTargetServer -and -not $State.Unloading
        ShowInstall=$native -and $State.InstallHelp
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
    $State.Generation++; $State.Error=''; $State.Notice=''; $State.Step=1
    $State.AdapterMissing=$false
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
    param([string]$StateRoot,[switch]$InChild)
    $paths=Get-StatePaths $StateRoot
    $start=New-Object Diagnostics.ProcessStartInfo
    if ($InChild) {
        $start.FileName=Resolve-IsolatedClaudeExecutable $paths;$start.Arguments='auth status --json'
    } else {
        # Normalize inherited environment casing in a separate process. Windows
        # can expose both Path/PATH, which breaks .NET Framework's child dictionary.
        $start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'account_status.ps1'),'-StateRoot',$paths.Root)
        $start.Arguments=($args | ForEach-Object {ConvertTo-ProcessArgument $_}) -join ' '
    }
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    if ($InChild) {
        $childEnvironment=$start.get_EnvironmentVariables()
        foreach ($entry in @($childEnvironment.GetEnumerator())) {
            if ($entry.Key -match '^(ANTHROPIC_|CLAUDE_CODE_|CLAUDE_CONFIG_DIR|OLLAMA_)') {$childEnvironment.Remove($entry.Key)}
        }
        $childEnvironment['CLAUDE_CONFIG_DIR']=$paths.Claude
        $childEnvironment['DISABLE_TELEMETRY']='1'
        $childEnvironment['DISABLE_ERROR_REPORTING']='1'
    }
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($(if ($InChild) {12000} else {16000}))) {$process.Kill();throw 'Проверка входа не завершилась вовремя. Закройте окно входа и повторите проверку.'}
        try {$data=$stdout.Result | ConvertFrom-Json} catch {throw 'Cannot read Claude account status. Update the isolated Claude Code extension.'}
        if (-not $InChild) {
            if ($process.ExitCode -ne 0) {throw [string](Get-Field $data 'Error' 'Не удалось проверить вход в отдельном профиле.')}
            return $data
        }
        return ConvertTo-IsolatedAccountStatus $data $paths
    } finally {$process.Dispose()}
}

function Start-IsolatedLauncher {
    param([string]$Repo,[string]$StateRoot,[switch]$Login,[string]$Project='',[int]$TimeoutSeconds=180)
    $paths=Get-StatePaths $StateRoot
    [void][IO.Directory]::CreateDirectory($paths.Root)
    $ready=Join-Path $paths.Root ('launcher-' + [guid]::NewGuid().ToString('N') + '.ready.json')
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Repo 'launch_claude_local_vscode.ps1'),'-StateRoot',$paths.Root,'-ReadyFile',$ready)
    if ($Login) {$arguments+='-LoginAccountB'} else {$arguments+=@('-WorkspacePath',$Project)}
    $launcher=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList (($arguments | ForEach-Object {ConvertTo-ProcessArgument $_}) -join ' ') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $paths.Root 'launcher-errors.log') -RedirectStandardOutput (Join-Path $paths.Root 'launcher-output.log')
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not (Test-Path -LiteralPath $ready)) {
            if ($launcher.HasExited) {throw 'Подготовка VS Code завершилась с ошибкой. Подробности: launcher-errors.log в отдельном профиле.'}
            if ([DateTime]::UtcNow -ge $deadline) {throw 'VS Code не подтвердил запуск за 3 минуты. Проверьте подключение для установки расширения и launcher-errors.log в отдельном профиле.'}
            [void]$launcher.WaitForExit(100)
        }
        $result=Read-JsonFile $ready
        if ((Get-Field $result 'Source') -ne 'switcher-vscode-launch' -or (Get-Field $result 'ProcessId') -ne $launcher.Id) {throw 'Unexpected VS Code launcher response.'}
        if (-not $result.Success) {
            [void]$launcher.WaitForExit(5000)
            throw ('Не удалось запустить VS Code: ' + $result.Error)
        }
        return [pscustomobject]@{Accepted=$true;ProcessId=$launcher.Id}
    } finally {
        $launcher.Dispose()
        if (Test-Path -LiteralPath $ready) {Remove-Item -LiteralPath $ready -Force}
    }
}

function Assert-OpenAiRuntime {
    param([string]$PythonExecutable='')
    if (-not $PythonExecutable) {$command=Get-Command python -CommandType Application -ErrorAction SilentlyContinue;if ($command) {$PythonExecutable=$command.Source}}
    $message='PYTHON_GATE: Для OpenAI API нужен Python 3.9 или новее. Установите Python с добавлением в PATH и повторите проверку сервера.'
    if (-not $PythonExecutable -or -not (Test-Path -LiteralPath $PythonExecutable -PathType Leaf) -or $PythonExecutable -match '\\WindowsApps\\python(?:3)?\.exe$') {throw $message}
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$PythonExecutable;$start.Arguments='-c "import sys; print(int(sys.version_info >= (3,9)))"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start
    try {
        [void]$process.Start();$output=$process.StandardOutput.ReadToEndAsync();$errorOutput=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {$process.Kill();throw $message}
        if ($process.ExitCode -ne 0 -or $output.Result.Trim() -ne '1') {throw $message}
        return $PythonExecutable
    } finally {$process.Dispose()}
}
