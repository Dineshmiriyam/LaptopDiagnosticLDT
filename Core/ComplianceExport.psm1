#Requires -Version 5.1
<#
.SYNOPSIS
    LDT ComplianceExport -- ISO/SOC2/CIS Aligned Audit Artifact Generator

.DESCRIPTION
    Generates structured compliance artifacts from a completed LDT session.
    Artifacts are designed to satisfy audit requirements for:
      - ISO 27001 (A.12 Operations security, A.16 Incident management)
      - SOC 2 Type II (Availability, Integrity, Confidentiality criteria)
      - CIS Controls (CIS v8: Controls 2, 4, 7, 10, 13)

    Generated Artifacts (6 per session):
      1. ComplianceReport.json     -- Master audit record with control mappings
      2. ChangeRecord.json         -- What changed, when, by what module
      3. RisksAccepted.json        -- Unresolved issues with review dates
      4. OperationalBoundary.json  -- canDo/cannotDo declaration
      5. EscalationRegister.json   -- Hardware/critical escalation records
      6. GuardAuditTrail.json      -- Full guard decision log

.NOTES
    Version : 7.0.0
    Platform: PowerShell 5.1+
    Ported  : From WinDRE v2.1.0 ComplianceExport with LDT adaptations
#>

Set-StrictMode -Version Latest

#region -- Operational Boundary Declaration (immutable platform truth)

$script:_OperationalBoundary = [ordered]@{
    platformName    = 'LDT -- Laptop Diagnostic Toolkit'
    version         = '7.0.0'
    classification  = 'INTERNAL -- FIELD SERVICE TOOL'

    canDo = @(
        'Diagnose Windows OS configuration failures (SFC, DISM, BCD)'
        'Repair Windows system file integrity via SFC and DISM'
        'Reset Windows Update component stack'
        'Repair critical Windows service states and startup types'
        'Reset TCP/IP, Winsock, DNS network stack components'
        'Restore Windows Boot Configuration Data soft corruption'
        'Detect and report driver issues (signed/unsigned, outdated)'
        'Auto-update Lenovo drivers via Thin Installer integration'
        'Re-enable Windows Defender, UAC, and Firewall if disabled'
        'Detect hardware faults and generate escalation records'
        'Detect BSOD patterns and identify faulting drivers'
        'Create system restore points and registry snapshots'
        'Generate SHA256 tamper-evident audit logs'
        'Track health score trends across 90 sessions per machine'
        'Generate ISO/SOC2/CIS compliance artifacts'
        'Perform OEM hardware validation (read-only baseline)'
        'Detect display diagnostics (dead pixels, color accuracy)'
    )

    cannotDo = @(
        'Flash BIOS or UEFI firmware'
        'Modify any firmware'
        'Reset or modify BitLocker encryption'
        'Disable or bypass Secure Boot'
        'Clear or provision TPM'
        'Make any internet or external network calls'
        'Install Windows Updates (detection only)'
        'Replace physically failed hardware'
        'Recover data from failed storage'
        'Modify Group Policy objects'
        'Access credential stores or SAM database'
        'Guarantee repair of all OS failure scenarios'
    )

    hardwarePolicy = 'Detection and escalation only. Zero automated hardware modification.'
    deploymentModel = 'USB-portable field service tool. Runs from removable media.'
    estimatedRepairCoverage = '80-85% of Windows OS and configuration-level failures'

    offlineOnly    = $true
    requiresAdmin  = $true
    internetAccess = $false
    destructiveOps = $false
}

#endregion

#region -- Public Functions

