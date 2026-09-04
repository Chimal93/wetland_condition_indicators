# ============================================================
# Extract AR50 Skog (forest, arealtype==30) polygons nationally - the open
# substitute for "nasjonalt grunnkart skog" used to define the forest
# reference (X0, poor condition) in Stage 4 of
# NO_GJEN_001_wetland_pipeline.R. Same source/method as
# build_ar50_wetland_lidar_coverage.R's Myr (arealtype==60) extraction,
# just a different class - see that script for the AR50 source/license
# details (NIBIO, NLOD-open, kart8.nibio.no/uttak_Download/ar50/).
#
# Output: ../Data/OpenS_data/ar50_skog_national.gpkg
# ============================================================

library(sf)
library(dplyr)

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  tried <- tryCatch({ setwd(dirname(sys.frame(1)$ofile)); TRUE }, error = function(e) FALSE)
  if (!tried) message("Note: keeping current working directory (", getwd(), ").")
}

out_dir     <- file.path("..", "Data", "OpenS_data")
staging_dir <- file.path("..", "Data", "spatial", "_staging_ar50_skog")
if (!dir.exists(out_dir))     dir.create(out_dir, recursive = TRUE)
if (!dir.exists(staging_dir)) dir.create(staging_dir, recursive = TRUE)

ar50_urls <- c(
  Oslo = "https://kart8.nibio.no/uttak_Download/ar50/03_4258_ar50_gml.zip",
  Vestland = "https://kart8.nibio.no/uttak_Download/ar50/46_4258_ar50_gml.zip",
  Trondelag = "https://kart8.nibio.no/uttak_Download/ar50/50_4258_ar50_gml.zip",
  Nordland = "https://kart8.nibio.no/uttak_Download/ar50/18_4258_ar50_gml.zip",
  Telemark = "https://kart8.nibio.no/uttak_Download/ar50/40_4258_ar50_gml.zip",
  Agder = "https://kart8.nibio.no/uttak_Download/ar50/42_4258_ar50_gml.zip",
  MoreOgRomsdal = "https://kart8.nibio.no/uttak_Download/ar50/15_4258_ar50_gml.zip",
  Finnmark = "https://kart8.nibio.no/uttak_Download/ar50/56_4258_ar50_gml.zip",
  Troms = "https://kart8.nibio.no/uttak_Download/ar50/55_4258_ar50_gml.zip",
  Ostfold = "https://kart8.nibio.no/uttak_Download/ar50/31_4258_ar50_gml.zip",
  Innlandet = "https://kart8.nibio.no/uttak_Download/ar50/34_4258_ar50_gml.zip",
  Vestfold = "https://kart8.nibio.no/uttak_Download/ar50/39_4258_ar50_gml.zip",
  Rogaland = "https://kart8.nibio.no/uttak_Download/ar50/11_4258_ar50_gml.zip",
  Akershus = "https://kart8.nibio.no/uttak_Download/ar50/32_4258_ar50_gml.zip",
  Buskerud = "https://kart8.nibio.no/uttak_Download/ar50/33_4258_ar50_gml.zip"
)

read_skog <- function(name, url) {
  extract_dir <- file.path(staging_dir, name)
  if (!dir.exists(extract_dir)) {
    zip_path <- file.path(staging_dir, paste0(name, ".zip"))
    download.file(url, zip_path, mode = "wb", quiet = TRUE)
    unzip(zip_path, exdir = extract_dir)
    file.remove(zip_path)
  }
  gml_file <- list.files(extract_dir, pattern = "\\.gml$", full.names = TRUE)[1]
  d <- st_read(gml_file, layer = "ArealressursFlate", quiet = TRUE)
  d <- d[as.character(d$arealtype) == "30", ]
  if (nrow(d) == 0) return(NULL)
  geom_col <- attr(d, "sf_column")
  if (geom_col != "geometry") {
    names(d)[names(d) == geom_col] <- "geometry"
    st_geometry(d) <- "geometry"
  }
  d %>% st_transform(25833) %>% st_make_valid() %>% dplyr::select(geometry)
}

cat("Downloading AR50 for 15 counties and extracting Skog (forest) polygons...\n")
skog_list <- list()
for (name in names(ar50_urls)) {
  t0 <- Sys.time()
  s <- tryCatch(read_skog(name, ar50_urls[[name]]),
                error = function(e) { cat("ERROR", name, ":", conditionMessage(e), "\n"); NULL })
  if (!is.null(s)) {
    skog_list[[name]] <- s
    cat(" ", name, ":", nrow(s), "skog polygons,", round(as.numeric(Sys.time() - t0), 1), "sec\n")
  }
}

skog_all <- do.call(rbind, skog_list)
skog_all$area_m2 <- as.numeric(st_area(skog_all))
cat("\nTotal Skog (forest, arealtype=30) polygons nationally:", nrow(skog_all), "\n")
cat("Total Skog area (km^2):", round(sum(skog_all$area_m2) / 1e6, 0), "\n")

st_write(skog_all, file.path(out_dir, "ar50_skog_national.gpkg"), delete_dsn = TRUE, quiet = TRUE)
cat("Saved:", file.path(out_dir, "ar50_skog_national.gpkg"), "\n")

unlink(staging_dir, recursive = TRUE)
