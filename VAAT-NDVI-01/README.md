# VAAT-NDVI-01 – Primærproduksjon i våtmark (NDVI-trend)-2026

- **Norsk tittel**: Primærproduksjon i våtmark (NDVI-trend)
- **Prosjekteier**: Miljødirektoratet
- **Oppdragstaker**: Sállir Natur AS
- **Leveringsdato**: 30.11.2026
- **Del av**: [Indikatorutvikling for våtmark-2026](../README.md)

> **Status: foreløpig, ikke ferdig.** Bare MODIS, 983 skårede polygoner,
> uten usikkerhetsestimat. Levert slik at metoden og leveransefilene kan
> vurderes. Se kjente begrensninger i del 6.

Måler endring i primærproduksjon i våtmark som trenden i NDVI (et mål på
grønnhet fra satellitt) per myrpolygon, skalert mot ingen trend.

- **English**: Primary production in wetlands: the trend in peak
  growing-season NDVI (MODIS, 2000–2026) per NiN wetland polygon, scaled
  against no trend. Provisional.
- **Norwegian**: Primærproduksjon i våtmark: trenden i høyeste NDVI i
  vekstsesongen (MODIS, 2000–2026) per NiN-våtmarkspolygon, skalert mot
  ingen trend. Foreløpig.

## 1. Bidragsytere / Kontakt

