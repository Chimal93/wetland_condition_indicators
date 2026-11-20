# ============================================================
# NO_NDVI_001 - Sentinel-2 NDVI fetch, GEE-free
#
# Replaces NINA's original bespoke Google Earth Engine zonal-statistics
# export (see NO_NDVI_001_wetland_pipeline.R Stage 5 comments) with the
# Copernicus Data Space Ecosystem (CDSE) openEO API directly - public
# self-service account, no NINA-internal access needed. Same GEE-free
# approach already used for NO_NDVI_001's MODIS fetch (fetch_modis_ndvi.R)
# and NO_GJEN_002's ETH canopy-height fetch.
#
# Mechanism: openEO is a server-side processing API - we submit a process
# graph (load Sentinel-2 L2A -> compute NDVI -> mask clouds via SCL ->
# aggregate_spatial over the wetland polygons) as a batch job, and CDSE's
# own cloud runs it and returns just the small aggregated per-polygon,
# per-date CSV. This avoids downloading/processing any raw Sentinel-2
# imagery locally (unlike the MODIS fetch, which downloads full HDF tiles).
#
# Cost: CDSE grants 10,000 free openEO processing credits/month (as of
# 2026 - boosted from a 4,000 baseline). Job cost scales with AOI area x
# time range x band count, so this script starts with a small single-
# region, single-year, 25-polygon test job before committing to anything
# resembling the original's national, multi-year scope (the original GEE
# export was 42 files - almost certainly 6 regions x 7 years, implying
# Sentinel-2 L2A coverage of roughly 2017-2023 in the original, since
# global L2A processing only became consistently available then).
#
# Auth: login() opens a browser window for CDSE sign-in (OIDC
# device_code+pkce flow, auto-negotiated - confirmed via the openeo R
# package's own login() help page) - no token/secret ever touches this
# script or an env var, unlike the MODIS/Earthdata bearer-token setup.
# ============================================================

library(openeo)
library(sf)
library(dplyr)

data_dir <- file.path("..", "data")
out_dir  <- file.path(data_dir, "NDVI_Sentinel")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

TEST_MODE   <- Sys.getenv("SENTINEL_TEST_MODE", "1") == "1"
TEST_YEAR   <- as.integer(Sys.getenv("SENTINEL_TEST_YEAR", "2023"))
TEST_REGION <- Sys.getenv("SENTINEL_TEST_REGION", "Ostlandet")
TEST_COUNT  <- as.integer(Sys.getenv("SENTINEL_TEST_COUNT", "25"))

# ------------------------------------------------------------
# Connect + authenticate
# ------------------------------------------------------------
con <- connect(host = "https://openeofed.dataspace.copernicus.eu")
# authorization_code+pkce (opens a real browser tab, no code to relay) was
# tried and rejected outright: "OAuth 2.0 authorization code flow requires
# an interactive session" - Rscript.exe batch execution can never satisfy
# that, regardless of foreground/background. device_code is therefore the
# only usable flow here - run this script directly yourself (not through
# an agent relaying the printed code) so you can click through the moment
# it appears, well inside its ~10 min window.
login()
# login() does not raise an R error on a failed/expired device-code flow -
# it just prints "Login failed..." and returns the still-unauthenticated
# connection, which otherwise cascades into confusing downstream failures
# (HTTP 401 on create_job, then a crash on an empty job status). Verify
# authentication actually succeeded via an endpoint that requires it.
auth_check <- tryCatch(describe_account(), error = function(e) e)
if (inherits(auth_check, "error")) {
  stop("CDSE authentication did not succeed (", conditionMessage(auth_check), "). ",
       "The device code expires quickly (~10 min) - re-run this script and ",
       "visit the printed URL / enter the code immediately.")
}
cat("Authenticated as:", if (is.null(auth_check$user_id)) "unknown" else auth_check$user_id, "\n")

