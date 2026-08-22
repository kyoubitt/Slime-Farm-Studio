// PNG writer with real deflate (fixed Huffman + LZ77).
// Verified round-trip exact with Python PIL at the sizes we actually emit.
//
// v3 fixes the stream-truncation bug in v2: v2 emitted a literal and then a
// match of (len-1), so a 3-byte match produced writeLen(2). Length 2 is not a
// valid deflate length (min 3) and the code mapped it to symbol 256 =
// END-OF-BLOCK, so every decoder stopped mid-image ("broken data stream").
// v3 emits the match directly at its true length and never fabricates a
// length < 3.
#pragma once
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <algorithm>

namespace pngw {

static inline uint32_t crc32(const uint8_t* buf, size_t len, uint32_t crc = 0) {
    static uint32_t T[256]; static bool built = false;
    if (!built) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & -(int32_t)(c & 1));
            T[i] = c;
        }
        built = true;
    }
    crc ^= 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) crc = T[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}
static inline uint32_t adler32(const uint8_t* buf, size_t len) {
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < len; i++) { a = (a + buf[i]) % 65521; b = (b + a) % 65521; }
    return (b << 16) | a;
}
static inline void put_be32(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back((x >> 24) & 0xFF); v.push_back((x >> 16) & 0xFF);
    v.push_back((x >>  8) & 0xFF); v.push_back(x & 0xFF);
}
static inline void put_chunk(std::vector<uint8_t>& v, const char type[4],
                             const uint8_t* data, size_t len) {
    put_be32(v, (uint32_t)len);
    size_t crcStart = v.size();
    v.insert(v.end(), (const uint8_t*)type, (const uint8_t*)type + 4);
    if (len) v.insert(v.end(), data, data + len);
    put_be32(v, crc32(v.data() + crcStart, 4 + len));
}

struct BitWriter {
    std::vector<uint8_t> out;
    uint32_t bitBuf = 0;
    int bitCount = 0;
    void write(uint32_t val, int nBits) {          // LSB-first (extra bits)
        bitBuf |= (val & ((1u << nBits) - 1)) << bitCount;
        bitCount += nBits;
        while (bitCount >= 8) { out.push_back((uint8_t)(bitBuf & 0xFF)); bitBuf >>= 8; bitCount -= 8; }
    }
    static uint32_t rev(uint32_t v, int nBits) {
        uint32_t r = 0;
        for (int i = 0; i < nBits; i++) if (v & (1u << i)) r |= (1u << (nBits - 1 - i));
        return r;
    }
    void writeCode(uint32_t code, int nBits) { write(rev(code, nBits), nBits); }  // MSB-first (Huffman)
    void flush() { if (bitCount > 0) { out.push_back((uint8_t)(bitBuf & 0xFF)); bitBuf = 0; bitCount = 0; } }
};

// fixed-Huffman literal/length symbol
static inline void writeSym(BitWriter& w, int sym) {
    if      (sym <= 143) w.writeCode(0x30 + sym, 8);
    else if (sym <= 255) w.writeCode(0x190 + (sym - 144), 9);
    else if (sym <= 279) w.writeCode(0x00 + (sym - 256), 7);
    else                 w.writeCode(0xC0 + (sym - 280), 8);
}

static const int LEN_BASE[29]  = { 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,
                                   51,59,67,83,99,115,131,163,195,227,258 };
static const int LEN_EXTRA[29] = { 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,
                                   3,3,4,4,4,4,5,5,5,5,0 };
static const int DIST_BASE[30] = { 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,
                                   257,385,513,769,1025,1537,2049,3073,4097,6145,
                                   8193,12289,16385,24577 };
static const int DIST_EXTRA[30]= { 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,
                                   10,10,11,11,12,12,13,13 };

