# OVERVIEW — read this first

A GPU search for the best **slime farm** in Minecraft Java: the AFK spot whose perimeter holds the most
slime-chunk area, measured the way `/perimeterinfo` reads it with the player's feet at **y −39** over a −64
floor. The current record found with these tools is **20,506 blocks**, confirmed in game.

---

## ⛔ STOP — BUILD FIRST

```
powershell -ExecutionPolicy Bypass -File build.ps1
```

**On Linux:** `./build.sh` builds the same tools and runs the same self-tests (`LINUX.md`), and every `.ps1`
here runs under PowerShell 7 as `pwsh -File ...`. `./slime gui` is a terminal app over the same tools and
`./slime` a menu of them (`HOW_TO_USE.txt`).

**No binaries are shipped.** `build.ps1` compiles with `-arch=native`, which bakes in the compute capability
of the build machine — a binary built elsewhere fails on your GPU with no hint that rebuilding is the fix.
It needs `nvcc` and MSVC `cl.exe`; it locates `cl.exe` via `vswhere` itself and refuses to run without it.

Three self-tests must pass. They are real tests, not smoke tests:
- `hotspot_scan --self-test` — GPU against a validated CPU core, including off-centre windows
- `slime_gpu --self-test` — same, independently
- `slime_refine --self-test` — must reproduce `slimefinder.jar`'s fine phase exactly

Then benchmark your machine, because every tuned default here was measured on a laptop-class 6 GB GPU:

```
powershell -ExecutionPolicy Bypass -File stress_toolchain.ps1 -Quick
```

---

## Verify the build against known answers

`data\known_answers.csv` holds five farms, each measured in game. A correct build reproduces every one.

| check | command | expected |
|---|---|---|
| the −39 ranking | `afk_rescan.exe --in <seed,x,z from the fixture> --out out.csv --dy 24 --window 48` | `blocks_dy_best` equals `estimate_blocks39` for all five rows |
| the exact search | `heat\phase_spots.ps1 -Spots 1 -SpotFile <X,Z = 16598688,-28207696>` | `SPOT BEST 76.23 cq`, 80 chunks at the screen, 86 at the refined best |

Both were verified from this folder on 2026-10-16. Four of the five estimates matched the in-game reading
exactly; the fifth was +32 blocks (19,734 estimated, 19,766 read).

---

## How the hunt works

Four stages. The whole design exists because the expensive stage must only ever see spots worth its time.

1. **Heat** — a cheap per-location estimate of slime density, from the class estimator
   (`hotspot_scan --heat-class`). This is what makes the search possible at all; see "Why this is not brute
   force" below.
2. **Screen** (`heat\universe_screen.ps1` → `phase_prepass.exe`) — ~0.011 s per spot. Reports the best
   slime-chunk count reachable at that spot over candidate AFK layouts.
3. **Gate + exact search** (`heat\candidates.ps1` → `heat\phase_spots.ps1` → `hotspot_scan --phase-search`)
   — ~5 s per candidate, so only spots screening **76+** get it. Solves every seed of the top families
   exactly, via the phase model in `docs\PHASE_MODEL.txt`.
4. **File and rank** (`hunt_pipeline.ps1`, `y39_rank.ps1`, `afk_rescan.exe`) — writes the farm, its image
   and its ledger row, then ranks the whole archive by the −39 number.

One command runs a full cycle: `heat\universe_chunk.ps1 -Minutes 10`, then `heat\second_pass.ps1`.

---

## The three numbers that matter, and why they are what they are

- **Gate 76** (`heat\candidates.ps1 -MinCount`). Every farm over 19,000 blocks ever found came from a spot
  screening 78+ — 8 spots out of 737 searched. The other 729 took ~99% of the search time and their ceiling
  was 18,970. The gate is 76 rather than 78 because projecting each band to the full catalogue puts screen
  76 at 19,149 and 77 at 19,064, both still over 19,000, and because the screen is a sampled lower bound:
  spots screening 76 have produced farms with 82 exact chunks. Full table in `docs\HEATMAP.txt`.
- **Second pass 74–75** (`heat\second_pass.ps1 -MinPass`). The safety net below the gate. It used to sweep
  68–73; that sweep screened 113,452 spots across five sections and its best result was 18,679, never once
  reaching the archive top 40. The 74–75 net costs 32 seconds a section; the old sweep cost 10 minutes.
