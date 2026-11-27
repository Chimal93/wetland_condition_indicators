# ============================================================
# VAAT-NDVI-01 - NDVI (greenness) indicator, WETLAND ecosystems only
# Norwegian name: Primaerproduksjon
# Pipeline: NiN wetland polygons + regions -> join Sentinel-2/MODIS/Landsat
#           NDVI data -> data cleaning per satellite -> exploratory analysis
#           -> beta-regression modelling of NDVI ~ condition x region x
#           ecosystem type -> NDVI-over-time trend models.
#
# Extracted from https://ninanor.github.io/ecosystemCondition/NDVI-indicator-wetland.html
# (chapter 15 of the "Indicators for Ecosystem Condition in Norway" bookdown
# site, NINAnor/ecosystemCondition repo - NOT the same repo as the individual
# per-indicator ecRxiv submissions).
#
# IMPORTANT - this indicator is NOT operational, in the original or here:
# the source page repeatedly frames this as exploratory concept/method
# development, not a finished indicator. Its own "Overall conclusion"
# section states explicitly that the large overlap between condition
# classes and ecosystem types "makes it generally difficult to define
# useful scaling values for absolute NDVI values" - i.e. no X0/X100
# reference levels or sigmoid-style scaling function were ever defined,
# unlike VAAT-GJEN-01/VAAT-GJEN-02. The source's own "Export" section is a literal
# empty placeholder with no code. This script therefore stops at the same
# point the original does: cleaned data, exploratory plots, and
# statistical models testing whether NDVI correlates with condition - not
# a scaled 0-1 indicator value. See STAGE 8 below for the source's own
# concluding assessment, reproduced as a code comment for reference.
#
# Data availability (checked against this repo):
#   - data/spatial/regions.shp   PRESENT - copied from VAAT-GJEN-01/VAAT-GJEN-02/
#     VAAT-FUNC-01 (same file already reused across those folders), then
#     relabelled to the English region names this source page uses
#     ("Northern Norway" etc.) instead of the Norwegian names used elsewhere
#     ("Nord-Norge" etc.) - same five polygons, same id order, different
#     label strings only.
#   - NiN nature-type ecosystem data   NOT bundled, but PUBLICLY
#     downloadable (unlike NINA's original NO_GJEN_001/002's NiN sources, which need
#     NINA-internal server access) - Miljodirektoratet's own public
#     nedlasting.miljodirektoratet.no download service. See STAGE 4.
#   - Sentinel-2 / MODIS / Landsat NDVI data (df.s / df.m / df.l)   MISSING
#     everywhere. These are bespoke Google Earth Engine zonal-statistics
#     exports (mean NDVI per NiN polygon per available image), the same
#     kind of NINA-internal-only GEE output as NINA's original NO_GJEN_001/002's missing
#     vegHeights_skog_climZoneRegion.csv - no public substitute attempted
#     here (out of scope for this extraction; see STAGE 5's stop()
#     messages for the GEE script links if that's ever pursued).
# ============================================================

# ===========================================================
# STAGE 1: Load packages
# ===========================================================

library(sf)         # spatial objects: st_read / st_intersects / st_join
library(dplyr)      # joins, filter, mutate
library(tidyr)      # separate_rows / separate
library(readr)      # read_csv / write_csv
library(stringr)    # str_remove
library(lubridate)  # year / month / day
library(ggplot2)    # plots
library(betareg)    # beta regression for NDVI (bounded [0,1] response)

# Set working directory to the folder containing this script. Three tiers,
# in order: (1) RStudio's own API - works regardless of run style inside
# RStudio; (2) commandArgs()'s "--file=" entry - set when run as
# `Rscript path/to/file.R` directly, regardless of starting directory;
# (3) sys.frame(1)$ofile - set when run via an explicit source() call.
# See VAAT-GJEN-01_wetland_pipeline.R's Stage 1 comment for why all three
# tiers are needed (a real, reproduced failure mode, not hypothetical).
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
# All relative paths below are anchored to: Indikatorer/VAAT-NDVI-01/R/

spatial_dir <- file.path("..", "data", "spatial")
data_dir    <- file.path("..", "data")
img_dir     <- file.path("..", "outputs", "results")
if (!dir.exists(img_dir)) dir.create(img_dir, recursive = TRUE)