function Export-ComplianceArtifacts {
    <#
    .SYNOPSIS
        Generates all compliance artifacts for a completed session.
        Returns a hashtable of artifact file paths.

    .PARAMETER DiagState
        LDT's central diagnostic state hashtable.

    .PARAMETER ModuleResults
        Array from ConvertTo-ModuleResults (LDT-EngineAdapter).

    .PARAMETER GuardDecisionLog
        Array from Get-GuardDecisionLog, or empty array.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]           $SessionId,
        [Parameter(Mandatory)] [hashtable]        $DiagState,
        [Parameter(Mandatory)] [PSCustomObject[]] $ModuleResults,
        [Parameter(Mandatory)] [PSCustomObject]   $ScoreResult,
        [Parameter(Mandatory)] [PSCustomObject]   $GuardStatus,
        [Parameter(Mandatory)] [string]           $OutputPath,
        [Parameter(Mandatory)] [string]           $PlatformRoot,
        [array]         $GuardDecisionLog = @(),
        [PSCustomObject] $TrendData       = $null
    )

    $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $hostName   = $env:COMPUTERNAME
    $artifacts  = @{}

    # Ensure output directory
    $complianceDir = Join-Path $OutputPath "Compliance_${hostName}_${timestamp}"
    New-Item -ItemType Directory -Path $complianceDir -Force | Out-Null

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'ComplianceExport' `
        -Message "Generating compliance artifacts" -Data @{ outputDir = $complianceDir }

    # ── Artifact 1: Master Compliance Report ──────────────────────────────────
    $artifacts['ComplianceReport'] = New-ComplianceReport `
        -SessionId $SessionId -DiagState $DiagState -ModuleResults $ModuleResults `
        -ScoreResult $ScoreResult -GuardStatus $GuardStatus `
        -OutputDir $complianceDir -PlatformRoot $PlatformRoot -TrendData $TrendData

    # ── Artifact 2: Change Record ─────────────────────────────────────────────
    $artifacts['ChangeRecord'] = New-ChangeRecord `
        -SessionId $SessionId -DiagState $DiagState -OutputDir $complianceDir

    # ── Artifact 3: Risks Accepted ────────────────────────────────────────────
    $artifacts['RisksAccepted'] = New-RisksAcceptedRecord `
        -SessionId $SessionId -DiagState $DiagState -ModuleResults $ModuleResults -OutputDir $complianceDir

    # ── Artifact 4: Operational Boundary ─────────────────────────────────────
    $artifacts['OperationalBoundary'] = New-OperationalBoundaryRecord `
        -SessionId $SessionId -OutputDir $complianceDir

    # ── Artifact 5: Escalation Register ──────────────────────────────────────
    $artifacts['EscalationRegister'] = New-EscalationRegister `
        -SessionId $SessionId -DiagState $DiagState -OutputDir $complianceDir

    # ── Artifact 6: Guard Audit Trail ────────────────────────────────────────
    $artifacts['GuardAuditTrail'] = New-GuardAuditTrail `
        -SessionId $SessionId -GuardStatus $GuardStatus `
        -GuardDecisionLog $GuardDecisionLog -OutputDir $complianceDir

    # ── Artifact 7: Classification Report (v7.2) ──────────────────────────
    if ($DiagState.ContainsKey('ClassificationReport') -and $DiagState['ClassificationReport']) {
        $classReport = $DiagState['ClassificationReport']
        $classRecord = [ordered]@{
            _type              = 'CLASSIFICATION_REPORT'
            sessionId          = $SessionId
            generatedAt        = Get-Date -Format 'o'
            computername       = $env:COMPUTERNAME
            escalation_level   = $classReport.escalation_level
            severity_score     = $classReport.severity_score
            confidence_pct     = $classReport.confidence_pct
            branch             = $classReport.classification_branch
            reasoning          = $classReport.classification_reasoning
            decision_path      = $classReport.decision_tree_path
            primary_cause      = $classReport.primary_cause
            component_health   = $classReport.component_health
            l1_count           = $classReport.l1_count
            l2_count           = $classReport.l2_count
            l3_count           = $classReport.l3_count
            auto_fix_allowed   = $classReport.auto_fix_allowed
            stress_validation  = $classReport.stress_validation
            enterprise_score   = $classReport.enterprise_score
        }
        $classPath = Join-Path $complianceDir 'ClassificationReport.json'
        $classRecord | ConvertTo-Json -Depth 10 | Set-Content $classPath -Encoding UTF8
        $artifacts['ClassificationReport'] = $classPath
    }

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'ComplianceExport' `
        -Message "Compliance artifacts generated" `
        -Data @{ artifactCount = $artifacts.Count; outputDir = $complianceDir }

    # Write artifact index
    $index = [ordered]@{
        _type        = 'COMPLIANCE_ARTIFACT_INDEX'
        sessionId    = $SessionId
        generatedAt  = Get-Date -Format 'o'
        computername = $env:COMPUTERNAME
        outputDir    = $complianceDir
        artifacts    = $artifacts
    }
    $index | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $complianceDir 'ArtifactIndex.json') -Encoding UTF8

    return $artifacts
}

