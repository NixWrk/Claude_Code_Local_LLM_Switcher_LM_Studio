# Claude Code Local Model Switcher (Windows)

Run local models with Claude Code in an isolated VS Code environment, while using your main Anthropic account in Claude Desktop.

The second **claude.ai account B** has a separate `CLAUDE_CONFIG_DIR`, VS Code user data, extensions, projects and chat history. Account login and model inference are separate: local requests use the local backend token, not account B's OAuth token. This tool does not verify your account email or create an Anthropic account.

## Supported backends

| Connector | Model catalog | Context configuration | Claude Code connection |
| --- | --- | --- | --- |
| LMStudio | Native `/api/v1/models` | Native load API | Direct `/v1/messages` |
| Ollama | `/api/tags`, excluding cloud models | Reusable derived tag with `num_ctx` | Direct `/v1/messages` |
| Anthropic | `/v1/models` | Set in the server application | Direct `/v1/messages` |
| OpenAI | `/v1/models` | Set in the server application | Local Python adapter to `/v1/chat/completions` |

Choose **Anthropic** for another runtime exposing the Anthropic Messages API, or **OpenAI** for an OpenAI-compatible local server such as a suitably configured llama.cpp/vLLM server. Compatibility depends on the actual server and model, especially tool calling. Only loopback URLs (`localhost`, `127.0.0.1`, `::1`) are accepted; there is no cloud inference fallback.

LM Studio must support its native v1 API and Anthropic Messages endpoint (0.4.1+). Ollama must expose the Anthropic-compatible endpoint. Neither connector needs a runtime CLI in `PATH`.

## Requirements

- Windows, Windows PowerShell 5.1+ (PowerShell 7 also supported).
- VS Code. The launcher installs `anthropic.claude-code` into the separate extensions directory when missing.
- A local runtime with a downloaded, instruction-following model that supports tools. Start its API server first.
- Python 3.9+ **only for the OpenAI adapter and Python tests**. Native Anthropic connections do not need Python.
- Your second claude.ai account for the separate account login workflow.

If the selected native runtime is not ready, the GUI shows its installation link and preparation instructions. The switcher does not silently install a runtime or download multi-gigabyte model weights.

## Quick start

Run `run_switcher_gui.cmd`. The Russian interface guides you through four required steps:

