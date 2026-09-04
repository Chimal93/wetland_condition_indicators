# ============================================================
# NO_CONN_001 - Wetland Structural Connectivity - MASTER PIPELINE
# (migration copy - see this folder's README.md first).
#
# Runs the open-source reconstruction of this indicator end to end:
# fetch every raw input, build the infrastructure index, fetch the
# wetland map, compute per-patch distances for all 5 regions, and
# produce the final 0-1 scaled indicator + regional map. The original
# implementation is Google Earth Engine JavaScript, so there is no
# equivalent R version to compare against.
#
# CACHES: a full from-scratch run takes 20+ hours (see RUNTIME below).
# Pre-computed caches are published as GitHub Release assets rather than
# committed to the repository - run Fetch/download_caches.R once to
# retrieve them, after which this script completes in minutes. Each
# stage prints "skipping" when it reads a cache and "no cache found -
# computing" when it does the real work; to re-verify a stage, delete
# the cached path named in its STAGE comment. See README's "Cache vs.
# real compute" section.
#
# RESUMABLE / IDEMPOTENT BY DESIGN: before each stage below, this
# script checks whether that stage's output already exists on disk and
# skips straight to the next stage if so. If it's interrupted (crash,
# reboot, deliberately stopped), just run it again; nothing already
# written to disk gets redone.
#
# ------------------------------------------------------------------
# RAW DATA INPUTS NEEDED (fetch scripts, run automatically below):
#
#   1. N50 Kartdata (Kartverket topographic base map), 3 national
#      snapshots (2006/2013/2023), + NVE regulated-lakes data
#        -> Fetch/fetch_n50_infrastructure_data.R
#   2. Wetland/mire probability map (Bakkestuen et al. 2023 model,
#      public Geonorge substitute for NINA's internal GEE asset)
#        -> Fetch/fetch_wetland_map.R
#   3. NiN (Natur i Norge) nature-type polygons - lower-fidelity
#      fallback wetland source, used only north of ~64N where the
#      Bakkestuen map has zero coverage
#        -> Fetch/fetch_nin_data.R
#   4. Five-region delineation for Norway (regions.shp) + a detailed
#      national coastline outline (outlineOfNorway_EPSG25833.shp, for
#      the final map's basemap only) - both already present in
#      Data/spatial/, no fetch script needed (small, reused reference
#      data).
#
# DERIVED PREREQUISITES (built FROM the raw inputs above by this
# script). Those marked [CACHED] are published as Release assets and
# retrieved by Fetch/download_caches.R:
#   - Data/infra_index_source/N50/2006/N50_2006.gpkg       <- STAGE 2 (QGIS)
#   - Data/infra_index_source/N50_extracted/*.gpkg         <- STAGE 3
#   - Data/LUI_output/LUI_<year>.tif (2006/2013/2023)      <- STAGE 4 [CACHED]
#   - Data/wetland_map_simplified/wetland_simplified_<region>.gpkg   <- STAGE 6a (x5) [CACHED]
#   - Data/connectivity_output_simplified/<region>_min_myr_distance_certified.gpkg <- STAGE 6b (x5) [CACHED]
#   - Data/connectivity_output_simplified/<region>_connectivity_full_2023.gpkg     <- STAGE 6c (x5) [CACHED]
#   - Results/NO_CONN_001_connectivity_condition_map.png (FINAL)      <- STAGE 7
#
# ------------------------------------------------------------------
# EXTERNAL SOFTWARE DEPENDENCIES (detail in README):
#   - STAGE 2 needs QGIS installed locally (SOSI driver) and hardcodes
#     qgis_root in Fetch/convert_n50_2006_sosi_to_gpkg.R - edit that if
#     your install is elsewhere.
#   - STAGE 5 is Windows-only (PowerShell/.NET ZipFile; R's own unzip()
#     does not handle ZIP64).
# Neither applies unless you delete the cache that stage feeds.
#
# ------------------------------------------------------------------
# RUNTIME: STAGE 6b (certified nearest-mire-distance) dominates at ~20
# hours across all 5 regions sequentially, Østlandet alone ~13h. Hence
# the published caches. Per-region figures are in STAGE 7's
# region_distance_runtime_hint below.
#
# ------------------------------------------------------------------
# DEVIATIONS FROM THE ORIGINAL METHODOLOGY: the infrastructure index is
# reconstructed from scratch (the original uses an internal GEE asset),
# 2006 substitutes for 2003, NiN substitutes for the Bakkestuen map
# north of ~64N, and the 0-1 scaling and regional map step is our own
# design - the original does not implement it (GitHub issue #144).
# Full detail in README.md.
# ============================================================

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args   <- commandArgs(trailingOnly = FALSE)
  file_match <- grep("^--file=", cmd_args)
  tried <- tryCatch({
    if (length(file_match) > 0) {
      setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[file_match]))))
    } else {
      setwd(dirname(sys.frame(1)$ofile))
    }
    TRUE
  }, error = function(e) FALSE)
  if (!tried) message("Note: keeping current working directory (", getwd(), ").")
}
# All relative paths below are anchored to: NO_CONN_001_Migration/Main/
# Fetch/ scripts are one level up, then into Fetch/ - each Fetch script
# manages its own working directory the same way, so sourcing them from
# here works regardless of where Rscript itself was launched from.
fetch_script <- function(name) file.path("..", "Fetch", name)

