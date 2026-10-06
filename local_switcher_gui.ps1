. (Join-Path $PSScriptRoot 'gui_workflow.ps1')
if ($PreviewScenario -ne 'Server' -and -not $PreviewPath -and -not $GuiTest) {throw 'Preview scenarios require a preview output file.'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:flow=New-WorkflowState
$script:flow.Backend=$provider.Kind
$script:catalog=@();$script:sortColumn=3;$script:sortDescending=$true;$script:lastSortClick=-1
$script:activeProvider=$provider;$script:runtimeTarget=$null;$script:job=$null;$script:unloadJob=$null;$script:changing=$false
$script:controls=@{}
$script:updatingUi=$false;$script:updateUiPending=$false
$form=New-Object Windows.Forms.Form
$form.Text='Claude Code — локальные модели и аккаунт B'
$form.ClientSize=New-Object Drawing.Size(1120,820)
$form.MinimumSize=New-Object Drawing.Size(1050,780)
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.StartPosition='CenterScreen'
$root=New-Object Windows.Forms.TableLayoutPanel
$root.Dock='Fill';$root.Padding=New-Object Windows.Forms.Padding(20);$root.ColumnCount=1;$root.RowCount=6
foreach ($height in @(50,44)) {[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
foreach ($height in @(66,42,0)) {[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
$form.Controls.Add($root)

function New-UiLabel {
    param($Parent,[string]$Text,[switch]$Heading)
    $label=New-Object Windows.Forms.Label
    $label.Text=$Text;$label.AutoSize=$true;$label.MaximumSize=New-Object Drawing.Size(1000,0)
    $label.Margin=New-Object Windows.Forms.Padding(0,5,12,10)
    if ($Heading) {$label.Font=New-Object Drawing.Font('Segoe UI',14,[Drawing.FontStyle]::Bold)}
    if ($Parent) {$Parent.Controls.Add($label)}
    return $label
}
function New-UiRow {
    param($Parent)
    $row=New-Object Windows.Forms.FlowLayoutPanel
    $row.AutoSize=$true;$row.WrapContents=$true;$row.Dock='Top';$row.Margin=New-Object Windows.Forms.Padding(0,0,0,8)
    if ($Parent) {$Parent.Controls.Add($row)}
    return $row
}
function New-UiButton {
    param($Parent,[string]$Text,[int]$Width=210)
    $button=New-Object Windows.Forms.Button
    $button.Text=$Text;$button.Size=New-Object Drawing.Size($Width,34);$button.Margin=New-Object Windows.Forms.Padding(0,0,12,4)
    $Parent.Controls.Add($button);return $button
}
function New-UiCheck {
    param($Parent,[string]$Text)
    $check=New-Object Windows.Forms.CheckBox
    $check.Text=$Text;$check.AutoSize=$true;$check.Margin=New-Object Windows.Forms.Padding(0,7,16,8)
    $Parent.Controls.Add($check);return $check
}
function New-UiText {
    param($Parent,[int]$Width=360)
    $box=New-Object Windows.Forms.TextBox
    $box.Width=$Width;$box.Margin=New-Object Windows.Forms.Padding(0,3,12,8)
    $Parent.Controls.Add($box);return $box
}
function New-UiPage {
    $panel=New-Object Windows.Forms.FlowLayoutPanel
    $panel.Dock='Fill';$panel.FlowDirection='TopDown';$panel.WrapContents=$false;$panel.AutoScroll=$true
    $panel.Padding=New-Object Windows.Forms.Padding(0,14,0,0)
    return $panel
}

$header=New-UiRow $null;$header.Dock='Fill'
[void](New-UiLabel $header 'Локальные модели в отдельном VS Code' -Heading)
$unloadButton=New-UiButton $header 'Выгрузить все модели' 230
$root.Controls.Add($header,0,0)
$nav=New-UiRow $null;$nav.Dock='Fill'
$stepButtons=@()
foreach ($caption in @('1. Сервер','2. Модель','3. Аккаунт B','4. Проект и запуск')) {$stepButtons += New-UiButton $nav $caption 230}
$root.Controls.Add($nav,0,1)
$pageHost=New-Object Windows.Forms.Panel;$pageHost.Dock='Fill';$root.Controls.Add($pageHost,0,2)
$pages=@();for ($i=0;$i -lt 4;$i++) {$pages += New-UiPage;$pageHost.Controls.Add($pages[$i])}
$status=New-Object Windows.Forms.Label;$status.Dock='Fill';$status.Padding=New-Object Windows.Forms.Padding(0,10,0,0)
$root.Controls.Add($status,0,3)
$footer=New-UiRow $null;$footer.Dock='Fill'
$backButton=New-UiButton $footer 'Назад' 120
$nextButton=New-UiButton $footer 'Далее' 270
$showLog=New-UiCheck $footer 'Показать журнал'
$root.Controls.Add($footer,0,4)
$log=New-Object Windows.Forms.TextBox;$log.Multiline=$true;$log.ReadOnly=$true;$log.ScrollBars='Vertical';$log.Dock='Fill'
$root.Controls.Add($log,0,5)

# Step 1: only actions for the selected runtime/installation path are displayed.
[void](New-UiLabel $pages[0] 'Подготовьте локальный сервер' -Heading)
$row=New-UiRow $pages[0];[void](New-UiLabel $row 'Движок')
$backendBox=New-Object Windows.Forms.ComboBox;$backendBox.DropDownStyle='DropDownList';$backendBox.Width=340
[void]$backendBox.Items.AddRange(@('LM Studio','Ollama','Другой сервер — Anthropic API','Другой сервер — OpenAI API'))
$kinds=@('LMStudio','Ollama','Anthropic','OpenAI');$backendBox.SelectedIndex=[array]::IndexOf($kinds,$provider.Kind);$row.Controls.Add($backendBox)
$runtimeChoice=New-UiCheck $pages[0] 'Движок уже установлен, локальный сервер запущен'
$installRow=New-UiRow $pages[0];$installButton=New-UiButton $installRow 'Установить выбранный движок' 300
$serverHelp=New-UiLabel $pages[0] ''
$advancedConnection=New-UiCheck $pages[0] 'Другой адрес сервера или авторизация'
$endpointRow=New-UiRow $pages[0];[void](New-UiLabel $endpointRow 'Адрес сервера');$endpointBox=New-UiText $endpointRow 470;$endpointBox.Text=$provider.BaseUrl
$authRow=New-UiRow $pages[0];$authRequired=New-UiCheck $authRow 'Сервер требует API-токен'
$tokenRow=New-UiRow $pages[0];[void](New-UiLabel $tokenRow 'Токен локального сервера');$tokenBox=New-UiText $tokenRow 370;$tokenBox.UseSystemPasswordChar=$true
$tokenHelp=New-UiLabel $pages[0] 'Токен создаётся в настройках сервера. Для LM Studio — при включённом Require Authentication. Вход в аккаунт Anthropic выполняется отдельно на шаге 3.'
$connectRow=New-UiRow $pages[0];$connectButton=New-UiButton $connectRow 'Проверить сервер и найти модели' 330

# Step 2: a real text + tool-call probe is required before the account/project steps.
[void](New-UiLabel $pages[1] 'Выберите и проверьте основную модель' -Heading)
$modelHelp=New-UiLabel $pages[1] 'Список получен от выбранного сервера. Крупные модели показаны первыми. Основная модель будет использоваться в Claude Code как sonnet.'
$modelRow=New-UiRow $pages[1];[void](New-UiLabel $modelRow 'Фильтр');$filterBox=New-UiText $modelRow 350;$refreshButton=New-UiButton $modelRow 'Обновить список' 180
$list=New-Object Windows.Forms.ListView;$list.View='Details';$list.FullRowSelect=$true;$list.MultiSelect=$false;$list.HideSelection=$false;$list.GridLines=$true;$list.ShowItemToolTips=$true
$list.Size=New-Object Drawing.Size(1030,250);$list.Margin=New-Object Windows.Forms.Padding(0,0,0,10)
$headers=@('Идентификатор','Название','Издатель','Размер, GiB','Параметры','Архитектура');$widths=@(260,230,120,130,120,130)
for ($i=0;$i -lt $headers.Count;$i++) {[void]$list.Columns.Add($headers[$i],$widths[$i])}
$pages[1].Controls.Add($list)
$emptyModelHelp=New-UiLabel $pages[1] ''
$advancedModel=New-UiCheck $pages[1] 'Дополнительные параметры модели'
$contextRow=New-UiRow $pages[1];[void](New-UiLabel $contextRow 'Контекст, токенов (0 = настройка сервера)')
$contextBox=New-Object Windows.Forms.NumericUpDown;$contextBox.Minimum=0;$contextBox.Maximum=1048576;$contextBox.Increment=1024;$contextBox.Value=32768;$contextBox.ThousandsSeparator=$true;$contextBox.Width=130;$contextRow.Controls.Add($contextBox)
$aliasRow=New-UiRow $pages[1];[void](New-UiLabel $aliasRow 'Роль в Claude Code')
$aliasBox=New-Object Windows.Forms.ComboBox;$aliasBox.DropDownStyle='DropDownList';$aliasBox.Width=160;[void]$aliasBox.Items.AddRange(@('sonnet','opus','haiku'));$aliasBox.SelectedIndex=0;$aliasRow.Controls.Add($aliasBox)
$verifyRow=New-UiRow $pages[1];$verifyButton=New-UiButton $verifyRow 'Проверить и использовать модель' 320
$diagnosticsRow=New-UiRow $pages[1];$testButton=New-UiButton $diagnosticsRow 'Повторить тест ответа' 230;$toolsButton=New-UiButton $diagnosticsRow 'Повторить тест инструментов' 270

# Step 3: account identity is read from the isolated CLI, not inferred from an API token.
[void](New-UiLabel $pages[2] 'Войдите в отдельный аккаунт Anthropic' -Heading)
[void](New-UiLabel $pages[2] 'Откроется отдельное окно VS Code для входа. Выберите второй аккаунт B в браузере, завершите вход в Claude Code и вернитесь сюда. Основной аккаунт и его настройки сохраняются отдельно.')
$accountRow=New-UiRow $pages[2];$loginButton=New-UiButton $accountRow 'Открыть вход в аккаунт B' 280;$checkAccountButton=New-UiButton $accountRow 'Проверить вход' 190
$accountLabel=New-UiLabel $pages[2] 'Вход в отдельном профиле пока не проверен.'
$identityCheck=New-UiCheck $pages[2] 'Подтверждаю: это мой отдельный аккаунт B'
[void](New-UiLabel $pages[2] 'API-токен локального сервера относится к шагу 1. Здесь проверяется авторизация claude.ai в отдельном каталоге настроек.')

# Step 4: registered project selection and final preflight are mandatory.
[void](New-UiLabel $pages[3] 'Выберите отдельный рабочий проект' -Heading)
[void](New-UiLabel $pages[3] 'Для параллельной работы используйте другую папку проекта или отдельный Git worktree. Два аккаунта не разделяют файлы внутри одной папки.')
$projectRow=New-UiRow $pages[3]
$projectBox=New-Object Windows.Forms.ComboBox;$projectBox.DropDownStyle='DropDownList';$projectBox.Width=650;$projectRow.Controls.Add($projectBox)
foreach ($project in @($config.projects)) {[void]$projectBox.Items.Add($project)}
if ($projectBox.Items.Count) {$projectBox.SelectedIndex=0}
$addProjectButton=New-UiButton $projectRow 'Выбрать папку' 180
$projectSummary=New-UiLabel $pages[3] ''
$launchRow=New-UiRow $pages[3];$launchButton=New-UiButton $launchRow 'Открыть локальный VS Code' 300

$script:controls=@{Form=$form;Backend=$backendBox;RuntimeChoice=$runtimeChoice;Install=$installButton;Endpoint=$endpointBox;AuthRequired=$authRequired;Token=$tokenBox;TokenRow=$tokenRow;Connect=$connectButton;List=$list;Filter=$filterBox;Verify=$verifyButton;ContextRow=$contextRow;Context=$contextBox;Aliases=$aliasBox;AliasRow=$aliasRow;Diagnostics=$diagnosticsRow;Login=$loginButton;CheckAccount=$checkAccountButton;Identity=$identityCheck;Projects=$projectBox;Launch=$launchButton;Unload=$unloadButton;Next=$nextButton;Back=$backButton;Navigation=$stepButtons;AdvancedConnection=$advancedConnection;AdvancedModel=$advancedModel}

function Write-UiLog {param([string]$Message);$log.AppendText('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message + "`r`n")}
function Get-DraftProvider {
    $token=if ($authRequired.Checked) {$tokenBox.Text} else {''}
    $candidate=New-Provider $kinds[$backendBox.SelectedIndex] $endpointBox.Text.Trim() $token
    if ($authRequired.Checked -and -not $token -and $candidate.Kind -eq $script:activeProvider.Kind -and $candidate.BaseUrl -eq $script:activeProvider.BaseUrl) {
        Set-Field $candidate 'TokenProtected' (Get-Field $script:activeProvider 'TokenProtected' '')
    }
    Set-Field $candidate 'AuthRequired' ([bool]$authRequired.Checked)
    return $candidate
}
function Update-WorkflowUi {
    # Visibility/enabled changes can synchronously raise selection events. Apply
    # their updated state after this pass instead of overwriting it with old gates.
    if ($script:updatingUi) {$script:updateUiPending=$true;return}
    $script:updatingUi=$true
    try {
        do {
            $script:updateUiPending=$false
            Update-WorkflowControls
        } while ($script:updateUiPending)
    } finally {$script:updatingUi=$false}
}
function Update-WorkflowControls {
    $script:flow.Backend=$kinds[$backendBox.SelectedIndex]
    $script:flow.RuntimeReady=$runtimeChoice.Checked
    $script:flow.AdvancedConnection=$advancedConnection.Checked;$script:flow.AdvancedModel=$advancedModel.Checked;$script:flow.AuthRequired=$authRequired.Checked
    $script:flow.SelectedModel=$list.SelectedItems.Count -gt 0
    $script:flow.ConnectionValid=$false;$script:flow.TokenReady=$false
    try {
        $draft=Get-DraftProvider;$script:flow.ConnectionValid=$true
        $script:flow.TokenReady=-not $authRequired.Checked -or [bool](Get-Field $draft 'TokenProtected' '')
    } catch {}
    $script:flow.CanTargetServer=$null -ne $script:runtimeTarget -or ($script:flow.ConnectionValid -and ($script:flow.RuntimeReady -or $script:flow.Backend -notin @('LMStudio','Ollama')))
    $script:flow.ProjectValid=$false
    if ($projectBox.SelectedItem) {try {if (Test-Path -LiteralPath ([string]$projectBox.SelectedItem) -PathType Container) {Assert-LocalProject ([string]$projectBox.SelectedItem);$script:flow.ProjectValid=$true}} catch {$script:flow.Error=$_.Exception.Message}}
    $policy=Get-WorkflowPolicy $script:flow
    $idle=-not $script:flow.Busy -and -not $script:flow.Unloading
    for ($i=0;$i -lt 4;$i++) {
        $pages[$i].Visible=($script:flow.Step -eq $i+1)
        $stepButtons[$i].Enabled=@($policy.CanGoServer,$policy.CanGoModel,$policy.CanGoAccount,$policy.CanGoProject)[$i]
        $stepButtons[$i].UseVisualStyleBackColor=$script:flow.Step -ne $i+1
        $stepButtons[$i].BackColor=if ($script:flow.Step -eq $i+1) {[Drawing.SystemColors]::Highlight} else {[Drawing.SystemColors]::Control}
        $stepButtons[$i].ForeColor=if ($script:flow.Step -eq $i+1) {[Drawing.SystemColors]::HighlightText} else {[Drawing.SystemColors]::ControlText}
    }
    $native=$script:flow.Backend -in @('LMStudio','Ollama')
    $runtimeChoice.Visible=$native;$runtimeChoice.Enabled=$idle;$advancedConnection.Visible=$native
    $installRow.Visible=$policy.ShowInstall;$installButton.Enabled=$idle
    $installButton.Text=if ($script:flow.Backend -eq 'Ollama') {'Установить Ollama'} else {'Установить LM Studio'}
    $serverHelp.Text=switch ($script:flow.Backend) {
        'LMStudio' {'В LM Studio скачайте или импортируйте модель и включите Local Server. По умолчанию используется порт 1234. Затем отметьте готовность движка и проверьте подключение.'}
        'Ollama' {'Установите Ollama, скачайте модель через ollama pull и запустите Ollama. По умолчанию используется порт 11434. Токен обычно не нужен.'}
        'Anthropic' {'Запустите приложение с Anthropic-совместимым API. Укажите его локальный адрес. Сервер должен предоставлять каталог моделей и Messages API.'}
        'OpenAI' {'Запустите приложение с OpenAI-совместимым API и укажите его адрес. При запуске VS Code будет использован локальный адаптер; для него нужен Python 3.9+.'}
    }
    $endpointRow.Visible=$policy.ShowEndpoint;$authRow.Visible=$policy.ShowAuthOption;$tokenRow.Visible=$policy.ShowToken;$tokenHelp.Visible=$policy.ShowToken
    $tokenHelp.Text='Токен создаётся в настройках локального сервера. В LM Studio он нужен при включённом Require Authentication. Вход Anthropic выполняется отдельно на шаге 3.'
    if ($script:flow.TokenReady -and -not $tokenBox.Text -and $authRequired.Checked) {$tokenHelp.Text += "`r`nДля этого адреса используется уже сохранённый токен; поле можно оставить пустым."}
    $backendBox.Enabled=$idle;$endpointBox.Enabled=$idle;$authRequired.Enabled=$idle;$tokenBox.Enabled=$idle;$advancedConnection.Enabled=$idle
    $connectButton.Enabled=$policy.CanCheckServer
    $list.Enabled=$idle -and $script:flow.ServerValid;$refreshButton.Enabled=$idle -and $script:flow.ServerValid
    $filterBox.Enabled=$idle -and $script:flow.ServerValid -and $script:flow.ModelCount -gt 0
    $advancedModel.Enabled=$idle -and $script:flow.ServerValid
    $contextRow.Visible=$policy.ShowContext;$aliasRow.Visible=$policy.ShowAliases;$diagnosticsRow.Visible=$policy.ShowModelDiagnostics
    $contextBox.Enabled=$idle;$aliasBox.Enabled=$idle;$verifyButton.Enabled=$policy.CanVerifyModel;$testButton.Enabled=$idle;$toolsButton.Enabled=$idle
    $loginButton.Enabled=$policy.CanCheckAccount;$checkAccountButton.Enabled=$policy.CanCheckAccount
    $identityCheck.Visible=$script:flow.AccountValid;$identityCheck.Enabled=$policy.CanConfirmIdentity
    $projectBox.Enabled=$policy.CanChooseProject;$addProjectButton.Enabled=$policy.CanChooseProject;$launchButton.Enabled=$policy.CanLaunch
    $unloadButton.Enabled=$policy.CanUnload
    $backButton.Visible=$script:flow.Step -gt 1;$backButton.Enabled=$idle
    $nextButton.Visible=$script:flow.Step -lt 4
    $nextButton.Enabled=switch ($script:flow.Step) {1 {$policy.CanGoModel} 2 {$policy.CanGoAccount} 3 {$policy.CanGoProject} default {$false}}
    $nextButton.Text=switch ($script:flow.Step) {1 {'Далее: модель'} 2 {'Далее: аккаунт B'} 3 {'Далее: проект'} default {'Далее'}}
    $emptyModelHelp.Visible=$script:flow.ModelCount -eq 0
    $emptyModelHelp.Text=if ($script:flow.ModelCount -eq 0) {'Каталог пуст. Скачайте или импортируйте модель в выбранном движке, затем обновите список.'} else {''}
    $modelHelp.Text=if ($script:flow.Backend -in @('LMStudio','Ollama')) {'Выберите модель. Проверяются текстовый ответ и вызов инструмента. Для Claude Code по умолчанию запрашивается контекст 32 768; размер можно изменить в дополнительных параметрах.'} else {'Выберите модель. Проверяются текстовый ответ и вызов инструмента. Контекст задаётся в самом сервере; неподдерживаемые настройки здесь скрыты.'}
    $projectSummary.Text="Сервер: $($script:activeProvider.Kind) — $($script:activeProvider.BaseUrl)`r`nАккаунт B: $($script:flow.AccountEmail)`r`nПроект: $($projectBox.SelectedItem)`r`nЗапуск использует отдельные настройки, историю и расширение Claude Code."
    $status.ForeColor=if ($script:flow.Error) {[Drawing.Color]::DarkRed} else {[Drawing.SystemColors]::ControlText}
    $status.Text=if ($script:flow.Error) {$script:flow.Error} elseif ($script:flow.Unloading) {'Выгружаются модели. Если сервер не отвечает, его процессы будут остановлены.'} elseif ($script:flow.Busy) {'Выполняется проверка. Аварийная выгрузка остаётся доступной.'} else {switch ($script:flow.Step) {1 {'Обязательный шаг: подготовьте сервер и подтвердите подключение.'} 2 {if ($script:flow.ModelValid) {'Основная модель проверена. Можно перейти к аккаунту B.'} else {'Обязательный шаг: выберите модель и дождитесь успешной проверки ответа и инструментов.'}} 3 {if ($script:flow.AccountValid) {'Подтвердите, что обнаруженная учётная запись — ваш отдельный аккаунт B.'} else {'Обязательный шаг: войдите в аккаунт B и нажмите «Проверить вход».'}} 4 {if ($script:flow.ProjectValid) {'Все обязательные шаги выполнены. Можно открыть локальный VS Code.'} else {'Обязательный шаг: выберите существующую отдельную папку проекта.'}}}}
    $root.RowStyles[5].Height=if ($showLog.Checked) {110} else {0};$log.Visible=$showLog.Checked
}

function Render-WorkflowModels {
    $key=if ($list.SelectedItems.Count) {$list.SelectedItems[0].Tag.ModelKey} else {''}
    $script:changing=$true;$list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($m in @(Get-SortedModels $script:catalog $script:sortColumn $script:sortDescending $filterBox.Text.Trim())) {
            $item=New-Object Windows.Forms.ListViewItem([string]$m.ModelKey)
            foreach ($value in @($m.DisplayName,$m.Publisher,$(if ($null -ne $m.SizeBytes) {([double]$m.SizeBytes / 1GB).ToString('N2')} else {'Неизвестно'}),$m.Params,$m.Architecture)) {[void]$item.SubItems.Add([string]$value)}
            $item.Tag=$m;$item.ToolTipText=$m.ModelKey;[void]$list.Items.Add($item)
            if ($m.ModelKey -eq $key) {$item.Selected=$true}
        }
        for ($i=0;$i -lt $headers.Count;$i++) {$list.Columns[$i].Text=$headers[$i]}
        $list.Columns[$script:sortColumn].Text += $(if ($script:sortDescending) {' убыв.'} else {' возр.'})
    } finally {$list.EndUpdate();$script:changing=$false}
    Update-WorkflowUi
}

function Start-WorkflowJob {
    param([string]$Operation,[switch]$Tools)
    $policy=Get-WorkflowPolicy $script:flow
    if ($script:job -or $script:unloadJob) {return}
    $allowed=switch ($Operation) { 'Connect' {$policy.CanCheckServer} 'Verify' {$policy.CanVerifyModel} 'Account' {$policy.CanCheckAccount} 'Login' {$policy.CanCheckAccount} 'Launch' {$policy.CanLaunch} 'Test' {$script:flow.ModelValid} default {$false} }
    if (-not $allowed) {return}
    $shell=$null
    try {
        $draft=Get-DraftProvider
        $alias=if ($script:flow.AdvancedModel -and $script:flow.ModelValid) {[string]$aliasBox.SelectedItem} else {'sonnet'}
        $selected=if ($list.SelectedItems.Count) {$list.SelectedItems[0].Tag} else {$null}
        $ctx=if ($draft.Kind -in @('LMStudio','Ollama')) {[int]$contextBox.Value} else {0}
        if ($selected -and $selected.MaxContext -gt 0) {$ctx=[math]::Min($ctx,[int]$selected.MaxContext)}
        $request=@{Operation=$Operation;Provider=$draft;Root=$paths.Root;Generation=$script:flow.Generation;Alias=$alias;Context=$ctx;ModelKey=$(if ($selected) {$selected.ModelKey} else {''});Project=[string]$projectBox.SelectedItem;Tools=[bool]$Tools;Repo=$PSScriptRoot;Email=$script:flow.AccountEmail}
        if ($Operation -in @('Connect','Verify','Test','Launch')) {$script:runtimeTarget=$draft}
        $shell=[PowerShell]::Create()
        [void]$shell.AddScript({
            param($Core,$Workflow,$Json)
            $ErrorActionPreference='Stop';. $Core;. $Workflow;$j=$Json | ConvertFrom-Json
            $data=[ordered]@{generation=$j.Generation;operation=$j.Operation;provider=$j.Provider;alias=$j.Alias}
            switch ($j.Operation) {
                'Connect' {
                    $data.models=@(Get-ProviderModels $j.Provider)
                    $saved=Get-SwitcherConfig $j.Root
                    if ($saved.provider.Kind -ne $j.Provider.Kind -or $saved.provider.BaseUrl -ne $j.Provider.BaseUrl) {Set-Field $saved 'bindings' ([pscustomobject]@{})}
                    Set-Field $saved 'provider' $j.Provider;Write-JsonFile (Get-StatePaths $j.Root).Config $saved
                }
                'Verify' {
                    [void](Set-ModelBinding $j.Root $j.Provider $j.Alias $j.ModelKey $j.Context -VerifyTools)
                    $saved=Get-SwitcherConfig $j.Root;$binding=Get-Field $saved.bindings $j.Alias
                    $data.binding=$binding
                }
                'Test' {
                    $saved=Get-SwitcherConfig $j.Root;$binding=Get-Field $saved.bindings $j.Alias
                    if (-not $binding) {throw 'No binding for the selected family.'}
                    $data.message=Test-ModelEndpoint $saved.provider $binding.ModelId -Tools:$j.Tools
                }
                'Account' {$data.account=Get-IsolatedAccountStatus $j.Root}
                'Launch' {
                    try {$auth=Get-IsolatedAccountStatus $j.Root} catch {throw ('ACCOUNT_GATE: ' + $_.Exception.Message)}
                    if (-not $auth.LoggedIn -or $auth.Email -ne $j.Email) {throw 'ACCOUNT_GATE: Account B changed or signed out. Check the account again.'}
                    $saved=Get-SwitcherConfig $j.Root
                    if ($saved.provider.Kind -ne $j.Provider.Kind -or $saved.provider.BaseUrl -ne $j.Provider.BaseUrl) {throw 'SERVER_GATE: Saved server changed. Check the connection again.'}
                    try {Assert-LocalProject $j.Project} catch {throw ('PROJECT_GATE: ' + $_.Exception.Message)}
                    try {[void](Test-ModelEndpoint $saved.provider $saved.bindings.sonnet.ModelId)} catch {throw ('MODEL_GATE: ' + $_.Exception.Message)}
                }
            }
            if ($j.Operation -in @('Login','Launch')) {
                [void](Resolve-CodeExecutable)
                $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $j.Repo 'launch_claude_local_vscode.ps1'),'-StateRoot',$j.Root)
                if ($j.Operation -eq 'Login') {$args += '-LoginAccountB'} else {$args += @('-WorkspacePath',$j.Project)}
                $p=Get-StatePaths $j.Root;[void][IO.Directory]::CreateDirectory($p.Root)
                Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList (($args | ForEach-Object {ConvertTo-ProcessArgument $_}) -join ' ') -WindowStyle Hidden -RedirectStandardError (Join-Path $p.Root 'launcher-errors.log') | Out-Null
            }
            [pscustomobject]$data | ConvertTo-Json -Depth 40 -Compress
        }.ToString())
        [void]$shell.AddArgument((Join-Path $PSScriptRoot 'local_switcher_core.ps1'));[void]$shell.AddArgument((Join-Path $PSScriptRoot 'gui_workflow.ps1'));[void]$shell.AddArgument(($request | ConvertTo-Json -Depth 25 -Compress))
        $script:flow.Busy=$Operation;$script:flow.Error=''
        $pending=$shell.BeginInvoke()
        $script:job=[pscustomobject]@{Shell=$shell;Pending=$pending;Operation=$Operation;Generation=$script:flow.Generation;Alias=$alias}
        Write-UiLog "${Operation}: проверка началась."
    } catch {$script:flow.Error=$_.Exception.Message;$script:flow.Busy='';if ($shell) {$shell.Dispose()}}
    Update-WorkflowUi
}

function Poll-WorkflowJobs {
    if ($script:unloadJob -and $script:unloadJob.Pending.IsCompleted) {
        try {
            $output=$script:unloadJob.Shell.EndInvoke($script:unloadJob.Pending)
            if ($script:unloadJob.Shell.HadErrors) {throw [string]$script:unloadJob.Shell.Streams.Error[0]}
            Write-UiLog ($output -join ' ');$script:flow.Error='Модели выгружены. Перед продолжением снова проверьте сервер.'
        } catch {$script:flow.Error='Выгрузка не завершена: ' + $_.Exception.Message;Write-UiLog $script:flow.Error}
        finally {$script:unloadJob.Shell.Dispose();$script:unloadJob=$null;$script:flow.Unloading=$false}
    }
    if ($script:job -and $script:job.Pending.IsCompleted) {
        $job=$script:job
        try {
            $output=$job.Shell.EndInvoke($job.Pending)
            if ($job.Generation -eq $script:flow.Generation) {
                if ($job.Shell.HadErrors) {throw [string]$job.Shell.Streams.Error[0]}
                $data=($output -join '') | ConvertFrom-Json
                switch ($job.Operation) {
                    'Connect' {$script:activeProvider=$data.provider;$script:catalog=@($data.models);$script:flow.ModelCount=$script:catalog.Count;$script:flow.ServerValid=$true;$script:flow.ModelValid=$false;$script:flow.Step=2;Render-WorkflowModels;Write-UiLog "Найдено моделей: $($script:flow.ModelCount)."}
                    'Verify' {if ($job.Alias -eq 'sonnet') {$script:flow.ModelValid=$true};Write-UiLog "Модель $($job.Alias) прошла проверку ответа и инструмента."}
                    'Account' {
                        $script:flow.AccountValid=[bool]$data.account.LoggedIn
                        if (-not $data.account.LoggedIn -or $data.account.Email -ne $script:flow.AccountEmail) {$identityCheck.Checked=$false;$script:flow.IdentityConfirmed=$false}
                        $script:flow.AccountEmail=[string]$data.account.Email
                        $accountLabel.Text=if ($script:flow.AccountValid) {"Вход claude.ai подтверждён: $($script:flow.AccountEmail)`r`nПроверьте, что это именно второй аккаунт B."} else {'В отдельном профиле нет входа claude.ai. Нажмите «Открыть вход в аккаунт B», завершите авторизацию и повторите проверку.'}
                    }
                    'Login' {Write-UiLog 'Открывается отдельный VS Code. После входа вернитесь и нажмите «Проверить вход».'}
                    'Launch' {Write-UiLog 'Запускается локальный VS Code. Ошибки запуска записываются в launcher-errors.log отдельного профиля.'}
                    'Test' {Write-UiLog 'Повторная проверка модели прошла.'}
                }
            }
        } catch {
            if ($job.Generation -eq $script:flow.Generation) {
                $script:flow.Error=$_.Exception.Message;Write-UiLog $script:flow.Error
                if ($job.Operation -eq 'Connect') {
                    $script:flow.ServerValid=$false
                    if ($script:flow.Error -match 'HTTP 401|HTTP 403') {$advancedConnection.Checked=$true;$authRequired.Checked=$true;$script:flow.Error='Сервер требует авторизацию. Введите его API-токен и повторите проверку.'}
                }
                if ($job.Operation -in @('Verify','Test') -and $job.Alias -eq 'sonnet') {$script:flow.ModelValid=$false}
                if ($job.Operation -eq 'Account' -or $script:flow.Error -match 'ACCOUNT_GATE:') {$script:flow.AccountValid=$false;$identityCheck.Checked=$false;$script:flow.Step=3}
                if ($script:flow.Error -match 'SERVER_GATE:') {$message=$script:flow.Error;Reset-WorkflowServer $script:flow;$script:flow.Error=$message}
                if ($script:flow.Error -match 'MODEL_GATE:') {$script:flow.ModelValid=$false;$script:flow.Step=2}
                if ($script:flow.Error -match 'PROJECT_GATE:') {$script:flow.ProjectValid=$false;$script:flow.Step=4}
            }
        } finally {$job.Shell.Dispose();$script:job=$null;$script:flow.Busy=''}
    }
    Update-WorkflowUi
}

function Invalidate-DraftServer {
    if ($script:changing) {return}
    Reset-WorkflowServer $script:flow;$script:catalog=@();Render-WorkflowModels
}
$backendBox.Add_SelectedIndexChanged({
    if ($script:changing) {return}
    $script:changing=$true
    $kind=$kinds[$backendBox.SelectedIndex];$saved=Get-SwitcherConfig $paths.Root
    $endpointBox.Text=if ($kind -eq $saved.provider.Kind) {$saved.provider.BaseUrl} else {(New-Provider $kind).BaseUrl}
    $tokenBox.Clear();$authRequired.Checked=$kind -eq $saved.provider.Kind -and [bool](Get-Field $saved.provider 'TokenProtected' '')
    $advancedConnection.Checked=$endpointBox.Text -ne (New-Provider $kind).BaseUrl;$advancedModel.Checked=$false;$runtimeChoice.Checked=$false;$aliasBox.SelectedIndex=0;$contextBox.Value=32768
    $script:changing=$false;Invalidate-DraftServer
})
$runtimeChoice.Add_CheckedChanged({Invalidate-DraftServer})
$endpointBox.Add_TextChanged({Invalidate-DraftServer})
$tokenBox.Add_TextChanged({Invalidate-DraftServer})
$authRequired.Add_CheckedChanged({Invalidate-DraftServer})
$advancedConnection.Add_CheckedChanged({Update-WorkflowUi})
$advancedModel.Add_CheckedChanged({
    if (-not $script:changing -and -not $advancedModel.Checked -and $aliasBox.SelectedItem -ne 'sonnet') {
        $aliasBox.SelectedIndex=0;Reset-WorkflowModel $script:flow
    }
    Update-WorkflowUi
})
$connectButton.Add_Click({Start-WorkflowJob 'Connect'})
$refreshButton.Add_Click({$script:flow.ModelValid=$false;Start-WorkflowJob 'Connect'})
$filterBox.Add_TextChanged({Render-WorkflowModels})
$list.Add_SelectedIndexChanged({if (-not $script:changing) {if ($aliasBox.SelectedItem -eq 'sonnet') {Reset-WorkflowModel $script:flow};Update-WorkflowUi}})
$list.Add_ColumnClick({param($sender,$event);$next=Get-NextSort $script:lastSortClick $script:sortDescending $event.Column;$script:sortColumn=$next.Column;$script:lastSortClick=$next.Column;$script:sortDescending=$next.Descending;Render-WorkflowModels})
$contextBox.Add_ValueChanged({if (-not $script:changing -and $aliasBox.SelectedItem -eq 'sonnet') {Reset-WorkflowModel $script:flow;Update-WorkflowUi}})
$aliasBox.Add_SelectedIndexChanged({Update-WorkflowUi})
$verifyButton.Add_Click({Start-WorkflowJob 'Verify'})
$testButton.Add_Click({Start-WorkflowJob 'Test'})
$toolsButton.Add_Click({Start-WorkflowJob 'Test' -Tools})
$loginButton.Add_Click({Start-WorkflowJob 'Login'})
$checkAccountButton.Add_Click({Start-WorkflowJob 'Account'})
$identityCheck.Add_CheckedChanged({$script:flow.IdentityConfirmed=$identityCheck.Checked;Update-WorkflowUi})
$projectBox.Add_SelectedIndexChanged({$script:flow.Error='';Update-WorkflowUi})
$addProjectButton.Add_Click({
    if (-not (Get-WorkflowPolicy $script:flow).CanChooseProject) {return}
    $dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Выберите отдельную папку проекта для локальных моделей.'
    try {if ($dialog.ShowDialog() -eq 'OK') {Assert-LocalProject $dialog.SelectedPath;Add-LocalProject $paths.Root $dialog.SelectedPath;if (-not $projectBox.Items.Contains($dialog.SelectedPath)) {[void]$projectBox.Items.Add($dialog.SelectedPath)};$projectBox.SelectedItem=$dialog.SelectedPath}}
    catch {$script:flow.Error=$_.Exception.Message} finally {$dialog.Dispose();Update-WorkflowUi}
})
$launchButton.Add_Click({Start-WorkflowJob 'Launch'})
$installButton.Add_Click({if ($script:flow.Backend -eq 'Ollama') {Start-Process 'https://ollama.com/download/windows' | Out-Null} elseif ($script:flow.Backend -eq 'LMStudio') {Start-Process 'https://lmstudio.ai/download' | Out-Null}})
$backButton.Add_Click({if (-not $script:flow.Busy -and -not $script:flow.Unloading) {$script:flow.Step=[math]::Max(1,$script:flow.Step-1);$script:flow.Error='';Update-WorkflowUi}})
$nextButton.Add_Click({$policy=Get-WorkflowPolicy $script:flow;$allowed=switch ($script:flow.Step) {1 {$policy.CanGoModel} 2 {$policy.CanGoAccount} 3 {$policy.CanGoProject} default {$false}};if ($allowed) {$script:flow.Step++;$script:flow.Error='';Update-WorkflowUi}})
for ($i=0;$i -lt $stepButtons.Count;$i++) {$stepButtons[$i].Tag=$i+1;$stepButtons[$i].Add_Click({param($sender,$event);if ($sender.Enabled) {$script:flow.Step=[int]$sender.Tag;$script:flow.Error='';Update-WorkflowUi}})}
$showLog.Add_CheckedChanged({Update-WorkflowUi})
$unloadButton.Add_Click({
    if (-not (Get-WorkflowPolicy $script:flow).CanUnload) {return}
    $shell=$null
    try {
        $target=if ($script:runtimeTarget) {$script:runtimeTarget} else {Get-DraftProvider}
        Reset-WorkflowServer $script:flow
        if ($script:job) {[void]$script:job.Shell.BeginStop($null,$null)}
        $shell=[PowerShell]::Create();[void]$shell.AddScript({param($Core,$Json);$ErrorActionPreference='Stop';. $Core;Unload-AllModels ($Json | ConvertFrom-Json)}.ToString())
        [void]$shell.AddArgument((Join-Path $PSScriptRoot 'local_switcher_core.ps1'));[void]$shell.AddArgument(($target | ConvertTo-Json -Compress))
        $script:flow.Unloading=$true;$pending=$shell.BeginInvoke();$script:unloadJob=[pscustomobject]@{Shell=$shell;Pending=$pending}
        Write-UiLog 'Выгрузка выполняется независимо от основного запроса.'
    } catch {$script:flow.Unloading=$false;$script:flow.Error=$_.Exception.Message;if ($shell) {$shell.Dispose()}}
    Update-WorkflowUi
})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=150;$timer.Add_Tick({Poll-WorkflowJobs})
$form.Add_Resize({$list.Width=[math]::Max(700,$pageHost.ClientSize.Width-30)})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose();if ($script:job) {[void]$script:job.Shell.BeginStop($null,$null)};if ($script:unloadJob) {[void]$script:unloadJob.Shell.BeginStop($null,$null)}})
$script:changing=$true
$authRequired.Checked=[bool](Get-Field $provider 'TokenProtected' '')
$advancedConnection.Checked=$provider.BaseUrl -ne (New-Provider $provider.Kind).BaseUrl
$runtimeChoice.Checked=$false
$script:changing=$false
if ($PreviewModelsFile) {$script:catalog=@((Read-JsonFile $PreviewModelsFile).models)}
if ($PreviewPath -or $GuiTest) {
    $script:changing=$true
    switch ($PreviewScenario) {
        'Install' {$runtimeChoice.Checked=$false}
        'Model' {$runtimeChoice.Checked=$true;$script:flow.ServerValid=$true;$script:flow.Step=2}
        'Account' {$runtimeChoice.Checked=$true;$script:flow.ServerValid=$true;$script:flow.ModelValid=$true;$script:flow.Step=3}
        'Project' {$runtimeChoice.Checked=$true;$script:flow.ServerValid=$true;$script:flow.ModelValid=$true;$script:flow.AccountValid=$true;$script:flow.IdentityConfirmed=$true;$script:flow.AccountEmail='пример: account-b@example.test';$identityCheck.Checked=$true;$script:flow.Step=4}
        'Busy' {$runtimeChoice.Checked=$true;$script:flow.Busy='Connect'}
        'NoModels' {$runtimeChoice.Checked=$true;$script:flow.ServerValid=$true;$script:flow.Step=2;$script:catalog=@()}
        'AuthRequired' {$runtimeChoice.Checked=$true;$authRequired.Checked=$true;$advancedConnection.Checked=$true}
        'CustomServer' {$backendBox.SelectedIndex=3;$endpointBox.Text='http://localhost:8080'}
    }
    $script:changing=$false
}
$script:flow.ModelCount=$script:catalog.Count
Render-WorkflowModels;Update-WorkflowUi
Write-UiLog 'Следуйте четырём шагам. Переход открывается после проверки обязательного действия.'
if ($GuiTest) {return}
if ($PreviewPath) {
    $form.Show();[Windows.Forms.Application]::DoEvents()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save([IO.Path]::GetFullPath($PreviewPath),[Drawing.Imaging.ImageFormat]::Png)}
    finally {$bitmap.Dispose();$form.Close();$form.Dispose()}
} else {$timer.Start();[void]$form.ShowDialog();$form.Dispose()}
