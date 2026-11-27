# ============================================================
# VAAT-NDVI-01 - fetch REAL MODIS NDVI (MOD13Q1 v061) for the national NiN
# wetland population, replacing the missing bespoke-GEE-export
# (data/NDVI_MODIS/modis_ndvi_ts_2000_2022.csv) that VAAT-NDVI-01_wetland_
# pipeline.R's Stage 5 has always stopped on. NO GOOGLE EARTH ENGINE
# INVOLVED - built entirely from public NASA infrastructure.
#
# SCOPE (user's explicit call, 2026-08-28): extend all the way to today,
# not just NINA's own mountain-indicator precedent (2000-2019) - "go all
# or nothing." Growing season only (Jun-Sep, matching the mountain
# indicator's own methodology - see project memory), 16-day MOD13Q1
# composites, for however many years that span actually has data.
#
# REAL INFRASTRUCTURE FINDING (2026-08-28, confirmed not assumed): NASA's
# legacy LP DAAC data pool (e4ftl01.cr.usgs.gov - what most tutorials
# still reference) was FULLY RETIRED 2025-06-30. All MODIS data is now
# served via NASA's Earthdata Cloud (AWS-hosted). This script queries
# NASA's own CMR (Common Metadata Repository) granule-search API to find
# real current download URLs - never guesses/constructs them.
#
# TILE GRID: MODIS sinusoidal, 6 tiles cover Norway's mainland -
# h18v01, h18v02, h18v03, h19v01, h19v02, h19v03 - computed directly via
# R/sf with the exact MODIS sinusoidal projection definition
# (+proj=sinu +R=6371007.181), densely sampled across Norway's real
# extent, not read off a lookup table or estimated from corners alone.
#
# AUTH: requires EARTHDATA_TOKEN in a local .Renviron file (a free NASA
# Earthdata Login bearer token, generated at urs.earthdata.nasa.gov ->
# profile -> "Generate Token" - 60-day validity, will need periodic
# regeneration). Never hardcoded - same convention as this project's
# other credentials (e.g. FIELD_DTM_URL).
#
# DOWNLOAD MECHANISM: shells out to curl.exe via system2(), NOT R's own
# download.file() - confirmed the hard way (2026-08-28) that download.
# file(method="libcurl") silently produces a subtly wrong/corrupted file
# across this specific bearer-token-then-redirect-to-presigned-URL chain
# (wrong byte count, no error raised - only caught because GDAL then
# failed to open the file). curl.exe with -L (follow redirects) produces
# byte-for-byte correct files, confirmed via exact size match against
# CMR's own reported granule size.
#
# OUTPUT SCHEMA matches exactly what VAAT-NDVI-01_wetland_pipeline.R's
# Stage 5 already expects (confirmed by reading that script's clean_ndvi()
# function directly, not assumed): columns `id` (NiN polygon
# identifikasjon_lokalId), `mean` (raw NDVI, RAW x10000 integer scale -
# the pipeline itself divides by 10000, so this script must NOT
# pre-scale), `date` (the 16-day composite's start date).
# ============================================================

library(sf)
library(terra)
library(dplyr)

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

token <- Sys.getenv("EARTHDATA_TOKEN")
if (!nzchar(token)) {
  stop("EARTHDATA_TOKEN not found. Generate a free bearer token at ",
       "https://urs.earthdata.nasa.gov (profile -> Generate Token) and ",
       "put it in a local .Renviron file as EARTHDATA_TOKEN=<token>.")
}

data_dir  <- file.path("..", "data")
out_dir   <- file.path(data_dir, "NDVI_MODIS")
cache_dir <- file.path(data_dir, "OpenS_data", "modis_tiles_cache")
if (!dir.exists(out_dir))   dir.create(out_dir, recursive = TRUE)
if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)

TILES <- c("h18v01", "h18v02", "h18v03", "h19v01", "h19v02", "h19v03")
# Growing-season 16-day composite start-DOYs (Jun-Sep window) - MOD13Q1's
# fixed 23-period annual schedule starts on DOY 1,17,33,...,353; these 8
# periods are the ones falling within Jun-Sep.
GROWING_SEASON_DOYS <- c(145, 161, 177, 193, 209, 225, 241, 257)
YEAR_START <- 2000
YEAR_END   <- as.integer(format(Sys.Date(), "%Y"))
# Quick single-year validation mode: set NDVI_TEST_YEAR to restrict the
# whole run to one year, before committing to the full multi-decade fetch.
test_year <- Sys.getenv("NDVI_TEST_YEAR", unset = "")
if (nzchar(test_year)) {
  YEAR_START <- YEAR_END <- as.integer(test_year)
  cat("NDVI_TEST_YEAR set - restricting to year", YEAR_START, "only.\n")
}
out_path <- file.path(out_dir, if (nzchar(test_year)) paste0("modis_ndvi_ts_TEST_", test_year, ".csv") else "modis_ndvi_ts_national.csv")

