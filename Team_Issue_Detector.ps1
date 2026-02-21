<#
.SYNOPSIS
    Team Issue Detector - LDT v6.0 Option 49
    Scans for BSOD, Unexpected Resets, and VPN/Network issues.
    Displays live terminal results, generates HTML report, auto-launches fix modules.

.VERSION
    1.0.0

.NOTES
    Architecture: Standalone PS1 (called by Laptop_Master_Diagnostic.bat)
    Dependencies: None - vanilla PowerShell 5.1
    Config: Reads thresholds from Config\config.ini
    Output: Terminal + HTML report + log file
#>

param(
    [string]$LogPath     = ".\Logs",
    [string]$ReportPath  = ".\Reports",
    [string]$ConfigPath  = ".\Config",
    [string]$BackupPath  = ".\Backups",
    [string]$TempPath    = ".\Temp",
    [string]$DataPath    = ".\Data",
    [string]$ScriptRoot  = ""
)

# ============================================================
# SETUP
# ============================================================

$ErrorActionPreference = "SilentlyContinue"
$timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$dateDisplay = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$logFile     = Join-Path $LogPath    "IssueDetector_$timestamp.log"
$reportFile  = Join-Path $ReportPath "IssueDetector_$timestamp.html"

# Determine script root for calling main PS1
if (-not $ScriptRoot) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$mainPS1 = Join-Path $ScriptRoot "Laptop_Diagnostic_Suite.ps1"

# Machine info
$computerName = $env:COMPUTERNAME
$serialNumber = (Get-CimInstance Win32_BIOS).SerialNumber
$model         = (Get-CimInstance Win32_ComputerSystem).Model

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
Write-Log "Team Issue Detector v1.0.0 started"
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

# Read thresholds from config (with defaults - PS 5.1 compatible)
$bsodDaysBack       = if ($config["Diagnostics.BSODDaysBack"])           { [int]$config["Diagnostics.BSODDaysBack"] }           else { 30 }
$eventLogDaysBack    = if ($config["Diagnostics.EventLogDaysBack"])       { [int]$config["Diagnostics.EventLogDaysBack"] }       else { 7 }
$maxEventLogEntries  = if ($config["Diagnostics.MaxEventLogEntries"])     { [int]$config["Diagnostics.MaxEventLogEntries"] }     else { 500 }
$fallbackDNSPrimary  = if ($config["AutoRemediation.FallbackDNSPrimary"]) { $config["AutoRemediation.FallbackDNSPrimary"] }      else { "8.8.8.8" }
$fallbackDNSSecondary = if ($config["AutoRemediation.FallbackDNSSecondary"]) { $config["AutoRemediation.FallbackDNSSecondary"] } else { "1.1.1.1" }

Write-Log "Config loaded: BSODDaysBack=$bsodDaysBack, EventLogDaysBack=$eventLogDaysBack"

# ============================================================
# TERMINAL OUTPUT HELPERS
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
    $padding = " " * (40 - $Label.Length)
    if ($padding.Length -lt 1) { $padding = " " }
    Write-Host "    $Label$padding" -NoNewline -ForegroundColor Gray
    Write-Host "$Value" -ForegroundColor $Color
}

function Write-Verdict {
    param([string]$Issue, [bool]$Found, [string]$Detail = "")
    if ($Found) {
        Write-Host ""
        Write-Host "    [X] $Issue " -NoNewline -ForegroundColor Red
        Write-Host "ISSUE FOUND" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkYellow }
    } else {
        Write-Host ""
        Write-Host "    [OK] $Issue " -NoNewline -ForegroundColor Green
        Write-Host "NO ISSUE" -ForegroundColor Green
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    }
}

# ============================================================
# DETECTOR 1: BSOD (Blue Screen of Death)
# ============================================================