# ---------------------------------------------------------------
# Small helpers - visual stage markers + a consistent "may take a
# while, here's roughly how long" warning, printed BEFORE a stage
# starts, only when that stage is actually about to run (skipped
# stages print a one-line "already done" note instead).
# ---------------------------------------------------------------
cat_stage <- function(msg) {
  cat("\n", strrep("=", 70), "\n", msg, "\n", strrep("=", 70), "\n", sep = "")
}
warn_runtime <- function(msg) {
  cat(">>> If this is the first time running this step: ", msg, "\n\n", sep = "")
}
skip_note <- function(msg) {
  cat_stage(msg)
  cat("Output already present on disk - SKIPPING (reading published cache, not recomputing).\n")
}

pipeline_start <- Sys.time()
cat_stage("NO_CONN_001 MASTER PIPELINE - starting")
cat("Working directory:", getwd(), "\n")
cat("Pre-computed caches are published as Release assets - run\n")
cat("Fetch/download_caches.R first if Data/ looks empty. Watch for\n")
cat("'skipping' vs 'no cache found - computing' to know which stages\n")
cat("are doing real work.\n")

# ================================================================
# STAGE 1: Fetch N50 (2006/2013/2023) + NVE infrastructure source data.
# Internally idempotent already, so this is always sourced directly -
# repeat runs are fast no-ops. NOT part of the published cache (raw
# source data, 29+GB) - this genuinely downloads on a fresh checkout.
# ================================================================
# STAGES 1-3 feed STAGE 4 (the LUI index) and nothing else. If STAGE 4's
# published cache already exists, none of stages 1-3's raw/harmonized
# N50 data (29+GB) is ever actually needed - so this whole block is
# gated on lui_2023_path (defined just below), not just stage-by-stage,
# to avoid downloading tens of GB of raw data purely to feed a
# computation whose output is already sitting on disk.
lui_2023_path <- file.path("..", "Data", "LUI_output", "LUI_2023.tif")
if (!file.exists(lui_2023_path)) {

  cat_stage("STAGE 1: Fetch N50 + NVE infrastructure source data")
  warn_runtime("downloads 3 national N50 snapshots + an NVE dataset (multi-GB each) - can take well over an hour depending on connection speed. Already-cached years/datasets are skipped automatically on re-runs.")
  local({ source(fetch_script("fetch_n50_infrastructure_data.R")) })

  # ================================================================
  # STAGE 2: Convert 2006's SOSI-only N50 archive to a readable GPKG.
  # REQUIRES QGIS installed locally (see header).
  # ================================================================
  sosi_gpkg_path <- file.path("..", "Data", "infra_index_source", "N50", "2006", "N50_2006.gpkg")
  if (!file.exists(sosi_gpkg_path)) {
    cat_stage("STAGE 2: Convert 2006 N50 SOSI archive to GPKG (via QGIS's bundled GDAL)")
    warn_runtime("converts 3,004 separate per-kommune SOSI files one at a time - not tightly benchmarked, budget on the order of an hour or more. Runs unattended once started. REQUIRES QGIS installed locally (see this script's header).")
    local({ source(fetch_script("convert_n50_2006_sosi_to_gpkg.R")) })
  } else {
    skip_note("STAGE 2: 2006 SOSI->GPKG conversion")
  }

  # ================================================================
  # STAGE 3: Extract/harmonize BI/LCI/ALI layers across all 3 years + NVE.
  # ================================================================
  extracted_2023_path <- file.path("..", "Data", "infra_index_source", "N50_extracted", "N50_extracted_2023.gpkg")
  if (!file.exists(extracted_2023_path)) {
    cat_stage("STAGE 3: Extract/harmonize infrastructure-index input layers")
    warn_runtime("fast - a few minutes, not hours (this is filtering, not the heavy computation).")
    local({ source(fetch_script("extract_n50_infrastructure_layers.R")) })
  } else {
    skip_note("STAGE 3: N50/NVE layer extraction")
  }

  # ================================================================
  # STAGE 4: Compute the national Land-Use-Intensity (LUI) index, all
  # 3 years.
  # ================================================================
  cat_stage("STAGE 4: Compute the national LUI infrastructure index (3 years)")
  warn_runtime("processes a ~177 million-cell national grid, once per year (2006/2013/2023) - not tightly benchmarked, budget at least 30-60 minutes, more on a slower disk (uses disk-backed raster processing throughout).")
  Sys.setenv(LUI_TEST_AOI = "")
  local({ source(fetch_script("compute_lui_infrastructure_index.R")) })

} else {
  skip_note("STAGES 1-4: N50/NVE fetch + LUI infrastructure index [CACHED - raw N50/NVE fetch skipped entirely, not just the LUI computation]")
}

