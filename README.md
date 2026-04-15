# Claude Code Local LLM Switcher (LM Studio)

Small utility for Windows to re-bind Claude model aliases (`sonnet`, `opus`, `haiku`, `default`) to any local model in LM Studio.

## Why this exists

Claude Code sends a model name on every request. Setting only `ANTHROPIC_BASE_URL=http://localhost:1234` is not enough if LM Studio does not have a matching model identifier.

This tool lets you switch alias mapping quickly without editing config every time.

## Requirements

- LM Studio installed
- LM Studio CLI `lms` available in PATH
- LM Studio Local Server running on `http://localhost:1234`

## Run GUI

Double-click:

- `run_switcher_gui.cmd`

Or start from terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1
```

## GUI workflow

1. Click `Refresh Models`.
2. Select model in the list. The table includes model `Size (GiB)`.
3. Choose alias (`sonnet`, `opus`, `haiku`, `default`) or enable `Custom alias`.
   - For VS Code Claude Code, you can also use full ids: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`.
4. Set `Context`:
   - `0` means auto/default LM Studio behavior.
   - `32768`, `65536`, `131072` etc. force explicit context length on load.
5. Click `Bind Alias To Selected Model`.
6. Optional: click `Test /v1/messages with Alias`.
7. In Claude Code UI pick matching model label (for example `Sonnet` if you bound `sonnet`).
8. If model is already loaded and you only need a bigger context, set `Context` and click `Set Context For Loaded Alias` (the script reloads the same model with new context).

## Headless mode (CLI)

You can use the same script without opening GUI.

- Show loaded instances:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -ShowLoaded
```

- Bind alias to model key:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Alias claude-opus-4-6 -ModelKey "p6_google_gemma-4-26b-a4b@q8_0" -ContextLength 32768
```

- Bind and immediately test endpoint:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Alias claude-opus-4-6 -ModelKey "p6_google_gemma-4-26b-a4b@q8_0" -ContextLength 32768 -TestAlias
```

- Increase context for an already loaded alias (reload same model):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Alias sonnet -ContextLength 32768
```

## Notes

- Existing alias is re-bound automatically (script unloads old alias instance and loads new target model).
- `ctx=4096` in logs means the model instance was loaded with that context. Re-bind with higher `Context` to increase it.
- The script does not change Claude Code menu labels, it changes which local model LM Studio serves for alias.
- Re-binding is reversible any time: just bind alias again to another model.
- If you see `No models loaded`, bind alias to an actually loaded model first.
