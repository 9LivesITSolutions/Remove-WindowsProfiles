# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- (next changes go here)

---

## [2.0.0] - 2026-04-28

### Added
- Pre-computation phase: `Build-ExcludedSIDSet()` queries `Win32_UserAccount` once before profile loop
- Built-in local accounts excluded by RID (500, 501, 503, 504) — fully locale-independent
- `Test-IsSystemByPrefix()` safety net for virtual/service accounts without `UserAccount` entries
- `-Verbose` flag exposes SID pre-computation details
- `-Exclude` now accepts SID strings in addition to name wildcards; both are split and handled before the main loop
- 3-phase execution model clearly documented (pre-compute / WMI read / classify)

### Changed
- Classification loop reduced to a single `HashSet.Contains()` O(1) call per profile for system detection
- `Resolve-AccountName` called only for profiles that pass the system filter (not for every profile)
- `Test-ExcludedByName` called only when `-Exclude` contains name patterns and profile is non-system

### Removed
- `$BUILTIN_NAMES` string list — replaced entirely by SID/RID-based detection
- Per-iteration calls to `Get-RIDFromSID` during profile classification

---

## [1.3.0] - 2026-04-28

### Added
- `$BUILTIN_LOCAL_RIDS` HashSet with RIDs 500, 501, 503, 504 for locale-independent built-in detection
- `Get-RIDFromSID` function extracting RID from `S-1-5-21-x-x-x-RID` pattern
- `$WELLKNOWN_SID_PREFIXES` covering NT SERVICE, IIS AppPool, Hyper-V, DWM, containers
- `-Exclude` now accepts SID strings in addition to name wildcards

### Removed
- `$BUILTIN_NAMES` string array — all name-based detection replaced by SID structure

---

## [1.2.0] - 2026-04-28

### Added
- Initial public release
- `Win32_UserProfile` WMI-based profile enumeration
- System account exclusion via SID exact match and prefix lists
- `-All` switch for non-interactive bulk removal
- `-WhatIf` dry-run support via `SupportsShouldProcess`
- `-ComputerName` for remote machine targeting
- Interactive per-profile Yes/No/Quit prompt
- Summary counters (deleted / failed / skipped)

---

<!-- Links -->
[Unreleased]: https://github.com/[OWNER]/windows-profile-cleanup/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/[OWNER]/windows-profile-cleanup/compare/v1.3.0...v2.0.0
[1.3.0]: https://github.com/[OWNER]/windows-profile-cleanup/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/[OWNER]/windows-profile-cleanup/releases/tag/v1.2.0
