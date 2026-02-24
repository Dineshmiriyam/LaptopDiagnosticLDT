#Requires -Version 5.1
<#
.SYNOPSIS
    LDT AuditExportEngine -- Compliance Artifact Bundle Export

.DESCRIPTION
    Packages all compliance and diagnostic JSON artifacts from a session
    into a single timestamped zip file with a SHA256 manifest.

    This makes it easy to hand off one file to a manager or auditor
    instead of 12+ scattered JSON files.

.NOTES
    Version : 10.0.0
    Platform: PowerShell 5.1+
    Section : S12 (External Audit Mode)
#>

Set-StrictMode -Version Latest

$script:_OperationalBoundary = [ordered]@{
    moduleName     = 'AuditExportEngine'
    version        = '10.0.0'
    canDo          = @(
        'Collect JSON compliance artifacts from Reports directory'
        'Create timestamped zip bundle'
        'Generate SHA256 manifest of all included files'
    )
    cannotDo       = @(
        'Modify compliance artifacts'
        'Delete original artifacts'
        'Send bundles to external services'
        'Access network resources'
    )
}

function Export-AuditBundle {
    <#
    .SYNOPSIS
        Packages all compliance/diagnostic JSON artifacts into a single zip with SHA256 manifest.
    .PARAMETER ReportPath
        Path to the Reports directory containing JSON artifacts.
    .PARAMETER PlatformRoot
        LDT root directory (for resolving relative paths).
    .PARAMETER OutputPath
        Optional. Where to write the zip. Defaults to ReportPath.
    .OUTPUTS
        [ordered] hashtable with BundlePath, ManifestPath, FileCount, TotalSizeKB, GeneratedAt.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportPath,
        [Parameter(Mandatory = $false)]
        [string]$PlatformRoot = '',
        [Parameter(Mandatory = $false)]
        [string]$OutputPath = ''
    )

    if (-not $OutputPath) { $OutputPath = $ReportPath }

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bundleName = "AuditBundle_$timestamp"
    $tempDir = Join-Path $OutputPath $bundleName

    # Create temp staging directory
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

    try {
        # Collect all JSON artifacts from Reports
        $jsonFiles = @()
        if (Test-Path $ReportPath) {
            $jsonFiles = @(Get-ChildItem -Path $ReportPath -Filter '*.json' -File -ErrorAction SilentlyContinue)
        }

        # Also collect HTML reports
        $htmlFiles = @()
        if (Test-Path $ReportPath) {
            $htmlFiles = @(Get-ChildItem -Path $ReportPath -Filter '*.html' -File -ErrorAction SilentlyContinue)
        }

        $allFiles = @($jsonFiles) + @($htmlFiles)

        if ($allFiles.Count -eq 0) {
            # Clean up temp dir
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            return [ordered]@{
                Status      = 'NO_ARTIFACTS'
                BundlePath  = $null
                FileCount   = 0
                GeneratedAt = Get-Date -Format 'o'
                Message     = 'No JSON or HTML artifacts found in Reports directory'
            }
        }

        # Copy all artifacts to staging directory
        $manifestEntries = @()
        $totalSize = 0

        foreach ($file in $allFiles) {
            $destPath = Join-Path $tempDir $file.Name
            Copy-Item -Path $file.FullName -Destination $destPath -Force

            # Compute SHA256 hash
            $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
            $totalSize += $file.Length

            $manifestEntries += [ordered]@{
                fileName = $file.Name
                sha256   = $hash
                sizeBytes = $file.Length
                lastModified = $file.LastWriteTime.ToString('o')
            }
        }

        # Write manifest to staging directory
        $manifest = [ordered]@{
            _type          = 'AUDIT_BUNDLE_MANIFEST'
            bundleName     = $bundleName
            generatedAt    = Get-Date -Format 'o'
            computerName   = $env:COMPUTERNAME
            fileCount      = $manifestEntries.Count
            totalSizeBytes = $totalSize
            files          = $manifestEntries
        }
        $manifestPath = Join-Path $tempDir 'AuditManifest.json'
        $manifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

        # Create zip using .NET (PS 5.1 compatible)
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zipPath = Join-Path $OutputPath "$bundleName.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $tempDir,
            $zipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false  # do not include base directory name
        )

        # Compute hash of the final zip
        $zipHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash

        # Clean up staging directory
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        $totalSizeKB = [math]::Round($totalSize / 1KB, 1)
        $zipSizeKB = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)

        return [ordered]@{
            Status       = 'SUCCESS'
            BundlePath   = $zipPath
            BundleHash   = $zipHash
            FileCount    = $manifestEntries.Count
            TotalSizeKB  = $totalSizeKB
            ZipSizeKB    = $zipSizeKB
            GeneratedAt  = Get-Date -Format 'o'
        }
    }
    catch {
        # Clean up on failure
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        return [ordered]@{
            Status      = 'ERROR'
            BundlePath  = $null
            FileCount   = 0
            GeneratedAt = Get-Date -Format 'o'
            Error       = $_.Exception.Message
        }
    }
}

Export-ModuleMember -Function @(
    'Export-AuditBundle'
)
