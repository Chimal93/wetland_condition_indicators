#!/usr/bin/env bash
# Prepare the AR5 forest and mire input for NO_GJEN_001 from the municipal
# FKB-AR5 GeoPackages. This is how the AR5 layers behind the published
# results were built.
#
# Kartverket (Geonorge) distributes FKB-AR5 as one GeoPackage per
# municipality, named Basisdata_<nr>_<name>_<epsg>_FKB-AR5_SOSI.gpkg
# (357 files, about 47 GB). Access to FKB-AR5 is restricted, so this
# script cannot download anything: you must already have the files.
# If you do not, run NO_GJEN_001 with GJEN_SOURCE=AR50 instead.
#
# What it does, for every municipality file:
#   1. copies the file to local disk (with retries, in case the files sit
#      on a network share that drops out now and then),
#   2. subsets the forest polygons (arealressursArealtype = 30) and the
#      mire polygons (arealressursArealtype = 60),
#   3. reprojects them to EPSG:25833, makes the geometries valid and
#      appends them to two national files.
#
# What "skog" and "myr" mean here - important for interpreting results:
#   The layer "polygons" in each file holds AR5 land-resource polygons.
#   The column arealressursArealtype ("arealtype", land type) is AR5's
#   main class. Two of its codes are used:
#     30 = Skog (forest): at least 6 trees per decare (1000 m2) that are
#          or can become 5 m tall, evenly spread over the area.
#     60 = Myr (mire): mire vegetation on a peat layer at least 30 cm thick.
#   Note that in AR5 the tree criterion wins: a peatland that carries
#   enough trees is coded 30 (Skog), not 60 (Myr). "Myr" is therefore
#   OPEN mire only, and forested mire ends up in the forest layer. AR5
#   records the peat under such forest in a separate column,
#   arealressursGrunnforhold (ground conditions) = 45 "organiske jordlag"
#   (organic soil), which this script does not use. This matches the
#   AR50 route (R/build_ar50_*.R), which uses the same two codes.
#   Definitions: NIBIO, "AR5 klassifikasjonssystem" (Ahlstrom et al.).
# If any municipality still fails after retries, the two outputs are renamed
# *.INCOMPLETE and nothing is installed, so a partial layer is never used.
#
# Result (installed into NO_GJEN_001/data/OpenS_data/):
#   ar5_skog_national.gpkg   forest
#   ar5_myr_national.gpkg    mire
#
# Usage, from the repository root (takes about 15 minutes; run it inside
# screen or tmux):
#   bash docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh /path/to/FKB-AR5-folder
#
# The work is done inside the Docker image (it provides ogr2ogr), so build
# the image first: bash docker/build_image.sh

