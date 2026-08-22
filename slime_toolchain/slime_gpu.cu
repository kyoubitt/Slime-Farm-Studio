// slime_gpu.cu - GPU multi-seed slime chunk searcher (THE HUNT: given a mask,
// grinds seeds looking for one that scores >= --record-floor at a fixed spot).
//
// Scoring is exactly identical to the SlimeFinder Java tool's fast phase: the
// scoring math in slime_core.h and the prefix-interval algorithm the kernels
// below use were both validated against the UNTOUCHED SlimeFinder release jar
// (exact row-for-row match). Row intervals: every row of the 17x17 despawn
// mask is one contiguous run (verified programmatically), so each row's count
// is one masked popcount instead of testing 289 cells individually - see
// computeStripCounts(). Run --self-test before trusting anything this prints.
//
// --fix-mask/--fix-val force generated seeds into a low-bit residue class
// (from hotspot_scan's derivation) to make high-score tail hits ~100-1000x
// more common at a fixed hotspot. Default run is unconstrained; the fused
// kernel (whole-bitmap-in-shared, no global round-trip) is the DEFAULT and
// only engages when the window fits the shared-memory budget - larger windows
// fall back to the two-kernel path automatically. --no-fused forces that path.
// Fused is 2.04x faster at hunt sizes because the two-kernel path is memory-
// bound on a heavily padded global bitmap (see rowWords32), and it is proven
// output-identical under a fixed --rng-seed, not merely assumed equivalent.
//
// Correctness invariant worth knowing before touching the hit-packing scheme
// (hits[] in scoreHitsKernel/huntFusedKernel): the seed index needs the full
// 16 bits ([63:48]) it has today - batches can reach 65535 (grid.y/z limit),
// and a narrower field silently wraps and saves the WRONG seed for any hit
// past the wrap point. Score gets 10 bits ([47:38]), position the remaining
// 38 (guarded in runHits/runHitsFused against m too large to fit).
//
// Build (Windows, x64 Native Tools Command Prompt):
//   nvcc -O3 -arch=native slime_gpu.cu -o slime_gpu.exe
//
// Usage:
//   slime_gpu.exe --self-test
//   slime_gpu.exe --seed 71629181566 --m-chunks 64
//   slime_gpu.exe --seed-count 0 --m-chunks 625 --report-every 5000
//   slime_gpu.exe --seed-count 0 --m-chunks 6250 --quick-m-chunks 350 --quick-threshold 45
//   slime_gpu.exe --climb-scan --seed <s> --center-x X --center-z Z --m-chunks 6
//       (GPU-coarse high-bit neighbor sweep - see README.txt BUILT: GPU-ACCELERATED CLIMB)

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <random>
#include <chrono>
#include <string>
#include <vector>
#include <algorithm>
#include <set>
#include <iostream>
#include <cuda_runtime.h>

#ifdef _WIN32
  #include <direct.h>
  #define SG_MKDIR(d) _mkdir(d)
#else
  #include <sys/stat.h>
  #define SG_MKDIR(d) mkdir(d, 0755)
#endif

#include "slime_core.h"

// CUDA_CHECK is defined in slime_core.h (shared with hotspot_scan.cu).

// Per-row [LO, LO+WD-1] column window of the 17-row disc mask. Single source
// of truth for both the FATAL literal-mismatch check in main() (unchanged,
// still guards the hand-unrolled VROW/FROW macros below) and the new
// per-row weight-plane masks --climb-scan uses - both must agree with the
// SAME geometry or neither can be trusted.
static const int kRowLO[17] = {4,2,1,1,0,0,0,0,0,0,0,0,1,1,2,4,8};
static const int kRowWD[17] = {8,12,14,14,16,16,16,16,17,16,16,16,14,14,12,8,1};

// 9 weight-bit-plane masks per row (blocks = SUM 2^p * popcount(rowBits &
// plane[row][p])). Built once from slime_core.h's buildBlockWeights, which
// already zeroes the four cells inside the 24-block exclusion sphere - so
// unlike the chunk-count kernels below, no separate exclusion subtraction is
// needed here: a weight of 0 sets no plane bit, contributing 0 blocks
// automatically. See --climb-scan / cqScoreKernel.
__constant__ uint32_t cRowPlaneMask[17 * 9];

// Launch geometry for the score/hit kernels, derived from m ALONE.
//
// This exists so rowWords32() below and the three dispatchers in GpuEngine
// cannot drift apart. The row stride has to be at least as wide as the
// furthest word any launch can read, and "the furthest word any launch can
// read" is a function of the block size and strip length the dispatcher picks
// - so both sides must compute those the same way, from one place. Previously
// the dispatcher derived them inline and rowWords32 covered the difference
// with a blanket 72-word guard.
struct StripPlan { int sthreads; int G; int S; int needWords; };
__host__ __device__ inline StripPlan stripPlan(int m) {
    const int threads = 256;
    long long cside = 2LL * m + 1;
    int sthreads = threads;
    // Small windows (hotspot hunting) get a smaller block so threads are not
    // idle - at m=24 (cside=49) a 256-thread block is 19% utilized, 64 is 77%.
    if (cside < threads) {
        sthreads = (int)(((cside + 31) / 32) * 32);
        if (sthreads < 32) sthreads = 32;
    }
    // adaptive strip: G blocks/row at max capacity, then the smallest strip
    // length that still covers the row -> ~98% thread utilization
    long long cap8 = (long long)sthreads * 8;
    int G = (int)((cside + cap8 - 1) / cap8);
    int S = (int)((cside + (long long)sthreads * G - 1) / ((long long)sthreads * G));
    if (S < 1) S = 1;
    if (S > 8) S = 8;
    // Exactly the expression stageRows() uses for its copy bound.
    int needWords = ((S * (sthreads - 1) + 8) >> 5) + 2;
    return StripPlan{ sthreads, G, S, needWords };
}

// Row stride in 32-bit words. Rows are BIT-PACKED, one bit per chunk, 32 chunks
// per uint32.
//
// This used to be `roundUpTo32(WR) + 72` at every m. That guard was sized for
// the STRIP=8 / blockDim=256 worst case but applied unconditionally, and at
// hunt sizes it dominates the allocation completely: at m=24 a row carries 3
// real words and was given 104; at m=6 it carries 1 and was given 104. The
// bitmap is written by bitKernel and read straight back by the score kernel, so
// that padding is not merely wasted VRAM - it is wasted BANDWIDTH, twice, and
// it is what made the two-kernel hunt memory-bound (measured 20.5M seeds/s
// versus 41.9M for the fused path, which skips the round trip entirely).
//
// Now sized to what a launch can actually touch:
//   furthest word = (largest block start offset >> 5) + needWords
// where both terms come from stripPlan(m) above, the same values the dispatcher
// uses. Kept at least WR so bitKernel's own writes always fit, plus one word of
// slack, and rounded to 8 words (32 B) to keep row bases sector-friendly.
// Guard/pad words may still hold garbage; the score kernel's width masks
// provably exclude them from every scored value, unchanged.
__host__ __device__ inline long long rowWords32(int m) {
    long long side = 2LL * m + 17;
    long long WR = (side + 31) / 32;
    StripPlan p = stripPlan(m);
    long long maxStart = ((long long)(p.G - 1) * p.sthreads * p.S) >> 5;
    long long need = maxStart + p.needWords;
    long long words = (WR > need ? WR : need) + 1;
    return ((words + 7) / 8) * 8;
}

// v7 fast RNG path. Both replacements EXHAUSTIVELY verified against Java's
// exact semantics over all 2^31 possible next(31) outputs (0 mismatches):
//   - Java's rejection loop condition  <=>  bits >= 2147483640
//   - bits % 10 == 0  <=>  ror32(bits * 0xCCCCCCCD, 1) <= 0x19999999
__device__ inline bool fastSlimeFromSeed(uint64_t seedExpr) {
    seedExpr ^= 0x3ad8025fULL;
    const uint64_t M = 0x5DEECE66DULL, A = 0xBULL, MASK = (1ULL << 48) - 1;
    uint64_t st = (seedExpr ^ M) & MASK;
    for (;;) {
        st = (st * M + A) & MASK;
        uint32_t bits = (uint32_t)(st >> 17);
        if (bits < 2147483640u) {
            uint32_t r = bits * 0xCCCCCCCDu;
            return ((r >> 1) | (r << 31)) <= 0x19999999u;
        }
    }
}

// ------------------------------------------------------------------
// SEED GENERATION ON THE GPU.
//
// The hunt used to build each batch of seeds on the CPU with mt19937_64 and
// then cudaMemcpy them across, which serialises three stages that could all be
// avoided: [CPU RNG] -> [H2D copy] -> [kernel] -> [blocking D2H]. Nothing
// overlaps, so the GPU sits idle for the whole CPU leg. Measured on this box
// during a live cycle: slime_gpu held the GPU at only 55% utilization, while
// hotspot_scan - which derives its seeds IN-KERNEL from splitmix64(base + j) -
// held it at 89%. Same GPU, same hour; the difference is where the seeds come
// from.
//
// So: same trick as hotspot_scan, which is already validated and already the
// faster of the two. splitmix64 over consecutive integers is exactly what that
// tool samples with (and is SplitMix64's designed use - it is the standard
// seeding generator for xoshiro), so this is an established pattern here, not
// a new one.
//
// The host still needs the actual seed VALUE to print and to save a hit, but
// hits are rare, so it recomputes just those from the same function rather
// than copying the whole batch back. huntSeedAt is __host__ __device__ for
// exactly that reason - one definition, so the two sides cannot disagree.
__host__ __device__ inline uint64_t sg_splitmix64(uint64_t x) {
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}
// Seed number `idx` of the hunt stream rooted at `base`, with the family
// constraint applied. Index is GLOBAL across batches (batchBase + i), so a
// batch boundary changes nothing about which seeds get drawn.
__host__ __device__ inline long long huntSeedAt(uint64_t base, long long idx,
                                                unsigned long long fixMask,
                                                unsigned long long fixVal) {
    uint64_t w = sg_splitmix64(base + (uint64_t)idx);
    return (long long)((w & ~fixMask) | (fixVal & fixMask));
}
__global__ void genSeedsKernel(long long* __restrict__ out, int n, uint64_t base,
                               long long idxBase,
                               unsigned long long fixMask, unsigned long long fixVal) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    out[i] = huntSeedAt(base, idxBase + i, fixMask, fixVal);
}

// ------------------------------------------------------------------
// Kernel 1 (v4): per-row prefix sums, block-cooperative and COALESCED.
// One BLOCK per (row, seed). 256 threads evaluate 256 consecutive chunks,
// combine via warp-shuffle inclusive scan, and write 256 adjacent prefix
// entries per tile - adjacent threads hit adjacent addresses, fixing the
// 94% uncoalesced-access problem the profiler found in v2/v3.
// Integer addition is associative, so the output is bit-identical to the
// sequential version validated against the untouched Java jar.
// ------------------------------------------------------------------
__global__ void __launch_bounds__(256, 6)
bitKernel(uint32_t* __restrict__ bits,
                          const long long* __restrict__ seeds,
                          int m, int ccx, int ccz) {
    // One thread = one 32-chunk word of one row. No cooperation, no scans,
    // no __syncthreads (v7's 31% barrier stalls are gone by construction),
    // and stores are 16x smaller than the uint16 prefix they replace.
    long long side = 2LL * m + 17;
    long long WR = (side + 31) / 32;        // real words per row
    long long rowWords = rowWords32(m);
    int s = blockIdx.y;
    long long t = (long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (t >= side * WR) return;
    long long r = t / WR;
    int w = (int)(t % WR);

    long long seed = seeds[s];
    int off = m + 8;
    int kz = (int)r - off + ccz;      // window centered on chunk (ccx, ccz)

    uint64_t rowBase = (uint64_t)seed
        + (uint64_t)((int64_t)((int32_t)((int64_t)kz * (int64_t)kz)) * 0x4307a7LL)
        + (uint64_t)(int64_t)(int32_t)((int64_t)kz * 0x5f24fLL);

    // stride-1 incremental x-terms (validated bit-exact: incr_test, 1.12M
    // positions, 0 mismatches)
    const uint32_t C1 = 0x4c1906u, C2 = 0x5ac0dbu;
    int x0 = (int)(w * 32) - off + ccx;
    uint32_t iu = (uint32_t)((int64_t)x0 * (int64_t)x0 * (int64_t)C1);
    uint32_t id = (uint32_t)((2LL * x0 + 1) * (int64_t)C1);
    uint32_t iv = (uint32_t)((int64_t)x0 * (int64_t)C2);

    uint32_t acc = 0;
    long long jBase = (long long)w * 32;
    #pragma unroll 4
    for (int c = 0; c < 32; c++) {
        if (jBase + c >= side) break;
        uint64_t seedExpr = rowBase + (uint64_t)(int64_t)(int32_t)iu
                                    + (uint64_t)(int64_t)(int32_t)iv;
        if (fastSlimeFromSeed(seedExpr)) acc |= 1u << c;
        iu += id; id += 2 * C1; iv += C2;
    }
    bits[((long long)s * side + r) * rowWords + w] = acc;   // coalesced
}

// ------------------------------------------------------------------
// Kernel 2 (v6): score via interval differences over STAGED shared memory.
// Division-free indexing: grid.x covers cx, grid.y = cz row, grid.z = seed
// (v4 computed cx,cz with 64-bit div/mod - a ~50-100 instruction sequence
// per thread on consumer GPUs, pure waste in a compute-bound kernel).
// Reduction: warp-shuffle max + one shared step (1 sync instead of 8).
// packed = (score << 40) | ((cz+m)*cside + (cx+m)) - identical values and
// tie-break to v2/v4 and the CPU reference, so results cannot differ.
// ------------------------------------------------------------------
// Shared strip scoring: computes the despawn-circle chunk count for STRIP
// consecutive positions from the staged bit rows. Used by BOTH the
// reduction kernel (self-test / single-seed verification path) and the
// hit-collection kernel (hunt path), so the validated math cannot diverge.
template <int STRIP>
__device__ __forceinline__ void computeStripCounts(
        const uint32_t* __restrict__ stage, int lj0, int* counts) {
    // Shared row stride, sized to the most any thread can read for this STRIP
    // at the largest block (blockDim=256): needWords = ((STRIP*255+8)>>5)+2,
    // +1 slack. Was a fixed 68 - oversized for small STRIP, which inflated the
    // __shared__ array and (per the m=24 profile) capped occupancy at 70.8%.
    // STRIP=1 -> 11 (hunt), STRIP=8 -> 67 (unchanged from 68 in practice).
    constexpr int SST = ((STRIP * 255 + 8) >> 5) + 3;
    #define VROW(K, LOK, MASKK) {                                          \
        int p = lj0 + (LOK);                                               \
        uint32_t w0 = stage[(K) * SST + (p >> 5)];                         \
        uint32_t w1 = stage[(K) * SST + (p >> 5) + 1];                     \
        unsigned long long V = ((unsigned long long)w1 << 32) | w0;       \
        int shift0 = p & 31;                                               \
        _Pragma("unroll")                                                  \
        for (int c = 0; c < STRIP; c++)                                    \
            counts[c] += __popc((unsigned)(V >> (shift0 + c)) & (MASKK));  \
    }
    VROW(0,4,0xFFu)     VROW(1,2,0xFFFu)    VROW(2,1,0x3FFFu)
    VROW(3,1,0x3FFFu)   VROW(4,0,0xFFFFu)   VROW(5,0,0xFFFFu)
    VROW(6,0,0xFFFFu)   VROW(7,0,0xFFFFu)   VROW(8,0,0x1FFFFu)
    VROW(9,0,0xFFFFu)   VROW(10,0,0xFFFFu)  VROW(11,0,0xFFFFu)
    VROW(12,1,0x3FFFu)  VROW(13,1,0x3FFFu)  VROW(14,2,0xFFFu)
    VROW(15,4,0xFFu)    VROW(16,8,0x1u)
    #undef VROW
    // --- v23 CORRECTNESS FIX (see scoreCenterShared for the full reasoning) --
    // Subtract the four chunks inside the 24-block exclusion sphere, which the
    // disc mask counts but which can never spawn: (0,0) (-1,0) (0,-1) (-1,-1).
    // VROW(16,8,0x1u) puts centre c at column lj0+8+c, so the four cells are
    // columns lj0+7+c and lj0+8+c on rows K=7 (dz=-1) and K=8 (dz=0). Both
    // those rows have LOK=0, so bits 0 and 1 of a read at p=lj0+7 are exactly
    // dx=-1 and dx=0. Two loads per row, one popcount per centre.
    {
        int p = lj0 + 7;
        uint32_t a0 = stage[8 * SST + (p >> 5)], a1 = stage[8 * SST + (p >> 5) + 1];
        uint32_t b0 = stage[7 * SST + (p >> 5)], b1 = stage[7 * SST + (p >> 5) + 1];
        unsigned long long V8 = ((unsigned long long)a1 << 32) | a0;
        unsigned long long V7 = ((unsigned long long)b1 << 32) | b0;
        int shift0 = p & 31;
        #pragma unroll
        for (int c = 0; c < STRIP; c++) {
            counts[c] -= __popc((unsigned)(V8 >> (shift0 + c)) & 0x3u);
            counts[c] -= __popc((unsigned)(V7 >> (shift0 + c)) & 0x3u);
        }
    }
}

