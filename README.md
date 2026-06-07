[![GitHub](https://img.shields.io/badge/GitHub-sosaramosalexis/ps1-toolkit-181717?logo=github)](https://github.com/sosaramosalexis/ps1-toolkit)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![PowerShell](https://img.shields.io/badge/powershell-5391FE?logo=powershell)]()
[![Platform](https://img.shields.io/badge/platform-Windows-blue)]()

# ps1-toolkit

ps1-toolkit is a Windows technician cleanup, optimization, software maintenance, and backup CLI written in PowerShell 5.1 compatible syntax.

It is designed to be practical and auditable: it scans first, defaults to dry-run mode for cleanup actions, writes logs, and avoids risky registry-cleaner behavior.

## Features

- Scan system summary, drive space, temp folder usage, startup entries, top installed apps, and restore point status.
- Clean safe temp locations, Windows Update download cache, thumbnails, DirectX shader cache, recycle bin, browser caches, and crash dumps.
- Run Windows health repairs with DISM and SFC.
- Optimize drives using the built-in `Optimize-Volume` cmdlet.
- Upgrade installed software with Winget.
- Batch uninstall Winget packages by package ID or text file.
- Back up user folders with OneDrive-aware path detection.
- Generate timestamped text and JSON reports under `reports/`.
- Optional restore point before applying changes.

## Quick Start

## Run directly from Github:
```
irm https://raw.githubusercontent.com/<user>/<repo>/main/install.ps1 | iex
```
## Download and run:
Open PowerShell as Administrator from this folder:

```powershell
.\ps1-toolkit.ps1 -Action Scan
```

Preview cleanup without deleting files:

```powershell
.\ps1-toolkit.ps1 -Action Clean -Preset Safe
```

Apply safe cleanup:

```powershell
.\ps1-toolkit.ps1 -Action Clean -Preset Safe -Apply -CreateRestorePoint
```

Run the interactive technician menu:

```powershell
.\ps1-toolkit.ps1 -Interactive
```

Launch the interactive menu as Administrator from Explorer:

```text
ps1-toolkit-admin.cmd
```

Launch without requesting Administrator rights:

```text
ps1-toolkit.cmd
```

## Actions

| Action | Description |
| --- | --- |
| `Scan` | Creates a system report without changing anything. |
| `Clean` | Cleans selected locations. Dry-run unless `-Apply` is passed. |
| `Optimize` | Optimizes supported volumes. |
| `Health` | Runs DISM restore health and SFC scan. |
| `All` | Runs scan, clean, optimize, and health tasks. |
| `WingetUpgrade` | Lists software upgrades, or upgrades all with `-Apply`. |
| `WingetInstall` | Batch installs Winget package IDs with `-Apply`. |
| `WingetUninstall` | Batch uninstalls Winget package IDs with `-Apply`. |
| `Backup` | Backs up user folders with `robocopy`. Dry-run unless `-Apply` is passed. |

Add `-Elevate` to ask Windows for Administrator rights automatically:

```powershell
.\ps1-toolkit.ps1 -Action All -Preset Standard -Apply -CreateRestorePoint -Elevate
```

## Winget Tools

ps1-toolkit includes winstall-style batch install support. [winstall.app](https://winstall.app/) is a web front-end for Winget that helps you find packages and generate install scripts. You can use it to discover package IDs, then paste those IDs into ps1-toolkit.

Preview available software upgrades:

```powershell
.\ps1-toolkit.ps1 -Action WingetUpgrade
```

Upgrade all supported software:

```powershell
.\ps1-toolkit.ps1 -Action WingetUpgrade -Apply -Elevate
```

Preview a batch install:

```powershell
.\ps1-toolkit.ps1 -Action WingetInstall -InstallPackage Google.Chrome,7zip.7zip
```

Apply a batch install:

```powershell
.\ps1-toolkit.ps1 -Action WingetInstall -InstallPackage Google.Chrome,7zip.7zip -Apply -Elevate
```

You can also keep install package IDs in a text file, one per line. Lines starting with `#` are ignored:

```powershell
.\ps1-toolkit.ps1 -Action WingetInstall -InstallList .\winget-install.txt -Apply -Elevate
```

Preview a batch uninstall:

```powershell
.\ps1-toolkit.ps1 -Action WingetUninstall -UninstallPackage Google.Chrome,7zip.7zip
```

Apply a batch uninstall:

```powershell
.\ps1-toolkit.ps1 -Action WingetUninstall -UninstallPackage Google.Chrome,7zip.7zip -Apply -Elevate
```

You can also keep package IDs in a text file, one per line. Lines starting with `#` are ignored:

```powershell
.\ps1-toolkit.ps1 -Action WingetUninstall -UninstallList .\winget-uninstall.txt -Apply -Elevate
```

By default, ps1-toolkit uses the `winget` source to avoid Microsoft Store agreement prompts during batch work. You can override it:

```powershell
.\ps1-toolkit.ps1 -Action WingetUpgrade -WingetSource msstore
```

## Backup Tools

Backup is PowerShell-only and built directly into ps1-toolkit. It uses Windows shell folder detection for Desktop, Documents, Downloads, Pictures, Music, and Videos. In `All` mode, it includes active OneDrive-known folders and the matching local folders when both exist.

Preview a OneDrive + local user backup:

```powershell
.\ps1-toolkit.ps1 -Action Backup -BackupDestination D:\CustomerBackups
```

Run a OneDrive + local user backup:

```powershell
.\ps1-toolkit.ps1 -Action Backup -BackupDestination D:\CustomerBackups -Apply
```

Preview local-only backup:

```powershell
.\ps1-toolkit.ps1 -Action Backup -BackupDestination D:\CustomerBackups -BackupMode Local
```

Back up only selected folders:

```powershell
.\ps1-toolkit.ps1 -Action Backup -BackupDestination D:\CustomerBackups -BackupFolder Desktop,Documents,Downloads -Apply
```

Each applied backup creates a timestamped folder like:

```text
D:\CustomerBackups\ps1-toolkit-backup-username-20260603-120000
```

## Presets

| Preset | Intended Use |
| --- | --- |
| `Safe` | Conservative cleanup suitable for most customer PCs. |
| `Standard` | Adds browser cache and Windows Update cache cleanup. |
| `Deep` | Adds crash dumps and more aggressive temporary cache targets. |

## Important Notes

- Run as Administrator for best results.
- `Clean` is a dry run by default. Add `-Apply` to actually remove files.
- `Health` can take a long time.
- Drive optimization uses Windows' own SSD/HDD-aware behavior.
- `Backup` is a dry run by default. Add `-Apply` to actually copy files.
- This tool intentionally does not include registry cleaning. Registry cleaners can cause hard-to-debug damage and rarely improve performance.