# ------------------------------------------------------------
# Load national wetland polygons, reproject to WGS84 (openEO expects
# GeoJSON geometries in EPSG:4326), pick the test region's polygons.
# ------------------------------------------------------------
# Same national NiN geodatabase + wetland filter as fetch_modis_ndvi.R -
# see that script's comments for field-name provenance.
nin_gdb_dir <- file.path(data_dir, "nin_data")
gdb_path <- list.files(nin_gdb_dir, pattern = "\\.gdb$", full.names = TRUE)[1]
if (is.na(gdb_path)) stop("Missing national NiN geodatabase in ", nin_gdb_dir, ".")

nin <- st_read(gdb_path, layer = "naturtyper_nin_omr", quiet = TRUE)
wetland <- nin %>%
  rename(geometry = SHAPE) %>%
  st_set_geometry("geometry") %>%
  filter(hovedøkosystem == "våtmark") %>%
  st_make_valid() %>%
  filter(!st_is_empty(.)) %>%
  rename(id = identifikasjon_lokalId) %>%
  dplyr::select(id) %>%
  st_transform(25833)

# REVISED DIAGNOSIS (2026-09-03, after researching the exact error):
# "TopologyException: side location conflict" is a well-documented GEOS/
# JTS FLOATING-POINT ROBUSTNESS bug, not necessarily a defect in any one
# polygon. It classically fires during overlay/noding when two SEPARATE
# geometries' edges pass extremely close to each other (near-touching,
# e.g. two adjacent wetland patches sharing a near-border) - the plane-
# sweep algorithm gets a contradictory "which side" answer at that near-
# miss coordinate. This explains why excluding/repairing one "offending"
# polygon kept just exposing a NEW error at a different location each
# time - the real issue is the RELATIONSHIP between nearby polygons'
# coordinates, not any single polygon's own validity. The standard fix
# is to force every coordinate onto a common precision grid before any
# GEOS operation, eliminating near-miss ambiguity entirely - st_buffer(0)
# below is what actually performs the snap, but only takes effect
# because st_set_precision() declares the grid it snaps to first.
wetland <- st_set_precision(wetland, 100)  # 1/100 = 1cm grid, in EPSG:25833's metre units
wetland <- st_buffer(wetland, 0) %>% filter(!st_is_empty(.))

# Simplify boundaries before anything else touches them - same fix, same
# justification as NO_CON_001's own polygon-simplification step: some NiN
# wetland polygons have 100+ boundary parts (the GDAL warning above), which
# inflates GeoJSON payload size for aggregate_spatial (root cause of the
# HTTP 413 rejections seen at national scale) without adding any real
# information Sentinel-2 could resolve anyway - its native pixel size is
# 10m, so a ~10m simplification tolerance can't remove detail the
# satellite data itself represents. Simplify in a projected (metres) CRS
# BEFORE reprojecting to WGS84 - st_simplify's tolerance is interpreted in
# whatever units the active CRS uses, and 10 degrees would be nonsensical.
n_vertices_before <- sum(vapply(seq_len(nrow(wetland)), function(i) nrow(st_coordinates(wetland[i, ])), integer(1)))
wetland <- st_simplify(wetland, dTolerance = 10, preserveTopology = TRUE) %>%
  filter(!st_is_empty(.))
# CONFIRMED (2026-09-03, via CDSE's Web Editor synchronous validation -
# the R client itself never surfaced this): st_simplify()'s Douglas-
# Peucker algorithm can produce genuinely self-intersecting (invalid)
# polygons even with preserveTopology=TRUE, especially for the complex,
# many-vertex boundaries this project has repeatedly flagged ("100+
# parts"). CDSE's aggregate_spatial crashes ungracefully on an invalid
# input geometry (GEOSException: TopologyException, side location
# conflict) - this is the real root cause of every "job registered
# successfully but can't be found" failure seen so far, not backend
# flakiness. st_make_valid() repairs this (GEOS's own polygon-repair
# algorithm) - re-simplify was NOT needed to reproduce/isolate this, but
# validity must be re-checked after ANY geometry-mutating step, not
# assumed to hold from the pre-simplification input alone.
wetland <- st_make_valid(wetland) %>% filter(!st_is_empty(.))

