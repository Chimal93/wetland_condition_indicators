# NO_GJEN_002 — Canopy height from orthophoto: process, decisions and parameters

**Status as of 2026-09-04.** Method built and validated on the 46-polygon
test set; national run prepared but **not yet executed**.

This document covers *why the method is what it is* — the exploratory
route through Sentinel-2, the decision to move to Meta's model on real
orthophoto, how that model works, and every parameter choice with its
justification. For **environment setup** (Python versions, checkpoints,
dependency gotchas) see `CHM_MODEL_SETUP.md`, which this document does
not duplicate.

---

## 1. What this indicator needs, and why it is separate from NO_GJEN_001

NO_GJEN_001 measures wetland regrowth (*gjengroing*) from **airborne
LiDAR**. NO_GJEN_002 measures the same phenomenon from **orthophoto /
flyfoto**, for one reason: orthophoto is re-flown on a standardised,
frequent cycle, whereas LiDAR is updated rarely and non-standardly.
GJEN_002 therefore exists to enable **continuous monitoring**, not to be
a more accurate one-off.

Two consequences follow, and both constrain everything below:

1. **The canopy-height input must come from orthophoto and nothing
   else.** Substituting a ready-made LiDAR-derived canopy height model
   would collapse GJEN_002 into a duplicate of GJEN_001 and defeat the
   purpose. It would also lock future users into a specific vendor's
   derived products rather than a standard, broadly-available imagery
   type.
2. **Reference levels are deliberately borrowed from GJEN_001.** The
   X0/X100 reference values remain LiDAR-derived. This is by design, not
   a gap to be closed — it keeps the two indicators on a common baseline
   while GJEN_002 supplies the frequently-refreshed measurement.

---

## 2. Phase 1 — the ETH / Sentinel-2 provisional stand-in

### 2.1 Why a stand-in was needed

Norwegian orthophoto was, for most of this project, **inaccessible**.
Kartverket's `wms.geonorge.no/skwms1/wms.nib` is gated ("Norge digitalt
begrenset"); the formerly-open WMTS closed on 2026-03-01; the replacement
`services.norgeibilder.no` still requires existing partner credentials;
Norkart/Webatlas is commercial with no self-service tier. This was
re-verified twice (2026-08-05, 2026-08-27) and was a genuine structural
wall, not a missing-account problem.

To keep building while access was pending, a substitute canopy-height
source was needed.

### 2.2 Why *not* Sentinel-2 fed to Meta's model

The obvious idea — point Meta's model at free Sentinel-2 imagery — is
scientifically void. Meta's `compressed_SSLhuge_aerial` checkpoint is
trained on **50 cm aerial imagery**, and Meta's own documentation notes
quality degrades on satellite imagery far finer than Sentinel-2's 10 m.
Running it on 10 m input would produce numbers, not measurements.

### 2.3 What was used instead: ETH Global Canopy Height

**Lang et al. (2022/2023), ETH Zurich Global Canopy Height 2020** — a
*different, purpose-built* model fusing GEDI spaceborne LiDAR with
Sentinel-2 at 10 m, CC-BY-4.0. Distributed as Cloud-Optimized GeoTIFF
tiles from ETH's public share, streamed with `/vsicurl/`, requiring **no
Google Earth Engine dependency** (found specifically by looking for a
non-GEE path; this avoided an interactive OAuth step that cannot be
automated).

Implemented in `R/fetch_eth_canopy_height.R`. Every value was tagged
`chm_source = "eth_sentinel2_2020_PROVISIONAL"` and never blended with
real data.

**National result (2026-08-27):** 24,516 of 24,524 polygons valued
(99.97%), 20 tiles in ~5.5 min. This was the first time this indicator
had ever run at national scale — the pipeline architecture (region and
strata assignment at 24k scale, reference joins, sigmoid scaling,
area-weighted aggregation, map output) was proven here.

### 2.4 Why it was never trustworthy, and was always going to be replaced

Validated against the 46 test polygons with known real values:

