# ============================================================
# NO_CONN_001 - extract/filter the raw N50 (+ NVE) layers down to just
# the object types the LUI infrastructure index (Erikstad et al. 2023)
# actually needs, harmonized across 2006/2013/2023's differing schemas.
#
# Reads from Data/infra_index_source/ (fetch_n50_infrastructure_data.R
# + convert_n50_2006_sosi_to_gpkg.R must have already run). Writes
# harmonized output to a NEW dedicated folder,
# Data/infra_index_source/N50_extracted/ - kept separate again, so the
# raw multi-GB national downloads and the much smaller filtered output
# don't mix.
#
# This script does EXTRACTION/FILTERING ONLY - it does not compute the
# LUI index itself (100m grid, 500m focal-window density count,
# log-transform, BI:LCI:ALI weighting). That's the next build step,
# once this harmonized output exists.
#
# --- The three years have THREE DIFFERENT SCHEMAS, confirmed by ---
# --- directly reading each one's actual layers/fields/values:    ---
#
#   2006 (GPKG, built by convert_n50_2006_sosi_to_gpkg.R):
#     layers <theme>_<geomtype> e.g. bygg_points, samferdsel_lines,
#     arealdekke_polygons. Discriminator field: `objekttypenavn`.
#     Uses ITS OWN object-type name strings, e.g. "BygningsEnhet" not
#     "Bygning", "Flyplass" not "Lufthavn", "Sportplass" not
#     "SportIdrettPlass", "Industri" not "Industriområde",
#     "SenterlinjeVeg" not "Veglenke"/"VegSenterlinje".
#
#   2013 (FGDB): semi-granular layers close to SOSI object-type names -
#     N50_BygningsPunkt (single-purpose, no discriminator needed - every
#     row IS "Bygning"), N50_AnleggsPunkt / N50_AnleggsLinje (mixed,
#     `OBJTYPE` field), N50_VegSti (`OBJTYPE`, values incl.
#     "VegSenterlinje"/"Traktorveg"/"Sti"), N50_Bane (single-purpose),
#     N50_ArealdekkeFlate (mixed, `OBJTYPE`, note "TettBebyggelse" -
#     capital B mid-word, unlike 2023's "Tettbebyggelse").
#
#   2023 (FGDB): consolidated by package+geometry-type -
#     N50_BygningerOgAnlegg_{omrade,posisjon,senterlinje} (mixed,
#     `objtype`, lowercase field name), N50_Samferdsel_senterlinje
#     (mixed, `objtype`, values incl. "Veglenke"/"Bane" - note: roads
#     use plain "Veglenke" here, NOT "VegSenterlinje" like 2013 - the
#     Sti/Traktorveg split isn't in this field, it's in `typeveg`
#     instead, confirmed separately), N50_Arealdekke_omrade (mixed,
#     `objtype`).
#
# Given this, matching is done against a small ALIAS list per canonical
# category (built from what's been directly verified) rather than a
# single hardcoded value per category - and unmatched/unexpected values
# actually present in the data are printed at the end of each run, so
# any remaining year-specific naming quirk in a layer that wasn't
# manually spot-checked surfaces immediately instead of silently
# dropping data.
#
# KNOWN UNRESOLVED GAP (not handled here, not a fetch/extraction
# problem): LCI's "other built-up areas" has no confirmed N50 object
# type - ambiguous even in the source paper's own Table 1.
# Not extracted.
# ============================================================

library(sf)
library(dplyr)

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

source_dir <- file.path("..", "Data", "infra_index_source")
out_dir    <- file.path(source_dir, "N50_extracted")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

