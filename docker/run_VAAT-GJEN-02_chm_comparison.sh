#!/usr/bin/env bash
# Canopy-height model comparison against LiDAR for VAAT-GJEN-02: CHMv1 and CHMv2
# on the ~25,000 AR5 mire sample cells of VAAT-GJEN-01, the choice of CHMv2, its
# calibration to LiDAR and the validation cells for the uncertainty.
# Code and method: VAAT-GJEN-02/src/chm_comparison/README.md.
#
# Usage (inside screen; ~3.5 h for all points on an RTX 5090):
#   bash docker/run_VAAT-GJEN-02_chm_comparison.sh
#   N_PER_STRATUM=4 OUT=out_test bash docker/run_VAAT-GJEN-02_chm_comparison.sh   # quick test
# Every step is skipped if its output exists, so a stopped run continues.
#
# Settings (docker/config.local.env or in front of the command):
#   ORTHOPHOTO_SOURCE_PATH  the orthophoto mosaic (local file), with its
#                           metadata/ folder next to it
#   CHM_COMPARISON_DIR      working folder (default: $RUNS_DIR/chm_comparison);
#                           output in its sub-folder OUT (default out_25k)
#   N_PER_STRATUM           0 = all points (default); N = N per stratum
#   KEEP_TILES              the photo windows (~25 GB) are deleted at the end
#                           unless yes
#   HF_TOKEN / HF_HOME      Hugging Face login for CHMv2 (see VAAT-GJEN-02/README.md)
. "$(dirname "$0")/internal/common.sh"
. "$DOCKER_DIR/canopy_height_model/versions.env"

WORK=${CHM_COMPARISON_DIR:-$RUNS_DIR/chm_comparison}
export OUT=${OUT:-out_25k} N_PER_STRATUM=${N_PER_STRATUM:-0}
KEEP_TILES=${KEEP_TILES:-no}
MODEL_DIR=$CHM_MODEL_DIR/HighResCanopyHeight-$MODEL_CODE_COMMIT
SRC=$REPO_DIR/VAAT-GJEN-02/src/chm_comparison
G1=$REPO_DIR/VAAT-GJEN-01/data/OpenS_data
ENV_DIR=$RUNS_DIR/chm_comparison_env
HF=${HF_HOME:-$HOME/.cache/huggingface}

missing=0
miss() { echo "MISSING  $1"; shift; for l in "$@"; do echo "         $l"; done; missing=1; }
docker image inspect "$CHM_IMAGE" >/dev/null 2>&1 || miss "Docker image $CHM_IMAGE" "Build it with: bash docker/build_canopy_height_image.sh"
[ -f "$MODEL_DIR/saved_checkpoints/compressed_SSLhuge_aerial.pth" ] || miss "CHMv1 code and weights in $MODEL_DIR" "Download them with: bash docker/canopy_height_model/download_model_and_weights.sh"
[ -f "$ORTHOPHOTO_SOURCE_PATH" ] || miss "Orthophoto $ORTHOPHOTO_SOURCE_PATH" "Set ORTHOPHOTO_SOURCE_PATH to a local file (see docker/config.env)"
META=$(dirname "${ORTHOPHOTO_SOURCE_PATH:-.}")/metadata
for f in mosaic_coverage_by_project.gpkg metadata_omløpsprosjekt_mosaic_v2_2025.gpkg; do
  [ -f "$META/$f" ] || miss "Flight metadata $META/$f" "Delivered with the mosaic, in metadata/ next to it"
done
[ -f "$G1/vaatmark_pop_openS.gpkg" ] || miss "VAAT-GJEN-01 sample $G1/vaatmark_pop_openS.gpkg" "Made by VAAT-GJEN-01's pipeline (AR5 variant)"
[ -f "$HF/token" ] || [ -n "${HF_TOKEN:-}" ] || miss "Hugging Face login" "CHMv2 is gated: accept its terms on huggingface.co and log in (token in $HF/token)"
[ $missing -eq 0 ] || exit 1
mkdir -p "$WORK/$OUT" "$ENV_DIR" "$HF"
ORTHO_DIR=$(dirname "$ORTHOPHOTO_SOURCE_PATH")
exec > >(tee -a "$WORK/$OUT/run_all.log") 2>&1
echo "==== $(date '+%F %T') start  WORK=$WORK OUT=$OUT N_PER_STRATUM=$N_PER_STRATUM KEEP_TILES=$KEEP_TILES"
echo "code commit $(git -C "$REPO_DIR" rev-parse HEAD)$(git -C "$REPO_DIR" diff --quiet -- VAAT-GJEN-02/src/chm_comparison || echo ' +uncommitted changes')"
echo "free disk on $(df -h "$WORK" | awk 'NR==2 {print $6": "$4}')"

