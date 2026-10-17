// cuda_device.h - --device N, shared by hotspot_scan.cu and slime_gpu.cu.
//
// Without this every process piles onto GPU 0 regardless of how many cards
// exist (AI_CONTEXT.md, "WHAT'S GENUINELY NOT DONE"). The flag is consumed
// and REMOVED from argv before the tool's own parser runs, so neither tool's
// "unknown arg" check needs to know about it, and slime_gpu's --worker spot
// lines (parsed by the same parseOneArg) never see it - a device is chosen
// once per process, because a worker's CUDA context lives on one card.
//
// Also honours SLIME_DEVICE=N from the environment, so the orchestration
// scripts can pin a whole cycle (every hotspot_scan + slime_gpu it spawns)
// without threading a flag through each command line. An explicit --device
// wins over the environment.
#pragma once
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cuda_runtime.h>

static int selectCudaDevice(int& argc, char** argv) {
    int dev = -1;
    const char* env = getenv("SLIME_DEVICE");
    if (env && *env) dev = atoi(env);
    int w = 1;
    for (int r = 1; r < argc; r++) {
        if (!strcmp(argv[r], "--device")) {
            if (r + 1 >= argc) { fprintf(stderr, "--device needs a value\n"); exit(1); }
            dev = atoi(argv[++r]);
            continue;
        }
        argv[w++] = argv[r];
    }
    argc = w;
    argv[argc] = nullptr;
    if (dev < 0) return 0;

    int n = 0;
    cudaError_t e = cudaGetDeviceCount(&n);
    if (e != cudaSuccess) {
        fprintf(stderr, "CUDA error: %s (cudaGetDeviceCount)\n", cudaGetErrorString(e));
        exit(1);
    }
    if (dev >= n) {
        fprintf(stderr, "--device %d: only %d CUDA device(s) present (0..%d)\n", dev, n, n - 1);
        exit(1);
    }
    e = cudaSetDevice(dev);
    if (e != cudaSuccess) {
        fprintf(stderr, "CUDA error: %s (cudaSetDevice %d)\n", cudaGetErrorString(e), dev);
        exit(1);
    }
    return dev;
}
