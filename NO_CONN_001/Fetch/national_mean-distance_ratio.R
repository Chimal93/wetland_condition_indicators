# ============================================================
# NO_CONN_001 - alternative "scaled indicator value" reading, checked in
# isolation.
#
# EXPLORATORY / DIAGNOSTIC ONLY. This script does NOT modify, source, or
# depend on scale_and_map_connectivity_indicator.R (the real indicator
# pipeline) in any way - it reads the same raw per-region
# *_connectivity_full_2023.gpkg files (already computed, untouched) and
# does its own independent computation, so the two pipelines stay fully
# isolated per user's explicit request. Its own output folder,
# Results/national_mean-distance_ratio/, is likewise separate from
# Results/'s real indicator outputs.
#
# WHY: NINA's source qmd has a genuine, still-unresolved prose/code
# discrepancy. The prose describing the "scaled indicator value"
# says to run the export "twice, with/without infrastructure" and take
# scaled_value = mean_distance_without / mean_distance_with - but no such
# toggle or second run exists anywhere in the actual GEE code, which only
# ever computes and exports the literal per-polygon `kvotient`
# (min_infra_distance / min_myr_distance) that
# scale_and_map_connectivity_indicator.R uses as the real indicator,
# area-weight-averaged to each region AFTER normalising each polygon
# first (Kolstad et al.'s "Pathway 1", Table 4).
#
# This script computes the best-guess reconciliation of that prose
# instead, using the SAME already-computed distance columns but a
# DIFFERENT order of operations: aggregate the raw distances to
# region-level (and national-level) MEANS FIRST, then take one ratio per
# region - Kolstad et al.'s "Pathway 2" (sp.agg. -> normalise). This is
# exactly the kind of pathway-order comparison Kolstad et al.'s own
# worked WFD/ASPT example warns can flip conclusions from the same
# underlying numbers - worth checking directly rather than assuming it
# doesn't matter here.
#
# mean_distance_without_infrastructure = mean(min_myr_distance_certified)
#   across ALL polygons in a region - nearest-neighbour mire distance,
#   infrastructure not involved at all ("without infrastructure").
# mean_distance_with_infrastructure = mean(min_infra_distance, na.rm=TRUE)
#   across only the polygons that HAVE infrastructure within the 1000m
#   search buffer (NA elsewhere, so na.rm=TRUE is the natural definition,
#   not a data-quality workaround) - distance to infrastructure ("with
#   infrastructure").
#
# NOTE ON POLARITY, found by actually computing this (not assumed going
# in): this pathway-2 ratio is structurally the RECIPROCAL of the
# pathway-1 kvotient (min_infra_distance/min_myr_distance). Pathway 1:
# HIGHER kvotient = infrastructure comparatively far away = BETTER
# condition. Pathway 2 as literally specified by the prose: HIGHER ratio
# means mean_distance_without (mire-to-mire) is large relative to
# mean_distance_with (mire-to-infrastructure), i.e. infrastructure is
# comparatively CLOSE = WORSE condition. The two pathways don't just
# reorder the same arithmetic - they invert which direction is "good."
# Flagged explicitly in the printed output and the report below, not
# silently normalised away.
# ============================================================

library(sf)
library(dplyr)
library(ggplot2)
library(ggrepel)
library(tidyr)

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

connectivity_dir <- file.path("..", "Data", "connectivity_output_simplified")
spatial_dir      <- file.path("..", "Data", "spatial")
out_dir          <- file.path("..", "Results", "national_mean-distance_ratio")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

regionlvl <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
ascii_lookup <- c(
  "Nord-Norge" = "nord_norge", "Midt-Norge" = "midt_norge",
  "Vestlandet" = "vestlandet", "Østlandet"  = "ostlandet",
  "Sørlandet"  = "sorlandet"
)

# ---------------------------------------------------------------
# Load the already-computed per-region distance data (read-only).
# ---------------------------------------------------------------
mire_all <- do.call(rbind, lapply(regionlvl, function(r) {
  f <- file.path(connectivity_dir, paste0(ascii_lookup[[r]], "_connectivity_full_2023.gpkg"))
  x <- st_read(f, quiet = TRUE)
  x$region <- r
  x
}))
mire_all$region <- factor(mire_all$region, levels = regionlvl)
cat("Total mire polygons loaded:", nrow(mire_all), "\n\n")

# ---------------------------------------------------------------
# PATHWAY 2 (this script's subject): region-level and national-level
# mean-distance ratio, aggregate-first.
# ---------------------------------------------------------------
mire_df <- st_drop_geometry(mire_all)