function Test-BSODIssue {
    Write-ScanHeader -Name "BSOD / BLUE SCREEN DETECTION" -Icon "[1/3]"
    Write-Log "--- BSOD Detection Started ---"

    $result = @{
        Found          = $false
        DumpCount      = 0
        DumpFiles      = @()
        BugCheckEvents = @()
        FaultingDriver = ""
        StopCode       = ""
        LastCrashDate  = ""
        Detail         = ""
    }

    # Check 1: Minidump files
    Write-Host "    Scanning crash dump files..." -ForegroundColor DarkGray
    $minidumpPath = "$env:SystemRoot\Minidump"
    $cutoffDate   = (Get-Date).AddDays(-$bsodDaysBack)

    if (Test-Path $minidumpPath) {
        $dumps = Get-ChildItem -Path $minidumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -ge $cutoffDate }
        $result.DumpCount = $dumps.Count
        $result.DumpFiles = $dumps | Select-Object Name, LastWriteTime, @{N='SizeKB';E={[math]::Round($_.Length/1KB)}}

        if ($dumps.Count -gt 0) {
            $latestDump = $dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $result.LastCrashDate = $latestDump.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    Write-Finding -Label "Minidump folder" -Value $(if (Test-Path $minidumpPath) { "Exists" } else { "Not found" })
    Write-Finding -Label "Crash dumps (last $bsodDaysBack days)" -Value "$($result.DumpCount) files" -Color $(if ($result.DumpCount -gt 0) { "Red" } else { "Green" })

    # Check 2: BugCheck events from Windows Error Reporting
    Write-Host "    Scanning event logs for BugCheck..." -ForegroundColor DarkGray
    try {
        $bugChecks = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 1001
            StartTime = $cutoffDate
        } -MaxEvents $maxEventLogEntries -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' }

        if ($bugChecks) {
            $result.BugCheckEvents = $bugChecks | Select-Object TimeCreated, Message
            # Try to extract stop code from latest event
            $latestBug = $bugChecks | Select-Object -First 1
            if ($latestBug.Message -match '0x([0-9A-Fa-f]+)') {
                $result.StopCode = "0x$($Matches[1])"
            }
        }
    } catch { }

    Write-Finding -Label "BugCheck events (last $bsodDaysBack days)" -Value "$(@($result.BugCheckEvents).Count) events" -Color $(if (@($result.BugCheckEvents).Count -gt 0) { "Red" } else { "Green" })

    # Check 3: Try to identify faulting driver from most recent event
    Write-Host "    Checking for faulting drivers..." -ForegroundColor DarkGray
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
                $result.FaultingDriver = $Matches[1]
            }
        }
    } catch { }

    if ($result.FaultingDriver) {
        Write-Finding -Label "Suspected faulting driver" -Value $result.FaultingDriver -Color "Yellow"
    } else {
        Write-Finding -Label "Suspected faulting driver" -Value "None identified" -Color "Green"
    }

    if ($result.LastCrashDate) {
        Write-Finding -Label "Last crash date" -Value $result.LastCrashDate -Color "Yellow"
    }

    # Verdict
    $result.Found = ($result.DumpCount -gt 0) -or (@($result.BugCheckEvents).Count -gt 0)
    if ($result.Found) {
        $detail = "$($result.DumpCount) crash dumps, $(@($result.BugCheckEvents).Count) BugCheck events"
        if ($result.FaultingDriver) { $detail += ", driver: $($result.FaultingDriver)" }
        if ($result.StopCode)       { $detail += ", stop: $($result.StopCode)" }
        $result.Detail = $detail
    } else {
        $result.Detail = "No crash dumps or BugCheck events in the last $bsodDaysBack days"
    }

    Write-Verdict -Issue "BSOD / BLUE SCREEN" -Found $result.Found -Detail $result.Detail
    Write-Log "BSOD Result: Found=$($result.Found) | $($result.Detail)"

    return $result
}

# ============================================================
# DETECTOR 2: UNEXPECTED RESETS / SHUTDOWNS
# ============================================================

