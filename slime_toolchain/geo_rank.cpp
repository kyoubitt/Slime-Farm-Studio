// geo_rank.cpp - the GEOMETRY PRIOR of a spot: how clustered the window's H values are, computed from the 222 chunk
// offsets alone - no family loop, no class loop, ~2,000 operations per grid position (the family cut costs 2^18 * 222).
// Why it predicts: B_i(c) = (8M * ((H_i + c) ^ C') + L_i) mod 2^31 with H_i = ((f + P_i) >> 20) & 0x7FFF, and H_i can
// only be (P_i >> 20) or that + 1 - the spot fixes every H difference up to 1, whatever the seed. Measured on the
// 1,724 searched spots (docs\PREDICTION.txt section 9): pairs of chunks with |dH| <= 512, minimum over the 15
// grid positions, correlates -0.29 with the spot's exact best count (heat: 0.10-0.23) and is nearly independent of
// heat (+0.15). The worst 40% of spots by it hold a 74+ at 1-2%, the rest at 6-7%: a free veto before any screening.
// Build: nvcc -O3 geo_rank.cpp -o geo_rank.exe
// Use:   geo_rank --spots spots.txt (lines X,Z in blocks) --out geo.csv [--threads 8] [--window 512]
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <vector>
#include <string>
#include <algorithm>
#include <thread>
#include <atomic>
#include "slime_core.h"
#include "portable_paths.h"
static uint64_t posOffset(long long cx, long long cz) {
    uint64_t p = 0;
    p += (uint64_t)(int64_t)(int32_t)((int64_t)cx * (int64_t)cx * 0x4c1906LL);
    p += (uint64_t)(int64_t)(int32_t)((int64_t)cx * 0x5ac0dbLL);
    p += (uint64_t)((int64_t)((int32_t)((int64_t)cz * (int64_t)cz)) * 0x4307a7LL);
    p += (uint64_t)(int64_t)(int32_t)((int64_t)cz * 0x5f24fLL);
    return p;
}
int main(int argc, char** argv) {
    slimeFixArgv(argc, argv);       // "\" -> "/" off Windows (portable_paths.h)
    std::string spots, out = "geo.csv"; int threads = 8, W = 512;
    for (int i = 1; i < argc; i++) { std::string k = argv[i]; auto nx = [&]() { return std::string(argv[++i]); };
        if (k == "--spots") spots = nx(); else if (k == "--out") out = nx(); else if (k == "--threads") threads = atoi(nx().c_str()); else if (k == "--window") W = atoi(nx().c_str()); }
    if (spots.empty()) { fprintf(stderr, "usage: geo_rank --spots spots.txt --out geo.csv [--threads 8] [--window 512]\n"); return 1; }
    uint8_t mask[17 * 17]; buildSpawnMask(mask); std::vector<int> DX, DZ;
    for (int dz = -8; dz <= 8; dz++) for (int dx = -8; dx <= 8; dx++) if (mask[(dz + 8) * 17 + (dx + 8)]) { DX.push_back(dx); DZ.push_back(dz); }
    const int n = (int)DX.size();
    std::vector<std::pair<long long, long long>> S;
    { FILE* fi = fopen(spots.c_str(), "r"); if (!fi) { fprintf(stderr, "cannot open %s\n", spots.c_str()); return 1; }
      char line[256]; long long X, Z; while (fgets(line, sizeof line, fi)) if (sscanf(line, "%lld,%lld", &X, &Z) == 2) S.push_back({ X, Z }); fclose(fi); }
    std::vector<int> res(S.size());
    std::atomic<size_t> next(0);
    auto work = [&]() {
        std::vector<int> H(n);
        for (size_t k; (k = next.fetch_add(64)) < S.size(); ) for (size_t q = k; q < k + 64 && q < S.size(); q++) {
            const long long pcx = (long long)std::floor(S[q].first / 16.0), pcz = (long long)std::floor(S[q].second / 16.0);
            int best = 1 << 30;
            for (int dz = -3; dz <= 3; dz += 3) for (int dx = -6; dx <= 6; dx += 3) {
                for (int i = 0; i < n; i++) H[i] = (int)((posOffset(pcx + dx + DX[i], pcz + dz + DZ[i]) >> 20) & 0x7FFF);
                std::sort(H.begin(), H.end());
                int pairs = 0, b = 0;                                  // sorted two-pointer, wrapping at 2^15
                for (int a = 0; a < n; a++) { if (b < a) b = a;
                    while (b + 1 < n && H[b + 1] - H[a] <= W) b++; pairs += b - a; }
                for (int a = 0; a < n; a++) { int c = 0;               // the wrap-around pairs
                    while (c < n && H[c] + 32768 - H[a] <= W) { if (c != a) pairs++; c++; } }
                best = std::min(best, pairs);
            }
            res[q] = best;
        } };
    std::vector<std::thread> T; for (int t = 0; t < threads; t++) T.emplace_back(work); for (auto& t : T) t.join();
    FILE* fo = fopen(out.c_str(), "w"); fprintf(fo, "X,Z,hpair\n");
    for (size_t q = 0; q < S.size(); q++) fprintf(fo, "%lld,%lld,%d\n", S[q].first, S[q].second, res[q]);
    fclose(fo);
    printf("%zu spots -> %s\n", S.size(), out.c_str());
    return 0;
}
