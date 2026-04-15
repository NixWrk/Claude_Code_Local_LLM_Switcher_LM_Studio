param(
    [switch]$Headless,
    [string]$Alias,
    [string]$ModelKey,
    [int]$ContextLength = 0,
    [switch]$TestAlias,
    [switch]$ShowLoaded
)

$ErrorActionPreference = 'Stop'
if ($ContextLength -lt 0) {
    throw 'ContextLength must be >= 0.'
}

function Normalize-LmsOutput {
    param([string]$Text)

    if (-not $Text) {
        return ''
    }

    $clean = $Text -replace "`0", ''
    $esc = [char]27
    $clean = [regex]::Replace($clean, "$([regex]::Escape($esc))\[[0-9;?]*[ -/]*[@-~]", '')

    $lines = @()
    foreach ($rawLine in ($clean -split "(`r`n|`n|`r)")) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($line -match '^\[\?25[hl]$') { continue }
        if ($line -match '^Loading\s+') { continue }
        if ($line -match '\[CliPref\] Error writing data to file') { continue }
        $lines += $line
    }

    if ($lines.Count -eq 0) {
        return ''
    }

    return ($lines -join [Environment]::NewLine).Trim()
}

function Run-LmsCommand {
    param(
        [string[]]$CommandArgs,
        [switch]$JsonMode
    )

    $cmd = Get-Command lms -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw 'LM Studio CLI (lms) was not found in PATH. Install/enable LM Studio CLI first.'
    }
    if (-not $CommandArgs -or $CommandArgs.Count -eq 0) {
        throw 'No lms arguments provided.'
    }

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $stdout = ''
    $stderr = ''
    try {
        $proc = Start-Process -FilePath $cmd.Source -ArgumentList $CommandArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if (Test-Path $stdoutPath) {
            $stdout = Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path $stderrPath) {
            $stderr = Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue
        }
        $exitCode = $proc.ExitCode
    }
    finally {
        if (Test-Path $stdoutPath) {
            Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $stderrPath) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }

    $combined = ($stdout, $stderr -join [Environment]::NewLine)
    $normalized = Normalize-LmsOutput -Text $combined
    $jsonPayload = if ($stdout) { $stdout.Trim() } else { '' }

    if ($exitCode -ne 0) {
        throw "lms command failed (exit $exitCode): lms $($CommandArgs -join ' ')`n$normalized"
    }

    if ($JsonMode) {
        return $jsonPayload
    }
    return $normalized
}

function Get-LmsJson {
    param([string[]]$CommandArgs)

    $raw = Run-LmsCommand -CommandArgs $CommandArgs -JsonMode
    if (-not $raw.Trim()) {
        return @()
    }

    try {
        return ($raw | ConvertFrom-Json)
    }
    catch {
        throw "Failed to parse JSON from: lms $($CommandArgs -join ' ')`nRaw output:`n$raw"
    }
}

function Get-LoadedLlmInstances {
    $loaded = Get-LmsJson -CommandArgs @('ps', '--json')
    return @($loaded | Where-Object { $_.type -eq 'llm' })
}

function Bind-ModelAlias {
    param(
        [Parameter(Mandatory = $true)][string]$BindAlias,
        [Parameter(Mandatory = $true)][string]$BindModelKey,
        [int]$BindContextLength = 0
    )

    $logParts = @()
    $existing = Get-LoadedLlmInstances | Where-Object { $_.identifier -eq $BindAlias } | Select-Object -First 1
    if ($existing) {
        $unloadOut = Run-LmsCommand -CommandArgs @('unload', $BindAlias)
        if ($unloadOut.Trim()) {
            $logParts += $unloadOut.Trim()
        }
    }

    $loadArgs = @('load', $BindModelKey, '--identifier', $BindAlias, '-y')
    if ($BindContextLength -gt 0) {
        $loadArgs += @('-c', "$BindContextLength")
    }
    $loadOut = Run-LmsCommand -CommandArgs $loadArgs
    if ($loadOut.Trim()) {
        $logParts += $loadOut.Trim()
    }

    return ($logParts -join [Environment]::NewLine)
}