function Test-ResetIssue {
    Write-ScanHeader -Name "UNEXPECTED RESET / SHUTDOWN DETECTION" -Icon "[2/3]"
    Write-Log "--- Reset Detection Started ---"

    $result = @{
        Found             = $false
        KernelPowerCount  = 0
        UnexpectedCount   = 0
        KernelPowerEvents = @()
        EventID6008       = @()
        SystemUptime      = ""
        UptimeHours       = 0
        LastResetDate     = ""
        Detail            = ""
    }

    $cutoffDate = (Get-Date).AddDays(-$eventLogDaysBack)

    # Check 1: Event ID 41 - Kernel-Power (unexpected shutdown / restart)
    Write-Host "    Scanning for Kernel-Power events (ID 41)..." -ForegroundColor DarkGray
    try {
        $kernelPower = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Kernel-Power'
            Id           = 41
            StartTime    = $cutoffDate
        } -MaxEvents $maxEventLogEntries -ErrorAction SilentlyContinue

        if ($kernelPower) {
            $result.KernelPowerCount  = $kernelPower.Count
            $result.KernelPowerEvents = $kernelPower | Select-Object TimeCreated, Message
            $result.LastResetDate     = ($kernelPower | Select-Object -First 1).TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
        }
    } catch { }

    Write-Finding -Label "Kernel-Power ID 41 (last $eventLogDaysBack days)" -Value "$($result.KernelPowerCount) events" -Color $(if ($result.KernelPowerCount -gt 0) { "Red" } else { "Green" })

    # Check 2: Event ID 6008 - Unexpected shutdown
    Write-Host "    Scanning for unexpected shutdown events (ID 6008)..." -ForegroundColor DarkGray
    try {
        $unexpected = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 6008
            StartTime = $cutoffDate
        } -MaxEvents $maxEventLogEntries -ErrorAction SilentlyContinue

        if ($unexpected) {
            $result.UnexpectedCount = $unexpected.Count
            $result.EventID6008     = $unexpected | Select-Object TimeCreated, Message
            if (-not $result.LastResetDate) {
                $result.LastResetDate = ($unexpected | Select-Object -First 1).TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
    } catch { }

    Write-Finding -Label "Unexpected shutdowns ID 6008" -Value "$($result.UnexpectedCount) events" -Color $(if ($result.UnexpectedCount -gt 0) { "Red" } else { "Green" })

    # Check 3: System uptime
    Write-Host "    Checking system uptime..." -ForegroundColor DarkGray
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $uptime = (Get-Date) - $os.LastBootUpTime
        $result.UptimeHours = [math]::Round($uptime.TotalHours, 1)
        $result.SystemUptime = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
    } catch {
        $result.SystemUptime = "Unknown"
    }

    $uptimeColor = if ($result.UptimeHours -lt 1) { "Red" } elseif ($result.UptimeHours -lt 24) { "Yellow" } else { "Green" }
    Write-Finding -Label "Current uptime" -Value $result.SystemUptime -Color $uptimeColor
    if ($result.LastResetDate) {
        Write-Finding -Label "Last unexpected reset" -Value $result.LastResetDate -Color "Yellow"
    }

    # Check 4: Boot pattern - multiple boots in short time suggests reset loop
    Write-Host "    Checking boot frequency..." -ForegroundColor DarkGray
    $recentBoots = 0
    try {
        $bootEvents = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 12
            StartTime = (Get-Date).AddDays(-1)
        } -MaxEvents 50 -ErrorAction SilentlyContinue
        $recentBoots = @($bootEvents).Count
    } catch { }

    Write-Finding -Label "System boots in last 24h" -Value "$recentBoots" -Color $(if ($recentBoots -gt 3) { "Red" } elseif ($recentBoots -gt 1) { "Yellow" } else { "Green" })

    # Verdict
    $totalEvents = $result.KernelPowerCount + $result.UnexpectedCount
    $result.Found = ($totalEvents -gt 0) -or ($recentBoots -gt 3) -or ($result.UptimeHours -lt 1)

    if ($result.Found) {
        $parts = @()
        if ($result.KernelPowerCount -gt 0) { $parts += "$($result.KernelPowerCount)x Kernel-Power" }
        if ($result.UnexpectedCount  -gt 0) { $parts += "$($result.UnexpectedCount)x unexpected shutdown" }
        if ($recentBoots -gt 3)             { $parts += "$recentBoots boots in 24h" }
        if ($result.UptimeHours -lt 1)      { $parts += "uptime under 1 hour" }
        $result.Detail = $parts -join ", "
    } else {
        $result.Detail = "No unexpected resets in the last $eventLogDaysBack days, uptime $($result.SystemUptime)"
    }

    Write-Verdict -Issue "UNEXPECTED RESETS" -Found $result.Found -Detail $result.Detail
    Write-Log "Reset Result: Found=$($result.Found) | $($result.Detail)"

    return $result
}

# ============================================================
# DETECTOR 3: VPN / NETWORK ISSUES
# ============================================================