# CONFIRMED (2026-09-03, second round of live Web Editor testing): a
# specific real polygon (NINFP2010027022) STILL triggers the same GEOS
# TopologyException inside CDSE's aggregate_spatial even AFTER
# st_make_valid() - its vertex order visibly changed between attempts
# (confirming the repair ran), but the shape still trips something in
# GEOS's overlay logic there. st_make_valid() guarantees OGC validity by
# definition, so this is a genuine edge case surviving simple repair, not
# something worth chasing polygon-by-polygon. Rather than let one
# stubborn polygon block an entire chunk's job, re-check validity
# explicitly after repair and drop (not silently keep) anything still
# failing - logging exactly which ids, so this is traceable rather than
# a silent coverage loss.
still_invalid <- !st_is_valid(wetland)
if (any(still_invalid)) {
  cat("Dropping", sum(still_invalid), "polygon(s) still invalid after st_make_valid() - ids:",
      paste(wetland$id[still_invalid], collapse = ", "), "\n")
  wetland <- wetland[!still_invalid, ]
}

# st_make_valid() can turn a Polygon into a GEOMETRYCOLLECTION (e.g. a
# polygon fragment + a stray line/point from the repair) - keep only the
# polygonal part rather than passing a mixed-type feature to the GeoJSON
# export, which aggregate_spatial does not expect.
geom_types <- st_geometry_type(wetland)
if (any(geom_types == "GEOMETRYCOLLECTION")) {
  wetland <- st_collection_extract(wetland, "POLYGON")
}

n_vertices_after <- sum(vapply(seq_len(nrow(wetland)), function(i) nrow(st_coordinates(wetland[i, ])), integer(1)))
cat("Simplified wetland boundaries (10m tolerance): ", n_vertices_before, "->", n_vertices_after,
    "vertices (", round(100 * (1 - n_vertices_after / n_vertices_before), 1), "% reduction)\n")

wetland <- st_transform(wetland, 4326)

regions <- st_read(file.path(data_dir, "spatial", "regions.shp"), quiet = TRUE)
regions$region[regions$id == 3] <- "Ostlandet"
regions$region[regions$id == 5] <- "Sorlandet"

if (TEST_MODE) {
  region_geom <- regions %>% filter(region == TEST_REGION) %>% st_transform(4326)
  wetland_sub <- wetland[st_intersects(wetland, region_geom, sparse = FALSE)[, 1], ]
  # capped to SENTINEL_TEST_COUNT polygons (default 25) for cost/mechanics checks
  wetland_sub <- head(wetland_sub, TEST_COUNT)
  cat("TEST MODE:", nrow(wetland_sub), "polygons in", TEST_REGION, "\n")
} else {
  wetland_sub <- wetland
}

wetland_sub$id <- as.character(wetland_sub$id)

temporal_extent <- if (TEST_MODE) {
  list(paste0(TEST_YEAR, "-06-01"), paste0(TEST_YEAR, "-09-30"))
} else {
  list("2017-06-01", "2023-09-30")
}

ESTIMATE_ONLY <- Sys.getenv("SENTINEL_ESTIMATE_ONLY", "0") == "1"
MAX_POLL_MIN <- if (TEST_MODE) 15 else 240