- **Screen floor 64** (`--floor` in `heat\universe_screen.ps1`). 16% faster than 60 and verified identical
  on every result column over 3,000 real spots. **Not** applied in `--y39` mode, where the same change moves
  `best` on 4 spots in 3,000 — the −39 re-rank keeps floor 60. Raising it past 64 gains nothing (measured 64
  through 74; it flattens then gets slower).

---

## Why this is not brute force

A Minecraft world holds **14,062,492,500,001** chunk positions. Roughly **1,300** of them can host a farm as
good as 20,506 given the right seed — about **1 in 10.7 billion**. Searching blind at this toolchain's rate
would take **3.6 years** of continuous GPU. The record was found after screening **531,595** spots, about
1.6 hours of screening, because heat says which locations are worth visiting.

That is the whole value of the project, and it is why the heat work (`docs\HEAT_CATALOGUE.txt`) matters more
than any kernel optimisation.

**The sharpest single finding:** ordinary heat (`heat40`, mean density) is the wrong axis. **Tail heat
(`heat45`) is the right one.** The record spot's heat40 is **17.361** — mid-range, far below the 22+ "tier 1"
threshold the project hunted first — but its tail heat put it in the top 2%. heat40 ordering would have
ranked it roughly 9-millionth. See `docs\HEATMAP.txt`, "heat45 test" and step 3.

---

## What is NOT here

No catalogue, no spot list, no farm archive — **method, not results**. `data\DATA.txt` says exactly what is
missing, how to regenerate each piece, and what to ask the sender for if you would rather not rebuild it.
The only input you must supply is `main\theory\prediction\universe_tier1.csv`, a `cx,cz,heat` list sorted
best first.

---

## Do not re-propose these — all tested and dead

- **Deeper per-spot search.** Eight known elite spots re-searched at 9× the budget (25% of families, refine
  1500/800/800, all 15 AFK positions): **zero improvement on all eight**. The standard budget saturates a
  spot. Value is in new spots, never in revisiting one.
- **GPU kernel and math rewrites** for `phase_prepass` / `hotspot_scan` — an 8-dimension audit with
  adversarial verification refuted every one. Caveat: that verdict came from audit, not measurement, and the
  same style of audit was later wrong by 30% on a different kernel. Ablate before trusting it.
- **x/z low-bit residue patterns** in where good spots sit — flat once counted per distinct spot. The
  apparent 6× enrichment was an artefact of multi-farm spots counted once per farm.
- **z-row clustering** — the top spots share rows no more than chance predicts (expected 5.9 same-row pairs
  among the top 100's 34 spots, observed 6). Tier 1 is simply row-concentrated to begin with.
- **The 68–73 second-pass sweep** — see above.

The general lesson, learned the hard way twice: before believing a pattern, check whether it is just the
shape of the catalogue you sampled from.

---

## Docs

| file | what it holds |
|---|---|
| `docs\HEATMAP.txt` | the hunt plan, tier definitions, the gate evidence, heat45, run history |
| `docs\PHASE_MODEL.txt` | the phase model the exact search is built on — read before touching the search |
| `docs\PREDICTION.txt` | how farm value is predicted and what correlates with the −39 number |
| `docs\HEAT_CATALOGUE.txt` | how the heat catalogue was measured, and how to rebuild it |
| `docs\CUTOFF.txt` | how far down the heat scale is worth hunting, with the economics |
| `docs\SECOND_PASS_NOTES.txt` | the second-pass experiments and what they settled |
| `docs\REWRITE_PLAN.txt` | the optimisation audit: what was installed, what was refuted |
| `docs\OPEN_ITEMS.txt` | open questions and parked ideas |
| `docs\WATCHLIST.txt` | the spot-archive protocol (79+ chunks), and why deep re-scans were dropped |
| `perimeter_gen\README.txt` | the standalone perimeter generator, separate build |

---

## Credits and licensing

The slime-chunk check and the fine-phase behaviour are validated against **slimefinder.jar** (its author's
work); `slime_refine --self-test` exists to prove this toolchain reproduces it exactly. No Mojang files are
included — Minecraft itself is the only ground truth for the in-game numbers and you need your own copy to
confirm anything. `perimeter_gen` carries its own notes in `perimeter_gen\README.txt`.
