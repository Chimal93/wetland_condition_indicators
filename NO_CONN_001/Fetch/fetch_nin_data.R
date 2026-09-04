# ============================================================
# NO_CONN_001 - fetch the national NiN (Natur i Norge) nature-type
# dataset, used here ONLY as a fallback wetland/mire source for the
# area north of ~64N that the Bakkestuen et al. probability map
# (fetch_wetland_map.R) doesn't actually cover, despite its "nationwide"
# filename - confirmed from the raster's own real extent.
#
# Same public source used identically in NO_GJEN_001/NO_GJEN_002/
# NO_NDVI_001 - copied here unmodified (self-contained pipelines
# preference: each indicator keeps its own local copy rather than
# reading another indicator's Data folder).
#
# Public, no login: Miljodirektoratet's own download service.
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

out_dir <- file.path("..", "Data", "nin_data")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

gdb_existing <- list.files(out_dir, pattern = "\\.gdb$", full.names = TRUE, recursive = FALSE)
if (length(gdb_existing) > 0) {
  cat("NiN gdb already present at", gdb_existing[1], "- skipping download.\n")
  quit(save = "no", status = 0)
}

url <- "https://nedlasting.miljodirektoratet.no/Miljodata/Naturtyper_nin/FILEGDB/4326/Naturtyper_nin_0000_norge_4326_FILEGDB.zip"
zip_path <- file.path(out_dir, basename(url))

options(timeout = max(900, getOption("timeout")))
cat("Downloading national NiN dataset...\n", url, "\n")
download.file(url, zip_path, mode = "wb", quiet = FALSE)

cat("Unzipping...\n")
utils::unzip(zip_path, exdir = out_dir)
file.remove(zip_path)

gdb <- list.files(out_dir, pattern = "\\.gdb$", full.names = TRUE)
cat("Done. NiN gdb at:", gdb, "\n")
