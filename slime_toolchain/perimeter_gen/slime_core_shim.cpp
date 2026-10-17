// C entry point into the finder's slime_core.h, so the vendored perimeter
// generator (C11) scores chunks with the same function as every other tool.
#include <cstdint>
#include "../slime_core.h"

extern "C" int slime_core_is_slime_chunk(int64_t worldSeed, int32_t chunkX, int32_t chunkZ) {
    return isSlimeChunk((long long)worldSeed, chunkX, chunkZ) ? 1 : 0;
}
