# build.ps1 - every tool, one folder, one slime_core.h (build.sh is the Linux twin)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)

# nvcc needs cl.exe on PATH for host-side compilation, and depending on which
# shell launched this it often is not. The failure mode is nasty: nvcc errors,
# the old .exe files survive, and the self-tests below "pass" against stale
# binaries - proving nothing about the code just edited. So: locate cl.exe via
# vswhere and prepend it, and refuse to run if it cannot be found.
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $cl = $null
    if (Test-Path $vswhere) {
        $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vs) {
            $cl = Get-ChildItem "$vs\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe" -ErrorAction SilentlyContinue |
                  Sort-Object FullName -Descending | Select-Object -First 1
        }
    }
    if (-not $cl) { Write-Host "cl.exe not found - install VS C++ build tools or fix PATH" -ForegroundColor Red; exit 1 }
    $env:PATH = "$($cl.DirectoryName);$env:PATH"
    Write-Host "cl.exe: $($cl.FullName)" -ForegroundColor DarkGray
}
Write-Host "building..." -ForegroundColor Cyan
# the folders the scripts write into (data\DATA.txt, "FOLDER TREE") - some append to a log there without creating it
New-Item -ItemType Directory -Force -Path main\logs, main\records, main\theory\heat, main\theory\prediction, main\work | Out-Null
# --use_fast_math: safe here specifically because the hot paths (the LCG,
# popcount) are integer/bitwise, not the transcendentals/div/sqrt approximations
# this flag actually changes. Verified before adopting: self-tests pass exactly
# on both .cu files, and --check's real output (mask, cqCeil, pWin, etc.) is
# byte-for-byte identical to a non-fast-math build - only the printed elapsed
# time differs (~8-10% faster).
nvcc -O3 -arch=native --use_fast_math hotspot_scan.cu -o hotspot_scan.exe
if ($LASTEXITCODE -ne 0) { Write-Host "hotspot_scan.cu FAILED TO COMPILE" -ForegroundColor Red; exit 1 }
nvcc -O3 -arch=native --use_fast_math slime_gpu.cu    -o slime_gpu.exe
if ($LASTEXITCODE -ne 0) { Write-Host "slime_gpu.cu FAILED TO COMPILE" -ForegroundColor Red; exit 1 }
nvcc -O3                slime_refine.cpp -o slime_refine.exe
if ($LASTEXITCODE -ne 0) { Write-Host "slime_refine.cpp FAILED TO COMPILE" -ForegroundColor Red; exit 1 }
nvcc -O3                perimeter_setup.cpp -o perimeter_setup.exe
if ($LASTEXITCODE -ne 0) { Write-Host "perimeter_setup.cpp FAILED TO COMPILE" -ForegroundColor Red; exit 1 }
nvcc -O3                afk_rescan.cpp -o afk_rescan.exe
if ($LASTEXITCODE -ne 0) { Write-Host "afk_rescan.cpp FAILED TO COMPILE" -ForegroundColor Red; exit 1 }
nvcc -O3                geo_rank.cpp -o geo_rank.exe
if ($LASTEXITCODE -ne 0) { Write-Host "geo_rank.cpp FAILED TO COMPILE" -ForegroundColor Red; exit 1 }
# slime_cpu / slime_cl: the same position search without CUDA (AMD, Intel, or any CPU). The repo ships built copies;
# a failure here is only a warning, since slime_gpu already does the job on this machine.
nvcc -O3 -Xcompiler "/arch:AVX2" slime_cpu.cpp -o slime_cpu.exe
if ($LASTEXITCODE -ne 0) { Write-Host "slime_cpu.cpp did not compile (the shipped slime_cpu.exe still works)" -ForegroundColor Yellow }
nvcc -O3                slime_cl.cpp -o slime_cl.exe
if ($LASTEXITCODE -ne 0) { Write-Host "slime_cl.cpp did not compile (the shipped slime_cl.exe still works)" -ForegroundColor Yellow }
# phase_prepass: no --use_fast_math (its own header's build line)
nvcc -O3 -arch=native   phase_prepass.cu -o phase_prepass.exe
if ($LASTEXITCODE -ne 0) { Write-Host "phase_prepass.cu FAILED TO COMPILE" -ForegroundColor Red; exit 1 }
# perimeter_gen: the vendored Slime Chunk Perimeter Generator (C11), linked against slime_core.h
# through a one-function shim so it shares the exact isSlimeChunk every other tool uses.
New-Item -ItemType Directory -Force -Path main\work\build | Out-Null
cl /nologo /O2 /std:c++17 /EHsc /c perimeter_gen\slime_core_shim.cpp /Fomain\work\build\slime_core_shim.obj
if ($LASTEXITCODE -ne 0) { Write-Host "perimeter_gen FAILED TO COMPILE" -ForegroundColor Red; exit 1 }
cl /nologo /O2 /std:c11 /W3 /D_CRT_SECURE_NO_WARNINGS /DSLIME_CORE_SHIM /Fomain\work\build\ /Feperimeter_gen\perimeter_gen.exe `
    perimeter_gen\src\main.c perimeter_gen\src\Perimeter.c perimeter_gen\src\util\Inputs.c main\work\build\slime_core_shim.obj
if ($LASTEXITCODE -ne 0) { Write-Host "perimeter_gen FAILED TO COMPILE" -ForegroundColor Red; exit 1 }
Write-Host "`nself-tests (all three must pass)" -ForegroundColor Cyan
.\hotspot_scan.exe --self-test; if ($LASTEXITCODE -ne 0) { Write-Host "hotspot_scan FAILED" -ForegroundColor Red; exit 1 }
.\slime_gpu.exe    --self-test; if ($LASTEXITCODE -ne 0) { Write-Host "slime_gpu FAILED"    -ForegroundColor Red; exit 1 }
.\slime_refine.exe --self-test; if ($LASTEXITCODE -ne 0) { Write-Host "slime_refine FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nAll three self-tests passed." -ForegroundColor Green
Write-Host "perimeter_setup.exe built (no --self-test - it only formats commands from the" -ForegroundColor DarkGray
Write-Host "already-validated isSlimeChunk; there is no independent ground truth to check" -ForegroundColor DarkGray
Write-Host "against except Minecraft itself)." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Orientation banner. build.ps1 is the mandatory first step on any machine, so
# it is the one place guaranteed to be seen before anything else - which makes
# it the right place to say what this thing actually does. Someone handed this
# folder cold otherwise has to guess which of four docs to open first.
# ---------------------------------------------------------------------------
$c = "Cyan"; $g = "Gray"; $y = "Yellow"; $w = "White"
Write-Host ""
Write-Host "==============================================================================" -ForegroundColor $c
Write-Host " WHAT THIS IS" -ForegroundColor $c
Write-Host "==============================================================================" -ForegroundColor $c
Write-Host " Finds the best possible Minecraft slime-chunk farm spot. It searches world"
Write-Host " SEEDS (not just locations) for a spot where the most slime chunks fall inside"
Write-Host " the 24-128 block spawning ring around one AFK point, and scores it as " -NoNewline
Write-Host "cq" -ForegroundColor $w -NoNewline
Write-Host " ="
Write-Host " eligible spawn blocks / 256. Best measured in game so far: " -NoNewline
Write-Host "20,506 spawning spaces" -ForegroundColor $y -NoNewline
Write-Host ", " -NoNewline
Write-Host "76.23 cq" -ForegroundColor $y
Write-Host " (feet at y -39). Ranking is by the in-game number, not the model's."
Write-Host ""
Write-Host " THE FOUR TOOLS" -ForegroundColor $c
Write-Host "   hotspot_scan     WHERE to hunt - picks promising spots, derives a seed mask"
Write-Host "   slime_gpu        THE HUNT     - brute-forces seeds at a spot on the GPU"
Write-Host "   slime_refine     WHAT IT'S WORTH - exact cq at block precision (replaces"
Write-Host "                    the community SlimeFinder.jar entirely)"
Write-Host "   perimeter_setup  IS IT REAL   - emits in-game commands to build a test rig"
Write-Host "                    you can measure with Carpet's /perimeterinfo"
Write-Host ""
Write-Host " WHAT YOU CAN ACTUALLY DO" -ForegroundColor $c
Write-Host "   * Hunt for a new record, fully automated and resumable across sessions"
Write-Host "   * Score any seed you already have, at any location"
Write-Host "   * Find the best spot within N blocks of spawn for a FIXED seed"
Write-Host "   * Generate thousands of seeds that all share one known-good farm layout"
Write-Host "   * Build an in-game rig to verify any result against Minecraft itself"
Write-Host "   * Get PNG maps + text reports of every good find, filed automatically"
Write-Host ""
Write-Host " START HERE" -ForegroundColor $c
Write-Host "   python slime gui" -ForegroundColor $w
Write-Host "       the app, right in this terminal: map, best spot, perimeter commands, build guide"
Write-Host "   python slime" -ForegroundColor $w
Write-Host "       a numbered menu of the same jobs (HOW_TO_USE.txt); python slime doctor checks your setup"
Write-Host "   powershell -ExecutionPolicy Bypass -File record_cycle.ps1 -Status" -ForegroundColor $w
Write-Host "       progress so far - runs nothing, safe to start with"
Write-Host "   powershell -ExecutionPolicy Bypass -File record_cycle.ps1 -Repeat 12" -ForegroundColor $w
Write-Host "       hunt for a record; resumable, stops itself if it finds one"
Write-Host "   powershell -ExecutionPolicy Bypass -File stop_all.ps1" -ForegroundColor $w
Write-Host "       the ONLY correct way to stop - killing by hand orphans a GPU process"
Write-Host ""
Write-Host " DOCS" -ForegroundColor $c
Write-Host "   FEATURES.txt            capability checklist, shortest read"
Write-Host "   STEP_BY_STEP_GUIDE.txt  concepts, easiest to hardest"
Write-Host "   README.txt              full command reference"
Write-Host "   OVERVIEW.md           start here: the hunt, its numbers, known answers"
Write-Host "   docs\                   the detail (docs\REFERENCE.md: the older full reference)"
Write-Host ""
Write-Host "------------------------------------------------------------------------------" -ForegroundColor $y
Write-Host ""
Write-Host " NEXT: BENCHMARK THIS MACHINE" -ForegroundColor $c
Write-Host "   powershell -ExecutionPolicy Bypass -File stress_toolchain.ps1 -Quick" -ForegroundColor $w
Write-Host "   ...or just:  " -NoNewline
Write-Host "hotspot_scan.exe --bench --center-x 0 --center-z 0 --range 40" -ForegroundColor $w
Write-Host ""
Write-Host "   Every tuned default shipped here (-Seconds, -GateTop, -Top, projected run" -ForegroundColor $g
Write-Host "   times) was measured on one specific GPU. The bench prints what YOUR machine" -ForegroundColor $g
Write-Host "   actually does. Once you have those numbers, re-tuning the defaults to match" -ForegroundColor $g
Write-Host "   is " -NoNewline -ForegroundColor $g
Write-Host "recommended" -NoNewline -ForegroundColor $y
Write-Host " - see the CURRENT TUNING section" -ForegroundColor $g
Write-Host "   in docs\REFERENCE.md to do it by hand." -ForegroundColor $g
Write-Host "------------------------------------------------------------------------------" -ForegroundColor $y
