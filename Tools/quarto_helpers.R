# ============================================================
# Shared helpers for the Quarto indicator documents (docs/<ID>.qmd).
# Sourced from docs/, so script paths are relative to that folder.
# ============================================================

num <- function(x, d = 2) formatC(x, format = "f", digits = d)
cnt <- function(x) format(x, big.mark = ",", trim = TRUE)
pct <- function(x, d = 0) paste0(formatC(100 * x, format = "f", digits = d), "%")

# Whole script from R/, as lines.
script <- function(file) readLines(file.path("..", "R", file), encoding = "UTF-8", warn = FALSE)

# One or more stages of a script in R/ ("# STAGE n" headers). The code shown
# in the document is therefore always the code in the repository.
stage <- function(file, ...) {
  x  <- script(file)
  h  <- grep("^# STAGE ", x)
  id <- sub("^# STAGE ([0-9a-z]+).*", "\\1", x[h])
  from <- h - 1                       # the "# ====" line above each header
  to   <- c(from[-1] - 1, length(x))
  k <- match(c(...), id); stopifnot(!anyNA(k))
  unlist(Map(function(a, b) x[a:b], from[k], to[k]))
}

# Metadata table from the document's own YAML header.
metadata_table <- function(qmd) {
  y <- rmarkdown::yaml_front_matter(qmd)
  keep <- c(indicatorID = "Indicator ID", indicatorName = "Indicator name",
            verbatimName = "Norwegian name", continent = "Continent", country = "Country",
            ECT = "Ecosystem Condition Typology class", Realm = "Realm", Biome = "Biome",
            Ecosystem = "Ecosystem", verbatimEcosystem = "Norwegian ecosystem",
            yearAdded = "Year added", yearLastUpdate = "Last update", status = "Status",
            Version = "Version", VersionComment = "Version comment", Normalised = "Normalised",
            SpatialAggregationPathway = "Spatial aggregation pathway", Precision = "Precision")
  value <- vapply(names(keep), function(n) {
    v <- unlist(y[[n]])
    if (is.logical(v)) v <- ifelse(v, "Yes", "No")
    paste(v, collapse = "; ")
  }, "")
  knitr::kable(data.frame(Variable = unname(keep), Value = unname(value)))
}

# Region map of the indicator value from a delivered region .rds.
region_map <- function(rds, col, limits = c(0.6, 1)) {
  m <- sf::st_simplify(readRDS(rds), dTolerance = 1000)
  sf::st_agr(m) <- "constant"
  m$value <- m[[col]]
  ggplot2::ggplot(m) +
    ggplot2::geom_sf(ggplot2::aes(fill = value), colour = "white", linewidth = 0.3) +
    ggplot2::geom_sf_label(ggplot2::aes(label = paste0(area, "\n", num(value))), fill = "white", size = 2.8) +
    ggplot2::scale_fill_viridis_c(limits = limits, name = "Indicator\nvalue") +
    ggplot2::theme_void() +
    ggplot2::theme(plot.margin = ggplot2::margin(2, 12, 2, 2))
}
