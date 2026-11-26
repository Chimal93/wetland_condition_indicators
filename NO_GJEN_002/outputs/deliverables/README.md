# Superseded: NO_GJEN_002 version 000.003 (NiN polygons, CHMv1)

The files in this folder are the earlier version of NO_GJEN_002. It used the
canopy-height model CHMv1 (Meta HighResCanopyHeight) on the mapped NiN
wetland polygons. They are kept for reference only.

**The current deliverables are in [`../deliverables_20m_cells/`](../deliverables_20m_cells/)**
(version 000.004 and later). That version uses CHMv2, calibrated to LiDAR,
on every 20 m cell of AR5 mire, with the same cells, height measure,
references and scaling as NO_GJEN_001.

Why this version was replaced:
- **Population:** NiN mapping covers only part of the wetland and is not
  area-representative.
- **Model:** CHMv1 runs only on a CPU, about two weeks nationally, and
  cannot be calibrated to LiDAR with a simple correction.

See [`../../README.md`](../../README.md).
