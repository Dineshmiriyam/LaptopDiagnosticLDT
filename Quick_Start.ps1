<#
.SYNOPSIS
    Quick Start - LDT v6.1 Options 51-53
    Three guided workflows for any team member:
      Mode A: Auto-Discover  - Scan machine, show what's wrong
      Mode B: SymptomFix     - Pick a symptom, run targeted fixes
      Mode C: ScoreMachine   - Health score 0-100 with letter grade

.VERSION
    1.0.0

.NOTES
    Architecture: Standalone PS1 (called by Laptop_Master_Diagnostic.bat)
    Dependencies: None - vanilla PowerShell 5.1
    Config: Reads thresholds from Config\config.ini
    Output: Terminal + HTML report + CSV (ScoreMachine) + baseline JSON
#>

param(
    [ValidateSet('AutoDiscover', 'SymptomFix', 'ScoreMachine')]
    [string]$Mode = '',
    [string]$LogPath     = ".\Logs",
    [string]$ReportPath  = ".\Reports",
    [string]$ConfigPath  = ".\Config",
    [string]$BackupPath  = ".\Backups",
    [string]$TempPath    = ".\Temp",
    [string]$DataPath    = ".\Data",
    [string]$ResultsPath = ".\Results",
    [string]$ScriptRoot  = ""
)

# ============================================================
# SETUP
# ============================================================

$ErrorActionPreference = "SilentlyContinue"
$timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$dateDisplay = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$logFile     = Join-Path $LogPath    "QuickStart_$timestamp.log"
$reportFile  = Join-Path $ReportPath "QuickStart_$timestamp.html"

# Determine script root for calling main PS1
if (-not $ScriptRoot) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$mainPS1 = Join-Path $ScriptRoot "Laptop_Diagnostic_Suite.ps1"

# Machine info
$computerName = $env:COMPUTERNAME
$serialNumber = "Unknown"
$model        = "Unknown"
$manufacturer = "Unknown"
try {
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
    $serialNumber = $bios.SerialNumber
} catch { }
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $model = $cs.Model
    $manufacturer = $cs.Manufacturer
} catch { }

