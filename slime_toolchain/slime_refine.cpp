// slime_refine.cpp
// ============================================================================
// Native replacement for slimefinder.jar's scoring. Seeds in, real cq out.
//
// WHY THIS EXISTS
//   slimefinder.jar is correct but it is a JVM process per seed per y-offset,
//   writing properties files and CSVs to disk between every run. The scoring
//   itself is ~14k integer ops. Everything else was overhead.
//
// WHAT IT REPRODUCES EXACTLY
//   Verified against slimefinder's own fine-phase output, blocks AND chunks,
//   seed 2452809435317741826:
//     (3680,6992) 16821/70   (3696,6992) 16498/72   (3680,6976) 16496/68
//   Same report layout and same filename scheme, so it drops into the existing
//   workflow. Images are still the jar's job (-i mode); this only replaces the
//   search.
//
// WHAT IT DOES THAT THE JAR DID NOT
//   The jar only ever tested chunk-ALIGNED AFK positions - every position in
//   your logs is a multiple of 16. But the block weights depend on where you
//   stand INSIDE the chunk: for offset (ox,oz), a block at chunk offset (dx,dz)
//   sits at a = 16*dx + i - ox. There are 256 distinct weight tables and the
//   jar searched one of them. --fine tests all 16x16 offsets, so it sees 256x
//   more AFK spots. Chunk alignment is not special; it was an artifact.
//
// THE METRIC
//   Slimes cannot spawn within 24 blocks of a player, so eligibility is an
//   ANNULUS: 24^2 < a^2+b^2 <= 128^2. cq = blocks/256 is the real objective.
//   Chunk count is a proxy and it lies: in your own data 70 chunks at 93.9%
//   (65.71 cq) BEATS 72 chunks at 89.5% (64.45 cq).
//
// Build:  g++ -O3 -march=native -pthread slime_refine.cpp -o slime_refine
// Needs:  slime_core.h beside it.
// ============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <string>
#include <vector>
#include <algorithm>
#include <set>
#include <thread>
#include <mutex>
#include "slime_core.h"
#include "png_writer.h"
#ifdef _WIN32
#include <direct.h>
#define MKDIR(d) _mkdir(d)
#else
#include <sys/stat.h>
#define MKDIR(d) mkdir(d, 0755)
#endif

struct Row {
    int bx, bz, blocks, chunks, dist;
    double cq() const { return std::floor(blocks / 256.0 * 100.0 + 0.5) / 100.0; }  // 2dp, like the driver
};

// 256 weight tables, one per in-chunk AFK offset. w[(oz*16+ox)][cell]
struct Weights {
    std::vector<int> w;             // 256 * 289
    // yOff = how far the AFK spot sits above/below the spawn plane. Both spheres
    // are 3D, so at vertical offset dy a column at horizontal distance d is
    // eligible iff  24^2 < d^2 + dy^2 <= 128^2, i.e. the radii become
    //     outer^2 = 128^2 - dy^2        inner^2 = max(0, 24^2 - dy^2)
    // At |dy| >= 24 the exclusion sphere no longer reaches the plane and the
    // inner hole disappears. At |dy| >= 128 nothing is in range at all.
    // dy = 0 is the default and the ONLY value verified against slimefinder's
    // own output. Non-zero y is derived from the same geometry but unvalidated -
    // send me a jar log at y-offset -16 or -32 and I will check it.
    Weights(int yOff = 0) : w(256 * 289, 0) {
        long long dy2 = (long long)yOff * yOff;
        long long RD = (long long)SLIME_DESPAWN_R * SLIME_DESPAWN_R - dy2;
        long long RE = (long long)SLIME_EXCLUSION_R * SLIME_EXCLUSION_R - dy2;
        if (RD < 0) RD = -1;          // nothing in range
        if (RE < 0) RE = -1;          // exclusion sphere misses the plane
        for (int oz = 0; oz < 16; oz++)
            for (int ox = 0; ox < 16; ox++) {
                int* t = &w[(oz * 16 + ox) * 289];
                for (int dz = -8; dz <= 8; dz++)
                    for (int dx = -8; dx <= 8; dx++) {
                        int c = 0;
                        for (int i = 0; i < 16; i++) {
                            long long a = 16LL * dx + i - ox;
                            for (int j = 0; j < 16; j++) {
                                long long b = 16LL * dz + j - oz;
                                long long d2 = a * a + b * b;
                                if (d2 <= RD && d2 > RE) c++;
                            }
                        }
                        t[(dz + 8) * 17 + (dx + 8)] = c;
                    }
            }
    }
    const int* table(int ox, int oz) const { return &w[(oz * 16 + ox) * 289]; }
};

