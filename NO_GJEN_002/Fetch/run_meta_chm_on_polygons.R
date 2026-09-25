# ============================================================
# NO_GJEN_002 - end-to-end canopy height from REAL ORTHOPHOTO.
#
# Orthophoto (remote COG, read-only) -> aligned 256x256 RGB tiles ->
# Meta HighResCanopyHeight model -> georeferenced predictions -> one
# zonal statistic per polygon. This is the real replacement for the
# PROVISIONAL ETH/Sentinel-2 stand-in (see fetch_eth_canopy_height.R).
#
# USE `meta_chm_mean`, NOT `meta_chm_median`, downstream. These
# predictions are heavily right-skewed (mostly ~0 with a few tall trees),
# so the statistic matters: scored against LiDAR on the 46-polygon test
# set, the mean gives r=0.952 / MAE 0.31 m where the median gives
# r=0.755 / MAE 0.65 m. Both columns are written; only the mean is
# validated.
#
# WHY ORTHOPHOTO-ONLY: this indicator must depend on orthophoto and
# nothing else. Orthophoto is refreshed on a standardised, frequent cycle
# (the entire reason GJEN_002 is separate from the LiDAR-based GJEN_001),
# and keeping the method orthophoto-only means future users are not
# locked into any vendor's derived products. Do NOT substitute a
# ready-made LiDAR-derived CHM.
#
# THE MODEL IS LOADED ONCE PER BATCH, not once per polygon: loading costs
# ~8 s while inference costs ~1 s/tile.
#
# The orthophoto is NEVER modified - see orthophoto_source.R.
#
# ------------------------------------------------------------
# BUILT FOR LONG RUNS. A national run is ~163,000 tiles / ~88 h / ~75 GB
# (see project memory for the per-region breakdown), so three things that
# did not matter for 46 polygons matter a great deal here:
#
#   1. RESUMABLE. The output CSV is the checkpoint of record: on start,
#      polygons already present in it are skipped. Tiles and predictions
#      are per-file on disk, so partially-done work is reused too
#      (predict_tiles.py --skip-existing skips any tile already predicted).
#      An interruption - a sleep, a reboot, a Ctrl-C - costs at most the
#      current batch, not the run.
#   2. BATCHED cut -> infer -> aggregate -> (optional) clean. Doing ALL
#      tiling first would mean ~41 h and ~30 GB before a single prediction
#      exists. Batching bounds disk and produces results incrementally.
#   3. PER-POLYGON ERROR TRAPPING. 16 of the 24,524 national wetland
#      polygons (0.07%) have invalid geometry that aborts sf operations
#      outright. One bad polygon must not kill a multi-hour run - failures
#      are logged to a side CSV and the run continues.
#
# Required env vars:
#   ORTHOPHOTO_SOURCE_PATH     - e.g. "/vsicurl/https://.../ortho.tif"
#   ORTHOPHOTO_SOURCE_USERPWD  - "user:password", if the source needs auth
# Optional:
#   CHM_POPULATION  - "test" (default, the 46 validation polygons) or
#                     "national" (all 24,524 NiN wetland polygons)
#   CHM_REGION      - process only this region (Nord-Norge | Midt-Norge |
#                     Ostlandet | Vestlandet | Sorlandet). Splitting a
#                     national run by region caps worst-case loss at ~26 h
#                     and peak disk at ~22 GB instead of ~88 h / ~75 GB.
#                     All 24,524 polygons match exactly one region, so no
#                     polygon is lost by looping over the five.
#   CHM_BATCH_SIZE  - polygons per cut/infer/aggregate cycle (default 250)
#   CHM_CLEAN_BATCH - "1" to delete each batch's tiles+predictions once
#                     aggregated (keeps disk flat; set "0" to keep them,
#                     which makes re-aggregation free but costs space)
#   CHM_TILE_RESOLUTION - metres/pixel fed to the model (default 0.5).
#                     Sets BOTH model input resolution and tile ground
#                     size (256 px x this). A 25 cm SOURCE was tested and
#                     was slightly WORSE and 3x slower - stay at 0.5 with
#                     the 50 cm ortho.
#   CHM_OUTPUT_NAME - output CSV filename (default derived from
#                     population + region, so per-region runs do not
#                     overwrite each other)
#   CHM_PYTHON / CHM_PYTHONPATH - interpreter and site-packages
#   CHM_WORK_DIR    - scratch dir for tiles/predictions
#   CHM_MAX_POLYGONS- cap, for testing
#
# NOTE on CHM_PYTHON: this machine's Windows Application Control blocks
# .venv_chm\Scripts\python.exe (a venv launcher shim), while the
# uv-managed base interpreter runs fine. Defaults below reflect that;
# override via env vars elsewhere. See CHM_MODEL_SETUP.md.
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

