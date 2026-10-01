# ============================================================
# NO_GJEN_002 - NATIONAL PIPELINE (real Meta-model canopy heights).
#
# Runs the gjengroing indicator for the entire national NiN wetland
# population using the canopy heights predicted by the Meta
# HighResCanopyHeight model on 50 cm aerial orthophoto - the frozen run
# archived in Data/OpenS_data/meta_chm_national_RAW_2026-09-17/ (see its
# README for provenance, run time and checksums). Supersedes
# NO_GJEN_002_national_pipeline_PROVISIONAL.R (ETH/Sentinel-2 stand-in),
# whose structure this keeps.
#
# Anchors (both shared with NO_GJEN_001, as the original design borrows
# them unchanged):
#   ref  (X100) - Data/OpenS_data/refvaatmark_openS_30m.csv, the good-
#                 condition wetland reference evaluated at 30 m
#                 (NO_GJEN_001/R/build_refvaatmark_openS_30m.R, column
#                 ref_mean30). Replaces the earlier 1 m refvaatmark_openS.csv.
#   skog (X0)   - Data/OpenS_data/vegHeights_skog_climZoneRegion_openS.csv,
#                 NO_GJEN_001's current (AR5-based) forest reference; the
#                 2026-07-23 AR50-era copy is kept as *_SUPERSEDED_2026-07.csv.
# Population value: meta_chm_mean (validated; not the median).
#
# Scaling: identical sigmoid to NO_GJEN_001 (per polygon, against its
# region x bioclim stratum anchors), 1 = reference condition.
# Aggregation: ecTools::ea_spread() area-weighted mean + bootstrap SE, to
# the 5 regions and the SSB 50 km grid - the same estimator NO_GJEN_001
# uses, so the two GJEN indicators are directly comparable.
#
# Outputs (../Results/, suffix _OpenSource):
#   ../Results/NO_GJEN_002_wetland_index_OpenSource.csv / .shp  per polygon
#   NO_GJEN_002_wetland_index_region_OpenSource.shp   per region
#   NO_GJEN_002_wetland_index_grid_OpenSource.shp     per 50 km cell
#   vaatmarkIndexStrata_OpenSource.csv                 per stratum
#   ../Results/NO_GJEN_002_wetland_map_OpenSource.png
# ============================================================

suppressPackageStartupMessages({
  library(sf); library(dplyr); library(readr); library(tidyr); library(tibble)
  library(ggplot2); library(ggrepel); library(RColorBrewer)
})

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args   <- commandArgs(trailingOnly = FALSE)
  file_match <- grep("^--file=", cmd_args)
  if (length(file_match) > 0) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[file_match]))))
}

spatial_dir <- file.path("..", "Data", "spatial")
data_dir    <- file.path("..", "Data")
opens_dir   <- file.path(data_dir, "OpenS_data")
results_dir <- file.path("..", "Results")   # indicator outputs (repo convention)
img_dir     <- results_dir
if (!dir.exists(img_dir)) dir.create(img_dir, recursive = TRUE)
# Forest anchor (GJEN002_SKOG_SCALE). Both anchors are borrowed from
# NO_GJEN_001, as the original design does.
#   "20m" (default) - the forest p90 read as 20 m cell means, i.e. the
#                     scale the original workflow uses. This is what
#                     NO_GJEN_001 delivers, so the two indicators are
#                     scaled against the same X0.
#   "1m"            - the earlier native-resolution anchor, about 14 %
#                     higher; outputs suffixed "_skog1m" for comparison.
skog_scale  <- Sys.getenv("GJEN002_SKOG_SCALE", "20m")
if (!skog_scale %in% c("1m", "20m")) stop("GJEN002_SKOG_SCALE must be '20m' or '1m'")
out_suffix  <- if (skog_scale == "20m") "_OpenSource" else "_OpenSource_skog1m"
skog_file   <- if (skog_scale == "20m") "vegHeights_skog_climZoneRegion_openS_20m.csv" else "vegHeights_skog_climZoneRegion_openS.csv"
raw_dir     <- Sys.getenv("GJEN002_META_RAW_DIR", file.path(opens_dir, "meta_chm_national_RAW_2026-09-17"))

cat("\n", strrep("=", 70), "\nNO_GJEN_002 NATIONAL PIPELINE - Meta canopy heights from orthophoto\n", strrep("=", 70), "\n", sep = "")

