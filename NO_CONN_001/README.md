# NO_CONN_001 — Wetland Structural Connectivity

Open-source, self-contained reconstruction of NINA's wetland structural
connectivity indicator: for each mire polygon, the ratio of (distance
to nearest infrastructure) to (distance to nearest neighbouring mire
polygon). There is no NINA-original R equivalent to compare against -
the real original is 100% Google Earth Engine JavaScript, and NINA's
own metadata marks this indicator `status: incomplete`, version
`0.002`, *"Working pipeline, but not operationalised."* This is a
genuine from-scratch reconstruction, not a port of a finished product.

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

For each mire (wetland) polygon: `kvotient = distance to nearest
infrastructure / distance to nearest other mire polygon`. Higher =
infrastructure is comparatively far away = better condition. Scaled to
0-1 via a log-transform and percentile-based anchors, then area-weighted
aggregated to the 5 regions with bootstrap confidence intervals.

## Cache vs. real compute - READ THIS FIRST

A from-scratch national run of this pipeline is **20+ hours of compute**
(Østlandet alone takes ~13 hours for its distance computation). Rather
than force every collaborator to pay that cost to get a working result,
the ~2GB of derived outputs are **published as GitHub Release assets**
(`LUI_output/`, `wetland_map_simplified/`,
`connectivity_output_simplified/`).

They are not committed to the repository: several exceed GitHub's 100MB
per-file limit, and keeping them out of git history keeps the repo
small enough to clone quickly. Run **`Fetch/download_caches.R` once**
to retrieve them into `Data/`.