# ------------------------------------------------------------
# Build + register one chunk's process graph (own bbox, own geometries).
# Band-arithmetic idiom (positional data[1], data[2] indexing inside a
# reduce_dimension callback) follows the package's own getting-started and
# process-graph-building vignettes exactly - do NOT use array_element or a
# "normalized_difference" process, neither appears in the package's own
# examples. Returns the created job, or NULL if the backend rejected it
# (e.g. HTTP 413 Payload Too Large on a large inline geometry list -
# create_job() does not raise an R error for this, it prints the HTTP error
# text and returns a job object with a blank/missing id instead).
# ------------------------------------------------------------
create_chunk_job <- function(chunk_polys, chunk_title) {
  chunk_bbox <- st_bbox(chunk_polys)
  p <- processes()

  s2 <- p$load_collection(
    id = "SENTINEL2_L2A",
    spatial_extent = list(west = chunk_bbox[["xmin"]], south = chunk_bbox[["ymin"]],
                           east = chunk_bbox[["xmax"]], north = chunk_bbox[["ymax"]]),
    temporal_extent = temporal_extent,
    bands = list("B04", "B08", "SCL")
  )

  ndvi <- p$reduce_dimension(data = s2, dimension = "bands", reducer = function(data, context) {
    red <- data[1]
    nir <- data[2]
    (nir - red) / (nir + red)
  })

  # Keep only clear vegetation/bare-soil pixels (SCL 4 = vegetation, 5 =
  # bare soil) - mirrors CDSE's own NDVI timeseries sample notebook,
  # appropriate here since wetlands are vegetated land, not water/cloud/snow.
  scl_mask <- p$reduce_dimension(data = s2, dimension = "bands", reducer = function(data, context) {
    scl <- data[3]
    is_clear <- p$or(x = p$eq(x = scl, y = 4), y = p$eq(x = scl, y = 5))
    p$not(x = is_clear)
  })

  ndvi_masked <- p$mask(data = ndvi, mask = scl_mask)

  # CONFIRMED (test job cdse-j-260902104229467d8831d35d76c64242, 25
  # polygons, Ostlandet, 2023): aggregate_spatial's output CSV does NOT
  # echo back GeoJSON feature properties - only a plain 0-based
  # `feature_index`, in submission order. Join back to `id` happens by
  # POSITION after download (see run_chunk() below).
  #
  # Geometries are embedded inline (not via upload_file()+read_vector() -
  # that combo hit an unrelated client-side bug, "cannot unclass an
  # environment", building the read_vector node; not worth chasing further
  # since inline embedding + region-sized chunking - see run_all() below -
  # already avoids the original problem, HTTP 413 on the full national set).
  geoms_list <- jsonlite::fromJSON(geojsonsf::sf_geojson(chunk_polys["id"]), simplifyVector = FALSE)

  # target_dimension explicitly NULL: the R client's aggregate_spatial
  # wrapper defaults it to "result" (a real value, not the usual NA
  # placeholder for "unset"), which gets serialized into the graph even
  # when never passed - and CDSE's backend rejects that value outright
  # (HTTP 501 Not Implemented on job creation, confirmed against the live
  # backend). Passing NULL makes the client's own arg-filtering (drops any
  # NULL-valued argument before serializing) omit it entirely.
  timeseries <- p$aggregate_spatial(
    data = ndvi_masked,
    geometries = geoms_list,
    reducer = function(data, context) p$mean(data = data),
    target_dimension = NULL
  )

  result <- p$save_result(data = timeseries, format = "CSV")
  # create_job() does not raise a normal R error for a rejected request -
  # it prints the HTTP status/message directly (via cat/message, not a
  # condition) and returns a job object with a blank/missing id. Capture
  # BOTH stdout and message-stream output from this ONE call so the real
  # reason is visible instead of guessing "too large" for every rejection.
  captured_lines <- character(0)
  txt_con <- textConnection("captured_lines", "w", local = TRUE)
  sink(txt_con)
  sink(txt_con, type = "message")
  job <- tryCatch(create_job(graph = result, title = chunk_title), error = function(e) {
    cat("create_job() raised an R error:", conditionMessage(e), "\n")
    NULL
  })
  sink(type = "message")
  sink()
  close(txt_con)

  if (is.null(job) || is.null(job$id) || !nzchar(job$id)) {
    # CONFIRMED (national run, 2026-09-03): a bare NULL return here was
    # wrongly treated as "payload too large" for EVERY kind of rejection -
    # including a transient/session-related HTTP 404 "Collection
    # 'SENTINEL2_L2A' does not exist" that has nothing to do with size (the
    # same collection worked fine in every earlier job this session).
    # That bug caused pointless splitting all the way to the floor size on
    # an error no amount of splitting could ever fix. Only an actual 413
    # means "too large" - anything else is a real error to surface, not a
    # size problem to work around.
    msg <- paste(captured_lines, collapse = " ")
    is_413 <- grepl("413", msg, fixed = TRUE)
    cat("    create_job() did not return a usable job. Captured output:\n")
    cat(paste("     ", captured_lines, collapse = "\n"), "\n")
    return(list(job = NULL, too_large = is_413, message = msg))
  }
  list(job = job, too_large = FALSE, message = NULL)
}

