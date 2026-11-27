"""The two results VAAT-GJEN-02 takes from the comparison, from $OUT/paired.csv:

1. The calibration of CHMv2 (0.6 m input variant, as national_chm.py) to LiDAR
   on the 20 m cell median, VAAT-GJEN-01's statistic:
       lidar = a + b * chmv2      (ordinary least squares, all usable points)
   printed for all points and per region, and written to
   $OUT/calibration_chmv2_median_fit.json. The coefficients are copied by hand
   into ../chm_national/calibration_chmv2_median.json. Its leave-one-region-out
   error is in $OUT/calibration_validation.csv (04_compare.py: chmv2_06,
   median, leave-one-region-out).
2. The validation cells for the uncertainty of VAAT-GJEN-02: the LiDAR cell
   median at every usable sample cell, written to
   $OUT/validation_cells_lidar_20m_median.csv. Copy it to NATIONAL_CHM_OUT_DIR,
   where run_VAAT-GJEN-02_cell_indicator.sh expects it. It derives from AR5
   (the sample is drawn in AR5 mire), so it is not committed.
"""
import json, os
import numpy as np, pandas as pd

OUT = os.environ.get("OUT", "out")
d = pd.read_csv(f"{OUT}/paired.csv", low_memory=False)

v = d[d.usable & d.lidar_cell_median.notna()]
v[["cell_x", "cell_y", "region", "vegClimZoneLab", "lidar_cell_median", "lidar_year", "lidar_project"]].to_csv(
    f"{OUT}/validation_cells_lidar_20m_median.csv", index=False)
print(f"validation cells: {len(v)} -> {OUT}/validation_cells_lidar_20m_median.csv")

c = d[d.usable & d.chmv2_06_median.notna()]
b, a = np.polyfit(c.chmv2_06_median, c.lidar_cell_median, 1)
print(f"calibration, all points: a={a:.6f} b={b:.6f} n={len(c)}")
per_region = {}
for r, g in c.groupby("region"):
    bb, aa = np.polyfit(g.chmv2_06_median, g.lidar_cell_median, 1)
    per_region[r] = {"a": round(aa, 6), "b": round(bb, 6), "n": len(g)}
    print(f"  {r}: a={aa:.3f} b={bb:.3f}")
json.dump({"a": round(a, 6), "b": round(b, 6), "n": len(c), "per_region": per_region},
          open(f"{OUT}/calibration_chmv2_median_fit.json", "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print(f"wrote {OUT}/calibration_chmv2_median_fit.json")
