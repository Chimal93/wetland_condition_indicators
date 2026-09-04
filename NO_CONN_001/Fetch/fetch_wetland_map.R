# ============================================================
# NO_CONN_001 - fetch input B, the wetland/mire probability map
# (Bakkestuen et al. 2023 / "in prep" nationwide follow-up).
#
# Public Geonorge substitute for the private GEE asset
# `users/vegarbakkestuen/Myr168NN`: despite the qmd describing this as
# South-Norway-only (matching the 2023 published paper), the actual
# published Geonorge product's ATOM feed has a single "Landsdekkende"
# (nationwide) entry - likely already the newer, unpublished nationwide
# follow-up map cited in the qmd's own reference list. In practice its
# real coverage still only reaches ~63.5-64.0N (see Fetch/simplify_
# wetland_polygons.R's WETLAND_MAP_NORTH_LIMIT_Y) - the "nationwide"
# label is aspirational, not yet accurate.
#
# A first download attempt (2026-08-04, done as a manual scratchpad
# test) turned out to be a truncated/incomplete zip (missing its
# end-of-central-directory record - a classic sign the transfer was
# never actually completed, despite looking "active" at the time it was
# last checked). Re-fetched properly here with a generous timeout and an
# explicit post-download integrity check, so an incomplete file can
# never silently pass as usable.
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

out_dir <- file.path("..", "Data", "wetland_map_source")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

url <- "https://nedlasting.geonorge.no/geonorge/Natur/VatmarkBasertPaNiN/GeoTIFF/Natur_0000_Norge_25833_VatmarkBasertPaNiN_GeoTIFF.zip"
zip_path <- file.path(out_dir, basename(url))

options(timeout = max(1800, getOption("timeout")))

cat("Downloading wetland/mire probability map...\n", url, "\n")
download.file(url, zip_path, mode = "wb", quiet = FALSE)

# The real file is ~8.1GB (confirmed 2026-08-06 - an earlier manual test
# download that looked "active" turned out to have been badly truncated
# at only 1.68GB, ~20% of the true size, and sat unused/unverified for
# 2 days before this was caught). At this size R's bundled `unzip()`
# fails (ZIP64 support gap in its minizip backend -
# "error -103 with zipfile in unzGetCurrentFileInfo") even on a
# complete download - confirmed the zip itself was fine by
# reading it with .NET's System.IO.Compression.ZipFile class instead.
# Extract via PowerShell/.NET rather than R's own unzip() for exactly
# that reason.
cat("\nExtracting via .NET ZipFile (R's own unzip() can't handle a\n")
cat("zip this large - confirmed, not just a precaution)...\n")
ps_cmd <- sprintf(
  'Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory(\'%s\', \'%s\')',
  normalizePath(zip_path), normalizePath(out_dir)
)
status <- system2("powershell.exe", c("-NoProfile", "-Command", ps_cmd))
if (status != 0) {
  stop("PowerShell/.NET extraction failed (exit ", status, "). ",
       "Zip left in place at ", zip_path, " for manual inspection.")
}
file.remove(zip_path)

tif <- list.files(out_dir, pattern = "\\.tif$", full.names = TRUE, recursive = TRUE)
cat("\nExtracted GeoTIFF(s):\n")
print(tif)
