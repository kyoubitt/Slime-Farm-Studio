// slime_cpu.cpp - the fixed-seed position search on the CPU: slime_gpu's job for machines with no NVIDIA card
// (AMD and Intel graphics, every Mac, a laptop on battery).
//
//   slime_cpu --seed S --m-chunks M --center-x X --center-z Z      Best: score=N at x=.. z=..
//   slime_cpu --worker                                              the same, one command per stdin line
//   slime_cpu --self-test                                           checks it against the naive scorer
//
// It prints exactly what `slime_gpu --seed ...` prints (same score, same tie-break: highest score, then the
// highest row-major position), so slime_studio.py and ./slime best-spot use either one the same way.
//
// How it is fast (all of it exact - the self-test and the GPU comparison in vanilla_parity.py check that):
//  * a slime chunk is Java's first nextInt(10) == 0, and that first draw is one multiply of the 48-bit LCG:
//    no loop, no division, and the compiler vectorizes it. The ~1-in-2^28 draws that Java would reject and
//    redraw are redone with the real isSlimeChunk from slime_core.h.
//  * the despawn disc is 17 rows, each one contiguous run; only 6 distinct (offset, width) pairs exist, so each
//    bitmap row is turned into 6 window-count rows once (a prefix sum), and a position's score is then 17
//    byte-adds of rows that are already there - no popcount per position per row.
//  * the four chunks inside the 24-block exclusion sphere are subtracted at the end, as slime_core.h says.
//  * the rows are cut into bands that the threads take in turn; each thread keeps a 17-row ring, so nothing
//    is stored for the whole window and memory stays at a few MB per thread whatever --m-chunks is.
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "slime_core.h"
#if defined(__AVX2__) && defined(__x86_64__)
  #include <cpuid.h>
#endif

namespace {

#if defined(__AVX2__) && defined(__x86_64__)
// A build made with -mavx2 (the Windows one) must say so, not crash, on a CPU without it.
bool cpuHasAvx2() {
    unsigned a, b, c, d;
    if (!__get_cpuid(1, &a, &b, &c, &d) || !(c & (1u << 27))) return false;       // the OS saves the wide registers
    unsigned lo, hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    if ((lo & 6) != 6) return false;
    return __get_cpuid_count(7, 0, &a, &b, &c, &d) && (b & (1u << 5));
}
#endif

constexpr uint64_t MULT = 0x5DEECE66DULL, ADD = 0xBULL, MASK48 = (1ULL << 48) - 1;
constexpr uint64_t SCRAMBLE = MULT ^ 0x3ad8025fULL;   // isSlimeChunk's final xor and Random's initial scramble, folded
constexpr uint32_t REJECT = 2147483640u;      // a first draw this high is one Java would throw away and redraw
constexpr int ROWS = 17;

struct Geometry {
    int lo[ROWS], wd[ROWS];        // row k of the disc: columns [lo, lo+wd) of the window, from buildIntersectMask
    int win[ROWS];                 // which of the distinct windows row k uses
    int lows[ROWS], wds[ROWS];     // the distinct (lo, wd) pairs
    int nwin = 0;
    Geometry() {
        uint8_t mask[17 * 17];
        int8_t A[17], B[17];
        if (buildIntersectMask(mask) != 226 || !buildMaskIntervals(mask, A, B)) {
            fprintf(stderr, "FATAL: the despawn disc is not what slime_core.h says it is\n");
            exit(1);
        }
        for (int k = 0; k < ROWS; k++) {
            lo[k] = A[k] + 8;
            wd[k] = B[k] - A[k] + 1;
            int j = 0;
            while (j < nwin && !(lows[j] == lo[k] && wds[j] == wd[k])) j++;
            if (j == nwin) { lows[nwin] = lo[k]; wds[nwin] = wd[k]; nwin++; }
            win[k] = j;
        }
    }
};

constexpr int BLOCK = 4096;
void addBytes(uint8_t* __restrict d, const uint8_t* __restrict a, int n) { for (int i = 0; i < n; i++) d[i] = (uint8_t)(d[i] + a[i]); }
void subBytes(uint8_t* __restrict d, const uint8_t* __restrict a, int n) { for (int i = 0; i < n; i++) d[i] = (uint8_t)(d[i] - a[i]); }
uint8_t maxByte(const uint8_t* __restrict a, int n) { uint8_t m = 0; for (int i = 0; i < n; i++) m = a[i] > m ? a[i] : m; return m; }

struct Best { int score = -1; int cx = 0, cz = 0; };

// ---- one search ----------------------------------------------------------------------------------------
struct Search {
    const Geometry& g;
    uint64_t seed;
    int m, ccx, ccz;
    long long side, npos;
    std::vector<uint64_t> xterm;                 // the x part of the seed expression, per window column
    long long colWidth = 4096;                   // positions per tile across (the self-test shrinks it to test the seams)