# ================================================================
# STAGE 5: Fetch the wetland/mire probability map (~8.1GB). NOT part
# of the published cache (raw source data) - genuinely downloads on a
# fresh checkout, UNLESS you never need it because Data/
# wetland_map_simplified/ (the published derived cache) already has
# all 5 regions, in which case Stage 6a will skip and this raw file is
# never actually read.
# ================================================================
# STAGES 5-6 feed STAGE 7a (per-region wetland-patch simplification)
# and nothing else, so each is gated on whether any MISSING region
# could actually need it - not just "are all 5 done" - to avoid an
# unnecessary ~8GB+ download for a region that will never touch that
# data. Nord-Norge specifically sits entirely north of Bakkestuen's
# real coverage (WETLAND_MAP_NORTH_LIMIT_Y in Fetch/simplify_wetland_
# polygons.R - must stay in sync if that ever changes) and uses NiN
# exclusively; every other region needs at least some Bakkestuen data.
# Found and fixed 2026-08-27: an earlier all-or-nothing version of this
# gate triggered a pointless 8.1GB download when only Nord-Norge's
# cache was missing - caught by actually forcing that exact scenario,
# not assumed safe.
regionlvl <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
missing_regions <- regionlvl[!file.exists(file.path(
  "..", "Data", "wetland_map_simplified", paste0("wetland_simplified_", regionlvl, ".gpkg")
))]
needs_bakkestuen <- any(missing_regions != "Nord-Norge")
needs_nin        <- length(missing_regions) > 0  # NiN is cheap either way - safe to be conservative

