# NO_GJEN_002 – Gjengroing i våtmark fra flyfoto-2026

- **Norsk tittel**: Gjengroing i våtmark (flyfoto)
- **Prosjekteier**: Miljødirektoratet
- **Oppdragstaker**: Sállir Natur AS
- **Leveringsdato**: 30.11.2026
- **Del av**: [Indikatorutvikling for våtmark-2026](../README.md)

Måler gjengroing i våtmark som vegetasjonshøyde predikert fra flyfoto med
en dyplæringsmodell, mot de samme referansenivåene som `NO_GJEN_001`.

- **English**: Woody encroachment in wetlands from aerial photography:
  canopy height predicted from orthophoto by a deep-learning model for
  every NiN wetland polygon, scaled against the reference levels of
  `NO_GJEN_001`.
- **Norwegian**: Gjengroing i våtmark fra flyfoto: vegetasjonshøyde
  predikert fra ortofoto med en dyplæringsmodell for hvert
  NiN-våtmarkspolygon, skalert mot referansenivåene i `NO_GJEN_001`.

## 1. Bidragsytere / Kontakt

Se [hoved-README](../README.md#1-bidragsytere--kontakt).

## 2. Formål / Bakgrunn

Rekonstruksjon av NINAs indikator NO_GJEN_002 (Gray, Mienna og Venter,
publisert på ecRxiv). Den måler det samme som
[`NO_GJEN_001`](../NO_GJEN_001/), men henter vegetasjonshøyden fra flyfoto
i stedet for laserdata. Flyfoto fornyes langt oftere enn nasjonale
laserdata, så indikatoren kan oppdateres hyppigere. Originalen ble testet
på 124 polygoner; dette er den første nasjonale kjøringen.

**Metode.**

1. **Vegetasjonshøyde.** Metas modell HighResCanopyHeight (Tolan et al.,
   2024), sjekkpunktet for flyfoto, kjøres på ortofoto med 0,5 m
   oppløsning i fliser på 256 × 256 piksler (128 m), på CPU.
2. **Populasjon.** Alle NiN-våtmarkspolygoner, ikke et utvalg. Verdien per
   polygon er **gjennomsnittet** av pikslene.
3. **Referanser.** Lånt uendret fra `NO_GJEN_001`, som i originalen:
   referansen for god tilstand evaluert på 30 m (X100), og skogreferansen
   på 20 m (X0).
4. **Skalering og aggregering.** Samme sigmoid-funksjon som `NO_GJEN_001`;
   arealvektet gjennomsnitt per region, per SSB 50 km-rute og nasjonalt,
   med bootstrap-standardfeil (`ecTools::ea_spread`, 1000 trekninger, fast
   seed).

To innstillinger er avgjørende og håndteres automatisk:

- Normaliseringen for satellittbilder som er bygget inn i modellen, **må
  hoppes over** for sjekkpunktet for flyfoto.
- Polygonverdiene **må aggregeres med gjennomsnitt, ikke median**, fordi
  fordelingen av pikselverdier er høyreskjev.

Begge er forklart i [`docs/METHODOLOGY_CANOPY_HEIGHT.md`](docs/METHODOLOGY_CANOPY_HEIGHT.md).
Feil på ett av punktene endrer resultatet vesentlig.

**Validering.** Mot kronehøyde fra laserdata på de 46 testpolygonene som
har begge: r = 0,95, MAE = 0,31 m. Det er like godt som eller bedre enn
originalens egen validering på alle mål.

**Resultater (n = 24 026 polygoner):**

| Region | Indikator | Gjennomsnittlig høyde | n |
|---|---|---|---|
| Midt-Norge | 0,988 | 0,80 m | 6 754 |
| Nord-Norge | 0,972 | 0,75 m | 5 642 |
| Vestlandet | 0,971 | 1,15 m | 2 618 |
| Østlandet | 0,877 | 3,01 m | 6 286 |
| Sørlandet | 0,802 | 3,89 m | 2 726 |
| **Norge** | **0,957** | 0,68 m | 24 026 |

Gjennomsnittlig høyde er uvektet per region, men arealvektet for Norge.
Derfor er den nasjonale høyden lavere enn i noen av regionene.

De to gjengroingsindikatorene er nær hverandre i fire regioner (forskjell
på 0,005–0,03 fra `NO_GJEN_001`), der de bruker de samme referansene. Sørlandet skiller seg ut (0,80 mot
0,95); der er 69 % av polygonene naturlig tresatt våtmark, se kjente
begrensninger.

**Referanser**

- Tolan, J., Yang, H.-I., Nosarzewski, B., Couairon, G., Vo, H. V.,
  Brandt, J., Spore, J., Majumdar, S., Haziza, D., Vamaraju, J.,
  Moutakanni, T., Bojanowski, P., Johns, T., White, B., Tiecke, T., &
  Couprie, C. (2024). Very high resolution canopy height maps from RGB
  imagery using self-supervised vision transformer and convolutional
  decoder trained on aerial lidar. *Remote Sensing of Environment, 300*,
  113888. https://doi.org/10.1016/j.rse.2023.113888
- NINAs original: [NINAnor/ecRxiv, NO_GJEN_002](https://github.com/NINAnor/ecRxiv).

## 3. Forutsetninger / Dependencies

Maskinvare, programvare, KI-verktøy og R-versjon: se
[hoved-README](../README.md#3-forutsetninger--dependencies).

- **R-pakker:** låst i [`renv.lock`](renv.lock). Viktigst: `sf`, `terra`,
  `dplyr`, `ggplot2` og `ecTools` (se `NO_GJEN_001`).
- **Python (bare for nye prediksjoner):** Python 3.9 med PyTorch 2.0.1 på
  CPU, låst i `src/chm_model/pyproject.toml` og `uv.lock`. Python 3.9 er
  eldre enn malens krav (> 3.11), men er versjonen modellen er laget for,
  og den de publiserte prediksjonene er laget med. Oppsett og kjente
  fallgruver: [`docs/CHM_MODEL_SETUP.md`](docs/CHM_MODEL_SETUP.md).
- **GPU:** trengs ikke. Sjekkpunktet som brukes, er komprimert for CPU.
- **Ytelse:** fra de lagrede prediksjonene tar beregningen noen minutter.
  Nye nasjonale prediksjoner tar ca. 90 timer: 114 406 bildeuttrekk for
  24 521 polygoner, hvorav 45,6 timer er modellkjøring.

## 4. Struktur

| Mappe | Innhold |
|---|---|
| `R/` | All R-kode: nedlasting, kobling mot ortofoto (`orthophoto_source.R`), kjøring av modellen per polygon, validering, beregningen (`NO_GJEN_002_national_pipeline.R`), eksport og kart. `fetch_eth_canopy_height.R` og `validate_eth_canopy_height.R` hører til en tidligere, forkastet midlertidig løsning med satellittbasert kronehøyde (ETH, Sentinel-2), beholdt for dokumentasjon; se metodedokumentet. |
| `src/` | `run_national_by_region.ps1` (den nasjonale modellkjøringen) og `chm_model/`: vår innpakning av modellen (`predict_tiles.py`), røyktest og Python-miljøet. Selve modellen lastes ned, se `docs/CHM_MODEL_SETUP.md`. |
| `config/` | `orthophoto_access.template.txt`. Kopieres til `orthophoto_access.txt` (gitignored) for å peke på egne bilder. |
| `docs/` | `METHODOLOGY_CANOPY_HEIGHT.md` (hvorfor metoden er som den er) og `CHM_MODEL_SETUP.md`. Indikatordokument på engelsk etter NINAs ecRxiv-mal: `NO_GJEN_002.qmd` (kilde) og `NO_GJEN_002.html`. Lages på nytt med `quarto render docs/NO_GJEN_002.qmd`. Koden vises, men kjøres ikke; resultatene leses fra `outputs/`. |
| `data/OpenS_data/` | De lagrede prediksjonene per polygon og referansetabellene fra `NO_GJEN_001`. Store inndata (NiN, bioklimatiske soner) lastes ned. |
| `outputs/results/` | Kart og tabeller fra beregningen. |
| `outputs/deliverables/` | Indikatoren i plattformformatet. |

## 5. Input / Output

### Input

| Datasett | Kilde og versjon | Lastet ned | Hentes med |
|---|---|---|---|
| Ortofoto, 50 cm RGB | Kommersiell nasjonal mosaikk, produktår 2025; flyvningene spenner over flere år | Lest 2026-09-04 til 2026-09-17 | Brukerens egen kilde, se under |
| Høydemodell for trær | Meta HighResCanopyHeight, sjekkpunkt `compressed_SSLhuge_aerial.pth` (Apache-2.0) | 2026-09 | Se `docs/CHM_MODEL_SETUP.md` |
| Prediksjoner per polygon | Egen kjøring, frosset 2026-09-17 (15 MB, med sjekksummer og logger) | – | Ligger i repoet: `data/OpenS_data/meta_chm_national_RAW_2026-09-17/` |
| NiN-naturtyper | Miljødirektoratet, FILEGDB, EPSG:4326 | 2026-07-28 | `R/fetch_nin_data.R` |
| Bioklimatiske soner | Moen-sonene, Miljødirektoratets kartjeneste (lag «soner2017») | 2026-07-20 | `R/fetch_bioclim_zones.R` |
| Referanse for god tilstand (30 m) og skogreferanse (20 m) | Fra `NO_GJEN_001` | – | Ligger i repoet |
| SSB 50 km-rutenett | Fra `NO_GJEN_001` (`R/build_ssb_grids.R`) | 2026-07-21 | Ligger i repoet |

**Egne bilder.** Bildene bak de publiserte tallene er kommersielle data
med en lisens som ikke tillater videreformidling av bildene eller
tilgangsinformasjonen. Ingenting i repoet identifiserer leverandøren.
Bildene må være 3-bånds RGB, 8 bit, **0,5 m eller finere**, i projisert
koordinatsystem (EPSG:25833 for Norge), som GeoTIFF, COG eller VRT. En
COG over nett må støtte HTTP range-forespørsler; mosaikken lastes aldri
ned i sin helhet. Kilden settes på en av to måter:

```powershell
# 1. miljøvariabler (har forrang)
$env:ORTHOPHOTO_SOURCE_PATH    = "D:/bilder/ortofoto_50cm.tif"          # lokal fil eller VRT
$env:ORTHOPHOTO_SOURCE_PATH    = "/vsicurl/https://din.server/orto.tif" # COG over nett
$env:ORTHOPHOTO_SOURCE_USERPWD = "bruker:passord"                       # bare ved innlogging

# 2. eller kopier malen og fyll den ut (den utfylte filen er gitignored)
copy config\orthophoto_access.template.txt config\orthophoto_access.txt
```

Bilder trengs bare for å lage nye prediksjoner eller beregne indikatoren
for et nytt år. Den publiserte indikatoren kan beregnes på nytt uten
bilder.

### Output

I `outputs/deliverables/`:

- `NO_GJEN_002_indicatorMap_region.rds` – landsdeler (primær).
- `NO_GJEN_002_indicatorMap_grid50km.rds` – SSB 50 km-ruter med data.
- `NO_GJEN_002_indicatorMap_polygon.rds` – hvert NiN-våtmarkspolygon med
  verdi (NiN er åpne data).
- `NO_GJEN_002_values.csv` / `.xlsx` – verditabell med nasjonal verdi,
  tilleggskolonner og metadata.
- `NO_GJEN_002_map.png`.

Kolonner som i `NO_GJEN_001`, men `v` er gjennomsnittlig predikert
høyde per polygon. Årstall `2025` er produktåret for ortofotomosaikken.

## 6. Installasjon / Kjøring

Sett opp R-miljøet som beskrevet i [hoved-README](../README.md#6-installasjon--kjøring).

**Fra de lagrede prediksjonene (minutter, uten bilder):**

1. `R/fetch_nin_data.R`
2. `R/fetch_bioclim_zones.R`
3. `R/NO_GJEN_002_national_pipeline.R` – beregningen.
4. `R/export_deliverables.R` – leveransefilene.
5. `R/make_report_map.R` – rapportkartet.

**Nye prediksjoner (krever bilder, ca. 90 timer nasjonalt):**

1. Sett opp modellen: [`docs/CHM_MODEL_SETUP.md`](docs/CHM_MODEL_SETUP.md).
2. Sett opp tilgang til bildene (se over).
3. `src/run_national_by_region.ps1` – kjører region for region, med
   sjekkpunkter. Et avbrudd koster bare partiet som pågikk. Sett
   `$env:RSCRIPT` hvis R ikke ligger på standardstien.
4. Valider før resultatene tas i bruk: `R/validate_meta_chm_orthophoto.R`
   sammenligner med kronehøyde fra laserdata på testpolygonene.

**Variant.** `GJEN002_SKOG_SCALE=1m` bruker den eldre skogreferansen på
1 m til sammenligning (utdata med suffiks `_skog1m`).

**Kontroll.** Den nasjonale kjøringen ble fullført uten feil og uten
manglende verdier i alle fem regioner. To kjøringer av beregningen etter
hverandre gir identiske resultater.

**Kjente begrensninger**

- **Resultatet avhenger av bildene.** Den publiserte kjøringen brukte en
  nasjonal mosaikk med produktår 2025, men flyvningene spenner over flere
  år. Det er det viktigste forbeholdet ved sammenligning mellom regioner.
- **Indeksen metter for åpen myr.** 62 % av polygonene får over 0,99,
  fordi sigmoid-funksjonen er flat nær referansen. Det er greit for en
  tilstandsverdi, men misvisende som et kontinuerlig mål på høyde.
- **495 polygoner (2 %) er utelatt**, fordi de ligger i fire strata
  (region × bioklimatisk sone) uten referanse for god tilstand.
- **Populasjonen er en annen enn i `NO_GJEN_001`:** her alle kartlagte
  NiN-våtmarkspolygoner, der et stratifisert utvalg av AR5 myr. De to
  indikatorene kan ikke byttes om.
- **Naturlig tresatt våtmark trekker ned verdiene i sør.** Populasjonen
  omfatter tresatte naturtyper (særlig sumpskog), som referansen for god
  tilstand utelater. De utgjør 69 % av polygonene på Sørlandet og 72 % på
  Østlandet, og skåres som gjengrodd fordi de sammenlignes med åpen
  våtmark. Uten dem ville verdiene vært 0,98 på både Sørlandet (levert:
  0,80) og Østlandet (levert: 0,88), og 0,99 for Norge (levert: 0,96).
- **Predikerte høyder er mye høyere i sør** (median 2,5–3,5 m) enn ellers
  (under 0,2 m). Det skyldes i hovedsak de tresatte typene. Årstid og
  flyår for bildene kan også spille inn.

## 7. Lisens / Rettigheter

Se [**LICENSE**-filen](LICENSE.md). Bildene og tilgangsinformasjonen er
ikke en del av repoet og kan ikke deles. Modellen er Apache-2.0 og lastes
ned fra Meta. Nedlastede data er underlagt lisensene til kildene.