# ---------------------------------------------------------------
# Canonical category -> known alias list. Add to this if a future year
# turns out to use yet another name - don't silently guess.
# ---------------------------------------------------------------
aliases <- list(
  BI_Buildings            = c("Bygning", "BygningsEnhet"),
  BI_PowerLines           = c("LuftledningLH"),
  BI_MainRoads            = c("VegSenterlinje", "SenterlinjeVeg", "Veglenke"),
  BI_Railways             = c("Bane"),
  BI_TechnicalFacilities  = c("Hoppbakke", "MastTele", "Vindkraftverk", "Tårn"),
  LCI_UrbanFabric         = c("BymessigBebyggelse", "Tettbebyggelse", "TettBebyggelse"),
  LCI_Industrial          = c("Industriområde", "Industri"),
  LCI_Airports            = c("Lufthavn", "Rullebane", "Flyplass"),
  LCI_MinesDumpsConstr    = c("Steinbrudd", "Steintipp", "Gruve"),
  LCI_Graveyards          = c("Gravplass"),
  LCI_SportLeisure        = c("SportIdrettPlass", "Sportplass", "Golfbane", "Alpinbakke"),
  ALI_AgriculturalFields  = c("DyrketMark"),
  ALI_TractorRoadsFootpaths = c("Traktorveg", "Sti")
)
category_of <- function(objtype) {
  hit <- vapply(names(aliases), function(cat) objtype %in% aliases[[cat]], logical(1))
  if (any(hit)) names(aliases)[hit][1] else NA_character_
}
top_level <- function(cat) sub("_.*", "", cat)  # "BI_Buildings" -> "BI"

# ---------------------------------------------------------------
# Per-year layer + discriminator-field definitions. `field = NA` means
# the layer is single-purpose (no discriminator needed, every row gets
# the given fixed object type).
# ---------------------------------------------------------------
year_defs <- list(
  "2006" = list(
    dsn = file.path(source_dir, "N50", "2006", "N50_2006.gpkg"),
    layers = list(
      list(layer = "bygg_points",        field = "objekttypenavn", fixed = NA),
      list(layer = "bygg_lines",         field = "objekttypenavn", fixed = NA),
      list(layer = "bygg_polygons",      field = "objekttypenavn", fixed = NA),
      list(layer = "samferdsel_points",  field = "objekttypenavn", fixed = NA),
      list(layer = "samferdsel_lines",   field = "objekttypenavn", fixed = NA),
      list(layer = "arealdekke_points",  field = "objekttypenavn", fixed = NA),
      list(layer = "arealdekke_lines",   field = "objekttypenavn", fixed = NA),
      list(layer = "arealdekke_polygons",field = "objekttypenavn", fixed = NA)
    )
  ),
  "2013" = list(
    dsn = file.path(source_dir, "N50", "2013", "N50_Kartdata_2013.gdb"),
    layers = list(
      list(layer = "N50_BygningsPunkt",   field = NA, fixed = "Bygning"),
      list(layer = "N50_AnleggsPunkt",    field = "OBJTYPE", fixed = NA),
      list(layer = "N50_AnleggsLinje",    field = "OBJTYPE", fixed = NA),
      list(layer = "N50_VegSti",          field = "OBJTYPE", fixed = NA),
      list(layer = "N50_Bane",            field = NA, fixed = "Bane"),
      list(layer = "N50_ArealdekkeFlate", field = "OBJTYPE", fixed = NA)
    )
  ),
  "2023" = list(
    dsn = file.path(source_dir, "N50", "2023", "Basisdata_0000_Norge_25833_N50Kartdata_FGDB.gdb"),
    layers = list(
      list(layer = "N50_BygningerOgAnlegg_omrade",     field = "objtype", fixed = NA),
      list(layer = "N50_BygningerOgAnlegg_posisjon",   field = "objtype", fixed = NA),
      list(layer = "N50_BygningerOgAnlegg_senterlinje",field = "objtype", fixed = NA),
      list(layer = "N50_Samferdsel_senterlinje",       field = "objtype", fixed = NA),
      list(layer = "N50_Arealdekke_omrade",            field = "objtype", fixed = NA)
    )
  )
)

