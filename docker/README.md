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
| `results_committed/` | The `Results/` folders as they were before the run. |
| `results_after/` | The `Results/` folders after the run. Compare with the folder above. |
| `home/`, `tmp/` | Scratch space used by R during the run. |

Fetched data goes where the indicator scripts put it: into `Data/` inside
each indicator folder, which git ignores. The national OpenStreetMap
download is kept in `runs/osm_cache/` and reused by later runs.

## What the runner does, step by step

1. Records the software versions into `versions/`.
2. Copies the current `Results/` folders to `results_committed/`.
3. `NO_FUNC_003`: downloads the ANO field-survey data, then runs the
   pipeline. Requires the Tyler et al. spreadsheet (see "Before your first
   run").
4. `NO_CONN_001`: downloads the published caches (about 2 GB, only what is
   missing), then runs the pipeline. With the caches this takes minutes;
   without them it would take more than 20 hours.
5. `NO_GJEN_001`: downloads the bioclimatic zones, the forest disturbance
   map, OpenStreetMap buildings and the NiN nature-type data, checks or
   downloads the forest and mire polygons (see below), then runs the
   pipeline. The first
   run takes about 3.5 hours, most of it reading elevation data from
   Kartverket's servers; later runs reuse the cached results and finish in
   minutes.
6. Copies the `Results/` folders to `results_after/`.

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