function Test-AnthropicEndpoint {
    param([Parameter(Mandatory = $true)][string]$AliasToTest)

    $url = 'http://localhost:1234/v1/messages'
    $headers = @{
        'x-api-key' = 'lmstudio'
        'anthropic-version' = '2023-06-01'
        'Content-Type' = 'application/json'
    }
    $bodyObject = @{
        model = $AliasToTest
        max_tokens = 8
        messages = @(
            @{ role = 'user'; content = 'Reply with OK only.' }
        )
    }

    $body = $bodyObject | ConvertTo-Json -Depth 8
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Post -Headers $headers -Body $body -TimeoutSec 30
        $sw.Stop()
        return "Endpoint test OK: HTTP $($resp.StatusCode), $($sw.ElapsedMilliseconds) ms"
    }
    catch {
        $sw.Stop()
        if ($_.Exception.Response) {
            $resp = $_.Exception.Response
            return "Endpoint test failed: HTTP $([int]$resp.StatusCode), $($sw.ElapsedMilliseconds) ms"
        }
        return "Endpoint test failed: $($_.Exception.Message)"
    }
}

if ($Headless) {
    if ($ShowLoaded) {
        $instances = Get-LoadedLlmInstances
        if ($instances.Count -eq 0) {
            Write-Output 'No loaded LLM instances.'
        }
        else {
            foreach ($m in $instances) {
                Write-Output ("loaded: identifier='{0}', modelKey='{1}', status='{2}', parallel={3}, ctx={4}, maxCtx={5}" -f $m.identifier, $m.modelKey, $m.status, $m.parallel, $m.contextLength, $m.maxContextLength)
            }
        }
    }

    if ($Alias -and $ModelKey) {
        Write-Output "Binding alias '$Alias' -> '$ModelKey'..."
        if ($ContextLength -gt 0) {
            Write-Output "Requested context length: $ContextLength"
        }
        $bindOutput = Bind-ModelAlias -BindAlias $Alias -BindModelKey $ModelKey -BindContextLength $ContextLength
        if ($bindOutput.Trim()) {
            Write-Output $bindOutput.Trim()
        }
        Write-Output "Done. Alias '$Alias' now points to '$ModelKey'."
    }
    elseif ($Alias -or $ModelKey) {
        throw 'For headless binding, provide both -Alias and -ModelKey.'
    }

    if ($TestAlias) {
        if (-not $Alias) {
            throw 'Use -Alias <name> together with -TestAlias.'
        }
        $testResult = Test-AnthropicEndpoint -AliasToTest $Alias
        Write-Output $testResult
    }

    if (-not $ShowLoaded -and -not ($Alias -and $ModelKey) -and -not $TestAlias) {
        Write-Output 'Headless mode: no action requested.'
        Write-Output 'Example: -Headless -Alias sonnet -ModelKey mistralai/ministral-3-3b -ContextLength 32768 -TestAlias'
    }

    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Write-Log {
    param(
        [System.Windows.Forms.TextBox]$Box,
        [string]$Message
    )
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $Box.AppendText("[$timestamp] $Message`r`n")
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Code Local LLM Switcher (LM Studio)'
$form.Size = New-Object System.Drawing.Size(1020, 740)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(980, 680)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = 'Pick a local model and bind it to Claude alias (sonnet/opus/haiku/default). Context 0 = auto.'
$lblInfo.AutoSize = $true
$lblInfo.Location = New-Object System.Drawing.Point(12, 12)
$form.Controls.Add($lblInfo)

$lblAlias = New-Object System.Windows.Forms.Label
$lblAlias.Text = 'Alias:'
$lblAlias.AutoSize = $true
$lblAlias.Location = New-Object System.Drawing.Point(12, 45)
$form.Controls.Add($lblAlias)

$cmbAlias = New-Object System.Windows.Forms.ComboBox
$cmbAlias.DropDownStyle = 'DropDownList'
$cmbAlias.Location = New-Object System.Drawing.Point(60, 40)
$cmbAlias.Size = New-Object System.Drawing.Size(220, 24)
@(
    'sonnet',
    'opus',
    'haiku',
    'default',
    'claude-sonnet-4-6',
    'claude-opus-4-6',
    'claude-haiku-4-5'
) | ForEach-Object { [void]$cmbAlias.Items.Add($_) }
$cmbAlias.SelectedIndex = 0
$form.Controls.Add($cmbAlias)

$chkCustomAlias = New-Object System.Windows.Forms.CheckBox
$chkCustomAlias.Text = 'Custom alias'
$chkCustomAlias.AutoSize = $true
$chkCustomAlias.Location = New-Object System.Drawing.Point(290, 43)
$form.Controls.Add($chkCustomAlias)

$txtCustomAlias = New-Object System.Windows.Forms.TextBox
$txtCustomAlias.Location = New-Object System.Drawing.Point(390, 40)
$txtCustomAlias.Size = New-Object System.Drawing.Size(180, 24)
$txtCustomAlias.Enabled = $false
$form.Controls.Add($txtCustomAlias)

$chkCustomAlias.Add_CheckedChanged({
    $txtCustomAlias.Enabled = $chkCustomAlias.Checked
})

$lblContext = New-Object System.Windows.Forms.Label
$lblContext.Text = 'Context:'
$lblContext.AutoSize = $true
$lblContext.Location = New-Object System.Drawing.Point(580, 45)
$form.Controls.Add($lblContext)

$numContext = New-Object System.Windows.Forms.NumericUpDown
$numContext.Location = New-Object System.Drawing.Point(640, 40)
$numContext.Size = New-Object System.Drawing.Size(100, 24)
$numContext.Minimum = 0
$numContext.Maximum = 1048576
$numContext.Increment = 1024
$numContext.Value = 0
$numContext.ThousandsSeparator = $true
$form.Controls.Add($numContext)

$lblContextHint = New-Object System.Windows.Forms.Label
$lblContextHint.Text = '0 = auto'
$lblContextHint.AutoSize = $true
$lblContextHint.Location = New-Object System.Drawing.Point(750, 45)
$form.Controls.Add($lblContextHint)

$lblFilter = New-Object System.Windows.Forms.Label
$lblFilter.Text = 'Filter:'
$lblFilter.AutoSize = $true
$lblFilter.Location = New-Object System.Drawing.Point(12, 78)
$form.Controls.Add($lblFilter)

$txtFilter = New-Object System.Windows.Forms.TextBox
$txtFilter.Location = New-Object System.Drawing.Point(60, 74)
$txtFilter.Size = New-Object System.Drawing.Size(590, 24)
$form.Controls.Add($txtFilter)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh Models'
$btnRefresh.Location = New-Object System.Drawing.Point(660, 72)
$btnRefresh.Size = New-Object System.Drawing.Size(170, 28)
$form.Controls.Add($btnRefresh)

$listView = New-Object System.Windows.Forms.ListView
$listView.Location = New-Object System.Drawing.Point(12, 108)
$listView.Size = New-Object System.Drawing.Size(978, 430)
$listView.View = 'Details'
$listView.FullRowSelect = $true
$listView.MultiSelect = $false
$listView.GridLines = $true
[void]$listView.Columns.Add('Model Key', 350)
[void]$listView.Columns.Add('Display Name', 200)
[void]$listView.Columns.Add('Publisher', 120)
[void]$listView.Columns.Add('Size (GiB)', 90)
[void]$listView.Columns.Add('Params', 70)
[void]$listView.Columns.Add('Arch', 120)
$form.Controls.Add($listView)

$btnBind = New-Object System.Windows.Forms.Button
$btnBind.Text = 'Bind Alias To Selected Model'
$btnBind.Location = New-Object System.Drawing.Point(12, 550)
$btnBind.Size = New-Object System.Drawing.Size(290, 34)
$form.Controls.Add($btnBind)

$btnShowLoaded = New-Object System.Windows.Forms.Button
$btnShowLoaded.Text = 'Show Loaded Models'
$btnShowLoaded.Location = New-Object System.Drawing.Point(315, 550)
$btnShowLoaded.Size = New-Object System.Drawing.Size(190, 34)
$form.Controls.Add($btnShowLoaded)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = 'Test /v1/messages with Alias'
$btnTest.Location = New-Object System.Drawing.Point(520, 550)
$btnTest.Size = New-Object System.Drawing.Size(240, 34)
$form.Controls.Add($btnTest)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(12, 592)
$logBox.Size = New-Object System.Drawing.Size(978, 80)
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$form.Controls.Add($logBox)

$script:AllModels = @()

function Get-TargetAlias {
    if ($chkCustomAlias.Checked) {
        $custom = $txtCustomAlias.Text.Trim()
        if (-not $custom) {
            throw 'Custom alias is empty.'
        }
        return $custom
    }
    return [string]$cmbAlias.SelectedItem
}

function Get-TargetContextLength {
    return [int]$numContext.Value
}

function Refresh-ModelList {
    $listView.Items.Clear()
    try {
        $models = Get-LmsJson -CommandArgs @('ls', '--json')
        $script:AllModels = @($models | Where-Object { $_.type -eq 'llm' })

        $flt = $txtFilter.Text.Trim().ToLowerInvariant()
        $filtered = $script:AllModels
        if ($flt) {
            $filtered = $filtered | Where-Object {
                ($_.modelKey -and $_.modelKey.ToLowerInvariant().Contains($flt)) -or
                ($_.displayName -and $_.displayName.ToLowerInvariant().Contains($flt)) -or
                ($_.publisher -and $_.publisher.ToLowerInvariant().Contains($flt))
            }
        }

        foreach ($m in $filtered) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$m.modelKey)
            [void]$item.SubItems.Add([string]$m.displayName)
            [void]$item.SubItems.Add([string]$m.publisher)
            $sizeGiB = ''
            if ($m.PSObject.Properties.Name -contains 'sizeBytes' -and $m.sizeBytes) {
                $sizeGiB = ('{0:N2}' -f ($m.sizeBytes / 1GB))
            }
            [void]$item.SubItems.Add([string]$sizeGiB)
            [void]$item.SubItems.Add([string]$m.paramsString)
            [void]$item.SubItems.Add([string]$m.architecture)
            $item.Tag = $m
            [void]$listView.Items.Add($item)
        }

        Write-Log -Box $logBox -Message "Loaded $($filtered.Count) model(s) from LM Studio catalog."
    }
    catch {
        Write-Log -Box $logBox -Message "Refresh failed: $($_.Exception.Message)"
    }
}

