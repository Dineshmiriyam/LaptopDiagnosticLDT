# LDT v9.0 GUARDRAILS

**Status:** MANDATORY -- applies to ALL contributors (human and AI).
**Violation of any rule in this document is grounds for immediate revert.**

This file defines the strict, non-negotiable rules governing development,
testing, and deployment of the Laptop Diagnostic Toolkit. Every commit,
every pull request, and every AI-assisted edit must comply.

Read this file in full before making any change to the codebase.

---

## 1. PowerShell 5.1 Strict Compatibility

Target laptops run Windows 10/11 with PowerShell 5.1 pre-installed.
PowerShell 7+ is NEVER available on target machines. Code that uses
PS 7+ syntax will silently fail or throw parse errors in production.

### Prohibited Syntax

| Syntax | Name | PS Version | Required Alternative |
|--------|------|------------|---------------------|
| `$x ?? $y` | Null-coalescing operator | 7.0+ | `if ($x) { $x } else { $y }` |
| `$x ??= $y` | Null-coalescing assignment | 7.0+ | `if (-not $x) { $x = $y }` |
| `$x?.Property` | Null-conditional member access | 7.1+ | `if ($x) { $x.Property }` |
| `$x ? $a : $b` | Ternary operator | 7.0+ | `if ($x) { $a } else { $b }` |
| `ForEach-Object -Parallel` | Parallel pipeline | 7.0+ | `ForEach-Object` (sequential) or `Start-Job` |
| `command1 && command2` | Pipeline chain (AND) | 7.0+ | `command1; if ($LASTEXITCODE -eq 0) { command2 }` |
| `command1 \|\| command2` | Pipeline chain (OR) | 7.0+ | `command1; if ($LASTEXITCODE -ne 0) { command2 }` |

### Permitted Syntax (Often Mistaken as 7+ Only)

```powershell
# Statement assignment IS valid in PS 5.1:
$var = if ($condition) { "valueA" } else { "valueB" }
```

### Verification Command

