# ============================================================
# Produces two things the main pipeline actually needs to run, not just a
# one-time historical check (originally written to verify LiDAR coverage;
# still true, but no longer this script's only purpose):
#
#   1. dtm1_tile_footprint.gpkg - REQUIRED regardless of AR5/AR50 choice.
#      Every CHM extraction and building-filter call in
#      NO_GJEN_001_wetland_pipeline_OpenSource.R defaults to reading this
#      file to batch sample points by DTM1 tile. Run this once before a
#      first cold-cache run of Stage 4/5/6, even if you have AR5 access
#      and never touch the AR50 fallback below.
#   2. ar50_myr_national.gpkg - the open AR50 fallback for Stage 6's
#      wetland population source, used automatically if AR5 isn't found.
#
# Method: uses AR50 (NIBIO, NLOD-open) as an open stand-in for "where are
# the wetlands" (Nasjonalt grunnkart itself is gated, Norge Digitalt
# license), then checks it against Kartverket's open 1m LiDAR (DTM1/DOM1)
# tile grid.
#
# Produces (in ../Data/OpenS_data/):
#   ar50_myr_national.gpkg    - all AR50 arealtype==60 (Myr/wetland) polygons
#                                nationally (343,744 polygons, ~20,046 km^2
#                                as of the 2026-07-21 run)
#   dtm1_tile_footprint.gpkg  - the 2033 individual DTM1 tile polygons
#   dtm1_coverage_union.gpkg  - those tiles dissolved into one coverage
#                                layer (this one is just the
#                                original coverage-check output, not read
#                                by anything downstream)
#
# Result as of 2026-07-21: 100.0% of AR50 wetland area (by precise
# intersection, not just a bounding-box/touches check) falls within the
# open 1m LiDAR footprint.
#
# Sources:
#   AR50: NIBIO per-county GML downloads, no auth -
#         https://kart8.nibio.no/uttak_Download/ar50/<county>_4258_ar50_gml.zip
#         (the county codes used are listed below). Layer
#         "ArealressursFlate", field "arealtype".
#   DTM1: Kartverket's atom feed, https://nedlasting.geonorge.no/geonorge/
#         ATOM/hoydedata/datasett/DTM1.atom - per-tile GeoTIFF, no auth.
#         Only the tile footprints (georss:polygon) are used here, not the
#         actual elevation rasters - this script checks *coverage*, not CHM.
# ============================================================

library(sf)
library(dplyr)
library(xml2)

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  tried <- tryCatch({ setwd(dirname(sys.frame(1)$ofile)); TRUE }, error = function(e) FALSE)
  if (!tried) message("Note: keeping current working directory (", getwd(), ").")
}

out_dir     <- file.path("..", "Data", "OpenS_data")
staging_dir <- file.path("..", "Data", "spatial", "_staging_ar50_dtm1")
if (!dir.exists(out_dir))     dir.create(out_dir, recursive = TRUE)
if (!dir.exists(staging_dir)) dir.create(staging_dir, recursive = TRUE)


# ===========================================================
# STAGE A: Download AR50 (all 15 counties) and extract Myr (wetland) polygons
# ===========================================================

ar50_urls <- c(
  Oslo = "https://kart8.nibio.no/uttak_Download/ar50/03_4258_ar50_gml.zip",
  Vestland = "https://kart8.nibio.no/uttak_Download/ar50/46_4258_ar50_gml.zip",
  Trondelag = "https://kart8.nibio.no/uttak_Download/ar50/50_4258_ar50_gml.zip",
  Nordland = "https://kart8.nibio.no/uttak_Download/ar50/18_4258_ar50_gml.zip",
  Telemark = "https://kart8.nibio.no/uttak_Download/ar50/40_4258_ar50_gml.zip",
  Agder = "https://kart8.nibio.no/uttak_Download/ar50/42_4258_ar50_gml.zip",
  MoreOgRomsdal = "https://kart8.nibio.no/uttak_Download/ar50/15_4258_ar50_gml.zip",
  Finnmark = "https://kart8.nibio.no/uttak_Download/ar50/56_4258_ar50_gml.zip",
  Troms = "https://kart8.nibio.no/uttak_Download/ar50/55_4258_ar50_gml.zip",
  Ostfold = "https://kart8.nibio.no/uttak_Download/ar50/31_4258_ar50_gml.zip",
  Innlandet = "https://kart8.nibio.no/uttak_Download/ar50/34_4258_ar50_gml.zip",
  Vestfold = "https://kart8.nibio.no/uttak_Download/ar50/39_4258_ar50_gml.zip",
  Rogaland = "https://kart8.nibio.no/uttak_Download/ar50/11_4258_ar50_gml.zip",
  Akershus = "https://kart8.nibio.no/uttak_Download/ar50/32_4258_ar50_gml.zip",
  Buskerud = "https://kart8.nibio.no/uttak_Download/ar50/33_4258_ar50_gml.zip"
)

read_myr <- function(name, url) {
  extract_dir <- file.path(staging_dir, "ar50", name)
  if (!dir.exists(extract_dir)) {
    zip_path <- file.path(staging_dir, "ar50", paste0(name, ".zip"))
    dir.create(dirname(zip_path), recursive = TRUE, showWarnings = FALSE)
    download.file(url, zip_path, mode = "wb", quiet = TRUE)
    unzip(zip_path, exdir = extract_dir)
    file.remove(zip_path)
  }
  gml_file <- list.files(extract_dir, pattern = "\\.gml$", full.names = TRUE)[1]
  d <- st_read(gml_file, layer = "ArealressursFlate", quiet = TRUE)
  d <- d[as.character(d$arealtype) == "60", ]
  if (nrow(d) == 0) return(NULL)
  geom_col <- attr(d, "sf_column")
  if (geom_col != "geometry") {
    names(d)[names(d) == geom_col] <- "geometry"
    st_geometry(d) <- "geometry"
  }
  d %>% st_transform(25833) %>% st_make_valid() %>% dplyr::select(geometry)
}

