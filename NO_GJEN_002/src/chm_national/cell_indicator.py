"""NO_GJEN_002 indicator on the 20 m grid over all AR5 mire, from the national
CHM map (national_chm.py). Same design as NO_GJEN_001, but wall-to-wall
instead of a sample of points:

  cells     the global 20 m grid (edges at multiples of 20 m, EPSG:25833);
            every cell that contains AR5 mire. Weight = share of the cell that
            is AR5 mire and not an OSM building (NO_GJEN_001 drops points on
            buildings), 0-1, from the polygons rasterised at 0.5 m.
  height    median of the 1,600 CHM pixels (0.5 m) in the cell, calibrated to
            the LiDAR scale: max(0, a + b * median) (calibration_*.json).
  stratum   region x bioclimatic zone at the cell centre (NO_GJEN_001's bioClimReg).
  index     NO_GJEN_001's scaleSigmoid with the stratum's X100 (ref, column
            ref_mean30) and X0 (skog): height below X100 -> X100;
            x = (h - min) / (max - min) over (X100, h, X0), clamped to 0-1;
            index = 1 - round(1.0068 * (1 - exp(-5 x^2.5)), 4).
  tables    per stratum, region, SSB 50 km cell and Norway, two weightings:
            index_area_weighted  each cell counts with its mire area;
            index_sample_design  each cell counts with its mire area divided by
                                 the stratum's total mire area, i.e. every
                                 stratum weighs the same, as NO_GJEN_001's
                                 sample of up to 1,000 points per stratum.
Cells without a stratum, without X100/X0 for their stratum, or without CHM
pixels are left out and reported.

Chunks are the CHM map's 12.8 km chunks (= 640 x 640 cells), processed in
parallel. Reads that fail are retried after 10, 30 and 90 s; if a chunk still
fails or is missing from the map, the output folder is named *_INCOMPLETE and
the exit code is 2.
Outputs (--out): height_median_raw_m.tif, height_m.tif (calibrated), index.tif,
mire_weight.tif (20 m, float32), strata.csv, region.csv, grid50km.csv,
norway.csv (X100_ref / X0_skog there = mean over the unit's mire area;
height_m_raised_to_X100 = mean height with heights below X100 raised to X100,
NO_GJEN_001's variable v),
sums_by_stratum_and_grid50km.csv (the sums all tables are made from; w = mire
area in 20 m cells, wi / wh / wh_x100 / wraw = w x index / height / height
raised to X100 / raw height; flight_year = year of the photo, from the mosaic's
visible flight project at the cell centre),
excluded.csv, uncertainty.csv (photo- vs LiDAR-based indicator at the validation
cells, per region and Norway; sd = sqrt(difference^2 + SE^2)), provenance.json.
"""
import argparse, datetime, glob, json, os, shutil, subprocess, sys, time, warnings
import multiprocessing as mp
import numpy as np
import pandas as pd
import pyogrio
import rasterio
import shapely
from rasterio.errors import NotGeoreferencedWarning
from rasterio.features import rasterize
from rasterio.transform import Affine
from rasterio.windows import Window
warnings.filterwarnings("ignore", category=NotGeoreferencedWarning)

RES, CELL = 0.5, 20.0
PX = int(CELL / RES)          # 40 px per cell side
NC = 640                      # cells per chunk side (12.8 km)
STRIP = 32                    # cell rows read at a time (1280 px)
CHUNK_BLOCKS = 50             # national_chm.py: 50 x 50 blocks of 256 m per chunk
NODATA_CM = 65535

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--chm", required=True, help="national_chm.py output for one model, e.g. <out>/chmv2")
ap.add_argument("--calibration", required=True)
ap.add_argument("--ar5", required=True); ap.add_argument("--ar5-layer", default="ar5_myr")
ap.add_argument("--buildings", required=True, help="OSM building footprints (GeoPackage)")
ap.add_argument("--regions", required=True); ap.add_argument("--bioclim", required=True)
ap.add_argument("--ssb50km", required=True)
ap.add_argument("--ref", required=True, help="X100 table (refvaatmark_openS_30m.csv)")
ap.add_argument("--skog", required=True, help="X0 table (vegHeights_skog_climZoneRegion_openS_20m.csv)")
ap.add_argument("--out", required=True); ap.add_argument("--staging", required=True)
ap.add_argument("--flight-projects", required=True, help="the mosaic's visible flight projects (mosaic_coverage_by_project.gpkg; field PROJECT ends with the flight year)")
ap.add_argument("--validation", required=True, help="validation cells with LiDAR heights: csv with cell_x, cell_y, region, vegClimZoneLab, lidar_cell_median")
ap.add_argument("--workers", type=int, default=16)
ap.add_argument("--bbox", type=float, nargs=4, metavar=("XMIN", "YMIN", "XMAX", "YMAX"), help="only cells in this box (tests)")
a = ap.parse_args()
def log(*m): print(datetime.datetime.now().strftime("%H:%M:%S"), *m, flush=True)
t_start = time.time()

