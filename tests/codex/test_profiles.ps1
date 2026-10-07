param([string]$Repo=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Repo 'shared\process.ps1')
$script:checks=0
function Assert { param([bool]$Condition,[string]$Message);if (-not $Condition) {throw $Message};$script:checks++ }
function Assert-Throws { param([scriptblock]$Action,[string]$Message);$thrown=$false;try {& $Action | Out-Null} catch {$thrown=$true};Assert $thrown $Message }
$root=Join-Path ([IO.Path]::GetTempPath()) ('manager-codex-tests-' + [guid]::NewGuid().ToString('N'))
$module=Join-Path $Repo 'agents\codex\scripts'
$snapshot=Get-ProcessEnvironmentSnapshot
try {
    [void][IO.Directory]::CreateDirectory($root)
    $env:LOCALAPPDATA=Join-Path $root 'Local';$env:APPDATA=Join-Path $root 'Roaming';$env:USERPROFILE=Join-Path $root 'User'
    $env:CODEX_MULTI_ACCOUNT_ROOT=Join-Path $root 'Profiles with spaces'
    $env:CODEX_HOME='fixture-main-codex';$env:CLAUDE_CONFIG_DIR='fixture-main-claude';$env:ANTHROPIC_API_KEY='fixture-cloud';$env:OPENAI_API_KEY='fixture-openai'
    $env:AI_MANAGER_FIXTURE_OUTPUT=Join-Path $root 'launch.txt'
    $env:AI_MANAGER_FIXTURE_TRACE=Join-Path $root 'trace.txt'
    $env:AI_MANAGER_FIXTURE_EXIT='0'
    $codeExe=Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'
    $codexExe=Join-Path $env:USERPROFILE '.vscode\extensions\openai.chatgpt-99.0.0-win32-x64\bin\windows-x86_64\codex.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path $codeExe -Parent))
    [void][IO.Directory]::CreateDirectory((Split-Path $codexExe -Parent))
    $cliJs=Join-Path (Split-Path $codeExe -Parent) 'resources\app\out\cli.js'
    [void][IO.Directory]::CreateDirectory((Split-Path $cliJs -Parent))
    [IO.File]::WriteAllText($cliJs,'// synthetic VS Code CLI fixture')
    $fixtureSource=Join-Path $root 'fixture.cs'
    [IO.File]::WriteAllText($fixtureSource, @'
using System;
using System.IO;
using System.Collections.Generic;
public static class ProfileFixture {
    public static int Main(string[] args) {
        var lines = new List<string>();
        foreach (var name in new [] {"CODEX_HOME", "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"})
            lines.Add(name + "=" + Environment.GetEnvironmentVariable(name));
        foreach (var arg in args) lines.Add("ARG=" + arg);
        File.WriteAllLines(Environment.GetEnvironmentVariable("AI_MANAGER_FIXTURE_OUTPUT"), lines);
        if (args.Length > 0) File.AppendAllText(Environment.GetEnvironmentVariable("AI_MANAGER_FIXTURE_TRACE"), args[0] + Environment.NewLine);
        var home = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (args.Length > 0 && args[0] == "login") {
            Directory.CreateDirectory(home);
            File.WriteAllText(Path.Combine(home, "auth.json"), "{\"auth_mode\":\"chatgpt\",\"tokens\":{}}");
        }
        if (args.Length > 0 && args[0] == "logout") File.Delete(Path.Combine(home, "auth.json"));
        return int.Parse(Environment.GetEnvironmentVariable("AI_MANAGER_FIXTURE_EXIT") ?? "0");
    }
}
'@)
    # Compile a .NET Framework console fixture even when the test host is PS 7.
    $compileScript=Join-Path $root 'compile.ps1'
    [IO.File]::WriteAllText($compileScript,'param($Source,$Target); $ErrorActionPreference="Stop"; Add-Type -Path $Source -OutputAssembly $Target -OutputType ConsoleApplication')
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $shell -NoProfile -ExecutionPolicy Bypass -File $compileScript -Source $fixtureSource -Target $codeExe
    Assert ($LASTEXITCODE -eq 0) 'Could not compile the synthetic process fixture'
    Copy-Item -LiteralPath $codeExe -Destination $codexExe
    . (Join-Path $module 'Common.ps1')
    Assert ((Find-VSCodeExecutable) -eq $codeExe -and (Find-CodexCli) -eq $codexExe) 'Module discovery selected a real executable instead of the fixture'

    $mainSettings=Join-Path $env:APPDATA 'Code\User\settings.json'
    Write-JsonFile $mainSettings ([pscustomobject]@{'editor.fontSize'=18})
    & (Join-Path $module 'New-CodexAccountProfile.ps1') -Name work -CopyVsCodeSettings
    $work=Get-CodexProfileConfig work
    Assert (Test-Path -LiteralPath $work.ConfigPath) 'Profile metadata was not saved'
    Assert ((Read-JsonFile (Join-Path $work.VSCodeUserData 'User\settings.json')).'editor.fontSize' -eq 18) 'Settings copying broke during integration'
    $stored=Read-JsonFile $work.ConfigPath
    Assert ($stored.version -eq 1 -and $stored.codexHome -eq $work.CodexHome) 'Existing profile schema changed'
    & (Join-Path $module 'New-CodexAccountProfile.ps1') -Name personal
    $personal=Get-CodexProfileConfig personal
    Assert ($work.CodexHome -ne $personal.CodexHome -and $work.VSCodeUserData -ne $personal.VSCodeUserData) 'Named profiles share state'

    & (Join-Path $module 'Login-CodexAccountProfile.ps1') -Name work -SkipSecurityPage
    $record=Get-Content -LiteralPath $env:AI_MANAGER_FIXTURE_OUTPUT
    Assert (('ARG=login' -in $record) -and ('ARG=--device-auth' -in $record) -and (('CODEX_HOME=' + $work.CodexHome) -in $record)) 'Login did not reach the selected profile'
    Assert (('ANTHROPIC_API_KEY=' -in $record) -and ('OPENAI_API_KEY=' -in $record) -and ('CLAUDE_CONFIG_DIR=' -in $record)) 'Other agent credentials leaked into Codex login'
    Assert ($env:CODEX_HOME -eq 'fixture-main-codex' -and $env:ANTHROPIC_API_KEY -eq 'fixture-cloud') 'Login changed the parent environment'
    Assert ((Get-CodexAuthSummary (Join-Path $work.CodexHome 'auth.json') work).LoggedIn) 'Synthetic account login was not recognized'
    & (Join-Path $module 'Login-CodexAccountProfile.ps1') -Name work -Force -SkipSecurityPage
    $trace=Get-Content -LiteralPath $env:AI_MANAGER_FIXTURE_TRACE
    Assert ($trace[-2] -eq 'logout' -and $trace[-1] -eq 'login') 'Account switching did not logout before login'
    Assert ((Get-CodexAuthSummary (Join-Path $work.CodexHome 'auth.json') work).LoggedIn) 'Account switching lost the profile login'

    $project=Join-Path $root 'Project with spaces'
    [void][IO.Directory]::CreateDirectory($project)
    & (Join-Path $module 'Start-VSCodeCodexProfile.ps1') -Name work -Path ($project + '\') -NoLogin
    $record=Get-Content -LiteralPath $env:AI_MANAGER_FIXTURE_OUTPUT
    Assert (('ARG=--user-data-dir' -in $record) -and (('ARG=' + $work.VSCodeUserData) -in $record)) 'VS Code user data path was not forwarded'
    Assert (('ARG=' + $project + '\') -in $record) 'Windows path quoting broke for spaces and a trailing backslash'
    Assert (('ARG=--extensions-dir' -in $record) -and (('CODEX_HOME=' + $work.CodexHome) -in $record)) 'Codex launch isolation changed'
    Assert (('CLAUDE_CONFIG_DIR=' -in $record) -and ('OPENAI_API_KEY=' -in $record)) 'Other agent configuration leaked into Codex startup'
    Assert ($env:CODEX_HOME -eq 'fixture-main-codex' -and $env:OPENAI_API_KEY -eq 'fixture-openai') 'VS Code launch changed the parent environment'

    # The public manager reaches the same module in a disposable child process.
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'start.ps1') -Agent Codex -Action Start -Name work -ProfilesRoot $env:CODEX_MULTI_ACCOUNT_ROOT -WorkspacePath $project
    Assert ($LASTEXITCODE -eq 0) 'Unified manager could not launch the selected Codex profile'
    $record=Get-Content -LiteralPath $env:AI_MANAGER_FIXTURE_OUTPUT
    Assert ((('CODEX_HOME=' + $work.CodexHome) -in $record) -and (('ARG=' + $project) -in $record)) 'Unified manager lost profile or workspace arguments'

    $env:AI_MANAGER_FIXTURE_EXIT='7'
    Assert-Throws { & (Join-Path $module 'Start-VSCodeCodexProfile.ps1') -Name work -NoLogin } 'Rejected VS Code launch was reported as successful'
    Assert ($env:CODEX_HOME -eq 'fixture-main-codex') 'Failed launch did not restore the environment'
    $env:AI_MANAGER_FIXTURE_EXIT='0'
    Assert-Throws { & (Join-Path $module 'Start-VSCodeCodexProfile.ps1') -Name personal -NoLogin } 'Signed-out profile launched without login'
    Assert-Throws { & (Join-Path $module 'New-CodexAccountProfile.ps1') -Name unsafe -CodexHome (Join-Path $env:USERPROFILE '.codex') } 'Creation accepted main Codex state'
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:CODEX_MULTI_ACCOUNT_ROOT 'unsafe'))) 'Rejected profile created files'

    $authPath=Join-Path $personal.CodexHome 'auth.json'
    [IO.File]::WriteAllText($authPath,'not json')
    Assert (-not (Get-CodexAuthSummary $authPath personal).LoggedIn) 'Unreadable credentials were treated as signed in'
    Assert-Throws { & (Join-Path $module 'Start-VSCodeCodexProfile.ps1') -Name personal -NoLogin } 'Unreadable credentials bypassed the launch check'
    Write-JsonFile $personal.ConfigPath ([pscustomobject]@{codexHome=(Join-Path $env:USERPROFILE '.codex');vscodeUserData=$personal.VSCodeUserData})
    Assert-Throws { Get-CodexProfileConfig personal } 'Stored profile redirected login to the main account'
} finally { Restore-ProcessEnvironment $snapshot }
Write-Output "PASS: $script:checks Codex profile/process integration checks (PowerShell $($PSVersionTable.PSVersion)). Fixtures: $root"
