# ============================================================
# NO_GJEN_002 - when was the aerial photo of each polygon taken?
#
# A national orthophoto "mosaic" is stitched together from many separate
# flight projects, often several years apart (the 2025 mosaic used here
# spans flights from 2011 to 2024). The canopy height of a polygon is
# therefore a measurement of the year and season ITS photo was taken, not
# of the mosaic's nominal year. This script attaches that flight date to
# every polygon with a canopy-height value, so that
#   - regional differences can be checked against differences in photo
#     age and season, and
#   - a later run on newer imagery can be compared polygon by polygon
#     with the real time between the two photos.
#
# INPUTS (Norge i bilder mosaic metadata, delivered with the mosaic):
#   ORTHOPHOTO_VISIBLE_PROJECTS - a polygon layer with one feature per
#       flight project, outlining where that project is VISIBLE in the
#       finished mosaic. The features must not overlap (checked below):
#       each spot of the mosaic shows exactly one project. Required field:
#       PROJECT. (mosaic_coverage_by_project.gpkg)
#   ORTHOPHOTO_PROJECT_GRID - the mosaic's grid cells, one row per cell
#       and flight project that contributes imagery to it, with that
#       project's flight dates inside the cell. Required fields: NAME
#       (cell), PROJECT, STARTDATO, SLUTTDATO.
#       (metadata_omløpsprosjekt_mosaic_v2_2025.gpkg, layer mosaic_grid)
#   CHM_RESULTS_DIR - folder with the meta_chm_national_*.csv files of a
#       canopy-height run; only polygons listed there are dated.
#
# METHOD
#   1. Cut each wetland polygon by the visible-project outlines: which
#      project(s) is the polygon actually seen in, and how much of it?
#   2. Cut those pieces by the grid cells and look up the flight dates of
#      that project in that cell. The grid also has a LAYER_ORDER field,
#      but it is not needed (and not used): the visible-project outlines
#      already say which project is on top at every spot.
#   3. Per polygon, report the project covering the largest share and
#      its flight dates, plus the earliest and latest flight over all
#      projects the polygon is seen in.
#
# OUTPUT 1: <CHM_RESULTS_DIR>/orthophoto_flight_dates.csv, one row per
# polygon:
#   id                    NiN polygon id (as in the canopy-height files)
#   flight_project        project covering the largest share of the polygon
#   flight_project_name   its full name, e.g. "Nordkinnhalvøya 2012"
#   nib_project_id        its Norge i bilder project id (NibPrjId); the
#                         project's official metadata can be looked up by it
#   original_pixel_size_m pixel size of that project's photos before the
#                         mosaic was resampled to 50 cm (0.1, 0.25 or 0.4 m)
#   flight_project_share  that share (0-1)
#   flight_start, flight_end  flight dates of that project over the polygon
#   earliest_flight, latest_flight  over all projects the polygon is seen in
#   n_flight_projects     number of projects the polygon is seen in
#   share_without_photo   share of the polygon outside every project outline
#
# OUTPUT 2: <CHM_RESULTS_DIR>/orthophoto_flight_projects.csv, one row per
# flight project the polygons are seen in, with every attribute of the
# visible-project layer under its original (shortened) Norge i bilder field
# name - e.g. Prosjektna (project name), Dekningsnu (coverage number), Eier
# (owner), Pixelstorr (pixel size, m), Flyfirma (flight company), Produsent
# (producer), Produktspe (product specification), Fotodato (photo date,
# often empty) - plus, from this script:
#   first_flight, last_flight  flight dates of the project in the grid
#   visible_km2                area where the project is visible in the mosaic
#   n_polygons                 polygons whose main project it is
# ============================================================

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

suppressMessages({ library(sf); library(dplyr) })
# Planar geometry: everything is in EPSG:25833, and the national NiN layer
# has geometries s2 rejects (see run_meta_chm_on_polygons.R).
sf_use_s2(FALSE)

visible_path <- Sys.getenv("ORTHOPHOTO_VISIBLE_PROJECTS")
grid_path    <- Sys.getenv("ORTHOPHOTO_PROJECT_GRID")
results_dir  <- Sys.getenv("CHM_RESULTS_DIR")
for (v in c("ORTHOPHOTO_VISIBLE_PROJECTS", "ORTHOPHOTO_PROJECT_GRID", "CHM_RESULTS_DIR")) {
  if (!nzchar(Sys.getenv(v))) stop("Set ", v, " (see the header of this script).")
}

# ---- polygons that have a canopy-height value ---------------------------
chm_files <- list.files(results_dir, pattern = "^meta_chm_national_.*\\.csv$", full.names = TRUE)
if (length(chm_files) == 0) stop("No meta_chm_national_*.csv in ", results_dir)
ids <- unique(unlist(lapply(chm_files, function(f) as.character(read.csv(f)$id))))
cat("Polygons with a canopy-height value:", length(ids), "\n")

gdb <- list.files(file.path("..", "Data", "OpenS_data", "nin_data"), pattern = "\\.gdb$", full.names = TRUE)[1]
if (is.na(gdb)) stop("No NiN geodatabase under Data/OpenS_data/nin_data (run Fetch/fetch_nin_data.R).")
polys <- st_read(gdb, layer = "naturtyper_nin_omr", quiet = TRUE) %>%
  rename(geometry = SHAPE) %>% st_set_geometry("geometry") %>%
  rename(id = identifikasjon_lokalId) %>% mutate(id = as.character(id)) %>%
  filter(id %in% ids) %>% dplyr::select(id) %>%
  st_make_valid() %>% st_transform(25833)
