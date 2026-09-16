# NO_GJEN_001 — Gjengroing (Woody Encroachment), Wetlands

Open-source, self-contained reconstruction of NINA's wetland woody-
encroachment indicator. Every input is either fetched from a public
source or independently reconstructed - no NINA-internal access is
required to run this, though the preferred data source for two of the
core computations (see below) does require access your collaborators
already have.

Developed under the documentation standard of NINA's
[ecRxiv](https://github.com/NINAnor/ecRxiv) publishing platform for
Ecosystem Condition indicators. This is an independent reconstruction and
not an official NINA product; it has not gone through ecRxiv's
publication workflow.

This is one indicator's subfolder within a larger multi-indicator repo
(5 indicators planned in total). Everything below is self-contained to
this folder - all scripts resolve paths relative to their own location,
not to the repo root.

## What this indicator measures

For each sampled wetland location, compares its actual vegetation
height (from LiDAR canopy-height data) against a "good condition"
reference height (from good-condition NiN wetland polygons) and a
"poor condition" forest-height anchor (tree cover = fully encroached).
A sigmoid scaling maps this onto a 0-1 condition score - shorter
vegetation relative to the reference is better. Aggregated to
bioclimatic-zone strata, a 50km grid, and national/regional levels.

## Folder structure

| Folder | Contents |
|---|---|
| `Main/` | The real pipeline, `NO_GJEN_001_wetland_pipeline_OpenSource.R` - a single self-contained file (consolidated from what were 4 separate source()-linked files in the original project folder, purely for readability; no behavior change). |
| `Fetch/` | Scripts that download or build each input. Run these first. |
| `Data/OpenS_data/` | Everything the pipeline reads/writes, flat (no NINA/OpenS split - none of this data is actually gated). |
| `Results/` | Final maps, tables, and exported shapefiles/CSVs. |
| `Results_TEST_AOI/` | Created by `Fetch/quick_test_small_aoi.R` - small-region smoke-test output, not a real result (gitignored). |

## How to run it (in order)

1. `Fetch/fetch_bioclim_zones.R` - Moen bioclimatic zones (public ArcGIS service).
2. `Fetch/fetch_disturbance.R` - Senf et al. forest disturbance/clear-cut map (Zenodo).
3. `Fetch/fetch_osm_buildings.R` - national OpenStreetMap building footprints.
4. `Fetch/fetch_nin_data.R` - national NiN nature-type dataset (wetland reference polygons).
5. `Fetch/build_ssb_grids.R` - dissolves Kartverket's open 1km grid into the 10km/50km grids used for aggregation.
6. `Fetch/build_ar50_wetland_lidar_coverage.R` - **run this even if you have AR5 access.** Produces `dtm1_tile_footprint.gpkg`, required by every CHM extraction regardless of population source, plus the AR50 wetland fallback data.
7. `Fetch/build_ar50_skog.R` - the AR50 forest fallback data.
8. `Fetch/build_refvaatmark_30m.R` - the wetland "good condition" reference heights (Stage 5 input). Needs steps 4 and 6. Evaluates the LiDAR canopy height at 30 m inside every good-condition NiN wetland polygon, as the original reference is defined - see "Reference heights" below for why the scale matters. ~40 min, network-bound, checkpointed (safe to interrupt and re-run). Prints a per-stratum comparison against the published reference table at the end.
9. **If you have AR5 access** (your collaborators do): place `AR5-skog-myr.gpkg` at the repo's `Indikatorer`-equivalent root (one level above this indicator's folder tree, matching the original project layout - adjust the path in `extract_ar5_skog_myr.R` if your repo root is laid out differently), then run `Fetch/extract_ar5_skog_myr.R`. If you skip this, the pipeline automatically falls back to the AR50 data from steps 6-7 - see "AR5 vs. AR50" below.
10. `Main/NO_GJEN_001_wetland_pipeline_OpenSource.R` - the actual indicator computation. First run computes Stage 4/6's forest-reference and population heights from scratch (national stratified sampling + CHM extraction against Kartverket's live LiDAR service) and caches the results; later runs read the cache instantly. In practice this is quick, not the hours-long worst case you might expect from "national stratified sampling" - a full cold-cache run (both stages, ~25,000 points each, 8 parallel workers) took under 5 minutes end to end on a normal laptop. Stage 5 reads step 8's table.

