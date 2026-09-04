# ============================================================
# One-time utility: fetch Norway's bioclimatic zones (Moen) from the public
# NINA / Miljødirektoratet ArcGIS REST service and cache them locally as
# Data/spatial/bioclim/soner2017.shp, so that Stage 3 of
# NO_GJEN_001_wetland_pipeline.R can dissolve/label them without needing
# NINA-internal R:/P: drive access at all.
#
# Service (public, no auth required):
#   https://arcgis06.miljodirektoratet.no/arcgis/rest/services/
#     NIN_hjelpelag/BioklimatiskeSoner/MapServer/0
#   Layer "Bio soner", polygon, EPSG:25833, copyright NINA.
#   351,402 features nationwide (1km x 1km tiles), so this pages through
#   the query endpoint (max 1000 records/request) - takes a few minutes.
#
# NOTE: st_read() reading directly from the query URL silently drops
# attribute fields for this service (a GDAL/vsicurl quirk with this
# server's response) - each page is downloaded to a local temp file first,
# which reads back correctly with fields intact.
# ============================================================

library(sf)
library(dplyr)

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  # sys.frame(1)$ofile only resolves when this script is source()'d (as in
  # NO_GJEN_001_wetland_pipeline.R's convention). When run directly via
  # `Rscript fetch_bioclim_zones.R`, there's no source() frame to read, so
  # fall back to leaving the working directory as-is (assumed already ..R/).
  tried <- tryCatch({ setwd(dirname(sys.frame(1)$ofile)); TRUE }, error = function(e) FALSE)
  if (!tried) message("Note: keeping current working directory (", getwd(), ").")
}

# Writes into OpenS_data (the canonical, actively-refetched copy used by
# NO_GJEN_001_wetland_pipeline.R) - not Data/spatial, which keeps its own
# frozen 2026-07-21 snapshot for diffing against future reruns.
out_dir  <- file.path("..", "Data", "OpenS_data", "bioclim")
out_path <- file.path(out_dir, "soner2017.shp")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

base_url <- paste0(
  "https://arcgis06.miljodirektoratet.no/arcgis/rest/services/",
  "NIN_hjelpelag/BioklimatiskeSoner/MapServer/0/query"
)

page_size <- 1000

count_url <- paste0(base_url, "?where=1%3D1&returnCountOnly=true&f=json")
total_n <- jsonlite::fromJSON(count_url)$count
cat("Total features to fetch:", total_n, "\n")

n_pages <- ceiling(total_n / page_size)
pages <- vector("list", n_pages)

for (i in seq_len(n_pages)) {
  offset <- (i - 1) * page_size
  url <- paste0(
    base_url,
    "?where=1%3D1",
    "&outFields=Sone_navn,Sone_kode",
    "&outSR=25833",
    "&f=geojson",
    "&resultRecordCount=", page_size,
    "&resultOffset=", offset
  )

  page <- NULL
  for (attempt in 1:3) {
    page <- tryCatch({
      tmp <- tempfile(fileext = ".geojson")
      download.file(url, tmp, mode = "wb", quiet = TRUE)
      d <- st_read(tmp, quiet = TRUE)
      file.remove(tmp)
      d
    }, error = function(e) NULL)
    if (!is.null(page)) break
    Sys.sleep(1)
  }

  if (is.null(page)) {
    stop("Failed to fetch page ", i, " (offset ", offset, ") after 3 attempts.")
  }

  pages[[i]] <- page

  if (i %% 20 == 0 || i == n_pages) {
    cat(sprintf("  page %d/%d (offset %d) - %d features fetched so far\n",
                i, n_pages, offset, sum(sapply(pages[1:i], nrow))))
  }
  Sys.sleep(0.05)  # light throttle - be a good citizen to a public government server
}

bioclim_raw <- bind_rows(pages)
cat("\nTotal features fetched:", nrow(bioclim_raw), "\n")
print(table(bioclim_raw$Sone_navn))

st_write(bioclim_raw, out_path, delete_dsn = TRUE, quiet = TRUE)
cat("\nSaved to:", normalizePath(out_path), "\n")
cat("NO_GJEN_001_wetland_pipeline.R's Stage 3 will now find this file and\n",
    "dissolve/label it automatically - no NINA drive access needed.\n", sep = "")
