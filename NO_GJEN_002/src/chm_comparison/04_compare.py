"""Compare model predictions with LiDAR on the 20 m cells, and test a linear
calibration (LiDAR = a + b * model) for how well it transfers.

Cell statistics: model cell MEAN vs LiDAR cell mean (clamped 1 m CHM), and
model cell MEDIAN vs LiDAR cell median (NO_GJEN_001's statistic).
Calibration is checked four ways (on the cell mean):
  random 5-fold        - fitted and tested on random halves of the same data
  leave-one-region-out - fitted without a region, tested on it
  leave-one-photo-year-out - fitted without one photo year, tested on it:
                         would a calibration carry over to other imagery?
  coefficients per region / photo year - how much a and b move.
Writes to $OUT: paired.csv, metrics.csv, calibration_validation.csv,
calibration_coefficients.csv, residuals_by_factor.csv, summary.txt,
scatter.png, examples_by_class_1.png, examples_by_class_2.png,
examples_worst.png.
"""
import glob, io, os, sys
import numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt

OUT = os.environ.get("OUT", "out")
log = io.StringIO()
def say(*a):
    print(*a); print(*a, file=log)
pd.set_option("display.width", 220); pd.set_option("display.max_rows", 500); pd.set_option("display.max_columns", 30)

# ---- load ----------------------------------------------------------------------
p = pd.read_csv(f"{OUT}/points.csv", low_memory=False)
n = len(p)
def load(tag):
    files = sorted(glob.glob(f"{OUT}/pred_{tag}_[0-9][0-9].npz")) if tag == "chmv1_cpu" else [f"{OUT}/pred_{tag}.npz"]
    files = [f for f in files if os.path.exists(f)]
    if not files: return None
    mean, median = np.full(n, np.nan), np.full(n, np.nan); maps = {}
    for f in files:
        z = np.load(f)
        mean[z["idx"]], median[z["idx"]] = z["mean"], z["median"]
        maps.update(dict(zip(z["ex_idx"].tolist(), z["ex_maps"])))
    return mean, median, maps
MODELS = ["chmv1_cpu", "chmv1_gpu", "chmv1_gpu_06", "chmv2_05", "chmv2_06"]
maps = {}
for m in MODELS:
    r = load(m)
    if r is None: say(f"(no predictions for {m})"); continue
    p[f"{m}_mean"], p[f"{m}_median"], maps[m] = r
MODELS = [m for m in MODELS if m in maps]
p["lidar_class"] = pd.Categorical(p.lidar_class, ["<0.5 m", "0.5-2 m", "2-5 m", ">5 m"], ordered=True)
p["photo_year"] = pd.to_datetime(p.photo_start, errors="coerce").dt.year
p["photo_month"] = pd.to_datetime(p.photo_start, errors="coerce").dt.month
p["gap_years"] = p.photo_year - p.lidar_year
p["gap_class"] = pd.cut(p.gap_years, [-50, -3, -1, 0, 2, 4, 50], labels=["LiDAR >=3 y newer", "LiDAR 1-2 y newer", "same year", "photo 1-2 y newer", "photo 3-4 y newer", "photo >=5 y newer"])
p["density_class"] = pd.cut(p.lidar_density_pts_m2, [0, 2, 5, 10, 1000], labels=["<=2 pts/m2", "2-5", "5-10", ">10"])
q = p[p.usable & p.lidar_cell_mean.notna()].copy()
say(f"{len(q)} usable points of {n}. LiDAR cell mean: {(q.lidar_cell_mean < 0.5).mean():.0%} < 0.5 m, "
    f"{(q.lidar_cell_mean > 2).mean():.0%} > 2 m. Photo years {q.photo_year.min():.0f}-{q.photo_year.max():.0f}, "
    f"LiDAR years {q.lidar_year.min():.0f}-{q.lidar_year.max():.0f}. Cells also covered by image matching: "
    f"{(q.n_image_matching_projects > 0).mean():.0%} (laser is drawn on top).")

def err(obs, pr):
    e = pr - obs
    return {"n": len(e), "r": np.corrcoef(obs, pr)[0, 1] if len(e) > 2 else np.nan, "bias": e.mean(),
            "MAE": np.abs(e).mean(), "RMSE": np.sqrt((e ** 2).mean()), "MAE_lt0.5m": np.abs(e[obs < 0.5]).mean(),
            "MAE_ge0.5m": np.abs(e[obs >= 0.5]).mean()}
rnd = lambda d: d.round({"r": 3, "bias": 2, "MAE": 2, "RMSE": 2, "MAE_lt0.5m": 2, "MAE_ge0.5m": 2, "a": 2, "b": 2})

