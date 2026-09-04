# ============================================================
# Quick smoke test: confirms a fresh checkout of this repo actually
# works, using one small real region (default Nord-Norge) instead of
# the full national AR5 skog/myr datasets - a few minutes instead of
# the 2+ hours a genuine cold-cache national run takes (see README).
#
# COMPLETELY INDEPENDENT FROM Main/ - Main/NO_GJEN_001_wetland_pipeline_
# OpenSource.R is never edited and has zero awareness this script
# exists. Instead, this script:
#   1. Temporarily swaps the real national AR5 skog/myr gpkgs for a
#      small-region subset (same file names/paths/schema, so Main can't
#      tell the difference), and hides Stage 4/5/6's cached CSV/gpkg
#      outputs so Main is forced through the real compute path on all
#      three stages, not a stale national cache.
#   2. Runs Main AS A REAL SEPARATE Rscript SUBPROCESS - literally the
#      same command a collaborator would type themselves, not a
#      source()-in-process shortcut.
#   3. Restores the real AR5 data, the real caches, and the real
#      Results/ folder afterward, in a tryCatch(finally=...) so this
#      happens even if Main errors. Any cache the test run itself
#      created (i.e. didn't exist before) is deleted rather than kept -
#      a small-region cache masquerading as a national one would
#      silently corrupt a later real run.
#
# Needs the real AR5 data extracted at least once already
# (Fetch/extract_ar5_skog_myr.R, or the AR50 fallback builders) - this
# only FILTERS an existing national extract down to one region, it
# doesn't fetch/extract anything itself. Falls back to the AR50 files
# if AR5 isn't present, same preference order as Main itself.
#
# Output: Results_TEST_AOI/ - a clearly-marked, separate folder holding
# whatever this test run produced. The real Results/ folder is left
# exactly as it was before this script ran.
#
# Usage: Rscript quick_test_small_aoi.R
#   Set GJEN001_TEST_REGION to pick a different region (default
#   "Nord-Norge" - typically the fastest, since it's the smallest).
#   Real region names: Nord-Norge, Midt-Norge, Vestlandet, Østlandet,
#   Sørlandet (see Data/OpenS_data/regions.shp).
# ============================================================

library(sf)
library(dplyr)

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
# Anchored to NO_GJEN_001_Migration/Fetch/ - Data/ and Results/ (below)
# are siblings of this folder, same as they are for Main/.

test_region <- Sys.getenv("GJEN001_TEST_REGION", unset = "Nord-Norge")
spatial_dir <- file.path("..", "Data", "OpenS_data")

# ---------------------------------------------------------------
# Everything this script temporarily swaps out. Each has a
# ".real_backup" sibling used for the swap/restore.
# ---------------------------------------------------------------
skog_ar5   <- file.path(spatial_dir, "ar5_skog_national.gpkg")
skog_ar50  <- file.path(spatial_dir, "ar50_skog_national.gpkg")
myr_ar5    <- file.path(spatial_dir, "ar5_myr_national.gpkg")
myr_ar50   <- file.path(spatial_dir, "ar50_myr_national.gpkg")

cache_skog <- file.path(spatial_dir, "vegHeights_skog_climZoneRegion_openS.csv")
cache_ref  <- file.path(spatial_dir, "refvaatmark_NINA_median", "refvaatmark_openS.csv")
cache_pop  <- file.path(spatial_dir, "vaatmark_pop_openS.gpkg")

results_dir      <- file.path("..", "Results")
results_test_dir <- file.path("..", "Results_TEST_AOI")

backup_of <- function(path) paste0(path, ".real_backup")

# Recover automatically if a previous run of this script crashed
# mid-swap and never restored the real data - detectable because a
# backup exists but the "real" path doesn't.
recover_leftover_backup <- function(real_path) {
  b <- backup_of(real_path)
  if (!file.exists(real_path) && file.exists(b)) {
    message("Found a leftover backup from an interrupted previous run - restoring: ", real_path)
    if (file.exists(real_path)) file.remove(real_path)
    file.rename(b, real_path)
  }
}
for (p in c(skog_ar5, skog_ar50, myr_ar5, myr_ar50, cache_skog, cache_pop)) recover_leftover_backup(p)
if (!dir.exists(results_dir) && dir.exists(backup_of(results_dir))) {
  message("Found a leftover Results/ backup from an interrupted previous run - restoring it.")
  file.rename(backup_of(results_dir), results_dir)
}

# Which AR5/AR50 pair actually exists on disk, preferring AR5 - same
# preference order as Main's own Stage 4/6.
skog_real <- if (file.exists(skog_ar5)) skog_ar5 else if (file.exists(skog_ar50)) skog_ar50 else NULL
myr_real  <- if (file.exists(myr_ar5))  myr_ar5  else if (file.exists(myr_ar50))  myr_ar50  else NULL
if (is.null(skog_real) || is.null(myr_real)) {
  stop(
    "Missing forest/wetland polygon data - need EITHER AR5 or AR50 for both.\n",
    "Run extract_ar5_skog_myr.R (needs personal AR5 access), or\n",
    "build_ar50_skog.R + build_ar50_wetland_lidar_coverage.R (fully open), first."
  )
}
cat("Using", basename(skog_real), "/", basename(myr_real), "as the source to subset from.\n")

# ---------------------------------------------------------------
# Build the small-region subset. wkt_filter pushes the spatial test
# down to GDAL/the gpkg's own spatial index (same technique already
# used by the building-filter code in Main) - fast even against a
# multi-million-feature national layer.
# ---------------------------------------------------------------
cat("Building a small test subset (region:", test_region, ")...\n")

