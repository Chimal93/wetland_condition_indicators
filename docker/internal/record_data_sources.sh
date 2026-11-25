# Shared by the runners in docker/. Not meant to be run directly.
# Keeps track of where every input came from and when it was fetched, using
# the list in docker/data_sources.tsv. Paths below are relative to the
# repository root given as REPO (default /work, the path in the container).
REPO=${REPO:-/work}
SOURCES_TSV=$REPO/docker/data_sources.tsv

# Rows of data_sources.tsv as "indicator<TAB>path<TAB>how<TAB>source", no comments/header.
_sources() { grep -v '^#' "$SOURCES_TSV" | tail -n +2 | grep .; }

_csv() { local f; for f in "$@"; do printf '"%s",' "${f//\"/\"\"}"; done | sed 's/,$//'; echo; }

# _fingerprint <file or folder>: prints "size_bytes<TAB>modified<TAB>sha256".
# A folder gets one SHA-256 over the sorted checksums of all its files.
_fingerprint() {
  local p=$1
  if [ -d "$p" ]; then
    printf '%s\t%s\t%s\n' "$(du -sb "$p" | cut -f1)" \
      "$(find "$p" -type f -printf '%TY-%Tm-%Td %TH:%TM:%.2TS\n' | sort | tail -1)" \
      "$( (cd "$p" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) | sha256sum | cut -d' ' -f1)"
  else
    printf '%s\t%s\t%s\n' "$(stat -c %s "$p")" "$(date -r "$p" '+%Y-%m-%d %H:%M:%S')" \
      "$(sha256sum "$p" | cut -d' ' -f1)"
  fi
}

# log_fetch <indicator> <how> [run name]: call right after <how> (a download
# or build script) finished successfully. Appends one row per output of
# that script to <indicator>/data/data_sources_log.csv, which stays next to
# the data and so keeps the fetch date even when later runs skip the download.
log_fetch() {
  local ind=$1 how=$2 run=${3:-} i path h src size mod sum log
  log=$REPO/$ind/data/data_sources_log.csv
  mkdir -p "$(dirname "$log")"
  [ -f "$log" ] || _csv fetched_at path how source size_bytes sha256 repository_commit run > "$log"
  while IFS=$'\t' read -r i path h src; do
    [ "$i" = "$ind" ] && [ "$h" = "$how" ] && [ -e "$REPO/$ind/$path" ] || continue
    IFS=$'\t' read -r size mod sum < <(_fingerprint "$REPO/$ind/$path")
    _csv "$(date '+%Y-%m-%d %H:%M:%S %z')" "$path" "$how" "$src" "$size" "$sum" \
      "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)" "$run" >> "$log"
  done < <(_sources)
}

# write_data_sources <output csv> [indicator ...]: the state of every input
# of the given indicators as this run used it: present or not, size, last
# modified, checksum, and the last logged fetch. Live services are listed
# with the time of this run, since they are read during it.
write_data_sources() {
  local out=$1; shift
  local inds=" $* " i path how src size mod sum last log
  _csv indicator path how source present size_bytes modified sha256 last_logged_fetch > "$out"
  while IFS=$'\t' read -r i path how src; do
    [[ "$inds" == *" $i "* ]] || continue
    if [ "$how" = live ]; then
      _csv "$i" "$path" "$how" "$src" "read live during this run" "" "$(date '+%Y-%m-%d %H:%M:%S')" "" "" >> "$out"
      continue
    fi
    if [ ! -e "$REPO/$i/$path" ]; then
      _csv "$i" "$path" "$how" "$src" no "" "" "" "" >> "$out"; continue
    fi
    IFS=$'\t' read -r size mod sum < <(_fingerprint "$REPO/$i/$path")
    log=$REPO/$i/data/data_sources_log.csv
    last=$( [ -f "$log" ] && grep -F ",\"$path\"," "$log" | tail -1 | cut -d, -f1 | tr -d '"')
    _csv "$i" "$path" "$how" "$src" yes "$size" "$mod" "$sum" \
      "${last:-not logged (fetched before logging existed; see modified)}" >> "$out"
  done < <(_sources)
}
