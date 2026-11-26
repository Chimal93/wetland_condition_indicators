"""Inputs for the canopy-height model comparison.

1. Points: NO_GJEN_001's AR5 mire sample (vaatmark_pop_openS.gpkg). All points
   (N_PER_STRATUM=0, default) or N per stratum (region x bioclimatic zone).
2. The 20 m LiDAR cell exactly as NO_GJEN_001 builds it: the cell of the
   global 20 m grid (EPSG:25833, edges at multiples of 20 m) that CONTAINS the
   point. The point lies anywhere in its cell, not at its centre.
3. A 576 x 576 px (288 m) orthophoto window at 0.5 m CENTRED ON THE CELL, so
   the cell is exactly the central 40 x 40 px of every window. The mosaic grid
   and the 20 m grid are both aligned to whole 0.5 m pixels: no resampling.
4. LiDAR cell from Kartverket DOM1 - DTM1 (1 m, as NO_GJEN_001): median of the
   CHM clamped at 0 (NO_GJEN_001's statistic) and mean of the clamped CHM;
   plus a 128 m CHM chip for the example maps.
5. Photo: flight project, dates and original pixel size at the cell centre
   (mosaic metadata, as NO_GJEN_002/R/assign_orthophoto_flight_dates.R).
6. LiDAR: the projects of Kartverket's surface-model catalogue covering the
   cell centre (footprints downloaded once from hoydedata.no). The national
   DOM1 is built from LASER projects (type 1); among those, the one with the
   lowest ZORDER is drawn on top, so it is recorded as the source. Image-
   matching projects (type 2) covering the cell are counted separately.
7. Example points: 60 per LiDAR height class (seed 1), whose full maps are
   kept for the pictures.

Reads of the orthophoto (often on a network drive) and from the LiDAR server
are retried (10/30/90 s); points that still fail are reported and dropped.
The NO_GJEN_001 sample is read from /gjen001 (mounted by the runner).
Outputs ($OUT): points.csv, tiles_576.npy (uint8 N x 576 x 576 x 3, deleted by
run_all.sh at the end unless KEEP_TILES=yes), lidar_chips.npy (float32,
N x 128 x 128), photo_examples.npy, lidar_projects.gpkg.
"""
import json, os, threading, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
import numpy as np, pandas as pd, geopandas as gpd, rasterio
from rasterio.windows import from_bounds

N_PER_STRATUM = int(os.environ.get("N_PER_STRATUM", "0"))
OUT = os.environ.get("OUT", "out")
ORTHO = os.environ["ORTHOPHOTO_SOURCE_PATH"]                       # the mosaic (local file)
META = os.path.join(os.path.dirname(ORTHO), "metadata")           # its flight metadata, delivered with it
LIDAR = "/vsicurl/https://nedlasting.geonorge.no/hoydedata/{}/{}.tif"
CATALOG = "https://hoydedata.no/arcgis/rest/services/DOM/ImageServer/query"
CELL, WIN_M, CHIP_M = 20.0, 288.0, 128.0
os.makedirs(OUT, exist_ok=True)


def retry(fn, what):
    for wait in (10, 30, 90, None):
        try:
            return fn()
        except Exception as e:
            if wait is None:
                print(f"FAILED {what}: {e}", flush=True); return None
            print(f"retry {what} in {wait}s: {e}", flush=True); time.sleep(wait)


# ---- 1-2. points and cells ---------------------------------------------------
pts = gpd.read_file("/gjen001/vaatmark_pop_openS.gpkg")
if N_PER_STRATUM > 0:
    pts = pts.groupby("stratum_ID").sample(n=N_PER_STRATUM, random_state=1)
pts = pts.rename(columns={"chm": "chm_gjen001_5m_window"}).reset_index(drop=True)
pts["x"], pts["y"] = pts.geometry.x, pts.geometry.y
pts["cell_x"] = np.floor(pts.x / CELL) * CELL + CELL / 2
pts["cell_y"] = np.floor(pts.y / CELL) * CELL + CELL / 2
n = len(pts)
print(f"{n} points in {pts.stratum_ID.nunique()} strata", flush=True)

# ---- 3. orthophoto windows, written straight to disk --------------------------
tiles = np.lib.format.open_memmap(f"{OUT}/tiles_576.npy", mode="w+", dtype=np.uint8, shape=(n, 576, 576, 3))
_loc = threading.local()
def read_tile(i):
    def f():
        if not hasattr(_loc, "ds"): _loc.ds = rasterio.open(ORTHO)
        ds, cx, cy, h = _loc.ds, pts.cell_x[i], pts.cell_y[i], WIN_M / 2
        w = from_bounds(cx - h, cy - h, cx + h, cy + h, ds.transform)
        assert float(w.col_off).is_integer() and float(w.row_off).is_integer(), w   # no sub-pixel shift
        a = ds.read([1, 2, 3], window=w)
        assert a.shape == (3, 576, 576), a.shape
        tiles[i] = a.transpose(1, 2, 0)
        return True
    return retry(f, f"orthophoto point {i}")
