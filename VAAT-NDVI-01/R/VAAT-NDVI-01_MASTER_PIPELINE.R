# ============================================================
# VAAT-NDVI-01 - NDVI (Primary Production), Wetlands - MASTER PIPELINE
#
# Stitches together every piece of this indicator into one script, run
# top to bottom. Two stages below are marked NOT FULLY AUTOMATED - read
# their own comments before running this unattended:
#
#   STAGE 2 (Sentinel-2 fetch)  - needs a HUMAN to click a login link
#                                  when CDSE's device-code flow prompts
#                                  for it (~10 min window). Cannot be
#                                  scripted around - see fetch_sentinel2_
#                                  ndvi.R's own header for why
#                                  authorization_code+pkce (which would
#                                  avoid this) was tried and rejected.
#   STAGE 3 (Landsat fetch)     - NOT BUILT AT ALL. No fetch script
#                                  exists yet. This stage is a documented
#                                  placeholder, not a bug - see its own
#                                  block below for what would need to be
#                                  built.
#
# RESUMABLE / IDEMPOTENT: each stage checks whether its expected output
# already exists and skips straight past if so - safe to re-run this
# whole script at any time without redoing finished work or re-spending
# CDSE credits on an already-completed Sentinel-2 fetch.
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

data_dir <- file.path("..", "data")
t0 <- Sys.time()

cat_stage <- function(msg) {
  cat("\n============================================================\n")
  cat(msg, "-", format(Sys.time(), "%H:%M:%S"), "\n")
  cat("============================================================\n")
}
skip_note <- function(msg) cat("  [skip] ", msg, " - output already present.\n", sep = "")

# ================================================================
# STAGE 1: Fetch MODIS NDVI - FULLY AUTOMATED.
# National fetch, 2000-present, growing season only. No human
# interaction needed - NASA Earthdata auth uses a stored bearer token
# (.Renviron), not an interactive login.
# ================================================================
cat_stage("STAGE 1: Fetch MODIS NDVI (fully automated)")
modis_out <- file.path(data_dir, "NDVI_MODIS", "modis_ndvi_ts_national.csv")
if (file.exists(modis_out) || file.exists(paste0(modis_out, ".gz"))) {
  skip_note(modis_out)
} else {
  local({ source("fetch_modis_ndvi.R") })
}

# ================================================================
# STAGE 2: Fetch Sentinel-2 NDVI - NOT FULLY AUTOMATED.
#
# *** THIS STAGE NEEDS YOU AT THE KEYBOARD ***
# CDSE's login is a device-code flow: a URL + short code will print to
# the console below, and you must open that URL and approve it within
# ~10 minutes or the whole fetch fails. This cannot be scripted around
# (authorization_code+pkce, which opens a browser directly with no code
# to relay, was tried and rejected outright - Rscript.exe batch execution
# is never "interactive" enough for it, regardless of how this script is
# run). If you're not available to click through logins right now, stop
# this script and re-run it later - Stage 1 and this stage's own partial
# job registrations are cached/resumable, nothing is lost by waiting.
#
# Also requires CDSE's own openEO service to be up - it was down (503 on
# both its federated and direct endpoints) as of 2026-09-02; if this
# stage fails immediately with a connection error, that's the first
# thing to rule out, not a bug in this script.
# ================================================================
cat_stage("STAGE 2: Fetch Sentinel-2 NDVI (MANUAL - needs your login click)")
sentinel_out <- file.path(data_dir, "NDVI_Sentinel", "ndvi_national_clean.csv")
if (file.exists(sentinel_out)) {
  skip_note(sentinel_out)
} else {
  # CONFIRMED (2026-09-03): when CDSE's openEO service is down/degraded,
  # the R client's own connect() does not reliably fail fast - a real
  # test run hung for 5+ minutes at near-zero CPU (a blocking socket
  # call, not a retry loop) with zero output, even though a plain curl
  # check against the same host failed instantly with a clean 503/404.
  # A hard-timeout pre-flight check via curl's own --max-time (enforced
  # at the OS/network level, unlike an R-side timeout which may not
  # interrupt a blocking C call cleanly) avoids that hang entirely -
  # skip straight past this stage if the backend isn't even reachable,
  # rather than risk blocking the whole master pipeline indefinitely.
  preflight <- suppressWarnings(system2(
    "curl", c("-s", "-o", "NUL", "-w", "%{http_code}", "--max-time", "15",
              "https://openeofed.dataspace.copernicus.eu/openeo/1.2/well-known/openeo"),
    stdout = TRUE, stderr = TRUE
  ))
  backend_up <- length(preflight) > 0 && grepl("^(200|404)$", preflight[1])
  # (404 on this exact sub-path still counts as "backend is up" - what
  # matters is getting ANY prompt HTTP response fast, not this specific
  # path resolving; a 503 or curl timeout/connection-refused means down.)

  if (!backend_up) {
    cat("  CDSE openEO backend pre-flight check failed (response: '",
        if (length(preflight) > 0) preflight[1] else "no response/timeout",
        "') - skipping this stage rather than risk hanging. Re-run this\n",
        "  script later once CDSE's service is back up.\n", sep = "")
  } else {
    Sys.setenv(SENTINEL_TEST_MODE = "0", SENTINEL_ESTIMATE_ONLY = "0")
    sentinel_res <- tryCatch({ source(file.path("..", "experimental", "fetch_sentinel2_ndvi.R")); "ok" }, error = function(e) e)
    if (inherits(sentinel_res, "error")) {
      cat("  Sentinel-2 fetch did not complete this run: ", conditionMessage(sentinel_res), "\n", sep = "")
      cat("  (non-fatal to this master pipeline - continuing with whatever sources ARE available)\n")
    }
  }
}