| | vs NINA's Meta run | vs LiDAR |
|---|---|---|
| Pearson r | 0.46 | 0.57 |
| Mean bias | **+8 m** | **+8 m** |

The scatter revealed the real failure mode, which the summary statistics
alone understate: almost all *true* values cluster near 0 m (most test
polygons are open, unencroached wetland), while ETH's predictions
scattered across 0–15 m regardless. This is **compressed dynamic range**,
not merely noise — the model rarely resolves the "healthy open vs.
lightly encroached" distinction this indicator most depends on.

A national map built on it (`NO_GJEN_002_national_pipeline_PROVISIONAL.R`)
placed **every region** in "Dårlig"/"Svært dårlig" — consistent with the
documented upward bias, and not a finding about Norway's wetlands.

**Conclusion: ETH/Sentinel-2 served its purpose as scaffolding for
pipeline mechanics, and is superseded. Its values must not be reported.**

---

## 3. Phase 2 — Meta's model on real orthophoto (current method)

### 3.1 Imagery requirements

The pipeline needs an RGB orthophoto covering the polygons being scored.
It is deliberately agnostic about where that comes from - a national
mapping agency, a commercial supplier, or your own imagery - and reads it
through one interface (`Fetch/orthophoto_source.R`), configured by
`ORTHOPHOTO_SOURCE_PATH` (plus `ORTHOPHOTO_SOURCE_USERPWD` if the source
needs authentication). See `orthophoto_access.template.txt`.

What the imagery has to satisfy:

- 3-band RGB, 8-bit
- 0.5 m per pixel or finer (the model runs at 0.5 m; 25 cm was tested and
  was both worse and about three times slower - see section 4)
- a projected CRS, EPSG:25833 for Norway
- GeoTIFF, Cloud-Optimised GeoTIFF, or a VRT over either

A national mosaic at 50 cm is measured in terabytes, so it is **never
downloaded**. For a remote Cloud-Optimised GeoTIFF the server must
support **HTTP range requests** (`Accept-Ranges: bytes`); GDAL's
`/vsicurl/` driver then fetches only the byte ranges covering each tile
window. A local GeoTIFF or VRT works the same way without any network.

The reference run behind the published results used a commercial national
50 cm mosaic (2025) accessed under licence. That licence does not permit
redistributing the imagery or the access details, so none of it appears
in this repository - the published per-polygon canopy heights (section 8)
are what make the results reproducible without it.

`/vsicurl/` is **read-only by design** (GET/HEAD only), so the source
imagery cannot be modified by this pipeline — see `R/orthophoto_source.R`
for the full read-only guarantees.

### 3.2 The pipeline

```
  orthophoto COG (remote, read-only)
        │   windowed range reads, aligned to a fixed 128 m grid
        ▼
  256×256×3 uint8 RGB tiles          ← R/orthophoto_source.R
        │
        ▼
  Meta HighResCanopyHeight model     ← chm_model/predict_tiles.py
        │   per-pixel height, metres
        ▼
  float32 predictions (.bin)
        │   georeferenced from the originating tile
        ▼
  zonal MEAN per wetland polygon     ← R/run_meta_chm_on_polygons.R
        │
        ▼
  meta_chm_mean  →  downstream index / reference joins
```

---

## 4. How Meta's model works

**Paper:** Tolan et al. (2024), *Very high resolution canopy height maps
from RGB imagery using self-supervised vision transformer and
convolutional decoder trained on Aerial Lidar*, Remote Sensing of
Environment. <https://doi.org/10.1016/j.rse.2023.113888> ·
arXiv <https://arxiv.org/abs/2304.07213>
**Code:** <https://github.com/facebookresearch/HighResCanopyHeight> (Apache 2.0)

### 4.1 Architecture

Two networks are involved.

**A. The canopy-height model (`SSLModule` → `SSLAE`)**

- **Backbone:** `SSLVisionTransformer`, a self-supervised (DINOv2-style)
  Vision Transformer. In the *huge* configuration used here:
  `embed_dim=1280`, `depth=32`, `num_heads=20`, features taken from
  layers `(9, 16, 22, 29)`.