pathway2_region <- mire_df %>%
  group_by(region) %>%
  summarise(
    n                          = n(),
    n_with_infra               = sum(!is.na(min_infra_distance)),
    mean_dist_without_infra    = mean(min_myr_distance_certified, na.rm = TRUE),
    mean_dist_with_infra       = mean(min_infra_distance, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(ratio_pathway2 = mean_dist_without_infra / mean_dist_with_infra)

pathway2_national <- mire_df %>%
  summarise(
    region                     = "NASJONALT",
    n                          = n(),
    n_with_infra               = sum(!is.na(min_infra_distance)),
    mean_dist_without_infra    = mean(min_myr_distance_certified, na.rm = TRUE),
    mean_dist_with_infra       = mean(min_infra_distance, na.rm = TRUE)
  ) %>%
  mutate(ratio_pathway2 = mean_dist_without_infra / mean_dist_with_infra)

# ---------------------------------------------------------------
# PATHWAY 1 (the real indicator's actual pathway), reproduced here
# INDEPENDENTLY from the same raw kvotient column, purely so this
# script can show "how the values change" between pathways without
# importing or running scale_and_map_connectivity_indicator.R. Anchors
# are recomputed fresh from this run's own data, matching that script's
# own stated design (percentile anchors are never hardcoded).
# ---------------------------------------------------------------
PERCENTILE_LOWER <- 0.01
PERCENTILE_UPPER <- 0.99

kv <- mire_all$kvotient
is_finite_nonzero <- is.finite(kv) & kv > 0
log_k    <- log(kv[is_finite_nonzero])
X0_log   <- as.numeric(quantile(log_k, PERCENTILE_LOWER, na.rm = TRUE))
X100_log <- as.numeric(quantile(log_k, PERCENTILE_UPPER, na.rm = TRUE))
scaled   <- (log_k - X0_log) / (X100_log - X0_log)
scaled[scaled < 0] <- 0
scaled[scaled > 1] <- 1

mire_all$index_p1 <- NA_real_
mire_all$index_p1[is_finite_nonzero]                 <- scaled
mire_all$index_p1[is.na(kv)]                         <- 1
mire_all$index_p1[!is.na(kv) & kv == 0]              <- 0
# kvotient == Inf (topology artifact) stays NA - excluded, same as the
# real pipeline.

mire_all$area <- as.numeric(st_area(mire_all))

pathway1_region <- mire_all %>%
  st_drop_geometry() %>%
  filter(!is.na(index_p1)) %>%
  group_by(region) %>%
  summarise(index_pathway1 = weighted.mean(index_p1, w = area), .groups = "drop")

pathway1_national <- mire_all %>%
  st_drop_geometry() %>%
  filter(!is.na(index_p1)) %>%
  summarise(region = "NASJONALT", index_pathway1 = weighted.mean(index_p1, w = area))

# ---------------------------------------------------------------
# Combine into one comparison table.
# ---------------------------------------------------------------
comparison <- bind_rows(pathway2_region, pathway2_national) %>%
  left_join(bind_rows(pathway1_region, pathway1_national), by = "region") %>%
  mutate(region = factor(region, levels = c(regionlvl, "NASJONALT")))

cat("=== Comparison: Pathway 1 (real indicator, normalise-then-aggregate)",
    "vs Pathway 2 (qmd prose reading, aggregate-then-ratio) ===\n\n")
print(as.data.frame(comparison))

write.csv(comparison, file.path(out_dir, "national_mean-distance_ratio_table.csv"), row.names = FALSE)
cat("\nTable written to", file.path(out_dir, "national_mean-distance_ratio_table.csv"), "\n")

# ---------------------------------------------------------------
# Plot 1: the two raw component means (mean distance without vs. with
# infrastructure) per region - the ratio's actual ingredients, since the
# ratio alone hides whether a region differs because of its mire spacing,
# its infrastructure proximity, or both.
# ---------------------------------------------------------------
components_long <- pathway2_region %>%
  select(region, mean_dist_without_infra, mean_dist_with_infra) %>%
  pivot_longer(cols = c(mean_dist_without_infra, mean_dist_with_infra),
               names_to = "component", values_to = "meters") %>%
  mutate(component = recode(component,
                             mean_dist_without_infra = "Uten infrastruktur\n(myr-til-myr)",
                             mean_dist_with_infra    = "Med infrastruktur\n(myr-til-infrastruktur)"))

p_components <- ggplot(components_long, aes(x = region, y = meters, fill = component)) +
  geom_col(position = position_dodge(width = 0.7), width = 0.65) +
  geom_text(aes(label = round(meters)), position = position_dodge(width = 0.7),
            vjust = -0.4, size = 3) +
  scale_fill_manual(values = c("Uten infrastruktur\n(myr-til-myr)" = "#1a9641",
                                "Med infrastruktur\n(myr-til-infrastruktur)" = "#d7191c"),
                     name = NULL) +
  labs(title = "NO_CONN_001 - gjennomsnittlig avstand, med vs. uten infrastruktur",
       subtitle = "De to komponentene bak pathway 2-forholdstallet (region-nivå gjennomsnitt, ikke per-polygon)",
       x = NULL, y = "Gjennomsnittlig avstand (m)") +
  theme_minimal() +
  theme(legend.position = "top", axis.text.x = element_text(size = 10))

ggsave(file.path(out_dir, "national_mean-distance_ratio_components.png"),
       p_components, width = 9, height = 6, dpi = 300, bg = "white")

# ---------------------------------------------------------------
# Plot 2: pathway 1 vs pathway 2 side by side per region, on their own
# scales (NOT directly comparable numerically - see header note on
# polarity) - shows how differently the two pathways rank the regions.
# ---------------------------------------------------------------
compare_long <- comparison %>%
  filter(region != "NASJONALT") %>%
  select(region, index_pathway1, ratio_pathway2) %>%
  pivot_longer(cols = c(index_pathway1, ratio_pathway2), names_to = "pathway", values_to = "value") %>%
  mutate(pathway = recode(pathway,
                           index_pathway1 = "Pathway 1 (reell indikator)\nareal-vektet 0-1 indeks, høyere = bedre",
                           ratio_pathway2 = "Pathway 2 (qmd-prosa-tolkning)\nmean-distance ratio, høyere = dårligere"))

p_compare <- ggplot(compare_long, aes(x = region, y = value, fill = region)) +
  geom_col(width = 0.65, show.legend = FALSE) +
  geom_text(aes(label = round(value, 3)), vjust = -0.4, size = 3) +
  facet_wrap(~ pathway, scales = "free_y") +
  labs(title = "NO_CONN_001 - samme rådata, to ulike aggregeringsrekkefølger (Kolstad et al. Table 4)",
       subtitle = "Pathway 1 og Pathway 2 er IKKE på samme skala og har MOTSATT polaritet - se scriptets header",
       x = NULL, y = NULL) +
  theme_minimal() +
  theme(strip.text = element_text(size = 9), axis.text.x = element_text(size = 9))

ggsave(file.path(out_dir, "national_mean-distance_ratio_pathway_comparison.png"),
       p_compare, width = 10, height = 6, dpi = 300, bg = "white")

# ---------------------------------------------------------------
# Map: regions coloured by the pathway-2 ratio (continuous scale - this
# is a diagnostic value, not the real 0-1 indicator, so it is
# deliberately NOT forced into the official 5-class "Tilstand" breaks,
# which were calibrated for pathway 1's index only). Same clipped
# basemap as the other 3 wetland-indicator maps for visual consistency
# (see 2026-08-20 basemap-uniformity fix).
# ---------------------------------------------------------------
regions_path <- file.path(spatial_dir, "regions.shp")
regions <- st_read(regions_path, quiet = TRUE)
regions$region[regions$id == 3] <- "Østlandet"
regions$region[regions$id == 5] <- "Sørlandet"
regions <- regions %>% mutate(region = factor(region, levels = regionlvl))

outline_path <- file.path(spatial_dir, "outlineOfNorway_EPSG25833.shp")
nor <- st_read(outline_path, quiet = TRUE) %>% st_transform(st_crs(regions))
regions_clipped <- st_intersection(regions, nor)

map_dat <- regions_clipped %>%
  left_join(pathway2_region, by = "region")

label_pts <- map_dat %>%
  st_point_on_surface() %>%
  mutate(label = sprintf("%s\n%.2f\n(n=%d)", region, ratio_pathway2, n))
label_xy <- st_coordinates(label_pts)
label_pts$x <- label_xy[, "X"]
label_pts$y <- label_xy[, "Y"]

ratio_map <- ggplot() +
  geom_sf(data = map_dat, aes(fill = ratio_pathway2), color = "black", linewidth = 0.4) +
  geom_label_repel(data = label_pts, aes(x = x, y = y, label = label),
                    size = 2.6, lineheight = 0.85, fill = "white", color = "black",
                    label.size = 0.3, label.padding = unit(0.2, "lines"),
                    seed = 1, max.overlaps = Inf, min.segment.length = 0,
                    segment.color = "grey40", box.padding = 0.3) +
  scale_fill_gradient(low = "#1a9641", high = "#d7191c", name = "Pathway 2\nratio\n(høyere = dårligere)") +
  labs(
    title   = "NO_CONN_001 - alternativ tolkning: mean-distance ratio (Pathway 2)",
    caption = sprintf(
      "DIAGNOSTISK, ikke den reelle indikatoren. ratio = mean(min_myr_distance) / mean(min_infra_distance) per region.\nBasert pa NINA-qmd-ens uavklarte prosa (\"scaled_value = mean_distance_without/mean_distance_with\") - ingen slik kode finnes i selve GEE-scriptet.\nMerk motsatt polaritet av pathway 1 sin offisielle 0-1 indeks - se R/national_mean-distance_ratio.R sin header for full forklaring."
    )
  ) +
  theme_void() +
  theme(plot.title = element_text(size = 12, face = "bold"),
        plot.caption = element_text(size = 7, hjust = 0))

ggsave(file.path(out_dir, "national_mean-distance_ratio_map.png"),
       ratio_map, width = 11, height = 10, dpi = 300, bg = "white")
print(ratio_map)

cat("\n================================================\n")
cat("Outputs written to", out_dir, ":\n")
cat(" - national_mean-distance_ratio_table.csv\n")
cat(" - national_mean-distance_ratio_components.png\n")
cat(" - national_mean-distance_ratio_pathway_comparison.png\n")
cat(" - national_mean-distance_ratio_map.png\n")
cat("This script did not read, modify, or write anything under the real\n")
cat("indicator's own Results/ output or scale_and_map_connectivity_indicator.R.\n")
cat("================================================\n")
