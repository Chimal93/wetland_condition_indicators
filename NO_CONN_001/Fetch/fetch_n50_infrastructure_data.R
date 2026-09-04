# ============================================================
# NO_CONN_001 - fetch raw layers for reconstructing input A, the
# infrastructure/land-use-intensity index (Erikstad et al. 2023,
# "Index Measuring Land Use Intensity - A Gradient-Based Approach").
#
# Downloads the three national N50 Kartdata snapshots (2006/2013/2023)
# and NVE's regulated-lakes dataset, all confirmed CC BY 4.0 / open,
# no login. Writes ONLY into Data/infra_index_source/ - deliberately
# kept out of Data/ directly, since building this index eventually
# needs several large multi-year national files and would otherwise
# clutter the folder.
#
# This script only FETCHES raw layers. It does NOT compute the LUI
# index itself (log-transform, focal-window density count, BI/LCI/ALI
# weighting) - that's a separate build step, once these inputs are in
# place and validated.
#
# Known gaps, deliberately not papered over:
#
#   1. The paper's three time points are 2003/2013/2023. N50's own
#      historical-versions archive only goes back to 2006 - by user's
#      explicit decision, this script fetches 2006 in place of 2003,
#      giving a genuine 3-point series (2006/2013/2023) that just
#      doesn't exactly match Vegar's original 2003 start point.
#   2. The 2006 N50 snapshot is ONLY available in SOSI format (no FGDB/
#      GML/PostGIS - checked directly against Geonorge's metadata).
#      SOSI needs GDAL's SOSI driver, which is NOT bundled in sf's own
#      GDAL. RESOLVED (2026-08-06): see convert_n50_2006_sosi_to_gpkg.R,
#      which converts the raw SOSI this script downloads into a
#      standard GPKG using a local QGIS install's SOSI-capable GDAL.
#      Run that script after this one to make 2006 usable.
#   3. LCI's "other built-up areas" row has no further breakdown even in
#      the source paper's own Table 1 - there's no N50 object type to
#      fetch for it specifically. That's a downstream *definition*
#      question (how do we operationalise "other"?), not a fetch
#      problem, so it's not handled in this script either.
#
# CORRECTED (same day): ALI's "tractor roads and footpaths" was first
# thought to need a separate paywalled product (FKB-TraktorvegSti,
# Norge Digitalt-gated) since N50's `Vegkategori` codelist doesn't list
# them. Wrong - after actually reading the downloaded data, Sti/
# Traktorveg are directly inside N50 itself, just under a different
# attribute: 2013's `N50_VegSti` layer has `OBJTYPE` values "Sti"/
# "Traktorveg"; 2023's `N50_Samferdsel_senterlinje` layer has `typeveg`
# values "sti"/"traktorveg" (100,000+ real records each, both years).
# No FKB fetch needed. Lesson: the object catalog's codelist pages don't
# show every attribute on a type - check real data before concluding
# something's gated.
#
# All object-type -> N50 layer mappings (Bygning, LuftledningLH,
# Veglenke, Bane, Hoppbakke, MastTele, Vindkraftverk, Tårn,
# BymessigBebyggelse, Tettbebyggelse, Industriområde, Lufthavn,
# Rullebane, Steinbrudd, Steintipp, Gruve, Gravplass, SportIdrettPlass,
# Golfbane, Alpinbakke, DyrketMark, Sti, Traktorveg) are documented in
# extract_n50_infrastructure_layers.R's own alias table, not repeated
# here - this script fetches the whole national FGDB per year (that's
# how N50 "landsfiler" are distributed - one file with all layers, not
# per-object-type downloads), so no per-layer filtering happens at
# fetch time. NOTE: 2013 and 2023 use DIFFERENT internal layer/field
# naming schemes (2013 is semi-granular per-type layers; 2023
# consolidates by package+geometry-type with an `objtype` discriminator
# column) - see extract_n50_infrastructure_layers.R for the full
# mapping, a later extraction script will need year-aware logic, not one
# uniform reader.
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
# All relative paths below are anchored to: Indikatorer/NO_CONN_001/R/