cat("Found in the NiN data:", nrow(polys), "\n")
if (nrow(polys) < length(ids)) {
  warning(length(ids) - nrow(polys), " polygon id(s) are not in the current NiN data ",
          "(changed since the canopy heights were computed?) and get no flight date.")
}
polys$poly_m2 <- as.numeric(st_area(polys))

# ---- mosaic metadata -----------------------------------------------------
visible_all <- st_read(visible_path, quiet = TRUE) %>% st_make_valid() %>% st_transform(25833)
visible <- dplyr::select(visible_all, PROJECT)
overlap_m2 <- sum(as.numeric(st_area(visible))) - as.numeric(st_area(st_union(visible)))
if (overlap_m2 > 1e6) {
  stop("The visible-project outlines overlap by ", round(overlap_m2 / 1e6), " km2, so they ",
       "do not say which project is visible where. This script needs non-overlapping outlines.")
}
grid <- st_read(grid_path, layer = "mosaic_grid", quiet = TRUE) %>%
  st_transform(25833) %>% dplyr::select(NAME, PROJECT, STARTDATO, SLUTTDATO)

# ---- 1. polygon x visible project ----------------------------------------
cat("Intersecting polygons with the visible-project outlines...\n")
pieces <- suppressWarnings(st_intersection(polys, visible))

# ---- 2. pieces x grid cells of the same project ---------------------------
cat("Looking up flight dates per grid cell...\n")
cells <- suppressWarnings(st_intersection(pieces, rename(grid, cell_project = PROJECT))) %>%
  filter(cell_project == PROJECT)
cells$m2 <- as.numeric(st_area(cells))
cells <- st_drop_geometry(cells)
n_undated <- length(setdiff(unique(pieces$PROJECT), unique(cells$PROJECT)))
if (n_undated > 0) {
  warning(n_undated, " visible project(s) have no matching grid rows; polygons seen only ",
          "in them get no flight dates.")
}

# ---- 3. one row per polygon ----------------------------------------------
per_project <- cells %>%
  group_by(id, PROJECT) %>%
  summarise(m2 = sum(m2), start = min(STARTDATO), end = max(SLUTTDATO), .groups = "drop")
out <- per_project %>%
  group_by(id) %>%
  summarise(
    flight_project    = PROJECT[which.max(m2)],
    covered_m2        = sum(m2),
    top_m2            = max(m2),
    flight_start      = start[which.max(m2)],
    flight_end        = end[which.max(m2)],
    earliest_flight   = min(start),
    latest_flight     = max(end),
    n_flight_projects = n_distinct(PROJECT),
    .groups = "drop") %>%
  right_join(st_drop_geometry(polys), by = "id") %>%
  left_join(st_drop_geometry(visible_all) %>%
              transmute(flight_project = PROJECT, flight_project_name = Prosjektna,
                        nib_project_id = NibPrjId, original_pixel_size_m = as.numeric(Pixelstorr)),
            by = "flight_project") %>%
  mutate(
    flight_project_share = round(top_m2 / poly_m2, 3),
    share_without_photo  = round(pmax(0, 1 - coalesce(covered_m2, 0) / poly_m2), 3)) %>%
  dplyr::select(id, flight_project, flight_project_name, nib_project_id, original_pixel_size_m,
                flight_project_share, flight_start, flight_end,
                earliest_flight, latest_flight, n_flight_projects, share_without_photo) %>%
  arrange(id)

out_path <- file.path(results_dir, "orthophoto_flight_dates.csv")
write.csv(out, out_path, row.names = FALSE)
cat("\nWritten:", out_path, "\n")

# ---- one row per flight project ------------------------------------------
projects <- visible_all %>%
  mutate(visible_km2 = round(as.numeric(st_area(.)) / 1e6, 1)) %>%
  st_drop_geometry() %>%
  filter(PROJECT %in% per_project$PROJECT) %>%
  left_join(st_drop_geometry(grid) %>% group_by(PROJECT) %>%
              summarise(first_flight = min(STARTDATO), last_flight = max(SLUTTDATO)),
            by = "PROJECT") %>%
  left_join(count(out, flight_project, name = "n_polygons"), by = c("PROJECT" = "flight_project")) %>%
  mutate(n_polygons = coalesce(n_polygons, 0L)) %>%
  arrange(first_flight)
proj_path <- file.path(results_dir, "orthophoto_flight_projects.csv")
write.csv(projects, proj_path, row.names = FALSE)
cat("Written:", proj_path, "(", nrow(projects), "flight projects )\n")
cat("Polygons dated:", sum(!is.na(out$flight_start)), "of", nrow(out), "\n")
cat("Seen in more than one flight project:", sum(out$n_flight_projects > 1, na.rm = TRUE), "\n")
cat("Flight year of the main project:\n")
print(table(substr(out$flight_start, 1, 4), useNA = "ifany"))
cat("Flight month of the main project:\n")
print(table(substr(out$flight_start, 6, 7), useNA = "ifany"))
