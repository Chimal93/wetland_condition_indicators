# Norwegian Wetland Ecosystem Condition Indicators

Open-source, reproducible reconstructions of Norwegian wetland ecosystem
condition indicators. Each indicator runs end to end from public data —
no access to internal institutional file shares is required.

These reconstruct the methodology of NINA's
[ecosystemCondition](https://github.com/NINAnor/ecosystemCondition)
indicators, developed and published through NINA's
[**ecRxiv**](https://github.com/NINAnor/ecRxiv) — a publishing platform
for Ecosystem Condition indicators ([ecRxiv.com](https://ecrxiv.com),
DOI [10.5281/zenodo.21802603](https://doi.org/10.5281/zenodo.21802603)),
which defines the documentation standard and workflow these indicators
follow.

This work is an independent reconstruction and **not an official NINA
product**; it has not gone through ecRxiv's publication workflow, and the
ecRxiv name and branding remain reserved for indicators that have. Where
an original could not be reproduced exactly, the deviation is documented
in that indicator's README rather than silently absorbed.

## TL;DR: reproduce all results

On a machine with Docker (Linux, or Windows via WSL, or macOS), from a
terminal:

```bash
git clone <this repository> && cd wetland_condition_indicators
bash docker/build_image.sh        # once, a few minutes
bash docker/check_setup.sh        # tells you which inputs you must obtain by hand
bash docker/run_indicators.sh     # hours; run it inside screen or tmux
```

Two inputs cannot be downloaded automatically and the check will ask for
them: the Tyler et al. (2021) spreadsheet for `NO_FUNC_003`, and the
AR5 forest and mire layers for `NO_GJEN_001` (or set `GJEN_SOURCE=AR50`
to use the public map instead). Logs, software versions and the results
before and after the run land in `runs/`. Details: [`docker/README.md`](docker/README.md).

## Indicators

| Indicator | Measures | Status |
|---|---|---|
| [`NO_FUNC_003`](NO_FUNC_003/) | Functional plant community index — plant trait indicator values (light, moisture, pH, nitrogen) against bootstrapped reference distributions | Complete |
| [`NO_GJEN_001`](NO_GJEN_001/) | Gjengroing (woody encroachment) — canopy height against LiDAR-derived reference levels | Complete |
| [`NO_CONN_001`](NO_CONN_001/) | Structural connectivity — per mire polygon, distance to nearest infrastructure vs. distance to nearest neighbouring mire | Complete |
| [`NO_GJEN_002`](NO_GJEN_002/) | Gjengroing from **aerial photography** — canopy height predicted by a deep-learning model on orthophoto, against the same reference levels as `NO_GJEN_001` | Complete |

`NO_GJEN_001` and `NO_GJEN_002` are deliberately paired: they measure the
same thing against the same two reference levels, and differ only in how
the vegetation height is obtained — LiDAR for the first, aerial
photography for the second. Photography is reflown far more often than
national LiDAR, so the second can be updated on a much shorter cycle.

**`NO_GJEN_002` needs imagery you supply yourself.** The photography
behind its published numbers is commercial and cannot be redistributed,
so nothing identifying a provider is in this repository — see that
indicator's README. Its per-polygon canopy heights *are* published, so
the indicator can be reproduced end to end without any imagery access.

One further indicator (NDVI-based) is in development and will be added
here when ready.

## How this repository is organised

Each indicator is a **self-contained subfolder**. Scripts resolve paths
relative to their own location, not to the repository root, so an
indicator can be run without reference to the others. Every subfolder
follows the same layout:

| Folder | Contents |
|---|---|
| `Main/` | The pipeline orchestrator — run this |
| `Fetch/` | Scripts that download or build each input; run these first |
| `Data/` | Inputs and intermediates (large files are fetched, not committed) |
| `Results/` | Final maps, indices and diagnostics |
| `Deliverables/` | The indicator in the ecosystemCondition platform format (see below) |

At the repository level:

| File / folder | Contents |
|---|---|
| `renv.lock` | The exact versions of R and every R package the scripts were run with |
| `wetland_condition_indicators.Rproj` | Opens the repository as an RStudio project |
| `docker/` | Runs the pipelines in a ready-made, frozen software environment. The preferred way to run them (see `docker/README.md`) |

**Start with the README inside the indicator you want to run.** Each
documents its own inputs, runtime, external dependencies and known
limitations.

## Delivery format (`Tools/` and each `Deliverables/`)

Every finished indicator ends with `Main/export_deliverables.R`, which
writes the indicator in the data structure used by the
[ecosystemCondition platform](https://ninanor.github.io/ecosystemCondition/)
so it can be used in a condition assessment without conversion:

- `<ID>_indicatorMap_region.rds` — an `sf` object in EPSG:25833, one row
  per landsdel, columns `area, areaId, v_YYYY, sd_YYYY, i_YYYY,
  reference_high, reference_low, thr` (variable value, its uncertainty,
  the 0-1 indicator value, the X100/X0 reference levels on the variable
  scale, and the good-condition threshold on the indicator scale). Finer
  unit sets (grid cells, polygons, plots) are written alongside with the
  same columns.
- `<ID>_values.csv` / `.xlsx` — the same table without geometry plus a
  national row and supplementary columns; the workbook carries a
  `metadata` sheet (ID and version, names, ecosystem, data years,
  variable and scaling definitions, reference-level justification,
  uncertainty definition, sources, documentation links).
- `<ID>_map.png` — a figure of the primary map.

`Tools/export_platform_format.R` is the one shared writer; each
indicator's export script only maps its own results onto the schema.
Column names follow the platform's own example file (`reference_high`;
the platform documentation spells it `referance_high`).

## Data is not committed

Raw and derived data are deliberately kept out of git — the three
indicators together reference roughly 15 GB of inputs. Each indicator's
`Fetch/` scripts retrieve or rebuild what they need from public sources.

One exception is worth knowing about: `NO_CONN_001` depends on derived
caches that take **20+ hours of compute** to rebuild. Those are published
as GitHub Release assets and retrieved with
`NO_CONN_001/Fetch/download_caches.R` — see that indicator's README.

## Getting started

1. Set up the software as described under "Setting up the software" below.
2. Pick an indicator and follow its README — each is self-contained and
   can be run without the others.

## Setting up the software

All indicators are written in R. To get the same results as everyone
else, you need the same versions of R, of the R packages the scripts use,
and of the map libraries underneath them. There are two ways to set this
up. Docker is the preferred one; RStudio without Docker is a fallback.

### Preferred: with Docker (Windows, macOS or Linux)

The `docker/` folder provides a complete, frozen environment with R 4.6.1,
all packages in the versions recorded in `renv.lock`, and the map
libraries (GDAL, GEOS, PROJ) they depend on, plus a runner that executes
the pipelines and records logs, versions and results for each run. It is
the only setup that fixes all three layers, which is what makes results
from different machines comparable. On Windows the commands are run from
a WSL (Ubuntu) terminal with Docker Desktop; on macOS from the Terminal
app with Docker Desktop. See [`docker/README.md`](docker/README.md).

### Fallback: in RStudio without Docker

Use this if you cannot install Docker. The file `renv.lock` records the
exact R package versions, and the steps below install precisely those.
Note that this does not fix the versions of R itself or of the map
libraries (GDAL, GEOS, PROJ) that come with your `sf` and `terra`
installation, so results may differ slightly from the published ones.

1. Install [R](https://cran.r-project.org/) version 4.6 and
   [RStudio](https://posit.co/download/rstudio-desktop/).
2. Open the file `wetland_condition_indicators.Rproj` in RStudio. On the
   first start, RStudio installs a small helper package called `renv` and
   prints a message about it; this is expected.
3. In the RStudio console, run:

   ```r
   renv::restore()
   ```

   and confirm with `y`. This downloads and installs all packages in the
   recorded versions into a library that belongs to this project only.
   It does not touch your other R projects. Expect 5 to 15 minutes and
   about 1 GB of disk space. An internet connection is required.
4. Follow the README of the indicator you want to run. Run the scripts
   from within RStudio (open the script and use *Source*), so that they
   pick up the project's package library.

Good to know:

- One package, `ecTools`, is downloaded from GitHub. If the install stops
  with a message about a "rate limit", GitHub is refusing anonymous
  downloads for a while. Wait an hour and try again, or create a free
  GitHub token and run `Sys.setenv(GITHUB_PAT = "<token>")` before
  `renv::restore()`.
- Two rebuild-from-scratch steps in `NO_CONN_001` need a program from
  outside R: QGIS or PowerShell on Windows, GDAL's `ogr2ogr` and `unzip`
  on Linux and macOS (both are in the Docker image). You only hit them if
  you delete that indicator's published caches; its README explains when.

## Reference data included here

Two small spatial files are committed rather than fetched, because every
indicator depends on them and they are only a few MB:

- **`regions.shp`** — the five-region delineation of Norway used for all
  regional aggregation. Taken from
  [NINAnor/ecosystemCondition](https://github.com/NINAnor/ecosystemCondition)
  (`data/regions.shp`) and redistributed under its CC BY 4.0 license.
  Each indicator carries an identical copy so it stays self-contained.

  Its `region` column has a character-encoding fault affecting *Østlandet*
  and *Sørlandet*. Every pipeline works around this by reassigning those
  two regions by `id` (3 and 5). Read the column directly and you will get
  corrupted names.

- **`outlineOfNorway_EPSG25833.shp`** — detailed coastline, used only as a
  basemap for rendering. It never enters a computed value.

## License

[CC BY 4.0](LICENSE.md) — the same license used by the
`NINAnor/ecosystemCondition` repository whose methodology these
reconstruct. Data retrieved by the `Fetch/` scripts remains governed by
its own source license.

Copyright (c) 2026 Sállir Natur AS
