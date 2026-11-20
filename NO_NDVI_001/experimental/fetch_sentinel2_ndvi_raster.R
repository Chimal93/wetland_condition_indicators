# ============================================================
# NO_NDVI_001 - Sentinel-2 NDVI, RASTER-BASED alternative to
# fetch_sentinel2_ndvi.R's aggregate_spatial approach.
#
# WHY THIS EXISTS: aggregate_spatial (per-polygon server-side zonal
# stats) repeatedly triggered GEOSException("TopologyException: side
# location conflict") inside CDSE's backend across national wetland
# polygons - a real, hard-to-fully-eliminate class of GEOS overlay
# robustness bug (confirmed via CDSE's own Web Editor synchronous
# validation), not something fixable by chasing individual polygons one
# at a time. That approach was eventually fixed too (geometry repair +
# small enough batches - see fetch_sentinel2_ndvi.R), but it ties every
# CDSE job to one specific wetland polygon set: a revised/better polygon
# layer later would mean resubmitting brand-new CDSE jobs (cost + the
# same GEOS risk all over again).
#
# This script avoids that coupling structurally: request a plain RASTER
# export (no wetland geometries touch the server at all - only a single
# well-behaved REGION boundary polygon, per region), then do the zonal
# extraction OURSELVES locally, later, against whatever polygon set is
# current - the same terra::extract() approach already proven for MODIS,
# just with a real per-polygon zonal option now that Sentinel-2's 10m
# pixels are usually smaller than a wetland polygon (MODIS's 250-500m
# pixels forced centroid-only sampling; that constraint doesn't apply
# here). Swapping wetland polygons later becomes a free, local, offline
# operation - no CDSE credits, no GEOS exception surface, ever again.
#
# SERVER-SIDE TEMPORAL REDUCTION: the peak (max) NDVI across the growing
# season is computed server-side (reduce_dimension over the time axis)
# BEFORE export - collapsing an entire season into one single-band
# raster per piece. This matches the trend-scaling design's own "peak
# NDVI per year" concept exactly, and keeps download size manageable.
#
# REGION GEOMETRY, NOT BBOX (confirmed necessary 2026-09-03): a plain
# bounding box works fine for a compact region (Ostlandet), but Nord-
# Norge's actual shape is a long, thin, curving coastline - its bbox is
# 21.2 degrees wide vs. its true area implying something far smaller
# (196,641 km2, "only" 2.5x Ostlandet's 78,357 km2, yet ~4x the bbox
# width). A bbox request there would pull a huge amount of pure-ocean,
# no-data area for no benefit. openEO's load_collection spatial_extent
# accepts a real GeoJSON polygon, not just a bbox - and unlike the
# wetland layer (24,000+ messy, near-touching polygons that triggered
# the GEOS bug), each region boundary here is a single well-behaved
# polygon, so this doesn't reintroduce that topology risk. Used for
# every region now (not just Nord-Norge) - there's no downside to it
# anywhere, it just matters most there.
#
# NORD-NORGE SPLIT INTO LATITUDE BANDS: even clipped to its real shape,
# Nord-Norge's coastline still winds through nearly its full 21-degree
# longitude span and a huge north-south extent - Sentinel-2 data comes
# in a fixed UTM tile grid, so the number of tiles actually touched (the
# real driver of processing time/cost) stays large regardless of exact
# polygon-vs-bbox clipping. Split into N_NORD_NORGE_BANDS (default 3,
# roughly Nordland/Troms/Finnmark-scale) equal-latitude slices of the
# real polygon, each submitted as its own bounded job - same "keep every
# job bounded" principle already proven by fetch_sentinel2_ndvi.R's
# adaptive chunk-splitting, applied along a spatial axis instead of a
# polygon-count axis. Smaller jobs are also cheaper to retry individually
# if CDSE's backend (confirmed to have some genuine flakiness - see that
# script's list_jobs() HTTP 500 notes) hiccups on just one.
#
# ALSO SPLIT BY TIME (confirmed necessary 2026-09-03): a full-Ostlandet,
# full-growing-season (4 month) single job FAILED after ~65 min and 123
# credits (status "error", no log entries returned by CDSE - a known
# backend limitation, not something we could get a root-cause message
# for). A follow-up diagnostic - the exact same process graph, but over
# a tiny ~20x20km area with the full 4-month range intact - succeeded
# cleanly in 6.6 minutes, which isolates the failure to SPATIAL x
# TEMPORAL data volume in one job (holding a whole season's worth of
# full-region scenes before the temporal-max can collapse them), not a
# structural problem with the temporal reduction step itself. Fix:
# split each piece's season into N_PERIODS roughly-equal date ranges
# (default 4, ~monthly), submit one bounded job per (piece, period),
# then take the max across the downloaded period rasters OURSELVES,
# locally, via terra::mosaic(fun="max") - free, and avoids ever asking
# CDSE to hold a whole season for a whole region in one job again.
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

