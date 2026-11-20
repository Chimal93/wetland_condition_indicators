# NO_NDVI_001 — Primary production (NDVI trend) in wetlands

> **Status: provisional, not finished.** MODIS only, 983 scored polygons,
> no uncertainty estimate. Delivered so that the method and the platform
> files can be reviewed. See [Status and limitations](#status-and-limitations).

Open reconstruction of the wetland NDVI indicator described in NINA's
[ecosystemCondition documentation, chapter 15](https://ninanor.github.io/ecosystemCondition/NDVI-indicator-wetland.html).
That work was exploratory and never defined a scaling: it found that NDVI
overlaps too much between condition classes to set reference values for
absolute NDVI. This reconstruction therefore scales the **trend** in NDVI
rather than its level, adapting the approach NINA used for the mountain
NDVI indicator (Framstad et al., 2022).

This is an independent reconstruction and not an official NINA product.

## Method in brief

1. **NDVI per polygon.** MODIS MOD13Q1 v6.1 (250 m, 16-day composites),
   June–September, 2000–2026, zonal mean per NiN wetland polygon,
   fetched directly from NASA Earthdata (`R/fetch_modis_ndvi.R`).
2. **Peak per year.** The maximum composite per polygon and growing
   season.
3. **Trend.** Least-squares slope of peak NDVI against year, per polygon.
   Polygons need at least one MODIS pixel (≥ 62,500 m²) and at least 10
   growing seasons.
4. **Reference and anchors.** Reference condition is no trend (slope 0).
   The threshold and the bad-condition anchor come from a permutation null
   distribution: each polygon's year labels are shuffled and the slope
   refitted. Its 97.5th percentile of |slope| (0.00214 NDVI/yr) maps to
   0.6, and its maximum (0.0107 NDVI/yr) maps to 0.
5. **Scaling.** Piecewise linear on |slope|, two-sided: greening and
   browning both count as deviation.
6. **Aggregation.** Area-weighted mean per region and nationally.

## Results (provisional)

| Region | Indicator | n |
|---|---|---|
| Nord-Norge | 0.814 | 251 |
| Midt-Norge | 0.839 | 481 |
| Vestlandet | 0.826 | 73 |
| Østlandet | 0.853 | 168 |
| Sørlandet | 0.822 | 10 |
| **Norge** | **0.835** | 983 |

## Folder structure

| Folder | Contents |
|---|---|
| `R/` | The indicator: `fetch_nin_data.R`, `fetch_modis_ndvi.R`, `NO_NDVI_001_trend_scaling.R` (scaling, aggregation, map), `export_deliverables.R`, `make_report_map.R`, `NO_NDVI_001_MASTER_PIPELINE.R` (runs the stages in order), and `NO_NDVI_001_wetland_pipeline.R`, the original's exploratory analysis translated to R (not part of the indicator). |
| `experimental/` | Sentinel-2 fetch via Copernicus openEO. Works on test areas; no national run. See its README. |
| `data/NDVI_MODIS/` | The national MODIS NDVI series, gzipped (33 MB). |
| `data/spatial/` | Region polygons and the outline of Norway. |
| `outputs/results/` | Polygon and regional tables, the scaling anchors, maps. |
| `outputs/deliverables/` | The indicator in the ecosystemCondition platform format. |
| `docs/` | Workflow diagram. |

## How to run it

From the committed MODIS series (about 2 minutes):

1. `R/fetch_nin_data.R` — the national NiN nature-type dataset.
2. `R/NO_NDVI_001_trend_scaling.R` — trends, scaling, regional table, map.
3. `R/export_deliverables.R` — the delivery files.
4. `R/make_report_map.R` — the report map.

To refetch MODIS (hours; the tile cache is about 100 GB), create a free
NASA Earthdata account, put the token in `.Renviron` as
`EARTHDATA_TOKEN=...`, and run `R/fetch_modis_ndvi.R`. Its plain `.csv`
output takes precedence over the committed `.csv.gz`.

## Status and limitations

- **MODIS only.** At 250 m, only 983 of the national wetland polygons are
  large enough to score; Sørlandet has 10. Sentinel-2 (10 m) would raise
  this substantially and is in `experimental/`; Landsat is not started.
- **No uncertainty.** `sd` is empty in the delivery files.
- **The 2026 season is partial** (fetched to July), and it enters the
  trends as a full year.
- **The scaling is our adaptation**, not a published wetland method. The
  threshold rests on the assumption that a stable wetland shows no trend
  in peak NDVI.

## Attribution

- The original indicator, its exploratory analysis and the Google Earth
  Engine scripts that extracted MODIS, Sentinel-2 and Landsat NDVI are
  NINA's (ecosystemCondition, chapter 15). The Earth Engine scripts are
  not included here: they depend on private Earth Engine assets. This
  reconstruction replaces them with direct downloads.
- Didan, K. (2021). *MODIS/Terra Vegetation Indices 16-Day L3 Global 250m
  SIN Grid V061* [Data set]. NASA EOSDIS Land Processes Distributed Active
  Archive Center. https://doi.org/10.5067/MODIS/MOD13Q1.061
- Framstad, E., Eide, N. E., Eide, W., Klanderud, K., Kolstad, A.,
  Töpper, J., & Vandvik, V. (2022). *Vurdering av økologisk tilstand for
  fjell i Norge i 2021* (NINA Rapport 2050). Norsk institutt for
  naturforskning.
- NiN nature-type data: Miljødirektoratet, downloaded 2026-08-05.

## R environment

`renv.lock` pins the packages; restore with `renv::restore()`.
