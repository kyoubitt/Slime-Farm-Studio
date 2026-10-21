#!/usr/bin/env bash
# build.sh - Linux equivalent of build.ps1: all four tools, one folder, one
# slime_core.h, then the three self-tests. Mandatory first step on any machine
# (see AI_CONTEXT.md, "STOP - BUILD FIRST"): -arch=native bakes in THIS
# GPU's compute capability, so binaries from another box will not run here.
#
#   ./build.sh            build + self-tests + orientation banner
#   ./build.sh --no-test  build only
#   ./build.sh --cpu-only just the tools that need no GPU (slime_refine, perimeter_setup, afk_rescan, geo_rank,
#                         perimeter_gen). This is also what happens, with a note, when there's no nvcc: macOS
#                         and any machine without an NVIDIA GPU. The app then does Manual scoring, the map and
#                         the perimeter commands; Best AFK / Cluster search needs the GPU build.
#
# Environment overrides:
#   NVCC=/path/to/nvcc     default: nvcc on PATH, else /opt/cuda/bin/nvcc,
#                          else /usr/local/cuda/bin/nvcc
#   NVCC_CCBIN=g++-14      host compiler for nvcc, if the system g++ is newer
#                          than this CUDA release supports
#   CUDA_ARCH=sm_89        instead of -arch=native (e.g. building on a box
#                          whose GPU is not the one the binaries will run on)
#   CXX=clang++            compiler for the two CPU-only tools (default g++)
set -euo pipefail
here="$0"; [[ -L "$here" ]] && here="$(readlink "$here")"       # no readlink -f: older macOS doesn't have it
cd "$(dirname "$here")"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
cyan() { printf '\033[36m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
dim()  { printf '\033[90m%s\033[0m\n' "$*"; }

RUN_TESTS=1
CPU_ONLY=0
for a in "$@"; do
    case "$a" in
        --no-test) RUN_TESTS=0 ;;
        --cpu-only) CPU_ONLY=1 ;;
    esac
done

NVCC="${NVCC:-}"
if [[ -z "$NVCC" ]]; then
    for c in "$(command -v nvcc || true)" /opt/cuda/bin/nvcc /usr/local/cuda/bin/nvcc; do
        [[ -n "$c" && -x "$c" ]] && { NVCC="$c"; break; }
    done
fi
if (( ! CPU_ONLY )) && [[ -z "$NVCC" ]]; then
    printf '\033[33m%s\033[0m\n' "nvcc not found - building the CPU tools only (no GPU search)."
    dim "For the GPU search install the CUDA toolkit (Arch: sudo pacman -S cuda), or point NVCC= at it, then run ./build.sh again."
    CPU_ONLY=1
fi
(( CPU_ONLY )) || dim "nvcc: $NVCC ($("$NVCC" --version | sed -n 's/.*release \([0-9.]*\).*/\1/p'))"

CXX="${CXX:-g++}"
command -v "$CXX" >/dev/null || { red "$CXX not found - install a C++ compiler"; exit 1; }

NVFLAGS=(-O3 --use_fast_math -std=c++17)
if [[ -n "${CUDA_ARCH:-}" ]]; then NVFLAGS+=(-arch="$CUDA_ARCH"); else NVFLAGS+=(-arch=native); fi
[[ -n "${NVCC_CCBIN:-}" ]] && NVFLAGS+=(-ccbin "$NVCC_CCBIN")

# Delete first. The Windows build learned this the hard way: if a compile
# fails and the old binary survives, the self-tests below "pass" against it
# and prove nothing about the source just edited.
ALL_TOOLS=(hotspot_scan slime_gpu slime_refine perimeter_setup afk_rescan geo_rank phase_prepass)
TOOLS=(slime_refine perimeter_setup afk_rescan geo_rank)
(( CPU_ONLY )) || TOOLS=("${ALL_TOOLS[@]}")
for t in "${ALL_TOOLS[@]}"; do rm -f "$t" "$t.exe"; done
rm -f perimeter_gen/perimeter_gen

