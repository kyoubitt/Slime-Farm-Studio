# Running on Linux

**Easiest way in: `./slime gui`** - the app, full screen in your terminal (map, best spot, perimeter commands,
build guide; mouse or keyboard). Or `./slime` for a numbered menu. `HOW_TO_USE.txt` is the one-page version of
everything below.

The same source and the same `.ps1` scripts run on Windows and Linux. Keep editing the scripts on
Windows as usual: on Linux they run under PowerShell 7 (`pwsh`), which reads and writes the same
`main/` files.

## What you need

| need | why | Arch |
|---|---|---|
| CUDA toolkit | `nvcc`, for the GPU tools | `sudo pacman -S cuda` |
| gcc / g++ | the CPU tools, and the host side of nvcc | already installed |
| PowerShell 7 (`pwsh`) | runs the `.ps1` scripts | not in the Arch repos: unpack Microsoft's official `powershell-<ver>-linux-x64.tar.gz` from github.com/PowerShell/PowerShell/releases into `~/.local/share/`, and link `pwsh` into `~/.local/bin`. No sudo needed. |
| Python 3 | `./slime` and the parity tests (standard library only) | already installed |
| a JDK | `vanilla_parity.py` only (reads your Minecraft jars) | any of 21 / 25 |

Nothing else: no pip packages, no system-wide changes beyond `cuda`.

## Build (mandatory on every machine)

```sh
./build.sh          # all 7 tools + the perimeter generator, then the three self-tests
```

`-arch=native` bakes in this GPU, so binaries from another machine won't run here. Rebuild after any
source change. Every tool also gets a `<name>.exe` link, because the scripts call tools by that name.

| env var | use |
|---|---|
| `NVCC=/path/to/nvcc` | CUDA somewhere unusual |
| `NVCC_CCBIN=g++-14` | your g++ is newer than this CUDA accepts |
| `CUDA_ARCH=sm_89` | building for a different GPU than this one |

## Running

Every command in the other docs works with `pwsh` in place of `powershell -ExecutionPolicy Bypass`:

```sh
pwsh -File record_cycle.ps1 -Status
pwsh -File record_cycle.ps1 -Range 100000 -Repeat 100
pwsh -File record_cycle.ps1 -PhaseSearch -BestFamily -BestFamilySpots main/best_spots.csv
pwsh -File stop_all.ps1                  # the ONLY correct way to stop a hunt
pwsh -File stress_toolchain.ps1 -Quick
./hotspot_scan.exe --bench --center-x 0 --center-z 0 --range 40

# the heat hunt (AI_CONTEXT.md "How the hunt works"); needs main/theory/prediction/universe_tier1.csv - data/DATA.txt
pwsh -File heat/universe_chunk.ps1 -Minutes 10
pwsh -File heat/second_pass.ps1
pwsh -File heat/tier2_skim.ps1 -Batches 6        # the heat45 skim that found the 20,506 record
```

Windows-style paths (`main\work\x.csv`) work everywhere: the tools turn `\` into `/` on Linux.

## The Y phase

Everything else scores a farm at one standing height. After each cycle, `y_phase.ps1` runs on that
cycle's new 66+ farms (`-YPhaseTop 5`, `0` turns it off):

1. **Pick.** Each farm gets one quick check at −39 (max 200). Normal cq is scored on the floor, which
   ranks farms differently: the 70.64 beats the 69.39 on the floor, but the 69.39 wins at −39. The 5
   with the best "better end" (−39 or floor) go on, so a floor-best farm like the 66.21 isn't dropped.
2. **Sweep.** Those 5 get every feet height from −63 (on the floor) to −39, with the best AFK point
   within ±48 blocks at each.

Above −39 the count can only drop, so that's where it stops. Each farm is only ever swept once. A
cycle costs at most 200 quick checks + 125 sweep runs, a couple of seconds. It prints a table, the largest gain it found, and the
in-game number for farms in `main/records/measured_in_game.csv`. Everything goes into
`main/y_phase.csv`.

For one farm by hand: `./slime y --seed S --x X --z Z`.

Measured on farms you've already checked in game:

- −39 is best for 69.39, 70.34, 70.64 and 66.04.
- The 69.30 is +9 better at −40.
- The 66.21 is +387 better standing on the floor (−62). That explains why it measured worse in game
  than the 66.04.

## `/perimeterinfo` vs real vanilla spawning (checked in the game's own code)

- **Vanilla spawner** (`NaturalSpawner`, every jar checked): a spawn needs `24² < d² ≤ 128²`. Exactly
  24 blocks away never spawns.
- **Carpet `/perimeterinfo`**: counts `24² ≤ d² ≤ 128²`. It includes that exact-24 shell.

They differ by at most 1 block at −39 (the column straight under you) and at most 4 standing on the
floor. `afk_rescan` now writes both:

- its existing columns are the `/perimeterinfo` number, unchanged and still matching your in-game
  calibration (49,669; the 69.39 / 69.30 / 66.04 measurements exactly);
- `vanilla_dy_best` is what the game really spawns on.

`slime_refine`'s floor-level rule was vanilla-exact all along.

## 1:1 vanilla parity tests

```sh
./vanilla_parity.py        # against every Minecraft jar in your Prism install
./vanilla_world_test.py    # real vanilla servers: 1.16.5, 1.20.4, 1.20.6, 1.21.11, 26.1.2
```

**`vanilla_parity.py`** calls the game's own `seedSlimeChunk(...).nextInt(10)` from your jars. On
1.20.6, 1.21.11 and 26.1.2 it checks:

- 20M random chunks and five full 1001×1001-chunk maps, for both the CPU and GPU builds;
- `slime_gpu`'s kernels end to end;
- both perimeter tools' floors, and the generator's magma border block by block;
- the spawner rule read from the bytecode;
- `afk_rescan` at four heights.

Result: 0 mismatches.

**`vanilla_world_test.py`** downloads the official server (sha1-checked, cached in
`~/.cache/slime_toolchain`). It pastes both tools' monoliths into powered command blocks exactly as
you would, then reads the saved world back. Result on all five versions:

- floor and border identical to that server's own slime chunks;
- the cleanup leaves only your command block (no redstone, rail, minecarts or items);
- every gamerule, `/tp` and `/give` line is accepted.

It sets `eula=true` only inside its throwaway server folders under `main/work/world_test/`.

## Fixed while making this work

- **Monolith cleanup** (both perimeter tools). The old teardown removed the rail first, so the carts
  after it never fired, and a redstone block plus every minecart were left behind. The redstone
  block is a spawnable surface, so it corrupted the count. Now an auto command block clears the rail
  and redstone, and the last cart kills the minecarts.
- **1.13–1.17.** The monolith built nothing at all on a real 1.16.5 server: the falling rail never
  landed. A `Health:0` armor stand between the redstone and the rail fixes it, and all newer
  versions accept the same form.
- **`perimeter_setup --game-version`** (default 1.21.11):
  - `spawn_mobs` on 1.21.11+, which rejects `doMobSpawning`;
  - the item-component `/give` on 1.20.5+;
  - a y 0 floor before 1.18.
- **`//replace air`** instead of `//set air` in both tools' void step. It only touches non-air
  blocks, so it's faster.
- **Linux script fixes.** `Start-Process -WindowStyle` (Windows-only) made `hunt_pipeline` skip
  scoring a spot's seeds. Raw `"$root\..."` paths in .NET calls, `powershell -File` calls,
  `stop_all`'s process search and `$env:TEMP` are all now cross-platform, with the same behaviour on
  Windows.
