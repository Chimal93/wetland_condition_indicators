# ============================================================
# One-time utility: fetch the latest ANO (Arealrepresentativ
# naturovervåking) national field-monitoring export from
# Miljødirektoratet's public download service and cache it locally.
# Confirmed public, no auth required - both a direct file URL AND a
# manual GUI download link are available from the same Kartkatalog page.
#
# Source: https://kartkatalog.miljodirektoratet.no/Dataset/Details/2054
#   Manual download (GUI, no login): same page, "Geopackage (GPKG)" link.
#   Direct URL (used below):
#     https://nedlasting.miljodirektoratet.no/naturovervaking/naturovervaking_eksport.gpkg.zip
#   Also available as a File Geodatabase (.gdb.zip) from the same page -
#   this script uses the GeoPackage instead: a single self-contained file,
#   no need to unzip into a .gdb directory, and it matches the format of
#   the already-present (older, manually-downloaded) reference copy at
#   Data/NINA/Raw_Data/naturovervaking_eksport.gpkg.zip, making a direct
#   layer-for-layer comparison straightforward.
#   Layers: ANO_SurveyPoint (points), ANO_Flate (survey plot polygons),
#   ANO_Art (species records), ANO_FremmedArt (alien species),
#   ANO_Problemart (problem species), ANO_Treslag (tree species).
# ============================================================

library(sf)

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

ano_url <- "https://nedlasting.miljodirektoratet.no/naturovervaking/naturovervaking_eksport.gpkg.zip"

out_dir     <- file.path("..", "Data", "OpenS_data", "ano_data")
zip_path    <- file.path(out_dir, "naturovervaking_eksport.gpkg.zip")
gpkg_path   <- file.path(out_dir, "naturovervaking_eksport.gpkg")
force_fetch <- FALSE

if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

if (file.exists(gpkg_path) && !force_fetch) {
  cat("Already present:", normalizePath(gpkg_path), "\n")
  cat("Set force_fetch <- TRUE above to re-download anyway (e.g. to pick up a newer export).\n")
} else {
  cat("Downloading latest national ANO export...\n")
  t0 <- Sys.time()
  download.file(ano_url, destfile = zip_path, mode = "wb")
  cat("  download took", round(as.numeric(Sys.time() - t0), 1), "sec\n")

  unzip(zip_path, exdir = out_dir)
  file.remove(zip_path)

  if (!file.exists(gpkg_path)) {
    stop("No .gpkg found after extraction - archive structure may have ",
         "changed. Inspect ", out_dir, " manually.")
  }
}

cat("\nVerifying layers...\n")
print(st_layers(gpkg_path))
cat("\nSaved:", normalizePath(gpkg_path), "\n")
