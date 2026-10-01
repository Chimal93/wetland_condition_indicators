# ============================================================
# NO_GJEN_002 - validate the PROVISIONAL ETH/Sentinel-2 canopy height
# stand-in (Data/OpenS_data/eth_canopy_height_national.csv) against real
# ground truth, at the only locations where real ground truth actually
# exists: the 124-polygon `NiN_metaTest.shp` test set.
#
# WHY THIS IS A GENUINE CHECK, NOT A TAUTOLOGY: NiN_metaTest.shp's 124
# polygons are themselves a subset of the national NiN dataset (confirmed
# earlier by exact `id` match, see project memory) - so the national ETH
# extraction ALREADY has canopy-height values for these same real-world
# locations, computed completely independently (different script,
# different data source, no knowledge of the test set's own values).
# This lets us compare the PROVISIONAL stand-in (`eth_chm_median`,
# Sentinel-2 + GEDI, 2020, 10m) against two real values at the exact same
# 46 wetland polygons: `meta_media` (the real Meta model, run on real
# orthophoto) and `DSM_median` (real airborne LiDAR) - the two things
# this stand-in is meant to approximate until real orthophoto access
# exists.
#
# WHAT TO EXPECT, per this project's own documented caveats (see
# fetch_eth_canopy_height.R's header): NOT a tight 1:1 match. ETH's
# product is trained against GEDI's spaceborne LiDAR at 10m/2020 vintage,
# a different signal than either DSM_median (real local LiDAR) or
# meta_media (aerial-imagery-trained model) - and GEDI-based products are
# documented to perform worse at the SHORT vegetation heights this
# indicator cares about most. This script exists to quantify exactly how
# far off, not to pass/fail a threshold decided in advance.
# ============================================================

library(sf)
library(dplyr)
library(ggplot2)

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

spatial_dir <- file.path("..", "Data", "spatial")
data_dir    <- file.path("..", "Data")
img_dir     <- file.path("..", "img")
if (!dir.exists(img_dir)) dir.create(img_dir, recursive = TRUE)

test_set <- st_read(file.path(spatial_dir, "NiN_metaTest.shp"), quiet = TRUE) %>%
  st_drop_geometry() %>%
  filter(hvdksys == "Vaatmark") %>%
  dplyr::select(id, meta_media, DSM_median)
cat("Real test-set wetland polygons (with known meta_media/DSM_median):", nrow(test_set), "\n")

eth <- read.csv(file.path(data_dir, "OpenS_data", "eth_canopy_height_national.csv")) %>%
  dplyr::select(id = identifikasjon_lokalId, eth_chm_median, eth_chm_n)

comparison <- test_set %>%
  inner_join(eth, by = "id") %>%
  filter(!is.na(eth_chm_median))

cat("Matched to a national ETH canopy-height value:", nrow(comparison), "of", nrow(test_set), "\n")
if (nrow(comparison) == 0) stop("No matches found - check that fetch_eth_canopy_height.R has been run.")

fit_meta <- lm(eth_chm_median ~ meta_media, data = comparison)
fit_lidar <- lm(eth_chm_median ~ DSM_median, data = comparison)

cat("\n=== ETH (provisional) vs. real Meta model (meta_media) ===\n")
cat("R²:", round(summary(fit_meta)$r.squared, 3), "\n")
cat("Pearson r:", round(cor(comparison$eth_chm_median, comparison$meta_media), 3), "\n")
cat("Mean bias (ETH - Meta):", round(mean(comparison$eth_chm_median - comparison$meta_media), 2), "m\n")
cat("Mean abs. difference:", round(mean(abs(comparison$eth_chm_median - comparison$meta_media)), 2), "m\n")

cat("\n=== ETH (provisional) vs. real LiDAR (DSM_median) ===\n")
cat("R²:", round(summary(fit_lidar)$r.squared, 3), "\n")
cat("Pearson r:", round(cor(comparison$eth_chm_median, comparison$DSM_median), 3), "\n")
cat("Mean bias (ETH - LiDAR):", round(mean(comparison$eth_chm_median - comparison$DSM_median), 2), "m\n")
cat("Mean abs. difference:", round(mean(abs(comparison$eth_chm_median - comparison$DSM_median)), 2), "m\n")

# ---------------------------------------------------------------
# Short-vegetation-specific check (the regime this indicator cares
# about most - see header). Splits the comparison at the median real
# LiDAR height so this isn't just an overall-average number hiding a
# worse fit at the low end.
# ---------------------------------------------------------------
short_cutoff <- median(comparison$DSM_median, na.rm = TRUE)
short <- comparison %>% filter(DSM_median <= short_cutoff)
tall  <- comparison %>% filter(DSM_median >  short_cutoff)

cat("\n=== Split by real LiDAR height (cutoff =", round(short_cutoff, 2), "m) ===\n")
cat("SHORT (n=", nrow(short), "): mean abs. diff vs LiDAR =",
    round(mean(abs(short$eth_chm_median - short$DSM_median)), 2), "m\n")
cat("TALL  (n=", nrow(tall), "): mean abs. diff vs LiDAR =",
    round(mean(abs(tall$eth_chm_median - tall$DSM_median)), 2), "m\n")

# ---------------------------------------------------------------
# Plot: ETH vs. both real references, on the same axes for direct
# visual comparison.
# ---------------------------------------------------------------
plot_dat <- comparison %>%
  tidyr::pivot_longer(cols = c(meta_media, DSM_median), names_to = "reference", values_to = "real_value") %>%
  mutate(reference = recode(reference,
                             meta_media = "Real Meta model (orthophoto)",
                             DSM_median = "Real LiDAR (DSM)"))

p <- ggplot(plot_dat, aes(x = real_value, y = eth_chm_median)) +
  geom_point(size = 2.5, alpha = 0.5, color = "darkgray") +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "red") +
  geom_smooth(method = "lm", se = FALSE, color = "darkblue") +
  facet_wrap(~ reference) +
  coord_fixed(ratio = 1, xlim = c(0, 15), ylim = c(0, 15)) +
  theme_minimal() +
  labs(title = "PROVISIONAL: ETH/Sentinel-2 canopy height vs. real references (46 wetland test polygons)",
       subtitle = "Red dashed line = perfect 1:1 agreement. Not expected to be tight - see script header.",
       x = "Real reference value (m)", y = "ETH/Sentinel-2 provisional value (m)")

ggsave(file.path(img_dir, "NO_GJEN_002_eth_validation_scatter.png"),
       p, width = 10, height = 6, dpi = 300, bg = "white")
print(p)

cat("\nPlot saved to:", file.path(img_dir, "NO_GJEN_002_eth_validation_scatter.png"), "\n")
cat("\nThis is a validation of the PROVISIONAL stand-in only - it does not\n")
cat("change how much confidence to place in the eventual real orthophoto-\n")
cat("based pipeline, only in how much to trust the Sentinel-2 substitute\n")
cat("used to build/test the national pipeline while orthophoto access is pending.\n")
