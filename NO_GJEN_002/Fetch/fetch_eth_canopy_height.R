# ============================================================
# NO_GJEN_002 - fetch ETH Zurich's Global Canopy Height (2020) values for
# every national NiN wetland polygon, as a PROVISIONAL stand-in for the
# real Meta-model-on-orthophoto canopy height (`meta_media`) while
# orthophoto access (Norge Digitalt / Norkart) is still pending.
#
# WHY THIS EXISTS, AND WHY IT IS NOT THE REAL PIPELINE: Meta's own
# HighResCanopyHeight model (this project's `compressed_SSLhuge_aerial`
# checkpoint) was trained on 50cm aerial imagery - Meta's own
# documentation notes quality degrades on lower-resolution *satellite*
# imagery even at resolutions much finer than Sentinel-2's 10m, so
# feeding it Sentinel-2 directly would be scientifically meaningless,
# not just "coarser." This script therefore uses a DIFFERENT,
# purpose-built model instead: Lang et al. 2022/2023 ("A high-resolution
# canopy height model of the Earth"), which fuses GEDI spaceborne LiDAR
# with Sentinel-2 imagery specifically, at 10m resolution, globally, for
# 2020 - a legitimate model for this input resolution, not a misuse of
# the wrong tool. Two real caveats, documented not hidden: (1) ETH's
# product measures a different underlying signal (GEDI-trained canopy
# TOP height) than Meta's aerial-LiDAR-trained model, so values are not
# expected to be numerically continuous with an eventual real
# orthophoto-based run; (2) GEDI-based products are documented to
# perform worse at SHORT vegetation heights than tall forest canopy -
# precisely the regime this indicator cares about most (woody
# encroachment into open wetland). Every output row is tagged with a
# `chm_source` column identifying it as the ETH/Sentinel-2 stand-in,
# never silently blended with a real orthophoto-derived value.
#
# NO GOOGLE EARTH ENGINE NEEDED. An earlier version of this script used
# rgee against the GEE asset `users/nlang/ETH_GlobalCanopyHeight_2020_
# 10m_v1` - abandoned in favour of this direct approach once found
# (2026-08-27): the same dataset is distributed as Cloud-Optimized
# GeoTIFF (COG) tiles via ETH's own public Nextcloud share (linked
# directly from the dataset's DOI/Research Collection record - CC-BY-4.0,
# https://doi.org/10.3929/ethz-b-000609802), streamable via GDAL's
# /vsicurl/ exactly like this project already streams Kartverket's
# DTM1/DOM1 LiDAR tiles elsewhere (see NO_GJEN_001/R/elevation_source.R)
# - no authentication, no Python, no OAuth. Confirmed working directly:
# a real windowed read returned a sensible mean canopy height for a
# known-forested test point in southern Norway.
#
# TILE GRID: 3x3 degree COG tiles, named
# ETH_GlobalCanopyHeight_10m_2020_N{lat}E{lon}_Map.tif where {lat}/{lon}
# are the tile's SW-corner degree values (multiples of 3) - confirmed
# directly via the share's own WebDAV directory listing, not assumed
# from documentation. The share token below is itself the public,
# citable access point for this dataset (not a secret credential) -
# same status as any other public download URL used elsewhere in this
# project.
#
# FULL TILE DOWNLOAD, NOT /vsicurl/ STREAMING - a real timing finding,
# not a style choice: an earlier version of this script streamed each
# tile via /vsicurl/ and ran terra::extract() directly against the
# remote COG. Confirmed too slow to be practical (2026-08-27) - CPU time
# grew much slower than wall-clock time while running, consistent with
# per-polygon network-round-trip latency dominating (terra::extract()
# issues many small reads per polygon, and this dataset's server doesn't
# appear to make that cheap the way Kartverket's DTM1/DOM1 tiles do
# elsewhere in this project) - over 25 minutes on just the first of 20
# tiles, killed before completion. Each tile is ~285MB (confirmed via a
# real HEAD request, not estimated) - downloading it once, then running
# terra::extract() against the LOCAL file, removes per-polygon network
# latency from the hot loop entirely. Tiles are cached in Data/OpenS_
# data/eth_tiles_cache/ (gitignored in the eventual migration copy - large,
# fully re-fetchable, same treatment as every other large raw download in
# this project) so a re-run after a code fix doesn't re-download.
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

