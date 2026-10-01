# ============================================================
# NO_FUNC_003 - final export stage: platform-format indicator maps +
# delivery tables (see the repository README, "Delivery format").
#
# Reads Stage 11's tables (../Results/) and writes, to
# ../Deliverables/:
#   NO_FUNC_003_indicatorMap_region.rds   5 landsdeler x 2 periods (primary):
#                                         v_2021/sd_2021/i_2021 and v_2024/sd_2024/i_2024
#   NO_FUNC_003_indicatorMap_plot.rds     every ANO wetland plot (points), same columns
#   NO_FUNC_003_values.csv / .xlsx        region rows + national row; sheets
#                                         metadata, plot, supp_indicators
#   NO_FUNC_003_map.png
#
# Column mapping (platform <- pipeline):
#   YYYY            <- last year of each 3-year ANO period: 2021 = 2019-2021,
#                     2024 = 2022-2024 (documented in metadata)
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
# Supplementary columns in csv/xlsx: n (plot visits), q25, q75 (spread of
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
VERSION <- Sys.getenv("FUNC003_DELIVERY_VERSION", "000.002")
THR     <- 0.6
periods <- c("2019to2021" = 2021L, "2022to2024" = 2024L)   # period -> year label

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

regions <- st_read(file.path(spatial_dir, "regions.shp"), quiet = TRUE)
regions$region[regions$id == 3] <- "Østlandet"; regions$region[regions$id == 5] <- "Sørlandet"
regions <- regions %>% transmute(area = region, areaId = unname(region_ids[region]))

# --- bootstrap sd of the median, same resampling as the pipeline's CI ------
boot_sd_median <- function(x, R = 1000) {
  x <- x[!is.na(x)]
  if (length(x) < 2) return(NA_real_)
  sd(replicate(R, median(sample(x, length(x), replace = TRUE))))
}
set.seed(1)
plots_df <- plots %>% st_drop_geometry() %>%
  mutate(period = case_when(aar %in% 2019:2021 ~ "2019to2021", aar %in% 2022:2024 ~ "2022to2024"))
sd_tab <- bind_rows(
  plots_df %>% filter(!is.na(period)) %>% group_by(region, period) %>%
    summarise(sd = boot_sd_median(fpci.min), .groups = "drop"),
  plots_df %>% filter(!is.na(period)) %>% group_by(period) %>%
    summarise(region = "Norway", sd = boot_sd_median(fpci.min), .groups = "drop")
)

