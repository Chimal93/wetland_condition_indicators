# ============================================================
# NO_GJEN_002 - validate OUR Meta-model-on-real-orthophoto pipeline
# (Data/OpenS_data/meta_chm_orthophoto.csv, produced by
# run_meta_chm_on_polygons.R) against NINA's own values at the same 46
# wetland polygons of NiN_metaTest.shp.
#
# Deliberately mirrors validate_eth_canopy_height.R's metrics exactly, so
# the numbers are directly comparable with the PROVISIONAL ETH/Sentinel-2
# stand-in's recorded performance (r=0.46 vs Meta, r=0.57 vs LiDAR, +8 m
# mean bias, and - the decisive weakness - near-inability to resolve
# genuinely open ground as near-zero).
#
# WHAT THIS IS AND ISN'T: `meta_media` is NINA's own run of the SAME model
# on THEIR orthophoto (older Kartverket imagery); ours uses a different,
# newer orthophoto. So this is a reimplementation check, not a
# reproduction to machine precision - real vegetation change between
# image dates is a legitimate source of disagreement, and is expected to
# push our values UP where regrowth has continued, not down. A large
# NEGATIVE bias would instead point at our pipeline.
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

suppressMessages({ library(sf); library(dplyr); library(ggplot2) })

spatial_dir <- file.path("..", "Data", "spatial")
data_dir    <- file.path("..", "Data")
img_dir     <- file.path("..", "img")
if (!dir.exists(img_dir)) dir.create(img_dir, recursive = TRUE)

truth <- st_read(file.path(spatial_dir, "NiN_metaTest.shp"), quiet = TRUE) %>%
  st_drop_geometry() %>%
  filter(hvdksys == "Vaatmark") %>%
  mutate(id = as.character(id)) %>%
  dplyr::select(id, meta_media, DSM_median)

ours <- read.csv(file.path(data_dir, "OpenS_data", "meta_chm_orthophoto.csv"),
                 stringsAsFactors = FALSE) %>%
  mutate(id = as.character(id))

cmp <- truth %>%
  inner_join(ours, by = "id") %>%
  filter(!is.na(meta_chm_median), !is.na(meta_media))
cat("Polygons compared:", nrow(cmp), "of", nrow(truth), "\n\n")
if (nrow(cmp) == 0) stop("No overlap - has run_meta_chm_on_polygons.R been run?")

report <- function(label, ours_v, ref_v) {
  cat("=== OURS vs", label, "===\n")
  cat("  Pearson r        :", round(cor(ours_v, ref_v), 3), "\n")
  cat("  Spearman r       :", round(cor(ours_v, ref_v, method = "spearman"), 3), "\n")
  cat("  R2               :", round(summary(lm(ours_v ~ ref_v))$r.squared, 3), "\n")
  cat("  Mean bias        :", round(mean(ours_v - ref_v), 2), "m\n")
  cat("  Mean abs. diff   :", round(mean(abs(ours_v - ref_v)), 2), "m\n")
  cat("  Median abs. diff :", round(median(abs(ours_v - ref_v)), 2), "m\n\n")
}
report("NINA meta_media (same model, their ortho)", cmp$meta_chm_median, cmp$meta_media)
report("NINA DSM_median (LiDAR)",                   cmp$meta_chm_median, cmp$DSM_median)

# The regime this indicator actually cares about: can we tell genuinely
# open wetland from lightly encroached? This is exactly where the ETH
# stand-in failed, so it gets its own explicit check rather than being
# hidden inside an overall average.
cat("=== Short-vegetation regime (where the indicator lives) ===\n")
cutoff <- 1.0
open_true <- cmp %>% filter(meta_media <= cutoff)
tall_true <- cmp %>% filter(meta_media >  cutoff)
cat(sprintf("  Polygons NINA calls open (<=%.1f m): n=%d, our median prediction=%.2f m\n",
            cutoff, nrow(open_true), median(open_true$meta_chm_median)))
if (nrow(tall_true) > 0) {
  cat(sprintf("  Polygons NINA calls taller (>%.1f m): n=%d, our median prediction=%.2f m\n",
              cutoff, nrow(tall_true), median(tall_true$meta_chm_median)))
  cat(sprintf("  Separation between the two groups   : %.2f m\n",
              median(tall_true$meta_chm_median) - median(open_true$meta_chm_median)))
} else {
  cat("  (no polygons above the cutoff in this set)\n")
}

cat("\n--- side-by-side value distributions ---\n")
print(summary(cmp[, c("meta_chm_median", "meta_media", "DSM_median")]))

plot_dat <- cmp %>%
  tidyr::pivot_longer(cols = c(meta_media, DSM_median),
                      names_to = "reference", values_to = "real_value") %>%
  mutate(reference = recode(reference,
                            meta_media = "NINA Meta model (their orthophoto)",
                            DSM_median = "NINA LiDAR (DSM)"))

p <- ggplot(plot_dat, aes(x = real_value, y = meta_chm_median)) +
  geom_point(size = 2.5, alpha = 0.6, colour = "darkgreen") +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "red") +
  geom_smooth(method = "lm", se = FALSE, colour = "darkblue") +
  facet_wrap(~ reference) +
  coord_fixed(xlim = c(0, 15), ylim = c(0, 15)) +
  theme_minimal() +
  labs(title = "Meta model on REAL orthophoto vs NINA's references (46 wetland polygons)",
       subtitle = "Red dashed = 1:1. Our run uses newer orthophoto than NINA's, so exact agreement is not expected.",
       x = "NINA reference value (m)", y = "Our Meta-on-orthophoto median (m)")
ggsave(file.path(img_dir, "NO_GJEN_002_meta_orthophoto_validation.png"),
       p, width = 10, height = 6, dpi = 300, bg = "white")
cat("\nPlot saved to:", file.path(img_dir, "NO_GJEN_002_meta_orthophoto_validation.png"), "\n")
