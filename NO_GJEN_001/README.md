# NO_GJEN_001 – Gjengroing i våtmark-2026

- **Norsk tittel**: Gjengroing i våtmark (laserdata)
- **Prosjekteier**: Miljødirektoratet
- **Oppdragstaker**: Sállir Natur AS
- **Leveringsdato**: 30.11.2026
- **Del av**: [Indikatorutvikling for våtmark-2026](../README.md)

Måler gjengroing i våtmark som vegetasjonshøyde fra laserdata (LiDAR),
skalert mellom høyden i våtmark i god tilstand og høyden i skog.

- **English**: Woody encroachment in wetlands: vegetation height from
  national LiDAR in a sample of wetland, scaled between a good-condition
  wetland reference and a forest reference.
- **Norwegian**: Gjengroing i våtmark: vegetasjonshøyde fra nasjonale
  laserdata i et utvalg av våtmark, skalert mellom en referanse for
  våtmark i god tilstand og en referanse for skog.

## 1. Bidragsytere / Kontakt

Se [hoved-README](../README.md#1-bidragsytere--kontakt).

## 2. Formål / Bakgrunn

Rekonstruksjon av NINAs indikator NO_GJEN_001 på åpne data. Originalen
hentet høydedata gjennom Google Earth Engine; her leses Kartverkets
høydemodeller direkte.

**Metode.**

1. **Vegetasjonshøyde.** Kartverkets overflatemodell (DOM1) minus
   terrengmodell (DTM1) gir en kronehøydemodell med 1 m oppløsning.
2. **Populasjon.** Et stratifisert utvalg av punkter i AR5 myr, inntil
   1000 per stratum (region × bioklimatisk sone, seed 123), som i
   originalens Earth Engine-skript. Rundt hvert punkt tas medianen av
   kronehøyden i en 20 × 20 m-celle, som i originalens arbeidsflyt.
3. **Referanse for god tilstand (X100).** Kronehøyden evaluert på 30 m
   inne i hvert NiN-våtmarkspolygon kartlagt i god tilstand, median per
   polygon, deretter median per region og bioklimatisk sone. Skalaen er en
   del av definisjonen: på 1 m er en åpen myr noen få centimeter nesten
   overalt, mens en 30 m-celle (900 m²) tar med spredte trær og, for små
   polygoner, skogkanten. De samme polygonene gir 5–20 ganger høyere verdi
   på 30 m.
4. **Referanse for skog (X0).** 90-persentilen av kronehøyden i
   20 m-celler i AR5 skog, per region og bioklimatisk sone. Punkter i skog
   som er hogd eller forstyrret i 1986–2020, tas ut med kartet over
   skogforstyrrelser. I alle utvalg tas punkter som faller på en bygning
   (OpenStreetMap) ut.
5. **Skalering.** Sigmoid-funksjon mellom X0 og X100, snudd slik at lav
   vegetasjon gir høy verdi (1 = referansetilstand, 0 = skog).
6. **Aggregering.** Arealvektet gjennomsnitt per region, per SSB 50 km-rute
   og nasjonalt. Usikkerheten er bootstrap-standardfeil (`ecTools::ea_spread`,
   1000 trekninger, fast seed).

**Resultater (n = 20 999 utvalgsceller):**

| Region | Indikator |
|---|---|
| Nord-Norge | 0,977 |
| Midt-Norge | 0,960 |
| Vestlandet | 0,959 |
| Sørlandet | 0,950 |
| Østlandet | 0,908 |
| **Norge** | **0,949** |

**Referanser**

- Moen, A. (1998). *Nasjonalatlas for Norge: Vegetasjon*. Statens
  kartverk.
- Senf, C., & Seidl, R. (2021). Mapping the forest disturbance regimes of
  Europe. *Nature Sustainability, 4*, 63–70.
  https://doi.org/10.1038/s41893-020-00609-y
- NINAs original: [NINAnor/ecRxiv, NO_GJEN_001](https://github.com/NINAnor/ecRxiv).

## 3. Forutsetninger / Dependencies

Maskinvare, programvare, KI-verktøy og R-versjon: se
[hoved-README](../README.md#3-forutsetninger--dependencies).

- **R-pakker:** låst i [`renv.lock`](renv.lock). Viktigst: `sf`, `terra`,
  `dplyr`, `ggplot2` og `ecTools`. `ecTools` installeres fra GitHub som
  `NINAnor/eaTools`, låst til commit `e9480b4`, fordi nyere versjoner har
  gitt funksjonen pipelinen bruker nytt navn. `renv.lock` tar seg av dette.
- **Nettverk:** høydemodellene leses over nett fra Kartverket under
  kjøringen. Stabil forbindelse trengs.
- **Ytelse:** første kjøring fra tomt mellomlager tar over 2 timer, hvorav
  ca. 40 minutter er referansen for god tilstand
  (`R/build_refvaatmark_30m.R`, 8 200 polygoner). Tidene skriptene selv
  skriver ut, er lavere enn den reelle tiden, fordi de ikke tar med
  oppstart og nedlasting. Senere kjøringer av beregningen tar under ett
  minutt.

## 4. Struktur

| Mappe | Innhold |
|---|---|
| `R/` | All kode: nedlasting og bygging av inndata, beregningen (`NO_GJEN_001_wetland_pipeline_OpenSource.R`), eksport og kart. |
| `data/OpenS_data/` | Inndata og mellomlager. Store filer er gitignored og lages av skriptene i `R/`. |
| `docs/` | Tom foreløpig. |
| `outputs/results/` | Kart, tabeller og shapefiler fra beregningen. |
| `outputs/deliverables/` | Indikatoren i plattformformatet. |
| `outputs/results_TEST_AOI/` | Resultat av hurtigtesten (gitignored). |

## 5. Input / Output

### Input

| Datasett | Kilde og versjon | Lastet ned | Hentes med |
|---|---|---|---|
| Overflate- og terrengmodell, DOM1/DTM1 | Kartverket, Nasjonal detaljert høydemodell (flyvninger 2010–2024) | Lest under kjøringene 2026-07-28 til 2026-09-17 | Leses direkte av skriptene |
| NiN-naturtyper | Miljødirektoratet, FILEGDB, EPSG:4326 | 2026-07-28 | `R/fetch_nin_data.R` |
| AR5 skog og myr | NIBIO, FKB-AR5 (krever tilgang via Norge digitalt) | 2026-07-28 | `R/extract_ar5_skog_myr.R` |
| AR50 skog og myr (åpen reserveløsning) | NIBIO, AR50 | 2026-07-21 | `R/build_ar50_wetland_lidar_coverage.R`, `R/build_ar50_skog.R` |
| Bioklimatiske soner | Moen-sonene, Miljødirektoratets kartjeneste (lag «soner2017») | 2026-07-20 | `R/fetch_bioclim_zones.R` |
| Skogforstyrrelser 1986–2020 | Senf og Seidl (2021), Zenodo-post 7080016 | 2026-07-22 | `R/fetch_disturbance.R` |
| Bygninger | OpenStreetMap, nasjonalt uttrekk | 2026-07-23 | `R/fetch_osm_buildings.R` |
| SSB-rutenett 10 og 50 km | Bygget fra Kartverkets åpne 1 km-rutenett | 2026-07-21 | `R/build_ssb_grids.R` |
| Regioner og kystlinje | NINAnor/ecosystemCondition | 2026-07-20 | Ligger i repoet |

**AR5 eller AR50.** AR5 gir skarpere grenser mellom skog og myr, men krever
tilgang. Uten AR5 bruker beregningen automatisk AR50, som er åpen. Kilden
skrives til konsollen og lagres i kolonnen `population_source`.
Resultatene blir litt forskjellige; i ett stratum var skogreferansen
3,97 m med AR5 og 2,60 m med AR50. De leverte resultatene bruker AR5.

### Output

I `outputs/deliverables/`:

- `NO_GJEN_001_indicatorMap_region.rds` – landsdeler (primær).
- `NO_GJEN_001_indicatorMap_grid50km.rds` – SSB 50 km-ruter med data.
- `NO_GJEN_001_indicatorMap_polygon.rds` – hver utvalgscelle med verdi.
  Kartet er avledet fra AR5: utvalgspunktene er trukket inne i AR5 myr.
  Geometrien er likevel ikke AR5 selv, men 20 × 20 m-cellen rundt hvert
  utvalgspunkt. Ingen AR5-polygongrenser publiseres. Det samme gjelder
  `outputs/results/NO_GJEN_001_wetland_index_OpenSource.shp`.
- `NO_GJEN_001_values.csv` / `.xlsx` – verditabell med nasjonal verdi,
  tilleggskolonner og metadata.
- `NO_GJEN_001_map.png`.

Kolonner: `v` = gjennomsnittlig vegetasjonshøyde (m), `i` = indikatorverdi,
`reference_high` = referanse for god tilstand (X100), `reference_low` =
skogreferansen (X0), `thr` = 0,6 på indikatorskalaen (originalen
definerer ingen X60 på variabelskalaen), `sd` = bootstrap-standardfeil for
det arealvektede gjennomsnittet. Årstall `2024` er siste flyår for
høydemodellene; flyvningene spenner over 2010–2024.

## 6. Installasjon / Kjøring

Sett opp R-miljøet som beskrevet i [hoved-README](../README.md#6-installasjon--kjøring).
Kjør deretter, i rekkefølge:

1. `R/fetch_bioclim_zones.R`
2. `R/fetch_disturbance.R`
3. `R/fetch_osm_buildings.R`
4. `R/fetch_nin_data.R`
5. `R/build_ssb_grids.R`
6. `R/build_ar50_wetland_lidar_coverage.R` – kjøres alltid, også med
   AR5-tilgang. Lager `dtm1_tile_footprint.gpkg`, som alle uttrekk av
   kronehøyde trenger.
7. `R/build_ar50_skog.R`
8. `R/build_refvaatmark_30m.R` – referansen for god tilstand (ca. 40 min).
   Kan avbrytes og startes på nytt; den fortsetter der den slapp.
9. Med AR5-tilgang: legg `AR5-skog-myr.gpkg` i mappen over repoet og kjør
   `R/extract_ar5_skog_myr.R`. Stien kan endres øverst i skriptet. Uten
   AR5 hoppes steget over, og beregningen bruker AR50.
10. `R/NO_GJEN_001_wetland_pipeline_OpenSource.R` – beregningen.
11. `R/export_deliverables.R` – leveransefilene.
12. `R/make_report_map.R` – rapportkartet.

**Varianter.** `GJEN001_SAMPLING_SCALE=1m` beregner populasjon og
skogreferanse på 1 m i stedet for 20 m, og `GJEN001_REF_VARIANT=1m` bruker
den eldre 1 m-referansen for god tilstand. Utdata får egne suffikser og
overskriver aldri de leverte filene. Med 1 m-utvalg blir regionverdiene
0,01–0,03 lavere.

**Rask test.** Når steg 6–9 er kjørt, kjører `R/quick_test_small_aoi.R`
den uendrede beregningen for én region (standard Nord-Norge; velg annen
med `GJEN001_TEST_REGION`) på noen minutter. Testen ga 0,9698 for
Nord-Norge da den ble kjørt med det tidligere 1 m-utvalget, likt den
nasjonale kjøringen med samme metode. Den er ikke kjørt på nytt med det
leverte 20 m-utvalget (0,977 nasjonal kjøring).

**Kontroll.** Hele kjeden er kjørt fra tomt mellomlager uten tilgang til
NINAs filområder. Nedlastingene ga de samme objekttallene som originalen.
To kjøringer etter hverandre gir identiske resultater.

**Kjente begrensninger**

- **Avvik fra NINAs publiserte referansetabell.** 15 av 20 strata ligger
  innenfor 0,5–2 ganger de publiserte verdiene. Der avviket er størst
  (Sørlandet sørboreal og mellomboreal, Nord-Norge nordboreal), er 65–90 %
  av polygonene i god tilstand kartlagt i 2023–2025, altså etter at den
  publiserte tabellen ble laget. Avviket skyldes derfor hovedsakelig nyere
  kartlegging, ikke metoden.
- **AR5 og AR50 skiller ikke ut sumpskog.** NiN skiller V2 myr- og
  sumpskogsmark fra skog, men AR5 og AR50 har bare skog og myr. Tresatt
  våtmark kan derfor havne i skogreferansen, eller utenfor populasjonen.
- **Strata uten referanse for god tilstand får ingen verdi.**
  Referansetabellen har verdier for 21 strata. I de leverte resultatene
  har 3 av 25 strata (region × bioklimatisk sone) ingen verdi.
- **`regions.shp` har en tegnkodingsfeil** i kolonnen `region` for
  Østlandet og Sørlandet. Skriptene bruker `id` (3 og 5).

## 7. Lisens / Rettigheter

Se [**LICENSE**-filen](LICENSE.md). Nedlastede data er underlagt
lisensene til kildene. AR5 deles ikke i repoet.
