# ============================================================
# NO_FUNC_003 — Functional Plant Community Index: Wetlands
# Fully open-source, self-contained version: every input is either
# fetched from a public source or independently reconstructed, so no
# access to internal NINA files is required. Deviations from the
# original methodology are documented in this folder's README.
#
# ------------------------------------------------------------------
# INPUTS
#
#   1. ANO (Arealrepresentativ naturovervåking) field monitoring data
#      -> Fetch/fetch_ano_data.R. Public, no login (Miljødirektoratet
#      Kartkatalog dataset 2054). Produces Data/OpenS_data/ano_data/
#      naturovervaking_eksport.gpkg, read directly by Stage 2. Covers
#      2019-2024; NINA's own cached export went to 2021, so this
#      also adds a full second reporting period the original never had
#      data for. Stage 4 classifies each visit as round1 (first-ever
#      survey of that plot) or round2 (a revisit), since ANO plots are
#      revisited on a 5-year rotation.
#
#   2. Tyler et al. (2021) plant functional trait indicator values
#      -> published, open-access (Ecological Indicators 120,
#      DOI:10.1016/j.ecolind.2020.106923), but MANUAL DOWNLOAD ONLY -
#      ScienceDirect/ResearchGate/DOAJ all block scripted fetches, so no
#      fetch script exists. Download the "Taxa" sheet from the article's
#      Supplementary content and place it at
#      Data/OpenS_data/Tyler_data_raw.xlsx. Grime (1974) CSR values are
#      not used - a different plant-strategy axis, no overlap with the
#      Light/Moisture/pH/Nitrogen indicators this pipeline needs.
#
#   3. Bootstrapped CWM reference distributions (X0/X100-style reference
#      levels per NiN wetland type x indicator)
#      -> Fetch/fetch_b12_data.R + Fetch/build_wet_ref_openS.R, producing
#      Data/OpenS_data/wet_ref_openS.csv, read by Stage 2. Reimplements
#      NINA's own indBoot.freq() bootstrap (documented, plain R code) on
#      Artsdatabanken's public "B12" generalized species-list dataset,
#      validated within ~7-15% of NINA's cached values. Covers NiN types
#      V1/V2/V3 (96.98% of real ANO wetland plots); V4/V8 (0.88%
#      combined) are not reconstructed and those plots are excluded from
#      scoring, not patched from NINA's cache. Confirmed this costs
#      under 0.003 on the final index - not material today, but NOT a
#      permanently closed gap: no public V8 species list was found as of
#      2026-08 (checked exhaustively), and V4's candidate source (B04)
#      was set aside as too fragile to untangle rather than confirmed
#      unusable. Recheck if a new/reworked Artsdatabanken list appears -
#      see build_wet_ref_openS.R's header for how to extend it.
#
#   4. Five-region delineation for Norway (regions.shp) and the national
#      coastline outline (outlineOfNorway_EPSG25833.shp), Data/NINA/
#      spatial/ - reused as-is, shared across this project's indicators;
#      no fetch script written for either yet.
# ------------------------------------------------------------------
# ============================================================

# ===========================================================
# STAGE 1: Load packages
# Load order matters: conflicted must be first so its rules
# apply when subsequent packages are attached.
# ===========================================================

library(conflicted)  # explicit conflict resolution; must load before other packages
library(sf)          # spatial objects, st_read / st_join / st_intersection
library(tidyverse)   # dplyr, tidyr (pivot_longer), stringr (word/str_replace), purrr (pmap)
library(readxl)      # reads Tyler et al.'s raw .xlsx directly - no CSV conversion needed

# dplyr wins over any masked functions (e.g. plyr::filter, stats::filter)
conflict_prefer_all("dplyr", quiet = TRUE)

# Set working directory to the folder containing this script.
# In RStudio: Session > Set Working Directory > To Source File Location, or run the line below.
# Three-tier fallback: RStudio -> source()'d (sys.frame) -> plain
# `Rscript file.R` (commandArgs' --file= entry) - works from any of the
# three, unlike a plain 2-tier fallback which errors under plain Rscript.
if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args   <- commandArgs(trailingOnly = FALSE)
  file_match <- grep("^--file=", cmd_args)
  tried <- tryCatch({
    if (length(file_match) > 0) {
      setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[file_match]))))
    } else {
      setwd(dirname(sys.frame(1)$ofile))
    }
    TRUE
  }, error = function(e) FALSE)
  if (!tried) message("Note: keeping current working directory (", getwd(), ").")
}
# All relative paths below are anchored to: NO_FUNC_003_Migration/Main/

ano_dir    <- file.path("..", "Data", "OpenS_data", "ano_data") # input 1, fetch_ano_data.R's output
tyler_path <- file.path("..", "Data", "OpenS_data", "Tyler_data_raw.xlsx")  # input 2, manually downloaded


# ===========================================================
# STAGE 2: Load raw data.
#
# ANO_SurveyPoint/ANO_Art column names come back lowercase from the raw
# GPKG ("globalid"/"parentglobalid") - renamed immediately below so
# every downstream stage can reference GlobalID/ParentGlobalID directly.
#
# ANO.sp  = species cover records (long format, one row per species per plot)
# ANO.geo = plot-level metadata + NiN ecosystem classification + geometry
# ind.Tyler = functional trait indicator values per species
# wet_ref_openS = quantile-summarized CWM reference per hovedtype x
#   indicator (see build_wet_ref_openS.R)
# ===========================================================

ano_gpkg_path <- file.path(ano_dir, "naturovervaking_eksport.gpkg")
if (!file.exists(ano_gpkg_path)) {
  stop("Missing required file: ", ano_gpkg_path, "\n",
       "Run fetch_ano_data.R first to produce it.")
}

ANO.geo <- st_read(ano_gpkg_path, layer = "ANO_SurveyPoint", quiet = TRUE) |>
  rename(GlobalID = globalid)

ANO.sp <- st_read(ano_gpkg_path, layer = "ANO_Art", quiet = TRUE) |>
  st_drop_geometry() |>
  rename(GlobalID = globalid, ParentGlobalID = parentglobalid)

if (!file.exists(tyler_path)) {
  stop("Missing required file: ", tyler_path, "\n",
       "No automated fetch is possible (ScienceDirect/ResearchGate/DOAJ ",
       "all block scripted downloads) - manually download the 'Taxa' ",
       "data sheet from https://www.sciencedirect.com/science/article/pii/S1470160X20308621 ",
       "(look for \"Supplementary content\"/\"Data availability\") and ",
       "place the raw .xlsx there. See this script's header for detail.")
}

# Raw column names are human-readable ("Soil reaction (pH)", "Nitrogen
# (N)") - renamed to the identifiers Stage 3/7 reference below.
# "Light"/"Moisture" already match, so only these two need renaming.
# Columns 35-73 (38 NiN vegetation-type presence flags) are left as-is,
# unused by this indicator.
ind.Tyler <- read_excel(tyler_path, sheet = "Taxa") |>
  rename(
    Soil_reaction_pH = `Soil reaction (pH)`,
    Nitrogen         = `Nitrogen (N)`
  ) |>
  as.data.frame()
