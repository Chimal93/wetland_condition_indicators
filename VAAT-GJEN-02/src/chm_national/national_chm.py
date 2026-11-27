"""National canopy-height map over all AR5 mire (VAAT-GJEN-02), on GPU.

Runs one model over every 256 m block of the orthophoto mosaic that lies
within 30 m of an AR5 mire polygon, and writes canopy height in cm at 0.5 m
for the pixels within 30 m of mire (other pixels: nodata). The 30 m buffer
keeps every 20 m cell around a mire point complete (VAAT-GJEN-01's sample cells
can reach up to 28.3 m from their point).

Models (--model):
  chmv1  Meta HighResCanopyHeight, aerial checkpoint compressed_SSLhuge_aerial.pth
         (the model of the published VAAT-GJEN-02 run). Its int8 layers are
         converted back to float so it runs on GPU (checked against the CPU
         int8 path on 2,000 points: same accuracy against LiDAR). Input as
         published: 256 x 256 px tiles at 0.5 m, four per block, no overlap.
  chmv2  Meta/WRI CHMv2 (facebook/dinov3-vitl16-chmv2-dpt-head). The block plus
         a 40 m margin (672 px) is resampled to 0.6 m (560 px), the resolution
         CHMv2 was trained on, predicted in one pass, resampled back to 0.5 m
         and cropped to the block, so block edges have context.
Both: ImageNet-style normalisation (0.420, 0.411, 0.296) / (0.213, 0.156, 0.143),
bf16 on GPU. Output is the RAW model height (no calibration).

Layout: blocks are the mosaic's own 512 x 512 px tiles (so every read is
aligned to them), grouped into chunks of 50 x 50 blocks (12.8 km). Each chunk
is written to a local staging folder, copied to the output folder when done,
and recorded in chunks/<chunk>.json. A rerun skips finished chunks.
Reads that fail are retried after 10, 30 and 90 s; a block that still fails
is listed in the chunk's json, and the chunk's file is named
<chunk>.INCOMPLETE.tif so it is redone by the next run.

Output folder (--out): <model>/chunks/*.tif, *.json; <model>/chm_<model>.vrt;
<model>/provenance.json; block_mask_ar5_30m.npy (shared between models).
"""
import argparse, collections, datetime, hashlib, json, os, queue, shutil, subprocess, sys, threading, time
os.environ.setdefault("GDAL_CACHEMAX", "4096")
import warnings
import numpy as np
import rasterio
from rasterio.errors import NotGeoreferencedWarning
from rasterio.features import rasterize
warnings.filterwarnings("ignore", category=NotGeoreferencedWarning)   # rasterize's in-memory raster, harmless
from rasterio.transform import Affine
from rasterio.windows import Window
import shapely
import pyogrio
import torch
import torch.nn.functional as F

BLOCK = 512            # px, = the mosaic's internal tile
RES = 0.5              # m
CHUNK = 50             # blocks per chunk side (12.8 km)
BUFFER_M = 30.0
NODATA = 65535
MEAN = (0.420, 0.411, 0.296)
STD = (0.213, 0.156, 0.143)

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--model", choices=["chmv1", "chmv2"], required=True)
ap.add_argument("--ortho", required=True, help="orthophoto mosaic (8-bit RGB, 0.5 m, EPSG:25833)")
ap.add_argument("--ar5", required=True, help="AR5 mire GeoPackage (layer ar5_myr)")
ap.add_argument("--ar5-layer", default="ar5_myr")
ap.add_argument("--out", required=True, help="output folder (may be on the network drive)")
ap.add_argument("--staging", required=True, help="local folder for chunks being written")
ap.add_argument("--chmv1-dir", default="/chmv1", help="Meta HighResCanopyHeight code + saved_checkpoints")
ap.add_argument("--readers", type=int, default=24)
ap.add_argument("--batch", type=int, default=None, help="blocks per GPU batch (default 16 chmv1, 8 chmv2)")
ap.add_argument("--bbox", type=float, nargs=4, metavar=("XMIN", "YMIN", "XMAX", "YMAX"), help="only blocks in this box (tests)")
ap.add_argument("--max-chunks", type=int, default=0, help="stop after N chunks (tests)")
a = ap.parse_args()
batch_size = a.batch or (16 if a.model == "chmv1" else 8)
MARGIN = 0 if a.model == "chmv1" else 80          # px at 0.5 m on each side (chmv2: 40 m)
out_dir = os.path.join(a.out, a.model); os.makedirs(f"{out_dir}/chunks", exist_ok=True)
stage = os.path.join(a.staging, a.model); os.makedirs(stage, exist_ok=True)
dev = torch.device("cuda")
def log(*m):
    print(datetime.datetime.now().strftime("%H:%M:%S"), *m, flush=True)

