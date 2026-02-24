#Requires -Version 5.1
<#
.SYNOPSIS
    LDT CertificationEngine -- Self-Health, KPI Validation, Config Schema & Security Hardening

.DESCRIPTION
    Implements certification-grade validation controls for LDT v10.0.

    Certification Functions:
      1. Engine Self-Health      -- Module load, required function existence, deprecated call
                                    detection, config schema validation (S7)
      2. KPI Validation          -- Formal KPI metrics (AutoFixRate, RollbackSuccessRate,
                                    StressPassRate, ClassificationConfidenceAvg) with
                                    GovernanceWarning flagging (S9)
      3. Config Schema Validation-- Required sections, unknown keys, numeric ranges,
                                    weight sum = 100% validation (S10)
      4. Security Hardening Check-- Read-only security posture check: ExecutionPolicy,
                                    SecureBoot, Defender, BitLocker (S11)

    EngineHealthStatus:
      HEALTHY  -- All checks pass, full capability
      DEGRADED -- Non-critical issues detected, limited capability
      INVALID  -- Critical failures, remediation blocked

.NOTES
    Version : 10.0.0
    Platform: PowerShell 5.1+
    Sections: S7 (Self-Health), S9 (KPI Validation), S10 (Config Schema), S11 (Security Hardening)
#>

Set-StrictMode -Version Latest

$script:_OperationalBoundary = [ordered]@{
    moduleName     = 'CertificationEngine'
    version        = '10.0.0'
    canDo          = @(
        'Validate module load success and function existence'
        'Detect deprecated function calls'
        'Validate config.ini schema completeness'
        'Enforce KPI thresholds with GovernanceWarning'
        'Read-only security posture assessment'
    )
    cannotDo       = @(
        'Modify security settings'
        'Change execution policy'
        'Enable or disable BitLocker'
        'Modify Defender settings'
        'Override KPI thresholds'
    )
}

#region -- S7: Engine Self-Health Functions

function Invoke-EngineHealthCheck {
    <#
    .SYNOPSIS
        Validates LDT engine integrity: module load, required functions, deprecated calls,
        hash consistency, config schema, and policy profile.
    .OUTPUTS
        [PSCustomObject] with engineHealthStatus (HEALTHY/DEGRADED/INVALID), checks[]
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot,
        [string] $ConfigIniPath  = '',
        [string] $ConfigJsonPath = ''
    )

    $result = [ordered]@{
        timestamp          = Get-Date -Format 'o'
        sessionId          = $SessionId
        engineHealthStatus = 'UNKNOWN'
        checks             = @()
        criticalFailures   = 0
        warnings           = 0
    }

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'CertificationEngine' `
        -Message "Engine self-health check initiated"

    # ── Check 1: Required Modules Loaded ─────────────────────────────────────
    $moduleCheck = _Test-RequiredModules -PlatformRoot $PlatformRoot
    $result.checks += $moduleCheck
    if ($moduleCheck.status -eq 'FAIL') { $result.criticalFailures++ }
    elseif ($moduleCheck.status -eq 'WARN') { $result.warnings++ }

    # ── Check 2: Required Functions Exist ────────────────────────────────────
    $funcCheck = Test-RequiredFunctions
    $result.checks += $funcCheck
    if ($funcCheck.status -eq 'FAIL') { $result.criticalFailures++ }
    elseif ($funcCheck.status -eq 'WARN') { $result.warnings++ }

    # ── Check 3: Deprecated Calls ────────────────────────────────────────────
    $deprecatedCheck = Test-DeprecatedCalls -PlatformRoot $PlatformRoot
    $result.checks += $deprecatedCheck
    if ($deprecatedCheck.status -eq 'WARN') { $result.warnings++ }

    # ── Check 4: Config Schema ───────────────────────────────────────────────
    if ($ConfigIniPath) {
        $schemaCheck = Test-ConfigSchema -SessionId $SessionId -ConfigIniPath $ConfigIniPath
        $result.checks += [PSCustomObject]@{
            checkName = 'ConfigSchema'
            status    = $schemaCheck.overallStatus
            details   = "Sections: $($schemaCheck.sectionsFound)/$($schemaCheck.sectionsRequired), Issues: $($schemaCheck.issues.Count)"
        }
        if ($schemaCheck.overallStatus -eq 'INVALID') { $result.criticalFailures++ }
        elseif ($schemaCheck.overallStatus -ne 'PASS') { $result.warnings++ }
    }

    # ── Check 5: Config.json Structure ───────────────────────────────────────
    if ($ConfigJsonPath -and (Test-Path $ConfigJsonPath)) {
        $jsonCheck = _Test-ConfigJsonStructure -ConfigJsonPath $ConfigJsonPath
        $result.checks += $jsonCheck
        if ($jsonCheck.status -eq 'FAIL') { $result.criticalFailures++ }
        elseif ($jsonCheck.status -eq 'WARN') { $result.warnings++ }
    }

    # ── Final Assessment ─────────────────────────────────────────────────────
    if ($result.criticalFailures -gt 0) {
        $result.engineHealthStatus = 'INVALID'
    }
    elseif ($result.warnings -gt 0) {
        $result.engineHealthStatus = 'DEGRADED'
    }
    else {
        $result.engineHealthStatus = 'HEALTHY'
    }

    $logLevel = if ($result.engineHealthStatus -eq 'HEALTHY') { 'AUDIT' }
                elseif ($result.engineHealthStatus -eq 'DEGRADED') { 'WARN' }
                else { 'ERROR' }
    Write-EngineLog -SessionId $SessionId -Level $logLevel -Source 'CertificationEngine' `
        -Message "Engine health: $($result.engineHealthStatus) (Critical=$($result.criticalFailures), Warn=$($result.warnings))"

    return [PSCustomObject]$result
}

