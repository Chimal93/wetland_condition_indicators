# ============================================================
# Shared export helper: write an indicator in the ecosystemCondition
# platform format + the Miljødirektoratet delivery tables.
#
# Platform format (https://ninanor.github.io/ecosystemCondition/, data
# structure chapter; example file indicators/indicatorMaps/naturindeks_map.rds):
#   sf object, one row per spatial unit, columns
#     area, areaId, v_YYYY, sd_YYYY, i_YYYY, reference_high, reference_low, thr
#   Column spelling follows the platform's own example file (`reference_`);
#   the docs and the contract text carry the typo `referance_`.
#   CRS: EPSG:25833 (contract + docs; the example file happens to be 4326).
#
# One call writes, into out_dir:
#   <ID>_indicatorMap_<unit>.rds   sf, EPSG:25833, schema columns (one per unit set)
#   <ID>_values.csv                region rows (+ optional national row), no geometry,
#                                  schema columns + any supplementary columns
#   <ID>_values.xlsx               sheet "values" (= csv), sheet "metadata"
#                                  (field/value), one extra sheet per finer unit set
#   <ID>_map.png                   report figure of the primary unit set (i_<last year>)
#
# Input contract (long format, so multi-period indicators work naturally):
#   units: named list of sf objects. Each sf has columns
#            area, areaId, year, v, sd, i, reference_high, reference_low, thr
#          plus geometry (any CRS) and optionally supplementary columns
#          (kept, after the schema columns, in csv/xlsx but NOT in the rds).
#          One row per unit x year. The FIRST element is the primary set
#          (typically "region"); it feeds the csv "values" sheet and the png.
#   national: optional data.frame with the same non-geometry columns
#             (area = "Norge"), appended to the csv/xlsx values only.
#   metadata: named character vector / list -> "metadata" sheet, in order.
# ============================================================

suppressPackageStartupMessages({
  library(sf); library(dplyr); library(tidyr); library(readr); library(writexl); library(ggplot2)
})

.schema_long <- c("area", "areaId", "year", "v", "sd", "i", "reference_high", "reference_low", "thr")

.check_long <- function(x, what) {
  miss <- setdiff(.schema_long, names(x))
  if (length(miss)) stop(what, ": missing columns ", paste(miss, collapse = ", "))
  if (any(!is.na(x$i) & (x$i < 0 | x$i > 1))) stop(what, ": indicator values outside [0, 1]")
  if (any(duplicated(x[, c("areaId", "year"), drop = TRUE] %>% as.data.frame() %>% select(areaId, year)))) {
    stop(what, ": duplicated areaId x year")
  }
  invisible(TRUE)
}

# long (one row per unit x year) -> platform wide (one row per unit)
.to_wide <- function(x) {
  df <- if (inherits(x, "sf")) st_drop_geometry(x) else x
  supp <- setdiff(names(df), .schema_long)
  yrs  <- sort(unique(df$year))
  wide <- df %>%
    select(area, areaId, year, v, sd, i) %>%
    pivot_wider(names_from = year, values_from = c(v, sd, i), names_glue = "{.value}_{year}")
  ordered <- c("area", "areaId", unlist(lapply(yrs, function(y) paste0(c("v_", "sd_", "i_"), y))))
  refs <- df %>%
    group_by(area, areaId) %>%
    summarise(reference_high = first(reference_high), reference_low = first(reference_low),
              thr = first(thr), .groups = "drop")
  out <- wide %>% select(all_of(ordered)) %>% left_join(refs, by = c("area", "areaId"))
  if (length(supp)) {
    # Supplementary columns are per unit x year too: with several years they
    # are suffixed like the schema columns (n_2021, n_2024, ...); with a
    # single year they keep their plain names.
    if (length(yrs) > 1) {
      s <- df %>% select(area, areaId, year, all_of(supp)) %>%
        pivot_wider(names_from = year, values_from = all_of(supp), names_glue = "{.value}_{year}")
    } else {
      s <- df %>% select(area, areaId, all_of(supp))
    }
    out <- out %>% left_join(s, by = c("area", "areaId"))
    supp <- setdiff(names(s), c("area", "areaId"))   # names as they now appear (possibly year-suffixed)
  }
  list(wide = out, years = yrs, supplementary = supp)
}