# as.data.frame() is NOT cosmetic: read_excel() returns a tibble, and
# Stage 3 uses base-R bracket indexing (ind.Tyler[, "species"]), which
# drops to a plain vector on a data.frame but stays a one-column tibble
# on a tibble - silently breaking word()/as.factor() downstream.

# Reads the reference table build_wet_ref_openS.R produces (V1/V2/V3
# only, see that script's header for method and the V4/V8 coverage
# gap). HOVEDTYPE granularity (V1/V2/V3), coarser than NINA's original
# per-subtype columns (e.g. "V1-C4h") - Stage 7's matching key uses the
# hovedtype prefix accordingly, not the exact subtype code.
wet_ref_path <- file.path("..", "Data", "OpenS_data", "wet_ref_openS.csv")
if (!file.exists(wet_ref_path)) {
  stop("Missing required file: ", wet_ref_path, "\n",
       "Run fetch_b12_data.R then build_wet_ref_openS.R first to produce it ",
       "(a substantial ~1 min computation - fetches/parses Artsdatabanken's ",
       "B12 dataset and runs a 1000-iteration bootstrap per NiN type).")
}
wet_ref_openS <- read_csv(wet_ref_path, show_col_types = FALSE)


# ===========================================================
# STAGE 3: Harmonise Tyler indicator data
#
# Grime (1974) CSR indicator values are not used for wetlands - a
# separate plant-strategy axis (CC/SS/RR) with no overlap with the
# Light/Moisture/Soil_reaction_pH/Nitrogen indicators Stage 7 needs.
#
# Goal: one row per binomial species name, no duplicates.
# Subspecies/hybrid rows that collapse to the same binomial
# are removed, keeping the "primary" taxon record.
# ===========================================================

names(ind.Tyler)[1] <- "species"
ind.Tyler$species   <- as.factor(ind.Tyler$species)
ind.Tyler <- ind.Tyler[!is.na(ind.Tyler$species), ]

ind.Tyler[, "species.orig"] <- ind.Tyler[, "species"]
ind.Tyler[, "species"]      <- word(ind.Tyler[, "species"], 1, 2)

# Tyler: drop hybrids / subspecies whose trimmed binomials are duplicated
ind.Tyler <- ind.Tyler |>
  filter(!species.orig %in% c(
    "Ammophila arenaria x Calamagrostis epigejos",
    "Anemone nemorosa x ranunculoides",
    "Armeria maritima ssp. elongata",
    "Asplenium trichomanes ssp. quadrivalens",
    "Calystegia sepium ssp. spectabilis",
    "Campanula glomerata 'Superba'",
    "Dactylorhiza maculata ssp. fuchsii",
    "Erigeron acris ssp. droebachensis",
    "Erigeron acris ssp. politus",
    "Erysimum cheiranthoides L. ssp. alatum",
    "Euphrasia nemorosa x stricta var. brevipila",
    "Galium mollugo x verum",
    "Geum rivale x urbanum",
    "Hylotelephium telephium (ssp. maximum)",
    "Juncus alpinoarticulatus ssp. rariflorus",
    "Lamiastrum galeobdolon ssp. argentatum",
    "Lathyrus latifolius ssp. heterophyllus",
    "Medicago sativa ssp. falcata",
    "Medicago sativa ssp. x varia",
    "Monotropa hypopitys ssp. hypophegea",
    "Ononis spinosa ssp. hircina",
    "Ononis spinosa ssp. procurrens",
    "Pilosella aurantiaca ssp. decolorans",
    "Pilosella aurantiaca ssp. dimorpha",
    "Pilosella cymosa ssp. gotlandica",
    "Pilosella cymosa ssp. praealta",
    "Pilosella officinarum ssp. peleteranum",
    "Poa x jemtlandica (Almq.) K. Richt.",
    "Poa x herjedalica Harry Sm.",
    "Ranunculus peltatus ssp. baudotii",
    "Sagittaria natans x sagittifolia",
    "Salix repens ssp. rosmarinifolia",
    "Stellaria nemorum L. ssp. montana",
    "Trichophorum cespitosum ssp. germanicum"
  ))

# Tyler: handle Hieracium sect. duplicates then drop remaining hybrids
ind.Tyler <- ind.Tyler |>
  mutate(species = gsub("sect. ", "", species.orig))
ind.Tyler[, "species"] <- word(ind.Tyler[, "species"], 1, 2)
ind.Tyler <- ind.Tyler[!duplicated(ind.Tyler[, "species"]), ]
ind.Tyler$species <- as.factor(ind.Tyler$species)

# Synonymy alignment: ind.dat taxonomy → ANO/NiN taxonomy
# (ind.dat = ind.Tyler; kept under its own name since Stage 4/7 below
# reference ind.dat's Light/Moisture/Soil_reaction_pH/Nitrogen columns)
ind.dat <- ind.Tyler
ind.dat <- ind.dat |>
  mutate(species = str_replace(species, "Aconitum lycoctonum",    "Aconitum septentrionale")) |>
  mutate(species = str_replace(species, "Carex simpliciuscula",   "Kobresia simpliciuscula")) |>
  mutate(species = str_replace(species, "Carex myosuroides",      "Kobresia myosuroides")) |>
  mutate(species = str_replace(species, "Clinopodium acinos",     "Acinos arvensis")) |>
  mutate(species = str_replace(species, "Artemisia rupestris",    "Artemisia norvegica")) |>
  mutate(species = str_replace(species, "Cherleria biflora",      "Minuartia biflora")) |>
  mutate(species = str_replace(species, "Rosa vosagica",          "Rosa vosagiaca"))
ind.dat$species <- as.factor(ind.dat$species)


# ===========================================================
# STAGE 4: Harmonise ANO monitoring data
# - Derive main ecosystem type (hovedtype) and ecosystem class
# - Decode NiN disturbance variable codes to numeric
# - Standardise species names to genus + epithet
# - Merge ANO species records with indicator values
# - Keep only wetland plots (V1–V8)
# ===========================================================

# Extract the 3-character NiN main-type code from the mapping unit string
ANO.geo$hovedtype_rute <- gsub("-", "", substr(ANO.geo$kartleggingsenhet_1m2, 1, 3))

# Classify into broad ecosystem classes; wetland = V1–V8
ANO.geo$hovedoekosystem_rute <- ANO.geo$hovedtype_rute
ANO.geo <- ANO.geo |>
  mutate(hovedoekosystem_rute = recode(
    hovedoekosystem_rute,
    "V1" = "Wetland", "V2" = "Wetland", "V3" = "Wetland",
    "V4" = "Wetland", "V5" = "Wetland", "V6" = "Wetland",
    "V7" = "Wetland", "V8" = "Wetland",
    "T4"  = "Forest",  "T30" = "Forest",
    "T3"  = "Mountain","T7"  = "Mountain","T14" = "Mountain","T22" = "Mountain",
    "T31" = "Seminat", "T32" = "Seminat", "T33" = "Seminat", "T34" = "Seminat",
    "V9"  = "Seminat", "V10" = "Seminat",
    "T2"  = "Natopen", "T8"  = "Natopen", "T11" = "Natopen", "T12" = "Natopen",
    "T13" = "Natopen", "T15" = "Natopen", "T16" = "Natopen", "T18" = "Natopen",
    "T21" = "Natopen", "T24" = "Natopen", "T29" = "Natopen"
  ))