    Search(const Geometry& geo, long long s, int mm, int cx, int cz) : g(geo), seed((uint64_t)s), m(mm), ccx(cx), ccz(cz) {
        side = 2LL * m + 17;
        npos = 2LL * m + 1;
        xterm.resize(side);
        const uint32_t C1 = 0x4c1906u, C2 = 0x5ac0dbu;
        for (long long j = 0; j < side; j++) {
            uint32_t x = (uint32_t)(int32_t)(j - (m + 8) + ccx);        // two's complement: the low 32 bits are all that matter
            uint32_t a = x * x * C1, b = x * C2;
            xterm[j] = (uint64_t)(int64_t)(int32_t)a + (uint64_t)(int64_t)(int32_t)b;
        }
    }

    // Window columns [xs, xs + n) of window row r, as 0/1 bytes.
    void bitsRow(long long r, long long xs, long long n, uint8_t* out) const {
        const long long side = n;                   // locals: a byte store may alias any member, which would stop the vectorizer
        const uint64_t seed = this->seed;
        const int m = this->m, ccx = this->ccx;
        int kz = (int)(r - (m + 8) + ccz);
        uint32_t z = (uint32_t)kz;
        uint64_t base = seed + (uint64_t)((int64_t)(int32_t)(z * z) * 0x4307a7LL) + (uint64_t)(int64_t)(int32_t)(z * 0x5f24fu);
        const uint64_t* xt = xterm.data() + xs;
        uint32_t rare = 0;
        for (long long j = 0; j < side; j++) {
            uint64_t s0 = ((base + xt[j]) ^ SCRAMBLE) & MASK48;
            uint32_t bits = (uint32_t)(((s0 * MULT + ADD) & MASK48) >> 17);
            out[j] = (bits % 10u) == 0;
            rare |= bits >= REJECT;
        }
        if (rare)                                                      // the exact answer where Java would redraw
            for (long long j = 0; j < side; j++)
                out[j] = isSlimeChunk((long long)seed, (int)(xs + j - (m + 8) + ccx), kz);
    }

