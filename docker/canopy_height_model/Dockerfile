# Canopy-height model image for NO_GJEN_002: the R image plus a separate,
# pinned Python environment for Meta's HighResCanopyHeight model. R and
# Python must live in one container because Fetch/run_meta_chm_on_polygons.R
# calls Python directly for every batch of tiles.
#
# Pinned here:
#   - the R image (R_IMAGE, built by docker/build_image.sh)
#   - uv, by digest (UV_IMAGE in versions.env); uv installs a fixed
#     standalone build of PYTHON_VERSION, so no system Python is used
#   - every Python package, by version and hash (requirements.lock)
# Not in the image: the model code and weights (~800 MB). They are
# downloaded and checksummed by download_model_and_weights.sh and mounted
# at run time.
#
# Build with:  bash docker/build_canopy_height_image.sh
ARG R_IMAGE
ARG UV_IMAGE
FROM ${UV_IMAGE} AS uv
FROM ${R_IMAGE}
ARG PYTHON_VERSION

COPY --from=uv /usr/local/bin/uv /usr/local/bin/uv
ENV UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_NO_CACHE=1 \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_INDEX_STRATEGY=unsafe-best-match

# Both indexes are searched, as when the lock was resolved; the hashes in
# the lock make sure only the exact recorded files are installed.
COPY requirements.lock /tmp/chm/requirements.lock
RUN uv python install "$PYTHON_VERSION" \
    && uv venv --python "$PYTHON_VERSION" /opt/chm-venv \
    && uv pip sync --python /opt/chm-venv/bin/python --require-hashes /tmp/chm/requirements.lock \
    && rm -rf /tmp/chm \
    && /opt/chm-venv/bin/python -c "import torch, torchvision, pytorch_lightning, torchmetrics, numpy; print('torch', torch.__version__, 'numpy', numpy.__version__)"

# Where run_meta_chm_on_polygons.R finds Python. CHM_PYTHONPATH is empty
# on purpose: the venv interpreter finds its own packages.
ENV CHM_PYTHON=/opt/chm-venv/bin/python \
    CHM_PYTHONPATH=""
