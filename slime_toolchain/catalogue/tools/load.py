import numpy as np, csv, os
OFF = 1874999; NN = 2 * OFF + 1
D = os.path.dirname(os.path.abspath(__file__))
def load(path, key):
    a = np.full(NN, np.nan, dtype=np.float32)
    with open(path) as f:
        next(f)
        k = 0 if key == 'cx' else 1
        for line in f:
            p = line.split(',', 3)
            a[int(p[k]) + OFF] = float(p[2])
    return a
def cached(path, key):
    npy = path[:-4] + '.npy'
    if os.path.exists(npy) and os.path.getmtime(npy) > os.path.getmtime(path): return np.load(npy)
    a = load(path, key); np.save(npy, a); return a
