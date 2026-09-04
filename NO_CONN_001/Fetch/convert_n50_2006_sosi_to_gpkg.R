# ============================================================
# NO_CONN_001 - convert the 2006 N50 SOSI archive into one readable GPKG.
#
# WHY THIS EXISTS: N50's 2006 historical release is only distributed as
# SOSI (no FGDB/GML/PostGIS - confirmed against Geonorge's own metadata).
# SOSI needs GDAL's SOSI driver, which is NOT in the GDAL build bundled
# with the sf package on CRAN (`sf::st_drivers()` has zero SOSI rows on
# this machine). It IS present in QGIS's own bundled GDAL
# (C:/Program Files/QGIS 3.44.12/apps/gdal/lib/gdalplugins/ogr_SOSI.dll,
# GDAL 3.13.1) - confirmed working via QGIS's own ogrinfo/ogr2ogr.
#
# REQUIRES QGIS installed locally (tested against QGIS 3.44.12) - this
# is a genuine machine-specific dependency, not something portable to
# just any R install. If QGIS isn't present, this step can't run; fall
# back to a 2013/2023-only 2-point time series instead (see fetch
# script's header for that option). Once this script has produced the
# GPKG, everything downstream reads it with plain sf - no QGIS needed
# after this point.
#
# The 2006 archive itself is structured very differently from 2013/2023:
# 3004 separate files, one per (kommune x theme) pair, e.g.
# "32_n50_0101bygg.sos" = fylke 32, kommune 0101, theme "bygg". Each
# file is also in its OWN local UTM zone (confirmed: kommune 0101's file
# is EPSG:3044/UTM32N) rather than the national EPSG:25833 used by
# 2013/2023 - reprojected during conversion so all three years end up
# directly comparable.
#
# Only 3 of the 7 per-kommune themes are converted - the ones BI/LCI/ALI
# actually need (admin_omr/hoyde/restrik_omr/stedsnavn are skipped):
#   - bygg        -> Bygninger_og_anlegg (buildings, power lines, towers, etc.)
#   - samferdsel  -> roads/railways (incl. Sti/Traktorveg)
#   - arealdekke  -> land cover (industry, urban fabric, mines, etc.)
#
# Object-type discriminator field confirmed directly: `objekttypenavn`
# - the SOSI driver only exposes generic "points"/"lines"/"polygons"
# geometry-type layers per file, same consolidated-by-geometry-type
# pattern as 2023's FGDB, just at the per-kommune-file level instead of
# one national file.
#
# IMPORTANT, confirmed by reading the converted output: 2006's object-type
# NAME STRINGS differ from 2013/2023's, not just the file structure -
# e.g. `BygningsEnhet` (2006) vs `Bygning` (2013/2023), `Flyplass` vs
# `Lufthavn`, `Sportplass` vs `SportIdrettPlass`, `Industri` vs
# `Industriområde`. `Traktorveg`/`Sti` ARE present under those exact
# names in both vintages, though (94,476 / 73,026 records respectively
# in the 2006 samferdsel_lines layer). Any extraction code reading all
# three years needs a year-aware name-mapping table, not just year-aware
# layer names - don't assume 2013/2023's object-type strings apply here.
#
# Output: Data/infra_index_source/N50/2006/N50_2006.gpkg, with layers
# named <theme>_<geomtype> (e.g. bygg_points, samferdsel_lines,
# arealdekke_polygons) - filter by `objekttypenavn` downstream, same
# pattern as 2013/2023.
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

sosi_dir <- file.path("..", "Data", "infra_index_source", "N50", "2006")
gpkg_out <- file.path(sosi_dir, "N50_2006.gpkg")