cat("MODIS NDVI fetch:", YEAR_START, "-", YEAR_END, "( growing season only ), tiles:",
    paste(TILES, collapse = ", "), "\n")

# ---------------------------------------------------------------
# National wetland population + per-tile assignment (by centroid - NiN
# wetland polygons are far smaller than a 231m MODIS pixel, let alone a
# ~1112km tile, so centroid assignment is unambiguous).
# ---------------------------------------------------------------
nin_gdb_dir <- file.path(data_dir, "nin_data")
gdb_path <- list.files(nin_gdb_dir, pattern = "\\.gdb$", full.names = TRUE)[1]
if (is.na(gdb_path)) stop("Missing national NiN geodatabase in ", nin_gdb_dir, ".")

cat("Loading national NiN wetland polygons...\n")
nin <- st_read(gdb_path, layer = "naturtyper_nin_omr", quiet = TRUE)
wetland <- nin %>%
  rename(geometry = SHAPE) %>%
  st_set_geometry("geometry") %>%
  filter(hovedøkosystem == "våtmark") %>%
  st_make_valid() %>%
  filter(!st_is_empty(.)) %>%
  rename(id = identifikasjon_lokalId) %>%
  dplyr::select(id)
cat("  ", nrow(wetland), "national wetland polygons.\n")

modis_sinu <- "+proj=sinu +lon_0=0 +x_0=0 +y_0=0 +R=6371007.181 +units=m +no_defs"
wetland_sinu <- st_transform(wetland, modis_sinu)

# CENTROID POINTS, not polygon boundaries - a real, measured performance
# finding (2026-08-28): terra::extract() against full polygon geometries
# took 9+ minutes and never finished for a single ~6,900-polygon tile
# (the same class of problem CON_001 hit with vertex-heavy polygons -
# NiN wetland polygons can have very complex boundaries). Switching to
# point extraction at each polygon's own centroid dropped this to 0.2
# seconds for the SAME tile, covering 95% of polygons (vs. only 10% via
# a rasterize()+zonal() alternative also tested, which loses any polygon
# that doesn't "win" a pixel's single zone-ID assignment). Methodologically
# reasonable here specifically because MODIS's 250m pixels are frequently
# LARGER than individual wetland polygons - centroid value and a true
# area-weighted mean converge to nearly the same number in that regime,
# unlike VAAT-GJEN-01/CON_001's own point-sampling (there, a deliberate
# stratified design choice; here, a direct, measured performance
# necessity forced by MODIS's coarse resolution relative to polygon size).
centroid_geom <- st_centroid(st_geometry(wetland_sinu))
centroids_xy <- st_coordinates(centroid_geom)

TILE_SIZE <- 1111950.519667
XMIN <- -20015109.354
YMAX <- 10007554.677
h <- floor((centroids_xy[, 1] - XMIN) / TILE_SIZE)
v <- floor((YMAX - centroids_xy[, 2]) / TILE_SIZE)

wetland_pts <- st_sf(id = wetland_sinu$id, tile = sprintf("h%02dv%02d", h, v),
                     geometry = centroid_geom) %>%
  filter(tile %in% TILES)
cat("  ", nrow(wetland_pts), "polygons (as centroids) fall within the 6 Norway tiles.\n")

# ---------------------------------------------------------------
# CMR granule search - one query per year, Jun 1 - Sep 30, Norway bbox.
# Filters results down to exactly our 6 tiles (bounding_box search can
# return neighbouring tiles that merely clip the box edge).
# ---------------------------------------------------------------
cmr_search_year <- function(year) {
  url <- paste0(
    "https://cmr.earthdata.nasa.gov/search/granules.json",
    "?short_name=MOD13Q1&version=061",
    "&bounding_box=4,57,32,71",
    "&temporal=", year, "-06-01T00:00:00Z,", year, "-09-30T23:59:59Z",
    "&page_size=100"
  )
  tmp <- tempfile()
  status <- system2("curl", c("-s", "-o", shQuote(tmp), shQuote(url)))
  if (status != 0 || !file.exists(tmp)) return(NULL)
  js <- tryCatch(jsonlite::fromJSON(tmp, simplifyVector = FALSE), error = function(e) NULL)
  file.remove(tmp)
  if (is.null(js) || length(js$feed$entry) == 0) return(NULL)

  rows <- lapply(js$feed$entry, function(g) {
    hv <- regmatches(g$title, regexpr("h[0-9]{2}v[0-9]{2}", g$title))
    if (length(hv) == 0 || !(hv %in% TILES)) return(NULL)
    doy <- as.integer(substr(regmatches(g$title, regexpr("A[0-9]{7}", g$title)), 6, 8))
    yr  <- as.integer(substr(regmatches(g$title, regexpr("A[0-9]{7}", g$title)), 2, 5))
    https_url <- Filter(function(l) grepl("\\.hdf$", l$href) && grepl("^https://data\\.lpdaac", l$href), g$links)
    if (length(https_url) == 0) return(NULL)
    data.frame(title = g$title, tile = hv, year = yr, doy = doy, url = https_url[[1]]$href,
               stringsAsFactors = FALSE)
  })
  bind_rows(rows[!sapply(rows, is.null)])
}