# ================================================================
# STAGE 3: Fetch Landsat NDVI - NOT BUILT AT ALL.
#
# *** PLACEHOLDER - no fetch script exists for this yet ***
# NINA's original used a bespoke GEE Landsat export (see
# VAAT-NDVI-01_wetland_pipeline.R Stage 5 header). Nobody has attempted a
# GEE-free Landsat equivalent to the MODIS/Sentinel-2 work above. If/when
# this gets built, the natural shape (matching the other two fetches):
#   - USGS EarthExplorer or the Microsoft Planetary Computer STAC API for
#     Landsat Collection 2 Level-2 surface reflectance (both public, no
#     GEE), 30m resolution, similar cloud-masking need (QA_PIXEL band).
#   - Add its own entry to VAAT-NDVI-01_trend_scaling.R's `sources` list
#     (min_area_m2 = 900, matching clean_ndvi()'s Landsat convention) -
#     no other change needed there, it already combines sources
#     generically.
# This stage intentionally does nothing but report that fact - it is not
# silently skipped without you knowing.
# ================================================================
cat_stage("STAGE 3: Fetch Landsat NDVI (NOT BUILT - placeholder only)")
cat("  No fetch script exists for Landsat yet. Skipping - see this stage's\n",
    "  header comment above for what would need to be built.\n", sep = "")

# ================================================================
# STAGE 4: Original NINA-style exploratory analysis - FULLY AUTOMATED,
# but gated on all three satellite sources existing (Sentinel-2 and
# Landsat, per its own Stage 5 requirement - see that script's header).
# Expected to still stop cleanly right now if either is missing - that's
# correct, documented behavior, not a bug this master script needs to
# work around. Wrapped so its expected early stop doesn't halt Stage 5
# below, which does NOT need all three sources to produce real output.
# ================================================================
cat_stage("STAGE 4: Run original exploratory pipeline (needs all 3 satellite sources)")
explore_res <- tryCatch({ source("VAAT-NDVI-01_wetland_pipeline.R"); "ok" }, error = function(e) e)
if (inherits(explore_res, "error")) {
  cat("  Did not complete (expected while Sentinel-2/Landsat are incomplete): ",
      conditionMessage(explore_res), "\n", sep = "")
}

# ================================================================
# STAGE 5: Trend-based scaling calculation + map - FULLY AUTOMATED, and
# the actual real deliverable of this indicator. Runs against whichever
# satellite source(s) are currently on disk (MODIS only, right now) and
# will automatically include Sentinel-2/Landsat the moment their fetches
# complete - no changes needed here when that happens.
# ================================================================
cat_stage("STAGE 5: Trend-based NDVI scaling (real 0-1 indicator + map)")
source("VAAT-NDVI-01_trend_scaling.R")

cat_stage(sprintf("VAAT-NDVI-01 MASTER PIPELINE - complete (%.1f minutes this run)",
                   as.numeric(difftime(Sys.time(), t0, units = "mins"))))
