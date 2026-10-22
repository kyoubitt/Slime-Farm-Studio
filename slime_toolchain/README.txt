================================================================================
 RECORD COMMANDS, IN ORDER  (kept up to date here - this is the section to
 check first; update it whenever the toolchain gains/changes a step)
================================================================================
New here? Run ./slime gui (the app, right in your terminal) or ./slime for a menu, or read HOW_TO_USE.txt
(one page) first. On Windows: python slime gui.
This file is the command reference. FEATURES.txt has a quick capability
checklist, STEP_BY_STEP_GUIDE.txt explains the concepts from easy to hard,
OVERVIEW.md is where to start, docs\ holds the detail, and docs\REFERENCE.md
is the older everything-in-one-place reference.
================================================================================
[STOP] BUILD FIRST. This copy ships NO .exe files, on purpose: they are compiled
  with -arch=native, which bakes in the GPU model, so a binary built on one card
  WILL NOT RUN on another. On the wrong card you get this, with no hint that rebuilding is
  the fix:
      CUDA error: no kernel image is available for execution on the device
  Verified for real: binaries built on the RTX PRO 6000 (sm_120) fail exactly
  like that on an RTX 4050 laptop (sm_89), and the same build.ps1 on that
  laptop rebuilt everything and passed all self-tests. So before ANY command
  below:

      powershell -ExecutionPolicy Bypass -File build.ps1

  LINUX: ./build.sh instead, then run every .ps1 below with pwsh
  (PowerShell 7): pwsh -File record_cycle.ps1 -Status. Needs the CUDA
  toolkit + g++ (Arch: sudo pacman -S cuda) and pwsh. See LINUX.md,
  which also covers the Y phase (y_phase.ps1) and the vanilla parity tests.

  Two prerequisites, neither of which ships here:
    * CUDA Toolkit (for nvcc). A toolkit-ONLY CUDA 13 install is missing
      pieces nvcc needs and cannot compile a .cu file at all - it needs the
      cuda_crt component (else "C1083: Cannot open include file:
      'crt/host_config.h'"), libnvvm (else a bare "The system cannot find
      the path specified."), and cuda_nvcc's bin/crt/ stubs (else link
      failures). Do NOT fix the first by copying the flat
      include/host_config.h into a new crt/ dir - those flat headers are
      deprecation wrappers that include "crt/host_config.h" themselves, so
      it self-references and gives "C1014: too many include files:
      depth = 1024". Pull the real redistributable components instead
      (component list + SHA-256s at developer.download.nvidia.com/compute/
      cuda/redist/redistrib_<version>.json).
    * Visual Studio Build Tools with the "Desktop development with C++"
      workload (for cl.exe, which nvcc calls for host code). build.ps1 finds
      it via vswhere and hard-fails if missing - deliberately, since
      otherwise nvcc errors, the old .exe files survive, and the self-tests
      "PASS" against stale binaries while proving nothing about the source.
  Skip the rebuild ONLY on the same machine that produced the binaries, with
  no source change since. See OVERVIEW.md's STOP section for detail.
================================================================================
[!!!] READ THIS BEFORE TRUSTING A SINGLE NUMBER BELOW: every wall-clock
  figure and every tuned default in this entire file (-Seconds, -GateTop,
  -Top, -Range, projected run times, all of it) was measured on ONE
  specific GPU. This is NOT a portable, works-anywhere set of numbers -
  it is THIS MACHINE'S numbers. Moving to different hardware WILL make
  some of these wrong, possibly by an order of magnitude (this project's
  own history: the exact same code went from ~66.7k to 2.7M loc/s and from
  4M to 54-58M seeds/s between two real GPUs already used here - a 13-41x
  swing). Before trusting or reusing any timing-based setting on a new
  machine: build it, run every self-test, run --bench and a short
  --time-limit-ms hunt, and re-derive -Seconds/-GateTop/etc. from THOSE
  numbers. Only SEED-COUNT constants (--give-up-after and friends) are
  safe to copy across hardware unchanged.
================================================================================
[!] HARDWARE NOTE - this toolchain is now tuned for an RTX PRO 6000 Blackwell
  (188 SMs, 96 GB, sm_120). Measured there: scan pass 1 2.74M loc/s, pass 2
  0.14 s/spot, hunt 54.4M seeds/s fused+GPU-seedgen (58.1M with CUDA-stream
  double-buffering) (was ~66.7k / ~1-3s / 4M on the old laptop GPU). Several
  consequences are baked into the defaults below:
    * the FUSED hunt kernel is now the DEFAULT (--no-fused to opt out). The
      two-kernel path writes a heavily padded bitmap to global memory and reads
      it back, which made the hunt memory-bound; fused is 2.04x faster and
      proven byte-identical under a fixed --rng-seed.
    * hunt seeds are generated ON THE GPU by default (genSeedsKernel), not a
      single-threaded CPU loop - 1.31x, since the CPU leg used to idle the GPU.
    * slime_gpu.exe --worker keeps one CUDA context alive across many spots
      instead of paying a ~199ms process-spawn cost per spot (2.69x on
      all-dead-family workloads). hunt_pipeline.ps1 uses it by default
      (-NoWorker to opt out); --climb-scan also runs through the same worker.
    * CUDA streams double-buffer the hunt's batch upload/compute/download
      (--no-stream to opt out) - ~10.7% more throughput, GPU utilization
      84-87% -> 91-94%. This does not shorten a fixed wall-clock cycle (the
      budgets below are TIME budgets, not seed-count budgets) - it means more
      seeds get tested inside the same window.
    * wall-clock budgets were rebalanced toward BREADTH (-Seconds 12->4,
      -PushSeconds 40->15, -Top 40->120, -GateTop 220->600). At current
      throughput a 4s triage still draws far more seeds than 12s ever did on
      the old GPU - so this buys more spots WITHOUT hunting any spot shallower.
  If you move to different hardware, re-measure with --bench before trusting
  any wall-clock number here. Constants denominated in SEEDS
  (--give-up-after 20000000 etc.) are hardware-independent and need no change.

[0] BUILD (once per new file set):
  powershell -ExecutionPolicy Bypass -File build.ps1
  Needs nvcc + cl.exe. On a fresh box, a CUDA "toolkit only, no driver" install
  must include the cuda_crt and libnvvm components or nvcc cannot compile a .cu
  at all (CUDA 13 split them out of cuda_nvcc).

