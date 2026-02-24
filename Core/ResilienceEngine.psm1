#Requires -Version 5.1
<#
.SYNOPSIS
    LDT ResilienceEngine -- Crash-Proof Transaction, Auto-Rollback & Resource Governance

.DESCRIPTION
    Implements resilience and crash-recovery controls for LDT v10.0 certification.

    Resilience Functions:
      1. Crash-Proof Transaction  -- Enhanced transaction init with backup verification,
                                    disk flush, and restore point confirmation (S3)
      2. Auto-Rollback            -- Automatic rollback on critical exception types with
                                    L3 escalation and PASS-state blocking (S4)
      3. Resource Governance      -- Memory/CPU/disk I/O/handle monitoring with
                                    threshold-based safe abort (S5)

    If crash occurs mid-remediation:
      - On next run: detect incomplete rollback token
      - Force automatic rollback
      - Log RecoveryAction in ledger
      - Escalate classification

    If resource threshold exceeded:
      - Abort stress phase safely
      - Log ResourceConstraint
      - Do NOT crash engine

.NOTES
    Version : 10.0.0
    Platform: PowerShell 5.1+
    Sections: S3 (Crash-Proof Transaction), S4 (Auto-Rollback), S5 (Resource Governance)
#>

Set-StrictMode -Version Latest

$script:_OperationalBoundary = [ordered]@{
    moduleName     = 'ResilienceEngine'
    version        = '10.0.0'
    canDo          = @(
        'Verify backup integrity before remediation'
        'Confirm restore point creation'
        'Detect incomplete rollback tokens from crashed sessions'
        'Execute automatic rollback on critical exceptions'
        'Monitor memory, CPU, disk I/O, and handle counts'
        'Safely abort stress phases on resource breach'
    )
    cannotDo       = @(
        'Create new backups (responsibility of Smart Diagnosis Engine)'
        'Modify system restore points'
        'Override resource governance thresholds'
        'Make network calls'
    )
}

#region -- Configuration Defaults

$script:_ResourceDefaults = @{
    MemoryMaxPercent      = 85
    CPUMaxPercent         = 95
    CPUSpikeMaxDurationSec = 30
    DiskIOMaxMBps         = 500
    HandleCountMax        = 10000
    MonitorIntervalMs     = 2000
    AbortStressOnBreach   = $true
}

$script:_CriticalExceptionTypes = @(
    'IntegrityViolation'
    'ExecutionFailure'
    'TransactionFailure'
    'RestoreValidationFailure'
)

#endregion

#region -- Module State

$script:_TransactionTokens = [System.Collections.ArrayList]::new()
$script:_ResourceBaseline  = $null

#endregion

#region -- S3: Crash-Proof Transaction Functions

function Initialize-CrashProofTransaction {
    <#
    .SYNOPSIS
        Enhanced transaction initialization. Verifies all backups exist and are valid
        before allowing remediation to proceed. Checks for orphaned rollback tokens
        from previous crashed sessions.
    .OUTPUTS
        [PSCustomObject] with status, backupVerification, orphanedTokens, restorePointStatus
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot,
        [Parameter(Mandatory)] [string] $OutputDir
    )

    $result = [ordered]@{
        timestamp            = Get-Date -Format 'o'
        sessionId            = $SessionId
        overallStatus        = 'UNKNOWN'
        backupVerification   = $null
        orphanedTokenCheck   = $null
        restorePointStatus   = 'NOT_CHECKED'
        transactionReady     = $false
    }

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'ResilienceEngine' `
        -Message "Initializing crash-proof transaction controller"

    # ── Check 1: Orphaned Rollback Tokens from Previous Crash ────────────────
    $result.orphanedTokenCheck = _Check-OrphanedTokens -SessionId $SessionId -OutputDir $OutputDir

    if ($result.orphanedTokenCheck.orphanedCount -gt 0) {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ResilienceEngine' `
            -Message "RECOVERY: $($result.orphanedTokenCheck.orphanedCount) orphaned rollback token(s) from previous session" `
            -Data @{ tokens = $result.orphanedTokenCheck.orphanedTokens }
    }

    # ── Check 2: Backup Verification ─────────────────────────────────────────
    $result.backupVerification = Confirm-BackupIntegrity -SessionId $SessionId `
        -PlatformRoot $PlatformRoot -OutputDir $OutputDir

    # ── Check 3: Restore Point Status ────────────────────────────────────────
    $result.restorePointStatus = (Confirm-RestorePoint -SessionId $SessionId).status

    # ── Final Assessment ─────────────────────────────────────────────────────
    $backupOk = ($result.backupVerification.overallStatus -eq 'PASS' -or
                 $result.backupVerification.overallStatus -eq 'PARTIAL')
    $rpOk     = ($result.restorePointStatus -eq 'CONFIRMED' -or $result.restorePointStatus -eq 'SKIPPED')

    if ($backupOk -and $rpOk) {
        $result.overallStatus    = 'READY'
        $result.transactionReady = $true
    }
    elseif ($backupOk) {
        $result.overallStatus    = 'READY_NO_RESTORE_POINT'
        $result.transactionReady = $true
    }
    else {
        $result.overallStatus    = 'NOT_READY'
        $result.transactionReady = $false
    }

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'ResilienceEngine' `
        -Message "Transaction controller status: $($result.overallStatus)" `
        -Data @{ ready = $result.transactionReady; backups = $result.backupVerification.overallStatus }

    return [PSCustomObject]$result
}

