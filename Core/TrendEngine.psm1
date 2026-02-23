#Requires -Version 5.1
<#
.SYNOPSIS
    LDT TrendEngine -- Historical Session Trend Storage and Drift Analysis

.DESCRIPTION
    Maintains a machine-local TrendStore (JSON) that accumulates per-session
    health scores and key metrics over time.

    Enables:
      - Score trajectory visualization (improving / stable / declining)
      - Recurring issue identification (same module failing repeatedly)
      - MTTR (Mean Time To Repair) tracking per issue category
      - Threshold-based alert if score declines across consecutive sessions
      - Compliance evidence retention (N sessions of health history)

    TrendStore Schema (per machine, USB-relative TrendStore/ directory):
    {
        "computername"  : "...",
        "firstSession"  : "ISO8601",
        "lastSession"   : "ISO8601",
        "sessionCount"  : int,
        "sessions"      : [ ... ],
        "trends"        : { scoreTrajectory, avgScore, recurringIssues, ... }
    }

.NOTES
    Version : 7.0.0
    Platform: PowerShell 5.1+
    Ported  : From WinDRE v2.1.0 TrendEngine with LDT adaptations
#>

Set-StrictMode -Version Latest

$script:_MaxSessions           = 90   # Rolling window -- configurable via config
$script:_DeclineAlertThreshold = 10   # Score drop over last 3 sessions triggers alert

#region -- Public Functions

function Add-TrendEntry {
    <#
    .SYNOPSIS
        Records a new session's results into the TrendStore.
        Called at end of every Smart Diagnosis Engine run.

    .PARAMETER ModuleResults
        Array from ConvertTo-ModuleResults (LDT-EngineAdapter).

    .PARAMETER ScoreResult
        Output from Invoke-SystemScoring.

    .PARAMETER PlatformRoot
        USB root path (e.g., E:\LDT-v9.0) for resolving TrendStore directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]          $SessionId,
        [Parameter(Mandatory)] [hashtable]       $DiagState,
        [Parameter(Mandatory)] [PSCustomObject[]] $ModuleResults,
        [Parameter(Mandatory)] [PSCustomObject]  $ScoreResult,
        [Parameter(Mandatory)] [string]          $PlatformRoot,
        [PSCustomObject] $GuardStatus = $null,
        [PSCustomObject] $Config      = $null
    )

    $storeDir  = Get-TrendStoreDir -Config $Config -PlatformRoot $PlatformRoot
    $storePath = Join-Path $storeDir "$($env:COMPUTERNAME)_trend.json"

    # Load existing trend store or create new
    $store = Load-TrendStore -Path $storePath

    # Build module status map from module results
    $moduleStatuses = @{}
    foreach ($m in $ModuleResults) {
        $moduleStatuses[$m.moduleName] = $m.status
    }

    # Derive counts from DiagState
    $findingsCount = if ($DiagState.Findings) { $DiagState.Findings.Count } else { 0 }
    $repairsCount  = if ($DiagState.FixesApplied) { $DiagState.FixesApplied.Count } else { 0 }
    $escalationCount = 0
    if ($DiagState.Findings) {
        $escalationCount = @($DiagState.Findings | Where-Object { $_.Status -eq 'Escalation' -or $_.Severity -match '^H' }).Count
    }

    # v7.2: Determine escalation level from ClassificationEngine if available
    $escalationLevel = 'None'
    if ($DiagState.ContainsKey('ClassificationReport') -and $DiagState['ClassificationReport']) {
        $escalationLevel = $DiagState['ClassificationReport'].escalation_level
    }
    elseif ($DiagState.ContainsKey('Ranking') -and $DiagState['Ranking']) {
        $escalationLevel = $DiagState['Ranking'].EscalationLevel
    }

    $entry = [ordered]@{
        sessionId        = $SessionId
        timestamp        = Get-Date -Format 'o'
        mode             = if ($DiagState.OEMMode) { 'OEM_VALIDATION' } else { 'DIAGNOSTIC' }
        score            = $ScoreResult.finalScore
        band             = $ScoreResult.band
        moduleStatuses   = $moduleStatuses
        hardStop         = if ($GuardStatus) { $GuardStatus.hardStopTriggered } else { $false }
        escalations      = $escalationCount
        repairs          = $repairsCount
        findings         = $findingsCount
        escalation_level = $escalationLevel
    }

    $store.sessions = @($store.sessions) + @($entry)

    # Enforce rolling window
    $maxSessions = $script:_MaxSessions
    if ($Config -and $Config.PSObject.Properties['engine'] -and $Config.engine.PSObject.Properties['trendRetentionSessions']) {
        $maxSessions = [int]$Config.engine.trendRetentionSessions
    }

    if ($store.sessions.Count -gt $maxSessions) {
        $store.sessions = @($store.sessions | Select-Object -Last $maxSessions)
    }

    $store.lastSession  = Get-Date -Format 'o'
    $store.sessionCount = $store.sessions.Count

    # Recompute trends
    $store.trends = Compute-Trends -Sessions $store.sessions

    # Write back
    $store | ConvertTo-Json -Depth 15 | Set-Content $storePath -Encoding UTF8

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'TrendEngine' `
        -Message "Trend entry recorded" `
        -Data @{
            score         = $entry.score
            band          = $entry.band
            trajectory    = $store.trends.scoreTrajectory
            totalSessions = $store.sessionCount
        }

    return $store.trends
}