# ===========================================================
# STAGE 1: Population canopy heights (frozen archive) + NiN polygons.
# ===========================================================
raw_files <- list.files(raw_dir, pattern = "^meta_chm_national_.*\\.csv$", full.names = TRUE)
if (length(raw_files) == 0) stop("No meta_chm_national_*.csv in ", raw_dir)
meta <- bind_rows(lapply(raw_files, read_csv, show_col_types = FALSE)) %>%
  select(id, pop = meta_chm_mean, meta_chm_median, meta_chm_n, n_tiles, region_filter)
cat("Meta canopy heights:", nrow(meta), "polygons from", length(raw_files), "regional files\n")
stopifnot(!any(duplicated(meta$id)))

nin_gdb_dir <- file.path(opens_dir, "nin_data")
gdb_path <- list.files(nin_gdb_dir, pattern = "\\.gdb$", full.names = TRUE)[1]
if (is.na(gdb_path)) stop("Missing national NiN geodatabase - run fetch_nin_data.R first.")
cat("Loading national NiN wetland polygons...\n")
nin <- st_read(gdb_path, layer = "naturtyper_nin_omr", quiet = TRUE)
wetland <- nin %>%
  rename(geometry = SHAPE) %>% st_set_geometry("geometry") %>%
  filter(hovedøkosystem == "våtmark") %>%
  st_make_valid() %>% filter(!st_is_empty(.)) %>%
  rename(id = identifikasjon_lokalId) %>%
  select(id, naturtype, tilstand, kartleggingsår, geometry)

metaChm <- wetland %>% inner_join(meta, by = "id")
cat("  ", nrow(metaChm), "polygons with a canopy-height value (of", nrow(wetland), "national wetland polygons)\n")

# ===========================================================
# STAGE 2: Regions and bioclimatic strata (as in NO_GJEN_001).
# ===========================================================
regions <- st_read(file.path(spatial_dir, "regions.shp"), quiet = TRUE)
regions$region[regions$id == 3] <- "Østlandet"
regions$region[regions$id == 5] <- "Sørlandet"
regionlvl      <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
vegclimzonelvl <- c("Lavalpin sone (LA)", "Nordboreal sone (NB)", "Mellomboreal sone (MB)",
                    "Sørboreal sone (SB)", "Boreonemoral sone (BN)")
regions <- regions %>% mutate(region = factor(region, levels = regionlvl)) %>% st_make_valid()
metaChm <- st_transform(metaChm, st_crs(regions)) %>% st_make_valid()   # re-validate AFTER reprojection

# Dissolved zones must be valid: st_join(largest = TRUE) intersects on the
# fly and a single self-touching ring in the union aborts the whole join.
bioclim <- st_read(file.path(opens_dir, "bioclim", "soner2017.shp"), quiet = TRUE) %>%
  st_transform(st_crs(regions)) %>% st_make_valid() %>%
  group_by(Sone_navn) %>% summarise(geometry = st_union(geometry)) %>%
  st_make_valid() %>%
  rename(vegClimZoneLab = Sone_navn) %>%
  mutate(vegClimZoneLab = factor(vegClimZoneLab, levels = vegclimzonelvl))

cat("Assigning region and bioclim zone by largest overlap (", nrow(metaChm), " polygons)...\n", sep = "")
t0 <- Sys.time()
# Largest-overlap join (as NO_GJEN_001); if GEOS still trips on a residual
# topology conflict, fall back per layer to the majority-intersects rule the
# provisional pipeline used (the same answer for all but boundary slivers).
join_largest <- function(x, y, col) {
  tryCatch(st_join(x, y, largest = TRUE),
    error = function(e) {
      message("  largest-overlap join failed (", conditionMessage(e), ") - using majority st_intersects for ", col)
      hits <- st_intersects(x, y)
      x[[col]] <- sapply(hits, function(i) if (length(i)) as.character(y[[col]][i[1]]) else NA_character_)
      x
    })
}
metaChm <- join_largest(metaChm, regions %>% select(region), "region")
metaChm <- join_largest(metaChm, bioclim, "vegClimZoneLab")
cat("  [timing]", round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "sec\n")
cat("  unassigned: region", sum(is.na(metaChm$region)), "| bioclim zone", sum(is.na(metaChm$vegClimZoneLab)), "\n")