# ---- grid -------------------------------------------------------------------------
with rasterio.open(a.ortho) as src:
    T, W, H, CRS = src.transform, src.width, src.height, src.crs
    assert abs(T.a - RES) < 1e-9 and abs(T.e + RES) < 1e-9, T
X0, Y0 = T.c, T.f
NBC, NBR = -(-W // BLOCK), -(-H // BLOCK)
BM = BLOCK * RES  # 256 m
def block_bounds(br, bc):
    x = X0 + bc * BM; y = Y0 - br * BM
    return x, y - BM, x + BM, y

# ---- 1. which blocks: AR5 mire rasterised at 32 m, grown by one cell (>= 30 m) ------
mask_path = os.path.join(a.out, "block_mask_ar5_30m.npy")
if not os.path.exists(mask_path):
    log("rasterising AR5 mire at 32 m to find the blocks (once, a few minutes)...")
    r32 = os.path.join(a.staging, "ar5_mire_32m.tif")
    ny, nx = NBR * 8, NBC * 8
    subprocess.run(["gdal_rasterize", "-q", "-l", a.ar5_layer, "-burn", "1", "-at", "-ot", "Byte", "-a_nodata", "0",
                    "-te", str(X0), str(Y0 - ny * 32), str(X0 + nx * 32), str(Y0), "-ts", str(nx), str(ny),
                    "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES", a.ar5, r32], check=True)
    with rasterio.open(r32) as d:
        m = d.read(1) > 0
    g = m.copy()                                       # grow by one 32 m cell in all 8 directions
    g[1:] |= m[:-1]; g[:-1] |= m[1:]
    g2 = g.copy(); g2[:, 1:] |= g[:, :-1]; g2[:, :-1] |= g[:, 1:]
    blocks = g2.reshape(NBR, 8, NBC, 8).any(axis=(1, 3))
    np.save(os.path.join(a.staging, "block_mask.npy"), blocks)
    shutil.copyfile(os.path.join(a.staging, "block_mask.npy"), mask_path)
    os.remove(r32)
blocks = np.load(mask_path)
log(f"blocks within 30 m of AR5 mire: {blocks.sum():,} of {blocks.size:,}")

# chunk list (only chunks with blocks), optional bbox
todo = []
for cr in range(0, NBR, CHUNK):
    for cc in range(0, NBC, CHUNK):
        sub = np.argwhere(blocks[cr:cr + CHUNK, cc:cc + CHUNK])
        if a.bbox:
            keep = []
            for br, bc in sub + [cr, cc]:
                x0, y0, x1, y1 = block_bounds(br, bc)
                if x1 > a.bbox[0] and x0 < a.bbox[2] and y1 > a.bbox[1] and y0 < a.bbox[3]: keep.append((br, bc))
            sub = np.array(keep).reshape(-1, 2)
        else:
            sub = sub + [cr, cc]
        if len(sub):
            todo.append((cr, cc, [tuple(map(int, b)) for b in sub]))
def chunk_name(cr, cc): return f"r{cr // CHUNK:03d}_c{cc // CHUNK:03d}"
def chunk_done(cr, cc):
    f = f"{out_dir}/chunks/{chunk_name(cr, cc)}.json"
    if not os.path.exists(f): return False
    info = json.load(open(f))      # a chunk done in a --bbox test run is not done for another box / the full run
    return info.get("status") in ("complete", "empty") and info.get("bbox") == a.bbox
n_all = len(todo)
todo = [t for t in todo if not chunk_done(t[0], t[1])]
if a.max_chunks: todo = todo[:a.max_chunks]
n_blocks = sum(len(t[2]) for t in todo)
log(f"chunks: {n_all} with mire, {n_all - len(todo) if not a.max_chunks else 'n/a'} already done, "
    f"{len(todo)} to do ({n_blocks:,} blocks)")
if not todo:
    log("nothing to do")

# ---- 2. AR5 polygons for the 0.5 m mask -----------------------------------------------
if todo:
    bb = a.bbox and (a.bbox[0] - 300, a.bbox[1] - 300, a.bbox[2] + 300, a.bbox[3] + 300)
    log("reading AR5 mire polygons...")
    _, _, wkb, _ = pyogrio.raw.read(a.ar5, layer=a.ar5_layer, columns=[], bbox=bb, read_geometry=True)
    geoms = shapely.from_wkb(wkb); del wkb
    tree = shapely.STRtree(geoms)
    log(f"{len(geoms):,} polygons")

# ---- 3. model -------------------------------------------------------------------------------
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 24), b""): h.update(b)
    return h.hexdigest()
