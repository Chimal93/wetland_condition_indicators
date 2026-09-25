# ============================================================
# Run Meta's HighResCanopyHeight model over a directory of real 256x256
# RGB orthophoto tiles and write one predicted canopy-height raster per
# tile (float32, metres).
#
# This is the "custom wrapper" CHM_MODEL_SETUP.md says is required:
# the repo's own inference.py is a benchmark harness hardcoded to Meta's
# NEON validation dataset (it needs ./data/neon_test_data.csv and paired
# ground-truth images, and reports MAE/RMSE/R2), NOT a run-on-any-image
# tool. This script reuses the same SSLModule/RNet classes inference.py
# uses internally, but feeds them real tiles cut by
# NO_GJEN_002/R/orthophoto_source.R.
#
# NORMALISATION - WHICH BRANCH APPLIES DEPENDS ON THE CHECKPOINT, and
# getting this wrong costs accuracy silently (measured, see below):
#
#   1. Maxar quantile colour-matching (inference.py's NeonDataset,
#      `new_norm` branch). RNet predicts Maxar-equivalent 5th/95th
#      percentiles per band (6 outputs = p5 x3, p95 x3) and each band is
#      linearly rescaled onto them. This exists because the BASE model
#      was trained on Maxar SATELLITE imagery, so aerial input has to be
#      stretched to resemble it. **It must be SKIPPED for the
#      aerial-finetuned checkpoints.** inference.py encodes exactly this
#      as `--trained_rgb` ("True if model was finetuned on aerial data"),
#      which gates the whole block via `if not self.trained_rgb:`.
#   2. The fixed ImageNet-style normalisation applied at inference time:
#      Normalize((0.420, 0.411, 0.296), (0.213, 0.156, 0.143)).
#      This ALWAYS applies, both branches.
#
# MEASURED on the 46 wetland test polygons, scored against airborne LiDAR
# with `compressed_SSLhuge_aerial.pth` (2026-09-04) - applying stage 1 to
# this aerial checkpoint actively degrades it:
#     stage 1 ON : r=0.879 all / 0.731 vegetated, slope 0.564, MAE 0.38
#     stage 1 OFF: r=0.952 all / 0.894 vegetated, slope 0.833, MAE 0.31
# Hence stage 1 now defaults OFF whenever the checkpoint name contains
# "aerial", rather than depending on a flag being remembered.
#
# Output scaling is likewise inference.py's, not ours: SSLModule wraps
# the network as `10 * model(x)` (metres), and predictions are passed
# through relu() so negative heights clamp to 0 - matching how the
# original treats ground truth (`chm[chm<0] = 0`).
#
# Deliberately depends on nothing beyond the pinned environment
# CHM_MODEL_SETUP.md documents (torch/torchvision/numpy/PIL) - notably
# NOT rasterio/GDAL, which would risk that environment's documented,
# fragile `numpy<2` pin. Tiles are read with PIL exactly as Meta's own
# code does; the R side owns all georeferencing, since it cut the tiles
# and already knows their extent/CRS.
#
# OUTPUT CONTRACT - raw .bin, NOT an image format. Each prediction is
# written as a headerless little-endian float32 array, C order
# (row-major), FIRST ROW = NORTHERNMOST, matching how PIL/numpy hold the
# input tile. Reconstruct in R with:
#     v <- readBin(f, "double", size = 4, n = nrow*ncol, endian = "little")
#     m <- matrix(v, nrow = nrow, ncol = ncol, byrow = TRUE)   # row 1 = top
#
# WHY NOT A TIFF (this cost a real wrong answer once - 2026-09-03):
# writing predictions as a plain TIFF via PIL produced a file with no
# geotransform, and terra/GDAL then read its rows BOTTOM-UP - an exact
# vertical mirror. Confirmed by round-trip test: PIL and terra agree
# perfectly on a GEOREFERENCED tile (row means 69.68 / 68.54 both ways),
# but disagree, exactly mirrored, on the ungeoreferenced copy. Nothing
# errored; the zonal median just silently sampled mirror-image ground
# and read 0.04 m where LiDAR said 3.85 m. Row order in a TIFF with no
# geotransform is implementation-defined, so it must not be relied on -
# hence an explicit, documented byte layout instead.
#
# Run via the base interpreter + PYTHONPATH rather than the venv's own
# python.exe - see CHM_MODEL_SETUP.md (the venv launcher shim is blocked
# by this machine's Windows Application Control policy; the interpreter
# and packages themselves are fine).
# ============================================================

import argparse
import glob
import os
import sys
import time

import numpy as np
import torch
import torchvision.transforms as T
import torchvision.transforms.functional as TF
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "HighResCanopyHeight-main")

