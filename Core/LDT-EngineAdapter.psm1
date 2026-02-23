#Requires -Version 5.1
<#
.SYNOPSIS
    LDT Engine Adapter -- Bridge module between LDT conventions and WinDRE enterprise engines.

.DESCRIPTION
    Provides Write-EngineLog (wraps LDT's Write-Log), ConvertTo-ModuleResults (groups
    DiagState.Findings by Category), and Get-LDTEscalationAsInt (maps L1/L2/L3 to 0-5).

    This module MUST be imported BEFORE GuardEngine, IntegrityEngine, etc. so those
    engines find Write-EngineLog in scope without modification.

.NOTES
    Version : 7.0.0
    Platform: PowerShell 5.1+
#>

Set-StrictMode -Version Latest

# ─────────────────────────────────────────────────────────────────────────────
# Write-EngineLog -- WinDRE engines call this; we route to LDT's Write-Log
# ─────────────────────────────────────────────────────────────────────────────

$script:_AdapterLogFile  = $null
$script:_AdapterLogFunc  = $null

function Initialize-EngineAdapter {
    <#
    .SYNOPSIS
        Set up the adapter with LDT's log file path and optional Write-Log function reference.
    #>
    [CmdletBinding()]
    param(
        [string]$LogFilePath,
        [scriptblock]$WriteLogFunc
    )
    $script:_AdapterLogFile = $LogFilePath
    $script:_AdapterLogFunc = $WriteLogFunc
}

