#Requires -Version 5.1
<#
.SYNOPSIS
    LDT GovernanceEngine -- Enterprise Governance Control Authority

.DESCRIPTION
    The GovernanceEngine provides enterprise-grade governance controls for the
    LDT diagnostic platform. It enforces policy boundaries, manages execution
    state, controls operational modes, and governs exception handling across
    all diagnostic phases.

    Governance Functions:
      1. Policy Engine            -- Profile-based policy enforcement (Strict/Balanced/Aggressive)
      2. Transaction Control      -- Checkpoint save/restore for resumable execution
      3. Execution Modes          -- AuditOnly, Diagnostic, Remediation, Full, ClassifyOnly
      4. Exception Governance     -- Structured exception logging with severity thresholds
      5. Retry Governance         -- Exponential backoff with jitter and policy integration
      6. Business Impact Assessment -- Weighted impact scoring by category/severity/classification

.NOTES
    Version : 9.0.0
    Platform: PowerShell 5.1+
#>

Set-StrictMode -Version Latest

$script:_OperationalBoundary = [ordered]@{
    platformName    = 'LDT -- Laptop Diagnostic Toolkit'
    version         = '9.0.0'
    classification  = 'INTERNAL -- FIELD SERVICE TOOL'
}

# Module-scoped state variables
$script:_PolicyProfile   = $null
$script:_ExecutionMode   = 'Full'
$script:_ExceptionLog    = [System.Collections.ArrayList]::new()
$script:_TransactionState = $null

#region -- Policy Engine Functions

function Initialize-PolicyEngine {
    param(
        [string]$ConfigJsonPath,
        [string]$ProfileName = 'Balanced'
    )
    # Read config.json, extract governance.policies.$ProfileName
    # If file missing or profile missing, default to Balanced hardcoded defaults
    # Store in $script:_PolicyProfile
    # Return the profile hashtable

    $defaultProfiles = @{
        'Strict'     = @{ maxAutoFixLevel = 'L1'; requireWhitelist = $true;  retryEnabled = $false; abortOnCritical = $true  }
        'Balanced'   = @{ maxAutoFixLevel = 'L1'; requireWhitelist = $false; retryEnabled = $true;  abortOnCritical = $true  }
        'Aggressive' = @{ maxAutoFixLevel = 'L2'; requireWhitelist = $false; retryEnabled = $true;  abortOnCritical = $false }
    }

    try {
        if (Test-Path $ConfigJsonPath) {
            $config = Get-Content $ConfigJsonPath -Raw | ConvertFrom-Json
            if ($config.governance -and $config.governance.policies) {
                $profileObj = $config.governance.policies.$ProfileName
                if ($profileObj) {
                    $script:_PolicyProfile = @{
                        Name             = $ProfileName
                        maxAutoFixLevel  = if ($profileObj.maxAutoFixLevel) { $profileObj.maxAutoFixLevel } else { 'L1' }
                        requireWhitelist = [bool]$profileObj.requireWhitelist
                        retryEnabled     = [bool]$profileObj.retryEnabled
                        abortOnCritical  = [bool]$profileObj.abortOnCritical
                    }
                    return $script:_PolicyProfile
                }
            }
        }
    } catch {
        # Graceful degradation -- use defaults
    }

    # Fallback to hardcoded default
    $profile = $defaultProfiles[$ProfileName]
    if (-not $profile) { $profile = $defaultProfiles['Balanced'] }
    $script:_PolicyProfile = @{ Name = $ProfileName } + $profile
    return $script:_PolicyProfile
}

function Get-PolicyProfile {
    if ($script:_PolicyProfile) {
        return $script:_PolicyProfile
    }
    # Return default if not initialized
    return @{
        Name             = 'Balanced'
        maxAutoFixLevel  = 'L1'
        requireWhitelist = $false
        retryEnabled     = $true
        abortOnCritical  = $true
    }
}

