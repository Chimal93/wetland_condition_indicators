# ============================================================
# NO_GJEN_001 - Gjengroing / Woody encroachment - WETLAND ecosystems only.
# FULLY OPEN-SOURCE, SELF-CONTAINED VERSION - SINGLE-FILE EDITION.
#
# Consolidated into one file for this migration copy: the original
# NO_GJEN_001 folder splits the shared CHM-sampling engine across 3
# files that source() each other (stratified_chm_sampling.R,
# elevation_source.R, building_mask.R) - inlined below as STAGE 1b, in
# dependency order (elevation -> building filter -> sampling), with no
# behavior change. The original, private-file-dependent version is kept
# separately in NO_GJEN_001/NO_GJEN_001_wetland_pipeline.R, not migrated
# here.
#
# ------------------------------------------------------------------
# RAW DATA INPUTS NEEDED (fetch once; cached under Data/OpenS_data/ -
# re-run is then instant):
#
#   1. AR5 forest + wetland polygons (ARTYPE 30/60) - PREFERRED, finer
#      boundaries, personal/organizational access only (see 1a).
#        -> extract_ar5_skog_myr.R
#           (needs AR5-skog-myr.gpkg already placed at the Indikatorer root)
#   1a. AR50 forest + wetland polygons (NIBIO, NLOD-open, fully public,
#      no access request needed) - AUTOMATIC FALLBACK if AR5 isn't
#      available. Coarser boundaries than AR5 (e.g. Nord-Norge/Lavalpin
#      sone skog: 3.97m on AR5 vs 2.60m on AR50 - expected, not an
#      error) - lets this pipeline run for someone with zero personal
#      access at all.
#        -> build_ar50_skog.R (-> ar50_skog_national.gpkg) and
#           build_ar50_wetland_lidar_coverage.R (-> ar50_myr_national.gpkg)
#   2. Kartverket DTM1/DOM1 LiDAR (terrain + surface models)
#        -> no fetch script - STAGE 1b below streams this live,
#           point-by-point, directly from Kartverket's server; nothing is
#           ever downloaded as a full dataset
#   3. Senf et al. forest disturbance/clear-cut map
#        -> fetch_disturbance.R
#   4. OpenStreetMap building footprints
#        -> fetch_osm_buildings.R
#   5. Moen bioclimatic zones
#        -> fetch_bioclim_zones.R
#   6. Kartverket StatistiskRutenett1km (-> 50km grid)
#        -> build_ssb_grids.R
#   7. Five-region delineation for Norway (regions.shp)
#        -> no fetch script - reused as-is from NO_GJEN_002/NO_FUNC_003
#   8. National NiN nature-type dataset (wetland X100 "good condition"
#      reference polygons)
#        -> fetch_nin_data.R
#
# DERIVED PREREQUISITES (built FROM the raw inputs above; also cached):
#   - Data/OpenS_data/dtm1_tile_footprint.gpkg           <- build_ar50_wetland_lidar_coverage.R
#     (REQUIRED regardless of AR5/AR50 choice - the DTM1 tile grid every
#     CHM extraction and building-filter call below batches points by;
#     not just an AR50-fallback byproduct despite where it's built)
#   - Data/OpenS_data/ar5_skog_national.gpkg / ar5_myr_national.gpkg
#                                                         <- extract_ar5_skog_myr.R
#   - Data/OpenS_data/ar50_skog_national.gpkg / ar50_myr_national.gpkg
#                                                         <- build_ar50_skog.R /
#                                                            build_ar50_wetland_lidar_coverage.R
#                                                            (only needed as the AR5 fallback)
#   - Stage 5's wetland reference heights are computed inline below and
#     cached to Data/OpenS_data/refvaatmark_NINA_median/refvaatmark_openS.csv
#     on first run - no separate build script needed.
#
# KNOWN CAVEAT: Stage 5's wetland reference-height reconstruction below
# does not closely match NINA's original refvaatmark.csv in absolute
# terms - systematically lower in most of the 25 region x bioclim strata
# (2-16x in the worst cases). Root cause unresolved (NINA's internal GEE
# script isn't public; likely candidates are a different DTM/DSM source
# or NiN dataset vintage). A controlled side-by-side run showed the
# downstream final indicator is only minimally affected (mean abs.
# difference across strata: 0.005; max: 0.077, both on the 0-1 scale) -
# kept as the best available open-data substitute. See Stage 5 below for
# the reasoning on why the divergence matters less than it looks.
#
# RUN TIME: see this migration's README's "Estimated run time" section -
# real cold-cache time was measured in hours, not the minutes a naive
# read of this script's own per-step console timings would suggest.
# ------------------------------------------------------------------
# ============================================================

# ===========================================================
# STAGE 1: Packages, working directory.
# ===========================================================

library(sf)
library(terra)
library(dplyr)
library(tidyr)
library(tibble)
library(readr)
library(stringr)
library(ggplot2)
library(gridExtra)
library(RColorBrewer)

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
# All relative paths below are anchored to: NO_GJEN_001_Migration/Main/

spatial_dir <- file.path("..", "Data", "OpenS_data")
data_dir    <- file.path("..", "Data")
results_dir     <- file.path("..", "Results")
if (!dir.exists(results_dir)) dir.create(results_dir, recursive = TRUE)

regionlvl      <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
vegclimzonelvl <- c("Lavalpin sone (LA)", "Nordboreal sone (NB)", "Mellomboreal sone (MB)",
                     "Sørboreal sone (SB)", "Boreonemoral sone (BN)")


# ===========================================================
# STAGE 1b: Shared CHM-sampling engine (elevation provider, building
# filter, stratified sampling + extraction) - used by Stage 4/5/6 below.
# Consolidated from 3 originally-separate files (see header) - no
# behavior change, just inlined in dependency order.
# ===========================================================

# --- Elevation provider: DTM/DSM -> CHM (originally
# elevation_source.R). get_chm(aoi) is the documented public interface,
# reading Kartverket's open 1m DTM1/DOM1 tiles directly over HTTP; the
# bulk national sampling below re-derives tile URLs itself in
# .process_tile() rather than calling get_chm() per point, for
# performance, but get_chm() is kept as the documented single-AOI entry
# point. ---

.kartverket_tile_url <- function(tile_id, product) {
  paste0("/vsicurl/https://nedlasting.geonorge.no/hoydedata/", product, "/", tile_id, ".tif")
}

.kartverket_tiles_for_aoi <- function(aoi, tile_footprint_path) {
  tiles <- st_read(tile_footprint_path, quiet = TRUE)
  tiles <- st_transform(tiles, st_crs(aoi))
  hits <- tiles[st_intersects(tiles, aoi, sparse = FALSE)[, 1], ]
  if (nrow(hits) == 0) {
    stop("No DTM1/DOM1 tile covers this area of interest - either it's ",
         "outside Norway or outside Kartverket's current 1m LiDAR coverage. ",
         "Consider the 10m DTM10/DOM10 product (confirmed fully nationwide) ",
         "as a coarser fallback.")
  }
  hits
}

.mosaic_if_needed <- function(rasters) {
  if (length(rasters) == 1) return(rasters[[1]])
  do.call(terra::mosaic, rasters)
}