// --climb-scan: exact BLOCKS (not chunk count) for STRIP consecutive
// positions, from the SAME staged bitmap computeStripCounts reads - this is
// the context where the README's original "9 popcounts" idea actually pays
// off (unlike hotspot_scan's fixed-single-centre case): many overlapping
// positions reuse one staged bitmap, so 9 popcounts/row here is cheap next to
// the 1 popcount/row computeStripCounts already does, and both are cheap
// next to the LCG bitmap generation that dominates either way. No exclusion-
// cell subtraction needed (unlike computeStripCounts above): cRowPlaneMask is
// built from slime_core.h's buildBlockWeights, which already zeroes the four
// excluded cells' weight, so they contribute 0 blocks automatically.
template <int STRIP>
__device__ __forceinline__ void computeStripBlocks(
        const uint32_t* __restrict__ stage, int lj0, int* blocks) {
    constexpr int SST = ((STRIP * 255 + 8) >> 5) + 3;
    #define VROWB(K, LOK, MASKK) {                                             \
        int p = lj0 + (LOK);                                                  \
        uint32_t w0 = stage[(K) * SST + (p >> 5)];                            \
        uint32_t w1 = stage[(K) * SST + (p >> 5) + 1];                        \
        unsigned long long V = ((unsigned long long)w1 << 32) | w0;          \
        int shift0 = p & 31;                                                  \
        _Pragma("unroll")                                                     \
        for (int c = 0; c < STRIP; c++) {                                     \
            uint32_t rowBits = (uint32_t)(V >> (shift0 + c)) & (MASKK);       \
            _Pragma("unroll")                                                 \
            for (int pl = 0; pl < 9; pl++)                                    \
                blocks[c] += (1 << pl) * __popc(rowBits & cRowPlaneMask[(K) * 9 + pl]); \
        }                                                                      \
    }
    VROWB(0,4,0xFFu)     VROWB(1,2,0xFFFu)    VROWB(2,1,0x3FFFu)
    VROWB(3,1,0x3FFFu)   VROWB(4,0,0xFFFFu)   VROWB(5,0,0xFFFFu)
    VROWB(6,0,0xFFFFu)   VROWB(7,0,0xFFFFu)   VROWB(8,0,0x1FFFFu)
    VROWB(9,0,0xFFFFu)   VROWB(10,0,0xFFFFu)  VROWB(11,0,0xFFFFu)
    VROWB(12,1,0x3FFFu)  VROWB(13,1,0x3FFFu)  VROWB(14,2,0xFFFu)
    VROWB(15,4,0xFFu)    VROWB(16,8,0x1u)
    #undef VROWB
}

// v18 (fused hunt): score ONE center (cx,cz) by reading the full bitmap held
// in shared memory (row stride SWR), instead of a per-block staged strip. The
// per-row LO offsets and mask widths are IDENTICAL to computeStripCounts'
// VROW rows, so this yields the exact same score - just sourced from the whole
// in-shared bitmap (no re-staging, no global round-trip). Host-verified against
// slime_core.h over full windows (incl. real record seeds).
__device__ __forceinline__ int scoreCenterShared(
        const uint32_t* __restrict__ sbits, int SWR, int cx, int cz) {
    int count = 0;
    #define FROW(K, LOK, MASKK) {                                        \
        int p = cx + (LOK);                                              \
        const uint32_t* row = sbits + (long long)(cz + (K)) * SWR;       \
        uint32_t w0 = row[p >> 5];                                       \
        uint32_t w1 = row[(p >> 5) + 1];                                 \
        unsigned long long V = ((unsigned long long)w1 << 32) | w0;      \
        count += __popc((unsigned)(V >> (p & 31)) & (MASKK));            \
    }
    FROW(0,4,0xFFu)     FROW(1,2,0xFFFu)    FROW(2,1,0x3FFFu)
    FROW(3,1,0x3FFFu)   FROW(4,0,0xFFFFu)   FROW(5,0,0xFFFFu)
    FROW(6,0,0xFFFFu)   FROW(7,0,0xFFFFu)   FROW(8,0,0x1FFFFu)
    FROW(9,0,0xFFFFu)   FROW(10,0,0xFFFFu)  FROW(11,0,0xFFFFu)
    FROW(12,1,0x3FFFu)  FROW(13,1,0x3FFFu)  FROW(14,2,0xFFFu)
    FROW(15,4,0xFFu)    FROW(16,8,0x1u)
    #undef FROW
    // --- v23 CORRECTNESS FIX -------------------------------------------------
    // Slimes cannot spawn within 24 blocks of a player. Four chunks touch the
    // AFK spot and lie ENTIRELY inside that exclusion sphere - their farthest
    // block centre is 21.2 blocks out - so they can never spawn anything:
    //     (0,0)  (-1,0)  (0,-1)  (-1,-1)
    // The 226-cell disc mask counts all four. Measured over 2M random seeds at
    // chunk(125,534) the old score was too high 33.2% of the time (+1: 27.1%,
    // +2: 5.5%, +3: 0.6%), and on a real hit at (3680,6976) it read 70 when
    // SlimeFinder's fine phase says 68.
    //
    // The fix is NOT a new mask: the true 222-cell mask has holes in rows -1
    // and 0, so buildMaskIntervals would refuse to build and this kernel would
    // not launch. Instead keep the disc rows and subtract the four cells. They
    // sit at fixed positions: rows K=7 (dz=-1) and K=8 (dz=0), bits 7 and 8
    // (dx=-1 and dx=0), both rows having LOK=0. Two loads, two popcounts.
    {
        int p = cx + 7;
        const uint32_t* r8 = sbits + (long long)(cz + 8) * SWR;
        const uint32_t* r7 = sbits + (long long)(cz + 7) * SWR;
        unsigned long long V8 = ((unsigned long long)r8[(p >> 5) + 1] << 32) | r8[p >> 5];
        unsigned long long V7 = ((unsigned long long)r7[(p >> 5) + 1] << 32) | r7[p >> 5];
        count -= __popc((unsigned)(V8 >> (p & 31)) & 0x3u);
        count -= __popc((unsigned)(V7 >> (p & 31)) & 0x3u);
    }
    return count;
}

// Both kernels stage the bit rows into shared memory, then read them via
// computeStripCounts, which only ever touches words up to
// ((STRIP*(blockDim-1)+8)>>5)+1 (LO[K] max = 8; a read touches words w and
// w+1) - so staging exactly that many (needWords below), not a fixed worst
// case, cuts shared+global staging traffic ~16x at hunt-mode sizes (STRIP=1,
// blockDim=64) versus the STRIP=8/blockDim=256 worst case. Unread stage
// words are never touched, so this cannot change any scored value (verified
// safe for every (STRIP,blockDim) combination the dispatcher can emit, via a
// host simulation). The main phase keeps a straddle-free 32-word-multiple
// layout (coalesced, no warp crosses a row boundary); the remainder is
// interleaved across rows so no thread sits idle even when needWords < 32.
template <int STRIP>
__device__ __forceinline__ void stageRows(
        uint32_t* __restrict__ stage,
        const uint32_t* __restrict__ rowsBase,
        long long rowWords) {
    constexpr int SST = ((STRIP * 255 + 8) >> 5) + 3;   // shared row stride
    const int needWords = ((STRIP * ((int)blockDim.x - 1) + 8) >> 5) + 2; // <= SST-1
    const int mainW = needWords & ~31;      // 0, 32, or 64 (multiple of 32)
    if (mainW == 64) {
        for (int e = threadIdx.x; e < 17 * 64; e += blockDim.x) {
            int rk = e >> 6, k = e & 63;
            stage[rk * SST + k] = rowsBase[(long long)rk * rowWords + k];
        }
    } else if (mainW == 32) {
        for (int e = threadIdx.x; e < 17 * 32; e += blockDim.x) {
            int rk = e >> 5, k = e & 31;
            stage[rk * SST + k] = rowsBase[(long long)rk * rowWords + k];
        }
    }
    const int tailW = needWords - mainW;    // 0..31 (for small m this is all of it)
    if (tailW > 0) {
        for (int e = threadIdx.x; e < 17 * tailW; e += blockDim.x) {
            int rk = e / tailW;
            int k  = mainW + (e - rk * tailW);
            stage[rk * SST + k] = rowsBase[(long long)rk * rowWords + k];
        }
    }
}

template <int STRIP>
__global__ void __launch_bounds__(256, 5)
scoreKernel(const uint32_t* __restrict__ bits,
            int m, unsigned long long* __restrict__ bests) {
    // Adaptive strip length: the host picks STRIP (1..8) per launch so ~98%
    // of threads have real positions at every m (a fixed STRIP left 39-80%
    // idle whenever cside mod 2048 was small). __launch_bounds__(256,5)
    // recovers occupancy the per-thread counters would otherwise cost.
    constexpr int SST = ((STRIP * 255 + 8) >> 5) + 3;   // per-STRIP shared stride
    __shared__ uint32_t stage[17 * SST];
    __shared__ unsigned long long warpMax[8];

    int s = blockIdx.z;
    long long side = 2LL * m + 17;
    long long rowWords = rowWords32(m);
    long long cside = 2LL * m + 1;
    long long rz = blockIdx.y;
    long long J0 = (long long)blockIdx.x * blockDim.x * STRIP;   // first jx of block

    // ---- stage the 17 bit rows into shared ----
    {
        const uint32_t* rowsBase = bits + ((long long)s * side + rz) * rowWords + (J0 >> 5);
        stageRows<STRIP>(stage, rowsBase, rowWords);
    }
    __syncthreads();

    int lj0 = STRIP * (int)threadIdx.x;   // local jx of this thread's first position
    int counts[STRIP] = {};
    computeStripCounts<STRIP>(stage, lj0, counts);

    unsigned long long packed = 0;
    long long idxBase = rz * cside + J0 + lj0;   // hoisted: one 64-bit mul per thread
    long long jxBase = J0 + lj0;
    #pragma unroll
    for (int c = 0; c < STRIP; c++) {
        if (jxBase + c < cside) {
            unsigned long long p =
                ((unsigned long long)counts[c] << 40) | (unsigned long long)(idxBase + c);
            if (p > packed) packed = p;
        }
    }

    // warp-level max reduction, then one shared step
    #pragma unroll
    for (int o = 16; o > 0; o >>= 1) {
        unsigned long long other = __shfl_down_sync(0xffffffffu, packed, o);
        if (other > packed) packed = other;
    }
    int lane = threadIdx.x & 31;
    int warp = threadIdx.x >> 5;
    int numWarps = ((int)blockDim.x + 31) >> 5;
    if (lane == 0) warpMax[warp] = packed;
    __syncthreads();
    if (warp == 0) {
        packed = (lane < numWarps) ? warpMax[lane] : 0;
        #pragma unroll
        for (int o = 4; o > 0; o >>= 1) {
            unsigned long long other = __shfl_down_sync(0xffffffffu, packed, o);
            if (other > packed) packed = other;
        }
        if (lane == 0) atomicMax(&bests[s], packed);
    }
}