regions <- st_read(file.path(spatial_dir, "regions.shp"), quiet = TRUE)
# Known double-encoding bug in this file's DBF for 2 of 5 rows - same
# fix Main's own Stage 2 applies.
regions$region[regions$id == 3] <- "Østlandet"
regions$region[regions$id == 5] <- "Sørlandet"
if (!test_region %in% regions$region) {
  stop("Unknown GJEN001_TEST_REGION '", test_region, "'. Real region names: ",
       paste(unique(regions$region), collapse = ", "))
}
region_geom <- regions[regions$region == test_region, ]

subset_layer <- function(src_path, region_geom) {
  # st_layers() reads only the layer's metadata (CRS included) - no
  # features - so this stays fast even against a multi-GB source.
  src_crs <- st_layers(src_path)$crs[[1]]
  region_wkt <- st_as_text(st_union(st_geometry(st_transform(region_geom, src_crs))))
  st_read(src_path, wkt_filter = region_wkt, quiet = TRUE)
}

skog_test <- subset_layer(skog_real, region_geom)
myr_test  <- subset_layer(myr_real,  region_geom)
cat("  ", nrow(skog_test), "skog polygons,", nrow(myr_test), "myr polygons in/near", test_region, "\n")
if (nrow(skog_test) == 0 || nrow(myr_test) == 0) {
  stop("Zero polygons matched '", test_region, "' in one of the two layers - can't build a test subset from this region.")
}

# ---------------------------------------------------------------
# Swap in the small subset + hide the 3 stage caches, run Main as a
# real subprocess, always restore afterward (success or failure) via
# tryCatch(finally=...).
# ---------------------------------------------------------------
invisible(file.rename(skog_real, backup_of(skog_real)))
invisible(file.rename(myr_real,  backup_of(myr_real)))
st_write(skog_test, skog_real, delete_dsn = TRUE, quiet = TRUE)
st_write(myr_test,  myr_real,  delete_dsn = TRUE, quiet = TRUE)

had_cache_skog <- file.exists(cache_skog)
had_cache_ref  <- file.exists(cache_ref)
had_cache_pop  <- file.exists(cache_pop)
if (had_cache_skog) invisible(file.rename(cache_skog, backup_of(cache_skog)))
if (had_cache_ref)  invisible(file.rename(cache_ref,  backup_of(cache_ref)))
if (had_cache_pop)  invisible(file.rename(cache_pop,  backup_of(cache_pop)))

if (dir.exists(results_dir)) invisible(file.rename(results_dir, backup_of(results_dir)))

rscript_bin <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
main_script <- file.path("..", "Main", "NO_GJEN_001_wetland_pipeline_OpenSource.R")

tryCatch({
  cat("\nRunning Main/NO_GJEN_001_wetland_pipeline_OpenSource.R as a real subprocess",
      "(unmodified, unaware this is a test)...\n\n")
  status <- system2(rscript_bin, shQuote(main_script))
  if (!is.null(status) && status != 0) {
    warning("Main exited with a non-zero status (", status, ") - see output above.")
  } else {
    cat("\nMain completed successfully against the small test subset.\n")
  }
}, finally = {
  # Restore the real AR5/AR50 layers unconditionally.
  file.remove(skog_real)
  file.rename(backup_of(skog_real), skog_real)
  file.remove(myr_real)
  file.rename(backup_of(myr_real), myr_real)

  # Restore each cache if it existed before, otherwise delete whatever
  # the test just wrote - a Nord-Norge-only cache must never be left
  # behind looking like a real national one.
  restore_cache <- function(real_path, had_before) {
    if (file.exists(real_path)) file.remove(real_path)
    if (had_before) file.rename(backup_of(real_path), real_path)
  }
  restore_cache(cache_skog, had_cache_skog)
  restore_cache(cache_ref,  had_cache_ref)
  restore_cache(cache_pop,  had_cache_pop)

  # Whatever Main just wrote is the small-AOI test output - keep it
  # under a clearly-marked separate folder, then restore the real one.
  if (dir.exists(results_dir)) {
    if (dir.exists(results_test_dir)) unlink(results_test_dir, recursive = TRUE)
    file.rename(results_dir, results_test_dir)
  }
  if (dir.exists(backup_of(results_dir))) file.rename(backup_of(results_dir), results_dir)

  cat("\nReal AR5/AR50 data, real caches, and real Results/ restored - nothing real was left changed.\n")
  if (dir.exists(results_test_dir)) {
    cat("Test-run outputs (small AOI, not a real result): ", results_test_dir, "\n")
  }

  # Sanity-check print: compare this test's regional index for
  # test_region against the real (just-restored) national run's value
  # for the same region, if both are available.
  test_shp <- file.path(results_test_dir, "NO_GJEN_001_wetland_index_region_OpenSource.shp")
  real_shp <- file.path(results_dir,      "NO_GJEN_001_wetland_index_region_OpenSource.shp")
  if (file.exists(test_shp) && file.exists(real_shp)) {
    test_val <- st_read(test_shp, quiet = TRUE) %>% st_drop_geometry() %>% filter(region == test_region)
    real_val <- st_read(real_shp, quiet = TRUE) %>% st_drop_geometry() %>% filter(region == test_region)
    if (nrow(test_val) == 1 && nrow(real_val) == 1) {
      cat("\nSanity check -", test_region, "index: test run =", round(test_val$index, 4),
          " | real national run =", round(real_val$index, 4), "\n")
    }
  }
})