function Get-TrendReport {
    <#
    .SYNOPSIS
        Returns the current trend analysis for this machine.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $PlatformRoot,
        [PSCustomObject] $Config = $null
    )

    $storeDir  = Get-TrendStoreDir -Config $Config -PlatformRoot $PlatformRoot
    $storePath = Join-Path $storeDir "$($env:COMPUTERNAME)_trend.json"

    if (-not (Test-Path $storePath)) {
        return [PSCustomObject]@{
            computername = $env:COMPUTERNAME
            sessionCount = 0
            trends       = $null
            message      = "No trend data available -- first session or store not found"
        }
    }

    return Get-Content $storePath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-TrendAlert {
    <#
    .SYNOPSIS
        Returns alert objects if trend conditions warrant notification.
        Used by report generation and compliance export.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $TrendStore,
        [Parameter(Mandatory)] [string]         $SessionId
    )

    $alerts = @()

    if (-not $TrendStore.sessions -or $TrendStore.sessions.Count -lt 3) {
        return $alerts  # Need at least 3 sessions for trend alerts
    }

    $lastThree = @($TrendStore.sessions | Select-Object -Last 3)
    $scores    = @($lastThree | ForEach-Object { [double]$_.score })

    # Declining score alert
    $decline = $scores[0] - $scores[-1]
    if ($decline -ge $script:_DeclineAlertThreshold) {
        $alerts += [PSCustomObject]@{
            type     = 'SCORE_DECLINING'
            severity = 'WARN'
            message  = "Health score has declined $([Math]::Round($decline,1)) points over last 3 sessions ($($scores[0]) -> $($scores[-1]))"
            data     = @{ from = $scores[0]; to = $scores[-1]; decline = $decline }
        }
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'TrendEngine' `
            -Message "TREND ALERT: Score declining -- $($scores[0]) -> $($scores[-1])"
    }

    # Recurring issues alert
    if ($TrendStore.trends -and $TrendStore.trends.recurringIssues -and $TrendStore.trends.recurringIssues.Count -gt 0) {
        $alerts += [PSCustomObject]@{
            type     = 'RECURRING_ISSUES'
            severity = 'WARN'
            message  = "Modules with recurring failures across sessions: $($TrendStore.trends.recurringIssues -join ', ')"
            data     = @{ modules = $TrendStore.trends.recurringIssues }
        }
    }

    # Hard stop in recent history
    $recentHardStops = @($TrendStore.sessions | Select-Object -Last 5 | Where-Object { $_.hardStop }).Count
    if ($recentHardStops -gt 0) {
        $alerts += [PSCustomObject]@{
            type     = 'RECENT_HARD_STOPS'
            severity = 'ERROR'
            message  = "$recentHardStops hard-stop event(s) in last 5 sessions -- recurring critical condition"
            data     = @{ count = $recentHardStops }
        }
    }

    return $alerts
}

#endregion

#region -- Private Functions

function Load-TrendStore {
    param([string] $Path)

    if (Test-Path $Path) {
        try {
            return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch { }
    }

    # Create new store -- ensure directory exists
    $parentDir = Split-Path $Path -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    return [PSCustomObject]@{
        computername = $env:COMPUTERNAME
        firstSession = Get-Date -Format 'o'
        lastSession  = $null
        sessionCount = 0
        sessions     = @()
        trends       = @{}
    }
}

function Compute-Trends {
    param([array] $Sessions)

    if ($Sessions.Count -eq 0) {
        return [PSCustomObject]@{
            scoreTrajectory = 'UNKNOWN'; avgScore = 0; minScore = 0; maxScore = 0
            sessionCount = 0; recurringIssues = @(); sessionsSinceLastCritical = 0
            mttrByModule = @{}; computedAt = Get-Date -Format 'o'
        }
    }

    $scores = @($Sessions | ForEach-Object { [double]$_.score })
    $avg    = [Math]::Round(($scores | Measure-Object -Average).Average, 1)
    $min    = [Math]::Round(($scores | Measure-Object -Minimum).Minimum, 1)
    $max    = [Math]::Round(($scores | Measure-Object -Maximum).Maximum, 1)

    # Trajectory: compare average of first half vs second half
    $trajectory = 'STABLE'
    if ($Sessions.Count -ge 4) {
        $half    = [Math]::Floor($Sessions.Count / 2)
        $firstH  = ($Sessions | Select-Object -First $half | ForEach-Object { [double]$_.score } | Measure-Object -Average).Average
        $secondH = ($Sessions | Select-Object -Last $half  | ForEach-Object { [double]$_.score } | Measure-Object -Average).Average
        $delta   = $secondH - $firstH
        $trajectory = if ($delta -gt 5) { 'IMPROVING' } elseif ($delta -lt -5) { 'DECLINING' } else { 'STABLE' }
    }

    # Recurring issues: modules that failed in >50% of last 10 sessions
    $recentSessions = @($Sessions | Select-Object -Last 10)
    $allModules = @()
    foreach ($sess in $recentSessions) {
        if ($sess.moduleStatuses) {
            # Handle both hashtable (new entry) and PSCustomObject (from JSON)
            $names = if ($sess.moduleStatuses -is [hashtable]) {
                $sess.moduleStatuses.Keys
            } else {
                $sess.moduleStatuses.PSObject.Properties.Name
            }
            foreach ($n in $names) {
                if ($allModules -notcontains $n) { $allModules += $n }
            }
        }
    }

    $recurringIssues = @()
    foreach ($mod in $allModules) {
        $failCount = @($recentSessions | Where-Object {
            $status = $null
            if ($_.moduleStatuses -is [hashtable]) {
                $status = $_.moduleStatuses[$mod]
            } elseif ($_.moduleStatuses) {
                $status = $_.moduleStatuses.$mod
            }
            $status -in @('FAILED','ESCALATED','PARTIAL')
        }).Count
        if ($failCount -gt ($recentSessions.Count * 0.5)) {
            $recurringIssues += $mod
        }
    }

    # Sessions since last critical
    $lastCriticalIdx = -1
    for ($i = $Sessions.Count - 1; $i -ge 0; $i--) {
        if ($Sessions[$i].band -in @('CRITICAL','POOR')) {
            $lastCriticalIdx = $i
            break
        }
    }
    $sessionsSinceLastCritical = if ($lastCriticalIdx -eq -1) { $Sessions.Count } else { $Sessions.Count - 1 - $lastCriticalIdx }

    # MTTR approximation: sessions between a failure and subsequent PASS for same module
    $mttrData = @{}
    foreach ($mod in $allModules) {
        $failSessions   = @()
        $repairSessions = @()
        for ($i = 0; $i -lt $Sessions.Count; $i++) {
            $status = $null
            if ($Sessions[$i].moduleStatuses -is [hashtable]) {
                $status = $Sessions[$i].moduleStatuses[$mod]
            } elseif ($Sessions[$i].moduleStatuses) {
                $status = $Sessions[$i].moduleStatuses.$mod
            }
            if ($status -in @('FAILED','ESCALATED')) { $failSessions += $i }
            if ($status -in @('PASS','REPAIRED'))    { $repairSessions += $i }
        }
        if ($failSessions.Count -gt 0 -and $repairSessions.Count -gt 0) {
            $firstFail   = $failSessions[0]
            $firstRepair = $repairSessions | Where-Object { $_ -gt $firstFail } | Select-Object -First 1
            if ($null -ne $firstRepair) {
                $mttrData[$mod] = $firstRepair - $firstFail
            }
        }
    }

    return [PSCustomObject]@{
        scoreTrajectory           = $trajectory
        avgScore                  = $avg
        minScore                  = $min
        maxScore                  = $max
        sessionCount              = $Sessions.Count
        recurringIssues           = $recurringIssues
        sessionsSinceLastCritical = $sessionsSinceLastCritical
        mttrByModule              = $mttrData
        computedAt                = Get-Date -Format 'o'
    }
}

function Get-TrendStoreDir {
    param(
        [PSCustomObject] $Config,
        [string] $PlatformRoot
    )

    # Config paths.trendStore is relative to platform root
    if ($Config -and $Config.PSObject.Properties['paths'] -and $Config.paths.PSObject.Properties['trendStore']) {
        $configured = $Config.paths.trendStore
        if ([System.IO.Path]::IsPathRooted($configured)) {
            return $configured
        }
        return Join-Path $PlatformRoot $configured
    }

    # Default: TrendStore/ relative to platform root
    return Join-Path $PlatformRoot 'TrendStore'
}

#endregion

Export-ModuleMember -Function @(
    'Add-TrendEntry',
    'Get-TrendReport',
    'Get-TrendAlert'
)