export_platform_indicator <- function(id, units, metadata, out_dir,
                                      national = NULL, crs = 25833,
                                      png_title = NULL, write_png = TRUE,
                                      xlsx_max_rows = 200000) {
  stopifnot(is.list(units), length(units) >= 1, !is.null(names(units)))
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  written <- character(0)

  # --- indicator maps (rds), one per unit set ---
  wide_sets <- list()
  for (nm in names(units)) {
    u <- units[[nm]]
    .check_long(u, nm)
    w <- .to_wide(u)
    geom <- u %>% group_by(areaId) %>% slice(1) %>% ungroup() %>% select(areaId) %>% st_transform(crs)
    st_geometry(geom) <- "geometry"   # normalise the geometry column name (gpkg -> "geom", shp -> "geometry")
    map_sf <- geom %>% inner_join(w$wide %>% select(-all_of(w$supplementary)), by = "areaId") %>%
      relocate(area, areaId) %>%
      relocate(geometry, .after = last_col())
    p <- file.path(out_dir, paste0(id, "_indicatorMap_", nm, ".rds"))
    saveRDS(map_sf, p); written <- c(written, p)
    wide_sets[[nm]] <- w
  }

  # --- values table (primary set + optional national row) ---
  primary <- names(units)[1]
  values <- wide_sets[[primary]]$wide
  if (!is.null(national)) {
    nat <- .to_wide(national)$wide
    values <- bind_rows(values, nat)
  }
  p_csv <- file.path(out_dir, paste0(id, "_values.csv"))
  write_csv(values, p_csv, na = ""); written <- c(written, p_csv)

  # --- xlsx: values + metadata (+ finer sets) ---
  meta_df <- tibble(field = names(metadata), value = unname(vapply(metadata, function(v) paste(as.character(v), collapse = "; "), "")))
  sheets <- list(values = values, metadata = meta_df)
  for (nm in setdiff(names(units), primary)) {
    w <- wide_sets[[nm]]$wide
    if (nrow(w) > xlsx_max_rows) {
      cat("  (", nm, ": ", nrow(w), " rows - not written to xlsx, see the .rds; limit ", xlsx_max_rows, ")
", sep = "")
      next
    }
    sheets[[nm]] <- w
  }
  p_xlsx <- file.path(out_dir, paste0(id, "_values.xlsx"))
  write_xlsx(sheets, p_xlsx); written <- c(written, p_xlsx)

  # --- png of the primary set, last year ---
  if (write_png) {
    yrs <- wide_sets[[primary]]$years
    icol <- paste0("i_", max(yrs))
    map_sf <- readRDS(file.path(out_dir, paste0(id, "_indicatorMap_", primary, ".rds")))
    lab <- map_sf %>% st_point_on_surface() %>% suppressWarnings()
    g <- ggplot(map_sf) +
      geom_sf(aes(fill = .data[[icol]]), colour = "grey30", linewidth = 0.3) +
      geom_sf_text(data = lab, aes(label = paste0(area, "\n", sprintf("%.2f", .data[[icol]]))), size = 3) +
      scale_fill_viridis_c(limits = c(0, 1), name = "Indicator\nvalue") +
      labs(title = if (is.null(png_title)) id else png_title,
           subtitle = paste0(icol, " (", metadata[["Indicator name (public)"]] %||% "", ")"),
           caption = paste0("Platform format: v_YYYY / sd_YYYY / i_YYYY / reference_high / reference_low / thr - EPSG:", crs)) +
      theme_void(base_size = 11) + theme(plot.background = element_rect(fill = "white", colour = NA))
    p_png <- file.path(out_dir, paste0(id, "_map.png"))
    ggsave(p_png, g, width = 7, height = 8, dpi = 200); written <- c(written, p_png)
  }

  cat("Exported", id, "->", out_dir, "\n"); for (w in written) cat("  -", basename(w), "\n")
  invisible(written)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
