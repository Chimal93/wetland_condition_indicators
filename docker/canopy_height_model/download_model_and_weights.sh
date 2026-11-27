#!/usr/bin/env bash
# Download Meta's HighResCanopyHeight model code (pinned commit) and the two
# weight files NO_GJEN_002 uses, and check them against model_files.sha256.
# Run once per machine; about 800 MB. The files are Apache-2.0 but not ours
# to redistribute, so they are kept outside the repository in
# CHM_MODEL_DIR (see docker/config.env) and mounted into the container by
# docker/run_NO_GJEN_002_canopy_height_model.sh.
#
# Usage, from the repository root:
#   bash docker/canopy_height_model/download_model_and_weights.sh
#
# If model_files.sha256 has no entry for a file yet, the checksum of the
# downloaded file is added to it (commit that change). After that, any file
# that does not match its recorded checksum is rejected.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../internal/common.sh"
. "$HERE/versions.env"
SUMS=$HERE/model_files.sha256
touch "$SUMS"

DEST=$CHM_MODEL_DIR/HighResCanopyHeight-$MODEL_CODE_COMMIT
CODE_URL=https://github.com/facebookresearch/HighResCanopyHeight/archive/$MODEL_CODE_COMMIT.tar.gz
WEIGHTS_URL=https://dataforgood-fb-data.s3.amazonaws.com/forests/v1/models/saved_checkpoints
WEIGHTS=(compressed_SSLhuge_aerial.pth aerial_normalization_quantiles_predictor.ckpt)
mkdir -p "$CHM_MODEL_DIR/downloads"

# fetch <url> <file in downloads/>: download unless present, then verify.
fetch() {
  local url=$1 f=$CHM_MODEL_DIR/downloads/$2
  [ -f "$f" ] || { echo "Downloading $2 ..."; curl -fL --retry 5 --retry-delay 30 -o "$f.part" "$url"; mv "$f.part" "$f"; }
  local sum; sum=$(sha256sum "$f" | cut -d' ' -f1)
  local want; want=$(awk -v n="$2" '$2 == n {print $1}' "$SUMS")
  if [ -z "$want" ]; then
    echo "$sum  $2" >> "$SUMS"
    echo "RECORDED $2  $sum  (new entry in $(basename "$SUMS") - commit it)"
  elif [ "$sum" = "$want" ]; then
    echo "OK       $2  $sum"
  else
    echo "MISMATCH $2: got $sum, expected $want. Not using it."; exit 1
  fi
}

fetch "$CODE_URL" "HighResCanopyHeight-$MODEL_CODE_COMMIT.tar.gz"
for w in "${WEIGHTS[@]}"; do fetch "$WEIGHTS_URL/$w" "$w"; done

# Unpack the code and place the weights where Meta's code expects them.
if [ ! -d "$DEST" ]; then
  tar -xzf "$CHM_MODEL_DIR/downloads/HighResCanopyHeight-$MODEL_CODE_COMMIT.tar.gz" -C "$CHM_MODEL_DIR"
fi
mkdir -p "$DEST/saved_checkpoints"
# Hard links, not symlinks: only $DEST is mounted into the container, so a
# symlink into downloads/ would point nowhere there.
for w in "${WEIGHTS[@]}"; do ln -f "$CHM_MODEL_DIR/downloads/$w" "$DEST/saved_checkpoints/$w"; done
echo "Model ready: $DEST"