get_chm_kartverket <- function(aoi,
                                tile_footprint_path = file.path("..", "Data", "OpenS_data", "dtm1_tile_footprint.gpkg"),
                                buffer_m = 20) {
  aoi_b <- st_buffer(aoi, buffer_m)
  tiles <- .kartverket_tiles_for_aoi(aoi_b, tile_footprint_path)

  dtm_rasters <- lapply(tiles$tile_id, function(id) terra::rast(.kartverket_tile_url(id, "DTM1")))
  dom_rasters <- lapply(tiles$tile_id, function(id) terra::rast(.kartverket_tile_url(id, "DOM1")))

  dtm <- .mosaic_if_needed(dtm_rasters)
  dom <- .mosaic_if_needed(dom_rasters)

  bbox <- st_bbox(aoi_b)
  win  <- terra::ext(bbox["xmin"], bbox["xmax"], bbox["ymin"], bbox["ymax"])
  dtm_c <- terra::crop(dtm, win)
  dom_c <- terra::crop(dom, win)

  chm <- dom_c - dtm_c
  chm[chm < 0] <- 0
  names(chm) <- "chm"
  chm
}

#' Get a canopy height model (CHM) raster for an area of interest.
#' Reads Kartverket's open 1m DTM1/DOM1 tiles directly over HTTP.
#' @param aoi sf polygon(s), any CRS (reprojected internally as needed).
#' @param buffer_m buffer applied to the AOI before reading. Default 20m.
get_chm <- function(aoi, buffer_m = 20) {
  get_chm_kartverket(aoi, buffer_m = buffer_m)
}

# --- Building filter: drop sample points that fall on a building
# (originally building_mask.R). OSM (open, in use) vs. FKB-Bygning
# (gated, not available - errors immediately if selected). ---

.query_buildings_osm <- function(bbox, buildings_path) {
  wkt <- sf::st_as_text(sf::st_as_sfc(bbox))
  st_read(buildings_path, wkt_filter = wkt, quiet = TRUE)
}

.query_buildings_fkb <- function(bbox, buildings_path) {
  stop("FKB-Bygning source not available - requires Norge Digitalt access. ",
       "Use source = \"osm\" (default), the currently available option.")
}

#' Drop any sample point that falls within a building footprint.
#' @param points_sf sf points, any CRS.
#' @param source "osm" (open, default) or "fkb" (not available - errors
#'   immediately, before any tile is queried).
#' @param tile_footprint_path DTM1 tile grid, reused only as a spatial
#'   batching unit (nothing to do with elevation here).
#' @param buildings_path national building-footprint layer for `source`.
filter_building_points <- function(points_sf,
                                    source = c("osm", "fkb"),
                                    tile_footprint_path = file.path("..", "Data", "OpenS_data", "dtm1_tile_footprint.gpkg"),
                                    buildings_path = file.path("..", "Data", "OpenS_data", "osm_buildings_national.gpkg")) {
  source <- match.arg(source)
  if (source == "fkb") {
    .query_buildings_fkb(NULL, NULL)  # errors immediately - not implemented
  }

  tiles <- st_read(tile_footprint_path, quiet = TRUE)
  pts <- st_transform(points_sf, st_crs(tiles))
  # Stable row id, independent of row position/count - st_join can
  # duplicate a row when a point falls in the (small) overlap between
  # adjacent DTM1 tile footprints, so a position-based index back into
  # points_sf would silently corrupt results (a logical vector longer
  # than nrow(points_sf) appends phantom NA-geometry rows rather than
  # erroring - confirmed the hard way originally).
  pts$.row_id <- seq_len(nrow(pts))
  joined <- st_join(pts, tiles["tile_id"])
  tile_ids <- unique(joined$tile_id)
  tile_ids <- tile_ids[!is.na(tile_ids)]

  cat("Building filter: checking", nrow(pts), "points (", nrow(joined), "after tile join) across",
      length(tile_ids), "tile extents against", basename(buildings_path), "(source:", source, ")...\n")

  on_building_ids <- integer(0)

  for (tid in tile_ids) {
    sub_pts <- joined[joined$tile_id == tid, ]
    bbox <- st_bbox(st_buffer(sub_pts, 20))
    bld <- .query_buildings_osm(bbox, buildings_path)
    if (nrow(bld) == 0) next
    bld <- st_transform(bld, st_crs(tiles))
    hits <- lengths(st_intersects(sub_pts, bld)) > 0
    on_building_ids <- c(on_building_ids, sub_pts$.row_id[hits])
  }

  on_building_ids <- unique(on_building_ids)
  cat("Building filter: dropping", length(on_building_ids), "/", nrow(points_sf),
      "points that fall on a building footprint\n")
  # NOTE: `points_sf[-integer(0), ]` returns ZERO rows, not "all rows" -
  # R's negative indexing does not treat an empty exclusion vector as
  # "exclude nothing". Must special-case it explicitly.
  if (length(on_building_ids) == 0) return(points_sf)
  points_sf[-on_building_ids, ]
}

# --- Stratified sampling + tile-batched CHM extraction (originally
# stratified_chm_sampling.R). Mirrors the public sibling
# Gjengroing_GEE_Script.js's stratifiedSample(scale:5, numPoints:1000,
# seed:123), stratified against bioClimReg (region x bioclim, 25 cells)
# to match the vegClimZone column present in NINA's own cached CSVs. ---

# Without these, a stalled/slow remote request can hang indefinitely -
# GDAL's vsicurl has no default timeout. Set before makeCluster() so
# PSOCK workers (which inherit the parent process's environment) pick
# these up too.
Sys.setenv(
  GDAL_HTTP_TIMEOUT        = "15",  # give up on a single request after 15s
  GDAL_HTTP_CONNECTTIMEOUT = "10",
  GDAL_HTTP_MAX_RETRY      = "2",
  GDAL_HTTP_RETRY_DELAY    = "1"
)

#' Split polygons at bioClimReg strata boundaries, tagging each fragment
#' with its stratum's region/vegClimZoneLab/ID.
assign_to_strata <- function(polygons, bio_clim_reg) {
  polygons <- st_transform(polygons, st_crs(bio_clim_reg)) %>% st_make_valid()
  suppressWarnings(st_intersection(polygons, bio_clim_reg))
}

#' Draw n_per_stratum stratified random points from `frags` (the output
#' of assign_to_strata), one stratum at a time, area-weighted within
#' each stratum (st_sample's default behaviour across multiple polygons).
draw_stratified_points <- function(frags, n_per_stratum = 1000, seed = 123) {
  set.seed(seed)
  strata_ids <- sort(unique(frags$ID))
  pts_list <- vector("list", length(strata_ids))

  for (i in seq_along(strata_ids)) {
    sid <- strata_ids[i]
    sub <- frags[frags$ID == sid, ]
    total_area <- sum(as.numeric(st_area(sub)))
    if (total_area <= 0 || nrow(sub) == 0) next

    cat("  starting stratum", sid, "(", as.character(sub$region[1]), "/", as.character(sub$vegClimZoneLab[1]), ") -",
        nrow(sub), "polygons,", round(total_area / 1e6, 1), "km^2...\n")
    flush.console()
    t0 <- Sys.time()
    pts <- suppressMessages(st_sample(sub, size = n_per_stratum, type = "random"))
    dt <- round(as.numeric(Sys.time() - t0), 1)
    if (length(pts) == 0) next

    pts_sf <- st_sf(
      stratum_ID     = sid,
      region         = sub$region[1],
      vegClimZoneLab = sub$vegClimZoneLab[1],
      geometry       = pts
    )
    pts_list[[i]] <- pts_sf
    cat("  stratum", sid, "(", as.character(sub$region[1]), "/", as.character(sub$vegClimZoneLab[1]), "):",
        length(pts), "points drawn from", round(total_area / 1e6, 1), "km^2 in", dt, "sec\n")
    flush.console()
  }

  do.call(rbind, pts_list[!sapply(pts_list, is.null)])
}

