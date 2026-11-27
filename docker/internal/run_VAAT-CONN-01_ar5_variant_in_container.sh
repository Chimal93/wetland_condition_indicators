#!/usr/bin/env bash
# Runs INSIDE the container, started by docker/run_VAAT-CONN-01_ar5_variant.sh.
# Bash version of upstream's VAAT-CONN-01/src/run_connectivity_ar5.ps1, same
# steps, folders and label, plus the two steps the README lists after it:
#   1. prepare wetland patches per region    (R/prepare_ar5_mire_regions.R)
#   2. certified nearest-mire distance       (R/run_region_certified.R)
#   3. infrastructure distance + kvotient    (R/compute_infra_distance_region.R)
#   4. scaling + regional map + write-out    (R/scale_and_map_connectivity_indicator.R)
#   5. platform-format deliverables          (R/export_deliverables.R)
#   6. report map                            (R/make_report_map.R)
# Resumable: steps 1-3 skip a region whose output already exists.
# The repository's own scripts are never modified.
set -u
RUN=/runs/current
LOG=$RUN/logs
SUMMARY=$RUN/SUMMARY.txt
mkdir -p "$LOG"

say() { echo "$(date '+%F %T')  $*" | tee -a "$SUMMARY"; }
stamp_lines() { while IFS= read -r line || [ -n "$line" ]; do echo "$(date '+%F %T')  $line"; done; }

# step <script.R in R/> <log name>
step() {
  local script=$1 log="$LOG/$2.log"
  say "START R/$script  ${CONNECTIVITY_REGION:+(region $CONNECTIVITY_REGION)}"
  local t0=$SECONDS
  ( cd /work/VAAT-CONN-01/R && stdbuf -oL -eL Rscript "$script" ) 2>&1 | stamp_lines > "$log"
  local rc=${PIPESTATUS[0]}
  say "END   R/$script  rc=$rc  $(( (SECONDS - t0) / 60 )) min  -> logs/$(basename "$log")"
  return $rc
}

# Same settings as run_connectivity_ar5.ps1. AR5_MYR_GPKG is set by the
# host script so the preparation never falls back to AR50 silently.
export CONNECTIVITY_MIRE_DIR=../data/wetland_map_ar5
export CONNECTIVITY_OUT_DIR=../data/connectivity_output_ar5
export CONNECTIVITY_SCORE_DIR=../data/connectivity_output_ar5
export CONNECTIVITY_SCORE_PATTERN='connectivity_full_2023\.gpkg$'
export CONNECTIVITY_SCORE_LABEL=national_2023_AR5

# ASCII names; the R scripts map them to the Norwegian spelling.
REGIONS=(Nord-Norge Sorlandet Vestlandet Midt-Norge Ostlandet)
declare -A ASCII=([Nord-Norge]=nord_norge [Midt-Norge]=midt_norge [Vestlandet]=vestlandet [Ostlandet]=ostlandet [Sorlandet]=sorlandet)
OUT=/work/VAAT-CONN-01/data/connectivity_output_ar5

say "VAAT-CONN-01 AR5 variant. Wetland population: $AR5_MYR_GPKG"
# The inputs of this run (AR5 mires from VAAT-GJEN-01, infrastructure layers
# from VAAT-CONN-01), with sizes, dates and checksums.
. /work/docker/internal/record_data_sources.sh
write_data_sources "$RUN/data_sources.csv" VAAT-CONN-01 VAAT-GJEN-01
failed=()

export CONNECTIVITY_REGIONS=$(IFS=,; echo "${REGIONS[*]}")
step prepare_ar5_mire_regions.R prepare \
  || { say "Preparation FAILED - nothing else can run. See logs/prepare.log"; exit 1; }

for r in "${REGIONS[@]}"; do
  a=${ASCII[$r]}
  export CONNECTIVITY_REGION=$r
  if [ -e "$OUT/${a}_min_myr_distance_certified.gpkg" ]; then
    say "SKIP  $r certified nearest-mire distance (output exists)"
  else
    step run_region_certified.R "certified_$a" || { failed+=("$r"); continue; }
  fi
  if [ -e "$OUT/${a}_connectivity_full_2023.gpkg" ]; then
    say "SKIP  $r infrastructure distance (output exists)"
  else
    step compute_infra_distance_region.R "infra_$a" || failed+=("$r")
  fi
done
unset CONNECTIVITY_REGION

# Scaling uses the anchors of the whole national distribution, so it must
# not run on an incomplete set of regions.
if [ ${#failed[@]} -gt 0 ]; then
  say "FAILED regions: ${failed[*]}. Scaling and export NOT run - rerun this script to resume."
  exit 1
fi
step scale_and_map_connectivity_indicator.R scale \
  && step export_deliverables.R export_deliverables \
  && step make_report_map.R report_map \
  || { say "Scaling, export or report map FAILED (see its log)"; exit 1; }
say "ALL DONE. Deliverables: VAAT-CONN-01/outputs/deliverables/ (compare with git diff)"