function Test-PolicyGate {
    param(
        [Parameter(Mandatory)][string]$ActionId,
        [string]$Category = 'Unknown',
        [string]$EscalationLevel = 'L1'
    )
    # Check if the action is permitted under current policy profile
    $profile = Get-PolicyProfile

    # Check escalation level against policy max
    $levelMap = @{ 'L1' = 1; 'L2' = 2; 'L3' = 3 }
    $actionLevel = if ($levelMap.ContainsKey($EscalationLevel)) { $levelMap[$EscalationLevel] } else { 1 }
    $maxLevel    = if ($levelMap.ContainsKey($profile.maxAutoFixLevel)) { $levelMap[$profile.maxAutoFixLevel] } else { 1 }

    $result = @{
        ActionId      = $ActionId
        Permitted     = $true
        Reason        = 'Policy gate passed'
        PolicyProfile = $profile.Name
    }

    if ($actionLevel -gt $maxLevel) {
        $result.Permitted = $false
        $result.Reason    = "Action level $EscalationLevel exceeds policy maximum $($profile.maxAutoFixLevel)"
    }

    return $result
}

#endregion

#region -- Transaction Control Functions

function Save-ExecutionState {
    param(
        [Parameter(Mandatory)][string]$SessionGUID,
        [Parameter(Mandatory)][int]$CurrentPhase,
        [Parameter(Mandatory)][string]$OutputDir,
        [hashtable]$StateSnapshot = @{}
    )
    $statePath = Join-Path $OutputDir 'ExecutionState.json'
    $state = [ordered]@{
        sessionGUID  = $SessionGUID
        currentPhase = $CurrentPhase
        timestamp    = (Get-Date).ToString('o')
        machineName  = $env:COMPUTERNAME
        status       = 'IN_PROGRESS'
        phaseLabel   = "Phase $CurrentPhase"
        snapshot     = $StateSnapshot
    }
    $script:_TransactionState = $state
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8 -Force
    } catch {
        # Non-fatal -- checkpoint write failure should not halt diagnostics
    }
    return $state
}

function Restore-ExecutionState {
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [string]$ExpectedSessionGUID = ''
    )
    $statePath = Join-Path $OutputDir 'ExecutionState.json'
    if (-not (Test-Path $statePath)) { return $null }

    try {
        $raw   = Get-Content $statePath -Raw -Encoding UTF8
        $state = $raw | ConvertFrom-Json

        # Check age -- discard if older than 24 hours
        $stateTime = [datetime]::Parse($state.timestamp)
        $ageHours  = ((Get-Date) - $stateTime).TotalHours
        if ($ageHours -gt 24) {
            Remove-Item $statePath -Force -ErrorAction SilentlyContinue
            return $null
        }

        # Check session GUID match if provided
        if ($ExpectedSessionGUID -and $state.sessionGUID -ne $ExpectedSessionGUID) {
            return $null
        }

        # Only return if status is IN_PROGRESS (not already completed)
        if ($state.status -ne 'IN_PROGRESS') { return $null }

        return @{
            SessionGUID  = $state.sessionGUID
            CurrentPhase = [int]$state.currentPhase
            Timestamp    = $state.timestamp
            MachineName  = $state.machineName
            Status       = $state.status
            Snapshot     = $state.snapshot
        }
    } catch {
        return $null
    }
}

function Clear-ExecutionState {
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [string]$FinalStatus = 'COMPLETED'
    )
    $statePath = Join-Path $OutputDir 'ExecutionState.json'
    if (Test-Path $statePath) {
        try {
            $raw   = Get-Content $statePath -Raw -Encoding UTF8
            $state = $raw | ConvertFrom-Json
            # Update status to completed before removing
            $finalState = [ordered]@{
                sessionGUID  = $state.sessionGUID
                currentPhase = $state.currentPhase
                timestamp    = (Get-Date).ToString('o')
                status       = $FinalStatus
                completedAt  = (Get-Date).ToString('o')
            }
            $finalState | ConvertTo-Json -Depth 3 | Set-Content -Path $statePath -Encoding UTF8 -Force
        } catch {
            # Best effort -- remove on failure
            Remove-Item $statePath -Force -ErrorAction SilentlyContinue
        }
    }
    $script:_TransactionState = $null
}

