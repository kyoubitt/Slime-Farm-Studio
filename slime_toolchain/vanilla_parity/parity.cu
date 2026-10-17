// parity.cu - compares slime_core.h against bit files produced by GameOracle
// (i.e. by the real Minecraft jar). Both the CPU build and the GPU build of
// isSlimeChunk are checked, since nvcc compiles the same source twice.
//
//   parity cases <N> <game.bin>                       random/edge (seed,x,z)
//   parity map <seed> <cx0> <cz0> <w> <h> <game.bin>  a whole window
//   parity score <cx0> <cz0> <w> <h> <game.bin> <ccx> <ccz> <m> <gx> <gz>
//       best slime_gpu-style score (226-cell mask) over centres ccx+-m,
//       ccz+-m computed FROM THE GAME'S MAP, plus the score at (gx,gz) - to
//       check slime_gpu's own optimized kernels end to end.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
#include <cuda_runtime.h>
#include "../slime_core.h"

// ---- the same case generator as GameOracle.java -------------------------------
struct Gen {
    uint64_t s = 0x5EEDULL;
    uint64_t next() {
        uint64_t z = (s += 0x9E3779B97F4A7C15ULL);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
        return z ^ (z >> 31);
    }
};
static const long long SPECIAL[] = { 0LL, -1LL, (long long)0x8000000000000000ULL, 0x7FFFFFFFFFFFFFFFLL,
    9029506488461633794LL, -89761025938370956LL, -3918692359804081918LL,
    1LL << 48, (1LL << 48) - 1, 1LL << 47 };
static const int NSPECIAL = sizeof(SPECIAL) / sizeof(SPECIAL[0]);

static void genCase(Gen& g, long long i, long long& seed, int& x, int& z) {
    int k = (int)(i & 3);
    seed = (long long)g.next();
    if (k == 3) seed = SPECIAL[g.next() % NSPECIAL];
    if (k == 0) {
        x = (int)(g.next() % 4001) - 2000;
        z = (int)(g.next() % 4001) - 2000;
    } else if (k == 2) {
        x = (int32_t)(uint32_t)g.next();
        z = (int32_t)(uint32_t)g.next();
    } else {
        x = (int)(g.next() % 3750001) - 1875000;
        z = (int)(g.next() % 3750001) - 1875000;
    }
}

static std::vector<uint8_t> readBits(const char* path, long long n) {
    std::vector<uint8_t> b((n + 7) / 8);
    FILE* f = fopen(path, "rb");
    if (!f || fread(b.data(), 1, b.size(), f) != b.size()) { fprintf(stderr, "cannot read %s\n", path); exit(2); }
    fclose(f);
    return b;
}
static inline bool bit(const std::vector<uint8_t>& b, long long i) { return (b[i >> 3] >> (i & 7)) & 1; }

__global__ void gpuSlime(const long long* seeds, const int* xs, const int* zs, uint8_t* out, long long n) {
    long long i = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    if (i < n) out[i] = isSlimeChunk(seeds[i], xs[i], zs[i]) ? 1 : 0;
}

static void ck(cudaError_t e) { if (e != cudaSuccess) { fprintf(stderr, "CUDA: %s\n", cudaGetErrorString(e)); exit(2); } }

