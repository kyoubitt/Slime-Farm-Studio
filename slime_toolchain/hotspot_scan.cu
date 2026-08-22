// hotspot_scan.cu
// ===========================================================================
// WHY THE SCORING AND DERIVATION WORK THE WAY THEY DO
// ---------------------------------------------------------------------------
// VARIANCE IS A GATE, NOT A RANKER. Measured tail distributions (100M
// single-center samples per location) showed variance-ranking picks the
// WRONG order:
//
//       location            var    p(>=52)   p(>=55)   p(>=57)   max
//       (125,533)  record  28.8    9.7e-7    1.8e-7    6.0e-8    60
//       (689,533)  dud     32.7    7.9e-7    4.0e-8    1.0e-8    57
//       (459,436)  ok      32.3    2.2e-6    2.2e-7    6.0e-8    62
//
//     Variance ranks dud > ok > record. The deep tail says ok ~ record >> dud.
//     Higher variance buys a fatter tail in the 40s and a THINNER one past
//     ~51 - the curves for a real spot and a dud actually CROSS partway up,
//     so anything derived/validated near that crossing point looks identical
//     regardless of which side it's really on. Variance is a usable GATE
//     (independent-binomial baseline is 20.34, real spots run 28-33) but it
//     is noise-to-anticorrelated as a RANKER - --var-min filters, --score-t
//     ranks.
//
// SCORE = p(count >= --deep-t | derived mask), measured on a held-out
//         sample. Throughput (seeds/s) is constant across locations, so this
//         number IS hits-per-second - directly comparable across spots.
//
// DERIVATION = escalating-threshold bootstrap (derive() below). You cannot
//         derive a mask at a high threshold directly: unconstrained p(>=58)
//         is of order 2e-8, so a round would need ~1e11 samples to see
//         anything. Instead: learn a few bits at a low --t-start, force them
//         (which raises the rate at the next threshold enough to learn
//         there too), escalate, repeat up to --deep-t. Each rung pays for
//         the next - this automates the hunt -> find-the-family -> derive-a-
//         mask -> hunt-again loop as one pass.
//
// DUD TEST = inverted-bit CONTROL arm (see measure() below). Comparing a
//         masked rate against an unmasked baseline conflates "the mask
//         helps" with "the spot is good." Three independent arms run at
//         --deep-t: baseline (no mask), treatment (mask,val), and control
//         (mask, ~val & mask - same bits, opposite values). A real
//         constraint beats its own inverted control by a wide margin;
//         measured at center (125,534), 3M seeds/arm, count>=63: 14-bit
//         baseline 21 hits, 18-bit correct 163, 18-bit inverted 2 - the
//         control separates signal from noise by ~80x where baseline alone
//         cannot.
//
// REACH = masks are derived at --deep-t, NOT from known high-scoring seeds
//         directly. A mask fit to already-found top seeds clamps the search
//         into that one family (fast, but it can only re-find close variants
//         of what's already known). Deriving at --deep-t instead keeps the
//         constraint a superset, so a better result in a DIFFERENT family
//         stays reachable. --max-bits caps how tight the mask gets; the
//         residual layout count 2^(48-bits) is reported so reach is visible.
//
// GEOMETRY (measured, and it shrinks the scan a lot):
//   Z is periodic with EXACT period 97 chunks. Variance autocorrelation along
//   Z peaks at 97/194/291/388. Peaks sit in 3-chunk-wide bands on lattice
//   points ...49,146,243,340,437,534,631,728,825,922,1019,1116... Use
//   --z-period 97 --z-band 1 (or --z-all, which derives every hot line in
//   range from this closed form directly) to scan only the lattice: ~30x
//   fewer locations, no loss.
//   X is QUASI-periodic, ~32.7 chunks (autocorr 0.968 at lag 33). Not an
//   integer, so it drifts instead of tiling -- do not decimate X, but know
//   that short-lag X neighbours are near-duplicates.
// ===========================================================================
// CURRENT WORKFLOW (see README.txt "RECORD COMMANDS, IN ORDER" for the full
// loop including slime_gpu/slime_refine - this is just this tool's part)
// ---------------------------------------------------------------------------
//   --scan   hotspot_scan.exe --scan --center-x 0 --center-z 0 --range 10000
//                --z-all --var-min 26 --gate-top 300 --score-t 68
//                --emit-top 15 --name hunt
//            One fused pass, no separate stages/intermediate CSVs: a cheap
//            variance gate (weak ranker, only job is to not LOSE good spots)
//            narrows the range down to --gate-top survivors, then each of
//            those gets the real work - escalating bootstrap derivation, the
//            3-arm control test, held-out measurement - and only spots that
//            clear it are emitted. Writes main/commands/commands_<name>.csv,
//            one slime_gpu.exe hunt command per line, best first.
//            --rank-by like ranks by resemblance to known-good spots instead
//            (see the --rank-by like section below); --derive-eff adds a
//            second, packing-efficiency-aware pass on top of the ladder (see
//            deriveEffBits() below).
//            --rank-by win ranks by winRate = p(count>=scoreT) x pWin, the
//            record-beaters produced PER SEED SAMPLED. That is the right key
//            when the goal is beating a record in bounded hunt time: it is
//            family-size independent, so unlike the default `winners` ordering
//            it cannot be gamed by a loose mask simply covering more layouts.
//            cq <= chunk count ALWAYS (cq = blocks/256, <=256 blocks/chunk), so
//            a spot whose counts top out below the record cannot beat it at any
//            packing - and among spots that clear it, packing decides: measured
//            here, 70 chunks @ 94.3% (66.04 cq) beats 69 @ 94.9% and 68 @ 95.9%,
//            while a 74-chunk seed lost outright. Both terms, not either alone.
//
//   --check  hotspot_scan.exe --check --center-x 2000 --center-z 8544
//            Full pipeline on a single spot, skip the range scan. Always
//            worth running on a known-good spot first: if it doesn't rank
//            there the way you expect, distrust the tool before the spot.
//
// Build : nvcc -O3 -arch=native hotspot_scan.cu -o hotspot_scan.exe
// Needs : slime_core.h beside it (the same file the hunt/refiner validate on).
// Verify: hotspot_scan.exe --self-test     (GPU vs CPU, must print PASSED)
// ===========================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <vector>
#include <algorithm>
#include <string>
#include <chrono>
#include <cuda_runtime.h>
#include "slime_core.h"
#ifdef _WIN32
#include <direct.h>
#define HS_MKDIR(d) _mkdir(d)
#else
#include <sys/stat.h>
#define HS_MKDIR(d) mkdir(d, 0755)
#endif

// CUDA_CHECK is defined in slime_core.h (shared with slime_gpu.cu).

// Low bits eligible to be forced. 24 covers everything we have ever seen bias
// in (your working mask is 14 bits inside this window; the measured extension
// reached bit 21). Kept at 32 so bitOnes[] stays one warp wide in shared mem.
#define MAX_BIT_WINDOW 32

__constant__ int cMaskDX[226];
__constant__ int cMaskDZ[226];
__constant__ int cMaskN;
// Per-cell eligible-block weight (slime_core.h buildBlockWeights), same order
// and same N as cMaskDX/cMaskDZ. Lets cqRateKernel accumulate exact blocks
// (cq = blocks/256) alongside the chunk-count tail test, instead of a
// separate CPU-only pass.
__constant__ int cCellW[226];

// ---------------------------------------------------------------------------
// device core -- bit-identical to slime_core.h's isSlimeChunk, factored so the
// per-cell position offset can be hoisted out of the seed loop.
// ---------------------------------------------------------------------------
__host__ __device__ __forceinline__ uint64_t posOffset(long long cx, long long cz) {
    uint64_t p = 0;
    p += (uint64_t)(int64_t)(int32_t)((int64_t)cx * (int64_t)cx * 0x4c1906LL);
    p += (uint64_t)(int64_t)(int32_t)((int64_t)cx * 0x5ac0dbLL);
    p += (uint64_t)((int64_t)((int32_t)((int64_t)cz * (int64_t)cz)) * 0x4307a7LL);
    p += (uint64_t)(int64_t)(int32_t)((int64_t)cz * 0x5f24fLL);
    return p;
}
// Peeled fast path. Two changes, both provably output-identical to
// slime_core.h's isSlimeChunk (verified over 3M random (seed,chunk) pairs):
//
//  1. The rejection loop retries with probability ~10/2^31 = 4.7e-9, but the
//     compiler cannot prove that, so a loop body sits between every cell and
//     blocks unrolling ACROSS cells. That serialises 226 independent LCG
//     chains into one dependency chain -- which is the "fixed latency
//     execution dependency" stall (31.94% of warp cycles). Peeling the first
//     iteration gives straight-line code the compiler can interleave; the
//     rare retry stays behind a cold branch.
//  2. st is masked to 48 bits, so st>>17 is 31 bits, so bits is ALWAYS in
//     [0, 2^31-1]. Signed and unsigned modulo are therefore identical here,
//     but the unsigned form skips the sign-correction sequence. The rejection
//     comparison stays in int32 exactly as the reference has it, because that
//     expression relies on int32 overflow behaviour.
//
// NOTE: this was measured at 1.00x on CPU -- an out-of-order core already
// hides the dependency. The win, if any, is GPU-only. Re-profile to confirm.
__host__ __device__ __forceinline__ bool slimeFromOffset(long long worldSeed, uint64_t P) {
    const uint64_t M = 0x5DEECE66DULL, A = 0xBULL, MK = (1ULL << 48) - 1;
    uint64_t st = ((((uint64_t)worldSeed + P) ^ 0x3ad8025fULL) ^ M) & MK;
    st = (st * M + A) & MK;
    uint32_t ub = (uint32_t)(st >> 17);
    uint32_t uv = ub % 10u;
    int32_t bits = (int32_t)ub, val = (int32_t)uv;
    if (bits - val + 9 >= 0) return val == 0;          // taken ~always
    for (;;) {                                          // ~4.7e-9 of the time
        st = (st * M + A) & MK;
        bits = (int32_t)(st >> 17);
        val = bits % 10;
        if (bits - val + 9 >= 0) return val == 0;
    }
}
__host__ __device__ __forceinline__ uint64_t splitmix64(uint64_t x) {
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}

// full count over all mask cells (variance needs the exact value)
__host__ __device__ __forceinline__ int countAll(const uint64_t* P, int n, long long w) {
    int c = 0;
    // unroll 2, not more: a wider unroll holds more slimeFromOffset calls
    // in-flight and pushes register use up (measured: unroll 4 -> 31 regs,
    // 47% occupancy). unroll 2 keeps most of the throughput at 62%+ occupancy.
    #pragma unroll 2
    for (int i = 0; i < n; i++) c += (int)slimeFromOffset(w, P[i]);
    return c;
}

// Tail-only count with early exit: bail as soon as the best possible final
// count (c + cells remaining) can no longer reach T. Returns -1 if it bailed.
// The mean is 22.6 and T is 50-60, so the overwhelming majority of seeds bail
// after ~40-60 cells instead of all 226. Measured ~3-10x saving depending on
// T, and it is exactly equivalent for the >=T predicate (the bailed seeds are
// provably below T and are never counted).
__host__ __device__ __forceinline__ int countTail(const uint64_t* P, int n, long long w, int T) {
    int c = 0;
    for (int i = 0; i < n; i++) {
        c += (int)slimeFromOffset(w, P[i]);
        if (c + (n - 1 - i) < T) return -1;
    }
    return c;
}

// Same early-exit tail count as countTail, but also accumulates the exact
// eligible-block weight (cellWeight[i], from slime_core.h buildBlockWeights)
// of every hit cell. Early exit is still driven by the chunk-count bound only
// -- a seed that cannot reach T chunks is discarded regardless of its blocks,
// so blocksOut is only meaningful when the return value is >= T.
__host__ __device__ __forceinline__ int countAndBlocksTail(const uint64_t* P, const int* cellW,
                                                            int n, long long w, int T, int& blocksOut) {
    int c = 0, blocks = 0;
    for (int i = 0; i < n; i++) {
        if (slimeFromOffset(w, P[i])) { c++; blocks += cellW[i]; }
        if (c + (n - 1 - i) < T) return -1;
    }
    blocksOut = blocks;
    return c;
}

// ---------------------------------------------------------------------------
// FAMILY SWEEP kernel: one block per FAMILY, all at one fixed location.
//
// Every scan so far varied the SPOT and hunted whichever single family the bit
// ladder derived there - so family quality was never isolated from spot
// quality, and the question "is the derived family actually the best of the
// 2^bits available here, and is a good family even RECOGNISABLE?" was never
// asked. This kernel asks it directly: fix the centre, fix the mask, sweep many
// vals, and measure each resulting residue class the same way.
//
// One block per family means F families cost ONE launch, not F launches. Each
// block samples N seeds of its own family and reduces to (hits >= floorCount,
// sum of per-seed packing, max blocks seen) - max blocks being the statistic
// that matters, since a record is a tail event and means cannot see tails.
// ---------------------------------------------------------------------------
__global__ void __launch_bounds__(256, 6)
familySweepKernel(long long cx, long long cz, uint64_t seedBase, long long N, int floorCount,
                  uint64_t mask, const uint64_t* __restrict__ vals,
                  unsigned long long* __restrict__ outHits,
                  double* __restrict__ outEffSum,
                  int* __restrict__ outMaxBlocks) {
    __shared__ uint64_t P[226];
    __shared__ int W[226];
    __shared__ unsigned long long sHits;
    __shared__ double sEff;
    __shared__ int sMax;
    for (int i = threadIdx.x; i < cMaskN; i += blockDim.x) {
        P[i] = posOffset(cx + cMaskDX[i], cz + cMaskDZ[i]);
        W[i] = cCellW[i];
    }
    if (threadIdx.x == 0) { sHits = 0; sEff = 0.0; sMax = 0; }
    __syncthreads();

    const uint64_t val = vals[blockIdx.x] & mask;
    unsigned long long lh = 0; double lsum = 0.0; int lmax = 0;
    // Distinct stream per family: without mixing blockIdx into the seed base
    // every family would sample the SAME pre-mask draws, turning genuine
    // family-to-family spread into an artifact of a shared stream.
    uint64_t base = seedBase + ((uint64_t)blockIdx.x * 0x9E3779B97F4A7C15ULL);
    for (long long j = threadIdx.x; j < N; j += blockDim.x) {
        uint64_t w64 = splitmix64(base + (uint64_t)j);
        w64 = (w64 & ~mask) | val;
        int blocks = 0;
        int c = countAndBlocksTail(P, W, cMaskN, (long long)w64, floorCount, blocks);
        if (c >= floorCount) {
            lh++;
            lsum += (blocks / 256.0) / (double)c;
            if (blocks > lmax) lmax = blocks;
        }
    }
    #pragma unroll
    for (int off = 16; off > 0; off >>= 1) {
        lh   += __shfl_down_sync(0xFFFFFFFFu, lh,   off);
        lsum += __shfl_down_sync(0xFFFFFFFFu, lsum, off);
        int o = __shfl_down_sync(0xFFFFFFFFu, lmax, off);
        if (o > lmax) lmax = o;
    }
    if ((threadIdx.x & 31) == 0) {
        if (lh) atomicAdd(&sHits, lh);
        if (lsum != 0.0) atomicAdd(&sEff, lsum);
        atomicMax(&sMax, lmax);
    }
    __syncthreads();
    if (threadIdx.x == 0) {
        outHits[blockIdx.x]      = sHits;
        outEffSum[blockIdx.x]    = sEff;
        outMaxBlocks[blockIdx.x] = sMax;
    }
}

// ---------------------------------------------------------------------------
// STAGE 1 kernel: one block per location, sample N seeds, exact variance.
// No early exit here -- variance needs full counts.
// ---------------------------------------------------------------------------
__global__ void __launch_bounds__(256, 6)
varKernel(const int* __restrict__ locCX, const int* __restrict__ locCZ, int numLoc,
          uint64_t seedBase, int N,
          double* __restrict__ outVar, unsigned int* __restrict__ outMax,
          double* __restrict__ outMean) {
    int loc = blockIdx.x;
    if (loc >= numLoc) return;
    long long cx = locCX[loc], cz = locCZ[loc];

    __shared__ uint64_t P[226];
    for (int i = threadIdx.x; i < cMaskN; i += blockDim.x)
        P[i] = posOffset(cx + cMaskDX[i], cz + cMaskDZ[i]);
    __syncthreads();

    unsigned long long lsum = 0, lsq = 0; unsigned int lmax = 0;
    for (int j = threadIdx.x; j < N; j += blockDim.x) {
        long long w = (long long)splitmix64(seedBase + (uint64_t)j);
        int c = countAll(P, cMaskN, w);
        lsum += (unsigned)c;
        lsq  += (unsigned long long)c * (unsigned)c;
        if ((unsigned)c > lmax) lmax = (unsigned)c;
    }

    // Warp-reduce FIRST (no shared memory), then 8-way shared, then final warp:
    // needs only 3 arrays of 8 elements (160 bytes shared, unlimited by shmem)
    // instead of 3 arrays of 256 (5120 bytes, which would cap occupancy at
    // 16 blocks/SM).
    #pragma unroll
    for (int off = 16; off > 0; off >>= 1) {
        lsum += __shfl_down_sync(0xFFFFFFFFu, lsum, off);
        lsq  += __shfl_down_sync(0xFFFFFFFFu, lsq,  off);
        unsigned int om = __shfl_down_sync(0xFFFFFFFFu, lmax, off);
        if (om > lmax) lmax = om;
    }
    __shared__ unsigned long long wsum[8], wsq[8];
    __shared__ unsigned int wmax[8];
    int wid = threadIdx.x >> 5, lane = threadIdx.x & 31;
    if (lane == 0) { wsum[wid] = lsum; wsq[wid] = lsq; wmax[wid] = lmax; }
    __syncthreads();
    if (wid == 0) {
        unsigned long long vs = (lane < 8) ? wsum[lane] : 0ULL;
        unsigned long long vq = (lane < 8) ? wsq[lane]  : 0ULL;
        unsigned int       vm = (lane < 8) ? wmax[lane] : 0u;
        #pragma unroll
        for (int off = 4; off > 0; off >>= 1) {
            vs += __shfl_down_sync(0xFFFFFFFFu, vs, off);
            vq += __shfl_down_sync(0xFFFFFFFFu, vq, off);
            unsigned int om = __shfl_down_sync(0xFFFFFFFFu, vm, off);
            if (om > vm) vm = om;
        }
        if (lane == 0) {
            double mean = (double)vs / N;
            outVar[loc]  = (double)vq / N - mean * mean;
            outMax[loc]  = vm;
            outMean[loc] = mean;
        }
    }
}

// ---------------------------------------------------------------------------
// STAGE 2 kernel A: tail bit-frequency at ONE location, conditioned on the
// bits fixed so far. condMask/condVal are FORCED (w = (w & ~condMask)|condVal)
// rather than rejection-tested, so all N samples are usable no matter how many
// bits are already pinned -- rejection would collapse past ~14 bits, which is
// the whole point of bootstrapping.
// Tallies go to shared memory first (tail hits are rare, so shared atomics are
// nearly uncontended) and hit global once per block.
// ---------------------------------------------------------------------------
__global__ void __launch_bounds__(256, 6)
tailBitsKernel(long long cx, long long cz, uint64_t seedBase, long long N, int T,
               int bitWindow, uint64_t condMask, uint64_t condVal,
               unsigned long long* __restrict__ tailCount,
               unsigned long long* __restrict__ bitOnes) {
    __shared__ uint64_t P[226];
    for (int i = threadIdx.x; i < cMaskN; i += blockDim.x)
        P[i] = posOffset(cx + cMaskDX[i], cz + cMaskDZ[i]);

    __shared__ unsigned long long sTail;
    __shared__ unsigned long long sBits[MAX_BIT_WINDOW];
    if (threadIdx.x == 0) sTail = 0;
    for (int b = threadIdx.x; b < MAX_BIT_WINDOW; b += blockDim.x) sBits[b] = 0;
    __syncthreads();

    long long idx    = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    long long stride = (long long)blockDim.x * gridDim.x;
    // Warp-reduce the tail counter (it would otherwise take heavy atomic
    // contention from every thread). Bit tallies stay as shared atomicAdd -
    // tail hits are ~1e-4, so per-bit contention across ~50 hits/block is
    // negligible, and warp-reducing 32 separate per-thread counters would
    // spill to local memory.
    unsigned long long lTail = 0;
    for (long long j = idx; j < N; j += stride) {
        uint64_t w64 = splitmix64(seedBase + (uint64_t)j);
        w64 = (w64 & ~condMask) | condVal;
        int c = countTail(P, cMaskN, (long long)w64, T);
        if (c >= T) {
            lTail++;
            for (int b = 0; b < bitWindow; b++)
                if ((w64 >> b) & 1ULL) atomicAdd(&sBits[b], 1ULL);
        }
    }
    #pragma unroll
    for (int off = 16; off > 0; off >>= 1)
        lTail += __shfl_down_sync(0xFFFFFFFFu, lTail, off);
    if ((threadIdx.x & 31) == 0 && lTail) atomicAdd(&sTail, lTail);
    __syncthreads();
    if (threadIdx.x == 0 && sTail) atomicAdd(tailCount, sTail);
    for (int b = threadIdx.x; b < bitWindow; b += blockDim.x)
        if (sBits[b]) atomicAdd(&bitOnes[b], sBits[b]);
}

// ---------------------------------------------------------------------------
// STAGE 2 kernel B: rate of count >= T with mask FORCED, plus the max count
// seen. mask=0 gives the unconstrained baseline arm. Same forcing rationale as
// above. Early exit applies -- we only ever ask the >=T question.
// ---------------------------------------------------------------------------
__global__ void __launch_bounds__(256, 6)
rateKernel(long long cx, long long cz, uint64_t seedBase, long long N, int T,
           uint64_t mask, uint64_t val,
           unsigned long long* __restrict__ hiCount, unsigned int* __restrict__ hiMax) {
    __shared__ uint64_t P[226];
    for (int i = threadIdx.x; i < cMaskN; i += blockDim.x)
        P[i] = posOffset(cx + cMaskDX[i], cz + cMaskDZ[i]);
    __syncthreads();

    unsigned long long lh = 0; unsigned int lm = 0;
    long long idx    = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    long long stride = (long long)blockDim.x * gridDim.x;
    for (long long j = idx; j < N; j += stride) {
        uint64_t w64 = splitmix64(seedBase + (uint64_t)j);
        w64 = (w64 & ~mask) | val;
        int c = countTail(P, cMaskN, (long long)w64, T);
        if (c >= T) { lh++; if ((unsigned)c > lm) lm = (unsigned)c; }
    }
    #pragma unroll
    for (int off = 16; off > 0; off >>= 1) {
        lh += __shfl_down_sync(0xFFFFFFFFu, lh, off);
        unsigned int om = __shfl_down_sync(0xFFFFFFFFu, lm, off);
        if (om > lm) lm = om;
    }
    if ((threadIdx.x & 31) == 0) {
        if (lh) atomicAdd(hiCount, lh);
        if (lm) atomicMax(hiMax, lm);
    }
}

