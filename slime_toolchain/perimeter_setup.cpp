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
//   A slime-chunk floor needs one /fill per slime chunk (~70-90 commands for
//   radius 152). Getting that many commands into the game in one shot is
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
//   surface); its own header says so explicitly. --afk-y (the /tp height)
//   defaults to -50, 14 above the -64 floor (the author's rig, 2026-09-12),
//   and is settable BECAUSE real rigs stand above the floor - and since both
//   the exclusion and despawn spheres are 3D, height changes the horizontal
//   footprint substantially:
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
#include "portable_paths.h"

static long long floorDiv16(long long v) {
    long long q = v / 16;
    if ((v % 16 != 0) && ((v < 0) != (16 < 0))) q--;
    return q;
}

// DEFAULTS = the author's real rig (2026-09-12). Change them HERE, not by passing flags - the old
// defaults (radius 200, void-top 120) kept coming back because the fix only ever lived in a
// command line (--void-top -40), never in the code.
struct Args {
    long long seed = 0;
    bool haveSeed = false;
    long long centerX = 0, centerZ = 0;
    long long y = -64;
    long long radius = 152;       // 3 chunks in from the old 200 on every side (the author's rig); still 24 blocks past the 128-block despawn sphere
    std::string block = "obsidian";
    long long voidTop = -40;      // superflat world: nothing above y=-40 to clear
    long long afkY = -50;         // the /tp height (reference rig: 14 above the floor)
    // --game-version: the command syntax that changes between versions. 1.21.11 renamed the
    // gamerule (doMobSpawning -> spawn_mobs; a 1.21.11 server rejects the old name - checked on a
    // real server by vanilla_world_test.py), 1.20.5 replaced /give's BlockEntityTag NBT with item
    // components, and before 1.18 the world floor is y 0 rather than -64.
    int ver[3] = {1, 21, 11};
    bool haveY = false, haveVoidTop = false, haveAfkY = false;
};

static bool versionAtLeast(const int v[3], int a, int b, int c) {
    if (v[0] != a) return v[0] > a;
    if (v[1] != b) return v[1] > b;
    return v[2] >= c;
}

static void usage() {
    std::fprintf(stderr,
        "usage: perimeter_setup --seed <s> --center-x <x> --center-z <z>\n"
        "                       [--y -64] [--radius 152] [--block obsidian]\n"
        "                       [--void-top -40] [--afk-y -50] [--game-version 1.21.11]\n"
        "  --game-version picks the gamerule name and /give syntax for your Minecraft\n"
        "  version, and the floor height before 1.18 (y 0 instead of -64).\n");
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
        else if (k == "--y") { a.y = std::atoll(next("--y").c_str()); a.haveY = true; }
        else if (k == "--radius") a.radius = std::atoll(next("--radius").c_str());
        else if (k == "--block") a.block = next("--block");
        else if (k == "--void-top") { a.voidTop = std::atoll(next("--void-top").c_str()); a.haveVoidTop = true; }
        else if (k == "--afk-y") { a.afkY = std::atoll(next("--afk-y").c_str()); a.haveAfkY = true; }
        else if (k == "--game-version") {
            std::string v = next("--game-version");
            int n = std::sscanf(v.c_str(), "%d.%d.%d", &a.ver[0], &a.ver[1], &a.ver[2]);
            if (n < 2) { std::fprintf(stderr, "--game-version wants e.g. 1.21.11 or 26.1.2\n"); std::exit(1); }
            if (n == 2) a.ver[2] = 0;
        }
        else if (k == "--help" || k == "-h") { usage(); std::exit(0); }
        else { std::fprintf(stderr, "unknown argument: %s\n", k.c_str()); usage(); std::exit(1); }
    }
    if (!a.haveSeed) { std::fprintf(stderr, "--seed is required\n"); usage(); std::exit(1); }
    // before 1.18 the world bottom is y 0: move the reference rig's defaults with it
    // (afk 14 above the floor, void top 24 above it) unless they were given explicitly
    if (!versionAtLeast(a.ver, 1, 18, 0)) {
        if (!a.haveY) a.y = 0;
        if (!a.haveAfkY) a.afkY = a.y + 14;
        if (!a.haveVoidTop) a.voidTop = a.y + 24;
    }
    return true;
}

struct Chunk { long long cx, cz; };