// Compare game bits vs CPU and GPU isSlimeChunk for an explicit case list.
static int compare(const char* label, const std::vector<long long>& S, const std::vector<int>& X,
                   const std::vector<int>& Z, const std::vector<uint8_t>& game) {
    long long n = (long long)S.size();
    long long *dS; int *dX, *dZ; uint8_t* dO;
    ck(cudaMalloc(&dS, n * 8)); ck(cudaMalloc(&dX, n * 4)); ck(cudaMalloc(&dZ, n * 4)); ck(cudaMalloc(&dO, n));
    ck(cudaMemcpy(dS, S.data(), n * 8, cudaMemcpyHostToDevice));
    ck(cudaMemcpy(dX, X.data(), n * 4, cudaMemcpyHostToDevice));
    ck(cudaMemcpy(dZ, Z.data(), n * 4, cudaMemcpyHostToDevice));
    gpuSlime<<<(unsigned)((n + 255) / 256), 256>>>(dS, dX, dZ, dO, n);
    ck(cudaGetLastError());
    std::vector<uint8_t> gpu(n);
    ck(cudaMemcpy(gpu.data(), dO, n, cudaMemcpyDeviceToHost));
    cudaFree(dS); cudaFree(dX); cudaFree(dZ); cudaFree(dO);

    long long badCpu = 0, badGpu = 0, slimes = 0;
    int shown = 0;
    for (long long i = 0; i < n; i++) {
        bool g = bit(game, i), c = isSlimeChunk(S[i], X[i], Z[i]), d = gpu[i] != 0;
        slimes += g;
        if (c != g) badCpu++;
        if (d != g) badGpu++;
        if ((c != g || d != g) && shown < 10) {
            shown++;
            printf("    MISMATCH seed %lld chunk (%d,%d): game %d cpu %d gpu %d\n", S[i], X[i], Z[i], g, c, d);
        }
    }
    printf("  %-34s %11lld chunks  game says %5.2f%% slime | cpu mismatches %lld | gpu mismatches %lld  -> %s\n",
           label, n, 100.0 * slimes / n, badCpu, badGpu, (badCpu || badGpu) ? "FAIL" : "OK");
    return (badCpu || badGpu) ? 1 : 0;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "see header\n"); return 2; }
    if (!strcmp(argv[1], "cases") && argc == 4) {
        long long n = atoll(argv[2]);
        auto game = readBits(argv[3], n);
        std::vector<long long> S(n); std::vector<int> X(n), Z(n);
        Gen g;
        for (long long i = 0; i < n; i++) genCase(g, i, S[i], X[i], Z[i]);
        return compare("random + edge-case chunks", S, X, Z, game);
    }
    if (!strcmp(argv[1], "map") && argc == 8) {
        long long seed = atoll(argv[2]);
        int cx0 = atoi(argv[3]), cz0 = atoi(argv[4]), w = atoi(argv[5]), h = atoi(argv[6]);
        long long n = (long long)w * h;
        auto game = readBits(argv[7], n);
        std::vector<long long> S(n, seed); std::vector<int> X(n), Z(n);
        for (long long i = 0; i < n; i++) { X[i] = cx0 + (int)(i % w); Z[i] = cz0 + (int)(i / w); }
        char label[96];
        snprintf(label, sizeof label, "map %dx%d @chunk(%d,%d)", w, h, cx0, cz0);
        return compare(label, S, X, Z, game);
    }
    if (!strcmp(argv[1], "score") && argc == 12) {
        int cx0 = atoi(argv[2]), cz0 = atoi(argv[3]), w = atoi(argv[4]), h = atoi(argv[5]);
        auto game = readBits(argv[6], (long long)w * h);
        int ccx = atoi(argv[7]), ccz = atoi(argv[8]), m = atoi(argv[9]), gx = atoi(argv[10]), gz = atoi(argv[11]);
        uint8_t mask[17 * 17];
        if (buildIntersectMask(mask) != 226) { fprintf(stderr, "mask != 226\n"); return 2; }
        auto at = [&](int x, int z) -> int {
            int ix = x - cx0, iz = z - cz0;
            if (ix < 0 || iz < 0 || ix >= w || iz >= h) { fprintf(stderr, "map too small for (%d,%d)\n", x, z); exit(2); }
            return bit(game, (long long)iz * w + ix);
        };
        // slime_core.h scoreCenterChunks semantics: the 226-cell disc minus the
        // 4 cells inside the 24-block no-spawn radius - what slime_gpu reports.
        auto score = [&](int cx, int cz) {
            int n = 0;
            for (int dz = -8; dz <= 8; dz++)
                for (int dx = -8; dx <= 8; dx++)
                    if (mask[(dz + 8) * 17 + (dx + 8)]) n += at(cx + dx, cz + dz);
            for (int i = 0; i < SLIME_EXCLUDED_N; i++) {
                int dx, dz; excludedCell(i, dx, dz);
                n -= at(cx + dx, cz + dz);
            }
            return n;
        };
        int best = -1;
        std::vector<std::pair<int,int> > where;
        for (int cz = ccz - m; cz <= ccz + m; cz++)
            for (int cx = ccx - m; cx <= ccx + m; cx++) {
                int s = score(cx, cz);
                if (s > best) { best = s; where.clear(); }
                if (s == best) where.push_back({cx, cz});
            }
        printf("%d %d", best, score(gx, gz));
        for (size_t i = 0; i < where.size() && i < 5; i++) printf(" (%d,%d)", where[i].first, where[i].second);
        printf("\n");
        return 0;
    }
    fprintf(stderr, "bad arguments - see header\n");
    return 2;
}
