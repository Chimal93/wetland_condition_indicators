# NO_CONN_001 - the two national variants

The connectivity indicator has been computed nationally twice. The two runs
use the **same method, the same infrastructure data and the same code**; they
differ only in which wetland polygons are scored. Both are kept.

| | `national_2023` (mire-model) | `national_2023_AR5` (AR5) |
|---|---|---|
| Wetland population | National mire-probability model (Bakkestuen), with field-mapped NiN polygons as fallback where the model has no data | AR5 myr (ARTYPE 60), dissolved into connected patches |
| Coverage | Model stops at about 64 N - **northern Norway is NiN-mapped polygons only** | National |
| Polygons scored | 1,151,903 | 722,567 |
| Nord-Norge polygons | 4,917 | 127,464 |
| Anchors (kvotient) | X0 = 0.1414, X100 = 177.75 | X0 = 0.1562, X100 = 1487.66 |
| Index by region | NN 0.648, MN 0.974, VL 0.958, OL 0.971, SL 0.976 | NN 0.855, MN 0.911, VL 0.825, OL 0.917, SL 0.908 |
| National index | 0.967 | 0.898 |
| Run date / time | 2026-08-17 (distances) + 2026-08-19 (scaling) | 2026-09-18/19, 24.8 h end to end |
| Fidelity to the original | Closer - the original indicator used the mire-probability model | Deviates on population, matches NO_GJEN_001's wetland population |

## The anchors are not shared

The scaling anchors are the 1st and 99th percentile of each run's own
log-kvotient distribution, so **the two variants are not on a common scale**.
A side-check rescored the AR5 polygons with the mire-model anchors
(`Fetch/compare_ar5_vs_model_anchors.R`, result in
`img/ar5_vs_model_anchors/ar5_vs_model_anchors.csv`) and separates the two
effects:

| Region | Effect of the anchors | Effect of the population |
|---|---|---|
| Nord-Norge | -0.026 | **+0.233** |
| Midt-Norge | -0.022 | -0.041 |
| Vestlandet | -0.034 | -0.099 |
| Østlandet | -0.021 | -0.033 |
| Sørlandet | -0.017 | -0.051 |

The anchor change is small and uniform; the difference between the variants
is a population difference, which is what they are meant to test.

## Files per variant

```
mire_scored_<label>.gpkg      every mire polygon: kvotient, index, index_note
region_agg_<label>.csv        area-weighted mean index per region + bootstrap CI
anchors_<label>.csv           the percentile anchors that run used
run_logs_AR5/                 per-region logs of the AR5 run (timings,
                              certified %, exact-fallback counts)
```
Per-region intermediates live in `Data/connectivity_output_simplified/`
(mire-model) and `Data/connectivity_output_ar5/` (AR5); the mire inputs in
`Data/wetland_map_simplified/` and `Data/wetland_map_ar5/`.

Maps: `img/NO_CON_001_connectivity_condition_map.png` (mire-model) and
`img/NO_CON_001_connectivity_condition_map_national_2023_AR5.png` (AR5).

## Regenerating

```
# mire-model variant (defaults)
Rscript Fetch/scale_and_map_connectivity_indicator.R

# AR5 variant, end to end (prepare -> distances -> scaling), 24.8 h
powershell -ExecutionPolicy Bypass -File .\run_connectivity_ar5.ps1
```
Scaling alone for the AR5 variant needs `CONNECTIVITY_SCORE_DIR=../Data/connectivity_output_ar5`,
`CONNECTIVITY_SCORE_PATTERN=connectivity_full_2023\.gpkg$` and
`CONNECTIVITY_SCORE_LABEL=national_2023_AR5`.

**Hazard:** running the scaling script with no environment variables set
re-writes the `national_2023` files. It reproduces them from the same
inputs, so the content is identical, but do not run it expecting the AR5
variant without setting the label.

## Note on the August run logs

The mire-model run predates this archiving convention and its logs were only
in the temporary folder, which has since been cleared. Its timings, certified
percentages and per-region counts are recorded in `CONNECTIVITY_NOTES.md`
and in the 2026-09-22 advancement document instead.
