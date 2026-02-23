#Requires -Version 5.1
<#
.SYNOPSIS
    LDT ClassificationEngine -- 3-Level Diagnostic Classification Engine

.DESCRIPTION
    Formal implementation of the LDT 3-level escalation framework:
      Level 1 (L1) -- AUTO-FIXABLE: Software-layer issues that can be remediated automatically.
      Level 2 (L2) -- REPLACEABLE COMPONENT: Wear-layer hardware requiring part replacement.
      Level 3 (L3) -- TECHNICIAN REQUIRED: Critical hardware faults, no auto-fix possible.

    Provides:
      - 5-branch decision tree (No Power -> No Windows -> Fatal HW -> Wear HW -> Software)
      - 0-100 severity scoring with configurable thresholds
      - Component health classification (software / wear / fatal)
      - Structured classification report (mandatory JSON schema)
      - Config-driven thresholds from [ClassificationEngine] in config.ini

    Designed for reuse across all LDT scripts:
      - Smart_Diagnosis_Engine.ps1 (Phase 6 gate + Phase 8 classification)
      - Team_Issue_Detector.ps1
      - Quick_Start.ps1
      - Fleet_Aggregator.ps1

.NOTES
    Version : 8.5.0
    Platform: PowerShell 5.1+
    Config  : Config\config.ini [ClassificationEngine] section
#>

Set-StrictMode -Version Latest

# ─────────────────────────────────────────────────────────────────────────────
# Module-level defaults (overridden by config.ini at runtime)
# ─────────────────────────────────────────────────────────────────────────────

$script:_DefaultConfig = @{
    SeverityCritical                    = 90
    SeverityHigh                        = 65
    SeverityMedium                      = 40
    SeverityLow                         = 20
    L3_WHEAUncorrectable                = 1
    L3_StorageControllerFault           = 1
    L3_BIOSCorruption                   = 1
    L3_TPMNotDetected                   = 1
    L3_SMARTFailure                     = 1
    L3_PostFailure                      = 1
    L2_BatteryWearPercent               = 40
    L2_BatteryWearCriticalPercent       = 60
    L2_SSDWearPercent                   = 70
    L2_NVMeWearPercent                  = 80
    L2_NVMeWearCriticalPercent          = 90
    L2_RAMErrorCount                    = 1
    L2_CMOSClockDriftSec                = 120
    L2_DisplayDeadPixels                = 3
    L2_PowerOnHoursWarnDays             = 1825
    L1_AutoFixCategories                = 'OS/Boot,Driver,Security,Network,Performance,Storage'
    L1_MaxAutoFixAttempts               = 3
    L1_RequireConfidenceForFix          = 60
    EscalateL2ToL3_UncorrectableMemory  = 1
    EscalateL2ToL3_StorageControllerFail = 1
    EscalateL2ToL3_FirmwareCorruption   = 1
    EscalateL2ToL3_TPMHardwareFail      = 1
    IncludeDecisionTreePath             = 1
    IncludeComponentHealthCards         = 1
}

# ─────────────────────────────────────────────────────────────────────────────
# SEVERITY WEIGHT MAP -- Maps component patterns to severity scores (0-100)
# Priority order: Hardware > Firmware > OS Corruption > Drivers > Performance
# ─────────────────────────────────────────────────────────────────────────────

$script:_SeverityWeightMap = @(
    @{ Pattern = 'WHEA.*Uncorrectable|Memory Error.*Uncorrectable'; Score = 100; Category = 'Fatal Hardware' }
    @{ Pattern = 'SMART.*Fail|SMART.*Critical|Storage Controller'; Score = 95;  Category = 'Fatal Hardware' }
    @{ Pattern = 'BIOS.*Corrupt|Firmware.*Corrupt|POST.*Fail';     Score = 90;  Category = 'Fatal Hardware' }
    @{ Pattern = 'TPM.*Not Detected|TPM.*Hardware.*Fail';          Score = 88;  Category = 'Fatal Hardware' }
    @{ Pattern = 'NVMe.*Wear.*9[0-9]|NVMe.*Wear.*100';            Score = 85;  Category = 'Wear Component' }
    @{ Pattern = 'Battery.*Wear.*[6-9][0-9]|Battery.*Wear.*100';   Score = 75;  Category = 'Wear Component' }
    @{ Pattern = 'DISM.*Fail|Component Store.*Corrupt';            Score = 70;  Category = 'OS Corruption' }
    @{ Pattern = 'BSOD.*Driver|Faulting Driver';                   Score = 65;  Category = 'Driver Issue' }
    @{ Pattern = 'SSD.*Wear|HDD.*Wear|SMART.*Warning';            Score = 60;  Category = 'Wear Component' }
    @{ Pattern = 'Defender.*Disabled.*Firewall.*Disabled';         Score = 55;  Category = 'Security' }
    @{ Pattern = 'CMOS.*Fail|RTC.*Fail';                           Score = 55;  Category = 'Wear Component' }
    @{ Pattern = 'Battery.*Wear.*[4-5][0-9]';                     Score = 50;  Category = 'Wear Component' }
    @{ Pattern = 'SFC.*Fail';                                      Score = 50;  Category = 'OS Corruption' }
    @{ Pattern = 'RAM.*Correctable|Memory.*Warning|WHEA.*Correct'; Score = 48;  Category = 'Wear Component' }
    @{ Pattern = 'Fan.*Not Spinning|Fan.*Fail';                    Score = 45;  Category = 'Wear Component' }
    @{ Pattern = 'Startup.*Overload|Startup.*Bloat';               Score = 40;  Category = 'Performance' }
    @{ Pattern = 'Windows Update.*Fail|WU.*Fail';                  Score = 35;  Category = 'OS Corruption' }
    @{ Pattern = 'Defender|Firewall|UAC|SmartScreen';              Score = 30;  Category = 'Security' }
    @{ Pattern = 'DNS|Winsock|Network.*Reset';                     Score = 25;  Category = 'Network' }
    @{ Pattern = 'Driver.*Outdated|Driver.*Old';                   Score = 20;  Category = 'Driver Issue' }
)

