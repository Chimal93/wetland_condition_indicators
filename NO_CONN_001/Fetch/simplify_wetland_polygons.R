# ============================================================
# NO_CONN_001 - vectorize mire polygons (Bakkestuen raster + NiN
# fallback) and write a SIMPLIFIED version to Data/wetland_map_
# simplified/, feeding the certified distance computation below.
#
# WHY THIS IS A SEPARATE SCRIPT: an earlier unsimplified regional run
# was killed after ~44.5 CPU-hours stuck on nearest-neighbour distance
# calculation for 327,622 raster-derived polygons - never finished, on
# the SMALLEST of the 5 regions. Root cause: raster-to-vector conversion
# at 10m resolution produces very vertex-heavy "staircase" polygon
# boundaries (visually confirmed on a real test section, not just
# theorised), and exact polygon-to-polygon distance calculation cost
# scales with vertex count, not just polygon count. Vectorization
# itself was NOT the bottleneck (~82 min for all of Sørlandet) - only
# the distance step was. So it makes sense to decouple them: do the
# (comparatively fast) vectorize+simplify step once per region and
# cache it here, so future experiments with a redesigned, faster
# nearest-neighbour algorithm don't need to repeat it.
#
# SIMPLIFICATION TOLERANCE: 12m (~matches the raster's own 10m
# resolution). Visually verified, not just asserted: overview shape is
# indistinguishable at this tolerance; the close-up on the single most
# complex polygon in a real Sørlandet test section went from 328 to 91
# vertices (72% reduction) with no visible change to the true boundary
# beyond removing pixel-grid staircase artifacts. Across that whole
# 252-polygon section: 6,226 -> 2,242 vertices (64% reduction).
#
# THIS SCRIPT DOES NOT COMPUTE DISTANCES. It only vectorizes and
# simplifies, and writes the result for reuse. The nearest-neighbour
# redesign itself is a separate, not-yet-started step.
# ============================================================

library(terra)
library(sf)
library(dplyr)

terraOptions(memfrac = 0.4, todisk = TRUE)

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

wetland_tif <- file.path("..", "Data", "wetland_map_source", "MyrMod2Rv.tif")
nin_gdb_dir <- file.path("..", "Data", "nin_data")
out_dir     <- file.path("..", "Data", "wetland_map_simplified")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

MIRE_THRESHOLD <- 800
WETLAND_MAP_NORTH_LIMIT_Y <- 7101702  # EPSG:25833 northing where the Bakkestuen raster's real coverage ends (~63.5-64.0N) - confirmed from the raster's own extent, despite its "nationwide" filename
REGION_BUFFER_M <- 10000
SIMPLIFY_TOLERANCE_M <- 12

# TILING (added 2026-08-12): a single-shot crop+vectorize of a whole
# region crashed with "std::bad_alloc" for Midt-Norge (1.07B cells) and
# Østlandet (1.48B cells) - confirmed a real out-of-memory crash, not a
# hang (distinct from the earlier nearest-neighbour-distance problem).
# NOT simply a raw-cell-count issue: Vestlandet (1.35B cells, BIGGER
# than Midt-Norge) succeeded in one shot, so the trigger is more likely
# tied to patch density/complexity within specific sub-areas than total
# size alone. Fix: process in small tiles (well under any size that's
# actually failed or succeeded so far, so this isn't just barely
# dodging the observed threshold), simplify each tile immediately
# (cheap - ~12-18 sec even for 300k+ polygons, confirmed by the 5
# regions already run), then re-merge polygons that got split across a
# tile seam. This also means memory use stays roughly constant
# regardless of region size, rather than scaling with it.
TILE_SIZE_M <- 20000

region_name <- Sys.getenv("CONNECTIVITY_REGION", unset = "")
if (!nzchar(region_name)) stop("Set CONNECTIVITY_REGION to one of: Nord-Norge, Midt-Norge, Vestlandet, Østlandet, Sørlandet")

regionlvl <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
regions_all <- st_read(file.path("..", "Data", "spatial", "regions.shp"), quiet = TRUE)
regions_all$region[regions_all$id == 3] <- "Østlandet"
regions_all$region[regions_all$id == 5] <- "Sørlandet"
regions_all <- regions_all %>% mutate(region = factor(region, levels = regionlvl)) %>% st_transform(25833)
region_true_boundary <- regions_all %>% filter(region == region_name)
if (nrow(region_true_boundary) == 0) stop("Unknown CONNECTIVITY_REGION: '", region_name, "'")

region_buffered_poly <- st_buffer(region_true_boundary, REGION_BUFFER_M)
bb <- st_bbox(region_buffered_poly)
target_extent <- ext(bb["xmin"], bb["xmax"], bb["ymin"], bb["ymax"])
cat("Region:", region_name, "- buffered bounding box:", as.vector(target_extent), "\n")

# ---------------------------------------------------------------
# Vectorize Bakkestuen raster (skip entirely if wholly north of its
# real coverage, so a purely-northern AOI never wastes time cropping a
# raster that's 100% NA there).
# ---------------------------------------------------------------
aoi_entirely_north <- target_extent[3] >= WETLAND_MAP_NORTH_LIMIT_Y