cat("Downloading AR50 for 15 counties and extracting Myr polygons...\n")
myr_list <- list()
for (name in names(ar50_urls)) {
  t0 <- Sys.time()
  m <- tryCatch(read_myr(name, ar50_urls[[name]]),
                error = function(e) { cat("ERROR", name, ":", conditionMessage(e), "\n"); NULL })
  if (!is.null(m)) {
    myr_list[[name]] <- m
    cat(" ", name, ":", nrow(m), "myr polygons,", round(as.numeric(Sys.time() - t0), 1), "sec\n")
  }
}

myr_all <- do.call(rbind, myr_list)
myr_all$area_m2 <- as.numeric(st_area(myr_all))
total_myr_area_km2 <- sum(myr_all$area_m2) / 1e6
cat("\nTotal Myr (wetland, arealtype=60) polygons nationally:", nrow(myr_all), "\n")
cat("Total Myr area (km^2):", round(total_myr_area_km2, 0), "\n")

st_write(myr_all, file.path(out_dir, "ar50_myr_national.gpkg"), delete_dsn = TRUE, quiet = TRUE)


# ===========================================================
# STAGE B: Build the DTM1 tile footprint from Kartverket's atom feed
# ===========================================================

cat("\nFetching DTM1 tile feed...\n")
dtm1_feed_url <- "https://nedlasting.geonorge.no/geonorge/ATOM/hoydedata/datasett/DTM1.atom"
feed_path <- file.path(staging_dir, "dtm1_feed.xml")
download.file(dtm1_feed_url, feed_path, mode = "wb", quiet = TRUE)

doc <- read_xml(feed_path)
entries <- xml_find_all(doc, ".//d1:entry", xml_ns(doc))
cat("DTM1 tiles in feed:", length(entries), "\n")

# tile_id (e.g. "33-107-122") is kept so a DTM1/DOM1 download URL can be
# reconstructed later for any tile: both datasets share the identical
# naming scheme, just swapping the DTM1/DOM1 folder in the URL - confirmed
# against a real DOM1 feed entry on 2026-07-22, not assumed.
get_tile <- function(entry) {
  poly_node <- xml_find_first(entry, ".//georss:polygon", c(georss = "http://www.georss.org/georss"))
  if (is.na(poly_node)) return(NULL)
  nums <- as.numeric(strsplit(trimws(xml_text(poly_node)), "\\s+")[[1]])
  lats <- nums[seq(1, length(nums), 2)]
  lons <- nums[seq(2, length(nums), 2)]
  m <- cbind(lons, lats)
  if (!identical(m[1, ], m[nrow(m), ])) m <- rbind(m, m[1, ])
  id_url <- xml_text(xml_find_first(entry, ".//d1:id"))
  tile_id <- sub("\\.tif$", "", basename(id_url))
  list(tile_id = tile_id, poly = st_polygon(list(m)))
}

tiles <- lapply(entries, get_tile)
valid <- !sapply(tiles, is.null)
tiles <- tiles[valid]
tiles_sf <- st_sf(
  tile_id  = sapply(tiles, `[[`, "tile_id"),
  geometry = st_sfc(lapply(tiles, `[[`, "poly"), crs = 4326)
)
tiles_25833 <- st_transform(tiles_sf, 25833)
st_write(tiles_25833, file.path(out_dir, "dtm1_tile_footprint.gpkg"), delete_dsn = TRUE, quiet = TRUE)

cat("Dissolving tile footprint into one coverage layer...\n")
coverage_union <- st_union(tiles_25833)
st_write(st_sf(geometry = coverage_union), file.path(out_dir, "dtm1_coverage_union.gpkg"),
         delete_dsn = TRUE, quiet = TRUE)
cat("Total DTM1 tile coverage area (km^2):", round(as.numeric(st_area(coverage_union)) / 1e6, 0), "\n")


# ===========================================================
# STAGE C: Coverage check - what fraction of AR50 wetland area falls
# within the open 1m LiDAR footprint?
# ===========================================================

cat("\nChecking intersection of AR50 wetlands with DTM1 coverage...\n")
touches <- st_intersects(myr_all, coverage_union, sparse = FALSE)[, 1]
partial <- myr_all[touches, ]
inter <- suppressWarnings(st_intersection(st_geometry(partial), coverage_union))
inter_area_km2 <- sum(as.numeric(st_area(inter))) / 1e6

cat("\n=== RESULTS ===\n")
cat("Myr polygons with any LiDAR overlap:", sum(touches), "/", nrow(myr_all),
    sprintf("(%.1f%%)\n", 100 * sum(touches) / nrow(myr_all)))
cat("Precise overlapping Myr area (km^2):", round(inter_area_km2, 0),
    sprintf("(%.1f%% of total Myr area)\n", 100 * inter_area_km2 / total_myr_area_km2))

unlink(staging_dir, recursive = TRUE)
cat("\nDone. Outputs saved to", normalizePath(out_dir), "\n")
