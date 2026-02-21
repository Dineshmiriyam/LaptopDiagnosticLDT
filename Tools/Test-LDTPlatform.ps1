#Requires -Version 5.1
<#
.SYNOPSIS
    LDT Platform Validation -- Pre-deployment and CI gate checks

.DESCRIPTION
    Runs 7 validation checks against the LDT platform:
      1. PowerShell parse check (all .ps1/.psm1 files)
      2. PS 7+ syntax scan (catches ??, ?.=, ??=, ternary, -Parallel, &&, ||)
      3. Encoding scan (em-dash U+2014, smart quotes, BOM issues)
      4. Config section drift (config.ini sections vs expected list)
      5. BAT routing validation (menu options match goto labels)
      6. Version consistency (version string matches across all files)
      7. VersionManifest hash check (no PLACEHOLDER values remaining)

    Exit code 0 = all checks pass. Non-zero = failures found.

.PARAMETER PlatformRoot
    Root directory of the LDT platform. Defaults to parent of this script's directory.

.PARAMETER Fix
    When specified, auto-fixes encoding issues (em-dash replacement).

.EXAMPLE
    .\Test-LDTPlatform.ps1
    .\Test-LDTPlatform.ps1 -PlatformRoot "E:\LDT-v6.0" -Fix
#>

[CmdletBinding()]
param(
    [string] $PlatformRoot = (Split-Path $PSScriptRoot -Parent),
    [switch] $Fix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ============================================================
# HELPERS
# ============================================================

$script:TotalPass = 0
$script:TotalFail = 0
$script:TotalWarn = 0

function Write-CheckHeader {
    param([string]$Number, [string]$Title)
    Write-Host ""
    Write-Host "  [$Number] $Title" -ForegroundColor Cyan
    Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
}

function Write-Pass {
    param([string]$Message)
    Write-Host "    [PASS] $Message" -ForegroundColor Green
    $script:TotalPass++
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    [FAIL] $Message" -ForegroundColor Red
    $script:TotalFail++
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
    $script:TotalWarn++
}

function Write-Info {
    param([string]$Message)
    Write-Host "    [INFO] $Message" -ForegroundColor Gray
}

# ============================================================
# BANNER
# ============================================================

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "    LDT Platform Validation" -ForegroundColor White
Write-Host "    Platform Root: $PlatformRoot" -ForegroundColor DarkGray
Write-Host "    Timestamp:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host "  ================================================================" -ForegroundColor Cyan

# ============================================================
# CHECK 1: PowerShell Parse Check
# ============================================================

Write-CheckHeader "1/7" "PowerShell Parse Check"

$psFiles = @(Get-ChildItem -Path $PlatformRoot -Recurse -Include '*.ps1','*.psm1' -File |
    Where-Object { $_.FullName -notmatch '\\21022026\\' })

$parseErrors = 0
foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize((Get-Content $file.FullName -Raw -Encoding UTF8), [ref]$errors) | Out-Null

    if ($errors -and $errors.Count -gt 0) {
        Write-Fail "$($file.Name): $($errors.Count) parse error(s)"
        foreach ($err in $errors) {
            Write-Host "           Line $($err.Token.StartLine): $($err.Message)" -ForegroundColor DarkRed
        }
        $parseErrors++
    }
}

if ($parseErrors -eq 0) {
    Write-Pass "All $($psFiles.Count) PowerShell files parse cleanly"
} else {
    Write-Fail "$parseErrors file(s) have parse errors"
}

# ============================================================
# CHECK 2: PS 7+ Syntax Scan
# ============================================================

Write-CheckHeader "2/7" "PowerShell 7+ Syntax Scan"

# Patterns that indicate PS 7+ syntax (must NOT appear in production code)
$ps7Patterns = @(
    @{ Name = 'Null-coalescing (??)';           Pattern = '[^?]\?\?[^?]' }
    @{ Name = 'Null-coalescing assign (??=)';   Pattern = '\?\?=' }
    @{ Name = 'Null-conditional (?.)';          Pattern = '\?\.' }
    @{ Name = 'Ternary operator (? :)';         Pattern = '\?\s+[^#].*\s+:\s+' }
    @{ Name = 'ForEach-Object -Parallel';       Pattern = 'ForEach-Object\s+-Parallel' }
    @{ Name = 'Pipeline chain (&&)';            Pattern = '\s&&\s' }
    @{ Name = 'Pipeline chain (||)';            Pattern = '\s\|\|\s' }
)

