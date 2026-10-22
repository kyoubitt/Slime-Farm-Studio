// slime_cl.cpp - the fixed-seed position search on any graphics card with an OpenCL driver (AMD, Intel, Apple,
// and NVIDIA too): slime_gpu's job without CUDA.
//
//   slime_cl --seed S --m-chunks M --center-x X --center-z Z       Best: score=N at x=.. z=..
//   slime_cl --worker                                               the same, one command per stdin line
//   slime_cl --self-test                                            checks the card against the naive scorer
//   slime_cl --list                                                 the OpenCL devices it can see
//   --device N (or SLIME_CL_DEVICE=N) picks a device from that list.
//
// Same output, same tie-break (highest score, then the highest row-major position) as slime_gpu and slime_cpu.
// Nothing to install or link: the OpenCL driver the graphics card already came with is opened at run time, and if
// there is none, or the card gets a different answer from the CPU on the start-up check, this exits with an error
// and the app uses slime_cpu instead.
//
// Two kernels, like slime_gpu: one turns the window into rows of slime-chunk bits (one work item per 32-chunk
// word), one scores 32 neighbouring positions per work item with a popcount per disc row, subtracts the four
// chunks inside the 24-block exclusion sphere, and keeps the best (score << 40 | position) per work group. The
// host takes the maximum of those, so no 64-bit atomics are needed. Long windows go through in row bands.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <random>
#include <string>
#include <vector>

#ifdef _WIN32
  #include <windows.h>
  #define OPEN_LIB(n) ((void*)LoadLibraryA(n))
  #define LIB_SYM(h, n) ((void*)GetProcAddress((HMODULE)(h), n))
  #define CL_CALL __stdcall
#else
  #include <dlfcn.h>
  #define OPEN_LIB(n) dlopen(n, RTLD_NOW)
  #define LIB_SYM(h, n) dlsym(h, n)
  #define CL_CALL
#endif

#include "slime_core.h"

namespace {

// ---- the few OpenCL calls we use, declared here so no SDK is needed to build ---------------------------------
typedef int32_t cl_int;
typedef uint32_t cl_uint;
typedef uint64_t cl_ulong;
typedef void* cl_handle;
constexpr cl_uint CL_DEVICE_TYPE_GPU = 1u << 2, CL_DEVICE_TYPE_ALL = 0xFFFFFFFFu;
constexpr cl_uint CL_DEVICE_NAME = 0x102B, CL_DEVICE_MAX_COMPUTE_UNITS = 0x1002, CL_DEVICE_TYPE = 0x1000;
constexpr cl_uint CL_PROGRAM_BUILD_LOG = 0x1183;
constexpr cl_ulong CL_MEM_READ_WRITE = 1;

struct CL {
    cl_int (CL_CALL *GetPlatformIDs)(cl_uint, cl_handle*, cl_uint*);
    cl_int (CL_CALL *GetDeviceIDs)(cl_handle, cl_ulong, cl_uint, cl_handle*, cl_uint*);
    cl_int (CL_CALL *GetDeviceInfo)(cl_handle, cl_uint, size_t, void*, size_t*);
    cl_handle (CL_CALL *CreateContext)(const void*, cl_uint, const cl_handle*, void*, void*, cl_int*);
    cl_handle (CL_CALL *CreateCommandQueue)(cl_handle, cl_handle, cl_ulong, cl_int*);
    cl_handle (CL_CALL *CreateProgramWithSource)(cl_handle, cl_uint, const char**, const size_t*, cl_int*);
    cl_int (CL_CALL *BuildProgram)(cl_handle, cl_uint, const cl_handle*, const char*, void*, void*);
    cl_int (CL_CALL *GetProgramBuildInfo)(cl_handle, cl_handle, cl_uint, size_t, void*, size_t*);
    cl_handle (CL_CALL *CreateKernel)(cl_handle, const char*, cl_int*);
    cl_handle (CL_CALL *CreateBuffer)(cl_handle, cl_ulong, size_t, void*, cl_int*);
    cl_int (CL_CALL *SetKernelArg)(cl_handle, cl_uint, size_t, const void*);
    cl_int (CL_CALL *EnqueueNDRangeKernel)(cl_handle, cl_handle, cl_uint, const size_t*, const size_t*, const size_t*, cl_uint, const cl_handle*, cl_handle*);
    cl_int (CL_CALL *EnqueueReadBuffer)(cl_handle, cl_handle, cl_uint, size_t, size_t, void*, cl_uint, const cl_handle*, cl_handle*);
    cl_int (CL_CALL *Finish)(cl_handle);
    cl_int (CL_CALL *ReleaseMemObject)(cl_handle);

