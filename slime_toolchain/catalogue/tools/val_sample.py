import numpy as np, sys
sys.path.insert(0, '.')
from load import cached, OFF
per = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
cols = [-319635, 1791063, -1115453, -133170]
rows = [int(x) for x in open('xscan/rows.txt').read().split()]
A = np.stack([cached(f'zscan/rows_col{j}.csv', 'cz') for j in range(4)])
B = np.stack([cached(f'xscan/rows_row{k}.csv', 'cx') for k in range(4)])
norm = sum((A[j, rows[k] + OFF] + B[k, cols[j] + OFF]) / 2 for j in range(4) for k in range(4))
G = A.sum(0); F = B.sum(0)
ordF = np.argsort(F); Fs = F[ordF]
rng = np.random.default_rng(12345)
bins = [(0.5, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 7), (7, 8), (8, 10), (10, 12), (12, 99)]
out = open('val/pairs.txt', 'w'); meta = open('val/pairs_meta.csv', 'w'); meta.write('cx,cz,pred,bin,bin_pairs\n')
for lo, hi in bins:
    a = np.searchsorted(Fs, lo * norm / np.maximum(G, 1e-9)); b = np.searchsorted(Fs, hi * norm / np.maximum(G, 1e-9))
    cnt = (b - a).astype(np.float64); tot = cnt.sum()
    rz = rng.choice(len(G), size=per, p=cnt / tot)
    ix = a[rz] + (rng.random(per) * cnt[rz]).astype(np.int64)
    cx = ordF[ix] - OFF; cz = rz - OFF
    pred = F[ordF[ix]] * G[rz] / norm
    for x, z, p in zip(cx, cz, pred):
        out.write(f"{x},{z}\n"); meta.write(f"{x},{z},{p:.3f},{lo}-{hi},{int(tot)}\n")
    print(f"bin {lo}-{hi}: {int(tot):,} pairs, sampled {per}")
gt = np.nonzero(G >= np.quantile(G, 0.99))[0]; ft = np.nonzero(F >= np.quantile(F, 0.99))[0]
for name, zs, xs, tot in [('hotrow-anycol', rng.choice(gt, per), rng.integers(0, len(F), per), len(gt) * len(F)),
                          ('hotcol-anyrow', rng.integers(0, len(G), per), rng.choice(ft, per), len(ft) * len(G)),
                          ('anywhere', rng.integers(0, len(G), per), rng.integers(0, len(F), per), len(G) * len(F))]:
    for z, x in zip(zs, xs):
        out.write(f"{x - OFF},{z - OFF}\n"); meta.write(f"{x - OFF},{z - OFF},{F[x] * G[z] / norm:.3f},{name},{tot}\n")
    print(f"{name}: {tot:,} pairs, sampled {per}")