#' Drop any sample point that falls on a pixel with a recorded
#' disturbance (clear-cut) between 1986-2020, per the Senf et al.
#' disturbance map - used for Stage 4's forest reference-height
#' sampling only (wetlands aren't clear-cut masked in the original
#' methodology). NA in the disturbance raster = no disturbance recorded
#' = keep the point. A valid year (1986-2020) = disturbed = drop.
filter_disturbed_points <- function(points_sf,
                                     disturbance_path = file.path("..", "Data", "OpenS_data", "disturbance", "disturbance_year_1986-2020_norway.tif")) {
  dist_r <- terra::rast(disturbance_path)
  pts_proj <- st_transform(points_sf, terra::crs(dist_r))
  vals <- terra::extract(dist_r, terra::vect(pts_proj))
  disturbed <- !is.na(vals[[2]])
  cat("Disturbance filter: dropping", sum(disturbed), "/", nrow(points_sf),
      "points that fall on a recorded 1986-2020 clear-cut\n")
  points_sf[!disturbed, ]
}

#' Per-tile worker: opens one tile's DTM1/DOM1 ONCE (cheap - lazy
#' handles, headers only), then crops/extracts PER POINT with a small,
#' fixed-size window, reusing those handles across every point sharing
#' this tile. Self-contained (re-derives the tile URL inline) so it can
#' run on a parallel worker process without needing anything else
#' sourced there - only `terra` needs to be loaded on each worker.
#' Per-point windows, not one crop spanning all of a tile's points -
#' measured directly: a single bbox spanning many scattered points
#' within a tile balloons back toward a near-full-tile read once
#' points/tile rises much past ~2.
.process_tile <- function(item, buffer_m) {
  tile_url <- function(tile_id, product) {
    paste0("/vsicurl/https://nedlasting.geonorge.no/hoydedata/", product, "/", tile_id, ".tif")
  }
  dtm <- tryCatch(terra::rast(tile_url(item$tile_id, "DTM1")), error = function(e) NULL)
  dom <- tryCatch(terra::rast(tile_url(item$tile_id, "DOM1")), error = function(e) NULL)
  if (is.null(dtm) || is.null(dom)) {
    return(data.frame(row_idx = item$row_idx, chm = NA_real_))
  }

  vals <- numeric(length(item$row_idx))
  for (k in seq_along(item$row_idx)) {
    win <- terra::ext(item$x[k] - buffer_m, item$x[k] + buffer_m,
                       item$y[k] - buffer_m, item$y[k] + buffer_m)
    vals[k] <- tryCatch({
      dtm_c <- terra::crop(dtm, win)
      dom_c <- terra::crop(dom, win)
      c <- dom_c - dtm_c
      c[c < 0] <- 0
      as.numeric(terra::global(c, "mean", na.rm = TRUE)[1, 1])
    }, error = function(e) NA_real_)
  }
  data.frame(row_idx = item$row_idx, chm = vals)
}

#' Extract mean CHM within a small buffer around each point,
#' tile-batched and parallelized across tiles (network-latency bound,
#' not CPU bound - n_workers=8 is a deliberately moderate choice, not
#' maxed out, to stay considerate to Kartverket's public server).
#' buffer_m = 2.5 -> a 5m-diameter window, mirroring the original
#' script's scale:5 sampling resolution.
extract_chm_at_points <- function(points_sf, buffer_m = 2.5,
                                   tile_footprint_path = file.path("..", "Data", "OpenS_data", "dtm1_tile_footprint.gpkg"),
                                   n_workers = 8) {
  tiles <- st_read(tile_footprint_path, quiet = TRUE)
  points_sf <- st_transform(points_sf, st_crs(tiles))
  joined <- st_join(points_sf, tiles["tile_id"])
  joined$chm <- NA_real_

  tile_ids <- unique(joined$tile_id)
  tile_ids <- tile_ids[!is.na(tile_ids)]
  cat("Extracting CHM across", length(tile_ids), "distinct DTM1 tiles for", nrow(joined),
      "points (", n_workers, "parallel workers)...\n")

  coords <- st_coordinates(joined)
  work_items <- lapply(tile_ids, function(tid) {
    idx <- which(joined$tile_id == tid)
    list(tile_id = tid, row_idx = idx, x = coords[idx, 1], y = coords[idx, 2])
  })

  cl <- parallel::makeCluster(n_workers)
  on.exit(parallel::stopCluster(cl), add = TRUE)
  parallel::clusterEvalQ(cl, {
    Sys.setenv(GDAL_HTTP_TIMEOUT = "15", GDAL_HTTP_CONNECTTIMEOUT = "10",
               GDAL_HTTP_MAX_RETRY = "2", GDAL_HTTP_RETRY_DELAY = "1")
    library(terra)
  })

  t0 <- Sys.time()
  results_list <- parallel::parLapply(cl, work_items, .process_tile, buffer_m = buffer_m)
  cat("  extraction across", length(tile_ids), "tiles took",
      round(as.numeric(Sys.time() - t0), 1), "sec\n")

  results_df <- do.call(rbind, results_list)
  joined$chm[results_df$row_idx] <- results_df$chm
  joined
}

#' Top-level entry point: polygons in, stratified+tile-batched CHM
#' samples out. Building-masked by default (source = "osm") before CHM
#' extraction, so sampled heights reflect vegetation, not rooftops.
sample_chm_by_stratum <- function(polygons, bio_clim_reg, n_per_stratum = 1000,
                                   seed = 123, buffer_m = 2.5, n_workers = 8,
                                   filter_buildings = TRUE, building_source = "osm") {
  cat("Assigning", nrow(polygons), "polygons to", nrow(bio_clim_reg), "strata...\n")
  frags <- assign_to_strata(polygons, bio_clim_reg)
  cat("Drawing", n_per_stratum, "points per stratum (seed", seed, ")...\n")
  pts <- draw_stratified_points(frags, n_per_stratum = n_per_stratum, seed = seed)
  cat("Total points drawn:", nrow(pts), "\n")
  if (filter_buildings) {
    pts <- filter_building_points(pts, source = building_source)
    cat("Points remaining after building filter:", nrow(pts), "\n")
  }
  extract_chm_at_points(pts, buffer_m = buffer_m, n_workers = n_workers)
}


# ===========================================================
# STAGE 2: Load the five-region delineation for Norway.
# ===========================================================

regions_path <- file.path(spatial_dir, "regions.shp")
if (!file.exists(regions_path)) {
  stop(
    "Missing required file: ", regions_path, "\n",
    "Copy it from NO_FUNC_003/Data/NINA/spatial/regions.shp or ",
    "NO_CONN_001/Data/spatial/regions.shp and re-run."
  )
}

regions <- st_read(regions_path, quiet = TRUE)

# Known double-encoding bug in this file's DBF: ids 3/5 come back garbled.
# Every downstream join matches on the literal region name, so this must
# be fixed here regardless.
regions$region[regions$id == 3] <- "Østlandet"
regions$region[regions$id == 5] <- "Sørlandet"

regions <- regions %>%
  mutate(region = factor(region, levels = regionlvl))


# ===========================================================
# STAGE 3: Bioclimatic zones -> bioClimReg (region x zone strata polygons).
# [OPEN SOURCE] Zones fetched from the public Miljødirektoratet ArcGIS
# service (fetch_bioclim_zones.R) rather than NINA's internal R: drive copy.
# ===========================================================

bioclimzone_path <- file.path(spatial_dir, "bioclim", "bioclimzone.shp")
soner_path       <- file.path(spatial_dir, "bioclim", "soner2017.shp")

