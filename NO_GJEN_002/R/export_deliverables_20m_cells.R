# ============================================================
# NO_GJEN_002 - deliverables from the orthophoto 20 m cell indicator
# (src/chm_national/cell_indicator.py), in the platform format of the other
# indicators (Tools/export_platform_format.R).
#
# Reads the tables of the national cell run, kept in the repository as
#   ../data/OpenS_data/orthophoto_chmv2_20m_cells/
#     region.csv, grid50km.csv, norway.csv, strata.csv, excluded.csv, uncertainty.csv,
#     sums_by_stratum_and_grid50km.csv, provenance.json
# (copied from <NATIONAL_CHM_OUT_DIR>/cell_indicator_chmv2/; the 20 m rasters
# stay there), and writes to ../outputs/deliverables/:
#   NO_GJEN_002_indicatorMap_region.rds     5 landsdeler (primary)
#   NO_GJEN_002_indicatorMap_grid50km.rds   SSB 50 km cells with mire
#   NO_GJEN_002_values.csv / .xlsx          region rows + national row,
#                                           metadata sheet, grid sheet
#   NO_GJEN_002_map.png
#
# Column mapping (platform <- cell tables):
#   YYYY            <- median flight year over Norway's mire (norway.csv), or GJEN002_DATA_YEAR
#   v_YYYY          <- height_m_raised_to_X100: mean calibrated vegetation height
#                     of the unit's AR5 mire, heights below X100 raised to X100
#                     (NO_GJEN_001's variable)
#   i_YYYY          <- index_area_weighted: mean of the 20 m cell values,
#                     each cell weighted by its mire area
#   sd_YYYY         <- uncertainty.csv: how far the photo-based indicator lies from
#                     the LiDAR-based one at ~25,000 validation cells, per region
#                     and Norway (sqrt(mean difference^2 + SE^2)); a 50 km square
#                     gets the value of the region holding most of its mire
#   reference_high  <- X100_ref, reference_low <- X0_skog (stratum values,
#                     averaged over the unit's mire area)
#   thr             <- 0.6 (platform default, as NO_GJEN_001)
# Supplementary columns (csv/xlsx only): i_sample_design (each region x zone
# stratum weighted equally, as NO_GJEN_001's sample), height_m (calibrated
# height without raising), n_cells, mire_km2, flight_year_median / _min / _max.
# ============================================================

suppressPackageStartupMessages({ library(sf); library(dplyr); library(readr); library(jsonlite) })

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args <- commandArgs(trailingOnly = FALSE); fm <- grep("^--file=", cmd_args)
  if (length(fm)) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[fm]))))
}
source(file.path("..", "..", "Tools", "export_platform_format.R"))

ID        <- "NO_GJEN_002"
VERSION   <- Sys.getenv("GJEN002_DELIVERY_VERSION", "000.004")
THR       <- 0.6

in_dir  <- file.path("..", "data", "OpenS_data", "orthophoto_chmv2_20m_cells")
out_dir <- Sys.getenv("GJEN002_DELIVERABLES_DIR", file.path("..", "outputs", "deliverables"))
g1_dir  <- file.path("..", "..", "NO_GJEN_001", "data", "OpenS_data")

region_ids <- c("Nord-Norge" = 1L, "Midt-Norge" = 2L, "Østlandet" = 3L, "Vestlandet" = 4L, "Sørlandet" = 5L)

prov <- fromJSON(file.path(in_dir, "provenance.json"))
if (!isTRUE(prov$complete)) stop("The cell run in ", in_dir, " is not complete (see provenance.json)")
reg  <- read_csv(file.path(in_dir, "region.csv"), show_col_types = FALSE)
grid <- read_csv(file.path(in_dir, "grid50km.csv"), show_col_types = FALSE, col_types = cols(SSBID = "c"))
nat  <- read_csv(file.path(in_dir, "norway.csv"), show_col_types = FALSE)
# Year label: the median flight year of the photos over Norway's AR5 mire area
# (each cell dated by the mosaic's flight project visible there).
DATA_YEAR <- as.integer(Sys.getenv("GJEN002_DATA_YEAR", nat$flight_year_median))
cat("Inputs:", nrow(reg), "regions,", nrow(grid), "grid rows, national mire",
    round(nat$mire_km2), "km2 in", nat$n_cells, "cells\n")