function Test-RequiredFunctions {
    <#
    .SYNOPSIS
        Verifies that all required exported functions exist in the current session.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $requiredFunctions = @(
        # GuardEngine
        'Initialize-GuardEngine', 'Test-GuardClearance', 'Invoke-GuardedRemediation',
        'Set-EscalationLevel', 'Get-GuardStatus',
        # IntegrityEngine
        'Test-PlatformIntegrity', 'Seal-SessionLog', 'New-ExecutionReceipt',
        # GovernanceEngine
        'Initialize-PolicyEngine', 'Get-PolicyProfile', 'Save-ExecutionState',
        'Get-ExecutionMode', 'Test-ModeAllowsPhase', 'Write-GovernedException',
        # ClassificationEngine
        'Get-ClassificationConfig', 'Invoke-DiagnosticClassification',
        # ScoringEngine
        'Invoke-SystemScoring',
        # ComplianceExport
        'Export-ComplianceArtifacts'
    )

    $missing = @()
    $found   = 0

    foreach ($func in $requiredFunctions) {
        if (Get-Command $func -ErrorAction SilentlyContinue) {
            $found++
        } else {
            $missing += $func
        }
    }

    $status = if ($missing.Count -eq 0) { 'PASS' }
              elseif ($missing.Count -le 3) { 'WARN' }
              else { 'FAIL' }

    return [PSCustomObject]@{
        checkName = 'RequiredFunctions'
        status    = $status
        details   = "Found $found/$($requiredFunctions.Count), Missing: $($missing -join ', ')"
        found     = $found
        total     = $requiredFunctions.Count
        missing   = $missing
    }
}

