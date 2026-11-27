# Canopy-height model comparison against LiDAR (VAAT-GJEN-02)

The study behind three choices in `VAAT-GJEN-02` version 000.004: the model
(CHMv2 instead of CHMv1), its **calibration** to LiDAR, and the
**validation cells** used for the uncertainty.

Run: `bash docker/run_VAAT-GJEN-02_chm_comparison.sh` (inside `screen`,
~3.5 h on one RTX 5090; needs the same setup as the national map, see
`docker/README.md`). The scripts are those that produced the published
calibration (26 Nov. 2026). Since then only the paths have been turned
into settings and the steps moved into the Docker runner; they have not
been rerun after that change.

## Method

| Step | Script | What it does |
|---|---|---|
| 1 | `01_make_inputs.py` | The ~25,000 AR5 mire sample points of `VAAT-GJEN-01` (`vaatmark_pop_openS.gpkg`). For each, the 20 m cell of the global grid that contains it; a 288 m orthophoto window centred on the cell; the LiDAR cell from Kartverket's DOM1 − DTM1 (1 m, clamped at 0; median = `VAAT-GJEN-01`'s statistic); the flight project and dates of the photo; the LiDAR project and year (Kartverket's catalogue). |
| 2 | `02_chmv1_cpu.py` | CHMv1 exactly as in version 000.003: int8 checkpoint, CPU, Python 3.9 / torch 2.0.1 of the canopy-height image. |
| 3 | `03_gpu_models.py` | CHMv1 on GPU (0.5 m and 0.6 m input) and CHMv2 (0.5 m, and 0.6 m = the resolution it was trained on). Every prediction is brought back to the 0.5 m grid, so the cell is always the same 40 × 40 pixels. |
| 4 | `04_compare.py` | Agreement with LiDAR per model, for cell mean and median; a linear calibration *LiDAR = a + b × model*, tested on data not used for the fit (random 5-fold, leave one region out, leave one photo year out); errors by height class, region, zone, photo year and month, time between photo and LiDAR, LiDAR point density; example maps. |
| 5 | `05_calibration_and_validation.py` | The calibration used (CHMv2 at 0.6 m, cell median, all usable points) and the validation cells (`validation_cells_lidar_20m_median.csv`). |

`cmp_common.py` is shared by steps 2–3. Python environment:
`pyproject.toml` / `uv.lock` (Python 3.12, PyTorch 2.11 with CUDA 12.8,
transformers 5.24).

## Results (25,027 usable cells, cell median)

| Model | MAE uncalibrated | MAE calibrated, leave one region out | r |
|---|---|---|---|
| CHMv1 (CPU, as 000.003) | 0.35 m | 0.44 m | 0.80 |
| CHMv2, 0.5 m input | 0.71 m | 0.28 m | 0.87 |
| CHMv2, 0.6 m input (used) | 0.64 m | 0.30 m | 0.86 |

- CHMv2 overestimates about twofold but is linear, so a single calibration
  fixes it (slope 0.53; 0.49–0.55 per region; the same when one photo year
  is left out). CHMv1 gets worse with calibration: its errors are not a
  simple scale.
- The national map uses the 0.6 m input, the resolution CHMv2 was trained
  on (`national_chm.py`), so the calibration is fitted on that variant. The
  0.5 m input is marginally better here.
- Speed on one RTX 5090: CHMv2 72 tiles/s; CHMv1 on CPU (as 000.003) 3.8 tiles/s.
- Photo years 2015–2024, LiDAR years 2006–2025 (median 2017).

## Outputs and where they go

In `<CHM_COMPARISON_DIR>/<OUT>/` (default `runs/chm_comparison/out_25k/`):
`summary.txt` (all tables above and more), `metrics.csv`,
`calibration_validation.csv`, `calibration_coefficients.csv`,
`residuals_by_factor.csv`, `paired.csv` (every point with every
prediction), figures, and from step 5:

- `calibration_chmv2_median_fit.json`: a and b. Copied by hand into
  [`../chm_national/calibration_chmv2_median.json`](../chm_national/calibration_chmv2_median.json),
  which the indicator reads (a = −0.012697, b = 0.533637).
- `validation_cells_lidar_20m_median.csv`: copy it to
  `NATIONAL_CHM_OUT_DIR`, where `docker/run_VAAT-GJEN-02_cell_indicator.sh`
  reads it for the uncertainty.

Neither the outputs nor the photo windows are committed: they contain the
licensed imagery or derive from AR5.