Each script has a 3-tier working-directory fallback and runs the same
way from RStudio, `Rscript script.R`, or `source("script.R")`.

### Quick test, without the full run

Once AR5 or AR50 skog/myr data exists (steps 6-9 above), `Fetch/
quick_test_small_aoi.R` runs the *real, unmodified* Main script against
one small region (default Nord-Norge) instead of the whole country -
useful to confirm your setup actually works in a few minutes, without
waiting on the multi-hour national run described below. It temporarily
swaps in a small-region subset of the AR5/AR50 skog and myr layers,
hides Stage 4/6's cached outputs so Main is forced through the real
compute path (Stage 5's reference table from step 8 is a national
prerequisite, not a cache, and is left in place), runs Main as a
genuine separate process, and restores the
real data, caches, and `Results/` folder afterward - Main itself is
never modified and has no awareness this exists. Output:
`Results_TEST_AOI/` (gitignored - not a real result, just a smoke-test
artifact) with a console line comparing the test region's index against
the real national run's value for that region if one exists. Set
`GJEN001_TEST_REGION` to test a different region (Nord-Norge,
Midt-Norge, Vestlandet, Østlandet, Sørlandet).

## Estimated run time (first run, cold cache) - read this before you start

**Budget at least 2 hours** for a genuinely cold-cache run through every
`Fetch/` step plus `Main`. That's the real observed wall-clock time from
our own from-scratch verification run.

This is much higher than you'd guess from watching the console: `Main`
prints a "took X sec" line after each CHM extraction (tens of seconds
each), and naively adding those up suggests the whole thing should
finish in well under 15 minutes. In practice it did not - real elapsed
time was over 2 hours end to end. The per-step numbers the scripts print
only measure the core computation inside that step; they don't capture
everything around it: R/package startup on every script invocation,
network latency and variance across the Zenodo/Kartverket/OSM fetches
(especially `fetch_osm_buildings.R`'s national `.pbf` download on a
genuinely cold cache), and CPU/disk contention once the 8 parallel CHM
workers are competing with everything else on the machine. Treat the
console's self-reported per-step timings as a floor, not a ceiling.

Of that, `Fetch/build_refvaatmark_30m.R` alone is ~40 min: it reads
DTM1/DOM1 for 8,200 polygons over HTTP. It is checkpointed, so an
interrupted run resumes where it stopped.

Once every `Fetch/` step has been run once and `Main`'s Stage 4/6
caches exist, re-running `Main` is fast (well under a minute) - the
2+ hour budget is a one-time, first-run cost.

## AR5 vs. AR50 - read this before your first run

Two of the three core computations (Stage 4: forest reference heights;
Stage 6: wetland population heights) need a national forest/wetland
polygon layer. There are two options, tried in this order automatically:

- **AR5** (preferred) - finer boundaries, but personal/organizational
  access only, not publicly fetchable. Your collaborators have this
  access, so this is the default path for this project.
- **AR50** (automatic fallback) - NIBIO, fully public (NLOD-open), no
  access request needed. Coarser boundaries than AR5 (results will
  differ slightly - e.g. one real stratum's forest reference height was
  3.97m on AR5 vs. 2.60m on AR50 - expected, not a bug). Exists so this
  pipeline can eventually run for someone with zero personal access at
  all, which matters for publication even though it isn't a blocker for
  this project's own collaborators.

Whichever source gets used is always printed to the console and tagged
in the cached output file (a `population_source` column/attribute), so
it's traceable after the fact, not silently blended.

## Verification

