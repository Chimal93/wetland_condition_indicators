# ============================================================
# Fetch OpenStreetMap building footprints for Norway - the open substitute
# for FKB-Bygning (gated behind Norge Digitalt) used to mask buildings out
# of the CHM before measuring vegetation height, per the original
# methodology ("remove buildings, and what remains is vegetation").
#
# Uses the osmextract package: downloads Geofabrik's Norway .osm.pbf
# extract (cached locally by osmextract itself) and queries just the
# building polygons via GDAL's OSM driver, rather than loading every
# OSM feature (roads, land use, etc.) for the whole country.
#
# Output: ../Data/OpenS_data/osm_buildings_national.gpkg
#
# License: ODbL (OpenStreetMap contributors) - open, attribution required
# if this dataset is redistributed/published, not just used internally.
# ============================================================

library(sf)
library(osmextract)

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  tried <- tryCatch({ setwd(dirname(sys.frame(1)$ofile)); TRUE }, error = function(e) FALSE)
  if (!tried) message("Note: keeping current working directory (", getwd(), ").")
}

out_dir  <- file.path("..", "Data", "OpenS_data")
out_path <- file.path(out_dir, "osm_buildings_national.gpkg")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

cat("Downloading/querying Norway OSM extract for building polygons ",
    "(this downloads a national .pbf the first time - can take a while)...\n", sep = "")

t0 <- Sys.time()
buildings <- oe_get(
  place = "Norway",
  layer = "multipolygons",
  extra_tags = "building",
  query = "SELECT building, geometry FROM multipolygons WHERE building IS NOT NULL",
  quiet = FALSE
)
cat("Fetched", nrow(buildings), "building polygons in",
    round(as.numeric(Sys.time() - t0), 1), "sec\n")

buildings <- st_transform(buildings, 25833)
buildings <- st_make_valid(buildings)

st_write(buildings, out_path, delete_dsn = TRUE, quiet = TRUE)
cat("Saved:", out_path, "\n")
