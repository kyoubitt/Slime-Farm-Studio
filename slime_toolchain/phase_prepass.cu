// phase_prepass.cu - the PREDICTION SEARCH's screen (predict_cycle.ps1). Separate from hotspot_scan: the exact search never uses it.
// For each spot: at every grid position (dx -6..6 step 3, dz -3..3 step 3), the kept families (top 5% by possible
// chunks, as the exact search) are tried on a SAMPLE of K classes each (default 512 random per family, 1/64 of the
// exact work) with the exact phase model; reported per spot: the best count found, how many (family, class) pairs
// reach 64 / 66 / 68 / 70, and how many distinct families reach 66+. A cheap "how jackpot-like is this spot" score -
// to test whether spots picked by it hold better farms than spots picked by heat. The exact search stays the judge.
// Build: nvcc -O3 -arch=native phase_prepass.cu -o phase_prepass.exe
// Use:   phase_prepass --spots spots.txt (lines X,Z in blocks) --out result.csv [--probe 8 --exhaust 128 (default; 0 turns
//        the probe off and falls back to the old sample)] [--classes 512] [--mode random|low] [--top-pct 5]
//        [--top-positions 10 (the exact search's adaptive positions; 0 = all 15)] [--pos-stat 150]
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <atomic>
#include <mutex>
#include <thread>
#include <vector>
#include <string>
#include <algorithm>
#include <chrono>
#include <cuda_runtime.h>
#include "slime_core.h"
#include "portable_paths.h"
#include "cuda_device.h"

