#!/usr/bin/env bash
# Runs INSIDE the container, started by docker/run_indicators.sh. Mounts:
#   /work          the repository
#   /runs/current  this run's folder (logs, versions, result snapshots)
# Settings arrive as environment variables: INDICATORS, VAAT_GJEN_01_SOURCE, RERUN_FETCH.
#
# Order: record software versions, snapshot the committed results, then run
# the selected indicators cheapest first (VAAT-FUNC-01, VAAT-CONN-01, VAAT-GJEN-02, VAAT-NDVI-01, VAAT-GJEN-01). Within one
# indicator a failed step stops that indicator; the others still run.
# Download steps whose output already exists are skipped unless RERUN_FETCH=yes.
# The repository's own scripts are never modified.
set -u
RUN=/runs/current
LOG=$RUN/logs
SUMMARY=$RUN/SUMMARY.txt
INDICATORS=${INDICATORS:-"VAAT-FUNC-01 VAAT-CONN-01 VAAT-GJEN-02 VAAT-NDVI-01 VAAT-GJEN-01"}
VAAT_GJEN_01_SOURCE=${VAAT_GJEN_01_SOURCE:-AR5}
RERUN_FETCH=${RERUN_FETCH:-no}
mkdir -p "$LOG" "$RUN/versions" "$RUN/results_committed" "$RUN/results_after"
. /work/docker/internal/record_data_sources.sh
ALL_INDICATORS="VAAT-VAAT-FUNC-01-01 VAAT-VAAT-CONN-01-01 VAAT-VAAT-GJEN-01-02 VAAT-VAAT-NDVI-01-01 VAAT-VAAT-GJEN-01-01"

say()  { echo "$(date '+%F %T')  $*" | tee -a "$SUMMARY"; }
stamp_lines() { while IFS= read -r line || [ -n "$line" ]; do echo "$(date '+%F %T')  $line"; done; }
want() { [[ " $INDICATORS " == *" $1 "* ]]; }

# step <indicator> <script.R in R/> [output that marks the step as done]
step() {
  local ind=$1 script=$2 done_marker=${3:-}
  local log="$LOG/${ind}__${script%.R}.log"
  if [ -n "$done_marker" ] && [ "$RERUN_FETCH" != "yes" ] && [ -e "/work/$ind/$done_marker" ]; then
    say "SKIP  $ind/R/$script  (output exists: $done_marker)"; return 0
  fi
  say "START $ind/R/$script"
  local t0=$SECONDS
  # Every line gets a timestamp. stdbuf makes R write line by line instead
  # of in buffered chunks, so the timestamps are true and tail -f is live.
  ( cd "/work/$ind/R" && stdbuf -oL -eL Rscript "$script" ) 2>&1 | stamp_lines > "$log"
  local rc=${PIPESTATUS[0]}
  say "END   $ind/R/$script  rc=$rc  $(( (SECONDS - t0) / 60 )) min  -> logs/$(basename "$log")"
  # Record when and from where the data was fetched (see docker/data_sources.tsv;
  # scripts not listed there as a download step log nothing).
  [ "$rc" -eq 0 ] && log_fetch "$ind" "R/$script" "${RUN_NAME:-}"
  return $rc
}

say "Indicators: $INDICATORS   VAAT-GJEN-01 source: $VAAT_GJEN_01_SOURCE   rerun fetch: $RERUN_FETCH"

# ---- 1. record the software versions --------------------------------------
say "Recording software versions -> versions/"
Rscript - <<'REOF' > "$RUN/versions/record_versions.log" 2>&1
suppressPackageStartupMessages({ library(sf); library(terra); library(dplyr); library(ggplot2); library(ecTools) })
sink("/runs/current/versions/sessionInfo.txt")
cat(R.version.string, "\n\n"); print(sessionInfo())
cat("\n--- GDAL/GEOS/PROJ used by sf ---\n"); print(sf::sf_extSoftVersion())
cat("\n--- terra ---\n"); print(terra::gdal(lib = "all"))
cat("\n--- locale ---\n"); print(Sys.getlocale()); print(l10n_info())
sink()
write.csv(installed.packages()[, c("Package", "Version", "LibPath")], "/runs/current/versions/installed_packages.csv", row.names = FALSE)
for (l in Sys.glob("/work/NO_*/renv.lock")) file.copy(l, file.path("/runs/current/versions", paste0(basename(dirname(l)), "_renv.lock")), overwrite = TRUE)
REOF

