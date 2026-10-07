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
$script:mainValidation=$null;$script:bindingsCache=$config.bindings;$script:draftProvider=$null;$script:draftError='';$script:cancelledJobs=@()
$script:providerDrafts=@{};$script:selectedBackendKind=$provider.Kind
$form=New-Object Windows.Forms.Form
$form.Text=('Claude Code — локальные модели | ' + $paths.Name)
$workArea=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.ClientSize=New-Object Drawing.Size([math]::Min(1120,$workArea.Width-80),[math]::Min(760,$workArea.Height-80))
$form.MinimumSize=New-Object Drawing.Size([math]::Min(900,$workArea.Width-40),[math]::Min(650,$workArea.Height-40))
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.StartPosition='CenterScreen'
$root=New-Object Windows.Forms.TableLayoutPanel
$root.Dock='Fill';$root.Padding=New-Object Windows.Forms.Padding(20);$root.ColumnCount=1;$root.RowCount=6
[void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
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
$targetTip=New-Object Windows.Forms.ToolTip
$root.Controls.Add($header,0,0)
$nav=New-UiRow $null;$nav.Dock='Fill'
$stepButtons=@()
foreach ($caption in @('1. Сервер','2. Модель','3. Аккаунт','4. Проект и запуск')) {$stepButtons += New-UiButton $nav $caption 230}
$root.Controls.Add($nav,0,1)
$pageHost=New-Object Windows.Forms.Panel;$pageHost.Dock='Fill';$root.Controls.Add($pageHost,0,2)
$pages=@();for ($i=0;$i -lt 4;$i++) {$pages += New-UiPage;$pageHost.Controls.Add($pages[$i])}
$status=New-Object Windows.Forms.Label;$status.Dock='Fill';$status.Padding=New-Object Windows.Forms.Padding(0,10,0,0)
$root.Controls.Add($status,0,3)
$footer=New-UiRow $null;$footer.Dock='Fill'
$backButton=New-UiButton $footer 'Назад' 120
$nextButton=New-UiButton $footer 'Далее' 270
$showLog=New-UiCheck $footer 'Показать журнал'
$cancelButton=New-UiButton $footer 'Отменить проверку' 190
$root.Controls.Add($footer,0,4)
$log=New-Object Windows.Forms.TextBox;$log.Multiline=$true;$log.ReadOnly=$true;$log.ScrollBars='Vertical';$log.Dock='Fill'
$root.Controls.Add($log,0,5)

# Step 1: only actions for the selected runtime/installation path are displayed.
[void](New-UiLabel $pages[0] 'Подготовьте локальный сервер' -Heading)
$row=New-UiRow $pages[0];[void](New-UiLabel $row 'Движок')
$backendBox=New-Object Windows.Forms.ComboBox;$backendBox.DropDownStyle='DropDownList';$backendBox.Width=340
[void]$backendBox.Items.AddRange(@('LM Studio','Ollama','Другой сервер — Anthropic API','Другой сервер — OpenAI API'))
$kinds=@('LMStudio','Ollama','Anthropic','OpenAI');$backendBox.SelectedIndex=[array]::IndexOf($kinds,$provider.Kind);$row.Controls.Add($backendBox)
$runtimeChoice=New-UiCheck $pages[0] 'Показать установку и запуск движка'
$installRow=New-UiRow $pages[0];$installButton=New-UiButton $installRow 'Установить выбранный движок' 300
$serverHelp=New-UiLabel $pages[0] ''
$endpointSummary=New-UiLabel $pages[0] ''
$advancedConnection=New-UiCheck $pages[0] 'Другой адрес сервера или авторизация'
$endpointRow=New-UiRow $pages[0];[void](New-UiLabel $endpointRow 'Адрес сервера');$endpointBox=New-UiText $endpointRow 470;$endpointBox.Text=$provider.BaseUrl
$authRow=New-UiRow $pages[0];$authRequired=New-UiCheck $authRow 'Сервер требует API-токен'
$tokenRow=New-UiRow $pages[0];[void](New-UiLabel $tokenRow 'Токен локального сервера');$tokenBox=New-UiText $tokenRow 370;$tokenBox.UseSystemPasswordChar=$true
$tokenHelp=New-UiLabel $pages[0] 'Токен создаётся в настройках сервера. Для LM Studio — при включённом Require Authentication. Вход в аккаунт Anthropic выполняется отдельно на шаге 3.'
$connectRow=New-UiRow $pages[0];$connectButton=New-UiButton $connectRow 'Проверить сервер и найти модели' 330
$pythonInstallButton=New-UiButton $connectRow 'Установить Python' 190

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
$bindingSummary=New-UiLabel $pages[1] ''
$diagnosticsRow=New-UiRow $pages[1];$testButton=New-UiButton $diagnosticsRow 'Повторить тест ответа' 230;$toolsButton=New-UiButton $diagnosticsRow 'Повторить тест инструментов' 270

# Step 3: account identity is read from the isolated CLI, not inferred from an API token.
[void](New-UiLabel $pages[2] 'Войдите в отдельный аккаунт Anthropic' -Heading)
[void](New-UiLabel $pages[2] 'Откроется отдельное окно VS Code для входа. Выберите нужный аккаунт в браузере, завершите вход в Claude Code и вернитесь сюда. Основной аккаунт и его настройки сохраняются отдельно.')
$accountRow=New-UiRow $pages[2];$loginButton=New-UiButton $accountRow 'Открыть вход в аккаунт профиля' 280;$checkAccountButton=New-UiButton $accountRow 'Проверить вход' 190
$accountLabel=New-UiLabel $pages[2] 'Вход в отдельном профиле пока не проверен.'
$identityCheck=New-UiCheck $pages[2] 'Подтверждаю: это мой отдельный аккаунт профиля'
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
$script:selectedAlias='sonnet';$script:selectedProject=[string]$projectBox.SelectedItem
$script:openDropdowns=@{Backend=$false;Alias=$false;Project=$false}

$script:controls=@{Form=$form;Backend=$backendBox;RuntimeChoice=$runtimeChoice;Install=$installButton;Endpoint=$endpointBox;AuthRequired=$authRequired;Token=$tokenBox;TokenRow=$tokenRow;Connect=$connectButton;List=$list;Filter=$filterBox;Verify=$verifyButton;ContextRow=$contextRow;Context=$contextBox;Aliases=$aliasBox;AliasRow=$aliasRow;Diagnostics=$diagnosticsRow;Login=$loginButton;CheckAccount=$checkAccountButton;Identity=$identityCheck;Projects=$projectBox;Launch=$launchButton;Unload=$unloadButton;Next=$nextButton;Back=$backButton;Navigation=$stepButtons;AdvancedConnection=$advancedConnection;AdvancedModel=$advancedModel}

function Write-UiLog {param([string]$Message);$log.AppendText('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message + "`r`n")}
function Get-DraftProvider {
    $token=if ($authRequired.Checked) {$tokenBox.Text} else {''}
    $candidate=New-Provider $script:selectedBackendKind $endpointBox.Text.Trim() $token
    if ($authRequired.Checked -and -not $token -and $candidate.Kind -eq $script:activeProvider.Kind -and $candidate.BaseUrl -eq $script:activeProvider.BaseUrl) {
        Set-Field $candidate 'TokenProtected' (Get-Field $script:activeProvider 'TokenProtected' '')
    }
    Set-Field $candidate 'AuthRequired' ([bool]$authRequired.Checked)
    return $candidate
}
function Update-DraftProvider {
    $script:draftProvider=$null;$script:draftError=''
    $script:flow.ConnectionValid=$false;$script:flow.TokenReady=$false
    try {
        $script:draftProvider=Get-DraftProvider;$script:flow.ConnectionValid=$true
        $script:flow.TokenReady=-not $authRequired.Checked -or [bool](Get-Field $script:draftProvider 'TokenProtected' '')
    } catch {$script:draftError='Укажите локальный адрес HTTP(S), например http://localhost:1234. Облачные адреса и параметры в URL не поддерживаются.'}
}
function Get-EditingAlias {
    if ($advancedModel.Checked -and $script:selectedAlias -ne 'sonnet' -and $script:mainValidation) {return $script:selectedAlias}
    return 'sonnet'
}
function Get-SelectedContext {
    if ($script:selectedBackendKind -notin @('LMStudio','Ollama')) {return 0}
    $value=[int]$contextBox.Value
    if ($list.SelectedItems.Count) {
        $limit=[int](Get-Field $list.SelectedItems[0].Tag 'MaxContext' 0)
        if ($limit -gt 0) {$value=[math]::Min($value,$limit)}
    }
    return $value
}
function Sync-ModelDraft {
    if ($script:changing -or (Get-EditingAlias) -ne 'sonnet' -or -not $script:flow.ServerValid) {return}
    # A blank selection, sorting and a hidden page do not alter the saved binding.
    if ($list.SelectedItems.Count -and $script:mainValidation) {
        $matches=$list.SelectedItems[0].Tag.ModelKey -eq $script:mainValidation.ModelKey -and (Get-SelectedContext) -eq $script:mainValidation.Context
        if ($script:flow.ModelValid -ne $matches) {$script:flow.Generation++;$script:flow.Error='';$script:flow.ModelValid=$matches}
    }
}
function Restore-MainSelection {
    if (-not $script:mainValidation) {return}
    $script:changing=$true
    try {
        $contextBox.Value=$script:mainValidation.Context
        $filterBox.Clear();Render-WorkflowModels
        $script:changing=$true
        foreach ($item in $list.Items) {$item.Selected=$item.Tag.ModelKey -eq $script:mainValidation.ModelKey}
    } finally {$script:changing=$false}
    Sync-ModelDraft
}
function Validate-SelectedProject {
    $script:flow.ProjectValid=$false
    if ($script:selectedProject) {
        try {
            $projectPath=$script:selectedProject
            if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {throw 'Выбранная папка проекта больше не существует. Выберите другую папку.'}
            Assert-LocalProject $projectPath;$script:flow.ProjectValid=$true
        } catch {$script:flow.Error=$_.Exception.Message}
    }
}
function Update-WorkflowUi {
    # Visibility/enabled changes can synchronously raise selection events. Apply
    # their updated state after this pass instead of overwriting it with old gates.
    if ($script:changing -or $script:updatingUi) {$script:updateUiPending=$true;return}
    $script:updatingUi=$true
    try {
        do {
            $script:updateUiPending=$false
            Update-WorkflowControls
        } while ($script:updateUiPending)
    } finally {$script:updatingUi=$false}
}
function Update-WorkflowControls {
    $script:flow.Backend=$script:selectedBackendKind
    $script:flow.InstallHelp=$runtimeChoice.Checked
    $script:flow.AdvancedConnection=$advancedConnection.Checked;$script:flow.AdvancedModel=$advancedModel.Checked;$script:flow.AuthRequired=$authRequired.Checked
    $script:flow.SelectedModel=$list.SelectedItems.Count -gt 0
    $script:flow.CanTargetServer=$null -ne $script:runtimeTarget -or $script:flow.ConnectionValid
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
        'LMStudio' {'В LM Studio скачайте или импортируйте модель и включите Local Server. Затем нажмите «Проверить сервер и найти модели».'}
        'Ollama' {'Установите Ollama, скачайте модель через ollama pull и запустите Ollama. По умолчанию используется порт 11434. Токен обычно не нужен.'}
        'Anthropic' {'Запустите приложение с Anthropic-совместимым API. Укажите его локальный адрес. Сервер должен предоставлять каталог моделей и Messages API.'}
        'OpenAI' {'Запустите приложение с OpenAI-совместимым API и укажите его адрес. При запуске VS Code будет использован локальный адаптер; для него нужен Python 3.9+.'}
    }
    $endpointSummary.Text='Проверяется API: ' + $endpointBox.Text
    $endpointRow.Visible=$policy.ShowEndpoint;$authRow.Visible=$policy.ShowAuthOption;$tokenRow.Visible=$policy.ShowToken;$tokenHelp.Visible=$policy.ShowToken
    $tokenHelp.Text='Токен создаётся в настройках локального сервера. В LM Studio он нужен при включённом Require Authentication. Вход Anthropic выполняется отдельно на шаге 3.'
    if ($script:flow.TokenReady -and -not $tokenBox.Text -and $authRequired.Checked) {$tokenHelp.Text += "`r`nДля этого адреса используется уже сохранённый токен; поле можно оставить пустым."}
    $backendBox.Enabled=$idle;$endpointBox.Enabled=$idle;$authRequired.Enabled=$idle;$tokenBox.Enabled=$idle;$advancedConnection.Enabled=$idle
    $connectButton.Enabled=$policy.CanCheckServer
    $pythonInstallButton.Visible=$script:flow.Backend -eq 'OpenAI' -and $script:flow.AdapterMissing;$pythonInstallButton.Enabled=$idle
    $list.Enabled=$idle -and $script:flow.ServerValid;$refreshButton.Enabled=$idle -and $script:flow.ServerValid
    $filterBox.Enabled=$idle -and $script:flow.ServerValid -and $script:flow.ModelCount -gt 0
    $advancedModel.Enabled=$idle -and $script:flow.ServerValid
    $contextRow.Visible=$policy.ShowContext;$aliasRow.Visible=$policy.ShowAliases;$diagnosticsRow.Visible=$policy.ShowModelDiagnostics
    $contextBox.Enabled=$idle;$aliasBox.Enabled=$idle;$verifyButton.Enabled=$policy.CanVerifyModel;$testButton.Enabled=$idle;$toolsButton.Enabled=$idle
    $bindingSummary.Visible=$null -ne $script:mainValidation
    if ($script:mainValidation) {$bindingSummary.Text="Проверенная основная модель: $($script:mainValidation.ModelKey). Контекст: $($script:mainValidation.Context)."}
    $loginButton.Enabled=$policy.CanCheckAccount;$checkAccountButton.Enabled=$policy.CanCheckAccount
    $identityCheck.Visible=$script:flow.AccountValid;$identityCheck.Enabled=$policy.CanConfirmIdentity
    $projectBox.Enabled=$policy.CanChooseProject;$addProjectButton.Enabled=$policy.CanChooseProject;$launchButton.Enabled=$policy.CanLaunch
    $unloadButton.Enabled=$policy.CanUnload
    $target=if ($script:runtimeTarget) {$script:runtimeTarget} else {$script:draftProvider}
    $targetTip.SetToolTip($unloadButton,$(if ($target) {"Выгрузить модели сервера $($target.Kind): $($target.BaseUrl)"} else {'Сначала укажите локальный адрес сервера.'}))
    $cancelButton.Visible=[bool]$script:job -and $script:flow.Busy -in @('Connect','Verify','Test','Account') -and -not $script:flow.Unloading
    $backButton.Visible=$script:flow.Step -gt 1;$backButton.Enabled=$idle
    $nextButton.Visible=$script:flow.Step -lt 4
    $nextButton.Enabled=switch ($script:flow.Step) {1 {$policy.CanGoModel} 2 {$policy.CanGoAccount} 3 {$policy.CanGoProject} default {$false}}
    $nextButton.Text=switch ($script:flow.Step) {1 {'Далее: модель'} 2 {'Далее: аккаунт профиля'} 3 {'Далее: проект'} default {'Далее'}}
    $emptyModelHelp.Visible=$list.Items.Count -eq 0
    $emptyModelHelp.Text=if ($script:flow.ModelCount -eq 0) {'Каталог сервера пуст. Скачайте или импортируйте модель в выбранном движке, затем обновите список.'} else {'По этому фильтру моделей нет. Очистите фильтр, чтобы вернуть список.'}
    $modelHelp.Text=if ($script:flow.Backend -in @('LMStudio','Ollama')) {'Выберите модель. Проверяются текстовый ответ и вызов инструмента. Для Claude Code по умолчанию запрашивается контекст 32 768; размер можно изменить в дополнительных параметрах.'} else {'Выберите модель. Проверяются текстовый ответ и вызов инструмента. Контекст задаётся в самом сервере; неподдерживаемые настройки здесь скрыты.'}
    $projectSummary.Text="Сервер: $($script:activeProvider.Kind) — $($script:activeProvider.BaseUrl)`r`nАккаунт: $($script:flow.AccountEmail)`r`nПроект: $($script:selectedProject)`r`nЗапуск использует отдельные настройки, историю и расширение Claude Code."
    $status.ForeColor=if ($script:flow.Error) {[Drawing.Color]::DarkRed} else {[Drawing.SystemColors]::ControlText}
    $busyText=switch ($script:flow.Busy) {'Connect' {'Получаем каталог моделей от сервера…'} 'Verify' {'Загружаем модель и проверяем текстовый ответ и инструменты. Первая загрузка может занять несколько минут.'} 'Account' {'Проверяем вход в отдельном профиле Anthropic…'} 'Login' {'Подготавливаем отдельный VS Code для входа. При первом запуске устанавливается расширение Claude Code.'} 'Launch' {'Проверяем настройки и запускаем отдельный VS Code…'} default {'Проверяем ответ модели…'}}
    $status.Text=if ($script:flow.Unloading) {'Выгружаются модели. Если сервер не отвечает, его процессы будут остановлены.'} elseif ($script:flow.Busy) {$busyText} elseif ($script:flow.Error) {$script:flow.Error} elseif ($script:flow.Step -eq 1 -and -not $script:flow.ConnectionValid) {$script:draftError} elseif ($script:flow.Step -eq 1 -and -not $script:flow.TokenReady) {'Введите API-токен локального сервера или отключите требование токена, если авторизация сервера выключена.'} elseif ($script:flow.Notice) {$script:flow.Notice} else {switch ($script:flow.Step) {1 {'Нажмите «Проверить сервер и найти модели». Установка нужна только если движок отсутствует.'} 2 {if ($script:flow.ModelValid) {'Основная модель проверена. Можно перейти к аккаунту профиля.'} else {'Выберите модель и нажмите «Проверить и использовать модель».'}} 3 {if ($script:flow.AccountValid) {'Подтвердите, что обнаруженная учётная запись — ваш отдельный аккаунт профиля.'} else {'Войдите в аккаунт профиля и нажмите «Проверить вход».'}} 4 {if ($script:flow.ProjectValid) {'Все обязательные шаги выполнены. Можно открыть локальный VS Code.'} else {'Выберите существующую отдельную папку проекта.'}}}}
    $root.RowStyles[5].Height=if ($showLog.Checked) {110} else {0};$log.Visible=$showLog.Checked
}

function Render-WorkflowModels {
    $key=if ($list.SelectedItems.Count) {$list.SelectedItems[0].Tag.ModelKey} else {''}
    $wasChanging=$script:changing;$script:changing=$true;$list.BeginUpdate()
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
    } finally {$list.EndUpdate();$script:changing=$wasChanging}
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
        $alias=Get-EditingAlias
        $selected=if ($Operation -eq 'Verify' -and $list.SelectedItems.Count) {$list.SelectedItems[0].Tag} else {$null}
        $ctx=if ($Operation -eq 'Verify') {Get-SelectedContext} else {0}
        $request=@{Operation=$Operation;Provider=$draft;Root=$paths.Root;Generation=$script:flow.Generation;Alias=$alias;Context=$ctx;ModelKey=$(if ($selected) {$selected.ModelKey} else {''});Project=$script:selectedProject;Tools=[bool]$Tools;Repo=$PSScriptRoot;Email=$script:flow.AccountEmail}
        if ($Operation -in @('Connect','Verify','Test','Launch')) {$script:runtimeTarget=$draft}
        $shell=[PowerShell]::Create()
        [void]$shell.AddScript({
            param($Core,$Workflow,$Json)
            $ErrorActionPreference='Stop';. $Core;. $Workflow;$j=$Json | ConvertFrom-Json
            $data=[ordered]@{generation=$j.Generation;operation=$j.Operation;provider=$j.Provider;alias=$j.Alias}
            switch ($j.Operation) {
                'Connect' {
                    if ($j.Provider.Kind -eq 'OpenAI') {[void](Assert-OpenAiRuntime)}
                    $data.models=@(Get-ProviderModels $j.Provider)
                    $saved=Get-SwitcherConfig $j.Root
                    if ($saved.provider.Kind -ne $j.Provider.Kind -or $saved.provider.BaseUrl -ne $j.Provider.BaseUrl) {Set-Field $saved 'bindings' ([pscustomobject]@{})}
                    Set-Field $saved 'provider' $j.Provider;Write-JsonFile (Get-StatePaths $j.Root).Config $saved
                    $data.bindings=$saved.bindings
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
                    if ($j.Provider.Kind -eq 'OpenAI') {[void](Assert-OpenAiRuntime)}
                    try {$auth=Get-IsolatedAccountStatus $j.Root} catch {throw ('ACCOUNT_GATE: ' + $_.Exception.Message)}
                    if (-not $auth.LoggedIn -or $auth.Email -ne $j.Email) {throw 'ACCOUNT_GATE: Profile account changed or signed out. Check the account again.'}
                    $saved=Get-SwitcherConfig $j.Root
                    if ($saved.provider.Kind -ne $j.Provider.Kind -or $saved.provider.BaseUrl -ne $j.Provider.BaseUrl) {throw 'SERVER_GATE: Saved server changed. Check the connection again.'}
                    try {Assert-LocalProject $j.Project} catch {throw ('PROJECT_GATE: ' + $_.Exception.Message)}
                    try {[void](Test-ModelEndpoint $saved.provider $saved.bindings.sonnet.ModelId)} catch {throw ('MODEL_GATE: ' + $_.Exception.Message)}
                }
            }
            if ($j.Operation -in @('Login','Launch')) {
                [void](Resolve-CodeExecutable)
                $data.launch=Start-IsolatedLauncher $j.Repo $j.Root -Login:($j.Operation -eq 'Login') -Project $j.Project
            }
            [pscustomobject]$data | ConvertTo-Json -Depth 40 -Compress
        }.ToString())
        [void]$shell.AddArgument((Join-Path $PSScriptRoot 'local_switcher_core.ps1'));[void]$shell.AddArgument((Join-Path $PSScriptRoot 'gui_workflow.ps1'));[void]$shell.AddArgument(($request | ConvertTo-Json -Depth 25 -Compress))
        $script:flow.Busy=$Operation;$script:flow.Error='';$script:flow.Notice=''
        $pending=$shell.BeginInvoke()
        $script:job=[pscustomobject]@{Shell=$shell;Pending=$pending;Operation=$Operation;Generation=$script:flow.Generation;Alias=$alias;ModelKey=$request.ModelKey;Context=$ctx}
        Write-UiLog "${Operation}: проверка началась."
    } catch {$script:flow.Error=$_.Exception.Message;$script:flow.Busy='';if ($shell) {$shell.Dispose()}}
    Update-WorkflowUi
}

