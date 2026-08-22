# build.ps1 - all three, one folder, one slime_core.h
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
Write-Host " eligible spawn blocks / 256. Current record: " -NoNewline
Write-Host "66.04 cq" -ForegroundColor $y -NoNewline
Write-Host ", verified in game at " -NoNewline
Write-Host "17,112 spawning spaces" -ForegroundColor $y -NoNewline
Write-Host "."
Write-Host " A 66.21 cq result exists too, but measured WORSE in game - records rank by"
Write-Host " the in-game count, not the model number. Beating 66.04 is the goal."
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
Write-Host "   AI_CONTEXT.md           everything, dense - the one file to hand an AI"
Write-Host ""
Write-Host "------------------------------------------------------------------------------" -ForegroundColor $y
Write-Host " TWO WAYS TO USE THIS" -ForegroundColor $y
Write-Host ""
Write-Host " 1. STANDALONE - it is fully self-contained." -ForegroundColor $w
Write-Host "    Every capability above is reachable from the commands in README.txt. No"    -ForegroundColor $g
Write-Host "    AI, no account, no internet needed - just build it and run the commands."   -ForegroundColor $g
Write-Host "    The docs are written to be sufficient on their own."                        -ForegroundColor $g
Write-Host ""
Write-Host " 2. WITH CLAUDE (or any AI assistant) - much easier, and recommended." -ForegroundColor $w
Write-Host "    Point it at this folder and ask in plain English. It reads every source"    -ForegroundColor $g
Write-Host "    file and doc here and answers immediately, including things written down"   -ForegroundColor $g
Write-Host "    nowhere. It can also DO the work: run hunts, score a seed you paste in,"    -ForegroundColor $g
Write-Host "    find the best spot near spawn, generate the in-game commands, explain any"  -ForegroundColor $g
Write-Host "    number it produced, retune for your GPU, or add features outright."         -ForegroundColor $g
Write-Host ""
Write-Host "    The difference is real: standalone means finding the right flag across"     -ForegroundColor $g
Write-Host "    four documents and four tools, then reading the output yourself. With an"   -ForegroundColor $g
Write-Host "    assistant you say what you want and it handles the flags, chains the"       -ForegroundColor $g
Write-Host "    tools, and tells you what the numbers mean. This whole project was built"   -ForegroundColor $g
Write-Host "    that way."                                                                  -ForegroundColor $g
Write-Host ""
Write-Host "    Try: " -NoNewline -ForegroundColor $g
Write-Host "`"read AI_CONTEXT.md, then hunt for a record`"" -ForegroundColor $w
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
Write-Host " - ask an assistant to do it, or see the CURRENT TUNING section" -ForegroundColor $g
Write-Host "   in AI_CONTEXT.md to do it by hand." -ForegroundColor $g
Write-Host "------------------------------------------------------------------------------" -ForegroundColor $y