function Test-VPNIssue {
    Write-ScanHeader -Name "VPN / NETWORK CONNECTION DETECTION" -Icon "[3/3]"
    Write-Log "--- VPN/Network Detection Started ---"

    $result = @{
        Found            = $false
        VPNAdapters      = @()
        VPNClientFound   = $false
        VPNClientName    = ""
        VPNConnected     = $false
        DNSWorking       = $false
        InternetAccess   = $false
        WiFiAdapter      = $null
        WiFiStatus       = ""
        NetworkIssues    = @()
        Detail           = ""
    }

    # Check 1: List all network adapters, identify VPN adapters
    Write-Host "    Scanning network adapters..." -ForegroundColor DarkGray
    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
        $vpnAdapterNames = @("VPN", "AnyConnect", "GlobalProtect", "Pulse", "Juniper", "WireGuard", "OpenVPN", "FortiClient", "Cisco", "SonicWall", "F5", "Zscaler", "Tunnel")
        $vpnAdapters = @()
        foreach ($adapter in $adapters) {
            foreach ($vpnName in $vpnAdapterNames) {
                if ($adapter.InterfaceDescription -match $vpnName -or $adapter.Name -match $vpnName) {
                    $vpnAdapters += $adapter
                    break
                }
            }
        }
        $result.VPNAdapters = $vpnAdapters | Select-Object Name, InterfaceDescription, Status, LinkSpeed
    } catch { }

    # Check 2: VPN client software installed
    Write-Host "    Checking for VPN client software..." -ForegroundColor DarkGray
    $vpnClients = @(
        @{ Name = "Cisco AnyConnect";   Path = "${env:ProgramFiles(x86)}\Cisco\Cisco AnyConnect Secure Mobility Client" },
        @{ Name = "GlobalProtect";      Path = "${env:ProgramFiles}\Palo Alto Networks\GlobalProtect" },
        @{ Name = "Pulse Secure";       Path = "${env:ProgramFiles(x86)}\Pulse Secure" },
        @{ Name = "FortiClient";        Path = "${env:ProgramFiles}\Fortinet\FortiClient" },
        @{ Name = "Zscaler";            Path = "${env:ProgramFiles}\Zscaler" },
        @{ Name = "WireGuard";          Path = "${env:ProgramFiles}\WireGuard" }
    )

    foreach ($client in $vpnClients) {
        if (Test-Path $client.Path) {
            $result.VPNClientFound = $true
            $result.VPNClientName  = $client.Name
            break
        }
    }

    # Also check Windows built-in VPN connections
    try {
        $builtinVPN = Get-VpnConnection -ErrorAction SilentlyContinue
        if ($builtinVPN) {
            $result.VPNClientFound = $true
            if (-not $result.VPNClientName) {
                $result.VPNClientName = "Windows Built-in VPN ($($builtinVPN[0].Name))"
            }
            foreach ($vpn in $builtinVPN) {
                if ($vpn.ConnectionStatus -eq "Connected") {
                    $result.VPNConnected = $true
                }
            }
        }
    } catch { }

    Write-Finding -Label "VPN client installed" -Value $(if ($result.VPNClientFound) { "$($result.VPNClientName)" } else { "None detected" }) -Color $(if ($result.VPNClientFound) { "Green" } else { "Yellow" })

    if ($result.VPNAdapters.Count -gt 0) {
        foreach ($va in $result.VPNAdapters) {
            $statusColor = if ($va.Status -eq "Up") { "Green" } else { "Red" }
            Write-Finding -Label "  VPN adapter: $($va.Name)" -Value "$($va.Status)" -Color $statusColor
            if ($va.Status -ne "Up") {
                $result.NetworkIssues += "VPN adapter '$($va.Name)' is $($va.Status)"
            }
        }
    } else {
        Write-Finding -Label "VPN adapters" -Value "None found" -Color "DarkGray"
    }

    # Check 3: Wi-Fi adapter status
    Write-Host "    Checking Wi-Fi adapter..." -ForegroundColor DarkGray
    try {
        $wifi = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceDescription -match 'Wi-Fi|WiFi|Wireless|Intel.*AX|Intel.*AC|802\.11'
        } | Select-Object -First 1

        if ($wifi) {
            $result.WiFiAdapter = $wifi
            $result.WiFiStatus  = $wifi.Status
            $wifiColor = if ($wifi.Status -eq "Up") { "Green" } else { "Red" }
            Write-Finding -Label "Wi-Fi adapter" -Value "$($wifi.InterfaceDescription) - $($wifi.Status)" -Color $wifiColor
            if ($wifi.Status -ne "Up") {
                $result.NetworkIssues += "Wi-Fi adapter is $($wifi.Status)"
            }
        } else {
            Write-Finding -Label "Wi-Fi adapter" -Value "Not found" -Color "Yellow"
        }
    } catch { }

    # Check 4: DNS resolution
    Write-Host "    Testing DNS resolution..." -ForegroundColor DarkGray
    try {
        $dnsTest = Resolve-DnsName -Name "dns.msftncsi.com" -Type A -DnsOnly -ErrorAction Stop
        $result.DNSWorking = $true
        Write-Finding -Label "DNS resolution" -Value "Working" -Color "Green"
    } catch {
        $result.DNSWorking = $false
        $result.NetworkIssues += "DNS resolution failed"
        Write-Finding -Label "DNS resolution" -Value "FAILED" -Color "Red"
    }

    # Check 5: Internet connectivity (TCP test to known endpoint)
    Write-Host "    Testing internet connectivity..." -ForegroundColor DarkGray
    try {
        $tcpTest = Test-NetConnection -ComputerName "8.8.8.8" -Port 53 -WarningAction SilentlyContinue -InformationLevel Quiet
        $result.InternetAccess = $tcpTest
        Write-Finding -Label "Internet access (8.8.8.8:53)" -Value $(if ($tcpTest) { "Reachable" } else { "UNREACHABLE" }) -Color $(if ($tcpTest) { "Green" } else { "Red" })
        if (-not $tcpTest) {
            $result.NetworkIssues += "No internet connectivity (8.8.8.8 unreachable)"
        }
    } catch {
        $result.InternetAccess = $false
        $result.NetworkIssues += "Internet connectivity test failed"
        Write-Finding -Label "Internet access" -Value "Test failed" -Color "Red"
    }

    # Check 6: VPN-specific service status
    Write-Host "    Checking VPN-related services..." -ForegroundColor DarkGray
    $vpnServices = @("vpnagent", "PanGPS", "GlobalProtect", "PulseSecureService", "FortiClient", "ZscalerService", "WireGuardTunnel*")
    foreach ($svcName in $vpnServices) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc) {
                $svcColor = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
                Write-Finding -Label "  Service: $($svc.DisplayName)" -Value "$($svc.Status)" -Color $svcColor
                if ($svc.Status -ne "Running") {
                    $result.NetworkIssues += "VPN service '$($svc.DisplayName)' is $($svc.Status)"
                }
            }
        } catch { }
    }

    # Verdict
    $result.Found = ($result.NetworkIssues.Count -gt 0)

    if ($result.Found) {
        $result.Detail = $result.NetworkIssues -join "; "
    } else {
        $detail = "Network healthy"
        if ($result.VPNClientFound) { $detail += ", $($result.VPNClientName) installed" }
        $detail += ", DNS working, internet reachable"
        $result.Detail = $detail
    }

    Write-Verdict -Issue "VPN / NETWORK" -Found $result.Found -Detail $result.Detail
    Write-Log "VPN Result: Found=$($result.Found) | $($result.Detail)"

    return $result
}

