# ============================================================
# NO_CONN_001 - AR5 variant, end to end, region by region.
#   1. prepare wetland patches per region    (Fetch/prepare_ar5_mire_regions.R)
#   2. certified nearest-mire distance       (Fetch/run_region_certified.R)
#   3. infrastructure distance + kvotient    (Fetch/compute_infra_distance_region.R)
#   4. scaling + regional map + write-out    (Fetch/scale_and_map_connectivity_indicator.R)
# Everything goes to Data/wetland_map_ar5, Data/connectivity_output_ar5 and
# label "national_2023_AR5" - the model-based results are never touched.
# Resumable: each step skips a region whose output already exists.
#
# Run from this folder:  powershell -ExecutionPolicy Bypass -File .\run_connectivity_ar5.ps1
# Logs: %TEMP%\conn001_ar5\<step>_<Region>.log
# ============================================================
$ErrorActionPreference = "Continue"
# Point $env:RSCRIPT at your own Rscript.exe if R is installed elsewhere.
$Rscript = if ($env:RSCRIPT) { $env:RSCRIPT } else { "C:\Program Files\R\R-4.6.1\bin\Rscript.exe" }
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir  = Join-Path $env:TEMP "conn001_ar5"
New-Item -ItemType Directory -Force $logDir | Out-Null

$env:CONNECTIVITY_MIRE_DIR    = "..\Data\wetland_map_ar5"
$env:CONNECTIVITY_OUT_DIR     = "..\Data\connectivity_output_ar5"
$env:CONNECTIVITY_SCORE_DIR   = "..\Data\connectivity_output_ar5"
$env:CONNECTIVITY_SCORE_PATTERN = "connectivity_full_2023\.gpkg$"
$env:CONNECTIVITY_SCORE_LABEL = "national_2023_AR5"

$regions = @("Nord-Norge", "Sorlandet", "Vestlandet", "Midt-Norge", "Ostlandet")   # ASCII names; the R scripts map them
$ascii   = @{ "Nord-Norge" = "nord_norge"; "Midt-Norge" = "midt_norge"; "Vestlandet" = "vestlandet"; "Ostlandet" = "ostlandet"; "Sorlandet" = "sorlandet" }

Set-Location (Join-Path $here "Fetch")
$t0 = Get-Date
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] AR5 connectivity run started" | Tee-Object -FilePath (Join-Path $logDir "run.log") -Append

# 1. prepare all regions (skips those already done)
$env:CONNECTIVITY_REGIONS = ($regions -join ",")
& $Rscript "prepare_ar5_mire_regions.R" *> (Join-Path $logDir "prepare.log")
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] prepare done" | Tee-Object -FilePath (Join-Path $logDir "run.log") -Append

foreach ($r in $regions) {
  $a = $ascii[$r]
  $env:CONNECTIVITY_REGION = $r
  $cert = Join-Path $here ("Data\connectivity_output_ar5\" + $a + "_min_myr_distance_certified.gpkg")
  $full = Join-Path $here ("Data\connectivity_output_ar5\" + $a + "_connectivity_full_2023.gpkg")
  if (-not (Test-Path $cert)) {
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] $r certified NN distance ..." | Tee-Object -FilePath (Join-Path $logDir "run.log") -Append
    & $Rscript "run_region_certified.R" *> (Join-Path $logDir ("certified_" + $a + ".log"))
  } else { "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] $r certified NN distance - exists, skipped" | Tee-Object -FilePath (Join-Path $logDir "run.log") -Append }
  if (-not (Test-Path $full)) {
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] $r infrastructure distance ..." | Tee-Object -FilePath (Join-Path $logDir "run.log") -Append
    & $Rscript "compute_infra_distance_region.R" *> (Join-Path $logDir ("infra_" + $a + ".log"))
  } else { "[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] $r infrastructure distance - exists, skipped" | Tee-Object -FilePath (Join-Path $logDir "run.log") -Append }
}

"[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] scaling + write-out (label national_2023_AR5) ..." | Tee-Object -FilePath (Join-Path $logDir "run.log") -Append
& $Rscript "scale_and_map_connectivity_indicator.R" *> (Join-Path $logDir "scale.log")
$dt = (Get-Date) - $t0
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm')] ALL DONE in $([math]::Round($dt.TotalHours, 1)) h" | Tee-Object -FilePath (Join-Path $logDir "run.log") -Append
