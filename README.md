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

## Indicators

| Indicator | Measures | Status |
|---|---|---|
| [`NO_FUNC_003`](NO_FUNC_003/) | Functional plant community index — plant trait indicator values (light, moisture, pH, nitrogen) against bootstrapped reference distributions | Complete |
| [`NO_GJEN_001`](NO_GJEN_001/) | Gjengroing (woody encroachment) — canopy height against LiDAR-derived reference levels | Complete |
| [`NO_CONN_001`](NO_CONN_001/) | Structural connectivity — per mire polygon, distance to nearest infrastructure vs. distance to nearest neighbouring mire | Complete |

Two further indicators (a flyfoto-based encroachment companion and an
NDVI-based indicator) are in development and will be added here when
ready.

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

**Start with the README inside the indicator you want to run.** Each
documents its own inputs, runtime, external dependencies and known
limitations.

## Data is not committed

Raw and derived data are deliberately kept out of git — the three
indicators together reference roughly 15 GB of inputs. Each indicator's
`Fetch/` scripts retrieve or rebuild what they need from public sources.

One exception is worth knowing about: `NO_CONN_001` depends on derived
caches that take **20+ hours of compute** to rebuild. Those are published
as GitHub Release assets and retrieved with
`NO_CONN_001/Fetch/download_caches.R` — see that indicator's README.

## Getting started

```
git clone https://github.com/Chimal93/wetland_condition_indicators.git
```

**While this repository is private, downloading the release assets needs a
token.** Cloning uses your normal GitHub login, but the GitHub API requires
explicit authentication to serve release assets from a private repo — so
`download_caches.R` will fail without one. The simplest route:

1. Install the [GitHub CLI](https://cli.github.com/) and run `gh auth login`
2. In R, before running the download script:

   ```r
   Sys.setenv(GITHUB_TOKEN = system("gh auth token", intern = TRUE))
   ```

Alternatively create a [fine-grained personal access token](https://github.com/settings/tokens)
with read access to this repository and set `GITHUB_TOKEN` to it.

Once the repository is public, no token is needed and this step disappears.

Then pick an indicator and follow its README — each is self-contained and
can be run without the others.

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

## Requirements

- **R** (developed against 4.6) with `sf`, `terra`, `dplyr`, `ggplot2`
- **QGIS** — only for `NO_CONN_001` stage 2 (SOSI format conversion)
- Some steps are Windows-specific; each README flags these where they apply

## License

[CC BY 4.0](LICENSE.md) — the same license used by the
`NINAnor/ecosystemCondition` repository whose methodology these
reconstruct. Data retrieved by the `Fetch/` scripts remains governed by
its own source license.

Copyright (c) 2026 Sállir Natur AS
