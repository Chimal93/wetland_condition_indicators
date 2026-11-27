"""Shared by the model scripts: where outputs go, and what is kept per prediction.

Every model returns its prediction on the 0.5 m grid of the input window,
cropped to the central 256 x 256 px (128 m). The 20 m cell is then exactly
the central 40 x 40 px. Kept per point: the cell mean and median. Kept for
the example points only: the full 256 x 256 map (float16)."""
import os
import numpy as np
import pandas as pd

OUT = os.environ.get("OUT", "out")
CELL = slice(108, 148)


def example_mask():
    return pd.read_csv(f"{OUT}/points.csv", usecols=["example"])["example"].to_numpy()


def save(tag, idx, preds, is_example):
    """idx: point indices; preds: (len(idx), 256, 256) float array; is_example: bool per point."""
    cell = preds[:, CELL, CELL].reshape(len(idx), -1).astype("float32")
    ex = is_example[idx]
    np.savez(f"{OUT}/pred_{tag}.npz", idx=idx, mean=cell.mean(1), median=np.median(cell, 1),
             ex_idx=idx[ex], ex_maps=preds[ex].astype(np.float16))
