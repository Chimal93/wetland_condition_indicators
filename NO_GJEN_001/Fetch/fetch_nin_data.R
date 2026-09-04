# ============================================================
# One-time utility: fetch the national NiN nature-type dataset
# ("Naturtyper etter Miljødirektoratets instruks") from Miljødirektoratet's
# public download service and cache it locally, so Stage 5's future
# open-data reconstruction of refvaatmark.csv (wetland X100 reference
# heights) can filter/sample it without needing NINA-internal server
# access. Confirmed public, no auth required.
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