[*] THE RECORD SEARCH - EXACT PHASE SEARCH (the main mode):
  powershell -ExecutionPolicy Bypass -File record_cycle.ps1 -PhaseSearch -BestFamilySpots main\best_spots.csv -Repeat 1000   run (resumable, new spots only)
  New-Item main\STOP_WR                                                  stop after the current spot (clean)
  powershell -ExecutionPolicy Bypass -File stop_all.ps1                  stop everything at once
  powershell -ExecutionPolicy Bypass -File record_cycle.ps1 -Status      progress
    Per spot: every seed of the top 5% of families by possible chunks (ranked separately at each AFK
    position), at the 10 best of 15 AFK positions, solved EXACTLY with the phase model
    (docs\PHASE_MODEL.txt) - no sampling; the top ~600 layouts refined to block precision
    (slime_refine, Z radius 7). ~12.8 s per spot on the laptop RTX 4050 (1.44x kernel).
    Every 66+ farm is filed into main\records\ (tier folders, over66.csv, over66_images, and
    over66_y-39 named by its -39 estimate - see RAISED-AFK FOLDER). Logs: main\cycles.txt (one line
    per 10 spots), main\theory\heat\phase_search.csv (one row per spot).
  SPOT LIST: main\best_spots.csv - 500 spots, already ranked hottest-first, shipped with this copy.
  Pass it explicitly: -BestFamilySpots main\best_spots.csv. The whole-world survey that built it
  (heat\spot_top.ps1) is not included, but its survey modes (hotspot_scan --heat-survey /
  --heat-rows / --heat-spots) are. Any CSV with X,Z,Line,Heat40 columns works as a spot list.
  SAFETY: a family-cut check every 50 spots (main\theory\heat\cut_checks.csv). The regression gate
  (heat\phase_regress.ps1) that the original project ran before changing the search is not shipped.
  IN GAME: perimeter setups on request (perimeter_setup.exe -> main\records\perimeter\); your
  measurements go in main\records\measured_in_game.csv - the game's number always wins.
  PREDICTION SEARCH (separate) - picks WHICH spots the exact search visits:
  (NOT AVAILABLE IN THIS COPY: it needs the whole-world heat survey main\theory\heat\spot_measured.csv - 183,536 spots - which is not shipped, so predict_cycle.ps1 prints a notice and exits. The method is described below for reference; use the shipped 500-spot list instead: record_cycle.ps1 -PhaseSearch -BestFamilySpots main\best_spots.csv)
  powershell -ExecutionPolicy Bypass -File predict_cycle.ps1 -Repeat 1000          run (resumable)
    Per cycle (~22 min): 2,000 fresh spots from the whole-world survey (heat 20+: half the hottest not yet
    screened, half random - rich spots hide at low heat), screened by phase_prepass (PROBE screen:
    8 classes on every family of the top 0.25%, then all 32,768 classes of the best 64 -
    0.24 s/spot), the top 10% again wider (top 1%, best 128), scored (stage-2 best + log2(1 + pairs
    reaching 68)), and the top 50 exact-searched by the normal exact search. First test: its picks held
    67+ at 30% of spots vs 7% for the heat list, 68+ 14% vs 1%, four farms of 69.9+ from 50 spots.
    The probe screen finds a spot's TRUE exact best (within 2) at 84-94%, against 34% for the old 512-class
    sample at the same price (180 spots of known exact best) - the picks are now the chunk's real best spots.
  (heat\rescreen.ps1, a one-shot re-screen of old spots, is not shipped in this copy.)
    Logs: main\predict_cycles.txt, main\theory\prediction\screened.csv (every screened spot). Stop:
    main\STOP_WR or stop_all.ps1. The exact search itself is unchanged; unpicked spots stay available.
  Plain record_cycle.ps1 (no mode) is the OLD square-scan hunt, kept for reference below.
  RECORD HUNT - BEST-FAMILY MODE (previous):
  powershell -ExecutionPolicy Bypass -File record_cycle.ps1 -BestFamily -BestFamilySpots main\best_spots.csv -Repeat 100
    Each spot is searched in the seed family it is BEST in. Spots: the hottest
    in the world from re-measured X and line values (heat\best_spots.ps1). Per
    spot: all 1,048,576 20-bit families swept (best AFK chunk within +-3 X / +-2
    Z), the top 8 re-checked, the best walked seed by seed (2^28 each). ~4 min
    per spot on a laptop, resumable, 10 spots per logged cycle. Stop: create
    main\STOP_WR. First test (23 spots): new 67.28, 66.73, 66.56, 66.61, 66.17.
  RECORD HUNT - HEAT MODE: RETIRED (record_cycle -Heat now only prints a pointer to
  -PhaseSearch; heat_spots.ps1 / record_odds.ps1 are in heat\old). History, for reference:
    found 67.24 on its first run.
    Hunted the hottest never-hunted spots in the WORLD: top X columns x top Z
    lines, ranked by an exact model of Java's slime formula. Measured head to
    head (same mask, one cycle): 60 hot spots 82% productive, 9 at >=63 cq,
    67.24 best - 60 typical spots 3% productive, best 58.26.
    Spots can be millions of blocks out (inside the 30M border): distance along
    a line does not change quality. See docs\REFERENCE.md "LINE / X / HEAT MODEL".
    Each cycle: a fresh list (no farm is ever hunted twice), its heat range, and
    its RECORD ODDS ("1 in N cycles", logged to main\logs\record_odds.csv - when
    N climbs too high, the hot spots are used up). Seeds >= 65 get a DEEP climb
    (bits 20-47, ~2-3 min) that the normal climb cannot match: 65.55 -> 66.31.
    Tune with -DeepClimbMinCQ; see docs\REFERENCE.md "CLIMBS" and "RECORD ODDS".
  (The heat helper scripts - heat_of, heat_spots, heat_ledger, record_odds - are not shipped in this copy.)
  LINE MODE (chosen Z lines only, long X, equal spots per line):
  powershell -ExecutionPolicy Bypass -File record_cycle.ps1 -Lines 3,4,5 -RangeX 150000 -AutoMask -NoAnchor -ReuseScan -Repeat 3
    Line n is centred on chunk row 48.5 + 96.875 n (period 1550 blocks, NOT the
    old 1552): line 3 = Z ~5426, 4 = ~6976, 5 = ~8526. Any n works.
  SQUARE SCAN (the older method):
  powershell -ExecutionPolicy Bypass -File record_cycle.ps1 -Range 50000 -AutoMask -NoAnchor -ReuseScan -Repeat 3
    Cycles are NUMBERED and resume across sessions - main\cycles.txt is the run
    log, main\families.csv the ledger of every (mask,val) already hunted, so a
    session days later never re-hunts old ground. Each cycle: scan -> 12s triage
    hunt per spot -> score -> GPU climb -> family sweep -> record push on the
    leaders, plus a guaranteed push on the record family itself. Anything 64+ is
    filed automatically into main\records\ (66+ today), named "<cq>_<seed>.{txt,png}"
    - its image also goes to over66_y-39\ (see RAISED-AFK FOLDER) - and
    deduplicated by pattern. A new record stops the queue and prints the /tp
    line.
    ALWAYS use stop_all.ps1 to stop - killing the script by hand leaves
    slime_gpu orphaned on the GPU, which breaks the NEXT run with
    "CUDA error: unknown error".

[1] SCAN for candidate spots (emits 15 hunt commands, no pre-judging):
  hotspot_scan.exe --scan --center-x 0 --center-z 0 --range 10000 --z-all --var-min 26 --gate-top 300 --score-t 68 --emit-top 15 --name hunt
  Add --derive-eff to also fix any free bit (up to --max-bits) that predicts
    packing EFFICIENCY, not just chunk-count - the ladder alone often uses the
    whole default budget, so raise --max-bits/--bit-window to give it room.
  Swap --emit-top 15 for --rank-by like to rank by resemblance to the known
    records instead of hard --eff-target/--min-pwin/--min-winners cutoffs
    (defaults to the two known records; override with repeatable --like X,Z):
    hotspot_scan.exe --scan --center-x 0 --center-z 0 --range 10000 --z-all --var-min 26 --gate-top 300 --score-t 68 --rank-by like --name likehunt

  BEST FOR ACTUALLY BEATING THE RECORD: --rank-by win --bit-window 20
    hotspot_scan.exe --scan --center-x 0 --center-z 6976 --range 500 --var-min 26 --gate-top 400 --score-t 70 --bit-window 20 --max-bits 17 --rank-by win --derive-eff --emit-top 20 --name win
    Three separate reasons, all measured:
    * --rank-by win ranks on winRate = p(count>=scoreT) x pWin = record-beaters
      per seed sampled. The default key (winners) multiplies that by 2^(48-bits),
      which swings ~128x on mask tightness alone and so ranks a loose mediocre
      family above a tight excellent one. winRate is family-size independent:
      expected seconds to a record = 1/(winRate x seeds_per_sec).
    * --bit-window 20 drops bits 20-23. Measured across 15 real derived masks:
      bits 0/1/12 were selected 15/15 times, bits 20/22/23 were selected 0/15.
      Those three never carry signal, so excluding them spends the bit budget
      only on positions that can actually pay.
    * --score-t 70 is a HARD FLOOR here, not a preference. The packing bar is
      effBar = --record-cq / --score-t, so --score-t 70 vs 66.04 needs 94.3%
      packing (achieved: the record is 94.3%, and 95.9% has been measured).
      Set --score-t below --record-cq and effBar goes ABOVE 1.0 - impossible,
      since cq = blocks/256 and a chunk holds at most 256 eligible blocks, so
      cq <= chunk count ALWAYS. pWin then reads 0 at every spot and the ranking
      silently orders noise. The tool now warns instead of doing this quietly.
      Beating 66.04 needs >=67 chunks minimum, ~71 at typical 93% packing.
      Rule of thumb: --score-t 70..72, never below ceil(--record-cq).

THE TARGET (measured, hundreds of seeds across many spots/families): packing
  falls monotonically as chunk count rises - best seen 95.9% @68c, 94.9% @69c,
  94.3% @70c, 91.4% @71c, 90.4% @72c - so count x packing PEAKS AT EXACTLY 70
  CHUNKS, and the 66.04 record sits on that peak. A new record is one specific
  draw: 70 chunks packing >= 94.4% (or 71c >= 93.2%, never yet seen). Chasing
  higher chunk counts is provably counterproductive. The pipeline's push stage
  hunts at floor 70 for this reason; its triage stays at floor 64 only because
  low floors are what make the 10-second spot ranking discriminate.

[2] HUNT + SCORE + CLIMB the batch, one command (replaces the old manual
  hunt-runner + score-runner steps; ranks by REAL cq, keeps images/txts):
  powershell -ExecutionPolicy Bypass -File hunt_pipeline.ps1
    Defaults: newest commands_*.csv, 20s/spot, floor 64, radius 6, within
    10k blocks (-MaxDist 0 to disable). Writes main\pipeline.txt ranked table.
    Per spot: hunts (dead spots auto-killed at 5s with zero seeds - yield is
    linear, so zero-at-5s means dead), scores every new seed at block
    precision, then GPU-sweeps the best seed's 8192 high-bit variants
    (0.2s vs 23.4s for the old CPU climb) and refines the top 5.
  The old manual runner still works if you want raw hunts only - the scan
  prints it. Dead families also self-abort in ~5s (10 pulse hits at count
  >= 62 by 20M seeds, calibrated on the record family: ~207 vs ~0).

[3] LONG-HUNT any spot that survived with real hits: re-run its line from the
  csv with --give-up-after 0 and leave it for an hour.

[4] SCORE everything, with the free high-bit climb bonus:
  powershell -Command "Get-ChildItem 'main\seeds\*.csv' | ForEach-Object { if ($_.BaseName -match '^(-?\d+)_(-?\d+)$') { .\slime_refine.exe --seeds $_.FullName --center-x $matches[1] --center-z $matches[2] --radius 6 --climb --climb-recurse } }"
  Check main\scores\*\*.txt for anything beating the current record.