int main(int argc, char** argv) {
    slimeFixArgv(argc, argv);       // "\" -> "/" off Windows (portable_paths.h)
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
    std::printf("seed %lld  center (%lld,%lld)  y=%lld  radius=%lld  block=%s  void-top=%lld  afk-y=%lld  game %d.%d.%d\n",
                 a.seed, a.centerX, a.centerZ, a.y, a.radius, a.block.c_str(), a.voidTop, a.afkY,
                 a.ver[0], a.ver[1], a.ver[2]);
    std::printf("%lld slime chunks of %lld scanned (%.1f%%), %lld blocks of floor\n\n",
                 (long long)slimeChunks.size(), scanned,
                 100.0 * (double)slimeChunks.size() / (double)scanned, floorBlocks);

    // ---- Section 0: SEED ----
    std::printf("--- 0. SEED ---\n%lld\n\n", a.seed);

    // ---- Section 1: TELEPORT (no /spawnpoint - removed 2026-09-12, not used) ----
    std::printf("--- 1. TELEPORT ---\n");
    std::printf("/tp @p %lld %lld %lld\n", a.centerX, a.afkY, a.centerZ);
    std::printf("/gamerule %s false\n", versionAtLeast(a.ver, 1, 21, 11) ? "spawn_mobs" : "doMobSpawning");
    std::printf("/seed\n\n");

    // ---- Section 2: VOID THE AREA (WorldEdit) ----
    std::printf("--- 2. VOID THE AREA (WorldEdit) ---\n");   // no //fast (removed 2026-09-12, not used)
    // CHUNK-BORDERED (project owner, 2026-09-13): the box covers exactly the chunks the floor is built in (cxMin..cxMax,
    // czMin..czMax) - a box of +-radius blocks cut through chunks, leaving part of an edge slime chunk under terrain.
    std::printf("//pos1 %lld,%lld,%lld\n", cxMin * 16, a.y, czMin * 16);
    std::printf("//pos2 %lld,%lld,%lld\n", cxMax * 16 + 15, a.voidTop, czMax * 16 + 15);
    std::printf("//replace air\n\n");   // only touches non-air blocks: much faster than //set air

    // ---- Section 3: SLIME CHUNK FLOOR (command minecarts - the only form built with;
    //      the old chain-command-block form "3a" was removed 2026-09-12) ----
    std::printf("--- 3. SLIME CHUNK FLOOR - command minecarts (paste into ONE command block) ---\n");
    {
        // The Health:0 armor stand between the redstone and the rail is what makes the rail land on
        // 1.13 - 1.17 (without it a real 1.16.5 server fires no minecart at all); newer versions build
        // the same either way, so one form serves every version.
        std::string mono = "summon falling_block ~ ~1 ~ {BlockState:{Name:\"minecraft:redstone_block\"},Time:1,"
                            "Passengers:[{id:\"minecraft:armor_stand\",Health:0f,"
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
        // TEARDOWN - order is load-bearing, and the old order did not work: its first cart removed
        // the rail, so the carts after it were no longer on an activator rail and never fired -
        // the redstone block and every minecart stayed behind (seen on a real 1.21.11 server,
        // vanilla_world_test.py). Now: one cart places an auto command block ABOVE the rail that
        // clears itself, the rail and the redstone block on the next tick; the last cart kills
        // the minecarts while the rail is still there. The command block you pasted into stays.
        mono += "{id:\"minecraft:command_block_minecart\",Command:\"setblock ~ ~1 ~ command_block{auto:1b,Command:\\\"fill ~ ~ ~ ~ ~-2 ~ air\\\"}\"},";
        mono += "{id:\"minecraft:command_block_minecart\",Command:\"kill @e[type=command_block_minecart,distance=..3]\"}";
        mono += "]}]}]}";
        std::printf("%s\n\n", mono.c_str());
        std::printf("(%zu characters, %zu fills)\n\n", mono.size(), slimeChunks.size());
    }

    // ---- Section 4: MEASURE - a /give for the measuring block (repeating, unconditional, always
    //      active, running perimeterinfo at the player). Fits in chat, unlike the section-3 command.
    //      1.20.5+ uses the item-component form, older versions the BlockEntityTag NBT form. ----
    std::printf("--- 4. MEASURE - repeating command block, unconditional, always active ---\n");
    if (versionAtLeast(a.ver, 1, 20, 5))
        std::printf("/give @p repeating_command_block[block_entity_data={id:\"minecraft:command_block\","
                    "Command:\"execute at @p run perimeterinfo\",auto:1b}]\n");
    else
        std::printf("/give @p minecraft:repeating_command_block{BlockEntityTag:{Command:\"execute at @p run perimeterinfo\",auto:1b}}\n");

    return 0;
}
