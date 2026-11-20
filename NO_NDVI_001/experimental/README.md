# Experimental: Sentinel-2 NDVI

Not part of the delivered indicator. These scripts fetch Sentinel-2 NDVI
for the NiN wetland polygons through the Copernicus Data Space Ecosystem
(CDSE) openEO service, without Google Earth Engine. They work on small
test areas, but no national fetch has completed: CDSE's batch jobs
reduced a whole growing season in one job, which failed repeatedly and
used up processing credits.

NINA's original extracted NDVI per image as a zonal mean and reduced the
time series afterwards in R, never in one server-side reduction. A
rework should follow that pattern.

| File | Contents |
|---|---|
| `fetch_sentinel2_ndvi.R` | Per-polygon NDVI time series via openEO (`aggregate_spatial`). |
| `fetch_sentinel2_ndvi_raster.R` | Variant that downloads NDVI rasters per period and extracts locally. |
| `manual_test_*.json` | openEO process graphs used to test jobs by hand in the CDSE web editor. |

Login is CDSE's device-code flow, so a person has to approve it in a
browser while the script waits. `R/NO_NDVI_001_MASTER_PIPELINE.R` calls
`fetch_sentinel2_ndvi.R` as its optional stage 2 and continues without it.
Once `data/NDVI_Sentinel/ndvi_national_clean.csv` exists,
`R/NO_NDVI_001_trend_scaling.R` includes it automatically.