#region -- Public Functions

# ─────────────────────────────────────────────────────────────────────────────
# Get-ClassificationConfig -- Read [ClassificationEngine] from config.ini
# ─────────────────────────────────────────────────────────────────────────────

function Get-ClassificationConfig {
    <#
    .SYNOPSIS
        Reads the [ClassificationEngine] section from config.ini.
        Falls back to module defaults if section or keys are missing.

    .PARAMETER ConfigPath
        Path to the Config directory containing config.ini.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $config = @{}
    foreach ($key in $script:_DefaultConfig.Keys) {
        $config[$key] = $script:_DefaultConfig[$key]
    }

    $iniPath = Join-Path $ConfigPath 'config.ini'
    if (-not (Test-Path $iniPath)) {
        return $config
    }

    $inSection = $false
    $lines = Get-Content $iniPath -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '[ClassificationEngine]') {
            $inSection = $true
            continue
        }
        if ($trimmed -match '^\[' -and $inSection) {
            break
        }
        if ($inSection -and $trimmed -and -not $trimmed.StartsWith(';')) {
            $parts = $trimmed -split '=', 2
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $val = $parts[1].Trim()
                if ($config.ContainsKey($key)) {
                    # Convert numeric values
                    $numVal = 0
                    if ([int]::TryParse($val, [ref]$numVal)) {
                        $config[$key] = $numVal
                    }
                    else {
                        $config[$key] = $val
                    }
                }
            }
        }
    }

    return $config
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-ComponentHealth -- Classify a finding as software / wear / fatal
# ─────────────────────────────────────────────────────────────────────────────

