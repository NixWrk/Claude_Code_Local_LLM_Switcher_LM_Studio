# The manager selects a module. Each module owns its authentication and settings.
. (Join-Path $PSScriptRoot 'shared\profiles.ps1')
. (Join-Path $PSScriptRoot 'shared\process.ps1')

function Get-ManagerCommand {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Claude','Codex')][string]$Agent,
        [Parameter(Mandatory=$true)][string]$Action,
        [string]$Name='', [string]$ProfilesRoot='', [string]$StateRoot='', [string]$WorkspacePath='',
        [switch]$Force, [switch]$CopyVsCodeSettings, [switch]$CreateDesktopShortcuts
    )
    $arguments = @()
    if ($Force -and ($Agent -ne 'Codex' -or $Action -ne 'Login')) { throw '-Force applies to Codex Login only.' }
    if (($CopyVsCodeSettings -or $CreateDesktopShortcuts) -and ($Agent -ne 'Codex' -or $Action -ne 'Create')) {
        throw 'Settings copying and desktop shortcuts apply to Codex Create only.'
    }
    if ($Agent -eq 'Claude') {
        if ($StateRoot -and $ProfilesRoot) { throw 'Choose either -StateRoot or -ProfilesRoot.' }
        if (-not $Name) { $Name = 'account-b' }
        $Name = ConvertTo-SafeProfileName $Name
        if (-not $StateRoot) {
            if (-not $ProfilesRoot) { $ProfilesRoot = Get-AgentProfilesRoot Claude }
            $StateRoot = Join-Path $ProfilesRoot $Name
        }
        $StateRoot = [IO.Path]::GetFullPath($StateRoot)
        Assert-IsolatedStatePath $StateRoot
        $module = Join-Path $PSScriptRoot 'agents\claude'
        $file = switch ($Action) {
            'Gui' { 'lmstudio_alias_switcher_gui.ps1' }
            'Prepare' { 'prepare_windows.ps1' }
            'Login' { 'launch_claude_local_vscode.ps1' }
            'Start' { 'launch_claude_local_vscode.ps1' }
            'ResetChats' { 'reset_local_chats.ps1' }
            default { throw "Claude does not support action '$Action'. Choose Gui, Prepare, Login, Start or ResetChats." }
        }
        $arguments += @('-StateRoot', $StateRoot)
        if ($Action -eq 'Login') { $arguments += '-LoginAccountB' }
        if ($WorkspacePath) {
            if ($Action -notin @('Prepare','Start')) { throw '-WorkspacePath applies to Claude Prepare or Start.' }
            $arguments += @('-WorkspacePath', [IO.Path]::GetFullPath($WorkspacePath))
        } elseif ($Action -eq 'Start') { throw 'Choose a registered project with -WorkspacePath.' }
    } else {
        if ($StateRoot) { throw 'Codex uses -ProfilesRoot, not -StateRoot.' }
        $module = Join-Path $PSScriptRoot 'agents\codex\scripts'
        $file = switch ($Action) {
            'Create' { 'New-CodexAccountProfile.ps1' }
            'Login' { 'Login-CodexAccountProfile.ps1' }
            'Start' { 'Start-VSCodeCodexProfile.ps1' }
            'Status' { 'Get-CodexAccountProfiles.ps1' }
            default { throw "Codex does not support action '$Action'. Choose Create, Login, Start or Status." }
        }
        if ($Action -ne 'Status') {
            $Name = ConvertTo-SafeProfileName $Name
            $arguments += @('-Name', $Name)
        }
        if ($ProfilesRoot) {
            $ProfilesRoot = [IO.Path]::GetFullPath($ProfilesRoot)
            Assert-IsolatedStatePath $ProfilesRoot
            $arguments += @('-ProfilesRoot', $ProfilesRoot)
        }
        if ($WorkspacePath) {
            if ($Action -ne 'Start') { throw '-WorkspacePath applies to Codex Start.' }
            $arguments += @('-Path', [IO.Path]::GetFullPath($WorkspacePath))
        }
        if ($Force) { $arguments += '-Force' }
        if ($CopyVsCodeSettings) { $arguments += '-CopyVsCodeSettings' }
        if ($CreateDesktopShortcuts) { $arguments += '-CreateDesktopShortcuts' }
    }
    [pscustomobject]@{ Agent=$Agent; Action=$Action; Script=(Join-Path $module $file); Arguments=@($arguments) }
}

function Invoke-ManagerCommand {
    param($Command)
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$Command.Script) + $Command.Arguments
    # Separate processes preserve module scopes, exit codes and interactive login.
    $process = Start-Process -FilePath $shell -ArgumentList (($arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ') -NoNewWindow -PassThru
    try { $process.WaitForExit(); return $process.ExitCode } finally { $process.Dispose() }
}

function Show-AgentMenu {
    param([ValidateSet('Claude','Codex')][string]$Agent)
    while ($true) {
        Write-Host "`n$Agent - профили" -ForegroundColor Cyan
        if ($Agent -eq 'Claude') {
            Write-Host '1. Настроить локальные модели (графический мастер)'
            Write-Host '2. Войти в аккаунт профиля'
            Write-Host '3. Зарегистрировать проект'
            Write-Host '4. Открыть локальный проект в VS Code'
            $actions = @{ '1'='Gui'; '2'='Login'; '3'='Prepare'; '4'='Start' }
        } else {
            Write-Host '1. Создать профиль и ярлыки'
            Write-Host '2. Войти в аккаунт профиля'
            Write-Host '3. Открыть VS Code'
            Write-Host '4. Проверить аккаунты'
            Write-Host '5. Сменить аккаунт профиля'
            $actions = @{ '1'='Create'; '2'='Login'; '3'='Start'; '4'='Status'; '5'='Login' }
        }
        Write-Host '0. Назад'
        $choice = Read-Host 'Выберите действие'
        if ($choice -eq '0') { return }
        if (-not $actions.ContainsKey($choice)) { continue }
        try {
            $parameters = @{ Agent=$Agent; Action=$actions[$choice] }
            if ($parameters.Action -ne 'Status') {
                $profileName = Read-Host $(if ($Agent -eq 'Claude') { 'Имя профиля [account-b]' } else { 'Имя профиля (work, personal, ...)' })
                if (-not $profileName -and $Agent -eq 'Claude') { $profileName = 'account-b' }
                $parameters.Name = $profileName
            }
            if ($Agent -eq 'Codex' -and $choice -eq '5') { $parameters.Force = $true }
            if ($Agent -eq 'Codex' -and $parameters.Action -eq 'Create') {
                $parameters.CopyVsCodeSettings = $true
                $parameters.CreateDesktopShortcuts = $true
            }
            if ($parameters.Action -in @('Start','Prepare')) {
                $workspace = Read-Host $(if ($Agent -eq 'Codex') { 'Папка проекта [необязательно]' } else { 'Существующая папка проекта' })
                if ($workspace) { $parameters.WorkspacePath = $workspace }
            }
            $command = Get-ManagerCommand @parameters
            $result = Invoke-ManagerCommand $command
            if ($result -ne 0) { Write-Host "Команда завершилась с ошибкой (код $result)." -ForegroundColor Red }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        [void](Read-Host 'Нажмите Enter для продолжения')
    }
}
