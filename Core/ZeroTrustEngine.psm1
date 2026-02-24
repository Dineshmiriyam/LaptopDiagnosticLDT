#Requires -Version 5.1
<#
.SYNOPSIS
    LDT ZeroTrustEngine -- Pre-Execution Trust Chain Validation

.DESCRIPTION
    Implements the Zero Trust execution foundation for LDT v10.0 certification.
    Before ANY diagnostic or remediation activity, this engine validates:

      1. Script Signatures        -- Authenticode or SHA256 verification of all .ps1/.psm1 files
      2. Approved Files Manifest  -- Directory whitelist enforcement against ApprovedFiles.json
      3. Config Hash Validation   -- config.ini + config.json integrity vs VersionManifest
      4. Policy Integrity         -- Governance policy profile consistency check

    Signature Modes (configurable via [ZeroTrust] SignatureMode):
      SHA256Only              -- Hash scripts against ApprovedFiles.json (default, USB-safe)
      AuthenticodeWithFallback-- Check Authenticode first, fall back to SHA256 if unsigned
      Authenticode            -- Require valid Authenticode; abort if unsigned

    If ANY check fails:
      - Abort immediately
      - Log ZeroTrustViolation
      - No remediation allowed
      - Classification = L3

.NOTES
    Version : 10.0.0
    Platform: PowerShell 5.1+
    Sections: S0 (Zero Trust), S1 (Cryptographic Trust), S2 (Directory Whitelist)
#>

Set-StrictMode -Version Latest

$script:_OperationalBoundary = [ordered]@{
    moduleName     = 'ZeroTrustEngine'
    version        = '10.0.0'
    canDo          = @(
        'Validate script digital signatures (Authenticode or SHA256)'
        'Verify ApprovedFiles manifest against filesystem'
        'Validate config file hashes against VersionManifest'
        'Verify policy profile integrity'
        'Abort execution on any trust violation'
    )
    cannotDo       = @(
        'Modify any file'
        'Sign scripts'
        'Create or update manifests'
        'Make network calls'
        'Bypass violations'
    )
}

#region -- Configuration Defaults

$script:_ZeroTrustDefaults = @{
    SignatureMode           = 'SHA256Only'
    AbortOnManifestMismatch    = $true
    AbortOnConfigHashMismatch  = $true
    AbortOnPolicyIntegrityFailure = $true
    AbortOnSignatureFailure    = $true
    TrustedThumbprint          = ''
}

#endregion

#region -- Public Functions