$ps7Violations = 0
foreach ($file in $psFiles) {
    $lines = Get-Content $file.FullName -Encoding UTF8
    $lineNum = 0
    $hereStringDepth = 0
    $inCommentBlock = $false
    foreach ($line in $lines) {
        $lineNum++
        $trimmed = $line.Trim()

        # Track here-string boundaries (skip JS/HTML inside @"..."@ or @'...'@)
        # Here-strings can nest inside $() sub-expressions
        if ($line -match '@"$' -or $line -match "@'$") { $hereStringDepth++; continue }
        if ($trimmed -eq '"@' -or $trimmed -eq "'@" -or $trimmed -match '^"@' -or $trimmed -match "^'@") {
            if ($hereStringDepth -gt 0) { $hereStringDepth-- }
            continue
        }
        if ($hereStringDepth -gt 0) { continue }

        # Track comment blocks (<# ... #>)
        if ($trimmed -match '^<#') { $inCommentBlock = $true }
        if ($inCommentBlock) {
            if ($trimmed -match '#>') { $inCommentBlock = $false }
            continue
        }

        # Skip single-line comments
        if ($trimmed.StartsWith('#')) { continue }
        # Skip lines inside .SYNOPSIS/.DESCRIPTION comment blocks
        if ($lineNum -le 20 -and $trimmed -match '^\.\w+') { continue }

        foreach ($pat in $ps7Patterns) {
            if ($line -match $pat.Pattern) {
                # Skip if it's a regex/pattern definition line
                if ($trimmed -match "Pattern\s*=" -or $trimmed -match "'[^']*\?\?[^']*'") { continue }

                Write-Fail "$($file.Name):$lineNum -- $($pat.Name)"
                Write-Host "           $trimmed" -ForegroundColor DarkRed
                $ps7Violations++
            }
        }
    }
}

if ($ps7Violations -eq 0) {
    Write-Pass "No PS 7+ syntax found in $($psFiles.Count) files"
} else {
    Write-Fail "$ps7Violations PS 7+ syntax violation(s) found"
}

# ============================================================
# CHECK 3: Encoding Scan
# ============================================================

Write-CheckHeader "3/7" "Encoding Scan (em-dash, smart quotes, BOM)"

$encodingIssues = 0
$fixedCount = 0

foreach ($file in $psFiles) {
    $raw = Get-Content $file.FullName -Raw -Encoding UTF8
    $issues = @()

    # Em-dash (U+2014)
    if ($raw -match '\u2014') {
        $issues += "em-dash (U+2014)"
        if ($Fix) {
            $raw = $raw -replace '\u2014', '--'
            Set-Content $file.FullName -Value $raw -Encoding UTF8 -NoNewline
            $fixedCount++
        }
    }

    # En-dash (U+2013)
    if ($raw -match '\u2013') {
        $issues += "en-dash (U+2013)"
        if ($Fix) {
            $raw = $raw -replace '\u2013', '-'
            Set-Content $file.FullName -Value $raw -Encoding UTF8 -NoNewline
            $fixedCount++
        }
    }

    # Smart quotes (U+201C, U+201D, U+2018, U+2019)
    if ($raw -match '[\u201C\u201D]') { $issues += "smart double-quotes" }
    if ($raw -match '[\u2018\u2019]') { $issues += "smart single-quotes" }

    # Ellipsis (U+2026)
    if ($raw -match '\u2026') { $issues += "ellipsis (U+2026)" }

    if ($issues.Count -gt 0) {
        $label = if ($Fix -and ($issues -match 'dash')) { "FIXED" } else { "FAIL" }
        if ($label -eq "FIXED") {
            Write-Warn "$($file.Name): $($issues -join ', ') -- AUTO-FIXED"
        } else {
            Write-Fail "$($file.Name): $($issues -join ', ')"
        }
        $encodingIssues++
    }
}

if ($encodingIssues -eq 0) {
    Write-Pass "No encoding issues in $($psFiles.Count) files"
} elseif ($Fix -and $fixedCount -gt 0) {
    Write-Warn "$fixedCount file(s) auto-fixed, $($encodingIssues - $fixedCount) remaining"
}

# ============================================================
# CHECK 4: Config Section Drift
# ============================================================

Write-CheckHeader "4/7" "Config Section Drift (config.ini)"

