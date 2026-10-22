<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="slime_toolchain/docs/logo-wordmark-dark.png">
    <img src="slime_toolchain/docs/logo-wordmark.png" width="420" alt="SlimeByte">
  </picture>
</p>

Finds the best spot for a Minecraft slime farm on a world seed — the AFK block with the most
spawning spaces around it — then writes the commands that build the perimeter.

![SlimeByte](slime_toolchain/docs/studio.png)

Based on [xvyz1/Vibecoded-Slime-Chunk-Finder](https://github.com/xvyz1/Vibecoded-Slime-Chunk-Finder).

## The app

Full screen in your terminal: seed in, best spot out, a live slime-chunk map, the
perimeter commands with Copy buttons, and the build guide. Light and dark colours (press `t`), and a search you've run is
saved, so asking again is instant.

## Install

**Windows** - download `SlimeByte.exe` from [Releases](../../releases), put it in `slime_toolchain` next to the tools
from `build.ps1`, and double-click it.

**Linux** - one line, no sudo (needs `git`, `python3` and a C++ compiler; the CUDA toolkit is optional, and an
NVIDIA card isn't needed):

```sh
curl -fsSL https://raw.githubusercontent.com/kyoubitt/SlimeByte/main/install.sh | bash
```

Then run `slimebyte`. Run the same line again to update. To remove it, add `-s -- --uninstall` after `bash`.
The search runs on whatever you have, fastest first: an NVIDIA GPU with CUDA (if the toolkit is installed), any other
graphics card through OpenCL (AMD, Intel), or every core of your CPU.

**macOS** - with [Homebrew](https://brew.sh):

```sh
brew install kyoubitt/slimebyte/slimebyte
```

Then run `slimebyte`. A Mac has no CUDA, so the search runs on the Mac's graphics card through OpenCL (Apple still
ships it), or on the CPU if that doesn't work.

The map is a real picture in Windows Terminal 1.22+, Ghostty, kitty, WezTerm and iTerm2;
other terminals draw it with characters.

## The rest

Best AFK and Cluster search around 1M blocks takes about a second on an NVIDIA GPU, a few seconds on another graphics
card or a multi-core CPU; the whole world takes minutes on a graphics card and much longer on a CPU. Build first, then see:

- `slime_toolchain/HOW_TO_USE.txt` — the one-page version
- `slime_toolchain/README.txt` — every command, in order
- `slime_toolchain/LINUX.md` — running it on Linux
