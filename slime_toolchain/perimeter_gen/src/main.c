#include <stdio.h>

#include "Perimeter.h"
#include "util/Inputs.h"

int main(void) {
    printf("Slime Chunk Perimeter Gen\n\n");

    Options opt;
    int64_t value;

    if (!getI64Number("world seed", &value, 0, 0, INT64_MIN, INT64_MAX)) return 1;
    opt.seed = value;

    if (!getI64Number("center X in blocks", &value, 0, 0, -30000000, 30000000)) return 1;
    opt.x = value;

    if (!getI64Number("center Z in blocks", &value, 0, 0, -30000000, 30000000)) return 1;
    opt.z = value;

    if (!getIntEnum("game version", &opt.version, VERSION_NAMES, VERSION_COUNT)) return 1;

    char path[128];
    snprintf(path, sizeof path, "perimeter_%lld_%lld_%lld_%s.txt",
             (long long)opt.seed, (long long)opt.x, (long long)opt.z, VERSION_TAGS[opt.version]);

    Report rep;
    if (!generatePerimeter(&opt, path, &rep)) {
        printf("\nCould not write %s\n", path);
        return 1;
    }

    printf("\n%s\n", path);
    printf("  %d slime chunks of %d, floor at y %d\n", rep.slimeChunks, rep.scannedChunks, rep.floorY);
    printf("  floor  %d fills, %zu characters\n", rep.floorFills, rep.floorChars);
    printf("  border %d fills, %lld blocks, %zu characters\n", rep.borderFills, rep.borderBlocks, rep.borderChars);
    if (rep.floorChars > COMMAND_BLOCK_LIMIT || rep.borderChars > COMMAND_BLOCK_LIMIT)
        printf("  WARNING a command is over the %d character command block limit\n", COMMAND_BLOCK_LIMIT);
    return 0;
}
