#Requires -Version 5.1
<#
.SYNOPSIS
    LDT IntegrityEngine -- SHA256 Tamper-Evident Log Sealing and Platform Validation

.DESCRIPTION
    Implements the integrity validation layer for LDT Enterprise governance.

    Functions:
      1. Platform Validation        -- Validates SHA256 hashes of all platform files against
                                      VersionManifest.json before execution begins.
                                      Critical file tamper = ABORT. Non-critical = WARN.

      2. Log Integrity Verification -- Before each session, verifies the previous session's
                                      log seal is intact. Flags tampered logs.

      3. Log Seal                   -- Appends a SHA256 seal record to the session log at
                                      session close. The seal covers ALL prior log entries.

      4. Execution Receipt          -- Generates a self-hashing execution receipt (JSON)
                                      proving what ran, when, and at what version.

    Seal Record Schema (appended as last line of session log):
    {
        "_type"       : "INTEGRITY_SEAL",
        "timestamp"   : "ISO8601",
        "sessionId"   : "...",
        "algorithm"   : "SHA256",
        "entryCount"  : int,
        "logHash"     : "SHA256 of all prior content",
        "manifestHash": "SHA256 of VersionManifest.json at seal time"
    }

.NOTES
    Version : 9.0.0
    Platform: PowerShell 5.1+
    Ported  : From WinDRE v2.1.0 IntegrityEngine with LDT adaptations
#>

Set-StrictMode -Version Latest

#region -- Public Functions