    bool load(std::string& err) {
        const char* names[] = {
#ifdef _WIN32
            "OpenCL.dll",
#elif defined(__APPLE__)
            "/System/Library/Frameworks/OpenCL.framework/OpenCL",
#else
            "libOpenCL.so.1", "libOpenCL.so",
#endif
        };
        void* h = nullptr;
        for (const char* n : names) if ((h = OPEN_LIB(n))) break;
        if (!h) { err = "no OpenCL driver found (no libOpenCL)"; return false; }
        bool ok = true;
        auto get = [&](auto& fn, const char* sym) { fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(LIB_SYM(h, sym)); ok &= fn != nullptr; };
        get(GetPlatformIDs, "clGetPlatformIDs");         get(GetDeviceIDs, "clGetDeviceIDs");
        get(GetDeviceInfo, "clGetDeviceInfo");           get(CreateContext, "clCreateContext");
        get(CreateCommandQueue, "clCreateCommandQueue"); get(CreateProgramWithSource, "clCreateProgramWithSource");
        get(BuildProgram, "clBuildProgram");             get(GetProgramBuildInfo, "clGetProgramBuildInfo");
        get(CreateKernel, "clCreateKernel");             get(CreateBuffer, "clCreateBuffer");
        get(SetKernelArg, "clSetKernelArg");             get(EnqueueNDRangeKernel, "clEnqueueNDRangeKernel");
        get(EnqueueReadBuffer, "clEnqueueReadBuffer");   get(Finish, "clFinish");
        get(ReleaseMemObject, "clReleaseMemObject");
        if (!ok) err = "the OpenCL driver is missing functions";
        return ok;
    }
};

CL cl;

struct Device { cl_handle platform, id; std::string name; cl_uint units; bool gpu; };

std::vector<Device> devices() {
    std::vector<Device> out;
    cl_uint np = 0;
    if (cl.GetPlatformIDs(0, nullptr, &np) != 0 || !np) return out;
    std::vector<cl_handle> plats(np);
    cl.GetPlatformIDs(np, plats.data(), nullptr);
    for (cl_handle p : plats) {
        cl_uint nd = 0;
        if (cl.GetDeviceIDs(p, CL_DEVICE_TYPE_ALL, 0, nullptr, &nd) != 0 || !nd) continue;
        std::vector<cl_handle> ds(nd);
        cl.GetDeviceIDs(p, CL_DEVICE_TYPE_ALL, nd, ds.data(), nullptr);
        for (cl_handle d : ds) {
            char name[256] = {0};
            cl_uint units = 0;
            cl_ulong type = 0;
            cl.GetDeviceInfo(d, CL_DEVICE_NAME, sizeof name - 1, name, nullptr);
            cl.GetDeviceInfo(d, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof units, &units, nullptr);
            cl.GetDeviceInfo(d, CL_DEVICE_TYPE, sizeof type, &type, nullptr);
            out.push_back({p, d, name, units, (type & CL_DEVICE_TYPE_GPU) != 0});
        }
    }
    return out;
}

// ---- the kernels ---------------------------------------------------------------------------------------------
std::string kernelSource() {
    uint8_t mask[17 * 17];
    int8_t A[17], B[17];
    if (buildIntersectMask(mask) != 226 || !buildMaskIntervals(mask, A, B)) {
        fprintf(stderr, "FATAL: the despawn disc is not what slime_core.h says it is\n");
        exit(1);
    }
    return R"CL(
#define MULT 0x5DEECE66DUL
#define ADDC 0xBUL
#define MASK48 0xFFFFFFFFFFFFUL
#define SCRAMBLE (0x5DEECE66DUL ^ 0x3ad8025fUL)

// Java's nextInt(10) == 0 for the Random seeded with s0 (already scrambled); redraws what Java would reject.
inline int slimeBits(ulong v) {
    ulong s = (v ^ SCRAMBLE) & MASK48;
    for (;;) {
        s = (s * MULT + ADDC) & MASK48;
        uint bits = (uint)(s >> 17);
        uint val = bits % 10u;
        if (bits < 2147483640u) return val == 0;
    }
}

__kernel void bitsK(__global uint* bits, const int WR, const long r0, const ulong seed, const int m, const int ccx, const int ccz,
                    const int side, const long total) {
    long t = get_global_id(0);
    if (t >= total) return;
    long r = t / WR;
    int w = (int)(t % WR);
    int kz = (int)(r0 + r) - (m + 8) + ccz;
    uint z = (uint)kz;
    ulong base = seed + (ulong)((long)(int)(z * z) * 0x4307a7L) + (ulong)(long)(int)(z * 0x5f24fu);
    uint acc = 0;
    for (int c = 0; c < 32; c++) {
        int j = w * 32 + c;
        if (j >= side) break;
        uint x = (uint)(j - (m + 8) + ccx);
        uint a = x * x * 0x4c1906u, b = x * 0x5ac0dbu;
        ulong v = base + (ulong)(long)(int)a + (ulong)(long)(int)b;
        ulong s = ((v ^ SCRAMBLE) & MASK48);
        s = (s * MULT + ADDC) & MASK48;
        uint bt = (uint)(s >> 17);
        int hit = bt < 2147483640u ? (bt % 10u == 0) : slimeBits(v);
        acc |= (uint)hit << c;
    }
    bits[t] = acc;
}

__kernel void scoreK(__global const uint* bits, const int WR, const int npos, const int WN, const long total,
                     const long pzBase, __global ulong* groupBest) {
    __local ulong red[64];
    long g = get_global_id(0);
    int l = (int)get_local_id(0);
    ulong best = 0;
    if (g < total) {
        long row = g / WN;
        int strip = (int)(g % WN);
        int sc[32];
        for (int c = 0; c < 32; c++) sc[c] = 0;
        __global const uint* rp;
        ulong V;
)CL" + [&] {
        // one block per disc row, with the row's column offset and width mask written in as constants
        std::string s;
        for (int k = 0; k < 17; k++)
            s += "        { const int K = " + std::to_string(k) + ";\n" +
                 "          rp = bits + (row + K) * WR + strip; V = ((ulong)rp[0] | ((ulong)rp[1] << 32)) >> " + std::to_string(A[k] + 8) +
                 ";\n          #pragma unroll\n          for (int c = 0; c < 32; c++) sc[c] += popcount((uint)(V >> c) & " +
                 std::to_string((1u << (B[k] - A[k] + 1)) - 1) + "u); }\n";
        return s;
    }() + R"CL(
        // the four chunks inside the exclusion sphere: columns 7 and 8 of rows 7 and 8
        for (int q = 7; q <= 8; q++) {
            rp = bits + (row + q) * WR + strip;
            V = ((ulong)rp[0] | ((ulong)rp[1] << 32)) >> 7;
            #pragma unroll
            for (int c = 0; c < 32; c++) sc[c] -= popcount((uint)(V >> c) & 3u);
        }
        long px0 = (long)strip * 32;
        #pragma unroll
        for (int c = 0; c < 32; c++) {
            if (px0 + c < npos) {
                ulong p = ((ulong)sc[c] << 40) | (ulong)((pzBase + row) * npos + px0 + c);
                best = p > best ? p : best;
            }
        }
    }
    red[l] = best;
    barrier(CLK_LOCAL_MEM_FENCE);
    for (int s = 32; s > 0; s >>= 1) {
        if (l < s) red[l] = red[l + s] > red[l] ? red[l + s] : red[l];
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    if (l == 0) groupBest[get_group_id(0)] = red[0];
}
)CL";
}