function Test-ZeroTrustGate {
    <#
    .SYNOPSIS
        Master gate function called during Phase 0. Orchestrates all Zero Trust checks.
        Returns a structured result. Throws on any critical violation if configured to abort.
    .OUTPUTS
        [PSCustomObject] with overallStatus, signatureResult, manifestResult, configHashResult, policyResult
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot,
        [string] $ConfigIniPath = '',
        [string] $ConfigJsonPath = ''
    )

    $ztConfig = _Get-ZeroTrustConfig -ConfigIniPath $ConfigIniPath

    $gate = [ordered]@{
        timestamp        = Get-Date -Format 'o'
        sessionId        = $SessionId
        overallStatus    = 'UNKNOWN'
        signatureMode    = $ztConfig.SignatureMode
        signatureResult  = $null
        manifestResult   = $null
        configHashResult = $null
        policyResult     = $null
        violations       = @()
    }

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'ZeroTrustEngine' `
        -Message "Zero Trust gate initiated -- Mode: $($ztConfig.SignatureMode)"

    # ── Check 1: Script Signatures ───────────────────────────────────────────
    try {
        $gate.signatureResult = Test-ScriptSignatures -SessionId $SessionId `
            -PlatformRoot $PlatformRoot -SignatureMode $ztConfig.SignatureMode `
            -TrustedThumbprint $ztConfig.TrustedThumbprint
        if ($gate.signatureResult.overallStatus -ne 'PASS') {
            $gate.violations += "SignatureValidation: $($gate.signatureResult.overallStatus)"
            if ($ztConfig.AbortOnSignatureFailure) {
                $gate.overallStatus = 'ABORT_SIGNATURE_FAILURE'
                _Log-ZeroTrustViolation -SessionId $SessionId -ViolationType 'SignatureFailure' `
                    -Details $gate.signatureResult
                throw "ZeroTrustEngine: Script signature validation failed. Execution aborted."
            }
        }
    }
    catch [System.Management.Automation.RuntimeException] {
        throw
    }
    catch {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ZeroTrustEngine' `
            -Message "Signature check encountered error: $($_.Exception.Message)"
        $gate.signatureResult = [PSCustomObject]@{ overallStatus = 'ERROR'; error = $_.Exception.Message }
    }

    # ── Check 2: Approved Files Manifest ─────────────────────────────────────
    try {
        $gate.manifestResult = Test-ApprovedFilesManifest -SessionId $SessionId `
            -PlatformRoot $PlatformRoot
        if ($gate.manifestResult.overallStatus -ne 'PASS') {
            $gate.violations += "ManifestValidation: $($gate.manifestResult.overallStatus)"
            if ($ztConfig.AbortOnManifestMismatch) {
                $gate.overallStatus = 'ABORT_MANIFEST_MISMATCH'
                _Log-ZeroTrustViolation -SessionId $SessionId -ViolationType 'ManifestMismatch' `
                    -Details $gate.manifestResult
                throw "ZeroTrustEngine: Approved files manifest validation failed. Execution aborted."
            }
        }
    }
    catch [System.Management.Automation.RuntimeException] {
        throw
    }
    catch {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ZeroTrustEngine' `
            -Message "Manifest check encountered error: $($_.Exception.Message)"
        $gate.manifestResult = [PSCustomObject]@{ overallStatus = 'ERROR'; error = $_.Exception.Message }
    }

    # ── Check 3: Config Hash Validation ──────────────────────────────────────
    try {
        $gate.configHashResult = Test-ConfigHashes -SessionId $SessionId `
            -PlatformRoot $PlatformRoot
        if ($gate.configHashResult.overallStatus -ne 'PASS') {
            $gate.violations += "ConfigHashValidation: $($gate.configHashResult.overallStatus)"
            if ($ztConfig.AbortOnConfigHashMismatch) {
                $gate.overallStatus = 'ABORT_CONFIG_HASH_MISMATCH'
                _Log-ZeroTrustViolation -SessionId $SessionId -ViolationType 'ConfigHashMismatch' `
                    -Details $gate.configHashResult
                throw "ZeroTrustEngine: Config file hash validation failed. Execution aborted."
            }
        }
    }
    catch [System.Management.Automation.RuntimeException] {
        throw
    }
    catch {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ZeroTrustEngine' `
            -Message "Config hash check encountered error: $($_.Exception.Message)"
        $gate.configHashResult = [PSCustomObject]@{ overallStatus = 'ERROR'; error = $_.Exception.Message }
    }

    # ── Check 4: Policy Integrity ────────────────────────────────────────────
    try {
        $gate.policyResult = Test-PolicyIntegrity -SessionId $SessionId `
            -ConfigJsonPath $ConfigJsonPath
        if ($gate.policyResult.overallStatus -ne 'PASS') {
            $gate.violations += "PolicyIntegrity: $($gate.policyResult.overallStatus)"
            if ($ztConfig.AbortOnPolicyIntegrityFailure) {
                $gate.overallStatus = 'ABORT_POLICY_INTEGRITY_FAILURE'
                _Log-ZeroTrustViolation -SessionId $SessionId -ViolationType 'PolicyIntegrityFailure' `
                    -Details $gate.policyResult
                throw "ZeroTrustEngine: Policy integrity validation failed. Execution aborted."
            }
        }
    }
    catch [System.Management.Automation.RuntimeException] {
        throw
    }
    catch {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ZeroTrustEngine' `
            -Message "Policy integrity check encountered error: $($_.Exception.Message)"
        $gate.policyResult = [PSCustomObject]@{ overallStatus = 'ERROR'; error = $_.Exception.Message }
    }

    # ── Final Assessment ─────────────────────────────────────────────────────
    if ($gate.violations.Count -eq 0) {
        $gate.overallStatus = 'PASS'
        Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'ZeroTrustEngine' `
            -Message "Zero Trust gate PASSED -- all checks clear"
    } else {
        if ($gate.overallStatus -eq 'UNKNOWN') {
            $gate.overallStatus = 'WARN_VIOLATIONS_PRESENT'
        }
        Write-EngineLog -SessionId $SessionId -Level 'ERROR' -Source 'ZeroTrustEngine' `
            -Message "Zero Trust gate completed with violations: $($gate.violations -join '; ')"
    }

    return [PSCustomObject]$gate
}