if (file.exists(bioclimzone_path)) {
  # Already-dissolved cache: one polygon per zone, NAVN/KLASSE already set.
  bioclim <- st_read(bioclimzone_path, quiet = TRUE) %>%
    st_transform(st_crs(regions))
  bioclim$NAVN <- factor(bioclim$NAVN, levels = vegclimzonelvl)

} else if (file.exists(soner_path)) {
  # Raw tiled source: dissolve by zone name, then assign a numeric class.
  bioclim <- st_read(soner_path, quiet = TRUE) %>%
    st_transform(st_crs(regions))
  bioclim <- bioclim %>%
    group_by(Sone_navn) %>%
    summarise(geometry = st_union(geometry)) %>%
    mutate(KLASSE = as.numeric(as.factor(Sone_navn))) %>%
    rename(NAVN = Sone_navn)
  bioclim$NAVN <- factor(bioclim$NAVN, levels = vegclimzonelvl)

} else {
  stop(
    "Missing required file: ", soner_path, "\n",
    "Run fetch_bioclim_zones.R to produce it."
  )
}

# Intersect zones with regions -> one polygon per unique region x
# bioclim-zone stratum (a "homogeneous ecosystem area"). Everything below
# is stratified against this.
bioClimReg <- bioclim %>%
  st_intersection(regions) %>%
  mutate(vegClimZoneLab = NAVN) %>%
  dplyr::select(region, vegClimZoneLab) %>%
  rowid_to_column("ID")

bioClimReg$vegClimZoneLab <- factor(bioClimReg$vegClimZoneLab, levels = vegclimzonelvl)
bioClimReg$region         <- factor(bioClimReg$region,         levels = regionlvl)


# ===========================================================
# STAGE 4: Forest ("skog") reference heights per region x bioclim stratum
# (X0, poor-condition anchor for the sigmoid scaling in Stage 8).
#
# [OPEN SOURCE] Original: 90th-percentile CHM inside NINA's internal
# "nasjonalt grunnkart skog" polygons, clear-cut masked, from a bespoke GEE
# export. Here: AR5 Skog polygons (ARTYPE==30) + Kartverket DTM1/DOM1 CHM +
# Senf et al. clear-cut mask + OSM building mask, stratified point-sampled
# (1000 pts/bioClimReg stratum, seed 123, ~5m window) and aggregated to the
# 90th percentile per stratum.
#
# Reads the cached result instantly if present; otherwise computes it here
# from the raw AR5 polygons (national sampling + CHM extraction - see
# README for real timing) and caches it for next time. KNOWN LIMITATION:
# AR5's plain ARTYPE==30 has no equivalent to the NiN reference side's V2
# "sumpskog" tree-cover carve-out - left unaddressed, revisit only if
# this turns out to matter for result quality.
# ===========================================================

skog_path_openS    <- file.path(spatial_dir, "vegHeights_skog_climZoneRegion_openS.csv")
skog_raw_path_ar5  <- file.path(spatial_dir, "ar5_skog_national.gpkg")
skog_raw_path_ar50 <- file.path(spatial_dir, "ar50_skog_national.gpkg")

if (file.exists(skog_path_openS)) {
  skog_cached <- read_csv(skog_path_openS, show_col_types = FALSE)
  cached_source <- if ("population_source" %in% names(skog_cached)) {
    unique(skog_cached$population_source)[1]
  } else {
    "unknown - cached before source-tagging was added"
  }
  message("Stage 4: using cached forest reference heights: ", skog_path_openS,
          " (source: ", cached_source, ")")
  skog_region_bioclim <- skog_cached %>% dplyr::select(region, vegClimZoneLab, skog)
} else {
  # AR5 (personal/organizational access, finer boundaries) is preferred;
  # AR50 (NIBIO, fully public, no access request needed - see header
  # item 1a) is an automatic fallback, not a silent swap - which source
  # was used is always printed, and results WILL differ slightly from
  # an AR5-based run (documented, expected - e.g. Nord-Norge/Lavalpin
  # sone skog: 3.97m on AR5 vs 2.60m on AR50), not a bug either way.
  if (file.exists(skog_raw_path_ar5)) {
    skog_raw_path <- skog_raw_path_ar5
    message("Stage 4: no cache found - computing forest reference heights from AR5 ",
            "now (national stratified sampling + CHM extraction; expect this to ",
            "take a while on a cold cache).")
  } else if (file.exists(skog_raw_path_ar50)) {
    skog_raw_path <- skog_raw_path_ar50
    message("Stage 4: AR5 not found (", skog_raw_path_ar5, ") - falling back to ",
            "AR50 (fully open, no personal access needed). Results will differ ",
            "slightly from an AR5-based run - see this script's header.")
  } else {
    stop(
      "Missing required file - need EITHER of:\n",
      "  (a) ", skog_raw_path_ar5, " [PREFERRED, finer boundaries]\n",
      "      Run extract_ar5_skog_myr.R (needs AR5-skog-myr.gpkg, personal/\n",
      "      organizational access, at the Indikatorer root) to produce it.\n",
      "  (b) ", skog_raw_path_ar50, " [fully open fallback]\n",
      "      Run build_ar50_skog.R to produce it.\n",
      "Produce (a) or (b) and re-run."
    )
  }
  skog_source <- if (identical(skog_raw_path, skog_raw_path_ar5)) "AR5" else "AR50"
  skog_poly <- st_read(skog_raw_path, quiet = TRUE)
  cat("Assigning", nrow(skog_poly), "Skog polygons to", nrow(bioClimReg), "strata...\n")
  frags <- assign_to_strata(skog_poly, bioClimReg)
  pts   <- draw_stratified_points(frags, n_per_stratum = 1000, seed = 123)
  cat("Points drawn (before disturbance filter):", nrow(pts), "\n")
  pts   <- filter_disturbed_points(pts)
  pts   <- filter_building_points(pts, source = "osm")
  samples <- extract_chm_at_points(pts, buffer_m = 2.5)

  skog_region_bioclim <- samples %>%
    st_drop_geometry() %>%
    filter(!is.na(chm)) %>%
    group_by(region, vegClimZoneLab) %>%
    summarise(skog = quantile(chm, 0.90, na.rm = TRUE), n = n(), .groups = "drop") %>%
    mutate(population_source = skog_source)

  write_csv(skog_region_bioclim, skog_path_openS)
  cat("Cached to:", skog_path_openS, "(source:", skog_source,
      "- future runs will read this instantly regardless of source)\n")
  skog_region_bioclim <- skog_region_bioclim %>% dplyr::select(region, vegClimZoneLab, skog)
}

skog_region_bioclim$region         <- factor(skog_region_bioclim$region,         levels = regionlvl)
skog_region_bioclim$vegClimZoneLab <- factor(skog_region_bioclim$vegClimZoneLab, levels = vegclimzonelvl)


