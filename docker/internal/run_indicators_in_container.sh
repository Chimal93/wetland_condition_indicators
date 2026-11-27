#!/usr/bin/env bash
# Runs INSIDE the container, started by docker/run_indicators.sh. Mounts:
#   /work          the repository
#   /runs/current  this run's folder (logs, versions, result snapshots)
# Settings arrive as environment variables: INDICATORS, GJEN_SOURCE, RERUN_FETCH.
#
# Order: record software versions, snapshot the committed results, then run
# the selected indicators cheapest first (FUNC, CONN, GJEN2, NDVI, GJEN). Within one
# indicator a failed step stops that indicator; the others still run.
# Download steps whose output already exists are skipped unless RERUN_FETCH=yes.
# The repository's own scripts are never modified.
set -u
RUN=/runs/current
LOG=$RUN/logs
SUMMARY=$RUN/SUMMARY.txt
INDICATORS=${INDICATORS:-"FUNC CONN GJEN2 NDVI GJEN"}
GJEN_SOURCE=${GJEN_SOURCE:-AR5}
RERUN_FETCH=${RERUN_FETCH:-no}
mkdir -p "$LOG" "$RUN/versions" "$RUN/results_committed" "$RUN/results_after"
. /work/docker/internal/record_data_sources.sh
ALL_INDICATORS="NO_FUNC_003 NO_CONN_003 NO_GJEN_002 NO_NDVI_001 NO_GJEN_001"

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

say "Indicators: $INDICATORS   GJEN source: $GJEN_SOURCE   rerun fetch: $RERUN_FETCH"

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

# ---- 3. NO_FUNC_003 (about a minute) ----------------------------------------
# Needs data/OpenS_data/Tyler_data_raw.xlsx, which must be downloaded by hand
# (see NO_FUNC_003/README.md). The reference table wet_ref_openS.csv is
# committed, so the B12 fetch and reference build are not needed.
if want FUNC; then
  say "=== NO_FUNC_003 ==="
  if [ ! -f /work/NO_FUNC_003/data/OpenS_data/Tyler_data_raw.xlsx ]; then
    say "NO_FUNC_003 SKIPPED: data/OpenS_data/Tyler_data_raw.xlsx is missing (manual download, see NO_FUNC_003/README.md)"
  else
    step NO_FUNC_003 fetch_ano_data.R data/OpenS_data/ano_data/naturovervaking_eksport.gpkg \
      && step NO_FUNC_003 NO_FUNC_003_wetland_pipeline_OpenSource.R \
      && step NO_FUNC_003 export_deliverables.R \
      && step NO_FUNC_003 make_factor_report_maps.R \
      || say "NO_FUNC_003 FAILED (see its log)"
  fi
fi

# ---- 4. NO_CONN_003 (a few minutes with the published caches) ---------------
# download_caches.R checks file sizes itself and only downloads what is missing.
# The published caches are those of the mire-model variant, so this is the
# variant reproduced here, and its export goes to outputs/deliverables_MireModel/.
# The delivered AR5 variant (outputs/deliverables/) and its report map are a
# separate ~25 h run: docker/run_NO_CONN_003_ar5_variant.sh.
if want CONN; then
  say "=== NO_CONN_003 (mire-model variant) ==="
  step NO_CONN_003 download_caches.R \
    && step NO_CONN_003 NO_CONN_003_wetland_pipeline.R \
    && CONNECTIVITY_SCORE_LABEL=national_2023 CONN003_OUT_DIR=../outputs/deliverables_MireModel \
       step NO_CONN_003 export_deliverables.R \
    || say "NO_CONN_003 FAILED (see its log)"
fi

# ---- 4b. NO_GJEN_002 (minutes, from the committed 20 m cell tables) ---------
# Exports the deliverables from data/OpenS_data/orthophoto_chmv2_20m_cells/,
# the tables of the national 20 m cell run. That run needs the orthophoto, a
# GPU and hours: docker/run_NO_GJEN_002_deliverables.sh does all of it. The
# earlier NiN-polygon version (000.003, R/NO_GJEN_002_national_pipeline.R)
# is superseded and no longer run here.
if want GJEN2; then
  say "=== NO_GJEN_002 ==="
  step NO_GJEN_002 export_deliverables_20m_cells.R \
    || say "NO_GJEN_002 FAILED (see its log)"
fi