// ---- one device ------------------------------------------------------------------------------------------------
struct Card {
    cl_handle ctx = nullptr, queue = nullptr, prog = nullptr, kBits = nullptr, kScore = nullptr;
    std::string name;

    bool open(const Device& d, std::string& err) {
        name = d.name;
        cl_int e = 0;
        ctx = cl.CreateContext(nullptr, 1, &d.id, nullptr, nullptr, &e);
        if (!ctx || e) { err = "could not open " + name + " (OpenCL error " + std::to_string(e) + ")"; return false; }
        queue = cl.CreateCommandQueue(ctx, d.id, 0, &e);
        if (!queue || e) { err = "could not queue work on " + name; return false; }
        std::string src = kernelSource();
        const char* sp = src.c_str();
        size_t len = src.size();
        prog = cl.CreateProgramWithSource(ctx, 1, &sp, &len, &e);
        if (!prog || e) { err = "could not load the kernels"; return false; }
        if (cl.BuildProgram(prog, 1, &d.id, "-cl-std=CL1.2", nullptr, nullptr) != 0) {
            size_t n = 0;
            cl.GetProgramBuildInfo(prog, d.id, CL_PROGRAM_BUILD_LOG, 0, nullptr, &n);
            std::string log(n, 0);
            cl.GetProgramBuildInfo(prog, d.id, CL_PROGRAM_BUILD_LOG, n, &log[0], nullptr);
            err = "the kernels did not compile on " + name + ":\n" + log;
            return false;
        }
        kBits = cl.CreateKernel(prog, "bitsK", &e);
        if (e) { err = "no bitsK kernel"; return false; }
        kScore = cl.CreateKernel(prog, "scoreK", &e);
        if (e) { err = "no scoreK kernel"; return false; }
        return true;
    }