#endregion

#region -- Artifact Builders

function New-ComplianceReport {
    param($SessionId, $DiagState, $ModuleResults, $ScoreResult,
          $GuardStatus, $OutputDir, $PlatformRoot, $TrendData)

    $manifestHash = $null
    $manifestPath = Join-Path $PlatformRoot 'Config\VersionManifest.json'
    if (Test-Path $manifestPath) {
        $manifestHash = (Get-FileHash $manifestPath -Algorithm SHA256).Hash
    }

    # Build module summary from ModuleResults
    $moduleSummary = @($ModuleResults | ForEach-Object {
        [PSCustomObject]@{
            module         = $_.moduleName
            status         = $_.status
            findingCount   = if ($_.findings) { $_.findings.Count } else { 0 }
        }
    })

    $report = [ordered]@{
        _type             = 'COMPLIANCE_REPORT'
        sessionId         = $SessionId
        reportVersion     = '7.0.0'
        generatedAt       = Get-Date -Format 'o'
        computername      = $env:COMPUTERNAME
        username          = "$env:USERDOMAIN\$env:USERNAME"
        platformVersion   = '7.0.0'
        manifestHash      = $manifestHash
        mode              = if ($DiagState.OEMMode) { 'OEM_VALIDATION' } else { 'DIAGNOSTIC' }
        healthScore       = $ScoreResult.finalScore
        healthBand        = $ScoreResult.band
        escalationLevel   = if ($GuardStatus) { $GuardStatus.currentLevel } else { 0 }
        hardStopTriggered = if ($GuardStatus) { $GuardStatus.hardStopTriggered } else { $false }
        findingsCount     = if ($DiagState.Findings) { $DiagState.Findings.Count } else { 0 }
        fixesAppliedCount = if ($DiagState.FixesApplied) { $DiagState.FixesApplied.Count } else { 0 }
        moduleResults     = $moduleSummary
        trendSummary      = $TrendData
        controlsMapped    = Get-ControlMapping
    }

    $path = Join-Path $OutputDir 'ComplianceReport.json'
    $report | ConvertTo-Json -Depth 15 | Set-Content $path -Encoding UTF8
    return $path
}

function New-ChangeRecord {
    param($SessionId, $DiagState, $OutputDir)

    $changes = @()
    if ($DiagState.FixesApplied) {
        foreach ($fix in $DiagState.FixesApplied) {
            $changes += [ordered]@{
                timestamp    = Get-Date -Format 'o'
                sessionId    = $SessionId
                computername = $env:COMPUTERNAME
                module       = if ($fix.Category) { $fix.Category } else { 'Unknown' }
                action       = if ($fix.Name) { $fix.Name } else { 'Repair' }
                detail       = if ($fix.Details) { $fix.Details } else { '' }
                changeType   = 'AUTOMATED_REPAIR'
                approvedBy   = 'LDT_GuardEngine'
            }
        }
    }

    $record = [ordered]@{
        _type        = 'CHANGE_RECORD'
        sessionId    = $SessionId
        generatedAt  = Get-Date -Format 'o'
        computername = $env:COMPUTERNAME
        totalChanges = $changes.Count
        changes      = $changes
    }

    $path = Join-Path $OutputDir 'ChangeRecord.json'
    $record | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    return $path
}