# ============================================================
# HTML REPORT GENERATOR
# ============================================================

function New-HTMLReport {
    param(
        [hashtable]$BSOD,
        [hashtable]$Reset,
        [hashtable]$VPN
    )

    $issueCount = 0
    if ($BSOD.Found)  { $issueCount++ }
    if ($Reset.Found)  { $issueCount++ }
    if ($VPN.Found)    { $issueCount++ }

    $overallStatus = if ($issueCount -eq 0) { "ALL CLEAR" } elseif ($issueCount -le 1) { "ATTENTION NEEDED" } else { "CRITICAL" }
    $overallColor  = if ($issueCount -eq 0) { "#00C875" } elseif ($issueCount -le 1) { "#F59E0B" } else { "#E2231A" }

    function Get-StatusBadge([bool]$found) {
        if ($found) {
            return '<span style="background:rgba(226,35,26,0.15);color:#FF6B6B;border:1px solid rgba(226,35,26,0.3);padding:4px 12px;border-radius:6px;font-family:monospace;font-size:11px;font-weight:600">ISSUE FOUND</span>'
        } else {
            return '<span style="background:rgba(0,200,117,0.15);color:#00C875;border:1px solid rgba(0,200,117,0.3);padding:4px 12px;border-radius:6px;font-family:monospace;font-size:11px;font-weight:600">NO ISSUE</span>'
        }
    }

    function Get-FindingsHTML([hashtable]$result, [string]$name) {
        $rows = ""
        switch ($name) {
            "BSOD" {
                $rows += "<tr><td>Crash dump files</td><td>$($result.DumpCount) files (last $bsodDaysBack days)</td></tr>"
                $rows += "<tr><td>BugCheck events</td><td>$(@($result.BugCheckEvents).Count) events</td></tr>"
                if ($result.FaultingDriver) { $rows += "<tr><td>Suspected driver</td><td style='color:#FF6B6B;font-weight:600'>$($result.FaultingDriver)</td></tr>" }
                if ($result.StopCode)       { $rows += "<tr><td>Stop code</td><td style='color:#FF6B6B'>$($result.StopCode)</td></tr>" }
                if ($result.LastCrashDate)  { $rows += "<tr><td>Last crash</td><td>$($result.LastCrashDate)</td></tr>" }
            }
            "Reset" {
                $rows += "<tr><td>Kernel-Power (ID 41)</td><td>$($result.KernelPowerCount) events (last $eventLogDaysBack days)</td></tr>"
                $rows += "<tr><td>Unexpected shutdown (ID 6008)</td><td>$($result.UnexpectedCount) events</td></tr>"
                $rows += "<tr><td>System uptime</td><td>$($result.SystemUptime)</td></tr>"
                if ($result.LastResetDate) { $rows += "<tr><td>Last unexpected reset</td><td>$($result.LastResetDate)</td></tr>" }
            }
            "VPN" {
                $rows += "<tr><td>VPN client</td><td>$(if ($result.VPNClientFound) { $result.VPNClientName } else { 'None detected' })</td></tr>"
                $rows += "<tr><td>VPN adapters</td><td>$($result.VPNAdapters.Count) found</td></tr>"
                $rows += "<tr><td>DNS resolution</td><td>$(if ($result.DNSWorking) { 'Working' } else { '<span style=color:#FF6B6B>FAILED</span>' })</td></tr>"
                $rows += "<tr><td>Internet access</td><td>$(if ($result.InternetAccess) { 'Reachable' } else { '<span style=color:#FF6B6B>UNREACHABLE</span>' })</td></tr>"
                if ($result.WiFiAdapter) { $rows += "<tr><td>Wi-Fi</td><td>$($result.WiFiAdapter.InterfaceDescription) &mdash; $($result.WiFiStatus)</td></tr>" }
                foreach ($issue in $result.NetworkIssues) {
                    $rows += "<tr><td>Issue</td><td style='color:#FF6B6B'>$issue</td></tr>"
                }
            }
        }
        return $rows
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="dark">
<title>Issue Detector Report - $computerName - $dateDisplay</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #0A0F1A; color: #F5F7FA; font-family: 'Segoe UI', sans-serif; font-size: 14px; line-height: 1.7; padding: 40px 20px; }
  .container { max-width: 900px; margin: 0 auto; }
  h1 { font-size: 32px; margin-bottom: 4px; letter-spacing: 1px; }
  h1 span { color: #E2231A; }
  .subtitle { color: #7A8BA8; font-size: 13px; margin-bottom: 32px; }
  .machine-info { display: flex; gap: 24px; flex-wrap: wrap; margin-bottom: 32px; padding: 16px 20px; background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; }
  .machine-info div { font-size: 12px; color: #7A8BA8; }
  .machine-info strong { color: #F5F7FA; font-weight: 600; }
  .overall { text-align: center; padding: 32px; margin-bottom: 40px; border-radius: 16px; border: 2px solid ${overallColor}40; background: ${overallColor}10; }
  .overall-status { font-size: 40px; font-weight: 700; color: ${overallColor}; letter-spacing: 2px; margin-bottom: 8px; }
  .overall-sub { color: #7A8BA8; font-size: 14px; }
  .section { margin-bottom: 32px; padding: 24px; background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; }
  .section-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
  .section-title { font-size: 18px; font-weight: 600; }
  .section-detail { font-size: 12px; color: #7A8BA8; margin-bottom: 16px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; padding: 8px 12px; color: #4A8BEF; font-size: 10px; text-transform: uppercase; letter-spacing: 1.5px; border-bottom: 1px solid rgba(26,93,204,0.3); font-weight: 400; }
  td { padding: 8px 12px; border-bottom: 1px solid rgba(255,255,255,0.05); color: #A0B8D0; }
  td:first-child { color: #7A8BA8; width: 200px; }
  .fix-section { margin-top: 40px; padding: 24px; background: rgba(26,93,204,0.08); border: 1px solid rgba(26,93,204,0.25); border-radius: 12px; }
  .fix-title { font-size: 18px; font-weight: 600; color: #4A8BEF; margin-bottom: 12px; }
  .fix-item { padding: 8px 0; border-bottom: 1px solid rgba(255,255,255,0.05); display: flex; gap: 12px; }
  .fix-option { font-family: monospace; font-size: 12px; color: #4A8BEF; min-width: 100px; }
  .fix-desc { color: #A0B8D0; font-size: 13px; }
  .footer { margin-top: 40px; text-align: center; color: rgba(122,139,168,0.5); font-size: 11px; }
  @media print { body { background: #fff; color: #111; } .section, .machine-info, .overall, .fix-section { background: #f8f8f8; border-color: #ccc; } .overall-status { color: #333; } td, th { color: #333; } }
</style>
</head>
<body>
<div class="container">
  <h1>ISSUE DETECTOR <span>REPORT</span></h1>
  <div class="subtitle">LDT v6.0 - Team Issue Detector v1.0.0 - Generated $dateDisplay</div>

  <div class="machine-info">
    <div><strong>$computerName</strong> Computer</div>
    <div><strong>$model</strong> Model</div>
    <div><strong>$serialNumber</strong> Serial</div>
    <div><strong>$dateDisplay</strong> Scan Time</div>
  </div>

  <div class="overall">
    <div class="overall-status">$overallStatus</div>
    <div class="overall-sub">$issueCount of 3 checks found issues</div>
  </div>

  <div class="section">
    <div class="section-header">
      <div class="section-title">1. BSOD / Blue Screen</div>
      $(Get-StatusBadge $BSOD.Found)
    </div>
    <div class="section-detail">$($BSOD.Detail)</div>
    <table><thead><tr><th>Check</th><th>Result</th></tr></thead><tbody>
    $(Get-FindingsHTML -result $BSOD -name "BSOD")
    </tbody></table>
  </div>

  <div class="section">
    <div class="section-header">
      <div class="section-title">2. Unexpected Resets</div>
      $(Get-StatusBadge $Reset.Found)
    </div>
    <div class="section-detail">$($Reset.Detail)</div>
    <table><thead><tr><th>Check</th><th>Result</th></tr></thead><tbody>
    $(Get-FindingsHTML -result $Reset -name "Reset")
    </tbody></table>
  </div>

  <div class="section">
    <div class="section-header">
      <div class="section-title">3. VPN / Network</div>
      $(Get-StatusBadge $VPN.Found)
    </div>
    <div class="section-detail">$($VPN.Detail)</div>
    <table><thead><tr><th>Check</th><th>Result</th></tr></thead><tbody>
    $(Get-FindingsHTML -result $VPN -name "VPN")
    </tbody></table>
  </div>

  $(if ($issueCount -gt 0) { @"
  <div class="fix-section">
    <div class="fix-title">RECOMMENDED FIXES</div>
    $(if ($BSOD.Found) { '<div class="fix-item"><div class="fix-option">Option 33</div><div class="fix-desc">BSOD Troubleshooter - auto-fix crash-causing drivers + system repair</div></div>' })
    $(if ($Reset.Found) { '<div class="fix-item"><div class="fix-option">Option 1</div><div class="fix-desc">Advanced Diagnostic - full system scan to identify root cause of resets</div></div>' })
    $(if ($VPN.Found) { '<div class="fix-item"><div class="fix-option">Option 32</div><div class="fix-desc">Network Troubleshooter - auto-fix Wi-Fi, VPN adapters, DNS, drivers</div></div>' })
  </div>
"@ })

  <div class="footer">
    LDT v6.0 &middot; Team Issue Detector v1.0.0 &middot; Report: IssueDetector_$timestamp.html
  </div>
</div>
</body>
</html>
"@

    $html | Out-File -FilePath $reportFile -Encoding UTF8 -Force
    Write-Log "HTML report saved: $reportFile"
}

# ============================================================
# AUTO-FIX LAUNCHER
# ============================================================

function Invoke-AutoFix {
    param(
        [hashtable]$BSOD,
        [hashtable]$Reset,
        [hashtable]$VPN
    )

    $fixes = @()
    if ($BSOD.Found)  { $fixes += @{ Option = "33"; Name = "BSOD Troubleshooter";    Func = "BSODTroubleshooter" } }
    if ($VPN.Found)    { $fixes += @{ Option = "32"; Name = "Network Troubleshooter";  Func = "NetworkTroubleshooter" } }
    if ($Reset.Found)  { $fixes += @{ Option = "1";  Name = "Advanced Diagnostic";     Func = "AdvancedDiagnostic" } }

    if ($fixes.Count -eq 0) {
        Write-Host ""
        Write-Host "  No issues found - no fixes needed." -ForegroundColor Green
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor DarkYellow
    Write-Host "   AUTO-FIX: $($fixes.Count) module(s) ready to launch" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor DarkYellow
    Write-Host ""

    foreach ($fix in $fixes) {
        Write-Host "    Option $($fix.Option) → $($fix.Name)" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "  Launch all fix modules now? [Y/N]: " -NoNewline -ForegroundColor Yellow
    $confirm = Read-Host

    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host ""
        Write-Host "  Auto-fix skipped. You can run these modules manually from the main menu." -ForegroundColor DarkGray
        Write-Log "Auto-fix declined by user"
        return
    }

    Write-Log "Auto-fix approved by user"

    # Verify main PS1 exists
    if (-not (Test-Path $mainPS1)) {
        Write-Host ""
        Write-Host "  ERROR: Laptop_Diagnostic_Suite.ps1 not found at:" -ForegroundColor Red
        Write-Host "  $mainPS1" -ForegroundColor Red
        Write-Host "  Please run fix modules manually from the main menu." -ForegroundColor DarkGray
        Write-Log "ERROR: Main PS1 not found at $mainPS1"
        return
    }

    foreach ($fix in $fixes) {
        Write-Host ""
        Write-Host "  --------------------------------------------" -ForegroundColor DarkCyan
        Write-Host "  Running: Option $($fix.Option) - $($fix.Name)" -ForegroundColor Cyan
        Write-Host "  --------------------------------------------" -ForegroundColor DarkCyan
        Write-Host ""
        Write-Log "Launching fix: $($fix.Func) (Option $($fix.Option))"

        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $mainPS1 `
                -RunFunction $fix.Func `
                -LogPath $LogPath `
                -ReportPath $ReportPath `
                -ConfigPath $ConfigPath `
                -BackupPath $BackupPath `
                -TempPath $TempPath `
                -DataPath $DataPath

            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                Write-Host "  $($fix.Name) completed with warnings (exit code: $exitCode)" -ForegroundColor Yellow
                Write-Log "$($fix.Func) completed with exit code $exitCode"
            } else {
                Write-Host "  $($fix.Name) completed successfully" -ForegroundColor Green
                Write-Log "$($fix.Func) completed successfully"
            }
        } catch {
            Write-Host "  ERROR running $($fix.Name): $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "ERROR running $($fix.Func): $($_.Exception.Message)"
        }
    }

    Write-Host ""
    Write-Host "  All fix modules completed." -ForegroundColor Green
    Write-Host ""
}

# ============================================================
# MAIN EXECUTION
# ============================================================

Write-Banner "TEAM ISSUE DETECTOR v1.0.0"

Write-Host "  Machine:  $computerName" -ForegroundColor White
Write-Host "  Model:    $model" -ForegroundColor White
Write-Host "  Serial:   $serialNumber" -ForegroundColor White
Write-Host "  Time:     $dateDisplay" -ForegroundColor White
Write-Host ""
Write-Host "  Scanning for 3 known issues: BSOD, Resets, VPN" -ForegroundColor DarkGray
Write-Host "  Config: BSODDaysBack=$bsodDaysBack | EventLogDaysBack=$eventLogDaysBack" -ForegroundColor DarkGray

# -- Run all 3 detectors --
$bsodResult  = Test-BSODIssue
$resetResult = Test-ResetIssue
$vpnResult   = Test-VPNIssue

# -- Summary --
$issueCount = 0
if ($bsodResult.Found)  { $issueCount++ }
if ($resetResult.Found) { $issueCount++ }
if ($vpnResult.Found)   { $issueCount++ }

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host "   SUMMARY" -ForegroundColor White
Write-Host "  ============================================================" -ForegroundColor DarkCyan
Write-Host ""

if ($issueCount -eq 0) {
    Write-Host "  ALL CLEAR - No issues detected" -ForegroundColor Green
} else {
    Write-Host "  $issueCount of 3 checks found issues:" -ForegroundColor Yellow
    if ($bsodResult.Found)  { Write-Host "    [X] BSOD: $($bsodResult.Detail)" -ForegroundColor Red }
    if ($resetResult.Found) { Write-Host "    [X] RESETS: $($resetResult.Detail)" -ForegroundColor Red }
    if ($vpnResult.Found)   { Write-Host "    [X] VPN/NETWORK: $($vpnResult.Detail)" -ForegroundColor Red }
}

Write-Host ""

# -- Generate HTML report --
Write-Host "  Generating HTML report..." -ForegroundColor DarkGray
New-HTMLReport -BSOD $bsodResult -Reset $resetResult -VPN $vpnResult
Write-Host "  Report saved: $reportFile" -ForegroundColor Green

# -- Auto-fix --
Invoke-AutoFix -BSOD $bsodResult -Reset $resetResult -VPN $vpnResult

# -- Open report --
Write-Host "  Opening report in browser..." -ForegroundColor DarkGray
Start-Process $reportFile -ErrorAction SilentlyContinue

Write-Log "Team Issue Detector completed. Issues found: $issueCount/3"
Write-Log "============================================"

Write-Host ""
Write-Host "  Scan complete. Log saved: $logFile" -ForegroundColor DarkGray
Write-Host ""