$configPath = Join-Path $PlatformRoot 'Config\config.ini'
$expectedSections = @(
    'General', 'Paths', 'Diagnostics', 'HardwareTests',
    'PerformanceBenchmark', 'Repair', 'Fleet', 'Reporting',
    'Security', 'PowerManagement', 'DataCollection', 'Refurbishment',
    'AutoRemediation', 'POSTErrorReader', 'SMARTDiskAnalysis',
    'CMOSBatteryCheck', 'MachineIdentityCheck', 'TPMHealthCheck',
    'Win11ReadinessCheck', 'LenovoVantageCheck', 'MemoryErrorLogCheck',
    'DisplayPixelCheck', 'EnterpriseReadinessReport', 'LDT',
    'QuickStart', 'SmartDiagnosis', 'Display'
)

if (Test-Path $configPath) {
    $iniContent = Get-Content $configPath -Encoding UTF8
    $foundSections = @($iniContent | Where-Object { $_ -match '^\[(.+)\]$' } | ForEach-Object { $Matches[1] })

    $missing = @($expectedSections | Where-Object { $_ -notin $foundSections })
    $extra   = @($foundSections | Where-Object { $_ -notin $expectedSections })

    if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
        Write-Pass "All $($expectedSections.Count) expected sections present, no unexpected sections"
    } else {
        if ($missing.Count -gt 0) {
            Write-Fail "Missing sections: $($missing -join ', ')"
        }
        if ($extra.Count -gt 0) {
            Write-Warn "Unexpected sections: $($extra -join ', ')"
        }
    }
} else {
    Write-Fail "config.ini not found at: $configPath"
}

# ============================================================
# CHECK 5: BAT Routing Validation
# ============================================================

Write-CheckHeader "5/7" "BAT Routing Validation"

$batPath = Join-Path $PlatformRoot 'Laptop_Master_Diagnostic.bat'
if (Test-Path $batPath) {
    $batContent = Get-Content $batPath -Encoding UTF8

    # Extract all "goto run_xxx" targets from CHOICE routing
    $gotoTargets = @($batContent | Where-Object { $_ -match 'goto\s+(run_\w+)' } |
        ForEach-Object { if ($_ -match 'goto\s+(run_\w+)') { $Matches[1] } }) | Sort-Object -Unique

    # Extract all ":run_xxx" labels
    $labels = @($batContent | Where-Object { $_ -match '^:(run_\w+)' } |
        ForEach-Object { if ($_ -match '^:(run_\w+)') { $Matches[1] } }) | Sort-Object -Unique

    $missingLabels = @($gotoTargets | Where-Object { $_ -notin $labels })
    $orphanLabels  = @($labels | Where-Object { $_ -notin $gotoTargets })

    if ($missingLabels.Count -eq 0) {
        Write-Pass "All $($gotoTargets.Count) goto targets have matching labels"
    } else {
        foreach ($ml in $missingLabels) {
            Write-Fail "goto $ml has no matching :$ml label"
        }
    }

    if ($orphanLabels.Count -gt 0) {
        foreach ($ol in $orphanLabels) {
            Write-Warn "Label :$ol exists but no goto points to it"
        }
    }

    # Check option range: verify 0-55 all have routing
    $routedOptions = @($batContent | Where-Object { $_ -match 'if\s+"%CHOICE%"=="(\d+)"' } |
        ForEach-Object { if ($_ -match 'if\s+"%CHOICE%"=="(\d+)"') { [int]$Matches[1] } }) | Sort-Object

    $expectedOptions = 1..55
    # Options 37, 38 may be reserved/unused -- check
    $missingOptions = @($expectedOptions | Where-Object { $_ -notin $routedOptions -and $_ -ne 0 })
    # Option 0 is typically exit

    if ($missingOptions.Count -eq 0) {
        Write-Pass "All options 1-55 have routing entries"
    } else {
        Write-Warn "Unrouted options: $($missingOptions -join ', ')"
    }
} else {
    Write-Fail "Laptop_Master_Diagnostic.bat not found at: $batPath"
}

# ============================================================
# CHECK 6: Version Consistency
# ============================================================

Write-CheckHeader "6/7" "Version Consistency"

$versions = @{}

# config.ini
if (Test-Path $configPath) {
    $iniLines = Get-Content $configPath -Encoding UTF8
    foreach ($line in $iniLines) {
        if ($line -match '^\s*Version\s*=\s*(.+)$') {
            $versions['config.ini'] = $Matches[1].Trim()
            break
        }
    }
}

