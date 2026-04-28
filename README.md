# windows-profile-cleanup

> PowerShell tool for safe removal of Windows user profiles with SID-based exclusions, targeted deletion, and multi-machine WinRM support.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-3.9.0-informational.svg)](CHANGELOG.md)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-blue.svg)](https://github.com/PowerShell/PowerShell)

---

## Overview

`Remove-WindowsProfiles.ps1` removes Windows user profiles via `Win32_UserProfile` CIM. It operates in three modes:

- **Local** — runs directly on the current machine
- **Single remote** — connects to one machine via WinRM CimSession
- **Multi-machine** — parallel WinRM sessions across a list of targets, with per-machine logs and a CSV report

System and built-in accounts are always protected by SID structure, never by name — fully locale-independent across French, English, and any other Windows language.

---

## Features

- **SID-based exclusion** — system accounts identified by well-known SIDs and built-in RIDs (500/501/503/504), never by name
- **Pre-computed exclusion HashSet** — `Win32_UserAccount` queried once; O(1) lookup per profile in the classification loop
- **Targeted deletion** — `-Username` restricts removal to specific accounts or SIDs (wildcards accepted)
- **Flexible exclusions** — `-Exclude` accepts SID strings and name wildcards to protect additional accounts
- **Multi-machine** — parallel WinRM sessions with configurable throttle, per-machine log files, consolidated CSV report
- **Self-deploying** — copies itself to remote targets via `Copy-Item -ToSession`, cleans up after execution
- **WhatIf** — dry-run mode as a plain switch, no `SupportsShouldProcess` propagation side-effects
- **Interactive mode** — per-profile Yes/No/Quit prompt when `-All` is not specified
- **PS5.1 and PS7** — tested on both; uses `Get-CimInstance` and `Remove-CimInstance` throughout

---

## Requirements

| Dependency | Version |
|------------|---------|
| PowerShell | 5.1 or 7+ |
| CIM/WMI | Built-in (`Win32_UserProfile`, `Win32_UserAccount`) |
| Privileges | Local Administrator, or remote admin with WinRM access |

WinRM must be enabled on remote targets:
```powershell
# Run as admin on each target, or deploy via GPO
Enable-PSRemoting -Force
```

---

## Installation

```powershell
git clone https://github.com/[OWNER]/windows-profile-cleanup.git
cd windows-profile-cleanup
```

No external dependencies. The script is self-contained.

---

## Usage

```powershell
# Dry-run on local machine
.\Remove-WindowsProfiles.ps1 -WhatIf

# Remove a specific profile locally
.\Remove-WindowsProfiles.ps1 -Username "jdoe" -All

# Remove a specific profile on a remote machine
.\Remove-WindowsProfiles.ps1 -ComputerName "WORKSTATION-01" -Username "jdoe" -All

# Preview removal on a remote machine
.\Remove-WindowsProfiles.ps1 -ComputerName "WORKSTATION-01" -Username "jdoe" -WhatIf

# Bulk removal on remote machine, exclude service accounts
.\Remove-WindowsProfiles.ps1 -ComputerName "WORKSTATION-01" -All -Exclude "svc_*"

# Interactive mode (confirm each profile)
.\Remove-WindowsProfiles.ps1 -ComputerName "WORKSTATION-01" -Exclude "svc_*"

# Multi-machine from inline list
.\Remove-WindowsProfiles.ps1 -ComputerName "PC-001","PC-002","PC-003" -All -Exclude "svc_*"

# Multi-machine from file with credentials
.\Remove-WindowsProfiles.ps1 -TargetList ".\targets.txt" -All `
    -Exclude "svc_*" -Credential (Get-Credential) -ThrottleLimit 5
```

---

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-ComputerName` | `string[]` | Target hostname(s). One = single mode; two or more = multi-machine WinRM mode. Default: local machine. |
| `-TargetList` | `string` | Path to a text file with one hostname per line (`#` lines ignored). Activates multi-machine mode. |
| `-Username` | `string[]` | Restrict removal to specific account names or SIDs. Wildcards accepted. |
| `-Exclude` | `string[]` | Account names (wildcards) or SID strings to always skip. |
| `-All` | `switch` | Remove all candidates without per-profile confirmation. Required for unattended runs. |
| `-WhatIf` | `switch` | Simulate without deleting. Lists all candidates that would be removed. |
| `-Credential` | `PSCredential` | Explicit credentials for remote sessions (default: Kerberos pass-through). |
| `-ThrottleLimit` | `int` | Max simultaneous WinRM sessions in multi-machine mode (default: 10, max: 50). |
| `-LogPath` | `string` | Directory for per-machine logs and CSV report in multi-machine mode (default: `.\Logs`). |
| `-RemoteTempPath` | `string` | Staging directory on remote machines (default: `C:\Windows\Temp`). |
| `-Verbose` | `switch` | Show SID pre-computation details. |

---

## How It Works

```
Phase 1 -- Build-ExcludedSIDSet()  [runs once, before any profile is touched]
  |- Load NT AUTHORITY well-known SIDs into HashSet
  |- Query Win32_UserAccount (LocalAccount=True, SIDType=1)
  |- Filter by built-in RIDs {500, 501, 503, 504} -> inject real SIDs into HashSet
  '- Inject explicit -Exclude SID entries

Phase 2 -- Load Win32_UserProfile  [single CIM query]

Phase 3 -- Classify each profile
  |- ExcludedSIDs.Contains(SID)  -> O(1) -> SYSTEM, skip
  |- Test-IsSystemByPrefix()     -> safety net for NT SERVICE, IIS, Hyper-V accounts
  |- Resolve-AccountName()       -> only for non-system profiles
  |- Apply -Exclude name patterns
  |- Apply -Username filter      -> restrict candidates if specified
  '- Apply -All / interactive / -WhatIf to final candidate list
```

Built-in accounts are excluded by RID regardless of their display name: RID 500 (Administrator/Administrateur/...), 501 (Guest/Invite/...), 503 (DefaultAccount), 504 (WDAGUtilityAccount).

---

## Multi-Machine Output

In multi-machine mode, the script produces:

- **Console** — per-machine status line (Success / PartialFailure / Unreachable) with removed/failed/skipped counts
- **Log files** — `Logs\<ComputerName>_<timestamp>.log` for each machine
- **CSV report** — `Logs\report_<timestamp>.csv` with all results consolidated

---

## Project Structure

```
windows-profile-cleanup/
|-- Remove-WindowsProfiles.ps1   # Main script (local, single-remote, multi-machine)
|-- targets.txt                  # Example target list for -TargetList
|-- README.md
|-- CHANGELOG.md
|-- LICENSE
'-- .gitignore
```

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/[feature-name]`)
3. Commit your changes (`git commit -m 'feat: add [feature-name]'`)
4. Push to the branch (`git push origin feature/[feature-name]`)
5. Open a Pull Request

Please follow [Conventional Commits](https://www.conventionalcommits.org/) for commit messages.

---

## License

This project is licensed under the MIT License -- see the [LICENSE](LICENSE) file for details.