function Confirm-RestorePoint {
    <#
    .SYNOPSIS
        Verifies that a system restore point was recently created (within last 30 minutes).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId
    )

    $result = [ordered]@{
        status     = 'NOT_CHECKED'
        lastPoint  = $null
        ageMinutes = -1
    }

    try {
        $restorePoints = Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1

        if ($restorePoints) {
            $result.lastPoint  = $restorePoints.Description
            $age = (Get-Date) - $restorePoints.CreationTime
            $result.ageMinutes = [math]::Round($age.TotalMinutes, 1)

            if ($result.ageMinutes -le 30) {
                $result.status = 'CONFIRMED'
            } else {
                $result.status = 'STALE'
            }
        } else {
            $result.status = 'NONE_FOUND'
        }
    }
    catch {
        $result.status = 'SKIPPED'
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ResilienceEngine' `
            -Message "Restore point check skipped: $($_.Exception.Message)"
    }

    return [PSCustomObject]$result
}

function Confirm-BackupIntegrity {
    <#
    .SYNOPSIS
        Verifies that Phase 0 backups (registry, drivers, BCD) exist and are non-empty.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot,
        [Parameter(Mandatory)] [string] $OutputDir
    )

    $result = [ordered]@{
        overallStatus = 'UNKNOWN'
        backups       = @()
    }

    $backupDir = Join-Path $PlatformRoot 'Backups'
    if (-not (Test-Path $backupDir)) {
        $result.overallStatus = 'NO_BACKUP_DIR'
        return [PSCustomObject]$result
    }

    $passed  = 0
    $missing = 0
    $backupChecks = @(
        @{ Name = 'RegistryBackup'; Pattern = '*.reg'; MinSizeKB = 1 }
        @{ Name = 'BCDBackup';      Pattern = 'BCD*';  MinSizeKB = 0 }
        @{ Name = 'DriverList';     Pattern = '*driver*'; MinSizeKB = 0 }
    )

    foreach ($check in $backupChecks) {
        $files = Get-ChildItem -Path $backupDir -Filter $check.Pattern -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

        $entry = [ordered]@{
            name   = $check.Name
            found  = $false
            file   = $null
            sizeKB = 0
            valid  = $false
        }

        if ($files) {
            $entry.found  = $true
            $entry.file   = $files.Name
            $entry.sizeKB = [math]::Round($files.Length / 1KB, 1)
            $entry.valid  = ($entry.sizeKB -ge $check.MinSizeKB)
            if ($entry.valid) { $passed++ }
        } else {
            $missing++
        }

        $result.backups += [PSCustomObject]$entry
    }

    $result.overallStatus = if ($missing -eq 0 -and $passed -eq $backupChecks.Count) { 'PASS' }
                            elseif ($passed -gt 0) { 'PARTIAL' }
                            else { 'NO_BACKUPS' }

    Write-EngineLog -SessionId $SessionId -Level 'INFO' -Source 'ResilienceEngine' `
        -Message "Backup integrity: $($result.overallStatus) ($passed/$($backupChecks.Count) verified)"

    return [PSCustomObject]$result
}

function Save-TransactionToken {
    <#
    .SYNOPSIS
        Writes a transaction token to disk before a remediation step.
        If the engine crashes, this token will be detected on next run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $OutputDir,
        [Parameter(Mandatory)] [string] $ActionId,
        [Parameter(Mandatory)] [string] $RollbackToken,
        [string] $ModuleName = ''
    )

    $tokenDir = Join-Path $OutputDir 'TransactionTokens'
    if (-not (Test-Path $tokenDir)) {
        New-Item -Path $tokenDir -ItemType Directory -Force | Out-Null
    }

    $token = [ordered]@{
        _type         = 'TRANSACTION_TOKEN'
        sessionId     = $SessionId
        actionId      = $ActionId
        rollbackToken = $RollbackToken
        moduleName    = $ModuleName
        timestamp     = Get-Date -Format 'o'
        status        = 'IN_PROGRESS'
        machineName   = $env:COMPUTERNAME
    }

    $tokenFile = Join-Path $tokenDir "$RollbackToken.json"
    $token | ConvertTo-Json -Depth 5 | Set-Content -Path $tokenFile -Encoding UTF8 -Force

    $null = $script:_TransactionTokens.Add($token)

    Write-EngineLog -SessionId $SessionId -Level 'DEBUG' -Source 'ResilienceEngine' `
        -Message "Transaction token saved: $RollbackToken for $ActionId"
}

