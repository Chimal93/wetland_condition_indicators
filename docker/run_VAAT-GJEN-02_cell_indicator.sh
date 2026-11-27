#!/usr/bin/env bash
# VAAT-GJEN-02 indicator on the 20 m grid over all AR5 mire, from the national
# CHM map made by run_VAAT-GJEN-02_national_chm.sh. Code and method:
# VAAT-GJEN-02/src/chm_national/cell_indicator.py. CPU only.
#
# Usage (inside screen):
#   bash docker/run_VAAT-GJEN-02_cell_indicator.sh            # chmv2 (default)
# Extra arguments go to cell_indicator.py, e.g. --workers 12 or a test box:
#   bash docker/run_VAAT-GJEN-02_cell_indicator.sh --bbox 346400 7270400 372000 7296000
#
# Settings (docker/config.local.env or in front of the command):
#   NATIONAL_CHM_OUT_DIR   the CHM map's output folder; results go to
#                          <it>/cell_indicator_chmv2 (or set CELL_INDICATOR_OUT)
#   NATIONAL_CHM_AR5       AR5 mire GeoPackage (default: VAAT-GJEN-01's ar5_myr_national.gpkg)
#   ORTHOPHOTO_FLIGHT_PROJECTS  the mosaic's visible flight projects (default:
#                          metadata/mosaic_coverage_by_project.gpkg next to the mosaic)
# Also needs <NATIONAL_CHM_OUT_DIR>/validation_cells_lidar_20m_median.csv: the
# LiDAR 20 m cell medians at the VAAT-GJEN-01 sample cells, used for the
# uncertainty. Kept outside the repository because the cells come from AR5.
. "$(dirname "$0")/internal/common.sh"
. "$DOCKER_DIR/canopy_height_model/versions.env"

MODEL=chmv2
CHM=${NATIONAL_CHM_OUT_DIR:-}/$MODEL
OUT=${CELL_INDICATOR_OUT:-${NATIONAL_CHM_OUT_DIR:-}/cell_indicator_$MODEL}
G1=$REPO_DIR/VAAT-GJEN-01/data/OpenS_data
G2=$REPO_DIR/VAAT-GJEN-02/data/OpenS_data
AR5=${NATIONAL_CHM_AR5:-$G1/ar5_myr_national.gpkg}
VALIDATION=${NATIONAL_CHM_OUT_DIR:-}/validation_cells_lidar_20m_median.csv
FLIGHTS=${ORTHOPHOTO_FLIGHT_PROJECTS:-$(dirname "${ORTHOPHOTO_SOURCE_PATH:-.}")/metadata/mosaic_coverage_by_project.gpkg}
ENV_DIR=$RUNS_DIR/national_chm_env
STAGING=$RUNS_DIR/national_chm_staging
SRC=$REPO_DIR/VAAT-GJEN-02/src/chm_national

missing=0
miss() { echo "MISSING  $1"; shift; for l in "$@"; do echo "         $l"; done; missing=1; }
[ -n "${NATIONAL_CHM_OUT_DIR:-}" ] || miss "NATIONAL_CHM_OUT_DIR" "Set it in docker/config.local.env"
[ -f "$CHM/chm_$MODEL.vrt" ] || miss "CHM map $CHM" "Run: bash docker/run_VAAT-GJEN-02_national_chm.sh $MODEL"
docker image inspect "$CHM_IMAGE" >/dev/null 2>&1 || miss "Docker image $CHM_IMAGE" "Build it with: bash docker/build_canopy_height_image.sh"
[ -f "$AR5" ] || miss "AR5 mire layer $AR5" "Build it with docker/prepare_ar5_input/ or set NATIONAL_CHM_AR5"
[ -f "$FLIGHTS" ] || miss "Flight projects of the mosaic $FLIGHTS" "Delivered with the mosaic (metadata/); or set ORTHOPHOTO_FLIGHT_PROJECTS"
[ -f "$VALIDATION" ] || miss "Validation cells $VALIDATION" "LiDAR 20 m cell medians at the VAAT-GJEN-01 sample cells (not in the repository: derived from AR5)"
for f in "$G1/osm_buildings_national.gpkg" "$G1/regions.shp" "$G1/bioclim/soner2017.shp" "$G1/ssb50km.shp" \
         "$G2/refvaatmark_openS_30m.csv" "$G2/vegHeights_skog_climZoneRegion_openS_20m.csv"; do
  [ -f "$f" ] || miss "$f" "Made by the VAAT-GJEN-01 pipeline (see VAAT-GJEN-01/README.md)"
done
[ $missing -eq 0 ] || exit 1
mkdir -p "$(dirname "$OUT")" "$ENV_DIR" "$STAGING"

FL_DIR=$(dirname "$FLIGHTS")
AR5_DIR=$(dirname "$AR5"); AR5_MOUNT=(); [ "$AR5_DIR" = "$G1" ] || AR5_MOUNT=(-v "$AR5_DIR:$AR5_DIR:ro")
COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)$(git -C "$REPO_DIR" diff --quiet -- VAAT-GJEN-02/src/chm_national 2>/dev/null || echo "+uncommitted changes")
LOG="$(dirname "$OUT")/cell_indicator_${MODEL}_$(date +%Y%m%d_%H%M%S).log"
echo "Log: $LOG"
docker run --rm --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e UV_CACHE_DIR="$ENV_DIR/.uvcache" -e UV_PYTHON_INSTALL_DIR="$ENV_DIR/.python" \
  -e UV_PROJECT_ENVIRONMENT="$ENV_DIR/.venv" -e CODE_COMMIT="$COMMIT" -e TZ="$HOST_TZ" \
  -v "$SRC:/code:ro" -v "$G1:$G1:ro" -v "$G2:$G2:ro" "${AR5_MOUNT[@]}" -v "$FL_DIR:$FL_DIR:ro" \
  -v "$NATIONAL_CHM_OUT_DIR:$NATIONAL_CHM_OUT_DIR" -v "$(dirname "$OUT"):$(dirname "$OUT")" -v "$ENV_DIR:$ENV_DIR" -v "$STAGING:$STAGING" \
  -w /tmp "$CHM_IMAGE" bash -c '
    set -e
    uv python install 3.12 >/dev/null 2>&1
    uv sync --locked --project /code --no-install-project >/dev/null
    exec "$UV_PROJECT_ENVIRONMENT/bin/python" -u /code/cell_indicator.py "$@"' _ \
    --chm "$CHM" --calibration /code/calibration_${MODEL}_median.json --ar5 "$AR5" \
    --buildings "$G1/osm_buildings_national.gpkg" --regions "$G1/regions.shp" \
    --bioclim "$G1/bioclim/soner2017.shp" --ssb50km "$G1/ssb50km.shp" \
    --ref "$G2/refvaatmark_openS_30m.csv" --skog "$G2/vegHeights_skog_climZoneRegion_openS_20m.csv" \
    --validation "$VALIDATION" --flight-projects "$FLIGHTS" --out "$OUT" --staging "$STAGING" "$@" \
  2>&1 | grep --line-buffered -v -E "Warning|warnings.warn|^\s*$" | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