# --- region (primary) + national row ------------------------------------
idx_long <- idx %>%
  left_join(sd_tab, by = c("region", "period")) %>%
  transmute(region, year = unname(periods[period]),
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

# --- plots (points) -----------------------------------------------------------
plot_long <- plots %>%
  mutate(period = case_when(aar %in% 2019:2021 ~ "2019to2021", aar %in% 2022:2024 ~ "2022to2024")) %>%
  filter(!is.na(period), !is.na(fpci.min)) %>%
  # one value per plot x period (a plot revisited within the same period is rare; keep the latest)
  group_by(ano_flate_id, period) %>% slice_max(aar, n = 1, with_ties = FALSE) %>% ungroup() %>%
  transmute(area = region, areaId = as.character(ano_flate_id), year = unname(periods[period]),
            v = fpci.min, sd = NA_real_, i = fpci.min,
            reference_high = 1, reference_low = 0, thr = THR,
            nin_unit = kartleggingsenhet_1m2, survey_year = aar, ano_round = ano_round)

# --- supplementary: the 8 underlying scaled indicators + raw CWM medians ---------
supp_wide <- supp %>%
  mutate(year = unname(periods[period]), area = ifelse(region == "Norway", "Norge", unname(region_names[region]))) %>%
  select(area, year, Indicator, median, low, high, n, boot_low, boot_high) %>%
  arrange(area, year, Indicator)
cwm_medians <- plots_df %>% filter(!is.na(period)) %>%
  mutate(area = ifelse(is.na(region), NA, unname(region_names[region])), year = unname(periods[period])) %>%
  group_by(area, year) %>%
  summarise(across(c(cwm_Light, cwm_Moisture, cwm_pH, cwm_Nitrogen), ~ median(.x, na.rm = TRUE)),
            n_plots = n(), .groups = "drop")

# --- metadata ---------------------------------------------------------------
n_plots_total <- nrow(plots_df %>% filter(!is.na(period), !is.na(fpci.min)))
metadata <- c(
  "Indicator ID"                = ID,
  "Version"                     = VERSION,
  "Indicator name (public)"     = "Funksjonelle plantegrupper i våtmark",
  "Indicator name (technical)"  = "Functional plant community index (FPCI), wetlands - minimum of eight scaled community-weighted-mean trait indicators (light, moisture, soil reaction, nitrogen; upper and lower deviation each)",
  "Ecosystem"                   = "Våtmark (wetland); IUCN GET TF1.6 Boreal/temperate bogs, TF1.7 Boreal/temperate fens",
  "ECT class"                   = "B1 - Compositional State Characteristics",
  "Spatial units delivered"     = "landsdel (5 regions, primary map), individual ANO wetland plots (points); national value in the values table (area = Norge)",
  "CRS"                         = "EPSG:25833 (ETRS89 / UTM 33N)",
  "Time periods"                = "Two 3-year ANO reporting periods: 2019-2021 (column suffix 2021) and 2022-2024 (suffix 2024). ANO field seasons through 2024; no 2025 data in the export used",
  "Variable (v)"                = "Set equal to the indicator value: the FPCI has no single unscaled variable (it is the minimum over eight scaled indicators, each scaling the community-weighted mean of a Tyler et al. 2021 trait value against the reference distribution of the plot's NiN main type). Underlying CWMs (native trait units) and the eight scaled indicators are in the supp sheets",
  "Indicator (i)"               = "Median over ANO wetland plot visits in the period of fpci.min; 1 = reference condition, 0.6 = limit of good condition",
  "Scaling function"            = "Two-sided piecewise linear per indicator: reference median -> 1, reference 0.25/0.75 quantile -> 0.6, theoretical scale extreme -> 0; deviation beyond the reference on the 'wrong' side only; values > 1 set to NA (2-sided variant). Index = minimum over the eight indicators (worst-rule). Same as the original indicator",
  "reference_high (X100)"       = "1 on the scaled axis. On the variable axis: the median of the reference CWM distribution per NiN main type (V1, V3, ...), from generalised species lists (Tyler et al. traits x NiN reference species lists) - see Fetch/build_wet_ref_openS.R",
  "reference_low (X0)"          = "0 on the scaled axis; on the variable axis the theoretical minimum/maximum of the trait scale",
  "Threshold (thr)"             = "0.6 on the indicator scale, corresponding to the 0.25 / 0.75 quantile of the reference distribution (X60 as defined in the original indicator)",
  "Uncertainty (sd)"            = "Bootstrap standard deviation (R = 1000) of the median over plot visits. Supplementary: q25/q75 = spread of plot values; boot_low/boot_high = 95 % bootstrap CI of the median (the pipeline's own CI)",
  "Number of observations"      = paste0(n_plots_total, " ANO wetland plot visits with an index value across both periods; per-unit n in the tables"),
  "Justification of references" = "Reference = community composition expected under the NiN definition of the main type in near-natural condition, expressed through species' trait values; a normative choice inherited from the original indicator",
  "Data sources"                = "ANO (Arealrepresentativ naturovervåking), Miljødirektoratet (open); Tyler et al. 2021 plant trait database (Ecological Indicators, doi 10.1016/j.ecolind.2020.106923); NiN generalised species lists (Artsdatabanken, open)",
  "Method note"                 = "Open-data reconstruction of the original NINA indicator NO_FUNC_003 (part of NO_FUNC_001-004 on ecRxiv). Same definitions and scaling; reference lists rebuilt from open sources at NiN main-type level",
  "Documentation"               = "https://github.com/Chimal93/wetland_condition_indicators/tree/main/NO_FUNC_003 ; original: https://github.com/NINAnor/ecRxiv/tree/main/indicators/NO_FUNC_001-004 ; https://ninanor.github.io/ecosystemCondition/functional-plant-indicators-wetland.html",
  "Column spelling note"        = "reference_high / reference_low as in the platform's example file; the platform docs and the contract text spell them referance_*",
  "Produced by"                 = "Sállir Natur AS",
  "Generated"                   = format(Sys.time(), "%Y-%m-%d %H:%M")
)

written <- export_platform_indicator(
  id       = ID,
  units    = list(region = region_long, plot = plot_long),
  national = national,
  metadata = metadata,
  out_dir  = out_dir,
  png_title = "NO_FUNC_003 - Funksjonelle plantegrupper i våtmark"
)

# add the supplementary sheets to the workbook
xlsx_path <- file.path(out_dir, paste0(ID, "_values.xlsx"))
sheets <- list(
  values = read_csv(file.path(out_dir, paste0(ID, "_values.csv")), show_col_types = FALSE),
  metadata = tibble(field = names(metadata), value = unname(metadata)),
  plot = readRDS(file.path(out_dir, paste0(ID, "_indicatorMap_plot.rds"))) %>% st_drop_geometry(),
  supp_indicators = supp_wide,
  supp_cwm_medians = cwm_medians
)
writexl::write_xlsx(sheets, xlsx_path)
cat("  - supp sheets added to", basename(xlsx_path), "\n")
