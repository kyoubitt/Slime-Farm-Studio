import numpy as np, sys, json
sys.path.insert(0, '.')
from load import cached, OFF
cols = [-319635, 1791063, -1115453, -133170]
rows = [int(x) for x in open('xscan/rows.txt').read().split()]
A = np.stack([cached(f'zscan/rows_col{j}.csv', 'cz') for j in range(4)])
B = np.stack([cached(f'xscan/rows_row{k}.csv', 'cx') for k in range(4)])
X = np.array([[(A[j, rows[k] + OFF] + B[k, cols[j] + OFF]) / 2 for k in range(4)] for j in range(4)])
print("cross heat h(C_j, R_k), two independent reads:")
for j in range(4): print("  ", [f"{A[j, rows[k] + OFF]:.1f}/{B[k, cols[j] + OFF]:.1f}" for k in range(4)])
G = A.sum(0); F = B.sum(0); norm = X.sum()
fit = np.outer(G[[r + OFF for r in rows]], F[[c + OFF for c in cols]]).T / norm
print("separable fit of the cross (pred / measured):"); print(np.round(fit / X, 2))
Fs = np.sort(F)
print(f"F: columns {len(F)}, G: rows {len(G)}, norm {norm:.1f}")
for c in (3, 4, 5, 6, 6.5, 8, 10, 12, 13, 16, 20, 22):
    need = c * norm / np.maximum(G, 1e-9)
    n = (len(Fs) - np.searchsorted(Fs, need)).sum()
    print(f"  pairs predicted >= {c:5.1f}: {n:15,d}")
