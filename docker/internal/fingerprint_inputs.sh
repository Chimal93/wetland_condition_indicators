# Shared by docker/run_VAAT-GJEN-02_canopy_height_model.sh. Not meant to be
# run directly. Functions that write a short, comparable fingerprint of an
# input, so a result can be traced back to exactly the data it came from.

# fingerprint_file <file>: size, modification time and full SHA-256.
# For files up to a few GB (metadata, footprints, source lists).
fingerprint_file() {
  local f=$1
  echo "file:     $f"
  echo "size:     $(stat -c %s "$f") bytes"
  echo "modified: $(stat -c %y "$f")"
  echo "sha256:   $(sha256sum "$f" | cut -d' ' -f1)"
}

# fingerprint_folder <folder>: the same for every file in a folder (e.g. a
# FileGDB), combined into one SHA-256 over the sorted per-file checksums.
fingerprint_folder() {
  local d=$1
  echo "folder:   $d"
  echo "files:    $(find "$d" -type f | wc -l), $(du -sb "$d" | cut -f1) bytes"
  echo "newest:   $(find "$d" -type f -printf '%TY-%Tm-%Td %TH:%TM\n' | sort | tail -1)"
  echo "sha256:   $( (cd "$d" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1)  (of the sorted per-file checksums)"
}

# fingerprint_large_raster <file>: for files far too large to checksum in
# full (a national orthophoto is several TB, and reading it over a network
# share would take days). Records size and modification time, and SHA-256
# of the first 4 MiB (TIFF header and tile index, so any change to the
# layout shows) plus 64 evenly spaced 1 MiB samples of the image data.
# The same file always gives the same fingerprint; a replaced or re-encoded
# file almost certainly does not. Reads about 70 MB.
fingerprint_large_raster() {
  local f=$1 size n=64 chunk=1048576 i off
  size=$(stat -c %s "$f")
  echo "file:     $f"
  echo "size:     $size bytes"
  echo "modified: $(stat -c %y "$f")"
  echo "sha256 of first 4 MiB: $(head -c 4194304 "$f" | sha256sum | cut -d' ' -f1)"
  echo "sha256 of $n x 1 MiB samples: $(
    for ((i = 0; i < n; i++)); do
      off=$(( (size - chunk) / (n - 1) * i ))
      dd if="$f" iflag=skip_bytes,count_bytes skip="$off" count=$chunk status=none
    done | sha256sum | cut -d' ' -f1)"
}

# fingerprint_remote <url> [user:password]: what the server says about a
# remote file (size, ETag, last modified). Credentials are never written.
fingerprint_remote() {
  local url=$1 userpwd=${2:-}
  echo "url:      $(echo "$url" | sed -E 's#//[^/@]+@#//<credentials>@#')"
  curl -sfI ${userpwd:+-u "$userpwd"} "$url" | tr -d '\r' \
    | grep -iE '^(content-length|etag|last-modified|x-amz-version-id):' | sed 's/^/header:   /' \
    || echo "header:   (server did not answer a HEAD request)"
}