# Rename and decode NiN disturbance variables.
# [OPEN SOURCE FIX] The original script renamed these by POSITIONAL index
# (colnames(ANO.geo)[42:47] <- ...), which silently breaks against the
# fetched GPKG: the cached RDS has an extra column ("art_alle_registrert",
# not present in the raw public export) that shifts everything after it
# by one position, so columns 42:47 in the cache are 41:46 in the fetched
# data. Fixed by renaming these six columns BY NAME instead (they're
# named identically - "bv_7gr_gi" etc. - in both the cache and the raw
# GPKG, confirmed directly) - robust regardless of column position/source.
ANO.geo <- ANO.geo |>
  rename(
    groeftingsintensitet = bv_7gr_gi,
    bruksintensitet       = bv_7jb_ba,
    beitetrykk            = bv_7jb_bt,
    slatteintensitet      = bv_7jb_si,
    tungekjoretoy         = bv_7tk,
    slitasje              = bv_7se
  )
decode_nin <- function(x, prefix) as.numeric(gsub("X", "NA", gsub(prefix, "", x)))
ANO.geo$groeftingsintensitet <- decode_nin(ANO.geo$groeftingsintensitet, "7GR-GI_")
ANO.geo$bruksintensitet      <- decode_nin(ANO.geo$bruksintensitet,      "7JB-BA_")
ANO.geo$beitetrykk           <- decode_nin(ANO.geo$beitetrykk,           "7JB-BT_")
ANO.geo$slatteintensitet     <- decode_nin(ANO.geo$slatteintensitet,     "7JB-SI_")
ANO.geo$tungekjoretoy        <- decode_nin(ANO.geo$tungekjoretoy,        "7TK_")
ANO.geo$slitasje             <- decode_nin(ANO.geo$slitasje,             "7SE_")

# Classify each survey instance as round 1 (first-ever visit to that
# ano_flate_id) or round 2 (a revisit) - 89% of 2022-2024 plots are
# brand-new round-1 coverage; the remainder are round-2 revisits,
# overwhelmingly exactly 5 years after a flate's first visit, matching
# ANO's documented 5-year rotation design. Carried through the rest of
# the pipeline; Stage 10 adds a round-based breakdown alongside the
# existing period-based one (the main NO_FUNC_003/NO_FUNC_003_supp
# tables are unaffected - still every plot, both rounds).
ano_first_year <- ANO.geo |>
  st_drop_geometry() |>
  group_by(ano_flate_id) |>
  summarise(first_year = min(aar, na.rm = TRUE), .groups = "drop")

ANO.geo <- ANO.geo |>
  left_join(ano_first_year, by = "ano_flate_id") |>
  mutate(ano_round = ifelse(aar == first_year, "round1", "round2")) |>
  select(-first_year)

cat("ANO survey rounds: round1 (first visit) =", sum(ANO.geo$ano_round == "round1"),
    ", round2 (revisit) =", sum(ANO.geo$ano_round == "round2"), "\n")

# Standardise ANO species names: trim to binomial, fix capitalisation
ANO.sp$Species <- word(ANO.sp$art_navn, 1, 2)
ANO.sp$Species <- str_to_title(ANO.sp$Species)
ANO.sp$Species <- gsub("( .*)","\\L\\1", ANO.sp$Species, perl = TRUE)
ANO.sp$Species <- gsub("( .*)","\\L\\1", ANO.sp$Species, perl = TRUE)