    template <class T> bool arg(cl_handle k, cl_uint i, const T& v) { return cl.SetKernelArg(k, i, sizeof(T), &v) == 0; }

    struct Best { int score = -1, cx = 0, cz = 0; };

    // Best over every centre within +-m chunks of chunk (ccx, ccz), in row bands of about 32 MB (short dispatches: a slow card never trips the OS watchdog).
    bool search(long long seed, int m, int ccx, int ccz, Best& out, std::string& err) {
        const long long npos = 2LL * m + 1, side = 2LL * m + 17;
        const int WR = (int)((side + 31) / 32) + 2, WN = (int)((npos + 31) / 32);
        const long long maxRows = std::max<long long>(32, (32LL << 20) / ((long long)WR * 4));
        const long long band = maxRows - 16;                              // output rows per pass
        const long long groupsMax = (band * WN + 63) / 64 + 1;
        cl_int e = 0;
        cl_handle bufBits = cl.CreateBuffer(ctx, CL_MEM_READ_WRITE, (size_t)(maxRows * WR * 4), nullptr, &e);
        cl_handle bufBest = e ? nullptr : cl.CreateBuffer(ctx, CL_MEM_READ_WRITE, (size_t)(groupsMax * 8), nullptr, &e);
        if (e || !bufBits || !bufBest) { err = "out of memory on " + name; return false; }
        unsigned long long best = 0;
        std::vector<cl_ulong> got((size_t)groupsMax);
        bool ok = true;
        for (long long p0 = 0; p0 < npos && ok; p0 += band) {
            long long rows = std::min(band, npos - p0) + 16;               // bitmap rows this pass needs
            long long words = rows * WR;
            long long items = std::min(band, npos - p0) * WN;
            long long groups = (items + 63) / 64;
            cl_int side32 = (cl_int)side, WR32 = WR, WN32 = WN, npos32 = (cl_int)npos;
            long long r0 = p0, pzBase = p0;
            cl_ulong useed = (cl_ulong)seed;
            cl_int m32 = m, cx32 = ccx, cz32 = ccz;
            cl_int tl = 0;
            ok = arg(kBits, 0, bufBits) && arg(kBits, 1, WR32) && arg(kBits, 2, r0) && arg(kBits, 3, useed) && arg(kBits, 4, m32) &&
                 arg(kBits, 5, cx32) && arg(kBits, 6, cz32) && arg(kBits, 7, side32) && arg(kBits, 8, words);
            size_t g1 = (size_t)((words + 63) / 64 * 64), loc = 64;
            ok = ok && cl.EnqueueNDRangeKernel(queue, kBits, 1, nullptr, &g1, &loc, 0, nullptr, nullptr) == 0;
            ok = ok && arg(kScore, 0, bufBits) && arg(kScore, 1, WR32) && arg(kScore, 2, npos32) && arg(kScore, 3, WN32) &&
                 arg(kScore, 4, items) && arg(kScore, 5, pzBase) && arg(kScore, 6, bufBest);
            size_t g2 = (size_t)(groups * 64);
            ok = ok && cl.EnqueueNDRangeKernel(queue, kScore, 1, nullptr, &g2, &loc, 0, nullptr, nullptr) == 0;
            ok = ok && cl.EnqueueReadBuffer(queue, bufBest, 1, 0, (size_t)(groups * 8), got.data(), 0, nullptr, nullptr) == 0;
            ok = ok && cl.Finish(queue) == 0;
            (void)tl;
            if (!ok) { err = "the OpenCL run failed on " + name; break; }
            for (long long i = 0; i < groups; i++) best = std::max<unsigned long long>(best, got[(size_t)i]);
        }
        cl.ReleaseMemObject(bufBits);
        cl.ReleaseMemObject(bufBest);
        if (!ok) return false;
        out.score = (int)(best >> 40);
        long long idx = (long long)(best & ((1ULL << 40) - 1));
        out.cz = (int)(idx / npos) - m;
        out.cx = (int)(idx % npos) - m;
        return true;
    }
};

