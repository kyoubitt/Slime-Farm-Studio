// perimeter_setup.cpp
// ============================================================================
// In-game verification rig. Added after the main toolchain (hotspot_scan,
// slime_gpu, slime_refine) was already built.
//
// WHY THIS EXISTS
//   Every number the toolchain produces is a MODEL PREDICTION. slime_refine
//   computes eligible spawn blocks from slime_core.h's annulus weights,
//   validated against slimefinder.jar - but that is validation against
//   another PROGRAM, not against Minecraft itself.
//
//   This closes that loop. It emits the exact in-game commands to build a
//   physical test rig, measurable with Carpet mod's /perimeterinfo - the
//   game's own spawn-space calculation - and compares directly against the
//   model. At record margins the two can disagree enough to flip a ranking
//   (see the AFK-height note below); the game wins any disagreement, not
//   the model.
//
// THE RIG, CONCEPTUALLY
//   /perimeterinfo counts positions where a mob could spawn around the
//   player. To make that number mean "slime spawn potential of this spot"
//   and nothing else, the world around the AFK point must contain NO
//   spawnable surface except slime-chunk floor:
//     1. Void a large box around the AFK spot.
//     2. Lay one layer of floor block (default obsidian) at the world
//        floor, in slime chunks only - everything else stays void.
//     3. Disable mob spawning (live mobs would corrupt the count).
//     4. Measure with /perimeterinfo.
//   One layer is enough: a spawn position needs a solid block beneath and
//   air above, so a single floor layer with void above satisfies exactly
//   one spawn position per column.
//
// THE MONOLITH
//   A slime-chunk floor needs one /fill per slime chunk (~100+ commands for
//   radius 200). Getting that many commands into the game in one shot is
//   the actual engineering problem here - chat caps at 256 characters and
//   one line per send, a single command block executes exactly ONE
//   command regardless of how much text it holds, and semicolon-separated
//   multi-commands are not vanilla. The fix is the classic "one-command
//   creation" trick: a falling redstone block lands an activator rail on
//   top of itself, and every command_block_minecart riding that rail fires
//   ONCE. N commands from one summon command pasted into one block.
//   Self-destructs afterward - command blocks are solid, so leaving the
//   rig's own blocks in place would inflate the very count being measured.
//
// AFK-HEIGHT CAVEAT - read before trusting a game/model mismatch
//   slime_core.h computes at y-offset 0 (player level with the spawn
//   surface); its own header says so explicitly. --afk-y here defaults to
//   100 and is independently settable BECAUSE real rigs often stand well
//   above the floor - and since both the exclusion and despawn spheres are
//   3D, height changes the horizontal footprint substantially:
//       y-offset  0: exclusion radius 24.0 blocks, despawn radius 128.0
//       y-offset 23: exclusion radius  6.9 blocks, despawn radius 125.9
//   The two effects roughly cancel in TOTAL area but change WHICH chunks
//   qualify - and since slime chunks are discrete and clustered, that can
//   flip the ranking of two spots separated by a fraction of a cq. If a
//   model/game mismatch shows up, check --afk-y against the floor Y first;
//   it is the leading explanation, not a sign of a scoring bug.
//
// Build:  nvcc -O3 perimeter_setup.cpp -o perimeter_setup.exe
//         (plain C++, no CUDA in it - g++ -O3 works identically. Includes
//         slime_core.h purely for isSlimeChunk.)
// Needs:  slime_core.h beside it.
// ============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include "slime_core.h"

static long long floorDiv16(long long v) {
    long long q = v / 16;
    if ((v % 16 != 0) && ((v < 0) != (16 < 0))) q--;
    return q;
}

struct Args {
    long long seed = 0;
    bool haveSeed = false;
    long long centerX = 0, centerZ = 0;
    long long y = -64;
    long long radius = 200;
    std::string block = "obsidian";
    long long voidTop = 120;
    long long afkY = 100;
};

static void usage() {
    std::fprintf(stderr,
        "usage: perimeter_setup --seed <s> --center-x <x> --center-z <z>\n"
        "                       [--y -64] [--radius 200] [--block obsidian]\n"
        "                       [--void-top 120] [--afk-y 100]\n");
}

static bool parseArgs(int argc, char** argv, Args& a) {
    for (int i = 1; i < argc; i++) {
        std::string k = argv[i];
        auto next = [&](const char* name) -> std::string {
            if (i + 1 >= argc) { std::fprintf(stderr, "missing value for %s\n", name); std::exit(1); }
            return argv[++i];
        };
        if (k == "--seed") { a.seed = std::atoll(next("--seed").c_str()); a.haveSeed = true; }
        else if (k == "--center-x") a.centerX = std::atoll(next("--center-x").c_str());
        else if (k == "--center-z") a.centerZ = std::atoll(next("--center-z").c_str());
        else if (k == "--y") a.y = std::atoll(next("--y").c_str());
        else if (k == "--radius") a.radius = std::atoll(next("--radius").c_str());
        else if (k == "--block") a.block = next("--block");
        else if (k == "--void-top") a.voidTop = std::atoll(next("--void-top").c_str());
        else if (k == "--afk-y") a.afkY = std::atoll(next("--afk-y").c_str());
        else if (k == "--help" || k == "-h") { usage(); std::exit(0); }
        else { std::fprintf(stderr, "unknown argument: %s\n", k.c_str()); usage(); std::exit(1); }
    }
    if (!a.haveSeed) { std::fprintf(stderr, "--seed is required\n"); usage(); std::exit(1); }
    return true;
}

struct Chunk { long long cx, cz; };

