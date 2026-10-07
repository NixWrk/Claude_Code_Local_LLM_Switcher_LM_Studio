param([string]$Repo=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Repo 'manager.ps1')
. (Join-Path $Repo 'shared\json.ps1')
$script:checks=0
function Assert { param([bool]$Condition,[string]$Message); if (-not $Condition) { throw $Message }; $script:checks++ }
function Assert-Throws { param([scriptblock]$Action,[string]$Message); $thrown=$false;try { & $Action | Out-Null } catch { $thrown=$true }; Assert $thrown $Message }

$snapshot=Get-ProcessEnvironmentSnapshot
try {
    $env:CODEX_MULTI_ACCOUNT_ROOT=''
    $claude=Get-ManagerCommand -Agent Claude -Action Gui
    Assert ($claude.Script -eq (Join-Path $Repo 'agents\claude\lmstudio_alias_switcher_gui.ps1')) 'Claude GUI dispatch points outside its module'
    Assert ($claude.Arguments[1] -eq (Join-Path $env:LOCALAPPDATA 'ClaudeLocalSwitcher\account-b')) 'Existing Claude state root changed'
    Assert ((Get-AgentProfilesRoot Codex) -eq (Join-Path $env:LOCALAPPDATA 'CodexAccounts')) 'Existing Codex profiles root changed'
    foreach ($action in @('Gui','Prepare','Login','Start','ResetChats')) {
        $options=@{Agent='Claude';Action=$action;Name='local-work'}
        if ($action -in @('Start','Prepare')) { $options.WorkspacePath='D:\Fixture project\' }
        $command=Get-ManagerCommand @options
        Assert (Test-Path -LiteralPath $command.Script) "Missing Claude entry point for $action"
        Assert ($command.Arguments[1] -like '*\ClaudeLocalSwitcher\local-work') 'Named Claude profiles share account-b state'
        if ($action -eq 'Login') { Assert ('-LoginAccountB' -in $command.Arguments) 'Login unexpectedly selects local inference' }
    }
    foreach ($action in @('Create','Login','Start','Status')) {
        $command=Get-ManagerCommand -Agent Codex -Action $action -Name work
        Assert (Test-Path -LiteralPath $command.Script) "Missing Codex entry point for $action"
    }
    $customRoot=Join-Path ([IO.Path]::GetTempPath()) 'Manager profiles with spaces'
    $custom=Get-ManagerCommand -Agent Codex -Action Create -Name personal -ProfilesRoot $customRoot -CopyVsCodeSettings -CreateDesktopShortcuts
    Assert ('-CopyVsCodeSettings' -in $custom.Arguments -and '-CreateDesktopShortcuts' -in $custom.Arguments) 'Profile creation options were lost'
    $login=Get-ManagerCommand -Agent Codex -Action Login -Name work -Force
    Assert ('-Force' -in $login.Arguments) 'Account switch option was lost'
    $env:CODEX_MULTI_ACCOUNT_ROOT=$customRoot
    Assert ((Get-AgentProfilesRoot Codex) -eq $customRoot) 'Existing Codex root override was lost'
    Assert-Throws { Get-ManagerCommand -Agent Claude -Action Create } 'Unsupported Claude action accepted'
    Assert-Throws { Get-ManagerCommand -Agent Codex -Action Gui } 'Unsupported Codex action accepted'
    Assert-Throws { Get-ManagerCommand -Agent Codex -Action Start -Name '../escape' } 'Profile path traversal accepted'
    Assert-Throws { Get-ManagerCommand -Agent Claude -Action Start } 'Local launch accepted an absent project'
    Assert-Throws { Get-ManagerCommand -Agent Claude -Action Gui -Force } 'Account replacement option accepted by Claude GUI'
    foreach ($name in @('CON','NUL.txt','COM1','work.')) { Assert-Throws { ConvertTo-SafeProfileName $name } 'Windows reserved profile name accepted' }
    foreach ($protected in @((Join-Path $env:USERPROFILE '.codex\child'),(Join-Path $env:USERPROFILE '.claude'),(Join-Path $env:APPDATA 'Code\child'))) {
        Assert-Throws { Assert-IsolatedStatePath $protected } 'Main agent state accepted as a profile'
    }
    $env:CODEX_HOME='fixture-codex-main';$env:OPENAI_API_KEY='fixture-openai';$env:OPENAI_BASE_URL='fixture-openai-url'
    $env:ANTHROPIC_API_KEY='fixture-anthropic';$env:CLAUDE_CONFIG_DIR='fixture-claude-main';$env:LOCAL_SWITCHER_CLIENT_TOKEN='fixture-adapter'
    Set-AgentProcessEnvironment ([ordered]@{CLAUDE_CONFIG_DIR='fixture-claude-profile'})
    Assert (-not $env:CODEX_HOME -and -not $env:OPENAI_API_KEY -and -not $env:OPENAI_BASE_URL -and -not $env:ANTHROPIC_API_KEY -and -not $env:LOCAL_SWITCHER_CLIENT_TOKEN) 'Codex/cloud/adapter configuration leaked into Claude'
    Set-AgentProcessEnvironment ([ordered]@{CODEX_HOME='fixture-codex-profile'})
    Assert ($env:CODEX_HOME -eq 'fixture-codex-profile' -and -not $env:CLAUDE_CONFIG_DIR) 'Claude configuration leaked into Codex'
} finally { Restore-ProcessEnvironment $snapshot }
Assert ([string]$env:CODEX_HOME -eq [string]$snapshot['CODEX_HOME'] -and [string]$env:OPENAI_API_KEY -eq [string]$snapshot['OPENAI_API_KEY']) 'Parent environment was changed'

# Exercise the public CLI from another working directory, without running agents.
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cliRoot=Join-Path ([IO.Path]::GetTempPath()) ('manager-cli-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($cliRoot)
$stdout=Join-Path $cliRoot 'stdout.json';$stderr=Join-Path $cliRoot 'stderr.txt'
Push-Location ([IO.Path]::GetTempPath())
try {
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Repo 'start.ps1'),'-Agent','Codex','-Action','Start','-Name','work','-WorkspacePath','D:\Fixture project\','-DryRun')
    $process=Start-Process $shell -ArgumentList (($arguments | ForEach-Object {ConvertTo-ProcessArgument $_}) -join ' ') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Assert ($process.ExitCode -eq 0) 'Unified CLI dry run failed outside the repository'
    $process.Dispose()
    $plan=[IO.File]::ReadAllText($stdout) | ConvertFrom-Json
    Assert ($plan.Script -eq (Join-Path $Repo 'agents\codex\scripts\Start-VSCodeCodexProfile.ps1') -and 'D:\Fixture project\' -in $plan.Arguments) 'CLI forwarded the wrong script or project'
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Repo 'start.ps1'),'-Agent','Codex','-Action','Gui','-DryRun')
    $process=Start-Process $shell -ArgumentList (($arguments | ForEach-Object {ConvertTo-ProcessArgument $_}) -join ' ') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Assert ($process.ExitCode -ne 0) 'Invalid CLI action returned success'
    $process.Dispose()
} finally { Pop-Location }

# The module retains the original account state after obsolete wrappers are removed.
. (Join-Path $Repo 'agents\claude\local_switcher_core.ps1')
Assert ((Get-StatePaths).Root -eq (Join-Path $env:LOCALAPPDATA 'ClaudeLocalSwitcher\account-b')) 'Claude module changed the existing profile state'
Write-Output "PASS: $script:checks manager and shared isolation checks (PowerShell $($PSVersionTable.PSVersion))."