# ---- 4c. NO_NDVI_001 (minutes, from the committed MODIS series) -------------
# Provisional indicator (see NO_NDVI_001/README.md). Recomputes the trends
# from data/NDVI_MODIS/modis_ndvi_ts_national.csv.gz, upstream's national
# MODIS download. fetch_modis_ndvi.R is not run: it needs a NASA Earthdata
# token and takes hours.
if want NDVI; then
  say "=== NO_NDVI_001 (provisional) ==="
  step NO_NDVI_001 fetch_nin_data.R data/nin_data/Naturtyper_nin_0000_norge_4326_FILEGDB.gdb \
    && step NO_NDVI_001 NO_NDVI_001_trend_scaling.R \
    && step NO_NDVI_001 export_deliverables.R \
    && step NO_NDVI_001 make_report_map.R \
    || say "NO_NDVI_001 FAILED (see its log)"
fi

# ---- 5. NO_GJEN_001 (hours on a first run) ----------------------------------
# Not run on purpose: build_ssb_grids.R (its outputs are committed),
# extract_ar5_skog_myr.R (expects a single pre-merged AR5 file), quick_test_small_aoi.R.
gjen_polygons() {
  local d=/work/NO_GJEN_001/data/OpenS_data
  case "$GJEN_SOURCE" in
    AR5)
      # The national layers are prepared once, outside the run, with
      # docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh.
      # check_setup.sh has already verified this on the host; this is a safety net.
      if [ -f "$d/ar5_skog_national.gpkg" ] && [ -f "$d/ar5_myr_national.gpkg" ]; then
        say "AR5 layers present: ar5_skog_national.gpkg and ar5_myr_national.gpkg"; return 0
      fi
      say "AR5 layers missing in NO_GJEN_001/data/OpenS_data - see docker/check_setup.sh"; return 1 ;;
    AR50)
      if [ -f "$d/ar5_skog_national.gpkg" ] || [ -f "$d/ar5_myr_national.gpkg" ]; then
        say "WARNING: GJEN_SOURCE=AR50 but AR5 files exist in data/OpenS_data - the pipeline prefers AR5 when present. Remove them to force AR50."
      fi
      # build_ar50_wetland_lidar_coverage.R also rewrites the committed
      # dtm1_tile_footprint.gpkg from today's LiDAR feed; the committed tile
      # index is restored afterwards so results stay comparable.
      local foot=$d/dtm1_tile_footprint.gpkg
      cp "$foot" "$RUN/dtm1_tile_footprint.committed.gpkg"
      step NO_GJEN_001 build_ar50_wetland_lidar_coverage.R data/OpenS_data/ar50_myr_national.gpkg
      local rc=$?
      if [ -f "$RUN/dtm1_tile_footprint.committed.gpkg" ] && ! cmp -s "$foot" "$RUN/dtm1_tile_footprint.committed.gpkg"; then
        cp "$foot" "$RUN/dtm1_tile_footprint.refetched.gpkg"; cp "$RUN/dtm1_tile_footprint.committed.gpkg" "$foot"
        say "restored the committed dtm1_tile_footprint.gpkg (today's version kept in the run folder)"
      fi
      [ $rc -eq 0 ] && step NO_GJEN_001 build_ar50_skog.R data/OpenS_data/ar50_skog_national.gpkg ;;
    *) say "Unknown GJEN_SOURCE '$GJEN_SOURCE' (use AR5 or AR50)"; return 1 ;;
  esac
}
if want GJEN; then
  say "=== NO_GJEN_001 ==="
  step NO_GJEN_001 fetch_bioclim_zones.R data/OpenS_data/bioclim/soner2017.shp \
    && step NO_GJEN_001 fetch_disturbance.R data/OpenS_data/disturbance/disturbance_year_1986-2020_norway.tif \
    && step NO_GJEN_001 fetch_osm_buildings.R data/OpenS_data/osm_buildings_national.gpkg \
    && step NO_GJEN_001 fetch_nin_data.R data/OpenS_data/nin_data/Naturtyper_nin_0000_norge_4326_FILEGDB.gdb \
    && gjen_polygons \
    && step NO_GJEN_001 build_refvaatmark_30m.R data/OpenS_data/refvaatmark_30m/refvaatmark_30m.csv \
    && step NO_GJEN_001 NO_GJEN_001_wetland_pipeline_OpenSource.R \
    && step NO_GJEN_001 export_deliverables.R \
    && step NO_GJEN_001 make_report_map.R \
    || say "NO_GJEN_001 FAILED (see its log)"
fi

# ---- 6. results after the run ----------------------------------------------
snapshot "$RUN/results_after"
say "Recording the inputs this run used -> data_sources.csv"
inds=(); want FUNC && inds+=(NO_FUNC_003); want CONN && inds+=(NO_CONN_003)
want GJEN2 && inds+=(NO_GJEN_002); want NDVI && inds+=(NO_NDVI_001); want GJEN && inds+=(NO_GJEN_001)
write_data_sources "$RUN/data_sources.csv" "${inds[@]}"
say "ALL DONE. Results before/after this run: results_committed/ and results_after/ in this folder."
