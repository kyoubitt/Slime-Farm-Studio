// afk_rescan.cpp - RAISED-AFK RESCAN of farms already found (a separate tool: the search never calls it).
// ============================================================================
// The search and slime_refine score every farm with the player level with the spawn surface
// (y-offset 0): a block column counts when 24^2 < a^2 + b^2 <= 128^2 (a, b = column minus AFK, in
// blocks). In game the player stands ABOVE the floor (the author's rig: feet at y -39, floor at y -64, so
// slimes spawn at y -63, dy = 24 below the feet), and both spheres are 3D:
//
//        24^2 <= a^2 + b^2 + dy^2 <= 128^2      (game; calibrated in game, see makeRing)
//
// At dy = 24 the inner no-spawn circle is gone (only the column straight below is excluded) and the
// outer circle shrinks to sqrt(128^2 - 24^2) = 125.7 blocks. Same total area, different chunks: a farm
// gains whatever slime lies within 24 blocks of the AFK point and loses the slime in the outer 2.3
// blocks. That is why the 69.30 (4 slime chunks in the middle) beat its y-offset-0 count by 3.8% and
// the 70.64 by only 1.2%.
//
// For every farm (seed, AFK x, z) this prints: the y-offset-0 count (must equal the stored blocks -
// a built-in check of this code against slime_refine), the count at dy at the SAME AFK point, and the
// best count at dy within +-window blocks (the best point moves once the middle counts).
//
// Method: slime-column bitmap around the farm, per-row prefix sums, and for every candidate AFK point
// one prefix-sum difference per row of the circle (~250 rows) - about 1M operations per farm at
// window 32, so thousands of farms take seconds.
//
// TWO RULES, BOTH CHECKED AGAINST THE GAME'S OWN CODE (vanilla_parity.py):
//   Carpet /perimeterinfo  24^2 <= d^2 <= 128^2   integer offsets from the player's block (the
//                          calibrated 49,669 below; this is the number /perimeterinfo shows)
//   vanilla spawning       24^2 <  d^2 <= 128^2   NaturalSpawner: "d^2 <= 576 -> no spawn", despawn
//                          past 128 - the same rule slime_refine uses at y-offset 0
// They differ only on the exact-24 shell: at dy 24 that is the one column straight below the
// player, at dy 0 the four columns 24 blocks out on the axes. The blocks_* columns below are the
// Carpet rule (what you read in game); vanilla_* columns are what the game actually spawns on.
//
// Input CSV (header line required; extra columns are carried to the output unchanged):
//     seed,x,z[,anything...]
// Usage:
//     afk_rescan --in farms.csv --out rescan.csv [--dy 24] [--window 32]
//     afk_rescan --in farms.csv --out sweep.csv --dy-from 0 --dy-to 24 [--window 48] [--spawn-y -63]
//              Y SWEEP: every standing height in one pass (the area is built once per farm). One
//              row per farm per dy; the best AFK point is picked by the VANILLA count (ties: Carpet,
//              then the nearer point). feet_y = spawn-y + dy (floor -64 -> spawn -63 -> dy 24 = -39).
//              Above dy 24 nothing can be gained (the count is a subset of dy 24's).
//     afk_rescan --disc [--dy 24]      full-floor count (calibration: a floor under every column)
// Build: nvcc -O3 afk_rescan.cpp -o afk_rescan.exe   (plain C++; slime_core.h only for isSlimeChunk)
// ============================================================================
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include "slime_core.h"
#include "portable_paths.h"

static long long floorDiv(long long v, long long d) { long long q = v / d; if ((v % d != 0) && ((v < 0) != (d < 0))) q--; return q; }
static long long isqrtFloor(long long v) { if (v < 0) return -1; long long r = (long long)std::sqrt((double)v); while (r * r > v) r--; while ((r + 1) * (r + 1) <= v) r++; return r; }

struct Ring {           // per row offset b: columns |a| <= outer[b] count, minus |a| <= inner[b] (-1 = none)
    int R;              // max |b|
    std::vector<long long> outer, inner;
};
// game = true: the Carpet /perimeterinfo rule, CALIBRATED - a full floor under a player standing at y -39 (dy 24) reads
// 49,669 in /perimeterinfo; 24^2 < d^2 gives 49,668, so the game also counts d^2 = 24^2 exactly (the
// column straight below). game = false: 24^2 < d^2 - slime_refine's rule, and also vanilla's own spawn
// rule at ANY dy (NaturalSpawner rejects d^2 <= 576); used for the stored-blocks check and vanilla_*.
static Ring makeRing(long long dy, bool game) {
    const long long lo = 576 - dy * dy, hi = 16384 - dy * dy;
    Ring g; g.R = (int)isqrtFloor(hi);
    for (int b = -g.R; b <= g.R; b++) {
        long long b2 = (long long)b * b;
        g.outer.push_back(isqrtFloor(hi - b2));
        // excluded columns: a^2 + b^2 <= lo (model) or < lo (game)
        long long lim = game ? lo - 1 : lo;
        g.inner.push_back(lim - b2 >= 0 ? isqrtFloor(lim - b2) : -1);
    }
    return g;
}