// --climb-scan: same reduction as scoreKernel, but the best BLOCKS (exact
// cq) per seed instead of best chunk-count. packed = (blocks << 24) | idx -
// idx only needs 24 bits here (climb-scan's window is small, host guards
// cside^2 < 2^24, i.e. m up to ~2047 chunks - generous for sweeping a known
// seed's immediate neighborhood), leaving blocks (max ~49640, 17 bits) ample
// room even before the two counts overlap.
template <int STRIP>
__global__ void __launch_bounds__(256, 5)
scoreBlocksKernel(const uint32_t* __restrict__ bits,
                  int m, unsigned long long* __restrict__ bests) {
    constexpr int SST = ((STRIP * 255 + 8) >> 5) + 3;
    __shared__ uint32_t stage[17 * SST];
    __shared__ unsigned long long warpMax[8];

    int s = blockIdx.z;
    long long side = 2LL * m + 17;
    long long rowWords = rowWords32(m);
    long long cside = 2LL * m + 1;
    long long rz = blockIdx.y;
    long long J0 = (long long)blockIdx.x * blockDim.x * STRIP;

    {
        const uint32_t* rowsBase = bits + ((long long)s * side + rz) * rowWords + (J0 >> 5);
        stageRows<STRIP>(stage, rowsBase, rowWords);
    }
    __syncthreads();

    int lj0 = STRIP * (int)threadIdx.x;
    int blocks[STRIP] = {};
    computeStripBlocks<STRIP>(stage, lj0, blocks);

    unsigned long long packed = 0;
    long long idxBase = rz * cside + J0 + lj0;
    long long jxBase = J0 + lj0;
    #pragma unroll
    for (int c = 0; c < STRIP; c++) {
        if (jxBase + c < cside) {
            unsigned long long p =
                ((unsigned long long)blocks[c] << 24) | (unsigned long long)(idxBase + c);
            if (p > packed) packed = p;
        }
    }

    #pragma unroll
    for (int o = 16; o > 0; o >>= 1) {
        unsigned long long other = __shfl_down_sync(0xffffffffu, packed, o);
        if (other > packed) packed = other;
    }
    int lane = threadIdx.x & 31;
    int warp = threadIdx.x >> 5;
    int numWarps = ((int)blockDim.x + 31) >> 5;
    if (lane == 0) warpMax[warp] = packed;
    __syncthreads();
    if (warp == 0) {
        packed = (lane < numWarps) ? warpMax[lane] : 0;
        #pragma unroll
        for (int o = 4; o > 0; o >>= 1) {
            unsigned long long other = __shfl_down_sync(0xffffffffu, packed, o);
            if (other > packed) packed = other;
        }
        if (lane == 0) atomicMax(&bests[s], packed);
    }
}

// Hunt-mode kernel: instead of reducing to a per-seed best, append every
// position scoring >= floor to a global hit buffer. Hits at the floor are
// so rare (well under one per million seeds at the hotspot) that this
// removes the entire reduction tail (shuffles, shared mem, per-block
// atomics) from the hot path. Scoring math is computeStripCounts - the
// exact same function the validated reduction kernel uses.
// hit packing: [63:48]=seed index (16 bits - needs the full range, batches
//                      reach 65535; a narrower field silently wraps and
//                      saves the WRONG seed for any hit past the wrap point)
//              [47:38]=score (10 bits, max mask count 226)
//              [37:0] =position index (38 bits; cside^2, guarded host-side)
template <int STRIP>
__global__ void __launch_bounds__(256, 5)
scoreHitsKernel(const uint32_t* __restrict__ bits,
                int m, int floor_,
                unsigned long long* __restrict__ hits,
                unsigned int* __restrict__ hitCount,
                unsigned int hitCap) {
    constexpr int SST = ((STRIP * 255 + 8) >> 5) + 3;   // per-STRIP shared stride
    __shared__ uint32_t stage[17 * SST];

    int s = blockIdx.z;
    long long side = 2LL * m + 17;
    long long rowWords = rowWords32(m);
    long long cside = 2LL * m + 1;
    long long rz = blockIdx.y;
    long long J0 = (long long)blockIdx.x * blockDim.x * STRIP;

    {
        const uint32_t* rowsBase = bits + ((long long)s * side + rz) * rowWords + (J0 >> 5);
        stageRows<STRIP>(stage, rowsBase, rowWords);
    }
    __syncthreads();

    int lj0 = STRIP * (int)threadIdx.x;
    int counts[STRIP] = {};
    computeStripCounts<STRIP>(stage, lj0, counts);

    long long jxBase = J0 + lj0;
    long long idxBase = rz * cside + jxBase;
    #pragma unroll
    for (int c = 0; c < STRIP; c++) {
        if (jxBase + c < cside && counts[c] >= floor_) {
            unsigned int slot = atomicAdd(hitCount, 1u);
            if (slot < hitCap) {
                hits[slot] = ((unsigned long long)s << 48)
                           | ((unsigned long long)counts[c] << 38)
                           | (unsigned long long)(idxBase + c);
            }
        }
    }
}

// ------------------------------------------------------------------
// v18 FUSED hunt kernel (small m only). One BLOCK per seed:
//   Phase 1: compute the seed's whole bit window into shared memory
//            (identical math to bitKernel, one thread per (row,word)).
//   Phase 2: score EVERY center from that in-shared bitmap and append hits.
// This removes, versus the two-kernel path: the global bitmap write, the
// staging read-back, and the ~17x redundant re-reads of each row across the
// per-row score blocks. Only usable when the bit window fits in shared memory
// (host gates on side*SWR); large m falls back to the two-kernel path.
// Hit packing is IDENTICAL to scoreHitsKernel (16b seedIdx / 10b score /
// 38b position), so decode is shared.
__global__ void huntFusedKernel(const long long* __restrict__ seeds,
                                 int m, int ccx, int ccz, int floor_,
                                 unsigned long long* __restrict__ hits,
                                 unsigned int* __restrict__ hitCount,
                                 unsigned int hitCap, int SWR) {
    extern __shared__ uint32_t sbits[];      // side * SWR words
    int s = blockIdx.x;                       // one block == one seed
    long long seed = seeds[s];
    int side  = 2 * m + 17;
    int WR    = (side + 31) / 32;
    int cside = 2 * m + 1;
    int off   = m + 8;

    // Zero everything incl. the 2 pad words/row, so the +1-word combine in
    // scoreCenterShared reads defined 0s past the real data.
    for (int idx = threadIdx.x; idx < side * SWR; idx += blockDim.x) sbits[idx] = 0u;
    __syncthreads();

    // Phase 1: RNG bitmap -> shared (mirror of bitKernel's per-word path).
    const uint32_t C1 = 0x4c1906u, C2 = 0x5ac0dbu;
    for (long long t = threadIdx.x; t < (long long)side * WR; t += blockDim.x) {
        int r = (int)(t / WR);
        int w = (int)(t % WR);
        int kz = r - off + ccz;
        uint64_t rowBase = (uint64_t)seed
            + (uint64_t)((int64_t)((int32_t)((int64_t)kz * (int64_t)kz)) * 0x4307a7LL)
            + (uint64_t)(int64_t)(int32_t)((int64_t)kz * 0x5f24fLL);
        int x0 = w * 32 - off + ccx;
        uint32_t iu = (uint32_t)((int64_t)x0 * (int64_t)x0 * (int64_t)C1);
        uint32_t id = (uint32_t)((2LL * x0 + 1) * (int64_t)C1);
        uint32_t iv = (uint32_t)((int64_t)x0 * (int64_t)C2);
        uint32_t acc = 0;
        long long jBase = (long long)w * 32;
        #pragma unroll 4
        for (int c = 0; c < 32; c++) {
            if (jBase + c >= side) break;
            uint64_t seedExpr = rowBase + (uint64_t)(int64_t)(int32_t)iu
                                        + (uint64_t)(int64_t)(int32_t)iv;
            if (fastSlimeFromSeed(seedExpr)) acc |= 1u << c;
            iu += id; id += 2 * C1; iv += C2;
        }
        sbits[(long long)r * SWR + w] = acc;
    }
    __syncthreads();

    // Phase 2: score all cside*cside centers, append hits >= floor.
    for (long long ci = threadIdx.x; ci < (long long)cside * cside; ci += blockDim.x) {
        int cz = (int)(ci / cside);
        int cx = (int)(ci % cside);
        int count = scoreCenterShared(sbits, SWR, cx, cz);
        if (count >= floor_) {
            unsigned int slot = atomicAdd(hitCount, 1u);
            if (slot < hitCap) {
                long long idx = (long long)cz * cside + cx;
                hits[slot] = ((unsigned long long)s << 48)
                           | ((unsigned long long)count << 38)
                           | (unsigned long long)idx;
            }
        }
    }
}


// ------------------------------------------------------------------
// Host side
// ------------------------------------------------------------------
struct Best { int score; int cx; int cz; };

static uint8_t h_mask[17 * 17];
static int h_weights[17 * 17];   // buildBlockWeights - for cpuBestBlocks / --climb-scan

// CPU reference: validated naive core with the identical packed tie-break.
static Best cpuBestPacked(long long seed, int m, int ccx, int ccz) {
    long long cside = 2LL * m + 1;
    unsigned long long best = 0;
    for (int cz = -m; cz <= m; cz++) {
        for (int cx = -m; cx <= m; cx++) {
            int sc = scoreCenterChunks(h_mask, seed, cx + ccx, cz + ccz);
            long long idx = (long long)(cz + m) * cside + (cx + m);
            unsigned long long packed =
                ((unsigned long long)sc << 40) | (unsigned long long)idx;
            if (packed > best) best = packed;
        }
    }
    int score = (int)(best >> 40);
    long long idx = (long long)(best & ((1ULL << 40) - 1));
    return Best{ score, (int)(idx % cside) - m, (int)(idx / cside) - m };
}

// CPU reference for scoreBlocksKernel / --climb-scan.
static Best cpuBestBlocks(long long seed, int m, int ccx, int ccz) {
    long long cside = 2LL * m + 1;
    unsigned long long best = 0;
    for (int cz = -m; cz <= m; cz++) {
        for (int cx = -m; cx <= m; cx++) {
            int bl = scoreCenterBlocks(h_weights, seed, cx + ccx, cz + ccz);
            long long idx = (long long)(cz + m) * cside + (cx + m);
            unsigned long long packed = ((unsigned long long)bl << 24) | (unsigned long long)idx;
            if (packed > best) best = packed;
        }
    }
    int blocks = (int)(best >> 24);
    long long idx = (long long)(best & ((1ULL << 24) - 1));
    return Best{ blocks, (int)(idx % cside) - m, (int)(idx / cside) - m };
}

static Best decodePacked(unsigned long long packed, int m) {
    long long cside = 2LL * m + 1;
    int score = (int)(packed >> 40);
    long long idx = (long long)(packed & ((1ULL << 40) - 1));
    return Best{ score, (int)(idx % cside) - m, (int)(idx / cside) - m };
}

// scoreBlocksKernel's packing: 24-bit idx (climb-scan windows are small, see
// scoreBlocksKernel), so blocks occupies everything above that.
static Best decodePackedBlocks(unsigned long long packed, int m) {
    long long cside = 2LL * m + 1;
    int blocks = (int)(packed >> 24);
    long long idx = (long long)(packed & ((1ULL << 24) - 1));
    return Best{ blocks, (int)(idx % cside) - m, (int)(idx / cside) - m };
}

struct GpuEngine {
    uint32_t* bits = nullptr;
    long long* dSeeds = nullptr;
    unsigned long long* dBests = nullptr;
    unsigned long long* dHits = nullptr;
    unsigned int* dHitCount = nullptr;
    static const unsigned int HIT_CAP = 65536;
    size_t bitsCapBytes = 0;
    int seedCap = 0;

    // ---- Double-buffered streaming for the FUSED hunt loop (see
    // beginFusedBatch/collectFusedBatch below) ----
    //
    // Measured live (nvidia-smi, 1s polling) during a real hunt: 84-87% GPU
    // utilization, SM clock pinned at 2422/2430 MHz (essentially max boost),
    // power draw ~410W of a 600W cap. Clocks maxed + power well under cap
    // rules out thermal/power throttling - the ~15% idle gap is a
    // synchronization one: runHitsFusedPrepared's cudaMemcpy(hitCount) is a
    // BLOCKING D2H copy, so the host cannot issue the next batch's kernels
    // until the current one both finishes AND its result round-trips back -
    // the GPU sits idle for exactly that CPU-side gap every batch. At the
    // fused kernel's measured throughput a 65535-seed batch is ~1.2ms of
    // kernel time; a ~150-200us host/driver round-trip per batch lines up
    // with the observed gap almost exactly.
    //
    // Fix: two independent seed/hit buffers and two CUDA streams. While
    // stream A's batch result is still in flight (async copy queued, not yet
    // synchronized), stream B's NEXT batch is already launched - the GPU
    // never idles waiting on a host round-trip because there is always a
    // second batch already queued behind whichever one the host is waiting
    // on. Scoped to the FUSED path only (the default, and where essentially
    // all real hunting happens) - the two-kernel fallback path keeps using
    // the original synchronous runHitsGen unchanged, since it is already a
    // rare/large-m-only path and not resource-constrained the same way.
    static const int NSTREAMS = 2;
    cudaStream_t streams[NSTREAMS] = { nullptr, nullptr };
    long long* dSeedsS[NSTREAMS] = { nullptr, nullptr };
    unsigned long long* dHitsS[NSTREAMS] = { nullptr, nullptr };
    unsigned int* dHitCountS[NSTREAMS] = { nullptr, nullptr };
    unsigned long long* hHitsPinned[NSTREAMS] = { nullptr, nullptr };
    unsigned int* hHitCountPinned[NSTREAMS] = { nullptr, nullptr };
    int seedCapS[NSTREAMS] = { 0, 0 };
    bool streamsInit = false;

    static size_t perSeedBytes(int m) {
        long long side = 2LL * m + 17;
        return (size_t)side * (size_t)rowWords32(m) * sizeof(uint32_t);
    }

    // choose a batch size that fits comfortably in free VRAM
    int autoBatch(int m, int wanted) {
        size_t freeB = 0, totalB = 0;
        CUDA_CHECK(cudaMemGetInfo(&freeB, &totalB));
        size_t budget = (size_t)((double)freeB * 0.6);
        size_t per = perSeedBytes(m);
        long long fit = (long long)(budget / (per ? per : 1));
        if (fit < 1) fit = 1;
        // No fixed cap here on purpose: a small cap would throttle small-m
        // hunts into thousands of tiny, sync-bound batches (each ends on a
        // blocking hitCount copy). For small m the bitmap is tiny, so VRAM
        // easily holds tens of thousands of seeds - let the batch grow to
        // the grid.y limit, bounded only by the 0.6*free VRAM budget above.
        // Large m stays small automatically because perSeedBytes is large.
        // Correctness is unaffected either way: batch size only groups the
        // SAME seeds into fewer launches.
        if (fit > wanted) fit = wanted;
        if (fit > 65535) fit = 65535; // grid.y / grid.z hard limit
        return (int)fit;
    }

