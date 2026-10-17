#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <vector>
#include <string>
#include <algorithm>

static const long long OFF = 1874999, LOFF = 20000;
struct Rec { int cx, cz; float heat, sd; int classes; };

template <class T> static std::vector<T> readBin(const char* p) {
    FILE* f = fopen(p, "rb"); if (!f) { fprintf(stderr, "cannot read %s\n", p); exit(1); }
    fseek(f, 0, SEEK_END); long long n = _ftelli64(f) / sizeof(T); fseek(f, 0, SEEK_SET);
    std::vector<T> v(n); if (fread(v.data(), sizeof(T), n, f) != (size_t)n) exit(1); fclose(f); return v;
}
static inline uint64_t key(long long cx, long long cz) { return ((uint64_t)(cx + OFF) << 32) | (uint64_t)(cz + OFF); }

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "catalog_build <outdir> <band.csv>...\n"); return 1; }
    const std::string outDir = argv[1];
    std::vector<Rec> R; R.reserve(120000000);
    for (int a = 2; a < argc; a++) {
        FILE* f = fopen(argv[a], "rb"); if (!f) { fprintf(stderr, "cannot read %s\n", argv[a]); return 1; }
        static char buf[1 << 16]; long long bad = 0, n0 = (long long)R.size();
        while (fgets(buf, sizeof buf, f)) {
            if (buf[0] == 'c') continue;
            Rec r; char* p = buf; char* e;
            r.cx = (int)strtol(p, &e, 10); if (*e != ',') { bad++; continue; } p = e + 1;
            r.cz = (int)strtol(p, &e, 10); if (*e != ',') { bad++; continue; } p = e + 1;
            r.heat = strtof(p, &e); if (*e != ',') { bad++; continue; } p = e + 1;
            r.classes = (int)strtol(p, &e, 10); if (*e != ',') { bad++; continue; } p = e + 1;
            r.sd = strtof(p, &e);
            if (llabs(r.cx) > OFF || llabs(r.cz) > OFF || !(r.heat >= 0 && r.heat < 1000)) { bad++; continue; }
            R.push_back(r);
        }
        fclose(f);
        printf("%s: %lld rows, %lld malformed skipped\n", argv[a], (long long)R.size() - n0, bad);
    }
    std::sort(R.begin(), R.end(), [](const Rec& a, const Rec& b) { return key(a.cx, a.cz) < key(b.cx, b.cz); });
    size_t w = 0; long long dups = 0;
    for (size_t i = 0; i < R.size(); i++) { if (w && key(R[w - 1].cx, R[w - 1].cz) == key(R[i].cx, R[i].cz)) { dups++; continue; } R[w++] = R[i]; }
    R.resize(w);
    printf("unique spots %zu (%lld duplicate rows dropped)\n", R.size(), dups);

    auto F = readBin<float>("aux_F.bin"), G = readBin<float>("aux_G.bin");
    auto XR = readBin<int32_t>("aux_xrank.bin"), LR = readBin<int32_t>("aux_lrank.bin");
    auto OLD = readBin<uint64_t>("aux_old.bin");
    auto SK = readBin<uint64_t>("aux_screen_k.bin"); auto SV = readBin<int32_t>("aux_screen_v.bin");
    auto QK = readBin<uint64_t>("aux_search_k.bin"); auto QV = readBin<float>("aux_search_v.bin");
    double norm = 0; { FILE* f = fopen("aux_norm.txt", "r"); if (fscanf(f, "%lf", &norm) != 1) return 1; fclose(f); }

    std::sort(R.begin(), R.end(), [](const Rec& a, const Rec& b) { return a.heat != b.heat ? a.heat > b.heat : key(a.cx, a.cz) < key(b.cx, b.cz); });

    const char* regName[5] = {"v1", "v1_other_row", "A", "B", "new"};
    const double tierLo[7] = {22, 20, 18, 16, 13, 12, 0};
    const char* tierFile[7] = {"heat_22plus", "heat_20_22", "heat_18_20", "heat_16_18", "heat_13_16", "heat_12_13", "edge_below_12"};
    long long hist[40][5] = {{0}}; long long tierN[7] = {0};
    FILE* out[7];
    for (int t = 0; t < 7; t++) {
        out[t] = fopen((outDir + "/" + tierFile[t] + ".csv").c_str(), "wb");
        fprintf(out[t], "rank,cx,cz,x_block,z_block,heat40,sd,classes,pred,line,line_offset,v1_region,near_border,screen_best_chunks,search_best_cq\n");
    }
    long long rank = 0;
    for (const Rec& r : R) {
        rank++;
        const double pred = (double)F[r.cx + OFF] * G[r.cz + OFF] / norm;
        const long long n = (long long)std::floor((r.cz - 48.5) / 96.875 + 0.5);
        const double d = r.cz - (48.5 + 96.875 * n);
        const uint64_t k = key(r.cx, r.cz);
        int reg;
        const int xr = XR[r.cx + OFF], lr = (n + LOFF >= 0 && n + LOFF < (long long)LR.size()) ? LR[n + LOFF] : 0;
        if (std::binary_search(OLD.begin(), OLD.end(), k)) reg = 0;
        else if (xr >= 1 && xr <= 10000 && lr >= 1 && lr <= 300) reg = 1;
        else if (xr >= 1 && xr <= 10000) reg = 2;
        else if (xr > 10000 && xr <= 70000 && lr >= 1 && lr <= 300) reg = 3;
        else reg = 4;
        const int nb = (llabs(r.cx) > OFF - 8 || llabs(r.cz) > OFF - 8);
        auto si = std::lower_bound(SK.begin(), SK.end(), k); const int sb = (si != SK.end() && *si == k) ? SV[si - SK.begin()] : -1;
        auto qi = std::lower_bound(QK.begin(), QK.end(), k); const double qb = (qi != QK.end() && *qi == k) ? QV[qi - QK.begin()] : -1;
        int t = 0; while (t < 6 && r.heat < tierLo[t]) t++;
        tierN[t]++;
        const int hb = std::min(39, (int)r.heat); hist[hb][reg]++;
        char sbs[16], qbs[16];
        if (sb >= 0) snprintf(sbs, sizeof sbs, "%d", sb); else sbs[0] = 0;
        if (qb >= 0) snprintf(qbs, sizeof qbs, "%.2f", qb); else qbs[0] = 0;
        fprintf(out[t], "%lld,%d,%d,%lld,%lld,%.3f,%.3f,%d,%.2f,%lld,%.2f,%s,%d,%s,%s\n", rank, r.cx, r.cz, 16LL * r.cx, 16LL * r.cz,
                r.heat, r.sd, r.classes, pred, n, d, regName[reg], nb, sbs, qbs);
    }
    for (int t = 0; t < 7; t++) fclose(out[t]);
    FILE* h = fopen((outDir + "/summary_by_heat_and_region.csv").c_str(), "wb");
    fprintf(h, "heat_band,v1,v1_other_row,A,B,new,total\n");
    for (int b = 0; b < 40; b++) { long long s = 0; for (int g = 0; g < 5; g++) s += hist[b][g]; if (!s) continue;
        fprintf(h, "%d,%lld,%lld,%lld,%lld,%lld,%lld\n", b, hist[b][0], hist[b][1], hist[b][2], hist[b][3], hist[b][4], s); }
    fclose(h);
    for (int t = 0; t < 7; t++) printf("  %-14s %12lld spots\n", tierFile[t], tierN[t]);
    return 0;
}
