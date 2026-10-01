#!/usr/bin/env bash
# Runs INSIDE the canopy-height image, started by
# docker/run_NO_GJEN_002_canopy_height_model.sh. Bash version of upstream's
# NO_GJEN_002/run_national_by_region.ps1: one region at a time, resumable,
# a failed region does not stop the others.
#
# Additions over the .ps1:
#   - a region whose run fails, or leaves polygons unvalued, is retried
#     after 10 s, 30 s and 90 s, so a network-share outage of a few minutes
#     does not leave holes (run_meta_chm_on_polygons.R resumes where it
#     stopped and retries the polygons that failed);
#   - polygons that still fail are listed in INCOMPLETE.txt in the output
#     folder and the run exits with an error, so an incomplete result can
#     never be mistaken for a finished one.
# The repository's own scripts are never modified.
set -u
RUN=/runs/current
LOG=$RUN/logs
SUMMARY=$RUN/SUMMARY.txt
OUT_REL=canopy_height_runs/$CHM_RUN_NAME
OUT=/work/NO_GJEN_002/Data/OpenS_data/$OUT_REL
mkdir -p "$LOG" "$OUT"

say() { echo "$(date '+%F %T')  $*" | tee -a "$SUMMARY"; }
stamp_lines() { while IFS= read -r line || [ -n "$line" ]; do echo "$(date '+%F %T')  $line"; done; }

# Same settings as run_national_by_region.ps1.
export CHM_POPULATION=national
export CHM_BATCH_SIZE=250
export CHM_TILE_RESOLUTION=0.5     # 25 cm was tested upstream: worse and 3x slower
export CHM_CLEAN_BATCH=1
[ "$CHM_MAX_POLYGONS" -gt 0 ] && export CHM_MAX_POLYGONS || unset CHM_MAX_POLYGONS

# Record what GDAL sees in the orthophoto (size, CRS, tiling, overviews).
GDAL_HTTP_USERPWD=${ORTHOPHOTO_SOURCE_USERPWD:-} gdalinfo -json "$ORTHOPHOTO_SOURCE_PATH" \
  > "$RUN/provenance/orthophoto_gdalinfo.json" 2>> "$RUN/provenance/orthophoto_gdalinfo.err" \
  || { say "Could not open the orthophoto with GDAL - see provenance/orthophoto_gdalinfo.err"; exit 1; }

# outstanding <csv>: polygons in the failures file that are not (yet) in the
# output. The failures file only ever grows, so this is the real count.
outstanding() {
  local out=$1 fail=${1%.csv}_failures.csv
  [ -f "$fail" ] || { echo 0; return; }
  Rscript -e 'a <- commandArgs(TRUE); f <- read.csv(a[2])$id
              o <- if (file.exists(a[1])) read.csv(a[1])$id else character(0)
              cat(length(setdiff(unique(f), o)))' "$out" "$fail"
}

say "NO_GJEN_002 canopy heights, run name '$CHM_RUN_NAME', regions: $CHM_REGIONS${CHM_MAX_POLYGONS:+, at most $CHM_MAX_POLYGONS polygons each}"
incomplete=()
for r in $CHM_REGIONS; do
  a=${r//[^A-Za-z0-9]/}
  export CHM_REGION=$r
  export CHM_OUTPUT_NAME=$OUT_REL/meta_chm_national_$a.csv
  export CHM_WORK_DIR=/runs/scratch/$CHM_RUN_NAME/$a
  csv=/work/NO_GJEN_002/Data/OpenS_data/$CHM_OUTPUT_NAME
  for delay in 0 10 30 90; do
    if [ "$delay" -gt 0 ]; then
      say "RETRY $r in $delay s ($left polygon(s) not valued yet, last exit code $rc)"; sleep "$delay"
    fi
    say "START $r"
    t0=$SECONDS
    ( cd /work/NO_GJEN_002/Fetch && stdbuf -oL -eL Rscript run_meta_chm_on_polygons.R ) 2>&1 | stamp_lines >> "$LOG/$a.log"
    rc=${PIPESTATUS[0]}
    left=$(outstanding "$csv")
    say "END   $r  rc=$rc  $(( (SECONDS - t0) / 60 )) min  not valued: $left  -> logs/$a.log"
    [ "$rc" -eq 0 ] && [ "$left" -eq 0 ] && break
  done
  if [ "$rc" -ne 0 ] || [ "$left" -ne 0 ]; then incomplete+=("$r (exit code $rc, $left polygon(s) not valued)"); fi
done

if [ ${#incomplete[@]} -gt 0 ]; then
  { echo "This canopy-height run is INCOMPLETE. Do not use it as a finished result."
    echo "Rerun the same command (same CHM_RUN_NAME) to resume; per-polygon errors"
    echo "are in the *_failures.csv files next to this one."
    printf '  %s\n' "${incomplete[@]}"; } > "$OUT/INCOMPLETE.txt"
  say "INCOMPLETE: ${incomplete[*]}. Listed in $OUT_REL/INCOMPLETE.txt"
  exit 1
fi
rm -f "$OUT/INCOMPLETE.txt"

# When was the photo of each polygon taken? (only with the flight metadata)
if [ -n "${ORTHOPHOTO_VISIBLE_PROJECTS:-}" ]; then
  say "START flight dates per polygon"
  ( cd /work/NO_GJEN_002/Fetch && CHM_RESULTS_DIR=$OUT stdbuf -oL -eL Rscript assign_orthophoto_flight_dates.R ) 2>&1 \
    | stamp_lines > "$LOG/flight_dates.log"
  rc=${PIPESTATUS[0]}
  say "END   flight dates  rc=$rc  -> logs/flight_dates.log"
  [ "$rc" -eq 0 ] || { say "Canopy heights are complete, but the flight dates FAILED (see its log)."; exit 1; }
fi
say "ALL DONE. Per-polygon canopy heights: NO_GJEN_002/Data/OpenS_data/$OUT_REL/"
say "Use meta_chm_mean (validated), not meta_chm_median. Provenance: $OUT_REL/provenance/${ORTHOPHOTO_VISIBLE_PROJECTS:+  Flight dates: $OUT_REL/orthophoto_flight_dates.csv}"