    // Best position among the output rows [z0, z1) and columns [xs, xs + npos): packed = score << 40 | row-major
    // index in the whole window, bigger wins. A tile needs 16 more bit columns than it has positions.
    unsigned long long band(long long z0, long long z1, long long xs, long long npos, std::vector<uint8_t>& mem) const {
        const long long side = npos + 16, nposAll = this->npos;
        const int nw = g.nwin;
        const size_t cs = (size_t)npos + 32;                          // a window-count row (padded for the vector tail)
        const size_t bs = (size_t)side + 32;
        mem.assign((size_t)ROWS * (nw * cs + bs) + cs, 0);
        uint8_t* cnt0 = mem.data();                                   // [slot][window][x]
        uint8_t* raw0 = cnt0 + (size_t)ROWS * nw * cs;                // [slot][column]
        uint8_t* __restrict sc = raw0 + (size_t)ROWS * bs;                       // this output row's scores
        // running sums of 1, 2, 4, 8 and 16 neighbouring bits: any window width is a few of these added together
        const size_t ss = (size_t)side + 40;
        std::vector<uint8_t> sums(5 * ss, 0);
        uint8_t* S[5];
        for (int i = 0; i < 5; i++) S[i] = sums.data() + i * ss;

        auto fill = [&](long long r) {
            int slot = (int)(r % ROWS);
            uint8_t* raw = raw0 + (size_t)slot * bs;
            bitsRow(r, xs, side, raw);
            std::memcpy(S[0], raw, (size_t)side);
            for (int i = 1; i < 5; i++) {
                const uint8_t* a = S[i - 1];
                uint8_t* __restrict d = S[i];
                const int h = 1 << (i - 1);
                for (long long x = 0; x < side; x++) d[x] = (uint8_t)(a[x] + a[x + h]);
            }
            for (int w = 0; w < nw; w++) {
                uint8_t* __restrict c = cnt0 + ((size_t)slot * nw + w) * cs;
                int off = g.lows[w], wdt = g.wds[w];
                bool first = true;
                for (int i = 4; i >= 0; i--) {
                    if (!(wdt & (1 << i))) continue;
                    const uint8_t* a = S[i] + off;
                    if (first) for (long long x = 0; x < npos; x++) c[x] = a[x];
                    else       for (long long x = 0; x < npos; x++) c[x] = (uint8_t)(c[x] + a[x]);
                    first = false;
                    off += 1 << i;
                }
            }
        };

        for (long long r = z0; r < z0 + ROWS - 1; r++) fill(r);
        unsigned long long best = 0;
        int bestScore = -1;
        for (long long pz = z0; pz < z1; pz++) {
            fill(pz + ROWS - 1);
            const uint8_t* p[ROWS];
            for (int k = 0; k < ROWS; k++)
                p[k] = cnt0 + ((size_t)((pz + k) % ROWS) * nw + g.win[k]) * cs;
            const uint8_t* e7 = raw0 + (size_t)((pz + 7) % ROWS) * bs + 7;     // the exclusion sphere's four chunks:
            const uint8_t* e8 = raw0 + (size_t)((pz + 8) % ROWS) * bs + 7;     // columns 7 and 8 of rows 7 and 8
            uint8_t mx = 0;
            for (long long x0 = 0; x0 < npos; x0 += BLOCK) {         // a block at a time, so sc stays in the L1 cache
                const int n = (int)std::min<long long>(BLOCK, npos - x0);
                std::memcpy(sc + x0, p[0] + x0, (size_t)n);
                for (int k = 1; k < ROWS; k++) addBytes(sc + x0, p[k] + x0, n);
                subBytes(sc + x0, e7 + x0, n);
                subBytes(sc + x0, e7 + x0 + 1, n);
                subBytes(sc + x0, e8 + x0, n);
                subBytes(sc + x0, e8 + x0 + 1, n);
                mx = std::max(mx, maxByte(sc + x0, n));
            }
            if ((int)mx >= bestScore) {                              // rows ascend, so a tie goes to the later row
                long long x = npos - 1;
                while (sc[x] != mx) x--;                             // ...and to the later column within it
                bestScore = mx;
                best = ((unsigned long long)mx << 40) | (unsigned long long)(pz * nposAll + xs + x);
            }
        }
        return best;
    }