function Test-PlatformIntegrity {
    <#
    .SYNOPSIS
        Validates all platform files against VersionManifest.json.
        Returns a structured validation result. Throws if any CRITICAL file is tampered.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot
    )

    $result = [ordered]@{
        timestamp        = Get-Date -Format 'o'
        manifestFound    = $false
        manifestValid    = $false
        filesChecked     = 0
        filesPassed      = 0
        filesFailed      = @()
        filesSkipped     = @()
        overallStatus    = 'UNKNOWN'
        manifestHash     = $null
    }

    Write-EngineLog -SessionId $SessionId -Level 'INFO' -Source 'IntegrityEngine' `
        -Message "Beginning platform integrity validation"

    # ── Load Manifest ─────────────────────────────────────────────────────────
    $manifestPath = Join-Path $PlatformRoot 'Config\VersionManifest.json'
    if (-not (Test-Path $manifestPath)) {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'IntegrityEngine' `
            -Message "VersionManifest.json not found -- skipping file hash validation" `
            -Data @{ expectedPath = $manifestPath }
        $result.overallStatus = 'MANIFEST_MISSING'
        return [PSCustomObject]$result
    }

    $result.manifestFound = $true
    $result.manifestHash  = (Get-FileHash $manifestPath -Algorithm SHA256).Hash

    try {
        $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-EngineLog -SessionId $SessionId -Level 'ERROR' -Source 'IntegrityEngine' `
            -Message "VersionManifest.json is malformed: $($_.Exception.Message)"
        $result.overallStatus = 'MANIFEST_PARSE_ERROR'
        return [PSCustomObject]$result
    }

    # ── Validate Each File in Manifest ────────────────────────────────────────
    $criticalFailures = 0

    foreach ($entry in $manifest.files) {
        $filePath = Join-Path $PlatformRoot $entry.relativePath
        $result.filesChecked++

        if (-not (Test-Path $filePath)) {
            if ($entry.critical) {
                $criticalFailures++
                $result.filesFailed += [PSCustomObject]@{
                    file     = $entry.relativePath
                    reason   = 'FILE_MISSING'
                    critical = $true
                    expected = $entry.sha256
                    actual   = $null
                }
                Write-EngineLog -SessionId $SessionId -Level 'FATAL' -Source 'IntegrityEngine' `
                    -Message "INTEGRITY FAIL [MISSING]: $($entry.relativePath) -- critical platform file missing"
            } else {
                $result.filesSkipped += $entry.relativePath
            }
            continue
        }

        # Skip placeholder hashes (not yet populated by Update-VersionManifest.ps1)
        if ($entry.sha256 -eq 'PLACEHOLDER_RUN_Update-VersionManifest') {
            $result.filesPassed++
            Write-EngineLog -SessionId $SessionId -Level 'DEBUG' -Source 'IntegrityEngine' `
                -Message "SKIP (placeholder hash): $($entry.relativePath)"
            continue
        }

        $actualHash = (Get-FileHash $filePath -Algorithm SHA256).Hash

        if ($actualHash -ne $entry.sha256) {
            $result.filesFailed += [PSCustomObject]@{
                file     = $entry.relativePath
                reason   = 'HASH_MISMATCH'
                critical = $entry.critical
                expected = $entry.sha256
                actual   = $actualHash
            }

            $logLevel = if ($entry.critical) { 'FATAL' } else { 'ERROR' }
            if ($entry.critical) { $criticalFailures++ }

            Write-EngineLog -SessionId $SessionId -Level $logLevel -Source 'IntegrityEngine' `
                -Message "INTEGRITY FAIL [TAMPERED]: $($entry.relativePath)" `
                -Data @{ expected = $entry.sha256; actual = $actualHash; critical = $entry.critical }
        } else {
            $result.filesPassed++
            Write-EngineLog -SessionId $SessionId -Level 'DEBUG' -Source 'IntegrityEngine' `
                -Message "OK: $($entry.relativePath) -- $actualHash"
        }
    }

    $result.manifestValid = $true
    $result.overallStatus = if ($criticalFailures -gt 0) { 'CRITICAL_INTEGRITY_FAILURE' }
                            elseif ($result.filesFailed.Count -gt 0) { 'PARTIAL_INTEGRITY_FAILURE' }
                            else { 'PASS' }

    $integrityLevel = if ($criticalFailures -gt 0) { 'FATAL' } else { 'AUDIT' }
    Write-EngineLog -SessionId $SessionId -Level $integrityLevel `
        -Source 'IntegrityEngine' `
        -Message "Integrity validation complete: $($result.overallStatus)" `
        -Data @{
            filesChecked     = $result.filesChecked
            filesPassed      = $result.filesPassed
            filesFailed      = $result.filesFailed.Count
            criticalFailures = $criticalFailures
        }

    if ($criticalFailures -gt 0) {
        throw "IntegrityEngine: CRITICAL integrity failure -- $criticalFailures critical platform file(s) are missing or tampered. Execution halted."
    }

    return [PSCustomObject]$result
}

function Invoke-LogIntegrityCheck {
    <#
    .SYNOPSIS
        Checks the most recent previous session log for a valid seal.
        Returns a validation result -- does NOT halt execution (warning only).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $LogPath
    )

    $result = [ordered]@{
        previousLogFound  = $false
        sealFound         = $false
        sealValid         = $false
        previousLogFile   = $null
        tamperDetected    = $false
        sealTimestamp     = $null
    }

    # Find most recent previous log (SmartDiag_*.log, not the current session)
    $previousLog = Get-ChildItem $LogPath -Filter 'SmartDiag_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch $SessionId } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $previousLog) {
        Write-EngineLog -SessionId $SessionId -Level 'INFO' -Source 'IntegrityEngine' `
            -Message "No previous session log found -- first run or logs rotated"
        return [PSCustomObject]$result
    }

    $result.previousLogFound = $true
    $result.previousLogFile  = $previousLog.FullName

    # Read the log looking for a seal record as the last entry
    try {
        $lines = Get-Content $previousLog.FullName -Encoding UTF8 -ErrorAction Stop
        if (-not $lines -or $lines.Count -eq 0) {
            Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'IntegrityEngine' `
                -Message "Previous session log is empty"
            return [PSCustomObject]$result
        }

        $lastLine = $lines | Select-Object -Last 1

        $sealRecord = $null
        try {
            $sealRecord = $lastLine | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            # Last line isn't JSON -- no seal present
        }

        if (-not $sealRecord -or $sealRecord._type -ne 'INTEGRITY_SEAL') {
            $result.sealFound      = $false
            $result.tamperDetected = $true
            Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'IntegrityEngine' `
                -Message "Previous log is missing integrity seal -- log may have been truncated or tampered" `
                -Data @{ logFile = $previousLog.Name }
            return [PSCustomObject]$result
        }

        $result.sealFound     = $true
        $result.sealTimestamp = $sealRecord.timestamp

        # Recompute hash of all lines except the seal line
        $contentToHash = ($lines | Select-Object -SkipLast 1) -join "`n"
        $actualHash    = Get-StringHash -InputString $contentToHash

        if ($actualHash -ne $sealRecord.logHash) {
            $result.sealValid      = $false
            $result.tamperDetected = $true
            Write-EngineLog -SessionId $SessionId -Level 'ERROR' -Source 'IntegrityEngine' `
                -Message "INTEGRITY VIOLATION: Previous session log hash mismatch -- log content was modified after sealing" `
                -Data @{
                    logFile   = $previousLog.Name
                    expected  = $sealRecord.logHash
                    actual    = $actualHash
                    sealTime  = $sealRecord.timestamp
                }
        } else {
            $result.sealValid = $true
            Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'IntegrityEngine' `
                -Message "Previous session log integrity verified" `
                -Data @{ logFile = $previousLog.Name; sealTime = $sealRecord.timestamp }
        }
    }
    catch {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'IntegrityEngine' `
            -Message "Could not parse previous log for integrity check: $($_.Exception.Message)"
    }

    return [PSCustomObject]$result
}

function Seal-SessionLog {
    <#
    .SYNOPSIS
        Appends a SHA256 integrity seal to the current session's log file.
        Must be called as the very last operation before session close.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $LogFilePath,
        [Parameter(Mandatory)] [string] $PlatformRoot
    )

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'IntegrityEngine' `
        -Message "Sealing session log..."

    try {
        # Read all current content as lines
        $lines      = Get-Content $LogFilePath -Encoding UTF8 -ErrorAction Stop
        $entryCount = $lines.Count

        # Compute hash of all log content
        $logHash = Get-StringHash -InputString ($lines -join "`n")

        # Get manifest hash for cross-reference
        $manifestPath = Join-Path $PlatformRoot 'Config\VersionManifest.json'
        $manifestHash = if (Test-Path $manifestPath) {
            (Get-FileHash $manifestPath -Algorithm SHA256).Hash
        } else { 'MANIFEST_NOT_FOUND' }

        # Build seal record
        $seal = [ordered]@{
            _type         = 'INTEGRITY_SEAL'
            timestamp     = Get-Date -Format 'o'
            sessionId     = $SessionId
            computername  = $env:COMPUTERNAME
            algorithm     = 'SHA256'
            entryCount    = $entryCount
            logHash       = $logHash
            manifestHash  = $manifestHash
            sealVersion   = '9.0.0'
        }

        $sealJson = $seal | ConvertTo-Json -Compress -Depth 5
        Add-Content -Path $LogFilePath -Value $sealJson -Encoding UTF8

        Write-Host "  [SEAL] Log integrity seal applied -- SHA256: $($logHash.Substring(0,16))..." -ForegroundColor DarkCyan
    }
    catch {
        Write-Host "  [WARN] Failed to seal log: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function New-ExecutionReceipt {
    <#
    .SYNOPSIS
        Generates a self-hashing execution receipt proving what ran, when, and at what version.
        Adapted for LDT's $DiagState structure.

    .PARAMETER DiagState
        LDT's central diagnostic state hashtable.

    .PARAMETER ScoreResult
        Output from ScoringEngine's Invoke-SystemScoring (or $null if scoring skipped).

    .PARAMETER GuardStatus
        Output from GuardEngine's Get-GuardStatus (or $null if guard not active).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]    $SessionId,
        [Parameter(Mandatory)] [hashtable] $DiagState,
        [Parameter(Mandatory)] [string]    $PlatformRoot,
        [Parameter(Mandatory)] [string]    $OutputPath,
        [PSCustomObject] $ScoreResult  = $null,
        [PSCustomObject] $GuardStatus  = $null
    )

    $manifestPath = Join-Path $PlatformRoot 'Config\VersionManifest.json'
    $manifestVer  = 'UNKNOWN'
    if (Test-Path $manifestPath) {
        try {
            $man = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $manifestVer = $man.version
        } catch { }
    }

    # Build module execution summary from DiagState.PhaseResults
    $modulesSummary = @()
    if ($DiagState.PhaseResults) {
        foreach ($key in $DiagState.PhaseResults.Keys) {
            $modulesSummary += [PSCustomObject]@{
                phase  = $key
                status = $DiagState.PhaseResults[$key]
            }
        }
    }

    # Determine overall health from score or DiagState
    $overallHealth = 'UNKNOWN'
    if ($ScoreResult) {
        $overallHealth = $ScoreResult.band
    } elseif ($DiagState.EnterpriseScore) {
        $overallHealth = "$($DiagState.EnterpriseScore)/100"
    }

    # Escalation info
    $escalationLevel  = 0
    $hardStopTriggered = $false
    if ($GuardStatus) {
        $escalationLevel   = $GuardStatus.currentLevel
        $hardStopTriggered = $GuardStatus.hardStopTriggered
    }

    $receipt = [ordered]@{
        _type              = 'EXECUTION_RECEIPT'
        sessionId          = $SessionId
        issuedAt           = Get-Date -Format 'o'
        platformVersion    = '9.0.0'
        manifestVersion    = $manifestVer
        computername       = $env:COMPUTERNAME
        username           = "$env:USERDOMAIN\$env:USERNAME"
        mode               = if ($DiagState.OEMMode) { 'OEM_VALIDATION' } else { 'DIAGNOSTIC' }
        findingsCount      = if ($DiagState.Findings) { $DiagState.Findings.Count } else { 0 }
        fixesAppliedCount  = if ($DiagState.FixesApplied) { $DiagState.FixesApplied.Count } else { 0 }
        phasesExecuted     = $modulesSummary
        overallHealth      = $overallHealth
        escalationLevel    = $escalationLevel
        hardStopTriggered  = $hardStopTriggered
        receiptHash        = $null   # filled below
    }

    # Self-hash the receipt content
    $receiptJson         = $receipt | ConvertTo-Json -Depth 10 -Compress
    $receipt.receiptHash = Get-StringHash -InputString $receiptJson

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $outFile = Join-Path $OutputPath "ExecutionReceipt_$SessionId.json"
    $receipt | ConvertTo-Json -Depth 10 | Set-Content $outFile -Encoding UTF8

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'IntegrityEngine' `
        -Message "Execution receipt generated" `
        -Data @{ file = $outFile; hash = $receipt.receiptHash }

    return $outFile
}