library(openeo)
library(sf)
library(dplyr)
library(terra)

data_dir <- file.path("..", "data")
out_dir  <- file.path(data_dir, "NDVI_Sentinel_raster")
period_dir <- file.path(out_dir, "periods")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
if (!dir.exists(period_dir)) dir.create(period_dir, recursive = TRUE)

# MODE: "single" (default) tests one region via SENTINEL_RASTER_REGION -
# the original, already-confirmed-registering-cleanly path. "all" builds
# every region (Nord-Norge split into bands) and runs them all. Both
# modes now split the season into N_PERIODS jobs per piece (see header
# comment - a single whole-season job failed at full-Ostlandet scale).
MODE                 <- Sys.getenv("SENTINEL_RASTER_MODE", "single")
TEST_REGION          <- Sys.getenv("SENTINEL_RASTER_REGION", "Ostlandet")
TEST_YEAR            <- as.integer(Sys.getenv("SENTINEL_RASTER_YEAR", "2023"))
N_NORD_NORGE_BANDS   <- as.integer(Sys.getenv("SENTINEL_RASTER_NN_BANDS", "3"))
N_PERIODS            <- as.integer(Sys.getenv("SENTINEL_RASTER_N_PERIODS", "4"))
MAX_POLL_MIN         <- as.integer(Sys.getenv("SENTINEL_RASTER_MAX_POLL_MIN", "60"))

# Growing season: June 1 - Sept 30, split into N_PERIODS ~equal date
# ranges (default 4 -> ~monthly). Each is its own bounded CDSE job.
season_start <- as.Date(paste0(TEST_YEAR, "-06-01"))
season_end   <- as.Date(paste0(TEST_YEAR, "-09-30"))
period_breaks <- seq(season_start, season_end + 1, length.out = N_PERIODS + 1)
periods <- lapply(seq_len(N_PERIODS), function(i) {
  list(label = sprintf("p%d", i),
       start = format(period_breaks[i], "%Y-%m-%d"),
       end   = format(period_breaks[i + 1] - 1, "%Y-%m-%d"))
})
cat("Season split into", N_PERIODS, "period(s):\n")
for (pr in periods) cat(" ", pr$label, ":", pr$start, "to", pr$end, "\n")

# ------------------------------------------------------------
# Connect + authenticate
# ------------------------------------------------------------
con <- connect(host = "https://openeofed.dataspace.copernicus.eu")
login()
auth_check <- tryCatch(describe_account(), error = function(e) e)
if (inherits(auth_check, "error")) {
  stop("CDSE authentication did not succeed (", conditionMessage(auth_check), ").")
}
cat("Authenticated as:", if (is.null(auth_check$user_id)) "unknown" else auth_check$user_id, "\n")

# ------------------------------------------------------------
# Load region boundaries. Same source as fetch_sentinel2_ndvi.R's own
# region lookup - id==3/id==5 renames just fix a character-encoding
# issue on Ostlandet/Sorlandet, not an actual region count change
# (confirmed 5 regions total: Nord-Norge, Midt-Norge, Ostlandet,
# Vestlandet, Sorlandet).
# ------------------------------------------------------------
regions <- st_read(file.path(data_dir, "spatial", "regions.shp"), quiet = TRUE)
regions$region[regions$id == 3] <- "Ostlandet"
regions$region[regions$id == 5] <- "Sorlandet"
regions <- st_make_valid(regions) %>% st_transform(4326)

