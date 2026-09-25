# NO_GJEN_002 — Gjengroing (Woody Encroachment) from aerial photography

Open reconstruction of NINA's second woody-encroachment indicator for
wetlands. It measures the same thing as
[`NO_GJEN_001`](../NO_GJEN_001/) — vegetation height in wetland, scaled
between a good-condition reference and a forest reference — but derives
the height from **aerial photography** with a deep-learning canopy-height
model instead of from LiDAR.

That matters practically: orthophoto is reflown far more often than
national LiDAR, so this indicator can be updated on a much shorter cycle.

Developed under the documentation standard of NINA's
[ecRxiv](https://github.com/NINAnor/ecRxiv) publishing platform. This is
an independent reconstruction and not an official NINA product.

## You must supply your own imagery

The pipeline does not ship, and cannot ship, the photography behind the
published numbers: it is commercial data used under a licence that does
not permit redistribution of the imagery or of the access details.

**Nothing identifying any particular provider is in this repository, by
design.** Configure your own source in either of two ways:

```powershell
# 1. environment variables (take precedence)
$env:ORTHOPHOTO_SOURCE_PATH    = "D:/imagery/ortho_50cm.tif"          # local file or VRT
$env:ORTHOPHOTO_SOURCE_PATH    = "/vsicurl/https://your.host/ortho.tif" # remote COG
$env:ORTHOPHOTO_SOURCE_USERPWD = "user:password"                       # only if it needs auth

# 2. or copy the template and fill it in (the filled file is gitignored)
copy orthophoto_access.template.txt orthophoto_access.txt
```

What the imagery has to satisfy: 3-band RGB 8-bit, **0.5 m per pixel or
finer**, a projected CRS (EPSG:25833 for Norway), as GeoTIFF, COG or VRT.
A remote COG must support HTTP range requests — the mosaic is never
downloaded, only the byte ranges covering each tile window are read.
Details in [`METHODOLOGY_CANOPY_HEIGHT.md`](METHODOLOGY_CANOPY_HEIGHT.md).

## You do not need imagery to reproduce the results

The expensive step is running the model over the country: **114,406 tile
reads across 24,521 wetland polygons, about 90 hours** (45.6 h of which is
model inference on CPU). Its output — one canopy height per polygon — is
committed here:

```
Data/OpenS_data/meta_chm_national_RAW_2026-09-17/
```

15 MB, checksummed, with the run logs. Everything downstream (scaling,
aggregation, maps, delivery files) recomputes from it in minutes. So the
published indicator is fully reproducible without any imagery access;
imagery is needed only to regenerate the predictions themselves, or to
run the indicator for a new year.

## Folder structure

| Folder | Contents |
|---|---|
| `Fetch/` | Input fetchers and the imagery interface (`orthophoto_source.R`), the per-polygon model runner, and the validation scripts. |
| `chm_model/` | Our wrapper around the canopy-height model (`predict_tiles.py`) and its smoke test. The model itself is fetched, not vendored — see `CHM_MODEL_SETUP.md`. |
| `Main/` | `NO_GJEN_002_national_pipeline.R` (indicator) and `export_deliverables.R` (platform format). |
| `Data/OpenS_data/` | The frozen per-polygon predictions, and the two reference tables borrowed from NO_GJEN_001. Large inputs (NiN, bioclim) are fetched. |
| `Results/` | Maps and the pipeline's tables. |
| `Deliverables/` | The indicator in the ecosystemCondition platform format. |

## How to run it

**From the frozen predictions (minutes, no imagery):**

1. `Fetch/fetch_nin_data.R` — the national NiN nature-type dataset.
2. `Fetch/fetch_bioclim_zones.R` — Moen bioclimatic zones.
3. Two inputs come from the sibling indicator, which builds them:
   `NO_GJEN_001/Fetch/build_ssb_grids.R` → `ssb50km.shp` (aggregation grid),
   and the two reference tables (`refvaatmark_openS_30m.csv`,
   `vegHeights_skog_climZoneRegion_openS_20m.csv`, both committed here).
4. `Main/NO_GJEN_002_national_pipeline.R` — index, aggregation, map.
5. `Main/export_deliverables.R` — the delivery files.

**Regenerating the predictions (needs imagery, ~90 h nationally):**

1. Set up the model once: [`CHM_MODEL_SETUP.md`](CHM_MODEL_SETUP.md).
2. Configure imagery access (above).
3. `run_national_by_region.ps1` — runs region by region, checkpointed and
   resumable; a closed laptop lid or a restart costs only the batch in
   flight. Set `$env:RSCRIPT` if R is not at the default path.

Validate before trusting a new run: `Fetch/validate_meta_chm_orthophoto.R`
compares predictions against LiDAR canopy height on the test polygons.

## Method in brief

- The model is Meta's HighResCanopyHeight (Tolan et al. 2024), aerial
  checkpoint, run on 256 × 256 px tiles at 0.5 m (128 m on the ground),
  CPU inference, averaged per polygon.
- Two settings are load-bearing and handled automatically: the
  satellite-specific normalisation built into the published model **must
  be skipped** for the aerial checkpoint, and polygon values **must be
  aggregated with the mean, not the median**, because the per-pixel
  distribution is right-skewed. Both are explained in the methodology
  document; getting either wrong changes the answer materially.
- Reference levels are borrowed unchanged from `NO_GJEN_001`, as the
  original design does: the good-condition wetland reference evaluated at
  30 m, and the forest anchor at 20 m. `GJEN002_SKOG_SCALE=1m` selects the
  earlier native-resolution anchor for comparison (outputs `_skog1m`).
- Scaling is the same sigmoid as `NO_GJEN_001`, so the two indicators
  differ only in how the population height is measured.

## Results

Area-weighted mean indicator per region, 24,026 wetland polygons:

| Region | Indicator | Mean predicted height | n |
|---|---|---|---|
| Midt-Norge | 0.988 | 0.80 m | 6,754 |
| Nord-Norge | 0.972 | 0.75 m | 5,642 |
| Vestlandet | 0.971 | 1.15 m | 2,618 |
| Østlandet | 0.877 | 3.01 m | 6,286 |
| Sørlandet | 0.802 | 3.89 m | 2,726 |
| **Norge** | **0.957** | 0.68 m | 24,026 |

Where the two encroachment indicators can be compared they agree closely —
northern, western and eastern Norway within 0.03 of `NO_GJEN_001` — because
they share both reference levels. Sørlandet is the real divergence (0.80
against 0.95) and is where mapped wetland polygons are most tree-fringed.

## Verification

- Against LiDAR canopy height on the 46 test polygons that have both:
  **r = 0.95, MAE = 0.31 m** — matching or beating the original work's own
  validation on every metric.
- The national run completed with **zero failures and no missing values**
  across all five regions.

## Known limitations

- **Imagery is user-supplied**, so results depend on the mosaic used. The
  published run used a commercial national 50 cm mosaic whose product year
  is 2025, but whose individual flights span several years — the delivery
  metadata says so, and this is the main caveat when comparing regions.
- **The index saturates for open bog**: 64 % of polygons score above 0.99,
  because the sigmoid is flat near the reference. Fine for a condition
  score, misleading if read as a continuous height measure.
- **495 polygons (2 %) are excluded** because they fall in the four
  region × bioclimatic-zone strata that have no good-condition reference
  value — the same limitation as `NO_GJEN_001`.
- **The population differs from `NO_GJEN_001`'s**: every field-mapped NiN
  wetland polygon here, a stratified sample of the AR5 wetland layer
  there. They are not interchangeable; see both metadata sheets.
- Raw predicted heights are far higher in the south (2.5-3.5 m median)
  than elsewhere (under 0.2 m). The direction matches the reference
  pattern, but the magnitude should be checked against imagery season and
  flight year before being read as an ecological finding.

## R and Python environment

R: `sf`, `terra`, `dplyr`, `readr`, `tidyr`, `tibble`, `ggplot2`,
`ggrepel`, `RColorBrewer`, plus `ecTools` (see the root README for the
pinned install). Python for the model: see `CHM_MODEL_SETUP.md`.