function Test-PreRemediationIntegrity {
    <#
    .SYNOPSIS
        Lightweight pre-remediation integrity check. Re-hashes critical platform files
        and config.ini against the VersionManifest.json baseline.
        Called at Phase 6 entry to detect mid-session tampering.
    .OUTPUTS
        [PSCustomObject] with properties: overallStatus, filesChecked, filesPassed, failures
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot
    )

    $manifestPath = Join-Path $PlatformRoot "Config\VersionManifest.json"
    if (-not (Test-Path $manifestPath)) {
        return [PSCustomObject]@{ overallStatus = 'SKIP'; filesChecked = 0; filesPassed = 0; failures = @() }
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $criticalFiles = @($manifest.files | Where-Object { $_.critical -eq $true })
    $failures = @()
    $passed   = 0

    foreach ($entry in $criticalFiles) {
        $filePath = Join-Path $PlatformRoot $entry.relativePath.Replace('\\', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $filePath)) {
            $failures += [PSCustomObject]@{ file = $entry.relativePath; reason = 'FILE_MISSING' }
            continue
        }
        $sha = New-Object System.Security.Cryptography.SHA256CryptoServiceProvider
        $stream = [System.IO.File]::OpenRead($filePath)
        $hashBytes = $sha.ComputeHash($stream)
        $stream.Close()
        $sha.Dispose()
        $hashStr = ($hashBytes | ForEach-Object { $_.ToString('X2') }) -join ''
        if ($hashStr -ne $entry.sha256) {
            $failures += [PSCustomObject]@{ file = $entry.relativePath; reason = 'HASH_MISMATCH' }
        } else {
            $passed++
        }
    }

    $status = if ($failures.Count -eq 0) { 'PASS' } else { 'TAMPER_DETECTED' }

    Write-EngineLog -SessionId $SessionId -Level $(if ($failures.Count -gt 0) { 'ERROR' } else { 'INFO' }) `
        -Source 'IntegrityEngine' `
        -Message "Pre-remediation integrity: $status ($passed/$($criticalFiles.Count) critical files)" `
        -Data @{ failures = $failures.Count; status = $status }

    return [PSCustomObject]@{
        overallStatus = $status
        filesChecked  = $criticalFiles.Count
        filesPassed   = $passed
        failures      = $failures
    }
}

function New-ForensicArchive {
    <#
    .SYNOPSIS
        v10 S8: Generates a forensic-immutable archive with SHA256 + ChainHash.
        Bundles all session logs, marks archive read-only.
        ChainHash = SHA256(ArchiveHash + PreviousChainHash).
    .OUTPUTS
        [PSCustomObject] with archivePath, archiveHash, chainHash, timestamp
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot,
        [Parameter(Mandatory)] [string] $OutputDir,
        [string] $LogFilePath = ''
    )

    $result = [ordered]@{
        sessionId        = $SessionId
        timestamp        = Get-Date -Format 'o'
        archivePath      = ''
        archiveHash      = ''
        chainHash        = ''
        previousChainHash = ''
        filesIncluded    = 0
        readOnlySet      = $false
        engineVersion    = '10.0.0'
        signatureThumbprint = ''
    }

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'IntegrityEngine' `
        -Message "Generating forensic archive with ChainHash"

    # Create archive directory
    $archiveDir = Join-Path $PlatformRoot 'Archive'
    if (-not (Test-Path $archiveDir)) {
        New-Item -Path $archiveDir -ItemType Directory -Force | Out-Null
    }

    $archiveName = "ForensicArchive_${SessionId}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $archiveSubDir = Join-Path $archiveDir $archiveName
    New-Item -Path $archiveSubDir -ItemType Directory -Force | Out-Null

    # Collect files to archive
    $filesToArchive = @()

    # Session log
    if ($LogFilePath -and (Test-Path $LogFilePath)) {
        $filesToArchive += $LogFilePath
    }

    # Compliance artifacts
    $complianceDir = Join-Path $OutputDir 'Compliance*'
    $compDirs = Get-ChildItem -Path $OutputDir -Filter 'Compliance*' -Directory -ErrorAction SilentlyContinue
    foreach ($cd in $compDirs) {
        $files = Get-ChildItem -Path $cd.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $filesToArchive += $f.FullName
        }
    }

    # Execution receipt
    $receipts = Get-ChildItem -Path $OutputDir -Filter "ExecutionReceipt_$SessionId*" -File -ErrorAction SilentlyContinue
    foreach ($r in $receipts) {
        $filesToArchive += $r.FullName
    }

    # Copy files to archive
    foreach ($src in $filesToArchive) {
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $archiveSubDir -Force -ErrorAction SilentlyContinue
            $result.filesIncluded++
        }
    }

    # Compute archive hash (hash of all file hashes concatenated)
    $allHashes = ''
    $archivedFiles = Get-ChildItem -Path $archiveSubDir -File -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($af in $archivedFiles) {
        $fileHash = (Get-FileHash $af.FullName -Algorithm SHA256).Hash
        $allHashes += $fileHash
    }
    $result.archiveHash = Get-StringHash -InputString $allHashes

    # Load previous ChainHash
    $chainStorePath = Join-Path $PlatformRoot 'Data\ChainHash.json'
    $previousChainHash = ''
    if (Test-Path $chainStorePath) {
        try {
            $chainStore = Get-Content $chainStorePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($chainStore.currentChainHash) {
                $previousChainHash = $chainStore.currentChainHash
            }
        }
        catch { }
    }
    $result.previousChainHash = $previousChainHash

    # Compute ChainHash = SHA256(ArchiveHash + PreviousChainHash)
    $result.chainHash = Get-StringHash -InputString "$($result.archiveHash)$previousChainHash"

    # Get signature thumbprint if available
    $mainScript = Join-Path $PlatformRoot 'Smart_Diagnosis_Engine.ps1'
    if (Test-Path $mainScript) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $mainScript -ErrorAction SilentlyContinue
            if ($sig -and $sig.SignerCertificate) {
                $result.signatureThumbprint = $sig.SignerCertificate.Thumbprint
            }
        }
        catch { }
    }

    # Write archive manifest
    $archiveManifest = [ordered]@{
        _type               = 'FORENSIC_ARCHIVE'
        sessionId           = $SessionId
        timestamp           = $result.timestamp
        archiveHash         = $result.archiveHash
        chainHash           = $result.chainHash
        previousChainHash   = $previousChainHash
        engineVersion       = '10.0.0'
        signatureThumbprint = $result.signatureThumbprint
        filesIncluded       = $result.filesIncluded
        machineName         = $env:COMPUTERNAME
    }
    $manifestFile = Join-Path $archiveSubDir 'ArchiveManifest.json'
    $archiveManifest | ConvertTo-Json -Depth 10 | Set-Content $manifestFile -Encoding UTF8

    # Update ChainHash store
    $dataDir = Join-Path $PlatformRoot 'Data'
    if (-not (Test-Path $dataDir)) {
        New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
    }
    $chainStoreData = [ordered]@{
        _type            = 'CHAIN_HASH_STORE'
        currentChainHash = $result.chainHash
        previousHash     = $previousChainHash
        lastSessionId    = $SessionId
        updatedAt        = Get-Date -Format 'o'
        history          = @()
    }
    # Preserve history
    if ((Test-Path $chainStorePath)) {
        try {
            $existing = Get-Content $chainStorePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing.history) {
                $chainStoreData.history = @($existing.history)
            }
        }
        catch { }
    }
    $chainStoreData.history += [PSCustomObject]@{
        sessionId  = $SessionId
        chainHash  = $result.chainHash
        archiveHash = $result.archiveHash
        timestamp  = $result.timestamp
    }
    $chainStoreData | ConvertTo-Json -Depth 10 | Set-Content $chainStorePath -Encoding UTF8

    # Set archive read-only
    try {
        $archivedFiles = Get-ChildItem -Path $archiveSubDir -File -ErrorAction SilentlyContinue
        foreach ($af in $archivedFiles) {
            $af.IsReadOnly = $true
        }
        $result.readOnlySet = $true
    }
    catch {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'IntegrityEngine' `
            -Message "Could not set archive files to read-only: $($_.Exception.Message)"
    }

    $result.archivePath = $archiveSubDir

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'IntegrityEngine' `
        -Message "Forensic archive sealed" `
        -Data @{
            path        = $archiveSubDir
            archiveHash = $result.archiveHash
            chainHash   = $result.chainHash
            files       = $result.filesIncluded
        }

    return [PSCustomObject]$result
}

#endregion

#region -- Private Helpers

function Get-StringHash {
    param([string] $InputString)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hash   = $sha256.ComputeHash($bytes)
    $sha256.Dispose()
    return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
}

#endregion

Export-ModuleMember -Function @(
    'Test-PlatformIntegrity',
    'Test-PreRemediationIntegrity',
    'Invoke-LogIntegrityCheck',
    'Seal-SessionLog',
    'New-ExecutionReceipt',
    'New-ForensicArchive'
)
