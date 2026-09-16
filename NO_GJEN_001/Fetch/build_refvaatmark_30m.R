# ============================================================
# Build the wetland reference heights (Stage 5 input of Main/):
# one "good condition" canopy-height reference per region x
# bioclimatic-zone stratum, evaluated at 30 m.
#
# METHOD
# The original indicator derives this table in Google Earth Engine as one
# median per good-condition NiN wetland polygon, with the canopy height
# model (CHM = DSM - DTM, 1 m LiDAR) requested at a 30 m scale
# (reduceRegions, median reducer, scale 30), then a median across polygons
# within each stratum. Requesting a computed 1 m image at 30 m makes Earth
# Engine read the DSM and DTM through their mean pyramids, so each 30 m
# value is the mean of the raw 1 m difference over that 900 m^2 cell, with
# the "no negative heights" clamp applied afterwards. This script
# reproduces that evaluation explicitly with open data:
#
#   1. good-condition NiN wetland polygons (Fetch/fetch_nin_data.R), with
#      the same nature-type exclusions the original applies (types that
#      are tree-covered while in good condition) and no T1 mapping units;
#   2. Kartverket DTM1/DOM1 tiles read over HTTP; for each polygon the raw
#      DOM - DTM difference is averaged onto a 30 m grid anchored at the
#      EPSG:25833 origin (the same grid a scale-30 request produces), then
#      clamped at 0;
#   3. per polygon: the median over those 30 m cells, each cell weighted
#      by the fraction of it the polygon covers (Earth Engine's median
#      reducer is coverage-weighted);
#   4. per stratum: the median across polygons.
#
# WHY 30 m MATTERS
# Evaluated at the native 1 m, a good-condition open bog has a median
# height of a few centimetres - almost every pixel is ground. At 30 m each
# cell is a 900 m^2 average that includes scattered trees and, for the
# typically sub-hectare NiN polygons, the surrounding forest edge. The
# same polygons therefore give reference values roughly 5-20x higher at
# 30 m than at 1 m. The 1 m point-sampling reconstruction this repo used
# before (still available in Main/ as the "1m" variant) is what produced
# the previously documented 2-16x shortfall against the published
# reference table; the 30 m evaluation removes it (see COMPARISON).
#
# The evaluation scale is a property of the reference definition, not a
# resolution choice made here: the "good condition" anchor is defined as
# a 30 m median, and the population and forest anchors have their own
# scales (20 m) in the original design. Changing any of them changes the
# indicator's meaning.
#
# COMPARISON (optional, printed at the end)
# If the published reference table is available it is joined per stratum.
# It is looked for at ../Data/OpenS_data/refvaatmark_published.csv and,
# failing that, downloaded from the indicator's ecRxiv page
# (github.com/NINAnor/ecRxiv, indicators/NO_GJEN_001/data/refvaatmark.csv).
# Full national build (8,200 polygons, 2026-09): 15 of 20 strata within
# 0.5-2x of the published values (4 of 20 at 1 m); the strata that were
# 10-16x low at 1 m agree within 1.05-1.55x. The remaining outliers
# (Sørlandet SB/MB, Nord-Norge NB) are polygon-set differences, not
# method: 65-90 % of those strata's polygons in the current NiN download
# were mapped in 2023-2025 and postdate the polygon set the published
# table was built from. The current NiN download is the correct input for
# a current reconstruction; the published table is not treated as ground
# truth.
#
# RUN
#   Rscript build_refvaatmark_30m.R            full build (default)
#   REF30_N_PER_STRATUM=40  ...                quick validation subsample
#   REF30_N_WORKERS=4       ...                parallel workers (default 4)
# Network-bound (HTTP range reads of DTM1/DOM1), ~40 min nationally with
# 4 workers. Checkpointed per chunk of tiles and resumable: re-running
# skips tiles already in the per-polygon file.
#
# OUTPUT  ../Data/OpenS_data/refvaatmark_30m/
#   refvaatmark_30m.csv             region, vegClimZoneLab, ref (m), n,
#                                   plus ref_1m and ref_median30 for
#                                   reference (see column notes below)
#   refvaatmark_30m_perpolygon.csv  per-polygon values (resume checkpoint)
#   refvaatmark_30m_comparison.csv  join to the published table, if found
#
# Column notes: `ref` is the value Main/ uses (mean-pyramid 30 m,
# coverage-weighted median). `ref_1m` is the native-resolution zonal
# median of the same polygons and `ref_median30` a median-pyramid variant;
# both are kept only so the scale effect is visible in one table.
# ============================================================

