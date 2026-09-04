# ============================================================
# Build the open-data reconstruction of NO_FUNC_003's bootstrapped CWM
# reference table (reimplements NINA's indBoot.freq() bootstrap on a
# public species-list source instead of NINA's internal compilation).
#
# COVERAGE: reconstructs NiN main types V1 (Åpen jordvannsmyr), V2
# (Jordvannsmyr-skogsmark), V3 (Regnvannsmyr) - together 96.98% of real
# ANO wetland monitoring points nationally (2,990 of 3,083). V4 and V8
# (0.88% combined, 27 points) are NOT reconstructed and are excluded
# from scoring downstream, rather than patched from a gated source.
# Confirmed empirically (2026-08-21) that this costs under 0.003 on the
# final 0-1 index - not material at today's data availability.
#
# NOT PERMANENTLY CLOSED - worth rechecking if new data appears:
#   - V8 (Strandsumpskogsmark, 3 points): no public generalized species
#     list found anywhere as of 2026-08, checked exhaustively against
#     Artsdatabanken's full "Generaliserte artslistedatasett" collection.
#   - V4 (Kilde, 24 points): B04 ("Planter i kilder") is a candidate
#     public source but was not used here - its internal structure was
#     judged too fragile to untangle for this little coverage, not
#     confirmed impossible. Worth a second look if this gap ever matters
#     more (e.g. a future dataset skews more toward V4 plots).
# If either source is ever published/reworked, extend Stage 5/6 below
# the same way V1/V2/V3 already work (add the hovedtype to `hovedtypes`
# and make sure its list-columns are tagged correctly in Stage 1).
#
# GRANULARITY: one row per HOVEDTYPE (V1/V2/V3), pooling a type's finer
# subtype variation together - coarser than NINA's original per-subtype
# columns, validated directly against NINA's own cached values (pooled
# the same way) and matched within ~7-15% for all 12 combinations.
#
# Source: Artsdatabanken "Generaliserte artslistedatasett til artikkel 2"
# (public, no login), dataset B12 ("Planter og lav på myr"), fetched by
# fetch_b12_data.R. Its own Metadata sheet documents the species-list ->
# NiN-code crosswalk directly.
#
# Method: reimplementation of indBoot.freq() - per NiN list, 1000
# bootstrap iterations each keeping all "obligate" species (cover >= obl)
# plus a random rat-fraction subsample of the rest, jittering each
# species' cover-class value to a nearby class, then computing the
# abundance-weighted mean (CWM) per indicator. Only Tyler's four wetland
# indicators (Light, Moisture, Soil_reaction_pH, Nitrogen) are computed -
# Grime's CC/SS/RR are a separate plant-strategy axis, unused here.
#
# Output: ../Data/OpenS_data/wet_ref_openS.csv
#   Columns: hovedtype (V1/V2/V3), indicator, q25, median, q75,
#   n_pooled_draws, n_lists.
# ============================================================

library(readxl)
library(dplyr)
library(stringr)

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

data_dir   <- file.path("..", "Data", "OpenS_data")
b12_path   <- file.path(data_dir, "B12_planter_og_lav_pa_myr.xlsx")
tyler_path <- file.path(data_dir, "Tyler_data_raw.xlsx")
out_path   <- file.path(data_dir, "wet_ref_openS.csv")

if (!file.exists(b12_path)) {
  stop("Missing required file: ", b12_path, "\nRun fetch_b12_data.R first to produce it.")
}
if (!file.exists(tyler_path)) {
  stop("Missing required file: ", tyler_path, "\n",
       "No automated fetch is possible - manually download the 'Taxa' ",
       "data sheet from https://www.sciencedirect.com/science/article/pii/S1470160X20308621 ",
       "and place the raw .xlsx there (see NO_FUNC_003_wetland_pipeline_OpenSource.R's header).")
}

coverscale <- data.frame(orig = 0:6, cov = c(0, 1/32, 1/8, 3/8, 0.6, 4/5, 1))


# ===========================================================
# STAGE 1: Parse B12's Definisjon section -> hovedtype crosswalk.
# The section has 57 sequentially-numbered list entries ("01"-"57") that
# correspond 1:1 and in-order to DataTransp's 57 rows, PLUS 6 extra
# unlabeled rows (all "svært kalkrik" continuations of the myrkant/
# myrskogsmark/kildemyr series that were documented as theoretically-
# recognized but never compiled into their own species list - no
# DataTransp row exists for them). Fix: keep only non-NA sequential
# labels, sort numerically - gives a clean 57-row crosswalk.
# ===========================================================

cat("Parsing B12 Metadata (Definisjon crosswalk)...\n")
meta <- as.data.frame(read_excel(b12_path, sheet = "Metadata"))
def_start <- which(meta$Deltema == "Definisjon, f.eks. karakteristisk trinnkombinasjon, for naturtyper (som det er lagd artslister for)")
boundary  <- which(meta$Opplysninger == "6 trinn")
boundary  <- boundary[boundary > def_start][1]