n_vertices <- function(x) sum(vapply(seq_len(nrow(x)), function(i) nrow(st_coordinates(x[i, ])), integer(1)))
cat("Region boundary vertex counts:\n")
for (i in seq_len(nrow(regions))) cat(" ", regions$region[i], ":", nrow(st_coordinates(regions[i, ])), "\n")
# Simplify only if genuinely complex (mirrors fetch_sentinel2_ndvi.R's own
# reasoning: 10m tolerance can't remove detail Sentinel-2's 10m pixels
# could resolve anyway). Applied in a projected CRS (metres), same as
# that script, then re-validated.
if (n_vertices(regions) > 20000) {
  regions_m <- st_transform(regions, 25833)
  regions_m <- st_simplify(regions_m, dTolerance = 50, preserveTopology = TRUE) %>% st_make_valid()
  regions <- st_transform(regions_m, 4326)
  cat("Simplified region boundaries (50m tolerance) - new vertex count:", n_vertices(regions), "\n")
}

# ------------------------------------------------------------
# Convert one sf polygon (single row) to the GeoJSON geometry object
# openEO's load_collection spatial_extent expects (a bare {type,
# coordinates} object, not a Feature/FeatureCollection wrapper) - same
# geojsonsf + jsonlite round-trip technique already proven for wetland
# geometries in fetch_sentinel2_ndvi.R's aggregate_spatial call.
# ------------------------------------------------------------
# CONFIRMED (local test, 2026-09-03): geojsonsf::sf_geojson() on a
# geometry-only sf object (no attribute columns, as built by
# build_pieces() below) serializes to a BARE {type, coordinates} object
# directly, NOT a FeatureCollection - unlike the wetland id-attributed
# case in fetch_sentinel2_ndvi.R, which does produce Features. Handle
# both shapes rather than assuming one.
sf_to_geojson_geometry <- function(poly_1row) {
  parsed <- jsonlite::fromJSON(geojsonsf::sf_geojson(poly_1row), simplifyVector = FALSE)
  if (!is.null(parsed$type) && !is.null(parsed$coordinates)) return(parsed)
  parsed$features[[1]]$geometry
}

# ------------------------------------------------------------
# Build the list of job "pieces": one per region, except Nord-Norge,
# which is split into N_NORD_NORGE_BANDS equal-latitude slices of its
# real polygon (not its bbox) - see header comment for why.
# ------------------------------------------------------------
build_pieces <- function(regions_sf, n_bands) {
  pieces <- list()
  for (i in seq_len(nrow(regions_sf))) {
    rn <- regions_sf$region[i]
    geom <- regions_sf[i, ]
    if (rn == "Nord-Norge" && n_bands > 1) {
      bb <- st_bbox(geom)
      breaks <- seq(bb[["ymin"]], bb[["ymax"]], length.out = n_bands + 1)
      for (b in seq_len(n_bands)) {
        band_box <- st_as_sfc(st_bbox(c(xmin = bb[["xmin"]], xmax = bb[["xmax"]],
                                         ymin = breaks[b], ymax = breaks[b + 1]), crs = st_crs(geom)))
        band_geom <- suppressWarnings(st_intersection(st_geometry(geom), band_box))
        if (length(band_geom) == 0 || all(st_is_empty(band_geom))) next
        pieces[[length(pieces) + 1]] <- list(title = paste0("NordNorge_band", b), geom = st_sf(geometry = band_geom))
      }
    } else {
      pieces[[length(pieces) + 1]] <- list(title = rn, geom = st_geometry(geom) %>% st_sf())
    }
  }
  pieces
}

