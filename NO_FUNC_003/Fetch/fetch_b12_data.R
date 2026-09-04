# ============================================================
# One-time utility: fetch the "Planter og lav på myr" (Plants and lichens
# on mire) generalized species-list dataset from Artsdatabanken's public
# download service and cache it locally. Confirmed public, no auth
# required - a manual GUI download link is available from the same page.
#
# Source: https://artsdatabanken.no/Pages/281569/Generaliserte_artslistedatasett_til_artikkel_2
#   (dataset "B12", one of 13 files in the "Generaliserte artslistedatasett
#   til artikkel 2" collection - the public source behind NINA's own
#   internal Eco_State.RData compilation used to build
#   wet_mount_forest_seminat.ref.cov - see build_wet_ref_openS.R)
#   Direct URL (used below):
#     https://artsdatabanken.no/Files/29643/Datasett_B12__Planter_og_lav_p__myr
#   File is served as a .xlsx despite having no extension in the URL -
#   confirmed via magic-byte inspection (PK\x03\x04 = zip/xlsx signature).
#
# Covers NiN wetland main types V1 (Åpen jordvannsmyr), V2 (Jordvannsmyr-
# skogsmark), V3 (Regnvannsmyr) - together 96.98% of real ANO wetland
# monitoring points nationally. Does NOT cover V4 (Kilde) or V8
# (Strandsumpskogsmark) - see build_wet_ref_openS.R's header for how
# those are handled (patched from NINA's cache, together under 1% of
# real field usage - see project_indicator_issues_list memory).
# ============================================================

library(readxl)

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

b12_url <- "https://artsdatabanken.no/Files/29643/Datasett_B12__Planter_og_lav_p__myr"

out_dir     <- file.path("..", "Data", "OpenS_data")
xlsx_path   <- file.path(out_dir, "B12_planter_og_lav_pa_myr.xlsx")
force_fetch <- FALSE

if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

if (file.exists(xlsx_path) && !force_fetch) {
  cat("Already present:", normalizePath(xlsx_path), "\n")
  cat("Set force_fetch <- TRUE above to re-download anyway.\n")
} else {
  cat("Downloading B12 (Planter og lav på myr)...\n")
  t0 <- Sys.time()
  download.file(b12_url, destfile = xlsx_path, mode = "wb")
  cat("  download took", round(as.numeric(Sys.time() - t0), 1), "sec\n")
}

cat("\nVerifying sheets...\n")
print(excel_sheets(xlsx_path))
cat("\nSaved:", normalizePath(xlsx_path), "\n")