qgis_root <- "C:/Program Files/QGIS 3.44.12"
ogr2ogr   <- file.path(qgis_root, "bin", "ogr2ogr.exe")
if (!file.exists(ogr2ogr)) {
  stop(
    "QGIS's ogr2ogr.exe not found at ", ogr2ogr, ".\n",
    "This conversion needs a local QGIS install for its bundled SOSI ",
    "driver (not present in sf's own GDAL). If QGIS isn't installed, or ",
    "is installed at a different version/path, either install/update it ",
    "or edit qgis_root above to match. Alternative: skip 2006 entirely ",
    "and use a 2013/2023-only 2-point time series."
  )
}
Sys.setenv(GDAL_DRIVER_PATH = file.path(qgis_root, "apps", "gdal", "lib", "gdalplugins"))
Sys.setenv(GDAL_DATA = file.path(qgis_root, "share", "gdal"))

if (file.exists(gpkg_out)) {
  cat("GPKG already exists at", gpkg_out, "- delete it first to reconvert. Skipping.\n")
  quit(save = "no", status = 0)
}

themes <- c("bygg", "samferdsel", "arealdekke")
geom_layers <- c("points", "lines", "polygons")

run_ogr2ogr <- function(src, dst_layer) {
  # source sub-layer name inside the SOSI file is just "points"/"lines"/
  # "polygons" - pull it from dst_layer's suffix (e.g. "bygg_points" -> "points")
  src_layer <- sub(".*_", "", dst_layer)
  args <- c("-append", "-update", "-makevalid", "-t_srs", "EPSG:25833",
            "-nln", dst_layer, "-f", "GPKG", gpkg_out, src, src_layer)
  result <- suppressWarnings(system2(ogr2ogr, args, stdout = TRUE, stderr = TRUE))
  status <- attr(result, "status")
  if (!is.null(status) && status != 0) {
    # Most common cause: this particular file has no features of this
    # geometry type (e.g. a "bygg" file with no polygon buildings) -
    # not a real error, just nothing to append. Only surface genuinely
    # unexpected failures.
    if (!any(grepl("Couldn't fetch requested layer|Unable to open", result, ignore.case = TRUE))) {
      cat("  Note (", dst_layer, "on", basename(src), "):", paste(result, collapse = " | "), "\n")
    }
    return(FALSE)
  }
  TRUE
}

total_files <- 0
total_ok <- 0
start_time <- Sys.time()

for (theme in themes) {
  # NOTE: filenames are "<fylke>_n50_<kommune><theme>.sos" - no separator
  # between the kommune code and theme name (e.g. "32_n50_0101bygg.sos"),
  # confirmed directly (a first version of this pattern assumed a "_"
  # there and matched zero files).
  files <- list.files(sosi_dir, pattern = paste0(theme, "\\.sos$"), full.names = TRUE)
  cat("\n=== Theme:", theme, "-", length(files), "kommune file(s) ===\n")
  for (i in seq_along(files)) {
    f <- files[i]
    total_files <- total_files + 1
    ok_any <- FALSE
    for (gl in geom_layers) {
      dst_layer <- paste0(theme, "_", gl)
      ok <- run_ogr2ogr(f, dst_layer)
      if (ok) ok_any <- TRUE
    }
    if (ok_any) total_ok <- total_ok + 1
    if (i %% 50 == 0) {
      elapsed <- round(as.numeric(difftime(Sys.time(), start_time, units = "mins")), 1)
      cat("  ...", i, "/", length(files), "files (", elapsed, "min elapsed)\n")
    }
  }
}

cat("\n=== Done:", total_ok, "/", total_files, "source files contributed at least one feature ===\n")

# ---------------------------------------------------------------
# Verify the result is readable by sf (the actual point of this whole
# exercise) and print a layer summary.
# ---------------------------------------------------------------
library(sf)
if (!file.exists(gpkg_out)) {
  stop("No GPKG was produced - something went wrong upstream, see messages above.")
}
layers <- st_layers(gpkg_out)
cat("\nGPKG layers (", nrow(layers), "):\n")
for (i in seq_len(nrow(layers))) {
  cat(" -", layers$name[i], ":", layers$features[i], "features\n")
}
cat("\n2006 N50 data is now usable exactly like 2013/2023 - read", gpkg_out,
    "with sf::st_read(), filter by the `objekttypenavn` field.\n")