count_vertices_total <- function(x) {
  if (nrow(x) == 0) return(0L)
  sum(vapply(seq_len(nrow(x)), function(i) nrow(st_coordinates(x[i, ])), integer(1)))
}

if (aoi_entirely_north) {
  cat("Region is entirely north of Bakkestuen's coverage - NiN-only.\n")
  mire_polygons <- st_sf(patch_id = integer(0), source = character(0),
                          geometry = st_sfc(crs = 25833))
  n_vertices_before <- 0L
} else {
  t0 <- Sys.time()
  x_breaks <- seq(target_extent[1], target_extent[2], by = TILE_SIZE_M)
  if (tail(x_breaks, 1) < target_extent[2]) x_breaks <- c(x_breaks, target_extent[2])
  y_breaks <- seq(target_extent[3], target_extent[4], by = TILE_SIZE_M)
  if (tail(y_breaks, 1) < target_extent[4]) y_breaks <- c(y_breaks, target_extent[4])
  n_tiles <- (length(x_breaks) - 1) * (length(y_breaks) - 1)
  cat("Processing in", n_tiles, "tiles of", TILE_SIZE_M / 1000, "km...\n")

  wetland_r_full <- rast(wetland_tif)
  tile_results <- list()
  n_vertices_before <- 0L
  tile_i <- 0

  for (xi in seq_len(length(x_breaks) - 1)) {
    for (yi in seq_len(length(y_breaks) - 1)) {
      tile_i <- tile_i + 1
      tile_ext <- ext(x_breaks[xi], x_breaks[xi + 1], y_breaks[yi], y_breaks[yi + 1])
      tile_r <- tryCatch(crop(wetland_r_full, tile_ext), error = function(e) NULL)
      if (is.null(tile_r)) next  # tile entirely outside the source raster's own extent

      n_mire <- global(tile_r > MIRE_THRESHOLD, "sum", na.rm = TRUE)[1, 1]
      if (is.na(n_mire) || n_mire == 0) next  # empty tile, skip cheaply

      tile_binary <- tile_r > MIRE_THRESHOLD
      tile_binary[tile_binary == 0] <- NA
      tile_patches <- patches(tile_binary, directions = 8)
      tile_polys <- tryCatch(as.polygons(tile_patches, dissolve = TRUE) |> st_as_sf(),
                              error = function(e) {
                                message("  Tile ", tile_i, " failed even at ", TILE_SIZE_M / 1000,
                                        "km - skipping (", conditionMessage(e), "). Consider a smaller TILE_SIZE_M.")
                                NULL
                              })
      if (is.null(tile_polys) || nrow(tile_polys) == 0) next
      names(tile_polys)[1] <- "patch_id"
      tile_polys <- tile_polys %>% filter(!is.na(patch_id))
      if (nrow(tile_polys) == 0) next

      n_vertices_before <- n_vertices_before + count_vertices_total(tile_polys)
      # Simplify immediately, per tile - cheap (confirmed: 12-18 sec even
      # for 300k+ polygons across a whole region) and keeps memory low by
      # not accumulating full-complexity geometries across many tiles.
      tile_polys <- st_simplify(tile_polys, dTolerance = SIMPLIFY_TOLERANCE_M, preserveTopology = TRUE) %>%
        filter(!st_is_empty(.))
      tile_polys$source <- "bakkestuen"
      tile_polys$mire_id <- NULL
      tile_results[[length(tile_results) + 1]] <- tile_polys

      if (tile_i %% 20 == 0 || tile_i == n_tiles) {
        cat("  tile", tile_i, "/", n_tiles, "- running total:",
            sum(vapply(tile_results, nrow, integer(1))), "polygons\n")
      }
    }
  }

  if (length(tile_results) == 0) {
    mire_polygons <- st_sf(patch_id = integer(0), source = character(0),
                            geometry = st_sfc(crs = 25833))
  } else {
    mire_polygons_raw <- bind_rows(tile_results)
    cat("All tiles vectorized+simplified:", nrow(mire_polygons_raw), "fragments. ",
        "[timing] tiled vectorize:", round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "sec\n")

    # Re-merge fragments of the same real patch that landed in different
    # tiles (split exactly at a tile seam). Operates on already-simplified
    # (low-vertex-count) geometry, so this stays cheap even at national
    # scale - confirmed by the same dissolve pattern already used for the
    # NiN fallback data (there: n=628, negligible time).
    if (nrow(mire_polygons_raw) > 1) {
      cat("Re-merging polygons split across tile seams...\n")
      t_merge <- Sys.time()
      mire_polygons <- mire_polygons_raw %>% st_union() %>% st_cast("POLYGON") %>% st_sf() %>%
        transmute(patch_id = row_number(), source = "bakkestuen")
      cat("  [timing] cross-tile merge:", round(as.numeric(difftime(Sys.time(), t_merge, units = "secs")), 1),
          "sec -", nrow(mire_polygons_raw), "fragments ->", nrow(mire_polygons), "merged polygons\n")
    } else {
      mire_polygons <- mire_polygons_raw
    }
  }
}

