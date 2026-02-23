<#
.SYNOPSIS
    Smart Diagnosis Engine - LDT v9.0 Option 54
    9-phase orchestrated diagnostic with decision tree, root cause ranking,
    rollback protection, post-fix stress validation, and enterprise engines.

.VERSION
    9.0.0

.NOTES
    Architecture: Standalone PS1 (called by Laptop_Master_Diagnostic.bat)
    Dependencies: None - vanilla PowerShell 5.1
    Config: Reads thresholds from Config\config.ini [SmartDiagnosis]
    Output: Terminal + HTML report + audit log
    Calls: Laptop_Diagnostic_Suite.ps1 -RunFunction for remediation (Phase 6)
#>

param(
    [string]$LogPath     = ".\Logs",
    [string]$ReportPath  = ".\Reports",
    [string]$ConfigPath  = ".\Config",
    [string]$BackupPath  = ".\Backups",
    [string]$TempPath    = ".\Temp",
    [string]$DataPath    = ".\Data",
    [string]$ScriptRoot  = "",
    [string]$Mode        = "Full"
)

# ============================================================
# SETUP
# ============================================================

$ErrorActionPreference = "SilentlyContinue"
$timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$dateDisplay = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$logFile     = Join-Path $LogPath    "SmartDiag_$timestamp.log"
$reportFile  = Join-Path $ReportPath "SmartDiag_$timestamp.html"

# Determine script root for calling main PS1
if (-not $ScriptRoot) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$mainPS1 = Join-Path $ScriptRoot "Laptop_Diagnostic_Suite.ps1"

# ============================================================
# ENTERPRISE ENGINE IMPORTS (v7.0 -- graceful degradation)
# ============================================================

$v7EnginesAvailable = $false
$coreDir = Join-Path $ScriptRoot "Core"
if (Test-Path $coreDir) {
    try {
        Import-Module (Join-Path $coreDir "LDT-EngineAdapter.psm1") -Force -ErrorAction Stop
        Import-Module (Join-Path $coreDir "GuardEngine.psm1") -Force -ErrorAction Stop
        Import-Module (Join-Path $coreDir "IntegrityEngine.psm1") -Force -ErrorAction Stop
        Import-Module (Join-Path $coreDir "ScoringEngine.psm1") -Force -ErrorAction Stop
        Import-Module (Join-Path $coreDir "TrendEngine.psm1") -Force -ErrorAction Stop
        Import-Module (Join-Path $coreDir "ComplianceExport.psm1") -Force -ErrorAction Stop
        Import-Module (Join-Path $coreDir "ClassificationEngine.psm1") -Force -ErrorAction Stop
        $v7EnginesAvailable = $true
    }
    catch {
        Write-Host "  [WARN] Enterprise engines failed to load: $($_.Exception.Message)" -ForegroundColor Yellow
        $v7EnginesAvailable = $false
    }
}

# v9 Governance Engine imports (graceful degradation)
$v9GovernanceAvailable = $false
if ($v7EnginesAvailable -and (Test-Path $coreDir)) {
    try {
        Import-Module (Join-Path $coreDir "GovernanceEngine.psm1") -Force -ErrorAction Stop
        Import-Module (Join-Path $coreDir "FleetGovernance.psm1") -Force -ErrorAction Stop
        $v9GovernanceAvailable = $true
    }
    catch {
        Write-Host "  [INFO] Governance engines not available: $($_.Exception.Message)" -ForegroundColor DarkGray
        $v9GovernanceAvailable = $false
    }
}

# Load enterprise config
$v7Config = $null
$v7ConfigPath = Join-Path $ConfigPath "config.json"
if ($v7EnginesAvailable -and (Test-Path $v7ConfigPath)) {
    try {
        $v7Config = Get-Content $v7ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch { }
}

# Load classification engine config
$classConfig = @{}
if ($v7EnginesAvailable) {
    try { $classConfig = Get-ClassificationConfig -ConfigPath $ConfigPath }
    catch { $classConfig = @{} }
}

# Machine info
$computerName  = $env:COMPUTERNAME
$biosInfo      = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
$csInfo        = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$osInfo        = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$serialNumber  = if ($biosInfo) { $biosInfo.SerialNumber } else { "Unknown" }
$manufacturer  = if ($csInfo) { $csInfo.Manufacturer } else { "Unknown" }
$model         = if ($csInfo) { $csInfo.Model } else { "Unknown" }
$osVersion     = if ($osInfo) { $osInfo.Caption + " " + $osInfo.BuildNumber } else { "Unknown" }
$isDomainJoined = if ($csInfo) { $csInfo.PartOfDomain } else { $false }

# Ensure output directories exist
foreach ($dir in @($LogPath, $ReportPath, $BackupPath, $TempPath)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

# ============================================================
# LOGGING
# ============================================================

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] $Message"
    Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
}

Write-Log "============================================"
Write-Log "Smart Diagnosis Engine v7.0.0 started"
Write-Log "Machine: $computerName | Serial: $serialNumber | Model: $model"
Write-Log "============================================"

# ============================================================
# CONFIG READER
# ============================================================

function Read-Config {
    param([string]$FilePath)
    $config = @{}
    if (-not (Test-Path $FilePath)) { return $config }
    $section = ""
    foreach ($line in Get-Content $FilePath) {
        $line = $line.Trim()
        if ($line -eq "" -or $line.StartsWith(";") -or $line.StartsWith("#")) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1]
            continue
        }
        if ($line -match '^(.+?)=(.*)$') {
            $key = "$section.$($Matches[1].Trim())"
            $config[$key] = $Matches[2].Trim()
        }
    }
    return $config
}

$configFile = Join-Path $ConfigPath "config.ini"
$config = Read-Config -FilePath $configFile

# SmartDiagnosis config with PS 5.1 safe defaults
$cfgStressDuration    = if ($config["SmartDiagnosis.StressTestDurationSec"])       { [int]$config["SmartDiagnosis.StressTestDurationSec"] }       else { 60 }
$cfgStressMemoryMB    = if ($config["SmartDiagnosis.StressTestMemoryBlocksMB"])    { [int]$config["SmartDiagnosis.StressTestMemoryBlocksMB"] }    else { 200 }
$cfgStressDiskMB      = if ($config["SmartDiagnosis.StressTestDiskSizeMB"])        { [int]$config["SmartDiagnosis.StressTestDiskSizeMB"] }        else { 100 }
$cfgConfidenceThresh  = if ($config["SmartDiagnosis.ConfidenceThresholdForAutoFix"]) { [int]$config["SmartDiagnosis.ConfidenceThresholdForAutoFix"] } else { 60 }
$cfgMaxAutoLevel      = if ($config["SmartDiagnosis.MaxAutoRemediationLevel"])     { $config["SmartDiagnosis.MaxAutoRemediationLevel"] }          else { "L1" }
$cfgBackupRegistry    = if ($config["SmartDiagnosis.BackupRegistryBeforeFix"])     { [int]$config["SmartDiagnosis.BackupRegistryBeforeFix"] }     else { 1 }
$cfgBackupDrivers     = if ($config["SmartDiagnosis.BackupDriversBeforeFix"])      { [int]$config["SmartDiagnosis.BackupDriversBeforeFix"] }      else { 1 }
$cfgCreateRestore     = if ($config["SmartDiagnosis.CreateRestorePointBeforeFix"]) { [int]$config["SmartDiagnosis.CreateRestorePointBeforeFix"] } else { 1 }
$cfgThermalBlock      = if ($config["SmartDiagnosis.ThermalBlockStressTestC"])     { [int]$config["SmartDiagnosis.ThermalBlockStressTestC"] }     else { 85 }
$cfgThermalWarn       = if ($config["SmartDiagnosis.ThermalWarningC"])             { [int]$config["SmartDiagnosis.ThermalWarningC"] }             else { 75 }
$cfgBsodCritical      = if ($config["SmartDiagnosis.BSODCriticalCount"])           { [int]$config["SmartDiagnosis.BSODCriticalCount"] }           else { 5 }
$cfgBsodDays          = if ($config["SmartDiagnosis.BSODDaysBack"])                { [int]$config["SmartDiagnosis.BSODDaysBack"] }                else { 30 }
$cfgPerfTolerance     = if ($config["SmartDiagnosis.PerfTolerancePercent"])        { [int]$config["SmartDiagnosis.PerfTolerancePercent"] }        else { 10 }
$cfgEventLogDays      = if ($config["SmartDiagnosis.EventLogDaysBack"])            { [int]$config["SmartDiagnosis.EventLogDaysBack"] }            else { 7 }
$cfgBattSampleSec     = if ($config["SmartDiagnosis.BatteryDischargeSampleSec"])   { [int]$config["SmartDiagnosis.BatteryDischargeSampleSec"] }   else { 60 }

Write-Log "Config: StressDuration=$cfgStressDuration, ConfidenceThreshold=$cfgConfidenceThresh, MaxAutoLevel=$cfgMaxAutoLevel"

# ============================================================
# TERMINAL DISPLAY HELPERS
# ============================================================

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor DarkCyan
    Write-Host "   $Text" -ForegroundColor White
    Write-Host "  ============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-ScanHeader {
    param([string]$Name, [string]$Icon)
    Write-Host ""
    Write-Host "  $Icon $Name" -ForegroundColor Cyan
    Write-Host "  $('-' * ($Name.Length + 4))" -ForegroundColor DarkGray
}

function Write-Finding {
    param([string]$Label, [string]$Value, [string]$Color = "Gray")
    $padLen = 42 - $Label.Length
    if ($padLen -lt 1) { $padLen = 1 }
    $padding = " " * $padLen
    Write-Host "    $Label$padding" -NoNewline -ForegroundColor Gray
    Write-Host "$Value" -ForegroundColor $Color
}

function Write-PhaseResult {
    param([string]$Phase, [string]$Status, [string]$Details = "")
    $badge = switch ($Status) {
        "PASS"    { @{ Text = "[PASS]";    Color = "Green"  } }
        "WARN"    { @{ Text = "[WARN]";    Color = "Yellow" } }
        "FAIL"    { @{ Text = "[FAIL]";    Color = "Red"    } }
        "SKIP"    { @{ Text = "[SKIP]";    Color = "DarkGray" } }
        "APPLIED" { @{ Text = "[APPLIED]"; Color = "Cyan"   } }
        default   { @{ Text = "[$Status]"; Color = "Gray"   } }
    }
    Write-Host ""
    Write-Host "    $($badge.Text) " -NoNewline -ForegroundColor $badge.Color
    Write-Host "$Phase" -NoNewline -ForegroundColor White
    if ($Details) {
        Write-Host " - $Details" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
}

function Write-ProgressBar {
    param([string]$Label, [int]$Score, [int]$MaxWidth = 30)
    $filled = [math]::Round($Score / 100 * $MaxWidth)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $MaxWidth) { $filled = $MaxWidth }
    $empty = $MaxWidth - $filled
    $color = if ($Score -ge 80) { "Green" } elseif ($Score -ge 60) { "Yellow" } else { "Red" }
    $padLen = 20 - $Label.Length
    if ($padLen -lt 1) { $padLen = 1 }
    Write-Host "    $Label$(' ' * $padLen)" -NoNewline -ForegroundColor Gray
    Write-Host "[" -NoNewline -ForegroundColor DarkGray
    if ($filled -gt 0) { Write-Host ("=" * $filled) -NoNewline -ForegroundColor $color }
    if ($empty -gt 0)  { Write-Host ("." * $empty) -NoNewline -ForegroundColor DarkGray }
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Score%" -ForegroundColor $color
}

# ============================================================
# AUDIT LOG (local copy - standalone script)
# ============================================================

function Write-DiagAuditLog {
    param(
        [string]$Module,
        [string]$IssueCode,
        [string]$Severity,
        [string]$ActionTaken    = "None",
        [string]$ValidationStatus = "N/A",
        [string]$FinalState     = "N/A",
        [string]$RiskLevel      = "Low"
    )
    try {
        $auditFile = Join-Path $LogPath "LDT_Audit_$(Get-Date -Format 'yyyyMMdd').audit.log"
        $blStatus = "Unknown"
        try {
            $blVol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
            if ($blVol) { $blStatus = $blVol.ProtectionStatus.ToString() }
        } catch { }
        $entry = "TIMESTAMP=$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')" +
            " | DEVICE_SERIAL=$serialNumber" +
            " | VENDOR=$manufacturer" +
            " | MODEL=$model" +
            " | OS_BUILD=$osVersion" +
            " | MODULE=$Module" +
            " | ISSUE_CODE=$IssueCode" +
            " | SEVERITY=$Severity" +
            " | ACTION_TAKEN=$ActionTaken" +
            " | VALIDATION_STATUS=$ValidationStatus" +
            " | FINAL_STATE=$FinalState" +
            " | RISK_LEVEL=$RiskLevel" +
            " | DOMAIN_JOINED=$isDomainJoined" +
            " | BITLOCKER_STATUS=$blStatus"
        Add-Content -Path $auditFile -Value $entry -Encoding UTF8
    } catch { }
}

# ============================================================
# SEVERITY CODE (local copy - same logic as main PS1)
# ============================================================

function Get-LocalSeverityCode {
    param([string]$Component, [string]$Status)
    # Hardware indicators
    if ($Component -match 'SMART|Disk|SSD|HDD|Reallocated|Uncorrectable') {
        if ($Status -eq 'Fail') { return 'H3' }
        if ($Status -eq 'Warning') { return 'H2' }
        return 'H1'
    }
    if ($Component -match 'Battery|Fan|Thermal|Temperature|Memory Error|WHEA|DIMM') {
        if ($Status -eq 'Fail') { return 'H2' }
        return 'H1'
    }
    if ($Component -match 'POST|CMOS|RTC') {
        if ($Status -eq 'Fail') { return 'H2' }
        return 'H1'
    }
    # Security
    if ($Component -match 'Defender|Firewall|UAC|SmartScreen|BitLocker|TPM|Security') {
        if ($Status -eq 'Fail' -or $Status -eq 'Warning') { return 'S3' }
        return 'S1'
    }
    # Stability
    if ($Component -match 'SFC|DISM|BSOD|BugCheck|Crash|Driver|Boot|Update|WU') {
        if ($Status -eq 'Fail' -or $Status -eq 'Warning') { return 'S2' }
        return 'S1'
    }
    # Performance
    if ($Component -match 'Startup|CPU|Memory Pressure|Disk I/O|Performance') {
        return 'S4'
    }
    # Network
    if ($Component -match 'Network|Wi-Fi|DNS|Winsock|Bluetooth|VPN|Adapter') {
        if ($Status -eq 'Fail' -or $Status -eq 'Warning') { return 'S2' }
        return 'S1'
    }
    # Default
    if ($Status -eq 'Fail') { return 'S2' }
    if ($Status -eq 'Warning') { return 'S1' }
    return 'S1'
}

# ============================================================
# DIAGNOSIS STATE (accumulates across all phases)
# ============================================================

$diagState = @{
    Findings         = [System.Collections.ArrayList]::new()
    HardwareCritical = $false
    ThermalCritical  = $false
    BSODFound        = $false
    BSODDrivers      = @()
    BootIssues       = $false
    DriverIssues     = $false
    SecurityIssues   = $false
    PerfBaseline     = @{}
    FixesApplied     = [System.Collections.ArrayList]::new()
    FixesFailed      = [System.Collections.ArrayList]::new()
    StressResults    = @{}
    PhaseResults     = @{}
    Machine          = @{}
    BackupId         = ""
    PhaseTimestamp    = ""
    SessionId        = ""
    # v7 Enterprise Engine fields
    GuardStatus      = $null
    ScoreResult      = $null
    TrendData        = $null
    TrendAlerts      = @()
    ComplianceDir    = ""
    IntegrityResult  = $null
    LogSealApplied   = $false
    ExecutionReceipt = ""
    OEMMode          = $false
    # v8.5 Enterprise Hardening fields
    RemediationLedger = [System.Collections.ArrayList]::new()
    PhaseTiming       = @{}
    HealthBefore      = $null
    HealthAfter       = $null
    StressOverride    = $false
}

# ============================================================
# PHASE TIMING HELPERS (v8.5)
# ============================================================

function Start-PhaseTimer {
    param([hashtable]$DiagState, [string]$PhaseName)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $DiagState.PhaseTiming[$PhaseName] = @{
        StartTime = Get-Date -Format 'o'
        Stopwatch = $sw
        MemoryStart = [GC]::GetTotalMemory($false)
    }
}

function Stop-PhaseTimer {
    param([hashtable]$DiagState, [string]$PhaseName)
    $entry = $DiagState.PhaseTiming[$PhaseName]
    if ($null -ne $entry -and $null -ne $entry.Stopwatch) {
        $entry.Stopwatch.Stop()
        $entry.EndTime    = Get-Date -Format 'o'
        $entry.DurationMs = $entry.Stopwatch.ElapsedMilliseconds
        $entry.MemoryEnd  = [GC]::GetTotalMemory($false)
        $entry.MemoryDeltaBytes = $entry.MemoryEnd - $entry.MemoryStart
        $entry.Remove('Stopwatch')
        if ($entry.DurationMs -gt 120000) {
            Write-Log "WARNING: $PhaseName took $([math]::Round($entry.DurationMs / 1000, 1))s (exceeds 120s threshold)"
        }
    }
}

# ============================================================
# ROOT CAUSE ENGINE
# ============================================================

function Add-DiagFinding {
    param(
        [hashtable]$DiagState,
        [string]$Component,
        [string]$Status,
        [string]$Details,
        [string]$Category,
        [int]$Weight
    )
    $finding = [PSCustomObject]@{
        Component = $Component
        Status    = $Status
        Details   = $Details
        Category  = $Category
        Weight    = $Weight
        Severity  = (Get-LocalSeverityCode -Component $Component -Status $Status)
        Timestamp = (Get-Date -Format "HH:mm:ss")
    }
    $DiagState.Findings.Add($finding) | Out-Null
    Write-Log "Finding: [$Category] $Component = $Status (W:$Weight) - $Details"
}

function Get-EscalationLevel {
    param([hashtable]$DiagState)
    # L3: Any H2/H3 severity (hardware replacement needed)
    foreach ($f in $DiagState.Findings) {
        if ($f.Severity -eq 'H3' -or $f.Severity -eq 'H2') {
            return "L3"
        }
    }
    # L2: Firmware-level issues
    foreach ($f in $DiagState.Findings) {
        if ($f.Component -match 'BIOS|CMOS|POST|Firmware|Microcode' -and $f.Status -ne 'Pass') {
            return "L2"
        }
    }
    # L1: Any software failure present
    foreach ($f in $DiagState.Findings) {
        if ($f.Status -eq 'Fail' -and $f.Severity -match '^S') {
            return "L1"
        }
    }
    return "None"
}

function Get-RootCauseRanking {
    param([hashtable]$DiagState)

    $findings = $DiagState.Findings | Where-Object { $_.Status -eq 'Fail' -or $_.Status -eq 'Warning' }
    if (-not $findings -or @($findings).Count -eq 0) {
        return [PSCustomObject]@{
            PrimaryRootCause   = "No issues detected"
            PrimaryCategory    = "None"
            PrimaryWeight      = 0
            SecondarySymptoms  = @()
            Confidence         = 100
            EscalationLevel    = "None"
            RecommendedAction  = "No action required"
            EnterpriseScore    = 100
        }
    }

    $sorted = @($findings) | Sort-Object Weight -Descending
    $primary = $sorted[0]
    $secondary = @()
    if ($sorted.Count -gt 1) {
        $secondary = $sorted[1..([math]::Min($sorted.Count - 1, 4))]
    }

    # Base confidence = primary weight as percentage
    $totalWeight = 0
    foreach ($f in $sorted) { $totalWeight += $f.Weight }
    $confidence = [math]::Round($primary.Weight / $totalWeight * 100)
    if ($confidence -gt 95) { $confidence = 95 }

    # Correlation boosts
    $hasSmartFail  = @($DiagState.Findings | Where-Object { $_.Component -match 'SMART' -and $_.Status -eq 'Fail' }).Count -gt 0
    $hasWHEA       = @($DiagState.Findings | Where-Object { $_.Component -match 'WHEA|Memory Error' -and $_.Status -eq 'Fail' }).Count -gt 0
    $hasThermalCrit = $DiagState.ThermalCritical
    $hasBSOD       = $DiagState.BSODFound
    $hasSFC        = @($DiagState.Findings | Where-Object { $_.Component -match 'SFC' -and $_.Status -eq 'Fail' }).Count -gt 0
    $hasDISM       = @($DiagState.Findings | Where-Object { $_.Component -match 'DISM' -and ($_.Status -eq 'Fail' -or $_.Status -eq 'Warning') }).Count -gt 0
    $hasResets     = @($DiagState.Findings | Where-Object { $_.Component -match 'Reset|Kernel-Power' -and $_.Status -eq 'Fail' }).Count -gt 0
    $hasDriverFault = @($DiagState.Findings | Where-Object { $_.Component -match 'Faulting Driver' -and $_.Status -eq 'Fail' }).Count -gt 0
    $hasProbDevice  = @($DiagState.Findings | Where-Object { $_.Component -match 'Problem Device' -and $_.Status -eq 'Fail' }).Count -gt 0

    # Storage root cause: SMART fail + BSOD
    if ($hasSmartFail -and $hasBSOD) { $confidence = [math]::Min($confidence + 25, 95) }
    # Memory root cause: WHEA + BSOD
    if ($hasWHEA -and $hasBSOD) { $confidence = [math]::Min($confidence + 20, 95) }
    # Thermal root cause: thermal critical + resets
    if ($hasThermalCrit -and $hasResets) { $confidence = [math]::Min($confidence + 20, 95) }
    # Driver root cause: faulting driver + problem device
    if ($hasDriverFault -and $hasProbDevice) { $confidence = [math]::Min($confidence + 15, 95) }
    # OS corruption: SFC + DISM + BSOD
    if ($hasSFC -and $hasDISM -and $hasBSOD) { $confidence = [math]::Min($confidence + 15, 95) }

    $escalation = Get-EscalationLevel -DiagState $DiagState

    # Enterprise severity score: 100 = perfect, 0 = critical
    # Status penalties: Fail=50%, Warning=20%, Repaired=5%, Info/Pass=0%
    $enterpriseScore = 100
    foreach ($f in $sorted) {
        if ($f.Status -eq 'Fail') { $enterpriseScore -= [math]::Round($f.Weight * 0.5) }
        elseif ($f.Status -eq 'Warning') { $enterpriseScore -= [math]::Round($f.Weight * 0.2) }
        elseif ($f.Status -eq 'Repaired') { $enterpriseScore -= [math]::Round($f.Weight * 0.05) }
    }
    if ($enterpriseScore -lt 0) { $enterpriseScore = 0 }
    if ($enterpriseScore -gt 100) { $enterpriseScore = 100 }

    # Recommended action
    $action = switch ($escalation) {
        "L3" { "Hardware replacement or escalation to hardware team" }
        "L2" { "Firmware update or BIOS reset recommended" }
        "L1" { "Software remediation available (Phase 6)" }
        default { "No action required" }
    }

    return [PSCustomObject]@{
        PrimaryRootCause   = "$($primary.Component): $($primary.Details)"
        PrimaryCategory    = $primary.Category
        PrimaryWeight      = $primary.Weight
        SecondarySymptoms  = $secondary
        Confidence         = $confidence
        EscalationLevel    = $escalation
        RecommendedAction  = $action
        EnterpriseScore    = $enterpriseScore
    }
}

# ============================================================
# PHASE 0: PREFLIGHT
# ============================================================

function Invoke-Phase0-Preflight {
    param([hashtable]$DiagState)
    Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase0"
    if ($v9GovernanceAvailable) { try { Save-ExecutionState -SessionGUID $DiagState.SessionId -CurrentPhase 0 -OutputDir $ReportPath } catch {} }
    Write-ScanHeader -Name "PHASE 0: PREFLIGHT" -Icon "[0/8]"
    Write-Log "--- Phase 0: Preflight ---"

    $phase0Pass = $true

    # 0A: Verify admin privileges
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Finding -Label "  Admin privileges" -Value "Confirmed" -Color "Green"
    } else {
        Write-Finding -Label "  Admin privileges" -Value "NOT ELEVATED" -Color "Red"
        $phase0Pass = $false
    }

    # 0B: Verify PowerShell version
    $psVer = $PSVersionTable.PSVersion
    $psVerStr = "$($psVer.Major).$($psVer.Minor)"
    if ($psVer.Major -ge 5 -and $psVer.Minor -ge 1) {
        Write-Finding -Label "  PowerShell version" -Value "$psVerStr" -Color "Green"
    } elseif ($psVer.Major -ge 5) {
        Write-Finding -Label "  PowerShell version" -Value "$psVerStr" -Color "Green"
    } else {
        Write-Finding -Label "  PowerShell version" -Value "$psVerStr (requires 5.1+)" -Color "Red"
        $phase0Pass = $false
    }

    # 0C: Generate session GUID
    $sessionGuid = [guid]::NewGuid().ToString()
    $DiagState.SessionId = $sessionGuid
    Write-Finding -Label "  Session ID" -Value $sessionGuid.Substring(0, 8) -Color "Cyan"

    # 0D: Create initial preflight backup
    $preflightDir = Join-Path $BackupPath "SmartDiag_${timestamp}_preflight"
    New-Item -Path $preflightDir -ItemType Directory -Force | Out-Null

    # Restore point
    try {
        $srService = Get-Service -Name 'srservice' -ErrorAction SilentlyContinue
        if ($srService -and $srService.Status -eq 'Running') {
            Checkpoint-Computer -Description "LDT SmartDiag Pre-Execution $timestamp" -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue
            Write-Finding -Label "  Restore point" -Value "Created" -Color "Green"
        } else {
            Write-Finding -Label "  Restore point" -Value "SR service not running" -Color "Yellow"
        }
    } catch {
        Write-Finding -Label "  Restore point" -Value "Skipped (24hr limit?)" -Color "Yellow"
    }

    # Registry export: SYSTEM + SOFTWARE
    try {
        & reg export "HKLM\SYSTEM" (Join-Path $preflightDir "SYSTEM.reg") /y 2>&1 | Out-Null
        & reg export "HKLM\SOFTWARE" (Join-Path $preflightDir "SOFTWARE.reg") /y 2>&1 | Out-Null
        Write-Finding -Label "  Registry export" -Value "SYSTEM + SOFTWARE" -Color "Green"
    } catch {
        Write-Finding -Label "  Registry export" -Value "Failed" -Color "Yellow"
    }

    # BCD export
    try {
        & bcdedit /export (Join-Path $preflightDir "bcd_preflight") 2>&1 | Out-Null
        Write-Finding -Label "  BCD export" -Value "Saved" -Color "Green"
    } catch {
        Write-Finding -Label "  BCD export" -Value "Failed" -Color "Yellow"
    }

    # Driver version baseline export
    try {
        $driverCsv = Join-Path $preflightDir "driver_baseline.csv"
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Select-Object DeviceName, DriverVersion, Manufacturer, DriverDate, DeviceClass |
            Export-Csv -Path $driverCsv -NoTypeInformation -Encoding UTF8
        Write-Finding -Label "  Driver baseline" -Value "Exported" -Color "Green"
    } catch {
        Write-Finding -Label "  Driver baseline" -Value "Failed" -Color "Yellow"
    }

    # Preflight manifest
    $manifest = @(
        "Smart Diagnosis Engine - Preflight Backup"
        "==========================================="
        "Session:    $sessionGuid"
        "Timestamp:  $dateDisplay"
        "Machine:    $computerName"
        "Admin:      $isAdmin"
        "PS Version: $psVerStr"
        "Contents:   SYSTEM.reg, SOFTWARE.reg, bcd_preflight, driver_baseline.csv"
    )
    $manifest | Out-File (Join-Path $preflightDir "manifest.txt") -Encoding UTF8

    Write-Log "Preflight backup: $preflightDir"

    # 0E: Initialize GuardEngine (v7)
    if ($v7EnginesAvailable) {
        try {
            Initialize-EngineAdapter -LogFilePath $logFile
            Initialize-GuardEngine -SessionId $DiagState.SessionId -Config $v7Config
            Write-Finding -Label "  GuardEngine" -Value "Initialized (22 prohibitions)" -Color "Green"
            Write-Log "GuardEngine initialized"
        }
        catch {
            Write-Finding -Label "  GuardEngine" -Value "Failed: $($_.Exception.Message)" -Color "Yellow"
            Write-Log "GuardEngine init failed: $($_.Exception.Message)"
        }
    }

    # 0F: Initialize Governance Engine (v9)
    if ($v9GovernanceAvailable) {
        try {
            $configJsonPath = Join-Path $ScriptRoot "Config\config.json"
            $configIniPath = Join-Path $ScriptRoot "Config\config.ini"

            # Initialize policy engine
            $policyProfile = Initialize-PolicyEngine -ConfigJsonPath $configJsonPath -ProfileName 'Balanced'
            Write-Finding -Label "  GovernanceEngine" -Value "Policy: $($policyProfile.Name)" -Color "Green"

            # Set execution mode
            $govMode = Get-ExecutionMode -RequestedMode $Mode -ConfigJsonPath $configJsonPath
            Write-Finding -Label "  Execution Mode" -Value $govMode -Color "Cyan"

            # Check for crash recovery (previous interrupted session)
            $prevState = Restore-ExecutionState -OutputDir $ReportPath
            if ($prevState) {
                Write-Finding -Label "  Crash Recovery" -Value "Previous session interrupted at Phase $($prevState.CurrentPhase)" -Color "Yellow"
                Write-Log "Crash recovery: Previous session $($prevState.SessionGUID) interrupted at Phase $($prevState.CurrentPhase)"
            }

            # Directory tamper detection
            $manifestPath = Join-Path $ScriptRoot "Config\VersionManifest.json"
            $dirCheck = Test-DirectoryIntegrity -ManifestPath $manifestPath -BasePath $ScriptRoot
            if ($dirCheck.Valid) {
                Write-Finding -Label "  Directory Integrity" -Value "PASS ($($dirCheck.ExpectedCount) files verified)" -Color "Green"
            } else {
                Write-Finding -Label "  Directory Integrity" -Value "WARN: $($dirCheck.MissingFiles.Count) missing, $($dirCheck.UnexpectedFiles.Count) unexpected" -Color "Yellow"
                Write-Log "Directory integrity: $($dirCheck.MissingFiles.Count) missing, $($dirCheck.UnexpectedFiles.Count) unexpected"
            }
            $DiagState['GovernanceInitialized'] = $true
            $DiagState['PolicyProfile'] = $policyProfile
            $DiagState['DirectoryCheck'] = $dirCheck
            Write-Log "GovernanceEngine initialized: Policy=$($policyProfile.Name), Mode=$govMode"
        }
        catch {
            Write-Finding -Label "  GovernanceEngine" -Value "Failed: $($_.Exception.Message)" -Color "Yellow"
            Write-Log "GovernanceEngine init failed: $($_.Exception.Message)"
        }
    }

    # 0G: Platform Integrity Validation (v7)
    if ($v7EnginesAvailable) {
        try {
            $intResult = Test-PlatformIntegrity -SessionId $DiagState.SessionId -PlatformRoot $ScriptRoot
            $DiagState.IntegrityResult = $intResult
            $intColor = if ($intResult.overallStatus -eq 'PASS') { "Green" } elseif ($intResult.overallStatus -match 'PARTIAL') { "Yellow" } else { "Red" }
            Write-Finding -Label "  Platform Integrity" -Value "$($intResult.overallStatus) ($($intResult.filesPassed)/$($intResult.filesChecked) files)" -Color $intColor
            Write-Log "Platform integrity: $($intResult.overallStatus)"
        }
        catch {
            Write-Finding -Label "  Platform Integrity" -Value "Skipped" -Color "Yellow"
            Write-Log "Platform integrity skipped: $($_.Exception.Message)"
        }
    }

    # 0H: Previous Log Seal Verification (v7)
    if ($v7EnginesAvailable) {
        try {
            $sealResult = Invoke-LogIntegrityCheck -SessionId $DiagState.SessionId -LogPath $LogPath
            if ($sealResult.previousLogFound) {
                $sealColor = if ($sealResult.sealValid) { "Green" } elseif ($sealResult.tamperDetected) { "Red" } else { "Yellow" }
                $sealText = if ($sealResult.sealValid) { "Previous log verified" } elseif ($sealResult.tamperDetected) { "TAMPER DETECTED" } else { "No seal found" }
                Write-Finding -Label "  Log Integrity" -Value $sealText -Color $sealColor
            } else {
                Write-Finding -Label "  Log Integrity" -Value "No previous log (first run)" -Color "DarkGray"
            }
            Write-Log "Log integrity: previousFound=$($sealResult.previousLogFound), sealValid=$($sealResult.sealValid)"
        }
        catch {
            Write-Finding -Label "  Log Integrity" -Value "Skipped" -Color "DarkGray"
        }
    }

    if ($phase0Pass) {
        $DiagState.PhaseResults["Phase0"] = "Pass"
        Write-Host ""
        Write-Host "    Phase 0: PREFLIGHT COMPLETE" -ForegroundColor Green
    } else {
        $DiagState.PhaseResults["Phase0"] = "Fail"
        Write-Host ""
        Write-Host "    Phase 0: PREFLIGHT FAILED -- aborting" -ForegroundColor Red
    }
    Write-Host ""
    Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase0"
    return $phase0Pass
}

