# Shared by the host-side scripts in docker/. Not meant to be run directly.
# Resolves folders, loads settings and defines run_in_container().
set -euo pipefail
DOCKER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR=$(cd "$DOCKER_DIR/.." && pwd)

# Precedence (highest first): variables already set in the shell,
# docker/config.local.env, docker/config.env.
if [ -f "$DOCKER_DIR/config.local.env" ]; then
  set -a; . "$DOCKER_DIR/config.local.env"; set +a
fi
set -a; . "$DOCKER_DIR/config.env"; set +a

HOST_TZ=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC)

docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { echo "Docker image '$IMAGE' not found. Build it first: bash docker/build_image.sh"; exit 1; }

# run_in_container <run_dir> [docker run options...] -- <command...>
# Starts the image as the current user with the repository mounted at /work,
# the run folder at /runs/current and the shared download cache at
# /runs/osm_cache. Extra "docker run" options go before "--".
run_in_container() {
  local run_dir=$1; shift
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  mkdir -p "$run_dir/home" "$run_dir/tmp" "$RUNS_DIR/osm_cache"
  docker run --user "$(id -u):$(id -g)" \
    -v "$REPO_DIR:/work" \
    -v "$run_dir:/runs/current" \
    -v "$RUNS_DIR/osm_cache:/runs/osm_cache" \
    -e HOME=/runs/current/home \
    -e TMPDIR=/runs/current/tmp \
    -e OSMEXT_DOWNLOAD_DIRECTORY=/runs/osm_cache \
    -e TZ="$HOST_TZ" \
    "${extra[@]}" "$IMAGE" "$@"
}
