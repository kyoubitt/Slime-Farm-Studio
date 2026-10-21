#!/usr/bin/env bash
# SlimeByte installer for Linux (works on macOS too, if you'd rather not use Homebrew).
#
#   curl -fsSL https://raw.githubusercontent.com/kyoubitt/SlimeByte/main/install.sh | bash
#
# Run it again any time to update. To remove SlimeByte:
#
#   curl -fsSL https://raw.githubusercontent.com/kyoubitt/SlimeByte/main/install.sh | bash -s -- --uninstall
#
# It needs no sudo: everything goes in your home folder, and the only thing outside it is what you
# install yourself. What it does:
#   1. checks for git, python3 and a C/C++ compiler (and tells you the command to get any that's missing)
#   2. downloads SlimeByte to ~/.local/share/slimebyte
#   3. builds the tools: the GPU ones too if the CUDA toolkit (nvcc) is installed, otherwise just the CPU
#      ones (then Best AFK / Cluster search is off, and Manual scoring, the map and the commands work)
#   4. puts a `slimebyte` command in ~/.local/bin
#
# Overrides (environment): SLIMEBYTE_HOME (install folder), SLIMEBYTE_BIN (where `slimebyte` goes),
# SLIMEBYTE_CPU_ONLY=1 (skip the GPU tools even with CUDA), SLIMEBYTE_REPO / SLIMEBYTE_BRANCH.
set -euo pipefail

REPO="${SLIMEBYTE_REPO:-https://github.com/kyoubitt/SlimeByte.git}"
BRANCH="${SLIMEBYTE_BRANCH:-main}"
DEST="${SLIMEBYTE_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/slimebyte}"
BIN="${SLIMEBYTE_BIN:-$HOME/.local/bin}"

if [[ -t 1 ]]; then
    red()  { printf '\033[31m%s\033[0m\n' "$*"; }
    grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
    cyan() { printf '\033[36m%s\033[0m\n' "$*"; }
    dim()  { printf '\033[90m%s\033[0m\n' "$*"; }
else
    red() { echo "$*"; }; grn() { echo "$*"; }; cyan() { echo "$*"; }; dim() { echo "$*"; }
fi
die() { red "$*"; exit 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
    cyan "removing SlimeByte"
    [[ -d "$DEST" ]] && { rm -rf "$DEST"; dim "removed $DEST (its saved searches and settings went with it)"; }
    [[ -f "$BIN/slimebyte" ]] && { rm -f "$BIN/slimebyte"; dim "removed $BIN/slimebyte"; }
    grn "done"
    exit 0
fi

# ---- what's needed --------------------------------------------------------------------------------------
os="$(uname -s)"
hint_pkg() {   # the one-line install command for this system
    if   [[ "$os" == Darwin ]];            then echo "xcode-select --install"
    elif command -v apt-get >/dev/null;    then echo "sudo apt install $1"
    elif command -v dnf >/dev/null;        then echo "sudo dnf install $2"
    elif command -v pacman >/dev/null;     then echo "sudo pacman -S $3"
    elif command -v zypper >/dev/null;     then echo "sudo zypper install $2"
    else echo "install $2 with your package manager"; fi
}
missing=0
need() {       # need <command> <apt pkgs> <dnf pkgs> <pacman pkgs>
    command -v "$1" >/dev/null && return
    red "missing: $1   ->   $(hint_pkg "$2" "$3" "$4")"
    missing=1
}
need git     git                  git     git
need python3 python3              python3 python
if ! command -v g++ >/dev/null && ! command -v clang++ >/dev/null; then
    red "missing: a C++ compiler   ->   $(hint_pkg "g++ build-essential" "gcc-c++" "gcc")"; missing=1
fi
if ! command -v gcc >/dev/null && ! command -v clang >/dev/null && ! command -v cc >/dev/null; then
    red "missing: a C compiler   ->   $(hint_pkg "gcc" "gcc" "gcc")"; missing=1
fi
(( missing )) && die "Install those, then run this again."
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || die "python3 is older than 3.8 - please update it."

# ---- download -------------------------------------------------------------------------------------------
cyan "SlimeByte -> $DEST"
if [[ -d "$DEST/.git" ]]; then
    dim "updating"
    git -C "$DEST" fetch --depth 1 -q "$REPO" "$BRANCH"
    git -C "$DEST" reset --hard -q FETCH_HEAD       # the build swaps tracked files; your saved data (untracked) stays
else
    [[ -e "$DEST" ]] && die "$DEST exists and isn't a SlimeByte install - move it, or set SLIMEBYTE_HOME."
    mkdir -p "$(dirname "$DEST")"
    git clone --depth 1 -q -b "$BRANCH" "$REPO" "$DEST"
fi

# ---- build ----------------------------------------------------------------------------------------------
cd "$DEST/slime_toolchain"
chmod +x build.sh slime
export CXX="${CXX:-$(command -v g++ || command -v clang++)}"
export CC="${CC:-$(command -v gcc || command -v clang || command -v cc)}"
flags=(--no-test)
[[ -n "${SLIMEBYTE_CPU_ONLY:-}" ]] && flags+=(--cpu-only)
cyan "building (the GPU tools take a minute or two)"
if ! ./build.sh "${flags[@]}"; then
    if [[ -z "${SLIMEBYTE_CPU_ONLY:-}" ]]; then
        red "the GPU build failed (often a CUDA / g++ version mismatch: see LINUX.md, NVCC_CCBIN)."
        cyan "building the CPU tools only instead"
        ./build.sh --no-test --cpu-only || die "build failed - see the messages above."
    else
        die "build failed - see the messages above."
    fi
fi

# ---- the command ----------------------------------------------------------------------------------------
mkdir -p "$BIN"
cat > "$BIN/slimebyte" <<EOF
#!/usr/bin/env bash
# SlimeByte: no arguments opens the app, anything else goes to ./slime (slimebyte doctor, ...)
exec python3 "$DEST/slime_toolchain/slime" "\${@:-gui}"
EOF
chmod +x "$BIN/slimebyte"

echo
grn "SlimeByte is installed."
case ":$PATH:" in
    *":$BIN:"*) echo "Run:  slimebyte" ;;
    *) echo "Add $BIN to your PATH, then run slimebyte:"
       echo "    echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.profile   # (or your shell's rc file), then open a new terminal"
       echo "or run it right now with:  $BIN/slimebyte" ;;
esac
[[ -x "$DEST/slime_toolchain/slime_gpu" ]] || dim "No GPU tools built: Manual scoring, the map and the commands work; Best AFK / Cluster need an NVIDIA GPU + CUDA."