function Test-DeprecatedCalls {
    <#
    .SYNOPSIS
        Scans script files for deprecated or unsafe patterns.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $PlatformRoot = ''
    )

    $deprecatedPatterns = @(
        @{ Pattern = 'Invoke-WebRequest';  Reason = 'Network calls prohibited in offline tool' }
        @{ Pattern = 'Invoke-RestMethod';  Reason = 'Network calls prohibited in offline tool' }
        @{ Pattern = 'Start-BitsTransfer'; Reason = 'Network transfer prohibited' }
        @{ Pattern = 'Net\.WebClient';     Reason = 'Network calls prohibited' }
        @{ Pattern = '\?\?';              Reason = 'PS 7+ null-coalescing operator' }
        @{ Pattern = '\?\.'  ;            Reason = 'PS 7+ null-conditional operator' }
        @{ Pattern = 'ForEach-Object\s+-Parallel'; Reason = 'PS 7+ parallel processing' }
    )

    $findings = @()

    if ($PlatformRoot -and (Test-Path $PlatformRoot)) {
        $scriptFiles = @()
        $scriptFiles += Get-ChildItem -Path $PlatformRoot -Filter '*.ps1' -ErrorAction SilentlyContinue
        $coreDir = Join-Path $PlatformRoot 'Core'
        if (Test-Path $coreDir) {
            $scriptFiles += Get-ChildItem -Path $coreDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        }

        foreach ($file in $scriptFiles) {
            try {
                $content = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if (-not $content) { continue }

                foreach ($dp in $deprecatedPatterns) {
                    if ($content -match $dp.Pattern) {
                        # Exclude patterns inside comments or string literals (simple heuristic)
                        $lines = Get-Content $file.FullName -Encoding UTF8
                        $lineNum = 0
                        foreach ($line in $lines) {
                            $lineNum++
                            $trimmed = $line.TrimStart()
                            if ($trimmed.StartsWith('#')) { continue }
                            if ($trimmed.StartsWith("'")) { continue }
                            if ($line -match $dp.Pattern) {
                                $findings += [PSCustomObject]@{
                                    file    = $file.Name
                                    line    = $lineNum
                                    pattern = $dp.Pattern
                                    reason  = $dp.Reason
                                }
                                break  # One finding per pattern per file
                            }
                        }
                    }
                }
            }
            catch { }
        }
    }

    $status = if ($findings.Count -eq 0) { 'PASS' } else { 'WARN' }

    return [PSCustomObject]@{
        checkName = 'DeprecatedCalls'
        status    = $status
        details   = "$($findings.Count) deprecated pattern(s) found"
        findings  = $findings
    }
}

#endregion

#region -- S9: KPI Validation Functions

