# ============================================================
# NO_GJEN_001 - report map in the same style as NO_FUNC_003's regional
# map (5-class "økologisk tilstand" scale, labelled regions, n per region),
# so the two indicators look alike side by side in a report.
#
# Reads the delivered regional values (Deliverables/NO_GJEN_001_values.csv,
# written by export_deliverables.R) - run that first. No computation here.
# Output: Results/NO_GJEN_001_wetland_map_report.png
# ============================================================

suppressPackageStartupMessages({ library(sf); library(dplyr); library(ggplot2); library(readr) })

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  cmd_args <- commandArgs(trailingOnly = FALSE); fm <- grep("^--file=", cmd_args)
  if (length(fm)) setwd(dirname(normalizePath(sub("^--file=", "", cmd_args[fm]))))
}

spatial_dir <- file.path("..", "Data", "OpenS_data")
out_dir     <- file.path("..", "Results")

vals <- read_csv(file.path("..", "Deliverables", "NO_GJEN_001_values.csv"), show_col_types = FALSE) %>%
  filter(areaId != 0) %>%
  select(areaId, index = i_2024, n)

# regions.shp's `region` text has an encoding fault for Østlandet/Sørlandet,
# so join on `id` (1 Nord, 2 Midt, 3 Øst, 4 Vest, 5 Sør - the same ids
# export_deliverables.R uses as areaId). Labels in English, as on the
# NO_FUNC_003 map.
region_labels <- c("1" = "Northern", "2" = "Central", "3" = "Eastern", "4" = "Western", "5" = "Southern")

nor <- st_read(file.path(spatial_dir, "outlineOfNorway_EPSG25833.shp"), quiet = TRUE)
reg <- st_read(file.path(spatial_dir, "regions.shp"), quiet = TRUE) %>%
  st_transform(st_crs(nor)) %>%
  transmute(areaId = as.integer(id), region = unname(region_labels[as.character(id)]))
sf::st_agr(reg) <- "constant"; sf::st_agr(nor) <- "constant"
regnor <- st_intersection(reg, nor)

# Same condition classes and colours as NO_FUNC_003 (God starts at 0.6).
condition_breaks <- c(0, 0.2, 0.4, 0.6, 0.8, 1)
condition_labels <- c("Svært dårlig", "Dårlig", "Moderat", "God", "Svært god")
condition_colors <- setNames(c("#d7191c", "#fdae61", "#ffffbf", "#a6d96a", "#1a9641"), condition_labels)

regnor_map <- regnor %>%
  left_join(vals, by = "areaId") %>%
  mutate(condition = cut(index, breaks = condition_breaks, labels = condition_labels, include.lowest = TRUE))

label_pts <- regnor_map %>%
  group_by(region, index, n) %>% summarise(.groups = "drop") %>%
  st_point_on_surface() %>%
  mutate(label = sprintf("%s\n%.3f (n=%d)", region, index, n))

# Invisible points carry the legend so all five classes always show
# (same approach as NO_FUNC_003).
dummy_xy <- st_coordinates(st_point_on_surface(regnor_map[1, ]))
legend_dummy <- data.frame(condition = factor(condition_labels, levels = condition_labels),
                           x = dummy_xy[1, "X"], y = dummy_xy[1, "Y"])

wetland_map <- ggplot() +
  geom_sf(data = regnor_map, aes(fill = condition), color = "black", linewidth = 0.4, show.legend = FALSE) +
  geom_point(data = legend_dummy, aes(x = x, y = y, fill = condition),
             shape = 22, size = 6, color = "black", alpha = 0) +
  geom_sf_label(data = label_pts, aes(label = label), size = 3, lineheight = 0.9,
                fill = "white", color = "black", label.size = 0.3) +
  scale_fill_manual(values = condition_colors, name = "Tilstand", limits = condition_labels,
                    drop = FALSE, na.value = "grey80",
                    guide = guide_legend(override.aes = list(alpha = 1))) +
  labs(title    = "NO_GJEN_001 indikator Våtmark",
       subtitle = "Gjengroing, LiDAR 2010-2024",
       caption  = "Arealvektet gjennomsnittlig skalert gjengroingsindeks per region. God tilstand ≥ 0.6.") +
  theme_void() +
  theme(plot.title      = element_text(face = "bold", size = 16, hjust = 0.5),
        plot.subtitle   = element_text(size = 11, hjust = 0.5),
        plot.caption    = element_text(size = 8, hjust = 0.5),
        legend.position = "right")

dir.create(out_dir, showWarnings = FALSE)
out <- file.path(out_dir, "NO_GJEN_001_wetland_map_report.png")
ggsave(out, wetland_map, width = 11, height = 10, dpi = 300, bg = "white")
cat("Saved", out, "\n")
