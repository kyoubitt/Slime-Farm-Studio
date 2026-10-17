import numpy as np, csv, sys, os, struct
sys.path.insert(0, '..')
os.chdir(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, '..')
from load import cached, OFF
H = '..'
cols = [-319635, 1791063, -1115453, -133170]
rows = [int(x) for x in open(f'{H}/xscan/rows.txt').read().split()]
A = np.stack([cached(f'{H}/zscan/rows_col{j}.csv', 'cz') for j in range(4)])
B = np.stack([cached(f'{H}/xscan/rows_row{k}.csv', 'cx') for k in range(4)])
norm = sum((A[j, rows[k] + OFF] + B[k, cols[j] + OFF]) / 2 for j in range(4) for k in range(4))
B.sum(0).astype('<f4').tofile('aux_F.bin'); A.sum(0).astype('<f4').tofile('aux_G.bin')
open('aux_norm.txt', 'w').write(f'{norm:.6f}\n')
AR = '../../../archive/heat_v1_2026-09-21/heat/'
xr = np.zeros(2 * OFF + 1, dtype='<i4')
for i, r in enumerate(csv.DictReader(open(AR + 'x_world.csv'))): xr[int(r['cx']) + OFF] = i + 1
xr.tofile('aux_xrank.bin')
LOFF = 20000
lr = np.zeros(2 * LOFF + 1, dtype='<i4')
for r in csv.DictReader(open(AR + 'line_world_ranked.csv')): lr[int(r['line_n']) + LOFF] = int(r['rank'])
lr.tofile('aux_lrank.bin')
old = []
with open(AR + 'spot_measured.csv') as f:
    next(f)
    for line in f:
        a, b, _ = line.split(',', 2); old.append(((int(a) + OFF) << 32) | (int(b) + OFF))
np.array(sorted(set(old)), dtype='<u8').tofile('aux_old.bin')
P = '../../../theory/'
screen, search = {}, {}
def key(X, Z): return ((int(X) // 16 + OFF) << 32) | (int(Z) // 16 + OFF)
for f, col in [('prediction/universe_screened.csv', 'best'), ('prediction/universe_sample.csv', 'best'), ('prediction/floor_sample.csv', 'best'),
               ('prediction/rescreened.csv', 'best'), ('prediction/screened.csv', 'best2048')]:
    if not os.path.exists(P + f): continue
    for r in csv.DictReader(open(P + f)):
        try: k = key(r['X'], r['Z']); v = int(float(r[col]))
        except (ValueError, KeyError, TypeError): continue
        screen[k] = max(screen.get(k, -1), v)
for f in ['heat/phase_search.csv', 'heat/best_family.csv']:
    for r in csv.DictReader(open(P + f)):
        try: k = key(r['X'], r['Z'])
        except (ValueError, KeyError, TypeError): continue
        try: v = float(r['SpotBest'] or 0)
        except ValueError: v = 0.0
        search[k] = max(search.get(k, 0.0), v)
ks = np.array(sorted(screen), dtype='<u8'); ks.tofile('aux_screen_k.bin'); np.array([screen[k] for k in ks], dtype='<i4').tofile('aux_screen_v.bin')
ks = np.array(sorted(search), dtype='<u8'); ks.tofile('aux_search_k.bin'); np.array([search[k] for k in ks], dtype='<f4').tofile('aux_search_v.bin')
print(f'norm {norm:.3f}  old spots {len(set(old)):,}  screened {len(screen):,}  searched {len(search):,}')
