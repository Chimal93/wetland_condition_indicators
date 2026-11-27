#!/usr/bin/env bash
# Compute per-polygon canopy heights for VAAT-GJEN-02 from an RGB orthophoto
# with Meta's HighResCanopyHeight model, inside the canopy-height image.
# Bash replacement for upstream's VAAT-GJEN-02/src/run_national_by_region.ps1.
#
# Only needed for NEW canopy heights (new imagery, new polygons, another
# model). The published VAAT-GJEN-02 result is recomputed from the committed
# values in VAAT-GJEN-02/data/OpenS_data/meta_chm_national_RAW_2026-09-17/.
#
# A national run takes several days on CPU; start it inside a screen or
# tmux session. Resumable: rerun with the same CHM_RUN_NAME to continue.
# Progress:  tail -f <run folder>/SUMMARY.txt
#
# Settings (docker/config.env explains each; set them in
# docker/config.local.env or in front of the command):
#   ORTHOPHOTO_SOURCE_PATH   the orthophoto (required)
#   ORTHOPHOTO_METADATA      files describing it, checksummed with every run
#   CHM_RUN_NAME             output folder name (required)
#   CHM_REGIONS, CHM_MAX_POLYGONS
#
# Quick test, 20 polygons in one region:
#   CHM_RUN_NAME=test20 CHM_REGIONS=Vestlandet CHM_MAX_POLYGONS=20 \
#     bash docker/run_VAAT-GJEN-02_canopy_height_model.sh
. "$(dirname "$0")/internal/common.sh"
. "$DOCKER_DIR/internal/fingerprint_inputs.sh"
. "$DOCKER_DIR/canopy_height_model/versions.env"

MODEL_DIR=$CHM_MODEL_DIR/HighResCanopyHeight-$MODEL_CODE_COMMIT
NIN_DIR=$REPO_DIR/VAAT-GJEN-02/data/OpenS_data/nin_data
OUT_DIR=$REPO_DIR/VAAT-GJEN-02/data/OpenS_data/canopy_height_runs/$CHM_RUN_NAME

# ---- check everything before starting ----------------------------------
missing=0
miss() { echo "MISSING  $1"; shift; for l in "$@"; do echo "         $l"; done; missing=1; }
docker image inspect "$CHM_IMAGE" >/dev/null 2>&1 \
  || miss "Docker image $CHM_IMAGE" "Build it with: bash docker/build_canopy_height_image.sh"
[ -f "$MODEL_DIR/saved_checkpoints/compressed_SSLhuge_aerial.pth" ] \
  || miss "Model code and weights in $MODEL_DIR" "Download them with: bash docker/canopy_height_model/download_model_and_weights.sh"
[ -n "$CHM_RUN_NAME" ] \
  || miss "CHM_RUN_NAME" "Name the run after its input, e.g. CHM_RUN_NAME=ortho2025 (see docker/config.env)"
if [ -z "$ORTHOPHOTO_SOURCE_PATH" ]; then
  miss "ORTHOPHOTO_SOURCE_PATH" "Set it in docker/config.local.env (see docker/config.env)"