mean_t = torch.tensor(MEAN, device=dev).view(1, 3, 1, 1); std_t = torch.tensor(STD, device=dev).view(1, 3, 1, 1)
if a.model == "chmv1":
    import torch.nn as nn
    sys.path.insert(0, a.chmv1_dir)
    from models.backbone import SSLVisionTransformer
    from models.dpt_head import DPTHead
    class SSLAE(nn.Module):  # Meta's inference.py, huge=True, classify=True
        def __init__(self):
            super().__init__()
            self.backbone = SSLVisionTransformer(embed_dim=1280, num_heads=20, out_indices=(9, 16, 22, 29), depth=32)
            self.decode_head = DPTHead(classify=True, in_channels=(1280,) * 4, embed_dims=1280,
                                       post_process_channels=[160, 320, 640, 1280])
        def forward(self, x):
            return 10 * self.decode_head(self.backbone(x))   # x10 as SSLModule
    ckpt_path = os.path.join(a.chmv1_dir, "saved_checkpoints", "compressed_SSLhuge_aerial.pth")
    ck = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    sd = {}
    for k, v in ck.items():
        if k.endswith("._packed_params._packed_params"):            # int8 nn.Linear -> float
            base = k[: -len("._packed_params._packed_params")]
            sd[base + ".weight"] = v[0].dequantize()
            if v[1] is not None: sd[base + ".bias"] = v[1]
        elif not k.endswith((".scale", ".zero_point", "._packed_params.dtype")):
            sd[k] = v
    net = SSLAE().eval()
    res = net.load_state_dict(sd, strict=False)
    assert res.missing_keys == ["backbone.mask_token"] and not res.unexpected_keys, res
    net = net.to(dev)
    model_id = {"name": "Meta HighResCanopyHeight (CHMv1), aerial checkpoint, int8 layers dequantised",
                "checkpoint": ckpt_path, "checkpoint_sha256": sha256(ckpt_path)}
    def predict(x):                                     # x: (B,3,512,512) in [0,1]
        B = x.shape[0]
        t = x.reshape(B, 3, 2, 256, 2, 256).permute(0, 2, 4, 1, 3, 5).reshape(B * 4, 3, 256, 256)
        y = net((t - mean_t) / std_t).squeeze(1)        # (B*4,256,256)
        return y.reshape(B, 2, 2, 256, 256).permute(0, 1, 3, 2, 4).reshape(B, 512, 512)