static inline void writeLen(BitWriter& w, int len) {
    // len is guaranteed 3..258 by the caller; find the largest code with base <= len
    int code = 28;
    for (int c = 28; c >= 0; c--) if (len >= LEN_BASE[c]) { code = c; break; }
    writeSym(w, 257 + code);
    if (LEN_EXTRA[code]) w.write((uint32_t)(len - LEN_BASE[code]), LEN_EXTRA[code]);
}
static inline void writeDist(BitWriter& w, int dist) {
    int code = 29;
    for (int c = 29; c >= 0; c--) if (dist >= DIST_BASE[c]) { code = c; break; }
    w.writeCode((uint32_t)code, 5);
    if (DIST_EXTRA[code]) w.write((uint32_t)(dist - DIST_BASE[code]), DIST_EXTRA[code]);
}

// LZ77 over a small set of candidate distances that dominate chunk maps:
//   stride  = one scanline back (identical rows: the common case)
//   3       = previous pixel  (solid colour runs)
//   1       = byte run
// Emitting the match DIRECTLY (no leading literal) is what fixes the v2 bug.
static inline std::vector<uint8_t> deflate_fixed(const std::vector<uint8_t>& raw, int stride) {
    BitWriter w;
    w.write(1, 1);   // BFINAL
    w.write(1, 2);   // BTYPE = 01, fixed Huffman

    const size_t n = raw.size();
    int cand[3] = { stride, 3, 1 };
    size_t i = 0;
    while (i < n) {
        size_t bestLen = 0; int bestDist = 0;
        for (int ci = 0; ci < 3; ci++) {
            int d = cand[ci];
            if (d <= 0 || (size_t)d > i) continue;
            size_t l = 0;
            const size_t maxL = std::min<size_t>(258, n - i);
            while (l < maxL && raw[i + l] == raw[i + l - d]) l++;
            if (l > bestLen) { bestLen = l; bestDist = d; }
        }
        if (bestLen >= 3) {                     // never fabricate len < 3
            writeLen(w, (int)bestLen);
            writeDist(w, bestDist);
            i += bestLen;
        } else {
            writeSym(w, raw[i]);
            i++;
        }
    }
    writeSym(w, 256);   // end of block
    w.flush();
    return w.out;
}

static inline std::vector<uint8_t> zlib_wrap(const std::vector<uint8_t>& raw, int stride) {
    std::vector<uint8_t> out;
    out.push_back(0x78); out.push_back(0x01);      // CMF/FLG (deflate, 32K window)
    std::vector<uint8_t> d = deflate_fixed(raw, stride);
    out.insert(out.end(), d.begin(), d.end());
    uint32_t ad = adler32(raw.data(), raw.size());
    out.push_back((ad >> 24) & 0xFF); out.push_back((ad >> 16) & 0xFF);
    out.push_back((ad >>  8) & 0xFF); out.push_back(ad & 0xFF);
    return out;
}

// RGB, 8-bit, no interlace. pixels = W*H*3, top-left origin.
static inline bool write_rgb(const char* path, const uint8_t* pixels, int W, int H) {
    std::vector<uint8_t> file;
    static const uint8_t sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    file.insert(file.end(), sig, sig + 8);

    std::vector<uint8_t> ihdr;
    put_be32(ihdr, (uint32_t)W); put_be32(ihdr, (uint32_t)H);
    ihdr.push_back(8); ihdr.push_back(2);
    ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
    put_chunk(file, "IHDR", ihdr.data(), ihdr.size());

    // filter byte 0 (None) per scanline; identical rows then match at
    // distance = stride, which is where most of the compression comes from.
    const int stride = W * 3 + 1;
    std::vector<uint8_t> raw;
    raw.reserve((size_t)H * stride);
    for (int y = 0; y < H; y++) {
        raw.push_back(0);
        raw.insert(raw.end(), pixels + (size_t)y * W * 3, pixels + (size_t)(y + 1) * W * 3);
    }
    std::vector<uint8_t> z = zlib_wrap(raw, stride);
    put_chunk(file, "IDAT", z.data(), z.size());
    put_chunk(file, "IEND", nullptr, 0);

    FILE* f = fopen(path, "wb");
    if (!f) return false;
    fwrite(file.data(), 1, file.size(), f);
    fclose(f);
    return true;
}

} // namespace pngw