regionlvl <- c("Northern Norway", "Central Norway", "Eastern Norway",
                "Western Norway", "Southern Norway")


# ===========================================================
# STAGE 2: Load regions
# Present locally, relabelled to the English region names this source
# uses (the underlying polygons/id order are identical to the
# "Nord-Norge" etc. copy used in VAAT-GJEN-01/VAAT-GJEN-02/VAAT-FUNC-01).
# ===========================================================

regions_path <- file.path(spatial_dir, "regions.shp")
if (!file.exists(regions_path)) {
  stop(
    "Missing required file: ", regions_path, "\n",
    "The five-region delineation for Norway. Copies already exist in this ",
    "repo at VAAT-GJEN-01/Data/OpenS_data/regions.shp (or VAAT-FUNC-01/VAAT-GJEN-02's ",
    "data/spatial/regions.shp) - copy one in and re-run."
)
}

regions <- st_read(regions_path, quiet = TRUE)
# Same double-encoding bug documented in VAAT-GJEN-01_wetland_pipeline.R
# ("Some issues with the letter o/a" in the source .qmd) - ids 3/5 need
# fixing before relabelling by position below.
regions$region[regions$id == 3] <- "Ostlandet"
regions$region[regions$id == 5] <- "Sorlandet"
# Relabel Norwegian region names -> the English names this source page
# uses, by id (same 1:5 order confirmed against VAAT-GJEN-01's own mapping:
# 1=Nord-Norge/Northern, 2=Midt-Norge/Central, 3=Ostlandet/Eastern,
# 4=Vestlandet/Western, 5=Sorlandet/Southern).
regions <- regions %>%
  mutate(region = case_match(id,
    1 ~ "Northern Norway", 2 ~ "Central Norway", 3 ~ "Eastern Norway",
    4 ~ "Western Norway",  5 ~ "Southern Norway"
  )) %>%
  mutate(region = factor(region, levels = regionlvl))


# ===========================================================
# STAGE 3: Norway outline (for the site map in Stage 6)
# Reused from VAAT-FUNC-01's copy (outlineOfNorway_EPSG25833.shp), which is
# the exact file this source page itself reads.
# ===========================================================

outline_path <- file.path(data_dir, "outlineOfNorway_EPSG25833.shp")
norway_outline <- NULL
if (file.exists(outline_path)) {
  norway_outline <- st_read(outline_path, quiet = TRUE) %>%
    st_transform(st_crs(regions))
} else {
  message("Skipping Norway outline (used only for the site map in Stage 6): ",
          outline_path, " not found. Copy it from VAAT-FUNC-01/Data/ if needed.")
}


# ===========================================================
# STAGE 4: NiN wetland ecosystem data
# PUBLICLY downloadable (unlike NINA's original NO_GJEN_001/002's NiN source) from
# Miljodirektoratet's own download service.
# Downloaded once and cached locally; re-run with
# force_download = TRUE below to refresh.
# ===========================================================

nin_zip_url  <- "https://nedlasting.miljodirektoratet.no/Miljodata/Naturtyper_nin/FILEGDB/4326/Naturtyper_nin_0000_norge_4326_FILEGDB.zip"
nin_zip_path <- file.path(data_dir, "Naturtyper_nin_0000_norge_4326_FILEGDB.zip")
nin_gdb_dir  <- file.path(data_dir, "nin_data")
force_download <- FALSE

if (force_download || !dir.exists(nin_gdb_dir)) {
  message("Downloading national NiN nature-type dataset (large file - can take a while)...")
  if (!file.exists(nin_zip_path) || force_download) {
    download.file(nin_zip_url, destfile = nin_zip_path, mode = "wb")
  }
  unzip(nin_zip_path, exdir = nin_gdb_dir)
}

nin_gdb_path <- list.files(nin_gdb_dir, pattern = "\\.gdb$", full.names = TRUE)[1]
if (is.na(nin_gdb_path)) {
  stop(
    "Missing required data: no .gdb found in ", nin_gdb_dir, "\n",
    "Expected the extracted contents of:\n  ", nin_zip_url, "\n",
    "Download/unzip it manually into ", nin_gdb_dir, " and re-run, or set ",
    "force_download <- TRUE above."
  )
}

nin <- st_read(nin_gdb_path, layer = "naturtyper_nin_omr", quiet = TRUE)