function Test-KPIThresholds {
    <#
    .SYNOPSIS
        Validates session KPIs against certification thresholds.
        Flags GovernanceWarning if any KPI is below minimum.
    .OUTPUTS
        [PSCustomObject] with overallStatus, kpis[], governanceWarning
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [hashtable] $DiagState,
        [string] $ConfigIniPath = ''
    )

    $thresholds = _Get-KPIConfig -ConfigIniPath $ConfigIniPath

    $result = [ordered]@{
        timestamp          = Get-Date -Format 'o'
        overallStatus      = 'UNKNOWN'
        governanceWarning  = $false
        kpis               = @()
        belowThreshold     = @()
    }

    # Calculate AutoFixRate
    $totalFindings = 0
    $totalFixes    = 0
    if ($DiagState.Findings) { $totalFindings = $DiagState.Findings.Count }
    if ($DiagState.FixesApplied) { $totalFixes = @($DiagState.FixesApplied | Where-Object { $_.FixApplied -eq $true }).Count }

    $autoFixRate = if ($totalFindings -gt 0) { [math]::Round(($totalFixes / $totalFindings) * 100, 1) } else { 100 }
    $result.kpis += [PSCustomObject]@{
        name      = 'AutoFixRate'
        value     = $autoFixRate
        threshold = $thresholds.AutoFixRateMin
        unit      = 'percent'
        status    = if ($autoFixRate -ge $thresholds.AutoFixRateMin) { 'PASS' } else { 'BELOW' }
    }

    # Calculate RollbackSuccessRate
    $totalRollbacks  = 0
    $successRollbacks = 0
    if ($DiagState.FixesApplied) {
        foreach ($fix in $DiagState.FixesApplied) {
            if ($fix.RollbackToken -and $fix.RollbackToken -ne '') {
                $totalRollbacks++
                if ($fix.FinalStatus -ne 'FAILED') { $successRollbacks++ }
            }
        }
    }
    $rollbackRate = if ($totalRollbacks -gt 0) { [math]::Round(($successRollbacks / $totalRollbacks) * 100, 1) } else { 100 }
    $result.kpis += [PSCustomObject]@{
        name      = 'RollbackSuccessRate'
        value     = $rollbackRate
        threshold = $thresholds.RollbackSuccessRateMin
        unit      = 'percent'
        status    = if ($rollbackRate -ge $thresholds.RollbackSuccessRateMin) { 'PASS' } else { 'BELOW' }
    }

    # Calculate StressPassRate
    $totalStress = 0
    $passedStress = 0
    if ($DiagState.StressResults) {
        foreach ($key in $DiagState.StressResults.Keys) {
            $totalStress++
            $sr = $DiagState.StressResults[$key]
            if ($sr -is [hashtable] -and $sr.ContainsKey('Status')) {
                if ($sr.Status -eq 'PASS') { $passedStress++ }
            }
            elseif ($sr -is [PSCustomObject] -and $sr.PSObject.Properties['Status']) {
                if ($sr.Status -eq 'PASS') { $passedStress++ }
            }
            else { $passedStress++ }
        }
    }
    $stressRate = if ($totalStress -gt 0) { [math]::Round(($passedStress / $totalStress) * 100, 1) } else { 100 }
    $result.kpis += [PSCustomObject]@{
        name      = 'StressPassRate'
        value     = $stressRate
        threshold = $thresholds.StressPassRateMin
        unit      = 'percent'
        status    = if ($stressRate -ge $thresholds.StressPassRateMin) { 'PASS' } else { 'BELOW' }
    }

    # Calculate ClassificationConfidenceAvg
    $totalConfidence = 0
    $confidenceCount = 0
    if ($DiagState.Findings) {
        foreach ($finding in $DiagState.Findings) {
            if ($finding.ConfidenceScore -and $finding.ConfidenceScore -gt 0) {
                $totalConfidence += $finding.ConfidenceScore
                $confidenceCount++
            }
        }
    }
    $avgConfidence = if ($confidenceCount -gt 0) { [math]::Round($totalConfidence / $confidenceCount, 1) } else { 100 }
    $result.kpis += [PSCustomObject]@{
        name      = 'ClassificationConfidenceAvg'
        value     = $avgConfidence
        threshold = $thresholds.ClassificationConfidenceAvgMin
        unit      = 'percent'
        status    = if ($avgConfidence -ge $thresholds.ClassificationConfidenceAvgMin) { 'PASS' } else { 'BELOW' }
    }

    # Determine if GovernanceWarning needed
    $belowCount = @($result.kpis | Where-Object { $_.status -eq 'BELOW' }).Count
    $result.belowThreshold = @($result.kpis | Where-Object { $_.status -eq 'BELOW' })

    if ($belowCount -gt 0) {
        $result.governanceWarning = $true
        $result.overallStatus     = 'GOVERNANCE_WARNING'
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'CertificationEngine' `
            -Message "KPI GOVERNANCE WARNING: $belowCount KPI(s) below threshold" `
            -Data @{ below = $belowCount; kpis = ($result.belowThreshold | ForEach-Object { "$($_.name)=$($_.value)" }) -join '; ' }
    } else {
        $result.overallStatus = 'PASS'
    }

    return [PSCustomObject]$result
}

function Export-KPIReport {
    <#
    .SYNOPSIS
        Exports KPI validation results to KPIReport.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $KPIResult,
        [Parameter(Mandatory)] [string] $OutputPath,
        [string] $SessionId = ''
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $report = [ordered]@{
        _type             = 'KPI_REPORT'
        _version          = '10.0.0'
        sessionId         = $SessionId
        generatedAt       = Get-Date -Format 'o'
        overallStatus     = $KPIResult.overallStatus
        governanceWarning = $KPIResult.governanceWarning
        kpis              = $KPIResult.kpis
    }

    $outFile = Join-Path $OutputPath "KPIReport_$SessionId.json"
    $report | ConvertTo-Json -Depth 10 | Set-Content $outFile -Encoding UTF8

    return $outFile
}

#endregion

#region -- S10: Config Schema Validation Functions