function Write-EngineLog {
    <#
    .SYNOPSIS
        Adapter matching WinDRE engine log signature. Routes to LDT's log file.
    #>
    [CmdletBinding()]
    param(
        [string]$SessionId  = '',
        [ValidateSet('DEBUG','INFO','WARN','ERROR','FATAL','AUDIT')]
        [string]$Level      = 'INFO',
        [string]$Source     = '',
        [string]$Message    = '',
        [hashtable]$Data    = @{},
        [int]$DurationMs    = -1
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = if ($Source) { "[$Source]" } else { '' }
    $durStr = if ($DurationMs -ge 0) { " (${DurationMs}ms)" } else { '' }
    $line   = "[$ts] [$Level] $prefix $Message$durStr"

    # Write to LDT log file if available
    if ($script:_AdapterLogFile -and (Test-Path (Split-Path $script:_AdapterLogFile -Parent))) {
        try { Add-Content -Path $script:_AdapterLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
        catch { }
    }

    # Console output with color coding
    $color = switch ($Level) {
        'FATAL' { 'Red' }
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host "    $line" -ForegroundColor $color
}

function Start-LogTimer {
    <#
    .SYNOPSIS
        Returns a stopwatch for measuring durations. Used by WinDRE engines.
    #>
    $sw = [System.Diagnostics.Stopwatch]::new()
    $sw.Start()
    return $sw
}

# ─────────────────────────────────────────────────────────────────────────────
# ConvertTo-ModuleResults -- Group DiagState.Findings by Category
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-ModuleResults {
    <#
    .SYNOPSIS
        Converts LDT's flat Findings ArrayList into per-module result objects
        compatible with WinDRE ScoringEngine and ComplianceExport.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$DiagState
    )

    $findings = $DiagState.Findings
    if (-not $findings -or $findings.Count -eq 0) {
        return @()
    }

    # Group findings by Category
    $groups = @{}
    foreach ($f in $findings) {
        $cat = if ($f.Category) { $f.Category } else { 'Unknown' }
        if (-not $groups.ContainsKey($cat)) {
            $groups[$cat] = [System.Collections.ArrayList]::new()
        }
        [void]$groups[$cat].Add($f)
    }

    $results = @()
    foreach ($cat in $groups.Keys) {
        $catFindings = $groups[$cat]
        $failCount  = @($catFindings | Where-Object { $_.Status -eq 'Fail' }).Count
        $warnCount  = @($catFindings | Where-Object { $_.Status -eq 'Warning' }).Count

        # Determine module status from worst finding
        $status = if ($failCount -gt 0) { 'FAILED' }
                  elseif ($warnCount -gt 0) { 'PARTIAL' }
                  else { 'PASS' }

        # Map Phase results if available
        $phaseMap = @{
            'Hardware'    = 'Phase2'
            'OS/Boot'     = 'Phase3'
            'Driver'      = 'Phase4'
            'Security'    = 'Phase4'
            'Network'     = 'Phase5'
            'Performance' = 'Phase5'
        }
        $phaseKey = if ($phaseMap.ContainsKey($cat)) { $phaseMap[$cat] } else { $null }
        if ($phaseKey -and $DiagState.PhaseResults -and $DiagState.PhaseResults.ContainsKey($phaseKey)) {
            $phaseStatus = $DiagState.PhaseResults[$phaseKey]
            if ($phaseStatus -eq 'APPLIED') { $status = 'REPAIRED' }
        }

        # Check if repairs were applied for this category
        if ($DiagState.FixesApplied) {
            $repaired = @($DiagState.FixesApplied | Where-Object { $_.Category -eq $cat -or $_.Name -match $cat }).Count
            if ($repaired -gt 0 -and $status -eq 'FAILED') { $status = 'PARTIAL' }
            if ($repaired -gt 0 -and $failCount -eq 0) { $status = 'REPAIRED' }
        }

        $results += [PSCustomObject]@{
            moduleName = $cat
            status     = $status
            findings   = @($catFindings | ForEach-Object {
                [PSCustomObject]@{
                    component = $_.Component
                    severity  = if ($_.Severity) { $_.Severity } else { 'S2' }
                    status    = $_.Status
                    weight    = if ($_.Weight) { $_.Weight } else { 10 }
                    details   = if ($_.Details) { $_.Details } else { '' }
                }
            })
            checks     = @()
            repairs    = @()
            escalations = @()
        }
    }

    return $results
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-LDTEscalationAsInt -- Map LDT L1/L2/L3 to WinDRE 0-5 scale
# ─────────────────────────────────────────────────────────────────────────────

function Get-LDTEscalationAsInt {
    <#
    .SYNOPSIS
        Maps LDT's text escalation levels to WinDRE's integer scale.
        None=0, L1=1, L2=2, L3=4 (L3 maps to hard-stop)
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$EscalationLevel = 'None'
    )

    switch ($EscalationLevel) {
        'L3'    { return 4 }
        'L2'    { return 2 }
        'L1'    { return 1 }
        'None'  { return 0 }
        default { return 0 }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Map LDT Severity Codes to WinDRE Severity Names
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-WinDRESeverity {
    <#
    .SYNOPSIS
        Maps LDT severity codes (H1-H3, S1-S4) to WinDRE severity names.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$LDTSeverity = 'S2'
    )

    switch ($LDTSeverity) {
        'H3'    { return 'CRITICAL' }
        'H2'    { return 'ERROR' }
        'H1'    { return 'WARN' }
        'S3'    { return 'ERROR' }
        'S2'    { return 'WARN' }
        'S1'    { return 'INFO' }
        'S4'    { return 'INFO' }
        default { return 'WARN' }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ConvertTo-ClassificationFindings -- Bridge for ClassificationEngine
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-ClassificationFindings {
    <#
    .SYNOPSIS
        Groups DiagState.Findings by classification level (L1/L2/L3) using
        the ClassificationEngine. Returns a summary suitable for fleet
        aggregation, compliance, and trend reporting.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$DiagState,
        [hashtable]$ClassConfig = @{}
    )

    $l1 = [System.Collections.ArrayList]::new()
    $l2 = [System.Collections.ArrayList]::new()
    $l3 = [System.Collections.ArrayList]::new()

    $findings = $DiagState.Findings
    if (-not $findings) { $findings = @() }

    foreach ($f in $findings) {
        if ($f.Status -eq 'Pass' -or $f.Status -eq 'Info') { continue }

        $health = $null
        if (Get-Command 'Get-ComponentHealth' -ErrorAction SilentlyContinue) {
            $health = Get-ComponentHealth -Finding $f -Config $ClassConfig
        }

        if ($health) {
            switch ($health.Classification) {
                'FATAL'    { [void]$l3.Add([ordered]@{ component = $f.Component; severity = $f.Severity; details = $f.Details; reason = $health.Reason; recommendation = $health.ReplacementRecommendation }) }
                'WEAR'     { [void]$l2.Add([ordered]@{ component = $f.Component; severity = $f.Severity; details = $f.Details; reason = $health.Reason; recommendation = $health.ReplacementRecommendation }) }
                'SOFTWARE' { [void]$l1.Add([ordered]@{ component = $f.Component; severity = $f.Severity; details = $f.Details; reason = $health.Reason }) }
            }
        }
        else {
            # Fallback: use severity code
            if ($f.Severity -match '^H[23]') { [void]$l3.Add([ordered]@{ component = $f.Component; severity = $f.Severity; details = $f.Details }) }
            elseif ($f.Severity -match '^H')  { [void]$l2.Add([ordered]@{ component = $f.Component; severity = $f.Severity; details = $f.Details }) }
            else                               { [void]$l1.Add([ordered]@{ component = $f.Component; severity = $f.Severity; details = $f.Details }) }
        }
    }

    return @{
        L1 = @($l1)
        L2 = @($l2)
        L3 = @($l3)
        Summary = "L1:$($l1.Count) L2:$($l2.Count) L3:$($l3.Count)"
    }
}

Export-ModuleMember -Function @(
    'Initialize-EngineAdapter',
    'Write-EngineLog',
    'Start-LogTimer',
    'ConvertTo-ModuleResults',
    'Get-LDTEscalationAsInt',
    'ConvertTo-WinDRESeverity',
    'ConvertTo-ClassificationFindings'
)