suppressMessages({ library(sf); library(terra); library(dplyr) })
# The national NiN wetland layer contains geometries s2 rejects outright
# ("Loop 0 is not valid: Edge N has duplicate vertex with edge M").
# Everything here is planar (bbox windows, tile grids, zonal stats), so
# planar geometry is both sufficient and robust to those.
sf_use_s2(FALSE)
source("orthophoto_source.R")

data_dir    <- file.path("..", "Data")
spatial_dir <- file.path(data_dir, "spatial")
chm_dir     <- normalizePath(file.path("..", "chm_model"), winslash = "/", mustWork = TRUE)

POPULATION      <- Sys.getenv("CHM_POPULATION", "test")
REGION          <- Sys.getenv("CHM_REGION", "")
BATCH_SIZE      <- as.integer(Sys.getenv("CHM_BATCH_SIZE", "250"))
CLEAN_BATCH     <- Sys.getenv("CHM_CLEAN_BATCH", "1") == "1"
TILE_RESOLUTION <- as.numeric(Sys.getenv("CHM_TILE_RESOLUTION", "0.5"))
MAX_POLYGONS    <- as.integer(Sys.getenv("CHM_MAX_POLYGONS", "0"))

default_name <- paste0("meta_chm_", POPULATION,
                       if (nzchar(REGION)) paste0("_", gsub("[^A-Za-z0-9]", "", REGION)) else "",
                       ".csv")
OUTPUT_NAME <- Sys.getenv("CHM_OUTPUT_NAME", default_name)

CHM_PYTHON <- Sys.getenv(
  "CHM_PYTHON",
  file.path(Sys.getenv("APPDATA"), "uv", "python",
            "cpython-3.9.25-windows-x86_64-none", "python.exe"))
CHM_PYTHONPATH <- Sys.getenv(
  "CHM_PYTHONPATH",
  normalizePath(file.path("..", ".venv_chm", "Lib", "site-packages"),
                winslash = "/", mustWork = FALSE))
if (!file.exists(CHM_PYTHON)) {
  stop("Python interpreter not found: ", CHM_PYTHON,
       "\nSet CHM_PYTHON to a working interpreter (see CHM_MODEL_SETUP.md).")
}