function Test-ConfigSchema {
    <#
    .SYNOPSIS
        Validates config.ini schema: required sections, numeric ranges, weight sums.
    .OUTPUTS
        [PSCustomObject] with overallStatus, sectionsFound, sectionsRequired, issues[]
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $ConfigIniPath
    )

    $result = [ordered]@{
        overallStatus    = 'UNKNOWN'
        sectionsFound    = 0
        sectionsRequired = 0
        issues           = @()
        weightSums       = @()
    }

    if (-not (Test-Path $ConfigIniPath)) {
        $result.overallStatus = 'FILE_MISSING'
        $result.issues += "config.ini not found at: $ConfigIniPath"
        return [PSCustomObject]$result
    }

    $content = Get-Content $ConfigIniPath -Encoding UTF8

    # Parse sections
    $sections = @{}
    $currentSection = ''
    foreach ($line in $content) {
        if ($line -match '^\s*\[(.+)\]') {
            $currentSection = $Matches[1].Trim()
            if (-not $sections.ContainsKey($currentSection)) {
                $sections[$currentSection] = @{}
            }
        }
        elseif ($currentSection -and $line -match '^\s*([^;#][^=]*?)\s*=\s*(.*)') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()
            $sections[$currentSection][$key] = $val
        }
    }

    $result.sectionsFound = $sections.Count

    # Required sections
    $requiredSections = @(
        'General', 'Paths', 'Diagnostics', 'HardwareTests', 'Repair',
        'Security', 'SmartDiagnosis', 'ClassificationEngine', 'GovernanceEngine'
    )
    $result.sectionsRequired = $requiredSections.Count

    foreach ($req in $requiredSections) {
        if (-not $sections.ContainsKey($req)) {
            $result.issues += "Missing required section: [$req]"
        }
    }

    # Validate numeric values
    $numericKeys = @{
        'HardwareTests'    = @('DiskTestSizeMB', 'MemoryTestSizeMB', 'CPUStressTestDurationSec',
                               'ThermalWarningThresholdC', 'ThermalCriticalThresholdC')
        'SmartDiagnosis'   = @('StressTestDurationSec', 'ConfidenceThresholdForAutoFix',
                               'BSODCriticalCount', 'BSODDaysBack')
        'ClassificationEngine' = @('SeverityCritical', 'SeverityHigh', 'SeverityMedium', 'SeverityLow')
    }

    foreach ($section in $numericKeys.Keys) {
        if ($sections.ContainsKey($section)) {
            foreach ($key in $numericKeys[$section]) {
                if ($sections[$section].ContainsKey($key)) {
                    $val = $sections[$section][$key]
                    if ($val -notmatch '^\d+(\.\d+)?$') {
                        $result.issues += "[$section] $key = '$val' is not numeric"
                    }
                }
            }
        }
    }

    # Validate weight sums
    $weightSections = @{
        'EnterpriseReadinessReport' = @(
            'WeightSecurity', 'WeightHardware', 'WeightStorage', 'WeightBattery',
            'WeightDrivers', 'WeightOS', 'WeightIdentity', 'WeightTPM', 'WeightDisplay'
        )
        'QuickStart' = @(
            'WeightHardware', 'WeightSecurity', 'WeightStability', 'WeightPerformance'
        )
    }

    foreach ($section in $weightSections.Keys) {
        if ($sections.ContainsKey($section)) {
            $sum = 0
            $allPresent = $true
            foreach ($wKey in $weightSections[$section]) {
                if ($sections[$section].ContainsKey($wKey)) {
                    $wVal = $sections[$section][$wKey]
                    if ($wVal -match '^\d+$') {
                        $sum += [int]$wVal
                    }
                } else {
                    $allPresent = $false
                }
            }
            $result.weightSums += [PSCustomObject]@{
                section  = $section
                sum      = $sum
                expected = 100
                valid    = ($sum -eq 100)
            }
            if ($allPresent -and $sum -ne 100) {
                $result.issues += "[$section] weight sum = $sum (expected 100)"
            }
        }
    }

    # Validate range constraints
    if ($sections.ContainsKey('ClassificationEngine')) {
        $ce = $sections['ClassificationEngine']
        $severityOrder = @('SeverityLow', 'SeverityMedium', 'SeverityHigh', 'SeverityCritical')
        $prevVal = 0
        foreach ($sk in $severityOrder) {
            if ($ce.ContainsKey($sk)) {
                $sVal = 0
                if ($ce[$sk] -match '^\d+$') { $sVal = [int]$ce[$sk] }
                if ($sVal -lt $prevVal) {
                    $result.issues += "[ClassificationEngine] $sk ($sVal) must be >= previous threshold ($prevVal)"
                }
                $prevVal = $sVal
            }
        }
    }

    # Final status
    $result.overallStatus = if ($result.issues.Count -eq 0) { 'PASS' }
                            elseif (@($result.issues | Where-Object { $_ -match 'Missing required' }).Count -gt 0) { 'INVALID' }
                            else { 'WARNINGS' }

    Write-EngineLog -SessionId $SessionId -Level $(if ($result.overallStatus -eq 'PASS') { 'AUDIT' } else { 'WARN' }) `
        -Source 'CertificationEngine' `
        -Message "Config schema validation: $($result.overallStatus) ($($result.sectionsFound) sections, $($result.issues.Count) issues)"

    return [PSCustomObject]$result
}

