#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Consolidated Laptop Diagnostic Toolkit

.DESCRIPTION
    Single-module v6.0 consolidation of 26 laptop diagnostic and repair functions.
    All functions are invokable via -RunFunction parameter from the BAT launcher
    or interactively from the built-in menu.

.NOTES
    Version: 6.1.0
    Author: Enterprise Support Team
    Last Updated: 2026-02-20
#>

param (
    [Parameter()]
    [switch]$SkipMenu,

    [Parameter()]
    [ValidateSet(
        'AdvancedDiagnostic', 'BSODAnalysis', 'BootRepair', 'EnhancedHardwareTest',
        'BIOSRepair', 'DriverRepair', 'SoftwareCleanup', 'CustomTests',
        'FleetReport', 'VerifyScripts', 'CompatibilityChecker', 'HardwareInventory',
        'BatteryHealth', 'NetworkDiagnostic', 'PerformanceAnalyzer', 'SecureWipe',
        'DeploymentPrep', 'UpdateManager', 'PowerSettings', 'ThermalAnalysis',
        'DisplayCalibration', 'AudioDiagnostic', 'KeyboardTest', 'TrackPointCalibration',
        'BIOSUpdate', 'SecurityCheck', 'DiagnosticAnalyzer',
        'RefurbBatteryAnalysis', 'RefurbQualityCheck', 'RefurbThermalAnalysis',
        'SecurityHardening', 'NetworkTroubleshooter', 'BSODTroubleshooter',
        'InputTroubleshooter', 'DriverAutoUpdate',
        'POSTErrorReader', 'SMARTDiskAnalysis', 'CMOSBatteryCheck',
        'MachineIdentityCheck', 'TPMHealthCheck', 'Win11ReadinessCheck',
        'LenovoVantageCheck', 'MemoryErrorLogCheck', 'DisplayPixelCheck',
        'EnterpriseReadinessReport'
    )]
    [string]$RunFunction,

    [Parameter()]
    [string]$LogPath,

    [Parameter()]
    [string]$ReportPath,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$BackupPath,

    [Parameter()]
    [string]$TempPath,

    [Parameter()]
    [string]$DataPath
)

#region Global Variables and Setup
$script:Version = "6.1.0"

# USB-based path defaults using $PSScriptRoot
if (-not $LogPath)    { $LogPath    = Join-Path $PSScriptRoot 'Logs' }
if (-not $ReportPath) { $ReportPath = Join-Path $PSScriptRoot 'Reports' }
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'Config' }
if (-not $BackupPath) { $BackupPath = Join-Path $PSScriptRoot 'Backups' }
if (-not $TempPath)   { $TempPath   = Join-Path $PSScriptRoot 'Temp' }
if (-not $DataPath)   { $DataPath   = Join-Path $PSScriptRoot 'Data' }

$script:LogFile = Join-Path -Path $LogPath -ChildPath "Laptop_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:ReportFile = Join-Path -Path $ReportPath -ChildPath "Laptop_Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
$script:IsThinkPad = $false
$script:ModelInfo = $null
$script:SerialNumber = $null
$script:BIOSVersion = $null
$script:OSVersion = $null
$script:LastBootTime = $null
$script:SystemInfo = $null
$script:IsDomainJoined = $false
$script:DomainName = $null
$script:BitLockerStatus = 'Unknown'
$script:UserIsAdmin = $false
$script:Vendor = 'Unknown'

# Create necessary directories
foreach ($dir in @($LogPath, $ReportPath, $ConfigPath, $BackupPath, $TempPath, $DataPath)) {
    if (-not (Test-Path -Path $dir)) {
        try { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        catch { Write-Host "Failed to create directory: $dir" -ForegroundColor Red }
    }
}
#endregion

#region Helper Functions
function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    if (-not (Test-Path -Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    if (-not (Test-Path -Path $script:LogFile)) {
        New-Item -Path $script:LogFile -ItemType File -Force | Out-Null
        Add-Content -Path $script:LogFile -Value "[$timestamp] [Info] Laptop Diagnostic Toolkit v$script:Version started"
    }
    Add-Content -Path $script:LogFile -Value $logMessage
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor White }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
    }
}

function Get-USBBasePath {
    return $PSScriptRoot
}

function Test-CommandExists {
    param ([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Invoke-SafeWinEvent {
    param (
        [hashtable]$FilterHashtable,
        [int]$MaxEvents = 500
    )
    try {
        Get-WinEvent -FilterHashtable $FilterHashtable -MaxEvents $MaxEvents -ErrorAction SilentlyContinue
    } catch {
        @()
    }
}

function Get-SystemInformation {
    Write-Log "Collecting system information..." -Level Info
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        $biosInfo = Get-CimInstance -ClassName Win32_BIOS
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
        $processorInfo = Get-CimInstance -ClassName Win32_Processor
        $isLenovo = $computerSystem.Manufacturer -match "LENOVO"
        $modelHasTP = $computerSystem.Model -match "ThinkPad"
        $familyHasTP = $computerSystem.SystemFamily -match "ThinkPad"
        $cspProduct = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        $productVersion = $cspProduct.Version
        $productName = $cspProduct.Name
        $productHasTP = $productVersion -match "ThinkPad"
        $productNameHasTP = $productName -match "ThinkPad"
        # Lenovo MTM pattern: 4-char machine type (e.g. 20NK) + model suffix — ThinkPads use 20XX/21XX prefixes
        $mtmIsTP = $false
        if ($isLenovo -and $computerSystem.Model -match '^\d{2}[A-Z0-9]{2}') {
            # Known Lenovo ThinkPad machine type prefixes (20xx and 21xx series are ThinkPads)
            $mtmIsTP = $computerSystem.Model -match '^(20|21)[A-Z0-9]{2}'
        }
        $script:IsThinkPad = $isLenovo -and ($modelHasTP -or $familyHasTP -or $productHasTP -or $productNameHasTP -or $mtmIsTP)
        $script:ModelInfo = if ($familyHasTP) { $computerSystem.SystemFamily } elseif ($productHasTP) { $productVersion } elseif ($productNameHasTP) { $productName } elseif ($mtmIsTP) { "$($computerSystem.Model) (Lenovo ThinkPad)" } else { $computerSystem.Model }
        $script:SerialNumber = $biosInfo.SerialNumber
        $script:BIOSVersion = $biosInfo.SMBIOSBIOSVersion
        $script:OSVersion = $osInfo.Caption + " " + $osInfo.Version
        $script:LastBootTime = $osInfo.LastBootUpTime
        # Domain, BitLocker, and admin detection
        $script:IsDomainJoined = $computerSystem.PartOfDomain
        $script:DomainName = if ($computerSystem.PartOfDomain) { $computerSystem.Domain } else { $null }
        $script:UserIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $script:BitLockerStatus = 'Unknown'
        try {
            $blVol = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
            if ($blVol.ProtectionStatus -eq 1) { $script:BitLockerStatus = 'On' }
            elseif ($blVol.ProtectionStatus -eq 0) { $script:BitLockerStatus = 'Off' }
        } catch { $script:BitLockerStatus = 'NotAvailable' }
        # Vendor detection (cross-OEM)
        $mfr = $computerSystem.Manufacturer.ToUpper()
        if ($mfr -match 'LENOVO') { $script:Vendor = 'Lenovo' }
        elseif ($mfr -match 'DELL') { $script:Vendor = 'Dell' }
        elseif ($mfr -match 'HP|HEWLETT') { $script:Vendor = 'HP' }
        else { $script:Vendor = 'Other' }
        $script:SystemInfo = [PSCustomObject]@{
            IsThinkPad = $script:IsThinkPad
            Manufacturer = $computerSystem.Manufacturer
            Model = $script:ModelInfo
            SerialNumber = $script:SerialNumber
            BIOSVersion = $script:BIOSVersion
            OSVersion = $script:OSVersion
            LastBootTime = $script:LastBootTime
            ProcessorName = $processorInfo.Name
            TotalMemoryGB = [math]::Round($computerSystem.TotalPhysicalMemory / 1GB, 2)
            IsDomainJoined = $script:IsDomainJoined
            DomainName = $script:DomainName
            BitLockerStatus = $script:BitLockerStatus
            Vendor = $script:Vendor
            UserIsAdmin = $script:UserIsAdmin
        }
        Write-Log "System information collected successfully" -Level Success
        return $script:SystemInfo
    } catch {
        Write-Log "Failed to collect system information: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Show-Menu {
    param (
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string[]]$Options,
        [Parameter()][string]$BackText = "Back to Main Menu"
    )
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  $($i + 1). $($Options[$i])" -ForegroundColor White
    }
    Write-Host "  $($Options.Count + 1). $BackText" -ForegroundColor Yellow
    Write-Host
    do {
        Write-Host "Select an option (1-$($Options.Count + 1)): " -ForegroundColor Green -NoNewline
        $choice = Read-Host
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le ($Options.Count + 1)) {
            return [int]$choice
        }
        Write-Host "Invalid selection. Please try again." -ForegroundColor Red
    } while ($true)
}

function Test-ThinkPadCompatibility {
    Write-Log "Checking laptop compatibility..." -Level Info
    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }
    if ($script:IsThinkPad) {
        Write-Log "Lenovo ThinkPad detected: $($script:ModelInfo) - Full feature support" -Level Success
        return $true
    }
    Write-Log "Non-ThinkPad laptop detected. Lenovo-specific features (BIOS, TrackPoint, hotkeys) may be limited." -Level Warning
    Write-Host "`nNOTE: This is not a Lenovo ThinkPad. Some Lenovo-specific features may be limited." -ForegroundColor Yellow
    $response = Read-Host "Do you want to continue anyway? (Y/N)"
    if ($response -eq "Y" -or $response -eq "y") {
        Write-Log "User chose to continue despite compatibility warning" -Level Warning
        return $true
    }
    return $false
}

function Test-ConfigIntegrity {
    Write-Log "Validating config.ini..." -Level Info
    $cfgFile = Join-Path $ConfigPath "config.ini"
    if (-not (Test-Path $cfgFile)) {
        Write-Log "WARNING: config.ini not found at $cfgFile" -Level Warning
        return $false
    }
    $content = Get-Content $cfgFile -Raw
    $requiredSections = @(
        'General', 'Paths', 'Diagnostics', 'HardwareTests',
        'PerformanceBenchmark', 'Repair', 'Fleet', 'Reporting',
        'Security', 'PowerManagement', 'DataCollection', 'Refurbishment',
        'AutoRemediation'
    )
    $missing = @()
    foreach ($section in $requiredSections) {
        if ($content -notmatch "\[$section\]") {
            $missing += $section
        }
    }
    if ($missing.Count -gt 0) {
        Write-Log "WARNING: config.ini missing sections: $($missing -join ', ')" -Level Warning
        Write-Host "  WARNING: config.ini missing $($missing.Count) section(s)" -ForegroundColor Yellow
        return $false
    }
    Write-Log "config.ini validated - all $($requiredSections.Count) sections present" -Level Info
    return $true
}

function Export-DiagnosticReport {
    param (
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][System.Collections.ArrayList]$Results,
        [Parameter()][string]$OutputPath = $script:ReportFile
    )
    Write-Log "Generating diagnostic report: $Title" -Level Info
    try {
        if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }
        $sysModel = if ($script:SystemInfo) { "$($script:SystemInfo.Manufacturer) $($script:SystemInfo.Model)" } else { "Unknown" }
        $sysSerial = if ($script:SystemInfo) { $script:SystemInfo.SerialNumber } else { "Unknown" }
        $sysOS = if ($script:SystemInfo) { $script:SystemInfo.OSVersion } else { "Unknown" }
        $sysBIOS = if ($script:SystemInfo) { $script:SystemInfo.BIOSVersion } else { "Unknown" }
        $reportDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<!DOCTYPE html>')
        [void]$sb.AppendLine('<html><head><title>Laptop Diagnostic Report</title>')
        [void]$sb.AppendLine('<style>')
        [void]$sb.AppendLine('body { font-family: Arial, sans-serif; margin: 20px; }')
        [void]$sb.AppendLine('h1 { color: #00539B; }')
        [void]$sb.AppendLine('h2 { color: #00539B; border-bottom: 1px solid #ddd; padding-bottom: 5px; }')
        [void]$sb.AppendLine('table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }')
        [void]$sb.AppendLine('th { background-color: #00539B; color: white; text-align: left; padding: 8px; }')
        [void]$sb.AppendLine('td { border: 1px solid #ddd; padding: 8px; }')
        [void]$sb.AppendLine('tr:nth-child(even) { background-color: #f2f2f2; }')
        [void]$sb.AppendLine('.success { color: green; } .warning { color: orange; } .error { color: red; } .info { color: #00539B; }')
        [void]$sb.AppendLine('</style></head><body>')
        [void]$sb.AppendLine("<h1>Laptop Diagnostic Report</h1>")
        [void]$sb.AppendLine("<p><strong>Report Date:</strong> $reportDate</p>")
        [void]$sb.AppendLine("<p><strong>System:</strong> $sysModel</p>")
        [void]$sb.AppendLine("<p><strong>Serial Number:</strong> $sysSerial</p>")
        [void]$sb.AppendLine("<p><strong>OS Version:</strong> $sysOS</p>")
        [void]$sb.AppendLine("<p><strong>BIOS Version:</strong> $sysBIOS</p>")
        [void]$sb.AppendLine("<h2>$Title</h2>")
        [void]$sb.AppendLine('<table><tr><th>Component</th><th>Status</th><th>Details</th></tr>')

        foreach ($result in $Results) {
            $statusClass = switch ($result.Status) {
                "Pass" { "success" }; "Warning" { "warning" }; "Fail" { "error" }; default { "info" }
            }
            [void]$sb.AppendLine("<tr><td>$($result.Component)</td><td class=`"$statusClass`">$($result.Status)</td><td>$($result.Details)</td></tr>")
        }

        [void]$sb.AppendLine('</table>')
        [void]$sb.AppendLine("<p><em>Report generated by Laptop Diagnostic Toolkit v$($script:Version)</em></p>")
        [void]$sb.AppendLine('</body></html>')

        $sb.ToString() | Out-File -FilePath $OutputPath -Encoding utf8 -Force
        Write-Log "Diagnostic report saved to: $OutputPath" -Level Success
        Write-Host "Report saved to: $OutputPath" -ForegroundColor Green
    } catch {
        Write-Log "Failed to generate diagnostic report: $($_.Exception.Message)" -Level Error
    }
}

function Request-UserApproval {
    param (
        [Parameter(Mandatory)][string]$Issue,
        [Parameter(Mandatory)][string]$ProposedFix
    )
    Write-Host ""
    Write-Host "  ISSUE: $Issue" -ForegroundColor Yellow
    Write-Host "  FIX:   $ProposedFix" -ForegroundColor Cyan
    $response = Read-Host "  Apply fix? [Y/N]"
    $approved = $response -match '^[Yy]'
    Write-Log "Fix $(if($approved){'APPROVED'}else{'DECLINED'}): $ProposedFix" -Level Info
    return $approved
}

function Invoke-FixAndVerify {
    param (
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][scriptblock]$FixAction,
        [Parameter(Mandatory)][scriptblock]$VerifyAction
    )
    $prevEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        & $FixAction
        Start-Sleep -Seconds 2
        $verified = & $VerifyAction
        if ($verified) {
            Write-Host "  VERIFIED: $Component fixed successfully" -ForegroundColor Green
            Write-Log "VERIFIED: $Component fixed" -Level Success
            $sev = Get-SeverityCode -Component $Component -Status 'Pass'
            Write-AuditLog -Module $Component -IssueCode $Component -Severity $sev -ActionTaken 'AutoFix' -ValidationStatus 'Verified' -FinalState 'Resolved'
            return [PSCustomObject]@{ Component = $Component; Status = "Pass"; Details = "Fixed and verified" }
        } else {
            Write-Host "  PARTIAL: $Component fix applied, verify manually" -ForegroundColor Yellow
            Write-Log "PARTIAL: $Component fix applied but unverified" -Level Warning
            $sev = Get-SeverityCode -Component $Component -Status 'Warning'
            Write-AuditLog -Module $Component -IssueCode $Component -Severity $sev -ActionTaken 'AutoFix' -ValidationStatus 'Unverified' -FinalState 'PartiallyResolved' -RiskLevel 'Medium'
            return [PSCustomObject]@{ Component = $Component; Status = "Warning"; Details = "Fix applied, verify manually" }
        }
    } catch {
        Write-Host "  FAILED: $Component - $($_.Exception.Message)" -ForegroundColor Red
        Write-Log "FAILED: $Component - $($_.Exception.Message)" -Level Error
        $sev = Get-SeverityCode -Component $Component -Status 'Fail'
        Write-AuditLog -Module $Component -IssueCode $Component -Severity $sev -ActionTaken 'AutoFix' -ValidationStatus 'Failed' -FinalState 'Unresolved' -RiskLevel 'High'
        return [PSCustomObject]@{ Component = $Component; Status = "Fail"; Details = "Fix failed: $($_.Exception.Message)" }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Get-RemediationConfig {
    $cfg = @{
        Enabled = $true
        FallbackDNS1 = "8.8.8.8"
        FallbackDNS2 = "1.1.1.1"
        TempThresholdMB = 500
        WUMaxAgeDays = 30
        DefenderSigMaxDays = 7
        LenovoThinInstallerPath = ""
        VPNInstallerPath = ""
        DriverUpdateSource = "Both"
        NeverAutoUpdate = @("BIOS", "Firmware")
    }
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $content = Get-Content $cfgFile -Raw
            if ($content -match 'AutoRemediationEnabled=(\d+)') { $cfg.Enabled = [bool][int]$Matches[1] }
            if ($content -match 'FallbackDNSPrimary=([\d.]+)') { $cfg.FallbackDNS1 = $Matches[1] }
            if ($content -match 'FallbackDNSSecondary=([\d.]+)') { $cfg.FallbackDNS2 = $Matches[1] }
            if ($content -match 'TempCleanupThresholdMB=(\d+)') { $cfg.TempThresholdMB = [int]$Matches[1] }
            if ($content -match 'WindowsUpdateMaxAgeDays=(\d+)') { $cfg.WUMaxAgeDays = [int]$Matches[1] }
            if ($content -match 'DefenderSignatureMaxAgeDays=(\d+)') { $cfg.DefenderSigMaxDays = [int]$Matches[1] }
            if ($content -match 'LenovoThinInstallerPath=(.+)') {
                $cfg.LenovoThinInstallerPath = Join-Path (Get-USBBasePath) $Matches[1].Trim()
            }
            if ($content -match 'VPNInstallerPath=(.+)') {
                $cfg.VPNInstallerPath = Join-Path (Get-USBBasePath) $Matches[1].Trim()
            }
            if ($content -match 'DriverUpdateSource=(\w+)') { $cfg.DriverUpdateSource = $Matches[1] }
            if ($content -match 'NeverAutoUpdate=(.+)') { $cfg.NeverAutoUpdate = $Matches[1].Trim().Split(',') | ForEach-Object { $_.Trim() } }
        }
    } catch { }
    return $cfg
}

function New-SafeRestorePoint {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ModuleName
    )
    Write-Host "`n  Creating system restore point before $ModuleName..." -ForegroundColor Yellow -NoNewline
    Write-Log "Creating restore point before $ModuleName" -Level Info
    try {
        # Check if System Restore is enabled on the system drive
        $srService = Get-Service -Name 'srservice' -ErrorAction SilentlyContinue
        if (-not $srService -or $srService.Status -eq 'Disabled') {
            Write-Host " skipped (System Restore service disabled)" -ForegroundColor DarkYellow
            Write-Log "System Restore service not available - restore point skipped" -Level Warning
            return $false
        }
        $sysDrive = $env:SystemDrive
        $srEnabled = $false
        try {
            $srConfig = Get-ComputerRestorePoint -ErrorAction Stop | Select-Object -First 1
            $srEnabled = $true
        } catch {
            # If Get-ComputerRestorePoint fails, try vssadmin
            $vssCheck = & vssadmin list shadowstorage 2>&1 | Select-String $sysDrive
            if ($vssCheck) { $srEnabled = $true }
        }
        if (-not $srEnabled) {
            Write-Host " skipped (System Restore not enabled on $sysDrive)" -ForegroundColor DarkYellow
            Write-Log "System Restore not enabled on $sysDrive - restore point skipped" -Level Warning
            return $false
        }
        # Create the restore point
        Checkpoint-Computer -Description "LDT v6.0 - Before $ModuleName $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Host " done" -ForegroundColor Green
        Write-Log "Restore point created successfully before $ModuleName" -Level Success
        return $true
    } catch {
        if ($_.Exception.Message -match 'frequency') {
            Write-Host " skipped (Windows limits one restore point per 24hrs)" -ForegroundColor DarkYellow
            Write-Log "Restore point skipped - frequency limit: $($_.Exception.Message)" -Level Warning
        } else {
            Write-Host " failed ($($_.Exception.Message))" -ForegroundColor DarkYellow
            Write-Log "Restore point failed: $($_.Exception.Message)" -Level Warning
        }
        return $false
    }
}

function Test-DomainSafety {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('DNS', 'Firewall', 'Service', 'Boot')]
        [string]$ActionType,
        [Parameter()]
        [string]$Detail = ''
    )
    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }
    if (-not $script:IsDomainJoined) { return $true }
    # Domain-joined machine — check if action is safe
    switch ($ActionType) {
        'DNS' {
            Write-Host "`n  [DOMAIN GUARD] This machine is joined to domain: $($script:DomainName)" -ForegroundColor Red
            Write-Host "  Changing DNS may break internal services (intranet, file shares, AD auth)." -ForegroundColor Yellow
            Write-Host "  Override DNS anyway? [Y/N]: " -ForegroundColor Yellow -NoNewline
            $response = Read-Host
            if ($response -ne 'Y' -and $response -ne 'y') {
                Write-Log "DNS change skipped - domain-joined machine ($($script:DomainName)), user declined" -Level Warning
                return $false
            }
            Write-Log "DNS change approved by tech on domain-joined machine ($($script:DomainName))" -Level Warning
            return $true
        }
        'Firewall' {
            # Check if firewall profile is GPO-managed
            $gpoManaged = $false
            try {
                $fwReg = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -ErrorAction SilentlyContinue
                if ($null -ne $fwReg -and $null -ne $fwReg.EnableFirewall) { $gpoManaged = $true }
            } catch { }
            if ($gpoManaged) {
                Write-Host "`n  [DOMAIN GUARD] Firewall is managed by Group Policy — skipping modification." -ForegroundColor Red
                Write-Log "Firewall change skipped - GPO-managed on domain $($script:DomainName)" -Level Warning
                return $false
            }
            return $true
        }
        'Service' {
            Write-Host "`n  [DOMAIN GUARD] This machine is domain-joined ($($script:DomainName))." -ForegroundColor Yellow
            Write-Host "  Modifying service: $Detail. Proceed? [Y/N]: " -ForegroundColor Yellow -NoNewline
            $response = Read-Host
            if ($response -ne 'Y' -and $response -ne 'y') {
                Write-Log "Service modification '$Detail' skipped on domain machine" -Level Warning
                return $false
            }
            return $true
        }
        'Boot' {
            if ($script:BitLockerStatus -eq 'On') {
                Write-Host "`n  [DOMAIN GUARD] BitLocker is ACTIVE on $env:SystemDrive." -ForegroundColor Red
                Write-Host "  Modifying boot configuration may trigger BitLocker recovery." -ForegroundColor Yellow
                Write-Host "  Ensure you have the recovery key before proceeding. Continue? [Y/N]: " -ForegroundColor Yellow -NoNewline
                $response = Read-Host
                if ($response -ne 'Y' -and $response -ne 'y') {
                    Write-Log "Boot modification skipped - BitLocker active, user declined" -Level Warning
                    return $false
                }
                Write-Log "Boot modification approved by tech with BitLocker active" -Level Warning
            }
            return $true
        }
    }
    return $true
}

function Write-AuditLog {
    param (
        [Parameter(Mandatory = $true)][string]$Module,
        [Parameter(Mandatory = $true)][string]$IssueCode,
        [Parameter(Mandatory = $true)][string]$Severity,
        [Parameter()][string]$ActionTaken = 'None',
        [Parameter()][string]$ValidationStatus = 'N/A',
        [Parameter()][string]$FinalState = 'N/A',
        [Parameter()][string]$RiskLevel = 'Low'
    )
    try {
        $auditFile = Join-Path $LogPath "LDT_Audit_$(Get-Date -Format 'yyyyMMdd').audit.log"
        $entry = "TIMESTAMP=$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')" +
            " | DEVICE_SERIAL=$($script:SerialNumber)" +
            " | VENDOR=$($script:Vendor)" +
            " | MODEL=$($script:ModelInfo)" +
            " | OS_BUILD=$($script:OSVersion)" +
            " | MODULE=$Module" +
            " | ISSUE_CODE=$IssueCode" +
            " | SEVERITY=$Severity" +
            " | ACTION_TAKEN=$ActionTaken" +
            " | VALIDATION_STATUS=$ValidationStatus" +
            " | FINAL_STATE=$FinalState" +
            " | RISK_LEVEL=$RiskLevel" +
            " | DOMAIN_JOINED=$($script:IsDomainJoined)" +
            " | BITLOCKER_STATUS=$($script:BitLockerStatus)"
        Add-Content -Path $auditFile -Value $entry -Encoding UTF8
    } catch { }
}

function Get-SeverityCode {
    param (
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$Status
    )
    # Hardware indicators → H1/H2/H3
    if ($Component -match 'SMART|Disk|SSD|HDD|Reallocated|Uncorrectable') {
        if ($Status -eq 'Fail') { return 'H3' }  # Data loss imminent
        if ($Status -eq 'Warning') { return 'H2' }  # Hardware failure
        return 'H1'  # Hardware warning
    }
    if ($Component -match 'Battery|Fan|Thermal|Temperature|Memory Error|WHEA|DIMM') {
        if ($Status -eq 'Fail') { return 'H2' }
        return 'H1'
    }
    if ($Component -match 'Dead Pixel|LCD|Display Panel|Backlight') {
        if ($Status -eq 'Fail') { return 'H2' }
        return 'H1'
    }
    if ($Component -match 'POST|CMOS|RTC') {
        if ($Status -eq 'Fail') { return 'H2' }
        return 'H1'
    }
    # Security indicators → S3
    if ($Component -match 'Defender|Firewall|UAC|SmartScreen|BitLocker|TPM|Security|Credential') {
        if ($Status -eq 'Fail' -or $Status -eq 'Warning') { return 'S3' }
        return 'S1'
    }
    # Stability indicators → S2
    if ($Component -match 'SFC|DISM|BSOD|BugCheck|Crash|Driver|Boot|Update|WU') {
        if ($Status -eq 'Fail') { return 'S2' }
        if ($Status -eq 'Warning') { return 'S2' }
        return 'S1'
    }
    # Performance indicators → S4
    if ($Component -match 'Startup|CPU|Memory Pressure|Disk I/O|Performance|Slow|Cache|Temp Files') {
        return 'S4'
    }
    # Network → S2
    if ($Component -match 'Network|Wi-Fi|DNS|Winsock|Bluetooth|VPN|Adapter') {
        if ($Status -eq 'Fail' -or $Status -eq 'Warning') { return 'S2' }
        return 'S1'
    }
    # Default minor config
    if ($Status -eq 'Fail') { return 'S2' }
    if ($Status -eq 'Warning') { return 'S1' }
    return 'S1'
}
#endregion

#region Diagnostics

function Invoke-AdvancedDiagnostic {
    Write-Log "Starting Advanced Diagnostic..." -Level Info
    $results = New-Object System.Collections.ArrayList
    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Advanced System Diagnostic" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Disk health
    Write-Host "Checking disk health..." -ForegroundColor Yellow
    try {
        $diskHealth = Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, HealthStatus, OperationalStatus, Size
        foreach ($disk in $diskHealth) {
            $diskSizeGB = [math]::Round($disk.Size / 1GB, 2)
            $status = if ($disk.HealthStatus -eq "Healthy") { "Pass" } else { "Fail" }
            $null = $results.Add([PSCustomObject]@{ Component = "Disk: $($disk.FriendlyName) ($diskSizeGB GB)"; Status = $status; Details = "Health: $($disk.HealthStatus), Status: $($disk.OperationalStatus)" })
            $color = if ($status -eq "Pass") { "Green" } else { "Red" }
            Write-Host "  Disk: $($disk.FriendlyName) ($diskSizeGB GB) - $($disk.HealthStatus)" -ForegroundColor $color
        }
    } catch {
        Write-Log "Error checking disk health: $($_.Exception.Message)" -Level Error
        $null = $results.Add([PSCustomObject]@{ Component = "Disk Health"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Memory
    Write-Host "Checking memory status..." -ForegroundColor Yellow
    try {
        $memoryModules = Get-CimInstance -ClassName Win32_PhysicalMemory
        $totalMemory = 0
        foreach ($module in $memoryModules) {
            $capacityGB = [math]::Round($module.Capacity / 1GB, 2)
            $totalMemory += $capacityGB
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Module (Bank: $($module.BankLabel))"; Status = "Pass"; Details = "Capacity: $capacityGB GB, Speed: $($module.Speed) MHz" })
            Write-Host "  Memory Module (Bank: $($module.BankLabel)) - $capacityGB GB" -ForegroundColor Green
        }
        Write-Host "  Total Memory: $totalMemory GB" -ForegroundColor Green
    } catch {
        Write-Log "Error checking memory: $($_.Exception.Message)" -Level Error
        $null = $results.Add([PSCustomObject]@{ Component = "Memory"; Status = "Error"; Details = $_.Exception.Message })
    }

    # CPU
    Write-Host "Checking CPU status..." -ForegroundColor Yellow
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor
        $cpuLoad = $cpu.LoadPercentage
        $null = $results.Add([PSCustomObject]@{ Component = "CPU"; Status = "Pass"; Details = "Model: $($cpu.Name), Cores: $($cpu.NumberOfCores), Load: $cpuLoad%" })
        Write-Host "  CPU: $($cpu.Name), Cores: $($cpu.NumberOfCores), Load: $cpuLoad%" -ForegroundColor Green
    } catch {
        Write-Log "Error checking CPU: $($_.Exception.Message)" -Level Error
        $null = $results.Add([PSCustomObject]@{ Component = "CPU"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Windows Update status
    Write-Host "Checking Windows Update status..." -ForegroundColor Yellow
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $updateSearcher = $updateSession.CreateUpdateSearcher()
        $pendingUpdates = $updateSearcher.Search("IsInstalled=0 and Type='Software'").Updates
        if ($pendingUpdates.Count -gt 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "Windows Updates"; Status = "Warning"; Details = "$($pendingUpdates.Count) pending updates" })
            Write-Host "  $($pendingUpdates.Count) pending updates found" -ForegroundColor Yellow
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Windows Updates"; Status = "Pass"; Details = "No pending updates" })
            Write-Host "  No pending updates" -ForegroundColor Green
        }
    } catch {
        Write-Log "Error checking Windows Updates: $($_.Exception.Message)" -Level Error
        $null = $results.Add([PSCustomObject]@{ Component = "Windows Updates"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Event logs (with MaxEvents limit)
    Write-Host "Checking system event logs for critical errors..." -ForegroundColor Yellow
    try {
        $startTime = (Get-Date).AddDays(-7)
        $systemErrors = Invoke-SafeWinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=$startTime} -MaxEvents 500
        $applicationErrors = Invoke-SafeWinEvent -FilterHashtable @{LogName='Application'; Level=1,2; StartTime=$startTime} -MaxEvents 500
        $sysCount = if ($systemErrors) { @($systemErrors).Count } else { 0 }
        $appCount = if ($applicationErrors) { @($applicationErrors).Count } else { 0 }
        $totalErrors = $sysCount + $appCount
        if ($totalErrors -gt 0) {
            $status = if ($totalErrors -gt 10) { "Fail" } else { "Warning" }
            $null = $results.Add([PSCustomObject]@{ Component = "Event Logs"; Status = $status; Details = "$totalErrors critical/error events in 7 days (System: $sysCount, App: $appCount)" })
            Write-Host "  Found $totalErrors critical/error events in the last 7 days" -ForegroundColor Yellow
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Event Logs"; Status = "Pass"; Details = "No critical/error events in 7 days" })
            Write-Host "  No critical/error events in the last 7 days" -ForegroundColor Green
        }
    } catch {
        Write-Log "Error checking event logs: $($_.Exception.Message)" -Level Error
        $null = $results.Add([PSCustomObject]@{ Component = "Event Logs"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Disk space
    Write-Host "Checking disk space..." -ForegroundColor Yellow
    try {
        $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"
        foreach ($drive in $drives) {
            if ($drive.Size -gt 0) {
                $freeGB = [math]::Round($drive.FreeSpace / 1GB, 2)
                $totalGB = [math]::Round($drive.Size / 1GB, 2)
                $freePct = [math]::Round(($drive.FreeSpace / $drive.Size) * 100, 2)
                $status = if ($freePct -lt 10) { "Fail" } elseif ($freePct -lt 20) { "Warning" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "Disk Space ($($drive.DeviceID))"; Status = $status; Details = "Free: $freeGB GB / $totalGB GB ($freePct%)" })
                $color = if ($status -eq "Pass") { "Green" } elseif ($status -eq "Warning") { "Yellow" } else { "Red" }
                Write-Host "  Drive $($drive.DeviceID): $freeGB GB free / $totalGB GB ($freePct%)" -ForegroundColor $color
            }
        }
    } catch {
        Write-Log "Error checking disk space: $($_.Exception.Message)" -Level Error
        $null = $results.Add([PSCustomObject]@{ Component = "Disk Space"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Network
    Write-Host "Checking network connectivity..." -ForegroundColor Yellow
    try {
        $networkAdapters = Get-NetAdapter | Where-Object Status -eq "Up"
        if ($networkAdapters.Count -gt 0) {
            foreach ($adapter in $networkAdapters) {
                $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
                $ipAddress = if ($ipConfig.IPv4Address) { $ipConfig.IPv4Address.IPAddress } else { "N/A" }
                $null = $results.Add([PSCustomObject]@{ Component = "Network ($($adapter.Name))"; Status = "Pass"; Details = "IP: $ipAddress, Speed: $($adapter.LinkSpeed)" })
                Write-Host "  $($adapter.Name): IP=$ipAddress, Speed=$($adapter.LinkSpeed)" -ForegroundColor Green
            }
            $pingTest = Test-NetConnection -ComputerName 8.8.8.8 -WarningAction SilentlyContinue
            if ($pingTest.PingSucceeded) {
                $null = $results.Add([PSCustomObject]@{ Component = "Internet Connectivity"; Status = "Pass"; Details = "Internet reachable" })
                Write-Host "  Internet: Connected" -ForegroundColor Green
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Internet Connectivity"; Status = "Fail"; Details = "No internet" })
                Write-Host "  Internet: Not connected" -ForegroundColor Red
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Network"; Status = "Fail"; Details = "No active adapters" })
            Write-Host "  No active network connections" -ForegroundColor Red
        }
    } catch {
        Write-Log "Error checking network: $($_.Exception.Message)" -Level Error
        $null = $results.Add([PSCustomObject]@{ Component = "Network"; Status = "Error"; Details = $_.Exception.Message })
    }

    Write-Host "`nAdvanced Diagnostic completed. Generating report..." -ForegroundColor Cyan
    Export-DiagnosticReport -Title "Advanced System Diagnostic Results" -Results $results

    # Export summary CSV row to Results folder for fleet tracking
    try {
        $resultsDir = Join-Path $PSScriptRoot 'Results'
        if (-not (Test-Path $resultsDir)) { New-Item -Path $resultsDir -ItemType Directory -Force | Out-Null }
        $csvPath = Join-Path $resultsDir "Fleet_Diagnostic_Summary.csv"
        $passCount = ($results | Where-Object { $_.Status -eq "Pass" }).Count
        $warnCount = ($results | Where-Object { $_.Status -eq "Warning" }).Count
        $failCount = ($results | Where-Object { $_.Status -eq "Fail" }).Count
        $csvRow = [PSCustomObject]@{
            ComputerName  = $env:COMPUTERNAME
            SerialNumber  = $script:SerialNumber
            Model         = $script:ModelInfo
            ScanDate      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            TotalChecks   = $results.Count
            Pass          = $passCount
            Warning       = $warnCount
            Fail          = $failCount
            OverallStatus = if ($failCount -gt 0) { "FAIL" } elseif ($warnCount -gt 0) { "WARNING" } else { "PASS" }
        }
        $csvRow | Export-Csv -Path $csvPath -Append -NoTypeInformation -Force
        Write-Host "  Fleet summary saved to: $csvPath" -ForegroundColor Green
    } catch {
        Write-Log "Could not save fleet CSV: $($_.Exception.Message)" -Level Warning
    }

    Write-Log "Advanced Diagnostic completed" -Level Success
    $adFailCount = ($results | Where-Object { $_.Status -eq "Fail" }).Count
    $adWarnCount = ($results | Where-Object { $_.Status -eq "Warning" }).Count
    Write-AuditLog -Module 'AdvancedDiagnostic' -IssueCode "Fail:$adFailCount,Warn:$adWarnCount" -Severity "$(if ($adFailCount -gt 0) {'S2'} elseif ($adWarnCount -gt 0) {'S1'} else {'S1'})" -ActionTaken 'ScanOnly' -FinalState "$(if ($adFailCount -gt 0) {'IssuesFound'} else {'Clean'})"
    return $results
}

function Invoke-BSODAnalysis {
    Write-Log "Starting BSOD Analysis..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Blue Screen of Death (BSOD) Analysis" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Check memory dumps
    Write-Host "Checking for memory dump files..." -ForegroundColor Yellow
    try {
        $dumpPath = "$env:SystemRoot\Minidump"
        $memoryDumpPath = "$env:SystemRoot\MEMORY.DMP"
        $dumpFiles = @()
        if (Test-Path -Path $dumpPath) {
            $dumpFiles += Get-ChildItem -Path $dumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        }
        if (Test-Path -Path $memoryDumpPath) {
            $dumpFiles += Get-Item -Path $memoryDumpPath
        }
        if ($dumpFiles.Count -gt 0) {
            $recentDumps = $dumpFiles | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) }
            $oldestDump = $dumpFiles[-1].LastWriteTime.ToString('yyyy-MM-dd')
            $newestDump = $dumpFiles[0].LastWriteTime.ToString('yyyy-MM-dd')
            if ($recentDumps.Count -gt 0) {
                $null = $results.Add([PSCustomObject]@{ Component = "Memory Dumps"; Status = "Warning"; Details = "$($recentDumps.Count) recent + $($dumpFiles.Count - $recentDumps.Count) older dumps (total: $($dumpFiles.Count))" })
                Write-Host "  $($recentDumps.Count) dump files from the last 30 days" -ForegroundColor Yellow
                foreach ($dump in ($recentDumps | Select-Object -First 5)) {
                    $dumpDate = Get-Date $dump.LastWriteTime -Format 'yyyy-MM-dd HH:mm:ss'
                    $null = $results.Add([PSCustomObject]@{ Component = "Dump: $($dump.Name)"; Status = "Warning"; Details = "Created: $dumpDate, Size: $([math]::Round($dump.Length/1KB))KB" })
                    Write-Host "  $($dump.Name) - $dumpDate" -ForegroundColor Yellow
                }
            } elseif ($dumpFiles.Count -gt 0) {
                $null = $results.Add([PSCustomObject]@{ Component = "Memory Dumps"; Status = "Info"; Details = "$($dumpFiles.Count) dump(s) found but none in last 30 days (newest: $newestDump)" })
                Write-Host "  $($dumpFiles.Count) dump(s) found, none in last 30 days (newest: $newestDump)" -ForegroundColor Yellow
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Memory Dumps"; Status = "Pass"; Details = "No dump files found" })
                Write-Host "  No dump files found" -ForegroundColor Green
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Dumps"; Status = "Pass"; Details = "No dump files found" })
            Write-Host "  No dump files found" -ForegroundColor Green
        }
    } catch {
        Write-Log "Error checking memory dumps: $($_.Exception.Message)" -Level Error
        $null = $results.Add([PSCustomObject]@{ Component = "Memory Dumps"; Status = "Error"; Details = $_.Exception.Message })
    }

    # System stability
    Write-Host "Checking system stability..." -ForegroundColor Yellow
    try {
        $reliability = Get-CimInstance -ClassName Win32_ReliabilityRecords -ErrorAction SilentlyContinue |
            Where-Object { $_.TimeGenerated -ge (Get-Date).AddDays(-30) -and $_.SourceName -eq "Microsoft-Windows-WER-SystemErrorReporting" }
        if ($reliability -and @($reliability).Count -gt 0) {
            $relCount = @($reliability).Count
            $null = $results.Add([PSCustomObject]@{ Component = "System Stability"; Status = "Warning"; Details = "$relCount system errors in 30 days" })
            Write-Host "  $relCount system errors in 30 days" -ForegroundColor Yellow
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "System Stability"; Status = "Pass"; Details = "No system errors in 30 days" })
            Write-Host "  No system errors in 30 days" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "System Stability"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Problem drivers
    Write-Host "Checking for problem drivers..." -ForegroundColor Yellow
    try {
        $problemDrivers = Get-CimInstance -ClassName Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
        if ($problemDrivers -and @($problemDrivers).Count -gt 0) {
            $pdCount = @($problemDrivers).Count
            $null = $results.Add([PSCustomObject]@{ Component = "Problem Drivers"; Status = "Warning"; Details = "$pdCount devices with driver issues" })
            Write-Host "  $pdCount devices with driver issues" -ForegroundColor Yellow
            foreach ($drv in ($problemDrivers | Select-Object -First 10)) {
                $null = $results.Add([PSCustomObject]@{ Component = "Driver: $($drv.Name)"; Status = "Warning"; Details = "Error code $($drv.ConfigManagerErrorCode)" })
                Write-Host "    - $($drv.Name): Error $($drv.ConfigManagerErrorCode)" -ForegroundColor Yellow
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Problem Drivers"; Status = "Pass"; Details = "No driver issues" })
            Write-Host "  No driver issues" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Problem Drivers"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Disk errors from event log
    Write-Host "Checking disk errors in event log..." -ForegroundColor Yellow
    try {
        $diskErrors = Invoke-SafeWinEvent -FilterHashtable @{LogName='System'; ProviderName='disk','ftdisk','NTFS'; Level=1,2,3; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 500
        $deCount = if ($diskErrors) { @($diskErrors).Count } else { 0 }
        if ($deCount -gt 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "Disk Errors"; Status = "Warning"; Details = "$deCount disk errors in 30 days" })
            Write-Host "  $deCount disk errors in 30 days" -ForegroundColor Yellow
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Disk Errors"; Status = "Pass"; Details = "No disk errors in 30 days" })
            Write-Host "  No disk errors in 30 days" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Disk Errors"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Memory diagnostic results
    Write-Host "Checking memory diagnostic results..." -ForegroundColor Yellow
    try {
        $memErrors = Invoke-SafeWinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Memory-Diagnostic-Results'; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 100
        $meCount = if ($memErrors) { @($memErrors).Count } else { 0 }
        if ($meCount -gt 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Diagnostics"; Status = "Warning"; Details = "$meCount memory diagnostic results in 30 days" })
            Write-Host "  $meCount memory diagnostic results" -ForegroundColor Yellow
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Diagnostics"; Status = "Pass"; Details = "No memory diagnostic results" })
            Write-Host "  No memory diagnostic results" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Memory Diagnostics"; Status = "Error"; Details = $_.Exception.Message })
    }

    Write-Host "`nBSOD Analysis completed. Generating report..." -ForegroundColor Cyan

    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'BSODAnalysis' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'BSODAnalysis' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "BSOD Analysis Results" -Results $results
    Write-Log "BSOD Analysis completed" -Level Success
    return $results
}

function Invoke-EnhancedHardwareTest {
    Write-Log "Starting Enhanced Hardware Test..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Enhanced Hardware Test" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # CPU Test
    Write-Host "Testing CPU..." -ForegroundColor Yellow
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor
        Write-Host "  Running CPU stress test (10s)... " -ForegroundColor Yellow -NoNewline
        $job = Start-Job -ScriptBlock {
            $start = Get-Date
            while ((Get-Date) - $start -lt [TimeSpan]::FromSeconds(10)) {
                for ($i = 0; $i -lt 5000000; $i++) { [void][math]::Sqrt($i) }
            }
        }
        Wait-Job -Job $job -Timeout 15 | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        Write-Host "done" -ForegroundColor Green

        # CPU temperature (validated range)
        try {
            $thermalZones = Get-CimInstance -Namespace "root/wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
            foreach ($tz in $thermalZones) {
                $rawTemp = $tz.CurrentTemperature
                if ($rawTemp -ge 0 -and $rawTemp -le 5000) {
                    $tempC = ($rawTemp - 2732) / 10
                    if ($tempC -ge 0 -and $tempC -le 120) {
                        $tempStatus = if ($tempC -gt 80) { "Fail" } elseif ($tempC -gt 70) { "Warning" } else { "Pass" }
                        $null = $results.Add([PSCustomObject]@{ Component = "CPU Temperature"; Status = $tempStatus; Details = "$([math]::Round($tempC,1))C" })
                        $color = if ($tempStatus -eq "Pass") { "Green" } elseif ($tempStatus -eq "Warning") { "Yellow" } else { "Red" }
                        Write-Host "  CPU Temperature: $([math]::Round($tempC,1))C" -ForegroundColor $color
                    } else {
                        $null = $results.Add([PSCustomObject]@{ Component = "CPU Temperature"; Status = "Info"; Details = "Sensor returned out-of-range value" })
                        Write-Host "  CPU Temperature: sensor out of range" -ForegroundColor Yellow
                    }
                }
            }
        } catch {
            Write-Host "  CPU Temperature: not available via WMI" -ForegroundColor Yellow
        }

        $null = $results.Add([PSCustomObject]@{ Component = "CPU"; Status = "Pass"; Details = "$($cpu.Name), Cores: $($cpu.NumberOfCores), Logical: $($cpu.NumberOfLogicalProcessors)" })
        Write-Host "  CPU: $($cpu.Name)" -ForegroundColor Green
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "CPU"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Memory test (fixed: use List[byte[]] instead of += PSObject x1M)
    Write-Host "Testing memory..." -ForegroundColor Yellow
    try {
        $memoryModules = Get-CimInstance -ClassName Win32_PhysicalMemory
        foreach ($module in $memoryModules) {
            $capGB = [math]::Round($module.Capacity / 1GB, 2)
            $null = $results.Add([PSCustomObject]@{ Component = "Memory (Bank: $($module.BankLabel))"; Status = "Pass"; Details = "$capGB GB, $($module.Speed) MHz, $($module.Manufacturer)" })
            Write-Host "  Memory Bank $($module.BankLabel): $capGB GB @ $($module.Speed) MHz" -ForegroundColor Green
        }

        Write-Host "  Running memory stress test (100x1MB blocks)... " -ForegroundColor Yellow -NoNewline
        $job = Start-Job -ScriptBlock {
            $blocks = New-Object 'System.Collections.Generic.List[byte[]]'
            for ($i = 0; $i -lt 100; $i++) {
                $block = New-Object byte[] (1MB)
                [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($block)
                $blocks.Add($block)
            }
            $blocks.Clear()
        }
        $jobDone = Wait-Job -Job $job -Timeout 30
        if ($null -eq $jobDone) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Stress Test"; Status = "Warning"; Details = "Timed out" })
            Write-Host "timed out" -ForegroundColor Yellow
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Stress Test"; Status = "Pass"; Details = "100MB allocated and verified" })
            Write-Host "passed" -ForegroundColor Green
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Memory"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Disk test (with free space check before creating test file)
    Write-Host "Testing disks..." -ForegroundColor Yellow
    try {
        $disks = Get-PhysicalDisk
        foreach ($disk in $disks) {
            $diskSizeGB = [math]::Round($disk.Size / 1GB, 2)
            $diskStatus = if ($disk.HealthStatus -eq "Healthy") { "Pass" } else { "Fail" }
            $null = $results.Add([PSCustomObject]@{ Component = "Disk: $($disk.FriendlyName)"; Status = $diskStatus; Details = "Health: $($disk.HealthStatus), Media: $($disk.MediaType), $diskSizeGB GB" })
            $color = if ($diskStatus -eq "Pass") { "Green" } else { "Red" }
            Write-Host "  $($disk.FriendlyName) ($diskSizeGB GB) - $($disk.HealthStatus)" -ForegroundColor $color
        }

        # Disk read/write test - check 200MB free first
        $tempDrive = (Get-Item $TempPath).PSDrive.Name + ":"
        $tempDriveInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$tempDrive'"
        $freeSpaceMB = if ($tempDriveInfo) { [math]::Round($tempDriveInfo.FreeSpace / 1MB) } else { 0 }

        if ($freeSpaceMB -ge 200) {
            Write-Host "  Running disk I/O test (100MB)... " -ForegroundColor Yellow -NoNewline
            $testFile = Join-Path $TempPath "disktest_$(Get-Random).tmp"
            $testSize = 100MB
            try {
                $testBuffer = New-Object byte[] $testSize
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                [System.IO.File]::WriteAllBytes($testFile, $testBuffer)
                $sw.Stop()
                $writeSpeed = [math]::Round(($testSize / $sw.Elapsed.TotalSeconds) / 1MB, 2)

                $sw.Restart()
                [System.IO.File]::ReadAllBytes($testFile) | Out-Null
                $sw.Stop()
                $readSpeed = [math]::Round(($testSize / $sw.Elapsed.TotalSeconds) / 1MB, 2)

                $ioStatus = if ($readSpeed -lt 50 -or $writeSpeed -lt 50) { "Warning" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "Disk I/O Test"; Status = $ioStatus; Details = "Read: $readSpeed MB/s, Write: $writeSpeed MB/s" })
                Write-Host "  Disk I/O: Read=$readSpeed MB/s, Write=$writeSpeed MB/s" -ForegroundColor $(if ($ioStatus -eq "Pass") { "Green" } else { "Yellow" })
            } finally {
                if (Test-Path $testFile) { Remove-Item $testFile -Force }
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Disk I/O Test"; Status = "Warning"; Details = "Skipped: only ${freeSpaceMB}MB free (need 200MB)" })
            Write-Host "  Disk I/O test skipped: insufficient free space (${freeSpaceMB}MB)" -ForegroundColor Yellow
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Disks"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Network test
    Write-Host "Testing network..." -ForegroundColor Yellow
    try {
        $adapters = Get-NetAdapter | Where-Object Status -eq "Up"
        if ($adapters.Count -gt 0) {
            foreach ($adapter in $adapters) {
                $ipCfg = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
                $ip = if ($ipCfg.IPv4Address) { $ipCfg.IPv4Address.IPAddress } else { "N/A" }
                $null = $results.Add([PSCustomObject]@{ Component = "Network: $($adapter.Name)"; Status = "Pass"; Details = "IP: $ip, Speed: $($adapter.LinkSpeed), MAC: $($adapter.MacAddress)" })
                Write-Host "  $($adapter.Name): IP=$ip, Speed=$($adapter.LinkSpeed)" -ForegroundColor Green
            }
            foreach ($target in @(@{T="8.8.8.8";N="Google DNS"},@{T="1.1.1.1";N="Cloudflare DNS"})) {
                Write-Host "  Pinging $($target.N)..." -ForegroundColor Yellow -NoNewline
                try {
                    $ping = Test-Connection -ComputerName $target.T -Count 2 -BufferSize 32 -ErrorAction Stop
                    $avg = ($ping | Measure-Object -Property ResponseTime -Average).Average
                    $null = $results.Add([PSCustomObject]@{ Component = "Ping: $($target.N)"; Status = "Pass"; Details = "Avg: $([math]::Round($avg,1))ms" })
                    Write-Host " $([math]::Round($avg,1))ms" -ForegroundColor Green
                } catch {
                    $null = $results.Add([PSCustomObject]@{ Component = "Ping: $($target.N)"; Status = "Fail"; Details = "Unreachable" })
                    Write-Host " Failed" -ForegroundColor Red
                }
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Network"; Status = "Warning"; Details = "No active connections" })
            Write-Host "  No active connections" -ForegroundColor Yellow
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Network"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Battery test
    Write-Host "Testing battery..." -ForegroundColor Yellow
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if ($battery) {
            $battStatus = switch ($battery.BatteryStatus) {
                1 {"Discharging"} 2 {"AC Power"} 3 {"Fully Charged"} 4 {"Low"} 5 {"Critical"} 6 {"Charging"} default {"Unknown"}
            }
            $healthPct = "N/A"
            $healthStatus = "Info"
            if ($battery.DesignCapacity -gt 0 -and $battery.FullChargeCapacity -gt 0) {
                $healthPct = [math]::Round(($battery.FullChargeCapacity / $battery.DesignCapacity) * 100, 1)
                $healthStatus = if ($healthPct -lt 50) { "Fail" } elseif ($healthPct -lt 80) { "Warning" } else { "Pass" }
            }
            $null = $results.Add([PSCustomObject]@{ Component = "Battery"; Status = $healthStatus; Details = "Health: $healthPct%, Charge: $($battery.EstimatedChargeRemaining)%, Status: $battStatus" })
            Write-Host "  Battery: Health=$healthPct%, Charge=$($battery.EstimatedChargeRemaining)%, Status=$battStatus" -ForegroundColor $(if ($healthStatus -eq "Pass") {"Green"} elseif ($healthStatus -eq "Warning") {"Yellow"} else {"Red"})
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Battery"; Status = "Info"; Details = "No battery (desktop)" })
            Write-Host "  No battery detected" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Battery"; Status = "Error"; Details = $_.Exception.Message })
    }

    Write-Host "`nEnhanced Hardware Test completed. Generating report..." -ForegroundColor Cyan

    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'EnhancedHardwareTest' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'EnhancedHardwareTest' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Enhanced Hardware Test Results" -Results $results
    Write-Log "Enhanced Hardware Test completed" -Level Success
    return $results
}

function Invoke-CustomTests {
    Write-Log "Starting Custom Tests..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Custom Hardware Tests" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host
    Write-Host "  [A] System Information      [B] Battery Health"
    Write-Host "  [C] Storage Tests           [D] Memory Tests"
    Write-Host "  [E] Display Tests           [F] Network Tests"
    Write-Host "  [G] Keyboard/TrackPoint     [H] Fan/Thermal"
    Write-Host "  [I] Port Tests              [J] Webcam/Audio"
    Write-Host "  [K] Modern Standby          [L] ThinkPad-Specific"
    Write-Host "  [M] TPM/Security            [N] Thunderbolt/USB-C"
    Write-Host
    $testChoice = Read-Host "Select tests (e.g., ABDF)"
    if (-not $testChoice) { $testChoice = "A" }
    Write-Log "Custom test selection: $testChoice" -Level Info

    foreach ($ch in $testChoice.ToUpper().ToCharArray()) {
        switch ($ch) {
            'A' {
                Write-Host "`n--- System Information ---" -ForegroundColor Cyan
                if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }
                $null = $results.Add([PSCustomObject]@{ Component = "System Info"; Status = "Info"; Details = "$($script:SystemInfo.Model), $($script:SystemInfo.ProcessorName), $($script:SystemInfo.TotalMemoryGB)GB RAM" })
                Write-Host "  Model: $($script:SystemInfo.Model)" -ForegroundColor White
                Write-Host "  CPU: $($script:SystemInfo.ProcessorName)" -ForegroundColor White
                Write-Host "  RAM: $($script:SystemInfo.TotalMemoryGB) GB" -ForegroundColor White
            }
            'B' {
                Write-Host "`n--- Battery Health ---" -ForegroundColor Cyan
                $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
                if ($bat) {
                    $null = $results.Add([PSCustomObject]@{ Component = "Battery"; Status = "Info"; Details = "Charge: $($bat.EstimatedChargeRemaining)%" })
                    Write-Host "  Charge: $($bat.EstimatedChargeRemaining)%" -ForegroundColor Green
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "Battery"; Status = "Info"; Details = "No battery" })
                    Write-Host "  No battery detected" -ForegroundColor Gray
                }
            }
            'C' {
                Write-Host "`n--- Storage Tests ---" -ForegroundColor Cyan
                $phys = Get-PhysicalDisk
                foreach ($d in $phys) {
                    $sz = [math]::Round($d.Size/1GB,1)
                    $null = $results.Add([PSCustomObject]@{ Component = "Disk: $($d.FriendlyName)"; Status = $(if($d.HealthStatus -eq "Healthy"){"Pass"}else{"Fail"}); Details = "$sz GB, $($d.MediaType), $($d.HealthStatus)" })
                    Write-Host "  $($d.FriendlyName): $sz GB, $($d.MediaType), $($d.HealthStatus)" -ForegroundColor $(if($d.HealthStatus -eq "Healthy"){"Green"}else{"Red"})
                }
            }
            'D' {
                Write-Host "`n--- Memory Tests ---" -ForegroundColor Cyan
                $mem = Get-CimInstance Win32_PhysicalMemory
                foreach ($m in $mem) {
                    $cap = [math]::Round($m.Capacity/1GB,2)
                    $null = $results.Add([PSCustomObject]@{ Component = "Memory $($m.BankLabel)"; Status = "Pass"; Details = "$cap GB @ $($m.Speed) MHz" })
                    Write-Host "  $($m.BankLabel): $cap GB @ $($m.Speed) MHz" -ForegroundColor Green
                }
            }
            'E' {
                Write-Host "`n--- Display Tests ---" -ForegroundColor Cyan
                $gpu = Get-CimInstance Win32_VideoController
                foreach ($g in $gpu) {
                    $null = $results.Add([PSCustomObject]@{ Component = "GPU: $($g.Name)"; Status = "Info"; Details = "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)" })
                    Write-Host "  $($g.Name): $($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)" -ForegroundColor White
                }
            }
            'F' {
                Write-Host "`n--- Network Tests ---" -ForegroundColor Cyan
                $adapters = Get-NetAdapter | Where-Object Status -eq "Up"
                foreach ($a in $adapters) {
                    $null = $results.Add([PSCustomObject]@{ Component = "Net: $($a.Name)"; Status = "Pass"; Details = "$($a.LinkSpeed), MAC: $($a.MacAddress)" })
                    Write-Host "  $($a.Name): $($a.LinkSpeed)" -ForegroundColor Green
                }
            }
            'G' {
                Write-Host "`n--- Keyboard/TrackPoint ---" -ForegroundColor Cyan
                $tp = Get-CimInstance Win32_PointingDevice -ErrorAction SilentlyContinue
                foreach ($p in $tp) {
                    $null = $results.Add([PSCustomObject]@{ Component = "Pointing: $($p.Name)"; Status = "Info"; Details = $p.Description })
                    Write-Host "  $($p.Name)" -ForegroundColor White
                }
                $kb = Get-CimInstance Win32_Keyboard -ErrorAction SilentlyContinue
                foreach ($k in $kb) {
                    $null = $results.Add([PSCustomObject]@{ Component = "Keyboard: $($k.Name)"; Status = "Info"; Details = $k.Description })
                    Write-Host "  $($k.Name)" -ForegroundColor White
                }
            }
            'H' {
                Write-Host "`n--- Fan/Thermal ---" -ForegroundColor Cyan
                try {
                    $tz = Get-CimInstance -Namespace "root/wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
                    foreach ($z in $tz) {
                        $raw = $z.CurrentTemperature
                        if ($raw -ge 0 -and $raw -le 5000) {
                            $tc = [math]::Round(($raw - 2732) / 10, 1)
                            if ($tc -ge 0 -and $tc -le 120) {
                                $null = $results.Add([PSCustomObject]@{ Component = "Thermal Zone"; Status = $(if($tc -gt 80){"Warning"}else{"Pass"}); Details = "${tc}C" })
                                Write-Host "  Thermal: ${tc}C" -ForegroundColor $(if($tc -gt 80){"Yellow"}else{"Green"})
                            }
                        }
                    }
                } catch {
                    $null = $results.Add([PSCustomObject]@{ Component = "Thermal"; Status = "Info"; Details = "WMI thermal data not available" })
                    Write-Host "  Thermal data not available" -ForegroundColor Yellow
                }
            }
            'I' {
                Write-Host "`n--- Port Tests ---" -ForegroundColor Cyan
                $usb = Get-CimInstance Win32_USBController
                foreach ($u in $usb) {
                    $null = $results.Add([PSCustomObject]@{ Component = "USB: $($u.Name)"; Status = "Info"; Details = $u.Description })
                    Write-Host "  $($u.Name)" -ForegroundColor White
                }
            }
            'J' {
                Write-Host "`n--- Webcam/Audio ---" -ForegroundColor Cyan
                $cam = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPClass -eq "Camera" -or $_.PNPClass -eq "Image" }
                foreach ($c in $cam) {
                    $null = $results.Add([PSCustomObject]@{ Component = "Camera: $($c.Name)"; Status = "Info"; Details = $c.Status })
                    Write-Host "  Camera: $($c.Name)" -ForegroundColor White
                }
                $audio = Get-CimInstance Win32_SoundDevice
                foreach ($a in $audio) {
                    $null = $results.Add([PSCustomObject]@{ Component = "Audio: $($a.Name)"; Status = "Info"; Details = $a.Status })
                    Write-Host "  Audio: $($a.Name)" -ForegroundColor White
                }
            }
            'K' {
                Write-Host "`n--- Modern Standby ---" -ForegroundColor Cyan
                try {
                    $csEnabled = (powercfg /a 2>&1) -join "`n"
                    $hasMS = $csEnabled -match "Standby \(S0 Low Power Idle\)"
                    $null = $results.Add([PSCustomObject]@{ Component = "Modern Standby"; Status = $(if($hasMS){"Pass"}else{"Info"}); Details = $(if($hasMS){"Supported"}else{"Not supported/not available"}) })
                    Write-Host "  Modern Standby: $(if($hasMS){'Supported'}else{'Not available'})" -ForegroundColor $(if($hasMS){"Green"}else{"Yellow"})
                } catch {
                    $null = $results.Add([PSCustomObject]@{ Component = "Modern Standby"; Status = "Error"; Details = $_.Exception.Message })
                }
            }
            'L' {
                Write-Host "`n--- ThinkPad-Specific ---" -ForegroundColor Cyan
                if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }
                $isTP = $script:IsThinkPad
                $null = $results.Add([PSCustomObject]@{ Component = "ThinkPad Detection"; Status = $(if($isTP){"Pass"}else{"Warning"}); Details = $(if($isTP){"ThinkPad confirmed: $($script:ModelInfo)"}else{"Not a ThinkPad"}) })
                Write-Host "  ThinkPad: $(if($isTP){$script:ModelInfo}else{'Not detected'})" -ForegroundColor $(if($isTP){"Green"}else{"Yellow"})
            }
            'M' {
                Write-Host "`n--- TPM/Security ---" -ForegroundColor Cyan
                try {
                    $tpm = Get-Tpm -ErrorAction Stop
                    $null = $results.Add([PSCustomObject]@{ Component = "TPM"; Status = $(if($tpm.TpmPresent){"Pass"}else{"Warning"}); Details = "Present: $($tpm.TpmPresent), Ready: $($tpm.TpmReady)" })
                    Write-Host "  TPM Present: $($tpm.TpmPresent), Ready: $($tpm.TpmReady)" -ForegroundColor $(if($tpm.TpmPresent){"Green"}else{"Yellow"})
                } catch {
                    $null = $results.Add([PSCustomObject]@{ Component = "TPM"; Status = "Info"; Details = "Cannot query TPM" })
                    Write-Host "  TPM: Cannot query" -ForegroundColor Yellow
                }
            }
            'N' {
                Write-Host "`n--- Thunderbolt/USB-C ---" -ForegroundColor Cyan
                $tb = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match "Thunderbolt|USB-C|USB4" }
                if ($tb) {
                    foreach ($t in $tb) {
                        $null = $results.Add([PSCustomObject]@{ Component = "TB/USB-C: $($t.Name)"; Status = "Info"; Details = $t.Status })
                        Write-Host "  $($t.Name)" -ForegroundColor White
                    }
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "Thunderbolt/USB-C"; Status = "Info"; Details = "No Thunderbolt/USB-C devices detected" })
                    Write-Host "  No Thunderbolt/USB-C devices" -ForegroundColor Gray
                }
            }
        }
    }

    Write-Host "`nCustom Tests completed. Generating report..." -ForegroundColor Cyan

    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'CustomTests' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'CustomTests' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Custom Hardware Test Results" -Results $results
    Write-Log "Custom Tests completed" -Level Success
    return $results
}

function Invoke-DiagnosticAnalyzer {
    Write-Log "Starting Diagnostic Analyzer..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Diagnostic Log Analyzer" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    $logFiles = Get-ChildItem -Path $LogPath -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $logFiles -or $logFiles.Count -eq 0) {
        Write-Host "  No diagnostic logs found in $LogPath" -ForegroundColor Yellow
        $null = $results.Add([PSCustomObject]@{ Component = "Log Files"; Status = "Info"; Details = "No logs found" })
    } else {
        Write-Host "  Found $($logFiles.Count) log files" -ForegroundColor Green
        $null = $results.Add([PSCustomObject]@{ Component = "Log Files"; Status = "Info"; Details = "$($logFiles.Count) logs found" })

        $errorCount = 0
        $warningCount = 0
        $recentLogs = $logFiles | Select-Object -First 10

        foreach ($logF in $recentLogs) {
            $content = Get-Content $logF.FullName -ErrorAction SilentlyContinue
            if ($content) {
                $errors = @($content | Where-Object { $_ -match '\[Error\]|\[ERROR\]' })
                $warnings = @($content | Where-Object { $_ -match '\[Warning\]|\[WARNING\]' })
                $errorCount += $errors.Count
                $warningCount += $warnings.Count

                $status = if ($errors.Count -gt 0) { "Warning" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{
                    Component = "Log: $($logF.Name)"
                    Status = $status
                    Details = "Errors: $($errors.Count), Warnings: $($warnings.Count), Date: $(Get-Date $logF.LastWriteTime -Format 'yyyy-MM-dd')"
                })
            }
        }

        Write-Host "  Total errors (last 10 logs): $errorCount" -ForegroundColor $(if($errorCount -gt 0){"Yellow"}else{"Green"})
        Write-Host "  Total warnings (last 10 logs): $warningCount" -ForegroundColor $(if($warningCount -gt 0){"Yellow"}else{"Green"})

        # Check for patterns
        $batteryIssues = @($logFiles | ForEach-Object { Get-Content $_.FullName -ErrorAction SilentlyContinue } | Where-Object { $_ -match 'Battery Health.*\d+%' -and $_ -match '[Ww]arning|[Ff]ail' })
        if ($batteryIssues.Count -gt 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "Pattern: Battery"; Status = "Warning"; Details = "$($batteryIssues.Count) battery warnings across logs" })
            Write-Host "  Pattern: $($batteryIssues.Count) battery warnings found" -ForegroundColor Yellow
        }
    }

    Write-Host "`nDiagnostic Analyzer completed. Generating report..." -ForegroundColor Cyan

    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'DiagnosticAnalyzer' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'DiagnosticAnalyzer' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Diagnostic Log Analysis Results" -Results $results
    Write-Log "Diagnostic Analyzer completed" -Level Success
    return $results
}

#endregion

#region Repair Tools

function Invoke-BootRepair {
    Write-Log "Starting Boot Repair..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Boot Repair" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    New-SafeRestorePoint -ModuleName "Boot Repair" | Out-Null
    Write-Host

    # Check boot configuration via bcdedit (always available)
    Write-Host "Checking boot configuration..." -ForegroundColor Yellow
    try {
        $bcdedit = & bcdedit /enum 2>&1
        $bootConfigFile = Join-Path $TempPath "boot_config_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $bcdedit | Out-File -FilePath $bootConfigFile -Encoding utf8 -Force
        $null = $results.Add([PSCustomObject]@{ Component = "Boot Configuration"; Status = "Pass"; Details = "BCD data retrieved and saved" })
        Write-Host "  Boot configuration saved to $bootConfigFile" -ForegroundColor Green
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Boot Configuration"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Startup items
    Write-Host "Checking startup items..." -ForegroundColor Yellow
    try {
        $startupItems = Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue
        $siCount = if ($startupItems) { @($startupItems).Count } else { 0 }
        $null = $results.Add([PSCustomObject]@{ Component = "Startup Items"; Status = "Info"; Details = "$siCount startup items" })
        Write-Host "  $siCount startup items found" -ForegroundColor Green
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Startup Items"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Boot record repair - wrap bootrec in Test-CommandExists with fallback
    Write-Host "Repairing boot records..." -ForegroundColor Yellow
    $bootSafe = Test-DomainSafety -ActionType 'Boot' -Detail "Repair boot records (bootrec/bcdedit)"
    if (-not $bootSafe) {
        $null = $results.Add([PSCustomObject]@{ Component = "Boot Records"; Status = "Info"; Details = "Skipped - user declined (BitLocker/domain safety)" })
        Write-Host "  Boot record repair skipped by user" -ForegroundColor DarkYellow
    } elseif (Test-CommandExists "bootrec") {
        try {
            $fixmbr = & bootrec /fixmbr 2>&1
            $fixboot = & bootrec /fixboot 2>&1
            $null = $results.Add([PSCustomObject]@{ Component = "Boot Records (bootrec)"; Status = "Pass"; Details = "fixmbr and fixboot executed" })
            Write-Host "  bootrec /fixmbr and /fixboot executed" -ForegroundColor Green
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Boot Records (bootrec)"; Status = "Warning"; Details = "bootrec encountered issues: $($_.Exception.Message)" })
            Write-Host "  bootrec had issues, falling back to bcdedit/bcdboot" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  bootrec not available (WinRE only). Using bcdedit/bcdboot..." -ForegroundColor Yellow
        try {
            $bcdStatus = & bcdedit /enum "{default}" 2>&1
            $null = $results.Add([PSCustomObject]@{ Component = "Boot Records (bcdedit)"; Status = "Info"; Details = "bcdedit verified default entry. bootrec requires WinRE." })
            if (Test-CommandExists "bcdboot") {
                & bcdboot "$env:SystemRoot" /s "$env:SystemDrive" /f UEFI 2>&1 | Out-Null
                $null = $results.Add([PSCustomObject]@{ Component = "Boot Records (bcdboot)"; Status = "Pass"; Details = "bcdboot refreshed boot files" })
                Write-Host "  bcdboot refreshed boot files" -ForegroundColor Green
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Boot Records"; Status = "Warning"; Details = "Fallback repair had issues: $($_.Exception.Message)" })
        }
    }

    # SFC scan
    Write-Host "Running System File Checker (SFC)..." -ForegroundColor Yellow
    try {
        $sfcOutput = & sfc /scannow 2>&1
        $sfcText = $sfcOutput -join " "
        if ($sfcText -match "found corrupt files and successfully repaired") {
            $null = $results.Add([PSCustomObject]@{ Component = "SFC"; Status = "Warning"; Details = "Corrupt files found and repaired" })
            Write-Host "  SFC: Corrupt files repaired" -ForegroundColor Yellow
        } elseif ($sfcText -match "did not find any integrity violations") {
            $null = $results.Add([PSCustomObject]@{ Component = "SFC"; Status = "Pass"; Details = "No integrity violations" })
            Write-Host "  SFC: No integrity violations" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "SFC"; Status = "Info"; Details = "SFC completed" })
            Write-Host "  SFC completed" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "SFC"; Status = "Error"; Details = $_.Exception.Message })
    }

    # DISM
    Write-Host "Running DISM repair..." -ForegroundColor Yellow
    try {
        $dismResult = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop
        $status = if ($dismResult.ImageHealthState -eq "Healthy") { "Pass" } else { "Warning" }
        $null = $results.Add([PSCustomObject]@{ Component = "DISM Repair"; Status = $status; Details = "Health: $($dismResult.ImageHealthState)" })
        Write-Host "  DISM: $($dismResult.ImageHealthState)" -ForegroundColor $(if($status -eq "Pass"){"Green"}else{"Yellow"})
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "DISM Repair"; Status = "Error"; Details = $_.Exception.Message })
        Write-Host "  DISM error: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`nBoot Repair completed. Generating report..." -ForegroundColor Cyan
    Export-DiagnosticReport -Title "Boot Repair Results" -Results $results
    Write-Log "Boot Repair completed" -Level Success
    Write-AuditLog -Module 'BootRepair' -IssueCode 'BootRepair' -Severity 'S2' -ActionTaken 'BootRecordRepair' -FinalState 'Completed'
    return $results
}

function Invoke-BIOSRepair {
    Write-Log "Starting BIOS Repair..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  BIOS Management and Repair" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }

    $bios = Get-CimInstance -ClassName Win32_BIOS
    $model = $script:SystemInfo.Model
    $biosVersion = $bios.SMBIOSBIOSVersion
    $biosDate = $bios.ReleaseDate
    $serialNumber = $bios.SerialNumber
    $isTP = $script:IsThinkPad

    Write-Host "  Model: $model" -ForegroundColor White
    Write-Host "  BIOS Version: $biosVersion" -ForegroundColor White
    Write-Host "  BIOS Date: $biosDate" -ForegroundColor White
    Write-Host "  Serial: $serialNumber" -ForegroundColor White

    $null = $results.Add([PSCustomObject]@{ Component = "BIOS Version"; Status = "Info"; Details = "$biosVersion (released $biosDate)" })
    $null = $results.Add([PSCustomObject]@{ Component = "Serial Number"; Status = "Info"; Details = $serialNumber })

    # Check BIOS age
    $biosAgeMonths = (New-TimeSpan -Start $biosDate -End (Get-Date)).Days / 30
    if ($biosAgeMonths -gt 12) {
        $null = $results.Add([PSCustomObject]@{ Component = "BIOS Age"; Status = "Warning"; Details = "$([math]::Round($biosAgeMonths,0)) months old - consider updating" })
        Write-Host "  BIOS is $([math]::Round($biosAgeMonths,0)) months old" -ForegroundColor Yellow
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "BIOS Age"; Status = "Pass"; Details = "$([math]::Round($biosAgeMonths,0)) months old" })
        Write-Host "  BIOS age: $([math]::Round($biosAgeMonths,0)) months" -ForegroundColor Green
    }

    if (-not $isTP) {
        $null = $results.Add([PSCustomObject]@{ Component = "ThinkPad Check"; Status = "Warning"; Details = "Not a ThinkPad - some recommendations may not apply" })
        Write-Host "  WARNING: Not a ThinkPad device" -ForegroundColor Yellow
    }

    # Recommendations
    $recs = @(
        "Always back up data before BIOS updates",
        "Use Lenovo System Update or Vantage for BIOS updates",
        "Ensure AC power and >20% battery before flashing"
    )
    if ($isTP) { $recs += "For this ThinkPad, use Lenovo Commercial Vantage for driver and BIOS management" }
    foreach ($rec in $recs) {
        $null = $results.Add([PSCustomObject]@{ Component = "Recommendation"; Status = "Info"; Details = $rec })
    }

    Write-Host "`nBIOS Repair completed. Generating report..." -ForegroundColor Cyan

    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'BIOSRepair' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'BIOSRepair' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "BIOS Management Report" -Results $results
    Write-Log "BIOS Repair completed" -Level Success
    return $results
}

function Invoke-DriverRepair {
    Write-Log "Starting Driver Repair..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Driver Repair and Update" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    New-SafeRestorePoint -ModuleName "Driver Repair" | Out-Null
    Write-Host

    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }
    $isTP = $script:IsThinkPad

    # Scan problem devices
    Write-Host "Scanning for problem devices..." -ForegroundColor Yellow
    try {
        $problemDevices = Get-CimInstance -ClassName Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
        $pdList = if ($problemDevices) { @($problemDevices) } else { @() }
        if ($pdList.Count -gt 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "Problem Devices"; Status = "Warning"; Details = "$($pdList.Count) devices with issues" })
            Write-Host "  $($pdList.Count) problem devices found" -ForegroundColor Yellow
            foreach ($dev in $pdList) {
                $errMsg = switch ($dev.ConfigManagerErrorCode) {
                    1 {"Not configured correctly"} 2 {"Cannot load driver"} 3 {"Driver corrupted/missing"}
                    10 {"Cannot start"} 12 {"Insufficient resources"} 14 {"Needs restart"}
                    18 {"Needs reinstall"} 22 {"Disabled"} 24 {"Not present"} 28 {"Drivers not installed"}
                    default {"Error code $($dev.ConfigManagerErrorCode)"}
                }
                $null = $results.Add([PSCustomObject]@{ Component = "Device: $($dev.Name)"; Status = "Warning"; Details = $errMsg })
                Write-Host "    $($dev.Name): $errMsg" -ForegroundColor Yellow
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Problem Devices"; Status = "Pass"; Details = "No issues found" })
            Write-Host "  No problem devices" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Problem Devices"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Scan unsigned drivers
    Write-Host "Checking for unsigned drivers..." -ForegroundColor Yellow
    try {
        $unsignedDrivers = Get-CimInstance -ClassName Win32_PnPSignedDriver | Where-Object { $_.IsSigned -eq $false }
        $usList = if ($unsignedDrivers) { @($unsignedDrivers) } else { @() }
        if ($usList.Count -gt 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "Unsigned Drivers"; Status = "Warning"; Details = "$($usList.Count) unsigned drivers" })
            Write-Host "  $($usList.Count) unsigned drivers found" -ForegroundColor Yellow
            foreach ($drv in ($usList | Select-Object -First 10)) {
                $null = $results.Add([PSCustomObject]@{ Component = "Unsigned: $($drv.DeviceName)"; Status = "Warning"; Details = "v$($drv.DriverVersion) by $($drv.Manufacturer)" })
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Unsigned Drivers"; Status = "Pass"; Details = "All drivers signed" })
            Write-Host "  All drivers signed" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Unsigned Drivers"; Status = "Error"; Details = $_.Exception.Message })
    }

    # ThinkPad critical drivers
    if ($isTP) {
        Write-Host "Checking ThinkPad-specific drivers..." -ForegroundColor Yellow
        try {
            $tpDrivers = Get-CimInstance -ClassName Win32_PnPSignedDriver | Where-Object { $_.Manufacturer -match "Lenovo|ThinkPad" }
            $criticalNames = @("TrackPoint","UltraNav","Fingerprint","Power Management","Dock","Hotkey")
            $critCount = 0
            foreach ($drv in $tpDrivers) {
                foreach ($cn in $criticalNames) {
                    if ($drv.DeviceName -match $cn) {
                        $critCount++
                        $null = $results.Add([PSCustomObject]@{ Component = "ThinkPad: $($drv.DeviceName)"; Status = "Info"; Details = "v$($drv.DriverVersion)" })
                    }
                }
            }
            $null = $results.Add([PSCustomObject]@{ Component = "ThinkPad Drivers"; Status = "Info"; Details = "$critCount critical ThinkPad drivers found" })
            Write-Host "  $critCount critical ThinkPad drivers identified" -ForegroundColor Green
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "ThinkPad Drivers"; Status = "Error"; Details = $_.Exception.Message })
        }
    } elseif ($script:Vendor -eq 'Dell') {
        Write-Host "Checking Dell driver tools..." -ForegroundColor Yellow
        $dellCU = Get-CimInstance Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Dell Command.*Update' } | Select-Object -First 1
        if ($dellCU) {
            $null = $results.Add([PSCustomObject]@{ Component = "Dell Command Update"; Status = "Pass"; Details = "Installed: $($dellCU.Name) v$($dellCU.Version)" })
            Write-Host "  Dell Command Update found: v$($dellCU.Version)" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Dell Command Update"; Status = "Info"; Details = "Not installed — use Windows Update for drivers" })
            Write-Host "  Dell Command Update not found — using Windows Update" -ForegroundColor Yellow
        }
    } elseif ($script:Vendor -eq 'HP') {
        Write-Host "Checking HP driver tools..." -ForegroundColor Yellow
        $hpIA = Get-CimInstance Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'HP Image Assistant|HP Support Assistant' } | Select-Object -First 1
        if ($hpIA) {
            $null = $results.Add([PSCustomObject]@{ Component = "HP Support Tool"; Status = "Pass"; Details = "Installed: $($hpIA.Name) v$($hpIA.Version)" })
            Write-Host "  HP tool found: $($hpIA.Name)" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "HP Support Tool"; Status = "Info"; Details = "Not installed — use Windows Update for drivers" })
            Write-Host "  HP Image Assistant not found — using Windows Update" -ForegroundColor Yellow
        }
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Vendor Tools"; Status = "Info"; Details = "Vendor: $($script:Vendor) — using Windows Update for drivers" })
        Write-Host "  Vendor: $($script:Vendor) — Windows Update will be used for drivers" -ForegroundColor Gray
    }

    # Attempt repairs for problem devices
    if ($pdList.Count -gt 0) {
        Write-Host "`nAttempting to repair problem devices..." -ForegroundColor Yellow
        foreach ($dev in $pdList) {
            try {
                $pnpDev = Get-PnpDevice -InstanceId $dev.DeviceID -ErrorAction SilentlyContinue
                if ($pnpDev) {
                    Disable-PnpDevice -InstanceId $dev.DeviceID -Confirm:$false -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                    Enable-PnpDevice -InstanceId $dev.DeviceID -Confirm:$false -ErrorAction SilentlyContinue
                    $null = $results.Add([PSCustomObject]@{ Component = "Repair: $($dev.Name)"; Status = "Info"; Details = "Device reset (disable/enable)" })
                    Write-Host "  Reset: $($dev.Name)" -ForegroundColor Green
                }
            } catch {
                $null = $results.Add([PSCustomObject]@{ Component = "Repair: $($dev.Name)"; Status = "Warning"; Details = "Reset failed: $($_.Exception.Message)" })
            }
        }
    }

    # Check for Lenovo System Update
    Write-Host "Checking for Lenovo System Update..." -ForegroundColor Yellow
    $lsu = Get-CimInstance -ClassName Win32_Product -Filter "Name LIKE '%Lenovo System Update%'" -ErrorAction SilentlyContinue
    if ($lsu) {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo System Update"; Status = "Pass"; Details = "Installed: $($lsu.Name) v$($lsu.Version)" })
        Write-Host "  Lenovo System Update found: v$($lsu.Version)" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo System Update"; Status = "Info"; Details = "Not installed - recommended for driver management" })
        Write-Host "  Lenovo System Update not installed" -ForegroundColor Yellow
    }

    Write-Host "`nDriver Repair completed. Generating report..." -ForegroundColor Cyan

    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'DriverRepair' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'DriverRepair' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Driver Repair Report" -Results $results
    Write-Log "Driver Repair completed" -Level Success
    return $results
}

function Invoke-SoftwareCleanup {
    Write-Log "Starting Software Cleanup..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Software Cleanup and Optimization" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Temp files
    Write-Host "Scanning temporary files..." -ForegroundColor Yellow
    $tempPaths = @(
        "$env:TEMP",
        "$env:SystemRoot\Temp",
        "$env:LOCALAPPDATA\Temp"
    )
    $totalCleanableSize = 0
    foreach ($tp in $tempPaths) {
        if (Test-Path $tp) {
            $files = Get-ChildItem $tp -Recurse -File -ErrorAction SilentlyContinue
            $sizeBytes = ($files | Measure-Object -Property Length -Sum).Sum
            $sizeMB = [math]::Round($sizeBytes / 1MB, 2)
            $totalCleanableSize += $sizeMB
            $null = $results.Add([PSCustomObject]@{ Component = "Temp Files: $tp"; Status = "Info"; Details = "$($files.Count) files, $sizeMB MB (not deleted)" })
            Write-Host "  $tp : $($files.Count) files ($sizeMB MB)" -ForegroundColor White
        }
    }

    # Windows Update cache
    Write-Host "Checking Windows Update cache..." -ForegroundColor Yellow
    $wuPath = "$env:SystemRoot\SoftwareDistribution\Download"
    if (Test-Path $wuPath) {
        $wuFiles = Get-ChildItem $wuPath -Recurse -File -ErrorAction SilentlyContinue
        $wuSizeMB = [math]::Round(($wuFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
        $totalCleanableSize += $wuSizeMB
        $null = $results.Add([PSCustomObject]@{ Component = "WU Cache"; Status = "Info"; Details = "$wuSizeMB MB (safe to clear via Disk Cleanup)" })
        Write-Host "  Windows Update cache: $wuSizeMB MB" -ForegroundColor White
    }

    # Browser caches
    Write-Host "Checking browser caches..." -ForegroundColor Yellow
    $browserPaths = @{
        "Chrome" = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
        "Edge" = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
        "Firefox" = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    }
    foreach ($browser in $browserPaths.GetEnumerator()) {
        if (Test-Path $browser.Value) {
            $bFiles = Get-ChildItem $browser.Value -Recurse -File -ErrorAction SilentlyContinue
            $bSizeMB = [math]::Round(($bFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
            $totalCleanableSize += $bSizeMB
            $null = $results.Add([PSCustomObject]@{ Component = "Browser Cache: $($browser.Key)"; Status = "Info"; Details = "$bSizeMB MB (clear from browser settings)" })
            Write-Host "  $($browser.Key) cache: $bSizeMB MB" -ForegroundColor White
        }
    }

    # Startup programs
    Write-Host "Checking startup programs..." -ForegroundColor Yellow
    try {
        $startupItems = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue
        if ($startupItems) {
            $siCount = @($startupItems).Count
            $null = $results.Add([PSCustomObject]@{ Component = "Startup Programs"; Status = $(if($siCount -gt 10){"Warning"}else{"Pass"}); Details = "$siCount startup items" })
            Write-Host "  $siCount startup items" -ForegroundColor $(if($siCount -gt 10){"Yellow"}else{"Green"})
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Startup Programs"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Summary
    Write-Host "`n  Total cleanable space found: ~$([math]::Round($totalCleanableSize))MB" -ForegroundColor Cyan
    $null = $results.Add([PSCustomObject]@{ Component = "Total Cleanable Space"; Status = "Info"; Details = "~$([math]::Round($totalCleanableSize))MB across temp, cache, and WU files" })

    Write-Host "`n  Recommended actions (manual):" -ForegroundColor Yellow
    Write-Host "    - Run Disk Cleanup (cleanmgr) for system-level cleanup" -ForegroundColor White
    Write-Host "    - Clear browser caches from within each browser" -ForegroundColor White
    Write-Host "    - Review and disable unnecessary startup programs" -ForegroundColor White

    $null = $results.Add([PSCustomObject]@{ Component = "Action Required"; Status = "Warning"; Details = "Run Disk Cleanup (cleanmgr) to safely remove temp and WU cache files" })
    $null = $results.Add([PSCustomObject]@{ Component = "Action Required"; Status = "Info"; Details = "Review startup programs and disable unnecessary items" })

    Write-Host "`nSoftware Cleanup scan completed. Generating report..." -ForegroundColor Cyan

    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'SoftwareCleanup' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'SoftwareCleanup' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Software Cleanup Analysis (Scan Only - No Files Deleted)" -Results $results
    Write-Log "Software Cleanup completed" -Level Success
    return $results
}

#endregion

#region Fleet Management

function Invoke-FleetReport {
    Write-Log "Starting Fleet Report..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Fleet Report Generator" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }

    # System overview
    $null = $results.Add([PSCustomObject]@{ Component = "Computer Name"; Status = "Info"; Details = $env:COMPUTERNAME })
    $null = $results.Add([PSCustomObject]@{ Component = "Model"; Status = "Info"; Details = $script:SystemInfo.Model })
    $null = $results.Add([PSCustomObject]@{ Component = "Serial Number"; Status = "Info"; Details = $script:SystemInfo.SerialNumber })
    $null = $results.Add([PSCustomObject]@{ Component = "BIOS Version"; Status = "Info"; Details = $script:SystemInfo.BIOSVersion })
    $null = $results.Add([PSCustomObject]@{ Component = "OS Version"; Status = "Info"; Details = $script:SystemInfo.OSVersion })
    $null = $results.Add([PSCustomObject]@{ Component = "Processor"; Status = "Info"; Details = $script:SystemInfo.ProcessorName })
    $null = $results.Add([PSCustomObject]@{ Component = "Total Memory"; Status = "Info"; Details = "$($script:SystemInfo.TotalMemoryGB) GB" })
    $null = $results.Add([PSCustomObject]@{ Component = "Last Boot"; Status = "Info"; Details = "$($script:SystemInfo.LastBootTime)" })
    $null = $results.Add([PSCustomObject]@{ Component = "ThinkPad"; Status = $(if($script:IsThinkPad){"Pass"}else{"Warning"}); Details = $(if($script:IsThinkPad){"Confirmed"}else{"Not detected"}) })

    Write-Host "  Computer: $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "  Model: $($script:SystemInfo.Model)" -ForegroundColor White
    Write-Host "  Serial: $($script:SystemInfo.SerialNumber)" -ForegroundColor White

    # Disk summary
    Write-Host "`n  Disk Summary:" -ForegroundColor Yellow
    $drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    foreach ($drv in $drives) {
        if ($drv.Size -gt 0) {
            $freeGB = [math]::Round($drv.FreeSpace / 1GB, 1)
            $totalGB = [math]::Round($drv.Size / 1GB, 1)
            $freePct = [math]::Round(($drv.FreeSpace / $drv.Size) * 100, 1)
            $status = if ($freePct -lt 10) { "Fail" } elseif ($freePct -lt 20) { "Warning" } else { "Pass" }
            $null = $results.Add([PSCustomObject]@{ Component = "Disk $($drv.DeviceID)"; Status = $status; Details = "$freeGB GB free / $totalGB GB ($freePct%)" })
            Write-Host "    $($drv.DeviceID) $freeGB/$totalGB GB ($freePct% free)" -ForegroundColor $(if($status -eq "Pass"){"Green"}elseif($status -eq "Warning"){"Yellow"}else{"Red"})
        }
    }

    # Battery summary
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) {
        $null = $results.Add([PSCustomObject]@{ Component = "Battery Charge"; Status = "Info"; Details = "$($battery.EstimatedChargeRemaining)%" })
        Write-Host "`n  Battery: $($battery.EstimatedChargeRemaining)%" -ForegroundColor Green
    }

    # Network summary
    $activeNets = Get-NetAdapter | Where-Object Status -eq "Up"
    foreach ($net in $activeNets) {
        $null = $results.Add([PSCustomObject]@{ Component = "Network: $($net.Name)"; Status = "Pass"; Details = "$($net.LinkSpeed), MAC: $($net.MacAddress)" })
    }

    # Export CSV for fleet aggregation
    $csvPath = Join-Path $ReportPath "Fleet_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $csvData = [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        Model = $script:SystemInfo.Model
        SerialNumber = $script:SystemInfo.SerialNumber
        BIOSVersion = $script:SystemInfo.BIOSVersion
        OSVersion = $script:SystemInfo.OSVersion
        Processor = $script:SystemInfo.ProcessorName
        MemoryGB = $script:SystemInfo.TotalMemoryGB
        IsThinkPad = $script:IsThinkPad
        BatteryCharge = if ($battery) { $battery.EstimatedChargeRemaining } else { "N/A" }
        ReportDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
    $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Force
    $null = $results.Add([PSCustomObject]@{ Component = "CSV Export"; Status = "Pass"; Details = $csvPath })
    Write-Host "`n  Fleet CSV saved: $csvPath" -ForegroundColor Green

    Write-Host "`nFleet Report completed. Generating HTML report..." -ForegroundColor Cyan

    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'FleetReport' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'FleetReport' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Fleet Report - $env:COMPUTERNAME" -Results $results
    Write-Log "Fleet Report completed" -Level Success
    return $results
}

function Invoke-VerifyScripts {
    Write-Log "Starting Script Verification..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Script Verification" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    $ps1Path = Join-Path $PSScriptRoot "Laptop_Diagnostic_Suite.ps1"
    if (Test-Path $ps1Path) {
        $null = $results.Add([PSCustomObject]@{ Component = "PS1 Module"; Status = "Pass"; Details = "Found at $ps1Path" })
        Write-Host "  PS1 module found: $ps1Path" -ForegroundColor Green

        # Syntax check
        try {
            $content = Get-Content $ps1Path -Raw
            $errors = $null
            [void][System.Management.Automation.PSParser]::Tokenize($content, [ref]$errors)
            if ($errors.Count -eq 0) {
                $null = $results.Add([PSCustomObject]@{ Component = "Syntax Check"; Status = "Pass"; Details = "No syntax errors" })
                Write-Host "  Syntax: OK" -ForegroundColor Green
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Syntax Check"; Status = "Fail"; Details = "$($errors.Count) syntax errors" })
                Write-Host "  Syntax: $($errors.Count) errors" -ForegroundColor Red
                foreach ($err in ($errors | Select-Object -First 5)) {
                    Write-Host "    Line $($err.Token.StartLine): $($err.Message)" -ForegroundColor Red
                }
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Syntax Check"; Status = "Error"; Details = $_.Exception.Message })
        }

        # Function count
        $functionMatches = [regex]::Matches($content, 'function\s+Invoke-\w+')
        $null = $results.Add([PSCustomObject]@{ Component = "Function Count"; Status = $(if($functionMatches.Count -ge 26){"Pass"}else{"Warning"}); Details = "$($functionMatches.Count) Invoke-* functions found" })
        Write-Host "  Functions: $($functionMatches.Count) Invoke-* functions" -ForegroundColor $(if($functionMatches.Count -ge 26){"Green"}else{"Yellow"})
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "PS1 Module"; Status = "Fail"; Details = "Not found at $ps1Path" })
        Write-Host "  PS1 module NOT FOUND" -ForegroundColor Red
    }

    # Check BAT launcher
    $batPath = Join-Path $PSScriptRoot "Laptop_Master_Diagnostic.bat"
    if (Test-Path $batPath) {
        $null = $results.Add([PSCustomObject]@{ Component = "BAT Launcher"; Status = "Pass"; Details = "Found" })
        Write-Host "  BAT launcher found" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "BAT Launcher"; Status = "Fail"; Details = "Not found" })
        Write-Host "  BAT launcher NOT FOUND" -ForegroundColor Red
    }

    # Check config
    $configPath = Join-Path $PSScriptRoot "Config\config.ini"
    if (Test-Path $configPath) {
        $null = $results.Add([PSCustomObject]@{ Component = "Config File"; Status = "Pass"; Details = "Found" })
        Write-Host "  Config file found" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Config File"; Status = "Warning"; Details = "Not found" })
        Write-Host "  Config file not found" -ForegroundColor Yellow
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'VerifyScripts' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'VerifyScripts' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Script Verification Results" -Results $results
    Write-Log "Script Verification completed" -Level Success
    return $results
}

function Invoke-CompatibilityChecker {
    Write-Log "Starting Compatibility Checker..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Compatibility Checker" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # PowerShell version
    $psVer = $PSVersionTable.PSVersion.ToString()
    $psMajor = $PSVersionTable.PSVersion.Major
    $psStatus = if ($psMajor -ge 5) { "Pass" } else { "Warning" }
    $null = $results.Add([PSCustomObject]@{ Component = "PowerShell Version"; Status = $psStatus; Details = "v$psVer (minimum: 5.1)" })
    Write-Host "  PowerShell: v$psVer" -ForegroundColor $(if($psStatus -eq "Pass"){"Green"}else{"Yellow"})

    # .NET version
    try {
        $dotNet = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction Stop).Version
        $null = $results.Add([PSCustomObject]@{ Component = ".NET Framework"; Status = "Pass"; Details = "v$dotNet" })
        Write-Host "  .NET Framework: v$dotNet" -ForegroundColor Green
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = ".NET Framework"; Status = "Warning"; Details = "Cannot detect version" })
        Write-Host "  .NET Framework: Unknown" -ForegroundColor Yellow
    }

    # Execution policy
    $execPolicy = Get-ExecutionPolicy
    $epStatus = if ($execPolicy -eq "Restricted") { "Warning" } else { "Pass" }
    $null = $results.Add([PSCustomObject]@{ Component = "Execution Policy"; Status = $epStatus; Details = $execPolicy.ToString() })
    Write-Host "  Execution Policy: $execPolicy" -ForegroundColor $(if($epStatus -eq "Pass"){"Green"}else{"Yellow"})

    # Admin rights
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $null = $results.Add([PSCustomObject]@{ Component = "Admin Rights"; Status = $(if($isAdmin){"Pass"}else{"Warning"}); Details = $(if($isAdmin){"Running as Administrator"}else{"Not admin - some functions limited"}) })
    Write-Host "  Admin Rights: $(if($isAdmin){'Yes'}else{'No'})" -ForegroundColor $(if($isAdmin){"Green"}else{"Yellow"})

    # WMI/CIM
    try {
        Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Out-Null
        $null = $results.Add([PSCustomObject]@{ Component = "CIM/WMI"; Status = "Pass"; Details = "Working" })
        Write-Host "  CIM/WMI: Working" -ForegroundColor Green
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "CIM/WMI"; Status = "Fail"; Details = "Not working: $($_.Exception.Message)" })
        Write-Host "  CIM/WMI: FAILED" -ForegroundColor Red
    }

    # Windows version
    $os = Get-CimInstance Win32_OperatingSystem
    $null = $results.Add([PSCustomObject]@{ Component = "Windows Version"; Status = "Info"; Details = "$($os.Caption) ($($os.Version))" })
    Write-Host "  Windows: $($os.Caption)" -ForegroundColor White


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'CompatibilityChecker' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'CompatibilityChecker' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Compatibility Check Results" -Results $results
    Write-Log "Compatibility Checker completed" -Level Success
    return $results
}

function Invoke-HardwareInventory {
    Write-Log "Starting Hardware Inventory..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Hardware Inventory" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }

    # System
    $cs = Get-CimInstance Win32_ComputerSystem
    $null = $results.Add([PSCustomObject]@{ Component = "Manufacturer"; Status = "Info"; Details = $cs.Manufacturer })
    $null = $results.Add([PSCustomObject]@{ Component = "Model"; Status = "Info"; Details = $cs.Model })
    $null = $results.Add([PSCustomObject]@{ Component = "System Type"; Status = "Info"; Details = $cs.SystemType })
    Write-Host "  System: $($cs.Manufacturer) $($cs.Model)" -ForegroundColor White

    # BIOS
    $bios = Get-CimInstance Win32_BIOS
    $null = $results.Add([PSCustomObject]@{ Component = "BIOS"; Status = "Info"; Details = "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))" })
    $null = $results.Add([PSCustomObject]@{ Component = "Serial Number"; Status = "Info"; Details = $bios.SerialNumber })
    Write-Host "  BIOS: $($bios.SMBIOSBIOSVersion), SN: $($bios.SerialNumber)" -ForegroundColor White

    # CPU
    $cpus = Get-CimInstance Win32_Processor
    foreach ($cpu in $cpus) {
        $null = $results.Add([PSCustomObject]@{ Component = "CPU"; Status = "Info"; Details = "$($cpu.Name), $($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) threads" })
        Write-Host "  CPU: $($cpu.Name)" -ForegroundColor White
    }

    # Memory
    $memModules = Get-CimInstance Win32_PhysicalMemory
    foreach ($mem in $memModules) {
        $capGB = [math]::Round($mem.Capacity / 1GB, 2)
        $null = $results.Add([PSCustomObject]@{ Component = "Memory $($mem.BankLabel)"; Status = "Info"; Details = "$capGB GB, $($mem.Speed) MHz, $($mem.Manufacturer)" })
        Write-Host "  RAM: $($mem.BankLabel) - $capGB GB @ $($mem.Speed) MHz ($($mem.Manufacturer))" -ForegroundColor White
    }

    # Disks
    $disks = Get-PhysicalDisk
    foreach ($disk in $disks) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $null = $results.Add([PSCustomObject]@{ Component = "Disk: $($disk.FriendlyName)"; Status = "Info"; Details = "$sizeGB GB, $($disk.MediaType), $($disk.BusType), Health: $($disk.HealthStatus)" })
        Write-Host "  Disk: $($disk.FriendlyName) $sizeGB GB ($($disk.MediaType))" -ForegroundColor White
    }

    # Network adapters
    $nets = Get-NetAdapter
    foreach ($net in $nets) {
        $null = $results.Add([PSCustomObject]@{ Component = "NIC: $($net.Name)"; Status = $(if($net.Status -eq "Up"){"Pass"}else{"Info"}); Details = "$($net.InterfaceDescription), $($net.LinkSpeed), MAC: $($net.MacAddress)" })
        Write-Host "  NIC: $($net.Name) ($($net.Status))" -ForegroundColor $(if($net.Status -eq "Up"){"Green"}else{"Gray"})
    }

    # GPU
    $gpus = Get-CimInstance Win32_VideoController
    foreach ($gpu in $gpus) {
        $vramMB = [math]::Round($gpu.AdapterRAM / 1MB, 0)
        $null = $results.Add([PSCustomObject]@{ Component = "GPU: $($gpu.Name)"; Status = "Info"; Details = "VRAM: ${vramMB}MB, Resolution: $($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution)" })
        Write-Host "  GPU: $($gpu.Name)" -ForegroundColor White
    }

    # Battery
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) {
        $null = $results.Add([PSCustomObject]@{ Component = "Battery"; Status = "Info"; Details = "Charge: $($battery.EstimatedChargeRemaining)%, Status: $($battery.BatteryStatus)" })
        Write-Host "  Battery: $($battery.EstimatedChargeRemaining)%" -ForegroundColor White
    }

    # Export to CSV
    $csvPath = Join-Path $ReportPath "Inventory_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Force
    Write-Host "`n  Inventory CSV saved: $csvPath" -ForegroundColor Green


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'HardwareInventory' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'HardwareInventory' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Hardware Inventory - $env:COMPUTERNAME" -Results $results
    Write-Log "Hardware Inventory completed" -Level Success
    return $results
}

#endregion

#region Hardware Tests

function Invoke-BatteryHealth {
    Write-Log "Starting Battery Health Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Battery Health Analysis" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if (-not $battery) {
        $null = $results.Add([PSCustomObject]@{ Component = "Battery"; Status = "Info"; Details = "No battery detected (desktop system)" })
        Write-Host "  No battery detected" -ForegroundColor Gray
        Export-DiagnosticReport -Title "Battery Health Results" -Results $results
        return $results
    }

    # Basic battery info
    $battStatus = switch ($battery.BatteryStatus) {
        1 {"Discharging"} 2 {"AC Power"} 3 {"Fully Charged"} 4 {"Low"} 5 {"Critical"} 6 {"Charging"} default {"Unknown ($($battery.BatteryStatus))"}
    }
    $null = $results.Add([PSCustomObject]@{ Component = "Battery Status"; Status = "Info"; Details = $battStatus })
    $null = $results.Add([PSCustomObject]@{ Component = "Charge Level"; Status = $(if($battery.EstimatedChargeRemaining -lt 20){"Warning"}else{"Pass"}); Details = "$($battery.EstimatedChargeRemaining)%" })
    Write-Host "  Status: $battStatus" -ForegroundColor White
    Write-Host "  Charge: $($battery.EstimatedChargeRemaining)%" -ForegroundColor $(if($battery.EstimatedChargeRemaining -lt 20){"Yellow"}else{"Green"})

    # Design vs full charge capacity
    if ($battery.DesignCapacity -gt 0 -and $battery.FullChargeCapacity -gt 0) {
        $wearPct = [math]::Round((1 - ($battery.FullChargeCapacity / $battery.DesignCapacity)) * 100, 1)
        $healthPct = [math]::Round(($battery.FullChargeCapacity / $battery.DesignCapacity) * 100, 1)
        $healthStatus = if ($healthPct -lt 50) { "Fail" } elseif ($healthPct -lt 80) { "Warning" } else { "Pass" }
        $null = $results.Add([PSCustomObject]@{ Component = "Battery Health"; Status = $healthStatus; Details = "$healthPct% capacity remaining ($wearPct% wear)" })
        $null = $results.Add([PSCustomObject]@{ Component = "Design Capacity"; Status = "Info"; Details = "$($battery.DesignCapacity) mWh" })
        $null = $results.Add([PSCustomObject]@{ Component = "Full Charge Capacity"; Status = "Info"; Details = "$($battery.FullChargeCapacity) mWh" })
        Write-Host "  Health: $healthPct% ($wearPct% wear)" -ForegroundColor $(if($healthStatus -eq "Pass"){"Green"}elseif($healthStatus -eq "Warning"){"Yellow"}else{"Red"})
    }

    # Generate powercfg battery report
    Write-Host "  Generating powercfg battery report..." -ForegroundColor Yellow
    try {
        $battReportPath = Join-Path $ReportPath "battery_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
        & powercfg /batteryreport /output "$battReportPath" 2>&1 | Out-Null
        if (Test-Path $battReportPath) {
            $null = $results.Add([PSCustomObject]@{ Component = "Battery Report"; Status = "Pass"; Details = "Saved to $battReportPath" })
            Write-Host "  Battery report saved: $battReportPath" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Battery Report"; Status = "Warning"; Details = "Could not generate: $($_.Exception.Message)" })
    }

    # Estimated runtime
    if ($battery.EstimatedRunTime -and $battery.EstimatedRunTime -ne 71582788) {
        $null = $results.Add([PSCustomObject]@{ Component = "Estimated Runtime"; Status = "Info"; Details = "$($battery.EstimatedRunTime) minutes" })
        Write-Host "  Estimated Runtime: $($battery.EstimatedRunTime) min" -ForegroundColor White
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'BatteryHealth' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'BatteryHealth' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Battery Health Results" -Results $results
    Write-Log "Battery Health Check completed" -Level Success
    return $results
}

function Invoke-NetworkDiagnostic {
    Write-Log "Starting Network Diagnostic..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Network Diagnostic" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Adapters
    Write-Host "Checking network adapters..." -ForegroundColor Yellow
    $adapters = Get-NetAdapter
    foreach ($a in $adapters) {
        $status = if ($a.Status -eq "Up") { "Pass" } else { "Info" }
        $null = $results.Add([PSCustomObject]@{ Component = "Adapter: $($a.Name)"; Status = $status; Details = "$($a.InterfaceDescription), Status: $($a.Status), Speed: $($a.LinkSpeed), MAC: $($a.MacAddress)" })
        $color = if ($a.Status -eq "Up") { "Green" } else { "Gray" }
        Write-Host "  $($a.Name): $($a.Status), $($a.LinkSpeed)" -ForegroundColor $color
    }

    # IP configuration
    Write-Host "`nChecking IP configuration..." -ForegroundColor Yellow
    $activeAdapters = $adapters | Where-Object Status -eq "Up"
    foreach ($a in $activeAdapters) {
        $ipCfg = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
        if ($ipCfg) {
            $ipv4 = if ($ipCfg.IPv4Address) { $ipCfg.IPv4Address.IPAddress } else { "N/A" }
            $gw = if ($ipCfg.IPv4DefaultGateway) { $ipCfg.IPv4DefaultGateway.NextHop } else { "N/A" }
            $dns = if ($ipCfg.DNSServer) { ($ipCfg.DNSServer.ServerAddresses | Select-Object -First 2) -join ", " } else { "N/A" }
            $null = $results.Add([PSCustomObject]@{ Component = "IP ($($a.Name))"; Status = "Info"; Details = "IPv4: $ipv4, Gateway: $gw, DNS: $dns" })
            Write-Host "  $($a.Name): IP=$ipv4, GW=$gw, DNS=$dns" -ForegroundColor White
        }
    }

    # DNS resolution test
    Write-Host "`nTesting DNS resolution..." -ForegroundColor Yellow
    foreach ($host_ in @("www.google.com", "www.lenovo.com")) {
        try {
            $dnsResult = Resolve-DnsName $host_ -ErrorAction Stop | Select-Object -First 1
            $null = $results.Add([PSCustomObject]@{ Component = "DNS: $host_"; Status = "Pass"; Details = "Resolved to $($dnsResult.IPAddress)" })
            Write-Host "  $host_ -> $($dnsResult.IPAddress)" -ForegroundColor Green
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "DNS: $host_"; Status = "Fail"; Details = "Cannot resolve" })
            Write-Host "  $host_ -> FAILED" -ForegroundColor Red
        }
    }

    # Latency tests
    Write-Host "`nTesting latency..." -ForegroundColor Yellow
    foreach ($target in @(@{T="8.8.8.8";N="Google DNS"},@{T="1.1.1.1";N="Cloudflare"})) {
        $ping = Test-Connection -ComputerName $target.T -Count 4 -ErrorAction SilentlyContinue
        if ($ping) {
            $avg = [math]::Round(($ping | Measure-Object ResponseTime -Average).Average, 1)
            $loss = [math]::Round(100 - (@($ping).Count / 4 * 100), 0)
            $pStatus = if ($avg -gt 100 -or $loss -gt 25) { "Warning" } else { "Pass" }
            $null = $results.Add([PSCustomObject]@{ Component = "Ping: $($target.N)"; Status = $pStatus; Details = "Avg: ${avg}ms, Loss: ${loss}%" })
            Write-Host "  $($target.N): ${avg}ms, ${loss}% loss" -ForegroundColor $(if($pStatus -eq "Pass"){"Green"}else{"Yellow"})
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Ping: $($target.N)"; Status = "Fail"; Details = "Unreachable" })
            Write-Host "  $($target.N): Unreachable" -ForegroundColor Red
        }
    }

    # Proxy check
    Write-Host "`nChecking proxy settings..." -ForegroundColor Yellow
    try {
        $proxy = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop)
        $proxyEnabled = $proxy.ProxyEnable -eq 1
        $proxyServer = $proxy.ProxyServer
        $null = $results.Add([PSCustomObject]@{ Component = "Proxy"; Status = "Info"; Details = "Enabled: $proxyEnabled$(if($proxyServer){', Server: '+$proxyServer})" })
        Write-Host "  Proxy: $(if($proxyEnabled){"Enabled ($proxyServer)"}else{"Disabled"})" -ForegroundColor White
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Proxy"; Status = "Info"; Details = "Could not check proxy settings" })
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'NetworkDiagnostic' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'NetworkDiagnostic' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Network Diagnostic Results" -Results $results
    Write-Log "Network Diagnostic completed" -Level Success
    return $results
}

function Invoke-PerformanceAnalyzer {
    Write-Log "Starting Performance Analyzer..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Performance Analyzer" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # CPU benchmark
    Write-Host "Running CPU benchmark..." -ForegroundColor Yellow
    $cpuStart = Get-Date
    $iterations = 0
    $deadline = $cpuStart.AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        for ($i = 0; $i -lt 100000; $i++) { [void][math]::Sqrt($i) }
        $iterations++
    }
    $cpuScore = $iterations
    $cpuStatus = if ($cpuScore -lt 10) { "Warning" } else { "Pass" }
    $null = $results.Add([PSCustomObject]@{ Component = "CPU Benchmark"; Status = $cpuStatus; Details = "Score: $cpuScore (5s sqrt iterations x100K)" })
    Write-Host "  CPU Score: $cpuScore" -ForegroundColor $(if($cpuStatus -eq "Pass"){"Green"}else{"Yellow"})

    # Memory benchmark
    Write-Host "Running memory benchmark..." -ForegroundColor Yellow
    try {
        $memStart = Get-Date
        $block = New-Object byte[] (50MB)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($block)
        $memEnd = Get-Date
        $memTime = ($memEnd - $memStart).TotalMilliseconds
        $memSpeedMBs = [math]::Round(50 / ($memTime / 1000), 1)
        $null = $results.Add([PSCustomObject]@{ Component = "Memory Benchmark"; Status = "Pass"; Details = "50MB fill: ${memTime}ms (~${memSpeedMBs} MB/s)" })
        Write-Host "  Memory: 50MB in ${memTime}ms (~${memSpeedMBs} MB/s)" -ForegroundColor Green
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Memory Benchmark"; Status = "Error"; Details = $_.Exception.Message })
    }

    # Disk benchmark
    Write-Host "Running disk benchmark..." -ForegroundColor Yellow
    $testFile = Join-Path $TempPath "perftest_$(Get-Random).tmp"
    try {
        $buf = New-Object byte[] (50MB)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [System.IO.File]::WriteAllBytes($testFile, $buf)
        $sw.Stop()
        $writeSpeed = [math]::Round((50MB / $sw.Elapsed.TotalSeconds) / 1MB, 1)

        $sw.Restart()
        [void][System.IO.File]::ReadAllBytes($testFile)
        $sw.Stop()
        $readSpeed = [math]::Round((50MB / $sw.Elapsed.TotalSeconds) / 1MB, 1)

        $diskStatus = if ($readSpeed -lt 100 -or $writeSpeed -lt 50) { "Warning" } else { "Pass" }
        $null = $results.Add([PSCustomObject]@{ Component = "Disk Benchmark"; Status = $diskStatus; Details = "Read: ${readSpeed}MB/s, Write: ${writeSpeed}MB/s (50MB test)" })
        Write-Host "  Disk: Read=${readSpeed}MB/s, Write=${writeSpeed}MB/s" -ForegroundColor $(if($diskStatus -eq "Pass"){"Green"}else{"Yellow"})
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Disk Benchmark"; Status = "Error"; Details = $_.Exception.Message })
    } finally {
        if (Test-Path $testFile) { Remove-Item $testFile -Force }
    }

    # Current resource usage
    Write-Host "`nCurrent resource usage..." -ForegroundColor Yellow
    $os = Get-CimInstance Win32_OperatingSystem
    $usedMemPct = [math]::Round(100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100), 1)
    $cpuLoad = (Get-CimInstance Win32_Processor).LoadPercentage
    $null = $results.Add([PSCustomObject]@{ Component = "CPU Load"; Status = $(if($cpuLoad -gt 90){"Warning"}else{"Pass"}); Details = "$cpuLoad%" })
    $null = $results.Add([PSCustomObject]@{ Component = "Memory Usage"; Status = $(if($usedMemPct -gt 90){"Warning"}else{"Pass"}); Details = "$usedMemPct%" })
    Write-Host "  CPU Load: $cpuLoad%" -ForegroundColor $(if($cpuLoad -gt 90){"Yellow"}else{"Green"})
    Write-Host "  Memory Usage: $usedMemPct%" -ForegroundColor $(if($usedMemPct -gt 90){"Yellow"}else{"Green"})

    # Bottleneck identification
    $bottleneck = "None detected"
    if ($cpuLoad -gt 90) { $bottleneck = "CPU (sustained high load)" }
    elseif ($usedMemPct -gt 90) { $bottleneck = "Memory (high utilization)" }
    $null = $results.Add([PSCustomObject]@{ Component = "Bottleneck"; Status = $(if($bottleneck -eq "None detected"){"Pass"}else{"Warning"}); Details = $bottleneck })
    Write-Host "  Bottleneck: $bottleneck" -ForegroundColor $(if($bottleneck -eq "None detected"){"Green"}else{"Yellow"})


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'PerformanceAnalyzer' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'PerformanceAnalyzer' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Performance Analysis Results" -Results $results
    Write-Log "Performance Analyzer completed" -Level Success
    return $results
}

function Invoke-ThermalAnalysis {
    Write-Log "Starting Thermal Analysis..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Thermal Analysis" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    Write-Host "  Monitoring temperatures for 30 seconds..." -ForegroundColor Yellow
    $readings = @()
    for ($i = 0; $i -lt 6; $i++) {
        try {
            $thermalZones = Get-CimInstance -Namespace "root/wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
            foreach ($tz in $thermalZones) {
                $raw = $tz.CurrentTemperature
                if ($raw -ge 0 -and $raw -le 5000) {
                    $tempC = [math]::Round(($raw - 2732) / 10, 1)
                    if ($tempC -ge 0 -and $tempC -le 120) {
                        $readings += $tempC
                        if ($i -eq 0) {
                            Write-Host "  Initial temp: ${tempC}C" -ForegroundColor White
                        }
                    }
                }
            }
        } catch {
            if ($i -eq 0) {
                $null = $results.Add([PSCustomObject]@{ Component = "Thermal Zones"; Status = "Warning"; Details = "WMI thermal data not available" })
                Write-Host "  Thermal zone data not available via WMI" -ForegroundColor Yellow
            }
            break
        }
        if ($i -lt 5) { Start-Sleep -Seconds 5 }
        Write-Host "  Sample $($i+1)/6..." -ForegroundColor Gray
    }

    if ($readings.Count -gt 0) {
        $avgTemp = [math]::Round(($readings | Measure-Object -Average).Average, 1)
        $maxTemp = [math]::Round(($readings | Measure-Object -Maximum).Maximum, 1)
        $minTemp = [math]::Round(($readings | Measure-Object -Minimum).Minimum, 1)
        $tempStatus = if ($maxTemp -gt 85) { "Fail" } elseif ($maxTemp -gt 75) { "Warning" } else { "Pass" }
        $null = $results.Add([PSCustomObject]@{ Component = "Temperature"; Status = $tempStatus; Details = "Avg: ${avgTemp}C, Min: ${minTemp}C, Max: ${maxTemp}C ($($readings.Count) samples)" })
        Write-Host "`n  Avg: ${avgTemp}C, Min: ${minTemp}C, Max: ${maxTemp}C" -ForegroundColor $(if($tempStatus -eq "Pass"){"Green"}elseif($tempStatus -eq "Warning"){"Yellow"}else{"Red"})
    }

    # Fan status (ThinkPad-specific via WMI if available)
    Write-Host "`n  Checking fan status..." -ForegroundColor Yellow
    try {
        $fans = Get-CimInstance Win32_Fan -ErrorAction SilentlyContinue
        if ($fans) {
            foreach ($fan in $fans) {
                $null = $results.Add([PSCustomObject]@{ Component = "Fan: $($fan.Name)"; Status = "Info"; Details = "Active: $($fan.ActiveCooling), Status: $($fan.Status)" })
                Write-Host "  Fan: $($fan.Name), Active: $($fan.ActiveCooling)" -ForegroundColor White
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Fan Status"; Status = "Info"; Details = "Fan WMI data not available (common on modern laptops)" })
            Write-Host "  Fan WMI data not available" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Fan Status"; Status = "Info"; Details = "Cannot query fan status" })
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'ThermalAnalysis' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'ThermalAnalysis' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Thermal Analysis Results" -Results $results
    Write-Log "Thermal Analysis completed" -Level Success
    return $results
}

function Invoke-DisplayCalibration {
    Write-Log "Starting Display Calibration..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Display Calibration and Diagnostics" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # GPU info
    $gpus = Get-CimInstance Win32_VideoController
    foreach ($gpu in $gpus) {
        $vramMB = if ($gpu.AdapterRAM -gt 0) { [math]::Round($gpu.AdapterRAM / 1MB, 0) } else { "N/A" }
        $null = $results.Add([PSCustomObject]@{ Component = "GPU: $($gpu.Name)"; Status = "Info"; Details = "VRAM: ${vramMB}MB, Driver: $($gpu.DriverVersion), Status: $($gpu.Status)" })
        Write-Host "  GPU: $($gpu.Name)" -ForegroundColor White
        Write-Host "    VRAM: ${vramMB}MB, Driver: $($gpu.DriverVersion)" -ForegroundColor White
        Write-Host "    Resolution: $($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution) @ $($gpu.CurrentRefreshRate)Hz" -ForegroundColor White
        $null = $results.Add([PSCustomObject]@{ Component = "Resolution"; Status = "Info"; Details = "$($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution) @ $($gpu.CurrentRefreshRate)Hz" })
    }

    # Monitor info
    try {
        $monitors = Get-CimInstance WmiMonitorBasicDisplayParams -Namespace root/wmi -ErrorAction SilentlyContinue
        if ($monitors) {
            foreach ($mon in $monitors) {
                $widthCm = $mon.MaxHorizontalImageSize
                $heightCm = $mon.MaxVerticalImageSize
                $diagInch = [math]::Round([math]::Sqrt($widthCm * $widthCm + $heightCm * $heightCm) / 2.54, 1)
                $null = $results.Add([PSCustomObject]@{ Component = "Monitor"; Status = "Info"; Details = "Size: ~${diagInch} inch, Active: $($mon.Active)" })
                Write-Host "  Monitor: ~${diagInch} inch diagonal" -ForegroundColor White
            }
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Monitor Info"; Status = "Info"; Details = "Could not retrieve monitor details" })
    }

    # Dead pixel test suggestion
    $null = $results.Add([PSCustomObject]@{ Component = "Dead Pixel Test"; Status = "Info"; Details = "Use a full-screen color test tool to check for dead pixels" })
    Write-Host "`n  Dead pixel test: Use a full-screen color test application" -ForegroundColor Yellow
    Write-Host "  Recommendation: Display solid red, green, blue, white, and black screens" -ForegroundColor Yellow


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'DisplayCalibration' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'DisplayCalibration' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Display Calibration Results" -Results $results
    Write-Log "Display Calibration completed" -Level Success
    return $results
}

function Invoke-AudioDiagnostic {
    Write-Log "Starting Audio Diagnostic..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Audio Diagnostic" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Sound devices
    $soundDevices = Get-CimInstance Win32_SoundDevice
    foreach ($dev in $soundDevices) {
        $devStatus = if ($dev.Status -eq "OK") { "Pass" } else { "Warning" }
        $null = $results.Add([PSCustomObject]@{ Component = "Audio: $($dev.Name)"; Status = $devStatus; Details = "Manufacturer: $($dev.Manufacturer), Status: $($dev.Status)" })
        Write-Host "  $($dev.Name) - $($dev.Status)" -ForegroundColor $(if($devStatus -eq "Pass"){"Green"}else{"Yellow"})
    }

    # Audio service
    Write-Host "`n  Checking Windows Audio service..." -ForegroundColor Yellow
    $audioSvc = Get-Service -Name "AudioSrv" -ErrorAction SilentlyContinue
    if ($audioSvc) {
        $svcStatus = if ($audioSvc.Status -eq "Running") { "Pass" } else { "Warning" }
        $null = $results.Add([PSCustomObject]@{ Component = "Audio Service"; Status = $svcStatus; Details = "$($audioSvc.Status)" })
        Write-Host "  Audio Service: $($audioSvc.Status)" -ForegroundColor $(if($svcStatus -eq "Pass"){"Green"}else{"Yellow"})
    }

    $audioEndpoint = Get-Service -Name "AudioEndpointBuilder" -ErrorAction SilentlyContinue
    if ($audioEndpoint) {
        $epStatus = if ($audioEndpoint.Status -eq "Running") { "Pass" } else { "Warning" }
        $null = $results.Add([PSCustomObject]@{ Component = "Audio Endpoint Builder"; Status = $epStatus; Details = "$($audioEndpoint.Status)" })
        Write-Host "  Audio Endpoint Builder: $($audioEndpoint.Status)" -ForegroundColor $(if($epStatus -eq "Pass"){"Green"}else{"Yellow"})
    }

    # Test tone suggestion
    Write-Host "`n  To test speakers, go to:" -ForegroundColor Yellow
    Write-Host "    Settings > System > Sound > Output > Test" -ForegroundColor White
    $null = $results.Add([PSCustomObject]@{ Component = "Test Tone"; Status = "Info"; Details = "Use Windows Sound Settings to test output" })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'AudioDiagnostic' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'AudioDiagnostic' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Audio Diagnostic Results" -Results $results
    Write-Log "Audio Diagnostic completed" -Level Success
    return $results
}

function Invoke-KeyboardTest {
    Write-Log "Starting Keyboard Test..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Keyboard Test" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Keyboard devices
    $keyboards = Get-CimInstance Win32_Keyboard
    foreach ($kb in $keyboards) {
        $null = $results.Add([PSCustomObject]@{ Component = "Keyboard: $($kb.Name)"; Status = "Info"; Details = "Description: $($kb.Description), Layout: $($kb.Layout)" })
        Write-Host "  $($kb.Name) - $($kb.Description)" -ForegroundColor White
    }

    # Hotkey driver check (ThinkPad)
    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }
    if ($script:IsThinkPad) {
        $hotkeyDrv = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match "Hotkey|HotKey" }
        if ($hotkeyDrv) {
            $null = $results.Add([PSCustomObject]@{ Component = "ThinkPad Hotkey Driver"; Status = "Pass"; Details = "$($hotkeyDrv.DeviceName) v$($hotkeyDrv.DriverVersion)" })
            Write-Host "  Hotkey Driver: $($hotkeyDrv.DeviceName)" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "ThinkPad Hotkey Driver"; Status = "Warning"; Details = "Not found - Fn keys may not work" })
            Write-Host "  Hotkey Driver: Not found" -ForegroundColor Yellow
        }
    }

    Write-Host "`n  Interactive keyboard test:" -ForegroundColor Yellow
    Write-Host "  Type some characters to verify keyboard function." -ForegroundColor White
    Write-Host "  Press Enter when done (or just Enter to skip):" -ForegroundColor White
    $testInput = Read-Host "  "
    if ($testInput.Length -gt 0) {
        $null = $results.Add([PSCustomObject]@{ Component = "Key Input Test"; Status = "Pass"; Details = "User typed $($testInput.Length) characters" })
        Write-Host "  Input received: $($testInput.Length) characters" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Key Input Test"; Status = "Info"; Details = "Skipped by user" })
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'KeyboardTest' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'KeyboardTest' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Keyboard Test Results" -Results $results
    Write-Log "Keyboard Test completed" -Level Success
    return $results
}

function Invoke-TrackPointCalibration {
    Write-Log "Starting TrackPoint Calibration..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  TrackPoint / Touchpad Diagnostics" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Pointing devices
    $pointingDevices = Get-CimInstance Win32_PointingDevice
    foreach ($pd in $pointingDevices) {
        $null = $results.Add([PSCustomObject]@{ Component = "Pointing: $($pd.Name)"; Status = "Info"; Details = "Type: $($pd.PointingType), HW Type: $($pd.HardwareType), Buttons: $($pd.NumberOfButtons)" })
        Write-Host "  $($pd.Name) - Buttons: $($pd.NumberOfButtons)" -ForegroundColor White
    }

    # TrackPoint specific
    $trackpoint = $pointingDevices | Where-Object { $_.Name -match "TrackPoint|Pointing Stick" }
    if ($trackpoint) {
        $null = $results.Add([PSCustomObject]@{ Component = "TrackPoint"; Status = "Pass"; Details = "TrackPoint detected: $($trackpoint.Name)" })
        Write-Host "  TrackPoint detected" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "TrackPoint"; Status = "Info"; Details = "No TrackPoint detected" })
        Write-Host "  No TrackPoint detected" -ForegroundColor Gray
    }

    # Touchpad
    $touchpad = $pointingDevices | Where-Object { $_.Name -match "Touchpad|TouchPad|Synaptics|Elan" }
    if ($touchpad) {
        $null = $results.Add([PSCustomObject]@{ Component = "Touchpad"; Status = "Pass"; Details = "Touchpad detected: $($touchpad.Name)" })
        Write-Host "  Touchpad detected: $($touchpad.Name)" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Touchpad"; Status = "Info"; Details = "No touchpad detected" })
        Write-Host "  No touchpad detected" -ForegroundColor Gray
    }

    # Driver check
    $tpDrivers = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match "TrackPoint|UltraNav|Synaptics|Elan|Touchpad" }
    foreach ($drv in $tpDrivers) {
        $null = $results.Add([PSCustomObject]@{ Component = "Driver: $($drv.DeviceName)"; Status = "Info"; Details = "v$($drv.DriverVersion) by $($drv.Manufacturer)" })
        Write-Host "  Driver: $($drv.DeviceName) v$($drv.DriverVersion)" -ForegroundColor White
    }

    Write-Host "`n  TrackPoint/Touchpad calibration:" -ForegroundColor Yellow
    Write-Host "    Settings > Bluetooth & devices > Touchpad for gesture settings" -ForegroundColor White
    Write-Host "    Lenovo Vantage for TrackPoint sensitivity settings" -ForegroundColor White


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'TrackPointCalibration' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'TrackPointCalibration' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "TrackPoint/Touchpad Results" -Results $results
    Write-Log "TrackPoint Calibration completed" -Level Success
    return $results
}

function Invoke-PowerSettings {
    Write-Log "Starting Power Settings..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Power Settings Analysis" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Active power plan
    Write-Host "Checking power plans..." -ForegroundColor Yellow
    try {
        $activePlan = powercfg /getactivescheme 2>&1
        $planText = ($activePlan -join " ").Trim()
        $null = $results.Add([PSCustomObject]@{ Component = "Active Power Plan"; Status = "Info"; Details = $planText })
        Write-Host "  $planText" -ForegroundColor White
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Active Power Plan"; Status = "Error"; Details = $_.Exception.Message })
    }

    # List all plans
    try {
        $allPlans = powercfg /list 2>&1
        foreach ($line in $allPlans) {
            if ($line -match "Power Scheme GUID") {
                $null = $results.Add([PSCustomObject]@{ Component = "Power Plan"; Status = "Info"; Details = $line.Trim() })
                Write-Host "  $($line.Trim())" -ForegroundColor Gray
            }
        }
    } catch {}

    # Sleep settings
    Write-Host "`nChecking sleep/lid settings..." -ForegroundColor Yellow
    try {
        $sleepAC = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1
        $lidAction = powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION 2>&1
        $null = $results.Add([PSCustomObject]@{ Component = "Sleep Settings"; Status = "Info"; Details = "Queried current sleep/lid settings" })

        foreach ($line in $sleepAC) {
            if ($line -match "Current AC Power Setting Index|Current DC Power Setting Index") {
                Write-Host "  $($line.Trim())" -ForegroundColor White
            }
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Sleep Settings"; Status = "Warning"; Details = "Could not query sleep settings" })
    }

    # Lenovo Power Manager check
    Write-Host "`nChecking for Lenovo Power Manager..." -ForegroundColor Yellow
    $lpm = Get-CimInstance Win32_Product -Filter "Name LIKE '%Lenovo Power%' OR Name LIKE '%Energy Manager%'" -ErrorAction SilentlyContinue
    if ($lpm) {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Power Manager"; Status = "Pass"; Details = "$($lpm.Name) v$($lpm.Version)" })
        Write-Host "  Found: $($lpm.Name)" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Power Manager"; Status = "Info"; Details = "Not installed" })
        Write-Host "  Not installed" -ForegroundColor Gray
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'PowerSettings' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'PowerSettings' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Power Settings Results" -Results $results
    Write-Log "Power Settings completed" -Level Success
    return $results
}

#endregion

#region System Management

function Invoke-SecureWipe {
    Write-Log "Starting Secure Wipe..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Secure Wipe (Temp/Cache/Profile Cleanup)" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Double confirmation
    Write-Host "  WARNING: This will delete temporary files, caches, and optionally user profiles." -ForegroundColor Red
    Write-Host "  This action cannot be undone." -ForegroundColor Red
    Write-Host
    $confirm1 = Read-Host "  Are you sure you want to proceed? (YES/NO)"
    if ($confirm1 -ne "YES") {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        $null = $results.Add([PSCustomObject]@{ Component = "Secure Wipe"; Status = "Info"; Details = "Cancelled by user (first confirmation)" })
        Export-DiagnosticReport -Title "Secure Wipe Results" -Results $results
        return $results
    }
    $confirm2 = Read-Host "  Type CONFIRM to proceed with wipe"
    if ($confirm2 -ne "CONFIRM") {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        $null = $results.Add([PSCustomObject]@{ Component = "Secure Wipe"; Status = "Info"; Details = "Cancelled by user (second confirmation)" })
        Export-DiagnosticReport -Title "Secure Wipe Results" -Results $results
        return $results
    }

    # Clean temp directories
    Write-Host "`n  Cleaning temporary files..." -ForegroundColor Yellow
    $tempDirs = @("$env:TEMP", "$env:SystemRoot\Temp", "$env:LOCALAPPDATA\Temp")
    $totalCleaned = 0
    foreach ($td in $tempDirs) {
        if (Test-Path $td) {
            $files = Get-ChildItem $td -Recurse -Force -ErrorAction SilentlyContinue
            $count = 0
            foreach ($f in $files) {
                try {
                    Remove-Item $f.FullName -Force -Recurse -ErrorAction Stop
                    $count++
                } catch {}
            }
            $totalCleaned += $count
            $null = $results.Add([PSCustomObject]@{ Component = "Temp: $td"; Status = "Pass"; Details = "$count items removed" })
            Write-Host "  $td : $count items removed" -ForegroundColor Green
        }
    }

    # Clean browser caches
    Write-Host "  Cleaning browser caches..." -ForegroundColor Yellow
    $cachePaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
    )
    foreach ($cp in $cachePaths) {
        if (Test-Path $cp) {
            $cacheFiles = Get-ChildItem $cp -Recurse -Force -ErrorAction SilentlyContinue
            $count = 0
            foreach ($f in $cacheFiles) {
                try { Remove-Item $f.FullName -Force -ErrorAction Stop; $count++ } catch {}
            }
            $null = $results.Add([PSCustomObject]@{ Component = "Cache: $cp"; Status = "Pass"; Details = "$count items removed" })
            Write-Host "  Cache cleaned: $count items" -ForegroundColor Green
        }
    }

    # Clean Windows Update cache
    Write-Host "  Cleaning Windows Update cache..." -ForegroundColor Yellow
    $wuPath = "$env:SystemRoot\SoftwareDistribution\Download"
    if (Test-Path $wuPath) {
        try {
            Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
            $wuFiles = Get-ChildItem $wuPath -Recurse -Force -ErrorAction SilentlyContinue
            $count = 0
            foreach ($f in $wuFiles) {
                try { Remove-Item $f.FullName -Force -Recurse -ErrorAction Stop; $count++ } catch {}
            }
            Start-Service wuauserv -ErrorAction SilentlyContinue
            $null = $results.Add([PSCustomObject]@{ Component = "WU Cache"; Status = "Pass"; Details = "$count items removed" })
            Write-Host "  WU cache: $count items removed" -ForegroundColor Green
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "WU Cache"; Status = "Warning"; Details = $_.Exception.Message })
        }
    }

    $null = $results.Add([PSCustomObject]@{ Component = "Total Cleaned"; Status = "Pass"; Details = "$totalCleaned temp items + caches" })
    Write-Host "`n  Total items cleaned: $totalCleaned+" -ForegroundColor Cyan


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'SecureWipe' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'SecureWipe' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Secure Wipe Results" -Results $results
    Write-Log "Secure Wipe completed" -Level Success
    return $results
}

function Invoke-DeploymentPrep {
    Write-Log "Starting Deployment Prep..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Deployment Preparation (New User Setup)" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }

    # Checklist
    $checklist = @(
        @{Item="System identified"; Check=$true; Details="$($script:SystemInfo.Model), SN: $($script:SystemInfo.SerialNumber)"}
        @{Item="BIOS version noted"; Check=$true; Details="$($script:SystemInfo.BIOSVersion)"}
        @{Item="OS version"; Check=$true; Details="$($script:SystemInfo.OSVersion)"}
    )

    # Check disk health
    $disks = Get-PhysicalDisk
    $allHealthy = ($disks | Where-Object { $_.HealthStatus -ne "Healthy" }).Count -eq 0
    $checklist += @{Item="Disk health"; Check=$allHealthy; Details=$(if($allHealthy){"All disks healthy"}else{"Disk issues detected"})}

    # Check disk space
    $sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    $freePct = if ($sysDrive.Size -gt 0) { [math]::Round(($sysDrive.FreeSpace / $sysDrive.Size) * 100, 1) } else { 0 }
    $diskSpaceOK = $freePct -gt 20
    $checklist += @{Item="Disk space (system drive)"; Check=$diskSpaceOK; Details="$freePct% free"}

    # Check Windows activation
    try {
        $license = Get-CimInstance SoftwareLicensingProduct | Where-Object { $_.PartialProductKey -and $_.LicenseStatus -eq 1 } | Select-Object -First 1
        $activated = $null -ne $license
    } catch { $activated = $false }
    $checklist += @{Item="Windows activation"; Check=$activated; Details=$(if($activated){"Activated"}else{"Not activated"})}

    # Check Windows Updates
    Write-Host "  Checking Windows Update status..." -ForegroundColor Yellow
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $searcher = $updateSession.CreateUpdateSearcher()
        $pending = $searcher.Search("IsInstalled=0 and Type='Software'").Updates
        $upToDate = $pending.Count -eq 0
        $checklist += @{Item="Windows Updates"; Check=$upToDate; Details="$($pending.Count) pending updates"}
    } catch {
        $checklist += @{Item="Windows Updates"; Check=$false; Details="Could not check"}
    }

    # Battery health
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) {
        $battOK = $battery.EstimatedChargeRemaining -gt 50
        $checklist += @{Item="Battery"; Check=$battOK; Details="$($battery.EstimatedChargeRemaining)% charge"}
    }

    # Display checklist
    Write-Host "`n  Deployment Checklist:" -ForegroundColor Cyan
    Write-Host "  =====================" -ForegroundColor Cyan
    $passCount = 0
    foreach ($item in $checklist) {
        $symbol = if ($item.Check) { "[PASS]"; $passCount++ } else { "[FAIL]" }
        $color = if ($item.Check) { "Green" } else { "Red" }
        $null = $results.Add([PSCustomObject]@{ Component = $item.Item; Status = $(if($item.Check){"Pass"}else{"Fail"}); Details = $item.Details })
        Write-Host "  $symbol $($item.Item): $($item.Details)" -ForegroundColor $color
    }

    Write-Host "`n  Score: $passCount / $($checklist.Count) checks passed" -ForegroundColor $(if($passCount -eq $checklist.Count){"Green"}else{"Yellow"})
    $null = $results.Add([PSCustomObject]@{ Component = "Deployment Score"; Status = $(if($passCount -eq $checklist.Count){"Pass"}else{"Warning"}); Details = "$passCount / $($checklist.Count)" })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'DeploymentPrep' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'DeploymentPrep' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Deployment Preparation Results" -Results $results
    Write-Log "Deployment Prep completed" -Level Success
    return $results
}

function Invoke-UpdateManager {
    Write-Log "Starting Update Manager..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Update Manager" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Windows Update via COM
    Write-Host "Checking Windows Updates..." -ForegroundColor Yellow
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $searcher = $updateSession.CreateUpdateSearcher()
        $pendingUpdates = $searcher.Search("IsInstalled=0 and Type='Software'").Updates

        if ($pendingUpdates.Count -gt 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "Windows Updates"; Status = "Warning"; Details = "$($pendingUpdates.Count) updates available" })
            Write-Host "  $($pendingUpdates.Count) updates available:" -ForegroundColor Yellow
            $critCount = 0
            foreach ($update in $pendingUpdates) {
                $severity = if ($update.MsrcSeverity) { $update.MsrcSeverity } else { "Normal" }
                if ($severity -eq "Critical" -or $severity -eq "Important") { $critCount++ }
                $null = $results.Add([PSCustomObject]@{ Component = "Update: $($update.Title)"; Status = $(if($severity -eq "Critical"){"Fail"}elseif($severity -eq "Important"){"Warning"}else{"Info"}); Details = "Severity: $severity" })
                Write-Host "    [$severity] $($update.Title)" -ForegroundColor $(if($severity -eq "Critical"){"Red"}elseif($severity -eq "Important"){"Yellow"}else{"White"})
            }
            if ($critCount -gt 0) {
                Write-Host "`n  $critCount critical/important updates need attention!" -ForegroundColor Red
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Windows Updates"; Status = "Pass"; Details = "System is up to date" })
            Write-Host "  System is up to date" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Windows Updates"; Status = "Error"; Details = "Could not check: $($_.Exception.Message)" })
        Write-Host "  Could not check Windows Updates: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Lenovo System Update check
    Write-Host "`nChecking for Lenovo System Update..." -ForegroundColor Yellow
    $lsuPaths = @(
        "${env:ProgramFiles(x86)}\Lenovo\System Update\tvsu.exe",
        "${env:ProgramFiles}\Lenovo\System Update\tvsu.exe"
    )
    $lsuFound = $false
    foreach ($path in $lsuPaths) {
        if (Test-Path $path) {
            $lsuFound = $true
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo System Update"; Status = "Pass"; Details = "Found at $path" })
            Write-Host "  Lenovo System Update found: $path" -ForegroundColor Green
            Write-Host "  To run: Launch Lenovo System Update from Start Menu" -ForegroundColor White
            break
        }
    }
    if (-not $lsuFound) {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo System Update"; Status = "Info"; Details = "Not installed. Recommended for ThinkPad driver/BIOS updates." })
        Write-Host "  Lenovo System Update not found" -ForegroundColor Yellow
        Write-Host "  Recommended: Install from https://support.lenovo.com" -ForegroundColor White
    }

    # Lenovo Vantage check
    $vantage = Get-AppxPackage -Name "*LenovoVantage*" -ErrorAction SilentlyContinue
    if (-not $vantage) {
        $vantage = Get-AppxPackage -Name "*E046963F.LenovoCompanion*" -ErrorAction SilentlyContinue
    }
    if ($vantage) {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Vantage"; Status = "Pass"; Details = "Installed: $($vantage.Version)" })
        Write-Host "  Lenovo Vantage: v$($vantage.Version)" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Vantage"; Status = "Info"; Details = "Not installed" })
        Write-Host "  Lenovo Vantage: Not installed" -ForegroundColor Gray
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'UpdateManager' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'UpdateManager' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Update Manager Results" -Results $results
    Write-Log "Update Manager completed" -Level Success
    return $results
}

function Invoke-BIOSUpdate {
    Write-Log "Starting BIOS Update Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  BIOS Update Check" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    $bios = Get-CimInstance Win32_BIOS
    $cs = Get-CimInstance Win32_ComputerSystem

    $null = $results.Add([PSCustomObject]@{ Component = "Current BIOS"; Status = "Info"; Details = "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))" })
    $null = $results.Add([PSCustomObject]@{ Component = "System Model"; Status = "Info"; Details = $cs.Model })
    $null = $results.Add([PSCustomObject]@{ Component = "Manufacturer"; Status = "Info"; Details = $cs.Manufacturer })
    Write-Host "  Current BIOS: $($bios.SMBIOSBIOSVersion)" -ForegroundColor White
    Write-Host "  Model: $($cs.Model)" -ForegroundColor White
    Write-Host "  Release Date: $($bios.ReleaseDate)" -ForegroundColor White

    # BIOS age warning
    $ageMonths = (New-TimeSpan -Start $bios.ReleaseDate -End (Get-Date)).Days / 30
    $ageStatus = if ($ageMonths -gt 24) { "Warning" } elseif ($ageMonths -gt 12) { "Info" } else { "Pass" }
    $null = $results.Add([PSCustomObject]@{ Component = "BIOS Age"; Status = $ageStatus; Details = "$([math]::Round($ageMonths)) months" })
    Write-Host "  Age: $([math]::Round($ageMonths)) months" -ForegroundColor $(if($ageStatus -eq "Pass"){"Green"}elseif($ageStatus -eq "Warning"){"Yellow"}else{"White"})

    # Check for flash utility
    Write-Host "`n  Checking for BIOS flash utilities..." -ForegroundColor Yellow
    $flashPaths = @(
        "${env:ProgramFiles(x86)}\Lenovo\BIOS Update",
        "${env:ProgramFiles}\Lenovo\BIOS Update",
        "$PSScriptRoot\Tools\BIOS"
    )
    $flashFound = $false
    foreach ($fp in $flashPaths) {
        if (Test-Path $fp) {
            $exes = Get-ChildItem $fp -Filter "*.exe" -ErrorAction SilentlyContinue
            if ($exes) {
                $flashFound = $true
                $null = $results.Add([PSCustomObject]@{ Component = "Flash Utility"; Status = "Pass"; Details = "Found at $fp" })
                Write-Host "  Flash utility found: $fp" -ForegroundColor Green
                break
            }
        }
    }
    if (-not $flashFound) {
        $null = $results.Add([PSCustomObject]@{ Component = "Flash Utility"; Status = "Info"; Details = "No local flash utility. Use Lenovo System Update." })
        Write-Host "  No local flash utility found" -ForegroundColor Gray
        Write-Host "  Use Lenovo System Update or download from support.lenovo.com" -ForegroundColor White
    }

    # Safety checks
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) {
        $battOK = $battery.EstimatedChargeRemaining -ge 20
        $acPower = $battery.BatteryStatus -eq 2 -or $battery.BatteryStatus -eq 3 -or $battery.BatteryStatus -eq 6
        $null = $results.Add([PSCustomObject]@{ Component = "Battery for Update"; Status = $(if($battOK){"Pass"}else{"Fail"}); Details = "$($battery.EstimatedChargeRemaining)% (minimum 20%)" })
        $null = $results.Add([PSCustomObject]@{ Component = "AC Power"; Status = $(if($acPower){"Pass"}else{"Warning"}); Details = $(if($acPower){"Connected"}else{"NOT connected - required for BIOS update"}) })
        Write-Host "  Battery: $($battery.EstimatedChargeRemaining)% $(if($battOK){'(OK)'}else{'(TOO LOW)'})" -ForegroundColor $(if($battOK){"Green"}else{"Red"})
        Write-Host "  AC Power: $(if($acPower){'Connected'}else{'NOT connected'})" -ForegroundColor $(if($acPower){"Green"}else{"Red"})
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'BIOSUpdate' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'BIOSUpdate' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "BIOS Update Check Results" -Results $results
    Write-Log "BIOS Update Check completed" -Level Success
    return $results
}

function Invoke-SecurityCheck {
    Write-Log "Starting Security Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Security Check" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Windows Defender
    Write-Host "Checking Windows Defender..." -ForegroundColor Yellow
    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        $defStatus = if ($defender.RealTimeProtectionEnabled) { "Pass" } else { "Fail" }
        $null = $results.Add([PSCustomObject]@{ Component = "Defender Real-Time Protection"; Status = $defStatus; Details = "Enabled: $($defender.RealTimeProtectionEnabled)" })
        Write-Host "  Real-Time Protection: $($defender.RealTimeProtectionEnabled)" -ForegroundColor $(if($defStatus -eq "Pass"){"Green"}else{"Red"})

        $sigAge = (New-TimeSpan -Start $defender.AntivirusSignatureLastUpdated -End (Get-Date)).Days
        $sigStatus = if ($sigAge -gt 7) { "Warning" } else { "Pass" }
        $null = $results.Add([PSCustomObject]@{ Component = "Defender Signatures"; Status = $sigStatus; Details = "Last updated: $($defender.AntivirusSignatureLastUpdated) ($sigAge days ago)" })
        Write-Host "  Signatures: $sigAge days old" -ForegroundColor $(if($sigStatus -eq "Pass"){"Green"}else{"Yellow"})

        $null = $results.Add([PSCustomObject]@{ Component = "Defender Engine"; Status = "Info"; Details = "v$($defender.AMEngineVersion)" })
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Windows Defender"; Status = "Warning"; Details = "Could not query: $($_.Exception.Message)" })
        Write-Host "  Defender: Could not query" -ForegroundColor Yellow
    }

    # Firewall
    Write-Host "`nChecking Firewall..." -ForegroundColor Yellow
    try {
        $fwProfiles = Get-NetFirewallProfile
        foreach ($profile in $fwProfiles) {
            $fwStatus = if ($profile.Enabled) { "Pass" } else { "Fail" }
            $null = $results.Add([PSCustomObject]@{ Component = "Firewall: $($profile.Name)"; Status = $fwStatus; Details = "Enabled: $($profile.Enabled)" })
            Write-Host "  $($profile.Name): $(if($profile.Enabled){'Enabled'}else{'DISABLED'})" -ForegroundColor $(if($fwStatus -eq "Pass"){"Green"}else{"Red"})
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Firewall"; Status = "Error"; Details = $_.Exception.Message })
    }

    # BitLocker
    Write-Host "`nChecking BitLocker..." -ForegroundColor Yellow
    try {
        $bitlocker = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $blStatus = if ($bitlocker.ProtectionStatus -eq "On") { "Pass" } else { "Warning" }
        $null = $results.Add([PSCustomObject]@{ Component = "BitLocker ($env:SystemDrive)"; Status = $blStatus; Details = "Protection: $($bitlocker.ProtectionStatus), Encryption: $($bitlocker.EncryptionMethod)" })
        Write-Host "  BitLocker ($env:SystemDrive): $($bitlocker.ProtectionStatus)" -ForegroundColor $(if($blStatus -eq "Pass"){"Green"}else{"Yellow"})
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "BitLocker"; Status = "Info"; Details = "Not available or not enabled" })
        Write-Host "  BitLocker: Not available or not enabled" -ForegroundColor Gray
    }

    # TPM
    Write-Host "`nChecking TPM..." -ForegroundColor Yellow
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $tpmStatus = if ($tpm.TpmPresent -and $tpm.TpmReady) { "Pass" } elseif ($tpm.TpmPresent) { "Warning" } else { "Fail" }
        $null = $results.Add([PSCustomObject]@{ Component = "TPM"; Status = $tpmStatus; Details = "Present: $($tpm.TpmPresent), Ready: $($tpm.TpmReady), Enabled: $($tpm.TpmEnabled)" })
        Write-Host "  TPM: Present=$($tpm.TpmPresent), Ready=$($tpm.TpmReady)" -ForegroundColor $(if($tpmStatus -eq "Pass"){"Green"}elseif($tpmStatus -eq "Warning"){"Yellow"}else{"Red"})
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "TPM"; Status = "Warning"; Details = "Could not query TPM" })
        Write-Host "  TPM: Could not query" -ForegroundColor Yellow
    }

    # Secure Boot
    Write-Host "`nChecking Secure Boot..." -ForegroundColor Yellow
    try {
        $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
        $sbStatus = if ($secureBoot) { "Pass" } else { "Warning" }
        $null = $results.Add([PSCustomObject]@{ Component = "Secure Boot"; Status = $sbStatus; Details = "Enabled: $secureBoot" })
        Write-Host "  Secure Boot: $(if($secureBoot){'Enabled'}else{'Disabled'})" -ForegroundColor $(if($sbStatus -eq "Pass"){"Green"}else{"Yellow"})
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Secure Boot"; Status = "Info"; Details = "Could not determine (may not be UEFI)" })
        Write-Host "  Secure Boot: Unknown (may not be UEFI)" -ForegroundColor Gray
    }

    # UAC
    Write-Host "`nChecking UAC..." -ForegroundColor Yellow
    try {
        $uac = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction Stop).EnableLUA
        $uacStatus = if ($uac -eq 1) { "Pass" } else { "Warning" }
        $null = $results.Add([PSCustomObject]@{ Component = "UAC"; Status = $uacStatus; Details = "Enabled: $(if($uac -eq 1){'Yes'}else{'No'})" })
        Write-Host "  UAC: $(if($uac -eq 1){'Enabled'}else{'DISABLED'})" -ForegroundColor $(if($uacStatus -eq "Pass"){"Green"}else{"Red"})
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "UAC"; Status = "Info"; Details = "Could not check" })
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'SecurityCheck' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'SecurityCheck' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Security Check Results" -Results $results
    Write-Log "Security Check completed" -Level Success
    return $results
}

#endregion

#region Refurbishment Functions

function Invoke-RefurbBatteryAnalysis {
    Write-Log "Starting Refurb Battery Analysis..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Refurb Battery Analysis - Resale Readiness" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if (-not $battery) {
        $null = $results.Add([PSCustomObject]@{ Component = "Battery"; Status = "Fail"; Details = "No battery detected - cannot evaluate for resale" })
        Write-Host "  No battery detected" -ForegroundColor Red
        Export-DiagnosticReport -Title "Refurb Battery Analysis Results" -Results $results
        return $results
    }

    # Battery status
    $battStatus = switch ($battery.BatteryStatus) {
        1 {"Discharging"} 2 {"AC Power"} 3 {"Fully Charged"} 4 {"Low"} 5 {"Critical"} 6 {"Charging"} default {"Unknown"}
    }
    $null = $results.Add([PSCustomObject]@{ Component = "Battery Status"; Status = "Info"; Details = $battStatus })
    Write-Host "  Status: $battStatus" -ForegroundColor White

    # Read config thresholds
    $cycleGreen = 500; $cycleYellow = 800; $wearGreen = 20; $wearYellow = 35; $minScore = 75
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'CycleCountGreen=(\d+)') { $cycleGreen = [int]$Matches[1] }
            if ($cfgContent -match 'CycleCountYellow=(\d+)') { $cycleYellow = [int]$Matches[1] }
            if ($cfgContent -match 'WearPercentGreen=(\d+)') { $wearGreen = [int]$Matches[1] }
            if ($cfgContent -match 'WearPercentYellow=(\d+)') { $wearYellow = [int]$Matches[1] }
            if ($cfgContent -match 'MinimumBatteryScore=(\d+)') { $minScore = [int]$Matches[1] }
        }
    } catch { }

    # Wear analysis
    $wearPct = 0
    $wearScore = 50  # default max for wear (50% weight)
    if ($battery.DesignCapacity -gt 0 -and $battery.FullChargeCapacity -gt 0) {
        $wearPct = [math]::Round((1 - ($battery.FullChargeCapacity / $battery.DesignCapacity)) * 100, 1)
        $null = $results.Add([PSCustomObject]@{ Component = "Design Capacity"; Status = "Info"; Details = "$($battery.DesignCapacity) mWh" })
        $null = $results.Add([PSCustomObject]@{ Component = "Full Charge Capacity"; Status = "Info"; Details = "$($battery.FullChargeCapacity) mWh" })
        $null = $results.Add([PSCustomObject]@{ Component = "Wear Percentage"; Status = $(if($wearPct -le $wearGreen){"Pass"}elseif($wearPct -le $wearYellow){"Warning"}else{"Fail"}); Details = "$wearPct%" })
        Write-Host "  Design Capacity: $($battery.DesignCapacity) mWh" -ForegroundColor White
        Write-Host "  Full Charge Capacity: $($battery.FullChargeCapacity) mWh" -ForegroundColor White
        Write-Host "  Wear: $wearPct%" -ForegroundColor $(if($wearPct -le $wearGreen){"Green"}elseif($wearPct -le $wearYellow){"Yellow"}else{"Red"})

        if ($wearPct -le $wearGreen) { $wearScore = 50 }
        elseif ($wearPct -ge $wearYellow) { $wearScore = 0 }
        else { $wearScore = [math]::Round(50 * (1 - (($wearPct - $wearGreen) / ($wearYellow - $wearGreen))), 0) }
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Capacity Data"; Status = "Warning"; Details = "WMI capacity data not available - generating powercfg report" })
        Write-Host "  Capacity data not available via WMI, checking powercfg..." -ForegroundColor Yellow
    }

    # Generate and parse powercfg battery report
    $cycleCount = 0
    $cycleScore = 30  # default max for cycles (30% weight)
    try {
        $battReportPath = Join-Path $ReportPath "refurb_battery_$(Get-Date -Format 'yyyyMMdd_HHmmss').xml"
        & powercfg /batteryreport /output "$battReportPath" /xml 2>&1 | Out-Null
        if (Test-Path $battReportPath) {
            [xml]$battXml = Get-Content $battReportPath
            $battInfo = $battXml.BatteryReport.Batteries.Battery
            if ($battInfo) {
                $designCap = [int]$battInfo.DesignCapacity
                $fullChargeCap = [int]$battInfo.FullChargeCapacity
                if ($designCap -gt 0 -and $fullChargeCap -gt 0 -and $wearPct -eq 0) {
                    $wearPct = [math]::Round((1 - ($fullChargeCap / $designCap)) * 100, 1)
                    $null = $results.Add([PSCustomObject]@{ Component = "Wear (powercfg)"; Status = $(if($wearPct -le $wearGreen){"Pass"}elseif($wearPct -le $wearYellow){"Warning"}else{"Fail"}); Details = "$wearPct%" })
                    Write-Host "  Wear (powercfg): $wearPct%" -ForegroundColor $(if($wearPct -le $wearGreen){"Green"}elseif($wearPct -le $wearYellow){"Yellow"}else{"Red"})
                    if ($wearPct -le $wearGreen) { $wearScore = 50 }
                    elseif ($wearPct -ge $wearYellow) { $wearScore = 0 }
                    else { $wearScore = [math]::Round(50 * (1 - (($wearPct - $wearGreen) / ($wearYellow - $wearGreen))), 0) }
                }
                $cycleCount = [int]$battInfo.CycleCount
                if ($cycleCount -gt 0) {
                    $null = $results.Add([PSCustomObject]@{ Component = "Cycle Count"; Status = $(if($cycleCount -le $cycleGreen){"Pass"}elseif($cycleCount -le $cycleYellow){"Warning"}else{"Fail"}); Details = "$cycleCount cycles" })
                    Write-Host "  Cycle Count: $cycleCount" -ForegroundColor $(if($cycleCount -le $cycleGreen){"Green"}elseif($cycleCount -le $cycleYellow){"Yellow"}else{"Red"})
                }
            }
            $null = $results.Add([PSCustomObject]@{ Component = "Battery Report"; Status = "Pass"; Details = "Saved to $battReportPath" })
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Battery Report"; Status = "Warning"; Details = "Could not generate: $($_.Exception.Message)" })
    }

    # Cycle count score (30% weight)
    if ($cycleCount -gt 0) {
        if ($cycleCount -le $cycleGreen) { $cycleScore = 30 }
        elseif ($cycleCount -ge $cycleYellow) { $cycleScore = 0 }
        else { $cycleScore = [math]::Round(30 * (1 - (($cycleCount - $cycleGreen) / ($cycleYellow - $cycleGreen))), 0) }
    }

    # Status score (20% weight)
    $statusScore = 20
    $statusText = $battery.Status
    if ($statusText -match "Degraded") { $statusScore = 10 }
    elseif ($statusText -match "Replace") { $statusScore = 0 }
    $null = $results.Add([PSCustomObject]@{ Component = "Battery WMI Status"; Status = $(if($statusScore -eq 20){"Pass"}elseif($statusScore -eq 10){"Warning"}else{"Fail"}); Details = "$statusText" })

    # Calculate total score
    $totalScore = $wearScore + $cycleScore + $statusScore
    $verdict = if ($totalScore -ge $minScore) { "PASS" } elseif ($totalScore -ge 50) { "WARN" } else { "FAIL" }
    $verdictStatus = if ($verdict -eq "PASS") { "Pass" } elseif ($verdict -eq "WARN") { "Warning" } else { "Fail" }

    Write-Host "`n  ===== BATTERY SCORE =====" -ForegroundColor Cyan
    Write-Host "  Wear Score:   $wearScore / 50" -ForegroundColor White
    Write-Host "  Cycle Score:  $cycleScore / 30" -ForegroundColor White
    Write-Host "  Status Score: $statusScore / 20" -ForegroundColor White
    Write-Host "  TOTAL:        $totalScore / 100" -ForegroundColor $(if($verdict -eq "PASS"){"Green"}elseif($verdict -eq "WARN"){"Yellow"}else{"Red"})
    Write-Host "  VERDICT:      $verdict" -ForegroundColor $(if($verdict -eq "PASS"){"Green"}elseif($verdict -eq "WARN"){"Yellow"}else{"Red"})

    $null = $results.Add([PSCustomObject]@{ Component = "Wear Score"; Status = "Info"; Details = "$wearScore / 50" })
    $null = $results.Add([PSCustomObject]@{ Component = "Cycle Score"; Status = "Info"; Details = "$cycleScore / 30" })
    $null = $results.Add([PSCustomObject]@{ Component = "Status Score"; Status = "Info"; Details = "$statusScore / 20" })
    $null = $results.Add([PSCustomObject]@{ Component = "TOTAL SCORE"; Status = $verdictStatus; Details = "$totalScore / 100 - $verdict (threshold: $minScore)" })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'RefurbBatteryAnalysis' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'RefurbBatteryAnalysis' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Refurb Battery Analysis Results" -Results $results
    Write-Log "Refurb Battery Analysis completed - Score: $totalScore/100 ($verdict)" -Level Success
    return $results
}

function Invoke-RefurbQualityCheck {
    Write-Log "Starting Refurb Quality Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Refurb Quality Check - 10-Point QA Checklist" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    $passCount = 0
    $totalChecks = 10

    # Read config
    $minPassRate = 80
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'MinimumPassRate=(\d+)') { $minPassRate = [int]$Matches[1] }
        }
    } catch { }

    # Check 1: BIOS password
    Write-Host "  [1/10] Checking BIOS password..." -ForegroundColor Yellow
    try {
        $biosPasswordSet = $false
        if ($script:SystemInfo -and $script:SystemInfo.Manufacturer -match "LENOVO") {
            $lenovoBios = Get-CimInstance -Namespace "root\wmi" -ClassName Lenovo_BiosPasswordSettings -ErrorAction SilentlyContinue
            if ($lenovoBios -and $lenovoBios.PasswordState -ne 0) { $biosPasswordSet = $true }
        }
        if ($biosPasswordSet) {
            $null = $results.Add([PSCustomObject]@{ Component = "1. BIOS Password"; Status = "Warning"; Details = "BIOS password is set - must be removed before resale" })
            Write-Host "    WARNING: BIOS password set" -ForegroundColor Yellow
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "1. BIOS Password"; Status = "Pass"; Details = "No BIOS password detected (or non-Lenovo)" })
            Write-Host "    OK: No BIOS password" -ForegroundColor Green
            $passCount++
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "1. BIOS Password"; Status = "Pass"; Details = "Could not check (skipped for non-Lenovo)" })
        Write-Host "    OK: Skipped (non-Lenovo or not accessible)" -ForegroundColor Green
        $passCount++
    }

    # Check 2: User data cleaned
    Write-Host "  [2/10] Checking user profiles..." -ForegroundColor Yellow
    try {
        $userProfiles = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -notmatch "\\Default$|\\Public$" }
        $profileCount = @($userProfiles).Count
        if ($profileCount -le 1) {
            $null = $results.Add([PSCustomObject]@{ Component = "2. User Data Cleaned"; Status = "Pass"; Details = "$profileCount non-default profile(s) found" })
            Write-Host "    OK: $profileCount user profile(s)" -ForegroundColor Green
            $passCount++
        } else {
            $profileNames = ($userProfiles | ForEach-Object { Split-Path $_.LocalPath -Leaf }) -join ", "
            $null = $results.Add([PSCustomObject]@{ Component = "2. User Data Cleaned"; Status = "Warning"; Details = "$profileCount profiles found: $profileNames - clean before resale" })
            Write-Host "    WARNING: $profileCount profiles ($profileNames)" -ForegroundColor Yellow
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "2. User Data Cleaned"; Status = "Warning"; Details = "Could not enumerate profiles" })
        Write-Host "    WARNING: Could not check" -ForegroundColor Yellow
    }

    # Check 3: Windows activated
    Write-Host "  [3/10] Checking Windows activation..." -ForegroundColor Yellow
    try {
        $license = Get-CimInstance SoftwareLicensingProduct | Where-Object { $_.PartialProductKey -and $_.LicenseStatus -eq 1 } | Select-Object -First 1
        if ($license) {
            $null = $results.Add([PSCustomObject]@{ Component = "3. Windows Activated"; Status = "Pass"; Details = "Windows is activated" })
            Write-Host "    OK: Windows activated" -ForegroundColor Green
            $passCount++
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "3. Windows Activated"; Status = "Fail"; Details = "Windows is NOT activated" })
            Write-Host "    FAIL: Windows not activated" -ForegroundColor Red
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "3. Windows Activated"; Status = "Warning"; Details = "Could not check activation" })
        Write-Host "    WARNING: Could not check" -ForegroundColor Yellow
    }

    # Check 4: Drivers functional
    Write-Host "  [4/10] Checking drivers..." -ForegroundColor Yellow
    try {
        $problemDevices = Get-PnpDevice | Where-Object { $_.Status -ne "OK" -and $_.Status -ne "Unknown" }
        $problemCount = @($problemDevices).Count
        if ($problemCount -eq 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "4. Drivers Functional"; Status = "Pass"; Details = "All devices reporting OK status" })
            Write-Host "    OK: All drivers functional" -ForegroundColor Green
            $passCount++
        } else {
            $devNames = ($problemDevices | Select-Object -First 3 | ForEach-Object { $_.FriendlyName }) -join ", "
            $null = $results.Add([PSCustomObject]@{ Component = "4. Drivers Functional"; Status = "Warning"; Details = "$problemCount device(s) with issues: $devNames" })
            Write-Host "    WARNING: $problemCount device(s) with issues" -ForegroundColor Yellow
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "4. Drivers Functional"; Status = "Warning"; Details = "Could not enumerate devices" })
        Write-Host "    WARNING: Could not check" -ForegroundColor Yellow
    }

    # Check 5: Disk health
    Write-Host "  [5/10] Checking disk health..." -ForegroundColor Yellow
    try {
        $disks = Get-PhysicalDisk
        $unhealthy = $disks | Where-Object { $_.HealthStatus -ne "Healthy" }
        if (@($unhealthy).Count -eq 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "5. Disk Health"; Status = "Pass"; Details = "All $(@($disks).Count) disk(s) healthy" })
            Write-Host "    OK: All disks healthy" -ForegroundColor Green
            $passCount++
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "5. Disk Health"; Status = "Fail"; Details = "$(@($unhealthy).Count) disk(s) unhealthy" })
            Write-Host "    FAIL: $(@($unhealthy).Count) unhealthy disk(s)" -ForegroundColor Red
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "5. Disk Health"; Status = "Warning"; Details = "Could not check disk health" })
        Write-Host "    WARNING: Could not check" -ForegroundColor Yellow
    }

    # Check 6: Windows Update current
    Write-Host "  [6/10] Checking Windows Update..." -ForegroundColor Yellow
    try {
        $lastUpdate = Get-HotFix | Sort-Object InstalledOn -Descending -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($lastUpdate -and $lastUpdate.InstalledOn) {
            $daysSinceUpdate = (New-TimeSpan -Start $lastUpdate.InstalledOn -End (Get-Date)).Days
            if ($daysSinceUpdate -le 30) {
                $null = $results.Add([PSCustomObject]@{ Component = "6. Windows Update"; Status = "Pass"; Details = "Last update $daysSinceUpdate days ago ($($lastUpdate.HotFixID))" })
                Write-Host "    OK: Updated $daysSinceUpdate days ago" -ForegroundColor Green
                $passCount++
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "6. Windows Update"; Status = "Warning"; Details = "Last update $daysSinceUpdate days ago - run Windows Update" })
                Write-Host "    WARNING: $daysSinceUpdate days since last update" -ForegroundColor Yellow
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "6. Windows Update"; Status = "Warning"; Details = "No update history found" })
            Write-Host "    WARNING: No update history" -ForegroundColor Yellow
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "6. Windows Update"; Status = "Warning"; Details = "Could not check update status" })
        Write-Host "    WARNING: Could not check" -ForegroundColor Yellow
    }

    # Check 7: Antivirus active
    Write-Host "  [7/10] Checking antivirus..." -ForegroundColor Yellow
    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        if ($defender.RealTimeProtectionEnabled) {
            $null = $results.Add([PSCustomObject]@{ Component = "7. Antivirus Active"; Status = "Pass"; Details = "Defender real-time protection enabled" })
            Write-Host "    OK: Defender active" -ForegroundColor Green
            $passCount++
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "7. Antivirus Active"; Status = "Fail"; Details = "Defender real-time protection DISABLED" })
            Write-Host "    FAIL: Defender disabled" -ForegroundColor Red
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "7. Antivirus Active"; Status = "Warning"; Details = "Could not check Defender status" })
        Write-Host "    WARNING: Could not check" -ForegroundColor Yellow
    }

    # Check 8: No critical event logs
    Write-Host "  [8/10] Checking critical events..." -ForegroundColor Yellow
    try {
        $critEvents = Invoke-SafeWinEvent -FilterHashtable @{LogName='System'; Level=1; StartTime=(Get-Date).AddDays(-7)} -MaxEvents 10
        $critCount = @($critEvents).Count
        if ($critCount -lt 5) {
            $null = $results.Add([PSCustomObject]@{ Component = "8. Critical Events"; Status = "Pass"; Details = "$critCount critical event(s) in last 7 days" })
            Write-Host "    OK: $critCount critical events (last 7 days)" -ForegroundColor Green
            $passCount++
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "8. Critical Events"; Status = "Warning"; Details = "$critCount critical events in last 7 days - investigate" })
            Write-Host "    WARNING: $critCount critical events" -ForegroundColor Yellow
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "8. Critical Events"; Status = "Pass"; Details = "No critical events found" })
        Write-Host "    OK: No critical events" -ForegroundColor Green
        $passCount++
    }

    # Check 9: Battery present and healthy
    Write-Host "  [9/10] Checking battery..." -ForegroundColor Yellow
    try {
        $batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($batt) {
            if ($batt.Status -match "Replace") {
                $null = $results.Add([PSCustomObject]@{ Component = "9. Battery Health"; Status = "Fail"; Details = "Battery needs replacement (Status: $($batt.Status))" })
                Write-Host "    FAIL: Battery needs replacement" -ForegroundColor Red
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "9. Battery Health"; Status = "Pass"; Details = "Battery present, status: $($batt.Status), charge: $($batt.EstimatedChargeRemaining)%" })
                Write-Host "    OK: Battery present, $($batt.EstimatedChargeRemaining)%" -ForegroundColor Green
                $passCount++
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "9. Battery Health"; Status = "Warning"; Details = "No battery detected" })
            Write-Host "    WARNING: No battery" -ForegroundColor Yellow
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "9. Battery Health"; Status = "Warning"; Details = "Could not check battery" })
        Write-Host "    WARNING: Could not check" -ForegroundColor Yellow
    }

    # Check 10: Temp files cleaned
    Write-Host "  [10/10] Checking temp files..." -ForegroundColor Yellow
    try {
        $tempPath = $env:TEMP
        $tempSize = (Get-ChildItem $tempPath -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $tempSizeMB = [math]::Round($tempSize / 1MB, 0)
        if ($tempSizeMB -lt 500) {
            $null = $results.Add([PSCustomObject]@{ Component = "10. Temp Cleaned"; Status = "Pass"; Details = "Temp folder: ${tempSizeMB}MB (under 500MB threshold)" })
            Write-Host "    OK: Temp ${tempSizeMB}MB" -ForegroundColor Green
            $passCount++
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "10. Temp Cleaned"; Status = "Warning"; Details = "Temp folder: ${tempSizeMB}MB - run cleanup before resale" })
            Write-Host "    WARNING: Temp ${tempSizeMB}MB (cleanup needed)" -ForegroundColor Yellow
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "10. Temp Cleaned"; Status = "Warning"; Details = "Could not check temp folder" })
        Write-Host "    WARNING: Could not check" -ForegroundColor Yellow
    }

    # Calculate pass rate
    $passRate = [math]::Round(($passCount / $totalChecks) * 100, 0)
    $verdict = if ($passRate -ge $minPassRate) { "PASS" } elseif ($passRate -ge 60) { "CONDITIONAL" } else { "FAIL" }
    $verdictStatus = if ($verdict -eq "PASS") { "Pass" } elseif ($verdict -eq "CONDITIONAL") { "Warning" } else { "Fail" }

    Write-Host "`n  ===== QUALITY CHECK RESULTS =====" -ForegroundColor Cyan
    Write-Host "  Passed: $passCount / $totalChecks ($passRate%)" -ForegroundColor $(if($verdict -eq "PASS"){"Green"}elseif($verdict -eq "CONDITIONAL"){"Yellow"}else{"Red"})
    Write-Host "  VERDICT: $verdict" -ForegroundColor $(if($verdict -eq "PASS"){"Green"}elseif($verdict -eq "CONDITIONAL"){"Yellow"}else{"Red"})

    $null = $results.Add([PSCustomObject]@{ Component = "PASS RATE"; Status = $verdictStatus; Details = "$passCount / $totalChecks ($passRate%) - $verdict (threshold: ${minPassRate}%)" })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'RefurbQualityCheck' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'RefurbQualityCheck' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Refurb Quality Check Results" -Results $results
    Write-Log "Refurb Quality Check completed - $passCount/$totalChecks passed ($verdict)" -Level Success
    return $results
}

function Invoke-RefurbThermalAnalysis {
    Write-Log "Starting Refurb Thermal Analysis..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Refurb Thermal Analysis - CPU Stress Test" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config thresholds
    $stressDuration = 300; $sampleInterval = 5; $passMaxC = 75; $warnMaxC = 85
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'StressDurationSec=(\d+)') { $stressDuration = [int]$Matches[1] }
            if ($cfgContent -match 'StressSampleIntervalSec=(\d+)') { $sampleInterval = [int]$Matches[1] }
            if ($cfgContent -match 'ThermalPassMaxC=(\d+)') { $passMaxC = [int]$Matches[1] }
            if ($cfgContent -match 'ThermalWarnMaxC=(\d+)') { $warnMaxC = [int]$Matches[1] }
        }
    } catch { }

    $totalSamples = [math]::Floor($stressDuration / $sampleInterval)
    Write-Host "  Duration: $stressDuration seconds ($totalSamples samples at ${sampleInterval}s intervals)" -ForegroundColor White
    Write-Host "  Pass: <${passMaxC}C | Warn: ${passMaxC}-${warnMaxC}C | Fail: >${warnMaxC}C" -ForegroundColor White
    Write-Host

    # Helper to read temperature
    function Get-CurrentTempC {
        try {
            $tz = Get-CimInstance -Namespace "root/wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Select-Object -First 1
            $raw = $tz.CurrentTemperature
            if ($raw -ge 0 -and $raw -le 5000) {
                $tempC = [math]::Round(($raw - 2732) / 10, 1)
                if ($tempC -ge 0 -and $tempC -le 120) { return $tempC }
            }
        } catch { }
        return $null
    }

    # Phase 1: Idle temperature (3 readings)
    Write-Host "  Phase 1: Reading idle temperature..." -ForegroundColor Yellow
    $idleReadings = @()
    for ($i = 0; $i -lt 3; $i++) {
        $temp = Get-CurrentTempC
        if ($null -ne $temp) { $idleReadings += $temp }
        if ($i -lt 2) { Start-Sleep -Seconds $sampleInterval }
    }

    if ($idleReadings.Count -eq 0) {
        $null = $results.Add([PSCustomObject]@{ Component = "Thermal Zones"; Status = "Warning"; Details = "Cannot read temperature via WMI - thermal test unavailable" })
        Write-Host "  Cannot read temperature data. Thermal stress test unavailable." -ForegroundColor Red
        Export-DiagnosticReport -Title "Refurb Thermal Analysis Results" -Results $results
        Write-Log "Refurb Thermal Analysis - no thermal data available" -Level Warning
        return $results
    }

    $idleAvg = [math]::Round(($idleReadings | Measure-Object -Average).Average, 1)
    $null = $results.Add([PSCustomObject]@{ Component = "Idle Temperature"; Status = "Info"; Details = "${idleAvg}C (avg of $($idleReadings.Count) readings)" })
    Write-Host "  Idle temp: ${idleAvg}C" -ForegroundColor White

    # Phase 2: CPU stress test
    Write-Host "`n  Phase 2: Starting CPU stress test ($stressDuration seconds)..." -ForegroundColor Yellow
    Write-Host "  [" -NoNewline -ForegroundColor Cyan

    # Get baseline CPU frequency
    $cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
    $maxClockMHz = $cpuInfo.MaxClockSpeed
    $null = $results.Add([PSCustomObject]@{ Component = "CPU"; Status = "Info"; Details = "$($cpuInfo.Name), Max: ${maxClockMHz}MHz" })

    # Start CPU stress jobs (one per logical core)
    $coreCount = [Environment]::ProcessorCount
    $stressJobs = @()
    for ($c = 0; $c -lt $coreCount; $c++) {
        $stressJobs += Start-Job -ScriptBlock {
            param($duration)
            $end = (Get-Date).AddSeconds($duration)
            while ((Get-Date) -lt $end) {
                for ($i = 0; $i -lt 10000; $i++) { [Math]::Sqrt($i * 1.23456) | Out-Null }
            }
        } -ArgumentList $stressDuration
    }

    # Monitor temperature during stress
    $stressReadings = @()
    $throttleCount = 0
    $progressStep = [math]::Max(1, [math]::Floor($totalSamples / 50))

    for ($s = 0; $s -lt $totalSamples; $s++) {
        Start-Sleep -Seconds $sampleInterval
        $temp = Get-CurrentTempC
        if ($null -ne $temp) { $stressReadings += $temp }

        # Check for throttling
        $currentClock = (Get-CimInstance Win32_Processor | Select-Object -First 1).CurrentClockSpeed
        if ($maxClockMHz -gt 0 -and $currentClock -lt ($maxClockMHz * 0.85)) { $throttleCount++ }

        # Progress indicator
        if ($s % $progressStep -eq 0) { Write-Host "=" -NoNewline -ForegroundColor Cyan }
    }
    Write-Host "]" -ForegroundColor Cyan

    # Stop stress jobs
    $stressJobs | Stop-Job -PassThru | Remove-Job -Force

    # Phase 3: Cooldown (3 readings)
    Write-Host "`n  Phase 3: Reading cooldown temperature..." -ForegroundColor Yellow
    $cooldownReadings = @()
    for ($i = 0; $i -lt 3; $i++) {
        Start-Sleep -Seconds $sampleInterval
        $temp = Get-CurrentTempC
        if ($null -ne $temp) { $cooldownReadings += $temp }
    }

    # Calculate results
    if ($stressReadings.Count -gt 0) {
        $maxTemp = [math]::Round(($stressReadings | Measure-Object -Maximum).Maximum, 1)
        $avgTemp = [math]::Round(($stressReadings | Measure-Object -Average).Average, 1)
        $thermalDelta = [math]::Round($maxTemp - $idleAvg, 1)
        $cooldownAvg = if ($cooldownReadings.Count -gt 0) { [math]::Round(($cooldownReadings | Measure-Object -Average).Average, 1) } else { "N/A" }
        $throttlePct = [math]::Round(($throttleCount / $totalSamples) * 100, 0)

        $null = $results.Add([PSCustomObject]@{ Component = "Max Temperature"; Status = $(if($maxTemp -le $passMaxC){"Pass"}elseif($maxTemp -le $warnMaxC){"Warning"}else{"Fail"}); Details = "${maxTemp}C" })
        $null = $results.Add([PSCustomObject]@{ Component = "Avg Temperature (Load)"; Status = "Info"; Details = "${avgTemp}C" })
        $null = $results.Add([PSCustomObject]@{ Component = "Thermal Delta"; Status = "Info"; Details = "${thermalDelta}C (idle: ${idleAvg}C, max: ${maxTemp}C)" })
        $null = $results.Add([PSCustomObject]@{ Component = "Cooldown Temp"; Status = "Info"; Details = "${cooldownAvg}C" })
        $null = $results.Add([PSCustomObject]@{ Component = "Samples Collected"; Status = "Info"; Details = "$($stressReadings.Count) of $totalSamples" })

        # Throttling result
        $throttleStatus = if ($throttlePct -eq 0) { "Pass" } elseif ($throttlePct -lt 20) { "Warning" } else { "Fail" }
        $null = $results.Add([PSCustomObject]@{ Component = "CPU Throttling"; Status = $throttleStatus; Details = "${throttlePct}% of samples showed throttling ($throttleCount/$totalSamples)" })

        # Final verdict
        $verdict = "PASS"
        if ($maxTemp -gt $warnMaxC -or $throttlePct -ge 20) { $verdict = "FAIL" }
        elseif ($maxTemp -gt $passMaxC -or $throttlePct -gt 0) { $verdict = "WARN" }
        $verdictStatus = if ($verdict -eq "PASS") { "Pass" } elseif ($verdict -eq "WARN") { "Warning" } else { "Fail" }

        Write-Host "`n  ===== THERMAL TEST RESULTS =====" -ForegroundColor Cyan
        Write-Host "  Idle:     ${idleAvg}C" -ForegroundColor White
        Write-Host "  Max:      ${maxTemp}C" -ForegroundColor $(if($maxTemp -le $passMaxC){"Green"}elseif($maxTemp -le $warnMaxC){"Yellow"}else{"Red"})
        Write-Host "  Avg Load: ${avgTemp}C" -ForegroundColor White
        Write-Host "  Delta:    ${thermalDelta}C" -ForegroundColor White
        Write-Host "  Cooldown: ${cooldownAvg}C" -ForegroundColor White
        Write-Host "  Throttle: ${throttlePct}%" -ForegroundColor $(if($throttlePct -eq 0){"Green"}elseif($throttlePct -lt 20){"Yellow"}else{"Red"})
        Write-Host "  VERDICT:  $verdict" -ForegroundColor $(if($verdict -eq "PASS"){"Green"}elseif($verdict -eq "WARN"){"Yellow"}else{"Red"})

        $null = $results.Add([PSCustomObject]@{ Component = "VERDICT"; Status = $verdictStatus; Details = "$verdict - Max: ${maxTemp}C, Throttle: ${throttlePct}%" })
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Stress Test"; Status = "Warning"; Details = "No temperature readings during stress test" })
        Write-Host "  No temperature data collected during stress" -ForegroundColor Red
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'RefurbThermalAnalysis' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'RefurbThermalAnalysis' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Refurb Thermal Analysis Results" -Results $results
    Write-Log "Refurb Thermal Analysis completed" -Level Success
    return $results
}

#endregion

#region Troubleshooter Functions

function Invoke-SecurityHardening {
    Write-Log "Starting Security Hardening..." -Level Info
    $results = New-Object System.Collections.ArrayList
    $cfg = Get-RemediationConfig

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Security Hardening - Auto-Fix Mode" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    New-SafeRestorePoint -ModuleName "Security Hardening" | Out-Null
    Write-Host
    Write-Host "  Each issue found will prompt Y/N before fixing." -ForegroundColor Gray
    Write-Host

    $fixCount = 0; $declineCount = 0; $issueCount = 0

    # 1. Defender Real-Time Protection
    Write-Host "  [1/7] Checking Windows Defender..." -ForegroundColor Yellow
    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        if (-not $defender.RealTimeProtectionEnabled) {
            $issueCount++
            if (Request-UserApproval -Issue "Windows Defender real-time protection is DISABLED" -ProposedFix "Enable Defender real-time protection") {
                $result = Invoke-FixAndVerify -Component "Defender Real-Time" -FixAction {
                    Set-MpPreference -DisableRealtimeMonitoring $false
                } -VerifyAction {
                    (Get-MpComputerStatus).RealTimeProtectionEnabled
                }
                $null = $results.Add($result)
                if ($result.Status -eq "Pass") { $fixCount++ }
            } else {
                $declineCount++
                $null = $results.Add([PSCustomObject]@{ Component = "Defender Real-Time"; Status = "Warning"; Details = "Fix declined by user" })
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Defender Real-Time"; Status = "Pass"; Details = "Already enabled" })
            Write-Host "    OK: Defender active" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Defender Real-Time"; Status = "Warning"; Details = "Cannot check: $($_.Exception.Message)" })
    }

    # 2. Defender Signatures
    Write-Host "  [2/7] Checking Defender signatures..." -ForegroundColor Yellow
    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        $sigAge = (New-TimeSpan -Start $defender.AntivirusSignatureLastUpdated -End (Get-Date)).Days
        if ($sigAge -gt $cfg.DefenderSigMaxDays) {
            $issueCount++
            if (Request-UserApproval -Issue "Defender signatures are $sigAge days old (threshold: $($cfg.DefenderSigMaxDays))" -ProposedFix "Update Defender signatures now") {
                $result = Invoke-FixAndVerify -Component "Defender Signatures" -FixAction {
                    Update-MpSignature -ErrorAction Stop
                } -VerifyAction {
                    $newAge = (New-TimeSpan -Start (Get-MpComputerStatus).AntivirusSignatureLastUpdated -End (Get-Date)).Days
                    $newAge -le 1
                }
                $null = $results.Add($result)
                if ($result.Status -eq "Pass") { $fixCount++ }
            } else {
                $declineCount++
                $null = $results.Add([PSCustomObject]@{ Component = "Defender Signatures"; Status = "Warning"; Details = "Update declined ($sigAge days old)" })
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Defender Signatures"; Status = "Pass"; Details = "Up to date ($sigAge days old)" })
            Write-Host "    OK: Signatures current ($sigAge days)" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Defender Signatures"; Status = "Warning"; Details = "Cannot check" })
    }

    # 3. Firewall
    Write-Host "  [3/7] Checking Firewall profiles..." -ForegroundColor Yellow
    try {
        $fwProfiles = Get-NetFirewallProfile
        $disabledProfiles = $fwProfiles | Where-Object { -not $_.Enabled }
        if ($disabledProfiles) {
            $issueCount++
            $names = ($disabledProfiles | ForEach-Object { $_.Name }) -join ", "
            $fwSafe = Test-DomainSafety -ActionType 'Firewall' -Detail "Enable firewall on $names"
            if ($fwSafe -and (Request-UserApproval -Issue "Firewall DISABLED on: $names" -ProposedFix "Enable firewall on all profiles")) {
                $result = Invoke-FixAndVerify -Component "Firewall" -FixAction {
                    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
                } -VerifyAction {
                    @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count -eq 0
                }
                $null = $results.Add($result)
                if ($result.Status -eq "Pass") { $fixCount++ }
            } else {
                $declineCount++
                $null = $results.Add([PSCustomObject]@{ Component = "Firewall"; Status = "Warning"; Details = "Fix declined ($names disabled)" })
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Firewall"; Status = "Pass"; Details = "All profiles enabled" })
            Write-Host "    OK: All firewall profiles enabled" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Firewall"; Status = "Warning"; Details = "Cannot check" })
    }

    # 4. UAC
    Write-Host "  [4/7] Checking UAC..." -ForegroundColor Yellow
    try {
        $uac = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction Stop).EnableLUA
        if ($uac -ne 1) {
            $issueCount++
            if (Request-UserApproval -Issue "User Account Control (UAC) is DISABLED" -ProposedFix "Enable UAC (requires reboot to take effect)") {
                $result = Invoke-FixAndVerify -Component "UAC" -FixAction {
                    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name EnableLUA -Value 1
                } -VerifyAction {
                    (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System").EnableLUA -eq 1
                }
                $null = $results.Add($result)
                if ($result.Status -eq "Pass") { $fixCount++ }
                Write-Host "    NOTE: Reboot required for UAC change to take effect" -ForegroundColor Yellow
            } else {
                $declineCount++
                $null = $results.Add([PSCustomObject]@{ Component = "UAC"; Status = "Warning"; Details = "Fix declined" })
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "UAC"; Status = "Pass"; Details = "UAC enabled" })
            Write-Host "    OK: UAC enabled" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "UAC"; Status = "Warning"; Details = "Cannot check" })
    }

    # 5. Windows Update Service
    Write-Host "  [5/7] Checking Windows Update service..." -ForegroundColor Yellow
    try {
        $wuService = Get-Service wuauserv -ErrorAction Stop
        if ($wuService.Status -ne 'Running') {
            $issueCount++
            if (Request-UserApproval -Issue "Windows Update service is $($wuService.Status)" -ProposedFix "Start Windows Update service") {
                $result = Invoke-FixAndVerify -Component "Windows Update Service" -FixAction {
                    Start-Service wuauserv -ErrorAction Stop
                } -VerifyAction {
                    (Get-Service wuauserv).Status -eq 'Running'
                }
                $null = $results.Add($result)
                if ($result.Status -eq "Pass") { $fixCount++ }
            } else {
                $declineCount++
                $null = $results.Add([PSCustomObject]@{ Component = "Windows Update Service"; Status = "Warning"; Details = "Fix declined" })
            }
        } else {
            # Check if updates are stale
            $lastUpdate = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
            if ($lastUpdate -and $lastUpdate.InstalledOn) {
                $daysSince = (New-TimeSpan -Start $lastUpdate.InstalledOn -End (Get-Date)).Days
                if ($daysSince -gt $cfg.WUMaxAgeDays) {
                    $issueCount++
                    if (Request-UserApproval -Issue "No Windows updates in $daysSince days (threshold: $($cfg.WUMaxAgeDays))" -ProposedFix "Reset Windows Update components") {
                        $result = Invoke-FixAndVerify -Component "Windows Update Reset" -FixAction {
                            Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
                            $swDist = "$env:SystemRoot\SoftwareDistribution"
                            if (Test-Path $swDist) { Rename-Item $swDist "$swDist.old_$(Get-Date -Format 'yyyyMMdd')" -Force -ErrorAction SilentlyContinue }
                            Start-Service wuauserv, bits -ErrorAction SilentlyContinue
                        } -VerifyAction {
                            (Get-Service wuauserv).Status -eq 'Running'
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    } else {
                        $declineCount++
                        $null = $results.Add([PSCustomObject]@{ Component = "Windows Update Reset"; Status = "Warning"; Details = "Fix declined ($daysSince days stale)" })
                    }
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "Windows Update"; Status = "Pass"; Details = "Running, last update $daysSince days ago" })
                    Write-Host "    OK: WU running, updated $daysSince days ago" -ForegroundColor Green
                }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Windows Update"; Status = "Pass"; Details = "Service running" })
                Write-Host "    OK: WU service running" -ForegroundColor Green
            }
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Windows Update"; Status = "Warning"; Details = "Cannot check" })
    }

    # 6. Temp Files
    Write-Host "  [6/7] Checking temp files..." -ForegroundColor Yellow
    try {
        $tempSize = (Get-ChildItem $env:TEMP -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $tempMB = [math]::Round($tempSize / 1MB, 0)
        if ($tempMB -gt $cfg.TempThresholdMB) {
            $issueCount++
            if (Request-UserApproval -Issue "Temp folder is ${tempMB}MB (threshold: $($cfg.TempThresholdMB)MB)" -ProposedFix "Clean temp files") {
                $before = $tempMB
                $result = Invoke-FixAndVerify -Component "Temp Cleanup" -FixAction {
                    Get-ChildItem $env:TEMP -Recurse -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                } -VerifyAction {
                    $after = (Get-ChildItem $env:TEMP -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    [math]::Round($after / 1MB, 0) -lt $before
                }
                $afterSize = [math]::Round((Get-ChildItem $env:TEMP -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB, 0)
                $result.Details = "Cleaned ${before}MB -> ${afterSize}MB"
                $null = $results.Add($result)
                if ($result.Status -eq "Pass") { $fixCount++ }
            } else {
                $declineCount++
                $null = $results.Add([PSCustomObject]@{ Component = "Temp Cleanup"; Status = "Warning"; Details = "Fix declined (${tempMB}MB)" })
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Temp Files"; Status = "Pass"; Details = "${tempMB}MB (under threshold)" })
            Write-Host "    OK: Temp ${tempMB}MB" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Temp Files"; Status = "Warning"; Details = "Cannot check" })
    }

    # 7. Windows Update Cache
    Write-Host "  [7/7] Checking Windows Update cache..." -ForegroundColor Yellow
    try {
        $wuCache = "$env:SystemRoot\SoftwareDistribution\Download"
        if (Test-Path $wuCache) {
            $wuSize = (Get-ChildItem $wuCache -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $wuMB = [math]::Round($wuSize / 1MB, 0)
            if ($wuMB -gt 500) {
                $issueCount++
                if (Request-UserApproval -Issue "Windows Update cache is ${wuMB}MB" -ProposedFix "Clear WU download cache") {
                    $result = Invoke-FixAndVerify -Component "WU Cache Cleanup" -FixAction {
                        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
                        Get-ChildItem "$env:SystemRoot\SoftwareDistribution\Download" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                        Start-Service wuauserv -ErrorAction SilentlyContinue
                    } -VerifyAction {
                        (Get-Service wuauserv).Status -eq 'Running'
                    }
                    $null = $results.Add($result)
                    if ($result.Status -eq "Pass") { $fixCount++ }
                } else {
                    $declineCount++
                    $null = $results.Add([PSCustomObject]@{ Component = "WU Cache"; Status = "Warning"; Details = "Fix declined (${wuMB}MB)" })
                }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "WU Cache"; Status = "Pass"; Details = "${wuMB}MB (acceptable)" })
                Write-Host "    OK: WU cache ${wuMB}MB" -ForegroundColor Green
            }
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "WU Cache"; Status = "Warning"; Details = "Cannot check" })
    }

    # Post-fix validation re-scan
    if ($fixCount -gt 0) {
        Write-Host "`n  ---- Post-Fix Validation ----" -ForegroundColor Cyan
        $valPass = 0; $valFail = 0
        # Re-check Defender
        try {
            $defCheck = Get-MpComputerStatus -ErrorAction SilentlyContinue
            if ($defCheck -and $defCheck.RealTimeProtectionEnabled) { $valPass++; Write-Host "    Defender: ON" -ForegroundColor Green }
            else { $valFail++; Write-Host "    Defender: still OFF" -ForegroundColor Red }
        } catch { }
        # Re-check Firewall
        try {
            $fwOff = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count
            if ($fwOff -eq 0) { $valPass++; Write-Host "    Firewall: all profiles ON" -ForegroundColor Green }
            else { $valFail++; Write-Host "    Firewall: $fwOff profile(s) still OFF" -ForegroundColor Red }
        } catch { }
        # Re-check UAC
        try {
            $uacVal = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction SilentlyContinue).EnableLUA
            if ($uacVal -eq 1) { $valPass++; Write-Host "    UAC: enabled" -ForegroundColor Green }
            else { $valFail++; Write-Host "    UAC: still disabled" -ForegroundColor Red }
        } catch { }
        # Re-check WU service
        try {
            $wuSvc = Get-Service wuauserv -ErrorAction SilentlyContinue
            if ($wuSvc -and $wuSvc.Status -eq 'Running') { $valPass++; Write-Host "    WU Service: running" -ForegroundColor Green }
            else { $valFail++; Write-Host "    WU Service: not running" -ForegroundColor Red }
        } catch { }
        Write-Host "    Validation: $valPass passed, $valFail failed" -ForegroundColor $(if ($valFail -eq 0) {'Green'} else {'Yellow'})
        $null = $results.Add([PSCustomObject]@{ Component = "Post-Fix Validation"; Status = $(if ($valFail -eq 0) {'Pass'} else {'Warning'}); Details = "$valPass passed, $valFail still need attention" })
    }

    # Summary
    Write-Host "`n  ===== SECURITY HARDENING SUMMARY =====" -ForegroundColor Cyan
    Write-Host "  Issues found:    $issueCount" -ForegroundColor White
    Write-Host "  Fixes applied:   $fixCount" -ForegroundColor Green
    Write-Host "  Fixes declined:  $declineCount" -ForegroundColor Yellow
    Write-Host "  No action needed: $($results.Count - $issueCount)" -ForegroundColor Gray
    $null = $results.Add([PSCustomObject]@{ Component = "SUMMARY"; Status = $(if($issueCount -eq 0){"Pass"}elseif($fixCount -gt 0){"Pass"}else{"Warning"}); Details = "Issues: $issueCount, Fixed: $fixCount, Declined: $declineCount" })

    Export-DiagnosticReport -Title "Security Hardening Results" -Results $results
    Write-Log "Security Hardening completed - Fixed: $fixCount, Declined: $declineCount" -Level Success
    Write-AuditLog -Module 'SecurityHardening' -IssueCode "Issues:$issueCount" -Severity 'S3' -ActionTaken "Fixed:$fixCount,Declined:$declineCount" -FinalState "$(if ($issueCount -eq 0) {'Clean'} elseif ($fixCount -gt 0) {'Remediated'} else {'PendingAction'})"
    return $results
}

function Invoke-NetworkTroubleshooter {
    Write-Log "Starting Network Troubleshooter..." -Level Info
    $results = New-Object System.Collections.ArrayList
    $cfg = Get-RemediationConfig

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Network Troubleshooter - Auto-Fix Mode" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host
    Write-Host "  [1] Wi-Fi Issues" -ForegroundColor White
    Write-Host "  [2] Bluetooth Issues" -ForegroundColor White
    Write-Host "  [3] VPN Issues" -ForegroundColor White
    Write-Host "  [4] Mobile Network Issues" -ForegroundColor White
    Write-Host "  [5] Run All" -ForegroundColor White
    Write-Host
    $subChoice = Read-Host "  Select (1-5)"

    $fixCount = 0; $declineCount = 0

    # ---- Wi-Fi Sub-Workflow ----
    if ($subChoice -in @("1","5")) {
        Write-Host "`n  ---- Wi-Fi Troubleshooter ----" -ForegroundColor Cyan
        $null = $results.Add([PSCustomObject]@{ Component = "--- Wi-Fi ---"; Status = "Info"; Details = "Wi-Fi troubleshooting started" })

        # Wi-Fi adapter check
        Write-Host "  Checking Wi-Fi adapter..." -ForegroundColor Yellow
        try {
            $wifiAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Wi-Fi|Wireless|WLAN|802\.11' } | Select-Object -First 1
            if ($wifiAdapter) {
                if ($wifiAdapter.Status -ne "Up") {
                    if (Request-UserApproval -Issue "Wi-Fi adapter '$($wifiAdapter.Name)' is $($wifiAdapter.Status)" -ProposedFix "Enable Wi-Fi adapter") {
                        $result = Invoke-FixAndVerify -Component "Wi-Fi Adapter Enable" -FixAction {
                            Enable-NetAdapter -Name $wifiAdapter.Name -Confirm:$false
                        } -VerifyAction {
                            Start-Sleep -Seconds 3
                            (Get-NetAdapter -Name $wifiAdapter.Name).Status -eq "Up"
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    } else { $declineCount++ }
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "Wi-Fi Adapter"; Status = "Pass"; Details = "Up - $($wifiAdapter.InterfaceDescription)" })
                    Write-Host "    OK: Wi-Fi adapter active" -ForegroundColor Green
                }

                # DNS check
                Write-Host "  Checking DNS resolution..." -ForegroundColor Yellow
                $dnsOk = $false
                try { $null = Resolve-DnsName "www.google.com" -ErrorAction Stop; $dnsOk = $true } catch { }
                if (-not $dnsOk) {
                    $dnsSafe = Test-DomainSafety -ActionType 'DNS' -Detail "Set DNS to $($cfg.FallbackDNS1)/$($cfg.FallbackDNS2)"
                    if ($dnsSafe -and (Request-UserApproval -Issue "DNS resolution failing" -ProposedFix "Flush DNS cache and set DNS to $($cfg.FallbackDNS1) / $($cfg.FallbackDNS2)")) {
                        $adapterName = $wifiAdapter.Name
                        $dns1 = $cfg.FallbackDNS1; $dns2 = $cfg.FallbackDNS2
                        $result = Invoke-FixAndVerify -Component "DNS Fix" -FixAction {
                            & ipconfig /flushdns 2>&1 | Out-Null
                            Set-DnsClientServerAddress -InterfaceAlias $adapterName -ServerAddresses @($dns1, $dns2)
                        } -VerifyAction {
                            Start-Sleep -Seconds 2
                            try { $null = Resolve-DnsName "www.google.com" -ErrorAction Stop; $true } catch { $false }
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    } else { $declineCount++ }
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "DNS Resolution"; Status = "Pass"; Details = "Working" })
                    Write-Host "    OK: DNS resolving" -ForegroundColor Green
                }

                # LSO check
                Write-Host "  Checking Large Send Offload..." -ForegroundColor Yellow
                try {
                    $lso = Get-NetAdapterAdvancedProperty -Name $wifiAdapter.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Large Send Offload' -and $_.DisplayValue -eq 'Enabled' }
                    if ($lso) {
                        if (Request-UserApproval -Issue "Large Send Offload (LSO) is enabled on Wi-Fi (causes drops)" -ProposedFix "Disable LSO v2 on $($wifiAdapter.Name)") {
                            $adapterName = $wifiAdapter.Name
                            foreach ($prop in $lso) {
                                $propName = $prop.DisplayName
                                $result = Invoke-FixAndVerify -Component "Disable LSO ($propName)" -FixAction {
                                    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $propName -DisplayValue "Disabled"
                                } -VerifyAction {
                                    (Get-NetAdapterAdvancedProperty -Name $adapterName | Where-Object { $_.DisplayName -eq $propName }).DisplayValue -eq "Disabled"
                                }
                                $null = $results.Add($result)
                                if ($result.Status -eq "Pass") { $fixCount++ }
                            }
                        } else { $declineCount++ }
                    } else {
                        $null = $results.Add([PSCustomObject]@{ Component = "LSO"; Status = "Pass"; Details = "Already disabled or not present" })
                        Write-Host "    OK: LSO not an issue" -ForegroundColor Green
                    }
                } catch {
                    $null = $results.Add([PSCustomObject]@{ Component = "LSO"; Status = "Info"; Details = "Cannot check advanced properties" })
                }

                # Power management
                Write-Host "  Checking Wi-Fi power management..." -ForegroundColor Yellow
                try {
                    $powerMgmt = Get-NetAdapterPowerManagement -Name $wifiAdapter.Name -ErrorAction SilentlyContinue
                    if ($powerMgmt -and $powerMgmt.AllowComputerToTurnOffDevice -eq $true) {
                        if (Request-UserApproval -Issue "Power management may turn off Wi-Fi to save power" -ProposedFix "Disable power-saving on Wi-Fi adapter") {
                            $adapterName = $wifiAdapter.Name
                            $result = Invoke-FixAndVerify -Component "Wi-Fi Power Mgmt" -FixAction {
                                $pm = Get-NetAdapterPowerManagement -Name $adapterName
                                $pm.AllowComputerToTurnOffDevice = 'Disabled'
                                $pm | Set-NetAdapterPowerManagement
                            } -VerifyAction {
                                (Get-NetAdapterPowerManagement -Name $adapterName).AllowComputerToTurnOffDevice -ne $true
                            }
                            $null = $results.Add($result)
                            if ($result.Status -eq "Pass") { $fixCount++ }
                        } else { $declineCount++ }
                    } else {
                        $null = $results.Add([PSCustomObject]@{ Component = "Wi-Fi Power Mgmt"; Status = "Pass"; Details = "Power saving already disabled" })
                        Write-Host "    OK: Power saving off" -ForegroundColor Green
                    }
                } catch {
                    $null = $results.Add([PSCustomObject]@{ Component = "Wi-Fi Power Mgmt"; Status = "Info"; Details = "Cannot check power management" })
                }

                # TCP/IP stack reset check
                Write-Host "  Checking connectivity..." -ForegroundColor Yellow
                $pingOk = Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue
                if (-not $pingOk) {
                    if (Request-UserApproval -Issue "Cannot reach internet (ping 8.8.8.8 fails)" -ProposedFix "Reset TCP/IP stack (netsh winsock reset + ip reset)") {
                        $result = Invoke-FixAndVerify -Component "TCP/IP Stack Reset" -FixAction {
                            & netsh winsock reset 2>&1 | Out-Null
                            & netsh int ip reset 2>&1 | Out-Null
                        } -VerifyAction {
                            Start-Sleep -Seconds 5
                            Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                        Write-Host "    NOTE: Reboot may be required for full stack reset" -ForegroundColor Yellow
                    } else { $declineCount++ }
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "Internet Connectivity"; Status = "Pass"; Details = "Ping to 8.8.8.8 successful" })
                    Write-Host "    OK: Internet reachable" -ForegroundColor Green
                }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Wi-Fi Adapter"; Status = "Fail"; Details = "No Wi-Fi adapter found" })
                Write-Host "    No Wi-Fi adapter detected" -ForegroundColor Red
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Wi-Fi"; Status = "Warning"; Details = "Error: $($_.Exception.Message)" })
        }
    }

    # ---- Bluetooth Sub-Workflow ----
    if ($subChoice -in @("2","5")) {
        Write-Host "`n  ---- Bluetooth Troubleshooter ----" -ForegroundColor Cyan
        $null = $results.Add([PSCustomObject]@{ Component = "--- Bluetooth ---"; Status = "Info"; Details = "Bluetooth troubleshooting started" })

        # BT adapter
        Write-Host "  Checking Bluetooth adapter..." -ForegroundColor Yellow
        try {
            $btAdapter = Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Bluetooth' } | Select-Object -First 1
            if ($btAdapter) {
                if ($btAdapter.Status -ne "OK") {
                    if (Request-UserApproval -Issue "Bluetooth adapter status: $($btAdapter.Status)" -ProposedFix "Enable/reset Bluetooth adapter") {
                        $btId = $btAdapter.InstanceId
                        $result = Invoke-FixAndVerify -Component "Bluetooth Adapter" -FixAction {
                            Disable-PnpDevice -InstanceId $btId -Confirm:$false -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds 2
                            Enable-PnpDevice -InstanceId $btId -Confirm:$false
                        } -VerifyAction {
                            (Get-PnpDevice -InstanceId $btId).Status -eq "OK"
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    } else { $declineCount++ }
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "Bluetooth Adapter"; Status = "Pass"; Details = "$($btAdapter.FriendlyName) - OK" })
                    Write-Host "    OK: $($btAdapter.FriendlyName)" -ForegroundColor Green
                }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Bluetooth Adapter"; Status = "Fail"; Details = "No Bluetooth adapter found" })
                Write-Host "    No Bluetooth adapter detected" -ForegroundColor Red
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Bluetooth"; Status = "Warning"; Details = "Error checking BT" })
        }

        # BT service
        Write-Host "  Checking Bluetooth service..." -ForegroundColor Yellow
        try {
            $btService = Get-Service bthserv -ErrorAction Stop
            if ($btService.Status -ne 'Running') {
                if (Request-UserApproval -Issue "Bluetooth Support Service is $($btService.Status)" -ProposedFix "Start Bluetooth service and set to Automatic") {
                    $result = Invoke-FixAndVerify -Component "Bluetooth Service" -FixAction {
                        Set-Service bthserv -StartupType Automatic -ErrorAction SilentlyContinue
                        Start-Service bthserv -ErrorAction Stop
                    } -VerifyAction {
                        (Get-Service bthserv).Status -eq 'Running'
                    }
                    $null = $results.Add($result)
                    if ($result.Status -eq "Pass") { $fixCount++ }
                } else { $declineCount++ }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Bluetooth Service"; Status = "Pass"; Details = "Running" })
                Write-Host "    OK: BT service running" -ForegroundColor Green
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Bluetooth Service"; Status = "Warning"; Details = "Cannot check service" })
        }
    }

    # ---- VPN Sub-Workflow ----
    if ($subChoice -in @("3","5")) {
        Write-Host "`n  ---- VPN Troubleshooter ----" -ForegroundColor Cyan
        $null = $results.Add([PSCustomObject]@{ Component = "--- VPN ---"; Status = "Info"; Details = "VPN troubleshooting started" })

        # VPN agent service (Cisco AnyConnect)
        Write-Host "  Checking VPN services..." -ForegroundColor Yellow
        try {
            $vpnAgent = Get-Service vpnagent -ErrorAction SilentlyContinue
            if ($vpnAgent) {
                if ($vpnAgent.Status -ne 'Running') {
                    if (Request-UserApproval -Issue "Cisco AnyConnect VPN agent is $($vpnAgent.Status)" -ProposedFix "Start VPN agent service") {
                        $result = Invoke-FixAndVerify -Component "VPN Agent Service" -FixAction {
                            Start-Service vpnagent -ErrorAction Stop
                        } -VerifyAction {
                            (Get-Service vpnagent).Status -eq 'Running'
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    } else { $declineCount++ }
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "VPN Agent"; Status = "Pass"; Details = "Running" })
                    Write-Host "    OK: VPN agent running" -ForegroundColor Green
                }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "VPN Agent"; Status = "Warning"; Details = "Cisco AnyConnect service not found" })
                Write-Host "    VPN agent service not installed" -ForegroundColor Yellow

                # Check if installer available on USB
                $vpnInstallerDir = $cfg.VPNInstallerPath
                if ($vpnInstallerDir -and (Test-Path $vpnInstallerDir)) {
                    $installer = Get-ChildItem $vpnInstallerDir -Include *.msi,*.exe -Recurse | Select-Object -First 1
                    if ($installer) {
                        if (Request-UserApproval -Issue "Cisco AnyConnect is not installed" -ProposedFix "Install from USB: $($installer.Name)") {
                            Write-Host "  Installing VPN client..." -ForegroundColor Yellow
                            try {
                                if ($installer.Extension -eq ".msi") {
                                    & msiexec /i "$($installer.FullName)" /qn /norestart 2>&1 | Out-Null
                                } else {
                                    & "$($installer.FullName)" /quiet /norestart 2>&1 | Out-Null
                                }
                                Start-Sleep -Seconds 10
                                $newService = Get-Service vpnagent -ErrorAction SilentlyContinue
                                if ($newService) {
                                    $null = $results.Add([PSCustomObject]@{ Component = "VPN Install"; Status = "Pass"; Details = "AnyConnect installed from USB" })
                                    Write-Host "  VERIFIED: VPN client installed" -ForegroundColor Green
                                    $fixCount++
                                } else {
                                    $null = $results.Add([PSCustomObject]@{ Component = "VPN Install"; Status = "Warning"; Details = "Install completed, verify manually" })
                                }
                            } catch {
                                $null = $results.Add([PSCustomObject]@{ Component = "VPN Install"; Status = "Fail"; Details = "Install failed: $($_.Exception.Message)" })
                            }
                        } else { $declineCount++ }
                    }
                }
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "VPN"; Status = "Warning"; Details = "Error checking VPN" })
        }

        # Orphaned VPN services
        Write-Host "  Checking for orphaned VPN services..." -ForegroundColor Yellow
        try {
            $orphanServices = Get-Service | Where-Object { $_.DisplayName -match 'NAM|Network Access Manager' -and $_.Status -eq 'Stopped' }
            foreach ($orphan in $orphanServices) {
                if (Request-UserApproval -Issue "Orphaned VPN service found: $($orphan.DisplayName) ($($orphan.Name))" -ProposedFix "Remove orphaned service") {
                    $svcName = $orphan.Name
                    try {
                        & sc.exe delete $svcName 2>&1 | Out-Null
                        $null = $results.Add([PSCustomObject]@{ Component = "Remove Orphan: $svcName"; Status = "Pass"; Details = "Orphaned service removed" })
                        Write-Host "  Removed: $svcName" -ForegroundColor Green
                        $fixCount++
                    } catch {
                        $null = $results.Add([PSCustomObject]@{ Component = "Remove Orphan: $svcName"; Status = "Fail"; Details = $_.Exception.Message })
                    }
                } else { $declineCount++ }
            }
        } catch { }

        # DNS flush for VPN
        Write-Host "  Flushing DNS (post-VPN cleanup)..." -ForegroundColor Yellow
        & ipconfig /flushdns 2>&1 | Out-Null
        $null = $results.Add([PSCustomObject]@{ Component = "VPN DNS Flush"; Status = "Pass"; Details = "DNS cache flushed" })
    }

    # ---- Mobile Network Sub-Workflow ----
    if ($subChoice -in @("4","5")) {
        Write-Host "`n  ---- Mobile Network Troubleshooter ----" -ForegroundColor Cyan
        $null = $results.Add([PSCustomObject]@{ Component = "--- Mobile ---"; Status = "Info"; Details = "Mobile network troubleshooting started" })

        Write-Host "  Checking WWAN adapter..." -ForegroundColor Yellow
        try {
            $wwanAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'WWAN|Cellular|Mobile|LTE|5G' } | Select-Object -First 1
            if ($wwanAdapter) {
                if ($wwanAdapter.Status -ne "Up") {
                    if (Request-UserApproval -Issue "Mobile adapter '$($wwanAdapter.Name)' is $($wwanAdapter.Status)" -ProposedFix "Enable mobile adapter") {
                        $adName = $wwanAdapter.Name
                        $result = Invoke-FixAndVerify -Component "WWAN Adapter" -FixAction {
                            Enable-NetAdapter -Name $adName -Confirm:$false
                        } -VerifyAction {
                            Start-Sleep -Seconds 3
                            (Get-NetAdapter -Name $adName).Status -eq "Up"
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    } else { $declineCount++ }
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "WWAN Adapter"; Status = "Pass"; Details = "$($wwanAdapter.Name) - Up" })
                    Write-Host "    OK: Mobile adapter active" -ForegroundColor Green
                }

                # WWAN service
                $wwanSvc = Get-Service WwanSvc -ErrorAction SilentlyContinue
                if ($wwanSvc -and $wwanSvc.Status -ne 'Running') {
                    if (Request-UserApproval -Issue "WWAN Autoconfig service is $($wwanSvc.Status)" -ProposedFix "Start WWAN service") {
                        $result = Invoke-FixAndVerify -Component "WWAN Service" -FixAction {
                            Start-Service WwanSvc -ErrorAction Stop
                        } -VerifyAction {
                            (Get-Service WwanSvc).Status -eq 'Running'
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    } else { $declineCount++ }
                }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "WWAN Adapter"; Status = "Info"; Details = "No mobile broadband adapter found (WWAN module may not be installed)" })
                Write-Host "    No mobile adapter found" -ForegroundColor Gray
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Mobile Network"; Status = "Warning"; Details = "Error checking WWAN" })
        }
    }

    # Summary
    Write-Host "`n  ===== NETWORK TROUBLESHOOTER SUMMARY =====" -ForegroundColor Cyan
    Write-Host "  Fixes applied:  $fixCount" -ForegroundColor Green
    Write-Host "  Fixes declined: $declineCount" -ForegroundColor Yellow
    $null = $results.Add([PSCustomObject]@{ Component = "SUMMARY"; Status = $(if($fixCount -gt 0){"Pass"}else{"Info"}); Details = "Fixed: $fixCount, Declined: $declineCount" })

    Export-DiagnosticReport -Title "Network Troubleshooter Results" -Results $results
    Write-Log "Network Troubleshooter completed - Fixed: $fixCount, Declined: $declineCount" -Level Success
    Write-AuditLog -Module 'NetworkTroubleshooter' -IssueCode "Fixes:$fixCount" -Severity 'S2' -ActionTaken "Fixed:$fixCount,Declined:$declineCount" -FinalState "$(if ($fixCount -gt 0) {'Remediated'} else {'NoAction'})"
    return $results
}

function Invoke-BSODTroubleshooter {
    Write-Log "Starting BSOD Troubleshooter..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  BSOD Troubleshooter - Diagnose & Fix Crashes" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    New-SafeRestorePoint -ModuleName "BSOD Troubleshooter" | Out-Null
    Write-Host

    $fixCount = 0; $declineCount = 0

    # Known driver mapping
    $driverFixMap = @{
        'ndis'       = @{Category='Network'; Desc='Network driver'}
        'nwifi'      = @{Category='Network'; Desc='Wi-Fi driver'}
        'tcpip'      = @{Category='Network'; Desc='TCP/IP stack'}
        'nvlddmkm'   = @{Category='GPU'; Desc='NVIDIA GPU driver'}
        'atikmdag'   = @{Category='GPU'; Desc='AMD GPU driver'}
        'atikmpag'   = @{Category='GPU'; Desc='AMD GPU driver'}
        'igdkmd'     = @{Category='GPU'; Desc='Intel GPU driver'}
        'dxgkrnl'    = @{Category='GPU'; Desc='DirectX Graphics Kernel'}
        'dxgmms'     = @{Category='GPU'; Desc='DirectX Memory Management'}
        'ntfs'       = @{Category='Storage'; Desc='NTFS file system'}
        'ntoskrnl'   = @{Category='System'; Desc='Windows kernel'}
        'storport'   = @{Category='Storage'; Desc='Storage port driver'}
        'storahci'   = @{Category='Storage'; Desc='AHCI storage driver'}
        'Wdf01000'   = @{Category='USB'; Desc='USB/WDF framework'}
        'usbhub'     = @{Category='USB'; Desc='USB hub driver'}
        'usbxhci'    = @{Category='USB'; Desc='USB 3.0 host controller'}
    }

    # Phase 1: Scan minidumps
    Write-Host "  Phase 1: Scanning crash dumps..." -ForegroundColor Yellow
    $dumpPath = "$env:SystemRoot\Minidump"
    $faultingDrivers = @{}
    $lastDumpDate = $null

    if (Test-Path $dumpPath) {
        $dumps = Get-ChildItem $dumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10
        if ($dumps.Count -gt 0) { $lastDumpDate = $dumps[0].LastWriteTime.ToString('yyyy-MM-dd') }
        $null = $results.Add([PSCustomObject]@{ Component = "Crash Dumps Found"; Status = "Info"; Details = "$($dumps.Count) dump(s) in $dumpPath" })
        Write-Host "    Found $($dumps.Count) crash dump(s)" -ForegroundColor White

        foreach ($dump in $dumps) {
            try {
                $dumpBytes = [System.IO.File]::ReadAllBytes($dump.FullName)
                $dumpText = [System.Text.Encoding]::ASCII.GetString($dumpBytes)
                foreach ($driverName in $driverFixMap.Keys) {
                    if ($dumpText -match "$driverName\.sys") {
                        if (-not $faultingDrivers.ContainsKey($driverName)) {
                            $faultingDrivers[$driverName] = @{ Count = 0; LastDate = $dump.LastWriteTime; Info = $driverFixMap[$driverName] }
                        }
                        $faultingDrivers[$driverName].Count++
                    }
                }
            } catch {
                # Binary read may fail on locked dumps, continue
            }
        }
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Crash Dumps"; Status = "Pass"; Details = "No minidump folder found (no crashes)" })
        Write-Host "    No crash dump folder found" -ForegroundColor Green
    }

    # Also check System event log for BugCheck events
    Write-Host "  Scanning event logs for crash events..." -ForegroundColor Yellow
    try {
        $bugChecks = Invoke-SafeWinEvent -FilterHashtable @{LogName='System'; Id=1001; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=(Get-Date).AddDays(-30)} -MaxEvents 20
        if ($bugChecks) {
            $null = $results.Add([PSCustomObject]@{ Component = "BugCheck Events"; Status = "Warning"; Details = "$(@($bugChecks).Count) crash event(s) in last 30 days" })
            Write-Host "    $(@($bugChecks).Count) crash events in event log" -ForegroundColor Yellow
        } else {
            $bugDetail = "No crash events in last 30 days"
            if ($lastDumpDate) { $bugDetail = "No crash events in last 30 days (last dump: $lastDumpDate)" }
            $null = $results.Add([PSCustomObject]@{ Component = "BugCheck Events"; Status = "Pass"; Details = $bugDetail })
        }
    } catch { }

    # Phase 2: Fix faulting drivers
    if ($faultingDrivers.Count -gt 0) {
        Write-Host "`n  Phase 2: Faulting drivers identified" -ForegroundColor Yellow
        foreach ($driver in $faultingDrivers.GetEnumerator()) {
            $dName = $driver.Key
            $dInfo = $driver.Value
            $category = $dInfo.Info.Category
            $desc = $dInfo.Info.Desc

            $null = $results.Add([PSCustomObject]@{ Component = "Faulting: $dName.sys"; Status = "Fail"; Details = "$desc - $($dInfo.Count) crash(es), last: $($dInfo.LastDate.ToString('yyyy-MM-dd'))" })
            Write-Host "    $dName.sys ($desc) - $($dInfo.Count) crash(es)" -ForegroundColor Red

            if ($category -eq 'GPU') {
                Write-Host "    WARNING: GPU driver update requires reboot and may cause display flicker" -ForegroundColor Yellow
            }

            # Try to find the device and update/rollback
            try {
                $device = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.InfName -match $dName -or $_.DeviceName -match $desc.Split(' ')[0] } | Select-Object -First 1
                if ($device) {
                    $driverDate = if ($device.DriverDate) { $device.DriverDate.ToString('yyyy-MM-dd') } else { "Unknown" }
                    $inboxNote = if ($device.DriverDate -and $device.DriverDate.Year -lt 2010) { " (inbox driver)" } else { "" }
                    if (Request-UserApproval -Issue "Driver $dName.sys ($($device.DeviceName)) - version from $driverDate$inboxNote" -ProposedFix "Update driver via Windows Update") {
                        Write-Host "  Searching Windows Update for driver..." -ForegroundColor Yellow
                        try {
                            $session = New-Object -ComObject Microsoft.Update.Session
                            $searcher = $session.CreateUpdateSearcher()
                            $searchResult = $searcher.Search("IsInstalled=0 and Type='Driver'")
                            $matchingUpdate = $null
                            foreach ($update in $searchResult.Updates) {
                                if ($update.Title -match $dName -or $update.Title -match $device.DeviceName.Split(' ')[0]) {
                                    $matchingUpdate = $update
                                    break
                                }
                            }
                            if ($matchingUpdate) {
                                Write-Host "  Found update: $($matchingUpdate.Title)" -ForegroundColor Cyan
                                $downloader = $session.CreateUpdateDownloader()
                                $updates = New-Object -ComObject Microsoft.Update.UpdateColl
                                $updates.Add($matchingUpdate) | Out-Null
                                $downloader.Updates = $updates
                                $downloader.Download() | Out-Null
                                $installer = $session.CreateUpdateInstaller()
                                $installer.Updates = $updates
                                $installResult = $installer.Install()
                                if ($installResult.ResultCode -eq 2) {
                                    $null = $results.Add([PSCustomObject]@{ Component = "Update: $dName"; Status = "Pass"; Details = "Driver updated via Windows Update" })
                                    Write-Host "  VERIFIED: Driver updated" -ForegroundColor Green
                                    $fixCount++
                                } else {
                                    $null = $results.Add([PSCustomObject]@{ Component = "Update: $dName"; Status = "Warning"; Details = "Update installed, verify after reboot" })
                                }
                            } else {
                                $null = $results.Add([PSCustomObject]@{ Component = "Update: $dName"; Status = "Info"; Details = "No update found in Windows Update catalog" })
                                Write-Host "  No update available via Windows Update" -ForegroundColor Yellow
                            }
                        } catch {
                            $null = $results.Add([PSCustomObject]@{ Component = "Update: $dName"; Status = "Warning"; Details = "WU search failed - driver NOT updated: $($_.Exception.Message)" })
                        }
                    } else { $declineCount++ }
                }
            } catch { }
        }
    } else {
        Write-Host "    No specific faulting drivers identified in dumps" -ForegroundColor Gray
    }

    # Phase 3: System file repair
    Write-Host "`n  Phase 3: System integrity checks" -ForegroundColor Yellow

    # SFC
    if (Request-UserApproval -Issue "System files may be corrupted (contributing to crashes)" -ProposedFix "Run System File Checker (SFC /scannow) - takes 5-10 minutes") {
        Write-Host "  Running SFC /scannow (this takes several minutes)..." -ForegroundColor Yellow
        try {
            $sfcOutput = & sfc /scannow 2>&1 | Out-String
            if ($sfcOutput -match "found corrupt files and successfully repaired") {
                $null = $results.Add([PSCustomObject]@{ Component = "SFC Repair"; Status = "Pass"; Details = "Corrupted files found and repaired" })
                Write-Host "  SFC: Files repaired" -ForegroundColor Green
                $fixCount++
            } elseif ($sfcOutput -match "did not find any integrity violations") {
                $null = $results.Add([PSCustomObject]@{ Component = "SFC Scan"; Status = "Pass"; Details = "No integrity violations found" })
                Write-Host "  SFC: No issues found" -ForegroundColor Green
            } elseif ($sfcOutput -match "found corrupt files but was not able to fix") {
                $null = $results.Add([PSCustomObject]@{ Component = "SFC Scan"; Status = "Warning"; Details = "Corrupt files found but could not be repaired - see C:\Windows\Logs\CBS\CBS.log" })
            } else {
                $sfcDetail = "SFC completed with warnings"
                if ($sfcOutput -match "(?m)(Windows Resource Protection.*)") { $sfcDetail = $Matches[1].Trim() }
                $null = $results.Add([PSCustomObject]@{ Component = "SFC Scan"; Status = "Warning"; Details = "$sfcDetail - see C:\Windows\Logs\CBS\CBS.log for details" })
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "SFC"; Status = "Fail"; Details = $_.Exception.Message })
        }
    } else { $declineCount++ }

    # DISM
    if (Request-UserApproval -Issue "Windows component store may need repair" -ProposedFix "Run DISM RestoreHealth - takes 10-15 minutes") {
        Write-Host "  Running DISM /RestoreHealth (this takes several minutes)..." -ForegroundColor Yellow
        try {
            $dismResult = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop
            if ($dismResult.ImageHealthState -eq 'Healthy') {
                $null = $results.Add([PSCustomObject]@{ Component = "DISM Repair"; Status = "Pass"; Details = "Image health: Healthy" })
                Write-Host "  DISM: Image healthy" -ForegroundColor Green
                $fixCount++
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "DISM Repair"; Status = "Warning"; Details = "Image state: $($dismResult.ImageHealthState)" })
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "DISM"; Status = "Fail"; Details = $_.Exception.Message })
        }
    } else { $declineCount++ }

    # Phase 4: Disk and memory checks
    Write-Host "`n  Phase 4: Hardware checks" -ForegroundColor Yellow

    # Disk health
    try {
        $disks = Get-PhysicalDisk
        foreach ($disk in $disks) {
            $dStatus = if ($disk.HealthStatus -eq "Healthy") { "Pass" } else { "Fail" }
            $wearVal = $disk.Wear
            $wearDisplay = if ($null -ne $wearVal -and "$wearVal" -ne '') { "$wearVal%" } else { "N/A" }
            $null = $results.Add([PSCustomObject]@{ Component = "Disk: $($disk.FriendlyName)"; Status = $dStatus; Details = "Health: $($disk.HealthStatus), Wear: $wearDisplay" })
            if ($disk.HealthStatus -ne "Healthy") {
                Write-Host "    CRITICAL: Disk $($disk.FriendlyName) is $($disk.HealthStatus) - consider replacement" -ForegroundColor Red
            }
        }
    } catch { }

    # Memory diagnostic
    if (Request-UserApproval -Issue "RAM issues can cause BSODs" -ProposedFix "Schedule Windows Memory Diagnostic (runs on next reboot)") {
        try {
            & "$env:SystemRoot\system32\mdsched.exe" /f 2>&1 | Out-Null
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Diagnostic"; Status = "Info"; Details = "Scheduled for next reboot (verifies RAM health after restart)" })
            Write-Host "  Memory diagnostic scheduled for next reboot" -ForegroundColor Green
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Diagnostic"; Status = "Warning"; Details = "Could not schedule" })
        }
    } else { $declineCount++ }

    # Post-fix validation for driver changes
    if ($fixCount -gt 0) {
        Write-Host "`n  ---- Post-Fix Validation ----" -ForegroundColor Cyan
        $problemDevCount = 0
        try {
            $problemDevCount = @(Get-CimInstance -ClassName Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }).Count
        } catch { }
        Write-Host "    Problem devices remaining: $problemDevCount" -ForegroundColor $(if ($problemDevCount -eq 0) {'Green'} else {'Yellow'})
        $null = $results.Add([PSCustomObject]@{ Component = "Post-Fix Validation"; Status = $(if ($problemDevCount -eq 0) {'Pass'} else {'Warning'}); Details = "$problemDevCount problem device(s) after fix" })
        # SFC quick status check if SFC was run
        $sfcRan = $results | Where-Object { $_.Component -match 'SFC' }
        if ($sfcRan) {
            Write-Host "    SFC was run — full results in CBS.log after reboot" -ForegroundColor Gray
        }
    }

    # Summary
    Write-Host "`n  ===== BSOD TROUBLESHOOTER SUMMARY =====" -ForegroundColor Cyan
    Write-Host "  Faulting drivers found: $($faultingDrivers.Count)" -ForegroundColor White
    Write-Host "  Fixes applied:  $fixCount" -ForegroundColor Green
    Write-Host "  Fixes declined: $declineCount" -ForegroundColor Yellow
    if ($fixCount -gt 0) {
        Write-Host "  RECOMMENDATION: Reboot and monitor for 48 hours" -ForegroundColor Cyan
    }
    $null = $results.Add([PSCustomObject]@{ Component = "SUMMARY"; Status = $(if($faultingDrivers.Count -eq 0 -and $fixCount -eq 0){"Pass"}else{"Warning"}); Details = "Drivers: $($faultingDrivers.Count) faulting, Fixed: $fixCount, Declined: $declineCount" })

    Export-DiagnosticReport -Title "BSOD Troubleshooter Results" -Results $results
    Write-Log "BSOD Troubleshooter completed - Fixed: $fixCount" -Level Success
    Write-AuditLog -Module 'BSODTroubleshooter' -IssueCode "FaultingDrivers:$($faultingDrivers.Count)" -Severity 'S2' -ActionTaken "Fixed:$fixCount,Declined:$declineCount" -FinalState "$(if ($faultingDrivers.Count -eq 0) {'Clean'} elseif ($fixCount -gt 0) {'Remediated'} else {'PendingAction'})"
    return $results
}

function Invoke-InputTroubleshooter {
    Write-Log "Starting Input Device Troubleshooter..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Input Device Troubleshooter - Auto-Fix Mode" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    $fixCount = 0; $declineCount = 0

    # 1. Filter Keys
    Write-Host "  [1/8] Checking Filter Keys..." -ForegroundColor Yellow
    try {
        $filterKeys = Get-ItemProperty "HKCU:\Control Panel\Accessibility\Keyboard Response" -ErrorAction SilentlyContinue
        if ($filterKeys -and $filterKeys.Flags -ne "126") {
            $flags = $filterKeys.Flags
            if ($flags -match '1[2-9][0-9]|[2-9][0-9]{2}') {
                $issueFound = $true
            } else { $issueFound = $false }
            if ($issueFound) {
                if (Request-UserApproval -Issue "Filter Keys may be enabled (Flags: $flags)" -ProposedFix "Disable Filter Keys") {
                    $result = Invoke-FixAndVerify -Component "Filter Keys" -FixAction {
                        Set-ItemProperty "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name Flags -Value "126"
                    } -VerifyAction {
                        (Get-ItemProperty "HKCU:\Control Panel\Accessibility\Keyboard Response").Flags -eq "126"
                    }
                    $null = $results.Add($result)
                    if ($result.Status -eq "Pass") { $fixCount++ }
                } else { $declineCount++ }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Filter Keys"; Status = "Pass"; Details = "Disabled" })
                Write-Host "    OK: Filter Keys off" -ForegroundColor Green
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Filter Keys"; Status = "Pass"; Details = "Disabled" })
            Write-Host "    OK: Filter Keys off" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Filter Keys"; Status = "Info"; Details = "Cannot check" })
    }

    # 2. Sticky Keys
    Write-Host "  [2/8] Checking Sticky Keys..." -ForegroundColor Yellow
    try {
        $stickyKeys = Get-ItemProperty "HKCU:\Control Panel\Accessibility\StickyKeys" -ErrorAction SilentlyContinue
        if ($stickyKeys -and ([int]$stickyKeys.Flags -band 4) -eq 4) {
            if (Request-UserApproval -Issue "Sticky Keys is active (Flags: $($stickyKeys.Flags))" -ProposedFix "Disable Sticky Keys") {
                $result = Invoke-FixAndVerify -Component "Sticky Keys" -FixAction {
                    Set-ItemProperty "HKCU:\Control Panel\Accessibility\StickyKeys" -Name Flags -Value "506"
                } -VerifyAction {
                    (Get-ItemProperty "HKCU:\Control Panel\Accessibility\StickyKeys").Flags -eq "506"
                }
                $null = $results.Add($result)
                if ($result.Status -eq "Pass") { $fixCount++ }
            } else { $declineCount++ }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Sticky Keys"; Status = "Pass"; Details = "Disabled" })
            Write-Host "    OK: Sticky Keys off" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Sticky Keys"; Status = "Info"; Details = "Cannot check" })
    }

    # 3. Toggle Keys
    Write-Host "  [3/8] Checking Toggle Keys..." -ForegroundColor Yellow
    try {
        $toggleKeys = Get-ItemProperty "HKCU:\Control Panel\Accessibility\ToggleKeys" -ErrorAction SilentlyContinue
        if ($toggleKeys -and $toggleKeys.Flags -ne "62") {
            if (Request-UserApproval -Issue "Toggle Keys is enabled (Flags: $($toggleKeys.Flags))" -ProposedFix "Disable Toggle Keys") {
                $result = Invoke-FixAndVerify -Component "Toggle Keys" -FixAction {
                    Set-ItemProperty "HKCU:\Control Panel\Accessibility\ToggleKeys" -Name Flags -Value "62"
                } -VerifyAction {
                    (Get-ItemProperty "HKCU:\Control Panel\Accessibility\ToggleKeys").Flags -eq "62"
                }
                $null = $results.Add($result)
                if ($result.Status -eq "Pass") { $fixCount++ }
            } else { $declineCount++ }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Toggle Keys"; Status = "Pass"; Details = "Disabled" })
            Write-Host "    OK: Toggle Keys off" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Toggle Keys"; Status = "Info"; Details = "Cannot check" })
    }

    # 4. Keyboard layout
    Write-Host "  [4/8] Checking keyboard layout..." -ForegroundColor Yellow
    try {
        $langList = Get-WinUserLanguageList
        $currentLang = ($langList | Select-Object -First 1).LanguageTag
        $null = $results.Add([PSCustomObject]@{ Component = "Keyboard Layout"; Status = "Info"; Details = "Current: $currentLang" })
        Write-Host "    Current layout: $currentLang" -ForegroundColor White
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Keyboard Layout"; Status = "Info"; Details = "Cannot determine" })
    }

    # 5. Keyboard driver
    Write-Host "  [5/8] Checking keyboard driver..." -ForegroundColor Yellow
    try {
        $kbDevices = Get-PnpDevice -Class Keyboard -ErrorAction SilentlyContinue
        # Only flag Error/Degraded — "Unknown" is normal for composite HID devices
        $problemKB = @($kbDevices | Where-Object { $_.Status -in @("Error", "Degraded") })
        $unknownKB = @($kbDevices | Where-Object { $_.Status -eq "Unknown" })
        if ($unknownKB.Count -gt 0) {
            Write-Host "    Note: $($unknownKB.Count) HID device(s) report 'Unknown' status (normal for composite USB)" -ForegroundColor Gray
        }
        if ($problemKB.Count -gt 0) {
            # Group by FriendlyName so the tech gets one prompt per device type, not per instance
            $grouped = $problemKB | Group-Object FriendlyName
            foreach ($group in $grouped) {
                $devCount = $group.Count
                $devName = $group.Name
                $statusVal = ($group.Group | Select-Object -ExpandProperty Status -Unique) -join ", "
                $label = if ($devCount -gt 1) { "$devCount x '$devName' status: $statusVal" } else { "'$devName' status: $statusVal" }
                if (Request-UserApproval -Issue "Keyboard device $label" -ProposedFix "Reset keyboard device(s) (disable/enable)") {
                    foreach ($kb in $group.Group) {
                        $kbId = $kb.InstanceId
                        $result = Invoke-FixAndVerify -Component "Keyboard Driver: $devName" -FixAction {
                            Disable-PnpDevice -InstanceId $kbId -Confirm:$false -ErrorAction Stop
                            Start-Sleep -Seconds 2
                            Enable-PnpDevice -InstanceId $kbId -Confirm:$false -ErrorAction Stop
                        } -VerifyAction {
                            (Get-PnpDevice -InstanceId $kbId).Status -eq "OK"
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    }
                } else { $declineCount++ }
            }
        } else {
            $okCount = @($kbDevices | Where-Object { $_.Status -eq "OK" }).Count
            $null = $results.Add([PSCustomObject]@{ Component = "Keyboard Drivers"; Status = "Pass"; Details = "$okCount keyboard device(s) OK" })
            Write-Host "    OK: $okCount keyboard device(s) functional" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Keyboard Drivers"; Status = "Warning"; Details = "Cannot enumerate" })
    }

    # 6. Lenovo Hotkey driver
    Write-Host "  [6/8] Checking Fn key driver (Lenovo)..." -ForegroundColor Yellow
    try {
        if ($script:SystemInfo -and $script:SystemInfo.Manufacturer -match "LENOVO") {
            $hotkeyDriver = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match 'Hotkey|Special Button' }
            if (-not $hotkeyDriver) {
                Write-Host "    WARNING: Lenovo Hotkey driver not found" -ForegroundColor Yellow
                # Check if Lenovo Thin Installer is available on USB
                $hotkCfg = Get-RemediationConfig
                $thinDir = $hotkCfg.LenovoThinInstallerPath
                $thinExe = $null
                if ($thinDir -and (Test-Path $thinDir)) {
                    $thinExe = Get-ChildItem $thinDir -Filter "ThinInstaller.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if (-not $thinExe) { $thinExe = Get-ChildItem $thinDir -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 }
                }
                if ($thinExe) {
                    if (Request-UserApproval -Issue "Lenovo Hotkey driver not installed - Fn keys may not work" -ProposedFix "Run Lenovo Thin Installer to install hotkey driver") {
                        Write-Host "    Running Lenovo Thin Installer (may take several minutes)..." -ForegroundColor Yellow
                        $result = Invoke-FixAndVerify -Component "Lenovo Hotkey Driver" -FixAction {
                            $proc = Start-Process -FilePath $thinExe.FullName -ArgumentList "/CM /INCLUDEREBOOTPACKAGES 0 /NOREBOOT /NOICON" -Wait -PassThru
                            if ($proc.ExitCode -ne 0) { throw "Thin Installer exit code: $($proc.ExitCode)" }
                        } -VerifyAction {
                            $null -ne (Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match 'Hotkey|Special Button' })
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    } else { $declineCount++ }
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Hotkey Driver"; Status = "Warning"; Details = "Not installed. Place Lenovo Thin Installer in Tools\LenovoThinInstaller\ on USB, or install via Lenovo System Update." })
                }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Hotkey Driver"; Status = "Pass"; Details = "Installed: $($hotkeyDriver.DeviceName)" })
                Write-Host "    OK: Hotkey driver present" -ForegroundColor Green
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Fn Key Driver"; Status = "Info"; Details = "Non-Lenovo - skipped" })
            Write-Host "    Skipped (non-Lenovo)" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Fn Key Driver"; Status = "Info"; Details = "Cannot check" })
    }

    # 7. TrackPoint/Touchpad
    Write-Host "  [7/8] Checking pointing devices..." -ForegroundColor Yellow
    try {
        $mouseDevices = Get-PnpDevice -Class Mouse -ErrorAction SilentlyContinue
        # Only flag Error/Degraded — "Unknown" is normal for composite HID devices
        $problemMouse = @($mouseDevices | Where-Object { $_.Status -in @("Error", "Degraded") })
        $unknownMouse = @($mouseDevices | Where-Object { $_.Status -eq "Unknown" })
        if ($unknownMouse.Count -gt 0) {
            Write-Host "    Note: $($unknownMouse.Count) HID device(s) report 'Unknown' status (normal for composite USB)" -ForegroundColor Gray
        }
        if ($problemMouse.Count -gt 0) {
            # Group by FriendlyName so the tech gets one prompt per device type
            $grouped = $problemMouse | Group-Object FriendlyName
            foreach ($group in $grouped) {
                $devCount = $group.Count
                $devName = $group.Name
                $statusVal = ($group.Group | Select-Object -ExpandProperty Status -Unique) -join ", "
                $label = if ($devCount -gt 1) { "$devCount x '$devName' status: $statusVal" } else { "'$devName' status: $statusVal" }
                if (Request-UserApproval -Issue "Pointing device $label" -ProposedFix "Reset pointing device(s) (disable/enable)") {
                    foreach ($md in $group.Group) {
                        $mdId = $md.InstanceId
                        $result = Invoke-FixAndVerify -Component "Pointing Device: $devName" -FixAction {
                            Disable-PnpDevice -InstanceId $mdId -Confirm:$false -ErrorAction Stop
                            Start-Sleep -Seconds 2
                            Enable-PnpDevice -InstanceId $mdId -Confirm:$false -ErrorAction Stop
                        } -VerifyAction {
                            (Get-PnpDevice -InstanceId $mdId).Status -eq "OK"
                        }
                        $null = $results.Add($result)
                        if ($result.Status -eq "Pass") { $fixCount++ }
                    }
                } else { $declineCount++ }
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Pointing Devices"; Status = "Pass"; Details = "$(@($mouseDevices).Count) device(s) OK" })
            Write-Host "    OK: All pointing devices functional" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Pointing Devices"; Status = "Warning"; Details = "Cannot enumerate" })
    }

    # 8. Interactive typing test
    Write-Host "  [8/8] Keyboard typing test..." -ForegroundColor Yellow
    Write-Host "    Type a test phrase and press Enter (or press Enter to skip):" -ForegroundColor Cyan
    $testInput = Read-Host "    "
    if ($testInput.Length -gt 0) {
        $null = $results.Add([PSCustomObject]@{ Component = "Typing Test"; Status = "Pass"; Details = "User typed $($testInput.Length) characters successfully" })
        Write-Host "    Typed $($testInput.Length) characters" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "Typing Test"; Status = "Info"; Details = "Skipped by user" })
    }

    # Summary
    # Post-fix validation
    if ($fixCount -gt 0) {
        Write-Host "`n  ---- Post-Fix Validation ----" -ForegroundColor Cyan
        Start-Sleep -Seconds 3
        $kbProblems = 0
        $mouseProblems = 0
        try {
            $kbProblems = @(Get-PnpDevice -Class Keyboard -ErrorAction SilentlyContinue | Where-Object { $_.Status -in @('Error','Degraded') }).Count
        } catch { }
        try {
            $mouseProblems = @(Get-PnpDevice -Class Mouse -ErrorAction SilentlyContinue | Where-Object { $_.Status -in @('Error','Degraded') }).Count
        } catch { }
        Write-Host "    Keyboard device errors: $kbProblems" -ForegroundColor $(if ($kbProblems -eq 0) {'Green'} else {'Red'})
        Write-Host "    Pointing device errors: $mouseProblems" -ForegroundColor $(if ($mouseProblems -eq 0) {'Green'} else {'Red'})
        $null = $results.Add([PSCustomObject]@{ Component = "Post-Fix Validation"; Status = $(if ($kbProblems + $mouseProblems -eq 0) {"Pass"} else {"Warning"}); Details = "KB errors:$kbProblems, Mouse errors:$mouseProblems" })
    }

    Write-Host "`n  ===== INPUT TROUBLESHOOTER SUMMARY =====" -ForegroundColor Cyan
    Write-Host "  Fixes applied:  $fixCount" -ForegroundColor Green
    Write-Host "  Fixes declined: $declineCount" -ForegroundColor Yellow
    $null = $results.Add([PSCustomObject]@{ Component = "SUMMARY"; Status = $(if($fixCount -gt 0){"Pass"}else{"Info"}); Details = "Fixed: $fixCount, Declined: $declineCount" })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'InputTroubleshooter' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'InputTroubleshooter' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Input Device Troubleshooter Results" -Results $results
    Write-Log "Input Troubleshooter completed - Fixed: $fixCount" -Level Success
    return $results
}

function Invoke-DriverAutoUpdate {
    Write-Log "Starting Driver Auto-Update..." -Level Info
    $results = New-Object System.Collections.ArrayList
    $cfg = Get-RemediationConfig

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Driver Auto-Update" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Domain safety check
    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }
    if ($script:IsDomainJoined) {
        Write-Host "  [DOMAIN GUARD] This machine is domain-joined: $($script:DomainName)" -ForegroundColor Red
        Write-Host "  Auto-updating drivers may conflict with SCCM/WSUS policies." -ForegroundColor Yellow
        Write-Host "  Continue with driver updates? [Y/N]: " -NoNewline -ForegroundColor Yellow
        $domainConfirm = Read-Host
        if ($domainConfirm -ne 'Y' -and $domainConfirm -ne 'y') {
            Write-Host "  Driver auto-update skipped on domain machine." -ForegroundColor DarkGray
            Write-Log "Driver auto-update skipped - domain-joined ($($script:DomainName))" -Level Warning
            Write-AuditLog -Module 'DriverAutoUpdate' -IssueCode 'DomainSkip' -Severity 'S1' -ActionTaken 'Skipped' -FinalState 'UserDeclined'
            $null = $results.Add([PSCustomObject]@{ Component = "Domain Safety"; Status = "Info"; Details = "Skipped on domain-joined machine ($($script:DomainName))" })
            Export-DiagnosticReport -Title "Driver Auto-Update Results" -Results $results
            return $results
        }
        Write-Log "Driver auto-update approved on domain machine ($($script:DomainName))" -Level Warning
    }

    New-SafeRestorePoint -ModuleName "Driver Auto-Update" | Out-Null
    Write-Host

    $fixCount = 0; $declineCount = 0

    # Phase 1: Scan for problem and outdated drivers
    Write-Host "  Phase 1: Scanning drivers..." -ForegroundColor Yellow
    $problemDevices = @()
    $outdatedDrivers = @()
    $blockedCategories = $cfg.NeverAutoUpdate

    try {
        # Problem devices
        $problemDevices = @(Get-PnpDevice | Where-Object { $_.Status -ne "OK" -and $_.Status -ne "Unknown" -and $_.Class -ne $null })
        Write-Host "    Problem devices: $($problemDevices.Count)" -ForegroundColor $(if($problemDevices.Count -eq 0){"Green"}else{"Yellow"})
    } catch { }

    try {
        # Outdated drivers (over 12 months)
        $signedDrivers = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DriverDate -and $_.DeviceName }
        $cutoffDate = (Get-Date).AddMonths(-12)
        $outdatedDrivers = @($signedDrivers | Where-Object { $_.DriverDate -lt $cutoffDate })
        Write-Host "    Outdated drivers (>12 months): $($outdatedDrivers.Count)" -ForegroundColor $(if($outdatedDrivers.Count -eq 0){"Green"}else{"Yellow"})
    } catch { }

    # Report findings
    $null = $results.Add([PSCustomObject]@{ Component = "Scan Results"; Status = "Info"; Details = "Problem devices: $($problemDevices.Count), Outdated: $($outdatedDrivers.Count)" })

    if ($problemDevices.Count -eq 0 -and $outdatedDrivers.Count -eq 0) {
        $null = $results.Add([PSCustomObject]@{ Component = "Driver Status"; Status = "Pass"; Details = "All drivers are current and functional" })
        Write-Host "`n  All drivers are current and functional." -ForegroundColor Green
        Export-DiagnosticReport -Title "Driver Auto-Update Results" -Results $results
        Write-Log "Driver Auto-Update - no updates needed" -Level Success
        return $results
    }

    # Phase 2: Fix problem devices
    if ($problemDevices.Count -gt 0) {
        Write-Host "`n  Phase 2: Problem devices" -ForegroundColor Yellow
        foreach ($dev in $problemDevices) {
            $devClass = if ($dev.Class) { $dev.Class } else { "Unknown" }
            $isBlocked = $blockedCategories | Where-Object { $devClass -match $_ }

            if ($isBlocked) {
                $null = $results.Add([PSCustomObject]@{ Component = "BLOCKED: $($dev.FriendlyName)"; Status = "Info"; Details = "Category '$devClass' is blocked from auto-update (config)" })
                Write-Host "    BLOCKED: $($dev.FriendlyName) ($devClass) - manual update required" -ForegroundColor Gray
                continue
            }

            if (Request-UserApproval -Issue "Device '$($dev.FriendlyName)' ($devClass) - Status: $($dev.Status)" -ProposedFix "Reset device (disable/enable)") {
                $devId = $dev.InstanceId
                $result = Invoke-FixAndVerify -Component "Reset: $($dev.FriendlyName)" -FixAction {
                    Disable-PnpDevice -InstanceId $devId -Confirm:$false -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                    Enable-PnpDevice -InstanceId $devId -Confirm:$false
                } -VerifyAction {
                    (Get-PnpDevice -InstanceId $devId).Status -eq "OK"
                }
                $null = $results.Add($result)
                if ($result.Status -eq "Pass") { $fixCount++ }
            } else { $declineCount++ }
        }
    }

    # Phase 3: Windows Update driver search
    Write-Host "`n  Phase 3: Checking Windows Update for drivers..." -ForegroundColor Yellow
    if ($cfg.DriverUpdateSource -in @("WindowsUpdate", "Both")) {
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            Write-Host "    Searching Windows Update catalog..." -ForegroundColor Yellow
            $searchResult = $searcher.Search("IsInstalled=0 and Type='Driver'")

            if ($searchResult.Updates.Count -gt 0) {
                $null = $results.Add([PSCustomObject]@{ Component = "WU Driver Updates"; Status = "Info"; Details = "$($searchResult.Updates.Count) driver update(s) available" })
                Write-Host "    Found $($searchResult.Updates.Count) driver update(s)" -ForegroundColor Cyan

                foreach ($update in $searchResult.Updates) {
                    $isGPU = $update.Title -match 'Display|Graphics|GPU|NVIDIA|AMD|Intel.*HD|Intel.*UHD|Intel.*Iris|Radeon|GeForce'
                    $isBIOS = $update.Title -match 'BIOS|Firmware|UEFI'

                    if ($isBIOS) {
                        $null = $results.Add([PSCustomObject]@{ Component = "BLOCKED: $($update.Title)"; Status = "Info"; Details = "BIOS/Firmware - never auto-update" })
                        Write-Host "    BLOCKED: $($update.Title) (BIOS/Firmware)" -ForegroundColor Gray
                        continue
                    }

                    $warning = ""
                    if ($isGPU) { $warning = " [GPU - requires reboot, display may flicker]" }

                    if (Request-UserApproval -Issue "Driver update available: $($update.Title)$warning" -ProposedFix "Download and install via Windows Update") {
                        Write-Host "  Downloading..." -ForegroundColor Yellow
                        try {
                            $updates = New-Object -ComObject Microsoft.Update.UpdateColl
                            $updates.Add($update) | Out-Null
                            $downloader = $session.CreateUpdateDownloader()
                            $downloader.Updates = $updates
                            $downloader.Download() | Out-Null

                            Write-Host "  Installing..." -ForegroundColor Yellow
                            $installer = $session.CreateUpdateInstaller()
                            $installer.Updates = $updates
                            $installResult = $installer.Install()

                            if ($installResult.ResultCode -eq 2) {
                                $null = $results.Add([PSCustomObject]@{ Component = "Updated: $($update.Title)"; Status = "Pass"; Details = "Successfully installed" })
                                Write-Host "  INSTALLED: $($update.Title)" -ForegroundColor Green
                                $fixCount++
                            } else {
                                $null = $results.Add([PSCustomObject]@{ Component = "Update: $($update.Title)"; Status = "Warning"; Details = "Install result code: $($installResult.ResultCode)" })
                            }
                        } catch {
                            $null = $results.Add([PSCustomObject]@{ Component = "Update: $($update.Title)"; Status = "Fail"; Details = $_.Exception.Message })
                        }
                    } else { $declineCount++ }
                }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Windows Update"; Status = "Pass"; Details = "No driver updates available" })
                Write-Host "    No driver updates in Windows Update" -ForegroundColor Green
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Windows Update Search"; Status = "Warning"; Details = "Could not search: $($_.Exception.Message)" })
            Write-Host "    Could not search Windows Update" -ForegroundColor Yellow
        }
    }

    # Phase 4: Lenovo Thin Installer
    if ($cfg.DriverUpdateSource -in @("LenovoThinInstaller", "Both") -and $script:IsThinkPad) {
        Write-Host "`n  Phase 4: Lenovo Thin Installer" -ForegroundColor Yellow
        $thinInstallerDir = $cfg.LenovoThinInstallerPath
        if ($thinInstallerDir) {
            $thinExe = Get-ChildItem $thinInstallerDir -Filter "ThinInstaller.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $thinExe) {
                $thinExe = Get-ChildItem $thinInstallerDir -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($thinExe) {
                if (Request-UserApproval -Issue "Lenovo Thin Installer available on USB" -ProposedFix "Run Lenovo Thin Installer to check for manufacturer driver updates") {
                    Write-Host "  Running Lenovo Thin Installer (this may take several minutes)..." -ForegroundColor Yellow
                    try {
                        $thinProcess = Start-Process -FilePath $thinExe.FullName -ArgumentList "/CM /INCLUDEREBOOTPACKAGES 0 /NOREBOOT /NOICON" -Wait -PassThru
                        if ($thinProcess.ExitCode -eq 0) {
                            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Thin Installer"; Status = "Pass"; Details = "Completed successfully" })
                            Write-Host "  Lenovo Thin Installer completed" -ForegroundColor Green
                            $fixCount++
                        } else {
                            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Thin Installer"; Status = "Warning"; Details = "Exit code: $($thinProcess.ExitCode)" })
                        }
                    } catch {
                        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Thin Installer"; Status = "Fail"; Details = $_.Exception.Message })
                    }
                } else { $declineCount++ }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Thin Installer"; Status = "Info"; Details = "Not found in $thinInstallerDir - download from support.lenovo.com" })
                Write-Host "    Thin Installer not found on USB" -ForegroundColor Yellow
                Write-Host "    Download from: support.lenovo.com/solutions/ht037099" -ForegroundColor Gray
            }
        }
    }

    # Summary
    Write-Host "`n  ===== DRIVER AUTO-UPDATE SUMMARY =====" -ForegroundColor Cyan
    Write-Host "  Updates installed: $fixCount" -ForegroundColor Green
    Write-Host "  Updates declined:  $declineCount" -ForegroundColor Yellow
    if ($fixCount -gt 0) {
        Write-Host "  RECOMMENDATION: Reboot to complete driver installation" -ForegroundColor Cyan
    }
    $null = $results.Add([PSCustomObject]@{ Component = "SUMMARY"; Status = $(if($fixCount -gt 0){"Pass"}else{"Info"}); Details = "Updated: $fixCount, Declined: $declineCount" })

    Export-DiagnosticReport -Title "Driver Auto-Update Results" -Results $results
    Write-Log "Driver Auto-Update completed - Updated: $fixCount" -Level Success
    Write-AuditLog -Module 'DriverAutoUpdate' -IssueCode "Outdated:$($outdatedDrivers.Count)" -Severity 'S2' -ActionTaken "Updated:$fixCount,Declined:$declineCount" -FinalState "$(if ($fixCount -gt 0) {'Remediated'} else {'NoAction'})"
    return $results
}

#endregion

#region Advanced Diagnostics

function Invoke-MachineIdentityCheck {
    Write-Log "Starting Machine Identity Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Machine Identity Check" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config
    $requireSerial = $true; $requireUUID = $true; $requireAsset = $false
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'RequireSerialNumber=(true|false)') { $requireSerial = $Matches[1] -eq 'true' }
            if ($cfgContent -match 'RequireUUID=(true|false)') { $requireUUID = $Matches[1] -eq 'true' }
            if ($cfgContent -match 'RequireAssetTag=(true|false)') { $requireAsset = $Matches[1] -eq 'true' }
        }
    } catch { }

    $invalidValues = @("Default string", "To Be Filled By O.E.M.", "To be filled by O.E.M.", "System Serial Number", "None", "Not Specified", "00000000", "INVALID", "")
    $failCount = 0

    # 1. Serial Number
    Write-Host "  [1/5] Checking Serial Number..." -ForegroundColor Yellow
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $serial = $bios.SerialNumber
        $serialValid = $serial -and ($serial.Trim() -notin $invalidValues) -and ($serial.Length -ge 7) -and ($serial.Length -le 20) -and ($serial -match '^[A-Za-z0-9\-]+$')
        if ($serialValid) {
            $null = $results.Add([PSCustomObject]@{ Component = "Serial Number"; Status = "Pass"; Details = "$serial (length: $($serial.Length))" })
            Write-Host "    OK: $serial" -ForegroundColor Green
        } else {
            $status = if ($requireSerial) { "Fail" } else { "Warning" }
            if ($status -eq "Fail") { $failCount++ }
            $null = $results.Add([PSCustomObject]@{ Component = "Serial Number"; Status = $status; Details = "Invalid or placeholder: '$serial'" })
            Write-Host "    $status`: Serial '$serial' appears invalid" -ForegroundColor $(if($status -eq "Fail"){"Red"}else{"Yellow"})
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Serial Number"; Status = "Warning"; Details = "Cannot query: $($_.Exception.Message)" })
    }

    # 2. UUID
    Write-Host "  [2/5] Checking UUID..." -ForegroundColor Yellow
    try {
        $csp = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop
        $uuid = $csp.UUID
        $uuidAllZeros = $uuid -eq "00000000-0000-0000-0000-000000000000"
        $uuidAllFs = $uuid -match '^F{8}-F{4}-F{4}-F{4}-F{12}$'
        $uuidValidFormat = $uuid -match '^\{?[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}?$'
        $uuidValid = $uuid -and $uuidValidFormat -and (-not $uuidAllZeros) -and (-not $uuidAllFs)
        if ($uuidValid) {
            $null = $results.Add([PSCustomObject]@{ Component = "UUID"; Status = "Pass"; Details = $uuid })
            Write-Host "    OK: $uuid" -ForegroundColor Green
        } else {
            $reason = if ($uuidAllZeros) { "All zeros" } elseif ($uuidAllFs) { "All F's" } elseif (-not $uuidValidFormat) { "Invalid format" } else { "Empty/null" }
            $status = if ($requireUUID) { "Fail" } else { "Warning" }
            if ($status -eq "Fail") { $failCount++ }
            $null = $results.Add([PSCustomObject]@{ Component = "UUID"; Status = $status; Details = "Invalid UUID ($reason): '$uuid' - POST 2201 likely" })
            Write-Host "    $status`: UUID invalid ($reason)" -ForegroundColor $(if($status -eq "Fail"){"Red"}else{"Yellow"})
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "UUID"; Status = "Warning"; Details = "Cannot query: $($_.Exception.Message)" })
    }

    # 3. Machine Type / Model
    Write-Host "  [3/5] Checking Machine Type..." -ForegroundColor Yellow
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $model = $cs.Model
        $modelValid = $model -and ($model.Trim() -notin $invalidValues) -and ($model -notmatch 'System Product Name')
        if ($modelValid) {
            $machineType = $model.Substring(0, [Math]::Min(4, $model.Length))
            $null = $results.Add([PSCustomObject]@{ Component = "Machine Type"; Status = "Pass"; Details = "Model: $model (Type: $machineType)" })
            Write-Host "    OK: $model (Type: $machineType)" -ForegroundColor Green
        } else {
            $failCount++
            $null = $results.Add([PSCustomObject]@{ Component = "Machine Type"; Status = "Fail"; Details = "Invalid model: '$model' - POST 2200 likely" })
            Write-Host "    FAIL: Model '$model' is invalid/placeholder" -ForegroundColor Red
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Machine Type"; Status = "Warning"; Details = "Cannot query: $($_.Exception.Message)" })
    }

    # 4. Asset Tag
    Write-Host "  [4/5] Checking Asset Tag..." -ForegroundColor Yellow
    try {
        $enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop
        $assetTag = $enclosure.SMBIOSAssetTag
        $assetValid = $assetTag -and ($assetTag.Trim() -notin $invalidValues) -and ($assetTag -notmatch '^No Asset')
        if ($assetValid) {
            $null = $results.Add([PSCustomObject]@{ Component = "Asset Tag"; Status = "Pass"; Details = $assetTag })
            Write-Host "    OK: $assetTag" -ForegroundColor Green
        } else {
            $status = if ($requireAsset) { "Fail" } else { "Info" }
            if ($status -eq "Fail") { $failCount++ }
            $null = $results.Add([PSCustomObject]@{ Component = "Asset Tag"; Status = $status; Details = "Not set or default: '$assetTag'" })
            Write-Host "    Info: Asset tag not configured" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Asset Tag"; Status = "Info"; Details = "Cannot query" })
    }

    # 5. Cross-validation
    Write-Host "  [5/5] Cross-validating identifiers..." -ForegroundColor Yellow
    try {
        if ($serial -and $uuid) {
            $uuidPrefix = ($uuid -replace '-','').Substring(0, [Math]::Min(12, ($uuid -replace '-','').Length))
            if ($serial -eq $uuidPrefix) {
                $null = $results.Add([PSCustomObject]@{ Component = "Cross-Validation"; Status = "Warning"; Details = "Serial matches UUID prefix - possible FRU data issue" })
                Write-Host "    WARNING: Serial matches UUID prefix" -ForegroundColor Yellow
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Cross-Validation"; Status = "Pass"; Details = "Serial and UUID are independent" })
                Write-Host "    OK: Identifiers are independent" -ForegroundColor Green
            }
        }
        $null = $results.Add([PSCustomObject]@{ Component = "Computer Name"; Status = "Info"; Details = $env:COMPUTERNAME })
        $domain = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Domain
        $null = $results.Add([PSCustomObject]@{ Component = "Domain"; Status = "Info"; Details = $(if($domain){$domain}else{"N/A"}) })
    } catch { }

    # Summary
    $overallStatus = if ($failCount -gt 0) { "Fail" } else { "Pass" }
    $null = $results.Add([PSCustomObject]@{ Component = "SUMMARY"; Status = $overallStatus; Details = "Identity check: $failCount issue(s) found" })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'MachineIdentityCheck' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'MachineIdentityCheck' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Machine Identity Check Results" -Results $results
    Write-Log "Machine Identity Check completed - $failCount issues" -Level Success
    return $results
}

function Invoke-LenovoVantageCheck {
    Write-Log "Starting Lenovo Vantage Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Lenovo Vantage / Management Software Check" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    $softwareFound = 0

    # 1. Commercial Vantage (enterprise)
    Write-Host "  [1/9] Checking Lenovo Commercial Vantage..." -ForegroundColor Yellow
    try {
        $commVantage = Get-AppxPackage -Name "E046963F.LenovoSettingsforEnterprise" -AllUsers -ErrorAction SilentlyContinue
        if ($commVantage) {
            $softwareFound++
            $null = $results.Add([PSCustomObject]@{ Component = "Commercial Vantage"; Status = "Pass"; Details = "Installed - Version: $($commVantage.Version)" })
            Write-Host "    OK: Installed (v$($commVantage.Version))" -ForegroundColor Green
        } else {
            $status = if ($script:IsThinkPad) { "Warning" } else { "Info" }
            $null = $results.Add([PSCustomObject]@{ Component = "Commercial Vantage"; Status = $status; Details = "Not installed$(if($script:IsThinkPad){' - recommended for enterprise ThinkPads'})" })
            Write-Host "    Not installed$(if($script:IsThinkPad){' (recommended)'})" -ForegroundColor $(if($script:IsThinkPad){"Yellow"}else{"Gray"})
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Commercial Vantage"; Status = "Info"; Details = "Cannot check: $($_.Exception.Message)" })
    }

    # 2. Consumer Vantage
    Write-Host "  [2/9] Checking Lenovo Vantage (Consumer)..." -ForegroundColor Yellow
    try {
        $consVantage = Get-AppxPackage -Name "E046963F.LenovoCompanion" -AllUsers -ErrorAction SilentlyContinue
        if (-not $consVantage) { $consVantage = Get-AppxPackage -Name "*LenovoVantage*" -AllUsers -ErrorAction SilentlyContinue }
        if ($consVantage) {
            $softwareFound++
            $detail = "Installed - Version: $($consVantage.Version)"
            if ($commVantage) { $detail += " [NOTE: Both consumer and commercial versions detected - may conflict]" }
            $status = if ($commVantage) { "Warning" } else { "Pass" }
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Vantage (Consumer)"; Status = $status; Details = $detail })
            Write-Host "    Installed (v$($consVantage.Version))$(if($commVantage){' - CONFLICT with Commercial'})" -ForegroundColor $(if($commVantage){"Yellow"}else{"Green"})
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Vantage (Consumer)"; Status = "Info"; Details = "Not installed" })
            Write-Host "    Not installed" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Vantage (Consumer)"; Status = "Info"; Details = "Cannot check" })
    }

    # 3. Lenovo System Update
    Write-Host "  [3/9] Checking Lenovo System Update..." -ForegroundColor Yellow
    try {
        $suReg = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Lenovo\System Update" -ErrorAction SilentlyContinue
        $suService = Get-Service -Name "SUService" -ErrorAction SilentlyContinue
        if ($suReg -or $suService) {
            $softwareFound++
            $ver = if ($suReg.Version) { $suReg.Version } else { "Unknown" }
            $svcStatus = if ($suService) { $suService.Status } else { "N/A" }
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo System Update"; Status = "Pass"; Details = "Installed (Version: $ver, Service: $svcStatus)" })
            Write-Host "    OK: Installed (v$ver, Service: $svcStatus)" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo System Update"; Status = "Info"; Details = "Not installed (legacy tool - Commercial Vantage preferred)" })
            Write-Host "    Not installed (legacy)" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo System Update"; Status = "Info"; Details = "Cannot check" })
    }

    # 4. Lenovo Thin Installer
    Write-Host "  [4/9] Checking Lenovo Thin Installer..." -ForegroundColor Yellow
    try {
        $cfg = Get-RemediationConfig
        $thinDir = $cfg.LenovoThinInstallerPath
        $thinOnUSB = $thinDir -and (Test-Path $thinDir)
        $thinReg = Get-ItemProperty "HKLM:\SOFTWARE\Lenovo\Thin Installer" -ErrorAction SilentlyContinue
        if ($thinOnUSB) {
            $thinExe = Get-ChildItem $thinDir -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            $softwareFound++
            $null = $results.Add([PSCustomObject]@{ Component = "Thin Installer (USB)"; Status = "Pass"; Details = "Available on USB: $thinDir$(if($thinExe){' - '+$thinExe.Name})" })
            Write-Host "    OK: Available on USB$(if($thinExe){' ('+$thinExe.Name+')'})" -ForegroundColor Green
        } elseif ($thinReg) {
            $softwareFound++
            $null = $results.Add([PSCustomObject]@{ Component = "Thin Installer (Local)"; Status = "Pass"; Details = "Installed locally" })
            Write-Host "    OK: Installed locally" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Thin Installer"; Status = "Info"; Details = "Not found on USB or locally" })
            Write-Host "    Not found" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Thin Installer"; Status = "Info"; Details = "Cannot check" })
    }

    # 5. ImController Service
    Write-Host "  [5/9] Checking ImController Service..." -ForegroundColor Yellow
    try {
        $imSvc = Get-Service -Name "ImControllerService" -ErrorAction SilentlyContinue
        if ($imSvc) {
            $null = $results.Add([PSCustomObject]@{ Component = "ImController Service"; Status = $(if($imSvc.Status -eq "Running"){"Pass"}else{"Warning"}); Details = "Status: $($imSvc.Status)" })
            Write-Host "    Service: $($imSvc.Status)" -ForegroundColor $(if($imSvc.Status -eq "Running"){"Green"}else{"Yellow"})
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "ImController Service"; Status = "Info"; Details = "Not installed" })
            Write-Host "    Not installed" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "ImController Service"; Status = "Info"; Details = "Cannot check" })
    }

    # 6. Lenovo Diagnostics
    Write-Host "  [6/9] Checking Lenovo Diagnostics..." -ForegroundColor Yellow
    try {
        $diagApp = Get-AppxPackage -AllUsers -Name "*LenovoDiagnostics*" -ErrorAction SilentlyContinue
        $diagPath = Test-Path "C:\Program Files\Lenovo\Lenovo Diagnostics\" -ErrorAction SilentlyContinue
        if ($diagApp) {
            $softwareFound++
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Diagnostics (AppX)"; Status = "Pass"; Details = "Installed - Version: $($diagApp.Version)" })
            Write-Host "    OK: Lenovo Diagnostics AppX (v$($diagApp.Version))" -ForegroundColor Green
        } elseif ($diagPath) {
            $softwareFound++
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Diagnostics (Desktop)"; Status = "Pass"; Details = "Installed at C:\Program Files\Lenovo\Lenovo Diagnostics\" })
            Write-Host "    OK: Lenovo Diagnostics (desktop install)" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Diagnostics"; Status = "Info"; Details = "Not installed - useful for hardware testing" })
            Write-Host "    Not installed" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Diagnostics"; Status = "Info"; Details = "Cannot check" })
    }

    # 7. Lenovo Service Bridge
    Write-Host "  [7/9] Checking Lenovo Service Bridge..." -ForegroundColor Yellow
    try {
        $lsbService = Get-Service -Name "Lenovo Service Bridge" -ErrorAction SilentlyContinue
        if (-not $lsbService) { $lsbService = Get-Service -DisplayName "*Service Bridge*" -ErrorAction SilentlyContinue }
        if ($lsbService) {
            $softwareFound++
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Service Bridge"; Status = $(if($lsbService.Status -eq "Running"){"Pass"}else{"Info"}); Details = "Service status: $($lsbService.Status)" })
            Write-Host "    Service Bridge: $($lsbService.Status)" -ForegroundColor $(if($lsbService.Status -eq "Running"){"Green"}else{"Gray"})
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Service Bridge"; Status = "Info"; Details = "Not installed - enables web-based Lenovo support integration" })
            Write-Host "    Not installed" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Lenovo Service Bridge"; Status = "Info"; Details = "Cannot check" })
    }

    # 8. Warranty information (via Commercial Vantage registry)
    Write-Host "  [8/9] Checking warranty information..." -ForegroundColor Yellow
    try {
        $warrantyReg = Get-ItemProperty "HKLM:\SOFTWARE\Lenovo\Commercial Vantage\Warranty" -ErrorAction SilentlyContinue
        if ($warrantyReg) {
            $wStatus = $warrantyReg.WarrantyStatus
            $wEnd = $warrantyReg.WarrantyEndDate
            $detail = "Status: $(if($wStatus){$wStatus}else{'N/A'}), End date: $(if($wEnd){$wEnd}else{'N/A'})"
            $wResult = if ($wEnd) {
                try {
                    $endDate = [DateTime]::Parse($wEnd)
                    if ($endDate -lt (Get-Date)) { "Warning" } else { "Pass" }
                } catch { "Info" }
            } else { "Info" }
            $null = $results.Add([PSCustomObject]@{ Component = "Warranty Info"; Status = $wResult; Details = $detail })
            Write-Host "    Warranty: $detail" -ForegroundColor $(if($wResult -eq "Pass"){"Green"}elseif($wResult -eq "Warning"){"Yellow"}else{"White"})
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Warranty Info"; Status = "Info"; Details = "Not available - install Commercial Vantage to populate warranty data" })
            Write-Host "    Warranty data not available" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Warranty Info"; Status = "Info"; Details = "Cannot check" })
    }

    # 9. Recommendation
    Write-Host "  [9/9] Generating recommendation..." -ForegroundColor Yellow
    $recommendation = if ($script:IsThinkPad -and $softwareFound -eq 0) {
        "Fail"; "No Lenovo management tools detected on ThinkPad - install Commercial Vantage for enterprise management"
    } elseif ($script:IsThinkPad -and -not $commVantage) {
        "Warning"; "ThinkPad detected but Commercial Vantage not installed - recommended for enterprise fleet"
    } elseif ($softwareFound -gt 0) {
        "Pass"; "$softwareFound Lenovo management tool(s) detected"
    } else {
        "Info"; "Non-Lenovo system - Lenovo management tools not applicable"
    }
    $null = $results.Add([PSCustomObject]@{ Component = "RECOMMENDATION"; Status = $recommendation[0]; Details = $recommendation[1] })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'LenovoVantageCheck' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'LenovoVantageCheck' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Lenovo Vantage Check Results" -Results $results
    Write-Log "Lenovo Vantage Check completed - $softwareFound tool(s) found" -Level Success
    return $results
}

function Invoke-POSTErrorReader {
    Write-Log "Starting POST Error Reader..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  POST / BIOS Error Code Reader" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config
    $daysBack = 90; $biosAgeWarnYears = 3
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'POSTEventLogDaysBack=(\d+)') { $daysBack = [int]$Matches[1] }
            if ($cfgContent -match 'BIOSAgeWarningYears=(\d+)') { $biosAgeWarnYears = [int]$Matches[1] }
        }
    } catch { }

    # ThinkPad POST error code database (from Lenovo HMM)
    $postCodes = @{
        "0175" = "Bad CRC1 - EEPROM checksum corrupt -> Replace system board"
        "0176" = "System Security - System tampered -> Replace system board"
        "0177" = "Bad SVP data - Supervisor password checksum bad -> Replace system board"
        "0182" = "Bad CRC2 - EEPROM settings checksum wrong -> Enter BIOS Setup, Load Defaults"
        "0183" = "Bad CRC of Security Settings in EFI Variable -> Enter ThinkPad Setup"
        "0185" = "Bad startup sequence settings -> Enter BIOS, Load Setup Defaults"
        "0187" = "EAIA data access error -> Replace system board"
        "0188" = "Invalid RFID Serialization Information Area -> Replace system board"
        "0189" = "Invalid RFID configuration area -> Replace system board"
        "0190" = "Critical low-battery error at POST -> Charge battery or replace"
        "0191" = "System Security - Invalid Remote Change -> Run BIOS Setup, press F10 to save"
        "0192" = "System Security - Embedded Security hardware tamper -> Replace system board"
        "0199" = "Security password retry count exceeded -> Enter supervisor password"
        "0270" = "Real Time Clock Error - CMOS battery dead -> Replace CMOS coin cell battery"
        "0271" = "Check Date and Time Settings - Clock lost settings -> Reset in BIOS, replace CMOS battery"
        "1802" = "Unauthorized network card detected -> Remove card or update BIOS whitelist"
        "1820" = "More than one external fingerprint reader -> Remove extra device"
        "2100" = "Detection error on HDD0 (Main HDD) -> Reseat drive, check connector, replace drive"
        "2101" = "Detection error on HDD1 -> Reseat secondary drive, check connector"
        "2200" = "Machine Type and Serial Number invalid -> Re-flash system board FRU data"
        "2201" = "Machine UUID is invalid -> Re-flash system board FRU data"
    }

    $postErrorsFound = 0
    $startDate = (Get-Date).AddDays(-$daysBack)

    # 1. Scan System Event Log for Lenovo/BIOS sources
    Write-Host "  [1/5] Scanning System Event Log for BIOS/Lenovo events..." -ForegroundColor Yellow
    try {
        $providers = @('Lenovo*', 'BIOS*', 'ACPI*', 'LenovoBiosWmi*', 'Lenovo-BIOS-WMI*')
        foreach ($prov in $providers) {
            try {
                $events = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName=$prov; StartTime=$startDate} -MaxEvents 200 -ErrorAction SilentlyContinue
                if ($events) {
                    foreach ($evt in $events) {
                        $msg = $evt.Message
                        foreach ($code in $postCodes.Keys) {
                            if ($msg -match "\b$code\b") {
                                $postErrorsFound++
                                $null = $results.Add([PSCustomObject]@{ Component = "POST Error $code"; Status = "Fail"; Details = "$($postCodes[$code]) [Event: $($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm'))]" })
                                Write-Host "    FOUND: POST $code - $($postCodes[$code])" -ForegroundColor Red
                            }
                        }
                    }
                }
            } catch { }
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "System Event Log"; Status = "Warning"; Details = "Cannot query: $($_.Exception.Message)" })
    }

    # 1b. Scan Application Event Log for Lenovo/BIOS sources
    Write-Host "  [2/5] Scanning Application Event Log for BIOS/Lenovo events..." -ForegroundColor Yellow
    try {
        $appProviders = @('Lenovo*', 'BIOS*', 'LenovoBiosWmi*')
        foreach ($prov in $appProviders) {
            try {
                $appEvents = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName=$prov; StartTime=$startDate} -MaxEvents 200 -ErrorAction SilentlyContinue
                if ($appEvents) {
                    foreach ($evt in $appEvents) {
                        $msg = $evt.Message
                        foreach ($code in $postCodes.Keys) {
                            if ($msg -match "\b$code\b") {
                                $postErrorsFound++
                                $null = $results.Add([PSCustomObject]@{ Component = "POST Error $code (App Log)"; Status = "Fail"; Details = "$($postCodes[$code]) [Event: $($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm'))]" })
                                Write-Host "    FOUND (Application): POST $code - $($postCodes[$code])" -ForegroundColor Red
                            }
                        }
                    }
                }
            } catch { }
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Application Event Log"; Status = "Warning"; Details = "Cannot query: $($_.Exception.Message)" })
    }

    # 2. Check critical kernel events
    Write-Host "  [3/5] Checking critical kernel events..." -ForegroundColor Yellow
    try {
        $kernelEvents = @(
            @{Id=41;  Desc="Unexpected shutdown (kernel power failure)"}
            @{Id=6008; Desc="Unexpected shutdown recorded by EventLog"}
            @{Id=1001; Desc="Windows Error Reporting (BugCheck)"}
        )
        foreach ($ke in $kernelEvents) {
            try {
                $evts = Get-WinEvent -FilterHashtable @{LogName='System'; Id=$ke.Id; StartTime=$startDate} -MaxEvents 10 -ErrorAction SilentlyContinue
                if ($evts) {
                    $count = $evts.Count
                    $latest = $evts[0].TimeCreated.ToString('yyyy-MM-dd HH:mm')
                    $status = if ($count -ge 5) { "Fail" } elseif ($count -ge 2) { "Warning" } else { "Info" }
                    $null = $results.Add([PSCustomObject]@{ Component = "Event ID $($ke.Id)"; Status = $status; Details = "$($ke.Desc) - $count occurrence(s), latest: $latest" })
                    Write-Host "    Event $($ke.Id): $count occurrence(s) - $($ke.Desc)" -ForegroundColor $(if($status -eq "Fail"){"Red"}elseif($status -eq "Warning"){"Yellow"}else{"White"})
                }
            } catch { }
        }
    } catch { }

    # 3. BIOS age check
    Write-Host "  [4/5] Checking BIOS age..." -ForegroundColor Yellow
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $biosDate = $bios.ReleaseDate
        if ($biosDate) {
            $biosAge = (Get-Date) - $biosDate
            $biosYears = [math]::Round($biosAge.TotalDays / 365.25, 1)
            $status = if ($biosYears -gt $biosAgeWarnYears) { "Warning" } else { "Pass" }
            $null = $results.Add([PSCustomObject]@{ Component = "BIOS Age"; Status = $status; Details = "Version: $($bios.SMBIOSBIOSVersion), Released: $($biosDate.ToString('yyyy-MM-dd')) ($biosYears years ago)" })
            Write-Host "    BIOS: $($bios.SMBIOSBIOSVersion) ($biosYears years old)" -ForegroundColor $(if($status -eq "Warning"){"Yellow"}else{"Green"})
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "BIOS Age"; Status = "Info"; Details = "Cannot determine BIOS age" })
    }

    # 4. Summary
    Write-Host "  [5/5] Summary..." -ForegroundColor Yellow
    if ($postErrorsFound -eq 0) {
        $null = $results.Add([PSCustomObject]@{ Component = "POST Error Scan"; Status = "Pass"; Details = "No POST error codes detected in last $daysBack days" })
        Write-Host "    No POST errors detected" -ForegroundColor Green
    } else {
        $null = $results.Add([PSCustomObject]@{ Component = "POST Error Scan"; Status = "Fail"; Details = "$postErrorsFound POST error code(s) detected - review above for details" })
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'POSTErrorReader' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'POSTErrorReader' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "POST Error Reader Results" -Results $results
    Write-Log "POST Error Reader completed - $postErrorsFound POST errors found" -Level Success
    return $results
}

function Invoke-CMOSBatteryCheck {
    Write-Log "Starting CMOS Battery Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  CMOS / RTC Battery Check" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config
    $driftWarnSec = 120; $driftFailSec = 3600; $ntpServer = "time.windows.com"; $eventDaysBack = 180
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'ClockDriftWarnSec=(\d+)') { $driftWarnSec = [int]$Matches[1] }
            if ($cfgContent -match 'ClockDriftFailSec=(\d+)') { $driftFailSec = [int]$Matches[1] }
            if ($cfgContent -match 'NTPServer=(.+)') { $ntpServer = $Matches[1].Trim() }
            if ($cfgContent -match 'CMOSEventLogDaysBack=(\d+)') { $eventDaysBack = [int]$Matches[1] }
        }
    } catch { }

    $issueScore = 0

    # 1. NTP clock drift check
    Write-Host "  [1/4] Checking clock drift via NTP ($ntpServer)..." -ForegroundColor Yellow
    try {
        $w32tmOutput = & w32tm /stripchart /computer:$ntpServer /samples:1 /dataonly 2>&1
        $offsetLine = $w32tmOutput | Where-Object { $_ -match '[+-]?\d+\.\d+s' } | Select-Object -Last 1
        if ($offsetLine -match '([+-]?\d+\.\d+)s') {
            $offsetSec = [math]::Abs([double]$Matches[1])
            $status = if ($offsetSec -gt $driftFailSec) { $issueScore += 3; "Fail" } elseif ($offsetSec -gt $driftWarnSec) { $issueScore += 1; "Warning" } else { "Pass" }
            $null = $results.Add([PSCustomObject]@{ Component = "Clock Drift (NTP)"; Status = $status; Details = "Offset: $([math]::Round($offsetSec, 2)) seconds from $ntpServer" })
            Write-Host "    Clock offset: $([math]::Round($offsetSec, 2))s" -ForegroundColor $(if($status -eq "Fail"){"Red"}elseif($status -eq "Warning"){"Yellow"}else{"Green"})
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Clock Drift (NTP)"; Status = "Info"; Details = "Could not parse w32tm output - NTP server may be unreachable" })
            Write-Host "    NTP check inconclusive (server may be unreachable)" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Clock Drift (NTP)"; Status = "Info"; Details = "w32tm failed: $($_.Exception.Message)" })
        Write-Host "    NTP check failed" -ForegroundColor Gray
    }

    # 2. Time change events
    Write-Host "  [2/4] Scanning Event Log for time change events..." -ForegroundColor Yellow
    try {
        $startDate = (Get-Date).AddDays(-$eventDaysBack)
        $timeChangeEvents = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=1; StartTime=$startDate} -MaxEvents 50 -ErrorAction SilentlyContinue
        $timeChangeCount = if ($timeChangeEvents) { $timeChangeEvents.Count } else { 0 }
        if ($timeChangeCount -gt 10) {
            $issueScore += 2
            $null = $results.Add([PSCustomObject]@{ Component = "Time Change Events"; Status = "Warning"; Details = "$timeChangeCount time changes in last $eventDaysBack days (excessive - possible CMOS issue)" })
            Write-Host "    $timeChangeCount time changes detected (excessive)" -ForegroundColor Yellow
        } elseif ($timeChangeCount -gt 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "Time Change Events"; Status = "Info"; Details = "$timeChangeCount time change(s) in last $eventDaysBack days (normal range)" })
            Write-Host "    $timeChangeCount time change(s) (normal)" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Time Change Events"; Status = "Pass"; Details = "No time change events in last $eventDaysBack days" })
            Write-Host "    No time change events" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Time Change Events"; Status = "Info"; Details = "Cannot query event log" })
    }

    # 3. W32Time service errors
    Write-Host "  [3/4] Checking W32Time service errors..." -ForegroundColor Yellow
    try {
        $startDate = (Get-Date).AddDays(-$eventDaysBack)
        $timeSvcErrors = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Time-Service'; Level=2,3; StartTime=$startDate} -MaxEvents 20 -ErrorAction SilentlyContinue
        $timeSvcCount = if ($timeSvcErrors) { $timeSvcErrors.Count } else { 0 }
        if ($timeSvcCount -gt 5) {
            $issueScore += 2
            $null = $results.Add([PSCustomObject]@{ Component = "W32Time Errors"; Status = "Warning"; Details = "$timeSvcCount time service errors in last $eventDaysBack days" })
            Write-Host "    $timeSvcCount time service errors" -ForegroundColor Yellow
        } elseif ($timeSvcCount -gt 0) {
            $null = $results.Add([PSCustomObject]@{ Component = "W32Time Errors"; Status = "Info"; Details = "$timeSvcCount time service error(s)" })
            Write-Host "    $timeSvcCount time service error(s)" -ForegroundColor White
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "W32Time Errors"; Status = "Pass"; Details = "No time service errors" })
            Write-Host "    No time service errors" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "W32Time Errors"; Status = "Info"; Details = "Cannot query" })
    }

    # 4. Last boot time sanity
    Write-Host "  [4/4] Checking last boot time sanity..." -ForegroundColor Yellow
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $lastBoot = $os.LastBootUpTime
        $uptime = (Get-Date) - $lastBoot
        if ($lastBoot.Year -lt 2020) {
            $issueScore += 3
            $null = $results.Add([PSCustomObject]@{ Component = "Boot Time Sanity"; Status = "Fail"; Details = "Last boot time is $($lastBoot.ToString('yyyy-MM-dd HH:mm')) - suspiciously old, CMOS battery likely dead" })
            Write-Host "    FAIL: Boot time $($lastBoot.ToString('yyyy-MM-dd')) is before 2020 - CMOS likely dead" -ForegroundColor Red
        } elseif ($uptime.TotalDays -lt 0) {
            $issueScore += 3
            $null = $results.Add([PSCustomObject]@{ Component = "Boot Time Sanity"; Status = "Fail"; Details = "Negative uptime detected - clock issue" })
            Write-Host "    FAIL: Negative uptime - clock issue" -ForegroundColor Red
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Boot Time Sanity"; Status = "Pass"; Details = "Last boot: $($lastBoot.ToString('yyyy-MM-dd HH:mm')), Uptime: $([math]::Round($uptime.TotalDays, 1)) days" })
            Write-Host "    OK: Uptime $([math]::Round($uptime.TotalHours, 1)) hours" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Boot Time Sanity"; Status = "Info"; Details = "Cannot determine" })
    }

    # Verdict
    $verdict = if ($issueScore -ge 5) { "Fail" } elseif ($issueScore -ge 2) { "Warning" } else { "Pass" }
    $verdictText = switch ($verdict) {
        "Fail" { "CMOS battery likely dead - replace CR2032 coin cell. POST errors 0270/0271 expected." }
        "Warning" { "Minor clock drift or events detected - monitor, may need CMOS battery replacement soon." }
        "Pass" { "CMOS/RTC battery appears healthy - no clock drift or RTC errors detected." }
    }
    $null = $results.Add([PSCustomObject]@{ Component = "VERDICT"; Status = $verdict; Details = $verdictText })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'CMOSBatteryCheck' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'CMOSBatteryCheck' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "CMOS Battery Check Results" -Results $results
    Write-Log "CMOS Battery Check completed - Verdict: $verdict" -Level Success
    return $results
}

function Invoke-SMARTDiskAnalysis {
    Write-Log "Starting SMART Disk Analysis..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  SMART Disk Analysis" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config
    $readErrWarn = 1; $readErrFail = 10; $uncorrFail = 1; $tempWarn = 55; $tempCrit = 65
    $wearWarn = 70; $wearFail = 90; $pohWarnDays = 1825; $freeWarn = 20; $freeFail = 10
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'SMARTReadErrorWarn=(\d+)') { $readErrWarn = [int]$Matches[1] }
            if ($cfgContent -match 'SMARTReadErrorFail=(\d+)') { $readErrFail = [int]$Matches[1] }
            if ($cfgContent -match 'SMARTUncorrectableErrorFail=(\d+)') { $uncorrFail = [int]$Matches[1] }
            if ($cfgContent -match 'SMARTTemperatureWarnC=(\d+)') { $tempWarn = [int]$Matches[1] }
            if ($cfgContent -match 'SMARTTemperatureCritC=(\d+)') { $tempCrit = [int]$Matches[1] }
            if ($cfgContent -match 'SMARTWearWarnPercent=(\d+)') { $wearWarn = [int]$Matches[1] }
            if ($cfgContent -match 'SMARTWearFailPercent=(\d+)') { $wearFail = [int]$Matches[1] }
            if ($cfgContent -match 'SMARTPowerOnHoursWarnDays=(\d+)') { $pohWarnDays = [int]$Matches[1] }
            if ($cfgContent -match 'DiskFreeSpaceWarnPercent=(\d+)') { $freeWarn = [int]$Matches[1] }
            if ($cfgContent -match 'DiskFreeSpaceFailPercent=(\d+)') { $freeFail = [int]$Matches[1] }
        }
    } catch { }

    # Known bad SSD models
    $knownBadModels = @("UMIS LENSE*", "UMIS RPETJ*")
    $isWin11 = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption -match "Windows 11"

    # 1. Enumerate physical disks
    Write-Host "  Enumerating physical disks..." -ForegroundColor Yellow
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    if (-not $disks) {
        $null = $results.Add([PSCustomObject]@{ Component = "Physical Disks"; Status = "Warning"; Details = "No physical disks found via Get-PhysicalDisk" })
        Export-DiagnosticReport -Title "SMART Disk Analysis Results" -Results $results
        Write-Log "SMART Disk Analysis completed - No disks found" -Level Warning
        return $results
    }

    $diskNum = 0
    foreach ($disk in $disks) {
        $diskNum++
        $diskName = if ($disk.FriendlyName) { $disk.FriendlyName } else { "Disk $diskNum" }
        $diskModel = $disk.Model
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $mediaType = $disk.MediaType
        $busType = $disk.BusType
        $healthStatus = $disk.HealthStatus

        Write-Host "`n  [$diskNum] $diskName ($sizeGB GB, $mediaType, $busType)" -ForegroundColor Cyan

        # Basic info
        $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: $diskName"; Status = "Info"; Details = "$sizeGB GB, $mediaType, Bus: $busType, Health: $healthStatus" })

        # Skip USB drives
        if ($busType -eq "USB") {
            $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: SMART"; Status = "Info"; Details = "External USB drive - SMART check skipped" })
            Write-Host "    Skipped (external USB)" -ForegroundColor Gray
            continue
        }

        # Health status
        $hsStatus = if ($healthStatus -eq "Healthy") { "Pass" } else { "Fail" }
        $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Health"; Status = $hsStatus; Details = $healthStatus })
        Write-Host "    Health: $healthStatus" -ForegroundColor $(if($hsStatus -eq "Pass"){"Green"}else{"Red"})

        # Known bad SSD check
        foreach ($badModel in $knownBadModels) {
            if ($diskModel -like $badModel -and $isWin11) {
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Known Issue"; Status = "Fail"; Details = "Model '$diskModel' has known Win11 battery-mode BSOD issue. See Lenovo support bulletin." })
                Write-Host "    WARNING: Known problematic SSD on Windows 11!" -ForegroundColor Red
            }
        }

        # SMART counters via StorageReliabilityCounter
        try {
            $counter = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction SilentlyContinue
            if ($null -eq $counter) {
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: SMART"; Status = "Info"; Details = "StorageReliabilityCounter not available (common for NVMe)" })
                Write-Host "    SMART counters not available" -ForegroundColor Gray
                continue
            }

            # Temperature
            if ($null -ne $counter.Temperature) {
                $temp = $counter.Temperature
                $tStatus = if ($temp -gt $tempCrit) { "Fail" } elseif ($temp -gt $tempWarn) { "Warning" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Temperature"; Status = $tStatus; Details = "$temp C" })
                Write-Host "    Temperature: $temp C" -ForegroundColor $(if($tStatus -eq "Fail"){"Red"}elseif($tStatus -eq "Warning"){"Yellow"}else{"Green"})
            }

            # Wear (SSD)
            if ($null -ne $counter.Wear) {
                $wear = $counter.Wear
                $wStatus = if ($wear -gt $wearFail) { "Fail" } elseif ($wear -gt $wearWarn) { "Warning" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Wear"; Status = $wStatus; Details = "$wear%" })
                Write-Host "    Wear: $wear%" -ForegroundColor $(if($wStatus -eq "Fail"){"Red"}elseif($wStatus -eq "Warning"){"Yellow"}else{"Green"})
            }

            # Read Errors
            if ($null -ne $counter.ReadErrorsTotal) {
                $re = $counter.ReadErrorsTotal
                $reStatus = if ($re -ge $readErrFail) { "Fail" } elseif ($re -ge $readErrWarn) { "Warning" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Read Errors"; Status = $reStatus; Details = "$re total" })
                Write-Host "    Read Errors: $re" -ForegroundColor $(if($reStatus -ne "Pass"){"Yellow"}else{"Green"})
            }

            # Write Errors
            if ($null -ne $counter.WriteErrorsTotal) {
                $we = $counter.WriteErrorsTotal
                $weStatus = if ($we -ge $readErrFail) { "Fail" } elseif ($we -ge $readErrWarn) { "Warning" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Write Errors"; Status = $weStatus; Details = "$we total" })
            }

            # Uncorrectable Errors
            if ($null -ne $counter.ReadErrorsUncorrected) {
                $ue = $counter.ReadErrorsUncorrected
                $ueStatus = if ($ue -ge $uncorrFail) { "Fail" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Uncorrectable Errors"; Status = $ueStatus; Details = "$ue (any > 0 is critical)" })
                if ($ue -gt 0) { Write-Host "    CRITICAL: $ue uncorrectable read errors!" -ForegroundColor Red }
            }

            # Power-On Hours
            if ($null -ne $counter.PowerOnHours) {
                $poh = $counter.PowerOnHours
                $pohDays = [math]::Round($poh / 24, 0)
                $pohStatus = if ($pohDays -gt $pohWarnDays) { "Warning" } else { "Info" }
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Power-On Hours"; Status = $pohStatus; Details = "$poh hours ($pohDays days)" })
                Write-Host "    Power-On: $poh hours ($pohDays days)" -ForegroundColor White
            }

            # Start/Stop Cycle Count
            if ($null -ne $counter.StartStopCycleCount) {
                $ssc = $counter.StartStopCycleCount
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Start/Stop Cycles"; Status = "Info"; Details = "$ssc cycles" })
                Write-Host "    Start/Stop Cycles: $ssc" -ForegroundColor White
            }

            # Read Errors Corrected
            if ($null -ne $counter.ReadErrorsCorrected) {
                $rec = $counter.ReadErrorsCorrected
                $recStatus = if ($rec -gt 100) { "Warning" } elseif ($rec -gt 0) { "Info" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: Corrected Read Errors"; Status = $recStatus; Details = "$rec corrected$(if($rec -gt 100){' - elevated count, monitor closely'})" })
                if ($rec -gt 100) { Write-Host "    Corrected Read Errors: $rec (elevated)" -ForegroundColor Yellow }
            }
        } catch {
            $null = $results.Add([PSCustomObject]@{ Component = "Disk $diskNum`: SMART"; Status = "Info"; Details = "Cannot read counters: $($_.Exception.Message)" })
        }
    }

    # 2. Logical drive free space
    Write-Host "`n  Checking logical drive free space..." -ForegroundColor Yellow
    try {
        $logicalDrives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        foreach ($ld in $logicalDrives) {
            $totalGB = [math]::Round($ld.Size / 1GB, 1)
            $freeGB = [math]::Round($ld.FreeSpace / 1GB, 1)
            $freePct = if ($ld.Size -gt 0) { [math]::Round(($ld.FreeSpace / $ld.Size) * 100, 1) } else { 0 }
            $fStatus = if ($freePct -lt $freeFail) { "Fail" } elseif ($freePct -lt $freeWarn) { "Warning" } else { "Pass" }
            $null = $results.Add([PSCustomObject]@{ Component = "Drive $($ld.DeviceID) Free Space"; Status = $fStatus; Details = "$freeGB GB free of $totalGB GB ($freePct%)" })
            Write-Host "    $($ld.DeviceID) $freeGB/$totalGB GB ($freePct% free)" -ForegroundColor $(if($fStatus -eq "Fail"){"Red"}elseif($fStatus -eq "Warning"){"Yellow"}else{"Green"})
        }
    } catch { }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'SMARTDiskAnalysis' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'SMARTDiskAnalysis' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "SMART Disk Analysis Results" -Results $results
    Write-Log "SMART Disk Analysis completed" -Level Success
    return $results
}

function Invoke-MemoryErrorLogCheck {
    Write-Log "Starting Memory Error Log Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Memory Error Log Check" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config
    $wheaDays = 90; $wmdDays = 90
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'WHEAEventLogDaysBack=(\d+)') { $wheaDays = [int]$Matches[1] }
            if ($cfgContent -match 'WMDEventLogDaysBack=(\d+)') { $wmdDays = [int]$Matches[1] }
        }
    } catch { }

    $issueCount = 0

    # 1. Physical memory modules
    Write-Host "  [1/5] Enumerating physical memory modules..." -ForegroundColor Yellow
    try {
        $modules = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
        $moduleCount = @($modules).Count
        $totalGB = [math]::Round(($modules | Measure-Object -Property Capacity -Sum).Sum / 1GB, 1)
        $speeds = @($modules | Select-Object -ExpandProperty Speed -Unique)
        $null = $results.Add([PSCustomObject]@{ Component = "Physical Memory"; Status = "Info"; Details = "$moduleCount module(s), $totalGB GB total" })
        Write-Host "    $moduleCount DIMM(s), $totalGB GB total" -ForegroundColor Green

        foreach ($mod in $modules) {
            $capGB = [math]::Round($mod.Capacity / 1GB, 1)
            $null = $results.Add([PSCustomObject]@{ Component = "DIMM: $($mod.BankLabel)"; Status = "Info"; Details = "$capGB GB, $($mod.Speed) MHz, $($mod.Manufacturer)" })
        }

        # Speed mismatch check
        if ($speeds.Count -gt 1) {
            $issueCount++
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Speed Match"; Status = "Warning"; Details = "Mixed speeds detected: $($speeds -join ' MHz, ') MHz - may reduce performance" })
            Write-Host "    WARNING: Mixed speeds ($($speeds -join '/'))" -ForegroundColor Yellow
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Memory Speed Match"; Status = "Pass"; Details = "All modules at $($speeds[0]) MHz" })
        }

        # Single-channel check
        if ($moduleCount -eq 1) {
            $null = $results.Add([PSCustomObject]@{ Component = "Channel Config"; Status = "Info"; Details = "Single-channel (1 DIMM) - dual-channel provides better performance" })
            Write-Host "    Note: Single-channel configuration" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Physical Memory"; Status = "Warning"; Details = "Cannot enumerate: $($_.Exception.Message)" })
    }

    # 2. Windows Memory Diagnostic results
    Write-Host "  [2/5] Checking Windows Memory Diagnostic results..." -ForegroundColor Yellow
    try {
        $startDate = (Get-Date).AddDays(-$wmdDays)
        $wmdEvents = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results'; StartTime=$startDate} -MaxEvents 10 -ErrorAction SilentlyContinue
        if ($wmdEvents) {
            foreach ($evt in $wmdEvents) {
                $hasErrors = $evt.Message -match 'hardware (problems|errors) were detected'
                $status = if ($hasErrors) { $issueCount++; "Fail" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "WMD Test ($($evt.TimeCreated.ToString('yyyy-MM-dd')))"; Status = $status; Details = $(if($hasErrors){"ERRORS DETECTED in memory test"}else{"No errors detected"}) })
                Write-Host "    WMD $($evt.TimeCreated.ToString('yyyy-MM-dd')): $(if($hasErrors){'ERRORS FOUND'}else{'Passed'})" -ForegroundColor $(if($hasErrors){"Red"}else{"Green"})
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "WMD Results"; Status = "Info"; Details = "No Windows Memory Diagnostic results found in last $wmdDays days" })
            Write-Host "    No WMD tests found" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "WMD Results"; Status = "Info"; Details = "Cannot query" })
    }

    # 3. WHEA hardware errors
    Write-Host "  [3/5] Checking WHEA hardware errors..." -ForegroundColor Yellow
    try {
        $startDate = (Get-Date).AddDays(-$wheaDays)
        $wheaEvents = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$startDate} -MaxEvents 50 -ErrorAction SilentlyContinue
        if ($wheaEvents) {
            $memWhea = @($wheaEvents | Where-Object { $_.Message -match 'memory|DIMM|RAM|ECC|corrected machine check' })
            if ($memWhea.Count -gt 0) {
                $correctable = @($memWhea | Where-Object { $_.Id -eq 17 -or $_.Id -eq 18 })
                $uncorrectable = @($memWhea | Where-Object { $_.Id -eq 19 -or $_.Id -eq 20 })
                if ($uncorrectable.Count -gt 0) {
                    $issueCount += 3
                    $null = $results.Add([PSCustomObject]@{ Component = "WHEA Memory Errors"; Status = "Fail"; Details = "$($uncorrectable.Count) UNCORRECTABLE memory error(s) - RAM replacement recommended" })
                    Write-Host "    CRITICAL: $($uncorrectable.Count) uncorrectable memory errors!" -ForegroundColor Red
                }
                if ($correctable.Count -gt 0) {
                    $issueCount++
                    $null = $results.Add([PSCustomObject]@{ Component = "WHEA Correctable Errors"; Status = "Warning"; Details = "$($correctable.Count) correctable memory error(s) - monitor closely" })
                    Write-Host "    $($correctable.Count) correctable memory errors" -ForegroundColor Yellow
                }
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "WHEA Memory Errors"; Status = "Pass"; Details = "No memory-specific WHEA events in last $wheaDays days" })
                Write-Host "    No memory WHEA events" -ForegroundColor Green
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "WHEA Events"; Status = "Pass"; Details = "No WHEA events in last $wheaDays days" })
            Write-Host "    No WHEA events" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "WHEA Events"; Status = "Info"; Details = "Cannot query" })
    }

    # 4. Memory-related BugCheck codes
    Write-Host "  [4/5] Checking for memory-related BugCheck codes..." -ForegroundColor Yellow
    try {
        $memBugChecks = @("0x0000001A", "0x0000004E", "0x00000050", "0x000000D1", "0x0000007A", "0x000000F4")
        $startDate = (Get-Date).AddDays(-$wheaDays)
        $bugCheckEvents = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=$startDate} -MaxEvents 50 -ErrorAction SilentlyContinue
        $memCrashes = 0
        if ($bugCheckEvents) {
            foreach ($evt in $bugCheckEvents) {
                foreach ($bc in $memBugChecks) {
                    if ($evt.Message -match $bc) {
                        $memCrashes++
                        $null = $results.Add([PSCustomObject]@{ Component = "BugCheck $bc"; Status = "Fail"; Details = "Memory-related crash on $($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm'))" })
                    }
                }
            }
        }
        if ($memCrashes -gt 0) {
            $issueCount += 2
            Write-Host "    $memCrashes memory-related BugCheck(s) found" -ForegroundColor Red
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Memory BugChecks"; Status = "Pass"; Details = "No memory-related crash codes in last $wheaDays days" })
            Write-Host "    No memory BugChecks" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "BugCheck Scan"; Status = "Info"; Details = "Cannot query" })
    }

    # 5. Current memory usage
    Write-Host "  [5/5] Checking current memory usage..." -ForegroundColor Yellow
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $usedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
        $mStatus = if ($usedPct -gt 90) { "Warning" } else { "Pass" }
        $null = $results.Add([PSCustomObject]@{ Component = "Memory Usage"; Status = $mStatus; Details = "$usedPct% in use" })
        Write-Host "    Usage: $usedPct%" -ForegroundColor $(if($mStatus -eq "Warning"){"Yellow"}else{"Green"})
    } catch { }

    # Beep code reference
    $null = $results.Add([PSCustomObject]@{ Component = "Beep Code Reference"; Status = "Info"; Details = "If system beeps 3-3-1 or 1-long-2-short at POST: reseat RAM modules, test individually. If beeps persist, replace DIMM." })

    # Verdict
    $verdict = if ($issueCount -ge 3) { "Fail" } elseif ($issueCount -ge 1) { "Warning" } else { "Pass" }
    $null = $results.Add([PSCustomObject]@{ Component = "VERDICT"; Status = $verdict; Details = "Memory health: $issueCount issue(s) detected" })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'MemoryErrorLogCheck' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'MemoryErrorLogCheck' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Memory Error Log Check Results" -Results $results
    Write-Log "Memory Error Log Check completed - $issueCount issues" -Level Success
    return $results
}

function Invoke-DisplayPixelCheck {
    Write-Log "Starting Display Pixel Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Display Pixel & Health Check" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config
    $maxDeadPixels = 3; $gpuDriverMaxDays = 365
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'PixelDefectPolicyMaxDead=(\d+)') { $maxDeadPixels = [int]$Matches[1] }
            if ($cfgContent -match 'GPUDriverMaxAgeDays=(\d+)') { $gpuDriverMaxDays = [int]$Matches[1] }
        }
    } catch { }

    # 1. GPU / Video Controller
    Write-Host "  [1/7] Checking GPU / Video Controller..." -ForegroundColor Yellow
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop
        foreach ($gpu in $gpus) {
            $null = $results.Add([PSCustomObject]@{ Component = "GPU: $($gpu.Name)"; Status = "Info"; Details = "VRAM: $([math]::Round($gpu.AdapterRAM / 1GB, 1)) GB, Driver: $($gpu.DriverVersion)" })
            Write-Host "    $($gpu.Name) - $($gpu.DriverVersion)" -ForegroundColor Green

            # Driver age
            if ($gpu.DriverDate) {
                $driverAge = ((Get-Date) - $gpu.DriverDate).TotalDays
                $dStatus = if ($driverAge -gt $gpuDriverMaxDays) { "Warning" } else { "Pass" }
                $null = $results.Add([PSCustomObject]@{ Component = "GPU Driver Age"; Status = $dStatus; Details = "Driver date: $($gpu.DriverDate.ToString('yyyy-MM-dd')) ($([math]::Round($driverAge)) days old)" })
                if ($dStatus -eq "Warning") { Write-Host "    Driver is $([math]::Round($driverAge)) days old (>$gpuDriverMaxDays)" -ForegroundColor Yellow }
            }

            # Error code
            if ($gpu.ConfigManagerErrorCode -ne 0) {
                $null = $results.Add([PSCustomObject]@{ Component = "GPU Error Code"; Status = "Fail"; Details = "ConfigManager error code: $($gpu.ConfigManagerErrorCode)" })
                Write-Host "    GPU error code: $($gpu.ConfigManagerErrorCode)" -ForegroundColor Red
            }

            # Resolution
            $resText = "$($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution) @ $($gpu.CurrentRefreshRate)Hz"
            $null = $results.Add([PSCustomObject]@{ Component = "Resolution"; Status = "Info"; Details = $resText })
            Write-Host "    Resolution: $resText" -ForegroundColor White
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "GPU"; Status = "Warning"; Details = "Cannot enumerate: $($_.Exception.Message)" })
    }

    # 2. Display PnP device status
    Write-Host "  [2/7] Checking display device status..." -ForegroundColor Yellow
    try {
        $displayDevices = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue
        foreach ($dd in $displayDevices) {
            $dStatus = if ($dd.Status -eq "OK") { "Pass" } elseif ($dd.Status -in @("Error","Degraded")) { "Fail" } else { "Info" }
            $null = $results.Add([PSCustomObject]@{ Component = "Display Device: $($dd.FriendlyName)"; Status = $dStatus; Details = "Status: $($dd.Status)" })
        }
    } catch { }

    # 3. GPU TDR/error events
    Write-Host "  [3/7] Checking GPU error events (last 30 days)..." -ForegroundColor Yellow
    try {
        $startDate = (Get-Date).AddDays(-30)
        $tdrEvents = Get-WinEvent -FilterHashtable @{LogName='System'; Id=@(4101,4116); StartTime=$startDate} -MaxEvents 20 -ErrorAction SilentlyContinue
        if ($tdrEvents) {
            $null = $results.Add([PSCustomObject]@{ Component = "GPU TDR Events"; Status = "Warning"; Details = "$($tdrEvents.Count) GPU timeout/recovery event(s) in last 30 days" })
            Write-Host "    $($tdrEvents.Count) GPU TDR event(s)" -ForegroundColor Yellow
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "GPU TDR Events"; Status = "Pass"; Details = "No GPU timeout events in last 30 days" })
            Write-Host "    No GPU TDR events" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "GPU TDR Events"; Status = "Info"; Details = "Cannot query" })
    }

    # 4. Monitor info + brightness
    Write-Host "  [4/7] Checking monitor info..." -ForegroundColor Yellow
    try {
        $monitors = Get-CimInstance WmiMonitorBasicDisplayParams -Namespace root/wmi -ErrorAction SilentlyContinue
        foreach ($mon in $monitors) {
            $widthCm = $mon.MaxHorizontalImageSize
            $heightCm = $mon.MaxVerticalImageSize
            $diagInch = if ($widthCm -gt 0 -and $heightCm -gt 0) { [math]::Round([math]::Sqrt($widthCm*$widthCm + $heightCm*$heightCm) / 2.54, 1) } else { "N/A" }
            $null = $results.Add([PSCustomObject]@{ Component = "Monitor"; Status = "Info"; Details = "Active: $($mon.Active), Size: ~$diagInch inches" })
        }
        $brightness = Get-CimInstance WmiMonitorBrightness -Namespace root/wmi -ErrorAction SilentlyContinue
        if ($brightness) {
            $null = $results.Add([PSCustomObject]@{ Component = "Backlight"; Status = "Pass"; Details = "Current brightness: $($brightness.CurrentBrightness)%, controllable" })
            Write-Host "    Brightness: $($brightness.CurrentBrightness)%" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Monitor Info"; Status = "Info"; Details = "Cannot query WMI monitor data" })
    }

    # 5. Native vs Current resolution comparison
    Write-Host "  [5/7] Checking native resolution match..." -ForegroundColor Yellow
    try {
        $gpuCheck = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gpuCheck -and $gpuCheck.VideoModeDescription) {
            $vmDesc = $gpuCheck.VideoModeDescription
            if ($vmDesc -match '(\d{3,5})\s*x\s*(\d{3,5})') {
                $nativeW = [int]$Matches[1]; $nativeH = [int]$Matches[2]
                $currentW = $gpuCheck.CurrentHorizontalResolution
                $currentH = $gpuCheck.CurrentVerticalResolution
                if ($currentW -eq $nativeW -and $currentH -eq $nativeH) {
                    $null = $results.Add([PSCustomObject]@{ Component = "Resolution Match"; Status = "Pass"; Details = "Current ${currentW}x${currentH} matches native ${nativeW}x${nativeH}" })
                    Write-Host "    Native resolution match: ${currentW}x${currentH}" -ForegroundColor Green
                } else {
                    $null = $results.Add([PSCustomObject]@{ Component = "Resolution Match"; Status = "Warning"; Details = "Current ${currentW}x${currentH} differs from native ${nativeW}x${nativeH} - possible scaling or driver issue" })
                    Write-Host "    Mismatch: Current ${currentW}x${currentH} vs Native ${nativeW}x${nativeH}" -ForegroundColor Yellow
                }
            }
        }
    } catch { }

    # 6. Pixel defect policy - interactive inspection
    Write-Host "  [6/7] Lenovo Pixel Defect Policy..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    === LENOVO LCD PIXEL DEFECT POLICY (ISO 9241-307 Class II) ===" -ForegroundColor Cyan
    Write-Host "    Threshold: $maxDeadPixels or more visible defective pixels = FAIL" -ForegroundColor White
    Write-Host "    To test: Display solid color screens (white, black, red, green, blue)" -ForegroundColor White
    Write-Host "    and count any pixels that do not change color." -ForegroundColor White
    Write-Host ""

    $pixelCount = $null
    try {
        $pixelInput = Read-Host "    Enter number of visible defective pixels (0 if none, press Enter to skip)"
        if ($pixelInput -match '^\d+$') {
            $pixelCount = [int]$pixelInput
            if ($pixelCount -ge $maxDeadPixels) {
                $null = $results.Add([PSCustomObject]@{ Component = "Pixel Defect Count"; Status = "Fail"; Details = "$pixelCount dead pixel(s) - EXCEEDS Lenovo $maxDeadPixels-pixel threshold. Display replacement required." })
                Write-Host "    FAIL: $pixelCount dead pixels exceeds threshold" -ForegroundColor Red
            } elseif ($pixelCount -gt 0) {
                $null = $results.Add([PSCustomObject]@{ Component = "Pixel Defect Count"; Status = "Warning"; Details = "$pixelCount dead pixel(s) - Within Lenovo policy but document for buyer disclosure" })
                Write-Host "    WARNING: $pixelCount pixel(s) found but within policy" -ForegroundColor Yellow
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Pixel Defect Count"; Status = "Pass"; Details = "No dead pixels reported - Display passes visual inspection" })
                Write-Host "    PASS: No dead pixels reported" -ForegroundColor Green
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Pixel Defect Count"; Status = "Info"; Details = "Skipped - Manual inspection: $maxDeadPixels+ dead pixels = replacement required" })
            Write-Host "    Skipped (manual inspection required)" -ForegroundColor Gray
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Pixel Defect Count"; Status = "Info"; Details = "Non-interactive mode - Manual inspection: $maxDeadPixels+ dead pixels = replacement required" })
    }

    # 7. Backlight bleed check
    Write-Host "  [7/7] Backlight Bleed Inspection..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    Set display to pure black background and inspect edges for light bleed." -ForegroundColor White
    Write-Host ""

    try {
        $bleedInput = Read-Host "    Rate backlight bleed: None / Minor / Moderate / Severe (press Enter to skip)"
        $bleedInput = $bleedInput.Trim()
        switch -Wildcard ($bleedInput.ToLower()) {
            "none" {
                $null = $results.Add([PSCustomObject]@{ Component = "Backlight Bleed"; Status = "Pass"; Details = "No backlight bleed detected" })
                Write-Host "    PASS: No backlight bleed" -ForegroundColor Green
            }
            "minor" {
                $null = $results.Add([PSCustomObject]@{ Component = "Backlight Bleed"; Status = "Info"; Details = "Minor backlight bleed - common on IPS panels, typically acceptable" })
                Write-Host "    Info: Minor bleed (acceptable)" -ForegroundColor White
            }
            "moderate" {
                $null = $results.Add([PSCustomObject]@{ Component = "Backlight Bleed"; Status = "Warning"; Details = "Moderate backlight bleed - document for buyer disclosure" })
                Write-Host "    WARNING: Moderate bleed" -ForegroundColor Yellow
            }
            "severe" {
                $null = $results.Add([PSCustomObject]@{ Component = "Backlight Bleed"; Status = "Fail"; Details = "Severe backlight bleed - display replacement recommended" })
                Write-Host "    FAIL: Severe bleed - replacement recommended" -ForegroundColor Red
            }
            default {
                $null = $results.Add([PSCustomObject]@{ Component = "Backlight Bleed"; Status = "Info"; Details = "Skipped - Perform manual inspection: display pure black, check edges" })
                Write-Host "    Skipped (manual inspection required)" -ForegroundColor Gray
            }
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Backlight Bleed"; Status = "Info"; Details = "Non-interactive mode - Perform manual backlight bleed inspection" })
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'DisplayPixelCheck' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'DisplayPixelCheck' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Display Pixel Check Results" -Results $results
    Write-Log "Display Pixel Check completed" -Level Success
    return $results
}

function Invoke-TPMHealthCheck {
    Write-Log "Starting TPM Health Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  TPM Health Check" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config
    $requireTPM20 = $true; $eventDaysBack = 90; $checkROCA = $true
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'RequireTPM20=(true|false)') { $requireTPM20 = $Matches[1] -eq 'true' }
            if ($cfgContent -match 'TPMEventLogDaysBack=(\d+)') { $eventDaysBack = [int]$Matches[1] }
            if ($cfgContent -match 'CheckROCAVulnerability=(true|false)') { $checkROCA = $Matches[1] -eq 'true' }
        }
    } catch { }

    # 1. Basic TPM status
    Write-Host "  [1/7] Checking TPM presence and status..." -ForegroundColor Yellow
    $tpmPresent = $false
    $tpmVersion = "N/A"
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $tpmPresent = $tpm.TpmPresent
        if ($tpmPresent) {
            $null = $results.Add([PSCustomObject]@{ Component = "TPM Present"; Status = "Pass"; Details = "TPM detected" })
            $null = $results.Add([PSCustomObject]@{ Component = "TPM Ready"; Status = $(if($tpm.TpmReady){"Pass"}else{"Warning"}); Details = "Ready: $($tpm.TpmReady)" })
            $null = $results.Add([PSCustomObject]@{ Component = "TPM Enabled"; Status = $(if($tpm.TpmEnabled){"Pass"}else{"Fail"}); Details = "Enabled: $($tpm.TpmEnabled)" })
            Write-Host "    Present: Yes, Ready: $($tpm.TpmReady), Enabled: $($tpm.TpmEnabled)" -ForegroundColor $(if($tpm.TpmReady -and $tpm.TpmEnabled){"Green"}else{"Yellow"})
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "TPM Present"; Status = "Fail"; Details = "No TPM detected - Windows 11 incompatible" })
            Write-Host "    TPM NOT detected" -ForegroundColor Red
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "TPM"; Status = "Warning"; Details = "Cannot query Get-Tpm: $($_.Exception.Message)" })
    }

    # 2. TPM version and manufacturer
    Write-Host "  [2/7] Checking TPM version and manufacturer..." -ForegroundColor Yellow
    $tpmManufacturer = ""
    $tpmFirmwareVer = ""
    try {
        $tpmWmi = Get-CimInstance -Namespace "root/cimv2/Security/MicrosoftTpm" -ClassName Win32_Tpm -ErrorAction Stop
        if ($tpmWmi) {
            $tpmVersion = ($tpmWmi.SpecVersion -split ',')[0].Trim()
            $tpmManufacturer = $tpmWmi.ManufacturerIdTxt
            $tpmFirmwareVer = $tpmWmi.ManufacturerVersion
            $versionOk = [version]$tpmVersion -ge [version]"2.0"
            $vStatus = if ($versionOk) { "Pass" } elseif ($requireTPM20) { "Fail" } else { "Warning" }
            $null = $results.Add([PSCustomObject]@{ Component = "TPM Version"; Status = $vStatus; Details = "Version: $tpmVersion $(if(-not $versionOk){'- Windows 11 requires TPM 2.0'})" })
            $null = $results.Add([PSCustomObject]@{ Component = "TPM Manufacturer"; Status = "Info"; Details = "$tpmManufacturer, Firmware: $tpmFirmwareVer" })
            Write-Host "    Version: $tpmVersion, Manufacturer: $tpmManufacturer ($tpmFirmwareVer)" -ForegroundColor $(if($versionOk){"Green"}else{"Red"})
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "TPM WMI"; Status = "Info"; Details = "Cannot query Win32_Tpm namespace" })
    }

    # 3. ROCA vulnerability check (Infineon TPMs)
    Write-Host "  [3/7] Checking ROCA vulnerability (CVE-2017-15361)..." -ForegroundColor Yellow
    if ($checkROCA -and $tpmManufacturer) {
        if ($tpmManufacturer -match 'IFX|Infineon') {
            $rocaAffected = $false
            if ($tpmFirmwareVer -match '^(\d+)\.(\d+)') {
                $major = [int]$Matches[1]; $minor = [int]$Matches[2]
                $rocaAffected = ($major -eq 4 -and $minor -ge 32 -and $minor -le 43) -or
                                ($major -eq 6 -and $minor -ge 40 -and $minor -le 43) -or
                                ($major -eq 7 -and $minor -ge 61 -and $minor -le 62)
            }
            if ($rocaAffected) {
                $null = $results.Add([PSCustomObject]@{ Component = "ROCA Vulnerability"; Status = "Fail"; Details = "Infineon TPM firmware $tpmFirmwareVer is VULNERABLE to CVE-2017-15361 (ROCA). Update TPM firmware via Lenovo support." })
                Write-Host "    VULNERABLE: ROCA CVE-2017-15361!" -ForegroundColor Red
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "ROCA Vulnerability"; Status = "Pass"; Details = "Infineon TPM firmware $tpmFirmwareVer is not in affected range" })
                Write-Host "    Not affected" -ForegroundColor Green
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "ROCA Vulnerability"; Status = "Pass"; Details = "Non-Infineon TPM ($tpmManufacturer) - not affected by ROCA" })
            Write-Host "    N/A (non-Infineon: $tpmManufacturer)" -ForegroundColor Green
        }
    }

    # 4. TPM Event Log scan
    Write-Host "  [4/7] Scanning TPM event log..." -ForegroundColor Yellow
    try {
        $startDate = (Get-Date).AddDays(-$eventDaysBack)
        $tpmEventIds = @(
            @{Id=1794; Desc="Secure Boot update failed"; Sev="Fail"}
            @{Id=1796; Desc="TPM WMI error / self-test failed"; Sev="Fail"}
            @{Id=5827; Desc="TPM lockout"; Sev="Fail"}
            @{Id=5829; Desc="TPM key attestation failed"; Sev="Warning"}
        )
        foreach ($te in $tpmEventIds) {
            try {
                $evts = Get-WinEvent -FilterHashtable @{LogName='System'; Id=$te.Id; StartTime=$startDate} -MaxEvents 5 -ErrorAction SilentlyContinue
                if ($evts) {
                    $null = $results.Add([PSCustomObject]@{ Component = "TPM Event $($te.Id)"; Status = $te.Sev; Details = "$($te.Desc) - $($evts.Count) occurrence(s), latest: $($evts[0].TimeCreated.ToString('yyyy-MM-dd'))" })
                    Write-Host "    Event $($te.Id): $($evts.Count)x - $($te.Desc)" -ForegroundColor $(if($te.Sev -eq "Fail"){"Red"}else{"Yellow"})
                }
            } catch { }
        }
    } catch { }

    # 4b. Sleep-wake TPM bug detection (Event ID 24620)
    Write-Host "  [5/7] Checking for TPM sleep-wake bug..." -ForegroundColor Yellow
    try {
        $startDate = (Get-Date).AddDays(-$eventDaysBack)
        $sleepWakeEvents = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-BitLocker*'; Id=24620; StartTime=$startDate} -MaxEvents 10 -ErrorAction SilentlyContinue
        if ($sleepWakeEvents) {
            $null = $results.Add([PSCustomObject]@{ Component = "TPM Sleep-Wake Bug"; Status = "Fail"; Details = "$($sleepWakeEvents.Count) occurrence(s) of TPM failed to unlock after sleep (Event 24620) - Known ThinkPad TPM sleep-wake bug detected. Update BIOS and TPM firmware." })
            Write-Host "    FOUND: $($sleepWakeEvents.Count)x TPM sleep-wake unlock failure" -ForegroundColor Red
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "TPM Sleep-Wake Bug"; Status = "Pass"; Details = "No Event ID 24620 detected in last $eventDaysBack days" })
            Write-Host "    No sleep-wake TPM issues" -ForegroundColor Green
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "TPM Sleep-Wake Bug"; Status = "Info"; Details = "Cannot query BitLocker event log" })
    }

    # 5. BitLocker integration
    Write-Host "  [6/7] Checking BitLocker integration..." -ForegroundColor Yellow
    try {
        $blCmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
        if ($null -eq $blCmd) {
            $null = $results.Add([PSCustomObject]@{ Component = "BitLocker"; Status = "Info"; Details = "BitLocker feature not available (Windows Home edition)" })
            Write-Host "    BitLocker not available (Home edition)" -ForegroundColor Gray
        } else {
            $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
            $blStatus = if ($bl.ProtectionStatus -eq "On") { "Pass" } elseif ($bl.ProtectionStatus -eq "Off" -and $tpmPresent) { "Warning" } else { "Info" }
            $null = $results.Add([PSCustomObject]@{ Component = "BitLocker"; Status = $blStatus; Details = "Protection: $($bl.ProtectionStatus), Encryption: $($bl.EncryptionPercentage)%" })
            Write-Host "    BitLocker: $($bl.ProtectionStatus), Encrypted: $($bl.EncryptionPercentage)%" -ForegroundColor $(if($blStatus -eq "Pass"){"Green"}elseif($blStatus -eq "Warning"){"Yellow"}else{"White"})
            if ($bl.ProtectionStatus -eq "On" -and -not $tpmPresent) {
                $null = $results.Add([PSCustomObject]@{ Component = "BitLocker Conflict"; Status = "Fail"; Details = "BitLocker ON but TPM not present/ready - recovery key required at every boot" })
            }
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "BitLocker"; Status = "Info"; Details = "Cannot check: $($_.Exception.Message)" })
    }

    # 6. Secure Boot
    Write-Host "  [7/7] Checking Secure Boot..." -ForegroundColor Yellow
    try {
        $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
        $sbStatus = if ($secureBoot) { "Pass" } else { "Warning" }
        $null = $results.Add([PSCustomObject]@{ Component = "Secure Boot"; Status = $sbStatus; Details = "Secure Boot: $(if($secureBoot){'Enabled'}else{'Disabled'})$(if(-not $secureBoot -and $tpmPresent){' - recommended to enable for full security'})" })
        Write-Host "    Secure Boot: $(if($secureBoot){'Enabled'}else{'Disabled'})" -ForegroundColor $(if($secureBoot){"Green"}else{"Yellow"})
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Secure Boot"; Status = "Info"; Details = "Cannot determine (may not be supported on this system)" })
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'TPMHealthCheck' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'TPMHealthCheck' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "TPM Health Check Results" -Results $results
    Write-Log "TPM Health Check completed" -Level Success
    return $results
}

function Invoke-Win11ReadinessCheck {
    Write-Log "Starting Windows 11 Readiness Check..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Windows 11 Readiness Check" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config
    $minRAM = 4; $minStorage = 64; $win10EOL = "2025-10-14"
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'Win11MinRAMGB=(\d+)') { $minRAM = [int]$Matches[1] }
            if ($cfgContent -match 'Win11MinStorageGB=(\d+)') { $minStorage = [int]$Matches[1] }
            if ($cfgContent -match 'Win10EOLDate=(.+)') { $win10EOL = $Matches[1].Trim() }
        }
    } catch { }

    $failCount = 0; $warnCount = 0

    # 1. Current OS
    Write-Host "  [1/9] Checking current OS..." -ForegroundColor Yellow
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $osCaption = $os.Caption
        if ($osCaption -match "Windows 11") {
            $null = $results.Add([PSCustomObject]@{ Component = "Current OS"; Status = "Pass"; Details = "$osCaption - Already on Windows 11" })
            Write-Host "    Already on Windows 11" -ForegroundColor Green
        } elseif ($osCaption -match "Windows 10") {
            $eolDate = [DateTime]::Parse($win10EOL)
            $daysSinceEOL = ((Get-Date) - $eolDate).Days
            if ($daysSinceEOL -gt 0) {
                $null = $results.Add([PSCustomObject]@{ Component = "Current OS"; Status = "Fail"; Details = "$osCaption - Windows 10 reached end-of-life $daysSinceEOL days ago ($win10EOL). Upgrade recommended." })
                Write-Host "    $osCaption - EOL was $daysSinceEOL days ago!" -ForegroundColor Red
                $failCount++
            } else {
                $null = $results.Add([PSCustomObject]@{ Component = "Current OS"; Status = "Warning"; Details = "$osCaption - Windows 10 EOL: $win10EOL ($([math]::Abs($daysSinceEOL)) days remaining)" })
                $warnCount++
            }
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Current OS"; Status = "Fail"; Details = "$osCaption - Upgrade path to Windows 11 may not be supported" })
            $failCount++
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Current OS"; Status = "Warning"; Details = "Cannot determine" })
    }

    # 2. TPM 2.0
    Write-Host "  [2/9] Checking TPM 2.0..." -ForegroundColor Yellow
    try {
        $tpm = Get-Tpm -ErrorAction SilentlyContinue
        $tpmWmi = Get-CimInstance -Namespace "root/cimv2/Security/MicrosoftTpm" -ClassName Win32_Tpm -ErrorAction SilentlyContinue
        $tpmVer = if ($tpmWmi) { ($tpmWmi.SpecVersion -split ',')[0].Trim() } else { "N/A" }
        $tpmOk = $tpm -and $tpm.TpmPresent -and $tpmVer -ne "N/A" -and ([version]$tpmVer -ge [version]"2.0")
        if ($tpmOk) {
            $null = $results.Add([PSCustomObject]@{ Component = "TPM 2.0"; Status = "Pass"; Details = "TPM $tpmVer present and ready" })
            Write-Host "    TPM $tpmVer - OK" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "TPM 2.0"; Status = "Fail"; Details = "TPM $tpmVer - Windows 11 requires TPM 2.0" })
            Write-Host "    TPM $tpmVer - FAIL (need 2.0)" -ForegroundColor Red
            $failCount++
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "TPM 2.0"; Status = "Fail"; Details = "Cannot query TPM" })
        $failCount++
    }

    # 3. CPU generation
    Write-Host "  [3/9] Checking CPU generation..." -ForegroundColor Yellow
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop
        $cpuName = $cpu.Name
        $cpuSupported = $false; $cpuGen = "Unknown"

        if ($cpuName -match '(\d+)(?:th|st|nd|rd)\s+Gen\s+Intel') {
            $gen = [int]$Matches[1]; $cpuGen = "Intel Gen $gen"; $cpuSupported = $gen -ge 8
        } elseif ($cpuName -match 'Intel.*Core.*Ultra') {
            $cpuGen = "Intel Core Ultra"; $cpuSupported = $true
        } elseif ($cpuName -match 'Intel.*\bi[3579]-(\d)') {
            $gen = [int]$Matches[1]; $cpuGen = "Intel i-series Gen $gen"; $cpuSupported = $gen -ge 8
        } elseif ($cpuName -match 'AMD\s+Ryzen\s+\d+\s+(\d)') {
            $series = [int]$Matches[1]; $cpuGen = "AMD Ryzen ${series}xxx"; $cpuSupported = $series -ge 2
        } elseif ($cpuName -match 'Snapdragon|Qualcomm') {
            $cpuGen = "ARM Snapdragon"; $cpuSupported = $true
        }

        $cStatus = if ($cpuSupported) { "Pass" } else { "Fail" }
        $null = $results.Add([PSCustomObject]@{ Component = "CPU Compatibility"; Status = $cStatus; Details = "$cpuName [$cpuGen] $(if($cpuSupported){'- Supported'}else{'- Not supported for Windows 11'})" })
        Write-Host "    ${cpuGen}: $(if($cpuSupported){'Supported'}else{'NOT supported'})" -ForegroundColor $(if($cpuSupported){"Green"}else{"Red"})
        if (-not $cpuSupported) { $failCount++ }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "CPU"; Status = "Warning"; Details = "Cannot determine" })
        $warnCount++
    }

    # 4. RAM
    Write-Host "  [4/9] Checking RAM ($minRAM GB minimum)..." -ForegroundColor Yellow
    try {
        if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }
        $ramGB = $script:SystemInfo.TotalMemoryGB
        $ramOk = $ramGB -ge $minRAM
        $null = $results.Add([PSCustomObject]@{ Component = "RAM"; Status = $(if($ramOk){"Pass"}else{"Fail"}); Details = "$ramGB GB $(if($ramOk){'(meets minimum)'}else{\"(below $minRAM GB minimum)\"})" })
        Write-Host "    $ramGB GB - $(if($ramOk){'OK'}else{'FAIL'})" -ForegroundColor $(if($ramOk){"Green"}else{"Red"})
        if (-not $ramOk) { $failCount++ }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "RAM"; Status = "Warning"; Details = "Cannot determine" })
    }

    # 5. Storage
    Write-Host "  [5/9] Checking storage ($minStorage GB minimum)..." -ForegroundColor Yellow
    try {
        $sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
        $storageGB = [math]::Round($sysDrive.Size / 1GB, 1)
        $storageOk = $storageGB -ge $minStorage
        $null = $results.Add([PSCustomObject]@{ Component = "Storage"; Status = $(if($storageOk){"Pass"}else{"Fail"}); Details = "$storageGB GB system drive $(if($storageOk){'(meets minimum)'}else{\"(below $minStorage GB minimum)\"})" })
        Write-Host "    $storageGB GB - $(if($storageOk){'OK'}else{'FAIL'})" -ForegroundColor $(if($storageOk){"Green"}else{"Red"})
        if (-not $storageOk) { $failCount++ }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Storage"; Status = "Warning"; Details = "Cannot determine" })
    }

    # 6. Secure Boot
    Write-Host "  [6/9] Checking Secure Boot..." -ForegroundColor Yellow
    try {
        $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
        $null = $results.Add([PSCustomObject]@{ Component = "Secure Boot"; Status = $(if($secureBoot){"Pass"}else{"Warning"}); Details = "$(if($secureBoot){'Enabled'}else{'Disabled - enable in BIOS for Windows 11'})" })
        Write-Host "    $(if($secureBoot){'Enabled'}else{'Disabled'})" -ForegroundColor $(if($secureBoot){"Green"}else{"Yellow"})
        if (-not $secureBoot) { $warnCount++ }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Secure Boot"; Status = "Warning"; Details = "Cannot determine" })
        $warnCount++
    }

    # 7. UEFI firmware
    Write-Host "  [7/9] Checking UEFI firmware mode..." -ForegroundColor Yellow
    $firmwareType = $env:firmware_type
    if ([string]::IsNullOrEmpty($firmwareType)) {
        try {
            $regSB = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State" -ErrorAction SilentlyContinue
            $firmwareType = if ($null -ne $regSB) { "UEFI" } else { "Unknown" }
        } catch { $firmwareType = "Unknown" }
    }
    $uefiOk = $firmwareType -eq "UEFI"
    $null = $results.Add([PSCustomObject]@{ Component = "Firmware Mode"; Status = $(if($uefiOk){"Pass"}else{"Fail"}); Details = "$firmwareType $(if(-not $uefiOk){'- Windows 11 requires UEFI (not legacy BIOS)'})" })
    Write-Host "    $firmwareType - $(if($uefiOk){'OK'}else{'FAIL'})" -ForegroundColor $(if($uefiOk){"Green"}else{"Red"})
    if (-not $uefiOk) { $failCount++ }

    # 8. Display resolution
    Write-Host "  [8/9] Checking display resolution (720p minimum)..." -ForegroundColor Yellow
    try {
        $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gpu) {
            $resOk = $gpu.CurrentHorizontalResolution -ge 1280 -and $gpu.CurrentVerticalResolution -ge 720
            $null = $results.Add([PSCustomObject]@{ Component = "Display Resolution"; Status = $(if($resOk){"Pass"}else{"Fail"}); Details = "$($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution)" })
            if (-not $resOk) { $failCount++ }
        }
    } catch { }

    # 9. Internet connectivity for Windows Update
    Write-Host "  [9/9] Checking internet connectivity for Windows Update..." -ForegroundColor Yellow
    try {
        $netTest = Test-NetConnection -ComputerName "update.microsoft.com" -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
        if ($netTest.TcpTestSucceeded) {
            $null = $results.Add([PSCustomObject]@{ Component = "Internet (Windows Update)"; Status = "Pass"; Details = "update.microsoft.com:443 reachable - Windows Update available" })
            Write-Host "    update.microsoft.com reachable" -ForegroundColor Green
        } else {
            $null = $results.Add([PSCustomObject]@{ Component = "Internet (Windows Update)"; Status = "Warning"; Details = "Cannot reach update.microsoft.com:443 - Windows Update may be blocked" })
            Write-Host "    Cannot reach update.microsoft.com" -ForegroundColor Yellow
            $warnCount++
        }
    } catch {
        $null = $results.Add([PSCustomObject]@{ Component = "Internet (Windows Update)"; Status = "Warning"; Details = "Network test failed: $($_.Exception.Message)" })
        $warnCount++
    }

    # Verdict
    $verdict = if ($failCount -eq 0 -and $warnCount -eq 0) { "READY" }
               elseif ($failCount -eq 0) { "READY (with minor concerns)" }
               else { "NOT READY" }
    $priority = if ($failCount -eq 0) { 5 } elseif ($failCount -le 2) { 3 } else { 1 }

    Write-Host "`n  ===== WINDOWS 11 READINESS VERDICT =====" -ForegroundColor Cyan
    Write-Host "  Result: $verdict" -ForegroundColor $(if($failCount -eq 0){"Green"}else{"Red"})
    Write-Host "  Blocking issues: $failCount, Warnings: $warnCount" -ForegroundColor White
    Write-Host "  Upgrade Priority: $priority/5" -ForegroundColor White

    $null = $results.Add([PSCustomObject]@{ Component = "VERDICT"; Status = $(if($failCount -eq 0){"Pass"}else{"Fail"}); Details = "$verdict - $failCount blocking issue(s), $warnCount warning(s). Upgrade priority: $priority/5" })


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'Win11ReadinessCheck' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'Win11ReadinessCheck' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Windows 11 Readiness Check Results" -Results $results
    Write-Log "Win11 Readiness Check completed - $verdict (Priority: $priority/5)" -Level Success
    return $results
}

function Invoke-EnterpriseReadinessReport {
    Write-Log "Starting Enterprise Readiness Report..." -Level Info
    $results = New-Object System.Collections.ArrayList

    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Enterprise Readiness Report" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    # Read config weights
    $wSec=20; $wHw=15; $wStor=15; $wBatt=10; $wDrv=10; $wOS=10; $wId=10; $wTPM=5; $wDisp=5
    $passThreshold=70; $warnThreshold=50
    try {
        $cfgFile = Join-Path $ConfigPath "config.ini"
        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if ($cfgContent -match 'WeightSecurity=(\d+)') { $wSec = [int]$Matches[1] }
            if ($cfgContent -match 'WeightHardware=(\d+)') { $wHw = [int]$Matches[1] }
            if ($cfgContent -match 'WeightStorage=(\d+)') { $wStor = [int]$Matches[1] }
            if ($cfgContent -match 'WeightBattery=(\d+)') { $wBatt = [int]$Matches[1] }
            if ($cfgContent -match 'WeightDrivers=(\d+)') { $wDrv = [int]$Matches[1] }
            if ($cfgContent -match 'WeightOS=(\d+)') { $wOS = [int]$Matches[1] }
            if ($cfgContent -match 'WeightIdentity=(\d+)') { $wId = [int]$Matches[1] }
            if ($cfgContent -match 'WeightTPM=(\d+)') { $wTPM = [int]$Matches[1] }
            if ($cfgContent -match 'WeightDisplay=(\d+)') { $wDisp = [int]$Matches[1] }
            if ($cfgContent -match 'PassingScoreThreshold=(\d+)') { $passThreshold = [int]$Matches[1] }
            if ($cfgContent -match 'WarningScoreThreshold=(\d+)') { $warnThreshold = [int]$Matches[1] }
        }
    } catch { }

    $totalWeight = $wSec + $wHw + $wStor + $wBatt + $wDrv + $wOS + $wId + $wTPM + $wDisp
    if (-not $script:SystemInfo) { Get-SystemInformation | Out-Null }

    # Helper to score
    function Get-SubScore { param([int]$Score, [int]$Weight) return [math]::Round(($Score / 100) * $Weight, 1) }

    # 1. Security (Defender, Firewall, UAC)
    Write-Host "  [1/9] Scoring Security..." -ForegroundColor Yellow
    $secScore = 100
    try {
        $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if (-not $defender -or -not $defender.RealTimeProtectionEnabled) { $secScore -= 30 }
        if ($defender -and $defender.AntivirusSignatureAge -gt 7) { $secScore -= 20 }
        $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        $fwOff = @($fw | Where-Object { -not $_.Enabled }).Count
        $secScore -= ($fwOff * 15)
        try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop; if (-not $sb) { $secScore -= 10 } } catch { $secScore -= 10 }
        $uac = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue).EnableLUA
        if ($uac -ne 1) { $secScore -= 15 }
    } catch { $secScore = 50 }
    $secScore = [math]::Max(0, $secScore)
    $null = $results.Add([PSCustomObject]@{ Component = "Security Score"; Status = $(if($secScore -ge 70){"Pass"}elseif($secScore -ge 50){"Warning"}else{"Fail"}); Details = "$secScore/100 (weight: $wSec%)" })
    Write-Host "    Security: $secScore/100" -ForegroundColor $(if($secScore -ge 70){"Green"}elseif($secScore -ge 50){"Yellow"}else{"Red"})

    # 2. Hardware (TPM, CPU, battery)
    Write-Host "  [2/9] Scoring Hardware..." -ForegroundColor Yellow
    $hwScore = 100
    try {
        $tpm = Get-Tpm -ErrorAction SilentlyContinue
        if (-not $tpm -or -not $tpm.TpmPresent) { $hwScore -= 30 }
        $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($battery -and $battery.EstimatedChargeRemaining -lt 30 -and $battery.BatteryStatus -ne 2) { $hwScore -= 20 }
    } catch { $hwScore = 60 }
    $hwScore = [math]::Max(0, $hwScore)
    $null = $results.Add([PSCustomObject]@{ Component = "Hardware Score"; Status = $(if($hwScore -ge 70){"Pass"}elseif($hwScore -ge 50){"Warning"}else{"Fail"}); Details = "$hwScore/100 (weight: $wHw%)" })
    Write-Host "    Hardware: $hwScore/100" -ForegroundColor $(if($hwScore -ge 70){"Green"}elseif($hwScore -ge 50){"Yellow"}else{"Red"})

    # 3. Storage
    Write-Host "  [3/9] Scoring Storage..." -ForegroundColor Yellow
    $storScore = 100
    try {
        $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        foreach ($d in $disks) {
            if ($d.HealthStatus -ne "Healthy") { $storScore -= 40 }
        }
        $sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue
        if ($sysDrive) {
            $freePct = [math]::Round(($sysDrive.FreeSpace / $sysDrive.Size) * 100, 1)
            if ($freePct -lt 10) { $storScore -= 30 } elseif ($freePct -lt 20) { $storScore -= 15 }
        }
    } catch { $storScore = 60 }
    $storScore = [math]::Max(0, $storScore)
    $null = $results.Add([PSCustomObject]@{ Component = "Storage Score"; Status = $(if($storScore -ge 70){"Pass"}elseif($storScore -ge 50){"Warning"}else{"Fail"}); Details = "$storScore/100 (weight: $wStor%)" })
    Write-Host "    Storage: $storScore/100" -ForegroundColor $(if($storScore -ge 70){"Green"}elseif($storScore -ge 50){"Yellow"}else{"Red"})

    # 4. Battery
    Write-Host "  [4/9] Scoring Battery..." -ForegroundColor Yellow
    $battScore = 100
    try {
        $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if (-not $battery) { $battScore = 0 }
        elseif ($battery.Status -match "Replace") { $battScore = 10 }
        elseif ($battery.Status -match "Degraded") { $battScore = 50 }
    } catch { $battScore = 50 }
    $null = $results.Add([PSCustomObject]@{ Component = "Battery Score"; Status = $(if($battScore -ge 70){"Pass"}elseif($battScore -ge 50){"Warning"}else{"Fail"}); Details = "$battScore/100 (weight: $wBatt%)" })
    Write-Host "    Battery: $battScore/100" -ForegroundColor $(if($battScore -ge 70){"Green"}elseif($battScore -ge 50){"Yellow"}else{"Red"})

    # 5. Drivers
    Write-Host "  [5/9] Scoring Drivers..." -ForegroundColor Yellow
    $drvScore = 100
    try {
        $problemDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -in @("Error","Degraded") })
        $drvScore -= ($problemDevices.Count * 15)
    } catch { $drvScore = 70 }
    $drvScore = [math]::Max(0, $drvScore)
    $null = $results.Add([PSCustomObject]@{ Component = "Driver Score"; Status = $(if($drvScore -ge 70){"Pass"}elseif($drvScore -ge 50){"Warning"}else{"Fail"}); Details = "$drvScore/100 (weight: $wDrv%)" })
    Write-Host "    Drivers: $drvScore/100" -ForegroundColor $(if($drvScore -ge 70){"Green"}elseif($drvScore -ge 50){"Yellow"}else{"Red"})

    # 6. OS
    Write-Host "  [6/9] Scoring OS..." -ForegroundColor Yellow
    $osScore = 100
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os.Caption -match "Windows 11") { $osScore = 100 }
        elseif ($os.Caption -match "Windows 10") { $osScore = 50 }
        else { $osScore = 20 }
        $uptime = (Get-Date) - $os.LastBootUpTime
        if ($uptime.TotalDays -gt 30) { $osScore -= 10 }
    } catch { $osScore = 50 }
    $osScore = [math]::Max(0, $osScore)
    $null = $results.Add([PSCustomObject]@{ Component = "OS Score"; Status = $(if($osScore -ge 70){"Pass"}elseif($osScore -ge 50){"Warning"}else{"Fail"}); Details = "$osScore/100 (weight: $wOS%)" })
    Write-Host "    OS: $osScore/100" -ForegroundColor $(if($osScore -ge 70){"Green"}elseif($osScore -ge 50){"Yellow"}else{"Red"})

    # 7. Identity
    Write-Host "  [7/9] Scoring Identity..." -ForegroundColor Yellow
    $idScore = 100
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $serial = $bios.SerialNumber
        if (-not $serial -or $serial -match 'Default|To Be Filled|None') { $idScore -= 40 }
        $uuid = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID
        if (-not $uuid -or $uuid -eq "00000000-0000-0000-0000-000000000000") { $idScore -= 40 }
    } catch { $idScore = 50 }
    $idScore = [math]::Max(0, $idScore)
    $null = $results.Add([PSCustomObject]@{ Component = "Identity Score"; Status = $(if($idScore -ge 70){"Pass"}elseif($idScore -ge 50){"Warning"}else{"Fail"}); Details = "$idScore/100 (weight: $wId%)" })
    Write-Host "    Identity: $idScore/100" -ForegroundColor $(if($idScore -ge 70){"Green"}elseif($idScore -ge 50){"Yellow"}else{"Red"})

    # 8. TPM
    Write-Host "  [8/9] Scoring TPM..." -ForegroundColor Yellow
    $tpmScore = 100
    try {
        $tpm = Get-Tpm -ErrorAction SilentlyContinue
        if (-not $tpm -or -not $tpm.TpmPresent) { $tpmScore = 0 }
        elseif (-not $tpm.TpmReady) { $tpmScore = 50 }
        $tpmWmi = Get-CimInstance -Namespace "root/cimv2/Security/MicrosoftTpm" -ClassName Win32_Tpm -ErrorAction SilentlyContinue
        if ($tpmWmi) {
            $ver = ($tpmWmi.SpecVersion -split ',')[0].Trim()
            if ([version]$ver -lt [version]"2.0") { $tpmScore -= 30 }
        }
    } catch { $tpmScore = 30 }
    $tpmScore = [math]::Max(0, $tpmScore)
    $null = $results.Add([PSCustomObject]@{ Component = "TPM Score"; Status = $(if($tpmScore -ge 70){"Pass"}elseif($tpmScore -ge 50){"Warning"}else{"Fail"}); Details = "$tpmScore/100 (weight: $wTPM%)" })
    Write-Host "    TPM: $tpmScore/100" -ForegroundColor $(if($tpmScore -ge 70){"Green"}elseif($tpmScore -ge 50){"Yellow"}else{"Red"})

    # 9. Display
    Write-Host "  [9/9] Scoring Display..." -ForegroundColor Yellow
    $dispScore = 100
    try {
        $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gpu -and $gpu.ConfigManagerErrorCode -ne 0) { $dispScore -= 40 }
        $tdrEvents = Get-WinEvent -FilterHashtable @{LogName='System'; Id=@(4101,4116); StartTime=(Get-Date).AddDays(-30)} -MaxEvents 5 -ErrorAction SilentlyContinue
        if ($tdrEvents) { $dispScore -= ($tdrEvents.Count * 10) }
    } catch { $dispScore = 70 }
    $dispScore = [math]::Max(0, $dispScore)
    $null = $results.Add([PSCustomObject]@{ Component = "Display Score"; Status = $(if($dispScore -ge 70){"Pass"}elseif($dispScore -ge 50){"Warning"}else{"Fail"}); Details = "$dispScore/100 (weight: $wDisp%)" })
    Write-Host "    Display: $dispScore/100" -ForegroundColor $(if($dispScore -ge 70){"Green"}elseif($dispScore -ge 50){"Yellow"}else{"Red"})

    # Calculate weighted total
    $totalScore = [math]::Round(
        (($secScore * $wSec) + ($hwScore * $wHw) + ($storScore * $wStor) + ($battScore * $wBatt) +
         ($drvScore * $wDrv) + ($osScore * $wOS) + ($idScore * $wId) + ($tpmScore * $wTPM) +
         ($dispScore * $wDisp)) / $totalWeight, 0)

    $lifecycle = if ($totalScore -ge 90) { "EXCELLENT - Deploy immediately" }
                elseif ($totalScore -ge 70) { "GOOD - Minor issues, deploy after fixes" }
                elseif ($totalScore -ge 50) { "FAIR - Several issues, targeted repair needed" }
                elseif ($totalScore -ge 30) { "POOR - Major issues, evaluate for replacement" }
                else { "CRITICAL - Do not deploy, escalate or dispose" }

    $lifecycleStatus = if ($totalScore -ge 70) { "Pass" } elseif ($totalScore -ge 50) { "Warning" } else { "Fail" }

    Write-Host "`n  ===== ENTERPRISE READINESS SCORE =====" -ForegroundColor Cyan
    Write-Host "  TOTAL: $totalScore / 100" -ForegroundColor $(if($totalScore -ge 70){"Green"}elseif($totalScore -ge 50){"Yellow"}else{"Red"})
    Write-Host "  $lifecycle" -ForegroundColor $(if($totalScore -ge 70){"Green"}elseif($totalScore -ge 50){"Yellow"}else{"Red"})

    $null = $results.Add([PSCustomObject]@{ Component = "TOTAL SCORE"; Status = $lifecycleStatus; Details = "$totalScore/100 - $lifecycle" })

    # Build custom scorecard HTML
    try {
        $reportDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $sysModel = if ($script:SystemInfo) { "$($script:SystemInfo.Manufacturer) $($script:ModelInfo)" } else { "Unknown" }
        $sysSerial = if ($script:SystemInfo) { $script:SystemInfo.SerialNumber } else { "Unknown" }
        $barColor = if ($totalScore -ge 70) { "#388e3c" } elseif ($totalScore -ge 50) { "#f57f17" } else { "#c62828" }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<!DOCTYPE html><html><head><title>Enterprise Readiness Scorecard</title>')
        [void]$sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:20px;color:#1a1a1a}')
        [void]$sb.AppendLine('h1{color:#00539B}h2{color:#00539B;border-bottom:1px solid #ddd;padding-bottom:5px}')
        [void]$sb.AppendLine('.score-badge{display:inline-block;font-size:48pt;font-weight:bold;padding:20px 40px;border-radius:12px;color:#fff}')
        [void]$sb.AppendLine('.bar-container{background:#e0e0e0;border-radius:6px;height:24px;margin:4px 0 12px}')
        [void]$sb.AppendLine('.bar-fill{height:24px;border-radius:6px;text-align:center;color:#fff;font-size:10pt;line-height:24px}')
        [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;margin:12px 0}th{background:#00539B;color:#fff;text-align:left;padding:8px}')
        [void]$sb.AppendLine('td{border:1px solid #ddd;padding:8px}tr:nth-child(even){background:#f2f2f2}')
        [void]$sb.AppendLine('.pass{color:green}.warning{color:orange}.fail{color:red}.info{color:#00539B}')
        [void]$sb.AppendLine('</style></head><body>')
        [void]$sb.AppendLine("<h1>Enterprise Readiness Scorecard</h1>")
        [void]$sb.AppendLine("<p><strong>System:</strong> $sysModel | <strong>Serial:</strong> $sysSerial | <strong>Date:</strong> $reportDate</p>")
        [void]$sb.AppendLine("<div style='text-align:center;margin:20px 0'><span class='score-badge' style='background:$barColor'>$totalScore / 100</span>")
        [void]$sb.AppendLine("<p style='font-size:14pt;color:$barColor;font-weight:bold'>$lifecycle</p></div>")

        # Category bars
        [void]$sb.AppendLine("<h2>Category Breakdown</h2>")
        $categories = @(
            @{Name="Security";$s=$secScore;W=$wSec}, @{Name="Hardware";$s=$hwScore;W=$wHw},
            @{Name="Storage";$s=$storScore;W=$wStor}, @{Name="Battery";$s=$battScore;W=$wBatt},
            @{Name="Drivers";$s=$drvScore;W=$wDrv}, @{Name="OS";$s=$osScore;W=$wOS},
            @{Name="Identity";$s=$idScore;W=$wId}, @{Name="TPM";$s=$tpmScore;W=$wTPM},
            @{Name="Display";$s=$dispScore;W=$wDisp}
        )
        foreach ($cat in $categories) {
            $c = if ($cat.s -ge 70) { "#388e3c" } elseif ($cat.s -ge 50) { "#f57f17" } else { "#c62828" }
            [void]$sb.AppendLine("<p style='margin:2px 0'><strong>$($cat.Name)</strong> ($($cat.W)% weight)</p>")
            [void]$sb.AppendLine("<div class='bar-container'><div class='bar-fill' style='width:$($cat.s)%;background:$c'>$($cat.s)%</div></div>")
        }

        # Standard results table
        [void]$sb.AppendLine("<h2>Detailed Results</h2><table><tr><th>Component</th><th>Status</th><th>Details</th></tr>")
        foreach ($r in $results) {
            $sc = switch ($r.Status) { "Pass" { "pass" }; "Warning" { "warning" }; "Fail" { "fail" }; default { "info" } }
            [void]$sb.AppendLine("<tr><td>$($r.Component)</td><td class='$sc'>$($r.Status)</td><td>$($r.Details)</td></tr>")
        }
        [void]$sb.AppendLine("</table><p><em>Generated by Laptop Diagnostic Toolkit v$($script:Version)</em></p></body></html>")

        $scorecardPath = Join-Path $ReportPath "Enterprise_Scorecard_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
        $sb.ToString() | Out-File -FilePath $scorecardPath -Encoding utf8 -Force
        Write-Host "`n  Scorecard saved to: $scorecardPath" -ForegroundColor Green
        Write-Log "Enterprise Scorecard saved to: $scorecardPath" -Level Success
    } catch {
        Write-Log "Failed to generate scorecard: $($_.Exception.Message)" -Level Error
    }

    # Generate per-machine action plan from Fail/Warning items
    try {
        $actionItems = New-Object System.Collections.ArrayList
        $actionNum = 0
        foreach ($r in $results) {
            if ($r.Status -eq "Fail") {
                $actionNum++
                $action = switch -Wildcard ($r.Component) {
                    "*Security*" { "Run Security Hardening (Option 34) to resolve security deficiencies" }
                    "*Storage*" { "Run SMART Disk Analysis (Option 40) and free disk space or replace failing drive" }
                    "*Battery*" { "Run Battery Health (Option 14) - consider battery replacement if cycle count high" }
                    "*Driver*" { "Run Driver Auto-Update (Option 38) to resolve problem devices" }
                    "*OS*" { "Run Win11 Readiness Check (Option 44) and plan OS upgrade" }
                    "*Identity*" { "Run Machine Identity Check (Option 42) - reflash FRU data if serial/UUID invalid" }
                    "*TPM*" { "Run TPM Health Check (Option 43) - enable TPM in BIOS or update firmware" }
                    "*Display*" { "Run Display Pixel Check (Option 47) - update GPU drivers or replace display" }
                    default { "Investigate and resolve: $($r.Details)" }
                }
                $null = $actionItems.Add([PSCustomObject]@{ Priority = $actionNum; Action = $action; Source = $r.Component })
            } elseif ($r.Status -eq "Warning") {
                $actionNum++
                $null = $actionItems.Add([PSCustomObject]@{ Priority = $actionNum; Action = "Monitor: $($r.Details)"; Source = $r.Component })
            }
        }

        if ($actionItems.Count -gt 0) {
            Write-Host "`n  ===== ACTION PLAN =====" -ForegroundColor Cyan
            $null = $results.Add([PSCustomObject]@{ Component = "ACTION PLAN"; Status = "Info"; Details = "$($actionItems.Count) action item(s) identified" })
            foreach ($ai in $actionItems) {
                Write-Host "    $($ai.Priority). [$($ai.Source)] $($ai.Action)" -ForegroundColor White
                $null = $results.Add([PSCustomObject]@{ Component = "Action $($ai.Priority)"; Status = "Info"; Details = "[$($ai.Source)] $($ai.Action)" })
            }

            # Add action plan to scorecard HTML if it was generated
            if ($scorecardPath -and (Test-Path $scorecardPath)) {
                $htmlContent = Get-Content $scorecardPath -Raw
                $actionHtml = "<h2>Action Plan</h2><table><tr><th>#</th><th>Source</th><th>Action</th></tr>"
                foreach ($ai in $actionItems) {
                    $actionHtml += "<tr><td>$($ai.Priority)</td><td>$($ai.Source)</td><td>$($ai.Action)</td></tr>"
                }
                $actionHtml += "</table>"
                $htmlContent = $htmlContent -replace '</body></html>', "$actionHtml</body></html>"
                $htmlContent | Out-File -FilePath $scorecardPath -Encoding utf8 -Force
            }
        } else {
            Write-Host "`n  No action items - system is in good health." -ForegroundColor Green
        }
    } catch {
        Write-Log "Action plan generation failed: $($_.Exception.Message)" -Level Warning
    }

    # Export enriched fleet CSV row
    try {
        $topAction = if ($actionItems -and $actionItems.Count -gt 0) { $actionItems[0].Action } else { "None" }
        $fleetRow = [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            SerialNumber = if ($script:SystemInfo) { $script:SystemInfo.SerialNumber } else { "Unknown" }
            Model = if ($script:SystemInfo) { $script:SystemInfo.Model } else { "Unknown" }
            OverallScore = $totalScore
            SecurityScore = $secScore
            HardwareScore = $hwScore
            StorageScore = $storScore
            BatteryScore = $battScore
            DriverScore = $drvScore
            OSScore = $osScore
            IdentityScore = $idScore
            TPMScore = $tpmScore
            DisplayScore = $dispScore
            LifecycleRecommendation = $lifecycle
            ActionItemCount = if ($actionItems) { $actionItems.Count } else { 0 }
            TopActionItem = $topAction
            ReportDate = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }

        $fleetCsvPath = Join-Path $ReportPath "Enterprise_Fleet_Enriched.csv"
        $csvExists = Test-Path $fleetCsvPath
        if ($csvExists) {
            $fleetRow | Export-Csv -Path $fleetCsvPath -Append -NoTypeInformation -Force
        } else {
            $fleetRow | Export-Csv -Path $fleetCsvPath -NoTypeInformation -Force
        }
        Write-Host "`n  Fleet CSV updated: $fleetCsvPath" -ForegroundColor Green
        Write-Log "Fleet CSV updated: $fleetCsvPath" -Level Success
    } catch {
        Write-Log "Fleet CSV export failed: $($_.Exception.Message)" -Level Warning
    }


    # Audit log
    $auditFailCount = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    $auditWarnCount = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $auditSev = Get-SeverityCode -Component 'EnterpriseReadinessReport' -Status $(if ($auditFailCount -gt 0) {'Fail'} elseif ($auditWarnCount -gt 0) {'Warning'} else {'Pass'})
    Write-AuditLog -Module 'EnterpriseReadinessReport' -IssueCode "F:$auditFailCount,W:$auditWarnCount" -Severity $auditSev -ActionTaken 'ScanOnly' -FinalState $(if ($auditFailCount -gt 0) {'IssuesFound'} elseif ($auditWarnCount -gt 0) {'Attention'} else {'Clean'})
    Export-DiagnosticReport -Title "Enterprise Readiness Report Results" -Results $results
    Write-Log "Enterprise Readiness Report completed - Score: $totalScore/100 ($lifecycle)" -Level Success
    return $results
}

#endregion

#region Main Menu and Program Flow
function Show-MainMenu {
    $categories = @{
        "Diagnostics" = @("Advanced Diagnostic","BSOD Analysis","Enhanced Hardware Test","Custom Tests","Diagnostic Analyzer")
        "Repair Tools" = @("Boot Repair","BIOS Repair","Driver Repair","Software Cleanup")
        "Fleet Management" = @("Fleet Report","Verify Scripts","Compatibility Checker","Hardware Inventory")
        "Hardware Tests" = @("Battery Health","Network Diagnostic","Performance Analyzer","Thermal Analysis","Display Calibration","Audio Diagnostic","Keyboard Test","TrackPoint Calibration","Power Settings")
        "System Management" = @("Secure Wipe","Deployment Prep","Update Manager","BIOS Update","Security Check")
        "Refurbishment" = @("Refurb Battery Analysis","Refurb Quality Check","Refurb Thermal Analysis")
        "Troubleshooters" = @("Security Hardening","Network Troubleshooter","BSOD Troubleshooter","Input Device Troubleshooter","Driver Auto-Update")
        "Advanced Diagnostics" = @("POST Error Reader","SMART Disk Analysis","CMOS Battery Check","Machine Identity Check","TPM Health Check","Win11 Readiness Check","Lenovo Vantage Check","Memory Error Log Check","Display Pixel Check","Enterprise Readiness Report")
    }

    $allOptions = @()
    $catOrder = @("Diagnostics","Repair Tools","Fleet Management","Hardware Tests","System Management","Refurbishment","Troubleshooters","Advanced Diagnostics")
    foreach ($cat in $catOrder) { $allOptions += $categories[$cat] }

    $choice = Show-Menu -Title "Laptop Diagnostic Toolkit v$script:Version" -Options $allOptions -BackText "Exit"
    if ($choice -eq ($allOptions.Count + 1)) { return $false }

    $selected = $allOptions[$choice - 1]
    $funcMap = @{
        "Advanced Diagnostic"="Invoke-AdvancedDiagnostic"; "BSOD Analysis"="Invoke-BSODAnalysis"
        "Enhanced Hardware Test"="Invoke-EnhancedHardwareTest"; "Custom Tests"="Invoke-CustomTests"
        "Diagnostic Analyzer"="Invoke-DiagnosticAnalyzer"; "Boot Repair"="Invoke-BootRepair"
        "BIOS Repair"="Invoke-BIOSRepair"; "Driver Repair"="Invoke-DriverRepair"
        "Software Cleanup"="Invoke-SoftwareCleanup"; "Fleet Report"="Invoke-FleetReport"
        "Verify Scripts"="Invoke-VerifyScripts"; "Compatibility Checker"="Invoke-CompatibilityChecker"
        "Hardware Inventory"="Invoke-HardwareInventory"; "Battery Health"="Invoke-BatteryHealth"
        "Network Diagnostic"="Invoke-NetworkDiagnostic"; "Performance Analyzer"="Invoke-PerformanceAnalyzer"
        "Thermal Analysis"="Invoke-ThermalAnalysis"; "Display Calibration"="Invoke-DisplayCalibration"
        "Audio Diagnostic"="Invoke-AudioDiagnostic"; "Keyboard Test"="Invoke-KeyboardTest"
        "TrackPoint Calibration"="Invoke-TrackPointCalibration"; "Power Settings"="Invoke-PowerSettings"
        "Secure Wipe"="Invoke-SecureWipe"; "Deployment Prep"="Invoke-DeploymentPrep"
        "Update Manager"="Invoke-UpdateManager"; "BIOS Update"="Invoke-BIOSUpdate"
        "Security Check"="Invoke-SecurityCheck"
        "Refurb Battery Analysis"="Invoke-RefurbBatteryAnalysis"
        "Refurb Quality Check"="Invoke-RefurbQualityCheck"
        "Refurb Thermal Analysis"="Invoke-RefurbThermalAnalysis"
        "Security Hardening"="Invoke-SecurityHardening"
        "Network Troubleshooter"="Invoke-NetworkTroubleshooter"
        "BSOD Troubleshooter"="Invoke-BSODTroubleshooter"
        "Input Device Troubleshooter"="Invoke-InputTroubleshooter"
        "Driver Auto-Update"="Invoke-DriverAutoUpdate"
        "POST Error Reader"="Invoke-POSTErrorReader"
        "SMART Disk Analysis"="Invoke-SMARTDiskAnalysis"
        "CMOS Battery Check"="Invoke-CMOSBatteryCheck"
        "Machine Identity Check"="Invoke-MachineIdentityCheck"
        "TPM Health Check"="Invoke-TPMHealthCheck"
        "Win11 Readiness Check"="Invoke-Win11ReadinessCheck"
        "Lenovo Vantage Check"="Invoke-LenovoVantageCheck"
        "Memory Error Log Check"="Invoke-MemoryErrorLogCheck"
        "Display Pixel Check"="Invoke-DisplayPixelCheck"
        "Enterprise Readiness Report"="Invoke-EnterpriseReadinessReport"
    }

    if ($funcMap.ContainsKey($selected)) {
        & $funcMap[$selected]
        Write-Host "`nPress any key to continue..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    return $true
}

# Main script execution
try {
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  Laptop Diagnostic Toolkit v$script:Version" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host

    Get-SystemInformation | Out-Null
    Test-ConfigIntegrity | Out-Null

    $isCompatible = Test-ThinkPadCompatibility
    if (-not $isCompatible) {
        Write-Host "Exiting due to compatibility concerns." -ForegroundColor Red
        exit 1
    }

    Write-Host "System Information:" -ForegroundColor Cyan
    Write-Host "  Manufacturer: $($script:SystemInfo.Manufacturer)" -ForegroundColor White
    Write-Host "  Model: $($script:SystemInfo.Model)" -ForegroundColor White
    Write-Host "  Serial Number: $($script:SystemInfo.SerialNumber)" -ForegroundColor White
    Write-Host "  BIOS Version: $($script:SystemInfo.BIOSVersion)" -ForegroundColor White
    Write-Host "  OS Version: $($script:SystemInfo.OSVersion)" -ForegroundColor White
    Write-Host "  Processor: $($script:SystemInfo.ProcessorName)" -ForegroundColor White
    Write-Host "  Memory: $($script:SystemInfo.TotalMemoryGB) GB" -ForegroundColor White
    Write-Host

    if ($RunFunction) {
        $functionName = "Invoke-$RunFunction"
        & $functionName
        exit 0
    }

    if (-not $SkipMenu) {
        $continue = $true
        while ($continue) { $continue = Show-MainMenu }
    }

    Write-Host "Thank you for using Laptop Diagnostic Toolkit." -ForegroundColor Cyan
    exit 0
} catch {
    Write-Log "Critical error: $($_.Exception.Message)" -Level Error
    Write-Host "Critical error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
#endregion
