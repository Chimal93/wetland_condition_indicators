# ============================================================
# NO_CONN_001 - turn the per-polygon `kvotient` (from Fetch/
# compute_infra_distance_region.R's per-region output) into a 0-1 scaled
# indicator and a standardized regional "Tilstand" map, matching
# NO_GJEN_001/NO_FUNC_003's established map style.
#
# WHY A SEPARATE SCRIPT: the source qmd never actually defined a scaling
# function for connectivity (GitHub issue #144, "scaling and regional
# aggregation" explicitly marked unfinished) - the only hint anywhere is
# a "tentative 0.6 threshold" borrowed from a different indicator. This
# script is therefore OUR reconstruction, not confirmed NINA methodology
# - built following the framework in Kolstad et al. (in prep, "On the
# spatial aggregation of condition metrics for ecosystem accounting" -
# NINA's own guidance on exactly this problem; the manuscript itself is
# not included in this migration copy, see README), not invented from
# scratch.
#
# DATA-INFORMED DESIGN (checked the real kvotient distribution before
# designing this - heavily right-skewed raw, close to symmetric on the
# log scale, consistent with other log-transformed ratio/count
# variables in this project):
#   - THREE special cases handled distinctly, not one blended scale
#     (Kolstad's "natural zero" reference-level concept - some reference
#     levels are defined, not derived from data):
#       kvotient = Inf  -> EXCLUDED (dissolve/topology artifact from
#                           touching mire polygons, not an ecological
#                           signal)
#       kvotient = NA   -> index = 1 (no infrastructure within 1000m =
#                           reference condition, a defined anchor)
#       kvotient = 0    -> index = 0 (infrastructure touches the mire =
#                           complete disruption, a defined anchor)
#       finite, >0      -> log-transform, then scale/truncate between
#                           percentile-based anchors COMPUTED FROM
#                           WHATEVER DATA IS PASSED IN, not hardcoded -
#                           see PERCENTILE_LOWER/UPPER below.
#
# AGGREGATION PATHWAY (Kolstad et al., Table 4, "Pathway 1"): normalise
# EACH mire polygon FIRST, then spatially aggregate (area-weighted mean)
# to the 5 regions - the SAME pathway GJEN_001/FUNC_003 use (Kolstad's
# Recommendation #3: consistent pathway across indicators in the same
# assessment, not a free choice).
#
# ANCHOR STABILITY: anchors are always recomputed fresh from whatever
# data is fed in, never hardcoded - originally a real caution (the first
# test run had only 402 points from 2 small, biased AOIs, not enough to
# trust). The first real national run (2026-08-19) reached n=97,072,
# comfortably past ANCHOR_STABLE_MIN_N below, so this is no longer a
# live concern at national scale - but the adaptive design stays either
# way: the script always prints which anchors it used and whether it
# considers them stable, never silently ambiguous.
#
# SIGMOID TRANSFORM DROPPED (2026-08-19): the finite/nonzero branch
# originally applied GJEN_001's own sigmoid shape on top of the
# truncated linear scale, purely for cross-indicator visual consistency
# - not because CON_001's own ecology needs a threshold/diminishing-
# returns curve. Once real national data existed, plotting the
# sigmoid's actual effect showed a substantial, largely arbitrary
# UPWARD bias (median 0.651 -> 0.824, share >=0.9 from 7.9% to 35.7%)
# simply because most real values happen to fall where the curve sits
# above the identity line - not an ecological design choice. Kolstad's
# Recommendation #3 is about the AGGREGATION PATHWAY, not the per-unit
# curve shape, so dropping the sigmoid doesn't violate it. `index` for
# the finite/nonzero branch is now just the truncated linear-scaled
# log-kvotient value directly.
# ============================================================

library(sf)
library(dplyr)
library(ggplot2)
library(RColorBrewer)
library(ggrepel)

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

connectivity_dir <- Sys.getenv("CONNECTIVITY_SCORE_DIR",
                                unset = file.path("..", "Data", "connectivity_output"))
