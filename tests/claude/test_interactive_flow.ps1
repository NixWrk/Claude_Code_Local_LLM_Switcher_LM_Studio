param([string]$Repo=(Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'agents\claude'),[string]$BaseUrl,[ValidateSet('LMStudio','Ollama','Anthropic','OpenAI')][string]$Backend='LMStudio')
$ErrorActionPreference='Stop'
$testEndpoint=$BaseUrl
$testBackend=$Backend
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('switcher-interactive-' + [guid]::NewGuid().ToString('N'))
$script:checks=0
function Check {param([bool]$Ok,[string]$Message);if(-not $Ok){throw $Message};$script:checks++}
function Open-Choice {
    param($Combo)
    # Native popups require focus; settle queued focus events before opening.
    $form.Activate()
    [void]$Combo.Focus()
    for ($i=0;$i -lt 5;$i++) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
    $Combo.DroppedDown=$true
    Check $Combo.DroppedDown 'Dropdown did not open before its interaction test'
}
function Commit-Choice {
    param($Combo)
    # Trigger the same WinForms event raised by Enter or clicking a menu item.
    $method=$Combo.GetType().GetMethod('OnSelectionChangeCommitted',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($Combo,@([EventArgs]::Empty))
}
function Capture-Form {
    param([string]$Name)
    if (-not $env:SWITCHER_TEST_CAPTURE_DIR) {return}
    $captureDir=[IO.Path]::GetFullPath($env:SWITCHER_TEST_CAPTURE_DIR);[void][IO.Directory]::CreateDirectory($captureDir)
    [Windows.Forms.Application]::DoEvents()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $captureDir ($testBackend+'-'+$Name+'.png')),[Drawing.Imaging.ImageFormat]::Png)} finally {$bitmap.Dispose()}
}
function Await-Operation {
    $deadline=[DateTime]::UtcNow.AddSeconds(25)
    while($script:job -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Poll-WorkflowJobs;Start-Sleep -Milliseconds 20}
    Check (-not $script:job) 'Operation did not complete'
}
try {
    # No preview catalog and no manual readiness flags: exercise application events.
    . (Join-Path $Repo 'lmstudio_alias_switcher_gui.ps1') -StateRoot $testRoot -Backend $testBackend -GuiTest
    $form.Show();[Windows.Forms.Application]::DoEvents()
    Capture-Form 'server'
    Check $connectButton.Enabled 'Server check requires a manual readiness checkbox'
    Open-Choice $backendBox
    for($i=0;$i -lt 5;$i++){Poll-WorkflowJobs;[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20}
    Check $backendBox.DroppedDown 'Idle refresh closes the runtime dropdown'
    $backendBox.DroppedDown=$false
    $advancedConnection.Checked=$true
    $endpointBox.Text=$testEndpoint
    $connectButton.PerformClick();Await-Operation
    Check $script:flow.ServerValid ('Connection failed: ' + $script:flow.Error)
    $list.Items[0].Selected=$true;[Windows.Forms.Application]::DoEvents()
    $verifyButton.PerformClick();Await-Operation
    Check $script:flow.ModelValid ('Model failed: ' + $script:flow.Error)
    Check $nextButton.Enabled 'Validated model cannot proceed'
    Capture-Form 'model'
    $stepButtons[0].PerformClick();[Windows.Forms.Application]::DoEvents()
    $generation=$script:flow.Generation;$originalIndex=$backendBox.SelectedIndex
    Open-Choice $backendBox;$backendBox.SelectedIndex=($originalIndex+1)%4;[Windows.Forms.Application]::DoEvents()
    Check ($script:flow.Generation -eq $generation -and $script:flow.ModelValid) 'Arrow-style preview in runtime dropdown invalidates the active model before commit'
    $backendBox.DroppedDown=$false;[Windows.Forms.Application]::DoEvents()
    Check ($backendBox.SelectedIndex -eq $originalIndex -and $script:flow.Generation -eq $generation -and $script:flow.ModelValid) 'Cancelling runtime dropdown does not restore selection/readiness'
    $stepButtons[1].PerformClick();[Windows.Forms.Application]::DoEvents()
    $nextButton.PerformClick();[Windows.Forms.Application]::DoEvents()
    Check ($script:flow.Step -eq 3) 'Next button did not open account page'
    $backButton.PerformClick();[Windows.Forms.Application]::DoEvents()
    Check ($script:flow.Step -eq 2 -and $script:flow.ModelValid) 'Returning to model page lost validation'
    # Clearing/reselecting the same entry is not a model configuration change.
    $key=$list.SelectedItems[0].Tag.ModelKey
    $list.SelectedItems.Clear();$list.Items[0].Selected=$true;[Windows.Forms.Application]::DoEvents()
    Check $script:flow.ModelValid 'Reselecting the verified model loses validation'
    $advancedModel.Checked=$true
    Open-Choice $aliasBox
    $aliasBox.SelectedItem='opus'
    Poll-WorkflowJobs;[Windows.Forms.Application]::DoEvents()
    Check $aliasBox.DroppedDown 'Idle refresh closes the family dropdown'
    $aliasBox.DroppedDown=$false
    Check ($aliasBox.SelectedItem -eq 'sonnet' -and $script:flow.ModelValid) 'Cancelled role preview changes the applied family'
    Open-Choice $aliasBox;$aliasBox.SelectedItem='opus';Commit-Choice $aliasBox;$aliasBox.DroppedDown=$false
    Check ($script:selectedAlias -eq 'opus' -and $script:flow.ModelValid) 'Committed role choice is lost on dropdown close'
    $advancedModel.Checked=$false;[Windows.Forms.Application]::DoEvents()
    Check $script:flow.ModelValid 'Closing optional settings invalidates the working main model'
    $filterBox.Text='no-matching-model';[Windows.Forms.Application]::DoEvents()
    Check ($list.Items.Count -eq 0) 'Filter failed'
    Check ($emptyModelHelp.Visible -and $emptyModelHelp.Text -notmatch 'Скачайте') 'Filtered empty list has no useful recovery message'
    $filterBox.Clear();[Windows.Forms.Application]::DoEvents()
    Check $script:flow.ModelValid 'Filtering the catalog invalidates the working model'
    # A local fixture executable supplies auth status; no real account is used.
    $native=Join-Path (Get-StatePaths $testRoot).Extensions 'anthropic.claude-code-fixture\resources\native-binary'
    [void][IO.Directory]::CreateDirectory($native)
    $fixtureSource=Join-Path $testRoot 'AuthFixture.cs'
    [IO.File]::WriteAllText($fixtureSource,'using System;using System.IO;class AuthFixture{static void Main(){Console.OutputEncoding=new System.Text.UTF8Encoding(false);Console.WriteLine(File.ReadAllText(Path.Combine(Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR"),"auth-fixture.json")));}}')
    $build=Join-Path $testRoot 'build.ps1'
    [IO.File]::WriteAllText($build,'param($Source,$Exe);Add-Type -Path $Source -OutputAssembly $Exe -OutputType ConsoleApplication')
    $exe=Join-Path $native 'claude.exe'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build $fixtureSource $exe
    Check ($LASTEXITCODE -eq 0) 'Cannot compile isolated auth fixture'
    [IO.File]::WriteAllText(($exe+'.config'),'<configuration><startup><supportedRuntime version="v4.0" /></startup></configuration>')
    $authPaths=Get-StatePaths $testRoot
    $authFile=Join-Path $authPaths.Claude 'auth-fixture.json'
    Write-JsonFile $authFile ([pscustomobject]@{loggedIn=$false;authMethod='none';configDirectory=$authPaths.Claude})
    $nextButton.PerformClick();[Windows.Forms.Application]::DoEvents()
    $checkAccountButton.PerformClick();Await-Operation
    Check (-not $script:flow.AccountValid -and -not $identityCheck.Visible -and -not $nextButton.Enabled) 'Signed-out account fixture unlocks project step'
    Write-JsonFile $authFile ([pscustomobject]@{loggedIn=$true;authMethod='claude.ai';email='fixture-no-real-login@example.test';configDirectory=$authPaths.Claude})
    $checkAccountButton.PerformClick();Await-Operation
    Check ($script:flow.AccountValid -and -not $nextButton.Enabled) ('Account fixture check failed: ' + $script:flow.Error + '; Account=' + $script:flow.AccountValid + '; Next=' + $nextButton.Enabled + '; Model=' + $script:flow.ModelValid + '; Log=' + $log.Text)
    $identityCheck.Checked=$true;[Windows.Forms.Application]::DoEvents()
    $nextButton.PerformClick();[Windows.Forms.Application]::DoEvents()
    Check ($script:flow.Step -eq 4 -and -not $launchButton.Enabled) 'Project step opens with no project but launch is already enabled'
    $project1=Join-Path $testRoot 'Separate project one';$project2=Join-Path $testRoot 'Separate project two'
    [void][IO.Directory]::CreateDirectory($project1);[void][IO.Directory]::CreateDirectory($project2)
    Register-WorkflowProject $project1;Register-WorkflowProject $project2
    Open-Choice $projectBox;Poll-WorkflowJobs;[Windows.Forms.Application]::DoEvents()
    Check $projectBox.DroppedDown 'Idle refresh closes project dropdown'
    $projectBox.SelectedItem=$project1
    Check ($script:selectedProject -eq $project2 -and $projectSummary.Text.Contains($project2)) 'Project preview prematurely changes launch target'
    $projectBox.DroppedDown=$false
    Check ($projectBox.SelectedItem -eq $project2) 'Cancelling project dropdown does not restore the previous project'
    Open-Choice $projectBox;$projectBox.SelectedItem=$project1;Commit-Choice $projectBox;$projectBox.DroppedDown=$false;[Windows.Forms.Application]::DoEvents()
    Check ($script:flow.ProjectValid -and $launchButton.Enabled -and $projectSummary.Text.Contains($project1)) 'Project dropdown choice does not update the launch target'
    $projectBox.SelectedItem=$project2;$projectBox.SelectedItem=$project1;[Windows.Forms.Application]::DoEvents()
    Check ($script:flow.ProjectValid -and $launchButton.Enabled) 'Repeated project dropdown changes lose readiness'
    $form.ClientSize=New-Object Drawing.Size(920,680);[Windows.Forms.Application]::DoEvents()
    Check ($nav.Bounds.Right -le $root.ClientSize.Width-$root.Padding.Right -and $footer.Bounds.Bottom -le $root.ClientSize.Height-$root.Padding.Bottom -and $stepButtons[3].Bounds.Right -le $nav.ClientSize.Width) 'Small window clips navigation or launch footer'
    Capture-Form 'project-small'
    Write-JsonFile $authFile ([pscustomobject]@{loggedIn=$false;authMethod='none';configDirectory=$authPaths.Claude})
    $launchButton.PerformClick();Await-Operation
    Check ($script:flow.Step -eq 3 -and -not $script:flow.AccountValid -and -not $launchButton.Enabled) 'Launch does not catch account sign-out before spawning VS Code'
    $stepButtons[0].PerformClick();[Windows.Forms.Application]::DoEvents()
    if($backendBox.SelectedItem -eq 'Ollama'){$backendBox.SelectedItem='LM Studio'}
    Open-Choice $backendBox;$backendBox.SelectedItem='Ollama';Commit-Choice $backendBox;$backendBox.DroppedDown=$false;[Windows.Forms.Application]::DoEvents()
    Check (-not $script:flow.ServerValid -and -not $script:flow.ModelValid) 'Switching providers kept validation'
    Check ($null -eq $script:runtimeTarget -or $script:runtimeTarget.Kind -eq 'Ollama') 'Unload still targets the previously selected engine'
    Check ($endpointBox.Text -eq $(if($testBackend -eq 'Ollama'){$testEndpoint}else{'http://localhost:11434'})) 'Wrong URL after selecting Ollama'
    $backendBox.SelectedItem='Другой сервер — OpenAI API';[Windows.Forms.Application]::DoEvents()
    Check ($endpointBox.Text -eq $(if($testBackend -eq 'OpenAI'){$testEndpoint}else{'http://localhost:8080'}) -and -not $runtimeChoice.Visible -and -not $contextRow.Visible) ('OpenAI choice mismatch: url='+$endpointBox.Text+'; kind='+$script:selectedBackendKind+'; flag='+$script:openDropdowns.Backend+'; open='+$backendBox.DroppedDown)
    $backendBox.SelectedItem='Другой сервер — Anthropic API';[Windows.Forms.Application]::DoEvents()
    Check ($endpointBox.Text -eq $(if($testBackend -eq 'Anthropic'){$testEndpoint}else{'http://localhost:8080'}) -and -not $runtimeChoice.Visible) 'Anthropic dropdown choice shows native installation'
    $backendBox.SelectedIndex=[array]::IndexOf(@('LMStudio','Ollama','Anthropic','OpenAI'),$testBackend);[Windows.Forms.Application]::DoEvents()
    Check ($endpointBox.Text -eq $testEndpoint) 'Returning to the saved runtime loses its URL'
    $generation=$script:flow.Generation;$backendBox.SelectedIndex=[array]::IndexOf(@('LMStudio','Ollama','Anthropic','OpenAI'),$testBackend)
    Check ($script:flow.Generation -eq $generation) 'Reselecting the same runtime invalidates configuration'
    $backendBox.SelectedItem='Другой сервер — OpenAI API';$endpointBox.Text='http://localhost:31234';$authRequired.Checked=$true;$tokenBox.Text='fixture-draft-token'
    $backendBox.SelectedItem='LM Studio';$backendBox.SelectedItem='Другой сервер — OpenAI API';[Windows.Forms.Application]::DoEvents()
    Check ($endpointBox.Text -eq 'http://localhost:31234' -and $authRequired.Checked -and $tokenBox.Text -eq 'fixture-draft-token') 'Switching dropdown choices discards the per-server draft'
    Check ((Get-SwitcherConfig $testRoot).provider.BaseUrl -eq $testEndpoint) 'Dropdown edits silently save an unchecked server'
    Write-Output "PASS: $script:checks interactive flow checks."
} finally {
    if(Get-Variable form -ErrorAction SilentlyContinue){$form.Close();$form.Dispose()}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
