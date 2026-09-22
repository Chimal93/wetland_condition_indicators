# ============================================================
# NO_CONN_001 - side-check (2026-09-22): isolate the POPULATION effect
# from the ANCHOR effect between the two variants.
#
# The scaling anchors are computed from each run's own kvotient
# distribution (1st/99th percentile of log kvotient), so the model-based
# run and the AR5 run do not share a scale:
#   model-based : X0 = 0.1414   X100 = 177.75
#   AR5         : X0 = 0.1562   X100 = 1487.66
# Comparing their index values therefore mixes "different wetland
# population" with "different scale". This script rescores the AR5
# polygons with the MODEL-BASED anchors, so:
#   AR5 own anchors   vs  AR5 model anchors   = the anchor effect
#   AR5 model anchors vs  model-based result  = the population effect
#
# Read-only side-check: reads the two runs' write-outs, writes one CSV to
# img/ar5_vs_model_anchors/. It does not touch either pipeline.
#
# BASE R + sf ONLY - no dplyr/readr: this machine's Application Control
# policy blocks glue.dll (2026-09-22), which those packages load.
# ============================================================
suppressPackageStartupMessages(library(sf))

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args <- commandArgs(trailingOnly = FALSE); fm <- grep("^--file=", cmd_args)
  if (length(fm)) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[fm]))))
}

scored_dir <- file.path("..", "Data", "connectivity_scored")
out_dir    <- file.path("..", "img", "ar5_vs_model_anchors")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

regionlvl <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
regions <- st_read(file.path("..", "Data", "spatial", "regions.shp"), quiet = TRUE)
regions$region[regions$id == 3] <- "Østlandet"; regions$region[regions$id == 5] <- "Sørlandet"
regions <- regions[, "region"]

anch_model <- read.csv(file.path(scored_dir, "anchors_national_2023.csv"))
anch_ar5   <- read.csv(file.path(scored_dir, "anchors_national_2023_AR5.csv"))
cat("model anchors : X0", round(anch_model$X0_kvotient, 4), " X100", round(anch_model$X100_kvotient, 2), "\n")
cat("AR5 anchors   : X0", round(anch_ar5$X0_kvotient, 4),   " X100", round(anch_ar5$X100_kvotient, 2), "\n\n")

# Same rule as scale_and_map_connectivity_indicator.R, with anchors supplied.
rescale <- function(kvotient, X0_log, X100_log) {
  idx <- rep(NA_real_, length(kvotient))
  idx[is.na(kvotient)] <- 1                                   # no infrastructure within 1000 m
  idx[!is.na(kvotient) & kvotient == 0] <- 0                  # infrastructure touching the mire
  fin <- is.finite(kvotient) & kvotient > 0                   # Inf = topology artefact -> stays NA
  s <- (log(kvotient[fin]) - X0_log) / (X100_log - X0_log)
  s[s < 0] <- 0; s[s > 1] <- 1
  idx[fin] <- round(s, 4)
  idx
}

cat("Reading AR5 scored polygons (large file, ~1-2 min)...\n")
mire <- st_read(file.path(scored_dir, "mire_scored_national_2023_AR5.gpkg"), quiet = TRUE)
mire$area_m2 <- as.numeric(st_area(mire))
mire$index_model_anchors <- rescale(mire$kvotient, anch_model$X0_log, anch_model$X100_log)

cat("Assigning regions...\n")
j <- st_join(regions, mire[, c("index", "index_model_anchors", "area_m2")])
d <- st_drop_geometry(j)
d <- d[!is.na(d$index), ]

wm <- function(x, w) { ok <- !is.na(x) & !is.na(w); sum(x[ok] * w[ok]) / sum(w[ok]) }
rows <- lapply(regionlvl, function(r) {
  s <- d[d$region == r, ]
  data.frame(region = r, n = nrow(s),
             ar5_own_anchors   = wm(s$index, s$area_m2),
             ar5_model_anchors = wm(s$index_model_anchors, s$area_m2))
})
res <- do.call(rbind, rows)
res <- rbind(res, data.frame(region = "Norge", n = nrow(d),
                             ar5_own_anchors   = wm(d$index, d$area_m2),
                             ar5_model_anchors = wm(d$index_model_anchors, d$area_m2)))

model_agg <- read.csv(file.path(scored_dir, "region_agg_national_2023.csv"))
res$model_pop <- model_agg$index[match(res$region, model_agg$region)]
res$n_model   <- model_agg$n[match(res$region, model_agg$region)]
res$anchor_effect     <- res$ar5_own_anchors - res$ar5_model_anchors
res$population_effect <- res$ar5_model_anchors - res$model_pop
res$total             <- res$ar5_own_anchors - res$model_pop

cat("\n=== AR5 population rescored with the model-based anchors ===\n")
num <- sapply(res, is.numeric); res_p <- res; res_p[num] <- lapply(res_p[num], function(x) round(x, 4))
print(res_p, row.names = FALSE)
write.csv(res, file.path(out_dir, "ar5_vs_model_anchors.csv"), row.names = FALSE)
cat("\nSaved:", file.path(out_dir, "ar5_vs_model_anchors.csv"), "\n")
