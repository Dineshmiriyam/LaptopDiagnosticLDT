# Changelog

All notable changes to the Laptop Diagnostic Toolkit are documented here.

## [6.1.3] - 2026-02-20

### Added
- **Phase 4H: Display Adapter Health**: GPU enumeration, ConfigManagerErrorCode check, driver age validation, GPU info in snapshot
- **Phase 4I: GPU TDR/Crash Events**: Scans for Event 4101/4116 (display driver timeout recovery) and LiveKernelEvent (GPU hang)
- **Phase 4J: Display Panel Health**: Graphics Kernel errors, Video Scheduler errors (Event 129), resolution anomaly detection, internal vs external monitor enumeration, eDP cable/panel failure guidance

### Changed
- Smart Diagnosis Engine Phase 4 expanded from 7 checks (4A-4G) to 10 checks (4A-4J)
- Version bumped to 6.1.3

## [6.1.2] - 2026-02-20

### Added
- **Phase 0 Preflight**: Admin/PS verification, session GUID, pre-execution backup (SYSTEM + SOFTWARE + BCD)
- **Phase 1 enrichment**: OS activation status, firmware type (UEFI/Legacy), chassis type, pending update count
- **Phase 3 new checks**: BCD validation, CHKDSK dirty bit, corrupt service detection, WU component health
- **Phase 5 network stack**: Default gateway reachability, Winsock catalogue check, proxy misconfiguration
- **Phase 7 mdsched**: Memory diagnostic recommendation when WHEA errors detected
- **Backup expansion**: HKLM\SOFTWARE registry hive export alongside SERVICES

### Changed
- Smart Diagnosis Engine now runs 9 phases (0-8), up from 8 phases (1-8)
- Version bumped to 6.1.2

## [6.1.1] - 2026-02-20

### Added
- **Smart Diagnosis Engine** (Option 54): 8-phase orchestrated root cause analysis
  - Decision tree logic with conditional branching (hardware-first gating)
  - Root cause ranking with weighted findings, correlation rules, confidence %
  - 3-level escalation classification: L1 (OS Fix), L2 (Firmware), L3 (Hardware)
  - Rollback protection: System Restore + registry export + driver snapshot
  - Post-fix stress validation: CPU/memory/disk stress with baseline comparison
  - Self-contained dark-themed HTML report with executive summary
- `[SmartDiagnosis]` config section with 14 configurable thresholds

### Changed
- BAT menu accepts options 0-54 (was 0-53)

## [6.1.0] - 2026-02-20

### Added
- **Quick Start workflows** (Options 51-53): Auto-Discover, Quick Fix by Symptom, Score This Machine
- **Machine Health Score**: Weighted 0-100 score with letter grade (A-F) across 4 categories
- **Baseline Comparison**: JSON snapshot per device serial, delta tracking on re-scan
- **Fleet Dashboard HTML**: Self-contained dark-themed dashboard with sortable table, score distribution chart
- **Audit logging**: Write-AuditLog added to all 45+ diagnostic modules (was only in 6)
- **Post-fix validation**: Input Troubleshooter now verifies fixes
- **Domain safety**: Driver Auto-Update warns on domain-joined machines (SCCM/WSUS conflicts)
- **Config validation**: Test-ConfigIntegrity checks config.ini sections on startup
- **Quick_Start.ps1**: New standalone script for guided workflows
- **CHANGELOG.md**: This file

### Changed
- Version bumped from 6.0.0 to 6.1.0
- BAT menu now shows QUICK START section at top (Options 51-53)
- Fleet Aggregator generates Fleet_Dashboard.html alongside CSV
- Menu prompt accepts options 0-53

## [6.0.0] - 2026-02-13

### Added
- Initial release: 45 diagnostic/repair modules across 8 categories
- Restore points before destructive operations (Options 6, 8, 31, 33, 35)
- Domain/BitLocker/vendor awareness in Get-SystemInformation
- Domain safety guards (DNS, Firewall, Boot operations)
- Structured audit logging (SIEM-compatible key=value format)
- Post-fix validation for Security Hardening and BSOD Troubleshooter
- Severity classification system (S1-S4, H1-H3)
- Cross-OEM vendor detection (Lenovo, Dell, HP)
- Team Issue Detector (Option 49): BSOD + Resets + VPN scan
- Fleet CSV Aggregator (Option 50): Merge and deduplicate fleet data
- Enterprise-grade Step-by-Step HTML Guide with 12 visual enhancements