# Ensure output directories exist
foreach ($dir in @($LogPath, $ReportPath, $ResultsPath)) {
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
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
Write-Log "Quick Start v1.0.0 started - Mode: $Mode"
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

# Score weights from config (with PS 5.1-safe defaults)
$weightHardware    = if ($config["QuickStart.WeightHardware"])    { [int]$config["QuickStart.WeightHardware"] }    else { 30 }
$weightSecurity    = if ($config["QuickStart.WeightSecurity"])    { [int]$config["QuickStart.WeightSecurity"] }    else { 25 }
$weightStability   = if ($config["QuickStart.WeightStability"])   { [int]$config["QuickStart.WeightStability"] }   else { 25 }
$weightPerformance = if ($config["QuickStart.WeightPerformance"]) { [int]$config["QuickStart.WeightPerformance"] } else { 20 }
$gradeA = if ($config["QuickStart.GradeA"]) { [int]$config["QuickStart.GradeA"] } else { 90 }
$gradeB = if ($config["QuickStart.GradeB"]) { [int]$config["QuickStart.GradeB"] } else { 80 }
$gradeC = if ($config["QuickStart.GradeC"]) { [int]$config["QuickStart.GradeC"] } else { 70 }
$gradeD = if ($config["QuickStart.GradeD"]) { [int]$config["QuickStart.GradeD"] } else { 60 }

Write-Log "Config loaded: Weights H=$weightHardware S=$weightSecurity St=$weightStability P=$weightPerformance"

# ============================================================
# DISPLAY HELPERS
# ============================================================

function Write-Banner {
    param([string]$Title)
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   $Title" -ForegroundColor White
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Finding {
    param(
        [string]$Label,
        [string]$Value,
        [string]$Color = "White"
    )
    $padded = $Label.PadRight(28)
    Write-Host "    $padded " -NoNewline -ForegroundColor Gray
    Write-Host "$Value" -ForegroundColor $Color
}

function Write-ProgressBar {
    param(
        [string]$Label,
        [int]$Score,
        [int]$MaxWidth = 30
    )
    $filled = [math]::Round($Score / 100 * $MaxWidth)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $MaxWidth) { $filled = $MaxWidth }
    $empty = $MaxWidth - $filled

    $barColor = if ($Score -ge 80) { "Green" }
                elseif ($Score -ge 60) { "Yellow" }
                else { "Red" }

    $padded = $Label.PadRight(16)
    $bar = ("[" + ("=" * $filled) + (" " * $empty) + "]")
    Write-Host "    $padded $bar  $Score/100" -ForegroundColor $barColor
}

function Get-LetterGrade {
    param([int]$Score)
    if ($Score -ge $gradeA) { return "A" }
    if ($Score -ge $gradeB) { return "B" }
    if ($Score -ge $gradeC) { return "C" }
    if ($Score -ge $gradeD) { return "D" }
    return "F"
}

function Get-GradeLabel {
    param([string]$Grade)
    switch ($Grade) {
        "A" { return "Excellent" }
        "B" { return "Good" }
        "C" { return "Acceptable" }
        "D" { return "Needs Attention" }
        "F" { return "Critical" }
        default { return "Unknown" }
    }
}

# ============================================================
# MODE A: AUTO-DISCOVER
# ============================================================

function Start-AutoDiscover {
    Write-Banner "AUTO-DISCOVER - What's Wrong?"

    Write-Host "  Machine:  $computerName" -ForegroundColor White
    Write-Host "  Model:    $model" -ForegroundColor White
    Write-Host "  Serial:   $serialNumber" -ForegroundColor White
    Write-Host ""
    Write-Host "  Scanning 6 areas..." -ForegroundColor DarkGray
    Write-Host ""

    $areas = @()

    # -- 1. HARDWARE --
    Write-Host "  [1/6] Hardware..." -ForegroundColor DarkGray -NoNewline
    $hwScore = 100
    $hwDetails = @()
    try {
        # RAM check
        $totalRAM = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 1)
        if ($totalRAM -lt 4) { $hwScore -= 30; $hwDetails += "Low RAM: ${totalRAM}GB" }
        elseif ($totalRAM -lt 8) { $hwScore -= 10; $hwDetails += "RAM: ${totalRAM}GB (consider upgrade)" }

        # Disk health
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
        foreach ($disk in $disks) {
            if ($disk.HealthStatus -ne "Healthy") {
                $hwScore -= 40
                $hwDetails += "Disk '$($disk.FriendlyName)' health: $($disk.HealthStatus)"
            }
        }

        # PnP device errors
        $problemDevices = @(Get-PnpDevice -ErrorAction Stop | Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'Degraded' })
        if ($problemDevices.Count -gt 0) {
            $hwScore -= ($problemDevices.Count * 10)
            $hwDetails += "$($problemDevices.Count) device(s) with errors"
        }

        # TPM check
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            if (-not $tpm.TpmPresent) { $hwScore -= 5; $hwDetails += "TPM not present" }
            elseif (-not $tpm.TpmReady) { $hwScore -= 5; $hwDetails += "TPM not ready" }
        } catch { $hwScore -= 5; $hwDetails += "TPM check unavailable" }

    } catch {
        $hwScore -= 20
        $hwDetails += "Hardware scan error"
    }
    if ($hwScore -lt 0) { $hwScore = 0 }
    $hwStatus = if ($hwScore -ge 80) { "Good" } elseif ($hwScore -ge 50) { "Warning" } else { "Critical" }
    if ($hwDetails.Count -eq 0) { $hwDetails += "All hardware healthy, ${totalRAM}GB RAM" }
    $areas += @{ Area = "Hardware"; Status = $hwStatus; Score = $hwScore; Details = ($hwDetails -join "; ") }
    Write-Host " done" -ForegroundColor Green

    # -- 2. BATTERY --
    Write-Host "  [2/6] Battery..." -ForegroundColor DarkGray -NoNewline
    $batScore = 100
    $batDetails = @()
    try {
        $battery = Get-CimInstance Win32_Battery -ErrorAction Stop
        if ($battery) {
            $batStatus = $battery.Status
            $estCharge = $battery.EstimatedChargeRemaining
            if ($batStatus -ne "OK") { $batScore -= 30; $batDetails += "Battery status: $batStatus" }

            # Try to get wear level via WMI
            try {
                $fullCharge = (Get-CimInstance -Namespace 'root\WMI' -ClassName 'BatteryFullChargedCapacity' -ErrorAction Stop).FullChargedCapacity
                $designCap  = (Get-CimInstance -Namespace 'root\WMI' -ClassName 'BatteryStaticData' -ErrorAction Stop).DesignedCapacity
                if ($designCap -gt 0 -and $fullCharge -gt 0) {
                    $healthPct = [math]::Round(($fullCharge / $designCap) * 100, 1)
                    if ($healthPct -lt 40) { $batScore -= 40; $batDetails += "Battery health: ${healthPct}% (replace)" }
                    elseif ($healthPct -lt 60) { $batScore -= 25; $batDetails += "Battery health: ${healthPct}% (worn)" }
                    elseif ($healthPct -lt 80) { $batScore -= 10; $batDetails += "Battery health: ${healthPct}%" }
                    else { $batDetails += "Battery health: ${healthPct}%" }
                }
            } catch {
                $batDetails += "Charge: ${estCharge}% (wear data unavailable)"
            }

            # Cycle count from WMI
            try {
                $cycleCount = (Get-CimInstance -Namespace 'root\WMI' -ClassName 'BatteryCycleCount' -ErrorAction Stop).CycleCount
                if ($cycleCount -gt 500) { $batScore -= 15; $batDetails += "High cycle count: $cycleCount" }
                elseif ($cycleCount -gt 300) { $batScore -= 5; $batDetails += "Cycles: $cycleCount" }
                else { $batDetails += "Cycles: $cycleCount" }
            } catch { }
        } else {
            $batScore = 100
            $batDetails += "No battery (desktop or removed)"
        }
    } catch {
        $batScore = 100
        $batDetails += "No battery detected"
    }
    if ($batScore -lt 0) { $batScore = 0 }
    $batStatusLabel = if ($batScore -ge 80) { "Good" } elseif ($batScore -ge 50) { "Warning" } else { "Critical" }
    $areas += @{ Area = "Battery"; Status = $batStatusLabel; Score = $batScore; Details = ($batDetails -join "; ") }
    Write-Host " done" -ForegroundColor Green

    # -- 3. NETWORK --
    Write-Host "  [3/6] Network..." -ForegroundColor DarkGray -NoNewline
    $netScore = 100
    $netDetails = @()
    try {
        # Wi-Fi adapter
        $wifi = Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.InterfaceDescription -match 'Wi-Fi|WiFi|Wireless|Intel.*AX|Intel.*AC|802\.11'
        } | Select-Object -First 1
        if ($wifi) {
            if ($wifi.Status -ne "Up") {
                $netScore -= 30
                $netDetails += "Wi-Fi adapter: $($wifi.Status)"
            } else {
                $netDetails += "Wi-Fi: Connected"
            }
        } else {
            $netDetails += "No Wi-Fi adapter found"
        }

        # DNS
        try {
            $null = Resolve-DnsName -Name "www.google.com" -Type A -DnsOnly -ErrorAction Stop
            $netDetails += "DNS: Working"
        } catch {
            $netScore -= 30
            $netDetails += "DNS resolution: FAILED"
        }

        # Internet
        $netOk = Test-NetConnection -ComputerName "8.8.8.8" -Port 53 -WarningAction SilentlyContinue -InformationLevel Quiet
        if (-not $netOk) {
            $netScore -= 30
            $netDetails += "Internet: UNREACHABLE"
        } else {
            $netDetails += "Internet: Reachable"
        }
    } catch {
        $netScore -= 20
        $netDetails += "Network scan error"
    }
    if ($netScore -lt 0) { $netScore = 0 }
    $netStatus = if ($netScore -ge 80) { "Good" } elseif ($netScore -ge 50) { "Warning" } else { "Critical" }
    $areas += @{ Area = "Network"; Status = $netStatus; Score = $netScore; Details = ($netDetails -join "; ") }
    Write-Host " done" -ForegroundColor Green

    # -- 4. SECURITY --
    Write-Host "  [4/6] Security..." -ForegroundColor DarkGray -NoNewline
    $secScore = 100
    $secDetails = @()
    try {
        # Defender
        try {
            $defender = Get-MpComputerStatus -ErrorAction Stop
            if (-not $defender.RealTimeProtectionEnabled) {
                $secScore -= 30
                $secDetails += "Defender real-time: DISABLED"
            } else {
                $secDetails += "Defender: Active"
            }
            if (-not $defender.AntivirusEnabled) {
                $secScore -= 20
                $secDetails += "Antivirus: DISABLED"
            }
        } catch {
            $secScore -= 15
            $secDetails += "Defender: Unavailable"
        }

        # Firewall
        try {
            $fwProfiles = Get-NetFirewallProfile -ErrorAction Stop
            $fwOff = @($fwProfiles | Where-Object { -not $_.Enabled }).Count
            if ($fwOff -gt 0) {
                $secScore -= ($fwOff * 10)
                $secDetails += "Firewall: $fwOff of 3 profiles disabled"
            } else {
                $secDetails += "Firewall: All profiles enabled"
            }
        } catch { }

        # SecureBoot
        try {
            $sb = Confirm-SecureBootUEFI -ErrorAction Stop
            if (-not $sb) { $secScore -= 10; $secDetails += "SecureBoot: DISABLED" }
        } catch {
            $secDetails += "SecureBoot: N/A"
        }

        # UAC
        try {
            $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction Stop).EnableLUA
            if ($uac -ne 1) { $secScore -= 15; $secDetails += "UAC: DISABLED" }
        } catch { }

        # BitLocker
        try {
            $blVol = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$($env:SystemDrive)'" -ErrorAction Stop
            if ($blVol.ProtectionStatus -ne 1) { $secScore -= 10; $secDetails += "BitLocker: Not active" }
            else { $secDetails += "BitLocker: Active" }
        } catch {
            $secDetails += "BitLocker: N/A"
        }
    } catch {
        $secScore -= 20
        $secDetails += "Security scan error"
    }
    if ($secScore -lt 0) { $secScore = 0 }
    $secStatus = if ($secScore -ge 80) { "Good" } elseif ($secScore -ge 50) { "Warning" } else { "Critical" }
    $areas += @{ Area = "Security"; Status = $secStatus; Score = $secScore; Details = ($secDetails -join "; ") }
    Write-Host " done" -ForegroundColor Green

    # -- 5. STABILITY --
    Write-Host "  [5/6] Stability..." -ForegroundColor DarkGray -NoNewline
    $stabScore = 100
    $stabDetails = @()
    try {
        $days30ago = (Get-Date).AddDays(-30)

        # BSOD events (BugCheck 1001)
        $bsodCount = 0
        try {
            $bsodEvents = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=$days30ago} -ErrorAction Stop)
            $bsodCount = $bsodEvents.Count
        } catch { }
        if ($bsodCount -gt 5) { $stabScore -= 40; $stabDetails += "BSODs (30d): $bsodCount (frequent!)" }
        elseif ($bsodCount -gt 2) { $stabScore -= 25; $stabDetails += "BSODs (30d): $bsodCount" }
        elseif ($bsodCount -gt 0) { $stabScore -= 10; $stabDetails += "BSODs (30d): $bsodCount" }
        else { $stabDetails += "BSODs (30d): 0" }

        # Kernel-Power 41 (unexpected shutdowns)
        $kpCount = 0
        try {
            $kpEvents = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=41; ProviderName='Microsoft-Windows-Kernel-Power'; StartTime=$days30ago} -ErrorAction Stop)
            $kpCount = $kpEvents.Count
        } catch { }
        if ($kpCount -gt 5) { $stabScore -= 25; $stabDetails += "Unexpected shutdowns (30d): $kpCount" }
        elseif ($kpCount -gt 0) { $stabScore -= 10; $stabDetails += "Unexpected shutdowns (30d): $kpCount" }

        # System uptime
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $uptime = (Get-Date) - $os.LastBootUpTime
            $uptimeDays = [math]::Round($uptime.TotalDays, 1)
            if ($uptimeDays -gt 30) { $stabScore -= 10; $stabDetails += "Uptime: ${uptimeDays} days (reboot recommended)" }
            else { $stabDetails += "Uptime: ${uptimeDays} days" }
        } catch { }

    } catch {
        $stabScore -= 15
        $stabDetails += "Stability scan error"
    }
    if ($stabScore -lt 0) { $stabScore = 0 }
    $stabStatus = if ($stabScore -ge 80) { "Good" } elseif ($stabScore -ge 50) { "Warning" } else { "Critical" }
    $areas += @{ Area = "Stability"; Status = $stabStatus; Score = $stabScore; Details = ($stabDetails -join "; ") }
    Write-Host " done" -ForegroundColor Green

    # -- 6. THERMAL --
    Write-Host "  [6/6] Thermal..." -ForegroundColor DarkGray -NoNewline
    $thermScore = 100
    $thermDetails = @()
    try {
        $thermalZones = @(Get-CimInstance -Namespace 'root\WMI' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop)
        if ($thermalZones.Count -gt 0) {
            $maxTemp = 0
            foreach ($zone in $thermalZones) {
                $tempC = [math]::Round(($zone.CurrentTemperature - 2732) / 10, 1)
                if ($tempC -gt $maxTemp) { $maxTemp = $tempC }
            }
            if ($maxTemp -gt 90) { $thermScore -= 40; $thermDetails += "CPU temp: ${maxTemp}C (CRITICAL)" }
            elseif ($maxTemp -gt 80) { $thermScore -= 20; $thermDetails += "CPU temp: ${maxTemp}C (high)" }
            elseif ($maxTemp -gt 70) { $thermScore -= 5; $thermDetails += "CPU temp: ${maxTemp}C (warm)" }
            else { $thermDetails += "CPU temp: ${maxTemp}C" }
        } else {
            $thermDetails += "Thermal sensors: not accessible"
        }
    } catch {
        $thermDetails += "Thermal monitoring unavailable (requires admin)"
        $thermScore = 100
    }
    if ($thermScore -lt 0) { $thermScore = 0 }
    $thermStatus = if ($thermScore -ge 80) { "Good" } elseif ($thermScore -ge 50) { "Warning" } else { "Critical" }
    $areas += @{ Area = "Thermal"; Status = $thermStatus; Score = $thermScore; Details = ($thermDetails -join "; ") }
    Write-Host " done" -ForegroundColor Green

    # -- DASHBOARD --
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   SCAN RESULTS" -ForegroundColor White
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    AREA                         STATUS      DETAILS" -ForegroundColor DarkGray
    Write-Host "    ----------------------------  ----------  ----------------------" -ForegroundColor DarkGray

    $criticalCount = 0
    $warningCount = 0
    foreach ($area in $areas) {
        $areaName = $area.Area.PadRight(30)
        $statusPad = $area.Status.PadRight(12)
        $statusColor = if ($area.Status -eq "Good") { "Green" } elseif ($area.Status -eq "Warning") { "Yellow" } else { "Red" }
        Write-Host "    $areaName" -NoNewline -ForegroundColor White
        Write-Host "$statusPad" -NoNewline -ForegroundColor $statusColor
        Write-Host "$($area.Details)" -ForegroundColor Gray

        if ($area.Status -eq "Critical") { $criticalCount++ }
        if ($area.Status -eq "Warning") { $warningCount++ }
    }

    Write-Host ""
    if ($criticalCount -gt 0) {
        Write-Host "  VERDICT: $criticalCount CRITICAL issue(s) found - action needed" -ForegroundColor Red
    } elseif ($warningCount -gt 0) {
        Write-Host "  VERDICT: $warningCount area(s) need attention" -ForegroundColor Yellow
    } else {
        Write-Host "  VERDICT: All systems healthy" -ForegroundColor Green
    }

    # -- Suggest actions --
    $suggestions = @()
    foreach ($area in $areas) {
        if ($area.Status -eq "Critical" -or $area.Status -eq "Warning") {
            switch ($area.Area) {
                "Hardware"  { $suggestions += @{ Option = "3";  Name = "Enhanced Hardware Test" } }
                "Battery"   { $suggestions += @{ Option = "14"; Name = "Battery Health" } }
                "Network"   { $suggestions += @{ Option = "32"; Name = "Network Troubleshooter" } }
                "Security"  { $suggestions += @{ Option = "31"; Name = "Security Hardening" } }
                "Stability" { $suggestions += @{ Option = "33"; Name = "BSOD Troubleshooter" } }
                "Thermal"   { $suggestions += @{ Option = "17"; Name = "Thermal Analysis" } }
            }
        }
    }

    if ($suggestions.Count -gt 0) {
        Write-Host ""
        Write-Host "  RECOMMENDED NEXT STEPS:" -ForegroundColor Yellow
        foreach ($s in $suggestions) {
            Write-Host "    Option $($s.Option) -> $($s.Name)" -ForegroundColor White
        }
    }

    # -- Generate HTML report --
    Write-Host ""
    Write-Host "  Generating report..." -ForegroundColor DarkGray
    New-AutoDiscoverReport -Areas $areas -Suggestions $suggestions
    Write-Host "  Report saved: $reportFile" -ForegroundColor Green

    Write-Log "Auto-Discover completed. Critical=$criticalCount Warning=$warningCount"
    return $areas
}