// ---- command lines (the same as slime_cpu) --------------------------------------------------------------------
struct Args {
    long long seed = 0;
    bool haveSeed = false, selfTest = false, worker = false, list = false;
    int m = 625, cx = 2048, cz = 8576, device = -1;
};

int blockToChunk(int b) { return b >= 0 ? b / 16 : -(((-b) + 15) / 16); }

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
        else if (s == "--device") { if (!val(v)) return false; a.device = (int)v; }
        else if (s == "--self-test") a.selfTest = true;
        else if (s == "--worker") a.worker = true;
        else if (s == "--list") a.list = true;
        else { err = "unknown argument: " + s; return false; }
    }
    return true;
}

bool check(const Args& a, std::string& err) {
    if (a.m < 1 || a.m > 16000) { err = "--m-chunks must be between 1 and 16000"; return false; }
    long long ax = std::llabs((long long)blockToChunk(a.cx)), az = std::llabs((long long)blockToChunk(a.cz));
    if (ax + a.m + 8 > 1874000 || az + a.m + 8 > 1874000) { err = "center +/- m-chunks exceeds the world border"; return false; }
    return true;
}

// The naive scorer from slime_core.h, with the same tie-break: what every tool is checked against.
Card::Best naive(long long seed, int m, int ccx, int ccz) {
    uint8_t disc[17 * 17];
    buildIntersectMask(disc);
    unsigned long long best = 0;
    long long cside = 2LL * m + 1;
    for (int z = -m; z <= m; z++)
        for (int x = -m; x <= m; x++) {
            int s = scoreCenterChunks(disc, seed, x + ccx, z + ccz);
            unsigned long long p = ((unsigned long long)s << 40) | (unsigned long long)((z + m) * cside + (x + m));
            best = std::max(best, p);
        }
    long long idx = (long long)(best & ((1ULL << 40) - 1));
    Card::Best b;
    b.score = (int)(best >> 40);
    b.cz = (int)(idx / cside) - m;
    b.cx = (int)(idx % cside) - m;
    return b;
}

