# ============================================================
# Quick smoke test: confirms a fresh checkout of this repo actually
# works, using one small real region instead of the full national ANO
# dataset - runs in under a minute instead of several.
#
# COMPLETELY INDEPENDENT FROM Main/ - Main/NO_FUNC_003_wetland_pipeline_
# OpenSource.R is never edited and has zero awareness this script
# exists. Instead, this script:
#   1. Temporarily swaps the real national ANO gpkg for a small-region
#      subset (same file name/path/schema, so Main can't tell the
#      difference).
#   2. Runs Main AS A REAL SEPARATE Rscript SUBPROCESS - literally the
#      same command a collaborator would type themselves, not a
#      source()-in-process shortcut.
#   3. Restores the real ANO data and the real map output afterward, in
#      a tryCatch(finally=...) so this happens even if Main errors -
#      the same backup/restore/verify technique already used to confirm
#      the 2026-08-25 header cleanup didn't break anything (see git
#      history / project memory), just automated here and applied to
#      the input side instead of the output side.
#
# Needs the real ANO data fetched at least once already
# (Fetch/fetch_ano_data.R) - this only FILTERS an existing national
# export down to one region, it doesn't fetch anything itself.
#
# Output: Results/NO_FUNC_003_wetland_map_2019to2021_TEST_AOI.png - a
# clearly-marked test artifact. The real
# Results/NO_FUNC_003_wetland_map_2019to2021.png is left exactly as it
# was before this script ran.
#
# Usage: Rscript quick_test_small_aoi.R
#   Set FUNC003_TEST_REGION to pick a different region (default
#   "Nord-Norge" - typically the fastest, since it's the smallest).
#   Real region names: Nord-Norge, Midt-Norge, Vestlandet, Østlandet,
#   Sørlandet (see Data/NINA/spatial/regions.shp).
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
# Anchored to NO_FUNC_003_Migration/Fetch/ - Data/ and Results/ (below)
# are siblings of this folder, same as they are for Main/.

test_region <- Sys.getenv("FUNC003_TEST_REGION", unset = "Nord-Norge")

ano_dir      <- file.path("..", "Data", "OpenS_data", "ano_data")
real_gpkg    <- file.path(ano_dir, "naturovervaking_eksport.gpkg")
backup_gpkg  <- file.path(ano_dir, "naturovervaking_eksport.gpkg.real_backup")
real_map     <- file.path("..", "Results", "NO_FUNC_003_wetland_map_2019to2021.png")
backup_map   <- file.path("..", "Results", "NO_FUNC_003_wetland_map_2019to2021.png.real_backup")
test_map_out <- file.path("..", "Results", "NO_FUNC_003_wetland_map_2019to2021_TEST_AOI.png")

# Recover automatically if a previous run of this script crashed
# mid-swap and never restored the real data - detectable because the
# backup exists but the "real" path doesn't.
if (!file.exists(real_gpkg) && file.exists(backup_gpkg)) {
  message("Found a leftover backup from an interrupted previous run - restoring it first.")
  file.rename(backup_gpkg, real_gpkg)
}

if (!file.exists(real_gpkg)) {
  stop("Missing ", real_gpkg, "\n",
       "Run Fetch/fetch_ano_data.R first - this script only filters the\n",
       "real national export down to one region, it doesn't fetch anything.")
}

# ---------------------------------------------------------------
# Build the small-region subset (same 2 layers/columns Main reads).
# ---------------------------------------------------------------
cat("Building a small test subset (region:", test_region, ")...\n")

regions <- st_read(file.path("..", "Data", "NINA", "spatial", "regions.shp"), quiet = TRUE)
# regions.shp's own "region" column has a real encoding corruption for
# 2 of 5 rows (Ø/Ø as mojibake) - fixed by id, same as Main's own Stage
# 9 has to work around (there, by overwriting all 5 names outright).
regions$region[regions$id == 3] <- "Østlandet"
regions$region[regions$id == 5] <- "Sørlandet"
if (!test_region %in% regions$region) {
  stop("Unknown FUNC003_TEST_REGION '", test_region, "'. Real region names: ",
       paste(unique(regions$region), collapse = ", "))
}
region_geom <- regions[regions$region == test_region, ]

pts <- st_read(real_gpkg, layer = "ANO_SurveyPoint", quiet = TRUE)
sp  <- st_read(real_gpkg, layer = "ANO_Art", quiet = TRUE) |> st_drop_geometry()

pts_in_region <- st_transform(pts, st_crs(region_geom))
pts_test <- pts[lengths(st_intersects(pts_in_region, region_geom)) > 0, ]
sp_test  <- sp[sp$parentglobalid %in% pts_test$globalid, ]

cat("  ", nrow(pts_test), "survey points,", nrow(sp_test), "species records in", test_region, "\n")
if (nrow(pts_test) == 0) {
  stop("Zero survey points matched '", test_region, "' - can't build a test subset from this region.")
}

# ---------------------------------------------------------------
# Swap in the small subset, run Main as a real subprocess, always
# restore afterward (success or failure) via tryCatch(finally=...).
# ---------------------------------------------------------------
file.rename(real_gpkg, backup_gpkg)
if (file.exists(real_map)) file.rename(real_map, backup_map)

st_write(pts_test, real_gpkg, layer = "ANO_SurveyPoint", quiet = TRUE, append = FALSE)
st_write(sp_test,  real_gpkg, layer = "ANO_Art",         quiet = TRUE, append = FALSE)

rscript_bin <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
main_script <- file.path("..", "Main", "NO_FUNC_003_wetland_pipeline_OpenSource.R")

tryCatch({
  cat("\nRunning Main/NO_FUNC_003_wetland_pipeline_OpenSource.R as a real subprocess",
      "(unmodified, unaware this is a test)...\n\n")
  status <- system2(rscript_bin, shQuote(main_script))
  if (!is.null(status) && status != 0) {
    warning("Main exited with a non-zero status (", status, ") - see output above.")
  } else {
    cat("\nMain completed successfully against the small test subset.\n")
  }
}, finally = {
  # Restore the real ANO data unconditionally.
  file.remove(real_gpkg)
  file.rename(backup_gpkg, real_gpkg)

  # Rename whatever Main just wrote (the small-AOI test map) to a
  # clearly-marked filename, then restore the real map.
  if (file.exists(real_map)) file.rename(real_map, test_map_out)
  if (file.exists(backup_map)) file.rename(backup_map, real_map)

  cat("\nReal ANO data and real map restored - nothing real was left changed.\n")
  if (file.exists(test_map_out)) {
    cat("Test-run map (small AOI, not a real result): ", test_map_out, "\n")
  }
})
