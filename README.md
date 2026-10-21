# Slime Farm Finder

Finds the best spot for a Minecraft slime farm on a world seed — the AFK block with the most
spawning spaces around it — then writes the commands that build the perimeter.

![SlimeByte](slime_toolchain/docs/studio.png)

## SlimeByte

The app, full screen in your terminal: seed in, best spot out, a live slime-chunk map, the
perimeter commands with Copy buttons, and the build guide. Light and dark colours (press `t`), and a search you've run is
saved, so asking again is instant.

## Install

**Windows** - download `SlimeByte.exe` from [Releases](../../releases), put it in `slime_toolchain` next to the tools
from `build.ps1`, and double-click it.

**Linux** - one line, no sudo (needs `git`, `python3` and a C++ compiler; the CUDA toolkit is optional):

```sh
curl -fsSL https://raw.githubusercontent.com/kyoubitt/SlimeByte/main/install.sh | bash
```

Then run `slimebyte`. Run the same line again to update. To remove it, add `-s -- --uninstall` after `bash`.
With CUDA (an NVIDIA GPU) it builds the GPU search too; without, you get the CPU parts.

**macOS** - with [Homebrew](https://brew.sh):

```sh
brew install kyoubitt/slimebyte/slimebyte
```

Then run `slimebyte`. macOS has no CUDA, so on a Mac the app does Manual scoring, the map and the perimeter commands;
**Best AFK / Cluster search needs an NVIDIA GPU** (run that on a Linux or Windows machine, then type the spot in on the Mac).

The map is a real picture in Windows Terminal 1.22+, Ghostty, kitty, WezTerm and iTerm2;
other terminals draw it with characters.

## The rest

The search itself runs on the GPU (CUDA). Build first, then see:

- `slime_toolchain/HOW_TO_USE.txt` — the one-page version
- `slime_toolchain/README.txt` — every command, in order
- `slime_toolchain/LINUX.md` — running it on Linux
