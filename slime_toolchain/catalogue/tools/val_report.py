import csv, collections, math
M = {(r['cx'], r['cz']): r for r in csv.DictReader(open('val/pairs_meta.csv'))}
H = {(r['cx'], r['cz']): float(r['heat40']) for r in csv.DictReader(open('val/pairs_heat.csv'))}
by = collections.defaultdict(list)
for k, r in M.items(): by[r['bin']].append((float(r['pred']), H[k], int(r['bin_pairs'])))
print(f"{'pred bin':>9} {'pairs in bin':>15} {'sampled':>8} {'mean meas/pred':>14} {'meas>=12':>9} {'est. 12+ pairs in bin':>22} {'>=13':>6}")
for b in sorted(by, key=lambda s: (not s[0].isdigit(), float(s.split('-')[0]) if s[0].isdigit() else 0, s)):
    v = by[b]; n = len(v); tot = v[0][2]
    k12 = sum(h >= 12 for _, h, _ in v); k13 = sum(h >= 13 for _, h, _ in v)
    ratio = sum(h for _, h, _ in v) / max(1e-9, sum(p for p, _, _ in v))
    up = (k12 + 3) / n * tot if k12 == 0 else k12 / n * tot
    print(f"{b:>9} {tot:>15,} {n:>8} {ratio:>14.3f} {k12:>9} {('<' if k12 == 0 else '') + format(int(up), ','):>22} {k13:>6}")
