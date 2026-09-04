# ============================================================
# Split the national AR5-skog-myr.gpkg (3,468,123 polygons, ARTYPE 30/60
# combined) into two separate files matching this project's existing
# ar50_skog_national.gpkg / ar50_myr_national.gpkg naming convention, so
# build_veght_skog_openS.R and build_vaatmark_pop_openS.R can be pointed
# at AR5 with a one-line path change each, per the swappable-source design
# already used throughout this pipeline.
#
# Uses GDAL's ogr2ogr (via sf::gdal_utils) with a -where filter rather
# than reading the full 11GB source into R first - streams the filtered
# subset directly to the output file.
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

library(sf)

# AR5 is not public - it comes from the user's own institutional access
# (see README), so its location cannot be assumed. Point AR5_SOURCE_GPKG
# at the national AR5-skog-myr.gpkg wherever it lives; the file is read
# in place and never copied, since it is ~10.6GB.
src <- Sys.getenv("AR5_SOURCE_GPKG")
if (!nzchar(src)) src <- file.path("..", "Data", "OpenS_data", "AR5-skog-myr.gpkg")

out_dir  <- file.path("..", "Data", "OpenS_data")
skog_out <- file.path(out_dir, "ar5_skog_national.gpkg")
myr_out  <- file.path(out_dir, "ar5_myr_national.gpkg")

if (!file.exists(src)) {
  stop("Missing AR5 source file: ", src, "\n",
       "AR5 requires institutional access and is not distributed here.\n",
       "Point the script at your own copy, e.g. (PowerShell):\n",
       "  setx AR5_SOURCE_GPKG \"D:\\\\path\\\\to\\\\AR5-skog-myr.gpkg\"\n",
       "or place the file at ", file.path("..", "Data", "OpenS_data", "AR5-skog-myr.gpkg"), ".\n",
       "If you do not have AR5 access, use the fully public AR50 route\n",
       "instead - see this indicator's README.")
}
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

cat("Extracting AR5 Skog (ARTYPE=30) -> ", skog_out, " ...\n", sep = "")
t0 <- Sys.time()
sf::gdal_utils(
  util = "vectortranslate",
  source = src,
  destination = skog_out,
  options = c("-where", "ARTYPE='30'", "-nlt", "PROMOTE_TO_MULTI", "-overwrite")
)
cat("  took", round(as.numeric(Sys.time() - t0), 1), "sec\n")

cat("Extracting AR5 Myr (ARTYPE=60) -> ", myr_out, " ...\n", sep = "")
t0 <- Sys.time()
sf::gdal_utils(
  util = "vectortranslate",
  source = src,
  destination = myr_out,
  options = c("-where", "ARTYPE='60'", "-nlt", "PROMOTE_TO_MULTI", "-overwrite")
)
cat("  took", round(as.numeric(Sys.time() - t0), 1), "sec\n")

cat("\nVerifying...\n")
print(st_layers(skog_out))
print(st_layers(myr_out))

cat("\nDone.\n")