# Synonymy fixes: align ANO species names to the ind.dat taxonomy
ANO.sp <- ANO.sp |>
  mutate(Species = str_replace(Species, "Agrostis hyemalis",          "Agrostis scabra")) |>
  mutate(Species = str_replace(Species, "Antennaria lapponica",       "Antennaria alpina")) |>
  mutate(Species = str_replace(Species, "Antennaria porsildii",       "Antennaria alpina")) |>
  mutate(Species = str_replace(Species, "Arctous alpinus",            "Arctous alpina")) |>
  mutate(Species = str_replace(Species, "Betula tortuosa",            "Betula pubescens")) |>
  mutate(Species = str_replace(Species, "Blysmopsis rufa",            "Blysmus rufus")) |>
  mutate(Species = str_replace(Species, "Cardamine nymanii",          "Cardamine pratensis")) |>
  mutate(Species = str_replace(Species, "Carex adelostoma",           "Carex buxbaumii")) |>
  mutate(Species = str_replace(Species, "Carex concolor",             "Carex aquatilis")) |>
  mutate(Species = str_replace(Species, "Carex leersii",              "Carex echinata")) |>
  mutate(Species = str_replace(Species, "Carex myosuroides",          "Kobresia myosuroides")) |>
  mutate(Species = str_replace(Species, "Carex paupercula",           "Carex magellanica")) |>
  mutate(Species = str_replace(Species, "Carex simpliciuscula",       "Kobresia simpliciuscula")) |>
  mutate(Species = str_replace(Species, "Carex viridula",             "Carex flava")) |>
  mutate(Species = str_replace(Species, "Chamaepericlymenum suecicum","Cornus suecia")) |>
  mutate(Species = str_replace(Species, "Cicerbita alpina",           "Lactuca alpina")) |>
  mutate(Species = str_replace(Species, "Cornus suecia",              "Cornus suecica")) |>
  mutate(Species = str_replace(Species, "Cotoneaster scandinavicus",  "Cotoneaster integerrimus")) |>
  mutate(Species = str_replace(Species, "Dactylorhiza viridis",       "Coeloglossum viride")) |>
  mutate(Species = str_replace(Species, "Diphasiastrum alpinum",      "Lycopodium alpinum")) |>
  mutate(Species = str_replace(Species, "Diphasiastrum complanatum",  "Lycopodium complanatum")) |>
  mutate(Species = str_replace(Species, "Dryopteris affinis",         "Dryopteris filix-mas")) |>
  mutate(Species = str_replace(Species, "Empetrum hermaphroditum",    "Empetrum nigrum")) |>
  mutate(Species = str_replace(Species, "Elymus alaskanus",           "Elymus kronokensis")) |>
  mutate(Species = str_replace(Species, "Festuca prolifera",          "Festuca rubra")) |>
  mutate(Species = str_replace(Species, "Galium album",               "Galium mollugo")) |>
  mutate(Species = str_replace(Species, "Galium elongatum",           "Galium palustre")) |>
  mutate(Species = str_replace(Species, "Helictotrichon pratense",    "Avenula pratensis")) |>
  mutate(Species = str_replace(Species, "Helictotrichon pubescens",   "Avenula pubescens")) |>
  mutate(Species = str_replace(Species, "Hieracium alpina",           "Hieracium Alpina")) |>
  mutate(Species = str_replace(Species, "Hieracium alpinum",          "Hieracium Alpina")) |>
  mutate(Species = str_replace(Species, "Hieracium hieracium",        "Hieracium Hieracium")) |>
  mutate(Species = str_replace(Species, "Hieracium hieracioides",     "Hieracium umbellatum")) |>
  mutate(Species = str_replace(Species, "Hieracium murorum",          "Hieracium Vulgata")) |>
  mutate(Species = str_replace(Species, "Hieracium oreadea",          "Hieracium Oreadea")) |>
  mutate(Species = str_replace(Species, "Hieracium prenanthoidea",    "Hieracium Prenanthoidea")) |>
  mutate(Species = str_replace(Species, "Hieracium vulgata",          "Hieracium Vulgata")) |>
  mutate(Species = str_replace(Species, "Hieracium pilosella",        "Pilosella officinarum")) |>
  mutate(Species = str_replace(Species, "Hieracium vulgatum",         "Hieracium umbellatum")) |>
  mutate(Species = str_replace(Species, "Hierochloã« alpina",  "Hierochlö alpina")) |>
  mutate(Species = str_replace(Species, "Hierochloã« hirta",   "Hierochlö hirta")) |>
  mutate(Species = str_replace(Species, "Hierochloã« odorata", "Hierochlö odorata")) |>
  mutate(Species = str_replace(Species, "Huperzia appressa",          "Huperzia selago")) |>
  mutate(Species = str_replace(Species, "Huperzia arctica",           "Huperzia selago")) |>
  mutate(Species = str_replace(Species, "Hylotelephium maximum",      "Sedum telephium")) |>
  mutate(Species = str_replace(Species, "Listera cordata",            "Neottia cordata")) |>
  mutate(Species = str_replace(Species, "Leontodon autumnalis",       "Scorzoneroides autumnalis")) |>
  mutate(Species = str_replace(Species, "Loiseleuria procumbens",     "Kalmia procumbens")) |>
  mutate(Species = str_replace(Species, "Minuartia rubella",          "Sabulina rubella")) |>
  mutate(Species = str_replace(Species, "Minuartia stricta",          "Sabulina stricta")) |>
  mutate(Species = str_replace(Species, "Mycelis muralis",            "Lactuca muralis")) |>
  mutate(Species = str_replace(Species, "Omalotheca supina",          "Gnaphalium supinum")) |>
  mutate(Species = str_replace(Species, "Omalotheca norvegica",       "Gnaphalium norvegicum")) |>
  mutate(Species = str_replace(Species, "Omalotheca sylvatica",       "Gnaphalium sylvaticum")) |>
  mutate(Species = str_replace(Species, "Oreopteris limbosperma",     "Thelypteris limbosperma")) |>
  mutate(Species = str_replace(Species, "Oxycoccus microcarpus",      "Vaccinium microcarpum")) |>
  mutate(Species = str_replace(Species, "Oxycoccus palustris",        "Vaccinium oxycoccos")) |>
  mutate(Species = str_replace(Species, "Phalaris minor",             "Phalaris arundinacea")) |>
  mutate(Species = str_replace(Species, "Pinus unicinata",            "Pinus mugo")) |>
  mutate(Species = str_replace(Species, "Poa alpigena",               "Poa pratensis")) |>
  mutate(Species = str_replace(Species, "Poa angustifolia",           "Poa pratensis")) |>
  mutate(Species = str_replace(Species, "Poa ×jemtlandica",     "Poa alpina")) |>
  mutate(Species = str_replace(Species, "Potentilla anserina",        "Argentina anserina")) |>
  mutate(Species = str_replace(Species, "Potentilla arenosa",         "Potentilla nivea")) |>
  mutate(Species = str_replace(Species, "Pyrola grandiflora",         "Pyrola rotundifolia")) |>
  mutate(Species = str_replace(Species, "Rubus fruticosus",           "Rubus plicatus")) |>
  mutate(Species = str_replace(Species, "Rumex alpestris",            "Rumex acetosa")) |>
  mutate(Species = str_replace(Species, "Stellaria uliginosa",        "Stellaria alsine")) |>
  mutate(Species = str_replace(Species, "Syringa emodi",              "Syringa vulgaris")) |>
  mutate(Species = str_replace(Species, "Taraxacum crocea",           "Taraxacum officinale")) |>
  mutate(Species = str_replace(Species, "Taraxacum croceum",          "Taraxacum officinale")) |>
  mutate(Species = str_replace(Species, "Trientalis europaea",        "Lysimachia europaea")) |>
  mutate(Species = str_replace(Species, "Trifolium pallidum",         "Trifolium pratense")) |>
  mutate(Species = str_replace(Species, "Veratrum lobelianum",        "Veratrum album"))

# Merge ANO species records with indicator values; drop rows without species/cover
ANO.sp.ind <- merge(
  x = ANO.sp[, c("Species", "art_dekning", "ParentGlobalID")],
  y = ind.dat[, c("species", "Light", "Moisture", "Soil_reaction_pH", "Nitrogen")],
  by.x = "Species", by.y = "species", all.x = TRUE
)
ANO.sp.ind <- ANO.sp.ind[!is.na(ANO.sp.ind$Species), ]
ANO.sp.ind <- ANO.sp.ind[!is.na(ANO.sp.ind$art_dekning), ]
rm(ANO.sp)

# Restrict ANO plot metadata to wetland types only (V1–V8)
ANO.wet <- ANO.geo[ANO.geo$hovedoekosystem_rute == "Wetland", ]
row.names(ANO.wet) <- seq_len(nrow(ANO.wet))

ANO.wet$GlobalID             <- as.factor(ANO.wet$GlobalID)
ANO.wet$ano_flate_id         <- as.factor(ANO.wet$ano_flate_id)
ANO.wet$ano_punkt_id         <- as.factor(ANO.wet$ano_punkt_id)
ANO.wet$hovedoekosystem_rute <- as.factor(ANO.wet$hovedoekosystem_rute)
ANO.wet$kartleggingsenhet_1m2 <- as.factor(sub("\\ .*", "", ANO.wet$kartleggingsenhet_1m2))
ANO.wet$hovedtype_rute        <- as.factor(ANO.wet$hovedtype_rute)


# ===========================================================
# STAGE 5: Derive wetland scaling values from the reference table.
#
# [OPEN SOURCE] wet_ref_openS (loaded in Stage 2) already has q25/median/
# q75 precomputed per hovedtype x indicator - build_wet_ref_openS.R did
# the 1000-iteration bootstrap and quantile derivation itself, so this
# stage is now just a PIVOT into the same long-format `wet.ref.val`
# structure Stage 7 expects (grunn/Ind/Rv/Gv/maxmin), not a re-derivation.
# `grunn` is a HOVEDTYPE (V1/V2/V3) here, not NINA's original exact NiN
# sub-code (e.g. "V1-C4h") - a deliberate coarsening (see Stage 2).
# Stage 7's matching key uses the hovedtype prefix accordingly, not the
# exact subtype code. Plots typed V4/V8 (no reference available) or V5-
# V7 (never covered by this indicator at all) get no match and are
# skipped - see Stage 7.
# ===========================================================

get_q <- function(ht, ind, q) wet_ref_openS[[q]][wet_ref_openS$hovedtype == ht & wet_ref_openS$indicator == ind]
hovedtyper <- unique(wet_ref_openS$hovedtype)

