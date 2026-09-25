# ============================================================
# NO_GJEN_002 - national canopy-height run, one region at a time.
#
# Splitting the national run (24,524 polygons, ~163k tiles, ~88 h, ~75 GB)
# into its five regions caps worst-case loss at ~26 h and peak disk at
# ~22 GB. All 24,524 polygons match exactly one region, so looping over
# the five covers the whole population with nothing left over.
#
# Regions are ordered SMALLEST FIRST deliberately: Vestlandet and
# Sorlandet are ~9-10 h each, so they prove the whole national machinery
# at real scale before a full day is committed to Midt-Norge.
#
# Every region is independently resumable - re-running this script skips
# polygons already in each region's output CSV, and skips tiles already
# predicted. A region that fails does not stop the ones after it.
#
# Estimated per region (projected from the measured 46-polygon run; treat
# as a FLOOR - the 6.65 tiles/polygon rate comes from a sample with no
# large polygons, while nationally a single 446 ha polygon needs ~270):
#     Vestlandet   2,638 polys   ~9.5 h    ~8 GB
#     Sorlandet    2,726 polys   ~9.8 h    ~8 GB
#     Nord-Norge   5,695 polys  ~20.5 h   ~17 GB
#     Ostlandet    6,342 polys  ~22.9 h   ~19 GB
#     Midt-Norge   7,123 polys  ~25.7 h   ~22 GB
#
# Usage:
#   .\run_national_by_region.ps1                     # all five, small first
#   .\run_national_by_region.ps1 -Regions Vestlandet # just one
#   .\run_national_by_region.ps1 -MaxPolygons 20     # tiny smoke test
# ============================================================
param(
  [string[]]$Regions = @("Vestlandet", "Sorlandet", "Nord-Norge", "Ostlandet", "Midt-Norge"),
  [int]$BatchSize = 250,
  [int]$MaxPolygons = 0,
  [string]$WorkRoot = "$env:TEMP\gjen002_national",
  [switch]$KeepScratch
)

$ErrorActionPreference = "Continue"
$proj = Split-Path -Parent $MyInvocation.MyCommand.Path
$rscript = if ($env:RSCRIPT) { $env:RSCRIPT } else { "C:\Program Files\R\R-4.6.1\bin\Rscript.exe" }
if (-not (Test-Path $rscript)) { throw "Rscript not found at $rscript - edit this script." }

# ---------------------------------------------------------------------
# Imagery access. Nothing about any particular provider lives in this
# repository. Supply your own source either way:
#
#   1. environment variables (take precedence):
#        $env:ORTHOPHOTO_SOURCE_PATH   = "D:/imagery/ortho_50cm.tif"
#        $env:ORTHOPHOTO_SOURCE_PATH   = "/vsicurl/https://your.host/ortho_50cm.tif"
#        $env:ORTHOPHOTO_SOURCE_USERPWD = "user:password"   # only if needed
#   2. or a local  orthophoto_access.txt  next to this script, copied from
#      orthophoto_access.template.txt and filled in. It is gitignored.
#
# See the template and METHODOLOGY_CANOPY_HEIGHT.md for what the imagery
# has to satisfy (RGB, <= 0.5 m, projected CRS, GeoTIFF/COG/VRT).
# ---------------------------------------------------------------------
if (-not $env:ORTHOPHOTO_SOURCE_PATH) {
  $accessFile = Join-Path $proj "orthophoto_access.txt"
  if (-not (Test-Path $accessFile)) {
    throw ("No imagery source configured.`n" +
           "  Either set `$env:ORTHOPHOTO_SOURCE_PATH, or copy " +
           "orthophoto_access.template.txt to orthophoto_access.txt and fill it in.")
  }
  $cfg  = Get-Content $accessFile | Where-Object { $_ -notmatch '^\s*#' }
  $get  = { param($k) ($cfg | Select-String "^$k\s*:") -replace "^$k\s*:\s*", "" }
  $url  = (& $get 'url').Trim()
  $user = (& $get 'user').Trim()
  $pw   = (& $get 'password').Trim()
  if (-not $url) { throw "orthophoto_access.txt has no 'url:' value." }
  $env:ORTHOPHOTO_SOURCE_PATH = $url
  if ($user -and $pw) { $env:ORTHOPHOTO_SOURCE_USERPWD = "${user}:${pw}" }
}
Write-Output ("Imagery source: " + ($env:ORTHOPHOTO_SOURCE_PATH -replace '//[^/@]+@', '//<credentials>@'))

$env:CHM_POPULATION    = "national"
$env:CHM_BATCH_SIZE    = "$BatchSize"
$env:CHM_TILE_RESOLUTION = "0.5"     # 25 cm was tested: worse and 3x slower
$env:CHM_CLEAN_BATCH   = if ($KeepScratch) { "0" } else { "1" }
if ($MaxPolygons -gt 0) { $env:CHM_MAX_POLYGONS = "$MaxPolygons" }

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
Push-Location (Join-Path $proj "Fetch")
try {
  foreach ($r in $Regions) {
    $started = Get-Date
    Write-Output ""
    Write-Output "================ $r  (started $($started.ToString('HH:mm:ss'))) ================"
    $env:CHM_REGION   = $r
    # Per-region scratch so a partially-done region is never confused with
    # another, and so -KeepScratch stays inspectable per region.
    $env:CHM_WORK_DIR = Join-Path $WorkRoot ($r -replace '[^A-Za-z0-9]','')
    $log = Join-Path $WorkRoot "$($r -replace '[^A-Za-z0-9]','').log"

    & $rscript run_meta_chm_on_polygons.R 2>&1 | Tee-Object -FilePath $log
    $mins = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    if ($LASTEXITCODE -eq 0) {
      Write-Output "---- $r finished OK in $mins min (log: $log)"
    } else {
      # Keep going: a failed region must not block the rest, and re-running
      # this script resumes that region from its own checkpoint.
      Write-Output "---- $r FAILED (exit $LASTEXITCODE) after $mins min - continuing. Re-run to resume. Log: $log"
    }
  }
} finally {
  Pop-Location
}

Write-Output ""
Write-Output "All requested regions attempted. Outputs: NO_GJEN_002\Data\OpenS_data\meta_chm_national_<Region>.csv"
Write-Output "Any per-polygon failures: ..._failures.csv alongside each output."
Write-Output "Downstream must use meta_chm_mean (validated), not meta_chm_median."
