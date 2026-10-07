. (Join-Path $PSScriptRoot 'process.ps1')

function Resolve-CodeExecutable {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe')
    )
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\Code.exe' }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    foreach ($commandName in @('code', 'code.cmd', 'code.exe')) {
        $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { continue }
        if ([IO.Path]::GetFileName($command.Source) -ieq 'Code.exe') { return $command.Source }
        $candidate = Join-Path (Split-Path (Split-Path $command.Source -Parent) -Parent) 'Code.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $legacyPath = 'C:\PC\Visual_studio_code\Microsoft VS Code\Code.exe'
    if (Test-Path -LiteralPath $legacyPath -PathType Leaf) { return $legacyPath }
    throw 'VS Code Code.exe was not found. Install VS Code or add code to PATH.'
}

function Start-CodeCli {
    param([string]$Executable, [string[]]$Arguments, [switch]$Wait)
    $installRoot=Split-Path $Executable -Parent
    $candidates=@((Join-Path $installRoot 'resources\app\out\cli.js'))
    foreach ($dir in @(Get-ChildItem -LiteralPath $installRoot -Directory)) {$candidates += (Join-Path $dir.FullName 'resources\app\out\cli.js')}
    $cli=$candidates | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
    if (-not $cli) {throw 'VS Code CLI entry point was not found.'}
    $electron=[Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE','Process')
    $dev=[Environment]::GetEnvironmentVariable('VSCODE_DEV','Process')
    try {
        $env:ELECTRON_RUN_AS_NODE='1'; [Environment]::SetEnvironmentVariable('VSCODE_DEV',$null,'Process')
        $args=@($cli) + $Arguments
        $process=Start-Process -FilePath $Executable -ArgumentList (($args | ForEach-Object {ConvertTo-ProcessArgument $_}) -join ' ') -WindowStyle Hidden -PassThru
        if ($Wait) {$process.WaitForExit()}
        return $process
    } finally {
        [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE',$electron,'Process')
        [Environment]::SetEnvironmentVariable('VSCODE_DEV',$dev,'Process')
    }
}