#endregion

#region -- Execution Mode Functions

function Get-ExecutionMode {
    param(
        [string]$RequestedMode = '',
        [string]$ConfigJsonPath = ''
    )
    $validModes = @('AuditOnly', 'Diagnostic', 'Remediation', 'Full', 'ClassifyOnly')

    if ($RequestedMode -and $validModes -contains $RequestedMode) {
        $script:_ExecutionMode = $RequestedMode
        return $RequestedMode
    }

    # Try to read from config.json
    if ($ConfigJsonPath -and (Test-Path $ConfigJsonPath)) {
        try {
            $config = Get-Content $ConfigJsonPath -Raw | ConvertFrom-Json
            if ($config.governance -and $config.governance.executionModes) {
                # Config has modes defined -- validate requested mode exists
                if ($RequestedMode -and $config.governance.executionModes.$RequestedMode) {
                    $script:_ExecutionMode = $RequestedMode
                    return $RequestedMode
                }
            }
        } catch { }
    }

    # Default to Full
    $script:_ExecutionMode = 'Full'
    return 'Full'
}

function Test-ModeAllowsPhase {
    param(
        [Parameter(Mandatory)][int]$Phase,
        [string]$ConfigJsonPath = ''
    )
    $mode = $script:_ExecutionMode
    if (-not $mode) { $mode = 'Full' }

    # Built-in mode definitions (fallback if config.json unavailable)
    $modePhases = @{
        'AuditOnly'    = @(0,1,2,3,4,5,8)
        'Diagnostic'   = @(0,1,2,3,4,5,8)
        'Remediation'  = @(0,6,7,8)
        'Full'         = @(0,1,2,3,4,5,6,7,8)
        'ClassifyOnly' = @(0,1,2,3,4,5,8)
    }

    # Try config.json override
    if ($ConfigJsonPath -and (Test-Path $ConfigJsonPath)) {
        try {
            $config = Get-Content $ConfigJsonPath -Raw | ConvertFrom-Json
            if ($config.governance.executionModes.$mode) {
                $configPhases = @($config.governance.executionModes.$mode.phases)
                return ($configPhases -contains $Phase)
            }
        } catch { }
    }

    # Fallback to built-in
    $phases = $modePhases[$mode]
    if (-not $phases) { $phases = $modePhases['Full'] }
    return ($phases -contains $Phase)
}

function Test-ModeAllowsRemediation {
    $mode = $script:_ExecutionMode
    if (-not $mode) { $mode = 'Full' }
    $remediationModes = @('Remediation', 'Full')
    return ($remediationModes -contains $mode)
}

function Test-ModeAllowsClassification {
    $mode = $script:_ExecutionMode
    if (-not $mode) { $mode = 'Full' }
    $noClassification = @('AuditOnly')
    return ($noClassification -notcontains $mode)
}

#endregion

#region -- Exception Governance Functions

function Write-GovernedException {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Warning','Error','Critical')]
        [string]$Severity = 'Warning',
        [string]$SourcePhase = '',
        [string]$SourceFunction = '',
        [string]$Category = '',
        [System.Management.Automation.ErrorRecord]$ErrorRecord = $null
    )
    $entry = [ordered]@{
        Timestamp      = (Get-Date).ToString('o')
        Severity       = $Severity
        Message        = $Message
        SourcePhase    = $SourcePhase
        SourceFunction = $SourceFunction
        Category       = $Category
        ErrorType      = ''
        StackTrace     = ''
    }
    if ($ErrorRecord) {
        $entry.ErrorType  = $ErrorRecord.Exception.GetType().FullName
        $entry.StackTrace = if ($ErrorRecord.ScriptStackTrace) { $ErrorRecord.ScriptStackTrace } else { '' }
    }
    $null = $script:_ExceptionLog.Add($entry)
    return $entry
}

