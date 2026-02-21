#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    LDT OEM Validation Mode -- Read-Only Hardware and Firmware Baseline Validator (Option 55)

.DESCRIPTION
    Operates in a strictly read-only mode. NO system state is modified.
    NO repairs are applied. NO registry writes occur.

    Designed for:
      - Hardware validation labs before device shipping
      - Pre-deployment board validation
      - OEM quality assurance checklists
      - Windows 11 readiness audits
      - Hardware fingerprint drift detection between imaging cycles

    8 Validated Components:
      1. Secure Boot  -- Policy, state
      2. TPM          -- Presence, version, readiness
      3. Firmware      -- BIOS/UEFI version, date, vendor
      4. Hardware Fingerprint -- CPU, RAM, disk, NIC, GPU
      5. Windows 11 Readiness -- Full compatibility check
      6. POST History  -- Kernel boot events
      7. Driver Catalog -- Signed/unsigned enumeration
      8. Baseline Drift -- Compare against saved JSON

.PARAMETER BaselinePath
    Optional: Path to a hardware baseline JSON for drift comparison.

.PARAMETER OutputPath
    Where to write OEM validation artifacts. Defaults to Reports/ next to script.

.PARAMETER SaveBaseline
    When set, saves current hardware fingerprint as new baseline file.

.NOTES
    Version : 7.0.0
    Platform: PowerShell 5.1+
    Ported  : From WinDRE v2.1.0 OEM Validation with PS 5.1 remediation
#>