# ------------------------------------------------------------
# Build + register one piece's process graph. Returns a structured
# result rather than raising - one piece's failure must not abort the
# rest (same reasoning as fetch_sentinel2_ndvi.R's run_chunk()).
# ------------------------------------------------------------
create_piece_job <- function(piece_geom, piece_title, period) {
  p <- processes()

  s2 <- p$load_collection(
    id = "SENTINEL2_L2A",
    spatial_extent = sf_to_geojson_geometry(piece_geom),
    temporal_extent = list(period$start, period$end),
    bands = list("B04", "B08", "SCL")
  )

  ndvi <- p$reduce_dimension(data = s2, dimension = "bands", reducer = function(data, context) {
    red <- data[1]; nir <- data[2]
    (nir - red) / (nir + red)
  })

  scl_mask <- p$reduce_dimension(data = s2, dimension = "bands", reducer = function(data, context) {
    scl <- data[3]
    is_clear <- p$or(x = p$eq(x = scl, y = 4), y = p$eq(x = scl, y = 5))
    p$not(x = is_clear)
  })

  ndvi_masked <- p$mask(data = ndvi, mask = scl_mask)

  ndvi_peak <- p$reduce_dimension(data = ndvi_masked, dimension = "t", reducer = function(data, context) {
    p$max(data = data, ignore_nodata = TRUE)
  })

  result <- p$save_result(data = ndvi_peak, format = "GTiff")

  job_title <- paste0("ndvi_raster_", piece_title, "_", TEST_YEAR, "_", period$label)
  job <- tryCatch(create_job(graph = result, title = job_title), error = function(e) e)
  if (inherits(job, "error") || is.null(job$id) || !nzchar(job$id)) {
    return(list(ok = FALSE, title = job_title,
                error = paste("job registration failed:",
                               if (inherits(job, "error")) conditionMessage(job) else "no job id returned")))
  }
  list(ok = TRUE, title = job_title, job = job)
}

# ------------------------------------------------------------
# Run one already-registered job to completion: start, poll, download.
# ------------------------------------------------------------
run_piece_job <- function(job, job_title) {
  start_res <- tryCatch({ start_job(job = job); TRUE }, error = function(e) e)
  if (inherits(start_res, "error")) {
    return(list(ok = FALSE, title = job_title, error = paste("start_job() failed:", conditionMessage(start_res))))
  }

  t_start <- Sys.time()
  status <- NULL
  repeat {
    info <- tryCatch(describe_job(job = job), error = function(e) e)
    if (inherits(info, "error")) {
      cat("  describe_job() failed:", conditionMessage(info), "- retrying\n")
      Sys.sleep(15)
      next
    }
    status <- info$status
    if (is.null(status) || length(status) == 0) status <- "unknown"
    elapsed_min <- as.numeric(difftime(Sys.time(), t_start, units = "mins"))
    cat("  [", job_title, "] job status:", status, "-", format(Sys.time(), "%H:%M:%S"),
        sprintf("(%.1f min elapsed)", elapsed_min), "\n")
    if (status %in% c("finished", "error", "canceled")) break
    if (elapsed_min > MAX_POLL_MIN) {
      return(list(ok = FALSE, title = job_title,
                  error = paste0("did not finish within ", MAX_POLL_MIN, " min (stuck at '", status, "')")))
    }
    Sys.sleep(15)
  }
  if (status != "finished") {
    log_text <- tryCatch({
      l <- log_job(job = job)
      if (is.list(l) && !is.null(l$logs) && length(l$logs) > 0) {
        paste(vapply(l$logs, function(x) paste0("[", x$level, "] ", x$message), character(1)), collapse = " | ")
      } else "(no log entries)"
    }, error = function(e) paste("(could not fetch logs:", conditionMessage(e), ")"))
    return(list(ok = FALSE, title = job_title, error = paste0("finished with status '", status, "'. ", log_text)))
  }

  dl_res <- tryCatch({
    dl_dir <- file.path(period_dir, job_title)
    if (!dir.exists(dl_dir)) dir.create(dl_dir, recursive = TRUE)
    download_results(job = job, folder = dl_dir)
    tif <- list.files(dl_dir, pattern = "\\.tif$", full.names = TRUE)[1]
    if (is.na(tif)) stop("no .tif found in downloaded results")
    tif
  }, error = function(e) e)
  if (inherits(dl_res, "error")) {
    return(list(ok = FALSE, title = job_title, error = paste("download failed:", conditionMessage(dl_res))))
  }
  list(ok = TRUE, title = job_title, tif = dl_res)
}