# ---- 2. keep a copy of the results as they were before this run ------------
# outputs/ (results, and the platform-format deliverables) of every indicator.
snapshot() {
  local ind
  for ind in $ALL_INDICATORS; do
    mkdir -p "$1/$ind"
    [ -d "/work/$ind/outputs" ] && cp -r "/work/$ind/outputs" "$1/$ind/"
  done
}
snapshot "$RUN/results_committed"

# ---- 3. VAAT-FUNC-01 (about a minute) ----------------------------------------
# Needs data/OpenS_data/Tyler_data_raw.xlsx, which must be downloaded by hand
# (see VAAT-FUNC-01/README.md). The reference table wet_ref_openS.csv is
# committed, so the B12 fetch and reference build are not needed.
if want VAAT-FUNC-01; then
  say "=== VAAT-FUNC-01 ==="
  if [ ! -f /work/VAAT-FUNC-01/data/OpenS_data/Tyler_data_raw.xlsx ]; then
    say "VAAT-FUNC-01 SKIPPED: data/OpenS_data/Tyler_data_raw.xlsx is missing (manual download, see VAAT-FUNC-01/README.md)"
  else
    step VAAT-FUNC-01 fetch_ano_data.R data/OpenS_data/ano_data/naturovervaking_eksport.gpkg \
      && step VAAT-FUNC-01 VAAT-FUNC-01_wetland_pipeline_OpenSource.R \
      && step VAAT-FUNC-01 export_deliverables.R \
      && step VAAT-FUNC-01 make_factor_report_maps.R \
      || say "VAAT-FUNC-01 FAILED (see its log)"
  fi
fi

# ---- 4. VAAT-CONN-01 (a few minutes with the published caches) ---------------
# download_caches.R checks file sizes itself and only downloads what is missing.
# The published caches are those of the mire-model variant, so this is the
# variant reproduced here, and its export goes to outputs/deliverables_MireModel/.
# The delivered AR5 variant (outputs/deliverables/) and its report map are a
# separate ~25 h run: docker/run_VAAT-CONN-01_ar5_variant.sh.
if want VAAT-CONN-01; then
  say "=== VAAT-CONN-01 (mire-model variant) ==="
  step VAAT-CONN-01 download_caches.R \
    && step VAAT-CONN-01 VAAT-CONN-01_wetland_pipeline.R \
    && CONNECTIVITY_SCORE_LABEL=national_2023 VAAT_CONN_01_OUT_DIR=../outputs/deliverables_MireModel \
       step VAAT-CONN-01 export_deliverables.R \
    || say "VAAT-CONN-01 FAILED (see its log)"
fi

# ---- 4b. VAAT-GJEN-02 (minutes, from the committed 20 m cell tables) ---------
# Exports the deliverables from data/OpenS_data/orthophoto_chmv2_20m_cells/,
# the tables of the national 20 m cell run. That run needs the orthophoto, a
# GPU and hours: docker/run_VAAT-GJEN-02_deliverables.sh does all of it. The
# earlier NiN-polygon version (000.003, R/VAAT-GJEN-02_national_pipeline.R)
# is superseded and no longer run here.
if want VAAT-GJEN-02; then
  say "=== VAAT-GJEN-02 ==="
  step VAAT-GJEN-02 export_deliverables_20m_cells.R \
    || say "VAAT-GJEN-02 FAILED (see its log)"
fi

# ---- 4c. VAAT-NDVI-01 (minutes, from the committed MODIS series) -------------
# Provisional indicator (see VAAT-NDVI-01/README.md). Recomputes the trends
# from data/NDVI_MODIS/modis_ndvi_ts_national.csv.gz, upstream's national
# MODIS download. fetch_modis_ndvi.R is not run: it needs a NASA Earthdata
# token and takes hours.
if want VAAT-NDVI-01; then
  say "=== VAAT-NDVI-01 (provisional) ==="
  step VAAT-NDVI-01 fetch_nin_data.R data/nin_data/Naturtyper_nin_0000_norge_4326_FILEGDB.gdb \
    && step VAAT-NDVI-01 VAAT-NDVI-01_trend_scaling.R \
    && step VAAT-NDVI-01 export_deliverables.R \
    && step VAAT-NDVI-01 make_report_map.R \
    || say "VAAT-NDVI-01 FAILED (see its log)"
fi

