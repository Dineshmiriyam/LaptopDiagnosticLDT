# Changelog

All notable changes to the Laptop Diagnostic Toolkit are documented here.

## [10.0.0] - 2026-02-24

### Added
- **CertificationEngine.psm1** (`Core/`): Engine self-health check, KPI validation, config schema validation, security hardening status (7 exported functions)
- **AuditExportEngine.psm1** (`Core/`): Packages all compliance JSON/HTML artifacts into timestamped zip with SHA256 manifest
- **ZeroTrustEngine.psm1** (`Core/`): Script signature validation, approved files manifest, config hash verification (available for standalone use)
- **ResilienceEngine.psm1** (`Core/`): Crash-proof transaction tokens, resource governance monitoring (available for standalone use)
- **Phase 0 config schema validation** (0I): Validates config.ini structure on every diagnostic run; INVALID aborts, WARNING displays
- **Cross-session remediation registry**: `Import/Export-RemediationRegistry` in Phase 6 prevents re-applying same fix across sessions
- **Options 58-60**: Engine Health Check, Config Schema Validator, Export Audit Bundle
- **GuardEngine enhancements**: `Export-RemediationRegistry`, `Import-RemediationRegistry`, `Test-MultiModuleOverlap`
- **IntegrityEngine enhancement**: `New-ForensicArchive` with ChainHash support
- **ClassificationEngine enhancement**: `Invoke-DiagnosticClassification` with mandatory cause validation
- **FleetGovernance enhancement**: `Get-FleetKPIFields` formal KPI field definitions
- **ComplianceExport expanded to 16 artifacts**: Added KPIReport, SecurityHardening, RegressionReport, AuditManifest
- **8 new config.ini sections**: `[ZeroTrust]`, `[ResourceGovernance]`, `[ConfigSchema]`, `[SecurityHardening]`, `[ForensicIntegrity]`, `[KPIThresholds]`, `[RegressionHarness]`, `[AuditExport]`

### Changed
- Version bumped to 10.0.0 across Smart Diagnosis Engine, BAT launcher
- BAT menu expanded from 57 to 60 options
- BAT edition label changed from "Enterprise Governance Edition" to "Certification-Ready Edition"

## [9.0.0] - 2026-02-23

### Added
- **GovernanceEngine.psm1** (`Core/`): Enterprise governance control authority with 15 exported functions
  - `Initialize-PolicyEngine`: Loads Strict/Balanced/Aggressive policy profiles from config.json
  - `Get-PolicyProfile` / `Test-PolicyGate`: Policy-driven remediation gating
  - `Save-ExecutionState` / `Restore-ExecutionState` / `Clear-ExecutionState`: Crash recovery via ExecutionState.json
  - `Get-ExecutionMode` / `Test-ModeAllowsPhase`: 5 execution modes (AuditOnly/Diagnostic/Remediation/Full/ClassifyOnly)
  - `Write-GovernedException` / `Get-ExceptionSummary` / `Test-ExceptionThreshold`: Structured exception governance with severity routing
  - `Invoke-GovernedRetry`: Configurable retry with exponential backoff for transient failures
  - `Get-BusinessImpactWeight`: Category/severity/classification business impact scoring
- **FleetGovernance.psm1** (`Core/`): Fleet-wide governance controls with 6 exported functions
  - `Test-DirectoryIntegrity`: Validates LDT directory against VersionManifest.json (detects missing/unexpected files)
  - `Test-WhitelistApproval` / `Get-RemediationWhitelist`: Approved remediation whitelist enforcement
  - `Test-RollbackSimulation`: Dry-run rollback token validation (BeforeState integrity check)
  - `Export-FleetKPIs`: Aggregates L1 fix rate, score improvement, recurrence rate from TrendStore
  - `New-FleetGovernanceSummary`: Consolidated governance health snapshot
- **Option 7: Governance Audit** (AuditOnly mode): Runs Phases 0-5 + Phase 8 (scan + report only, no remediation or classification)
- **7th GuardEngine gate**: Whitelist enforcement via `Test-WhitelistApproval` in `Invoke-GuardedRemediation`
- **Crash recovery**: `ExecutionState.json` checkpoint at every phase boundary, auto-restore on interrupted sessions
- **ExceptionLog.json**: Governed exception log with severity routing (Warning/Error/Critical)
- **GovernanceReport.json**: Policy profile, execution mode, directory integrity, rollback simulation results
- **ComplianceExport expanded to 12 artifacts**: Added ExceptionLog, GovernanceReport
- **4 new config.ini sections**: `[GovernanceEngine]`, `[ExceptionGovernance]`, `[RetryPolicy]`, `[FleetGovernance]`
- **config.json governance block**: Policy profiles, execution modes, whitelist, retry policy, exception thresholds
- **`ConvertTo-GovernanceContext`** bridge function in LDT-EngineAdapter.psm1
- **Phase 0 governance initialization**: Policy engine, execution mode, crash recovery, directory tamper detection
- **Phase 6 governance integration**: Whitelist/policy gates, retry for transient fixes, exception logging
- **Phase 7 exception threshold check**: Abort if critical exception count exceeds threshold

