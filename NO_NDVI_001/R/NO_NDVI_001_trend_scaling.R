# ============================================================
# NO_NDVI_001 - trend-based NDVI scaling, wetland ecosystems, all
# available satellite sources combined (MODIS now; Sentinel-2/Landsat
# picked up automatically once their national fetches exist - see the
# `sources` list below).
#
# Implements the adapted scaling design found 2026-08-06 (see project
# memory / daily_notes_2026-08-06.md for full derivation): NINA's own
# wetland-NDVI documentation states no scaling approach was ever
# successfully defined for this indicator - but a complete, already-
# operational recipe exists for a DIFFERENT NINA indicator (mountain
# ecosystems' own NDVI indicator, NINA Rapport 2050 / Framstad et al.
# 2022), adapted here to wetland polygons instead of raster pixels.
#
# DESIGN:
#  - Indicator = SLOPE of a linear trend (peak NDVI ~ year) per wetland
#    polygon, NOT the raw NDVI value itself. Reference (undisturbed)
#    condition = slope 0 (no trend expected).
#  - Per polygon per year: take the MAXIMUM (peak growing-season) NDVI,
#    not the mean - matches NO_NDVI_001_wetland_pipeline.R's own
#    clean_ndvi() convention (Stage 6), so this stays consistent with
#    the rest of this indicator's codebase rather than introducing a
#    second, different aggregation rule.
#  - Threshold + extreme scaling anchors derived via PERMUTATION, not
#    assumed: shuffle each polygon's own year labels once, refit the
#    slope, pool one randomized slope per polygon into a null
#    distribution (same procedure as the mountain original). The
#    2.5th/97.5th percentile of |null slope| is the threshold; the
#    null distribution's own max |slope| is the extreme. Two-sided:
#    both greening AND browning trends count as deviation from
#    reference, since either direction indicates instability.
#  - Piecewise-linear scaling, same shape used throughout NINA's
#    reports: |slope|=0 -> 1.0 (reference), |slope|=threshold -> 0.6,
#    |slope|=extreme -> 0.0, clamped at 0 beyond the extreme.
#
# ADAPTATION FOR WETLAND (vs. the mountain original): mountain pixels
# all had a full continuous 2000-2019 MODIS record by construction: 25,000
# RANDOMLY PLACED pixels, not tied to any real-world feature that could
# have missing years. Wetland polygons are real, pre-existing features
# and can have patchy coverage (cloud/snow-masked growing seasons, edge-
# of-tile effects) - so a MIN_YEARS_REQUIRED guard is added here, with no
# equivalent in the mountain original, and multiple permutations per
# polygon are allowed (via N_PERM_PER_POLYGON) since wetland has far
# fewer independent polygons than mountain's 25,000 pixels to begin with.
#
# STATUS: runs against whichever sources are currently on disk - this
# script's structure (peak-NDVI-per-year -> per-unit slope -> pooled
# permutation threshold -> piecewise scaling) does not depend on which
# satellite fed it, only on having a real multi-year NDVI series per
# polygon. Currently MODIS-only in practice (Sentinel-2 pending CDSE's
# outage clearing + a completed national fetch); will automatically pick
# up Sentinel-2 the next time this script runs once that file exists.
# ============================================================

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

library(sf)
library(dplyr)
library(ggplot2)
library(ggrepel)

data_dir <- file.path("..", "data")
out_dir  <- file.path("..", "outputs", "results")
img_dir  <- file.path("..", "outputs", "results")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
if (!dir.exists(img_dir)) dir.create(img_dir, recursive = TRUE)

MIN_YEARS_REQUIRED <- 10   # of a possible 27 (2000-2026) - see ADAPTATION note above
N_PERM_PER_POLYGON <- 1    # bumped up below automatically if the pooled null distribution is too thin

# ------------------------------------------------------------
# Load whatever real satellite NDVI sources currently exist. Each source
# has its own min-area threshold matching its own pixel footprint (same
# per-satellite values NO_NDVI_001_wetland_pipeline.R's clean_ndvi() uses:
# Sentinel-2 10x10m=100, MODIS 250x250m=62500, Landsat 30x30m=900) - a
# small polygon that's meaningless for MODIS can still be perfectly valid
# for Sentinel-2's much finer resolution, so this must NOT be one shared
# constant. Sources are combined into one pool of (id, year, mean) rows
# BEFORE fitting per-polygon trends - this script does not care which
# satellite a given year's peak value came from, only that a real,
# defensible growing-season peak exists for that polygon-year. This is
# what makes the trend-scaling step automatically improve (more eligible
# polygons, since Sentinel-2's 10m fits far more real wetland polygon
# sizes than MODIS's 250m) the moment Sentinel-2's national fetch
# actually completes - no rewrite needed here when that happens.
# ------------------------------------------------------------
load_source <- function(label, path, min_area_m2, scale_divisor = 1) {
  if (!file.exists(path)) {
    cat("  [", label, "] not found at ", path, " - skipping (not an error, just not fetched yet).\n", sep = "")
    return(NULL)
  }
  df <- read.csv(path) %>%
    mutate(mean = mean / scale_divisor, date = as.Date(date), year = as.integer(format(date, "%Y")),
           id = as.character(id), source = label)
  cat("  [", label, "] ", nrow(df), " rows, ", length(unique(df$id)), " polygons, years ",
      min(df$year), "-", max(df$year), "\n", sep = "")
  list(data = df, min_area_m2 = min_area_m2)
}

