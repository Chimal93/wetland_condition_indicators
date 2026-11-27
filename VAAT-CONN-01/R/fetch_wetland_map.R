# ============================================================
# VAAT-CONN-01 - fetch input B, the wetland/mire probability map
# (Bakkestuen et al. 2023 / "in prep" nationwide follow-up).
#
# Public Geonorge substitute for the private GEE asset
# `users/vegarbakkestuen/Myr168NN`: despite the qmd describing this as
# South-Norway-only (matching the 2023 published paper), the actual
# published Geonorge product's ATOM feed has a single "Landsdekkende"
# (nationwide) entry - likely already the newer, unpublished nationwide
# follow-up map cited in the qmd's own reference list. In practice its
# real coverage still only reaches ~63.5-64.0N (see R/simplify_
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

out_dir <- file.path("..", "data", "wetland_map_source")
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
# Extract with a tool that handles zips this large instead:
#   - on Windows: PowerShell/.NET (built into every Windows install);
#   - on Linux and macOS: the standard `unzip` command (Info-ZIP 6.0 or
#     newer handles large "ZIP64" archives; it is preinstalled on macOS
#     and in the project's Docker image, and on Ubuntu/Debian comes with
#     `sudo apt install unzip`).
if (.Platform$OS.type == "windows") {
  cat("\nExtracting via .NET ZipFile (R's own unzip() can't handle a\n")
  cat("zip this large - confirmed, not just a precaution)...\n")
  ps_cmd <- sprintf(
    'Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory(\'%s\', \'%s\')',
    normalizePath(zip_path), normalizePath(out_dir)
  )
  status <- system2("powershell.exe", c("-NoProfile", "-Command", ps_cmd))
  tool <- "PowerShell/.NET"
} else {
  if (!nzchar(Sys.which("unzip"))) {
    stop("The `unzip` command was not found. Install it (Ubuntu/Debian: ",
         "sudo apt install unzip) or run this script in the project's Docker image. ",
         "Zip left in place at ", zip_path, ".")
  }
  cat("\nExtracting with the `unzip` command (R's own unzip() can't handle a\n")
  cat("zip this large - confirmed, not just a precaution)...\n")
  status <- system2("unzip", c("-o", "-q", shQuote(zip_path), "-d", shQuote(out_dir)))
  tool <- "unzip"
}
if (status != 0) {
  stop(tool, " extraction failed (exit ", status, "). ",
       "Zip left in place at ", zip_path, " for manual inspection.")
}
file.remove(zip_path)

tif <- list.files(out_dir, pattern = "\\.tif$", full.names = TRUE, recursive = TRUE)
cat("\nExtracted GeoTIFF(s):\n")
print(tif)
