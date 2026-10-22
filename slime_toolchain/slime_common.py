"""slime_common.py - shared plumbing for the Python helpers: ./slime (the front end),
vanilla_parity.py and vanilla_world_test.py.

The hunt itself is the .ps1 scripts on every platform (pwsh on Linux - see LINUX.md); nothing here
replaces them. Standard library only - nothing to pip install.
"""
import csv
import os
import subprocess
import sys

# the toolchain folder; for SlimeByte.exe (PyInstaller) that's where the .exe is, not where it unpacks itself
ROOT = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__))
EXE = ".exe" if os.name == "nt" else ""
# where the app keeps what it makes (prefs, saved searches, perimeter files, scores). Next to the tools by default;
# SLIMEBYTE_DATA moves it, which is what a package manager needs: its install folder is replaced on every upgrade.
DATA = os.environ.get("SLIMEBYTE_DATA") or os.path.join(ROOT, "main")


def tool(name):
    """Absolute path of a built tool (slime_gpu, slime_refine, ...)."""
    return os.path.join(ROOT, name + EXE)


def require_tools(*names):
    missing = [n for n in names if not os.path.exists(tool(n))]
    if missing:
        die("missing %s - run ./build.sh" % ", ".join(n + EXE for n in missing))


# ---- console -----------------------------------------------------------------
_COL = {"red": 31, "green": 32, "yellow": 33, "cyan": 36, "magenta": 35,
        "gray": 37, "darkgray": 90, "darkcyan": 36, "darkyellow": 33}
_TTY = sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def say(msg="", color=None):
    if color and _TTY:
        print("\033[%dm%s\033[0m" % (_COL[color], msg), flush=True)
    else:
        print(msg, flush=True)


class ToolError(SystemExit):
    """What die() raises: a normal exit for the command line, and the message for slime_studio.py
    to show in its window."""
    def __init__(self, msg, code=1):
        super().__init__(code)
        self.msg = msg


def die(msg, code=1):
    say(msg, "red")
    raise ToolError(msg, code)


# ---- files -----------------------------------------------------------------------
def num(s):
    """CSV cell -> float, tolerating '' (PowerShell's $null)."""
    try:
        return float(s)
    except (TypeError, ValueError):
        return 0.0