# Python 3.12 environment (src/chm_comparison/uv.lock), on the GPU
py() {
  docker run --rm --gpus all --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e USER=chm -e LOGNAME=chm -e TORCHINDUCTOR_CACHE_DIR=/tmp/ind -e HF_HOME=/hf -e HF_TOKEN \
    -e OUT -e N_PER_STRATUM -e ORTHOPHOTO_SOURCE_PATH -e TZ="$HOST_TZ" \
    -e UV_CACHE_DIR="$ENV_DIR/.uvcache" -e UV_PYTHON_INSTALL_DIR="$ENV_DIR/.python" -e UV_PROJECT_ENVIRONMENT="$ENV_DIR/.venv" \
    -v "$SRC:/code:ro" -v "$MODEL_DIR:/chmv1:ro" -v "$ORTHO_DIR:$ORTHO_DIR:ro" -v "$G1:/vaat_gjen_01:ro" \
    -v "$HF:/hf" -v "$ENV_DIR:$ENV_DIR" -v "$WORK:$WORK" -w "$WORK" "$CHM_IMAGE" bash -c '
      set -e
      uv python install 3.12 >/dev/null 2>&1
      uv sync --locked --project /code --no-install-project >/dev/null
      exec "$UV_PROJECT_ENVIRONMENT/bin/python" -u "$@"' _ "$@"
}
# CHMv1 as published: the image's own Python 3.9 / torch 2.0.1, int8, CPU, 12 processes x 2 threads
chmv1_cpu() {
  local start=$SECONDS n tiles s
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e OUT \
    -v "$SRC:/code:ro" -v "$MODEL_DIR:/chmv1:ro" -v "$WORK:$WORK" -w "$WORK" "$CHM_IMAGE" bash -c '
      for s in $(seq 0 11); do OMP_NUM_THREADS=2 /opt/chm-venv/bin/python /code/02_chmv1_cpu.py $s 12 2>&1 | grep shard & done; wait'
  n=$(ls "$WORK/$OUT"/pred_chmv1_cpu_*.npz 2>/dev/null | wc -l)
  [ "$n" -eq 12 ] || { echo "only $n of 12 CPU shards finished"; return 1; }
  tiles=$(( $(wc -l < "$WORK/$OUT/points.csv") - 1 )); s=$(( SECONDS - start ))
  echo "chmv1_cpu: $tiles tiles, $s s wall incl. ~30 s model loading, $(awk "BEGIN {printf \"%.2f\", $tiles / $s}") tiles/s (12 processes x 2 threads, CPU)" \
    | tee "$WORK/$OUT/timing_chmv1_cpu.txt"
}

failed=0
step() {  # name, file that marks it done, command...
  local name=$1 done=$2; shift 2
  if [ -e "$done" ]; then echo "---- $name: already done ($done)"; return 0; fi
  echo "---- $(date '+%T') $name"
  if "$@"; then echo "---- $(date '+%T') $name OK"; else echo "---- $(date '+%T') $name FAILED"; failed=1; fi
}
O=$WORK/$OUT
step "inputs (photo windows, LiDAR, dates)" "$O/points.csv"             py /code/01_make_inputs.py
[ -e "$O/points.csv" ] || { echo "inputs missing, stopping"; exit 1; }
step "CHMv1 CPU int8 (12 x 2)"         "$O/timing_chmv1_cpu.txt"     chmv1_cpu
step "CHMv1 GPU bf16, 0.5 m"           "$O/pred_chmv1_gpu.npz"       py /code/03_gpu_models.py chmv1_gpu --batch 64
step "CHMv1 GPU bf16, 0.6 m"           "$O/pred_chmv1_gpu_06.npz"    py /code/03_gpu_models.py chmv1_gpu_06 --batch 64
step "CHMv2 GPU bf16, 0.5 m"           "$O/pred_chmv2_05.npz"        py /code/03_gpu_models.py chmv2_05 --batch 8
step "CHMv2 GPU bf16, 0.6 m"           "$O/pred_chmv2_06.npz"        py /code/03_gpu_models.py chmv2_06 --batch 8
step "compare"                         "$O/__always__"               py /code/04_compare.py
step "calibration and validation cells" "$O/__always__"              py /code/05_calibration_and_validation.py
if [ "$failed" -eq 0 ] && [ "$KEEP_TILES" != "yes" ]; then
  rm -f "$O/tiles_576.npy" && echo "deleted $O/tiles_576.npy (KEEP_TILES=yes keeps it)"
elif [ "$failed" -ne 0 ]; then
  echo "a step FAILED: photo windows kept so the run can be restarted"
fi
echo "==== $(date '+%F %T') done. Results: $O (summary.txt, calibration_chmv2_median_fit.json, validation_cells_lidar_20m_median.csv)"
[ "$failed" -eq 0 ]