window <- meta[def_start:(boundary - 1), c("Del-deltema", "Opplysninger")]
names(window) <- c("label", "desc")
def_rows <- window[!is.na(window$label), ]
def_rows$label_num <- as.integer(def_rows$label)
def_rows <- def_rows[order(def_rows$label_num), ]
stopifnot(identical(def_rows$label_num, 1:57))

# Hovedtype tagging from the Norwegian description text: "ombrogen" =
# rain-fed bog (V3); "myrskogsmark"/"kildemyrskogsmark"/"...strandmyrskog"
# = swamp-forest family (V2); everything else (myrflate/myrkant/kildemyr)
# = V1. The 3 "...strandmyrskog" entries are a possible-but-unconfirmed
# V8 lead (salinity-extreme edge of the V2 family) - kept as V2 pending
# further evidence; see memory for the investigation.
tag_hovedtype <- function(desc) {
  d <- tolower(desc)
  if (grepl("ombrogen", d)) return("V3")
  if (grepl("myrskogsmark|kildemyrskogsmark|strandmyrskog", d)) return("V2")
  return("V1")
}
def_rows$hovedtype <- vapply(def_rows$desc, tag_hovedtype, character(1))
cat("  Hovedtype tally: ", paste(names(table(def_rows$hovedtype)), table(def_rows$hovedtype), sep = "=", collapse = ", "), "\n")


# ===========================================================
# STAGE 2: Build the species x list abundance matrix (raw 0-6 codes),
# tag each list-column with its hovedtype, apply coverscale (0-6 -> %cover).
# ===========================================================

cat("Building species x list abundance matrix...\n")
dt <- as.data.frame(read_excel(b12_path, sheet = "DataTransp"))
stopifnot(nrow(dt) == nrow(def_rows))

list_id <- paste0(def_rows$hovedtype, "_L", sprintf("%02d", def_rows$label_num))
species_cols <- names(dt)

dt_cov <- dt
for (col in species_cols) {
  dt_cov[[col]] <- coverscale$cov[match(dt[[col]], coverscale$orig)]
}

mat <- t(as.matrix(dt_cov[, species_cols]))
colnames(mat) <- list_id
sp_abund <- as.data.frame(mat)
sp_abund$sp_code <- rownames(sp_abund)
rownames(sp_abund) <- NULL

# Species-code -> scientific-name lookup from the Artslister sheet.
al <- as.data.frame(read_excel(b12_path, sheet = "Artslister"))
al <- al[-1, ]
names(al) <- as.character(unlist(al[1, ]))
al <- al[-1, c("Art", "Artskode")]
names(al) <- c("scientific_name", "sp_code")
al <- al[!is.na(al$sp_code) & !is.na(al$scientific_name), ]

sp_abund <- merge(sp_abund, al, by = "sp_code", all.x = TRUE)
cat("  Species matched to a scientific name:", sum(!is.na(sp_abund$scientific_name)), "/", nrow(sp_abund), "\n")


# ===========================================================
# STAGE 3: Merge with Tyler's indicator values via binomial name matching
# (same trimming approach Stage 3 of the main pipeline uses for ANO-Tyler
# reconciliation). Only vascular plants get a match - B12 also includes
# mosses/lichens ("Planter OG LAV"), which Tyler's dataset doesn't cover
# at all; this is expected (matches NINA's own indBoot.freq(), which
# drops species without a valid indicator value the same way), not a bug.
# ===========================================================

cat("Merging with Tyler indicator values...\n")
sp_abund$species_binomial <- word(sp_abund$scientific_name, 1, 2)

ind.Tyler <- read_excel(tyler_path, sheet = "Taxa") |>
  rename(Soil_reaction_pH = `Soil reaction (pH)`, Nitrogen = `Nitrogen (N)`) |>
  as.data.frame()
names(ind.Tyler)[1] <- "species"
ind.Tyler$species <- word(ind.Tyler$species, 1, 2)
ind.Tyler <- ind.Tyler[!duplicated(ind.Tyler$species), c("species","Light","Moisture","Soil_reaction_pH","Nitrogen")]

merged <- merge(sp_abund, ind.Tyler, by.x = "species_binomial", by.y = "species", all.x = TRUE)
cat("  Species with a Tyler indicator value:", sum(!is.na(merged$Light)), "/", nrow(merged), "\n")


# ===========================================================
# STAGE 4: indBoot.freq() - faithful reimplementation (qmd lines
# 1226-1282), unchanged logic. Per list-column: 1000 bootstrap iterations
# of the abundance-weighted mean (CWM) per indicator.
# ===========================================================