to_long <- function(d) d %>% mutate(
  year = DATA_YEAR, v = height_m_raised_to_X100, i = index_area_weighted,
  reference_high = X100_ref, reference_low = X0_skog, thr = THR,
  i_sample_design = index_sample_design, height_m = height_m, n_cells = n_cells, mire_km2 = mire_km2,
  flight_year_median = flight_year_median, flight_year_min = flight_year_min, flight_year_max = flight_year_max)
cols <- c("area", "areaId", "year", "v", "sd", "i", "reference_high", "reference_low", "thr",
          "i_sample_design", "height_m", "n_cells", "mire_km2", "flight_year_median", "flight_year_min", "flight_year_max")

# --- region (primary) ---------------------------------------------------
regions <- st_read(file.path(g1_dir, "regions.shp"), quiet = TRUE, options = "ENCODING=UTF-8") %>%
  st_transform(25833) %>% select(region)
stopifnot(setequal(reg$region, names(region_ids)), all(reg$region %in% regions$region))
unc <- read_csv(file.path(in_dir, "uncertainty.csv"), show_col_types = FALSE)
stopifnot(all(c(reg$region, "Norge") %in% unc$region))
sd_of <- setNames(unc$sd, unc$region)
region_long <- regions %>% inner_join(to_long(reg) %>% mutate(sd = unname(sd_of[region])), by = "region") %>%
  mutate(area = region, areaId = unname(region_ids[region])) %>%
  select(all_of(cols)) %>% arrange(areaId)

# --- 50 km grid (cells with mire; cells whose centre lies outside the
#     SSB grid have no SSBID and are only in the regional/national values) ---
ssb50 <- st_read(file.path(g1_dir, "ssb50km.shp"), quiet = TRUE) %>% st_transform(25833) %>% select(SSBID)
grid <- grid %>% filter(!is.na(SSBID))
main_region <- read_csv(file.path(in_dir, "sums_by_stratum_and_grid50km.csv"), show_col_types = FALSE,
                        col_types = cols(SSBID = "c")) %>%
  filter(!is.na(SSBID)) %>% group_by(SSBID, region) %>% summarise(km2 = sum(mire_km2), .groups = "drop") %>%
  group_by(SSBID) %>% slice_max(km2, n = 1, with_ties = FALSE) %>% ungroup() %>% select(SSBID, main_region = region)
grid <- grid %>% left_join(main_region, by = "SSBID") %>% mutate(sd = unname(sd_of[main_region]))
stopifnot(all(grid$SSBID %in% ssb50$SSBID))
grid_long <- ssb50 %>% inner_join(to_long(grid), by = "SSBID") %>%
  mutate(area = paste0("SSB50km_", SSBID), areaId = as.integer(SSBID)) %>%
  select(all_of(cols))

# --- national row ----------------------------------------------------------
national <- to_long(nat) %>% mutate(area = "Norge", areaId = 0L, sd = unname(sd_of["Norge"])) %>% select(all_of(cols))

excl <- read_csv(file.path(in_dir, "excluded.csv"), col_names = c("what", "value"), skip = 1, show_col_types = FALSE)
cal <- prov$calibration