cat("Loading available satellite NDVI sources:\n")
sources <- list(
  # The committed copy is gzipped (read.csv reads .gz directly); a fresh
  # fetch_modis_ndvi.R run writes the plain .csv, which then takes precedence.
  MODIS      = load_source("MODIS", {
                              f <- file.path(data_dir, "NDVI_MODIS", "modis_ndvi_ts_national.csv")
                              if (file.exists(f)) f else paste0(f, ".gz") },
                            min_area_m2 = 62500, scale_divisor = 10000),
  Sentinel2  = load_source("Sentinel-2", file.path(data_dir, "NDVI_Sentinel", "ndvi_national_clean.csv"),
                            min_area_m2 = 100, scale_divisor = 1)
  # Landsat: NOT YET BUILT (no fetch script exists) - add here (min_area_m2 = 900,
  # matching clean_ndvi()'s own Landsat threshold) once one does. Its absence is
  # not fatal to this script - it just means fewer/coarser data points than the
  # eventual 3-satellite version.
)
sources <- Filter(Negate(is.null), sources)
if (length(sources) == 0) stop("No satellite NDVI sources found at all - run fetch_modis_ndvi.R first.")
active_sources_label <- paste(names(sources), collapse = " + ")
all_possible <- c("MODIS", "Sentinel2", "Landsat")
missing <- setdiff(all_possible, names(sources))
missing_sources_note <- if (length(missing) == 0) "Alle tre satellittkilder inkludert." else
  paste0("Mangler foreløpig: ", paste(missing, collapse = ", "), ".")
cat("Active sources this run:", active_sources_label, "\n")

# ------------------------------------------------------------
# Load national wetland polygons (geometry needed for area filter,
# region assignment, and the final map) - same NiN gdb + filter used
# throughout this project.
# ------------------------------------------------------------
nin_gdb_dir <- file.path(data_dir, "nin_data")
gdb_path <- list.files(nin_gdb_dir, pattern = "\\.gdb$", full.names = TRUE)[1]
if (is.na(gdb_path)) stop("Missing national NiN geodatabase in ", nin_gdb_dir, ".")

nin <- st_read(gdb_path, layer = "naturtyper_nin_omr", quiet = TRUE)
wetland <- nin %>%
  rename(geometry = SHAPE) %>%
  st_set_geometry("geometry") %>%
  filter(hovedøkosystem == "våtmark") %>%
  st_make_valid() %>%
  filter(!st_is_empty(.)) %>%
  rename(id = identifikasjon_lokalId) %>%
  dplyr::select(id)
wetland$id <- as.character(wetland$id)
wetland$area_m2 <- as.numeric(st_area(wetland))
cat("National wetland polygons:", nrow(wetland), "\n")

regions <- st_read(file.path(data_dir, "spatial", "regions.shp"), quiet = TRUE)
regions$region[regions$id == 3] <- "Østlandet"
regions$region[regions$id == 5] <- "Sørlandet"
regionlvl <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
regions <- regions %>% mutate(region = factor(region, levels = regionlvl))

wetland_region <- st_join(wetland, st_transform(regions["region"], st_crs(wetland)), largest = TRUE)

# ------------------------------------------------------------
# Peak (max) NDVI per polygon per year, each source area-filtered by its
# OWN pixel footprint before combining - then re-collapsed to one peak
# value per polygon-year across whichever source(s) had data for it.
# ------------------------------------------------------------
wetland_areas <- st_drop_geometry(wetland) %>% dplyr::select(id, area_m2)

per_source_peak <- lapply(sources, function(src) {
  src$data %>%
    inner_join(wetland_areas, by = "id") %>%
    filter(area_m2 >= src$min_area_m2) %>%
    dplyr::select(id, year, mean, source)
})
combined <- bind_rows(per_source_peak)
cat("Combined rows across all active sources (post area-filter):", nrow(combined), "\n")
print(table(combined$source))