else:
    from transformers import CHMv2ForDepthEstimation
    repo = "facebook/dinov3-vitl16-chmv2-dpt-head"
    rev = "37130c851a3cf6720f974490707059f5edaeed4e"   # the model version calibrated in src/chm_comparison
    net = CHMv2ForDepthEstimation.from_pretrained(repo, revision=rev).eval().to(dev)
    model_id = {"name": "CHMv2 (Meta/WRI), DINOv3 ViT-L + DPT head", "hf_repo": repo, "hf_commit": rev}
    def predict(x):                                     # x: (B,3,672,672) in [0,1] at 0.5 m
        x6 = F.interpolate(x, size=(560, 560), mode="bicubic", antialias=True, align_corners=False).clamp(0, 1)
        y = net(pixel_values=(x6 - mean_t) / std_t).predicted_depth          # (B,560,560) metres
        y = F.interpolate(y[:, None].float(), size=(672, 672), mode="bilinear", align_corners=False)[:, 0]
        return y[:, MARGIN:MARGIN + BLOCK, MARGIN:MARGIN + BLOCK]

# ---- 4. readers ---------------------------------------------------------------------------
_tl = threading.local()
def ortho():
    if not hasattr(_tl, "ds"): _tl.ds = rasterio.open(a.ortho)
    return _tl.ds
def retry(fn, what):
    err = None
    for wait in (10, 30, 90, None):
        try:
            return fn(), None
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
            if wait is None: break
            log(f"retry in {wait}s: {what}: {err}")
            if hasattr(_tl, "ds"): del _tl.ds                    # reopen after a network error
            time.sleep(wait)
    return None, err
def read_block(br, bc):
    """-> (image uint8 (n,n,3) with margin, mire mask (512,512) bool, error)"""
    n = BLOCK + 2 * MARGIN
    c0, r0 = bc * BLOCK - MARGIN, br * BLOCK - MARGIN
    def f():
        ds = ortho()
        inside = c0 >= 0 and r0 >= 0 and c0 + n <= W and r0 + n <= H
        img = ds.read([1, 2, 3], window=Window(c0, r0, n, n), boundless=not inside, fill_value=255)
        assert img.shape == (3, n, n), img.shape
        return img
    img, err = retry(f, f"block r{br} c{bc}")
    if img is None: return None, None, err
    x0, y0, x1, y1 = block_bounds(br, bc)
    idx = tree.query(shapely.box(x0 - BUFFER_M, y0 - BUFFER_M, x1 + BUFFER_M, y1 + BUFFER_M))
    if len(idx) == 0:
        return img, np.zeros((BLOCK, BLOCK), bool), None
    clip = shapely.clip_by_rect(geoms[idx], x0 - BUFFER_M - 1, y0 - BUFFER_M - 1, x1 + BUFFER_M + 1, y1 + BUFFER_M + 1)
    buf = shapely.buffer(clip, BUFFER_M, quad_segs=4)
    buf = buf[~shapely.is_empty(buf)]
    mask = rasterize(((g, 1) for g in buf), out_shape=(BLOCK, BLOCK), transform=Affine(RES, 0, x0, 0, -RES, y1),
                     fill=0, dtype="uint8").astype(bool) if len(buf) else np.zeros((BLOCK, BLOCK), bool)
    return img, mask, None

# ---- 5. writer: one chunk file at a time, finalised in order ----------------------------
PROFILE = dict(driver="GTiff", dtype="uint16", count=1, nodata=NODATA, crs=CRS, tiled=True,
               blockxsize=BLOCK, blockysize=BLOCK, compress="ZSTD", predictor=2, zstd_level=9,
               BIGTIFF="IF_SAFER", SPARSE_OK=True, NUM_THREADS=8)