### Changed
- Execution mode handling expanded from ClassifyOnly to 5 governance-aware modes
- GuardEngine now has 7 gates (6 original + whitelist enforcement)
- ComplianceExport description updated to "up to 12 per session"
- Version bumped to 9.0.0 across all Core modules, Smart Diagnosis Engine, and config files

## [8.5.0] - 2026-02-23

### Added
- **Invoke-GuardedRemediation** (`Core/GuardEngine.psm1`): Central remediation wrapper with 6-gate guard check, deduplication registry, BeforeState/AfterState capture, per-fix rollback tokens (GUID-based), and automatic RemediationLedger entry creation
- **RemediationLedger**: Structured per-fix audit trail with FinalStatus rules (RESOLVED/PARTIAL/UNSTABLE/ESCALATED/SKIPPED/BLOCKED), exported as `RemediationLedger.json`
- **HealthBefore/HealthAfter scoring**: Pre-remediation score captured at end of Phase 5, post-remediation at Phase 8; `Invoke-HealthDeltaScoring` computes risk reduction percentage
- **ManagementSummary.html**: Executive one-page HTML report with KPI cards, health score before/after bars, classification breakdown (L1/L2/L3), resolved issues table, pending risks table, business impact summary
- **Phase timing instrumentation**: `Start-PhaseTimer`/`Stop-PhaseTimer` on all 9 phases with Stopwatch + memory delta tracking, exported as `phase_timing.json`
- **Test-PreRemediationIntegrity** (`Core/IntegrityEngine.psm1`): Re-validates critical file hashes before Phase 6 remediation
- **Enhanced confidence formula**: 3-factor calculation (SeverityWeight x FrequencyWeight x PhaseConsistencyFactor) replaces simple weight ratio
- **Recurrence escalation**: `-TrendData` parameter on `Get-DiagnosticLevel` and `Get-ClassificationReport`; issues recurring >3 sessions escalate one classification level
- **Stress override**: Phase 7 failures mark RemediationLedger entries as UNSTABLE and set StressOverride flag for Phase 8 classification escalation
- **ConvertTo-RemediationEntry** (`Core/LDT-EngineAdapter.psm1`): Bridge function for structured ledger entry creation
- **4 new config.ini sections**: `[RemediationLedger]`, `[PhaseTiming]`, `[ManagementSummary]`, `[EnterpriseHardening]`
- **3 new config.json blocks**: `remediationLedger`, `managementSummary`, `phaseTiming` under engine
- **RiskReduction.json**: Health delta artifact with before/after scores, band changes, improvement list
- **ClassificationReport.json**: Separate file export (was only embedded in final_report.json)
- **ComplianceExport expanded to 10 artifacts**: Added RemediationLedger, RiskReduction, PhaseTiming
- **Driver baseline export**: `driver_baseline.csv` captured in Phase 0 preflight
- **Get-RollbackTokens** (`Core/GuardEngine.psm1`): Returns all rollback tokens generated in session
- **Backup verification check**: Validates backup before proceeding with remediation

### Changed
- Phase 6A direct fixes (BITS, DISM, SFC, DisplayDriver) now create RemediationLedger entries with rollback tokens
- Phase 6B suite dispatches create ledger entries for blocked, prohibited, and executed fixes
- ClassificationEngine confidence formula enhanced from simple ratio to 3-factor calculation
- Version bumped to 8.5.0 across all Core modules, Smart Diagnosis Engine, and config files

## [7.2.0] - 2026-02-23