    void ensure(int m, int batch) {
        size_t need = perSeedBytes(m) * (size_t)batch;
        if (need > bitsCapBytes) {
            if (bits) CUDA_CHECK(cudaFree(bits));
            CUDA_CHECK(cudaMalloc(&bits, need));
            bitsCapBytes = need;
        }
        if (batch > seedCap) {
            if (dSeeds) CUDA_CHECK(cudaFree(dSeeds));
            if (dBests) CUDA_CHECK(cudaFree(dBests));
            CUDA_CHECK(cudaMalloc(&dSeeds, batch * sizeof(long long)));
            CUDA_CHECK(cudaMalloc(&dBests, batch * sizeof(unsigned long long)));
            seedCap = batch;
        }
        if (!dHits) {
            CUDA_CHECK(cudaMalloc(&dHits, HIT_CAP * sizeof(unsigned long long)));
            CUDA_CHECK(cudaMalloc(&dHitCount, sizeof(unsigned int)));
        }
    }

    // scores `count` seeds at radius m; results[i] = best of seeds[i]
    void run(const long long* seeds, int count, int m, int ccx, int ccz,
             Best* results) {
        ensure(m, count);
        CUDA_CHECK(cudaMemcpy(dSeeds, seeds, count * sizeof(long long),
                              cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemset(dBests, 0, count * sizeof(unsigned long long)));

        const int threads = 256;
        long long side = 2LL * m + 17;
        long long WR = (side + 31) / 32;
        dim3 g1((unsigned)((side * WR + threads - 1) / threads), (unsigned)count);
        bitKernel<<<g1, threads>>>(bits, dSeeds, m, ccx, ccz);
        CUDA_CHECK(cudaGetLastError());

        long long cside = 2LL * m + 1;
        // From stripPlan(m) - the SAME source rowWords32() sizes the row from,
        // so the stride can never be narrower than what this launch reads.
        StripPlan pl = stripPlan(m);
        int sthreads = pl.sthreads, G = pl.G, S = pl.S;
        dim3 grid2((unsigned)G, (unsigned)cside, (unsigned)count);
        switch (S) {
            case 1: scoreKernel<1><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 2: scoreKernel<2><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 3: scoreKernel<3><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 4: scoreKernel<4><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 5: scoreKernel<5><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 6: scoreKernel<6><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 7: scoreKernel<7><<<grid2, sthreads>>>(bits, m, dBests); break;
            default: scoreKernel<8><<<grid2, sthreads>>>(bits, m, dBests); break;
        }
        CUDA_CHECK(cudaGetLastError());

        std::vector<unsigned long long> packed(count);
        CUDA_CHECK(cudaMemcpy(packed.data(), dBests,
                              count * sizeof(unsigned long long),
                              cudaMemcpyDeviceToHost));
        for (int i = 0; i < count; i++) {
            results[i] = decodePacked(packed[i], m);
        }
    }

    // --climb-scan: same shape as run(), best BLOCKS per seed instead of best
    // chunk count. Caller guards cside^2 < 2^24 (see scoreBlocksKernel).
    void runBlocks(const long long* seeds, int count, int m, int ccx, int ccz,
                   Best* results) {
        ensure(m, count);
        CUDA_CHECK(cudaMemcpy(dSeeds, seeds, count * sizeof(long long),
                              cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemset(dBests, 0, count * sizeof(unsigned long long)));

        const int threads = 256;
        long long side = 2LL * m + 17;
        long long WR = (side + 31) / 32;
        dim3 g1((unsigned)((side * WR + threads - 1) / threads), (unsigned)count);
        bitKernel<<<g1, threads>>>(bits, dSeeds, m, ccx, ccz);
        CUDA_CHECK(cudaGetLastError());

        long long cside = 2LL * m + 1;
        // From stripPlan(m) - the SAME source rowWords32() sizes the row from,
        // so the stride can never be narrower than what this launch reads.
        StripPlan pl = stripPlan(m);
        int sthreads = pl.sthreads, G = pl.G, S = pl.S;
        dim3 grid2((unsigned)G, (unsigned)cside, (unsigned)count);
        switch (S) {
            case 1: scoreBlocksKernel<1><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 2: scoreBlocksKernel<2><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 3: scoreBlocksKernel<3><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 4: scoreBlocksKernel<4><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 5: scoreBlocksKernel<5><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 6: scoreBlocksKernel<6><<<grid2, sthreads>>>(bits, m, dBests); break;
            case 7: scoreBlocksKernel<7><<<grid2, sthreads>>>(bits, m, dBests); break;
            default: scoreBlocksKernel<8><<<grid2, sthreads>>>(bits, m, dBests); break;
        }
        CUDA_CHECK(cudaGetLastError());

        std::vector<unsigned long long> packed(count);
        CUDA_CHECK(cudaMemcpy(packed.data(), dBests,
                              count * sizeof(unsigned long long),
                              cudaMemcpyDeviceToHost));
        for (int i = 0; i < count; i++) {
            results[i] = decodePackedBlocks(packed[i], m);
        }
    }

    struct Hit { int seedIdx; int score; int cx; int cz; };

    // hunt path: returns every position scoring >= floor across the batch,
    // sorted for deterministic discovery order
    void runHits(const long long* seeds, int count, int m, int ccx, int ccz,
                 int floor_, std::vector<Hit>& out) {
        ensure(m, count);
        CUDA_CHECK(cudaMemcpy(dSeeds, seeds, count * sizeof(long long),
                              cudaMemcpyHostToDevice));
        runHitsPrepared(count, m, ccx, ccz, floor_, out);
    }

    // Everything after the seeds are in dSeeds, however they got there (host
    // upload for --self-test/--enumerate, or genSeedsKernel for the hunt).
    // Split out so both routes provably run the SAME scoring code.
    void runHitsPrepared(int count, int m, int ccx, int ccz, int floor_,
                         std::vector<Hit>& out) {
        CUDA_CHECK(cudaMemset(dHitCount, 0, sizeof(unsigned int)));

        const int threads = 256;
        long long side = 2LL * m + 17;
        long long WR = (side + 31) / 32;
        dim3 g1((unsigned)((side * WR + threads - 1) / threads), (unsigned)count);
        bitKernel<<<g1, threads>>>(bits, dSeeds, m, ccx, ccz);
        CUDA_CHECK(cudaGetLastError());

        long long cside = 2LL * m + 1;
        // The hit packing reserves 38 bits for the position index (cside*
        // cside) - ample for any real hunt (m up to ~262000), but guard
        // rather than silently corrupt if someone hunts at absurd m.
        if (cside * cside >= (1LL << 38)) {
            fprintf(stderr, "[FATAL] m=%d too large for hunt hit packing "
                            "(position index would overflow). Use the reduction "
                            "path / smaller m.\n", m);
            exit(1);
        }
        // From stripPlan(m) - the SAME source rowWords32() sizes the row from,
        // so the stride can never be narrower than what this launch reads.
        StripPlan pl = stripPlan(m);
        int sthreads = pl.sthreads, G = pl.G, S = pl.S;
        dim3 grid2((unsigned)G, (unsigned)cside, (unsigned)count);
        switch (S) {
            case 1: scoreHitsKernel<1><<<grid2, sthreads>>>(bits, m, floor_, dHits, dHitCount, HIT_CAP); break;
            case 2: scoreHitsKernel<2><<<grid2, sthreads>>>(bits, m, floor_, dHits, dHitCount, HIT_CAP); break;
            case 3: scoreHitsKernel<3><<<grid2, sthreads>>>(bits, m, floor_, dHits, dHitCount, HIT_CAP); break;
            case 4: scoreHitsKernel<4><<<grid2, sthreads>>>(bits, m, floor_, dHits, dHitCount, HIT_CAP); break;
            case 5: scoreHitsKernel<5><<<grid2, sthreads>>>(bits, m, floor_, dHits, dHitCount, HIT_CAP); break;
            case 6: scoreHitsKernel<6><<<grid2, sthreads>>>(bits, m, floor_, dHits, dHitCount, HIT_CAP); break;
            case 7: scoreHitsKernel<7><<<grid2, sthreads>>>(bits, m, floor_, dHits, dHitCount, HIT_CAP); break;
            default: scoreHitsKernel<8><<<grid2, sthreads>>>(bits, m, floor_, dHits, dHitCount, HIT_CAP); break;
        }
        CUDA_CHECK(cudaGetLastError());

        unsigned int n = 0;
        CUDA_CHECK(cudaMemcpy(&n, dHitCount, sizeof(unsigned int), cudaMemcpyDeviceToHost));
        decodeHits(n, m, out);
    }

    // Fill dSeeds on the DEVICE for batch [idxBase, idxBase+count) of the hunt
    // stream rooted at `base`. Replaces the CPU mt19937_64 loop AND the H2D
    // copy - see the genSeedsKernel comment above for why that mattered.
    void genSeeds(int count, uint64_t base, long long idxBase,
                  unsigned long long fixMask, unsigned long long fixVal) {
        int t = 256, b = (count + t - 1) / t;
        genSeedsKernel<<<b, t>>>(dSeeds, count, base, idxBase, fixMask, fixVal);
        CUDA_CHECK(cudaGetLastError());
    }

    // Hunt a generated batch. Identical to runHits/runHitsFused except the
    // seeds are produced on-device first instead of being uploaded. Kept as
    // separate entry points so the explicit-seed versions (which --self-test
    // and --enumerate rely on) stay exactly as validated.
    void runHitsGen(int count, int m, int ccx, int ccz, int floor_,
                    uint64_t base, long long idxBase,
                    unsigned long long fixMask, unsigned long long fixVal,
                    bool fused, std::vector<Hit>& out) {
        ensure(m, count);
        genSeeds(count, base, idxBase, fixMask, fixVal);
        if (fused) runHitsFusedPrepared(count, m, ccx, ccz, floor_, out);
        else       runHitsPrepared(count, m, ccx, ccz, floor_, out);
    }

    // shared decode for both hunt paths (two-kernel and fused) so packing can
    // never diverge. sorts for deterministic discovery order.
    void decodeHits(unsigned int n, int m, std::vector<Hit>& out) {
        long long cside = 2LL * m + 1;
        if (n > HIT_CAP) {
            fprintf(stderr, "[WARN] hit buffer overflow (%u hits, cap %u) - raise --record-floor\n", n, HIT_CAP);
            n = HIT_CAP;
        }
        out.clear();
        if (n == 0) return;
        std::vector<unsigned long long> raw(n);
        CUDA_CHECK(cudaMemcpy(raw.data(), dHits, n * sizeof(unsigned long long),
                              cudaMemcpyDeviceToHost));
        std::sort(raw.begin(), raw.end());
        for (unsigned int i = 0; i < n; i++) {
            unsigned long long h = raw[i];
            int sIdx = (int)(h >> 48);
            int score = (int)((h >> 38) & 0x3FF);
            long long idx = (long long)(h & ((1ULL << 38) - 1));
            out.push_back(Hit{ sIdx, score, (int)(idx % cside) - m, (int)(idx / cside) - m });
        }
    }

    // Shared bytes the fused kernel needs for a given m, or 0 if it doesn't fit
    // in the opt-in shared budget. side*(WR+2) words * 4 bytes.
    static size_t fusedShared(int m) {
        long long side = 2LL * m + 17;
        long long WR = (side + 31) / 32;
        long long SWR = WR + 2;
        size_t bytes = (size_t)side * (size_t)SWR * sizeof(uint32_t);
        return (bytes <= 44u * 1024u) ? bytes : 0;   // conservative 44 KB cap
    }

    // v18 fused hunt path (small m). One block per seed; whole bit window lives
    // in shared, so no global bitmap write / staging / redundant re-reads.
    // Produces identical hits to runHits (same scoring math + packing), just
    // fewer memory trips. Caller must have checked fusedShared(m) > 0.
    void runHitsFused(const long long* seeds, int count, int m, int ccx, int ccz,
                      int floor_, std::vector<Hit>& out) {
        ensure(m, count);
        long long cside = 2LL * m + 1;
        if (cside * cside >= (1LL << 38)) {   // same guard as runHits
            fprintf(stderr, "[FATAL] m=%d too large for hunt hit packing.\n", m);
            exit(1);
        }
        CUDA_CHECK(cudaMemcpy(dSeeds, seeds, count * sizeof(long long),
                              cudaMemcpyHostToDevice));
        runHitsFusedPrepared(count, m, ccx, ccz, floor_, out);
    }

    // Fused hunt over seeds already sitting in dSeeds. Same split rationale as
    // runHitsPrepared: one scoring path, two ways of filling the seed buffer.
    void runHitsFusedPrepared(int count, int m, int ccx, int ccz, int floor_,
                              std::vector<Hit>& out) {
        long long cside = 2LL * m + 1;
        if (cside * cside >= (1LL << 38)) {
            fprintf(stderr, "[FATAL] m=%d too large for hunt hit packing.\n", m);
            exit(1);
        }
        size_t shBytes = fusedShared(m);
        int SWR = (int)(((2LL * m + 17 + 31) / 32) + 2);
        CUDA_CHECK(cudaMemset(dHitCount, 0, sizeof(unsigned int)));
        huntFusedKernel<<<(unsigned)count, 256, shBytes>>>(
            dSeeds, m, ccx, ccz, floor_, dHits, dHitCount, HIT_CAP, SWR);
        CUDA_CHECK(cudaGetLastError());
        unsigned int n = 0;
        CUDA_CHECK(cudaMemcpy(&n, dHitCount, sizeof(unsigned int), cudaMemcpyDeviceToHost));
        decodeHits(n, m, out);
    }

    // Unpacks n raw hit words already sitting in HOST memory (as opposed to
    // decodeHits above, which does its own device->host copy first) - shared
    // so the streamed path below can never decode a hit differently than the
    // validated synchronous path. Same sort-for-determinism as decodeHits.
    static void decodeHitsFromHost(const unsigned long long* raw, unsigned int n,
                                   int m, std::vector<Hit>& out) {
        long long cside = 2LL * m + 1;
        out.clear();
        if (n == 0) return;
        std::vector<unsigned long long> sorted(raw, raw + n);
        std::sort(sorted.begin(), sorted.end());
        for (unsigned int i = 0; i < n; i++) {
            unsigned long long h = sorted[i];
            int sIdx = (int)(h >> 48);
            int score = (int)((h >> 38) & 0x3FF);
            long long idx = (long long)(h & ((1ULL << 38) - 1));
            out.push_back(Hit{ sIdx, score, (int)(idx % cside) - m, (int)(idx / cside) - m });
        }
    }

    // Lazily creates the 2 streams + fixed-size (HIT_CAP) pinned/device hit
    // buffers on first use, then grows each slot's seed buffer as needed -
    // same grow-only caching pattern as ensure() above, just doubled.
    void ensureStreams(int batch) {
        if (!streamsInit) {
            for (int s = 0; s < NSTREAMS; s++) {
                CUDA_CHECK(cudaStreamCreate(&streams[s]));
                CUDA_CHECK(cudaHostAlloc(&hHitCountPinned[s], sizeof(unsigned int), cudaHostAllocDefault));
                CUDA_CHECK(cudaHostAlloc(&hHitsPinned[s], HIT_CAP * sizeof(unsigned long long), cudaHostAllocDefault));
                CUDA_CHECK(cudaMalloc(&dHitCountS[s], sizeof(unsigned int)));
                CUDA_CHECK(cudaMalloc(&dHitsS[s], HIT_CAP * sizeof(unsigned long long)));
            }
            streamsInit = true;
        }
        for (int s = 0; s < NSTREAMS; s++) {
            if (batch > seedCapS[s]) {
                if (dSeedsS[s]) CUDA_CHECK(cudaFree(dSeedsS[s]));
                CUDA_CHECK(cudaMalloc(&dSeedsS[s], (size_t)batch * sizeof(long long)));
                seedCapS[s] = batch;
            }
        }
    }

    // Launches slot `slot`'s seed-gen + fused hunt kernel on its own stream
    // and queues the result copies asynchronously - does NOT wait for any of
    // it. The count is always copied speculatively at the full HIT_CAP size
    // (512KB, microseconds over PCIe) alongside the 4-byte count itself, so
    // there is no host-side dependency on knowing the count before queuing
    // the hits copy - both copies go out immediately, back to back.
    void beginFusedBatch(int slot, int count, int m, int ccx, int ccz, int floor_,
                         uint64_t base, long long idxBase,
                         unsigned long long fixMask, unsigned long long fixVal) {
        ensureStreams(count);
        cudaStream_t s = streams[slot];
        int t = 256, b = (count + t - 1) / t;
        genSeedsKernel<<<b, t, 0, s>>>(dSeedsS[slot], count, base, idxBase, fixMask, fixVal);
        CUDA_CHECK(cudaMemsetAsync(dHitCountS[slot], 0, sizeof(unsigned int), s));
        size_t shBytes = fusedShared(m);
        int SWR = (int)(((2LL * m + 17 + 31) / 32) + 2);
        huntFusedKernel<<<(unsigned)count, 256, shBytes, s>>>(
            dSeedsS[slot], m, ccx, ccz, floor_, dHitsS[slot], dHitCountS[slot], HIT_CAP, SWR);
        CUDA_CHECK(cudaMemcpyAsync(hHitCountPinned[slot], dHitCountS[slot], sizeof(unsigned int),
                                   cudaMemcpyDeviceToHost, s));
        CUDA_CHECK(cudaMemcpyAsync(hHitsPinned[slot], dHitsS[slot], HIT_CAP * sizeof(unsigned long long),
                                   cudaMemcpyDeviceToHost, s));
        CUDA_CHECK(cudaGetLastError());
    }

    // Waits for slot's stream (the async work queued in beginFusedBatch) and
    // decodes however many hits the count says. This is the ONLY blocking
    // point in the streamed path - and by the time it is called, the OTHER
    // slot's batch is typically already running, so the GPU has not been
    // idle waiting for this host round-trip the way the single-buffered path
    // was.
    void collectFusedBatch(int slot, int m, std::vector<Hit>& out) {
        CUDA_CHECK(cudaStreamSynchronize(streams[slot]));
        unsigned int n = *hHitCountPinned[slot];
        if (n > HIT_CAP) {
            fprintf(stderr, "[WARN] hit buffer overflow (%u hits, cap %u) - raise --record-floor\n", n, HIT_CAP);
            n = HIT_CAP;
        }
        decodeHitsFromHost(hHitsPinned[slot], n, m, out);
    }

    // Fully drains both streams. Called before runHunt() returns so a
    // --worker reusing this SAME GpuEngine for the NEXT spot can never race
    // against a still-in-flight batch from the PREVIOUS spot's stream -
    // CUDA streams execute in submission order, so this is a correctness
    // requirement for stream reuse across spots, not just tidiness.
    void drainStreams() {
        if (!streamsInit) return;
        for (int s = 0; s < NSTREAMS; s++) CUDA_CHECK(cudaStreamSynchronize(streams[s]));
    }

    void release() {
        if (bits) cudaFree(bits);
        if (dSeeds) cudaFree(dSeeds);
        if (dBests) cudaFree(dBests);
        if (dHits) cudaFree(dHits);
        if (dHitCount) cudaFree(dHitCount);
        bits = nullptr; dSeeds = nullptr; dBests = nullptr;
        bitsCapBytes = 0; seedCap = 0;
        if (streamsInit) {
            for (int s = 0; s < NSTREAMS; s++) {
                cudaStreamSynchronize(streams[s]);
                if (dSeedsS[s]) cudaFree(dSeedsS[s]);
                if (dHitsS[s]) cudaFree(dHitsS[s]);
                if (dHitCountS[s]) cudaFree(dHitCountS[s]);
                if (hHitCountPinned[s]) cudaFreeHost(hHitCountPinned[s]);
                if (hHitsPinned[s]) cudaFreeHost(hHitsPinned[s]);
                cudaStreamDestroy(streams[s]);
                dSeedsS[s] = nullptr; dHitsS[s] = nullptr; dHitCountS[s] = nullptr;
                hHitCountPinned[s] = nullptr; hHitsPinned[s] = nullptr;
                seedCapS[s] = 0;
            }
            streamsInit = false;
        }
    }
};

// ------------------------------------------------------------------
// Self-test: optimized GPU pipeline vs validated naive CPU core, at several
// area sizes to exercise interval/index edge cases. Must match exactly,
// including tie-breaks.
// ------------------------------------------------------------------
static bool selfTest(GpuEngine& eng) {
    printf("Self-test: GPU vs validated CPU core, incl. off-center windows (~15-25s)\n");
    std::mt19937_64 rng(20260710);
    const int ms[3] = { 24, 100, 333 };
    const int centers[3][2] = { {0, 0}, {134, 533}, {-7321, -99} };
    bool ok = true;
    for (int mi = 0; mi < 3; mi++) {
        int m = ms[mi];
        for (int t = 0; t < 3; t++) {
            long long seed = (long long)rng();
            int ccx = centers[t][0], ccz = centers[t][1];
            Best g;
            eng.run(&seed, 1, m, ccx, ccz, &g);
            Best c = cpuBestPacked(seed, m, ccx, ccz);
            bool match = (c.score == g.score && c.cx == g.cx && c.cz == g.cz);
            printf("  m=%3d center(%d,%d) seed %lld: CPU %d @(%d,%d) | GPU %d @(%d,%d) -> %s\n",
                   m, ccx, ccz, seed, c.score, c.cx, c.cz, g.score, g.cx, g.cz,
                   match ? "OK" : "MISMATCH");
            fflush(stdout);
            if (!match) ok = false;
        }
    }
    // ---- verify the hit-collection path (hunt mode) against a
    // CPU-computed hit set: exact set equality of (score, position) ----
    printf("Hit-path check (hunt kernel vs CPU hit sets)...\n");
    {
        const int hm[2] = { 24, 100 };
        const int hc[2][2] = { {134, 533}, {0, 0} };
        for (int t = 0; t < 2 && ok; t++) {
            long long seed = (long long)rng();
            int m = hm[t], ccx = hc[t][0], ccz = hc[t][1];
            int floor_ = 30;
            std::vector<GpuEngine::Hit> gpuHits;
            eng.runHits(&seed, 1, m, ccx, ccz, floor_, gpuHits);
            // CPU reference set
            std::vector<long long> cpuSet;
            for (int cz = -m; cz <= m; cz++)
                for (int cx = -m; cx <= m; cx++) {
                    int sc = scoreCenterChunks(h_mask, seed, cx + ccx, cz + ccz);
                    if (sc >= floor_)
                        cpuSet.push_back(((long long)sc << 40)
                            | ((long long)(cz + m) * (2LL * m + 1) + (cx + m)));
                }
            std::vector<long long> gpuSet;
            for (const auto& h : gpuHits)
                gpuSet.push_back(((long long)h.score << 40)
                    | ((long long)(h.cz + m) * (2LL * m + 1) + (h.cx + m)));
            std::sort(cpuSet.begin(), cpuSet.end());
            std::sort(gpuSet.begin(), gpuSet.end());
            bool match = (cpuSet == gpuSet);
            printf("  m=%3d center(%d,%d) seed %lld: CPU %zu hits | GPU %zu hits -> %s\n",
                   m, ccx, ccz, seed, cpuSet.size(), gpuSet.size(),
                   match ? "OK" : "MISMATCH");
            if (!match) ok = false;
        }
    }
    // ---- verify the FUSED hunt kernel against the same CPU hit set ----
    printf("Hit-path check (FUSED kernel vs CPU hit sets)...\n");
    {
        const int hm[2] = { 24, 100 };
        const int hc[2][2] = { {2048, 8576}, {0, 0} };
        for (int t = 0; t < 2 && ok; t++) {
            long long seed = (long long)rng();
            int m = hm[t], ccx = hc[t][0], ccz = hc[t][1];
            int floor_ = 30;
            if (GpuEngine::fusedShared(m) == 0) { printf("  m=%d skipped (too big)\n", m); continue; }
            std::vector<GpuEngine::Hit> gpuHits;
            eng.runHitsFused(&seed, 1, m, ccx, ccz, floor_, gpuHits);
            std::vector<long long> cpuSet, gpuSet;
            for (int cz = -m; cz <= m; cz++)
                for (int cx = -m; cx <= m; cx++) {
                    int sc = scoreCenterChunks(h_mask, seed, cx + ccx, cz + ccz);
                    if (sc >= floor_)
                        cpuSet.push_back(((long long)sc << 40)
                            | ((long long)(cz + m) * (2LL * m + 1) + (cx + m)));
                }
            for (const auto& h : gpuHits)
                gpuSet.push_back(((long long)h.score << 40)
                    | ((long long)(h.cz + m) * (2LL * m + 1) + (h.cx + m)));
            std::sort(cpuSet.begin(), cpuSet.end());
            std::sort(gpuSet.begin(), gpuSet.end());
            bool match = (cpuSet == gpuSet);
            printf("  m=%3d center(%d,%d) seed %lld: CPU %zu hits | FUSED %zu hits -> %s\n",
                   m, ccx, ccz, seed, cpuSet.size(), gpuSet.size(),
                   match ? "OK" : "MISMATCH");
            if (!match) ok = false;
        }
    }
    // ---- Streamed double-buffered path (beginFusedBatch/collectFusedBatch)
    // vs CPU hit sets, run across MULTIPLE batches so slot alternation
    // (0 -> 1 -> 0) is actually exercised, not just a single launch - the
    // whole point of this path is the handoff BETWEEN batches. Uses
    // GPU-generated seeds (genSeedsKernel/huntSeedAt, same as the real hunt
    // loop) from a fixed base so the CPU reference can recompute the
    // identical seed stream independently, and packs (global seed index,
    // score, position) per hit so a collision between two DIFFERENT seeds'
    // hits can't hide a per-batch indexing bug.
    printf("Streamed-batch check (double-buffered path vs CPU hit sets)...\n");
    {
        int m = 24, sccx = 2048, sccz = 8576, sfloor = 40;
        uint64_t base = (uint64_t)rng();
        const int nBatches = 3, batchSz = 800;
        std::vector<long long> cpuSet, gpuSet;
        for (int gi = 0; gi < nBatches * batchSz; gi++) {
            long long seed = huntSeedAt(base, gi, 0, 0);
            for (int cz = -m; cz <= m; cz++)
                for (int cx = -m; cx <= m; cx++) {
                    int sc = scoreCenterChunks(h_mask, seed, cx + sccx, cz + sccz);
                    if (sc >= sfloor)
                        cpuSet.push_back(((long long)gi << 24) | ((long long)sc << 16)
                            | ((long long)(cz + m) * (2LL * m + 1) + (cx + m)));
                }
        }
        int slot = 0;
        long long curBase = 0; int curN = batchSz;
        eng.beginFusedBatch(slot, batchSz, m, sccx, sccz, sfloor, base, curBase, 0, 0);
        for (int b = 0; b < nBatches; b++) {
            int nextSlot = 1 - slot;
            bool haveNext = (b + 1 < nBatches);
            long long nextBase = curBase + curN;
            if (haveNext) eng.beginFusedBatch(nextSlot, batchSz, m, sccx, sccz, sfloor, base, nextBase, 0, 0);
            std::vector<GpuEngine::Hit> shits;
            eng.collectFusedBatch(slot, m, shits);
            for (const auto& h : shits) {
                long long gi = curBase + h.seedIdx;
                gpuSet.push_back((gi << 24) | ((long long)h.score << 16)
                    | ((long long)(h.cz + m) * (2LL * m + 1) + (h.cx + m)));
            }
            slot = nextSlot; curBase = nextBase;
        }
        eng.drainStreams();
        std::sort(cpuSet.begin(), cpuSet.end());
        std::sort(gpuSet.begin(), gpuSet.end());
        bool match = (cpuSet == gpuSet);
        printf("  m=%d center(%d,%d) %d batches x %d seeds: CPU %zu hits | STREAMED %zu hits -> %s\n",
               m, sccx, sccz, nBatches, batchSz, cpuSet.size(), gpuSet.size(),
               match ? "OK" : "MISMATCH");
        if (!match) ok = false;
    }
    // ---- --climb-scan: scoreBlocksKernel vs cpuBestBlocks ----
    printf("Blocks-path check (scoreBlocksKernel vs CPU best-blocks)...\n");
    {
        const int bm[3] = { 6, 24, 100 };
        const int bc[3][2] = { {2000, 8544}, {134, 533}, {0, 0} };
        for (int t = 0; t < 3 && ok; t++) {
            long long seed = (long long)rng();
            int m = bm[t], ccx = bc[t][0], ccz = bc[t][1];
            Best g;
            eng.runBlocks(&seed, 1, m, ccx, ccz, &g);
            Best c = cpuBestBlocks(seed, m, ccx, ccz);
            bool match = (c.score == g.score && c.cx == g.cx && c.cz == g.cz);
            printf("  m=%3d center(%d,%d) seed %lld: CPU %d blocks @(%d,%d) | GPU %d blocks @(%d,%d) -> %s\n",
                   m, ccx, ccz, seed, c.score, c.cx, c.cz, g.score, g.cx, g.cz,
                   match ? "OK" : "MISMATCH");
            if (!match) ok = false;
        }
    }
    printf(ok ? "SELF TEST PASSED - GPU matches the validated CPU core.\n"
              : "SELF TEST FAILED - do NOT trust search results!\n");
    return ok;
}

// ------------------------------------------------------------------
// Output files
// ------------------------------------------------------------------
// ---- output file ----
// The only output is the seed list - deliberately not one row per qualifying
// POSITION: that's enormous and the per-position detail is never used, since
// the refiner re-derives the exact best position anyway, at block resolution.
// <seeds-out> : each qualifying SEED at most once, only if it reached a score
//               >= SEEDS_CSV_FLOOR. Paste-able straight into slime_refine.
//               Default main/seeds.csv; --seeds-out gives each family its own.
static int SEEDS_CSV_FLOOR = 68;            // --seeds-floor
static std::string g_seedsOut = "main/seeds.csv";   // --seeds-out
static std::set<long long> g_seedsInCsv;    // layout keys already written

// Dedup key is a hash of the ACTUAL slime layout in the mask at the hotspot
// center (ccx,ccz) - i.e. the exact picture the refiner draws. Two seeds
// that render the SAME image collapse to one entry even if their seed bits
// differ; two seeds that merely share cq/score but differ by a chunk stay
// separate. FNV-1a over the masked cells.
static inline long long patKey(long long seed, int ccx, int ccz) {
    unsigned long long h = 1469598103934665603ULL;
    for (int dz = -8; dz <= 8; dz++)
        for (int dx = -8; dx <= 8; dx++) {
            if (!h_mask[(dz + 8) * 17 + (dx + 8)]) continue;
            unsigned long long b = isSlimeChunk(seed, ccx + dx, ccz + dz) ? 1ULL : 0ULL;
            h = (h ^ b) * 1099511628211ULL;
        }
    return (long long)h;
}

// Create every parent directory in a path (so --seeds-out main/seeds/foo.csv
// works on a clean checkout).
static void makeParentDirs(const std::string& path) {
    for (size_t i = 0; i < path.size(); i++) {
        if (path[i] == '/' || path[i] == '\\') {
            std::string d = path.substr(0, i);
            if (!d.empty()) SG_MKDIR(d.c_str());
        }
    }
}

// Preload seeds already in the output so a restart never re-appends them.
// (Splits on comma/space/newline, mirrors the refiner's own tokenizer.)
static void loadSeedsCsv(int ccx, int ccz) {
    FILE* g = fopen(g_seedsOut.c_str(), "r");
    if (!g) return;
    std::string tok;
    int ch;
    auto flush = [&]() {
        if (!tok.empty()) { g_seedsInCsv.insert(patKey(atoll(tok.c_str()), ccx, ccz)); tok.clear(); }
    };
    while ((ch = fgetc(g)) != EOF) {
        if (ch == ',' || ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') flush();
        else tok.push_back((char)ch);
    }
    flush();
    fclose(g);
}

static void appendHitFiles(int score, long long seed, int x, int z, bool isRecord,
                           int ccx, int ccz) {
    (void)x; (void)z; (void)isRecord;   // per-position logging was removed (see Output files above)
    // Only seeds reaching SEEDS_CSV_FLOOR, and only the FIRST time a given
    // LAYOUT qualifies. insert().second is true only on first insertion, so
    // each unique layout is written once - across batches, across restarts, and
    // across different 64-bit seeds that share the same visible pattern.
    if (score >= SEEDS_CSV_FLOOR && g_seedsInCsv.insert(patKey(seed, ccx, ccz)).second) {
        FILE* g = fopen(g_seedsOut.c_str(), "a");
        if (!g) { makeParentDirs(g_seedsOut); g = fopen(g_seedsOut.c_str(), "a"); }
        if (g) {
            fprintf(g, "%lld,", seed);   // trailing-comma one-line format kept
            fclose(g);
        } else {
            fprintf(stderr, "[WARN] cannot write %s\n", g_seedsOut.c_str());
        }
    }
}

// ------------------------------------------------------------------
// Argument parsing, shared between CLI startup and the persistent worker's
// per-spot command lines (see --worker below), so the two flag sets can
// never drift apart - a spot line means EXACTLY what the same flags mean on
// the command line, because both go through parseOneArg.
// ------------------------------------------------------------------
struct HuntArgs {
    long long seedCount = -1;
    int mChunks = 1000;
    int quickM = 0;
    int quickThreshold = -1;
    long long reportEvery = 1000;
    // AUTO-ABORT. Measured across one --emit-top batch: 128304 gave 26 hits per
    // 100M while five of eight spots gave ZERO in the same 100M. Those five are
    // pure waste - the family is either productive early or it is not. Quit them
    // and let the runner move on.
    //   --give-up-after N  : judge the spot after N seeds (0 = never give up)
    //   --give-up-hits  H  : fewer than H hits by then means quit
    // Calibrated on the real emitted 14-bit masks (counts per 20M seeds):
    //     RECORD 2000,8544   >=62: 207      weak -117856  >=62: 20
    //     batch  128304      >=62: 104      true dead spots:  ~0
    // So: judge at 20M seeds (~5s) on a PULSE floor 6 below the record floor,
    // needing 10 pulse hits. Dead spots die in 5s; every family that ever
    // produced a real 68 clears it with margin. The pulse only lowers the
    // kernel floor WHILE the judgement is pending, then reverts to full speed.
    long long giveUpAfter = 20000000;
    long long giveUpHits  = 10;
    int giveUpFloor = 0;   // 0 = recordFloor - 6
    int centerBlockX = 2048, centerBlockZ = 8576;   // default center
    int recordFloor = 68;   // collect every position at or above this score
    int seedsFloor = 68;
    std::string seedsOut = "main/seeds.csv";
    int batchOverride = 0;  // 0 = auto (VRAM/grid-limited); else fixed batch size
    // Fused hunt kernel: ON by default, --no-fused to opt out. See the
    // original comment (preserved below at the top of runHunt) for why.
    bool useFused = true;
    bool noFused  = false;  // --no-fused: force the two-kernel path
    unsigned long long rngSeed = 0; bool haveRngSeed = false;  // reproducible hunt
    // Constrain generated seeds to a low-bit residue class. High-scoring
    // seeds at a FIXED hotspot live in a narrow low-bit class (slime chunks use
    // only the low 48 bits). Forcing those bits makes tail hits ~100-1000x more
    // common. Per-hotspot: compute the mask/val for your coordinate, pass here.
    // seed = (rng & ~fixMask) | (fixVal & fixMask). Defaults 0 = unconstrained.
    unsigned long long fixMask = 0, fixVal = 0;
    // --enumerate: exhaustively walk the masked family instead of sampling it.
    bool enumerate = false;
    // --time-limit-ms: wall-clock cutoff for ONE hunt (0 = none - the CLI's
    // old behaviour, unlimited except for --seed-count/--give-up-after). See
    // --worker below for why this exists: a persistent worker cannot bound a
    // PRODUCTIVE spot's hunt by killing the process, since that would tear
    // down the very CUDA context it exists to keep alive. Denominated in wall
    // time, unlike --give-up-after (seeds) - this is a caller's time BUDGET
    // per spot, not a productivity judgement.
    long long timeLimitMs = 0;
    // --no-stream: force the original single-buffered batch loop even when
    // the fused kernel is active. Escape hatch for the double-buffered
    // GpuEngine::beginFusedBatch/collectFusedBatch pipeline (see GpuEngine),
    // same role as --no-fused - if the streamed path ever misbehaves, this
    // falls back to the proven synchronous runHitsGen loop with no rebuild.
    bool noStream = false;
};

struct ModeFlags {
    long long fixedSeed = 0; bool haveFixedSeed = false;
    bool runSelfTest = false;
    // --climb-scan: GPU-coarse pass over --seed's high-bit neighbors (see
    // README BUILT: GPU --climb-scan). Chunk-aligned only - hand the winners
    // to slime_refine --climb for the final block-precision answer.
    bool climbScan = false;
    int climbLo = 35, climbBits = 13, climbTop = 10;
    bool workerMode = false;   // --worker: persistent command-loop mode
};

// Parses the argument at argv[i] (consuming a following value token if the
// flag needs one), advancing i past whatever it consumed. Returns false and
// fills err on an unknown flag or a missing value - the caller decides what
// to do with that (CLI startup exits; the worker reports and moves to the
// next spot line, see runWorkerLoop).
static bool parseOneArg(int argc, char** argv, int& i, HuntArgs& a, ModeFlags& m, std::string& err) {
    auto need = [&](const char* name) -> const char* {
        if (i + 1 >= argc) { err = std::string("Missing value for ") + name; return nullptr; }
        return argv[++i];
    };
    const char* s = argv[i];
    const char* v;
    if      (!strcmp(s, "--seed"))            { if (!(v = need(s))) return false; m.fixedSeed = atoll(v); m.haveFixedSeed = true; }
    else if (!strcmp(s, "--seed-count"))      { if (!(v = need(s))) return false; a.seedCount = atoll(v); }
    else if (!strcmp(s, "--m-chunks"))        { if (!(v = need(s))) return false; a.mChunks = atoi(v); }
    else if (!strcmp(s, "--quick-m-chunks"))  { if (!(v = need(s))) return false; a.quickM = atoi(v); }
    else if (!strcmp(s, "--quick-threshold")) { if (!(v = need(s))) return false; a.quickThreshold = atoi(v); }
    else if (!strcmp(s, "--report-every"))    { if (!(v = need(s))) return false; a.reportEvery = atoll(v); }
    else if (!strcmp(s, "--give-up-after"))   { if (!(v = need(s))) return false; a.giveUpAfter = atoll(v); }
    else if (!strcmp(s, "--give-up-hits"))    { if (!(v = need(s))) return false; a.giveUpHits  = atoll(v); }
    else if (!strcmp(s, "--give-up-floor"))   { if (!(v = need(s))) return false; a.giveUpFloor = atoi(v); }
    else if (!strcmp(s, "--center-x"))        { if (!(v = need(s))) return false; a.centerBlockX = atoi(v); }
    else if (!strcmp(s, "--center-z"))        { if (!(v = need(s))) return false; a.centerBlockZ = atoi(v); }
    else if (!strcmp(s, "--record-floor"))    { if (!(v = need(s))) return false; a.recordFloor = atoi(v); }
    else if (!strcmp(s, "--seeds-floor"))     { if (!(v = need(s))) return false; a.seedsFloor = atoi(v); }
    else if (!strcmp(s, "--seeds-out"))       { if (!(v = need(s))) return false; a.seedsOut = v; }
    else if (!strcmp(s, "--batch"))           { if (!(v = need(s))) return false; a.batchOverride = atoi(v); }
    else if (!strcmp(s, "--fix-mask"))        { if (!(v = need(s))) return false; a.fixMask = strtoull(v, nullptr, 0); }
    else if (!strcmp(s, "--fix-val"))         { if (!(v = need(s))) return false; a.fixVal  = strtoull(v, nullptr, 0); }
    else if (!strcmp(s, "--enumerate"))       { a.enumerate = true; }
    else if (!strcmp(s, "--rng-seed"))        { if (!(v = need(s))) return false; a.rngSeed = (unsigned long long)strtoull(v, nullptr, 10); a.haveRngSeed = true; }
    // --fused is now the default; kept as an accepted no-op so hunt commands
    // written by older builds (and any commands_*.csv still on disk) parse.
    else if (!strcmp(s, "--fused"))           { a.useFused = true; }
    else if (!strcmp(s, "--no-fused"))        { a.noFused  = true; }
    else if (!strcmp(s, "--no-stream"))       { a.noStream = true; }
    else if (!strcmp(s, "--time-limit-ms"))   { if (!(v = need(s))) return false; a.timeLimitMs = atoll(v); }
    else if (!strcmp(s, "--self-test"))       { m.runSelfTest = true; }
    else if (!strcmp(s, "--climb-scan"))      { m.climbScan = true; }
    else if (!strcmp(s, "--climb-lo"))        { if (!(v = need(s))) return false; m.climbLo = atoi(v); }
    else if (!strcmp(s, "--climb-bits"))      { if (!(v = need(s))) return false; m.climbBits = atoi(v); }
    else if (!strcmp(s, "--climb-top"))       { if (!(v = need(s))) return false; m.climbTop = atoi(v); }
    else if (!strcmp(s, "--worker"))          { m.workerMode = true; }
    else { err = std::string("Unknown argument: ") + s; return false; }
    return true;
}

// One full hunt (what used to be the tail of main()), extracted so a
// persistent --worker process can call it repeatedly on the SAME GpuEngine -
// no new CUDA context, no re-upload of the mask/weight constants, between
// spots. Returns false with `err` set on a bad config; never exit()s, since
// a --worker command loop must survive one bad spot line.
static bool runHunt(GpuEngine& eng, const HuntArgs& args, std::string& err) {
    int mChunks = args.mChunks;
    int quickM = args.quickM;
    int quickThreshold = args.quickThreshold;
    long long reportEvery = args.reportEvery;
    long long giveUpAfter = args.giveUpAfter;
    long long giveUpHits  = args.giveUpHits;
    int giveUpFloor = args.giveUpFloor;
    int recordFloor = args.recordFloor;
    int batchOverride = args.batchOverride;
    bool useFused = args.useFused;
    unsigned long long rngSeed = args.rngSeed; bool haveRngSeed = args.haveRngSeed;
    unsigned long long fixMask = args.fixMask, fixVal = args.fixVal;
    bool enumerate = args.enumerate;
    long long seedCount = args.seedCount;

    if (mChunks < 1 || mChunks > 16000) {
        err = "--m-chunks must be between 1 and 16000";
        return false;
    }
    int ccx = (args.centerBlockX >= 0) ? args.centerBlockX / 16 : -(((-args.centerBlockX) + 15) / 16);
    int ccz = (args.centerBlockZ >= 0) ? args.centerBlockZ / 16 : -(((-args.centerBlockZ) + 15) / 16);
    if ((long long)(ccx < 0 ? -ccx : ccx) + mChunks + 8 > 1874000 ||
        (long long)(ccz < 0 ? -ccz : ccz) + mChunks + 8 > 1874000) {
        err = "center +/- m-chunks exceeds the world border";
        return false;
    }
    if (seedCount < 0) {
        err = "seed-count required for a hunt (use --seed-count 0 for unlimited)";
        return false;
    }
    bool twoStage = quickM > 0 && quickM < mChunks;
    if (quickM > 0 && quickThreshold < 0) {
        err = "--quick-m-chunks requires --quick-threshold";
        return false;
    }
    if (twoStage) {
        err = "two-stage hunting (--quick-m-chunks) is not supported; "
              "drop --quick-m-chunks/--quick-threshold and run single-stage.";
        return false;
    }

    // Per-spot state reset. g_seedsOut/SEEDS_CSV_FLOOR/g_seedsInCsv are
    // globals shared with appendHitFiles/loadSeedsCsv; a persistent worker
    // calling runHunt() many times in a row must not let spot N+1 inherit
    // spot N's dedup set or output path - a single CLI invocation only ever
    // calls this once, so this reset is a no-op there.
    SEEDS_CSV_FLOOR = args.seedsFloor;
    g_seedsOut = args.seedsOut;
    g_seedsInCsv.clear();

    // --rng-seed makes the hunt reproducible so two builds (or two batch
    // sizes) can be run over the IDENTICAL seed sequence and their outputs
    // diffed - the definitive proof that a speed change didn't skip or alter
    // any work. Default stays time+entropy seeded (non-reproducible).
    // Root of the hunt's seed stream. Seed i of the run is
    // huntSeedAt(streamBase, i, fixMask, fixVal), computed on the GPU (and
    // recomputed on the host for the rare hit). --rng-seed still makes a run
    // fully reproducible - it just roots splitmix64 instead of mt19937_64.
    uint64_t streamBase =
        haveRngSeed ? rngSeed
                    : ((uint64_t)std::chrono::steady_clock::now().time_since_epoch().count()
                       ^ ((uint64_t)std::random_device{}() << 32));

    int batch = (batchOverride > 0)
                    ? eng.autoBatch(mChunks, batchOverride)   // clamp to VRAM/grid
                    : eng.autoBatch(mChunks, 65535);          // auto: as big as fits

    // Decide fused vs two-kernel path. Fused only when opted in AND the bit
    // window fits the shared budget (small m). Otherwise the proven path.
    if (args.noFused) useFused = false;
    // Falling back at large m is routine now that fused is the default, so it is
    // not worth a warning line - the "kernel=" field in the banner below already
    // states which path actually ran.
    bool fusedActive = useFused && (GpuEngine::fusedShared(mChunks) > 0);

    bool streamedActive = !enumerate && fusedActive && !args.noStream;
    std::string countLabel = (seedCount == 0) ? "unlimited (Ctrl+C to stop)"
                                              : std::to_string(seedCount);
    printf("Multi-seed GPU hunt: %s seeds, m-chunks=%d, "
           "center chunk (%d,%d) = block (%d,%d), batch=%d%s, kernel=%s%s\n",
           countLabel.c_str(), mChunks, ccx, ccz, 16 * ccx, 16 * ccz, batch,
           batchOverride > 0 ? " (--batch)" : " (auto)",
           fusedActive ? "fused" : "two-kernel",
           streamedActive ? "+streamed" : "");
    if (haveRngSeed)
        printf("Deterministic RNG seed: %llu (reproducible run)\n", rngSeed);
    if (fixMask) {
        int nb = 0; for (unsigned long long mm = fixMask; mm; mm &= mm - 1) nb++;
        printf("Seed constraint ACTIVE: seed = (rng & ~0x%llX) | 0x%llX  "
               "(forcing %d low bits -> ~%.0fx smaller class)\n",
               fixMask, (fixVal & fixMask), nb, (double)(1ULL << nb));
    }
    printf("Collecting every seed scoring >= %d.\n", recordFloor);
    printf("  %s : each unique layout once, only if it reached >= %d\n\n",
           g_seedsOut.c_str(), SEEDS_CSV_FLOOR);

    makeParentDirs(g_seedsOut);
    loadSeedsCsv(ccx, ccz);   // remember seeds already listed so we never duplicate them
    if (!g_seedsInCsv.empty())
        printf("(%s already lists %zu seed(s); they won't be re-added.)\n\n",
               g_seedsOut.c_str(), g_seedsInCsv.size());

    int recordScore = recordFloor - 1;   // first hit >= floor announces NEW RECORD
    if (giveUpFloor <= 0) giveUpFloor = recordFloor - 6;
    if (giveUpFloor < 1)  giveUpFloor = 1;
    long long hitsTotal = 0;    // hits >= recordFloor (printed, recorded)
    long long pulseHits = 0;    // hits >= giveUpFloor (silent, drives give-up)
    long long tested = 0;
    long long nextReport = reportEvery;
    auto start = std::chrono::steady_clock::now();

    std::vector<long long> seeds(batch);
    std::vector<GpuEngine::Hit> hits;

    // --enumerate: walk the masked family EXACTLY once each instead of drawing
    // from it at random. Only the low 48 bits of a world seed reach the slime
    // function (slime_core.h truncates to 2^48), so a --fix-mask of nb bits
    // leaves a family of exactly 2^(48-nb) distinct layouts - finite, and small
    // enough to exhaust: a 14-bit mask is 2^34 = 1.7e10 seeds.
    //
    // Random sampling never terminates in a useful sense. Drawing WITH
    // replacement from a family of size F, the chance a specific seed has been
    // seen after N draws is 1-(1-1/F)^N, so ~4.6F draws for 99% and no
    // guarantee ever. Enumeration finds it in at most F, with certainty, and so
    // is ~4.6x less work for a result that is actually a proof: if the record
    // is in the family and the run completes, it WAS tested.
    //
    // freeMask is the complement inside 48 bits; enumIdx is scattered across
    // those positions (a software PDEP - one iteration per free bit, cheap next
    // to the per-seed cell scan).
    const unsigned long long SEED48 = (1ULL << 48) - 1;
    unsigned long long freeMask = ~fixMask & SEED48;
    int nFree = 0; for (unsigned long long mm = freeMask; mm; mm &= mm - 1) nFree++;
    unsigned long long enumTotal = (nFree >= 64) ? ~0ULL : (1ULL << nFree);
    unsigned long long enumIdx = 0;
    if (enumerate) {
        printf("ENUMERATE: walking all %.4g seeds of the %d-bit family exactly once\n"
               "  (mask 0x%llX val 0x%llX -> %d free bits). Exhaustive: if a record\n"
               "  exists in this family, this run WILL test it.\n",
               (double)enumTotal, 48 - nFree, fixMask, (fixVal & fixMask), nFree);
        if (seedCount == 0) seedCount = (long long)enumTotal;
    }

    // Per-batch bookkeeping (decoded hits -> printed/saved records, tested
    // count, periodic report, give-up/time-limit checks), shared between the
    // streamed and single-buffered loops below so the two paths can never
    // drift in what "give up" or "time limit" mean. Returns false to mean
    // "stop the loop now" (give-up or time-limit fired).
    auto processBatch = [&](const std::vector<GpuEngine::Hit>& hitsIn, int n, long long batchBase) -> bool {
        for (const auto& h : hitsIn) {
            if (h.score >= giveUpFloor) pulseHits++;
            if (h.score < recordFloor) continue;   // pulse-only hit: count, stay silent
            // Recompute rather than copy the batch back: hits are rare, and
            // huntSeedAt is the same __host__ __device__ function the kernel
            // used, so the value cannot disagree.
            long long seed = enumerate ? seeds[h.seedIdx]
                                       : huntSeedAt(streamBase, batchBase + h.seedIdx,
                                                    fixMask, fixVal);
            int x = 16 * (h.cx + ccx);
            int z = 16 * (h.cz + ccz);
            bool isRecord = h.score > recordScore;
            if (isRecord) {
                recordScore = h.score;
                printf("NEW RECORD %d   seed=%lld  x=%d z=%d\n", h.score, seed, x, z);
            } else {
                printf("%d   seed=%lld  x=%d z=%d\n", h.score, seed, x, z);
            }
            fflush(stdout);
            appendHitFiles(h.score, seed, x, z, isRecord, ccx, ccz);
            hitsTotal++;
        }

        tested += n;
        if (reportEvery > 0 && tested >= nextReport) {
            double secs = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - start).count();
            if (hitsTotal > 0)
                printf("Tested %lld seeds (%.1f seeds/s). Hits >= %d: %lld. Record: %d\n",
                       tested, tested / secs, recordFloor, hitsTotal, recordScore);
            else
                printf("Tested %lld seeds (%.1f seeds/s). Nothing at or above %d yet.\n",
                       tested, tested / secs, recordFloor);
            fflush(stdout);
            while (nextReport <= tested) nextReport += reportEvery;
        }
        // Auto-abort: a family that has not produced --give-up-hits by
        // --give-up-after seeds is not worth more GPU time. Exiting (rather than
        // idling) lets a runner using WaitForExit start the next spot at once.
        if (giveUpAfter > 0 && tested >= giveUpAfter && pulseHits < giveUpHits) {
            double secs = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - start).count();
            printf("GIVING UP: %lld pulse hits at count >= %d (< %lld needed) after %lld seeds "
                   "in %.0fs. This family is not productive; moving on.\n",
                   pulseHits, giveUpFloor, giveUpHits, tested, secs);
            fflush(stdout);
            return false;
        }
        // Wall-clock cutoff (--time-limit-ms), denominated in TIME rather than
        // seeds like --give-up-after above. This exists for --worker: a caller
        // running many spots through one persistent process can bound a
        // PRODUCTIVE spot's hunt this way; the give-up check above only ever
        // stops a DEAD one. Works standalone in CLI mode too (0 = disabled,
        // the old unlimited-except-for-give-up/--seed-count behaviour).
        if (args.timeLimitMs > 0) {
            double ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - start).count();
            if (ms >= (double)args.timeLimitMs) {
                printf("TIME LIMIT: stopping after %.0fms, %lld seeds tested (%lld hits >= %d).\n",
                       ms, tested, hitsTotal, recordFloor);
                fflush(stdout);
                return false;
            }
        }
        return true;
    };