function Get-ExceptionSummary {
    $summary = [ordered]@{
        TotalExceptions = $script:_ExceptionLog.Count
        BySeverity      = [ordered]@{
            Warning  = 0
            Error    = 0
            Critical = 0
        }
        Entries     = @($script:_ExceptionLog)
        GeneratedAt = (Get-Date).ToString('o')
    }
    foreach ($entry in $script:_ExceptionLog) {
        $sev = $entry.Severity
        if ($summary.BySeverity.Contains($sev)) {
            $summary.BySeverity[$sev]++
        }
    }
    return $summary
}

function Test-ExceptionThreshold {
    param(
        [int]$CriticalMax = 3,
        [int]$ErrorMax = 10,
        [string]$ConfigIniPath = ''
    )
    # Read thresholds from config.ini if available
    if ($ConfigIniPath -and (Test-Path $ConfigIniPath)) {
        try {
            $content = Get-Content $ConfigIniPath
            foreach ($line in $content) {
                if ($line -match '^\s*CriticalAbortThreshold\s*=\s*(\d+)') { $CriticalMax = [int]$Matches[1] }
                if ($line -match '^\s*ExceptionAbortThreshold\s*=\s*(\d+)') { $ErrorMax = [int]$Matches[1] }
            }
        } catch { }
    }

    $summary = Get-ExceptionSummary
    $result = [ordered]@{
        ShouldAbort   = $false
        Reason        = 'Within thresholds'
        CriticalCount = $summary.BySeverity.Critical
        ErrorCount    = $summary.BySeverity.Error
        CriticalMax   = $CriticalMax
        ErrorMax      = $ErrorMax
    }

    if ($summary.BySeverity.Critical -ge $CriticalMax) {
        $result.ShouldAbort = $true
        $result.Reason      = "Critical exceptions ($($summary.BySeverity.Critical)) reached abort threshold ($CriticalMax)"
    }
    elseif ($summary.BySeverity.Error -ge $ErrorMax) {
        $result.ShouldAbort = $true
        $result.Reason      = "Error exceptions ($($summary.BySeverity.Error)) reached abort threshold ($ErrorMax)"
    }

    return $result
}

#endregion

#region -- Retry Governance Function

function Invoke-GovernedRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$ActionName = 'UnnamedAction',
        [int]$MaxRetries = 3,
        [int]$BackoffBaseMs = 1000,
        [int]$BackoffMultiplier = 2,
        [int]$MaxBackoffMs = 8000,
        [string]$ConfigIniPath = ''
    )
    # Override from config.ini if available
    if ($ConfigIniPath -and (Test-Path $ConfigIniPath)) {
        try {
            $content = Get-Content $ConfigIniPath
            $inSection = $false
            foreach ($line in $content) {
                if ($line -match '^\s*\[RetryPolicy\]') { $inSection = $true; continue }
                if ($line -match '^\s*\[') { $inSection = $false; continue }
                if ($inSection) {
                    if ($line -match '^\s*MaxRetries\s*=\s*(\d+)') { $MaxRetries = [int]$Matches[1] }
                    if ($line -match '^\s*BackoffBaseMs\s*=\s*(\d+)') { $BackoffBaseMs = [int]$Matches[1] }
                    if ($line -match '^\s*BackoffMultiplier\s*=\s*(\d+)') { $BackoffMultiplier = [int]$Matches[1] }
                    if ($line -match '^\s*MaxBackoffMs\s*=\s*(\d+)') { $MaxBackoffMs = [int]$Matches[1] }
                }
            }
        } catch { }
    }

    # Check if policy allows retry
    $profile = Get-PolicyProfile
    if (-not $profile.retryEnabled) {
        # Execute once without retry
        $result = @{
            Success    = $false
            Attempts   = 1
            LastError  = ''
            Duration   = 0
            ActionName = $ActionName
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = & $Action
            $result.Success = $true
        } catch {
            $result.LastError = $_.Exception.Message
            Write-GovernedException -Message "Action '$ActionName' failed (retry disabled by policy)" -Severity 'Warning' -SourceFunction 'Invoke-GovernedRetry' -ErrorRecord $_
        }
        $sw.Stop()
        $result.Duration = $sw.ElapsedMilliseconds
        return $result
    }

    $result = @{
        Success    = $false
        Attempts   = 0
        LastError  = ''
        Duration   = 0
        ActionName = $ActionName
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $currentBackoff = $BackoffBaseMs

    for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
        $result.Attempts = $attempt
        try {
            $null = & $Action
            $result.Success = $true
            break
        } catch {
            $result.LastError = $_.Exception.Message
            if ($attempt -le $MaxRetries) {
                # Add jitter (0-25% of current backoff)
                $jitter  = Get-Random -Minimum 0 -Maximum ([math]::Max(1, [int]($currentBackoff * 0.25)))
                $sleepMs = [math]::Min($currentBackoff + $jitter, $MaxBackoffMs)
                Start-Sleep -Milliseconds $sleepMs
                $currentBackoff = [math]::Min($currentBackoff * $BackoffMultiplier, $MaxBackoffMs)
            } else {
                Write-GovernedException -Message "Action '$ActionName' failed after $attempt attempts: $($_.Exception.Message)" -Severity 'Error' -SourceFunction 'Invoke-GovernedRetry' -ErrorRecord $_
            }
        }
    }
    $sw.Stop()
    $result.Duration = $sw.ElapsedMilliseconds
    return $result
}