def read_csv(path):
    if not os.path.exists(path):
        return []
    # utf-8-sig: files written by Windows PowerShell 5.1 start with a BOM
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def write_text(path, text):
    """BOM-free write (a BOM once made slime_refine score seed 0)."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def run_capture(args, timeout=None):
    """Run a tool, return (exit code, combined stdout+stderr lines)."""
    try:
        p = subprocess.run(args, cwd=ROOT, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, errors="replace", timeout=timeout)
        return p.returncode, p.stdout.splitlines()
    except subprocess.TimeoutExpired as e:
        out = e.stdout or ""
        if isinstance(out, bytes):
            out = out.decode(errors="replace")
        return None, out.splitlines()


# ---- the position search: three tools, one answer ---------------------------------------------------
# slime_gpu (CUDA, NVIDIA) is fastest; slime_cl runs on any graphics card with an OpenCL driver (AMD, Intel, Apple);
# slime_cpu uses every core and always works. Same flags, same output, same tie-break.
SEARCH_TOOLS = ("slime_gpu", "slime_cl", "slime_cpu")
SEARCH_ON = {"slime_gpu": "the NVIDIA GPU", "slime_cl": "the graphics card (OpenCL)", "slime_cpu": "the CPU"}
_search_runs = {}


def search_runs(name):
    """Whether this search tool is built AND runs here (a 1-chunk search, tried once per process): the OpenCL one
    exits with an error on a machine with no driver, or a card that gets a different answer from the CPU."""
    if name not in _search_runs:
        ok = False
        if os.path.exists(tool(name)):
            rc, out = run_capture([tool(name), "--seed", "1", "--m-chunks", "1", "--center-x", "0", "--center-z", "0"], timeout=60)
            ok = rc == 0 and any(l.startswith("Best:") for l in out)
        _search_runs[name] = ok
    return _search_runs[name]


def searcher():
    """The fastest search tool that works here, or None."""
    return next((n for n in SEARCH_TOOLS if search_runs(n)), None)


# ---- remembered answers for ./slime's menu (a convenience only) --------------------------
PREFS = os.path.join(DATA, "slime_prefs.json")


def load_prefs():
    try:
        import json
        with open(PREFS) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_prefs(**changes):
    try:
        import json
        d = load_prefs()
        d.update({k: v for k, v in changes.items() if v is not None})
        os.makedirs(os.path.dirname(PREFS), exist_ok=True)
        with open(PREFS, "w") as f:
            json.dump(d, f, indent=1)
    except Exception:
        pass


# ---- the .ps1 scripts ---------------------------------------------------------------
def ps_command():
    """How to start a .ps1 here: PowerShell 7 (pwsh) on Linux, Windows PowerShell on Windows.
    Returns the argument list up to and including -File, or None if no PowerShell is found."""
    import shutil
    if os.name == "nt":
        exe = shutil.which("powershell") or shutil.which("pwsh")
        return [exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"] if exe else None
    exe = shutil.which("pwsh") or next((p for p in [os.path.expanduser("~/.local/bin/pwsh"), "/usr/bin/pwsh"]
                                        if os.path.exists(p)), None)
    return [exe, "-NoProfile", "-File"] if exe else None


# ---- the slime-chunk formula, for drawing maps --------------------------------------------
# The same isSlimeChunk as slime_core.h (WorldgenRandom.seedSlimeChunk(x, z, seed, 987234911)
# .nextInt(10) == 0), for slime_studio.py's map. vanilla_parity.py checks it against the game bit for
# bit, like the C++ one. It only DRAWS: every number the toolchain reports comes from the tools.
_M48 = (1 << 48) - 1


def _i32(v):
    return ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000


_XOR = 0x3ad8025f ^ 0x5DEECE66D      # the slime salt, then Random's own scramble
_XTERMS = {}


def _xterms(cx0, n):
    """(int)(x*x*0x4c1906) + (int)(x*0x5ac0db) for x = cx0 .. cx0+n-1: the half of the seed mix that doesn't
    depend on the row, so a map works it out once and reuses it for every row."""
    k = (cx0, n)
    t = _XTERMS.get(k)
    if t is None:
        if len(_XTERMS) > 64:
            _XTERMS.clear()
        t = _XTERMS[k] = [_i32(x * x * 0x4c1906) + _i32(x * 0x5ac0db) for x in range(cx0, cx0 + n)]
    return t


def _next_int10(s):
    """Random.nextInt(10) from scrambled state s, rejection loop and all."""
    while True:
        s = (s * 0x5DEECE66D + 0xB) & _M48
        bits = s >> 17
        val = bits % 10
        if bits - val + 9 < 0x80000000:           # Java's int-overflow rejection
            return val


def slime_row(seed, cx0, cz, n):
    """bytearray of n flags: is chunk (cx0 + i, cz) a slime chunk. Java's int-overflow terms exactly:
    (int)(x*x*0x4c1906) + (int)(x*0x5ac0db) + (long)(int)(z*z)*0x4307a7 + (int)(z*0x5f24f).
    nextInt(10) only rejects a first draw of 2,147,483,640 or more (bits - bits % 10 + 9 overflows an int),
    about 1 chunk in 270 million, so the common case is one step and the loop runs only for those."""
    base = seed + _i32(cz * cz) * 0x4307a7 + _i32(cz * 0x5f24f)
    out = bytearray(n)
    for i, xt in enumerate(_xterms(cx0, n)):
        s = ((base + xt) ^ _XOR) & _M48
        bits = ((s * 0x5DEECE66D + 0xB) & _M48) >> 17
        if bits < 2147483640:
            if not bits % 10:
                out[i] = 1
        elif _next_int10(s) == 0:
            out[i] = 1
    return out


def is_slime_chunk(seed, cx, cz):
    return bool(slime_row(seed, cx, cz, 1)[0])


FLOOR_RADIUS = 152   # perimeter_gen/src/Perimeter.c RADIUS


def floor_block(slime, ax, az, bx, bz):
    """What the perimeter commands leave at floor block (bx, bz) for a farm centred on block (ax, az) -
    perimeter_gen's own rule: 'obsidian' in every slime chunk of the floor box (the chunks within +-152),
    'magma' on every other block touching one of those, diagonals included (the border grid is the box
    plus one block), 'glass' over the rest of the cleared area (the box plus a chunk each side), None
    outside it. slime(cx, cz) -> bool. vanilla_parity.py checks this against the commands, block by block."""
    cx0, cx1 = (ax - FLOOR_RADIUS) // 16, (ax + FLOOR_RADIUS) // 16
    cz0, cz1 = (az - FLOOR_RADIUS) // 16, (az + FLOOR_RADIUS) // 16
    if not ((cx0 - 1) * 16 <= bx <= (cx1 + 1) * 16 + 15 and (cz0 - 1) * 16 <= bz <= (cz1 + 1) * 16 + 15):
        return None
    floor = lambda cx, cz: cx0 <= cx <= cx1 and cz0 <= cz <= cz1 and slime(cx, cz)
    cx, cz = bx // 16, bz // 16
    if floor(cx, cz):
        return "obsidian"
    if cx0 * 16 - 1 <= bx <= (cx1 + 1) * 16 and cz0 * 16 - 1 <= bz <= (cz1 + 1) * 16 and (
            bx % 16 in (0, 15) or bz % 16 in (0, 15)):     # only a block on a chunk's edge can touch another
        for dx in (-1, 0, 1):
            for dz in (-1, 0, 1):
                n = ((bx + dx) // 16, (bz + dz) // 16)
                if n != (cx, cz) and floor(*n):
                    return "magma"
    return "glass"


# ---- perimeter generator version bands --------------------------------------------
# perimeter_gen/src/Perimeter.c VERSION_*: pick the closest band at or below
# the game version.
PERIMETER_BANDS = [((1, 13), "1.13 - 1.17"), ((1, 18), "1.18 - 1.20.4"),
                   ((1, 20, 5), "1.20.5 - 1.21.10"), ((1, 21, 11), "1.21.11 and later")]


def perimeter_band(version):
    """'1.21.11' -> 3; None if older than 1.13 or not a release version."""
    try:
        t = tuple(int(p) for p in version.split("."))
    except ValueError:
        return None
    band = None
    for i, (lo, _) in enumerate(PERIMETER_BANDS):
        if t >= lo:
            band = i
    return band


def run_perimeter_gen(seed, x, z, band, out_dir):
    """Run the (interactive) generator with piped answers; returns the path of
    the commands file it wrote, or raises with its output."""
    exe = os.path.join(ROOT, "perimeter_gen", "perimeter_gen" + EXE)
    if not os.path.exists(exe):
        die("missing perimeter_gen/perimeter_gen%s - run %s" % (EXE, "build.ps1" if EXE else "./build.sh"))
    os.makedirs(out_dir, exist_ok=True)
    r = subprocess.run([exe], cwd=out_dir, input="%d\n%d\n%d\n%d\n" % (seed, x, z, band),
                       capture_output=True, text=True)
    for l in r.stdout.splitlines():
        if l.startswith("perimeter_") and l.endswith(".txt"):
            return os.path.join(out_dir, l), r.stdout
    raise RuntimeError("perimeter_gen failed:\n" + r.stdout[-600:] + r.stderr[-600:])