# Column names on the public FILEGDB download were confirmed directly
# (2026-08-06, cross-referenced against VAAT-GJEN-01's already-fetched
# copy of the same national dataset) to be camelCase with real Norwegian
# characters - "hovedøkosystem", "ninKartleggingsenheter",
# "identifikasjon_lokalId" - NOT the lower-case ASCII-substituted names
# this rename block originally assumed (a real, previously-unconfirmed
# bug: this whole Stage 4 had never actually been run against real data
# before, since no NiN dataset was ever cached in this project's Data
# folder until now). With the old any_of("hovedokosystem") etc., every
# rename silently matched nothing (any_of() doesn't error on a miss),
# so downstream code referencing "hovedoekosystem" would have failed
# with "object not found" the moment this ever ran for real.
# The FILEGDB layer's active geometry column is called "SHAPE", not
# "geometry" - the original ninanor bookdown source assumes "geometry"
# throughout (Stage 6's clean_ndvi() references it directly by that
# name). Renaming here, once, so the rest of the pipeline can keep using
# the source's own naming. Found only once Stage 6 first executed
# end-to-end, via the NOT_REAL_DATA_TEST run.
nin <- nin %>% rename(geometry = SHAPE) %>% st_set_geometry("geometry")

nin <- nin %>%
  rename(
    hovedoekosystem        = hovedøkosystem,
    ninkartleggingsenheter = ninKartleggingsenheter,
    tilstand               = tilstand,
    identifikasjon_lokalid = identifikasjon_lokalId
  ) %>%
  mutate(
    # Real values confirmed directly: "våtmark", "semi-naturligMark",
    # "naturligÅpneOmråderILavlandet", "naturligÅpneOmråderUnderSkoggrensa"
    # (also "skog", "fjell", "ingen" - not targeted here, left unmapped,
    # which is fine since they never match "Vaatmark" at the Stage 4/6
    # wetland-only filter below). The original recode() source values
    # ("Vatmark"/"Vaatmark", ASCII "omrader") never matched anything in
    # the real data either - same class of bug as the column renames.
    hovedoekosystem = recode(hovedoekosystem,
      "våtmark" = "Vaatmark",
      "semi-naturligMark" = "Semi_naturlig",
      "naturligÅpneOmråderILavlandet" = "Naturlig-aapent",
      "naturligÅpneOmråderUnderSkoggrensa" = "Naturlig_aapent"
    ),
    validGeo = st_is_valid(geometry)
  )

cat("Total NiN polygons nationally:", nrow(nin), "\n")

# Drop polygons with more than one ecosystem type recorded (comma-separated
# in ninkartleggingsenheter) - there's no per-type proportion recorded, so
# these can't be reliably attributed to a single ecosystem.
nin <- nin %>% filter(!grepl(",", ninkartleggingsenheter))

nin <- nin %>%
  mutate(ninkartleggingsenheter = str_remove(ninkartleggingsenheter, "NA_")) %>%
  mutate(
    hovedtype = substr(ninkartleggingsenheter, 1, 3),
    hovedtype = str_remove(hovedtype, "-")
  )

# Real tilstand values confirmed directly (2026-08-06): lower-case with
# real Norwegian characters - "god", "moderat", "dårlig", "sværtRedusert"
# - not the capitalized ASCII values ("Darlig" etc.) this recode()
# originally assumed. That original version would have silently
# produced tilstand_num = NA for every single row (recode() passes
# unmatched values through unchanged rather than erroring), which
# drop_na(tilstand) - checking the wrong column - would never have
# caught. Recoding directly to the target string values in one step.
nin <- nin %>%
  mutate(tilstand = recode(tilstand,
    "god" = "God", "moderat" = "Moderat",
    "dårlig" = "Redusert", "sværtRedusert" = "Svaert_redusert"
  )) %>%
  mutate(tilstand_num = recode(tilstand,
    "God" = 0, "Moderat" = 1, "Redusert" = 2, "Svaert_redusert" = 3
  )) %>%
  mutate(id = identifikasjon_lokalid) %>%
  filter(validGeo) %>%
  drop_na(tilstand) %>%
  dplyr::select(id, hovedoekosystem, hovedtype, ninkartleggingsenheter,
                any_of("lokalitetskvalitet"), tilstand, tilstand_num,
                any_of("ninbeskrivelsesvariabler"), kartleggingsaar = any_of("kartleggingsår"))