# 2023's Sti/Traktorveg live in a DIFFERENT field (`typeveg`) on the same
# Samferdsel_senterlinje layer, not `objtype` (which only has
# "Veglenke"/"Bane" there) - confirmed directly (2026-08-06). Handled as
# a separate targeted pass below rather than forcing it into the
# generic loop, since it's a a different field on the same layer.
extract_2023_sti_traktorveg <- function(dsn) {
  q <- "SELECT * FROM \"N50_Samferdsel_senterlinje\" WHERE \"typeveg\" IN ('sti', 'traktorveg')"
  x <- tryCatch(st_read(dsn, query = q, quiet = TRUE), error = function(e) NULL)
  if (is.null(x) || nrow(x) == 0) return(NULL)
  if (is.na(st_crs(x)$epsg) || st_crs(x)$epsg != 25833) x <- st_transform(x, 25833)
  x %>%
    mutate(
      objtype_original = typeveg,
      category = "ALI_TractorRoadsFootpaths",
      geom_type = "lines"
    ) %>%
    select(objtype_original, category, geom_type)
}

# ---------------------------------------------------------------
# Main extraction loop
# ---------------------------------------------------------------
geom_type_of <- function(x) {
  gt <- unique(as.character(st_geometry_type(x, by_geometry = FALSE)))
  if (grepl("POINT", gt)) "points" else if (grepl("LINE", gt)) "lines" else "polygons"
}

extract_year <- function(year, def) {
  cat("\n========== YEAR", year, "==========\n")
  if (!file.exists(def$dsn) && !dir.exists(def$dsn)) {
    message("  Source not found at ", def$dsn, " - skipping this year.")
    return(invisible(NULL))
  }

  results <- list()
  unmatched_log <- list()

  for (ld in def$layers) {
    cat(" -", ld$layer, "... ")
    if (is.na(ld$field)) {
      # single-purpose layer, no filtering needed - fixed object type applies to every row
      x <- tryCatch(st_read(def$dsn, layer = ld$layer, quiet = TRUE), error = function(e) NULL)
      if (is.null(x) || nrow(x) == 0) { cat("empty/unreadable, skipped\n"); next }
      x$objtype_original <- ld$fixed
    } else {
      # discover distinct values present, so unmatched ones can be reported
      dv <- tryCatch(
        st_read(def$dsn, query = sprintf("SELECT DISTINCT \"%s\" AS v FROM \"%s\"", ld$field, ld$layer),
                quiet = TRUE),
        error = function(e) NULL
      )
      if (is.null(dv)) { cat("could not list distinct values, skipped\n"); next }
      present_values <- st_drop_geometry(dv)$v
      wanted <- present_values[!is.na(present_values) & vapply(present_values, function(v) !is.na(category_of(v)), logical(1))]
      unmatched <- setdiff(present_values, wanted)
      if (length(unmatched) > 0) unmatched_log[[ld$layer]] <- unmatched

      if (length(wanted) == 0) { cat("no matching object types present, skipped\n"); next }
      in_list <- paste(sprintf("'%s'", gsub("'", "''", wanted)), collapse = ", ")
      q <- sprintf("SELECT * FROM \"%s\" WHERE \"%s\" IN (%s)", ld$layer, ld$field, in_list)
      x <- tryCatch(st_read(def$dsn, query = q, quiet = TRUE), error = function(e) NULL)
      if (is.null(x) || nrow(x) == 0) { cat("query returned nothing, skipped\n"); next }
      x$objtype_original <- st_drop_geometry(x)[[ld$field]]
    }

    # Defensive reprojection: 2013's source FGDB is mislabeled -
    # Geonorge's own filename claims EPSG:25833 but the data is actually
    # embedded as EPSG:32633 (WGS84/UTM33N, not ETRS89/UTM33N) - confirmed
    # directly by reading the raw source CRS. The practical coordinate
    # shift is small (tens of cm in Norway) and immaterial for a 100m-grid
    # algorithm, but reproject explicitly anyway rather than leave a
    # silent datum mismatch between years.
    if (is.na(st_crs(x)$epsg) || st_crs(x)$epsg != 25833) {
      x <- st_transform(x, 25833)
    }

    x <- x %>%
      mutate(
        category = vapply(objtype_original, category_of, character(1)),
        geom_type = geom_type_of(x)
      ) %>%
      filter(!is.na(category)) %>%
      select(objtype_original, category, geom_type)

    cat(nrow(x), "matched features\n")
    if (nrow(x) > 0) results[[ld$layer]] <- x
  }

  # 2023's Sti/Traktorveg special-case pass
  if (year == "2023") {
    cat(" - N50_Samferdsel_senterlinje (typeveg field, Sti/Traktorveg) ... ")
    extra <- extract_2023_sti_traktorveg(def$dsn)
    if (!is.null(extra) && nrow(extra) > 0) {
      cat(nrow(extra), "matched features\n")
      results[["sti_traktorveg_2023"]] <- extra
    } else {
      cat("none found\n")
    }
  }

  if (length(unmatched_log) > 0) {
    cat("\n  Unmatched object-type values present in", year, "(not in any known alias list - review if any look relevant):\n")
    for (ly in names(unmatched_log)) {
      cat("   ", ly, ":", paste(unmatched_log[[ly]], collapse = ", "), "\n")
    }
  }

  if (length(results) == 0) {
    message("  Nothing extracted for ", year, " - check source data.")
    return(invisible(NULL))
  }

  combined <- bind_rows(results) %>%
    mutate(top_level = top_level(category), source_year = year)

  out_path <- file.path(out_dir, paste0("N50_extracted_", year, ".gpkg"))
  if (file.exists(out_path)) file.remove(out_path)
  for (tl in unique(combined$top_level)) {
    for (gt in unique(combined$geom_type[combined$top_level == tl])) {
      sub <- combined %>% filter(top_level == tl, geom_type == gt) %>% select(-top_level, -geom_type)
      if (nrow(sub) == 0) next
      st_write(sub, out_path, layer = paste0(tl, "_", gt), quiet = TRUE, append = FALSE)
    }
  }

  cat("\n  Total extracted:", nrow(combined), "features ->", out_path, "\n")
  cat("  By category:\n")
  print(table(combined$category))
  invisible(combined)
}

