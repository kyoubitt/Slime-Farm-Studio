> **The previous full AI_CONTEXT.md**, kept for the record-cycle tools (record_cycle.ps1, reclimb_top.ps1, ./slime climb / dupes) and the sections the new short `AI_CONTEXT.md` does not carry. Its numbers predate the 20,506 record and the heat pipeline: where they differ, `AI_CONTEXT.md` and `docs\*.txt` win. The phase model now lives in `docs\PHASE_MODEL.txt`.

# AI_CONTEXT — read this first

--------------------------------------------------------------------------------
## ⛔ STOP — DO THIS FIRST, BEFORE ANY OTHER COMMAND IN ANY DOC

**RUN `build.ps1` AND CONFIRM ALL THREE SELF-TESTS PASS BEFORE RUNNING
ANYTHING ELSE. THE SHIPPED `.exe` FILES WILL NOT RUN ON A DIFFERENT GPU
THAN THE ONE THEY WERE BUILT ON.**

`build.ps1` compiles with `-arch=native`, which bakes in the exact compute
capability of the build machine. Run a binary built elsewhere on a different GPU
architecture and you get this, with no hint that rebuilding is the fix:

    CUDA error: no kernel image is available for execution on the device
    at hotspot_scan.cu:631

Verified for real, not theorized: binaries built on an RTX PRO 6000
Blackwell (sm_120) fail exactly like that on an RTX 4050 laptop (Ada,
sm_89). The same `build.ps1` on that laptop, with no other change, rebuilt
all four tools and passed every self-test. So the fix is always:

    powershell -ExecutionPolicy Bypass -File build.ps1
    ./build.sh                                              # Linux - see LINUX.md

