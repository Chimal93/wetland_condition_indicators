# ============================================================
# NO_CONN_001 - final export stage: platform-format indicator maps +
# delivery tables (see the repository README, "Delivery format").
#
# Reads Fetch/scale_and_map_connectivity_indicator.R's write-out
# (Data/connectivity_scored/*_<label>.*) and writes, to ../Deliverables/:
#   NO_CONN_001_indicatorMap_region.rds    5 landsdeler (primary)
#   NO_CONN_001_indicatorMap_polygon.rds   every scored mire polygon (large)
#   NO_CONN_001_values.csv / .xlsx         region rows + national row; metadata
#   NO_CONN_001_map.png
#
# Column mapping (platform <- pipeline):
#   YYYY            <- 2023 (N50 infrastructure vintage used for the run)
#   i_YYYY          <- index: per polygon, log(kvotient) linearly scaled
#                     between the 1st and 99th percentile anchors and
#                     truncated to [0, 1]; kvotient = NA (no infrastructure
#                     within 1000 m) -> 1; kvotient = 0 (infrastructure
#                     touches the mire) -> 0; kvotient = Inf (topology
#                     artefact) -> excluded. Units: area-weighted mean.
#   v_YYYY          <- kvotient = min_infra_distance / min_myr_distance
#                     (dimensionless ratio). Polygon level: the raw value
#                     (NA where no infrastructure within 1000 m). Region /
#                     national: area-weighted GEOMETRIC mean over the
#                     finite, non-zero polygons (the ratio is log-normal-
#                     like; an arithmetic mean is dominated by the tail).
#                     The anchored cases (NA -> 1, 0 -> 0) enter i but not v.
#   sd_YYYY         <- bootstrap standard deviation (R = 1000) of the
#                     area-weighted mean index, resampling (index, area)
#                     pairs - the SE counterpart of the pipeline's 95 % CI,
#                     delivered as supplementary boot_low / boot_high
#   reference_high  <- X100 on the variable scale: kvotient at the 99th
#                     percentile of log(kvotient) (177.7 in this run)
#   reference_low   <- X0: kvotient at the 1st percentile (0.141)
#   thr             <- 0.6 on the indicator scale (platform default; the
#                     original work only mentions a "tentative 0.6")
# Supplementary in csv/xlsx: n (polygons with an index), n_scaled
# (finite non-zero kvotient), n_ref (no infra within 1000 m -> 1),
# n_zero (touching -> 0), boot_low, boot_high, area_km2.
# ============================================================

suppressPackageStartupMessages({ library(sf); library(dplyr); library(readr) })

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args <- commandArgs(trailingOnly = FALSE); fm <- grep("^--file=", cmd_args)
  if (length(fm)) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[fm]))))
}
source(file.path("..", "..", "Tools", "export_platform_format.R"))

ID        <- "NO_CONN_001"
VERSION   <- Sys.getenv("CONN001_DELIVERY_VERSION", "000.001")
DATA_YEAR <- as.integer(Sys.getenv("CONN001_DATA_YEAR", "2023"))
LABEL     <- Sys.getenv("CONNECTIVITY_SCORE_LABEL", "national_2023")
THR       <- 0.6
WRITE_POLYGON_MAP <- tolower(Sys.getenv("CONN001_POLYGON_MAP", "true")) == "true"

scored_dir  <- file.path("..", "Data", "connectivity_scored")
spatial_dir <- file.path("..", "Data", "spatial")
out_dir     <- file.path("..", "Deliverables")

regionlvl  <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
region_ids <- c("Nord-Norge" = 1L, "Midt-Norge" = 2L, "Østlandet" = 3L, "Vestlandet" = 4L, "Sørlandet" = 5L)

# --- inputs -----------------------------------------------------------
anchors <- read_csv(file.path(scored_dir, paste0("anchors_", LABEL, ".csv")), show_col_types = FALSE)
reg_agg <- read_csv(file.path(scored_dir, paste0("region_agg_", LABEL, ".csv")), show_col_types = FALSE)
mire    <- st_read(file.path(scored_dir, paste0("mire_scored_", LABEL, ".gpkg")), quiet = TRUE)
cat("Inputs:", nrow(mire), "polygons; anchors X0 =", round(anchors$X0_kvotient, 4),
    "X100 =", round(anchors$X100_kvotient, 2), "\n")