wq = queue.Queue(maxsize=64)
stats = {"blocks": 0, "written": 0, "failed": 0, "chunks": 0, "t_wait": 0.0, "t_gpu": 0.0}
def writer():
    ds, cur, info = None, None, None
    while True:
        item = wq.get()
        if item is None: break
        kind = item[0]
        if kind == "open":
            _, cr, cc, nb = item
            name = chunk_name(cr, cc)
            path = f"{stage}/{name}.tif"
            ds = rasterio.open(path, "w", width=CHUNK * BLOCK, height=CHUNK * BLOCK,
                               transform=Affine(RES, 0, X0 + cc * BM, 0, -RES, Y0 - cr * BM), **PROFILE)
            cur, info = (cr, cc, name, path), {"chunk": name, "bbox": a.bbox, "blocks": nb, "written": 0, "empty": 0, "failed": [], "t0": time.time()}
        elif kind == "block":
            _, br, bc, arr = item
            cr, cc = cur[0], cur[1]
            if arr is None: info["empty"] += 1
            else:
                ds.write(arr, 1, window=Window((bc - cc) * BLOCK, (br - cr) * BLOCK, BLOCK, BLOCK)); info["written"] += 1
        elif kind == "fail":
            info["failed"].append(item[1])
        elif kind == "close":
            ds.close(); ds = None
            cr, cc, name, path = cur
            info["seconds"] = round(time.time() - info.pop("t0"), 1)
            if info["failed"]:
                info["status"] = "incomplete"; dst = f"{out_dir}/chunks/{name}.INCOMPLETE.tif"
            elif info["written"] == 0:
                info["status"] = "empty"; dst = None
            else:
                info["status"] = "complete"; dst = f"{out_dir}/chunks/{name}.tif"
            if dst:
                shutil.copyfile(path, dst + ".part"); os.replace(dst + ".part", dst)
                if info["status"] == "complete" and os.path.exists(f"{out_dir}/chunks/{name}.INCOMPLETE.tif"):
                    os.remove(f"{out_dir}/chunks/{name}.INCOMPLETE.tif")
            os.remove(path)
            with open(f"{out_dir}/chunks/{name}.json", "w") as fh: json.dump(info, fh, indent=1)
            stats["chunks"] += 1; stats["failed"] += len(info["failed"])
        wq.task_done()
wt = threading.Thread(target=writer, daemon=True); wt.start()

# ---- 6. main loop: readers -> GPU batches -> writer ------------------------------------------
from concurrent.futures import ThreadPoolExecutor
prov = {"started": datetime.datetime.now().isoformat(timespec="seconds"), "args": vars(a), "model": model_id,
        "ortho": {"path": a.ortho, "bytes": os.path.getsize(a.ortho)} if os.path.exists(a.ortho) else a.ortho,
        "ar5": {"path": a.ar5, "bytes": os.path.getsize(a.ar5), "mtime": os.path.getmtime(a.ar5)},
        "grid": {"x0": X0, "y0": Y0, "res": RES, "block_px": BLOCK, "chunk_blocks": CHUNK, "margin_px": MARGIN,
                 "buffer_m": BUFFER_M, "units": "cm", "nodata": NODATA},
        "code_commit": os.environ.get("CODE_COMMIT"), "torch": torch.__version__,
        "gpu": torch.cuda.get_device_name(0), "packages": {m: sys.modules[m].__version__ for m in ("numpy", "rasterio", "shapely") if m in sys.modules}}
if a.model == "chmv2":
    import transformers; prov["packages"]["transformers"] = transformers.__version__
json.dump(prov, open(f"{out_dir}/provenance_{prov['started'].replace(':', '')}.json", "w"), indent=1)

def run_batch(items):
    """items: list of (br, bc, img, mask); predict and queue for writing."""
    t0 = time.time()
    x = torch.from_numpy(np.stack([it[2] for it in items])).to(dev).float() / 255   # (B,3,n,n)
    with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16):
        y = predict(x).float().relu()
    cm = torch.round(y * 100).clamp(0, NODATA - 1).to(torch.int32).cpu().numpy().astype(np.uint16)
    for (br, bc, img, mask), arr in zip(items, cm):
        core = img[:, MARGIN:MARGIN + BLOCK, MARGIN:MARGIN + BLOCK]
        nodata = ~mask | (core == 255).all(axis=0)
        arr[nodata] = NODATA
        wq.put(("block", br, bc, arr))
    stats["t_gpu"] += time.time() - t0

