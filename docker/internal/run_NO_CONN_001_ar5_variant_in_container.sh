#!/usr/bin/env bash
# Runs INSIDE the container, started by docker/run_NO_CONN_001_ar5_variant.sh.
# Bash version of upstream's NO_CONN_001/run_connectivity_ar5.ps1, same
# steps, folders and label, plus the deliverables export the README lists
# as the next step:
#   1. prepare wetland patches per region    (Fetch/prepare_ar5_mire_regions.R)
#   2. certified nearest-mire distance       (Fetch/run_region_certified.R)
#   3. infrastructure distance + kvotient    (Fetch/compute_infra_distance_region.R)
#   4. scaling + regional map + write-out    (Fetch/scale_and_map_connectivity_indicator.R)
#   5. platform-format deliverables          (Main/export_deliverables.R)
# Resumable: steps 1-3 skip a region whose output already exists.
# The repository's own scripts are never modified.
set -u
RUN=/runs/current
LOG=$RUN/logs
SUMMARY=$RUN/SUMMARY.txt
mkdir -p "$LOG"

say() { echo "$(date '+%F %T')  $*" | tee -a "$SUMMARY"; }
stamp_lines() { while IFS= read -r line || [ -n "$line" ]; do echo "$(date '+%F %T')  $line"; done; }

# step <subfolder> <script.R> <log name>
step() {
  local dir=$1 script=$2 log="$LOG/$3.log"
  say "START $dir/$script  ${CONNECTIVITY_REGION:+(region $CONNECTIVITY_REGION)}"
  local t0=$SECONDS
  ( cd "/work/NO_CONN_001/$dir" && stdbuf -oL -eL Rscript "$script" ) 2>&1 | stamp_lines > "$log"
  local rc=${PIPESTATUS[0]}
  say "END   $dir/$script  rc=$rc  $(( (SECONDS - t0) / 60 )) min  -> logs/$(basename "$log")"
  return $rc
}

# Same settings as run_connectivity_ar5.ps1. AR5_MYR_GPKG is set by the
# host script so the preparation never falls back to AR50 silently.
export CONNECTIVITY_MIRE_DIR=../Data/wetland_map_ar5
export CONNECTIVITY_OUT_DIR=../Data/connectivity_output_ar5
export CONNECTIVITY_SCORE_DIR=../Data/connectivity_output_ar5
export CONNECTIVITY_SCORE_PATTERN='connectivity_full_2023\.gpkg$'
export CONNECTIVITY_SCORE_LABEL=national_2023_AR5

# ASCII names; the R scripts map them to the Norwegian spelling.
REGIONS=(Nord-Norge Sorlandet Vestlandet Midt-Norge Ostlandet)
declare -A ASCII=([Nord-Norge]=nord_norge [Midt-Norge]=midt_norge [Vestlandet]=vestlandet [Ostlandet]=ostlandet [Sorlandet]=sorlandet)
OUT=/work/NO_CONN_001/Data/connectivity_output_ar5

say "NO_CONN_001 AR5 variant. Wetland population: $AR5_MYR_GPKG"
failed=()

export CONNECTIVITY_REGIONS=$(IFS=,; echo "${REGIONS[*]}")
step Fetch prepare_ar5_mire_regions.R prepare \
  || { say "Preparation FAILED - nothing else can run. See logs/prepare.log"; exit 1; }

for r in "${REGIONS[@]}"; do
  a=${ASCII[$r]}
  export CONNECTIVITY_REGION=$r
  if [ -e "$OUT/${a}_min_myr_distance_certified.gpkg" ]; then
    say "SKIP  $r certified nearest-mire distance (output exists)"
  else
    step Fetch run_region_certified.R "certified_$a" || { failed+=("$r"); continue; }
  fi
  if [ -e "$OUT/${a}_connectivity_full_2023.gpkg" ]; then
    say "SKIP  $r infrastructure distance (output exists)"
  else
    step Fetch compute_infra_distance_region.R "infra_$a" || failed+=("$r")
  fi
done
unset CONNECTIVITY_REGION

# Scaling uses the anchors of the whole national distribution, so it must
# not run on an incomplete set of regions.
if [ ${#failed[@]} -gt 0 ]; then
  say "FAILED regions: ${failed[*]}. Scaling and export NOT run - rerun this script to resume."
  exit 1
fi
step Fetch scale_and_map_connectivity_indicator.R scale \
  && step Main export_deliverables.R export_deliverables \
  || { say "Scaling or export FAILED (see its log)"; exit 1; }
say "ALL DONE. Deliverables: NO_CONN_001/Deliverables/ (compare with git diff)"