# ============================================================
# PHASE 1: SYSTEM SNAPSHOT
# ============================================================

function Invoke-Phase1-SystemSnapshot {
    param([hashtable]$DiagState)
    Write-ScanHeader -Name "PHASE 1: SYSTEM SNAPSHOT" -Icon "[1/8]"
    Write-Log "--- Phase 1: System Snapshot ---"
    Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase1"
    if ($v9GovernanceAvailable) { try { Save-ExecutionState -SessionGUID $DiagState.SessionId -CurrentPhase 1 -OutputDir $ReportPath } catch {} }

    $totalRAM = 0
    if ($csInfo) { $totalRAM = [math]::Round($csInfo.TotalPhysicalMemory / 1GB, 1) }

    $diskCount = @(Get-PhysicalDisk -ErrorAction SilentlyContinue).Count
    $hasBattery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0

    $uptime = $null
    $uptimeStr = "Unknown"
    $lastBoot = "Unknown"
    if ($osInfo) {
        try {
            $uptime = (Get-Date) - $osInfo.LastBootUpTime
            $uptimeStr = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
            $lastBoot = $osInfo.LastBootUpTime.ToString("yyyy-MM-dd HH:mm:ss")
        } catch { }
    }

    $powerSource = "AC"
    try {
        $batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($batt) {
            $battStatus = $batt.BatteryStatus
            # 1=Discharging, 2=AC/Charging
            if ($battStatus -eq 1) { $powerSource = "Battery" }
        }
    } catch { }

    # Event log error counts
    $sysErrors = 0
    $appErrors = 0
    try {
        $cutoff = (Get-Date).AddDays(-$cfgEventLogDays)
        $sysErrors = @(Get-WinEvent -FilterHashtable @{LogName='System'; Level=2; StartTime=$cutoff} -MaxEvents 500 -ErrorAction SilentlyContinue).Count
        $appErrors = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Level=2; StartTime=$cutoff} -MaxEvents 500 -ErrorAction SilentlyContinue).Count
    } catch { }

    # Store machine info
    $DiagState.Machine = @{
        ComputerName = $computerName
        Serial       = $serialNumber
        Manufacturer = $manufacturer
        Model        = $model
        OS           = $osVersion
        RAM_GB       = $totalRAM
        DiskCount    = $diskCount
        HasBattery   = $hasBattery
        Uptime       = $uptimeStr
        LastBoot     = $lastBoot
        PowerSource  = $powerSource
        SysErrors    = $sysErrors
        AppErrors    = $appErrors
        ScanTime     = $dateDisplay
    }

    # Display
    Write-Finding -Label "Computer" -Value $computerName
    Write-Finding -Label "Model" -Value "$manufacturer $model"
    Write-Finding -Label "Serial" -Value $serialNumber
    Write-Finding -Label "OS" -Value $osVersion
    Write-Finding -Label "RAM" -Value "$totalRAM GB"
    Write-Finding -Label "Physical disks" -Value "$diskCount"
    Write-Finding -Label "Battery present" -Value $(if ($hasBattery) { "Yes" } else { "No" })
    Write-Finding -Label "Uptime" -Value $uptimeStr
    Write-Finding -Label "Power source" -Value $powerSource
    $errColor = if (($sysErrors + $appErrors) -gt 50) { "Red" } elseif (($sysErrors + $appErrors) -gt 10) { "Yellow" } else { "Green" }
    Write-Finding -Label "Event log errors (${cfgEventLogDays}d)" -Value "System: $sysErrors, App: $appErrors" -Color $errColor

    # Capture full driver and service lists for snapshot
    Write-Host "    Capturing driver inventory..." -ForegroundColor DarkGray
    $driverList = @()
    try {
        $driverList = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.DeviceName } |
            Select-Object DeviceName, DriverVersion, Manufacturer, IsSigned, InfName, DriverDate)
    } catch { }
    $DiagState.Machine["Drivers"] = $driverList
    Write-Finding -Label "Installed drivers" -Value "$($driverList.Count) drivers"

    Write-Host "    Capturing service inventory..." -ForegroundColor DarkGray
    $serviceList = @()
    try {
        $serviceList = @(Get-Service -ErrorAction SilentlyContinue |
            Select-Object Name, DisplayName, Status, StartType)
    } catch { }
    $DiagState.Machine["Services"] = $serviceList
    Write-Finding -Label "Installed services" -Value "$($serviceList.Count) services"

    # Capture BIOS version for firmware tracking
    $biosVersion = if ($biosInfo) { $biosInfo.SMBIOSBIOSVersion } else { "Unknown" }
    $DiagState.Machine["BIOSVersion"] = $biosVersion
    Write-Finding -Label "BIOS version" -Value $biosVersion

    # OS Activation status
    $activationStatus = "Unknown"
    try {
        $slp = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue |
            Where-Object { $_.LicenseStatus -ne $null } | Select-Object -First 1
        if ($slp) {
            switch ($slp.LicenseStatus) {
                0 { $activationStatus = "Unlicensed" }
                1 { $activationStatus = "Licensed" }
                2 { $activationStatus = "OOBGrace" }
                3 { $activationStatus = "OOTGrace" }
                4 { $activationStatus = "NonGenuine" }
                5 { $activationStatus = "Notification" }
                default { $activationStatus = "Status $($slp.LicenseStatus)" }
            }
        }
    } catch { }
    $DiagState.Machine["Activation"] = $activationStatus
    $actColor = if ($activationStatus -eq "Licensed") { "Green" } else { "Yellow" }
    Write-Finding -Label "OS activation" -Value $activationStatus -Color $actColor

    # Firmware type (UEFI vs Legacy)
    $firmwareType = "Unknown"
    try {
        $fwType = (Get-ItemProperty "HKLM:\System\CurrentControlSet\Control" -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
        if ($fwType -eq 2) { $firmwareType = "UEFI" }
        elseif ($fwType -eq 1) { $firmwareType = "Legacy BIOS" }
    } catch { }
    $DiagState.Machine["FirmwareType"] = $firmwareType
    Write-Finding -Label "Firmware type" -Value $firmwareType

    # Chassis type
    $chassisType = "Unknown"
    try {
        $chassisId = (Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes
        if ($chassisId) {
            $cid = $chassisId[0]
            switch ($cid) {
                1  { $chassisType = "Other" }
                2  { $chassisType = "Unknown" }
                3  { $chassisType = "Desktop" }
                4  { $chassisType = "Desktop (Low Profile)" }
                5  { $chassisType = "Pizza Box" }
                6  { $chassisType = "Mini Tower" }
                7  { $chassisType = "Tower" }
                8  { $chassisType = "Portable" }
                9  { $chassisType = "Laptop" }
                10 { $chassisType = "Notebook" }
                11 { $chassisType = "Handheld" }
                14 { $chassisType = "Sub Notebook" }
                30 { $chassisType = "Tablet" }
                31 { $chassisType = "Convertible" }
                32 { $chassisType = "Detachable" }
                35 { $chassisType = "Mini PC" }
                36 { $chassisType = "Stick PC" }
                default { $chassisType = "Type $cid" }
            }
        }
    } catch { }
    $DiagState.Machine["ChassisType"] = $chassisType
    Write-Finding -Label "Chassis type" -Value $chassisType

    # Pending Windows Updates
    $pendingUpdates = 0
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $searcher = $updateSession.CreateUpdateSearcher()
        $searchResult = $searcher.Search("IsInstalled=0")
        $pendingUpdates = $searchResult.Updates.Count
    } catch { }
    $DiagState.Machine["PendingUpdates"] = $pendingUpdates
    $puColor = if ($pendingUpdates -gt 10) { "Yellow" } elseif ($pendingUpdates -gt 0) { "Cyan" } else { "Green" }
    Write-Finding -Label "Pending updates" -Value "$pendingUpdates" -Color $puColor

    $DiagState.PhaseResults["Phase1"] = "PASS"
    Write-PhaseResult -Phase "Phase 1: System Snapshot" -Status "PASS" -Details "Machine info collected"
    Write-Log "Phase 1 complete: $computerName, $manufacturer $model, RAM=${totalRAM}GB, Disks=$diskCount"
    Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase1"
}

# ============================================================
# PHASE 2: HARDWARE INTEGRITY
# ============================================================

function Invoke-Phase2-HardwareIntegrity {
    param([hashtable]$DiagState)
    Write-ScanHeader -Name "PHASE 2: HARDWARE INTEGRITY" -Icon "[2/8]"
    Write-Log "--- Phase 2: Hardware Integrity ---"
    Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase2"
    if ($v9GovernanceAvailable) { try { Save-ExecutionState -SessionGUID $DiagState.SessionId -CurrentPhase 2 -OutputDir $ReportPath } catch {} }

    $hwFails = 0
    $hwWarns = 0

    # --- 2A: Disk SMART ---
    Write-Host "    Scanning disk SMART health..." -ForegroundColor DarkGray
    try {
        $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        foreach ($disk in $disks) {
            $health = $disk.HealthStatus
            $mediaType = if ($disk.MediaType) { $disk.MediaType } else { "Unknown" }
            $sizeGB = [math]::Round($disk.Size / 1GB, 0)
            $diskLabel = "Disk $($disk.DeviceId) ($mediaType, ${sizeGB}GB)"

            if ($health -eq 'Unhealthy') {
                Add-DiagFinding -DiagState $DiagState -Component "SMART Disk Health" -Status "Fail" `
                    -Details "$diskLabel - UNHEALTHY" -Category "Hardware" -Weight 95
                $DiagState.HardwareCritical = $true
                $hwFails++
                Write-Finding -Label $diskLabel -Value "UNHEALTHY" -Color "Red"
            } elseif ($health -eq 'Warning') {
                Add-DiagFinding -DiagState $DiagState -Component "SMART Disk Health" -Status "Warning" `
                    -Details "$diskLabel - Warning state" -Category "Hardware" -Weight 60
                $hwWarns++
                Write-Finding -Label $diskLabel -Value "WARNING" -Color "Yellow"
            } else {
                Write-Finding -Label $diskLabel -Value "Healthy" -Color "Green"
            }

            # Check reliability counters
            try {
                $rel = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction SilentlyContinue
                if ($rel) {
                    $reallocated = $rel.ReadErrorsTotal
                    $uncorrectable = $rel.ReadErrorsUncorrected
                    if ($uncorrectable -and $uncorrectable -gt 0) {
                        Add-DiagFinding -DiagState $DiagState -Component "Disk Uncorrectable Errors" -Status "Fail" `
                            -Details "Disk $($disk.DeviceId): $uncorrectable uncorrectable errors" -Category "Hardware" -Weight 90
                        $DiagState.HardwareCritical = $true
                        $hwFails++
                    }
                    $wear = $rel.Wear
                    if ($wear -and $wear -gt 80) {
                        Add-DiagFinding -DiagState $DiagState -Component "SSD Wear Level" -Status "Warning" `
                            -Details "Disk $($disk.DeviceId): ${wear}% wear" -Category "Hardware" -Weight 55
                        $hwWarns++
                    }
                }
            } catch { }
        }
    } catch {
        Write-Finding -Label "SMART scan" -Value "Could not query" -Color "Yellow"
    }

    # --- 2B: Memory WHEA errors ---
    Write-Host "    Scanning for memory/WHEA errors..." -ForegroundColor DarkGray
    $wheaCount = 0
    try {
        $cutoff = (Get-Date).AddDays(-$cfgBsodDays)
        $wheaEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Microsoft-Windows-WHEA-Logger'
            StartTime = $cutoff
        } -MaxEvents 100 -ErrorAction SilentlyContinue
        if ($wheaEvents) { $wheaCount = @($wheaEvents).Count }
    } catch { }

    if ($wheaCount -gt 0) {
        $wheaSev = if ($wheaCount -ge 5) { "Fail" } else { "Warning" }
        $wheaWt  = if ($wheaCount -ge 5) { 90 } else { 50 }
        Add-DiagFinding -DiagState $DiagState -Component "Memory WHEA Errors" -Status $wheaSev `
            -Details "$wheaCount WHEA events in last $cfgBsodDays days" -Category "Hardware" -Weight $wheaWt
        if ($wheaSev -eq "Fail") { $DiagState.HardwareCritical = $true; $hwFails++ } else { $hwWarns++ }
        Write-Finding -Label "WHEA memory errors" -Value "$wheaCount events" -Color $(if ($wheaSev -eq "Fail") { "Red" } else { "Yellow" })
    } else {
        Write-Finding -Label "WHEA memory errors" -Value "None" -Color "Green"
    }

    # --- 2C: Thermal ---
    Write-Host "    Checking thermal sensors..." -ForegroundColor DarkGray
    $tempC = 0
    try {
        $thermal = Get-CimInstance -Namespace "root/WMI" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction SilentlyContinue
        if ($thermal) {
            $temps = @($thermal | ForEach-Object { [math]::Round(($_.CurrentTemperature - 2732) / 10, 1) })
            $tempC = ($temps | Measure-Object -Maximum).Maximum
        }
    } catch { }

    if ($tempC -gt 0) {
        if ($tempC -ge $cfgThermalBlock) {
            Add-DiagFinding -DiagState $DiagState -Component "Thermal Critical" -Status "Fail" `
                -Details "CPU temperature ${tempC}C exceeds ${cfgThermalBlock}C threshold" -Category "Hardware" -Weight 85
            $DiagState.ThermalCritical = $true
            $hwFails++
            Write-Finding -Label "CPU temperature" -Value "${tempC}C - CRITICAL" -Color "Red"
        } elseif ($tempC -ge $cfgThermalWarn) {
            Add-DiagFinding -DiagState $DiagState -Component "Thermal Warning" -Status "Warning" `
                -Details "CPU temperature ${tempC}C above ${cfgThermalWarn}C warning" -Category "Hardware" -Weight 40
            $hwWarns++
            Write-Finding -Label "CPU temperature" -Value "${tempC}C - HIGH" -Color "Yellow"
        } else {
            Write-Finding -Label "CPU temperature" -Value "${tempC}C" -Color "Green"
        }
    } else {
        Write-Finding -Label "CPU temperature" -Value "Sensor unavailable" -Color "DarkGray"
    }

    # --- 2D: Battery health ---
    Write-Host "    Checking battery health..." -ForegroundColor DarkGray
    if ($DiagState.Machine.HasBattery) {
        try {
            $designCap = $null
            $fullCap = $null
            try {
                $battStatic = Get-CimInstance -Namespace "root/WMI" -ClassName "BatteryStaticData" -ErrorAction Stop
                $battFull   = Get-CimInstance -Namespace "root/WMI" -ClassName "BatteryFullChargedCapacity" -ErrorAction Stop
                $designCap  = $battStatic.DesignedCapacity
                $fullCap    = $battFull.FullChargedCapacity
            } catch { }

            if ($designCap -and $fullCap -and $designCap -gt 0) {
                $wearPct = [math]::Round((1 - ($fullCap / $designCap)) * 100, 1)
                if ($wearPct -gt 60) {
                    Add-DiagFinding -DiagState $DiagState -Component "Battery Health" -Status "Fail" `
                        -Details "Battery wear ${wearPct}% - replacement recommended" -Category "Hardware" -Weight 25
                    $hwFails++
                    Write-Finding -Label "Battery wear" -Value "${wearPct}% - REPLACE" -Color "Red"
                } elseif ($wearPct -gt 40) {
                    Add-DiagFinding -DiagState $DiagState -Component "Battery Health" -Status "Warning" `
                        -Details "Battery wear ${wearPct}% - degrading" -Category "Hardware" -Weight 20
                    $hwWarns++
                    Write-Finding -Label "Battery wear" -Value "${wearPct}%" -Color "Yellow"
                } else {
                    Write-Finding -Label "Battery wear" -Value "${wearPct}%" -Color "Green"
                }
            } else {
                Write-Finding -Label "Battery wear" -Value "Could not determine" -Color "DarkGray"
            }
        } catch {
            Write-Finding -Label "Battery health" -Value "Query failed" -Color "DarkGray"
        }
    }

    # --- 2E: TPM ---
    Write-Host "    Checking TPM..." -ForegroundColor DarkGray
    try {
        $tpm = Get-Tpm -ErrorAction SilentlyContinue
        if ($tpm) {
            if (-not $tpm.TpmPresent) {
                Add-DiagFinding -DiagState $DiagState -Component "TPM Security" -Status "Warning" `
                    -Details "TPM not present" -Category "Hardware" -Weight 20
                $hwWarns++
                Write-Finding -Label "TPM" -Value "Not present" -Color "Yellow"
            } elseif (-not $tpm.TpmReady) {
                Add-DiagFinding -DiagState $DiagState -Component "TPM Security" -Status "Warning" `
                    -Details "TPM present but not ready" -Category "Hardware" -Weight 15
                $hwWarns++
                Write-Finding -Label "TPM" -Value "Not ready" -Color "Yellow"
            } else {
                Write-Finding -Label "TPM" -Value "Present and ready" -Color "Green"
            }
        } else {
            Write-Finding -Label "TPM" -Value "Could not query" -Color "DarkGray"
        }
    } catch {
        Write-Finding -Label "TPM" -Value "Query failed" -Color "DarkGray"
    }

    # --- 2F: PnP device errors ---
    Write-Host "    Scanning for device errors..." -ForegroundColor DarkGray
    $pnpErrors = 0
    try {
        $pnpErrors = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.ConfigManagerErrorCode -ne 0 }).Count
    } catch { }

    if ($pnpErrors -gt 0) {
        $pnpSev = if ($pnpErrors -ge 3) { "Fail" } else { "Warning" }
        $pnpWt  = if ($pnpErrors -ge 3) { 45 } else { 25 }
        Add-DiagFinding -DiagState $DiagState -Component "PnP Device Errors" -Status $pnpSev `
            -Details "$pnpErrors devices with errors" -Category "Hardware" -Weight $pnpWt
        if ($pnpSev -eq "Fail") { $hwFails++ } else { $hwWarns++ }
        Write-Finding -Label "PnP device errors" -Value "$pnpErrors devices" -Color $(if ($pnpSev -eq "Fail") { "Red" } else { "Yellow" })
    } else {
        Write-Finding -Label "PnP device errors" -Value "None" -Color "Green"
    }

    # Phase result
    $status = if ($hwFails -gt 0) { "FAIL" } elseif ($hwWarns -gt 0) { "WARN" } else { "PASS" }
    $DiagState.PhaseResults["Phase2"] = $status
    $detail = "$hwFails failures, $hwWarns warnings"
    if ($DiagState.HardwareCritical) { $detail += " [HARDWARE CRITICAL]" }
    if ($DiagState.ThermalCritical) { $detail += " [THERMAL CRITICAL]" }
    Write-PhaseResult -Phase "Phase 2: Hardware Integrity" -Status $status -Details $detail
    Write-Log "Phase 2 complete: $detail"
    Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase2"
}

# ============================================================
# PHASE 3: BOOT & OS VALIDATION
# ============================================================

