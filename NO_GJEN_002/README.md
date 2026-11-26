# NO_GJEN_002 – Gjengroing i våtmark fra flyfoto-2026

- **Norsk tittel**: Gjengroing i våtmark (flyfoto)
- **Prosjekteier**: Miljødirektoratet
- **Oppdragstaker**: Sállir Natur AS
- **Leveringsdato**: 30.11.2026
- **Del av**: [Indikatorutvikling for våtmark-2026](../README.md)

Måler gjengroing i våtmark som vegetasjonshøyde fra flyfoto, for hver
20 m-celle med AR5 myr, mot de samme referansenivåene som `NO_GJEN_001`.

- **English**: Woody encroachment in wetlands from aerial photography:
  canopy height estimated from the national orthophoto by the CHMv2 model,
  calibrated to LiDAR, for every 20 m cell of AR5 mire, scaled against the
  reference levels of `NO_GJEN_001`.
- **Norwegian**: Gjengroing i våtmark fra flyfoto: vegetasjonshøyde
  beregnet fra ortofoto med modellen CHMv2, kalibrert mot laserdata, for
  hver 20 m-celle med AR5 myr, skalert mot referansenivåene i `NO_GJEN_001`.

> **Versjon 000.004 (november 2026) erstatter versjon 000.003.** Den forrige
> versjonen brukte modellen CHMv1 på kartlagte NiN-våtmarkspolygoner. Koden
> (`R/NO_GJEN_002_national_pipeline.R` m.fl.) og leveransene
> (`outputs/deliverables/`) er beholdt til sammenligning, men brukes ikke
> lenger.

## 1. Bidragsytere / Kontakt