### Added
- **ClassificationEngine.psm1** (`Core/`): Formal 3-level diagnostic classification engine with 6 exported functions
  - `Get-DiagnosticLevel`: Master classification returning L1/L2/L3/CLEAR with reasoning
  - `Invoke-DecisionTree`: 5-branch decision tree (No Power → No Windows → Fatal HW → Wear HW → Software)
  - `Get-SeverityScore`: 0-100 severity scoring with configurable weight map
  - `Get-ComponentHealth`: Maps findings to SOFTWARE/WEAR/FATAL classifications
  - `Get-ClassificationReport`: Generates mandatory structured JSON report
  - `Get-ClassificationConfig`: Reads [ClassificationEngine] thresholds from config.ini
- **Option 6: Classification Engine** (ClassifyOnly mode): Runs Phases 0-5 + Phase 8 (scan + classify), skips Phase 6/7 (no remediation)
- **HTML Triage Panel**: 3-column L1/L2/L3 visual panel in Smart Diagnosis reports with active level highlighting
- **Decision Tree Path**: Visual breadcrumb showing classification path (Power OK → Windows OK → L1 AUTO-FIXABLE)
- **L2 Component Health Cards**: Per-component cards with wear details and replacement recommendations
- **`[ClassificationEngine]` config section**: 30+ configurable thresholds for L1/L2/L3 classification
- **7th Compliance Artifact**: `ClassificationReport.json` added to ComplianceExport
- **TrendEngine escalation tracking**: `escalation_level` field added to trend entries for fleet L3 frequency analysis
- **`ConvertTo-ClassificationFindings`** bridge function in LDT-EngineAdapter.psm1
- `-Mode` parameter on Smart_Diagnosis_Engine.ps1 (supports "Full" and "ClassifyOnly")

### Changed
- Smart Diagnosis Engine Phase 6 now uses ClassificationEngine for formal L1/L2/L3 gating (with legacy fallback)
- Smart Diagnosis Engine Phase 8 displays 3-level classification summary with severity score and decision path
- JSON export includes `classification` block with full L1/L2/L3 breakdown
- config.json updated with Classification module entry
- VersionManifest.json updated with ClassificationEngine.psm1 entry
- Version bumped to 7.2.0

## [7.1.0] - 2026-02-21

### Added
- **Phase 4K: Refresh Rate Validation**: Detects anomalous refresh rates outside configurable Min/MaxRefreshRateHz range
- **Phase 4L: Brightness / Backlight Diagnostics**: WmiMonitorBrightness + ACPI control method validation, detects 0% brightness (backlight failure)
- **Phase 4M: Shell / Explorer Integrity**: Detects missing explorer.exe (black screen root cause) and custom shell (kiosk mode)
- **Phase 4N: EDID / Native Resolution**: Panel manufacturer extraction via WmiMonitorID, native vs current resolution mismatch detection
- **Phase 7 GPU Stress Test**: GDI+ bitmap stress with TDR event monitoring during load, catches driver instability
- **Display Severity Classification** in Phase 8: Level 1 (auto-fixable) / Level 2 (component) / Level 3 (technician) per v11 taxonomy
- **DisplayPixelCheck steps [8/9] and [9/9]**: Refresh rate baseline and brightness control test added to Option 39
- **[Display] config section**: 8 new thresholds for GPU stress, refresh rate, brightness, EDID validation
- `display_status` field added to JSON export

### Changed
- Smart Diagnosis Engine Phase 4 expanded from 10 checks (4A-4J) to 14 checks (4A-4N)
- DisplayPixelCheck expanded from 7 steps to 9 steps
- Version bumped to 7.1.0

## [7.0.1] - 2026-02-21

### Added
- `Tools/Test-LDTPlatform.ps1`: 7-check platform validation (parse, PS7+ scan, encoding, config drift, BAT routing, version consistency, hash verification)
- Known Limitations section in README.md (driver update gaps, domain conflicts, compliance scope)
- Lenovo Thin Installer setup instructions in README.md

### Changed
- Unified dual scoring model: HTML report and JSON export now prefer ScoringEngine weighted score when v7 engines are available
- HTML report label changed from "Enterprise Score" to "Health Score" with band indicator
- `VersionManifest.json` populated with real SHA256 hashes (14 files verified)
- Fixed 13 em-dash (U+2014) encoding issues across Laptop_Diagnostic_Suite.ps1, Fleet_Aggregator.ps1, Update-VersionManifest.ps1
- Fixed `Update-VersionManifest.ps1` strict mode compatibility and em-dash in synopsis

## [7.0.0] - 2026-02-21