static void scoreSeed(long long seed, int centerBX, int centerBZ, int radiusChunks,
                      bool fine, const Weights& W, std::vector<Row>& out) {
    // AFK positions to test
    int half = radiusChunks * 16;
    int lo = fine ? -half : -radiusChunks * 16;
    int step = fine ? 1 : 16;
    int bx0 = centerBX + lo, bx1 = centerBX + half;
    int bz0 = centerBZ + lo, bz1 = centerBZ + half;
    if (!fine) { // snap to chunk origins
        bx0 = ((centerBX >> 4) - radiusChunks) * 16; bx1 = ((centerBX >> 4) + radiusChunks) * 16;
        bz0 = ((centerBZ >> 4) - radiusChunks) * 16; bz1 = ((centerBZ >> 4) + radiusChunks) * 16;
    }
    // Precompute the slime grid once: isSlimeChunk depends only on the chunk,
    // so every AFK position in the window reuses it. This is the whole trick -
    // the jar re-derived it per position.
    int gcx0 = (bx0 >> 4) - 8, gcx1 = (bx1 >> 4) + 8;
    int gcz0 = (bz0 >> 4) - 8, gcz1 = (bz1 >> 4) + 8;
    int gw = gcx1 - gcx0 + 1, gh = gcz1 - gcz0 + 1;
    std::vector<uint8_t> grid((size_t)gw * gh);
    for (int z = 0; z < gh; z++)
        for (int x = 0; x < gw; x++)
            grid[(size_t)z * gw + x] = isSlimeChunk(seed, gcx0 + x, gcz0 + z) ? 1 : 0;

    for (int bz = bz0; bz <= bz1; bz += step)
        for (int bx = bx0; bx <= bx1; bx += step) {
            int cx = bx >> 4, cz = bz >> 4;
            int ox = bx & 15, oz = bz & 15;
            const int* t = W.table(ox, oz);
            int blocks = 0, chunks = 0;
            for (int dz = -8; dz <= 8; dz++) {
                int gz = cz + dz - gcz0;
                for (int dx = -8; dx <= 8; dx++) {
                    int wt = t[(dz + 8) * 17 + (dx + 8)];
                    if (!wt) continue;
                    if (grid[(size_t)gz * gw + (cx + dx - gcx0)]) { blocks += wt; chunks++; }
                }
            }
            int ddx = bx - centerBX, ddz = bz - centerBZ;
            // PowerShell's [int] ROUNDS, it does not truncate, and dist is a sort
            // tie-breaker - so truncating here silently reorders the log.
            out.push_back(Row{ bx, bz, blocks, chunks,
                               (int)lround(std::sqrt((double)ddx * ddx + (double)ddz * ddz)) });
        }
}

// The jar workflow's numbers come out of PowerShell, which has two habits worth
// copying so old and new logs stay diffable:
//   [math]::Round(x,2) then string-format DROPS trailing zeros -> "63", not "63.00"
//   the driver rounds cq to 2dp BEFORE computing the eff%, so the % is derived
//   from the rounded value (61.57/68 = 90.5%, not 61.5742/68 = 90.6%)
static double roundCQ(int blocks) { return std::floor(blocks / 256.0 * 100.0 + 0.5) / 100.0; }
static std::string fmtCQ(double v) {
    char b[32]; snprintf(b, sizeof(b), "%.2f", v);
    std::string s(b);
    if (s.find('.') != std::string::npos) {
        while (!s.empty() && s.back() == '0') s.pop_back();
        if (!s.empty() && s.back() == '.') s.pop_back();
    }
    return s;
}
static std::string fmt1(double v) { char b[32]; snprintf(b, sizeof(b), "%.1f", v); return b; }