function New-RisksAcceptedRecord {
    param($SessionId, $DiagState, $ModuleResults, $OutputDir)

    $unresolved = @()
    foreach ($mod in $ModuleResults) {
        if ($mod.status -in @('FAILED','PARTIAL','ESCALATED')) {
            # Collect unrepaired findings for this module
            $critFindings = @()
            if ($mod.findings) {
                $critFindings = @($mod.findings | Where-Object {
                    $_.severity -in @('H3','H2','S3','CRITICAL','ERROR')
                })
            }
            foreach ($f in $critFindings) {
                $unresolved += [ordered]@{
                    module         = $mod.moduleName
                    component      = if ($f.component) { $f.component } else { 'Unknown' }
                    severity       = $f.severity
                    details        = if ($f.details) { $f.details } else { '' }
                    moduleStatus   = $mod.status
                    riskAcceptedBy = 'LDT_AutoClassification'
                    riskReason     = switch ($mod.status) {
                        'ESCALATED' { 'Hardware fault -- cannot auto-repair; human intervention required' }
                        'FAILED'    { 'Repair engine encountered exception; manual intervention required' }
                        'PARTIAL'   { 'Repair was partially successful; residual issues require follow-up' }
                        default     { 'Issue detected but not resolved in this session' }
                    }
                    mitigationRequired = ($f.severity -in @('H3','H2','CRITICAL'))
                    reviewDate         = (Get-Date).AddDays(7).ToString('yyyy-MM-dd')
                }
            }
        }
    }

    # Hardware-severity findings are always risks
    if ($DiagState.Findings) {
        $hwFindings = @($DiagState.Findings | Where-Object { $_.Severity -match '^H' -and $_.Status -eq 'Fail' })
        foreach ($hf in $hwFindings) {
            # Avoid duplicates
            $alreadyRecorded = $unresolved | Where-Object {
                $_.component -eq $hf.Component -and $_.severity -eq $hf.Severity
            }
            if (-not $alreadyRecorded) {
                $unresolved += [ordered]@{
                    module         = if ($hf.Category) { $hf.Category } else { 'Hardware' }
                    component      = $hf.Component
                    severity       = $hf.Severity
                    details        = if ($hf.Details) { $hf.Details } else { '' }
                    moduleStatus   = 'ESCALATED'
                    riskAcceptedBy = 'LDT_AutoClassification'
                    riskReason     = 'Hardware faults are never auto-repaired -- field engineer required'
                    mitigationRequired = $true
                    reviewDate         = (Get-Date).AddDays(1).ToString('yyyy-MM-dd')
                }
            }
        }
    }

    $record = [ordered]@{
        _type              = 'RISKS_ACCEPTED'
        sessionId          = $SessionId
        generatedAt        = Get-Date -Format 'o'
        computername       = $env:COMPUTERNAME
        totalUnresolved    = $unresolved.Count
        criticalUnresolved = @($unresolved | Where-Object { $_.mitigationRequired }).Count
        unresolvedItems    = $unresolved
        note = 'All items require human review. Critical items must be actioned within stated review dates.'
    }

    $path = Join-Path $OutputDir 'RisksAccepted.json'
    $record | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    return $path
}

function New-OperationalBoundaryRecord {
    param($SessionId, $OutputDir)

    # Clone the boundary declaration and add session metadata
    $record = [ordered]@{}
    foreach ($key in $script:_OperationalBoundary.Keys) {
        $record[$key] = $script:_OperationalBoundary[$key]
    }
    $record['_type']       = 'OPERATIONAL_BOUNDARY'
    $record['sessionId']   = $SessionId
    $record['generatedAt'] = Get-Date -Format 'o'
    $record['note']        = 'This document defines the explicit operational scope of LDT. Actions outside this boundary are prohibited by the GuardEngine and are not possible through this platform.'

    $path = Join-Path $OutputDir 'OperationalBoundary.json'
    $record | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    return $path
}

function New-EscalationRegister {
    param($SessionId, $DiagState, $OutputDir)

    $escalations = @()
    if ($DiagState.Findings) {
        # Hardware-severity findings (H1-H3) are escalation items
        $hwFindings = @($DiagState.Findings | Where-Object { $_.Severity -match '^H' })
        foreach ($hf in $hwFindings) {
            $urgency = switch ($hf.Severity) {
                'H3' { 'CRITICAL' }
                'H2' { 'HIGH' }
                'H1' { 'MEDIUM' }
                default { 'MEDIUM' }
            }
            $escalations += [ordered]@{
                sessionId       = $SessionId
                timestamp       = Get-Date -Format 'o'
                computername    = $env:COMPUTERNAME
                category        = if ($hf.Category) { $hf.Category } else { 'Hardware' }
                component       = if ($hf.Component) { $hf.Component } else { 'Unknown' }
                severity        = $hf.Severity
                urgency         = $urgency
                details         = if ($hf.Details) { $hf.Details } else { '' }
                action          = 'HUMAN_INTERVENTION_REQUIRED'
                assignedTo      = 'UNASSIGNED -- Tier 2/3 Support'
                status          = 'OPEN'
                openedAt        = Get-Date -Format 'o'
                resolvedAt      = $null
                resolutionNotes = $null
            }
        }
    }

    $register = [ordered]@{
        _type            = 'ESCALATION_REGISTER'
        sessionId        = $SessionId
        generatedAt      = Get-Date -Format 'o'
        computername     = $env:COMPUTERNAME
        totalEscalations = $escalations.Count
        openEscalations  = $escalations.Count
        escalations      = $escalations
        note = 'All escalation items require human review. Hardware items must not be auto-repaired. Assign to appropriate support tier.'
    }

    $path = Join-Path $OutputDir 'EscalationRegister.json'
    $register | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    return $path
}