work_dir  <- Sys.getenv("CHM_WORK_DIR", file.path(tempdir(), "gjen002_chm"))
tiles_dir <- file.path(work_dir, "tiles")
pred_dir  <- file.path(work_dir, "pred")
stats_csv <- file.path(work_dir, "pred_stats.csv")
dir.create(tiles_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(pred_dir,  recursive = TRUE, showWarnings = FALSE)

out_dir   <- file.path(data_dir, "OpenS_data")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out_path  <- file.path(out_dir, OUTPUT_NAME)
fail_path <- file.path(out_dir, sub("\\.csv$", "_failures.csv", OUTPUT_NAME))

cat("Population        :", POPULATION, "\n")
cat("Region filter     :", if (nzchar(REGION)) REGION else "(none - all)", "\n")
cat("Model input res   :", sprintf("%.2f m/px (tiles %.0f x %.0f m)",
                                    TILE_RESOLUTION, 256*TILE_RESOLUTION, 256*TILE_RESOLUTION), "\n")
cat("Batch size        :", BATCH_SIZE, " clean after batch:", CLEAN_BATCH, "\n")
cat("Orthophoto source :", Sys.getenv("ORTHOPHOTO_SOURCE_PATH"), "\n")
cat("Work dir          :", work_dir, "\n")
cat("Output            :", out_path, "\n")

# ------------------------------------------------------------
# Population
# ------------------------------------------------------------
load_population <- function(which_pop) {
  if (identical(which_pop, "test")) {
    p <- st_read(file.path(spatial_dir, "NiN_metaTest.shp"), quiet = TRUE) %>%
      filter(hvdksys == "Vaatmark")
    p$id <- as.character(p$id)
    return(p %>% dplyr::select(id))
  }
  if (!identical(which_pop, "national")) {
    stop("CHM_POPULATION must be 'test' or 'national', got: ", which_pop)
  }
  gdb <- list.files(file.path(data_dir, "OpenS_data", "nin_data"),
                    pattern = "\\.gdb$", full.names = TRUE)[1]
  if (is.na(gdb)) {
    gdb <- list.files(file.path(data_dir, "nin_data"), pattern = "\\.gdb$", full.names = TRUE)[1]
  }
  if (is.na(gdb)) stop("No NiN geodatabase found under Data/OpenS_data/nin_data or Data/nin_data.")
  cat("Reading national NiN geodatabase (slow):", gdb, "\n")
  nin <- st_read(gdb, layer = "naturtyper_nin_omr", quiet = TRUE)
  nin %>%
    rename(geometry = SHAPE) %>% st_set_geometry("geometry") %>%
    filter(hovedøkosystem == "våtmark") %>%
    rename(id = identifikasjon_lokalId) %>%
    mutate(id = as.character(id)) %>%
    dplyr::select(id)
}

polys <- load_population(POPULATION)
cat("Loaded", nrow(polys), "polygon(s).\n")

# 16 of the 24,524 national wetland polygons have invalid geometry and
# abort sf operations outright. Repair what can be repaired, and count
# what could not - never silently drop coverage.
bad <- !st_is_valid(polys)
if (any(bad, na.rm = TRUE)) {
  cat("Invalid geometries:", sum(bad, na.rm = TRUE), "- repairing with st_make_valid()\n")
  polys <- st_make_valid(polys)
}
empty <- st_is_empty(polys)
if (any(empty)) {
  cat("Dropping", sum(empty), "empty geometr(ies) after repair - ids:",
      paste(utils::head(polys$id[empty], 20), collapse = ", "), "\n")
  polys <- polys[!empty, ]
}

# ------------------------------------------------------------
# Region assignment (same logic as the national PROVISIONAL pipeline:
# st_intersects, most-overlapping region wins). Confirmed 2026-09-04 that
# all 24,524 national polygons match exactly one region, so looping over
# the five regions covers the whole population with nothing left over.
# ------------------------------------------------------------
if (nzchar(REGION)) {
  regions <- st_read(file.path(spatial_dir, "regions.shp"), quiet = TRUE)
  regions$region[regions$id == 3] <- "Ostlandet"
  regions$region[regions$id == 5] <- "Sorlandet"
  regions <- st_make_valid(regions)
  if (!REGION %in% regions$region) {
    stop("Unknown CHM_REGION '", REGION, "'. Expected one of: ",
         paste(unique(regions$region), collapse = ", "))
  }
  cat("Assigning regions (st_intersects - slow at national scale)...\n")
  ov <- st_intersects(st_transform(polys, st_crs(regions)), regions)
  polys$region_id <- vapply(ov, function(r) {
    if (length(r) == 0) return(NA_character_)
    tb <- sort(table(as.character(regions$region[r])), decreasing = TRUE)
    names(tb)[1]
  }, character(1))
  n_before <- nrow(polys)
  polys <- polys[!is.na(polys$region_id) & polys$region_id == REGION, ]
  cat("Region '", REGION, "': ", nrow(polys), " of ", n_before, " polygon(s)\n", sep = "")
}

if (MAX_POLYGONS > 0 && nrow(polys) > MAX_POLYGONS) {
  polys <- utils::head(polys, MAX_POLYGONS)
  cat("Capped to", nrow(polys), "polygon(s) via CHM_MAX_POLYGONS.\n")
}
if (nrow(polys) == 0) stop("No polygons to process after filtering.")

# ------------------------------------------------------------
# RESUME. The output CSV is the checkpoint of record.
# ------------------------------------------------------------
done_ids <- character(0)
if (file.exists(out_path)) {
  prev <- tryCatch(read.csv(out_path, stringsAsFactors = FALSE), error = function(e) NULL)
  if (!is.null(prev) && "id" %in% names(prev)) {
    done_ids <- as.character(prev$id)
    cat("RESUMING: ", length(done_ids), " polygon(s) already in ", basename(out_path),
        " - skipping them.\n", sep = "")
  }
}
todo <- polys[!(polys$id %in% done_ids), ]
cat("To process this run:", nrow(todo), "polygon(s)\n")
if (nrow(todo) == 0) {
  cat("Nothing left to do - output is already complete.\n")
  quit(save = "no", status = 0)
}

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
append_csv <- function(df, path) {
  write.table(df, path, sep = ",", row.names = FALSE,
              col.names = !file.exists(path), append = file.exists(path), qmethod = "double")
}

tile_raster <- function(tile_name, stats) {
  s <- stats[stats$tile == tile_name, ]
  if (nrow(s) == 0) return(NULL)
  s <- s[1, ]
  bin <- file.path(pred_dir, sub("\\.tif$", ".bin", tile_name))
  if (!file.exists(bin)) return(NULL)
  tr <- tryCatch(rast(file.path(tiles_dir, tile_name)), error = function(e) NULL)
  if (is.null(tr)) return(NULL)
  # Predictions are headerless little-endian float32, C order, first row =
  # northernmost (predict_tiles.py's OUTPUT CONTRACT). Geometry comes from
  # the original tile, which terra wrote and reads back unambiguously -
  # orientation is never inferred from a file lacking a geotransform.
  # That mattered: relying on an ungeoreferenced TIFF's implied row order
  # silently mirrored every prediction (see project memory).
  v <- readBin(bin, "double", size = 4, n = s$nrow * s$ncol, endian = "little")
  if (length(v) < s$nrow * s$ncol) return(NULL)
  r <- rast(matrix(v, nrow = s$nrow, ncol = s$ncol, byrow = TRUE),
            extent = ext(tr), crs = crs(tr))
  names(r) <- "chm_m"
  r
}

ortho_name <- basename(sub("^/vsicurl/", "", Sys.getenv("ORTHOPHOTO_SOURCE_PATH")))

# ------------------------------------------------------------
# Main loop: batches of cut -> infer -> aggregate -> (clean)
# ------------------------------------------------------------
batches <- split(seq_len(nrow(todo)), ceiling(seq_len(nrow(todo)) / BATCH_SIZE))
cat("\n", length(batches), " batch(es) of up to ", BATCH_SIZE, " polygon(s).\n", sep = "")
t_run <- Sys.time()
n_ok_total <- 0L

for (bi in seq_along(batches)) {
  idx <- batches[[bi]]
  batch <- todo[idx, ]
  cat("\n=========== batch ", bi, "/", length(batches), " (", nrow(batch), " polygons) ===========\n", sep = "")

  # ---- 1. cut tiles (per-polygon trapped; one bad geometry must not
  #         end a multi-hour run) ----
  t0 <- Sys.time()
  tile_map <- list()
  failures <- list()
  for (i in seq_len(nrow(batch))) {
    pid <- batch$id[i]
    tl <- tryCatch(
      get_orthophoto_tiles(batch[i, ], id_field = pid, output_dir = tiles_dir,
                           resolution = TILE_RESOLUTION),
      error = function(e) {
        failures[[length(failures) + 1]] <<- data.frame(id = pid, stage = "tiling",
                                                        error = conditionMessage(e))
        character(0)
      })
    tile_map[[pid]] <- basename(tl)
  }
  n_batch_tiles <- length(unique(unlist(tile_map)))
  cat(sprintf("  tiling: %d tile(s) from %d polygon(s) in %.1f min\n",
              n_batch_tiles, nrow(batch), as.numeric(difftime(Sys.time(), t0, units = "mins"))))

  if (n_batch_tiles == 0) {
    cat("  no tiles in this batch - skipping inference.\n")
    if (length(failures) > 0) append_csv(bind_rows(failures), fail_path)
    next
  }

  # ---- 2. inference (one model load for the batch; --skip-existing
  #         makes a re-run after an interruption cheap) ----
  old_pp <- Sys.getenv("PYTHONPATH")
  Sys.setenv(PYTHONPATH = CHM_PYTHONPATH)
  status <- system2(CHM_PYTHON,
                    args = c(shQuote(file.path(chm_dir, "predict_tiles.py")),
                             "--input-dir",  shQuote(tiles_dir),
                             "--output-dir", shQuote(pred_dir),
                             "--stats-csv",  shQuote(stats_csv),
                             "--skip-existing"))
  Sys.setenv(PYTHONPATH = old_pp)
  if (status != 0) {
    stop("predict_tiles.py failed with exit status ", status,
         " during batch ", bi, ". Progress so far is saved in ", out_path,
         " - re-running this script resumes from there.")
  }

  # ---- 3. aggregate ----
  if (!file.exists(stats_csv)) {
    cat("  WARNING: no per-tile stats file after inference - skipping aggregation for this\n",
        "  batch. Its polygons stay absent from the output, so re-running picks them up.\n", sep = "")
    if (length(failures) > 0) append_csv(bind_rows(failures), fail_path)
    next
  }
  stats <- read.csv(stats_csv, stringsAsFactors = FALSE)
  rows <- lapply(seq_len(nrow(batch)), function(i) {
    pid <- batch$id[i]
    tn <- tile_map[[pid]]
    if (length(tn) == 0) return(NULL)
    res <- tryCatch({
      rl <- Filter(Negate(is.null), lapply(tn, tile_raster, stats = stats))
      if (length(rl) == 0) stop("no readable predictions for this polygon")
      pr <- if (length(rl) == 1) rl[[1]] else do.call(terra::mosaic, c(rl, fun = "max"))
      v <- vect(batch[i, ])
      data.frame(
        id              = pid,
        meta_chm_mean   = terra::extract(pr, v, fun = function(x) mean(x, na.rm = TRUE))[1, 2],
        meta_chm_median = terra::extract(pr, v, fun = function(x) median(x, na.rm = TRUE))[1, 2],
        meta_chm_n      = as.integer(terra::extract(pr, v, fun = function(x) sum(!is.na(x)))[1, 2]),
        n_tiles         = length(tn))
    }, error = function(e) {
      failures[[length(failures) + 1]] <<- data.frame(id = pid, stage = "aggregate",
                                                      error = conditionMessage(e))
      NULL
    })
    res
  })
  out <- bind_rows(Filter(Negate(is.null), rows))

  if (nrow(out) > 0) {
    out$chm_source        <- "meta_highrescanopyheight_orthophoto"
    out$model_input_res_m <- TILE_RESOLUTION
    out$ortho_source      <- ortho_name
    out$region_filter     <- if (nzchar(REGION)) REGION else NA_character_
    append_csv(out, out_path)          # checkpoint written before cleanup
    n_ok_total <- n_ok_total + nrow(out)
  }
  if (length(failures) > 0) append_csv(bind_rows(failures), fail_path)
  cat(sprintf("  aggregated: %d valued, %d failed. Running total: %d\n",
              nrow(out), length(failures), n_ok_total))

  # ---- 4. clean this batch's scratch (only AFTER the checkpoint is on
  #         disk, so a crash here never loses results) ----
  if (CLEAN_BATCH) {
    tn_all <- unique(unlist(tile_map))
    unlink(file.path(tiles_dir, tn_all))
    unlink(file.path(pred_dir, sub("\\.tif$", ".bin", tn_all)))
    if (file.exists(stats_csv)) unlink(stats_csv)
  }
}

cat(sprintf("\nDone. %d polygon(s) valued this run in %.1f min -> %s\n",
            n_ok_total, as.numeric(difftime(Sys.time(), t_run, units = "mins")), out_path))
if (file.exists(fail_path)) cat("Failures logged to:", fail_path, "\n")
cat("Downstream must use `meta_chm_mean` (validated), not `meta_chm_median`.\n")