source_dir <- file.path("..", "Data", "infra_index_source")
options(timeout = max(1200, getOption("timeout")))  # these are large national files

download_and_unzip <- function(url, dest_dir, label) {
  if (length(list.files(dest_dir)) > 0) {
    cat("Skipping", label, "- already present in", dest_dir, "\n")
    return(invisible(TRUE))
  }
  zip_path <- file.path(dest_dir, basename(url))
  cat("Downloading", label, "...\n  ", url, "\n")
  ok <- tryCatch({
    download.file(url, zip_path, mode = "wb", quiet = FALSE)
    TRUE
  }, error = function(e) {
    message("  FAILED: ", conditionMessage(e))
    FALSE
  })
  if (!ok) return(invisible(FALSE))
  cat("  Unzipping...\n")
  unzip(zip_path, exdir = dest_dir)
  file.remove(zip_path)
  invisible(TRUE)
}

# ---------------------------------------------------------------
# N50 Kartdata, three national snapshots. URLs confirmed directly
# against Geonorge's ATOM feeds (2026-08-06) - each is the single
# "Landsdekkende" (nationwide) entry, EPSG:25833, one file containing
# all N50 layers/packages for that year.
# ---------------------------------------------------------------
n50_years <- list(
  "2006" = list(
    url = "https://nedlasting.geonorge.no/geonorge/Basisdata/N50KartdataHistoriskeData2006/SOSI/Basisdata_0000_Norge_25833_N50KartdataHistoriskeData2006_SOSI.zip",
    dest = file.path(source_dir, "N50", "2006"),
    format = "SOSI"
  ),
  "2013" = list(
    url = "https://nedlasting.geonorge.no/geonorge/Basisdata/N50KartdataHistoriskeData2013/FGDB/Basisdata_0000_Norge_25833_N50KartdataHistoriskeData2013_FGDB.zip",
    dest = file.path(source_dir, "N50", "2013"),
    format = "FGDB"
  ),
  "2023" = list(
    url = "https://nedlasting.geonorge.no/geonorge/Basisdata/N50KartdataHistoriskeData2023/FGDB/Basisdata_0000_Norge_25833_N50KartdataHistoriskeData2023_FGDB.zip",
    dest = file.path(source_dir, "N50", "2023"),
    format = "FGDB"
  )
)

for (yr in names(n50_years)) {
  entry <- n50_years[[yr]]
  if (!dir.exists(entry$dest)) dir.create(entry$dest, recursive = TRUE)
  download_and_unzip(entry$url, entry$dest, paste0("N50 Kartdata ", yr, " (", entry$format, ")"))
}

# ---------------------------------------------------------------
# NVE regulated lakes / hydropower dataset ("Vannkraft, Utbygd og ikke
# utbygd") - the paper cites NVE's "Magasin" page specifically; this
# broader NVE dataset (confirmed open, includes "dammer og regulerte
# innsjøer uavhengig av formål") is the closest confirmed-open match.
# Current snapshot only - no historical archive found/needed for this
# component (ALI is the extended/optional, lowest-weighted part of the
# index).
# ---------------------------------------------------------------
nve_dest <- file.path(source_dir, "NVE_regulated_lakes")
if (!dir.exists(nve_dest)) dir.create(nve_dest, recursive = TRUE)
download_and_unzip(
  "https://nedlasting.geonorge.no/geonorge/Energi/Vannkraft/FGDB/Energi_0000_Norge_25833_Vannkraft_FGDB.zip",
  nve_dest, "NVE Vannkraft (regulated lakes)"
)