# Build long-format reference/limit value table (one row per indicator x
# hovedtype x side). Each two-sided indicator has a "1" side (lower tail)
# and "2" side (upper tail). Rv = reference value (median), Gv = limit
# value (q25 or q75) - same maxmin scale endpoints as the original.
wet.ref.val <- bind_rows(
  data.frame(grunn = hovedtyper, Ind = "Light1",
             Rv = sapply(hovedtyper, get_q, ind = "Light", q = "median"),
             Gv = sapply(hovedtyper, get_q, ind = "Light", q = "q25"), maxmin = 1),
  data.frame(grunn = hovedtyper, Ind = "Light2",
             Rv = sapply(hovedtyper, get_q, ind = "Light", q = "median"),
             Gv = sapply(hovedtyper, get_q, ind = "Light", q = "q75"), maxmin = 7),
  data.frame(grunn = hovedtyper, Ind = "Moist1",
             Rv = sapply(hovedtyper, get_q, ind = "Moisture", q = "median"),
             Gv = sapply(hovedtyper, get_q, ind = "Moisture", q = "q25"), maxmin = 1),
  data.frame(grunn = hovedtyper, Ind = "Moist2",
             Rv = sapply(hovedtyper, get_q, ind = "Moisture", q = "median"),
             Gv = sapply(hovedtyper, get_q, ind = "Moisture", q = "q75"), maxmin = 12),
  data.frame(grunn = hovedtyper, Ind = "pH1",
             Rv = sapply(hovedtyper, get_q, ind = "Soil_reaction_pH", q = "median"),
             Gv = sapply(hovedtyper, get_q, ind = "Soil_reaction_pH", q = "q25"), maxmin = 1),
  data.frame(grunn = hovedtyper, Ind = "pH2",
             Rv = sapply(hovedtyper, get_q, ind = "Soil_reaction_pH", q = "median"),
             Gv = sapply(hovedtyper, get_q, ind = "Soil_reaction_pH", q = "q75"), maxmin = 8),
  data.frame(grunn = hovedtyper, Ind = "Nitrogen1",
             Rv = sapply(hovedtyper, get_q, ind = "Nitrogen", q = "median"),
             Gv = sapply(hovedtyper, get_q, ind = "Nitrogen", q = "q25"), maxmin = 1),
  data.frame(grunn = hovedtyper, Ind = "Nitrogen2",
             Rv = sapply(hovedtyper, get_q, ind = "Nitrogen", q = "median"),
             Gv = sapply(hovedtyper, get_q, ind = "Nitrogen", q = "q75"), maxmin = 9)
)
wet.ref.val$grunn <- as.factor(wet.ref.val$grunn)
wet.ref.val$Ind   <- as.factor(wet.ref.val$Ind)


# ===========================================================
# STAGE 6: Scaling functions
# scal()   — truncates at 0 and 1 (used for the 2-sided index)
# scal.2() — no truncation (raw scaled values, used for diagnostics)
# Both use four variables from the calling environment:
#   val    = observed CWM
#   ref    = reference value (median of bootstrapped distribution)
#   lim    = limit value (0.25 or 0.75 quantile)
#   maxmin = theoretical min or max of the indicator scale
# Output is a 0–1 score where 1 = reference condition.
# ===========================================================

r.s <- 1    # scaled reference value
l.s <- 0.6  # scaled limit value
a.s <- 0    # scaled absence/extreme value

scal <- function(val, ref, lim, maxmin) {
  x <- numeric()
  if (maxmin < ref) {
    if (val >= ref)                    { x <- 1 }
    if (val < ref  && val >= lim)      { x <- l.s + (val - lim) * ((r.s - l.s) / (ref - lim)) }
    if (val < lim  && val > maxmin)    { x <- a.s + (val - maxmin) * ((l.s - a.s) / (lim - maxmin)) }
    if (val <= maxmin)                 { x <- 0 }
  } else {
    if (val <= ref)                    { x <- 1 }
    if (val > ref  && val <= lim)      { x <- r.s - ((r.s - l.s) * (val - ref) / (lim - ref)) }
    if (val > lim)                     { x <- l.s - (l.s * (val - lim) / (maxmin - lim)) }
    if (val >= maxmin)                 { x <- 0 }
  }
  return(x)
}

scal.2 <- function(val, ref, lim, maxmin) {
  x <- numeric()
  if (maxmin < ref) {
    if (val >= ref)                    { x <- l.s + (val - lim) * ((r.s - l.s) / (ref - lim)) }
    if (val < ref  && val >= lim)      { x <- l.s + (val - lim) * ((r.s - l.s) / (ref - lim)) }
    if (val < lim  && val > maxmin)    { x <- a.s + (val - maxmin) * ((l.s - a.s) / (lim - maxmin)) }
    if (val <= maxmin)                 { x <- 0 }
  } else {
    if (val <= ref)                    { x <- r.s - ((r.s - l.s) * (val - ref) / (lim - ref)) }
    if (val > ref  && val <= lim)      { x <- r.s - ((r.s - l.s) * (val - ref) / (lim - ref)) }
    if (val > lim  && val < maxmin)    { x <- l.s - (l.s * (val - lim) / (maxmin - lim)) }
    if (val >= maxmin)                 { x <- 0 }
  }
  return(x)
}


# ===========================================================
# STAGE 7: Calculate CWM indicators and scale them
# For each wetland ANO plot:
#   1. Compute the community-weighted mean (CWM) of each
#      indicator as: sum(cover_i * trait_i) / sum(cover_i)
#   2. Scale the CWM against the reference/limit values
#      using scal() and scal.2()
# Indicators for wetlands: Light, Moisture, pH, Nitrogen
# (two-sided each → 8 scaled indicator columns per plot)
# ===========================================================

# Initialise results containers
wet_indicators <- c("Light1","Light2","Moist1","Moist2","pH1","pH2","Nitrogen1","Nitrogen2")

results.wet <- list()
results.wet[["original"]] <- ANO.wet
st_geometry(results.wet[["original"]]) <- NULL

nvar <- ncol(results.wet[["original"]])
for (col in wet_indicators) results.wet[["original"]][, col] <- NA_real_
results.wet[["original"]]$richness <- NA_real_

results.wet[["scaled"]]        <- results.wet[["original"]]
results.wet[["non-truncated"]] <- results.wet[["original"]]