    // Streamed double-buffered loop: only for the common case (GPU-generated
    // seeds, fused kernel active, not explicitly disabled). --enumerate keeps
    // the original loop below since it fills `seeds` host-side per batch
    // (a scatter across free bits, not an RNG draw) - not worth threading
    // through two in-flight slots for a comparatively rare, already-bounded
    // mode. See GpuEngine::beginFusedBatch/collectFusedBatch for why this
    // exists: it closes the ~15% GPU-idle gap a single synchronous
    // cudaMemcpy per batch left on the table (measured live via nvidia-smi).
    if (!enumerate && fusedActive && !args.noStream) {
        bool haveCur = (seedCount == 0 || tested < seedCount);
        int curN = 0; long long curBase = 0; long long launched = 0;
        if (haveCur) {
            curN = batch;
            if (seedCount > 0 && seedCount - launched < curN) curN = (int)(seedCount - launched);
            if (curN <= 0) haveCur = false;
        }
        int curSlot = 0;
        if (haveCur) {
            bool armed0 = (giveUpAfter > 0 && launched < giveUpAfter);
            int floor0 = armed0 ? (giveUpFloor < recordFloor ? giveUpFloor : recordFloor) : recordFloor;
            curBase = launched;
            eng.beginFusedBatch(curSlot, curN, mChunks, ccx, ccz, floor0, streamBase, curBase, fixMask, fixVal);
            launched += curN;
        }

        bool keepGoing = true;
        while (haveCur && keepGoing) {
            // Decide + launch the NEXT batch into the OTHER slot BEFORE
            // collecting the current one - this IS the overlap: the GPU
            // always has a second batch queued while the host waits on
            // whichever one it is currently blocked on.
            int nextSlot = 1 - curSlot;
            bool haveNext = (seedCount == 0 || launched < seedCount);
            int nextN = 0; long long nextBase = 0;
            if (haveNext) {
                nextN = batch;
                if (seedCount > 0 && seedCount - launched < nextN) nextN = (int)(seedCount - launched);
                if (nextN <= 0) haveNext = false;
            }
            if (haveNext) {
                bool armedNext = (giveUpAfter > 0 && launched < giveUpAfter);
                int floorNext = armedNext ? (giveUpFloor < recordFloor ? giveUpFloor : recordFloor) : recordFloor;
                nextBase = launched;
                eng.beginFusedBatch(nextSlot, nextN, mChunks, ccx, ccz, floorNext, streamBase, nextBase, fixMask, fixVal);
                launched += nextN;
            }

            eng.collectFusedBatch(curSlot, mChunks, hits);
            keepGoing = processBatch(hits, curN, curBase);

            if (!keepGoing && haveNext) {
                // give-up/time-limit fired while the NEXT batch was already
                // queued on the other stream - drain it (its results are
                // discarded; we already decided to stop) so nothing is left
                // in flight when this hunt returns. See drainStreams(): a
                // persistent worker reuses these same streams for the next
                // spot, and streams execute strictly in submission order.
                eng.collectFusedBatch(nextSlot, mChunks, hits);
            }

            curSlot = nextSlot; curN = nextN; curBase = nextBase; haveCur = haveNext;
        }
    } else {
        // ---- Original single-buffered loop: --enumerate, --no-fused
        // fallback (large m), or --no-stream. Unchanged from before the
        // streamed path existed. ----
        while (seedCount == 0 || tested < seedCount) {
            int n = batch;
            if (seedCount > 0 && seedCount - tested < n) n = (int)(seedCount - tested);
            if (enumerate) {
                if (enumIdx >= enumTotal) {
                    printf("\nENUMERATION COMPLETE: all %.4g seeds of this family tested.\n",
                           (double)enumTotal);
                    break;
                }
                for (int i = 0; i < n; i++) {
                    unsigned long long v = enumIdx + (unsigned long long)i, s = 0, mm = freeMask;
                    while (mm) { unsigned long long lo = mm & (~mm + 1ULL);
                                if (v & 1ULL) s |= lo; v >>= 1; mm &= mm - 1; }
                    seeds[i] = (long long)(s | (fixVal & fixMask));
                }
                enumIdx += (unsigned long long)n;
            }
            // (no host-side RNG loop any more - the non-enumerate path generates
            // its seeds on the GPU below, which is the whole point of this change)

            // While the give-up judgement is pending, run the kernel at the lower
            // pulse floor so the counter has something to count; afterwards revert
            // to recordFloor so the verify path is not flooded with low hits.
            bool armed = (giveUpAfter > 0 && tested < giveUpAfter);
            int kernelFloor = armed ? (giveUpFloor < recordFloor ? giveUpFloor : recordFloor)
                                    : recordFloor;
            // batchBase: this batch's first index in the global seed stream. Taken
            // BEFORE `tested` advances, so a hit's seed can be recomputed exactly.
            long long batchBase = tested;
            if (enumerate) {
                // --enumerate builds its seeds host-side (a scatter across the free
                // bits, not an RNG draw), so it keeps the upload path.
                if (fusedActive) eng.runHitsFused(seeds.data(), n, mChunks, ccx, ccz, kernelFloor, hits);
                else             eng.runHits(seeds.data(), n, mChunks, ccx, ccz, kernelFloor, hits);
            } else {
                // Seeds are produced ON THE GPU - no CPU RNG, no H2D copy. See
                // genSeedsKernel for the measurement that motivated this.
                eng.runHitsGen(n, mChunks, ccx, ccz, kernelFloor, streamBase, batchBase,
                               fixMask, fixVal, fusedActive, hits);
            }

            if (!processBatch(hits, n, batchBase)) break;
        }
    }
    eng.drainStreams();

