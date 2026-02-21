#Requires -Version 5.1
<#
.SYNOPSIS
    LDT Manifest Updater — Computes and writes real SHA256 hashes into VersionManifest.json

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
Write-Host "  LDT Manifest Updater — Computing SHA256 hashes" -ForegroundColor Cyan
Write-Host "  Platform Root: $PlatformRoot" -ForegroundColor Gray
Write-Host ""

$updated = 0; $missing = 0

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
Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
$missingColor = if ($missing -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "  Updated : $updated file(s)" -ForegroundColor Green
Write-Host "  Missing : $missing file(s)" -ForegroundColor $missingColor
Write-Host "  Manifest: $manifestPath" -ForegroundColor Gray
Write-Host "  Hash    : $selfHash" -ForegroundColor Cyan
Write-Host ""
Write-Host "  VersionManifest.json is now the integrity baseline." -ForegroundColor Green
Write-Host ""