spatial_dir      <- file.path("..", "Data", "spatial")
img_dir          <- file.path("..", "Results")
if (!dir.exists(img_dir)) dir.create(img_dir, recursive = TRUE)

# Which connectivity output file(s) to score - override via env var to
# point at a regional/national run once one exists. Defaults to
# combining every *_TEST.gpkg currently in the output folder (the two
# small AOIs) purely so this script's MECHANISM can be verified - not a
# claim that the resulting map is a real indicator value yet.
# 2026-08-19: first REAL national run - CONNECTIVITY_SCORE_DIR points at
# Data/connectivity_output_simplified (the certified-algorithm outputs,
# min_myr_distance_certified column instead of min_myr_distance) and
# CONNECTIVITY_SCORE_PATTERN matches the 5 per-region
# "<region>_connectivity_full_2023.gpkg" files - not the earlier
# *_min_myr_distance_certified.gpkg files (myr-distance only, no kvotient
# yet) also present in that folder.
input_pattern <- Sys.getenv("CONNECTIVITY_SCORE_PATTERN", unset = "connectivity_.*\\.gpkg$")

PERCENTILE_LOWER <- 0.01
PERCENTILE_UPPER <- 0.99

# ---------------------------------------------------------------
# Load and combine input mire polygons (with kvotient) from whichever
# connectivity_output file(s) match the pattern.
# ---------------------------------------------------------------
input_files <- list.files(connectivity_dir, pattern = input_pattern, full.names = TRUE)
if (length(input_files) == 0) stop("No connectivity output files found matching '", input_pattern, "' in ", connectivity_dir)
cat("Scoring", length(input_files), "input file(s):\n"); print(basename(input_files))

mire_polygons <- do.call(rbind, lapply(input_files, function(f) {
  x <- st_read(f, quiet = TRUE)
  x$source_file <- basename(f)
  x
}))
cat("Total mire polygons loaded:", nrow(mire_polygons), "\n")

# ---------------------------------------------------------------
# Scaling function - see header for the full rationale.
# ---------------------------------------------------------------
scale_connectivity <- function(x, lower_pct = PERCENTILE_LOWER, upper_pct = PERCENTILE_UPPER) {
  x$index <- NA_real_
  x$index_note <- NA_character_

  is_inf <- is.infinite(x$kvotient)
  x$index_note[is_inf] <- "excluded_topology_artifact"

  is_na_k <- is.na(x$kvotient)
  x$index[is_na_k] <- 1
  x$index_note[is_na_k] <- "reference_no_infra_within_1000m"

  is_zero <- !is.na(x$kvotient) & x$kvotient == 0
  x$index[is_zero] <- 0
  x$index_note[is_zero] <- "extreme_infra_touches_mire"

  is_finite_nonzero <- is.finite(x$kvotient) & x$kvotient > 0
  n_fn <- sum(is_finite_nonzero)
  if (n_fn >= 10) {
    log_k <- log(x$kvotient[is_finite_nonzero])
    X0_log   <- as.numeric(quantile(log_k, lower_pct, na.rm = TRUE))
    X100_log <- as.numeric(quantile(log_k, upper_pct, na.rm = TRUE))
    cat("Anchors computed from THIS run's data (n =", n_fn, "finite nonzero kvotient values):\n")
    cat("  X0 (log scale,", lower_pct * 100, "th pct):", round(X0_log, 3), " -> kvotient =", round(exp(X0_log), 4), "\n")
    cat("  X100 (log scale,", upper_pct * 100, "th pct):", round(X100_log, 3), " -> kvotient =", round(exp(X100_log), 4), "\n")

    scaled <- (log_k - X0_log) / (X100_log - X0_log)
    scaled[scaled < 0] <- 0
    scaled[scaled > 1] <- 1
    # Sigmoid transform DROPPED (2026-08-19, see header) - index is now
    # just the truncated linear-scaled log-kvotient value directly, no
    # further curve applied. GJEN_001's sigmoid shape was borrowed for
    # cross-indicator visual consistency only, not derived from this
    # indicator's own ecology, and was shown to introduce a substantial,
    # largely arbitrary upward bias on the real data (see this script's
    # header for the exact before/after numbers).
    x$index[is_finite_nonzero] <- scaled
    x$index_note[is_finite_nonzero] <- "log_kvotient_linear_scaled_truncated"
  } else {
    message("Fewer than 10 finite nonzero kvotient values (", n_fn, ") - too few to compute ",
            "stable percentile anchors. Those rows left unscored (index = NA).")
  }

  attr(x, "anchors") <- if (n_fn >= 10) c(X0_log = X0_log, X100_log = X100_log) else NULL
  x
}