# ---------------------------------------------------------------
# Verify what actually got downloaded, and specifically test whether
# the 2006 SOSI file is readable at all - don't assume either way.
# ---------------------------------------------------------------
cat("\n=== Verifying downloads ===\n")
for (yr in names(n50_years)) {
  dest <- n50_years[[yr]]$dest
  files <- list.files(dest, recursive = TRUE)
  cat("\nN50", yr, "(", n50_years[[yr]]$format, ") -", length(files), "file(s) in", dest, "\n")
  if (length(files) == 0) next

  if (n50_years[[yr]]$format == "SOSI") {
    sosi_file <- list.files(dest, pattern = "\\.sos$", full.names = TRUE, recursive = TRUE)[1]
    if (is.na(sosi_file)) {
      message("  No .sos file found after unzip - check archive contents manually.")
      next
    }
    layers <- tryCatch(st_layers(sosi_file), error = function(e) e)
    if (inherits(layers, "error")) {
      cat("  COULD NOT READ SOSI FILE:", conditionMessage(layers), "\n")
      cat("  This confirms the SOSI-driver gap flagged in this script's header comment.\n")
      cat("  Next steps to try: (a) check `sf::st_drivers()` for a SOSI entry and,\n")
      cat("  if missing, install a GDAL build with SOSI support (e.g. OSGeo4W's GDAL,\n")
      cat("  not the CRAN-bundled one); (b) convert via Kartverket's own SOSI tools;\n")
      cat("  or (c) treat 2006 as unusable and fall back to a 2-point 2013/2023 series.\n")
    } else {
      cat("  SOSI file read OK -", nrow(layers), "layer(s) found.\n")
    }
  } else {
    # .gdb is a DIRECTORY, not a file - list.files() alone never returns it
    # (recursive=TRUE returns files *inside* directories, not the directory
    # names themselves). Use list.dirs() instead. Found the hard way: the
    # first version of this check reported "no .gdb found" for both 2013
    # and 2023 even though both had downloaded and extracted correctly.
    gdb_dir <- list.dirs(dest, recursive = TRUE)
    gdb_dir <- gdb_dir[grepl("\\.gdb$", gdb_dir)][1]
    if (is.na(gdb_dir)) {
      message("  No .gdb found after unzip - check archive contents manually.")
      next
    }
    layers <- tryCatch(st_layers(gdb_dir), error = function(e) e)
    if (inherits(layers, "error")) {
      cat("  COULD NOT READ FGDB:", conditionMessage(layers), "\n")
    } else {
      cat("  FGDB read OK -", nrow(layers), "layer(s) found, e.g.:",
          paste(head(layers$name, 5), collapse = ", "), "...\n")
    }
  }

  # Large zips can leave R's unzip() scratch copies (*.zip.tmp/.tmp1)
  # behind - confirmed on the 2023 download (two ~3.9GB leftovers next to
  # the successfully-extracted .gdb). Clean these up; the real .gdb is
  # what matters, not the temp copies unzip() used to get there.
  leftover_tmp <- list.files(dest, pattern = "\\.zip\\.tmp[0-9]*$", full.names = TRUE)
  if (length(leftover_tmp) > 0) {
    cat("  Removing", length(leftover_tmp), "leftover unzip scratch file(s)...\n")
    file.remove(leftover_tmp)
  }
}

leftover_tmp <- list.files(nve_dest, pattern = "\\.zip\\.tmp[0-9]*$", full.names = TRUE)
if (length(leftover_tmp) > 0) file.remove(leftover_tmp)

nve_files <- list.files(nve_dest, recursive = TRUE)
cat("\nNVE regulated lakes -", length(nve_files), "file(s) in", nve_dest, "\n")
if (length(nve_files) > 0) {
  gdb_dir <- list.dirs(nve_dest, recursive = TRUE)
  gdb_dir <- gdb_dir[grepl("\\.gdb$", gdb_dir)][1]
  if (!is.na(gdb_dir)) {
    layers <- tryCatch(st_layers(gdb_dir), error = function(e) e)
    if (inherits(layers, "error")) {
      cat("  COULD NOT READ FGDB:", conditionMessage(layers), "\n")
    } else {
      cat("  FGDB read OK -", nrow(layers), "layer(s) found:",
          paste(layers$name, collapse = ", "), "\n")
    }
  }
}

cat("\n=== Reminder: NOT fetched by this script ===\n")
cat("- FKB-TraktorvegSti (ALI tractor roads/footpaths) - paywalled, Norge Digitalt only.\n")
cat("- 'Other built-up areas' (LCI) - no N50 object type identified; the source paper\n")
cat("  itself doesn't specify one either. A definition question, not a fetch problem.\n")
