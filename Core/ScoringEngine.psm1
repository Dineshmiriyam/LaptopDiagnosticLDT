#Requires -Version 5.1
<#
.SYNOPSIS
    LDT ScoringEngine -- Weighted System Health Score Calculator

.DESCRIPTION
    Computes a deterministic, weighted health score (0-100) for an LDT session.
    Scores are reproducible given the same inputs and config-driven weights.

    Score Architecture:
      - Each diagnostic category contributes a weighted sub-score
      - Category weights sourced from config.json (9 categories, sum = 100)
      - Finding severity multipliers apply penalty within each category
      - Hard-stop active applies a 10-point penalty
      - Final score is normalized to 0-100

    Score Bands:
      90-100  : EXCELLENT   -- System is healthy
      75-89   : GOOD        -- Minor issues, no immediate action needed
      60-74   : FAIR        -- Degraded, schedule maintenance
      40-59   : POOR        -- Multiple failures, prioritize repair
      0-39    : CRITICAL    -- Immediate intervention required

    Output is suitable for trend tracking (stored per-session in TrendStore).

.NOTES
    Version : 7.0.0
    Platform: PowerShell 5.1+
    Ported  : From WinDRE v2.1.0 ScoringEngine with LDT adaptations
#>

Set-StrictMode -Version Latest

# Default module weights matching LDT's 9 diagnostic categories (sum = 100)
$script:_DefaultWeights = @{
    'Hardware'    = 20
    'OS/Boot'     = 18
    'Driver'      = 15
    'Security'    = 15
    'Network'     = 10
    'Performance' = 10
    'TPM'         =  5
    'Display'     =  5
    'Identity'    =  2
}

# Severity penalty multipliers -- supports both LDT (H1-H3/S1-S4) and WinDRE naming
$script:_SeverityPenalties = @{
    # WinDRE-style names
    'CRITICAL' = 1.0
    'ERROR'    = 0.7
    'WARN'     = 0.3
    'OK'       = 0.0
    'INFO'     = 0.0
    # LDT-style severity codes
    'H3'       = 1.0     # Hardware Critical
    'H2'       = 0.7     # Hardware Error
    'H1'       = 0.3     # Hardware Warning
    'S3'       = 0.7     # Software Error
    'S2'       = 0.3     # Software Warning
    'S1'       = 0.0     # Software Info
    'S4'       = 0.0     # Software Info
}

# Status factors applied to module weight
$script:_StatusFactors = @{
    'PASS'            = 1.0     # Full score retained
    'REPAIRED'        = 0.85    # Repaired -- slight deduction (was broken)
    'PARTIAL'         = 0.50    # Partial fix -- half score
    'DIAGNOSTIC_ONLY' = 0.70    # Diagnostic only -- conservative score
    'ESCALATED'       = 0.20    # Escalated hardware -- serious deduction
    'FAILED'          = 0.0     # Module failure -- zero for this category
    'UNKNOWN'         = 0.50    # Unknown -- conservative
}

#region -- Public Functions