1. **Сервер**: choose the runtime. Install/start [Ollama](https://ollama.com/download/windows) or [LM Studio](https://lmstudio.ai/download), download a model and enable the API server. Confirm runtime readiness, then click **Проверить сервер и найти модели**. Other compatible servers require their loopback URL. Connection errors keep later steps locked.
2. **Модель**: select a model and click **Проверить и использовать модель**. Both a text response and a valid tool call must succeed before the `sonnet` mapping is saved and the account step opens. Optional context settings are collapsed and only available for native runtimes. Additional `opus`/`haiku` mappings and repeat diagnostics appear under additional parameters after the main model passes.
3. **Аккаунт B**: click **Открыть вход в аккаунт B**, sign in inside the isolated VS Code window, then return and click **Проверить вход**. The switcher checks `claude auth status --json` using the isolated extension and account directory. Confirm that the reported account is your second account B before continuing. Use a separate browser profile or check the browser account before authorizing.
4. **Проект и запуск**: select an existing separate project folder, then click **Открыть локальный VS Code**. Account identity, saved server, project overrides and model availability are checked again before launch. Confirm a real read/edit/command task while Desktop continues using account A.

Each new GUI session starts with a server check. Editing a server/model invalidates its dependent checks; asynchronous completions from an older configuration cannot unlock the workflow. Only the current page is shown. Irrelevant controls are hidden, future steps are disabled, and the footer explains the next required action. Emergency unloading remains available during a pending request.

The server token field appears only when **Сервер требует API-токен** is enabled, including after an authentication error. A local API token is separate from the Anthropic account login. Human sign-in remains manual; simultaneous account A/B operation must be confirmed on your installed extension version.

The existing command-line preparation, login and launch wrappers remain available for scripted use. They do not require completing the GUI wizard:

```powershell
.\run_prepare.cmd -Backend Ollama -WorkspacePath "J:\Local Projects\My Project"
.\run_login_account_b.cmd
.\run_local_vscode.cmd -WorkspacePath "J:\Local Projects\My Project"
```

## Isolation boundaries

By default, all switcher state is under:

```text
%LOCALAPPDATA%\ClaudeLocalSwitcher\account-b\
  switcher.json        # endpoint, bindings and registered projects
  claude\              # account B login, Claude settings, history and plugins
  vscode-login\        # account B onboarding window; no local routing
  vscode-local\        # local chat window, settings and extension state
  extensions\          # isolated extension installation
```

Every script accepts `-StateRoot <absolute-or-relative-path>` for a portable/test environment. Use the same root for setup, login, switcher and launcher. Main `.claude` and VS Code state directories are rejected as roots.

- Setup never rewrites `%USERPROFILE%\.claude\settings.json` or `%APPDATA%\Code\User\settings.json`.
- Login and local windows use the same isolated Claude account directory and different VS Code state directories. Login inherits no local provider token or endpoint.
- Local launch removes inherited Anthropic/cloud provider variables from its child environment and sets explicit local models for all three families and subagents. The parent environment is restored afterwards.
- Custom backend tokens in `switcher.json` use Windows DPAPI for the current Windows user. Generated isolated VS Code settings contain the local backend token needed by the extension; protect that state directory. No prompts or tokens are logged by the adapter.
- Projects must be registered. Conflicting routing/model settings in `.claude/settings*.json` and `.vscode/settings.json` stop the launcher with an actionable error.
- Accounts/configuration directories do **not** isolate project files or sandbox model commands. For parallel work on the same repository use separate checkouts or Git worktrees. The project picker records explicit paths; it is not a filesystem access-control boundary.
- Machine/organization-managed Claude settings may apply to both environments. Check Claude `/status` and effective routing on managed devices.
- This multiple-account workflow is for claude.ai accounts. Claude Console sign-ins without API keys have different credential storage and are not covered by this isolation guarantee.

See [Anthropic's multiple-account documentation](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts) and [VS Code extension environment settings](https://code.claude.com/docs/en/vs-code#extension-settings).

## Models, context and sorting

**Проверить сервер и найти модели** and **Обновить список** request the catalog from the selected running server at the configured URL. They do not search all disks or search online model repositories:

- LM Studio: `GET /api/v1/models`, including downloaded models that are not currently loaded. Embedding models are excluded from the selector.
- Ollama: `GET /api/tags`, listing installed model tags. Cloud aliases/remote models exposed by Ollama are excluded.
- Other Anthropic/OpenAI-compatible servers: `GET /v1/models`. Whether this includes unloaded models depends on that server.

Model folders and imports are managed by the runtime itself. Download/import a model in that application, then refresh here. The **Filter** field searches the already fetched model key/name/publisher; it makes no new network requests. The list remains unchanged until the next refresh. Missing size metadata is shown as `Unknown` and sorted last.

- `sonnet`, `opus` and `haiku` map through `ANTHROPIC_DEFAULT_*_MODEL`. No bundled `cli.js` parsing, fake canonical Claude IDs, or duplicate short/canonical loading.
- `sonnet` is required before local launch. Unconfigured Opus/Haiku/helper models use that local model rather than a built-in Claude model.
- **Largest disk size first** is the default order. The first click on Size or Parameters selects descending order; subsequent clicks toggle. Other columns start ascending. Filtering and sorting use the cached catalog without invoking the server on each keystroke.
- Size compares numeric bytes, not formatted strings. Parameter sorting understands K/M/B/T. Unknown sizes/counts remain last in either direction. File size and parameter count are different measures; choose the relevant column.
- A binding is committed only after loading/configuring the model and validating a response. The guided GUI additionally requires a valid tool call before saving. Failed loading or validation leaves the saved mapping unchanged. Existing models are not proactively unloaded: enough memory is needed to load another model, or unload an unused model in the runtime yourself.
- Context `0` uses the server default. For Ollama, an explicit context creates a reusable `local-switcher-ctx-<hash>:latest` variant and preserves the original tag. LM Studio's actual load context is recorded when available.
- Generic servers control their context themselves; the GUI hides context controls for them and the CLI rejects unsupported changes.
- Known contexts are passed as a conservative client context limit. Claude Code's exact compaction behavior depends on its version/model recognition; verify `/context` against your runtime. Prefer a sufficient explicit context for coding workloads.
- Start a new local Claude session/window after changing bindings. Close existing local VS Code windows before changing provider or credentials; running chats keep their startup configuration.

### Unload all models, including an unresponsive engine

**Unload all models** stays available while catalog refresh, binding or a model request is busy. It runs in a separate worker and cancels the pending operation. The action affects the **selected server**, not every AI application on the computer.

For Ollama and LM Studio it first attempts normal unload with two-second request timeouts and a short overall budget. If this fails, or a generic API has no unload endpoint, it finds the process listening on the selected local port, rechecks its executable and creation time, and terminates that process tree. Known Ollama/LM Studio launchers are included to prevent automatic respawn; protected processes such as Claude Desktop, VS Code, browsers and Windows services are refused.

After an emergency stop, start the runtime again. Bindings and model files are retained. Windows permissions or a kernel/driver hang can prevent termination; the UI reports that failure rather than claiming memory was freed.

```powershell
# Graceful unload, automatically falling back to emergency stop
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -UnloadAll

# Skip the API when an engine is already known to be hung
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -ForceUnload
```

## OpenAI adapter limitations

The adapter is an optional compatibility layer, not complete Anthropic API emulation. It supports text, base64 images when the upstream model supports them, tool calls/results, multi-turn history and SSE text/tool deltas. It uses a random loopback port and a separate local client token. It forwards only the configured backend credential and allows only model IDs saved in the isolated bindings.

Hosted/deferred tools, document blocks, exact `/v1/messages/count_tokens`, and full Anthropic reasoning semantics are not implemented. Unsupported inputs return explicit errors; the token-count endpoint returns HTTP 501 rather than invented counts. Claude Code feature compatibility must be checked with a real model. Prefer the native Anthropic connector where available.

The adapter reads the saved mapping on requests and rejects a provider-type change. The launcher stays running with VS Code `--wait` and stops its adapter when the window closes or launch fails. Keep the launcher alive for that session.

## CLI examples

```powershell
# Show Ollama catalog, largest first
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Backend Ollama -ListModels

# Bind an installed Ollama model, preserving its original tag
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Backend Ollama -Alias sonnet -ModelKey "your-installed-model:latest" -ContextLength 32768 -TestAlias

# Configure another local server (URL ending in /v1 is normalized)
.\run_prepare.cmd -Backend OpenAI -BaseUrl "http://localhost:8080/v1"

# Bind a generic server model by its catalog ID
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Alias sonnet -ModelKey "your-model-id"

# Validate tool calling on the saved binding
powershell -NoProfile -ExecutionPolicy Bypass -File .\lmstudio_alias_switcher_gui.ps1 -Headless -Alias sonnet -TestTools

# Inspect setup or account B launch without writing state/opening windows
.\run_prepare.cmd -Backend Ollama -DryRun
.\run_login_account_b.cmd -DryRun

# Inspect chat reset targets; close both account B windows before an actual reset
.\run_reset_local_chats.cmd -DryRun
```

Use `-BaseUrl` and optional `-AuthToken` together with `-Backend`. Tokens can also be entered in the password field in the GUI. Errors return exit code 1, including failed endpoint tests. The old `-DisableClaudeAliasSync` flag is accepted for compatibility but is unnecessary: canonical alias syncing was removed. Custom family aliases were removed; bind a backend model ID to one of the three supported Claude families.

The **Токен локального сервера** field is the API credential of the **local server**. For local Ollama or LM Studio with authentication disabled, leave **Сервер требует API-токен** unchecked; the token field stays hidden. If LM Studio's **Require Authentication** is enabled, enable that option and use a token created in its server settings. Generic servers need a token only if they require authentication. Anthropic account B uses step 3 separately. With the option enabled, a blank field preserves an already configured token for the same normalized endpoint. Unchecking the option removes the backend credential when a successful connection is saved.

`run_reset_local_chats.cmd` clears account B's local Claude histories and local VS Code caches (including isolated extension UI state). It preserves the account B login, model mappings and registered project paths. It refuses a running account B VS Code instance, targets outside its state root, junctions and symlinks. Account logout is performed in the dedicated account B login window; it is not part of chat reset.

## Files and validation

| File | Purpose |
| --- | --- |
| `local_switcher_core.ps1` | Isolated state, JSONC, providers, mappings, sorting, process environment |
| `runtime_control.ps1` | Bounded model unloading and verified emergency process termination |
| `lmstudio_alias_switcher_gui.ps1` | Entry point and headless CLI |
| `local_switcher_gui.ps1` | Guided WinForms UI; network work runs off the UI thread |
| `gui_workflow.ps1` | Prerequisite policy and isolated account status checks |
| `prepare_windows.ps1` | Isolated setup and runtime diagnostics |
| `launch_claude_local_vscode.ps1` | Account B login/local launch and optional adapter lifecycle |
| `openai_bridge.py` | Dependency-free local API translation |

Run regression tests without installing a runtime, logging in or changing main account settings:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_core.ps1
pwsh -NoProfile -File .\tests\test_core.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_runtime_control.ps1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\test_gui_workflow.ps1
pwsh -NoProfile -STA -File .\tests\test_gui_workflow.ps1
python -m unittest discover -s tests -p "test_*.py" -v
```

Tests cover numeric sorting/click direction, JSONC, argv escaping, isolated settings/environment, DPAPI, provider context calls, failed binding preservation, CLI exit codes, real HTTP fixture connections for all four providers, and adapter SSE/tool conversion. Workflow tests inspect actual WinForms controls, conditional visibility, prerequisite gating, account-directory checks, busy-state emergency access, and asynchronous model/tool success and failure. HTTP fixtures are **not** real model execution or proof of simultaneous account A/B login.

A separate real-runtime smoke check used portable Ollama 0.35.1 and `qwen3:0.6b`: catalog/binding, a 32768-token context variant, text response, tool probe, SSE, and an actual bundled Claude Code CLI request reached the local model. The tiny model did not reliably follow the CLI instruction, so this verifies connectivity, not coding quality. Health probes disable thinking to avoid mistaking reasoning-only budget exhaustion for a broken endpoint.

Normal unloading returned an empty `/api/ps`. Suspending the actual temporary Ollama server made its API unresponsive; automatic emergency stop terminated it and its model runner in 8.17 seconds, leaving no listening port or temporary engine processes. The portable runtime, model weights, generated variants and temporary profile were then deleted.

The same real check was repeated with LM Studio's official headless daemon **llmster 0.0.25+1**, bundled `lms` CLI commit `69d945a`, and LM Studio community **Qwen3-0.6B-Q4_K_M.gguf** (484,219,808 bytes). Native catalog/loading, the actual 32768-token context, text, tool calling and SSE passed. The bundled Claude Code CLI returned the expected `OK.` through the local LM Studio Messages API. Normal unloading left zero loaded instances; suspending `llmster.exe` and using automatic emergency stop terminated it and its children in 8.73 seconds. This checks the actual LM Studio engine/API, not interaction with its desktop GUI. Temporary runtime, bundled assets, model and profile were removed afterwards.

Official backend references: [LM Studio + Claude Code](https://lmstudio.ai/docs/integrations/claude-code), [LM Studio model API](https://lmstudio.ai/docs/developer/rest/list), [Ollama Anthropic compatibility](https://docs.ollama.com/api/anthropic-compatibility), [Ollama context variants](https://docs.ollama.com/api/create).
