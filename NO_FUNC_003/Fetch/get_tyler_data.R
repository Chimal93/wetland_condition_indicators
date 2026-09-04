# ============================================================
# Tyler et al. (2021) plant functional trait indicator values.
#
# THIS SCRIPT DOES NOT DOWNLOAD ANYTHING - it cannot. It checks whether
# the file is present and, if not, prints exactly how to obtain it.
#
# Two reasons there is no automated fetch:
#   1. ScienceDirect, ResearchGate and DOAJ all block scripted requests
#      for supplementary files, so any download would break immediately.
#   2. The file is the publisher's supplementary material. It is not
#      redistributed in this repository - please obtain it from the
#      source and cite the paper.
#
# CITATION
#   Tyler, T., Herbertsson, L., Olofsson, J., Olsson, P.A. (2021).
#   Ecological indicator and traits values for Swedish vascular plants.
#   Ecological Indicators, 120, 106923.
#   https://doi.org/10.1016/j.ecolind.2020.106923
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

target_dir  <- file.path("..", "Data", "OpenS_data")
target_file <- file.path(target_dir, "Tyler_data_raw.xlsx")

instructions <- paste0(
  "\n",
  "  Tyler et al. (2021) indicator values are required but not present.\n\n",
  "  1. Open the article:\n",
  "       https://doi.org/10.1016/j.ecolind.2020.106923\n\n",
  "  2. Under 'Supplementary material' / 'Appendix A', download the\n",
  "     supplementary spreadsheet containing the \"Taxa\" sheet.\n\n",
  "  3. Save it, unchanged and still .xlsx, as:\n",
  "       ", normalizePath(target_dir, winslash = "/", mustWork = FALSE), "/Tyler_data_raw.xlsx\n\n",
  "  The pipeline reads the \"Taxa\" sheet and uses four columns:\n",
  "  Light, Moisture, Soil_reaction_pH, Nitrogen. Grime (1974) CSR\n",
  "  values in the same workbook are not used - a different plant\n",
  "  strategy axis with no overlap with these indicators.\n\n",
  "  Not automated because ScienceDirect blocks scripted downloads, and\n",
  "  because the file is the publisher's supplementary material rather\n",
  "  than ours to redistribute. Please cite the paper if you use it.\n")

if (file.exists(target_file)) {
  sz <- file.size(target_file)
  cat("Tyler data present:", target_file, sprintf("(%.1f MB)\n", sz / 1e6))
  ok <- requireNamespace("readxl", quietly = TRUE)
  if (ok) {
    sheets <- tryCatch(readxl::excel_sheets(target_file), error = function(e) NULL)
    if (is.null(sheets)) {
      cat("  WARNING: file exists but could not be read as .xlsx - re-download it.\n")
    } else if (!"Taxa" %in% sheets) {
      cat("  WARNING: no \"Taxa\" sheet found. Sheets present:",
          paste(sheets, collapse = ", "), "\n")
      cat("  The pipeline needs the \"Taxa\" sheet - check you saved the right file.\n")
    } else {
      cat("  \"Taxa\" sheet found - ready to use.\n")
    }
  } else {
    cat("  (install readxl to verify the \"Taxa\" sheet is present)\n")
  }
} else {
  dir.create(target_dir, recursive = TRUE, showWarnings = FALSE)
  cat(instructions)
  stop("Tyler_data_raw.xlsx not found - see the instructions above.", call. = FALSE)
}