# ---- 1. raw agreement ------------------------------------------------------------
rows = []
for m in MODELS:
    for stat in ("mean", "median"):
        rows.append({"model": m, "stat": stat, "group": "all", "level": "all", **err(q[f"lidar_cell_{stat}"].values, q[f"{m}_{stat}"].values)})
        for g in ("lidar_class", "region", "vegClimZoneLab"):
            for lev, d in q.groupby(g, observed=True):
                rows.append({"model": m, "stat": stat, "group": g, "level": lev, **err(d[f"lidar_cell_{stat}"].values, d[f"{m}_{stat}"].values)})
met = pd.DataFrame(rows); met.to_csv(f"{OUT}/metrics.csv", index=False)
say("\n== 1. raw agreement with LiDAR (no calibration)")
say(rnd(met[met.group == "all"].drop(columns=["group", "level"])).to_string(index=False))

# ---- 2. calibration: LiDAR = a + b * model, validated --------------------------------
def fit(x, y):
    b, a = np.polyfit(x, y, 1); return a, b
def cv(d, m, stat, groups):
    x, y = d[f"{m}_{stat}"].values, d[f"lidar_cell_{stat}"].values
    pred = np.full(len(d), np.nan)
    for gv in pd.unique(groups):
        te = groups == gv
        if te.all() or (~te).sum() < 50: continue
        a, b = fit(x[~te], y[~te]); pred[te] = np.clip(a + b * x[te], 0, None)
    ok = ~np.isnan(pred)
    return err(y[ok], pred[ok])
rng = np.random.default_rng(1)
fold = rng.integers(0, 5, len(q))
rows = []
for m in MODELS:
    for stat in ("mean", "median"):
        x, y = q[f"{m}_{stat}"].values, q[f"lidar_cell_{stat}"].values
        rows.append({"model": m, "stat": stat, "scheme": "none (raw)", **err(y, x)})
        rows.append({"model": m, "stat": stat, "scheme": "random 5-fold", **cv(q, m, stat, fold)})
        rows.append({"model": m, "stat": stat, "scheme": "leave-one-region-out", **cv(q, m, stat, q.region.values)})
        qy = q[q.photo_year.notna()]
        rows.append({"model": m, "stat": stat, "scheme": "leave-one-photo-year-out", **cv(qy, m, stat, qy.photo_year.values)})
val = pd.DataFrame(rows); val.to_csv(f"{OUT}/calibration_validation.csv", index=False)
say("\n== 2. calibration LiDAR = a + b * model, tested on data NOT used for the fit (cell mean)")
say(rnd(val[val.stat == "mean"].drop(columns="stat")).to_string(index=False))
say("\n   (same for the cell median)")
say(rnd(val[val.stat == "median"].drop(columns="stat")).to_string(index=False))

rows = []
for m in MODELS:
    x, y = q[f"{m}_mean"].values, q[f"lidar_cell_mean"].values
    a, b = fit(x, y); rows.append({"model": m, "group": "all", "level": "all", "n": len(q), "a": a, "b": b})
    for g in ("region", "vegClimZoneLab", "photo_year", "density_class"):
        for lev, d in q.groupby(g, observed=True):
            if len(d) < 100: continue
            a, b = fit(d[f"{m}_mean"].values, d.lidar_cell_mean.values)
            rows.append({"model": m, "group": g, "level": lev, "n": len(d), "a": a, "b": b})
coef = pd.DataFrame(rows); coef.to_csv(f"{OUT}/calibration_coefficients.csv", index=False)
say("\n== 3. calibration coefficients (cell mean): how much do a and b move between groups? (groups >= 100 points)")
for m in [m for m in ("chmv1_cpu", "chmv2_06") if m in MODELS]:
    say(f"-- {m}"); say(rnd(coef[coef.model == m].drop(columns="model")).to_string(index=False))

# calibration used for the pictures and residual tables: fitted on all usable non-example points
fit_on = ~q.example if (~q.example).sum() >= 50 else np.ones(len(q), bool)   # tiny test runs: all points
CAL = {m: fit(q.loc[fit_on, f"{m}_mean"].values, q.loc[fit_on, "lidar_cell_mean"].values) for m in MODELS}
for m in MODELS:
    a, b = CAL[m]; q[f"{m}_cal_mean"] = np.clip(a + b * q[f"{m}_mean"], 0, None)

# ---- 4. residuals by factor ----------------------------------------------------------
show = [c for c in ("chmv1_cpu_mean", "chmv1_gpu_06_mean", "chmv2_06_mean", "chmv2_06_cal_mean") if c in q]
rows = []
for g in ("lidar_class", "region", "vegClimZoneLab", "photo_year", "photo_month", "gap_class", "density_class"):
    for lev, d in q.groupby(g, observed=True):
        if len(d) < 30: continue
        r = {"factor": g, "level": lev, "n": len(d)}
        for c in show:
            e = d[c] - d.lidar_cell_mean
            r[f"{c.replace('_mean', '')} bias"] = e.mean(); r[f"{c.replace('_mean', '')} MAE"] = e.abs().mean()
        rows.append(r)