bool selfCheck(Card& card, bool talk, std::string& err) {
    std::mt19937_64 rng(20260722);
    struct Case { long long seed; int m, ccx, ccz; };
    std::vector<Case> cases = {{71629181566LL, 24, 124, 534}, {-1, 5, -1, -1}, {0, 1, 0, 0}, {42, 33, 1873800, -1873800},
                               {-9223372036854775807LL - 1, 17, -33, 20}};
    for (int i = 0; i < (talk ? 20 : 3); i++)
        cases.push_back({(long long)rng(), 1 + (int)(rng() % 70), (int)(rng() % 3000000) - 1500000, (int)(rng() % 3000000) - 1500000});
    int bad = 0;
    for (const Case& c : cases) {
        Card::Best want = naive(c.seed, c.m, c.ccx, c.ccz), got;
        if (!card.search(c.seed, c.m, c.ccx, c.ccz, got, err)) return false;
        bool ok = want.score == got.score && want.cx == got.cx && want.cz == got.cz;
        if (talk) printf("  m=%3d centre(%d,%d) seed %lld: naive %d @(%d,%d) | %s %d @(%d,%d) -> %s\n", c.m, c.ccx, c.ccz, c.seed,
                         want.score, want.cx, want.cz, "slime_cl", got.score, got.cx, got.cz, ok ? "match" : "MISMATCH");
        bad += !ok;
    }
    if (bad) err = "the graphics card got different answers from the CPU on the start-up check";
    return bad == 0;
}

bool runOne(Card& card, const Args& a, std::string& err) {
    if (!a.haveSeed) { err = "a position search needs --seed"; return false; }
    if (!check(a, err)) return false;
    int ccx = blockToChunk(a.cx), ccz = blockToChunk(a.cz);
    Card::Best b;
    if (!card.search(a.seed, a.m, ccx, ccz, b, err)) return false;
    printf("Best: score=%d at x=%d z=%d (chunk %d,%d)\n", b.score, 16 * (b.cx + ccx), 16 * (b.cz + ccz), b.cx + ccx, b.cz + ccz);
    fflush(stdout);
    return true;
}

void workerLoop(Card& card) {
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
        if (ok && (a.selfTest || a.worker || a.list)) { err = "a spot line is a bare --seed position search"; ok = false; }
        if (ok) ok = runOne(card, a, err);
        if (!ok) { fprintf(stderr, "[WORKER] %s\n", err.c_str()); fflush(stderr); }
        printf("===SPOT-DONE===\n");
        fflush(stdout);
    }
}

}  // namespace

int main(int argc, char** argv) {
    Args a;
    std::string err;
    if (!parse(std::vector<std::string>(argv + 1, argv + argc), a, err)) { fprintf(stderr, "%s\n", err.c_str()); return 1; }
    if (!a.haveSeed && !a.selfTest && !a.worker && !a.list) {
        fprintf(stderr, "Usage:\n  slime_cl --list | --self-test\n  slime_cl --seed <s> --m-chunks <m> --center-x X --center-z Z [--device N]\n"
                        "  slime_cl --worker      (one --seed line per tile on stdin, until --quit)\n");
        return 1;
    }
    if (!cl.load(err)) { fprintf(stderr, "%s\n", err.c_str()); return 1; }
    std::vector<Device> ds = devices();
    if (a.list) {
        for (size_t i = 0; i < ds.size(); i++) printf("%zu: %s (%u compute units, %s)\n", i, ds[i].name.c_str(), ds[i].units, ds[i].gpu ? "GPU" : "not a GPU");
        return 0;
    }
    int pick = a.device;
    if (pick < 0 && getenv("SLIME_CL_DEVICE")) pick = atoi(getenv("SLIME_CL_DEVICE"));
    if (pick < 0) {                                      // the biggest graphics card; a CPU "device" is slime_cpu's job
        for (size_t i = 0; i < ds.size(); i++)
            if (ds[i].gpu && (pick < 0 || ds[i].units > ds[pick].units)) pick = (int)i;
    }
    if (pick < 0 || pick >= (int)ds.size()) { fprintf(stderr, "no OpenCL graphics card found\n"); return 1; }
    Card card;
    if (!card.open(ds[pick], err) || !selfCheck(card, a.selfTest, err)) { fprintf(stderr, "%s\n", err.c_str()); return 1; }
    if (a.selfTest) { printf("SELF TEST PASSED (%s)\n", card.name.c_str()); return 0; }
    if (a.worker) { workerLoop(card); return 0; }
    printf("Single seed %lld, m-chunks %d, center chunk (%d,%d), on %s\n", a.seed, a.m, blockToChunk(a.cx), blockToChunk(a.cz), card.name.c_str());
    if (!runOne(card, a, err)) { fprintf(stderr, "%s\n", err.c_str()); return 1; }
    return 0;
}
