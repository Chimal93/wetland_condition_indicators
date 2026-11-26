# Running the indicators with Docker

This folder lets you run the indicator pipelines in a ready-made,
fixed software environment, without installing R yourself. **This is the
preferred way to run the indicators, on any operating system.** It is the
only setup that fixes not just the R packages but also R itself and the
map libraries underneath (GDAL, GEOS, PROJ), which is what makes results
from different machines comparable.

The scripts here are written for a Linux shell. On a Linux machine or
server they run as they are. On Windows, install Docker Desktop and run
the commands from a WSL (Ubuntu) terminal. On macOS, install Docker
Desktop and use the Terminal app. Running the R scripts directly in
RStudio, without Docker, is possible as a fallback and is described in the
main README, but it does not fix the underlying map libraries, so results
may differ slightly.

## What Docker gives you here

A Docker *image* is a complete, frozen software installation: an operating
system, R 4.6.1, every R package at the exact version listed in the
indicators' own lockfiles (`NO_*/renv.lock`), and the map libraries (GDAL, GEOS, PROJ) that the `sf` and
`terra` packages depend on. Running a script "inside the image" means it
uses exactly that installation, whatever is installed on the machine
itself. This is what makes runs on different machines comparable.

The image is built once from `Dockerfile`. The pipelines, their data and
their results stay on your machine; the image only provides the software.

## What lives where

| File | What it is |
|---|---|
| `Dockerfile` | Recipe for the image: starts from the public `rocker/geospatial:4.6.1` image and installs the packages from every indicator's `renv.lock`. The lockfiles never disagree on a package version, so one image serves all indicators. |
| `config.env` | All settings, with defaults and explanations. Committed; you do not edit it. |
| `config.local.env` | Your own settings for this machine (see "Your own settings" below). Not committed; you create it. |
| `config.local.env.example` | A copyable example of `config.local.env`. |
| `build_image.sh` | Builds the image. Run once, and again whenever a `NO_*/renv.lock` or the `Dockerfile` changes. |
| `check_setup.sh` | Checks that the inputs you must obtain yourself are in place (see "Before your first run"). The runner calls it automatically. |
| `run_indicators.sh` | The main runner: runs the selected indicators from start to finish and records everything. |
| `run_script.sh` | Runs a single R script from the repository inside the image. |
| `prepare_ar5_input/` | One script, run once by hand: builds the AR5 forest and mire layers for `NO_GJEN_001` from the municipal FKB-AR5 GeoPackages. Needs restricted-access data; not part of the normal run. |
| `run_NO_CONN_003_ar5_variant.sh` | Runs the AR5 variant of `NO_CONN_003`, the delivered one (about 25 hours). See "The AR5 variant of NO_CONN_003" below. |
| `build_canopy_height_image.sh`, `canopy_height_model/` | A second image with the Python environment for Meta's canopy-height model (installed with `uv` from `NO_GJEN_002/src/chm_model/uv.lock`). Only needed for new `NO_GJEN_002` canopy heights. |
| `run_NO_GJEN_002_deliverables.sh` | The whole current `NO_GJEN_002` chain in one go: national canopy-height map, 20 m indicator, deliverables and indicator document. See "NO_GJEN_002 from aerial photos" below. |
| `run_NO_GJEN_002_national_chm.sh`, `run_NO_GJEN_002_cell_indicator.sh` | The two heavy steps of that chain, also runnable on their own. |
| `run_NO_GJEN_002_canopy_height_model.sh` | Version 000.003 (superseded): per-polygon canopy heights for the NiN polygons with CHMv1. See "New canopy heights for NO_GJEN_002 (version 000.003)" below. |
| `data_sources.tsv` | The list of every input the runners use and where it comes from (see "Where the data came from"). |
| `internal/` | Pieces used by the scripts above; you do not call these yourself. `run_indicators_in_container.sh` is the step list that runs inside the image; `common.sh` loads the settings. |

Nothing in this folder changes the indicator scripts under `NO_*/`.

## First-time setup

1. Install Docker and make sure your user may run it (`docker run hello-world`
   works without `sudo`).
2. Build the image (a few minutes, needs internet):

   ```bash
   bash docker/build_image.sh
   ```
