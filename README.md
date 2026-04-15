# Claude Code Local LLM Switcher (Windows + LM Studio)

GUI/CLI utility for Windows that helps map Claude Code aliases (`sonnet`, `opus`, `haiku`) to local LM Studio models and control model context size.

## What problem it solves

Claude Code sends a model name in each request.  
Pointing to `ANTHROPIC_BASE_URL=http://localhost:1234` is not enough unless LM Studio has a loaded model with a matching identifier.

This project gives you:

- one-click alias binding in GUI;
- context update for already loaded aliases;
- quick local endpoint test (`/v1/messages`);
- first-run setup script for new Windows machines.

## Requirements

- Windows (PowerShell 5.1+)
- LM Studio installed
- LM Studio CLI `lms` available in `PATH`
- LM Studio Local Server enabled (default: `http://localhost:1234`)
- VS Code + Claude Code extension (recommended usage path)

## Repository files

- `run_prepare.cmd` / `prepare_windows.ps1`
  - one-time machine setup (Claude + VS Code config)
- `run_switcher_gui.cmd` / `lmstudio_alias_switcher_gui.ps1`
  - main alias switcher GUI

## Quick start (new Windows PC)

1. Clone/copy this repository.
2. Start LM Studio and enable Local Server.
3. Run:
   - `run_prepare.cmd`
4. Open VS Code and reload window (`Developer: Reload Window`).
5. Run:
   - `run_switcher_gui.cmd`
6. Bind local model to `sonnet` (or `opus`/`haiku`) and test.

## What `prepare_windows.ps1` configures

- `~/.claude/settings.json`
  - `ANTHROPIC_BASE_URL`
  - `ANTHROPIC_AUTH_TOKEN`
  - `CLAUDE_CODE_ATTRIBUTION_HEADER=0`
- VS Code user `settings.json`
  - `claudeCode.environmentVariables`
  - `claudeCode.disableLoginPrompt=true`
- Endpoint health check: `GET /v1/models`

## GUI usage

1. Click `Refresh Models`.
2. Select a model in the table (`Model Key`, `Display Name`, `Publisher`, `Size (GiB)`, `Params`, `Arch`).
3. Select alias:
   - default dropdown: `sonnet`, `opus`, `haiku`
   - or enable `Custom alias` for custom names (for example `claude-opus-4-6`)
4. Set `Context`:
   - `0` = auto
   - `>0` = explicit `n_ctx` on load (for example `32768`)
5. Click `Bind Alias To Selected Model`.
6. Optional: click `Test /v1/messages with Alias`.

Extra GUI features:

- `Set Context For Loaded Alias`
  - reloads currently loaded alias with a new context
- `Show Loaded Models`
  - prints loaded model instances and context
- top status panel
  - shows what is currently loaded for `sonnet`/`opus`/`haiku`
- table sorting
  - click any column header to sort
  - repeated click toggles ascending/descending (Explorer-style)

## Headless mode (CLI)

Show loaded aliases:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -ShowLoaded
```

Bind alias to model:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Alias sonnet -ModelKey "p6_google_gemma-4-e4b@q6_k" -ContextLength 32768
```

Bind and test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Alias sonnet -ModelKey "p6_google_gemma-4-e4b@q6_k" -ContextLength 32768 -TestAlias
```

Update context for already loaded alias:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Alias sonnet -ContextLength 32768
```

## Operational notes

- Rebinding is reversible: just bind the same alias to another model.
- If responses are slow, first check `ctx` and loaded model size.
- If you see `No models loaded`, load/bind alias before sending requests from Claude Code.
- This tool changes LM Studio alias mapping; it does not rename Claude Code UI labels.