# ===========================================================
# STAGE 5: Wetland reference heights (X100, good-condition anchor).
#
# [OPEN SOURCE] Original: median LiDAR height within NiN "Vatmark"
# polygons with tilstand=="God" (good ecological condition), excluding
# tree-covered-but-good-condition swamp-forest/spring-forest/strand-
# forest types and T1 (nakent berg) types, from a bespoke GEE export.
# Here: the same national NiN nature-type dataset (open, Miljodirektoratet),
# same tilstand/exclusion-list filters, points allocated proportional to
# each polygon's own area (not a single stratum-wide sample - avoids a
# confirmed pathological memory/time blowup on strata with few, widely-
# scattered polygons), Kartverket DTM1/DOM1 CHM, OSM building mask,
# aggregated to the MEDIAN per stratum (matching NINA's methodology -
# X100 is explicitly defined as a percentile, and median is used
# consistently across all 3 ecosystem types, not the mean).
#
# KNOWN CAVEAT: does not closely match NINA's original refvaatmark.csv in
# absolute terms (systematically lower in most strata, 2-16x in the worst
# cases) - root cause unresolved (see header). Only a small effect on the
# final downstream indicator regardless (mean abs. index diff 0.005, max
# 0.077 on the 0-1 scale) - kept as the best available open substitute.
#
# Reads the cached result instantly if present; otherwise computes it here
# from the raw NiN geodatabase and caches it for next time. Optional
# sample-size (n) labels for Stage 12's chart come from raw per-polygon
# files that also aren't bundled; skipped gracefully if absent (they always
# will be here, since that directory is NINA-only).
# ===========================================================

refvaatmark_path_openS <- file.path(spatial_dir, "refvaatmark_NINA_median", "refvaatmark_openS.csv")
nin_gdb_path <- file.path(spatial_dir, "nin_data", "Naturtyper_nin_0000_norge_4326_FILEGDB.gdb")

if (file.exists(refvaatmark_path_openS)) {
  message("Stage 5: using cached wetland reference heights: ", refvaatmark_path_openS)
  refvaatmark <- read_csv(refvaatmark_path_openS, show_col_types = FALSE) %>%
    dplyr::select(region, vegClimZoneLab, ref)
} else {
  message("Stage 5: no cache found - computing wetland reference heights from the ",
          "national NiN dataset now (national stratified sampling + CHM extraction; ",
          "expect this to take a while on a cold cache).")
  if (!file.exists(nin_gdb_path)) {
    stop(
      "Missing required file: ", nin_gdb_path, "\n",
      "Run fetch_nin_data.R first to produce it."
    )
  }

  # Per-polygon area-proportional sampling (not the shared draw_stratified_
  # points() above, which draws once per whole stratum) - confirmed
  # necessary to avoid a multi-GB/multi-hour blowup on scattered-sliver
  # strata. Local to this stage only.
  draw_stratified_points_by_polygon <- function(frags, n_per_stratum = 1000, seed = 123) {
    set.seed(seed)
    strata_ids <- sort(unique(frags$ID))
    pts_list <- vector("list", length(strata_ids))
    for (i in seq_along(strata_ids)) {
      sid <- strata_ids[i]
      sub <- frags[frags$ID == sid, ]
      areas <- as.numeric(st_area(sub))
      total_area <- sum(areas)
      if (total_area <= 0 || nrow(sub) == 0) next
      raw_alloc <- n_per_stratum * areas / total_area
      n_alloc <- floor(raw_alloc)
      remainder <- n_per_stratum - sum(n_alloc)
      if (remainder > 0) {
        frac_order <- order(raw_alloc - n_alloc, decreasing = TRUE)
        n_alloc[frac_order[seq_len(remainder)]] <- n_alloc[frac_order[seq_len(remainder)]] + 1
      }
      poly_pts <- vector("list", nrow(sub))
      for (j in seq_len(nrow(sub))) {
        nj <- n_alloc[j]
        if (nj <= 0) next
        pj <- tryCatch(
          suppressMessages(st_sample(sf::st_geometry(sub)[j], size = nj, type = "random")),
          error = function(e) st_sfc(crs = st_crs(sub))
        )
        if (length(pj) > 0) poly_pts[[j]] <- pj
      }
      poly_pts <- poly_pts[!vapply(poly_pts, is.null, logical(1))]
      if (length(poly_pts) == 0) next
      pts <- do.call(c, poly_pts)
      pts_list[[i]] <- st_sf(stratum_ID = sid, region = sub$region[1],
                              vegClimZoneLab = sub$vegClimZoneLab[1], geometry = pts)
    }
    do.call(rbind, pts_list[!vapply(pts_list, is.null, logical(1))])
  }

  excluded_naturtyper <- c(
    "Hule eiker", "Hagemark", "Lauveng",
    "Saltpåvirket strand- og sumpskogsmark", "Flommyr, myrkant og myrskogsmark",
    "Grankildeskog", "Sørlig kaldkilde", "Kaldkilde under skoggrensa",
    "Svak kilde og kildeskogsmark", "Varmekjær kildelauvskog",
    "Gammel fattig sumpskog", "Rik gransumpskog", "Rik svartorsumpskog",
    "Kilde-edellauvskog", "Rik gråorsumpskog", "Kalkrik myr- og sumpskogsmark",
    "Rik vierstrandskog", "Rik svartorstrandskog", "Saltpåvirket svartorstrandskog",
    "Leirravine", "Kalkrik helofyttsump",
    "Grotte", "Silt og leirskred", "Fossepåvirket berg"
  )

  nin <- st_read(nin_gdb_path, layer = "naturtyper_nin_omr", quiet = TRUE)
  nin_wetland_ref <- nin %>%
    filter(hovedøkosystem == "våtmark") %>%
    filter(tilstand == "god") %>%
    filter(!(naturtype %in% excluded_naturtyper)) %>%
    filter(!grepl("T1-", ninKartleggingsenheter)) %>%
    st_transform(st_crs(bioClimReg)) %>%
    st_make_valid()

  frags <- nin_wetland_ref %>%
    st_join(bioClimReg %>% select(ID, region, vegClimZoneLab), largest = TRUE) %>%
    filter(!is.na(ID))
  pts <- draw_stratified_points_by_polygon(frags, n_per_stratum = 1000, seed = 123)
  pts <- filter_building_points(pts, source = "osm")
  samples <- extract_chm_at_points(pts, buffer_m = 2.5)

  refvaatmark <- samples %>%
    st_drop_geometry() %>%
    filter(!is.na(chm)) %>%
    group_by(region, vegClimZoneLab) %>%
    summarise(ref = median(chm, na.rm = TRUE), n = n(), .groups = "drop")

  dir.create(dirname(refvaatmark_path_openS), showWarnings = FALSE, recursive = TRUE)
  write_csv(refvaatmark, refvaatmark_path_openS)
  cat("Cached to:", refvaatmark_path_openS, "(future runs will read this instantly)\n")
  refvaatmark <- refvaatmark %>% dplyr::select(region, vegClimZoneLab, ref)
}

refvaatmark$region         <- factor(refvaatmark$region,         levels = regionlvl)
refvaatmark$vegClimZoneLab <- factor(refvaatmark$vegClimZoneLab, levels = vegclimzonelvl)

# Only used to decode the optional raw n-label files just below (if ever
# supplied) - numeric region_id/vegClimZone codes to string labels.
vegLookup <- tibble(
  vegClimZone    = c(1, 2, 3, 4, 5),
  vegClimZoneLab = c("Boreonemoral sone (BN)", "Lavalpin sone (LA)", "Mellomboreal sone (MB)",
                      "Nordboreal sone (NB)", "Sørboreal sone (SB)")
)
cleanRegClim <- function(data) {
  data %>%
    mutate(region = case_match(region_id,
      1 ~ "Nord-Norge", 2 ~ "Midt-Norge", 3 ~ "Østlandet",
      4 ~ "Vestlandet", 5 ~ "Sørlandet"
    )) %>%
    mutate(vegClimZone = round(vegClimZone)) %>%
    left_join(vegLookup, by = "vegClimZone") %>%
    dplyr::select(-region_id, -vegClimZone) %>%
    drop_na(vegClimZoneLab, region)
}