# ---- host side: start the container and run this same script inside it ----
if [ "${INSIDE_CONTAINER:-}" != "yes" ]; then
  . "$(dirname "$0")/../internal/common.sh"
  [ $# -eq 1 ] || { echo "usage: bash docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh <folder with the FKB-AR5 GeoPackages>"; exit 1; }
  [ -d "$1" ] || { echo "Folder does not exist: $1"; exit 1; }
  FKB_DIR=$(cd "$1" && pwd)
  WORK_DIR="$RUNS_DIR/prepare_ar5_input_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$WORK_DIR"
  echo "Reading FKB-AR5 from: $FKB_DIR"
  echo "Work folder and log:  $WORK_DIR"
  run_in_container "$WORK_DIR" --rm -v "$FKB_DIR:/fkb:ro" -e INSIDE_CONTAINER=yes \
    -e FKB_SOURCE_DIR="$FKB_DIR" -e RUN_NAME="$(basename "$WORK_DIR")" \
    -- bash /work/docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh 2>&1 | tee "$WORK_DIR/log.txt"
  exit "${PIPESTATUS[0]}"
fi

# ---- container side ---------------------------------------------------------
# Mounts: /fkb (the FKB-AR5 folder, read-only), /runs/current (work folder),
# /work (the repository; the final files are copied into NO_GJEN_001).
set -u
SRC=/fkb
OUT=/runs/current/ar5
DEST=/work/NO_GJEN_001/data/OpenS_data
STAGE=$OUT/_staging
mkdir -p "$OUT" "$STAGE" "$DEST"
SKOG=$OUT/ar5_skog_national.gpkg
MYR=$OUT/ar5_myr_national.gpkg
rm -f "$SKOG" "$MYR"
FAILED=()
DELAYS=(10 30 90)
# Which municipal files went in: name, size, date, checksum (of the copy read).
SOURCE_LIST=$OUT/ar5_national_source_files.csv
echo '"file","size_bytes","modified","sha256"' > "$SOURCE_LIST"

log() { echo "$(date '+%F %T')  $*"; }

subset() {   # subset <local_src> <arealtype> <out_gpkg> <layer_name>
  ogr2ogr -f GPKG -append -nln "$4" -t_srs EPSG:25833 -nlt PROMOTE_TO_MULTI -makevalid \
    -where "arealressursArealtype = $2" "$3" "$1" polygons
}

mapfile -t FILES < <(ls "$SRC"/Basisdata_*_FKB-AR5_SOSI.gpkg 2>/dev/null | sort)
N=${#FILES[@]}
log "Found $N municipality files in $SRC"
[ "$N" -gt 0 ] || { log "No files named Basisdata_*_FKB-AR5_SOSI.gpkg found - is this the right folder?"; exit 1; }
if [ "$N" -ne 357 ]; then log "WARNING: expected 357 files (one per municipality)"; fi

i=0
for f in "${FILES[@]}"; do
  i=$((i+1)); name=$(basename "$f"); local_f="$STAGE/$name"; ok=0
  for attempt in 0 1 2 3; do
    if [ "$attempt" -gt 0 ]; then
      d=${DELAYS[$((attempt-1))]}; log "  retry $attempt for $name after ${d}s"; sleep "$d"
    fi
    rm -f "$local_f"
    if cp "$f" "$local_f" \
       && subset "$local_f" 30 "$SKOG" ar5_skog \
       && subset "$local_f" 60 "$MYR" ar5_myr; then
      sha=$(sha256sum "$local_f" | cut -d' ' -f1)
      ok=1; break
    fi
  done
  rm -f "$local_f"
  if [ "$ok" -eq 1 ]; then
    echo "\"$name\",$(stat -c %s "$f"),\"$(date -r "$f" '+%Y-%m-%d %H:%M:%S')\",\"$sha\"" >> "$SOURCE_LIST"
    log "[$i/$N] ok   $name"
  else
    log "[$i/$N] FAIL $name"; FAILED+=("$name")
  fi
done

log "Skog features: $(ogrinfo -so "$SKOG" ar5_skog 2>/dev/null | grep 'Feature Count' | tr -dc '0-9')"
log "Myr  features: $(ogrinfo -so "$MYR"  ar5_myr  2>/dev/null | grep 'Feature Count' | tr -dc '0-9')"

if [ "${#FAILED[@]}" -gt 0 ]; then
  log "FAILED municipalities (${#FAILED[@]}): ${FAILED[*]}"
  mv "$SKOG" "$SKOG.INCOMPLETE"; mv "$MYR" "$MYR.INCOMPLETE"
  log "Outputs renamed *.INCOMPLETE and NOT installed into the repository."
  exit 1
fi

cp "$SKOG" "$DEST/ar5_skog_national.gpkg" && cp "$MYR" "$DEST/ar5_myr_national.gpkg" \
  && log "Installed ar5_skog_national.gpkg and ar5_myr_national.gpkg into NO_GJEN_001/data/OpenS_data/" \
  || { log "Copy into the repository failed"; exit 1; }

# Record where the two layers came from (see docker/data_sources.tsv).
cp "$SOURCE_LIST" "$DEST/ar5_national_source_files.csv"
. /work/docker/internal/record_data_sources.sh
log_fetch NO_GJEN_001 docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh "$RUN_NAME (from $FKB_SOURCE_DIR)"
log "Recorded in NO_GJEN_001/data/data_sources_log.csv; the municipal files used are listed in"
log "NO_GJEN_001/data/OpenS_data/ar5_national_source_files.csv"