# Calculate and scale indicators for each wetland plot
for (i in seq_len(nrow(ANO.wet))) {
  tryCatch({

    gid      <- as.character(ANO.wet$GlobalID[i])
    # wet.ref.val's `grunn` is a HOVEDTYPE (V1/V2/V3), not NINA's original
    # exact NiN sub-code (e.g. "V1-C-1a") - see Stage 5. Extract just the
    # hovedtype prefix from ANO's own (finer) code for matching.
    nin_type <- sub("-.*", "", as.character(results.wet[["original"]][i, "kartleggingsenhet_1m2"]))

    # Skip if the NiN type has no reference values
    if (!nin_type %in% levels(wet.ref.val$grunn)) next
    # Skip if no species recorded at this plot
    if (nrow(ANO.sp.ind[ANO.sp.ind$ParentGlobalID == gid, ]) == 0) next

    calc_ind <- function(trait_col, ind1_name, ind2_name) {
      dat <- ANO.sp.ind[ANO.sp.ind$ParentGlobalID == gid,
                        c("art_dekning", trait_col)]
      results.wet[["original"]][i, "richness"] <<- nrow(dat)
      dat <- dat[!is.na(dat[[trait_col]]), ]
      if (nrow(dat) == 0) return()

      cwm <- sum(dat[["art_dekning"]] * dat[[trait_col]], na.rm = TRUE) /
             sum(dat[["art_dekning"]], na.rm = TRUE)

      # Lower side
      rv1 <- wet.ref.val[wet.ref.val$Ind == ind1_name & wet.ref.val$grunn == nin_type, "Rv"]
      gv1 <- wet.ref.val[wet.ref.val$Ind == ind1_name & wet.ref.val$grunn == nin_type, "Gv"]
      mm1 <- wet.ref.val[wet.ref.val$Ind == ind1_name & wet.ref.val$grunn == nin_type, "maxmin"]
      results.wet[["scaled"]][i, ind1_name]        <<- scal(cwm, rv1, gv1, mm1)
      results.wet[["non-truncated"]][i, ind1_name] <<- scal.2(cwm, rv1, gv1, mm1)
      results.wet[["original"]][i, ind1_name]      <<- cwm

      # Upper side
      rv2 <- wet.ref.val[wet.ref.val$Ind == ind2_name & wet.ref.val$grunn == nin_type, "Rv"]
      gv2 <- wet.ref.val[wet.ref.val$Ind == ind2_name & wet.ref.val$grunn == nin_type, "Gv"]
      mm2 <- wet.ref.val[wet.ref.val$Ind == ind2_name & wet.ref.val$grunn == nin_type, "maxmin"]
      results.wet[["scaled"]][i, ind2_name]        <<- scal(cwm, rv2, gv2, mm2)
      results.wet[["non-truncated"]][i, ind2_name] <<- scal.2(cwm, rv2, gv2, mm2)
      results.wet[["original"]][i, ind2_name]      <<- cwm
    }

    calc_ind("Light",           "Light1",    "Light2")
    calc_ind("Moisture",        "Moist1",    "Moist2")
    calc_ind("Soil_reaction_pH","pH1",       "pH2")
    calc_ind("Nitrogen",        "Nitrogen1", "Nitrogen2")

  }, error = function(e) cat("ERROR row", i, ":", conditionMessage(e), "\n"))
}

# Build 2-sided result: use non-truncated values, cap at 1 (values > 1 → NA)
results.wet[["2-sided"]] <- results.wet[["non-truncated"]]
for (col in wet_indicators) {
  results.wet[["2-sided"]][[col]][results.wet[["2-sided"]][[col]] > 1] <- NA
}


# ===========================================================
# STAGE 8: Build the functional plant community index (fpci)
# The index for each plot = the LOWEST scoring indicator
# ("worst-rule" / verste-styrer principle).
# For wetlands: min of Light1, Light2, Moist1, Moist2,
#               pH1, pH2, Nitrogen1, Nitrogen2.
# Inf (produced by pmap when all inputs are NA) → NA.
# ===========================================================

res.wet <- results.wet[["2-sided"]]

res.wet <- res.wet |>
  mutate(
    fpci.min = as.numeric(pmap(
      list(Light1, Light2, Moist1, Moist2, pH1, pH2, Nitrogen1, Nitrogen2),
      min, na.rm = TRUE
    )),
    fpci.min = na_if(fpci.min, Inf)
  )

# Warnings expected at this stage due to plots with no species recorded (NA for all indicators → Inf → NA for fpci.min).

# ===========================================================
# STAGE 9: Add spatial region information
# Joins each ANO plot to one of the five Norwegian regions
# so that regional indices can be computed alongside the
# national index.
# ===========================================================

# Restore geometry for spatial join
st_geometry(res.wet) <- st_geometry(ANO.wet)

spatial_dir <- file.path("..", "Data", "NINA", "spatial")

nor <- st_read(
  file.path(spatial_dir, "outlineOfNorway_EPSG25833.shp"),
  quiet = TRUE
) |>
  st_as_sf() |>
  st_transform(crs = st_crs(ANO.wet))

reg <- st_read(
  file.path(spatial_dir, "regions.shp"),
  quiet = TRUE
) |>
  st_as_sf() |>
  st_transform(crs = st_crs(ANO.wet))

reg$region <- c(
  "Northern.Norway", "Central.Norway", "Eastern.Norway",
  "Western.Norway",  "Southern.Norway"
)

regnor   <- st_intersection(reg, nor)
# Warning expected here: "attribute variables are assumed to be spatially constant throughout all geometries".
# st_intersection() carries reg's and nor's non-geometry columns onto the clipped output without
# recalculating them, and sf can't verify that's valid. It is valid here: reg$region is a categorical
# label, not an area-based quantity, so clipping to Norway's coastline doesn't change which region a
# fragment belongs to. Harmless; to silence, set sf::st_agr(reg) <- "constant" (and same for nor) first.
res.wet  <- st_join(res.wet, regnor, left = TRUE)

# Pivot to long format for easy aggregation
res.wet.long <- res.wet |>
  pivot_longer(
    cols          = all_of(c(wet_indicators, "fpci.min")),
    names_to      = "fp_ind",
    values_to     = "scaled_value",
    values_drop_na = FALSE
  )


# ===========================================================
# EXPLORE: distribution of indicator values by region
# Two views of the same underlying data, at two different
# points in the pipeline:
#   1. Raw CWM (Stage 7 output, native units) — useful for
#      spotting outliers/data issues before any reference-
#      based scaling is applied.
#   2. Scaled indicators (Stage 9 output, 0-1 vs reference) —
#      the exact values that feed the Stage 10 aggregation
#      and the regional map.
# Both are printed to the session only (not saved to img/),
# since they're for exploration rather than the final report.
# ===========================================================

# --- 1. Raw CWM by region ------------------------------------------------
# Light1/Light2 (etc.) hold the same raw CWM in results.wet[["original"]] —
# the two-sidedness only appears later, during scaling — so only one
# column per trait is used here. Joined to region via GlobalID (rather
# than assuming row order matches res.wet) since st_join() in Stage 9 can
# in principle drop/duplicate rows for points that match zero/multiple regions.
region_lookup <- res.wet |>
  st_drop_geometry() |>
  select(GlobalID, region) |>
  mutate(region = str_remove(region, "\\.Norway$")) |>
  distinct(GlobalID, .keep_all = TRUE)

raw_cwm_long <- results.wet[["original"]] |>
  select(GlobalID, Light = Light1, Moisture = Moist1,
         pH = pH1, Nitrogen = Nitrogen1) |>
  left_join(region_lookup, by = "GlobalID") |>
  filter(!is.na(region)) |>
  pivot_longer(cols = c(Light, Moisture, pH, Nitrogen),
               names_to = "trait", values_to = "cwm") |>
  filter(!is.na(cwm))

raw_cwm_plot <- ggplot(raw_cwm_long, aes(x = region, y = cwm, fill = region)) +
  geom_violin(trim = FALSE, alpha = 0.7, show.legend = FALSE) +
  geom_boxplot(width = 0.1, outlier.size = 0.5, show.legend = FALSE) +
  facet_wrap(~ trait, scales = "free_y") +
  labs(
    title = "Rå CWM-verdier per region (før skalering)",
    x = NULL, y = "Community-weighted mean"
  ) +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

print(raw_cwm_plot)