# ---- grid of the CHM map -----------------------------------------------------------------
prov_chm = sorted(glob.glob(f"{a.chm}/provenance_*.json"))
assert prov_chm, f"no provenance_*.json in {a.chm}"
grid = json.load(open(prov_chm[-1]))["grid"]
X0, Y0 = grid["x0"], grid["y0"]
assert grid["res"] == RES and grid["chunk_blocks"] == CHUNK_BLOCKS and grid["units"] == "cm"
assert X0 % CELL == 0 and Y0 % CELL == 0, "CHM grid not aligned to the 20 m grid"
blocks = np.load(os.path.join(os.path.dirname(a.chm.rstrip("/")), "block_mask_ar5_30m.npy"))
CM = NC * CELL                # 12,800 m
chunks = []
for i, cr in enumerate(range(0, blocks.shape[0], CHUNK_BLOCKS)):
    for j, cc in enumerate(range(0, blocks.shape[1], CHUNK_BLOCKS)):
        if not blocks[cr:cr + CHUNK_BLOCKS, cc:cc + CHUNK_BLOCKS].any(): continue
        x0, y1 = X0 + j * CM, Y0 - i * CM
        if a.bbox and not (x0 + CM > a.bbox[0] and x0 < a.bbox[2] and y1 > a.bbox[1] and y1 - CM < a.bbox[3]): continue
        chunks.append((i, j, f"r{i:03d}_c{j:03d}"))
