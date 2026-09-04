# ============================================================
# NO_CONN_001 - compute the Land Use Intensity (LUI) infrastructure
# index (Erikstad et al. 2023, "Index Measuring Land Use Intensity -
# A Gradient-Based Approach"), from the harmonized BI/LCI/ALI layers
# produced by extract_n50_infrastructure_layers.R.
#
# This is input A of the Connectivity indicator (NO_CONN_001) - the
# original GEE script thresholds this exact index at >2 to build an
# infrastructure mask (`infrastrukturMask = infrastruktur.gt(2)`, see
# NO_CONN_001_wetland_analysis.qmd). Producing that mask/the actual
# connectivity distance calculation is a SEPARATE, later build step -
# this script only produces the LUI raster itself, matching what the
# original GEE asset (`users/vegar/NY_INFRA_IND`) would contain.
#
# ALGORITHM (from the paper, confirmed by direct methodology extraction):
#   1. 100m x 100m national grid.
#   2. For each cell, count how many 100m "presence" cells (grid cells
#      containing at least one relevant feature) fall within a 500m
#      radius circular neighborhood.
#   3. Log-transform each component: component_index = log2(4+X) - 2
#      (constant k=4 chosen so the index climbs 1 unit as counts go
#      0->4->12->28->60).
#   4. Combine: LUI = 2*log2(4+BI) + log2(4+LCI) - 6
#      LUI_ext = 2*log2(4+BI) + log2(4+LCI) - 0.5*log2(4+ALI) - 7
#
# MODELLING CHOICE, documented not hidden: the paper's exact wording for
# step 2 is "only cells with a major fraction of their area situated
# within the circumference of the circle are included" - i.e. an
# area-fraction-weighted circular window. This script instead uses a
# CELL-CENTER-DISTANCE circular kernel (a cell is in the neighborhood if
# its center is within 500m) - the standard definition used by most GIS
# focal-window tools (including terra's own `focalMat(type="circle")`
# at zero threshold) when an exact area-weighted variant isn't
# explicitly requested. The practical difference is confined to the
# handful of boundary cells at the very edge of each 500m circle - not
# expected to materially change results, but flagged here as a real
# simplification, not silently assumed equivalent.
#
# KNOWN INCOMPLETENESS, carried over from the extraction step: LCI is
# missing "other built-up areas" (no confirmed N50 object type, genuinely
# ambiguous even in the source paper's own Table 1). LCI counts here are
# therefore a systematic (if probably minor) undercount relative to the
# original methodology, not a bug.
#
# Output: Data/LUI_output/LUI_<year>.tif and LUI_ext_<year>.tif
# (2-component and 3-component-with-ALI versions), plus the
# intermediate BI/LCI/ALI component-index and raw-count rasters for
# diagnostics/transparency, for each of 2006/2013/2023.
# ============================================================

library(terra)
library(sf)

# The full national grid turned out much bigger than first estimated:
# 177,411,306 cells (11906 x 14901), not the ~38.5M guessed from Norway's
# land AREA - the bounding RECTANGLE around Norway's shape (elongated
# SW-NE, lots of the rectangle is Sweden/Finland/ocean with no N50 data
# at all) is ~4.6x larger than the land area alone. A first national run
# crashed silently (no R error text, just stopped mid-rasterize) -
# consistent with an in-memory OOM crash, not a logic error. Forcing all
# raster operations to be disk-backed/chunked fixes this, at some speed
# cost - confirmed necessary at this scale, not a precautionary guess.
terraOptions(memfrac = 0.4, todisk = TRUE)

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

extracted_dir <- file.path("..", "Data", "infra_index_source", "N50_extracted")
out_dir       <- file.path("..", "Data", "LUI_output")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

RES        <- 100   # metres, per the paper
RADIUS     <- 500   # metres, per the paper
K          <- 4      # log-transform constant, per the paper

years <- c("2006", "2013", "2023")

# ---------------------------------------------------------------
# Optional AOI restriction for testing - set to NULL for a full
# national run. A small bounding box (e.g. around Oslo) is much faster
# to sanity-check the algorithm's behaviour before committing to the
# full country. Set via environment variable so this script doesn't
# need editing to switch modes:
#   LUI_TEST_AOI=oslo   -> small box around central Oslo
#   LUI_TEST_AOI=""     -> full national run (default if unset)
# ---------------------------------------------------------------
test_aoi <- Sys.getenv("LUI_TEST_AOI", unset = "")
aoi_boxes <- list(
  oslo = ext(258000, 268000, 6642000, 6652000)  # 10km x 10km, central Oslo, EPSG:25833
)

# ---------------------------------------------------------------
# Build a shared national (or AOI-restricted) grid template, aligned to
# clean 100m cell boundaries, from 2023's BI_points extent (most
# complete year, and Norway's land extent doesn't change 2006->2023 at
# a scale that matters here).
# ---------------------------------------------------------------
build_grid_template <- function(res, aoi_name) {
  if (nzchar(aoi_name)) {
    e <- aoi_boxes[[aoi_name]]
    if (is.null(e)) stop("Unknown LUI_TEST_AOI value: ", aoi_name)
  } else {
    ref <- st_read(file.path(extracted_dir, "N50_extracted_2023.gpkg"), layer = "BI_points", quiet = TRUE)
    e <- ext(vect(ref))
    e <- ext(floor(e[1] / res) * res, ceiling(e[2] / res) * res,
             floor(e[3] / res) * res, ceiling(e[4] / res) * res)
  }
  rast(e, resolution = res, crs = "EPSG:25833")
}
grid_template <- build_grid_template(RES, test_aoi)
cat("Grid template:", ncol(grid_template), "x", nrow(grid_template), "cells (",
    ncol(grid_template) * nrow(grid_template), "total )\n")