After every `.ps1` change, run:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($filePath, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_.Message } }
```

---

## 2. Architecture Rules (Non-Negotiable)

These rules define the fundamental design constraints of LDT. They are not
suggestions. They are load-bearing walls. Removing any one of them
compromises the entire product.

1. **Fully offline.** Zero internet dependencies at runtime. No CDN links,
   no API calls, no telemetry, no update checks. The toolkit must function
   identically on an air-gapped network.

2. **USB-portable.** Nothing is installed on the target machine. No registry
   entries, no scheduled tasks, no services, no files written outside the
   USB drive (except logs/reports saved to the USB itself).

3. **Single entry point.** `Laptop_Master_Diagnostic.bat` is the ONLY file
   end-users touch. All options (0-57) route through this launcher. Users
   must never need to open PowerShell manually or navigate the file tree.

4. **Self-contained.** All tools, fonts, configurations, documentation,
   and dependencies ship on the USB. If it is not on the drive, it does
   not exist.

5. **Config-driven.** All diagnostic thresholds, scoring weights, tier
   classifications, and operational parameters live in `Config/config.ini`
   (diagnostics) or `Config/config.json` (engine settings). Hardcoded
   magic numbers in scripts are prohibited.

6. **Non-destructive by default.** The three-tier safety model:
   - **Tier 1 (Auto):** Safe operations that run without user interaction.
     Examples: reading event logs, checking disk health, querying WMI.
   - **Tier 2 (Guided):** Operations that modify system state. Require
     explicit Y/N confirmation before execution. Examples: restarting
     services, running SFC, clearing temp files.
   - **Tier 3 (Escalation):** Operations too dangerous for automation.
     Report-only with manual instructions. Examples: BIOS update, driver
     rollback, hardware replacement.

7. **Audit trail.** Every diagnostic run produces:
   - Timestamped log files in `Logs/`
   - HTML reports in `Reports/`
   - All output persisted on the USB drive

8. **No frameworks.** Vanilla PowerShell for all scripts. Vanilla
   JavaScript and CSS for all documentation and HTML reports. No jQuery,
   no React, no Bootstrap, no Node.js, no NuGet packages.

---

## 3. Security Rules

LDT operates on enterprise machines that may contain sensitive data,
active BitLocker encryption, domain-joined configurations, and
compliance-critical audit trails. The following actions are absolutely
prohibited in automated execution.

### Hard Prohibitions

LDT must NEVER perform any of the following actions automatically:

1. Flash or modify BIOS/UEFI firmware
2. Clear or reset the TPM (Trusted Platform Module)
3. Modify, suspend, or disable BitLocker encryption
4. Modify, reset, or delete Group Policy settings
5. Access, read, or export credential stores (Windows Credential Manager,
   browser password stores, certificate private keys)
6. Collect, store, or transmit user personal data (documents, browsing
   history, email, chat logs)
7. Run any destructive operation without first creating a System Restore
   point (where applicable)
8. Skip or bypass GuardEngine checks during Phase 6 remediation

### GuardEngine Prohibited Operations

The GuardEngine enforces a hard-stop on the following 22 operation
categories. Any attempt to execute these without explicit override
must be blocked and logged:

| # | Operation ID | Description |
|---|-------------|-------------|
| 1 | `BIOS_Flash` | Flashing or updating BIOS/UEFI firmware |
| 2 | `TPM_Clear` | Clearing TPM keys or ownership |
| 3 | `BitLocker_Reset` | Disabling, suspending, or decrypting BitLocker |
| 4 | `Group_Policy_Modify` | Modifying local or domain Group Policy objects |
| 5 | `Credential_Store_Access` | Reading from Windows Credential Manager or cert stores |
| 6 | `Disk_Format` | Formatting any disk or volume |
| 7 | `Partition_Modify` | Creating, deleting, or resizing partitions |
| 8 | `Boot_Record_Write` | Writing to MBR, GPT, or BCD store |
| 9 | `Registry_Hive_Delete` | Deleting registry hives or critical registry trees |
| 10 | `Windows_Activation` | Modifying Windows activation or license status |
| 11 | `Domain_Leave` | Removing the machine from its Active Directory domain |
| 12 | `Domain_Join` | Joining the machine to a new domain |
| 13 | `Safe_Mode_Boot` | Forcing a reboot into Safe Mode |
| 14 | `Recovery_Partition_Delete` | Deleting the Windows Recovery partition |
| 15 | `System_Drive_Wipe` | Wiping or erasing the system drive |
| 16 | `User_Profile_Delete` | Deleting user profiles or profile directories |
| 17 | `Scheduled_Task_Delete_All` | Bulk deletion of scheduled tasks |
| 18 | `Firewall_Disable_All` | Disabling all firewall profiles |
| 19 | `Windows_Defender_Disable` | Disabling Windows Defender/Microsoft Defender |
| 20 | `Audit_Log_Clear` | Clearing Windows Security, System, or Application event logs |

Any code path that could trigger a GuardEngine prohibition must include
a check against the prohibition list BEFORE execution, not after.

---

## 4. Encoding Rules

PowerShell 5.1 on Windows defaults to reading script files using the
system's active code page (typically Windows-1252). This causes silent
corruption of Unicode characters, particularly em-dashes, curly quotes,
and other extended characters.

### Mandatory Encoding Standards

1. **All `.ps1` files must be saved as UTF-8.** UTF-8 with BOM is
   preferred (PowerShell 5.1 correctly detects the BOM). UTF-8 without
   BOM is acceptable but carries risk (see below).

2. **NEVER use em-dash (U+2014) inside double-quoted strings.**
   PowerShell 5.1 reading UTF-8-without-BOM will interpret the three
   bytes of U+2014 (`E2 80 94`) as three separate Windows-1252
   characters, producing garbled output or parse errors.

   ```powershell
   # WRONG -- will break on PS 5.1 without BOM:
   $msg = "Check failed --- see details"

   # CORRECT:
   $msg = "Check failed -- see details"
   ```

3. **Em-dashes in comments or single-quoted strings** are tolerated but
   discouraged. They will not cause parse failures but may display
   incorrectly in some editors.

4. **Curly quotes (U+2018, U+2019, U+201C, U+201D)** are prohibited in
   all `.ps1` files. Use straight quotes only (`'` and `"`).

### Verification

Check for problematic characters:

```powershell
# Find em-dashes in double-quoted strings (approximate check):
Select-String -Path *.ps1 -Pattern '"\u2014"' -AllMatches
```

---

## 5. Remediation Safety Rules

Phase 6 remediation is the most dangerous phase of the diagnostic cycle.
Code in this phase modifies system state. Every remediation action must
comply with the following rules.

### Permitted Tier 1 (Auto) Remediation Actions

These operations are considered safe for automatic execution:

- **BITS service restart** -- Restarting the Background Intelligent
  Transfer Service to resolve Windows Update stalls
- **DISM repair** -- `DISM /Online /Cleanup-Image /RestoreHealth` to
  repair component store corruption
