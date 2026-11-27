#!/usr/bin/env bash
# Build the canopy-height model image for VAAT-GJEN-02 (the R image plus a
# pinned Python environment). Build the R image first with build_image.sh.
# Usage: bash docker/build_canopy_height_image.sh
set -euo pipefail
. "$(dirname "$0")/internal/common.sh"
CTX=$DOCKER_DIR/canopy_height_model
. "$CTX/versions.env"
echo "Building $CHM_IMAGE on top of $IMAGE (Python $PYTHON_VERSION)..."
docker build -t "$CHM_IMAGE" \
  --build-arg R_IMAGE="$IMAGE" --build-arg UV_IMAGE="$UV_IMAGE" --build-arg PYTHON_VERSION="$PYTHON_VERSION" \
  --build-context chm="$REPO_DIR/VAAT-GJEN-02/src/chm_model" \
  "$CTX"
echo "Done: $CHM_IMAGE"
