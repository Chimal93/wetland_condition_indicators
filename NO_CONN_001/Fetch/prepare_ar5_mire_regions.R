# ============================================================
# NO_CONN_001 - build the per-region wetland inputs for the
# certified connectivity pipeline from AR5 myr (ARTYPE 60) instead of the
# mire probability map.
#
# WHY: the mire probability map stops at ~64 N (Nord-Norge falls back to
# NiN-mapped mires only, 4,917 polygons). AR5 myr is national and is the
# wetland population NO_GJEN_001 already uses.
#
# WHAT: for each region, polygons intersecting the region + 10 km buffer
# (the same buffer the model-based inputs carry; the infra step filters
# back to the true boundary), DISSOLVED into connected patches. AR5 splits
# one bog into many adjacent polygons along attribute boundaries; without
# dissolving, every shared edge would give min_myr_distance = 0 and
# kvotient = Inf. The raster-based inputs were connected components
# (terra::patches) - this is the vector equivalent. Then exploded to
# single-part POLYGONs, lightly simplified (2 m tolerance, topology
# preserved) to keep the exact-distance fallback fast, and written in the
# schema run_region_certified.R expects (patch_id, source, mire_id).
#
# Output: Data/wetland_map_ar5/wetland_simplified_<Region>.gpkg
# Run the pipeline on it with
#   CONNECTIVITY_MIRE_DIR=../Data/wetland_map_ar5
#   CONNECTIVITY_OUT_DIR=../Data/connectivity_output_ar5
# (see run_connectivity_ar5.ps1).
# ============================================================
suppressPackageStartupMessages({ library(sf); library(dplyr) })

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args <- commandArgs(trailingOnly = FALSE); fm <- grep("^--file=", cmd_args)
  if (length(fm)) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[fm]))))
}
sf_use_s2(FALSE)

# Source of the wetland population, in order of preference:
#   1. $AR5_MYR_GPKG, if set
#   2. this indicator's own Data/wetland_population/
#   3. the sibling NO_GJEN_001/Data/OpenS_data/ copies - the monorepo
#      already has the scripts that build these, so there is no reason to
#      keep a second 2.4 GB copy here
# AR5 (FKB-AR5) is preferred for its finer boundaries, but its licence
# restricts downloading to Norge digitalt parties, so the open AR50
# (NIBIO, NLOD) is used automatically when AR5 is absent. AR50 is national
# too, just coarser. Which one was used is recorded in the `source` column
# of every output, and in the console.
find_population <- function() {
  env <- Sys.getenv("AR5_MYR_GPKG", unset = "")
  if (nzchar(env)) {
    if (!file.exists(env)) stop("AR5_MYR_GPKG is set to a file that does not exist: ", env)
    return(env)
  }
  here <- file.path("..", "Data", "wetland_population")
  sib  <- file.path("..", "..", "NO_GJEN_001", "Data", "OpenS_data")
  for (d in c(here, sib)) {
    f <- file.path(d, "ar5_myr_national.gpkg")
    if (file.exists(f)) return(f)
  }
  for (d in c(here, sib)) {
    f <- file.path(d, "ar50_myr_national.gpkg")
    if (file.exists(f)) {
      message("AR5 not found - falling back to AR50 (NIBIO, open data, NLOD). ",
              "Coarser boundaries; results will differ slightly - see README.")
      return(f)
    }
  }
  stop("No wetland population layer found.\n",
       "  Looked in: ", here, " and ", sib, "\n",
       "  AR5 (preferred, Norge digitalt parties only): run\n",
       "    NO_GJEN_001/Fetch/extract_ar5_skog_myr.R   -> ar5_myr_national.gpkg\n",
       "  AR50 (open data, NLOD, no access needed): run\n",
       "    NO_GJEN_001/Fetch/build_ar50_wetland_lidar_coverage.R -> ar50_myr_national.gpkg\n",
       "  or set AR5_MYR_GPKG to either file. See this indicator's README.")
}
ar5_path   <- find_population()
pop_source <- if (grepl("ar50", basename(ar5_path))) "ar50_myr" else "ar5_myr"
cat("Wetland population:", ar5_path, "(source tag:", pop_source, ")\n")
# Write where the downstream scripts read from, so one variable defines the
# variant's input folder end to end (run_connectivity_ar5.ps1 sets it).
out_dir  <- Sys.getenv("CONNECTIVITY_MIRE_DIR", unset = file.path("..", "Data", "wetland_map_ar5"))
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
REGION_BUFFER_M <- 10000
SIMPLIFY_M      <- 2

regions_sel <- strsplit(Sys.getenv("CONNECTIVITY_REGIONS", "Nord-Norge,Sorlandet,Vestlandet,Midt-Norge,Ostlandet"), ",")[[1]]
name_map <- c("Nord-Norge" = "Nord-Norge", "Midt-Norge" = "Midt-Norge", "Vestlandet" = "Vestlandet",
              "Ostlandet" = "Østlandet", "Østlandet" = "Østlandet", "Sorlandet" = "Sørlandet", "Sørlandet" = "Sørlandet")
offset <- c("Nord-Norge" = 1e6, "Midt-Norge" = 2e6, "Østlandet" = 3e6, "Vestlandet" = 4e6, "Sørlandet" = 5e6)

regions <- st_read(file.path("..", "Data", "spatial", "regions.shp"), quiet = TRUE)
regions$region[regions$id == 3] <- "Østlandet"; regions$region[regions$id == 5] <- "Sørlandet"

layer <- st_layers(ar5_path)$name[1]
cat("Layer:", layer, "\n")

for (rsel in regions_sel) {
  region_name <- name_map[[rsel]]
  out_path <- file.path(out_dir, paste0("wetland_simplified_", region_name, ".gpkg"))
  if (file.exists(out_path)) { cat("==", region_name, "already prepared - skipping\n"); next }
  t0 <- Sys.time()
  reg_buf <- regions %>% filter(region == region_name) %>% st_buffer(REGION_BUFFER_M) %>% st_union()
  bb <- st_bbox(reg_buf)
  cat("==", region_name, "- reading", pop_source, "within the buffered bbox...\n")
  wkt <- st_as_text(st_as_sfc(bb))
  myr <- st_read(ar5_path, layer = layer, wkt_filter = wkt, quiet = TRUE)
  myr <- myr[lengths(st_intersects(myr, reg_buf)) > 0, ]
  cat("   ", nrow(myr), "source polygons in region + buffer; dissolving touching polygons into patches...\n")
  myr <- st_make_valid(myr)
  patches <- st_union(st_geometry(myr)) %>% st_cast("POLYGON")
  cat("   ", length(patches), "patches after dissolve (", round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1), "min )\n")
  patches <- st_simplify(patches, preserveTopology = TRUE, dTolerance = SIMPLIFY_M)
  patches <- patches[!st_is_empty(patches)]
  patches <- st_make_valid(patches)
  # st_make_valid can return multiparts/collections - keep polygon parts only, single-part
  patches <- st_collection_extract(patches, "POLYGON") %>% st_cast("POLYGON")
  out <- st_sf(patch_id = offset[[region_name]] + seq_along(patches),
               source   = pop_source,
               mire_id  = seq_along(patches),
               geom     = patches)
  st_write(out, out_path, quiet = TRUE, append = FALSE)
  cat("   written", nrow(out), "single-part patches ->", out_path,
      "(", round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1), "min total )\n")
  rm(myr, patches, out); gc()
}
cat("Done.\n")
