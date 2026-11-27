"""CHMv1 aerial, published path: int8 compressed_SSLhuge_aerial.pth, torch 2.0.1,
CPU, batch 1, ImageNet-style normalisation, no Maxar matching (= predict_tiles.py),
central 256 x 256 px (128 m) at 0.5 m. Runs one shard; 02_chmv1_cpu.sh starts
12 shards x 2 threads. Output: $OUT/pred_chmv1_cpu_<shard>.npz"""
import sys, time, numpy as np, torch
from cmp_common import OUT, example_mask, save
shard, nshard = int(sys.argv[1]), int(sys.argv[2])
sys.path.insert(0, "/chmv1")
from inference import SSLModule
torch.set_num_threads(2)
model = SSLModule(ssl_path="/chmv1/saved_checkpoints/compressed_SSLhuge_aerial.pth").eval()
tiles = np.load(f"{OUT}/tiles_576.npy", mmap_mode="r")
idx = np.array_split(np.arange(len(tiles)), nshard)[shard]
MEAN = torch.tensor((0.420, 0.411, 0.296)).view(1, 3, 1, 1); STD = torch.tensor((0.213, 0.156, 0.143)).view(1, 3, 1, 1)
out = np.zeros((len(idx), 256, 256), np.float32); t = time.time()
with torch.no_grad():
    for k, i in enumerate(idx):
        x = torch.from_numpy(np.ascontiguousarray(tiles[i, 160:416, 160:416])).permute(2, 0, 1)[None].float() / 255
        out[k] = model((x - MEAN) / STD).relu().squeeze().numpy()
        if k % 200 == 0: print(f"shard {shard}: {k}/{len(idx)} ({time.time() - t:.0f}s)", flush=True)
save(f"chmv1_cpu_{shard:02d}", idx, out, example_mask())
print(f"shard {shard}: {len(idx)} tiles in {time.time() - t:.0f}s", flush=True)