#define PH_M  0x5DEECE66DULL
#define PH_MK ((1ULL << 48) - 1)
#define PH_C  (0x3ad8025fULL ^ PH_M)
__host__ __device__ __forceinline__ uint64_t posOffset(long long cx, long long cz) {
    uint64_t p = 0;
    p += (uint64_t)(int64_t)(int32_t)((int64_t)cx * (int64_t)cx * 0x4c1906LL);
    p += (uint64_t)(int64_t)(int32_t)((int64_t)cx * 0x5ac0dbLL);
    p += (uint64_t)((int64_t)((int32_t)((int64_t)cz * (int64_t)cz)) * 0x4307a7LL);
    p += (uint64_t)(int64_t)(int32_t)((int64_t)cz * 0x5f24fLL);
    return p;
}
__host__ __device__ __forceinline__ uint32_t phaseB0(uint64_t s35, uint64_t P) {
    uint64_t t = (((s35 + P) ^ 0x3ad8025fULL) ^ PH_M) & PH_MK;
    return (uint32_t)((((t * PH_M) + 0xBULL) & PH_MK) >> 17);
}
__host__ __device__ __forceinline__ int phaseBoundFrom(uint64_t c0, uint64_t c1, uint64_t c2, uint64_t c3) {
    int U = 0;
    for (int r = 0; r < 5; r++) {
        const int r3 = (r + 3) % 5;
        const int a0 = (int)((c0 >> (8 * r)) & 0xFF), a1 = (int)((c1 >> (8 * r)) & 0xFF), a2 = (int)((c2 >> (8 * r)) & 0xFF), a3 = (int)((c3 >> (8 * r)) & 0xFF);
        const int b0 = (int)((c0 >> (8 * r3)) & 0xFF), b1 = (int)((c1 >> (8 * r3)) & 0xFF), b2 = (int)((c2 >> (8 * r3)) & 0xFF), b3 = (int)((c3 >> (8 * r3)) & 0xFF);
        const int u0 = a0 + a1 + a2 + a3 + b3, u1 = a0 + a1 + a2 + b2 + b3, u2 = a0 + a1 + b1 + b2 + b3, u3 = a0 + b0 + b1 + b2 + b3;
        U = max(U, max(max(u0, u1), max(u2, u3)));
    }
    return U;
}
// WEIGHTED (2026-09-20): the same sweep, but each chunk adds its share of the AFK sphere (slime_core
// buildBlockWeights) instead of 1, so the result is BLOCKS - the number /perimeterinfo reads, cq * 256 - rather than
// the chunk count the search has always ranked by. Within one chunk count the blocks span ~2,500 (count 74:
// 15,517-18,006) while two extra chunks are worth ~580, and at 23% of searched spots the best-blocks layout is not
// the best-count layout. Verified against brute force over all 8,192 top values: 2,000 checks, 0 mismatches
// (main\theory\research\phase_blocks.cpp).
__device__ int bestBlocksOfClassDev(const uint64_t* P, const int* Wg, int n, uint64_t s35) {
    uint32_t e[226]; int m = 0; int N[5] = {0, 0, 0, 0, 0};
    for (int i = 0; i < n; i++) { uint32_t b = phaseB0(s35, P[i]); if (b & 1) continue; uint32_t ph = b % 5; e[m++] = ((8192u - (b >> 18)) << 11) | (ph << 8) | (uint32_t)i; N[ph] += Wg[i]; }
    for (int i = 1; i < m; i++) { uint32_t x = e[i]; int j = i - 1; while (j >= 0 && e[j] > x) { e[j + 1] = e[j]; j--; } e[j + 1] = x; }
    int best = -1;
    for (int r = 0; r < 5; r++) {
        const uint32_t r3 = (r + 3) % 5; int cnt = N[r], p = 0, w = r;
        for (;;) {
            while (p < m && (int)(e[p] >> 11) <= w) { const uint32_t ph = (e[p] >> 8) & 7; const int wt = Wg[e[p] & 0xFF];
                if (ph == (uint32_t)r) cnt -= wt; else if (ph == r3) cnt += wt; p++; }
            if (cnt > best) best = cnt;
            while (p < m && ((e[p] >> 8) & 7) != (uint32_t)r && ((e[p] >> 8) & 7) != r3) p++;
            if (p >= m) break;
            const int t = (int)(e[p] >> 11), nw = t + (((r - t) % 5) + 5) % 5;
            if (nw >= 8192) break; w = nw;
        }
    }
    return best;
}
__device__ int bestOfClassDev(const uint64_t* P, int n, uint64_t s35) {    // hotspot_scan's phaseBestOfClass, counts only
    uint32_t e[226]; int m = 0; int N[5] = {0, 0, 0, 0, 0};
    for (int i = 0; i < n; i++) { uint32_t b = phaseB0(s35, P[i]); if (b & 1) continue; uint32_t ph = b % 5; e[m++] = ((8192u - (b >> 18)) << 11) | (ph << 8) | (uint32_t)i; N[ph]++; }
    for (int i = 1; i < m; i++) { uint32_t x = e[i]; int j = i - 1; while (j >= 0 && e[j] > x) { e[j + 1] = e[j]; j--; } e[j + 1] = x; }
    int best = -1;
    for (int r = 0; r < 5; r++) {
        const uint32_t r3 = (r + 3) % 5; int cnt = N[r], p = 0, w = r;
        for (;;) {
            while (p < m && (int)(e[p] >> 11) <= w) { const uint32_t ph = (e[p] >> 8) & 7; if (ph == (uint32_t)r) cnt--; else if (ph == r3) cnt++; p++; }
            if (cnt > best) best = cnt;
            while (p < m && ((e[p] >> 8) & 7) != (uint32_t)r && ((e[p] >> 8) & 7) != r3) p++;
            if (p >= m) break;
            const int t = (int)(e[p] >> 11), nw = t + (((r - t) % 5) + 5) % 5;
            if (nw >= 8192) break; w = nw;
        }
    }
    return best;
}
// bestOfClassDev / bestBlocksOfClassDev, same value, less work. A residue r (top values w = r mod 5) only ever sees
// the chunks of phase r and r + 3, so each walk sorts those ~2/5 of the possible chunks, not all of them. An octile
// bound per residue (phase r chunks count while w < thr, phase r+3 ones once w >= thr; thr's octile is B(0) >> 28)
// orders the residues and skips any that cannot beat the best so far - the maximum is still exact. With floorV > 0
// a result below floorV is reported as -2 (not computed exactly): the caller re-runs the spot if its best is below it.
__device__ int bestOfClassFast(const uint64_t* P, const int* Wg, int n, uint64_t s35, int floorV) {
    uint32_t e[226]; int m = 0;
    uint64_t lo0 = 0, lo1 = 0, lo2 = 0, lo3 = 0, lo4 = 0, hi0 = 0, hi1 = 0, hi2 = 0, hi3 = 0, hi4 = 0;
    for (int i = 0; i < n; i++) {
        const uint32_t b = phaseB0(s35, P[i]); if (b & 1) continue;
        const uint32_t ph = b % 5; const uint64_t wt = Wg ? (uint64_t)Wg[i] : 1;
        e[m++] = ((8192u - (b >> 18)) << 11) | (ph << 8) | (uint32_t)i;
        const uint32_t o = b >> 28; const uint64_t inc = wt << (16 * (o & 3)); const bool h = o >> 2;
        lo0 += (ph == 0 && !h) ? inc : 0; hi0 += (ph == 0 && h) ? inc : 0; lo1 += (ph == 1 && !h) ? inc : 0; hi1 += (ph == 1 && h) ? inc : 0;
        lo2 += (ph == 2 && !h) ? inc : 0; hi2 += (ph == 2 && h) ? inc : 0; lo3 += (ph == 3 && !h) ? inc : 0; hi3 += (ph == 3 && h) ? inc : 0;
        lo4 += (ph == 4 && !h) ? inc : 0; hi4 += (ph == 4 && h) ? inc : 0;
    }
    const uint64_t LO[5] = {lo0, lo1, lo2, lo3, lo4}, HI[5] = {hi0, hi1, hi2, hi3, hi4};
    int N[5], U[5];
    #pragma unroll
    for (int r = 0; r < 5; r++) { int t = 0;
        #pragma unroll
        for (int k = 0; k < 4; k++) t += (int)((LO[r] >> (16 * k)) & 0xFFFF) + (int)((HI[r] >> (16 * k)) & 0xFFFF);
        N[r] = t; }
    #pragma unroll
    for (int r = 0; r < 5; r++) {
        const int r3 = (r + 3) % 5; int preA = N[r], sufB = 0, u = 0;
        #pragma unroll
        for (int k = 7; k >= 0; k--) {
            const int a = (int)((((k >> 2) ? HI[r] : LO[r]) >> (16 * (k & 3))) & 0xFFFF), bb = (int)((((k >> 2) ? HI[r3] : LO[r3]) >> (16 * (k & 3))) & 0xFFFF);
            sufB += bb; u = max(u, preA + sufB); preA -= a; }
        U[r] = u;
    }
    int best = -1; uint32_t done = 0;
    uint32_t t[226];
    for (int it = 0; it < 5; it++) {
        int r = -1, ur = -1;
        for (int q = 0; q < 5; q++) if (!(done >> q & 1) && U[q] > ur) { ur = U[q]; r = q; }
        done |= 1u << r;
        if (ur <= best || ur < floorV) break;
        // 2026-09-22: the residue's chunks are first placed by threshold bucket (thr >> 7, 65 buckets), so the insertion
        // sort below only fixes order inside a bucket (~1 chunk each) - O(n) instead of O(n^2) in local memory, which
        // was 90% of the probe. Keys are distinct (they hold the chunk index), so the sorted array is the same.
        const uint32_t r3 = (r + 3) % 5; int mm = 0;
        uint16_t st[66];
        for (int k = 0; k < 66; k++) st[k] = 0;
        for (int i = 0; i < m; i++) { const uint32_t ph = (e[i] >> 8) & 7; if (ph == (uint32_t)r || ph == r3) { st[(e[i] >> 18) + 1]++; mm++; } }
        for (int k = 0; k < 65; k++) st[k + 1] += st[k];
        for (int i = 0; i < m; i++) { const uint32_t ph = (e[i] >> 8) & 7; if (ph == (uint32_t)r || ph == r3) t[st[e[i] >> 18]++] = e[i]; }
        for (int i = 1; i < mm; i++) { uint32_t x = t[i]; int j = i - 1; while (j >= 0 && t[j] > x) { t[j + 1] = t[j]; j--; } t[j + 1] = x; }
        int cnt = N[r], p = 0, w = r;
        for (;;) {
            while (p < mm && (int)(t[p] >> 11) <= w) { const uint32_t ph = (t[p] >> 8) & 7; const int wt = Wg ? Wg[t[p] & 0xFF] : 1;
                if (ph == (uint32_t)r) cnt -= wt; else cnt += wt; p++; }
            if (cnt > best) best = cnt;
            if (p >= mm) break;
            const int th = (int)(t[p] >> 11), nw = th + (((r - th) % 5) + 5) % 5;
            if (nw >= 8192) break; w = nw;
        }
    }
    return (floorV > 0 && best < floorV) ? -2 : best;
}
__device__ __forceinline__ uint32_t sampleClass(uint32_t fam, uint32_t j, int mode) {
    if (mode == 1) return j & 0x7FFF;                                  // "low": the first K classes
    uint32_t h = fam * 0x9E3779B1u + j * 0x85EBCA6Bu;                   // "random": a per-family hashed sample
    h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
    return h & 0x7FFF;
}
__global__ void possibleKernel(const uint64_t* __restrict__ P, int n, uint8_t* __restrict__ outN) {
    int f = blockIdx.x * blockDim.x + threadIdx.x; if (f >= (1 << 18)) return;
    int c = 0; for (int i = 0; i < n; i++) c += !(phaseB0((uint64_t)f, P[i]) & 1); outN[f] = (uint8_t)c;
}
// Possibility (B(0) even) is bit 17 of ((f + P) mod 2^18 ^ C) * M + A, so it depends on u = (f + P) mod 2^18 only:
// G holds it for all 2^18 u as bits. A thread takes 32 consecutive families, reads the 32 bits for each chunk with
// one funnel shift, and adds them into 8 bit-planes (a vertical counter), so each (family, chunk) costs a few bit
// operations instead of a 48-bit multiply. Same counts as possibleKernel, bit for bit; one launch for all positions.
__global__ void __launch_bounds__(256) possibleBitKernel(const uint32_t* __restrict__ Gg, const uint32_t* __restrict__ Pl, int n, uint8_t* __restrict__ outN) {
    __shared__ uint32_t G[8192];
    for (int i = threadIdx.x; i < 8192; i += blockDim.x) G[i] = Gg[i];
    __syncthreads();
    const int pos = blockIdx.y; const uint32_t* p = Pl + pos * n;
    const uint32_t f0 = (blockIdx.x * blockDim.x + threadIdx.x) << 5;
    uint32_t c0 = 0, c1 = 0, c2 = 0, c3 = 0, c4 = 0, c5 = 0, c6 = 0, c7 = 0;
    for (int i = 0; i < n; i++) {
        const uint32_t s = (f0 + p[i]) & 0x3FFFFu, w = s >> 5;
        uint32_t x = __funnelshift_r(G[w], G[(w + 1) & 8191], s & 31), t;
        t = c0 & x; c0 ^= x; x = t; t = c1 & x; c1 ^= x; x = t; t = c2 & x; c2 ^= x; x = t; t = c3 & x; c3 ^= x; x = t;
        t = c4 & x; c4 ^= x; x = t; t = c5 & x; c5 ^= x; x = t; t = c6 & x; c6 ^= x; x = t; c7 ^= x;
    }
    uint8_t* o = outN + ((size_t)pos << 18) + f0;
    #pragma unroll
    for (int j = 0; j < 32; j++)
        o[j] = (uint8_t)(((c0 >> j) & 1) | (((c1 >> j) & 1) << 1) | (((c2 >> j) & 1) << 2) | (((c3 >> j) & 1) << 3) |
                         (((c4 >> j) & 1) << 4) | (((c5 >> j) & 1) << 5) | (((c6 >> j) & 1) << 6) | (((c7 >> j) & 1) << 7));
}
// bound over (family, sampled class); items = F * K, K a multiple of 256 so a tile never straddles families
__global__ void __launch_bounds__(256)
sampleBoundKernel(const uint64_t* __restrict__ Pg, int n, const uint32_t* __restrict__ fams, int K, int mode,
                  long long items, int T, unsigned long long* __restrict__ queue, unsigned int* __restrict__ qCount, unsigned int qCap) {
    // the exact search's fast inner loop (hotspot_scan phaseBoundKernel, 1.44x): only K >> 17 is kept, K>>17 and H0 sit side
    // by side and are read two chunks per 128-bit load, and b = (((H0 + c) ^ C') * 8M + (K >> 17)) mod 2^31 - equal to
    // ((K + (y << 20)) mod 2^48) >> 17 (proof in hotspot_scan.cu); the output is byte-identical to the plain loop.
    __shared__ __align__(16) uint2 KH[228]; __shared__ int nPoss;
    __shared__ uint32_t SC[20 * 256];
    const uint32_t M8 = (uint32_t)(PH_M << 3), CX = (uint32_t)(PH_C >> 20);
    const long long tiles = items >> 8;
    for (long long tile = blockIdx.x; tile < tiles; tile += gridDim.x) {
        const long long g0 = tile << 8; const long long fi = g0 / K;
        const uint32_t fam = fams[fi];
        __syncthreads(); if (threadIdx.x == 0) nPoss = 0; __syncthreads();
        for (int i = threadIdx.x; i < n; i += blockDim.x) {
            const uint64_t Q = ((uint64_t)fam + Pg[i]) & PH_MK;
            const uint64_t k = (((Q & 0xFFFFF) ^ (PH_C & 0xFFFFF)) * PH_M + 0xBULL) & PH_MK;
            if (!((k >> 17) & 1)) { const int j = atomicAdd(&nPoss, 1); KH[j] = make_uint2((uint32_t)(k >> 17), (uint32_t)(Q >> 20)); }
        }
        __syncthreads();
        const int m = nPoss; const long long g = g0 + threadIdx.x;
        const uint32_t c = sampleClass(fam, (uint32_t)(g - fi * K), mode);
        for (int k = 0; k < 20; k++) SC[k * 256 + threadIdx.x] = 0;
        const uint4* KH4 = reinterpret_cast<const uint4*>(KH);
        #pragma unroll 2
        for (int i = 0; i + 1 < m; i += 2) {
            const uint4 kh = KH4[i >> 1];
            const uint32_t b0 = (((kh.y + c) ^ CX) * M8 + kh.x) & 0x7FFFFFFFu, b1 = (((kh.w + c) ^ CX) * M8 + kh.z) & 0x7FFFFFFFu;
            SC[((b0 >> 29) * 5 + b0 % 5) * 256 + threadIdx.x]++;
            SC[((b1 >> 29) * 5 + b1 % 5) * 256 + threadIdx.x]++;
        }
        if (m & 1) { const uint2 kh = KH[m - 1]; const uint32_t b = (((kh.y + c) ^ CX) * M8 + kh.x) & 0x7FFFFFFFu; SC[((b >> 29) * 5 + b % 5) * 256 + threadIdx.x]++; }
        uint64_t c0 = 0, c1 = 0, c2 = 0, c3 = 0;
        for (int r = 0; r < 5; r++) { c0 |= (uint64_t)SC[r * 256 + threadIdx.x] << (8 * r); c1 |= (uint64_t)SC[(5 + r) * 256 + threadIdx.x] << (8 * r);
                                      c2 |= (uint64_t)SC[(10 + r) * 256 + threadIdx.x] << (8 * r); c3 |= (uint64_t)SC[(15 + r) * 256 + threadIdx.x] << (8 * r); }
        if (phaseBoundFrom(c0, c1, c2, c3) >= T) { const unsigned int q = atomicAdd(qCount, 1u); if (q < qCap) queue[q] = (unsigned long long)g; }
    }
}
__host__ __device__ __forceinline__ void phaseAccumulate(uint32_t b, uint64_t& c0, uint64_t& c1, uint64_t& c2, uint64_t& c3) {
    if (b & 1) return;
    const uint64_t inc = 1ULL << (8 * (b % 5)); const uint32_t q = b >> 29;
    c0 += (q == 0) ? inc : 0; c1 += (q == 1) ? inc : 0; c2 += (q == 2) ? inc : 0; c3 += (q == 3) ? inc : 0;
}
// BIT-SLICED QUARTER BOUND (2026-09-22). Same 32-classes-per-thread tables as phaseBoundBSKernel, with the quarter
// (bits 30-31 of b2 = bits 29-30 of B(0)) in place of the half: breakpoints k 2^30 - D, k = 1..4, up to 129 intervals.
// Each class's 20 (residue, quarter) counts sit in 5-plane bit-sliced counters; a count reaching 32 sets the class's
// overflow bit. At the end the quarter bound max_r max_s u_{r,s} is summed bit-sliced from the 20 counts - exactly
// phaseBoundFrom - so a class without overflow is queued iff phaseBoundKernel queues it; overflowed classes (rare:
// 20 bins share ~150 chunks) get the quarter bound computed directly, one warp each. The queue is the same set.
#define BSQ_NI 136
__device__ __forceinline__ void bsqAdd2(uint32_t (&c)[5], uint32_t& ov, uint32_t a, uint32_t b) {
    uint32_t k = (c[0] & a) | (c[0] & b) | (a & b); c[0] ^= a ^ b;
    #pragma unroll
    for (int i = 1; i < 5; i++) { const uint32_t t = c[i] & k; c[i] ^= k; k = t; }
    ov |= k;
}
// four masks at once with carry-save adders: 13 bit operations per counter instead of 22 for two bsqAdd2
__device__ __forceinline__ void bsqAdd4(uint32_t (&c)[5], uint32_t& ov, uint32_t a, uint32_t b, uint32_t d, uint32_t e) {
    const uint32_t s1 = c[0] ^ a ^ b, t1 = (c[0] & a) | (c[0] & b) | (a & b);
    const uint32_t t2 = (s1 & d) | (s1 & e) | (d & e); c[0] = s1 ^ d ^ e;
    uint32_t k = (c[1] & t1) | (c[1] & t2) | (t1 & t2); c[1] ^= t1 ^ t2;
    #pragma unroll
    for (int i = 2; i < 5; i++) { const uint32_t t = c[i] & k; c[i] ^= k; k = t; }
    ov |= k;
}
__device__ __forceinline__ void bsqAdd1(uint32_t (&c)[5], uint32_t& ov, uint32_t a) {
    uint32_t k = a;
    #pragma unroll
    for (int i = 0; i < 5; i++) { const uint32_t t = c[i] & k; c[i] ^= k; k = t; }
    ov |= k;
}
__device__ __forceinline__ void bsqSum(const uint32_t (&x)[8], const uint32_t (&y)[8], uint32_t (&s)[8]) {
    uint32_t k = 0;
    #pragma unroll
    for (int i = 0; i < 8; i++) { const uint32_t a = x[i], b = y[i]; s[i] = a ^ b ^ k; k = (a & b) | (a & k) | (b & k); }
}
__device__ __forceinline__ uint32_t bsqGe(const uint32_t (&c)[8], int T) {
    if (T <= 0) return 0xFFFFFFFFu;
    if (T > 255) return 0u;
    uint32_t gt = 0, eq = 0xFFFFFFFFu;
    #pragma unroll
    for (int i = 7; i >= 0; i--) { if ((T >> i) & 1) eq &= c[i]; else { gt |= eq & c[i]; eq &= ~c[i]; } }
    return gt | eq;
}
__device__ uint32_t gBsqV10[BSQ_NI * 10], gBsqQB[BSQ_NI * 2], gBsqBP[BSQ_NI];
__device__ __align__(16) uint8_t gBsqBK[4096];
__device__ int gBsqNBP;
// the tables depend only on M and C' - built once on the host (same code as the per-block build it replaced)
static void bsqInitTables() {
    const uint32_t M16 = (uint32_t)(PH_M << 4), CX = (uint32_t)(PH_C >> 20), CXL = CX & 31u;
    std::vector<uint32_t> bp;
    for (int e = 0; e < 32; e++) { const uint32_t D = (uint32_t)e * M16; for (uint32_t k = 1; k <= 4; k++) bp.push_back((k << 30) - D); }
    std::sort(bp.begin(), bp.end()); bp.erase(std::unique(bp.begin(), bp.end()), bp.end());
    const int nbp = (int)bp.size();
    std::vector<uint32_t> BP(BSQ_NI, 0xFFFFFFFFu), V10(BSQ_NI * 10, 0), QB(BSQ_NI * 2, 0); std::vector<uint8_t> BK(4096);
    for (int i = 0; i < nbp; i++) BP[i] = bp[i];
    for (int I = 0; I <= nbp; I++) {
        const uint32_t s = I ? BP[I - 1] : 0u; uint32_t v[5] = {0, 0, 0, 0, 0}, q0 = 0, q1 = 0;
        for (int p = 0; p < 32; p++) {
            const uint32_t D = (p ^ CXL) * M16, sum = s + D, k = (sum % 5u + 5u - s % 5u) % 5u;
            v[k] |= 1u << p; if ((sum >> 30) & 1) q0 |= 1u << p; if ((sum >> 31) & 1) q1 |= 1u << p;
        }
        for (int q = 0; q < 10; q++) V10[I * 10 + q] = v[q % 5];
        QB[I * 2] = q0; QB[I * 2 + 1] = q1;
    }
    for (int k = 0; k < 4096; k++) { const uint32_t x = (uint32_t)k << 20; int c = 0; while (c < nbp && BP[c] <= x) c++; BK[k] = (uint8_t)c; }
    CUDA_CHECK(cudaMemcpyToSymbol(gBsqV10, V10.data(), V10.size() * 4)); CUDA_CHECK(cudaMemcpyToSymbol(gBsqQB, QB.data(), QB.size() * 4));
    CUDA_CHECK(cudaMemcpyToSymbol(gBsqBP, BP.data(), BP.size() * 4)); CUDA_CHECK(cudaMemcpyToSymbol(gBsqBK, BK.data(), 4096));
    CUDA_CHECK(cudaMemcpyToSymbol(gBsqNBP, &nbp, sizeof(int)));
}
__global__ void __launch_bounds__(128)
phaseBoundBSQKernel(const uint64_t* __restrict__ Pg, int n, const uint32_t* __restrict__ fams,
                    long long itemBase, long long items, int T,
                    unsigned long long* __restrict__ queue, unsigned int* __restrict__ qCount, unsigned int qCap, unsigned long long tag = 0) {
    __shared__ uint32_t V10[BSQ_NI * 10], QB[BSQ_NI * 2], BP[BSQ_NI];
    __shared__ uint8_t BK[4096];
    __shared__ __align__(16) uint4 CH[228];
    __shared__ int nPoss, nBP, nS;
    __shared__ uint16_t sL[1024];
    const uint32_t M16 = (uint32_t)(PH_M << 4), CX = (uint32_t)(PH_C >> 20), CXH = CX & ~31u;
    for (int k = threadIdx.x; k < BSQ_NI * 10; k += blockDim.x) V10[k] = gBsqV10[k];
    for (int k = threadIdx.x; k < BSQ_NI * 2; k += blockDim.x) QB[k] = gBsqQB[k];
    for (int k = threadIdx.x; k < BSQ_NI; k += blockDim.x) BP[k] = gBsqBP[k];
    for (int k = threadIdx.x; k < 1024; k += blockDim.x) reinterpret_cast<uint32_t*>(BK)[k] = reinterpret_cast<const uint32_t*>(gBsqBK)[k];
    if (threadIdx.x == 0) nBP = gBsqNBP;
    __syncthreads();
    const int nbp = nBP;
    const long long tiles = items >> 12;
    const int lane = threadIdx.x & 31;
    for (long long tile = blockIdx.x; tile < tiles; tile += gridDim.x) {
        const long long g0 = itemBase + (tile << 12);
        const uint64_t fam = fams[g0 >> 15];
        __syncthreads();
        if (threadIdx.x == 0) nPoss = 0;
        __syncthreads();
        for (int i = threadIdx.x; i < n; i += blockDim.x) {
            const uint64_t Q = (fam + Pg[i]) & PH_MK;
            const uint64_t k = (((Q & 0xFFFFF) ^ (PH_C & 0xFFFFF)) * PH_M + 0xBULL) & PH_MK;
            if (!((k >> 17) & 1)) {
                const int j = atomicAdd(&nPoss, 1); const uint32_t H0 = (uint32_t)(Q >> 20), a = H0 & 31u;
                CH[j] = make_uint4((uint32_t)((k >> 17) << 1), H0 & ~31u, a, (1u << a) - 1u);
            }
        }
        __syncthreads();
        const int m = nPoss;
        const uint32_t cbase = (uint32_t)((g0 & 0x7FFF) + 32 * threadIdx.x);
        uint32_t cn[5][4][5], ov = 0;
        #pragma unroll
        for (int d = 0; d < 5; d++) {
            #pragma unroll
            for (int q = 0; q < 4; q++) {
                #pragma unroll
                for (int i = 0; i < 5; i++) cn[d][q][i] = 0;
            }
        }
        auto masks = [&](const uint4 ch, uint32_t (&P)[5], uint32_t& Q0, uint32_t& Q1) {
            const uint32_t t = ch.y + cbase;
            const uint32_t b0 = (t ^ CXH) * M16 + ch.x, b1 = ((t + 32u) ^ CXH) * M16 + ch.x;
            int I0 = BK[b0 >> 20]; while (BP[I0] <= b0 && I0 < nbp) I0++;
            int I1 = BK[b1 >> 20]; while (BP[I1] <= b1 && I1 < nbp) I1++;
            const uint32_t be0 = b0 % 5u, be1 = b1 % 5u;
            const int o0 = I0 * 10 + (be0 ? 5 - (int)be0 : 0), o1 = I1 * 10 + (be1 ? 5 - (int)be1 : 0);
            const uint32_t pm = ch.w, sh = ch.z;
            #pragma unroll
            for (int q = 0; q < 5; q++) { const uint32_t x = (V10[o0 + q] & ~pm) | (V10[o1 + q] & pm); P[q] = __funnelshift_r(x, x, sh); }
            const uint32_t x0 = (QB[I0 * 2] & ~pm) | (QB[I1 * 2] & pm), x1 = (QB[I0 * 2 + 1] & ~pm) | (QB[I1 * 2 + 1] & pm);
            Q0 = __funnelshift_r(x0, x0, sh); Q1 = __funnelshift_r(x1, x1, sh);
        };
        int i = 0;
        for (; i + 3 < m; i += 4) {
            uint32_t P0[5], P1[5], P2[5], P3[5], A0, A1, B0, B1, C0, C1, D0, D1;
            masks(CH[i], P0, A0, A1); masks(CH[i + 1], P1, B0, B1); masks(CH[i + 2], P2, C0, C1); masks(CH[i + 3], P3, D0, D1);
            const uint32_t qa[4] = {~A1 & ~A0, ~A1 & A0, A1 & ~A0, A1 & A0}, qb[4] = {~B1 & ~B0, ~B1 & B0, B1 & ~B0, B1 & B0};
            const uint32_t qc[4] = {~C1 & ~C0, ~C1 & C0, C1 & ~C0, C1 & C0}, qd[4] = {~D1 & ~D0, ~D1 & D0, D1 & ~D0, D1 & D0};
            #pragma unroll
            for (int d = 0; d < 5; d++) {
                #pragma unroll
                for (int q = 0; q < 4; q++) bsqAdd4(cn[d][q], ov, P0[d] & qa[q], P1[d] & qb[q], P2[d] & qc[q], P3[d] & qd[q]);
            }
        }
        for (; i + 1 < m; i += 2) {
            uint32_t P0[5], P1[5], A0, A1, B0, B1;
            masks(CH[i], P0, A0, A1); masks(CH[i + 1], P1, B0, B1);
            const uint32_t qa[4] = {~A1 & ~A0, ~A1 & A0, A1 & ~A0, A1 & A0}, qb[4] = {~B1 & ~B0, ~B1 & B0, B1 & ~B0, B1 & B0};
            #pragma unroll
            for (int d = 0; d < 5; d++) {
                #pragma unroll
                for (int q = 0; q < 4; q++) bsqAdd2(cn[d][q], ov, P0[d] & qa[q], P1[d] & qb[q]);
            }
        }
        if (i < m) {
            uint32_t P0[5], A0, A1; masks(CH[i], P0, A0, A1);
            const uint32_t qa[4] = {~A1 & ~A0, ~A1 & A0, A1 & ~A0, A1 & A0};
            #pragma unroll
            for (int d = 0; d < 5; d++) {
                #pragma unroll
                for (int q = 0; q < 4; q++) bsqAdd1(cn[d][q], ov, P0[d] & qa[q]);
            }
        }
        uint32_t surv = 0;
        #pragma unroll
        for (int ph = 0; ph < 5; ph++) {
            const int da = (2 * ph) % 5, db = (2 * ((ph + 3) % 5)) % 5;
            uint32_t a[4][8], b[4][8];
            #pragma unroll
            for (int q = 0; q < 4; q++) {
                #pragma unroll
                for (int k = 0; k < 8; k++) { a[q][k] = k < 5 ? cn[da][q][k] : 0u; b[q][k] = k < 5 ? cn[db][q][k] : 0u; }
            }
            uint32_t A01[8], A012[8], A0123[8], B23[8], B123[8], B0123[8], u[8];
            bsqSum(a[0], a[1], A01); bsqSum(A01, a[2], A012); bsqSum(A012, a[3], A0123);
            bsqSum(b[2], b[3], B23); bsqSum(b[1], B23, B123); bsqSum(b[0], B123, B0123);
            bsqSum(A0123, b[3], u); surv |= bsqGe(u, T);
            bsqSum(A012, B23, u); surv |= bsqGe(u, T);
            bsqSum(A01, B123, u); surv |= bsqGe(u, T);
            bsqSum(a[0], B0123, u); surv |= bsqGe(u, T);
        }
        uint32_t direct = surv & ~ov;
        while (direct) {
            const int j = __ffs(direct) - 1; direct &= direct - 1;
            const unsigned int q = atomicAdd(qCount, 1u);
            if (q < qCap) queue[q] = tag | (unsigned long long)(g0 + 32 * threadIdx.x + j);
        }
        uint32_t rest = ov;
        while (__syncthreads_or(rest != 0)) {
            if (threadIdx.x == 0) nS = 0;
            __syncthreads();
            while (rest) {
                const int j = __ffs(rest) - 1;
                const int s = atomicAdd(&nS, 1);
                if (s >= 1024) break;
                sL[s] = (uint16_t)(32 * threadIdx.x + j); rest &= rest - 1;
            }
            __syncthreads();
            const int ns = min(nS, 1024);
            for (int s = threadIdx.x >> 5; s < ns; s += blockDim.x >> 5) {
                const uint32_t cs = (uint32_t)((g0 & 0x7FFF) + sL[s]);
                uint64_t c0 = 0, c1 = 0, c2 = 0, c3 = 0;
                for (int k = lane; k < m; k += 32) {
                    const uint4 ch = CH[k];
                    phaseAccumulate((((ch.y + ch.z + cs) ^ CX) * M16 + ch.x) >> 1, c0, c1, c2, c3);
                }
                #pragma unroll
                for (int off = 16; off > 0; off >>= 1) {
                    c0 += __shfl_xor_sync(0xFFFFFFFFu, c0, off); c1 += __shfl_xor_sync(0xFFFFFFFFu, c1, off);
                    c2 += __shfl_xor_sync(0xFFFFFFFFu, c2, off); c3 += __shfl_xor_sync(0xFFFFFFFFu, c3, off);
                }
                if (lane == 0 && phaseBoundFrom(c0, c1, c2, c3) >= T) {
                    const unsigned int q = atomicAdd(qCount, 1u);
                    if (q < qCap) queue[q] = tag | (unsigned long long)(g0 + sL[s]);
                }
            }
            __syncthreads();
        }
    }
}
// PROBE (2026-09-20): a rich family's WHOLE class landscape is lifted, not only its handful of good classes
// (main\theory\research\class_landscape: mean count 50.2 vs 39.2, p99 64.5 vs 46.4 over 100 jackpots and 200
// ordinary kept families). So J classes per family rank the families far better than the possible count does:
// the jackpot family's median rank is 7 of ~59,000 by the mean of 8 classes, against 1,945 by possible chunks
// (probe_rank on 20 known jackpots; inside the top 256 at 100% vs 25%). The pre-pass therefore probes every
// kept family with J classes and then EXHAUSTS all 32,768 classes of the top --exhaust families.
__global__ void probeKernel(const uint64_t* __restrict__ Pg, int n, const uint32_t* __restrict__ fams, int nf, int J, int* __restrict__ outScore) {
    const int k = blockIdx.x * blockDim.x + threadIdx.x; if (k >= nf) return;
    const uint32_t fam = fams[k]; int s = 0;
    for (int j = 0; j < J; j++) { const uint32_t c = sampleClass(fam, (uint32_t)j, 0); s += bestOfClassDev(Pg, n, (uint64_t)fam | ((uint64_t)c << 20)); }
    outScore[k] = s;
}
__global__ void probeAllKernel(const uint64_t* __restrict__ Pall, int n, const uint32_t* __restrict__ fams, const int* __restrict__ fpos, int nf, int J, int* __restrict__ outScore) {
    const long long g = (long long)blockIdx.x * blockDim.x + threadIdx.x; if (g >= (long long)nf * J) return;
    const int k = (int)(g / J), j = (int)(g - (long long)k * J); const uint32_t fam = fams[k];
    const uint32_t c = sampleClass(fam, (uint32_t)j, 0);
    atomicAdd(&outScore[k], bestOfClassFast(Pall + (size_t)fpos[k] * n, nullptr, n, (uint64_t)fam | ((uint64_t)c << 20), 0));
}
__global__ void probeFastKernel(const uint64_t* __restrict__ Pg, int n, const uint32_t* __restrict__ fams, int nf, int J, int* __restrict__ outScore) {
    const int g = blockIdx.x * blockDim.x + threadIdx.x; if (g >= nf * J) return;
    const int k = g / J, j = g - k * J; const uint32_t fam = fams[k];
    const uint32_t c = sampleClass(fam, (uint32_t)j, 0);
    atomicAdd(&outScore[k], bestOfClassFast(Pg, nullptr, n, (uint64_t)fam | ((uint64_t)c << 20), 0));
}
// The bound kernel stays in CHUNK COUNTS even in --blocks mode, and that is SOUND: a cell is worth at most 256
// blocks, so blocks <= 256 * count and a count bound of T prunes nothing with cq >= T. With T = 60 no layout worth
// 60 cq or more can be lost, which covers every farm the search cares about (66+). Only the exact scoring of the
// survivors changes.
__global__ void sampleExactKernel(const uint64_t* __restrict__ Pg, const int* __restrict__ Wg, int n, const uint32_t* __restrict__ fams, int K, int mode,
                                  const unsigned long long* __restrict__ queue, unsigned int nq, int* __restrict__ outBest, int blocksMode) {
    const unsigned int q = blockIdx.x * blockDim.x + threadIdx.x; if (q >= nq) return;
    const long long g = (long long)queue[q]; const long long fi = g / K; const uint32_t fam = fams[fi];
    const uint32_t c = sampleClass(fam, (uint32_t)(g - fi * K), mode);
    const uint64_t s35 = (uint64_t)fam | ((uint64_t)c << 20);
    outBest[q] = blocksMode ? bestBlocksOfClassDev(Pg, Wg, n, s35) : bestOfClassDev(Pg, n, s35);
}
__global__ void sampleExactFastKernel(const uint64_t* __restrict__ Pg, const int* __restrict__ Wg, int n, const uint32_t* __restrict__ fams, int K, int mode,
                                      const unsigned long long* __restrict__ queue, unsigned int nq, int* __restrict__ outBest, int blocksMode, int floorV) {
    const unsigned int q = blockIdx.x * blockDim.x + threadIdx.x; if (q >= nq) return;
    const long long g = (long long)queue[q]; const long long fi = g / K; const uint32_t fam = fams[fi];
    const uint32_t c = sampleClass(fam, (uint32_t)(g - fi * K), mode);
    outBest[q] = bestOfClassFast(Pg, blocksMode ? Wg : nullptr, n, (uint64_t)fam | ((uint64_t)c << 20), floorV);
}

