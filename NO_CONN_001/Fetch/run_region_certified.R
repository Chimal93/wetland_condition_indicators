# ============================================================
# NO_CONN_001 - run the certified exact nearest-neighbour distance
# computation for one region, selected via CONNECTIVITY_REGION env var
# (same pattern as simplify_wetland_polygons.R). Generalized from
# run_full_sorlandet_certified.R once the algorithm was validated on
# Sørlandet (2026-08-14).
# ============================================================

library(sf)
library(dplyr)

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

# Locate nn_distance_certified.R relative to THIS script's own file, not
# the process's current working directory - a plain relative source()
# call broke here (found 2026-08-27, forcing a real Nord-Norge-only
# recompute): when Main sources this script (rather than it being run
# directly), commandArgs()'s --file= still reflects MAIN's own path,
# not this script's, so the setwd() block above silently leaves cwd at
# Main/, not Fetch/ - harmless for every other relative path here (both
# folders are siblings, so "../Data/..." resolves identically from
# either), but not for a bare "source('nn_distance_certified.R')",
# which needs to be found next to THIS file specifically. Walking the
# call stack for the innermost active source() frame's own `ofile`
# reliably finds this script's true location regardless of nesting.
own_dir <- local({
  for (i in rev(seq_len(sys.nframe()))) {
    of <- sys.frame(i)$ofile
    if (!is.null(of)) return(dirname(normalizePath(of)))
  }
  getwd()
})
source(file.path(own_dir, "nn_distance_certified.R"))

region_name <- Sys.getenv("CONNECTIVITY_REGION", unset = "")
if (!nzchar(region_name)) stop("Set CONNECTIVITY_REGION to one of: Nord-Norge, Midt-Norge, Vestlandet, Østlandet, Sørlandet")

in_path <- file.path("..", "Data", "wetland_map_simplified", paste0("wetland_simplified_", region_name, ".gpkg"))
mire <- st_read(in_path, quiet = TRUE)
cat("Loaded", nrow(mire), "simplified", region_name, "mire polygons.\n")
cat("Running certified nearest-neighbour distance (k=75 + giants, exact) on FULL region...\n\n")

t0 <- Sys.time()
d <- nn_distance_certified(mire, k = 75)
elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

cat("\n[timing] FULL", region_name, ", CERTIFIED EXACT:", round(elapsed, 1), "sec (",
    round(elapsed / 60, 1), "min /", round(elapsed / 3600, 2), "hr )\n")
cat("Result summary:\n"); print(summary(d))

mire$min_myr_distance_certified <- d
out_dir <- file.path("..", "Data", "connectivity_output_simplified")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

# Explicit ASCII-safe filename per region, matching the names already in
# use on disk - NOT a generic regex strip. A first version used
# gsub("[^A-Za-z]", "_", region_name), which silently mangled "Østlandet"
# to "_stlandet" (Ø isn't in [A-Za-z], so it became a bare underscore
# instead of a readable substitution) - found and fixed 2026-08-17 after
# noticing the stray filename post-run.
ascii_name <- c(
  "Nord-Norge" = "nord_norge",
  "Midt-Norge" = "midt_norge",
  "Vestlandet" = "vestlandet",
  "Østlandet"  = "ostlandet",
  "Sørlandet"  = "sorlandet"
)[[region_name]]
out_path <- file.path(out_dir, paste0(ascii_name, "_min_myr_distance_certified.gpkg"))
st_write(mire, out_path, quiet = TRUE, append = FALSE)
cat("\nWritten to", out_path, "\n")
