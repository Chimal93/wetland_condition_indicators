# NO_GJEN_002 — raw national canopy-height run (archived 2026-09-17)

Frozen copy of the per-polygon canopy-height values produced by the Meta
HighResCanopyHeight model on aerial orthophoto for every NiN wetland
polygon in Norway. This folder is the reproducibility anchor for
NO_GJEN_002: everything downstream (reference scaling, index, maps,
deliverables) is recomputed from these five files in minutes, while
regenerating them takes ~90 hours of laptop compute plus imagery
orthophoto access. Do not edit; regenerate into a new dated folder if the
model, resolution or polygon set changes.

## Files

| file | polygons | region |
|---|---|---|
| `meta_chm_national_Vestlandet.csv` | 2,638 | Vestlandet |
| `meta_chm_national_Sorlandet.csv` | 2,726 | Sørlandet |
| `meta_chm_national_NordNorge.csv` | 5,692 | Nord-Norge |
| `meta_chm_national_Ostlandet.csv` | 6,342 | Østlandet |
| `meta_chm_national_MidtNorge.csv` | 7,123 | Midt-Norge |
| `logs/<Region>.log` | | run logs: batch summaries, timings and totals. Per-tile progress lines and any imagery URL are removed from this published copy |
| `SHA256SUMS.txt` | | checksums of the five CSVs |

Total 24,521 polygons (24,524 loaded; 3 without a region assignment
dropped). No failures, no NA values.

Columns: `id` (NiN polygon identifier), `meta_chm_mean` (m — the
validated value, use this), `meta_chm_median` (m — do not use for
scaling; the per-pixel distribution is right-skewed), `meta_chm_n`
(pixels inside the polygon), `n_tiles`, `chm_source`,
`model_input_res_m` (0.5), `ortho_source` (a generic descriptor: the imagery is licensed commercial data and the provider and product are not identified here), `region_filter`.

## How they were produced

- Model: Meta HighResCanopyHeight (Tolan et al. 2024), aerial checkpoint
  `compressed_SSLhuge_aerial.pth`, CPU inference, 256 x 256 px tiles at
  0.5 m/px (128 m ground), Maxar normalisation skipped for the aerial
  checkpoint (auto-detected), fixed ImageNet-style normalisation applied.
  Script: `chm_model/predict_tiles.py`.
- Input: a national 50 cm RGB orthophoto (2025 mosaic, EPSG:25833), read as
  HTTP range requests from a Cloud-Optimised GeoTIFF under a commercial
  licence that does not permit redistribution; polygons buffered, tiled,
  predicted, aggregated per polygon (`R/run_meta_chm_on_polygons.R`,
  `R/orthophoto_source.R`, runner `run_national_by_region.ps1`).
- Population: NiN wetland polygons (national dataset), `CHM_POPULATION =
  national`, region assignment by largest overlap with `regions.shp`.
- Validation of the method on 46 test polygons against LiDAR CHM: r =
  0.952, MAE = 0.31 m (see `METHODOLOGY_CANOPY_HEIGHT.md`).

## Run time (from the logs)

| region | tiles | model compute | active wall time | note |
|---|---|---|---|---|
| Vestlandet | 10,617 | 4.3 h | 18.2 h | Sep 4-5 |
| Sørlandet | 8,471 | 3.5 h | 19.3 h | Sep 5-6 |
| Nord-Norge | 26,506 | 9.6 h | 12.6 h | Sep 9-15; plus ~130 h asleep (laptop lid closed, Sep 9-15) |
| Østlandet | 24,726 | 10.2 h | 13.6 h | Sep 15-16 |
| Midt-Norge | 43,914 | 18.0 h | 25.9 h | Sep 16-17 |
| **total** | **114,234** | **45.6 h** | **89.5 h** | model = ~51 % of active time; the rest is orthophoto fetch, tiling and aggregation |

Timing per tile was stable at 1.46-1.51 s (1.25 s for Nord-Norge's first
14 batches). The Nord-Norge "8,566 min" in its log is wall time including
the sleep; the run itself was unaffected (it resumed where it stopped).

## Regional summary of `meta_chm_mean`

| region | median | note |
|---|---|---|
| Vestlandet | 0.18 m | |
| Nord-Norge | 0.15 m | |
| Midt-Norge | 0.18 m | |
| Østlandet | 2.49 m | |
| Sørlandet | 3.52 m | |

The south/north contrast (15-20x) is consistent in direction with the
30 m good-condition reference heights of NO_GJEN_001 (southern wetlands are
more tree-fringed) but is large; check per-polygon distributions and
orthophoto season before interpreting.