struct Area {            // slime-column bitmap as row prefix sums over [x0, x0+w) x [z0, z0+h)
    long long x0, z0; int w, h;
    std::vector<int> P;  // P[r*(w+1) + c] = slime columns in row r, columns [0, c)
    int rowSum(int r, long long xa, long long xb) const {   // columns xa..xb (world), inclusive
        int ca = (int)(xa - x0), cb = (int)(xb - x0) + 1;
        return P[(size_t)r * (w + 1) + cb] - P[(size_t)r * (w + 1) + ca];
    }
};
static Area buildArea(long long seed, long long cx, long long cz, int reach) {
    Area A; A.x0 = cx - reach; A.z0 = cz - reach; A.w = 2 * reach + 1; A.h = 2 * reach + 1;
    long long chx0 = floorDiv(A.x0, 16), chx1 = floorDiv(A.x0 + A.w - 1, 16);
    long long chz0 = floorDiv(A.z0, 16), chz1 = floorDiv(A.z0 + A.h - 1, 16);
    int nx = (int)(chx1 - chx0 + 1);
    std::vector<uint8_t> slime((size_t)nx * (chz1 - chz0 + 1));
    for (long long z = chz0; z <= chz1; z++)
        for (long long x = chx0; x <= chx1; x++)
            slime[(size_t)(z - chz0) * nx + (x - chx0)] = isSlimeChunk(seed, (int)x, (int)z) ? 1 : 0;
    A.P.assign((size_t)A.h * (A.w + 1), 0);
    for (int r = 0; r < A.h; r++) {
        long long zc = floorDiv(A.z0 + r, 16) - chz0;
        int acc = 0; A.P[(size_t)r * (A.w + 1)] = 0;
        for (int c = 0; c < A.w; c++) {
            acc += slime[(size_t)zc * nx + (floorDiv(A.x0 + c, 16) - chx0)];
            A.P[(size_t)r * (A.w + 1) + c + 1] = acc;
        }
    }
    return A;
}
static int countAt(const Area& A, const Ring& g, long long X, long long Z) {
    int n = 0;
    for (int i = 0; i <= 2 * g.R; i++) {
        int b = i - g.R; int r = (int)(Z + b - A.z0);
        long long o = g.outer[i];
        n += A.rowSum(r, X - o, X + o);
        long long in = g.inner[i];
        if (in >= 0) n -= A.rowSum(r, X - in, X + in);
    }
    return n;
}

static std::vector<std::string> splitCsv(const std::string& line) {
    std::vector<std::string> f; std::string cur; bool q = false;
    for (char ch : line) { if (ch == '"') q = !q; else if (ch == ',' && !q) { f.push_back(cur); cur.clear(); } else if (ch != '\r') cur += ch; }
    f.push_back(cur); return f;
}

