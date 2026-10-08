# ============================================================
# NO_FUNC_003 - final export stage: platform-format indicator maps +
# delivery tables (see the repository README, "Delivery format").
#
# Reads Stage 11's tables (../Results/) and writes, to ../Deliverables/,
# one file set per reporting set:
#
#   NO_FUNC_003_*                          the original indicator's two
#                                          3-year periods (every survey):
#                                          v_2021 = 2019-2021, v_2024 = 2022-2024
#   NO_FUNC_003_cycle1_2019to2024_*        one full ANO monitoring cycle,
#                                          FIRST survey of each plot point
#                                          only: v_2024 = 2019-2024
#   (NO_FUNC_003_cycle2_..._*              written automatically once the
#                                          pipeline's include_cycle2 is on)
#
# Each set contains:
#   <set>_indicatorMap_region.rds   5 landsdeler (primary)
#   <set>_indicatorMap_plot.rds     every scored ANO wetland plot point
#   <set>_values.csv / .xlsx        region rows + national row; sheets
#                                   metadata, plot, supp_indicators, supp_cwm_medians
#   <set>_map.png
#
# Column mapping (platform <- pipeline):
#   YYYY            <- last year of the period (documented in metadata)
#   i_YYYY          <- median over plots of fpci.min (the functional plant
#                     community index = min of the 8 scaled indicators)
#   v_YYYY          <- same value as i_YYYY. The index has no single
#                     unscaled variable: it is a "worst-rule" minimum over
#                     8 indicators that each scale a community-weighted
#                     mean (CWM) of a Tyler et al. trait against a NiN-
#                     unit-specific reference distribution. The platform's
#                     own example (naturindeks_map.rds) uses v = i for
#                     exactly this case. The underlying CWMs and the 8
#                     scaled indicators are delivered in the supp sheets.
#   sd_YYYY         <- bootstrap standard deviation (R = 1000) of the median
#                     over plots - the SE counterpart of the pipeline's
#                     bootstrap 95 % CI on the median, which is delivered
#                     as supplementary columns boot_low / boot_high
#   reference_high  <- 1 (scaled reference condition, r.s in the pipeline)
#   reference_low   <- 0 (scaled absence/extreme value, a.s)
#   thr             <- 0.6: the pipeline's scaled limit value l.s, i.e. the
#                     0.25/0.75 quantile of the reference distribution is
#                     mapped to 0.6 - a genuine X60, not the platform default
# Supplementary columns in csv/xlsx: n (plot surveys), q25, q75 (spread of
# plot values), boot_low, boot_high (95 % bootstrap CI of the median).
# ============================================================

suppressPackageStartupMessages({ library(sf); library(dplyr); library(tidyr); library(readr) })

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args <- commandArgs(trailingOnly = FALSE); fm <- grep("^--file=", cmd_args)
  if (length(fm)) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[fm]))))
}
source(file.path("..", "..", "Tools", "export_platform_format.R"))

ID      <- "NO_FUNC_003"
VERSION <- Sys.getenv("FUNC003_DELIVERY_VERSION", "000.003")
THR     <- 0.6

results_dir <- file.path("..", "Results")
spatial_dir <- file.path("..", "Data", "NINA", "spatial")
out_dir     <- file.path("..", "Deliverables")

region_names <- c("Northern" = "Nord-Norge", "Central" = "Midt-Norge", "Eastern" = "Østlandet",
                  "Western" = "Vestlandet", "Southern" = "Sørlandet")
region_ids   <- c("Nord-Norge" = 1L, "Midt-Norge" = 2L, "Østlandet" = 3L, "Vestlandet" = 4L, "Sørlandet" = 5L)

# --- inputs -----------------------------------------------------------
idx   <- read_csv(file.path(results_dir, "NO_FUNC_003_index_by_region_period.csv"), show_col_types = FALSE)
supp  <- read_csv(file.path(results_dir, "NO_FUNC_003_supp_indicators.csv"), show_col_types = FALSE)
plots <- st_read(file.path(results_dir, "NO_FUNC_003_plots.gpkg"), quiet = TRUE)
cat("Inputs:", nrow(idx), "index rows,", nrow(plots), "plot visits\n")
stopifnot(all(c("ano_punkt_id", "ano_visit") %in% names(plots)))   # rerun the pipeline if missing

