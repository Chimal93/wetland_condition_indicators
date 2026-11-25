# ============================================================
# NO_NDVI_001 - final export stage: platform-format indicator maps +
# Miljødirektoratet delivery tables.
#
# PROVISIONAL INDICATOR. MODIS only (250 m), so only the 983 NiN wetland
# polygons of at least one MODIS pixel with >= 10 growing seasons are
# scored, and no uncertainty is computed (sd = NA throughout). See the
# README's "Status" section.
#
# Reads NO_NDVI_001_trend_scaling.R's results in ../outputs/results/ and
# writes, to ../outputs/deliverables/:
#   NO_NDVI_001_indicatorMap_region.rds    5 landsdeler (primary)
#   NO_NDVI_001_indicatorMap_polygon.rds   every scored NiN wetland polygon
#   NO_NDVI_001_values.csv / .xlsx         region rows + national row,
#                                          metadata sheet, polygon sheet
#   NO_NDVI_001_map.png
#
# Column mapping (platform <- pipeline):
#   v_YYYY          <- slope of the linear trend of peak growing-season NDVI
#                     against year, per polygon (NDVI units per year);
#                     region / national = area-weighted mean over polygons
#   i_YYYY          <- index (two-sided piecewise-linear scaling of |slope|;
#                     region / national = area-weighted mean over polygons,
#                     identical to the pipeline's regional table)
#   sd_YYYY         <- NA (no uncertainty estimated yet)
#   reference_high  <- 0 (no trend = reference condition)
#   reference_low   <- the permutation null distribution's maximum |slope|
#                     (index 0)
#   thr             <- 0.6 on the indicator scale, which by construction is
#                     the 97.5th percentile of the |slope| null distribution
# Supplementary columns kept in csv/xlsx only: n (polygons), mean_abs_slope,
# slope_threshold (the |slope| at thr), i_sd_polygons.
#
# Year label: the trend window's last year (2026; the window is 2000-2026).
# The 2026 growing season was fetched up to July and is therefore partial.
# ============================================================

suppressPackageStartupMessages({ library(sf); library(dplyr); library(readr) })

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args <- commandArgs(trailingOnly = FALSE); fm <- grep("^--file=", cmd_args)
  if (length(fm)) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[fm]))))
}
source(file.path("..", "..", "Tools", "export_platform_format.R"))

ID      <- "NO_NDVI_001"
VERSION <- Sys.getenv("NDVI001_DELIVERY_VERSION", "000.001")
THR     <- 0.6

res_dir <- file.path("..", "outputs", "results")
out_dir <- file.path("..", "outputs", "deliverables")

region_ids <- c("Nord-Norge" = 1L, "Midt-Norge" = 2L, "Østlandet" = 3L, "Vestlandet" = 4L, "Sørlandet" = 5L)
region_names <- setNames(names(region_ids), region_ids)

# --- inputs -----------------------------------------------------------
anch <- read_csv(file.path(res_dir, "NO_NDVI_001_trend_scaling_anchors.csv"), show_col_types = FALSE)
pol  <- read_csv(file.path(res_dir, "NO_NDVI_001_trend_scaling_polygons.csv"), show_col_types = FALSE) %>%
  mutate(id = as.character(id))
reg_tab <- read_csv(file.path(res_dir, "NO_NDVI_001_trend_scaling_regional.csv"), show_col_types = FALSE)
DATA_YEAR <- as.integer(anch$year_max)
cat("Inputs:", nrow(pol), "polygons,", nrow(reg_tab), "regions; trend window",
    anch$year_min, "-", anch$year_max, "\n")

# Polygon geometry: the same NiN geodatabase the pipeline scored.
gdb <- list.files(file.path("..", "data", "nin_data"), pattern = "\\.gdb$", full.names = TRUE)[1]
if (is.na(gdb)) stop("NiN geodatabase missing - run R/fetch_nin_data.R first.")
nin <- st_read(gdb, layer = "naturtyper_nin_omr", quiet = TRUE) %>%
  rename(geometry = SHAPE) %>% st_set_geometry("geometry") %>%
  filter(identifikasjon_lokalId %in% pol$id) %>%
  transmute(id = as.character(identifikasjon_lokalId), naturtype = naturtype, tilstand = tilstand) %>%
  st_make_valid()
stopifnot(nrow(nin) == nrow(pol))

# Region geometry. regions.shp's `region` text has an encoding fault, so use `id`.
regions <- st_read(file.path("..", "data", "spatial", "regions.shp"), quiet = TRUE) %>%
  transmute(areaId = as.integer(id), area = unname(region_names[as.character(id)]))

pd <- pol %>% filter(!is.na(region))

# --- region (primary) ---------------------------------------------------
reg_stats <- pd %>% group_by(region) %>%
  summarise(v = weighted.mean(slope, area_m2), i = weighted.mean(index, area_m2),
            n = n(), mean_abs_slope = weighted.mean(abs(slope), area_m2),
            i_sd_polygons = sd(index), .groups = "drop")
# Must equal the pipeline's own regional table.
chk <- inner_join(reg_stats, reg_tab, by = "region")
stopifnot(nrow(chk) == nrow(reg_tab), isTRUE(all.equal(chk$i, chk$index)), all(chk$n.x == chk$n.y))

region_long <- regions %>%
  inner_join(reg_stats, by = c("area" = "region")) %>%
  transmute(area, areaId, year = DATA_YEAR, v, sd = NA_real_, i,
            reference_high = 0, reference_low = anch$extreme, thr = THR,
            n, mean_abs_slope, slope_threshold = anch$threshold, i_sd_polygons) %>%
  arrange(areaId)

