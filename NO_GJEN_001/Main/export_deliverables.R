# ============================================================
# NO_GJEN_001 - final export stage: platform-format indicator maps +
# delivery tables (see the repository README, "Delivery format").
#
# Reads the pipeline's results in ../Results/ (suffix "_OpenSource", the
# default 30 m reference variant) and writes, to ../Deliverables/:
#   NO_GJEN_001_indicatorMap_region.rds     5 landsdeler (primary)
#   NO_GJEN_001_indicatorMap_grid50km.rds   SSB 50 km cells with data
#   NO_GJEN_001_indicatorMap_polygon.rds    every wetland polygon valued
#   NO_GJEN_001_values.csv / .xlsx          region rows + national row,
#                                           metadata sheet, grid sheet
#   NO_GJEN_001_map.png
#
# Column mapping (platform <- pipeline):
#   v_YYYY          <- pop  (mean vegetation height in the wetland
#                     population, m; region/grid = mean over polygons)
#   i_YYYY          <- index (sigmoid-scaled, 1 = reference condition)
#   sd_YYYY         <- region/grid: bootstrap standard error of the
#                     area-weighted mean index (ecTools::ea_spread, R = 1000,
#                     as in the original pipeline); polygon level: NA
#   reference_high  <- ref  (X100: good-condition wetland reference height,
#                     30 m evaluation, Fetch/build_refvaatmark_30m.R; region/grid = mean over polygons of
#                     each polygon's stratum value)
#   reference_low   <- skog (X0: forest reference height, 90th percentile;
#                     same aggregation)
#   thr             <- 0.6 on the indicator scale (platform default; no X60
#                     is defined on the variable scale in the original work)
# Supplementary columns kept in csv/xlsx only: n (polygons), sd_pop, sd_ref
# (sd of polygon-level heights within the unit), i_sd_polygons (sd of
# polygon-level index values within the unit).
#
# Year label: DATA_YEAR below. The elevation models are Kartverket's DTM1/
# DOM1 national products (LiDAR flights 2010-2024, varying by tile); the
# NiN reference polygons run through 2025. One label is required by the
# platform's column convention; the range is stated in the metadata.
# ============================================================

suppressPackageStartupMessages({ library(sf); library(dplyr); library(boot) })

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args <- commandArgs(trailingOnly = FALSE); fm <- grep("^--file=", cmd_args)
  if (length(fm)) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[fm]))))
}
source(file.path("..", "..", "Tools", "export_platform_format.R"))

ID        <- "NO_GJEN_001"
VERSION   <- Sys.getenv("GJEN001_DELIVERY_VERSION", "000.002")
DATA_YEAR <- as.integer(Sys.getenv("GJEN001_DATA_YEAR", "2024"))
SUFFIX    <- Sys.getenv("GJEN001_RESULT_SUFFIX", "_OpenSource")
THR       <- 0.6

data_dir <- file.path("..", "Results")   # the pipeline writes its results here in this layout
out_dir  <- file.path("..", "Deliverables")

region_ids <- c("Nord-Norge" = 1L, "Midt-Norge" = 2L, "Østlandet" = 3L, "Vestlandet" = 4L, "Sørlandet" = 5L)

# --- inputs -----------------------------------------------------------
reg  <- st_read(file.path(data_dir, paste0(ID, "_wetland_index_region", SUFFIX, ".shp")), quiet = TRUE)
grid <- st_read(file.path(data_dir, paste0(ID, "_wetland_index_grid",   SUFFIX, ".shp")), quiet = TRUE)
poly <- st_read(file.path(data_dir, paste0(ID, "_wetland_index",        SUFFIX, ".shp")), quiet = TRUE)
poly$area_m2 <- as.numeric(st_area(poly))
cat("Inputs:", nrow(reg), "regions,", nrow(grid), "grid cells,", nrow(poly), "polygons (suffix", SUFFIX, ")\n")

# --- region (primary) ---------------------------------------------------
poly_by_region <- poly %>% st_drop_geometry() %>%
  group_by(region) %>% summarise(i_sd_polygons = sd(index), .groups = "drop")