# Restrict to wetlands only (this pipeline's whole scope).
nin.wetland <- nin %>% filter(hovedoekosystem == "Vaatmark")

# Assign each polygon to a region (spatial join) - source note: at least
# one polygon fell in two regions due to an imprecise coordinate; if that
# recurs here, keep only the first match per polygon.
#
# regions has its own numeric "id" column (1-5, unrelated to the NiN
# polygon "id"). st_join() doesn't join on it (this is a spatial, not
# attribute, join) - it just carries it over, and since both sides have a
# column called "id", dplyr silently renames both to id.x/id.y. That
# leaves no plain "id" column afterwards, which only breaks downstream
# (Stage 6's by = "id" full_join with NDVI data) - found via the
# NOT_REAL_DATA_TEST run, since Stage 5/6 had never previously executed.
# Fix: drop regions' own "id" before the join, since only "region" is needed.
nin.wetland <- st_join(nin.wetland %>% st_transform(st_crs(regions)),
                        regions %>% dplyr::select(-id), left = TRUE)
dup_ids <- nin.wetland$id[duplicated(nin.wetland$id)]
if (length(dup_ids) > 0) {
  message(length(dup_ids), " NiN polygon(s) matched more than one region ",
          "(likely an imprecise coordinate near a region boundary) - keeping the first match.")
  nin.wetland <- nin.wetland %>% group_by(id) %>% slice(1) %>% ungroup()
}

nin.wetland <- nin.wetland %>%
  mutate(area_meters_nin = as.numeric(st_area(nin.wetland))) %>%
  mutate(region = factor(region, levels = regionlvl))

cat("Wetland ('Vaatmark') NiN polygons:", nrow(nin.wetland), "\n")
print(table(nin.wetland$region, nin.wetland$hovedtype))


# ===========================================================
# STAGE 5: NDVI data (Sentinel-2, MODIS, Landsat)
# Sentinel-2 and Landsat are NOT bundled with the repo - bespoke Google Earth
# Engine zonal-statistics exports (mean NDVI per NiN polygon per available
# cloud-free image), same NINA-internal-only situation as NINA's original NO_GJEN_001/002's
# missing vegHeights_skog_climZoneRegion.csv. Expected locations once obtained:
#   data/NDVI_Sentinel/*.csv  (42 files, gridded exports)
#   data/NDVI_Landsat/*.csv   (42 files, gridded exports)
# GEE scripts (may or may not be publicly viewable - untested here):
#   Sentinel-2: https://code.earthengine.google.com/2ceb0c3e03adade9e6f6d0903184b8c4
#   Landsat:    https://code.earthengine.google.com/da8a9279238ef26d14be08a43788b6b7
#
# MODIS is fetched here entirely GEE-free instead (fetch_modis_ndvi.R): CMR
# granule search + Earthdata Cloud HTTPS (bearer token) + curl.exe + GDAL
# HDF4, national wetland set, growing-season composites, 2000-2026.
#   data/NDVI_MODIS/modis_ndvi_ts_national.csv
# ===========================================================

sentinel_dir <- file.path(data_dir, "NDVI_Sentinel")
modis_path   <- file.path(data_dir, "NDVI_MODIS", "modis_ndvi_ts_national.csv")
landsat_dir  <- file.path(data_dir, "NDVI_Landsat")

.stop_missing_ndvi <- function(what, path, gee_url) {
  stop(
    "Missing required data: ", what, " NDVI export not found at:\n  ", path, "\n",
    "This is a bespoke Google Earth Engine zonal-statistics output, only ",
    "available on NINA's internal P: drive (mirrors NINA's original NO_GJEN_001/002's missing ",
    "vegHeights_skog_climZoneRegion.csv situation - see that pipeline's Stage 4 ",
    "comments for the general pattern). GEE script (access untested): ", gee_url, "\n",
    "Copy the export(s) into the path above and re-run."
  )
}

