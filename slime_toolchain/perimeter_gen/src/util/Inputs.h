#ifndef INPUTS_H
#define INPUTS_H

#include <stdint.h>

int getI64Number(const char *name, int64_t *out, int hasDefault, int64_t defaultValue, int64_t min, int64_t max);
int getIntEnum(const char *name, int *out, const char *const *elements, int elementCount);

#endif