elif [[ ! "$ORTHOPHOTO_SOURCE_PATH" =~ ^(/vsi|https?://) ]] && [ ! -f "$ORTHOPHOTO_SOURCE_PATH" ]; then
  miss "Orthophoto file $ORTHOPHOTO_SOURCE_PATH" "The path in ORTHOPHOTO_SOURCE_PATH does not exist"
fi
ls "$NIN_DIR"/*.gdb >/dev/null 2>&1 \
  || miss "NiN nature-type data in VAAT-GJEN-02/data/OpenS_data/nin_data/" "Download it with: bash docker/run_script.sh VAAT-GJEN-02/R/fetch_nin_data.R"
IFS=: read -r -a META <<< "$ORTHOPHOTO_METADATA"
# The flight metadata is checksummed too, unless already listed.
for m in "$ORTHOPHOTO_VISIBLE_PROJECTS" "$ORTHOPHOTO_PROJECT_GRID"; do
  [ -n "$m" ] && [[ ! " ${META[*]} " == *" $m "* ]] && META+=("$m")
done
if [ -n "$ORTHOPHOTO_VISIBLE_PROJECTS$ORTHOPHOTO_PROJECT_GRID" ] && { [ -z "$ORTHOPHOTO_VISIBLE_PROJECTS" ] || [ -z "$ORTHOPHOTO_PROJECT_GRID" ]; }; then
  miss "ORTHOPHOTO_VISIBLE_PROJECTS and ORTHOPHOTO_PROJECT_GRID" "Flight dates need both files (see docker/config.env); set both or neither"
fi
for m in "${META[@]}"; do [ -e "$m" ] || miss "Orthophoto metadata $m" "Fix ORTHOPHOTO_METADATA"; done
[ $missing -eq 0 ] || exit 1

STAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="$RUNS_DIR/vaat_gjen_02_canopy_height_${CHM_RUN_NAME}_$STAMP"
PROV=$RUN_DIR/provenance
mkdir -p "$PROV" "$OUT_DIR/provenance" "$RUNS_DIR/canopy_height_scratch"

# ---- record exactly what this run uses -----------------------------------
echo "Recording input fingerprints (reads about 70 MB of the orthophoto)..."
if [[ "$ORTHOPHOTO_SOURCE_PATH" =~ ^(/vsi|https?://) ]]; then
  fingerprint_remote "${ORTHOPHOTO_SOURCE_PATH#/vsicurl/}" "$ORTHOPHOTO_SOURCE_USERPWD" > "$PROV/orthophoto.txt"
else
  fingerprint_large_raster "$ORTHOPHOTO_SOURCE_PATH" > "$PROV/orthophoto.txt"
  for s in "$ORTHOPHOTO_SOURCE_PATH".aux.xml "${ORTHOPHOTO_SOURCE_PATH%.*}".vrt; do
    [ -f "$s" ] && { echo; fingerprint_file "$s"; } >> "$PROV/orthophoto.txt"
  done
fi
for m in "${META[@]}"; do
  if [ -d "$m" ]; then fingerprint_folder "$m"; else fingerprint_file "$m"; fi; echo
done > "$PROV/orthophoto_metadata.txt"
for d in "$NIN_DIR"/*.gdb; do fingerprint_folder "$d"; done > "$PROV/nin_polygons.txt"
{
  echo "run name:   $CHM_RUN_NAME"
  echo "started:    $STAMP"
  echo "repository: $(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo 'not a git checkout')$(git -C "$REPO_DIR" diff --quiet HEAD 2>/dev/null || echo ' (with uncommitted changes)')"
  echo "image:      $CHM_IMAGE"; docker image inspect --format '            id={{.Id}}  created={{.Created}}' "$CHM_IMAGE"
  echo "settings:   CHM_REGIONS=\"$CHM_REGIONS\" CHM_MAX_POLYGONS=$CHM_MAX_POLYGONS"
  echo; echo "--- docker/canopy_height_model/versions.env"; grep -v '^#' "$DOCKER_DIR/canopy_height_model/versions.env" | grep .
  echo; echo "--- model files (checked by download_model_and_weights.sh)"; cat "$DOCKER_DIR/canopy_height_model/model_files.sha256"
  echo; echo "--- VAAT-GJEN-02/src/chm_model/uv.lock sha256: $(sha256sum "$REPO_DIR/VAAT-GJEN-02/src/chm_model/uv.lock" | cut -d' ' -f1)"
} > "$PROV/run_info.txt"

# A resumed run must read the same imagery as the part already done.
FIRST=$(ls -d "$OUT_DIR"/provenance/*/ 2>/dev/null | head -1 || true)   # none on a first start
if [ -n "$FIRST" ] && ! cmp -s <(grep -v '^file:' "$FIRST/orthophoto.txt") <(grep -v '^file:' "$PROV/orthophoto.txt"); then
  echo "STOP: the orthophoto differs from the one this run ($CHM_RUN_NAME) started with:"
  diff "$FIRST/orthophoto.txt" "$PROV/orthophoto.txt" || true
  echo "Use a new CHM_RUN_NAME for new imagery, so the two are never mixed."
  rm -rf "$RUN_DIR"; exit 1
fi
cp -r "$PROV" "$OUT_DIR/provenance/$STAMP"

# ---- run ------------------------------------------------------------------
orthophoto_mount=(); ortho_in_container=$ORTHOPHOTO_SOURCE_PATH
if [[ ! "$ORTHOPHOTO_SOURCE_PATH" =~ ^(/vsi|https?://) ]]; then
  orthophoto_mount=(-v "$(dirname "$ORTHOPHOTO_SOURCE_PATH"):/orthophoto:ro")
  ortho_in_container=/orthophoto/$(basename "$ORTHOPHOTO_SOURCE_PATH")
fi
flight_mounts=()
if [ -n "$ORTHOPHOTO_VISIBLE_PROJECTS" ] && [ -n "$ORTHOPHOTO_PROJECT_GRID" ]; then
  flight_mounts=(-v "$(dirname "$ORTHOPHOTO_VISIBLE_PROJECTS"):/flight_metadata/visible:ro"
                 -v "$(dirname "$ORTHOPHOTO_PROJECT_GRID"):/flight_metadata/grid:ro"
                 -e ORTHOPHOTO_VISIBLE_PROJECTS="/flight_metadata/visible/$(basename "$ORTHOPHOTO_VISIBLE_PROJECTS")"
                 -e ORTHOPHOTO_PROJECT_GRID="/flight_metadata/grid/$(basename "$ORTHOPHOTO_PROJECT_GRID")")
fi
# The model's code expects to sit at src/chm_model/HighResCanopyHeight-main
# (gitignored). Create the mount point as this user, or Docker creates it
# owned by root.
mkdir -p "$REPO_DIR/VAAT-GJEN-02/src/chm_model/HighResCanopyHeight-main"

echo "Run folder: $RUN_DIR"
echo "Output:     $OUT_DIR"
echo "Progress:   tail -f $RUN_DIR/SUMMARY.txt"
IMAGE=$CHM_IMAGE   # run_in_container starts $IMAGE
rc=0  # common.sh sets -e; capture the exit code so the container is still removed
run_in_container "$RUN_DIR" --name "vaat_gjen_02_chm_$STAMP" \
  -v "$MODEL_DIR:/work/VAAT-GJEN-02/src/chm_model/HighResCanopyHeight-main:ro" \
  -v "$RUNS_DIR/canopy_height_scratch:/runs/scratch" \
  "${orthophoto_mount[@]}" "${flight_mounts[@]}" \
  -e ORTHOPHOTO_SOURCE_PATH="$ortho_in_container" -e ORTHOPHOTO_SOURCE_USERPWD \
  -e CHM_RUN_NAME="$CHM_RUN_NAME" -e CHM_REGIONS="$CHM_REGIONS" -e CHM_MAX_POLYGONS="$CHM_MAX_POLYGONS" \
  -- bash /work/docker/internal/run_VAAT-GJEN-02_canopy_height_model_in_container.sh || rc=$?
docker rm "vaat_gjen_02_chm_$STAMP" >/dev/null 2>&1 || true
for f in orthophoto_gdalinfo.json data_sources.csv; do   # written inside the container
  cp "$PROV/$f" "$OUT_DIR/provenance/$STAMP/" 2>/dev/null || true
done
echo "Finished (exit $rc). Run folder: $RUN_DIR"
exit $rc