// ---------------------------------------------------------------------------
// STAGE 2 kernel C: exact-cq measurement, GPU-scale replacement for the old
// CPU-only efficiencyProbe. Widens the net to floorCount (a few chunks below
// scoreT, same idea as the CPU probe's old floorCount) so enough layouts
// qualify to measure packing; for every qualifying seed accumulates its exact
// block count (weighted sum over cCellW, the same table slime_refine and the
// jar are validated against - NOT an approximation) and whether its packing
// fraction clears effBar = recordCq/scoreT. Same forcing/early-exit approach
// as rateKernel; the only difference is the extra weighted-sum accumulator,
// which is cheap next to the ~222 LCG evaluations that dominate every seed.
// ---------------------------------------------------------------------------
__global__ void __launch_bounds__(256, 6)
cqRateKernel(long long cx, long long cz, uint64_t seedBase, long long N, int floorCount,
             uint64_t mask, uint64_t val, double effBar, int recBlocks,
             unsigned long long* __restrict__ hiCount,
             double* __restrict__ effSum,
             unsigned long long* __restrict__ winCount,
             unsigned long long* __restrict__ recCount) {
    __shared__ uint64_t P[226];
    __shared__ int W[226];
    for (int i = threadIdx.x; i < cMaskN; i += blockDim.x) {
        P[i] = posOffset(cx + cMaskDX[i], cz + cMaskDZ[i]);
        W[i] = cCellW[i];
    }
    __syncthreads();

    unsigned long long lh = 0, lwin = 0, lrec = 0;
    double lsum = 0.0;   // mean of PER-SEED efficiency (blocks/256/chunks),
                         // matching the CPU probe's statistic exactly -- NOT
                         // (sum blocks)/(sum chunks), which would be a
                         // differently-weighted (and biased) quantity.
    long long idx    = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    long long stride = (long long)blockDim.x * gridDim.x;
    for (long long j = idx; j < N; j += stride) {
        uint64_t w64 = splitmix64(seedBase + (uint64_t)j);
        w64 = (w64 & ~mask) | val;
        int blocks = 0;
        int c = countAndBlocksTail(P, W, cMaskN, (long long)w64, floorCount, blocks);
        if (c >= floorCount) {
            lh++;
            double eff = (blocks / 256.0) / (double)c;
            lsum += eff;
            if (eff >= effBar) lwin++;
            // THE question, asked directly: does this layout's actual cq beat
            // the record? effBar above only asks whether it PACKS better than
            // recordCq/scoreT, which a layout can do while still losing badly -
            // 66 chunks at 95% packing clears effBar and scores 61.9 cq, ten
            // short of the record. Packing is a ratio; the record is a total.
            //
            // Safe to evaluate inside the c >= floorCount gate: cq = blocks/256
            // and a chunk holds at most 256 eligible blocks, so cq <= c always.
            // Beating recordCq therefore REQUIRES c > recordCq, and callers
            // keep floorCount <= ceil(recordCq), so no record-beater can be
            // hiding below the gate.
            if (blocks >= recBlocks) lrec++;
        }
    }
    #pragma unroll
    for (int off = 16; off > 0; off >>= 1) {
        lh   += __shfl_down_sync(0xFFFFFFFFu, lh,   off);
        lwin += __shfl_down_sync(0xFFFFFFFFu, lwin, off);
        lrec += __shfl_down_sync(0xFFFFFFFFu, lrec, off);
        lsum += __shfl_down_sync(0xFFFFFFFFu, lsum, off);
    }
    if ((threadIdx.x & 31) == 0) {
        if (lh)     atomicAdd(hiCount, lh);
        if (lwin)   atomicAdd(winCount, lwin);
        if (lrec)   atomicAdd(recCount, lrec);
        if (lsum != 0.0) atomicAdd(effSum, lsum);
    }
}

// ---------------------------------------------------------------------------
// STAGE 2 kernel D: --derive-eff. The count ladder (tailBitsKernel/derive())
// picks bits by correlating them with chunk-COUNT. Count and cq correlate in
// general, but the residual signal that actually separates a record from a
// dud - does a bit predict better PACKING among seeds that already clear the
// count floor, not just more chunks - is invisible to that test. This kernel
// answers that question directly: for the tail population at --deep-t (same
// population measure() already samples), split by each free bit's value and
// accumulate per-seed efficiency (blocks/256/chunks) into two groups, so the
// host side can run a per-bit Welch's t-test (unequal group sizes/variances
// expected) on mean efficiency. Same forced-mask tail-sampling pattern as
// tailBitsKernel; only fires the extra per-bit work on tail HITS (rare), so
// the added atomic traffic is the same class as tailBitsKernel's bitOnes[].
// ---------------------------------------------------------------------------
__global__ void __launch_bounds__(256, 4)
effBitsKernel(long long cx, long long cz, uint64_t seedBase, long long N, int T,
              int bitWindow, uint64_t condMask, uint64_t condVal,
              unsigned long long* __restrict__ tailCount,
              unsigned long long* __restrict__ n0, unsigned long long* __restrict__ n1,
              double* __restrict__ sum0, double* __restrict__ sum1,
              double* __restrict__ sumSq0, double* __restrict__ sumSq1) {
    __shared__ uint64_t P[226];
    __shared__ int W[226];
    for (int i = threadIdx.x; i < cMaskN; i += blockDim.x) {
        P[i] = posOffset(cx + cMaskDX[i], cz + cMaskDZ[i]);
        W[i] = cCellW[i];
    }
    __shared__ unsigned long long sTail;
    __shared__ unsigned long long sN0[MAX_BIT_WINDOW], sN1[MAX_BIT_WINDOW];
    __shared__ double sSum0[MAX_BIT_WINDOW], sSum1[MAX_BIT_WINDOW];
    __shared__ double sSumSq0[MAX_BIT_WINDOW], sSumSq1[MAX_BIT_WINDOW];
    if (threadIdx.x == 0) sTail = 0;
    for (int b = threadIdx.x; b < MAX_BIT_WINDOW; b += blockDim.x) {
        sN0[b] = 0; sN1[b] = 0; sSum0[b] = 0; sSum1[b] = 0; sSumSq0[b] = 0; sSumSq1[b] = 0;
    }
    __syncthreads();

    long long idx    = blockIdx.x * (long long)blockDim.x + threadIdx.x;
    long long stride = (long long)blockDim.x * gridDim.x;
    unsigned long long lTail = 0;
    for (long long j = idx; j < N; j += stride) {
        uint64_t w64 = splitmix64(seedBase + (uint64_t)j);
        w64 = (w64 & ~condMask) | condVal;
        int blocks = 0;
        int c = countAndBlocksTail(P, W, cMaskN, (long long)w64, T, blocks);
        if (c >= T) {
            lTail++;
            double eff = (blocks / 256.0) / (double)c;
            for (int b = 0; b < bitWindow; b++) {
                if ((w64 >> b) & 1ULL) {
                    atomicAdd(&sN1[b], 1ULL);
                    atomicAdd(&sSum1[b], eff);
                    atomicAdd(&sSumSq1[b], eff * eff);
                } else {
                    atomicAdd(&sN0[b], 1ULL);
                    atomicAdd(&sSum0[b], eff);
                    atomicAdd(&sSumSq0[b], eff * eff);
                }
            }
        }
    }
    #pragma unroll
    for (int off = 16; off > 0; off >>= 1)
        lTail += __shfl_down_sync(0xFFFFFFFFu, lTail, off);
    if ((threadIdx.x & 31) == 0 && lTail) atomicAdd(&sTail, lTail);
    __syncthreads();
    if (threadIdx.x == 0 && sTail) atomicAdd(tailCount, sTail);
    for (int b = threadIdx.x; b < bitWindow; b += blockDim.x) {
        if (sN0[b]) { atomicAdd(&n0[b], sN0[b]); atomicAdd(&sum0[b], sSum0[b]); atomicAdd(&sumSq0[b], sSumSq0[b]); }
        if (sN1[b]) { atomicAdd(&n1[b], sN1[b]); atomicAdd(&sum1[b], sSum1[b]); atomicAdd(&sumSq1[b], sSumSq1[b]); }
    }
}

// ---------------------------------------------------------------------------
// host side
// ---------------------------------------------------------------------------
static std::vector<int> g_dx, g_dz;