region_long <- reg %>%
  transmute(area = region, areaId = unname(region_ids[region]), year = DATA_YEAR,
            v = pop_mean, sd = sd, i = index,
            reference_high = ref_mean, reference_low = skog_mean, thr = THR,
            n = n, sd_pop = sd_pop, sd_ref = sd_ref) %>%
  left_join(poly_by_region, by = c("area" = "region")) %>%
  arrange(areaId)

# --- 50 km grid -----------------------------------------------------------
# The pipeline's polygon-level `ssbid` is only a row number (a GEE-era
# name), so grid membership is re-derived here: polygon centroid within the
# SSB 50 km cell. The grid shapefile's `ssbid` is the SSBID (1..n) but the
# DBF stored it with a 1/1000 scale, hence the rounding.
ssb50 <- st_read(file.path("..", "Data", "OpenS_data", "ssb50km.shp"), quiet = TRUE) %>%
  st_transform(st_crs(poly)) %>% transmute(SSBID = as.integer(SSBID))
grid <- grid %>% mutate(SSBID = as.integer(round(ssbid * 1000)))
stopifnot(all(grid$SSBID %in% ssb50$SSBID))
poly_cell <- poly %>% st_point_on_surface() %>% suppressWarnings() %>%
  st_join(ssb50, join = st_within) %>% st_drop_geometry() %>% select(id, SSBID)
grid_stats <- poly %>% st_drop_geometry() %>%
  inner_join(poly_cell, by = "id") %>%
  group_by(SSBID) %>%
  summarise(v = mean(pop), reference_high = mean(ref), reference_low = mean(skog),
            n = n(), sd_pop = sd(pop), sd_ref = sd(ref), i_sd_polygons = sd(index), .groups = "drop")
grid_long <- grid %>%
  filter(!is.na(index)) %>%
  inner_join(grid_stats, by = "SSBID") %>%
  transmute(area = paste0("SSB50km_", SSBID), areaId = SSBID, year = DATA_YEAR,
            v = v, sd = sd, i = index, reference_high, reference_low, thr = THR,
            n, sd_pop, sd_ref, i_sd_polygons)
cat("Grid cells with data:", nrow(grid_long), "/", sum(!is.na(grid$index)), "\n")

# --- polygons -------------------------------------------------------------
poly_long <- poly %>%
  transmute(area = region, areaId = as.character(id), year = DATA_YEAR,
            v = pop, sd = NA_real_, i = index,
            reference_high = ref, reference_low = skog, thr = THR,
            vegClimZone = vegZn, area_m2 = area_m2)

# --- national row: area-weighted mean over polygons, bootstrap SE (R = 1000,
#     same estimator as ecTools::ea_spread uses per region) ------------------
set.seed(123)
pd <- poly %>% st_drop_geometry()
wmean <- function(d, idx) weighted.mean(d$index[idx], d$area_m2[idx])
b <- boot(pd, wmean, R = 1000)
national <- tibble(
  area = "Norge", areaId = 0L, year = DATA_YEAR,
  v = weighted.mean(pd$pop, pd$area_m2), sd = sd(b$t), i = b$t0,
  reference_high = weighted.mean(pd$ref, pd$area_m2), reference_low = weighted.mean(pd$skog, pd$area_m2),
  thr = THR, n = nrow(pd), sd_pop = sd(pd$pop), sd_ref = sd(pd$ref), i_sd_polygons = sd(pd$index)
)