# ---------------------------------------------------------------
# Circular focal kernel: cell-center distance <= RADIUS (see header
# comment re: this vs. the paper's area-fraction wording).
# ---------------------------------------------------------------
make_circle_kernel <- function(res, radius_m) {
  n <- radius_m %/% res
  size <- 2 * n + 1
  kernel <- matrix(0, size, size)
  center <- n + 1
  for (i in 1:size) for (j in 1:size) {
    d <- sqrt(((i - center) * res)^2 + ((j - center) * res)^2)
    if (d <= radius_m) kernel[i, j] <- 1
  }
  kernel
}
kernel_500m <- make_circle_kernel(RES, RADIUS)
cat("Circular kernel:", sum(kernel_500m), "cells within", RADIUS, "m radius.\n")

# ---------------------------------------------------------------
# Rasterize one or more vector layers (from one gpkg) into a single
# binary presence raster on the shared template. Missing layers are
# skipped (not every geometry-type layer exists for every category/
# year - e.g. no LCI_lines anywhere).
# ---------------------------------------------------------------
rasterize_presence <- function(gpkg_path, layer_names, template) {
  presence <- NULL
  avail <- tryCatch(st_layers(gpkg_path)$name, error = function(e) character(0))
  for (ln in layer_names) {
    if (!ln %in% avail) next
    v <- vect(st_read(gpkg_path, layer = ln, quiet = TRUE))
    if (length(v) == 0) next
    r <- rasterize(v, template, field = 1, background = 0, touches = TRUE)
    presence <- if (is.null(presence)) r else max(presence, r, na.rm = TRUE)
  }
  if (is.null(presence)) {
    presence <- template
    values(presence) <- 0
  }
  presence
}

compute_component_index <- function(presence_raster, kernel) {
  count <- focal(presence_raster, w = kernel, fun = "sum", na.rm = TRUE)
  idx <- log2(K + count) - 2
  list(count = count, index = idx)
}

# NVE regulated lakes - single source, shared across all years (no
# historical archive available/needed - ALI is the extended, lowest-
# weighted part of the index). The extraction script writes it into
# N50_extracted/ alongside the
# per-year files (same out_dir was reused there for all outputs), NOT
# one level up - confirmed by checking that script's own out_path.
nve_path <- file.path(extracted_dir, "NVE_extracted_regulated_lakes.gpkg")
if (!file.exists(nve_path)) nve_path <- NA_character_
cat("NVE regulated-lakes source:", nve_path, "\n")

for (yr in years) {
  cat("\n========== YEAR", yr, "==========\n")
  gpkg <- file.path(extracted_dir, paste0("N50_extracted_", yr, ".gpkg"))
  if (!file.exists(gpkg)) { message("  Missing extracted file for ", yr, ", skipping."); next }

  cat("Rasterizing BI presence...\n")
  bi_presence <- rasterize_presence(gpkg, c("BI_points", "BI_lines", "BI_polygons"), grid_template)

  cat("Rasterizing LCI presence...\n")
  lci_presence <- rasterize_presence(gpkg, c("LCI_points", "LCI_polygons"), grid_template)

  cat("Rasterizing ALI presence (N50 + NVE)...\n")
  ali_n50 <- rasterize_presence(gpkg, c("ALI_lines", "ALI_polygons"), grid_template)
  if (!is.na(nve_path)) {
    ali_nve <- rasterize_presence(nve_path, st_layers(nve_path)$name, grid_template)
  } else {
    ali_nve <- grid_template
    values(ali_nve) <- 0
  }
  ali_presence <- max(ali_n50, ali_nve, na.rm = TRUE)

  cat("Computing focal counts + component indices (this is the slow step)...\n")
  bi  <- compute_component_index(bi_presence, kernel_500m)
  lci <- compute_component_index(lci_presence, kernel_500m)
  ali <- compute_component_index(ali_presence, kernel_500m)

  LUI     <- 2 * bi$index + lci$index - 6
  LUI_ext <- 2 * bi$index + lci$index - 0.5 * ali$index - 7

  writeRaster(LUI,     file.path(out_dir, paste0("LUI_", yr, ".tif")),     overwrite = TRUE)
  writeRaster(LUI_ext, file.path(out_dir, paste0("LUI_ext_", yr, ".tif")), overwrite = TRUE)
  writeRaster(bi$count,  file.path(out_dir, paste0("BI_count_", yr, ".tif")),  overwrite = TRUE)
  writeRaster(lci$count, file.path(out_dir, paste0("LCI_count_", yr, ".tif")), overwrite = TRUE)
  writeRaster(ali$count, file.path(out_dir, paste0("ALI_count_", yr, ".tif")), overwrite = TRUE)

  cat("LUI range:", paste(round(range(values(LUI), na.rm = TRUE), 2), collapse = " to "), "\n")
  cat("LUI_ext range:", paste(round(range(values(LUI_ext), na.rm = TRUE), 2), collapse = " to "), "\n")
  cat("Written to", out_dir, "\n")
}

cat("\n\n================================================\n")
cat("LUI COMPUTATION COMPLETE.\n")
cat("Test-mode AOI:", if (nzchar(test_aoi)) test_aoi else "(none - full national run)", "\n")
cat("Remember: LCI is missing 'other built-up areas' (unresolved even at\n")
cat("the source) - a documented, systematic minor undercount, not a bug.\n")
cat("Next step (not done here): threshold LUI > 2 to build the infrastructure\n")
cat("mask and run the actual polygon-distance connectivity calculation.\n")
cat("================================================\n")