This folder's full pipeline (every `Fetch/` script plus `Main`, AR5
path) has been run end to end on a cold cache with no NINA-drive access
of any kind: all seven fetch/build scripts completed and matched the
original pipeline's known feature counts exactly, and the final run
produced 21,026 wetland polygons with a valid indicator value -
identical to the original (non-migrated) pipeline's result. Nothing
here is untested guesswork.

`Fetch/quick_test_small_aoi.R` has also been run for real, most
recently after the 30 m reference change: a Nord-Norge-only pass on AR5
produced index 0.9698 for that region - an exact match to the full
national run's own Nord-Norge value - confirming the small-region
shortcut reproduces the real compute path faithfully, not just a
superficially-passing stub. The same test on the AR50 fallback gives
0.9759: the expected AR5/AR50 difference (coarser AR50 wetland polygons
sample slightly taller vegetation, coarser AR50 forest polygons give a
lower forest anchor), not a Stage 5 effect - the reference table is
identical in both runs.

The 30 m reference build (`Fetch/build_refvaatmark_30m.R`, added
2026-09) was run nationally in this layout and `Main` re-run on it:
15 of 20 strata fall within 0.5-2x of the published reference table
(4 of 20 with the earlier 1 m method), the same 21,026 polygons get a
value, and the index values are identical to the project-folder run of
the same method. Current region means: Nord-Norge 0.970, Midt-Norge
0.946, Vestlandet 0.943, Østlandet 0.899, Sørlandet 0.941.

## R environment

Packages needed: `sf`, `terra`, `dplyr`, `tidyr`, `tibble`, `readr`,
`stringr`, `ggplot2`, `gridExtra`, `RColorBrewer`, `viridis`, `scales`,
plus `ecTools` (installed from GitHub, NOT CRAN or the obvious repo
name - the package's actual `remotes::install_github()` name is
`NINAnor/eaTools`, but its installed package name is `ecTools`; the
current master branch has renamed the function this pipeline needs, so
install a pinned commit instead:
`remotes::install_github("NINAnor/eaTools@e9480b4b977f4a15597e64f649e43b2dd8dc4bfc")`).

## Reference heights - the evaluation scale

The wetland "good condition" reference (Stage 5) is defined in the
original indicator as the median canopy height per good-condition NiN
wetland polygon with the 1 m LiDAR canopy-height model evaluated at
30 m, then the median across polygons per region x bioclim stratum.
The scale is part of the definition: at 1 m an open bog is a few
centimetres almost everywhere, while a 30 m cell (900 m^2) averages in
scattered trees and, for sub-hectare polygons, the forest edge - the
same polygons give 5-20x higher values at 30 m. `Fetch/build_
refvaatmark_30m.R` reproduces the 30 m evaluation on open data and is
the default. The earlier 1 m point-sampling reconstruction is kept in
`Main` as a switchable legacy variant (`GJEN001_REF_VARIANT=1m`,
outputs suffixed `_OpenSource_1m`); it is what produced the 2-16x
shortfall against the published table this README used to list as an
open limitation. Its effect on the final index is small but systematic
(region means +0.002 to +0.018, Østlandet and Sørlandet most).

Residual differences from the published table are a matter of polygon
set, not method: in the strata that still differ most (Sørlandet SB/MB,
Nord-Norge NB), 65-90 % of the good-condition polygons in the current
NiN download were mapped in 2023-2025 and postdate the polygon set the
published table was built from. The current download is the correct
input for a current reconstruction; the published table is used for
comparison, not as ground truth.

## Known limitations

- **AR5/AR50's plain forest/wetland classification has no equivalent to
  NiN's V2 "sumpskog" (swamp-forest) tree-cover carve-out** - a
  classification-scheme gap, not something either data source's finer
  resolution can fix. Documented, not addressed.
- Full build history, every real bug found and fixed, and the reasoning
  behind each methodology decision: see the project memory this
  migration was built from (not included in this folder) or ask
  whoever set this repo up for the detailed build log.