function Poll-WorkflowJobs {
    $changed=$false
    foreach ($cancelled in @($script:cancelledJobs)) {
        if ($cancelled.Pending.IsCompleted) {
            try {[void]$cancelled.Shell.EndInvoke($cancelled.Pending)} catch {} finally {$cancelled.Shell.Dispose()}
            $script:cancelledJobs=@($script:cancelledJobs | Where-Object {$_ -ne $cancelled})
        }
    }
    if ($script:unloadJob -and $script:unloadJob.Pending.IsCompleted) {
        $changed=$true
        try {
            $output=$script:unloadJob.Shell.EndInvoke($script:unloadJob.Pending)
            if ($script:unloadJob.Shell.HadErrors) {throw [string]$script:unloadJob.Shell.Streams.Error[0]}
            $message=$output -join ' ';Write-UiLog $message
            $script:flow.Notice=if ($message -match 'not listening') {'Сервер уже выключен. Для продолжения запустите движок и проверьте подключение.'} elseif ($message -match 'Emergency stop complete') {'Движок принудительно остановлен. Запустите его заново и проверьте подключение.'} else {'Все модели выгружены, сервер работает. Перед продолжением снова проверьте подключение.'}
        } catch {$script:flow.Error='Выгрузка не завершена: ' + $_.Exception.Message;Write-UiLog $script:flow.Error}
        finally {$script:unloadJob.Shell.Dispose();$script:unloadJob=$null;$script:flow.Unloading=$false}
    }
    if ($script:job -and $script:job.Pending.IsCompleted) {
        $changed=$true
        $job=$script:job
        try {
            $output=$job.Shell.EndInvoke($job.Pending)
            if ($job.Generation -eq $script:flow.Generation) {
                if ($job.Shell.HadErrors) {throw [string]$job.Shell.Streams.Error[0]}
                $data=($output -join '') | ConvertFrom-Json
                switch ($job.Operation) {
                    'Connect' {
                        $script:activeProvider=$data.provider;$script:bindingsCache=$data.bindings;$script:catalog=@($data.models);$script:flow.ModelCount=$script:catalog.Count
                        $script:flow.ServerValid=$true;$script:flow.RuntimeReady=$true;$script:flow.ModelValid=$false;$script:mainValidation=$null;$script:flow.Step=2
                        Render-WorkflowModels;Update-DraftProvider
                        $main=Get-Field $script:bindingsCache 'sonnet'
                        if ($main) {foreach ($item in $list.Items) {if ($item.Tag.ModelKey -eq $main.ModelKey) {$script:changing=$true;$item.Selected=$true;$contextBox.Value=[math]::Min([int]$main.ContextLength,[int]$contextBox.Maximum);$script:changing=$false;break}}}
                        Write-UiLog "Найдено моделей: $($script:flow.ModelCount)."
                    }
                    'Verify' {
                        Set-Field $script:bindingsCache $job.Alias $data.binding
                        if ($job.Alias -eq 'sonnet') {$script:mainValidation=[pscustomobject]@{ModelKey=$job.ModelKey;Context=$job.Context};$script:flow.ModelValid=$true}
                        $script:flow.Notice="Модель для роли $($job.Alias) сохранена после проверки текста и инструмента."
                        Write-UiLog $script:flow.Notice
                    }
                    'Account' {
                        $script:flow.AccountValid=[bool]$data.account.LoggedIn
                        if (-not $data.account.LoggedIn -or $data.account.Email -ne $script:flow.AccountEmail) {$identityCheck.Checked=$false;$script:flow.IdentityConfirmed=$false}
                        $script:flow.AccountEmail=[string]$data.account.Email
                        $accountLabel.Text=if ($script:flow.AccountValid) {"Вход claude.ai подтверждён: $($script:flow.AccountEmail)`r`nПроверьте, что это именно нужный аккаунт."} else {'В отдельном профиле нет входа claude.ai. Нажмите «Открыть вход в аккаунт профиля», завершите авторизацию и повторите проверку.'}
                    }
                    'Login' {$script:flow.Notice='Отдельный VS Code открыт. Завершите вход в аккаунт профиля, затем нажмите «Проверить вход».';Write-UiLog $script:flow.Notice}
                    'Launch' {$script:flow.Notice='Отдельный VS Code запущен с локальной моделью и выбранной папкой проекта.';Write-UiLog $script:flow.Notice}
                    'Test' {Write-UiLog 'Повторная проверка модели прошла.'}
                }
            }
        } catch {
            if ($job.Generation -eq $script:flow.Generation) {
                $script:flow.Error=$_.Exception.Message;Write-UiLog $script:flow.Error
                if ($job.Shell.Streams.Error.Count) {Write-UiLog ([string](Get-Field $job.Shell.Streams.Error[0] 'ScriptStackTrace' ''))}
                if ($job.Operation -eq 'Connect') {
                    $script:flow.ServerValid=$false;$script:flow.ModelValid=$false;$script:mainValidation=$null;$script:flow.Step=1
                    if ($script:flow.Error -match 'HTTP 401|HTTP 403') {$advancedConnection.Checked=$true;$authRequired.Checked=$true;$script:flow.Error='Сервер требует авторизацию. Введите его API-токен и повторите проверку.'}
                    elseif ($script:flow.Error -match 'request failed:') {$runtimeChoice.Checked=$true;$script:flow.Error="Не удалось получить каталог от $($script:flow.Backend) по адресу $($endpointBox.Text). Запустите API-сервер выбранного движка, проверьте порт и повторите подключение."}
                }
                if ($job.Operation -in @('Verify','Test') -and $job.Alias -eq 'sonnet') {$script:flow.ModelValid=$false;$script:mainValidation=$null}
                if ($job.Operation -in @('Verify','Test') -and $script:flow.Error -match 'tool_use|tool call|probe tool|tool arguments') {$script:flow.Error='Модель не выполнила корректный вызов инструмента. Выберите модель с поддержкой tools или проверьте шаблон чата в движке и повторите проверку.'}
                if ($job.Operation -eq 'Account' -or $script:flow.Error -match 'ACCOUNT_GATE:') {$script:flow.AccountValid=$false;$identityCheck.Checked=$false;$script:flow.Step=3}
                if ($script:flow.Error -match 'SERVER_GATE:') {$message=$script:flow.Error;Reset-WorkflowServer $script:flow;$script:flow.Error=$message}
                if ($script:flow.Error -match 'MODEL_GATE:') {$script:flow.ModelValid=$false;$script:flow.Step=2}
                if ($script:flow.Error -match 'PROJECT_GATE:') {$script:flow.ProjectValid=$false;$script:flow.Step=4}
                if ($script:flow.Error -match 'PYTHON_GATE:') {$message=$script:flow.Error;Reset-WorkflowServer $script:flow;$script:mainValidation=$null;$script:flow.AdapterMissing=$true;$script:flow.Error=$message}
            }
        } finally {$job.Shell.Dispose();$script:job=$null;$script:flow.Busy=''}
    }
    if ($changed) {Update-WorkflowUi}
}
function Cancel-WorkflowJob {
    if (-not $script:job) {return}
    $job=$script:job;$script:job=$null;$script:flow.Generation++;$script:flow.Busy=''
    $script:cancelledJobs+=@($job)
    [void]$job.Shell.BeginStop($null,$null)
}
function Register-WorkflowProject {
    param([string]$ProjectPath)
    if (-not (Get-WorkflowPolicy $script:flow).CanChooseProject) {throw 'Сначала проверьте модель и вход в аккаунт профиля.'}
    Assert-LocalProject $ProjectPath;Add-LocalProject $paths.Root $ProjectPath
    if (-not $projectBox.Items.Contains($ProjectPath)) {[void]$projectBox.Items.Add($ProjectPath)}
    $projectBox.SelectedItem=$ProjectPath
}