// Draw a top-down PNG of the 17x17 chunk area around the best AFK spot,
// styled like the jar's images: green = slime chunk, dark grey = excluded
// (annulus outer), even darker = spawn-suppression sphere (24-block hole).
// North is up (Z decreases upward), matching the jar. One tile = 32x32 px.
// Written to <dir>/../images/<same-name-as-log>.png so seeds and images sit
// as siblings under main/.
static void writeSeedImage(long long seed, int bx, int bz, int yOff,
                           double bestCq, double bestEff, int bestChunks, int bestCrChunks,
                           const std::string& imgDir) {
    // v7: jar-style rendering with true circles for the exclusion spheres and
    // cleaner palette. 17x17 chunks visible, 32px/chunk tile.
    // Colors match SlimeFinder defaults: light background, dark chunk-grid,
    // saturated green slime, red AFK cross with faint circle overlays.
    const int TILE = 32;
    const int W = 17 * TILE, H = 17 * TILE;
    std::vector<uint8_t> px((size_t)W * H * 3, 0);

    auto setpx = [&](int x, int y, uint8_t r, uint8_t g, uint8_t b) {
        if (x < 0 || x >= W || y < 0 || y >= H) return;
        size_t p = (size_t)(y * W + x) * 3;
        px[p+0] = r; px[p+1] = g; px[p+2] = b;
    };
    auto blendpx = [&](int x, int y, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
        if (x < 0 || x >= W || y < 0 || y >= H) return;
        size_t p = (size_t)(y * W + x) * 3;
        px[p+0] = (uint8_t)((px[p+0] * (255 - a) + r * a) / 255);
        px[p+1] = (uint8_t)((px[p+1] * (255 - a) + g * a) / 255);
        px[p+2] = (uint8_t)((px[p+2] * (255 - a) + b * a) / 255);
    };
    auto fillTile = [&](int tx, int tz, uint8_t r, uint8_t g, uint8_t b) {
        int x0 = tx * TILE, y0 = tz * TILE;
        for (int y = y0; y < y0 + TILE; y++)
            for (int x = x0; x < x0 + TILE; x++) setpx(x, y, r, g, b);
    };

    int cbxChunk = bx >> 4, cbzChunk = bz >> 4;
    int oxBlock = bx & 15, ozBlock = bz & 15;

    // AFK position in pixels (offset within center chunk, chunk is at tile 8,8)
    // Every block = 2px. So x within chunk = 0..15 blocks = 0..30px inside tile.
    int afkPxX = 8 * TILE + oxBlock * 2 + 1;
    int afkPxZ = 8 * TILE + ozBlock * 2 + 1;

    // --- Layer 1: chunk tiles ---
    // Base background: light off-white (jar uses ~white)
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) setpx(x, y, 245, 245, 240);

    for (int dz = -8; dz <= 8; dz++) {
        for (int dx = -8; dx <= 8; dx++) {
            int cx = cbxChunk + dx, cz = cbzChunk + dz;
            bool slime = isSlimeChunk(seed, cx, cz);
            int tx = dx + 8, tz = dz + 8;
            if (slime) fillTile(tx, tz, 90, 200, 90);   // saturated green
            // non-slime tiles keep the light background
        }
    }

    // --- Layer 2: chunk grid (thin, dark) ---
    for (int i = 0; i <= 17; i++) {
        int gx = i * TILE;
        for (int y = 0; y < H; y++) setpx(gx, y, 60, 60, 60);
    }
    for (int i = 0; i <= 17; i++) {
        int gy = i * TILE;
        for (int x = 0; x < W; x++) setpx(x, gy, 60, 60, 60);
    }

    // --- Layer 3: exclusion + eligibility circles (true circles, semi-transparent) ---
    // 24-block exclusion sphere and 128-block eligibility radius drawn as
    // anti-aliased ring outlines. Scale: 1 block = 2 pixels (32px tile / 16 blocks).
    auto drawCircle = [&](double cxp, double cyp, double r,
                          uint8_t rr, uint8_t gg, uint8_t bb, uint8_t a, double thickness = 1.5) {
        int x0 = (int)(cxp - r - 2), x1 = (int)(cxp + r + 2);
        int y0 = (int)(cyp - r - 2), y1 = (int)(cyp + r + 2);
        for (int y = y0; y <= y1; y++)
            for (int x = x0; x <= x1; x++) {
                double dx = x + 0.5 - cxp, dy = y + 0.5 - cyp;
                double d = sqrt(dx*dx + dy*dy);
                double dist = fabs(d - r);
                if (dist < thickness) {
                    double t = 1.0 - dist / thickness;
                    blendpx(x, y, rr, gg, bb, (uint8_t)(a * t));
                }
            }
    };
    // 24 blocks = 48 px, 128 blocks = 256 px
    drawCircle(afkPxX + 0.5, afkPxZ + 0.5, 48.0, 200, 0, 0, 200, 1.5);   // inner exclusion
    drawCircle(afkPxX + 0.5, afkPxZ + 0.5, 256.0, 200, 0, 0, 160, 1.5);  // outer eligibility

    // --- Layer 4: red AFK crosshair (larger, more visible) ---
    for (int i = -8; i <= 8; i++) {
        setpx(afkPxX + i, afkPxZ, 220, 30, 30);
        setpx(afkPxX, afkPxZ + i, 220, 30, 30);
        setpx(afkPxX + i, afkPxZ + 1, 220, 30, 30);
        setpx(afkPxX + 1, afkPxZ + i, 220, 30, 30);
    }
    // Small red dot at exact position
    setpx(afkPxX, afkPxZ, 255, 60, 60);

    // --- Save ---
    // Filename is just the seed - the score (bestCq/bestEff/bestChunks/
    // bestCrChunks) lives in the matching .txt log, not the filename.
    MKDIR(imgDir.c_str());
    std::string name = imgDir + "/" + std::to_string(seed) + ".png";
    if (!pngw::write_rgb(name.c_str(), px.data(), W, H))
        fprintf(stderr, "cannot write %s\n", name.c_str());
}


