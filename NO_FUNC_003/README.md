# NO_FUNC_003 – Funksjonell plantesammensetning i våtmark-2026

- **Norsk tittel**: Vegetasjonsindikatorer for lys, fuktighet, pH og nitrogen i våtmark
- **Prosjekteier**: Miljødirektoratet
- **Oppdragstaker**: Sállir Natur AS
- **Leveringsdato**: 30.11.2026
- **Del av**: [Indikatorutvikling for våtmark-2026](../README.md)

Beregner tilstanden i artssammensetningen på våtmarksflatene i
arealrepresentativ naturovervåking (ANO), ut fra plantenes
indikatorverdier for lys, fuktighet, pH og nitrogen.

- **English**: Functional plant community indicators for wetlands: light,
  moisture, pH and nitrogen indicator values of the species recorded in
  ANO wetland plots, scaled against reference distributions per NiN main
  type.
- **Norwegian**: Vegetasjonsindikatorer for våtmark: artenes
  indikatorverdier for lys, fuktighet, pH og nitrogen i ANO-flater i
  våtmark, skalert mot referansefordelinger per NiN-hovedtype.

## 1. Bidragsytere / Kontakt

Se [hoved-README](../README.md#1-bidragsytere--kontakt).

## 2. Formål / Bakgrunn

**Overvåkingsprogram.** ANO (arealrepresentativ naturovervåking,
Miljødirektoratet) kartlegger faste punkter over hele landet med en
omløpstid på fem år. På hver flate registreres karplantearter og
NiN-naturtype. Indikatoren bruker våtmarksflatene (NiN-hovedtype V1–V8).

**Metode.**

1. For hver flate beregnes et artsvektet gjennomsnitt (community-weighted
   mean) av indikatorverdiene for lys, fuktighet, pH og nitrogen (Tyler
   et al., 2021).
2. Referansefordelingen for hver NiN-hovedtype bygges ved bootstrap av
   Artsdatabankens generaliserte artslister (datasett B12, planter og lav
   på myr), etter samme bootstrap som NINAs `indBoot.freq()`. Det finnes
   referanser for V1 (åpen jordvannsmyr), V2 (myr- og sumpskogsmark) og
   V3 (nedbørsmyr), som dekker 97 % av våtmarksflatene i ANO (2 990 av
   3 083).
3. Hver flate skaleres mot referansen for sin hovedtype. Hver side skaleres
   for seg: medianen i referansen gir 1, grenseverdien gir 0,6 og enden av
   skalaen gir 0. For de tosidige indikatorene multipliseres de to sidene,
   som i NINAs kode.
4. Nasjonale og regionale verdier for de fire indikatorene kommer fra
   NINAs modell: ordnet beta-regresjon (`glmmTMB`, familie `ordbeta`) med
   ANO-lokalitet som tilfeldig effekt. `i` er modellens gjennomsnitt, `sd`
   er standardavviket til 1000 trekninger.

| ID (foreløpig) | Indikator | Skalering |
|---|---|---|
| `NO_FULI_003` | Vegetasjonsindikator for lys | tosidig, grenser = 0,025- og 0,975-kvantilene |
| `NO_FUMO_003` | Vegetasjonsindikator for fuktighet | tosidig, grenser = 0,025- og 0,975-kvantilene |
| `NO_FUPH_003` | Vegetasjonsindikator for pH | tosidig, grenser = 0,025- og 0,975-kvantilene |
| `NO_FUNI_003` | Vegetasjonsindikator for nitrogen | ensidig (bare anrikning), grense = 0,95-kvantilen |

Inndelingen i fire indikatorer følger NINAs tilsvarende indikatorer på
ecRxiv (NO_FULI_002, NO_FUMO_004, NO_FUNI_002/004). pH har ingen
tilsvarende NINA-indikator, men er tatt med fordi den er valgt for
våtmark. Skaleringsfunksjonen gjengir `ec_normalise()` fra gjeldende
versjon av eaTools. Versjonen som er låst i dette repoet (nødvendig for
`NO_GJEN_001/002`) har en feil i synkende retning som NINA rettet i mai
2026 (eaTools-commit `ca7bc797`).

Den samlede indeksen (laveste av de åtte skalerte sidene, grenser
0,25/0,75, aggregert med median og bootstrap) er **ikke** en del av
leveransen. Den beregnes fortsatt og ligger i `outputs/supplementary/`.

**Resultater, nasjonalt (ANO-syklus 1, 2019–2024, første besøk per punkt, n = 2 778 flater):**

| Indikator | Verdi |
|---|---|
| Lys (`NO_FULI_003`) | 0,765 |
| Fuktighet (`NO_FUMO_003`) | 0,790 |
| pH (`NO_FUPH_003`) | 0,736 |
| Nitrogen (`NO_FUNI_003`) | 0,842 |

Regionale verdier og de to treårsperiodene står i
`outputs/results/NO_FUNC_003_factor_indicators.csv`.

**Referanser**

- Tyler, T., Herbertsson, L., Olofsson, J., & Olsson, P. A. (2021).
  Ecological indicator and traits values for Swedish vascular plants.
  *Ecological Indicators, 120*, 106923.
  https://doi.org/10.1016/j.ecolind.2020.106923
- NINAs originale indikatorer: [NINAnor/ecRxiv](https://github.com/NINAnor/ecRxiv).

## 3. Forutsetninger / Dependencies

Maskinvare, programvare, KI-verktøy og R-versjon: se
[hoved-README](../README.md#3-forutsetninger--dependencies).

- **R-pakker:** låst i [`renv.lock`](renv.lock). Viktigst: `sf`,
  `tidyverse`, `readxl`, `glmmTMB`, `writexl`, `conflicted`.
- **Ytelse:** hele kjeden tar ca. 3 minutter (målt 175 sekunder).
  Bootstrap av referansene tar ca. 1 minutt av dette.

## 4. Struktur

| Mappe | Innhold |
|---|---|
| `R/` | All kode: nedlasting, referansetabell, beregning, eksport, kart. |
| `data/OpenS_data/` | Nedlastede inndata (ANO, B12 og Tyler et al. er gitignored) og referansetabellen `wet_ref_openS.csv`. |
| `data/NINA/spatial/` | Regioner og kystlinje fra NINAnor/ecosystemCondition (CC BY 4.0). |
| `docs/` | Indikatordokument på engelsk etter NINAs ecRxiv-mal: `NO_FUNC_003.qmd` (kilde) og `NO_FUNC_003.html`. Lages på nytt med `quarto render docs/NO_FUNC_003.qmd` (Quarto 1.9). Koden vises, men kjøres ikke; resultatene leses fra `outputs/`. |
| `outputs/results/` | Kart og tabeller fra beregningen, inkludert verdier per flate (`NO_FUNC_003_plots.gpkg`/`.csv`). |
| `outputs/deliverables/` | De fire indikatorene i plattformformatet. |
| `outputs/supplementary/` | Den samlede indeksen `NO_FUNC_003` i samme format (ikke levert). |

## 5. Input / Output

### Input

| Datasett | Kilde og versjon | Lastet ned | Hentes med |
|---|---|---|---|
| ANO, nasjonal eksport (GeoPackage, ca. 60 MB) | Miljødirektoratet, [nedlasting](https://nedlasting.miljodirektoratet.no/naturovervaking/naturovervaking_eksport.gpkg.zip) | 2026-07-30 | `R/fetch_ano_data.R` |
| B12, planter og lav på myr (ca. 51 MB) | Artsdatabanken, generaliserte artslistedatasett | 2026-08-03 | `R/fetch_b12_data.R` |
| Indikatorverdier for svenske karplanter | Tyler et al. (2021), tilleggsmateriale (Appendix A) | 2026-07-30 | Manuelt, se under |
| Regioner og kystlinje | NINAnor/ecosystemCondition | 2026-06-23 | Ligger i repoet |

Tyler et al. sitt tilleggsmateriale kan ikke lastes ned med skript, fordi
forlaget blokkerer automatiske nedlastinger. Last det ned fra artikkelen
(doi:10.1016/j.ecolind.2020.106923) og lagre det som
`data/OpenS_data/Tyler_data_raw.xlsx`. `R/get_tyler_data.R` sier fra hvis
filen mangler, og kontrollerer at arket `"Taxa"` finnes.

### Output

I `outputs/deliverables/`, for hver av `NO_FULI_003`, `NO_FUMO_003`,
`NO_FUPH_003` og `NO_FUNI_003`:

- `<ID>_*` – de to treårsperiodene i originalen, alle registreringer i
  periodene: `_2021` (ANO 2019–2021) og `_2024` (ANO 2022–2024).
- `<ID>_cycle1_2019to2024_*` – én hel ANO-syklus, med bare **første**
  registrering per punkt, slik at ingen punkter telles to ganger.

Hvert sett har kart per landsdel og per ANO-punkt (`.rds`), verditabell
(`.csv`/`.xlsx` med metadata) og figur (`.png`). Særskilt for denne
indikatoren:

- `v = i`, som i NINAs delte indikatorer. De artsvektede gjennomsnittene per
  flate ligger i `outputs/results/NO_FUNC_003_plots.csv`.
- `thr = 0,6` er en reell X60: grenseverdien i referansefordelingen er
  satt til 0,6 av skaleringsfunksjonen.
- Enheter: landsdel (primær) og hvert ANO-punkt i våtmark (`areaId` =
  `ano_punkt_id`).

ANO besøker hvert punkt på nytt etter fem år. Når hele andre syklus er
registrert, settes `include_cycle2 <- TRUE` (og `cycle2_last_year`) i
steg 10 av beregningsskriptet. Tabeller, kart og `<ID>_cycle2_*`-filer
lages da automatisk. Det er slått av fordi bare ca. 180 våtmarkspunkter
var besøkt to ganger i eksporten fra 2019–2024.

## 6. Installasjon / Kjøring

Sett opp R-miljøet som beskrevet i [hoved-README](../README.md#6-installasjon--kjøring).
Kjør deretter, i rekkefølge:

1. `R/fetch_ano_data.R` – ANO-eksporten.
2. `R/fetch_b12_data.R` – B12-artslistene.
3. `R/get_tyler_data.R` – manuelt steg, se over.
4. `R/build_wet_ref_openS.R` – bygger referansetabellen fra steg 2–3.
5. `R/NO_FUNC_003_wetland_pipeline_OpenSource.R` – beregningen. Skriver
   kart og tabeller til `outputs/results/`.
6. `R/export_deliverables.R` – leveransefilene.
7. `R/make_factor_report_maps.R` – rapportkart for de fire indikatorene.

**Rask test.** Når steg 1 er kjørt, kjører `R/quick_test_small_aoi.R` det
uendrede beregningsskriptet for én region (standard Nord-Norge, velg
annen med miljøvariabelen `FUNC003_TEST_REGION`) på under ett minutt.
Testkartet havner i `outputs/results/` og er gitignored.

**Kjente begrensninger**

- **Ikke alle våtmarksflater kan skåres.** Av 3 083 registreringer av
  våtmarksflater i ANO 2019–2024 er 2 954 skåret:

  | NiN-hovedtype | Registreringer | Skåret |
  |---|---|---|
  | V1 åpen jordvannsmyr | 2 375 | 2 344 |
  | V2 myr- og sumpskogsmark | 305 | 303 |
  | V3 nedbørsmyr | 310 | 307 |
  | V4 kilde | 24 | 0 |
  | V6 våtsnøleie og snøleiekilde | 66 | 0 |
  | V8 strandsumpskogsmark | 3 | 0 |

  - **V6** har ingen referanse, heller ikke i NINAs original. Flatene er
    altså utelatt også der.
  - **V4 og V8** har referanser i NINAs original, men ingen åpen artsliste
    vi kan bygge en egen referanse fra: det finnes ingen for V8, og
    B04-listene for V4 ble vurdert som for vanskelige å tolke entydig.
    NINAs referansefil brukes ikke; referansene i dette repoet er bygget
    fra åpne kilder. Å utelate de 27 flatene endrer den samlede indeksen
    med under 0,003, mindre enn konfidensintervallet. Overskriften i
    `R/build_wet_ref_openS.R` beskriver hvordan typene kan legges til.
  - **36 registreringer av typene V1–V3** har ingen registrerte arter i
    ANO-eksporten og får derfor ingen verdi.
- **Referansen for V2 inneholder bare myrskog, ikke sumpskog.** I ANO
  kodes V2 som «myr- og sumpskogsmark», delt bare etter kalkinnhold
  (V2-C-1/2/3). Flater i sumpskog (skog på våt mineraljord) kan derfor
  ikke skilles fra myrskog (skog på torv), og de skåres sammen (303 skårede
  V2-registreringer). Referansen for V2 er bygget fra 11 artslister i B12,
  som gjelder planter og lav på myr: myrskogsmark fra middels kalkfattig
  til kalkrik, kildemyrskogsmark og strandmyrskog. Ingen av listene gjelder
  sumpskog. En sumpskogsflate sammenlignes dermed med myrskog i god
  tilstand. Sumpskog på mineraljord er trolig noe rikere på næring, så
  verdiene for nitrogen og pH kan se ut som avvik selv når de er normale
  for sumpskog. Hvor mange av V2-flatene som er sumpskog, går ikke fram av
  dataene.
- **Referanseverdiene gjelder per NiN-hovedtype** (V1, V2, V3), ikke per
  kartleggingsenhet som i NINAs original.
- **`regions.shp` har en tegnkodingsfeil** i kolonnen `region` for
  Østlandet og Sørlandet. Skriptene bruker derfor `id` (3 og 5), ikke
  navnet.

## 7. Lisens / Rettigheter

Se [**LICENSE**-filen](LICENSE.md). Nedlastede data er underlagt
lisensene til kildene. Tyler et al. sitt tilleggsmateriale deles ikke i
repoet.