cyan "building..."
# --use_fast_math: safe here specifically because the hot paths (the LCG,
# popcount) are integer/bitwise - see build.ps1 for the measurement.
build() { local name="$1"; shift; if ! "$@"; then red "$name FAILED TO COMPILE"; exit 1; fi; }
(( CPU_ONLY )) || build hotspot_scan.cu    "$NVCC" "${NVFLAGS[@]}" hotspot_scan.cu -o hotspot_scan
(( CPU_ONLY )) || build slime_gpu.cu       "$NVCC" "${NVFLAGS[@]}" slime_gpu.cu    -o slime_gpu
build slime_refine.cpp   "$CXX" -O3 -std=c++17 -pthread slime_refine.cpp    -o slime_refine
build perimeter_setup.cpp "$CXX" -O3 -std=c++17         perimeter_setup.cpp -o perimeter_setup
build afk_rescan.cpp     "$CXX" -O3 -std=c++17         afk_rescan.cpp   -o afk_rescan
build geo_rank.cpp       "$CXX" -O3 -std=c++17 -pthread geo_rank.cpp     -o geo_rank
# phase_prepass: its own header builds it without --use_fast_math, so this does too
PPFLAGS=(-O3 -std=c++17)
if [[ -n "${CUDA_ARCH:-}" ]]; then PPFLAGS+=(-arch="$CUDA_ARCH"); else PPFLAGS+=(-arch=native); fi
[[ -n "${NVCC_CCBIN:-}" ]] && PPFLAGS+=(-ccbin "$NVCC_CCBIN")
(( CPU_ONLY )) || build phase_prepass.cu   "$NVCC" "${PPFLAGS[@]}" phase_prepass.cu -o phase_prepass
# The .ps1 scripts call every tool as <name>.exe (one set of scripts for Windows and Linux):
# give each Linux binary that name too.
for t in "${TOOLS[@]}"; do ln -sf "$t" "$t.exe"; done
# perimeter_gen: the vendored Slime Chunk Perimeter Generator (C11), linked
# against slime_core.h through a one-function shim so it shares the exact
# isSlimeChunk every other tool uses (see perimeter_gen/slime_core_shim.cpp).
CC="${CC:-gcc}"
mkdir -p main/work/build
# the folders the scripts write into (data/DATA.txt, "FOLDER TREE") - some append to a log there without creating it
mkdir -p main/logs main/records main/theory/heat main/theory/prediction
build perimeter_gen "$CXX" -O2 -std=c++17 -c perimeter_gen/slime_core_shim.cpp -o main/work/build/slime_core_shim.o
build perimeter_gen "$CC" -O2 -std=c11 -DSLIME_CORE_SHIM perimeter_gen/src/main.c perimeter_gen/src/Perimeter.c \
    perimeter_gen/src/util/Inputs.c main/work/build/slime_core_shim.o -lstdc++ -o perimeter_gen/perimeter_gen

if (( RUN_TESTS )); then
    echo
    if (( CPU_ONLY )); then
        cyan "self-test"
        ./slime_refine --self-test || { red "slime_refine FAILED"; exit 1; }
        echo
        grn "slime_refine self-test passed (CPU-only build: no GPU tools)."
    else
        cyan "self-tests (all three must pass)"
        ./hotspot_scan --self-test || { red "hotspot_scan FAILED"; exit 1; }
        ./slime_gpu    --self-test || { red "slime_gpu FAILED";    exit 1; }
        ./slime_refine --self-test || { red "slime_refine FAILED"; exit 1; }
        echo
        grn "All three self-tests passed."
    fi
    dim "perimeter_setup built (no --self-test - it only formats commands from the"
    dim "already-validated isSlimeChunk; the only ground truth is Minecraft itself)."
fi

if (( CPU_ONLY )); then
    echo
    cyan "CPU-only build done: slime_refine, perimeter_setup, afk_rescan, geo_rank, perimeter_gen."
    dim "Run ./slime gui (or slimebyte). Best AFK / Cluster search needs an NVIDIA GPU + CUDA (then ./build.sh again);"
    dim "Manual scoring, the map and the perimeter commands work as they are."
    exit 0
fi

cat <<'EOF'

==============================================================================
 WHAT THIS IS
==============================================================================
 Finds the best possible Minecraft slime-chunk farm spot. It searches world
 SEEDS (not just locations) for a spot where the most slime chunks fall inside
 the 24-128 block spawning ring around one AFK point, and scores it as cq =
 eligible spawn blocks / 256. Best measured in game so far: 20,506 spawning
 spaces (76.23 cq, feet at y -39). Ranking is by the in-game number.

 THE FOUR TOOLS
   hotspot_scan     WHERE to hunt - picks promising spots, derives a seed mask
   slime_gpu        THE HUNT     - brute-forces seeds at a spot on the GPU
   slime_refine     WHAT IT'S WORTH - exact cq at block precision
   perimeter_setup  IS IT REAL   - emits in-game commands to build a test rig

 START HERE
   ./slime gui                                    the app, full screen in this terminal - easiest way in
   ./slime                                        a menu of the same jobs (HOW_TO_USE.txt)
   ./slime doctor                                 checks your setup, says how to fix anything
   ./slime best-spot --seed <SEED>                best farm spot in YOUR world
   ./slime y --seed <S> --x <X> --z <Z>           best standing height for a farm
   pwsh -File record_cycle.ps1 -Status            record-hunt progress, runs nothing
   pwsh -File record_cycle.ps1 -Repeat 12         hunt for a record; resumable
   pwsh -File stop_all.ps1                        the ONLY correct way to stop a hunt
   ./vanilla_parity.py / ./vanilla_world_test.py  1:1 checks against the real game

 NEXT: BENCHMARK THIS MACHINE
   pwsh -File stress_toolchain.ps1 -Quick
   ...or just:  ./hotspot_scan --bench --center-x 0 --center-z 0 --range 40

   Every tuned default was measured on one specific GPU. Re-tune -Seconds /
   -GateTop / -Top once you have numbers for yours (docs/REFERENCE.md,
   CURRENT TUNING).
------------------------------------------------------------------------------
EOF