function Invoke-SystemScoring {
    <#
    .SYNOPSIS
        Computes the health score for a session. Returns a structured score object.

    .PARAMETER ModuleResults
        Array of module result objects from ConvertTo-ModuleResults (LDT-EngineAdapter).
        Each has: moduleName, status, findings (array with component/severity/status/weight/details).

    .PARAMETER GuardStatus
        Output from Get-GuardStatus, or $null if GuardEngine not active.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject[]] $ModuleResults,
        [Parameter(Mandatory)] [string]           $SessionId,
        [PSCustomObject] $Config      = $null,
        [PSCustomObject] $GuardStatus = $null
    )

    Write-EngineLog -SessionId $SessionId -Level 'INFO' -Source 'ScoringEngine' `
        -Message "Computing system health score"

    $weights      = Get-ModuleWeights -Config $Config
    $moduleScores = @()
    $totalWeight  = ($weights.Values | Measure-Object -Sum).Sum

    foreach ($modResult in $ModuleResults) {
        $modName   = $modResult.moduleName
        $modWeight = if ($weights.ContainsKey($modName)) { $weights[$modName] } else { 2 }

        # Base factor from module status
        $statusFactor = if ($script:_StatusFactors.ContainsKey($modResult.status)) {
            $script:_StatusFactors[$modResult.status]
        } else { 0.5 }

        # Additional finding-level penalty within the module
        $findingPenalty = 0.0
        if ($modResult.findings -and $modResult.findings.Count -gt 0) {
            $totalFindings = $modResult.findings.Count
            $penaltySum    = 0.0
            foreach ($f in $modResult.findings) {
                $sev = if ($f.severity) { $f.severity } else { 'INFO' }
                $sevPenalty = if ($script:_SeverityPenalties.ContainsKey($sev)) {
                    $script:_SeverityPenalties[$sev]
                } else { 0.0 }
                $penaltySum += $sevPenalty
            }
            # Normalize: average penalty per finding, cap at 0.4 additional deduction
            $findingPenalty = [Math]::Min(($penaltySum / $totalFindings) * 0.4, 0.4)
        }

        $effectiveFactor = [Math]::Max(0.0, $statusFactor - $findingPenalty)
        $moduleScore     = $modWeight * $effectiveFactor

        $moduleScores += [PSCustomObject]@{
            module          = $modName
            weight          = $modWeight
            status          = $modResult.status
            statusFactor    = [Math]::Round($statusFactor, 3)
            findingPenalty  = [Math]::Round($findingPenalty, 3)
            effectiveFactor = [Math]::Round($effectiveFactor, 3)
            rawScore        = [Math]::Round($moduleScore, 2)
            maxScore        = $modWeight
        }
    }

    # Guard engine penalty
    $guardPenalty = 0
    if ($GuardStatus -and $GuardStatus.hardStopTriggered) {
        $guardPenalty = 10   # Hard stop always deducts 10 points
    }

    # Compute raw total
    $rawTotal    = ($moduleScores | Measure-Object -Property rawScore -Sum).Sum
    $maxPossible = ($moduleScores | Measure-Object -Property maxScore -Sum).Sum
    if ($maxPossible -eq 0) { $maxPossible = $totalWeight }

    $normalizedScore = [Math]::Round(($rawTotal / $maxPossible) * 100 - $guardPenalty, 1)
    $finalScore      = [Math]::Max(0, [Math]::Min(100, $normalizedScore))

    $band = Get-ScoreBand -Score $finalScore

    $scoreResult = [PSCustomObject]@{
        sessionId    = $SessionId
        timestamp    = Get-Date -Format 'o'
        finalScore   = $finalScore
        band         = $band.Label
        bandColor    = $band.Color
        guardPenalty = $guardPenalty
        moduleScores = $moduleScores
        computation  = [PSCustomObject]@{
            rawTotal                = [Math]::Round($rawTotal, 2)
            maxPossible             = [Math]::Round($maxPossible, 2)
            normalizedBeforePenalty = [Math]::Round($normalizedScore + $guardPenalty, 1)
        }
        recommendation = $band.Recommendation
    }

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'ScoringEngine' `
        -Message "Health score computed: $finalScore ($($band.Label))" `
        -Data @{
            score        = $finalScore
            band         = $band.Label
            guardPenalty = $guardPenalty
            moduleCount  = $moduleScores.Count
        }

    return $scoreResult
}

#endregion

#region -- Private Helpers

function Get-ModuleWeights {
    param([PSCustomObject] $Config)

    # Try config-sourced weights first (engine.scoring.moduleWeights in config.json)
    if ($Config -and $Config.PSObject.Properties['engine']) {
        if ($Config.engine.PSObject.Properties['scoring'] -and $Config.engine.scoring.PSObject.Properties['moduleWeights']) {
            $configWeights = @{}
            $Config.engine.scoring.moduleWeights.PSObject.Properties | ForEach-Object {
                $configWeights[$_.Name] = [int]$_.Value
            }
            if ($configWeights.Count -gt 0) { return $configWeights }
        }
    }
    return $script:_DefaultWeights
}

function Get-ScoreBand {
    param([double] $Score)

    if ($Score -ge 90) {
        return @{ Label = 'EXCELLENT'; Color = '#22c55e'; Recommendation = 'System is healthy. Continue standard monitoring schedule.' }
    } elseif ($Score -ge 75) {
        return @{ Label = 'GOOD';      Color = '#84cc16'; Recommendation = 'Minor issues detected. Schedule maintenance within 30 days.' }
    } elseif ($Score -ge 60) {
        return @{ Label = 'FAIR';      Color = '#f59e0b'; Recommendation = 'System is degraded. Schedule maintenance within 7 days.' }
    } elseif ($Score -ge 40) {
        return @{ Label = 'POOR';      Color = '#f97316'; Recommendation = 'Multiple failures detected. Prioritize repair within 48 hours.' }
    } else {
        return @{ Label = 'CRITICAL';  Color = '#ef4444'; Recommendation = 'IMMEDIATE intervention required. Escalate to Tier 2/3 support.' }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-SystemScoring'
)