library(sf)
library(terra)
library(dplyr)
library(readr)
library(tibble)

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
# All relative paths below are anchored to: NO_GJEN_001/Fetch/

Sys.setenv(
  GDAL_HTTP_TIMEOUT            = "15",
  GDAL_HTTP_CONNECTTIMEOUT     = "10",
  GDAL_HTTP_MAX_RETRY          = "2",
  GDAL_HTTP_RETRY_DELAY        = "1",
  GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR"
)

n_per_stratum <- suppressWarnings(as.integer(Sys.getenv("REF30_N_PER_STRATUM", "0")))
if (is.na(n_per_stratum)) n_per_stratum <- 0L
n_workers <- suppressWarnings(as.integer(Sys.getenv("REF30_N_WORKERS", "4")))
if (is.na(n_workers) || n_workers < 1) n_workers <- 4L
tag <- if (n_per_stratum > 0) paste0("_TEST", n_per_stratum) else ""
SCALE_M <- 30

data_dir <- file.path("..", "Data", "OpenS_data")
out_dir  <- file.path(data_dir, "refvaatmark_30m")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
gdb_path            <- file.path(data_dir, "nin_data", "Naturtyper_nin_0000_norge_4326_FILEGDB.gdb")
tile_footprint_path <- file.path(data_dir, "dtm1_tile_footprint.gpkg")
published_ref_path  <- file.path(data_dir, "refvaatmark_published.csv")
published_ref_url   <- "https://raw.githubusercontent.com/NINAnor/ecRxiv/main/indicators/NO_GJEN_001/data/refvaatmark.csv"
checkpoint_path     <- file.path(out_dir, paste0("refvaatmark_30m_perpolygon", tag, ".csv"))
final_output_path   <- file.path(out_dir, paste0("refvaatmark_30m", tag, ".csv"))
comparison_path     <- file.path(out_dir, paste0("refvaatmark_30m_comparison", tag, ".csv"))

if (!file.exists(gdb_path)) {
  stop("Missing required file: ", gdb_path, "\nRun fetch_nin_data.R first to produce it.")
}
if (!file.exists(tile_footprint_path)) {
  stop("Missing required file: ", tile_footprint_path,
       "\nRun build_ar50_wetland_lidar_coverage.R first to produce it.")
}

cat("Mode:", if (n_per_stratum > 0) paste("VALIDATION -", n_per_stratum, "polygons/stratum") else "FULL national build",
    "| workers:", n_workers, "\n")

# --- Strata: region x bioclimatic zone, built exactly as Main/ Stage 2-3 ---
regionlvl      <- c("Nord-Norge", "Midt-Norge", "Vestlandet", "Østlandet", "Sørlandet")
vegclimzonelvl <- c("Lavalpin sone (LA)", "Nordboreal sone (NB)", "Mellomboreal sone (MB)",
                    "Sørboreal sone (SB)", "Boreonemoral sone (BN)")

regions_path <- file.path(data_dir, "regions.shp")
if (!file.exists(regions_path)) stop("Missing required file: ", regions_path)
regions <- st_read(regions_path, quiet = TRUE)
# Same DBF double-encoding fix as Main/ (ids 3/5 come back garbled).
regions$region[regions$id == 3] <- "Østlandet"
regions$region[regions$id == 5] <- "Sørlandet"
regions$region <- factor(regions$region, levels = regionlvl)

