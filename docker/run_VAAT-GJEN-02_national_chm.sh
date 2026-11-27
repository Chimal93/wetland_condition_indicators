#!/usr/bin/env bash
# National canopy-height map over all AR5 mire for VAAT-GJEN-02, on the GPU.
# Code: VAAT-GJEN-02/src/chm_national/national_chm.py (its header explains the
# method). Python environment: VAAT-GJEN-02/src/chm_national/uv.lock, built on
# the first run into $RUNS_DIR/national_chm_env.
#
# Usage (inside screen; 11-14 h per model on an RTX 5090, mostly reading the mosaic):
#   bash docker/run_VAAT-GJEN-02_national_chm.sh chmv2
#   bash docker/run_VAAT-GJEN-02_national_chm.sh chmv1
# Extra arguments go to national_chm.py, e.g. a test over a small box:
#   NATIONAL_CHM_OUT_DIR=/some/test/folder \
#     bash docker/run_VAAT-GJEN-02_national_chm.sh chmv2 --bbox 260000 7020000 285600 7045600
# Rerunning the same command continues where it stopped.
#
# Settings (docker/config.local.env or in front of the command):
#   ORTHOPHOTO_SOURCE_PATH   the orthophoto mosaic (local file)
#   NATIONAL_CHM_OUT_DIR     output folder; may be on the network drive (required)
#   NATIONAL_CHM_AR5         AR5 mire GeoPackage (default: VAAT-GJEN-01's ar5_myr_national.gpkg)
#   HF_TOKEN / HF_HOME       Hugging Face login for CHMv2: the token in $HF_HOME/token
#                            (default ~/.cache/huggingface/token) or in HF_TOKEN
. "$(dirname "$0")/internal/common.sh"
. "$DOCKER_DIR/canopy_height_model/versions.env"

MODEL=${1:-}; shift || true
MODEL_DIR=$CHM_MODEL_DIR/HighResCanopyHeight-$MODEL_CODE_COMMIT
AR5=${NATIONAL_CHM_AR5:-$REPO_DIR/VAAT-GJEN-01/data/OpenS_data/ar5_myr_national.gpkg}
OUT=${NATIONAL_CHM_OUT_DIR:-}
ENV_DIR=$RUNS_DIR/national_chm_env
STAGING=$RUNS_DIR/national_chm_staging
SRC=$REPO_DIR/VAAT-GJEN-02/src/chm_national
HF=${HF_HOME:-$HOME/.cache/huggingface}

missing=0
miss() { echo "MISSING  $1"; shift; for l in "$@"; do echo "         $l"; done; missing=1; }
[[ "$MODEL" == chmv1 || "$MODEL" == chmv2 ]] || miss "model" "Give chmv1 or chmv2 as the first argument"
docker image inspect "$CHM_IMAGE" >/dev/null 2>&1 || miss "Docker image $CHM_IMAGE" "Build it with: bash docker/build_canopy_height_image.sh"
[ -f "$MODEL_DIR/saved_checkpoints/compressed_SSLhuge_aerial.pth" ] || miss "CHMv1 code and weights in $MODEL_DIR" "Download them with: bash docker/canopy_height_model/download_model_and_weights.sh"
[ -f "$ORTHOPHOTO_SOURCE_PATH" ] || miss "Orthophoto $ORTHOPHOTO_SOURCE_PATH" "Set ORTHOPHOTO_SOURCE_PATH to a local file (see docker/config.env)"
[ -f "$AR5" ] || miss "AR5 mire layer $AR5" "Build it with docker/prepare_ar5_input/ or set NATIONAL_CHM_AR5"
[ -n "$OUT" ] || miss "NATIONAL_CHM_OUT_DIR" "Set the output folder in docker/config.local.env"
if [ "$MODEL" = chmv2 ] && [ ! -f "$HF/token" ] && [ -z "${HF_TOKEN:-}" ]; then
  miss "Hugging Face login" "CHMv2 is gated: accept its terms on huggingface.co and log in (token in $HF/token)"
fi
[ $missing -eq 0 ] || exit 1
mkdir -p "$OUT" "$ENV_DIR" "$STAGING" "$HF"

ORTHO_DIR=$(dirname "$ORTHOPHOTO_SOURCE_PATH"); AR5_DIR=$(dirname "$AR5")
COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)$(git -C "$REPO_DIR" diff --quiet -- VAAT-GJEN-02/src/chm_national 2>/dev/null || echo "+uncommitted changes")
LOG="$OUT/national_chm_${MODEL}_$(date +%Y%m%d_%H%M%S).log"
echo "Log: $LOG"
docker run --rm --gpus all --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e USER=chm -e LOGNAME=chm -e TORCHINDUCTOR_CACHE_DIR=/tmp/ind -e HF_HOME=/hf -e HF_TOKEN \
  -e UV_CACHE_DIR="$ENV_DIR/.uvcache" -e UV_PYTHON_INSTALL_DIR="$ENV_DIR/.python" -e UV_PROJECT_ENVIRONMENT="$ENV_DIR/.venv" \
  -e CODE_COMMIT="$COMMIT" -e TZ="$HOST_TZ" \
  -v "$SRC:/code:ro" -v "$MODEL_DIR:/chmv1:ro" -v "$ORTHO_DIR:$ORTHO_DIR:ro" -v "$AR5_DIR:$AR5_DIR:ro" \
  -v "$HF:/hf" -v "$ENV_DIR:$ENV_DIR" -v "$STAGING:$STAGING" -v "$OUT:$OUT" \
  -w /tmp "$CHM_IMAGE" bash -c '
    set -e
    uv python install 3.12 >/dev/null 2>&1
    uv sync --locked --project /code --no-install-project >/dev/null
    exec "$UV_PROJECT_ENVIRONMENT/bin/python" -u /code/national_chm.py "$@"' _ \
    --model "$MODEL" --ortho "$ORTHOPHOTO_SOURCE_PATH" --ar5 "$AR5" --out "$OUT" --staging "$STAGING" "$@" \
  2>&1 | grep --line-buffered -v -E "Warning|warnings.warn|^\s*$" | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
