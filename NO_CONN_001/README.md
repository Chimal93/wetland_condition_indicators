# NO_CONN_001 – Strukturell konnektivitet i våtmark-2026

- **Norsk tittel**: Strukturell konnektivitet i våtmark
- **Prosjekteier**: Miljødirektoratet
- **Oppdragstaker**: Sállir Natur AS
- **Leveringsdato**: 30.11.2026
- **Del av**: [Indikatorutvikling for våtmark-2026](../README.md)

Måler hvor nær infrastruktur ligger hver myr, sammenlignet med hvor nær
nærmeste andre myr ligger.

- **English**: Structural connectivity of wetlands: for each mire patch,
  the distance to the nearest infrastructure divided by the distance to
  the nearest other mire, scaled to 0–1 and aggregated by region.
- **Norwegian**: Strukturell konnektivitet i våtmark: for hver myr,
  avstanden til nærmeste infrastruktur delt på avstanden til nærmeste
  andre myr, skalert til 0–1 og aggregert per region.

## 1. Bidragsytere / Kontakt

Se [hoved-README](../README.md#1-bidragsytere--kontakt).

## 2. Formål / Bakgrunn

Rekonstruksjon av NINAs konnektivitetsindikator for våtmark. På ecRxiv
heter originalen nå NO_CONN_003; NO_CONN_001 er der en skogindikator.
Originalen er skrevet i Google Earth Engine (JavaScript), og NINAs egen
metadata merker den som ufullstendig («Working pipeline, but not
operationalised», versjon 0.002). Dette er derfor en ny implementasjon
etter originalens oppskrift, ikke en overføring av et ferdig produkt.

**Metode.**

1. **Infrastruktur.** En indeks for arealbruksintensitet (LUI; Erikstad
   et al., 2023) bygges fra N50 Kartdata 2006, 2013 og 2023 og NVEs
   regulerte innsjøer. Som i originalen regnes celler med indeks over 2 som
   infrastruktur.
2. **Våtmark.** Myrpolygoner slås sammen til sammenhengende flater og
   forenkles (toleranse 2 m, arealet bevares eksakt), slik at et eksakt
   nærmeste-nabo-søk blant om lag én million polygoner er gjennomførbart.
3. **Kvotient.** For hver myr: avstand til nærmeste infrastruktur delt på
   avstand til nærmeste andre myr, innenfor 1000 m. Høyere kvotient betyr
   at infrastrukturen ligger relativt langt unna, altså bedre tilstand.
4. **Skalering.** Lineær på logaritmen til kvotienten mellom 1- og
   99-persentilen i kjøringens egen fordeling. To faste ankere: ingen
   infrastruktur innen 1000 m gir 1, infrastruktur som berører myra gir 0.
   Originalen fastsatte aldri en skalering (NINA-sak #144); denne er vår.
5. **Aggregering.** Arealvektet gjennomsnitt av indikatorverdien per
   region og nasjonalt, med bootstrap-standardavvik.

**To varianter.** Metode, infrastrukturdata og kode er like; bare
våtmarkspopulasjonen er forskjellig.

| | AR5-variant (**levert**) | Myrmodell-variant (**ikke anbefalt**) |
|---|---|---|
| Våtmark fra | AR5 myr, sammenslått til flater; AR50 brukes automatisk uten AR5-tilgang | Nasjonalt sannsynlighetskart for myr («Våtmark basert på NiN»), NiN der kartet mangler |
| Dekning | Hele landet | **Slutter ved ca. 64° N**; Nord-Norge får bare NiN-polygoner |
| Skårede polygoner | 722 567 | 1 151 903 |
| Polygoner i Nord-Norge | 127 464 | 4 917 |
| Mappe | `outputs/deliverables/` | `outputs/deliverables_MireModel/` |

Myrmodell-varianten anbefales ikke fordi verdien for Nord-Norge da
beskriver en annen populasjon enn de fire andre regionene: 4 917 spredte
polygoner, uforholdsmessig mange langs veier, mot 200 000–450 000 i de
andre. Den er beholdt fordi den ligger nærmest originalens populasjon.
Variantene er ikke på samme skala, fordi skaleringsankrene er persentiler
av hver kjørings egen fordeling. `R/compare_ar5_vs_model_anchors.R` viser
at ankerforskjellen er liten (−0,017 til −0,034 per region), mens
populasjonsforskjellen dominerer (+0,233 i Nord-Norge, −0,03 til −0,10 ellers).
Detaljer: `data/connectivity_scored/README_variants.md`.

**Resultater, AR5-variant:**

| Region | Indikator | n |
|---|---|---|
| Nord-Norge | 0,855 | 127 464 |
| Midt-Norge | 0,911 | 186 159 |
| Vestlandet | 0,825 | 78 023 |
| Østlandet | 0,917 | 203 211 |
| Sørlandet | 0,908 | 125 603 |
| **Norge** | **0,898** | 720 460 |

Av de 722 567 myrflatene har 720 226 indikatorverdi; 2 341 er utelatt som
topologieffekter (se kjente begrensninger). n i tabellen summerer til
720 460, fordi 234 flater som krysser en regiongrense telles i begge
regionene, se kjente begrensninger.

**Referanser**

- Erikstad, L., Simensen, T., Bakkestuen, V., & Halvorsen, R. (2023).
  Index measuring land use intensity—A gradient-based approach.
  *Geomatics, 3*(1), 188–204. https://doi.org/10.3390/geomatics3010010
- NINAs original: [NINAnor/ecRxiv, NO_CONN_003](https://github.com/NINAnor/ecRxiv).
- Aggregeringen følger rammeverket for aggregeringsveier i et upublisert
  NINA-manus (Kolstad m.fl.). Manuset er ikke lagt ved.

## 3. Forutsetninger / Dependencies

Maskinvare, programvare, KI-verktøy og R-versjon: se
[hoved-README](../README.md#3-forutsetninger--dependencies).

- **R-pakker:** låst i [`renv.lock`](renv.lock). Viktigst: `sf`, `terra`,
  `dplyr`, `ggplot2`, `RANN`. Alle fra CRAN.
- **QGIS 3.44.12:** bare for steg 2 (N50 2006 finnes bare i SOSI-format,
  som GDAL-versjonen i `sf` ikke leser, men QGIS sin gjør). Kalles
  automatisk med `system2()`. Stien står i
  `R/convert_n50_2006_sosi_to_gpkg.R` (`qgis_root`). Trengs bare hvis
  infrastrukturindeksen bygges på nytt.
- **Windows og PowerShell:** myrmodellen (ca. 8 GB) pakkes ut med .NET
  `ZipFile`, fordi R sin `unzip()` ikke håndterer ZIP64 i denne størrelsen.
  AR5-varianten kjøres med `src/run_connectivity_ar5.ps1`.
- **Ytelse:** med mellomlageret lastet ned tar beregningen noen minutter.
  Full nyberegning av AR5-varianten tok 24,8 timer (Midt-Norge 10,0 t og
  Østlandet 9,7 t for avstandsberegningen; klargjøring 48 min).
- **Disk:** rådata for infrastruktur ca. 29 GB og myrmodellen ca. 8 GB, bare
  ved full nyberegning.

## 4. Struktur

| Mappe | Innhold |
|---|---|
| `R/` | All R-kode: hovedskriptet `NO_CONN_001_wetland_pipeline.R` (ni steg, hopper over ferdige steg), skriptene det kaller, eksport og kart. |
| `src/` | `run_connectivity_ar5.ps1`, som kjører AR5-varianten region for region. |
| `data/spatial/` | Regioner og kystlinje. |
| `data/LUI_output/`, `data/wetland_map_simplified/`, `data/connectivity_output_simplified/` | Mellomlager (ca. 2 GB), hentes med `R/download_caches.R`. |
| `data/connectivity_scored/` | Hver myr med indikatorverdi (gitignored, lages på nytt på minutter). |
| `data/wetland_map_ar5/`, `data/connectivity_output_ar5/` | Mellomresultater for AR5-varianten (gitignored på grunn av AR5-lisensen). |
| `docs/` | Tom foreløpig. |
| `outputs/results/` | Kart og kontrollberegningen av gjennomsnittlig avstandsforhold. |
| `outputs/deliverables/` | AR5-varianten i plattformformatet. |
| `outputs/deliverables_MireModel/` | Myrmodell-varianten i plattformformatet. |

## 5. Input / Output

### Input

| Datasett | Kilde og versjon | Lastet ned | Hentes med |
|---|---|---|---|
| N50 Kartdata, historiske data 2023 og 2013 | Kartverket via Geonorge, FGDB | 2026-08-06 | `R/fetch_n50_infrastructure_data.R` |
| N50 Kartdata, historiske data 2006 | Kartverket via Geonorge, SOSI | 2026-08-06 | `R/fetch_n50_infrastructure_data.R` + QGIS |
| Regulerte innsjøer | NVE, Vannkraft, via Geonorge (FGDB) | 2026-08-06 | `R/fetch_n50_infrastructure_data.R` |
| AR5 myr | NIBIO, FKB-AR5 (krever tilgang via Norge digitalt) | 2026-07-28 | Fra `NO_GJEN_001/R/extract_ar5_skog_myr.R` |
| AR50 myr (åpen reserveløsning) | NIBIO, AR50 | 2026-07-21 | Fra `NO_GJEN_001/R/build_ar50_wetland_lidar_coverage.R` |
| Myrmodell (MyrMod2Rv) | «Våtmark basert på NiN», GeoTIFF via Geonorge, fil datert 2023-06-19 | 2026-08-07 | `R/fetch_wetland_map.R` |
| NiN-naturtyper | Miljødirektoratet, FILEGDB, EPSG:4326 | 2026-08-27 | `R/fetch_nin_data.R` |
| Regioner og kystlinje | NINAnor/ecosystemCondition | 2026-07-20 | Ligger i repoet |

AR5-varianten finner myrlaget i denne rekkefølgen: miljøvariabelen
`$AR5_MYR_GPKG`, mappen `data/wetland_population/`, og til slutt
`NO_GJEN_001/data/OpenS_data/`, der `NO_GJEN_001` allerede bygger det.
Finnes ingen av dem, stopper skriptet med instruksjoner.

**Lisens.** AR5 er bare tilgjengelig for parter i Norge digitalt. Derfor
publiseres ingen geometri avledet av AR5 for denne indikatoren: verken
myrflatene, mellomresultatene eller polygonkartet. Det som ligger i repoet
for AR5-varianten, er regionkartet, verditabellene og metadata.
`R/export_deliverables.R` lager polygonkartet lokalt for den som har
tilgang. AR50 er åpne data (NLOD); `R/prepare_ar5_mire_regions.R` bruker
AR50 automatisk uten AR5 og skriver kilden i kolonnen `source`.

**Mellomlager.** Avledede data som tar over 20 timer å beregne (ca. 2 GB),
er publisert som Release-filer på GitHub (tag `conn001-caches-v1`) og hentes
med `R/download_caches.R`. Repoet de hentes fra, settes med miljøvariabelen
`CONN001_REPO` (standard `Chimal93/wetland_condition_indicators`). Med
mellomlageret på plass skriver nesten alle steg «SKIPPING (reading
published cache, not recomputing)», altså beregnes de ikke på nytt. For å
beregne et steg på nytt sletter man filene steget lager; overskriften i
hovedskriptet sier hvilke filer som styrer hvilket steg.

### Output

I `outputs/deliverables/` (AR5-varianten):

- `NO_CONN_001_indicatorMap_region.rds` – landsdeler.
- `NO_CONN_001_values.csv` / `.xlsx` – verditabell med nasjonal verdi,
  tilleggskolonner og metadata (variant, populasjon og dekning).
- `NO_CONN_001_map.png`.
- `NO_CONN_001_indicatorMap_polygon.rds` lages lokalt, men ligger ikke i
  repoet (AR5-lisens).

`outputs/deliverables_MireModel/` har de samme filene for myrmodell-varianten.
Polygonkartet for den er bare gitignored på grunn av størrelsen, og kan
deles.

Kolonner:

- `v` = kvotienten. Region og nasjonalt er arealvektet **geometrisk**
  gjennomsnitt over polygoner med endelig kvotient større enn null. De to
  faste ankerne inngår i `i`, men har ingen `v`.
- `reference_high` / `reference_low` = 99- og 1-persentilen av kvotienten
  i kjøringen: 1487,7 / 0,156 for AR5-varianten, 177,7 / 0,141 for
  myrmodell-varianten.
- `thr` = 0,6 (plattformens standard).
- `sd` = bootstrap-standardavvik for det arealvektede gjennomsnittet;
  95 %-intervallet ligger i `boot_low` / `boot_high`.
- Årstall `2023` = årgangen for N50.

## 6. Installasjon / Kjøring

Sett opp R-miljøet som beskrevet i [hoved-README](../README.md#6-installasjon--kjøring).

**AR5-varianten (den leverte):**

1. `R/download_caches.R` – henter mellomlageret.
2. Bygg myrlaget i `NO_GJEN_001` (AR5 eller AR50, se tabellen over).
3. `R/NO_CONN_001_wetland_pipeline.R` – trengs for stegene 1–6
   (infrastrukturen). Med mellomlageret tar det noen minutter.
4. Fra indikatormappen:
   `powershell -ExecutionPolicy Bypass -File .\src\run_connectivity_ar5.ps1`
   (klargjøring, avstander og skalering per region; kan avbrytes og
   startes på nytt). Sett `$env:RSCRIPT` hvis R ikke ligger på
   standardstien.
5. `R/export_deliverables.R` med `CONNECTIVITY_SCORE_LABEL=national_2023_AR5`.
6. `R/make_report_map.R` – rapportkartet.

**Myrmodell-varianten:** steg 1 og 3 gir denne varianten, fordi det er
standardinnstillingene. Eksporter med
`CONNECTIVITY_SCORE_LABEL=national_2023` og
`CONN001_OUT_DIR=../outputs/deliverables_MireModel`.

Hovedskriptets ni steg: (1) hent N50 og NVE, (2) konverter N50 2006 fra
SOSI [QGIS], (3) trekk ut og harmoniser infrastrukturlag, (4) beregn
LUI-indeksen, (5) hent myrmodellen, (6) hent NiN, (7) forenkling,
avstand til nærmeste myr og avstand til infrastruktur for hver av de fem
regionene, (8) skalering, regionkart og bootstrap, (9) kontrollberegning
av gjennomsnittlig avstandsforhold.

**Rask test.** `LUI_TEST_AOI=oslo` kjører LUI-indeksen for en
10 × 10 km-boks. For å teste den virkelige beregningen per region kan man
slette de tre mellomlagrede filene for Nord-Norge og kjøre hovedskriptet;
regionen tar sekunder i myrmodell-varianten.

**Kontroll.**

- Kjøring fra mellomlageret gir identiske leveransefiler, og
  `mire_scored_national_2023.gpkg` er identisk i attributter og geometri.
- Nord-Norge er beregnet helt på nytt med de andre regionene fra
  mellomlageret. Resultatet var identisk (indeks 0,6477198, 4 939
  polygoner), og den nasjonale verdien uendret.

**Kjente begrensninger**

- **Skaleringen er vår egen.** Originalen markerer skalering og
  aggregering som uferdig (NINA-sak #144).
- **Kategorien «annet bebygd areal» i LUI har ingen sikker N50-objekttype**
  (uklar også i Erikstad et al. sin tabell 1). Den er ikke tatt med, noe
  som gir en liten, systematisk underteling av infrastruktur.
- **Myrflatene er generalisert** (toleranse 2 m, arealet bevart). På et
  utvalg på 20 × 20 km gikk AR5 fra 97 910 til 31 891 punkter. Ved et
  søk på 1000 m betyr det lite for resultatet, men polygonkartet er ikke
  en nøyaktig kopi av AR5. Myrmodell-varianten er generalisert hardere
  (61–66 % færre punkter).
- **Uendelige kvotienter fra myrer som berører hverandre** er utelatt (en
  topologieffekt, ikke et økologisk signal): 2 341 av 722 567 i
  AR5-varianten og 13 803 av 1 165 125 i myrmodell-varianten.
- **Myrflater som krysser en regiongrense telles i begge regionene.**
  Regiontilordningen skjer ved overlapp, som i beregningsskriptet. Det
  gjelder 234 av 720 226 flater (0,03 %), og de telles også to ganger i
  den nasjonale verdien. Effekten på verdiene er ubetydelig, men n er
  derfor litt høyere enn antall flater.
- **Originalens tekst og kode er ikke enige** om hvordan den skalerte
  verdien skal regnes. Koden regner bare kvotienten, som her. Den andre
  lesningen (aggregere først, så dele) regnes bare som kontroll i steg 9
  (`R/national_mean-distance_ratio.R`) og inngår ikke i indikatoren.

## 7. Lisens / Rettigheter

Se [**LICENSE**-filen](LICENSE.md). AR5 og geometri avledet av AR5 deles
ikke. Nedlastede data er underlagt lisensene til kildene.