t = time.time()
with ThreadPoolExecutor(16) as ex: ok_tile = list(ex.map(read_tile, range(n)))
tiles.flush()
print(f"orthophoto windows: {time.time() - t:.0f}s", flush=True)

# ---- 4. LiDAR cell (DOM1 - DTM1) and 128 m chip -------------------------------
chips = np.lib.format.open_memmap(f"{OUT}/lidar_chips.npy", mode="w+", dtype=np.float32, shape=(n, 128, 128))
def read_lidar(i):
    def f():
        with rasterio.Env(GDAL_HTTP_MAX_RETRY=3, GDAL_HTTP_RETRY_DELAY=5):
            dom = rasterio.open(LIDAR.format("DOM1", pts.tile_id[i]))
            dtm = rasterio.open(LIDAR.format("DTM1", pts.tile_id[i]))
            cx, cy, out = pts.cell_x[i], pts.cell_y[i], {}
            for name, h in (("cell", CELL / 2), ("chip", CHIP_M / 2)):
                w = from_bounds(cx - h, cy - h, cx + h, cy + h, dom.transform)
                k = int(round(2 * h))
                kw = dict(window=w, boundless=True, fill_value=np.nan, out_shape=(k, k), masked=True)
                out[name] = (dom.read(1, **kw).astype("float32").filled(np.nan)
                             - dtm.read(1, **kw).astype("float32").filled(np.nan))
        raw = out["cell"]
        chips[i] = np.clip(out["chip"], 0, None)
        return (float(np.nanmedian(np.clip(raw, 0, None))),   # = NO_GJEN_001 "cell_median"
                float(np.nanmean(np.clip(raw, 0, None))),     # mean of the clamped CHM
                float(np.isnan(raw).mean()))
    return retry(f, f"LiDAR point {i}")
t = time.time()
with ThreadPoolExecutor(8) as ex: lid = list(ex.map(read_lidar, range(n)))   # 8 workers, as NO_GJEN_001
chips.flush()
print(f"LiDAR cells: {time.time() - t:.0f}s", flush=True)
pts["lidar_cell_median"] = [l[0] if l else np.nan for l in lid]
pts["lidar_cell_mean"] = [l[1] if l else np.nan for l in lid]
pts["lidar_cell_nodata_share"] = [l[2] if l else np.nan for l in lid]

# ---- 5. photo: flight project, dates, original pixel size ----------------------
cells = gpd.GeoDataFrame(index=pts.index, geometry=gpd.points_from_xy(pts.cell_x, pts.cell_y), crs=25833)
vis = gpd.read_file(f"{META}/mosaic_coverage_by_project.gpkg").to_crs(25833)
grid = gpd.read_file(f"{META}/metadata_omløpsprosjekt_mosaic_v2_2025.gpkg", layer="mosaic_grid").to_crs(25833)
pix = next((c for c in vis.columns if c.lower().startswith("pixelst")), None)
j = gpd.sjoin(cells, vis[["PROJECT", "geometry"] + ([pix] if pix else [])], how="left", predicate="within")
j = j[~j.index.duplicated()]
g = gpd.sjoin(j.drop(columns="index_right"), grid[["PROJECT", "STARTDATO", "SLUTTDATO", "geometry"]], how="left", predicate="within")
g = g[g.PROJECT_left == g.PROJECT_right]; g = g[~g.index.duplicated()]
pts["photo_project"] = j.PROJECT
pts["photo_pixel_size_m"] = pd.to_numeric(j[pix], errors="coerce") if pix else np.nan
pts["photo_start"] = g.STARTDATO.reindex(pts.index)
pts["photo_end"] = g.SLUTTDATO.reindex(pts.index)

# ---- 6. LiDAR projects ----------------------------------------------------------
proj_path = f"{OUT}/lidar_projects.gpkg"
def esri_polygon(geom):
    """Esri JSON rings -> shapely: clockwise rings are outer rings, the others holes."""
    from shapely.geometry import LinearRing, MultiPolygon, Polygon
    outers, holes = [], []
    for ring in geom["rings"]:
        (holes if LinearRing(ring).is_ccw else outers).append(ring)
    polys = [Polygon(o, [h for h in holes if Polygon(o).contains(Polygon(h).representative_point())]) for o in outers]
    return polys[0] if len(polys) == 1 else MultiPolygon(polys)
