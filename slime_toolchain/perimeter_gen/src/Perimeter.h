#ifndef PERIMETER_H
#define PERIMETER_H

#include <stddef.h>
#include <stdint.h>

#define VERSION_1_13 0
#define VERSION_1_18 1
#define VERSION_1_20_5 2
#define VERSION_1_21_11 3
#define VERSION_COUNT 4

#define COMMAND_BLOCK_LIMIT 32500

extern const char *const VERSION_NAMES[VERSION_COUNT];
extern const char *const VERSION_TAGS[VERSION_COUNT];

typedef struct {
    int64_t seed;
    int64_t x;
    int64_t z;
    int version;
} Options;

typedef struct {
    int slimeChunks;
    int scannedChunks;
    int floorFills;
    int borderFills;
    long long borderBlocks;
    size_t floorChars;
    size_t borderChars;
    int floorY;
} Report;

int generatePerimeter(const Options *opt, const char *path, Report *rep);

#endif