[5] (optional) WIDEN the climb on anything close with the GPU coarse pass -
  cheap to try wider windows/more variants than CPU --climb can afford:
  slime_gpu.exe --climb-scan --seed <s> --center-x X --center-z Z --m-chunks 6 --climb-lo 24 --climb-bits 24
  then feed its printed top seeds to slime_refine --seeds <csv> --center-x X --center-z Z --radius 6 --climb
  for the real block-precision number (--climb-scan is chunk-aligned only).

Repeat [1]-[4] at --center-x 40000, then -40000: new windows, new families.
NOTE: old commands_*.csv files were written by older builds with stale give-up
settings - re-run the scan rather than reusing them.
================================================================================

================================================================================
 STANDARD COMMANDS  (everyday / one-off, not part of the record loop above)
================================================================================
Self-test any tool (must pass before trusting anything it prints):
  hotspot_scan.exe --self-test
  slime_gpu.exe --self-test
  slime_refine.exe --self-test

Check a single spot without a full scan:
  hotspot_scan.exe --check --center-x 2000 --center-z 8544

Cheap variance-only look at one spot (not a ranker - see --check for that):
  hotspot_scan.exe --score-one --center-x 2000 --center-z 8544

Score one known seed at a fixed centre (no --seeds file):
  slime_gpu.exe --seed <s> --m-chunks 24 --center-x X --center-z Z

Widen a mask from real hunt hits instead of random sampling:
  hotspot_scan.exe --from-seeds main\seeds\<x>_<z>.csv --center-x X --center-z Z

Speed check / projected full-run timing:
  hotspot_scan.exe --bench --center-x X --center-z Z --range 40

Stress report (self-tests, benchmarks, timed hunts, refine batch + one image):
  powershell -ExecutionPolicy Bypass -File stress_toolchain.ps1
  powershell -ExecutionPolicy Bypass -File stress_toolchain.ps1 -Quick

auto_shootout.ps1 is superseded by hunt_pipeline.ps1 / record_cycle.ps1 (see RECORD COMMANDS
at the top of this file), which do the same hands-off "hunt+score, ranked by real cq" job plus
climb/family-sweep/push/ledger. It still works and is shipped: it hunts every spot in
main\commands\commands_*.csv (written by a normal scan cycle) and writes main\shootout.txt
ranked by cq. Prefer record_cycle.ps1.
================================================================================

SLIME TOOLCHAIN
==================================================================================
One folder. One slime_core.h. Everything generated lands in main\.

  hotspot_scan     WHERE to hunt. Scans an area, derives a per-spot bit mask,
                   ranks by measured hit rate, and prints the next two commands.
  slime_gpu        THE HUNT. Grinds seeds at one spot into that spot's seed file.
  slime_refine     WHAT IT IS WORTH. Real cq, at block resolution, plus the PNG.
                   Replaces slimefinder.jar entirely - the jar is not needed.
  perimeter_setup  IS THE MODEL RIGHT. Emits in-game commands to build a
                   physical test rig and measure the real answer with Carpet
                   mod's /perimeterinfo - see IN-GAME VERIFICATION below.
  slime_core.h     the scoring math, shared by all four. DO NOT FORK IT.

Output layout - everything under main\:
  main\commands\commands_<name>.csv   hunt commands from one scan, best first
  main\seeds\<x>_<z>.csv              WORKING: raw hunt seeds, one file per spot -
                                       regenerated by any hunt, safe to clear anytime;
                                       anything that mattered is already in records\
  main\scores\<x>_<z>\<seed>.txt      WORKING: ranked cq log from slime_refine, one
                                       per seed - same disposability as seeds\ above
  main\scores\<x>_<z>\<seed>.png      matching image, same seed, same folder
  main\records\<cq>_<seed>.{txt,png}  PERMANENT - auto-filed 64/65/66+ results, one flat folder,
                                       deduped by pattern - the actual find archive,
                                       never auto-cleaned. The cq prefix keeps the
                                       best results sorted together and easy to scan
  main\families.csv                   LEDGER: every (mask,val) hunted - the thing that
                                       stops a later session from re-hunting old ground
  main\cycles.txt                     numbered run log, one line per record_cycle.ps1 cycle
  main\stress_report.txt              stress_toolchain output
  main\work\                          SCRATCH: per-cycle pipeline intermediates
                                       (cq_/new_/climb_/push_/sweep_ CSVs per spot),
                                       safe to clear - nothing here is a final result
  (main\shootout.txt is written by auto_shootout.ps1 - see note above)

<name> is --name on the scan (defaults to <x>_<z>_r<range>).
<family> is --family on slime_refine (defaults to the centre, <x>_<z>).
Two scans, or two spots, can never overwrite each other's output.


== 1. BUILD ======================================================================

  powershell -ExecutionPolicy Bypass -File build.ps1

Builds all three and runs every self-test. Stops if any fails. Nothing below
means anything until all three pass.


== 2. THE LOOP ===================================================================
Three copy-pastes. The scan prints steps 2 and 3 for you, filled in.

  [1] SCAN - find spots worth hunting
      hotspot_scan.exe --scan --center-x 0 --center-z 0 --range 10000 --z-all --var-min 26 --gate-top 300 --score-t 68 --name all

  Optional - force your two known records through as an acceptance check. They
  do NOT survive on merit (both spots are mean ~62 cqCeil; 65.71 was seed luck),
  so this is the only way to see where they land:
    --include 2000,8544 --include 3680,6992

      -> main\commands\commands_all.csv, one bare hunt command per line.
         Then it PRINTS the hunt runner and the score runner. Paste them.

  [2] HUNT - the printed runner, e.g.
      powershell -Command "Get-Content 'main\commands\commands_all.csv' | ForEach-Object { $a = $_ -split ' ', 2; $p = Start-Process -FilePath ('.\' + $a[0]) -ArgumentList $a[1] -PassThru -NoNewWindow; Start-Sleep 120; if (!$p.HasExited) { $p.Kill() } }"

      120 = seconds per spot. Raise it to give each spot more chances.
      Each spot appends to main\seeds\<x>_<z>.csv.

  [3] SCORE - the printed runner, e.g.
      powershell -Command "Get-ChildItem 'main\seeds\*.csv' | ForEach-Object { if ($_.BaseName -match '^(-?\d+)_(-?\d+)$') { .\slime_refine.exe --seeds $_.FullName --center-x $matches[1] --center-z $matches[2] --radius 6 } }"

      Refines each family at its OWN centre. Logs and images land together
      in main\scores\<x>_<z>\, one <seed>.txt and <seed>.png per seed.

Or hands-off (does 2 and 3 itself, ranks by real cq) - use record_cycle.ps1
instead (see RECORD COMMANDS at the top of this file); auto_shootout.ps1,
which used to live here, no longer exists.


== 3. SCAN RECIPES ===============================================================
Z is periodic at 97 chunks; X is not. WHY: isSlimeChunk does x*x*0x4c1906 in INT
(overflows, wraps, scrambles) but z*z as LONG (never overflows, stays a clean
quadratic). So z has an exact 97-chunk lattice and x does not. The hot Z lines are
  chunkZ mod 97 in {48, 49}   <=>   blockZ = 1552k + 768  or  1552k + 784
Both records sit on it (chunk 534 and 437 are each == 49 mod 97).

PRIMARY - --z-all generates every hot Z line in range from that formula and
sweeps each fully. No anchor (--center-z is ignored), no tiling, no overlap
bookkeeping. One command replaces the old 8 directional sweeps:
  hotspot_scan.exe --scan --center-x 0 --center-z 0 --range 10000 --z-all --var-min 26 --gate-top 300 --score-t 68 --name all

Specific lines only (when you want a subset, skips generation):
  hotspot_scan.exe --scan --center-x 0 --center-z 0 --range 10000 --z-only 8544,6992,5424,10096 --var-min 26 --gate-top 300 --score-t 68 --name zonly

--z-all vs --z-period: --z-period anchors the lattice to --center-z and misses it
entirely if the phase is wrong. --z-all derives the lines, so it cannot miss.

Check one spot by hand (prints its mask, its hunt command, and its refine command):
  hotspot_scan.exe --check --center-x 2000 --center-z 8544


Images are on by default. --no-images when batch-scoring thousands of seeds.


==================================================================================
 RAISED-AFK FOLDER (main\records\over66_y-39) - a minor side hint, not a second ranking
==================================================================================
Next to over66_images and the tier folders: every 66+ farm's image named by the number
/perimeterinfo would read with your feet at y -39 over the -64 floor (no inner no-spawn
circle, outer circle 125.7, AFK point free to move +-48 blocks):
    18598-69.39-71791501344359.png            the tool's ESTIMATE (peri-score-seed)
    18409-70.34-136253019324379-measured.png   your in-game count - it wins
Sort by name (or by date, newest first) = highest first. A farm the model ranks low but
that sits high here is the thing to look at (a 67 that could play like a 69). New 66+
farms are added when the search files them (hunt_pipeline Add-Y39Image, ~0.1 s, never
blocks filing); no background loop. After an in-game measurement goes into
main\records\measured_in_game.csv, run   powershell -File afk_rescan.ps1   once to rename
that farm to its measured number (it also backfills; on a fresh copy there is no main\records\over66.csv yet, so it prints a notice and does nothing until your own hunt files a 70+ farm). "BIG (estimate ...)" is printed when
an unmeasured farm is estimated above the best in-game count. Track record: full floor
49,669 exact; exact for 72.22 / 69.39 / 70.82 / 69.30 / 68.28 / 66.04, +20 for 70.64, off ~200 for 70.34 / 69.09.
afk_rescan.exe --disc prints the full-floor count (calibration).