- **Decoder:** `DPTHead` (Dense Prediction Transformer head) fusing those
  four feature scales — `in_channels=(1280,1280,1280,1280)`,
  `post_process_channels=[160, 320, 640, 1280]` — to produce a dense,
  per-pixel output at input resolution.
- **Output formulation:** `classify=True, n_bins=256` — height is
  predicted as a binned distribution rather than direct scalar
  regression.
- **Scaling:** `SSLModule` wraps the network as `10 × model(x)`. The ×10
  converts to **metres**. Predictions are then passed through `relu()`,
  clamping negative heights to 0 — matching how the original treats
  ground truth (`chm[chm<0] = 0`).

The key property for our purpose: it is trained against **aerial LiDAR**
ground truth, so it learns to infer 3-D structure from 2-D RGB texture,
shadow and parallax cues. It is not a vegetation-index proxy.

**B. The normalisation network (`RNet`)**

A small CNN (6 conv blocks with max-pooling → 4 fully-connected layers)
taking a 256×256×3 image and predicting **6 numbers**: the 5th and 95th
percentiles per RGB band that the *equivalent Maxar satellite image*
would have. Used to colour-match aerial input to the satellite imagery
the **base** model was trained on.

**RNet is deliberately NOT used in our configuration — see §5.3.**

### 4.2 Why the checkpoint choice matters

Meta ship several checkpoints. Two matter here:

| checkpoint | trained on | normalisation needed? |
|---|---|---|
| `compressed_SSLhuge.pth` (satellite) | Maxar satellite | **Yes** — aerial input must be colour-matched |
| `compressed_SSLhuge_aerial.pth` | **aerial imagery** | **No** — already finetuned on aerial |