bioclimzone_path <- file.path(data_dir, "bioclim", "bioclimzone.shp")
soner_path       <- file.path(data_dir, "bioclim", "soner2017.shp")
if (file.exists(bioclimzone_path)) {
  bioclim <- st_read(bioclimzone_path, quiet = TRUE) %>% st_transform(st_crs(regions))
} else if (file.exists(soner_path)) {
  bioclim <- st_read(soner_path, quiet = TRUE) %>%
    st_transform(st_crs(regions)) %>%
    group_by(Sone_navn) %>%
    summarise(geometry = st_union(geometry)) %>%
    mutate(KLASSE = as.numeric(as.factor(Sone_navn))) %>%
    rename(NAVN = Sone_navn)
} else {
  stop("Missing required file: ", soner_path, "
Run fetch_bioclim_zones.R to produce it.")
}
bioclim$NAVN <- factor(bioclim$NAVN, levels = vegclimzonelvl)

bio_clim_reg <- bioclim %>%
  st_intersection(regions) %>%
  mutate(vegClimZoneLab = NAVN) %>%
  dplyr::select(region, vegClimZoneLab) %>%
  tibble::rowid_to_column("ID")

tiles <- st_read(tile_footprint_path, quiet = TRUE)

cat("Loading national NiN dataset...\n")
nin <- st_read(gdb_path, layer = "naturtyper_nin_omr", quiet = TRUE)

# Nature types that can be in good condition while tree-covered (swamp,
# spring and strand forests) or that sit on unstable/sloped ground - the
# same exclusion list Main/ Stage 5 applies for the 1 m variant.
excluded_naturtyper <- c(
  "Hule eiker", "Hagemark", "Lauveng",
  "Saltpåvirket strand- og sumpskogsmark", "Flommyr, myrkant og myrskogsmark",
  "Grankildeskog", "Sørlig kaldkilde", "Kaldkilde under skoggrensa",
  "Svak kilde og kildeskogsmark", "Varmekjær kildelauvskog",
  "Gammel fattig sumpskog", "Rik gransumpskog", "Rik svartorsumpskog",
  "Kilde-edellauvskog", "Rik gråorsumpskog", "Kalkrik myr- og sumpskogsmark",
  "Rik vierstrandskog", "Rik svartorstrandskog", "Saltpåvirket svartorstrandskog",
  "Leirravine", "Kalkrik helofyttsump",
  "Grotte", "Silt og leirskred", "Fossepåvirket berg"
)

nin_wetland_ref <- nin %>%
  filter(hovedøkosystem == "våtmark") %>%
  filter(tilstand == "god") %>%                    # lowercase in this download
  filter(!(naturtype %in% excluded_naturtyper)) %>%
  filter(!grepl("T1-", ninKartleggingsenheter)) %>%  # values are "NA_T1-..." - no anchor
  st_transform(st_crs(bio_clim_reg)) %>%
  st_make_valid()

cat("Good-condition NiN wetland reference polygons (post-exclusions):",
    nrow(nin_wetland_ref), "\n")

# Largest-overlap stratum assignment (polygons are small, mostly < 1 ha).
frags <- nin_wetland_ref %>%
  st_join(bio_clim_reg %>% select(ID, region, vegClimZoneLab), largest = TRUE) %>%
  filter(!is.na(ID))
# poly_id is assigned before any subsampling so ids are identical between
# validation and full runs.
frags$poly_id <- seq_len(nrow(frags))
cat("Polygons matched to a stratum:", nrow(frags), "/", nrow(nin_wetland_ref), "\n")

if (n_per_stratum > 0) {
  set.seed(123)
  keep <- frags %>%
    st_drop_geometry() %>%
    group_by(ID) %>%
    slice_sample(n = n_per_stratum) %>%
    ungroup() %>%
    pull(poly_id)
  frags <- frags[frags$poly_id %in% keep, ]
  cat("Validation subsample:", nrow(frags), "polygons across",
      n_distinct(frags$ID), "strata\n")
}

# Tile assignment via centroid (safe for sub-hectare polygons).
polys_proj <- st_transform(frags, st_crs(tiles))
centroids  <- st_centroid(st_geometry(polys_proj))
tile_join  <- st_join(st_sf(poly_id = polys_proj$poly_id, geometry = centroids), tiles["tile_id"])
polys_proj$tile_id <- tile_join$tile_id[match(polys_proj$poly_id, tile_join$poly_id)]

n_no_tile <- sum(is.na(polys_proj$tile_id))
cat("Polygons with no matching DTM1 tile (dropped):", n_no_tile, "\n")
polys_proj <- polys_proj[!is.na(polys_proj$tile_id), ]

# Flatten to WKT + plain attributes: terra objects wrap external pointers
# and cannot be passed to parallel workers; rebuild inside each worker.
polys_flat <- polys_proj %>%
  st_drop_geometry() %>%
  select(poly_id, tile_id, region, vegClimZoneLab)
polys_flat$wkt <- sf::st_as_text(sf::st_geometry(polys_proj))
crs_wkt <- sf::st_crs(polys_proj)$wkt

tile_ids <- unique(polys_flat$tile_id)
cat("Distinct DTM1 tiles needed:", length(tile_ids), "\n")

# --- Checkpoint: skip tiles completed in a previous (interrupted) run ---
empty_row <- data.frame(poly_id = integer(), tile_id = character(),
                        med_1m = double(), med_mean30 = double(), med_median30 = double(),
                        n_px_1m = integer(), n_cells_30m = integer(), w_cells_30m = double())
done_tiles <- character(0)
if (file.exists(checkpoint_path)) {
  prev <- read_csv(checkpoint_path, show_col_types = FALSE)
  done_tiles <- unique(prev$tile_id)
  cat("Resuming from checkpoint:", length(done_tiles), "tiles already completed\n")
} else {
  write_csv(empty_row, checkpoint_path)
}
remaining_tiles <- setdiff(tile_ids, done_tiles)
cat("Tiles remaining to process:", length(remaining_tiles), "/", length(tile_ids), "\n")

# Coverage-weighted median: the value at which the cumulative weight first
# reaches half the total.
weighted_median <- function(x, w) {
  ok <- !is.na(x) & !is.na(w) & w > 0
  x <- x[ok]; w <- w[ok]
  if (length(x) == 0) return(NA_real_)
  o <- order(x); x <- x[o]; w <- w[o]
  cw <- cumsum(w) / sum(w)
  x[which(cw >= 0.5)[1]]
}

process_tile_zonal_30m <- function(tid, polys_flat, crs_wkt, scale_m, weighted_median) {
  sub <- polys_flat[polys_flat$tile_id == tid, ]
  na_row <- function(pid) data.frame(poly_id = pid, tile_id = tid,
                                     med_1m = NA_real_, med_mean30 = NA_real_, med_median30 = NA_real_,
                                     n_px_1m = NA_integer_, n_cells_30m = NA_integer_, w_cells_30m = NA_real_)
  tile_url <- function(tile_id, product) {
    paste0("/vsicurl/https://nedlasting.geonorge.no/hoydedata/", product, "/", tile_id, ".tif")
  }
  dtm <- tryCatch(terra::rast(tile_url(tid, "DTM1")), error = function(e) NULL)
  dom <- tryCatch(terra::rast(tile_url(tid, "DOM1")), error = function(e) NULL)
  if (is.null(dtm) || is.null(dom)) {
    return(do.call(rbind, lapply(sub$poly_id, na_row)))
  }
  out <- vector("list", nrow(sub))
  for (i in seq_len(nrow(sub))) {
    g <- tryCatch(terra::vect(sub$wkt[i], crs = crs_wkt), error = function(e) NULL)
    if (is.null(g)) { out[[i]] <- na_row(sub$poly_id[i]); next }
    out[[i]] <- tryCatch({
      # Crop window snapped outward to the global 30 m grid plus one cell
      # of margin, so aggregate(fact = 30) lands on origin-anchored cells.
      e  <- terra::ext(g)
      bb <- terra::ext(floor(e$xmin / scale_m) * scale_m - scale_m,
                       ceiling(e$xmax / scale_m) * scale_m + scale_m,
                       floor(e$ymin / scale_m) * scale_m - scale_m,
                       ceiling(e$ymax / scale_m) * scale_m + scale_m)
      dtm_c <- terra::crop(dtm, bb)
      dom_c <- terra::crop(dom, bb)
      raw   <- dom_c - dtm_c                # unclamped 1 m difference
      chm1  <- raw; chm1[chm1 < 0] <- 0     # the 1 m CHM

      # 1 m zonal median (kept for the scale comparison only)
      ex1  <- terra::extract(chm1, g, fun = median, na.rm = TRUE)[[2]]
      npx1 <- terra::extract(chm1, g, fun = function(x, ...) sum(!is.na(x)))[[2]]

      # mean30: mean pyramid of the raw difference, clamp after (the value used)
      m30 <- terra::aggregate(raw, fact = scale_m, fun = "mean", na.rm = TRUE)
      m30[m30 < 0] <- 0
      # median30: median pyramid of the clamped CHM (comparison only)
      d30 <- terra::aggregate(chm1, fact = scale_m, fun = "median", na.rm = TRUE)

      both <- c(m30, d30); names(both) <- c("mean30", "median30")
      ex30 <- terra::extract(both, g, exact = TRUE)   # ID, mean30, median30, fraction
      data.frame(poly_id = sub$poly_id[i], tile_id = tid,
                 med_1m       = ex1,
                 med_mean30   = weighted_median(ex30$mean30,   ex30$fraction),
                 med_median30 = weighted_median(ex30$median30, ex30$fraction),
                 n_px_1m      = as.integer(npx1),
                 n_cells_30m  = sum(!is.na(ex30$mean30) & ex30$fraction > 0),
                 w_cells_30m  = sum(ex30$fraction[!is.na(ex30$mean30)]))
    }, error = function(e) na_row(sub$poly_id[i]))
  }
  do.call(rbind, out)
}

if (length(remaining_tiles) > 0) {
  chunk_size <- 20
  chunks <- split(remaining_tiles, ceiling(seq_along(remaining_tiles) / chunk_size))

  cl <- parallel::makeCluster(n_workers)
  on.exit(parallel::stopCluster(cl), add = TRUE)
  parallel::clusterEvalQ(cl, {
    Sys.setenv(GDAL_HTTP_TIMEOUT = "15", GDAL_HTTP_CONNECTTIMEOUT = "10",
               GDAL_HTTP_MAX_RETRY = "2", GDAL_HTTP_RETRY_DELAY = "1",
               GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR")
    library(terra)
  })

  t_start <- Sys.time()
  for (ci in seq_along(chunks)) {
    chunk_tiles <- chunks[[ci]]
    t0 <- Sys.time()
    res_list <- parallel::parLapply(cl, chunk_tiles, process_tile_zonal_30m,
                                    polys_flat = polys_flat, crs_wkt = crs_wkt,
                                    scale_m = SCALE_M, weighted_median = weighted_median)
    res_df <- do.call(rbind, res_list)
    write_csv(res_df, checkpoint_path, append = TRUE)
    dt <- round(as.numeric(Sys.time() - t0, units = "secs"), 1)
    elapsed <- round(as.numeric(Sys.time() - t_start, units = "secs"), 1)
    cat("Chunk", ci, "/", length(chunks), "-", length(chunk_tiles), "tiles,",
        nrow(res_df), "polygons, in", dt, "sec (", elapsed, "sec elapsed total)\n")
    flush.console()
  }
} else {
  cat("All tiles already completed in checkpoint - nothing left to process.\n")
}

cat("\nLoading checkpoint for final aggregation...\n")
per_polygon <- read_csv(checkpoint_path, show_col_types = FALSE) %>%
  distinct(poly_id, .keep_all = TRUE) %>%
  filter(poly_id %in% polys_flat$poly_id) %>%
  left_join(polys_flat %>% select(poly_id, region, vegClimZoneLab), by = "poly_id")

cat("NA per-polygon values (outside LiDAR coverage):", sum(is.na(per_polygon$med_mean30)), "/", nrow(per_polygon), "\n")
cat("30 m cells per polygon (weighted): median", round(median(per_polygon$w_cells_30m, na.rm = TRUE), 1),
    "| share of polygons covering < 1 whole cell:",
    round(100 * mean(per_polygon$w_cells_30m < 1, na.rm = TRUE)), "%\n")

agg <- per_polygon %>%
  filter(!is.na(med_mean30)) %>%
  group_by(region, vegClimZoneLab) %>%
  summarise(ref          = median(med_mean30, na.rm = TRUE),
            n            = n(),
            ref_1m       = median(med_1m, na.rm = TRUE),
            ref_median30 = median(med_median30, na.rm = TRUE),
            .groups = "drop")

write_csv(agg, final_output_path)
cat("Saved:", final_output_path, "\n")

# --- Optional comparison against the published reference table ---
published <- NULL
if (file.exists(published_ref_path)) {
  published <- read_csv(published_ref_path, show_col_types = FALSE)
} else {
  published <- tryCatch({
    download.file(published_ref_url, published_ref_path, quiet = TRUE, mode = "wb")
    read_csv(published_ref_path, show_col_types = FALSE)
  }, error = function(e) { message("Published reference table not available (", conditionMessage(e), ") - comparison skipped."); NULL })
}

if (!is.null(published)) {
  comp <- published %>%
    rename(ref_published = ref) %>%
    left_join(agg, by = c("region", "vegClimZoneLab")) %>%
    mutate(ratio_30m = ref / ref_published,
           ratio_1m  = ref_1m / ref_published) %>%
    arrange(desc(ref_published))
  write_csv(comp, comparison_path)
  cat("\n=== Per-stratum comparison against the published reference table ===\n")
  print(comp %>% select(region, vegClimZoneLab, n, ref_published, ref, ratio_30m, ref_1m, ratio_1m) %>%
          mutate(across(where(is.numeric), ~ round(.x, 3))), n = 40, width = 200)
  summ <- function(r) {
    r <- r[is.finite(r)]
    sprintf("median ratio %.2f | within 0.5-2x: %d/%d | log10-RMSE %.2f",
            median(r), sum(r > 0.5 & r < 2), length(r), sqrt(mean(log10(r)^2)))
  }
  cat("\n  30 m (used): ", summ(comp$ratio_30m), "\n")
  cat("  1 m         : ", summ(comp$ratio_1m), "\n")
  cat("Saved:", comparison_path, "\n")
}
