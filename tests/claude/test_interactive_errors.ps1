param([string]$Repo=(Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'agents\claude'),[string]$BaseUrl,[ValidateSet('Offline','Auth','Cancel','Unload')][string]$Scenario)
$ErrorActionPreference='Stop';$testEndpoint=$BaseUrl;$testScenario=$Scenario
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('switcher-errors-' + [guid]::NewGuid().ToString('N'))
$script:checks=0
function Check {param([bool]$Ok,[string]$Message);if(-not $Ok){throw $Message};$script:checks++}
function Await-Operation {
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while(($script:job -or $script:unloadJob) -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Poll-WorkflowJobs;Start-Sleep -Milliseconds 20}
    Check (-not $script:job -and -not $script:unloadJob) 'Operation timed out'
}
try {
    . (Join-Path $Repo 'lmstudio_alias_switcher_gui.ps1') -StateRoot $testRoot -GuiTest
    $form.Show();[Windows.Forms.Application]::DoEvents()
    $advancedConnection.Checked=$true;$endpointBox.Text=$testEndpoint
    $connectButton.PerformClick();Await-Operation
    switch($testScenario) {
        'Offline' {
            Check (-not $script:flow.ServerValid -and $script:flow.Step -eq 1 -and $connectButton.Enabled -and $script:flow.Error.Contains($testEndpoint)) 'Server failure has no usable recovery path'
            [void](Invoke-RestMethod ($testEndpoint+'/fixture/control') -Method Post -ContentType 'application/json' -Body '{"fail_catalog":false}')
            $connectButton.PerformClick();Await-Operation
            Check ($script:flow.ServerValid -and $script:flow.Step -eq 2) 'Retry after server recovery failed'
        }
        'Auth' {
            Check ($authRequired.Checked -and $tokenRow.Visible -and -not $connectButton.Enabled -and $script:flow.Step -eq 1) '401 does not guide the user to a required token'
            $tokenBox.Text='fixture-secret';[Windows.Forms.Application]::DoEvents()
            Check $connectButton.Enabled 'Entering required token does not enable retry'
            $connectButton.PerformClick();Await-Operation
            Check $script:flow.ServerValid ('Authenticated retry failed: '+$script:flow.Error)
            $saved=Get-SwitcherConfig $testRoot
            Check ((Get-BackendToken $saved.provider) -eq 'fixture-secret') 'Authenticated server credential was not saved'
        }
        default {
            Check $script:flow.ServerValid ('Cannot connect: '+$script:flow.Error)
            $before=[IO.File]::ReadAllText((Get-StatePaths $testRoot).Config)
            $list.Items[0].Selected=$true;$verifyButton.PerformClick()
            $deadline=[DateTime]::UtcNow.AddSeconds(8)
            do {
                $metrics=Invoke-RestMethod ($testEndpoint+'/fixture/requests')
                [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20
            } while($metrics.message_requests -eq 0 -and [DateTime]::UtcNow -lt $deadline)
            Check ($metrics.message_requests -gt 0 -and $script:job -and $cancelButton.Visible) 'Delayed response did not actually start'
            if($testScenario -eq 'Cancel') {
                $cancelButton.PerformClick();[Windows.Forms.Application]::DoEvents()
                Check (-not $script:job -and -not $script:flow.Busy -and $connectButton.Enabled) 'Cancellation leaves the interface blocked until HTTP returns'
            } else {
                Check $unloadButton.Enabled 'Busy model verification blocks unload'
                $unloadButton.PerformClick();Await-Operation
                Check (-not $script:flow.Busy -and $connectButton.Enabled -and $script:flow.Step -eq 1 -and -not $script:flow.ModelValid) 'Completed unload leaves stale worker blocking the UI'
                Check ([bool]$script:flow.Notice -and -not $script:flow.Error) 'Successful unload is presented as an error'
            }
            $deadline=[DateTime]::UtcNow.AddSeconds(8)
            while($script:cancelledJobs.Count -and [DateTime]::UtcNow -lt $deadline){Poll-WorkflowJobs;[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20}
            Check ($script:cancelledJobs.Count -eq 0) 'Cancelled runspace is not released'
            Check ([IO.File]::ReadAllText((Get-StatePaths $testRoot).Config) -eq $before -and -not $script:flow.ModelValid) 'Cancelled worker saved a binding or reopened later steps'
        }
    }
    # Exercise the real launcher error report without starting VS Code.
    $project=Join-Path $testRoot 'project';[void][IO.Directory]::CreateDirectory($project);Add-LocalProject $testRoot $project
    $refused=$false
    try {Start-IsolatedLauncher $Repo $testRoot -Project $project -TimeoutSeconds 10 | Out-Null} catch {$refused=$_.Exception.Message -match 'sonnet'}
    Check $refused 'Launcher failure was falsely reported as successful startup'
    Write-Output "PASS: $script:checks error/cancellation checks."
} finally {
    if(Get-Variable form -ErrorAction SilentlyContinue){$form.Close();$form.Dispose()}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
