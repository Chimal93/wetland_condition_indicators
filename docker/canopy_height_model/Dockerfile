# Canopy-height model image for NO_GJEN_002: the R image plus a separate,
# pinned Python environment for Meta's HighResCanopyHeight model. R and
# Python must live in one container because R/run_meta_chm_on_polygons.R
# calls Python directly for every batch of tiles.
#
# Pinned here:
#   - the R image (R_IMAGE, built by docker/build_image.sh)
#   - uv, by digest (UV_IMAGE in versions.env); uv installs a fixed
#     standalone build of PYTHON_VERSION, so no system Python is used
#   - every Python package, by version and hash: upstream's uv.lock in
#     NO_GJEN_002/src/chm_model/ (passed in as the build context "chm")
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
    UV_PROJECT_ENVIRONMENT=/opt/chm-venv

# --locked installs exactly what uv.lock records (versions and hashes), and
# stops if pyproject.toml has been changed without updating the lock.
COPY --from=chm pyproject.toml uv.lock /tmp/chm/
RUN uv python install "$PYTHON_VERSION" \
    && uv sync --locked --project /tmp/chm --python "$PYTHON_VERSION" \
    && rm -rf /tmp/chm \
    && /opt/chm-venv/bin/python -c "import sys, torch, torchvision, pytorch_lightning, torchmetrics, numpy; print('python', sys.version.split()[0], 'torch', torch.__version__, 'numpy', numpy.__version__)"

# Where run_meta_chm_on_polygons.R finds Python. CHM_PYTHONPATH is empty
# on purpose: the venv interpreter finds its own packages.
ENV CHM_PYTHON=/opt/chm-venv/bin/python \
    CHM_PYTHONPATH=""