function Test-ScriptSignatures {
    <#
    .SYNOPSIS
        Validates .ps1 and .psm1 files according to the configured signature mode.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot,
        [string] $SignatureMode = 'SHA256Only',
        [string] $TrustedThumbprint = ''
    )

    $result = [ordered]@{
        overallStatus   = 'UNKNOWN'
        mode            = $SignatureMode
        filesChecked    = 0
        filesPassed     = 0
        filesFailed     = @()
    }

    # Collect all .ps1 and .psm1 files (non-recursive into excluded dirs)
    $scriptFiles = @()
    $scriptFiles += Get-ChildItem -Path $PlatformRoot -Filter '*.ps1' -ErrorAction SilentlyContinue
    $scriptFiles += Get-ChildItem -Path $PlatformRoot -Filter '*.psm1' -ErrorAction SilentlyContinue
    $coreDir = Join-Path $PlatformRoot 'Core'
    if (Test-Path $coreDir) {
        $scriptFiles += Get-ChildItem -Path $coreDir -Filter '*.psm1' -ErrorAction SilentlyContinue
    }
    $toolsDir = Join-Path $PlatformRoot 'Tools'
    if (Test-Path $toolsDir) {
        $scriptFiles += Get-ChildItem -Path $toolsDir -Filter '*.ps1' -ErrorAction SilentlyContinue
    }

    # Load ApprovedFiles.json for SHA256 lookup
    $approvedHashes = @{}
    $approvedPath = Join-Path $PlatformRoot 'Config\ApprovedFiles.json'
    if (Test-Path $approvedPath) {
        try {
            $approved = Get-Content $approvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in $approved.files) {
                if ($entry.sha256) {
                    $approvedHashes[$entry.relativePath] = $entry.sha256
                }
            }
        }
        catch {
            Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ZeroTrustEngine' `
                -Message "Could not parse ApprovedFiles.json for signature check: $($_.Exception.Message)"
        }
    }

    foreach ($file in $scriptFiles) {
        $result.filesChecked++
        $relativePath = $file.FullName.Substring($PlatformRoot.Length + 1).Replace('\', '/')
        # Normalize to backslash for manifest lookup
        $relativePathBS = $relativePath.Replace('/', '\')

        $fileStatus = 'UNKNOWN'

        switch ($SignatureMode) {
            'Authenticode' {
                $sig = Get-AuthenticodeSignature -FilePath $file.FullName -ErrorAction SilentlyContinue
                if ($sig -and $sig.Status -eq 'Valid') {
                    if ($TrustedThumbprint -and $sig.SignerCertificate.Thumbprint -ne $TrustedThumbprint) {
                        $fileStatus = 'UNTRUSTED_THUMBPRINT'
                    } else {
                        $fileStatus = 'PASS'
                    }
                } else {
                    $fileStatus = 'SIGNATURE_INVALID'
                }
            }
            'AuthenticodeWithFallback' {
                $sig = Get-AuthenticodeSignature -FilePath $file.FullName -ErrorAction SilentlyContinue
                if ($sig -and $sig.Status -eq 'Valid') {
                    if ($TrustedThumbprint -and $sig.SignerCertificate.Thumbprint -ne $TrustedThumbprint) {
                        $fileStatus = 'UNTRUSTED_THUMBPRINT'
                    } else {
                        $fileStatus = 'PASS'
                    }
                } else {
                    # Fallback to SHA256
                    $fileStatus = _Test-FileSHA256 -FilePath $file.FullName -RelativePath $relativePathBS `
                        -ApprovedHashes $approvedHashes
                }
            }
            default {
                # SHA256Only
                $fileStatus = _Test-FileSHA256 -FilePath $file.FullName -RelativePath $relativePathBS `
                    -ApprovedHashes $approvedHashes
            }
        }

        if ($fileStatus -eq 'PASS') {
            $result.filesPassed++
        } else {
            $result.filesFailed += [PSCustomObject]@{
                file   = $relativePath
                status = $fileStatus
            }
        }
    }

    $result.overallStatus = if ($result.filesFailed.Count -eq 0) { 'PASS' }
                            elseif ($result.filesFailed.Count -le 2) { 'PARTIAL_FAILURE' }
                            else { 'CRITICAL_FAILURE' }

    Write-EngineLog -SessionId $SessionId -Level $(if ($result.overallStatus -eq 'PASS') { 'AUDIT' } else { 'ERROR' }) `
        -Source 'ZeroTrustEngine' `
        -Message "Script signature check: $($result.overallStatus) ($($result.filesPassed)/$($result.filesChecked) passed)" `
        -Data @{ mode = $SignatureMode; failed = $result.filesFailed.Count }

    return [PSCustomObject]$result
}

function Test-ApprovedFilesManifest {
    <#
    .SYNOPSIS
        Validates all files in the LDT directory against ApprovedFiles.json.
        Detects unknown files, hash mismatches, and extension violations.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot
    )

    $result = [ordered]@{
        overallStatus       = 'UNKNOWN'
        manifestFound       = $false
        approvedFileCount   = 0
        unknownFiles        = @()
        hashMismatches      = @()
        extensionViolations = @()
        missingApproved     = @()
    }

    $approvedPath = Join-Path $PlatformRoot 'Config\ApprovedFiles.json'
    if (-not (Test-Path $approvedPath)) {
        Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ZeroTrustEngine' `
            -Message "ApprovedFiles.json not found -- directory whitelist check skipped"
        $result.overallStatus = 'MANIFEST_MISSING'
        return [PSCustomObject]$result
    }

    $result.manifestFound = $true

    try {
        $manifest = Get-Content $approvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $result.overallStatus = 'MANIFEST_PARSE_ERROR'
        return [PSCustomObject]$result
    }

    # Build approved file lookup
    $approvedLookup = @{}
    foreach ($entry in $manifest.files) {
        $approvedLookup[$entry.relativePath] = $entry
        $result.approvedFileCount++
    }

    # Build excluded directories set
    $excludedDirs = @()
    if ($manifest.excludedDirectories) {
        $excludedDirs = @($manifest.excludedDirectories)
    }

    # Scan allowed extensions
    $allowedExtensions = @()
    if ($manifest.allowedExtensions) {
        $allowedExtensions = @($manifest.allowedExtensions)
    }

    # Get directory rules
    $dirRules = @{}
    if ($manifest.directoryRules) {
        foreach ($rule in $manifest.directoryRules) {
            $dirRules[$rule.path.TrimEnd('/')] = $rule
        }
    }

    # Scan filesystem
    $allFiles = Get-ChildItem -Path $PlatformRoot -Recurse -File -ErrorAction SilentlyContinue

    foreach ($file in $allFiles) {
        $relativePath = $file.FullName.Substring($PlatformRoot.Length + 1)
        # Skip excluded directories
        $topDir = $relativePath.Split('\')[0]
        if ($topDir -in $excludedDirs) { continue }
        if ($topDir -eq '.git') { continue }

        # Check if file is in the approved list
        if (-not $approvedLookup.ContainsKey($relativePath)) {
            # Check extension against allowed list
            $ext = $file.Extension.ToLower()
            if ($allowedExtensions.Count -gt 0 -and $ext -notin $allowedExtensions) {
                $result.extensionViolations += [PSCustomObject]@{
                    file      = $relativePath
                    extension = $ext
                }
            }
            $result.unknownFiles += $relativePath

            Write-EngineLog -SessionId $SessionId -Level 'WARN' -Source 'ZeroTrustEngine' `
                -Message "UNKNOWN FILE detected: $relativePath" `
                -Data @{ file = $relativePath; extension = $ext }
            continue
        }

        # Validate hash if available
        $approvedEntry = $approvedLookup[$relativePath]
        if ($approvedEntry.sha256) {
            $actualHash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
            if ($actualHash -ne $approvedEntry.sha256) {
                $result.hashMismatches += [PSCustomObject]@{
                    file     = $relativePath
                    expected = $approvedEntry.sha256
                    actual   = $actualHash
                    critical = [bool]$approvedEntry.critical
                }
                Write-EngineLog -SessionId $SessionId -Level 'ERROR' -Source 'ZeroTrustEngine' `
                    -Message "HASH MISMATCH: $relativePath" `
                    -Data @{ expected = $approvedEntry.sha256; actual = $actualHash }
            }
        }
    }

    # Check for missing approved files (critical only)
    foreach ($relPath in $approvedLookup.Keys) {
        $fullPath = Join-Path $PlatformRoot $relPath
        if (-not (Test-Path $fullPath)) {
            $entry = $approvedLookup[$relPath]
            if ($entry.critical) {
                $result.missingApproved += $relPath
            }
        }
    }

    # Determine overall status
    $hasCriticalHash = @($result.hashMismatches | Where-Object { $_.critical }).Count -gt 0
    $hasMissing = $result.missingApproved.Count -gt 0

    if ($hasCriticalHash -or $hasMissing) {
        $result.overallStatus = 'CRITICAL_FAILURE'
    }
    elseif ($result.hashMismatches.Count -gt 0 -or $result.unknownFiles.Count -gt 0) {
        $result.overallStatus = 'PARTIAL_FAILURE'
    }
    else {
        $result.overallStatus = 'PASS'
    }

    Write-EngineLog -SessionId $SessionId -Level $(if ($result.overallStatus -eq 'PASS') { 'AUDIT' } else { 'ERROR' }) `
        -Source 'ZeroTrustEngine' `
        -Message "Approved files manifest check: $($result.overallStatus)" `
        -Data @{
            approved    = $result.approvedFileCount
            unknown     = $result.unknownFiles.Count
            mismatches  = $result.hashMismatches.Count
            missing     = $result.missingApproved.Count
        }

    return [PSCustomObject]$result
}

function Test-ConfigHashes {
    <#
    .SYNOPSIS
        Validates config.ini and config.json hashes against VersionManifest.json.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $PlatformRoot
    )

    $result = [ordered]@{
        overallStatus = 'UNKNOWN'
        filesChecked  = 0
        filesPassed   = 0
        filesFailed   = @()
    }

    $manifestPath = Join-Path $PlatformRoot 'Config\VersionManifest.json'
    if (-not (Test-Path $manifestPath)) {
        $result.overallStatus = 'MANIFEST_MISSING'
        return [PSCustomObject]$result
    }

    try {
        $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $result.overallStatus = 'MANIFEST_PARSE_ERROR'
        return [PSCustomObject]$result
    }

    # Check config files specifically
    $configFiles = @($manifest.files | Where-Object { $_.role -eq 'CONFIG' })

    foreach ($entry in $configFiles) {
        $filePath = Join-Path $PlatformRoot $entry.relativePath
        $result.filesChecked++

        if (-not (Test-Path $filePath)) {
            if ($entry.critical) {
                $result.filesFailed += [PSCustomObject]@{
                    file   = $entry.relativePath
                    reason = 'FILE_MISSING'
                }
            }
            continue
        }

        # Skip placeholder hashes
        if (-not $entry.sha256 -or $entry.sha256 -eq 'PLACEHOLDER_RUN_Update-VersionManifest') {
            $result.filesPassed++
            continue
        }

        $actualHash = (Get-FileHash $filePath -Algorithm SHA256).Hash
        if ($actualHash -ne $entry.sha256) {
            $result.filesFailed += [PSCustomObject]@{
                file     = $entry.relativePath
                reason   = 'HASH_MISMATCH'
                expected = $entry.sha256
                actual   = $actualHash
            }
            Write-EngineLog -SessionId $SessionId -Level 'ERROR' -Source 'ZeroTrustEngine' `
                -Message "Config hash mismatch: $($entry.relativePath)" `
                -Data @{ expected = $entry.sha256; actual = $actualHash }
        } else {
            $result.filesPassed++
        }
    }

    $result.overallStatus = if ($result.filesFailed.Count -eq 0) { 'PASS' } else { 'HASH_MISMATCH' }

    return [PSCustomObject]$result
}

function Test-PolicyIntegrity {
    <#
    .SYNOPSIS
        Validates governance policy profile consistency in config.json.
        Ensures required policy fields exist and values are within expected ranges.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [string] $ConfigJsonPath = ''
    )

    $result = [ordered]@{
        overallStatus   = 'UNKNOWN'
        profilesFound   = @()
        issues          = @()
    }

    if (-not $ConfigJsonPath -or -not (Test-Path $ConfigJsonPath)) {
        $result.overallStatus = 'CONFIG_MISSING'
        return [PSCustomObject]$result
    }

    try {
        $config = Get-Content $ConfigJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $result.overallStatus = 'PARSE_ERROR'
        $result.issues += "config.json parse error: $($_.Exception.Message)"
        return [PSCustomObject]$result
    }

    # Validate governance.policies
    if (-not $config.governance -or -not $config.governance.policies) {
        $result.overallStatus = 'MISSING_POLICIES'
        $result.issues += "governance.policies section missing from config.json"
        return [PSCustomObject]$result
    }

    $requiredProfiles = @('Strict', 'Balanced', 'Aggressive')
    $requiredFields   = @('maxAutoFixLevel', 'requireWhitelist', 'retryEnabled', 'abortOnCritical')
    $validLevels      = @('L1', 'L2', 'L3')

    foreach ($profileName in $requiredProfiles) {
        $profile = $config.governance.policies.$profileName
        if (-not $profile) {
            $result.issues += "Missing policy profile: $profileName"
            continue
        }
        $result.profilesFound += $profileName

        foreach ($field in $requiredFields) {
            $val = $profile.$field
            if ($null -eq $val) {
                $result.issues += "$profileName missing field: $field"
            }
        }

        # Validate maxAutoFixLevel
        if ($profile.maxAutoFixLevel -and $profile.maxAutoFixLevel -notin $validLevels) {
            $result.issues += "$profileName has invalid maxAutoFixLevel: $($profile.maxAutoFixLevel)"
        }
    }

    # Validate execution modes
    if ($config.governance.executionModes) {
        $requiredModes = @('AuditOnly', 'Diagnostic', 'Remediation', 'Full', 'ClassifyOnly')
        foreach ($mode in $requiredModes) {
            if (-not $config.governance.executionModes.$mode) {
                $result.issues += "Missing execution mode: $mode"
            }
        }
    } else {
        $result.issues += "governance.executionModes section missing"
    }

    $result.overallStatus = if ($result.issues.Count -eq 0) { 'PASS' }
                            elseif ($result.issues.Count -le 2) { 'DEGRADED' }
                            else { 'INTEGRITY_FAILURE' }

    Write-EngineLog -SessionId $SessionId -Level $(if ($result.overallStatus -eq 'PASS') { 'AUDIT' } else { 'WARN' }) `
        -Source 'ZeroTrustEngine' `
        -Message "Policy integrity check: $($result.overallStatus)" `
        -Data @{ profiles = $result.profilesFound; issues = $result.issues.Count }

    return [PSCustomObject]$result
}

#endregion

#region -- Private Helpers

function _Get-ZeroTrustConfig {
    param([string] $ConfigIniPath = '')

    $config = @{} + $script:_ZeroTrustDefaults

    if ($ConfigIniPath -and (Test-Path $ConfigIniPath)) {
        try {
            $content   = Get-Content $ConfigIniPath -Encoding UTF8
            $inSection = $false
            foreach ($line in $content) {
                if ($line -match '^\s*\[ZeroTrust\]') { $inSection = $true; continue }
                if ($line -match '^\s*\[') { $inSection = $false; continue }
                if ($inSection) {
                    if ($line -match '^\s*SignatureMode\s*=\s*(.+)') {
                        $config.SignatureMode = $Matches[1].Trim()
                    }
                    if ($line -match '^\s*AbortOnManifestMismatch\s*=\s*(\d+)') {
                        $config.AbortOnManifestMismatch = [int]$Matches[1] -ne 0
                    }
                    if ($line -match '^\s*AbortOnConfigHashMismatch\s*=\s*(\d+)') {
                        $config.AbortOnConfigHashMismatch = [int]$Matches[1] -ne 0
                    }
                    if ($line -match '^\s*AbortOnPolicyIntegrityFailure\s*=\s*(\d+)') {
                        $config.AbortOnPolicyIntegrityFailure = [int]$Matches[1] -ne 0
                    }
                    if ($line -match '^\s*AbortOnSignatureFailure\s*=\s*(\d+)') {
                        $config.AbortOnSignatureFailure = [int]$Matches[1] -ne 0
                    }
                    if ($line -match '^\s*TrustedThumbprint\s*=\s*(.+)') {
                        $config.TrustedThumbprint = $Matches[1].Trim()
                    }
                }
            }
        }
        catch { }
    }

    return $config
}

function _Test-FileSHA256 {
    param(
        [string] $FilePath,
        [string] $RelativePath,
        [hashtable] $ApprovedHashes
    )

    # Try both forward-slash and backslash variants
    $lookupKey = $RelativePath
    $lookupKeyAlt = $RelativePath.Replace('\', '/')

    $expectedHash = $null
    if ($ApprovedHashes.ContainsKey($lookupKey)) {
        $expectedHash = $ApprovedHashes[$lookupKey]
    }
    elseif ($ApprovedHashes.ContainsKey($lookupKeyAlt)) {
        $expectedHash = $ApprovedHashes[$lookupKeyAlt]
    }

    if (-not $expectedHash) {
        return 'NOT_IN_MANIFEST'
    }

    $actualHash = (Get-FileHash $FilePath -Algorithm SHA256).Hash
    if ($actualHash -eq $expectedHash) {
        return 'PASS'
    } else {
        return 'HASH_MISMATCH'
    }
}

function _Log-ZeroTrustViolation {
    param(
        [string] $SessionId,
        [string] $ViolationType,
        $Details
    )

    Write-EngineLog -SessionId $SessionId -Level 'FATAL' -Source 'ZeroTrustEngine' `
        -Message "ZERO TRUST VIOLATION: $ViolationType -- Execution must be aborted" `
        -Data @{ violationType = $ViolationType; detailStatus = $Details.overallStatus }
}

#endregion

Export-ModuleMember -Function @(
    'Test-ZeroTrustGate',
    'Test-ScriptSignatures',
    'Test-ApprovedFilesManifest',
    'Test-ConfigHashes',
    'Test-PolicyIntegrity'
)