# --- 2. Scaled indicators by region --------------------------------------
# Same long-format table (res.wet.long) that feeds Stage 10, so this shows
# exactly what's being summarized into NO_FUNC_003 / NO_FUNC_003_supp.
# fpci.min (the composite index) is excluded — it's already the map/table's
# headline number; this is about the underlying pH/moisture/etc. indicators.
scaled_long <- res.wet.long |>
  filter(fp_ind != "fpci.min", !is.na(scaled_value)) |>
  mutate(region = str_remove(region, "\\.Norway$"))

scaled_plot <- ggplot(scaled_long, aes(x = region, y = scaled_value, fill = region)) +
  geom_violin(trim = FALSE, alpha = 0.7, show.legend = FALSE) +
  geom_boxplot(width = 0.1, outlier.size = 0.5, show.legend = FALSE) +
  geom_hline(yintercept = l.s, linetype = "dashed", color = "red") +
  facet_wrap(~ fp_ind, ncol = 4) +
  labs(
    title    = "Skalerte indikatorverdier per region",
    subtitle = "Stiplet linje = grense for god tilstand (0.6)",
    x = NULL, y = "Skalert verdi (0-1)"
  ) +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

print(scaled_plot)


# ===========================================================
# STAGE 10: Aggregate to NO_FUNC_003 final product
# Compute national and regional median and 0.25/0.75
# quantiles for each indicator and for the index (fpci.min),
# separately for the two 3-year reporting periods.
# Final output: NO_FUNC_003 (index only) and
#               NO_FUNC_003_supp (all underlying indicators).
# ===========================================================

res.quant <- c(0.25, 0.50, 0.75)

# Bootstrap CI on the median: resamples the observed per-plot scaled_value
# (with replacement, same size as the original sample) B times, recomputes
# the median each time, and takes the 2.5/97.5 percentiles of that
# distribution. This estimates sampling uncertainty in the regional/national
# median given the number of ANO plots monitored, distinct from `low`/`high`,
# which describe the spread of scaled_value across the sampled plots
# themselves rather than the precision of the median estimate.
boot.n     <- 1000
boot.probs <- c(0.025, 0.975)
set.seed(1)  # reproducible bootstrap draws

boot_median_ci <- function(x, n = boot.n, probs = boot.probs) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(c(NA_real_, NA_real_))
  if (length(x) == 1) return(c(x, x))  # sample(x,...) mis-treats length-1 x as a range
  boot_medians <- replicate(n, median(sample(x, length(x), replace = TRUE)))
  quantile(boot_medians, probs, na.rm = TRUE)
}

all_indicators <- c("fpci.min", wet_indicators)
regions        <- c("Norway", "Northern.Norway", "Central.Norway",
                    "Western.Norway", "Eastern.Norway", "Southern.Norway")
periods        <- list(
  "2019to2021" = c(2019, 2020, 2021),
  "2022to2024" = c(2022, 2023, 2024)
)

agg_list <- list()

for (period_name in names(periods)) {
  yrs <- periods[[period_name]]

  med <- low <- high <- n_obs <- boot_low <- boot_high <-
    data.frame(Indicator = all_indicators,
               matrix(NA_real_, nrow = length(all_indicators), ncol = length(regions),
                      dimnames = list(NULL, regions)))

  for (i in seq_along(all_indicators)) {
    ind <- all_indicators[i]

    # National
    df  <- res.wet.long[res.wet.long$fp_ind == ind & res.wet.long$aar %in% yrs,
                        c("scaled_value", "ano_flate_id")]
    res <- quantile(df$scaled_value, res.quant, na.rm = TRUE)
    low[i,  "Norway"] <- res[1]
    med[i,  "Norway"] <- res[2]
    high[i, "Norway"] <- res[3]
    n_obs[i,"Norway"] <- sum(!is.na(df$scaled_value))
    boot_ci <- boot_median_ci(df$scaled_value)
    boot_low[i,  "Norway"] <- boot_ci[1]
    boot_high[i, "Norway"] <- boot_ci[2]

    # Regional
    for (rgn in regions[-1]) {
      df2  <- res.wet.long[res.wet.long$fp_ind == ind &
                             res.wet.long$aar %in% yrs &
                             res.wet.long$region == rgn,
                           c("scaled_value", "ano_flate_id")]
      res2 <- quantile(df2$scaled_value, res.quant, na.rm = TRUE)
      low[i,  rgn] <- res2[1]
      med[i,  rgn] <- res2[2]
      high[i, rgn] <- res2[3]
      n_obs[i,rgn] <- sum(!is.na(df2$scaled_value))
      boot_ci2 <- boot_median_ci(df2$scaled_value)
      boot_low[i,  rgn] <- boot_ci2[1]
      boot_high[i, rgn] <- boot_ci2[2]
    }
  }

  agg_list[[period_name]] <- list(median = med, low = low, high = high, n = n_obs,
                                   boot_low = boot_low, boot_high = boot_high)
}

# Combine both periods into a single long data frame
make_long <- function(lst, period) {
  cbind(
    ecosystem = "wetland",
    period    = period,
    tidyr::pivot_longer(lst[["median"]], cols = dplyr::all_of(regions),
                        names_to = "region", values_to = "median"),
    high = tidyr::pivot_longer(lst[["high"]], cols = dplyr::all_of(regions),
                               names_to = "region", values_to = "high")[["high"]],
    low  = tidyr::pivot_longer(lst[["low"]],  cols = dplyr::all_of(regions),
                               names_to = "region", values_to = "low")[["low"]],
    n    = tidyr::pivot_longer(lst[["n"]],    cols = dplyr::all_of(regions),
                               names_to = "region", values_to = "n")[["n"]],
    boot_low  = tidyr::pivot_longer(lst[["boot_low"]],  cols = dplyr::all_of(regions),
                               names_to = "region", values_to = "boot_low")[["boot_low"]],
    boot_high = tidyr::pivot_longer(lst[["boot_high"]], cols = dplyr::all_of(regions),
                               names_to = "region", values_to = "boot_high")[["boot_high"]]
  )
}

NO_FUNC_003_full <- rbind(
  make_long(agg_list[["2019to2021"]], "2019to2021"),
  make_long(agg_list[["2022to2024"]], "2022to2024")
)

# Index table: fpci.min only, with official indicator ID
NO_FUNC_003 <- NO_FUNC_003_full |>
  filter(Indicator == "fpci.min") |>
  mutate(Indicator = "NO_FUNC_003") |>
  mutate(region = str_remove(region, "\\.Norway$"))

# Supplementary table: all underlying wetland indicators
NO_FUNC_003_supp <- NO_FUNC_003_full |>
  filter(Indicator != "fpci.min") |>
  mutate(region = str_remove(region, "\\.Norway$"))

# Inspect
print(NO_FUNC_003)
print(NO_FUNC_003_supp)

# ===========================================================
# Round-based breakdown (round1 = first-ever visit to a flate, round2 =
# a revisit - see Stage 4's `ano_round` classification). Same national + regional
# median/quantile aggregation as above, grouped by ano_round instead of
# reporting period, so the effect of mixing brand-new round-1 coverage
# with round-2 revisits in the 2022-2024 period can be inspected
# separately. Does NOT change NO_FUNC_003/NO_FUNC_003_supp above (still
# every plot, both rounds, exactly as the original pipeline defines it) -
# this is a supplementary table only.
# ===========================================================