NROW, NCOL = -(-blocks.shape[0] // CHUNK_BLOCKS) * NC, -(-blocks.shape[1] // CHUNK_BLOCKS) * NC
log(f"{len(chunks)} chunks with AR5 mire{' in the box' if a.bbox else ''}")

# ---- calibration, references, strata (read once, shared with the workers by fork) ----------
cal = json.load(open(a.calibration))
CAL_A, CAL_B = cal["a"], cal["b"]
def read_vec(path, cols, **kw):
    meta, _, wkb, fields = pyogrio.raw.read(path, columns=cols, **kw)
    return shapely.from_wkb(wkb), dict(zip(meta["fields"], fields))
# no .cpg files: regions.shp is UTF-8, soner2017.shp Latin-1 (GDAL's default); names are checked below
reg_g, f = read_vec(a.regions, ["region"], encoding="UTF-8"); reg_name = list(f["region"])
zon_g, f = read_vec(a.bioclim, ["Sone_navn"]); zon_all = list(f["Sone_navn"])
ZONES = sorted(set(zon_all)); zon_code = np.array([ZONES.index(z) + 1 for z in zon_all])
ssb_g, f = read_vec(a.ssb50km, ["SSBID"]); SSB = list(f["SSBID"])
fp_g, f = read_vec(a.flight_projects, ["PROJECT"]); fp_year = np.array([int(p[-4:]) for p in f["PROJECT"]])
REGIONS = reg_name
ref = pd.read_csv(a.ref)[["region", "vegClimZoneLab", "ref_mean30"]].rename(columns={"ref_mean30": "ref"})
skog = pd.read_csv(a.skog)[["region", "vegClimZoneLab", "skog"]]
refs = ref.merge(skog, on=["region", "vegClimZoneLab"], how="outer")
unknown = (set(refs.region) - set(REGIONS)) | (set(refs.vegClimZoneLab) - set(ZONES))
assert not unknown, f"names in the reference tables not found in regions/bioclim: {unknown} (encoding?)"
REF = np.full((len(REGIONS) + 1, len(ZONES) + 1), np.nan); SKOG = REF.copy()
for r in refs.itertuples():
    REF[REGIONS.index(r.region) + 1, ZONES.index(r.vegClimZoneLab) + 1] = r.ref
    SKOG[REGIONS.index(r.region) + 1, ZONES.index(r.vegClimZoneLab) + 1] = r.skog
trees = {k: (g, shapely.STRtree(g), v) for k, g, v in (
    ("region", reg_g, np.arange(1, len(reg_g) + 1)), ("zone", zon_g, zon_code), ("ssb", ssb_g, np.arange(1, len(ssb_g) + 1)), ("year", fp_g, fp_year))}
log(f"{len(REGIONS)} regions, {len(ZONES)} bioclimatic zones, {len(SSB)} 50 km cells; "
    f"{np.isfinite(REF + SKOG).sum()} strata with X100 and X0; calibration a={CAL_A}, b={CAL_B}")


def burn(geoms, values, shape, transform):
    if len(geoms) == 0: return np.zeros(shape, np.int32)
    return rasterize(zip(geoms, values), out_shape=shape, transform=transform, fill=0, dtype="int32")

def clipped(tree_geoms, tree, box):
    idx = tree.query(shapely.box(*box))
    g = shapely.clip_by_rect(tree_geoms[idx], *box)
    keep = ~shapely.is_empty(g)
    return g[keep], idx[keep]

def index_from_height(h, r, z):
    """NO_GJEN_001 scaleSigmoid, vectorised. h calibrated height (m); r, z stratum codes."""
    x100, x0 = REF[r, z], SKOG[r, z]
    pop = np.where(h < x100, x100, h)
    lo = np.minimum(np.minimum(x100, pop), x0); hi = np.maximum(np.maximum(x100, pop), x0)
    with np.errstate(invalid="ignore", divide="ignore"):
        x = np.clip((pop - lo) / (hi - lo), 0, 1)
    return 1 - np.round(1.0068 * (1 - np.exp(-5 * x ** 2.5)), 4)


def process_chunk(ci, cj, name):
    tif = f"{a.chm}/chunks/{name}.tif"; js = f"{a.chm}/chunks/{name}.json"
    if not (os.path.exists(tif) and json.load(open(js)).get("status") == "complete"):
        return name, "missing from the CHM map (or not complete)", None
    x0, y1 = X0 + cj * CM, Y0 - ci * CM
    for wait in (10, 30, 90, None):
        try:
            return name, None, _chunk(tif, x0, y1)
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
            if wait is None: return name, err, None
            log(f"retry in {wait}s: {name}: {err}"); time.sleep(wait)

def _chunk(tif, x0, y1):
    box = (x0, y1 - CM, x0 + CM, y1)
    _, _, wkb, _ = pyogrio.raw.read(a.ar5, layer=a.ar5_layer, columns=[], bbox=box)
    mire = shapely.from_wkb(wkb); mire_t = shapely.STRtree(mire)
    _, _, wkb, _ = pyogrio.raw.read(a.buildings, columns=[], bbox=box)
    bld = shapely.from_wkb(wkb); bld = bld[np.isin(shapely.get_type_id(bld), (3, 6))]; bld_t = shapely.STRtree(bld)  # polygons only
    out = {k: np.full((NC, NC), np.nan, np.float32) for k in ("raw", "height", "index", "weight")}
    codes = {k: np.zeros((NC, NC), np.int32) for k in ("region", "zone", "ssb", "year")}
    nodata_cells = 0
    with rasterio.open(tif) as ds:
        assert ds.transform.c == x0 and ds.transform.f == y1 and ds.width == NC * PX, (ds.transform, x0, y1)
        for s in range(0, NC, STRIP):
            sb = (x0, y1 - (s + STRIP) * CELL, x0 + CM, y1 - s * CELL)
            g, _ = clipped(mire, mire_t, sb)
            if len(g) == 0: continue
            T05 = Affine(RES, 0, sb[0], 0, -RES, sb[3]); shp = (STRIP * PX, NC * PX)
            inside = burn(g, np.ones(len(g)), shp, T05) > 0
            gb, _ = clipped(bld, bld_t, sb)
            if len(gb): inside &= burn(gb, np.ones(len(gb)), shp, T05) == 0
            w = inside.reshape(STRIP, PX, NC, PX).sum(axis=(1, 3)) / (PX * PX)
            if a.bbox:      # cells whose centre is in the box
                cx = x0 + (np.arange(NC) + 0.5) * CELL; cy = sb[3] - (np.arange(STRIP) + 0.5) * CELL
                w[~((cy[:, None] > a.bbox[1]) & (cy[:, None] < a.bbox[3]) & (cx[None] > a.bbox[0]) & (cx[None] < a.bbox[2]))] = 0
            sel = w > 0
            if not sel.any(): continue
            arr = ds.read(1, window=Window(0, s * PX, NC * PX, STRIP * PX))
            cells = arr.reshape(STRIP, PX, NC, PX).transpose(0, 2, 1, 3).reshape(STRIP, NC, PX * PX)[sel]
            cells.sort(axis=1)                                    # nodata (65535) sorts last
            k = (cells != NODATA_CM).sum(axis=1)
            rows = np.arange(len(k)); lo_i, hi_i = np.maximum((k - 1) // 2, 0), np.maximum(k // 2, 0)
            med = (cells[rows, lo_i].astype(np.float64) + cells[rows, hi_i]) / 2 / 100
            med[k == 0] = np.nan
            nodata_cells += int(((k < PX * PX) & (k > 0)).sum())
            T20 = Affine(CELL, 0, sb[0], 0, -CELL, sb[3])
            for key, (tg, tt, tv) in trees.items():
                gg, idx = clipped(tg, tt, sb)
                codes[key][s:s + STRIP] = burn(gg, tv[idx], (STRIP, NC), T20)
            rs = slice(s, s + STRIP)
            out["weight"][rs][sel] = w[sel]
            out["raw"][rs][sel] = med
            h = np.maximum(0, CAL_A + CAL_B * med)
            out["height"][rs][sel] = h
            out["index"][rs][sel] = index_from_height(h, codes["region"][rs][sel], codes["zone"][rs][sel])
    # sums per region x zone x 50 km cell, and what is left out
    w = np.nan_to_num(out["weight"])
    ok = (w > 0) & np.isfinite(out["index"])
    df = pd.DataFrame({"r": codes["region"][ok], "z": codes["zone"][ok], "ssb": codes["ssb"][ok], "y": codes["year"][ok], "w": w[ok],
                       "wi": w[ok] * out["index"][ok], "wh": w[ok] * out["height"][ok], "wraw": w[ok] * out["raw"][ok]})
    # height as NO_GJEN_001 reports it (its variable v): below X100 raised to X100
    rz = (codes["region"][ok], codes["zone"][ok])
    df["wh_x100"] = w[ok] * np.maximum(out["height"][ok], REF[rz])
    df["n"] = 1
    sums = df.groupby(["r", "z", "ssb", "y"]).sum().reset_index()
    has = w > 0
    excl = {"cells with mire": int(has.sum()), "mire km2": float(w.sum() * CELL ** 2 / 1e6),
            "no CHM pixels": int((has & np.isnan(out["raw"])).sum()),
            "outside regions x zones": int((has & ((codes["region"] == 0) | (codes["zone"] == 0))).sum()),
            "stratum without X100/X0": int((has & np.isfinite(out["raw"]) & (codes["region"] > 0) & (codes["zone"] > 0)
                                            & ~np.isfinite(REF[codes["region"], codes["zone"]] + SKOG[codes["region"], codes["zone"]])).sum()),
            "cells with some CHM nodata (median of the rest)": nodata_cells}
    excl["used"] = int(ok.sum()); excl["used mire km2"] = float(w[ok].sum() * CELL ** 2 / 1e6)
    return out, sums, excl


# ---- run ---------------------------------------------------------------------------------
stage = os.path.join(a.staging, "cell_indicator"); os.makedirs(stage, exist_ok=True)
for f in glob.glob(f"{stage}/*"): os.remove(f)
RASTERS = {"raw": "height_median_raw_m", "height": "height_m", "index": "index", "weight": "mire_weight"}
profile = dict(driver="GTiff", dtype="float32", count=1, nodata=float("nan"), width=NCOL, height=NROW,
               crs="EPSG:25833", transform=Affine(CELL, 0, X0, 0, -CELL, Y0), tiled=True, blockxsize=NC, blockysize=NC,
               compress="ZSTD", predictor=3, zstd_level=9, BIGTIFF="YES", SPARSE_OK=True)
dsts = {k: rasterio.open(f"{stage}/{v}.tif", "w", **profile) for k, v in RASTERS.items()}
all_sums, all_excl, failed = [], [], []
last = 0
def run_one(c): return c, process_chunk(*c)
with mp.get_context("fork").Pool(a.workers) as pool:
    for n, ((ci, cj, _), (name, err, res)) in enumerate(pool.imap_unordered(run_one, chunks), 1):
        if err:
            failed.append({"chunk": name, "error": err}); log(f"FAILED {name}: {err}")
        else:
            out, sums, excl = res
            for k, d in dsts.items():
                if np.isfinite(out[k]).any():
                    d.write(out[k], 1, window=Window(cj * NC, ci * NC, NC, NC))
            all_sums.append(sums); all_excl.append(excl)
        if time.time() - last > 60 or n == len(chunks):
            last = time.time(); el = last - t_start
            log(f"chunk {n}/{len(chunks)}, failed {len(failed)}, ETA {(len(chunks) - n) * el / n / 3600:.1f} h")
for d in dsts.values(): d.close()

# ---- uncertainty: photo-based vs LiDAR-based indicator at the validation cells --------------
# At each validation cell the indicator is computed twice: from the LiDAR height and from this
# run's raw cell median, calibrated with a fit that leaves the cell's region out. Per region and
# for Norway: sd = sqrt(mean difference^2 + SE^2), SE from 1,000 bootstrap resamples of the cells.
v = pd.read_csv(a.validation)
with rasterio.open(f"{stage}/{RASTERS['raw']}.tif") as ds:
    v["raw"] = [x[0] for x in ds.sample(zip(v.cell_x, v.cell_y))]
v["r"] = [REGIONS.index(x) + 1 if x in REGIONS else 0 for x in v.region]
v["z"] = [ZONES.index(x) + 1 if x in ZONES else 0 for x in v.vegClimZoneLab]
v = v[np.isfinite(v.raw) & np.isfinite(v.lidar_cell_median) & np.isfinite(REF[v.r.to_numpy(), v.z.to_numpy()] + SKOG[v.r.to_numpy(), v.z.to_numpy()])].copy()
v["h_photo"] = np.nan
for r in v.r.unique():
    te = (v.r == r).to_numpy()
    tr = ~te if (~te).any() else te           # only one region (a --bbox test): fit on it
    b, a0 = np.polyfit(v.raw[tr], v.lidar_cell_median[tr], 1)
    v.loc[te, "h_photo"] = np.maximum(0, a0 + b * v.raw[te])
v["i_lidar"] = index_from_height(v.lidar_cell_median.to_numpy(), v.r.to_numpy(), v.z.to_numpy())
v["i_photo"] = index_from_height(v.h_photo.to_numpy(), v.r.to_numpy(), v.z.to_numpy())
rng = np.random.default_rng(1); unc = []
for name, g in [(REGIONS[r - 1], v[v.r == r]) for r in sorted(v.r.unique())] + [("Norge", v)]:
    diff = (g.i_photo - g.i_lidar).to_numpy()
    boot = np.array([diff[rng.integers(0, len(diff), len(diff))].mean() for _ in range(1000)])
    unc.append({"region": name, "n_validation_cells": len(g), "index_lidar": g.i_lidar.mean(), "index_photo": g.i_photo.mean(),
                "difference": diff.mean(), "se_difference": boot.std(), "sd": np.sqrt(diff.mean() ** 2 + boot.std() ** 2)})
unc = pd.DataFrame(unc)

# ---- tables --------------------------------------------------------------------------------
s = pd.concat(all_sums).groupby(["r", "z", "ssb", "y"]).sum().reset_index()
s["region"] = [REGIONS[i - 1] for i in s.r]; s["vegClimZoneLab"] = [ZONES[i - 1] for i in s.z]
s["SSBID"] = [SSB[i - 1] if i > 0 else None for i in s.ssb]
A_s = s.groupby(["r", "z"]).w.transform("sum")            # stratum mire area (in cell units)
s["w_eq"], s["wi_eq"] = s.w / A_s, s.wi / A_s
s["wref"], s["wskog"] = s.w * REF[s.r.to_numpy(), s.z.to_numpy()], s.w * SKOG[s.r.to_numpy(), s.z.to_numpy()]
def table(by):
    g = s.groupby(by, dropna=False) if by else s.assign(_all="Norge").groupby("_all")
    t = g[["n", "w", "wi", "wh", "wh_x100", "wraw", "w_eq", "wi_eq", "wref", "wskog"]].sum()
    return pd.DataFrame({"n_cells": t.n, "mire_km2": t.w * CELL ** 2 / 1e6,
                         "height_m": t.wh / t.w, "height_m_raised_to_X100": t.wh_x100 / t.w, "height_median_raw_m": t.wraw / t.w,
                         "index_area_weighted": t.wi / t.w, "index_sample_design": t.wi_eq / t.w_eq,
                         "X100_ref": t.wref / t.w, "X0_skog": t.wskog / t.w}).join(flight_years(by)).reset_index()   # references: mean over the unit's mire area
def flight_years(by):
    """Flight year of the photo (year of the mosaic's visible flight project at the cell centre),
    over the unit's mire area: median, earliest and latest."""
    d = s[s.y > 0]
    g = d.groupby(by + ["y"], dropna=False).w.sum().reset_index() if by else d.assign(_all="Norge").groupby(["_all", "y"]).w.sum().reset_index()
    def summ(x):
        x = x.sort_values("y"); c = x.w.cumsum()
        return pd.Series({"flight_year_median": int(x.y[c >= c.iloc[-1] / 2].iloc[0]), "flight_year_min": int(x.y.min()), "flight_year_max": int(x.y.max())})
    return g.groupby(by if by else "_all", dropna=False)[["y", "w"]].apply(summ)
strata = table(["region", "vegClimZoneLab"]).drop(columns="index_sample_design").rename(columns={"index_area_weighted": "index"})
sums = s.assign(mire_km2=s.w * CELL ** 2 / 1e6, flight_year=s.y.where(s.y > 0))[["region", "vegClimZoneLab", "SSBID", "flight_year", "n", "mire_km2", "w", "wi", "wh", "wh_x100", "wraw"]]
tables = {"strata": strata, "region": table(["region"]), "grid50km": table(["SSBID"]),
          "norway": table(None).drop(columns="_all"), "sums_by_stratum_and_grid50km": sums}
excluded = pd.DataFrame(all_excl).sum().rename("value").to_frame()

complete = not failed
final = a.out if complete else a.out.rstrip("/") + "_INCOMPLETE"
os.makedirs(final, exist_ok=True)
for k, t in tables.items():
    t.round(6).to_csv(f"{stage}/{k}.csv", index=False)
excluded.to_csv(f"{stage}/excluded.csv")
unc.round(6).to_csv(f"{stage}/uncertainty.csv", index=False)
log("building overviews...")
for v in RASTERS.values():
    subprocess.run(["gdaladdo", "-q", "-r", "average", "--config", "COMPRESS_OVERVIEW", "ZSTD",
                    "--config", "PREDICTOR_OVERVIEW", "3", "--config", "GDAL_NUM_THREADS", "ALL_CPUS",
                    "--config", "SPARSE_OK_OVERVIEW", "YES", f"{stage}/{v}.tif", "2", "4", "8", "16", "32", "64"], check=True)
prov = {"finished": datetime.datetime.now().isoformat(timespec="seconds"), "args": vars(a), "complete": complete,
        "failed_chunks": failed, "chunks": len(chunks), "calibration": cal, "chm_provenance": json.load(open(prov_chm[-1])),
        "inputs": {k: {"path": p, "bytes": os.path.getsize(p), "mtime": os.path.getmtime(p)} for k, p in (
            ("ar5", a.ar5), ("buildings", a.buildings), ("regions", a.regions), ("bioclim", a.bioclim),
            ("ssb50km", a.ssb50km), ("ref", a.ref), ("skog", a.skog), ("validation", a.validation), ("flight_projects", a.flight_projects))},
        "excluded": excluded.value.to_dict(), "code_commit": os.environ.get("CODE_COMMIT"),
        "packages": {m: sys.modules[m].__version__ for m in ("numpy", "pandas", "rasterio", "shapely", "pyogrio")},
        "seconds": round(time.time() - t_start)}
json.dump(prov, open(f"{stage}/provenance.json", "w"), indent=1, default=str)
for f in sorted(os.listdir(stage)):
    shutil.copyfile(f"{stage}/{f}", f"{final}/{f}.part"); os.replace(f"{final}/{f}.part", f"{final}/{f}")
    os.remove(f"{stage}/{f}")
log("excluded / used:\n" + excluded.to_string())
log("uncertainty (validation cells):\n" + unc.round(4).to_string(index=False))
log("Norway:\n" + tables["norway"].round(4).to_string(index=False))
log(f"done in {(time.time() - t_start) / 60:.0f} min: {final}")
if not complete:
    log(f"NOT COMPLETE: {len(failed)} chunk(s) failed or missing; run again after fixing (see provenance.json)")
    sys.exit(2)
