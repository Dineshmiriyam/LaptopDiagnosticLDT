#Requires -Version 5.1
<#
.SYNOPSIS
    LDT Manifest Updater -- Computes and writes real SHA256 hashes into VersionManifest.json

.DESCRIPTION
    Run this tool ONCE after deployment or after any platform update to populate
    VersionManifest.json with the true SHA256 hashes of all platform files.

    After running this tool, the VersionManifest becomes a tamper-evident baseline.
    Any subsequent modification will be detected by IntegrityEngine at session start.

.PARAMETER PlatformRoot
    Root directory of the LDT platform. Defaults to parent of this script's directory.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $PlatformRoot = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $PlatformRoot 'Config\VersionManifest.json'

if (-not (Test-Path $manifestPath)) {
    Write-Host "[ERROR] VersionManifest.json not found at: $manifestPath" -ForegroundColor Red
    exit 1
}

$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host ""
Write-Host "  LDT Manifest Updater -- Computing SHA256 hashes" -ForegroundColor Cyan
Write-Host "  Platform Root: $PlatformRoot" -ForegroundColor Gray
Write-Host ""

$updated = 0
$missing = 0

foreach ($entry in $manifest.files) {
    $fullPath = Join-Path $PlatformRoot $entry.relativePath

    if (Test-Path $fullPath) {
        $hash = (Get-FileHash $fullPath -Algorithm SHA256).Hash
        $entry.sha256 = $hash
        $updated++
        Write-Host "  [OK] $($entry.relativePath)" -ForegroundColor Green
        Write-Host "       $hash" -ForegroundColor DarkGray
    } else {
        $missing++
        Write-Host "  [MISSING] $($entry.relativePath)" -ForegroundColor Yellow
    }
}

# Add metadata
$manifest | Add-Member -MemberType NoteProperty -Name '_selfHash' `
    -Value 'COMPUTED_AFTER_WRITE' -Force
$manifest | Add-Member -MemberType NoteProperty -Name '_manifestUpdatedAt' `
    -Value (Get-Date -Format 'o') -Force
$manifest | Add-Member -MemberType NoteProperty -Name '_manifestUpdatedBy' `
    -Value "$env:USERDOMAIN\$env:USERNAME" -Force

$manifest | ConvertTo-Json -Depth 15 | Set-Content $manifestPath -Encoding UTF8

# Compute self-hash and write it back
$selfHash = (Get-FileHash $manifestPath -Algorithm SHA256).Hash
$content  = Get-Content $manifestPath -Raw -Encoding UTF8
$content  = $content -replace '"COMPUTED_AFTER_WRITE"', "`"$selfHash`""
$content  | Set-Content $manifestPath -Encoding UTF8

Write-Host ""
Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
if ($missing -gt 0) { $missingColor = 'Yellow' } else { $missingColor = 'Green' }
Write-Host "  Updated : $updated file(s)" -ForegroundColor Green
Write-Host "  Missing : $missing file(s)" -ForegroundColor $missingColor
Write-Host "  Manifest: $manifestPath" -ForegroundColor Gray
Write-Host "  Hash    : $selfHash" -ForegroundColor Cyan
Write-Host ""
Write-Host "  VersionManifest.json is now the integrity baseline." -ForegroundColor Green
Write-Host ""

# ============================================================
# SECTION 2: Update ApprovedFiles.json with SHA256 hashes
# ============================================================

$approvedPath = Join-Path $PlatformRoot 'Config\ApprovedFiles.json'

if (Test-Path $approvedPath) {
    Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Updating ApprovedFiles.json hashes..." -ForegroundColor Cyan
    Write-Host ""

    $approved = Get-Content $approvedPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $afUpdated = 0
    $afMissing = 0

    foreach ($entry in $approved.files) {
        $fullPath = Join-Path $PlatformRoot $entry.relativePath
        if (Test-Path $fullPath) {
            $hash = (Get-FileHash $fullPath -Algorithm SHA256).Hash
            # Add or update sha256 property
            if ($entry.PSObject.Properties['sha256']) {
                $entry.sha256 = $hash
            } else {
                $entry | Add-Member -MemberType NoteProperty -Name 'sha256' -Value $hash -Force
            }
            $afUpdated++
            Write-Host "  [OK] $($entry.relativePath)" -ForegroundColor Green
            Write-Host "       $hash" -ForegroundColor DarkGray
        } else {
            $afMissing++
            Write-Host "  [MISSING] $($entry.relativePath)" -ForegroundColor Yellow
        }
    }

    # Update generation timestamp
    if ($approved.PSObject.Properties['_generatedAt']) {
        $approved._generatedAt = (Get-Date -Format 'o')
    } else {
        $approved | Add-Member -MemberType NoteProperty -Name '_generatedAt' -Value (Get-Date -Format 'o') -Force
    }

    $approved | ConvertTo-Json -Depth 15 | Set-Content $approvedPath -Encoding UTF8

    Write-Host ""
    Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
    if ($afMissing -gt 0) { $afMissingColor = 'Yellow' } else { $afMissingColor = 'Green' }
    Write-Host "  Updated : $afUpdated file(s)" -ForegroundColor Green
    Write-Host "  Missing : $afMissing file(s)" -ForegroundColor $afMissingColor
    Write-Host "  Manifest: $approvedPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  ApprovedFiles.json hashes are now current." -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host "  [SKIP] ApprovedFiles.json not found at: $approvedPath" -ForegroundColor Yellow
    Write-Host ""
}