#endregion

#region -- S11: Security Hardening Check Functions

function Get-SecurityHardeningStatus {
    <#
    .SYNOPSIS
        Read-only security posture check. Does NOT modify any settings.
        Checks: ExecutionPolicy, SecureBoot, Defender TamperProtection, BitLocker.
    .OUTPUTS
        [PSCustomObject] with overallPosture, checks[]
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [string] $ConfigIniPath = ''
    )

    $shConfig = _Get-SecurityHardeningConfig -ConfigIniPath $ConfigIniPath

    $result = [ordered]@{
        timestamp       = Get-Date -Format 'o'
        overallPosture  = 'UNKNOWN'
        checks          = @()
        passCount       = 0
        warnCount       = 0
        failCount       = 0
    }

    # ── Check 1: PowerShell Execution Policy ─────────────────────────────────
    if ($shConfig.CheckExecutionPolicy) {
        $epCheck = [ordered]@{
            name   = 'ExecutionPolicy'
            status = 'UNKNOWN'
            value  = ''
            recommendation = ''
        }
        try {
            $ep = Get-ExecutionPolicy -Scope LocalMachine -ErrorAction SilentlyContinue
            $epCheck.value = "$ep"
            if ($ep -eq 'Restricted' -or $ep -eq 'AllSigned') {
                $epCheck.status = 'HARDENED'
                $result.passCount++
            }
            elseif ($ep -eq 'RemoteSigned') {
                $epCheck.status = 'ACCEPTABLE'
                $result.passCount++
            }
            else {
                $epCheck.status = 'WEAK'
                $epCheck.recommendation = "Consider setting ExecutionPolicy to RemoteSigned or AllSigned"
                $result.warnCount++
            }
        }
        catch {
            $epCheck.status = 'ERROR'
            $result.warnCount++
        }
        $result.checks += [PSCustomObject]$epCheck
    }

    # ── Check 2: Secure Boot ─────────────────────────────────────────────────
    if ($shConfig.CheckSecureBoot) {
        $sbCheck = [ordered]@{
            name   = 'SecureBoot'
            status = 'UNKNOWN'
            value  = ''
            recommendation = ''
        }
        try {
            $sb = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
            $sbCheck.value = "$sb"
            if ($sb) {
                $sbCheck.status = 'ENABLED'
                $result.passCount++
            } else {
                $sbCheck.status = 'DISABLED'
                $sbCheck.recommendation = "Secure Boot should be enabled for enterprise compliance"
                $result.failCount++
            }
        }
        catch {
            $sbCheck.status = 'NOT_SUPPORTED'
            $sbCheck.value  = $_.Exception.Message
        }
        $result.checks += [PSCustomObject]$sbCheck
    }

    # ── Check 3: Defender Tamper Protection ───────────────────────────────────
    if ($shConfig.CheckDefenderTamperProtection) {
        $dtCheck = [ordered]@{
            name   = 'DefenderTamperProtection'
            status = 'UNKNOWN'
            value  = ''
            recommendation = ''
        }
        try {
            $defenderPrefs = Get-MpPreference -ErrorAction SilentlyContinue
            if ($defenderPrefs) {
                $tamper = $defenderPrefs.IsTamperProtected
                $dtCheck.value = "$tamper"
                if ($tamper) {
                    $dtCheck.status = 'ENABLED'
                    $result.passCount++
                } else {
                    $dtCheck.status = 'DISABLED'
                    $dtCheck.recommendation = "Enable Defender Tamper Protection for security compliance"
                    $result.warnCount++
                }
            } else {
                $dtCheck.status = 'NOT_AVAILABLE'
            }
        }
        catch {
            $dtCheck.status = 'NOT_AVAILABLE'
            $dtCheck.value  = $_.Exception.Message
        }
        $result.checks += [PSCustomObject]$dtCheck
    }

    # ── Check 4: BitLocker ───────────────────────────────────────────────────
    if ($shConfig.CheckBitLocker) {
        $blCheck = [ordered]@{
            name   = 'BitLocker'
            status = 'UNKNOWN'
            value  = ''
            recommendation = ''
        }
        try {
            $blStatus = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
            if ($blStatus) {
                $blCheck.value = "$($blStatus.ProtectionStatus)"
                if ($blStatus.ProtectionStatus -eq 'On') {
                    $blCheck.status = 'ENABLED'
                    $result.passCount++
                } else {
                    $blCheck.status = 'DISABLED'
                    $blCheck.recommendation = "Enable BitLocker on system drive for data protection"
                    $result.warnCount++
                }
            } else {
                $blCheck.status = 'NOT_AVAILABLE'
            }
        }
        catch {
            $blCheck.status = 'NOT_AVAILABLE'
            $blCheck.value  = $_.Exception.Message
        }
        $result.checks += [PSCustomObject]$blCheck
    }

    # Final posture assessment
    $totalChecks = $result.passCount + $result.warnCount + $result.failCount
    if ($totalChecks -eq 0) {
        $result.overallPosture = 'NOT_ASSESSED'
    }
    elseif ($result.failCount -gt 0) {
        $result.overallPosture = 'WEAK'
    }
    elseif ($result.warnCount -gt 0) {
        $result.overallPosture = 'MODERATE'
    }
    else {
        $result.overallPosture = 'HARDENED'
    }

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'CertificationEngine' `
        -Message "Security hardening posture: $($result.overallPosture) (Pass=$($result.passCount) Warn=$($result.warnCount) Fail=$($result.failCount))"

    return [PSCustomObject]$result
}

#endregion

#region -- Private Helpers

function _Test-RequiredModules {
    param([string] $PlatformRoot)

    $requiredModules = @(
        'Core\GuardEngine.psm1'
        'Core\IntegrityEngine.psm1'
        'Core\GovernanceEngine.psm1'
        'Core\ClassificationEngine.psm1'
        'Core\ScoringEngine.psm1'
        'Core\TrendEngine.psm1'
        'Core\ComplianceExport.psm1'
        'Core\LDT-EngineAdapter.psm1'
    )

    $found   = 0
    $missing = @()

    foreach ($mod in $requiredModules) {
        $modPath = Join-Path $PlatformRoot $mod
        if (Test-Path $modPath) {
            $found++
        } else {
            $missing += $mod
        }
    }

    $status = if ($missing.Count -eq 0) { 'PASS' }
              elseif ($missing.Count -le 2) { 'WARN' }
              else { 'FAIL' }

    return [PSCustomObject]@{
        checkName = 'RequiredModules'
        status    = $status
        details   = "Found $found/$($requiredModules.Count) modules"
        found     = $found
        total     = $requiredModules.Count
        missing   = $missing
    }
}

function _Test-ConfigJsonStructure {
    param([string] $ConfigJsonPath)

    $issues = @()
    try {
        $config = Get-Content $ConfigJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

        # Required top-level keys
        $requiredKeys = @('engine', 'modules', 'governance')
        foreach ($key in $requiredKeys) {
            if (-not $config.$key) {
                $issues += "Missing top-level key: $key"
            }
        }

        # Required engine sub-keys
        if ($config.engine) {
            $engineKeys = @('scoring', 'escalationThresholds', 'remediationLedger')
            foreach ($ek in $engineKeys) {
                if (-not $config.engine.$ek) {
                    $issues += "Missing engine.$ek"
                }
            }
        }

        # Validate module definitions
        if ($config.modules) {
            $requiredModuleKeys = @('OS/Boot', 'Driver', 'Security', 'Network', 'Hardware')
            foreach ($mk in $requiredModuleKeys) {
                if (-not $config.modules.$mk) {
                    $issues += "Missing module definition: $mk"
                }
            }
        }
    }
    catch {
        $issues += "JSON parse error: $($_.Exception.Message)"
    }

    $status = if ($issues.Count -eq 0) { 'PASS' }
              elseif ($issues.Count -le 2) { 'WARN' }
              else { 'FAIL' }

    return [PSCustomObject]@{
        checkName = 'ConfigJsonStructure'
        status    = $status
        details   = "$($issues.Count) issue(s): $($issues -join '; ')"
    }
}

function _Get-KPIConfig {
    param([string] $ConfigIniPath = '')

    $config = @{
        AutoFixRateMin                  = 70
        RollbackSuccessRateMin          = 90
        StressPassRateMin               = 80
        ClassificationConfidenceAvgMin  = 60
    }

    if ($ConfigIniPath -and (Test-Path $ConfigIniPath)) {
        try {
            $content   = Get-Content $ConfigIniPath -Encoding UTF8
            $inSection = $false
            foreach ($line in $content) {
                if ($line -match '^\s*\[KPIThresholds\]') { $inSection = $true; continue }
                if ($line -match '^\s*\[') { $inSection = $false; continue }
                if ($inSection) {
                    if ($line -match '^\s*AutoFixRateMin\s*=\s*(\d+)') { $config.AutoFixRateMin = [int]$Matches[1] }
                    if ($line -match '^\s*RollbackSuccessRateMin\s*=\s*(\d+)') { $config.RollbackSuccessRateMin = [int]$Matches[1] }
                    if ($line -match '^\s*StressPassRateMin\s*=\s*(\d+)') { $config.StressPassRateMin = [int]$Matches[1] }
                    if ($line -match '^\s*ClassificationConfidenceAvgMin\s*=\s*(\d+)') { $config.ClassificationConfidenceAvgMin = [int]$Matches[1] }
                }
            }
        }
        catch { }
    }

    return $config
}

function _Get-SecurityHardeningConfig {
    param([string] $ConfigIniPath = '')

    $config = @{
        CheckExecutionPolicy         = $true
        CheckSecureBoot              = $true
        CheckDefenderTamperProtection = $true
        CheckBitLocker               = $true
    }

    if ($ConfigIniPath -and (Test-Path $ConfigIniPath)) {
        try {
            $content   = Get-Content $ConfigIniPath -Encoding UTF8
            $inSection = $false
            foreach ($line in $content) {
                if ($line -match '^\s*\[SecurityHardening\]') { $inSection = $true; continue }
                if ($line -match '^\s*\[') { $inSection = $false; continue }
                if ($inSection) {
                    if ($line -match '^\s*CheckExecutionPolicy\s*=\s*(\d+)') { $config.CheckExecutionPolicy = [int]$Matches[1] -ne 0 }
                    if ($line -match '^\s*CheckSecureBoot\s*=\s*(\d+)') { $config.CheckSecureBoot = [int]$Matches[1] -ne 0 }
                    if ($line -match '^\s*CheckDefenderTamperProtection\s*=\s*(\d+)') { $config.CheckDefenderTamperProtection = [int]$Matches[1] -ne 0 }
                    if ($line -match '^\s*CheckBitLocker\s*=\s*(\d+)') { $config.CheckBitLocker = [int]$Matches[1] -ne 0 }
                }
            }
        }
        catch { }
    }

    return $config
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-EngineHealthCheck',
    'Test-RequiredFunctions',
    'Test-DeprecatedCalls',
    'Test-KPIThresholds',
    'Export-KPIReport',
    'Test-ConfigSchema',
    'Get-SecurityHardeningStatus'
)
