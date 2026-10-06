param(
    [switch]$Headless,
    [ValidateSet('LMStudio','Ollama','Anthropic','OpenAI')][string]$Backend = '',
    [string]$BaseUrl = '', [string]$AuthToken = '', [string]$StateRoot = '',
    [ValidateSet('sonnet','opus','haiku')][string]$Alias = 'sonnet',
    [string]$ModelKey = '', [int]$ContextLength = 0,
    [switch]$TestAlias, [switch]$TestTools, [switch]$ShowLoaded, [switch]$ListModels,
    [switch]$UnloadAll, [switch]$ForceUnload,
    [switch]$DisableClaudeAliasSync,
    [string]$PreviewPath = '', [string]$PreviewModelsFile = ''
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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='Claude Code - Local Models / Account B'
$form.ClientSize=New-Object Drawing.Size(1080,760)
$form.MinimumSize=New-Object Drawing.Size(1020,760)
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.Padding=New-Object Windows.Forms.Padding(16)
$layout.ColumnCount=1; $layout.RowCount=8
foreach ($height in @(44,42,44,80,52,40)) {[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',110)))
$form.Controls.Add($layout)

function New-Row {
    param([int]$Row)
    $panel=New-Object Windows.Forms.FlowLayoutPanel
    $panel.Dock='Fill'; $panel.WrapContents=$false
    $layout.Controls.Add($panel,0,$Row)
    return $panel
}
function New-Label {
    param($Panel,[string]$Text)
    $label=New-Object Windows.Forms.Label
    $label.Text=$Text; $label.AutoSize=$true; $label.Margin=New-Object Windows.Forms.Padding(0,7,8,0)
    $Panel.Controls.Add($label); return $label
}
function New-Button {
    param($Panel,[string]$Text,[int]$Width=150)
    $button=New-Object Windows.Forms.Button
    $button.Text=$Text; $button.Size=New-Object Drawing.Size($Width,32)
    $button.Margin=New-Object Windows.Forms.Padding(0,0,8,0)
    $Panel.Controls.Add($button); return $button
}
function New-TextBox {
    param($Panel,[int]$Width)
    $box=New-Object Windows.Forms.TextBox
    $box.Width=$Width; $box.Margin=New-Object Windows.Forms.Padding(0,3,8,0)
    $Panel.Controls.Add($box); return $box
}

$title=New-Object Windows.Forms.Label
$title.Text='Local models, separate projects and chats'
$title.Font=New-Object Drawing.Font('Segoe UI',16,[Drawing.FontStyle]::Bold)
$title.Dock='Fill'; $layout.Controls.Add($title,0,0)
$connectionRow=New-Row 1
[void](New-Label $connectionRow 'Server')
$backendBox=New-Object Windows.Forms.ComboBox
$backendBox.DropDownStyle='DropDownList'; $backendBox.Width=140
[void]$backendBox.Items.AddRange(@('LMStudio','Ollama','Anthropic','OpenAI'))
$backendBox.SelectedItem=$provider.Kind; $connectionRow.Controls.Add($backendBox)
$endpointBox=New-TextBox $connectionRow 270; $endpointBox.Text=$provider.BaseUrl
[void](New-Label $connectionRow 'Token')
$tokenBox=New-TextBox $connectionRow 140; $tokenBox.UseSystemPasswordChar=$true
$tokenBox.AccessibleName='Backend API token (blank keeps the saved token for this endpoint)'
$saveServerButton=New-Button $connectionRow 'Save server' 115
$refreshButton=New-Button $connectionRow 'Refresh models' 145

$projectRow=New-Row 2
[void](New-Label $projectRow 'Project')
$projectBox=New-Object Windows.Forms.ComboBox
$projectBox.DropDownStyle='DropDownList'; $projectBox.Width=400; $projectRow.Controls.Add($projectBox)
foreach ($project in @($config.projects)) {[void]$projectBox.Items.Add($project)}
if ($projectBox.Items.Count) {$projectBox.SelectedIndex=0}
$addProjectButton=New-Button $projectRow 'Add project' 125
$launchButton=New-Button $projectRow 'Open local VS Code' 175
$loginButton=New-Button $projectRow 'Sign in account B' 170

$bindingRow=New-Row 3
[void](New-Label $bindingRow 'Claude alias')
$aliasBox=New-Object Windows.Forms.ComboBox
$aliasBox.DropDownStyle='DropDownList'; $aliasBox.Width=95; [void]$aliasBox.Items.AddRange(@('sonnet','opus','haiku'))
$aliasBox.SelectedIndex=0; $bindingRow.Controls.Add($aliasBox)
[void](New-Label $bindingRow 'Context (0 = server default)')
$contextBox=New-Object Windows.Forms.NumericUpDown
$contextBox.Minimum=0; $contextBox.Maximum=1048576; $contextBox.Increment=1024; $contextBox.ThousandsSeparator=$true
$contextBox.Width=120; $bindingRow.Controls.Add($contextBox)
$bindButton=New-Button $bindingRow 'Use selected model' 180
$testButton=New-Button $bindingRow 'Test response' 145
$toolsButton=New-Button $bindingRow 'Test tools' 120
$bindingRow.WrapContents=$true
$unloadButton=New-Button $bindingRow 'Unload all models' 180
$unloadButton.AccessibleDescription='Unload models from the selected server; if it is unresponsive, stop its process tree.'
[void](New-Label $bindingRow 'If the server hangs, this also stops its processes.')

$statusBox=New-Object Windows.Forms.TextBox
$statusBox.Multiline=$true; $statusBox.ReadOnly=$true; $statusBox.Dock='Fill'; $statusBox.ScrollBars='Vertical'
$layout.Controls.Add($statusBox,0,4)
$filterRow=New-Row 5
[void](New-Label $filterRow 'Filter')
$filterBox=New-TextBox $filterRow 320
$sortHint=New-Label $filterRow 'Largest models first. Click a column to change order.'
$ollamaButton=New-Button $filterRow 'Get Ollama' 120
$lmButton=New-Button $filterRow 'Get LM Studio' 140

$list=New-Object Windows.Forms.ListView
$list.Dock='Fill'; $list.View='Details'; $list.FullRowSelect=$true; $list.MultiSelect=$false
$list.HideSelection=$false; $list.GridLines=$true; $list.ShowItemToolTips=$true
$emptyLabel=New-Object Windows.Forms.Label
$emptyLabel.Text="No local models listed.`r`nStart a server, then click Refresh models."
$emptyLabel.TextAlign='MiddleCenter';$emptyLabel.Dock='Fill';$emptyLabel.BackColor=[Drawing.SystemColors]::Window
$list.Controls.Add($emptyLabel)
$headers=@('Model key','Name','Publisher','Size (GiB)','Parameters','Architecture')
$widths=@(290,230,110,120,110,110)
for ($i=0;$i -lt $headers.Count;$i++) {[void]$list.Columns.Add($headers[$i],$widths[$i])}
$layout.Controls.Add($list,0,6)
$log=New-Object Windows.Forms.TextBox
$log.Multiline=$true; $log.ReadOnly=$true; $log.Dock='Fill'; $log.ScrollBars='Vertical'
$layout.Controls.Add($log,0,7)

$script:models=@(); $script:column=3; $script:descending=$true; $script:lastClick=-1
$script:worker=$null; $script:pending=$null; $script:operation=''
$script:unloadWorker=$null; $script:unloadPending=$null
$script:activeProvider=$provider
$script:busyControls=@($backendBox,$endpointBox,$tokenBox,$saveServerButton,$refreshButton,$aliasBox,$contextBox,$bindButton,$testButton,$toolsButton,$launchButton,$loginButton,$addProjectButton,$projectBox)

function Write-GuiLog {param([string]$Message); $log.AppendText(('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message + "`r`n"))}
function Update-BindingStatus {
    $saved=Get-SwitcherConfig $paths.Root
    $lines=@("Saved backend: $($saved.provider.Kind) | $($saved.provider.BaseUrl) | Account B: separate sign-in (not verified by this switcher)")
    foreach ($name in @('sonnet','opus','haiku')) {
        $binding=Get-Field $saved.bindings $name
        if ($binding) {$lines += "$name -> $($binding.ModelId) | context=$($binding.ContextLength)"}
    }
    $statusBox.Text=$lines -join "`r`n"
}
function Render-Models {
    $selected=if ($list.SelectedItems.Count) {$list.SelectedItems[0].Tag.ModelKey} else {''}
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($m in @(Get-SortedModels $script:models $script:column $script:descending $filterBox.Text.Trim())) {
            $item=New-Object Windows.Forms.ListViewItem([string]$m.ModelKey)
            [void]$item.SubItems.Add([string]$m.DisplayName); [void]$item.SubItems.Add([string]$m.Publisher)
            $size=if ($null -ne $m.SizeBytes) {([double]$m.SizeBytes / 1GB).ToString('N2')} else {'Unknown'}
            [void]$item.SubItems.Add($size); [void]$item.SubItems.Add([string]$m.Params); [void]$item.SubItems.Add([string]$m.Architecture)
            $item.Tag=$m; $item.ToolTipText=$m.ModelKey; [void]$list.Items.Add($item)
            if ($m.ModelKey -eq $selected) {$item.Selected=$true}
        }
        for ($i=0;$i -lt $headers.Count;$i++) {$list.Columns[$i].Text=$headers[$i]}
        $list.Columns[$script:column].Text += $(if ($script:descending) {' desc'} else {' asc'})
        $emptyLabel.Visible=$list.Items.Count -eq 0
        if ($script:models.Count -and -not $list.Items.Count) {$emptyLabel.Text='No models match this filter.'}
        else {$emptyLabel.Text="No local models listed.`r`nStart a server, then click Refresh models."}
    } finally {$list.EndUpdate()}
}
function Get-GuiProvider {
    $kind=[string]$backendBox.SelectedItem; $url=$endpointBox.Text.Trim()
    if (-not $tokenBox.Text -and $script:activeProvider.Kind -eq $kind -and $script:activeProvider.BaseUrl -eq $url.TrimEnd('/')) {return $script:activeProvider}
    return New-Provider $kind $url $tokenBox.Text
}
function Start-GuiTask {
    param([string]$Operation,[string]$ModelId='', [switch]$Tools)
    if ($script:worker) {return}
    if ($script:unloadWorker) {Write-GuiLog 'Wait for model unloading to finish.';return}
    try {
        $chosen=Get-GuiProvider
        if ($Operation -in @('Bind','Test')) {
            if ($Operation -eq 'Bind' -and -not $list.SelectedItems.Count) {throw 'Select a model first.'}
            if ($Operation -eq 'Bind' -and ($chosen.Kind -ne $script:activeProvider.Kind -or $chosen.BaseUrl -ne $script:activeProvider.BaseUrl)) {throw 'Save the server and refresh its model list first.'}
            if ($Operation -eq 'Test') {
                $saved=Get-SwitcherConfig $paths.Root
                $binding=Get-Field $saved.bindings ([string]$aliasBox.SelectedItem)
                if (-not $binding) {throw 'Save a model binding first.'}
                $chosen=$saved.provider; $ModelId=$binding.ModelId
            }
        }
        $script:operation=$Operation
        $script:worker=[PowerShell]::Create()
        [void]$script:worker.AddScript({
            param($Core,$Kind,$ProviderJson,$Root,$Name,$Id,$Ctx,$CheckTools)
            $ErrorActionPreference='Stop'; . $Core
            $p=$ProviderJson | ConvertFrom-Json
            switch ($Kind) {
                'Refresh' { $result=@(Get-ProviderModels $p) }
                'Bind' { $result=Set-ModelBinding $Root $p $Name $Id $Ctx }
                'Test' { $result=Test-ModelEndpoint $p $Id -Tools:$CheckTools }
            }
            [pscustomobject]@{result=$result;provider=$p} | ConvertTo-Json -Depth 30 -Compress
        }.ToString())
        foreach ($arg in @((Join-Path $PSScriptRoot 'local_switcher_core.ps1'),$Operation,($chosen | ConvertTo-Json -Compress),$paths.Root,[string]$aliasBox.SelectedItem,$ModelId,[int]$contextBox.Value,[bool]$Tools)) {[void]$script:worker.AddArgument($arg)}
        foreach ($control in $script:busyControls) {$control.Enabled=$false}
        $form.UseWaitCursor=$true
        Write-GuiLog "$Operation in progress..."
        $script:pending=$script:worker.BeginInvoke()
    } catch {Write-GuiLog $_.Exception.Message; if ($script:worker) {$script:worker.Dispose();$script:worker=$null}}
}
$timer=New-Object Windows.Forms.Timer
$timer.Interval=150
$timer.Add_Tick({
    if ($script:unloadWorker -and $script:unloadPending.IsCompleted) {
        try {
            $result=$script:unloadWorker.EndInvoke($script:unloadPending)
            if ($script:unloadWorker.HadErrors) {throw [string]$script:unloadWorker.Streams.Error[0]}
            Write-GuiLog ($result -join ' ')
        } catch {Write-GuiLog ('Unload failed: ' + $_.Exception.Message)} finally {
            $script:unloadWorker.Dispose();$script:unloadWorker=$null;$script:unloadPending=$null;$unloadButton.Enabled=$true
        }
    }
    if (-not $script:worker -or -not $script:pending.IsCompleted) {return}
    try {
        $output=$script:worker.EndInvoke($script:pending)
        if ($script:worker.HadErrors) {throw [string]$script:worker.Streams.Error[0]}
        $result=($output -join '') | ConvertFrom-Json
        if ($script:operation -eq 'Refresh') {$script:models=@($result.result); $script:activeProvider=$result.provider; Render-Models; Write-GuiLog "Found $($script:models.Count) local models."}
        else {Write-GuiLog ([string]$result.result);Update-BindingStatus}
    } catch {Write-GuiLog ($_.Exception.Message + ' Start a local server or choose a different connector.')} finally {
        $script:worker.Dispose();$script:worker=$null;$script:pending=$null
        foreach ($control in $script:busyControls) {$control.Enabled=$true}
        $contextBox.Enabled=$backendBox.SelectedItem -in @('LMStudio','Ollama')
        $form.UseWaitCursor=$false
    }
})
$timer.Start()

$backendBox.Add_SelectedIndexChanged({
    $endpointBox.Text=(New-Provider ([string]$backendBox.SelectedItem)).BaseUrl
    $tokenBox.Clear(); $script:models=@(); Render-Models
    $contextBox.Value=0; $contextBox.Enabled=$backendBox.SelectedItem -in @('LMStudio','Ollama')
})
$contextBox.Enabled=$provider.Kind -in @('LMStudio','Ollama')
$refreshButton.Add_Click({Start-GuiTask 'Refresh'})
$filterBox.Add_TextChanged({Render-Models})
$list.Add_ColumnClick({param($sender,$event); $next=Get-NextSort $script:lastClick $script:descending $event.Column; $script:column=$next.Column;$script:lastClick=$next.Column;$script:descending=$next.Descending;Render-Models})
$bindButton.Add_Click({if ($list.SelectedItems.Count) {Start-GuiTask 'Bind' $list.SelectedItems[0].Tag.ModelKey} else {Write-GuiLog 'Select a model first.'}})
$testButton.Add_Click({Start-GuiTask 'Test'})
$toolsButton.Add_Click({Start-GuiTask 'Test' -Tools})
$unloadButton.Add_Click({
    if ($script:unloadWorker) {return}
    try {
        $selectedProvider=Get-GuiProvider
        if ($script:worker) {[void]$script:worker.BeginStop($null,$null)}
        $script:unloadWorker=[PowerShell]::Create()
        [void]$script:unloadWorker.AddScript({param($Core,$ProviderJson);$ErrorActionPreference='Stop';. $Core;Unload-AllModels ($ProviderJson | ConvertFrom-Json)}.ToString())
        [void]$script:unloadWorker.AddArgument((Join-Path $PSScriptRoot 'local_switcher_core.ps1'))
        [void]$script:unloadWorker.AddArgument(($selectedProvider | ConvertTo-Json -Compress))
        $unloadButton.Enabled=$false
        Write-GuiLog 'Unloading all models from the selected server. An unresponsive engine will be stopped.'
        $script:unloadPending=$script:unloadWorker.BeginInvoke()
    } catch {Write-GuiLog $_.Exception.Message;if ($script:unloadWorker) {$script:unloadWorker.Dispose();$script:unloadWorker=$null};$unloadButton.Enabled=$true}
})
$saveServerButton.Add_Click({
    try {
        $chosen=Get-GuiProvider; $saved=Get-SwitcherConfig $paths.Root
        if ($chosen.Kind -ne $saved.provider.Kind -or $chosen.BaseUrl -ne $saved.provider.BaseUrl) {Set-Field $saved 'bindings' ([pscustomobject]@{});$script:models=@();Render-Models}
        Set-Field $saved 'provider' $chosen;Write-JsonFile $paths.Config $saved;$script:activeProvider=$chosen;$tokenBox.Clear();Update-BindingStatus
        Write-GuiLog 'Server saved. Refresh models, then bind sonnet before opening local VS Code.'
    } catch {Write-GuiLog $_.Exception.Message}
})
$addProjectButton.Add_Click({
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description='Choose a project for local models. Use a separate checkout for parallel work.'
    try {if ($dialog.ShowDialog() -eq 'OK') {Assert-LocalProject $dialog.SelectedPath;Add-LocalProject $paths.Root $dialog.SelectedPath;if (-not $projectBox.Items.Contains($dialog.SelectedPath)) {[void]$projectBox.Items.Add($dialog.SelectedPath)};$projectBox.SelectedItem=$dialog.SelectedPath;Write-GuiLog 'Project registered.'}}
    catch {Write-GuiLog $_.Exception.Message} finally {$dialog.Dispose()}
})
function Open-IsolatedWindow {
    param([switch]$Login)
    try {
        $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'launch_claude_local_vscode.ps1'),'-StateRoot',$paths.Root)
        if ($Login) {$args += '-LoginAccountB'}
        else {
            if (-not $projectBox.SelectedItem) {throw 'Add or select a separate local project first.'}
            Assert-LocalProject ([string]$projectBox.SelectedItem)
            [void](Get-LocalEnvironment (Get-SwitcherConfig $paths.Root) $paths)
            $args += @('-WorkspacePath',[string]$projectBox.SelectedItem)
        }
        [void][IO.Directory]::CreateDirectory($paths.Root)
        $startupLog=Join-Path $paths.Root 'launcher-errors.log'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList (($args | ForEach-Object {ConvertTo-ProcessArgument $_}) -join ' ') -WindowStyle Hidden -RedirectStandardError $startupLog | Out-Null
        Write-GuiLog "Launcher started. If no window opens, check $startupLog"
    } catch {Write-GuiLog $_.Exception.Message}
}
$launchButton.Add_Click({Open-IsolatedWindow})
$loginButton.Add_Click({Open-IsolatedWindow -Login})
$ollamaButton.Add_Click({Start-Process 'https://ollama.com/download/windows' | Out-Null})
$lmButton.Add_Click({Start-Process 'https://lmstudio.ai/download' | Out-Null})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose();if ($script:worker) {[void]$script:worker.BeginStop($null,$null)};if ($script:unloadWorker) {[void]$script:unloadWorker.BeginStop($null,$null)}})
Update-BindingStatus
if ($PreviewModelsFile) {$script:models=@((Read-JsonFile $PreviewModelsFile).models)}
Render-Models
Write-GuiLog 'Choose a server and refresh models. No runtime installed? Use Get Ollama or Get LM Studio.'
if ($PreviewPath) {
    # Render the real form without launching apps or probing a server; used for visual QA.
    $form.Show();[Windows.Forms.Application]::DoEvents()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save([IO.Path]::GetFullPath($PreviewPath),[Drawing.Imaging.ImageFormat]::Png)}
    finally {$bitmap.Dispose();$form.Close();$form.Dispose()}
} else {[void]$form.ShowDialog();$form.Dispose()}