mire_scored <- scale_connectivity(mire_polygons)

cat("\n=== Scoring summary ===\n")
print(table(mire_scored$index_note, useNA = "ifany"))
cat("\nindex summary (excludes topology-artifact rows):\n")
print(summary(mire_scored$index))

# ---------------------------------------------------------------
# Regional aggregation - same pathway as GJEN_001 (normalise per-polygon
# FIRST, spatially aggregate SECOND), same 5 regions, same Norwegian
# region labels/o-a-encoding fix.
# ---------------------------------------------------------------
regionlvl <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
regions_path <- file.path(spatial_dir, "regions.shp")
regions <- st_read(regions_path, quiet = TRUE)
regions$region[regions$id == 3] <- "Østlandet"
regions$region[regions$id == 5] <- "Sørlandet"
regions <- regions %>% mutate(region = factor(region, levels = regionlvl))

mire_valid <- mire_scored %>%
  filter(!is.na(index)) %>%
  st_transform(st_crs(regions))
# st_area() called on the whole sf object, not a literal "geometry"
# column name - GPKG's default geometry column name is "geom", not
# "geometry" (confirmed the hard way: st_area(geometry) failed with
# "object 'geometry' not found" on data read back from a GPKG).
mire_valid$area <- as.numeric(st_area(mire_valid))

region_agg <- regions %>%
  st_join(mire_valid) %>%
  st_drop_geometry() %>%
  filter(!is.na(index)) %>%
  group_by(region) %>%
  summarise(index = weighted.mean(index, w = area, na.rm = TRUE), n = n(), .groups = "drop")

# ---------------------------------------------------------------
# Bootstrap CI on the regional area-weighted mean (2026-08-19, user
# request). CON_001 was the only one of the three wetland indicators
# with NO uncertainty quantification at the regional aggregation step -
# GJEN_001's ecTools::ea_spread() has a bootstrapped SE built in,
# FUNC_003 has its own boot_median_ci(). Kolstad et al. explicitly
# endorse non-parametric bootstrapping for exactly this ("...can be used
# to possibly obtain better descriptions of the uncertainty in the
# estimates"). Resamples (index, area) PAIRS together (not index alone)
# so each resampled weighted mean reflects genuine sampling uncertainty
# in the actual polygon population, not an unweighted resample.
# ---------------------------------------------------------------
BOOT_N     <- 1000
BOOT_PROBS <- c(0.025, 0.975)
set.seed(1)  # reproducible bootstrap draws, matching FUNC_003's convention

boot_weighted_mean_ci <- function(index, area, n = BOOT_N, probs = BOOT_PROBS) {
  ok <- !is.na(index) & !is.na(area)
  index <- index[ok]; area <- area[ok]
  if (length(index) == 0) return(c(NA_real_, NA_real_))
  if (length(index) == 1) return(c(index, index))
  n_obs <- length(index)
  boot_means <- vapply(seq_len(n), function(i) {
    idx <- sample.int(n_obs, n_obs, replace = TRUE)
    weighted.mean(index[idx], w = area[idx])
  }, numeric(1))
  as.numeric(quantile(boot_means, probs, na.rm = TRUE))
}