if (needs_bakkestuen) {
  wetland_tif_files <- list.files(file.path("..", "Data", "wetland_map_source"),
                                   pattern = "\\.tif$", recursive = TRUE, full.names = TRUE)
  if (length(wetland_tif_files) == 0) {
    cat_stage("STAGE 5: Fetch the wetland/mire probability map")
    warn_runtime("downloads and extracts an ~8.1GB national GeoTIFF - can take well over an hour depending on connection speed. Extraction itself (PowerShell/.NET, not R's own unzip() - see header) is fast once the download finishes. WINDOWS ONLY as written.")
    local({ source(fetch_script("fetch_wetland_map.R")) })
  } else {
    skip_note("STAGE 5: wetland/mire probability map fetch")
  }
} else {
  skip_note("STAGE 5: wetland/mire probability map fetch [not needed - only Nord-Norge is missing, and it never uses Bakkestuen data]")
}

if (needs_nin) {
  # ================================================================
  # STAGE 6: Fetch NiN nature-type data (northern wetland fallback,
  # used only above ~64N where the Bakkestuen map has no coverage).
  # fetch_nin_data.R DOES call quit() internally when its own output
  # already exists - must not be source()'d in that situation, or it
  # would terminate this whole master session. Gated here for exactly
  # that reason, not just for a progress message.
  # ================================================================
  nin_gdb_files <- list.files(file.path("..", "Data", "nin_data"), pattern = "\\.gdb$", full.names = TRUE)
  if (length(nin_gdb_files) == 0) {
    cat_stage("STAGE 6: Fetch NiN nature-type data (northern wetland fallback)")
    warn_runtime("a single national download - typically a few minutes.")
    local({ source(fetch_script("fetch_nin_data.R")) })
  } else {
    skip_note("STAGE 6: NiN nature-type data fetch")
  }

} else {
  skip_note("STAGE 6: NiN nature-type data fetch [CACHED - all 5 regions already simplified]")
}

# ================================================================
# STAGE 7: Per-region processing - simplify/vectorize, certified exact
# nearest-mire distance, then infrastructure distance + kvotient.
# THIS IS THE DOMINANT COST OF THE WHOLE PIPELINE (see header runtime
# table) - Ostlandet's certified-distance step alone (~13h) is longer
# than every other stage in this script COMBINED. ALL THREE SUB-STAGES
# BELOW ARE GATED BY PUBLISHED CACHES - see each sub-stage's own path.
# ================================================================
ascii_lookup <- c(
  "Nord-Norge" = "nord_norge", "Midt-Norge" = "midt_norge",
  "Vestlandet" = "vestlandet", "Østlandet"  = "ostlandet",
  "Sørlandet"  = "sorlandet"
)
region_distance_runtime_hint <- c(
  "Nord-Norge" = "well under a minute (small, fast NiN-only region)",
  "Midt-Norge" = "roughly 2.4 hours",
  "Vestlandet" = "roughly 3.3 hours",
  "Østlandet"  = "roughly 12.9 hours - the single longest step in this entire pipeline",
  "Sørlandet"  = "roughly 1.1 hours"
)