indBoot.freq <- function(sp, abun, ind, iter, obl, rat = 2/3, var.abun = FALSE) {
  ind.b <- matrix(nrow = iter, ncol = length(colnames(abun)))
  colnames(ind.b) <- colnames(abun)
  ind.b <- as.data.frame(ind.b)

  ind <- as.data.frame(ind)
  ind.list <- as.list(1:length(colnames(ind)))
  names(ind.list) <- colnames(ind)
  for (k in 1:length(colnames(ind))) ind.list[[k]] <- ind.b

  for (j in 1:length(colnames(abun))) {
    dat <- cbind(sp, abun[, j], ind)
    dat <- dat[dat[, 2] > 0, ]
    dat <- dat[!is.na(dat[, 2]), ]
    dat <- dat[!is.na(dat[, 3]), ]

    for (i in 1:iter) {
      non_obl <- dat$sp[dat[, 2] < obl]
      n_take  <- round((length(dat$sp) - length(dat$sp[dat[, 2] >= obl])) * rat, 0)
      speciesSample <- sample(non_obl, size = n_take, replace = FALSE)
      dat.b <- rbind(dat[dat[, 2] >= obl, ], dat[match(speciesSample, dat$sp), ])

      if (var.abun) {
        for (m in 1:nrow(coverscale[-1, ])) {
          xxx <- dat.b[dat.b[, 2] == coverscale[-1, ][m, 2], 2]
          probs <- switch(m,
            c(0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0),
            c(0.2, 0.3, 0.5, 0.0, 0.0, 0.0, 0.0),
            c(0.0, 0.2, 0.3, 0.5, 0.0, 0.0, 0.0),
            c(0.0, 0.0, 0.2, 0.3, 0.5, 0.0, 0.0),
            c(0.0, 0.0, 0.0, 0.2, 0.3, 0.5, 0.0),
            c(0.0, 0.0, 0.0, 0.0, 0.2, 0.3, 0.5)
          )
          if (length(xxx) > 0) {
            dat.b[dat.b[, 2] == coverscale[-1, ][m, 2], 2] <-
              sample(c(0.01, coverscale[2:7, 2]), prob = probs, size = length(xxx), replace = TRUE)
          }
        }
        dat.b[!is.na(dat.b[, 2]) & dat.b[, 2] <= 0, 2] <- 0.01
        dat.b[!is.na(dat.b[, 2]) & dat.b[, 2] > 1, 2]  <- 1
      }

      for (k in 1:length(colnames(ind))) {
        if (nrow(dat.b) > 2) {
          val <- sum(dat.b[!is.na(dat.b[, 2 + k]), 2] * dat.b[!is.na(dat.b[, 2 + k]), 2 + k], na.rm = TRUE) /
                 sum(dat.b[!is.na(dat.b[, 2 + k]), 2], na.rm = TRUE)
          ind.list[[k]][i, j] <- val
        } else {
          ind.list[[k]][i, j] <- NA
        }
      }
    }
  }
  return(ind.list)
}

list_cols <- setdiff(names(merged), c("sp_code","scientific_name","species_binomial","Light","Moisture","Soil_reaction_pH","Nitrogen"))
cat("Running bootstrap (1000 iterations x", length(list_cols), "lists x 4 indicators)...\n")
t0 <- Sys.time()
set.seed(123)
boot_result <- indBoot.freq(
  sp = merged$sp_code, abun = merged[, list_cols],
  ind = merged[, c("Light","Moisture","Soil_reaction_pH","Nitrogen")],
  iter = 1000, obl = 0.8, rat = 1/2, var.abun = TRUE
)
cat("  took", round(as.numeric(Sys.time() - t0, units = "secs"), 1), "sec\n")


# ===========================================================
# STAGE 5: Pool each hovedtype's lists' 1000-iteration draws together,
# compute reference quantiles (0.25/0.5/0.75) - the deliberate coarsening
# vs. NINA's fine per-subtype columns (see header).
# ===========================================================

indicators <- c("Light","Moisture","Soil_reaction_pH","Nitrogen")
hovedtypes <- c("V1","V2","V3")

our_ref <- data.frame()
for (ind in indicators) {
  df <- boot_result[[ind]]
  for (ht in hovedtypes) {
    ht_lists <- intersect(paste0(ht, "_L", sprintf("%02d", def_rows$label_num[def_rows$hovedtype == ht])), names(df))
    pooled <- unlist(df[, ht_lists], use.names = FALSE)
    pooled <- pooled[!is.na(pooled)]
    q <- quantile(pooled, c(0.25, 0.5, 0.75), na.rm = TRUE)
    our_ref <- rbind(our_ref, data.frame(
      hovedtype = ht, indicator = ind, q25 = q[1], median = q[2], q75 = q[3],
      n_pooled_draws = length(pooled), n_lists = length(ht_lists)
    ))
  }
}

# V4 and V8 are not reconstructed here (see header) - plots of those
# types are excluded from scoring downstream, not patched from a gated
# source. Confirmed (2026-08-21) this costs 27 of 3,083 wetland plots
# nationally and shifts the final index by under 0.003, well inside its
# own bootstrap confidence interval.
final_ref <- our_ref[order(our_ref$indicator, our_ref$hovedtype), ]
rownames(final_ref) <- NULL

cat("\n=== Final reference table ===\n")
print(final_ref)

write.csv(final_ref, out_path, row.names = FALSE)
cat("\nSaved:", out_path, "\n")
