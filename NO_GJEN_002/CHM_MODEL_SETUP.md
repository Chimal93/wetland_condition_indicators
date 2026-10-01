# Meta canopy-height model - environment setup and status

This documents the **external Python/PyTorch dependency** needed to regenerate
NO_GJEN_002's canopy-height predictions (Meta's `HighResCanopyHeight` model, run
on orthophoto tiles) - the same kind of "read this before running anything"
treatment NO_CONN_001's README gives QGIS.

**You only need this to regenerate predictions from imagery.** To reproduce the
published indicator, use the committed per-polygon predictions in
`Data/OpenS_data/meta_chm_national_RAW_2026-09-17/` and skip this document
entirely - see the README.

## Status: built, smoke-tested, and used for the national run (2026-09-04 to 2026-09-17)

Confirmed working end-to-end on this machine, on CPU, using a synthetic (random
noise) 256x256 input tile - proves the *mechanism* works, says nothing about
*accuracy*, since no real Norwegian imagery has been fed through it yet (none
exists locally - that's the actual blocker). Real command used to verify:
```
.venv_chm\Scripts\python.exe chm_model\smoke_test.py
```
Output confirmed: model loads, both checkpoints load, quantization succeeds,
forward pass completes, output shape is exactly `(1, 1, 256, 256)` - one
predicted height value per input pixel, as expected.

## Why this is a real, separate dependency (not just "install some packages")

Meta's model is Python/PyTorch-only - there is no R package or interface, and
no way to avoid this. The integration pattern is the same one already used
elsewhere in this project (R calling out to an external tool via `system2()` -
see `NO_CONN_001`'s QGIS `ogr2ogr.exe` call, or its PowerShell/.NET zip
extraction) - just a heavier, more specialized external environment than
either of those two.

## Exact dependencies (all version-pinned - this is an old, unmaintained-since-2023
research repo; newer transitive dependencies silently break it - see "Two real
gotchas" below)

| Dependency | Version | Why pinned exactly |
|---|---|---|
| Python | 3.9.25 | Repo's own documented requirement (`conda create -n hrch python=3.9`) |
| torch | 2.0.1 (**+cpu** build) | Repo's pin. CPU build specifically - see "GPU note" below |
| torchvision | 0.15.2 (**+cpu** build) | Repo's pin, matched to the torch build |
| pytorch_lightning | 1.7.0 | Repo's pin |
| torchmetrics | 0.11.4 | Repo's pin |
| numpy | **<2** (installed: 1.26.4) | NOT in the repo's own instructions - see gotcha #1 |
| setuptools | **<81** (installed: 80.10.2) | NOT in the repo's own instructions - see gotcha #2 |
| pandas, matplotlib | latest | Repo's instructions don't pin these; no issues found |

**GPU note**: no GPU/CUDA needed. The checkpoint this project uses
(`compressed_SSLhuge_aerial.pth`) is a quantized model explicitly built for
CPU inference - confirmed directly in the repo's own `inference.py`:
`if 'compressed' in args.checkpoint: device='cpu'`. The conda-based GPU
install path in the repo's README (`pytorch-cuda=11.7`) is for the
*uncompressed* checkpoints only and was deliberately skipped here.

## Setup commands actually used (via `uv`, not conda)

`uv` was already installed on this machine and can manage isolated Python
versions itself, avoiding a conda install entirely:

```powershell
cd NO_GJEN_002
uv python install 3.9
uv venv --python 3.9 .venv_chm

uv pip install --python .venv_chm\Scripts\python.exe torch==2.0.1 torchvision==0.15.2 --index-url https://download.pytorch.org/whl/cpu
uv pip install --python .venv_chm\Scripts\python.exe pytorch_lightning==1.7 pandas matplotlib torchmetrics==0.11.4
uv pip install --python .venv_chm\Scripts\python.exe "numpy<2" "setuptools<81"
```

If reproducing this without `uv`: any Python 3.9 install + `pip install` with
the same package list/pins works identically - `uv` was just what was already
available here, not a hard requirement of the model itself.

## Two real gotchas found and fixed (not in the repo's own README - a genuine gap
in a 2023-era, since-unmaintained dependency list meeting a 2026 package
resolver's defaults)

1. **NumPy 2.x breaks this torch build.** `torch==2.0.1` was compiled against
   NumPy 1.x's ABI. Installing packages without pinning numpy pulls the
   latest (2.0.2 as of this setup), which torchvision's import chain fails on:
   `UserWarning: Failed to initialize NumPy: _ARRAY_API not found`. **Fix**:
   `numpy<2` explicitly (installed 1.26.4).
2. **`pkg_resources` (needed by `torchmetrics`) was removed from modern
   `setuptools`.** A fresh `uv venv` doesn't include `setuptools` by default,
   and even installing the latest `setuptools` (82.0.1 as of this setup) no
   longer includes `pkg_resources` at all - it was removed upstream, with
   `setuptools` itself printing: *"pkg_resources is deprecated... slated for
   removal as early as 2025-11-30... pin to Setuptools<81."* **Fix**:
   `setuptools<81` explicitly (installed 80.10.2).

## Model code and checkpoints - you download these yourself

The model is Apache-2.0 licensed and freely available, but it is ~760 MB with
the checkpoints and is upstream's to distribute, not ours, so it is **not
committed here** (`chm_model/HighResCanopyHeight-main/` is gitignored). Fetch it
into `chm_model/` once:

- `chm_model/HighResCanopyHeight-main/` - the model source code. Download the
  plain GitHub zip archive of
  `facebookresearch/HighResCanopyHeight` (`.../archive/refs/heads/main.zip`)
  and unpack it here - no `git` dependency needed.
- `chm_model/HighResCanopyHeight-main/saved_checkpoints/compressed_SSLhuge_aerial.pth`
  (784,469,429 bytes) - the aerial-trained quantized model weights.
- `chm_model/HighResCanopyHeight-main/saved_checkpoints/aerial_normalization_quantiles_predictor.ckpt`
  (9,428,091 bytes) - the required image-normalization network.
- Both fetched via **plain HTTPS** from Meta's public "Data for Good" S3
  bucket (`dataforgood-fb-data`, confirmed anonymous/unsigned-read, CC-style
  open dataset - https://registry.opendata.aws/dataforgood-fb-forests/) -
  the repo's own README suggests the `aws s3 --no-sign-request` CLI, but
  that's not actually necessary; the exact object URLs work with a plain
  `download.file()`/`Invoke-WebRequest` call, avoiding an AWS CLI
  dependency entirely:
  ```
  https://dataforgood-fb-data.s3.amazonaws.com/forests/v1/models/saved_checkpoints/compressed_SSLhuge_aerial.pth
  https://dataforgood-fb-data.s3.amazonaws.com/forests/v1/models/saved_checkpoints/aerial_normalization_quantiles_predictor.ckpt
  ```

## Important finding: the repo's own `inference.py` is NOT a generic "run on my
image" tool

It's a benchmark/evaluation script hardcoded to Meta's own NEON validation
dataset (`./data/neon_test_data.csv` + specific paired image files it expects
to find locally) - it computes MAE/RMSE/R² against known ground truth, it
doesn't accept an arbitrary input image path. **A real Norwegian-data
integration will need a small custom wrapper**, not a call to `inference.py`
as a black box - reusing its `SSLModule` (main model) and `RNet`
(normalization network) classes directly, the same way `chm_model/
smoke_test.py` does, but feeding real 256x256 RGB crops (a real orthophoto
tile, tiled to that size, normalized the same way) instead of NEON's own test
set or (as in the smoke test) synthetic noise.

## What "real" integration will still need, once orthophoto access exists

1. A real orthophoto tile source (the actual blocker - see project memory).
2. Tiling logic to cut a fetched orthophoto into 256x256 RGB crops aligned to
   each population polygon (mirrors the qmd's own `fn.getOrtoImages()` tiling
   math - `NO_GJEN_002/R/orthophoto_source.R` already handles this piece,
   built 2026-08-05, for a *local* raster source; needs pointing at whatever
   the real fetched orthophoto ends up being).
3. The custom Python wrapper described above (SSLModule + RNet on real
   crops, not `inference.py`).
4. Georeferencing the model's per-pixel output raster back onto real
   coordinates, then zonal-stat aggregation per population polygon (median,
   matching how `meta_media` is computed today from the original NINA
   workflow) - not yet built, since there's nothing real to test it against.
5. An R-side `system2()` wrapper calling into `.venv_chm`'s Python, matching
   the `convert_n50_2006_sosi_to_gpkg.R` / QGIS integration pattern in
   NO_CONN_001 - not yet built, same reason as #4.

## To re-verify this environment still works (e.g. after a machine change)

```powershell
cd NO_GJEN_002
.venv_chm\Scripts\python.exe chm_model\smoke_test.py
```
Expect: `=== SMOKE TEST PASSED ===` with output shape `(1, 1, 256, 256)`. This
does NOT need or use any Norwegian data - it's a pure environment/dependency
check, safe to re-run any time.
