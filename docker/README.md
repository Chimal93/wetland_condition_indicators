# Running the indicators with Docker

This folder lets you run the three indicator pipelines in a ready-made,
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
system, R 4.6.1, every R package at the exact version listed in
`renv.lock`, and the map libraries (GDAL, GEOS, PROJ) that the `sf` and
`terra` packages depend on. Running a script "inside the image" means it
uses exactly that installation, whatever is installed on the machine
itself. This is what makes runs on different machines comparable.

The image is built once from `Dockerfile`. The pipelines, their data and
their results stay on your machine; the image only provides the software.

## What lives where

| File | What it is |
|---|---|
| `Dockerfile` | Recipe for the image: starts from the public `rocker/geospatial:4.6.1` image and installs the packages from `renv.lock`. |
| `config.env` | All settings, with defaults and explanations. Committed; you do not edit it. |
| `config.local.env` | Your own settings for this machine (see "Your own settings" below). Not committed; you create it. |
| `config.local.env.example` | A copyable example of `config.local.env`. |
| `build_image.sh` | Builds the image. Run once, and again whenever `renv.lock` or `Dockerfile` changes. |
| `check_setup.sh` | Checks that the inputs you must obtain yourself are in place (see "Before your first run"). The runner calls it automatically. |
| `run_indicators.sh` | The main runner: runs the selected indicators from start to finish and records everything. |
| `run_script.sh` | Runs a single R script from the repository inside the image. |
| `prepare_ar5_input/` | One script, run once by hand: builds the AR5 forest and mire layers for `NO_GJEN_001` from the municipal FKB-AR5 GeoPackages. Needs restricted-access data; not part of the normal run. |
| `run_NO_CONN_001_ar5_variant.sh` | Runs the AR5 variant of `NO_CONN_001`, the delivered one (about 25 hours). See "The AR5 variant of NO_CONN_001" below. |
| `build_canopy_height_image.sh`, `canopy_height_model/` | A second image with the Python environment for Meta's canopy-height model, and everything it is built from. Only needed for new `NO_GJEN_002` canopy heights. |
| `run_NO_GJEN_002_canopy_height_model.sh` | Computes per-polygon canopy heights from an orthophoto for `NO_GJEN_002` and records exactly which inputs were used. See "New canopy heights for NO_GJEN_002" below. |
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
  `NO_FUNC_003/Data/OpenS_data/Tyler_data_raw.xlsx`.
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
| `versions/` | The exact software used: R session info, GDAL/GEOS/PROJ versions, every installed package with its version, and a copy of `renv.lock`. |
| `run_info.txt` | Which repository commit, image and settings the run used. |
| `results_committed/` | The `Results/` and `Deliverables/` folders as they were before the run. |
| `results_after/` | The same folders after the run. Compare with the folder above. |
| `home/`, `tmp/` | Scratch space used by R during the run. |

Fetched data goes where the indicator scripts put it: into `Data/` inside
each indicator folder, which git ignores. The national OpenStreetMap
download is kept in `runs/osm_cache/` and reused by later runs.

## What the runner does, step by step

1. Records the software versions into `versions/`.
2. Copies the current `Results/` and `Deliverables/` folders to
   `results_committed/`.
3. `NO_FUNC_003`: downloads the ANO field-survey data, runs the pipeline,
   then writes the deliverables. Requires the Tyler et al. spreadsheet
   (see "Before your first run").
4. `NO_CONN_001`: downloads the published caches (about 2 GB, only what is
   missing), runs the pipeline, then writes the deliverables. With the
   caches this takes minutes; without them it would take more than 20
   hours. The caches belong to the older *mire-model* variant, so this
   reproduces that variant, and its deliverables go to
   `NO_CONN_001/Deliverables_MireModel/`. The delivered AR5 variant is a
   separate run (see "The AR5 variant of NO_CONN_001" below).
5. `NO_GJEN_002` (`GJEN2`): downloads the NiN nature-type data and the
   bioclimatic zones, recomputes the indicator from the canopy heights
   committed in the repository, then writes the deliverables. Minutes.
   Computing new canopy heights from aerial photos is a separate run (see
   "New canopy heights for NO_GJEN_002" below).
6. `NO_GJEN_001`: downloads the bioclimatic zones, the forest disturbance
   map, OpenStreetMap buildings and the NiN nature-type data, checks or
   downloads the forest and mire polygons (see below), builds the
   good-condition reference heights at 30 m (about 40 minutes, the first
   time only), runs the pipeline, then writes the deliverables. The first
   run takes several hours, most of it reading elevation data from
   Kartverket's servers; later runs reuse the cached results and finish in
   minutes.
7. Copies the `Results/` and `Deliverables/` folders to `results_after/`.

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
  places both in `NO_GJEN_001/Data/OpenS_data/`. It takes about 15
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

## The AR5 variant of NO_CONN_001

The delivered `NO_CONN_001` result uses AR5 mires as the wetland
population. `run_indicators.sh` reproduces only the older mire-model
variant from published caches; the AR5 variant is computed from scratch:

```bash
bash docker/run_NO_CONN_001_ar5_variant.sh
```

It needs `ar5_myr_national.gpkg` (built by `prepare_ar5_input/`, see
above) and the infrastructure layer from a normal `NO_CONN_001` run
(`INDICATORS="CONN" bash docker/run_indicators.sh`); the script checks
both first. About 25 hours, so start it in `screen` or `tmux`. It can be
stopped and restarted: regions already done are skipped. The run folder is
`runs/conn001_ar5_<date>_<time>/`; the results land in
`NO_CONN_001/Deliverables/`, where `git diff` shows any difference from the
published ones. Same steps as upstream's `run_connectivity_ar5.ps1`, plus
the final `export_deliverables.R`.

## New canopy heights for NO_GJEN_002

`NO_GJEN_002` measures vegetation height with Meta's HighResCanopyHeight
model on RGB aerial photos. The published result is recomputed from
canopy heights committed in the repository and needs none of this.
This section is for computing **new**
canopy heights: new imagery, a later year, or a test of the model.

**One-time setup** (about 800 MB download, a few minutes):

```bash
bash docker/build_canopy_height_image.sh                       # image with Python and the model's packages
bash docker/canopy_height_model/download_model_and_weights.sh  # model code and weights, checksum-verified
bash docker/run_script.sh NO_GJEN_002/Fetch/fetch_nin_data.R   # NiN wetland polygons
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
`NO_GJEN_002/Fetch/assign_orthophoto_flight_dates.R`. Use it to check
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
`NO_GJEN_002/Data/OpenS_data/canopy_height_runs/<CHM_RUN_NAME>/`, next to a
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
| Python version, `uv` (the installer), model code commit, package-resolution date | `canopy_height_model/versions.env` |
| Every Python package, by version and checksum | `canopy_height_model/requirements.lock` (generated from `requirements.in` by `update_requirements_lock.sh`) |
| Model code archive and the two weight files | `canopy_height_model/model_files.sha256` |

## Running a single script

```bash
bash docker/run_script.sh NO_FUNC_003/Fetch/get_tyler_data.R
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