static void buildMaskOffsets() {
    // The SPAWN mask (222 cells), not the disc mask (226): slimes cannot spawn
    // within 24 blocks of a player, and four chunks touching the AFK spot lie
    // entirely inside that exclusion sphere: (0,0) (-1,0) (0,-1) (-1,-1).
    // Counting them overstates the score 33.2% of the time (+1: 27.1%, +2:
    // 5.5%, +3: 0.6%) at chunk(125,534) over 2M seeds. This kernel walks a
    // cell LIST, so unlike slime_gpu's row-interval kernel it can just use
    // the real (non-contiguous) mask directly - the holes cost nothing here.
    // Counts agree with slime_gpu and slime_refine, so --deep-t and any
    // count threshold mean the same number in all three tools.
    uint8_t mask[17 * 17];
    int cells = buildSpawnMask(mask);
    if (cells != 222) { fprintf(stderr, "spawn mask cell count %d != 222, aborting\n", cells); exit(1); }
    int weights[17 * 17];
    buildBlockWeights(weights);
    // Idempotent: g_dx/g_dz are file-scope and this can be reached twice (a mode
    // that builds its own offsets, then the shared path). Appending a second
    // time pushes n to 444 and overflows the 226-entry __constant__ arrays,
    // which surfaces only as "invalid argument" from cudaMemcpyToSymbol.
    g_dx.clear(); g_dz.clear();
    std::vector<int> g_w;
    for (int dz = -8; dz <= 8; dz++)
        for (int dx = -8; dx <= 8; dx++)
            if (mask[(dz + 8) * 17 + (dx + 8)]) {
                g_dx.push_back(dx); g_dz.push_back(dz);
                g_w.push_back(weights[(dz + 8) * 17 + (dx + 8)]);
            }
    int n = (int)g_dx.size();
    CUDA_CHECK(cudaMemcpyToSymbol(cMaskDX, g_dx.data(), n * sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(cMaskDZ, g_dz.data(), n * sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(cMaskN, &n, sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(cCellW, g_w.data(), n * sizeof(int)));
}

struct Result { double var; double mean; int cx, cz; unsigned mx; };

static void runVarScan(const std::vector<int>& lx, const std::vector<int>& lz,
                       uint64_t seedBase, int N, std::vector<Result>& out) {
    int numLoc = (int)lx.size();
    int *dLX, *dLZ; double *dVar, *dMean; unsigned int *dMax;
    CUDA_CHECK(cudaMalloc(&dLX,  numLoc * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&dLZ,  numLoc * sizeof(int)));
    CUDA_CHECK(cudaMalloc(&dVar, numLoc * sizeof(double)));
    CUDA_CHECK(cudaMalloc(&dMean,numLoc * sizeof(double)));
    CUDA_CHECK(cudaMalloc(&dMax, numLoc * sizeof(unsigned int)));
    CUDA_CHECK(cudaMemcpy(dLX, lx.data(), numLoc * sizeof(int), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(dLZ, lz.data(), numLoc * sizeof(int), cudaMemcpyHostToDevice));
    varKernel<<<numLoc, 256>>>(dLX, dLZ, numLoc, seedBase, N, dVar, dMax, dMean);
    CUDA_CHECK(cudaGetLastError());
    std::vector<double> hVar(numLoc), hMean(numLoc);
    std::vector<unsigned int> hMax(numLoc);
    CUDA_CHECK(cudaMemcpy(hVar.data(),  dVar,  numLoc * sizeof(double), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(hMean.data(), dMean, numLoc * sizeof(double), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(hMax.data(),  dMax,  numLoc * sizeof(unsigned int), cudaMemcpyDeviceToHost));
    out.resize(numLoc);
    for (int i = 0; i < numLoc; i++) out[i] = Result{ hVar[i], hMean[i], lx[i], lz[i], hMax[i] };
    cudaFree(dLX); cudaFree(dLZ); cudaFree(dVar); cudaFree(dMean); cudaFree(dMax);
}

// CPU reference for --self-test
static void cpuVar(long long cx, long long cz, uint64_t seedBase, int N,
                   double& var, double& mean, unsigned& mx) {
    std::vector<uint64_t> P(g_dx.size());
    for (size_t i = 0; i < g_dx.size(); i++) P[i] = posOffset(cx + g_dx[i], cz + g_dz[i]);
    unsigned long long sum = 0, sumsq = 0; mx = 0;
    for (int j = 0; j < N; j++) {
        long long w = (long long)splitmix64(seedBase + (uint64_t)j);
        int c = 0;
        for (size_t i = 0; i < P.size(); i++) c += (int)slimeFromOffset(w, P[i]);
        sum += c; sumsq += (unsigned long long)c * c;
        if ((unsigned)c > mx) mx = (unsigned)c;
    }
    mean = (double)sum / N;
    var  = (double)sumsq / N - mean * mean;
}
static unsigned long long cpuRate(long long cx, long long cz, uint64_t seedBase, long long N,
                                  int T, uint64_t mask, uint64_t val) {
    std::vector<uint64_t> P(g_dx.size());
    for (size_t i = 0; i < g_dx.size(); i++) P[i] = posOffset(cx + g_dx[i], cz + g_dz[i]);
    unsigned long long hits = 0;
    for (long long j = 0; j < N; j++) {
        uint64_t w = splitmix64(seedBase + (uint64_t)j);
        w = (w & ~mask) | (val & mask);
        int c = 0;
        for (size_t i = 0; i < P.size(); i++) c += (int)slimeFromOffset((long long)w, P[i]);
        if (c >= T) hits++;
    }
    return hits;
}

// ---------------------------------------------------------------------------
// STAGE 2: escalating-threshold bootstrap derivation
// ---------------------------------------------------------------------------
struct Round { int T; int bit; double freq; double z; unsigned long long tail; bool to1; };

struct Derivation {
    uint64_t mask = 0, val = 0;
    int bitsFixed = 0;
    int topT = 0;                 // highest rung actually learned from
    int released = 0;             // bits the reach guard took back
    std::vector<Round> rounds;
    const char* stopReason = "";
};

// Two-sided z for k ones out of n fair coin flips.
static inline double bitZ(unsigned long long k, unsigned long long n) {
    if (!n) return 0.0;
    double dn = (double)n;
    return ((double)(2.0 * (double)k - dn)) / sqrt(dn);
}

static Derivation derive(int ccx, int ccz, uint64_t seedBase,
                         long long bigN, long long bigNMin,
                         int tStart, int tStep, int deepT, int tFloor,
                         int bitWindow, int maxBits,
                         double zMin, double minDev, unsigned long long minTail,
                         bool verbose) {
    Derivation D;
    if (bitWindow > MAX_BIT_WINDOW) bitWindow = MAX_BIT_WINDOW;

    unsigned long long *dTail, *dBits;
    CUDA_CHECK(cudaMalloc(&dTail, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&dBits, MAX_BIT_WINDOW * sizeof(unsigned long long)));

    bool stop = false;
    int T = tStart;
    int roundId = 0;
    while (!stop) {
        // Learn everything this rung has to offer, then escalate.
        for (;;) {
            if (D.bitsFixed >= maxBits) { D.stopReason = "hit --max-bits (reach cap)"; stop = true; break; }

            // ADAPTIVE SAMPLE SIZE. --big-n is a CEILING, not a quota. Once a few
            // bits are pinned the tail gets dense fast (measured at your spot:
            // 614 tail hits on the first round at T>=45, 216008 by the last),
            // so a fixed --big-n wastes ~25x on nearly every round after the
            // first. Start at --big-n-min, quadruple only while the tail is
            // too thin to learn from.
            unsigned long long tail = 0;
            std::vector<unsigned long long> ones(MAX_BIT_WINDOW);
            long long useN = bigNMin;
            for (;;) {
                CUDA_CHECK(cudaMemset(dTail, 0, sizeof(unsigned long long)));
                CUDA_CHECK(cudaMemset(dBits, 0, MAX_BIT_WINDOW * sizeof(unsigned long long)));
                uint64_t salt = seedBase + (uint64_t)(++roundId) * 0x2545F4914F6CDD1DULL
                                         + (uint64_t)T * 0x9E3779B97F4A7C15ULL;
                int blk = (int)std::min<long long>(8192, (useN + 255) / 256);
                if (blk < 1) blk = 1;
                tailBitsKernel<<<blk, 256>>>((long long)ccx, (long long)ccz, salt, useN, T,
                                             bitWindow, D.mask, D.val, dTail, dBits);
                CUDA_CHECK(cudaGetLastError());
                CUDA_CHECK(cudaMemcpy(&tail, dTail, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
                CUDA_CHECK(cudaMemcpy(ones.data(), dBits, MAX_BIT_WINDOW * sizeof(unsigned long long),
                                      cudaMemcpyDeviceToHost));
                if (tail >= minTail) break;
                // Prefer DESCENDING a rung over escalating N. One rung down is
                // -5 counts, which raises the tail rate roughly 10x; 4x the
                // samples costs 4x for 4x. Descending is the better trade by
                // ~2.5x, and the old order burned 8M->32M->128M->200M at a
                // threshold this spot was never going to reach before it tried
                // the cheaper fix. This is most of why duds cost 3.2s.
                if (D.bitsFixed == 0 && T - tStep >= tFloor) {
                    T -= tStep; useN = bigNMin;
                    if (verbose) printf("    (tail %llu thin at T>=%d, dropping a rung to T>=%d)\n",
                                        tail, T + tStep, T);
                    continue;
                }
                if (useN >= bigN) break;
                useN = std::min(useN * 4, bigN);
            }

            if (tail < minTail) {
                // Nothing learned yet? Then --t-start is simply too high for
                // this location's tail. Step DOWN a rung and retry rather than
                // calling it a dud -- a sparse spot can still carry a real
                // constraint, and the bits it yields are the same ones (the
                // measured bit structure is stable across thresholds even
                // though the between-location RANKING is not). Once we do have
                // bits, a thin tail means we are genuinely out of signal.
                if (D.bitsFixed == 0 && T - tStep >= tFloor) {
                    T -= tStep;
                    if (verbose)
                        printf("    (tail %llu < %llu at T>=%d, descending to T>=%d)\n",
                               tail, minTail, T + tStep, T);
                    continue;
                }
                // FAST BAIL: if we are already at tFloor, have 0 bits, and the
                // tail is literally 0 after bigNMin seeds, this location is
                // structurally dead. Don't escalate N â€” every 4x costs seconds
                // and will still find nothing. This cuts dud cost from ~4s to
                // ~0.2s (the single kernel launch).
                if (D.bitsFixed == 0 && T <= tFloor && tail == 0 && useN >= bigNMin) {
                    D.stopReason = "zero tail at floor threshold (structural dud)";
                    stop = true; break;
                }
                D.stopReason = "tail too thin to learn (raise --big-n or lower --t-start)";
                stop = true; break;
            }

            // Pick the most-biased FREE bit that clears BOTH a significance
            // bar and an effect-size bar. Significance alone is not enough:
            // at bigN in the hundreds of millions a 0.5001 bias is "real" and
            // worthless. Effect size alone is v3's bug. Require both.
            // zMin is Bonferroni-ish for bitWindow x rounds tests; 5.0 is
            // ~2e-6 two-sided after correction.
            int bestBit = -1; double bestZ = 0, bestFreq = 0.5;
            for (int b = 0; b < bitWindow; b++) {
                if ((D.mask >> b) & 1ULL) continue;
                double freq = (double)ones[b] / (double)tail;
                if (fabs(freq - 0.5) < minDev) continue;
                double z = fabs(bitZ(ones[b], tail));
                if (z > bestZ) { bestZ = z; bestBit = b; bestFreq = freq; }
            }
            if (bestBit < 0 || bestZ < zMin) break;   // nothing left at this rung -> escalate

            bool to1 = bestFreq > 0.5;
            D.mask |= (1ULL << bestBit);
            if (to1) D.val |= (1ULL << bestBit);
            D.bitsFixed++;
            D.topT = T;
            D.rounds.push_back(Round{ T, bestBit, bestFreq, bestZ, tail, to1 });
            if (verbose)
                printf("    T>=%2d  bit %-2d  freq %.4f  z %6.1f  tail %8llu  -> force %d\n",
                       T, bestBit, bestFreq, bestZ, tail, to1 ? 1 : 0);
        }
        if (stop) break;
        if (T >= deepT) { if (!*D.stopReason) D.stopReason = "no further significant bits at --deep-t"; break; }
        T = std::min(T + tStep, deepT);
        if (verbose) printf("    -- escalating to T>=%d --\n", T);
    }
    cudaFree(dTail); cudaFree(dBits);
    return D;
}


// ---------------------------------------------------------------------------
// REACH GUARD
//
// The ladder has to fix bits at T=45 to make T=60 reachable at all -- that is
// the whole bootstrap. But a frequency measured at T=45 is not a claim about
// T=70, and some bits lie:
//
//   bit    T>=45   T>=54   T>=60   T>=66     what it really is
//    4     0.694   0.759   0.825   0.974     converging -> locked, force it
//   20     0.438   0.351   0.211   0.022     converging -> locked, force it
//    5     0.345   0.369   0.430   0.298     drifts BACK to 0.5 -> DO NOT FORCE
//   22     0.480   0.484   0.466   0.417     flat ~0.47 -> real family split
//   23     0.507   0.517   0.511   0.506     flat ~0.51 -> a coin flip
//
// bit 5 clears --min-dev 0.08 at T=45 (|0.345-0.5| = 0.155) and gets forced to
// 0, but by T>=60 it is 0.430. Forcing it throws away ~55% of the deep
// population and buys nothing. It ranked 21st, so --max-bits 20 happened to cut
// it off. That is luck, not a design.
//
// So: after the ladder, release each fixed bit ONE AT A TIME, re-measure its
// frequency at --deep-t with every other bit still fixed, and keep it only if
// it is still decisive THERE. A bit that is locked at the deep end costs
// nothing to force (2x faster, ~0% of the population lost). A bit that has
// drifted back toward 0.5 is a family split, and forcing it makes higher counts
// in the other half UNREACHABLE -- not rarer, not generated at all.
//
// This is on by default because reach beats speed when you are chasing a
// record. --no-reach-check to disable.
// ---------------------------------------------------------------------------
static void reachGuard(int ccx, int ccz, uint64_t seedBase, Derivation& D,
                       long long reachN, int deepT, int bitWindow,
                       double reachDev, unsigned long long minTail, bool verbose) {
    if (!D.bitsFixed) return;
    unsigned long long *dTail, *dBits;
    CUDA_CHECK(cudaMalloc(&dTail, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&dBits, MAX_BIT_WINDOW * sizeof(unsigned long long)));

    uint64_t keepMask = D.mask, keepVal = D.val;
    int released = 0, probe = 0;
    if (verbose) printf("\n  reach guard: re-testing each bit at T>=%d [keep if |freq-0.5| >= %.2f]\n",
                        deepT, reachDev);

    for (int b = 0; b < bitWindow; b++) {
        if (!((D.mask >> b) & 1ULL)) continue;
        uint64_t tm = D.mask & ~(1ULL << b);      // release ONLY this bit
        uint64_t tv = D.val & tm;
        // FIXED budget, no escalation. The guard only ever runs on a spot that
        // already passed the 3-arm test, so p(>=deep-t | mask) is 1e-4..1e-3 and
        // --reach-n gives thousands of tail hits on the first try. Letting this
        // escalate to --big-n was costing 3-10s per location on spots that were
        // being dropped anyway.
        unsigned long long tail = 0;
        std::vector<unsigned long long> ones(MAX_BIT_WINDOW);
        CUDA_CHECK(cudaMemset(dTail, 0, sizeof(unsigned long long)));
        CUDA_CHECK(cudaMemset(dBits, 0, MAX_BIT_WINDOW * sizeof(unsigned long long)));
        uint64_t salt = seedBase ^ (0x51E7A5C0DEULL + (uint64_t)(++probe) * 0x9E3779B97F4A7C15ULL);
        int blk = (int)std::min<long long>(8192, (reachN + 255) / 256);
        if (blk < 1) blk = 1;
        tailBitsKernel<<<blk, 256>>>((long long)ccx, (long long)ccz, salt, reachN, deepT,
                                     bitWindow, tm, tv, dTail, dBits);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaMemcpy(&tail, dTail, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(ones.data(), dBits, MAX_BIT_WINDOW * sizeof(unsigned long long),
                              cudaMemcpyDeviceToHost));
        if (tail < minTail) continue;             // cannot judge it -> leave it alone
        double fr = (double)ones[b] / (double)tail;
        bool keep = fabs(fr - 0.5) >= reachDev;
        if (verbose) printf("    bit %-2d  freq@%d %.3f  tail %8llu  -> %s\n",
                            b, deepT, fr, tail, keep ? "keep" : "RELEASE (split, costs reach)");
        if (!keep) { keepMask &= ~(1ULL << b); keepVal &= ~(1ULL << b); released++; }
    }
    cudaFree(dTail); cudaFree(dBits);
    D.mask = keepMask; D.val = keepVal & keepMask;
    D.bitsFixed = 0;
    for (uint64_t t = D.mask; t; t &= t - 1) D.bitsFixed++;
    D.released = released;
    if (verbose && released)
        printf("  released %d bit(s) to preserve reach -> %d bits, layouts 2^%d\n",
               released, D.bitsFixed, 48 - D.bitsFixed);
}

// ---------------------------------------------------------------------------
// --derive-eff: additive post-pass on top of the count ladder's finished
// mask. ADDS bits, never removes any the ladder already fixed - the ladder
// is the delicate, proven part of this tool, so this only ever gets a
// chance at bits the ladder left free (within --max-bits). Samples the SAME
// tail population reachGuard/measure() already define (count >= --deep-t
// under the current mask), tests each free bit with a Welch's t-test on
// per-seed efficiency (blocks/256/chunks) split by that bit's value, and
// fixes the most significant one if it clears both a t-stat bar (--eff-z-min)
// and an effect-size bar (--min-eff-dev) - same two-bar pattern derive()
// itself uses (significance alone is not enough; effect size alone is v3's
// old bug). Repeats against the newly-widened mask until nothing left
// clears the bar or --max-bits is hit. Caller must re-run reachGuard on any
// bit this fixes - it gets no exemption from that check.
// ---------------------------------------------------------------------------
static bool deriveEffBits(int ccx, int ccz, uint64_t seedBase, Derivation& D,
                          long long bigN, long long bigNMin, int deepT,
                          int bitWindow, int maxBits, double minEffDev, double effZMin,
                          bool verbose) {
    if (bitWindow > MAX_BIT_WINDOW) bitWindow = MAX_BIT_WINDOW;
    bool fixedAny = false;
    unsigned long long *dTail, *dN0, *dN1;
    double *dSum0, *dSum1, *dSumSq0, *dSumSq1;
    CUDA_CHECK(cudaMalloc(&dTail, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&dN0, MAX_BIT_WINDOW * sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&dN1, MAX_BIT_WINDOW * sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&dSum0, MAX_BIT_WINDOW * sizeof(double)));
    CUDA_CHECK(cudaMalloc(&dSum1, MAX_BIT_WINDOW * sizeof(double)));
    CUDA_CHECK(cudaMalloc(&dSumSq0, MAX_BIT_WINDOW * sizeof(double)));
    CUDA_CHECK(cudaMalloc(&dSumSq1, MAX_BIT_WINDOW * sizeof(double)));

    int round = 0;
    while (D.bitsFixed < maxBits) {
        unsigned long long tail = 0;
        std::vector<unsigned long long> n0(MAX_BIT_WINDOW), n1(MAX_BIT_WINDOW);
        std::vector<double> sum0(MAX_BIT_WINDOW), sum1(MAX_BIT_WINDOW),
                            sumSq0(MAX_BIT_WINDOW), sumSq1(MAX_BIT_WINDOW);
        long long useN = bigNMin;
        for (;;) {
            CUDA_CHECK(cudaMemset(dTail, 0, sizeof(unsigned long long)));
            CUDA_CHECK(cudaMemset(dN0, 0, MAX_BIT_WINDOW * sizeof(unsigned long long)));
            CUDA_CHECK(cudaMemset(dN1, 0, MAX_BIT_WINDOW * sizeof(unsigned long long)));
            CUDA_CHECK(cudaMemset(dSum0, 0, MAX_BIT_WINDOW * sizeof(double)));
            CUDA_CHECK(cudaMemset(dSum1, 0, MAX_BIT_WINDOW * sizeof(double)));
            CUDA_CHECK(cudaMemset(dSumSq0, 0, MAX_BIT_WINDOW * sizeof(double)));
            CUDA_CHECK(cudaMemset(dSumSq1, 0, MAX_BIT_WINDOW * sizeof(double)));
            uint64_t salt = seedBase ^ (0xD1CE5EEDULL + (uint64_t)(++round) * 0x9E3779B97F4A7C15ULL);
            int blk = (int)std::min<long long>(8192, (useN + 255) / 256);
            if (blk < 1) blk = 1;
            effBitsKernel<<<blk, 256>>>((long long)ccx, (long long)ccz, salt, useN, deepT,
                                        bitWindow, D.mask, D.val, dTail, dN0, dN1,
                                        dSum0, dSum1, dSumSq0, dSumSq1);
            CUDA_CHECK(cudaGetLastError());
            CUDA_CHECK(cudaMemcpy(&tail, dTail, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
            if (tail >= 200 || useN >= bigN) break;
            useN = std::min(useN * 4, bigN);
        }
        if (tail < 200) {
            if (verbose) printf("    (derive-eff: tail %llu too thin to test at T>=%d, stopping)\n", tail, deepT);
            break;
        }
        CUDA_CHECK(cudaMemcpy(n0.data(), dN0, MAX_BIT_WINDOW * sizeof(unsigned long long), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(n1.data(), dN1, MAX_BIT_WINDOW * sizeof(unsigned long long), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(sum0.data(), dSum0, MAX_BIT_WINDOW * sizeof(double), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(sum1.data(), dSum1, MAX_BIT_WINDOW * sizeof(double), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(sumSq0.data(), dSumSq0, MAX_BIT_WINDOW * sizeof(double), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(sumSq1.data(), dSumSq1, MAX_BIT_WINDOW * sizeof(double), cudaMemcpyDeviceToHost));

        int bestBit = -1; double bestT = 0, bestDiff = 0;
        for (int b = 0; b < bitWindow; b++) {
            if ((D.mask >> b) & 1ULL) continue;             // already fixed by the ladder
            if (n0[b] < 30 || n1[b] < 30) continue;         // need both groups populated
            double mean0 = sum0[b] / (double)n0[b];
            double mean1 = sum1[b] / (double)n1[b];
            double var0 = sumSq0[b] / (double)n0[b] - mean0 * mean0; if (var0 < 0) var0 = 0;
            double var1 = sumSq1[b] / (double)n1[b] - mean1 * mean1; if (var1 < 0) var1 = 0;
            double se = sqrt(var0 / (double)n0[b] + var1 / (double)n1[b]);
            double diff = mean1 - mean0;
            double t = (se > 0) ? fabs(diff) / se : 0.0;
            if (fabs(diff) >= minEffDev && t >= effZMin && t > bestT) { bestT = t; bestBit = b; bestDiff = diff; }
        }
        if (bestBit < 0) {
            if (verbose) printf("    (derive-eff: no free bit clears %.3f eff-dev / z>=%.1f, tail %llu)\n",
                                minEffDev, effZMin, tail);
            break;
        }

        bool to1 = bestDiff > 0;
        D.mask |= (1ULL << bestBit);
        if (to1) D.val |= (1ULL << bestBit);
        D.bitsFixed++;
        fixedAny = true;
        if (verbose)
            printf("    derive-eff  bit %-2d  eff-diff %+.4f  t %6.1f  tail %8llu  -> force %d\n",
                   bestBit, bestDiff, bestT, tail, to1 ? 1 : 0);
    }
    cudaFree(dTail); cudaFree(dN0); cudaFree(dN1);
    cudaFree(dSum0); cudaFree(dSum1); cudaFree(dSumSq0); cudaFree(dSumSq1);
    return fixedAny;
}

// ---------------------------------------------------------------------------
// STAGE 2: three-arm held-out measurement at --deep-t
// ---------------------------------------------------------------------------
struct Measure {
    unsigned long long baseHits = 0, treatHits = 0, ctrlHits = 0;
    unsigned baseMax = 0, treatMax = 0, ctrlMax = 0;
    long long N = 0, maxN = 0;      // maxN = the FIXED sample the maxes came from
    bool ctrlZero = false;
    // THE RANKING KEY. Measured at --score-t, the count you actually want - NOT
    // at --deep-t, which is only as deep as the bootstrap can reach. They are
    // different questions and the tail curves cross between them. Variance,
    // measured near 45, could not predict 70; ranking at 60 to predict 70 is the
    // same mistake one rung up.
    unsigned long long scoreHits = 0; long long scoreN = 0;
    double scoreRate = 0; unsigned scoreMax = 0;
    // Efficiency ceiling: mean cq-per-chunk among high-count layouts at THIS spot.
    // The variable that actually decides a winner. Measured on 88M seeds it holds
    // to ~0.1%: the record spot averages 92-94%, a found spot 87-88%, and that
    // 6-point gap is why a 70-chunk find can still lose by 4 cq. cqCeil is the
    // best plausible cq (mean eff x scoreT); effMean is the packing fraction.
    double effMean = 0; double cqCeil = 0; unsigned long long effSamples = 0;
    // Chunk count the packing sample was actually taken at. Starts at scoreT-4
    // and steps down until the sample is big enough to mean anything, so this
    // says how far the probe had to reach - a floor far below scoreT means the
    // spot rarely produces high counts at all, which is itself a signal.
    int effFloor = 0;
    // pWin: of the high-count layouts this spot produces, what FRACTION pack well
    // enough to beat the record at scoreT chunks. Measured, not derived - and it
    // separates spots that a mean cannot. At the record spot 20.3% of layouts
    // clear the bar; at a spot whose mean was only 0.9 points lower, 0 of 162 did.
    // A mean hides the tail; this is the tail.
    double pWin = 0;
    // THE record metric, and the one to rank on: fraction of ALL sampled family
    // members whose exact cq beats recordCq. Unlike pWin this is not a packing
    // ratio and is not conditioned on chunk count, so it cannot be fooled by a
    // spot that packs beautifully into too few chunks. Directly actionable:
    // expected seeds to a record = 1/pRec, and expected SECONDS = 1/(pRec x
    // seeds-per-second). pRec == 0 on a large sample is the real "this family
    // cannot produce a record" verdict.
    double pRec = 0; unsigned long long recHits = 0; long long recN = 0;
    // OPTIONS: how many record-beating layouts EXIST in this family.
    //     winners = 2^(48 - bitsFixed)  x  p(count>=scoreT)  x  pWin
    // The mask carves a residue class out of the 48-bit space; that class has
    // exactly 2^(48-bits) layouts and NOTHING else. Ranking on rate alone
    // rewards tight masks, which raise the rate by SHRINKING the family - the
    // opposite of what produced the records (their original mask was 14 bits =
    // 2^34 layouts, 64x the 2^28 the scan derives now). This counts what is
    // actually reachable. Below ~1 means the family probably contains no winner
    // at all, however long it is hunted.
    double winners = 0;
    double baseRate = 0, treatRate = 0, ctrlRate = 0;
    double lift = 0, sep = 0;
    int verdict = 0;              // 2 worth, 1 inconclusive, 0 dud
    // --rank-by like: log-distance to the nearest --like reference spot, over
    // {cqCeil, pWin, winners}. Lower = more similar to a known record. Left at
    // its default (huge) for every other ranking mode.
    double likeDist = 1e18;
    // which quality gates this row would have failed under the DEFAULT scheme
    // (--eff-target / --min-pwin / --min-winners) - these are bypassed as hard
    // drops under --rank-by like (see main()), but still worth showing.
    bool wouldFailEff = false, wouldFailPWin = false, wouldFailWinners = false;
};

static void oneArm(int ccx, int ccz, uint64_t salt, long long N, int T,
                   uint64_t mask, uint64_t val,
                   unsigned long long& hits, unsigned& mx) {
    unsigned long long *dH; unsigned int *dM;
    CUDA_CHECK(cudaMalloc(&dH, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&dM, sizeof(unsigned int)));
    CUDA_CHECK(cudaMemset(dH, 0, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemset(dM, 0, sizeof(unsigned int)));
    int blocks = (int)std::min<long long>(8192, (N + 255) / 256);
    if (blocks < 1) blocks = 1;
    rateKernel<<<blocks, 256>>>((long long)ccx, (long long)ccz, salt, N, T, mask, val & mask, dH, dM);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaMemcpy(&hits, dH, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
    unsigned m = 0;
    CUDA_CHECK(cudaMemcpy(&m, dM, sizeof(unsigned int), cudaMemcpyDeviceToHost));
    mx = m;
    cudaFree(dH); cudaFree(dM);
}

static Measure measure(int ccx, int ccz, uint64_t seedBase, const Derivation& D,
                       long long N, long long Nmin, int T, double minLift, double minSep,
                       unsigned long long minHits, unsigned minMax) {
    Measure M;
    // Same idea as derive(): --measure-n is a ceiling. A live spot hits
    // --min-hits almost immediately (p(>=60|mask) ~ 7.6e-4 measured, so 32M
    // seeds gives ~24k hits and we stop there); only genuinely sparse spots
    // pay the full ceiling, and those are the ones we are about to discard.
    long long useN = std::min(Nmin, N);
    unsigned fBase = 0, fTreat = 0, fCtrl = 0; bool firstPass = true;
    for (;;) {
        M = Measure(); M.N = useN;
        // three independent streams: decorrelated from the derivation and from
        // each other, so we never test on the seeds we mined the bias from.
        oneArm(ccx, ccz, seedBase ^ 0x9E3779B97F4A7C15ULL, useN, T, 0, 0, M.baseHits, M.baseMax);
        oneArm(ccx, ccz, seedBase ^ 0xC2B2AE3D27D4EB4FULL, useN, T, D.mask, D.val, M.treatHits, M.treatMax);
        oneArm(ccx, ccz, seedBase ^ 0x165667B19E3779F9ULL, useN, T, D.mask, (~D.val) & D.mask,
               M.ctrlHits, M.ctrlMax);
        // The max counts MUST come from a fixed sample size or they are not
        // comparable between locations: adaptive sizing stops a live spot at
        // Nmin but escalates a sparse one 16x, which would hand the weak spots
        // more draws to set a high max. Freeze the maxes at the first pass.
        if (firstPass) {
            fBase = M.baseMax; fTreat = M.treatMax; fCtrl = M.ctrlMax; firstPass = false;
            // The --min-chunks verdict reads the FROZEN max, so no amount of
            // escalation can change it. If the first pass already failed that
            // bar, escalating 32M -> 128M -> 512M burns ~2G samples to
            // re-confirm a decision that is already made. Measured on a real
            // run: duds cost 3.2s vs 0.5s for keeps, purely from this.
            if (M.treatMax < minMax) break;
        }
        if (M.treatHits >= minHits || useN >= N) break;
        useN = std::min(useN * 4, N);
    }
    M.baseMax = fBase; M.treatMax = fTreat; M.ctrlMax = fCtrl;
    M.maxN = std::min(Nmin, N);
    M.ctrlZero = (M.ctrlHits == 0);
    N = M.N;
    M.baseRate  = (double)M.baseHits  / (double)N;
    M.treatRate = (double)M.treatHits / (double)N;
    M.ctrlRate  = (double)M.ctrlHits  / (double)N;

    double floorRate = 1.0 / (double)N;   // one-hit resolution limit
    M.lift = M.treatRate / std::max(M.baseRate, floorRate);
    M.sep  = M.treatRate / std::max(M.ctrlRate, floorRate);

    if (D.bitsFixed == 0)                       M.verdict = 0;
    else if (M.treatHits < minHits)             M.verdict = 1;
    else if (M.treatMax < minMax)               M.verdict = 0;   // --min-chunks: never demonstrated a real count
    else if (M.lift >= minLift && M.sep >= minSep) M.verdict = 2;
    else                                        M.verdict = 0;
    return M;
}


// ---------------------------------------------------------------------------
// Rank on p(count >= scoreT | mask). Kept separate from the 3-arm test on
// purpose: that test lives at --deep-t where the control arm has enough hits to
// mean anything, while this needs orders more samples because scoreT is rarer.
// Runs ONLY on spots that already passed the control test, and escalates only
// until --min-score-hits, so a live spot resolves in one pass.
// Efficiency ceiling probe. Runs on the CPU for the handful of spots that pass
// the control test - a few million masked seeds each, trivial next to the GPU
// hunt that would otherwise be wasted on a low-ceiling spot. Uses slime_core's
// EXACT annulus weights, so the number matches slime_refine to the block.
//
// It answers the question chunk-count cannot: "if this spot makes a high count,
// how well do those chunks pack?" A spot whose 68+ layouts average 88% can never
// beat a 94% record no matter how many chunks it hits - so this both RANKS and
// FILTERS. cqTarget below which a spot is hopeless = record; measured per spot.
// GPU-scale replacement for the old CPU-only probe (was capped at 12M seeds /
// 400 samples on one CPU thread). Runs cqRateKernel over the full --eff-n
// budget in parallel, so pWin/cqCeil get the same statistical depth as the
// count-based measurements instead of being the thinnest-sampled number in
// the pipeline - which is exactly the "everything hinges on a handful of
// samples past a minimum" gap this replaces.
static void efficiencyProbe(int ccx, int ccz, uint64_t seedBase, const Derivation& D, int scoreT,
                            long long nSeeds, double recordCq, double recMargin, Measure& M) {
    // Widen the net a few chunks below scoreT so enough layouts qualify to
    // measure packing - efficiency is flat across adjacent counts (measured),
    // which is what makes sampling at a lower count a fair estimate of packing
    // at scoreT rather than a biased one.
    //
    // The net has to KEEP widening until it actually catches something. A fixed
    // scoreT-4 silently dies exactly when it matters most: at --score-t 70 the
    // floor is 66 chunks, too rare to hit even once in the --eff-n budget, so
    // every spot reported effMean 0 / cqCeil 0 / pWin 0 and the ranking had
    // nothing to order by (measured: 208 of 208 spots came back empty at
    // score-t 70, while the same probe at score-t 66 -> floor 62 returned
    // healthy 84-92% readings). Zero samples and genuinely-bad packing are very
    // different facts that both print as 0.0%. So: step the floor down until
    // the sample is big enough to mean anything, and record the floor actually
    // used so a reader can see how far it had to reach.
    int floorCount = scoreT - 4;
    // The bar: a layout of exactly scoreT chunks needs this packing fraction to
    // beat the record. scoreT 70 vs a 66.04 record -> 94.34%.
    double effBar = (scoreT > 0) ? recordCq / (double)scoreT : 1.0;
    // effBar > 1 is unachievable: cq = blocks/256 and a chunk holds at most 256
    // eligible blocks, so cq <= chunk count ALWAYS and no layout of scoreT
    // chunks can reach recordCq when scoreT < recordCq. pWin is then a silent,
    // structural zero at every spot - which reads as "these spots are all bad"
    // rather than "you asked an impossible question". main() warns about this
    // at argument-validation time, since this function only runs for spots that
    // already reached verdict==2 and so never sees the runs that need telling.

    // Enough layouts to make a mean/tail fraction worth printing. Below this the
    // reading is noise; 2000 resolves pWin to well under a percent.
    const unsigned long long MIN_EFF_SAMPLES = 2000;
    // Do not widen past this: packing flatness is measured across ADJACENT
    // counts, so a floor dragged tens of chunks below scoreT would be measuring
    // a different population and quietly reporting it as this one.
    const int MIN_EFF_FLOOR = 55;

    // Blocks needed to beat the record - measured at the CHUNK-ALIGNED centre,
    // which is the only thing this kernel ever evaluates.
    //
    // recordCq is a BLOCK-REFINED number: 66.04 is what slime_refine found at
    // (3680,6989) after searching sub-chunk offsets, while that same seed scores
    // 16821 blocks = 65.71 cq at the chunk-aligned (3680,6992) this kernel sees.
    // Testing chunk-aligned blocks against a block-refined bar is apples to
    // oranges and rejects the actual record family (16821 < ceil(66.04*256) =
    // 16907) - a false negative on the one family known to contain records.
    //
    // So the bar is lowered by recMargin, the cq that refinement typically
    // recovers by finding a better sub-chunk position (+0.33 on the record:
    // 65.71 -> 66.04). A candidate clearing this bar is one whose chunk-aligned
    // score is high enough that refinement could carry it past the record;
    // slime_refine still decides whether it actually does.
    int recBlocks = (int)std::ceil((recordCq - recMargin) * 256.0);
    // The kernel only sees seeds passing c >= floorCount, and cq <= c always, so
    // the gate must sit at or below ceil(recordCq) or record-beaters could be
    // filtered out before being counted.
    int recGate = (int)std::ceil(recordCq);
    if (floorCount > recGate) floorCount = recGate;

    unsigned long long *dH, *dWin, *dRec; double *dSum;
    CUDA_CHECK(cudaMalloc(&dH,   sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&dWin, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&dRec, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc(&dSum, sizeof(double)));

    unsigned long long h = 0, win = 0, rec = 0; double sum = 0;
    int blk = (int)std::min<long long>(8192, (nSeeds + 255) / 256);
    if (blk < 1) blk = 1;

    for (;;) {
        CUDA_CHECK(cudaMemset(dH,   0, sizeof(unsigned long long)));
        CUDA_CHECK(cudaMemset(dWin, 0, sizeof(unsigned long long)));
        CUDA_CHECK(cudaMemset(dRec, 0, sizeof(unsigned long long)));
        CUDA_CHECK(cudaMemset(dSum, 0, sizeof(double)));
        cqRateKernel<<<blk, 256>>>((long long)ccx, (long long)ccz, seedBase ^ 0xEFF1C1E7ULL,
                                   nSeeds, floorCount, D.mask, D.val & D.mask, effBar, recBlocks,
                                   dH, dSum, dWin, dRec);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaMemcpy(&h,   dH,   sizeof(unsigned long long), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(&win, dWin, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(&rec, dRec, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(&sum, dSum, sizeof(double), cudaMemcpyDeviceToHost));
        if (h >= MIN_EFF_SAMPLES || floorCount <= MIN_EFF_FLOOR) break;
        floorCount -= 2;
    }
    cudaFree(dH); cudaFree(dWin); cudaFree(dRec); cudaFree(dSum);

    // Denominator is every seed SAMPLED, not just those clearing the gate: the
    // question is "what fraction of this family beats the record", which is what
    // makes 1/pRec an expected-seeds-to-a-record number.
    M.recHits = rec; M.recN = nSeeds;
    M.pRec = nSeeds ? (double)rec / (double)nSeeds : 0.0;

    if (h) {
        M.effMean = sum / (double)h;             // mean packing fraction at high count
        M.effSamples = h;
        M.cqCeil = M.effMean * scoreT;           // best plausible cq: full scoreT at mean packing
        M.pWin   = (double)win / (double)h;      // THE ranking key
        M.effFloor = floorCount;                 // how far the net had to reach
    } else { M.effMean = 0; M.cqCeil = 0; M.effSamples = 0; M.pWin = 0; M.effFloor = floorCount; }
}

static void scoreAt(int ccx, int ccz, uint64_t seedBase, const Derivation& D,
                    int scoreT, long long scoreCap, long long scoreMin,
                    unsigned long long minScoreHits, Measure& M) {
    long long useN = std::min(scoreMin, scoreCap);
    for (;;) {
        unsigned long long h = 0; unsigned mx = 0;
        oneArm(ccx, ccz, seedBase ^ 0x27D4EB2F165667C5ULL, useN, scoreT, D.mask, D.val, h, mx);
        M.scoreHits = h; M.scoreN = useN; M.scoreMax = mx;
        M.scoreRate = (double)h / (double)useN;
        if (h >= minScoreHits || useN >= scoreCap) break;
        useN = std::min(useN * 4, scoreCap);
    }
}

// ---------------------------------------------------------------------------
// --rank-by like support.
//
// Distance to a reference spot's measured profile, in log space over the
// three numbers that actually separate a record from a dud (cqCeil, pWin,
// winners - see the Measure struct comments). |log(a)-log(b)| is a relative
// difference (log(a/b)), so this needs no separate per-dimension
// normalization: doubling cqCeil and doubling pWin both cost the same 0.69
// of distance. Lower = more similar. eps keeps log() finite for spots that
// never won or never reached the target count at all.
// ---------------------------------------------------------------------------
static double likeDistance(const Measure& cand, const Measure& ref) {
    const double eps = 1e-6;
    double d = 0;
    d += fabs(log(std::max(cand.cqCeil, eps))  - log(std::max(ref.cqCeil, eps)));
    d += fabs(log(cand.pWin + eps)             - log(ref.pWin + eps));
    d += fabs(log(cand.winners + eps)          - log(ref.winners + eps));
    return d;
}

// Runs the SAME derive -> measure -> reach-guard -> efficiency -> deep-count
// pipeline the --scan candidate loop uses (below), on one spot, so a --like
// reference's feature vector is measured fresh under THIS run's parameters
// rather than trusted from old README literals. Verdict gates are not applied
// here - a reference spot's numbers are wanted regardless of whether it would
// itself have cleared the default minimums (the whole point of --rank-by like
// is that clearing them is not required to be similar to one).
struct RefProfile { int bx, bz; Derivation D; Measure M; };
static RefProfile measureReference(int bx, int bz, uint64_t seedBase,
                                   long long bigN, long long bigNMin, int tStart, int tStep,
                                   int deepT, int tFloor, int bitWindow, int maxBits,
                                   double zMin, double minDev, unsigned long long minTail,
                                   long long measureN, long long measureNMin,
                                   double minLift, double minSep, unsigned long long minHits, unsigned minMax,
                                   bool reachCheck, long long reachN, double reachDev,
                                   int scoreT, long long effN, double recordCq, double recMargin,
                                   long long scoreCap, long long scoreMin, unsigned long long minScoreHits) {
    RefProfile P; P.bx = bx; P.bz = bz;
    int rcx = bx / 16, rcz = bz / 16;
    P.D = derive(rcx, rcz, seedBase, bigN, bigNMin, tStart, tStep, deepT, tFloor,
                bitWindow, maxBits, zMin, minDev, minTail, false);
    if (!P.D.bitsFixed) return P;
    P.M = measure(rcx, rcz, seedBase, P.D, measureN, measureNMin, deepT, minLift, minSep, minHits, minMax);
    if (reachCheck) {
        reachGuard(rcx, rcz, seedBase, P.D, reachN, deepT, bitWindow, reachDev, minTail, false);
        if (P.D.released) P.M = measure(rcx, rcz, seedBase, P.D, measureN, measureNMin,
                                        deepT, minLift, minSep, minHits, minMax);
    }
    efficiencyProbe(rcx, rcz, seedBase, P.D, scoreT, effN, recordCq, recMargin, P.M);
    scoreAt(rcx, rcz, seedBase, P.D, scoreT, scoreCap, scoreMin, minScoreHits, P.M);
    P.M.winners = std::pow(2.0, 48.0 - P.D.bitsFixed) * P.M.scoreRate * P.M.pWin;
    return P;
}

// Every emitted hunt command carries --seeds-out, so each spot (family)
// accumulates into its own file under the scan's seeds folder. The filename is
// "<x>_<z>.csv" - the refine runner parses the coords straight back out of it,
// which is why nothing else may go in that name.
static std::string huntCommand(int bx, int bz, uint64_t mask, uint64_t val,
                               int mChunks, int huntFloor, long long reportEvery,
                               const char* exe, const char* seedsDir) {
    char buf[640];
    if (seedsDir && *seedsDir)
        snprintf(buf, sizeof(buf),
                 "%s --seed-count 0 --center-x %d --center-z %d --m-chunks %d "
                 "--fix-mask 0x%llX --fix-val 0x%llX --record-floor %d --seeds-floor %d "
                 "--report-every %lld --give-up-after 20000000 --give-up-hits 10 --give-up-floor %d "
                 "--seeds-out %s/%d_%d.csv",
                 exe, bx, bz, mChunks,
                 (unsigned long long)mask, (unsigned long long)(val & mask),
                 huntFloor, huntFloor, reportEvery, huntFloor - 6, seedsDir, bx, bz);
    else
        snprintf(buf, sizeof(buf),
                 "%s --seed-count 0 --center-x %d --center-z %d --m-chunks %d "
                 "--fix-mask 0x%llX --fix-val 0x%llX --record-floor %d --seeds-floor %d "
                 "--report-every %lld",
                 exe, bx, bz, mChunks,
                 (unsigned long long)mask, (unsigned long long)(val & mask),
                 huntFloor, huntFloor, reportEvery);
    return std::string(buf);
}


// ---------------------------------------------------------------------------
// FEEDBACK: derive bits from ACTUAL found seeds (slime_gpu's seeds.csv).
//
// Sampling has a hard ceiling. The bootstrap tops out around 20 bits because
// even at --deep-t 60 you are conditioning on p ~ 7.6e-4; the bits that only
// express at 70+ are behind a p ~ 1e-9 wall that no feasible sample reaches.
// But slime_gpu's real hits ARE that conditioning, already paid for. Their bit
// structure carries information sampling cannot buy. This is precisely how
// bits 7/9/16/21 were found in your seeds70.csv: they are free in the hunt's
// mask, yet every single winner converged on them.
//
// LOOP: hunt with the current mask -> seeds.csv -> --from-seeds -> wider mask
//       -> hunt again. Each pass needs enough NEW seeds to clear the z bar:
//       a fully-locked bit over n seeds has z = sqrt(n), so n=31 gives z=5.6
//       (clears --z-min 5.0) and n=16 gives z=4.0 (does not).
//
// COST: bits learned from found 70s are FAMILY bits, not general high-count
// bits. They make 70-71 much faster and 72 LESS likely. See REACH vs SPEED.
// ---------------------------------------------------------------------------
static inline uint64_t fxPart(long long cx) {
    return (uint64_t)(int64_t)(int32_t)((int64_t)cx * (int64_t)cx * 0x4c1906LL)
         + (uint64_t)(int64_t)(int32_t)((int64_t)cx * 0x5ac0dbLL);
}
static inline uint64_t fzPart(long long cz) {
    return (uint64_t)((int64_t)((int32_t)((int64_t)cz * (int64_t)cz)) * 0x4307a7LL)
         + (uint64_t)(int64_t)(int32_t)((int64_t)cz * 0x5f24fLL);
}

static int feedback(const std::string& file, int ccx, int ccz, int mChunks, int seedFloor,
                    int bitWindow, int maxBits, double zMin, double minDev,
                    int huntFloor, long long reportEvery, const std::string& huntExe) {
    std::vector<long long> raw;
    FILE* f = fopen(file.c_str(), "r");
    if (!f) { fprintf(stderr, "cannot read %s\n", file.c_str()); return 1; }
    std::string cur; int ch;
    while ((ch = fgetc(f)) != EOF) {
        if (ch == ',' || ch == '\n' || ch == '\r' || ch == ' ') {
            if (cur.size()) { raw.push_back(strtoll(cur.c_str(), nullptr, 10)); cur.clear(); }
        } else cur += (char)ch;
    }
    if (cur.size()) raw.push_back(strtoll(cur.c_str(), nullptr, 10));
    fclose(f);

    // Seed VALUES are irrelevant -- only the low-48 layout matters, and many
    // distinct 64-bit seeds share one. Dedup or the bit stats get weighted by
    // however many times a layout happened to be rediscovered.
    std::vector<long long> seeds;
    {
        std::vector<uint64_t> seen;
        for (size_t i = 0; i < raw.size(); i++) {
            uint64_t k = (uint64_t)raw[i] & ((1ULL << 48) - 1);
            if (std::find(seen.begin(), seen.end(), k) == seen.end()) { seen.push_back(k); seeds.push_back(raw[i]); }
        }
    }
    printf("=== FEEDBACK from %s ===\n", file.c_str());
    printf("%zu seeds parsed, %zu unique low-48 layouts.\n", raw.size(), seeds.size());
    if (seeds.empty()) return 1;

    // posOffset is separable: posOffset(cx,cz) = fx(cx) + fz(cz). Precompute
    // both axes once over the window instead of recomputing per seed/cell.
    int half = mChunks / 2, pad = 8;
    int lo = -half - pad, hi = half - 1 + pad, gw = hi - lo + 1;
    std::vector<uint64_t> FX(gw), FZ(gw);
    for (int i = 0; i < gw; i++) { FX[i] = fxPart(ccx + lo + i); FZ[i] = fzPart(ccz + lo + i); }
    int n = (int)g_dx.size();

    std::vector<long long> keep; std::vector<int> keptScore;
    int bestAll = 0;
    for (size_t si = 0; si < seeds.size(); si++) {
        int best = 0;
        for (int dz = -half; dz < half; dz++)
            for (int dx = -half; dx < half; dx++) {
                int c = 0;
                for (int i = 0; i < n; i++)
                    c += (int)slimeFromOffset(seeds[si], FX[dx + g_dx[i] - lo] + FZ[dz + g_dz[i] - lo]);
                if (c > best) best = c;
            }
        if (best > bestAll) bestAll = best;
        if (best >= seedFloor) { keep.push_back(seeds[si]); keptScore.push_back(best); }
    }
    printf("scored in a %dx%d chunk window at chunk (%d,%d): best %d, %zu at or above --seed-floor %d.\n",
           mChunks, mChunks, ccx, ccz, bestAll, keep.size(), seedFloor);
    if (keep.size() < 16) {
        printf("\nToo few (%zu). A fully-locked bit over n seeds has z = sqrt(n), so you need\n"
               "n >= %d to clear --z-min %.1f. Hunt longer, or lower --seed-floor.\n",
               keep.size(), (int)ceil(zMin * zMin), zMin);
        return 1;
    }

    uint64_t mask = 0, val = 0; int bits = 0;
    printf("\nbit : freq   z      -> action   [n=%zu, need |z|>=%.1f AND |freq-0.5|>=%.3f]\n",
           keep.size(), zMin, minDev);
    struct Cand { int b; double f, z; };
    std::vector<Cand> cands;
    for (int b = 0; b < bitWindow; b++) {
        unsigned long long ones = 0;
        for (size_t i = 0; i < keep.size(); i++) if (((uint64_t)keep[i] >> b) & 1ULL) ones++;
        double fr = (double)ones / (double)keep.size();
        double z  = fabs((2.0 * (double)ones - (double)keep.size()) / sqrt((double)keep.size()));
        cands.push_back(Cand{ b, fr, z });
    }
    std::sort(cands.begin(), cands.end(), [](const Cand& a, const Cand& b) { return a.z > b.z; });
    for (size_t i = 0; i < cands.size(); i++) {
        const Cand& c = cands[i];
        bool ok = (c.z >= zMin) && (fabs(c.f - 0.5) >= minDev) && (bits < maxBits);
        if (ok) {
            printf("  %2d : %.3f  %6.2f  -> force %d\n", c.b, c.f, c.z, c.f > 0.5 ? 1 : 0);
            mask |= (1ULL << c.b); if (c.f > 0.5) val |= (1ULL << c.b); bits++;
        } else if (fabs(c.f - 0.5) >= minDev && bits < maxBits) {
            // A leaning-but-unproven bit. z = 2|f-0.5|*sqrt(n), so the seed
            // count that would settle it is (zMin / (2|f-0.5|))^2. This is the
            // actual answer to "how long do I hunt before feeding back again".
            long long nNeed = (long long)ceil(pow(zMin / (2.0 * fabs(c.f - 0.5)), 2.0));
            printf("  %2d : %.3f  %6.2f  -> leaning %d, unproven: needs n >= %lld layouts\n",
                   c.b, c.f, c.z, c.f > 0.5 ? 1 : 0, nNeed);
        } else {
            printf("  %2d : %.3f  %6.2f  -> free\n", c.b, c.f, c.z);
        }
    }
    printf("\nmask=0x%llX  val=0x%llX  (%d bits)  layouts left 2^%d = %.3g\n",
           (unsigned long long)mask, (unsigned long long)val, bits, 48 - bits, pow(2.0, 48 - bits));
    printf("\nNOTE: these are FAMILY bits, learned from seeds that already scored >= %d.\n"
           "They will make %d-%d much faster and 72+ less likely. If you are chasing the\n"
           "record rather than farming the known family, keep the --scan mask instead.\n",
           seedFloor, seedFloor, bestAll);
    printf("\n%s\n", huntCommand(ccx * 16, ccz * 16, mask, val, mChunks, huntFloor, reportEvery, huntExe.c_str(), "main/seeds").c_str());
    return 0;
}

static const char* need(int argc, char** argv, int& i, const char* f) {
    if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", f); exit(1); }
    return argv[++i];
}

// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    // NOTE: do NOT call setvbuf here. MSVC requires size >= 2 when the buffer
    // pointer is NULL, and it maps _IOLBF to _IOFBF (full buffering), so it is
    // both invalid and backwards on Windows. The explicit fflush(stdout) after
    // every candidate row is the portable way to stop output arriving in bursts.
    // shared
    int centerBX = 2000, centerBZ = 8544;
    uint64_t seedBase = 0xA1CE5EED;
    bool selfTest = false, bench = false, scoreOne = false;
    // --family-sweep: hold the spot, vary the family. See the sweep block below.
    bool familySweep = false;
    uint64_t sweepMask = 0, sweepMark = 0;
    long long sweepN = 1000, sweepSeeds = 400000;
    int sweepFloor = 0;
    std::string sweepOut;
    bool doScan = false, doCheck = false;
    std::string fromSeeds; int seedFloor = 70;

    // pass 1 (variance gate)
    int range = 2000, stepX = 1, stepZ = 1, zPeriod = 0, zBand = 1;
    // --range is CHUNKS along X but BLOCKS along Z (the --z-all lattice window
    // is built in block space). So --range 10000 sweeps +/-160000 blocks E/W
    // but only +/-10000 N/S - fine for a wide sweep, useless for "stay within
    // N blocks of spawn". Shrinking --range to fix X breaks Z instead: the
    // nearest lattice lines sit at blockZ 768/784, so any range under ~800
    // yields ZERO z lines and the scan silently finds nothing.
    // --range-x takes BLOCKS and bounds X only, leaving Z's window alone.
    // Negative = unset = keep the historical chunk-based behaviour, so every
    // command written before this flag existed still means what it meant.
    int rangeXBlocks = -1;
    // --z-only <z1,z2,...> restricts pass 1 to ONLY these Z lines. Anchor-
    // free (ignores --center-z). Use when you already know the hot Z lines and
    // want to sweep X across all of them; skips the variance gate for cold
    // rows entirely.
    std::vector<int> zOnly;   // if non-empty, --z-period/--z-band are ignored
    bool zAll = false;        // --z-all: generate every hot Z line from the closed form
    int scanSeeds = 4000, refineTop = 20000, refineSeeds = 50000;
    double varMin = 0.0;
    // --name gives this scan its own identity. Everything it produces is
    // keyed by it: main/commands/commands_<name>.csv holds the hunt commands,
    // and each spot's hunt writes main/seeds/<name>/<x>_<z>.csv. Defaults to
    // the center coords so two scans never clobber each other.
    std::string scanName;
    std::string outFile;   // resolved after parsing (needs scanName)

    // pass 2 (deep-tail rank)
    int gateTop = 100, benchLocs = 3, deepT = 60, scoreT = 68, tStart = 45, tStep = 5, tFloor = 40;
    int topPrint = 10;   // how many survivors to show in console preview (CSV always has all)
    // --rank-by score|hits|combined|like|win. score is the default (rarity of
    // >=T); win ranks by record-beaters per seed sampled (see the sort lambda).
    // hits ranks by raw count (variety - if you saw 52 seeds cross 68 vs 3 seeds
    // cross 68, the 52 spot has more independent chances at a 70+ even at the
    // same rate). combined = score * log(hits+1) rewards both signals.
    // like: rank by resemblance to --like reference spots (default: the two
    // known records) instead of a hard pass/fail on --eff-target/--min-pwin/
    // --min-winners - see measureReference()/likeDistance() above.
    std::string rankBy = "score";
    // 14, not 20. Measured: a mask of b bits carves out a residue class of
    // exactly 2^(48-b) layouts and NOTHING else lives in it.
    //     20 bits -> 2^28 =   268M layouts
    //     14 bits -> 2^34 = 17179M layouts   (64x)
    // Both known records were found with 14-bit masks. The derivation adds bits
    // while they raise the HIT RATE, but every bit halves the family, and the
    // later bits buy less than the 2x they cost - so 20 bits maximises rate and
    // MINIMISES total reachable options. winners = 2^(48-b) x rate x pWin is what
    // actually decides, and it favours looser masks. --max-bits 20 restores the
    // old behaviour if you want raw hits-per-second instead of reachable options.
    int bitWindow = 24, maxBits = 14;
    long long bigN = 200000000LL, bigNMin = 8000000LL;
    long long measureN = 128000000LL, measureNMin = 8000000LL;
    // --score-t needs a far bigger sample than --deep-t: p(>=60|mask) is ~7.9e-4
    // at your spot but p(>=70|mask) is ~3e-8, four orders down. These are the
    // budget for that. scoreCap is a CEILING - a live spot stops at scoreMin.
    // scoreCap is set by HOW MUCH WORSE THAN YOUR CONTROL YOU STILL CARE ABOUT,
    // not by how deep the sample can go. Your control sits at p(>=70) ~ 3.1e-8,
    // so --min-score-hits 3 needs ~1e8 seeds to see it. At 512M anything that
    // still shows 0 hits has p < 6e-9 - five times worse than the spot you
    // already have, i.e. not an upgrade. A real spot hits in ~32M; anything
    // needing the full 128M ceiling is not competitive.
    long long scoreCap = 128000000LL, scoreMin = 32000000LL;
    unsigned long long minScoreHits = 3;
    // efficiency-ceiling filter/rank (the fix for the four-spot shootout, where
    // every spot found 70-chunk layouts but at 88-92% packing vs the record's
    // 94%). A spot whose high-count layouts average below --eff-target cq is
    // geometrically incapable of beating the record and is cut before hunting.
    // 63, not the 65.71 record: cqCeil is the spot's MEAN packing x scoreT, and a
    // record-beating seed is a tail outlier ABOVE that mean (65.71 came from a spot
    // whose mean was ~63). Filtering at 62 keeps both known record spots (their
    // means are 62-63) plus anything with comparable upside; raise it to prune
    double effTarget = 62.0;
    // the record to beat, in cq. Sets the packing bar: recordCq / scoreT.
    // 66.04 = the real current best (70 chunks @ 94.3%, block (3680,6989)).
    // This was 65.71 for a long time, which is a DIFFERENT, lower result - the
    // bar was being set against a record we had already beaten, so pWin counted
    // some non-winners as winners. Override per-run with --record-cq.
    double recordCq = 66.04;
    // cq that block-precision refinement typically recovers over the
    // chunk-aligned score by finding a better sub-chunk position. Measured on
    // the record: 65.71 chunk-aligned -> 66.04 refined = +0.33. The scan only
    // ever sees chunk-aligned scores, so this is what keeps its record bar
    // comparable to a refined record instead of unreachably strict.
    double recMargin = 0.40;
    // a spot must produce record-beating packing at least this often. 0 disables.
    // 0 = rank on pWin but never cut on it. 400 samples resolves ~0.25%, which is
    // enough to order spots and not enough to condemn one.
    double minPWin = 0.0;
    // a family must plausibly CONTAIN a record-beater. < 1 means it does not.
    double minWinners = 0.25;
    // --emit-top N: emit the top N hunt commands regardless of the pass/fail
    // filters. THIS IS HOW THE RECORDS WERE ACTUALLY FOUND - derive a 14-bit
    // mask at a spot, hunt it to exhaustion, score the seeds. The filters
    // (3-arm --min-hits, the max prefilter, pWin) are all calibrated on TIGHT
    // masks with fat hit rates; a 14-bit mask fails every one of them while
    // being the exact configuration that produced both records. --check has
    // never had these filters, which is why --check works and --scan does not.
    int emitTop = 0;
    // A GPU-parallel seed budget (cqRateKernel), same idea as --measure-n -
    // set to the same scale so pWin/cqCeil get as many samples as the
    // count-based measurements, not the thinnest number in the pipeline.
    long long effN = 128000000LL;
    bool rankEff = true;
    // Measured on 32M samples: the two record spots show max 70/71, the marginal
    // keeper 69 - EVERY real contender shows max >= scoreT. A spot whose best in
    // 32M never reached scoreT cannot win and its cqCeil is meaningless, so it is
    // cut here, before any expensive stage. This is the permanent fix for the
    // "slow dud" bug: nothing below scoreT ever reaches the probe or the count.
    // Default 0 = cut at max < scoreT. Raise only to deliberately keep near-misses.
    int scoreMaxMargin = 0;
    // skip the deep count if the frozen max is this far below --score-t
    double zMin = 5.0, minDev = 0.08, minLift = 3.0, minSep = 3.0;
    double reachDev = 0.25; bool reachCheck = true;
    long long reachN = 8000000LL;
    unsigned long long minTail = 200, minHits = 30;
    // --derive-eff: additive post-pass, see deriveEffBits() above. Off by
    // default - same experience unless asked for.
    bool deriveEff = false;
    double minEffDev = 0.02, effZMin = 5.0;
    const unsigned minMax = 0;   // --min-chunks/--min-max removed: they filtered on the
                                 // frozen max, a noisy order statistic that --score-t replaced.
                                 // Kept at 0 so the verdict path below is a no-op.
    std::vector<std::pair<int,int> > includes;
    // --rank-by like: rank candidates by resemblance to known-good spots
    // instead of hard pass/fail minimums. --like X,Z is repeatable; with none
    // given, defaults to the two known records (see README KNOWN RECORDS).
    std::vector<std::pair<int,int> > likeSpots;

    // hunt-command passthrough
    int mChunks = 24;
    // Hunt floor = --score-t, full stop. The spot was picked for reaching score-t,
    // so that is exactly what its hunt records. (Earlier builds dropped the floor
    // below score-t to widen seeds.csv; the shootout re-scores by real cq now, so
    // the drop only changed volume and was one knob too many.)
    int huntFloor = -1;
    
    long long reportEvery = 50000000LL;
    std::string huntExe = "slime_gpu.exe";

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--center-x"))   centerBX = atoi(need(argc, argv, i, "--center-x"));
        else if (!strcmp(argv[i], "--center-z"))   centerBZ = atoi(need(argc, argv, i, "--center-z"));
        else if (!strcmp(argv[i], "--rng-seed"))   seedBase = strtoull(need(argc, argv, i, "--rng-seed"), nullptr, 0);
        else if (!strcmp(argv[i], "--self-test"))  selfTest = true;
        else if (!strcmp(argv[i], "--bench"))      bench = true;
        else if (!strcmp(argv[i], "--score-one"))  scoreOne = true;
        else if (!strcmp(argv[i], "--scan"))       doScan = true;
        
        else if (!strcmp(argv[i], "--check"))      doCheck = true;
        else if (!strcmp(argv[i], "--from-seeds")) fromSeeds = need(argc, argv, i, "--from-seeds");
        else if (!strcmp(argv[i], "--seed-floor")) seedFloor = atoi(need(argc, argv, i, "--seed-floor"));
        // pass 1 (variance gate)
        else if (!strcmp(argv[i], "--range"))      range = atoi(need(argc, argv, i, "--range"));
        else if (!strcmp(argv[i], "--range-x"))    rangeXBlocks = atoi(need(argc, argv, i, "--range-x"));
        else if (!strcmp(argv[i], "--family-sweep")) familySweep = true;
        else if (!strcmp(argv[i], "--sweep-mask"))  sweepMask  = strtoull(need(argc, argv, i, "--sweep-mask"), nullptr, 0);
        else if (!strcmp(argv[i], "--sweep-mark"))  sweepMark  = strtoull(need(argc, argv, i, "--sweep-mark"), nullptr, 0);
        else if (!strcmp(argv[i], "--sweep-n"))     sweepN     = atoll(need(argc, argv, i, "--sweep-n"));
        else if (!strcmp(argv[i], "--sweep-seeds")) sweepSeeds = atoll(need(argc, argv, i, "--sweep-seeds"));
        else if (!strcmp(argv[i], "--sweep-floor")) sweepFloor = atoi(need(argc, argv, i, "--sweep-floor"));
        else if (!strcmp(argv[i], "--sweep-out"))   sweepOut   = need(argc, argv, i, "--sweep-out");
        else if (!strcmp(argv[i], "--rec-margin")) recMargin = atof(need(argc, argv, i, "--rec-margin"));
        else if (!strcmp(argv[i], "--step"))       { stepX = stepZ = atoi(need(argc, argv, i, "--step")); }
        else if (!strcmp(argv[i], "--step-x"))     stepX = atoi(need(argc, argv, i, "--step-x"));
        else if (!strcmp(argv[i], "--step-z"))     stepZ = atoi(need(argc, argv, i, "--step-z"));
        else if (!strcmp(argv[i], "--z-period"))   zPeriod = atoi(need(argc, argv, i, "--z-period"));
        else if (!strcmp(argv[i], "--z-band"))     zBand = atoi(need(argc, argv, i, "--z-band"));
        else if (!strcmp(argv[i], "--z-only")) {
            // parse comma-separated Z BLOCK values (converted to chunk internally)
            std::string s = need(argc, argv, i, "--z-only");
            size_t start = 0;
            while (start <= s.size()) {
                size_t comma = s.find(',', start);
                std::string tok = s.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
                if (!tok.empty()) zOnly.push_back(atoi(tok.c_str()) / 16);   // block -> chunk
                if (comma == std::string::npos) break;
                start = comma + 1;
            }
        }
        else if (!strcmp(argv[i], "--z-all"))      zAll = true;
        else if (!strcmp(argv[i], "--seeds"))      scanSeeds = atoi(need(argc, argv, i, "--seeds"));
        else if (!strcmp(argv[i], "--refine-top"))   refineTop = atoi(need(argc, argv, i, "--refine-top"));
        else if (!strcmp(argv[i], "--refine-seeds")) refineSeeds = atoi(need(argc, argv, i, "--refine-seeds"));
        else if (!strcmp(argv[i], "--out-top"))    gateTop = atoi(need(argc, argv, i, "--out-top"));  // alias for --gate-top
        else if (!strcmp(argv[i], "--var-min"))    varMin = atof(need(argc, argv, i, "--var-min"));
        else if (!strcmp(argv[i], "--out"))        outFile = need(argc, argv, i, "--out");
        else if (!strcmp(argv[i], "--name"))       scanName = need(argc, argv, i, "--name");
        // pass 2 (deep-tail rank)
        
        else if (!strcmp(argv[i], "--gate-top"))   gateTop = atoi(need(argc, argv, i, "--gate-top"));
        else if (!strcmp(argv[i], "--bench-locs")) benchLocs = atoi(need(argc, argv, i, "--bench-locs"));
        else if (!strcmp(argv[i], "--deep-t"))     deepT = atoi(need(argc, argv, i, "--deep-t"));
        else if (!strcmp(argv[i], "--score-t"))    scoreT = atoi(need(argc, argv, i, "--score-t"));
        else if (!strcmp(argv[i], "--top-print"))  topPrint = atoi(need(argc, argv, i, "--top-print"));
        else if (!strcmp(argv[i], "--rank-by"))    rankBy = need(argc, argv, i, "--rank-by");
        else if (!strcmp(argv[i], "--score-n"))    scoreCap = strtoll(need(argc, argv, i, "--score-n"), nullptr, 10);
        else if (!strcmp(argv[i], "--score-n-min")) scoreMin = strtoll(need(argc, argv, i, "--score-n-min"), nullptr, 10);
        else if (!strcmp(argv[i], "--min-score-hits")) minScoreHits = strtoull(need(argc, argv, i, "--min-score-hits"), nullptr, 10);
        else if (!strcmp(argv[i], "--eff-target")) effTarget = atof(need(argc, argv, i, "--eff-target"));
        else if (!strcmp(argv[i], "--record-cq")) recordCq = atof(need(argc, argv, i, "--record-cq"));
        else if (!strcmp(argv[i], "--min-pwin"))  minPWin = atof(need(argc, argv, i, "--min-pwin"));
        else if (!strcmp(argv[i], "--min-winners")) minWinners = atof(need(argc, argv, i, "--min-winners"));
        else if (!strcmp(argv[i], "--emit-top")) emitTop = atoi(need(argc, argv, i, "--emit-top"));
        else if (!strcmp(argv[i], "--eff-n"))      effN = strtoll(need(argc, argv, i, "--eff-n"), nullptr, 10);
        else if (!strcmp(argv[i], "--no-rank-eff")) rankEff = false;
        else if (!strcmp(argv[i], "--score-max-margin")) scoreMaxMargin = atoi(need(argc, argv, i, "--score-max-margin"));
        else if (!strcmp(argv[i], "--min-sep"))    minSep = atoi(need(argc, argv, i, "--min-sep"));
        else if (!strcmp(argv[i], "--t-start"))    tStart = atoi(need(argc, argv, i, "--t-start"));
        else if (!strcmp(argv[i], "--t-step"))     tStep = atoi(need(argc, argv, i, "--t-step"));
        else if (!strcmp(argv[i], "--t-floor"))    tFloor = atoi(need(argc, argv, i, "--t-floor"));
        else if (!strcmp(argv[i], "--bit-window")) bitWindow = atoi(need(argc, argv, i, "--bit-window"));
        else if (!strcmp(argv[i], "--max-bits"))   maxBits = atoi(need(argc, argv, i, "--max-bits"));
        else if (!strcmp(argv[i], "--big-n"))      bigN = strtoll(need(argc, argv, i, "--big-n"), nullptr, 10);
        else if (!strcmp(argv[i], "--big-n-min"))  bigNMin = strtoll(need(argc, argv, i, "--big-n-min"), nullptr, 10);
        else if (!strcmp(argv[i], "--measure-n-min")) measureNMin = strtoll(need(argc, argv, i, "--measure-n-min"), nullptr, 10);
        else if (!strcmp(argv[i], "--measure-n"))  measureN = strtoll(need(argc, argv, i, "--measure-n"), nullptr, 10);
        else if (!strcmp(argv[i], "--z-min"))      zMin = atof(need(argc, argv, i, "--z-min"));
        else if (!strcmp(argv[i], "--min-dev"))    minDev = atof(need(argc, argv, i, "--min-dev"));
        else if (!strcmp(argv[i], "--reach-dev"))  reachDev = atof(need(argc, argv, i, "--reach-dev"));
        else if (!strcmp(argv[i], "--reach-n"))    reachN = strtoll(need(argc, argv, i, "--reach-n"), nullptr, 10);
        else if (!strcmp(argv[i], "--no-reach-check")) reachCheck = false;
        else if (!strcmp(argv[i], "--derive-eff"))   deriveEff = true;
        else if (!strcmp(argv[i], "--min-eff-dev"))  minEffDev = atof(need(argc, argv, i, "--min-eff-dev"));
        else if (!strcmp(argv[i], "--eff-z-min"))    effZMin = atof(need(argc, argv, i, "--eff-z-min"));
        else if (!strcmp(argv[i], "--min-lift"))   minLift = atof(need(argc, argv, i, "--min-lift"));
        else if (!strcmp(argv[i], "--min-sep"))    minSep = atof(need(argc, argv, i, "--min-sep"));
        else if (!strcmp(argv[i], "--min-tail"))   minTail = strtoull(need(argc, argv, i, "--min-tail"), nullptr, 10);
        else if (!strcmp(argv[i], "--min-hits"))   minHits = strtoull(need(argc, argv, i, "--min-hits"), nullptr, 10);
        else if (!strcmp(argv[i], "--include")) {
            const char* s = need(argc, argv, i, "--include");
            int ix = 0, iz = 0;
            if (sscanf(s, "%d,%d", &ix, &iz) == 2) includes.push_back(std::make_pair(ix, iz));
            else { fprintf(stderr, "--include wants X,Z in block coords e.g. --include 2000,8544\n"); return 1; }
        }
        else if (!strcmp(argv[i], "--like")) {
            const char* s = need(argc, argv, i, "--like");
            int ix = 0, iz = 0;
            if (sscanf(s, "%d,%d", &ix, &iz) == 2) likeSpots.push_back(std::make_pair(ix, iz));
            else { fprintf(stderr, "--like wants X,Z in block coords e.g. --like 2000,8544\n"); return 1; }
        }
        // hunt-command passthrough
        else if (!strcmp(argv[i], "--m-chunks"))     mChunks = atoi(need(argc, argv, i, "--m-chunks"));
        else if (!strcmp(argv[i], "--report-every")) reportEvery = strtoll(need(argc, argv, i, "--report-every"), nullptr, 10);
        else if (!strcmp(argv[i], "--hunt-exe"))     huntExe = need(argc, argv, i, "--hunt-exe");
        else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 1; }
    }
    if (stepX < 1) stepX = 1;
    if (stepZ < 1) stepZ = 1;
    if (bitWindow > MAX_BIT_WINDOW) bitWindow = MAX_BIT_WINDOW;
    if (maxBits > bitWindow) maxBits = bitWindow;
    if (tStep < 1) tStep = 1;
    if (deepT < tStart) deepT = tStart;
    if (scoreT < deepT) scoreT = deepT;
    if (scoreMin > scoreCap) scoreMin = scoreCap;
    // Validate the packing bar HERE, not inside efficiencyProbe(): that only
    // runs for spots reaching verdict==2, so a run where nothing passes would
    // never reach the check and the bad setting would pass unnoticed - which is
    // exactly the case that needs warning. See efficiencyProbe() for why
    // effBar > 1 is unachievable rather than merely strict.
    if (scoreT > 0 && recordCq / (double)scoreT > 1.0) {
        fprintf(stderr,
            "\n  WARNING: --score-t %d is below --record-cq %.2f, so beating the record\n"
            "  would need %.1f%% packing - impossible (cq <= chunk count, max 100%%).\n"
            "  pWin/winners will be 0 at EVERY spot and cannot rank anything.\n"
            "  Raise --score-t to at least %d (70-72 recommended).\n\n",
            scoreT, recordCq, 100.0 * recordCq / (double)scoreT, (int)ceil(recordCq));
    }
    huntFloor = scoreT;   // one input, no drop, no manual override
    if (tFloor > tStart) tFloor = tStart;
    if (bigNMin > bigN) bigNMin = bigN;
    if (measureNMin > measureN) measureNMin = measureN;

    HS_MKDIR("main");
    buildMaskOffsets();
    int ccx = centerBX / 16, ccz = centerBZ / 16;

    // Resolve this scan's identity and the folders it owns.
    //   main/commands/commands_<name>.csv   the hunt commands
    //   main/seeds/<x>_<z>.csv              one seed file per spot (family)
    if (scanName.empty()) {
        char nb[96];
        snprintf(nb, sizeof(nb), "%d_%d_r%d", centerBX, centerBZ, range);
        scanName = nb;
    }
    // --rank-by like with no --like given: fall back to the two known records
    // (see README KNOWN RECORDS) - at their HUNT centre (chunk-aligned), not
    // the best-BLOCK answer slime_refine reports. 3680,6989 is not a multiple
    // of 16; the chunk it rounds to under this tool's own bx/16 truncation is
    // 436, not the record's actual chunk 437 (block 6992) - derive on the
    // wrong chunk and you get noise, not a reference profile.
    if (rankBy == "like" && likeSpots.empty()) {
        likeSpots.push_back(std::make_pair(2000, 8544));
        likeSpots.push_back(std::make_pair(3680, 6992));
    }
    HS_MKDIR("main/commands");
    HS_MKDIR("main/seeds");
    // Hunt seeds land directly in main/seeds/<x>_<z>.csv - not nested under a
    // per-scan subfolder, since two scans' commands already carry distinct
    // --seeds-out paths whenever their spots differ.
    std::string seedsDir = "main/seeds";
    if (outFile.empty()) outFile = "main/commands/commands_" + scanName + ".csv";

    // --z-all generates every hot Z line in range from the closed form and
    // feeds them into the same path --z-only uses. The hot Z lattice is
    //   chunkZ mod 97 in {48, 49}   <=>   blockZ = 1552k + 768 or 1552k + 784
    // derived from BOTH records (534 and 437 are each mod 97 == 49) and every
    // measured peak. There is nothing to anchor: --center-z is ignored, so
    // --center-z 0 works. This is strictly safer than --z-period, which misses
    // the lattice entirely if the anchor phase is wrong.
    if (zAll) {
        zOnly.clear();
        long long zLo = (long long)centerBZ - range, zHi = (long long)centerBZ + range;
        // walk k so that 1552k+768 and 1552k+784 cover [zLo, zHi]
        long long kLo = (zLo - 784) / 1552 - 1, kHi = (zHi - 768) / 1552 + 1;
        for (long long k = kLo; k <= kHi; k++) {
            for (long long off : { 768LL, 784LL }) {
                long long bz = 1552 * k + off;
                if (bz >= zLo && bz <= zHi) zOnly.push_back((int)(bz / 16));
            }
        }
        std::sort(zOnly.begin(), zOnly.end());
        zOnly.erase(std::unique(zOnly.begin(), zOnly.end()), zOnly.end());
        zPeriod = 0;   // lines are exact; no band filtering
    }

    if (!fromSeeds.empty())
        return feedback(fromSeeds, ccx, ccz, mChunks, seedFloor, bitWindow, maxBits,
                        zMin, minDev, huntFloor, reportEvery, huntExe);

    // ---------------- self-test ----------------
    // ---------------- --family-sweep ----------------
    // Hold the SPOT fixed, sweep many families, measure each. Answers the
    // question every spot-varying scan leaves open: how much do families at one
    // location actually differ, is the derived one the best available, and is a
    // record-class family measurably different from its siblings? Run it at the
    // record spot with --sweep-mark 0x70802 and the answer is checkable against
    // ground truth, because that val IS the family the 66.04 came from.
    if (familySweep) {
        buildMaskOffsets();
        int ccx2 = centerBX / 16, ccz2 = centerBZ / 16;
        uint64_t sm = sweepMask ? sweepMask : 0xFDE0FULL;
        int nb = 0; for (uint64_t m = sm; m; m &= m - 1) nb++;
        long long maxFam = (nb < 62) ? (1LL << nb) : (1LL << 62);
        long long F = std::min<long long>(sweepN, maxFam);
        int floorC = (sweepFloor > 0) ? sweepFloor : std::max(40, scoreT - 8);
        printf("=== FAMILY SWEEP  block(%d,%d)  mask=0x%llX (%d bits, %lld families exist)\n",
               centerBX, centerBZ, (unsigned long long)sm, nb, maxFam);
        printf("  testing %lld families x %lld seeds each, counting layouts >= %d chunks\n",
               F, sweepSeeds, floorC);

        // Enumerate distinct vals by scattering an index across the mask bits,
        // so every family tested is genuinely different (random vals collide).
        std::vector<int> bitPos;
        for (int b = 0; b < 48; b++) if (sm >> b & 1ULL) bitPos.push_back(b);
        std::vector<uint64_t> hVals(F);
        uint64_t markVal = sweepMark & sm;
        long long markIdx = -1;
        // Index selection. A STRIDE here is a trap: with maxFam/F = 16 every
        // sampled index is a multiple of 16, which pins the four lowest mask
        // bits to zero in every family tested - and bits 0/1 were selected in
        // 15 of 15 real derived masks, so that silently handicaps the whole
        // comparison set on the bits that matter most (it made a marked family
        // holding bit 1 look unique when its rivals simply could not hold it).
        // Exhaustive when it fits; otherwise a hashed scatter, never a stride.
        bool exhaustive = (F >= maxFam);
        for (long long f = 0; f < F; f++) {
            long long idx;
            if (exhaustive) idx = f;
            else {
                uint64_t h = splitmix64((uint64_t)f ^ 0xD1B54A32D192ED03ULL);
                idx = (long long)(h % (uint64_t)maxFam);
            }
            uint64_t v = 0;
            for (size_t b = 0; b < bitPos.size(); b++) if (idx >> b & 1LL) v |= (1ULL << bitPos[b]);
            hVals[f] = v;
            if (sweepMark && v == markVal) markIdx = f;
        }
        // guarantee the marked family is present even if the stride skipped it
        if (sweepMark && markIdx < 0 && F > 0) { hVals[F - 1] = markVal; markIdx = F - 1; }

        uint64_t* dVals; unsigned long long* dHits; double* dEff; int* dMax;
        CUDA_CHECK(cudaMalloc(&dVals, F * sizeof(uint64_t)));
        CUDA_CHECK(cudaMalloc(&dHits, F * sizeof(unsigned long long)));
        CUDA_CHECK(cudaMalloc(&dEff,  F * sizeof(double)));
        CUDA_CHECK(cudaMalloc(&dMax,  F * sizeof(int)));
        CUDA_CHECK(cudaMemcpy(dVals, hVals.data(), F * sizeof(uint64_t), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemset(dHits, 0, F * sizeof(unsigned long long)));
        CUDA_CHECK(cudaMemset(dEff,  0, F * sizeof(double)));
        CUDA_CHECK(cudaMemset(dMax,  0, F * sizeof(int)));
        auto t0 = std::chrono::steady_clock::now();
        familySweepKernel<<<(int)F, 256>>>((long long)ccx2, (long long)ccz2, seedBase ^ 0x5A17ED5EEDULL,
                                           sweepSeeds, floorC, sm, dVals, dHits, dEff, dMax);
        CUDA_CHECK(cudaGetLastError());
        std::vector<unsigned long long> hHits(F); std::vector<double> hEff(F); std::vector<int> hMax(F);
        CUDA_CHECK(cudaMemcpy(hHits.data(), dHits, F * sizeof(unsigned long long), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(hEff.data(),  dEff,  F * sizeof(double), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(hMax.data(),  dMax,  F * sizeof(int), cudaMemcpyDeviceToHost));
        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        cudaFree(dVals); cudaFree(dHits); cudaFree(dEff); cudaFree(dMax);

        struct FR { uint64_t val; unsigned long long hits; double eff; int mx; };
        std::vector<FR> fr(F);
        for (long long f = 0; f < F; f++) {
            fr[f].val = hVals[f]; fr[f].hits = hHits[f]; fr[f].mx = hMax[f];
            fr[f].eff = hHits[f] ? hEff[f] / (double)hHits[f] : 0.0;
        }
        // Rank by HITS, not max cq. Max-of-sample is an order statistic: at 400k
        // seeds/family it put 0x74802 (57.65) above the record's own 0x70802
        // (56.92), and hunting both settled it - 0x74802 capped at 64.40 while
        // 0x70802 produced 66.04. Hit count had it right (56 vs 32): it is a
        // rate estimate over the whole sample rather than one lucky draw, so it
        // is the stable measure of how often a family reaches high counts.
        std::vector<FR> byMax = fr;
        std::sort(byMax.begin(), byMax.end(), [](const FR& a, const FR& b) {
            if (a.hits != b.hits) return a.hits > b.hits;
            return a.mx > b.mx;
        });
        double sumMx = 0, sumHits = 0;
        for (long long f = 0; f < F; f++) { sumMx += fr[f].mx; sumHits += (double)fr[f].hits; }
        double meanMx = sumMx / (double)F;
        double vv = 0; for (long long f = 0; f < F; f++) vv += (fr[f].mx - meanMx) * (fr[f].mx - meanMx);
        double sdMx = std::sqrt(vv / std::max(1.0, (double)F - 1));

        printf("  swept in %.1fs (%.0fM seeds total)\n\n", secs, (double)F * sweepSeeds / 1e6);
        printf("  best cq per family: mean %.2f  sd %.2f  min %.2f  max %.2f\n",
               meanMx / 256.0, sdMx / 256.0, byMax.back().mx / 256.0, byMax.front().mx / 256.0);
        printf("  mean layouts >= %dc per family: %.0f\n\n", floorC, sumHits / (double)F);
        printf("  TOP 10 FAMILIES BY HIT RATE\n");
        printf("    %-12s %10s %8s %8s\n", "val", "hits", "best cq", "pack%");
        for (int i = 0; i < 10 && i < (int)F; i++)
            printf("    0x%-10llX %10llu %8.2f %7.1f%%\n", (unsigned long long)byMax[i].val,
                   byMax[i].hits, byMax[i].mx / 256.0, byMax[i].eff * 100.0);
        // machine-readable: the pipeline reads this to pick which family to hunt
        if (!sweepOut.empty()) {
            FILE* sf = fopen(sweepOut.c_str(), "w");
            if (sf) {
                fprintf(sf, "val,hits,best_cq,pack_pct\n");
                for (int i = 0; i < 64 && i < (int)F; i++)
                    fprintf(sf, "0x%llX,%llu,%.2f,%.1f\n", (unsigned long long)byMax[i].val,
                            byMax[i].hits, byMax[i].mx / 256.0, byMax[i].eff * 100.0);
                fclose(sf);
                printf("\n  wrote %s (top 64 by hits)\n", sweepOut.c_str());
            }
        }
        if (markIdx >= 0) {
            const FR& m = fr[markIdx];
            long long rank = 1;
            for (long long f = 0; f < F; f++)
                if (fr[f].hits > m.hits || (fr[f].hits == m.hits && fr[f].mx > m.mx)) rank++;
            printf("\n  MARKED family 0x%llX: best cq %.2f, pack %.1f%%, %llu hits\n",
                   (unsigned long long)m.val, m.mx / 256.0, m.eff * 100.0, m.hits);
            printf("    rank %lld of %lld  (z = %+.2f sd from the family mean)\n",
                   rank, F, (m.mx - meanMx) / std::max(1e-9, sdMx));
            printf("    -> %s\n", (rank <= F / 20)
                   ? "STANDS OUT: family quality is measurable, so good families can be FOUND."
                   : "indistinguishable from ordinary families at this sample size.");
        }
        return 0;
    }

    if (selfTest) {
        printf("Self-test.\n\n");
        bool ok = true;

        // [1/3] The contract. Everything else in this file is an optimisation of
        // isSlimeChunk; if this drifts, every number the tool prints is fiction.
        // This matters more than it looks: slimeFromOffset hoists posOffset out
        // of the seed loop AND peels the rejection loop, so it is NOT the
        // reference code any more -- only the reference RESULT.
        printf("[1/5] slimeFromOffset(w, posOffset(cx,cz)) == slime_core.h isSlimeChunk(w,cx,cz)\n");
        printf("      (and the cell list is the 222-cell SPAWN mask, not the 226-cell disc)\n");
        {
            long long bad = 0, checked = 0;
            for (long long j = 0; j < 2000000; j++) {
                long long w = (long long)splitmix64(0x1234ULL + (uint64_t)j);
                int cx = (int)(splitmix64((uint64_t)j * 7 + 1) % 20000) - 10000;
                int cz = (int)(splitmix64((uint64_t)j * 13 + 5) % 20000) - 10000;
                if (slimeFromOffset(w, posOffset(cx, cz)) != isSlimeChunk(w, cx, cz)) bad++;
                checked++;
            }
            printf("  %lld random (seed,chunk) pairs: %lld mismatches -> %s\n",
                   checked, bad, bad ? "MISMATCH" : "OK");
            if (bad) ok = false;
        }

        int tn = 4000;
        int tc[3][2] = { { ccx, ccz }, { 0, 0 }, { 459, 436 } };
        std::vector<int> lx, lz;
        for (int t = 0; t < 3; t++) { lx.push_back(tc[t][0]); lz.push_back(tc[t][1]); }
        std::vector<Result> r;
        runVarScan(lx, lz, seedBase, tn, r);
        printf("[2/5] variance kernel: GPU vs CPU, identical seeds\n");
        for (int t = 0; t < 3; t++) {
            double cv, cm; unsigned cx_;
            cpuVar(tc[t][0], tc[t][1], seedBase, tn, cv, cm, cx_);
            bool m = (fabs(cv - r[t].var) < 1e-9) && (cx_ == r[t].mx);
            printf("  chunk(%6d,%6d): GPU var %8.4f max %2u | CPU var %8.4f max %2u -> %s\n",
                   tc[t][0], tc[t][1], r[t].var, r[t].mx, cv, cx_, m ? "OK" : "MISMATCH");
            if (!m) ok = false;
        }
        // The early-exit tail path is the one thing v3 never had; prove it is
        // exactly equivalent to a full count for the >=T predicate, masked
        // and unmasked.
        printf("[3/5] early-exit rate kernel: must equal a full-count CPU reference\n");
        struct { int T; uint64_t mask, val; const char* what; } rt[3] = {
            { 40, 0ULL,        0ULL,        "unconstrained"    },
            { 45, 0xEFC4FULL,  0xE904EULL,  "your 14-bit mask" },
            { 45, 0x2FFECFULL, 0x2E924EULL, "18-bit mask"      },
        };
        long long rn = 200000;
        for (int t = 0; t < 3; t++) {
            unsigned long long gh = 0; unsigned gm = 0;
            oneArm(ccx, ccz, seedBase, rn, rt[t].T, rt[t].mask, rt[t].val, gh, gm);
            unsigned long long ch = cpuRate(ccx, ccz, seedBase, rn, rt[t].T, rt[t].mask, rt[t].val);
            bool m = (gh == ch);
            printf("  T>=%d %-17s: GPU %6llu | CPU %6llu -> %s\n",
                   rt[t].T, rt[t].what, gh, ch, m ? "OK" : "MISMATCH");
            if (!m) ok = false;
        }

        // [4/5] cqRateKernel: exact blocks (the weighted-sum accumulator) vs
        // slime_core.h's own validated scoreCenterBlocks/scoreCenterChunks -
        // ground truth, not this file's optimized path, so the check proves
        // the GPU probe's cq is the real number, not merely internally
        // consistent.
        printf("[4/5] cqRateKernel: exact blocks match slime_core.h scoreCenterBlocks\n");
        {
            int wt[17 * 17]; buildBlockWeights(wt);
            uint8_t disc[17 * 17]; buildIntersectMask(disc);
            struct { int floorCount; uint64_t mask, val; const char* what; } ct[3] = {
                { 20, 0ULL,       0ULL,       "unconstrained"    },
                { 20, 0xEFC4FULL, 0xE904EULL, "your 14-bit mask" },
                { 60, 0xEFC4FULL, 0xE904EULL, "14-bit mask, T=60" },
            };
            const double effBar = 0.9;   // fixed bar, just to exercise winCount too
            // t=2 (T=60, tight mask) needs more depth than rn to see any tail
            // hits at all, but not 20M worth - the CPU reference loop for this
            // case is the single biggest cost in the whole self-test (a
            // single-threaded scoreCenterChunks+scoreCenterBlocks pass per
            // seed), and an exact GPU/CPU match on ~50-60 hits is just as
            // strong a correctness proof as matching on ~600 - a real kernel
            // bug would still show up as a mismatch either way.
            long long rnCq = 2000000;
            for (int t = 0; t < 3; t++) {
                long long rnT = (t == 2) ? rnCq : rn;
                // Fixed block bar for the record counter, chosen so the check
                // has a nonzero answer to verify rather than trivially passing
                // on 0 == 0: at these floors it lands mid-distribution.
                const int recBlocksT = 16000;
                unsigned long long *dH, *dWin, *dRec; double *dSum;
                CUDA_CHECK(cudaMalloc(&dH, sizeof(unsigned long long)));
                CUDA_CHECK(cudaMalloc(&dWin, sizeof(unsigned long long)));
                CUDA_CHECK(cudaMalloc(&dRec, sizeof(unsigned long long)));
                CUDA_CHECK(cudaMalloc(&dSum, sizeof(double)));
                CUDA_CHECK(cudaMemset(dH, 0, sizeof(unsigned long long)));
                CUDA_CHECK(cudaMemset(dWin, 0, sizeof(unsigned long long)));
                CUDA_CHECK(cudaMemset(dRec, 0, sizeof(unsigned long long)));
                CUDA_CHECK(cudaMemset(dSum, 0, sizeof(double)));
                int blk = (int)std::min<long long>(8192, (rnT + 255) / 256);
                cqRateKernel<<<blk, 256>>>((long long)ccx, (long long)ccz, seedBase, rnT,
                                          ct[t].floorCount, ct[t].mask, ct[t].val, effBar, recBlocksT,
                                          dH, dSum, dWin, dRec);
                CUDA_CHECK(cudaGetLastError());
                unsigned long long gh2 = 0, gwin = 0, grec = 0; double gsum = 0;
                CUDA_CHECK(cudaMemcpy(&gh2, dH, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
                CUDA_CHECK(cudaMemcpy(&gwin, dWin, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
                CUDA_CHECK(cudaMemcpy(&grec, dRec, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
                CUDA_CHECK(cudaMemcpy(&gsum, dSum, sizeof(double), cudaMemcpyDeviceToHost));
                cudaFree(dH); cudaFree(dWin); cudaFree(dRec); cudaFree(dSum);

                // Identical seed stream, scored by the file's own validated
                // reference functions (not a re-derivation of the kernel math).
                unsigned long long ch2 = 0, cwin = 0, crec = 0; double csum = 0;
                for (long long j = 0; j < rnT; j++) {
                    uint64_t w64 = splitmix64(seedBase + (uint64_t)j);
                    w64 = (w64 & ~ct[t].mask) | ct[t].val;
                    long long seed = (long long)w64;
                    int chunks = scoreCenterChunks(disc, seed, ccx, ccz);
                    if (chunks < ct[t].floorCount) continue;
                    int blocks = scoreCenterBlocks(wt, seed, ccx, ccz);
                    double eff = (blocks / 256.0) / chunks;
                    ch2++; csum += eff;
                    if (eff >= effBar) cwin++;
                    if (blocks >= recBlocksT) crec++;
                }
                bool m2 = (gh2 == ch2) && (gwin == cwin) && (grec == crec) &&
                          (fabs(gsum - csum) < 1e-6 * std::max(1.0, csum));
                printf("  %-17s: GPU hits %6llu sumEff %10.4f win %4llu rec %4llu | "
                       "CPU hits %6llu sumEff %10.4f win %4llu rec %4llu -> %s\n",
                       ct[t].what, gh2, gsum, gwin, grec, ch2, csum, cwin, crec, m2 ? "OK" : "MISMATCH");
                if (!m2) ok = false;
            }
        }

        // [5/5] effBitsKernel: per-bit efficiency group sums (the statistic
        // --derive-eff's Welch's t-test runs on) vs a CPU reference built
        // directly from scoreCenterBlocks/scoreCenterChunks - ground truth,
        // same pattern as check 4.
        printf("[5/5] effBitsKernel: per-bit efficiency groups match CPU reference\n");
        {
            int wt[17 * 17]; buildBlockWeights(wt);
            uint8_t disc[17 * 17]; buildIntersectMask(disc);
            struct { int T; uint64_t mask, val; const char* what; } et[2] = {
                { 20, 0ULL,       0ULL,       "unconstrained"    },
                { 60, 0xEFC4FULL, 0xE904EULL, "14-bit mask, T=60" },
            };
            const int bw = 24;
            // Same tradeoff as rnCq above: enough depth to see real tail hits
            // at T=60, not so much that this dominates self-test runtime.
            long long rnEff = 2000000;
            for (int t = 0; t < 2; t++) {
                long long rnT = (t == 1) ? rnEff : rn;
                unsigned long long *dTail, *dN0, *dN1; double *dSum0, *dSum1, *dSumSq0, *dSumSq1;
                CUDA_CHECK(cudaMalloc(&dTail, sizeof(unsigned long long)));
                CUDA_CHECK(cudaMalloc(&dN0, MAX_BIT_WINDOW * sizeof(unsigned long long)));
                CUDA_CHECK(cudaMalloc(&dN1, MAX_BIT_WINDOW * sizeof(unsigned long long)));
                CUDA_CHECK(cudaMalloc(&dSum0, MAX_BIT_WINDOW * sizeof(double)));
                CUDA_CHECK(cudaMalloc(&dSum1, MAX_BIT_WINDOW * sizeof(double)));
                CUDA_CHECK(cudaMalloc(&dSumSq0, MAX_BIT_WINDOW * sizeof(double)));
                CUDA_CHECK(cudaMalloc(&dSumSq1, MAX_BIT_WINDOW * sizeof(double)));
                CUDA_CHECK(cudaMemset(dTail, 0, sizeof(unsigned long long)));
                CUDA_CHECK(cudaMemset(dN0, 0, MAX_BIT_WINDOW * sizeof(unsigned long long)));
                CUDA_CHECK(cudaMemset(dN1, 0, MAX_BIT_WINDOW * sizeof(unsigned long long)));
                CUDA_CHECK(cudaMemset(dSum0, 0, MAX_BIT_WINDOW * sizeof(double)));
                CUDA_CHECK(cudaMemset(dSum1, 0, MAX_BIT_WINDOW * sizeof(double)));
                CUDA_CHECK(cudaMemset(dSumSq0, 0, MAX_BIT_WINDOW * sizeof(double)));
                CUDA_CHECK(cudaMemset(dSumSq1, 0, MAX_BIT_WINDOW * sizeof(double)));
                int blk = (int)std::min<long long>(8192, (rnT + 255) / 256);
                effBitsKernel<<<blk, 256>>>((long long)ccx, (long long)ccz, seedBase, rnT,
                                            et[t].T, bw, et[t].mask, et[t].val,
                                            dTail, dN0, dN1, dSum0, dSum1, dSumSq0, dSumSq1);
                CUDA_CHECK(cudaGetLastError());
                std::vector<unsigned long long> gn0(MAX_BIT_WINDOW), gn1(MAX_BIT_WINDOW);
                std::vector<double> gsum0(MAX_BIT_WINDOW), gsum1(MAX_BIT_WINDOW),
                                    gsumSq0(MAX_BIT_WINDOW), gsumSq1(MAX_BIT_WINDOW);
                CUDA_CHECK(cudaMemcpy(gn0.data(), dN0, MAX_BIT_WINDOW * sizeof(unsigned long long), cudaMemcpyDeviceToHost));
                CUDA_CHECK(cudaMemcpy(gn1.data(), dN1, MAX_BIT_WINDOW * sizeof(unsigned long long), cudaMemcpyDeviceToHost));
                CUDA_CHECK(cudaMemcpy(gsum0.data(), dSum0, MAX_BIT_WINDOW * sizeof(double), cudaMemcpyDeviceToHost));
                CUDA_CHECK(cudaMemcpy(gsum1.data(), dSum1, MAX_BIT_WINDOW * sizeof(double), cudaMemcpyDeviceToHost));
                CUDA_CHECK(cudaMemcpy(gsumSq0.data(), dSumSq0, MAX_BIT_WINDOW * sizeof(double), cudaMemcpyDeviceToHost));
                CUDA_CHECK(cudaMemcpy(gsumSq1.data(), dSumSq1, MAX_BIT_WINDOW * sizeof(double), cudaMemcpyDeviceToHost));
                cudaFree(dTail); cudaFree(dN0); cudaFree(dN1);
                cudaFree(dSum0); cudaFree(dSum1); cudaFree(dSumSq0); cudaFree(dSumSq1);

                std::vector<unsigned long long> cn0(bw, 0), cn1(bw, 0);
                std::vector<double> csum0(bw, 0), csum1(bw, 0), csumSq0(bw, 0), csumSq1(bw, 0);
                for (long long j = 0; j < rnT; j++) {
                    uint64_t w64 = splitmix64(seedBase + (uint64_t)j);
                    w64 = (w64 & ~et[t].mask) | et[t].val;
                    long long seed = (long long)w64;
                    int chunks = scoreCenterChunks(disc, seed, ccx, ccz);
                    if (chunks < et[t].T) continue;
                    int blocks = scoreCenterBlocks(wt, seed, ccx, ccz);
                    double eff = (blocks / 256.0) / chunks;
                    for (int b = 0; b < bw; b++) {
                        if ((w64 >> b) & 1ULL) { cn1[b]++; csum1[b] += eff; csumSq1[b] += eff * eff; }
                        else                    { cn0[b]++; csum0[b] += eff; csumSq0[b] += eff * eff; }
                    }
                }
                bool m3 = true;
                for (int b = 0; b < bw; b++) {
                    if (gn0[b] != cn0[b] || gn1[b] != cn1[b]) { m3 = false; break; }
                    double tol0 = 1e-6 * std::max(1.0, fabs(csum0[b]));
                    double tol1 = 1e-6 * std::max(1.0, fabs(csum1[b]));
                    if (fabs(gsum0[b] - csum0[b]) > tol0 || fabs(gsum1[b] - csum1[b]) > tol1) { m3 = false; break; }
                    double tolq0 = 1e-6 * std::max(1.0, fabs(csumSq0[b]));
                    double tolq1 = 1e-6 * std::max(1.0, fabs(csumSq1[b]));
                    if (fabs(gsumSq0[b] - csumSq0[b]) > tolq0 || fabs(gsumSq1[b] - csumSq1[b]) > tolq1) { m3 = false; break; }
                }
                printf("  %-17s: %d bits checked -> %s\n", et[t].what, bw, m3 ? "OK" : "MISMATCH");
                if (!m3) ok = false;
            }
        }

        printf("\n%s\n", ok ? "SELF TEST PASSED." : "SELF TEST FAILED.");
        return ok ? 0 : 1;
    }

    // ---------------- score-one ----------------
    if (scoreOne) {
        std::vector<int> lx(1, ccx), lz(1, ccz); std::vector<Result> r;
        runVarScan(lx, lz, seedBase, scanSeeds, r);
        printf("chunk (%d,%d) = block (%d,%d)\n", ccx, ccz, ccx * 16, ccz * 16);
        printf("  variance %.3f   mean %.3f   max-count over %d seeds: %u\n",
               r[0].var, r[0].mean, scanSeeds, r[0].mx);
        printf("  (reference: independent-binomial baseline 20.34; your (2000,8544) ~28.9;\n"
               "   best seen ~33. NOTE: variance is a GATE, not a ranker -- use --check\n"
               "   for the number that actually predicts hits/sec.)\n");
        return 0;
    }

    // ---------------- check (stage 2 on one spot) ----------------
    if (doCheck) {
        printf("=== CHECK  chunk (%d,%d) = block (%d,%d) ===\n", ccx, ccz, ccx * 16, ccz * 16);
        printf("Escalating bootstrap: T %d -> %d step %d, %lld seeds/round, low %d bits eligible,\n"
               "  fix a bit iff |freq-0.5| >= %.3f AND |z| >= %.1f, cap %d bits.\n\n",
               tStart, deepT, tStep, bigN, bitWindow, minDev, zMin, maxBits);
        auto t0 = std::chrono::steady_clock::now();
        Derivation D = derive(ccx, ccz, seedBase, bigN, bigNMin, tStart, tStep, deepT, tFloor,
                              bitWindow, maxBits, zMin, minDev, minTail, true);
        if (reachCheck) reachGuard(ccx, ccz, seedBase, D, reachN, deepT, bitWindow,
                                   reachDev, minTail, true);
        if (deriveEff) {
            printf("\n  --derive-eff: testing remaining free bits against packing efficiency\n");
            bool added = deriveEffBits(ccx, ccz, seedBase, D, bigN, bigNMin, deepT,
                                       bitWindow, maxBits, minEffDev, effZMin, true);
            if (added && reachCheck)
                reachGuard(ccx, ccz, seedBase, D, reachN, deepT, bitWindow, reachDev, minTail, true);
        }
        printf("\n  stop: %s\n", D.stopReason);
        printf("  mask=0x%llX  val=0x%llX  (%d bits, learned up to T>=%d)\n",
               (unsigned long long)D.mask, (unsigned long long)D.val, D.bitsFixed, D.topT);
        printf("  reach: 2^%d = %.3g unique layouts still available\n",
               48 - D.bitsFixed, pow(2.0, 48 - D.bitsFixed));

        Measure M = measure(ccx, ccz, seedBase, D, measureN, measureNMin, deepT, minLift, minSep, minHits, minMax);
        if (M.verdict == 2) scoreAt(ccx, ccz, seedBase, D, scoreT, scoreCap, scoreMin, minScoreHits, M);
        if (M.verdict == 2) efficiencyProbe(ccx, ccz, seedBase, D, scoreT, effN, recordCq, recMargin, M);
        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        // NOTE: this 3-arm test is measured at --deep-t (measure() is called
        // with deepT, not scoreT, above) - printed here because it is the
        // control/dud test, not because it is the scoreT measurement. The
        // scoreT-specific numbers are SCORE below and the packing/pWin lines,
        // which come from scoreAt()/efficiencyProbe() at the real scoreT.
        printf("\n  Held-out measurement at count >= %d (--deep-t), %lld seeds/arm max:\n", deepT, measureN);
        printf("    baseline (no mask)      : %10llu hits  rate %.4e  max %u\n", M.baseHits,  M.baseRate,  M.baseMax);
        printf("    treatment (mask,val)    : %10llu hits  rate %.4e  max %u\n", M.treatHits, M.treatRate, M.treatMax);
        printf("    control  (mask,~val)    : %10llu hits  rate %.4e  max %u\n", M.ctrlHits,  M.ctrlRate,  M.ctrlMax);
        if (M.effSamples)
            printf("    packing at >=%d chunks   : %.1f%% mean  ->  cqCeil %.1f cq  (%llu samples)\n",
                   scoreT - 4, M.effMean * 100.0, M.cqCeil, M.effSamples);
            if (M.effSamples < 100)
                printf("    P(beats %.2f cq at %dc)  : %.1f%% on only %llu samples - NOT CONCLUSIVE.\n"
                       "                               (a true 5%% rate shows 0 of 23 about a third of the time)\n",
                       recordCq, scoreT, M.pWin * 100.0, M.effSamples);
            else
                printf("    P(beats %.2f cq at %dc)  : %.1f%%  (%llu samples)\n",
                       recordCq, scoreT, M.pWin * 100.0, M.effSamples);
        // The direct metric: measured chunk-aligned, bar lowered by --rec-margin
        // so it is comparable to a block-refined record (see efficiencyProbe).
        printf("    pRec (chunk-aligned >= %.2f cq): %.3e  (%llu of %lld)\n",
               recordCq - recMargin, M.pRec, M.recHits, M.recN);
        if (M.pRec > 0)
            printf("      -> ~%.3g seeds per record-class hit; slime_refine decides the rest.\n",
                   1.0 / M.pRec);
        printf("    lift (treat/base)    = %s%8.2fx   [keep if >= %.1f]\n",
               M.baseHits ? " " : ">", M.lift, minLift);
        printf("    sep  (treat/control) = %s%8.2fx   [keep if >= %.1f]  <-- the real dud test\n",
               M.ctrlZero ? ">" : " ", M.sep, minSep);
        if (M.ctrlZero)
            printf("      (control scored 0 hits, so sep is only bounded below: it is\n"
                   "       score x %lld, not an independently measured effect size.)\n", M.N);
        // M.treatRate is the --deep-t 3-arm rate (the control/dud test above,
        // relabeled correctly now); the actual --score-t rate is M.scoreRate
        // from scoreAt(), which is also what --scan sorts on. Printing
        // treatRate here under a scoreT label was the same pre-existing
        // deepT/scoreT mislabel as the "Held-out measurement" line above.
        if (M.scoreN > 0)
            printf("\n  SCORE (hits per seed at T>=%d) = %.4e\n", scoreT, M.scoreRate);
        else
            printf("\n  SCORE (hits per seed at T>=%d) = not run (cut before the deep count)\n", scoreT);
        printf("  (%.1fs)\n\n", secs);
        if (M.verdict == 2) {
            printf("HUNT:\n%s\n",
                   huntCommand(ccx * 16, ccz * 16, D.mask, D.val, mChunks, huntFloor,
                               reportEvery, huntExe.c_str(), "main/seeds").c_str());
            printf("\nTHEN SCORE (after the hunt has collected some seeds):\n"
                   "slime_refine.exe --seeds main\\seeds\\manual\\%d_%d.csv --center-x %d --center-z %d --radius 6\n",
                   ccx * 16, ccz * 16, ccx * 16, ccz * 16);
        }
        else if (M.verdict == 1)
            printf("(too few hits to call it -- raise --measure-n or lower --deep-t)\n");
        else
            printf("(no real constraint here -- not worth a hunt)\n");
        return 0;
    }

    // ---------------- build scan grid (stages 1 / bench) ----------------
    std::vector<int> lx, lz;
    // X extent in CHUNKS. --range-x is given in blocks, so convert; unset keeps
    // --range's historical chunk semantics untouched.
    int rangeX = (rangeXBlocks >= 0) ? (rangeXBlocks / 16) : range;
    if (doScan || bench) {
        if (!zOnly.empty()) {
            // --z-only / --z-all mode. Ignore --center-z/--z-period/--z-band.
            // Sweep X across --range (or --range-x) for each Z line.
            printf("%s: sweeping X in [%d, %d] chunks = [%d, %d] blocks on %zu Z line(s)",
                   zAll ? "--z-all ACTIVE (hot lattice from closed form)" : "--z-only ACTIVE",
                   ccx - rangeX, ccx + rangeX,
                   (ccx - rangeX) * 16, (ccx + rangeX) * 16, zOnly.size());
            if (zOnly.size() <= 12) {
                printf(": ");
                for (int z : zOnly) printf("%d ", z * 16);
                printf("(block Z)");
            }
            printf("\n");
            for (int cz : zOnly) {
                for (int dx = -rangeX; dx <= rangeX; dx += stepX) { lx.push_back(ccx + dx); lz.push_back(cz); }
            }
        } else {
            for (int dz = -range; dz <= range; dz += stepZ) {
                if (zPeriod > 0) {
                    int m = ((dz % zPeriod) + zPeriod) % zPeriod;
                    int d = std::min(m, zPeriod - m);
                    if (d > zBand) continue;
                }
                for (int dx = -rangeX; dx <= rangeX; dx += stepX) { lx.push_back(ccx + dx); lz.push_back(ccz + dz); }
            }
        }
    }

    if (bench) {
        printf("=== PASS 1 (varKernel -- this is the search) ===\n");
        std::vector<Result> r;
        auto t0 = std::chrono::steady_clock::now();
        runVarScan(lx, lz, seedBase, scanSeeds, r);
        CUDA_CHECK(cudaDeviceSynchronize());
        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        double evals = (double)lx.size() * scanSeeds * (double)g_dx.size();
        double locPerSec = lx.size() / secs;
        printf("  %zu locations x %d seeds x %zu cells in %.3fs\n", lx.size(), scanSeeds, g_dx.size(), secs);
        printf("  %.0f locations/s   %.2f G cell-evals/s\n", locPerSec, evals / secs / 1e9);
        if (lx.size() < 20000)
            printf("  NOTE: %zu locations is a small grid and will UNDERSTATE the rate\n"
                   "  (not enough blocks to fill the SMs). Raise --range for a true figure.\n", lx.size());

        double secPerLoc = 0;
        if (benchLocs > 0) {
            printf("\n=== PASS 2 (derive + 3 arms) ===\n");
            int nb = std::min((size_t)benchLocs, lx.size());
            auto t1 = std::chrono::steady_clock::now();
            for (int i = 0; i < nb; i++) {
                Derivation D = derive(lx[i], lz[i], seedBase, bigN, bigNMin, tStart, tStep, deepT, tFloor,
                                      bitWindow, maxBits, zMin, minDev, minTail, false);
                if (D.bitsFixed) measure(lx[i], lz[i], seedBase, D, measureN, measureNMin,
                                         deepT, minLift, minSep, minHits, minMax);
            }
            double s2 = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();
            secPerLoc = s2 / nb;
            printf("  %d locations in %.2fs -> %.2f s/location\n", nb, s2, secPerLoc);
            printf("  (varies a lot: a live spot resolves fast, a sparse one escalates)\n");
        }

        printf("\n=== PROJECTED FULL RUN (--z-period 97 --z-band 1, --gate-top %d) ===\n", gateTop);
        printf("  %-8s %12s %10s %10s %10s\n", "range", "locations", "pass1", "pass2", "total");
        int rr[5] = { 500, 1000, 2000, 5000, 10000 };
        for (int k = 0; k < 5; k++) {
            long long nz = 0;
            for (int dz = -rr[k]; dz <= rr[k]; dz++) {
                int mm = ((dz % 97) + 97) % 97;
                if (std::min(mm, 97 - mm) <= 1) nz++;
            }
            double nloc = (double)(2 * rr[k] + 1) * (double)nz;
            double p1 = nloc / locPerSec, p2 = secPerLoc * gateTop;
            printf("  %-8d %12.0f %9.0fs %9.0fs %9.0fs\n", rr[k], nloc, p1, p2, p1 + p2);
        }
        printf("\n  pass 1 grows with range^2; pass 2 is flat at --gate-top. Below the\n"
               "  crossover, optimising varKernel buys you nothing.\n");
        return 0;
    }

    // ---------------- FUSED SCAN: gate -> deep-tail rank -> commands ----------
    if (doScan) {
        if (lx.empty()) { fprintf(stderr, "no locations in grid\n"); return 1; }

        printf("=== PASS 1/2: variance gate ===\n");
        printf("%zu locations around chunk (%d,%d), +-%d, step x=%d z=%d",
               lx.size(), ccx, ccz, range, stepX, stepZ);
        if (zPeriod > 0) printf(", Z lattice %d band +-%d (phase anchored to --center-z)", zPeriod, zBand);
        printf("\n%d seeds/location. Gate only -- pass 2 does the ranking.\n", scanSeeds);

        std::vector<Result> res;
        auto t0 = std::chrono::steady_clock::now();
        runVarScan(lx, lz, seedBase, scanSeeds, res);
        CUDA_CHECK(cudaDeviceSynchronize());
        double gsecs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        std::sort(res.begin(), res.end(), [](const Result& a_, const Result& b_) { return a_.var > b_.var; });

        // PASS 1b -- CASCADE. Taking the top-K of millions of noisy variance
        // estimates is a max-selection: at --seeds 4000 the sampling SE on the
        // variance is ~0.64, so the head of a 12M-row list is substantially
        // lucky noise rather than real structure. (This is the winner's curse
        // that made v3's top-10 look special: it scanned 4M locations at 20k
        // seeds, SE ~0.29, and then reported the extreme order statistic.)
        // Re-scoring only the shortlist, on an INDEPENDENT seed stream, is an
        // unbiased second opinion -- and it is still far cheaper than scanning
        // everything at high --seeds, because the shortlist is ~600x smaller.
        if (refineTop > 0 && refineSeeds > scanSeeds && (int)res.size() > refineTop) {
            std::vector<int> rx, rz;
            for (int i = 0; i < refineTop; i++) { rx.push_back(res[i].cx); rz.push_back(res[i].cz); }
            printf("\n=== PASS 1b: re-scoring top %d on fresh seeds (%d each) ===\n", refineTop, refineSeeds);
            auto t1b = std::chrono::steady_clock::now();
            std::vector<Result> ref;
            runVarScan(rx, rz, seedBase ^ 0xD1B54A32D192ED03ULL, refineSeeds, ref);
            CUDA_CHECK(cudaDeviceSynchronize());
            double rsecs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1b).count();
            double shrink = 0; int moved = 0;
            for (size_t i = 0; i < ref.size(); i++) { shrink += res[i].var - ref[i].var; if (ref[i].var < varMin) moved++; }
            printf("done in %.1fs. mean variance shrank %.3f on re-measurement (that gap was the\n"
                   "  selection bias); %d of %d no longer clear --var-min %.2f.\n",
                   rsecs, shrink / (double)ref.size(), moved, refineTop, varMin);
            res = ref;
            std::sort(res.begin(), res.end(), [](const Result& a_, const Result& b_) { return a_.var > b_.var; });
        }

        double centerVar = 0; int crank = 0;
        for (size_t i = 0; i < res.size(); i++)
            if (res[i].cx == ccx && res[i].cz == ccz) { crank = (int)i + 1; centerVar = res[i].var; }
        printf("\n%zu locations in %.1fs (%.0f/s). best var %.3f  median %.3f\n",
               res.size(), gsecs, res.size() / gsecs, res.front().var, res[res.size() / 2].var);
        if (crank) printf("your center chunk(%d,%d): var %.3f, rank %d\n", ccx, ccz, centerVar, crank);
        if (res.front().var < 26.0)
            printf("\nWARNING: best variance %.3f is close to the independent-binomial\n"
                   "  baseline of 20.34 -- nothing here has real cell correlation. If you\n"
                   "  passed --z-period, the lattice phase is probably wrong for this X.\n"
                   "  Re-run without --z-period.\n", res.front().var);

        // PASS 1c -- CLUSTER SUPPRESSION. X is quasi-periodic at ~32.7 chunks
        // (autocorrelation 0.968 at lag 33), so x and x+-1..16 are near-duplicate
        // measurements of the same underlying area. Without this, one strong area
        // burns 5-8 of the gate-top slots on copies of itself: a real run's top
        // 100 was ~15 distinct areas, and the 65.71 cq record spot - variance
        // 31.9, HIGHER than the control - ranked ~1500th overall yet first in its
        // own cluster, so it was cut without ever being measured. Rank clusters,
        // not cells: keep only ONE row within +-16 chunks X / +-2 chunks Z.
        //
        // WHICH rows survive a cluster matters as much as the clustering:
        // keeping only the variance-best member loses record spots a second
        // way. Measured on the record's own neighbourhood (202 locations around
        // chunk 230,437): the record spot ranks 22nd by variance, so a
        // variance-luckier neighbour on the next z-line took the cluster's only
        // slot, measured a mediocre cqCeil, and the whole region read as
        // ordinary. Variance within a cluster does not track packing - and a
        // cheap unmasked packing probe was tried and failed the same acceptance
        // test (at reachable floors, mid-tail packing is ~87-89% everywhere;
        // the record spot's edge exists only in its masked family's high-count
        // tail, which only pass 2's real derivation can see). So: no guessing.
        // Each cluster sends its top clusterK members BY VARIANCE to pass 2,
        // and pass 2's measured cqCeil/pWin - the statistic that actually
        // separates record families - picks between them.
        {
            const int clusterK = 2;
            struct Cluster { Result rep; std::vector<Result> keep; };
            std::vector<Cluster> clusters;
            for (size_t i = 0; i < res.size(); i++) {
                bool placed = false;
                for (size_t j = 0; j < clusters.size(); j++)
                    if (std::abs(res[i].cx - clusters[j].rep.cx) <= 16 &&
                        std::abs(res[i].cz - clusters[j].rep.cz) <= 2) {
                        // res is variance-sorted, so the first K placed are the
                        // cluster's K strongest. Prefer members on a DIFFERENT
                        // z-line from the rep: same-line x-neighbours are the
                        // near-duplicates suppression exists to kill, while the
                        // record spot sat one z-line off its cluster's rep.
                        if ((int)clusters[j].keep.size() < clusterK &&
                            res[i].cz != clusters[j].rep.cz)
                            clusters[j].keep.push_back(res[i]);
                        placed = true; break;
                    }
                if (!placed) {
                    Cluster c; c.rep = res[i];
                    clusters.push_back(c);
                }
            }
            std::vector<Result> reps;
            for (size_t j = 0; j < clusters.size(); j++) {
                reps.push_back(clusters[j].rep);
                for (size_t m = 0; m < clusters[j].keep.size(); m++)
                    reps.push_back(clusters[j].keep[m]);
            }
            printf("cluster suppression: %zu rows -> %zu distinct areas, %zu rows kept "
                   "(top %d per cluster, cross-z preferred; pass 2 judges between them)\n",
                   res.size(), clusters.size(), reps.size(), 1 + clusterK);
            res.swap(reps);
        }

        // Survivors: forced --include controls first, then the gate's top rows.
        std::vector<std::pair<int,int> > cand;
        for (size_t i = 0; i < includes.size(); i++) cand.push_back(includes[i]);
        for (size_t i = 0; i < res.size() && (int)cand.size() < gateTop + (int)includes.size(); i++) {
            if (res[i].var < varMin) break;              // sorted, so nothing below clears it either
            int bx = res[i].cx * 16, bz = res[i].cz * 16;
            bool dup = false;
            for (size_t j = 0; j < cand.size(); j++) {
                // X is quasi-periodic at ~33 chunks: adjacent-x candidates are the
                // same structure sampled twice (the old top-100 held 7344, 7360 AND
                // 7376 at z=6976). Suppress anything within minSep chunks of an
                // accepted survivor so the budget buys DISTINCT spots. The best
                // variant of each cluster survives because the list is sorted.
                if (std::abs(cand[j].first - bx) <= minSep * 16 &&
                    std::abs(cand[j].second - bz) <= minSep * 16) { dup = true; break; }
            }
            if (!dup) cand.push_back(std::make_pair(bx, bz));
        }
        if (cand.empty()) { fprintf(stderr, "nothing cleared --var-min %.2f\n", varMin); return 1; }

        // --rank-by like: measure every reference spot FIRST, under this run's
        // own parameters (not stale README numbers), so candidates are judged
        // against a freshly-measured feature vector.
        std::vector<RefProfile> refProfiles;
        if (rankBy == "like") {
            printf("\n=== REFERENCE SPOTS (--rank-by like) ===\n");
            for (size_t i = 0; i < likeSpots.size(); i++) {
                RefProfile rp = measureReference(likeSpots[i].first, likeSpots[i].second, seedBase,
                                                 bigN, bigNMin, tStart, tStep, deepT, tFloor, bitWindow, maxBits,
                                                 zMin, minDev, minTail, measureN, measureNMin, minLift, minSep,
                                                 minHits, minMax, reachCheck, reachN, reachDev,
                                                 scoreT, effN, recordCq, recMargin, scoreCap, scoreMin, minScoreHits);
                printf("  block(%8d,%8d)  %2d bits  cqCeil %5.1f  pWin %5.1f%%  winners %6.2f\n",
                       rp.bx, rp.bz, rp.D.bitsFixed, rp.M.cqCeil, rp.M.pWin * 100.0, rp.M.winners);
                refProfiles.push_back(rp);
            }
            if (refProfiles.empty())
                fprintf(stderr, "  (no --like spots and the defaults were somehow empty - "
                                "falling back to plain --score ranking)\n");
        }

        printf("\n=== PASS 2/2: deep-tail ranking, %zu survivors ===\n", cand.size());
        printf("per location: escalating bootstrap (T %d->%d step %d, up to %lld seeds/round),\n"
               "then 3 held-out arms at count >= %d (--score-t) (baseline / mask / INVERTED mask).\n"
               "score = p(count >= %d | mask) = hits per seed = hits per second.\n\n",
               tStart, deepT, tStep, bigN, scoreT, scoreT);

        struct Row { int bx, bz; Derivation D; Measure M; };
        std::vector<Row> rows;
        auto tAll = std::chrono::steady_clock::now();
        for (size_t i = 0; i < cand.size(); i++) {
            Row R; R.bx = cand[i].first; R.bz = cand[i].second;
            int rcx = R.bx / 16, rcz = R.bz / 16;
            auto t1 = std::chrono::steady_clock::now();
            R.D = derive(rcx, rcz, seedBase, bigN, bigNMin, tStart, tStep, deepT, tFloor,
                         bitWindow, maxBits, zMin, minDev, minTail, false);
            // EARLY EXIT: a spot that derived < 10 bits has no usable constraint.
            // Skip the 3-arm measure + reach guard + scoreAt entirely â€” those cost
            // 1-5s each and the answer is always "drop". This is the main speedup
            // for the ~70% of candidates that are structural duds.
            if (R.D.bitsFixed < 10) {
                double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();
                printf("  [%3zu/%3zu] block(%8d,%8d)  %2d bits       (early dud, skipped 3-arm)  drop (%.1fs, cum %.0fs)\n",
                       i + 1, cand.size(), R.bx, R.bz, R.D.bitsFixed, secs,
                       std::chrono::duration<double>(std::chrono::steady_clock::now() - tAll).count());
                fflush(stdout);
                fflush(stdout);
                rows.push_back(R);
                continue;
            }
            // EARLY EXIT 2: 20 bits derived but the deepest rung's observed max
            // was far below scoreT. The 3-arm measure at deepT will produce hits
            // but the scoreAt stage will fail (max + margin < scoreT), so we'd
            // burn 1-2s on 3 arms to discover the same thing. Check: if the last
            // round's tail was sampled at deepT, its max is a useful signal.
            // If max < scoreT - 4, this spot cannot plausibly reach scoreT.
            if (R.D.bitsFixed >= 10 && R.D.topT >= deepT) {
                // Find the max count observed during derivation's last sampling at deepT
                unsigned long long lastTail = 0;
                for (auto& rd : R.D.rounds) if (rd.T >= deepT) lastTail = std::max(lastTail, rd.tail);
                // If derivation found bits at deepT but its own sampling never saw
                // anything near scoreT, measure() won't either. Skip.
                // (lastTail > 0 means derive DID sample at deepT, so this is safe)
            }
            // bitsFixed == 0 is verdict 0 by definition -- do not pay for 3 arms
            // to discover that.
            // The 3-arm test lives at --deep-t. Running it at --score-t was a bug:
            // baseline and control are structurally 0 up there, treatment cannot
            // reach --min-hits, so every spot failed for a reason that had nothing
            // to do with the spot.
            if (R.D.bitsFixed) R.M = measure(rcx, rcz, seedBase, R.D, measureN, measureNMin,
                                             deepT, minLift, minSep, minHits, minMax);
            // Guard AFTER the verdict, not before. A spot we are dropping does not
            // need its bits audited, and dropped spots are exactly the ones where
            // the guard is slowest (thin tails -> long escalation). Then re-measure,
            // because releasing bits changes the mask and therefore the score.
            if (reachCheck && R.M.verdict == 2) {
                reachGuard(rcx, rcz, seedBase, R.D, reachN, deepT, bitWindow, reachDev, minTail, false);
                if (R.D.released)
                    R.M = measure(rcx, rcz, seedBase, R.D, measureN, measureNMin,
                                  deepT, minLift, minSep, minHits, minMax);
            }
            // --derive-eff only runs on spots that already survived the control
            // test - same cost-gating logic as everything below it. Any bit it
            // fixes still has to hold under reachGuard, same as a ladder bit.
            if (deriveEff && R.M.verdict == 2) {
                bool added = deriveEffBits(rcx, rcz, seedBase, R.D, bigN, bigNMin, deepT,
                                           bitWindow, maxBits, minEffDev, effZMin, false);
                if (added) {
                    if (reachCheck)
                        reachGuard(rcx, rcz, seedBase, R.D, reachN, deepT, bitWindow, reachDev, minTail, false);
                    R.M = measure(rcx, rcz, seedBase, R.D, measureN, measureNMin,
                                  deepT, minLift, minSep, minHits, minMax);
                }
            }
            // ORDER MATTERS. The efficiency probe is CHEAP (12M CPU seeds, sub-
            // second) and it is the variable that actually decides a winner, so it
            // runs FIRST and gates everything expensive behind it. Previously the
            // deep count (scoreAt) ran first and escalated to --score-n on ceiling
            // spots - 42s on a spot the efficiency filter then cut anyway.
            if (R.M.verdict == 2) {
                // (a) cheap max prefilter: if a fixed 32M sample never got near
                //     scoreT, nothing downstream will. One compare.
                // BIT-AWARE. This filter compares a max from a FIXED 32M sample
                // against scoreT, and it was calibrated on 20-bit masks where real
                // contenders show max 69-71. Every bit removed halves the hit rate,
                // and the tail falls ~2.6x per count, so the observed max drops
                // log(2)/log(2.6) = 0.73 counts per missing bit. At 14 bits a
                // genuine contender shows ~66, and a fixed bar of 68 deletes the
                // entire field - which is exactly what happened on the first
                // --max-bits 14 run: zero survivors, no output at all.
                int bitSlack = (int)(0.73 * (20 - R.D.bitsFixed) + 0.5);
                if (bitSlack < 0) bitSlack = 0;
                if ((int)R.M.treatMax + scoreMaxMargin + bitSlack < scoreT) R.M.verdict = 1;
            }
            // --rank-by win RANKS on cqCeil/pWin, so they have to be measured
            // even for spots the verdict gates knock down - otherwise the key is
            // 0 everywhere and the order is arbitrary. That is not hypothetical:
            // at --score-t 70 the max-prefilter above downgrades nearly the whole
            // field to verdict 1 (a 70-chunk draw is rare in a fixed 8M sample),
            // so a verdict-gated probe left all 20 emitted candidates reading
            // winRate 0 / cqCeil 0. Same reasoning --rank-by like already uses:
            // a ranking mode cannot be gated on the thresholds it exists to rank
            // BELOW. The probe is sub-second; the gates below still apply.
            if (R.M.verdict == 2 || rankBy == "win") {
                // (b) efficiency ceiling. Sub-second. Kills low-packing spots
                //     (the 88% duds) before they can cost a 40s count escalation.
                efficiencyProbe(rcx, rcz, seedBase, R.D, scoreT, effN, recordCq, recMargin, R.M);
                R.M.wouldFailEff  = (R.M.cqCeil > 0 && R.M.cqCeil < effTarget);
                R.M.wouldFailPWin = (R.M.effSamples && R.M.pWin < minPWin);
                // --rank-by like: these are exactly the MINIMUM gates that can
                // silently cut a spot which is genuinely close to a known
                // record but a hair under an independent threshold. Leave them
                // informational (wouldFail* above) instead of dropping, and let
                // the similarity ranking below sort it in relation to the
                // references instead. The structural/statistical tests (the
                // bit-count dud check, the 3-arm control test, and the max
                // prefilter just above) still apply either way.
                if (rankBy != "like") {
                    if (R.M.wouldFailEff)  R.M.verdict = 1;
                    if (R.M.wouldFailPWin) R.M.verdict = 1;
                }
            }
            // Same argument as (b): winRate = scoreRate x pWin, so --rank-by win
            // needs scoreRate measured on the spots the gates knocked down too.
            if (R.M.verdict == 2 || rankBy == "win") {
                // (c) ONLY genuine contenders pay for the deep count now.
                scoreAt(rcx, rcz, seedBase, R.D, scoreT, scoreCap, scoreMin, minScoreHits, R.M);
                if (R.M.verdict == 2 && R.M.scoreHits < minScoreHits) R.M.verdict = 1;
                // how many record-beaters the family actually contains
                R.M.winners = std::pow(2.0, 48.0 - R.D.bitsFixed) * R.M.scoreRate * R.M.pWin;
                R.M.wouldFailWinners = (R.M.winners < minWinners);
                if (rankBy != "like" && rankBy != "win" && R.M.wouldFailWinners) R.M.verdict = 1;
                // --rank-by like: distance to the nearest reference spot's
                // measured profile, now that cqCeil/pWin/winners are all in.
                if (rankBy == "like" && !refProfiles.empty()) {
                    double best = 1e18;
                    for (size_t ri = 0; ri < refProfiles.size(); ri++)
                        best = std::min(best, likeDistance(R.M, refProfiles[ri].M));
                    R.M.likeDist = best;
                }
            }
            double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();
            char sepbuf[32];
            // When the control arm scores 0 the ratio is only bounded below by
            // the sample size -- printing a bare "47000x" invites reading it as
            // a measured effect when it is just score x measure-n. Say so.
            if (R.M.ctrlZero) snprintf(sepbuf, sizeof(sepbuf), ">%.0fx", R.M.sep);
            else              snprintf(sepbuf, sizeof(sepbuf), "%.0fx", R.M.sep);
            char bitbuf[24];
            if (R.D.released) snprintf(bitbuf, sizeof(bitbuf), "%2d bits (-%d)", R.D.bitsFixed, R.D.released);
            else              snprintf(bitbuf, sizeof(bitbuf), "%2d bits     ", R.D.bitsFixed);
            char ratebuf[24];
            // scoreN == 0 means the deep count never ran (cut by an earlier, cheaper
            // filter). Printing 0.00e+00 for that claims a measurement that was not
            // taken - it says "this spot makes no 68s" when the truth is "we did not
            // look". Say so.
            if (R.M.scoreN == 0) snprintf(ratebuf, sizeof(ratebuf), "  not run");
            else                 snprintf(ratebuf, sizeof(ratebuf), "%.2e", R.M.scoreRate);
            // --rank-by like: show the distance and which default gate(s) this
            // row would have failed under the normal scheme - visibility for
            // the near-record spots that used to vanish silently.
            char likebuf[64] = "";
            if (rankBy == "like" && !refProfiles.empty()) {
                char failbuf[32] = "";
                if (R.M.wouldFailEff)     strcat(failbuf, "eff,");
                if (R.M.wouldFailPWin)    strcat(failbuf, "pwin,");
                if (R.M.wouldFailWinners) strcat(failbuf, "winners,");
                size_t fl = strlen(failbuf);
                if (fl) failbuf[fl - 1] = 0;   // trim trailing comma
                snprintf(likebuf, sizeof(likebuf), "  like-dist %6.3f%s%s",
                         R.M.likeDist, fl ? "  would-fail: " : "", fl ? failbuf : "");
            }
            printf("  [%3zu/%3zu] block(%8d,%8d)  %s  p>=%d %s  eff %4.1f%% pWin %5.1f%% win %6.2f  max %2u  %s%s (%.1fs, cum %.0fs)\n",
                   i + 1, cand.size(), R.bx, R.bz, bitbuf, scoreT, ratebuf,
                   R.M.effMean * 100.0, R.M.pWin * 100.0, R.M.winners, R.M.treatMax,
                   R.M.verdict == 2 ? "keep" : "drop", likebuf, secs,
                   std::chrono::duration<double>(std::chrono::steady_clock::now() - tAll).count());
            fflush(stdout);
            fflush(stdout);
            rows.push_back(R);
        }
        double allSecs = std::chrono::duration<double>(std::chrono::steady_clock::now() - tAll).count();

        // Sort by --rank-by. score (rate at >=T) is the default. hits
        // rewards spots that produced MANY distinct 68+ seeds even at lower
        // rate. combined multiplies score by log(1+hits) so both signals count.
        std::sort(rows.begin(), rows.end(), [&](const Row& x, const Row& y) {
            if (x.M.verdict != y.M.verdict) return x.M.verdict > y.M.verdict;
            // --rank-by like: ascending distance to the nearest reference spot.
            // Checked before rankEff/rankBy so it wins even without --no-rank-eff.
            if (rankBy == "like") return x.M.likeDist < y.M.likeDist;
            // --rank-by win: expected record-beaters PER SEED SAMPLED,
            //     winRate = p(count>=scoreT) x pWin
            // Use this when the goal is "find a new record in the hunt time I
            // actually have", which is not the same question `winners` answers.
            // winners = 2^(48-bits) x winRate counts how many record-beaters
            // EXIST in the family, so it is dominated by the 2^(48-bits) term -
            // that swings ~128x on mask tightness alone, which buries the two
            // terms that measure spot QUALITY. Ranking on it therefore prefers
            // a loose mediocre family over a tight excellent one, purely for
            // being bigger. winRate drops the family-size factor entirely, so
            // it is the rate a hunt actually converts seeds into winners:
            // expected time to a record = 1 / (winRate x seeds_per_sec).
            // Existence is still enforced, just as a FILTER not a ranking key -
            // --min-winners already drops families that contain no winner at
            // all, which is the only thing the family-size term needs to do.
            // Ties (both zero, common when pWin is unmeasurably small) fall
            // through to winners, then the packing ceiling.
            // --rank-by rec: the direct question. pRec is the measured fraction
            // of this family whose exact cq beats the record, so it needs no
            // proxy and no conditioning. Ties (usually pRec == 0, since a record
            // is rare) fall through to cqCeil, which at least says how close the
            // spot's packing can get.
            if (rankBy == "rec") {
                if (x.M.pRec != y.M.pRec)     return x.M.pRec > y.M.pRec;
                if (x.M.cqCeil != y.M.cqCeil) return x.M.cqCeil > y.M.cqCeil;
                return x.M.scoreRate > y.M.scoreRate;
            }
            if (rankBy == "win") {
                double kx = x.M.scoreRate * x.M.pWin;
                double ky = y.M.scoreRate * y.M.pWin;
                if (kx != ky) return kx > ky;
                if (x.M.winners != y.M.winners) return x.M.winners > y.M.winners;
                if (x.M.cqCeil != y.M.cqCeil) return x.M.cqCeil > y.M.cqCeil;
                return x.M.scoreRate > y.M.scoreRate;
            }
            // Efficiency-first ranking (default). cqCeil = mean packing x scoreT
            // is the best plausible cq a spot can yield; it is the only key that
            // separated the winners from the losers in the four-spot shootout.
            // Rate breaks ties: among equal ceilings, hunt the one that hits the
            // count more often.
            if (rankEff) {
                // winners FIRST: a family that contains no record-beater cannot
                // produce one at any hunt length, however good its rate looks.
                if (x.M.winners != y.M.winners) return x.M.winners > y.M.winners;
                if (x.M.pWin != y.M.pWin)     return x.M.pWin > y.M.pWin;
                if (x.M.cqCeil != y.M.cqCeil) return x.M.cqCeil > y.M.cqCeil;
                return x.M.scoreRate > y.M.scoreRate;
            }
            if (rankBy == "hits") {
                if (x.M.scoreHits != y.M.scoreHits) return x.M.scoreHits > y.M.scoreHits;
                return x.M.scoreRate > y.M.scoreRate;
            }
            if (rankBy == "combined") {
                double kx = x.M.scoreRate * log(1.0 + (double)x.M.scoreHits);
                double ky = y.M.scoreRate * log(1.0 + (double)y.M.scoreHits);
                if (kx != ky) return kx > ky;
                return x.M.scoreRate > y.M.scoreRate;
            }
            // default: score
            if (x.M.scoreRate != y.M.scoreRate) return x.M.scoreRate > y.M.scoreRate;
            return x.M.treatRate > y.M.treatRate;
        });

        // Output is nothing but commands, best first, one per line. Anything
        // that failed the inverted-control test is simply not here.
        // No numeric prefix - the console already shows max/hits/rate, and
        // a bare line can be piped straight into a runner.
        int kept = 0;
        HS_MKDIR(seedsDir.c_str());
        FILE* o = fopen(outFile.c_str(), "w");
        if (!o) {
            std::string p = outFile;
            size_t slash = p.find_last_of("/\\");
            if (slash != std::string::npos) { HS_MKDIR(p.substr(0, slash).c_str()); }
            o = fopen(outFile.c_str(), "w");
        }
        if (!o) { fprintf(stderr, "cannot write %s\n", outFile.c_str()); return 1; }
        for (size_t i = 0; i < rows.size(); i++) {
            // --emit-top N ignores the verdict for the first N rows: hunt them and
            // let the seeds decide, which is what actually produced the records.
            bool emit = (emitTop > 0) ? (kept < emitTop && rows[i].D.bitsFixed >= 10)
                                      : (rows[i].M.verdict == 2);
            if (!emit) continue;
            fprintf(o, "%s\n",
                    huntCommand(rows[i].bx, rows[i].bz, rows[i].D.mask, rows[i].D.val,
                                mChunks, huntFloor, reportEvery, huntExe.c_str(),
                                seedsDir.c_str()).c_str());
            kept++;
        }
        fclose(o);

        printf("\nranked %zu in %.1fs. %d %s -> %s (one command per line, best first)\n",
               cand.size(), allSecs, kept,
               emitTop > 0 ? "emitted (--emit-top, filters bypassed)" : "survived the control test",
               outFile.c_str());
        printf("\n=== TOP %d ===\n", topPrint);
        int shown = 0;
        for (size_t i = 0; i < rows.size() && shown < topPrint; i++) {
            if (emitTop <= 0 && rows[i].M.verdict != 2) continue;
            if (emitTop > 0 && rows[i].D.bitsFixed < 10) continue;
            shown++;
            if (rankBy == "like")
                printf("#%2d  block(%8d,%8d)  like-dist %6.3f  cqCeil %5.1f  pWin %5.1f%%  "
                       "p>=%d %.3e (%llu hits)  %2d bits\n",
                       shown, rows[i].bx, rows[i].bz, rows[i].M.likeDist, rows[i].M.cqCeil,
                       rows[i].M.pWin * 100.0, scoreT, rows[i].M.scoreRate, rows[i].M.scoreHits,
                       rows[i].D.bitsFixed);
            else if (rankBy == "rec")
                printf("#%2d  block(%8d,%8d)  pRec %.3e (%llu/%lld beat %.2f)  cqCeil %5.1f  "
                       "eff %5.1f%%@>=%dc  max %u  %2d bits\n",
                       shown, rows[i].bx, rows[i].bz, rows[i].M.pRec,
                       rows[i].M.recHits, rows[i].M.recN, recordCq, rows[i].M.cqCeil,
                       rows[i].M.effMean * 100.0, rows[i].M.effFloor,
                       rows[i].M.treatMax, rows[i].D.bitsFixed);
            else if (rankBy == "win")
                printf("#%2d  block(%8d,%8d)  winRate %.3e  pWin %5.1f%%  cqCeil %5.1f  "
                       "eff %5.1f%%@>=%dc (%llu smp)  p>=%d %.3e  max %u  %2d bits\n",
                       shown, rows[i].bx, rows[i].bz,
                       rows[i].M.scoreRate * rows[i].M.pWin, rows[i].M.pWin * 100.0,
                       rows[i].M.cqCeil, rows[i].M.effMean * 100.0, rows[i].M.effFloor,
                       rows[i].M.effSamples, scoreT, rows[i].M.scoreRate,
                       rows[i].M.treatMax, rows[i].D.bitsFixed);
            else
                printf("#%2d  block(%8d,%8d)  p>=%d %.3e (%llu hits)  max %u  %2d bits  layouts 2^%d\n",
                       shown, rows[i].bx, rows[i].bz, scoreT, rows[i].M.scoreRate,
                       rows[i].M.scoreHits, rows[i].M.treatMax, rows[i].D.bitsFixed,
                       48 - rows[i].D.bitsFixed);
        }
        if (!shown) printf("  (nothing survived -- lower --score-t/--deep-t or widen the scan)\n");
        if (rankBy == "win")
            printf("winRate = p(count >= %d | mask) x pWin = record-beaters per seed sampled.\n"
                   "THIS IS THE RANKING KEY: expected seconds to a record = 1/(winRate x seeds_per_sec).\n"
                   "winners = winRate x 2^(48-bits) is how many exist in the family - shown as a\n"
                   "SANITY CHECK, not ranked on (below ~1 the family holds no record at any length).\n"
                   "max = luckiest single draw in a fixed %lld-seed sample. An order statistic,\n"
                   "not a property of the spot - do not filter on it. That is what --score-t is for.\n",
                   scoreT, std::min(measureNMin, measureN));
        else
            printf("score = p(count >= %d | mask) = hits/seed = hits/sec. THIS IS THE RANKING KEY.\n"
                   "max = luckiest single draw in a fixed %lld-seed sample. It is an order statistic,\n"
                   "not a property of the spot - do not filter on it. That is what --score-t is for.\n",
                   scoreT, std::min(measureNMin, measureN));

        // The next two steps, ready to paste. No extra files - the whole
        // point is that the pipeline is three copy-pastes, not a pile of txts.
        if (kept) {
            printf("\n================ NEXT: HUNT ================\n");
            printf("Runs every command in %s, %d seconds each, then moves on.\n"
                   "Each spot appends to its own file %s\\<x>_<z>.csv.\n"
                   "Dead families self-abort (--give-up-after 100000000): 5 of 8 spots in a\n"
                   "measured batch produced ZERO hits in 100M seeds. WaitForExit means the\n"
                   "runner starts the next spot the moment one gives up.\n"
                   "Change 60000 (ms) to hunt each spot longer.\n\n", outFile.c_str(), 120, seedsDir.c_str());
            printf("powershell -Command \"Get-Content '%s' | ForEach-Object { $a = $_ -split ' ', 2; "
                   "Write-Host $a[0] $a[1]; $p = Start-Process -FilePath ('.\\' + $a[0]) -ArgumentList $a[1] "
                   "-PassThru -NoNewWindow; if (!$p.WaitForExit(60000)) { $p.Kill() } }\"\n",
                   outFile.c_str());
            printf("\n================ THEN: SCORE ================\n");
            printf("Scores every seed file this scan produced, at that spot's own centre.\n"
                   "Ranked cq logs -> main\\scores\\seeds\\, images -> main\\scores\\images\\.\n\n");
            // -match with a signed-int regex, NOT -split '_': a negative X like
            // -92224_5424 splits into ["",92224,5424] and $n[0] comes out empty,
            // silently scoring every negative-X family at the wrong centre.
            printf("powershell -Command \"Get-ChildItem '%s\\*.csv' | ForEach-Object { "
                   "if ($_.BaseName -match '^(-?\\d+)_(-?\\d+)$') { "
                   ".\\slime_refine.exe --seeds $_.FullName "
                   "--center-x $matches[1] --center-z $matches[2] --radius 6 } }\"\n", seedsDir.c_str());
        }

        // The acceptance test: where did your known-good spot land?
        for (size_t i = 0; i < includes.size(); i++) {
            int r = 0, live = 0;
            double sc = 0;
            for (size_t j = 0; j < rows.size(); j++) {
                if (rows[j].M.verdict == 2) live++;
                if (rows[j].bx == includes[i].first && rows[j].bz == includes[i].second) {
                    r = (rows[j].M.verdict == 2) ? live : 0; sc = rows[j].M.treatRate;
                }
            }
            if (r) printf("\nCONTROL block(%d,%d) ranked %d of %d (score %.3e).\n",
                          includes[i].first, includes[i].second, r, kept, sc);
            else   printf("\nCONTROL block(%d,%d) was dropped (score %.3e).\n"
                          "  If its score is competitive with the kept rows above, the FILTER threw it\n"
                          "  out, not the control test - check --score-t and --min-hits.\n",
                          includes[i].first, includes[i].second, sc);
        }
        return 0;
    }

    fprintf(stderr,
        "usage:\n"
        "  --self-test                       GPU vs CPU (variance + early-exit rate)\n"
        "  --score-one --center-x X --center-z Z\n"
        "  --scan  ...                       gate + deep-tail rank -> commands.txt\n"
        "  --check --center-x X --center-z Z  full check of a single spot\n"
        "  --from-seeds seeds.csv --center-x X --center-z Z   widen mask from real hits\n"
        "  --bench --range N [--bench-locs K]  areas/sec for pass 1 + sec/area for pass 2\n"
        "  --scan --rank-by like [--like X,Z ...]   rank by resemblance to known-good\n"
        "                                      spots (default: the two known records)\n"
        "                                      instead of the --eff-target/--min-pwin/\n"
        "                                      --min-winners minimum gates\n");
    return 1;
}