Se [hoved-README](../README.md#1-bidragsytere--kontakt).

## 2. Formål / Bakgrunn

Rekonstruksjon av NDVI-indikatoren for våtmark beskrevet i NINAs
[ecosystemCondition, kapittel 15](https://ninanor.github.io/ecosystemCondition/NDVI-indicator-wetland.html).
Det arbeidet var utforskende og fastsatte aldri en skalering: NDVI
overlapper for mye mellom tilstandsklasser til at det går an å sette
referanseverdier for selve NDVI-nivået. Her skaleres derfor **trenden** i
NDVI i stedet for nivået, etter metoden NINA brukte for NDVI i fjell
(Framstad et al., 2022).

**Metode.**

1. **NDVI per polygon.** MODIS MOD13Q1 v6.1 (250 m, 16-dagers
   sammenstillinger), slutten av mai til september 2000–2026. Verdien
   leses i pikselen ved polygonets midtpunkt (sentroide), hentet direkte
   fra NASA Earthdata (`R/fetch_modis_ndvi.R`). Kvalitetslaget i MODIS
   brukes ikke. Originalen brukte sonalt gjennomsnitt i Google Earth
   Engine.
2. **Høyeste verdi per år.** Den høyeste sammenstillingen per polygon og
   vekstsesong.
3. **Trend.** Helningen (minste kvadraters metode) av høyeste NDVI mot år,
   per polygon. Polygonet må dekke minst én MODIS-piksel (≥ 62 500 m²) og
   ha minst 10 vekstsesonger.
4. **Referanse og ankere.** Referansetilstanden er ingen trend (helning 0).
   Terskel og nedre anker kommer fra en permutasjonsfordeling: årstallene
   i hvert polygon stokkes, og helningen beregnes på nytt. 97,5-persentilen
   av |helning| (0,00214 NDVI/år) gir 0,6, og største |helning|
   (0,0107 NDVI/år) gir 0.
5. **Skalering.** Stykkevis lineær på |helning|, tosidig: både økende og
   avtagende grønnhet regnes som avvik.
6. **Aggregering.** Arealvektet gjennomsnitt per region og nasjonalt.

**Resultater (foreløpige):**

| Region | Indikator | n |
|---|---|---|
| Nord-Norge | 0,814 | 251 |
| Midt-Norge | 0,839 | 481 |
| Vestlandet | 0,826 | 73 |
| Østlandet | 0,853 | 168 |
| Sørlandet | 0,822 | 10 |
| **Norge** | **0,835** | 983 |

**Referanser**

- Didan, K. (2021). *MODIS/Terra vegetation indices 16-day L3 global 250m
  SIN grid V061* [Datasett]. NASA EOSDIS Land Processes Distributed Active
  Archive Center. https://doi.org/10.5067/MODIS/MOD13Q1.061
- Framstad, E., Eide, N. E., Eide, W., Klanderud, K., Kolstad, A.,
  Töpper, J., & Vandvik, V. (2022). *Vurdering av økologisk tilstand for
  fjell i Norge i 2021* (NINA Rapport 2050). Norsk institutt for
  naturforskning.
- Originalindikatoren, den utforskende analysen og Google Earth
  Engine-skriptene som hentet NDVI fra MODIS, Sentinel-2 og Landsat, er
  NINAs (ecosystemCondition, kapittel 15). Earth Engine-skriptene er ikke
  lagt ved, fordi de bruker private Earth Engine-ressurser. Her er de
  erstattet med direkte nedlasting.

## 3. Forutsetninger / Dependencies

Maskinvare, programvare, KI-verktøy og R-versjon: se
[hoved-README](../README.md#3-forutsetninger--dependencies).

- **R-pakker:** låst i [`renv.lock`](renv.lock). Viktigst: `sf`, `terra`,
  `dplyr`, `ggplot2`, `ggrepel`.
- **NASA Earthdata-konto** (gratis), bare for å hente MODIS på nytt.
  Tokenet legges i `.Renviron` som `EARTHDATA_TOKEN=...`.
- **Ytelse:** fra MODIS-serien som ligger i repoet tar beregningen ca.
  2 minutter. Ny nedlasting av MODIS tar flere timer, og flismellomlageret
  bruker ca. 100 GB.

## 4. Struktur

| Mappe | Innhold |
|---|---|
| `R/` | Indikatoren: `fetch_nin_data.R`, `fetch_modis_ndvi.R`, `VAAT-NDVI-01_trend_scaling.R` (skalering, aggregering, kart), `export_deliverables.R`, `make_report_map.R` og `VAAT-NDVI-01_MASTER_PIPELINE.R` (kjører stegene i rekkefølge). `VAAT-NDVI-01_wetland_pipeline.R` er originalens utforskende analyse oversatt til R; den er ikke en del av indikatoren. |
| `experimental/` | Henting av Sentinel-2 via Copernicus openEO. Virker på testområder, men ingen nasjonal kjøring er fullført. Se egen README. |
| `data/NDVI_MODIS/` | Den nasjonale MODIS-serien, gzip-komprimert (33 MB). |
| `data/spatial/` | Regioner og kystlinje. |
| `docs/` | Flytdiagram for arbeidsflyten. Indikatordokument på engelsk etter NINAs ecRxiv-mal: `VAAT-NDVI-01.qmd` (kilde) og `VAAT-NDVI-01.html`. Lages på nytt med `quarto render docs/VAAT-NDVI-01.qmd`. Koden vises, men kjøres ikke; resultatene leses fra `outputs/`. |
| `outputs/results/` | Tabeller per polygon og region, skaleringsankrene og kart. |
| `outputs/deliverables/` | Indikatoren i plattformformatet. |

## 5. Input / Output

### Input

| Datasett | Kilde og versjon | Lastet ned | Hentes med |
|---|---|---|---|
| NDVI, MODIS MOD13Q1 v6.1 | NASA LP DAAC (Didan, 2021), slutten av mai til september 2000–2026 | 2026-08-28 | `R/fetch_modis_ndvi.R`; resultatet ligger i repoet |
| NiN-naturtyper | Miljødirektoratet, FILEGDB, EPSG:4326 | 2026-08-05 | `R/fetch_nin_data.R` |
| Regioner og kystlinje | NINAnor/ecosystemCondition | 2026-06-23 | Ligger i repoet |

MODIS-dataene har ingen begrensninger på bruk eller videreformidling;
NASA ber om at de siteres. Serien ligger i repoet som
`data/NDVI_MODIS/modis_ndvi_ts_national.csv.gz` (ukomprimert 169 MB, over
GitHubs grense på 100 MB). Skriptene leser `.gz`-filen direkte. En ny
nedlasting skriver en ukomprimert `.csv`, som da brukes i stedet.

### Output

I `outputs/deliverables/`:

- `VAAT-NDVI-01_indicatorMap_region.rds` – landsdeler (primær).
- `VAAT-NDVI-01_indicatorMap_polygon.rds` – hvert skåret
  NiN-våtmarkspolygon (NiN er åpne data).
- `VAAT-NDVI-01_values.csv` / `.xlsx` – verditabell med nasjonal verdi,
  tilleggskolonner og metadata.
- `VAAT-NDVI-01_map.png`.

Kolonner:

- `v` = helning i NDVI per år. Region og nasjonalt er arealvektet
  gjennomsnitt.
- `i` = indikatorverdi.
- `reference_high` = 0 (ingen trend).
- `reference_low` = 0,0107, største |helning| i permutasjonsfordelingen.
- `thr` = 0,6, som tilsvarer |helning| 0,00214 (kolonnen `slope_threshold`).
- `sd` = tom; usikkerhet er ikke beregnet.
- Årstall `2026` = siste år i trendperioden 2000–2026.

Tilleggskolonner: `n`, `mean_abs_slope` (arealvektet gjennomsnitt av
|helning|) og `i_sd_polygons`.

## 6. Installasjon / Kjøring

Sett opp R-miljøet som beskrevet i [hoved-README](../README.md#6-installasjon--kjøring).

**Fra MODIS-serien i repoet (ca. 2 minutter):**

1. `R/fetch_nin_data.R`
2. `R/VAAT-NDVI-01_trend_scaling.R` – trender, skalering, regiontabell, kart.
3. `R/export_deliverables.R` – leveransefilene.
4. `R/make_report_map.R` – rapportkartet.

**Ny nedlasting av MODIS (flere timer):** opprett en gratis konto hos NASA
Earthdata, legg tokenet i `.Renviron` som `EARTHDATA_TOKEN=...`, og kjør
`R/fetch_modis_ndvi.R`.

`R/VAAT-NDVI-01_MASTER_PIPELINE.R` kjører alt i rekkefølge og hopper over
steg som er ferdige. Steg 2 (Sentinel-2) krever at noen godkjenner
innloggingen i nettleseren; uten det fortsetter skriptet uten Sentinel-2.

**Kontroll.** Kjøringen i denne mappestrukturen, fra den komprimerte
MODIS-serien, gir tabellene per polygon og region og rapportkartet byte
for byte likt den opprinnelige kjøringen.

**Kjente begrensninger**

- **Bare MODIS.** Med 250 m oppløsning er bare 983 av de nasjonale
  våtmarkspolygonene store nok til å skåres, og Sørlandet har bare 10.
  Sentinel-2 (10 m) ville gitt langt flere og ligger i `experimental/`.
  Landsat er ikke påbegynt.
- **Én piksel per polygon.** NDVI leses ved polygonets sentroide, ikke
  som gjennomsnitt over polygonet, og kvalitetslaget i MODIS brukes ikke.
- **Ingen usikkerhet.** `sd` er tom i leveransefilene.
- **Vekstsesongen 2026 er ufullstendig** (hentet til juli), men inngår i
  trendene som et helt år.
- **Skaleringen er vår tilpasning**, ikke en publisert metode for våtmark.
  Terskelen bygger på antagelsen om at en stabil våtmark ikke har noen
  trend i høyeste NDVI.

## 7. Lisens / Rettigheter

Se [**LICENSE**-filen](LICENSE.md). Nedlastede data er underlagt
lisensene til kildene.