res = pd.DataFrame(rows); res.to_csv(f"{OUT}/residuals_by_factor.csv", index=False)
say("\n== 4. error by factor, cell mean vs LiDAR cell mean (cal = one calibration fitted on all non-example points)")
for g, d in res.groupby("factor", sort=False):
    say(f"-- {g}"); say(d.drop(columns="factor").round(2).to_string(index=False))
for f in sorted(glob.glob(f"{OUT}/timing_*.txt")):
    say(open(f).read().strip())
open(f"{OUT}/summary.txt", "w").write(log.getvalue())
p.merge(q[[c for c in q if c.endswith("_cal_mean")]], left_index=True, right_index=True, how="left").to_csv(f"{OUT}/paired.csv", index=False)

# ---- 5. pictures ------------------------------------------------------------------------
cols = [m for m in ("chmv1_cpu", "chmv1_gpu_06", "chmv2_06") if m in MODELS]
fig, ax = plt.subplots(1, len(cols) + 1, figsize=(4.2 * (len(cols) + 1), 4.2))
for k, c in enumerate([f"{m}_mean" for m in cols] + ["chmv2_06_cal_mean"]):
    if c not in q: continue
    a_ = ax[k]; a_.hexbin(q.lidar_cell_mean, q[c], gridsize=60, bins="log", extent=(0, 20, 0, 20), cmap="viridis", mincnt=1)
    a_.plot([0, 20], [0, 20], "r-", lw=.8); a_.set_xlabel("LiDAR cell mean (m)"); a_.set_ylabel("model cell mean (m)")
    a_.set_title(c.replace("_mean", "").replace("_cal", " calibrated"), fontsize=10)
fig.tight_layout(); fig.savefig(f"{OUT}/scatter.png", dpi=100); plt.close(fig)

photos = np.load(f"{OUT}/photo_examples.npy", mmap_mode="r")
chips = np.load(f"{OUT}/lidar_chips.npy", mmap_mode="r")
ex_all = np.sort(p.index[p.example].to_numpy()); photo_row = {i: k for k, i in enumerate(ex_all)}
pic_cols = ["photo", "LiDAR"] + cols + (["chmv2_06 calibrated"] if "chmv2_06" in MODELS else [])
def panel(rows_idx, fname, title):
    fig, ax = plt.subplots(len(rows_idx), len(pic_cols), figsize=(2.2 * len(pic_cols), 2.25 * len(rows_idx)))
    for r, i in enumerate(rows_idx):
        imgs = [photos[photo_row[i]], chips[i]] + [maps[m][i].astype("float32") for m in cols]
        vals = [None, q.lidar_cell_mean[i]] + [q[f"{m}_mean"][i] for m in cols]
        if "chmv2_06" in MODELS:
            a, b = CAL["chmv2_06"]; imgs.append(np.clip(a + b * maps["chmv2_06"][i].astype("float32"), 0, None)); vals.append(q.chmv2_06_cal_mean[i])
        for c, (im, v) in enumerate(zip(imgs, vals)):
            a_ = ax[r, c]; a_.set_xticks([]); a_.set_yticks([])
            a_.imshow(im) if c == 0 else a_.imshow(im, vmin=0, vmax=15, cmap="viridis")
            k = im.shape[0]; s = k * 20 / 128; o = (k - s) / 2
            a_.add_patch(plt.Rectangle((o - .5, o - .5), s, s, fill=False, ec="red", lw=1))
            if r == 0: a_.set_title(pic_cols[c], fontsize=9)
            if c == 0:
                a_.set_ylabel(f"{q.region[i]}\nphoto {q.photo_start[i]}\nLiDAR {q.lidar_year[i]:.0f}", fontsize=7)
            else:
                a_.set_xlabel(f"cell {v:.1f} m", fontsize=8)
    fig.suptitle(title, fontsize=10); fig.tight_layout(); fig.savefig(fname, dpi=100); plt.close(fig)
exq = q[q.example]
r1 = np.random.default_rng(5)
pick = {c: list(r1.choice(d.index, min(4, len(d)), replace=False)) for c, d in exq.groupby("lidar_class", observed=True)}
note = "128 m around each 20 m cell (red), heights 0-15 m; calibration fitted without these points"
lo = pick.get("<0.5 m", []) + pick.get("0.5-2 m", []); hi = pick.get("2-5 m", []) + pick.get(">5 m", [])
if lo: panel(lo, f"{OUT}/examples_by_class_1.png", "Random examples, LiDAR < 2 m. " + note)
if hi: panel(hi, f"{OUT}/examples_by_class_2.png", "Random examples, LiDAR > 2 m. " + note)
if "chmv2_06" in MODELS:
    worst = (exq.chmv2_06_cal_mean - exq.lidar_cell_mean).abs().sort_values(ascending=False).index[:8]
    panel(list(worst), f"{OUT}/examples_worst.png", "Largest errors of calibrated CHMv2 among the example points. " + note)
say("\nwrote paired.csv, metrics.csv, calibration_*.csv, residuals_by_factor.csv, summary.txt, scatter.png, examples_*.png")