peak_ndvi <- combined %>%
  group_by(id, year) %>%
  slice_max(mean, n = 1, with_ties = FALSE) %>%
  ungroup()
cat("Peak-NDVI-per-polygon-per-year rows (combined, area-filtered):", nrow(peak_ndvi), "\n")

years_per_poly <- peak_ndvi %>% group_by(id) %>% summarise(n_years = n_distinct(year), .groups = "drop")
cat("Polygons with >=", MIN_YEARS_REQUIRED, "distinct years:",
    sum(years_per_poly$n_years >= MIN_YEARS_REQUIRED), "of", nrow(years_per_poly), "\n")

eligible_ids <- years_per_poly %>% filter(n_years >= MIN_YEARS_REQUIRED) %>% pull(id)
peak_eligible <- peak_ndvi %>% filter(id %in% eligible_ids)

# ------------------------------------------------------------
# Per-polygon trend slope (real, not permuted).
# ------------------------------------------------------------
fit_slope <- function(df) coef(lm(mean ~ year, data = df))[["year"]]

trend <- peak_eligible %>%
  group_by(id) %>%
  group_modify(~ tibble(slope = fit_slope(.x), n_years = n_distinct(.x$year))) %>%
  ungroup()
cat("\nReal per-polygon slopes fit:", nrow(trend), "\n")
cat("Slope summary:\n"); print(summary(trend$slope))

# ------------------------------------------------------------
# Permutation null distribution (two-sided): shuffle year labels within
# each eligible polygon's own series, refit, pool across polygons.
# ------------------------------------------------------------
set.seed(1)
permute_slopes_for <- function(df, n_perm) {
  vapply(seq_len(n_perm), function(i) {
    shuffled <- df
    shuffled$year <- sample(df$year)
    fit_slope(shuffled)
  }, numeric(1))
}

null_slopes <- peak_eligible %>%
  group_by(id) %>%
  group_map(~ permute_slopes_for(.x, N_PERM_PER_POLYGON)) %>%
  unlist()

if (length(null_slopes) < 500) {
  N_PERM_PER_POLYGON <- ceiling(500 / max(1, nrow(trend)))
  cat("\nPooled null distribution too thin (n=", length(null_slopes),
      ") for a well-resolved 97.5th percentile - bumping to", N_PERM_PER_POLYGON,
      "permutations per polygon (still one real trend per polygon; only the null gets extra draws).\n", sep = "")
  null_slopes <- peak_eligible %>%
    group_by(id) %>%
    group_map(~ permute_slopes_for(.x, N_PERM_PER_POLYGON)) %>%
    unlist()
}
cat("Pooled null distribution: n =", length(null_slopes), "\n")

threshold <- as.numeric(quantile(abs(null_slopes), 0.975, na.rm = TRUE))
extreme   <- max(abs(null_slopes), na.rm = TRUE)
cat("Threshold (|slope|, 97.5th pctile of null):", signif(threshold, 4), "\n")
cat("Extreme  (|slope|, max of null):           ", signif(extreme, 4), "\n")

# ------------------------------------------------------------
# Piecewise-linear two-sided scaling: 0 -> 1.0, threshold -> 0.6,
# extreme -> 0.0, clamped at 0 beyond the extreme.
# ------------------------------------------------------------
scale_trend <- function(slope, threshold, extreme) {
  a <- abs(slope)
  ifelse(
    a <= threshold,
    1 - 0.4 * (a / threshold),
    pmax(0, 0.6 - 0.6 * (a - threshold) / (extreme - threshold))
  )
}
trend <- trend %>% mutate(index = scale_trend(slope, threshold, extreme))
cat("\nScaled index summary:\n"); print(summary(trend$index))

# ------------------------------------------------------------
# Join back to geometry + region, regional area-weighted aggregation,
# standardized Tilstand map (same style as GJEN_001/FUNC_003/CON_001/
# GJEN_002's provisional map).
# ------------------------------------------------------------
trend_sf <- wetland_region %>% inner_join(trend, by = "id")
cat("\nPolygons with a final scaled index:", nrow(trend_sf), "\n")

region_agg <- trend_sf %>%
  st_drop_geometry() %>%
  filter(!is.na(region)) %>%
  group_by(region) %>%
  summarise(index = weighted.mean(index, w = area_m2, na.rm = TRUE), n = n(), .groups = "drop") %>%
  mutate(region = factor(region, levels = regionlvl))
cat("\n=== Regional aggregation (trend-based NDVI, wetland, ", active_sources_label, ") ===\n", sep = "")
print(as.data.frame(region_agg))

