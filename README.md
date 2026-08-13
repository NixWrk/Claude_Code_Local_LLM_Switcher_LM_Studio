# Несколько учётных записей Codex на одном Windows-ПК

Набор позволяет одновременно использовать одну ChatGPT-учётку в Codex Desktop, другую в VS Code и дополнительные учётки в отдельных окнах VS Code.

Каждому профилю назначаются собственные каталоги `CODEX_HOME` и `--user-data-dir`. Токены, история Codex и сессии VS Code не смешиваются.

## Требования

- Windows 10/11 и PowerShell 5.1+;
- установленный VS Code;
- официальное расширение Codex/OpenAI для VS Code;
- учётные записи ChatGPT с доступом к Codex.

## Самый простой способ

Запустите `START-HERE.cmd`:

1. Создайте профиль, например `work` или `personal`.
2. Войдите в нужную ChatGPT-учётку.
3. Запустите изолированный VS Code.
4. Проверьте почты и безопасные отпечатки аккаунтов.

При создании профиля можно получить два ярлыка: `VS Code Codex (<профиль>)` и `Login Codex (<профиль>)`.

## Команды PowerShell

Откройте PowerShell в этой папке.

### Создать профиль

```powershell
.\scripts\New-CodexAccountProfile.ps1 `
  -Name work `
  -CopyVsCodeSettings `
  -CreateDesktopShortcuts
```

Профиль хранится в `%LOCALAPPDATA%\CodexAccounts\work`. Секреты не помещаются в Git-репозиторий.

### Войти или сменить учётку

```powershell
.\scripts\Login-CodexAccountProfile.ps1 -Name work
.\scripts\Login-CodexAccountProfile.ps1 -Name work -Force
```

Скрипт открывает безопасность ChatGPT в приватном окне и запускает `codex login --device-auth`. Войдите в целевую учётку. Если ChatGPT просит разрешить вход по коду устройства, включите **«Авторизация с помощью кода устройства для Codex»** в `Настройки → Безопасность` и повторите ввод кода.

### Запустить VS Code

```powershell
.\scripts\Start-VSCodeCodexProfile.ps1 -Name work
.\scripts\Start-VSCodeCodexProfile.ps1 -Name work -Path D:\Git_Code\MyProject
```

### Проверить аккаунты

```powershell
.\scripts\Get-CodexAccountProfiles.ps1
```

Команда показывает почту, имя, время обновления и короткий SHA-256-отпечаток аккаунта. Токены не выводятся.

## Несколько профилей одновременно

```powershell
.\scripts\New-CodexAccountProfile.ps1 -Name account-b -CreateDesktopShortcuts
.\scripts\New-CodexAccountProfile.ps1 -Name account-c -CreateDesktopShortcuts
.\scripts\Login-CodexAccountProfile.ps1 -Name account-b
.\scripts\Login-CodexAccountProfile.ps1 -Name account-c
```

Codex Desktop может оставаться под аккаунтом A, а изолированные окна VS Code — под B и C.

## Важные правила

- Обычный VS Code использует общий `%USERPROFILE%\.codex` и обычно видит ту же учётку, что Desktop.
- Для отдельного аккаунта всегда используйте профильный ярлык.
- Не копируйте `auth.json` между ПК и не добавляйте его в Git.
- На новом ПК переносите только эту папку, затем создавайте профили и выполняйте вход заново.
- Скрипты автоматически находят актуальный Codex CLI в расширении VS Code.

## Диагностика

- **VS Code показывает основную учётку:** запущен обычный ярлык; используйте профильный.
- **Браузер подставляет не тот аккаунт:** войдите в целевую учётку в приватном окне.
- **Device authorization disabled:** разрешите код устройства в безопасности целевой ChatGPT-учётки.
- **Codex CLI не найден:** установите или обновите официальное расширение Codex/OpenAI.
- **Папка со скриптами перемещена:** повторите создание профиля с `-CreateDesktopShortcuts`, чтобы обновить ярлыки.

## Старые скрипты

`legacy-current-device` содержит исходные одноразовые скрипты первого ПК. Они имеют жёсткие пути и сохранены только как история. На новых устройствах используйте `scripts`.