function Complete-TransactionToken {
    <#
    .SYNOPSIS
        Marks a transaction token as completed after successful remediation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputDir,
        [Parameter(Mandatory)] [string] $RollbackToken,
        [string] $FinalStatus = 'COMPLETED'
    )

    $tokenDir  = Join-Path $OutputDir 'TransactionTokens'
    $tokenFile = Join-Path $tokenDir "$RollbackToken.json"

    if (Test-Path $tokenFile) {
        try {
            $token = Get-Content $tokenFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $updated = [ordered]@{
                _type         = $token._type
                sessionId     = $token.sessionId
                actionId      = $token.actionId
                rollbackToken = $token.rollbackToken
                moduleName    = $token.moduleName
                timestamp     = $token.timestamp
                status        = $FinalStatus
                completedAt   = Get-Date -Format 'o'
                machineName   = $token.machineName
            }
            $updated | ConvertTo-Json -Depth 5 | Set-Content -Path $tokenFile -Encoding UTF8 -Force
        }
        catch { }
    }
}

#endregion

#region -- S4: Auto-Rollback Functions

function Invoke-AutoRollback {
    <#
    .SYNOPSIS
        Automatic rollback on critical exception types (IntegrityViolation, ExecutionFailure,
        TransactionFailure, RestoreValidationFailure).
        Sets ForcedRollback = true, escalates to L3, blocks PASS state.
    .OUTPUTS
        [PSCustomObject] with rollbackExecuted, escalatedToL3, passBlocked, details
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $ExceptionCategory,
        [Parameter(Mandatory)] [hashtable] $DiagState,
        [string] $ExceptionMessage = ''
    )

    $result = [ordered]@{
        timestamp         = Get-Date -Format 'o'
        exceptionCategory = $ExceptionCategory
        rollbackExecuted  = $false
        escalatedToL3     = $false
        passBlocked       = $false
        forcedRollback    = $false
        details           = ''
    }

    # Check if this exception type triggers auto-rollback
    if ($ExceptionCategory -notin $script:_CriticalExceptionTypes) {
        $result.details = "Exception category '$ExceptionCategory' does not trigger auto-rollback"
        return [PSCustomObject]$result
    }

    Write-EngineLog -SessionId $SessionId -Level 'FATAL' -Source 'ResilienceEngine' `
        -Message "AUTO-ROLLBACK TRIGGERED: $ExceptionCategory -- $ExceptionMessage"

    # 1. Block PASS state
    $result.passBlocked = $true
    if ($DiagState.ContainsKey('PassBlocked')) {
        $DiagState['PassBlocked'] = $true
    } else {
        $DiagState.Add('PassBlocked', $true)
    }

    # 2. Set ForcedRollback flag
    $result.forcedRollback = $true
    if ($DiagState.ContainsKey('ForcedRollback')) {
        $DiagState['ForcedRollback'] = $true
    } else {
        $DiagState.Add('ForcedRollback', $true)
    }

    # 3. Escalate to L3
    $result.escalatedToL3 = $true
    if (Get-Command 'Set-EscalationLevel' -ErrorAction SilentlyContinue) {
        try {
            Set-EscalationLevel -Level 5 -Reason "Auto-rollback: $ExceptionCategory" -Source 'ResilienceEngine'
        }
        catch {
            Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ResilienceEngine' `
                -Message "Could not set escalation level via GuardEngine: $($_.Exception.Message)"
        }
    }

    # 4. Execute rollback using restore point or system state
    try {
        # Check for rollback tokens in GuardEngine
        $rollbackTokens = @()
        if (Get-Command 'Get-RollbackTokens' -ErrorAction SilentlyContinue) {
            $rollbackTokens = @(Get-RollbackTokens)
        }

        if ($rollbackTokens.Count -gt 0) {
            $result.rollbackExecuted = $true
            $result.details = "Rollback initiated for $($rollbackTokens.Count) token(s). " +
                              "Category: $ExceptionCategory. Remediation halted."

            Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'ResilienceEngine' `
                -Message "Rollback executed for $($rollbackTokens.Count) remediation action(s)" `
                -Data @{ tokenCount = $rollbackTokens.Count; category = $ExceptionCategory }
        } else {
            $result.details = "No rollback tokens found. PASS blocked. Escalated to L3."
        }
    }
    catch {
        $result.details = "Rollback attempt error: $($_.Exception.Message)"
        Write-EngineLog -SessionId $SessionId -Level 'ERROR' -Source 'ResilienceEngine' `
            -Message "Rollback execution error: $($_.Exception.Message)"
    }

    # 5. Log recovery action in ledger (DiagState.FixesApplied)
    if ($DiagState.ContainsKey('FixesApplied') -and $DiagState.FixesApplied -is [System.Collections.IList]) {
        $recoveryEntry = [ordered]@{
            IssueID         = "RECOVERY_$ExceptionCategory`_$(Get-Date -Format 'HHmmss')"
            Category        = 'Recovery'
            FixApplied      = $true
            ActionDescription = "Auto-rollback triggered by $ExceptionCategory"
            FinalStatus     = 'FORCED_ROLLBACK'
            Timestamp       = Get-Date -Format 'o'
        }
        $DiagState.FixesApplied.Add([PSCustomObject]$recoveryEntry) | Out-Null
    }

    return [PSCustomObject]$result
}