# Meta's model code and checkpoint paths are relative to the repo root,
# so import from there and run there - but resolve every user-supplied
# path to absolute FIRST, so chdir can't silently relocate the outputs.
sys.path.insert(0, REPO)

from inference import SSLModule  # noqa: E402
from models.regressor import RNet  # noqa: E402

# inference.py's own values - do not "tidy" these numbers.
IMAGENET_NORM = T.Normalize((0.420, 0.411, 0.296), (0.213, 0.156, 0.143))
TILE_SIZE = 256


def load_models(checkpoint, normnet):
    """Load RNet (quantile predictor) + SSLModule (canopy height), CPU."""
    ckpt = torch.load(normnet, map_location="cpu")
    state_dict = ckpt["state_dict"]
    # Same key-renaming inference.py does when loading this checkpoint.
    for k in list(state_dict.keys()):
        if "backbone." in k:
            state_dict[k.replace("backbone.", "")] = state_dict.pop(k)
    model_norm = RNet(n_classes=6).eval()
    model_norm.load_state_dict(state_dict)

    model = SSLModule(ssl_path=checkpoint).eval()
    return model, model_norm


def match_to_maxar_quantiles(img, model_norm):
    """Stage 1: inference.py's `new_norm` aerial branch (normtype=2).

    img: float tensor (3, H, W) in [0, 1], as produced by TF.to_tensor().
    Returns a tensor of the same shape, colour-matched to the Maxar
    quantiles RNet predicts for this image.
    """
    with torch.no_grad():
        predicted = model_norm(img.unsqueeze(0)).detach()
    p5_target = [predicted[0][i].item() for i in range(3)]
    p95_target = [predicted[0][i + 3].item() for i in range(3)]

    out = img.clone()
    for i in range(3):
        band = img[i, :, :].numpy().flatten()
        p5_in = np.percentile(band, 5)
        p95_in = np.percentile(band, 95)
        spread_in = p95_in - p5_in
        if spread_in <= 0:
            # A flat band (e.g. a blank/constant tile) would divide by
            # zero. Leave it untouched rather than exploding it - such a
            # tile carries no signal anyway.
            continue
        scale = (p95_target[i] - p5_target[i]) / spread_in
        out[i, :, :] = (img[i, :, :] - p5_in) * scale + p5_target[i]
    return out


def predict_tile(path, model, model_norm, skip_norm=False):
    """One tile -> (256, 256) float32 array of canopy height in metres."""
    with Image.open(path) as im:
        img = TF.to_tensor(im.convert("RGB"))  # (3, H, W), uint8 -> [0,1]

    if img.shape[1] != TILE_SIZE or img.shape[2] != TILE_SIZE:
        raise ValueError(
            "%s is %dx%d, expected %dx%d - the model's input size is fixed."
            % (os.path.basename(path), img.shape[1], img.shape[2], TILE_SIZE, TILE_SIZE)
        )

    normed = img if skip_norm else match_to_maxar_quantiles(img, model_norm)
    with torch.no_grad():
        pred = model(IMAGENET_NORM(normed).unsqueeze(0))
    # SSLModule already applies the x10 metre scaling internally.
    return pred.cpu().detach().relu().squeeze().numpy().astype(np.float32)


