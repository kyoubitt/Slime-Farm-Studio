#include "Perimeter.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RADIUS 152
#define AFK_ABOVE_FLOOR 14
#define VOID_ABOVE_FLOOR 24

const char *const VERSION_NAMES[VERSION_COUNT] = {
    "1.13 - 1.17",
    "1.18 - 1.20.4",
    "1.20.5 - 1.21.10",
    "1.21.11 and later"
};

const char *const VERSION_TAGS[VERSION_COUNT] = {
    "1.13-1.17",
    "1.18-1.20.4",
    "1.20.5-1.21.10",
    "1.21.11+"
};

static int floorLevel(int version) { return version == VERSION_1_13 ? 0 : -64; }

static int64_t chunkOf(int64_t block) {
    return block >= 0 ? block / 16 : -((-block + 15) / 16);
}

#ifdef SLIME_CORE_SHIM
/* Built inside the slime chunk finder (see build.sh): use the toolchain's
 * single shared slime_core.h isSlimeChunk - the one vanilla_parity.py checks
 * against the real game - instead of a second copy of the formula.
 * Chunk coordinates always fit int32 (the world border is chunk +-1875000). */
int slime_core_is_slime_chunk(int64_t worldSeed, int32_t chunkX, int32_t chunkZ);
static int isSlimeChunk(int64_t worldSeed, int64_t chunkX, int64_t chunkZ) {
    return slime_core_is_slime_chunk(worldSeed, (int32_t)chunkX, (int32_t)chunkZ);
}
#else
static int isSlimeChunk(int64_t worldSeed, int64_t chunkX, int64_t chunkZ) {
    uint64_t seed = (uint64_t)worldSeed;
    seed += (uint64_t)(int64_t)(int32_t)(chunkX * chunkX * 0x4c1906LL);
    seed += (uint64_t)(int64_t)(int32_t)(chunkX * 0x5ac0dbLL);
    seed += (uint64_t)((int64_t)((int32_t)(chunkZ * chunkZ)) * 0x4307a7LL);
    seed += (uint64_t)(int64_t)(int32_t)(chunkZ * 0x5f24fLL);
    seed ^= 0x3ad8025fULL;

    uint64_t state = (seed ^ 0x5DEECE66DULL) & ((1ULL << 48) - 1);
    for (;;) {
        state = (state * 0x5DEECE66DULL + 0xBULL) & ((1ULL << 48) - 1);
        int32_t bits = (int32_t)(state >> 17);
        int32_t val = bits % 10;
        if (bits - val + 9 >= 0) return val == 0;
    }
}
#endif

typedef struct {
    char *data;
    size_t len;
    size_t cap;
    int count;
    int failed;
} Monolith;


static void append(Monolith *m, const char *s) {
    if (m->failed) return;
    size_t n = strlen(s);
    if (m->len + n + 1 > m->cap) {
        size_t cap = m->cap ? m->cap : 1 << 16;
        while (m->len + n + 1 > cap) cap *= 2;
        char *p = (char *)realloc(m->data, cap);
        if (!p) { m->failed = 1; return; }
        m->data = p;
        m->cap = cap;
    }
    memcpy(m->data + m->len, s, n + 1);
    m->len += n;
}

/* The armor stand (Health:0, it dies on its first tick) between the falling redstone block and the
 * falling rail is what makes the rail land on 1.13 - 1.17: without it the rail never becomes a block
 * there and no minecart fires (a real 1.16.5 server builds nothing). 1.20.4, 1.20.6, 1.21.11 and
 * 26.1.2 build the same with or without it, so one form serves every version band. */
static void monolithStart(Monolith *m) {
    memset(m, 0, sizeof *m);
    append(m, "summon falling_block ~ ~1 ~ {BlockState:{Name:\"minecraft:redstone_block\"},Time:1,Passengers:"
                "[{id:\"minecraft:armor_stand\",Health:0f,Passengers:"
                "[{id:\"minecraft:falling_block\",BlockState:{Name:\"minecraft:activator_rail\"},Time:1,Passengers:[");
}

static void monolithAdd(Monolith *m, const char *command) {
    char piece[256];
    snprintf(piece, sizeof piece, "%s{id:\"minecraft:command_block_minecart\",Command:\"%s\"}",
             m->count ? "," : "", command);
    append(m, piece);
    m->count++;
}

