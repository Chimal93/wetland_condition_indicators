# ============================================================
# NO_CONN_001 - compute min_infra_distance + kvotient for one region,
# using the already-computed certified min_myr_distance results
# (Data/connectivity_output_simplified/<region>_min_myr_distance_
# certified.gpkg) instead of re-deriving mire polygons from scratch.
#
# This step was NEVER the bottleneck in the whole min_myr_distance saga
# - kept as close to the original methodology as possible: crop LUI to
# the buffered region extent, resample to 10m to match the mire
# raster's own resolution, threshold, vectorize (dissolved), then
# buffer+distance against the certified mire polygons. Tested first on
# the smallest region before committing to full national scale, since
# raster resampling at national extent has been a real source of
# surprises elsewhere in this pipeline (LUI's own 177M-cell grid needed
# disk-backed processing for the same reason - see compute_lui_
# infrastructure_index.R).
#
# After computing kvotient, filters to the TRUE (unbuffered) region
# boundary - the certified min_myr_distance files still contain the full
# 10km-buffered extent (simplify_wetland_polygons.R never filtered this
# out), so combining regions without this filter would double-count
# polygons in the shared buffer zones between adjacent regions.
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

region_name <- Sys.getenv("CONNECTIVITY_REGION", unset = "")
if (!nzchar(region_name)) stop("Set CONNECTIVITY_REGION to one of: Nord-Norge, Midt-Norge, Vestlandet, Østlandet, Sørlandet")

ascii_name <- c(
  "Nord-Norge" = "nord_norge",
  "Midt-Norge" = "midt_norge",
  "Vestlandet" = "vestlandet",
  "Østlandet"  = "ostlandet",
  "Sørlandet"  = "sorlandet"
)[[region_name]]

INFRA_THRESHOLD <- 2
INFRA_BUFFER_M  <- 1000
REGION_BUFFER_M <- 10000
YEAR <- Sys.getenv("CONNECTIVITY_YEAR", unset = "2023")

lui_path <- file.path("..", "Data", "LUI_output", paste0("LUI_", YEAR, ".tif"))
mire_path <- file.path("..", "Data", "connectivity_output_simplified",
                        paste0(ascii_name, "_min_myr_distance_certified.gpkg"))

cat("Region:", region_name, "- year:", YEAR, "\n")
cat("Loading certified mire polygons (includes 10km buffer zone)...\n")
mire_polygons <- st_read(mire_path, quiet = TRUE)
cat("  ", nrow(mire_polygons), "polygons loaded.\n")

regions_all <- st_read(file.path("..", "Data", "spatial", "regions.shp"), quiet = TRUE)
regionlvl <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
regions_all$region[regions_all$id == 3] <- "Østlandet"
regions_all$region[regions_all$id == 5] <- "Sørlandet"
regions_all <- regions_all %>% mutate(region = factor(region, levels = regionlvl)) %>% st_transform(25833)
region_true_boundary <- regions_all %>% filter(region == region_name)
region_buffered_poly <- st_buffer(region_true_boundary, REGION_BUFFER_M)
bb <- st_bbox(region_buffered_poly)
target_extent <- ext(bb["xmin"], bb["xmax"], bb["ymin"], bb["ymax"])
cat("Buffered extent:", as.vector(target_extent), "\n")

# 10m template raster over the buffered extent, matching the mire
# raster's own resolution (no wetland_r available here since we're
# working from already-vectorized polygons, not deriving fresh).
wetland_r_template <- rast(target_extent, resolution = 10, crs = "EPSG:25833")
cat("Template raster cells:", ncell(wetland_r_template), "\n")

cat("Loading infrastructure index, cropping, resampling to 10m...\n")
t0 <- Sys.time()
lui_r <- rast(lui_path)
lui_r <- crop(lui_r, target_extent)
lui_r <- resample(lui_r, wetland_r_template, method = "near")
cat("  [timing] crop+resample:", round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "sec\n")

t0 <- Sys.time()
infra_binary <- lui_r > INFRA_THRESHOLD
infra_binary[infra_binary == 0] <- NA
infra_polygons <- as.polygons(infra_binary, dissolve = TRUE) |> st_as_sf()
cat("  [timing] threshold+vectorize:", round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "sec\n")
cat("Infrastructure polygon(s) (dissolved):", nrow(infra_polygons), "\n")

cat("Computing nearest-infrastructure distances (", INFRA_BUFFER_M, "m local search)...\n")
t0 <- Sys.time()
mire_buffered <- st_buffer(mire_polygons, INFRA_BUFFER_M)
has_nearby_infra <- lengths(st_intersects(mire_buffered, infra_polygons)) > 0

mire_polygons$min_infra_distance <- NA_real_
if (any(has_nearby_infra)) {
  d <- st_distance(mire_polygons[has_nearby_infra, ], infra_polygons)
  mire_polygons$min_infra_distance[has_nearby_infra] <- apply(d, 1, min)
}
cat("  [timing] nearest-infra distance:", round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "sec\n")
cat("  with infrastructure within", INFRA_BUFFER_M, "m:", sum(has_nearby_infra),
    "(", round(100 * mean(has_nearby_infra), 1), "% )\n")

mire_polygons$kvotient <- mire_polygons$min_infra_distance / mire_polygons$min_myr_distance_certified

n_before <- nrow(mire_polygons)
centroids <- st_centroid(st_geometry(mire_polygons))
in_true_region <- lengths(st_intersects(centroids, region_true_boundary)) > 0
mire_polygons <- mire_polygons[in_true_region, ]
cat("True-boundary filter: kept", nrow(mire_polygons), "of", n_before, "polygons.\n")

out_dir <- file.path("..", "Data", "connectivity_output_simplified")
out_path <- file.path(out_dir, paste0(ascii_name, "_connectivity_full_", YEAR, ".gpkg"))
st_write(mire_polygons, out_path, quiet = TRUE, append = FALSE)

cat("\n=== Summary for", region_name, "===\n")
cat("Final polygon count:", nrow(mire_polygons), "\n")
cat("min_infra_distance (NA = none within buffer): "); print(summary(mire_polygons$min_infra_distance))
cat("kvotient: "); print(summary(mire_polygons$kvotient))
cat("Written to", out_path, "\n")