if (!dir.exists(sentinel_dir) || length(list.files(sentinel_dir, pattern = "\\.csv$")) == 0) {
  .stop_missing_ndvi("Sentinel-2", sentinel_dir,
    "https://code.earthengine.google.com/2ceb0c3e03adade9e6f6d0903184b8c4")
}
if (!file.exists(modis_path)) {
  .stop_missing_ndvi("MODIS", modis_path,
    "https://code.earthengine.google.com/efb84013701f1d5f6e1e81345f389b84")
}
if (!dir.exists(landsat_dir) || length(list.files(landsat_dir, pattern = "\\.csv$")) == 0) {
  .stop_missing_ndvi("Landsat", landsat_dir,
    "https://code.earthengine.google.com/da8a9279238ef26d14be08a43788b6b7")
}

df.s <- list.files(sentinel_dir, pattern = "\\.csv$", full.names = TRUE) %>%
  purrr::map_df(readr::read_csv, show_col_types = FALSE)

df.m <- read_csv(modis_path, show_col_types = FALSE) %>%
  mutate(mean = mean / 10000)  # MODIS NDVI is scaled by 0.0001

df.l <- list.files(landsat_dir, pattern = "\\.csv$", full.names = TRUE) %>%
  purrr::map_df(readr::read_csv, show_col_types = FALSE)


# ===========================================================
# STAGE 6: Data cleaning per satellite (shared logic)
# Mirrors the source's three near-identical cleaning blocks (Sentinel/
# MODIS/Landsat) - written once here as a function of the satellite's
# pixel resolution, since the steps are otherwise identical: join to
# nin.wetland, drop non-matches, drop NiN polygons smaller than one pixel,
# parse the image date, keep only the MAXIMUM NDVI per polygon per year
# (i.e. peak-of-growing-season greenness).
# min_area_m2: Sentinel-2 (10x10m) = 100, MODIS (250x250m) = 62500,
# Landsat (30x30m) = 900 - the satellite's own pixel footprint.
# ===========================================================

clean_ndvi <- function(nin_wetland, ndvi_df, min_area_m2) {
  out <- full_join(nin_wetland, ndvi_df, by = "id") %>%
    mutate(area_meters = as.numeric(st_area(geometry))) %>%
    filter(!is.na(hovedtype), !is.na(mean)) %>%
    filter(area_meters >= min_area_m2) %>%
    mutate(
      year  = lubridate::year(date),
      month = lubridate::month(date),
      day   = lubridate::day(date),
      subtype = str_remove(str_remove(substring(ninkartleggingsenheter, 4), "-"), "-")
    ) %>%
    group_by(id, year) %>%
    filter(mean == max(mean, na.rm = TRUE)) %>%
    ungroup()
  out
}

SentinelNDVI.wetland <- clean_ndvi(nin.wetland, df.s, min_area_m2 = 100)
# 2022 excluded per the source's own exploratory check: that year is
# missing its highest NDVI values (a data-completeness artefact, not a
# real ecological signal).
SentinelNDVI.wetland <- SentinelNDVI.wetland %>% filter(year != 2022)

ModisNDVI.wetland  <- clean_ndvi(nin.wetland, df.m, min_area_m2 = 62500)
LandsatNDVI.wetland <- clean_ndvi(nin.wetland, df.l, min_area_m2 = 900)

cat("Cleaned Sentinel-2 wetland NDVI rows:", nrow(SentinelNDVI.wetland), "\n")
cat("Cleaned MODIS wetland NDVI rows:",      nrow(ModisNDVI.wetland),  "\n")
cat("Cleaned Landsat wetland NDVI rows:",    nrow(LandsatNDVI.wetland), "\n")


# ===========================================================
# STAGE 7: Exploratory analysis (Sentinel-2 - the source's primary focus,
# given its resolution is the best match to wetland polygon sizes)
# Mirrors the source's "Exploratory analyses, Sentinel-2" section.
# ===========================================================

if (!is.null(norway_outline)) {
  site_map <- ggplot() +
    geom_sf(data = norway_outline, fill = NA, color = "black") +
    geom_sf(data = SentinelNDVI.wetland, aes(color = hovedtype), size = 0.6, alpha = 0.6) +
    theme_void() +
    ggtitle("Wetland ecosystem sites (NiN, Miljodirektoratets instruks)") +
    labs(color = "Major\necosystem type")

  ggsave(file.path(img_dir, "VAAT-NDVI-01_wetland_siteMap.png"),
         site_map, width = 7, height = 9, dpi = 300, bg = "white")
}

