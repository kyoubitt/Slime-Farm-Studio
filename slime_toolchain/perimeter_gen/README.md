# Slime Chunk Perimeter Generator

Builds the floor of a sliced portal slime farm perimeter on a set seed, location, and version. Carpet and worldedit are needed.

## Step By Step Guide

[VIDEO](https://www.youtube.com/watch?v=jxQhHYSfn-g)

1. Firstly, create a superflat world with the chosen seed, slime chunk generation is unchanged.

2. Open the program, input the seed, location, and the version. This will generate a .txt with the commands.

3. Input the commands, only do the obsidian platforms for now. Input the large command into a command block and power it from the side, ie button.

4. Scroll to the bottom of the txt, there will be a repeating command block command with /perimeterinfo.
   Replace a obsidian block with it and fly around, both vertically and horizontally,
   until you find the spot with the highest total spawning space. Place a glass block below.

5. Only after the obsidian is in, paste in the schematic pattern above it midair, making sure it's aligned properly.
   The schematic is under releases.

7. Once the schematic is pasted, the purple concrete powder will not fall until it is updated, do //replacenear
   200 purple_concrete_powder air and then //undo to update the blocks. Warning, it will be laggy.

8. Once the purple concrete powder is on the obsidian, do //replacenear 200 purple_concrete_powder nether_portal

9. OPTIONAL. Try different rotations of the pattern. To measure which is best, 
replace the concrete powder with glass and do /perimeterinfo from the spot. Highest value is best. Usually gains a few blocks lower blocks.

10. Add the magma block outline. Same as obsidian.

11. Using minihud, create a despawn sphere from the spot. Fly around and remove and chunks that aren't within the area or unwanted.

12. Using the command in the txt or manually, replace the bottom most layer with glass/tripwire for pack spawning.

REMEMBER

Lightning will destroy portals.

6.75//1.00 Local Difficulty. Hard.

Only bother with turtle eggs for mobcap. Have a filtered storage, wandering traders spawn anyways.

## Requirements

Generating the file needs nothing. Two of the sections it writes do:

- **WorldEdit**: voids the area in section 2, and the easiest way to clear a perimeter afterwards
- **Carpet**: adds `perimeterinfo`, the command the block in section 5 runs

The floor and border commands themselves are vanilla.

## Versions

| Version |
|---|
| 1.13 - 1.17 |
| 1.18 - 1.20.4 |
| 1.20.5 - 1.21.10 |
| 1.21.11 and later |

Select the closest version at or below your game version. 1.13 - 1.17 builds the floor at y 0, the world bottom
before Caves and Cliffs; every other band builds at y -64. 1.13 is the earliest supported: before the Flattening,
falling blocks used `Block` and `Data` instead of `BlockState`, `fill` needed data values, and selectors used `r=`
instead of `distance=`.

## Input Parameters

- **World seed**: world seed (numeric form)
- **Center X** and **Center Z**: the block the floor is centred on, normally the AFK spot
- **Game version**: see version table above

Invalid entries prompt re-entry. Inputs can be piped sequentially.

Everything else is fixed: radius 152 blocks, obsidian floor, magma border, and the AFK position 14 above the floor
with the void reaching 24 above it. The floor sits at y -64, or y 0 on 1.13 - 1.17.

## Output

`perimeter_<seed>_<x>_<z>_<version>.txt`, in seven sections:

| Section | Contents |
|---|---|
| 0. Seed | the seed, for the world creation screen |
| 1. Teleport | `/tp` to the AFK spot, mob spawning off, `/seed` to confirm the world |
| 2. Void the area | two WorldEdit positions and `//replace air` (only touches non-air blocks, much faster than `//set air`) |
| 3. Slime chunk floor | one command: obsidian in every slime chunk |
| 4. Magma border | one command: the border around those chunks |
| 5. Spawning skirt | one WorldEdit selection across the voided area at y -64, `//replace air glass` |
| 6. Measure | a repeating command block running `perimeterinfo` |

Run section 3 first, then section 4. Both commands clean up after themselves, removing the redstone block, the rail
and the minecarts (one cart places an auto command block above the rail that clears the rail and redstone block, the
last cart kills the minecarts; checked on real vanilla servers by the finder's `vanilla_world_test.py`).

Every fill is chunk aligned, one fill per slime chunk. The border is every block touching a slime chunk that is not
slime chunk floor itself, diagonals included, merged into the fewest rectangles that cover it. Border fills use
`replace air` and the voided box is a chunk wider than the floor on every side, so the border never overwrites
terrain at the edge.

A command block holds 32500 characters. Both lengths are printed, with a warning if either is over. At radius 152 a
perimeter is usually about 10000 characters for the floor and 22000 for the border.

## Building

**Windows**: run `build.bat` from a Visual Studio Developer Command Prompt.

**Linux/macOS** (gcc/clang):
```
gcc -o SlimeChunkPerimeterGen -std=c11 -O2 ./src/*.c ./src/*/*.c
```

No dependencies, and no floating point anywhere, so every platform writes byte identical files.

**Reference output**: seed `1`, center `0 0`, version `1.18 - 1.20.4` gives 38 slime chunks of 400, a floor of 38
fills and 3771 characters, and a border of 136 fills, 2420 blocks and 14289 characters. A build that prints those
four numbers matches every other build.

**Memory**: under 1 MB; the whole perimeter is a few hundred kilobytes of grid.

## Credits

Slime chunk generation from Minecraft by Mojang; input prompts shared with TrialFinder.

**License**: MIT
