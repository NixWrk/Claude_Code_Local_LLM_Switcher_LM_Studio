# Emergency unloading runs independently of catalog/binding workers.
function Get-LocalListenerIds {
    param([int]$Port)
    $netstat=Join-Path $env:SystemRoot 'System32\netstat.exe'
    $lines=@(& $netstat -ano -p tcp)
    if ($LASTEXITCODE -ne 0) {throw 'Cannot inspect listening server ports in this execution environment.'}
    $owners=@()
    foreach ($line in $lines) {
        if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$' -and [int]$Matches[1] -eq $Port) {$owners += [int]$Matches[2]}
    }
    return @($owners | Select-Object -Unique)
}

function Get-EngineProcessTable {
    return @(Get-CimInstance Win32_Process -ErrorAction Stop)
}

function Test-ProtectedProcess {
    param([string]$Name)
    return $Name -match '(?i)^(system|registry|idle|svchost|services|lsass|wininit|winlogon|csrss|explorer|code|code-insiders|codex|claude|chrome|msedge|firefox|powershell|pwsh|conhost|cmd)(\.exe)?$'
}

function Get-EngineStopTargets {
    param($Provider)
    $uri=[Uri]$Provider.BaseUrl
    if (-not $uri.IsLoopback) {throw 'Emergency stop only supports the selected loopback server.'}
    $owners=@(Get-LocalListenerIds $uri.Port)
    if (-not $owners.Count) {return @()}
    $table=@(Get-EngineProcessTable)
    foreach ($owner in $owners) {
        $process=$table | Where-Object {[int]$_.ProcessId -eq [int]$owner} | Select-Object -First 1
        if (-not $process -or -not $process.ExecutablePath -or (Test-ProtectedProcess $process.Name)) {
            throw 'Cannot safely identify or stop the selected server process. No process was terminated.'
        }
        # Stop a known runtime launcher as well, to prevent its automatic respawn.
        $seen=@([int]$process.ProcessId)
        while ($process.ParentProcessId) {
            $parent=$table | Where-Object {[int]$_.ProcessId -eq [int]$process.ParentProcessId} | Select-Object -First 1
            if (-not $parent -or [int]$parent.ProcessId -in $seen -or $parent.Name -notmatch '(?i)^(ollama app|ollama|LM Studio|LM-Studio|llmster|lms)\.exe$') {break}
            if (-not $parent.CreationDate -or -not $process.CreationDate -or $parent.CreationDate -gt $process.CreationDate) {break}
            $process=$parent; $seen += [int]$process.ProcessId
        }
        [pscustomobject]@{ProcessId=[int]$process.ProcessId;Name=$process.Name;ExecutablePath=$process.ExecutablePath;CreationDate=$process.CreationDate}
    }
}

function Stop-EngineProcessTree {
    param($Target)
    # Recheck identity before termination, avoiding PID reuse or a replaced process.
    $current=@(Get-EngineProcessTable) | Where-Object {[int]$_.ProcessId -eq $Target.ProcessId} | Select-Object -First 1
    if (-not $current) {return}
    if ($current.ExecutablePath -ne $Target.ExecutablePath -or $current.CreationDate -ne $Target.CreationDate -or (Test-ProtectedProcess $current.Name)) {
        throw 'Server process identity changed. Emergency stop refused.'
    }
    $killer=Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $job=Start-Process -FilePath $killer -ArgumentList @('/PID',[string]$Target.ProcessId,'/T','/F') -WindowStyle Hidden -PassThru
    if (-not $job.WaitForExit(5000)) {throw 'Windows did not finish terminating the engine within 5 seconds.'}
    if ($job.ExitCode -ne 0 -and (Get-Process -Id $Target.ProcessId -ErrorAction SilentlyContinue)) {throw 'Windows denied stopping the engine. Models may still be loaded.'}
}

function Unload-AllModels {
    param($Provider, [switch]$Force)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $normal=$false
    if (-not $Force) {
        try {
            switch ($Provider.Kind) {
                'Ollama' {
                    $loaded=Invoke-Backend $Provider '/api/ps' -TimeoutSec 2
                    foreach ($model in @($loaded.models)) {
                        if ($watch.Elapsed.TotalSeconds -gt 6) {throw 'Normal unload time budget exhausted.'}
                        [void](Invoke-Backend $Provider '/api/generate' 'POST' @{model=$model.name;keep_alive=0;stream=$false} 2)
                    }
                    $remaining=Invoke-Backend $Provider '/api/ps' -TimeoutSec 2
                    $normal=@($remaining.models).Count -eq 0
                }
                'LMStudio' {
                    $catalog=Invoke-Backend $Provider '/api/v1/models' -TimeoutSec 2
                    foreach ($model in @($catalog.models)) {
                        foreach ($instance in @(Get-Field $model 'loaded_instances' @())) {
                            if ($watch.Elapsed.TotalSeconds -gt 6) {throw 'Normal unload time budget exhausted.'}
                            [void](Invoke-Backend $Provider '/api/v1/models/unload' 'POST' @{instance_id=$instance.id} 2)
                        }
                    }
                    $remaining=Invoke-Backend $Provider '/api/v1/models' -TimeoutSec 2
                    $normal=-not @($remaining.models | ForEach-Object {Get-Field $_ 'loaded_instances' @()}).Count
                }
                default {throw 'This generic API has no portable unload command.'}
            }
        } catch {$normal=$false}
    }
    if ($normal) {return 'All models unloaded. The server is still running; saved bindings are retained.'}
    $targets=@(Get-EngineStopTargets $Provider | Sort-Object ProcessId -Unique)
    if (-not $targets.Count) {return 'The selected server is not listening. No engine process was stopped.'}
    foreach ($target in $targets) {Stop-EngineProcessTree $target}
    $uri=[Uri]$Provider.BaseUrl
    if (@(Get-LocalListenerIds $uri.Port).Count) {throw 'The server port is still listening after emergency stop. Check for an automatic restart.'}
    return 'Emergency stop complete: selected server and child processes terminated. Restart the runtime before using models again. Saved bindings are retained.'
}