size_hist <- SentinelNDVI.wetland %>%
  st_drop_geometry() %>%
  ggplot(aes(x = area_meters)) +
  geom_histogram(bins = 60) +
  coord_cartesian(xlim = c(0, 20000)) +
  geom_vline(xintercept = 100, linetype = "dashed") +
  labs(title = "Wetland ecosystem polygon sizes", x = "Area (sqm)", y = "Count")

ggsave(file.path(img_dir, "VAAT-NDVI-01_wetland_sizeHistogram.png"),
       size_hist, width = 7, height = 5, dpi = 300, bg = "white")

ndvi_over_time <- SentinelNDVI.wetland %>%
  st_drop_geometry() %>%
  ggplot(aes(x = year, y = mean)) +
  geom_point() +
  facet_grid(tilstand ~ hovedtype) +
  theme(axis.text.x = element_text(angle = -45, vjust = 0.5, hjust = 0.2)) +
  ggtitle("NDVI across years for different ecosystem types in all condition classes") +
  labs(y = "NDVI values (Sentinel-2)", x = "Year")

ggsave(file.path(img_dir, "VAAT-NDVI-01_wetland_ndviOverTime.png"),
       ndvi_over_time, width = 9, height = 7, dpi = 300, bg = "white")

# Good-condition-only view, matching NiN-mapping year, faceted by ecosystem
# type and region.
good_condition_dat <- SentinelNDVI.wetland %>%
  st_drop_geometry() %>%
  filter(tilstand == "God", year == kartleggingsaar)

ndvi_by_type <- good_condition_dat %>%
  ggplot(aes(x = hovedtype, y = mean)) +
  geom_violin() +
  geom_point(size = 0.7, color = "grey", position = position_jitter(0.1)) +
  ggtitle("NDVI for different ecosystem types in good condition") +
  labs(y = "NDVI values (Sentinel-2)", x = "Major ecosystem type")

ggsave(file.path(img_dir, "VAAT-NDVI-01_wetland_ndviByType.png"),
       ndvi_by_type, width = 7, height = 5, dpi = 300, bg = "white")

ndvi_by_condition <- SentinelNDVI.wetland %>%
  st_drop_geometry() %>%
  filter(year == kartleggingsaar) %>%
  ggplot(aes(x = tilstand, y = mean)) +
  geom_violin() +
  geom_point(size = 0.7, color = "grey", position = position_jitter(0.1)) +
  facet_wrap(~hovedtype) +
  theme(axis.text.x = element_text(angle = -45, vjust = 0.5, hjust = 0.2)) +
  ggtitle("NDVI for different ecosystems in different condition classes") +
  labs(y = "NDVI values (Sentinel-2)", x = "Condition")

ggsave(file.path(img_dir, "VAAT-NDVI-01_wetland_ndviByCondition.png"),
       ndvi_by_condition, width = 8, height = 6, dpi = 300, bg = "white")


# ===========================================================
# STAGE 8: Beta-regression modelling, Sentinel-2
# NDVI is bounded [-1, 1]; rescaled to (0, 1) for beta regression
# (mean_beta = (mean + 1) / 2), matching the source exactly. V4 (cold
# springs) is dropped from modelling - too sparse across region x
# condition combinations to fit reliably (source's own finding).
#
# NOTE on StepBeta(): the source calls a stepwise-selection helper
# `StepBeta()` on the fitted betareg model to find the most parsimonious
# term set. That function's definition is NOT shown anywhere in the
# source page (likely from a helper script sourced elsewhere, similar to
# how other indicators' `_common.R` isn't part of the rendered report) -
# it is not reproduced here. The full three-way interaction model is kept
# below instead; drop non-significant terms manually by inspecting
# summary(model)$coefficients if a more parsimonious model is wanted.
# ===========================================================

SentinelNDVI.wetland <- SentinelNDVI.wetland %>%
  mutate(mean_beta = (mean + 1) / 2)

sentinel_train <- SentinelNDVI.wetland %>%
  st_drop_geometry() %>%
  filter(year == kartleggingsaar, hovedtype != "V4", !is.na(region))

model.wetland.cond.Sent <- betareg(
  mean_beta ~ tilstand_num * region * hovedtype,
  data = sentinel_train
)
cat("\n=== National Sentinel-2 model (NDVI ~ condition x region x ecosystem type) ===\n")
print(summary(model.wetland.cond.Sent)$coefficients$mean)

