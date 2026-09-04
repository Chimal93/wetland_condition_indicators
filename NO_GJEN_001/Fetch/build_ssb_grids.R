# ============================================================
# One-time utility: build the SSB 10km and 50km statistical grids used by
# NO_GJEN_001_wetland_pipeline.R's Stage 10 (grid-level map), by dissolving
# the official 1km grid ("StatistiskRutenett1km", Kartverket's Basisdata
# distribution of SSB's grid - confirmed open, no auth) up to 10km/50km.
#
# Why not download the 10km/50km product directly: Kartverket's automated
# Basisdata pipeline (nedlasting.geonorge.no) only carries 250m/1km/5km of
# this grid; 10km/50km exist (open, NLOD-licensed) but only through SSB's
# own kart.ssb.no portal/WFS, and the exact WFS dataset id for the plain
# (non-statistic-attributed) grid at those sizes could not be found.
#
# This works because SSB's grid is nested/aligned to a common origin: every
# 1km cell's corner coordinates are exact multiples of 1000m, which are
# also exact multiples of 10000m/50000m at the relevant grid lines - so
# flooring each cell's centroid to the nearest 10km/50km origin and
# dissolving by that key reproduces the native 10km/50km grid exactly.
#
# NOTE: the resulting SSBID column is a locally-generated row index, not
# SSB's own canonical grid numbering - this only matters if you need to
# cross-reference a specific cell against an external SSB table by ID. For
# NO_GJEN_001_wetland_pipeline.R's use (eaTools::ea_spread(groups = SSBID)
# for spatial aggregation only), any unique per-cell id is sufficient.
#
# Source data: Kartverket's Basisdata distribution of SSB's statistical
# grid, "StatistiskRutenett1km", GML format, EPSG:25833, nationwide -
# confirmed open/no-auth (unlike the 10km/50km sizes - see above). Metadata
# record (uuid 122cf146-90a9-4557-96ea-e639fb28d896, for the 250m sibling
# product which shares the same Basisdata naming convention):
#   https://kartkatalog.geonorge.no/metadata/statistisk-rutenett-250m/122cf146-90a9-4557-96ea-e639fb28d896
# Direct download (~35 MB zip, downloaded below if not already present):
#   https://nedlasting.geonorge.no/geonorge/Basisdata/StatistiskRutenett1km/GML/Basisdata_0000_Norge_25833_StatistiskRutenett1km_GML.zip
# ============================================================

library(sf)
library(dplyr)

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  tried <- tryCatch({ setwd(dirname(sys.frame(1)$ofile)); TRUE }, error = function(e) FALSE)
  if (!tried) message("Note: keeping current working directory (", getwd(), ").")
}

# Writes into OpenS_data (the canonical, actively-refetched copy used by
# NO_GJEN_001_wetland_pipeline.R) - not Data/spatial, which keeps its own
# frozen 2026-07-21 snapshot for diffing against future reruns.
spatial_dir  <- file.path("..", "Data", "OpenS_data")
staging_dir  <- file.path(spatial_dir, "_ssb_download")
grid1km_url  <- paste0(
  "https://nedlasting.geonorge.no/geonorge/Basisdata/StatistiskRutenett1km/",
  "GML/Basisdata_0000_Norge_25833_StatistiskRutenett1km_GML.zip"
)
zip_path <- file.path(staging_dir, "rutenett1km.zip")
gml_path <- file.path(staging_dir, "Basisdata_0000_Norge_25833_StatistiskRutenett1km_GML.gml")

if (!file.exists(gml_path)) {
  if (!dir.exists(staging_dir)) dir.create(staging_dir, recursive = TRUE)
  cat("Downloading nationwide 1km grid from Kartverket's Basisdata (~35 MB):\n  ",
      grid1km_url, "\n", sep = "")
  download.file(grid1km_url, zip_path, mode = "wb", quiet = TRUE)
  unzip(zip_path, exdir = staging_dir)
}

cat("Reading 1km grid (478,640 features expected)...\n")
t0 <- Sys.time()
grid1km <- st_read(gml_path, quiet = TRUE)
cat("Read", nrow(grid1km), "features in", round(as.numeric(Sys.time() - t0), 1), "sec\n")

# The GML source names its geometry column "område" (Norwegian for "area"),
# not "geometry" - normalise so the rest of this script (and st_union() by
# literal column name below) works regardless of the source's naming.
geom_col <- attr(grid1km, "sf_column")
if (geom_col != "geometry") {
  names(grid1km)[names(grid1km) == geom_col] <- "geometry"
  st_geometry(grid1km) <- "geometry"
}

# Centroid coordinates - vectorised, used only to compute which coarser
# cell each 1km square belongs to (not used as the output geometry).
coords <- st_coordinates(st_centroid(st_geometry(grid1km)))

build_grid <- function(cell_size, coords, source) {
  key <- paste0(floor(coords[, 1] / cell_size), "_", floor(coords[, 2] / cell_size))
  out <- source %>%
    mutate(.key = key) %>%
    group_by(.key) %>%
    summarise(geometry = st_union(geometry), .groups = "drop") %>%
    st_sf() %>%
    mutate(SSBID = as.character(dplyr::row_number())) %>%
    dplyr::select(SSBID)
  out
}

cat("Dissolving to 10km grid...\n")
t0 <- Sys.time()
ssb10km <- build_grid(10000, coords, grid1km)
cat("  ->", nrow(ssb10km), "cells in", round(as.numeric(Sys.time() - t0), 1), "sec\n")

cat("Dissolving to 50km grid...\n")
t0 <- Sys.time()
ssb50km <- build_grid(50000, coords, grid1km)
cat("  ->", nrow(ssb50km), "cells in", round(as.numeric(Sys.time() - t0), 1), "sec\n")

st_write(ssb10km, file.path(spatial_dir, "ssb10km.shp"), delete_dsn = TRUE, quiet = TRUE)
st_write(ssb50km, file.path(spatial_dir, "ssb50km.shp"), delete_dsn = TRUE, quiet = TRUE)

cat("\nSaved:\n  ", file.path(spatial_dir, "ssb10km.shp"),
    "\n  ", file.path(spatial_dir, "ssb50km.shp"), "\n", sep = "")

# Remove the ~520 MB staging download (zip + unzipped GML) now that the
# dissolved 10km/50km outputs exist - only those are needed going forward.
unlink(staging_dir, recursive = TRUE)
cat("Removed staging download:", staging_dir, "\n")