# ---- 5. VAAT-GJEN-01 (hours on a first run) ----------------------------------
# Not run on purpose: build_ssb_grids.R (its outputs are committed),
# extract_ar5_skog_myr.R (expects a single pre-merged AR5 file), quick_test_small_aoi.R.
gjen_polygons() {
  local d=/work/VAAT-GJEN-01/data/OpenS_data
  case "$VAAT_GJEN_01_SOURCE" in
    AR5)
      # The national layers are prepared once, outside the run, with
      # docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh.
      # check_setup.sh has already verified this on the host; this is a safety net.
      if [ -f "$d/ar5_skog_national.gpkg" ] && [ -f "$d/ar5_myr_national.gpkg" ]; then
        say "AR5 layers present: ar5_skog_national.gpkg and ar5_myr_national.gpkg"; return 0
      fi
      say "AR5 layers missing in VAAT-GJEN-01/data/OpenS_data - see docker/check_setup.sh"; return 1 ;;
    AR50)
      if [ -f "$d/ar5_skog_national.gpkg" ] || [ -f "$d/ar5_myr_national.gpkg" ]; then
        say "WARNING: VAAT_GJEN_01_SOURCE=AR50 but AR5 files exist in data/OpenS_data - the pipeline prefers AR5 when present. Remove them to force AR50."
      fi
      # build_ar50_wetland_lidar_coverage.R also rewrites the committed
      # dtm1_tile_footprint.gpkg from today's LiDAR feed; the committed tile
      # index is restored afterwards so results stay comparable.
      local foot=$d/dtm1_tile_footprint.gpkg
      cp "$foot" "$RUN/dtm1_tile_footprint.committed.gpkg"
      step VAAT-GJEN-01 build_ar50_wetland_lidar_coverage.R data/OpenS_data/ar50_myr_national.gpkg
      local rc=$?
      if [ -f "$RUN/dtm1_tile_footprint.committed.gpkg" ] && ! cmp -s "$foot" "$RUN/dtm1_tile_footprint.committed.gpkg"; then
        cp "$foot" "$RUN/dtm1_tile_footprint.refetched.gpkg"; cp "$RUN/dtm1_tile_footprint.committed.gpkg" "$foot"
        say "restored the committed dtm1_tile_footprint.gpkg (today's version kept in the run folder)"
      fi
      [ $rc -eq 0 ] && step VAAT-GJEN-01 build_ar50_skog.R data/OpenS_data/ar50_skog_national.gpkg ;;
    *) say "Unknown VAAT_GJEN_01_SOURCE '$VAAT_GJEN_01_SOURCE' (use AR5 or AR50)"; return 1 ;;
  esac
}
if want VAAT-GJEN-01; then
  say "=== VAAT-GJEN-01 ==="
  step VAAT-GJEN-01 fetch_bioclim_zones.R data/OpenS_data/bioclim/soner2017.shp \
    && step VAAT-GJEN-01 fetch_disturbance.R data/OpenS_data/disturbance/disturbance_year_1986-2020_norway.tif \
    && step VAAT-GJEN-01 fetch_osm_buildings.R data/OpenS_data/osm_buildings_national.gpkg \
    && step VAAT-GJEN-01 fetch_nin_data.R data/OpenS_data/nin_data/Naturtyper_nin_0000_norge_4326_FILEGDB.gdb \
    && gjen_polygons \
    && step VAAT-GJEN-01 build_refvaatmark_30m.R data/OpenS_data/refvaatmark_30m/refvaatmark_30m.csv \
    && step VAAT-GJEN-01 VAAT-GJEN-01_wetland_pipeline_OpenSource.R \
    && step VAAT-GJEN-01 export_deliverables.R \
    && step VAAT-GJEN-01 make_report_map.R \
    || say "VAAT-GJEN-01 FAILED (see its log)"
fi

# ---- 6. results after the run ----------------------------------------------
snapshot "$RUN/results_after"
say "Recording the inputs this run used -> data_sources.csv"
inds=(); want VAAT-FUNC-01 && inds+=(VAAT-FUNC-01); want VAAT-CONN-01 && inds+=(VAAT-CONN-01)
want VAAT-GJEN-02 && inds+=(VAAT-GJEN-02); want VAAT-NDVI-01 && inds+=(VAAT-NDVI-01); want VAAT-GJEN-01 && inds+=(VAAT-GJEN-01)
write_data_sources "$RUN/data_sources.csv" "${inds[@]}"
say "ALL DONE. Results before/after this run: results_committed/ and results_after/ in this folder."