/* Teardown order is load-bearing. Removing the rail first (the old order) means the carts after it
 * are no longer on an activator rail and never fire, so the redstone block and every minecart stay
 * behind (seen on a real 1.21.11 server). Instead one cart places an auto command block above the
 * rail that clears itself, the rail and the redstone block on the next tick, and the last cart kills
 * the minecarts while the rail is still there. The command block the player pasted into stays. */
static void monolithEnd(Monolith *m) {
    append(m, ",{id:\"minecraft:command_block_minecart\",Command:\"setblock ~ ~1 ~ command_block"
                "{auto:1b,Command:\\\"fill ~ ~ ~ ~ ~-2 ~ air\\\"}\"}"
                ",{id:\"minecraft:command_block_minecart\",Command:\"kill @e[type=command_block_minecart,distance=..3]\"}]}]}]}");
}

static void giveCommand(char *out, size_t n, int version) {
    if (version <= VERSION_1_18)
        snprintf(out, n, "/give @p minecraft:repeating_command_block"
                         "{BlockEntityTag:{Command:\"execute at @p run perimeterinfo\",auto:1b}}");
    else
        snprintf(out, n, "/give @p repeating_command_block[block_entity_data="
                         "{id:\"minecraft:command_block\",Command:\"execute at @p run perimeterinfo\",auto:1b}]");
}