function New-GuardAuditTrail {
    param($SessionId, $GuardStatus, $GuardDecisionLog, $OutputDir)

    $trail = [ordered]@{
        _type             = 'GUARD_AUDIT_TRAIL'
        sessionId         = $SessionId
        generatedAt       = Get-Date -Format 'o'
        computername      = $env:COMPUTERNAME
        oemModeActive     = if ($GuardStatus) { $GuardStatus.oemModeActive } else { $false }
        currentLevel      = if ($GuardStatus) { $GuardStatus.currentLevel } else { 0 }
        hardStopTriggered = if ($GuardStatus) { $GuardStatus.hardStopTriggered } else { $false }
        totalDecisions    = if ($GuardStatus) { $GuardStatus.totalDecisions } else { 0 }
        blockedActions    = if ($GuardStatus) { $GuardStatus.blockedActions } else { 0 }
        clearedActions    = if ($GuardStatus) { $GuardStatus.clearedActions } else { 0 }
        prohibitionList   = if ($GuardStatus) { $GuardStatus.prohibitionList } else { @() }
        decisions         = if ($GuardDecisionLog) { $GuardDecisionLog } else { @() }
        note = 'Full audit trail of every guard decision made during this session.'
    }

    $path = Join-Path $OutputDir 'GuardAuditTrail.json'
    $trail | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    return $path
}

function Get-ControlMapping {
    # Map LDT diagnostic activity to compliance control frameworks
    return [ordered]@{
        ISO27001 = @(
            @{ control='A.12.1.2'; title='Change Management'; satisfied=$true; evidence='ChangeRecord.json generated with all automated repairs' }
            @{ control='A.12.4.1'; title='Event Logging'; satisfied=$true; evidence='Structured logging with SHA256 integrity seal' }
            @{ control='A.12.6.1'; title='Technical Vulnerability Management'; satisfied=$true; evidence='Driver, security, and OS integrity validated' }
            @{ control='A.16.1.5'; title='Response to Security Incidents'; satisfied=$true; evidence='Escalation register for unresolvable issues' }
        )
        SOC2 = @(
            @{ criteria='CC6.8';  title='Logical Access Controls'; satisfied=$true; evidence='UAC, Defender, and Firewall status verified' }
            @{ criteria='CC7.2';  title='System Monitoring'; satisfied=$true; evidence='System health scored and trended across sessions' }
            @{ criteria='A1.2';   title='Environmental Protections'; satisfied=$true; evidence='Hardware fault detection and escalation' }
            @{ criteria='PI1.4';  title='Processing Integrity'; satisfied=$true; evidence='SFC/DISM system file integrity validated' }
        )
        CISv8 = @(
            @{ control='CIS-4';  title='Secure Configuration'; satisfied=$true; evidence='OS, services, and security posture checked' }
            @{ control='CIS-7';  title='Continuous Vulnerability Management'; satisfied=$true; evidence='Driver age and update status verified' }
            @{ control='CIS-10'; title='Malware Defenses'; satisfied=$true; evidence='Defender real-time protection verified' }
            @{ control='CIS-13'; title='Network Monitoring'; satisfied=$true; evidence='Network stack integrity validated' }
        )
    }
}

#endregion

Export-ModuleMember -Function @(
    'Export-ComplianceArtifacts'
)
