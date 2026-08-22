// slime_core.h  v2
// ============================================================================
// Shared verbatim by slime_gpu, hotspot_scan and slime_refine. Validating one
// validates the scoring math of all three. Do not fork this file.
//
// WHAT CHANGED IN v2, AND WHY IT MATTERS
// ----------------------------------------------------------------------------
// v1 called itself an exact port of SlimeFinder's FAST-phase scoring, and it
// was. The fast phase is not the answer. Slimes cannot spawn within 24 blocks
// of a player, and SlimeFinder's fine phase knows this (its driver sets
// exclusion-sphere=true). v1 counted every chunk with a block inside radius
// 128, which includes FOUR chunks touching the AFK spot that can never spawn
// anything:
//
//        (0,0)  (-1,0)  (0,-1)  (-1,-1)
//
// Their farthest block centre is 21.2 blocks away, so all 256 of their columns
// sit inside the 24-block exclusion sphere. Measured over 2M random seeds at
// chunk(125,534), v1's chunk score was too high 33.2% of the time (+1: 27.1%,
// +2: 5.5%, +3: 0.6%).
//
// The correct eligibility test is an ANNULUS, not a disc:
//
//        24^2 < a^2 + b^2 <= 128^2          a = 16*dx + i, b = 16*dz + j
//
// Verified EXACT against SlimeFinder's own fine-phase output (blocks AND
// chunks) at three positions for seed 2452809435317741826:
//
//        (3680,6992)   16821 blocks / 70 chunks   MATCH
//        (3696,6992)   16498 blocks / 72 chunks   MATCH
//        (3680,6976)   16496 blocks / 68 chunks   MATCH
//
// Verified at y-offset 0, which is what slime_refine and the SlimeFinder driver
// use. A y-sweep makes both spheres 3D and the weights become per-y tables.
//
//                    v1 (disc r<=128)    v2 (annulus 24<d<=128)
//      mask cells          226                   222
//      max blocks        51433                 49640
//      max cq           200.91                193.91
//
// WHY buildIntersectMask STILL RETURNS 226
// ----------------------------------------------------------------------------
// slime_gpu's kernel packs the mask into row intervals (buildMaskIntervals),
// which requires every row to be ONE contiguous run of 1s. The four dead cells
// sit in the middle of rows -1 and 0, so an annulus mask has holes and the
// interval fast path would refuse to build. Rather than rewrite that kernel,
// the disc mask is kept and the four cells are SUBTRACTED afterwards - four
// extra lookups, exact same answer. That is what EXCLUDED_CELLS is for.
// ============================================================================

#pragma once
#include <cstdint>

#ifdef __CUDACC__
#define SLIME_FN __host__ __device__
// Shared by hotspot_scan.cu/slime_gpu.cu (both include cuda_runtime.h before
// this header). Guarded by __CUDACC__, not just "have we seen cuda_runtime.h" -
// confirmed empirically that nvcc does NOT define __CUDACC__ when compiling a
// plain .cpp (slime_refine.cpp), so this never applies there.
#include <cstdio>
#include <cstdlib>
#define CUDA_CHECK(call) do {                                               \
        cudaError_t err__ = (call);                                         \
        if (err__ != cudaSuccess) {                                         \
            fprintf(stderr, "CUDA error: %s at %s:%d\n",                    \
                    cudaGetErrorString(err__), __FILE__, __LINE__);         \
            exit(1);                                                        \
        }                                                                    \
    } while (0)
#else
#define SLIME_FN
#endif

#define SLIME_DESPAWN_R   128
#define SLIME_EXCLUSION_R  24

// ------------------------------------------------------------------
// Slime chunk test. Replicates Java int overflow and java.util.Random
// (initial scramble, next(31), nextInt(10) rejection loop) exactly.
// ------------------------------------------------------------------
SLIME_FN inline bool isSlimeChunk(long long worldSeed, int chunkX, int chunkZ) {
    // All wrapping arithmetic MUST be unsigned: signed overflow is undefined
    // behavior in C++ and miscompiles under constant folding / optimization.
    uint64_t seed = (uint64_t)worldSeed;
    seed += (uint64_t)(int64_t)(int32_t)((int64_t)chunkX * (int64_t)chunkX * 0x4c1906LL);
    seed += (uint64_t)(int64_t)(int32_t)((int64_t)chunkX * 0x5ac0dbLL);
    seed += (uint64_t)((int64_t)((int32_t)((int64_t)chunkZ * (int64_t)chunkZ)) * 0x4307a7LL);
    seed += (uint64_t)(int64_t)(int32_t)((int64_t)chunkZ * 0x5f24fLL);
    seed ^= 0x3ad8025fULL;

    const uint64_t MULT = 0x5DEECE66DULL;
    const uint64_t ADD  = 0xBULL;
    const uint64_t MASK = (1ULL << 48) - 1;
    uint64_t state = (seed ^ MULT) & MASK;

    for (;;) {
        state = (state * MULT + ADD) & MASK;
        int32_t bits = (int32_t)(state >> (48 - 31));
        int32_t val  = bits % 10;
        if (bits - val + 9 >= 0) return val == 0;
    }
}