3. If a default does not suit your machine, create `docker/config.local.env`
   as described next. Most people can skip this at first.

## Your own settings: `config.local.env`

All settings live in `docker/config.env` with sensible defaults, and you
do not edit that file. To change a setting for your machine, create a
second file next to it, `docker/config.local.env`, containing only the
settings you want to change, one `NAME=value` per line. Git ignores this
file, so your paths never end up in the repository. A complete example:

```
# docker/config.local.env - my settings for this machine

# Write run output here instead of into the repository's runs/ folder.
RUNS_DIR=/data/wetland_runs

# I do not have FKB-AR5, so use the public AR50 map for NO_GJEN_001.
GJEN_SOURCE=AR50
```

The easiest start is to copy the shipped example and edit it:

```bash
cp docker/config.local.env.example docker/config.local.env
```

Every setting, its possible values and what it does is explained in
`config.env`. To change a setting for one run only, put it in front of
the command instead, for example `GJEN_SOURCE=AR50 bash docker/run_indicators.sh`.
That wins over both files for that run.

## Before your first run: inputs you must obtain yourself

Almost everything the pipelines need is downloaded automatically. Two
inputs cannot be, and a run stops right at the start until they are in
place:

- **NO_FUNC_003 needs the Tyler et al. (2021) spreadsheet.** It is the
  publisher's supplementary material, so it has to be downloaded by hand
  from the article and saved as
  `NO_FUNC_003/data/OpenS_data/Tyler_data_raw.xlsx`.
- **NO_GJEN_001 with `GJEN_SOURCE=AR5` (the default) needs the national
  AR5 forest and mire layers.** Access to FKB-AR5 is restricted. If you
  have the municipal FKB-AR5 GeoPackages, build the layers once with
  `docker/prepare_ar5_input/` (see below). If you do not, set
  `GJEN_SOURCE=AR50`, which needs nothing from you.

Check what you have with:

```bash
bash docker/check_setup.sh
```

It prints OK or MISSING for every item and, for each missing item, exactly
what to do. `run_indicators.sh` runs the same check before starting and
refuses to run while anything is missing.

## Running everything

From the repository root, inside a `screen` or `tmux` session because the
run can take hours and blocks the terminal:

```bash
bash docker/run_indicators.sh
```

To run only some indicators, or change other settings for one run, set
them on the command line:

```bash
INDICATORS="GJEN" bash docker/run_indicators.sh
INDICATORS="FUNC CONN" GJEN_SOURCE=AR50 bash docker/run_indicators.sh
```

The runner prints the run folder and a `tail -f` command for following
progress. Each run gets its own folder under `runs/` in the repository
(git ignores it; change the place with the `RUNS_DIR` setting):

| In the run folder | Contents |
|---|---|
| `SUMMARY.txt` | One line per step: started, finished with exit code and duration, or skipped. Read this first. |
| `logs/` | The full console output of every step, one file per script, every line stamped with the time. |
| `versions/` | The exact software used: R session info, GDAL/GEOS/PROJ versions, every installed package with its version, and a copy of each indicator's `renv.lock`. |
| `run_info.txt` | Which repository commit, image and settings the run used. |
| `data_sources.csv` | Every input the run used: where it comes from, size, last change, checksum and when it was fetched (see "Where the data came from" below). |
| `results_committed/` | Each indicator's `outputs/` folder (results and deliverables) as it was before the run. |
| `results_after/` | The same folders after the run. Compare with the folder above. |
| `home/`, `tmp/` | Scratch space used by R during the run. |

Fetched data goes where the indicator scripts put it: into `data/` inside
each indicator folder, where git ignores the large files. The national OpenStreetMap
download is kept in `runs/osm_cache/` and reused by later runs.

### Where the data came from

Most inputs are downloaded from public services that update their data
over time (NiN, OpenStreetMap, ...). To compare results years apart you
need to know which version of each dataset went in, so the runners keep
two records:

- **A download log next to the data.** Every time a download (or the AR5
  preparation) actually runs, one row per file is added to
  `<indicator>/data/data_sources_log.csv`: date and time, file, source,
  size, checksum, repository commit and run. Because it lives next to the
  data, the date survives later runs that skip the download.
