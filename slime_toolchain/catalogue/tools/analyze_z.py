import csv, math, statistics, collections, json, sys
D = sys.argv[1] if len(sys.argv) > 1 else "./zscan/"   # folder holding rows_col*.csv
cols = [0, 1, 2, 3]
H = {}
for c in cols:
    try: H[c] = {int(r['cz']): float(r['heat40']) for r in csv.DictReader(open(D + "rows_col%d.csv" % c, newline=''))}
    except FileNotFoundError: pass
print("columns loaded:", list(H), {c: len(v) for c, v in H.items()})
def dist(z):
    n = round((z - 48.5) / 96.875); return z - (48.5 + 96.875 * n), n
for c, h in H.items():
    vals = sorted(h.values())
    print("\ncolumn %d: rows %d, heat median %.2f, 99th %.2f, 99.9th %.2f, max %.2f" % (c, len(vals), statistics.median(vals), vals[int(.99 * len(vals))], vals[int(.999 * len(vals))], vals[-1]))
    for t in (4, 8, 12):
        hot = [z for z, v in h.items() if v >= t]
        d = [abs(dist(z)[0]) for z in hot]
        far = [z for z in hot if abs(dist(z)[0]) > 3]
        print("  rows >= %2d: %7d  |  distance to the formula line: <=0.5 %5.1f%%  <=1.5 %5.1f%%  <=2.5 %5.1f%%  <=3.5 %5.1f%%  OFF-LATTICE (>3): %d" % (
            t, len(hot), 100 * sum(x <= .5 for x in d) / max(1, len(d)), 100 * sum(x <= 1.5 for x in d) / max(1, len(d)),
            100 * sum(x <= 2.5 for x in d) / max(1, len(d)), 100 * sum(x <= 3.5 for x in d) / max(1, len(d)), len(far)))
        if far and t >= 8: print("     off-lattice examples:", [(z, round(h[z], 1), round(dist(z)[0], 1)) for z in sorted(far, key=lambda z: -h[z])[:8]])
    prof = collections.defaultdict(list)
    for z, v in h.items():
        dd, n = dist(z)
        if abs(dd) <= 8: prof[round(dd)].append(v)
    print("  mean heat by offset from the line centre:", {k: round(statistics.mean(v), 2) for k, v in sorted(prof.items())})
if len(H) >= 2:
    ks = sorted(H)
    common = set.intersection(*[set(H[c]) for c in ks])
    print("\nSEPARABILITY - do the columns see the same lines?")
    for i in range(len(ks)):
        for j in range(i + 1, len(ks)):
            a, b = H[ks[i]], H[ks[j]]
            zz = [z for z in common if a[z] >= 4 or b[z] >= 4]
            xa = [math.log(a[z] + 0.5) for z in zz]; xb = [math.log(b[z] + 0.5) for z in zz]
            ma, mb = statistics.mean(xa), statistics.mean(xb)
            r = sum((p - ma) * (q - mb) for p, q in zip(xa, xb)) / math.sqrt(sum((p - ma) ** 2 for p in xa) * sum((q - mb) ** 2 for q in xb))
            print("  col %d vs col %d: %d rows hot in either, corr(log heat) %.3f" % (ks[i], ks[j], len(zz), r))
    g = {z: max(H[c][z] for c in ks if z in H[c]) for z in common}
    json.dump({"rows": len(g)}, open(D + "summary.json", "w"))
    with open(D + "g_rows.csv", "w") as f:
        f.write("cz,max_heat," + ",".join("col%d" % c for c in ks) + "\n")
        for z in sorted(g):
            if g[z] >= 2: f.write("%d,%.3f,%s\n" % (z, g[z], ",".join("%.3f" % H[c][z] for c in ks)))
    print("rows with max heat >= 2 written to g_rows.csv")