int main(int argc, char** argv) {
    Args a;
    parseArgs(argc, argv, a);

    long long cxMin = floorDiv16(a.centerX - a.radius);
    long long cxMax = floorDiv16(a.centerX + a.radius);
    long long czMin = floorDiv16(a.centerZ - a.radius);
    long long czMax = floorDiv16(a.centerZ + a.radius);

    std::vector<Chunk> slimeChunks;
    long long scanned = 0;
    for (long long cz = czMin; cz <= czMax; cz++) {
        for (long long cx = cxMin; cx <= cxMax; cx++) {
            scanned++;
            if (isSlimeChunk(a.seed, (int)cx, (int)cz)) slimeChunks.push_back({cx, cz});
        }
    }
    long long floorBlocks = (long long)slimeChunks.size() * 256;

    std::printf("=== perimeter_setup ===\n");
    std::printf("seed %lld  center (%lld,%lld)  y=%lld  radius=%lld  block=%s  void-top=%lld  afk-y=%lld\n",
                 a.seed, a.centerX, a.centerZ, a.y, a.radius, a.block.c_str(), a.voidTop, a.afkY);
    std::printf("%lld slime chunks of %lld scanned (%.1f%%), %lld blocks of floor\n\n",
                 (long long)slimeChunks.size(), scanned,
                 100.0 * (double)slimeChunks.size() / (double)scanned, floorBlocks);

    // ---- Section 0: SEED ----
    std::printf("--- 0. SEED ---\n%lld\n\n", a.seed);

    // ---- Section 1: TELEPORT + SPAWNPOINT ----
    std::printf("--- 1. TELEPORT + SPAWNPOINT ---\n");
    std::printf("/tp @p %lld %lld %lld\n", a.centerX, a.afkY, a.centerZ);
    std::printf("/spawnpoint @p %lld %lld %lld\n", a.centerX, a.afkY, a.centerZ);
    std::printf("/gamerule doMobSpawning false\n");
    std::printf("/seed\n\n");

    // ---- Section 2: VOID THE AREA (WorldEdit) ----
    std::printf("--- 2. VOID THE AREA (WorldEdit) ---\n");
    std::printf("//fast\n");
    std::printf("//pos1 %lld,%lld,%lld\n", a.centerX - a.radius, a.y, a.centerZ - a.radius);
    std::printf("//pos2 %lld,%lld,%lld\n", a.centerX + a.radius, a.voidTop, a.centerZ + a.radius);
    std::printf("//set air\n\n");

    // ---- Section 3: SLIME CHUNK FLOOR ----
    std::printf("--- 3a. SLIME CHUNK FLOOR - chain-command-block form (re-triggerable) ---\n");
    std::printf("Place at y=%lld starting at (%lld,%lld), marching +X. First block IMPULSE\n", a.afkY, a.centerX, a.centerZ);
    std::printf("with a button (press once); the rest CHAIN, facing=east, Always Active.\n");
    {
        long long bx = a.centerX;
        long long idx = 0;
        for (auto& c : slimeChunks) {
            char cmd[256];
            std::snprintf(cmd, sizeof cmd, "fill %lld %lld %lld %lld %lld %lld %s",
                          c.cx * 16, a.y, c.cz * 16, c.cx * 16 + 15, a.y, c.cz * 16 + 15, a.block.c_str());
            const char* type = (idx == 0) ? "command_block" : "chain_command_block";
            const char* auto_flag = (idx == 0) ? "" : ",auto:1b";
            std::printf("setblock %lld %lld %lld minecraft:%s[facing=east]{Command:\"%s\"%s}\n",
                         bx, a.afkY, a.centerZ, type, cmd, auto_flag);
            bx++; idx++;
        }
        std::printf("setblock %lld %lld %lld minecraft:chain_command_block[facing=east]{Command:\"setblock ~ ~ ~ air\",auto:1b}\n", bx, a.afkY, a.centerZ); bx++;
        std::printf("setblock %lld %lld %lld minecraft:chain_command_block[facing=east]{Command:\"setblock ~ ~-1 ~ air\",auto:1b}\n", bx, a.afkY, a.centerZ);
    }
    std::printf("\n");

    std::printf("--- 3b. SLIME CHUNK FLOOR - one-command monolith (paste into ONE command block) ---\n");
    {
        std::string mono = "summon falling_block ~ ~1 ~ {BlockState:{Name:\"minecraft:redstone_block\"},Time:1,"
                            "Passengers:[{id:\"minecraft:falling_block\",BlockState:{Name:\"minecraft:activator_rail\"},Time:1,"
                            "Passengers:[";
        for (auto& c : slimeChunks) {
            char cmd[256];
            std::snprintf(cmd, sizeof cmd, "fill %lld %lld %lld %lld %lld %lld %s",
                          c.cx * 16, a.y, c.cz * 16, c.cx * 16 + 15, a.y, c.cz * 16 + 15, a.block.c_str());
            mono += "{id:\"minecraft:command_block_minecart\",Command:\"";
            mono += cmd;
            mono += "\"},";
        }
        mono += "{id:\"minecraft:command_block_minecart\",Command:\"setblock ~ ~ ~ air\"},";
        mono += "{id:\"minecraft:command_block_minecart\",Command:\"setblock ~ ~-1 ~ air\"},";
        mono += "{id:\"minecraft:command_block_minecart\",Command:\"kill @e[type=command_block_minecart,distance=..3]\"}";
        mono += "]}]}";
        std::printf("%s\n\n", mono.c_str());
        std::printf("(%zu characters, %zu fills)\n\n", mono.size(), slimeChunks.size());
    }

    // ---- Section 4: MEASURE ----
    std::printf("--- 4. MEASURE ---\n");
    std::printf("/perimeterinfo\n");

    return 0;
}
