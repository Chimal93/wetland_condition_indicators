#!/usr/bin/env bash
# NO_GJEN_002 from orthophoto to deliverables and indicator document, in one go.
#
#   1. national CHMv2 canopy-height map over AR5 mire (GPU; chunks that are
#      already finished are skipped, so a finished map takes a minute)
#   2. indicator on the 20 m grid, uncertainty and flight years (CPU, ~30 min)
#   3. copy the result tables into the repository:
#      NO_GJEN_002/data/OpenS_data/orthophoto_chmv2_20m_cells/
#   4. deliverables: NO_GJEN_002/outputs/deliverables_20m_cells/
#   5. indicator document: NO_GJEN_002/docs/NO_GJEN_002.html
#
# Usage (inside screen):  bash docker/run_NO_GJEN_002_deliverables.sh
# Stops at the first step that fails. Settings: as the two runners it calls
# (NATIONAL_CHM_OUT_DIR, ORTHOPHOTO_SOURCE_PATH, ... in docker/config.local.env).
. "$(dirname "$0")/internal/common.sh"

CELLS=${NATIONAL_CHM_OUT_DIR:?Set NATIONAL_CHM_OUT_DIR in docker/config.local.env}/cell_indicator_chmv2
TABLES=$REPO_DIR/NO_GJEN_002/data/OpenS_data/orthophoto_chmv2_20m_cells
LOG=$NATIONAL_CHM_OUT_DIR/deliverables_NO_GJEN_002_$(date +%Y%m%d_%H%M%S).log
say() { echo "$(date '+%F %T')  $*" | tee -a "$LOG"; }
say "log: $LOG"

say "1/5 national canopy-height map (CHMv2)"
bash "$DOCKER_DIR/run_NO_GJEN_002_national_chm.sh" chmv2

say "2/5 indicator on the 20 m grid"
bash "$DOCKER_DIR/run_NO_GJEN_002_cell_indicator.sh"

say "3/5 copy the tables into $TABLES"
mkdir -p "$TABLES"
rm -f "$TABLES"/*.csv "$TABLES"/provenance.json
cp "$CELLS"/*.csv "$CELLS"/provenance.json "$TABLES"/
ls -l "$TABLES" | tee -a "$LOG"

say "4/5 deliverables"
bash "$DOCKER_DIR/run_script.sh" NO_GJEN_002/R/export_deliverables_20m_cells.R 2>&1 | tee -a "$LOG"

say "5/5 indicator document"
run_in_container "$RUNS_DIR/single_scripts" --rm -w /work/NO_GJEN_002/docs -- \
  quarto render NO_GJEN_002.qmd 2>&1 | tail -5 | tee -a "$LOG"

say "done. Deliverables: NO_GJEN_002/outputs/deliverables_20m_cells/  Document: NO_GJEN_002/docs/NO_GJEN_002.html"
