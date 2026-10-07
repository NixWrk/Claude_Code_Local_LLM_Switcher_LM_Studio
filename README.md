# AI Workspace Manager (Windows)

Единый проект для изолированных профилей **Claude Code** и **Codex** в VS Code. Менеджер выбирает инструмент и профиль; каждый модуль отдельно управляет входом, настройками и историей. Модуль Claude также подключает локальные модели через LM Studio, Ollama и совместимые API.

## Быстрый запуск

Запустите **`START-HERE.cmd`** и выберите инструмент:

- **Claude Code**: графический мастер локальных моделей, вход в профиль, регистрация проекта и запуск VS Code.
- **Codex**: создание именованных профилей, вход, запуск VS Code, проверка аккаунтов и смена аккаунта профиля.

Для быстрого доступа передайте `-Agent Claude` или `-Agent Codex` в `START-HERE.cmd`. Все команды запуска доступны через единый менеджер.

Требования: Windows, PowerShell 5.1+ и VS Code. Claude требует запущенный локальный сервер с подходящей моделью; Python 3.9+ нужен для его OpenAI-адаптера. Codex требует официальное расширение OpenAI/Codex и учётную запись с доступом к нему. Python также нужен для полного набора тестов.

## Команды общего менеджера

Запускайте из корня проекта; внутренние пути разрешаются относительно файлов, поэтому менеджер работает и из другой рабочей папки.

```powershell
# Общий выбор инструмента или сразу меню Codex
.\START-HERE.cmd
.\START-HERE.cmd -Agent Codex

# Claude: отдельный именованный профиль и его графический мастер
.\START-HERE.cmd -Agent Claude -Action Gui -Name local-work

# Codex: создание, вход, запуск и состояние аккаунтов
.\START-HERE.cmd -Agent Codex -Action Create -Name work -CopyVsCodeSettings -CreateDesktopShortcuts
.\START-HERE.cmd -Agent Codex -Action Login -Name work
.\START-HERE.cmd -Agent Codex -Action Start -Name work -WorkspacePath "D:\Projects\My Project"
.\START-HERE.cmd -Agent Codex -Action Status

# Явная смена аккаунта выполняет logout и новый login для выбранного профиля
.\START-HERE.cmd -Agent Codex -Action Login -Name work -Force

# Посмотреть команду без создания профилей, входа и открытия приложений
.\START-HERE.cmd -Agent Codex -Action Start -Name work -DryRun
```

Поддерживаемые действия:

| Инструмент | `-Action` | Параметры |
| --- | --- | --- |
| Claude | `Gui`, `Login` | `-Name`, необязательные `-ProfilesRoot` или `-StateRoot` |
| Claude | `Prepare`, `Start` | Те же параметры и `-WorkspacePath`; для `Start` проект обязателен |
| Claude | `ResetChats` | Выбранный профиль; удаляет его историю и локальные кеши после закрытия окон |
| Codex | `Create` | `-Name`, `-ProfilesRoot`, `-CopyVsCodeSettings`, `-CreateDesktopShortcuts` |
| Codex | `Login` | `-Name`, `-ProfilesRoot`, необязательный `-Force` |
| Codex | `Start` | `-Name`, `-ProfilesRoot`, необязательный `-WorkspacePath` |
| Codex | `Status` | Необязательный `-ProfilesRoot` |

Без `-Action` открывается меню. `-DryRun` общего менеджера возвращает выбранный скрипт и аргументы, не выполняя действие. Для диагностики моделей, подключения и просмотра целей очистки используйте собственные CLI модулей, описанные в документации ниже.

Имена профилей: 1–64 латинских буквы, цифры, точки, `_` и `-`; имена устройств Windows и завершающая точка запрещены. Профиль Claude по умолчанию — `account-b`. В окне Claude и заголовке VS Code отображается выбранный профиль.

## Существующие аккаунты и данные

Объединение кода сохраняет прежние пути и форматы конфигурации:

```text
%LOCALAPPDATA%\ClaudeLocalSwitcher\account-b\
  switcher.json
  claude\
  vscode-login\
  vscode-local\
  extensions\

%LOCALAPPDATA%\CodexAccounts\work\
  profile.json
  codex-home\
  vscode-user-data\
```

Новые Claude-профили используют `%LOCALAPPDATA%\ClaudeLocalSwitcher\<имя>`. Codex сохраняет поддержку `CODEX_MULTI_ACCOUNT_ROOT` и `-ProfilesRoot`. Для другого существующего Claude-каталога передайте `-StateRoot`.

Учётные данные и история остаются в этих каталогах. Код проекта не копирует их в репозиторий. На новом ПК создавайте профили и входите заново; зашифрованные DPAPI-токены локального сервера относятся к текущему пользователю Windows.

Код Claude находится в `agents/claude/`, Codex — в `agents/codex/scripts/`. Старые корневые обёртки и отдельная папка `codex-multi-account` удалены. Для запуска используйте общий менеджер или прямые команды модулей из документации.

После переименования папки проекта обновите Codex-ярлыки: повторите `Create` с тем же именем/корнем и `-CreateDesktopShortcuts`. Вход и история сохраняются.

## Структура и ответственность

```text
START-HERE.cmd / start.ps1       # единое меню и CLI
manager.ps1                     # выбор модуля и запуск отдельного процесса
shared/
  profiles.ps1                  # имена, корни профилей, защита основных каталогов
  json.ps1                      # JSONC и сохранение с резервной копией
  process.ps1                   # аргументы Windows и окружение процессов
  vscode.ps1                    # поиск VS Code и контролируемый запуск его CLI
agents/
  claude/                       # авторизация, GUI, модели, адаптер API, очистка истории
  codex/
    scripts/                    # именованные профили и авторизация Codex
tests/
  shared/                       # общий менеджер и изоляция окружения
  claude/                       # перенесённые регрессионные и HTTP/GUI-тесты
  codex/                        # профили, вход и запуск на тестовых процессах
docs/
  claude.md                     # подробная инструкция Claude и локальных моделей
  codex.md                      # подробная инструкция Codex
  architecture.md               # зависимости и правила дальнейшего развития
```

Общий менеджер запускает модули отдельными процессами. Они используют разные переменные авторизации (`CLAUDE_CONFIG_DIR` и `CODEX_HOME`) и собственные схемы конфигурации. Общие функции убирают наследованные параметры подключения обоих инструментов из запускаемого процесса и восстанавливают родительское окружение.

Claude сохраняет собственный каталог расширений и отдельные окна входа/локальной работы. Codex сохраняет общий каталог установленных расширений с отдельными пользовательскими данными каждого профиля. Изоляция профилей не изолирует файлы проекта: для параллельной работы используйте отдельные checkout или Git worktree.

Тип `OpenAI` в модуле Claude — протокол локального сервера и адаптер Anthropic Messages → OpenAI Chat Completions. Поддержка локальных моделей Codex в этом проекте пока не реализована.

## Проверки

```powershell
# Все PowerShell-тесты, Python-адаптер и HTTP/WinForms-интеграция
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\run_tests.ps1

# Тот же набор с PowerShell 7 для PowerShell-сценариев
pwsh -NoProfile -STA -File .\run_tests.ps1

# Без GUI и HTTP-тестов провайдеров; включает HTTP-тесты адаптера и процессы Codex
.\run_tests.ps1 -SkipGui
```

Тесты используют временные каталоги, синтетические аккаунты, HTTP-фикстуры и тестовый исполняемый файл. Они не входят в реальные аккаунты и не запускают установленный VS Code или модельные движки. Набор проверяет маршрутизацию общего менеджера, сохранение прежних путей, изоляцию/восстановление окружения, Codex-профили, ошибки запуска, модели, адаптер и взаимодействие элементов Claude GUI. Тесты разделены по модулям в `tests/claude/`, `tests/codex/` и `tests/shared/`.

Подробности: [Claude](docs/claude.md), [Codex](docs/codex.md), [архитектура](docs/architecture.md).
