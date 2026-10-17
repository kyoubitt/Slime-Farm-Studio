#include "Inputs.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

static char *readLine(char *buf, int size) {
    if (!fgets(buf, size, stdin)) return NULL;
    char *s = buf;
    if ((unsigned char)s[0] == 0xEF && (unsigned char)s[1] == 0xBB && (unsigned char)s[2] == 0xBF) s += 3;
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

static int isEmpty(const char *s) { return *s == '\n' || *s == '\r' || *s == 0; }

static int parseI64(const char *s, int64_t *out) {
    char *end;
    errno = 0;
    long long v = strtoll(s, &end, 10);
    if (end == s) return 0;
    while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n') end++;
    if (*end != 0 || errno == ERANGE) return 0;
    *out = (int64_t)v;
    return 1;
}

static int readI64(const char *name, int64_t *out, int hasDefault, int64_t defaultValue, int64_t min, int64_t max) {
    char buf[128];
    for (;;) {
        char *s = readLine(buf, sizeof buf);
        if (!s || isEmpty(s)) {
            if (hasDefault) { *out = defaultValue; return 1; }
            if (!s) return 0;
            printf("A value is required, enter %s:\n", name);
            continue;
        }
        int64_t v;
        if (!parseI64(s, &v)) { printf("Entered value is not valid, enter %s:\n", name); continue; }
        if (v < min || v > max) {
            printf("Entered value must be between %" PRId64 " and %" PRId64 ", enter %s:\n", min, max, name);
            continue;
        }
        *out = v;
        return 1;
    }
}

int getI64Number(const char *name, int64_t *out, int hasDefault, int64_t defaultValue, int64_t min, int64_t max) {
    if (hasDefault) printf("Enter %s (leave empty for %" PRId64 "):\n", name, defaultValue);
    else printf("Enter %s:\n", name);
    if (!readI64(name, out, hasDefault, defaultValue, min, max)) return 0;
    return 1;
}

int getIntEnum(const char *name, int *out, const char *const *elements, int elementCount) {
    printf("Enter %s:\n", name);
    for (int i = 0; i < elementCount; i++) printf("%d - %s\n", i, elements[i]);
    int64_t v;
    if (!readI64(name, &v, 0, 0, 0, elementCount - 1)) return 0;
    *out = (int)v;
    return 1;
}