> **While this repository is private, that script needs a GitHub token.**
> Release assets on a private repo are not served without authentication,
> even to collaborators who can clone. Easiest fix — install the
> [GitHub CLI](https://cli.github.com/), run `gh auth login`, then in R:
>
> ```r
> Sys.setenv(GITHUB_TOKEN = system("gh auth token", intern = TRUE))
> ```
>
> Or set `GITHUB_TOKEN` to a fine-grained personal access token with read
> access to this repository. No token is needed once the repo is public.

**With the caches in place, `Main/NO_CONN_001_wetland_pipeline.R`
finishes in a few minutes**, not hours - because almost every stage
finds its cache and prints `"already present on disk - SKIPPING
(reading published cache, not recomputing)"`. **That is not the
pipeline recomputing anything.** Watch for `"SKIPPING"` vs. `"no cache
found - computing"` to know which stages are doing real work on a given
run - never judge this from elapsed time alone.

**To verify the real computation for yourself** (not just the cached
result): delete the specific cached file/folder for the stage you want
to re-run. Main's own header comments name exactly which path gates
which stage. The big one: delete the whole
`Data/connectivity_output_simplified/` folder to force a genuine
national distance recomputation - budget the full 20+ hours if you do.

## Folder structure

| Folder | Contents |
|---|---|
| `Main/` | The orchestrator, `NO_CONN_001_wetland_pipeline.R` - runs all 9 stages in order, skip-if-cached throughout. |
| `Fetch/` | The 12 scripts Main actually calls (fetch/build/compute, one per stage). |
| `Data/spatial/` | Small, essential, reused reference data (regions.shp, national outline) - no fetch script. |
| `Data/LUI_output/`, `Data/wetland_map_simplified/`, `Data/connectivity_output_simplified/` | **Published derived caches** (~2GB total), retrieved by `Fetch/download_caches.R` - see "Cache vs. real compute" above. |
| `Results/` | The final map + the mean-distance-ratio diagnostic side-check. |

Not in the repository, fetched or rebuilt on demand by `Fetch/`:
`Data/infra_index_source/` (29GB raw N50/NVE), `Data/wetland_map_source/`
(8GB raw Bakkestuen tif), `Data/nin_data/` (fast to refetch).

## How to run it

Just run `Main/NO_CONN_001_wetland_pipeline.R`. It is resumable/idempotent
by design - every stage checks its own output before running, so it's
safe to stop and restart across multiple sessions. With the published
caches downloaded, this finishes in a few minutes (see above). The
9 stages, in order: (1) fetch N50+NVE, (2) convert 2006 SOSI→GPKG
[QGIS], (3) extract/harmonize infrastructure layers, (4) compute the
national LUI index, (5) fetch the wetland map, (6) fetch NiN fallback
data, (7) per-region simplify → certified distance → infra-distance ×5
regions, (8) 0-1 scaling + regional map + bootstrap CIs, (9) diagnostic
mean-distance-ratio side-check.

Each script has a 3-tier working-directory fallback and runs the same
way from RStudio, `Rscript script.R`, or `source("script.R")`.

## External dependencies - read before deleting any cache

- **QGIS** (tested against 3.44.12) must be installed locally, purely
  for Stage 2 (2006's N50 archive is SOSI-only, and SOSI support isn't
  in the GDAL build bundled with R's own `sf` package - it IS in QGIS's
  own bundled GDAL). Fully automated via `system2()` - nobody opens
  QGIS's own interface. `Fetch/convert_n50_2006_sosi_to_gpkg.R` hardcodes
  `qgis_root <- "C:/Program Files/QGIS 3.44.12"` - edit this if your
  install is elsewhere or a different version. You only hit this
  requirement if you delete `Data/LUI_output/` and rebuild the
  infrastructure index from scratch. If QGIS truly isn't available, the
  documented fallback is a 2013/2023-only 2-point time series instead
  of the full 3-point series (not automated - needs manual script
  edits).
- **Windows + PowerShell**: Stage 5 (fetching the ~8.1GB wetland map)
  extracts its zip via PowerShell's .NET `ZipFile` class, because R's
  own `unzip()` hits a real ZIP64 limitation at this file size (confirmed,
  not a precaution). This means `Fetch/fetch_wetland_map.R`, as written,
  only runs on Windows. You only hit this if you delete
  `Data/wetland_map_simplified/` and need to rebuild it from the raw
  raster on a non-Windows machine.

## Quick test

`Fetch/compute_lui_infrastructure_index.R` already has a built-in
`LUI_TEST_AOI` environment-variable hook (set to `"oslo"` for a small
10km×10km test box instead of the full national grid) - used during
original development to sanity-check the LUI algorithm cheaply. Nord-Norge
is also already the fastest of the 5 regions for Stage 7b (~7 seconds,
vs. hours for the others, since it's NiN-only) - if you want to exercise
the real per-region compute path without committing to a multi-hour run,
delete only Nord-Norge's 3 cached files
(`Data/wetland_map_simplified/wetland_simplified_Nord-Norge.gpkg`,
`Data/connectivity_output_simplified/nord_norge_min_myr_distance_certified.gpkg`,
`Data/connectivity_output_simplified/nord_norge_connectivity_full_2023.gpkg`)
before running Main - the other 4 regions' caches stay intact, so only
Nord-Norge's fast path actually recomputes. **Actually verified, not just
described**: doing exactly this reproduced the region's known result to
7 decimal places (index 0.6477198, 4,939 final polygons) - see
Verification below. Two real bugs were found and fixed while doing this
(gate over-fetching, a nested-source() path issue) - both are fixed in
the scripts here, not just noted as caveats.

## R environment

Packages needed: `sf`, `terra`, `dplyr`, `tidyr`, `ggplot2`, `ggrepel`,
`RColorBrewer`, `RANN` (for the certified nearest-neighbour pre-filter).
No GitHub-only packages (unlike GJEN_001's `ecTools` pin) - everything
here is on CRAN.

## Verification

This migration copy's `Main` has been run end to end for real against
the published caches: every stage correctly reported `"SKIPPING"`
except Stage 8/9 (which always re-run, by design - they're cheap), no
unnecessary raw-data downloads were triggered, and the run completed in
3.3 minutes producing the exact known national result (n=97,072
finite-nonzero kvotient values; regional index: Nord-Norge 0.648,
Midt-Norge 0.974, Vestlandet 0.958, Østlandet 0.971, Sørlandet 0.976) -
identical to the original (non-migrated) pipeline's 2026-08-20 final
run.

**The genuine per-region recompute path has also been verified**, not
just the read-cache path: Nord-Norge's 3 cached files were deleted and
Main was re-run for real, forcing an actual recompute of that region
while the other 4 stayed cached. Result: exact reproduction (index
0.6477198, 4,939 final polygons, 48.6% with infrastructure within
1000m) and the national aggregate unchanged - confirming the fresh
recompute re-integrates seamlessly with the 4 still-cached regions.
This forced-recompute test is what actually caught the two real bugs
below - the earlier all-cache runs couldn't have found either one.

## Known limitations

- **`run_region_certified.R` and `compute_infra_distance_region.R` had
  a hardcoded absolute `setwd()`** pointing at a folder name
  (`NO_CONN_001`, single N) that no longer exists after this project was
  renamed to `NO_CONN_001` (double N). This was dormant in the original
  project (all 5 regions' caches already existed, so the broken line
  never actually ran) but would have broken the instant someone deleted
  a cache to force a recompute. **Fixed in this migration copy** - both
  scripts now use the standard 3-tier working-directory fallback like
  every other script here.
- **Main's Stage 5/6 gate originally over-fetched**: an all-or-nothing
  "are all 5 regions simplified" check would have downloaded the
  unnecessary ~8.1GB Bakkestuen wetland map even when only Nord-Norge's
  cache was missing - Nord-Norge sits entirely north of that map's real
  coverage and never uses it. **Fixed**: the gate now checks whether any
  *specific* missing region could actually need that data.
- **`run_region_certified.R`'s internal `source("nn_distance_certified.R")`
  broke when sourced from Main** (though not when run standalone): the
  standard 3-tier working-directory pattern relies on `commandArgs()`,
  which reflects the outermost Rscript invocation's own path regardless
  of nesting depth - harmless everywhere else in this codebase (`Main/`
  and `Fetch/` are siblings, so `"../Data/..."` resolves identically from
  either), but fatal for this one script's own further `source()` call,
  which needs to find a sibling file next to *itself*, not next to
  whatever originally launched Rscript. **Fixed** by locating the file
  relative to this script's own true location (via the R call stack),
  not the process's current working directory.
- **LCI's "other built-up areas" category (input A) has no confirmed
  N50 object type** - ambiguous even in the source paper's
  own Table 1. Not extracted; a documented, systematic minor undercount.
- **The connectivity/scaling methodology is our own reconstruction**,
  not confirmed NINA methodology - the source qmd explicitly marks
  scaling/aggregation as unfinished (GitHub issue #144). Built following
  NINA's own Kolstad et al. aggregation-pathway framework
  (`AKolstad_aggregation_manuscript.pdf`, an unpublished NINA
  manuscript - **not included in this migration copy** for that reason;
  ask whoever set this repo up if you need it).
- **Nord-Norge's wetland data is lower-fidelity** - NiN nature-type
  polygons instead of Bakkestuen et al.'s validated 90.9%-balanced-
  accuracy probability surface, since the published Bakkestuen map only
  covers up to ~63.5-64.0°N despite its "nationwide" filename/label.
- **A real prose/code discrepancy exists in NINA's source qmd** for how
  the "scaled indicator value" should be computed - the actual GEE code
  only ever computes the literal `kvotient` used here; a second,
  structurally-inverted reading (aggregate-then-ratio, vs. this
  pipeline's normalise-then-aggregate) is computed separately as a
  diagnostic side-check only (`Fetch/national_mean-distance_ratio.R`,
  Stage 9) - not part of the real indicator output.
- **Residual `Inf` kvotient values from touching mire polygons** are
  excluded (topology artifact, not an ecological signal) rather than
  imputed - inherent to the formula when polygons touch, not
  a bug (13,803 of 1,165,125 in the last full run).
- 2 loose test-AOI `.gpkg` files and several superseded/historical
  images (a wrong sigmoid-transform attempt, an early provisional map,
  simplification/log-transform diagnostic plots) exist in the original
  project folder but are **not migrated here** - dead ends from the
  development process documented in the original project's
  `CONNECTIVITY_NOTES.md`, not needed to run or understand the current
  pipeline.