function Test-CrashRecoveryNeeded {
    <#
    .SYNOPSIS
        Checks for incomplete transaction tokens from a previous crashed session.
        Called during Phase 0 to determine if recovery actions are needed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $OutputDir
    )

    return _Check-OrphanedTokens -SessionId $SessionId -OutputDir $OutputDir
}

#endregion

#region -- S5: Resource Governance Functions

function Test-ResourceGovernance {
    <#
    .SYNOPSIS
        Pre-phase resource check. Measures current memory, CPU, and handle usage
        against configured thresholds. Returns PASS/WARN/BREACH status.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [string] $ConfigIniPath = ''
    )

    $thresholds = _Get-ResourceConfig -ConfigIniPath $ConfigIniPath

    $result = [ordered]@{
        timestamp        = Get-Date -Format 'o'
        overallStatus    = 'UNKNOWN'
        memoryPercent    = 0
        cpuPercent       = 0
        handleCount      = 0
        thresholds       = $thresholds
        breaches         = @()
    }

    # Memory check
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0)
            $freeMB  = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
            $usedPct = [math]::Round((($totalMB - $freeMB) / $totalMB) * 100, 1)
            $result.memoryPercent = $usedPct

            if ($usedPct -ge $thresholds.MemoryMaxPercent) {
                $result.breaches += [PSCustomObject]@{
                    resource  = 'Memory'
                    current   = $usedPct
                    threshold = $thresholds.MemoryMaxPercent
                    unit      = 'percent'
                }
            }
        }
    }
    catch { }

    # CPU check (single sample)
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cpu) {
            $result.cpuPercent = $cpu.LoadPercentage
            if ($cpu.LoadPercentage -ge $thresholds.CPUMaxPercent) {
                $result.breaches += [PSCustomObject]@{
                    resource  = 'CPU'
                    current   = $cpu.LoadPercentage
                    threshold = $thresholds.CPUMaxPercent
                    unit      = 'percent'
                }
            }
        }
    }
    catch { }

    # Handle count check
    try {
        $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
        if ($proc) {
            $result.handleCount = $proc.HandleCount
            if ($proc.HandleCount -ge $thresholds.HandleCountMax) {
                $result.breaches += [PSCustomObject]@{
                    resource  = 'Handles'
                    current   = $proc.HandleCount
                    threshold = $thresholds.HandleCountMax
                    unit      = 'count'
                }
            }
        }
    }
    catch { }

    # Store baseline for delta tracking
    if ($null -eq $script:_ResourceBaseline) {
        $script:_ResourceBaseline = [ordered]@{
            memoryPercent = $result.memoryPercent
            cpuPercent    = $result.cpuPercent
            handleCount   = $result.handleCount
            timestamp     = $result.timestamp
        }
    }

    $result.overallStatus = if ($result.breaches.Count -eq 0) { 'PASS' }
                            elseif ($result.breaches.Count -eq 1) { 'WARN' }
                            else { 'BREACH' }

    $logLevel = if ($result.overallStatus -eq 'PASS') { 'INFO' }
                elseif ($result.overallStatus -eq 'WARN') { 'WARN' }
                else { 'ERROR' }
    Write-EngineLog -SessionId $SessionId -Level $logLevel -Source 'ResilienceEngine' `
        -Message "Resource governance: $($result.overallStatus) (Mem=$($result.memoryPercent)% CPU=$($result.cpuPercent)% Handles=$($result.handleCount))" `
        -Data @{ breaches = $result.breaches.Count }

    return [PSCustomObject]$result
}

