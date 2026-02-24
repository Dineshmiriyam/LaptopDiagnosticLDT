#Requires -Version 5.1
$files = @(
    'E:\LDT-v6.0\Core\ZeroTrustEngine.psm1',
    'E:\LDT-v6.0\Core\ResilienceEngine.psm1',
    'E:\LDT-v6.0\Core\CertificationEngine.psm1',
    'E:\LDT-v6.0\Core\AuditExportEngine.psm1',
    'E:\LDT-v6.0\Core\GuardEngine.psm1',
    'E:\LDT-v6.0\Core\IntegrityEngine.psm1',
    'E:\LDT-v6.0\Core\ClassificationEngine.psm1',
    'E:\LDT-v6.0\Core\FleetGovernance.psm1',
    'E:\LDT-v6.0\Core\ComplianceExport.psm1',
    'E:\LDT-v6.0\Smart_Diagnosis_Engine.ps1'
)
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.PSParser]::Tokenize(
        (Get-Content $file -Raw), [ref]$parseErrors
    ) | Out-Null
    $name = Split-Path $file -Leaf
    if ($parseErrors.Count -gt 0) {
        Write-Host "  [FAIL] $name -- $($parseErrors.Count) error(s)" -ForegroundColor Red
        foreach ($err in $parseErrors) {
            Write-Host "    Line $($err.Token.StartLine): $($err.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [OK] $name -- zero parse errors" -ForegroundColor Green
    }
}