int generatePerimeter(const Options *opt, const char *path, Report *rep) {
    const int64_t cxMin = chunkOf(opt->x - RADIUS), cxMax = chunkOf(opt->x + RADIUS);
    const int64_t czMin = chunkOf(opt->z - RADIUS), czMax = chunkOf(opt->z + RADIUS);
    const int nx = (int)(cxMax - cxMin + 1), nz = (int)(czMax - czMin + 1);

    const int floorY = floorLevel(opt->version), afkY = floorY + AFK_ABOVE_FLOOR, voidTop = floorY + VOID_ABOVE_FLOOR;
    const int64_t bx0 = cxMin * 16 - 1, bz0 = czMin * 16 - 1;
    const int w = nx * 16 + 2, h = nz * 16 + 2;

    unsigned char *slime = (unsigned char *)calloc((size_t)nx * nz, 1);
    unsigned char *border = (unsigned char *)calloc((size_t)w * h, 1);
    Monolith floorCmds, borderCmds;
    monolithStart(&floorCmds);
    monolithStart(&borderCmds);

    if (!slime || !border || floorCmds.failed || borderCmds.failed) {
        free(slime); free(border); free(floorCmds.data); free(borderCmds.data);
        return 0;
    }

    int slimeCount = 0;
    for (int i = 0; i < nx; i++)
        for (int j = 0; j < nz; j++)
            if (isSlimeChunk(opt->seed, cxMin + i, czMin + j)) { slime[i * nz + j] = 1; slimeCount++; }

    for (int j = 0; j < nz; j++)
        for (int i = 0; i < nx; i++)
            if (slime[i * nz + j]) {
                const int64_t x0 = (cxMin + i) * 16, z0 = (czMin + j) * 16;
                char line[160];
                snprintf(line, sizeof line, "fill %lld %d %lld %lld %d %lld obsidian",
                         (long long)x0, floorY, (long long)z0,
                         (long long)(x0 + 15), floorY, (long long)(z0 + 15));
                monolithAdd(&floorCmds, line);
            }

    long long borderBlocks = 0;
    for (int ix = 0; ix < w; ix++) {
        const int ci = (int)chunkOf(ix - 1);
        for (int iz = 0; iz < h; iz++) {
            const int cj = (int)chunkOf(iz - 1);
            if (ci >= 0 && ci < nx && cj >= 0 && cj < nz && slime[ci * nz + cj]) continue;
            int touches = 0;
            for (int dx = -1; dx <= 1 && !touches; dx++)
                for (int dz = -1; dz <= 1 && !touches; dz++) {
                    if (!dx && !dz) continue;
                    const int ni = (int)chunkOf(ix + dx - 1), nj = (int)chunkOf(iz + dz - 1);
                    if (ix + dx < 0 || ix + dx >= w || iz + dz < 0 || iz + dz >= h) continue;
                    if (ni >= 0 && ni < nx && nj >= 0 && nj < nz && slime[ni * nz + nj]) touches = 1;
                }
            if (touches) { border[ix * h + iz] = 1; borderBlocks++; }
        }
    }

    for (int ix = 0; ix < w; ix++)
        for (int iz = 0; iz < h; iz++) {
            if (!border[ix * h + iz]) continue;
            int rw = 1;
            while (ix + rw < w && border[(ix + rw) * h + iz]) rw++;
            int rh = 1, extend = 1;
            while (extend && iz + rh < h) {
                for (int k = 0; k < rw; k++)
                    if (!border[(ix + k) * h + iz + rh]) { extend = 0; break; }
                if (extend) rh++;
            }
            for (int a = 0; a < rw; a++)
                for (int b = 0; b < rh; b++) border[(ix + a) * h + iz + b] = 0;
            char line[160];
            snprintf(line, sizeof line, "fill %lld %d %lld %lld %d %lld magma_block replace air",
                     (long long)(bx0 + ix), floorY, (long long)(bz0 + iz),
                     (long long)(bx0 + ix + rw - 1), floorY, (long long)(bz0 + iz + rh - 1));
            monolithAdd(&borderCmds, line);
        }

    monolithEnd(&floorCmds);
    monolithEnd(&borderCmds);

    char give[512];
    giveCommand(give, sizeof give, opt->version);

    FILE *f = floorCmds.failed || borderCmds.failed ? NULL : fopen(path, "w");
    if (f) {
        fprintf(f, "seed %lld  center %lld %lld  radius %d  floor y %d  version %s\n",
                (long long)opt->seed, (long long)opt->x, (long long)opt->z, RADIUS, floorY,
                VERSION_NAMES[opt->version]);
        fprintf(f, "%d slime chunks of %d, %d blocks of floor, %lld magma border blocks\n\n",
                slimeCount, nx * nz, slimeCount * 256, borderBlocks);

        fprintf(f, "--- 0. SEED ---\n%lld\n\n", (long long)opt->seed);

        fprintf(f, "--- 1. TELEPORT ---\n/tp @p %lld %d %lld\n/gamerule %s false\n/seed\n\n",
                (long long)opt->x, afkY, (long long)opt->z,
                opt->version >= VERSION_1_21_11 ? "spawn_mobs" : "doMobSpawning");

        fprintf(f, "--- 2. VOID THE AREA (WorldEdit) ---\n//pos1 %lld,%d,%lld\n//pos2 %lld,%d,%lld\n//replace air\n\n",
                (long long)((cxMin - 1) * 16), floorY, (long long)((czMin - 1) * 16),
                (long long)((cxMax + 1) * 16 + 15), voidTop, (long long)((czMax + 1) * 16 + 15));

        fprintf(f, "--- 3. SLIME CHUNK FLOOR - paste into ONE command block ---\n%s\n\n(%zu characters, %d fills)\n\n",
                floorCmds.data, floorCmds.len, floorCmds.count);

        fprintf(f, "--- 4. MAGMA BORDER - paste into ONE command block, run after 3 ---\n"
                   "%s\n\n(%zu characters, %d fills, %lld blocks)\n\n",
                borderCmds.data, borderCmds.len, borderCmds.count, borderBlocks);

        fprintf(f, "--- 5. SPAWNING SKIRT (WorldEdit) ---\n//pos1 %lld,%d,%lld\n//pos2 %lld,%d,%lld\n//replace air glass\n\n",
                (long long)((cxMin - 1) * 16), floorY, (long long)((czMin - 1) * 16),
                (long long)((cxMax + 1) * 16 + 15), floorY, (long long)((czMax + 1) * 16 + 15));

        fprintf(f, "--- 6. MEASURE - repeating command block, unconditional, always active ---\n%s\n", give);
        fclose(f);

        rep->slimeChunks = slimeCount;
        rep->scannedChunks = nx * nz;
        rep->floorFills = floorCmds.count;
        rep->borderFills = borderCmds.count;
        rep->borderBlocks = borderBlocks;
        rep->floorChars = floorCmds.len;
        rep->borderChars = borderCmds.len;
        rep->floorY = floorY;
    }

    free(slime);
    free(border);
    free(floorCmds.data);
    free(borderCmds.data);
    return f != NULL;
}