# ---------------------------------------------------------------
# NiN fallback, north of the limit - dissolves touching NiN polygons
# before use, since NiN's independently-delineated records can
# touch (unlike Bakkestuen's raster-derived patches, which
# never do - patches() merges touching pixels by construction).
# ---------------------------------------------------------------
needs_nin_fallback <- target_extent[4] > WETLAND_MAP_NORTH_LIMIT_Y
if (needs_nin_fallback) {
  cat("Loading NiN wetland fallback...\n")
  nin_gdb <- list.files(nin_gdb_dir, pattern = "\\.gdb$", full.names = TRUE)[1]
  if (is.na(nin_gdb)) stop("NiN gdb not found in ", nin_gdb_dir, " - run fetch_nin_data.R first.")
  nin <- st_read(nin_gdb, layer = "naturtyper_nin_omr", quiet = TRUE)
  nin <- nin %>% rename(geometry = SHAPE) %>% st_set_geometry("geometry")
  nin_wetland <- nin %>%
    rename(hovedoekosystem = hovedøkosystem, identifikasjon_lokalid = identifikasjon_lokalId) %>%
    filter(hovedoekosystem == "våtmark") %>%
    st_transform(25833) %>%
    st_make_valid() %>%
    filter(!st_is_empty(.))

  north_boundary <- ext(max(-100000, target_extent[1]), min(1200000, target_extent[2]),
                         max(WETLAND_MAP_NORTH_LIMIT_Y, target_extent[3]), min(8000000, target_extent[4]))
  nb <- as.vector(north_boundary)
  aoi_box <- st_as_sfc(st_bbox(c(xmin = unname(nb["xmin"]), ymin = unname(nb["ymin"]),
                                  xmax = unname(nb["xmax"]), ymax = unname(nb["ymax"])), crs = 25833))
  nin_wetland <- st_filter(nin_wetland, aoi_box, .predicate = st_intersects)

  if (nrow(nin_wetland) > 0) {
    nin_dissolved <- nin_wetland %>% st_union() %>% st_cast("POLYGON") %>% st_sf()
    nin_polygons <- nin_dissolved %>%
      st_cast("MULTIPOLYGON", warn = FALSE) %>%
      transmute(patch_id = row_number() + 1e6, source = "nin_fallback")
    n_vertices_before <- n_vertices_before + count_vertices_total(nin_polygons)
    mire_polygons <- bind_rows(mire_polygons, nin_polygons)
    cat("NiN fallback polygons added (post-dissolve):", nrow(nin_polygons), "\n")
  }
}
mire_polygons$mire_id <- seq_len(nrow(mire_polygons))

if (nrow(mire_polygons) == 0) stop("No mire polygons found for this region - nothing to simplify.")

# ---------------------------------------------------------------
# Final simplify pass + report the reduction (not just claim it).
# The Bakkestuen portion (if any) was already simplified per-tile above
# - re-simplifying it here at the same tolerance is harmless/idempotent
# (cheap either way). The NiN portion (if any) has NOT been simplified
# yet, so this pass is where that actually happens. n_vertices_before
# was accumulated during the tiled loop + the NiN block above, so it
# correctly reflects BOTH sources' true pre-simplification complexity,
# not just whatever mire_polygons happens to look like at this point.
# ---------------------------------------------------------------
cat("\nFinal simplify pass at", SIMPLIFY_TOLERANCE_M, "m tolerance (", nrow(mire_polygons), "polygons)...\n")
t_simp <- Sys.time()
mire_simplified <- st_simplify(mire_polygons, dTolerance = SIMPLIFY_TOLERANCE_M, preserveTopology = TRUE)
cat("  [timing] final simplify:", round(as.numeric(difftime(Sys.time(), t_simp, units = "secs")), 1), "sec\n")

# st_simplify can occasionally produce empty/degenerate geometries for
# tiny slivers (a real, known behaviour, not assumed) - drop them, and
# report how many, rather than silently pass them downstream.
n_before_drop <- nrow(mire_simplified)
mire_simplified <- mire_simplified %>% filter(!st_is_empty(.))
if (nrow(mire_simplified) < n_before_drop) {
  cat("Dropped", n_before_drop - nrow(mire_simplified), "polygon(s) that became empty after simplification",
      "(tiny slivers below the simplification tolerance).\n")
}

n_vertices_after <- count_vertices_total(mire_simplified)
cat("\n=== Vertex reduction ===\n")
cat("Before:", n_vertices_before, " After:", n_vertices_after,
    " Reduction:", round(100 * (1 - n_vertices_after / n_vertices_before), 1), "%\n")

# ---------------------------------------------------------------
# Output
# ---------------------------------------------------------------
out_path <- file.path(out_dir, paste0("wetland_simplified_", region_name, ".gpkg"))
st_write(mire_simplified, out_path, quiet = TRUE, append = FALSE)
cat("\nWritten to", out_path, "\n")
cat("Final polygon count:", nrow(mire_simplified), "\n")