regions <- st_read(file.path(spatial_dir, "regions.shp"), quiet = TRUE)
regions$region[regions$id == 3] <- "Østlandet"; regions$region[regions$id == 5] <- "Sørlandet"
regions <- regions %>% transmute(area = region, areaId = unname(region_ids[region]))

# --- reporting periods: must match the pipeline's Stage 10 `periods` ------
# 3-year periods use every survey in their years; "cycleN_AAAAtoBBBB"
# periods (detected from the pipeline output) use only visit N of each
# plot point. year = the platform's column suffix (last year of the period).
period_defs <- list(
  "2019to2021" = list(years = 2019:2021, visit = NULL, year = 2021L),
  "2022to2024" = list(years = 2022:2024, visit = NULL, year = 2024L)
)
for (p in grep("^cycle\\d+_\\d{4}to\\d{4}$", unique(idx$period), value = TRUE)) {
  m <- regmatches(p, regexec("^cycle(\\d+)_(\\d{4})to(\\d{4})$", p))[[1]]
  period_defs[[p]] <- list(years = as.integer(m[3]):as.integer(m[4]), visit = as.integer(m[2]),
                           year = as.integer(m[4]))
}
in_period <- function(dat, p) {
  keep <- dat$aar %in% p$years
  if (!is.null(p$visit)) keep <- keep & dat$ano_visit %in% p$visit
  keep
}

# --- bootstrap sd of the median, same resampling as the pipeline's CI ------
boot_sd_median <- function(x, R = 1000) {
  x <- x[!is.na(x)]
  if (length(x) < 2) return(NA_real_)
  sd(replicate(R, median(sample(x, length(x), replace = TRUE))))
}

plots_df <- plots %>% st_drop_geometry()

# --- metadata (shared fields; period-specific ones filled in per set) -----
base_metadata <- c(
  "Indicator ID"                = ID,
  "Version"                     = VERSION,
  "Indicator name (public)"     = "Funksjonelle plantegrupper i våtmark",
  "Indicator name (technical)"  = "Functional plant community index (FPCI), wetlands - minimum of eight scaled community-weighted-mean trait indicators (light, moisture, soil reaction, nitrogen; upper and lower deviation each)",
  "Ecosystem"                   = "Våtmark (wetland); IUCN GET TF1.6 Boreal/temperate bogs, TF1.7 Boreal/temperate fens",
  "ECT class"                   = "B1 - Compositional State Characteristics",
  "Spatial units delivered"     = "landsdel (5 regions, primary map), individual ANO wetland plot points; national value in the values table (area = Norge)",
  "CRS"                         = "EPSG:25833 (ETRS89 / UTM 33N)",
  "Time periods"                = NA,
  "Variable (v)"                = "Set equal to the indicator value: the FPCI has no single unscaled variable (it is the minimum over eight scaled indicators, each scaling the community-weighted mean of a Tyler et al. 2021 trait value against the reference distribution of the plot's NiN main type). Underlying CWMs (native trait units) and the eight scaled indicators are in the supp sheets",
  "Indicator (i)"               = "Median over ANO wetland plot surveys in the period of fpci.min; 1 = reference condition, 0.6 = limit of good condition",
  "Scaling function"            = "Two-sided piecewise linear per indicator: reference median -> 1, reference 0.25/0.75 quantile -> 0.6, theoretical scale extreme -> 0; deviation beyond the reference on the 'wrong' side only; values > 1 set to NA (2-sided variant). Index = minimum over the eight indicators (worst-rule). Same as the original indicator",
  "reference_high (X100)"       = "1 on the scaled axis. On the variable axis: the median of the reference CWM distribution per NiN main type (V1, V3, ...), from generalised species lists (Tyler et al. traits x NiN reference species lists) - see Fetch/build_wet_ref_openS.R",
  "reference_low (X0)"          = "0 on the scaled axis; on the variable axis the theoretical minimum/maximum of the trait scale",
  "Threshold (thr)"             = "0.6 on the indicator scale, corresponding to the 0.25 / 0.75 quantile of the reference distribution (X60 as defined in the original indicator)",
  "Uncertainty (sd)"            = "Bootstrap standard deviation (R = 1000) of the median over plot surveys. Supplementary: q25/q75 = spread of plot values; boot_low/boot_high = 95 % bootstrap CI of the median (the pipeline's own CI)",
  "Number of observations"      = NA,
  "Justification of references" = "Reference = community composition expected under the NiN definition of the main type in near-natural condition, expressed through species' trait values; a normative choice inherited from the original indicator",
  "Data sources"                = "ANO (Arealrepresentativ naturovervåking), Miljødirektoratet (open); Tyler et al. 2021 plant trait database (Ecological Indicators, doi 10.1016/j.ecolind.2020.106923); NiN generalised species lists (Artsdatabanken, open)",
  "Method note"                 = "Open-data reconstruction of the original NINA indicator NO_FUNC_003 (part of NO_FUNC_001-004 on ecRxiv). Same definitions and scaling; reference lists rebuilt from open sources at NiN main-type level",
  "Documentation"               = "https://github.com/Chimal93/wetland_condition_indicators/tree/main/NO_FUNC_003 ; original: https://github.com/NINAnor/ecRxiv/tree/main/indicators/NO_FUNC_001-004 ; https://ninanor.github.io/ecosystemCondition/functional-plant-indicators-wetland.html",
  "Column spelling note"        = "reference_high / reference_low as in the platform's example file; the platform docs and the contract text spell them referance_*",
  "Produced by"                 = "Sállir Natur AS",
  "Generated"                   = format(Sys.time(), "%Y-%m-%d %H:%M")
)

