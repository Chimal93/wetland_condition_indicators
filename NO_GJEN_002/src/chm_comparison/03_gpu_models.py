"""GPU models for the comparison. Every prediction is brought back to the
0.5 m grid of the input window and cropped to its central 256 x 256 px
(128 m), so the 20 m cell is always the central 40 x 40 px (see cmp_common).

  chmv1_gpu     CHMv1 aerial checkpoint, int8 Linear layers converted back to
                float, bf16; central 256 px at 0.5 m (as the published run).
  chmv1_gpu_06  the same model on the window resampled to 0.6 m (256 px
                = 154 m), the resolution of the Maxar imagery it was built for.
  chmv2_05      CHMv2, central 448 px at 0.5 m (imagery as is).
  chmv2_06      CHMv2, full 576 px window resampled to 480 px = 0.6 m, the
                resolution CHMv2 was trained on.
Resampling to 0.6 m: bicubic with antialiasing (as CHMv2's own processor);
back to 0.5 m: bilinear. Both keep the window centre fixed (align_corners=False).

usage: python 03_gpu_models.py <model> [--fp32] [--batch N]
Writes $OUT/pred_<model>.npz and $OUT/timing_<model>.txt.
"""
import argparse, sys, time
import numpy as np, torch, torch.nn.functional as F
from cmp_common import OUT, CELL, example_mask

ap = argparse.ArgumentParser()
ap.add_argument("model", choices=["chmv1_gpu", "chmv1_gpu_06", "chmv2_05", "chmv2_06"])
ap.add_argument("--fp32", action="store_true"); ap.add_argument("--batch", type=int, default=8)
a = ap.parse_args()
dev = torch.device("cuda")
tiles = np.load(f"{OUT}/tiles_576.npy", mmap_mode="r")
is_ex = example_mask()
MEAN = torch.tensor((0.420, 0.411, 0.296), device=dev).view(1, 3, 1, 1)   # identical for CHMv1 and CHMv2
STD = torch.tensor((0.213, 0.156, 0.143), device=dev).view(1, 3, 1, 1)


def load_chmv1():
    import torch.nn as nn
    sys.path.insert(0, "/chmv1")
    from models.backbone import SSLVisionTransformer
    from models.dpt_head import DPTHead
    class SSLAE(nn.Module):  # inference.py, huge=True, classify=True
        def __init__(self):
            super().__init__()
            self.backbone = SSLVisionTransformer(embed_dim=1280, num_heads=20, out_indices=(9, 16, 22, 29), depth=32)
            self.decode_head = DPTHead(classify=True, in_channels=(1280,) * 4, embed_dims=1280,
                                       post_process_channels=[160, 320, 640, 1280])
        def forward(self, x):
            return 10 * self.decode_head(self.backbone(x))   # x10 as SSLModule
    ck = torch.load("/chmv1/saved_checkpoints/compressed_SSLhuge_aerial.pth", map_location="cpu", weights_only=False)
    sd = {}
    for k, v in ck.items():
        if k.endswith("._packed_params._packed_params"):
            base = k[: -len("._packed_params._packed_params")]
            sd[base + ".weight"] = v[0].dequantize()
            if v[1] is not None: sd[base + ".bias"] = v[1]
        elif not k.endswith((".scale", ".zero_point", "._packed_params.dtype")):
            sd[k] = v
    m = SSLAE().eval(); m.load_state_dict(sd, strict=False)   # only backbone.mask_token missing (unused)
    m = m.to(dev)
    return lambda x: m((x - MEAN) / STD).squeeze(1)


def load_chmv2():
    from transformers import CHMv2ForDepthEstimation
    m = CHMv2ForDepthEstimation.from_pretrained("facebook/dinov3-vitl16-chmv2-dpt-head",
                                                revision="37130c851a3cf6720f974490707059f5edaeed4e").eval().to(dev)   # pinned
    def run(x):
        y = m(pixel_values=(x - MEAN) / STD).predicted_depth            # metres, same size as input
        assert y.shape[-2:] == x.shape[-2:], (y.shape, x.shape)
        return y
    return run


to06 = lambda x: F.interpolate(x, size=(480, 480), mode="bicubic", antialias=True, align_corners=False).clamp(0, 1)
to05 = lambda y: F.interpolate(y[:, None].float(), size=(576, 576), mode="bilinear", align_corners=False)[:, 0]

if a.model == "chmv1_gpu":
    net = load_chmv1()
    predict = lambda x: net(x[:, :, 160:416, 160:416])
elif a.model == "chmv1_gpu_06":
    net = load_chmv1()
    def predict(x):
        y = torch.zeros(x.shape[0], 480, 480, device=dev)
        y[:, 112:368, 112:368] = net(to06(x)[:, :, 112:368, 112:368]).float()
        return to05(y)[:, 160:416, 160:416]        # the 0.5 m crop lies inside the predicted area
elif a.model == "chmv2_05":
    net = load_chmv2()
    predict = lambda x: net(x[:, :, 64:512, 64:512])[:, 96:352, 96:352]
else:
    net = load_chmv2()
    predict = lambda x: to05(net(to06(x)))[:, 160:416, 160:416]

n = len(tiles); mean = np.zeros(n, np.float32); median = np.zeros(n, np.float32); ex_maps = {}
def batch(i):
    return torch.from_numpy(np.ascontiguousarray(tiles[i:i + a.batch])).to(dev).permute(0, 3, 1, 2).float() / 255
with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16, enabled=not a.fp32):
    predict(batch(0)); torch.cuda.synchronize()                  # warm-up
    t = time.time()
    for i in range(0, n, a.batch):
        y = predict(batch(i)).float().relu()
        cell = y[:, CELL, CELL].reshape(y.shape[0], -1)
        mean[i:i + a.batch] = cell.mean(1).cpu().numpy()
        median[i:i + a.batch] = cell.float().quantile(0.5, dim=1).cpu().numpy()
        for k in np.where(is_ex[i:i + a.batch])[0]:
            ex_maps[i + k] = y[k].cpu().numpy().astype(np.float16)
    torch.cuda.synchronize(); dt = time.time() - t
ex_idx = np.array(sorted(ex_maps), dtype=int)
np.savez(f"{OUT}/pred_{a.model}.npz", idx=np.arange(n), mean=mean, median=median,
         ex_idx=ex_idx, ex_maps=np.stack([ex_maps[i] for i in ex_idx]))
msg = (f"{a.model}: {n} tiles, {dt:.1f} s, {n / dt:.1f} tiles/s (batch {a.batch}, "
       f"{'fp32' if a.fp32 else 'bf16'}, reading from local disk), peak GPU memory "
       f"{torch.cuda.max_memory_allocated() / 1e9:.1f} GB, {torch.cuda.get_device_name(0)}")
print(msg); open(f"{OUT}/timing_{a.model}.txt", "w").write(msg + "\n")
