#Requires -Version 5.1
<#
.SYNOPSIS
    LDT FleetGovernance -- Fleet-Wide Governance Controls

.DESCRIPTION
    Provides fleet-level governance controls for LDT diagnostic operations.
    Designed for multi-machine oversight, policy enforcement, and KPI tracking.

    Governance Functions:
      1. Directory Tamper Detection   -- Validates file integrity against VersionManifest.json
      2. Whitelist Enforcement        -- Restricts remediation to approved action IDs
      3. Rollback Simulation          -- Validates rollback token and BeforeState data
      4. Fleet KPI Export             -- Aggregates session metrics across TrendStore
      5. Fleet Governance Summary     -- Consolidated governance health snapshot

.NOTES
    Version : 9.0.0
    Platform: PowerShell 5.1+
#>

Set-StrictMode -Version Latest

#region -- Operational Boundary Declaration (immutable platform truth)

$script:_OperationalBoundary = [ordered]@{
    platformName    = 'LDT -- Laptop Diagnostic Toolkit'
    version         = '9.0.0'
    classification  = 'INTERNAL -- FIELD SERVICE TOOL'

    canDo = @(
        'Detect directory tampering via manifest comparison'
        'Enforce remediation whitelist against approved action IDs'
        'Simulate rollback readiness from remediation ledger tokens'
        'Export fleet-wide KPIs from TrendStore session data'
        'Generate consolidated fleet governance summary'
        'Report missing or unexpected files in deployment directory'
        'Aggregate L1/L2/L3 fix rates and recurrence metrics'
    )

    cannotDo = @(
        'Modify or delete any files on disk'
        'Execute any remediation actions directly'
        'Communicate over the network or internet'
        'Alter Windows system configuration'
        'Override governance policy decisions'
        'Access credential stores or authentication data'
    )
}

#endregion

#region -- Directory Tamper Detection