# Per-region models (source repeats the same national-model call, filtered
# to one region at a time, for all five regions) - written as a loop here
# rather than five near-identical blocks.
regional_models <- list()
for (rgn in regionlvl) {
  dat_r <- sentinel_train %>% filter(region == rgn)
  if (nrow(dat_r) == 0 || length(unique(dat_r$tilstand_num)) < 2) {
    message("Skipping regional model for ", rgn, ": insufficient data.")
    next
  }
  m <- tryCatch(
    betareg(mean_beta ~ tilstand_num * hovedtype, data = dat_r),
    error = function(e) { message(rgn, ": ", conditionMessage(e)); NULL }
  )
  if (!is.null(m)) regional_models[[rgn]] <- m
}

for (rgn in names(regional_models)) {
  cat("\n===", rgn, "===\n")
  print(summary(regional_models[[rgn]])$coefficients$mean)
}


# ===========================================================
# STAGE 9: NDVI-over-time trend models, semi-natural wetlands (V9, V10)
# The source highlights V9/V10 specifically: reduced condition in these
# types is linked to declining land-use intensity (undergrazing/undermowing),
# for which a rising NDVI trend over time is ecologically expected. Fits
# NDVI ~ year * condition per satellite, restricted to V9/V10.
# ===========================================================

fit_time_trend <- function(ndvi_df, label) {
  dat <- ndvi_df %>%
    st_drop_geometry() %>%
    filter(hovedtype %in% c("V9", "V10")) %>%
    mutate(mean_beta = (mean + 1) / 2)
  if (nrow(dat) == 0) {
    message("Skipping ", label, " time-trend model: no V9/V10 data.")
    return(NULL)
  }
  betareg(mean_beta ~ year * tilstand, data = dat)
}

model.wetland.time.tilst.V9V10.Sent <- fit_time_trend(SentinelNDVI.wetland, "Sentinel-2")
model.wetland.time.tilst.V9V10.Modi <- fit_time_trend(ModisNDVI.wetland, "MODIS")
model.wetland.time.tilst.V9V10.Land <- fit_time_trend(LandsatNDVI.wetland, "Landsat")

for (nm in c("Sent", "Modi", "Land")) {
  m <- get(paste0("model.wetland.time.tilst.V9V10.", nm))
  if (!is.null(m)) {
    cat("\n=== NDVI-over-time trend, V9/V10,", nm, "===\n")
    print(summary(m)$coefficients$mean)
  }
}


# ===========================================================
# STAGE 10: Overall conclusion (from the source, reproduced as reference -
# not code, since no scaling/indicator step exists to run)
#
# NDVI in wetland ecosystems does vary with condition and ecosystem type,
# but overlap between condition classes and ecosystem types is large.
# Semi-natural wetlands (V9, V10) show the clearest, most consistent
# pattern: higher NDVI and a stronger positive NDVI-over-time trend in
# sites with reduced condition, consistent with declining land-use
# intensity (undergrazing, succession, shrub/tree encroachment) as the
# main pressure in these types. Minerotrophic fens (V1) show an
# inconsistent, region-dependent pattern (increasing NDVI with reduced
# condition in the South, decreasing in the North) tentatively linked to
# regional variation in Nitrogen deposition, though this is not confirmed.
# Ombrotrophic bogs (V3) show no consistent pattern.
#
# The source concludes the large overlap "makes it generally difficult to
# define useful scaling values for absolute NDVI values" and suggests that
# a trend-based scaling approach (as used for the mountain NDVI indicator,
# Framstad et al. 2022) may be more viable than absolute-value scaling -
# but does not implement one for wetlands. Two structural blockers are
# named as needing to be resolved before this can become an operational
# indicator: (1) no national wetland ecosystem map exists, so the NiN
# occurrence sample used here cannot be considered spatially
# representative; (2) NDVI in wetland ecosystems lacks the ecological
# ground-truthing available for other ecosystem types (forests, tundra),
# so the meaning of an NDVI deviation is not yet well understood, in part
# because of confounding factors like moss moisture content.
# ===========================================================

cat("\nDone. This pipeline stops at exploratory/statistical analysis, matching\n",
    "the source page's own status - no scaled 0-1 indicator value exists to export.\n",
    "See Stage 10's comment block for the source's own concluding assessment.\n", sep = "")