refheight_dir <- file.path(data_dir, "From_GEE", "vegHeights")
vaatmarkrawtab <- NULL
if (dir.exists(refheight_dir)) {
  readVegHeightFiles <- function(dir, uniqueString) {
    files <- list.files(dir)[str_detect(list.files(dir), uniqueString)]
    dat <- tibble()
    for (f in files) {
      dat <- dat %>%
        bind_rows(read_csv(file.path(dir, f), show_col_types = FALSE) %>%
                    mutate(ssbid = substr(str_split(f, "_")[[1]][3], 1, 14)))
    }
    dat
  }
  refvaatmarkRaw <- readVegHeightFiles(refheight_dir, "vaatmark_ref") %>%
    mutate(ref = chm) %>%
    dplyr::select(-any_of(c(".geo", "system:index", "chm")))
  vaatmarkrawtab <- cleanRegClim(refvaatmarkRaw) %>%
    group_by(region, vegClimZoneLab) %>%
    summarise(n = n(), .groups = "drop")
} else {
  message("Skipping sample-size (n) labels on the reference-height plot: ",
          refheight_dir, " not found.")
}


# ===========================================================
# STAGE 6: Wetland population heights (raw LiDAR heights per sampled
# wetland location).
#
# [OPEN SOURCE] Original: raw CHM sampled at wetland population locations
# within NINA's internal "nasjonalt grunnkart" Class 7 Våtmark, from a
# bespoke GEE export. Here: AR5 Myr polygons (ARTYPE==60) + Kartverket
# DTM1/DOM1 CHM + OSM building mask, stratified point-sampled (1000
# pts/bioClimReg stratum, seed 123, ~5m window). Same known V2/sumpskog
# limitation as Stage 4 (see above) - AR5's ARTYPE==60 has no equivalent
# carve-out either.
#
# Reads the cached result instantly if present; otherwise computes it here
# from the raw AR5 polygons and caches it for next time.
# ===========================================================

pop_path_openS    <- file.path(spatial_dir, "vaatmark_pop_openS.gpkg")
myr_raw_path_ar5  <- file.path(spatial_dir, "ar5_myr_national.gpkg")
myr_raw_path_ar50 <- file.path(spatial_dir, "ar50_myr_national.gpkg")

create_square <- function(point, size = 20) {
  st_buffer(point, dist = size / 2, endCapStyle = "SQUARE")
}

if (file.exists(pop_path_openS)) {
  vaatmark_cached <- st_read(pop_path_openS, quiet = TRUE)
  cached_source <- if ("population_source" %in% names(vaatmark_cached)) {
    unique(vaatmark_cached$population_source)[1]
  } else {
    "unknown - cached before source-tagging was added"
  }
  message("Stage 6: using cached wetland population heights: ", pop_path_openS,
          " (source: ", cached_source, ")")
  vaatmark_sampled <- vaatmark_cached %>% st_transform(st_crs(regions))
} else {
  # Same AR5-preferred/AR50-fallback logic as Stage 4 - see that stage's
  # comments for the rationale.
  if (file.exists(myr_raw_path_ar5)) {
    myr_raw_path <- myr_raw_path_ar5
    myr_source   <- "AR5"
    message("Stage 6: no cache found - computing wetland population heights from AR5 ",
            "now (national stratified sampling + CHM extraction; expect this to ",
            "take a while on a cold cache).")
  } else if (file.exists(myr_raw_path_ar50)) {
    myr_raw_path <- myr_raw_path_ar50
    myr_source   <- "AR50"
    message("Stage 6: AR5 not found (", myr_raw_path_ar5, ") - falling back to ",
            "AR50 (fully open, no personal access needed). Results will differ ",
            "slightly from an AR5-based run - see this script's header.")
  } else {
    stop(
      "Missing required file - need EITHER of:\n",
      "  (a) ", myr_raw_path_ar5, " [PREFERRED, finer boundaries]\n",
      "      Run extract_ar5_skog_myr.R (needs AR5-skog-myr.gpkg, personal/\n",
      "      organizational access, at the Indikatorer root) to produce it.\n",
      "  (b) ", myr_raw_path_ar50, " [fully open fallback]\n",
      "      Run build_ar50_wetland_lidar_coverage.R to produce it.\n",
      "Produce (a) or (b) and re-run."
    )
  }
  myr_poly <- st_read(myr_raw_path, quiet = TRUE)
  vaatmark_sampled <- sample_chm_by_stratum(myr_poly, bioClimReg, n_per_stratum = 1000,
                                             seed = 123, buffer_m = 2.5) %>%
    mutate(population_source = myr_source)
  st_write(vaatmark_sampled, pop_path_openS, delete_dsn = TRUE, quiet = TRUE)
  cat("Cached to:", pop_path_openS, "(source:", myr_source,
      "- future runs will read this instantly regardless of source)\n")
  vaatmark_sampled <- vaatmark_sampled %>% st_transform(st_crs(regions))
}

# Adds a unique row id (system:index/ssbid) - not a GEE artefact here, just
# a join key Stage 7/8 need, kept under those historical names so the rest
# of the pipeline (unchanged from the original extraction) needs no edits.
vaatmark_points <- vaatmark_sampled %>%
  mutate(pop = chm,
         `system:index` = as.character(dplyr::row_number()),
         ssbid = as.character(dplyr::row_number())) %>%
  dplyr::select(region, vegClimZoneLab, pop, `system:index`, ssbid)

# Buffer each sampled point out to a 20x20m square, approximating a polygon
# (matching the original's own population-polygon shape).
vaatmark_poly <- st_geometry(vaatmark_points) %>%
  lapply(create_square) %>%
  st_sfc(crs = st_crs(vaatmark_points))

popvaatmark <- st_sf(st_drop_geometry(vaatmark_points), geometry = vaatmark_poly)


# ===========================================================
# STAGE 7: Combine reference (X100), forest (X0) and population heights.
# ===========================================================

popskogvaatmark <- popvaatmark %>%
  left_join(skog_region_bioclim, by = c("vegClimZoneLab", "region"))

vaatmarkHts <- popskogvaatmark %>%
  as_tibble() %>%
  dplyr::select(-geometry) %>%
  left_join(refvaatmark, by = c("vegClimZoneLab", "region")) %>%
  gather(type, height, ref, pop, skog) %>%
  group_by(`system:index`, region, vegClimZoneLab, type) %>%
  summarise(height = mean(height), .groups = "drop") %>%
  pivot_wider(values_from = height, names_from = type) %>%
  # Population height below reference = automatically "good" condition -
  # inherits the reference height so the rescaled value is 1.
  mutate(pop = ifelse(pop < ref, ref, pop)) %>%
  drop_na(pop, ref)

vaatmarkHts$region         <- factor(vaatmarkHts$region,         levels = regionlvl)
vaatmarkHts$vegClimZoneLab <- factor(vaatmarkHts$vegClimZoneLab, levels = vegclimzonelvl)


# ===========================================================
# STAGE 8: Sigmoid scaling and polygon-level indicator values.
# ===========================================================

scaleSigmoid <- function(variable) {
  refLow  <- min(variable)
  refHigh <- max(variable)
  indicator_LowHigh <- (variable - refLow) / (refHigh - refLow)
  indicator_LowHigh[indicator_LowHigh < 0] <- 0
  indicator_LowHigh[indicator_LowHigh > 1] <- 1
  indicator_sigmoid <- 100.68 * (1 - exp(-5 * (indicator_LowHigh)^2.5)) / 100
  round(indicator_sigmoid, 4)
}

