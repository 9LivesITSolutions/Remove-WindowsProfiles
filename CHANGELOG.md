# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [3.9.0] - 2026-04-28

### Added
- `-Username` parameter: restrict removal to one or more specific account names or SIDs (wildcards accepted). Applied after all system/exclusion filters.
- `-TargetList` parameter: path to a plain-text file of hostnames (one per line, `#` comments ignored) activating multi-machine WinRM mode.
- Multi-machine orchestrator (`Invoke-MultiMachineCleanup`): parallel WinRM sessions, configurable throttle, per-machine log files, consolidated CSV report.
- `-ThrottleLimit` parameter: max simultaneous WinRM sessions (default: 10).
- `-LogPath` parameter: directory for per-machine logs and CSV report.
- `-RemoteTempPath` parameter: staging directory on remote targets.
- `-Credential` parameter: explicit PSCredential for remote sessions.
- Self-deployment: script copies itself to remote targets via `Copy-Item -ToSession` and cleans up after execution.

### Changed
- Script routes automatically between single-machine and multi-machine mode based on target count.
- `-WhatIf` implemented as a plain `[switch]` parameter replacing `SupportsShouldProcess` -- eliminates automatic propagation to child cmdlets that caused parameter binding failures on PS5.1.
- Profile deletion switched from `Invoke-CimMethod -MethodName Delete` to `Remove-CimInstance` -- `Win32_UserProfile` does not expose a `Delete` WMI method; `Remove-CimInstance` issues the correct `DeleteInstance` CIM operation.
- Remote CIM connectivity via `New-CimSession` (WSMan/WinRM) replacing direct .NET `CimSession::Create()` with `DComSessionOptions` which ignored the `ComputerName` argument on PS5.1.
- `[string[]]$ComputerName` typed explicitly with `@()` wrapping at entry point to prevent PS5.1 string-indexing coercion (`$array[0]` returning first character instead of first element).

### Fixed
- Banner displaying first character of local hostname instead of target hostname when `-ComputerName` was specified.
- `Get-CimInstance` connecting to local machine instead of remote target due to DCOM session ignoring `ComputerName`.
- `Remove-CimInstance` (formerly `Invoke-CimMethod -MethodName Delete`) failing with "method not found" -- `Win32_UserProfile` has no callable WMI methods.
- `New-CimSessionOption` throwing parameter binding error under `-WhatIf` due to `SupportsShouldProcess` propagation.

---

## [2.0.0] - 2026-04-28

### Added
- Pre-computation phase: `Build-ExcludedSIDSet()` queries `Win32_UserAccount` once before profile loop
- Built-in local accounts excluded by RID (500, 501, 503, 504) -- fully locale-independent
- `Test-IsSystemByPrefix()` safety net for virtual/service accounts without `UserAccount` entries
- `-Verbose` flag exposes SID pre-computation details
- `-Exclude` now accepts SID strings in addition to name wildcards; both split and handled before the main loop
- 3-phase execution model (pre-compute / CIM read / classify)

### Changed
- Classification loop reduced to a single `HashSet.Contains()` O(1) call per profile for system detection
- `Resolve-AccountName` called only for profiles that pass the system filter
- `Test-ExcludedByName` called only when `-Exclude` contains name patterns and profile is non-system
- Migrated from `Get-WmiObject` to `Get-CimInstance` for PS5.1 and PS7 compatibility

### Removed
- `$BUILTIN_NAMES` string list -- replaced entirely by SID/RID-based detection
- Per-iteration calls to `Get-RIDFromSID` during profile classification

---

## [1.3.0] - 2026-04-28

### Added
- `$BUILTIN_LOCAL_RIDS` HashSet with RIDs 500, 501, 503, 504 for locale-independent built-in detection
- `Get-RIDFromSID` function extracting RID from `S-1-5-21-x-x-x-RID` pattern
- `$WELLKNOWN_SID_PREFIXES` covering NT SERVICE, IIS AppPool, Hyper-V, DWM, containers
- `-Exclude` now accepts SID strings in addition to name wildcards

### Removed
- `$BUILTIN_NAMES` string array -- all name-based detection replaced by SID structure

---

## [1.2.0] - 2026-04-28

### Added
- Initial public release
- `Win32_UserProfile` WMI-based profile enumeration
- System account exclusion via SID exact match and prefix lists
- `-All` switch for non-interactive bulk removal
- `-WhatIf` dry-run support
- `-ComputerName` for remote machine targeting
- Interactive per-profile Yes/No/Quit prompt
- Summary counters (removed / failed / skipped)

---

<!-- Links -->
[Unreleased]: https://github.com/[OWNER]/windows-profile-cleanup/compare/v3.9.0...HEAD
[3.9.0]: https://github.com/[OWNER]/windows-profile-cleanup/compare/v2.0.0...v3.9.0
[2.0.0]: https://github.com/[OWNER]/windows-profile-cleanup/compare/v1.3.0...v2.0.0
[1.3.0]: https://github.com/[OWNER]/windows-profile-cleanup/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/[OWNER]/windows-profile-cleanup/releases/tag/v1.2.0
