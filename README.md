<p align="center">
  <strong>Laptop Diagnostic Toolkit (LDT)</strong><br>
  USB-Portable Diagnostic and Repair Automation for Windows Laptop Fleets
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-7.0.0-blue?style=flat-square" alt="Version 7.0.0">
  <img src="https://img.shields.io/badge/PowerShell-5.1-blue?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?style=flat-square&logo=windows&logoColor=white" alt="Windows 10/11">
  <img src="https://img.shields.io/badge/optimized-Lenovo%20ThinkPad-E2231A?style=flat-square" alt="Lenovo ThinkPad">
  <img src="https://img.shields.io/badge/installation-zero--install-green?style=flat-square" alt="Zero Install">
  <img src="https://img.shields.io/badge/license-proprietary-lightgrey?style=flat-square" alt="License">
</p>

---

## Overview

LDT is a USB-portable diagnostic and repair automation toolkit designed for IT technicians, field engineers, and fleet managers. It runs entirely from a USB drive with zero installation on the target machine, works fully offline, and covers 56 menu options (0--55) spanning hardware validation, OS health, driver analysis, performance benchmarking, fleet aggregation, and enterprise compliance reporting.

Optimized for Lenovo ThinkPad fleets but compatible with any Windows 10/11 laptop.

---

## Table of Contents