# --- metadata sheet ---------------------------------------------------------
metadata <- c(
  "Indicator ID"                 = ID,
  "Version"                      = VERSION,
  "Indicator name (public)"      = "Gjengroing i våtmark",
  "Indicator name (technical)"   = "Woody encroachment in wetlands - vegetation height relative to good-condition reference",
  "Ecosystem"                    = "Våtmark (wetland); IUCN GET TF1.6 Boreal/temperate bogs, TF1.7 Boreal/temperate fens",
  "ECT class"                    = "B3 - Functional State Characteristics",
  "Spatial units delivered"      = "landsdel (5 regions, primary map), SSB 50 km grid cells with data, individual wetland polygons; national value in the values table (area = Norge)",
  "CRS"                          = "EPSG:25833 (ETRS89 / UTM 33N)",
  "Data year label"              = paste0(DATA_YEAR, " - label required by the platform's column convention. Elevation models: Kartverket DTM1/DOM1 national products (LiDAR flights 2010-2024, varying by tile). Reference polygons: NiN nature-type mapping through 2025. Population: AR5 wetland polygons."),
  "Variable (v)"                 = "Mean vegetation height (m) of the wetland population sample within the unit (canopy height model = DOM1 - DTM1, 1 m; 1000 stratified points per region x bioclimatic-zone stratum; buildings and 1986-2020 clear-cuts excluded)",
  "Indicator (i)"                = "1 - sigmoid(v scaled between reference_low and reference_high per polygon's stratum); 1 = reference condition (no encroachment), 0 = forest height. Aggregated to units as the area-weighted mean of polygon values",
  "Scaling function"             = "Sigmoid: 100.68 * (1 - exp(-5 * x^2.5)) / 100 on x = (v - X0) / (X100 - X0) clipped to [0, 1], then inverted (shorter vegetation = better). Same function as the original indicator",
  "reference_high (X100)"        = "Good-condition wetland reference height per region x bioclimatic-zone stratum: median canopy height per good-condition NiN wetland polygon with the CHM evaluated at 30 m, then median across polygons (matches the original definition; see Fetch/build_refvaatmark_30m.R). Unit value = mean over the unit's polygons of their stratum value",
  "reference_low (X0)"           = "Forest reference height per stratum: 90th percentile of canopy height in forest (AR5 skog) sample points. Unit value = mean over the unit's polygons of their stratum value",
  "Threshold (thr)"              = "0.6 on the indicator scale = platform default. No X60 on the variable scale is defined in the original work",
  "Uncertainty (sd)"             = "Region, grid and national: bootstrap standard error (R = 1000) of the area-weighted mean indicator value (estimator of ecTools::ea_spread, as in the original pipeline). Polygon level: not applicable. Supplementary columns: sd_pop / sd_ref = sd of polygon-level heights, i_sd_polygons = sd of polygon-level indicator values",
  "Number of observations"       = paste0(nrow(pd), " wetland polygons valued nationally; per-unit n in the tables"),
  "Justification of references"  = "Reference condition = vegetation height of wetland mapped in good ecological condition (NiN tilstand 'god'), i.e. an empirical reference from the least-impacted mapped sites; X0 = forest, the end state of encroachment. Both follow the original indicator's normative choice",
  "Data sources"                 = "Kartverket DTM1/DOM1 (open); NiN nature-type dataset, Miljødirektoratet (open); AR5 (NIBIO, access-restricted; AR50 open fallback); Moen bioclimatic zones (open); OpenStreetMap buildings; Senf et al. disturbance map; SSB grid via Kartverket",
  "Method note"                  = "Open-data reconstruction of the original NINA indicator NO_GJEN_001 (ecosystemCondition / ecRxiv). Same definitions and scaling; inputs replaced by open sources; wetland reference evaluated at 30 m as in the original GEE workflow",
  "Documentation"                = "https://github.com/Chimal93/wetland_condition_indicators/tree/main/NO_GJEN_001 ; original: https://github.com/NINAnor/ecRxiv/tree/main/indicators/NO_GJEN_001 ; https://ninanor.github.io/ecosystemCondition/gjengroing.html",
  "Column spelling note"         = "reference_high / reference_low as in the platform's example file; the platform docs and the contract text spell them referance_*",
  "Produced by"                  = "Sállir Natur AS",
  "Generated"                    = format(Sys.time(), "%Y-%m-%d %H:%M")
)

export_platform_indicator(
  id       = ID,
  units    = list(region = region_long, grid50km = grid_long, polygon = poly_long),
  national = national,
  metadata = metadata,
  out_dir  = out_dir,
  png_title = "NO_GJEN_001 - Gjengroing i våtmark"
)