nin_gdb_dir <- file.path("..", "Data", "OpenS_data", "nin_data")
out_dir     <- file.path("..", "Data", "OpenS_data")
out_path    <- file.path(out_dir, "eth_canopy_height_national.csv")

if (file.exists(out_path)) {
  cat("Already present:", normalizePath(out_path), "\n")
  cat("Delete it first to force a re-fetch.\n")
  quit(save = "no", status = 0)
}

gdb_path <- list.files(nin_gdb_dir, pattern = "\\.gdb$", full.names = TRUE)[1]
if (is.na(gdb_path)) {
  stop("Missing national NiN geodatabase in ", nin_gdb_dir, " - run fetch_nin_data.R first.")
}

cat("Loading national NiN wetland ('våtmark') polygons...\n")
nin <- st_read(gdb_path, layer = "naturtyper_nin_omr", quiet = TRUE)
wetland <- nin %>%
  rename(geometry = SHAPE) %>%
  st_set_geometry("geometry") %>%
  filter(hovedøkosystem == "våtmark") %>%
  st_make_valid() %>%
  filter(!st_is_empty(.)) %>%
  st_transform(4326)  # ETH tiles are EPSG:4326 - match before tiling/extraction
cat("  ", nrow(wetland), "national wetland polygons.\n")

# ---------------------------------------------------------------
# Share credentials + tile fetch/cache helpers.
# ---------------------------------------------------------------
ETH_SHARE_TOKEN <- "cO8or7iOe5dT2Rt"
tile_cache_dir <- file.path(out_dir, "eth_tiles_cache")
if (!dir.exists(tile_cache_dir)) dir.create(tile_cache_dir, recursive = TRUE)

eth_tile_name <- function(tile_lat, tile_lon) {
  lat_str <- sprintf("N%02d", tile_lat)
  lon_str <- if (tile_lon >= 0) sprintf("E%03d", tile_lon) else sprintf("W%03d", -tile_lon)
  paste0("ETH_GlobalCanopyHeight_10m_2020_", lat_str, lon_str, "_Map.tif")
}

#' Download one tile fully to the local cache (skips if already present -
#' the cache is what makes a re-run after a code fix cheap). Returns the
#' local file path, or NULL if the tile genuinely doesn't exist on the
#' server (a real, expected case for tiles that are mostly/entirely
#' ocean with no corresponding data file).
fetch_tile_cached <- function(tile_lat, tile_lon) {
  fname <- eth_tile_name(tile_lat, tile_lon)
  local_path <- file.path(tile_cache_dir, fname)
  if (file.exists(local_path)) return(local_path)

  # Credential embedded via standard user:pass@host URL syntax (libcurl,
  # R's default download method, handles this natively as HTTP Basic
  # Auth - no extra package needed).
  url <- paste0("https://", ETH_SHARE_TOKEN, ":@libdrive.ethz.ch/public.php/webdav/3deg_cogs/", fname)
  tmp_path <- paste0(local_path, ".part")
  status <- tryCatch(
    download.file(url, tmp_path, mode = "wb", quiet = TRUE, method = "libcurl"),
    error = function(e) { message("  download error: ", conditionMessage(e)); NA }
  )
  if (!identical(status, 0L) || !file.exists(tmp_path) || file.size(tmp_path) < 1e6) {
    if (file.exists(tmp_path)) file.remove(tmp_path)
    return(NULL)
  }
  file.rename(tmp_path, local_path)
  local_path
}

# Assign each polygon to its 3-degree tile using its CENTROID (small NiN
# wetland polygons essentially never span a 3-degree/~330km boundary -
# unlike Kartverket's 1km DTM1 tiles elsewhere in this project, where
# per-point tile assignment matters at a much finer grain).
centroids <- st_coordinates(st_centroid(st_geometry(wetland)))
wetland$.tile_lat <- floor(centroids[, 2] / 3) * 3
wetland$.tile_lon <- floor(centroids[, 1] / 3) * 3
wetland$.row_id   <- seq_len(nrow(wetland))