static void report(long long seed, int cbx, int cbz, int radius, bool fine, int yOff,
                   std::vector<Row>& rows, const std::string& dir, int topN, bool quiet,
                   bool images, const std::string& imgDir) {
    if (rows.empty()) return;
    std::vector<Row> byB = rows, byC = rows;
    std::sort(byB.begin(), byB.end(), [](const Row& a, const Row& b) {
        if (a.blocks != b.blocks) return a.blocks > b.blocks; return a.dist < b.dist; });
    std::sort(byC.begin(), byC.end(), [](const Row& a, const Row& b) {
        if (a.chunks != b.chunks) return a.chunks > b.chunks; return a.dist < b.dist; });
    const Row& bB = byB[0]; const Row& bC = byC[0];

    std::string s;
    char line[512];
    snprintf(line, sizeof(line), "Slime refine result   (slime_refine, native)\n"); s += line;
    snprintf(line, sizeof(line), "Seed %lld   center (%d,%d)   radius %d chunks   y-offset %d   %s\n",
             seed, cbx, cbz, radius, yOff, fine ? "block resolution (256x the jar)" : "chunk aligned"); s += line;
    s += "\n";
    snprintf(line, sizeof(line), "BEST BY BLOCKS: %d blocks (%s cq) / %d chunks at (%d,%d)  y-offset %d  dist %d  /tp %d ~ %d\n",
             bB.blocks, fmtCQ(bB.cq()).c_str(), bB.chunks, bB.bx, bB.bz, yOff, bB.dist, bB.bx, bB.bz); s += line;
    snprintf(line, sizeof(line), "BEST BY CHUNKS: %d chunks / %d blocks at (%d,%d)  y-offset %d  dist %d  /tp %d ~ %d\n",
             bC.chunks, bC.blocks, bC.bx, bC.bz, yOff, bC.dist, bC.bx, bC.bz); s += line;
    s += "\nTop " + std::to_string(topN) + " by blocks:\n";
    for (int i = 0; i < topN && i < (int)byB.size(); i++) {
        const Row& r = byB[i];
        snprintf(line, sizeof(line), "  %6d blocks  %5s cq  %5s%%  %3d chunks  (%d,%d)  y%d  dist %d\n",
                 r.blocks, fmtCQ(r.cq()).c_str(), fmt1(r.cq() / r.chunks * 100).c_str(),
                 r.chunks, r.bx, r.bz, yOff, r.dist); s += line;
    }
    s += "\nTop " + std::to_string(topN) + " by chunks:\n";
    for (int i = 0; i < topN && i < (int)byC.size(); i++) {
        const Row& r = byC[i];
        snprintf(line, sizeof(line), "  %3d chunks  %6d blocks  (%d,%d)  y%d  dist %d\n",
                 r.chunks, r.blocks, r.bx, r.bz, yOff, r.dist); s += line;
    }
    if (!quiet) fputs(s.c_str(), stdout);

    // Filename is just the seed - the score is the first thing IN the log
    // (see "BEST BY BLOCKS" above), not encoded in the filename.
    std::string name = dir + "/" + std::to_string(seed) + ".txt";
    FILE* f = fopen(name.c_str(), "w");
    if (f) { fputs(s.c_str(), f); fclose(f); if (!quiet) printf("\nLog saved to %s\n", name.c_str()); }
    else fprintf(stderr, "cannot write %s\n", name.c_str());

    // v7: image output under main/images/<family>/. Default ON so the jar isn't
    // needed for the visual. Same base filename as the log, .png extension.
    if (images) {
        double eff = bB.cq() / bB.chunks * 100.0;
        writeSeedImage(seed, bB.bx, bB.bz, yOff, bB.cq(), eff, bB.chunks, bC.chunks, imgDir);
    }
}