int main(int argc, char** argv) {
    slimeFixArgv(argc, argv);       // "\" -> "/" off Windows (portable_paths.h)
    std::string in, out; long long dy = 24; int window = 32; bool disc = false;
    long long dyFrom = -1, dyTo = -1, spawnY = -63; bool windowSet = false;
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        auto nx = [&](const char* n) -> const char* { if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", n); exit(1); } return argv[++i]; };
        if (k == "--in") in = nx("--in");
        else if (k == "--out") out = nx("--out");
        else if (k == "--dy") dy = atoll(nx("--dy"));
        else if (k == "--window") { window = atoi(nx("--window")); windowSet = true; }
        else if (k == "--dy-from") dyFrom = atoll(nx("--dy-from"));
        else if (k == "--dy-to") dyTo = atoll(nx("--dy-to"));
        else if (k == "--spawn-y") spawnY = atoll(nx("--spawn-y"));
        else if (k == "--disc") disc = true;
        else { fprintf(stderr, "usage: afk_rescan --in farms.csv --out rescan.csv [--dy 24] [--window 32]\n"
                               "       afk_rescan --in farms.csv --out sweep.csv --dy-from 0 --dy-to 24 [--window 48] [--spawn-y -63]\n"
                               "       afk_rescan --disc [--dy 24]\n"); return 1; }
    }
    const Ring g = makeRing(dy, true), gv = makeRing(dy, false), g0 = makeRing(0, false);
    if (disc) {   // every column floored: the pure geometry, for an in-game calibration
        auto full = [](const Ring& r) { long long n = 0;
            for (int i = 0; i <= 2 * r.R; i++) n += 2 * r.outer[i] + 1 - (r.inner[i] >= 0 ? 2 * r.inner[i] + 1 : 0);
            return n; };
        printf("full floor, dy %lld: %lld spawn columns by /perimeterinfo, %lld by vanilla spawning (outer radius %.2f, inner %s)\n",
               dy, full(g), full(gv), std::sqrt(16384.0 - dy * dy),
               dy >= 24 ? "none" : std::to_string(std::sqrt(576.0 - dy * dy)).c_str());
        return 0;
    }
    const bool sweep = dyFrom >= 0 || dyTo >= 0;
    if (sweep) {
        if (dyFrom < 0 || dyTo < dyFrom || dyTo > 128) { fprintf(stderr, "--dy-from/--dy-to: need 0 <= from <= to <= 128\n"); return 1; }
        if (!windowSet) window = 48;
    }
    if (in.empty() || out.empty()) { fprintf(stderr, "--in and --out are required\n"); return 1; }
    std::ifstream fi(in); if (!fi) { fprintf(stderr, "cannot read %s\n", in.c_str()); return 1; }
    FILE* fo = fopen(out.c_str(), "w"); if (!fo) { fprintf(stderr, "cannot write %s\n", out.c_str()); return 1; }
    std::string line; std::getline(fi, line); if (!line.empty() && line.back() == '\r') line.pop_back();
    if (sweep) fprintf(fo, "%s,blocks_y0,dy,feet_y,blocks_carpet,blocks_vanilla,best_x,best_z,shift\n", line.c_str());
    else fprintf(fo, "%s,blocks_y0,blocks_dy_same_afk,blocks_dy_best,best_x,best_z,shift,vanilla_dy_best\n", line.c_str());
    const int reach = g0.R + window + 2;
    long long nFarms = 0;
    while (std::getline(fi, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        auto f = splitCsv(line); if (f.size() < 3) continue;
        long long seed = atoll(f[0].c_str()), x = atoll(f[1].c_str()), z = atoll(f[2].c_str());
        Area A = buildArea(seed, x, z, reach);
        int b0 = countAt(A, g0, x, z);
        if (sweep) {
            for (long long d = dyFrom; d <= dyTo; d++) {
                const Ring rc = makeRing(d, true), rv = makeRing(d, false);
                int bestV = -1, bestC = -1; long long bx = x, bz = z, bd = 0;
                for (int v = -window; v <= window; v++)
                    for (int u = -window; u <= window; u++) {
                        int cv = countAt(A, rv, x + u, z + v);
                        if (cv < bestV) continue;
                        int cc = countAt(A, rc, x + u, z + v); long long dd = (long long)u * u + (long long)v * v;
                        if (cv > bestV || cc > bestC || (cc == bestC && dd < bd)) { bestV = cv; bestC = cc; bx = x + u; bz = z + v; bd = dd; }
                    }
                fprintf(fo, "%s,%d,%lld,%lld,%d,%d,%lld,%lld,%.1f\n", line.c_str(), b0, d, spawnY + d, bestC, bestV, bx, bz, std::sqrt((double)bd));
            }
            nFarms++;
            continue;
        }
        int bs = countAt(A, g, x, z);
        int best = -1; long long bx = x, bz = z, bd = 0;
        for (int v = -window; v <= window; v++)
            for (int u = -window; u <= window; u++) {
                int c = countAt(A, g, x + u, z + v); long long d = (long long)u * u + (long long)v * v;
                if (c > best || (c == best && d < bd)) { best = c; bx = x + u; bz = z + v; bd = d; }
            }
        fprintf(fo, "%s,%d,%d,%d,%lld,%lld,%.1f,%d\n", line.c_str(), b0, bs, best, bx, bz, std::sqrt((double)bd),
                countAt(A, gv, bx, bz));
        nFarms++;
    }
    fclose(fo);
    if (sweep) printf("%lld farms swept over dy %lld..%lld (window +-%d blocks) -> %s\n", nFarms, dyFrom, dyTo, window, out.c_str());
    else printf("%lld farms rescanned at dy %lld (window +-%d blocks) -> %s\n", nFarms, dy, window, out.c_str());
    return 0;
}
