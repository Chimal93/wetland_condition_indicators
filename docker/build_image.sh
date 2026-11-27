#!/usr/bin/env bash
# Build the Docker image with R and all packages pinned by renv.lock.
# Usage: bash docker/build_image.sh
# Optional: GITHUB_PAT=<token> bash docker/build_image.sh   (avoids GitHub rate limits)
set -euo pipefail
DOCKER_DIR=$(cd "$(dirname "$0")" && pwd); REPO_DIR=$(cd "$DOCKER_DIR/.." && pwd)
if [ -f "$DOCKER_DIR/config.local.env" ]; then set -a; . "$DOCKER_DIR/config.local.env"; set +a; fi
set -a; . "$DOCKER_DIR/config.env"; set +a
echo "Building $IMAGE from $DOCKER_DIR/Dockerfile (this takes a few minutes the first time)..."
docker build -f "$DOCKER_DIR/Dockerfile" -t "$IMAGE" ${GITHUB_PAT:+--build-arg GITHUB_PAT="$GITHUB_PAT"} "$REPO_DIR"
echo "Done: $IMAGE"
