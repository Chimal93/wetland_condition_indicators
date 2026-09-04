# Norwegian Wetland Ecosystem Condition Indicators

Open-source, reproducible reconstructions of Norwegian wetland ecosystem
condition indicators. Each indicator runs end to end from public data —
no access to internal institutional file shares is required.

These reconstruct the methodology of NINA's
[ecosystemCondition](https://github.com/NINAnor/ecosystemCondition)
indicators. They are independent work and not official NINA products.
Where an original could not be reproduced exactly, the deviation is
documented in that indicator's README rather than silently absorbed.

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
