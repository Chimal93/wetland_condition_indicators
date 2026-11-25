#!/usr/bin/env bash
# Run the AR5 variant of NO_CONN_003 (the delivered one) inside the Docker
# image. Bash replacement for upstream's NO_CONN_003/src/run_connectivity_ar5.ps1.
#
# About 25 hours on the first run (certified distances for Midt-Norge and
# Østlandet dominate). Resumable: rerunning skips regions already done.
# Start it inside a screen or tmux session. Progress:
#   tail -f <run folder>/SUMMARY.txt
#
# Needs, before the first run:
#   - NO_GJEN_001/data/OpenS_data/ar5_myr_national.gpkg, built with
#     docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh
#   - NO_CONN_003/data/LUI_output/LUI_2023.tif, the infrastructure layer
#     from the normal NO_CONN_003 run:  INDICATORS="CONN" bash docker/run_indicators.sh
#
# Usage, from the repository root:
#   bash docker/run_NO_CONN_003_ar5_variant.sh
. "$(dirname "$0")/internal/common.sh"

AR5=NO_GJEN_001/data/OpenS_data/ar5_myr_national.gpkg
LUI=NO_CONN_003/data/LUI_output/LUI_2023.tif
missing=0
[ -f "$REPO_DIR/$AR5" ] || { echo "MISSING  $AR5"; echo "         Build it with: bash docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh /path/to/FKB-AR5-folder"; missing=1; }
[ -f "$REPO_DIR/$LUI" ] || { echo "MISSING  $LUI"; echo "         Run the normal NO_CONN_003 pipeline first: INDICATORS=\"CONN\" bash docker/run_indicators.sh"; missing=1; }
[ $missing -eq 0 ] || exit 1

STAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="$RUNS_DIR/conn003_ar5_$STAMP"
mkdir -p "$RUN_DIR"
{
  echo "run: NO_CONN_003 AR5 variant, $STAMP"
  echo "repository: $REPO_DIR @ $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout')"
  echo "wetland population: $AR5  $(stat -c '%s bytes, modified %y' "$REPO_DIR/$AR5")"
  echo "image: $IMAGE"; docker image inspect --format '  id={{.Id}}  created={{.Created}}' "$IMAGE"
} > "$RUN_DIR/run_info.txt"

echo "Run folder: $RUN_DIR"
echo "Progress:   tail -f $RUN_DIR/SUMMARY.txt"
rc=0  # common.sh sets -e; capture the exit code so the container is still removed
run_in_container "$RUN_DIR" --name "conn003_ar5_$STAMP" \
  -e AR5_MYR_GPKG="/work/$AR5" \
  -- bash /work/docker/internal/run_NO_CONN_003_ar5_variant_in_container.sh || rc=$?
docker rm "conn003_ar5_$STAMP" >/dev/null 2>&1 || true
echo "Finished (exit $rc). Run folder: $RUN_DIR"
exit $rc