condition_breaks <- c(0, 0.2, 0.4, 0.6, 0.8, 1)
condition_labels <- c("Svært dårlig", "Dårlig", "Moderat", "God", "Svært god")
condition_colors <- setNames(
  c("#d7191c", "#fdae61", "#ffffbf", "#a6d96a", "#1a9641"),
  condition_labels
)

outline_path <- file.path(data_dir, "spatial", "outlineOfNorway_EPSG25833.shp")
regions_for_map <- regions
if (file.exists(outline_path)) {
  nor <- st_read(outline_path, quiet = TRUE) %>% st_transform(st_crs(regions_for_map))
  regions_for_map <- st_intersection(regions_for_map, nor)
} else {
  message("Note: ", outline_path, " not found - drawing regions.shp raw (no coastline clip).")
}

condition_map_dat <- regions_for_map %>%
  left_join(st_drop_geometry(region_agg), by = "region") %>%
  mutate(condition = cut(index, breaks = condition_breaks,
                          labels = condition_labels, include.lowest = TRUE))

label_pts <- condition_map_dat %>%
  st_point_on_surface() %>%
  mutate(label = ifelse(
    is.na(index),
    paste0(region, "\nIngen data"),
    sprintf("%s\n%.3f (n=%d)", region, index, n)
  ))
label_xy <- st_coordinates(label_pts)
label_pts$x <- label_xy[, "X"]; label_pts$y <- label_xy[, "Y"]

dummy_xy <- st_coordinates(st_point_on_surface(condition_map_dat[1, ]))
legend_dummy <- data.frame(
  condition = factor(condition_labels, levels = condition_labels),
  x = dummy_xy[1, "X"], y = dummy_xy[1, "Y"]
)

national_map <- ggplot() +
  geom_sf(data = condition_map_dat, aes(fill = condition), color = "black", linewidth = 0.4,
          show.legend = FALSE) +
  geom_point(data = legend_dummy, aes(x = x, y = y, fill = condition),
             shape = 22, size = 6, color = "black", alpha = 0) +
  geom_label_repel(data = label_pts, aes(x = x, y = y, label = label),
                    size = 2.6, lineheight = 0.85, fill = "white", color = "black",
                    label.size = 0.3, label.padding = unit(0.2, "lines"),
                    seed = 1, max.overlaps = Inf, min.segment.length = 0,
                    segment.color = "grey40", box.padding = 0.3) +
  scale_fill_manual(
    values = condition_colors, name = "Tilstand", limits = condition_labels,
    drop = FALSE, na.value = "grey80",
    guide = guide_legend(override.aes = list(alpha = 1))
  ) +
  labs(
    title   = paste0("NO_NDVI_001 indikator Våtmark - trend-basert NDVI-skalering (", active_sources_label, ")"),
    caption = paste0(
      "Indikator = helning av NDVI-trend per polygon (", min(combined$year), "-", max(combined$year),
      "), ikke rå NDVI-verdi.\n",
      "Terskel/ekstremverdi utledet via permutasjon (n=", length(null_slopes), " permuterte helninger).\n",
      missing_sources_note
    )
  ) +
  theme_void() +
  theme(plot.title = element_text(hjust = 0.5, face = "bold"),
        plot.caption = element_text(hjust = 0.5, size = 8))

map_path <- file.path(img_dir, "NO_NDVI_001_trend_scaling_map.png")
ggsave(map_path, national_map, width = 8, height = 9, dpi = 200)
cat("\nMap saved to:", map_path, "\n")

# ------------------------------------------------------------
# Export
# ------------------------------------------------------------
trend_csv_path <- file.path(out_dir, "NO_NDVI_001_trend_scaling_polygons.csv")
write.csv(st_drop_geometry(trend_sf), trend_csv_path, row.names = FALSE)

region_csv_path <- file.path(out_dir, "NO_NDVI_001_trend_scaling_regional.csv")
write.csv(region_agg, region_csv_path, row.names = FALSE)

# Scaling anchors, read by export_deliverables.R.
anchors_csv_path <- file.path(out_dir, "NO_NDVI_001_trend_scaling_anchors.csv")
write.csv(data.frame(reference_slope = 0, threshold = threshold, extreme = extreme,
                     n_null = length(null_slopes), n_perm_per_polygon = N_PERM_PER_POLYGON,
                     min_years = MIN_YEARS_REQUIRED, sources = active_sources_label,
                     year_min = min(peak_eligible$year), year_max = max(peak_eligible$year)),
          anchors_csv_path, row.names = FALSE)

cat("\nExported:\n  ", trend_csv_path, "\n  ", region_csv_path, "\n  ", anchors_csv_path, "\n  ", map_path, "\n", sep = "")
cat("\n=== Done ===\n")