if not os.path.exists(proj_path):
    rows, offset = [], 0
    while True:
        q = urllib.parse.urlencode({
            "where": "CATEGORY=1 AND LAS_PROJECT_NAME IS NOT NULL", "outSR": 25833, "f": "json",
            "outFields": "OBJECTID,LAS_PROJECT_NAME,TYPE,AARSTALL,SISTEFLYDATO,PUNKTTETTHET,ZORDER,PRIORITET",
            "resultOffset": offset, "resultRecordCount": 500, "orderByFields": "OBJECTID"})
        page = retry(lambda: json.load(urllib.request.urlopen(f"{CATALOG}?{q}", timeout=300)), f"catalog page {offset}")
        if page is None or "features" not in page: raise SystemExit(f"could not download the LiDAR project catalogue: {page}")
        rows += [{**f["attributes"], "geometry": esri_polygon(f["geometry"])} for f in page["features"]]
        offset += 500
        if len(page["features"]) < 500: break
    proj = gpd.GeoDataFrame(rows, geometry="geometry", crs=25833)
    proj.to_file(proj_path)
    print(f"LiDAR project catalogue: {len(proj)} footprints", flush=True)
proj = gpd.read_file(proj_path)
proj["SISTEFLYDATO"] = pd.to_datetime(proj.SISTEFLYDATO, unit="ms", errors="coerce") if proj.SISTEFLYDATO.dtype != "datetime64[ns]" else proj.SISTEFLYDATO
# When was each DOM1 tile last rebuilt? Projects flown after that are not in it yet.
def last_modified(tile):
    def f():
        r = urllib.request.urlopen(urllib.request.Request(LIDAR.format("DOM1", tile).replace("/vsicurl/", ""), method="HEAD"), timeout=60)
        return pd.Timestamp(r.headers["Last-Modified"]).tz_localize(None)
    return retry(f, f"tile date {tile}")
tiles_u = pts.tile_id.dropna().unique()
with ThreadPoolExecutor(8) as ex: mod = dict(zip(tiles_u, ex.map(last_modified, tiles_u)))
pts["dom1_tile_modified"] = pts.tile_id.map(mod)
hit = gpd.sjoin(cells, proj, how="inner", predicate="within")
hit["tile_modified"] = pts.dom1_tile_modified.reindex(hit.index).values
las = hit[hit.TYPE == "1"].sort_values("ZORDER")                   # lowest ZORDER = newest = on top
in_tile = las[las.SISTEFLYDATO.isna() | las.tile_modified.isna() | (las.SISTEFLYDATO <= las.tile_modified)]
laser = in_tile.groupby(level=0).head(1)
pts["lidar_project"] = laser.LAS_PROJECT_NAME.reindex(pts.index)
pts["lidar_year"] = laser.AARSTALL.reindex(pts.index)
pts["lidar_date"] = laser.SISTEFLYDATO.reindex(pts.index)
pts["lidar_density_pts_m2"] = laser.PUNKTTETTHET.reindex(pts.index)
pts["newer_laser_not_in_tile"] = las.groupby(level=0).head(1).AARSTALL.reindex(pts.index).gt(pts.lidar_year)
pts["n_laser_projects"] = hit[hit.TYPE == "1"].groupby(level=0).size().reindex(pts.index).fillna(0).astype(int)
pts["n_image_matching_projects"] = hit[hit.TYPE == "2"].groupby(level=0).size().reindex(pts.index).fillna(0).astype(int)

# ---- 7. drop failures, choose examples, write ----------------------------------
ok = np.array([bool(ok_tile[i]) and lid[i] is not None for i in range(n)])
pts["no_photo"] = [(tiles[i, 268:308, 268:308] == 255).all(axis=2).mean() > 0.5 for i in range(n)]
pts["usable"] = ok & ~pts.no_photo.values & pts.lidar_cell_mean.notna().values
if (~ok).any():
    print(f"WARNING: {(~ok).sum()} points failed after retries and are marked unusable: {np.where(~ok)[0].tolist()}", flush=True)
cls = pd.cut(pts.lidar_cell_mean, [-0.01, 0.5, 2, 5, 1000], labels=["<0.5 m", "0.5-2 m", "2-5 m", ">5 m"])
pts["lidar_class"] = cls
ex = pts[pts.usable].sample(frac=1, random_state=1).groupby("lidar_class", observed=True).head(60).index
pts["example"] = pts.index.isin(ex)
np.save(f"{OUT}/photo_examples.npy", tiles[np.sort(ex)][:, 160:416, 160:416])
pts.drop(columns="geometry").to_csv(f"{OUT}/points.csv", index=False)
u = pts[pts.usable]
print(f"{len(pts)} points, {len(u)} usable ({pts.no_photo.sum()} without photo, {(~ok).sum()} failed)")
print(f"photo dates found {u.photo_start.notna().mean():.1%}; LiDAR laser project found {u.lidar_year.notna().mean():.1%}; "
      f"cells also covered by image matching {(u.n_image_matching_projects > 0).mean():.1%}; "
      f"newer laser project not yet in the DOM1 tile {u.newer_laser_not_in_tile.mean():.1%}; "
      f"DOM1 tiles last rebuilt {u.dom1_tile_modified.min()} - {u.dom1_tile_modified.max()}")
print(f"LiDAR years: {u.lidar_year.min():.0f}-{u.lidar_year.max():.0f}, median {u.lidar_year.median():.0f}; "
      f"density median {u.lidar_density_pts_m2.median()} pts/m2", flush=True)
