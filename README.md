# Indikatorutvikling for våtmark-2026

- **Norsk tittel**: Indikatorutvikling for våtmark-2026
- **Prosjekteier**: Miljødirektoratet
- **Oppdragstaker**: Sállir Natur AS
- **Leveringsdato**: 30.11.2026
- **Nedlastingslenke:** [dataleveranser.miljodirektoratet.no/nedlasting/leveranse-id](https://dataleveranser.miljodirektoratet.no/nedlasting/<leveranse-id>) **[FYLLES INN]**

Åpne og reproduserbare beregninger av indikatorer for økologisk tilstand i
våtmark, levert i dataformatet til ecosystemCondition-plattformen.

- **English**: Open, reproducible reconstructions of five indicators of
  ecological condition for Norwegian wetlands, with delivery files in the
  ecosystemCondition platform format.
- **Norwegian**: Åpne, reproduserbare rekonstruksjoner av fem indikatorer
  for økologisk tilstand i norsk våtmark, med leveransefiler i formatet til
  ecosystemCondition-plattformen.

## 1. Bidragsytere / Kontakt

| Navn | Organisasjon | Epost | Bidrag |
|---|---|---|---|
| Bendik Sivertsen (BS) | Sállir Natur AS | bendik@sallirnatur.no | Rapportskriving |
| Jesus Adrian Chimal-Ballesteros (JACB) | Sállir Natur AS | adrian@sallirnatur.no | Rapportskriving, kodeutvikling og vurdering |
| Lasse Keetz (LK) | Field Geospatial AS | lasse.keetz@fieldgeo.no | Kodeutvikling og vurdering |

- **Eventuelle eksterne samarbeidspartnere:** Field Geospatial AS (Lasse Keetz). Metodene bygger på
  publisert arbeid fra Norsk institutt for naturforskning (NINA), men NINA
  har ikke deltatt i prosjektet.

## 2. Formål / Bakgrunn

Repoet er levert under avtale 26087344 med Miljødirektoratet,
*Indikatorutvikling for våtmark i 2026*. Målet er indikatorer for økologisk
tilstand i våtmark som kan beregnes på nytt fra åpne data, uten tilgang til
interne filområder, og som leveres direkte i plattformens dataformat.

Indikatorene rekonstruerer metodikken i NINAs
[ecosystemCondition](https://github.com/NINAnor/ecosystemCondition) og
[ecRxiv](https://github.com/NINAnor/ecRxiv) (publiseringsplattform for
tilstandsindikatorer, doi:[10.5281/zenodo.21802603](https://doi.org/10.5281/zenodo.21802603)).
De følger fagsystemet for økologisk tilstand (Nybø & Evju, 2017): en
målt variabel skaleres mot en referanseverdi (god tilstand) og en
grenseverdi til en indikatorverdi mellom 0 og 1, der 0,6 er grensen for
god tilstand. Repoet er en uavhengig rekonstruksjon og **ikke et offisielt
NINA-produkt**. Der originalen ikke kunne gjenskapes nøyaktig, er avviket
dokumentert i indikatorens README.

| Indikator | Måler | Status |
|---|---|---|
| [`NO_FUNC_003`](NO_FUNC_003/) | Funksjonell plantesammensetning: artsvektede indikatorverdier for lys, fuktighet, pH og nitrogen i ANO-flater, mot referansefordelinger. Leveres som fire indikatorer (`NO_FULI_003`, `NO_FUMO_003`, `NO_FUPH_003`, `NO_FUNI_003`). | Ferdig |
| [`NO_CONN_001`](NO_CONN_001/) | Strukturell konnektivitet: avstand fra hver myr til nærmeste infrastruktur, sett mot avstand til nærmeste nabomyr. | Ferdig |
| [`NO_GJEN_001`](NO_GJEN_001/) | Gjengroing: vegetasjonshøyde fra laserdata (LiDAR) mot referansenivåer for god tilstand og for skog. | Ferdig |
| [`NO_GJEN_002`](NO_GJEN_002/) | Gjengroing fra flyfoto: vegetasjonshøyde predikert med en dyplæringsmodell, mot de samme referansenivåene som `NO_GJEN_001`. | Ferdig |
| [`NO_NDVI_001`](NO_NDVI_001/) | Primærproduksjon: trend i NDVI (MODIS) per myrpolygon, skalert mot ingen trend. | **Foreløpig** – kun MODIS, uten usikkerhetsestimat |

`NO_GJEN_001` og `NO_GJEN_002` måler det samme mot de samme
referansenivåene og skiller seg bare i hvordan vegetasjonshøyden måles.
Flyfoto fornyes oftere enn nasjonale laserdata, slik at `NO_GJEN_002` kan
oppdateres hyppigere.

**Referanser**

- Nybø, S., & Evju, M. (Red.). (2017). *Fagsystem for fastsetting av god
  økologisk tilstand: Forslag fra et ekspertråd*. Ekspertrådet for
  økologisk tilstand.
- Metodereferanser for hver indikator står i indikatorens README.

## 3. Forutsetninger / Dependencies

- **Hardware** (maskinen analysene er kjørt og testet på):
  - **OS:** Windows 11 Pro, build 10.0.26200
  - **Memory (RAM):** 27,6 GB tilgjengelig
  - **CPU:** AMD Ryzen AI 7 PRO 350, 8 kjerner / 16 tråder
  - **GPU:** AMD Radeon 860M (integrert). Brukes ikke; ingen analyser krever GPU.
  - **Storage:** 954 GB SSD. En full nyberegning av alle indikatorer krever
    rundt 200 GB ledig plass, mest til rådata for `NO_CONN_001` (N50 og
    myrmodell, ca. 37 GB) og MODIS-fliser for `NO_NDVI_001` (ca. 100 GB).
    Beregning fra mellomlagrede data krever langt mindre.
  - **Ytelse:** Se tabellen under. «Fra mellomlager» betyr fra data som
    ligger i repoet eller som lastes ned ferdig beregnet.

    | Indikator | Fra mellomlager | Full nyberegning |
    |---|---|---|
    | `NO_FUNC_003` | ca. 3 min | ca. 3 min + nedlasting (ca. 115 MB) |
    | `NO_GJEN_001` | under 1 min | over 2 timer |
    | `NO_GJEN_002` | noen minutter | ca. 90 timer (modellkjøring på flyfoto) |
    | `NO_CONN_001` | noen minutter | over 20 timer |
    | `NO_NDVI_001` | ca. 2 min | flere timer (MODIS-nedlasting) |

- **Kjøringsmiljø:**
  - **Lokal PC:** Windows 11. Geodatabibliotekene følger med R-pakken
    `sf` sine Windows-binærfiler: GDAL 3.12.1, PROJ 9.7.1, GEOS 3.14.1.
    Rtools trengs ikke; alle pakker installeres som binærfiler. Noen
    hjelpeskript er PowerShell-skript (Windows PowerShell 5.1) og bruker
    `curl.exe`, som følger med Windows.
- **Programvare:**
  - R 4.6.1
  - QGIS 3.44.12 – bare for `NO_CONN_001`, steg 2 (konvertering av N50 2006
    fra SOSI-format).
  - uv 0.11.29 – bare for Python-miljøet til `NO_GJEN_002`.
  - Quarto 1.9.38 – bare for å lage indikatordokumentene i `docs/` på nytt.
- **KI-verktøy:**
  - Claude Code (Anthropic), kommandolinjeverktøy og VS Code-utvidelse,
    med språkmodellen Claude Opus (versjon 5.5 i sluttfasen; tidligere
    Claude-versjoner er brukt underveis i prosjektet).
  - Claude (Anthropic), skrivebordsapplikasjon, brukt til oversettelse av
    rapporttekst fra engelsk til norsk.
  - Bruk: utvikling og feilsøking av R- og Python-kode, gjennomgang av
    NINAs originalkode og metodedokumentasjon, kjøring og kontroll av
    analyser, utkast til dokumentasjon (README-filer, metadata) og
    oversettelse av tekst til rapporten.
  - Alle metodiske valg er tatt av prosjektgruppen. Alle resultater er
    kontrollert av prosjektgruppen: kjøringer er gjentatt og gir identiske
    resultater, og verdiene er sammenlignet med NINAs originale indikatorer
    der det var mulig.
  - Det er ikke brukt egne instruksjonsfiler (`CLAUDE.md` / `AGENTS.md`) i
    repoet. Verktøyets arbeidsnotater fra prosjektet legges ikke ved, fordi
    de inneholder tilgangsinformasjon til lisensierte data.
- **Programmeringsspråk:**
  - R 4.6.1 (alle indikatorer)
  - Python 3.9.25 (bare `NO_GJEN_002`, kjøring av høydemodellen)
- **Definisjon av analysemiljø:**

  **R-miljø:** Hver indikator har sin egen `renv.lock` med eksakte
  pakkeversjoner. Hver pakke er knyttet til et datert øyeblikksbilde av
  CRAN hos Posit Package Manager, slik at gamle versjoner kan installeres
  som binærfiler. `ecTools` hentes fra GitHub (`NINAnor/eaTools`, fast
  commit). Gjenopprettingen er testet i et tomt bibliotek (ca. 4 minutter
  for alle indikatorene).

  **Python-miljø:** `NO_GJEN_002/src/chm_model/` har `pyproject.toml` og
  `uv.lock`. Python 3.9 er eldre enn malens krav (> 3.11), men er versjonen
  høydemodellen (Meta HighResCanopyHeight) er laget for, og den som de
  publiserte resultatene er beregnet med. Python trengs bare for å lage nye
  høydeprediksjoner; indikatoren kan beregnes på nytt fra prediksjonene som
  ligger i repoet.

## 4. Struktur

Hver indikator er en selvstendig mappe som kan kjøres uten de andre.
Skriptene finner filer relativt til sin egen plassering. Hver
indikatormappe følger standardstrukturen:

- _/config_ – Konfigurasjonsfiler (maler for tilgang til egne data).
- _/R_ – All R-kode: nedlasting, beregning, eksport og figurer.
- _/src_ – PowerShell-skript som kjører lange beregninger region for
  region, og Python-kode (`NO_GJEN_002`).
- _/data_ – Små inndata og metadata. Store inndata lastes ned av skriptene
  og ligger ikke i repoet.
- _/docs_ – Indikatordokument på engelsk (Quarto, `.qmd` og `.html`) etter
  NINAs ecRxiv-mal, og annen metodikk.
- _/outputs/results_ – Kart og tabeller fra beregningen.
- _/outputs/deliverables_ – Indikatoren i plattformformatet.

I tillegg:

- _/Tools_ (rotmappen) – felles eksportskript (`export_platform_format.R`)
  som alle indikatorene bruker for å skrive leveransefilene, og
  hjelpefunksjoner for indikatordokumentene (`quarto_helpers.R`).
- _NO_NDVI_001/experimental_ – uferdig henting av Sentinel-2-data. Ikke
  del av den leverte indikatoren.

## 5. Input / Output

### Input

Store datasett ligger ikke i repoet. Hver indikator har skript i `R/` som
laster dem ned eller bygger dem. Tabellen viser datasettene som er brukt i
de leverte resultatene, med datoen de ble lastet ned. En ny nedlasting kan
gi en nyere versjon, siden flere av kildene oppdateres løpende.

| Indikator | Datasett | Kilde og versjon | Lastet ned | Hentes med |
|---|---|---|---|---|
| Alle | Regioner (5 landsdeler) og kystlinje | NINAnor/ecosystemCondition, CC BY 4.0 | 2026-06-23 | Ligger i repoet |
| `NO_FUNC_003` | ANO – arealrepresentativ naturovervåking | Miljødirektoratet, nasjonal eksport (GeoPackage) | 2026-07-30 | `R/fetch_ano_data.R` |
| `NO_FUNC_003` | B12, plante- og lavarter på myr | Artsdatabanken | 2026-08-03 | `R/fetch_b12_data.R` |
| `NO_FUNC_003` | Indikatorverdier for svenske karplanter | Tyler et al. (2021), tilleggsmateriale | 2026-07-30 | Manuelt, se `R/get_tyler_data.R` |
| `NO_GJEN_001`, `NO_GJEN_002` | NiN-naturtyper | Miljødirektoratet, FILEGDB, EPSG:4326 | 2026-07-28 | `R/fetch_nin_data.R` |
| `NO_GJEN_001` | Terreng- og overflatemodell, DTM1/DOM1 | Kartverket, Nasjonal detaljert høydemodell, lest direkte over nett | 2026-07-28 til 2026-09-17 (under kjøring) | Leses av beregningsskriptene |
| `NO_GJEN_001` | AR5 skog og myr | NIBIO, FKB-AR5 (begrenset lisens, se under) | 2026-07-28 | `R/extract_ar5_skog_myr.R` |
| `NO_GJEN_001` | AR50 skog og myr (åpen reserveløsning) | NIBIO, AR50 | 2026-07-21 | `R/build_ar50_*.R` |
| `NO_GJEN_001`, `NO_GJEN_002` | Bioklimatiske soner | Moen-sonene, Miljødirektoratets kartjeneste (lag «soner2017») | 2026-07-20 | `R/fetch_bioclim_zones.R` |
| `NO_GJEN_001` | Skogforstyrrelser 1986–2020 | Senf og Seidl (2021), Zenodo-post 7080016 | 2026-07-22 | `R/fetch_disturbance.R` |
| `NO_GJEN_001` | Bygninger | OpenStreetMap | 2026-07-23 | `R/fetch_osm_buildings.R` |
| `NO_GJEN_001`, `NO_GJEN_002` | SSB-rutenett 10 og 50 km | SSB via Kartverket | 2026-07-21 | `R/build_ssb_grids.R` |
| `NO_GJEN_002` | Ortofoto, 50 cm RGB | Kommersiell nasjonal mosaikk fra Field Geospatial AS, produktår 2025 (kan ikke deles, se indikatorens README) | Lest 2026-09-04 til 2026-09-17 | Brukerens egen kilde |
| `NO_GJEN_002` | Høydemodell for trær | Meta HighResCanopyHeight, «aerial»-sjekkpunkt (Apache-2.0) | 2026-09 | Se `docs/CHM_MODEL_SETUP.md` |
| `NO_CONN_001` | N50 Kartdata, historiske data 2023 og 2013 | Kartverket via Geonorge, FGDB | 2026-08-06 | `R/fetch_n50_infrastructure_data.R` |
| `NO_CONN_001` | N50 Kartdata, historiske data 2006 | Kartverket via Geonorge, SOSI | 2026-08-06 | `R/fetch_n50_infrastructure_data.R` + QGIS |
| `NO_CONN_001` | Regulerte innsjøer | NVE, Vannkraft, via Geonorge (FGDB) | 2026-08-06 | `R/fetch_n50_infrastructure_data.R` |
| `NO_CONN_001` | Myrmodell (MyrMod2Rv) | «Våtmark basert på NiN» (Bakkestuen m.fl.), GeoTIFF via Geonorge, fil datert 2023-06-19 | 2026-08-07 | `R/fetch_wetland_map.R` |
| `NO_CONN_001` | NiN-naturtyper | Miljødirektoratet, FILEGDB, EPSG:4326 | 2026-08-27 | `R/fetch_nin_data.R` |
| `NO_CONN_001` | AR5 myr | NIBIO, FKB-AR5 (begrenset lisens) | 2026-07-28 | Fra `NO_GJEN_001` |
| `NO_NDVI_001` | NDVI, MODIS MOD13Q1 v6.1 | NASA LP DAAC (Didan, 2021), 2000–2026, slutten av mai til september | 2026-08-28 | `R/fetch_modis_ndvi.R`; resultatet ligger i repoet |
| `NO_NDVI_001` | NiN-naturtyper | Miljødirektoratet, FILEGDB, EPSG:4326 | 2026-08-05 | `R/fetch_nin_data.R` |

**Lisensbegrensninger.** AR5 er bare tilgjengelig for parter i Norge
digitalt. Derfor publiseres ikke polygongeometri avledet av AR5; den
genereres lokalt av den som har tilgang. Ortofotoet til `NO_GJEN_002` er
kommersielt og kan ikke deles. Prediksjonene per polygon ligger i repoet,
slik at indikatoren kan beregnes på nytt uten bildene.

**Mellomlager for `NO_CONN_001`.** Avledede data som tar over 20 timer å
beregne (ca. 2 GB) publiseres som Release-filer på GitHub og hentes med
`NO_CONN_001/R/download_caches.R`.

- Didan, K. (2021). *MODIS/Terra vegetation indices 16-day L3 global 250m
  SIN grid V061* [Datasett]. NASA EOSDIS Land Processes Distributed Active
  Archive Center. https://doi.org/10.5067/MODIS/MOD13Q1.061
- Tyler, T., Herbertsson, L., Olofsson, J., & Olsson, P. A. (2021).
  Ecological indicator and traits values for Swedish vascular plants.
  *Ecological Indicators, 120*, 106923.
  https://doi.org/10.1016/j.ecolind.2020.106923

### Output

Hver indikator avslutter med `R/export_deliverables.R`, som skriver til
`outputs/deliverables/`:

- `<ID>_indicatorMap_region.rds` – `sf`-objekt i EPSG:25833, én rad per
  landsdel, kolonnene `area, areaId, v_ÅÅÅÅ, sd_ÅÅÅÅ, i_ÅÅÅÅ,
  reference_high, reference_low, thr` (variabelverdi, usikkerhet,
  indikatorverdi 0–1, referanse- og grenseverdi på variabelskalaen, og
  terskel for god tilstand på indikatorskalaen). Finere enheter
  (rutenett, polygoner, flater) skrives i egne filer med de samme
  kolonnene.
- `<ID>_values.csv` / `.xlsx` – samme tabell uten geometri, med nasjonal
  verdi og tilleggskolonner. Regnearket har et `metadata`-ark med
  definisjoner av variabel, skalering, referanseverdier, usikkerhet og
  kilder.
- `<ID>_map.png` – kart over indikatorverdien per landsdel.

Kolonnenavnene følger plattformens eksempelfil (`reference_high`);
plattformens dokumentasjon og kontrakten skriver `referance_high`.

`outputs/results/` inneholder kart, tabeller og diagnostikk fra
beregningen.

## 6. Installasjon / Kjøring

1. Installer R 4.6.1. Klon repoet.
2. Sett opp R-pakkene for indikatoren du skal kjøre. Fra indikatorens mappe:

   ```r
   install.packages("renv")
   renv::restore(lockfile = "renv.lock", library = .libPaths()[1], prompt = FALSE)
   ```

3. Bare for `NO_GJEN_002`, og bare for å lage nye høydeprediksjoner:
   installer [uv](https://docs.astral.sh/uv/) og kjør `uv sync --frozen` i
   `NO_GJEN_002/src/chm_model/`.
4. Kjør skriptene i rekkefølgen indikatorens README angir. Mønsteret er
   det samme for alle:
   1. nedlastingsskriptene i `R/` (`fetch_*`, `build_*`);
   2. beregningen (`NO_<ID>_..._pipeline*.R` eller tilsvarende);
   3. `R/export_deliverables.R`;
   4. `R/make_report_map.R`.

Skriptene kan kjøres fra RStudio, med `Rscript skript.R` eller med
`source()`. De setter selv riktig arbeidsmappe.

## 7. Lisens / Rettigheter

Se [**LICENSE**-filen](LICENSE.md) for mer informasjon. Koden og
resultatene er lisensiert under CC BY 4.0, samme lisens som
`NINAnor/ecosystemCondition`, som metodikken bygger på. Data som hentes av
skriptene er underlagt lisensene til de opprinnelige kildene.

Copyright (c) 2026 Sállir Natur AS