round_agg_list <- list()
for (rnd in c("round1", "round2")) {
  med <- low <- high <- n_obs <-
    data.frame(Indicator = all_indicators,
               matrix(NA_real_, nrow = length(all_indicators), ncol = length(regions),
                      dimnames = list(NULL, regions)))

  for (i in seq_along(all_indicators)) {
    ind <- all_indicators[i]

    df <- res.wet.long[res.wet.long$fp_ind == ind & res.wet.long$ano_round == rnd,
                        c("scaled_value", "ano_flate_id")]
    res <- quantile(df$scaled_value, res.quant, na.rm = TRUE)
    low[i,  "Norway"] <- res[1]; med[i,  "Norway"] <- res[2]; high[i, "Norway"] <- res[3]
    n_obs[i,"Norway"] <- sum(!is.na(df$scaled_value))

    for (rgn in regions[-1]) {
      df2 <- res.wet.long[res.wet.long$fp_ind == ind & res.wet.long$ano_round == rnd &
                            res.wet.long$region == rgn, c("scaled_value", "ano_flate_id")]
      res2 <- quantile(df2$scaled_value, res.quant, na.rm = TRUE)
      low[i,  rgn] <- res2[1]; med[i,  rgn] <- res2[2]; high[i, rgn] <- res2[3]
      n_obs[i,rgn] <- sum(!is.na(df2$scaled_value))
    }
  }
  round_agg_list[[rnd]] <- list(median = med, low = low, high = high, n = n_obs)
}

make_long_round <- function(lst, round_label) {
  cbind(
    ecosystem = "wetland",
    ano_round = round_label,
    tidyr::pivot_longer(lst[["median"]], cols = dplyr::all_of(regions),
                        names_to = "region", values_to = "median"),
    high = tidyr::pivot_longer(lst[["high"]], cols = dplyr::all_of(regions),
                               names_to = "region", values_to = "high")[["high"]],
    low  = tidyr::pivot_longer(lst[["low"]],  cols = dplyr::all_of(regions),
                               names_to = "region", values_to = "low")[["low"]],
    n    = tidyr::pivot_longer(lst[["n"]],    cols = dplyr::all_of(regions),
                               names_to = "region", values_to = "n")[["n"]]
  )
}

NO_FUNC_003_by_round <- rbind(
  make_long_round(round_agg_list[["round1"]], "round1"),
  make_long_round(round_agg_list[["round2"]], "round2")
) |>
  mutate(region = str_remove(region, "\\.Norway$"))

cat("\n=== Supplementary: round1 (first visit) vs round2 (revisit) breakdown ===\n")
print(NO_FUNC_003_by_round |> filter(Indicator == "fpci.min"))

# -----------------------------------------------------------
# Map: median wetland indicator by region
# Choropleth of the 5 Norwegian regions, coloured by
# ecological condition class using the standard Norwegian
# 5-class "økologisk tilstand" scale (Svært dårlig/Dårlig/
# Moderat/God/Svært god, each spanning 0.2 of the 0-1 scale).
# "God" (good condition) starts at l.s = 0.6, the same
# limit-value constant used in Stage 6's scal(); a.s = 0 and
# r.s = 1 anchor the floor and reference ends of the scale.
# Saved to ../img (sibling of R/ and Data/).
# -----------------------------------------------------------

map_period <- "2019to2021"  # switch to "2022to2024" once that period has data

condition_breaks <- c(a.s, 0.2, 0.4, l.s, 0.8, r.s)
condition_labels <- c("Svært dårlig", "Dårlig", "Moderat", "God", "Svært god")
# setNames() reuses the condition_labels strings directly as names, rather than
# retyping the accented labels a second time, so the fill scale's name-matching
# can't silently fail on a mismatched character encoding.
condition_colors <- setNames(
  c("#d7191c", "#fdae61", "#ffffbf", "#a6d96a", "#1a9641"),
  condition_labels
)

map_dat <- NO_FUNC_003 |>
  filter(period == map_period, region != "Norway") |>
  mutate(condition = cut(median, breaks = condition_breaks,
                          labels = condition_labels, include.lowest = TRUE))

regnor_map <- regnor |>
  mutate(region = str_remove(region, "\\.Norway$")) |>
  left_join(map_dat, by = "region")

# st_point_on_surface() guarantees a point inside each region polygon,
# unlike st_centroid(), which can land outside irregular/elongated shapes
# (e.g. Northern Norway) or over water.
label_pts <- regnor_map |>
  st_point_on_surface() |>
  mutate(
    label = ifelse(
      is.na(median),
      paste0(region, "\nIngen data"),
      sprintf("%s\n%.3f (n=%d)", region, median, n)
    )
  )

# Legend built from an invisible, ordinary geom_point() layer rather than
# geom_sf()'s own legend-key inference, which does not reliably render solid
# fill colours for classes that have no polygon in the current map data.
# The points sit on top of one real region (so the view doesn't rescale to
# fit them) and are fully transparent (alpha = 0); override.aes forces the
# legend key itself back to full opacity regardless.
dummy_xy <- st_coordinates(st_point_on_surface(regnor_map[1, ]))
legend_dummy <- data.frame(
  condition = factor(condition_labels, levels = condition_labels),
  x = dummy_xy[1, "X"],
  y = dummy_xy[1, "Y"]
)

wetland_map <- ggplot() +
  geom_sf(data = regnor_map, aes(fill = condition), color = "black", linewidth = 0.4,
          show.legend = FALSE) +
  geom_point(data = legend_dummy, aes(x = x, y = y, fill = condition),
             shape = 22, size = 6, color = "black", alpha = 0) +
  geom_sf_label(data = label_pts, aes(label = label), size = 3, lineheight = 0.9,
                fill = "white", color = "black", label.size = 0.3) +
  scale_fill_manual(
    values   = condition_colors,
    name     = "Tilstand",
    limits   = condition_labels,  # forces all 5 classes into the legend, even if unused in the data
    drop     = FALSE,
    na.value = "grey80",
    guide    = guide_legend(override.aes = list(alpha = 1))
  ) +
  labs(
    title    = "NO_FUNC_003 indikator Våtmark",
    subtitle = paste("Periode:", gsub("to", " to ", map_period)),
    caption  = "Median skalert FPCI-verdi per region. God tilstand ≥ 0.6."
  ) +
  theme_void() +
  theme(
    plot.title      = element_text(face = "bold", size = 16, hjust = 0.5),
    plot.subtitle   = element_text(size = 11, hjust = 0.5),
    plot.caption    = element_text(size = 8, hjust = 0.5),
    legend.position = "right"
  )

# [MIGRATION] Points at the Results/ folder (sibling of Main/), matching
# this repo's Main/Data/Results/Fetch/Docs layout, instead of the
# original ../img convention used in the non-migrated NO_FUNC_003 folder.
img_dir <- file.path("..", "Results")
if (!dir.exists(img_dir)) dir.create(img_dir, recursive = TRUE)

ggsave(
  filename = file.path(img_dir, paste0("NO_FUNC_003_wetland_map_", map_period, ".png")),
  plot     = wetland_map,
  width    = 11, height = 10, dpi = 300, bg = "white"
)

print(wetland_map)