cat("\nComputing bootstrap CIs on the regional area-weighted mean (", BOOT_N, "resamples per region)...\n")
t_boot <- Sys.time()
joined_for_boot <- st_drop_geometry(st_join(regions, mire_valid))
joined_for_boot <- joined_for_boot[!is.na(joined_for_boot$index), ]
boot_rows <- lapply(regionlvl, function(r) {
  sub <- joined_for_boot[joined_for_boot$region == r, ]
  if (nrow(sub) == 0) return(data.frame(region = r, boot_low = NA_real_, boot_high = NA_real_))
  ci <- boot_weighted_mean_ci(sub$index, sub$area)
  data.frame(region = r, boot_low = ci[1], boot_high = ci[2])
})
boot_cis <- do.call(rbind, boot_rows)
cat("  [timing]", round(as.numeric(difftime(Sys.time(), t_boot, units = "secs")), 1), "sec\n")

region_agg <- region_agg %>% left_join(boot_cis, by = "region")

cat("\n=== Regional aggregation ===\n")
# print(region_agg) would use tibble/pillar's pretty-printer, which loads
# utf8.dll - found blocked by a Windows Application Control policy on
# this machine (2026-08-19), crashing the script AFTER all the real work
# was already done. print.data.frame() avoids that dependency entirely.
print(as.data.frame(region_agg))

# ---------------------------------------------------------------
# Standardized 5-class "Tilstand" map - breaks/labels/colors copied
# directly from NO_GJEN_001_wetland_pipeline_OpenSource.R's own
# condition_map code, so every indicator's regional map reads the same
# way (Kolstad Recommendation #3).
# ---------------------------------------------------------------
condition_breaks <- c(0, 0.2, 0.4, 0.6, 0.8, 1)
condition_labels <- c("Svært dårlig", "Dårlig", "Moderat", "God", "Svært god")
condition_colors <- setNames(
  c("#d7191c", "#fdae61", "#ffffbf", "#a6d96a", "#1a9641"),
  condition_labels
)

# Clip to Norway's real coastline (fjords/islands) for display only - matches
# NO_FUNC_003's map style (st_intersection(reg, nor), the only one of the 3
# wetland indicators that did this). GJEN_001/CON_001 previously drew
# regions.shp raw, giving a visibly smoother/more generalized coastline than
# FUNC_003's map - purely a rendering difference, not a data/value one (see
# 2026-08-20 investigation). Done here, AFTER region_agg is already computed
# from the unclipped `regions`, so this can't perturb the aggregation itself -
# it only affects what geometry the final map draws.
outline_path <- file.path(spatial_dir, "outlineOfNorway_EPSG25833.shp")
nor <- st_read(outline_path, quiet = TRUE) %>% st_transform(st_crs(regions))
regions_clipped <- st_intersection(regions, nor)

condition_map_dat <- regions_clipped %>%
  left_join(region_agg, by = "region") %>%
  mutate(condition = cut(index, breaks = condition_breaks,
                          labels = condition_labels, include.lowest = TRUE))

# Label text got longer once the bootstrap CI was added (2026-08-19) -
# the single-line "%.3f [%.3f-%.3f] (n=%d)" format was wide enough to
# make adjacent regions' label boxes overlap and clip text (seen
# directly on the rendered map). Splitting across 3 lines + shrinking
# font size reduced but did not eliminate the overlap for the
# Vestlandet/Østlandet pair specifically (their point-on-surface
# centroids sit close together along their shared border). Switched to
# ggrepel::geom_label_repel(), which auto-nudges colliding labels apart
# and draws a leader line back to the true point - a permanent fix
# instead of continuing to shrink text.
label_pts <- condition_map_dat %>%
  st_point_on_surface() %>%
  mutate(label = ifelse(
    is.na(index),
    paste0(region, "\nIngen data"),
    sprintf("%s\n%.3f\n[%.3f-%.3f] (n=%d)", region, index, boot_low, boot_high, n)
  ))
label_xy <- st_coordinates(label_pts)
label_pts$x <- label_xy[, "X"]
label_pts$y <- label_xy[, "Y"]

