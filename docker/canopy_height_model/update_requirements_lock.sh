#!/usr/bin/env bash
# Re-resolve requirements.in into requirements.lock (exact versions and
# hashes of every package, for Linux x86_64 and the Python version below).
# Run this only after editing requirements.in on purpose; the lock is what
# the image installs. Needs Docker and internet, nothing else.
#
# --exclude-newer freezes the resolution to what was published on that
# date, so rerunning this script later gives the same lock unless the date
# is changed too.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/versions.env"
docker run --rm --user "$(id -u):$(id -g)" -e UV_NO_CACHE=1 -e HOME=/tmp -v "$HERE:/w" -w /w "$UV_IMAGE" \
  uv pip compile requirements.in -o requirements.lock \
    --python-version "$PYTHON_VERSION" --python-platform x86_64-manylinux_2_28 \
    --index-url https://pypi.org/simple --extra-index-url https://download.pytorch.org/whl/cpu \
    --index-strategy unsafe-best-match --exclude-newer "$EXCLUDE_NEWER" \
    --generate-hashes --emit-index-url --no-header
echo "Wrote $HERE/requirements.lock"