# ------------------------------------------------------------
# Adaptive splitting: if a chunk is rejected (413), halve it and retry each
# half recursively, down to a floor size, rather than guessing a safe
# polygon count up front (payload size depends on polygon complexity, not
# just count - some NiN wetland polygons have 100+ ring parts per the GDAL
# warning above).
# ------------------------------------------------------------
register_jobs <- function(chunk_polys, chunk_title, min_size = 200, retried = FALSE) {
  cat("Registering job '", chunk_title, "' (", nrow(chunk_polys), " polygons)...\n", sep = "")
  res <- create_chunk_job(chunk_polys, chunk_title)
  if (!is.null(res$job)) {
    cat("  OK - job id:", res$job$id, "\n")
    return(list(list(job = res$job, polys = chunk_polys, title = chunk_title)))
  }

  # Non-413 errors (auth hiccups, transient backend faults, etc.) are not
  # a size problem - splitting can never fix them. Retry once after a
  # short pause; if it fails again, stop with the real error instead of
  # cascading into a misleading "too large" diagnosis.
  if (!res$too_large) {
    if (!retried) {
      cat("  Non-size error, retrying once after a short pause: ", res$message, "\n", sep = "")
      Sys.sleep(10)
      return(register_jobs(chunk_polys, chunk_title, min_size, retried = TRUE))
    }
    stop("Chunk '", chunk_title, "' failed with a non-size error (not fixable by splitting): ",
         res$message)
  }

  if (nrow(chunk_polys) <= min_size) {
    stop("Chunk '", chunk_title, "' still rejected (413, too large) at floor size (", nrow(chunk_polys),
         " polygons) - investigate manually.")
  }
  cat("  REJECTED (too large) - splitting in half.\n")
  half <- ceiling(nrow(chunk_polys) / 2)
  c(register_jobs(chunk_polys[seq_len(half), ], paste0(chunk_title, "a"), min_size),
    register_jobs(chunk_polys[(half + 1):nrow(chunk_polys), ], paste0(chunk_title, "b"), min_size))
}

# ------------------------------------------------------------
# Run one already-registered job to completion: estimate, (optionally
# stop), start, poll, download, clean + id-map by position.
# ------------------------------------------------------------
# One region's real processing failure must not abandon the other nine -
# CONFIRMED (2026-09-03): a bare stop() here propagates through the
# top-level lapply() and kills the whole R process, leaving every
# not-yet-reached job stuck at "created" forever (never even getting a
# start_job() call) - NOT a CDSE problem, a bug in this script's own
# control flow. Every failure path below now returns a structured
# failure marker instead of stop()-ing, so run_all_chunks() can continue
# with the remaining jobs and report a clear pass/fail summary at the end.
run_chunk <- function(entry) {
  job <- entry$job; chunk_polys <- entry$polys; chunk_title <- entry$title

  est <- tryCatch(estimate_job(job = job), error = function(e) e)
  if (!inherits(est, "error")) {
    cat("\n--- Estimate for '", chunk_title, "' ---\n", sep = "")
    print(est)
  } else {
    cat("estimate_job() failed for '", chunk_title, "': ", conditionMessage(est), "\n", sep = "")
  }
  if (ESTIMATE_ONLY) return(list(ok = TRUE, title = chunk_title, data = NULL))

  start_res <- tryCatch({ start_job(job = job); TRUE }, error = function(e) e)
  if (inherits(start_res, "error")) {
    return(list(ok = FALSE, title = chunk_title, error = paste("start_job() failed:", conditionMessage(start_res))))
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
    cat("  [", chunk_title, "] job status:", status, "-", format(Sys.time(), "%H:%M:%S"),
        sprintf("(%.1f min elapsed)", elapsed_min), "\n")
    if (status %in% c("finished", "error", "canceled")) break
    if (elapsed_min > MAX_POLL_MIN) {
      return(list(ok = FALSE, title = chunk_title,
                  error = paste0("did not finish within ", MAX_POLL_MIN, " min (stuck at '", status, "')")))
    }
    Sys.sleep(15)
  }
  if (status != "finished") {
    log_text <- tryCatch({
      l <- log_job(job = job)
      if (is.list(l) && !is.null(l$logs) && length(l$logs) > 0) {
        paste(vapply(l$logs, function(x) paste0("[", x$level, "] ", x$message), character(1)), collapse = " | ")
      } else {
        "(no log entries returned by the backend for this job)"
      }
    }, error = function(e) paste("(could not fetch logs:", conditionMessage(e), ")"))
    return(list(ok = FALSE, title = chunk_title,
                error = paste0("finished with status '", status, "'. ", log_text)))
  }

  dl_res <- tryCatch({
    dl_dir <- file.path(out_dir, chunk_title)
    if (!dir.exists(dl_dir)) dir.create(dl_dir, recursive = TRUE)
    download_results(job = job, folder = dl_dir)

    raw <- read.csv(file.path(dl_dir, "timeseries.csv"))
    id_lookup <- data.frame(feature_index = seq_len(nrow(chunk_polys)) - 1, id = chunk_polys$id)
    raw %>%
      rename(mean = band_unnamed) %>%
      filter(!is.na(mean)) %>%
      left_join(id_lookup, by = "feature_index") %>%
      mutate(date = as.Date(date)) %>%
      dplyr::select(id, mean, date)
  }, error = function(e) e)

  if (inherits(dl_res, "error")) {
    return(list(ok = FALSE, title = chunk_title, error = paste("download/clean failed:", conditionMessage(dl_res))))
  }
  list(ok = TRUE, title = chunk_title, data = dl_res)
}