dummy_xy <- st_coordinates(st_point_on_surface(condition_map_dat[1, ]))
legend_dummy <- data.frame(
  condition = factor(condition_labels, levels = condition_labels),
  x = dummy_xy[1, "X"], y = dummy_xy[1, "Y"]
)

# PROVISIONAL vs FINAL labeling is DATA-DRIVEN, not hardcoded - never
# silently assume which mode we're in. The original two-small-test-AOI
# run (402 usable points combined) was explicitly judged NOT
# representative enough for real anchors; the first real national run
# (2026-08-19) used n=97,072 finite-nonzero kvotient values, 241x more.
# ANCHOR_STABLE_MIN_N=5000 is a deliberately conservative line between
# "small test AOI" and "real regional/national scale" - comfortably above
# the rejected 402-point case, comfortably below any real regional run.
ANCHOR_STABLE_MIN_N <- 5000
anchor_info <- attr(mire_scored, "anchors")
n_scored <- sum(mire_scored$index_note == "log_kvotient_linear_scaled_truncated", na.rm = TRUE)
is_final <- !is.null(anchor_info) && n_scored >= ANCHOR_STABLE_MIN_N

map_title <- if (is_final) "NO_CONN_001 indikator Konnektivitet" else "NO_CONN_001 indikator Konnektivitet (PROVISORISK)"

caption_txt <- if (is.null(anchor_info)) {
  "Areal-vektet gjennomsnittlig indeksverdi per region. God tilstand >= 0.6.\nPROVISORISK: for lite data til å beregne anchors."
} else if (is_final) {
  # Not "PROVISORISK" anymore (n is now large/national), but the scaling
  # FUNCTION itself is still our own reconstruction, not confirmed NINA
  # methodology (NINA's own scaling/aggregation step was never finished
  # at the source - GitHub issue #144) - that fact doesn't change just
  # because the anchors are now stable, so it stays noted, just without
  # the data-instability alarm.
  sprintf("Areal-vektet gjennomsnittlig indeksverdi per region. God tilstand >= 0.6.\nAnchors fra n=%d landsdekkende data (X0/X100 log-kvotient = %.2f/%.2f).\nSkaleringsmetodikk uavhengig utviklet (ikke fullført av NINA ved kilden, se issue #144).",
          n_scored, anchor_info["X0_log"], anchor_info["X100_log"])
} else {
  sprintf("Areal-vektet gjennomsnittlig indeksverdi per region. God tilstand >= 0.6.\nPROVISORISK: anchors beregnet fra n=%d denne kjøringen (X0/X100 log-kvotient = %.2f/%.2f) - IKKE offisiell NINA-metodikk.",
          n_scored, anchor_info["X0_log"], anchor_info["X100_log"])
}

connectivity_condition_map <- ggplot() +
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
    title   = map_title,
    caption = caption_txt
  ) +
  theme_void() +
  theme(plot.title = element_text(size = 12, face = "bold"),
        plot.caption = element_text(size = 8, hjust = 0))

out_map_path <- file.path(img_dir, if (is_final) "NO_CONN_001_connectivity_condition_map.png"
                                     else "NO_CONN_001_connectivity_condition_map_PROVISIONAL.png")
ggsave(out_map_path, connectivity_condition_map, width = 8, height = 8, dpi = 300, bg = "white")

cat("\nMap written to", out_map_path, "\n")
cat("\n================================================\n")
if (is_final) {
  cat("Anchors computed from n =", n_scored, "real data points (>= ", ANCHOR_STABLE_MIN_N,
      "threshold) - labeled FINAL, not provisional.\n")
} else {
  cat("REMINDER: anchors computed from only n =", n_scored, "points (<", ANCHOR_STABLE_MIN_N,
      "threshold) - too few to trust as stable. Re-run against a larger/regional/national\n")
  cat("dataset before treating this as final.\n")
}
cat("This map's underlying SCALING FUNCTION is OUR reconstruction either way,\n")
cat("not confirmed NINA methodology (never finished at the source - issue #144).\n")
cat("================================================\n")
