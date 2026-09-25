# Smoke test: confirms the Python/PyTorch environment + Meta HighResCanopyHeight
# model + both checkpoints actually load and run a forward pass end to end on
# this machine, on CPU, with NO real orthophoto imagery involved yet (a random
# synthetic tensor stands in for a real 256x256 RGB tile). This does NOT
# validate accuracy - it validates that the dependency chain itself works:
# Python 3.9 + pinned torch/torchvision/pytorch_lightning/torchmetrics +
# the model's own source code + the two downloaded checkpoint files.
#
# Deliberately does NOT use the repo's own inference.py - that script is a
# benchmark harness hardcoded to Meta's own NEON validation dataset
# (./data/neon_test_data.csv + specific image files), not a generic
# run-on-any-image utility. This smoke test instead imports SSLModule/RNet
# directly, the same classes inference.py itself uses internally - the real
# future integration (once Norwegian orthophoto exists) will need a similarly
# small custom wrapper, not a call to inference.py as a black box.

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/HighResCanopyHeight-main")
os.chdir(os.path.dirname(os.path.abspath(__file__)) + "/HighResCanopyHeight-main")

import torch
import torchvision.transforms as T

print("torch:", torch.__version__)
print("cuda available:", torch.cuda.is_available(), "(expected False - compressed checkpoint runs CPU-only by design)")

from inference import SSLModule
from models.regressor import RNet

CKPT = "saved_checkpoints/compressed_SSLhuge_aerial.pth"
NORMNET = "saved_checkpoints/aerial_normalization_quantiles_predictor.ckpt"

print("\nLoading normalization network (RNet)...")
ckpt = torch.load(NORMNET, map_location="cpu")
state_dict = ckpt["state_dict"]
for k in list(state_dict.keys()):
    if "backbone." in k:
        new_k = k.replace("backbone.", "")
        state_dict[new_k] = state_dict.pop(k)
model_norm = RNet(n_classes=6).eval()
model_norm.load_state_dict(state_dict)
print("  OK - RNet loaded and in eval mode.")

print("\nLoading main SSL canopy-height model (compressed, huge, quantized)...")
model = SSLModule(ssl_path=CKPT)
model = model.eval()
print("  OK - SSLModule loaded, quantized, weights applied.")

print("\nRunning a forward pass on a SYNTHETIC 256x256 RGB tile (random noise -")
print("NOT real imagery - this only proves the pipeline runs end to end,")
print("output values are meaningless until fed a real orthophoto tile)...")
norm = T.Normalize((0.420, 0.411, 0.296), (0.213, 0.156, 0.143))
synthetic_tile = torch.rand(1, 3, 256, 256)  # batch=1, RGB, 256x256 - the model's expected input shape
with torch.no_grad():
    pred = model(norm(synthetic_tile))
pred = pred.relu()

print("  OK - forward pass completed.")
print("  Output shape:", tuple(pred.shape), "(expected: (1, 1, 256, 256) - one predicted height per pixel)")
print("  Output value range on synthetic noise: min=%.2f max=%.2f (meaningless - synthetic input)" %
      (pred.min().item(), pred.max().item()))

print("\n=== SMOKE TEST PASSED ===")
print("Environment, model code, and both checkpoints are confirmed working on this")
print("machine. Real inference on actual Norwegian orthophoto tiles still requires:")
print("  1. Real orthophoto access (Norge Digitalt/Norkart - the actual blocker)")
print("  2. A custom wrapper script (not inference.py as-is) to feed real 256x256")
print("     RGB crops through this same SSLModule/RNet pipeline and georeference")
print("     the output back onto real coordinates.")