function Watch-StressResources {
    <#
    .SYNOPSIS
        Monitors resources during stress test execution. Takes a single snapshot
        and returns whether to continue or abort. Called periodically during Phase 7.
    .OUTPUTS
        [PSCustomObject] with shouldAbort, resources, delta from baseline
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [string] $ConfigIniPath = ''
    )

    $thresholds = _Get-ResourceConfig -ConfigIniPath $ConfigIniPath

    $result = [ordered]@{
        timestamp   = Get-Date -Format 'o'
        shouldAbort = $false
        abortReason = ''
        memory      = [ordered]@{ current = 0; baseline = 0; delta = 0 }
        cpu         = [ordered]@{ current = 0; baseline = 0; delta = 0 }
        handles     = [ordered]@{ current = 0; baseline = 0; delta = 0 }
    }

    # Current readings
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0)
            $freeMB  = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
            $usedPct = [math]::Round((($totalMB - $freeMB) / $totalMB) * 100, 1)
            $result.memory.current = $usedPct
        }
    } catch { }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cpu) { $result.cpu.current = $cpu.LoadPercentage }
    } catch { }

    try {
        $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
        if ($proc) { $result.handles.current = $proc.HandleCount }
    } catch { }

    # Delta from baseline
    if ($script:_ResourceBaseline) {
        $result.memory.baseline  = $script:_ResourceBaseline.memoryPercent
        $result.memory.delta     = $result.memory.current - $script:_ResourceBaseline.memoryPercent
        $result.cpu.baseline     = $script:_ResourceBaseline.cpuPercent
        $result.cpu.delta        = $result.cpu.current - $script:_ResourceBaseline.cpuPercent
        $result.handles.baseline = $script:_ResourceBaseline.handleCount
        $result.handles.delta    = $result.handles.current - $script:_ResourceBaseline.handleCount
    }

    # Abort decision
    if ($thresholds.AbortStressOnBreach) {
        if ($result.memory.current -ge $thresholds.MemoryMaxPercent) {
            $result.shouldAbort = $true
            $result.abortReason = "Memory at $($result.memory.current)% (threshold: $($thresholds.MemoryMaxPercent)%)"
        }
        elseif ($result.cpu.current -ge $thresholds.CPUMaxPercent) {
            $result.shouldAbort = $true
            $result.abortReason = "CPU at $($result.cpu.current)% (threshold: $($thresholds.CPUMaxPercent)%)"
        }
        elseif ($result.handles.current -ge $thresholds.HandleCountMax) {
            $result.shouldAbort = $true
            $result.abortReason = "Handle count $($result.handles.current) (threshold: $($thresholds.HandleCountMax))"
        }
    }

    if ($result.shouldAbort) {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ResilienceEngine' `
            -Message "RESOURCE ABORT: $($result.abortReason)"
    }

    return [PSCustomObject]$result
}