### Added
- **Enterprise Engine Modules** (6 new files in `Core/`):
  - `GuardEngine.psm1`: 6-gate remediation authority with 20-item prohibition list
  - `IntegrityEngine.psm1`: SHA256 platform tamper detection + session log sealing
  - `ScoringEngine.psm1`: Weighted 0-100 health scoring across 9 categories
  - `TrendEngine.psm1`: 90-session per-machine historical tracking (TrendStore/)
  - `ComplianceExport.psm1`: ISO 27001/SOC2/CIS compliance artifact generation (6 JSONs)
  - `LDT-EngineAdapter.psm1`: Bridge module between LDT and enterprise engines
- **OEM Validation Mode** (Option 5): 8 read-only hardware checks (SecureBoot, TPM, BIOS, fingerprint, Win11 readiness, POST history, driver catalog, baseline drift)
- **Phase 6A Direct Targeted Fixes**: BITS service restart, DISM component store repair, SFC system file check, display driver 4-method update (WU, Lenovo System Update, Thin Installer, pnputil)
- **Phase 6 smart gating**: Proceeds with obvious fixable issues even when root-cause confidence is below threshold
- **Finding status "Repaired"**: Fixed items marked as Repaired with 5% score penalty (vs 50% for Fail)
- **Driver Update Escalation**: When all 4 auto-update methods fail, provides manufacturer-specific download URLs
- `Config/config.json`: Enterprise engine configuration (scoring weights, guard rules, feature flags)
- `Config/VersionManifest.json`: SHA256 integrity baseline for platform files
- `Tools/Update-VersionManifest.ps1`: Hash regeneration utility
- `README.md`, `GUARDRAILS.md`: Project documentation for GitHub
- Git repository: github.com/Dineshmiriyam/LaptopDiagnosticLDT

### Changed
- Smart Diagnosis Engine integrated with all 6 enterprise engines (graceful degradation if Core/ missing)
- Phase 0 now includes GuardEngine init, platform integrity check, log seal verification
- Phase 6 split into 6A (direct fixes) and 6B (suite dispatch) with deduplication
- Phase 8 now includes ScoringEngine, TrendEngine, ComplianceExport, log sealing
- TDR/GPU events reclassified from "Hardware" to "Driver" category (software-fixable)
- Enterprise score formula: added Repaired status at 5% penalty, Info at 0%
- BAT launcher: added Option 5 (OEM Validation), updated version to 7.0.0
- Version bumped to 7.0.0 across config.ini, BAT, and all scripts

### Fixed
- Phase 6 no longer skips when confidence is below threshold but fixable issues exist
- Phase 6 filter now includes Warnings (not just Fails) for software-fixable categories
- Em-dash encoding bug: replaced all U+2014 characters with -- in double-quoted strings (PS 5.1 parse fix)
- Driver Update Escalation finding no longer worsens enterprise score (changed to Info/weight 0)

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
- **Smart Diagnosis Engine** (Option 4): 8-phase orchestrated root cause analysis
  - Decision tree logic with conditional branching (hardware-first gating)
  - Root cause ranking with weighted findings, correlation rules, confidence %
  - 3-level escalation classification: L1 (OS Fix), L2 (Firmware), L3 (Hardware)
  - Rollback protection: System Restore + registry export + driver snapshot
  - Post-fix stress validation: CPU/memory/disk stress with baseline comparison
  - Self-contained dark-themed HTML report with executive summary
- `[SmartDiagnosis]` config section with 14 configurable thresholds

### Changed
- BAT menu accepts options 0-57 (sequential numbering)

## [6.1.0] - 2026-02-20

### Added
- **Quick Start workflows** (Options 1-3): Auto-Discover, Quick Fix by Symptom, Score This Machine
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
- BAT menu now shows QUICK START section at top (Options 1-3)
- Fleet Aggregator generates Fleet_Dashboard.html alongside CSV
- Menu prompt accepts options 0-57

## [6.0.0] - 2026-02-13

### Added
- Initial release: 45 diagnostic/repair modules across 8 categories
- Restore points before destructive operations (Options 13, 15, 17, 19, 21)
- Domain/BitLocker/vendor awareness in Get-SystemInformation
- Domain safety guards (DNS, Firewall, Boot operations)
- Structured audit logging (SIEM-compatible key=value format)
- Post-fix validation for Security Hardening and BSOD Troubleshooter
- Severity classification system (S1-S4, H1-H3)
- Cross-OEM vendor detection (Lenovo, Dell, HP)
- Team Issue Detector (Option 53): BSOD + Resets + VPN scan
- Fleet CSV Aggregator (Option 54): Merge and deduplicate fleet data
- Enterprise-grade Step-by-Step HTML Guide with 12 visual enhancements
