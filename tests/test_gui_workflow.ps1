param([string]$Repo = (Split-Path $PSScriptRoot -Parent), [string]$BaseUrl = '', [switch]$ExpectToolFailure)
$ErrorActionPreference='Stop'
. (Join-Path $Repo 'local_switcher_core.ps1')
. (Join-Path $Repo 'gui_workflow.ps1')
$script:assertions=0
function Assert-Flow {param([bool]$Condition,[string]$Message);if (-not $Condition) {throw $Message};$script:assertions++}
$s=New-WorkflowState
$s.ConnectionValid=$true
$policy=Get-WorkflowPolicy $s
Assert-Flow (-not $policy.CanCheckServer -and $policy.ShowInstall) 'Native installation path must precede server check'
Assert-Flow (-not $policy.CanGoModel -and -not $policy.CanLaunch) 'Future steps unlocked before connection'
$s.RuntimeReady=$true
Assert-Flow (Get-WorkflowPolicy $s).CanCheckServer 'Prepared native runtime cannot be checked'
$s.AuthRequired=$true;$s.TokenReady=$false
Assert-Flow (-not (Get-WorkflowPolicy $s).CanCheckServer -and (Get-WorkflowPolicy $s).ShowToken) 'Missing required token did not block connection'
$s.TokenReady=$true;$s.ServerValid=$true;$s.ModelCount=2;$s.SelectedModel=$true
Assert-Flow (Get-WorkflowPolicy $s).CanVerifyModel 'Available model cannot be verified'
Assert-Flow (-not (Get-WorkflowPolicy $s).CanGoAccount) 'Account step opened without a validated model'
$s.ModelValid=$true
Assert-Flow (Get-WorkflowPolicy $s).CanGoAccount 'Verified model did not unlock account step'
$s.AccountValid=$true
Assert-Flow (-not (Get-WorkflowPolicy $s).CanGoProject) 'Unconfirmed identity unlocked project'
$s.IdentityConfirmed=$true
Assert-Flow (Get-WorkflowPolicy $s).CanChooseProject 'Verified identity did not unlock project selection'
Assert-Flow (-not (Get-WorkflowPolicy $s).CanLaunch) 'Missing project did not block launch'
$s.ProjectValid=$true
Assert-Flow (Get-WorkflowPolicy $s).CanLaunch 'Complete workflow cannot launch'
$s.AdvancedModel=$true;$s.Backend='OpenAI'
Assert-Flow (-not (Get-WorkflowPolicy $s).ShowContext) 'Generic server exposes unsupported context controls'
Assert-Flow (-not (Get-WorkflowPolicy $s).ShowInstall -and (Get-WorkflowPolicy $s).ShowEndpoint) 'Wrong controls for generic server'
$s.Backend='Ollama';$s.CanTargetServer=$true;$s.Busy='Verify'
Assert-Flow ((Get-WorkflowPolicy $s).CanUnload -and -not (Get-WorkflowPolicy $s).CanLaunch) 'Busy worker blocks emergency unload or allows launch'
$s.Busy='';$generation=$s.Generation;Reset-WorkflowServer $s
Assert-Flow ($s.Generation -gt $generation -and -not $s.ServerValid -and -not $s.ModelValid) 'Server edit did not invalidate dependencies/stale completions'
Assert-Flow ($s.AccountValid -and $s.IdentityConfirmed) 'Independent account validation lost on server edit'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('switcher-gui-' + [guid]::NewGuid().ToString('N'))
$authPaths=Get-StatePaths $tmp
$auth=ConvertTo-IsolatedAccountStatus ([pscustomobject]@{loggedIn=$true;authMethod='api_key';email='b@example.test';configDirectory=$authPaths.Claude}) $authPaths
Assert-Flow (-not $auth.LoggedIn) 'Backend/API-key credentials mistaken for account B login'
$auth=ConvertTo-IsolatedAccountStatus ([pscustomobject]@{loggedIn=$true;authMethod='claude.ai';email='b@example.test';configDirectory=$authPaths.Claude}) $authPaths
Assert-Flow ($auth.LoggedIn -and $auth.Email -eq 'b@example.test') 'Isolated Claude account not recognized'
$refused=$false
try {ConvertTo-IsolatedAccountStatus ([pscustomobject]@{loggedIn=$true;authMethod='claude.ai';configDirectory=(Join-Path $env:USERPROFILE '.claude')}) $authPaths | Out-Null} catch {$refused=$true}
Assert-Flow $refused 'Main account directory accepted as isolated account B'