for (region_r in regionlvl) {
  ascii_r <- ascii_lookup[[region_r]]
  Sys.setenv(CONNECTIVITY_REGION = region_r)

  # --- 7a: simplify/vectorize wetland patches for this region ---
  # GATED BY: Data/wetland_map_simplified/wetland_simplified_<region>.gpkg [CACHED]
  simplified_path_r <- file.path("..", "Data", "wetland_map_simplified",
                                  paste0("wetland_simplified_", region_r, ".gpkg"))
  if (!file.exists(simplified_path_r)) {
    cat_stage(sprintf("STAGE 7a [%s]: simplify + vectorize wetland patches", region_r))
    warn_runtime(sprintf("tiled vectorization for %s - typically 20 minutes to ~2 hours depending on region size/density.", region_r))
    local({ source(fetch_script("simplify_wetland_polygons.R")) })
  } else {
    skip_note(sprintf("STAGE 7a [%s]: wetland-patch simplification [CACHED]", region_r))
  }

  # --- 7b: certified exact nearest-mire distance (THE dominant cost) ---
  # GATED BY: Data/connectivity_output_simplified/<region>_min_myr_distance_certified.gpkg [CACHED]
  certified_path_r <- file.path("..", "Data", "connectivity_output_simplified",
                                 paste0(ascii_r, "_min_myr_distance_certified.gpkg"))
  if (!file.exists(certified_path_r)) {
    cat_stage(sprintf("STAGE 7b [%s]: certified exact nearest-mire-distance computation", region_r))
    warn_runtime(sprintf("for %s, expect this to take %s.", region_r, region_distance_runtime_hint[[region_r]]))
    local({ source(fetch_script("run_region_certified.R")) })
  } else {
    skip_note(sprintf("STAGE 7b [%s]: certified nearest-mire-distance computation [CACHED - this is the ~20h/region step]", region_r))
  }

  # --- 7c: infrastructure distance + kvotient ---
  # GATED BY: Data/connectivity_output_simplified/<region>_connectivity_full_2023.gpkg [CACHED]
  full_path_r <- file.path("..", "Data", "connectivity_output_simplified",
                            paste0(ascii_r, "_connectivity_full_2023.gpkg"))
  if (!file.exists(full_path_r)) {
    cat_stage(sprintf("STAGE 7c [%s]: infrastructure-distance + kvotient", region_r))
    warn_runtime(sprintf("for %s, typically a few minutes to about 10 minutes.", region_r))
    Sys.setenv(CONNECTIVITY_YEAR = "2023")
    local({ source(fetch_script("compute_infra_distance_region.R")) })
  } else {
    skip_note(sprintf("STAGE 7c [%s]: infrastructure-distance computation [CACHED]", region_r))
  }
}

# ================================================================
# STAGE 8: 0-1 scaling, regional aggregation with bootstrap CIs, and
# the final map. Always re-run (cheap - a few minutes, dominated by the
# ~100-120 sec bootstrap step) rather than skip-if-exists, so the final
# outputs always reflect whatever regional data currently exists on
# disk. NOT gated - always genuinely (re)computes, but this is a CHEAP
# stage, not the expensive one.
# ================================================================
cat_stage("STAGE 8: 0-1 scaling, regional aggregation, final map")
warn_runtime("fast - a few minutes (the bootstrap confidence-interval step alone takes ~100-120 seconds; everything else is well under that).")
Sys.setenv(CONNECTIVITY_SCORE_DIR = file.path("..", "Data", "connectivity_output_simplified"))
Sys.setenv(CONNECTIVITY_SCORE_PATTERN = "connectivity_full_2023\\.gpkg$")
local({ source(fetch_script("scale_and_map_connectivity_indicator.R")) })

# ================================================================
# STAGE 9 (optional diagnostic, not part of the real indicator output):
# NINA's own source document has a ambiguous alternative
# description of how the scaled value should be computed - this
# recomputes that alternative reading as a side-check, fully isolated
# from the real pipeline. Always re-run, cheap.
# ================================================================
cat_stage("STAGE 9 (optional diagnostic): mean-distance-ratio side-check")
warn_runtime("fast - well under a minute (reads already-computed data only, no new distance computation).")
local({ source(fetch_script("national_mean-distance_ratio.R")) })

total_elapsed <- round(as.numeric(difftime(Sys.time(), pipeline_start, units = "mins")), 1)
cat_stage(sprintf("NO_CONN_001 MASTER PIPELINE - complete (%s minutes this run)", total_elapsed))
cat("Final map: Results/NO_CONN_001_connectivity_condition_map.png\n")
cat("Diagnostic side-check: Results/national_mean-distance_ratio/\n")
cat("\nReminder: if this run finished in minutes, that's because it read\n")
cat("the published caches (see this script's header banner) - it did NOT\n")
cat("just recompute a 20+ hour national pipeline. See the README's\n")
cat("'Cache vs. real compute' section if you want to verify otherwise.\n")