# ===========================================================
# STAGE 3: Reference anchors.
# ===========================================================
message("Forest anchor: ", skog_file)
skog_tab <- read_csv(file.path(opens_dir, skog_file), show_col_types = FALSE) %>%
  select(region, vegClimZoneLab, skog)
ref_tab <- read_csv(file.path(opens_dir, "refvaatmark_openS_30m.csv"), show_col_types = FALSE) %>%
  transmute(region, vegClimZoneLab, ref = ref_mean30)

vaatmarkHts <- metaChm %>%
  mutate(region = as.character(region), vegClimZoneLab = as.character(vegClimZoneLab)) %>%
  left_join(skog_tab, by = c("region", "vegClimZoneLab")) %>%
  left_join(ref_tab,  by = c("region", "vegClimZoneLab"))
n_no_anchor <- sum(is.na(vaatmarkHts$ref) | is.na(vaatmarkHts$skog))
cat("Polygons with both anchors resolved:", nrow(vaatmarkHts) - n_no_anchor, "of", nrow(vaatmarkHts),
    "(", n_no_anchor, "in strata without a reference - dropped)\n")
vaatmarkHts <- vaatmarkHts %>% filter(!is.na(ref), !is.na(skog))

# ===========================================================
# STAGE 4: Sigmoid scaling (NO_GJEN_001's function, per polygon).
# ===========================================================
scaleSigmoid <- function(pop, ref, skog) {
  x <- (pop - ref) / (skog - ref)
  x[x < 0] <- 0; x[x > 1] <- 1
  round(100.68 * (1 - exp(-5 * x^2.5)) / 100, 4)
}
vaatmarkIndexPoly <- vaatmarkHts %>%
  mutate(index = 1 - scaleSigmoid(pop, ref, skog)) %>%
  mutate(region = factor(region, levels = regionlvl),
         vegClimZoneLab = factor(vegClimZoneLab, levels = vegclimzonelvl))
cat("Wetland polygons with a valid indicator value:", nrow(vaatmarkIndexPoly), "\n")
cat("Index summary:\n"); print(summary(vaatmarkIndexPoly$index))

# ===========================================================
# STAGE 5: Aggregation - strata, regions (ea_spread), 50 km grid (ea_spread).
# ===========================================================
vaatmarkIndexStrata <- vaatmarkIndexPoly %>% st_drop_geometry() %>%
  group_by(region, vegClimZoneLab) %>%
  summarise(pop = mean(pop), ref = first(ref), skog = first(skog),
            index = mean(index), n = n(), .groups = "drop")
write_csv(vaatmarkIndexStrata, file.path(results_dir, paste0("vaatmarkIndexStrata", out_suffix, ".csv")))

heights_region <- vaatmarkIndexPoly %>% st_drop_geometry() %>%
  group_by(region) %>%
  summarise(pop_mean = mean(pop), skog_mean = mean(skog), ref_mean = mean(ref),
            sd_ref = sd(ref), sd_pop = sd(pop), n = n(), .groups = "drop")

cat("Aggregating to regions and 50 km grid with ecTools::ea_spread (bootstrap SE)...\n")
t0 <- Sys.time()
vaatmarkIndexRegion <- ecTools::ea_spread(
  indicator_data = vaatmarkIndexPoly, indicator = index,
  regions = regions, groups = region, threshold = 1
) %>%
  mutate(index = w_mean, region = ID) %>%
  select(region, index, sd) %>%
  left_join(heights_region %>% mutate(region = as.character(region)), by = "region")

ssb50km <- st_read(file.path(opens_dir, "ssb50km.shp"), quiet = TRUE) %>%
  mutate(SSBID = as.numeric(SSBID) / 1000) %>%      # same DBF-scale convention as NO_GJEN_001
  st_transform(st_crs(regions))
vaatmarkIndexGrid <- ecTools::ea_spread(
  indicator_data = vaatmarkIndexPoly, indicator = index,
  regions = ssb50km, groups = SSBID, threshold = 1
) %>%
  mutate(index = w_mean, ssbid = ID) %>%
  select(ssbid, index, sd)
cat("  [timing]", round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "sec\n")

cat("\n=== Regional aggregation ===\n")
print(as.data.frame(vaatmarkIndexRegion %>% st_drop_geometry() %>%
                      mutate(across(where(is.numeric), ~ round(.x, 4)))))