vaatmarkIndexPoly <- vaatmarkHts %>%
  gather(type, height, ref, pop, skog) %>%
  group_by(`system:index`) %>%
  mutate(index = scaleSigmoid(height)) %>%
  mutate(index = 1 - index) %>%  # shorter vegetation = better condition
  filter(type == "pop") %>%
  dplyr::select(-type, -height) %>%
  left_join(vaatmarkHts %>% dplyr::select("system:index", pop, ref, skog),
             by = "system:index") %>%
  left_join(popvaatmark %>% st_drop_geometry() %>% dplyr::select("system:index", ssbid),
             by = "system:index")

vaatmarkIndexPolySpat <- popvaatmark %>%
  dplyr::select("system:index") %>%
  left_join(vaatmarkIndexPoly, by = "system:index") %>%
  filter(!is.na(index)) %>%
  st_transform(st_crs(regions))

cat("Wetland polygons with a valid indicator value:", nrow(vaatmarkIndexPolySpat), "\n")


# ===========================================================
# STAGE 9: Strata-level aggregation (area-weighted mean per HEA).
# ===========================================================

vaatmarkIndexStrata <- bioClimReg %>%
  st_join(vaatmarkIndexPolySpat %>% mutate(area = as.numeric(st_area(geometry))),
          st_intersects, largest = TRUE) %>%
  group_by(ID) %>%
  summarise(across(c(pop, ref, skog, index), ~ weighted.mean(.x, w = area, na.rm = TRUE))) %>%
  as_tibble() %>%
  dplyr::select(-geometry)

write_csv(vaatmarkIndexStrata, file.path(results_dir, "vaatmarkIndexStrata_OpenSource.csv"))


# ===========================================================
# STAGE 10: 50km grid-level aggregation.
# [OPEN SOURCE] Grid dissolved from Kartverket's open StatistiskRutenett1km
# product (build_ssb_grids.R) instead of NINA's official 10km/50km product.
# ea_spread() comes from GitHub NINAnor/eaTools (installed package name is
# actually "ecTools" - a rename the repo's current master doesn't reflect;
# pin the commit before that rename to keep the exact function this
# pipeline needs: remotes::install_github("NINAnor/eaTools@e9480b4b977f4a15597e64f649e43b2dd8dc4bfc")).
# ===========================================================

ssb50km_path <- file.path(spatial_dir, "ssb50km.shp")
vaatmarkIndexGrid <- NULL
if (!file.exists(ssb50km_path)) {
  message("Skipping 50km grid-level aggregation: ", ssb50km_path, " not found.\n",
          "Run build_ssb_grids.R to produce it.")
} else {
  ssb50km <- st_read(ssb50km_path, quiet = TRUE) %>%
    mutate(SSBID = as.numeric(SSBID) / 1000) %>%
    st_transform(st_crs(regions))

  vaatmarkIndexGrid <- ecTools::ea_spread(
    indicator_data = vaatmarkIndexPolySpat,
    indicator      = index,
    regions        = ssb50km,
    groups         = SSBID,
    threshold      = 1
  ) %>%
    mutate(index = w_mean, ssbid = ID) %>%
    dplyr::select(ssbid, index, sd)

  st_write(vaatmarkIndexGrid, file.path(results_dir, "vaatmark_index_grid_OpenSource.shp"),
           delete_dsn = TRUE, quiet = TRUE)
}


# ===========================================================
# STAGE 11: Regional-level aggregation.
# ===========================================================

vaatmarkHeightsRegion <- regions %>%
  st_join(vaatmarkIndexPolySpat) %>%
  as_tibble() %>%
  drop_na(index) %>%
  mutate(region = region.x) %>%
  dplyr::select(-region.x, -region.y) %>%
  group_by(region) %>%
  summarise(pop_mean  = mean(pop),
            skog_mean = mean(skog),
            ref_mean  = mean(ref),
            sd_ref    = sd(ref),
            sd_pop    = sd(pop),
            n         = n())

vaatmarkIndexRegion <- ecTools::ea_spread(
  indicator_data = vaatmarkIndexPolySpat,
  indicator      = index,
  regions        = regions,
  groups         = region,
  threshold      = 1
) %>%
  mutate(index = w_mean, region = ID) %>%
  dplyr::select(region, index, sd) %>%
  left_join(vaatmarkHeightsRegion, by = "region")

st_write(vaatmarkIndexRegion, file.path(results_dir, "vaatmark_index_region_OpenSource.shp"),
         delete_dsn = TRUE, quiet = TRUE)


# ===========================================================
# STAGE 12: Results - reference heights.
# ===========================================================

refvaatmarknr <- refvaatmark
if (!is.null(vaatmarkrawtab)) refvaatmarknr <- refvaatmarknr %>% left_join(vaatmarkrawtab, by = c("region", "vegClimZoneLab"))

ref_plot <- refvaatmarknr %>%
  ggplot(aes(x = vegClimZoneLab, y = ref)) +
  {if (!is.null(vaatmarkrawtab)) geom_text(aes(label = n), hjust = -.5)} +
  geom_bar(stat = "identity") +
  theme_bw(base_size = 12) +
  coord_flip() +
  scale_y_continuous(expand = expansion(mult = c(0, 0.5), add = c(.1, 0))) +
  facet_wrap(. ~ region) +
  labs(title = "Reference vegetation height in wetland ecosystems",
       y = "Reference vegetation height (m)", x = " ")

ggsave(file.path(results_dir, "NO_GJEN_001_wetland_refHeights_OpenSource.png"),
       ref_plot, width = 9, height = 6, dpi = 300, bg = "white")
print(ref_plot)


# ===========================================================
# STAGE 13: Results - maps at HEA (strata), grid and regional level.
# ===========================================================

theme_legend_1 <- theme(legend.key.size   = unit(0.25, "cm"),
                         legend.key.height = unit(0.25, "cm"),
                         legend.key.width  = unit(0.25, "cm"),
                         legend.title      = element_text(size = 6),
                         legend.text       = element_text(size = 6),
                         legend.position   = c(0.8, 0.4))

makeStrataHeightMap <- function(data, var, title, limits) {
  bioClimReg %>%
    left_join(data, by = "ID") %>%
    mutate(response = .data[[var]]) %>%
    ggplot() +
    geom_sf(aes(fill = response), color = NA) +
    scale_fill_gradientn(colors = viridis::viridis(10), limits = limits,
                         oob = scales::squish, name = "Veg ht (m)") +
    ggtitle(title) + theme_void() +
    theme(plot.title = element_text(size = 9)) + theme_legend_1
}

makeStrataIndicatorMap <- function(data, title) {
  bioClimReg %>%
    left_join(data, by = "ID") %>%
    ggplot() +
    geom_sf(aes(fill = index), color = NA) +
    scale_fill_gradientn(colors = brewer.pal(10, "Spectral"), limits = c(0, 1), name = "Index") +
    ggtitle(title) + theme_void() +
    theme(plot.title = element_text(size = 9)) + theme_legend_1
}

v1 <- makeStrataIndicatorMap(vaatmarkIndexStrata, "Våtmark scaled indicator")
v2 <- makeStrataHeightMap(vaatmarkIndexStrata, "ref", "Våtmark reference height", c(0, 5))
v3 <- makeStrataHeightMap(vaatmarkIndexStrata, "pop", "Våtmark vegetation height", c(0, 5))

strataHeightPlot <- grid.arrange(v1, v2, v3, ncol = 3, widths = c(1, 1, 1),
                                  padding = unit(0, "line"), newpage = TRUE)
ggsave(file.path(results_dir, "NO_GJEN_001_wetland_strataMap_OpenSource.png"),
       strataHeightPlot, width = 11, height = 5, dpi = 300, bg = "white")