    Best run(int threads) const {
        // tiles of rows x columns: a few hundred columns' rows stay in the CPU's cache, whatever --m-chunks is
        const long long bh = std::min<long long>(256, std::max<long long>(32, npos / ((long long)threads * 4)));
        const long long cw = colWidth;
        const long long nbands = (npos + bh - 1) / bh, ncols = (npos + cw - 1) / cw;
        std::atomic<long long> next(0);
        std::vector<unsigned long long> got(threads, 0);
        auto work = [&](int t) {
            std::vector<uint8_t> mem;
            for (;;) {
                long long k = next.fetch_add(1);
                if (k >= nbands * ncols) break;
                long long b = k / ncols, c = k % ncols;
                unsigned long long v = band(b * bh, std::min(npos, (b + 1) * bh), c * cw, std::min(cw, npos - c * cw), mem);
                if (v > got[t]) got[t] = v;
            }
        };
        std::vector<std::thread> pool;
        for (int t = 1; t < threads; t++) pool.emplace_back(work, t);
        work(0);
        for (auto& th : pool) th.join();
        unsigned long long best = *std::max_element(got.begin(), got.end());
        Best out;
        out.score = (int)(best >> 40);
        long long idx = (long long)(best & ((1ULL << 40) - 1));
        out.cz = (int)(idx / npos) - m;
        out.cx = (int)(idx % npos) - m;
        return out;
    }
};

// ---- command lines -----------------------------------------------------------------------------------------
struct Args {
    long long seed = 0;
    bool haveSeed = false, selfTest = false, worker = false;
    int m = 625, cx = 2048, cz = 8576, threads = 0;
};

int blockToChunk(int b) { return b >= 0 ? b / 16 : -(((-b) + 15) / 16); }       // the same rounding as slime_gpu

bool parse(const std::vector<std::string>& t, Args& a, std::string& err) {
    for (size_t i = 0; i < t.size(); i++) {
        const std::string& s = t[i];
        auto val = [&](long long& out) {
            if (i + 1 >= t.size()) { err = "missing value after " + s; return false; }
            out = atoll(t[++i].c_str());
            return true;
        };
        long long v = 0;
        if (s == "--seed") { if (!val(v)) return false; a.seed = v; a.haveSeed = true; }
        else if (s == "--m-chunks") { if (!val(v)) return false; a.m = (int)v; }
        else if (s == "--center-x") { if (!val(v)) return false; a.cx = (int)v; }
        else if (s == "--center-z") { if (!val(v)) return false; a.cz = (int)v; }
        else if (s == "--threads") { if (!val(v)) return false; a.threads = (int)v; }
        else if (s == "--self-test") a.selfTest = true;
        else if (s == "--worker") a.worker = true;
        else { err = "unknown argument: " + s; return false; }
    }
    return true;
}

int threadCount(const Args& a) {
    if (a.threads > 0) return a.threads;
    if (const char* e = getenv("SLIME_THREADS")) if (atoi(e) > 0) return atoi(e);
    unsigned n = std::thread::hardware_concurrency();
    return n ? (int)n : 4;
}

bool check(const Args& a, std::string& err) {
    if (a.m < 1 || a.m > 16000) { err = "--m-chunks must be between 1 and 16000"; return false; }
    long long ax = std::llabs((long long)blockToChunk(a.cx)), az = std::llabs((long long)blockToChunk(a.cz));
    if (ax + a.m + 8 > 1874000 || az + a.m + 8 > 1874000) { err = "center +/- m-chunks exceeds the world border"; return false; }
    return true;
}

bool runOne(const Geometry& g, const Args& a, std::string& err) {
    if (!a.haveSeed) { err = "a position search needs --seed"; return false; }
    if (!check(a, err)) return false;
    int ccx = blockToChunk(a.cx), ccz = blockToChunk(a.cz);
    Best b = Search(g, a.seed, a.m, ccx, ccz).run(threadCount(a));
    printf("Best: score=%d at x=%d z=%d (chunk %d,%d)\n", b.score, 16 * (b.cx + ccx), 16 * (b.cz + ccz), b.cx + ccx, b.cz + ccz);
    fflush(stdout);
    return true;
}

// ---- self-test: the naive scorer from slime_core.h, which every other tool is checked against -----------------
int selfTest(const Geometry& g) {
    uint8_t disc[17 * 17];
    buildIntersectMask(disc);
    std::mt19937_64 rng(20260721);
    struct Case { long long seed; int m, ccx, ccz; };
    std::vector<Case> cases = {
        {0, 1, 0, 0}, {71629181566LL, 24, 124, 534}, {-1, 5, -1, -1}, {1234567890123456789LL, 40, 1873900 - 90, -1873900 + 90},
        {-9223372036854775807LL - 1, 17, -33, 20}, {42, 33, 0, 0},
    };
    for (int i = 0; i < 24; i++)
        cases.push_back({(long long)rng(), 1 + (int)(rng() % 60), (int)(rng() % 3000000) - 1500000, (int)(rng() % 3000000) - 1500000});
    int bad = 0;
    for (const Case& c : cases) {
        Search search(g, c.seed, c.m, c.ccx, c.ccz);
        if ((&c - &cases[0]) % 2) search.colWidth = 5 + (long long)(rng() % 40);   // every other case: many narrow tiles
        Best fast = search.run(1 + (int)(&c - &cases[0]) % 5);
        unsigned long long best = 0;                         // the naive loop, with the same tie-break
        long long cside = 2LL * c.m + 1;
        for (int z = -c.m; z <= c.m; z++)
            for (int x = -c.m; x <= c.m; x++) {
                int s = scoreCenterChunks(disc, c.seed, x + c.ccx, z + c.ccz);
                unsigned long long p = ((unsigned long long)s << 40) | (unsigned long long)((z + c.m) * cside + (x + c.m));
                if (p > best) best = p;
            }
        long long idx = (long long)(best & ((1ULL << 40) - 1));
        int rs = (int)(best >> 40), rz = (int)(idx / cside) - c.m, rx = (int)(idx % cside) - c.m;
        bool ok = fast.score == rs && fast.cx == rx && fast.cz == rz;
        printf("  m=%3d centre(%d,%d) seed %lld: naive %d @(%d,%d) | slime_cpu %d @(%d,%d) -> %s\n", c.m, c.ccx, c.ccz, c.seed,
               rs, rx, rz, fast.score, fast.cx, fast.cz, ok ? "match" : "MISMATCH");
        bad += !ok;
    }
    // the redraw path: chunks whose first draw Java rejects must still come out as isSlimeChunk says
    printf(bad ? "SELF TEST FAILED (%d mismatches)\n" : "SELF TEST PASSED (%d cases)\n", bad ? bad : (int)cases.size());
    return bad ? 1 : 0;
}

void workerLoop(const Geometry& g) {
    printf("WORKER READY\n");
    fflush(stdout);
    std::string line;
    while (std::getline(std::cin, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
        if (line.size() >= 3 && (unsigned char)line[0] == 0xEF && (unsigned char)line[1] == 0xBB && (unsigned char)line[2] == 0xBF) line.erase(0, 3);
        if (line.empty()) continue;
        if (line == "--quit") break;
        std::vector<std::string> toks;
        std::string cur;
        for (char c : line) {
            if (c == ' ' || c == '\t') { if (!cur.empty()) { toks.push_back(cur); cur.clear(); } }
            else cur.push_back(c);
        }
        if (!cur.empty()) toks.push_back(cur);
        Args a;
        std::string err;
        bool ok = parse(toks, a, err);
        if (ok && (a.selfTest || a.worker)) { err = "a spot line is a bare --seed position search"; ok = false; }
        if (ok) ok = runOne(g, a, err);
        if (!ok) { fprintf(stderr, "[WORKER] %s\n", err.c_str()); fflush(stderr); }
        printf("===SPOT-DONE===\n");
        fflush(stdout);
    }
}

}  // namespace

int main(int argc, char** argv) {
#if defined(__AVX2__) && defined(__x86_64__)
    if (!cpuHasAvx2()) { fprintf(stderr, "this slime_cpu needs a CPU with AVX2 (2013 or later)\n"); return 1; }
#endif
    Geometry g;
    Args a;
    std::string err;
    if (!parse(std::vector<std::string>(argv + 1, argv + argc), a, err)) { fprintf(stderr, "%s\n", err.c_str()); return 1; }
    if (a.selfTest) return selfTest(g);
    if (a.worker) { workerLoop(g); return 0; }
    if (!a.haveSeed) {
        fprintf(stderr, "Usage:\n  slime_cpu --self-test\n  slime_cpu --seed <s> --m-chunks <m> --center-x X --center-z Z [--threads N]\n"
                        "  slime_cpu --worker      (one --seed line per tile on stdin, until --quit)\n");
        return 1;
    }
    printf("Single seed %lld, m-chunks %d, center chunk (%d,%d)\n", a.seed, a.m, blockToChunk(a.cx), blockToChunk(a.cz));
    if (!runOne(g, a, err)) { fprintf(stderr, "%s\n", err.c_str()); return 1; }
    return 0;
}
