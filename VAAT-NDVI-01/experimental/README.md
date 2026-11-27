# Eksperimentelt: NDVI fra Sentinel-2

Ikke en del av den leverte indikatoren. Skriptene henter NDVI fra
Sentinel-2 for NiN-våtmarkspolygonene gjennom openEO-tjenesten i
Copernicus Data Space Ecosystem (CDSE), uten Google Earth Engine. De
virker på små testområder, men ingen nasjonal henting er fullført:
CDSE-jobbene reduserte en hel vekstsesong i én jobb, som feilet gjentatte
ganger og brukte opp prosesseringskreditter.

NINAs original hentet NDVI som sonalt gjennomsnitt per bilde og reduserte
tidsserien etterpå i R, aldri i én reduksjon på serveren. En ny versjon
bør følge det mønsteret.

| Fil | Innhold |
|---|---|
| `fetch_sentinel2_ndvi.R` | NDVI-tidsserie per polygon via openEO (`aggregate_spatial`). |
| `fetch_sentinel2_ndvi_raster.R` | Variant som laster ned NDVI-raster per periode og trekker ut verdiene lokalt. |
| `manual_test_*.json` | openEO-prosessgrafer brukt til å teste jobber manuelt i CDSEs webredigerer. |

Innloggingen er CDSEs «device code»-flyt, så noen må godkjenne den i
nettleseren mens skriptet venter. `R/VAAT-NDVI-01_MASTER_PIPELINE.R` kaller
`fetch_sentinel2_ndvi.R` som valgfritt steg 2 og fortsetter uten.
Når `data/NDVI_Sentinel/ndvi_national_clean.csv` finnes, tar
`R/VAAT-NDVI-01_trend_scaling.R` den med automatisk.