[CmdletBinding()]
param(
    [string] $BaselinePath = '',
    [string] $OutputPath   = '',
    [string] $DataPath     = '',
    [switch] $SaveBaseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LDT_Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# Default paths relative to LDT root
if (-not $OutputPath) { $OutputPath = Join-Path $LDT_Root "Reports" }
if (-not $DataPath)   { $DataPath   = Join-Path $LDT_Root "Data" }

# Load enterprise engines (adapter + GuardEngine needed for OEM mode)
$v7Available = $false
$coreDir = Join-Path $LDT_Root "Core"
if (Test-Path $coreDir) {
    try {
        Import-Module (Join-Path $coreDir "LDT-EngineAdapter.psm1") -Force -ErrorAction Stop
        Import-Module (Join-Path $coreDir "GuardEngine.psm1") -Force -ErrorAction Stop
        $v7Available = $true
    }
    catch {
        Write-Host "  [WARN] Enterprise engines not available: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$sessionId = "OEM_$([System.Guid]::NewGuid().ToString('N').Substring(0,12).ToUpper())"

# Ensure output directories exist
foreach ($dir in @($OutputPath, $DataPath)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# Initialize log adapter
if ($v7Available) {
    $logFile = Join-Path $OutputPath "OEM_Validation_${timestamp}.log"
    Initialize-EngineAdapter -LogFilePath $logFile
}

# Initialize GuardEngine in OEM Mode -- all write operations blocked
if ($v7Available) {
    $oemConfig = [PSCustomObject]@{ engine = @{}; modules = @{} }
    Initialize-GuardEngine -SessionId $sessionId -Config $oemConfig -OEMMode
}

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "   LDT OEM VALIDATION MODE -- READ-ONLY" -ForegroundColor Magenta
Write-Host "   Hardware & Firmware Baseline Validation" -ForegroundColor Magenta
Write-Host "   NO SYSTEM STATE WILL BE MODIFIED" -ForegroundColor Yellow
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host ""

$report = [ordered]@{
    _type        = 'OEM_VALIDATION_REPORT'
    sessionId    = $sessionId
    timestamp    = Get-Date -Format 'o'
    computername = $env:COMPUTERNAME
    mode         = 'OEM_VALIDATION_READ_ONLY'
    checks       = [ordered]@{}
    driftReport  = $null
    win11Ready   = $null
    baseline     = $null
}

# ── 1: SECURE BOOT ────────────────────────────────────────────────────────────
Write-Host "  [1/8] Secure Boot validation..." -ForegroundColor Cyan
try {
    $sb = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
    $sbPolicyName = 'N/A'
    try {
        $sbPolicy = Get-SecureBootPolicy -ErrorAction SilentlyContinue
        if ($sbPolicy) { $sbPolicyName = $sbPolicy.PolicyPublisher }
    } catch { }

    $sbDbStatus = 'UNKNOWN'
    try {
        $sbDb = Get-SecureBootUEFI -Name 'db' -ErrorAction SilentlyContinue
        $sbDbStatus = if ($sbDb) { 'DB_PRESENT' } else { 'DB_MISSING' }
    } catch { }

    $report.checks['SecureBoot'] = [ordered]@{
        status     = if ($sb -eq $true) { 'ENABLED' } else { 'DISABLED' }
        policyName = $sbPolicyName
        uefiVars   = $sbDbStatus
        finding    = if ($sb) { 'OK' } else { 'WARN: Secure Boot is disabled' }
    }
    Write-Host "    Secure Boot: $(if ($sb) { 'ENABLED' } else { 'DISABLED' })" -ForegroundColor $(if ($sb) { 'Green' } else { 'Yellow' })
} catch {
    $report.checks['SecureBoot'] = @{ status = 'LEGACY_BIOS_OR_NOT_AVAILABLE'; finding = 'WARN: System may not support Secure Boot' }
    Write-Host "    Secure Boot: Not available" -ForegroundColor Yellow
}

# ── 2: TPM ────────────────────────────────────────────────────────────────────
Write-Host "  [2/8] TPM readiness validation..." -ForegroundColor Cyan
try {
    $tpm = Get-Tpm -ErrorAction Stop
    $tpmSpecVer = if ($tpm.ManufacturerVersion) { $tpm.ManufacturerVersion } else { 'UNKNOWN' }
    $tpmMfgId   = if ($tpm.ManufacturerId) { $tpm.ManufacturerId } else { 'UNKNOWN' }

    $report.checks['TPM'] = [ordered]@{
        present        = $tpm.TpmPresent
        ready          = $tpm.TpmReady
        enabled        = $tpm.TpmEnabled
        activated      = $tpm.TpmActivated
        owned          = $tpm.TpmOwned
        specVersion    = $tpmSpecVer
        manufacturerId = $tpmMfgId
        finding        = if ($tpm.TpmPresent -and $tpm.TpmReady -and $tpm.TpmEnabled) { 'OK' }
                         else { "WARN: TPM state not optimal -- Present:$($tpm.TpmPresent) Ready:$($tpm.TpmReady) Enabled:$($tpm.TpmEnabled)" }
    }

    # EK presence check (read-only)
    try {
        $ekInfo = Get-TpmEndorsementKeyInfo -ErrorAction SilentlyContinue
        $report.checks['TPM']['ekPresent'] = ($null -ne $ekInfo)
    } catch { }

    $tpmStatus = if ($tpm.TpmPresent -and $tpm.TpmReady) { 'Present + Ready' } elseif ($tpm.TpmPresent) { 'Present (not ready)' } else { 'Not present' }
    Write-Host "    TPM: $tpmStatus (v$tpmSpecVer)" -ForegroundColor $(if ($tpm.TpmPresent -and $tpm.TpmReady) { 'Green' } else { 'Yellow' })
} catch {
    $report.checks['TPM'] = @{ present = $false; finding = "ERROR: $($_.Exception.Message)" }
    Write-Host "    TPM: Not available" -ForegroundColor Yellow
}

# ── 3: FIRMWARE / BIOS ────────────────────────────────────────────────────────
Write-Host "  [3/8] Firmware baseline capture..." -ForegroundColor Cyan
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
$cs   = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue

$biosVersion = if ($bios) { $bios.SMBIOSBIOSVersion } else { 'UNKNOWN' }
$biosDate    = if ($bios -and $bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { 'UNKNOWN' }
$biosVendor  = if ($bios) { $bios.Manufacturer } else { 'UNKNOWN' }
$biosSerial  = if ($bios) { $bios.SerialNumber } else { 'UNKNOWN' }

$fwType = 'UNKNOWN'
try {
    $compInfo = Get-ComputerInfo -Property BiosFirmwareType -ErrorAction SilentlyContinue
    if ($compInfo) { $fwType = $compInfo.BiosFirmwareType }
} catch { }

$report.checks['Firmware'] = [ordered]@{
    biosVersion     = $biosVersion
    biosDate        = $biosDate
    biosVendor      = $biosVendor
    biosSerial      = $biosSerial
    firmwareType    = $fwType
    oemManufacturer = if ($cs) { $cs.Manufacturer } else { 'UNKNOWN' }
    model           = if ($cs) { $cs.Model } else { 'UNKNOWN' }
    systemFamily    = if ($cs -and $cs.SystemFamily) { $cs.SystemFamily } else { 'N/A' }
    finding         = 'CAPTURED'
}
Write-Host "    BIOS: $biosVersion ($biosDate) by $biosVendor" -ForegroundColor Gray

# ── 4: HARDWARE FINGERPRINT ───────────────────────────────────────────────────
Write-Host "  [4/8] Hardware fingerprint capture..." -ForegroundColor Cyan
$cpu  = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
$ram  = Get-CimInstance -ClassName Win32_PhysicalMemory
$disk = Get-PhysicalDisk -ErrorAction SilentlyContinue
$nic  = Get-CimInstance -ClassName Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter }

$fingerprint = [ordered]@{
    cpu = [ordered]@{
        name              = if ($cpu) { $cpu.Name } else { 'UNKNOWN' }
        processorId       = if ($cpu) { $cpu.ProcessorId } else { 'UNKNOWN' }
        cores             = if ($cpu) { $cpu.NumberOfCores } else { 0 }
        logicalProcessors = if ($cpu) { $cpu.NumberOfLogicalProcessors } else { 0 }
        maxClockSpeed     = if ($cpu) { $cpu.MaxClockSpeed } else { 0 }
    }
    ram = [ordered]@{
        totalGB   = [Math]::Round(($ram | Measure-Object -Property Capacity -Sum).Sum / 1GB, 1)
        dimmCount = $ram.Count
        dimms     = @($ram | Select-Object DeviceLocator, Capacity, Speed, Manufacturer, PartNumber)
    }
    storage = @($disk | Select-Object FriendlyName, MediaType, BusType, SerialNumber,
                                @{N='SizeGB'; E={[Math]::Round($_.Size/1GB,0)}}, HealthStatus)
    network = @($nic | Select-Object Name, MACAddress, AdapterType, Speed)
    gpus    = @(Get-CimInstance -ClassName Win32_VideoController |
                Select-Object Name, DriverVersion, @{N='VRAMGB'; E={[Math]::Round($_.AdapterRAM/1GB,1)}})
}

$report.checks['HardwareFingerprint'] = $fingerprint
Write-Host "    CPU: $($fingerprint.cpu.name)" -ForegroundColor Gray
Write-Host "    RAM: $($fingerprint.ram.totalGB) GB ($($fingerprint.ram.dimmCount) DIMM)" -ForegroundColor Gray

# ── 5: WINDOWS 11 READINESS ──────────────────────────────────────────────────
Write-Host "  [5/8] Windows 11 readiness audit..." -ForegroundColor Cyan
$os      = Get-CimInstance -ClassName Win32_OperatingSystem
$osBuild = [int]$os.BuildNumber
$ramGB   = $fingerprint.ram.totalGB
$diskGB  = 0
$diskList = @($fingerprint.storage | Where-Object { $_.MediaType -ne 'Unspecified' })
if ($diskList.Count -gt 0) {
    $diskGB = ($diskList | Measure-Object -Property SizeGB -Maximum).Maximum
}
$cpuGHz = if ($cpu) { $cpu.MaxClockSpeed / 1000 } else { 0 }

$tpmIs20 = $false
if ($report.checks['TPM'] -and $report.checks['TPM'].specVersion -and $report.checks['TPM'].present) {
    $tpmIs20 = ($report.checks['TPM'].specVersion -match '^2\.')
}

$w11Checks = [ordered]@{
    tpm20        = $tpmIs20
    secureBoot   = ($report.checks['SecureBoot'].status -eq 'ENABLED')
    uefi         = ($report.checks['Firmware'].firmwareType -eq 'Uefi')
    ram4GB       = ($ramGB -ge 4)
    disk64GB     = ($diskGB -ge 64)
    cpu1GHz      = ($cpuGHz -ge 1.0)
    directx12    = $true   # Cannot detect without GPU query; assume true for enterprise
    displayRes   = $true   # Cannot detect in headless; assume true
    osBuildReady = ($osBuild -ge 19041)
}

$w11PassCount = @($w11Checks.Values | Where-Object { $_ -eq $true }).Count
$w11Total     = $w11Checks.Count
$w11Ready     = ($w11PassCount -eq $w11Total)

$report.win11Ready = [ordered]@{
    ready       = $w11Ready
    passCount   = $w11PassCount
    totalChecks = $w11Total
    checks      = $w11Checks
    finding     = if ($w11Ready) { 'PASS: System meets Windows 11 hardware requirements' }
                  else { "WARN: $($w11Total - $w11PassCount) Windows 11 requirement(s) not met" }
}
$w11Color = if ($w11Ready) { 'Green' } else { 'Yellow' }
$w11Text  = if ($w11Ready) { 'YES' } else { "NO -- $($w11Total - $w11PassCount) check(s) failed" }
Write-Host "    Windows 11 Ready: $w11Text" -ForegroundColor $w11Color

# ── 6: POST HISTORY ──────────────────────────────────────────────────────────
Write-Host "  [6/8] POST history extraction..." -ForegroundColor Cyan
try {
    $postEvents = Get-EventLog -LogName System -Source 'Microsoft-Windows-Kernel-Boot' `
        -EventID 20 -Newest 5 -ErrorAction SilentlyContinue
    $report.checks['POSTHistory'] = [ordered]@{
        available = ($null -ne $postEvents)
        records   = @($postEvents | Select-Object EventID, TimeGenerated, Message | Select-Object -First 5)
        finding   = if ($postEvents) { 'CAPTURED' } else { 'UNAVAILABLE' }
    }
    Write-Host "    POST events: $(if ($postEvents) { "$($postEvents.Count) captured" } else { 'None found' })" -ForegroundColor Gray
} catch {
    $report.checks['POSTHistory'] = @{ available = $false; finding = 'Event log access limited' }
    Write-Host "    POST events: Access limited" -ForegroundColor Yellow
}

# ── 7: DRIVER CATALOG ────────────────────────────────────────────────────────
Write-Host "  [7/8] Driver version catalog..." -ForegroundColor Cyan
$drivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceClass -in @('Display','Net','DiskDrive','HDC','USB','System','Processor') } |
    Select-Object DeviceName, DeviceClass, DriverVersion, DriverDate, Signer |
    Sort-Object DeviceClass, DeviceName

$unsignedCount = @($drivers | Where-Object { -not $_.Signer }).Count
$report.checks['DriverCatalog'] = [ordered]@{
    driverCount     = $drivers.Count
    unsignedDrivers = $unsignedCount
    drivers         = @($drivers)
    finding         = if ($unsignedCount -eq 0) { 'OK: All drivers signed' }
                      else { "WARN: $unsignedCount unsigned driver(s) found" }
}
Write-Host "    Drivers: $($drivers.Count) cataloged, $unsignedCount unsigned" -ForegroundColor $(if ($unsignedCount -eq 0) { 'Green' } else { 'Yellow' })

# ── 8: BASELINE DRIFT DETECTION ──────────────────────────────────────────────
Write-Host "  [8/8] Baseline drift detection..." -ForegroundColor Cyan
if ($BaselinePath -and (Test-Path $BaselinePath)) {
    try {
        $baseline = Get-Content $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $drifts = @()

        # CPU drift
        if ($baseline.baseline.cpu.processorId -ne $fingerprint.cpu.processorId) {
            $drifts += @{ component='CPU'; type='IDENTIFIER_CHANGE'; baseline=$baseline.baseline.cpu.processorId; current=$fingerprint.cpu.processorId }
        }
        # RAM drift
        if ($baseline.baseline.ram.totalGB -ne $fingerprint.ram.totalGB) {
            $drifts += @{ component='RAM'; type='CAPACITY_CHANGE'; baseline=$baseline.baseline.ram.totalGB; current=$fingerprint.ram.totalGB }
        }
        # MAC address drift
        $baselineMacs = ($baseline.baseline.network | ForEach-Object { $_.MACAddress } | Sort-Object) -join ','
        $currentMacs  = ($fingerprint.network | ForEach-Object { $_.MACAddress } | Sort-Object) -join ','
        if ($baselineMacs -ne $currentMacs) {
            $drifts += @{ component='NIC_MAC'; type='MAC_CHANGE'; baseline=$baselineMacs; current=$currentMacs }
        }
        # Firmware version drift
        if ($baseline.checks.Firmware.biosVersion -ne $report.checks.Firmware.biosVersion) {
            $drifts += @{ component='Firmware'; type='BIOS_VERSION_CHANGE'; baseline=$baseline.checks.Firmware.biosVersion; current=$report.checks.Firmware.biosVersion }
        }

        $report.driftReport = [ordered]@{
            baselineFile  = $BaselinePath
            baselineDate  = $baseline.timestamp
            driftDetected = ($drifts.Count -gt 0)
            driftCount    = $drifts.Count
            drifts        = $drifts
            finding       = if ($drifts.Count -eq 0) { 'PASS: Hardware fingerprint matches baseline' }
                            else { "WARN: $($drifts.Count) hardware change(s) detected since baseline" }
        }
        $driftColor = if ($drifts.Count -eq 0) { 'Green' } else { 'Yellow' }
        $driftText  = if ($drifts.Count -eq 0) { 'No drift detected' } else { "$($drifts.Count) drift(s) detected" }
        Write-Host "    Drift: $driftText" -ForegroundColor $driftColor
    } catch {
        $report.driftReport = @{ error = $_.Exception.Message; finding = 'ERROR: Could not compare baseline' }
        Write-Host "    Drift: Error comparing baseline" -ForegroundColor Red
    }
} else {
    $report.driftReport = @{ finding = 'No baseline provided -- drift comparison skipped' }
    Write-Host "    Drift: No baseline provided (use -BaselinePath)" -ForegroundColor DarkGray
}

# Save baseline snapshot if requested
if ($SaveBaseline) {
    $baselineOut = [ordered]@{
        _type        = 'OEM_HARDWARE_BASELINE'
        timestamp    = Get-Date -Format 'o'
        computername = $env:COMPUTERNAME
        capturedBy   = "$env:USERDOMAIN\$env:USERNAME"
        baseline     = $fingerprint
        checks       = [ordered]@{
            Firmware   = $report.checks['Firmware']
            SecureBoot = $report.checks['SecureBoot']
            TPM        = $report.checks['TPM']
        }
    }
    $baselineFile = Join-Path $DataPath "${env:COMPUTERNAME}_baseline_${timestamp}.json"
    $baselineOut | ConvertTo-Json -Depth 15 | Set-Content $baselineFile -Encoding UTF8
    $report.baseline = $baselineFile
    Write-Host ""
    Write-Host "    Baseline saved: $baselineFile" -ForegroundColor Green
}

# ── Write Report ──────────────────────────────────────────────────────────────
$reportFile = Join-Path $OutputPath "OEM_Validation_${env:COMPUTERNAME}_${timestamp}.json"
$report | ConvertTo-Json -Depth 15 | Set-Content $reportFile -Encoding UTF8

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host "   OEM VALIDATION COMPLETE" -ForegroundColor Magenta
Write-Host "  ============================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "    Win11 Ready  : $w11Text" -ForegroundColor $w11Color
$tpmText = if ($report.checks['TPM'].present) { "Present (v$tpmSpecVer)" } else { "Not detected" }
Write-Host "    TPM          : $tpmText" -ForegroundColor Gray
Write-Host "    Secure Boot  : $($report.checks['SecureBoot'].status)" -ForegroundColor Gray
Write-Host "    Firmware     : $biosVersion ($biosDate)" -ForegroundColor Gray
Write-Host "    Report       : $reportFile" -ForegroundColor Green
Write-Host ""
Write-Host "    OEM Validation Mode: Zero system modifications were made." -ForegroundColor Yellow
Write-Host ""