#endregion

#region -- Business Impact Assessment Function

function Get-BusinessImpactWeight {
    param(
        [string]$Category = 'Unknown',
        [string]$Severity = 'Medium',
        [string]$Classification = 'L1'
    )
    # Base impact weights by category (higher = more business-critical)
    $categoryImpact = @{
        'Hardware'    = 1.0
        'OS/Boot'     = 0.9
        'Security'    = 0.85
        'Driver'      = 0.7
        'Network'     = 0.65
        'Performance' = 0.5
        'TPM'         = 0.4
        'Display'     = 0.35
        'Identity'    = 0.2
        'Unknown'     = 0.3
    }

    # Severity multiplier
    $severityMultiplier = @{
        'Critical' = 2.0
        'High'     = 1.5
        'Medium'   = 1.0
        'Low'      = 0.5
    }

    # Classification multiplier
    $classMultiplier = @{
        'L3'    = 2.0
        'L2'    = 1.5
        'L1'    = 1.0
        'CLEAR' = 0.0
    }

    $catWeight = if ($categoryImpact.ContainsKey($Category)) { $categoryImpact[$Category] } else { 0.3 }
    $sevWeight = if ($severityMultiplier.ContainsKey($Severity)) { $severityMultiplier[$Severity] } else { 1.0 }
    $clsWeight = if ($classMultiplier.ContainsKey($Classification)) { $classMultiplier[$Classification] } else { 1.0 }

    $impact = [math]::Round($catWeight * $sevWeight * $clsWeight, 2)

    return @{
        Category                = $Category
        Severity                = $Severity
        Classification          = $Classification
        BusinessImpact          = $impact
        CategoryWeight          = $catWeight
        SeverityMultiplier      = $sevWeight
        ClassificationMultiplier = $clsWeight
    }
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-PolicyEngine',
    'Get-PolicyProfile',
    'Test-PolicyGate',
    'Save-ExecutionState',
    'Restore-ExecutionState',
    'Clear-ExecutionState',
    'Get-ExecutionMode',
    'Test-ModeAllowsPhase',
    'Test-ModeAllowsRemediation',
    'Test-ModeAllowsClassification',
    'Write-GovernedException',
    'Get-ExceptionSummary',
    'Test-ExceptionThreshold',
    'Invoke-GovernedRetry',
    'Get-BusinessImpactWeight'
)
