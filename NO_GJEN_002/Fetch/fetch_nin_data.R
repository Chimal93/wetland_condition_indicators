# ============================================================
# One-time utility: fetch the national NiN nature-type dataset
# ("Naturtyper etter Miljødirektoratets instruks") from Miljødirektoratet's
# public download service and cache it locally.
#
# Copied here (2026-08-05) from NO_GJEN_001/R/fetch_nin_data.R, unchanged,
# per this project's self-contained-pipeline convention (see project
# memory [[feedback_self_contained_pipelines]]) - each indicator keeps its
# own local copy rather than reading cross-folder at runtime.
#
# Purpose here (distinct from NO_GJEN_001's use, which is refvaatmark.csv
# reconstruction): building an AOI polygon set for NO_GJEN_002's own
# orthophoto-tile-download + Meta-model step, with the eventual goal of
# making NO_GJEN_002 fully independent of NO_GJEN_001 (deriving its own
# X0/X100 reference levels from the Meta model + LiDAR directly, rather
# than borrowing NO_GJEN_001's LiDAR-derived CSVs as it does today).
#
# IMPORTANT - this fetch is NOT filtered by ecosystem type at download
# time. It pulls the ENTIRE national geodatabase, all hovedøkosystem
# categories included - confirmed directly (2026-08-05) by inspecting the
# fetched data's own hovedøkosystem field:
#   fjell, ingen, naturligÅpneOmråderILavlandet,
#   naturligÅpneOmråderUnderSkoggrensa, semi-naturligMark, skog, våtmark
# In particular "skog" (forest, 93,256 polygons nationally) IS included -
# no separate/second fetch is needed to get forest NiN polygons for a
# future X0-from-Meta-model reconstruction. Any type filtering (e.g. to
# just "våtmark" + "skog") happens downstream, in whatever script builds
# the actual AOI sample - not here.
#
# Source: https://kartkatalog.miljodirektoratet.no/Dataset/Details/2031
#   https://nedlasting.miljodirektoratet.no/Miljodata/Naturtyper_nin/FILEGDB/4326/
#     Naturtyper_nin_0000_norge_4326_FILEGDB.zip
#   ESRI File Geodatabase, layer "naturtyper_nin_omr", EPSG:4326.
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

nin_url  <- "https://nedlasting.miljodirektoratet.no/Miljodata/Naturtyper_nin/FILEGDB/4326/Naturtyper_nin_0000_norge_4326_FILEGDB.zip"

out_dir  <- file.path("..", "Data", "OpenS_data")
zip_path <- file.path(out_dir, "Naturtyper_nin_0000_norge_4326_FILEGDB.zip")
gdb_dir  <- file.path(out_dir, "nin_data")
force_fetch <- FALSE

if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

gdb_path <- if (dir.exists(gdb_dir)) list.files(gdb_dir, pattern = "\\.gdb$", full.names = TRUE)[1] else NA

if (!is.na(gdb_path) && !force_fetch) {
  cat("Already present:", normalizePath(gdb_path), "\n")
  cat("Set force_fetch <- TRUE above to re-download/re-extract anyway.\n")
} else {
  cat("Downloading national NiN nature-type dataset (large file - can take a while)...\n")
  t0 <- Sys.time()
  download.file(nin_url, destfile = zip_path, mode = "wb")
  cat("  download took", round(as.numeric(Sys.time() - t0), 1), "sec\n")

  unzip(zip_path, exdir = gdb_dir)
  file.remove(zip_path)

  gdb_path <- list.files(gdb_dir, pattern = "\\.gdb$", full.names = TRUE)[1]
  if (is.na(gdb_path)) {
    stop("No .gdb found inside the downloaded zip - archive structure may ",
         "have changed. Inspect ", gdb_dir, " manually.")
  }
}

cat("\nVerifying layer...\n")
print(st_layers(gdb_path))
cat("\nSaved:", normalizePath(gdb_path), "\n")