tile_keys <- unique(paste(wetland$.tile_lat, wetland$.tile_lon))
cat("Polygons span", length(tile_keys), "distinct 3-degree ETH tiles.\n")

# ---------------------------------------------------------------
# Per-tile zonal median extraction. Downloads each tile fully to the
# local cache ONCE (see header - full download beat /vsicurl/ streaming
# decisively on real timing), then runs terra::extract() with a median
# function across every polygon assigned to that tile, against the
# LOCAL file - no per-polygon network round-trips.
# ---------------------------------------------------------------
results <- vector("list", length(tile_keys))
t0 <- Sys.time()

for (i in seq_along(tile_keys)) {
  parts <- as.numeric(strsplit(tile_keys[i], " ")[[1]])
  tlat <- parts[1]; tlon <- parts[2]
  sub_idx <- which(wetland$.tile_lat == tlat & wetland$.tile_lon == tlon)
  sub_polys <- wetland[sub_idx, ]

  cat("  tile", i, "/", length(tile_keys), "( N", tlat, "E", tlon, ") -",
      length(sub_idx), "polygons - downloading (or using cache)...\n")
  t_dl <- Sys.time()
  local_tif <- fetch_tile_cached(tlat, tlon)
  cat("    [timing] download/cache check:",
      round(as.numeric(difftime(Sys.time(), t_dl, units = "secs")), 1), "sec\n")

  r <- if (!is.null(local_tif)) tryCatch(rast(local_tif), error = function(e) NULL) else NULL

  if (is.null(r)) {
    cat("  tile", i, "/", length(tile_keys), "( N", tlat, "E", tlon,
        ") - not available (likely ocean/no-data tile) - skipping",
        length(sub_idx), "polygons.\n")
    results[[i]] <- data.frame(.row_id = sub_polys$.row_id,
                                eth_chm_median = NA_real_, eth_chm_n = 0L)
    next
  }

  ext_vals <- tryCatch(
    terra::extract(r, vect(sub_polys), fun = median, na.rm = TRUE, ID = FALSE),
    error = function(e) NULL
  )
  cnt_vals <- tryCatch(
    terra::extract(r, vect(sub_polys), fun = function(x, ...) sum(!is.na(x)), ID = FALSE),
    error = function(e) NULL
  )

  if (is.null(ext_vals)) {
    results[[i]] <- data.frame(.row_id = sub_polys$.row_id,
                                eth_chm_median = NA_real_, eth_chm_n = 0L)
  } else {
    results[[i]] <- data.frame(
      .row_id        = sub_polys$.row_id,
      eth_chm_median = ext_vals[[1]],
      eth_chm_n      = if (!is.null(cnt_vals)) cnt_vals[[1]] else NA_integer_
    )
  }

  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  eta <- elapsed / i * (length(tile_keys) - i)
  cat("  tile", i, "/", length(tile_keys), "( N", tlat, "E", tlon, ") -",
      length(sub_idx), "polygons - [timing]", round(elapsed, 1), "sec elapsed, ETA",
      round(eta / 60, 1), "min\n")
}

extracted <- bind_rows(results)

out <- wetland %>%
  st_drop_geometry() %>%
  dplyr::select(.row_id, identifikasjon_lokalId) %>%
  left_join(extracted, by = ".row_id") %>%
  dplyr::select(-.row_id) %>%
  mutate(chm_source = "eth_sentinel2_2020_PROVISIONAL")

write.csv(out, out_path, row.names = FALSE)

cat("\n=== Summary ===\n")
cat("Polygons with a valid zonal median (non-NA):", sum(!is.na(out$eth_chm_median)),
    "of", nrow(out), "\n")
cat("Polygons with 3 or fewer 10m pixels (statistically thin estimate):",
    sum(out$eth_chm_n <= 3, na.rm = TRUE), "\n")
cat("Saved to:", normalizePath(out_path), "\n")
cat("\nREMINDER: chm_source == 'eth_sentinel2_2020_PROVISIONAL' throughout -\n")
cat("this is a stand-in for the real Meta-model-on-orthophoto value, not a\n")
cat("final result. See this script's header for the two real caveats.\n")