// ------------------------------------------------------------------
// --climb: exploit high-bit seed-neighbor correlation. java.util.Random's
// LCG does state = state*MULT + ADD (mod 2^48) with MULT odd (~35 bits).
// Flipping seed bit b changes the product by (MULT<<b) mod 2^48, and a
// left-shift-then-truncate can only ever ADD bits at position >= b -
// truncation drops the overflow, it does not wrap to the bottom. So
// flipping a HIGH seed bit perturbs only the top few bits of the LCG state,
// not a fresh independent draw - seeds differing solely in bits
// [climbLo,47] render nearly-identical slime layouts. This is a genuinely
// different axis from hotspot_scan's derivation (which correlates LOW bits
// 0-23 across many random seeds at one location): here we fix everything
// and sweep high bits of ONE known seed to search its local neighborhood.
// Confirmed empirically: an 8192-variant sweep (bits 35-47) around the
// 66.04 record ties it exactly in a small but very much nonzero fraction of
// variants - far too often to be coincidence (a true independent seed lands
// on this exact layout at a rate no feasible hunt reaches).
// Pure local search over a KNOWN good seed: finds no new families, just
// squeezes any free extra cq out of ones already in hand. --climb-recurse
// repeats the same fixed-size sweep centred on any improvement found.
// ------------------------------------------------------------------
static Row bestRowFor(long long seed, int cbx, int cbz, int radius, bool fine,
                      const Weights& W, std::vector<Row>& rows) {
    rows.clear();
    scoreSeed(seed, cbx, cbz, radius, fine, W, rows);
    if (rows.empty()) return Row{0, 0, 0, 0, 0};
    return *std::max_element(rows.begin(), rows.end(),
        [](const Row& a, const Row& b) {
            if (a.blocks != b.blocks) return a.blocks < b.blocks;
            return a.dist > b.dist;
        });
}

static void climbSeed(long long baseSeed, int cbx, int cbz, int radius, bool fine,
                      const Weights& W, int climbBits, int climbLo, bool recurse,
                      int maxRounds, int T, const std::string& logDir, int topN,
                      bool images, const std::string& imgDir) {
    std::vector<Row> rows;
    Row origBest = bestRowFor(baseSeed, cbx, cbz, radius, fine, W, rows);
    if (origBest.blocks == 0 && origBest.chunks == 0) {
        fprintf(stderr, "[climb] base seed %lld scored nothing in range, skipping\n", baseSeed);
        return;
    }
    long long mask = ((1LL << climbBits) - 1) << climbLo;
    long long variantCount = 1LL << climbBits;
    printf("\n=== CLIMB base seed %lld: %.2f cq, sweeping bits %d-%d (%lld variants) ===\n",
           baseSeed, origBest.cq(), climbLo, climbLo + climbBits - 1, variantCount);

    long long curSeed = baseSeed;
    Row curBest = origBest;
    for (int round = 0; round < maxRounds; round++) {
        std::vector<Row> bestPerVariant(variantCount);
        std::vector<char> got(variantCount, 0);
        std::vector<std::thread> th;
        for (int t = 0; t < T; t++)
            th.emplace_back([&, t] {
                std::vector<Row> localRows;
                for (long long k = t; k < variantCount; k += T) {
                    long long v = (curSeed & ~mask) | (k << climbLo);
                    bestPerVariant[k] = bestRowFor(v, cbx, cbz, radius, fine, W, localRows);
                    got[k] = 1;
                }
            });
        for (auto& x : th) x.join();

        long long bestK = -1; Row roundBest{};
        for (long long k = 0; k < variantCount; k++) {
            if (!got[k]) continue;
            if (bestK < 0 || bestPerVariant[k].blocks > roundBest.blocks) { roundBest = bestPerVariant[k]; bestK = k; }
        }
        if (bestK < 0) { printf("  round %d: no variant scored in range\n", round + 1); break; }
        long long bestSeed = (curSeed & ~mask) | (bestK << climbLo);

        if (roundBest.blocks > curBest.blocks) {
            printf("  round %d: IMPROVEMENT %.2f cq -> %.2f cq  seed %lld\n",
                   round + 1, curBest.cq(), roundBest.cq(), bestSeed);
            curSeed = bestSeed; curBest = roundBest;
            if (!recurse) break;
        } else if (roundBest.blocks == curBest.blocks) {
            printf("  round %d: best variant ties the base (%.2f cq) - local plateau, no strict gain.\n",
                   round + 1, roundBest.cq());
            break;
        } else {
            printf("  round %d: best variant %.2f cq, below base %.2f cq - no gain here.\n",
                   round + 1, roundBest.cq(), curBest.cq());
            break;
        }
    }

    if (curSeed != baseSeed) {
        printf("=== CLIMB RESULT: %.2f cq -> %.2f cq (seed %lld -> %lld) ===\n",
               origBest.cq(), curBest.cq(), baseSeed, curSeed);
        // File it exactly like a normal find: same log/image path, so a
        // climb win shows up in main\scores\ next to everything else.
        std::vector<Row> finalRows;
        scoreSeed(curSeed, cbx, cbz, radius, fine, W, finalRows);
        if (!finalRows.empty())
            report(curSeed, cbx, cbz, radius, fine, 0, finalRows, logDir, topN, false, images, imgDir);
    } else {
        printf("=== CLIMB RESULT: no improvement over %.2f cq (seed %lld unchanged) ===\n",
               origBest.cq(), baseSeed);
    }
}