// WARP EXACT BEST (2026-09-22). bestOfClassFast, one warp per class: it ran at ~4% of the GPU's issue rate - two
// 226-entry arrays per thread thrashed local memory and threads of a warp walked different lengths. Here the lanes
// share the chunks, the entries live in the warp's shared memory, a residue's entries are sorted by rank (keys are
// distinct: they hold the chunk index) and the walk is a prefix sum: the walk evaluates cnt after the last entry of
// each group of equal walk point j = ceil((thr - r) / 5) (0 for thr <= r) with r + 5j < 8192, and at j = 0 even if
// that group is empty - the same values, so the same maximum. Bounds, residue order, pruning and the floor are
// bestOfClassFast's. The start-up self-test compares the two on random classes in both weightings and floors.
#define BW_WPB 4
__device__ int bestOfClassWarp(const uint64_t* P, const int* Wg, int n, uint64_t s35, int floorV, uint32_t* E, uint32_t* Tt, uint32_t* S) {
    const int lane = threadIdx.x & 31; const unsigned FULL = 0xFFFFFFFFu;
    uint64_t lo0 = 0, lo1 = 0, lo2 = 0, lo3 = 0, lo4 = 0, hi0 = 0, hi1 = 0, hi2 = 0, hi3 = 0, hi4 = 0;
    int m = 0;
    uint32_t q0 = 0, q1 = 0, q2 = 0, q3 = 0, q4 = 0;
    for (int base = 0; base < n; base += 32) {
        const int i = base + lane; uint32_t key = 0; bool ok = false;
        if (i < n) {
            const uint32_t b = phaseB0(s35, P[i]);
            if (!(b & 1)) {
                ok = true;
                const uint32_t ph = b % 5, o = b >> 28;
                key = ((8192u - (b >> 18)) << 11) | (ph << 8) | (uint32_t)i;
                if (Wg) {
                    const uint64_t inc = (uint64_t)Wg[i] << (16 * (o & 3)); const bool h = o >> 2;
                    lo0 += (ph == 0 && !h) ? inc : 0; hi0 += (ph == 0 && h) ? inc : 0; lo1 += (ph == 1 && !h) ? inc : 0; hi1 += (ph == 1 && h) ? inc : 0;
                    lo2 += (ph == 2 && !h) ? inc : 0; hi2 += (ph == 2 && h) ? inc : 0; lo3 += (ph == 3 && !h) ? inc : 0; hi3 += (ph == 3 && h) ? inc : 0;
                    lo4 += (ph == 4 && !h) ? inc : 0; hi4 += (ph == 4 && h) ? inc : 0;
                } else {    // counts: a lane sees <= 8 chunks, so a phase's 8 octile counts fit 4 bits each in one word
                    const uint32_t inc = 1u << (4 * o);
                    q0 += ph == 0 ? inc : 0; q1 += ph == 1 ? inc : 0; q2 += ph == 2 ? inc : 0; q3 += ph == 3 ? inc : 0; q4 += ph == 4 ? inc : 0;
                }
            }
        }
        const unsigned bal = __ballot_sync(FULL, ok);
        if (ok) E[m + __popc(bal & ((1u << lane) - 1u))] = key;
        m += __popc(bal);
    }
    // each 16-bit field sums to at most 226 x 256 < 2^16 over the warp, so a packed 32-bit add never carries across fields
    auto wsum = [&](uint64_t v) -> uint64_t { return (uint64_t)__reduce_add_sync(FULL, (unsigned)v) | ((uint64_t)__reduce_add_sync(FULL, (unsigned)(v >> 32)) << 32); };
    if (Wg) {
        lo0 = wsum(lo0); lo1 = wsum(lo1); lo2 = wsum(lo2); lo3 = wsum(lo3); lo4 = wsum(lo4);
        hi0 = wsum(hi0); hi1 = wsum(hi1); hi2 = wsum(hi2); hi3 = wsum(hi3); hi4 = wsum(hi4);
    } else {    // even / odd octiles to bytes; a byte sums to <= 226 over the warp, so the packed add never carries
        auto unpack = [&](uint32_t q, uint64_t& lo, uint64_t& hi) {
            const uint32_t ev = __reduce_add_sync(FULL, q & 0x0F0F0F0Fu), od = __reduce_add_sync(FULL, (q >> 4) & 0x0F0F0F0Fu);
            lo = (uint64_t)(ev & 0xFF) | ((uint64_t)(od & 0xFF) << 16) | ((uint64_t)((ev >> 8) & 0xFF) << 32) | ((uint64_t)((od >> 8) & 0xFF) << 48);
            hi = (uint64_t)((ev >> 16) & 0xFF) | ((uint64_t)((od >> 16) & 0xFF) << 16) | ((uint64_t)(ev >> 24) << 32) | ((uint64_t)(od >> 24) << 48);
        };
        unpack(q0, lo0, hi0); unpack(q1, lo1, hi1); unpack(q2, lo2, hi2); unpack(q3, lo3, hi3); unpack(q4, lo4, hi4);
    }
    __syncwarp();
    const uint64_t LO[5] = {lo0, lo1, lo2, lo3, lo4}, HI[5] = {hi0, hi1, hi2, hi3, hi4};
    int N[5], U[5];
    #pragma unroll
    for (int r = 0; r < 5; r++) { int t = 0;
        #pragma unroll
        for (int k = 0; k < 4; k++) t += (int)((LO[r] >> (16 * k)) & 0xFFFF) + (int)((HI[r] >> (16 * k)) & 0xFFFF);
        N[r] = t; }
    #pragma unroll
    for (int r = 0; r < 5; r++) {
        const int r3 = (r + 3) % 5; int preA = N[r], sufB = 0, u = 0;
        #pragma unroll
        for (int k = 7; k >= 0; k--) {
            const int a = (int)((((k >> 2) ? HI[r] : LO[r]) >> (16 * (k & 3))) & 0xFFFF), bb = (int)((((k >> 2) ? HI[r3] : LO[r3]) >> (16 * (k & 3))) & 0xFFFF);
            sufB += bb; u = max(u, preA + sufB); preA -= a; }
        U[r] = u;
    }
    int best = -1; uint32_t done = 0;
    for (int it = 0; it < 5; it++) {
        int r = -1, ur = -1;
        for (int q = 0; q < 5; q++) if (!(done >> q & 1) && U[q] > ur) { ur = U[q]; r = q; }
        done |= 1u << r;
        if (ur <= best || ur < floorV) break;
        // Walk without a sort: the answer is max over all w = r (mod 5), w < 8192, of cnt(w) - cnt only changes at a
        // walk point, so this is the walk's maximum. Entries go to 64 buckets of 26 walk points j (2 per lane); a lane
        // orders its ~2 entries by j and takes its prefix maximum at the end of each group of equal j; a warp scan adds
        // the lanes' offsets. N_r itself (j = 0 with nothing applied) counts only if no entry has j = 0.
        const uint32_t r3 = (r + 3) % 5;
        uint32_t* C = S; uint32_t* O = S + 64;
        C[2 * lane] = 0; C[2 * lane + 1] = 0;
        __syncwarp();
        bool hasZero = false;
        for (int base = 0; base < m; base += 32) {
            const int i = base + lane;
            if (i < m) { const uint32_t x = E[i]; const uint32_t ph = (x >> 8) & 7;
                if (ph == (uint32_t)r || ph == r3) { const int th = (int)(x >> 11), j = th <= r ? 0 : (th - r + 4) / 5;
                    if (r + 5 * j < 8192) { atomicAdd(&C[j / 26], 1u); hasZero |= (j == 0); } } }
        }
        __syncwarp();
        const uint32_t c0 = C[2 * lane], c1 = C[2 * lane + 1], cs = c0 + c1;
        uint32_t ex = cs;
        #pragma unroll
        for (int off = 1; off < 32; off <<= 1) { const uint32_t t = __shfl_up_sync(FULL, ex, off); if (lane >= off) ex += t; }
        ex -= cs;
        O[2 * lane] = ex; O[2 * lane + 1] = ex + c0;
        __syncwarp();
        for (int base = 0; base < m; base += 32) {
            const int i = base + lane;
            if (i < m) { const uint32_t x = E[i]; const uint32_t ph = (x >> 8) & 7;
                if (ph == (uint32_t)r || ph == r3) { const int th = (int)(x >> 11), j = th <= r ? 0 : (th - r + 4) / 5;
                    if (r + 5 * j < 8192) { const uint32_t wt = Wg ? (uint32_t)Wg[x & 0xFF] : 1u;
                        Tt[atomicAdd(&O[j / 26], 1u)] = ((uint32_t)j << 16) | (ph == (uint32_t)r ? 0x8000u : 0u) | wt; } } }
        }
        __syncwarp();
        const int p0 = (int)ex, p1 = (int)(ex + cs);
        for (int p = p0 + 1; p < p1; p++) { const uint32_t x = Tt[p]; int q = p - 1; while (q >= p0 && Tt[q] > x) { Tt[q + 1] = Tt[q]; q--; } Tt[q + 1] = x; }
        int run = 0, mp = -(1 << 30);
        for (int p = p0; p < p1; p++) {
            const uint32_t x = Tt[p]; const int v = (int)(x & 0x7FFF); run += (x & 0x8000u) ? -v : v;
            if (p == p1 - 1 || (Tt[p + 1] >> 16) != (x >> 16)) mp = max(mp, run);
        }
        int incl = run;
        #pragma unroll
        for (int off = 1; off < 32; off <<= 1) { const int t = __shfl_up_sync(FULL, incl, off); if (lane >= off) incl += t; }
        int cand = (p1 > p0) ? N[r] + (incl - run) + mp : -1;
        if (!__any_sync(FULL, hasZero) && lane == 0) cand = max(cand, N[r]);
        #pragma unroll
        for (int off = 16; off > 0; off >>= 1) cand = max(cand, __shfl_xor_sync(FULL, cand, off));
        best = max(best, cand);
        __syncwarp();
    }
    return (floorV > 0 && best < floorV) ? -2 : best;
}
__global__ void __launch_bounds__(32 * BW_WPB) probeWarpKernel(const uint64_t* __restrict__ Pall, int n, const uint32_t* __restrict__ fams, const int* __restrict__ fpos, int nf, int J, int* __restrict__ outScore) {
    __shared__ uint32_t sh[BW_WPB][3][228];
    const int wb = threadIdx.x >> 5;
    const long long g = ((long long)blockIdx.x * blockDim.x + threadIdx.x) >> 5; if (g >= (long long)nf * J) return;
    const int k = (int)(g / J), j = (int)(g - (long long)k * J); const uint32_t fam = fams[k];
    const uint32_t c = sampleClass(fam, (uint32_t)j, 0);
    const int v = bestOfClassWarp(Pall + (size_t)fpos[k] * n, nullptr, n, (uint64_t)fam | ((uint64_t)c << 20), 0, sh[wb][0], sh[wb][1], sh[wb][2]);
    if ((threadIdx.x & 31) == 0) atomicAdd(&outScore[k], v);
}
__global__ void __launch_bounds__(32 * BW_WPB) sampleExactWarpKernel(const uint64_t* __restrict__ Pg, const int* __restrict__ Wg, int n, const uint32_t* __restrict__ fams, int K, int mode,
                                      const unsigned long long* __restrict__ queue, unsigned int nq, int* __restrict__ outBest, int blocksMode, int floorV) {
    __shared__ uint32_t sh[BW_WPB][3][228];
    const int wb = threadIdx.x >> 5;
    const unsigned int q = (blockIdx.x * blockDim.x + threadIdx.x) >> 5; if (q >= nq) return;
    const long long g = (long long)queue[q]; const long long fi = g / K; const uint32_t fam = fams[fi];
    const uint32_t c = sampleClass(fam, (uint32_t)(g - fi * K), mode);
    const int v = bestOfClassWarp(Pg, blocksMode ? Wg : nullptr, n, (uint64_t)fam | ((uint64_t)c << 20), floorV, sh[wb][0], sh[wb][1], sh[wb][2]);
    if ((threadIdx.x & 31) == 0) outBest[q] = v;
}
__global__ void __launch_bounds__(32 * BW_WPB) warpSelfTestKernel(const uint64_t* __restrict__ Pg, const int* __restrict__ Wg, int n, int nTests, uint64_t seed, int* __restrict__ bad) {
    __shared__ uint32_t sh[BW_WPB][3][228];
    const int wb = threadIdx.x >> 5;
    const int t = (blockIdx.x * blockDim.x + threadIdx.x) >> 5; if (t >= nTests) return;
    uint64_t z = seed + (uint64_t)t * 0x9E3779B97F4A7C15ULL; z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL; z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL; z ^= z >> 31;
    const uint64_t s35 = z & ((1ULL << 35) - 1); const int mode = t & 3;
    const int* W = (mode & 1) ? Wg : nullptr; const int fl = (mode & 2) ? ((mode & 1) ? 50 * 256 : 60) : 0;
    const int v = bestOfClassWarp(Pg, W, n, s35, fl, sh[wb][0], sh[wb][1], sh[wb][2]);
    if ((threadIdx.x & 31) == 0 && v != bestOfClassFast(Pg, W, n, s35, fl)) atomicAdd(bad, 1);
}
// FEW-SYNC SPOT (2026-09-22). With 4 workers the GPU was busy only 64% of the time: a spot waited on ~22 host round
// trips and spent ~13 ms of host passes. These kernels move the per-position host work to the GPU - the possible-count
// histograms (position scores and cuts), the ordered family lists, one tagged queue for all positions, one exact pass,
// and the aggregates - so a spot waits 5 times. Host logic that decides results (stable position sort, cut, the
// std::partial_sort family choice) is unchanged; best keeps the old tie rule: highest value, then the earliest
// position, then the smallest class index in it.
__global__ void histKernel(const uint8_t* __restrict__ N15, int* __restrict__ hist) {
    __shared__ int h[256];
    const int pos = blockIdx.y;
    h[threadIdx.x] = 0; __syncthreads();
    const uint8_t* p = N15 + ((size_t)pos << 18) + ((size_t)blockIdx.x << 12);
    for (int i = threadIdx.x; i < 4096; i += 256) atomicAdd(&h[p[i]], 1);
    __syncthreads();
    if (h[threadIdx.x]) atomicAdd(&hist[pos * 256 + threadIdx.x], h[threadIdx.x]);
}
__global__ void __launch_bounds__(1024) compactKernel(const uint8_t* __restrict__ N15, const int* __restrict__ slot, const int* __restrict__ cut,
                                                      uint32_t* __restrict__ base, int* __restrict__ cnt) {
    __shared__ int ws[32]; __shared__ int running, tot;
    const int k = blockIdx.x; const uint8_t* h = N15 + ((size_t)slot[k] << 18); const int c = cut[k];
    uint32_t* out = base + ((size_t)k << 18);
    const int lane = threadIdx.x & 31, wid = threadIdx.x >> 5;
    if (threadIdx.x == 0) running = 0;
    __syncthreads();
    for (int t0 = 0; t0 < (1 << 18); t0 += 1024) {
        const int r = t0 + threadIdx.x; const bool ok = h[r] >= c;
        const unsigned bal = __ballot_sync(0xFFFFFFFFu, ok);
        if (lane == 0) ws[wid] = __popc(bal);
        __syncthreads();
        if (wid == 0) { const int v = ws[lane]; int inc = v;
            #pragma unroll
            for (int off = 1; off < 32; off <<= 1) { const int t = __shfl_up_sync(0xFFFFFFFFu, inc, off); if (lane >= off) inc += t; }
            ws[lane] = inc - v; if (lane == 31) tot = inc; }
        __syncthreads();
        if (ok) out[running + ws[wid] + __popc(bal & ((1u << lane) - 1u))] = (uint32_t)r;
        __syncthreads();
        if (threadIdx.x == 0) running += tot;
        __syncthreads();
    }
    if (threadIdx.x == 0) cnt[k] = running;
}
__global__ void __launch_bounds__(32 * BW_WPB) sampleExactUnionKernel(const uint64_t* __restrict__ Pall, const int* __restrict__ Wg, int n, const uint32_t* __restrict__ sel, int stride, int K,
                                      const unsigned long long* __restrict__ queue, const unsigned int* __restrict__ qCount, unsigned int qCap, int* __restrict__ outBest, int blocksMode, int floorV) {
    __shared__ uint32_t sh[BW_WPB][3][228];
    const int wb = threadIdx.x >> 5;
    const unsigned int nq = min(*qCount, qCap), nw = (gridDim.x * blockDim.x) >> 5;
    for (unsigned int q = (blockIdx.x * blockDim.x + threadIdx.x) >> 5; q < nq; q += nw) {
        const unsigned long long it = queue[q]; const int pos = (int)(it >> 32); const long long g = (long long)(it & 0xFFFFFFFFull);
        const long long fi = g / K; const uint32_t fam = sel[pos * stride + fi];
        const uint32_t c = sampleClass(fam, (uint32_t)(g - fi * K), 1);
        const int v = bestOfClassWarp(Pall + (size_t)pos * n, blocksMode ? Wg : nullptr, n, (uint64_t)fam | ((uint64_t)c << 20), floorV, sh[wb][0], sh[wb][1], sh[wb][2]);
        if ((threadIdx.x & 31) == 0) outBest[q] = v;
    }
}
struct SpotAgg { unsigned int nq, pad; unsigned long long c[4]; unsigned long long bestKey; };
__global__ void aggKernel(const unsigned long long* __restrict__ queue, const unsigned int* __restrict__ qCount, unsigned int qCap, const int* __restrict__ vals,
                          int stride, int K, int blocksMode, SpotAgg* __restrict__ agg, uint8_t* __restrict__ flag66) {
    const unsigned int nq = min(*qCount, qCap);
    const int q64 = blocksMode ? 64 * 256 : 64, q66 = blocksMode ? 66 * 256 : 66, q68 = blocksMode ? 68 * 256 : 68, q70 = blocksMode ? 70 * 256 : 70;
    unsigned long long c0 = 0, c1 = 0, c2 = 0, c3 = 0, bk = 0;
    for (unsigned int q = blockIdx.x * blockDim.x + threadIdx.x; q < nq; q += gridDim.x * blockDim.x) {
        const int v = vals[q]; const unsigned long long it = queue[q]; const int pos = (int)(it >> 32); const unsigned long long g = it & 0xFFFFFFFFull;
        c0 += v >= q64; c1 += v >= q66; c2 += v >= q68; c3 += v >= q70;
        if (v >= q66) flag66[pos * stride + (int)(g / K)] = 1;
        if (v >= 0) { const unsigned long long key = ((unsigned long long)(v + 1) << 28) | ((unsigned long long)(15 - pos) << 24) | ((1ull << 24) - 1 - g); bk = key > bk ? key : bk; }
    }
    if (c0) atomicAdd(&agg->c[0], c0); if (c1) atomicAdd(&agg->c[1], c1); if (c2) atomicAdd(&agg->c[2], c2); if (c3) atomicAdd(&agg->c[3], c3);
    if (bk) atomicMax(&agg->bestKey, bk);
    if (blockIdx.x == 0 && threadIdx.x == 0) agg->nq = *qCount;
}
template <class F> static void parallelFor(int n, F f) {
    std::vector<std::thread> th; th.reserve(n);
    for (int k = 0; k < n; k++) th.emplace_back([&f, k] { f(k); });
    for (auto& t : th) t.join();
}
int main(int argc, char** argv) {
    slimeFixArgv(argc, argv);       // "\" -> "/" off Windows (portable_paths.h)
    selectCudaDevice(argc, argv);   // consumes --device N / SLIME_DEVICE
    std::string spots, out = "prepass.csv"; int K = 512, mode = 0, T = 60, topPositions = 10, posStat = 150, probe = 8, exhaust = 128, blocksMode = 0, y39 = 0; double topPct = 5.0;
    for (int i = 1; i < argc; i++) { std::string k = argv[i]; auto nx = [&]() { return std::string(argv[++i]); };
        if (k == "--spots") spots = nx(); else if (k == "--out") out = nx(); else if (k == "--classes") K = atoi(nx().c_str());
        else if (k == "--top-positions") topPositions = atoi(nx().c_str()); else if (k == "--pos-stat") posStat = atoi(nx().c_str());
        else if (k == "--mode") mode = (nx() == "low") ? 1 : 0; else if (k == "--top-pct") topPct = atof(nx().c_str()); else if (k == "--floor") T = atoi(nx().c_str());
        else if (k == "--probe") probe = atoi(nx().c_str()); else if (k == "--exhaust") exhaust = atoi(nx().c_str());
        else if (k == "--blocks") blocksMode = 1; else if (k == "--y39") { blocksMode = 1; y39 = 1; } }
    if (probe > 0) { K = 32768; mode = 1; }        // probe mode: the chosen families get every class
    if (spots.empty() || K < 256 || K % 256 || K > 32768) { fprintf(stderr, "usage: phase_prepass --spots file --out file [--probe 8 --exhaust 128] [--blocks | --y39] [--classes 512 (multiple of 256)] [--mode random|low] [--floor 60]\n"); return 1; }
    uint8_t mask[17 * 17]; buildSpawnMask(mask); int WT[17 * 17]; buildBlockWeights(WT);
    // --y39: the RAISED-AFK weighting, the one actually measured in game (feet at y -39 over the -64 floor,
    // dy = 24): 24^2 <= a^2 + b^2 + dy^2 <= 128^2 becomes 0 <= a^2 + b^2 <= 15808 - no inner no-spawn circle, outer
    // radius 125.73 (afk_rescan makeRing, calibrated in game: a full floor reads 49,669). The default weighting is
    // slime_core's cq geometry (inner 24, outer 128; cq = blocks / 256).
    if (y39) { int tot = 0;
        for (int dz = -8; dz <= 8; dz++) for (int dx = -8; dx <= 8; dx++) { int w = 0;
            for (int i = 0; i < 16; i++) for (int j = 0; j < 16; j++) { const long long a = 16LL * dx + i, b = 16LL * dz + j;
                if (a * a + b * b <= 15808LL) w++; }
            WT[(dz + 8) * 17 + (dx + 8)] = w; tot += w; }
        printf("y-39 weighting: %d spawn columns in the window (in game: 49,669)\n", tot); }
    std::vector<int> DX, DZ, WH;
    for (int dz = -8; dz <= 8; dz++) for (int dx = -8; dx <= 8; dx++) if (mask[(dz + 8) * 17 + (dx + 8)]) { DX.push_back(dx); DZ.push_back(dz); WH.push_back(WT[(dz + 8) * 17 + (dx + 8)]); }
    // At dy = 24 there is no inner no-spawn circle, so the four chunks touching the AFK column count too -
    // 256 columns each. The spawn mask drops them (at dy = 0 they lie entirely inside the exclusion sphere),
    // so the y-39 window is 226 cells, not 222: without them a full floor reads 48,645, not the in-game
    // 49,669, and two layouts that differ only in the middle score the same.
    if (y39) { for (int i = 0; i < SLIME_EXCLUDED_N; i++) { int ex, ez; excludedCell(i, ex, ez);
            DX.push_back(ex); DZ.push_back(ez); WH.push_back(WT[(ez + 8) * 17 + (ex + 8)]); }
        long long s = 0; for (int w : WH) s += w;
        if (s != 49669) { fprintf(stderr, "y-39 window sums to %lld, not the in-game 49669, aborting\n", s); return 1; } }
    const int n = (int)DX.size();
    uint64_t* dP; uint8_t* dN; int* dW; const unsigned int qCap = 1u << 22;
    CUDA_CHECK(cudaMalloc(&dP, n * 8)); CUDA_CHECK(cudaMalloc(&dN, 1 << 18)); CUDA_CHECK(cudaMalloc(&dW, n * 4));
    CUDA_CHECK(cudaMemcpy(dW, WH.data(), n * 4, cudaMemcpyHostToDevice));
    int nSM = 0; CUDA_CHECK(cudaDeviceGetAttribute(&nSM, cudaDevAttrMultiProcessorCount, 0));
    std::vector<uint32_t> hG(8192, 0);
    for (uint32_t u = 0; u < (1u << 18); u++) if (!(((((uint64_t)(u ^ (uint32_t)(PH_C & 0x3FFFF))) * PH_M + 0xBULL) >> 17) & 1)) hG[u >> 5] |= 1u << (u & 31);
    uint32_t* dG; uint32_t* dPl; uint8_t* dN15;
    CUDA_CHECK(cudaMalloc(&dG, 8192 * 4)); CUDA_CHECK(cudaMalloc(&dPl, 15 * n * 4)); CUDA_CHECK(cudaMalloc(&dN15, 15u << 18));
    CUDA_CHECK(cudaMemcpy(dG, hG.data(), 8192 * 4, cudaMemcpyHostToDevice));
    for (int trial = 0; trial < 4; trial++) {
        std::vector<uint64_t> tp(n); for (int i = 0; i < n; i++) tp[i] = posOffset(12345 + 777777 * trial + DX[i], -6789 - 555555 * trial + DZ[i]);
        std::vector<uint32_t> tl(15 * n); for (int k = 0; k < 15; k++) for (int i = 0; i < n; i++) tl[k * n + i] = (uint32_t)(tp[i] & 0x3FFFF);
        CUDA_CHECK(cudaMemcpy(dP, tp.data(), n * 8, cudaMemcpyHostToDevice)); CUDA_CHECK(cudaMemcpy(dPl, tl.data(), 15 * n * 4, cudaMemcpyHostToDevice));
        possibleKernel<<<(1 << 18) / 256, 256>>>(dP, n, dN); possibleBitKernel<<<dim3(8192 / 256, 15), 256>>>(dG, dPl, n, dN15); CUDA_CHECK(cudaGetLastError());
        std::vector<uint8_t> a(1 << 18), b(15u << 18); CUDA_CHECK(cudaMemcpy(a.data(), dN, 1 << 18, cudaMemcpyDeviceToHost)); CUDA_CHECK(cudaMemcpy(b.data(), dN15, 15u << 18, cudaMemcpyDeviceToHost));
        for (size_t r = 0; r < (15u << 18); r++) if (a[r & 0x3FFFF] != b[r]) { fprintf(stderr, "possible-count self-test FAILED at %zu (%d vs %d)\n", r, a[r & 0x3FFFF], b[r]); return 1; } }
    bsqInitTables();
    {   // warp exact best == bestOfClassFast on random classes, counts and blocks, with and without the floor
        int* dBad; CUDA_CHECK(cudaMalloc(&dBad, 4)); CUDA_CHECK(cudaMemset(dBad, 0, 4)); const int nt = 1 << 15;
        std::vector<uint64_t> tp(n); for (int i = 0; i < n; i++) tp[i] = posOffset(-2345678 + DX[i], 3456789 + DZ[i]);
        CUDA_CHECK(cudaMemcpy(dP, tp.data(), n * 8, cudaMemcpyHostToDevice));
        warpSelfTestKernel<<<nt / BW_WPB, 32 * BW_WPB>>>(dP, dW, n, nt, 0x5EEDF00DULL, dBad); CUDA_CHECK(cudaGetLastError());
        int bad = 0; CUDA_CHECK(cudaMemcpy(&bad, dBad, 4, cudaMemcpyDeviceToHost)); cudaFree(dBad);
        if (bad) { fprintf(stderr, "warp exact-best self-test FAILED: %d of %d classes differ\n", bad, nt); return 1; }
    }
    {   // bit-sliced quarter bound (the exhaust stage) queues exactly what sampleBoundKernel queues: 128 families, 2 floors
        std::vector<uint32_t> tf(128); for (int k = 0; k < 128; k++) tf[k] = (uint32_t)(((uint64_t)k * 16411u + 977u) & 0xFFFFF);
        uint32_t* dTF; unsigned long long *qa, *qb; unsigned int *na, *nb; const unsigned int cap = 1u << 22;
        CUDA_CHECK(cudaMalloc(&dTF, 128 * 4)); CUDA_CHECK(cudaMemcpy(dTF, tf.data(), 128 * 4, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMalloc(&qa, cap * 8ULL)); CUDA_CHECK(cudaMalloc(&qb, cap * 8ULL)); CUDA_CHECK(cudaMalloc(&na, 4)); CUDA_CHECK(cudaMalloc(&nb, 4));
        long long tot = 0;
        for (int Tt : {44, 52}) {
            CUDA_CHECK(cudaMemset(na, 0, 4)); CUDA_CHECK(cudaMemset(nb, 0, 4));
            sampleBoundKernel<<<nSM * 16, 256>>>(dP, n, dTF, 32768, 1, 128LL * 32768, Tt, qa, na, cap);
            phaseBoundBSQKernel<<<nSM * 12, 128>>>(dP, n, dTF, 0, 128LL * 32768, Tt, qb, nb, cap);
            CUDA_CHECK(cudaGetLastError());
            unsigned int ha = 0, hb = 0; CUDA_CHECK(cudaMemcpy(&ha, na, 4, cudaMemcpyDeviceToHost)); CUDA_CHECK(cudaMemcpy(&hb, nb, 4, cudaMemcpyDeviceToHost));
            bool same = ha == hb && ha <= cap;
            if (same && ha) { std::vector<unsigned long long> va(ha), vb(hb);
                CUDA_CHECK(cudaMemcpy(va.data(), qa, ha * 8ULL, cudaMemcpyDeviceToHost)); CUDA_CHECK(cudaMemcpy(vb.data(), qb, hb * 8ULL, cudaMemcpyDeviceToHost));
                std::sort(va.begin(), va.end()); std::sort(vb.begin(), vb.end()); same = va == vb; }
            if (!same) { fprintf(stderr, "bit-sliced bound self-test FAILED at floor %d: %u vs %u queued\n", Tt, ha, hb); return 1; }
            tot += ha;
        }
        cudaFree(dTF); cudaFree(qa); cudaFree(qb); cudaFree(na); cudaFree(nb);
        if (!tot) { fprintf(stderr, "bit-sliced bound self-test queued nothing - test too weak\n"); return 1; }
    }
    CUDA_CHECK(cudaDeviceSynchronize());
    FILE* fi = fopen(spots.c_str(), "r"); FILE* fo = fopen(out.c_str(), "w"); if (!fi || !fo) { fprintf(stderr, "cannot open input/output\n"); return 1; }
    fprintf(fo, "X,Z,best,pairs64,pairs66,pairs68,pairs70,families66,best_dx,best_dz,best_family,seconds\n");
    std::vector<std::pair<long long, long long>> spotList;
    { char line[256]; while (fgets(line, sizeof line, fi)) { long long X, Z; if (sscanf(line, "%lld,%lld", &X, &Z) == 2) spotList.push_back({X, Z}); } }
    fclose(fi);
    // PIPELINE (2026-09-22): host threads (default 3, PP_WORKERS), each with its own stream and buffers, take the next spot; while one
    // does its host work (family lists, sorting, result loops - ~40% of a spot) the other's kernels run. Each spot is
    // computed exactly as before; rows are written in input order.
    struct Worker { cudaStream_t st; uint64_t* dP; uint32_t* dF; unsigned long long* dQ; unsigned int* dQN; int* dB; int* dS;
                    uint64_t* dPall; uint32_t* dFall; int* dFpos; uint32_t* dPl; uint8_t* dN15; std::vector<uint8_t> hN15;
                    int* dHist; int* dSlot; int* dCut; uint32_t* dBase; int* dCnt; uint32_t* dSel; SpotAgg* dAgg; uint8_t* dFlag; };
    const int NW = getenv("PP_WORKERS") ? atoi(getenv("PP_WORKERS")) : 3; std::vector<Worker> wk(NW);
    for (Worker& w : wk) {
        CUDA_CHECK(cudaStreamCreateWithFlags(&w.st, cudaStreamNonBlocking));
        CUDA_CHECK(cudaMalloc(&w.dP, n * 8)); CUDA_CHECK(cudaMalloc(&w.dF, (1 << 20) * 4));
        CUDA_CHECK(cudaMalloc(&w.dQ, qCap * 8ULL)); CUDA_CHECK(cudaMalloc(&w.dQN, 4)); CUDA_CHECK(cudaMalloc(&w.dB, qCap * 4ULL)); CUDA_CHECK(cudaMalloc(&w.dS, 15ULL * (1 << 20) * 4));
        CUDA_CHECK(cudaMalloc(&w.dPall, 15ULL * n * 8)); CUDA_CHECK(cudaMalloc(&w.dFall, 15ULL * (1 << 20) * 4)); CUDA_CHECK(cudaMalloc(&w.dFpos, 15ULL * (1 << 20) * 4));
        CUDA_CHECK(cudaMalloc(&w.dPl, 15 * n * 4)); CUDA_CHECK(cudaMalloc(&w.dN15, 15u << 18)); w.hN15.resize(15u << 18);
        CUDA_CHECK(cudaMalloc(&w.dHist, 15 * 256 * 4)); CUDA_CHECK(cudaMalloc(&w.dSlot, 16 * 4)); CUDA_CHECK(cudaMalloc(&w.dCut, 16 * 4)); CUDA_CHECK(cudaMalloc(&w.dBase, (15ULL << 18) * 4));
        CUDA_CHECK(cudaMalloc(&w.dCnt, 16 * 4)); CUDA_CHECK(cudaMalloc(&w.dSel, 15 * 512 * 4)); CUDA_CHECK(cudaMalloc(&w.dAgg, sizeof(SpotAgg))); CUDA_CHECK(cudaMalloc(&w.dFlag, 15 * 512));
    }
    std::vector<std::string> rows(spotList.size()); std::vector<char> ready(spotList.size(), 0);
    std::atomic<long long> nextSpot(0), nRedo(0); std::mutex mo; size_t nextWrite = 0; long long nSpots = 0;
    auto runSpot = [&](Worker& w, long long X, long long Z) -> std::string {
        cudaStream_t st = w.st; std::vector<unsigned long long> hQ; std::vector<int> hB;
        for (int pass = 0; pass < 2; pass++) {
        const int floorV = pass ? 0 : (blocksMode ? 50 * 256 : 64);
        auto t0 = std::chrono::steady_clock::now();
        const long long pcx = (long long)std::floor(X / 16.0), pcz = (long long)std::floor(Z / 16.0);
        int best = -1, bdx = 0, bdz = 0, bestPos = -1; unsigned long long bestG = 0; uint32_t bfam = 0; long long p64 = 0, p66 = 0, p68 = 0, p70 = 0; std::vector<uint32_t> fam66;
        // the 15 grid positions (dz outer, dx inner - hotspot_scan's order), each with its possible counts; with
        // --top-positions N only the N the EXACT search will visit (ranked like hotspot_scan's adaptive positions:
        // families with >= posStat possible chunks, stable order) are screened - scoring positions it never searches is waste
        struct Pos { int dx, dz; std::vector<uint64_t> P; int slot; long long score; };
        std::vector<Pos> grid; std::vector<uint32_t> pl;
        for (int dz = -3; dz <= 3; dz += 3) for (int dx = -6; dx <= 6; dx += 3) {
            Pos q; q.dx = dx; q.dz = dz; q.slot = (int)grid.size(); q.P.resize(n); for (int i = 0; i < n; i++) { q.P[i] = posOffset(pcx + dx + DX[i], pcz + dz + DZ[i]); pl.push_back((uint32_t)(q.P[i] & 0x3FFFF)); }
            grid.push_back(std::move(q));
        }
        CUDA_CHECK(cudaMemcpyAsync(w.dPl, pl.data(), pl.size() * 4, cudaMemcpyHostToDevice, st));
        possibleBitKernel<<<dim3(8192 / 256, 15), 256, 0, st>>>(dG, w.dPl, n, w.dN15); CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaMemcpyAsync(w.hN15.data(), w.dN15, 15u << 18, cudaMemcpyDeviceToHost, st)); CUDA_CHECK(cudaStreamSynchronize(st));
        // the per-position host passes over the 2^18 counts run on one thread per position and read hN15 in place
        parallelFor(15, [&](int k) { Pos& q = grid[k]; const uint8_t* h = w.hN15.data() + ((size_t)q.slot << 18);
            long long sc = 0; for (int r = 0; r < (1 << 18); r++) sc += h[r] >= posStat; q.score = sc; });
        if (topPositions > 0 && topPositions < (int)grid.size()) {
            std::stable_sort(grid.begin(), grid.end(), [](const Pos& a, const Pos& b) { return a.score > b.score; });
            grid.resize(topPositions);
        }
        const int NP = (int)grid.size();
        std::vector<std::vector<uint32_t>> famsAt(NP); std::vector<int> famOff(NP + 1, 0);
        std::vector<uint64_t> Pall((size_t)NP * n);
        parallelFor(NP, [&](int k) {
            const uint8_t* h = w.hN15.data() + ((size_t)grid[k].slot << 18);
            long long hist[256] = {0}; for (int r = 0; r < (1 << 18); r++) hist[h[r]]++;
            long long want = (long long)std::ceil(topPct / 100.0 * (1 << 18)), acc = 0; int cut = 255; for (int v = 255; v >= 0; v--) { acc += hist[v]; cut = v; if (acc >= want) break; }
            std::vector<uint32_t> base; for (int r = 0; r < (1 << 18); r++) if (h[r] >= cut) base.push_back((uint32_t)r);
            std::vector<uint32_t>& fl = famsAt[k]; fl.reserve(base.size() * 4);
            for (int kk = 0; kk < 4; kk++) for (uint32_t r : base) fl.push_back(r + ((uint32_t)kk << 18));
            std::copy(grid[k].P.begin(), grid[k].P.end(), Pall.begin() + (size_t)k * n);
        });
        for (int k = 0; k < NP; k++) famOff[k + 1] = famOff[k] + (int)famsAt[k].size();
        std::vector<int> scAll;
        if (probe > 0) {
            const int nfAll = famOff[NP];
            std::vector<uint32_t> fa(nfAll); std::vector<int> fp(nfAll);
            for (int k = 0; k < NP; k++) for (int r = famOff[k]; r < famOff[k + 1]; r++) { fa[r] = famsAt[k][r - famOff[k]]; fp[r] = k; }
            CUDA_CHECK(cudaMemcpyAsync(w.dPall, Pall.data(), Pall.size() * 8, cudaMemcpyHostToDevice, st));
            CUDA_CHECK(cudaMemcpyAsync(w.dFall, fa.data(), nfAll * 4ULL, cudaMemcpyHostToDevice, st)); CUDA_CHECK(cudaMemcpyAsync(w.dFpos, fp.data(), nfAll * 4ULL, cudaMemcpyHostToDevice, st));
            CUDA_CHECK(cudaMemsetAsync(w.dS, 0, nfAll * 4ULL, st));
            static const int warpMode = getenv("PP_WARP") ? atoi(getenv("PP_WARP")) : 1;
            if (warpMode) probeWarpKernel<<<(unsigned)(((long long)nfAll * probe + BW_WPB - 1) / BW_WPB), 32 * BW_WPB, 0, st>>>(w.dPall, n, w.dFall, w.dFpos, nfAll, probe, w.dS);
            else probeAllKernel<<<(unsigned)(((long long)nfAll * probe + 127) / 128), 128, 0, st>>>(w.dPall, n, w.dFall, w.dFpos, nfAll, probe, w.dS);
            CUDA_CHECK(cudaGetLastError());
            scAll.resize(nfAll); CUDA_CHECK(cudaMemcpyAsync(scAll.data(), w.dS, nfAll * 4ULL, cudaMemcpyDeviceToHost, st)); CUDA_CHECK(cudaStreamSynchronize(st));
        }
        for (int gk = 0; gk < NP; gk++) {
            auto& q = grid[gk];
            const int dx = q.dx, dz = q.dz; const std::vector<uint64_t>& P = q.P;
            CUDA_CHECK(cudaMemcpyAsync(w.dP, P.data(), n * 8, cudaMemcpyHostToDevice, st));
            std::vector<uint32_t> fams = famsAt[gk];
            if (probe > 0) {                      // probe every kept family with `probe` classes, keep the best `exhaust`
                const int nf = (int)fams.size();
                std::vector<int> sc(scAll.begin() + famOff[gk], scAll.begin() + famOff[gk + 1]);
                std::vector<int> idx(nf); for (int r = 0; r < nf; r++) idx[r] = r;
                const int take = std::min(exhaust, nf);
                std::partial_sort(idx.begin(), idx.begin() + take, idx.end(), [&](int a, int b) { return sc[a] > sc[b]; });
                std::vector<uint32_t> sel(take); for (int r = 0; r < take; r++) sel[r] = fams[idx[r]];
                fams.swap(sel);
            }
            CUDA_CHECK(cudaMemcpyAsync(w.dF, fams.data(), fams.size() * 4, cudaMemcpyHostToDevice, st));
            const long long items = (long long)fams.size() * K;
            CUDA_CHECK(cudaMemsetAsync(w.dQN, 0, 4, st));
            static const int bsq = getenv("PP_BSQ") ? atoi(getenv("PP_BSQ")) : 1;
            if (bsq && K == 32768 && mode == 1) phaseBoundBSQKernel<<<nSM * 12, 128, 0, st>>>(w.dP, n, w.dF, 0, items, T, w.dQ, w.dQN, qCap);
            else sampleBoundKernel<<<nSM * 16, 256, 0, st>>>(w.dP, n, w.dF, K, mode, items, T, w.dQ, w.dQN, qCap);
            CUDA_CHECK(cudaGetLastError());
            unsigned int nq = 0; CUDA_CHECK(cudaMemcpyAsync(&nq, w.dQN, 4, cudaMemcpyDeviceToHost, st)); CUDA_CHECK(cudaStreamSynchronize(st));
            if (nq > qCap) { fprintf(stderr, "queue overflow at (%lld,%lld) - raise --floor\n", X, Z); nq = qCap; }
            if (!nq) continue;
            static const int warpModeE = getenv("PP_WARP_EXACT") ? atoi(getenv("PP_WARP_EXACT")) : 1;
            if (warpModeE) sampleExactWarpKernel<<<(nq + BW_WPB - 1) / BW_WPB, 32 * BW_WPB, 0, st>>>(w.dP, dW, n, w.dF, K, mode, w.dQ, nq, w.dB, blocksMode, floorV);
            else sampleExactFastKernel<<<(nq + 127) / 128, 128, 0, st>>>(w.dP, dW, n, w.dF, K, mode, w.dQ, nq, w.dB, blocksMode, floorV);
            CUDA_CHECK(cudaGetLastError());
            hQ.resize(nq); hB.resize(nq);
            CUDA_CHECK(cudaMemcpyAsync(hQ.data(), w.dQ, nq * 8ULL, cudaMemcpyDeviceToHost, st)); CUDA_CHECK(cudaMemcpyAsync(hB.data(), w.dB, nq * 4ULL, cudaMemcpyDeviceToHost, st));
            CUDA_CHECK(cudaStreamSynchronize(st));
            for (unsigned int q = 0; q < nq; q++) { const int v = hB[q]; const uint32_t f = fams[hQ[q] / K];
                const int q64 = blocksMode ? 64 * 256 : 64, q66 = blocksMode ? 66 * 256 : 66, q68 = blocksMode ? 68 * 256 : 68, q70 = blocksMode ? 70 * 256 : 70;
                p64 += v >= q64; p66 += v >= q66; p68 += v >= q68; p70 += v >= q70; if (v >= q66) fam66.push_back(f);
                if (v > best || (v == best && bestPos == gk && hQ[q] < bestG)) { best = v; bdx = dx; bdz = dz; bfam = f; bestPos = gk; bestG = hQ[q]; } }
        }
        if (!pass && best < floorV) { nRedo++; continue; }
        std::sort(fam66.begin(), fam66.end()); const long long f66 = std::unique(fam66.begin(), fam66.end()) - fam66.begin();
        const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        char buf[256]; snprintf(buf, sizeof buf, "%lld,%lld,%d,%lld,%lld,%lld,%lld,%lld,%d,%d,0x%05X,%.2f\n", X, Z, best, p64, p66, p68, p70, f66, bdx, bdz, bfam, secs);
        return std::string(buf); }
        return std::string();
    };
    // few-sync spot (see FEW-SYNC SPOT at the kernels): same decisions as runSpot; any queue overflow, or a mode the
    // fast path does not cover (no probe, or not all classes in order), runs runSpot instead
    const int SELS = 512;
    auto runSpotFast = [&](Worker& w, long long X, long long Z) -> std::string {
        if (!(probe > 0 && K == 32768 && mode == 1 && exhaust <= SELS)) return runSpot(w, X, Z);
        cudaStream_t st = w.st;
        for (int pass = 0; pass < 2; pass++) {
        const int floorV = pass ? 0 : (blocksMode ? 50 * 256 : 64);
        auto t0 = std::chrono::steady_clock::now();
        const long long pcx = (long long)std::floor(X / 16.0), pcz = (long long)std::floor(Z / 16.0);
        struct Pos { int dx, dz; std::vector<uint64_t> P; int slot; long long score; };
        std::vector<Pos> grid; std::vector<uint32_t> pl;
        for (int dz = -3; dz <= 3; dz += 3) for (int dx = -6; dx <= 6; dx += 3) {
            Pos q; q.dx = dx; q.dz = dz; q.slot = (int)grid.size(); q.P.resize(n); for (int i = 0; i < n; i++) { q.P[i] = posOffset(pcx + dx + DX[i], pcz + dz + DZ[i]); pl.push_back((uint32_t)(q.P[i] & 0x3FFFF)); }
            grid.push_back(std::move(q));
        }
        CUDA_CHECK(cudaMemcpyAsync(w.dPl, pl.data(), pl.size() * 4, cudaMemcpyHostToDevice, st));
        possibleBitKernel<<<dim3(8192 / 256, 15), 256, 0, st>>>(dG, w.dPl, n, w.dN15);
        CUDA_CHECK(cudaMemsetAsync(w.dHist, 0, 15 * 256 * 4, st));
        histKernel<<<dim3(64, 15), 256, 0, st>>>(w.dN15, w.dHist); CUDA_CHECK(cudaGetLastError());
        std::vector<int> hist(15 * 256);
        CUDA_CHECK(cudaMemcpyAsync(hist.data(), w.dHist, 15 * 256 * 4, cudaMemcpyDeviceToHost, st)); CUDA_CHECK(cudaStreamSynchronize(st));
        for (int k = 0; k < 15; k++) { long long sc = 0; for (int v = posStat; v < 256; v++) sc += hist[grid[k].slot * 256 + v]; grid[k].score = sc; }
        if (topPositions > 0 && topPositions < (int)grid.size()) {
            std::stable_sort(grid.begin(), grid.end(), [](const Pos& a, const Pos& b) { return a.score > b.score; });
            grid.resize(topPositions);
        }
        const int NP = (int)grid.size();
        std::vector<int> slots(NP), cuts(NP);
        for (int k = 0; k < NP; k++) {
            const int* h = hist.data() + grid[k].slot * 256;
            long long want = (long long)std::ceil(topPct / 100.0 * (1 << 18)), acc = 0; int cut = 255; for (int v = 255; v >= 0; v--) { acc += h[v]; cut = v; if (acc >= want) break; }
            slots[k] = grid[k].slot; cuts[k] = cut;
        }
        CUDA_CHECK(cudaMemcpyAsync(w.dSlot, slots.data(), NP * 4, cudaMemcpyHostToDevice, st)); CUDA_CHECK(cudaMemcpyAsync(w.dCut, cuts.data(), NP * 4, cudaMemcpyHostToDevice, st));
        compactKernel<<<NP, 1024, 0, st>>>(w.dN15, w.dSlot, w.dCut, w.dBase, w.dCnt); CUDA_CHECK(cudaGetLastError());
        std::vector<int> cnt(NP);
        CUDA_CHECK(cudaMemcpyAsync(cnt.data(), w.dCnt, NP * 4, cudaMemcpyDeviceToHost, st)); CUDA_CHECK(cudaStreamSynchronize(st));
        std::vector<std::vector<uint32_t>> base(NP);
        for (int k = 0; k < NP; k++) { base[k].resize(cnt[k]); if (cnt[k]) CUDA_CHECK(cudaMemcpyAsync(base[k].data(), w.dBase + ((size_t)k << 18), cnt[k] * 4ULL, cudaMemcpyDeviceToHost, st)); }
        std::vector<uint64_t> Pall((size_t)NP * n);
        for (int k = 0; k < NP; k++) std::copy(grid[k].P.begin(), grid[k].P.end(), Pall.begin() + (size_t)k * n);
        CUDA_CHECK(cudaMemcpyAsync(w.dPall, Pall.data(), Pall.size() * 8, cudaMemcpyHostToDevice, st));
        CUDA_CHECK(cudaStreamSynchronize(st));
        std::vector<std::vector<uint32_t>> famsAt(NP); std::vector<int> famOff(NP + 1, 0);
        for (int k = 0; k < NP; k++) { std::vector<uint32_t>& fl = famsAt[k]; fl.reserve(base[k].size() * 4);
            for (int kk = 0; kk < 4; kk++) for (uint32_t r : base[k]) fl.push_back(r + ((uint32_t)kk << 18));
            famOff[k + 1] = famOff[k] + (int)fl.size(); }
        const int nfAll = famOff[NP];
        std::vector<uint32_t> fa(nfAll); std::vector<int> fp(nfAll);
        for (int k = 0; k < NP; k++) for (int r = famOff[k]; r < famOff[k + 1]; r++) { fa[r] = famsAt[k][r - famOff[k]]; fp[r] = k; }
        CUDA_CHECK(cudaMemcpyAsync(w.dFall, fa.data(), nfAll * 4ULL, cudaMemcpyHostToDevice, st)); CUDA_CHECK(cudaMemcpyAsync(w.dFpos, fp.data(), nfAll * 4ULL, cudaMemcpyHostToDevice, st));
        CUDA_CHECK(cudaMemsetAsync(w.dS, 0, nfAll * 4ULL, st));
        if (nfAll) probeWarpKernel<<<(unsigned)(((long long)nfAll * probe + BW_WPB - 1) / BW_WPB), 32 * BW_WPB, 0, st>>>(w.dPall, n, w.dFall, w.dFpos, nfAll, probe, w.dS);
        CUDA_CHECK(cudaGetLastError());
        std::vector<int> scAll(nfAll); CUDA_CHECK(cudaMemcpyAsync(scAll.data(), w.dS, nfAll * 4ULL, cudaMemcpyDeviceToHost, st)); CUDA_CHECK(cudaStreamSynchronize(st));
        std::vector<std::vector<uint32_t>> sels(NP); std::vector<uint32_t> selAll((size_t)NP * SELS, 0);
        for (int gk = 0; gk < NP; gk++) {
            const std::vector<uint32_t>& fams = famsAt[gk]; const int nf = (int)fams.size();
            std::vector<int> sc(scAll.begin() + famOff[gk], scAll.begin() + famOff[gk + 1]);
            std::vector<int> idx(nf); for (int r = 0; r < nf; r++) idx[r] = r;
            const int take = std::min(exhaust, nf);
            std::partial_sort(idx.begin(), idx.begin() + take, idx.end(), [&](int a, int b) { return sc[a] > sc[b]; });
            sels[gk].resize(take); for (int r = 0; r < take; r++) { sels[gk][r] = fams[idx[r]]; selAll[(size_t)gk * SELS + r] = fams[idx[r]]; }
        }
        CUDA_CHECK(cudaMemcpyAsync(w.dSel, selAll.data(), selAll.size() * 4, cudaMemcpyHostToDevice, st));
        CUDA_CHECK(cudaMemsetAsync(w.dQN, 0, 4, st)); CUDA_CHECK(cudaMemsetAsync(w.dAgg, 0, sizeof(SpotAgg), st)); CUDA_CHECK(cudaMemsetAsync(w.dFlag, 0, (size_t)NP * SELS, st));
        for (int gk = 0; gk < NP; gk++) { const long long items = (long long)sels[gk].size() * K; if (!items) continue;
            phaseBoundBSQKernel<<<nSM * 12, 128, 0, st>>>(w.dPall + (size_t)gk * n, n, w.dSel + (size_t)gk * SELS, 0, items, T, w.dQ, w.dQN, qCap, (unsigned long long)gk << 32); }
        sampleExactUnionKernel<<<nSM * 24, 32 * BW_WPB, 0, st>>>(w.dPall, dW, n, w.dSel, SELS, K, w.dQ, w.dQN, qCap, w.dB, blocksMode, floorV);
        aggKernel<<<nSM * 8, 256, 0, st>>>(w.dQ, w.dQN, qCap, w.dB, SELS, K, blocksMode, w.dAgg, w.dFlag); CUDA_CHECK(cudaGetLastError());
        SpotAgg ag; std::vector<uint8_t> flag((size_t)NP * SELS);
        CUDA_CHECK(cudaMemcpyAsync(&ag, w.dAgg, sizeof ag, cudaMemcpyDeviceToHost, st)); CUDA_CHECK(cudaMemcpyAsync(flag.data(), w.dFlag, flag.size(), cudaMemcpyDeviceToHost, st));
        CUDA_CHECK(cudaStreamSynchronize(st));
        if (ag.nq > qCap) return runSpot(w, X, Z);
        int best = -1, bdx = 0, bdz = 0; uint32_t bfam = 0;
        if (ag.bestKey) { best = (int)(ag.bestKey >> 28) - 1; const int pos = 15 - (int)((ag.bestKey >> 24) & 15); const unsigned long long g = (1ull << 24) - 1 - (ag.bestKey & 0xFFFFFF);
            bdx = grid[pos].dx; bdz = grid[pos].dz; bfam = sels[pos][g / K]; }
        if (!pass && best < floorV) { nRedo++; continue; }
        std::vector<uint32_t> fam66;
        for (int gk = 0; gk < NP; gk++) for (int r = 0; r < (int)sels[gk].size(); r++) if (flag[(size_t)gk * SELS + r]) fam66.push_back(sels[gk][r]);
        std::sort(fam66.begin(), fam66.end()); const long long f66 = std::unique(fam66.begin(), fam66.end()) - fam66.begin();
        const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        char buf[256]; snprintf(buf, sizeof buf, "%lld,%lld,%d,%lld,%lld,%lld,%lld,%lld,%d,%d,0x%05X,%.2f\n", X, Z, best, (long long)ag.c[0], (long long)ag.c[1], (long long)ag.c[2], (long long)ag.c[3], f66, bdx, bdz, bfam, secs);
        return std::string(buf); }
        return std::string();
    };
    static const int fastMode = getenv("PP_FAST") ? atoi(getenv("PP_FAST")) : 1;
    std::vector<std::thread> th;
    for (int t = 0; t < NW; t++) th.emplace_back([&, t] {
        for (;;) {
            const long long i = nextSpot++; if (i >= (long long)spotList.size()) break;
            std::string r = fastMode ? runSpotFast(wk[t], spotList[i].first, spotList[i].second) : runSpot(wk[t], spotList[i].first, spotList[i].second);
            std::lock_guard<std::mutex> g(mo); rows[i] = r; ready[i] = 1;
            while (nextWrite < rows.size() && ready[nextWrite]) { fputs(rows[nextWrite].c_str(), fo); nextWrite++; if (++nSpots % 50 == 0) { printf("  %lld spots\n", nSpots); fflush(stdout); } }
            fflush(fo);
        }
    });
    for (auto& t : th) t.join();
    fclose(fo); printf("%lld spots -> %s (%lld re-run exactly below the floor)\n", nSpots, out.c_str(), (long long)nRedo);
    return 0;
}