# ------------------------------------------------------------
# Run every period for one piece (each its own bounded CDSE job - see
# header comment on why the whole season can't be one job at region
# scale), then combine the period rasters into one season-peak raster
# locally via terra::mosaic(fun="max") - free, no CDSE cost. One
# period's failure is reported but does not abort the others; the
# combined raster is still written from whichever periods succeeded
# (logged clearly, not silently missing coverage).
# ------------------------------------------------------------
run_piece_all_periods <- function(piece_geom, piece_title) {
  period_results <- lapply(periods, function(pr) {
    cat("\nRegistering '", piece_title, "' / ", pr$label, " (", pr$start, " to ", pr$end, ")...\n", sep = "")
    reg <- create_piece_job(piece_geom, piece_title, pr)
    if (!reg$ok) { cat("  FAILED:", reg$error, "\n"); return(reg) }
    cat("  OK - job id:", reg$job$id, "\n")
    res <- run_piece_job(reg$job, reg$title)
    if (!res$ok) cat("  FAILED:", res$error, "\n")
    res
  })

  ok_results <- Filter(function(r) r$ok, period_results)
  failed <- Filter(function(r) !r$ok, period_results)
  if (length(failed) > 0) {
    cat("\n", piece_title, ": ", length(failed), " of ", length(period_results), " period(s) failed:\n", sep = "")
    for (f in failed) cat("  [", f$title, "] ", f$error, "\n", sep = "")
  }
  if (length(ok_results) == 0) {
    return(list(ok = FALSE, title = piece_title, error = "all periods failed - no raster to combine"))
  }

  combine_res <- tryCatch({
    rasters <- lapply(ok_results, function(r) terra::rast(r$tif))
    combined <- if (length(rasters) == 1) rasters[[1]] else do.call(terra::mosaic, c(rasters, fun = "max"))
    out_path <- file.path(out_dir, paste0("ndvi_peak_", piece_title, "_", TEST_YEAR, ".tif"))
    terra::writeRaster(combined, out_path, overwrite = TRUE)
    out_path
  }, error = function(e) e)
  if (inherits(combine_res, "error")) {
    return(list(ok = FALSE, title = piece_title,
                error = paste("local combine failed:", conditionMessage(combine_res)),
                n_periods_ok = length(ok_results), n_periods_total = length(period_results)))
  }
  list(ok = TRUE, title = piece_title, tif = combine_res,
       n_periods_ok = length(ok_results), n_periods_total = length(period_results))
}

# ------------------------------------------------------------
# Top level
# ------------------------------------------------------------
if (MODE == "single") {
  region_geom <- regions %>% filter(region == TEST_REGION) %>% st_geometry() %>% st_sf()
  if (nrow(region_geom) == 0) stop("Unknown region: ", TEST_REGION)
  cat("Single-region mode:", TEST_REGION, "\n")
  final <- run_piece_all_periods(region_geom, TEST_REGION)
  if (!final$ok) stop(final$error)
  cat("\n", final$n_periods_ok, "/", final$n_periods_total, "period(s) succeeded. Combined season-peak raster:\n")
  cat(" ", final$tif, "\n")
} else if (MODE == "all") {
  pieces <- build_pieces(regions, N_NORD_NORGE_BANDS)
  cat(length(pieces), "piece(s) to process:", paste(vapply(pieces, function(p) p$title, character(1)), collapse = ", "), "\n")

  results <- lapply(pieces, function(pc) run_piece_all_periods(pc$geom, pc$title))

  failed <- Filter(function(r) !r$ok, results)
  cat("\n=== ", length(results) - length(failed), " of ", length(results), " piece(s) succeeded ===\n", sep = "")
  if (length(failed) > 0) {
    cat("Failed pieces:\n")
    for (f in failed) cat("  [", f$title, "] ", f$error, "\n", sep = "")
  }
  for (r in results) if (r$ok) cat("  [", r$title, "] (", r$n_periods_ok, "/", r$n_periods_total, " periods) ->", r$tif, "\n")
} else {
  stop("Unknown SENTINEL_RASTER_MODE: ", MODE, " (expected 'single' or 'all')")
}