# --- export one reporting set ---------------------------------------------
export_set <- function(set_id, pnames, period_text, png_title) {
  defs <- period_defs[pnames]
  yr   <- vapply(defs, `[[`, integer(1), "year")
  stopifnot(!any(duplicated(yr)))   # one platform year column per period

  # plot surveys belonging to each period of this set (a survey can sit in
  # several sets, e.g. a 2020 first visit is in 2019to2021 and in cycle 1)
  pp <- bind_rows(lapply(pnames, function(p) plots_df[in_period(plots_df, defs[[p]]), ] %>% mutate(period = p)))

  set.seed(1)
  sd_tab <- bind_rows(
    pp %>% group_by(region, period) %>% summarise(sd = boot_sd_median(fpci.min), .groups = "drop"),
    pp %>% group_by(period) %>% summarise(region = "Norway", sd = boot_sd_median(fpci.min), .groups = "drop")
  )

  idx_long <- idx %>%
    filter(period %in% pnames) %>%
    left_join(sd_tab, by = c("region", "period")) %>%
    transmute(region, year = unname(yr[period]),
              v = median, sd = sd, i = median,
              reference_high = 1, reference_low = 0, thr = THR,
              n = n, q25 = low, q75 = high, boot_low, boot_high)

  region_long <- regions %>%
    inner_join(idx_long %>% filter(region != "Norway") %>%
                 mutate(area = unname(region_names[region])) %>% select(-region),
               by = "area") %>%
    arrange(areaId, year)

  national <- idx_long %>% filter(region == "Norway") %>%
    transmute(area = "Norge", areaId = 0L, year, v, sd, i, reference_high, reference_low, thr,
              n, q25, q75, boot_low, boot_high)

  # plot points: one value per point x period. areaId = ano_punkt_id (the
  # 1 m2 plot), NOT ano_flate_id (the site, ~5 points each) - keying on the
  # site kept only one point per site. A point surveyed twice within one
  # 3-year period keeps its latest survey.
  plot_long <- plots %>%
    filter(!is.na(fpci.min)) %>%
    { bind_rows(lapply(pnames, function(p) .[in_period(., defs[[p]]), ] %>% mutate(period = p))) } %>%
    group_by(ano_punkt_id, period) %>% slice_max(aar, n = 1, with_ties = FALSE) %>% ungroup() %>%
    transmute(area = region, areaId = as.character(ano_punkt_id), year = unname(yr[period]),
              v = fpci.min, sd = NA_real_, i = fpci.min,
              reference_high = 1, reference_low = 0, thr = THR,
              ano_flate_id = ano_flate_id, nin_unit = kartleggingsenhet_1m2,
              survey_year = aar, ano_visit = ano_visit)

  supp_wide <- supp %>%
    filter(period %in% pnames) %>%
    mutate(year = unname(yr[period]), area = ifelse(region == "Norway", "Norge", unname(region_names[region]))) %>%
    select(area, year, Indicator, median, low, high, n, boot_low, boot_high) %>%
    arrange(area, year, Indicator)
  cwm_medians <- pp %>%
    mutate(area = ifelse(is.na(region), NA, unname(region_names[region])), year = unname(yr[period])) %>%
    group_by(area, year) %>%
    summarise(across(c(cwm_Light, cwm_Moisture, cwm_pH, cwm_Nitrogen), ~ median(.x, na.rm = TRUE)),
              n_plots = n(), .groups = "drop")

  metadata <- base_metadata
  metadata[["Time periods"]] <- period_text
  metadata[["Number of observations"]] <- paste0(
    sum(!is.na(pp$fpci.min)), " ANO wetland plot surveys with an index value (",
    paste(sprintf("%s: %d", pnames, tapply(!is.na(pp$fpci.min), factor(pp$period, pnames), sum)), collapse = ", "),
    "); per-unit n in the tables")

  export_platform_indicator(
    id       = set_id,
    units    = list(region = region_long, plot = plot_long),
    national = national,
    metadata = metadata,
    out_dir  = out_dir,
    png_title = png_title
  )

  xlsx_path <- file.path(out_dir, paste0(set_id, "_values.xlsx"))
  sheets <- list(
    values = read_csv(file.path(out_dir, paste0(set_id, "_values.csv")), show_col_types = FALSE),
    metadata = tibble(field = names(metadata), value = unname(metadata)),
    plot = readRDS(file.path(out_dir, paste0(set_id, "_indicatorMap_plot.rds"))) %>% st_drop_geometry(),
    supp_indicators = supp_wide,
    supp_cwm_medians = cwm_medians
  )
  writexl::write_xlsx(sheets, xlsx_path)
  cat("  - supp sheets added to", basename(xlsx_path), "\n")
}