all_results <- list()
for (yr in names(year_defs)) {
  all_results[[yr]] <- extract_year(yr, year_defs[[yr]])
}

# ---------------------------------------------------------------
# NVE regulated lakes - single source, not year-specific, extracted once
# into its own file. ALI's "regulated lakes" component.
# ---------------------------------------------------------------
cat("\n========== NVE regulated lakes (ALI) ==========\n")
nve_dsn <- list.dirs(file.path(source_dir, "NVE_regulated_lakes"), recursive = TRUE)
nve_dsn <- nve_dsn[grepl("\\.gdb$", nve_dsn)][1]
if (is.na(nve_dsn)) {
  message("NVE gdb not found - skipping.")
} else {
  nve_layers <- st_layers(nve_dsn)$name
  reg_layer <- nve_layers[grepl("regulert", nve_layers, ignore.case = TRUE)]
  cat("Candidate regulated-lake layer(s):", paste(reg_layer, collapse = ", "), "\n")
  if (length(reg_layer) > 0) {
    x <- st_read(nve_dsn, layer = reg_layer[1], quiet = TRUE)
    if (is.na(st_crs(x)$epsg) || st_crs(x)$epsg != 25833) x <- st_transform(x, 25833)
    x <- x %>%
      mutate(category = "ALI_RegulatedLakes", source_year = "current", geom_type = geom_type_of(.))
    out_path <- file.path(out_dir, "NVE_extracted_regulated_lakes.gpkg")
    st_write(x, out_path, quiet = TRUE, append = FALSE)
    cat("Extracted", nrow(x), "regulated-lake features ->", out_path, "\n")
  }
}

cat("\n\n================================================\n")
cat("EXTRACTION COMPLETE. Output in:", normalizePath(out_dir), "\n")
cat("NOT extracted (see script header for why):\n")
cat("  - LCI 'other built-up areas' - no confirmed N50 object type, ambiguous at the source.\n")
cat("================================================\n")
