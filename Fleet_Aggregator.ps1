# Fleet_Aggregator.ps1 -- Merge fleet CSV files from multiple USB drives
# Usage: Run from LDT menu (Option 54) or standalone
# Input: Folder containing CSV files (default: Results folder on USB)
# Output: Master_Fleet_Report.csv with deduplicated, scored fleet data

param (
    [string]$InputPath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Continue'

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Fleet CSV Aggregator" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host

# Determine paths
$scriptRoot = $PSScriptRoot
if (-not $InputPath) {
    Write-Host "  Select CSV source:" -ForegroundColor Yellow
    Write-Host "    [1] USB Results folder ($scriptRoot\Results)" -ForegroundColor White
    Write-Host "    [2] USB Reports folder ($scriptRoot\Reports)" -ForegroundColor White
    Write-Host "    [3] Custom folder path" -ForegroundColor White
    Write-Host
    $srcChoice = Read-Host "  Select (1-3)"
    switch ($srcChoice) {
        '1' { $InputPath = Join-Path $scriptRoot 'Results' }
        '2' { $InputPath = Join-Path $scriptRoot 'Reports' }
        '3' {
            $InputPath = Read-Host "  Enter full folder path"
            $InputPath = $InputPath.Trim('"').Trim("'")
        }
        default { $InputPath = Join-Path $scriptRoot 'Results' }
    }
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $scriptRoot 'Results'
}

# Ensure output folder exists
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

Write-Host "`n  Scanning: $InputPath" -ForegroundColor Yellow

# Find all CSV files
$csvFiles = @()
if (Test-Path $InputPath) {
    $csvFiles = @(Get-ChildItem -Path $InputPath -Filter '*.csv' -Recurse -ErrorAction SilentlyContinue)
}

if ($csvFiles.Count -eq 0) {
    Write-Host "  No CSV files found in $InputPath" -ForegroundColor Red
    Write-Host "  Run Option 8 (Advanced Diagnostic) or Option 40 (Enterprise Readiness)" -ForegroundColor Yellow
    Write-Host "  on target laptops first to generate fleet data." -ForegroundColor Yellow
    Write-Host
    Read-Host "  Press Enter to continue"
    exit 0
}

Write-Host "  Found $($csvFiles.Count) CSV file(s):" -ForegroundColor Green
foreach ($f in $csvFiles) {
    Write-Host "    - $($f.Name) ($([math]::Round($f.Length/1KB,1))KB)" -ForegroundColor Gray
}

# Import and merge all CSVs
$allRows = @()
$importErrors = 0
foreach ($f in $csvFiles) {
    try {
        $rows = @(Import-Csv -Path $f.FullName -ErrorAction Stop)
        if ($rows.Count -gt 0) {
            # Tag with source file
            foreach ($row in $rows) {
                $row | Add-Member -NotePropertyName '_SourceFile' -NotePropertyValue $f.Name -Force
            }
            $allRows += $rows
        }
    } catch {
        $importErrors++
        Write-Host "    SKIP: $($f.Name) - $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

Write-Host "`n  Total rows imported: $($allRows.Count)" -ForegroundColor Cyan
if ($importErrors -gt 0) {
    Write-Host "  Import errors: $importErrors" -ForegroundColor Yellow
}

if ($allRows.Count -eq 0) {
    Write-Host "  No data rows found in CSV files." -ForegroundColor Red
    Read-Host "  Press Enter to continue"
    exit 0
}

# Deduplicate by SerialNumber (keep latest scan per device)
$hasSerial = $allRows | Where-Object { $_.SerialNumber -and $_.SerialNumber -ne '' }
$noSerial = $allRows | Where-Object { -not $_.SerialNumber -or $_.SerialNumber -eq '' }

$deduped = @()
if ($hasSerial.Count -gt 0) {
    $grouped = $hasSerial | Group-Object -Property SerialNumber
    foreach ($group in $grouped) {
        # Keep the row with the latest ScanDate
        $sorted = $group.Group | Sort-Object -Property {
            try { [datetime]$_.ScanDate } catch { [datetime]::MinValue }
        } -Descending
        $deduped += $sorted | Select-Object -First 1
    }
}
# Add rows without serial numbers as-is
$deduped += $noSerial

Write-Host "  Unique devices: $($deduped.Count) (from $($allRows.Count) total rows)" -ForegroundColor Green

# Sort by OverallScore or OverallStatus
$sorted = $deduped | Sort-Object -Property {
    if ($_.OverallScore) { [int]$_.OverallScore } else { 999 }
}

# Remove internal _SourceFile column for clean export
$cleanRows = $sorted | Select-Object -Property * -ExcludeProperty '_SourceFile'

# Export Master Fleet Report
$masterFile = Join-Path $OutputPath "Master_Fleet_Report.csv"
$cleanRows | Export-Csv -Path $masterFile -NoTypeInformation -Force -Encoding UTF8

Write-Host "`n  ===== FLEET AGGREGATION COMPLETE =====" -ForegroundColor Cyan
Write-Host "  Output: $masterFile" -ForegroundColor Green
Write-Host "  Devices: $($deduped.Count)" -ForegroundColor White
Write-Host "  Source files: $($csvFiles.Count)" -ForegroundColor White

# Quick fleet summary if OverallScore/OverallStatus exists
$hasScore = $deduped | Where-Object { $_.OverallScore }
$hasStatus = $deduped | Where-Object { $_.OverallStatus }
if ($hasScore.Count -gt 0) {
    $scores = $hasScore | ForEach-Object { [int]$_.OverallScore }
    $avgScore = [math]::Round(($scores | Measure-Object -Average).Average, 1)
    $minScore = ($scores | Measure-Object -Minimum).Minimum
    $maxScore = ($scores | Measure-Object -Maximum).Maximum
    Write-Host "`n  Fleet Score Summary:" -ForegroundColor Yellow
    Write-Host "    Average: $avgScore / 100" -ForegroundColor White
    Write-Host "    Lowest:  $minScore" -ForegroundColor $(if ($minScore -lt 50) {'Red'} else {'Yellow'})
    Write-Host "    Highest: $maxScore" -ForegroundColor Green
} elseif ($hasStatus.Count -gt 0) {
    $passCount = @($deduped | Where-Object { $_.OverallStatus -eq 'PASS' }).Count
    $warnCount = @($deduped | Where-Object { $_.OverallStatus -eq 'WARNING' }).Count
    $failCount = @($deduped | Where-Object { $_.OverallStatus -eq 'FAIL' }).Count
    Write-Host "`n  Fleet Status Summary:" -ForegroundColor Yellow
    Write-Host "    PASS:    $passCount" -ForegroundColor Green
    Write-Host "    WARNING: $warnCount" -ForegroundColor Yellow
    Write-Host "    FAIL:    $failCount" -ForegroundColor Red
}

# Generate Fleet Dashboard HTML
Write-Host "`n  Generating Fleet Dashboard..." -ForegroundColor Yellow
try {
    New-FleetDashboard -FleetData $deduped -OutputPath $OutputPath -CsvPath $masterFile
} catch {
    Write-Host "  Dashboard generation failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "`n  Open $masterFile in Excel to sort and filter." -ForegroundColor Gray
Write-Host
Read-Host "  Press Enter to continue"

# ============================================================
# FLEET DASHBOARD HTML GENERATOR
# ============================================================

function New-FleetDashboard {
    param(
        [array]$FleetData,
        [string]$OutputPath,
        [string]$CsvPath
    )

    $dashFile = Join-Path $OutputPath "Fleet_Dashboard.html"
    $genDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $totalDevices = $FleetData.Count

    # Scoring data
    $scoredDevices = @($FleetData | Where-Object { $_.OverallScore })
    $hasScores = ($scoredDevices.Count -gt 0)

    $avgScore = 0; $minScore = 0; $maxScore = 0
    $passCount = 0; $warnCount = 0; $failCount = 0
    $bucketA = 0; $bucketB = 0; $bucketC = 0; $bucketD = 0; $bucketF = 0

    if ($hasScores) {
        $scores = $scoredDevices | ForEach-Object { [int]$_.OverallScore }
        $avgScore = [math]::Round(($scores | Measure-Object -Average).Average, 1)
        $minScore = ($scores | Measure-Object -Minimum).Minimum
        $maxScore = ($scores | Measure-Object -Maximum).Maximum

        foreach ($s in $scores) {
            if ($s -ge 90) { $bucketA++ }
            elseif ($s -ge 80) { $bucketB++ }
            elseif ($s -ge 70) { $bucketC++ }
            elseif ($s -ge 60) { $bucketD++ }
            else { $bucketF++ }
        }
    }

    # Status counts
    $passCount = @($FleetData | Where-Object { $_.OverallStatus -eq 'PASS' }).Count
    $warnCount = @($FleetData | Where-Object { $_.OverallStatus -eq 'WARNING' }).Count
    $failCount = @($FleetData | Where-Object { $_.OverallStatus -eq 'FAIL' }).Count

    # Score distribution bar percentages
    $pctA = if ($scoredDevices.Count -gt 0) { [math]::Round($bucketA / $scoredDevices.Count * 100, 1) } else { 0 }
    $pctB = if ($scoredDevices.Count -gt 0) { [math]::Round($bucketB / $scoredDevices.Count * 100, 1) } else { 0 }
    $pctC = if ($scoredDevices.Count -gt 0) { [math]::Round($bucketC / $scoredDevices.Count * 100, 1) } else { 0 }
    $pctD = if ($scoredDevices.Count -gt 0) { [math]::Round($bucketD / $scoredDevices.Count * 100, 1) } else { 0 }
    $pctF = if ($scoredDevices.Count -gt 0) { [math]::Round($bucketF / $scoredDevices.Count * 100, 1) } else { 0 }

    # Worst devices (bottom 5)
    $worstDevices = @()
    if ($hasScores) {
        $worstDevices = @($scoredDevices | Sort-Object { [int]$_.OverallScore } | Select-Object -First 5)
    }

    # Build worst devices HTML
    $worstHtml = ""
    if ($worstDevices.Count -gt 0) {
        $worstHtml = '<div class="section"><h2>Devices Needing Attention</h2><div class="worst-grid">'
        foreach ($w in $worstDevices) {
            $wScore = if ($w.OverallScore) { $w.OverallScore } else { "?" }
            $wColor = if ([int]$wScore -lt 50) { "#E2231A" } elseif ([int]$wScore -lt 70) { "#F59E0B" } else { "#4A8BEF" }
            $wName = if ($w.ComputerName) { $w.ComputerName } else { "Unknown" }
            $wModel = if ($w.Model) { $w.Model } else { "-" }
            $wSerial = if ($w.SerialNumber) { $w.SerialNumber } else { "-" }
            $wGrade = if ($w.LetterGrade) { $w.LetterGrade } else { "-" }
            $worstHtml += "<div class='worst-card' style='border-left:4px solid $wColor'><div class='worst-score' style='color:$wColor'>$wScore</div><div class='worst-info'><strong>$wName</strong><br>$wModel | $wSerial | Grade: $wGrade</div></div>"
        }
        $worstHtml += '</div></div>'
    }

    # Build device table rows
    $tableRows = ""
    foreach ($device in $FleetData) {
        $dName   = if ($device.ComputerName)  { $device.ComputerName }  else { "-" }
        $dSerial = if ($device.SerialNumber)  { $device.SerialNumber }  else { "-" }
        $dModel  = if ($device.Model)         { $device.Model }         else { "-" }
        $dScore  = if ($device.OverallScore)  { $device.OverallScore }  else { "-" }
        $dGrade  = if ($device.LetterGrade)   { $device.LetterGrade }   else { "-" }
        $dStatus = if ($device.OverallStatus) { $device.OverallStatus } else { "-" }
        $dDate   = if ($device.ScanDate)      { $device.ScanDate }      else { "-" }

        $rowClass = "row-default"
        if ($dScore -ne "-") {
            $scoreVal = [int]$dScore
            if ($scoreVal -ge 70) { $rowClass = "row-pass" }
            elseif ($scoreVal -ge 50) { $rowClass = "row-warn" }
            else { $rowClass = "row-fail" }
        } elseif ($dStatus -eq "PASS") { $rowClass = "row-pass" }
        elseif ($dStatus -eq "WARNING") { $rowClass = "row-warn" }
        elseif ($dStatus -eq "FAIL") { $rowClass = "row-fail" }

        $tableRows += "<tr class='$rowClass'><td>$dName</td><td>$dSerial</td><td>$dModel</td><td>$dScore</td><td>$dGrade</td><td>$dStatus</td><td>$dDate</td></tr>`n"
    }

    # Build the full HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="dark">
<title>Fleet Dashboard - LDT v6.1 - $genDate</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0A0F1A;color:#F5F7FA;font-family:'Segoe UI',sans-serif;font-size:14px;line-height:1.7;padding:40px 20px}
.container{max-width:1100px;margin:0 auto}
h1{font-size:28px;margin-bottom:4px;letter-spacing:1px}
h1 span{color:#4A8BEF}
h2{font-size:18px;font-weight:600;margin-bottom:16px;color:#F5F7FA}
.subtitle{color:#7A8BA8;font-size:13px;margin-bottom:32px}
.summary-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;margin-bottom:32px}
.stat-card{padding:24px;background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);border-radius:12px;text-align:center}
.stat-value{font-size:36px;font-weight:700;line-height:1.2}
.stat-label{font-size:12px;color:#7A8BA8;margin-top:4px;text-transform:uppercase;letter-spacing:1px}
.section{padding:24px;background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);border-radius:12px;margin-bottom:24px}
.bar-row{display:flex;align-items:center;margin-bottom:8px}
.bar-label{width:80px;font-size:12px;color:#7A8BA8}
.bar-track{flex:1;height:24px;background:rgba(255,255,255,0.06);border-radius:4px;overflow:hidden;margin:0 12px}
.bar-fill{height:100%;border-radius:4px;display:flex;align-items:center;padding-left:8px;font-size:11px;color:#fff;min-width:2px;transition:width 0.3s}
.bar-count{width:40px;font-size:12px;color:#A0B8D0;text-align:right}
.worst-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px}
.worst-card{padding:16px;background:rgba(255,255,255,0.03);border-radius:8px;display:flex;align-items:center;gap:16px}
.worst-score{font-size:28px;font-weight:700;min-width:50px;text-align:center}
.worst-info{font-size:12px;color:#A0B8D0;line-height:1.6}
.worst-info strong{color:#F5F7FA;font-size:14px}
.table-wrap{overflow-x:auto;border-radius:12px;background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08)}
table{width:100%;border-collapse:collapse;font-size:13px;min-width:700px}
th{text-align:left;padding:12px 14px;color:#4A8BEF;font-size:10px;text-transform:uppercase;letter-spacing:1.5px;border-bottom:1px solid rgba(26,93,204,0.3);font-weight:400;cursor:pointer;user-select:none;position:sticky;top:0;background:#0D1320}
th:hover{color:#6BA3FF}
th::after{content:' \25B4';font-size:8px;opacity:0.3;margin-left:4px}
th.sort-asc::after{content:' \25B4';opacity:1}
th.sort-desc::after{content:' \25BE';opacity:1}
td{padding:10px 14px;border-bottom:1px solid rgba(255,255,255,0.04);color:#A0B8D0}
tr:nth-child(even){background:rgba(255,255,255,0.02)}
tr:hover{background:rgba(26,93,204,0.08)}
.row-pass td:first-child{border-left:3px solid #00C875}
.row-warn td:first-child{border-left:3px solid #F59E0B}
.row-fail td:first-child{border-left:3px solid #E2231A}
.footer{margin-top:40px;text-align:center;color:rgba(122,139,168,0.4);font-size:11px}
@media(max-width:768px){.summary-grid{grid-template-columns:1fr 1fr}.worst-grid{grid-template-columns:1fr}}
@media print{body{background:#fff;color:#111;padding:20px}h1,h2{color:#111}h1 span{color:#1A5DCC}.stat-card,.section,.table-wrap{background:#f8f8f8;border-color:#ccc}.stat-value{color:#111}.stat-label,.subtitle{color:#555}td,th{color:#333;border-color:#ccc}tr:nth-child(even){background:#f0f0f0}.worst-card{background:#f8f8f8;border-color:#ccc}.bar-track{background:#e0e0e0}.footer{color:#999}}
</style>
</head>
<body>
<div class="container">
  <h1>FLEET <span>DASHBOARD</span></h1>
  <div class="subtitle">LDT v6.1 - Generated $genDate - $totalDevices device(s) from $($csvFiles.Count) CSV file(s)</div>

  <div class="summary-grid">
    <div class="stat-card"><div class="stat-value" style="color:#4A8BEF">$totalDevices</div><div class="stat-label">Total Devices</div></div>
    <div class="stat-card"><div class="stat-value" style="color:$(if ($avgScore -ge 70) {'#00C875'} elseif ($avgScore -ge 50) {'#F59E0B'} else {'#E2231A'})">$avgScore</div><div class="stat-label">Avg Score</div></div>
    <div class="stat-card"><div class="stat-value" style="color:#00C875">$passCount</div><div class="stat-label">Pass</div></div>
    <div class="stat-card"><div class="stat-value" style="color:#F59E0B">$warnCount</div><div class="stat-label">Warning</div></div>
    <div class="stat-card"><div class="stat-value" style="color:#E2231A">$failCount</div><div class="stat-label">Fail</div></div>
  </div>

  $(if ($hasScores) { @"
  <div class="section">
    <h2>Score Distribution</h2>
    <div class="bar-row"><div class="bar-label">90-100 (A)</div><div class="bar-track"><div class="bar-fill" style="width:${pctA}%;background:#00C875">$(if ($pctA -gt 5) { "${pctA}%" })</div></div><div class="bar-count">$bucketA</div></div>
    <div class="bar-row"><div class="bar-label">80-89 (B)</div><div class="bar-track"><div class="bar-fill" style="width:${pctB}%;background:#34D399">$(if ($pctB -gt 5) { "${pctB}%" })</div></div><div class="bar-count">$bucketB</div></div>
    <div class="bar-row"><div class="bar-label">70-79 (C)</div><div class="bar-track"><div class="bar-fill" style="width:${pctC}%;background:#F59E0B">$(if ($pctC -gt 5) { "${pctC}%" })</div></div><div class="bar-count">$bucketC</div></div>
    <div class="bar-row"><div class="bar-label">60-69 (D)</div><div class="bar-track"><div class="bar-fill" style="width:${pctD}%;background:#F97316">$(if ($pctD -gt 5) { "${pctD}%" })</div></div><div class="bar-count">$bucketD</div></div>
    <div class="bar-row"><div class="bar-label">0-59 (F)</div><div class="bar-track"><div class="bar-fill" style="width:${pctF}%;background:#E2231A">$(if ($pctF -gt 5) { "${pctF}%" })</div></div><div class="bar-count">$bucketF</div></div>
  </div>
"@ })

  $worstHtml

  <div class="table-wrap">
    <table id="fleetTable">
      <thead><tr><th data-sort="text">Computer</th><th data-sort="text">Serial</th><th data-sort="text">Model</th><th data-sort="number">Score</th><th data-sort="text">Grade</th><th data-sort="text">Status</th><th data-sort="text">Scan Date</th></tr></thead>
      <tbody>
$tableRows
      </tbody>
    </table>
  </div>

  <div class="footer">LDT v6.1 &middot; Fleet Dashboard &middot; Source: $(Split-Path $CsvPath -Leaf)</div>
</div>

<script>
(function(){
  var ths = document.querySelectorAll('th[data-sort]');
  for (var i = 0; i < ths.length; i++) {
    ths[i].addEventListener('click', function() {
      var th = this;
      var table = th.closest('table');
      var tbody = table.querySelector('tbody');
      var rows = [];
      var trs = tbody.querySelectorAll('tr');
      for (var j = 0; j < trs.length; j++) { rows.push(trs[j]); }
      var colIdx = 0;
      var sibs = th.parentNode.children;
      for (var k = 0; k < sibs.length; k++) { if (sibs[k] === th) { colIdx = k; break; } }
      var sortType = th.getAttribute('data-sort');
      var asc = th.getAttribute('data-order') !== 'asc';
      var allThs = th.parentNode.querySelectorAll('th');
      for (var m = 0; m < allThs.length; m++) { allThs[m].removeAttribute('data-order'); allThs[m].className = ''; }
      th.setAttribute('data-order', asc ? 'asc' : 'desc');
      th.className = asc ? 'sort-asc' : 'sort-desc';
      rows.sort(function(a, b) {
        var aVal = a.children[colIdx].textContent.trim();
        var bVal = b.children[colIdx].textContent.trim();
        if (sortType === 'number') {
          var aNum = parseFloat(aVal) || 0;
          var bNum = parseFloat(bVal) || 0;
          return asc ? aNum - bNum : bNum - aNum;
        }
        return asc ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
      });
      for (var n = 0; n < rows.length; n++) { tbody.appendChild(rows[n]); }
    });
  }
})();
</script>
</body>
</html>
"@

    $html | Out-File -FilePath $dashFile -Encoding UTF8 -Force
    Write-Host "  Fleet Dashboard saved: $dashFile" -ForegroundColor Green
}