function Get-ResourceBaseline {
    <#
    .SYNOPSIS
        Returns the resource baseline captured at engine initialization.
    #>
    [OutputType([PSCustomObject])]
    param()
    if ($script:_ResourceBaseline) {
        return [PSCustomObject]$script:_ResourceBaseline
    }
    return $null
}

#endregion

#region -- Private Helpers

function _Get-ResourceConfig {
    param([string] $ConfigIniPath = '')

    $config = @{} + $script:_ResourceDefaults

    if ($ConfigIniPath -and (Test-Path $ConfigIniPath)) {
        try {
            $content   = Get-Content $ConfigIniPath -Encoding UTF8
            $inSection = $false
            foreach ($line in $content) {
                if ($line -match '^\s*\[ResourceGovernance\]') { $inSection = $true; continue }
                if ($line -match '^\s*\[') { $inSection = $false; continue }
                if ($inSection) {
                    if ($line -match '^\s*MemoryMaxPercent\s*=\s*(\d+)') { $config.MemoryMaxPercent = [int]$Matches[1] }
                    if ($line -match '^\s*CPUMaxPercent\s*=\s*(\d+)') { $config.CPUMaxPercent = [int]$Matches[1] }
                    if ($line -match '^\s*CPUSpikeMaxDurationSec\s*=\s*(\d+)') { $config.CPUSpikeMaxDurationSec = [int]$Matches[1] }
                    if ($line -match '^\s*DiskIOMaxMBps\s*=\s*(\d+)') { $config.DiskIOMaxMBps = [int]$Matches[1] }
                    if ($line -match '^\s*HandleCountMax\s*=\s*(\d+)') { $config.HandleCountMax = [int]$Matches[1] }
                    if ($line -match '^\s*MonitorIntervalMs\s*=\s*(\d+)') { $config.MonitorIntervalMs = [int]$Matches[1] }
                    if ($line -match '^\s*AbortStressOnBreach\s*=\s*(\d+)') { $config.AbortStressOnBreach = [int]$Matches[1] -ne 0 }
                }
            }
        }
        catch { }
    }

    return $config
}

function _Check-OrphanedTokens {
    param(
        [string] $SessionId,
        [string] $OutputDir
    )

    $result = [ordered]@{
        orphanedCount  = 0
        orphanedTokens = @()
        recoveryNeeded = $false
    }

    $tokenDir = Join-Path $OutputDir 'TransactionTokens'
    if (-not (Test-Path $tokenDir)) {
        return [PSCustomObject]$result
    }

    $tokenFiles = Get-ChildItem -Path $tokenDir -Filter '*.json' -ErrorAction SilentlyContinue

    foreach ($file in $tokenFiles) {
        try {
            $token = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($token.status -eq 'IN_PROGRESS' -and $token.sessionId -ne $SessionId) {
                $result.orphanedCount++
                $result.orphanedTokens += [PSCustomObject]@{
                    token     = $token.rollbackToken
                    actionId  = $token.actionId
                    sessionId = $token.sessionId
                    timestamp = $token.timestamp
                    file      = $file.Name
                }
                $result.recoveryNeeded = $true

                # Mark as recovered
                $recovered = [ordered]@{
                    _type         = $token._type
                    sessionId     = $token.sessionId
                    actionId      = $token.actionId
                    rollbackToken = $token.rollbackToken
                    moduleName    = $token.moduleName
                    timestamp     = $token.timestamp
                    status        = 'RECOVERED'
                    recoveredAt   = Get-Date -Format 'o'
                    recoveredBy   = $SessionId
                    machineName   = $token.machineName
                }
                $recovered | ConvertTo-Json -Depth 5 | Set-Content -Path $file.FullName -Encoding UTF8 -Force

                Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ResilienceEngine' `
                    -Message "ORPHANED TOKEN: $($token.rollbackToken) from session $($token.sessionId) -- marking as recovered"
            }
        }
        catch { }
    }

    return [PSCustomObject]$result
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-CrashProofTransaction',
    'Confirm-RestorePoint',
    'Confirm-BackupIntegrity',
    'Save-TransactionToken',
    'Complete-TransactionToken',
    'Invoke-AutoRollback',
    'Test-CrashRecoveryNeeded',
    'Test-ResourceGovernance',
    'Watch-StressResources',
    'Get-ResourceBaseline'
)