$btnRefresh.Add_Click({ Refresh-ModelList })
$txtFilter.Add_TextChanged({ Refresh-ModelList })

$btnShowLoaded.Add_Click({
    try {
        $llm = Get-LoadedLlmInstances
        if ($llm.Count -eq 0) {
            Write-Log -Box $logBox -Message 'No loaded LLM instances.'
            return
        }

        foreach ($m in $llm) {
            Write-Log -Box $logBox -Message ("loaded: identifier='{0}', modelKey='{1}', status='{2}', parallel={3}, ctx={4}, maxCtx={5}" -f $m.identifier, $m.modelKey, $m.status, $m.parallel, $m.contextLength, $m.maxContextLength)
        }
    }
    catch {
        Write-Log -Box $logBox -Message "Unable to list loaded models: $($_.Exception.Message)"
    }
})

$btnBind.Add_Click({
    try {
        if ($listView.SelectedItems.Count -eq 0) {
            throw 'Select a model first.'
        }

        $aliasTarget = Get-TargetAlias
        $contextTarget = Get-TargetContextLength
        $model = $listView.SelectedItems[0].Tag
        $modelKeyTarget = [string]$model.modelKey

        if ($contextTarget -gt 0) {
            Write-Log -Box $logBox -Message "Binding alias '$aliasTarget' -> '$modelKeyTarget' with context=$contextTarget..."
        }
        else {
            Write-Log -Box $logBox -Message "Binding alias '$aliasTarget' -> '$modelKeyTarget' with context=auto..."
        }
        $out = Bind-ModelAlias -BindAlias $aliasTarget -BindModelKey $modelKeyTarget -BindContextLength $contextTarget
        if ($out.Trim()) {
            foreach ($line in ($out -split "(`r`n|`n|`r)")) {
                $trimmed = $line.Trim()
                if ($trimmed) {
                    Write-Log -Box $logBox -Message $trimmed
                }
            }
        }
        Write-Log -Box $logBox -Message "Done. Alias '$aliasTarget' now points to '$modelKeyTarget' (context=$([int]$contextTarget))."
    }
    catch {
        Write-Log -Box $logBox -Message "Bind failed: $($_.Exception.Message)"
    }
})

$btnTest.Add_Click({
    try {
        $aliasTarget = Get-TargetAlias
        $msg = Test-AnthropicEndpoint -AliasToTest $aliasTarget
        Write-Log -Box $logBox -Message $msg
    }
    catch {
        Write-Log -Box $logBox -Message "Test failed: $($_.Exception.Message)"
    }
})

Write-Log -Box $logBox -Message 'Ready. Make sure LM Studio server is running on http://localhost:1234.'
Refresh-ModelList

[void]$form.ShowDialog()