# BAT title line
if (Test-Path $batPath) {
    $batLines = Get-Content $batPath -Encoding UTF8
    foreach ($line in $batLines) {
        if ($line -match 'title\s+.*v(\d+\.\d+\.\d+)') {
            $versions['BAT (title)'] = $Matches[1].Trim()
            break
        }
    }
}

# Smart_Diagnosis_Engine.ps1 .VERSION
$sdeFile = Join-Path $PlatformRoot 'Smart_Diagnosis_Engine.ps1'
if (Test-Path $sdeFile) {
    $sdeLines = Get-Content $sdeFile -Encoding UTF8 -TotalCount 15
    foreach ($line in $sdeLines) {
        if ($line -match '^\s+(\d+\.\d+\.\d+)') {
            $versions['Smart_Diagnosis_Engine'] = $Matches[1].Trim()
            break
        }
    }
}

# VersionManifest.json
$manifestPath = Join-Path $PlatformRoot 'Config\VersionManifest.json'
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.version) {
        $versions['VersionManifest.json'] = $manifest.version
    }
}

# config.json
$configJsonPath = Join-Path $PlatformRoot 'Config\config.json'
if (Test-Path $configJsonPath) {
    $cjson = Get-Content $configJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cjProps = $cjson | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    if ($cjProps -contains 'platformVersion') {
        $versions['config.json'] = $cjson.platformVersion
    }
}

if ($versions.Count -gt 0) {
    $uniqueVersions = @($versions.Values | Sort-Object -Unique)
    foreach ($k in ($versions.Keys | Sort-Object)) {
        $color = if ($versions[$k] -eq $uniqueVersions[0]) { 'Green' } else { 'Red' }
        Write-Host "    $($k.PadRight(30)) $($versions[$k])" -ForegroundColor $color
    }

    if ($uniqueVersions.Count -eq 1) {
        Write-Pass "All $($versions.Count) sources agree: v$($uniqueVersions[0])"
    } else {
        Write-Fail "Version mismatch: $($uniqueVersions -join ' vs ')"
    }
} else {
    Write-Fail "Could not extract version from any source"
}

# ============================================================
# CHECK 7: VersionManifest Hash Check
# ============================================================

Write-CheckHeader "7/7" "VersionManifest Hash Check"

if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $placeholders = 0
    $valid = 0
    $total = 0

    foreach ($entry in $manifest.files) {
        $total++
        if ($entry.sha256 -match 'PLACEHOLDER') {
            Write-Fail "$($entry.relativePath): hash is PLACEHOLDER"
            $placeholders++
        } else {
            # Verify hash format (64 hex chars)
            if ($entry.sha256 -match '^[A-Fa-f0-9]{64}$') {
                # Optionally verify actual file hash
                $filePath = Join-Path $PlatformRoot $entry.relativePath
                if (Test-Path $filePath) {
                    $actualHash = (Get-FileHash $filePath -Algorithm SHA256).Hash
                    if ($actualHash -eq $entry.sha256) {
                        $valid++
                    } else {
                        Write-Warn "$($entry.relativePath): hash MISMATCH (file was modified since manifest update)"
                    }
                } else {
                    Write-Warn "$($entry.relativePath): file not found"
                }
            } else {
                Write-Fail "$($entry.relativePath): invalid hash format"
                $placeholders++
            }
        }
    }

    if ($placeholders -eq 0) {
        Write-Pass "All $total files have valid SHA256 hashes ($valid verified)"
    } else {
        Write-Fail "$placeholders/$total files have placeholder or invalid hashes"
        Write-Info "Run: Tools\Update-VersionManifest.ps1 to fix"
    }
} else {
    Write-Fail "VersionManifest.json not found"
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "    RESULTS" -ForegroundColor White
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""

$passColor = if ($script:TotalPass -gt 0) { 'Green' } else { 'Gray' }
$failColor = if ($script:TotalFail -gt 0) { 'Red' } else { 'Green' }
$warnColor = if ($script:TotalWarn -gt 0) { 'Yellow' } else { 'Green' }

Write-Host "    PASS: $($script:TotalPass)" -ForegroundColor $passColor
Write-Host "    FAIL: $($script:TotalFail)" -ForegroundColor $failColor
Write-Host "    WARN: $($script:TotalWarn)" -ForegroundColor $warnColor
Write-Host ""

if ($script:TotalFail -eq 0) {
    Write-Host "    PLATFORM VALIDATION: PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "    PLATFORM VALIDATION: FAILED" -ForegroundColor Red
    exit 1
}