# ===========================================================
# STAGE 6: Exports.
# ===========================================================
poly_out <- vaatmarkIndexPoly %>%
  select(id, region, vegClimZoneLab, index, pop, ref, skog, naturtype, tilstand, kartleggingsår)
st_write(poly_out, file.path(results_dir, paste0("NO_GJEN_002_wetland_index", out_suffix, ".shp")), delete_dsn = TRUE, quiet = TRUE)
write_csv(st_drop_geometry(poly_out), file.path(results_dir, paste0("NO_GJEN_002_wetland_index", out_suffix, ".csv")))
st_write(vaatmarkIndexRegion, file.path(results_dir, paste0("NO_GJEN_002_wetland_index_region", out_suffix, ".shp")), delete_dsn = TRUE, quiet = TRUE)
st_write(vaatmarkIndexGrid, file.path(results_dir, paste0("NO_GJEN_002_wetland_index_grid", out_suffix, ".shp")), delete_dsn = TRUE, quiet = TRUE)

# ===========================================================
# STAGE 7: Standardised "Tilstand" map (same style as the other indicators).
# ===========================================================
condition_breaks <- c(0, 0.2, 0.4, 0.6, 0.8, 1)
condition_labels <- c("Svært dårlig", "Dårlig", "Moderat", "God", "Svært god")
condition_colors <- setNames(c("#d7191c", "#fdae61", "#ffffbf", "#a6d96a", "#1a9641"), condition_labels)

regions_for_map <- regions
outline_path <- file.path(spatial_dir, "outlineOfNorway_EPSG25833.shp")
if (file.exists(outline_path)) {
  nor <- st_read(outline_path, quiet = TRUE) %>% st_transform(st_crs(regions))
  regions_for_map <- suppressWarnings(st_intersection(regions_for_map, nor))
}
map_dat <- regions_for_map %>%
  left_join(vaatmarkIndexRegion %>% st_drop_geometry() %>% mutate(region = factor(region, levels = regionlvl)), by = "region") %>%
  mutate(condition = cut(index, breaks = condition_breaks, labels = condition_labels, include.lowest = TRUE))
label_pts <- suppressWarnings(st_point_on_surface(map_dat)) %>%
  mutate(label = sprintf("%s\n%.3f (n=%d)", region, index, n))
xy <- st_coordinates(label_pts); label_pts$x <- xy[, 1]; label_pts$y <- xy[, 2]
legend_dummy <- data.frame(condition = factor(condition_labels, levels = condition_labels), x = xy[1, 1], y = xy[1, 2])

national_map <- ggplot() +
  geom_sf(data = map_dat, aes(fill = condition), color = "black", linewidth = 0.4, show.legend = FALSE) +
  geom_point(data = legend_dummy, aes(x = x, y = y, fill = condition), shape = 22, size = 6, color = "black", alpha = 0) +
  geom_label_repel(data = label_pts, aes(x = x, y = y, label = label), size = 2.6, lineheight = 0.85,
                   fill = "white", color = "black", label.size = 0.3, seed = 1, max.overlaps = Inf,
                   min.segment.length = 0, segment.color = "grey40", box.padding = 0.3) +
  scale_fill_manual(values = condition_colors, name = "Tilstand", limits = condition_labels, drop = FALSE,
                    na.value = "grey80", guide = guide_legend(override.aes = list(alpha = 1))) +
  labs(title = "NO_GJEN_002 - Gjengroing i våtmark (flyfoto, Meta canopy-height model)",
       subtitle = sprintf("%d NiN-våtmarkpolygoner, arealvektet gjennomsnitt per landsdel", nrow(vaatmarkIndexPoly)),
       caption = "Referanser (X100 = god tilstand ved 30 m, X0 = skog) delt med NO_GJEN_001. Kartgrunnlag: Kartverket.") +
  theme_void() +
  theme(plot.title = element_text(face = "bold", size = 14, hjust = 0.5),
        plot.subtitle = element_text(size = 10, hjust = 0.5), plot.caption = element_text(size = 8, hjust = 0.5),
        legend.position = "right")
ggsave(file.path(img_dir, paste0("NO_GJEN_002_wetland_map", out_suffix, ".png")), national_map,
       width = 8, height = 8, dpi = 300, bg = "white")

cat("\nDone. Outputs in", normalizePath(data_dir), "and", normalizePath(img_dir), "\n")