- **SFC scan** -- `sfc /scannow` to repair protected system files
- **Display driver update** via safe channels:
  - Windows Update (`Get-WindowsUpdate` or `usoclient`)
  - Lenovo System Update (command-line invocation)
  - Lenovo Thin Installer (command-line invocation)
  - `pnputil /add-driver` for INF-based driver packages

### Prohibited Auto-Update Targets

The following must NEVER be updated automatically without explicit user
confirmation (Tier 2 minimum):

- BIOS / UEFI firmware
- Embedded controller firmware
- GPU drivers (NVIDIA, AMD, Intel Arc discrete)
- Storage controller firmware

### Findings Integrity Rules

1. **Fixed findings must be marked as `Repaired` status.** Never delete
   a finding from the results after remediation. The audit trail must
   show what was found and what was done about it.

2. **Never add escalation findings with `Fail` status.** When Phase 6
   determines that an issue requires manual intervention, add it with
   `Info` status and weight `0`. This ensures the escalation note
   appears in reports without artificially worsening the diagnostic
   score.

3. **Driver update escalation.** If all four automatic driver update
   methods fail (Windows Update, Lenovo System Update, Thin Installer,
   pnputil), the remediation must provide the user with:
   - The exact driver name and version needed
   - Direct download URLs from the manufacturer
   - Step-by-step manual installation instructions
   - Never fail silently with no guidance

---

## 6. Scoring Rules

The diagnostic score is the single most visible output of LDT. Incorrect
scoring undermines trust in the entire toolkit.

### Enterprise Score Calculation

Finding status contributes to score penalty as a percentage of the
finding's assigned weight:

| Status | Penalty Factor | Example (weight=10) |
|--------|---------------|---------------------|
| `Fail` | 50% of weight | -5.0 points |
| `Warning` | 20% of weight | -2.0 points |
| `Repaired` | 5% of weight | -0.5 points |
| `Info` | 0% of weight | 0.0 points |
| `Pass` | 0% of weight | 0.0 points |

### ScoringEngine Factors

The ScoringEngine uses multiplicative factors:

| Status | Factor |
|--------|--------|
| `PASS` | 1.0 |
| `REPAIRED` | 0.85 |
| `FAILED` | 0.0 |

### Scoring Integrity Rules

1. **Phase 6 must not worsen scores.** Remediation actions in Phase 6
   must never add findings that push the score below what was calculated
   after Phases 1-5. If a remediation attempt fails, the original
   finding's status remains unchanged.

2. **Guard penalty.** If a GuardEngine hard-stop is triggered during
   remediation, a flat -10 point penalty is applied to the final score
   and logged with full justification.

3. **Score range.** Final scores must be clamped to the range 0-100.
   Negative scores are reported as 0. Scores above 100 indicate a
   calculation bug and must be investigated.

---

## 7. File Structure Rules

The LDT codebase has a specific structure that must be maintained.
Uncontrolled growth of the core engine file is the single greatest
technical debt risk.

### Core Engine Protection

1. **`Laptop_Diagnostic_Suite.ps1`** is the core engine (12,921+ lines).
   Do NOT modify this file unless absolutely necessary. Changes to this
   file require justification and thorough testing of all 58 options.

2. **New features go in separate scripts or `Core/` modules.** The core
   engine should only be modified to add routing hooks to new modules,
   never to add entire feature implementations inline.

3. **All new modules must support graceful degradation.** Check the
   `$v7EnginesAvailable` flag before calling v7+ engine functions. For
   v9 governance features, check `$v9GovernanceAvailable`. If the flag
   is `$false`, the module must fall back to previous behavior or skip
   gracefully.

### Configuration Boundaries

| What | Where | Format |
|------|-------|--------|
| Diagnostic thresholds | `Config/config.ini` | INI (33 sections) |
| Engine settings | `Config/config.json` | JSON |
| Scoring weights | `Config/config.ini` | INI |
| UI/report settings | `Config/config.json` | JSON |

Hardcoded threshold values in `.ps1` files are prohibited. If a value
controls diagnostic behavior, it belongs in a config file.

### Path Rules

All file paths in scripts must be USB-relative. Compute paths at runtime
from `$PSScriptRoot` or the launcher's working directory.

```powershell
# CORRECT:
$configPath = Join-Path $PSScriptRoot "Config\config.ini"
$toolPath   = Join-Path $PSScriptRoot "Tools\CPU-Z\cpuz.exe"

# WRONG -- hardcoded drive letters:
$configPath = "E:\LDT-v9.0\Config\config.ini"
$toolPath   = "C:\Tools\CPU-Z\cpuz.exe"
```