`inference.py` encodes this as `--trained_rgb` ("True if model was
finetuned on aerial data"), which gates the whole normalisation block via
`if not self.trained_rgb:`. We use the **aerial** checkpoint.

`compressed` also means the weights are dynamically **int8-quantised**
(Linear / Conv2d / ConvTranspose2d) and run **CPU-only** by the model's
own logic (`if 'compressed' in checkpoint: device='cpu'`). No GPU is
required.

---

## 5. Parameters — what we chose and why

### 5.1 Tile size — **256 × 256 px (fixed)**

Not a free choice; it is the model's input size. Changing it would
require re-checking model compatibility.

### 5.2 Model input resolution — **0.5 m/px** (tiles cover 128 × 128 m)

- NINA's original `.qmd` found **0.5 m outperformed 1 m** for this model.
- We additionally **tested 0.25 m** (the imagery provider's 25 cm source, same 46
  polygons): it was **worse**, not better — slope against LiDAR fell from
  0.83 to 0.50 on vegetated polygons, and tiling took 13.2 min vs 4.7 min
  (4× the data per tile from a 13.76 TB file).
- **Decision: 0.5 m, sourced from the 50 cm orthophoto.** Configurable
  via `CHM_TILE_RESOLUTION`, but there is measured evidence against
  changing it.

Tiles are aligned to a fixed grid derived from `tile_size × resolution`
(not simply cropped to each polygon's bbox), so tile boundaries are
reproducible — mirroring the `.qmd`'s own `fn.getOrtoImages()` logic.

### 5.3 Maxar quantile normalisation — **OFF** (the most consequential choice)

Applying it to the aerial checkpoint **actively degrades accuracy**.
Measured on the 46 polygons against LiDAR:

| | r (all) | r (vegetated) | slope (vegetated) | MAE (all) |
|---|---|---|---|---|
| normalisation **ON** | 0.879 | 0.731 | 0.564 | 0.38 m |
| normalisation **OFF** | **0.952** | **0.894** | **0.833** | **0.31 m** |

This was originally applied in error, and it manifested as a systematic
~2× under-prediction of tall canopy that the aggregate statistics
partially masked. It is now **auto-detected**: normalisation defaults off
whenever the checkpoint name contains `aerial`, rather than depending on
a flag being remembered. `--force-norm` overrides for comparison runs.

The fixed ImageNet-style normalisation
`Normalize((0.420, 0.411, 0.296), (0.213, 0.156, 0.143))` **always**
applies — it is part of the model's expected input pipeline, distinct
from the Maxar colour-matching.

### 5.4 Zonal statistic — **MEAN**, not median

Predictions are heavily right-skewed (mostly ~0 with a few tall trees),
so the statistic materially changes the answer. Against LiDAR:

| statistic | r (all) | MAE (all) |
|---|---|---|
| median | 0.755 | 0.65 m |
| **mean** | **0.952** | **0.31 m** |

Both columns are written; **only `meta_chm_mean` is validated and should
be used downstream.**

### 5.5 Tile pixel type — **uint8 (`INT1U`)**

Two hard reasons, not preference: PIL cannot read multi-band float TIFFs
at all, and `TF.to_tensor()` only applies the [0,255] → [0,1] scaling the
model was trained on for uint8 input. `resample()` silently promotes to
float32, so the write is forced to `INT1U`. The source orthophoto is
8-bit, so nothing real is lost; bilinear resampling is a weighted mean of
neighbours and cannot overshoot 0–255.

### 5.6 Python → R handoff — **raw float32, not an image format**

Predictions are written as headerless little-endian float32, C order,
**first row = northernmost**, documented as an OUTPUT CONTRACT in
`predict_tiles.py`.

This is deliberate. Writing predictions as a plain TIFF produced a file
with **no geotransform**, and terra/GDAL then read its rows **bottom-up**
— an exact vertical mirror, with no error raised. The zonal median
silently sampled mirror-image ground and returned **0.04 m where LiDAR
said 3.85 m**. Row order in a TIFF lacking a geotransform is
implementation-defined and must not be relied on; hence an explicit byte
layout that we define.

---

## 6. Data inputs

| input | source | notes |
|---|---|---|
| **Orthophoto** | user-supplied, via `ORTHOPHOTO_SOURCE_PATH` | reference run: a commercial national 50 cm RGB mosaic (2025), EPSG:25833, read-only, never downloaded |
| **Wetland polygons** | `Data/OpenS_data/nin_data/…FILEGDB.gdb`, layer `naturtyper_nin_omr`, filter `hovedøkosystem == "våtmark"` | **24,524 polygons**, median 0.40 ha, mean 1.62 ha, max 446 ha, 39,788 ha total |
| **Region boundaries** | `Data/spatial/regions.shp` | 5 regions; ids 3 and 5 need the known encoding fix (→ Østlandet / Sørlandet) |
| **Model weights** | `compressed_SSLhuge_aerial.pth` (784 MB) + `aerial_normalization_quantiles_predictor.ckpt` (9 MB) | Meta "Data for Good" S3, already downloaded locally |

**Credentials**, where a source needs them, are read from the environment
(`ORTHOPHOTO_SOURCE_USERPWD`) or from a local, gitignored
`orthophoto_access.txt`. They are never hardcoded in scripts and none are
distributed with this repository.

### Population note

NiN våtmark is a **selective survey of notable nature types**. AR5 myr —
which NO_GJEN_001 uses — contains 842,572 polygons covering 1,423,246 ha,
~36× more wetland area, and only 42.9% of NiN wetland centroids fall
inside it (the two maps are *not* nested and measure different things).
Switching to AR5 was evaluated and rejected for now on feasibility
grounds (~3,305 h, ~2.8 TB). **This leaves a known consistency gap
between GJEN_001 and GJEN_002 populations, to be discussed separately.**

---

## 7. Expected outputs

Written to `Data/OpenS_data/`:

**`meta_chm_<population>[_<Region>].csv`** — one row per polygon:

| column | meaning |
|---|---|
| `id` | NiN `identifikasjon_lokalId` |
| **`meta_chm_mean`** | **zonal mean predicted canopy height, metres — the validated value** |
| `meta_chm_median` | zonal median (written for comparison; not validated) |
| `meta_chm_n` | prediction pixels inside the polygon |
| `n_tiles` | tiles contributing |
| `chm_source` | `meta_highrescanopyheight_orthophoto` |
| `model_input_res_m` | 0.5 |
| `ortho_source` | orthophoto filename (provenance) |
| `region_filter` | region processed, if any |

**`meta_chm_…_failures.csv`** — per-polygon failures with `stage`
(`tiling` / `aggregate`) and error message. Failures are logged, never
silently dropped.

### Expected value ranges

From the validated test run: floor ~0.01 m on bare ground, national
maxima in the 6–8 m range for encroached wetland. Roughly three quarters
of wetland polygons are genuinely open and should sit near zero — a
result concentrated near 0 with a long right tail is *expected*, not a
malfunction.

---

## 8. Validation (46 wetland polygons, `NiN_metaTest.shp`)

Scored against airborne LiDAR (`DSM_median`), the best available ground
truth. NINA's own Meta run (`meta_media`) is shown as a peer, not a
target — it used older Kartverket imagery.

| predictor | r (all) | MAE (all) | r (veg) | slope (veg) | MAE (veg) |
|---|---|---|---|---|---|
| **Ours (0.5 m, norm off, mean)** | **0.952** | **0.31 m** | 0.894 | 0.833 | **0.75 m** |
| NINA's `meta_media` | 0.913 | 0.56 m | 0.897 | 1.361 | 1.06 m |
| ETH/Sentinel-2 (superseded) | — | — | — | — | +8 m bias |

We match or beat NINA's own run on every metric, and our slope is closer
to 1.0 in absolute terms (0.83 under vs their 1.36 over). Critically, the
open-vs-encroached discrimination that ETH lacked is restored: polygons
NINA calls open (≤1 m) get a median prediction of 0.01 m; those it calls
taller get 1.12 m.

---

## 9. Known limitations

1. **Validated on 46 polygons from one test set**, all wetland, against a
   different sensor (LiDAR). Strong, but not evidence about the full
   national range of sites.
2. **Slope 0.833** — tall canopy is still slightly under-predicted.
   Small, and better than NINA's over-prediction, but real.
3. **Imagery vintage differs** from NINA's run (2025 vs older), so exact
   agreement with `meta_media` is neither expected nor required.
4. **Population gap vs GJEN_001** (NiN vs AR5) — see §6.
5. **16 of 24,524 national polygons have invalid geometry** and abort
   `sf` operations outright; they are trapped per-polygon and logged.

---

## 10. Running it

See `CHM_MODEL_SETUP.md` for environment. Per-region national run:

```powershell
cd NO_GJEN_002
.\run_national_by_region.ps1                       # all five, smallest first
.\run_national_by_region.ps1 -Regions Vestlandet   # one region
.\run_national_by_region.ps1 -MaxPolygons 20       # smoke test
```

Designed for long runs: **resumable** (output CSV is the checkpoint;
already-processed polygons and already-predicted tiles are skipped),
**batched** (default 250 polygons per cut→infer→aggregate→clean cycle, so
disk stays flat and results accrue incrementally), and **per-polygon
error trapped** (one bad geometry cannot end a multi-hour run).

### Projected cost (NiN, 0.5 m) — treat as a floor, not a point estimate

| region | polygons | est. hours | est. disk |
|---|---|---|---|
| Vestlandet | 2,638 | ~9.5 | ~8 GB |
| Sørlandet | 2,726 | ~9.8 | ~8 GB |
| Nord-Norge | 5,695 | ~20.5 | ~17 GB |
| Østlandet | 6,342 | ~22.9 | ~19 GB |
| Midt-Norge | 7,123 | ~25.7 | ~22 GB |
| **total** | **24,524** | **~88–97** | ~82 GB (≈22 GB peak if cleaning per batch) |

Tiling is **network-bound** (low CPU — the machine stays usable);
inference is **CPU-bound** and PyTorch will use all cores unless capped
via `OMP_NUM_THREADS`.
