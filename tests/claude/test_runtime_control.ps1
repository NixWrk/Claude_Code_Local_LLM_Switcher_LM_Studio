param([string]$Repo = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'agents\claude'))
$ErrorActionPreference='Stop'
. (Join-Path $Repo 'local_switcher_core.ps1')
$script:checks=0
function Assert {param([bool]$Condition,[string]$Message);if (-not $Condition) {throw $Message};$script:checks++}
function Assert-Throws {param([scriptblock]$Action,[string]$Message);$thrown=$false;try {& $Action | Out-Null} catch {$thrown=$true};Assert $thrown $Message}
$script:loaded=@('one','two');$script:hang=$false;$script:terminated=@();$script:owners=@(100);$script:calls=@()
$script:lmLoaded=@('chat-instance','embedding-instance')
$created=[datetime]'2026-01-01'
$script:table=@([pscustomobject]@{ProcessId=100;ParentProcessId=200;Name='ollama.exe';ExecutablePath='C:\fixture\ollama.exe';CreationDate=$created},
    [pscustomobject]@{ProcessId=200;ParentProcessId=300;Name='ollama app.exe';ExecutablePath='C:\fixture\ollama app.exe';CreationDate=$created},
    [pscustomobject]@{ProcessId=300;ParentProcessId=0;Name='Code.exe';ExecutablePath='C:\fixture\Code.exe';CreationDate=$created})
function Invoke-Backend {
    param($Provider,[string]$Path,[string]$Method='GET',$Body=$null,[int]$TimeoutSec=15)
    Assert ($TimeoutSec -le 2) 'Normal unload request has an unbounded timeout'
    if ($script:hang) {throw 'Fixture engine is unresponsive'}
    if ($Path -eq '/api/ps') {return [pscustomobject]@{models=@($script:loaded | ForEach-Object {[pscustomobject]@{name=$_}})}}
    if ($Path -eq '/api/generate') {Assert ($Body.keep_alive -eq 0 -and -not $Body.stream) 'Model unload request incorrect';$script:calls += $Body.model;$script:loaded=@($script:loaded | Where-Object {$_ -ne $Body.model});return [pscustomobject]@{done=$true}}
    if ($Path -eq '/api/v1/models') {return [pscustomobject]@{models=@($script:lmLoaded | ForEach-Object {[pscustomobject]@{loaded_instances=@([pscustomobject]@{id=$_})}})}}
    if ($Path -eq '/api/v1/models/unload') {$script:lmLoaded=@($script:lmLoaded | Where-Object {$_ -ne $Body.instance_id});return [pscustomobject]@{instance_id=$Body.instance_id}}
    throw 'Unexpected endpoint'
}
function Get-LocalListenerIds {param([int]$Port);Assert ($Port -eq 11434) 'Wrong server port targeted';return $script:owners}
function Get-EngineProcessTable {return $script:table}
$realStop=${function:Stop-EngineProcessTree}
function Stop-EngineProcessTree {param($Target);$script:terminated += $Target.ProcessId;$script:owners=@()}
$provider=New-Provider Ollama
$result=Unload-AllModels $provider
Assert ($script:loaded.Count -eq 0 -and $script:calls.Count -eq 2) 'Not all loaded models were unloaded'
Assert ($script:terminated.Count -eq 0) 'Healthy engine was unnecessarily terminated'
Assert ($result -like '*still running*') 'Graceful result is misleading'
$result=Unload-AllModels (New-Provider LMStudio)
Assert ($script:lmLoaded.Count -eq 0) 'LM Studio did not unload all instances including embeddings'
Assert ($script:terminated.Count -eq 0) 'Healthy LM Studio was unnecessarily terminated'
$script:hang=$true
$result=Unload-AllModels $provider
Assert ($script:terminated.Count -eq 1 -and $script:terminated[0] -eq 200) 'Hanging engine launcher was not stopped, or unrelated parent was targeted'
Assert ($result -like '*Restart the runtime*') 'Forced termination is not explained'
$script:owners=@(300);$script:terminated=@()
Assert-Throws {Unload-AllModels $provider -Force} 'Protected VS Code process was allowed to terminate'
Assert ($script:terminated.Count -eq 0) 'Protected process termination attempted'
$script:owners=@()
$result=Unload-AllModels $provider -Force
Assert ($result -like '*not listening*') 'Offline engine result is misleading'
$script:owners=@(100)
$script:table[1].CreationDate=$created.AddMinutes(1)
$safeTargets=@(Get-EngineStopTargets $provider)
Assert ($safeTargets.Count -eq 1 -and $safeTargets[0].ProcessId -eq 100) 'A reused parent PID incorrectly expanded the termination target'
$target=$script:table[0]
$changed=[pscustomobject]@{ProcessId=100;ParentProcessId=200;Name='ollama.exe';ExecutablePath='C:\different\ollama.exe';CreationDate=$created.AddSeconds(1)}
$script:table=@($changed)
Assert-Throws {& $realStop $target} 'PID reuse identity check failed'
Write-Output "PASS: $script:checks emergency unload checks (PowerShell $($PSVersionTable.PSVersion))."
