# windows-profile-cleanup

> PowerShell tool for safe bulk removal of Windows user profiles with built-in SID-based exclusions.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.0.0-informational.svg)](CHANGELOG.md)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://github.com/PowerShell/PowerShell)

---

## Overview

`Remove-WindowsProfiles.ps1` removes user profiles from Windows machines using `Win32_UserProfile` WMI.  
Built-in and system accounts are always excluded based on their SID structure, never by name — making the tool fully locale-independent (works on French, English, and any other Windows language).  
Supports interactive confirmation, bulk `-All` mode, dry-run via `-WhatIf`, and remote machine targeting.

---

## Features

- **SID-based exclusion** — identifies system accounts by SID well-known values and RIDs, not by name
- **Pre-computed exclusion HashSet** — `Win32_UserAccount` queried once before profile loop; O(1) lookup per profile
- **Safety net** — secondary prefix-based detection for virtual/service accounts without `UserAccount` entries
- **Remote support** — target any machine via `-ComputerName` (requires WinRM or DCOM)
- **Flexible exclusions** — mix SID strings, name wildcards in `-Exclude`
- **WhatIf support** — full dry-run mode via PowerShell's native `-WhatIf`
- **Interactive mode** — per-profile Yes/No/Quit prompt when `-All` is not specified

---

## Requirements

| Dependency | Version |
|------------|---------|
| PowerShell | >= 5.1  |
| WMI        | Built-in (Win32_UserProfile, Win32_UserAccount) |
| Privileges | Local Administrator (or remote admin rights) |

> PowerShell 7+ (pwsh) is supported but not required.

---

## Installation

```bash
# Clone the repository
git clone https://github.com/[OWNER]/windows-profile-cleanup.git
cd windows-profile-cleanup
```

No additional dependencies. Copy `Remove-WindowsProfiles.ps1` to your target machine or run remotely.

---

## Usage

```powershell
# Dry-run — see what would be removed without touching anything
.\Remove-WindowsProfiles.ps1 -WhatIf

# Interactive mode — confirm each profile individually
.\Remove-WindowsProfiles.ps1 -Exclude "svc_*","adminlocal"

# Bulk mode — remove all non-system profiles without prompts
.\Remove-WindowsProfiles.ps1 -All -Exclude "svc_*","S-1-5-21-111-222-333-1001"

# Remote machine
.\Remove-WindowsProfiles.ps1 -All -ComputerName "WORKSTATION-01"
```

---

## Configuration

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Exclude` | `string[]` | SID strings or name wildcards to exclude (e.g. `"svc_*"`, `"S-1-5-21-...-1105"`) |
| `-All` | `switch` | Suppress per-profile confirmation — remove all candidates silently |
| `-WhatIf` | `switch` | Dry-run — simulate without deleting |
| `-ComputerName` | `string` | Remote target hostname (default: local machine) |
| `-Verbose` | `switch` | Show pre-computation details (SIDs added to exclusion set) |

---

## How It Works

Execution is split into 3 phases:

```
Phase 1 — Build-ExcludedSIDSet()
  ├── Load NT AUTHORITY well-known SIDs into HashSet
  ├── Query Win32_UserAccount (LocalAccount=True, SIDType=1)
  ├── Filter by built-in RIDs {500, 501, 503, 504} → inject into HashSet
  └── Inject explicit -Exclude SID entries

Phase 2 — Query Win32_UserProfile (single WMI call)

Phase 3 — Classify each profile
  ├── ExcludedSIDs.Contains(SID) → O(1) → skip
  ├── Test-IsSystemByPrefix()    → safety net for virtual accounts
  └── Resolve name + apply name-pattern exclusions
```

Built-in accounts (Administrator/Administrateur RID 500, Guest/Invité RID 501, DefaultAccount RID 503, WDAGUtilityAccount RID 504) are excluded regardless of their display name or system language.

---

## Project Structure

```
windows-profile-cleanup/
├── Remove-WindowsProfiles.ps1   # Main script
├── README.md
├── CHANGELOG.md
├── LICENSE
└── .gitignore
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

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