function Invalidate-DraftServer {
    if ($script:changing) {return}
    Reset-WorkflowServer $script:flow;$script:mainValidation=$null;$script:catalog=@()
    if (-not $script:job -and -not $script:unloadJob) {$script:runtimeTarget=$null}
    Update-DraftProvider;Render-WorkflowModels
}
function Apply-BackendChoice {
    if ($script:changing) {return}
    $kind=$kinds[$backendBox.SelectedIndex]
    if ($kind -eq $script:selectedBackendKind) {return}
    $script:providerDrafts[$script:selectedBackendKind]=[pscustomobject]@{Endpoint=$endpointBox.Text;Auth=$authRequired.Checked;TokenProtected=(Protect-BackendToken $tokenBox.Text);Advanced=$advancedConnection.Checked;InstallHelp=$runtimeChoice.Checked}
    $script:changing=$true
    $saved=Get-SwitcherConfig $paths.Root
    if ($script:providerDrafts.ContainsKey($kind)) {
        $draft=$script:providerDrafts[$kind];$endpointBox.Text=$draft.Endpoint;$authRequired.Checked=$draft.Auth
        $tokenBox.Text=if ($draft.TokenProtected) {Get-BackendToken $draft} else {''}
        $advancedConnection.Checked=$draft.Advanced;$runtimeChoice.Checked=$draft.InstallHelp
    } else {
        $endpointBox.Text=if ($kind -eq $saved.provider.Kind) {$saved.provider.BaseUrl} else {(New-Provider $kind).BaseUrl}
        $tokenBox.Clear();$authRequired.Checked=$kind -eq $saved.provider.Kind -and [bool](Get-Field $saved.provider 'TokenProtected' '')
        $advancedConnection.Checked=$endpointBox.Text -ne (New-Provider $kind).BaseUrl;$runtimeChoice.Checked=$false
    }
    $script:selectedBackendKind=$kind;$advancedModel.Checked=$false;$script:selectedAlias='sonnet';$aliasBox.SelectedIndex=0;$contextBox.Value=32768
    $script:changing=$false;Invalidate-DraftServer
}
function Apply-AliasChoice {
    if ($script:changing -or [string]$aliasBox.SelectedItem -eq $script:selectedAlias) {return}
    $script:selectedAlias=[string]$aliasBox.SelectedItem
    if ($script:selectedAlias -eq 'sonnet') {Restore-MainSelection}
    Update-WorkflowUi
}
function Apply-ProjectChoice {
    if ($script:changing -or [string]$projectBox.SelectedItem -eq $script:selectedProject) {return}
    $script:selectedProject=[string]$projectBox.SelectedItem
    $script:flow.Error='';$script:flow.Notice='';Validate-SelectedProject;Update-WorkflowUi
}
function Restore-ComboIndex {
    param($Combo,[int]$Index)
    if ($Combo.SelectedIndex -eq $Index) {return}
    $script:changing=$true
    try {$Combo.SelectedIndex=$Index} finally {$script:changing=$false}
}
# Browsing an open native dropdown is a preview. Apply only a committed choice;
# Esc/closing without committing restores the prior value and all readiness.
$backendBox.Add_DropDown({$script:openDropdowns.Backend=$true})
$backendBox.Add_SelectedIndexChanged({if (-not $script:openDropdowns.Backend -and -not $backendBox.DroppedDown) {Apply-BackendChoice}})
$backendBox.Add_SelectionChangeCommitted({Apply-BackendChoice;$script:openDropdowns.Backend=$false})
$backendBox.Add_DropDownClosed({Restore-ComboIndex $backendBox ([array]::IndexOf($kinds,$script:selectedBackendKind));$script:openDropdowns.Backend=$false})
$runtimeChoice.Add_CheckedChanged({Update-WorkflowUi})
$endpointBox.Add_TextChanged({Invalidate-DraftServer})
$tokenBox.Add_TextChanged({Invalidate-DraftServer})
$authRequired.Add_CheckedChanged({Invalidate-DraftServer})
$advancedConnection.Add_CheckedChanged({Update-WorkflowUi})
$advancedModel.Add_CheckedChanged({
    if (-not $script:changing -and -not $advancedModel.Checked -and $aliasBox.SelectedItem -ne 'sonnet') {
        $script:changing=$true;$aliasBox.SelectedIndex=0;$script:selectedAlias='sonnet';$script:changing=$false;Restore-MainSelection
    }
    Update-WorkflowUi
})
$connectButton.Add_Click({Start-WorkflowJob 'Connect'})
$refreshButton.Add_Click({Start-WorkflowJob 'Connect'})
$filterBox.Add_TextChanged({Render-WorkflowModels})
$list.Add_SelectedIndexChanged({if (-not $script:changing) {Sync-ModelDraft;Update-WorkflowUi}})
$list.Add_ColumnClick({param($sender,$event);$next=Get-NextSort $script:lastSortClick $script:sortDescending $event.Column;$script:sortColumn=$next.Column;$script:lastSortClick=$next.Column;$script:sortDescending=$next.Descending;Render-WorkflowModels})
$contextBox.Add_ValueChanged({if (-not $script:changing) {Sync-ModelDraft;Update-WorkflowUi}})
$aliasBox.Add_DropDown({$script:openDropdowns.Alias=$true})
$aliasBox.Add_SelectedIndexChanged({if (-not $script:openDropdowns.Alias -and -not $aliasBox.DroppedDown) {Apply-AliasChoice}})
$aliasBox.Add_SelectionChangeCommitted({Apply-AliasChoice;$script:openDropdowns.Alias=$false})
$aliasBox.Add_DropDownClosed({Restore-ComboIndex $aliasBox ([array]::IndexOf(@('sonnet','opus','haiku'),$script:selectedAlias));$script:openDropdowns.Alias=$false})
$verifyButton.Add_Click({Start-WorkflowJob 'Verify'})
$testButton.Add_Click({Start-WorkflowJob 'Test'})
$toolsButton.Add_Click({Start-WorkflowJob 'Test' -Tools})
$loginButton.Add_Click({Start-WorkflowJob 'Login'})
$checkAccountButton.Add_Click({Start-WorkflowJob 'Account'})
$identityCheck.Add_CheckedChanged({$script:flow.IdentityConfirmed=$identityCheck.Checked;Update-WorkflowUi})
$projectBox.Add_DropDown({$script:openDropdowns.Project=$true})
$projectBox.Add_SelectedIndexChanged({if (-not $script:openDropdowns.Project -and -not $projectBox.DroppedDown) {Apply-ProjectChoice}})
$projectBox.Add_SelectionChangeCommitted({Apply-ProjectChoice;$script:openDropdowns.Project=$false})
$projectBox.Add_DropDownClosed({Restore-ComboIndex $projectBox ($projectBox.Items.IndexOf($script:selectedProject));$script:openDropdowns.Project=$false})
$addProjectButton.Add_Click({
    if (-not (Get-WorkflowPolicy $script:flow).CanChooseProject) {return}
    $dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Выберите отдельную папку проекта для локальных моделей.'
    try {if ($dialog.ShowDialog() -eq 'OK') {Register-WorkflowProject $dialog.SelectedPath}}
    catch {$script:flow.Error=$_.Exception.Message} finally {$dialog.Dispose();Update-WorkflowUi}
})
$launchButton.Add_Click({Start-WorkflowJob 'Launch'})
$installButton.Add_Click({if ($script:flow.Backend -eq 'Ollama') {Start-Process 'https://ollama.com/download/windows' | Out-Null} elseif ($script:flow.Backend -eq 'LMStudio') {Start-Process 'https://lmstudio.ai/download' | Out-Null}})
$pythonInstallButton.Add_Click({Start-Process 'https://www.python.org/downloads/windows/' | Out-Null})
$backButton.Add_Click({if (-not $script:flow.Busy -and -not $script:flow.Unloading) {$script:flow.Step=[math]::Max(1,$script:flow.Step-1);$script:flow.Error='';Update-WorkflowUi}})
$nextButton.Add_Click({$policy=Get-WorkflowPolicy $script:flow;$allowed=switch ($script:flow.Step) {1 {$policy.CanGoModel} 2 {$policy.CanGoAccount} 3 {$policy.CanGoProject} default {$false}};if ($allowed) {$script:flow.Step++;$script:flow.Error='';Update-WorkflowUi}})
for ($i=0;$i -lt $stepButtons.Count;$i++) {$stepButtons[$i].Tag=$i+1;$stepButtons[$i].Add_Click({param($sender,$event);if ($sender.Enabled) {$script:flow.Step=[int]$sender.Tag;$script:flow.Error='';Update-WorkflowUi}})}
$showLog.Add_CheckedChanged({Update-WorkflowUi})
$cancelButton.Add_Click({Cancel-WorkflowJob;$script:flow.Notice='Проверка отменена. Можно изменить настройки или повторить запрос.';Update-WorkflowUi})
$unloadButton.Add_Click({
    if (-not (Get-WorkflowPolicy $script:flow).CanUnload) {return}
    $shell=$null
    try {
        $target=if ($script:runtimeTarget) {$script:runtimeTarget} else {Get-DraftProvider}
        Reset-WorkflowServer $script:flow
        $script:mainValidation=$null;Cancel-WorkflowJob
        $shell=[PowerShell]::Create();[void]$shell.AddScript({param($Core,$Json);$ErrorActionPreference='Stop';. $Core;Unload-AllModels ($Json | ConvertFrom-Json)}.ToString())
        [void]$shell.AddArgument((Join-Path $PSScriptRoot 'local_switcher_core.ps1'));[void]$shell.AddArgument(($target | ConvertTo-Json -Compress))
        $script:flow.Unloading=$true;$pending=$shell.BeginInvoke();$script:unloadJob=[pscustomobject]@{Shell=$shell;Pending=$pending}
        Write-UiLog 'Выгрузка выполняется независимо от основного запроса.'
    } catch {$script:flow.Unloading=$false;$script:flow.Error=$_.Exception.Message;if ($shell) {$shell.Dispose()}}
    Update-WorkflowUi
})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=200;$timer.Add_Tick({Poll-WorkflowJobs})
function Resize-WorkflowLayout {
    $width=[math]::Max(400,$pageHost.ClientSize.Width-30)
    $list.Width=$width;$list.Height=[math]::Max(120,[math]::Min(220,$pageHost.ClientSize.Height-250))
    $projectBox.Width=[math]::Max(300,[math]::Min(650,$width-210))
    foreach ($button in $stepButtons) {$button.Width=[math]::Max(150,[math]::Floor(($nav.ClientSize.Width-48)/4))}
    foreach ($page in $pages) {foreach ($control in $page.Controls) {if ($control -is [Windows.Forms.Label]) {$control.MaximumSize=New-Object Drawing.Size($width,0)}}}
}
$form.Add_Resize({Resize-WorkflowLayout})
$pageHost.Add_Resize({Resize-WorkflowLayout})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose();$targetTip.Dispose();if ($script:job) {[void]$script:job.Shell.BeginStop($null,$null)};if ($script:unloadJob) {[void]$script:unloadJob.Shell.BeginStop($null,$null)}})
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
Update-DraftProvider;Validate-SelectedProject;Render-WorkflowModels;Update-WorkflowUi;Resize-WorkflowLayout
Write-UiLog 'Следуйте четырём шагам. Переход открывается после проверки обязательного действия.'
if ($GuiTest) {return}
if ($PreviewPath) {
    $form.Show();[Windows.Forms.Application]::DoEvents()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save([IO.Path]::GetFullPath($PreviewPath),[Drawing.Imaging.ImageFormat]::Png)}
    finally {$bitmap.Dispose();$form.Close();$form.Dispose()}
} else {$timer.Start();[void]$form.ShowDialog();$form.Dispose()}