regions <- st_read(file.path(spatial_dir, "regions.shp"), quiet = TRUE)
regions$region[regions$id == 3] <- "Østlandet"; regions$region[regions$id == 5] <- "Sørlandet"
regions <- regions %>% transmute(area = region, areaId = unname(region_ids[region]))

mire <- mire %>% filter(!is.na(index)) %>% st_transform(st_crs(regions))
mire$area_m2 <- as.numeric(st_area(mire))
# region membership as in the pipeline (st_join regions -> polygons)
mire_reg <- regions %>% st_join(mire %>% select(mire_id, index, kvotient, index_note, area_m2)) %>%
  st_drop_geometry() %>% filter(!is.na(index))
cat("Polygons assigned to regions:", nrow(mire_reg), "\n")

# --- per-unit summaries -----------------------------------------------------
set.seed(1)
boot_sd_wmean <- function(index, area, R = 1000) {
  n <- length(index); if (n < 2) return(NA_real_)
  sd(vapply(seq_len(R), function(i) { k <- sample.int(n, n, replace = TRUE); weighted.mean(index[k], area[k]) }, numeric(1)))
}
summarise_unit <- function(d) {
  fin <- is.finite(d$kvotient) & d$kvotient > 0
  tibble(
    v  = exp(weighted.mean(log(d$kvotient[fin]), d$area_m2[fin])),
    sd = boot_sd_wmean(d$index, d$area_m2),
    i  = weighted.mean(d$index, d$area_m2),
    n = nrow(d), n_scaled = sum(fin), n_ref = sum(is.na(d$kvotient)),
    n_zero = sum(!is.na(d$kvotient) & d$kvotient == 0),
    area_km2 = sum(d$area_m2) / 1e6
  )
}
cat("Bootstrapping unit sd (R = 1000)...\n")
unit_stats <- mire_reg %>% group_by(area) %>% group_modify(~ summarise_unit(.x)) %>% ungroup()
nat_stats  <- summarise_unit(mire_reg)

# consistency check against the pipeline's own regional aggregation
chk <- unit_stats %>% inner_join(reg_agg %>% select(region, index_pipeline = index, boot_low, boot_high), by = c("area" = "region"))
stopifnot(all(abs(chk$i - chk$index_pipeline) < 1e-6))

region_long <- regions %>%
  inner_join(chk %>% transmute(area, year = DATA_YEAR, v, sd, i,
                               reference_high = anchors$X100_kvotient, reference_low = anchors$X0_kvotient, thr = THR,
                               n, n_scaled, n_ref, n_zero, boot_low, boot_high, area_km2), by = "area") %>%
  arrange(areaId)

set.seed(1)
nat_boot <- {
  n <- nrow(mire_reg)
  vapply(seq_len(1000), function(i) { k <- sample.int(n, n, replace = TRUE); weighted.mean(mire_reg$index[k], mire_reg$area_m2[k]) }, numeric(1))
}
national <- nat_stats %>%
  transmute(area = "Norge", areaId = 0L, year = DATA_YEAR, v, sd, i,
            reference_high = anchors$X100_kvotient, reference_low = anchors$X0_kvotient, thr = THR,
            n, n_scaled, n_ref, n_zero,
            boot_low = as.numeric(quantile(nat_boot, 0.025)), boot_high = as.numeric(quantile(nat_boot, 0.975)),
            area_km2)

units <- list(region = region_long)
if (WRITE_POLYGON_MAP) {
  units$polygon <- mire %>%
    transmute(area = "polygon", areaId = as.character(mire_id), year = DATA_YEAR,
              v = ifelse(is.finite(kvotient), kvotient, NA_real_), sd = NA_real_, i = index,
              reference_high = anchors$X100_kvotient, reference_low = anchors$X0_kvotient, thr = THR,
              index_note = index_note)
  # areaId must be unique per polygon; mire_id repeats across regional files
  units$polygon$areaId <- paste0(units$polygon$areaId, "_", seq_len(nrow(units$polygon)))
}