- **A snapshot per run.** At the end of every run, `data_sources.csv` in
  the run folder lists every input of the selected indicators as that run
  used it, with its last logged download date. A checksum that differs
  between two runs means the input changed. Web services that are read
  live during the run (Kartverket's elevation data) are listed with the
  time of the run.

The AR5 preparation also writes
`NO_GJEN_001/data/OpenS_data/ar5_national_source_files.csv`, the name,
size, date and checksum of every municipal FKB-AR5 file it used.

Which files belong to which source is listed in `docker/data_sources.tsv`.
Data fetched before this logging existed shows "not logged" and its file
date instead. If you add a download step to a runner, add its output to
that list.

## What the runner does, step by step

1. Records the software versions into `versions/`.
2. Copies each indicator's current `outputs/` folder to
   `results_committed/`.
3. `NO_FUNC_003`: downloads the ANO field-survey data, runs the pipeline,
   writes the deliverables, then the report maps of its four
   indicators. Requires the Tyler et al. spreadsheet (see "Before your
   first run").
4. `NO_CONN_003`: downloads the published caches (about 2 GB, only what is
   missing), runs the pipeline, then writes the deliverables. With the
   caches this takes minutes; without them it would take more than 20
   hours. The caches belong to the older *mire-model* variant, so this
   reproduces that variant, and its deliverables go to
   `NO_CONN_003/outputs/deliverables_MireModel/`. The delivered AR5 variant
   is a separate run (see "The AR5 variant of NO_CONN_003" below).
5. `NO_GJEN_002` (`GJEN2`): writes the deliverables from the tables of the
   national 20 m run committed in the repository
   (`NO_GJEN_002/data/OpenS_data/orthophoto_chmv2_20m_cells/`). Seconds.
   The national run itself needs the aerial photos and a GPU and is
   separate (see "NO_GJEN_002 from aerial photos" below).
6. `NO_NDVI_001` (`NDVI`, provisional): downloads the NiN nature-type data,
   recomputes the NDVI trends from the national MODIS series committed in
   the repository, then writes the deliverables and the report map.
   Minutes. A new MODIS download (`R/fetch_modis_ndvi.R`, hours, needs a
   free NASA Earthdata token) is not part of the run.
7. `NO_GJEN_001`: downloads the bioclimatic zones, the forest disturbance
   map, OpenStreetMap buildings and the NiN nature-type data, checks or
   downloads the forest and mire polygons (see below), builds the
   good-condition reference heights at 30 m (about 40 minutes, the first
   time only), runs the pipeline, then writes the deliverables and the
   report map. The first
   run takes several hours, most of it reading elevation data from
   Kartverket's servers; later runs reuse the cached results and finish in
   minutes.
8. Copies the `outputs/` folders to `results_after/`.

A download step is skipped when its output file already exists. Set
`RERUN_FETCH=yes` to download everything again. Within one indicator, a
failed step stops that indicator; the remaining indicators still run.

### Forest and mire polygons for NO_GJEN_001

The pipeline can use two sources, chosen with `GJEN_SOURCE`:

- `AR5` (default): the detailed national land-resource map, the source
  the published results were built with. Access is restricted. Norway's
  mapping authority (Geonorge) distributes it as one GeoPackage per
  municipality (357 files, about 47 GB). If you have that folder, build
  the two national layers once, before the run, with

  ```bash
  bash docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh /path/to/FKB-AR5-folder
  ```

  The script subsets the forest and mire polygons from every municipal
  file, merges them into `ar5_skog_national.gpkg` and
  `ar5_myr_national.gpkg`, checks that no municipality is missing, and
  places both in `NO_GJEN_001/data/OpenS_data/`. It takes about 15
  minutes and runs inside the Docker image, so build the image first. The
  runner only checks that the two files exist.

  "Skog" and "myr" are AR5's own land-type classes (column
  `arealressursArealtype`): code 30, *skog* (forest), is land with at
  least 6 trees per decare that are or can become 5 m tall; code 60,
  *myr* (mire), is mire vegetation on at least 30 cm of peat. The tree
  criterion wins in AR5, so a peatland with enough trees is coded as
  forest. The mire layer is therefore open mire only, and forested mire
  sits in the forest layer. Keep this in mind when interpreting the
  results. The AR50 route uses the same two codes.
- `AR50`: a coarser, freely downloadable map. The sensible choice if you
  do not have FKB-AR5: nothing to obtain, nothing to prepare. Results
  differ slightly from the AR5-based ones.

## The AR5 variant of NO_CONN_003

The delivered `NO_CONN_003` result uses AR5 mires as the wetland
population. `run_indicators.sh` reproduces only the older mire-model
variant from published caches; the AR5 variant is computed from scratch:

```bash
bash docker/run_NO_CONN_003_ar5_variant.sh
```

It needs `ar5_myr_national.gpkg` (built by `prepare_ar5_input/`, see
above) and the infrastructure layer from a normal `NO_CONN_003` run
(`INDICATORS="CONN" bash docker/run_indicators.sh`); the script checks
both first. About 25 hours, so start it in `screen` or `tmux`. It can be
stopped and restarted: regions already done are skipped. The run folder is
`runs/conn003_ar5_<date>_<time>/`; the results land in
`NO_CONN_003/outputs/deliverables/`, where `git diff` shows any difference
from the published ones. Same steps as upstream's
`NO_CONN_003/src/run_connectivity_ar5.ps1`, plus the two steps its README
lists after it: `export_deliverables.R` and `make_report_map.R`.

## NO_GJEN_002 from aerial photos

The current `NO_GJEN_002` (version 000.004) estimates vegetation height
with the CHMv2 model for all AR5 mire, calibrates it to LiDAR and computes
the indicator for every 20 m cell, like `NO_GJEN_001`. One script runs the
whole chain; start it inside `screen`:

```bash
bash docker/run_NO_GJEN_002_deliverables.sh
```

1. **Map** (`run_NO_GJEN_002_national_chm.sh chmv2`): canopy height at
   0.5 m over all AR5 mire plus 30 m, on the GPU. 11–14 hours nationally;
   finished parts are skipped on a rerun.
2. **20 m indicator** (`run_NO_GJEN_002_cell_indicator.sh`): cell medians,
   calibration, indicator, uncertainty and flight years. About 30 minutes.
3. The result tables are copied into
   `NO_GJEN_002/data/OpenS_data/orthophoto_chmv2_20m_cells/`.
4. Deliverables are written to `NO_GJEN_002/outputs/deliverables_20m_cells/`.
5. The indicator document `NO_GJEN_002/docs/NO_GJEN_002.html` is rendered.

**Needs:**
- the canopy-height image (`build_canopy_height_image.sh`), an NVIDIA GPU;
- a Hugging Face login with the CHMv2 terms accepted (CHMv2 is gated);
- in `config.local.env`: `ORTHOPHOTO_SOURCE_PATH` (a local copy of the
  mosaic, with its `metadata/` folder next to it) and `NATIONAL_CHM_OUT_DIR`
  (output folder, may be on the network drive);
- the AR5 mire layer (see "Forest and mire polygons for NO_GJEN_001");
- `NATIONAL_CHM_OUT_DIR/validation_cells_lidar_20m_median.csv`: LiDAR
  heights at the `NO_GJEN_001` sample cells, for the uncertainty. It is
  not in the repository because the cells come from AR5.

Reads from the network drive are retried after 10, 30 and 90 seconds. If
anything still fails, the output is marked `INCOMPLETE` and the script
stops with an error.

## New canopy heights for NO_GJEN_002 (version 000.003, superseded)

This section describes the earlier version on NiN polygons with CHMv1. It
is kept for reference.

`NO_GJEN_002` measures vegetation height with Meta's HighResCanopyHeight
model on RGB aerial photos. The published result is recomputed from
canopy heights committed in the repository and needs none of this.
This section is for computing **new**
canopy heights: new imagery, a later year, or a test of the model.

**One-time setup** (about 800 MB download, a few minutes):

```bash
bash docker/build_canopy_height_image.sh                       # image with Python and the model's packages
bash docker/canopy_height_model/download_model_and_weights.sh  # model code and weights, checksum-verified
bash docker/run_script.sh NO_GJEN_002/R/fetch_nin_data.R       # NiN wetland polygons
```

Then tell the runner which orthophoto to use, in `config.local.env`:

```bash
ORTHOPHOTO_SOURCE_PATH=/path/to/national_ortho_50cm.tif
ORTHOPHOTO_METADATA=/path/to/source_image_list.txt
# Flight metadata of the mosaic, for the photo date of every polygon (optional):
ORTHOPHOTO_VISIBLE_PROJECTS=/path/to/metadata/mosaic_coverage_by_project.gpkg
ORTHOPHOTO_PROJECT_GRID=/path/to/metadata/metadata_omløpsprosjekt_mosaic_v2_2025.gpkg
```

A national mosaic is stitched together from many flights, often years
apart and in different months, so a polygon's canopy height describes
the date of *its* photo, not the mosaic's nominal year. With the two
flight-metadata files set, the runner finishes by writing
`orthophoto_flight_dates.csv` next to the canopy heights: for every
polygon the flight project it is seen in (name and Norge i bilder project
id), the flight dates, the original pixel size of the photos, and how much
of the polygon that project covers. `orthophoto_flight_projects.csv` adds
one row per flight project with everything the metadata says about it
(owner, flight company, producer, product specification, ...). Method in
`NO_GJEN_002/R/assign_orthophoto_flight_dates.R`. Use it to check
whether differences between regions or years could come from photo age
or season.

**Run** (a quick test first, then the full run):

```bash
CHM_RUN_NAME=test20 CHM_REGIONS=Vestlandet CHM_MAX_POLYGONS=20 bash docker/run_NO_GJEN_002_canopy_height_model.sh
CHM_RUN_NAME=ortho2025 bash docker/run_NO_GJEN_002_canopy_height_model.sh
```

The full national run takes several days on CPU. Rerunning with the same
`CHM_RUN_NAME` resumes it. A region that fails, or leaves polygons
without a value, is retried three times (after 10, 30 and 90 seconds, to
ride out a network-share hiccup); whatever still fails is listed in an
`INCOMPLETE.txt` in the output folder, and the run ends with an error.

The output is one CSV per region in
`NO_GJEN_002/data/OpenS_data/canopy_height_runs/<CHM_RUN_NAME>/`, next to a
`provenance/` folder that records, for every start of the run:

- a fingerprint of the orthophoto (size, date, checksums of its header and
  of 64 samples spread over the file; a full checksum of a multi-terabyte
  file is not practical) and what GDAL reports about it;
- the checksum of every file listed in `ORTHOPHOTO_METADATA` and of the
  two flight-metadata files;
- a fingerprint of the NiN polygon data;
- the repository commit, the image, the model code commit and the
  checksums of the model weights and Python packages.

A resumed run whose orthophoto fingerprint differs from the one it started
with is refused, so two sets of imagery are never mixed in one result.

What is pinned, and where:

| What | Pinned in |
|---|---|
| Python version, `uv` (the installer), model code commit | `canopy_height_model/versions.env` |
| Every Python package, by version and checksum | `NO_GJEN_002/src/chm_model/uv.lock`, upstream's lock (the image runs `uv sync --locked` on it) |
| Model code archive and the two weight files | `canopy_height_model/model_files.sha256` |

## Running a single script

```bash
bash docker/run_script.sh NO_FUNC_003/R/get_tyler_data.R
```

The script runs with its own folder as working directory, exactly as the
indicator READMEs assume. Output appears in your terminal.

## Good to know

- Everything runs as your own user, so files created by a run belong to
  you, not to root.
- Two runs can go at the same time, for example `FUNC` in one terminal and
  `GJEN` in another. They write to separate run folders and separate
  indicator folders.
- The log timestamps use the machine's local time zone.
- If the image build fails while fetching `ecTools` from GitHub, GitHub's
  rate limit for anonymous downloads is the usual cause. Run
  `GITHUB_PAT=<your token> bash docker/build_image.sh`.
- Old run folders and stopped containers are not cleaned up automatically.
  `docker ps -a` lists containers; `docker rm <name>` removes one.