if (!is.null(vaatmarkIndexGrid)) {
  grid_map <- vaatmarkIndexGrid %>%
    ggplot() +
    geom_sf(aes(fill = index), color = NA) +
    geom_sf(data = regions, fill = NA, linewidth = 0.5) +
    scale_fill_gradientn(colors = brewer.pal(10, "Spectral"), limits = c(0, 1), name = "Index") +
    theme_void() +
    theme(legend.position = c(0.7, 0.4), plot.title = element_text(size = 10)) +
    ggtitle("Våtmark gjengroing condition (50km grid)")

  ggsave(file.path(results_dir, "NO_GJEN_001_wetland_gridMap_OpenSource.png"),
         grid_map, width = 7, height = 7, dpi = 300, bg = "white")
  print(grid_map)
} else {
  message("Skipping grid-level map: vaatmarkIndexGrid was not computed (see Stage 10).")
}

vaatmarkTable <- vaatmarkIndexRegion %>%
  as_tibble() %>%
  mutate(sd = (sd_pop / pop_mean) * index)

region_forest <- regions %>%
  left_join(vaatmarkTable, by = "region") %>%
  mutate(lowError = index - sd, upError = pmin(index + sd, 1)) %>%
  ggplot(aes(y = region, x = index)) +
  geom_point() +
  geom_segment(aes(yend = region, x = lowError, xend = upError)) +
  coord_cartesian(xlim = c(0, 1)) +
  geom_vline(xintercept = c(0, 1)) +
  labs(x = "Tilstandsverdi", title = "Regional wetland gjengroing indicator") +
  theme(axis.title.y = element_blank())

ggsave(file.path(results_dir, "NO_GJEN_001_wetland_regionForest_OpenSource.png"),
       region_forest, width = 6, height = 5, dpi = 300, bg = "white")
print(region_forest)

region_map <- regions %>%
  left_join(vaatmarkTable, by = "region") %>%
  ggplot() +
  geom_sf(aes(fill = index)) +
  scale_fill_gradientn(colors = brewer.pal(10, "Spectral"), limits = c(0, 1)) +
  ggtitle("Våtmark - regional level") +
  theme_void() +
  theme(legend.position = c(0.7, 0.4))

ggsave(file.path(results_dir, "NO_GJEN_001_wetland_regionMap_OpenSource.png"),
       region_map, width = 7, height = 7, dpi = 300, bg = "white")
print(region_map)

# Uniform 5-class condition map, matching NO_FUNC_003's "Tilstand" style so
# every indicator's regional map reads the same way.
condition_breaks <- c(0, 0.2, 0.4, 0.6, 0.8, 1)
condition_labels <- c("Svært dårlig", "Dårlig", "Moderat", "God", "Svært god")
condition_colors <- setNames(
  c("#d7191c", "#fdae61", "#ffffbf", "#a6d96a", "#1a9641"),
  condition_labels
)

# Clip to Norway's real coastline (fjords/islands) for display only - matches
# NO_FUNC_003's map style. GJEN_001/CON_001 previously drew regions.shp raw,
# giving a visibly smoother/more generalized coastline than FUNC_003's map -
# purely a rendering difference, not a data/value one. Done here, AFTER
# vaatmarkIndexRegion is already computed from the unclipped regions, so
# this can't perturb the aggregation itself - it only affects what
# geometry the final map draws.
outline_path <- file.path(spatial_dir, "outlineOfNorway_EPSG25833.shp")
nor <- st_read(outline_path, quiet = TRUE) %>% st_transform(st_crs(vaatmarkIndexRegion))
vaatmarkIndexRegion_clipped <- st_intersection(vaatmarkIndexRegion, nor)

condition_map_dat <- vaatmarkIndexRegion_clipped %>%
  mutate(condition = cut(index, breaks = condition_breaks,
                          labels = condition_labels, include.lowest = TRUE))

label_pts <- condition_map_dat %>%
  st_point_on_surface() %>%
  mutate(label = ifelse(
    is.na(index),
    paste0(region, "\nIngen data"),
    sprintf("%s\n%.3f (n=%d)", region, index, n)
  ))

dummy_xy <- st_coordinates(st_point_on_surface(condition_map_dat[1, ]))
legend_dummy <- data.frame(
  condition = factor(condition_labels, levels = condition_labels),
  x = dummy_xy[1, "X"],
  y = dummy_xy[1, "Y"]
)

wetland_condition_map <- ggplot() +
  geom_sf(data = condition_map_dat, aes(fill = condition), color = "black", linewidth = 0.4,
          show.legend = FALSE) +
  geom_point(data = legend_dummy, aes(x = x, y = y, fill = condition),
             shape = 22, size = 6, color = "black", alpha = 0) +
  geom_sf_label(data = label_pts, aes(label = label), size = 3, lineheight = 0.9,
                fill = "white", color = "black", label.size = 0.3) +
  scale_fill_manual(
    values   = condition_colors,
    name     = "Tilstand",
    limits   = condition_labels,
    drop     = FALSE,
    na.value = "grey80",
    guide    = guide_legend(override.aes = list(alpha = 1))
  ) +
  labs(
    title   = "NO_GJEN_001 indikator Våtmark (Open Source)",
    caption = "Areal-vektet gjennomsnittlig indeksverdi per region. God tilstand ≥ 0.6."
  ) +
  theme_void() +
  theme(
    plot.title      = element_text(face = "bold", size = 16, hjust = 0.5),
    plot.caption    = element_text(size = 8, hjust = 0.5),
    legend.position = "right"
  )

ggsave(
  filename = file.path(results_dir, "NO_GJEN_001_wetland_map_OpenSource.png"),
  plot     = wetland_condition_map,
  width    = 11, height = 10, dpi = 300, bg = "white"
)
print(wetland_condition_map)


# ===========================================================
# STAGE 14: Export.
# Polygon-level, grid-level (if computed) and regional-level wetland
# indicator tables. Suffixed "_OpenSource" throughout so outputs never
# collide with the gated-original pipeline's own exports.
# ===========================================================

vaatmarkIndexPolySpat %>%
  mutate(id = `system:index`, vegZn = vegClimZoneLab) %>%
  dplyr::select(-`system:index`, -vegClimZoneLab, -any_of("elevation")) %>%
  st_write(file.path(results_dir, "NO_GJEN_001_wetland_index_OpenSource.shp"), delete_dsn = TRUE, quiet = TRUE)

vaatmarkIndexPolySpat %>%
  st_drop_geometry() %>%
  write_csv(file.path(results_dir, "NO_GJEN_001_wetland_index_OpenSource.csv"))

if (!is.null(vaatmarkIndexGrid)) {
  vaatmarkIndexGrid %>%
    st_write(file.path(results_dir, "NO_GJEN_001_wetland_index_grid_OpenSource.shp"), delete_dsn = TRUE, quiet = TRUE)
}

vaatmarkIndexRegion %>%
  st_write(file.path(results_dir, "NO_GJEN_001_wetland_index_region_OpenSource.shp"), delete_dsn = TRUE, quiet = TRUE)

cat("Done. Open-source wetland indicator exported to:\n",
    " - ", file.path(results_dir, "NO_GJEN_001_wetland_index_OpenSource.shp"), "\n",
    " - ", file.path(results_dir, "NO_GJEN_001_wetland_index_OpenSource.csv"), "\n",
    " - ", file.path(results_dir, "NO_GJEN_001_wetland_index_region_OpenSource.shp"), "\n", sep = "")