- [Key Features](#key-features)
- [Getting Started](#getting-started)
- [Directory Structure](#directory-structure)
- [Scripts and Entry Points](#scripts-and-entry-points)
- [Enterprise Engines (v7.0)](#enterprise-engines-v70)
- [Smart Diagnosis Engine (Option 54)](#smart-diagnosis-engine-option-54)
- [Configuration](#configuration)
- [Quick Reference](#quick-reference)
- [Built With](#built-with)
- [Contributing](#contributing)
- [License](#license)

---

## Key Features

- **56 diagnostic and repair options** across hardware, OS, drivers, performance, network, security, and fleet management
- **USB-portable** -- copy to an 8GB+ USB drive and run on any target machine
- **Zero installation** -- nothing is installed on the target laptop
- **Fully offline** -- no internet connection required at runtime
- **Config-driven** -- 200+ tunable parameters in `config.ini` for fleet-specific thresholds
- **Non-destructive by default** -- safe Tier 1 auto-fixes; Tier 2 repairs require explicit user confirmation
- **Audit trail** -- timestamped logs, HTML reports, and CSV exports for every session
- **Enterprise compliance** -- ISO 27001, SOC 2, and CIS benchmark artifact generation
- **Tamper detection** -- SHA256 integrity verification of all platform files
- **Fleet-scale** -- aggregate results across multiple machines with trend tracking

---

## Getting Started

### Prerequisites

- Windows 10 or Windows 11 (any edition)
- PowerShell 5.1 (ships with Windows -- no additional install needed)
- Administrator privileges on the target machine
- USB drive with 8GB+ free space

### Installation

There is no installation. LDT runs directly from the USB drive.

1. Copy the entire `LDT-v6.0` folder to a USB drive
2. Plug the USB drive into the target laptop
3. Right-click **`Laptop_Master_Diagnostic.bat`** and select **Run as Administrator**
4. Select an option from the menu (0--55)
5. Reports are saved to the `Reports/` folder on the USB drive

> **Note:** The folder name `LDT-v6.0` is the distribution folder. The toolkit version is 7.0.0.

---

## Directory Structure

```
LDT-v6.0/
|
|-- Laptop_Master_Diagnostic.bat        Launcher (right-click -> Run as Administrator)
|-- Laptop_Diagnostic_Suite.ps1         Core engine (45 diagnostic modules, Options 1-48)
|-- Smart_Diagnosis_Engine.ps1          Option 54: 9-phase auto-detect + auto-fix
|-- Team_Issue_Detector.ps1             Option 49: Quick triage (BSOD + Resets + VPN)
|-- Quick_Start.ps1                     Options 51-53: Overview, auto-discover, scoring
|-- Fleet_Aggregator.ps1                Option 50: Multi-machine fleet dashboard
|-- OEM_Validation.ps1                  Option 55: 8 read-only hardware validation checks
|
|-- Config/
|   |-- config.ini                      Master configuration (23 sections, 200+ parameters)
|   |-- config.json                     Enterprise engine configuration
|   +-- VersionManifest.json            SHA256 platform integrity hashes
|
|-- Core/                               Enterprise engines (v7.0)
|   |-- GuardEngine.psm1               6-gate remediation authority
|   |-- IntegrityEngine.psm1           SHA256 tamper detection + log sealing
|   |-- ScoringEngine.psm1             Weighted 0-100 health scoring
|   |-- TrendEngine.psm1               90-session historical tracking
|   |-- ComplianceExport.psm1          ISO 27001 / SOC 2 / CIS artifact generation
|   +-- LDT-EngineAdapter.psm1         Bridge between LDT and enterprise engines
|
|-- Docs/                               Documentation and guides
|   |-- fonts/                          Bebas Neue, DM Sans, JetBrains Mono (woff2)
|   |-- LDT_Step_by_Step_Guide.html    Visual step-by-step guide
|   +-- Laptop_Toolkit_v6_Team_Guide.html / .pdf
|
|-- Tools/
|   |-- Update-VersionManifest.ps1     Regenerate SHA256 integrity hashes
|   |-- LenovoThinInstaller/           Lenovo System Update utility
|   +-- VPNInstaller/                  VPN client installer
|
|-- Logs/                               Auto-generated per-session logs (gitignored)
|-- Reports/                            Auto-generated HTML reports (gitignored)
|-- Results/                            Fleet CSV exports (gitignored)
|-- Backups/                            Restore points before repairs (gitignored)
|-- TrendStore/                         Per-machine trend data (gitignored)
|-- Temp/                               Working directory, cleared between runs (gitignored)
+-- Data/                               Reference data files (gitignored)
```

---

## Scripts and Entry Points

| Script | Menu Option | Purpose |
|--------|-------------|---------|
| `Laptop_Master_Diagnostic.bat` | -- | **Launcher.** Right-click, Run as Administrator. Auto-elevates and presents the menu. |
| `Laptop_Diagnostic_Suite.ps1` | 1--48 | **Core engine.** 45 diagnostic and repair modules covering hardware, OS, drivers, performance, network, and security. |
| `Team_Issue_Detector.ps1` | 49 | **Quick triage.** Scans for BSOD events, unexpected resets, and VPN issues. Outputs terminal summary and HTML report. |
| `Fleet_Aggregator.ps1` | 50 | **Fleet dashboard.** Aggregates diagnostic results across multiple machines into a single view. |
| `Quick_Start.ps1` | 51--53 | **One-click workflows.** Option 51: Full overview. Option 52: Auto-discover issues. Option 53: Score this machine. |
| `Smart_Diagnosis_Engine.ps1` | 54 | **Smart Diagnosis.** 9-phase orchestrated root cause analysis with auto-fix and compliance reporting. |
| `OEM_Validation.ps1` | 55 | **OEM validation.** 8 read-only hardware checks (no modifications to the target system). |

---

## Enterprise Engines (v7.0)

Version 7.0 introduces six enterprise-grade engine modules in the `Core/` directory. These are PowerShell modules (`.psm1`) consumed by the Smart Diagnosis Engine and other scripts via `LDT-EngineAdapter.psm1`.

| Engine | File | Purpose |
|--------|------|---------|
| **GuardEngine** | `GuardEngine.psm1` | 6-gate remediation authority with a 20-item prohibition list. Prevents dangerous or unauthorized repairs from executing. |
| **IntegrityEngine** | `IntegrityEngine.psm1` | SHA256 platform tamper detection. Verifies all toolkit files against `VersionManifest.json`. Seals session logs against post-hoc modification. |
| **ScoringEngine** | `ScoringEngine.psm1` | Weighted 0--100 health scoring across 9 categories. Produces letter grades (A--F) with per-category breakdowns. |
| **TrendEngine** | `TrendEngine.psm1` | Stores up to 90 sessions of historical data per machine serial number. Enables trend analysis and regression detection. |
| **ComplianceExport** | `ComplianceExport.psm1` | Generates compliance artifacts aligned to ISO 27001, SOC 2, and CIS benchmarks. Produces audit-ready documentation. |
| **LDT-EngineAdapter** | `LDT-EngineAdapter.psm1` | Adapter layer that bridges the main LDT diagnostic suite with the enterprise engine modules. |

---

## Smart Diagnosis Engine (Option 54)

The Smart Diagnosis Engine is a 9-phase orchestrated diagnostic pipeline that automatically detects issues, applies targeted fixes, and produces compliance-grade reports.

| Phase | Name | Description |
|-------|------|-------------|
| 0 | **Preflight** | GuardEngine initialization, integrity check against `VersionManifest.json`, log seal verification, admin/PS validation, session GUID assignment, pre-execution backup (registry + BCD) |
| 1 | **System Snapshot** | Hardware inventory, OS activation status, firmware type (UEFI/Legacy), chassis type, pending updates |
| 2 | **Hardware Integrity** | Battery health, disk SMART, thermal sensors, memory diagnostics, WHEA error correlation |
| 3 | **Boot and OS** | BCD validation, CHKDSK dirty bit, corrupt service detection, Windows Update component health |
| 4 | **Service and Driver** | Driver age validation, service dependency analysis, TDR/display crash detection (Event 4101/4116), GPU health, display panel diagnostics |
| 5 | **Performance** | CPU/memory/disk benchmarks, network stack validation (gateway, Winsock, proxy), baseline comparison |
| 6A | **Direct Targeted Fixes** | BITS service restart, DISM component repair, SFC system file check, display driver 4-method update pipeline |
| 6B | **Suite-Level Remediation** | Delegates complex repairs to the main diagnostic suite modules with GuardEngine authorization |
| 7 | **Stress Validation** | Post-fix CPU/memory/disk stress testing with baseline comparison to confirm fixes hold under load |
| 8 | **Classification and Reporting** | Root cause ranking with confidence scoring, 3-level escalation (L1: OS Fix, L2: Firmware, L3: Hardware), health scoring, trend storage, compliance artifact generation |

---

## Configuration

### config.ini (Primary)

The `Config/config.ini` file contains 23 sections with 200+ parameters that control every diagnostic threshold, timeout, and behavior. Fleet managers can customize these values without modifying any code.

Examples of configurable parameters:
- Battery health thresholds (warning/critical percentages)
- Disk space thresholds
- CPU temperature limits
- Driver age thresholds
- Network timeout values
- Report formatting options
- Smart Diagnosis phase-specific thresholds

### config.json (Enterprise Engines)

The `Config/config.json` file configures the enterprise engine modules (GuardEngine gates, ScoringEngine weights, TrendEngine retention, ComplianceExport templates).

### VersionManifest.json (Integrity)

The `Config/VersionManifest.json` file stores SHA256 hashes of all platform files. Used by IntegrityEngine for tamper detection. Regenerate with `Tools/Update-VersionManifest.ps1` after any file changes.

---

## Quick Reference

Common scenarios and which option to use:

| Scenario | Option | Script |
|----------|--------|--------|
| First time diagnosing a laptop | **54** | Smart Diagnosis Engine -- runs full 9-phase pipeline |
| Quick health score for a machine | **53** | Quick Start -- Score This Machine |
| Laptop is blue-screening (BSOD) | **49** | Team Issue Detector -- scans BSOD events and auto-fixes |
| Laptop restarted unexpectedly | **49** | Team Issue Detector -- scans unexpected reset events |
| VPN not connecting | **49** | Team Issue Detector -- VPN configuration check |
| Need a full overview before handoff | **51** | Quick Start -- Full Overview |
| Auto-discover all issues | **52** | Quick Start -- Auto-Discover Issues |
| Aggregate fleet-wide results | **50** | Fleet Aggregator -- multi-machine dashboard |
| Validate OEM hardware (read-only) | **55** | OEM Validation -- 8 hardware checks, no modifications |
| Specific diagnostic (battery, disk, etc.) | **1--48** | Core Suite -- choose the specific module from the menu |
| Generate compliance report | **54** | Smart Diagnosis Engine -- Phase 8 produces ISO/SOC/CIS artifacts |
| Check if toolkit files were tampered with | **54** | Smart Diagnosis Engine -- Phase 0 runs integrity verification |

---

## Known Limitations

- **Display driver auto-update**: Phase 6A tries 4 methods in sequence (Windows Update COM API, Lenovo System Update, Lenovo Thin Installer, pnputil). If none of these tools are installed on the target machine or USB, the update will fail and the script escalates with a manual download URL. To maximize success, place [Lenovo Thin Installer](https://support.lenovo.com/solutions/ht037099) in `Tools/LenovoThinInstaller/` before deployment.
- **Domain-joined machines**: Driver Auto-Update (Option 35) and some Phase 6 fixes may conflict with SCCM/WSUS/Intune policies. The toolkit detects domain membership and warns before proceeding, but cannot override Group Policy restrictions.
- **Hardware diagnostics**: Some findings (e.g., swollen battery, cracked screen, physical damage) require visual inspection. The toolkit flags related symptoms (battery wear, display anomalies) but cannot replace hands-on assessment.
- **Compliance mappings**: ISO 27001, SOC 2, and CIS benchmark artifact generation is self-assessed based on the toolkit's operational scope. These artifacts have not been certified by an external auditor. They are intended as supporting evidence for compliance programs, not as standalone proof of compliance.
- **Offline driver catalog**: The toolkit ships no driver binaries. All driver updates require either an internet connection or pre-staged OEM update utilities on the USB drive.

---

## Lenovo Thin Installer Setup (Recommended)

To enable the most reliable driver update path in Phase 6A:

1. Download [Lenovo Thin Installer](https://support.lenovo.com/solutions/ht037099) from Lenovo Support
2. Place the executable in `Tools/LenovoThinInstaller/` on your USB drive
3. The Smart Diagnosis Engine will automatically detect and use it when updating display drivers

Without Thin Installer, the toolkit falls back to Windows Update and pnputil, which may not have the latest Lenovo-specific drivers.

---

## Built With

- **PowerShell 5.1** -- Core diagnostic engine and all automation scripts. Ships with Windows 10/11; no additional runtime required.
- **Batch (CMD)** -- Launcher script for administrator elevation and menu presentation.
- **HTML / CSS / JavaScript (vanilla)** -- Self-contained documentation files and diagnostic reports. No frameworks, no CDNs, no build tools.
- **Embedded fonts** -- Bebas Neue, DM Sans, JetBrains Mono (woff2) shipped locally for offline rendering.

No external dependencies. No package managers. No build step. Everything runs from the USB drive as-is.

---

## Contributing

Contributions are welcome. Before making any changes:

1. **Read [`CONTEXT.md`](CONTEXT.md)** -- the single source of truth for project architecture, design rules, and guardrails
2. **Read [`GUARDRAILS.md`](GUARDRAILS.md)** -- additional constraints on what the toolkit must never do
3. **Follow the coding standards** defined in CONTEXT.md Section 5
4. **Target PowerShell 5.1** -- do not use PowerShell 7+ syntax (no `??`, `??=`, `?.`, ternary operators, or `ForEach-Object -Parallel`)
5. **Maintain offline capability** -- no CDN links, no `fetch()` calls, no external URLs at runtime
6. **Test on real hardware** -- run the testing checklist on a physical Lenovo ThinkPad before submitting
7. **Update `CHANGELOG.md`** and version history in `CONTEXT.md` with your changes

### Architecture Rules (Non-Negotiable)

- Fully offline at runtime -- zero internet dependencies
- USB-portable -- nothing installed on the target machine
- Config-driven -- all thresholds in `config.ini`, never hardcoded
- Non-destructive by default -- Tier 1 auto-fixes are safe; Tier 2 requires user confirmation
- Audit trail -- every session produces timestamped logs and reports
- No frameworks -- vanilla PowerShell, vanilla JS/CSS, no build tools

---

## License

This project is proprietary software. All rights reserved.

See the [LICENSE](LICENSE) file for details.

---

<p align="center">
  <strong>Laptop Diagnostic Toolkit v7.0.0</strong><br>
  Built for the field. Runs from USB. Zero install. Full diagnostics.
</p>
