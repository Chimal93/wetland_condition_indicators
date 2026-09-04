# ============================================================
# One-time utility: fetch the Senf & Seidl European forest disturbance map's
# Norway tile from Zenodo and cache it locally as
# Data/OpenS_data/disturbance/disturbance_year_1986-2020_norway.tif, the
# clear-cut mask stratified_chm_sampling.R's filter_disturbed_points() reads
# for Stage 4 (forest reference heights only - wetlands aren't clear-cut
# masked in the original methodology).
#
# This is the one raw input in this pipeline that, until now, had no fetch
# script at all - it was downloaded manually at some point and the .tif
# just placed at the expected path. Written now to close that gap.
#
# Source (public, no auth, CC-BY 4.0):
#   Senf, C. & Seidl, R. (2021) Mapping the forest disturbance regimes of
#   Europe. Nature Sustainability. Data: Zenodo record 7080016 (latest
#   version as of 2026-07-28; check https://zenodo.org/records/7080016 for
#   a newer version number if this URL ever 404s - Zenodo mints a new
#   record id per version but the "latest version" link on the record page
#   always resolves forward).
#   File: norway.zip (~197.5MB, EPSG:3035 / ETRS89-LAEA Europe), annual
#   disturbance-year raster 1986-2020 plus a severity layer and forest mask.
# ============================================================

library(terra)

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

zenodo_url <- "https://zenodo.org/records/7080016/files/norway.zip?download=1"

out_dir      <- file.path("..", "Data", "OpenS_data", "disturbance")
zip_path     <- file.path(out_dir, "norway.zip")
final_path   <- file.path(out_dir, "disturbance_year_1986-2020_norway.tif")
force_fetch  <- FALSE  # set TRUE to re-download/re-extract even if final_path already exists

if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

if (file.exists(final_path) && !force_fetch) {
  cat("Already present:", normalizePath(final_path), "\n")
  cat("Set force_fetch <- TRUE above to re-download/re-extract anyway.\n")
} else {
  cat("Downloading Norway forest disturbance tile from Zenodo (~197.5MB)...\n")
  t0 <- Sys.time()
  download.file(zenodo_url, destfile = zip_path, mode = "wb")
  cat("  took", round(as.numeric(Sys.time() - t0), 1), "sec\n")

  extract_dir <- file.path(out_dir, "_extracted")
  if (dir.exists(extract_dir)) unlink(extract_dir, recursive = TRUE)
  unzip(zip_path, exdir = extract_dir)

  # The zip's internal filename isn't guaranteed to already match this
  # pipeline's expected canonical name, and Senf & Seidl's own naming has
  # changed across dataset versions - search for the disturbance-year
  # raster (as opposed to the accompanying severity/forest-mask layers, if
  # bundled) rather than hardcoding one exact internal filename.
  tifs <- list.files(extract_dir, pattern = "\\.tif$", full.names = TRUE, recursive = TRUE)
  if (length(tifs) == 0) {
    stop("No .tif found inside norway.zip after extraction - the archive's ",
         "internal structure may have changed. Inspect ", extract_dir, " manually.")
  }
  disturbance_tif <- tifs[grepl("disturbance", basename(tifs), ignore.case = TRUE)]
  if (length(disturbance_tif) == 0) {
    disturbance_tif <- tifs[1]
    message("No filename containing 'disturbance' found - using the only/first ",
            ".tif found instead: ", basename(disturbance_tif),
            ". Verify this is actually the disturbance-year layer, not a ",
            "severity or forest-mask layer, before trusting Stage 4's output.")
  } else {
    disturbance_tif <- disturbance_tif[1]
  }

  file.copy(disturbance_tif, final_path, overwrite = TRUE)
  unlink(extract_dir, recursive = TRUE)
  file.remove(zip_path)

  cat("\nVerifying...\n")
  r <- rast(final_path)
  print(r)

  cat("\nSaved:", normalizePath(final_path), "\n")
  cat("stratified_chm_sampling.R's filter_disturbed_points() will now find\n",
      "this file automatically - no manual download step needed.\n", sep = "")
}