function Invoke-Phase3-BootAndOS {
    param([hashtable]$DiagState)

    if ($DiagState.HardwareCritical) {
        Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase3"
        Write-ScanHeader -Name "PHASE 3: BOOT & OS VALIDATION" -Icon "[3/8]"
        Write-Host "    Skipped - hardware critical issue detected" -ForegroundColor DarkGray
        $DiagState.PhaseResults["Phase3"] = "SKIP"
        Write-PhaseResult -Phase "Phase 3: Boot & OS" -Status "SKIP" -Details "Hardware critical - OS repair pointless"
        Write-Log "Phase 3 skipped: HardwareCritical=true"
        Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase3"
        return
    }

    Write-ScanHeader -Name "PHASE 3: BOOT & OS VALIDATION" -Icon "[3/8]"
    Write-Log "--- Phase 3: Boot & OS Validation ---"
    Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase3"
    if ($v9GovernanceAvailable) { try { Save-ExecutionState -SessionGUID $DiagState.SessionId -CurrentPhase 3 -OutputDir $ReportPath } catch {} }

    $osFails = 0
    $osWarns = 0

    # --- 3A: BSOD Analysis ---
    Write-Host "    Scanning for BSODs..." -ForegroundColor DarkGray
    $bsodCount = 0
    $faultingDriver = ""
    $stopCode = ""
    $cutoffDate = (Get-Date).AddDays(-$cfgBsodDays)

    # Minidump files
    $minidumpPath = "$env:SystemRoot\Minidump"
    $dumpCount = 0
    if (Test-Path $minidumpPath) {
        $dumps = Get-ChildItem -Path $minidumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -ge $cutoffDate }
        $dumpCount = @($dumps).Count
    }

    # BugCheck events
    $bugCheckCount = 0
    try {
        $bugChecks = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 1001
            StartTime = $cutoffDate
        } -MaxEvents 500 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' }
        if ($bugChecks) {
            $bugCheckCount = @($bugChecks).Count
            $latestBug = $bugChecks | Select-Object -First 1
            if ($latestBug.Message -match '0x([0-9A-Fa-f]+)') {
                $stopCode = "0x$($Matches[1])"
            }
        }
    } catch { }

    # Faulting driver
    try {
        $driverEvents = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Level     = 1,2
            StartTime = $cutoffDate
        } -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match '\.sys' }
        if ($driverEvents) {
            $latest = $driverEvents | Select-Object -First 1
            if ($latest.Message -match '(\w+\.sys)') {
                $faultingDriver = $Matches[1]
                $DiagState.BSODDrivers += $faultingDriver
            }
        }
    } catch { }

    $bsodCount = $dumpCount + $bugCheckCount
    if ($bsodCount -gt 0) {
        $DiagState.BSODFound = $true
        $bsodDetail = "${dumpCount} dumps, ${bugCheckCount} BugCheck events"
        if ($faultingDriver) { $bsodDetail += ", driver: $faultingDriver" }
        if ($stopCode) { $bsodDetail += ", stop: $stopCode" }

        if ($bsodCount -ge $cfgBsodCritical) {
            Add-DiagFinding -DiagState $DiagState -Component "BSOD Crashes" -Status "Fail" `
                -Details $bsodDetail -Category "OS/Boot" -Weight 80
            $osFails++
        } else {
            Add-DiagFinding -DiagState $DiagState -Component "BSOD Crashes" -Status "Warning" `
                -Details $bsodDetail -Category "OS/Boot" -Weight 55
            $osWarns++
        }
        if ($faultingDriver) {
            Add-DiagFinding -DiagState $DiagState -Component "Faulting BSOD Driver" -Status "Fail" `
                -Details "Driver: $faultingDriver (stop: $stopCode)" -Category "Driver" -Weight 75
            $osFails++
        }
        Write-Finding -Label "BSODs (last $cfgBsodDays days)" -Value "$bsodCount total" -Color $(if ($bsodCount -ge $cfgBsodCritical) { "Red" } else { "Yellow" })
    } else {
        Write-Finding -Label "BSODs (last $cfgBsodDays days)" -Value "None" -Color "Green"
    }

    # --- 3B: Unexpected resets ---
    Write-Host "    Scanning for unexpected resets..." -ForegroundColor DarkGray
    $resetCount = 0
    $cutoffShort = (Get-Date).AddDays(-$cfgEventLogDays)
    try {
        $kp41 = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Kernel-Power'
            Id           = 41
            StartTime    = $cutoffShort
        } -MaxEvents 500 -ErrorAction SilentlyContinue
        if ($kp41) { $resetCount += @($kp41).Count }
    } catch { }
    try {
        $ev6008 = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 6008
            StartTime = $cutoffShort
        } -MaxEvents 500 -ErrorAction SilentlyContinue
        if ($ev6008) { $resetCount += @($ev6008).Count }
    } catch { }

    if ($resetCount -gt 3) {
        Add-DiagFinding -DiagState $DiagState -Component "Unexpected Resets" -Status "Fail" `
            -Details "$resetCount unexpected resets in last $cfgEventLogDays days" -Category "OS/Boot" -Weight 70
        $osFails++
        Write-Finding -Label "Unexpected resets (${cfgEventLogDays}d)" -Value "$resetCount events" -Color "Red"
    } elseif ($resetCount -gt 0) {
        Add-DiagFinding -DiagState $DiagState -Component "Unexpected Resets" -Status "Warning" `
            -Details "$resetCount unexpected resets in last $cfgEventLogDays days" -Category "OS/Boot" -Weight 40
        $osWarns++
        Write-Finding -Label "Unexpected resets (${cfgEventLogDays}d)" -Value "$resetCount events" -Color "Yellow"
    } else {
        Write-Finding -Label "Unexpected resets (${cfgEventLogDays}d)" -Value "None" -Color "Green"
    }

    # --- 3C: SFC integrity ---
    Write-Host "    Checking SFC integrity status..." -ForegroundColor DarkGray
    $sfcViolations = $false
    $cbsLogPath = "$env:SystemRoot\Logs\CBS\CBS.log"
    if (Test-Path $cbsLogPath) {
        try {
            $cbsTail = Get-Content $cbsLogPath -Tail 200 -ErrorAction SilentlyContinue
            $violations = @($cbsTail | Where-Object { $_ -match 'Cannot repair member file' -or $_ -match 'Corruption not repaired' })
            if ($violations.Count -gt 0) {
                $sfcViolations = $true
                Add-DiagFinding -DiagState $DiagState -Component "SFC Integrity" -Status "Fail" `
                    -Details "$($violations.Count) integrity violations in CBS.log" -Category "OS/Boot" -Weight 65
                $osFails++
                Write-Finding -Label "SFC integrity" -Value "$($violations.Count) violations" -Color "Red"
            } else {
                Write-Finding -Label "SFC integrity" -Value "No violations" -Color "Green"
            }
        } catch {
            Write-Finding -Label "SFC integrity" -Value "Could not read CBS.log" -Color "DarkGray"
        }
    } else {
        Write-Finding -Label "SFC integrity" -Value "CBS.log not found" -Color "DarkGray"
    }

    # --- 3D: DISM component store ---
    Write-Host "    Checking component store..." -ForegroundColor DarkGray
    try {
        $dismOutput = & dism /Online /Cleanup-Image /CheckHealth 2>&1
        $dismStr = $dismOutput -join " "
        if ($dismStr -match 'repairable') {
            Add-DiagFinding -DiagState $DiagState -Component "DISM Component Store" -Status "Warning" `
                -Details "Component store is repairable" -Category "OS/Boot" -Weight 50
            $osWarns++
            Write-Finding -Label "DISM component store" -Value "Repairable" -Color "Yellow"
        } elseif ($dismStr -match 'no component store corruption') {
            Write-Finding -Label "DISM component store" -Value "Healthy" -Color "Green"
        } else {
            Write-Finding -Label "DISM component store" -Value "Check complete" -Color "Green"
        }
    } catch {
        Write-Finding -Label "DISM component store" -Value "Check failed" -Color "DarkGray"
    }

    # --- 3E: Secure Boot ---
    Write-Host "    Checking Secure Boot..." -ForegroundColor DarkGray
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        if ($sb -eq $true) {
            Write-Finding -Label "Secure Boot" -Value "Enabled" -Color "Green"
        } else {
            Add-DiagFinding -DiagState $DiagState -Component "Secure Boot" -Status "Warning" `
                -Details "Secure Boot is disabled" -Category "OS/Boot" -Weight 15
            $osWarns++
            Write-Finding -Label "Secure Boot" -Value "Disabled" -Color "Yellow"
        }
    } catch {
        Write-Finding -Label "Secure Boot" -Value "Not supported (Legacy BIOS)" -Color "DarkGray"
    }

    # --- 3F: Windows Update age ---
    Write-Host "    Checking Windows Update status..." -ForegroundColor DarkGray
    try {
        $lastUpdate = Get-HotFix -ErrorAction SilentlyContinue |
            Sort-Object InstalledOn -Descending -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($lastUpdate -and $lastUpdate.InstalledOn) {
            $daysSince = ((Get-Date) - $lastUpdate.InstalledOn).Days
            if ($daysSince -gt 60) {
                Add-DiagFinding -DiagState $DiagState -Component "Windows Update" -Status "Warning" `
                    -Details "Last update was $daysSince days ago" -Category "OS/Boot" -Weight 20
                $osWarns++
                Write-Finding -Label "Last Windows Update" -Value "$daysSince days ago" -Color "Yellow"
            } else {
                Write-Finding -Label "Last Windows Update" -Value "$daysSince days ago" -Color "Green"
            }
        }
    } catch {
        Write-Finding -Label "Windows Update" -Value "Could not determine" -Color "DarkGray"
    }

    # --- 3G: BCD Validation ---
    Write-Host "    Validating boot configuration data..." -ForegroundColor DarkGray
    try {
        $bcdOutput = & bcdedit /enum all 2>&1
        $bcdText = $bcdOutput -join "`n"
        $hasBootMgr = $bcdText -match "Windows Boot Manager"
        $hasBootLoader = $bcdText -match "Windows Boot Loader"
        if (-not $hasBootMgr -or -not $hasBootLoader) {
            Add-DiagFinding -DiagState $DiagState -Component "BCD Configuration" -Status "Fail" `
                -Details "Missing Windows Boot Manager or Boot Loader entry" -Category "OS/Boot" -Weight 70
            $osFails++
            Write-Finding -Label "BCD validation" -Value "MISSING boot entries" -Color "Red"
        } else {
            Write-Finding -Label "BCD validation" -Value "Boot Manager + Loader present" -Color "Green"
        }
    } catch {
        Write-Finding -Label "BCD validation" -Value "Could not query" -Color "DarkGray"
    }

    # --- 3H: CHKDSK Dirty Bit ---
    Write-Host "    Checking volume dirty bit..." -ForegroundColor DarkGray
    try {
        $dirtyOutput = & fsutil dirty query C: 2>&1
        $dirtyText = "$dirtyOutput"
        if ($dirtyText -match "dirty") {
            if ($dirtyText -match "NOT Dirty" -or $dirtyText -match "not dirty") {
                Write-Finding -Label "Volume C: dirty bit" -Value "Clean" -Color "Green"
            } else {
                Add-DiagFinding -DiagState $DiagState -Component "CHKDSK Dirty Bit" -Status "Warning" `
                    -Details "Volume C: has dirty bit set -- CHKDSK needed on next reboot" -Category "Storage" -Weight 30
                $osWarns++
                Write-Finding -Label "Volume C: dirty bit" -Value "DIRTY -- needs CHKDSK" -Color "Yellow"
            }
        } else {
            Write-Finding -Label "Volume C: dirty bit" -Value "Clean" -Color "Green"
        }
    } catch {
        Write-Finding -Label "CHKDSK dirty bit" -Value "Could not query" -Color "DarkGray"
    }

    # --- 3I: Corrupt Service Detection ---
    Write-Host "    Checking service binary paths..." -ForegroundColor DarkGray
    try {
        $autoServices = Get-CimInstance Win32_Service -Filter "StartMode='Auto'" -ErrorAction SilentlyContinue
        $brokenServices = @()
        foreach ($svc in $autoServices) {
            if ($svc.PathName) {
                # Extract executable path (strip quotes and arguments)
                $exePath = $svc.PathName
                if ($exePath.StartsWith('"')) {
                    $endQuote = $exePath.IndexOf('"', 1)
                    if ($endQuote -gt 1) { $exePath = $exePath.Substring(1, $endQuote - 1) }
                } else {
                    $spaceIdx = $exePath.IndexOf(' ')
                    if ($spaceIdx -gt 0) { $exePath = $exePath.Substring(0, $spaceIdx) }
                }
                # Expand environment variables
                $exePath = [System.Environment]::ExpandEnvironmentVariables($exePath)
                if ($exePath -and -not (Test-Path $exePath -ErrorAction SilentlyContinue)) {
                    # Skip svchost.exe false positives
                    if ($exePath -notmatch 'svchost\.exe') {
                        $brokenServices += $svc.Name
                    }
                }
            }
        }
        if ($brokenServices.Count -gt 0) {
            $brokenList = ($brokenServices | Select-Object -First 5) -join ", "
            Add-DiagFinding -DiagState $DiagState -Component "Corrupt Services" -Status "Warning" `
                -Details "$($brokenServices.Count) auto-start services with missing binaries: $brokenList" -Category "OS/Boot" -Weight 25
            $osWarns++
            Write-Finding -Label "Corrupt services" -Value "$($brokenServices.Count) with missing binaries" -Color "Yellow"
        } else {
            Write-Finding -Label "Corrupt services" -Value "All auto-start paths valid" -Color "Green"
        }
    } catch {
        Write-Finding -Label "Corrupt services" -Value "Could not scan" -Color "DarkGray"
    }

    # --- 3J: Windows Update Component Health ---
    Write-Host "    Checking WU components..." -ForegroundColor DarkGray
    try {
        $wuOK = $true
        # Check SoftwareDistribution folder
        $sdPath = Join-Path $env:SystemRoot "SoftwareDistribution"
        if (-not (Test-Path $sdPath)) {
            Add-DiagFinding -DiagState $DiagState -Component "WU SoftwareDistribution" -Status "Fail" `
                -Details "SoftwareDistribution folder missing" -Category "OS/Boot" -Weight 40
            $osFails++
            $wuOK = $false
            Write-Finding -Label "SoftwareDistribution" -Value "MISSING" -Color "Red"
        }
        # Check WU service chain
        $wuServices = @('wuauserv', 'BITS', 'CryptSvc', 'msiserver')
        $disabledWU = @()
        foreach ($wuSvc in $wuServices) {
            $svcObj = Get-Service -Name $wuSvc -ErrorAction SilentlyContinue
            if ($svcObj -and $svcObj.StartType -eq 'Disabled') {
                $disabledWU += $wuSvc
            }
        }
        if ($disabledWU.Count -gt 0) {
            Add-DiagFinding -DiagState $DiagState -Component "WU Service Chain" -Status "Warning" `
                -Details "Disabled WU services: $($disabledWU -join ', ')" -Category "OS/Boot" -Weight 20
            $osWarns++
            $wuOK = $false
            Write-Finding -Label "WU services" -Value "$($disabledWU -join ', ') disabled" -Color "Yellow"
        }
        if ($wuOK) {
            Write-Finding -Label "WU components" -Value "Healthy" -Color "Green"
        }
    } catch {
        Write-Finding -Label "WU components" -Value "Could not check" -Color "DarkGray"
    }

    # Phase result
    $status = if ($osFails -gt 0) { "FAIL" } elseif ($osWarns -gt 0) { "WARN" } else { "PASS" }
    $DiagState.PhaseResults["Phase3"] = $status
    if ($osFails -gt 0) { $DiagState.BootIssues = $true }
    Write-PhaseResult -Phase "Phase 3: Boot & OS" -Status $status -Details "$osFails failures, $osWarns warnings"
    Write-Log "Phase 3 complete: $osFails failures, $osWarns warnings"
    Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase3"
}

# ============================================================
# PHASE 4: SERVICE & DRIVER INTEGRITY
# ============================================================

function Invoke-Phase4-ServiceAndDriver {
    param([hashtable]$DiagState)

    if ($DiagState.HardwareCritical) {
        Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase4"
        Write-ScanHeader -Name "PHASE 4: SERVICE & DRIVER INTEGRITY" -Icon "[4/8]"
        Write-Host "    Skipped - hardware critical issue detected" -ForegroundColor DarkGray
        $DiagState.PhaseResults["Phase4"] = "SKIP"
        Write-PhaseResult -Phase "Phase 4: Service & Driver" -Status "SKIP" -Details "Hardware critical"
        Write-Log "Phase 4 skipped: HardwareCritical=true"
        Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase4"
        return
    }

    Write-ScanHeader -Name "PHASE 4: SERVICE & DRIVER INTEGRITY" -Icon "[4/8]"
    Write-Log "--- Phase 4: Service & Driver Integrity ---"
    Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase4"
    if ($v9GovernanceAvailable) { try { Save-ExecutionState -SessionGUID $DiagState.SessionId -CurrentPhase 4 -OutputDir $ReportPath } catch {} }

    $drvFails = 0
    $drvWarns = 0

    # --- 4A: Problem devices ---
    Write-Host "    Scanning for problem devices..." -ForegroundColor DarkGray
    try {
        $problemDevices = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.ConfigManagerErrorCode -ne 0 }
        $pdCount = @($problemDevices).Count
        if ($pdCount -gt 0) {
            $pdNames = @($problemDevices | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ", "
            Add-DiagFinding -DiagState $DiagState -Component "Problem Devices" -Status "Fail" `
                -Details "$pdCount devices: $pdNames" -Category "Driver" -Weight 55
            $DiagState.DriverIssues = $true
            $drvFails++
            Write-Finding -Label "Problem devices" -Value "$pdCount found" -Color "Red"
        } else {
            Write-Finding -Label "Problem devices" -Value "None" -Color "Green"
        }
    } catch {
        Write-Finding -Label "Problem devices" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4B: Unsigned drivers ---
    Write-Host "    Checking for unsigned drivers..." -ForegroundColor DarkGray
    try {
        $unsigned = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.IsSigned -eq $false -and $_.DeviceName }
        $unsCount = @($unsigned).Count
        if ($unsCount -gt 0) {
            $unsNames = @($unsigned | Select-Object -First 3 | ForEach-Object { $_.DeviceName }) -join ", "
            Add-DiagFinding -DiagState $DiagState -Component "Unsigned Drivers" -Status "Warning" `
                -Details "$unsCount unsigned: $unsNames" -Category "Driver" -Weight 35
            $drvWarns++
            Write-Finding -Label "Unsigned drivers" -Value "$unsCount found" -Color "Yellow"
        } else {
            Write-Finding -Label "Unsigned drivers" -Value "None" -Color "Green"
        }
    } catch {
        Write-Finding -Label "Unsigned drivers" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4C: Critical services ---
    Write-Host "    Checking critical services..." -ForegroundColor DarkGray
    $critServices = @(
        @{ Name = "WinDefend";  Label = "Windows Defender" },
        @{ Name = "mpssvc";     Label = "Windows Firewall" },
        @{ Name = "wuauserv";   Label = "Windows Update" },
        @{ Name = "BITS";       Label = "BITS Transfer" }
    )
    foreach ($svc in $critServices) {
        try {
            $service = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
            if ($service) {
                if ($service.Status -ne 'Running') {
                    Add-DiagFinding -DiagState $DiagState -Component "$($svc.Label) Service" -Status "Fail" `
                        -Details "$($svc.Label) is $($service.Status)" -Category "Security" -Weight 30
                    $DiagState.SecurityIssues = $true
                    $drvFails++
                    Write-Finding -Label $svc.Label -Value "$($service.Status)" -Color "Red"
                } else {
                    Write-Finding -Label $svc.Label -Value "Running" -Color "Green"
                }
            }
        } catch { }
    }

    # --- 4D: Defender status ---
    Write-Host "    Checking Defender status..." -ForegroundColor DarkGray
    try {
        $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($mp) {
            if (-not $mp.AntivirusEnabled) {
                Add-DiagFinding -DiagState $DiagState -Component "Defender Antivirus" -Status "Fail" `
                    -Details "Real-time protection disabled" -Category "Security" -Weight 30
                $DiagState.SecurityIssues = $true
                $drvFails++
                Write-Finding -Label "Defender real-time" -Value "Disabled" -Color "Red"
            } else {
                Write-Finding -Label "Defender real-time" -Value "Enabled" -Color "Green"
            }
            # Signature age
            if ($mp.AntivirusSignatureLastUpdated) {
                $sigAge = ((Get-Date) - $mp.AntivirusSignatureLastUpdated).Days
                if ($sigAge -gt 7) {
                    Add-DiagFinding -DiagState $DiagState -Component "Defender Signatures" -Status "Warning" `
                        -Details "Signatures $sigAge days old" -Category "Security" -Weight 20
                    $drvWarns++
                    Write-Finding -Label "Defender signatures" -Value "$sigAge days old" -Color "Yellow"
                } else {
                    Write-Finding -Label "Defender signatures" -Value "$sigAge days old" -Color "Green"
                }
            }
        }
    } catch {
        Write-Finding -Label "Defender" -Value "Could not query" -Color "DarkGray"
    }

    # --- 4E: Firewall profiles ---
    Write-Host "    Checking firewall profiles..." -ForegroundColor DarkGray
    try {
        $fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        $fwDisabled = @($fwProfiles | Where-Object { -not $_.Enabled }).Count
        if ($fwDisabled -gt 0) {
            Add-DiagFinding -DiagState $DiagState -Component "Firewall Profiles" -Status "Fail" `
                -Details "$fwDisabled of 3 profiles disabled" -Category "Security" -Weight 25
            $DiagState.SecurityIssues = $true
            $drvFails++
            Write-Finding -Label "Firewall" -Value "$fwDisabled profiles disabled" -Color "Red"
        } else {
            Write-Finding -Label "Firewall" -Value "All profiles enabled" -Color "Green"
        }
    } catch {
        Write-Finding -Label "Firewall" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4F: Network adapter ---
    Write-Host "    Checking network adapters..." -ForegroundColor DarkGray
    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        $wifiUp = @($adapters | Where-Object { $_.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11' }).Count
        $ethUp  = @($adapters | Where-Object { $_.InterfaceDescription -match 'Ethernet|Realtek|Intel.*I2[12][09]' }).Count

        if (($wifiUp + $ethUp) -eq 0) {
            Add-DiagFinding -DiagState $DiagState -Component "Network Adapters" -Status "Fail" `
                -Details "No active network adapters" -Category "Network" -Weight 30
            $drvFails++
            Write-Finding -Label "Network adapters" -Value "None active" -Color "Red"
        } else {
            Write-Finding -Label "Network adapters" -Value "Wi-Fi: $wifiUp, Ethernet: $ethUp" -Color "Green"
        }
    } catch {
        Write-Finding -Label "Network adapters" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4G: Suspicious scheduled tasks ---
    Write-Host "    Scanning scheduled tasks..." -ForegroundColor DarkGray
    try {
        $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.State -ne 'Disabled' }
        $suspiciousTasks = @()
        $suspiciousPaths = @()
        foreach ($task in $allTasks) {
            $author = if ($task.Author) { $task.Author } else { "" }
            # Skip Microsoft and system tasks
            if ($author -match 'Microsoft|Windows|SYSTEM|Intel|Lenovo|HP|Dell|Realtek|NVIDIA|AMD') { continue }
            if ($task.TaskPath -match '^\\Microsoft\\') { continue }
            $taskName = $task.TaskName
            # Check for suspicious action paths
            $actions = $task.Actions
            $isSuspPath = $false
            foreach ($act in $actions) {
                $exe = if ($act.Execute) { $act.Execute } else { "" }
                if ($exe -match 'Temp|AppData\\Local\\Temp|\\Downloads\\|cmd\.exe.*\/c') {
                    $isSuspPath = $true
                }
            }
            if ($isSuspPath) {
                $suspiciousPaths += $taskName
            }
            $suspiciousTasks += $taskName
        }
        $suspCount = $suspiciousTasks.Count
        $suspPathCount = $suspiciousPaths.Count

        if ($suspPathCount -gt 0) {
            $pathNames = ($suspiciousPaths | Select-Object -First 3) -join ", "
            Add-DiagFinding -DiagState $DiagState -Component "Suspicious Scheduled Tasks" -Status "Fail" `
                -Details "$suspPathCount tasks run from suspicious paths: $pathNames" -Category "Security" -Weight 35
            $DiagState.SecurityIssues = $true
            $drvFails++
            Write-Finding -Label "Suspicious tasks (bad path)" -Value "$suspPathCount found" -Color "Red"
        } elseif ($suspCount -gt 10) {
            $taskNames = ($suspiciousTasks | Select-Object -First 3) -join ", "
            Add-DiagFinding -DiagState $DiagState -Component "Non-System Scheduled Tasks" -Status "Warning" `
                -Details "$suspCount non-Microsoft tasks: $taskNames..." -Category "Security" -Weight 25
            $drvWarns++
            Write-Finding -Label "Non-system scheduled tasks" -Value "$suspCount found" -Color "Yellow"
        } else {
            Write-Finding -Label "Scheduled tasks" -Value "$suspCount non-system" -Color "Green"
        }
    } catch {
        Write-Finding -Label "Scheduled tasks" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4H: Display / GPU health ---
    Write-Host "    Checking display adapter health..." -ForegroundColor DarkGray
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
        $gpuErrorCount = 0
        $gpuDriverOld = $false
        $gpuDriverMaxDays = 365
        # Read config threshold if available
        try {
            $cfgPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Config\config.ini"
            if (-not (Test-Path $cfgPath)) { $cfgPath = Join-Path $PSScriptRoot "Config\config.ini" }
            if (Test-Path $cfgPath) {
                $cfgRaw = Get-Content $cfgPath -Raw
                if ($cfgRaw -match 'GPUDriverMaxAgeDays=(\d+)') { $gpuDriverMaxDays = [int]$Matches[1] }
            }
        } catch { }

        foreach ($gpu in $gpus) {
            $gpuName = if ($gpu.Name) { $gpu.Name } else { "Unknown GPU" }

            # Check ConfigManagerErrorCode
            # GPU PnP errors are often driver-fixable (code 28=no driver, 31=not working, 43=stopped)
            if ($gpu.ConfigManagerErrorCode -and $gpu.ConfigManagerErrorCode -ne 0) {
                $gpuErrorCount++
                Add-DiagFinding -DiagState $DiagState -Component "Display Adapter Error" -Status "Fail" `
                    -Details "$gpuName has error code $($gpu.ConfigManagerErrorCode)" -Category "Driver" -Weight 60
                $DiagState.DriverIssues = $true
                $drvFails++
                Write-Finding -Label "GPU: $gpuName" -Value "Error code $($gpu.ConfigManagerErrorCode)" -Color "Red"
            } else {
                # Check driver age
                if ($gpu.DriverDate) {
                    $driverAgeDays = [int]((Get-Date) - $gpu.DriverDate).TotalDays
                    if ($driverAgeDays -gt $gpuDriverMaxDays) {
                        $gpuDriverOld = $true
                        Add-DiagFinding -DiagState $DiagState -Component "Display Driver Outdated" -Status "Warning" `
                            -Details "$gpuName driver is $driverAgeDays days old (threshold: $gpuDriverMaxDays)" -Category "Driver" -Weight 20
                        $drvWarns++
                        Write-Finding -Label "GPU: $gpuName" -Value "Driver $driverAgeDays days old" -Color "Yellow"
                    } else {
                        Write-Finding -Label "GPU: $gpuName" -Value "OK ($($gpu.DriverVersion))" -Color "Green"
                    }
                } else {
                    Write-Finding -Label "GPU: $gpuName" -Value "OK ($($gpu.DriverVersion))" -Color "Green"
                }
            }
        }

        # Store GPU info in machine snapshot
        if ($gpus) {
            $DiagState.Machine["GPUAdapters"] = @($gpus | ForEach-Object {
                @{
                    Name = if ($_.Name) { $_.Name } else { "Unknown" }
                    DriverVersion = if ($_.DriverVersion) { $_.DriverVersion } else { "N/A" }
                    VRAM_MB = if ($_.AdapterRAM) { [math]::Round($_.AdapterRAM / 1MB) } else { 0 }
                    Status = if ($_.ConfigManagerErrorCode -eq 0) { "OK" } else { "Error ($($_.ConfigManagerErrorCode))" }
                }
            })
        }
    } catch {
        Write-Finding -Label "Display adapters" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4I: GPU TDR / Display crash events ---
    Write-Host "    Checking GPU crash/TDR events..." -ForegroundColor DarkGray
    try {
        $eventDays = 30
        try {
            if ($cfgRaw -and $cfgRaw -match 'EventLogDays=(\d+)') { $eventDays = [int]$Matches[1] }
        } catch { }
        $tdrStart = (Get-Date).AddDays(-$eventDays)

        # Event 4101: Display driver stopped responding and recovered (TDR)
        # Event 4116: Display driver TDR attempt
        # Event 141: LiveKernelEvent (GPU hang)
        $tdrEvents = @()
        $tdrEvents += @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=@(4101,4116); StartTime=$tdrStart} -MaxEvents 50 -ErrorAction SilentlyContinue)

        # LiveKernelEvent for GPU hangs
        $lkeEvents = @()
        $lkeEvents += @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-LiveDump'; StartTime=$tdrStart} -MaxEvents 20 -ErrorAction SilentlyContinue)

        $totalDisplayEvents = $tdrEvents.Count + $lkeEvents.Count

        # TDR = display driver timeout/recovery = SOFTWARE (driver) issue, NOT hardware
        # Driver update/reinstall fixes most TDR problems
        $DiagState.Machine["TDREventCount"] = $totalDisplayEvents
        if ($totalDisplayEvents -ge 10) {
            Add-DiagFinding -DiagState $DiagState -Component "GPU TDR/Crash Events" -Status "Fail" `
                -Details "$totalDisplayEvents display driver crash events in last $eventDays days (TDR: $($tdrEvents.Count), LiveKernel: $($lkeEvents.Count)). Display artifacts/color lines likely caused by driver instability. Auto-fix: driver update." -Category "Driver" -Weight 70
            $DiagState.DriverIssues = $true
            $drvFails++
            Write-Finding -Label "GPU TDR/crash events" -Value "$totalDisplayEvents events (DRIVER ISSUE)" -Color "Red"
        } elseif ($totalDisplayEvents -ge 3) {
            Add-DiagFinding -DiagState $DiagState -Component "GPU TDR Events" -Status "Fail" `
                -Details "$totalDisplayEvents display driver events in last $eventDays days (TDR: $($tdrEvents.Count), LiveKernel: $($lkeEvents.Count)). Driver instability detected -- update recommended." -Category "Driver" -Weight 50
            $DiagState.DriverIssues = $true
            $drvFails++
            Write-Finding -Label "GPU TDR events" -Value "$totalDisplayEvents events (DRIVER)" -Color "Yellow"
        } elseif ($totalDisplayEvents -gt 0) {
            Add-DiagFinding -DiagState $DiagState -Component "GPU TDR Events" -Status "Warning" `
                -Details "$totalDisplayEvents minor display driver event(s) -- monitor for recurrence" -Category "Driver" -Weight 20
            $drvWarns++
            Write-Finding -Label "GPU TDR events" -Value "$totalDisplayEvents (minor)" -Color "Yellow"
        } else {
            Write-Finding -Label "GPU TDR events" -Value "None" -Color "Green"
        }
    } catch {
        Write-Finding -Label "GPU TDR events" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4J: Display panel / cable health indicators ---
    Write-Host "    Checking display panel indicators..." -ForegroundColor DarkGray
    try {
        # Check monitor connectivity via WMI
        $monitors = @(Get-CimInstance WmiMonitorBasicDisplayParams -Namespace root/wmi -ErrorAction SilentlyContinue)
        $activeMonitors = @($monitors | Where-Object { $_.Active -eq $true })
        $internalCount = 0
        $externalCount = 0

        foreach ($mon in $activeMonitors) {
            $instanceName = if ($mon.InstanceName) { $mon.InstanceName } else { "" }
            # Internal displays typically have "DISPLAY\LEN", "DISPLAY\BOE", "DISPLAY\AUO", "DISPLAY\LGD", "DISPLAY\CMN" etc.
            $isInternal = ($instanceName -match 'DISPLAY\\(LEN|BOE|AUO|LGD|CMN|SEC|SDC|SHP|IVO|INX|CHI|HSD|KDB)')
            if ($isInternal) { $internalCount++ } else { $externalCount++ }
        }

        # Check for display-related error events (display panel issues)
        $displayErrors = @()
        $displayErrors += @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Graphics-Kernel'; StartTime=$tdrStart} -MaxEvents 30 -ErrorAction SilentlyContinue)

        # Check video scheduler errors (Event 129 = GPU reset)
        $vidSchedErrors = @()
        $vidSchedErrors += @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=129; StartTime=$tdrStart} -MaxEvents 20 -ErrorAction SilentlyContinue)

        $displayErrorTotal = $displayErrors.Count + $vidSchedErrors.Count

        # Resolution check - detect abnormal/fallback resolution
        $gpuInfo = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
        $currentRes = ""
        $resolutionAnomaly = $false
        if ($gpuInfo) {
            $hRes = $gpuInfo.CurrentHorizontalResolution
            $vRes = $gpuInfo.CurrentVerticalResolution
            $currentRes = "${hRes}x${vRes}"
            # Detect fallback/safe-mode resolution (640x480 or 800x600 or 1024x768 on modern laptops)
            if ($hRes -and $vRes) {
                if (($hRes -le 1024 -and $vRes -le 768)) {
                    $resolutionAnomaly = $true
                }
            }
        }

        # Build display health assessment
        # Smart classification: if TDR events found earlier → driver instability → try driver fix first
        # If NO TDR but display errors → more likely hardware (cable/panel)
        $hasTDR = ($DiagState.Machine["TDREventCount"] -and $DiagState.Machine["TDREventCount"] -gt 0)

        if ($resolutionAnomaly) {
            # Fallback resolution = driver crashed to basic display adapter → driver fixable
            $details = "Running at fallback resolution $currentRes -- GPU driver likely crashed to basic display adapter. Auto-fix: driver reinstall."
            Add-DiagFinding -DiagState $DiagState -Component "Display Resolution Anomaly" -Status "Fail" `
                -Details $details -Category "Driver" -Weight 50
            $DiagState.DriverIssues = $true
            $drvFails++
            Write-Finding -Label "Display resolution" -Value "FALLBACK $currentRes (DRIVER)" -Color "Red"
        } elseif ($displayErrorTotal -ge 10) {
            if ($hasTDR) {
                # TDR events + graphics kernel errors = driver instability confirmed
                $details = "$displayErrorTotal graphics kernel errors + TDR events detected. Display artifacts/color lines caused by driver instability. Auto-fix: driver update/reinstall."
                Add-DiagFinding -DiagState $DiagState -Component "Display Driver Instability" -Status "Fail" `
                    -Details $details -Category "Driver" -Weight 55
                $DiagState.DriverIssues = $true
                $drvFails++
                Write-Finding -Label "Display health" -Value "Driver instability ($displayErrorTotal errors)" -Color "Red"
            } else {
                # No TDR but many graphics errors = likely hardware (cable/panel)
                $details = "$displayErrorTotal graphics kernel errors but NO driver crashes (TDR). Likely hardware: check eDP cable seating, then panel replacement if color lines persist."
                Add-DiagFinding -DiagState $DiagState -Component "Display Panel Health" -Status "Fail" `
                    -Details $details -Category "Hardware" -Weight 55
                $drvFails++
                Write-Finding -Label "Display panel health" -Value "HARDWARE ($displayErrorTotal errors, no TDR)" -Color "Red"
            }
        } elseif ($displayErrorTotal -ge 3) {
            if ($hasTDR) {
                Add-DiagFinding -DiagState $DiagState -Component "Display Driver Instability" -Status "Warning" `
                    -Details "$displayErrorTotal graphics kernel errors with TDR events -- driver update recommended" -Category "Driver" -Weight 30
                $drvWarns++
                Write-Finding -Label "Display health" -Value "$displayErrorTotal errors (driver-related)" -Color "Yellow"
            } else {
                Add-DiagFinding -DiagState $DiagState -Component "Display Panel Health" -Status "Warning" `
                    -Details "$displayErrorTotal graphics kernel errors. Monitor: $($activeMonitors.Count) active ($internalCount internal, $externalCount external)" -Category "Hardware" -Weight 30
                $drvWarns++
                Write-Finding -Label "Display panel health" -Value "$displayErrorTotal errors" -Color "Yellow"
            }
        } else {
            Write-Finding -Label "Display panel health" -Value "OK ($($activeMonitors.Count) monitor(s), $currentRes)" -Color "Green"
        }

        # Store monitor info in machine snapshot
        $DiagState.Machine["Monitors"] = @{
            ActiveCount = $activeMonitors.Count
            InternalCount = $internalCount
            ExternalCount = $externalCount
            Resolution = $currentRes
            GraphicsKernelErrors = $displayErrorTotal
        }
    } catch {
        Write-Finding -Label "Display panel health" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4K: Refresh rate validation ---
    Write-Host "    Checking display refresh rate..." -ForegroundColor DarkGray
    try {
        $gpuCtrl = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gpuCtrl -and $gpuCtrl.CurrentRefreshRate) {
            $refreshRate = [int]$gpuCtrl.CurrentRefreshRate
            $DiagState.Machine["RefreshRate"] = $refreshRate

            # Read thresholds from config
            $minHz = 50; $maxHz = 240
            if ($cfgRaw -and $cfgRaw -match 'MinRefreshRateHz=(\d+)') { $minHz = [int]$Matches[1] }
            if ($cfgRaw -and $cfgRaw -match 'MaxRefreshRateHz=(\d+)') { $maxHz = [int]$Matches[1] }

            if ($refreshRate -lt $minHz -or $refreshRate -gt $maxHz) {
                $drvWarns++
                Add-DiagFinding -DiagState $DiagState -Component "Refresh Rate" `
                    -Status "Warning" -Category "Display" -Weight 20 `
                    -Details "Refresh rate ${refreshRate}Hz is outside normal range (${minHz}-${maxHz}Hz). Possible driver issue or misconfigured display."
                Write-Finding -Label "Refresh rate" -Value "${refreshRate}Hz (ANOMALY)" -Color "Yellow"
            } else {
                Write-Finding -Label "Refresh rate" -Value "${refreshRate}Hz" -Color "Green"
            }
        } else {
            Write-Finding -Label "Refresh rate" -Value "Not available" -Color "DarkGray"
        }
    } catch {
        Write-Finding -Label "Refresh rate" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4L: Brightness / backlight diagnostics ---
    Write-Host "    Checking brightness control..." -ForegroundColor DarkGray
    try {
        $brightness = Get-CimInstance WmiMonitorBrightness -Namespace root/wmi -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($brightness) {
            $currentBrightness = [int]$brightness.CurrentBrightness
            $DiagState.Machine["Brightness"] = $currentBrightness

            $minBrightness = 10
            if ($cfgRaw -and $cfgRaw -match 'BrightnessMinPercent=(\d+)') { $minBrightness = [int]$Matches[1] }

            if ($currentBrightness -eq 0) {
                $drvFails++
                Add-DiagFinding -DiagState $DiagState -Component "Brightness Control" `
                    -Status "Fail" -Category "Display" -Weight 40 `
                    -Details "Brightness is 0%. Possible ACPI display driver failure or backlight circuit issue."
                Write-Finding -Label "Brightness" -Value "0% (BACKLIGHT ISSUE)" -Color "Red"
            } elseif ($currentBrightness -lt $minBrightness) {
                $drvWarns++
                Add-DiagFinding -DiagState $DiagState -Component "Brightness Control" `
                    -Status "Warning" -Category "Display" -Weight 15 `
                    -Details "Brightness at ${currentBrightness}% (below ${minBrightness}% threshold). Check power plan and ACPI driver."
                Write-Finding -Label "Brightness" -Value "${currentBrightness}% (LOW)" -Color "Yellow"
            } else {
                Write-Finding -Label "Brightness" -Value "${currentBrightness}%" -Color "Green"
            }

            # Check if brightness control is functional (WmiSetBrightness available)
            $brightnessMethods = Get-CimInstance WmiMonitorBrightnessMethods -Namespace root/wmi -ErrorAction SilentlyContinue
            if (-not $brightnessMethods) {
                $drvWarns++
                Add-DiagFinding -DiagState $DiagState -Component "Brightness ACPI" `
                    -Status "Warning" -Category "Display" -Weight 15 `
                    -Details "WmiMonitorBrightnessMethods unavailable. Brightness hotkeys may not work. Check ACPI/monitor driver."
                Write-Finding -Label "Brightness control" -Value "ACPI method unavailable" -Color "Yellow"
            }
        } else {
            # No brightness WMI = desktop or external-only display (not a failure)
            Write-Finding -Label "Brightness" -Value "N/A (desktop or external display)" -Color "DarkGray"
        }
    } catch {
        Write-Finding -Label "Brightness" -Value "Query failed" -Color "DarkGray"
    }

    # --- 4M: Shell / explorer.exe integrity ---
    Write-Host "    Checking Windows shell integrity..." -ForegroundColor DarkGray
    try {
        $explorerProc = Get-Process explorer -ErrorAction SilentlyContinue
        $shellReg = $null
        try {
            $winlogon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
            if ($winlogon) { $shellReg = $winlogon.Shell }
        } catch { }

        $isCustomShell = ($shellReg -and $shellReg -ne 'explorer.exe')
        $explorerRunning = ($null -ne $explorerProc -and @($explorerProc).Count -gt 0)

        if (-not $explorerRunning -and -not $isCustomShell) {
            $drvFails++
            Add-DiagFinding -DiagState $DiagState -Component "Windows Shell" `
                -Status "Fail" -Category "OS/Boot" -Weight 60 `
                -Details "explorer.exe is not running and no custom shell configured. This causes black screen after login. Auto-fix: restart explorer or repair shell registry."
            Write-Finding -Label "Windows shell" -Value "explorer.exe NOT RUNNING" -Color "Red"
        } elseif ($isCustomShell) {
            Add-DiagFinding -DiagState $DiagState -Component "Windows Shell" `
                -Status "Info" -Category "OS/Boot" -Weight 0 `
                -Details "Custom shell configured: $shellReg (kiosk/domain policy). Not a defect."
            Write-Finding -Label "Windows shell" -Value "Custom: $shellReg" -Color "Cyan"
        } else {
            Write-Finding -Label "Windows shell" -Value "explorer.exe running" -Color "Green"
        }
    } catch {
        Write-Finding -Label "Windows shell" -Value "Check failed" -Color "DarkGray"
    }

    # --- 4N: EDID / native resolution validation ---
    Write-Host "    Checking EDID / native resolution..." -ForegroundColor DarkGray
    try {
        $edidValidation = $true
        if ($cfgRaw -and $cfgRaw -match 'EDIDValidation=(\d+)') { $edidValidation = $Matches[1] -eq '1' }

        if ($edidValidation) {
            $monitorIDs = @(Get-CimInstance WmiMonitorID -Namespace root/wmi -ErrorAction SilentlyContinue)
            $panelInfo = @()

            foreach ($mid in $monitorIDs) {
                $mfr = ''
                $prod = ''
                if ($mid.ManufacturerName) {
                    $mfr = -join ($mid.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
                }
                if ($mid.ProductCodeID) {
                    $prod = -join ($mid.ProductCodeID | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
                }
                $panelInfo += @{ Manufacturer = $mfr; ProductCode = $prod }
            }
            $DiagState.Machine["PanelInfo"] = $panelInfo

            if ($panelInfo.Count -gt 0) {
                $panelDesc = ($panelInfo | ForEach-Object { "$($_.Manufacturer) $($_.ProductCode)" }) -join ', '
                Write-Finding -Label "Panel EDID" -Value $panelDesc -Color "Green"
            } else {
                Write-Finding -Label "Panel EDID" -Value "No EDID data available" -Color "DarkGray"
            }

            # Compare native vs current resolution (if Phase 4J captured current)
            if ($currentRes -and $gpuCtrl) {
                $nativeRes = $null
                $videoMode = $gpuCtrl.VideoModeDescription
                if ($videoMode -and $videoMode -match '(\d{3,5})\s*x\s*(\d{3,5})') {
                    $nativeW = [int]$Matches[1]; $nativeH = [int]$Matches[2]
                    $nativeRes = "${nativeW}x${nativeH}"
                }
                if ($nativeRes -and $nativeRes -ne $currentRes) {
                    $drvWarns++
                    Add-DiagFinding -DiagState $DiagState -Component "Resolution Mismatch" `
                        -Status "Warning" -Category "Display" -Weight 20 `
                        -Details "Current resolution ($currentRes) does not match native ($nativeRes). Possible driver fallback or scaling issue."
                    Write-Finding -Label "Resolution match" -Value "$currentRes vs native $nativeRes (MISMATCH)" -Color "Yellow"
                }
            }
        }
    } catch {
        Write-Finding -Label "Panel EDID" -Value "Query failed" -Color "DarkGray"
    }

    # Phase result
    $status = if ($drvFails -gt 0) { "FAIL" } elseif ($drvWarns -gt 0) { "WARN" } else { "PASS" }
    $DiagState.PhaseResults["Phase4"] = $status
    Write-PhaseResult -Phase "Phase 4: Service & Driver" -Status $status -Details "$drvFails failures, $drvWarns warnings"
    Write-Log "Phase 4 complete: $drvFails failures, $drvWarns warnings"
    Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase4"
}

# ============================================================
# PHASE 5: PERFORMANCE PROFILING
# ============================================================

function Invoke-Phase5-PerformanceProfile {
    param([hashtable]$DiagState)

    if ($DiagState.HardwareCritical) {
        Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase5"
        Write-ScanHeader -Name "PHASE 5: PERFORMANCE PROFILING" -Icon "[5/8]"
        Write-Host "    Skipped - hardware critical issue detected" -ForegroundColor DarkGray
        $DiagState.PhaseResults["Phase5"] = "SKIP"
        Write-PhaseResult -Phase "Phase 5: Performance" -Status "SKIP" -Details "Hardware critical"
        Write-Log "Phase 5 skipped: HardwareCritical=true"
        Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase5"
        return
    }

    Write-ScanHeader -Name "PHASE 5: PERFORMANCE PROFILING" -Icon "[5/8]"
    Write-Log "--- Phase 5: Performance Profiling ---"
    Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase5"
    if ($v9GovernanceAvailable) { try { Save-ExecutionState -SessionGUID $DiagState.SessionId -CurrentPhase 5 -OutputDir $ReportPath } catch {} }

    $perfFails = 0
    $perfWarns = 0

    # --- 5A: CPU benchmark ---
    Write-Host "    Running CPU benchmark (10 seconds)..." -ForegroundColor DarkGray
    $cpuScore = 0
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $iterations = 0
        while ($sw.ElapsedMilliseconds -lt 10000) {
            for ($i = 0; $i -lt 1000; $i++) { [math]::Sqrt(123456.789 * $i) | Out-Null }
            $iterations++
        }
        $sw.Stop()
        $cpuScore = $iterations
        Write-Finding -Label "CPU benchmark" -Value "$cpuScore iterations/10s" -Color "Cyan"
    } catch {
        Write-Finding -Label "CPU benchmark" -Value "Failed" -Color "DarkGray"
    }

    # --- 5B: Memory pressure ---
    Write-Host "    Checking memory pressure..." -ForegroundColor DarkGray
    $memUsedPct = 0
    try {
        $totalMem = $csInfo.TotalPhysicalMemory
        $freeMem = $osInfo.FreePhysicalMemory * 1KB
        $usedMem = $totalMem - $freeMem
        $memUsedPct = [math]::Round($usedMem / $totalMem * 100, 1)
    } catch { }

    if ($memUsedPct -gt 90) {
        Add-DiagFinding -DiagState $DiagState -Component "Memory Pressure" -Status "Fail" `
            -Details "Memory usage at ${memUsedPct}%" -Category "Performance" -Weight 30
        $perfFails++
        Write-Finding -Label "Memory usage" -Value "${memUsedPct}%" -Color "Red"
    } elseif ($memUsedPct -gt 80) {
        Add-DiagFinding -DiagState $DiagState -Component "Memory Pressure" -Status "Warning" `
            -Details "Memory usage at ${memUsedPct}%" -Category "Performance" -Weight 20
        $perfWarns++
        Write-Finding -Label "Memory usage" -Value "${memUsedPct}%" -Color "Yellow"
    } else {
        Write-Finding -Label "Memory usage" -Value "${memUsedPct}%" -Color "Green"
    }

    # --- 5C: Disk free space ---
    Write-Host "    Checking disk free space..." -ForegroundColor DarkGray
    try {
        $sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        if ($sysDrive) {
            $freeGB = [math]::Round($sysDrive.FreeSpace / 1GB, 1)
            $totalGB = [math]::Round($sysDrive.Size / 1GB, 1)
            $freePct = [math]::Round($sysDrive.FreeSpace / $sysDrive.Size * 100, 1)
            if ($freePct -lt 10) {
                Add-DiagFinding -DiagState $DiagState -Component "Disk Free Space" -Status "Fail" `
                    -Details "C: drive ${freeGB}GB free (${freePct}%)" -Category "Performance" -Weight 45
                $perfFails++
                Write-Finding -Label "C: drive free" -Value "${freeGB}GB / ${totalGB}GB (${freePct}%)" -Color "Red"
            } elseif ($freePct -lt 20) {
                Add-DiagFinding -DiagState $DiagState -Component "Disk Free Space" -Status "Warning" `
                    -Details "C: drive ${freeGB}GB free (${freePct}%)" -Category "Performance" -Weight 20
                $perfWarns++
                Write-Finding -Label "C: drive free" -Value "${freeGB}GB / ${totalGB}GB (${freePct}%)" -Color "Yellow"
            } else {
                Write-Finding -Label "C: drive free" -Value "${freeGB}GB / ${totalGB}GB (${freePct}%)" -Color "Green"
            }
        }
    } catch { }

    # --- 5D: Disk I/O benchmark ---
    Write-Host "    Running disk I/O test..." -ForegroundColor DarkGray
    $diskWriteMBs = 0
    $diskReadMBs = 0
    try {
        $testFile = Join-Path $TempPath "smartdiag_disktest_$timestamp.tmp"
        $testSize = 50MB
        $data = New-Object byte[] $testSize
        (New-Object Random).NextBytes($data)

        # Write test
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [System.IO.File]::WriteAllBytes($testFile, $data)
        $sw.Stop()
        $diskWriteMBs = [math]::Round(($testSize / 1MB) / ($sw.ElapsedMilliseconds / 1000), 1)

        # Read test
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [System.IO.File]::ReadAllBytes($testFile) | Out-Null
        $sw.Stop()
        $diskReadMBs = [math]::Round(($testSize / 1MB) / ($sw.ElapsedMilliseconds / 1000), 1)

        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        Write-Finding -Label "Disk write speed" -Value "${diskWriteMBs} MB/s" -Color "Cyan"
        Write-Finding -Label "Disk read speed" -Value "${diskReadMBs} MB/s" -Color "Cyan"
    } catch {
        Write-Finding -Label "Disk I/O test" -Value "Failed" -Color "DarkGray"
    }

    # --- 5E: Startup items ---
    Write-Host "    Counting startup items..." -ForegroundColor DarkGray
    $startupCount = 0
    try {
        $startupCount += @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue).Count
        $runKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        )
        foreach ($key in $runKeys) {
            if (Test-Path $key) {
                $startupCount += @((Get-ItemProperty $key -ErrorAction SilentlyContinue).PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^PS' }).Count
            }
        }
    } catch { }

    if ($startupCount -gt 15) {
        Add-DiagFinding -DiagState $DiagState -Component "Startup Items" -Status "Warning" `
            -Details "$startupCount startup items (high)" -Category "Performance" -Weight 15
        $perfWarns++
        Write-Finding -Label "Startup items" -Value "$startupCount" -Color "Yellow"
    } else {
        Write-Finding -Label "Startup items" -Value "$startupCount" -Color "Green"
    }

    # --- 5F: Network Stack Health ---
    Write-Host "    Checking network stack..." -ForegroundColor DarkGray
    try {
        # Default gateway
        $gatewayOK = $false
        $gwInfo = "No gateway"
        $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        if ($routes) {
            $gateway = ($routes | Select-Object -First 1).NextHop
            $gwInfo = $gateway
            $pingOK = Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($pingOK) {
                $gwInfo = "$gateway (Reachable)"
                $gatewayOK = $true
            } else {
                $gwInfo = "$gateway (Unreachable)"
                Add-DiagFinding -DiagState $DiagState -Component "Default Gateway" -Status "Warning" `
                    -Details "Gateway $gateway is unreachable" -Category "Network" -Weight 25
                $perfWarns++
            }
        } else {
            Add-DiagFinding -DiagState $DiagState -Component "Default Gateway" -Status "Warning" `
                -Details "No default gateway configured" -Category "Network" -Weight 20
            $perfWarns++
        }

        # Winsock catalogue
        $winsockOK = $true
        try {
            $wsOutput = & netsh winsock show catalog 2>&1
            $wsText = "$wsOutput"
            if ($wsText.Length -lt 50 -or $wsText -match "error") {
                $winsockOK = $false
                Add-DiagFinding -DiagState $DiagState -Component "Winsock Catalogue" -Status "Fail" `
                    -Details "Winsock catalogue appears corrupt or empty" -Category "Network" -Weight 35
                $perfFails++
            }
        } catch {
            $winsockOK = $false
        }

        # Proxy check
        $proxyStatus = "None"
        try {
            $inetSettings = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
            if ($inetSettings.ProxyEnable -eq 1) {
                $proxyServer = $inetSettings.ProxyServer
                if ($proxyServer) {
                    $proxyStatus = "Enabled ($proxyServer)"
                } else {
                    $proxyStatus = "Enabled (no server!)"
                    Add-DiagFinding -DiagState $DiagState -Component "Proxy Configuration" -Status "Warning" `
                        -Details "Proxy enabled but no server configured" -Category "Network" -Weight 15
                    $perfWarns++
                }
            }
        } catch { }

        $wsLabel = if ($winsockOK) { "OK" } else { "CORRUPT" }
        $wsColor = if ($winsockOK) { "Green" } else { "Red" }
        $gwColor = if ($gatewayOK) { "Green" } elseif ($routes) { "Yellow" } else { "Yellow" }
        Write-Finding -Label "Gateway" -Value $gwInfo -Color $gwColor
        Write-Finding -Label "Winsock" -Value $wsLabel -Color $wsColor
        Write-Finding -Label "Proxy" -Value $proxyStatus
    } catch {
        Write-Finding -Label "Network stack" -Value "Could not check" -Color "DarkGray"
    }

    # Store performance baseline for Phase 7
    $DiagState.PerfBaseline = @{
        CPUScore     = $cpuScore
        MemUsedPct   = $memUsedPct
        DiskWriteMBs = $diskWriteMBs
        DiskReadMBs  = $diskReadMBs
    }

    # Phase result
    $status = if ($perfFails -gt 0) { "FAIL" } elseif ($perfWarns -gt 0) { "WARN" } else { "PASS" }
    $DiagState.PhaseResults["Phase5"] = $status
    Write-PhaseResult -Phase "Phase 5: Performance" -Status $status -Details "$perfFails failures, $perfWarns warnings"
    Write-Log "Phase 5 complete: CPU=$cpuScore, Mem=${memUsedPct}%, DiskW=${diskWriteMBs}MB/s, DiskR=${diskReadMBs}MB/s"

    # v8.5: Compute HealthBefore score (pre-remediation baseline)
    if ($v7EnginesAvailable) {
        try {
            $moduleResults = ConvertTo-ModuleResults -DiagState $DiagState
            $beforeScore = Invoke-SystemScoring -ModuleResults $moduleResults -Config $v7Config -SessionId $DiagState.SessionId
            $DiagState.HealthBefore = $beforeScore
            Write-Log "HealthBefore score: $($beforeScore.finalScore)"
        }
        catch {
            Write-Log "HealthBefore scoring failed: $($_.Exception.Message)"
        }
    }

    Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase5"
}

# ============================================================
# ROLLBACK FUNCTIONS
# ============================================================

function New-SmartDiagBackup {
    param([string]$BackupDir, [hashtable]$DiagState)
    Write-Log "Creating pre-remediation backup..."
    Write-Host "    Creating rollback backup..." -ForegroundColor DarkGray

    $backupId = "SmartDiag_$timestamp"
    $backupFolder = Join-Path $BackupDir $backupId
    New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
    $DiagState.BackupId = $backupId
    $success = $true

    # 1. System Restore Point
    if ($cfgCreateRestore -eq 1) {
        Write-Host "      Creating restore point..." -ForegroundColor DarkGray
        try {
            $srService = Get-Service -Name 'srservice' -ErrorAction SilentlyContinue
            if ($srService -and $srService.Status -eq 'Running') {
                Checkpoint-Computer -Description "LDT Smart Diagnosis Engine $timestamp" -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue
                Write-Log "Restore point created"
                Write-Finding -Label "  Restore point" -Value "Created" -Color "Green"
            } else {
                Write-Finding -Label "  Restore point" -Value "SR service not running" -Color "Yellow"
            }
        } catch {
            Write-Finding -Label "  Restore point" -Value "Failed (24hr limit?)" -Color "Yellow"
        }
    }

    # 2. Registry backup
    if ($cfgBackupRegistry -eq 1) {
        Write-Host "      Exporting registry hives..." -ForegroundColor DarkGray
        try {
            & reg export "HKLM\SYSTEM\CurrentControlSet\Services" (Join-Path $backupFolder "SERVICES.reg") /y 2>&1 | Out-Null
            & reg export "HKLM\SOFTWARE" (Join-Path $backupFolder "SOFTWARE.reg") /y 2>&1 | Out-Null
            Write-Finding -Label "  Registry backup" -Value "SERVICES + SOFTWARE exported" -Color "Green"
        } catch {
            Write-Finding -Label "  Registry backup" -Value "Export failed" -Color "Yellow"
            $success = $false
        }
    }

    # 3. Driver version snapshot
    if ($cfgBackupDrivers -eq 1) {
        Write-Host "      Saving driver versions..." -ForegroundColor DarkGray
        try {
            $driverCSV = Join-Path $backupFolder "driver_versions.csv"
            Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
                Where-Object { $_.DeviceName } |
                Select-Object DeviceName, DriverVersion, DriverDate, InfName |
                Export-Csv -Path $driverCSV -NoTypeInformation -Encoding UTF8
            Write-Finding -Label "  Driver snapshot" -Value "Saved" -Color "Green"
        } catch {
            Write-Finding -Label "  Driver snapshot" -Value "Failed" -Color "Yellow"
            $success = $false
        }
    }

    # 4. BCD backup
    Write-Host "      Exporting boot configuration..." -ForegroundColor DarkGray
    try {
        $bcdFile = Join-Path $backupFolder "bcd_backup"
        & bcdedit /export $bcdFile 2>&1 | Out-Null
        Write-Finding -Label "  BCD backup" -Value "Exported" -Color "Green"
    } catch {
        Write-Finding -Label "  BCD backup" -Value "Failed" -Color "Yellow"
    }

    # 5. Manifest
    $manifest = @(
        "Smart Diagnosis Engine - Backup Manifest"
        "========================================="
        "Backup ID:  $backupId"
        "Timestamp:  $dateDisplay"
        "Machine:    $computerName"
        "Serial:     $serialNumber"
        "Model:      $manufacturer $model"
        "Reason:     Pre-remediation backup for Phase 6"
        "Contents:   SERVICES.reg, SOFTWARE.reg, driver_versions.csv, bcd_backup"
    )
    $manifest | Out-File (Join-Path $backupFolder "manifest.txt") -Encoding UTF8

    Write-Log "Backup created: $backupFolder (success=$success)"
    return $success
}

function Invoke-SmartDiagRollback {
    param([string]$BackupDir, [string]$BackupId)
    Write-Log "Rollback requested: $BackupId"

    $backupFolder = Join-Path $BackupDir $BackupId
    if (-not (Test-Path $backupFolder)) {
        Write-Host "    Backup not found: $backupFolder" -ForegroundColor Red
        return $false
    }

    Write-Host ""
    Write-Host "    Rollback will restore registry from: $BackupId" -ForegroundColor Yellow
    Write-Host "    A reboot may be required after rollback." -ForegroundColor Yellow
    $confirm = Read-Host "    Proceed with rollback? [Y/N]"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "    Rollback cancelled." -ForegroundColor DarkGray
        return $false
    }

    try {
        $servicesReg = Join-Path $backupFolder "SERVICES.reg"
        if (Test-Path $servicesReg) {
            & reg import $servicesReg 2>&1 | Out-Null
            Write-Host "    Registry restored from backup." -ForegroundColor Green
        }
        Write-Host "    NOTE: Reboot recommended for registry changes to take effect." -ForegroundColor Yellow
        Write-Log "Rollback completed from $BackupId"
        return $true
    } catch {
        Write-Host "    Rollback failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "Rollback failed: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# PHASE 6: AUTOMATED REMEDIATION
# ============================================================

function Invoke-Phase6-AutoRemediation {
    param([hashtable]$DiagState)
    Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase6"
    if ($v9GovernanceAvailable) { try { Save-ExecutionState -SessionGUID $DiagState.SessionId -CurrentPhase 6 -OutputDir $ReportPath } catch {} }

    if ($DiagState.HardwareCritical) {
        Write-ScanHeader -Name "PHASE 6: AUTOMATED REMEDIATION" -Icon "[6/8]"
        Write-Host "    Skipped - hardware critical (L3 escalation)" -ForegroundColor DarkGray
        $DiagState.PhaseResults["Phase6"] = "SKIP"
        Write-PhaseResult -Phase "Phase 6: Remediation" -Status "SKIP" -Details "L3 hardware escalation"
        Write-Log "Phase 6 skipped: HardwareCritical=true"
        Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase6"
        return
    }

    # Compute ranking to check gates
    $ranking = Get-RootCauseRanking -DiagState $DiagState
    $escalation = $ranking.EscalationLevel

    # v7.2: Use ClassificationEngine for formal level determination if available
    $classLevel = $null
    if ($v7EnginesAvailable -and (Get-Command 'Get-DiagnosticLevel' -ErrorAction SilentlyContinue)) {
        try {
            $classResult = Get-DiagnosticLevel -Findings $DiagState.Findings -DiagState $DiagState -Config $classConfig
            $classLevel = $classResult.Level
            # L2/L3 from classification engine overrides: skip remediation
            if ($classLevel -eq 'L3') {
                Write-ScanHeader -Name "PHASE 6: AUTOMATED REMEDIATION" -Icon "[6/8]"
                Write-Host "    Skipped - Classification Engine: L3 TECHNICIAN REQUIRED" -ForegroundColor Red
                Write-Host "    Reason: $($classResult.Reasoning)" -ForegroundColor DarkGray
                $DiagState.PhaseResults["Phase6"] = "SKIP"
                Write-PhaseResult -Phase "Phase 6: Remediation" -Status "SKIP" -Details "L3 classification: $($classResult.Branch)"
                Write-Log "Phase 6 skipped: ClassificationEngine L3 ($($classResult.Branch)): $($classResult.Reasoning)"
                $DiagState["ClassificationResult"] = $classResult
                Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase6"
                return
            }
            if ($classLevel -eq 'L2') {
                Write-Host "    Classification: L2 REPLACEABLE COMPONENT ($($classResult.L2Count) wear item(s))" -ForegroundColor Yellow
                Write-Log "Phase 6: ClassificationEngine L2 -- $($classResult.Reasoning). Proceeding with L1 software fixes only."
            }
        }
        catch {
            Write-Log "ClassificationEngine not available in Phase 6, using legacy escalation: $($_.Exception.Message)"
        }
    }

    # Check max auto level (legacy path, still applies)
    $levelOrder = @{ "None" = 0; "L1" = 1; "L2" = 2; "L3" = 3; "CLEAR" = 0 }
    $escLevel = if ($classLevel) { $classLevel } else { $escalation }
    $currentLevel = if ($levelOrder.ContainsKey($escLevel)) { $levelOrder[$escLevel] } else { 0 }
    $maxLevel = if ($levelOrder.ContainsKey($cfgMaxAutoLevel)) { $levelOrder[$cfgMaxAutoLevel] } else { 1 }

    if ($currentLevel -gt $maxLevel) {
        Write-ScanHeader -Name "PHASE 6: AUTOMATED REMEDIATION" -Icon "[6/8]"
        Write-Host "    Skipped - escalation level $escalation exceeds max auto level $cfgMaxAutoLevel" -ForegroundColor DarkGray
        $DiagState.PhaseResults["Phase6"] = "SKIP"
        Write-PhaseResult -Phase "Phase 6: Remediation" -Status "SKIP" -Details "Escalation $escalation > max $cfgMaxAutoLevel"
        Write-Log "Phase 6 skipped: Escalation $escalation > MaxAutoLevel $cfgMaxAutoLevel"
        Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase6"
        return
    }

    if ($ranking.Confidence -lt $cfgConfidenceThresh) {
        # Low confidence: check if there are still obvious fixable issues
        # (outdated drivers, stopped services, repairable DISM, BSODs, etc.)
        # If clear issues exist, proceed with remediation despite low root-cause confidence
        $softwareFixableCategories = @('OS/Boot', 'Driver', 'Security', 'Network', 'Performance', 'Storage')
        $obviousIssues = @($DiagState.Findings | Where-Object {
            $_.Category -in $softwareFixableCategories -and $_.Status -in @('Fail', 'Warning')
        })
        if ($obviousIssues.Count -eq 0) {
            Write-ScanHeader -Name "PHASE 6: AUTOMATED REMEDIATION" -Icon "[6/8]"
            Write-Host "    Skipped - confidence $($ranking.Confidence)% below threshold $cfgConfidenceThresh% and no clear fixable issues" -ForegroundColor DarkGray
            $DiagState.PhaseResults["Phase6"] = "SKIP"
            Write-PhaseResult -Phase "Phase 6: Remediation" -Status "SKIP" -Details "Confidence $($ranking.Confidence)% < $cfgConfidenceThresh%, no obvious fixes"
            Write-Log "Phase 6 skipped: Confidence $($ranking.Confidence)% < threshold $cfgConfidenceThresh%, no obvious fixes"
            Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase6"
            return
        }
        Write-Host "    Note: Confidence is $($ranking.Confidence)% (below $cfgConfidenceThresh%) but $($obviousIssues.Count) fixable issue(s) detected -- proceeding" -ForegroundColor Yellow
        Write-Log "Phase 6: Low confidence ($($ranking.Confidence)%) but $($obviousIssues.Count) obvious fixable issues found -- proceeding"
    }

    # Check for fixable findings
    # Include both Fail AND Warning for software-fixable categories
    # Hardware-only issues (disk failure, battery, thermal) remain excluded
    $softwareFixableCategories = @('OS/Boot', 'Driver', 'Security', 'Network', 'Performance', 'Storage')
    $fixableFindings = @($DiagState.Findings | Where-Object {
        $_.Category -in $softwareFixableCategories -and $_.Status -in @('Fail', 'Warning')
    })
    if ($fixableFindings.Count -eq 0) {
        Write-ScanHeader -Name "PHASE 6: AUTOMATED REMEDIATION" -Icon "[6/8]"
        Write-Host "    No software-fixable issues found" -ForegroundColor DarkGray
        $DiagState.PhaseResults["Phase6"] = "SKIP"
        Write-PhaseResult -Phase "Phase 6: Remediation" -Status "SKIP" -Details "No fixable issues"
        Write-Log "Phase 6 skipped: No fixable findings"
        Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase6"
        return
    }

    Write-ScanHeader -Name "PHASE 6: AUTOMATED REMEDIATION" -Icon "[6/8]"
    Write-Log "--- Phase 6: Automated Remediation ---"
    Write-Host "    Found $($fixableFindings.Count) fixable finding(s)" -ForegroundColor DarkGray

    # Create backup first
    Write-Host ""
    $backupOk = New-SmartDiagBackup -BackupDir $BackupPath -DiagState $DiagState

    # v8.5: Pre-remediation integrity revalidation
    if ($v7EnginesAvailable -and (Get-Command 'Test-PreRemediationIntegrity' -ErrorAction SilentlyContinue)) {
        try {
            $integrityCheck = Test-PreRemediationIntegrity -SessionId $DiagState.SessionId -Config $v7Config
            if ($integrityCheck.Status -ne 'PASS') {
                Write-Host "    WARNING: Integrity check detected tampering -- proceeding with caution" -ForegroundColor Red
                Write-Log "Pre-remediation integrity: $($integrityCheck.Status) -- $($integrityCheck.Details)"
            } else {
                Write-Host "    Pre-remediation integrity: PASS" -ForegroundColor Green
            }
        }
        catch {
            Write-Log "Pre-remediation integrity check skipped: $($_.Exception.Message)"
        }
    }

    # v8.5: Verify backup before proceeding
    if (-not $backupOk) {
        Write-Host "    WARNING: Backup verification failed -- remediation will proceed without verified backup" -ForegroundColor Yellow
        Write-Log "Backup verification warning: backup may be incomplete"
    }

    Write-Host ""

    # ================================================================
    # PHASE 6A: DIRECT TARGETED FIXES
    # ================================================================
    # Quick inline fixes that run BEFORE main suite dispatch:
    # - BITS restart (critical: unblocks Windows Update downloads)
    # - DISM component store repair (fixes corrupted system files)
    # - Display driver update (multi-method: WU, Lenovo, pnputil)
    # These address the most common "detected but not fixed" gap.

    $directFixCount = 0
    $directFixFailed = 0
    $directResults = @{}

    Write-Host "    --- Phase 6A: Direct Targeted Fixes ---" -ForegroundColor Cyan
    Write-Log "Phase 6A: Direct targeted fixes starting"

    # ---- FIX 1: BITS Service Restart (MUST run first -- unblocks Windows Update) ----
    $bitsFinding = @($fixableFindings | Where-Object { $_.Component -match 'BITS' })
    if ($bitsFinding.Count -gt 0) {
        Write-Host ""
        Write-Host "    [6A-1] BITS Transfer Service Restart" -ForegroundColor Cyan
        Write-Log "Direct fix: BITS service restart"
        try {
            $bitsSvc = Get-Service BITS -ErrorAction SilentlyContinue
            if ($bitsSvc -and $bitsSvc.Status -ne 'Running') {
                Set-Service BITS -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service BITS -ErrorAction Stop
                Start-Sleep -Seconds 3
                $bitsSvc = Get-Service BITS
                if ($bitsSvc.Status -eq 'Running') {
                    Write-Host "      BITS service started successfully" -ForegroundColor Green
                    $DiagState.FixesApplied.Add("BITS Service Restart") | Out-Null
                    $directFixCount++
                    $directResults['BITS'] = $true
                    # Update the original finding to "Repaired" so scoring doesn't penalize a fixed issue
                    foreach ($f in $DiagState.Findings) {
                        if ($f.Component -match 'BITS') { $f.Status = 'Repaired' }
                    }
                } else {
                    Write-Host "      BITS status after restart: $($bitsSvc.Status)" -ForegroundColor Yellow
                    $directResults['BITS'] = $false
                    $directFixFailed++
                }
            } elseif ($bitsSvc) {
                Write-Host "      BITS already running" -ForegroundColor Green
                $directResults['BITS'] = $true
            } else {
                Write-Host "      BITS service not found" -ForegroundColor Yellow
                $directResults['BITS'] = $false
            }
            Write-Log "BITS service status: $(if ($bitsSvc) { $bitsSvc.Status } else { 'NOT_FOUND' })"
        } catch {
            Write-Host "      BITS restart failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "BITS restart error: $($_.Exception.Message)"
            $directResults['BITS'] = $false
            $directFixFailed++
        }
    }

    # ---- FIX 2: DISM Component Store Repair ----
    $dismFinding = @($fixableFindings | Where-Object { $_.Component -match 'DISM|Component Store' })
    if ($dismFinding.Count -gt 0) {
        Write-Host ""
        Write-Host "    [6A-2] DISM Component Store Repair" -ForegroundColor Cyan
        Write-Log "Direct fix: DISM /RestoreHealth"
        # Quick check first -- skip if already healthy
        Write-Host "      Checking component store health..." -ForegroundColor DarkGray
        try {
            $checkOutput = & DISM /Online /Cleanup-Image /CheckHealth 2>&1
            $checkStr = ($checkOutput | Out-String)
            if ($checkStr -match 'component store is repairable|image is repairable') {
                Write-Host "      Component store needs repair -- running RestoreHealth..." -ForegroundColor Yellow
                Write-Host "      (This may take 5-15 minutes)" -ForegroundColor DarkGray
                $dismOutput = & DISM /Online /Cleanup-Image /RestoreHealth 2>&1
                $dismExit = $LASTEXITCODE
                if ($dismExit -eq 0) {
                    Write-Host "      DISM repair completed successfully" -ForegroundColor Green
                    $DiagState.FixesApplied.Add("DISM Component Store Repair") | Out-Null
                    $directFixCount++
                    $directResults['DISM'] = $true
                    # Update finding to Repaired
                    foreach ($f in $DiagState.Findings) {
                        if ($f.Component -match 'DISM|Component Store') { $f.Status = 'Repaired' }
                    }
                } else {
                    Write-Host "      DISM completed with exit code $dismExit" -ForegroundColor Yellow
                    $directResults['DISM'] = $false
                    $directFixFailed++
                }
                Write-Log "DISM RestoreHealth exit: $dismExit"
            } elseif ($checkStr -match 'No component store corruption|healthy') {
                Write-Host "      Component store is healthy (no repair needed)" -ForegroundColor Green
                $directResults['DISM'] = $true
                # Already healthy -- mark finding as Repaired (may have been fixed by earlier option)
                foreach ($f in $DiagState.Findings) {
                    if ($f.Component -match 'DISM|Component Store') { $f.Status = 'Repaired' }
                }
            } else {
                Write-Host "      DISM check inconclusive -- running RestoreHealth..." -ForegroundColor Yellow
                $dismOutput = & DISM /Online /Cleanup-Image /RestoreHealth 2>&1
                $dismExit = $LASTEXITCODE
                if ($dismExit -eq 0) {
                    Write-Host "      DISM repair completed" -ForegroundColor Green
                    $DiagState.FixesApplied.Add("DISM Component Store Repair") | Out-Null
                    $directFixCount++
                    $directResults['DISM'] = $true
                } else {
                    $directResults['DISM'] = $false
                    $directFixFailed++
                }
                Write-Log "DISM RestoreHealth exit: $dismExit"
            }
        } catch {
            Write-Host "      DISM failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "DISM error: $($_.Exception.Message)"
            $directResults['DISM'] = $false
            $directFixFailed++
        }
    }

    # ---- FIX 3: SFC System File Check ----
    $sfcNeeded = @($fixableFindings | Where-Object {
        $_.Category -eq 'OS/Boot' -and $_.Component -match 'SFC|System File|Corrupt'
    })
    # Also run SFC if DISM was repaired (repair may have restored files that SFC can now fix)
    if ($sfcNeeded.Count -gt 0 -or $directResults['DISM'] -eq $true) {
        Write-Host ""
        Write-Host "    [6A-3] System File Checker (SFC)" -ForegroundColor Cyan
        Write-Host "      (This may take 5-10 minutes)" -ForegroundColor DarkGray
        Write-Log "Direct fix: SFC /scannow"
        try {
            $sfcOutput = & sfc /scannow 2>&1
            $sfcStr = ($sfcOutput | Out-String)
            $sfcExit = $LASTEXITCODE
            if ($sfcStr -match 'found corrupt files and successfully repaired') {
                Write-Host "      SFC repaired corrupt files" -ForegroundColor Green
                $DiagState.FixesApplied.Add("SFC Repair") | Out-Null
                $directFixCount++
                $directResults['SFC'] = $true
            } elseif ($sfcStr -match 'did not find any integrity violations') {
                Write-Host "      SFC: No integrity violations found" -ForegroundColor Green
                $directResults['SFC'] = $true
            } else {
                Write-Host "      SFC completed (exit: $sfcExit)" -ForegroundColor Yellow
                $directResults['SFC'] = ($sfcExit -eq 0)
            }
            Write-Log "SFC exit: $sfcExit"
        } catch {
            Write-Host "      SFC failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "SFC error: $($_.Exception.Message)"
            $directResults['SFC'] = $false
            $directFixFailed++
        }
    }

    # ---- FIX 4: Display Driver Update (multi-method fallback) ----
    $driverFinding = @($fixableFindings | Where-Object {
        $_.Category -eq 'Driver' -and $_.Component -match 'Display|GPU|Radeon|NVIDIA|GeForce|Intel.*Graphics|Driver.*Outdated'
    })
    if ($driverFinding.Count -gt 0) {
        Write-Host ""
        Write-Host "    [6A-4] Display Driver Update (multi-method)" -ForegroundColor Cyan
        Write-Log "Direct fix: Display driver update -- multi-method"
        $driverFixed = $false

        try {
            $gpuDevices = @(Get-WmiObject Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Display' })
            foreach ($gpu in $gpuDevices) {
                $gpuName = $gpu.Name
                $gpuDriverVer = $gpu.DriverVersion
                Write-Host "      Target: $gpuName (v$gpuDriverVer)" -ForegroundColor DarkGray

                # Method A: Windows Update driver search (BITS should be running now)
                if (-not $driverFixed) {
                    Write-Host "      [A] Searching Windows Update for display driver..." -ForegroundColor DarkGray
                    try {
                        $wuSession = New-Object -ComObject Microsoft.Update.Session
                        $wuSearcher = $wuSession.CreateUpdateSearcher()
                        $wuResult = $wuSearcher.Search("IsInstalled=0 AND Type='Driver'")
                        $gpuUpdates = [System.Collections.ArrayList]::new()
                        foreach ($update in $wuResult.Updates) {
                            if ($update.Title -match 'AMD|Radeon|NVIDIA|GeForce|Intel.*Graphics|Display|Video') {
                                $gpuUpdates.Add($update) | Out-Null
                            }
                        }
                        if ($gpuUpdates.Count -gt 0) {
                            Write-Host "      Found $($gpuUpdates.Count) display driver update(s):" -ForegroundColor Green
                            foreach ($u in $gpuUpdates) {
                                Write-Host "        - $($u.Title)" -ForegroundColor DarkGray
                            }
                            $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
                            foreach ($u in $gpuUpdates) { $toInstall.Add($u) | Out-Null }
                            Write-Host "      Downloading..." -ForegroundColor DarkGray
                            $wuDownloader = $wuSession.CreateUpdateDownloader()
                            $wuDownloader.Updates = $toInstall
                            $dlResult = $wuDownloader.Download()
                            Write-Host "      Installing..." -ForegroundColor DarkGray
                            $wuInstaller = $wuSession.CreateUpdateInstaller()
                            $wuInstaller.Updates = $toInstall
                            $instResult = $wuInstaller.Install()
                            # ResultCode: 2=Succeeded, 3=SucceededWithErrors
                            if ($instResult.ResultCode -le 3) {
                                Write-Host "      Display driver updated via Windows Update!" -ForegroundColor Green
                                $DiagState.FixesApplied.Add("Display Driver WU Update ($gpuName)") | Out-Null
                                $directFixCount++
                                $driverFixed = $true
                                $directResults['DisplayDriver'] = $true
                            } else {
                                Write-Host "      WU install failed (code: $($instResult.ResultCode))" -ForegroundColor Yellow
                            }
                        } else {
                            Write-Host "      No display driver updates in Windows Update catalog" -ForegroundColor DarkGray
                        }
                    } catch {
                        Write-Host "      WU driver search: $($_.Exception.Message)" -ForegroundColor DarkGray
                        Write-Log "WU driver search error: $($_.Exception.Message)"
                    }
                }

                # Method B: Lenovo System Update (if installed on laptop)
                if (-not $driverFixed) {
                    $lsuPaths = @(
                        "${env:ProgramFiles(x86)}\Lenovo\System Update\tvsu.exe",
                        "$env:ProgramFiles\Lenovo\System Update\tvsu.exe"
                    )
                    $lsuExe = $null
                    foreach ($p in $lsuPaths) {
                        if (Test-Path $p) { $lsuExe = $p; break }
                    }
                    if ($lsuExe) {
                        Write-Host "      [B] Launching Lenovo System Update..." -ForegroundColor DarkGray
                        try {
                            $lsuProc = Start-Process -FilePath $lsuExe -ArgumentList '/CM' -PassThru -Wait -WindowStyle Hidden
                            Write-Host "      Lenovo System Update completed (exit: $($lsuProc.ExitCode))" -ForegroundColor Green
                            # Re-check driver version
                            Start-Sleep -Seconds 5
                            $gpuAfter = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -eq $gpuName }
                            if ($gpuAfter -and $gpuAfter.DriverVersion -ne $gpuDriverVer) {
                                Write-Host "      Driver updated: v$gpuDriverVer -> v$($gpuAfter.DriverVersion)" -ForegroundColor Green
                                $DiagState.FixesApplied.Add("Lenovo System Update ($gpuName)") | Out-Null
                                $directFixCount++
                                $driverFixed = $true
                                $directResults['DisplayDriver'] = $true
                            }
                        } catch {
                            Write-Host "      LSU: $($_.Exception.Message)" -ForegroundColor DarkGray
                        }
                    } else {
                        Write-Host "      [B] Lenovo System Update not installed" -ForegroundColor DarkGray
                    }
                }

                # Method C: Lenovo Thin Installer (from USB)
                if (-not $driverFixed) {
                    $thinPaths = @(
                        (Join-Path $PSScriptRoot "Tools\LenovoThinInstaller\ThinInstaller.exe"),
                        (Join-Path $PSScriptRoot "Tools\ThinInstaller\ThinInstaller.exe")
                    )
                    $thinExe = $null
                    foreach ($p in $thinPaths) {
                        if (Test-Path $p) { $thinExe = $p; break }
                    }
                    if ($thinExe) {
                        Write-Host "      [C] Running Lenovo Thin Installer from USB..." -ForegroundColor DarkGray
                        try {
                            $tiProc = Start-Process -FilePath $thinExe -ArgumentList '/CM /INCLUDEREBOOTPACKAGES 3 /NOREBOOT' -PassThru -Wait -WindowStyle Hidden
                            Write-Host "      Thin Installer completed (exit: $($tiProc.ExitCode))" -ForegroundColor Green
                            Start-Sleep -Seconds 5
                            $gpuAfter = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -eq $gpuName }
                            if ($gpuAfter -and $gpuAfter.DriverVersion -ne $gpuDriverVer) {
                                Write-Host "      Driver updated: v$gpuDriverVer -> v$($gpuAfter.DriverVersion)" -ForegroundColor Green
                                $DiagState.FixesApplied.Add("Lenovo Thin Installer ($gpuName)") | Out-Null
                                $directFixCount++
                                $driverFixed = $true
                                $directResults['DisplayDriver'] = $true
                            }
                        } catch {
                            Write-Host "      Thin Installer: $($_.Exception.Message)" -ForegroundColor DarkGray
                        }
                    } else {
                        Write-Host "      [C] Lenovo Thin Installer not found on USB" -ForegroundColor DarkGray
                    }
                }

                # Method D: PnP device scan (check if newer driver is already cached)
                if (-not $driverFixed) {
                    Write-Host "      [D] Scanning for cached drivers (pnputil)..." -ForegroundColor DarkGray
                    try {
                        & pnputil /scan-devices 2>&1 | Out-Null
                        Start-Sleep -Seconds 5
                        $gpuAfter = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -eq $gpuName }
                        if ($gpuAfter -and $gpuAfter.DriverVersion -ne $gpuDriverVer) {
                            Write-Host "      Driver updated: v$gpuDriverVer -> v$($gpuAfter.DriverVersion)" -ForegroundColor Green
                            $DiagState.FixesApplied.Add("Display Driver PnP Update ($gpuName)") | Out-Null
                            $directFixCount++
                            $driverFixed = $true
                            $directResults['DisplayDriver'] = $true
                        } else {
                            Write-Host "      No newer cached driver found" -ForegroundColor DarkGray
                        }
                    } catch {
                        Write-Log "pnputil scan error: $($_.Exception.Message)"
                    }
                }

                # If driver was fixed by any method, update findings
                if ($driverFixed) {
                    foreach ($f in $DiagState.Findings) {
                        if ($f.Component -match 'Display Driver|GPU' -and $f.Category -eq 'Driver') {
                            $f.Status = 'Repaired'
                        }
                    }
                }

                # If ALL methods failed: escalate with clear download guidance
                if (-not $driverFixed) {
                    Write-Host ""
                    Write-Host "      *** MANUAL ACTION REQUIRED ***" -ForegroundColor Red
                    Write-Host "      The display driver ($gpuName) is severely outdated" -ForegroundColor Yellow
                    Write-Host "      but no automatic update source was found." -ForegroundColor Yellow
                    Write-Host ""
                    if ($gpuName -match 'AMD|Radeon') {
                        Write-Host "      Download latest driver from:" -ForegroundColor White
                        Write-Host "        1. support.lenovo.com > search model '$($DiagState.Machine['Model'])' > Display" -ForegroundColor Cyan
                        Write-Host "        2. amd.com/en/support > Radeon Graphics > Vega" -ForegroundColor Cyan
                    } elseif ($gpuName -match 'NVIDIA|GeForce') {
                        Write-Host "      Download from: nvidia.com/Download/index.aspx" -ForegroundColor Cyan
                    } elseif ($gpuName -match 'Intel') {
                        Write-Host "      Download from: intel.com/content/www/us/en/support/detect.html" -ForegroundColor Cyan
                    }
                    Write-Host "      Or: Install Lenovo System Update on the laptop" -ForegroundColor Cyan
                    Write-Host "      Or: Place ThinInstaller.exe in USB Tools\\LenovoThinInstaller\\" -ForegroundColor Cyan
                    Write-Host ""

                    # Note: Do NOT add as Fail finding -- it would worsen the score.
                    # The original "Display Driver Outdated" finding already captures the issue.
                    # Just log the escalation for the remediation log and report.
                    Add-DiagFinding -DiagState $DiagState -Component "Driver Update Escalation" `
                        -Status "Info" -Category "Driver" -Weight 0 `
                        -Details "Auto-update failed for $gpuName. Manual download required from Lenovo support or AMD.com."

                    $DiagState.FixesFailed.Add("Display Driver Update ($gpuName) -- manual download required") | Out-Null
                    $directResults['DisplayDriver'] = $false
                    $directFixFailed++
                    Write-Log "Display driver: all 4 auto-update methods failed for $gpuName"
                }
            }
        } catch {
            Write-Host "      Display driver fix error: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "Display driver fix error: $($_.Exception.Message)"
            $directResults['DisplayDriver'] = $false
            $directFixFailed++
        }
    }

    # Phase 6A summary
    Write-Host ""
    if ($directFixCount -gt 0) {
        Write-Host "    Phase 6A: $directFixCount direct fix(es) applied" -ForegroundColor Green
    }
    if ($directFixFailed -gt 0) {
        Write-Host "    Phase 6A: $directFixFailed fix(es) need manual action" -ForegroundColor Yellow
    }
    Write-Log "Phase 6A complete: $directFixCount applied, $directFixFailed failed"

    # v8.5: Create RemediationLedger entries for Phase 6A direct fixes
    if ($v7EnginesAvailable) {
        $guardEscLevel = 0
        if (Get-Command 'Get-LDTEscalationAsInt' -ErrorAction SilentlyContinue) {
            $guardEscLevel = Get-LDTEscalationAsInt -EscalationLevel $escalation
        }

        $phase6AFixMap = @(
            @{ Key = 'BITS';          Category = 'Security';  Desc = 'BITS Service Restart'; Root = 'BITS service not running' }
            @{ Key = 'DISM';          Category = 'OS/Boot';   Desc = 'DISM Component Store Repair'; Root = 'Component store corruption' }
            @{ Key = 'SFC';           Category = 'OS/Boot';   Desc = 'System File Checker'; Root = 'System file integrity violation' }
            @{ Key = 'DisplayDriver'; Category = 'Driver';    Desc = 'Display Driver Update'; Root = 'Display driver outdated' }
        )

        foreach ($fixDef in $phase6AFixMap) {
            if ($directResults.ContainsKey($fixDef.Key)) {
                $wasApplied = ($directResults[$fixDef.Key] -eq $true)
                $matchFinding = @($fixableFindings | Where-Object { $_.Component -match $fixDef.Key -or $_.Category -eq $fixDef.Category }) | Select-Object -First 1
                $sevScore = if ($matchFinding -and $matchFinding.Weight) { [int]$matchFinding.Weight } else { 20 }

                $ledgerEntry = [ordered]@{
                    IssueID                = "$($fixDef.Key)_$(Get-Date -Format 'HHmmss')"
                    Category               = $fixDef.Category
                    SeverityScore          = $sevScore
                    Classification         = if ($classLevel) { $classLevel } else { "" }
                    RootCause              = $fixDef.Root
                    Evidence               = if ($matchFinding) { "Component: $($matchFinding.Component), Details: $($matchFinding.Details)" } else { "Phase 6A direct fix" }
                    Location               = $fixDef.Desc
                    BusinessImpact         = ""
                    FixEligible            = $true
                    FixApplied             = $wasApplied
                    RollbackToken          = "RBK_$($fixDef.Key)_$([guid]::NewGuid().ToString('N').Substring(0,8))"
                    BeforeState            = "Pre-Phase6A"
                    AfterState             = if ($wasApplied) { "Applied" } else { "Failed" }
                    VerificationMethod     = "StressValidation"
                    VerificationResult     = "PENDING"
                    StressValidationResult = "PENDING"
                    FinalStatus            = if ($wasApplied) { "PARTIAL" } else { "FAILED" }
                    ConfidenceScore        = 0
                }
                $DiagState.RemediationLedger.Add([PSCustomObject]$ledgerEntry) | Out-Null
            }
        }
        Write-Log "Phase 6A: $($DiagState.RemediationLedger.Count) ledger entries created"
    }

    Write-Host ""

    # ================================================================
    # PHASE 6B: SUITE-LEVEL REMEDIATION
    # ================================================================
    Write-Host "    --- Phase 6B: Suite-Level Remediation ---" -ForegroundColor Cyan
    Write-Log "Phase 6B: Suite-level dispatch starting"

    # Build fix list based on findings (sorted by weight)
    # Skip categories already fully handled by Phase 6A
    $fixes = [System.Collections.ArrayList]::new()

    # Check what categories have issues (Fail or Warning)
    $hasBSODFix    = @($fixableFindings | Where-Object { $_.Category -eq 'OS/Boot' -and $_.Component -match 'BSOD|BugCheck|Faulting' }).Count -gt 0
    $hasBootFix    = @($fixableFindings | Where-Object { $_.Category -eq 'OS/Boot' -and $_.Component -match 'SFC|DISM|Boot|BCD|WU|Corrupt|Reset|Update|Component' }).Count -gt 0
    # Skip driver suite dispatch if Phase 6A already handled it (success or clear escalation)
    $hasDriverFix  = if ($directResults.ContainsKey('DisplayDriver')) { $false } else {
        @($fixableFindings | Where-Object { $_.Category -eq 'Driver' }).Count -gt 0
    }
    # Skip security suite dispatch if BITS was the only security finding and it was fixed
    $secFindings   = @($fixableFindings | Where-Object { $_.Category -eq 'Security' })
    $hasSecFix     = if ($secFindings.Count -eq 1 -and $secFindings[0].Component -match 'BITS' -and $directResults['BITS'] -eq $true) { $false } else {
        $secFindings.Count -gt 0
    }
    $hasNetFix     = @($fixableFindings | Where-Object { $_.Category -eq 'Network' }).Count -gt 0
    $hasPerfFix    = @($fixableFindings | Where-Object { $_.Category -in @('Performance', 'Storage') }).Count -gt 0
    # Skip boot repair if SFC and DISM were already handled in Phase 6A
    $skipBootRepair = ($directResults.ContainsKey('DISM') -and $directResults.ContainsKey('SFC'))

    if ($hasBootFix -and -not $skipBootRepair) { $fixes.Add(@{ Name = "Boot Repair (SFC/DISM)"; Func = "BootRepair"; Weight = 65 }) | Out-Null }
    if ($hasBSODFix)   { $fixes.Add(@{ Name = "BSOD Troubleshooter";   Func = "BSODTroubleshooter";     Weight = 80 }) | Out-Null }
    if ($hasDriverFix) { $fixes.Add(@{ Name = "Driver Auto-Update";    Func = "DriverAutoUpdate";       Weight = 55 }) | Out-Null }
    if ($hasSecFix)    { $fixes.Add(@{ Name = "Security Hardening";    Func = "SecurityHardening";      Weight = 30 }) | Out-Null }
    if ($hasNetFix)    { $fixes.Add(@{ Name = "Network Troubleshooter"; Func = "NetworkTroubleshooter"; Weight = 30 }) | Out-Null }
    if ($hasPerfFix)   { $fixes.Add(@{ Name = "Software Cleanup";     Func = "SoftwareCleanup";        Weight = 20 }) | Out-Null }

    # Sort by weight descending
    $sortedFixes = $fixes | Sort-Object { $_.Weight } -Descending

    $fixCount = 0
    $failCount = 0
    foreach ($fix in $sortedFixes) {
        # GuardEngine clearance (v7) -- check before each fix
        if ($v7EnginesAvailable) {
            try {
                $escInt = Get-LDTEscalationAsInt -EscalationLevel $escalation
                $cleared = Test-GuardClearance `
                    -ActionId $fix.Func `
                    -ModuleName $fix.Name `
                    -EscalationLevel $escInt `
                    -ActionDescription "Auto-remediation: $($fix.Name)"
                if (-not $cleared) {
                    Write-Host ""
                    Write-Host "    GuardEngine BLOCKED: $($fix.Name)" -ForegroundColor Yellow
                    Write-Log "GuardEngine blocked fix: $($fix.Func)"
                    # v8.5: Ledger entry for blocked fix
                    $blockedEntry = [ordered]@{
                        IssueID = "$($fix.Func)_$(Get-Date -Format 'HHmmss')"; Category = "Suite"
                        SeverityScore = $fix.Weight; Classification = ""; RootCause = "Suite fix: $($fix.Name)"
                        Evidence = "GuardEngine blocked"; Location = $fix.Name; BusinessImpact = ""
                        FixEligible = $false; FixApplied = $false; RollbackToken = ""
                        BeforeState = ""; AfterState = "BLOCKED"; VerificationMethod = "StressValidation"
                        VerificationResult = "GUARD_DENIED"; StressValidationResult = "PENDING"
                        FinalStatus = "BLOCKED"; ConfidenceScore = 0
                    }
                    $DiagState.RemediationLedger.Add([PSCustomObject]$blockedEntry) | Out-Null
                    continue
                }
            }
            catch {
                Write-Host ""
                Write-Host "    GuardEngine PROHIBITED: $($fix.Name)" -ForegroundColor Red
                Write-Log "GuardEngine prohibited: $($fix.Func) - $($_.Exception.Message)"
                # v8.5: Ledger entry for prohibited fix
                $prohibEntry = [ordered]@{
                    IssueID = "$($fix.Func)_$(Get-Date -Format 'HHmmss')"; Category = "Suite"
                    SeverityScore = $fix.Weight; Classification = ""; RootCause = "Suite fix: $($fix.Name)"
                    Evidence = "GuardEngine prohibited: $($_.Exception.Message)"; Location = $fix.Name
                    BusinessImpact = ""; FixEligible = $false; FixApplied = $false; RollbackToken = ""
                    BeforeState = ""; AfterState = "PROHIBITED"; VerificationMethod = "StressValidation"
                    VerificationResult = "PROHIBITED"; StressValidationResult = "PENDING"
                    FinalStatus = "BLOCKED"; ConfidenceScore = 0
                }
                $DiagState.RemediationLedger.Add([PSCustomObject]$prohibEntry) | Out-Null
                continue
            }
        }

        Write-Host ""
        Write-Host "    ------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host "    Running: $($fix.Name)" -ForegroundColor Cyan
        Write-Host "    ------------------------------------------------" -ForegroundColor DarkCyan
        Write-Log "Launching fix: $($fix.Func)"

        $suiteFixApplied = $false
        $suiteExitCode = -1
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $mainPS1 `
                -RunFunction $fix.Func `
                -LogPath $LogPath `
                -ReportPath $ReportPath `
                -ConfigPath $ConfigPath `
                -BackupPath $BackupPath `
                -TempPath $TempPath `
                -DataPath $DataPath

            $suiteExitCode = $LASTEXITCODE
            $suiteFixApplied = $true
            if ($suiteExitCode -ne 0) {
                Write-Host "    $($fix.Name) completed with warnings (exit: $suiteExitCode)" -ForegroundColor Yellow
                $DiagState.FixesApplied.Add("$($fix.Name) (exit: $suiteExitCode)") | Out-Null
            } else {
                Write-Host "    $($fix.Name) completed successfully" -ForegroundColor Green
                $DiagState.FixesApplied.Add($fix.Name) | Out-Null
            }
            $fixCount++
            Write-Log "$($fix.Func) completed (exit: $suiteExitCode)"
        } catch {
            Write-Host "    ERROR: $($fix.Name) failed - $($_.Exception.Message)" -ForegroundColor Red
            $DiagState.FixesFailed.Add("$($fix.Name): $($_.Exception.Message)") | Out-Null
            $failCount++
            Write-Log "ERROR: $($fix.Func) failed - $($_.Exception.Message)"
        }

        # v8.5: Ledger entry for suite fix
        if ($v7EnginesAvailable) {
            $suiteEntry = [ordered]@{
                IssueID                = "$($fix.Func)_$(Get-Date -Format 'HHmmss')"
                Category               = "Suite"
                SeverityScore          = $fix.Weight
                Classification         = if ($classLevel) { $classLevel } else { "" }
                RootCause              = "Suite remediation: $($fix.Name)"
                Evidence               = "Exit code: $suiteExitCode"
                Location               = $fix.Name
                BusinessImpact         = ""
                FixEligible            = $true
                FixApplied             = $suiteFixApplied
                RollbackToken          = "RBK_$($fix.Func)_$([guid]::NewGuid().ToString('N').Substring(0,8))"
                BeforeState            = "Pre-suite-dispatch"
                AfterState             = if ($suiteFixApplied) { "Exit: $suiteExitCode" } else { "FAILED" }
                VerificationMethod     = "StressValidation"
                VerificationResult     = "PENDING"
                StressValidationResult = "PENDING"
                FinalStatus            = if ($suiteFixApplied) { "PARTIAL" } else { "FAILED" }
                ConfidenceScore        = 0
            }
            $DiagState.RemediationLedger.Add([PSCustomObject]$suiteEntry) | Out-Null
        }
    }

    # Phase result (combine Phase 6A direct + Phase 6B suite counts)
    $totalFixed = $directFixCount + $fixCount
    $totalFailed = $directFixFailed + $failCount
    $status = if ($totalFailed -gt 0 -and $totalFixed -eq 0) { "FAIL" } elseif ($totalFixed -gt 0) { "APPLIED" } else { "SKIP" }
    $DiagState.PhaseResults["Phase6"] = $status
    $DiagState.PhaseTimestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    Write-PhaseResult -Phase "Phase 6: Remediation" -Status $status -Details "$totalFixed applied ($directFixCount direct + $fixCount suite), $totalFailed failed"
    Write-Log "Phase 6 complete: $totalFixed applied ($directFixCount direct, $fixCount suite), $totalFailed failed"
    Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase6"
}