# ============================================================
# MODE B: QUICK FIX BY SYMPTOM
# ============================================================

function Start-SymptomFix {
    Write-Banner "QUICK FIX - Pick Your Symptom"

    Write-Host "  What issue are you experiencing?" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    [1] Slow / Freezing" -ForegroundColor White
    Write-Host "    [2] Blue Screen (BSOD)" -ForegroundColor White
    Write-Host "    [3] Wi-Fi / Network Issues" -ForegroundColor White
    Write-Host "    [4] Battery Draining Fast" -ForegroundColor White
    Write-Host "    [5] Won't Boot Properly" -ForegroundColor White
    Write-Host "    [6] Security Alerts" -ForegroundColor White
    Write-Host "    [7] Display Problems" -ForegroundColor White
    Write-Host "    [8] Audio Issues" -ForegroundColor White
    Write-Host ""
    $symptom = Read-Host "  Select (1-8)"

    $workflows = @{
        '1' = @(
            @{ Func = "SoftwareCleanup";      Name = "Software Cleanup (temp files, startup)" },
            @{ Func = "PerformanceAnalyzer";   Name = "Performance Analyzer (CPU/mem/disk)" }
        )
        '2' = @(
            @{ Func = "BSODAnalysis";          Name = "BSOD Analysis (crash dump review)" },
            @{ Func = "BSODTroubleshooter";    Name = "BSOD Troubleshooter (auto-fix drivers)" }
        )
        '3' = @(
            @{ Func = "NetworkDiagnostic";     Name = "Network Diagnostic (scan adapters/DNS)" },
            @{ Func = "NetworkTroubleshooter";  Name = "Network Troubleshooter (auto-fix)" }
        )
        '4' = @(
            @{ Func = "BatteryHealth";         Name = "Battery Health (wear, cycles)" },
            @{ Func = "PowerSettings";         Name = "Power Settings (plans, sleep)" }
        )
        '5' = @(
            @{ Func = "BootRepair";            Name = "Boot Repair (BCD, SFC, DISM)" },
            @{ Func = "POSTErrorReader";       Name = "POST Error Reader (BIOS error codes)" }
        )
        '6' = @(
            @{ Func = "SecurityCheck";         Name = "Security Check (Defender, TPM, BitLocker)" },
            @{ Func = "SecurityHardening";     Name = "Security Hardening (auto-fix)" }
        )
        '7' = @(
            @{ Func = "DisplayCalibration";    Name = "Display Calibration (GPU, resolution)" },
            @{ Func = "DisplayPixelCheck";     Name = "Display Pixel Check (LCD, backlight)" }
        )
        '8' = @(
            @{ Func = "AudioDiagnostic";       Name = "Audio Diagnostic (sound devices)" }
        )
    }

    $symptomNames = @{
        '1' = "Slow / Freezing"
        '2' = "Blue Screen (BSOD)"
        '3' = "Wi-Fi / Network Issues"
        '4' = "Battery Draining Fast"
        '5' = "Won't Boot Properly"
        '6' = "Security Alerts"
        '7' = "Display Problems"
        '8' = "Audio Issues"
    }

    if (-not $workflows.ContainsKey($symptom)) {
        Write-Host "  Invalid selection." -ForegroundColor Red
        return
    }

    $selectedWorkflow = $workflows[$symptom]
    $symptomName = $symptomNames[$symptom]

    Write-Host ""
    Write-Host "  Selected: $symptomName" -ForegroundColor Cyan
    Write-Host "  Running $($selectedWorkflow.Count) diagnostic module(s):" -ForegroundColor DarkGray
    foreach ($step in $selectedWorkflow) {
        Write-Host "    -> $($step.Name)" -ForegroundColor White
    }
    Write-Host ""

    Write-Log "Symptom Fix selected: $symptomName ($($selectedWorkflow.Count) modules)"

    # Verify main PS1 exists
    if (-not (Test-Path $mainPS1)) {
        Write-Host "  ERROR: Laptop_Diagnostic_Suite.ps1 not found at:" -ForegroundColor Red
        Write-Host "  $mainPS1" -ForegroundColor Red
        Write-Host "  Please run these modules manually from the main menu." -ForegroundColor DarkGray
        Write-Log "ERROR: Main PS1 not found at $mainPS1"
        return
    }

    $stepNum = 0
    foreach ($step in $selectedWorkflow) {
        $stepNum++
        Write-Host ""
        Write-Host "  --------------------------------------------" -ForegroundColor DarkCyan
        Write-Host "  [$stepNum/$($selectedWorkflow.Count)] $($step.Name)" -ForegroundColor Cyan
        Write-Host "  --------------------------------------------" -ForegroundColor DarkCyan
        Write-Host ""

        Write-Log "Launching: $($step.Func) ($stepNum/$($selectedWorkflow.Count))"

        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $mainPS1 `
                -RunFunction $step.Func `
                -LogPath $LogPath `
                -ReportPath $ReportPath `
                -ConfigPath $ConfigPath `
                -BackupPath $BackupPath `
                -TempPath $TempPath `
                -DataPath $DataPath

            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                Write-Host "  $($step.Name) completed with warnings (exit: $exitCode)" -ForegroundColor Yellow
                Write-Log "$($step.Func) completed with exit code $exitCode"
            } else {
                Write-Host "  $($step.Name) completed successfully" -ForegroundColor Green
                Write-Log "$($step.Func) completed successfully"
            }
        } catch {
            Write-Host "  ERROR running $($step.Name): $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "ERROR running $($step.Func): $($_.Exception.Message)"
        }
    }

    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   All modules for '$symptomName' completed." -ForegroundColor Green
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Check Reports folder for detailed results." -ForegroundColor DarkGray

    Write-Log "Symptom Fix completed for: $symptomName"
}

# ============================================================
# MODE C: SCORE THIS MACHINE
# ============================================================

function Start-ScoreMachine {
    Write-Banner "SCORE THIS MACHINE - Health Assessment"

    Write-Host "  Machine:  $computerName" -ForegroundColor White
    Write-Host "  Model:    $model ($manufacturer)" -ForegroundColor White
    Write-Host "  Serial:   $serialNumber" -ForegroundColor White
    Write-Host ""
    Write-Host "  Scoring 4 categories..." -ForegroundColor DarkGray
    Write-Host ""

    # -- HARDWARE SCORE (weight: 30%) --
    Write-Host "  [1/4] Hardware ($weightHardware%)..." -ForegroundColor DarkGray -NoNewline
    $hwScore = 100
    $hwFindings = @()
    try {
        # RAM
        $totalRAM = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 1)
        if ($totalRAM -lt 4)      { $hwScore -= 25; $hwFindings += "RAM: ${totalRAM}GB (low)" }
        elseif ($totalRAM -lt 8)  { $hwScore -= 10; $hwFindings += "RAM: ${totalRAM}GB" }
        else { $hwFindings += "RAM: ${totalRAM}GB" }

        # Disks
        $disks = @(Get-PhysicalDisk -ErrorAction Stop)
        $unhealthy = @($disks | Where-Object { $_.HealthStatus -ne 'Healthy' })
        if ($unhealthy.Count -gt 0) {
            $hwScore -= 35
            $hwFindings += "$($unhealthy.Count) unhealthy disk(s)"
        } else {
            $hwFindings += "$($disks.Count) disk(s) healthy"
        }

        # PnP errors
        $pnpErrors = @(Get-PnpDevice -ErrorAction Stop | Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'Degraded' })
        if ($pnpErrors.Count -gt 3) { $hwScore -= 20; $hwFindings += "$($pnpErrors.Count) device errors" }
        elseif ($pnpErrors.Count -gt 0) { $hwScore -= ($pnpErrors.Count * 5); $hwFindings += "$($pnpErrors.Count) device error(s)" }

        # TPM
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            if (-not $tpm.TpmPresent -or -not $tpm.TpmReady) { $hwScore -= 10; $hwFindings += "TPM: Not ready" }
        } catch { $hwScore -= 5 }

        # Battery (for laptops)
        try {
            $bat = Get-CimInstance Win32_Battery -ErrorAction Stop
            if ($bat) {
                try {
                    $fullChg = (Get-CimInstance -Namespace 'root\WMI' -ClassName 'BatteryFullChargedCapacity' -ErrorAction Stop).FullChargedCapacity
                    $desCap  = (Get-CimInstance -Namespace 'root\WMI' -ClassName 'BatteryStaticData' -ErrorAction Stop).DesignedCapacity
                    if ($desCap -gt 0 -and $fullChg -gt 0) {
                        $batHealth = [math]::Round(($fullChg / $desCap) * 100, 1)
                        if ($batHealth -lt 40) { $hwScore -= 20; $hwFindings += "Battery: ${batHealth}% (replace)" }
                        elseif ($batHealth -lt 60) { $hwScore -= 10; $hwFindings += "Battery: ${batHealth}% (worn)" }
                        else { $hwFindings += "Battery: ${batHealth}%" }
                    }
                } catch { }
            }
        } catch { }
    } catch { $hwScore -= 15 }
    if ($hwScore -lt 0) { $hwScore = 0 }
    if ($hwScore -gt 100) { $hwScore = 100 }
    Write-Host " $hwScore/100" -ForegroundColor $(if ($hwScore -ge 80) { "Green" } elseif ($hwScore -ge 60) { "Yellow" } else { "Red" })

    # -- SECURITY SCORE (weight: 25%) --
    Write-Host "  [2/4] Security ($weightSecurity%)..." -ForegroundColor DarkGray -NoNewline
    $secScore = 100
    $secFindings = @()
    try {
        # Defender
        try {
            $def = Get-MpComputerStatus -ErrorAction Stop
            if (-not $def.RealTimeProtectionEnabled) { $secScore -= 25; $secFindings += "Defender RT: OFF" }
            else { $secFindings += "Defender: Active" }
            if (-not $def.AntivirusEnabled) { $secScore -= 15; $secFindings += "Antivirus: OFF" }
        } catch { $secScore -= 15; $secFindings += "Defender: Unavailable" }

        # Firewall
        try {
            $fwProf = Get-NetFirewallProfile -ErrorAction Stop
            $fwOff = @($fwProf | Where-Object { -not $_.Enabled }).Count
            if ($fwOff -gt 0) { $secScore -= ($fwOff * 8); $secFindings += "Firewall: $fwOff profile(s) off" }
            else { $secFindings += "Firewall: All on" }
        } catch { }

        # SecureBoot
        try {
            $sb = Confirm-SecureBootUEFI -ErrorAction Stop
            if (-not $sb) { $secScore -= 10; $secFindings += "SecureBoot: OFF" }
            else { $secFindings += "SecureBoot: ON" }
        } catch { $secFindings += "SecureBoot: N/A" }

        # UAC
        try {
            $uacVal = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction Stop).EnableLUA
            if ($uacVal -ne 1) { $secScore -= 15; $secFindings += "UAC: OFF" }
        } catch { }

        # BitLocker
        try {
            $blV = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$($env:SystemDrive)'" -ErrorAction Stop
            if ($blV.ProtectionStatus -ne 1) { $secScore -= 10; $secFindings += "BitLocker: Off" }
            else { $secFindings += "BitLocker: On" }
        } catch { $secFindings += "BitLocker: N/A" }
    } catch { $secScore -= 20 }
    if ($secScore -lt 0) { $secScore = 0 }
    if ($secScore -gt 100) { $secScore = 100 }
    Write-Host " $secScore/100" -ForegroundColor $(if ($secScore -ge 80) { "Green" } elseif ($secScore -ge 60) { "Yellow" } else { "Red" })

    # -- STABILITY SCORE (weight: 25%) --
    Write-Host "  [3/4] Stability ($weightStability%)..." -ForegroundColor DarkGray -NoNewline
    $stabScore = 100
    $stabFindings = @()
    try {
        $days30ago = (Get-Date).AddDays(-30)

        # BSOD count
        $bsodCnt = 0
        try {
            $bsodEvts = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=$days30ago} -ErrorAction Stop)
            $bsodCnt = $bsodEvts.Count
        } catch { }
        if ($bsodCnt -gt 5)     { $stabScore -= 40; $stabFindings += "BSODs: $bsodCnt (critical)" }
        elseif ($bsodCnt -gt 2) { $stabScore -= 25; $stabFindings += "BSODs: $bsodCnt" }
        elseif ($bsodCnt -gt 0) { $stabScore -= 10; $stabFindings += "BSODs: $bsodCnt" }
        else { $stabFindings += "BSODs: 0" }

        # Kernel-Power 41
        $kpCnt = 0
        try {
            $kpEvts = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=41; ProviderName='Microsoft-Windows-Kernel-Power'; StartTime=$days30ago} -ErrorAction Stop)
            $kpCnt = $kpEvts.Count
        } catch { }
        if ($kpCnt -gt 5)     { $stabScore -= 25; $stabFindings += "Reset events: $kpCnt" }
        elseif ($kpCnt -gt 0) { $stabScore -= 10; $stabFindings += "Reset events: $kpCnt" }

        # SFC integrity
        try {
            $sfcLog = Join-Path $env:WINDIR "Logs\CBS\CBS.log"
            if (Test-Path $sfcLog) {
                $lastLines = Get-Content $sfcLog -Tail 100 -ErrorAction Stop
                $violations = @($lastLines | Select-String "Corruption|violation" -ErrorAction SilentlyContinue)
                if ($violations.Count -gt 0) { $stabScore -= 15; $stabFindings += "SFC: $($violations.Count) integrity violation(s)" }
                else { $stabFindings += "SFC: No recent violations" }
            }
        } catch { }

        # Uptime
        try {
            $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $uptimeDays = [math]::Round(((Get-Date) - $osInfo.LastBootUpTime).TotalDays, 1)
            if ($uptimeDays -gt 30) { $stabScore -= 10; $stabFindings += "Uptime: ${uptimeDays}d (reboot needed)" }
            else { $stabFindings += "Uptime: ${uptimeDays}d" }
        } catch { }
    } catch { $stabScore -= 15 }
    if ($stabScore -lt 0) { $stabScore = 0 }
    if ($stabScore -gt 100) { $stabScore = 100 }
    Write-Host " $stabScore/100" -ForegroundColor $(if ($stabScore -ge 80) { "Green" } elseif ($stabScore -ge 60) { "Yellow" } else { "Red" })

    # -- PERFORMANCE SCORE (weight: 20%) --
    Write-Host "  [4/4] Performance ($weightPerformance%)..." -ForegroundColor DarkGray -NoNewline
    $perfScore = 100
    $perfFindings = @()
    try {
        # Free disk space
        try {
            $sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
            $freeGB = [math]::Round($sysDrive.FreeSpace / 1GB, 1)
            $totalGB = [math]::Round($sysDrive.Size / 1GB, 1)
            $freePct = [math]::Round(($sysDrive.FreeSpace / $sysDrive.Size) * 100, 1)
            if ($freePct -lt 5)       { $perfScore -= 35; $perfFindings += "Disk: ${freeGB}GB free (${freePct}% - CRITICAL)" }
            elseif ($freePct -lt 10)  { $perfScore -= 20; $perfFindings += "Disk: ${freeGB}GB free (${freePct}%)" }
            elseif ($freePct -lt 20)  { $perfScore -= 10; $perfFindings += "Disk: ${freeGB}GB free (${freePct}%)" }
            else { $perfFindings += "Disk: ${freeGB}/${totalGB}GB (${freePct}% free)" }
        } catch { }

        # CPU load
        try {
            $cpuLoad = (Get-CimInstance Win32_Processor -ErrorAction Stop).LoadPercentage
            if ($cpuLoad -gt 90)     { $perfScore -= 25; $perfFindings += "CPU: ${cpuLoad}% (overloaded)" }
            elseif ($cpuLoad -gt 70) { $perfScore -= 10; $perfFindings += "CPU: ${cpuLoad}% (high)" }
            else { $perfFindings += "CPU: ${cpuLoad}%" }
        } catch { }

        # Memory usage
        try {
            $osPerf = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $totalMem = $osPerf.TotalVisibleMemorySize
            $freeMem = $osPerf.FreePhysicalMemory
            $usedPct = [math]::Round((($totalMem - $freeMem) / $totalMem) * 100, 1)
            if ($usedPct -gt 90)     { $perfScore -= 25; $perfFindings += "Memory: ${usedPct}% used (critical)" }
            elseif ($usedPct -gt 80) { $perfScore -= 10; $perfFindings += "Memory: ${usedPct}% used (high)" }
            else { $perfFindings += "Memory: ${usedPct}% used" }
        } catch { }

        # Startup items count
        try {
            $startupItems = @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop)
            if ($startupItems.Count -gt 15) { $perfScore -= 10; $perfFindings += "Startup items: $($startupItems.Count) (too many)" }
            elseif ($startupItems.Count -gt 10) { $perfScore -= 5; $perfFindings += "Startup items: $($startupItems.Count)" }
            else { $perfFindings += "Startup items: $($startupItems.Count)" }
        } catch { }
    } catch { $perfScore -= 15 }
    if ($perfScore -lt 0) { $perfScore = 0 }
    if ($perfScore -gt 100) { $perfScore = 100 }
    Write-Host " $perfScore/100" -ForegroundColor $(if ($perfScore -ge 80) { "Green" } elseif ($perfScore -ge 60) { "Yellow" } else { "Red" })

    # -- OVERALL SCORE --
    $overallScore = [math]::Round(
        ($hwScore * $weightHardware / 100) +
        ($secScore * $weightSecurity / 100) +
        ($stabScore * $weightStability / 100) +
        ($perfScore * $weightPerformance / 100)
    )
    if ($overallScore -lt 0) { $overallScore = 0 }
    if ($overallScore -gt 100) { $overallScore = 100 }
    $grade = Get-LetterGrade -Score $overallScore
    $gradeLabel = Get-GradeLabel -Grade $grade

    # -- BASELINE COMPARISON --
    $baselineData = Compare-Baseline -SerialNumber $serialNumber -Scores @{
        Hardware    = $hwScore
        Security    = $secScore
        Stability   = $stabScore
        Performance = $perfScore
        Overall     = $overallScore
        Grade       = $grade
    }

    # -- DISPLAY SCORECARD --
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   MACHINE HEALTH SCORE" -ForegroundColor White
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-ProgressBar -Label "Hardware" -Score $hwScore
    Write-ProgressBar -Label "Security" -Score $secScore
    Write-ProgressBar -Label "Stability" -Score $stabScore
    Write-ProgressBar -Label "Performance" -Score $perfScore
    Write-Host "    ------------------------------------------------" -ForegroundColor DarkGray
    Write-ProgressBar -Label "OVERALL" -Score $overallScore
    Write-Host ""

    $gradeColor = if ($grade -eq "A") { "Green" }
                  elseif ($grade -eq "B") { "Green" }
                  elseif ($grade -eq "C") { "Yellow" }
                  elseif ($grade -eq "D") { "Yellow" }
                  else { "Red" }
    Write-Host "    Grade: $grade - $gradeLabel" -ForegroundColor $gradeColor
    Write-Host ""

    # -- CATEGORY DETAILS --
    Write-Host "  DETAILS:" -ForegroundColor DarkGray
    Write-Host "    Hardware:    $($hwFindings -join ' | ')" -ForegroundColor Gray
    Write-Host "    Security:    $($secFindings -join ' | ')" -ForegroundColor Gray
    Write-Host "    Stability:   $($stabFindings -join ' | ')" -ForegroundColor Gray
    Write-Host "    Performance: $($perfFindings -join ' | ')" -ForegroundColor Gray
    Write-Host ""

    # -- SAVE BASELINE --
    Save-Baseline -SerialNumber $serialNumber -Scores @{
        Hardware    = $hwScore
        Security    = $secScore
        Stability   = $stabScore
        Performance = $perfScore
        Overall     = $overallScore
        Grade       = $grade
    }

    # -- SAVE CSV FOR FLEET --
    $csvFile = Join-Path $ResultsPath "QuickStart_Fleet.csv"
    $csvRow = [PSCustomObject]@{
        ComputerName     = $computerName
        SerialNumber     = $serialNumber
        Manufacturer     = $manufacturer
        Model            = $model
        OverallScore     = $overallScore
        LetterGrade      = $grade
        HardwareScore    = $hwScore
        SecurityScore    = $secScore
        StabilityScore   = $stabScore
        PerformanceScore = $perfScore
        ScanDate         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        OverallStatus    = if ($overallScore -ge $gradeC) { "PASS" } elseif ($overallScore -ge $gradeD) { "WARNING" } else { "FAIL" }
    }

    # Append to fleet CSV (create header if new)
    if (Test-Path $csvFile) {
        $csvRow | Export-Csv -Path $csvFile -NoTypeInformation -Append -Force -Encoding UTF8
    } else {
        $csvRow | Export-Csv -Path $csvFile -NoTypeInformation -Force -Encoding UTF8
    }
    Write-Host "  Fleet CSV updated: $csvFile" -ForegroundColor Green

    # -- GENERATE HTML SCORECARD --
    New-ScorecardReport -Scores @{
        Hardware    = $hwScore
        Security    = $secScore
        Stability   = $stabScore
        Performance = $perfScore
        Overall     = $overallScore
        Grade       = $grade
        GradeLabel  = $gradeLabel
    } -Findings @{
        Hardware    = $hwFindings
        Security    = $secFindings
        Stability   = $stabFindings
        Performance = $perfFindings
    } -BaselineData $baselineData
    Write-Host "  Report saved: $reportFile" -ForegroundColor Green

    Write-Log "Score Machine completed. Overall=$overallScore Grade=$grade"
    return @{ Overall = $overallScore; Grade = $grade }
}

# ============================================================
# BASELINE FUNCTIONS
# ============================================================

function Save-Baseline {
    param(
        [string]$SerialNumber,
        [hashtable]$Scores
    )
    if (-not $SerialNumber -or $SerialNumber -eq 'Unknown') { return }
    $baselineDir = Join-Path $ResultsPath 'Baselines'
    if (-not (Test-Path $baselineDir)) {
        New-Item -Path $baselineDir -ItemType Directory -Force | Out-Null
    }
    $baselineFile = Join-Path $baselineDir "${SerialNumber}_baseline.json"

    $baseline = @{
        SerialNumber     = $SerialNumber
        ComputerName     = $computerName
        Model            = $model
        ScanDate         = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        OverallScore     = $Scores.Overall
        HardwareScore    = $Scores.Hardware
        SecurityScore    = $Scores.Security
        StabilityScore   = $Scores.Stability
        PerformanceScore = $Scores.Performance
        LetterGrade      = $Scores.Grade
    }

    $baseline | ConvertTo-Json -Depth 3 | Out-File -FilePath $baselineFile -Encoding UTF8 -Force
    Write-Host "  Baseline saved: $baselineFile" -ForegroundColor Green
    Write-Log "Baseline saved for $SerialNumber at $baselineFile"
}

function Compare-Baseline {
    param(
        [string]$SerialNumber,
        [hashtable]$Scores
    )
    if (-not $SerialNumber -or $SerialNumber -eq 'Unknown') { return $null }
    $baselineFile = Join-Path $ResultsPath "Baselines\${SerialNumber}_baseline.json"
    if (-not (Test-Path $baselineFile)) {
        Write-Host ""
        Write-Host "  No previous baseline found. This scan will become the baseline." -ForegroundColor DarkGray
        return $null
    }

    try {
        $prevJson = Get-Content $baselineFile -Raw -ErrorAction Stop
        $prev = $prevJson | ConvertFrom-Json
    } catch {
        Write-Host "  Could not read previous baseline." -ForegroundColor Yellow
        return $null
    }

    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor DarkCyan
    Write-Host "   BASELINE COMPARISON (vs $(if ($prev.ScanDate) { $prev.ScanDate } else { 'unknown' }))" -ForegroundColor White
    Write-Host "  ============================================================" -ForegroundColor DarkCyan
    Write-Host ""

    $categories = @(
        @{ Name = "Hardware";    Prop = "HardwareScore";    Key = "Hardware" },
        @{ Name = "Security";    Prop = "SecurityScore";    Key = "Security" },
        @{ Name = "Stability";   Prop = "StabilityScore";   Key = "Stability" },
        @{ Name = "Performance"; Prop = "PerformanceScore"; Key = "Performance" },
        @{ Name = "OVERALL";     Prop = "OverallScore";     Key = "Overall" }
    )

    foreach ($cat in $categories) {
        $prevVal = 0
        $propName = $cat.Prop
        if ($prev.$propName) { $prevVal = [int]$prev.$propName }
        $currVal = [int]$Scores[$cat.Key]
        $delta = $currVal - $prevVal

        $arrow = if ($delta -gt 0) { "+$delta" } elseif ($delta -lt 0) { "$delta" } else { "=" }
        $color = if ($delta -gt 0) { "Green" } elseif ($delta -lt 0) { "Red" } else { "Gray" }
        $label = if ($delta -gt 0) { "IMPROVED" } elseif ($delta -lt 0) { "DEGRADED" } else { "UNCHANGED" }

        $catPad = $cat.Name.PadRight(14)
        Write-Host "    $catPad $($prevVal.ToString().PadLeft(3)) -> $($currVal.ToString().PadLeft(3))  $($arrow.PadLeft(4))  $label" -ForegroundColor $color
    }
    Write-Host ""

    Write-Log "Baseline comparison: Previous date=$($prev.ScanDate) PrevOverall=$($prev.OverallScore) CurrOverall=$($Scores.Overall)"
    return $prev
}

# ============================================================
# HTML REPORT: AUTO-DISCOVER
# ============================================================

function New-AutoDiscoverReport {
    param(
        [array]$Areas,
        [array]$Suggestions
    )

    $critCount = @($Areas | Where-Object { $_.Status -eq "Critical" }).Count
    $warnCount = @($Areas | Where-Object { $_.Status -eq "Warning" }).Count
    $overallStatus = if ($critCount -gt 0) { "ISSUES FOUND" } elseif ($warnCount -gt 0) { "ATTENTION NEEDED" } else { "ALL CLEAR" }
    $overallColor  = if ($critCount -gt 0) { "#E2231A" } elseif ($warnCount -gt 0) { "#F59E0B" } else { "#00C875" }

    $areaRows = ""
    foreach ($area in $Areas) {
        $statusColor = if ($area.Status -eq "Good") { "#00C875" } elseif ($area.Status -eq "Warning") { "#F59E0B" } else { "#E2231A" }
        $areaRows += "<tr><td style='font-weight:600'>$($area.Area)</td><td><span style='color:${statusColor};font-weight:600'>$($area.Status)</span></td><td style='color:#A0B8D0'>$($area.Details)</td></tr>`n"
    }

    $suggestionsHtml = ""
    if ($Suggestions.Count -gt 0) {
        $suggestionsHtml = @"
  <div style="margin-top:32px;padding:24px;background:rgba(26,93,204,0.08);border:1px solid rgba(26,93,204,0.25);border-radius:12px;">
    <div style="font-size:18px;font-weight:600;color:#4A8BEF;margin-bottom:12px;">RECOMMENDED NEXT STEPS</div>
"@
        foreach ($s in $Suggestions) {
            $suggestionsHtml += "    <div style='padding:8px 0;border-bottom:1px solid rgba(255,255,255,0.05);display:flex;gap:12px'><span style='font-family:monospace;font-size:12px;color:#4A8BEF;min-width:100px'>Option $($s.Option)</span><span style='color:#A0B8D0;font-size:13px'>$($s.Name)</span></div>`n"
        }
        $suggestionsHtml += "  </div>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="dark">
<title>Auto-Discover Report - $computerName - $dateDisplay</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #0A0F1A; color: #F5F7FA; font-family: 'Segoe UI', sans-serif; font-size: 14px; line-height: 1.7; padding: 40px 20px; }
  .container { max-width: 900px; margin: 0 auto; }
  h1 { font-size: 28px; margin-bottom: 4px; letter-spacing: 1px; }
  h1 span { color: #4A8BEF; }
  .subtitle { color: #7A8BA8; font-size: 13px; margin-bottom: 32px; }
  .machine-info { display: flex; gap: 24px; flex-wrap: wrap; margin-bottom: 32px; padding: 16px 20px; background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; }
  .machine-info div { font-size: 12px; color: #7A8BA8; }
  .machine-info strong { color: #F5F7FA; font-weight: 600; }
  .overall { text-align: center; padding: 32px; margin-bottom: 40px; border-radius: 16px; border: 2px solid ${overallColor}40; background: ${overallColor}10; }
  .overall-status { font-size: 36px; font-weight: 700; color: ${overallColor}; letter-spacing: 2px; margin-bottom: 8px; }
  .overall-sub { color: #7A8BA8; font-size: 14px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; padding: 10px 14px; color: #4A8BEF; font-size: 10px; text-transform: uppercase; letter-spacing: 1.5px; border-bottom: 1px solid rgba(26,93,204,0.3); font-weight: 400; }
  td { padding: 10px 14px; border-bottom: 1px solid rgba(255,255,255,0.05); }
  .footer { margin-top: 40px; text-align: center; color: rgba(122,139,168,0.5); font-size: 11px; }
  @media print { body { background: #fff; color: #111; } .overall { border-color: #ccc; background: #f8f8f8; } .overall-status { color: #333; } td, th { color: #333; } }
</style>
</head>
<body>
<div class="container">
  <h1>AUTO-DISCOVER <span>REPORT</span></h1>
  <div class="subtitle">LDT v6.1 - Quick Start - Generated $dateDisplay</div>

  <div class="machine-info">
    <div><strong>$computerName</strong> Computer</div>
    <div><strong>$model</strong> Model</div>
    <div><strong>$serialNumber</strong> Serial</div>
    <div><strong>$dateDisplay</strong> Scan Time</div>
  </div>

  <div class="overall">
    <div class="overall-status">$overallStatus</div>
    <div class="overall-sub">$critCount critical, $warnCount warning, $(@($Areas | Where-Object { $_.Status -eq "Good" }).Count) good</div>
  </div>

  <div style="padding:24px;background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);border-radius:12px;">
    <table>
      <thead><tr><th>Area</th><th>Status</th><th>Details</th></tr></thead>
      <tbody>
        $areaRows
      </tbody>
    </table>
  </div>

  $suggestionsHtml

  <div class="footer">LDT v6.1 &middot; Auto-Discover Report &middot; $($reportFile | Split-Path -Leaf)</div>
</div>
</body>
</html>
"@

    $html | Out-File -FilePath $reportFile -Encoding UTF8 -Force
    Write-Log "Auto-Discover HTML report saved: $reportFile"
}

# ============================================================
# HTML REPORT: SCORECARD
# ============================================================

function New-ScorecardReport {
    param(
        [hashtable]$Scores,
        [hashtable]$Findings,
        $BaselineData
    )

    $grade = $Scores.Grade
    $gradeLabel = $Scores.GradeLabel
    $overall = $Scores.Overall
    $gradeColor = if ($grade -eq "A" -or $grade -eq "B") { "#00C875" } elseif ($grade -eq "C" -or $grade -eq "D") { "#F59E0B" } else { "#E2231A" }

    # Build score bars
    function Get-BarHtml([string]$label, [int]$score, [string]$color) {
        $width = $score
        return "<div style='margin-bottom:16px'><div style='display:flex;justify-content:space-between;margin-bottom:4px'><span style='color:#A0B8D0;font-size:13px'>$label</span><span style='color:${color};font-weight:600;font-size:13px'>${score}/100</span></div><div style='background:rgba(255,255,255,0.06);border-radius:6px;height:12px;overflow:hidden'><div style='width:${width}%;height:100%;background:${color};border-radius:6px;transition:width 0.3s'></div></div></div>"
    }

    $hwColor   = if ($Scores.Hardware -ge 80) { "#00C875" } elseif ($Scores.Hardware -ge 60) { "#F59E0B" } else { "#E2231A" }
    $secColor  = if ($Scores.Security -ge 80) { "#00C875" } elseif ($Scores.Security -ge 60) { "#F59E0B" } else { "#E2231A" }
    $stabColor = if ($Scores.Stability -ge 80) { "#00C875" } elseif ($Scores.Stability -ge 60) { "#F59E0B" } else { "#E2231A" }
    $perfColor = if ($Scores.Performance -ge 80) { "#00C875" } elseif ($Scores.Performance -ge 60) { "#F59E0B" } else { "#E2231A" }

    $barsHtml = (Get-BarHtml "Hardware ($weightHardware%)" $Scores.Hardware $hwColor) +
                (Get-BarHtml "Security ($weightSecurity%)" $Scores.Security $secColor) +
                (Get-BarHtml "Stability ($weightStability%)" $Scores.Stability $stabColor) +
                (Get-BarHtml "Performance ($weightPerformance%)" $Scores.Performance $perfColor)

    # Build findings detail
    $findingsHtml = ""
    foreach ($cat in @("Hardware", "Security", "Stability", "Performance")) {
        $items = $Findings[$cat]
        if ($items -and $items.Count -gt 0) {
            $findingsHtml += "<div style='margin-bottom:16px'><div style='font-weight:600;color:#4A8BEF;font-size:13px;margin-bottom:4px'>$cat</div>"
            foreach ($item in $items) {
                $findingsHtml += "<div style='color:#A0B8D0;font-size:12px;padding:2px 0'>- $item</div>"
            }
            $findingsHtml += "</div>"
        }
    }

    # Baseline delta section
    $baselineHtml = ""
    if ($BaselineData) {
        $baselineHtml = "<div style='margin-top:32px;padding:24px;background:rgba(26,93,204,0.08);border:1px solid rgba(26,93,204,0.25);border-radius:12px'>"
        $baselineHtml += "<div style='font-size:18px;font-weight:600;color:#4A8BEF;margin-bottom:12px'>BASELINE COMPARISON</div>"
        $baselineHtml += "<div style='font-size:12px;color:#7A8BA8;margin-bottom:12px'>Previous scan: $(if ($BaselineData.ScanDate) { $BaselineData.ScanDate } else { 'unknown' })</div>"
        $baselineHtml += "<table><thead><tr><th>Category</th><th>Previous</th><th>Current</th><th>Change</th></tr></thead><tbody>"

        $bsCats = @(
            @{ Name = "Hardware";    Prop = "HardwareScore";    Key = "Hardware" },
            @{ Name = "Security";    Prop = "SecurityScore";    Key = "Security" },
            @{ Name = "Stability";   Prop = "StabilityScore";   Key = "Stability" },
            @{ Name = "Performance"; Prop = "PerformanceScore"; Key = "Performance" },
            @{ Name = "Overall";     Prop = "OverallScore";     Key = "Overall" }
        )
        foreach ($bsc in $bsCats) {
            $prevV = 0
            $propN = $bsc.Prop
            if ($BaselineData.$propN) { $prevV = [int]$BaselineData.$propN }
            $currV = [int]$Scores[$bsc.Key]
            $d = $currV - $prevV
            $dColor = if ($d -gt 0) { "#00C875" } elseif ($d -lt 0) { "#E2231A" } else { "#7A8BA8" }
            $dText = if ($d -gt 0) { "+$d" } elseif ($d -lt 0) { "$d" } else { "=" }
            $baselineHtml += "<tr><td style='font-weight:600'>$($bsc.Name)</td><td>$prevV</td><td>$currV</td><td style='color:${dColor};font-weight:600'>$dText</td></tr>"
        }
        $baselineHtml += "</tbody></table></div>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="dark">
<title>Health Score - $computerName - Grade $grade - $dateDisplay</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #0A0F1A; color: #F5F7FA; font-family: 'Segoe UI', sans-serif; font-size: 14px; line-height: 1.7; padding: 40px 20px; }
  .container { max-width: 900px; margin: 0 auto; }
  h1 { font-size: 28px; margin-bottom: 4px; letter-spacing: 1px; }
  h1 span { color: ${gradeColor}; }
  .subtitle { color: #7A8BA8; font-size: 13px; margin-bottom: 32px; }
  .machine-info { display: flex; gap: 24px; flex-wrap: wrap; margin-bottom: 32px; padding: 16px 20px; background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; }
  .machine-info div { font-size: 12px; color: #7A8BA8; }
  .machine-info strong { color: #F5F7FA; font-weight: 600; }
  .grade-card { text-align: center; padding: 40px; margin-bottom: 40px; border-radius: 16px; border: 2px solid ${gradeColor}40; background: ${gradeColor}10; }
  .grade-letter { font-size: 72px; font-weight: 700; color: ${gradeColor}; line-height: 1; }
  .grade-score { font-size: 24px; color: #F5F7FA; margin-top: 8px; }
  .grade-label { font-size: 16px; color: #7A8BA8; margin-top: 4px; }
  .section { padding: 24px; background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; margin-bottom: 24px; }
  .section-title { font-size: 16px; font-weight: 600; margin-bottom: 16px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; padding: 8px 12px; color: #4A8BEF; font-size: 10px; text-transform: uppercase; letter-spacing: 1.5px; border-bottom: 1px solid rgba(26,93,204,0.3); font-weight: 400; }
  td { padding: 8px 12px; border-bottom: 1px solid rgba(255,255,255,0.05); color: #A0B8D0; }
  .footer { margin-top: 40px; text-align: center; color: rgba(122,139,168,0.5); font-size: 11px; }
  @media print { body { background: #fff; color: #111; } .grade-card { border-color: #ccc; background: #f8f8f8; } .grade-letter, .grade-score { color: #333; } .section { background: #f8f8f8; border-color: #ddd; } td, th { color: #333; } }
</style>
</head>
<body>
<div class="container">
  <h1>HEALTH <span>SCORECARD</span></h1>
  <div class="subtitle">LDT v6.1 - Score This Machine - Generated $dateDisplay</div>

  <div class="machine-info">
    <div><strong>$computerName</strong> Computer</div>
    <div><strong>$model</strong> Model</div>
    <div><strong>$serialNumber</strong> Serial</div>
    <div><strong>$manufacturer</strong> Vendor</div>
    <div><strong>$dateDisplay</strong> Scan Time</div>
  </div>

  <div class="grade-card">
    <div class="grade-letter">$grade</div>
    <div class="grade-score">$overall / 100</div>
    <div class="grade-label">$gradeLabel</div>
  </div>

  <div class="section">
    <div class="section-title">Score Breakdown</div>
    $barsHtml
  </div>

  <div class="section">
    <div class="section-title">Detailed Findings</div>
    $findingsHtml
  </div>

  $baselineHtml

  <div class="footer">LDT v6.1 &middot; Health Scorecard &middot; $($reportFile | Split-Path -Leaf)</div>
</div>
</body>
</html>
"@

    $html | Out-File -FilePath $reportFile -Encoding UTF8 -Force
    Write-Log "Scorecard HTML report saved: $reportFile"
}

# ============================================================
# MODE SELECTION & MAIN EXECUTION
# ============================================================

# If no mode specified, show menu
if (-not $Mode) {
    Write-Banner "QUICK START - LDT v6.1"

    Write-Host "  Machine:  $computerName" -ForegroundColor White
    Write-Host "  Model:    $model" -ForegroundColor White
    Write-Host "  Serial:   $serialNumber" -ForegroundColor White
    Write-Host ""
    Write-Host "  Select a workflow:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    [1] Auto-Discover       Scan machine, show what's wrong" -ForegroundColor White
    Write-Host "    [2] Quick Fix            Pick a symptom, run targeted fixes" -ForegroundColor White
    Write-Host "    [3] Score This Machine   Health score 0-100 with grade" -ForegroundColor White
    Write-Host ""
    $menuChoice = Read-Host "  Select (1-3)"

    switch ($menuChoice) {
        '1' { $Mode = 'AutoDiscover' }
        '2' { $Mode = 'SymptomFix' }
        '3' { $Mode = 'ScoreMachine' }
        default {
            Write-Host "  Invalid selection." -ForegroundColor Red
            exit 1
        }
    }
}

# Execute selected mode
Write-Log "Executing mode: $Mode"
switch ($Mode) {
    'AutoDiscover' { Start-AutoDiscover }
    'SymptomFix'   { Start-SymptomFix }
    'ScoreMachine' { Start-ScoreMachine }
}

# Open report if it exists
if (Test-Path $reportFile) {
    Write-Host ""
    Write-Host "  Opening report in browser..." -ForegroundColor DarkGray
    Start-Process $reportFile -ErrorAction SilentlyContinue
}

Write-Log "Quick Start completed."
Write-Host ""
Write-Host "  Log saved: $logFile" -ForegroundColor DarkGray
Write-Host ""