    if (hitsTotal > 0) {
        printf("\nFINAL: %lld hits >= %d collected. Record: %d\n",
               hitsTotal, recordFloor, recordScore);
    } else {
        printf("\nFINAL: no positions reached %d.\n", recordFloor);
    }
    return true;
}

// GPU-coarse high-bit neighbor sweep of one known seed (see README BUILT:
// GPU-ACCELERATED CLIMB). Extracted from main() the same way runHunt() was,
// so --worker can call it repeatedly on the SAME GpuEngine too - a
// productive spot's climb sweep used to pay its own separate ~199ms spawn
// on top of the hunt's, even after the hunt itself moved onto the worker.
// Never exit()s; returns false with `err` set instead, same contract as
// runHunt(), so one bad --climb-scan line can't take the worker down.
static bool runClimbScan(GpuEngine& eng, const HuntArgs& args, const ModeFlags& mode, std::string& err) {
    if (args.mChunks < 1 || args.mChunks > 16000) {
        err = "--m-chunks must be between 1 and 16000";
        return false;
    }
    int ccx = (args.centerBlockX >= 0) ? args.centerBlockX / 16 : -(((-args.centerBlockX) + 15) / 16);
    int ccz = (args.centerBlockZ >= 0) ? args.centerBlockZ / 16 : -(((-args.centerBlockZ) + 15) / 16);
    if ((long long)(ccx < 0 ? -ccx : ccx) + args.mChunks + 8 > 1874000 ||
        (long long)(ccz < 0 ? -ccz : ccz) + args.mChunks + 8 > 1874000) {
        err = "center +/- m-chunks exceeds the world border";
        return false;
    }
    if (!mode.haveFixedSeed) { err = "--climb-scan requires --seed <base-seed>"; return false; }
    if (mode.climbBits < 1 || mode.climbBits > 30) { err = "--climb-bits must be 1..30"; return false; }
    long long cside = 2LL * args.mChunks + 1;
    if (cside * cside >= (1LL << 24)) {
        err = "m-chunks too large for --climb-scan (cside^2 must be < 2^24 - this mode "
              "is for sweeping a known seed's immediate neighborhood, not a wide hunt)";
        return false;
    }
    long long variantCount = 1LL << mode.climbBits;
    long long mask = ((1LL << mode.climbBits) - 1) << mode.climbLo;
    printf("--climb-scan: base seed %lld, sweeping bits %d-%d (%lld variants), "
           "m-chunks=%d, center chunk (%d,%d) = block (%d,%d)\n",
           mode.fixedSeed, mode.climbLo, mode.climbLo + mode.climbBits - 1, variantCount,
           args.mChunks, ccx, ccz, 16 * ccx, 16 * ccz);

    int batch = eng.autoBatch(args.mChunks, 65535);
    std::vector<long long> seeds(batch);
    std::vector<Best> results(batch);
    struct Ranked { long long seed; Best b; };
    std::vector<Ranked> all;
    all.reserve((size_t)std::min<long long>(variantCount, 20000000LL));
    for (long long base = 0; base < variantCount; base += batch) {
        int n = (int)std::min<long long>(batch, variantCount - base);
        for (int i = 0; i < n; i++) {
            long long k = base + i;
            seeds[i] = (mode.fixedSeed & ~mask) | (k << mode.climbLo);
        }
        eng.runBlocks(seeds.data(), n, args.mChunks, ccx, ccz, results.data());
        for (int i = 0; i < n; i++) all.push_back(Ranked{ seeds[i], results[i] });
    }
    std::sort(all.begin(), all.end(),
              [](const Ranked& a, const Ranked& b) { return a.b.score > b.b.score; });
    int shown = (int)std::min<size_t>((size_t)mode.climbTop, all.size());
    printf("\ntop %d by chunk-aligned blocks (coarse - a GPU pre-filter, not the final\n"
           "answer: hand these seeds to slime_refine --seeds <csv> --center-x %d --center-z %d\n"
           "--radius 6 --climb for the real block-precision cq):\n\n",
           shown, 16 * ccx, 16 * ccz);
    printf("      blocks   cq(approx)  chunk-aligned position   seed\n");
    for (int i = 0; i < shown; i++) {
        const Ranked& r = all[i];
        printf("  %8d   %8.2f   (%8d,%8d)   %lld\n",
               r.b.score, r.b.score / 256.0, 16 * (r.b.cx + ccx), 16 * (r.b.cz + ccz), r.seed);
    }
    return true;
}