metadata <- c(
  "Indicator ID"                = ID,
  "Version"                     = VERSION,
  "Indicator name (public)"     = "Konnektivitet i våtmark",
  "Indicator name (technical)"  = "Wetland connectivity - distance to nearest infrastructure relative to distance to nearest other mire (kvotient), scaled 0-1",
  "Ecosystem"                   = "Våtmark (wetland); IUCN GET TF1.6 Boreal/temperate bogs, TF1.7 Boreal/temperate fens",
  "ECT class"                   = "C1 - Landscape and Seascape Characteristics",
  "Spatial units delivered"     = "landsdel (5 regions, primary map), individual mire polygons; national value in the values table (area = Norge)",
  "CRS"                         = "EPSG:25833 (ETRS89 / UTM 33N)",
  "Data year label"             = paste0(DATA_YEAR, ": N50 infrastructure and land-use-intensity layers of 2023; mire polygons from the national mire probability model (MyrMod2Rv, simplified) and NiN"),
  "Variable (v)"                = "kvotient = min_infra_distance / min_myr_distance per mire polygon (dimensionless). Infrastructure = N50 objects with land-use intensity > 2, searched within 1000 m; nearest other mire searched without limit. Region/national v = area-weighted geometric mean over polygons with finite, non-zero kvotient; polygons without infrastructure within 1000 m (v = NA) enter the index as 1 and polygons touched by infrastructure (v = 0) as 0",
  "Indicator (i)"               = "log(kvotient) scaled linearly between reference_low and reference_high and truncated to [0, 1]; defined anchors for the NA and 0 cases as above; Inf (topology artefacts, touching mires) excluded. Units: area-weighted mean over polygons",
  "Scaling function"            = "Linear on log(kvotient), truncated; no sigmoid. Percentile anchors (1st / 99th) computed from the national run itself (n = 97,072 finite non-zero values), following the aggregation framework of Kolstad et al. (in prep). The original indicator never finalised a scaling function (ecosystemCondition issue #144); this is our reconstruction",
  "reference_high (X100)"       = paste0("kvotient = ", round(anchors$X100_kvotient, 2), " (99th percentile of log kvotient): infrastructure ~178x farther than the nearest mire"),
  "reference_low (X0)"          = paste0("kvotient = ", round(anchors$X0_kvotient, 4), " (1st percentile): infrastructure ~7x closer than the nearest mire"),
  "Threshold (thr)"             = "0.6 on the indicator scale = platform default; the original work mentions only a tentative 0.6",
  "Uncertainty (sd)"            = "Bootstrap standard deviation (R = 1000) of the area-weighted mean index, resampling (index, area) pairs. Supplementary boot_low / boot_high = 95 % bootstrap CI (the pipeline's own). Polygon level: not applicable",
  "Number of observations"      = paste0(nrow(mire_reg), " mire polygons with an index value (", nat_stats$n_scaled, " scaled, ", nat_stats$n_ref, " reference-anchored, ", nat_stats$n_zero, " zero-anchored); total mire area ", round(nat_stats$area_km2), " km2"),
  "Coverage caveat"             = "The national mire probability map (MyrMod2Rv) covers Norway only to ~64 N. South of that, mire polygons come from the map + NiN; Nord-Norge is NiN-mapped mires ONLY (4,917 polygons, sparse, 48.6 % with infrastructure within 1000 m) and Midt-Norge is partially covered. Nord-Norge's value (0.65) therefore describes a different, much smaller and more human-proximate polygon population than the other regions' (0.96-0.98) and is not comparable to them; the national row is dominated by the four southern regions",
  "Justification of references" = "Data-driven anchors at the 1st/99th percentiles of the national log-ratio distribution, plus two defined ('natural zero') anchors: no infrastructure within 1000 m = reference condition, infrastructure touching the mire = complete disruption",
  "Data sources"                = "Kartverket N50 (open); Miljødirektoratet mire probability model MyrMod2Rv; NiN nature types (open); NVE regulated lakes (open); regions.shp",
  "Method note"                 = "Reconstruction of NINA's connectivity indicator (Bakkestuen; GEE workflow not public). Distance computations reproduced in R on the certified nearest-neighbour algorithm; scaling and regional aggregation are ours (see Scaling function)",
  "Documentation"               = "https://github.com/Chimal93/wetland_condition_indicators/tree/main/NO_CONN_001 ; original: https://ninanor.github.io/ecosystemCondition/connectivity.html",
  "Column spelling note"        = "reference_high / reference_low as in the platform's example file; the platform docs and the contract text spell them referance_*",
  "Produced by"                 = "Sállir Natur AS",
  "Generated"                   = format(Sys.time(), "%Y-%m-%d %H:%M")
)

export_platform_indicator(
  id       = ID,
  units    = units,
  national = national,
  metadata = metadata,
  out_dir  = out_dir,
  png_title = "NO_CONN_001 - Konnektivitet i våtmark"
)