PERIMETER SETUPS: on request only, written to main\records\perimeter\<cq>_<seed>_perimeter.txt. The void box is CHUNK-BORDERED: it covers exactly the chunks the floor is built in (never cutting a chunk), for any centre - checked on 300 random centres incl. negatives and the world border.
FARM IMAGES: no inner 24-block ring (measured at y -39 there is none); one image per farm, copied to the gallery and over66_y-39.

==================================================================================
 KNOWN RECORDS
==================================================================================
Ranked by IN-GAME measurement, not by model cq. The highest model number in
main/records/ is NOT automatically the record - the file prefixed RECORD. is.
A model cq is a geometric prediction; Carpet's /perimeterinfo is the game's
own count, and where they disagree the game wins. data\known_answers.csv holds the
top five with what each one proves - a correct build reproduces every estimate in it.

  76.23 cq   block (16598714,-28207684)   seed 182568670158536
             MEASURED IN GAME: 20,506 spawning spaces (estimate 20,506 exact) - #1 IN GAME, +740 over the 19,766.
             Spot 16598688,-28207696, heat40 only 17.4 (tier 2): found by the heat45 tail-heat skim
             (heat\tier2_skim.ps1) - ordinary heat40 ordering would have ranked the spot ~9-millionth.
  76.38 cq   block (9060723,-15431012)    seed 130738905053232
             MEASURED IN GAME: 19,766 (estimate 19,734, +32). Tier 1: the best heat40 22+ has produced.
  72.03 cq   block (14432930,5926460)     seed 230337960196917
             MEASURED IN GAME: 19,103 (estimate exact). Found by the universe screen at the 74 gate.
  71.08 cq   block (-19032517,15423291)   seed 267397934802442
             MEASURED IN GAME: 18,885 (estimate exact).

  72.22 cq   78c           block (28616800,-2104120)    seed 245821300723973
             MEASURED IN GAME: 18,727 spawning spaces (model 18,488; +239, +1.3%) - #1 IN GAME, 129 above the 69.39.
             Exactly the raised-AFK estimate. Found by the PREDICTION SEARCH (predict_cycle.ps1 cycle #3),
             spot (28616768,-2104112), heat 28.7; 71.34 at the same spot (est 18,675).
             Perimeter setup: main\records\perimeter\72.22_245821300723973_perimeter.txt. /tp 28616801 ~ -2104118
  73.19 cq                 block (7339521,-2104095)     seed 23298179214765
             HIGHEST MODEL SCORE. -39 ESTIMATE 18,970 - above the in-game record (BIG); 72.98 at the same spot
             (seed 255157693722029, est 18,853). Same Z line as the 72.22. Prediction search cycle #9. NOT YET MEASURED.
  72.90 cq   76c           block (12107056,7518294)     seed 68999818179391
             HIGHEST MODEL SCORE. -39 estimate 18,582. Found by the
             PREDICTION SEARCH (predict_cycle.ps1 cycle #3), spot heat 29.8. NOT YET MEASURED.
  69.39 cq   76c @ 91.3%   block (-21323306,17855231)   seed 71791501344359
             MEASURED IN GAME: 18,598 spawning spaces (model 17,764; +834, +4.7%) - #2 in game (behind the 72.22),
             189 above the 70.34. Measured with the rig centred on its best -39 point
             (-21323307,17855222) - exactly the raised-AFK estimate (over66_y-39). Found
             by the exact phase search (cycle #66), spot (-21323312,17855248),
             line 11519, heat 28.8 (254 layouts of 70+ chunks; X column of the 68.86).
             Perimeter setup: main\records\perimeter\69.39_71791501344359_perimeter.txt. /tp -21323307 ~ 17855222
  70.34 cq   79c @ 89.0%   block (-8546740,16457220)    seed 136253019324379
             MEASURED IN GAME: 18,409 spawning spaces (model 18,007; +402, +2.2%) - #2 in game,
             189 behind the 69.39, 2 above the 69.30 (18,407). Model #2, first 70+.
             Found by the exact phase search (cycle #47), spot (-8546768,16457136),
             line 10617, heat 29.9 - a very rich spot: 84 layouts of 70+ chunks, and 69.78,
             69.34, 69.24, 69.08 there too (all family 0x0FFDB).
             Perimeter setup: on request (main\records\perimeter\). /tp -8546740 ~ 16457220
  69.30 cq   72c @ 96.3%   block (-25146501,4528323)    seed 173087838020963
             MEASURED IN GAME: 18,407 spawning spaces (model 17,740; +667, +3.8%) - #3 in game,
             2 behind the 70.34, 191 behind the 69.39. Model #3. Found by the
             exact phase search (cycle #42), spot (-25146448,4528320), line 2921, heat 30.3.
             Why it beat its model by so much (called from its image, before measuring):
             4 slime chunks sit inside the middle no-spawn sphere - with a higher AFK y those
             add spawning blocks. The model scores at y-offset 0, so it cannot see this.
             Perimeter setup: on request (main\records\perimeter\). /tp -25146501 ~ 4528323
  70.64 cq   76c @ 92.9%   block (-27565075,26600328)   seed 51829727074880
             MEASURED IN GAME: 18,293 spawning spaces (model 18,083; +210, +1.2%) - #4 in game,
             116 behind the 70.34. Model #2. Found by the exact phase search (cycle #55),
             spot (-27565088,26600352), line 17161, heat 29.3; family 0x89A40 (69.64 there too).
             Perimeter setup: on request (main\records\perimeter\). /tp -27565075 ~ 26600328
  70.82 cq   73c         block (-25747483,12069090)   seed 18234105440443
             MEASURED IN GAME: 18,261 spawning spaces (model 18,131; +130, +0.7%) - #5 in game.
             HIGHEST MODEL SCORE - and exactly the raised-AFK estimate (18,261). Found
             by the exact phase search, spot (-25747424,12069088), line 7786, heat 28.5.
             Perimeter setup: main\records\perimeter\70.82_18234105440443_perimeter.txt. /tp -25747483 ~ 12069088
  69.09 cq   73c @ 94.6%   block (26657801,20130652)    seed 39347866698447
             MEASURED IN GAME: 17,740 spawning spaces (model 17,686; +54, +0.3%) - #7 in game,
             behind the 70.34, 69.30, 70.64 and 68.28. Model #3. Found by the
             exact phase search, spot (26657824,20130640), line 12987, heat 25.1. The same
             spot also holds 68.57 (seed 33747233538767, /tp 26657800 ~ 20130652).
             Perimeter setup: generated on request (perimeter_setup.exe). /tp 26657801 ~ 20130652
  68.38 cq   (16054700,20130673)  seed 163238104073275  - exact search, line 12987. NOT YET MEASURED.
  68.54 cq   75c @ 91.4%   block (-26008735,16457166)   seed 187561908205390
             NOT YET MEASURED IN GAME. Found by
             the EXACT PHASE SEARCH (record_cycle -PhaseSearch, cycle #4) in its first
             batch: spot (-26008736,16457136), line 10617, heat 29.1. 17,545 blocks.
             Perimeter setup: generated on request (perimeter_setup.exe). /tp -26008735 ~ 16457166
  68.39 cq   71c @ 96.3%   block (-15087422,-22325443)  seed 157366496822294
             Same batch, spot (-15087408,-22325440), line -14404. NOT YET MEASURED.
             Perimeter setup: generated on request (perimeter_setup.exe). /tp -15087422 ~ -22325443
  68.28 cq   72c @ 94.8%   block (-20106128,16457142)   seed 6343398036581507192
             MEASURED IN GAME: 17,771 spawning spaces (model 17,479 blocks; +292, +1.7%) -
             #6 in game (behind the 69.39, 70.34, 69.30, 70.64 and 70.82). Found
             (cycle #408) by a heat-mode hunt on line 10617 (Z ~16.46M). Exact-model
             check: 76 slime chunks in the r=9 disc (67.24: 74, 66.04: 73).
             Perimeter setup: generated on request (perimeter_setup.exe). /tp -20106128 ~ 16457142
  67.24 cq   72c @ 93.4%   block (-22078158,15423280)   seed 4508542591492402376
             NOT YET MEASURED IN GAME. Found
             (cycle #402) by the HEAT model's very first hunt of predicted-hot
             spots - see docs\REFERENCE.md "LINE / X / HEAT MODEL". Its lead over
             66.04 (1.2 cq, ~300 blocks) is larger than any model/game gap seen
             so far (~200 blocks), but it holds the title only once Carpet's
             /perimeterinfo confirms it. /tp -22078158 ~ 15423280
  66.04 cq   70c @ 94.3%   block (3680,6989)    seed 9029506488461633794   <- THE RECORD
             VERIFIED IN GAME: 17,112 spawning spaces. Filed as
             RECORD.66.04_9029506488461633794 in main/records/.
  66.21 cq   70c @ 94.6%   block (40776,5411)   seed -89761025938370956
             Higher model score, but MEASURED WORSE IN GAME, so it does not
             hold the title. See the AFK-height caveat further down - the
             model computes at y-offset 0 and both spawn spheres are 3D, so
             standing height changes which chunks qualify, and at margins
             this small that is enough to flip an ordering.
  65.71 cq   70c @ 93.9%   block (2000,8544)    seed -1018472292131368322

66.21 was found after widening -Range to 50000, on that window's very first
cycle, via the same high-bit climb mechanism that produces most gains here:
a raw hunt at (40776,5411) only found 64.64 cq; --climb-scan's high-bit
sweep found the 66.21 variant. Proven exhaustively, not sampled: a full
--enumerate of that seed's entire family (0xEF70F|0x4C604, all 2^34
members) found exactly 2 seeds that reach 66.21, and nothing in the family
beats it. Independently re-scored with an unmodified slime_refine.exe,
exact match. Unrelated to the 66.04 record - different family, different
real-world location, a pixel-level image comparison found no structural
similarity beyond chance (~23 of 289 chunks shared at native alignment,
matching what pure coincidence predicts). Image/log in main/records/.

The jar could only ever find the 65.71 spot: 6989 is not a multiple of 16, and
the jar only tests chunk-aligned centres. slime_refine tests every block, which
is where the extra 0.33 cq came from - same seed, same chunks, better standing
spot. If you feed 3680,6989 back to the jar it snaps to 6976 and reports LESS.

NOTE the 65.71/(2000,8544) row is known-stale (real historical best there is
63.96 cq, a record-keeping mix-up from early on) and is left alone on
purpose; do not spend time re-deriving it.


==================================================================================
 IN-GAME VERIFICATION (perimeter_setup)
==================================================================================
Every number above is a MODEL PREDICTION - slime_refine computes eligible
spawn blocks from slime_core.h's annulus weights, validated against
slimefinder.jar. That is validation against another PROGRAM, not against
Minecraft itself. perimeter_setup closes that loop: it emits the exact
in-game commands to build a physical test rig, measurable with Carpet mod's
/perimeterinfo - the game's own spawn-space calculation - so the model can
be checked against reality directly. This matters at record margins: a
spot the model ranks higher can measure WORSE in game (see the AFK-HEIGHT
CAVEAT below) - when the two disagree, the game wins, not the model.

REQUIRES: the Carpet mod (for /perimeterinfo) and WorldEdit (for the
//pos1 //pos2 //set void commands) both installed on the world being
tested. Neither is optional - without Carpet there is no way to read the
result, and without WorldEdit the void step has no vanilla equivalent that
can clear a box this large in one shot.

Build:  nvcc -O3 perimeter_setup.cpp -o perimeter_setup.exe
        (plain C++, no CUDA in it - g++ -O3 works identically. Included in
        build.ps1's standard build; no --self-test, since the only ground
        truth to check it against is Minecraft itself.)

Usage:
    perimeter_setup.exe --seed <s> --center-x <x> --center-z <z>
                        [--y -64] [--radius 152] [--block obsidian]
                        [--void-top -40] [--afk-y -50]
  The defaults assume a superflat world on Minecraft 1.20.4 - just
  pass seed and centre. Change a default in perimeter_setup.cpp, not by
  flags: the old 200 / 120 defaults kept coming back because the fix only
  ever lived in a command line.

  --seed              required, the world seed
  --center-x/z        the AFK spot, BLOCK precision - take it from
                       slime_refine's "BEST BY BLOCKS" line, not the
                       chunk-aligned scan centre. Example: the 66.04 scan
                       spot is (3680,6992) but the AFK spot is (3680,6989).
  --y                 Y of the obsidian floor. -64 for 1.18+, 0 for older
  --radius            half-width of the voided box AND of the obsidian
                       floor, in blocks. Default 152 (3 chunks
                       in from the old 200 on every side) - still 24 blocks
                       past the 128-block despawn sphere
  --block              floor material, default obsidian
  --void-top          top of the voided box. Default -40: superflat world,
                       nothing above to clear
  --afk-y             Y that /tp puts you at (default -50, 14 above the floor)

The rig, conceptually: void a large box around the AFK spot, lay one layer
of floor block at the world floor in slime chunks ONLY (everything else
stays void), disable mob spawning (live mobs corrupt the count), then
measure with /perimeterinfo. Every spawnable position in range is now
slime-chunk floor, so the reported count IS the spot's slime capacity,
directly comparable to slime_refine's block count for the same position.
One floor layer is enough - a spawn position needs solid beneath and air
above, so one layer with void above satisfies exactly one position/column.

Output, five sections in execution order (0-2 and 4 paste into chat, 3 goes
into a command block):
    0. SEED                    the seed, on its own line
    1. TELEPORT                 /tp (y -50), /gamerule, /seed  (no /spawnpoint)
    2. VOID THE AREA            //pos1 //pos2 //set air  (WorldEdit)
    3. SLIME CHUNK FLOOR        the command-minecart "monolith" (below) - the
                                only form; the chain-command-block form was
                                removed (never used)
    4. MEASURE                  /give of the measuring block: repeating,
                                unconditional, always active, running
                                "execute at @p run perimeterinfo" (1.20.4 NBT)

Why a "monolith": the floor needs one /fill per slime chunk, typically
~70-110 commands for radius 152. Chat caps at 256 characters and one line
per Enter; a command block holds ~32,500 characters but executes exactly
ONE command regardless of length; semicolon-chaining needs a plugin or
client mod most setups don't have. The fix is the classic "one-command
creation" trick: summon a falling redstone block with an activator rail
riding it, and every command_block_minecart riding THAT rail fires once -
N commands from one pasted summon command. It self-destructs afterward,
and that is a correctness requirement, not tidiness: command blocks are
solid, so leaving the rig's own blocks in place adds bogus spawnable
surfaces and inflates the exact count being measured.

Section 4's /give is the 1.20.4 form - this emitter targets 1.20.4 and earlier:
    /give @p minecraft:repeating_command_block{BlockEntityTag:{Command:"execute at @p run perimeterinfo",auto:1b}}
(1.20.5+ would need components instead: repeating_command_block[block_entity_data={id:"minecraft:command_block",...}].)
The section-3 command cannot be given this way - far too long for chat.
/perimeterinfo takes no mob argument here - with one (e.g. "slime") Carpet
dumps every spawnable coordinate and buries the summary; without it, just
the three summary lines print.

AFK-HEIGHT CAVEAT - read before trusting any model/game mismatch:
slime_core.h computes at y-offset 0 (player level with the spawn surface;
its own header says so explicitly). Both the exclusion and despawn spheres
are 3D, so standing higher than the floor changes the horizontal footprint
substantially, not just vertically:
    y-offset  0:  exclusion radius 24.0 blocks,  despawn radius 128.0
    y-offset 23:  exclusion radius  6.9 blocks,  despawn radius 125.9
The two effects roughly cancel in TOTAL area but change WHICH chunks
qualify - and since slime chunks are discrete and clustered, that is
enough to flip the ranking of two spots separated by a fraction of a cq.
This is the leading explanation for any model/game discrepancy - checked
and confirmed on the two known records:
    66.04 spot: model predicted 16,905 blocks; game measured 17,112.
    a 66.21-cq spot measured WORSE in game than the 66.04 spot.
Two ways to reconcile, neither implemented: measure with --afk-y set to
the floor Y (so the model's y-offset-0 assumption actually holds), or add
real y-offset support to slime_refine. Deliberately not built - real spawn
eligibility at a given y depends on terrain/surface/lighting this
toolchain's sphere-distance math does not model, so any y-sweep result
should be checked against a real in-game measurement, not trusted from the
geometry alone.

Worked example - the 66.04 record (HISTORICAL: run with the old radius 200 - today just pass seed and centre):
    perimeter_setup.exe --seed -3918692359804081918 --center-x 3680 --center-z 6989 --y -64 --radius 200 --afk-y -40 --void-top -40
Produces 109 slime chunks of 676 scanned (16.1%), 27,904 blocks of floor,
a 10,458-character monolith. In-game result: 17,112 spawning spaces,
against a model prediction of 16,905.

Presentation guidance, for whoever (or whatever) is relaying this output to
someone building the rig - learned the hard way, worth following:
  - One command per fenced/copyable block - chat takes one line per send,
    so a block holding several commands means manual splitting anyway.
  - Never paste the tool's raw stdout as commands - a shell prompt/prefix
    can get copied along with it. Reformat into clean, individually
    copyable blocks.
  - File attachments (the monolith) go at the END, after every chat
    command, not interleaved.
  - Every command gets its OWN block, no exceptions - including each of
    the 3 WorldEdit lines individually. One block holding several lines is
    harder to copy cleanly than four small ones, even if each line inside
    it looks separately selectable.
  - Minimal commentary between blocks - the goal is pasting, not reading.
Typical shape: seed, /tp, /gamerule, /seed, the WorldEdit three, the /give
- then the monolith attached last.


==================================================================================
 WHAT THE NUMBERS MEAN
==================================================================================
cq       blocks / 256. THE OBJECTIVE. What you actually farm.
chunks   a PROXY, and a leaky one. A chunk is 256 blocks, so k chunks caps at
         k.00 cq, and real efficiency is 90-95%:
             70 chunks -> 65.71 cq        66 chunks -> 61.25 cq
         65 chunks CANNOT beat 65.71 cq. Arithmetically impossible.
         To beat 66.04 cq: 67c needs 98.6%, 68c needs 97.1%, 69c 95.7%, 70c 94.3%.
win      THE RANKING KEY. How many record-beating layouts EXIST in this family:
             winners = 2^(48 - bits) x p(count>=score-t) x pWin
         A --fix-mask of b bits carves out a residue class holding exactly
         2^(48-b) layouts and nothing else. Ranking on RATE alone rewards tight
         masks, which raise the rate by SHRINKING the family - the opposite of
         what produced the records. Their original mask was 14 bits = 2^34
         layouts, 64x the 2^28 the scan derives now. More bits, higher rate,
         fewer total options.
             2000,8544 (record) : 19 bits, 3.1e-08, pWin 4.8%  -> 0.80 winners
             128304,6976        : 20 bits, 1.6e-07, pWin 0.0%  -> 0.00 winners
         The record spot's family contains ~1 record-beater. You found it.
         128304's contains ZERO - no hunt length produces one. Below
         --min-winners the spot is cut. Try --max-bits 14 for 64x the options.

pWin     secondary. Of the high-count layouts this spot produces, the
         FRACTION that pack well enough to beat --record-cq at --score-t chunks
         (bar = record-cq / score-t). A mean cannot separate spots; this can.
         Measured on your own two spots at --score-t 68:
             2000,8544  (record spot)  eff 93.2%  pWin 4.8%
             128304,6976               eff 91.7%  pWin 0.0%   <- CANNOT win
         0.9 points of mean separates them; pWin says one is a contender and the
         other is not, however long you hunt it. Spots below --min-pwin are cut.

cqCeil   secondary, a mean. Mean packing efficiency of a spot's high-count
         layouts, times --score-t. Measured on the CPU (12M masked seeds) for
         every spot that passes the count test. It answers what chunk count
         cannot: if this spot makes a 70, how well do those chunks PACK. Two
         spots both making 70s can differ 88%% vs 94%%, which is a 4 cq gap - and
         that gap, not chunk frequency, decided every spot in the shootout. Spots
         whose cqCeil falls below --eff-target are cut before you hunt them.
score    p(count >= --score-t | mask) = hits per seed = hits per SECOND, since
         throughput does not vary by location. THE RANKING KEY.
max      the luckiest single draw in a fixed sample. An order statistic, not a
         property of the spot - shown for information only. You cannot filter on
         it; --score-t is the only threshold, and the hunt records exactly there.
hits     how many DISTINCT seeds cleared --score-t in the sample. Two spots with
         the same score are not equal: the one with more hits has more separate
         chances at a 70+, which is why --rank-by combined exists.

--score-t 68 (default) is the fix for a real bug: the ladder must DERIVE at
--deep-t 60 because p(>=70) unconstrained is behind a 1e-9 wall, but scoring at
60 to predict 70 is the same mistake variance made at 45. The tail curves cross.
Score where you care. 68 catches high-efficiency 68-69 chunk spots that still
beat the record; below 68 you are ranking on seeds that cannot win.


==================================================================================
 THE METRIC
==================================================================================
Slimes cannot spawn within 24 blocks of a player. Four chunks touch the AFK spot
and sit entirely inside that exclusion sphere - (0,0) (-1,0) (0,-1) (-1,-1) - so
they can never spawn anything. Eligibility is an ANNULUS, not a disc:

    24^2 < a^2 + b^2 <= 128^2        222 live cells, max 49640 blocks, 193.91 cq

Verified EXACT against slimefinder's own fine-phase output, blocks AND chunks,
10 of 10 rows. slime_refine --chunk-aligned diffs its log byte for
byte, filename included.

The old 226-cell disc mask counted those four dead chunks and overstated the
score 33.2% of the time (+1: 27.1%, +2: 5.5%, +3: 0.6%). Any mask or score from
before this is stale: 0xEFC4F, 0x3FFEDF, 0xFFFFF/0x72902, 0xFFFFF/0x3B39E.
Re-derive with --check or --scan.


==================================================================================
 THINGS THAT WILL BITE YOU
==================================================================================
1. Refine at the SAME centre the hunt used. A mask is derived per spot; its seeds
   are worthless anywhere else. Wrong centre gives ~25 chunks - the random rate.
   The printed score runner and record_cycle.ps1 both handle this for you.
2. chunks is not cq. Both live in the 60s. They are not the same number.
3. --z-all needs no anchor and cannot miss the lattice. --z-period still exists
   but must be anchored to a HOT Z (8544, 6992, ...) or it samples dead bands and
   the scan comes back cold. Prefer --z-all.


==================================================================================
 STRESS + PROFILING
==================================================================================
Stress report (self-tests, benchmarks, timed hunts, refine batch + one
image). Every stage has a hard timeout, so it always finishes and always writes
the report:
  powershell -ExecutionPolicy Bypass -File stress_toolchain.ps1
  powershell -ExecutionPolicy Bypass -File stress_toolchain.ps1 -Quick   (short)
Writes main\stress_report.txt. Send that back for tuning.

Speed check only:
  hotspot_scan.exe --bench --center-x 2000 --center-z 8544 --range 40 --bench-locs 3

ncu profiling. -c 1 captures ONE kernel launch (~30s). WITHOUT IT ncu replays
every launch 45x and will appear to hang for hours - that is not a crash, it is
ncu doing 1350+ passes:
  Hunt kernel:
    ncu --set full --target-processes all -c 1 -o hunt_profile slime_gpu.exe --seed-count 16384 --m-chunks 24 --batch 16384 --center-x 2000 --center-z 8544 --fix-mask 0xEFC4F --fix-val 0xE904E --record-floor 70
  Pass 1 (varKernel):
    ncu --set full --target-processes all -c 1 -o hotspot_var hotspot_scan.exe --bench --center-x 2000 --center-z 8544 --range 40
  Pass 2 (tailBitsKernel / rateKernel):
    ncu --set full --target-processes all -c 1 -o hotspot_derive hotspot_scan.exe --check --center-x 2000 --center-z 8544 --big-n 8000000 --big-n-min 8000000
Open:
  ncu-ui hunt_profile.ncu-rep


==================================================================================
 KEY FLAGS
==================================================================================
hotspot_scan  --scan --check --from-seeds --bench --self-test
              --name <s>     this scan's identity; names its commands file and
                             its seeds folder. Default <x>_<z>_r<range>.
              --center-x --center-z --range --step
              --z-period 97 --z-band      lattice-only scan, anchored to center-z
              --z-only z1,z2,...          scan ONLY these Z lines, ignore anchor
              --var-min --gate-top --include X,Z --out
              --like X,Z (repeatable)   reference spot(s) for --rank-by like,
                         default the two known records (see KNOWN RECORDS)
              --score-t 68     count threshold the ceiling is measured at
              --record-cq 65.71  the record to beat; sets the packing bar
              --min-pwin 0.01    cut spots that beat it less often than this
              --min-winners 0.25 cut families that contain no record-beater
              --give-up-after N  slime_gpu: judge the family after N seeds (20M ~ 5s)
              --give-up-hits H   slime_gpu: pulse hits needed at the judgement
              --give-up-floor F  slime_gpu: pulse count floor (0 = record-floor - 6)
              --emit-top N       emit the top N commands, filters bypassed
                                 (the original workflow - see above)
              --max-bits 14      looser mask = 64x bigger family = more options
                                 (your records were found with 14-bit masks)
              --eff-target 62  cq floor; spots whose packing cannot reach it are
                               cut before hunting (the shootout fix)
              --eff-n 12000000 CPU seeds for the efficiency probe
              --no-rank-eff    fall back to ranking by count frequency
              --deep-t 60    derivation ladder top. Cannot go higher; 1e-9 wall.
              --rank-by score|hits|combined|like   (like: see --like above; ranks
                         by resemblance to reference spots instead of hard
                         --eff-target/--min-pwin/--min-winners cuts)
              --top-print N  console preview size (CSV always has every survivor)
              --t-start 45 --t-step 5 --t-floor 40 --max-bits 20 --bit-window 24
              --z-min 5.0 --min-dev 0.08 --reach-dev 0.25 --reach-n --no-reach-check
              --derive-eff    additive post-pass, fixes free bits that predict
                              packing efficiency instead of just chunk-count
                              (see BUILT: --derive-eff below). Off by default.
              --min-eff-dev 0.02 --eff-z-min 5.0   its two bars, same pattern
                              as --min-dev/--z-min above
              --big-n --big-n-min --measure-n --measure-n-min --score-n --score-n-min
              --min-hits --min-lift --min-sep --min-tail
              --m-chunks --report-every --hunt-exe --rng-seed
slime_gpu     --self-test --seed --seed-count --center-x --center-z --m-chunks
              --batch --fused --fix-mask --fix-val --record-floor --seeds-floor
              --seeds-out <f>  where this spot's seeds go. Default main/seeds.csv;
                               the scan fills this in per family automatically.
              --report-every --quick-m-chunks --quick-threshold --rng-seed
              --worker       keep one CUDA context alive, read spot commands
                             from stdin instead of one process per spot -
                             2.69x on all-dead-family workloads (~199ms/spawn
                             saved per spot). hunt_pipeline.ps1 uses this by
                             default; a bad line reports to stderr and does
                             NOT kill the worker. Accepts --climb-scan lines
                             too, and bare --seed S --m-chunks M --center-x X
                             --center-z Z position searches (one Best: line each)
                             - how ./slime gui scans the whole 30M world: 13,924
                             tiles at ~0.04 s each instead of ~0.3 s per process.
              --time-limit-ms N   wall-clock cutoff checked inside the hunt
                             loop itself - what lets a --worker spot be time-
                             capped without killing the shared process.
              --no-stream    opt out of CUDA-stream double-buffered batches
                             (on by default on the fused path - ~10.7% more
                             throughput, ~15% less host/GPU idle gap from the
                             blocking D2H hit-count copy). Byte-identical
                             output to the non-streamed path.
              --no-prune     score every position of a bare --seed position search.
                             By default it skips strips whose upper bound is
                             below the best already found - exact (same best,
                             same tie-break; 3,000-tile A/B vs the old build,
                             0 differences), 1.4x faster per full tile.
              --climb-scan   GPU-coarse high-bit neighbor sweep at chunk
                             resolution (see BUILT: GPU-ACCELERATED CLIMB
                             below). Needs --seed as the base.
              --climb-lo 35 --climb-bits 13 --climb-top 10   its window/
                             report-count, same meaning as slime_refine's
slime_refine  --self-test --seeds --center-x --center-z --radius --fine
              --csv --top --out-dir --threads --quiet
              --family <s>   subfolder for logs and images. Default <x>_<z>.
              --images (default on) / --no-images
              --climb        sweep high seed-bit neighbors of the top result(s)
                             for a free extra fraction of cq (see BUILT: HIGH-BIT
                             NEIGHBOR CLIMB below)
              --climb-top N (1) --climb-bits B (13) --climb-lo L (35)
              --climb-recurse --climb-max-rounds N (5)


== THE RECORD LOOP (the strategy, start to finish) ==============================
Both records came from DIFFERENT spots and DIFFERENT families. cell_probe says
the map is structureless. Conclusion, measured three ways: good layouts are
spread thin across families, so BREADTH beats DEPTH. The loop:

  [1] hotspot_scan --scan ... --emit-top 15        many families, no pre-judging
  [2] paste the printed HUNT runner                 dead families self-abort at
                                                    100M seeds; runner moves on
                                                    the instant one quits
  [3] survivors (real hit counts) get LONG hunts    hours, not 120s
  [4] paste the printed SCORE runner (--radius 6)   cq decides, nothing else

Then repeat [1] at a new --center-x window. Do not drain one family to the
bottom: at 26 hits/100M the productive spot yields its easy layouts fast, and
the two-records-two-families fact says the next record is likelier in a family
nobody has opened than in the dregs of one already mined.

== AUTO-ABORT: STOP HUNTING DEAD FAMILIES ======================================
Measured across one --emit-top batch, 100M seeds each:

    128304,6976    26 hits >= 68     <- the only one worth the GPU
    -117856,6976    2 hits
    -100592,6976    1 hit
    55408,-8528     0
    28720,6976      0
    -153872,6976    0
    -92224,5424     0
    128800,6976     0

Five of eight produced NOTHING in 100M seeds. A family is productive early or it
is not, so slime_gpu now judges itself:

    --give-up-after 20000000    judge at 20M seeds (~5s)
    --give-up-hits 10           pulse hits needed by then
    --give-up-floor 62          the PULSE floor (default record-floor - 6): hits
                                here are counted silently for the judgement, not
                                printed, not saved. Calibrated per 20M seeds:
                                record family 207, weak-but-real 20-35, dead ~0.
                                The kernel runs at the pulse floor only until the
                                judgement, then reverts to full speed.

It prints "GIVING UP: ..." and exits. Generated hunt commands carry these by
default. The printed runner now uses WaitForExit instead of Start-Sleep, so the
next spot starts the INSTANT a dead one quits instead of idling out its slot.
On the batch above that is roughly 5x less wall clock for the same information.

Set --give-up-after 0 to disable (hunt forever, the old behaviour).

== EMULATING THE ORIGINAL WORKFLOW: --emit-top ==================================
    hotspot_scan.exe --scan --center-x 0 --center-z 0 --range 10000 --z-all
        --var-min 26 --gate-top 300 --score-t 68 --emit-top 15 --name hunt

--emit-top N writes the top N hunt commands REGARDLESS of the pass/fail filters.

Why it exists: every filter in pass 2 is calibrated on TIGHT masks with fat hit
rates - the 3-arm test needs --min-hits 30, the max prefilter compares a 32M
sample max against --score-t, pWin needs ~400 samples. A 14-bit mask fails all
three, and a 14-bit mask is the exact configuration that produced BOTH records
(--check at 2000,8544 derives 0xFFC0F/0xE900E; the original was 0xEFC4F/0xE904E
- same 14 bits, same neighbourhood).

--check has never had those filters. That is the entire reason --check works and
--scan returns nothing. --emit-top makes --scan behave like --check across many
spots: derive a mask, emit the command, go hunt it, let the SEEDS decide.

That is how the records were found. Not by a scan that pre-judged the spot.

== HOW THE RECORDS WERE ACTUALLY FOUND =========================================
NOT by this scan. The scan has never produced a record-class spot. Both records
came from picking a spot and hunting it to exhaustion with a 14-BIT mask.

That is the whole difference, and it is arithmetic, not luck:

    a mask of b bits carves out a residue class of exactly 2^(48-b) layouts,
    and nothing else exists inside it.

        20 bits ->  2^28 =   268 million layouts
        14 bits ->  2^34 = 17179 million layouts     64x more

The derivation keeps adding bits while each one raises the HIT RATE. But every
bit also HALVES the family, and the later bits buy less than the 2x they cost.
So driving to 20 bits maximises hits-per-second and minimises total reachable
options - it makes the search feel fast while shrinking what it can ever find.

    winners = 2^(48-b)  x  p(count>=score-t)  x  pWin

is the quantity that decides whether a family contains a record at all, and it
favours LOOSER masks. --max-bits now defaults to 14 for that reason. Set it back
to 20 if you want raw rate instead of reachable options.

== WHAT THE RECORDS HAVE IN COMMON (measured) ===================================
Nothing geometric. Both were tested against 112 ordinary spots on the same Z line:

    variance of chunk count :  74th and 89th percentile
    variance of cq (blocks) :  78th and 91st percentile

Neither puts them in the top few percent, so no cheap spot statistic will pick
them out, and widening --gate-top only buys them a lottery ticket. What they
share is not the SPOT, it is the SEARCH: 14-bit masks (2^34 layouts) hunted to
exhaustion. That is what the win column and --max-bits 14 are for.

== IF THE SCAN SEEMS TO FREEZE =================================================
Every candidate row now prints "(1.2s, cum 340s)". The first number is that
spot's own work; cum is total wall clock since pass 2 started. If cum jumps far
more than the per-spot times add up to, the missing time is OUTSIDE the scan's
own measurement and it is one of:

  1. OUTPUT BUFFERING. Windows block-buffers stdout when it is redirected or
     piped, so rows pile up and emerge in bursts. stdout is now line-buffered
     and flushed per row, which should end it.
  2. GPU CONTENTION. If slime_gpu is hunting in another window, the scan's
     kernels queue behind it. Check with: nvidia-smi
  3. --big-n. The bootstrap escalates to 200M seeds per round, four rounds. At
     3.8M seeds/s that is ~52s per round on an unlucky spot. --big-n 32000000
     caps it; you lose depth on the derivation, not correctness.

== OPEN IDEA: THE FAMILY IS FINITE, AND YOU SAMPLE IT WITH REPLACEMENT =========
STATUS: DEPRIORITIZED. Both records came from DIFFERENT families, so breadth
across families (THE RECORD LOOP above) beats draining any one family to the
bottom. Enumeration only becomes the right tool if the loop stalls and one
family is worth finishing exactly. Kept for that day:

A 20-bit --fix-mask leaves 28 free bits in the low 48. That is the ENTIRE family:
2^28 = 268 million distinct layouts, and nothing else exists in it.

    enumerate all 268M           71 s at 3.8M seeds/s  -> exact family maximum
    random sampling to see all   5.2 BILLION seeds     -> 19x more, no guarantee

The hunt draws random seeds and masks them, i.e. samples WITH replacement. About
450M random draws on a 2^28 family covers ~81% of it; the last 19% costs more
than the first 81% did. Enumerating the free bits instead - scatter a counter
into the 28 free positions - visits every layout exactly once, never repeats, and
TERMINATES knowing the family's true best.

    19-bit mask -> 2^29, 141 s.   16-bit -> 2^32, 19 min. All still enumerable.

NOT BUILT. It changes how slime_gpu GENERATES seeds, not how it scores them, so
the kernel math is untouched.

== BUILT: --derive-eff, cq-AWARE DERIVATION (hotspot_scan.cu) ===================
The count ladder (derive()/tailBitsKernel) picks bits by correlating them with
chunk-COUNT. Count and cq correlate in general, but the signal that actually
separates a record from a dud is the RESIDUAL: given a seed already clears a
count floor, does a bit predict better packing specifically, not just more
chunks. The ladder cannot see that - it only ever asks about count.

--derive-eff is an ADDITIVE post-pass, not a replacement: it never touches a
bit the count ladder already fixed, it only gets a chance at bits still free
within --max-bits after the ladder (and reachGuard) are done. On the same
tail population at --deep-t, it runs a per-bit Welch's t-test on mean packing
efficiency (blocks/256/chunks), split by that bit's value, and fixes the most
significant one if it clears both an effect-size bar (--min-eff-dev, default
0.02) and a significance bar (--eff-z-min, default 5.0) - same two-bar pattern
the ladder itself uses (significance alone is not enough; effect size alone
was v3's old bug). Repeats against the widened mask; anything it fixes still
has to survive reachGuard, no exemption.

Measured: at the default --max-bits 14, the count ladder on the
known record spots already consumes the entire budget on its own - --derive-eff
gets no free bits to test and changes nothing (verified: identical mask with
and without it). Raise --max-bits/--bit-window and it does find things: on a
fresh, less-explored hunt hit, at loosened bars (--min-eff-dev 0.005
--eff-z-min 2.5) it found and fixed a real bit (t=11.6) that reachGuard then
correctly released for not holding up at --deep-t - the safety net working
exactly as intended on a bit that looked good at a small effect size but
didn't generalize. Off by default (opt-in, same experience unless asked for);
validated in --self-test [5/5] against slime_core.h's scoreCenterBlocks/
scoreCenterChunks.

== BUILT: HIGH-BIT NEIGHBOR CLIMB (--climb in slime_refine) =====================
A finding from the Minecraft seed-hunting community, checked against this
project's own isSlimeChunk and confirmed real: java.util.Random's LCG step is
    state = state*MULT + ADD  (mod 2^48),  MULT odd (~35 bits)
Flip seed bit b and the product changes by (MULT<<b) mod 2^48 - a left-shift-
then-truncate can only ever ADD bits at position >= b (truncation drops the
overflow, it never wraps to the bottom). So flipping a HIGH seed bit perturbs
only the top few bits of the LCG state, not a fresh independent draw. Seeds
differing solely in high bits render nearly-identical slime layouts.

This is a DIFFERENT axis from everything else in this file: hotspot_scan's
derivation correlates LOW bits (0-23) across many random seeds at one
location; this fixes everything and sweeps HIGH bits (default 35-47, 8192
variants) of ONE known seed to search its local neighborhood. They cannot
interfere - --fix-mask and --climb's window never overlap.

CONFIRMED, not just theorized: an 8192-variant sweep around the 66.04 record
ties it exactly in 24/8192 variants - far too often to be coincidence (an
independent seed lands on this exact layout at a rate no feasible hunt
reaches). It also turned up a real, if small, live example: two of this
project's own historically-logged "66.04" seeds (-4777489624898000638 and
-3351750423259698942) turn out to share the same low 32 bits and differ only
in bits 32-47 - i.e. they are high-bit neighbors of each other, both landing
on the identical layout, discovered independently in different sessions.

Usage: slime_refine --climb climbs the top --climb-top result(s) (default 1)
of the current batch; --climb-recurse repeats the same fixed-size sweep
centred on any improvement, up to --climb-max-rounds. Pure local search over
a seed ALREADY in hand - finds no new families, just squeezes out any free
extra cq. Reuses scoreSeed()/Weights unchanged, so it carries none of the
scoring-correctness risk a new kernel would - self-test still covers the
only math it depends on.

Honest odds, confirmed on this project's own two best hunts recorded:
plateaus are common (the 66.04 record itself: no improvement, exact ties
only) but real gains happen (a fresh, non-record hit from tonight's scan
climbed from 63.77 cq to 64.17 cq in one recursive round). It will not
manufacture a new record out of a mediocre spot, but it is free money on
anything already close.

NO DEAD ZONE at bits 24-34, checked directly: that's the range between
hotspot_scan's derivation ceiling (bitWindow 0-23) and --climb's default
window (35-47) - neither mechanism touches it by default. Tested it
(--climb-lo 24 --climb-bits 11) on both the 66.04 record and a fresh hit:
same plateau-prone behaviour as 35-47, no structural difference. Left the
default window narrow (fast, cheap) rather than widening it, since a full
--climb-lo 24 --climb-bits 24 sweep is ~2000x more variants for a mechanism
that ties more often than it improves - but it's one flag away if a plateau
at the default window is worth digging further on.

== BUILT: GPU-ACCELERATED CLIMB (--climb-scan in slime_gpu) =====================
CPU --climb scores each variant via slime_refine's full block-precision sweep
(256x the positions of a chunk-aligned check) - fine for 8192 variants, far
too slow to widen to the bits-24-47 range (2000x more variants) or climb many
seeds at once. slime_gpu.exe --climb-scan is a GPU coarse pass: it reuses
bitKernel's existing bitmap-once/slide-many-positions architecture (already
built for the hunt) unchanged, and adds a cq-aware scoring kernel
(scoreBlocksKernel/computeStripBlocks) alongside the existing chunk-count one.

THIS is the context where the README's original "9 popcounts" idea (see the
correction under EXACT cq ON THE GPU below) actually pays off, unlike
hotspot_scan's fixed-single-centre case: --climb-scan's whole point is MANY
overlapping chunk-aligned positions sharing ONE staged bitmap, so 9 popcounts
per row instead of 1 is cheap - both are cheap next to the LCG bitmap
generation that dominates either way. cRowPlaneMask (17 rows x 9 weight bits,
153 uint32 constants) is built once from slime_core.h's buildBlockWeights,
which already zeroes the four excluded cells' weight - unlike the chunk-count
kernels, no separate exclusion-cell subtraction is needed; a weight of 0
contributes 0 blocks automatically. Validated in --self-test's "Blocks-path
check" against a CPU reference built from scoreCenterBlocks, exact match.

Usage:
    slime_gpu.exe --climb-scan --seed <s> --center-x X --center-z Z --m-chunks 6
        [--climb-lo 35 --climb-bits 13 --climb-top 10]
Prints the top candidates by CHUNK-ALIGNED blocks - a coarse pre-filter, not
the final answer (chunk resolution loses the sub-chunk offset precision that
is where the extra 0.33 cq on the 66.04 record actually came from). Feed the
printed seeds to slime_refine --seeds <csv> --center-x X --center-z Z
--radius 6 --climb for the real block-precision number.

Staged by design, not a shortcut taken for lack of time: this mirrors the
project's own existing division of labour (GPU finds WHERE at chunk
resolution, CPU refines to block precision) instead of re-deriving
slime_refine's validated 256-offset math a second time on GPU. End-to-end
verified on both known-good cases: --climb-scan on the 66.04
record's seed found chunk-aligned ties at 65.71 (correct - that IS the
chunk-aligned score for that spot per slime_core.h's own validation
comment), and every one of those candidates refined to EXACTLY 66.04 cq at
block precision. Same check on the fresh 63.77-cq hit from tonight's scan:
GPU pass found candidates, block-precision refinement landed on EXACTLY
64.17 cq - the identical number the CPU-only --climb already found.

NOT BUILT (deliberately, scope call): slime_refine --climb-gpu, an automatic
wrapper that would shell out to slime_gpu --climb-scan and refine the winners
itself in one command. The two-step manual pipeline above (run --climb-scan,
paste its printed seeds into slime_refine --climb) is simple, transparent,
and was what actually got validated end-to-end. Automatic subprocess
spawning/parsing is real added complexity and failure surface (path
resolution, argument passing, output parsing) for a convenience gain over an
already-working two-command flow - deferred, not silently dropped.

== BUILT: EXACT cq ON THE GPU (cqRateKernel in hotspot_scan.cu) ==================
efficiencyProbe used to be a CPU-only pass, capped at 12M seeds / 400 samples on
one core - the thinnest-sampled number in the whole pipeline, and pure pass/fail
minimums (--eff-target/--min-pwin/--min-winners) built on top of it. It is now a
GPU kernel (cqRateKernel) run at the same seed scale as the count-based
measurements (--eff-n, default 128M), so cqCeil/pWin get real statistical depth.

CORRECTION vs the original idea below: the "9 popcounts" plan assumed a spatial
bitmap was already available so popcount is free. It isn't, here - hotspot_scan
scores one FIXED centre per seed via a 222-cell position list (not slime_gpu's
sliding-window bitmap, which is where many overlapping centres make popcount pay
off). For one fixed centre the 222 LCG evaluations dominate cost 10-20x over the
final reduction, so a 9-plane popcount buys nothing measurable over a plain
weighted-sum accumulator (cCellW[222], one multiply-add per cell) - which is what
got built instead: exact, simpler, same GPU-parallel win. Validated in
--self-test [4/4] against slime_core.h's own scoreCenterBlocks, bit-for-bit.

This is also what --rank-by like (see ALTERNATIVE [1] at the top) is built on -
every candidate gets a real cqCeil/pWin instead of a coin-flip's worth of CPU
samples, which is what makes ranking by resemblance to a known record instead of
a hard minimum actually trustworthy.

Original idea, for the record:
    blocks = SUM over b=0..8 of  2^b * popcount(S & W_b)
where S is a per-seed slime bitmap and W_b is the bitmask of cells whose weight
has bit b set. Still exact, if a future kernel actually has S as a bitmap already
(e.g. a fused derive+bitmap kernel) - just not the win it looked like here.

TESTED AND REJECTED: ranking on "inner core" count (the 153 cells at full 256
weight) as a cheap cq proxy. It is WORSE than plain count:
    corr(total count, cq) = 0.8685
    corr(inner count, cq) = 0.8035
The rim contribution matters too much. Use the exact weighted-sum form instead.