# --- set 1: the original indicator's two 3-year periods --------------------
export_set(
  set_id      = ID,
  pnames      = c("2019to2021", "2022to2024"),
  period_text = "Two 3-year ANO reporting periods: 2019-2021 (column suffix 2021) and 2022-2024 (suffix 2024), every plot survey in those years. ANO field seasons through 2024; no 2025 data in the export used. For one full monitoring cycle without double-counted points, see the NO_FUNC_003_cycle1_2019to2024 files",
  png_title   = "NO_FUNC_003 - Funksjonelle plantegrupper i våtmark"
)

# --- set 2+: full ANO monitoring cycles (first survey / revisit per point) --
for (p in grep("^cycle", names(period_defs), value = TRUE)) {
  d <- period_defs[[p]]
  export_set(
    set_id      = paste0(ID, "_", p),
    pnames      = p,
    period_text = paste0(
      "ANO monitoring cycle ", d$visit, ": ", min(d$years), "-", max(d$years), " (column suffix ", d$year, "). ",
      if (d$visit == 1) "Each plot point's FIRST survey only, so every point counts once; revisits are excluded"
      else paste0("Each plot point's survey number ", d$visit, " (its revisit) only"),
      ". ANO revisits points on a 5-year rotation"),
    png_title   = paste0("NO_FUNC_003 - Funksjonelle plantegrupper i våtmark, ANO-syklus ", d$visit,
                         " (", min(d$years), "-", max(d$years), ")")
  )
}
