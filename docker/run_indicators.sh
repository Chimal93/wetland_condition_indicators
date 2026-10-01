#!/usr/bin/env bash
# Run the indicator pipelines inside the Docker image and keep a full record
# of the run. Settings (which indicators, output folder, data sources) come
# from docker/config.env and docker/config.local.env - see docker/README.md.
#
# Usage, from the repository root:
#   bash docker/run_indicators.sh                       # all indicators
#   INDICATORS="GJEN" bash docker/run_indicators.sh     # only one
#
# The run takes minutes to hours and blocks the terminal, so start it inside
# a screen or tmux session. Progress: tail -f <run folder>/SUMMARY.txt
# Inputs that cannot be downloaded automatically (see docker/check_setup.sh)
# are checked first, so a run never fails or skips an indicator hours in.
bash "$(dirname "$0")/check_setup.sh" || exit 1
echo

. "$(dirname "$0")/internal/common.sh"

STAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="$RUNS_DIR/run_$STAMP"
mkdir -p "$RUN_DIR"

{
  echo "run: $STAMP"
  echo "repository: $REPO_DIR @ $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout')"
  echo "settings: INDICATORS=\"$INDICATORS\" GJEN_SOURCE=$GJEN_SOURCE RERUN_FETCH=$RERUN_FETCH"
  echo "image: $IMAGE"; docker image inspect --format '  id={{.Id}}  created={{.Created}}' "$IMAGE"
} > "$RUN_DIR/run_info.txt"

echo "Run folder: $RUN_DIR"
echo "Progress:   tail -f $RUN_DIR/SUMMARY.txt"
run_in_container "$RUN_DIR" --name "wetland_$STAMP" \
  -e INDICATORS="$INDICATORS" -e GJEN_SOURCE="$GJEN_SOURCE" -e RERUN_FETCH="$RERUN_FETCH" -e RUN_NAME="run_$STAMP" \
  -- bash /work/docker/internal/run_indicators_in_container.sh
docker rm "wetland_$STAMP" >/dev/null 2>&1 || true
echo "Finished. Run folder: $RUN_DIR"