Never hardcode `C:\`, `D:\`, `E:\`, or any drive letter.

---

## 8. Testing Rules

No change ships without verification. "It works on my machine" is not
a testing strategy.

### Mandatory Pre-Commit Checks

1. **Parse check every modified `.ps1` file:**

   ```powershell
   $errors = $null
   [System.Management.Automation.Language.Parser]::ParseFile(
       $filePath, [ref]$null, [ref]$errors
   )
   if ($errors.Count -gt 0) {
       throw "Parse errors found in $filePath"
   }
   ```

2. **PS 7+ syntax scan.** Search all modified `.ps1` files for:
   - `??` (null-coalescing and null-coalescing assignment)
   - `?.` (null-conditional)
   - Ternary pattern: variable, `?`, value, `:`, value on same line
   - `-Parallel` parameter on `ForEach-Object`
   - `&&` and `||` used as pipeline chain operators (not inside strings)

3. **Encoding scan.** Check for em-dash (`U+2014`) inside double-quoted
   strings in all modified `.ps1` files.

4. **Option routing verification.** After any change to
   `Laptop_Master_Diagnostic.bat`, verify that all 58 options (0-57)
   still route to the correct script/function.

### Hardware Testing

- Test on real Lenovo ThinkPad hardware. The simulator does not replicate
  WMI quirks, driver behavior, BIOS interfaces, or hardware sensor
  responses.
- Minimum test matrix: ThinkPad T-series, X-series, L-series (one each).
- Verify both plugged-in and battery-only operation.

---

## 9. Git Rules

### Ignored Paths (Must Never Be Committed)

The following directories contain runtime output and must remain in
`.gitignore`:

- `Reports/` -- Generated HTML diagnostic reports
- `Logs/` -- Runtime log files
- `Backups/` -- System restore and config backups
- `Temp/` -- Temporary working files
- `TrendStore/` -- Historical trend data
- `Results/` -- Diagnostic result snapshots
- `Data/` -- Runtime data collection

### Binary File Restrictions

Never commit binaries that trigger GitHub secret scanning or exceed
reasonable size limits. Specifically:

- CPU-Z executables
- Large OEM tool packages
- Any `.exe` or `.dll` not strictly required for the repository

### Commit Message Standards

Commit messages must describe the **why**, not just the **what**.

```
# WRONG:
Updated config.ini

# CORRECT:
Raise battery health warning threshold from 40% to 50% to catch
degrading batteries before they cause field failures
```

### USB Drive Git Configuration

The USB drive requires a safe directory exception to avoid Git's
ownership security check:

```bash
git config --global --add safe.directory E:/LDT-v9.0
```

---

## 10. AI Assistant Rules

Any AI assistant (Claude, Copilot, or other) working on this codebase
must follow these rules without exception.

### Before Making Any Change

1. Read `CONTEXT.md` to understand the current project state.
2. Read `GUARDRAILS.md` (this file) to understand the constraints.
3. Identify which files will be affected.
4. Verify that the proposed change does not violate any rule in this
   document.

### During Implementation

1. **Never break offline capability.** Do not add CDN links, API calls,
   external font loads, analytics scripts, or any network dependency.
2. **Never add frameworks.** No jQuery, React, Angular, Vue, Bootstrap,
   Tailwind, Node.js, or NuGet packages.
3. **Always preserve existing content.** When modifying a file, do not
   remove or rewrite sections unrelated to the current task. Additions
   and targeted edits only.
4. **Follow the design system.** All HTML/CSS work must match the
   existing visual language (colors, fonts, spacing, component styles).

### After Implementation

1. **Update `CHANGELOG.md`** with a clear description of what changed
   and why.
2. **Run the testing checklist** (Section 8) or explicitly remind the
   user to do so.
3. **Verify parse integrity** of all modified `.ps1` files.
4. **Confirm no PS 7+ syntax** was introduced.
5. **Confirm no encoding violations** were introduced.

---

## Enforcement

These guardrails are not aspirational. They are operational requirements.

- Any commit that violates these rules must be reverted.
- Any AI-generated code that violates these rules must be rejected.
- Any contributor who repeatedly violates these rules must review this
  document before continuing work.

If a rule in this document conflicts with a feature request, the rule
wins. Update this document first (with justification and team review),
then implement the feature.

---

*Last updated: 2026-02-23*
*Applies to: LDT v9.0 and all subsequent versions*