// ------------------------------------------------------------------
// FAST-PHASE disc mask, 226 of 289. Kept because slime_gpu's row-interval
// kernel needs contiguous rows. NOT the spawn-eligibility answer on its own:
// subtract EXCLUDED_CELLS, or use buildBlockWeights.
// ------------------------------------------------------------------
inline int buildIntersectMask(uint8_t out[17 * 17]) {
    int count = 0;
    for (int dz = -8; dz <= 8; dz++) {
        for (int dx = -8; dx <= 8; dx++) {
            int hit = 0;
            for (int i = 0; i < 16 && !hit; i++) {
                long long a = 16LL * dx + i;
                for (int j = 0; j < 16; j++) {
                    long long b = 16LL * dz + j;
                    if (a * a + b * b <= (long long)SLIME_DESPAWN_R * SLIME_DESPAWN_R) { hit = 1; break; }
                }
            }
            out[(dz + 8) * 17 + (dx + 8)] = (uint8_t)hit;
            count += hit;
        }
    }
    return count; // 226
}

// The four chunks entirely inside the exclusion sphere. In the disc mask but
// unable to spawn anything. Subtract these from any disc-mask chunk count.
#define SLIME_EXCLUDED_N 4
SLIME_FN inline void excludedCell(int i, int& dx, int& dz) {
    const int X[4] = { 0, -1,  0, -1 };
    const int Z[4] = { 0,  0, -1, -1 };
    dx = X[i]; dz = Z[i];
}

// ------------------------------------------------------------------
// FINE-PHASE block weights: how many of a chunk's 256 columns are spawn
// eligible. w == 0 for the four excluded cells and everything outside 128.
// blocks = SUM isSlimeChunk(cell) * w(cell);  cq = blocks / 256.
// Returns total eligible blocks (49640).
// ------------------------------------------------------------------
inline int buildBlockWeights(int out[17 * 17]) {
    const long long RD = (long long)SLIME_DESPAWN_R * SLIME_DESPAWN_R;
    const long long RE = (long long)SLIME_EXCLUSION_R * SLIME_EXCLUSION_R;
    int total = 0;
    for (int dz = -8; dz <= 8; dz++) {
        for (int dx = -8; dx <= 8; dx++) {
            int w = 0;
            for (int i = 0; i < 16; i++) {
                long long a = 16LL * dx + i;
                for (int j = 0; j < 16; j++) {
                    long long b = 16LL * dz + j;
                    long long d2 = a * a + b * b;
                    if (d2 <= RD && d2 > RE) w++;
                }
            }
            out[(dz + 8) * 17 + (dx + 8)] = w;
            total += w;
        }
    }
    return total; // 49640
}

// True spawn mask (222 cells). NOT row-contiguous - do not feed to
// buildMaskIntervals.
inline int buildSpawnMask(uint8_t out[17 * 17]) {
    int w[17 * 17]; buildBlockWeights(w);
    int n = 0;
    for (int i = 0; i < 17 * 17; i++) { out[i] = w[i] ? 1 : 0; n += out[i] ? 1 : 0; }
    return n; // 222
}

// ------------------------------------------------------------------
// Scoring. scoreCenterFast is v1's disc count, kept for compatibility and for
// the interval kernel; it OVERSTATES. scoreCenterChunks is the real one.
// ------------------------------------------------------------------
SLIME_FN inline int scoreCenterFast(const uint8_t* mask, long long seed, int cx, int cz) {
    int count = 0;
    for (int dz = -8; dz <= 8; dz++)
        for (int dx = -8; dx <= 8; dx++)
            if (mask[(dz + 8) * 17 + (dx + 8)] && isSlimeChunk(seed, cx + dx, cz + dz)) count++;
    return count;
}
// Back-compat alias. Existing callers keep compiling; the name now says what it
// is rather than pretending to be the answer.
SLIME_FN inline int scoreCenter(const uint8_t* mask, long long seed, int cx, int cz) {
    return scoreCenterFast(mask, seed, cx, cz);
}
// Correct chunk score: disc count minus the four dead cells.
SLIME_FN inline int excludedSlimeCount(long long seed, int cx, int cz) {
    int n = 0;
    for (int i = 0; i < SLIME_EXCLUDED_N; i++) {
        int dx, dz; excludedCell(i, dx, dz);
        if (isSlimeChunk(seed, cx + dx, cz + dz)) n++;
    }
    return n;
}
SLIME_FN inline int scoreCenterChunks(const uint8_t* discMask, long long seed, int cx, int cz) {
    return scoreCenterFast(discMask, seed, cx, cz) - excludedSlimeCount(seed, cx, cz);
}
// Eligible spawn blocks. cq = blocks / 256.0
SLIME_FN inline int scoreCenterBlocks(const int* weights, long long seed, int cx, int cz) {
    int blocks = 0;
    for (int dz = -8; dz <= 8; dz++)
        for (int dx = -8; dx <= 8; dx++) {
            int w = weights[(dz + 8) * 17 + (dx + 8)];
            if (w && isSlimeChunk(seed, cx + dx, cz + dz)) blocks += w;
        }
    return blocks;
}

// ------------------------------------------------------------------
// Row intervals of the DISC mask for slime_gpu's packed kernel. Every disc row
// is one contiguous run (verified programmatically). Returns false if that ever
// fails, in which case callers must abort. Do not pass the spawn mask here.
// ------------------------------------------------------------------
inline bool buildMaskIntervals(const uint8_t mask[17 * 17], int8_t A[17], int8_t B[17]) {
    for (int r = 0; r < 17; r++) {
        int a = 99, b = -99, transitions = 0, prev = 0;
        for (int c = 0; c < 17; c++) {
            int v = mask[r * 17 + c];
            if (v) { if (a == 99) a = c - 8; b = c - 8; }
            if (v != prev) transitions++;
            prev = v;
        }
        if (prev) transitions++;
        if (transitions != 2 || a == 99) return false;
        A[r] = (int8_t)a;
        B[r] = (int8_t)b;
    }
    return true;
}