**On Linux** the same `.ps1` scripts run under PowerShell 7: `pwsh -File record_cycle.ps1 ...`.
`build.sh` gives every tool a `<name>.exe` link, the tools accept `\` paths, and the scripts'
few Windows-only bits (`Start-Process -WindowStyle`, raw `"$root\..."` .NET paths,
`powershell -File`, CIM in stop_all) are now cross-platform with identical Windows behaviour.
LINUX.md has everything, including what was fixed.

Skip this ONLY if you are on the SAME machine that produced the binaries and
no source file has changed. Anywhere else — new box, rented GPU, someone
else's PC — rebuilding is mandatory, not advisory.

### Prerequisites for that build (neither ships here)

**1. CUDA Toolkit** (provides `nvcc`). A *toolkit-only* CUDA 13 install is
missing pieces `nvcc` needs and cannot compile a `.cu` file at all:

| missing | symptom | comes from |
|---|---|---|
| `include/crt/*` | `C1083: Cannot open include file: 'crt/host_config.h'` | `cuda_crt` component |
| `nvvm/bin/cicc.exe` | bare "The system cannot find the path specified." | `libnvvm` component |
| `bin/crt/link.stub`, `prelink.stub` | link failures | `cuda_nvcc` (under `bin/crt/`) |

Do **not** "fix" the first by copying the flat `include/host_config.h` into a
new `crt/` directory — the flat headers are deprecation wrappers that
`#include "crt/host_config.h"`, so it self-references and gives
`C1014: too many include files: depth = 1024`. Pull each missing
redistributable component and copy its tree in; verify against the published
SHA-256 list at
`https://developer.download.nvidia.com/compute/cuda/redist/redistrib_<version>.json`,
which also lists every component and its size.

**2. Visual Studio Build Tools, "Desktop development with C++" workload**
(provides `cl.exe`, which `nvcc` shells out to for host code). `build.ps1`
locates it itself via `vswhere` and hard-fails if absent — deliberately,
because the alternative is `nvcc` erroring while stale `.exe` files survive
and self-tests "PASS" against them, proving nothing about the current source.

--------------------------------------------------------------------------------
## WHAT IS IN THIS COPY

This is a self-contained, **source-only** copy of the slime-chunk toolchain.
Read this section before trusting any path or command mentioned further down.

- **No prebuilt `.exe` files, on purpose.** `build.ps1` compiles with
  `-arch=native`, which bakes in the GPU model; a binary built on one card fails
  on another with `CUDA error: no kernel image is available`. Building on your
  own machine is mandatory step one (see STOP above).
- **No hunt data.** No records, no ledger (`families.csv`), no logs, no cycle
  history, no heat-survey CSVs. `main\` ships as empty working folders plus
  `main\best_spots.csv` (500 pre-ranked spots). A hunt starts from scratch and
  builds its own archive as it runs.
- **One markdown file.** This is it. The phase-model derivation lives here under
  THE PHASE MODEL, and the old session notes were folded into WHY THE TOOLCHAIN
  IS SHAPED THIS WAY.
- **Some paths below are historical.** The dated log sections mention
  `heat\*.ps1` / `SlimeModel.cs`, `main\theory\` study files and `main\archive\`
  that this copy does not have - survey, regression and research tooling that
  depended on data not included. They appear only in comments and prose; no
  shipped script calls them. The three `heat\` scripts the search itself uses
  ARE here: `best_spots.ps1`, `best_family.ps1`, `phase_spots.ps1`.

What runs in a fresh copy:

| Entry point | Status |
|---|---|
| `build.ps1`, `stress_toolchain.ps1`, `tidy.ps1`, `perimeter_setup` | work as-is |
| `record_cycle.ps1` (`-Status`, default scan hunt), `stop_all.ps1` | work as-is |
| `record_cycle.ps1 -PhaseSearch` / `-BestFamily` | work - pass `-BestFamilySpots main\best_spots.csv` |
| `auto_shootout.ps1` | works after one scan cycle (needs `main\commands\commands_*.csv`) |
| `reclimb_top.ps1`, `afk_rescan.ps1`, `y39_rank.ps1` | need farms your own hunt has filed; each prints a notice until then |
| `predict_cycle.ps1` | unavailable - needs the whole-world survey `main\theory\heat\spot_measured.csv` (not shipped); prints a notice and exits |
| `heat\best_spots.ps1` | unavailable - its survey inputs are not shipped; it now leaves `main\best_spots.csv` untouched instead of emptying it |

## ⚠ THE ONE THING TO INTERNALIZE BEFORE ANYTHING ELSE IN THIS FILE

**THIS TOOLCHAIN MUST BE RE-TUNED FOR THE SPECIFIC MACHINE IT RUNS ON. IT
IS NOT PORTABLE-BY-DEFAULT. TREAT EVERY WALL-CLOCK NUMBER, EVERY DEFAULT,
AND EVERY "THIS IS THE RIGHT SETTING" CLAIM IN THIS ENTIRE PROJECT AS
SPECIFIC TO THE GPU (AND CPU) IT WAS MEASURED ON — NOT AS A UNIVERSAL
TRUTH.**

This is not a caution repeated out of habit — it already happened once,
for real, in this exact project. The same unmodified code, measured on two
different real GPUs:

    stage          old GPU (~20 SMs)   current GPU (188 SMs)   ratio
    scan pass 1        ~66.7k loc/s        2.7M loc/s          ~41x
    hunt (fused)         4M seeds/s        54-58M seeds/s      ~13x

A 13-41x swing is not a rounding error — it is enough to make every
wall-clock-denominated tuning choice in this project (`-Seconds`,
`-GateTop`, `-Top`, projected run times, "how long a cycle takes") **wrong
by an order of magnitude** on different hardware, in either direction. A
setting that is "the safe, measured-correct default" on one machine can be
absurdly loose or absurdly tight on another.

**Before trusting or reusing ANY tuning value in this project on a new
machine:**
1. Run `build.ps1` (or the equivalent build line for whichever tool) and
   confirm every self-test passes on the new hardware first.
2. Run `--bench` (`hotspot_scan`) and a short time-limited hunt
   (`--time-limit-ms`, `slime_gpu`) to get REAL numbers for THIS machine.
3. Only then decide whether `-Seconds`, `-GateTop`, `-Range`, `--max-bits`,
   etc. need to change - do not assume the numbers already in these docs
   still apply.

**The one exception:** constants denominated in raw SEED COUNTS rather
than wall-clock time (`--give-up-after 20000000`, `--give-up-hits 10`,
etc.) ARE hardware-independent and do not need to change. Everything
measured in SECONDS does need re-checking.

--------------------------------------------------------------------------------

Purpose: a single, dense, comprehensive brief for anyone (human or AI)
picking up this project cold. It intentionally duplicates the essential
facts from README.txt and STEP_BY_STEP_GUIDE.txt rather than just pointing
at them, so this one file is sufficient on its own.

## What this project is

A CUDA/C++ toolchain that searches Minecraft world seeds for the single
best slime-chunk farm spot: `hotspot_scan` picks WHERE to look,
`slime_gpu` brute-forces SEEDS at a spot on the GPU, `slime_refine`
computes the exact score (`cq`, defined below) at block resolution and
replaces the community `SlimeFinder.jar` entirely, and `perimeter_setup`
closes the last gap by generating an in-game rig to check the model
against Minecraft itself (see IN-GAME VERIFICATION below). Shared scoring
math lives in one file, `slime_core.h` — **do not fork it**; every tool's
correctness depends on all of them agreeing with the same math. The goal
is a single number: beat the current best `cq`.

## Current state — check this is still true before trusting it elsewhere

- **THE RECORD IS 66.04 cq**, seed `9029506488461633794`, AFK at block
  `(3680,6989)`, family `0xFDE0F|0x70802`. 70 chunks at 94.3% packing, and
  **verified in-game at 17,112 spawning spaces** with Carpet's
  `/perimeterinfo`. It is the file prefixed `RECORD.` in `main\records\`.
- **A 66.21 cq result also exists** — seed `-89761025938370956` at block
  `(40776,5411)`, family `0xEF70F|0x4C604`, 70 chunks at 94.6% packing,
  proven exhaustively to be that family's true maximum. It scores HIGHER in
  the model but **measured WORSE in game**, so it does not hold the title.
- **Rank by the in-game measurement, not the model cq.** The highest number
  in `main\records\` is not automatically the record — the `RECORD.` prefix
  is. The model is a geometric prediction; `/perimeterinfo` is the game's
  own answer, and where they disagree the game wins. See the AFK-HEIGHT
  CAVEAT under IN-GAME VERIFICATION for the leading explanation of why they
  can disagree at margins this small.
- Search state: `main\families.csv` (the ledger) and `main\cycles.txt`
  carry everything forward across runs. Last run used `-Range 100000`
  (script default is still 25000 — pass `-Range 100000` explicitly).
- Resume with exactly one command — **but only after `build.ps1` has passed
  on THIS machine** (see the STOP section at the top of this file; the
  built binaries are `-arch=native` and will not run on a different GPU):
  `powershell -ExecutionPolicy Bypass -File record_cycle.ps1 -Range 100000 -Repeat 100`
  On the SAME machine that built them, and with no source change since, no
  rebuild is needed — `build.ps1` was run after every source change and the
  binaries already reflect it. On ANY other machine, rebuild first.
- **If any of the above contradicts `main\families.csv`/`main\cycles.txt`
  when actually checked, trust the files** — this brief is a snapshot, not
  live state.

## File map

```
slime_core.h        scoring math shared by all 4 tools. DO NOT FORK.
hotspot_scan.cu      WHERE to hunt: --scan / --check / --self-test
slime_gpu.cu          THE HUNT: brute-forces seeds; --worker, --climb-scan
slime_refine.cpp      WHAT IT'S WORTH: exact cq; --climb
perimeter_setup.cpp   IS THE MODEL RIGHT: in-game verification rig, no --self-test
build.ps1             builds all 4 + runs the 3 GPU/refine self-tests; self-locates cl.exe
record_cycle.ps1      ONE full automated cycle; -Repeat N, -Status, resumable
hunt_pipeline.ps1     the per-cycle engine record_cycle.ps1 drives
stop_all.ps1          the ONLY correct way to stop — verifies GPU is idle
stress_toolchain.ps1  benchmarks + timed stress pass

main\families.csv    LEDGER — every (mask,val) hunted. NEVER hand-edit
                      casually; this is what prevents re-hunting old ground.
main\cycles.txt       numbered run log, one line per cycle
main\records\<cq>_<seed>.{txt,png}   PERMANENT — auto-filed 64/65/66+ finds,
                      ONE flat folder (no tier split), deduped by pattern —
                      the actual result archive, never auto-cleaned. The cq
                      prefix is the only "data in the name" and exists
                      purely so the best results sort together
main\scores\<x>_<z>\<seed>.{txt,png}  WORKING — refine logs + matching
                      images, grouped by spot. Regenerated by any refine
                      run; safe to delete anytime, nothing reads it back —
                      anything worth keeping is already in records\ above
main\seeds\<x>_<z>.csv  WORKING — raw hunt output per spot, same
                      disposability as scores\ above
main\work\            SCRATCH — per-cycle pipeline intermediates, safe to
                      delete freely (routinely cleaned; nothing final here)

README.txt                command reference, kept current, read top-down
FEATURES.txt               capability checklist - what this can actually do
STEP_BY_STEP_GUIDE.txt    concept-by-concept explainer, easy to hard,
                          includes the same runnable commands with what
                          each flag does
AI_CONTEXT.md              this file
```

## Hardware

Every wall-clock number in every doc was calibrated on an RTX PRO 6000
Blackwell (188 SMs, 96 GB, sm_120) with a 16-thread CPU. On
different hardware, re-measure with `--bench` before trusting any timing
claim — SEED-denominated constants (`--give-up-after 20000000` etc.) are
hardware-independent and need no change regardless of GPU.

CUDA 13 toolkit-only installs are missing pieces `nvcc` needs and cannot
compile a `.cu` file until they're added:

| missing | symptom | comes from |
|---|---|---|
| `include/crt/*` | `C1083: Cannot open include file: 'crt/host_config.h'` | `cuda_crt` component |
| `nvvm/bin/cicc.exe` | bare "The system cannot find the path specified." | `libnvvm` component |
| `bin/crt/link.stub`, `prelink.stub` | link failures | `cuda_nvcc` (under `bin/crt/`) |

Do **not** "fix" the first by copying the flat `include/host_config.h` into
a new `crt/` directory — the flat headers are deprecation wrappers that
`#include "crt/host_config.h"`, so that self-references and gives
`C1014: too many include files: depth = 1024`. Instead pull each missing
redistributable component and copy its tree in (verify against the
published SHA-256 list at
`https://developer.download.nvidia.com/compute/cuda/redist/redistrib_<version>.json`,
which also lists every component and its size). Also needs VS Build Tools
+ the C++ workload for `cl.exe`; `build.ps1` locates it itself via
`vswhere` and hard-fails if missing rather than silently building against
stale binaries.

## Core invariants — violate these and results silently corrupt

1. **`slime_core.h` is the single source of truth for scoring.** All three
   tools must agree. Don't add a parallel scoring path anywhere else.
2. **Refine at the SAME centre the hunt used.** A derived bitmask is
   per-spot; its seeds mean nothing at a different centre (silently gives
   ~25 chunks, the random rate, with no error).
3. **Always stop with `stop_all.ps1`.** Killing scripts by hand orphans a
   `slime_gpu` process on the GPU, which breaks the NEXT run with
   `CUDA error: unknown error`.
4. **The eligible-area mask is a 222-cell ANNULUS** (`24² < dist² ≤ 128²`),
   not a disc — see OBJECTIVE below for why.
5. **`cq = blocks / 256`, not chunk count.** Chunk count is a leaky proxy —
   packing efficiency falls as count rises, so ranking on raw chunk count
   silently prefers worse farms — see FRONTIER below.
6. **PowerShell unwraps single-element arrays on function return.** This
   bug class has bitten twice (a 1D seed-list slice, and a 2D pixel-grid
   array) — always re-wrap with `@()` (or `,$x` for 2D) at any call site
   that indexes/slices a function's return value.

## Verification discipline — follow this for any change

Self-tests alone have missed real bugs here before. Every change should be
checked against real data, not just self-tests:
1. Extend `--self-test` with a GPU-vs-CPU-reference check for any new
   kernel or statistic.
2. Run `build.ps1` (all 3 tools, all self-tests) before calling anything
   done.
3. Re-check against BOTH known records (66.21 and 66.04 should still
   reproduce exactly) AND a known dud spot (`55408,-8528` scores 0.0 at
   T>=68) — not just synthetic self-test cases.
4. For anything genuinely complex or touching the validated
   derivation/scoring logic specifically, plan before touching code —
   validated as the right call more than once on real changes.

---

## THE MOST COMMON REQUEST — "find the best cluster in MY seed"

Most people arriving here already have a world and want the best farm spot
in it. That is the FIXED-SEED search (vary position), not the record hunt
(vary seed). Follow this order.

**1. Bench first.** Confirms the build actually works on this machine, and
produces the real throughput numbers for it:

    hotspot_scan.exe --bench --center-x 0 --center-z 0 --range 40

**2. Then offer to re-tune.** After the bench — not before, not after the
build — ask whether they'd like the defaults (`-Seconds`, `-GateTop`,
`-Top`) re-tuned for their hardware, and say it's RECOMMENDED. Just offer;
only re-tune if they say yes. Every default in these docs came from one
specific GPU and was never measured on theirs.

**3. Search outward in three passes:** 10k, 100k, then 1M blocks.

    slime_gpu.exe --seed <SEED> --center-x 0 --center-z 0 --m-chunks 625     # ~10k
    slime_gpu.exe --seed <SEED> --center-x 0 --center-z 0 --m-chunks 6250    # ~100k
    slime_gpu.exe --seed <SEED> --center-x 0 --center-z 0 --m-chunks 16000   # ~256k, tile for 1M

`--m-chunks` is a RADIUS and caps at 16000 (±256,000 blocks). For the full
million, tile it — 16 runs on a 4x4 grid of tile-centres covers ±1,024,000
blocks in about 5 seconds. Then refine each finalist for the real number:

    slime_refine.exe --seeds seed.csv --center-x <X> --center-z <Z> --radius 6

**4. Recommend the CLOSEST good result, not the highest number.** This is
the part that needs explaining, because the raw table always makes the
furthest one look best. Show the trade explicitly:

    radius    cq      AFK spot          distance
    10k       44.00   -9362, -3851       10,123
    100k      46.70   38690, 54583       66,911
    1M        46.92   35826, 103296     109,337

10k -> 1M is 100x the search area and 10x the travel for +2.9 cq (~750
spawning blocks). 100k -> 1M is 1.6x further for +0.22 cq (~56 blocks) —
essentially nothing.

The reason is structural and worth saying out loud: **best-found grows
LOGARITHMICALLY with area searched, while travel cost grows LINEARLY.** Good
spots get rarer the further out you go in the way that matters — each extra
chunk costs exponentially more ground. So a few hundred extra spawning
blocks almost never justifies several times the distance. Recommend the
nearest result within ~1 cq of the best, and say why.

Set expectations early too: a single fixed seed's best spot is usually
**44-47 cq** even across a million blocks. Records (66+) come from searching
SEEDS, not positions — that's `record_cycle.ps1`, a different job entirely.

**5. Then offer the perimeter builder.** Once they've picked a spot, tell
them there's a built-in in-game rig generator to verify it for real:

    perimeter_setup.exe --seed <SEED> --center-x <X> --center-z <Z>

(the defaults are the reference rig - radius 152, void-top -40, /tp at y -50, 1.20.4 /give; see IN-GAME VERIFICATION)

It emits the whole floor as one pasteable command. Worth mentioning: load
the same seed in a **superflat** world to test it — there's almost no
terrain to clear, so the void step is far quicker and the rig goes up in
seconds. Full detail in IN-GAME VERIFICATION below (needs Carpet and
WorldEdit).

---

## THE OBJECTIVE

cq = eligible blocks / 256, at ONE fixed AFK spot, y-offset 0. Higher is
better. A chunk is 256 blocks, so k chunks caps at k.00 cq; real packing
efficiency is 90-97%.

Eligibility is an ANNULUS around the AFK point, not a disc: slimes cannot
spawn within 24 blocks of a player, and a naive 226-cell disc mask
overstates scores 33.2% of the time by including 4 dead chunks inside that
exclusion radius. The correct mask is 222 live cells:

    24^2 < a^2 + b^2 <= 128^2   (max 49640 blocks, 193.91 cq ceiling)

Verified block-for-block, chunk-for-chunk, against the community-standard
SlimeFinder.jar's own output (10/10 test rows).

## RECORDS - ranked by IN-GAME measurement, not by model cq

  Read this ordering carefully. The highest model cq in main\records\ is NOT
  automatically the record - the file prefixed RECORD. is. A model cq is a
  geometric prediction; /perimeterinfo is the game's own count, and where the
  two disagree the game wins.

  66.04 cq   *** THE RECORD ***   70 chunks @ 94.3% packing   block (3680,6989)
             seed 9029506488461633794
             VERIFIED IN GAME: 17,112 spawning spaces via Carpet
             /perimeterinfo. Filed as RECORD.66.04_9029506488461633794 in
             main\records\.
             One of 1,572,864 equivalent seeds sharing this identical layout
             - see EXACT SEED DUPLICATES below.
             family 0xFDE0F|0x70802 - also the reliable day-to-day ANCHOR:
             much denser than 66.21's family, ~207 hits/20M seeds vs ~15/20M,
             so it is what the pipeline pushes every cycle.

  66.21 cq   HIGHER MODEL SCORE, DOES NOT HOLD THE TITLE
             70 chunks @ 94.6% packing   block (40776,5411)
             seed -89761025938370956
             family 0xEF70F|0x4C604 - exhaustively proven: exactly 2 seeds in
             this 2^34-seed family reach 66.21, nothing beats it. Found via
             high-bit climb on a raw 64.64cq hit, on the FIRST cycle after
             widening -Range to 50000, virgin territory. Unrelated to the
             66.04 record - different family, different location, image
             comparison found no structural link, ~23/289 shared chunks which
             is chance level.
             MEASURED WORSE IN GAME than 66.04 despite the higher model
             number. That is the whole reason the ranking above is by
             in-game measurement. See the AFK-HEIGHT CAVEAT under IN-GAME
             VERIFICATION for the leading explanation - the model computes at
             y-offset 0 and both spheres are 3D, so standing height changes
             which chunks qualify, and at margins this small that is enough
             to flip an ordering.

  65.71 cq   (2000,8544), seed -1018472292131368322 - KNOWN STALE. Real
             historical best there is 63.96 cq, a record-keeping mix-up
             from early on. Left uncorrected on purpose; don't re-derive it.

The jar could only ever find the 65.71 spot: 6989 is not a multiple of 16,
and the jar only tests chunk-aligned centres. `slime_refine` tests every
block, which is where the extra 0.33 cq on 66.04 came from - same seed,
same chunks, better standing spot.

## THE FRONTIER - why 70 chunks and not more

Packing falls MONOTONICALLY as chunk count rises (marginal chunks are light
rim cells, ~150 blocks, not full 256-block interior cells):

    count   best packing seen   needed to beat 66.04   verdict
     67c         96.0%               98.57%            not realistic
     68c         95.9%               97.12%            a stretch
     69c         94.9%               95.71%            plausible
     70c         94.3%               94.34%            THE TARGET
     71c         91.4%               93.01%            packing collapses
     72c         90.4%               91.72%            packing collapses

count x packing PEAKS AT EXACTLY 70 CHUNKS. More chunks is NOT progress -
every 71c+ result across the whole project scored below 65.1. Not a
geometric wall either: the 70 heaviest cells are all full-weight 256, so
70c could in principle reach 100% = 70.00 cq; 94.3-94.6% is nowhere near
that ceiling, plateaus just happen to be rare.

## THE COORDINATE LATTICE - a parenthesis bug, exploited

8 of 8 good spots found sit on a hot Z lattice:

    chunkZ mod 97 in {48, 49}   <=>   blockZ = 1552k+768  or  1552k+784

Only 2 of every 97 chunk-rows can host a good spot - a 48.5x search
reduction, banked by `--z-all` (generates these lines directly, no anchor
needed, cannot miss the lattice).

WHY: a genuine bug in Minecraft's own seed-mixing formula (not something
this project introduced - `isSlimeChunk` in `slime_core.h` is a verbatim,
verified-exact port of Mojang's code). The actual function:

    SLIME_FN inline bool isSlimeChunk(long long worldSeed, int chunkX, int chunkZ) {
        uint64_t seed = (uint64_t)worldSeed;
        seed += (uint64_t)(int64_t)(int32_t)((int64_t)chunkX * (int64_t)chunkX * 0x4c1906LL);
        seed += (uint64_t)(int64_t)(int32_t)((int64_t)chunkX * 0x5ac0dbLL);
        seed += (uint64_t)((int64_t)((int32_t)((int64_t)chunkZ * (int64_t)chunkZ)) * 0x4307a7LL);
        seed += (uint64_t)(int64_t)(int32_t)((int64_t)chunkZ * 0x5f24fLL);
        seed ^= 0x3ad8025fULL;

        const uint64_t MULT = 0x5DEECE66DULL;
        const uint64_t ADD  = 0xBULL;
        const uint64_t MASK = (1ULL << 48) - 1;
        uint64_t state = (seed ^ MULT) & MASK;

        for (;;) {
            state = (state * MULT + ADD) & MASK;
            int32_t bits = (int32_t)(state >> (48 - 31));
            int32_t val  = bits % 10;
            if (bits - val + 9 >= 0) return val == 0;
        }
    }

Look at the X term vs. the Z term - same shape, different parenthesization:

    X:  (int32_t)( chunkX * chunkX * 0x4c1906 )       <- one cast, at the END
    Z:  (int32_t)( chunkZ * chunkZ )  *  0x4307a7      <- cast BEFORE the 2nd multiply

X's line casts to `int32_t` only once, AFTER the full triple product
(`chunkX * chunkX * 0x4c1906`) has been computed in 64-bit arithmetic -
"multiply everything, then truncate to 32 bits," a single clean mod-2^32
reduction on the whole product.

Z's line is different: `chunkZ * chunkZ` gets truncated to `int32_t`
FIRST - a mod-2^32 reduction on JUST the square, discarding high bits
right then - and only THAT truncated 32-bit value gets multiplied by
`0x4307a7` afterward (back in 64-bit arithmetic, so this second multiply
does not truncate again the same way). "Square, truncate, then multiply"
is a different operation from "multiply everything, then truncate once,"
even though it looks almost the same on the page. This looks exactly like
a copy-paste of the X line where a parenthesis landed one token earlier
than intended - and the early truncation on Z's square is what creates a
short, exploitable numeric resonance as chunkZ increases, measured out
empirically to a period of 97 chunk-rows. X, with its single truncation at
the very end, has no equivalent short period - it drifts quasi-periodically
(~32.7 chunks) instead of tiling cleanly, so there's no equivalent "hot X
value" to search for.

Practical upshot: because of this one truncation-order difference, only 2
out of every 97 possible chunk-rows along Z ever need checking, with zero
equivalent shortcut along X.

## THE HIGH-BIT CLIMB - near-identical layouts from a known seed

`java.util.Random`'s LCG: `state = state*MULT + ADD (mod 2^48)`, MULT odd.
Flip seed bit b and the product only ever changes bits AT OR ABOVE b
(truncation drops the overflow, never wraps down). So flipping a HIGH seed
bit perturbs only the top few LCG bits - nearly the same layout, not an
independent draw.

`--climb` (slime_refine) sweeps bits 35-47 (8192 variants) of a known-good
seed and keeps the best; `--climb-recurse` repeats on any improvement.
`--climb-scan` (slime_gpu) is the GPU-coarse version, chunk-resolution
only, 16.7M variants in ~1.4-5s, feeding candidates to `--climb` for the
real block-precision number. CONFIRMED empirically, not just theorized: an
8192-variant sweep of the 66.04 record ties it exactly in 24/8192 draws -
far too often for coincidence. The 66.21 record itself was found this way
(raw hunt: 64.64cq -> climb: 66.21cq).

No dead zone at bits 24-34 (the gap between the derivation's window 0-23
and climb's default 35-47) - tested directly, same plateau-prone behavior
throughout.

## EXACT SEED DUPLICATES - the top 16 bits of a 64-bit seed are provably dead (verified)

VERIFIED, not just derived: `slime_refine`'s own seed-loader independently
confirms this (unprompted) by collapsing multiple seeds sharing the same
low 48 bits into "N seeds -> 1 unique low-48 layouts" before scoring. To
rule out that being the tool simply assuming the claim, it was also
checked the hard way - the record seed `-89761025938370956` and four
variants (bit 48 flipped, bit 55 flipped, bit 63/the sign bit flipped, and
all 16 top bits flipped at once) were each refined in a completely
separate process, one seed per run, so no shared dedup logic could apply.
All five returned the byte-identical result: 16950 blocks, 66.21 cq, 70
chunks, at the exact same position (40776,5411), down to every printed
digit.

A step beyond the high-bit climb above, and worth spelling out precisely
because it's exact, not probabilistic. Minecraft world seeds are 64-bit
signed integers, but every step of `isSlimeChunk`'s seed-mixing chain
before the final LCG-state line only ever touches the running value via
ADDITION and XOR:

    uint64_t state = (seed ^ MULT) & MASK;      // MASK = (1ULL << 48) - 1

Addition only ever carries UPWARD (a low bit's carry can affect a higher
bit, never the reverse), and XOR is bit-independent. So bits 0-47 of any
running sum/xor in that function are determined ENTIRELY by bits 0-47 of
the operands feeding it - bits 48-63 of the original `worldSeed` cannot
reach bits 0-47 at any point in the chain. Since the final `state` (and
therefore every `isSlimeChunk` result, for every chunk, everywhere) is
computed from `seed & MASK` only, **bits 48-63 of a 64-bit world seed have
zero effect on the entire slime-chunk map of that world, at every
location, forever.** (This isn't specific to slime chunks - it's the same
fact as `java.util.Random`'s own documented 48-bit internal state; the
JDK's own seed scramble is `(seed ^ 0x5DEECE66DL) & ((1L<<48)-1)`, the
identical mask, so this reasoning applies to anything seeded directly with
`java.util.Random`, not just this one formula.)

Consequence: for any seed that produces a good pattern, exactly 2^16 =
65,536 OTHER 64-bit seeds - every value sharing the same low 48 bits -
produce the byte-identical slime-chunk map everywhere in that world, not
just at the one spot being farmed. This is a strictly EXACT version of the
high-bit climb above (which only guarantees "very similar," not
"identical" - climb's bits 35-47 are still inside the 48-bit window and do
change the LCG state, just only its high end). Generating that full batch
of 65,536 duplicates from one known-good seed is a single loop over the
seed's top 16 bits; no hunting, no GPU time, no uncertainty involved.

A related, broader technique worth recording: search ONE promising
location exhaustively (rather than many locations shallowly) until its
best possible pattern is found, then combine the exact bit-invariance
above with the softer near-duplicate climb (bits 35-47) to generate a very
large batch of seeds that all reproduce that same best-known pattern at
that same location. Useful whenever many INTERCHANGEABLE seeds are wanted
- e.g. distributing one known-good farm layout across many separate worlds
- rather than a single seed to remember. Not built as an automated feature
here, but directly supported by the existing `--climb` / `--climb-scan`
tools plus the exact-duplicate fact above; could be scripted as a thin
wrapper without touching `slime_core.h` at all.

**The technique carried out for real, with an exact total:** starting from
the 66.04 record's spot, a `--climb-scan` sweep of bits 24-47 (16.7M
variants, ~5s) found **24 distinct worlds** producing the identical local
layout there (24 different low-24-47-bit combinations, each then
multiplied by the 65,536 free top-16-bit duplicates above). Total seeds
that reproduce that exact farm: **24 × 65,536 = 1,572,864**. These are
genuinely different WORLDS, not cosmetic relabelings - since 1.18, terrain
and structure generation use the full 64-bit seed via a different RNG
(Xoroshiro), so all 1,572,864 keep the identical slime-chunk pattern while
having unrelated surroundings (different biomes, structures, terrain).
Useful if the same farm layout is wanted next to a specific biome or
village. Full enumeration over all 2^48 low bits is infeasible (~2.2 years
at ~4M seeds/s) but unnecessary for this purpose - random low-bit
coincidence is ~10^-77 per seed, so essentially every match comes from
this structured family, not chance.

## IN-GAME VERIFICATION (perimeter_setup)

Every number elsewhere in this file is a MODEL PREDICTION: `slime_refine`
computes eligible spawn blocks from `slime_core.h`'s annulus weights,
validated against `slimefinder.jar` - which is validation against another
PROGRAM, not against Minecraft itself. `perimeter_setup` closes that loop.
It emits the exact in-game commands to build a physical test rig,
measurable with Carpet mod's `/perimeterinfo` (the game's own spawn-space
calculation), and compares directly against the model. At record margins
the two can disagree enough to flip a ranking (see AFK-HEIGHT CAVEAT
below) - when they conflict, the game wins, the model needs explaining.

**Requires the Carpet mod** (for `/perimeterinfo`) **and WorldEdit** (for
the void step) both installed on the world being tested - neither is
optional. Without Carpet there is no way to read the result; without
WorldEdit there's no vanilla equivalent that clears a box this large in
one shot.

**The rig, conceptually:** void a large box around the AFK spot, lay one
layer of floor block (default obsidian) at the world floor in slime
chunks ONLY (everywhere else stays void), disable mob spawning (live mobs
would eat spawn positions and corrupt the count), then measure with
`/perimeterinfo`. Since every spawnable position in range is now
slime-chunk floor by construction, the reported count IS the spot's real
slime capacity - directly comparable to `slime_refine`'s block count for
the same position. One floor layer is enough: a spawn position needs a
solid block beneath and air above, so one layer with void above it
satisfies exactly one spawn position per column.

```
perimeter_setup.exe --seed <s> --center-x <x> --center-z <z>
                    [--y -64] [--radius 152] [--block obsidian]
                    [--void-top -40] [--afk-y -50]
```

The defaults assume a superflat world on **Minecraft 1.20.4**: pass only seed and
centre. Change a default in `perimeter_setup.cpp`, never by flags - the old radius 200 / void-top 120
kept coming back because the -40 only ever lived in a command line.

| flag | default | meaning |
|---|---|---|
| `--seed` | required | world seed |
| `--center-x` / `--center-z` | 0 | the AFK spot, BLOCK precision - take it from `slime_refine`'s `BEST BY BLOCKS` line, not the chunk-aligned scan centre |
| `--y` | -64 | Y of the obsidian floor. -64 for 1.18+, 0 for older |
| `--radius` | 152 | half-width of the voided box AND the obsidian floor - 3 chunks in from the old 200 (reference rig), still 24 blocks past the 128-block despawn sphere |
| `--block` | obsidian | floor material |
| `--void-top` | -40 | top of the voided box (superflat: nothing above to clear) |
| `--afk-y` | -50 | Y that `/tp` puts the player at (14 above the floor; no `/spawnpoint` is emitted) |

Output is five sections in execution order (sections 0-2 and 4 paste into
chat; section 3 goes into a command block): SEED, TELEPORT
(`/tp` at y -50, `/gamerule doMobSpawning false`, `/seed`), VOID THE
AREA (WorldEdit `//pos1 //pos2 //set air`), SLIME CHUNK FLOOR (the
command-minecart monolith, see below - the only form), MEASURE (a `/give`
of the measuring block, 1.20.4 NBT: `/give @p minecraft:repeating_command_block{BlockEntityTag:{Command:"execute at @p run perimeterinfo",auto:1b}}`
- repeating, unconditional, always active; no mob argument - with one, e.g.
`slime`, Carpet dumps every spawnable coordinate and buries the summary).
VERSION: that `/give` is the 1.20.4-and-earlier BlockEntityTag NBT form. On
1.20.5+ / 1.21 it will NOT work - use the `[block_entity_data={...}]`
component form instead.

**Why a "monolith":** the floor needs one `/fill` per slime chunk,
typically ~70-110 commands for radius 152. Chat caps at 256 characters
and one line per Enter; a command block holds ~32,500 characters but
executes exactly ONE command regardless of length, so length was never the
limiting factor - command COUNT is; semicolon-chaining needs a plugin or
client mod most setups won't have; a datapack function would be the clean
answer but isn't always available either. The fix is the classic
2015-era "one-command creation" trick: `summon falling_block` a redstone
block, which lands an `activator_rail` on top of itself, and every
`command_block_minecart` **riding that rail fires once** - N fill commands
from one pasted summon command. Teardown order is load-bearing (rail
first, then the redstone beneath it, then the minecarts kill themselves -
killing first would prevent the later commands from running at all), and
self-destructing is a **correctness** requirement, not tidiness: command
blocks are solid, so slimes can spawn ON TOP of a leftover one, adding
bogus spawnable surfaces and inflating the exact count being measured. The
old chain-command-block alternative ("3a") was removed; only the
command-minecart form is emitted.

**AFK-HEIGHT CAVEAT - read before trusting any model/game mismatch:**
`slime_core.h` computes at y-offset 0 (player level with the spawn
surface; its own header says so explicitly). Both the exclusion and
despawn spheres are 3D, so standing higher than the floor changes the
horizontal footprint substantially, not just vertically:

    y-offset  0:  exclusion radius 24.0 blocks,  despawn radius 128.0
    y-offset 23:  exclusion radius  6.9 blocks,  despawn radius 125.9

The two effects roughly cancel in TOTAL area but change WHICH chunks
qualify - and since slime chunks are discrete and clustered, that is
enough to flip the ranking of two spots separated by a fraction of a cq.
This is the leading explanation for a model/game discrepancy, confirmed on
the real records: the 66.04 spot's model prediction was 16,905 blocks, the
in-game measurement was **17,112**; a 66.21-cq spot has measured WORSE in
game than the 66.04 one did. Two ways to reconcile, **neither
implemented**: measure with `--afk-y` set to the floor Y (so the model's
y-offset-0 assumption actually holds), or add real y-offset support to
`slime_refine`. Deliberately left undone - real spawn eligibility at a
given y depends on terrain/surface/lighting this toolchain's sphere-
distance math does not model, so trust an in-game measurement over the
geometry alone here. **Do not re-litigate this** by proposing a y-sweep as
the fix; if a model/game mismatch shows up, AFK height is the first
hypothesis to check, not evidence of a scoring bug.

**Worked examples**, both independently verified end to end (HISTORICAL commands, run with the
old radius 200 - do not copy the flags; today pass only seed and centre):

    perimeter_setup.exe --seed -3918692359804081918 --center-x 3680 --center-z 6989 --y -64 --radius 200 --afk-y -40 --void-top -40

66.04 record: 109 slime chunks of 676 scanned (16.1%), 27,904 blocks of
floor, a 10,458-character monolith. In-game result: 17,112 spawning
spaces, against a model prediction of 16,905.

    perimeter_setup.exe --seed -89761025938370956 --center-x 40776 --center-z 5411 --y -64 --radius 200 --afk-y -40 --void-top -40

66.21 record: 123 slime chunks of 676 scanned (18.2%), 31,488 blocks of
floor, an 11,992-character monolith.

**Presentation guidance**, for whoever (or whatever) is relaying this
output to someone actually building the rig - worth following exactly:
- One command per fenced/copyable block - chat takes one line per send, so
  a block holding several commands just means manual splitting later.
- Never paste the tool's raw stdout as commands - a shell prompt/prefix
  can get copied along with it. Reformat into clean, individually copyable
  blocks.
- File attachments (the monolith) go at the END of a response, after
  every chat command, not interleaved with them.
- Every command gets its OWN block, no exceptions - including each of the
  4 WorldEdit lines individually, even though they're always used
  together. One block holding several lines is harder to copy cleanly
  than four small ones.
- Minimal commentary between blocks - the goal is pasting, not reading.

## IDEAS TESTED AND REJECTED - do not re-run these

  variance as a record predictor        record spot ranks 22nd/202 nearby
  cqCeil / pWin / pRec as spot rankers  never rank the record spot above ordinary
  best-family hit count                 ANTI-correlated (best spot had fewest hits)
  sub-chunk alignment                   0.3% spread across all 256 offsets
  distance from spawn                   variance flat from X=0 to X=100000
  CUDA streams for --scan (not --hunt)  no idle time to fill (data-dependent loop)
  __launch_bounds__ on huntFusedKernel  4.6% SLOWER - compiler default already better
  push floor 67                         needs 98.57% packing; best ever at 67c is 96.0%
  triage 12s -> 8s                      found 3 of 8 productive spots vs 4
  dead-abort 5s -> 3s                   Poisson: ~30% of medium spots misread as dead
  gate-top 220 -> 80                    34% vs 15% productive - a REGRESSION, reverted
  GPU "throttling" at 810MHz reading    was mid-ramp; sustained load reaches 1935-2430MHz
  widening fused batch past 65535       saturating gains (~1.14x/doubling at the cap);
                                        seed-index packing is exactly 16 bits, silent
                                        wrap would save the WRONG seed
  y-sweep (re-score at different AFK height)   considered closed, not just
                                        deprioritized: real spawn eligibility at a
                                        given y depends on real terrain/surface/
                                        lighting the toolchain's sphere-distance math
                                        doesn't model, and a real record checked
                                        against naive y-math found a genuine
                                        discrepancy. Verify against real in-game
                                        spawn counts, not just this geometric model,
                                        before trusting any y-sweep proposal.

The one that bit hardest: gate-top 220->80 "looked like" a 30% speedup by
wall-clock but was actually a ~60% efficiency loss once measured against
PRODUCTIVE spots/hour, the metric that actually matters.

## GOTCHAS THAT COST REAL TIME

1. Orphaned slime_gpu process pins the GPU, next scan dies with "CUDA error:
   unknown error." ALWAYS stop with stop_all.ps1 (kills scripts, then
   workers, then VERIFIES the GPU is idle) - never kill by hand.
2. Set-Content -Encoding UTF8 writes a BOM; slime_refine parses it as part
   of the first seed -> scores seed 0. All seed writes now use
   [System.IO.File]::WriteAllText.
3. PowerShell unwraps a single-element array on function return. A hunt
   producing exactly one seed made `$all[0..0]` slice a STRING by character
   ("8533...702" -> "8"), scoring junk and poisoning the ledger. Same bug
   class bit twice: once for 1D seed lists (fixed with @() at the call
   site), once for a 2D pixel-grid array in an unrelated comparison script
   (fixed with the comma operator, `return ,$grid`). Watch for this any time
   a PowerShell function returns an array that might have exactly 1 element.
4. .NET's Process.StandardInput emits a UTF-8 BOM on its FIRST write only -
   corrupted the first line ever sent to a fresh --worker. Fixed by
   stripping a leading BOM C++-side (PowerShell's own StandardInputEncoding
   fix doesn't exist in Windows PowerShell 5.1 / .NET Framework).
5. Stale-binary false pass: if nvcc can't find cl.exe it errors but old
   .exe files survive and self-tests "PASS" against them - proves nothing
   about code just edited. build.ps1 now locates cl.exe via vswhere and
   hard-fails if missing.
6. --range is CHUNKS along X but BLOCKS along Z (isSlimeChunk's own
   asymmetry - see COORDINATE LATTICE above). --range 10000 sweeps
   +/-160000 blocks E/W but only +/-10000 N/S. Use --range-x for
   blocks-along-X.
7. A long unattended background run is not guaranteed to survive a process
   boundary - one batch went untracked for hours with no crash, no orphan,
   no corruption; the controlling process itself just went away. Verify a
   long-running process is still alive after a big gap, don't assume.
8. CUDA 13 toolkit-only installs need cuda_crt + libnvvm explicitly (see
   HARDWARE above) or a .cu file cannot compile at all. Do NOT fix the
   missing crt/host_config.h by copying flat headers into a new crt/ dir -
   they're deprecation wrappers that self-reference and blow the include
   depth.

## CURRENT TUNING (record_cycle.ps1 / hunt_pipeline.ps1)

  -Range        100000 (runtime choice; script default is still 25000 -
                pass it explicitly)
  -GateTop      600    (34% vs 15% productive-spot fraction beat 80; safe
                        direction confirmed twice)
  -Seconds      4      (triage; draws ~168M seeds/spot on this GPU - still
                        3.5x deeper than the old 12s setting on the old GPU)
  -PushSeconds  15
  -Top          120    (pass 2 is 0.14s/spot now - spots are cheap)
  triage floor  64     (a discriminator, not a collector - floor 70 ties
                        everything at 0)
  push floor    69     (frontier gap 0.81 at 69c vs 1.22 at 68c; minimum,
                        so 70/71/72 still pass through)
  push min cq   64     (34 of 34 pushes below this produced zero)
  --bit-window  20     (bits 20-23 selected in 0 of 15 real derived masks)
  --max-bits    14     (looser mask = 64x bigger family = more reachable
                        options; both known records came from 14-bit masks)
  worker/stream on by default (-NoWorker / --no-stream to disable)

## WHAT'S GENUINELY NOT DONE (surfaced, not built)

- Multi-GPU support: no --device/cudaSetDevice anywhere; every process
  piles onto GPU 0 regardless of how many cards exist. Checked and
  confirmed NOT worth it for the PRO 6000 box (VRAM at 1.8% peak,
  pure integer/bitwise compute, zero NVLink benefit) - but would be THE
  throughput win on a genuine multi-GPU box.
- Two-level position pre-filter in the fused hunt kernel (speculative,
  expected to disappoint - bitmap cost already amortized).
- Enumeration over other derived families' free bits instead of random
  sampling (deprioritized - breadth-across-families has been winning).
- --climb-gpu automatic wrapper (the 2-step manual pipeline already works
  and is what got validated; deferred, not forgotten).
- Automated "generate N exact/near duplicate seeds of a known pattern" tool
  (see EXACT SEED DUPLICATES above) - the underlying mechanism is proven,
  just not wrapped into a one-command script yet.

--------------------------------------------------------------------------------
## THE PHASE MODEL — every seed at a spot, exactly (the full derivation)

Anything in this project that points at "the phase model", or at a
`main\theory\PHASE_MODEL.md`, means THIS section — the derivation lives here
now. The dated log entries further down summarise its conclusions and record
how the search built on it evolved; what follows is the maths the GPU pass is
actually built on.

### The result in one paragraph

Only the low 48 bits of a seed matter. Split them into **family** f (bits 0–19), **class** c
(bits 20–34) and **top** v (bits 35–47). For one (family, class), changing the top 13 bits
shifts every chunk's random number by the *same* amount. The 222 chunks of a farm therefore
move in lockstep: each chunk has a fixed **phase** (0–4), and each top value selects a phase.
The farm is simply "the possible chunks in that phase" (plus one wrap-around correction). So
the best farm over all 8,192 seeds of a class is computed from 222 numbers, not by checking
8,192 seeds. Every seed at a spot (2^35 classes × 8,192) costs about what a *sampled* sweep
(50,000 seeds per family, 0.02 % of the seeds) costs. Verified exact against Java.

### Derivation

Java: `new Random(seed + P(x,z) ^ 0x3ad8025f).nextInt(10) == 0`, P = chunk offset polynomial.

- Random's scramble and first step: `st1 = ((seed + P) ^ C) * M + A mod 2^48`, with
  `M = 0x5DEECE66D`, `A = 0xB`, `C = 0x3ad8025f ^ M`. **C < 2^35.**
- `nextInt(10)` reads `B = st1 >> 17` (31 bits); slime ⟺ `B % 10 == 0` (bar a rejection case
  hit by 8 values in 2^31).
- Adding `v·2^35` to the seed adds `v·2^35` to `seed + P`; the xor cannot reach bit 35, so
  `st1(v) = st1(0) + 2^35·M·v (mod 2^48)` ⇒ **`B(v) = B(0) + 2^18·w (mod 2^31)`**, with
  `w = M·v mod 2^13` — a bijection of v, **the same for every chunk**.
- Slime needs B even: bit 0 of B does not depend on w ⇒ a chunk is **possible** for the class
  or never slime at all (depends on the low 18 bits of seed + P only — the old "family decides
  which chunks can be slime").
- Mod 5: `2^18 ≡ −1`, so `B(v) ≡ B(0) − w (mod 5)`. With **phase φ = B(0) mod 5**, a possible
  chunk is slime exactly when `w ≡ φ (mod 5)` — until B wraps past 2^31 (at
  `w ≥ thr = 8192 − (B(0) >> 18)`), after which `w ≡ φ + 2` (2^31 ≡ 3 mod 5).

For top values w ≡ r (mod 5) the slime chunks are `{φ = r, w < thr} ∪ {φ = r − 2, w ≥ thr}`.
Best farm of a class = max over r and over the ≤ 111 wrap thresholds: an event scan, no
enumeration. Upper bound without the scan: **`U = max_r (N_r + N_{r−2})`**, N_r = possible
chunks of phase r. That bound is what the GPU's prune pass computes.

### Checks (CPU reference model vs Java, run during development)

| Check | Result |
|---|---|
| Model vs Java, all 8,192 top values × 222 chunks × 25 classes, two spots | 90,931,200 checks, **0 mismatches** |
| Fast event-scan best vs full 8,192 scan, 300 classes | 0 mismatches |
| The 68.28 (family 0x9E078, class 31989, top 2268) at its AFK chunk | Java 73 chunks; model 73. Possible chunks by phase: **47 / 25 / 22 / 46 / 18** (64 impossible). The record = phase 0 before the wrap + phase 3 after it. |
| Exact exhaust of 0x9E078 (all 2^28 seeds) at that AFK chunk | **1.2 s on the CPU** (slime_gpu --enumerate: 37 s GPU). Best 73 (Java recount 73); 2,550 seeds ≥ 70; 544,251 ≥ 60 |
| 12 random families, same chunk, exact | best 32–50; **zero** seeds ≥ 60 |
| 200,000 random (family, class) pairs | best-of-class mean 31.9, **max 57** |

The live equivalent that ships is `hotspot_scan --self-test` check [7].

### What "record-class family" means now

A family is rich where many of its classes line up a large share of their possible chunks in
one phase pair. It is a **tail** property:

| At the 66.63 farm's AFK chunk | classes ≥ 60 | ≥ 64 | ≥ 66 | best | seeds ≥ 64 (exact) |
|---|---|---|---|---|---|
| 0xA2CEC (the record's family) | 1.9 % | 0.23 % | 0.07 % | 70 | 11,404 |
| 0xA2E2C | 1.4 % | 0.08 % | 0 | 66 | 2,390 |
| 0xA9735 | 1.0 % | 0.10 % | 0 | 66 | 1,556 |
| random family | ~0 | 0 | 0 | ≤ 57 | 0 |

Negative results (do not retry): the family's mean best-of-class separates rich families at
only z ≈ 3.5 (shared by ~200 of 1,048,576 families — the same trap as the family mean); a
screen of 16 sampled classes per family misses the record family. Only the exact tail finds
it, i.e. **all classes of all families** — which is what makes the exact spot search the
endgame rather than a better sampler.

### How `hotspot_scan --phase-search` uses it

Per AFK position: possible-count family cut (top `--phase-top-pct`) → bound pass (family-split
B(0): per (family, chunk) K and Q>>20 computed once per tile of 256 classes, only the family's
possible chunks looped; counts by phase × quarter of hb) → exact pass on the survivors (chunks
sorted by wrap threshold, one walk per phase) → live recount of every hit with `slime_core.h`.
Positions: every 3rd AFK chunk within ±6 X / ±3 Z (15 of them).

| Check | Result |
|---|---|
| Self-test [7]: model vs isSlimeChunk / class best vs brute force / bound ≥ best / GPU vs host | 0 / 0 / 0 / 0 differences |
| 68.28 farm chunk, one position | record class re-found (73 chunks); 52 layouts ≥ 70 |
| Position stride: 67.07 spot, full 17 × 9 grid vs every 3rd X and Z | 397 of 397 classes with best ≥ 70 still reach 64 on the stride grid |
| Family cut: one position, top 3 % vs ALL families (281T seeds, 105 s) | identical: 1,494 / 199 / 20 classes ≥ 66 / 68 / 70. Their families: ≥ 66 from 40 families (possible ≥ 142 = the cut), ≥ 68 from 9 (≥ 149), ≥ 70 from 1 (≥ 153) |

Speed history (one position, 1.17G classes, GPU shared with a running search): halves bound
+ O(n²) exact 35.3 s → quarters bound + sorted exact 6.3 s → possible-chunks-only loop 4.6 s.
The bound pass is now the whole cost; its per-chunk bookkeeping (phase, quarter, packed counts)
costs about as much as the multiply.

**Ranking by BLOCKS, not chunks.** The exact walk also tracks each class's most-blocks layout
(chunk weights = eligible blocks), and the CSV is sorted by blocks at the searched position.
This matters more than it sounds: by chunk count the 67.07 farm (69 chunks at 97 % packing)
fell outside the top 1,000 layouts at its own spot; by blocks, after merging duplicate layouts
(16,984 rows = 3,403 distinct layouts), it ranks #5. The driver refines the top distinct
layouts by blocks. Self-test [7](b) checks best blocks against brute force; the live recount
checks chunks AND blocks of every hit.

### Open theory

- **Why a family is rich.** Its phases come from `B(0)` of `(s + P_i) ^ C` — without the xor
  (C = 0) phase differences between chunks would not depend on the seed at all; the xor's
  carry pattern is what makes alignment family- and class-specific. A structural rule for
  which (f, c) align could skip even the exact enumeration.
- **Blocks, not chunks, inside the search itself.** The search counts chunks; cq (blocks) is
  scored afterwards by slime_refine. A fully block-weighted event scan is straightforward
  (weights per chunk instead of 1).

--------------------------------------------------------------------------------
## WHY THE TOOLCHAIN IS SHAPED THIS WAY — design notes carried forward

Folded in from the project's old session-handoff note. Only what is still true
and not already stated above survives here. Everything else that note carried —
the orientation, the frontier table, the record family, the coordinate lattice,
the rejected ideas, the gotchas, the tuning table and the file layout — is
covered earlier in this file in a more current form, and **where the two ever
disagreed, the sections above are the ones that are right**.

### Portability — verified against the sources, not assumed

The C++/CUDA is portable. The three tools that create directories —
`hotspot_scan.cu`, `slime_gpu.cu`, `slime_refine.cpp` — each carry a POSIX
fallback (`#ifdef _WIN32` → `direct.h`/`_mkdir`, `#else` → `sys/stat.h`/
`mkdir(d,0755)`); the other four build targets create none. Every path in the
sources uses forward slashes, and `slime_refine.cpp`'s own header documents its
Linux build line (`g++ -O3 -march=native -pthread`). The PowerShell drivers are
the Windows-only part of the project; a bash port was scoped and never written.

Portable SOURCE is not a portable BINARY: `-arch=native` compiles for the GPU
physically present, so a copied `.exe` fails confusingly on a different card.
Build on the machine that will run it — see the STOP section at the top.

### Decisions that look odd until you know why

- **"Nine popcounts" is the right design in one tool and the wrong one in the
  other.** The idea — score many positions by popcounting a shared staged
  bitmap — assumes many overlapping search positions share one bitmap. That is
  false for `hotspot_scan`'s fixed-single-center case, so the GPU exact-cq
  measurement (`cqRateKernel`) uses a plain weighted-sum accumulator instead:
  same exactness, same GPU win, far simpler. It is true for `slime_gpu
  --climb-scan`, where many overlapping chunk-aligned positions genuinely do
  share one staged bitmap, and that is where the 9-bit-weight-plane popcount
  path was built. Same idea, opposite verdicts, for a concrete reason.
- **`--use_fast_math` is safe HERE specifically.** It changes transcendental,
  divide and sqrt approximations; this project's hot paths are the LCG
  recurrence and popcounts, i.e. integer and bitwise. Verified before adopting:
  self-tests pass and `--check`'s real output (mask, cqCeil, pWin, …) is
  byte-for-byte identical to a non-fast-math build, with only the wall clock
  moving (~8–10 % faster). Do not carry the flag to a float-heavy change
  without re-checking that.
- **`CUDA_CHECK` lives in `slime_core.h` behind `#ifdef __CUDACC__`.** Both
  `.cu` files used to carry their own copy. Consolidating them was only safe
  because of a verified fact worth remembering before editing that header:
  `nvcc` does **not** define `__CUDACC__` when compiling a plain `.cpp`, only
  for `.cu` files. That is what keeps `slime_refine.cpp` — compiled by `nvcc`
  as ordinary C++, never including `cuda_runtime.h` — from ever seeing a macro
  that references `cudaError_t`.
- **`--rank-by like` exists because hard thresholds were throwing away
  near-record spots.** It ranks scan candidates by resemblance to known-good
  spots instead of hard-cutting them on `--eff-target` / `--min-pwin` /
  `--min-winners`. The hypothesis it was built to test — that minimum
  thresholds silently discard the interesting margin — is the same instinct
  behind the triage floor being a discriminator rather than a collector.

### Measure first — two passes where measuring overturned the plan

- **The optimization that was not worth building.** Profiling `--scan` with
  `nsys` showed the GPU already compute-saturated: kernels launch 8,192 blocks
  against the ~20 SMs available, and inter-launch gaps are under 1 ms against
  10–19 ms kernel times. Streams-based overlap had no idle time to fill, so it
  was reported back and not built. Tooling note for repeating this: the default
  `--stats=true` run came back with an empty `cuda_gpu_kern_sum`; explicit
  `--trace=cuda` is what produces real numbers.
- **The optimization that was, once the real cost was found.** Measurement
  killed the obvious plan — slime_refine scoring is nearly free (0.02 s/seed
  with images, a 99-seed file in 1.6 s), so planned delta/overlap scoring work
  was worthless. The actual costs were the CPU `--climb` step at 23.4 s per
  producing spot (~35 % of a pipeline run) and dead spots consuming full hunt
  budgets (22 of 40 spots produced zero in one run). Fixing those two —
  GPU-first climb (`slime_gpu --climb-scan` sweeps the same 8,192 variants in
  0.2 s, 117×, top candidates refined at block precision) and killing hunts
  with zero seeds at 5 s — took an identical 40-spot workload from **585 s to
  216 s (2.7×)** with the same top spots and the same best cq. The lesson the
  tuning table already encodes: optimize productive spots per hour, never cycle
  wall-time.

### Known seeds of the 66.04 record family

Six seeds were recorded as reaching the identical 16,905-block 66.04 layout at
`(3680,6989)`, family `0xFDE0F|0x70802`. Two of them share the same low 48 bits
and differ only in the provably dead top bits (see EXACT SEED DUPLICATES
above), so they are five distinct seeds plus one exact duplicate:

```
-4777481069323147006   -3918692359804081918   -7288100972384540414
 2509326016612608258   -5307967289099343614   -2818884070047012606
```

They are kept here because they make the "66.04 is a hard plateau" claim
checkable: independent seeds, one identical peak layout, and two generations of
`--from-seeds` tightening that raised hit density without ever raising the
ceiling.

## OPTIMIZATION PASS (RTX 4050 laptop, 20 SMs, sm_89)

Five changes, all output-identical to what they replaced. Every one was
verified by the three build.ps1 self-tests PLUS a byte-comparison of real
tool output (`--check` at the record spots, `--score-one`, and for the
scan a full `--range 10000 --z-all` whose emitted commands_*.csv matched
the old build byte-for-byte).

**hotspot_scan.cu**
1. `countAll`: `#pragma unroll 2` -> `4`. The source comment warning against
   this cited 47% occupancy, but `__launch_bounds__(256,6)` pins 6 blocks/SM
   regardless and unroll 4 compiles to the SAME 31 registers. Stale warning.
2. `slimeFromOffset`: modular-inverse divisibility for `% 10`, replacing
   magic-divide + multiply-back + subtract + compare (5 SASS ops) with
   multiply + rotate + compare (3):
       n % 10 == 0  <=>  ROTR32(n * 0xCCCCCCCD, 1) <= 0x19999999
   The rejection guard can only fail for ub in [0x7FFFFFF8, 0x7FFFFFFF] --
   8 values in 2^31 -- so the fast path skips computing `val` entirely.
   NOTE: this was a BACK-PORT. slime_gpu.cu's fastSlimeFromSeed already had
   it; hotspot_scan.cu had simply never been brought along.
   Verified exhaustively over all 2^32 values: 0 mismatches, both the
   divisibility identity and the guard boundary.
3. `countTail` / `countAndBlocksTail`: test the early-exit bound every
   TAIL_BATCH-th cell instead of every cell. The bound c + (n-1-i) is
   NON-INCREASING (c rises by <=1 while n-1-i falls by exactly 1), so once
   below T it stays below -- batching can only DELAY the bail, never miss
   it, and returns -1 on exactly the same seeds. TAIL_BATCH swept:
   2=0.995, 4=0.923, 8=0.888, 16=0.890 s/location. 8 is the knee.

**slime_gpu.cu**
4. `bitKernel` and the fused kernel's phase 1 (same loop, two places): the
   `jBase + c >= side` guard is LOOP-INVARIANT, not data-dependent. Peeled
   the common case (all 32 cells in range) into a branch-free fully-
   unrolled loop; the ragged edge -- at most one word per row -- keeps the
   guarded path.
5. `--enumerate` now scatters index -> seed ON THE DEVICE
   (`genEnumSeedsKernel`, mirroring `genSeedsKernel`), plus `--enum-start`
   and `--enum-progress` for RESUME. Three separate points:
   * The host scatter was a software PDEP: one iteration per free bit (34
     for a 14-bit family) per seed, on ONE CPU thread, then an H2D copy --
     the exact bottleneck genSeedsKernel was written to remove for the
     random hunt, which --enumerate was still paying.
   * RESUME IS LOAD-BEARING. Enumeration restarts at index 0 every run and
     the anchor family is pushed EVERY cycle, so plain --enumerate would
     re-test one identical prefix forever: strictly WORSE than random.
     Checkpoints every 64 batches, not at exit -- the pipeline KILLS the
     process on its timeout, so an exit handler would never run. Overlap on
     resume is harmless; a gap would not be.
   * hunt_pipeline.ps1's push stage now keys a progress file per
     (spot, mask, val) under main\enum\ and resumes each cycle.
   Correctness: device and host scatter enumerate identical seeds --
   40M seeds, both builds, 1761 hits >= 60, record 70, exact match.

MEASURED ON THIS 20-SM LAPTOP -- RE-MEASURE BEFORE TRUSTING ANY OF IT
(see the hardware warning above; a 13-41x swing between GPUs is real):

    scan pass 1        113 -> 154 G cell-evals/s   (+36%, interleaved A/B)
    scan pass 2        1.155 -> 0.888 s/location   (-23%)
    real 10k --z-all   108.4s -> 74.3s             (1.46x, identical output)
    enumerate          4.08M -> 7.03M seeds/s      (+72%)
    enumerate vs random  97.5% of random speed     (was 28%)

A note on projections: `--bench`'s PROJECTED FULL RUN table assumes
`--z-period 97 --z-band 1`. A `--z-all` scan sweeps only the hot lattice
lines and is FAR cheaper -- a real range-50000 --z-all scan took 9.6 min,
against a 36 min projection from that table. Rule of thumb for --z-all:
cost is roughly `--gate-top` x ~1.4s plus a small pass 1.

STILL OPEN, in value order:
- Multi-GPU. There is still no cudaSetDevice or --device flag, so on a
  multi-GPU box every process piles onto GPU 0. This remains the single
  biggest throughput win available on a genuine multi-GPU box, unchanged.
- GPU performance counters were BLOCKED on the laptop (ERR_NVGPUCTRPERM),
  so every finding above came from SASS reading and interleaved A/B timing,
  never from real stall data. On a box where ncu can collect counters,
  profile before optimizing further -- what is left is probably not what
  static inspection would guess.
- The scoring kernels (scoreKernel/scoreHitsKernel/scoreBlocksKernel) sit
  at 47-48 registers under __launch_bounds__(256,5) = 83% occupancy.
  Forcing 6 blocks needs <=42 registers and would likely spill. Untested,
  and they run only on surviving hits, so the payoff is small either way.

### Follow-up: --enumerate now streams too

Enumerate was excluded from the double-buffered streamed path ONLY because
its seeds came from the host. Once genEnumSeedsKernel moved that on-device
the exclusion no longer applied, so beginFusedBatchEnum was added (a twin
of beginFusedBatch differing only in which generator fills the slot, kept
separate so the random path stays bit-identical to what was validated).

Verified: streamed, --no-stream, and the old host-scatter build all return
1761 hits >= 60 / record 70 over the same 40M-seed range.

MEASURED HERE: +0.3% (stddev ~1%), i.e. nothing. That is EXPECTED and is
not a reason to revert. Streaming hides a fixed ~150-200us host round-trip
per batch. On the 188-SM box a 65535-seed batch is ~1.2ms of kernel time,
so that gap is ~13-15% - which is what the 84-87% utilization note in the
source describes. This 20-SM laptop is ~13x slower, so the same batch is
~15ms of kernel and the same gap is ~1.3%. The win is real only where the
kernel is fast. RE-MEASURE on the target box; if it does not show ~10%+
there, the reasoning above is wrong and it can be reverted safely.

### Follow-up: pass 2 - two work-elimination changes (no new heuristics)

Groundwork audit of where a --z-all scan's time actually goes. A real
--range 50000 --gate-top 400 scan spent 498s in pass 2 across 400
locations (1.24s each) and DROPPED ALL 400 - win 0.00 on every one. So
pass 2 is, in practice, entirely the cost of rejecting duds.

Two things were paying for results nobody reads. Neither adds a threshold
or a new signal, and both were verified to leave the ranking inputs and
the emitted commands bit-identical:

1. measure(): the three held-out arms ran together at every escalation
   step, but the verdict cuts on `treatHits < minHits` BEFORE it reads
   lift or sep, and lift/sep are the only consumers of the baseline and
   control arms (the ranking key is 2^(48-b) x scoreRate x pWin, which
   touches neither). Treatment now escalates alone; base and control run
   only if the verdict is actually going to read them. `armsRun` records
   this so a skipped arm prints "NOT RUN" instead of a misleading 0.
   NOTE: this is NOT the removed --min-chunks filter. That gated on the
   frozen max, a noisy order statistic. Nothing is being filtered here.

2. efficiencyProbe(): the floor search paid a FULL --eff-n pass (128M
   seeds) at every step. At --score-t 70 the floor starts at 66 and walks
   to 54 - up to 7 passes, ~900M seeds per location, of which only the
   last one's numbers are kept. A 1/16-size probe now locates the floor
   first; the acceptance rule is unchanged (a floor is still accepted only
   when a full-size pass returns >= MIN_EFF_SAMPLES), so the floor chosen
   and everything derived from it are the same. The probe threshold is
   deliberately permissive - a quarter of the scaled target - so a floor
   that would clear at full size cannot be skipped.

MEASURED (20-location scan, range 2000, score-t 70, rank-by win):
    before  23.5s        after  15.3s        -35%
    ranking inputs: 23/23 rows identical
    emitted commands: 13/13 identical
    (--eff-n 4M for reference: 14.2s, i.e. the probe was ~41% of pass 2)

Where the rest of pass 2 goes, for whoever picks this up: the bootstrap
is cheap (~0.13s; it stops early on "tail too thin"), the arms are ~1.0s
of a 1.57s --check dud, and efficiencyProbe was the other ~41% in scan
mode. --check does NOT run efficiencyProbe unless verdict==2, so timing a
dud with --check understates a real scan's per-location cost - that
mistake was made once here already.

### Follow-up: two more audited, one shipped, two rejected

Continuing the same "is anything computed that nothing reads" audit. The
pipeline is already heavily cost-gated by design (see the "ORDER MATTERS"
and "Guard AFTER the verdict, not before" comments), so most of what looks
wasteful is not. Recording what was tested so it is not re-tried:

REJECTED - skipping measure() entirely under --rank-by win.
  Tempting: the ranking key is 2^(48-b) x scoreRate x pWin, which comes
  from scoreAt and efficiencyProbe, and --emit-top bypasses the verdict
  gates ("emitted (--emit-top, filters bypassed)"). So measure() looks
  display-only. It is NOT: std::sort's PRIMARY key is M.verdict, and
  verdict comes from measure(). Skipping it reorders every row and changes
  which --emit-top spots get emitted. That is a scoring change.

REJECTED - incremental escalation in measure()/scoreAt.
  Both loops re-draw [0,useN) from scratch at each step, so reaching the
  cap costs ~1.33x the cap. rateKernel indexes splitmix64(salt + j) over
  j in [0,N), so offsetting the salt by what was already drawn samples
  exactly [done,useN) and the union is a bit-identical seed set. Built it,
  and output WAS bit-identical (23/23 ranking rows, 13/13 commands). But
  interleaved timing: 29.6s -> 28.9s, -2.3% against a 1.3s stddev, i.e.
  nothing. Two reasons the theoretical 25-31% does not appear: only the
  treatment arm escalates more than one step, and the smaller increments
  launch fewer blocks (blocks = min(8192, N/256)) so they give back in
  occupancy what they save in work. Reverted - complexity with no
  measurable gain is a net loss in a file this heavily validated.

REMOVED - an abandoned optimization in the candidate loop that computed
  `lastTail` from R.D.rounds, commented "-> Skip", and then did nothing
  with it. Finishing it would have been the rejected measure()-skip above.

The lesson for the next pass: this codebase's remaining waste is NOT in
redundant sampling. It is in stages whose *results* are discarded, and
efficiencyProbe's floor search was the last big one of those.

### Bug: --enum-progress silently did nothing under the persistent worker

Caught by running a real record cycle and noticing main\enum\ was untouched
afterwards. The enumerate push had been verified end-to-end BEFORE the repo
sync - but that verification ran against the OLD hunt_pipeline, which spawned
one slime_gpu.exe per push. The newer pipeline routes pushes through the
persistent --worker instead, and the worker tokenizes spot lines on plain
whitespace with no quote handling (its own comment: "never quoted, never
spaced within one value"). hunt_pipeline was passing the progress path
QUOTED, so fopen received a path with literal quote characters, failed, and
the `if (pf)` guard swallowed it. No error, no file, enumeration silently
restarting at 0 every cycle - i.e. the exact replay failure --enum-start
exists to prevent.

Three fixes, because one was not enough:
  1. hunt_pipeline sends an UNQUOTED, project-RELATIVE path (the worker's cwd
     is $root and no path component has spaces).
  2. The worker tokenizer now strips a surrounding pair of double quotes.
     Callers are documented as never quoting; one did anyway.
  3. A failed --enum-progress write now WARNS on stderr instead of being
     swallowed. The silent guard is what turned a one-line bug into a whole
     wasted cycle.

Verified through the worker specifically, not just a direct spawn: the anchor
push printed "resuming enumeration at 142604160" and advanced its file to
251654400, and a new family's file was created in the same run.

LESSON: a feature verified against one execution path is not verified. This
codebase has two (per-spot spawn and persistent worker) and they take
different code to reach slime_gpu. Test the one the pipeline actually uses.

## SEARCH-STRUCTURE STUDY - six theories killed, two survive

Systematic hunt for structure that would let the search target records
instead of sampling for them. Everything below is measured. The headline:
NO SPOT-LEVEL STATISTIC PREDICTS RECORD-HOSTING.

FALSIFIED - do not re-run these:
1. X-position periodicity AT SMALL SCALES. 1459 same-line pairs of cq>=60 spots; |dX|
   divisibility matches chance at every power of two (49.0% vs 50%, 24.5%
   vs 25%, 12.0% vs 12.5%...). Expected: x*x*0x4c1906 overflows int32 and
   scrambles, while z*z stays a clean quadratic. There is no short X lattice.
   BUT: there IS a long period of exactly 65,536 chunks (2^20 blocks). The low 18 bits of
   the chunk-offset DIFFERENCES in a window (what decides which chunks can be slime) repeat when cx moves
   by 2^16 (x^2 term: 2*cx*dx*0x4c1906 has a factor 4 -> 2^16 * 4 = 2^18; x term cancels). The 69,955 hot
   X peaks (x_world.csv) use only 8,702 of the 65,536 residues mod 65,536 (mod 16,384: 8,684 of 16,384 -
   so the period is 65,536, not shorter), and 30% of the sisters (+-k*65,536) of a hot column are hot
   themselves (16x chance; offsets +13 / +1000 / +32768: 0%). (The source study is not shipped in this copy.)
2. 2-adic clustering of cell P values. Mean v2 of pairwise differences over
   the 222-cell mask: records 0.9877/0.9934, dud 0.9802, random lattice
   spots 0.9833 +/- 0.0041. Records sit inside the random distribution.
3. Z residue 48 vs 49. The LEDGER says 11.1% vs 7.8% cq>=60 (p~0.025), and
   both records are on 48. A matched prospective A/B (two 50k scans, 64 Z
   lines each, identical flags) did NOT replicate: pWin>0 was 38.0% vs
   39.6%, max>=65 was 13.2% vs 10.7% (0.96 sigma, p~0.34). The ledger
   correlation was post-hoc on data already mined several ways.
4. Tail-decay as a spot predictor. Hits at T>=40/45/50 over 20M seeds:
   the DOCUMENTED DUD (128304,6976) has a FLATTER tail (31.85x/rung) than
   the 66.21 record spot (37.76x) and more hits at every threshold.
5. best_cq as the family-selection key. Ranking sweep families by best_cq
   picked the WRONG family at every spot tried; 25 such families and 9.68
   BILLION enumerated layouts produced 5 seeds and no improvement.
6. Spot quality generally. Same mask, same 16384 vals, same 400k seeds:
   the dud totalled 341 hits vs 274 and 272 at the two record spots. At
   matched mask/floor/budget (250M seeds) the dud's best family beat the
   66.04 record family 3.8x at floor 60 and 4.0x at floor 65.

SURVIVES:
A. `hits` beats `best_cq` for choosing a family - and the pipeline ALREADY
   does this (the sweep CSV is written hits-descending and hunt_pipeline
   takes -First 1). Both records are the top-by-hits family at their spot
   and NEITHER is top-by-cq. Confirmed by violating it and getting a null.
B. The DERIVATION, not the spot, is the weak link. Across 13 spots the
   derived family is the sweep's top-by-hits 7 times and top-3 ten times -
   but it MISSED AT BOTH RECORD SPOTS. At 40752,5424 it chose 0x4C204,
   rank 40, one bit off the record family 0x4C604. At 3696,6992 it chose a
   family from a DIFFERENT MASK, so no val-sweep there could ever reach
   0x70802. A bad mask is unrecoverable; a bad val is not.

MASK GENERALITY: 0xFDE0F wins 4 of 5 spots and at 40752,5424 BEATS that
spot's own native mask (274 vs 235 hits). Mask-to-mask spread is ~1.2x;
spot-to-spot spread is 3.3x (188 to 622) - and the richest spot in the set
is a 64.35, not a record.

ENUMERATION, PRICED HONESTLY: the dud's best family was enumerated
EXHAUSTIVELY - all 2^34 = 17,179,869,184 layouts in 42.3 min. 152 hits at
70+ chunks collapsing to just 4 DISTINCT patterns (the fixed bits largely
determine the 222-cell window; free bits mostly do not change it). Best
achievable: 63.77 cq. The family is PROVEN to contain no record-beater.
  This does NOT prove the spot is bad: the docs put the RECORD family at
  ~0.80 expected winners, so zero from any single family is the expected
  outcome. What it does show is that `hits` is necessary but NOT
  sufficient - that family had 4x the hit rate and still zero winners,
  because its 70s packed at 92.4% against a 94.4% bar. pWin remains the
  correct final gate, exactly as the existing docs argue.
  It also prices depth-first search: 42 min to retire one family and yield
  4 distinct patterns. The project's original call to deprioritise
  enumeration in favour of breadth-across-families was better founded than
  this session's reversal of it. The --enum-start resume fix still matters
  (replaying one prefix every cycle was a real bug), but "exhaust families
  to find records" is NOT the strategy.

WHAT TO ACTUALLY DO: nothing in the search strategy changes. Rotate
rng-seeds, let the sweep pick families by hits, let pWin gate them, and
run cycles. The one defensible improvement found is (B): consider fixing
the mask to a known-good value instead of deriving it, since the
derivation's mask choice is unrecoverable and it missed at both records.

### Follow-up: two more prospective tests, and climbing measured

7. SPATIAL CLUSTERING - the ledger said good spots sit 1.21x closer than a
   permutation null (p=0.006). PROSPECTIVE test, fixed rng-seed across arms:
   boxes centred on 6 known cq>=64 spots vs boxes on the SAME Z lines shifted
   +400k blocks. Near: max>=65 4.3%, pWin>0 51.9%. Far: 6.6%, 60.2%. The near
   arm did WORSE on every metric. Falsified.
   That is the SECOND ledger correlation to fail a clean prospective test
   (after residue 48). Both looked significant post-hoc. The ledger is biased
   by how it was collected: it clusters because that is where scans looked.
   DO NOT mine families.csv for spatial structure again.

8. CHAINED CLIMBING - a single --climb-scan (bits 24-47) moved two of four
   high-packing seeds by exactly +1 chunk: 67c@95.1% -> 68c@94.4%, and
   65c@95.5% -> 66c@95.4% (a -0.1%/chunk trade, ~8x better than the
   population's ~0.8%/chunk). Chaining climbs from the improved seed - and
   trying bits 12-35 on the stuck 97.1%@66c seed - stalled at ROUND 1 in all
   three chains. Each seed sits at a local optimum; the one favourable step
   was the neighbourhood's best move, not a repeatable direction. Climbing is
   what its own comment says: local polish, not a way up the count axis.
   Note the collapse again: all 30 climb variants of the 97.1% seed were the
   IDENTICAL layout - high bits largely do not touch the 222-cell window.

MASK ROTATION (0xFDE0F -> 0xEF70F -> 0xFF03F, one per cycle, cycles
#387-#389): no mask separated; all three reported the standing 65.06.
hunt_pipeline.ps1 -ForceMask now NEVER applies to the anchor - forcing a
foreign mask onto it silently re-masks its val (0x70802 & 0xEF70F = 0x60002)
into a meaningless family. record_cycle.ps1 passes -ForceMask through, and
the family sweep now takes a rotating --rng-seed, because with a fixed mask
the sweep is otherwise deterministic per spot and would re-pick the same val
forever.

CONCLUSION OF THE STUDY: every test aimed at finding WHERE records are
(geometry, residues, spot statistics, clustering) came back null, and the
one aimed at MAKING a record from a near-miss (climbing) reaches a local
optimum in one step. The search is a rate problem. The remaining levers are
throughput and cycles; there is no structural shortcut in anything tested.

### Triage -ForceMask, never-run-twice, auto-masks, hardware profiles

The "best 65.06 every cycle" was a REPORTING bug, not a stuck search: the
ledger emits a Seeds=0 row for every already-mined family it skips, carrying
that family's HISTORICAL best, and record_cycle took the max over all rows.
52 of 57 rows in one cycle were stale; the real new-find best was 60.14.
record_cycle now computes both "best" and "best-elsewhere" from Seeds>0 rows.

-ForceMask previously applied only at the sweep and the push. TRIAGE still
hunted the DERIVED family, and the push gate (-PushMinCQ) read that triage
score - so the derivation still decided which spots the forced mask ever saw.
Now a light family sweep (-TriageSweepSeeds, default 50000) under the forced
mask picks the val at triage, and the push keeps that val.

NEVER RUN A FAMILY TWICE: any (mask,val) in a prior run's ledger is skipped
outright, and two spots in one run cannot pick the same family (the key has no
spot in it). This REPLACES the old rule, which only skipped at Times >= 2 and
reset an improving family to Times=1 so it kept being re-hunted - a deliberate
depth-over-breadth choice, reversed on purpose.

-AutoMask: a mask never used by any run, every cycle, recorded in
main\masks_used.txt BEFORE the hunt. Bits 0, 1, 12 kept (selected 15/15 in real
derivations); the other 11 drawn from the 20-bit window.

MEASURED, same 10k range, same laptop:
                        old triage (4 cycles)    -AutoMask (1 cycle)
  spots triaged/cycle            35                       92
  new finds/cycle                 5                       17
  skipped as mined            60 (64%)                  0 (0%)
The 10k window "ran dry" in three cycles under the old triage (skips 42% ->
86%), but it was never short of SPOTS - it was re-deriving FAMILIES the ledger
had already seen. With a never-used mask every family is new by construction.

HARDWARE PROFILES (-Profile auto|laptop|rental): auto picks rental on >=40 GB
VRAM or a PRO 6000/H100/A100-class name. rental: gate-top 600, seconds 4, push
8 x 15s (the docs' own values, calibrated there). laptop: gate-top 220 (this
file's previously measured sweet spot; pass 2 is ~6.6x slower here), seconds 6
(~42M seeds, near the original 48M triage calibration), push 6 x 12s. Explicit
parameters always override. The RENTAL branch is untested - re-bench there.

### -MaxDist now covers the scan's square; a half-run radius test

CORNER LOSS FIXED. The scan window is a SQUARE (+-Range per axis) but -MaxDist
was a true-distance CIRCLE, so every spot in the square's corners was scanned,
ranked and paid for, then discarded before triage. Geometric share 1 - pi/4 =
21.5%; measured at 10k: 28 of 120 (23%). record_cycle now passes
-MaxDist = Range * sqrt(2). Trade: -Range 10000 means spots up to ~14,142 blocks
out, not a strict 10k circle. Verified: 0 spots past -MaxDist, 120 triaged.
  OPEN QUESTION: in the one comparison available (different masks, one cycle
  each), the 28 recovered corner spots added ~142s of triage and ZERO extra new
  finds (17 vs 17). By theory they should be as productive as any other spot
  (variance is flat with distance), so this is probably noise - but if it
  repeats, a strict circle is the better -MaxDist and this change was a trade
  in the wrong direction.

RADIUS A/B, HALF DONE. Same fresh mask (0xD57E7) and same scan rng-seed
(918273645) for both arms, each started from an IDENTICAL ledger snapshot so
neither is barred from the other's families. Arm A (10k) completed as cycle
#395: 120 triaged, 17 new finds, 3 at cq>=60, best 64.76 at (3690,6986),
616s = 36.2s per new find. Arm B (50k) was stopped by request during its scan
and wrote nothing. Its snapshots remain in main\theory\ to resume. Arm A's 120
families were merged back into the live ledger afterwards.

TWO TOOLING LESSONS FROM RUNNING THESE:
- A process filter matching on command-line text WILL match its own shell
  (the query process's command line contains the pattern). It killed itself
  twice, and "1 script still running" was the query process every time.
  stop_all.ps1 excludes $PID correctly; ad-hoc checks must do the same.
- Inserting a line before a backtick-continued command splits it. PowerShell
  still PARSES it, and the call silently runs with default arguments. Parse-
  clean is not proof of correctness - check the call's structure.

Use record_cycle.ps1 -AutoMask to pick masks. The older approach - rotating a
fixed newmasks.txt list - is OBSOLETE: several of those masks are now spent.

UPDATE: arm B (50k) was later completed as cycle #396, same mask and rng as A,
from the post-A snapshot. 50k vs 10k: 24 vs 17 new finds, 7 vs 3 at cq>=60,
27.5 vs 36.2 s per find, 21.8 vs 16.6 finds per 10 min. About 1.1-1.3 sigma:
a lean toward 50k, not proof. 19 families ran in both arms (known exception).

### -ReuseScan, and Lines

-ReuseScan: scan once per -Repeat run and hunt the same spot list every cycle.
The scan ranks LOCATIONS; cycles with different rng seeds shared 64-91% of their
120 spots, and on the laptop the scan is ~125s of a ~650s 50k cycle (pass 2
117s at gate-top 220). -AutoMask makes each cycle's families new anyway, so the
rescan bought almost nothing. Ignored without -AutoMask/-ForceMask.

LINES. --z-all already scans only the hot lattice (blockZ 1552k+768/784), and
the ledger split by line index k shows effort AND quality are concentrated:
  k   Z      families  productive  >=62   >=63   best
  3   5432      573       26.9%     1.2%   0.5%  66.21
  4   6984      829       28.2%     2.2%   0.6%  66.04
  5   8536      428       25.5%     2.8%   1.6%  64.35
 -6  -8536      358       27.1%     0.8%   0.6%  65.06
  0    776      206       18.9%     0.5%   0.5%  63.13
  all lines other than 3/4/5 together: 930 families, 6 at >=62 (0.65%)
Lines 3/4/5: 37 of 1830 families >= 62 (2.0%). A 50k --z-all scan emitted 106 of
120 spots on 3/4/5 (77 on line 4). -Lines 3,4,5 -RangeX N scans only those lines,
each over CenterX +/- N, with an EQUAL share of -GateTop/-Top per line (pass 2
over-picks line 4; line 5 has the better tail), interleaved best-first.
-MaxDist in line mode = distance to the strip's far corner.
Caveats: the per-line rates are from UNEQUAL effort, and line -6 holds the #3
spot (65.06), so a 4th line is defensible. Lines past |Z| 50k were never
scanned at all - a better line may exist farther out (see next).

NEXT (not built): a per-line survey. Pass 1 variance for every lattice line out
to some |Z|, over a fixed X sample, printed as per-line quantiles. Validate it
first: it must rank 3/4/5 above 0/-1/-2 as the ledger does. Only then trust it
to pick far lines.

### THE LINE / X / HEAT MODEL - how spot quality actually works

Built from an exact CPU re-implementation of Java's isSlimeChunk (validated: the
two record seeds give 65 and 67 slime chunks in the r=8 disc vs ~20 by chance;
far-line GPU finds re-checked the same way, 54-64 vs ~20). Everything below is
seed-free: it measures a LOCATION against random seeds.

1. THE Z LATTICE WAS WRONG. Hot rows sit at chunk Z = 48.5 + 96.875 n (period
   1550 blocks), not "mod 97 in {48,49}" (1552). Fitted by row-coherence peaks
   out to Z = 30M (within 1-2 rows at n = 19300). The 97 form drifts 2 blocks
   per line: fine near spawn (both records are within 5 lines), 2 chunks off by
   Z = +-25k, past the band by +-50k. Fixed in hotspot_scan --z-all (3 rows per
   line) and record_cycle -Lines. This is why scans kept landing on lines 3/4/5.
   The Java int-overflow in the Z terms plays no part: z*389711 first wraps at
   |Z| ~ 88k blocks and z*z at ~741k, and a wrap only breaks the one window that
   straddles it.

2. LINES DIFFER (G(Z)). Row-coherence (variance of the slime count in a 17-row
   column / binomial) for all 38,701 lines inside the border: median 1.160,
   p99 1.213, max 1.290 (n = 12656, Z ~ 19.6M). Line 4 (the record line) = 1.213,
   rank 251. Top values re-measured at 13x the samples: all within 0.006.
   Line strength has periodic structure in n (periodogram peaks at ~21, 10.5,
   5 lines). Files: scratchpad lines\survey.csv / remeasured.csv (copy into
   main\theory\ if kept).
   REAL-HUNT CHECK (same settings, AutoMask, 40 spots/line, X +-100k):
     lines 3/4/5 old rows #398/#399     26-30% of spots productive
     lines 3/4/5 corrected rows #401    27% (>=60: 13; best 66.13 via climb)
     top-3 surveyed lines #400          58%, 26 spots >= 60 cq (vs 6-14)
   So the line effect is real and is not the row fix (#401 had the fix too).

3. X IS UNIVERSAL (F(X)). The spot-strength profile along X is the same on every
   line (correlation 0.996 line 4 vs line 12656, 0.993 vs line 0), because the X
   and Z terms are additive and independent. X ripples with quasi-period ~33
   chunks (autocorr 0.979 at lag 33). No trend with distance from X = 0: top-10%
   / max disc strength is flat from |X| < 330 blocks out to 29M, and the ledger's
   productive / >=62 rates are flat across X bands 0-100k. One X survey ranks
   every column for every line: hotspot_scan --pass1-out on a single row.

4. HEAT = F(X) x G(Z). P(>= 45 of 197 disc chunks | random seed), relative to a
   median lattice spot, factorises: top-vs-median X is ~10-13x at >=40 on every
   line; best-vs-median line ~3x at >=45 (~9x vs worst). Best x best vs median x
   median ~40x at >=45, and the ratio GROWS with the threshold. Records on this
   scale: 66.04 spot heat45 ~21, 66.21 spot ~14, 65.06 ~8; best line x best X in
   +-100k ~43. The scan's own selection already puts hunted spots in the top ~4%
   of X; within them, X rank still moves productive 27% -> 39% and >=62 1.8% ->
   3.1%.

NEW TOOLING: hotspot_scan --pass1-out FILE (pass-1 ranking, skips pass 2);
record_cycle -Spots FILE.csv (X,Z) hunts an explicit list, needs -AutoMask;
-Lines k1,k2 uses the corrected rows; -ReuseScan scans once per run.

THE DECISIVE TEST (cycle #402). One cycle, one fresh mask (0x67FB3),
120 spots interleaved: 60 HOT (top world X peaks x top lines, heat45 26-50) and
60 COLD (random X anywhere x random line: a typical lattice spot, heat45 ~0.7).
                  productive  >=58  >=60  >=62  >=63   best
    hot  (60)        82%       41    25    12     9    67.24
    cold (60)         3%        1     0     0     0    58.26
For scale, a normal 120-spot scan cycle yields 26-30% productive and 1-2 at >=63.
Heat moves the RECORD TAIL, not just productivity. It also produced 66.07 at
(-9296837,-26288804), 64.66, 64.43, 64.35, 64.05, 63.93, 63.61, 63.51.

67.24 cq at (-22078158,15423280), seed 4508542591492402376, 72 chunks @ 93.4%,
line 9950, reached by the climb (65.42 -> 67.24). Independently checked with the
exact model: 74 slime chunks in the r=9 disc (both old records: 73), 13 with the
same seed 3000 blocks away. HIGHEST MODEL cq EVER; not yet measured in game.

SEED-INDEPENDENCE: heat is a property of the LOCATION averaged over all seeds,
so the line survey and X survey never need recomputing - they are stored in
main\theory\heat\ (line_survey.csv, line_remeasured.csv, xsurvey_world.csv).

TOOLS (heat\ - NOT shipped in this copy, described for context only): SlimeModel.cs (exact Java isSlimeChunk + survey/heat statistics,
C#, loaded with Add-Type; no build step), heat_spots.ps1 (hottest never-hunted
spots -> main\heat_spots.csv), heat_of.ps1 (heat of any spot), heat_ledger.ps1
(heat of every hunted spot vs its real outcome). record_cycle -Heat wired
heat_spots into a cycle - RETIRED (heat_spots.ps1 and record_odds.ps1 moved to heat\old;
-Heat prints a pointer to -PhaseSearch). Reference heat40 values: median lattice spot 1, 66.21
spot ~10, 66.04 spot ~16, hottest spots in the world ~24-26.

OPEN: the Z-line periodicity (~21 lines) and the X ripple (~33 chunks) are
measured, not derived. A closed form would let heat be computed without the
surveys, but the surveys are cheap and final, so it is not needed to use this.

LEDGER VALIDATION (script and data not shipped in this copy).
Heat of every spot ever hunted vs its real outcome. The independent part is the
PRE-HEAT ledger - 3240 families from the old scans (|X|,|Z| <= 100k), outcomes
the model never saw - split into heat40 quintiles, per family:
    heat40      productive   >=60    >=62    >=64
    2.9-6.5        16.4%     4.6%    1.1%    0.0%
    6.5-7.6        22.7%     5.9%    0.9%    0.2%
    7.6-8.7        22.8%     5.4%    0.9%    0.5%
    8.7-10.3       29.8%     8.0%    2.2%    1.1%
    10.3-20.4      38.1%    13.9%    4.0%    1.2%
The old top farms sat at heat40 7.6-10.1 (upper-middle of what the square scan
reached); heat-mode spots are 20-26. The 67.24 spot: heat40 20.6, heat45 32.8.

### FILE LAYOUT AND HOUSEKEEPING

Built so a flood of new records does not bury anything:
  main\records\index.csv     one row per 64+ result (Date,CQ,Eff,Chunks,Blocks,Seed,
                             X,Z,Family,SpotX,SpotZ,Run,File) - sort/filter this
  main\records\66\ 67\ 68\ 69\ 70\   <cq>_<seed>.txt + .png, tier = floor(cq); over66_images\ gallery; over66_y-39\ raised-AFK folder; perimeter\ on-request setups
  main\records\RECORD.*      only results VERIFIED IN GAME (filed by hand)
  main\logs\scans\           scan logs (were loose in main\)
  main\logs\runs\            run / experiment logs
  main\theory\heat\          surveys + heat_cache.csv (seed-independent, never stale)
slime_refine --no-logs: batch scoring writes only its --csv; the per-seed .txt
files were 62k+ in main\scores. hunt_pipeline removes the main\work files its own
run wrote, and empty score folders. tidy.ps1 (asks first) deletes the old
regenerable clutter: main\scores, main\work older than a day, main\seeds older
than 30 days. It never touches the ledger, cycles.txt, records or theory.

-Heat rebuilds its list EVERY cycle and never repeats a farm: a candidate is
skipped if a hunted spot sits within 2 chunk rows and 4 chunks X of it, and
candidates are de-duplicated against each other the same way. Each cycle prints
its heat range. Heat falls gradually (rank 1 ~26-28, rank 100 ~17, rank 200 ~14),
so there is no single super-spot - breadth over the top few hundred is right.

NOTED, NOT BUILT: a stop rule. As hunting uses up the hottest spots the remaining
heat falls, and at some point a record becomes too unlikely to be worth the time.
-MinHeat exists but is OFF (0) until enough (heat, best cq) data exists to
extrapolate a cutoff. Known so far: every 66+ came from heat40 >= 7.6.

### RECORD ODDS - when to stop (heat\record_odds.ps1)

One number that ties heat to cq: the chance that ONE family hunted at a spot of
heat h beats the record. Fitted on the whole ledger (every family's best cq vs its
spot's heat40) as an exponential tail that scales with heat:
    P(best cq >= t | heat h) = exp(a + b*ln h - c*(t - 60))
First fit (3450 families, 1974 spots): a -7.50, b 2.31, c 0.73 - each extra cq point
2.1x rarer, doubling heat multiplies every tail ~5x. Observed vs fitted families at
>=61..66: 175/172, 79/83, 37/40, 26/19, 6/9, 5/4.5. Chance of beating 67.24 per
family: heat 25 ~1 in 210, heat 20 ~1 in 350, heat 10 ~1 in 1750, heat 5 ~1 in 8700.
Every -Heat cycle sums it over its spot list and appends to main\logs\record_odds.csv
(expected records this cycle, "1 in N cycles"). The list cools as it is used up, so N
climbs; stop when N is more cycles than the hunt is worth. CAVEATS: beating the record
is an extrapolation one step past the data; the fit ignores per-spot ceilings (masks at
one spot converge on the same best - see (28720,6976): 64.56/64.54/64.54/64.54), so it
is optimistic in absolute terms. Use the TREND across cycles more than the level. The
fit refits every cycle, so it self-corrects as data accumulates.

WHY BREADTH, NOT ONE SPOT WITH MANY MASKS: every family is a slice of the same 2^48
seeds at the same chunk geometry, so a spot has one best-possible farm and more masks
only re-find farms at or below it. Ledger spots with 4-6 productive families cluster
within ~0.1-0.3 cq of each other. New spots are new ceilings, and heat falls gradually.

### CLIMBS - what actually turns a good seed into a record

All three 66+ farms of the heat era came out of the climb (a sweep of a seed's high
bits, which stay inside its family): 64.16 -> 66.13, 65.42 -> 67.24, 63.95 -> 66.07.
Measured on this laptop, on the 5 best seeds of heat cycle #404:
    standard climb (bits 24-47, 16.7M variants)   ~5 s    0 of 5 improved again
    repeating it from its own result              ~5 s    0 of 5
    DEEP climb (bits 20-47, 268M variants)        90-200 s  3 of 5: 65.55 -> 66.31,
                                                           64.71 -> 65.05, 64.00 -> 64.44
The standard climb adds at most ~2.1 cq, so a seed well below ~65 cannot reach the
record through it - lowering -ClimbMinCQ would add 64s to the archive, not records.
hunt_pipeline now: standard climb at -ClimbMinCQ 63 with --climb-top 20 (was 5; the
top GPU variants are usually exact ties, so refine got one real candidate), DEEP climb
at -DeepClimbMinCQ 65.0 (~1 seed per heat cycle), and both on PUSH results too - push
seeds were never climbed, so in cycle #404 all 5 pushes lost to the triage best.

WHERE A HEAT CYCLE'S TIME GOES (laptop, cycle #404, 767 s / 120 spots): triage hunts
~80% (6 s per productive spot, ~3 s per dead one via --give-up-after), per-spot
forced-mask family sweeps ~15% (1.07 s each, of which 0.8 s is the kernel - so
batching the sweeps into one process would save only ~30 s/cycle; not done), climbs
and pushes the rest. The GPU is already on the core work most of the time; the big
remaining multiplier is hardware (~7M seeds/s here vs ~55M measured on the PRO 6000).
Heat-list scoring used to stall the first cycle ~2.5 min on CPU; the cache is now
pre-filled with a 7000-spot pool (120 X peaks x 60 lines, 300k seeds each).
RANKING CHECK: heat45 (P>=45) vs heat40 as the spot ranking, on the ledger - same
share of 63+/64+ in the top fifth (4.1% / 3.0% vs 4.1% / 2.8%). Kept heat40 (less
sampling noise), heat45 breaks ties.

RE-CLIMB OF THE BEST SEEDS (reclimb_top.ps1): the six best spots' seeds
(67.24, 66.21, 66.13, 66.07, 66.04, 64.94) got the deep climb - 0 of 6 improved. The
best farms already sit at their local peak, so re-climbing them is not a route to a
record; the route is a raw find of ~65+ that the climbs then lift (standard up to
~+2.1, deep up to ~+0.8 so far). Deep climbs cost ~63 s here (a full 268M-variant
sweep, verified), not the 90-200 s first measured. main\records\deep_climbed.csv logs
every deep climb's coverage (spot + low 20 bits); reclimb_top.ps1 skips covered seeds.
CLIMB TIES ARE HARMLESS (tested): the top-20 GPU list is usually 20 exact ties, but
asking for the top 200 and refining one seed per DISTINCT layout (5-15 of them) never
beat GPU rank 1 in 4 of 4 seeds (64.00, 66.24, 64.94, 67.24 all stayed rank 1 after
block-precision refine). No change needed.
HEAT POOL WIDENED (heat_spots default 120 X x 60 lines, was 40 x 20): after two
cycles had worked the narrow pool down to heat ~17, the wide pool still held
never-hunted spots at heat 21.7-31.1 (record odds 1 in 2 cycles vs 1 in 5).

EMPTY HOT SPOTS GET RETRIES (heat_spots -MaxTries 3). Cycle #407 hunted the 15 hottest
spots in the world (heat 26-31): best 64.35, most 57-62, and 5 of 15 produced NOTHING,
while that cycle's 66.78 and 66.56 came from spots at heat ~20-25. One hunt tries one
family, so "nothing" is a dead family, not a dead spot. A spot is now finished only when
it has produced a farm (masks converge on its ceiling) or had 3 masks; the list's Tries
column counts earlier empty attempts. The next list after #407 held 50 retries of 120.

66+ LOG. main\records\over66.csv: one row per farm at 66+ (seed, AFK X/Z, chunks,
packing, spot heat40, hot line, family, run), and each gets <cq>_<seed>_perimeter.txt
(perimeter_setup output) beside its record. Written by hunt_pipeline's Log-Over66 from
ArchiveResult; backfilled with the 12 farms found up to that point.

HOW DEEP TO HUNT (record_odds fit after #408: a -7.22, b 2.11, c 0.63). Beating 68.28,
per 120-spot cycle: heat 18-22 ~21%, 16-18 ~17%, 14-16 ~13%, 12-14 ~10%, 10-12 ~7%,
<10 ~4%. The fit matches observed counts through >=66 (12 vs 10.9) but over-predicts
above it (>=67: 2 observed vs ~6; >=68: 1 vs ~3), so divide by ~3 for a realistic
figure. Recommendation on the laptop: hunt down to heat ~14 (~18 cycles), stop below
~12 (<3%/cycle, ~7 h per expected record). A PRO 6000 (~8x) makes the lower bands worth it.

### WHAT EACH PART OF THE SEED DOES AT A SPOT (tested, exact model)

1. Z LINES ARE UNIVERSAL. Line strength measured separately for 24 seed families (low 20
   bits fixed): ranking agreement between different families r = 0.988, identical to two
   replicates of one family; per-line spread = sampling noise. With the low 35 bits fixed a
   small wobble appears (r 0.978 vs 0.987, SD up to ~0.015) - tiny next to the 1.08-1.29
   range between lines. Strongest line: 12656 or -14404 for every family.
2. BITS 0-19 (THE FAMILY) SET EACH CHUNK'S SLIME RATE AT THE SPOT. Mean disc count (197
   chunks) for random families at a strong X: 12.0 to 27.2 (typical 19.7). Every record
   seed's 20-bit family is in the top 0.1-3.7% of families at its spot (68.28: 27.9).
3. BITS 20-34 (THE CLASS) SET HOW THE CHUNKS MOVE TOGETHER. Inside the 68.28's family,
   200 fully-enumerated classes all average exactly 28.00 (SD 0.001), but seeds >=45 per
   class range 0 to 1638 of 8192 (SD 463 vs 19 by chance). The mean cannot find good
   classes; the tail can.
4. BITS 35-47 are the last lottery: 8192 values per class, small enough to enumerate.

TAIL-SCREENING (proposed hunt stage, not built): inside the chosen family, screen 6000
classes x 64 seeds by dense hits (>=45), enumerate the top 60 fully. Same seed budget vs
random sampling of the family (what the hunt does now):
    family of    >=50    >=55    >=58    >=60
    68.28        3.6x    4.9x    4.6x    4.3x
    67.32        4.9x   11.9x   21.7x   29.5x
    66.04        5.3x    8.4x   11.6x   21.6x
The gain grows with the threshold. Needs a GPU kernel mode (class screen + class
enumerate) and pipeline wiring - plan before building.
Also measured: choosing the best 20-bit family is already 30-100x over uniform random
seeds (what the family sweep buys). An earlier "screen by mean" version showed 2-5x only
by accident: ranking on a noisy mean favours high-variance classes.

HEAT POOL: 28,861 spots cached (240 X peaks x 120 lines, 300k seeds each). The top 120
did not change (heat 31.1 .. 21.7) - the wider pool adds depth at heat 15-20.

### Families, the enumerate bug, and where the hunt should cut off

EXACT FAMILY MEANS (heat\SlimeModel.cs FamilyMeans and its g20.bin - not shipped). A chunk can
only be slime when Java's roll is even, and that bit depends ONLY on the low 18 bits of
(seed + chunk offset); the offset's low 20 bits are a plain polynomial (int overflow vanishes
mod 2^20). So a 20-bit family's mean slime count at a spot = sum over the 222 spawn cells of
g((f + o) mod 2^20) - all 1,048,576 families in ~0.05 s, predicted vs sampled RMS 0.06.
BUT the mean does not find record families: at the 68.28 spot, families ranked 1-30 by mean
held no 70+ layout at all; the record's own family (rank 94) held 14. heat\family_spots.ps1
and record_cycle -Families rank by mean - EXPERIMENTAL, not recommended.

RICH FAMILIES. At a record spot the record's 20-bit family had 29k-47k hits >=64 in 20M seeds
while 48 other top families had ~0 (68.28, 67.32, 67.24, 67.22 spots). Rich families are rare,
spot-specific (the "possible chunks" pattern repeats every 1,048,576 blocks in X / 2,097,152 in
Z, but richness does not), and triage FINDS them: at 6 spots, 71-100% of triage's seeds came
from one 20-bit family.

ENUMERATE BUG, FIXED (slime_gpu.cu). --enumerate reported every hit as seed 0 (hits read a host
array the GPU enum generator never filled) - so every enumerated PUSH scored nothing real, which
is why pushes "never improved". Now recomputed from the enumeration index (enumSeedAt __host__).
Verified: exhausting the 68.28's family (2^28 seeds, 37 s) re-finds 68.28 (equivalent seed
1176004845688) plus 67.28, 67.28, 66.73, 66.56 at that spot - and proves nothing beats it there.
EMPTY-CYCLE BUG, FIXED (hunt_pipeline.ps1): when no spot produced a seed the pipeline exited
without saving the ledger or pipeline.csv, so dead families were re-hunted and the cycle line
repeated the previous cycle's best (#412 corrected by hand).

RICH-FAMILY EXHAUST (hunt_pipeline -RichTop etc.): walk all 2^28 seeds of the family the
triage hits came from. Measured on 6 spots (#414): matched triage's best 4x, +0.52 / +0.24 2x,
+35% cycle time. Triage usually already finds its family's best, so it now runs only when
triage reached 66+ (-RichMinCQ 66): cheap near-record insurance. The old push is off while
this stage is on.

DEEP ALL-FAMILY SWEEP (heat\deep_spots.ps1) - NEGATIVE, do not use as is. Sweeping all
1,048,576 families at a spot then exhausting the best: 20 hot spots (heat ~19) -> one 70+
family (61.88). The sweep kernel scores ONE position (the spot centre) while farms sit anywhere
in the 24-chunk hunt window: the 66.63 spot's family (140 layouts >= 70) got 1 sweep hit. It
only looked perfect at the 68.28 spot because that farm sits at the centre.

WHERE TO CUT OFF (all hunted spots, heat vs best farm):
    heat     spots   66+/spot   best
    20-25     297     2.0%      68.28
    17-20     545     1.5%      67.32
    14-17     152     0.66%     66.24
    10-14     361     0.28%     66.21
    7-10      878     0.23%     66.13
    <7        581     0         63.49
Every 67+ came from heat >= 19.4. Laptop cutoff: heat 17 (record_cycle -MinHeat 17 stops the
run there; ~1,770 never-hunted spots above it at the time). A PRO 6000 justifies ~14.
POOL FIX: heat_spots default pool widened to 240 x 120 (was 120 x 60) - the narrow pool was
offering heat ~18 while 357 never-hunted cached spots were at 20+. PowerShell trap #3 of the
day: a [string]$Lines parameter aliased the pool's $lines variable (case-insensitive) and cycle
#417 hunted 120 junk spots at Z=0; the filter is now -OnlyLines.

### The windowed family sweep, re-measured X and Z, and the best-family search

WINDOWED FAMILY SWEEP (hotspot_scan --family-sweep --sweep-rx R --sweep-rz R, max 4). The old
sweep scored each family at the spot CENTRE only; farms sit 0-3 chunks away. The windowed
kernel (familySweepWinKernel) evaluates the (17+2Rz) x (17+2Rx) union window once per seed,
packs rows into bitmasks and popcounts every AFK position against the spawn mask, so all
(2Rx+1)(2Rz+1) positions cost one pass; a seed is a hit when the BEST position reaches the
floor. Self-test [6]: 0x0 window == the old kernel exactly; 3x2 window == a CPU loop over all
35 positions (slime_core.h scoreCenterChunks/Blocks), hits and best (blocks, position) exact.
Windowed CSVs add best_dx,best_dz. Cost ~3x the centre sweep: all 1,048,576 20-bit families x
50k seeds = ~151 s per spot on the laptop. From the spot CENTRE (floor 64, 3x2):
    68.28 spot: record family 0x9E078 rank #1 of 1,048,576 (24 hits, next 10)
    66.63 spot: 0xA2CEC rank #1 (17 hits, next 7)   - the centre sweep had it at 1 hit, rank 5
    66.84 spot: 0x95DE3 rank #3 (2 hits); the 2M-seed confirm then puts it #1 (2063)

BEST-FAMILY SEARCH (heat\best_family.ps1; record_cycle -BestFamily). Per spot: windowed sweep
of every family -> confirm top 8 (slime_gpu, 2M seeds, 24-chunk window, floor 64) -> exhaust
(--enumerate, all 2^28 seeds) the top 2 plus any other family confirmed at >= 700 hits (max 4)
-> archive 66+, ledger 0xFFFFF|val@x,z. Resumable (spots in best_family.csv are skipped). A
timed-out exhaust is not ledgered. Test, 23 spots (3 record spots + the 20 of the failed deep
test), ~4 min/spot:
    the 20 deep-test spots: old method 1 spot with a 70-chunk layout (61.88); new 8 (best 66.17)
    new 66+ farms: 67.28, 66.73, 66.56 (68.28 family), 66.61 (66.63 spot, 2nd family), 66.17
    best family's sweep hits >= 10: 6 spots, 4 with a 66+ farm; < 10: 16 spots, 0 (best 63.36)
  -> DEAD-SPOT rule (-DeadTop1 5): best family < 5 sweep hits and nothing confirmed at 700 ->
     no exhaust. Confirm hits are a pointer, not a guarantee: families at 484, 610, 833 and
     1042 confirm hits had no 70-chunk layout at all; 1421-2137 gave 66.17-66.84, 4981 68.28.
  Heat alone does not find rich families: most heat-19 spots have none. The sweep does.

TRIAGE (hunt_pipeline -TriageRx 3 -TriageRz 2, default on): the -Heat cycle's per-spot 14-bit
family pick now uses the windowed sweep. Paired test, 30 spots
(main\theory\heat\triage_window_test.csv): picks differed at 22; windowed family better at 9,
centre at 6; spots whose pick had any 64+ layout 18 vs 14. Weak, one-sided, ~1.5 s/spot.

Z LINES PINNED (heat\line_rescore.ps1 -> line_rescore.csv: top 60 lines x 40 X at 2M seeds;
heat\factor_fit.ps1 -> z_values.csv / x_values.csv: Poisson product fit of all 29k cached heats,
chi2/measurement 1.93 - the product model holds up to a modest interaction). The two agree at
r = 0.981. Line 10617 (Z 16,457,126) 20.0, then -14404 17.9, 9950 17.3, 12987 17.0, 12656 17.0,
17161 16.7, -1253 16.7; ranks 2-15 are within 15.5-17.9. PowerShell trap #4: $h in a scriptblock
overwrote $H (the output folder) and the first 15-minute run wrote nothing; raw values now saved
first (line_rescore_spots.csv).

X COLUMNS RE-MEASURED (heat\x_rescore.ps1 -> x_rescore.csv; -ConfirmTop 600 -> x_confirm.csv).
The survey's pass-1 variance barely predicts real X value (r = 0.16 inside its top 240). All
15,405 distinct survey peaks measured on line 10617 at 300k seeds (31 min CPU), top 600 again at
2M (winner's-curse shrink only 5%, r = 0.73). The true top 240 sit at survey ranks up to 15,000
(median 3,702; 184 beyond rank 1,000). Leaders: X -15,087,408 (32.3, survey rank 12,893),
11,288,224 (32.2), -8,784,976 (31.4), 16,054,704 (31.1), 27,540,976 (30.8). 349 peaks >= 22.
Hot X columns probably also exist beyond the survey's 20,000 columns (rank 10k-20k still has
peaks at 30+) - a wider X survey is the next cheap win.

SPOT LIST (heat\best_spots.ps1 -> main\best_spots.csv): predicted heat = X value x line value /
line 10617 value, hottest first, skipping spots done by best_family. Top of list 32.3 (the old
pool peaked ~31); 44 of the top 500 had ever been hunted. heat_spots.ps1 (-Heat) now also orders
X by measured value.

HOUSEKEEPING: ArchiveResult files one row and one set of files per FARM: a result with the same cq and an AFK
point within 8 blocks of an indexed farm is a copy (the 48-bit form of a hunted seed, or another of the phase
search's up-to-3 seeds per layout - the AFK point shifts a few blocks with chunks outside the searched window).
The check runs BEFORE filing (it used to move the files first, leaving 12 copies' files in
the tier folders with no row; those + 8 near-copies moved to main\archive\duplicates). phase_spots
archives each spot's 10 best DISTINCT 66+ farms. over66.csv Heat40 = the spot's measured heat (spot_top.csv).

RUN: powershell -ExecutionPolicy Bypass -File record_cycle.ps1 -BestFamily -Repeat 100
(-Families now runs this too: mean-ranked families missed the record families.)

SCAN HISTORY RESET (on request). The ledger (main\families.csv, 4,704 families),
cycles.txt (417 cycles), masks_used.txt, best_family.csv, the spot lists and the raw per-spot
output (main\seeds, main\commands, main\scores) were MOVED to main\archive\scan_history
- restore by moving them back. Every location is huntable again. KEPT: main\records (every 64+
farm, index.csv, over66.csv) and all measurements (heat cache, X / line values, g20.bin).
record_cycle's record-to-beat now also reads records\index.csv (68.28), so an empty ledger does
not turn a 66.5 into a "new record". stop_all.ps1 now also stops best_family / deep_spots runs.

PREP FOR THE BEST-FAMILY RUN:
- NEGATIVE: the exact family structure does not screen spots. SpotFamilyStats (best family
  mean, top-10 mean, most possible chunks) on the 24 swept spots (main\theory\heat\screen_test.csv)
  shows no relation to the best family's sweep hits - the 68.28 spot is near the bottom on all
  three. Richness is a joint (co-movement) property; only the sweep sees it.
- familySweepWinKernel early exit (exact: stops reading rows once no position can reach the
  floor): 151 s -> 141 s per 20-bit spot sweep, output byte-identical (66.63 spot re-run).
- Window checked: 7 of 24 best families peaked on the window edge, where 20 of 35 positions
  are - the best positions concentrate inward. +-3 X / +-2 Z kept (wider = +20% cost).
- record_cycle: unreachable -Families code removed (the switch runs -BestFamily).
  heat\deep_spots.ps1 and heat\family_spots.ps1 marked SUPERSEDED. main\work scratch moved to
  the history archive.
- best_spots.csv rebuilt after the reset: 500 spots, heat 32.3-23, 242 on line 10617.

### THE PHASE MODEL - every seed at a spot, exactly (full derivation above, under THE PHASE MODEL)
seed = f (bits 0-19) + 2^20 c (20-34) + 2^35 v (35-47). For fixed (f, c), the top bits v shift
every chunk's nextInt bits by the SAME 2^18 w (w = M v mod 2^13): B(v) = B(0) + 2^18 w mod 2^31.
A chunk is possible iff B(0) even; its phase is B(0) mod 5; it is slime when w = phase (mod 5)
(phase + 2 after B wraps past 2^31). So a class's 8,192 seeds are a handful of layouts, and its
best farm comes from 222 numbers. the CPU reference model and its test (not shipped):
- 90.9M checks vs Java, 0 mismatches. The 68.28 at its AFK chunk: phases 47/25/22/46/18 -> 73.
- Exact exhaust of a family (2^28 seeds) at one AFK chunk: 1.2-7 s CPU (slime_gpu --enumerate
  37 s GPU). 0x9E078: 2,550 seeds >= 70. Random families: best <= 57 (200k classes).
- Rich = TAIL of classes (0xA2CEC: 0.23% of classes reach 64); family means / sampled classes do
  not find it. The endgame is the exact spot search (all 2^35 classes x 35 positions, ~4e14 ops,
  ~2-4 min/spot laptop) - design above, under THE PHASE MODEL; not built yet at that point.

PHASE SEARCH BUILT AND VALIDATED - hotspot_scan --phase-search, heat\phase_spots.ps1,
record_cycle -PhaseSearch. Every seed of the top-3% families (by possible chunks) at 15 AFK
positions per spot (every 3rd chunk within +-6 X / +-3 Z), exact. Re-found 68.28, 67.07, 66.84,
66.63, 66.17 at their exact positions; ~80 s/spot on the laptop with the GPU shared (the old
best-family search: 150-330 s and 0.02% of seeds). The top-3% cut lost nothing against a search of
all 2^48 seeds at one position. Details and speed history: above, under THE PHASE MODEL.
Window note: farms sit up to ~5 chunks from a spot centre in X (67.07) and 4 in Z (66.84) - the old
+-3/+-2 windows missed both; the stride grid covers +-7/+-4.

FIRST EXACT-SEARCH BATCH (cycle #4): 10 hottest spots (heat 32.3-28.7) in 449 s ->
11 new 66+ farms, two above the old 68.28: **68.54** (seed 187561908205390, AFK (-26008735,16457166),
75 chunks, 17,545 blocks; spot heat 29.1, line 10617) and **68.39** (seed 157366496822294, AFK
(-15087422,-22325443), 71 chunks @ 96.3%; line -14404). Not yet measured in game. The run stops on a
new record by design; restarted afterwards (record to beat now read from records\index.csv).
HEAT TEST (27 stratified spots, best-family search): record-class families at ~1 in 10-15 spots in
every heat band 12-33 (heat 26.8: 67.07; heat 13.7: 65.14); heat is a weak guide to them.
Possible-count metric (families with >= 155 possible chunks near a spot): r = 0.81 with big layouts
across positions around one spot, but only r = 0.24 across 51 spots (heat: 0.25) - not a better
spot ranking yet. main\theory\heat\n155_vs_spots.csv, possible_vs_layouts_6707.csv.

NO LOST RESULTS - THE REGRESSION GATE. Found by checking the exact search against every
66+ farm ever archived at the 5 known-farm spots: the build that kept one layout per class dropped
67.28 and 66.73 (68.28 spot) and 66.97 and 66.14 (67.07 spot) - a class of 8,192 seeds can hold
several good layouts (different wrap segments). Fixed: the exact walk now emits EVERY layout of a
class reaching the floor; the driver scores the top 400 DISTINCT layouts by blocks. Result: 17 of 17
archived farms re-found, spot bests unchanged. heat\phase_regress.ps1 -Exe <new build> must pass
before any phase-search build is installed. The 64 spots searched before the fix were re-passed with
it (main\theory\heat\phase_repass.csv, no second ledger row).
LOGGING: every searched spot = a row in main\theory\heat\phase_search.csv + a PHASE|top3@X,Z row in
main\families.csv; its layouts of 68+ chunks and its scored farms of 65+ cq are kept in
main\theory\heat\phase_layouts\<X>_<Z>.csv / <X>_<Z>_scored.csv; 66+ go to main\records as always.
The run skips every spot in phase_search / best_family / phase_validation (new spots only) and no
longer stops on a new record (logged in cycles.txt as NEW RECORD).
FAMILY CUT NOW 5% (was 3%): at the 68.54 chunk, record-sized (70+) layouts came from families up to
rank 3.58% - inside 3% only through ties. Pipelined refine (CPU scores spot i while the GPU searches
spot i+1), shortlist = top 400 layouts by blocks + top 200 by chunks, up to 3 seeds per layout
(seeds identical inside the window can differ outside it: the 66.56 at the 68.28 spot). Regression
gate: 20 of 20 archived farms re-found; the 66.17 spot's best rose to 66.38.
OPEN ITEMS (tracking file not shipped in this copy): verification, timeline, cleanup, theory. Done so far: regression set of
9 spots (heat\phase_regress.ps1 default main\theory\heat\regress_spots.csv, incl. 69.09 / 68.54 / 68.39 / 68.38);
automatic family-cut check every 50 spots (main\theory\heat\cut_checks.csv). Best in game: 69.39 (-21323306,17855231), seed 71791501344359, 76 chunks, 17,764 model blocks, cycle #66, line 11519 heat 28.8 - MEASURED 18,598, #1 (= the raised-AFK estimate). #2: 70.34 (-8546740,16457220), seed 136253019324379, 18,409. Best model farm: 70.64 (-27565075,26600328), seed 51829727074880, 76 chunks, 18,083 model blocks, cycle #55, line 17161 heat 29.3 - measured 18,293 in game (#3). #2 in game: 69.30 (-25146501,4528323), seed 173087838020963, 18,407 (model 17,740).
CLEANUP: 53 duplicate record copies (equivalent seeds of the same farm - same cq at the same AFK
block, e.g. the 68.28 under 7 seeds) moved to main\archive\duplicate_records (104 files + the
index.csv backup); one copy per farm kept (the one over66.csv / index.csv point to, with its perimeter file);
index.csv 208 -> 194 rows; gallery = exactly the over66.csv farms (137). Test/scratch files (main\work),
old .bak sources and stale main\ outputs moved to main\archive\cleanup. Nothing deleted.
ADAPTIVE POSITIONS: phase_spots -TopPositions 10 (default) -> hotspot_scan --phase-top-positions 10
--phase-pos-stat 150: the spot's 15 grid positions are ranked by families with >= 150 possible chunks (one
cheap GPU pass each) and only the best 10 get the full search. 97/97 test spots kept their best layout (36
in-sample + 61 held out, heat\position_test.ps1); regression gate 55/55; ~1/3 less search time.
SPOT RANKING (246 exact spots): 67+ farm at 18% of heat-28+ spots, 8% at 26-28, 1% at 24-26 - heat stays the
ordering and the supply of very hot spots is the limit. The possible-count statistic is no better for spot best.
GPU HEAT SURVEY: hotspot_scan --heat-survey --heat-from CX --heat-to CX [--heat-row R] [--heat-seeds N]
[--heat-min H] --heat-out file: heat40 of every column on one row (same definition as DiscPairs / x_rescore;
6 leaders at 2M seeds within noise of the CPU values). 20,000 columns x 50k seeds in 0.8 s.

### WHOLE-WORLD COVERAGE - every X column, every Z line, candidate spots measured directly
GPU heat modes in hotspot_scan (same heat40 as SlimeModel.DiscPairs, validated): --heat-survey (a row of
columns), --heat-rows <file> (many rows over one X range), --heat-spots <file of cx,cz> (any spots). Speed ~3,900
spots/s at 300k seeds on the laptop.
- X: every column inside the border on line 10617 (3.75M, 16 min): 69,955 peaks >= 18, top 2,000 re-measured at
  2M (heat\x_world.ps1 -> x_world.csv). 237 peaks >= 28 vs 13 in the old variance-picked list; best 36.3.
- Z: every line (38,710) at 5 rows around 48.5 + 96.875 n over 64 columns (27 min; heat\line_world.ps1 ->
  line_world_ranked.csv): only 29 of the new top 60 were in the old top 60. Checks: rows between lines are cold
  (3,000 consecutive rows: max 1.35 raw >10 rows off a line vs 6.99 on it); +-3/4 rows beat +-2 for only 2 of the
  top 300 lines (by 1-4%, noise) - the formula and the +-2 window capture the lines.
- The product model F(X) x G(Z) does NOT hold at the top: the 150 hottest X of line 10617 correlate r ~ 0.3 with
  their heat on lines 9950 / 4850 (top-50 overlap ~50%). So spots are MEASURED, not predicted: top 10,000 X peaks x
  top 300 lines = 3M spots at 300k (13 min, spot_measured.csv), top 19,740 kept and top 3,000 re-measured at 2M
  (heat\spot_top.ps1 -> spot_top.csv). Result: 666 spots >= 28 (prediction: 296), 46 >= 32, best 36.6, spread over
  many lines. heat\best_spots.ps1 now ranks by these measured values.
- Not covered (known): X columns beyond the top 10,000 peaks crossed with lines beyond the top 300 are predicted
  only (low odds given the ranges); heat itself is a proxy for record-class families.
IN-GAME: 69.39 measured 18,598 (model 17,764, +4.7%) - #1 in game, exactly the raised-AFK estimate; 70.34 18,409 spawning spaces (model 18,007, +2.2%) #2; 69.30 18,407 (model 17,740, +3.8%) #3; 70.64 18,293 (model 18,083, +1.2%) #4; 70.82 18,261 (model 18,131, +0.7%) #5 - the top model score, = the raised-AFK estimate. 68.28 17,771 (model
+1.7%) #5, 69.09 17,740 (+0.3%) #6, 66.04 17,112 (+1.2%). The gap is layout-dependent: the model scores at
y-offset 0, and slime chunks inside the middle no-spawn sphere (the 69.30 has 4) add spawning blocks when the
AFK point is raised - the 69.30's overshoot was called from its image before measuring. So model cq ranks
farms only to a few %, and a y-aware score (best AFK height per farm) would rank in-game candidates better.
CLEANUP 2: legacy main\ folders (keep, best_patterns, archive_runs, bench, qualify), the A/B arm experiment data, the oldest logs and four superseded heat\ scripts moved to main\archive (see main\archive\README.txt) and heat\old. main\ = archive, commands, enum, logs, records, scores, seeds, stress, theory, work.
RECORDS: only 66+ is archived now (ArchiveResult floor 66; records\64 and \65 moved to main\archive\records_64_65, index.csv 66+ only). Perimeter setups are NOT generated per farm any more - on request only (perimeter_setup.exe --seed S --center-x X --center-z Z); the 216 old ones are in main\archive\perimeter_files.

RAISED-AFK FOLDER: main\records\over66_y-39\ - every 66+ farm's image named "<peri>-<cq>-<seed>.png" (peri = afk_rescan.exe's estimate of /perimeterinfo with feet at y -39 over the -64 floor: dy 24, 24^2 <= a^2+b^2+dy^2 <= 128^2 - no inner circle, outer 125.7 - best AFK point within +-48 blocks), or "<ingame>-<cq>-<seed>-measured.png" for farms in main\records\measured_in_game.csv. A side hint, not a ranking; a real in-game measurement always wins. New 66+ farms are added at filing (hunt_pipeline Add-Y39Image, try/catch, ~0.1 s); afk_rescan.ps1 is a one-shot sync (backfill + rename measured farms) - no loop. Calibrated: full floor 49,669 exact (the game counts d^2 = 576 exactly); exact for 69.39 / 70.82 / 69.30 / 68.28 / 66.04, +20 for 70.64, off ~200 for 70.34 / 69.09. "BIG (estimate ...)" in the search log when an unmeasured farm (not a twin of a measured one) is estimated above the best in-game count. -39 only. Perimeter setups: on request, main\records\perimeter\ (the older ones are in main\archive\perimeter_files).

UNION WINDOW: hotspot_scan --phase-union searches all grid positions of a spot in one pass (each family's B(0) once over the union of its positions' windows, per-position counters in shared memory). Identical output (self-test [8]; 5 real spots row for row) but SLOWER on the laptop RTX 4050: 27.4 s vs 16.7 s per spot - the counters cut occupancy to 12 warps/SM. Off by default; the search uses the per-position kernel.

PREDICTION (study not shipped in this copy) - the final goal (predict where the best farms are and what they read in game). Per-spot table: heat\prediction_table.ps1 -> main\theory\prediction\spots.csv. First look: pre-search predictors weak (heat r 0.10 vs the spot's best -39 count), rich spots = one rich family, good classes share class mod 64, some X columns carry across lines; the five best -39 spots are exactly the in-game #1-#5.

REFERENCE MEASUREMENT PROCEDURE - the ground truth every model number is judged by
- Superflat world, Minecraft 1.20.4, Carpet + WorldEdit. Rig from perimeter_setup (on request only, files in
  main\records\perimeter\): /tp to y -50, void //pos1 X-152,-64,Z-152 .. //pos2 X+152,-40,Z+152, obsidian floor at
  y -64 in slime chunks only (the command-minecart command, pasted into one command block), then a repeating,
  unconditional, always-active command block "execute at @p run perimeterinfo" (/give in section 4).
- Standing height: feet at y -39 = 24 above the spawn level (-63). Rationale: at -39 mobs can spawn
  directly below, the bottom of the 128 sphere is a large flat surface (no single blocks sticking out) - and the
  inner no-spawn circle is gone. afk_rescan models exactly this (full floor 49,669 = in game 49,669).
- Move around for the best reading; afk_rescan's "best point within +-48 blocks" reproduced this exactly
  for 69.39, 70.82, 69.30, 68.28, 66.04. Measured counts: main\records\measured_in_game.csv. A real in-game
  measurement always wins.

PREDICTION TESTS: X-column test NO (103 lines on 5 strong columns: mean 64.72 vs 64.60, 68+ 1% vs 3%). Sister test NO (35 sisters X +- k*1,048,576 of 6 record spots: mean 62.88, none 67+; the rich family, shifted exactly for the possible structure, appears at 0 of 19). Possibility (low 18 bits) transports; richness (phase alignment, bits >= 18) does not - it is spot-specific.

PREDICTION SEARCH (predict_cycle.ps1; separate from record_cycle -PhaseSearch): chooses which fresh spots the exact search visits. Universe = main\theory\heat\spot_measured.csv at heat >= 20 (183,536 spots, cached in main\theory\prediction\universe_h20.csv); per cycle 1,000 hottest-unscreened + 1,000 random fresh spots (same-farm rule vs searched and screened); phase_prepass.exe (root, in build.ps1) at 512 random classes per family, top 10% at 2,048, score = stage-2 best + log2(1 + pairs68), top 50 through heat\phase_spots.ps1 (normal exact search, logged in phase_search.csv). Logs main\predict_cycles.txt, main\theory\prediction\screened.csv. Validation and first test: PREDICTION.md section 7 (picks: 67+ 30% vs 7%, 68+ 14% vs 1%).

IN GAME (latest): 72.22 MEASURED 18,727 (model 18,488, +1.3%; = the -39 estimate) - #1, found by the prediction search (predict_cycle cycle #3, spot (28616768,-2104112)). Then 69.39 18,598, 70.34 18,409, 69.30 18,407, 70.64 18,293, 70.82 18,261, 68.28 17,771, 69.09 17,740, 66.04 17,112. Model best: 72.90 (-39 est 18,582, unmeasured).

PREDICTION SEARCH SPEED: phase_prepass 0.23 s per spot (was 0.51): hotspot_scan's fast inner loop (identical output) + only the exact search's adaptive top-10 positions (--top-positions 10, --pos-stat 150; 0 = all 15). Cycle ~22 min. stop_all matches only real launches (-File ...<script>.ps1). Farm images have no inner 24-block ring (slime_refine never draws it; one image per farm, copied to the gallery and over66_y-39). perimeter_setup's void box is chunk-bordered (exactly the floor's chunks).

PROBE SCREEN (the prediction search's big step): a rich family's WHOLE class landscape is lifted (mean count over all 32,768 classes 50.2 vs 39.2 for ordinary kept families, p99 64.5 vs 46.4 - main\theory\research\class_landscape.cpp over 100 jackpots), while its own good set is only ~9 classes of 32,768 - which is why the old 512-random sample found a jackpot 14% of the time. So 8 classes per family RANK families: the jackpot family's median rank is 7 of ~59,000 by the mean of 8 classes, against 1,945 by possible chunks (probe_rank.cpp, 20 jackpots). phase_prepass now takes --probe 8 --exhaust N: probe every kept family, then run ALL 32,768 classes of the best N. Measured on 180 spots of known exact best: the screen finds the spot's true exact best within 2 at 84% (top 0.25%, exhaust 64, 0.24 s/spot - stage 1) and 94% (top 1%, exhaust 128, 0.39 s - stage 2), against 34% for the old screen at the same price; it never exceeds the exact best. predict_cycle.ps1 uses both. heat\rescreen.ps1 (one-shot, resumable) re-screens the ~15,600 spots the old 34% screen passed over. Research tools in main\theory\research: class_landscape.cpp (all-class landscapes), land_analyze.cpp (free class steps: +4, +512, +8192 keep the count ~30% of the time, from the runs of C' = 0x5E43), probe_rank.cpp. Details: PREDICTION.md section 8.

SPEED-UP (installed; every output identical, old builds in main\archive\speedup\old): phase_prepass (screen) 3.7x in chunks mode (96.6 s -> 26.1 s per 2,000 tier-1 spots; -39 mode 3.8x) - 3 host threads with their own streams (PP_WORKERS), per-position work on the GPU (5 waits a spot, not ~22), bit-sliced quarter bound for the exhaust stage (phaseBoundBSQKernel), one warp per class for the exact-best walk with a sort-free max-prefix walk (bestOfClassWarp); start-up self-tests compare the warp routine with the serial one and the new bound's queue with the old kernel's. hotspot_scan --phase-search 2.6x (~10.8 s -> ~3.9 s per spot): phaseBoundBSKernel, 32 consecutive classes per thread through one table lookup per chunk, halves bound bit-sliced, survivors re-checked with the quarter bound in-kernel - same queue (PH_BS=0 = old kernel, PH_BS_CHECK=1 = compare every batch; --self-test [9]); --phase-stdin runs spot after spot in one process and heat\phase_spots.ps1 keeps one open. slime_refine 3.1x: the unused report (two sorts of ~65k rows per seed under the output lock) is skipped when there are no logs, no images and > 8 seeds. Tier 1 estimate ~3.5 h (was ~8.5-11 h).

## Y PHASE AND VANILLA PARITY (added 2026-10-16, on Linux - see LINUX.md for the detail)

- y_phase.ps1: after each cycle (record_cycle -YPhaseTop 5 -YPhaseMinCQ 66; 0 = off). Every new 66+
  farm gets one quick -39 check (max 200), the 5 best by max(-39 vanilla, floor-level blocks) get every
  feet height -63..-39, best AFK point within +-48 at each height, each farm once (main/y_phase.csv).
  The pick is by the better end because floor cq misranks at -39 (70.64 > 69.39 on the floor, 69.39 wins at -39). Above -39 the count is a subset of -39's, so it never goes higher. Its own numbers:
  -39 best for 69.39 / 70.34 / 70.64 / 66.04; 69.30 +9 at -40; 66.21 +387 at -62 (why it read worse in game).
- afk_rescan: --dy-from/--dy-to sweep mode; new column vanilla_dy_best. The existing columns are unchanged.
- Spawn rule, read from the game's NaturalSpawner bytecode in 1.20.6 / 1.21.11 / 26.1.2: a spawn needs
  d^2 > 576 (strict). Carpet's /perimeterinfo counts d^2 >= 576. So /perimeterinfo = vanilla + the exact-24
  shell: <= 1 column at -39 (straight below), <= 4 at floor level. afk_rescan's blocks_* = /perimeterinfo
  (the 49,669 calibration), vanilla_* = real spawning; slime_refine's y-offset-0 rule is vanilla-exact.
- Monolith fixes (perimeter_setup + perimeter_gen), found on real servers by vanilla_world_test.py:
  * teardown left the redstone block and every minecart (the rail cart ran first, later carts lost their
    rail) - now an auto command block clears rail + redstone and the last cart kills the minecarts;
  * on 1.13-1.17 nothing was built at all (the falling rail never landed) - a Health:0 armor stand between
    redstone and rail fixes it, and every newer version accepts the same form;
  * perimeter_setup --game-version (default 1.21.11): spawn_mobs on 1.21.11+ (doMobSpawning is REJECTED
    there), item-component /give on 1.20.5+, y 0 floor before 1.18; //replace air instead of //set air.
- vanilla_parity.py (game jars) and vanilla_world_test.py (real servers 1.16.5, 1.20.4, 1.20.6, 1.21.11,
  26.1.2): 0 mismatches / 155 server checks passed after the fixes.