int main(int argc, char** argv) {
    int cbx = 2000, cbz = 8544, radius = 3, topN = 10, threads = 0, yOff = 0;
    bool fine = true, quiet = false, selftest = false, images = true;
    std::string seedFile, dir = "main/scores", csvOut, family;
    // --climb: see climbSeed() above for the mechanism. Off by default -
    // opt-in, so nothing about the existing workflow changes unless asked.
    bool climb = false, climbRecurse = false;
    int climbTop = 1, climbBits = 13, climbLo = 35, climbMaxRounds = 5;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto nx = [&](const char* f) -> const char* {
            if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", f); exit(1); } return argv[++i]; };
        if      (a == "--center-x")   cbx = atoi(nx("--center-x"));
        else if (a == "--center-z")   cbz = atoi(nx("--center-z"));
        else if (a == "--radius")     radius = atoi(nx("--radius"));
        else if (a == "--seeds")      seedFile = nx("--seeds");
        else if (a == "--out-dir")    dir = nx("--out-dir");
        else if (a == "--csv")        csvOut = nx("--csv");
        else if (a == "--top")        topN = atoi(nx("--top"));
        else if (a == "--threads")    threads = atoi(nx("--threads"));
        else if (a == "--chunk-aligned") fine = false;
        else if (a == "--fine")       fine = true;
        else if (a == "--quiet")      quiet = true;
        else if (a == "--self-test")  selftest = true;
        else if (a == "--images")     images = true;
        else if (a == "--no-images")  images = false;
        else if (a == "--family")     family = nx("--family");
        else if (a == "--climb")          climb = true;
        else if (a == "--climb-top")      climbTop = atoi(nx("--climb-top"));
        else if (a == "--climb-bits")      climbBits = atoi(nx("--climb-bits"));
        else if (a == "--climb-lo")        climbLo = atoi(nx("--climb-lo"));
        else if (a == "--climb-recurse")   climbRecurse = true;
        else if (a == "--climb-max-rounds") climbMaxRounds = atoi(nx("--climb-max-rounds"));
        else { fprintf(stderr,
            "usage: slime_refine --seeds seeds.csv --center-x X --center-z Z [--radius 3]\n"
            "  --fine            test every block offset (default, 256x the jar)\n"
            "  --chunk-aligned   only multiples of 16, what the jar did\n"
            "  --csv <file>      one summary row per seed, best cq first\n"
            "  --top N           rows per section (default 10)\n"
            "  --out-dir <d>     base for per-seed logs+images (default main/scores)\n"
            "  --family <name>   subfolder under the log/image bases; defaults to\n"
            "                    <x>_<z> so every hotspot keeps its own set\n"
            "  --images          write a PNG per seed (default on)\n"
            "  --no-images       skip the PNGs (batch scoring thousands)\n"
            "  --threads N       default: all cores\n"
            "                    ONE y only. 0 is the only value verified vs the jar.\n"
            "  --self-test       verify against SlimeFinder ground truth\n"
            "  --climb                 sweep high seed-bit neighbors of the best result(s)\n"
            "                          for a free extra fraction of cq (see slime_refine.cpp\n"
            "                          climbSeed() for the mechanism)\n"
            "  --climb-top N           climb the top N seeds by cq (default 1)\n"
            "  --climb-bits B          window width in bits, 2^B variants (default 13)\n"
            "  --climb-lo L            window starts at bit L, runs to 47 (default 35)\n"
            "  --climb-recurse         repeat the sweep centred on any improvement found\n"
            "  --climb-max-rounds N    cap on --climb-recurse rounds (default 5)\n");
            return 1; }
    }

    // Everything this run produces is filed under its family (the hotspot it
    // belongs to) in ONE combined folder - <seed>.txt and <seed>.png sit as
    // siblings, not split into separate seeds/images trees. Default family
    // name is the centre, so refining two spots never mixes their results.
    //   main/scores/<family>/<seed>.txt
    //   main/scores/<family>/<seed>.png
    if (family.empty()) family = std::to_string(cbx) + "_" + std::to_string(cbz);
    MKDIR("main");
    MKDIR(dir.c_str());        // main/scores
    std::string logDir = dir + "/" + family;
    std::string imgDir = logDir;
    MKDIR(logDir.c_str());

    Weights W(yOff);

    if (selftest) {
        printf("Self-test: must reproduce slimefinder.jar's fine phase exactly.\n\n");
        struct T { int bx, bz, blocks, chunks; } gt[3] =
            { {3680,6992,16821,70}, {3696,6992,16498,72}, {3680,6976,16496,68} };
        long long seed = 2452809435317741826LL;
        uint8_t disc[289]; buildIntersectMask(disc);
        int wt[289]; buildBlockWeights(wt);
        bool ok = true;
        for (int t = 0; t < 3; t++) {
            const int* tb = W.table(gt[t].bx & 15, gt[t].bz & 15);
            int blocks = 0, chunks = 0;
            int cx = gt[t].bx >> 4, cz = gt[t].bz >> 4;
            for (int dz = -8; dz <= 8; dz++) for (int dx = -8; dx <= 8; dx++) {
                int k = (dz + 8) * 17 + (dx + 8);
                if (!tb[k]) continue;
                if (isSlimeChunk(seed, cx + dx, cz + dz)) { blocks += tb[k]; chunks++; }
            }
            int cb = scoreCenterBlocks(wt, seed, cx, cz);
            int cc = scoreCenterChunks(disc, seed, cx, cz);
            bool m = blocks == gt[t].blocks && chunks == gt[t].chunks && cb == blocks && cc == chunks;
            printf("  (%d,%d)  blocks %5d/%-5d  chunks %2d/%-2d  -> %s\n",
                   gt[t].bx, gt[t].bz, blocks, gt[t].blocks, chunks, gt[t].chunks, m ? "OK" : "MISMATCH");
            if (!m) ok = false;
        }
        printf("\n%s\n", ok ? "SELF TEST PASSED." : "SELF TEST FAILED.");
        return ok ? 0 : 1;
    }

    // parse seeds: comma / space / newline, exactly like the jar prompt accepted
    std::vector<long long> seeds;
    {
        std::string cur; int ch; FILE* f = stdin;
        if (!seedFile.empty()) { f = fopen(seedFile.c_str(), "r");
            if (!f) { fprintf(stderr, "cannot read %s\n", seedFile.c_str()); return 1; } }
        else fprintf(stderr, "reading seeds from stdin...\n");
        while ((ch = fgetc(f)) != EOF) {
            if (ch == ',' || ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t') {
                if (cur.size()) { seeds.push_back(strtoll(cur.c_str(), nullptr, 10)); cur.clear(); }
            } else cur += (char)ch;
        }
        if (cur.size()) seeds.push_back(strtoll(cur.c_str(), nullptr, 10));
        if (!seedFile.empty()) fclose(f);
    }
    // Seed VALUES do not matter, only the low-48 layout. Many 64-bit seeds share
    // one, and scoring duplicates is wasted work and duplicate log files.
    {
        std::set<uint64_t> seen; std::vector<long long> u;
        for (size_t i = 0; i < seeds.size(); i++)
            if (seen.insert((uint64_t)seeds[i] & ((1ULL << 48) - 1)).second) u.push_back(seeds[i]);
        if (u.size() != seeds.size())
            printf("%zu seeds -> %zu unique low-48 layouts (%zu duplicates dropped)\n",
                   seeds.size(), u.size(), seeds.size() - u.size());
        seeds.swap(u);
    }
    if (seeds.empty()) { fprintf(stderr, "no seeds\n"); return 1; }


    int T = threads > 0 ? threads : (int)std::thread::hardware_concurrency();
    if (T < 1) T = 1;
    printf("%zu seeds, center (%d,%d), radius %d chunks, %s, %d thread(s)\n",
           seeds.size(), cbx, cbz, radius, fine ? "block resolution" : "chunk aligned", T);

    struct Sum { long long seed; Row bB, bC; };
    std::vector<Sum> sums(seeds.size());
    std::vector<char> done(seeds.size(), 0);
    std::mutex mio;
    std::vector<std::thread> th;
    for (int t = 0; t < T; t++)
        th.emplace_back([&, t] {
            std::vector<Row> rows;
            for (size_t i = t; i < seeds.size(); i += T) {
                rows.clear();
                scoreSeed(seeds[i], cbx, cbz, radius, fine, W, rows);
                if (rows.empty()) continue;
                std::vector<Row>::iterator bb = std::max_element(rows.begin(), rows.end(),
                    [](const Row& a, const Row& b) {
                        if (a.blocks != b.blocks) return a.blocks < b.blocks; return a.dist > b.dist; });
                std::vector<Row>::iterator bc = std::max_element(rows.begin(), rows.end(),
                    [](const Row& a, const Row& b) {
                        if (a.chunks != b.chunks) return a.chunks < b.chunks; return a.dist > b.dist; });
                sums[i] = Sum{ seeds[i], *bb, *bc }; done[i] = 1;
                std::lock_guard<std::mutex> g(mio);
                report(seeds[i], cbx, cbz, radius, fine, yOff, rows, logDir, topN, seeds.size() > 8, images, imgDir);
            }
        });
    for (size_t i = 0; i < th.size(); i++) th[i].join();

    std::vector<Sum> live;
    for (size_t i = 0; i < sums.size(); i++) if (done[i]) live.push_back(sums[i]);
    std::sort(live.begin(), live.end(), [](const Sum& a, const Sum& b) { return a.bB.blocks > b.bB.blocks; });

    printf("\n=== ALL SEEDS, BEST cq FIRST ===\n");
    printf("      cq    eff     c   cr   position            seed\n");
    for (size_t i = 0; i < live.size() && i < 20; i++) {
        const Sum& s = live[i];
        printf("  %6.2f  %5.1f%%  %3d  %3d   (%7d,%7d)  %lld\n",
               s.bB.cq(), s.bB.cq() / s.bB.chunks * 100, s.bB.chunks, s.bC.chunks,
               s.bB.bx, s.bB.bz, s.seed);
    }
    if (!csvOut.empty()) {
        FILE* f = fopen(csvOut.c_str(), "w");
        if (f) {
            fprintf(f, "cq,blocks,eff_pct,chunks_at_best_blocks,top_chunks,x,z,seed\n");
            for (size_t i = 0; i < live.size(); i++) {
                const Sum& s = live[i];
                fprintf(f, "%.2f,%d,%.1f,%d,%d,%d,%d,%lld\n", s.bB.cq(), s.bB.blocks,
                        s.bB.cq() / s.bB.chunks * 100, s.bB.chunks, s.bC.chunks,
                        s.bB.bx, s.bB.bz, s.seed);
            }
            fclose(f); printf("\nwrote %s\n", csvOut.c_str());
        }
    }
    printf("\nRANK ON cq, NOT CHUNKS. In your own data 70c at 93.9%% (65.71 cq) beats\n"
           "72c at 89.5%% (64.45 cq). 'c' is the chunk count at the best-blocks spot,\n"
           "'cr' is the highest chunk count anywhere for that seed.\n");

    if (climb && !live.empty()) {
        int n = std::min<int>(climbTop, (int)live.size());
        for (int i = 0; i < n; i++)
            climbSeed(live[i].seed, cbx, cbz, radius, fine, W, climbBits, climbLo,
                     climbRecurse, climbMaxRounds, T, logDir, topN, images, imgDir);
    }
    return 0;
}