function Get-ComponentHealth {
    <#
    .SYNOPSIS
        Maps a single diagnostic finding to a health classification:
          - 'SOFTWARE'  : Software-layer, auto-fixable (L1 eligible)
          - 'WEAR'      : Hardware wear, replaceable component (L2)
          - 'FATAL'     : Critical hardware fault (L3)
          - 'PASS'      : No issue

    .PARAMETER Finding
        A single finding object from DiagState.Findings.

    .PARAMETER Config
        Hashtable from Get-ClassificationConfig.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Finding,
        [hashtable]$Config = @{}
    )

    $component = if ($Finding.Component) { $Finding.Component } else { '' }
    $status    = if ($Finding.Status) { $Finding.Status } else { 'Pass' }
    $severity  = if ($Finding.Severity) { $Finding.Severity } else { 'S1' }
    $details   = if ($Finding.Details) { $Finding.Details } else { '' }

    # Pass findings need no classification
    if ($status -eq 'Pass' -or $status -eq 'Info') {
        return @{
            Classification = 'PASS'
            Component      = $component
            Reason         = 'No issue detected'
            ReplacementRecommendation = $null
        }
    }

    # === FATAL HARDWARE (L3 triggers) ===

    # WHEA Uncorrectable
    if ($component -match 'WHEA.*Uncorrectable|Memory Error.*Uncorrectable' -and $status -eq 'Fail') {
        return @{
            Classification = 'FATAL'
            Component      = $component
            Reason         = 'Uncorrectable memory error -- DIMM replacement or board-level fault'
            ReplacementRecommendation = 'Replace DIMM module or escalate for board diagnosis'
        }
    }

    # Storage controller / SMART failure
    if ($component -match 'Storage Controller|SMART.*Critical' -and $status -eq 'Fail') {
        return @{
            Classification = 'FATAL'
            Component      = $component
            Reason         = 'Storage controller failure or SMART critical -- drive unrecoverable'
            ReplacementRecommendation = 'Replace SSD/HDD immediately -- data at risk'
        }
    }

    # BIOS / Firmware corruption
    if ($component -match 'BIOS.*Corrupt|Firmware.*Corrupt' -and $status -eq 'Fail') {
        return @{
            Classification = 'FATAL'
            Component      = $component
            Reason         = 'BIOS/firmware corruption -- external programmer may be required'
            ReplacementRecommendation = 'Escalate to board-level technician for BIOS recovery'
        }
    }

    # TPM hardware not detected
    if ($component -match 'TPM.*Not Detected|TPM.*Hardware.*Fail' -and $status -eq 'Fail') {
        return @{
            Classification = 'FATAL'
            Component      = $component
            Reason         = 'TPM hardware absent or failed on TPM 2.0 required machine'
            ReplacementRecommendation = 'Board replacement required if TPM is soldered'
        }
    }

    # POST / No boot
    if ($component -match 'POST|No Power|Dead Board|Power Short' -and $status -eq 'Fail') {
        return @{
            Classification = 'FATAL'
            Component      = $component
            Reason         = 'POST failure -- dead board or power rail short'
            ReplacementRecommendation = 'Board-level diagnosis required'
        }
    }

    # H3 severity code = always fatal
    if ($severity -eq 'H3' -and $status -eq 'Fail') {
        return @{
            Classification = 'FATAL'
            Component      = $component
            Reason         = "Critical hardware fault: $details"
            ReplacementRecommendation = 'Escalate to hardware team'
        }
    }

    # === WEAR COMPONENTS (L2) ===

    # SMART warnings / disk wear
    if ($component -match 'SMART|SSD.*Wear|NVMe.*Wear|HDD.*Wear|Reallocated') {
        if ($status -eq 'Fail') {
            return @{
                Classification = 'FATAL'
                Component      = $component
                Reason         = "Storage failure: $details"
                ReplacementRecommendation = 'Replace SSD/HDD immediately'
            }
        }
        return @{
            Classification = 'WEAR'
            Component      = $component
            Reason         = "Storage wear detected: $details"
            ReplacementRecommendation = 'Plan SSD/HDD replacement -- drive approaching end of life'
        }
    }

    # Battery wear
    if ($component -match 'Battery.*Wear|Battery.*Cycle|Battery.*Health') {
        return @{
            Classification = 'WEAR'
            Component      = $component
            Reason         = "Battery degradation: $details"
            ReplacementRecommendation = 'Replace battery pack'
        }
    }

    # CMOS / RTC
    if ($component -match 'CMOS|RTC.*Battery|RTC.*Clock') {
        if ($status -eq 'Fail' -or $status -eq 'Warning') {
            return @{
                Classification = 'WEAR'
                Component      = $component
                Reason         = "CMOS battery failing: $details"
                ReplacementRecommendation = 'Replace CR2032 coin cell battery'
            }
        }
    }

    # RAM correctable errors
    if ($component -match 'WHEA.*Correct|Memory.*Warning|RAM.*Error' -and $severity -match '^H') {
        return @{
            Classification = 'WEAR'
            Component      = $component
            Reason         = "Memory showing correctable errors: $details"
            ReplacementRecommendation = 'Reseat or replace DIMM module'
        }
    }

    # Fan issues
    if ($component -match 'Fan.*Not Spinning|Fan.*Fail|Fan.*Anomal') {
        return @{
            Classification = 'WEAR'
            Component      = $component
            Reason         = "Fan unit degradation: $details"
            ReplacementRecommendation = 'Replace fan unit'
        }
    }

    # Display dead pixels (from config threshold)
    if ($component -match 'Dead Pixel|Pixel.*Defect|Display.*Pixel') {
        return @{
            Classification = 'WEAR'
            Component      = $component
            Reason         = "Display pixel defects: $details"
            ReplacementRecommendation = 'Screen replacement per LCD policy'
        }
    }

    # Thermal paste degradation
    if ($component -match 'Thermal.*Paste|Thermal.*Degrad') {
        return @{
            Classification = 'WEAR'
            Component      = $component
            Reason         = "Thermal interface degraded: $details"
            ReplacementRecommendation = 'Retherm required -- replace thermal paste'
        }
    }

    # H2 severity that isn't already caught above
    if ($severity -eq 'H2' -and ($status -eq 'Fail' -or $status -eq 'Warning')) {
        return @{
            Classification = 'WEAR'
            Component      = $component
            Reason         = "Hardware wear detected: $details"
            ReplacementRecommendation = 'Component inspection and possible replacement required'
        }
    }

    # H1 severity = hardware info/warning
    if ($severity -eq 'H1' -and $status -eq 'Warning') {
        return @{
            Classification = 'WEAR'
            Component      = $component
            Reason         = "Hardware advisory: $details"
            ReplacementRecommendation = 'Monitor component -- replacement may be needed soon'
        }
    }

    # === SOFTWARE (L1) ===

    # Everything else with S-severity codes
    if ($severity -match '^S' -and ($status -eq 'Fail' -or $status -eq 'Warning')) {
        return @{
            Classification = 'SOFTWARE'
            Component      = $component
            Reason         = "Software-level issue: $details"
            ReplacementRecommendation = $null
        }
    }

    # Default: treat remaining failures as software
    if ($status -eq 'Fail' -or $status -eq 'Warning') {
        return @{
            Classification = 'SOFTWARE'
            Component      = $component
            Reason         = "$component issue: $details"
            ReplacementRecommendation = $null
        }
    }

    return @{
        Classification = 'PASS'
        Component      = $component
        Reason         = 'No actionable issue'
        ReplacementRecommendation = $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-SeverityScore -- Compute 0-100 severity score from all findings
# ─────────────────────────────────────────────────────────────────────────────

function Get-SeverityScore {
    <#
    .SYNOPSIS
        Computes the severity score (0-100) based on the worst finding.
        0 = no issues, 100 = critical hardware fault.
        Uses the severity weight map and finding weights.

    .PARAMETER Findings
        ArrayList of finding objects from DiagState.Findings.

    .PARAMETER Config
        Hashtable from Get-ClassificationConfig.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        $Findings,
        [hashtable]$Config = @{}
    )

    if (-not $Findings -or $Findings.Count -eq 0) {
        return 0
    }

    $maxScore = 0

    foreach ($f in $Findings) {
        if ($f.Status -eq 'Pass' -or $f.Status -eq 'Info') { continue }

        $component = if ($f.Component) { $f.Component } else { '' }
        $details   = if ($f.Details) { $f.Details } else { '' }
        $combined  = "$component $details"
        $score     = 0

        # Check against severity weight map
        foreach ($entry in $script:_SeverityWeightMap) {
            if ($combined -match $entry.Pattern) {
                $score = $entry.Score
                break
            }
        }

        # Fallback: use finding weight if no pattern matched
        if ($score -eq 0 -and $f.Weight) {
            $score = [math]::Min([int]$f.Weight, 100)
        }

        # Status modifier: Fail gets full score, Warning gets 70%
        if ($f.Status -eq 'Warning' -and $score -gt 0) {
            $score = [math]::Round($score * 0.7)
        }

        if ($score -gt $maxScore) {
            $maxScore = $score
        }
    }

    return [math]::Min($maxScore, 100)
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoke-DecisionTree -- 5-branch diagnostic decision tree
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-DecisionTree {
    <#
    .SYNOPSIS
        Implements the formal 5-branch decision tree:
          1. No power / POST failure → L3
          2. Power but no Windows (boot failure) → L3
          3. Windows + fatal hardware errors → L3
          4. Windows + hardware wear → L2 (with L2→L3 escalation checks)
          5. Windows + software errors → L1
          6. No issues → CLEAR

    .PARAMETER Findings
        ArrayList of finding objects from DiagState.Findings.

    .PARAMETER DiagState
        Full DiagState hashtable (for flags like HardwareCritical, BootIssues).

    .PARAMETER Config
        Hashtable from Get-ClassificationConfig.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        $Findings,
        [hashtable]$DiagState = @{},
        [hashtable]$Config = @{}
    )

    if (-not $Findings -or $Findings.Count -eq 0) {
        return @{
            Level     = 'CLEAR'
            Branch    = 'NO_ISSUES'
            Reasoning = 'No diagnostic findings to classify'
            Path      = @('No Findings', 'CLEAR')
            FatalComponents = @()
            WearComponents  = @()
        }
    }

    # Classify every finding
    $fatalComponents = [System.Collections.ArrayList]::new()
    $wearComponents  = [System.Collections.ArrayList]::new()
    $softwareIssues  = [System.Collections.ArrayList]::new()

    foreach ($f in $Findings) {
        $health = Get-ComponentHealth -Finding $f -Config $Config
        switch ($health.Classification) {
            'FATAL'    { [void]$fatalComponents.Add(@{ Finding = $f; Health = $health }) }
            'WEAR'     { [void]$wearComponents.Add(@{ Finding = $f; Health = $health }) }
            'SOFTWARE' { [void]$softwareIssues.Add(@{ Finding = $f; Health = $health }) }
        }
    }

    # ── Branch 1: No power / POST failure ──────────────────────────────────
    $postFailures = @($fatalComponents | Where-Object {
        $_.Finding.Component -match 'POST|No Power|Dead Board|Power Short|No Display'
    })
    if ($postFailures.Count -gt 0) {
        $first = $postFailures[0]
        return @{
            Level     = 'L3'
            Branch    = 'NO_POWER'
            Reasoning = "POST/power failure: $($first.Finding.Component) -- $($first.Health.Reason)"
            Path      = @('No Power', 'POST Failure', 'L3 TECHNICIAN REQUIRED')
            FatalComponents = @($fatalComponents)
            WearComponents  = @($wearComponents)
        }
    }

    # ── Branch 2: Power but no Windows (boot failure) ──────────────────────
    $bootFailures = @($fatalComponents | Where-Object {
        $_.Finding.Component -match 'BCD|Boot Manager|Boot Loader|BIOS.*Corrupt|No Boot Device'
    })
    $hasBootFlag = ($DiagState.ContainsKey('BootIssues') -and $DiagState['BootIssues'])
    if ($bootFailures.Count -gt 0 -and $hasBootFlag) {
        $first = $bootFailures[0]
        return @{
            Level     = 'L3'
            Branch    = 'NO_WINDOWS'
            Reasoning = "Boot failure: $($first.Finding.Component) -- $($first.Health.Reason)"
            Path      = @('Power OK', 'No Windows Boot', 'L3 TECHNICIAN REQUIRED')
            FatalComponents = @($fatalComponents)
            WearComponents  = @($wearComponents)
        }
    }

    # ── Branch 3: Windows + fatal hardware errors → L3 ─────────────────────
    if ($fatalComponents.Count -gt 0) {
        $first = $fatalComponents[0]
        return @{
            Level     = 'L3'
            Branch    = 'FATAL_HARDWARE'
            Reasoning = "Fatal hardware: $($first.Finding.Component) -- $($first.Health.Reason)"
            Path      = @('Power OK', 'Windows OK', 'Fatal Hardware Detected', 'L3 TECHNICIAN REQUIRED')
            FatalComponents = @($fatalComponents)
            WearComponents  = @($wearComponents)
        }
    }

    # ── Branch 4: Windows + hardware wear → L2 ─────────────────────────────
    if ($wearComponents.Count -gt 0) {
        # Check L2 → L3 escalation triggers
        $escalateToL3 = $false
        $escalateReason = ''

        foreach ($wc in $wearComponents) {
            $comp = $wc.Finding.Component
            $det  = if ($wc.Finding.Details) { $wc.Finding.Details } else { '' }

            # Uncorrectable memory
            if ($comp -match 'Uncorrectable' -and $Config['EscalateL2ToL3_UncorrectableMemory'] -eq 1) {
                $escalateToL3 = $true
                $escalateReason = "Uncorrectable memory error escalated from L2 to L3"
            }
            # Storage controller failure
            if ($comp -match 'Storage Controller' -and $Config['EscalateL2ToL3_StorageControllerFail'] -eq 1) {
                $escalateToL3 = $true
                $escalateReason = "Storage controller failure escalated from L2 to L3"
            }
            # Firmware corruption
            if (($comp -match 'Firmware.*Corrupt' -or $det -match 'firmware.*corrupt') -and $Config['EscalateL2ToL3_FirmwareCorruption'] -eq 1) {
                $escalateToL3 = $true
                $escalateReason = "Firmware corruption escalated from L2 to L3"
            }
            # TPM hardware failure
            if ($comp -match 'TPM.*Hardware' -and $Config['EscalateL2ToL3_TPMHardwareFail'] -eq 1) {
                $escalateToL3 = $true
                $escalateReason = "TPM hardware failure escalated from L2 to L3"
            }
        }

        if ($escalateToL3) {
            return @{
                Level     = 'L3'
                Branch    = 'L2_ESCALATED'
                Reasoning = $escalateReason
                Path      = @('Power OK', 'Windows OK', 'Hardware Wear', 'Escalation Trigger', 'L3 TECHNICIAN REQUIRED')
                FatalComponents = @($fatalComponents)
                WearComponents  = @($wearComponents)
            }
        }

        $first = $wearComponents[0]
        return @{
            Level     = 'L2'
            Branch    = 'HARDWARE_WEAR'
            Reasoning = "$($wearComponents.Count) component(s) showing wear: $($first.Finding.Component)"
            Path      = @('Power OK', 'Windows OK', 'Hardware Wear Detected', 'L2 REPLACEABLE COMPONENT')
            FatalComponents = @($fatalComponents)
            WearComponents  = @($wearComponents)
        }
    }

    # ── Branch 5: Windows + software errors → L1 ──────────────────────────
    if ($softwareIssues.Count -gt 0) {
        $first = $softwareIssues[0]
        return @{
            Level     = 'L1'
            Branch    = 'SOFTWARE_FIXABLE'
            Reasoning = "$($softwareIssues.Count) software-level issue(s): $($first.Finding.Component)"
            Path      = @('Power OK', 'Windows OK', 'Software Errors', 'L1 AUTO-FIXABLE')
            FatalComponents = @($fatalComponents)
            WearComponents  = @($wearComponents)
        }
    }

    # ── No actionable issues ───────────────────────────────────────────────
    return @{
        Level     = 'CLEAR'
        Branch    = 'ALL_PASS'
        Reasoning = 'All findings are Pass or Info -- no actionable issues'
        Path      = @('Power OK', 'Windows OK', 'All Checks Passed', 'CLEAR')
        FatalComponents = @()
        WearComponents  = @()
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-DiagnosticLevel -- Master classification function
# ─────────────────────────────────────────────────────────────────────────────

function Get-DiagnosticLevel {
    <#
    .SYNOPSIS
        Master function that returns the diagnostic classification.
        Calls Invoke-DecisionTree and Get-SeverityScore, then returns
        a unified result.

    .PARAMETER Findings
        ArrayList of finding objects from DiagState.Findings.

    .PARAMETER DiagState
        Full DiagState hashtable.

    .PARAMETER Config
        Hashtable from Get-ClassificationConfig.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        $Findings,
        [hashtable]$DiagState = @{},
        [hashtable]$Config = @{},
        [hashtable]$TrendData = @{}
    )

    $tree  = Invoke-DecisionTree -Findings $Findings -DiagState $DiagState -Config $Config
    $score = Get-SeverityScore   -Findings $Findings -Config $Config

    # Count by classification
    $l1Count = 0; $l2Count = 0; $l3Count = 0
    foreach ($f in $Findings) {
        if ($f.Status -eq 'Pass' -or $f.Status -eq 'Info') { continue }
        $health = Get-ComponentHealth -Finding $f -Config $Config
        switch ($health.Classification) {
            'SOFTWARE' { $l1Count++ }
            'WEAR'     { $l2Count++ }
            'FATAL'    { $l3Count++ }
        }
    }

    # Determine allowed auto-fix categories
    $autoFixCats = @()
    if ($Config.ContainsKey('L1_AutoFixCategories') -and $Config['L1_AutoFixCategories']) {
        $autoFixCats = @($Config['L1_AutoFixCategories'] -split ',')
    }

    # v8.5: Recurrence escalation -- if TrendData shows same issue >3 sessions, escalate one level
    $recurrenceEscalated = $false
    if ($TrendData.Count -gt 0 -and $TrendData.ContainsKey('RecurrenceCount')) {
        $recurrenceThreshold = if ($Config.ContainsKey('RecurrenceEscalationThreshold')) { [int]$Config['RecurrenceEscalationThreshold'] } else { 3 }
        if ([int]$TrendData['RecurrenceCount'] -gt $recurrenceThreshold) {
            $recurrenceEscalated = $true
            if ($tree.Level -eq 'CLEAR') { $tree.Level = 'L1'; $tree.Reasoning += ' [Recurrence escalation: CLEAR->L1]' }
            elseif ($tree.Level -eq 'L1') { $tree.Level = 'L2'; $tree.Reasoning += ' [Recurrence escalation: L1->L2]' }
            elseif ($tree.Level -eq 'L2') { $tree.Level = 'L3'; $tree.Reasoning += ' [Recurrence escalation: L2->L3]' }
        }
    }

    return @{
        Level              = $tree.Level
        Branch             = $tree.Branch
        Reasoning          = $tree.Reasoning
        Path               = $tree.Path
        SeverityScore      = $score
        FatalComponents    = $tree.FatalComponents
        WearComponents     = $tree.WearComponents
        L1Count            = $l1Count
        L2Count            = $l2Count
        L3Count            = $l3Count
        AutoFixAllowed     = ($tree.Level -eq 'L1')
        AutoFixCategories  = $autoFixCats
        ConfidenceRequired = if ($Config.ContainsKey('L1_RequireConfidenceForFix')) { $Config['L1_RequireConfidenceForFix'] } else { 60 }
        RecurrenceEscalated = $recurrenceEscalated
        TrendData           = $TrendData
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-ClassificationReport -- Generate mandatory JSON report structure
# ─────────────────────────────────────────────────────────────────────────────

function Get-ClassificationReport {
    <#
    .SYNOPSIS
        Generates the mandatory structured classification report.
        Returns an ordered hashtable matching the required JSON schema.

    .PARAMETER DiagState
        Full DiagState hashtable with Findings, Machine, FixesApplied, etc.

    .PARAMETER Config
        Hashtable from Get-ClassificationConfig.

    .PARAMETER RootCauseRanking
        Optional PSCustomObject from the existing Get-RootCauseRanking function
        (for backward compatibility). If not provided, fields are computed locally.
    #>
    [CmdletBinding()]
    [OutputType([ordered])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$DiagState,
        [hashtable]$Config = @{},
        [PSCustomObject]$RootCauseRanking = $null,
        [hashtable]$TrendData = @{}
    )

    $findings = $DiagState.Findings

    # Run classification
    $classification = Get-DiagnosticLevel -Findings $findings -DiagState $DiagState -Config $Config -TrendData $TrendData
    $severityScore  = $classification.SeverityScore

    # Root cause (from ranking if provided, else from heaviest finding)
    $primaryCause = 'No issues detected'
    $secondarySymptoms = @()
    $confidence = 100
    $enterpriseScore = 100

    if ($RootCauseRanking) {
        $primaryCause      = $RootCauseRanking.PrimaryRootCause
        $secondarySymptoms = @($RootCauseRanking.SecondarySymptoms | ForEach-Object {
            [ordered]@{
                component = if ($_.Component) { $_.Component } else { '' }
                details   = if ($_.Details) { $_.Details } else { '' }
                weight    = if ($_.Weight) { $_.Weight } else { 0 }
            }
        })
        $confidence    = $RootCauseRanking.Confidence
        $enterpriseScore = $RootCauseRanking.EnterpriseScore
    }
    else {
        # Compute from findings
        $failFindings = @($findings | Where-Object { $_.Status -eq 'Fail' -or $_.Status -eq 'Warning' })
        if ($failFindings.Count -gt 0) {
            $sorted = @($failFindings | Sort-Object Weight -Descending)
            $top = $sorted[0]
            $primaryCause = "$($top.Component): $($top.Details)"
            if ($sorted.Count -gt 1) {
                $secondarySymptoms = @($sorted[1..([math]::Min($sorted.Count - 1, 4))] | ForEach-Object {
                    [ordered]@{
                        component = if ($_.Component) { $_.Component } else { '' }
                        details   = if ($_.Details) { $_.Details } else { '' }
                        weight    = if ($_.Weight) { $_.Weight } else { 0 }
                    }
                })
            }
            # v8.5: Enhanced confidence = SeverityWeight × FrequencyWeight × PhaseConsistencyFactor
            $totalWeight = 0
            foreach ($f in $sorted) { $totalWeight += $f.Weight }
            if ($totalWeight -gt 0) {
                # Factor 1: SeverityWeight (primary cause weight vs total)
                $severityWeight = $top.Weight / $totalWeight

                # Factor 2: FrequencyWeight (how many findings share same category as primary)
                $primaryCat = if ($top.Category) { $top.Category } else { 'Unknown' }
                $sameCategory = @($sorted | Where-Object { $_.Category -eq $primaryCat }).Count
                $frequencyWeight = [math]::Min($sameCategory / [math]::Max($sorted.Count, 1), 1.0)

                # Factor 3: PhaseConsistencyFactor (1.0 if all findings agree on category, 0.8 if mixed)
                $uniqueCategories = @($sorted | Select-Object -ExpandProperty Category -Unique).Count
                $phaseConsistencyFactor = if ($uniqueCategories -le 2) { 1.0 } else { 0.8 }

                $rawConfidence = $severityWeight * $frequencyWeight * $phaseConsistencyFactor * 100
                $confidence = [math]::Round([math]::Max(10, [math]::Min(95, $rawConfidence)))
            }
            # Enterprise score (health inverse)
            $enterpriseScore = 100
            foreach ($f in $sorted) {
                if ($f.Status -eq 'Fail') { $enterpriseScore -= [math]::Round($f.Weight * 0.5) }
                elseif ($f.Status -eq 'Warning') { $enterpriseScore -= [math]::Round($f.Weight * 0.2) }
            }
            if ($enterpriseScore -lt 0) { $enterpriseScore = 0 }
        }
    }

    # Use ScoringEngine result if available
    if ($DiagState.ContainsKey('ScoreResult') -and $DiagState['ScoreResult']) {
        $sr = $DiagState['ScoreResult']
        if ($sr.PSObject.Properties['finalScore'] -or ($sr -is [hashtable] -and $sr.ContainsKey('finalScore'))) {
            $eScore = if ($sr -is [hashtable]) { $sr['finalScore'] } else { $sr.finalScore }
            $enterpriseScore = [int]$eScore
        }
    }

    # Stress validation
    $stressValidation = 'N/A'
    if ($DiagState.ContainsKey('StressResults') -and $DiagState['StressResults']) {
        $sr = $DiagState['StressResults']
        $anyFail = $false
        $anyRun  = $false
        if ($sr -is [hashtable]) {
            foreach ($key in $sr.Keys) {
                $anyRun = $true
                $val = $sr[$key]
                if ($val -is [hashtable] -and $val.ContainsKey('Status') -and $val['Status'] -eq 'Fail') {
                    $anyFail = $true
                }
                elseif ($val -is [string] -and $val -eq 'Fail') {
                    $anyFail = $true
                }
            }
        }
        if ($anyRun) {
            $stressValidation = if ($anyFail) { 'FAIL' } else { 'PASS' }
        }
    }

    # Rollback tokens
    $rollbackTokens = @()
    if ($DiagState.ContainsKey('BackupId') -and $DiagState['BackupId']) {
        $rollbackTokens = @($DiagState['BackupId'])
    }

    # Actions taken
    $actionsTaken = @()
    if ($DiagState.ContainsKey('FixesApplied') -and $DiagState['FixesApplied']) {
        $actionsTaken = @($DiagState['FixesApplied'] | ForEach-Object {
            if ($_ -is [hashtable]) {
                [ordered]@{
                    name     = if ($_.Name) { $_.Name } else { 'Repair' }
                    category = if ($_.Category) { $_.Category } else { 'Unknown' }
                    details  = if ($_.Details) { $_.Details } else { '' }
                    status   = if ($_.Status) { $_.Status } else { 'Applied' }
                }
            }
            else {
                [ordered]@{
                    name     = if ($_.PSObject.Properties['Name']) { $_.Name } else { 'Repair' }
                    category = if ($_.PSObject.Properties['Category']) { $_.Category } else { 'Unknown' }
                    details  = if ($_.PSObject.Properties['Details']) { $_.Details } else { '' }
                    status   = if ($_.PSObject.Properties['Status']) { $_.Status } else { 'Applied' }
                }
            }
        })
    }

    # Device info
    $machine = if ($DiagState.ContainsKey('Machine')) { $DiagState['Machine'] } else { @{} }
    $device = [ordered]@{
        computer_name = if ($machine.ContainsKey('ComputerName')) { $machine['ComputerName'] } else { $env:COMPUTERNAME }
        serial_number = if ($machine.ContainsKey('Serial')) { $machine['Serial'] } else { 'Unknown' }
        manufacturer  = if ($machine.ContainsKey('Manufacturer')) { $machine['Manufacturer'] } else { 'Unknown' }
        model         = if ($machine.ContainsKey('Model')) { $machine['Model'] } else { 'Unknown' }
        os            = if ($machine.ContainsKey('OS')) { $machine['OS'] } else { 'Unknown' }
        bios_version  = if ($machine.ContainsKey('BIOSVersion')) { $machine['BIOSVersion'] } else { 'Unknown' }
    }

    # Build findings array for report
    $findingsArray = @($findings | ForEach-Object {
        [ordered]@{
            component = if ($_.Component) { $_.Component } else { '' }
            category  = if ($_.Category) { $_.Category } else { '' }
            status    = if ($_.Status) { $_.Status } else { '' }
            weight    = if ($_.Weight) { $_.Weight } else { 0 }
            severity  = if ($_.Severity) { $_.Severity } else { '' }
            details   = if ($_.Details) { $_.Details } else { '' }
            timestamp = if ($_.Timestamp) { $_.Timestamp } else { '' }
        }
    })

    # Build L2 component health cards
    $componentHealth = @()
    if ($classification.WearComponents) {
        foreach ($wc in $classification.WearComponents) {
            $componentHealth += [ordered]@{
                component      = $wc.Finding.Component
                category       = if ($wc.Finding.Category) { $wc.Finding.Category } else { 'Hardware' }
                status         = $wc.Finding.Status
                classification = 'L2_REPLACEABLE'
                reason         = $wc.Health.Reason
                recommendation = $wc.Health.ReplacementRecommendation
                weight         = if ($wc.Finding.Weight) { $wc.Finding.Weight } else { 0 }
            }
        }
    }

    # Build the mandatory report
    $report = [ordered]@{
        _type                    = 'CLASSIFICATION_REPORT'
        _version                 = '8.5.0'
        device                   = $device
        snapshot_time            = if ($machine.ContainsKey('ScanTime')) { $machine['ScanTime'] } else { (Get-Date -Format 'o') }
        findings                 = $findingsArray
        primary_cause            = $primaryCause
        secondary_symptoms       = $secondarySymptoms
        severity_score           = $severityScore
        confidence_pct           = $confidence
        actions_taken            = $actionsTaken
        rollback_tokens          = $rollbackTokens
        stress_validation        = $stressValidation
        escalation_level         = $classification.Level
        enterprise_score         = $enterpriseScore
        classification_branch    = $classification.Branch
        classification_reasoning = $classification.Reasoning
        recurrence_escalated     = if ($classification.ContainsKey('RecurrenceEscalated')) { $classification['RecurrenceEscalated'] } else { $false }
        decision_tree_path       = $classification.Path
        component_health         = $componentHealth
        l1_count                 = $classification.L1Count
        l2_count                 = $classification.L2Count
        l3_count                 = $classification.L3Count
        auto_fix_allowed         = $classification.AutoFixAllowed
    }

    return $report
}

#endregion

Export-ModuleMember -Function @(
    'Get-ClassificationConfig',
    'Get-ComponentHealth',
    'Get-SeverityScore',
    'Invoke-DecisionTree',
    'Get-DiagnosticLevel',
    'Get-ClassificationReport'
)
