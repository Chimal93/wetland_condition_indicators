# ============================================================
# Orthophoto -> per-AOI tile provider.
#
# Reads RGB tiles for Meta's canopy-height model from a national
# orthophoto raster (a Cloud-Optimized GeoTIFF or VRT), either a local
# file or a remote COG read over HTTP range requests. The path and any
# credentials are read ONLY from environment variables - never hardcoded
# here, never passed as a literal in a script or committed to git - so
# this file carries no information about where that raster actually came
# from, or who serves it.
#
# Expected env vars:
#   ORTHOPHOTO_SOURCE_PATH - GeoTIFF/COG/VRT covering the area(s) of
#                            interest, in any CRS (the AOI is reprojected
#                            to match it internally). Either a local path,
#                            or any GDAL virtual path - notably
#                            "/vsicurl/https://..." for a remote COG.
#                            (ORTHOPHOTO_LOCAL_PATH is still accepted, for
#                            backward compatibility with the local-only
#                            version of this file.)
#   ORTHOPHOTO_SOURCE_USERPWD - OPTIONAL "user:password", only needed when
#                            the remote source requires HTTP Basic auth.
#                            Passed to GDAL as GDAL_HTTP_USERPWD.
# Set once (PowerShell): setx ORTHOPHOTO_SOURCE_PATH "/vsicurl/https://..."
#
# REMOTE SOURCES ARE THE EXPECTED CASE, not an edge case: a national
# sub-metre orthophoto is far too large to hold locally (the 50cm one
# this was first pointed at is ~4.17 TB), so it is never downloaded -
# GDAL fetches only the byte ranges covering each tile window. This is
# the same /vsicurl/ streaming technique already used elsewhere in this
# project for ETH canopy-height and Kartverket DTM1/DOM1 tiles.
#
# STRICTLY READ-ONLY ON THE SOURCE. The orthophoto is not ours and must
# never be modified. That holds structurally, not just by convention:
# terra::rast() opens read-only (nothing here ever opens it in update
# mode), crop() reads a window into a NEW raster, and writeRaster() only
# ever targets `output_dir`. For a remote source it is stronger again -
# GDAL's /vsicurl/ handler is read-only by design, issuing only HTTP
# GET/HEAD range requests, so no write path to the file exists at all.
# The output_dir guard below additionally refuses to write anywhere near
# a local source file.
#
# Tiling logic mirrors NO_GJEN_002.qmd's own fn.getOrtoImages() (section
# 7.1.4): tiles are aligned to a fixed grid derived from tile_size *
# resolution (not just cropped to the AOI's raw bbox), so tile boundaries
# are reproducible and match the size the model expects (256x256px).
# The original reads tiles from a live WMS one at a time; this reads them
# as windowed crops from the local raster instead - same output shape,
# different source.
# ============================================================

library(sf)
library(terra)

