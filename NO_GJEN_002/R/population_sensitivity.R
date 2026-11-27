# ============================================================
# NO_GJEN_002 - effect of the population rule on the regional values.
#
# The delivered population leaves out the nature types that the good-
# condition reference excludes (see NO_GJEN_002_national_pipeline.R). This
# script compares it with the population of all NiN wetland polygons.
#
# Run first:
#   NO_GJEN_002_national_pipeline.R                            (delivered)
#   NO_GJEN_002_national_pipeline.R, GJEN002_POPULATION=all    (comparison)
# Output: ../outputs/v000.003/results/NO_GJEN_002_population_sensitivity.csv
# ============================================================

suppressPackageStartupMessages({ library(sf); library(dplyr); library(readr) })

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args <- commandArgs(trailingOnly = FALSE); fm <- grep("^--file=", cmd_args)
  if (length(fm)) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[fm]))))
}

res <- file.path("..", "outputs", "v000.003", "results")   # version 000.003 (superseded)
dir.create(res, showWarnings = FALSE, recursive = TRUE)
summarise_run <- function(suffix) {
  d <- st_read(file.path(res, paste0("NO_GJEN_002_wetland_index", suffix, ".shp")), quiet = TRUE)
  d$area <- as.numeric(st_area(d))
  d <- st_drop_geometry(d)
  bind_rows(d, mutate(d, region = "Norge")) %>%
    group_by(region) %>%
    summarise(n = n(), index = weighted.mean(index, area), .groups = "drop")
}
out <- summarise_run("_OpenSource") %>%
  inner_join(summarise_run("_OpenSource_allTypes"), by = "region", suffix = c("_delivered", "_all_types")) %>%
  mutate(share_removed = 1 - n_delivered / n_all_types)
write_csv(out, file.path(res, "NO_GJEN_002_population_sensitivity.csv"))
print(as.data.frame(out))