def main():
    ap = argparse.ArgumentParser(
        description="Predict canopy height for a directory of 256x256 RGB orthophoto tiles."
    )
    ap.add_argument("--input-dir", required=True, help="directory of .tif RGB tiles")
    ap.add_argument("--output-dir", required=True, help="where to write predicted height .tif files")
    ap.add_argument("--checkpoint", default="saved_checkpoints/compressed_SSLhuge_aerial.pth")
    ap.add_argument("--normnet", default="saved_checkpoints/aerial_normalization_quantiles_predictor.ckpt")
    ap.add_argument("--stats-csv", default=None, help="optional per-tile summary CSV")
    ap.add_argument("--skip-norm", action="store_true",
                    help="Force the Maxar quantile matching OFF (inference.py's --trained_rgb / "
                         "normtype=0). Already the default for 'aerial' checkpoints.")
    ap.add_argument("--force-norm", action="store_true",
                    help="Force the Maxar quantile matching ON even for an aerial checkpoint. "
                         "Measured to degrade accuracy there - diagnostic/comparison use only.")
    ap.add_argument("--skip-existing", action="store_true",
                    help="Resumability: skip any tile whose .bin output already exists. Makes an "
                         "interrupted run cheap to restart - it picks up where it stopped.")
    args = ap.parse_args()

    in_dir = os.path.abspath(args.input_dir)
    out_dir = os.path.abspath(args.output_dir)
    stats_csv = os.path.abspath(args.stats_csv) if args.stats_csv else None
    os.makedirs(out_dir, exist_ok=True)

    tiles = sorted(glob.glob(os.path.join(in_dir, "*.tif")))
    if not tiles:
        sys.exit("No .tif tiles found in %s" % in_dir)

    def out_bin(tp):
        return os.path.join(out_dir, os.path.splitext(os.path.basename(tp))[0] + ".bin")

    # Resumability. A .bin is only written after a tile is fully predicted,
    # so its presence is a safe "already done" marker. Existing per-tile
    # stats are carried forward so the stats CSV stays complete across a
    # resumed run rather than describing only the newly-done tiles.
    carried = []
    if args.skip_existing:
        before = len(tiles)
        prior = {}
        if stats_csv and os.path.exists(stats_csv):
            with open(stats_csv) as fh:
                next(fh, None)
                for line in fh:
                    parts = line.rstrip("\n").split(",")
                    if len(parts) == 7:
                        prior[parts[0]] = parts
        keep = []
        for tp in tiles:
            if os.path.exists(out_bin(tp)):
                row = prior.get(os.path.basename(tp))
                if row:
                    carried.append(tuple([row[0], int(row[1]), int(row[2])] +
                                         [float(x) for x in row[3:7]]))
            else:
                keep.append(tp)
        tiles = keep
        print("Resuming: %d of %d tile(s) already done, %d to run."
              % (before - len(tiles), before, len(tiles)), flush=True)
        if not tiles:
            print("Nothing left to predict.")
            # Always (re)write the stats file when one was requested, even
            # with nothing to do. The R caller reads it unconditionally
            # after this process returns, so returning without writing it
            # would crash a resumed run rather than continuing it.
            if stats_csv:
                with open(stats_csv, "w") as fh:
                    fh.write("tile,nrow,ncol,mean_m,median_m,min_m,max_m\n")
                    for r in carried:
                        fh.write("%s,%d,%d,%.4f,%.4f,%.4f,%.4f\n" % r)
            return

    # The aerial-finetuned checkpoints must NOT get the Maxar quantile
    # matching - that step exists to make aerial imagery resemble the
    # satellite imagery the BASE model was trained on, and applying it to
    # an already-aerial-finetuned model measurably degrades accuracy.
    # Equivalent to inference.py's --trained_rgb.
    is_aerial_ckpt = "aerial" in os.path.basename(args.checkpoint).lower()
    skip_norm = (is_aerial_ckpt or args.skip_norm) and not args.force_norm

    os.chdir(REPO)  # only now - all paths above are already absolute
    print("Loading models (CPU)...", flush=True)
    t0 = time.time()
    model, model_norm = load_models(args.checkpoint, args.normnet)
    print("  models loaded in %.1f s" % (time.time() - t0), flush=True)
    print("  Maxar quantile matching: %s%s" % (
        "OFF" if skip_norm else "ON",
        " (aerial checkpoint detected)" if is_aerial_ckpt and not args.force_norm else ""), flush=True)
    if args.force_norm and is_aerial_ckpt:
        print("  WARNING: --force-norm on an aerial checkpoint - measured to reduce accuracy.", flush=True)

    rows = list(carried)
    t_start = time.time()
    for n, tp in enumerate(tiles, 1):
        t1 = time.time()
        arr = predict_tile(tp, model, model_norm, skip_norm=skip_norm)
        out_path = os.path.join(out_dir, os.path.splitext(os.path.basename(tp))[0] + ".bin")
        # Explicit byte layout - see OUTPUT CONTRACT in the header. Row 0
        # is northernmost; R reads this back with byrow=TRUE.
        arr.astype("<f4").tofile(out_path)
        rows.append((os.path.basename(tp), arr.shape[0], arr.shape[1],
                     float(arr.mean()), float(np.median(arr)),
                     float(arr.min()), float(arr.max())))
        print("  [%d/%d] %-32s mean=%6.2f m  median=%6.2f m  max=%6.2f m  (%.1f s)"
              % (n, len(tiles), os.path.basename(tp), rows[-1][3], rows[-1][4],
                 rows[-1][6], time.time() - t1), flush=True)

    print("\nDone: %d tile(s) in %.1f s -> %s" % (len(tiles), time.time() - t_start, out_dir))

    if stats_csv:
        with open(stats_csv, "w") as fh:
            fh.write("tile,nrow,ncol,mean_m,median_m,min_m,max_m\n")
            for r in rows:
                fh.write("%s,%d,%d,%.4f,%.4f,%.4f,%.4f\n" % r)
        print("Per-tile stats -> %s" % stats_csv)


if __name__ == "__main__":
    main()