#' Cut aligned, fixed-size tiles from a local orthophoto raster over one
#' area-of-interest polygon, and write each as a small standalone GeoTIFF
#' (matching the format NO_GJEN_002.qmd's Python NorwayDataset expects:
#' a directory of individual 3-band .tif files).
#'
#' @param aoi a single sf polygon (one row).
#' @param id_field a label used in output tile filenames (e.g. the AOI's
#'   NiN polygon id).
#' @param output_dir directory to write tiles into (created if missing).
#' @param tile_size tile side length in pixels. Default 256 (fixed by the
#'   model - do not change without re-checking model compatibility).
#' @param resolution tile pixel size in metres. Default 0.5 (the qmd
#'   found 0.5m to perform better than 1m for this model).
#' @return character vector of written tile file paths (empty if none).
get_orthophoto_tiles <- function(aoi, id_field, output_dir,
                                  tile_size = 256, resolution = 0.5) {
  src_path <- Sys.getenv("ORTHOPHOTO_SOURCE_PATH")
  if (src_path == "") src_path <- Sys.getenv("ORTHOPHOTO_LOCAL_PATH")
  if (src_path == "") {
    stop("ORTHOPHOTO_SOURCE_PATH environment variable is not set.\n",
         "Set it once with (PowerShell): setx ORTHOPHOTO_SOURCE_PATH \"/vsicurl/https://...\"\n",
         "Never pass the path as a literal in a script.")
  }

  # A GDAL virtual path (/vsicurl/, /vsizip/, ...) or a bare URL is not a
  # file on disk, so file.exists() is meaningless for it - checking it
  # would reject every remote source. Validate those by actually opening
  # them instead, and keep the cheap existence check for local paths.
  is_remote <- grepl("^/vsi|^https?://", src_path)
  if (!is_remote && !file.exists(src_path)) {
    stop("ORTHOPHOTO_SOURCE_PATH points to a file that doesn't exist: ", src_path)
  }

  if (is_remote) {
    userpwd <- Sys.getenv("ORTHOPHOTO_SOURCE_USERPWD")
    if (userpwd != "") Sys.setenv(GDAL_HTTP_USERPWD = userpwd)
    # Without this GDAL tries to list the remote "directory" on every
    # open, which is slow-to-hanging on an HTTP endpoint; the cache keeps
    # already-fetched byte ranges warm across the many small tile reads
    # this function makes.
    Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR")
    Sys.setenv(VSI_CACHE = "TRUE")
    Sys.setenv(VSI_CACHE_SIZE = "25000000")
  }

  # Belt-and-braces for the LOCAL-source case: never write tiles into the
  # directory holding the source raster. The source doesn't belong to this
  # project and must stay untouched; this makes a mistaken output_dir fail
  # loudly instead of scattering files next to (or over) it.
  if (!is_remote) {
    src_dir <- normalizePath(dirname(src_path), winslash = "/", mustWork = FALSE)
    out_abs <- normalizePath(output_dir, winslash = "/", mustWork = FALSE)
    if (identical(src_dir, out_abs) || startsWith(paste0(out_abs, "/"), paste0(src_dir, "/"))) {
      stop("Refusing to write tiles into the orthophoto source's own directory (", src_dir, ").\n",
           "The source raster is read-only and must not be written next to or over. ",
           "Choose an output_dir outside it.")
    }
  }

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  src <- tryCatch(terra::rast(src_path), error = function(e) {
    stop("Could not open the orthophoto source (", src_path, "): ", conditionMessage(e),
         if (is_remote) "\nFor an authenticated remote source, check ORTHOPHOTO_SOURCE_USERPWD." else "")
  })

  if (!st_is_valid(aoi)) aoi <- st_make_valid(aoi)
  aoi_t <- st_transform(aoi, crs(src))
  geom_extent <- st_bbox(aoi_t)

  tile_width_m  <- tile_size * resolution
  tile_height_m <- tile_size * resolution

  x_min <- floor(geom_extent["xmin"] / tile_width_m)  * tile_width_m
  y_min <- floor(geom_extent["ymin"] / tile_height_m) * tile_height_m
  x_max <- ceiling(geom_extent["xmax"] / tile_width_m)  * tile_width_m
  y_max <- ceiling(geom_extent["ymax"] / tile_height_m) * tile_height_m

  x_tiles <- ceiling((x_max - x_min) / tile_width_m)
  y_tiles <- ceiling((y_max - y_min) / tile_height_m)

  # Build the aligned grid covering the AOI's bounding box, then keep only
  # the windows that ACTUALLY TOUCH the polygon.
  #
  # WHY THIS MATTERS (measured 2026-09-04): tiles are aligned to the bbox,
  # but a wetland polygon is rarely bbox-shaped. Cutting every bbox window
  # meant running the model over ~3x more ground than the polygons occupy
  # (20 test polygons = 137 ha of polygon, but 256 tiles = 419 ha of tile;
  # ~33% efficient). Those extra tiles contribute NO pixels to the zonal
  # statistic, so dropping them changes results not at all - it just skips
  # the expensive part: a network range-read per tile, then a model
  # forward pass per tile.
  #
  # The test is done as ONE vectorised spatial query over the whole grid
  # rather than per-window, and BEFORE terra::crop(), so a skipped tile
  # costs no network I/O at all.
  #
  # tile_index is assigned over the FULL grid (not just the kept windows),
  # in the same j-inner order the original nested loop used, so a given
  # ground position keeps a stable filename regardless of which tiles were
  # skipped.
  grid <- expand.grid(j = 0:(y_tiles - 1), i = 0:(x_tiles - 1))
  grid$tile_index <- seq_len(nrow(grid))
  grid$xmin <- x_min + grid$i * tile_width_m
  grid$xmax <- grid$xmin + tile_width_m
  grid$ymin <- y_min + grid$j * tile_height_m
  grid$ymax <- grid$ymin + tile_height_m

  wins_sfc <- st_sfc(lapply(seq_len(nrow(grid)), function(k) {
    st_polygon(list(cbind(
      c(grid$xmin[k], grid$xmax[k], grid$xmax[k], grid$xmin[k], grid$xmin[k]),
      c(grid$ymin[k], grid$ymin[k], grid$ymax[k], grid$ymax[k], grid$ymin[k]))))
  }), crs = st_crs(aoi_t))
  keep <- lengths(st_intersects(wins_sfc, st_geometry(aoi_t))) > 0
  grid <- grid[keep, , drop = FALSE]

  written <- character(0)
  for (k in seq_len(nrow(grid))) {
    {
      xmin <- grid$xmin[k]; xmax <- grid$xmax[k]
      ymin <- grid$ymin[k]; ymax <- grid$ymax[k]
      tile_index <- grid$tile_index[k]

      win <- terra::ext(xmin, xmax, ymin, ymax)
      tile <- tryCatch(terra::crop(src, win), error = function(e) NULL)

      # Still skip windows that intersect the polygon but carry no imagery
      # (e.g. a no-data gap in the mosaic) - the intersection test above
      # cannot know that.
      if (is.null(tile) || terra::ncell(tile) == 0 || all(is.na(terra::values(tile)))) {
        next
      }

      # Force exact tile_size x tile_size at the target resolution,
      # matching the WMS GetMap call's WIDTH/HEIGHT/resolution behaviour.
      target <- terra::rast(win, resolution = resolution, crs = crs(src))
      tile_r <- terra::resample(tile, target, method = "bilinear")

      # Write 8-bit, NOT the float that resample() promotes to. Two real
      # reasons, both about matching Meta's model rather than preference:
      # (1) its pipeline reads imagery with PIL + TF.to_tensor(), which
      # maps uint8 [0,255] onto the [0,1] range the model was trained on -
      # a float tile silently skips that scaling; (2) PIL cannot read
      # multi-band float TIFFs at all (mode "F" is single-band), so a
      # float tile isn't even loadable downstream. The source orthophoto
      # is 8-bit; the float only ever appeared as a resampling artifact,
      # so nothing real is lost. Bilinear is a weighted mean of
      # neighbours, so it cannot overshoot outside 0-255 the way cubic
      # could - the round-trip back to 8-bit is safe.
      out_path <- file.path(output_dir, paste0(id_field, "_", tile_index, ".tif"))
      terra::writeRaster(tile_r, out_path, overwrite = TRUE,
                          datatype = "INT1U",
                          gdal = c("COMPRESS=NONE"))
      written <- c(written, out_path)
    }
  }
  written
}