// ------------------------------------------------------------------
// --worker: persistent command-loop mode.
//
// A fresh slime_gpu.exe process pays ~199ms for CUDA context creation +
// constant uploads + teardown (measured on this box). hunt_pipeline.ps1
// spawns one process per triage spot (up to -Top, default 120) plus a
// handful of pushes, so that cost was being paid up to ~120+ times per
// cycle for pure plumbing, not hunting - up to ~16% of a cycle, worse on
// dead families where give-up costs ~0.37s of real work and spawn is ~35%
// of that spot's total cost. --worker pays it once: main() still does its
// one-time setup (mask/weights/GpuEngine) exactly as any other mode, then
// this loop reads one hunt's worth of flags per stdin line and calls
// runHunt() again on the SAME eng - no new context, no re-upload.
//
// Protocol: one line in, one hunt run, "===SPOT-DONE===" printed and
// flushed when it is safe to send the next line. "--quit" or EOF ends the
// worker cleanly either way. A line that fails to parse or validate is
// reported to stderr and does NOT tear down the worker - unlike the CLI
// path (which exits on a bad flag), one bad spot must not kill every spot
// queued after it in the same cycle.
static void runWorkerLoop(GpuEngine& eng) {
    printf("WORKER READY\n");
    fflush(stdout);
    std::string line;
    while (std::getline(std::cin, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
        // Defensive: some stdin writers (e.g. .NET's StreamWriter, which is
        // what a PowerShell-driven Process.StandardInput uses) emit a UTF-8
        // BOM preamble on the very first write, which would otherwise get
        // parsed as part of the first flag and fail with "Unknown argument".
        // Same class of bug as the project's existing BOM/seed-file issue -
        // strip it, same defensive pattern as hunt_pipeline.ps1's SeedList.
        if (line.size() >= 3 && (unsigned char)line[0] == 0xEF &&
            (unsigned char)line[1] == 0xBB && (unsigned char)line[2] == 0xBF)
            line.erase(0, 3);
        if (line.empty()) continue;
        if (line == "--quit") break;

        // Plain whitespace tokenizer: spot lines are "--flag value" pairs
        // built by hunt_pipeline.ps1 / printed by hotspot_scan - never
        // quoted, never spaced within one value.
        std::vector<std::string> toks;
        {
            std::string cur;
            for (char c : line) {
                if (c == ' ' || c == '\t') { if (!cur.empty()) { toks.push_back(cur); cur.clear(); } }
                else cur.push_back(c);
            }
            if (!cur.empty()) toks.push_back(cur);
        }
        std::vector<char*> fargv;
        fargv.push_back((char*)"spot");
        for (auto& t : toks) fargv.push_back(&t[0]);

        HuntArgs a;
        ModeFlags m;
        std::string perr;
        bool ok = true;
        for (int i = 1; i < (int)fargv.size() && ok; i++) {
            if (!parseOneArg((int)fargv.size(), fargv.data(), i, a, m, perr)) ok = false;
        }
        // A plain hunt or a --climb-scan (which needs its own --seed) are the
        // only two valid spot-line shapes; --self-test/--worker/a bare --seed
        // single-check are CLI-only.
        if (ok && (m.runSelfTest || m.workerMode || (m.haveFixedSeed && !m.climbScan))) {
            perr = "spot command must be a plain hunt or a --climb-scan "
                   "(no --self-test/--worker/bare --seed check)";
            ok = false;
        }
        if (ok) ok = m.climbScan ? runClimbScan(eng, a, m, perr) : runHunt(eng, a, perr);
        if (!ok) {
            fprintf(stderr, "[WORKER] %s\n", perr.c_str());
            fflush(stderr);
        }
        printf("===SPOT-DONE===\n");
        fflush(stdout);
    }
}

int main(int argc, char** argv) {
    HuntArgs args;
    ModeFlags mode;
    for (int i = 1; i < argc; i++) {
        std::string perr;
        if (!parseOneArg(argc, argv, i, args, mode, perr)) {
            fprintf(stderr, "%s\n", perr.c_str());
            return 1;
        }
    }

    int maskCount = buildIntersectMask(h_mask);
    if (maskCount != 226) {
        fprintf(stderr, "FATAL: mask count %d != 226\n", maskCount);
        return 1;
    }
    int8_t A[17], B[17];
    if (!buildMaskIntervals(h_mask, A, B)) {
        fprintf(stderr, "FATAL: mask rows not contiguous; fast path invalid\n");
        return 1;
    }
    // The score kernel uses hardcoded LO/HI literals (kRowLO/kRowWD); verify
    // they match the mask-derived intervals and refuse to run on any mismatch.
    for (int k = 0; k < 17; k++) {
        if (A[k] + 8 != kRowLO[k] || B[k] - A[k] + 1 != kRowWD[k]) {
            fprintf(stderr, "FATAL: literal offset/width table mismatch at k=%d\n", k);
            return 1;
        }
    }

    // --climb-scan: build the 9 per-row weight-plane masks (see
    // computeStripBlocks) from the SAME validated kRowLO/kRowWD geometry the
    // FATAL check above just confirmed, and upload once.
    buildBlockWeights(h_weights);
    {
        std::vector<uint32_t> planeMask(17 * 9, 0);
        for (int k = 0; k < 17; k++) {
            int dz = k - 8;
            for (int c = 0; c < kRowWD[k]; c++) {
                int dx = (kRowLO[k] + c) - 8;
                int w = h_weights[(dz + 8) * 17 + (dx + 8)];
                for (int p = 0; p < 9; p++)
                    if ((w >> p) & 1) planeMask[k * 9 + p] |= (1u << c);
            }
        }
        CUDA_CHECK(cudaMemcpyToSymbol(cRowPlaneMask, planeMask.data(), planeMask.size() * sizeof(uint32_t)));
    }

    GpuEngine eng;

    // --worker: persistent command-loop mode. Bypasses the single-invocation
    // mChunks/center checks below entirely - each spot line is validated
    // independently inside runHunt(), every time one is read.
    if (mode.workerMode) {
        runWorkerLoop(eng);
        eng.release();
        return 0;
    }

    if (mode.runSelfTest) {
        bool ok = selfTest(eng);
        eng.release();
        return ok ? 0 : 1;
    }

    if (args.mChunks < 1 || args.mChunks > 16000) {
        fprintf(stderr, "--m-chunks must be between 1 and 16000\n");
        return 1;
    }
    // center in blocks -> chunk coords (floor division, exact for negatives)
    int ccx = (args.centerBlockX >= 0) ? args.centerBlockX / 16 : -(((-args.centerBlockX) + 15) / 16);
    int ccz = (args.centerBlockZ >= 0) ? args.centerBlockZ / 16 : -(((-args.centerBlockZ) + 15) / 16);
    if ((long long)(ccx < 0 ? -ccx : ccx) + args.mChunks + 8 > 1874000 ||
        (long long)(ccz < 0 ? -ccz : ccz) + args.mChunks + 8 > 1874000) {
        fprintf(stderr, "center +/- m-chunks exceeds the world border\n");
        return 1;
    }

    if (mode.climbScan) {
        std::string cerr;
        if (!runClimbScan(eng, args, mode, cerr)) {
            fprintf(stderr, "%s\n", cerr.c_str());
            eng.release();
            return 1;
        }
        eng.release();
        return 0;
    }

    if (mode.haveFixedSeed) {
        printf("Single seed %lld, m-chunks %d, center chunk (%d,%d)\n",
               mode.fixedSeed, args.mChunks, ccx, ccz);
        Best b;
        eng.run(&mode.fixedSeed, 1, args.mChunks, ccx, ccz, &b);
        printf("Best: score=%d at x=%d z=%d (chunk %d,%d)\n",
               b.score, 16 * (b.cx + ccx), 16 * (b.cz + ccz), b.cx + ccx, b.cz + ccz);
        printf("Compare with: java -jar SlimeFinder.jar --seed %lld --m-chunks %d\n",
               mode.fixedSeed, args.mChunks);
        eng.release();
        return 0;
    }

    if (args.seedCount < 0) {
        fprintf(stderr,
            "Usage:\n"
            "  slime_gpu --self-test\n"
            "  slime_gpu --seed <s> --m-chunks <m>\n"
            "  slime_gpu --seed-count <n | 0 = run until Ctrl+C> --m-chunks <m>\n"
            "            [--quick-m-chunks <q> --quick-threshold <t>] [--report-every <k>]\n"
            "  slime_gpu --climb-scan --seed <s> --center-x X --center-z Z --m-chunks <m>\n"
            "            [--climb-lo 35 --climb-bits 13 --climb-top 10]\n"
            "            GPU-coarse high-bit neighbor sweep (chunk resolution) - hand the\n"
            "            top results to slime_refine --climb for the exact answer.\n"
            "  slime_gpu --worker\n"
            "            Persistent command-loop mode: keeps one CUDA context alive and\n"
            "            reads spot hunt commands from stdin, one per line, until --quit\n"
            "            or EOF. Each line takes the same flags as a normal hunt\n"
            "            invocation (minus slime_gpu.exe itself, plus --time-limit-ms);\n"
            "            prints ===SPOT-DONE=== after each.\n");
        return 1;
    }

    std::string herr;
    if (!runHunt(eng, args, herr)) {
        fprintf(stderr, "%s\n", herr.c_str());
        eng.release();
        return 1;
    }
    eng.release();
    return 0;
}
