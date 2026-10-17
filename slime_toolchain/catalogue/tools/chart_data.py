import csv, json, collections, sys, math
sys.path.insert(0, '.')
AR = '../../archive/heat_v1_2026-09-21/heat/'
xr = {}
for i, r in enumerate(csv.DictReader(open(AR + 'x_world.csv'))): xr[int(r['cx'])] = i + 1
lr = {int(r['line_n']): int(r['rank']) for r in csv.DictReader(open(AR + 'line_world_ranked.csv'))}
old = set()
with open(AR + 'spot_measured.csv') as f:
    next(f)
    for line in f:
        a, b, _ = line.split(',', 2); old.add((int(a), int(b)))
def region(cx, cz):
    if (cx, cz) in old: return 'v1'
    c = xr.get(cx, 0); n = math.floor((cz - 48.5) / 96.875 + 0.5); l = lr.get(n, 0)
    if 1 <= c <= 10000 and 1 <= l <= 300: return 'v1_other_row'
    if 1 <= c <= 10000: return 'A'
    if 10000 < c <= 70000 and 1 <= l <= 300: return 'B'
    return 'new'
bands = list(range(12, 31))
cnt = {g: [0.0] * len(bands) for g in ('v1', 'v1_other_row', 'A', 'B', 'new')}
for r in csv.DictReader(open('catalog/out/summary_by_heat_and_region.csv')):
    b = int(r['heat_band'])
    if b < 12: continue
    i = min(b, 30) - 12
    for g in cnt: cnt[g][i] += int(r[g])
M = list(csv.DictReader(open('val/pairs_meta.csv'))); H = {(r['cx'], r['cz']): float(r['heat40']) for r in csv.DictReader(open('val/pairs_heat.csv'))}
n = collections.Counter(r['bin'] for r in M)
for r in M:
    b = r['bin']
    if not b[0].isdigit() or float(b.split('-')[0]) >= 12: continue
    h = H[(r['cx'], r['cz'])]
    if h < 12: continue
    cnt[region(int(r['cx']), int(r['cz']))][min(int(h), 30) - 12] += int(r['bin_pairs']) / n[b]
out = {'bands': bands, 'old': [round(x) for x in cnt['v1']],
       'newAB': [round(a + b) for a, b in zip(cnt['A'], cnt['B'])],
       'newRest': [round(a + b) for a, b in zip(cnt['v1_other_row'], cnt['new'])]}
json.dump(out, open('chart_final.json', 'w'))
for k in ('old', 'newAB', 'newRest'): print(k, f'{sum(out[k]):,}', out[k])