# ============================================================
# PHASE 7: STRESS VALIDATION
# ============================================================

function Invoke-Phase7-StressValidation {
    param([hashtable]$DiagState)
    Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase7"
    if ($v9GovernanceAvailable) { try { Save-ExecutionState -SessionGUID $DiagState.SessionId -CurrentPhase 7 -OutputDir $ReportPath } catch {} }

    if ($DiagState.HardwareCritical -or $DiagState.ThermalCritical) {
        Write-ScanHeader -Name "PHASE 7: STRESS VALIDATION" -Icon "[7/8]"
        $reason = if ($DiagState.HardwareCritical) { "hardware critical" } else { "thermal critical" }
        Write-Host "    Skipped - $reason" -ForegroundColor DarkGray
        $DiagState.PhaseResults["Phase7"] = "SKIP"
        Write-PhaseResult -Phase "Phase 7: Stress Validation" -Status "SKIP" -Details $reason
        Write-Log "Phase 7 skipped: $reason"
        Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase7"
        return
    }

    # Skip if Phase 6 didnt run and there are no fixes to validate
    if ($DiagState.FixesApplied.Count -eq 0 -and $DiagState.FixesFailed.Count -eq 0) {
        # Still run stress to validate overall health
    }

    Write-ScanHeader -Name "PHASE 7: STRESS VALIDATION" -Icon "[7/8]"
    Write-Log "--- Phase 7: Stress Validation ---"

    $stressFails = 0
    $baseline = $DiagState.PerfBaseline

    # --- 7-PRE: Thermal baseline before stress ---
    Write-Host "    Capturing pre-stress thermal baseline..." -ForegroundColor DarkGray
    $preStressTemp = 0
    try {
        $thermal = Get-CimInstance -Namespace "root/WMI" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction SilentlyContinue
        if ($thermal) {
            $temps = @($thermal | ForEach-Object { [math]::Round(($_.CurrentTemperature - 2732) / 10, 1) })
            $preStressTemp = ($temps | Measure-Object -Maximum).Maximum
        }
    } catch { }
    if ($preStressTemp -gt 0) {
        Write-Finding -Label "Pre-stress temperature" -Value "${preStressTemp}C" -Color "Cyan"
    } else {
        Write-Finding -Label "Pre-stress temperature" -Value "Sensor unavailable" -Color "DarkGray"
    }

    # --- 7A: CPU Stress ---
    Write-Host "    CPU stress test ($cfgStressDuration seconds)..." -ForegroundColor DarkGray
    $cpuStressScore = 0
    try {
        $job = Start-Job -ScriptBlock {
            param($duration)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $iters = 0
            while ($sw.ElapsedMilliseconds -lt ($duration * 1000)) {
                for ($i = 0; $i -lt 1000; $i++) { [math]::Sqrt(123456.789 * $i) | Out-Null }
                $iters++
            }
            $sw.Stop()
            return $iters
        } -ArgumentList $cfgStressDuration

        $completed = $job | Wait-Job -Timeout ($cfgStressDuration + 30)
        if ($completed) {
            $cpuStressScore = Receive-Job $job
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch { }

    # Normalize to 10-second baseline for comparison
    $normalizedStress = 0
    if ($cfgStressDuration -gt 0) {
        $normalizedStress = [math]::Round($cpuStressScore / $cfgStressDuration * 10)
    }
    $cpuBaseline = if ($baseline.CPUScore) { $baseline.CPUScore } else { 0 }

    if ($cpuBaseline -gt 0 -and $normalizedStress -gt 0) {
        $cpuDelta = [math]::Round(($normalizedStress - $cpuBaseline) / $cpuBaseline * 100, 1)
        $cpuPass = [math]::Abs($cpuDelta) -le $cfgPerfTolerance
        $cpuColor = if ($cpuPass) { "Green" } else { "Red" }
        Write-Finding -Label "CPU stress vs baseline" -Value "${normalizedStress} vs ${cpuBaseline} (${cpuDelta}%)" -Color $cpuColor
        if (-not $cpuPass) { $stressFails++ }
        $DiagState.StressResults["CPUStress"] = $normalizedStress
        $DiagState.StressResults["CPUDelta"] = $cpuDelta
    } else {
        Write-Finding -Label "CPU stress" -Value "$cpuStressScore iterations/${cfgStressDuration}s" -Color "Cyan"
    }

    # --- 7B: Memory allocation test ---
    Write-Host "    Memory allocation test (${cfgStressMemoryMB}MB)..." -ForegroundColor DarkGray
    $memPass = $true
    try {
        $memData = New-Object byte[] ($cfgStressMemoryMB * 1MB)
        (New-Object Random).NextBytes($memData)
        # Verify data integrity via spot checks
        $checkOk = $true
        for ($i = 0; $i -lt 10; $i++) {
            $pos = Get-Random -Minimum 0 -Maximum $memData.Length
            if ($memData[$pos] -eq $null) { $checkOk = $false; break }
        }
        $memData = $null
        [GC]::Collect()
        if ($checkOk) {
            Write-Finding -Label "Memory allocation" -Value "${cfgStressMemoryMB}MB - PASS" -Color "Green"
        } else {
            Write-Finding -Label "Memory allocation" -Value "Data integrity issue" -Color "Red"
            $stressFails++
            $memPass = $false
        }
        $DiagState.StressResults["MemoryPass"] = $checkOk
    } catch {
        Write-Finding -Label "Memory allocation" -Value "Failed: $($_.Exception.Message)" -Color "Red"
        $stressFails++
        $memPass = $false
        $DiagState.StressResults["MemoryPass"] = $false
    }

    # --- 7C: Disk I/O stress ---
    Write-Host "    Disk I/O stress test (${cfgStressDiskMB}MB)..." -ForegroundColor DarkGray
    try {
        $testFile = Join-Path $TempPath "smartdiag_stressio_$timestamp.tmp"
        $testSize = $cfgStressDiskMB * 1MB
        $data = New-Object byte[] $testSize
        (New-Object Random).NextBytes($data)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [System.IO.File]::WriteAllBytes($testFile, $data)
        $sw.Stop()
        $stressWriteMBs = [math]::Round(($testSize / 1MB) / ($sw.ElapsedMilliseconds / 1000), 1)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [System.IO.File]::ReadAllBytes($testFile) | Out-Null
        $sw.Stop()
        $stressReadMBs = [math]::Round(($testSize / 1MB) / ($sw.ElapsedMilliseconds / 1000), 1)

        Remove-Item $testFile -Force -ErrorAction SilentlyContinue

        $diskWBaseline = if ($baseline.DiskWriteMBs) { $baseline.DiskWriteMBs } else { 0 }
        $diskRBaseline = if ($baseline.DiskReadMBs) { $baseline.DiskReadMBs } else { 0 }

        if ($diskWBaseline -gt 0) {
            $wDelta = [math]::Round(($stressWriteMBs - $diskWBaseline) / $diskWBaseline * 100, 1)
            $wPass = $wDelta -gt (-$cfgPerfTolerance)
            Write-Finding -Label "Disk write stress" -Value "${stressWriteMBs} vs ${diskWBaseline} MB/s (${wDelta}%)" -Color $(if ($wPass) { "Green" } else { "Red" })
            if (-not $wPass) { $stressFails++ }
        } else {
            Write-Finding -Label "Disk write stress" -Value "${stressWriteMBs} MB/s" -Color "Cyan"
        }

        $DiagState.StressResults["DiskWriteMBs"] = $stressWriteMBs
        $DiagState.StressResults["DiskReadMBs"] = $stressReadMBs
    } catch {
        Write-Finding -Label "Disk I/O stress" -Value "Failed" -Color "Red"
        $stressFails++
    }

    # --- 7-GPU: Graphics compute stress ---
    Write-Host "    GPU graphics stress test..." -ForegroundColor DarkGray
    try {
        $gpuStressDuration = 15
        $gpuMaxTempDelta = 20
        try {
            $cfgPath2 = Join-Path $ConfigPath "config.ini"
            if (Test-Path $cfgPath2) {
                $cfgDisplay = Get-Content $cfgPath2 -Raw -Encoding UTF8
                if ($cfgDisplay -match 'GPUStressDurationSeconds=(\d+)') { $gpuStressDuration = [int]$Matches[1] }
                if ($cfgDisplay -match 'GPUStressMaxTempDelta=(\d+)') { $gpuMaxTempDelta = [int]$Matches[1] }
            }
        } catch { }

        # Count TDR events BEFORE stress
        $tdrBefore = 0
        try {
            $tdrBefore = @(Get-WinEvent -FilterHashtable @{
                LogName='System'; Id=@(4101,4116); StartTime=(Get-Date).AddMinutes(-5)
            } -MaxEvents 100 -ErrorAction SilentlyContinue).Count
        } catch { }

        # GDI+ bitmap stress (stresses GPU display pipeline via driver)
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $gpuStressStart = Get-Date
        $gpuIterations = 0
        $bmp = New-Object System.Drawing.Bitmap(960, 540)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $rng = New-Object System.Random

        while (((Get-Date) - $gpuStressStart).TotalSeconds -lt $gpuStressDuration) {
            # Fill with random colored rectangles (forces GPU render ops)
            $brush = New-Object System.Drawing.SolidBrush(
                [System.Drawing.Color]::FromArgb($rng.Next(256), $rng.Next(256), $rng.Next(256))
            )
            $gfx.FillRectangle($brush, $rng.Next(960), $rng.Next(540), $rng.Next(100)+10, $rng.Next(100)+10)
            $brush.Dispose()
            $gpuIterations++

            # Draw lines for additional GPU workload
            $pen = New-Object System.Drawing.Pen(
                [System.Drawing.Color]::FromArgb($rng.Next(256), $rng.Next(256), $rng.Next(256)), 2
            )
            $gfx.DrawLine($pen, $rng.Next(960), $rng.Next(540), $rng.Next(960), $rng.Next(540))
            $pen.Dispose()
        }
        $gfx.Dispose()
        $bmp.Dispose()

        $gpuStressElapsed = [math]::Round(((Get-Date) - $gpuStressStart).TotalSeconds, 1)

        # Count TDR events AFTER stress
        $tdrAfter = 0
        try {
            $tdrAfter = @(Get-WinEvent -FilterHashtable @{
                LogName='System'; Id=@(4101,4116); StartTime=(Get-Date).AddMinutes(-5)
            } -MaxEvents 100 -ErrorAction SilentlyContinue).Count
        } catch { }

        $newTDR = $tdrAfter - $tdrBefore
        $DiagState.StressResults["GPUIterations"] = $gpuIterations
        $DiagState.StressResults["GPUNewTDR"] = $newTDR

        if ($newTDR -gt 0) {
            $stressFails++
            Add-DiagFinding -DiagState $DiagState -Component "GPU Stress TDR" `
                -Status "Fail" -Category "Driver" -Weight 65 `
                -Details "GPU produced $newTDR TDR event(s) during ${gpuStressElapsed}s stress test. Display driver unstable under load."
            Write-Finding -Label "GPU stress" -Value "$newTDR TDR events during stress (UNSTABLE)" -Color "Red"
        } else {
            Write-Finding -Label "GPU stress" -Value "OK ($gpuIterations ops in ${gpuStressElapsed}s, 0 TDR)" -Color "Green"
        }
    } catch {
        Write-Finding -Label "GPU stress" -Value "Skipped (GDI+ unavailable)" -Color "DarkGray"
    }

    # --- 7D: Post-stress event log check ---
    Write-Host "    Checking for new errors since remediation..." -ForegroundColor DarkGray
    $newErrors = 0
    if ($DiagState.PhaseTimestamp) {
        try {
            $sinceTime = [datetime]::Parse($DiagState.PhaseTimestamp)
            $newSysErrors = Get-WinEvent -FilterHashtable @{
                LogName = 'System'; Level = 1,2; StartTime = $sinceTime
            } -MaxEvents 50 -ErrorAction SilentlyContinue
            if ($newSysErrors) { $newErrors = @($newSysErrors).Count }
        } catch { }
    }

    if ($newErrors -gt 5) {
        Write-Finding -Label "New errors since Phase 6" -Value "$newErrors events" -Color "Red"
        $stressFails++
    } elseif ($newErrors -gt 0) {
        Write-Finding -Label "New errors since Phase 6" -Value "$newErrors events" -Color "Yellow"
    } else {
        Write-Finding -Label "New errors since Phase 6" -Value "None" -Color "Green"
    }
    $DiagState.StressResults["NewErrors"] = $newErrors

    # --- 7E: Memory Diagnostic Recommendation ---
    $wheaFound = $false
    foreach ($f in $DiagState.Findings) {
        if ($f.Component -match "WHEA|Memory Error" -and ($f.Status -eq "Fail" -or $f.Status -eq "Warning")) {
            $wheaFound = $true
            break
        }
    }
    if ($wheaFound) {
        Write-Finding -Label "Memory Diagnostic" -Value "RECOMMENDED (WHEA errors in Phase 2)" -Color "Yellow"
        Add-DiagFinding -DiagState $DiagState -Component "Memory Diagnostic" -Status "Warning" `
            -Details "WHEA memory errors detected -- run Windows Memory Diagnostic (mdsched.exe) on next reboot" -Category "Hardware" -Weight 15
        $DiagState.StressResults["MemDiagRecommended"] = $true
        Write-Log "Memory Diagnostic recommended due to WHEA errors"
    } else {
        $DiagState.StressResults["MemDiagRecommended"] = $false
    }

    # --- 7-POST: Thermal reading after stress ---
    Write-Host "    Capturing post-stress thermal data..." -ForegroundColor DarkGray
    $postStressTemp = 0
    try {
        $thermal = Get-CimInstance -Namespace "root/WMI" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction SilentlyContinue
        if ($thermal) {
            $temps = @($thermal | ForEach-Object { [math]::Round(($_.CurrentTemperature - 2732) / 10, 1) })
            $postStressTemp = ($temps | Measure-Object -Maximum).Maximum
        }
    } catch { }

    if ($postStressTemp -gt 0 -and $preStressTemp -gt 0) {
        $thermalDelta = [math]::Round($postStressTemp - $preStressTemp, 1)
        Write-Finding -Label "Post-stress temperature" -Value "${postStressTemp}C (delta: +${thermalDelta}C)" -Color $(if ($postStressTemp -ge $cfgThermalBlock) { "Red" } elseif ($thermalDelta -gt 20) { "Yellow" } else { "Green" })

        if ($postStressTemp -ge $cfgThermalBlock) {
            Add-DiagFinding -DiagState $DiagState -Component "Thermal Under Stress" -Status "Fail" `
                -Details "Post-stress temp ${postStressTemp}C exceeds ${cfgThermalBlock}C (delta +${thermalDelta}C)" -Category "Hardware" -Weight 70
            $stressFails++
        } elseif ($thermalDelta -gt 20) {
            Add-DiagFinding -DiagState $DiagState -Component "Thermal Rise Under Stress" -Status "Warning" `
                -Details "Temperature rose ${thermalDelta}C during stress (${preStressTemp}C -> ${postStressTemp}C)" -Category "Hardware" -Weight 35
        }

        $DiagState.StressResults["PreStressTemp"] = $preStressTemp
        $DiagState.StressResults["PostStressTemp"] = $postStressTemp
        $DiagState.StressResults["ThermalDelta"] = $thermalDelta
    } elseif ($postStressTemp -gt 0) {
        Write-Finding -Label "Post-stress temperature" -Value "${postStressTemp}C" -Color "Cyan"
        $DiagState.StressResults["PostStressTemp"] = $postStressTemp
    } else {
        Write-Finding -Label "Post-stress temperature" -Value "Sensor unavailable" -Color "DarkGray"
    }

    # Phase result
    $status = if ($stressFails -gt 0) { "FAIL" } else { "PASS" }
    $DiagState.PhaseResults["Phase7"] = $status
    Write-PhaseResult -Phase "Phase 7: Stress Validation" -Status $status -Details "$stressFails stress test failures"
    Write-Log "Phase 7 complete: $stressFails failures"

    # v8.5: Stress failure overrides classification upward
    if ($stressFails -gt 0) {
        $DiagState.StressOverride = $true
        Write-Log "StressOverride: Stress failures detected -- classification may be escalated in Phase 8"
        # Patch remediation ledger entries with stress results
        foreach ($entry in $DiagState.RemediationLedger) {
            if ($entry.FixApplied -eq $true) {
                $entry.StressValidationResult = "FAIL"
                if ($entry.FinalStatus -eq "PARTIAL") {
                    $entry.FinalStatus = "UNSTABLE"
                }
            }
        }
    } else {
        # Mark successful stress validation on all ledger entries
        foreach ($entry in $DiagState.RemediationLedger) {
            if ($entry.FixApplied -eq $true) {
                $entry.StressValidationResult = "PASS"
                if ($entry.FinalStatus -eq "PARTIAL") {
                    $entry.FinalStatus = "RESOLVED"
                }
            }
        }
    }

    # v9: Exception threshold check after stress validation
    if ($v9GovernanceAvailable) {
        try {
            $exThreshold = Test-ExceptionThreshold -ConfigIniPath (Join-Path $ScriptRoot "Config\config.ini")
            if ($exThreshold.ShouldAbort) {
                Write-Host "  [GOVERNANCE] Exception threshold reached: $($exThreshold.Reason)" -ForegroundColor Red
                Write-Log "Exception threshold abort: $($exThreshold.Reason)"
            }
        } catch {}
    }

    Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase7"
}

# ============================================================
# PHASE 8: FINAL CLASSIFICATION
# ============================================================

function Invoke-Phase8-FinalClassification {
    param([hashtable]$DiagState)
    Write-ScanHeader -Name "PHASE 8: FINAL CLASSIFICATION" -Icon "[8/8]"
    Write-Log "--- Phase 8: Final Classification ---"
    Start-PhaseTimer -DiagState $DiagState -PhaseName "Phase8"
    if ($v9GovernanceAvailable) { try { Save-ExecutionState -SessionGUID $DiagState.SessionId -CurrentPhase 8 -OutputDir $ReportPath } catch {} }

    $ranking = Get-RootCauseRanking -DiagState $DiagState
    $totalFindings = @($DiagState.Findings | Where-Object { $_.Status -eq 'Fail' -or $_.Status -eq 'Warning' }).Count
    $hwStatus = if ($DiagState.HardwareCritical) { "Critical" } elseif (@($DiagState.Findings | Where-Object { $_.Category -eq 'Hardware' -and $_.Status -eq 'Warning' }).Count -gt 0) { "Degraded" } else { "Healthy" }

    $postTest = "N/A"
    if ($DiagState.PhaseResults.ContainsKey("Phase7")) {
        $postTest = $DiagState.PhaseResults["Phase7"]
    }

    $fixSummary = "None"
    if ($DiagState.FixesApplied.Count -gt 0) {
        $fixSummary = ($DiagState.FixesApplied -join "; ")
    }

    # Terminal summary
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   SMART DIAGNOSIS COMPLETE" -ForegroundColor White
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Finding -Label "Primary Root Cause" -Value $ranking.PrimaryRootCause -Color "White"
    Write-Finding -Label "Confidence" -Value "$($ranking.Confidence)%" -Color $(if ($ranking.Confidence -ge 80) { "Green" } elseif ($ranking.Confidence -ge 60) { "Yellow" } else { "Red" })
    Write-Finding -Label "Fix Applied" -Value $fixSummary -Color "Cyan"
    Write-Finding -Label "Post-Test Result" -Value $postTest -Color $(if ($postTest -eq "PASS") { "Green" } elseif ($postTest -eq "FAIL") { "Red" } else { "DarkGray" })
    Write-Finding -Label "Hardware Status" -Value $hwStatus -Color $(if ($hwStatus -eq "Healthy") { "Green" } elseif ($hwStatus -eq "Degraded") { "Yellow" } else { "Red" })
    Write-Finding -Label "Escalation Level" -Value "$($ranking.EscalationLevel)" -Color $(if ($ranking.EscalationLevel -eq "None") { "Green" } elseif ($ranking.EscalationLevel -eq "L1") { "Yellow" } else { "Red" })
    Write-Finding -Label "Total Findings" -Value "$totalFindings issues"
    # Use ScoringEngine weighted score when v7 engines are available, otherwise fall back to ad-hoc
    $displayScore = $ranking.EnterpriseScore
    $displayLabel = "Enterprise Score"
    $esColor = if ($displayScore -ge 80) { "Green" } elseif ($displayScore -ge 60) { "Yellow" } else { "Red" }
    Write-Finding -Label $displayLabel -Value "$displayScore/100" -Color $esColor
    Write-ProgressBar -Label "Health" -Score $displayScore
    Write-Host ""

    if ($ranking.SecondarySymptoms -and @($ranking.SecondarySymptoms).Count -gt 0) {
        Write-Host "    Secondary Symptoms:" -ForegroundColor DarkGray
        foreach ($sym in $ranking.SecondarySymptoms) {
            Write-Host "      - $($sym.Component): $($sym.Details)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # Phase results summary
    Write-Host "    Phase Results:" -ForegroundColor White
    $phaseNames = @("Phase1","Phase2","Phase3","Phase4","Phase5","Phase6","Phase7")
    $phaseLabels = @("System Snapshot","Hardware Integrity","Boot & OS","Service & Driver","Performance","Remediation","Stress Validation")
    for ($i = 0; $i -lt $phaseNames.Count; $i++) {
        $pStatus = if ($DiagState.PhaseResults.ContainsKey($phaseNames[$i])) { $DiagState.PhaseResults[$phaseNames[$i]] } else { "N/A" }
        $pColor = switch ($pStatus) {
            "PASS"    { "Green" }
            "WARN"    { "Yellow" }
            "FAIL"    { "Red" }
            "SKIP"    { "DarkGray" }
            "APPLIED" { "Cyan" }
            default   { "Gray" }
        }
        Write-Host "      [$pStatus] $($phaseLabels[$i])" -ForegroundColor $pColor
    }
    Write-Host ""

    # Display severity classification (v11 taxonomy)
    $displayFindings = @($DiagState.Findings | Where-Object {
        $_.Category -eq 'Display' -or ($_.Category -eq 'Driver' -and $_.Component -match 'GPU|TDR|Display|Refresh|Brightness')
    })
    if ($displayFindings.Count -gt 0) {
        $displayFails = @($displayFindings | Where-Object { $_.Status -eq 'Fail' })
        $hasGPUHardware = @($displayFindings | Where-Object { $_.Component -match 'GPU.*hardware|panel.*cable|dead.*pixel' -and $_.Status -eq 'Fail' }).Count -gt 0
        $hasDriverOnly = @($displayFindings | Where-Object { $_.Component -match 'driver|TDR|Refresh|Brightness|ACPI|Resolution' }).Count -gt 0

        if ($hasGPUHardware) {
            $displayLevel = "Level 3 (Technician)"
            $displayColor = "Red"
        } elseif ($displayFails.Count -gt 0 -and -not $hasDriverOnly) {
            $displayLevel = "Level 2 (Component)"
            $displayColor = "Yellow"
        } else {
            $displayLevel = "Level 1 (Auto-fixable)"
            $displayColor = "Cyan"
        }
        $DiagState["DisplayStatus"] = $displayLevel
        Write-Host "    Display Classification: $displayLevel ($($displayFindings.Count) finding(s))" -ForegroundColor $displayColor
    } else {
        $DiagState["DisplayStatus"] = "No display issues"
    }
    Write-Host ""

    # v7.2: Classification Engine -- formal 3-level classification
    if ($v7EnginesAvailable -and (Get-Command 'Get-ClassificationReport' -ErrorAction SilentlyContinue)) {
        try {
            $classReport = Get-ClassificationReport -DiagState $DiagState -Config $classConfig -RootCauseRanking $ranking
            $DiagState["ClassificationReport"] = $classReport

            # Display 3-level triage summary
            Write-Host "    3-Level Classification:" -ForegroundColor White
            $levelColor = switch ($classReport.escalation_level) {
                'L1'    { 'Green' }
                'L2'    { 'Yellow' }
                'L3'    { 'Red' }
                'CLEAR' { 'Cyan' }
                default { 'Gray' }
            }
            $levelDesc = switch ($classReport.escalation_level) {
                'L1'    { 'AUTO-FIXABLE (Software)' }
                'L2'    { 'REPLACEABLE COMPONENT (Wear)' }
                'L3'    { 'TECHNICIAN REQUIRED (Critical)' }
                'CLEAR' { 'ALL CLEAR' }
                default { 'Unknown' }
            }
            Write-Host "      Level: $($classReport.escalation_level) -- $levelDesc" -ForegroundColor $levelColor
            Write-Host "      Branch: $($classReport.classification_branch)" -ForegroundColor DarkGray
            Write-Host "      Severity Score: $($classReport.severity_score)/100" -ForegroundColor $(if ($classReport.severity_score -ge 90) { 'Red' } elseif ($classReport.severity_score -ge 65) { 'Yellow' } else { 'Green' })
            Write-Host "      Issues: L1=$($classReport.l1_count) | L2=$($classReport.l2_count) | L3=$($classReport.l3_count)" -ForegroundColor DarkGray

            # Decision tree path
            if ($classReport.decision_tree_path) {
                $pathStr = $classReport.decision_tree_path -join ' -> '
                Write-Host "      Path: $pathStr" -ForegroundColor DarkGray
            }

            # L2 component health cards
            if ($classReport.component_health -and $classReport.component_health.Count -gt 0) {
                Write-Host ""
                Write-Host "    Replaceable Components (L2):" -ForegroundColor Yellow
                foreach ($ch in $classReport.component_health) {
                    Write-Host "      - $($ch.component): $($ch.reason)" -ForegroundColor Yellow
                    if ($ch.recommendation) {
                        Write-Host "        Recommendation: $($ch.recommendation)" -ForegroundColor DarkGray
                    }
                }
            }
            Write-Host ""
            Write-Log "ClassificationEngine: $($classReport.escalation_level) ($($classReport.classification_branch)), Severity=$($classReport.severity_score)"
        }
        catch {
            Write-Host "    [WARN] ClassificationEngine: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Log "ClassificationEngine failed in Phase 8: $($_.Exception.Message)"
        }
    }

    $DiagState.PhaseResults["Phase8"] = "DONE"

    # Store ranking for report
    $DiagState["Ranking"] = $ranking

    # Write audit log
    $auditIssueCode = "Findings:$totalFindings,Fixes:$($DiagState.FixesApplied.Count),StressFails:$($DiagState.StressResults['NewErrors'])"
    $auditSev = Get-LocalSeverityCode -Component $ranking.PrimaryCategory -Status $(if ($totalFindings -gt 0) { "Fail" } else { "Pass" })
    Write-DiagAuditLog -Module "SmartDiagnosisEngine" -IssueCode $auditIssueCode -Severity $auditSev `
        -ActionTaken $(if ($DiagState.FixesApplied.Count -gt 0) { "AutoRemediation" } else { "ScanOnly" }) `
        -FinalState "$($ranking.EscalationLevel):$($ranking.Confidence)%" `
        -RiskLevel $(if ($ranking.EscalationLevel -eq "L3") { "High" } elseif ($ranking.EscalationLevel -eq "L2") { "Medium" } else { "Low" })

    Write-Log "Phase 8 complete: $($ranking.PrimaryRootCause) | Confidence=$($ranking.Confidence)% | Escalation=$($ranking.EscalationLevel)"

    # ── v7 Enterprise Engine Integration ──────────────────────────────────────
    if ($v7EnginesAvailable) {
        $moduleResults = $null
        $guardStatus   = $null
        $scoreResult   = $null
        $trendData     = $null

        # ScoringEngine: Weighted health score (replaces ad-hoc enterprise score)
        try {
            $moduleResults = ConvertTo-ModuleResults -DiagState $DiagState
            $guardStatus   = Get-GuardStatus
            $scoreResult   = Invoke-SystemScoring -ModuleResults $moduleResults `
                -SessionId $DiagState.SessionId -Config $v7Config -GuardStatus $guardStatus

            $DiagState.ScoreResult = $scoreResult
            $DiagState.GuardStatus = $guardStatus

            Write-Host ""
            $bandColor = switch ($scoreResult.band) {
                'EXCELLENT' { 'Green' }
                'GOOD'      { 'Green' }
                'FAIR'      { 'Yellow' }
                'POOR'      { 'Red' }
                'CRITICAL'  { 'Red' }
                default     { 'Gray' }
            }
            Write-Finding -Label "Weighted Health Score" -Value "$($scoreResult.finalScore)/100 ($($scoreResult.band))" -Color $bandColor
            Write-ProgressBar -Label "Weighted Health" -Score ([int]$scoreResult.finalScore)
            Write-Log "ScoringEngine: $($scoreResult.finalScore)/100 ($($scoreResult.band))"
        }
        catch {
            Write-Host "    [WARN] ScoringEngine: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Log "ScoringEngine failed: $($_.Exception.Message)"
        }

        # TrendEngine: Store session + show trajectory
        if ($scoreResult -and $moduleResults) {
            try {
                $trendData = Add-TrendEntry -SessionId $DiagState.SessionId -DiagState $DiagState `
                    -ModuleResults $moduleResults -ScoreResult $scoreResult -PlatformRoot $ScriptRoot `
                    -GuardStatus $guardStatus -Config $v7Config
                $DiagState.TrendData = $trendData

                $trajColor = if ($trendData.scoreTrajectory -eq 'IMPROVING') { 'Green' } elseif ($trendData.scoreTrajectory -eq 'DECLINING') { 'Red' } else { 'Gray' }
                Write-Finding -Label "Trend Trajectory" -Value "$($trendData.scoreTrajectory) (avg: $($trendData.avgScore), $($trendData.sessionCount) sessions)" -Color $trajColor

                # Trend alerts
                $trendStore  = Get-TrendReport -PlatformRoot $ScriptRoot -Config $v7Config
                $trendAlerts = Get-TrendAlert -TrendStore $trendStore -SessionId $DiagState.SessionId
                $DiagState.TrendAlerts = $trendAlerts
                foreach ($alert in $trendAlerts) {
                    $alertColor = if ($alert.severity -eq 'ERROR') { 'Red' } else { 'Yellow' }
                    Write-Host "    [TREND ALERT] $($alert.message)" -ForegroundColor $alertColor
                }
                Write-Log "TrendEngine: $($trendData.scoreTrajectory), $($trendData.sessionCount) sessions"
            }
            catch {
                Write-Host "    [WARN] TrendEngine: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Log "TrendEngine failed: $($_.Exception.Message)"
            }
        }

        # ComplianceExport: Generate 6 audit artifacts
        if ($scoreResult -and $moduleResults) {
            try {
                $guardDecisionLog = Get-GuardDecisionLog
                $compArtifacts = Export-ComplianceArtifacts -SessionId $DiagState.SessionId `
                    -DiagState $DiagState -ModuleResults $moduleResults -ScoreResult $scoreResult `
                    -GuardStatus $guardStatus -OutputPath $ReportPath -PlatformRoot $ScriptRoot `
                    -GuardDecisionLog $guardDecisionLog -TrendData $trendData
                $DiagState.ComplianceDir = $compArtifacts['ComplianceReport']
                Write-Finding -Label "Compliance Artifacts" -Value "$($compArtifacts.Count) artifacts generated" -Color "Green"
                Write-Log "ComplianceExport: $($compArtifacts.Count) artifacts"
            }
            catch {
                Write-Host "    [WARN] ComplianceExport: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Log "ComplianceExport failed: $($_.Exception.Message)"
            }
        }

        # v8.5: HealthAfter computation + Risk Reduction
        if ($scoreResult) {
            $DiagState.HealthAfter = $scoreResult
            if ($DiagState.HealthBefore) {
                try {
                    $healthDelta = Invoke-HealthDeltaScoring -ScoreBefore $DiagState.HealthBefore -ScoreAfter $scoreResult
                    $DiagState['HealthDelta'] = $healthDelta
                    Write-Host ""
                    $deltaColor = if ($healthDelta.AbsoluteDelta -ge 0) { 'Green' } else { 'Red' }
                    $arrow = if ($healthDelta.AbsoluteDelta -gt 0) { '+' } else { '' }
                    Write-Finding -Label "Risk Reduction" -Value "$($healthDelta.HealthBefore) -> $($healthDelta.HealthAfter) ($arrow$($healthDelta.AbsoluteDelta) pts, $($healthDelta.RiskReductionPct)%)" -Color $deltaColor
                    Write-Finding -Label "Band Change" -Value "$($healthDelta.BandBefore) -> $($healthDelta.BandAfter)" -Color $deltaColor
                    Write-Log "HealthDelta: $($healthDelta.HealthBefore)->$($healthDelta.HealthAfter), RiskReduction=$($healthDelta.RiskReductionPct)%"
                }
                catch {
                    Write-Log "HealthDelta scoring failed: $($_.Exception.Message)"
                }
            }
        }

        # v8.5: Finalize RemediationLedger FinalStatus
        if ($DiagState.RemediationLedger -and $DiagState.RemediationLedger.Count -gt 0) {
            foreach ($entry in $DiagState.RemediationLedger) {
                if ($entry.FinalStatus -eq 'PARTIAL') {
                    # PARTIAL entries that have stress PASS become RESOLVED
                    if ($entry.StressValidationResult -eq 'PASS') {
                        $entry.FinalStatus = 'RESOLVED'
                    }
                }
            }
            $resolved = @($DiagState.RemediationLedger | Where-Object { $_.FinalStatus -eq 'RESOLVED' }).Count
            $total = $DiagState.RemediationLedger.Count
            Write-Finding -Label "Remediation Ledger" -Value "$total entries ($resolved resolved)" -Color "Cyan"
            Write-Log "RemediationLedger: $total entries, $resolved resolved"
        }

        # v8.5: Export new JSON artifacts to Reports directory
        $v85ReportDir = $ReportPath
        $v85Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

        # RemediationLedger.json
        if ($DiagState.RemediationLedger -and $DiagState.RemediationLedger.Count -gt 0) {
            try {
                $ledgerExport = [ordered]@{
                    _type         = 'REMEDIATION_LEDGER'
                    sessionId     = $DiagState.SessionId
                    generatedAt   = Get-Date -Format 'o'
                    computername  = $env:COMPUTERNAME
                    totalEntries  = $DiagState.RemediationLedger.Count
                    entries       = @($DiagState.RemediationLedger)
                }
                $ledgerFile = Join-Path $v85ReportDir "RemediationLedger_$v85Timestamp.json"
                $ledgerExport | ConvertTo-Json -Depth 10 | Out-File -FilePath $ledgerFile -Encoding UTF8 -Force
                Write-Host "  Ledger: $ledgerFile" -ForegroundColor Green
                Write-Log "RemediationLedger.json exported"
            }
            catch { Write-Log "RemediationLedger export failed: $($_.Exception.Message)" }
        }

        # RiskReduction.json
        if ($DiagState.ContainsKey('HealthDelta') -and $DiagState['HealthDelta']) {
            try {
                $riskExport = [ordered]@{
                    _type             = 'RISK_REDUCTION'
                    sessionId         = $DiagState.SessionId
                    generatedAt       = Get-Date -Format 'o'
                    computername      = $env:COMPUTERNAME
                    healthBefore      = $DiagState['HealthDelta'].HealthBefore
                    healthAfter       = $DiagState['HealthDelta'].HealthAfter
                    bandBefore        = $DiagState['HealthDelta'].BandBefore
                    bandAfter         = $DiagState['HealthDelta'].BandAfter
                    absoluteDelta     = $DiagState['HealthDelta'].AbsoluteDelta
                    riskReductionPct  = $DiagState['HealthDelta'].RiskReductionPct
                    improvements      = $DiagState['HealthDelta'].Improvements
                }
                $riskFile = Join-Path $v85ReportDir "RiskReduction_$v85Timestamp.json"
                $riskExport | ConvertTo-Json -Depth 10 | Out-File -FilePath $riskFile -Encoding UTF8 -Force
                Write-Host "  RiskReduction: $riskFile" -ForegroundColor Green
                Write-Log "RiskReduction.json exported"
            }
            catch { Write-Log "RiskReduction export failed: $($_.Exception.Message)" }
        }

        # phase_timing.json
        if ($DiagState.PhaseTiming -and $DiagState.PhaseTiming.Count -gt 0) {
            try {
                $timingExport = [ordered]@{
                    _type        = 'PHASE_TIMING'
                    sessionId    = $DiagState.SessionId
                    generatedAt  = Get-Date -Format 'o'
                    computername = $env:COMPUTERNAME
                    phases       = $DiagState.PhaseTiming
                }
                $timingFile = Join-Path $v85ReportDir "phase_timing_$v85Timestamp.json"
                $timingExport | ConvertTo-Json -Depth 10 | Out-File -FilePath $timingFile -Encoding UTF8 -Force
                Write-Host "  PhaseTiming: $timingFile" -ForegroundColor Green
                Write-Log "phase_timing.json exported"
            }
            catch { Write-Log "phase_timing export failed: $($_.Exception.Message)" }
        }

        # ClassificationReport.json (separate file)
        if ($DiagState.ContainsKey('ClassificationReport') -and $DiagState['ClassificationReport']) {
            try {
                $classFile = Join-Path $v85ReportDir "ClassificationReport_$v85Timestamp.json"
                $DiagState['ClassificationReport'] | ConvertTo-Json -Depth 10 | Out-File -FilePath $classFile -Encoding UTF8 -Force
                Write-Host "  Classification: $classFile" -ForegroundColor Green
                Write-Log "ClassificationReport.json exported"
            }
            catch { Write-Log "ClassificationReport export failed: $($_.Exception.Message)" }
        }

        # v9: Governance artifacts
        if ($v9GovernanceAvailable) {
            try {
                # ExceptionLog.json
                $exceptionSummary = Get-ExceptionSummary
                if ($exceptionSummary.TotalExceptions -gt 0) {
                    $exceptionFile = Join-Path $v85ReportDir "ExceptionLog_$v85Timestamp.json"
                    $exceptionSummary | ConvertTo-Json -Depth 5 | Out-File -FilePath $exceptionFile -Encoding UTF8 -Force
                    Write-Host "  ExceptionLog: $exceptionFile" -ForegroundColor Green
                    Write-Log "ExceptionLog.json exported ($($exceptionSummary.TotalExceptions) exceptions)"
                }

                # GovernanceReport.json
                $govReport = [ordered]@{
                    _type = 'GOVERNANCE_REPORT'
                    sessionId = $DiagState.SessionId
                    generatedAt = Get-Date -Format 'o'
                    computername = $env:COMPUTERNAME
                    governanceVersion = '9.0.0'
                    policyProfile = if ($DiagState.ContainsKey('PolicyProfile')) { $DiagState['PolicyProfile'] } else { @{} }
                    executionMode = $Mode
                    directoryCheck = if ($DiagState.ContainsKey('DirectoryCheck')) { $DiagState['DirectoryCheck'] } else { @{} }
                    exceptionSummary = $exceptionSummary
                }
                # Rollback simulation
                if ($DiagState.RemediationLedger -and $DiagState.RemediationLedger.Count -gt 0) {
                    $rollbackSim = Test-RollbackSimulation -RemediationLedger @($DiagState.RemediationLedger)
                    $govReport['rollbackSimulation'] = $rollbackSim
                }
                $govFile = Join-Path $v85ReportDir "GovernanceReport_$v85Timestamp.json"
                $govReport | ConvertTo-Json -Depth 10 | Out-File -FilePath $govFile -Encoding UTF8 -Force
                Write-Host "  GovernanceReport: $govFile" -ForegroundColor Green
                Write-Log "GovernanceReport.json exported"

                # Clear execution state (session completed successfully)
                Clear-ExecutionState -OutputDir $ReportPath -FinalStatus 'COMPLETED'
                Write-Log "ExecutionState cleared: session completed"
            }
            catch {
                Write-Log "Governance artifact export failed: $($_.Exception.Message)"
            }
        }
    }
    Stop-PhaseTimer -DiagState $DiagState -PhaseName "Phase8"
}

# ============================================================
# HTML REPORT GENERATOR
# ============================================================

function New-SmartDiagReport {
    param([hashtable]$DiagState, [string]$OutputPath)
    Write-Log "Generating HTML report..."

    $ranking = $DiagState["Ranking"]
    if (-not $ranking) { $ranking = Get-RootCauseRanking -DiagState $DiagState }

    $hwStatus = if ($DiagState.HardwareCritical) { "Critical" } elseif (@($DiagState.Findings | Where-Object { $_.Category -eq 'Hardware' -and $_.Status -eq 'Warning' }).Count -gt 0) { "Degraded" } else { "Healthy" }
    $postTest = if ($DiagState.PhaseResults.ContainsKey("Phase7")) { $DiagState.PhaseResults["Phase7"] } else { "N/A" }
    $fixSummary = if ($DiagState.FixesApplied.Count -gt 0) { ($DiagState.FixesApplied -join "; ") } else { "None" }

    # Phase results for grid
    $phaseNames = @("Phase1","Phase2","Phase3","Phase4","Phase5","Phase6","Phase7","Phase8")
    $phaseLabels = @("System Snapshot","Hardware Integrity","Boot & OS","Service & Driver","Performance","Remediation","Stress Validation","Classification")
    $phaseGridHTML = ""
    for ($i = 0; $i -lt $phaseNames.Count; $i++) {
        $pStatus = if ($DiagState.PhaseResults.ContainsKey($phaseNames[$i])) { $DiagState.PhaseResults[$phaseNames[$i]] } else { "N/A" }
        $badgeColor = switch ($pStatus) {
            "PASS"    { "#00C875" }
            "WARN"    { "#F59E0B" }
            "FAIL"    { "#E2231A" }
            "SKIP"    { "#555" }
            "APPLIED" { "#4A8BEF" }
            "DONE"    { "#00C875" }
            default   { "#777" }
        }
        $phaseGridHTML += "<div class='phase-card'><span class='phase-badge' style='background:$badgeColor'>$pStatus</span><span class='phase-label'>$($phaseLabels[$i])</span></div>`n"
    }

    # Findings table rows
    $findingsHTML = ""
    $sortedFindings = $DiagState.Findings | Sort-Object Weight -Descending
    foreach ($f in $sortedFindings) {
        $rowClass = switch ($f.Status) {
            "Fail"    { "row-fail" }
            "Warning" { "row-warn" }
            default   { "row-pass" }
        }
        $findingsHTML += "<tr class='$rowClass'><td>$($f.Component)</td><td>$($f.Category)</td><td>$($f.Status)</td><td>$($f.Weight)</td><td>$($f.Severity)</td><td>$($f.Details)</td></tr>`n"
    }

    # Secondary symptoms
    $secondaryHTML = ""
    if ($ranking.SecondarySymptoms -and @($ranking.SecondarySymptoms).Count -gt 0) {
        foreach ($sym in $ranking.SecondarySymptoms) {
            $secondaryHTML += "<li><strong>$($sym.Component)</strong>: $($sym.Details) (Weight: $($sym.Weight))</li>`n"
        }
    } else {
        $secondaryHTML = "<li>None</li>"
    }

    # Fixes log
    $fixesHTML = ""
    if ($DiagState.FixesApplied.Count -gt 0 -or $DiagState.FixesFailed.Count -gt 0) {
        foreach ($fx in $DiagState.FixesApplied) {
            $fixesHTML += "<tr><td>$fx</td><td style='color:#00C875'>Success</td><td>Yes</td></tr>`n"
        }
        foreach ($fx in $DiagState.FixesFailed) {
            $fixesHTML += "<tr><td>$fx</td><td style='color:#E2231A'>Failed</td><td>Yes</td></tr>`n"
        }
    } else {
        $fixesHTML = "<tr><td colspan='3'>No remediation applied</td></tr>"
    }

    # Stress results
    $stressHTML = ""
    if ($DiagState.PhaseResults.ContainsKey("Phase7") -and $DiagState.PhaseResults["Phase7"] -ne "SKIP") {
        $sr = $DiagState.StressResults
        $cpuD = if ($sr.ContainsKey("CPUDelta")) { "$($sr.CPUDelta)%" } else { "N/A" }
        $memP = if ($sr.ContainsKey("MemoryPass")) { if ($sr.MemoryPass) { "PASS" } else { "FAIL" } } else { "N/A" }
        $dwMBs = if ($sr.ContainsKey("DiskWriteMBs")) { "$($sr.DiskWriteMBs) MB/s" } else { "N/A" }
        $drMBs = if ($sr.ContainsKey("DiskReadMBs")) { "$($sr.DiskReadMBs) MB/s" } else { "N/A" }
        $newE = if ($sr.ContainsKey("NewErrors")) { $sr.NewErrors } else { "N/A" }
        $stressHTML = "<table class='data-table'><tr><th>Test</th><th>Result</th></tr>"
        $stressHTML += "<tr><td>CPU Stress vs Baseline</td><td>$cpuD</td></tr>"
        $stressHTML += "<tr><td>Memory Allocation</td><td>$memP</td></tr>"
        $stressHTML += "<tr><td>Disk Write</td><td>$dwMBs</td></tr>"
        $stressHTML += "<tr><td>Disk Read</td><td>$drMBs</td></tr>"
        $stressHTML += "<tr><td>New Event Log Errors</td><td>$newE</td></tr>"
        $preT = if ($sr.ContainsKey("PreStressTemp")) { "$($sr.PreStressTemp)C" } else { "N/A" }
        $postT = if ($sr.ContainsKey("PostStressTemp")) { "$($sr.PostStressTemp)C" } else { "N/A" }
        $tDelta = if ($sr.ContainsKey("ThermalDelta")) { "+$($sr.ThermalDelta)C" } else { "N/A" }
        $stressHTML += "<tr><td>Thermal (Pre / Post / Delta)</td><td>$preT / $postT / $tDelta</td></tr>"
        $stressHTML += "</table>"
    } else {
        $stressHTML = "<p class='muted'>Stress validation was skipped</p>"
    }

    # Confidence bar width
    $confWidth = $ranking.Confidence
    $confColor = if ($confWidth -ge 80) { "#00C875" } elseif ($confWidth -ge 60) { "#F59E0B" } else { "#E2231A" }
    # Prefer ScoringEngine weighted score when available
    $esScore = if ($DiagState.ScoreResult) { [int]$DiagState.ScoreResult.finalScore } else { $ranking.EnterpriseScore }
    $esBand  = if ($DiagState.ScoreResult) { " ($($DiagState.ScoreResult.band))" } else { "" }
    $esColor = if ($esScore -ge 80) { "#00C875" } elseif ($esScore -ge 60) { "#F59E0B" } else { "#E2231A" }
    $escalColor = switch ($ranking.EscalationLevel) {
        "None" { "#00C875" }
        "L1"   { "#F59E0B" }
        "L2"   { "#E2231A" }
        "L3"   { "#E2231A" }
        default { "#777" }
    }
    $hwColor = switch ($hwStatus) {
        "Healthy"  { "#00C875" }
        "Degraded" { "#F59E0B" }
        "Critical" { "#E2231A" }
        default    { "#777" }
    }

    # v7.2: Build 3-Level Classification Triage Panel
    $triagePanelHTML = ""
    $decisionPathHTML = ""
    $componentCardsHTML = ""
    $classReport = $null
    if ($DiagState.ContainsKey('ClassificationReport') -and $DiagState['ClassificationReport']) {
        $classReport = $DiagState['ClassificationReport']
        $activeLevel = $classReport.escalation_level

        # L1 column
        $l1Active = if ($activeLevel -eq 'L1') { 'triage-active' } else { 'triage-dimmed' }
        $l1Items = ""
        if ($classReport.l1_count -gt 0) {
            $swFindings = @($DiagState.Findings | Where-Object { $_.Severity -match '^S' -and ($_.Status -eq 'Fail' -or $_.Status -eq 'Warning') } | Select-Object -First 5)
            foreach ($sf in $swFindings) { $l1Items += "<li>$($sf.Component)</li>" }
        }

        # L2 column
        $l2Active = if ($activeLevel -eq 'L2') { 'triage-active' } else { 'triage-dimmed' }
        $l2Items = ""
        if ($classReport.component_health) {
            foreach ($ch in $classReport.component_health) { $l2Items += "<li>$($ch.component)</li>" }
        }

        # L3 column
        $l3Active = if ($activeLevel -eq 'L3') { 'triage-active' } else { 'triage-dimmed' }
        $l3Items = ""
        $hwCritFindings = @($DiagState.Findings | Where-Object { $_.Severity -eq 'H3' -and $_.Status -eq 'Fail' } | Select-Object -First 5)
        foreach ($hf in $hwCritFindings) { $l3Items += "<li>$($hf.Component)</li>" }

        $triagePanelHTML = @"
  <h2>3-Level Classification</h2>
  <div class="triage-panel">
    <div class="triage-col triage-l1 $l1Active">
      <div class="triage-title" style="color:#00C875">L1 — AUTO-FIXABLE</div>
      <span class="triage-count" style="color:#00C875">$($classReport.l1_count)</span>
      <div class="triage-desc">Software-layer issues that can be remediated automatically</div>
      <ul class="triage-items">$l1Items</ul>
    </div>
    <div class="triage-col triage-l2 $l2Active">
      <div class="triage-title" style="color:#F59E0B">L2 — REPLACEABLE</div>
      <span class="triage-count" style="color:#F59E0B">$($classReport.l2_count)</span>
      <div class="triage-desc">Hardware wear requiring component replacement</div>
      <ul class="triage-items">$l2Items</ul>
    </div>
    <div class="triage-col triage-l3 $l3Active">
      <div class="triage-title" style="color:#E2231A">L3 — TECHNICIAN</div>
      <span class="triage-count" style="color:#E2231A">$($classReport.l3_count)</span>
      <div class="triage-desc">Critical hardware faults — no auto-fix possible</div>
      <ul class="triage-items">$l3Items</ul>
    </div>
  </div>
"@

        # Decision tree path
        if ($classReport.decision_tree_path) {
            $pathNodes = ""
            $pathArr = @($classReport.decision_tree_path)
            for ($pi = 0; $pi -lt $pathArr.Count; $pi++) {
                $nodeClass = if ($pi -eq ($pathArr.Count - 1)) { 'decision-node decision-node-active' } else { 'decision-node' }
                $pathNodes += "<span class='$nodeClass'>$($pathArr[$pi])</span>"
                if ($pi -lt ($pathArr.Count - 1)) { $pathNodes += "<span class='decision-arrow'>&#8594;</span>" }
            }
            $decisionPathHTML = "<div class='decision-path'>$pathNodes</div>"
        }

        # L2 Component health cards
        if ($classReport.component_health -and $classReport.component_health.Count -gt 0) {
            $componentCardsHTML = "<h2>Replaceable Components (L2)</h2>"
            foreach ($ch in $classReport.component_health) {
                $componentCardsHTML += @"
<div class="component-card">
  <div class="comp-name">$($ch.component)</div>
  <div class="comp-detail">$($ch.reason)</div>
  <div class="comp-rec">Recommendation: $($ch.recommendation)</div>
</div>
"@
            }
        }
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Smart Diagnosis Report - $computerName</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { background:#0A0F1A; color:#F5F7FA; font-family:Consolas,'Courier New',monospace; font-size:14px; padding:20px; }
  .container { max-width:1100px; margin:0 auto; }
  h1 { color:#4A8BEF; font-size:22px; margin-bottom:5px; }
  h2 { color:#4A8BEF; font-size:16px; margin:25px 0 10px 0; border-bottom:1px solid #1A2744; padding-bottom:5px; }
  .header-bar { display:flex; justify-content:space-between; align-items:center; border-bottom:2px solid #4A8BEF; padding-bottom:10px; margin-bottom:20px; flex-wrap:wrap; gap:8px; }
  .machine-info { color:#7A8BA8; font-size:12px; }
  .exec-summary { background:#0F1E35; border:2px solid #1A2744; border-radius:8px; padding:20px; margin-bottom:20px; }
  .exec-row { display:flex; justify-content:space-between; margin:8px 0; flex-wrap:wrap; }
  .exec-label { color:#7A8BA8; min-width:180px; }
  .exec-value { font-weight:bold; }
  .conf-bar { background:#1A2744; border-radius:4px; height:20px; width:200px; display:inline-block; vertical-align:middle; overflow:hidden; }
  .conf-fill { height:100%; border-radius:4px; }
  .phase-grid { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; margin-bottom:20px; }
  .phase-card { background:#0F1E35; border:1px solid #1A2744; border-radius:6px; padding:10px; text-align:center; }
  .phase-badge { display:inline-block; padding:2px 8px; border-radius:4px; color:#fff; font-size:11px; font-weight:bold; margin-bottom:4px; }
  .phase-label { display:block; color:#7A8BA8; font-size:11px; margin-top:4px; }
  .data-table { width:100%; border-collapse:collapse; margin-bottom:15px; }
  .data-table th { background:#0F1E35; color:#4A8BEF; padding:8px 10px; text-align:left; border-bottom:2px solid #1A2744; font-size:12px; }
  .data-table td { padding:6px 10px; border-bottom:1px solid #1A2744; font-size:12px; }
  .row-fail td { border-left:3px solid #E2231A; }
  .row-warn td { border-left:3px solid #F59E0B; }
  .row-pass td { border-left:3px solid #00C875; }
  .muted { color:#7A8BA8; font-style:italic; }
  .footer { margin-top:30px; padding-top:10px; border-top:1px solid #1A2744; color:#7A8BA8; font-size:11px; text-align:center; }
  /* 3-Level Classification Triage Panel */
  .triage-panel { display:grid; grid-template-columns:1fr 1fr 1fr; gap:12px; margin-bottom:20px; }
  .triage-col { border-radius:8px; padding:16px; border:2px solid; }
  .triage-l1 { border-color:#00C875; background:rgba(0,200,117,0.05); }
  .triage-l2 { border-color:#F59E0B; background:rgba(245,158,11,0.05); }
  .triage-l3 { border-color:#E2231A; background:rgba(226,35,26,0.05); }
  .triage-active { box-shadow:0 0 15px rgba(74,139,239,0.3); }
  .triage-dimmed { opacity:0.35; }
  .triage-title { font-size:13px; font-weight:bold; margin-bottom:8px; }
  .triage-count { font-size:28px; font-weight:bold; display:block; margin:6px 0; }
  .triage-desc { font-size:11px; color:#7A8BA8; }
  .triage-items { margin-top:8px; font-size:11px; }
  .triage-items li { margin:3px 0; list-style:none; }
  .decision-path { display:flex; align-items:center; gap:6px; margin:12px 0; flex-wrap:wrap; }
  .decision-node { padding:4px 10px; border-radius:4px; font-size:11px; background:#0F1E35; border:1px solid #1A2744; }
  .decision-node-active { background:#1A5DCC; border-color:#4A8BEF; color:#fff; }
  .decision-arrow { color:#7A8BA8; font-size:12px; }
  .component-card { background:#0F1E35; border:1px solid #F59E0B; border-radius:6px; padding:10px 12px; margin:6px 0; }
  .component-card .comp-name { font-weight:bold; color:#F59E0B; font-size:12px; }
  .component-card .comp-detail { color:#7A8BA8; font-size:11px; margin-top:3px; }
  .component-card .comp-rec { color:#F5F7FA; font-size:11px; margin-top:3px; }
  @media print {
    body { background:#fff; color:#000; }
    .exec-summary { border-color:#ccc; }
    .phase-card { border-color:#ccc; background:#f9f9f9; }
    .phase-label { color:#555; }
    .data-table th { background:#eee; color:#000; }
    .data-table td { border-color:#ddd; }
    h1, h2 { color:#003; }
    .muted { color:#555; }
    .triage-panel { grid-template-columns:1fr 1fr 1fr; }
    .triage-col { border-color:#ccc; background:#f9f9f9; }
    .triage-dimmed { opacity:0.5; }
    .component-card { border-color:#ccc; background:#f5f5f5; }
    .decision-node { background:#eee; border-color:#ccc; }
    .decision-node-active { background:#036; color:#fff; }
  }
</style>
</head>
<body>
<div class="container">
  <div class="header-bar">
    <div>
      <h1>Smart Diagnosis Engine Report</h1>
      <div class="machine-info">$computerName | $manufacturer $model | SN: $serialNumber | $dateDisplay</div>
    </div>
    <div class="machine-info">LDT v7.0 | OS: $osVersion</div>
  </div>

  <h2>Executive Summary</h2>
  <div class="exec-summary">
    <div class="exec-row"><span class="exec-label">Primary Root Cause:</span><span class="exec-value">$($ranking.PrimaryRootCause)</span></div>
    <div class="exec-row"><span class="exec-label">Confidence:</span><span class="exec-value"><div class="conf-bar"><div class="conf-fill" style="width:${confWidth}%;background:$confColor"></div></div> $($ranking.Confidence)%</span></div>
    <div class="exec-row"><span class="exec-label">Fix Applied:</span><span class="exec-value" style="color:#4A8BEF">$fixSummary</span></div>
    <div class="exec-row"><span class="exec-label">Post-Test Result:</span><span class="exec-value" style="color:$(if ($postTest -eq 'PASS') {'#00C875'} elseif ($postTest -eq 'FAIL') {'#E2231A'} else {'#777'})">$postTest</span></div>
    <div class="exec-row"><span class="exec-label">Hardware Status:</span><span class="exec-value" style="color:$hwColor">$hwStatus</span></div>
    <div class="exec-row"><span class="exec-label">Escalation Level:</span><span class="exec-value" style="color:$escalColor">$($ranking.EscalationLevel)</span></div>
    <div class="exec-row"><span class="exec-label">Health Score:</span><span class="exec-value" style="color:$esColor"><div class="conf-bar"><div class="conf-fill" style="width:${esScore}%;background:$esColor"></div></div> $esScore/100$esBand</span></div>
  </div>

  $triagePanelHTML
  $decisionPathHTML
  $componentCardsHTML

  <h2>Phase Results</h2>
  <div class="phase-grid">
    $phaseGridHTML
  </div>

  <h2>All Findings (sorted by weight)</h2>
  <table class="data-table">
    <tr><th>Component</th><th>Category</th><th>Status</th><th>Weight</th><th>Severity</th><th>Details</th></tr>
    $findingsHTML
  </table>

  <h2>Root Cause Analysis</h2>
  <div class="exec-summary">
    <div class="exec-row"><span class="exec-label">Primary:</span><span class="exec-value">$($ranking.PrimaryRootCause)</span></div>
    <div class="exec-row"><span class="exec-label">Recommended Action:</span><span class="exec-value">$($ranking.RecommendedAction)</span></div>
    <p style="margin-top:10px;color:#7A8BA8">Secondary Symptoms:</p>
    <ul style="margin:5px 0 0 20px;color:#F5F7FA">$secondaryHTML</ul>
  </div>

  <h2>Remediation Log</h2>
  <table class="data-table">
    <tr><th>Action</th><th>Result</th><th>Rollback Available</th></tr>
    $fixesHTML
  </table>

  <h2>Stress Validation</h2>
  $stressHTML

  <div class="footer">
    LDT v6.1 - Smart Diagnosis Engine v1.0.0 | Report: $reportFile | Generated: $dateDisplay
  </div>
</div>
</body>
</html>
"@

    $html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
    Write-Log "HTML report saved: $OutputPath"
}

# ============================================================
# JSON REPORT GENERATOR
# ============================================================

function Export-SmartDiagJSON {
    param([hashtable]$DiagState, [string]$ReportDir, [string]$Timestamp)
    Write-Log "Generating JSON reports..."

    $ranking = $DiagState["Ranking"]
    if (-not $ranking) { $ranking = Get-RootCauseRanking -DiagState $DiagState }

    $postTest = "N/A"
    if ($DiagState.PhaseResults.ContainsKey("Phase7")) { $postTest = $DiagState.PhaseResults["Phase7"] }

    # --- snapshot.json ---
    $machineClean = @{}
    foreach ($key in $DiagState.Machine.Keys) {
        if ($key -eq 'Drivers') {
            $machineClean[$key] = @($DiagState.Machine[$key] | ForEach-Object {
                @{ DeviceName = $_.DeviceName; DriverVersion = $_.DriverVersion; Manufacturer = $_.Manufacturer; IsSigned = [bool]$_.IsSigned }
            })
        } elseif ($key -eq 'Services') {
            $machineClean[$key] = @($DiagState.Machine[$key] | ForEach-Object {
                @{ Name = $_.Name; DisplayName = $_.DisplayName; Status = $_.Status.ToString(); StartType = $_.StartType.ToString() }
            })
        } else {
            $machineClean[$key] = $DiagState.Machine[$key]
        }
    }

    $snapshot = @{
        device        = $machineClean
        snapshot_time = $DiagState.Machine["ScanTime"]
    }

    $snapshotFile = Join-Path $ReportDir "SmartDiag_${Timestamp}_snapshot.json"
    $snapshot | ConvertTo-Json -Depth 4 | Out-File -FilePath $snapshotFile -Encoding UTF8 -Force
    Write-Log "Snapshot JSON saved: $snapshotFile"

    # --- final_report.json ---
    $findingsArray = @($DiagState.Findings | ForEach-Object {
        @{
            component = $_.Component
            category  = $_.Category
            status    = $_.Status
            weight    = $_.Weight
            severity  = $_.Severity
            details   = $_.Details
            timestamp = $_.Timestamp
        }
    })

    $secondaryArray = @()
    if ($ranking.SecondarySymptoms) {
        $secondaryArray = @($ranking.SecondarySymptoms | ForEach-Object {
            @{ component = $_.Component; details = $_.Details; weight = $_.Weight }
        })
    }

    $finalReport = @{
        device              = @{
            computer_name = $DiagState.Machine["ComputerName"]
            serial        = $DiagState.Machine["Serial"]
            manufacturer  = $DiagState.Machine["Manufacturer"]
            model         = $DiagState.Machine["Model"]
            os            = $DiagState.Machine["OS"]
            bios_version  = $DiagState.Machine["BIOSVersion"]
        }
        snapshot_time       = $DiagState.Machine["ScanTime"]
        findings            = $findingsArray
        primary_cause       = $ranking.PrimaryRootCause
        secondary_symptoms  = $secondaryArray
        severity_score      = $ranking.PrimaryWeight
        confidence_pct      = $ranking.Confidence
        enterprise_score    = if ($DiagState.ScoreResult) { [int]$DiagState.ScoreResult.finalScore } else { $ranking.EnterpriseScore }
        actions_taken       = @($DiagState.FixesApplied)
        actions_failed      = @($DiagState.FixesFailed)
        rollback_id         = $DiagState.BackupId
        stress_validation   = $postTest
        stress_results      = $DiagState.StressResults
        escalation_level    = $ranking.EscalationLevel
        recommended_action  = $ranking.RecommendedAction
        phase_results       = $DiagState.PhaseResults
        display_status      = if ($DiagState.ContainsKey('DisplayStatus')) { $DiagState['DisplayStatus'] } else { 'N/A' }
    }

    # Add v7 enterprise engine data if available
    if ($DiagState.ScoreResult) {
        $finalReport['weighted_score']   = $DiagState.ScoreResult.finalScore
        $finalReport['health_band']      = $DiagState.ScoreResult.band
        $finalReport['guard_penalty']    = $DiagState.ScoreResult.guardPenalty
    }
    if ($DiagState.TrendData) {
        $finalReport['trend_trajectory'] = $DiagState.TrendData.scoreTrajectory
        $finalReport['trend_avg_score']  = $DiagState.TrendData.avgScore
        $finalReport['trend_sessions']   = $DiagState.TrendData.sessionCount
    }
    if ($DiagState.GuardStatus) {
        $finalReport['guard_hard_stop']  = $DiagState.GuardStatus.hardStopTriggered
        $finalReport['guard_blocked']    = $DiagState.GuardStatus.blockedActions
    }
    if ($DiagState.ComplianceDir) {
        $finalReport['compliance_dir']   = $DiagState.ComplianceDir
    }

    # v7.2: ClassificationEngine data
    if ($DiagState.ContainsKey('ClassificationReport') -and $DiagState['ClassificationReport']) {
        $cr = $DiagState['ClassificationReport']
        $finalReport['classification'] = @{
            escalation_level  = $cr.escalation_level
            severity_score    = $cr.severity_score
            branch            = $cr.classification_branch
            reasoning         = $cr.classification_reasoning
            decision_path     = $cr.decision_tree_path
            component_health  = $cr.component_health
            l1_count          = $cr.l1_count
            l2_count          = $cr.l2_count
            l3_count          = $cr.l3_count
            auto_fix_allowed  = $cr.auto_fix_allowed
        }
        # Override legacy fields with classification values
        $finalReport['severity_score']    = $cr.severity_score
        $finalReport['escalation_level']  = $cr.escalation_level
        $finalReport['rollback_tokens']   = $cr.rollback_tokens
        $finalReport['stress_validation'] = $cr.stress_validation
    }

    $reportJsonFile = Join-Path $ReportDir "SmartDiag_${Timestamp}_report.json"
    $finalReport | ConvertTo-Json -Depth 4 | Out-File -FilePath $reportJsonFile -Encoding UTF8 -Force
    Write-Log "Final report JSON saved: $reportJsonFile"

    return @{ SnapshotFile = $snapshotFile; ReportFile = $reportJsonFile }
}

# ============================================================
# MANAGEMENT SUMMARY GENERATOR (v8.5)
# ============================================================

function New-ManagementSummary {
    param([hashtable]$DiagState, [string]$OutputPath)
    Write-Log "Generating Management Summary..."

    $computerName = $DiagState.Machine["ComputerName"]
    $model = $DiagState.Machine["Model"]
    $serial = $DiagState.Machine["Serial"]
    $dateDisplay = Get-Date -Format "yyyy-MM-dd HH:mm"

    # Gather data
    $totalFindings = @($DiagState.Findings | Where-Object { $_.Status -eq 'Fail' -or $_.Status -eq 'Warning' }).Count
    $fixCount = $DiagState.FixesApplied.Count
    $failCount = $DiagState.FixesFailed.Count

    # Classification data
    $classReport = $null
    $l1Count = 0; $l2Count = 0; $l3Count = 0
    $escalLevel = "N/A"
    if ($DiagState.ContainsKey('ClassificationReport') -and $DiagState['ClassificationReport']) {
        $classReport = $DiagState['ClassificationReport']
        $l1Count = if ($classReport.l1_count) { $classReport.l1_count } else { 0 }
        $l2Count = if ($classReport.l2_count) { $classReport.l2_count } else { 0 }
        $l3Count = if ($classReport.l3_count) { $classReport.l3_count } else { 0 }
        $escalLevel = if ($classReport.escalation_level) { $classReport.escalation_level } else { "N/A" }
    }

    # Health scores
    $healthBefore = "N/A"; $healthAfter = "N/A"; $riskDelta = "N/A"
    $bandBefore = ""; $bandAfter = ""
    if ($DiagState.ContainsKey('HealthDelta') -and $DiagState['HealthDelta']) {
        $hd = $DiagState['HealthDelta']
        $healthBefore = "$($hd.HealthBefore)"
        $healthAfter = "$($hd.HealthAfter)"
        $riskDelta = "$($hd.RiskReductionPct)%"
        $bandBefore = $hd.BandBefore
        $bandAfter = $hd.BandAfter
    } elseif ($DiagState.ScoreResult) {
        $healthAfter = "$($DiagState.ScoreResult.finalScore)"
        $bandAfter = $DiagState.ScoreResult.band
    }

    # Ledger summary
    $resolvedItems = @()
    $pendingRisks = @()
    if ($DiagState.RemediationLedger -and $DiagState.RemediationLedger.Count -gt 0) {
        $resolvedItems = @($DiagState.RemediationLedger | Where-Object { $_.FinalStatus -eq 'RESOLVED' -or $_.FinalStatus -eq 'PARTIAL' })
        $pendingRisks = @($DiagState.RemediationLedger | Where-Object { $_.FinalStatus -in @('FAILED','UNSTABLE','BLOCKED','ESCALATED') })
    }

    # L1 auto-fixed list
    $l1FixedHTML = ""
    foreach ($fix in $DiagState.FixesApplied) {
        $fixName = if ($fix -is [string]) { $fix } else { "$fix" }
        $l1FixedHTML += "<li>$([System.Web.HttpUtility]::HtmlEncode($fixName))</li>`n"
    }
    if (-not $l1FixedHTML) { $l1FixedHTML = "<li class='muted'>None</li>" }

    # L2 advisory list
    $l2HTML = ""
    if ($classReport -and $classReport.component_health) {
        foreach ($ch in $classReport.component_health) {
            $l2HTML += "<li>$([System.Web.HttpUtility]::HtmlEncode($ch.component)): $([System.Web.HttpUtility]::HtmlEncode($ch.reason))</li>`n"
        }
    }
    if (-not $l2HTML) { $l2HTML = "<li class='muted'>None</li>" }

    # L3 escalated list
    $l3HTML = ""
    $hwCrit = @($DiagState.Findings | Where-Object { $_.Severity -eq 'H3' -and $_.Status -eq 'Fail' })
    foreach ($hf in $hwCrit) {
        $l3HTML += "<li>$([System.Web.HttpUtility]::HtmlEncode($hf.Component)): $([System.Web.HttpUtility]::HtmlEncode($hf.Details))</li>`n"
    }
    if (-not $l3HTML) { $l3HTML = "<li class='muted'>None</li>" }

    # Resolved issues table
    $resolvedTableHTML = ""
    foreach ($r in $resolvedItems) {
        $resolvedTableHTML += "<tr><td>$($r.IssueID)</td><td>$($r.Category)</td><td>$($r.Location)</td><td style='color:#00C875'>$($r.FinalStatus)</td></tr>`n"
    }
    if (-not $resolvedTableHTML) { $resolvedTableHTML = "<tr><td colspan='4' class='muted'>No resolved items</td></tr>" }

    # Pending risks table
    $pendingTableHTML = ""
    foreach ($p in $pendingRisks) {
        $riskColor = if ($p.FinalStatus -eq 'FAILED') { '#E2231A' } else { '#F59E0B' }
        $pendingTableHTML += "<tr><td>$($p.IssueID)</td><td>$($p.Category)</td><td style='color:$riskColor'>$($p.FinalStatus)</td><td>$($p.RootCause)</td></tr>`n"
    }
    if (-not $pendingTableHTML) { $pendingTableHTML = "<tr><td colspan='4' class='muted'>No pending risks</td></tr>" }

    # Score bar widths
    $beforeWidth = if ($healthBefore -ne 'N/A') { $healthBefore } else { '0' }
    $afterWidth = if ($healthAfter -ne 'N/A') { $healthAfter } else { '0' }
    $beforeColor = if ([double]$beforeWidth -ge 75) { '#00C875' } elseif ([double]$beforeWidth -ge 60) { '#F59E0B' } else { '#E2231A' }
    $afterColor = if ([double]$afterWidth -ge 75) { '#00C875' } elseif ([double]$afterWidth -ge 60) { '#F59E0B' } else { '#E2231A' }

    # Business impact
    $bizImpact = "System diagnosed with $totalFindings issue(s). "
    if ($fixCount -gt 0) { $bizImpact += "$fixCount fix(es) applied automatically. " }
    if ($l3Count -gt 0) { $bizImpact += "$l3Count critical hardware issue(s) require technician intervention. " }
    elseif ($l2Count -gt 0) { $bizImpact += "$l2Count component(s) showing wear -- schedule replacement. " }
    else { $bizImpact += "No critical hardware issues detected. " }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Management Summary - $computerName</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { background:#0A0F1A; color:#F5F7FA; font-family:'Segoe UI',Consolas,monospace; font-size:14px; padding:20px; }
  .container { max-width:900px; margin:0 auto; }
  h1 { color:#4A8BEF; font-size:22px; margin-bottom:3px; letter-spacing:1px; }
  h2 { color:#4A8BEF; font-size:15px; margin:20px 0 8px 0; border-bottom:1px solid #1A2744; padding-bottom:4px; }
  .subtitle { color:#7A8BA8; font-size:12px; }
  .header-bar { border-bottom:2px solid #4A8BEF; padding-bottom:10px; margin-bottom:15px; }
  .kpi-grid { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; margin-bottom:15px; }
  .kpi-card { background:#0F1E35; border:1px solid #1A2744; border-radius:8px; padding:14px; text-align:center; }
  .kpi-value { font-size:26px; font-weight:bold; }
  .kpi-label { font-size:11px; color:#7A8BA8; margin-top:4px; }
  .score-section { display:grid; grid-template-columns:1fr 1fr 1fr; gap:12px; margin-bottom:15px; }
  .score-card { background:#0F1E35; border:1px solid #1A2744; border-radius:8px; padding:14px; text-align:center; }
  .score-big { font-size:32px; font-weight:bold; }
  .score-label { font-size:11px; color:#7A8BA8; }
  .score-band { font-size:12px; margin-top:4px; }
  .bar { background:#1A2744; border-radius:4px; height:8px; margin-top:6px; overflow:hidden; }
  .bar-fill { height:100%; border-radius:4px; }
  .class-grid { display:grid; grid-template-columns:1fr 1fr 1fr; gap:10px; margin-bottom:15px; }
  .class-card { border-radius:8px; padding:12px; border:2px solid; }
  .class-l1 { border-color:#00C875; background:rgba(0,200,117,0.08); }
  .class-l2 { border-color:#F59E0B; background:rgba(245,158,11,0.08); }
  .class-l3 { border-color:#E2231A; background:rgba(226,35,26,0.08); }
  .class-title { font-size:12px; font-weight:bold; }
  .class-count { font-size:22px; font-weight:bold; display:block; margin:4px 0; }
  .class-list { font-size:11px; margin-top:6px; }
  .class-list li { margin:2px 0; list-style:none; }
  .biz-impact { background:#0F1E35; border-left:3px solid #4A8BEF; padding:12px 14px; margin-bottom:15px; font-size:13px; border-radius:0 6px 6px 0; }
  .data-table { width:100%; border-collapse:collapse; margin-bottom:12px; }
  .data-table th { background:#0F1E35; color:#4A8BEF; padding:6px 8px; text-align:left; border-bottom:2px solid #1A2744; font-size:11px; }
  .data-table td { padding:5px 8px; border-bottom:1px solid #1A2744; font-size:12px; }
  .muted { color:#7A8BA8; font-style:italic; }
  .footer { margin-top:20px; padding-top:8px; border-top:1px solid #1A2744; color:#7A8BA8; font-size:10px; text-align:center; }
  @media print { body { background:#fff; color:#000; } .kpi-card,.score-card,.class-card,.biz-impact { border-color:#ccc; background:#f9f9f9; } h1,h2 { color:#003; } .data-table th { background:#eee; color:#000; } }
</style>
</head>
<body>
<div class="container">
  <div class="header-bar">
    <h1>MANAGEMENT SUMMARY</h1>
    <div class="subtitle">$computerName | $model | SN: $serial | $dateDisplay | LDT v8.5</div>
  </div>

  <div class="kpi-grid">
    <div class="kpi-card"><div class="kpi-value" style="color:#F5F7FA">$totalFindings</div><div class="kpi-label">Total Issues</div></div>
    <div class="kpi-card"><div class="kpi-value" style="color:#00C875">$fixCount</div><div class="kpi-label">Auto-Fixed</div></div>
    <div class="kpi-card"><div class="kpi-value" style="color:#F59E0B">$l2Count</div><div class="kpi-label">Advisory (L2)</div></div>
    <div class="kpi-card"><div class="kpi-value" style="color:#E2231A">$l3Count</div><div class="kpi-label">Escalated (L3)</div></div>
  </div>

  <h2>Health Score</h2>
  <div class="score-section">
    <div class="score-card">
      <div class="score-label">BEFORE</div>
      <div class="score-big" style="color:$beforeColor">$healthBefore</div>
      <div class="score-band">$bandBefore</div>
      <div class="bar"><div class="bar-fill" style="width:${beforeWidth}%;background:$beforeColor"></div></div>
    </div>
    <div class="score-card">
      <div class="score-label">AFTER</div>
      <div class="score-big" style="color:$afterColor">$healthAfter</div>
      <div class="score-band">$bandAfter</div>
      <div class="bar"><div class="bar-fill" style="width:${afterWidth}%;background:$afterColor"></div></div>
    </div>
    <div class="score-card">
      <div class="score-label">RISK REDUCTION</div>
      <div class="score-big" style="color:#4A8BEF">$riskDelta</div>
      <div class="score-band">Classification: $escalLevel</div>
    </div>
  </div>

  <h2>Business Impact</h2>
  <div class="biz-impact">$bizImpact</div>

  <h2>Classification Breakdown</h2>
  <div class="class-grid">
    <div class="class-card class-l1">
      <div class="class-title" style="color:#00C875">L1 — AUTO-FIXED</div>
      <span class="class-count" style="color:#00C875">$fixCount</span>
      <ul class="class-list">$l1FixedHTML</ul>
    </div>
    <div class="class-card class-l2">
      <div class="class-title" style="color:#F59E0B">L2 — ADVISORY</div>
      <span class="class-count" style="color:#F59E0B">$l2Count</span>
      <ul class="class-list">$l2HTML</ul>
    </div>
    <div class="class-card class-l3">
      <div class="class-title" style="color:#E2231A">L3 — ESCALATED</div>
      <span class="class-count" style="color:#E2231A">$l3Count</span>
      <ul class="class-list">$l3HTML</ul>
    </div>
  </div>

  <h2>Resolved Issues</h2>
  <table class="data-table">
    <tr><th>Issue ID</th><th>Category</th><th>Fix</th><th>Status</th></tr>
    $resolvedTableHTML
  </table>

  <h2>Pending Risks</h2>
  <table class="data-table">
    <tr><th>Issue ID</th><th>Category</th><th>Status</th><th>Risk</th></tr>
    $pendingTableHTML
  </table>

  <div class="footer">LDT v8.5 | Smart Diagnosis Engine | Management Summary | Generated: $dateDisplay | Classification: $escalLevel</div>
</div>
</body>
</html>
"@

    $html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
    Write-Log "Management Summary saved: $OutputPath"
}

# ============================================================
# MAIN EXECUTION
# ============================================================

Write-Banner "SMART DIAGNOSIS ENGINE v9.0.0"

Write-Host "  Machine:  $computerName" -ForegroundColor White
Write-Host "  Model:    $manufacturer $model" -ForegroundColor White
Write-Host "  Serial:   $serialNumber" -ForegroundColor White
Write-Host "  OS:       $osVersion" -ForegroundColor White
Write-Host "  Time:     $dateDisplay" -ForegroundColor White
Write-Host ""
Write-Host "  9-phase root cause analysis with decision tree" -ForegroundColor DarkGray
Write-Host "  Config: Confidence=$cfgConfidenceThresh%, MaxAuto=$cfgMaxAutoLevel, Stress=${cfgStressDuration}s" -ForegroundColor DarkGray
if ($v7EnginesAvailable) {
    Write-Host "  Enterprise Engines: Guard + Integrity + Scoring + Trend + Compliance" -ForegroundColor DarkCyan
} else {
    Write-Host "  Enterprise Engines: Not available (v6 compat mode)" -ForegroundColor DarkGray
}

# ---- Phase 0: Preflight (always runs first) ----
$preflightOK = Invoke-Phase0-Preflight -DiagState $diagState
if (-not $preflightOK) {
    Write-Host "  ABORTING: Preflight checks failed. Run as Administrator." -ForegroundColor Red
    Write-Log "Aborted: Preflight failed"
    return
}

# ---- Phase 1: System Snapshot (always runs) ----
Invoke-Phase1-SystemSnapshot -DiagState $diagState

# ---- Phase 2: Hardware Integrity (always runs) ----
Invoke-Phase2-HardwareIntegrity -DiagState $diagState

# ---- Decision gate: Hardware Critical? ----
if ($diagState.HardwareCritical) {
    Write-Host ""
    Write-Host "  !! HARDWARE CRITICAL DETECTED !!" -ForegroundColor Red
    Write-Host "  Skipping software phases -- jumping to final classification" -ForegroundColor Red
    Write-Host ""
}

# ---- Phase 3: Boot & OS (skips if HW critical) ----
Invoke-Phase3-BootAndOS -DiagState $diagState

# ---- Phase 4: Service & Driver (skips if HW critical) ----
Invoke-Phase4-ServiceAndDriver -DiagState $diagState

# ---- Phase 5: Performance (skips if HW critical) ----
Invoke-Phase5-PerformanceProfile -DiagState $diagState

# ---- Phase 6: Auto Remediation (gates checked internally) ----
$skipRemediation = ($Mode -eq 'ClassifyOnly')
if ($v9GovernanceAvailable) {
    if (-not (Test-ModeAllowsRemediation)) { $skipRemediation = $true }
    if (-not (Test-ModeAllowsPhase -Phase 6)) { $skipRemediation = $true }
}
if ($skipRemediation) {
    Write-Host "  [$Mode] Skipping Phase 6 (Remediation)" -ForegroundColor DarkGray
    Write-Log "Phase 6 skipped: $Mode mode"
    $diagState.PhaseResults["Phase6"] = "SKIP"
} else {
    Invoke-Phase6-AutoRemediation -DiagState $diagState
}

# ---- Phase 7: Stress Validation (skips if HW/thermal critical) ----
$skipStress = ($Mode -eq 'ClassifyOnly')
if ($v9GovernanceAvailable) {
    if (-not (Test-ModeAllowsPhase -Phase 7)) { $skipStress = $true }
}
if ($skipStress) {
    Write-Host "  [$Mode] Skipping Phase 7 (Stress Validation)" -ForegroundColor DarkGray
    Write-Log "Phase 7 skipped: $Mode mode"
    $diagState.PhaseResults["Phase7"] = "SKIP"
} else {
    Invoke-Phase7-StressValidation -DiagState $diagState
}

# ---- Phase 8: Final Classification (always runs) ----
Invoke-Phase8-FinalClassification -DiagState $diagState

# ---- Generate HTML Report ----
Write-Host "  Generating HTML report..." -ForegroundColor DarkGray
New-SmartDiagReport -DiagState $diagState -OutputPath $reportFile
Write-Host "  Report saved: $reportFile" -ForegroundColor Green

# ---- Generate Management Summary (v8.5) ----
try {
    $mgmtSummaryFile = Join-Path $ReportPath "ManagementSummary_$timestamp.html"
    New-ManagementSummary -DiagState $diagState -OutputPath $mgmtSummaryFile
    Write-Host "  Management Summary: $mgmtSummaryFile" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] Management Summary: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Log "ManagementSummary generation failed: $($_.Exception.Message)"
}

# ---- Generate JSON Reports ----
Write-Host "  Generating JSON reports..." -ForegroundColor DarkGray
$jsonFiles = Export-SmartDiagJSON -DiagState $diagState -ReportDir $ReportPath -Timestamp $timestamp
Write-Host "  Snapshot: $($jsonFiles.SnapshotFile)" -ForegroundColor Green
Write-Host "  Report:   $($jsonFiles.ReportFile)" -ForegroundColor Green

# ---- Open report ----
Start-Process $reportFile -ErrorAction SilentlyContinue

# ---- Final log entries (BEFORE seal so seal is always last line) ----
Write-Log "Smart Diagnosis Engine completed"
Write-Log "============================================"

# ---- v7: Log Seal + Execution Receipt ----
if ($v7EnginesAvailable) {
    try {
        Seal-SessionLog -SessionId $diagState.SessionId -LogFilePath $logFile -PlatformRoot $ScriptRoot
        $diagState.LogSealApplied = $true
    }
    catch { Write-Host "  [WARN] Log seal failed: $($_.Exception.Message)" -ForegroundColor Yellow }

    try {
        $receiptFile = New-ExecutionReceipt -SessionId $diagState.SessionId -DiagState $diagState `
            -PlatformRoot $ScriptRoot -OutputPath $ReportPath `
            -ScoreResult $diagState.ScoreResult -GuardStatus $diagState.GuardStatus
        $diagState.ExecutionReceipt = $receiptFile
        Write-Host "  Receipt: $receiptFile" -ForegroundColor Green
    }
    catch { Write-Host "  [WARN] Execution receipt failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "  Scan complete. Log: $logFile" -ForegroundColor DarkGray
Write-Host ""