Se [hoved-README](../README.md#1-bidragsytere--kontakt).

## 2. Formål / Bakgrunn

Rekonstruksjon av NINAs indikator NO_GJEN_002 (Gray, Mienna og Venter,
publisert på ecRxiv). Den måler det samme som
[`NO_GJEN_001`](../NO_GJEN_001/), men henter vegetasjonshøyden fra flyfoto
i stedet for laserdata. Flyfoto fornyes langt oftere enn nasjonale
laserdata, så indikatoren kan oppdateres hyppigere.

**Metode.**

1. **Høydekart.** Modellen CHMv2 (Meta og World Resources Institute)
   beregner vegetasjonshøyde fra den nasjonale ortofotomosaikken (0,5 m)
   for all AR5 myr pluss en stripe på 30 m rundt, på GPU.
2. **Celler.** Det faste 20 m-rutenettet, det samme som i `NO_GJEN_001`.
   Alle celler med AR5 myr er med. Hver celle teller med sin andel myr, og
   bygninger (OpenStreetMap) trekkes fra, som i `NO_GJEN_001`.
3. **Høyde per celle.** Medianen av de 1 600 høydeverdiene i cellen, som
   medianen av laserhøyden i `NO_GJEN_001`. Høyden kalibreres mot
   laserdata: *laserhøyde = maks(0; −0,0127 + 0,5336 × CHMv2-høyde)*.
4. **Referanser og skalering.** Uendret fra `NO_GJEN_001`: referansen for
   god tilstand (X100, 30 m) og skogreferansen (X0, 20 m), og samme
   sigmoid-funksjon, per celle.
5. **Aggregering.** Gjennomsnitt per region, per SSB 50 km-rute og
   nasjonalt, vektet med myrarealet i cellene. I tillegg et gjennomsnitt der
   hvert stratum (region × bioklimatisk sone) veier likt, som i utvalget i
   `NO_GJEN_001` (`i_sample_design`).
6. **Usikkerhet.** Avstanden til den laserbaserte indikatoren i ca. 21 000
   valideringsceller: √(gjennomsnittlig differanse² + standardfeil²). En
   50 km-rute får verdien til regionen med mest av myrarealet.
7. **Flyår.** Hver celle dateres med flyprosjektet som er synlig der i
   mosaikken. Årstallet i leveransene er medianen over myrarealet i Norge.

**Modellvalg.** CHMv2 ble sammenlignet med CHMv1 (Meta HighResCanopyHeight,
brukt i versjon 000.003) i 25 027 utvalgsceller fra `NO_GJEN_001` med
laserhøyde. Kalibrert CHMv2 har gjennomsnittlig absolutt feil 0,30 m (CHMv1:
0,35 m) og er klart bedre der vegetasjonen er 2 m eller høyere. Skriptene og
alle resultatene: [`src/chm_comparison/`](src/chm_comparison/README.md). CHMv1 kan
ikke forbedres med kalibrering og ville tatt ca. to uker nasjonalt på CPU;
CHMv2 tok ca. 11 timer på én GPU.

**Resultater (versjon 000.004):**

| Region | Indikator (vektet med myrareal) | Strata likt vektet | `NO_GJEN_001` | Usikkerhet | Myrareal |
|---|---|---|---|---|---|
| Nord-Norge | 0,976 | 0,977 | 0,977 | 0,005 | 2 609 km² |
| Midt-Norge | 0,962 | 0,959 | 0,960 | 0,008 | 4 568 km² |
| Vestlandet | 0,952 | 0,963 | 0,959 | 0,004 | 774 km² |
| Sørlandet | 0,956 | 0,957 | 0,950 | 0,004 | 1 210 km² |
| Østlandet | 0,932 | 0,914 | 0,908 | 0,003 | 4 705 km² |
| **Norge** | **0,954** | **0,952** | **0,949** | **0,002** | 13 867 km² |

Med samme vekting av strata ligger alle regioner innenfor 0,007 av
`NO_GJEN_001`. 1,8 % av myrarealet er utelatt: celler utenfor kartet over
regioner og soner, celler i strata uten referanse, og celler uten flyfoto.

**Referanser**

- CHMv2: Meta og World Resources Institute, bygget på DINOv3,
  <https://huggingface.co/facebook/dinov3-vitl16-chmv2-dpt-head>.
- Tolan, J. mfl. (2024). Very high resolution canopy height maps from RGB
  imagery using self-supervised vision transformer and convolutional
  decoder trained on aerial lidar. *Remote Sensing of Environment, 300*,
  113888. https://doi.org/10.1016/j.rse.2023.113888 (CHMv1)
- NINAs original: [NINAnor/ecRxiv, NO_GJEN_002](https://github.com/NINAnor/ecRxiv).

## 3. Forutsetninger / Dependencies

Maskinvare, programvare, KI-verktøy og R-versjon: se
[hoved-README](../README.md#3-forutsetninger--dependencies).

- **R-pakker:** låst i [`renv.lock`](renv.lock) (eksporten og dokumentet).
- **Python:** 3.12 med PyTorch 2.11 (CUDA 12.8) og transformers 5.24, låst i
  [`src/chm_national/pyproject.toml`](src/chm_national/pyproject.toml) og
  `uv.lock`. Miljøet bygges automatisk av Docker-skriptene.
- **GPU:** trengs for høydekartet (testet på NVIDIA RTX 5090, 32 GB).
- **CHMv2** er en «gated» modell og krever innlogging på Hugging Face, se
  under.
- **Ytelse:** høydekartet tar 11–14 timer nasjonalt (lesing av mosaikken fra
  nettverksdisk er flaskehalsen), 20 m-beregningen ca. 30 minutter,
  eksporten noen sekunder.

**Tilgang til CHMv2 (Hugging Face).** Modellen lastes ned automatisk ved
første kjøring (ca. 1,2 GB), men bare med en gyldig nøkkel (token):

1. Lag en konto på <https://huggingface.co> og godta vilkårene (DINOv3-
   lisensen) på modellsiden
   <https://huggingface.co/facebook/dinov3-vitl16-chmv2-dpt-head>.
2. Lag en nøkkel med lesetilgang under *Settings → Access Tokens*
   (<https://huggingface.co/settings/tokens>). Den begynner med `hf_`.
3. Gi nøkkelen til skriptene på én av to måter:
   - **Som fil (anbefalt):** lagre nøkkelen i `~/.cache/huggingface/token`,
     for eksempel med `hf auth login`, eller uten ekstra programmer:

     ```bash
     mkdir -p ~/.cache/huggingface
     printf '%s' 'hf_...' > ~/.cache/huggingface/token
     chmod 600 ~/.cache/huggingface/token
     ```

   - **Som miljøvariabel:** `HF_TOKEN=hf_...` foran kommandoen, eller i
     `docker/config.local.env` (som ikke legges i git).

Mappen `~/.cache/huggingface` (eller `HF_HOME` hvis den er satt) monteres
inn i containeren. Der lagres også den nedlastede modellen, så den lastes
bare ned én gang. Skriptet stopper med en tydelig melding hvis ingen nøkkel
finnes. Nøkkelen er personlig: den skal aldri legges i repoet.

## 4. Struktur

| Mappe | Innhold |
|---|---|
| `src/chm_comparison/` | Sammenligningen av modellene mot laserdata: valget av CHMv2, kalibreringen og valideringscellene. Se [`src/chm_comparison/README.md`](src/chm_comparison/README.md). |
| `src/chm_national/` | `national_chm.py` (høydekartet), `cell_indicator.py` (20 m-celler, kalibrering, indikator, usikkerhet, flyår), `calibration_chmv2_median.json` (kalibreringen) og Python-miljøet. `src/chm_model/` og `src/run_national_by_region.ps1` hører til versjon 000.003. |
| `R/` | `export_deliverables_20m_cells.R` (leveransene). Resten hører til versjon 000.003 (NiN-polygoner, CHMv1) og er beholdt til sammenligning. |
| `docs/` | Indikatordokument på engelsk etter NINAs ecRxiv-mal: `NO_GJEN_002.qmd` (kilde) og `NO_GJEN_002.html`. `METHODOLOGY_CANOPY_HEIGHT.md` og `CHM_MODEL_SETUP.md` gjelder versjon 000.003. |
| `data/OpenS_data/orthophoto_chmv2_20m_cells/` | Tabellene fra den nasjonale 20 m-kjøringen. Leveransene kan lages på nytt fra dem uten bilder. |
| `data/OpenS_data/` ellers | Referansetabellene fra `NO_GJEN_001`, og data for versjon 000.003. |
| `outputs/deliverables_20m_cells/` | Indikatoren i plattformformatet (gjeldende). |
| `outputs/deliverables/`, `outputs/results/` | Versjon 000.003 (erstattet). |

## 5. Input / Output

### Input

| Datasett | Kilde, versjon og lisens | Brukt til | Hentes med / ligger |
|---|---|---|---|
| Ortofoto, 50 cm RGB | Kommersiell nasjonal mosaikk fra Field Geospatial AS (`MosaikkOmlopNorge_2025`), produktår 2025, 8 bit RGB, EPSG:25833. Flyvningene over myrene er fra 2015–2024 (median 2022). Kan ikke videreformidles | Høydekartet, sammenligningen | Brukerens egen kilde (`ORTHOPHOTO_SOURCE_PATH`), lest 2026-11 |
| Flyprosjekter i mosaikken | Metadata levert med mosaikken: `mosaic_coverage_by_project.gpkg` (synlig prosjekt per område; navnet slutter med flyåret) og `metadata_omløpsprosjekt_mosaic_v2_2025.gpkg` (flydatoer) | Flyår per celle; flydato i sammenligningen | `metadata/` ved mosaikken |
| CHMv2 | Meta og World Resources Institute, `facebook/dinov3-vitl16-chmv2-dpt-head` på Hugging Face, revisjon `37130c85` (låst i koden; DINOv3-lisens, krever innlogging) | Høydekartet | Lastes ned automatisk, 2026-11 |
| CHMv1 | Meta HighResCanopyHeight, kode-commit `84971392`, sjekkpunkt `compressed_SSLhuge_aerial.pth` (Apache-2.0) | Bare sammenligningen (og versjon 000.003) | `docker/canopy_height_model/download_model_and_weights.sh` |
| AR5 myr | NIBIO, FKB-AR5, arealtype 60 (myr), kommunevise filer fra Geonorge lastet ned 2026-07-28. Begrenset lisens (Norge digitalt), kan ikke deles | Hvilke celler som er med, og myrandelen i hver celle | `docker/prepare_ar5_input/`, se `NO_GJEN_001` |
| Utvalgspunkter i AR5 myr | `vaatmark_pop_openS.gpkg` fra `NO_GJEN_001` (25 029 punkter); avledet av AR5 | Kalibrering og validering | Lages av `NO_GJEN_001` |
| Laserhøyde, DOM1 og DTM1 | Kartverket, Nasjonal detaljert høydemodell, 1 m, åpne data (CC BY 4.0); laserprosjektene fra Kartverkets katalog. Laserår 2006–2025 (median 2017) | Kalibrering og validering (median i 20 m-cellen, som `NO_GJEN_001`) | Leses over nett av sammenligningen, 2026-11 |
| Valideringsceller | Laserhøyden i utvalgscellene, fra sammenligningen; ligger ikke i repoet fordi cellene kommer fra AR5 | Usikkerheten | `docker/run_NO_GJEN_002_chm_comparison.sh`, kopieres til `NATIONAL_CHM_OUT_DIR` |
| Referanser X100 og X0 | God tilstand (30 m) og skog (20 m) per region og bioklimatisk sone, fra `NO_GJEN_001` | Skaleringen | `data/OpenS_data/refvaatmark_openS_30m.csv`, `vegHeights_skog_climZoneRegion_openS_20m.csv` |
| Bygninger | OpenStreetMap (ODbL), fra `NO_GJEN_001` | Trekkes fra myrarealet | `NO_GJEN_001/R/fetch_osm_buildings.R` |
| Regioner, bioklimatiske soner, SSB 50 km-ruter | Fra `NO_GJEN_001` (se hoved-README) | Strata og rapporteringsenheter | Ligger i repoet eller lages av `NO_GJEN_001` |

**Egne bilder.** Bildene bak de publiserte tallene er kommersielle data
med en lisens som ikke tillater videreformidling av bildene eller
tilgangsinformasjonen. Bildene må være 3-bånds RGB, 8 bit, 0,5 m, i
EPSG:25833, som lokal fil (GeoTIFF eller VRT).

### Output

I `outputs/deliverables_20m_cells/`:

- `NO_GJEN_002_indicatorMap_region.rds` – landsdeler (primær).
- `NO_GJEN_002_indicatorMap_grid50km.rds` – SSB 50 km-ruter med myr.
- `NO_GJEN_002_values.csv` / `.xlsx` – verditabell med nasjonal verdi,
  tilleggskolonner og metadata.
- `NO_GJEN_002_map.png`.

`v` er kalibrert gjennomsnittshøyde, der høyder under X100 regnes som X100
(som i `NO_GJEN_001`). Tilleggskolonner: `i_sample_design`, `height_m`,
`n_cells`, `mire_km2` og flyår (`flight_year_median`, `_min`, `_max`).
Det finnes ingen polygonfil, fordi AR5 ikke er åpne data.

## 6. Installasjon / Kjøring

**Leveransene fra tabellene i repoet (sekunder, uten bilder):**
`R/export_deliverables_20m_cells.R`, i RStudio eller med `Rscript` (også
på Windows), eller `docker/run_indicators.sh`. Indikatordokumentet:
`quarto render docs/NO_GJEN_002.qmd`.

**Hele kjeden (krever bilder, AR5, Linux eller WSL2, Docker og en NVIDIA-GPU;
oppsett i [`docker/README.md`](../docker/README.md)):** i en `screen`-økt,

```bash
bash docker/run_NO_GJEN_002_deliverables.sh
```

Skriptet kjører høydekartet (`docker/run_NO_GJEN_002_national_chm.sh`;
ferdige deler hoppes over), 20 m-beregningen
(`docker/run_NO_GJEN_002_cell_indicator.sh`), kopierer tabellene inn i
repoet, lager leveransene og indikatordokumentet. Innstillinger
(`NATIONAL_CHM_OUT_DIR`, `ORTHOPHOTO_SOURCE_PATH` m.fl.) står i
`docker/config.env`.

**Kalibrering og valideringsceller** (bare ved nye bilder eller ny modell):
`bash docker/run_NO_GJEN_002_chm_comparison.sh`, ca. 3,5 timer. Se
[`src/chm_comparison/README.md`](src/chm_comparison/README.md).

**Kontroll.** Lesefeil fra nettverksdisken prøves på nytt etter 10, 30 og
90 sekunder. Deler som fortsatt feiler, listes, og resultatet merkes
`INCOMPLETE`, slik at en ufullstendig kjøring aldri ser ferdig ut.

**Kjente begrensninger**

- **Høye bestand.** Etter kalibrering undervurderes høyder over 5 m med ca.
  1,4 m i gjennomsnitt.
- **Bildene.** Flyår og årstid varierer over landet; flyårene per enhet
  står i leveransene.
- **Tid mellom flyfoto og laser.** Kalibrering og validering bruker
  laserdata som ofte er flere år eldre eller nyere enn bildet.
- **Indeksen metter for åpen myr.** De fleste celler med åpen myr får 1,
  fordi sigmoid-funksjonen er flat nær referansen.
- **Strata uten referanse** (f.eks. Nord-Norge × boreonemoral sone) er
  utelatt, som i `NO_GJEN_001`.

## 7. Lisens / Rettigheter

Se [**LICENSE**-filen](LICENSE.md). Bildene og tilgangsinformasjonen er
ikke en del av repoet og kan ikke deles. CHMv2 er underlagt DINOv3-lisensen
og lastes ned fra Hugging Face (CHMv1 i versjon 000.003: Apache-2.0).
Nedlastede data er underlagt lisensene til kildene.