run_all_chunks <- function(entries) {
  outcomes <- lapply(entries, run_chunk)
  failed <- Filter(function(o) !o$ok, outcomes)
  if (length(failed) > 0) {
    cat("\n=== ", length(failed), " of ", length(outcomes), " job(s) FAILED ===\n", sep = "")
    for (f in failed) cat("  [", f$title, "] ", f$error, "\n", sep = "")
    cat("(the remaining ", length(outcomes) - length(failed),
        " job(s) succeeded and are included in the output below)\n\n", sep = "")
  }
  outcomes
}

# ------------------------------------------------------------
# Top level: TEST_MODE runs one small chunk; national mode registers one
# job per region (mirroring the original NINA GEE export's own 6-region
# chunking) and auto-splits further only if a region itself is rejected.
# ------------------------------------------------------------
if (TEST_MODE) {
  job_entries <- register_jobs(wetland_sub, paste0("ndvi_test_", TEST_REGION, "_", TEST_YEAR))
} else {
  region_names <- setdiff(unique(regions$region), NA)
  job_entries <- list()
  for (rn in region_names) {
    region_geom <- regions %>% filter(region == rn) %>% st_transform(4326)
    region_polys <- wetland[st_intersects(wetland, region_geom, sparse = FALSE)[, 1], ]
    if (nrow(region_polys) == 0) next
    job_entries <- c(job_entries, register_jobs(region_polys, paste0("ndvi_national_", rn)))
  }
}

cat("\n", length(job_entries), "job(s) registered total.\n")

if (ESTIMATE_ONLY) {
  run_all_chunks(job_entries)
  cat("\nSENTINEL_ESTIMATE_ONLY=1 set - all jobs registered + estimated, none started (no execution cost).\n")
  quit(save = "no", status = 0)
}

outcomes <- run_all_chunks(job_entries)
clean_all <- bind_rows(lapply(Filter(function(o) o$ok, outcomes), function(o) o$data))

job_title <- if (TEST_MODE) paste0("ndvi_test_", TEST_REGION, "_", TEST_YEAR) else "ndvi_national"
clean_path <- file.path(out_dir, paste0(job_title, "_clean.csv"))
write.csv(clean_all, clean_path, row.names = FALSE)
cat("\nCleaned + id-mapped output (", nrow(clean_all), "rows across", length(job_entries),
    "job(s)) saved to:", clean_path, "\n")
