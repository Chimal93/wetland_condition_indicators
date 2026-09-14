#!/usr/bin/env bash
# Run ONE R script from the repository inside the Docker image, with the
# script's own folder as working directory (which is what the scripts expect).
# Usage: bash docker/run_script.sh NO_FUNC_003/Fetch/get_tyler_data.R
. "$(dirname "$0")/internal/common.sh"
[ $# -eq 1 ] || { echo "usage: bash docker/run_script.sh <path/to/script.R, relative to the repository root>"; exit 1; }
[ -f "$REPO_DIR/$1" ] || { echo "No such script: $REPO_DIR/$1"; exit 1; }
tty=(); [ -t 0 ] && tty=(-it)
run_in_container "$RUNS_DIR/single_scripts" --rm "${tty[@]}" -w "/work/$(dirname "$1")" -- Rscript "$(basename "$1")"