# --- polygons -------------------------------------------------------------
poly_long <- nin %>%
  inner_join(pol, by = "id") %>%
  transmute(area = region, areaId = id, year = DATA_YEAR,
            v = slope, sd = NA_real_, i = index,
            reference_high = 0, reference_low = anch$extreme, thr = THR,
            n_years = n_years, naturtype, tilstand, area_m2)

# --- national row -----------------------------------------------------------
national <- tibble(
  area = "Norge", areaId = 0L, year = DATA_YEAR,
  v = weighted.mean(pd$slope, pd$area_m2), sd = NA_real_, i = weighted.mean(pd$index, pd$area_m2),
  reference_high = 0, reference_low = anch$extreme, thr = THR,
  n = nrow(pd), mean_abs_slope = weighted.mean(abs(pd$slope), pd$area_m2),
  slope_threshold = anch$threshold, i_sd_polygons = sd(pd$index)
)

# --- metadata sheet ---------------------------------------------------------
metadata <- c(
  "Indicator ID"                 = ID,
  "Version"                      = VERSION,
  "Status"                       = "PROVISIONAL - not finished. MODIS only; Sentinel-2 and Landsat not yet included; no uncertainty estimate. Delivered so the platform pipeline and the method can be reviewed",
  "Indicator name (public)"      = "Primærproduksjon i våtmark (NDVI-trend)",
  "Indicator name (technical)"   = "Wetland primary production - deviation of the long-term trend in peak growing-season NDVI from no trend",
  "Ecosystem"                    = "Våtmark (wetland); IUCN GET TF1.6 Boreal/temperate bogs, TF1.7 Boreal/temperate fens",
  "ECT class"                    = "B2 - Structural State Characteristics or B3 - Functional State Characteristics",
  "Spatial units delivered"      = "landsdel (5 regions, primary map), individual NiN wetland polygons; national value in the values table (area = Norge)",
  "CRS"                          = "EPSG:25833 (ETRS89 / UTM 33N)",
  "Data year label"              = paste0(DATA_YEAR, " - last year of the trend window ", anch$year_min, "-", anch$year_max, ". The ", DATA_YEAR, " growing season was fetched up to July and is partial"),
  "Variable (v)"                 = "Slope (NDVI units per year) of an ordinary least-squares line through each polygon's peak (maximum) growing-season NDVI per year, MODIS MOD13Q1 v6.1 (250 m, 16-day composites, late May to September; value of the pixel at the polygon centroid). Region / national value = area-weighted mean slope over polygons",
  "Indicator (i)"                = "Two-sided piecewise-linear scaling of |slope|: 0 -> 1, threshold -> 0.6, extreme -> 0, clamped at 0. Greening and browning both count as deviation. Aggregated as the area-weighted mean of polygon values",
  "reference_high (X100)"        = "0 - no trend. Reference condition is a stable NDVI over time",
  "reference_low (X0)"           = paste0(signif(anch$extreme, 4), " NDVI/yr (|slope|) - the maximum of a permutation null distribution: each polygon's year labels shuffled once and the slope refitted (n = ", anch$n_null, ")"),
  "Threshold (thr)"              = paste0("0.6 on the indicator scale = |slope| ", signif(anch$threshold, 4), " NDVI/yr, the 97.5th percentile of the same null distribution (column slope_threshold)"),
  "Uncertainty (sd)"             = "Not estimated (NA). Planned as further work",
  "Number of observations"       = paste0(nrow(pd), " NiN wetland polygons scored nationally: at least one MODIS pixel (>= 62,500 m2) and at least ", anch$min_years, " growing seasons. Few in some regions (Sørlandet n = ", sum(pd$region == "Sørlandet"), ")"),
  "Justification of references"  = "Adapted from the trend-based NDVI scaling of NINA's mountain condition assessment (Framstad et al., 2022), since no scaling was defined for the wetland NDVI indicator in the original work",
  "Data sources"                 = "MODIS/Terra Vegetation Indices 16-Day L3 Global 250 m (MOD13Q1 v6.1), NASA LP DAAC, doi:10.5067/MODIS/MOD13Q1.061, via NASA Earthdata (no restrictions on reuse); NiN nature-type dataset, Miljødirektoratet (downloaded 2026-08-05)",
  "Method note"                  = "Reconstruction of the wetland NDVI indicator in NINA's ecosystemCondition documentation (chapter 15), which defined no scaling. The original extracted NDVI with Google Earth Engine scripts; here MODIS is fetched directly from NASA without Earth Engine. The original exploratory analysis is kept in R/NO_NDVI_001_wetland_pipeline.R",
  "Documentation"                = "https://github.com/Chimal93/wetland_condition_indicators/tree/main/NO_NDVI_001 ; original: https://ninanor.github.io/ecosystemCondition/NDVI-indicator-wetland.html",
  "Column spelling note"         = "reference_high / reference_low as in the platform's example file; the platform docs and the contract text spell them referance_*",
  "Produced by"                  = "Sállir Natur AS",
  "Generated"                    = format(Sys.time(), "%Y-%m-%d %H:%M")
)

export_platform_indicator(
  id       = ID,
  units    = list(region = region_long, polygon = poly_long),
  national = national,
  metadata = metadata,
  out_dir  = out_dir,
  png_title = "NO_NDVI_001 - Primærproduksjon i våtmark (NDVI-trend, foreløpig)"
)
