import numpy as np, sys, struct
sys.path.insert(0, '.')
from load import cached, OFF
lo = float(sys.argv[1]); hi = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] != 'inf' else np.inf
out = sys.argv[3] if len(sys.argv) > 3 else f'catalog/band_{lo:g}_{hi:g}.plan'
cols = [-319635, 1791063, -1115453, -133170]
rows = [int(x) for x in open('xscan/rows.txt').read().split()]
A = np.stack([cached(f'zscan/rows_col{j}.csv', 'cz') for j in range(4)])
B = np.stack([cached(f'xscan/rows_row{k}.csv', 'cx') for k in range(4)])
norm = sum((A[j, rows[k] + OFF] + B[k, cols[j] + OFF]) / 2 for j in range(4) for k in range(4))
G = A.sum(0); F = B.sum(0)
ordF = np.argsort(-F, kind='stable'); negF = -F[ordF]
Gs = np.maximum(G, 1e-9)
to = np.searchsorted(negF, -lo * norm / Gs, side='right')
fr = np.zeros_like(to) if hi == np.inf else np.searchsorted(negF, -hi * norm / Gs, side='right')
keep = np.nonzero(to > fr)[0]
keep = keep[np.argsort(-G[keep], kind='stable')]
with open(out, 'wb') as f:
    f.write(struct.pack('<i', len(ordF))); f.write((ordF - OFF).astype('<i4').tobytes())
    f.write(struct.pack('<i', len(keep)))
    f.write(np.stack([(keep - OFF).astype('<i4'), fr[keep].astype('<i4'), to[keep].astype('<i4')], 1).tobytes())
print(f"band pred [{lo}, {hi}): {len(keep):,} rows, {int((to - fr)[keep].sum()):,} pairs -> {out}")