cat("\nQuerying CMR for real granule URLs,", YEAR_START, "-", YEAR_END, "...\n")
all_granules <- list()
for (yr in YEAR_START:YEAR_END) {
  g <- cmr_search_year(yr)
  if (!is.null(g)) {
    g <- g %>% filter(doy %in% GROWING_SEASON_DOYS)
    all_granules[[as.character(yr)]] <- g
    cat("  ", yr, ":", nrow(g), "growing-season granules across all tiles\n")
  } else {
    cat("  ", yr, ": no granules found\n")
  }
}
granules <- bind_rows(all_granules)
cat("\nTotal granules to process:", nrow(granules), "\n")
if (nrow(granules) == 0) stop("No granules found - check CMR query / date range.")

# ---------------------------------------------------------------
# Download (cached) + zonal-mean extraction, one granule at a time.
# ---------------------------------------------------------------
download_granule_cached <- function(url, title) {
  local_path <- file.path(cache_dir, paste0(title, ".hdf"))
  if (file.exists(local_path)) return(local_path)
  tmp_path <- paste0(local_path, ".part")
  status <- system2("curl", c(
    "-s", "-L",
    "-H", shQuote(paste("Authorization: Bearer", token)),
    "-o", shQuote(tmp_path),
    shQuote(url)
  ))
  if (status != 0 || !file.exists(tmp_path) || file.size(tmp_path) < 1e6) {
    if (file.exists(tmp_path)) file.remove(tmp_path)
    return(NULL)
  }
  file.rename(tmp_path, local_path)
  local_path
}

results <- vector("list", nrow(granules))
t0 <- Sys.time()

for (i in seq_len(nrow(granules))) {
  g <- granules[i, ]
  sub_pts <- wetland_pts[wetland_pts$tile == g$tile, ]
  if (nrow(sub_pts) == 0) next

  local_hdf <- download_granule_cached(g$url, g$title)
  if (is.null(local_hdf)) {
    cat("  [", i, "/", nrow(granules), "]", g$title, "- DOWNLOAD FAILED, skipping\n")
    next
  }

  ndvi_sub <- tryCatch({
    subs <- terra::describe(local_hdf, sds = TRUE)
    row <- subs[grepl("NDVI", subs$var, ignore.case = TRUE) & !grepl("reliab|quality", subs$var, ignore.case = TRUE), ]
    # raw = TRUE: MOD13Q1's internal scale_factor (10000) uses the MODIS
    # convention (real = raw / scale_factor), but GDAL's HDF4 driver applies
    # it as a CF-style multiplier (real = raw * scale_factor) by default,
    # inflating every value ~10000x. raw=TRUE bypasses that auto-scoff so we
    # get the native -2000..10000 integers, matching what clean_ndvi() expects.
    rast(row$name[1], raw = TRUE)
  }, error = function(e) NULL)

  if (is.null(ndvi_sub)) {
    cat("  [", i, "/", nrow(granules), "]", g$title, "- COULD NOT READ NDVI SUBDATASET, skipping\n")
    next
  }

  # Point extraction at centroids, not polygon zonal stats - see the
  # wetland_pts construction comment above for why (a real, measured
  # 9min-vs-0.2sec performance finding, not a style preference).
  ext_vals <- tryCatch(
    terra::extract(ndvi_sub, vect(sub_pts), ID = FALSE),
    error = function(e) NULL
  )
  if (!is.null(ext_vals)) {
    composite_date <- as.Date(paste(g$year, g$doy), format = "%Y %j")
    results[[i]] <- data.frame(
      id   = sub_pts$id,
      mean = ext_vals[[1]],   # RAW x10000 scale - matches the real pipeline's own expected input
      date = composite_date
    )
  }

  if (i %% 20 == 0 || i == nrow(granules)) {
    elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    eta <- elapsed / i * (nrow(granules) - i)
    cat("  [", i, "/", nrow(granules), "] - [timing]", round(elapsed / 60, 1),
        "min elapsed, ETA", round(eta / 60, 1), "min\n")
  }
}

out <- bind_rows(results) %>% filter(!is.na(mean))
write.csv(out, out_path, row.names = FALSE)

cat("\n=== Summary ===\n")
cat("Total rows written:", nrow(out), "\n")
cat("Distinct polygons with at least one value:", length(unique(out$id)), "\n")
cat("Year range covered:", paste(range(format(out$date, "%Y")), collapse = " - "), "\n")
cat("Saved to:", normalizePath(out_path), "\n")
