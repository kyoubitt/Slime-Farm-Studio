# AI_CONTEXT — read this first

--------------------------------------------------------------------------------
## ⛔ STOP — DO THIS FIRST, BEFORE ANY OTHER COMMAND IN ANY DOC

**RUN `build.ps1` AND CONFIRM ALL THREE SELF-TESTS PASS BEFORE RUNNING
ANYTHING ELSE. THE SHIPPED `.exe` FILES WILL NOT RUN ON A DIFFERENT GPU
THAN THE ONE THEY WERE BUILT ON.**

`build.ps1` compiles with `-arch=native`, which bakes in the exact compute
capability of the build machine. Run a shipped binary on a different GPU
architecture and you get this, with no hint that rebuilding is the fix:

    CUDA error: no kernel image is available for execution on the device
    at hotspot_scan.cu:631

Verified for real, not theorized: binaries built on the rental box (RTX PRO
6000 Blackwell, sm_120) fail exactly like that on an RTX 4050 laptop (Ada,
sm_89). The same `build.ps1` on that laptop, with no other change, rebuilt
all four tools and passed every self-test. So the fix is always:

    powershell -ExecutionPolicy Bypass -File build.ps1

Skip this ONLY if you are on the SAME machine that produced the binaries and
no source file has changed. Anywhere else — new box, rented GPU, someone
else's PC — rebuilding is mandatory, not advisory.

### Prerequisites for that build (neither ships in the zip)

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
  shipped binaries are `-arch=native` and will not run on a different GPU):
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

If an AI assistant is available, it's usually faster to just point it at
this folder and ask a direct question ("what does --climb-scan do," "where
do results get saved") than to search these files by hand - it can read
the source and every doc here and answer immediately, including things not
written down anywhere.

## Hardware

Currently runs on a rented RTX PRO 6000 Blackwell (188 SMs, 96 GB, sm_120),
AMD EPYC 9354 (16 threads), driver 595.97. On a GPU-passthrough VM,
**do not replace the driver** — that risks losing GPU access entirely.
Every wall-clock number in every doc was calibrated on this box. On
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

    perimeter_setup.exe --seed <SEED> --center-x <X> --center-z <Z> --y -64 --radius 200 --afk-y -40 --void-top -40

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
                    [--y -64] [--radius 200] [--block obsidian]
                    [--void-top 120] [--afk-y 100]
```

| flag | default | meaning |
|---|---|---|
| `--seed` | required | world seed |
| `--center-x` / `--center-z` | 0 | the AFK spot, BLOCK precision - take it from `slime_refine`'s `BEST BY BLOCKS` line, not the chunk-aligned scan centre |
| `--y` | -64 | Y of the obsidian floor. -64 for 1.18+, 0 for older |
| `--radius` | 200 | half-width of the rig in blocks - deliberate margin over the 128-block despawn sphere |
| `--block` | obsidian | floor material |
| `--void-top` | 120 | top of the voided box |
| `--afk-y` | 100 | player standing height, and where the command-block chain is built |

Output is six sections in execution order (sections 0-2 and 4 paste into
chat; section 3 goes into a command block): SEED, TELEPORT+SPAWNPOINT
(`/tp`, `/spawnpoint`, `/gamerule doMobSpawning false`, `/seed`), VOID THE
AREA (WorldEdit `//fast //pos1 //pos2 //set air`), SLIME CHUNK FLOOR (see
below), MEASURE (`/perimeterinfo`, no mob argument - with one, e.g.
`slime`, Carpet dumps every spawnable coordinate and buries the summary).

**Why a "monolith":** the floor needs one `/fill` per slime chunk,
typically ~100-125 commands for radius 200. Chat caps at 256 characters
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
bogus spawnable surfaces and inflating the exact count being measured. A
re-triggerable chain-command-block form (an impulse block plus a march of
`chain_command_block`s, `auto:1b`, triggered once by a button) is emitted
as an alternative, at the cost of needing to actually place ~100+ blocks
by hand instead of pasting one command.

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

**Worked examples**, both independently verified end to end:

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
  confirmed NOT worth it for this specific rental box (VRAM at 1.8% peak,
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