# --- metadata sheet ---------------------------------------------------------
metadata <- c(
  "Indicator ID"                 = ID,
  "Version"                      = VERSION,
  "Indicator name (public)"      = "Gjengroing i våtmark (flyfoto)",
  "Indicator name (technical)"   = "Woody encroachment in wetlands - vegetation height from aerial orthophoto (CHMv2 canopy-height model, calibrated to LiDAR) relative to good-condition reference",
  "Ecosystem"                    = "Våtmark (wetland); IUCN GET TF1.6 Boreal/temperate bogs, TF1.7 Boreal/temperate fens",
  "ECT class"                    = "B2 - Structural State Characteristics",
  "Spatial units delivered"      = "landsdel (5 regions, primary map), SSB 50 km grid cells with AR5 mire; national value in the values table (area = Norge). Computed from all 20 m cells of AR5 mire (wall-to-wall)",
  "CRS"                          = "EPSG:25833 (ETRS89 / UTM 33N)",
  "Data year label"              = paste0(DATA_YEAR, " - label required by the platform's column convention: median flight year of the photos over the AR5 mire area of Norway (photos from ", nat$flight_year_min, " to ", nat$flight_year_max, "). Each 20 m cell is dated by the flight project visible there in the 2025 national orthophoto mosaic; median, earliest and latest flight year per unit are in the columns flight_year_*"),
  "Variable (v)"                 = "Mean vegetation height (m) of the unit's AR5 mire: per 20 m cell the median of the 0.5 m CHMv2 heights, calibrated to LiDAR, heights below the stratum's reference raised to it (as NO_GJEN_001); mean over cells weighted by mire area",
  "Indicator (i)"                = "1 - sigmoid(cell height scaled between reference_low and reference_high of the cell's stratum), per 20 m cell; 1 = reference condition (no encroachment), 0 = forest height. Unit value = mean over the unit's cells weighted by their AR5 mire area. Column i_sample_design: the same with every region x bioclimatic-zone stratum weighted equally, as in NO_GJEN_001's sample",
  "Scaling function"             = "Sigmoid: 100.68 * (1 - exp(-5 * x^2.5)) / 100 on x = (v - X100) / (X0 - X100) clipped to [0, 1], then inverted (shorter vegetation = better). Same function as NO_GJEN_001",
  "reference_high (X100)"        = "From NO_GJEN_001, per region x bioclimatic-zone stratum: good-condition NiN wetland polygons, canopy height evaluated at 30 m, median per polygon, then median across polygons. Unit value = stratum values averaged over the unit's mire area",
  "reference_low (X0)"           = "From NO_GJEN_001, per stratum: 90th percentile of canopy height in AR5 forest sample cells (20 m). Unit value = stratum values averaged over the unit's mire area",
  "Threshold (thr)"              = "0.6 on the indicator scale = platform default, as NO_GJEN_001",
  "Uncertainty (sd)"             = paste0("Agreement with the LiDAR-based indicator (NO_GJEN_001 method) at ", unc$n_validation_cells[unc$region == "Norge"], " validation cells (20 m) in AR5 mire: the indicator is computed at each cell from LiDAR height and from the calibrated photo-based height (calibration fitted without the cell's region); sd = sqrt(mean difference^2 + SE^2), SE from 1000 bootstrap resamples of the cells. Region and national values from the cells in the unit; a 50 km square gets the value of the region holding most of its mire"),
  "Calibration"                  = paste0("LiDAR height = max(0, ", cal$a, " + ", cal$b, " x CHMv2 height), 20 m cell medians; fitted on ", cal$points),
  "Number of observations"       = paste0(nat$n_cells, " cells of 20 m x 20 m (", round(nat$mire_km2), " km2 of AR5 mire); per-unit n_cells in the tables. Left out: ",
                                          paste0(excl$what, " ", format(excl$value, big.mark = ",", scientific = FALSE, trim = TRUE), collapse = "; ")),
  "Justification of references"  = "As NO_GJEN_001: reference condition = vegetation height of wetland mapped in good ecological condition (NiN tilstand 'god'); X0 = forest, the end state of encroachment",
  "Data sources"                 = "National 50 cm RGB orthophoto mosaic (Norge i bilder); CHMv2 canopy-height model (Meta / World Resources Institute, open weights); AR5 mire (NIBIO FKB-AR5); OpenStreetMap buildings; references from NO_GJEN_001 (Kartverket DTM1/DOM1, AR5, NiN); Moen bioclimatic zones; SSB grid via Kartverket",
  "Method note"                  = "Replaces the earlier NO_GJEN_002 version based on NiN wetland polygons. Same cells, height measure, references and scaling as NO_GJEN_001, but every 20 m cell of AR5 mire instead of a sample",
  "Documentation"                = "https://github.com/Chimal93/wetland_condition_indicators/tree/main/NO_GJEN_002",
  "Column spelling note"         = "reference_high / reference_low as in the platform's example file; the platform docs and the contract text spell them referance_*",
  "Produced by"                  = "Sállir Natur AS",
  "Generated"                    = format(Sys.time(), "%Y-%m-%d %H:%M")
)

export_platform_indicator(
  id        = ID,
  units     = list(region = region_long, grid50km = grid_long),
  national  = national,
  metadata  = metadata,
  out_dir   = out_dir,
  png_title = "NO_GJEN_002 - Gjengroing i våtmark (flyfoto)"
)