# Inspect the actual WinForms controls, including their hidden/disabled states.
. (Join-Path $Repo 'lmstudio_alias_switcher_gui.ps1') -StateRoot $tmp -GuiTest -PreviewModelsFile (Join-Path $Repo 'tests\preview-models.json')
$script:changing=$true
$backendBox.SelectedIndex=0;$runtimeChoice.Checked=$true;$script:changing=$false
Update-WorkflowUi
Assert-Flow (-not $verifyButton.Enabled -and -not $launchButton.Enabled) 'Actual controls ignore prerequisite gates'
Assert-Flow (-not $tokenRow.Visible) 'Token field shown when not required'
$script:flow.ServerValid=$true;$script:flow.ModelCount=$script:catalog.Count;$script:flow.Step=2
$form.Show();[Windows.Forms.Application]::DoEvents()
$list.Items[0].Selected=$true
Update-WorkflowUi
Assert-Flow $verifyButton.Enabled 'Selected model cannot be verified in actual form'
Assert-Flow (-not $contextRow.Visible -and -not $aliasRow.Visible -and -not $diagnosticsRow.Visible) 'Optional controls are not collapsed'
$advancedModel.Checked=$true;Update-WorkflowUi
Assert-Flow ($contextRow.Visible -and -not $aliasRow.Visible) 'Context/additional family controls violate their prerequisites'
$script:flow.ModelValid=$true;Update-WorkflowUi
Assert-Flow $aliasRow.Visible 'Additional families did not appear after main model verification'
$aliasBox.SelectedIndex=1;$advancedModel.Checked=$false;Update-WorkflowUi
Assert-Flow (-not $script:flow.ModelValid -and $aliasBox.SelectedItem -eq 'sonnet') 'Collapsing optional family controls kept a mismatched main model validation'
$script:changing=$true;$backendBox.SelectedIndex=3;$script:changing=$false;Update-WorkflowUi
Assert-Flow (-not $contextRow.Visible) 'Generic server context still visible in real form'
Assert-Flow (-not $advancedConnection.Visible) 'Generic server exposes an ineffective optional address checkbox'
$script:flow.Busy='Verify';$script:runtimeTarget=New-Provider OpenAI;Update-WorkflowUi
Assert-Flow ($unloadButton.Enabled -and -not $launchButton.Enabled) 'Emergency button blocked while actual form is busy'
Assert-Flow (-not $filterBox.Enabled) 'Busy model operation allows catalog/selection edits'
$script:flow.Busy='';$script:flow.ModelValid=$false;Update-WorkflowUi
Assert-Flow (-not $stepButtons[2].Enabled -and -not $stepButtons[3].Enabled) 'Completion indiscriminately re-enabled future navigation'

if ($BaseUrl) {
    $script:changing=$true;$backendBox.SelectedIndex=0;$endpointBox.Text=$BaseUrl;$runtimeChoice.Checked=$true;$script:changing=$false
    Reset-WorkflowServer $script:flow;Update-WorkflowUi
    Start-WorkflowJob 'Connect'
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while ($script:job -and [DateTime]::UtcNow -lt $deadline) {Poll-WorkflowJobs;[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 25}
    Assert-Flow ($script:flow.ServerValid -and $script:flow.Step -eq 2 -and $script:flow.ModelCount -gt 0) ('Async catalog step failed: ' + $script:flow.Error)
    $before=[IO.File]::ReadAllText((Get-StatePaths $tmp).Config)
    $list.Items[0].Selected=$true;Update-WorkflowUi;Start-WorkflowJob 'Verify'
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while ($script:job -and [DateTime]::UtcNow -lt $deadline) {Poll-WorkflowJobs;[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 25}
    if ($ExpectToolFailure) {
        Assert-Flow (-not $script:flow.ModelValid -and [bool]$script:flow.Error) 'Failed tool probe unlocked later steps'
        Assert-Flow ([IO.File]::ReadAllText((Get-StatePaths $tmp).Config) -eq $before) 'Failed tool probe committed the model mapping'
    } else {
        Assert-Flow $script:flow.ModelValid ('Async model/tool validation failed: ' + $script:flow.Error)
    }
    Assert-Flow (-not $launchButton.Enabled -and -not (Get-WorkflowPolicy $script:flow).CanGoProject) 'HTTP success skipped account/project requirements'
    Start-WorkflowJob 'Connect'
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while ($script:job -and -not $script:job.Pending.IsCompleted -and [DateTime]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 25}
    Reset-WorkflowServer $script:flow;Poll-WorkflowJobs
    Assert-Flow (-not $script:flow.ServerValid -and -not $script:flow.ModelValid -and $script:flow.Step -eq 1) 'Stale async completion reopened invalidated steps'
}
$form.Close();$form.Dispose()
if (Test-Path -LiteralPath $tmp) {Remove-Item -LiteralPath $tmp -Recurse -Force}
Write-Output "PASS: $script:assertions workflow/control checks."