t_start, last = time.time(), 0
pool = ThreadPoolExecutor(a.readers)
for ci, (cr, cc, blist) in enumerate(todo):
    wq.put(("open", cr, cc, len(blist)))
    futs = collections.deque(pool.submit(read_block, br, bc) for br, bc in blist)
    pending = []
    for br, bc in blist:
        t0 = time.time(); img, mask, err = futs.popleft().result(); stats["t_wait"] += time.time() - t0
        stats["blocks"] += 1
        if img is None:
            wq.put(("fail", {"block": [br, bc], "error": err})); log(f"FAILED block r{br} c{bc}: {err}"); continue
        if not mask.any():
            wq.put(("block", br, bc, None)); continue
        pending.append((br, bc, img, mask))
        if len(pending) == batch_size:
            run_batch(pending); pending = []
    if pending: run_batch(pending)
    wq.put(("close",))
    if time.time() - last > 60 or ci == len(todo) - 1:
        last = time.time(); el = last - t_start; rate = stats["blocks"] / el
        log(f"chunk {ci + 1}/{len(todo)}: {stats['blocks']:,}/{n_blocks:,} blocks, {rate:.1f} blocks/s, "
            f"ETA {(n_blocks - stats['blocks']) / max(rate, 1e-9) / 3600:.1f} h, failed blocks {stats['failed']} "
            f"(time waiting for reads {stats['t_wait'] / el:.0%}, GPU {stats['t_gpu'] / el:.0%})")
wq.put(None); wt.join(); pool.shutdown()

# ---- 7. VRT over all complete chunks, summary ----------------------------------------------------
def write_vrt(tifs, path):
    """The VRT is written directly: gdalbuildvrt opens every chunk file, which takes
    over an hour for 2,000 files on the network drive. All chunks have the same
    size, type and grid, so each one's place follows from its name (rNNN_cNNN)."""
    n = CHUNK * BLOCK
    src = "".join(
        f'    <SimpleSource><SourceFilename relativeToVRT="1">chunks/{f}</SourceFilename><SourceBand>1</SourceBand>'
        f'<SourceProperties RasterXSize="{n}" RasterYSize="{n}" DataType="UInt16" BlockXSize="{BLOCK}" BlockYSize="{BLOCK}"/>'
        f'<SrcRect xOff="0" yOff="0" xSize="{n}" ySize="{n}"/>'
        f'<DstRect xOff="{int(f[6:9]) * n}" yOff="{int(f[1:4]) * n}" xSize="{n}" ySize="{n}"/></SimpleSource>\n' for f in tifs)
    xml = (f'<VRTDataset rasterXSize="{W}" rasterYSize="{H}">\n  <SRS>{CRS.to_wkt().replace("&", "&amp;").replace("<", "&lt;")}</SRS>\n'
           f'  <GeoTransform>{X0}, {RES}, 0, {Y0}, 0, {-RES}</GeoTransform>\n'
           f'  <VRTRasterBand dataType="UInt16" band="1">\n    <NoDataValue>{NODATA}</NoDataValue>\n{src}  </VRTRasterBand>\n</VRTDataset>\n')
    open(path + ".part", "w").write(xml); os.replace(path + ".part", path)
tifs = sorted(f for f in os.listdir(f"{out_dir}/chunks") if f.endswith(".tif") and "INCOMPLETE" not in f)
if tifs:
    write_vrt(tifs, f"{out_dir}/chm_{a.model}.vrt")
incomplete = [f for f in os.listdir(f"{out_dir}/chunks") if "INCOMPLETE" in f]
missing = [chunk_name(cr, cc) for cr, cc, _ in todo if not chunk_done(cr, cc)]
log(f"done: {stats['blocks']:,} blocks in {(time.time() - t_start) / 3600:.2f} h; VRT over {len(tifs)} chunks: {out_dir}/chm_{a.model}.vrt")
if incomplete or missing:
    log(f"NOT COMPLETE: {len(incomplete)} chunk(s) with failed blocks, {len(missing)} chunk(s) not finished. "
        f"Run the same command again to redo them.")
    sys.exit(2)