function Test-DirectoryIntegrity {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$BasePath
    )
    # Read VersionManifest.json, get list of expected files from the "files" array
    # Scan actual directory for .ps1, .psm1, .json, .ini, .bat files
    # Report: missing files (in manifest but not on disk), unexpected files (on disk but not in manifest)

    $result = [ordered]@{
        Valid           = $true
        MissingFiles    = @()
        UnexpectedFiles = @()
        ExpectedCount   = 0
        ActualCount     = 0
        CheckedAt       = (Get-Date).ToString('o')
        Details         = @()
    }

    if (-not (Test-Path $ManifestPath)) {
        $result.Valid = $false
        $result.Details += "VersionManifest.json not found at: $ManifestPath"
        return $result
    }

    try {
        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        $expectedFiles = @()
        foreach ($f in $manifest.files) {
            $expectedFiles += $f.relativePath
        }
        $result.ExpectedCount = $expectedFiles.Count

        # Check for missing files
        foreach ($relPath in $expectedFiles) {
            $fullPath = Join-Path $BasePath $relPath
            if (-not (Test-Path $fullPath)) {
                $result.MissingFiles += $relPath
                $result.Details += "MISSING: $relPath"
            }
        }

        # Scan for unexpected .ps1/.psm1/.bat files in root and Core/
        $scanPaths = @(
            @{ Path = $BasePath; Pattern = '*.ps1' },
            @{ Path = $BasePath; Pattern = '*.bat' },
            @{ Path = (Join-Path $BasePath 'Core'); Pattern = '*.psm1' }
        )

        $actualFiles = @()
        foreach ($scan in $scanPaths) {
            if (Test-Path $scan.Path) {
                $found = Get-ChildItem -Path $scan.Path -Filter $scan.Pattern -File -ErrorAction SilentlyContinue
                foreach ($f in $found) {
                    # Convert to relative path
                    $relPath = $f.FullName.Substring($BasePath.Length).TrimStart('\', '/')
                    $actualFiles += $relPath
                }
            }
        }
        # Also scan Config/ for .json and .ini
        $configPath = Join-Path $BasePath 'Config'
        if (Test-Path $configPath) {
            $configFiles = Get-ChildItem -Path $configPath -Include '*.json','*.ini' -File -ErrorAction SilentlyContinue
            foreach ($f in $configFiles) {
                $relPath = $f.FullName.Substring($BasePath.Length).TrimStart('\', '/')
                $actualFiles += $relPath
            }
        }

        $result.ActualCount = $actualFiles.Count

        # Normalize paths for comparison (use backslash)
        $expectedNorm = @()
        foreach ($p in $expectedFiles) { $expectedNorm += $p.Replace('/', '\') }

        foreach ($actual in $actualFiles) {
            $normActual = $actual.Replace('/', '\')
            # Skip VersionManifest.json itself
            if ($normActual -like '*VersionManifest.json') { continue }
            if ($expectedNorm -notcontains $normActual) {
                $result.UnexpectedFiles += $actual
                $result.Details += "UNEXPECTED: $actual"
            }
        }

        if ($result.MissingFiles.Count -gt 0 -or $result.UnexpectedFiles.Count -gt 0) {
            $result.Valid = $false
        }
    } catch {
        $result.Valid = $false
        $result.Details += "Error reading manifest: $($_.Exception.Message)"
    }

    return $result
}

#endregion

#region -- Whitelist Enforcement

function Get-RemediationWhitelist {
    param(
        [string]$ConfigJsonPath = ''
    )
    # Default whitelist matching v8.5 fix actions
    $defaultWhitelist = @(
        'BITS_ServiceRestart', 'DISM_ComponentRepair', 'SFC_SystemScan',
        'DisplayDriver_Update', 'DNS_Reset', 'Winsock_Reset',
        'WindowsUpdate_Reset', 'Defender_SignatureUpdate',
        'TempFile_Cleanup', 'RestorePoint_Create'
    )

    if ($ConfigJsonPath -and (Test-Path $ConfigJsonPath)) {
        try {
            $config = Get-Content $ConfigJsonPath -Raw | ConvertFrom-Json
            if ($config.governance -and $config.governance.whitelist) {
                $configWhitelist = @($config.governance.whitelist)
                if ($configWhitelist.Count -gt 0) {
                    return $configWhitelist
                }
            }
        } catch { }
    }
    return $defaultWhitelist
}

function Test-WhitelistApproval {
    param(
        [Parameter(Mandatory)][string]$ActionId,
        [string]$ConfigJsonPath = '',
        [bool]$EnforcementEnabled = $true
    )
    $result = [ordered]@{
        ActionId          = $ActionId
        Approved          = $true
        Reason            = 'Whitelist check passed'
        EnforcementActive = $EnforcementEnabled
    }

    if (-not $EnforcementEnabled) {
        $result.Reason = 'Whitelist enforcement disabled'
        return $result
    }

    $whitelist = Get-RemediationWhitelist -ConfigJsonPath $ConfigJsonPath

    # Check exact match or prefix match (e.g., "BITS_ServiceRestart" matches "BITS_ServiceRestart_Phase6")
    $matched = $false
    foreach ($item in $whitelist) {
        if ($ActionId -eq $item -or $ActionId -like "$item*") {
            $matched = $true
            break
        }
    }

    if (-not $matched) {
        $result.Approved = $false
        $result.Reason = "Action '$ActionId' not found on approved remediation whitelist"
    }

    return $result
}

#endregion

#region -- Rollback Simulation

function Test-RollbackSimulation {
    param(
        [Parameter(Mandatory)][array]$RemediationLedger
    )
    # Validate each ledger entry with a RollbackToken has valid BeforeState data
    $result = [ordered]@{
        AllValid     = $true
        TokenCount   = 0
        ValidCount   = 0
        InvalidCount = 0
        Issues       = @()
        SimulatedAt  = (Get-Date).ToString('o')
    }

    foreach ($entry in $RemediationLedger) {
        $token = $null
        $beforeState = $null

        # Handle both hashtable and PSCustomObject
        if ($entry -is [hashtable]) {
            $token = $entry['RollbackToken']
            $beforeState = $entry['BeforeState']
        } else {
            $token = $entry.RollbackToken
            $beforeState = $entry.BeforeState
        }

        if (-not $token) { continue }
        $result.TokenCount++

        # Validate BeforeState exists and has meaningful data
        $isValid = $false
        if ($beforeState) {
            if ($beforeState -is [hashtable] -and $beforeState.Count -gt 0) {
                $isValid = $true
            } elseif ($beforeState -is [string] -and $beforeState.Length -gt 0) {
                $isValid = $true
            } elseif ($beforeState -is [pscustomobject]) {
                $props = @($beforeState.PSObject.Properties)
                if ($props.Count -gt 0) { $isValid = $true }
            }
        }

        if ($isValid) {
            $result.ValidCount++
        } else {
            $result.InvalidCount++
            $result.AllValid = $false
            $issueId = if ($entry -is [hashtable]) { $entry['IssueID'] } else { $entry.IssueID }
            $result.Issues += "Token $token (Issue: $issueId) -- BeforeState missing or empty"
        }
    }

    if ($result.TokenCount -eq 0) {
        $result.Issues += 'No rollback tokens found in ledger'
    }

    return $result
}

#endregion

#region -- Fleet KPI Export

function Export-FleetKPIs {
    param(
        [string]$TrendStorePath = '',
        [string]$OutputPath = '',
        [hashtable]$CurrentSession = @{}
    )
    $kpis = [ordered]@{
        GeneratedAt          = (Get-Date).ToString('o')
        MachineName          = $env:COMPUTERNAME
        SessionCount         = 0
        L1FixRate            = 0.0
        L2AdvisoryCount      = 0
        L3EscalationCount    = 0
        MeanScoreImprovement = 0.0
        RecurrenceRate       = 0.0
        ExceptionRate        = 0.0
        Sessions             = @()
    }

    # Aggregate from TrendStore if available
    if ($TrendStorePath -and (Test-Path $TrendStorePath)) {
        try {
            $trendFiles = Get-ChildItem -Path $TrendStorePath -Filter '*.json' -File -ErrorAction SilentlyContinue
            $totalSessions = 0
            $totalL1Fixed = 0
            $totalL1Total = 0
            $totalL2 = 0
            $totalL3 = 0
            $scoreDeltaSum = 0.0
            $recurrenceCount = 0

            foreach ($tf in $trendFiles) {
                try {
                    $trendData = Get-Content $tf.FullName -Raw | ConvertFrom-Json
                    if ($trendData.sessions) {
                        foreach ($session in $trendData.sessions) {
                            $totalSessions++
                            if ($session.l1_fixed) { $totalL1Fixed += [int]$session.l1_fixed }
                            if ($session.l1_total) { $totalL1Total += [int]$session.l1_total }
                            if ($session.l2_count) { $totalL2 += [int]$session.l2_count }
                            if ($session.l3_count) { $totalL3 += [int]$session.l3_count }
                            if ($session.score_delta) { $scoreDeltaSum += [double]$session.score_delta }
                            if ($session.is_recurrence) { $recurrenceCount++ }
                        }
                    }
                } catch { }
            }

            $kpis.SessionCount = $totalSessions
            $kpis.L2AdvisoryCount = $totalL2
            $kpis.L3EscalationCount = $totalL3
            if ($totalL1Total -gt 0) { $kpis.L1FixRate = [math]::Round(($totalL1Fixed / $totalL1Total) * 100, 1) }
            if ($totalSessions -gt 0) {
                $kpis.MeanScoreImprovement = [math]::Round($scoreDeltaSum / $totalSessions, 1)
                $kpis.RecurrenceRate = [math]::Round(($recurrenceCount / $totalSessions) * 100, 1)
            }
        } catch { }
    }

    # Include current session data if provided
    if ($CurrentSession.Count -gt 0) {
        $kpis.CurrentSession = $CurrentSession
    }

    # Export to file if OutputPath provided
    if ($OutputPath) {
        try {
            $kpis | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8 -Force
        } catch { }
    }

    return $kpis
}

#endregion

#region -- Fleet Governance Summary

function New-FleetGovernanceSummary {
    param(
        [hashtable]$KPIs = @{},
        [hashtable]$ExceptionSummary = @{},
        [hashtable]$PolicyProfile = @{},
        [hashtable]$DirectoryCheck = @{},
        [hashtable]$RollbackSim = @{}
    )
    # Generate a governance summary block (HTML fragment or data structure)
    # This can be integrated into existing Fleet_Dashboard.html or ManagementSummary.html

    $summary = [ordered]@{
        GeneratedAt       = (Get-Date).ToString('o')
        MachineName       = $env:COMPUTERNAME
        GovernanceVersion = '9.0.0'

        PolicyCompliance = [ordered]@{
            ProfileName       = if ($PolicyProfile.Count -gt 0 -and $PolicyProfile.ContainsKey('Name')) { $PolicyProfile['Name'] } else { 'Unknown' }
            WhitelistEnforced = if ($PolicyProfile.Count -gt 0 -and $PolicyProfile.ContainsKey('requireWhitelist')) { $true } else { $false }
            RetryEnabled      = if ($PolicyProfile.Count -gt 0 -and $PolicyProfile.ContainsKey('retryEnabled')) { $true } else { $false }
        }

        DirectoryIntegrity = [ordered]@{
            Valid           = if ($DirectoryCheck.Count -gt 0 -and $DirectoryCheck.ContainsKey('Valid')) { $DirectoryCheck['Valid'] } else { $false }
            MissingCount    = if ($DirectoryCheck.Count -gt 0 -and $DirectoryCheck.ContainsKey('MissingFiles')) { $DirectoryCheck['MissingFiles'].Count } else { 0 }
            UnexpectedCount = if ($DirectoryCheck.Count -gt 0 -and $DirectoryCheck.ContainsKey('UnexpectedFiles')) { $DirectoryCheck['UnexpectedFiles'].Count } else { 0 }
        }

        ExceptionHealth = [ordered]@{
            TotalExceptions = if ($ExceptionSummary.Count -gt 0 -and $ExceptionSummary.ContainsKey('TotalExceptions')) { $ExceptionSummary['TotalExceptions'] } else { 0 }
            CriticalCount   = 0
            ErrorCount      = 0
            WarningCount    = 0
        }

        RollbackReadiness = [ordered]@{
            TokenCount = if ($RollbackSim.Count -gt 0 -and $RollbackSim.ContainsKey('TokenCount')) { $RollbackSim['TokenCount'] } else { 0 }
            AllValid   = if ($RollbackSim.Count -gt 0 -and $RollbackSim.ContainsKey('AllValid')) { $RollbackSim['AllValid'] } else { $false }
        }

        KPISnapshot = [ordered]@{
            L1FixRate            = if ($KPIs.Count -gt 0 -and $KPIs.ContainsKey('L1FixRate')) { $KPIs['L1FixRate'] } else { 0 }
            MeanScoreImprovement = if ($KPIs.Count -gt 0 -and $KPIs.ContainsKey('MeanScoreImprovement')) { $KPIs['MeanScoreImprovement'] } else { 0 }
            SessionCount         = if ($KPIs.Count -gt 0 -and $KPIs.ContainsKey('SessionCount')) { $KPIs['SessionCount'] } else { 0 }
        }
    }

    # Fill exception severity counts
    if ($ExceptionSummary.Count -gt 0 -and $ExceptionSummary.ContainsKey('BySeverity')) {
        $bySev = $ExceptionSummary['BySeverity']
        if ($bySev.ContainsKey('Critical')) { $summary.ExceptionHealth.CriticalCount = $bySev['Critical'] }
        if ($bySev.ContainsKey('Error')) { $summary.ExceptionHealth.ErrorCount = $bySev['Error'] }
        if ($bySev.ContainsKey('Warning')) { $summary.ExceptionHealth.WarningCount = $bySev['Warning'] }
    }

    return $summary
}

#endregion

#endregion

#region -- v10 KPI Validation Support

function Get-FleetKPIFields {
    <#
    .SYNOPSIS
        v10 S9: Returns formal KPI field definitions for certification validation.
        Used by CertificationEngine.Test-KPIThresholds to validate fleet metrics.
    .OUTPUTS
        [PSCustomObject] with KPI field definitions and current values
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $TrendStorePath = '',
        [hashtable] $CurrentSession = @{}
    )

    # Get fleet KPIs from existing function
    $kpis = Export-FleetKPIs -TrendStorePath $TrendStorePath -CurrentSession $CurrentSession

    # Map to formal v10 KPI fields
    $formal = [ordered]@{
        _type                          = 'FLEET_KPI_FIELDS'
        _version                       = '10.0.0'
        generatedAt                    = Get-Date -Format 'o'
        machineName                    = $env:COMPUTERNAME
        autoFixRate                    = $kpis.L1FixRate
        rollbackSuccessRate            = 100  # Default; updated by session data
        stressPassRate                 = 100  # Default; updated by session data
        classificationConfidenceAvg    = 0    # Default; updated by session data
        sessionCount                   = $kpis.SessionCount
        l2AdvisoryCount                = $kpis.L2AdvisoryCount
        l3EscalationCount              = $kpis.L3EscalationCount
        meanScoreImprovement           = $kpis.MeanScoreImprovement
        recurrenceRate                 = $kpis.RecurrenceRate
    }

    # Update from current session if available
    if ($CurrentSession.Count -gt 0) {
        if ($CurrentSession.ContainsKey('RollbackSuccessRate')) {
            $formal.rollbackSuccessRate = $CurrentSession['RollbackSuccessRate']
        }
        if ($CurrentSession.ContainsKey('StressPassRate')) {
            $formal.stressPassRate = $CurrentSession['StressPassRate']
        }
        if ($CurrentSession.ContainsKey('ClassificationConfidenceAvg')) {
            $formal.classificationConfidenceAvg = $CurrentSession['ClassificationConfidenceAvg']
        }
    }

    return [PSCustomObject]$formal
}

#endregion

#region -- Module Exports

Export-ModuleMember -Function @(
    'Test-DirectoryIntegrity',
    'Get-RemediationWhitelist',
    'Test-WhitelistApproval',
    'Test-RollbackSimulation',
    'Export-FleetKPIs',
    'New-FleetGovernanceSummary',
    'Get-FleetKPIFields'
)

#endregion
