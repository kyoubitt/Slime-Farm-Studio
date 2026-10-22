#!/usr/bin/env python3
"""slime_studio.py - SlimeByte: the toolchain as a full-screen app in your terminal.

  ./slime gui                 (Windows: python slime gui)

Three tabs:
  1 Find spot           seed, version, Best AFK / Cluster / Manual, and a live slime-chunk map with the
                        24-128 spawn ring and the r=152 perimeter (scroll to zoom, drag to pan)
  2 Perimeter commands  every command perimeter_gen wrote, a Copy button on each line
  3 Build guide         the in-game steps, the best standing height, saving your /perimeterinfo reading

It scores nothing itself: Find runs slime_gpu + slime_refine, Generate runs perimeter_gen, the heights run
afk_rescan - through the same functions ./slime uses, so every number matches the terminal commands. The
map is drawn from slime_common.slime_row, which vanilla_parity.py checks against the game.

Runs in any modern terminal - Windows Terminal / PowerShell, macOS Terminal and iTerm2, every Linux
terminal. The mouse works wherever the terminal reports it; the keyboard works everywhere. In terminals
that show pictures the map is a real picture with thin lines - kitty's graphics protocol in Ghostty and
kitty, Sixel in Windows Terminal 1.22+, WezTerm, iTerm2, foot, Konsole - and elsewhere (macOS Terminal,
the old Windows console) it's drawn with characters. Standard library only: nothing to install.
"""
import base64
import codecs
import io
import json
import math
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import unicodedata
import zlib

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from slime_common import (DATA, PERIMETER_BANDS, ROOT, SEARCH_ON, SEARCH_TOOLS, ToolError, floor_block,  # noqa: E402
                          load_prefs, perimeter_band, require_tools, run_perimeter_gen, save_prefs, searcher,
                          slime_row, tool)

PERIMETERS = os.path.join(DATA, "perimeters")
RESULTS = os.path.join(DATA, "studio_results.json")   # every finished search, so it never runs twice
TILES = os.path.join(DATA, "studio_tiles")            # each tile's answer, per seed: a stopped scan resumes
TILE_M = 16000                 # slime_gpu --m-chunks caps here (+-256,000 blocks per call)
EDGE = 1874000 - 8             # slime_gpu: |centre chunk| + m-chunks + 8 <= 1,874,000
WORLD_RANGE = 29_983_000       # the whole world, to within ~16k blocks of the border (slime_gpu's edge)
PRESETS = [("10k", 10_000), ("100k", 100_000), ("1M", 1_000_000), ("10M", 10_000_000), ("World", 30_000_000)]
# seconds per full tile through one --worker, as measured on a laptop (RTX 4050 / Radeon 680M / 6 cores): the first guess,
# replaced by this machine's own timing after its first big scan
TILE_S = {"slime_gpu": 0.03, "slime_cl": 0.35, "slime_cpu": 0.25}
LIMIT = 32500                  # characters a command block holds
RADIUS = 152                   # perimeter_gen/src/Perimeter.c RADIUS
WORLD = 30_000_000

# ---- colours: the RedenMC slime farm generator's ----------------------------------------------------------------
# A calm, light tool: a sage-white page, white cards with a title bar, deep-green text, one forest-green accent,
# and a dark green map. Values from its own stylesheet and map code. Dark is the same page at night: deep
# green-black cards around the map's own green, the accent lifted so it still reads, dark text on it.
THEMES = {
    "light": dict(
        PAGE=0xf1f3ee, CARD_BG=0xffffff, PANEL2=0xe9eee6, LINE=0xd5dcd2,
        TEXT=0x26352b, MUTED=0x5f6d62,
        GREEN=0x32623c, GREEN_DARK=0x244e2d, ON_GREEN=0xffffff,   # the accent: main buttons, the tab you're on, focus
        VIOLET=0x655080, AMBER=0x805716, DANGER=0xa93232,
        FIELD_EDGE=0xb5c0b2, BTN_EDGE=0xb7c3b2, BTN_HOVER=0xedf3e8,
        PICK_BG=0xeaf2e4, PICK_EDGE=0x91ac84,                    # the chosen row of a choice
        NOTE_BG=0xf1f4ed, NOTE_TEXT=0x4d6051, NOTE_EDGE=0xd7e0d0,
        WARN_BG=0xfaf4e5, WARN_TEXT=0x79531a, WARN_EDGE=0xe5d6af,
        ERR_BG=0xfff0eb, ERR_TEXT=0x9a302d, ERR_EDGE=0xe1b7af,
        STAT_BG=0xe5ecdf, STAT_EDGE=0xccd8c4, STAT_LABEL=0x56674f, STAT_ACCENT=0x294f31,
        COORD_BG=0xf2f5ee, COORD_EDGE=0xd5dfce, COORD_TEXT=0x295b35,
        TRACK=0xe0e7da, TOAST_BG=0x294d33, TOAST_TEXT=0xffffff),
    "dark": dict(
        PAGE=0x0f1712, CARD_BG=0x16201a, PANEL2=0x1c2821, LINE=0x2a3830,
        TEXT=0xdbe5dd, MUTED=0x91a295,
        GREEN=0x5c9f6e, GREEN_DARK=0x7cc08f, ON_GREEN=0x0c1710,   # lighter with focus here, not darker
        VIOLET=0xb4a2dc, AMBER=0xe2b46a, DANGER=0xee7d70,
        FIELD_EDGE=0x3b4c41, BTN_EDGE=0x3d4f43, BTN_HOVER=0x213027,
        PICK_BG=0x1f3626, PICK_EDGE=0x4f8a5f,
        NOTE_BG=0x1a261f, NOTE_TEXT=0xb2c3b5, NOTE_EDGE=0x2d3f34,
        WARN_BG=0x2a2417, WARN_TEXT=0xe8c47c, WARN_EDGE=0x584a27,
        ERR_BG=0x2e1b19, ERR_TEXT=0xf29d91, ERR_EDGE=0x69342e,
        STAT_BG=0x1b2921, STAT_EDGE=0x2e4136, STAT_LABEL=0x91a295, STAT_ACCENT=0x9dd8ad,
        COORD_BG=0x1a261f, COORD_EDGE=0x2e4136, COORD_TEXT=0x92d2a3,
        TRACK=0x26342c, TOAST_BG=0x22392b, TOAST_TEXT=0xa9dcb5),
}
THEME = "light"


def apply_theme(name):
    """Swap the page's colours (the map keeps its own, dark in both). Every colour is read when it's drawn."""
    global THEME, BG
    THEME = name if name in THEMES else "light"
    globals().update(THEMES[THEME])
    BG = PAGE


apply_theme("light")
# the map: dark green, teal slime chunks, a violet 128 circle, a dashed amber 24 one, the AFK spot a pale-yellow cross
WHITE = 0xffffff
MAP_BG, SLIME, SLIME_LABEL, GRID = 0x17251f, 0x397e70, 0xa7dece, 0x24363a
RING128, RING24, FLOOR_SQ, SEARCH_SQ, MARK = 0xa594ee, 0xffd68e, 0x88adc5, 0x5db8ac, 0xffe2a0
INFO_BG, INFO_EDGE, INFO_TEXT, AXIS = 0x1c3028, 0x52665b, 0xd5e2d8, 0x9aaec8
OBSIDIAN, MAGMA, GLASS_RGB, GLASS_A = 0x3c345e, 0xe69058, 0x41657d, 220 / 255   # the blocks, as their layer image
SLIME_DIM = 0x19322f                                            # slime chunks under the Floor view
GLASS = 0x3b5c70                                                # their glass at 220/255 over the map, flat
GRID_FINE, GRID_COARSE, GRID_BLOCK = (0x9fbad4, 0x25 / 255), (0x527092, 0x30 / 255), (0xa2b4da, 0x18 / 255)
COMPASS = 0xb9cae0
CLEAR = -1                       # a cell left on the terminal's own background: where the map picture shows through

SECTIONS = [(0, "Seed", None), (1, "Teleport", None), (2, "Clear the area", "WorldEdit"), (3, "Slime floor", None),
            (4, "Magma border", None), (5, "Glass skirt", "WorldEdit"), (6, "Measure", "Carpet")]
SECTION_INFO = {
    0: "Type it in the world creation screen.",
    1: "Paste each line in chat. It takes you above the farm, turns mob spawning off, and /seed confirms the world.",
    2: "Clears from the floor to 24 above it. //replace air only touches blocks that aren't air, so it's far "
       "faster than //set air.",
    3: "Paste into one command block and power it with a button. It puts obsidian in every slime chunk, then "
       "cleans up after itself.",
    4: "The same again once the floor is done: magma around every slime chunk.",
    5: "Glass across the cleared area at floor level.",
    6: "A repeating command block that runs /perimeterinfo where you stand.",
}
MODES = [("best", "Best AFK", "exact"), ("cluster", "Cluster", "chunk count"), ("manual", "Manual", "your spot")]
MODE_NOTE = {
    "best": "The AFK block with the most spawning spaces around it, scored block by block.",
    "cluster": "The spot with the most slime chunks in the 24 to 128 ring. Faster, to the chunk.",
    "manual": "Your own AFK spot: type it below, or click the map.",
}
HELP = [("Keys", None), ("tab, shift+tab, up, down", "move between controls"), ("enter, space", "press or choose"),
        ("left, right", "change a choice: search type, range, version"), ("1  2  3", "switch tabs"),
        ("f", "find or score"), ("g", "generate the commands"), ("u", "build the perimeter at the AFK spot"),
        ("c", "back to the farm on the map"), ("+  -", "zoom the map"), ("t", "light or dark colours"),
        ("esc", "stop a search, close this"),
        ("q, ctrl+c", "quit"), ("", None), ("Mouse", None), ("click", "press; on the map in Manual, place the AFK spot"),
        ("scroll", "zoom the map, scroll a column"), ("drag", "move the map")]
SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
# the game-version menu, newest first: (band, what the box says, the releases it covers). Bands 0-3 are what
# perimeter_gen writes commands for; OLD is the one it can't (before 1.13 the commands differ), where the map,
# search and AFK scoring still work - the version never changes the slime chunks.
OLD = len(PERIMETER_BANDS)
VERSIONS = [(3, "1.21.11 and newer", "1.21.11, 26.1 and later"),
            (2, "1.20.5 - 1.21.10", "1.20.5, 1.20.6, 1.21 - 1.21.10"),
            (1, "1.18 - 1.20.4", "1.18, 1.19, 1.20 - 1.20.4"),
            (0, "1.13 - 1.17", "1.13, 1.14 ... 1.17"),
            (OLD, "1.12 and older", "map and search only")]


def band_name(b):
    return next(n for k, n, _ in VERSIONS if k == b)


def fmt(n):
    return format(int(n), ",")


def mix(a, b, t):
    """Colour a blended toward b by t (0..1)."""
    ar, ag, ab = a >> 16, (a >> 8) & 255, a & 255
    return (round(ar + ((b >> 16) - ar) * t) << 16) | (round(ag + (((b >> 8) & 255) - ag) * t) << 8) | \
        round(ab + ((b & 255) - ab) * t)


def short_dist(d):
    return fmt(d) if d < 10_000 else ("%dk" % round(d / 1000) if d < 1_000_000 else "%.1fM" % (d / 1e6))


# ---- text width (seeds can be any text, even CJK or emoji) -------------------------------------------------
def cwidth(c):
    o = ord(c)
    if o < 0x300:
        return 1 if o >= 32 and o != 127 else 0
    if unicodedata.combining(c) or unicodedata.category(c) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1


def twidth(s):
    return sum(cwidth(c) for c in s)


def wrap(text, w):
    w = max(1, w)
    out = []
    for para in str(text).split("\n"):
        line = ""
        for word in para.split(" "):
            while len(word) > w:
                if line:
                    out.append(line)
                    line = ""
                out.append(word[:w])
                word = word[w:]
            if not line:
                line = word
            elif len(line) + 1 + len(word) <= w:
                line += " " + word
            else:
                out.append(line)
                line = word
        out.append(line)
    return out


# ---- the terminal --------------------------------------------------------------------------------------------
def color_mode():
    v = os.environ.get("SLIME_COLORS", "").lower()
    if v in ("256", "truecolor"):
        return v
    if os.environ.get("COLORTERM", "").lower() in ("truecolor", "24bit") or os.environ.get("WT_SESSION") or \
            os.environ.get("TERM_PROGRAM") in ("iTerm.app", "WezTerm", "vscode", "ghostty", "Hyper", "Tabby"):
        return "truecolor"
    term = os.environ.get("TERM", "")
    if os.name == "nt" or any(t in term for t in ("kitty", "ghostty", "alacritty", "foot", "wezterm", "direct")):
        return "truecolor"
    return "256"            # macOS Terminal.app and anything unknown


def to256(c):
    r, g, b = c >> 16, (c >> 8) & 255, c & 255
    q = [0 if v < 48 else 1 if v < 115 else (v - 35) // 40 for v in (r, g, b)]
    cv = [0 if k == 0 else 55 + 40 * k for k in q]
    gi = max(0, min(23, round(((r + g + b) / 3 - 8) / 10)))
    gv = 8 + 10 * gi
    if (r - gv) ** 2 + (g - gv) ** 2 + (b - gv) ** 2 < sum((a - b2) ** 2 for a, b2 in zip((r, g, b), cv)):
        return 232 + gi
    return 16 + 36 * q[0] + 6 * q[1] + q[2]


_SGR = {}


def sgr(fg, bg, bold, mode):
    """The escape sequence for a cell's colours (CLEAR: the terminal's own background)."""
    k = (fg, bg, bold, mode)
    if k not in _SGR:
        if mode == "truecolor":
            b = "49" if bg == CLEAR else "48;2;%d;%d;%d" % (bg >> 16, (bg >> 8) & 255, bg & 255)
            _SGR[k] = "\x1b[0;%s38;2;%d;%d;%d;%sm" % ("1;" if bold else "", fg >> 16, (fg >> 8) & 255, fg & 255, b)
        else:
            b = "49" if bg == CLEAR else "48;5;%d" % to256(bg)
            _SGR[k] = "\x1b[0;%s38;5;%d;%sm" % ("1;" if bold else "", to256(fg), b)
    return _SGR[k]


class Term:
    """Raw keyboard + SGR mouse + the alternate screen, on Windows (console API) and everywhere else (termios)."""
    WIN_KEYS = {"H": "A", "P": "B", "M": "C", "K": "D", "G": "H", "O": "F"}

    def __init__(self):
        self.win = os.name == "nt"
        self.out = sys.__stdout__.buffer
        self.colors = color_mode()
        self.dec = codecs.getincrementaldecoder("utf-8")("replace")
        self.graphics, self.cell_q, self.stash = False, None, ""

    def start(self):
        if self.win:
            import ctypes
            from ctypes import wintypes
            k = ctypes.WinDLL("kernel32", use_last_error=True)
            self.k, self.hin, self.hout = k, k.GetStdHandle(-10), k.GetStdHandle(-11)
            m = wintypes.DWORD()
            if not k.GetConsoleMode(self.hin, ctypes.byref(m)):
                raise OSError("not a console")
            self.old_in = m.value
            k.GetConsoleMode(self.hout, ctypes.byref(m))
            self.old_out = m.value
            self.old_cp = (k.GetConsoleCP(), k.GetConsoleOutputCP())
            k.SetConsoleCP(65001)
            k.SetConsoleOutputCP(65001)
            # VT input (keys and mouse arrive as escape sequences), no line editing / echo / Ctrl+C signal / QuickEdit
            k.SetConsoleMode(self.hin, (self.old_in | 0x0200 | 0x0080) & ~(0x0001 | 0x0002 | 0x0004 | 0x0040))
            if not k.SetConsoleMode(self.hout, self.old_out | 0x0004 | 0x0008):
                k.SetConsoleMode(self.hout, self.old_out | 0x0004)
        else:
            import termios
            self.fd = sys.stdin.fileno()
            self.old = termios.tcgetattr(self.fd)
            t = termios.tcgetattr(self.fd)
            t[0] &= ~(termios.BRKINT | termios.ICRNL | termios.INPCK | termios.ISTRIP | termios.IXON)
            t[2] |= termios.CS8
            t[3] &= ~(termios.ECHO | termios.ICANON | termios.IEXTEN | termios.ISIG)
            t[6][termios.VMIN], t[6][termios.VTIME] = 0, 0
            termios.tcsetattr(self.fd, termios.TCSAFLUSH, t)
        # alt screen, hide cursor, no autowrap, mouse (click, drag, motion; SGR coordinates), bracketed paste
        self.write(b"\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[2J")
        self.graphics = self.probe_graphics()

    def probe_graphics(self):
        """Can this terminal show the map as a picture, and how?
          "kitty"  Ghostty and kitty: kitty's graphics protocol, the picture under the cells' own backgrounds
                   and the words on top.
          "sixel"  any terminal whose device attributes include 4 (Sixel): Windows Terminal 1.22+, WezTerm,
                   foot, iTerm2, Konsole, ... The picture becomes part of the cells; the words go back on it.
        Asked the protocols' way: the kitty query (only where kitty is expected), the cell size, then the
        device attributes, which every terminal answers - so macOS Terminal and the old Windows console just
        answer without a 4 and keep the character map. Kitty is off inside tmux / screen, which don't pass it
        on. SLIME_MAP=text, =kitty (or =image) or =sixel overrides it."""
        v = os.environ.get("SLIME_MAP", "").lower()
        if v == "text":
            return False
        env = os.environ.get
        kitty = v in ("kitty", "image") or (not env("TMUX") and not env("STY") and bool(
            env("TERM_PROGRAM") == "ghostty" or env("GHOSTTY_RESOURCES_DIR") or env("KITTY_WINDOW_ID") or
            env("TERM", "") in ("xterm-ghostty", "xterm-kitty")))
        self.write((b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\" if kitty else b"") + b"\x1b[16t\x1b[c")
        buf, end, da = "", time.monotonic() + 1.0, None
        while time.monotonic() < end and not da:
            buf += self.read(0.05)
            da = re.search(r"\x1b\[\?([0-9;]*)c", buf)
        m = re.search(r"\x1b\[6;(\d+);(\d+)t", buf)
        if m and int(m[1]) and int(m[2]):
            self.cell_q = (int(m[2]), int(m[1]))
        self.stash = re.sub(r"\x1b_G[^\x1b]*\x1b\\|\x1b\[6;\d+;\d+t|\x1b\[\?[0-9;]*c", "", buf)   # keys typed meanwhile
        if v in ("kitty", "image") or (kitty and "\x1b_Gi=31;OK" in buf):
            return "kitty"
        if v == "sixel" or (da and "4" in da[1].split(";")):
            return "sixel"
        return False

    def cell_px(self):
        """(width, height) of one cell in the picture protocol's pixels, or None if the terminal won't say."""
        if self.graphics == "sixel" and self.cell_q:
            return self.cell_q                         # the size it said it draws Sixel with
        if not self.win:
            try:
                import fcntl
                import struct
                import termios
                r, c, xp, yp = struct.unpack("HHHH", fcntl.ioctl(sys.__stdout__.fileno(), termios.TIOCGWINSZ, b"\0" * 8))
                if r and c and xp and yp:
                    return xp / c, yp / r
            except Exception:
                pass
        return self.cell_q or ((10, 20) if self.graphics == "sixel" else None)   # Windows Terminal's Sixel cell

    def stop(self):
        if self.graphics == "kitty":
            self.write(b"".join(b"\x1b_Ga=d,d=I,i=%d,q=2\x1b\\" % i for i in PIC_IDS))
        self.write(b"\x1b[0m\x1b[?2004l\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?7h\x1b[?25h\x1b[?1049l")
        if self.win:
            self.k.SetConsoleMode(self.hin, self.old_in)
            self.k.SetConsoleMode(self.hout, self.old_out)
            self.k.SetConsoleCP(self.old_cp[0])
            self.k.SetConsoleOutputCP(self.old_cp[1])
        else:
            import termios
            termios.tcsetattr(self.fd, termios.TCSAFLUSH, self.old)

    def write(self, data):
        self.out.write(data)
        self.out.flush()

    def size(self):
        try:
            s = os.get_terminal_size(sys.__stdout__.fileno())
            return s.columns, s.lines
        except OSError:
            return 80, 24

    def read(self, timeout):
        if self.stash:                                 # what came in while asking the terminal about pictures
            out, self.stash = self.stash, ""
            return out
        if self.win:
            import msvcrt
            end, out = time.monotonic() + timeout, []
            while True:
                while msvcrt.kbhit():
                    c = msvcrt.getwch()
                    if c in ("\x00", "\xe0"):          # a console without VT input: arrows etc. as scan codes
                        k = self.WIN_KEYS.get(msvcrt.getwch())
                        c = "\x1b[" + k if k else ""
                    out.append(c)
                if out or time.monotonic() >= end:
                    return "".join(out)
                time.sleep(0.008)
        import select
        r, _, _ = select.select([self.fd], [], [], timeout)
        return self.dec.decode(os.read(self.fd, 65536)) if r else ""


CSI = re.compile(r"\x1b\[([<?]?)([0-9;:]*)([\x40-\x7e])")
CSI_PART = re.compile(r"\x1b\[[<?]?[0-9;:]*$")
KEYS = {"A": "up", "B": "down", "C": "right", "D": "left", "H": "home", "F": "end", "Z": "btab"}
TILDE = {"1": "home", "2": "insert", "3": "delete", "4": "end", "5": "pgup", "6": "pgdn", "7": "home", "8": "end"}


def parse_input(buf):
    """Terminal input -> events: ("key", name), ("char", c), ("paste", text), ("mouse", kind, x, y, button).
    Returns (events, unparsed tail) - a tail is an escape sequence cut off mid-read."""
    ev, i, n = [], 0, len(buf)
    while i < n:
        c = buf[i]
        if c == "\x1b":
            if buf.startswith("\x1b[200~", i):
                j = buf.find("\x1b[201~", i + 6)
                if j < 0:
                    return ev, buf[i:]
                ev.append(("paste", buf[i + 6:j]))
                i = j + 6
                continue
            if i + 1 >= n:
                return ev, buf[i:]
            nx = buf[i + 1]
            if nx == "[":
                m = CSI.match(buf, i)
                if not m:
                    if CSI_PART.match(buf, i):
                        return ev, buf[i:]
                    ev.append(("key", "esc"))
                    i += 1
                    continue
                pre, params, fin = m.groups()
                i = m.end()
                if pre == "<" and fin in "Mm":
                    p = params.split(";")
                    if len(p) >= 3 and all(v.isdigit() for v in p[:3]):
                        b, x, y = int(p[0]), int(p[1]) - 1, int(p[2]) - 1
                        if b & 64:
                            if b & 3 in (0, 1):
                                ev.append(("mouse", "wheelup" if b & 3 == 0 else "wheeldown", x, y, 0))
                        elif b & 32:
                            ev.append(("mouse", "move" if b & 3 == 3 else "drag", x, y, b & 3))
                        else:
                            ev.append(("mouse", "release" if fin == "m" else "press", x, y, b & 3))
                    continue
                name = TILDE.get(params.split(";")[0]) if fin == "~" else KEYS.get(fin)
                if name:
                    ev.append(("key", name))
                continue
            if nx == "O":
                if i + 2 >= n:
                    return ev, buf[i:]
                name = KEYS.get(buf[i + 2])
                if name:
                    ev.append(("key", name))
                i += 3
                continue
            ev.append(("key", "alt"))
            i += 2
            continue
        if c == "\r" or c == "\n":
            ev.append(("key", "enter"))
            if c == "\r" and buf[i + 1:i + 2] == "\n":
                i += 1
        elif c == "\t":
            ev.append(("key", "tab"))
        elif c in "\x7f\x08":
            ev.append(("key", "backspace"))
        elif ord(c) < 32:
            ev.append(("key", "ctrl+" + chr(ord(c) + 96)))
        else:
            ev.append(("char", c))
        i += 1
    return ev, ""


# ---- the screen: a cell buffer, written as a diff against the last frame ----------------------------------------
class Screen:
    def __init__(self, w, h):
        self.w, self.h = w, h
        n = w * h
        self.ch, self.fg, self.bg, self.bd = [" "] * n, [TEXT] * n, [BG] * n, [False] * n
        self.clips = [(0, 0, w, h)]

    def push(self, x0, y0, x1, y1):
        a = self.clips[-1]
        self.clips.append((max(a[0], x0), max(a[1], y0), min(a[2], x1), min(a[3], y1)))

    def pop(self):
        self.clips.pop()

    def _set(self, i, row, c, fg, bg, bold):
        # keep wide characters consistent: overwriting either half of one blanks the other half
        if self.ch[i] == "" and i > row:
            self.ch[i - 1] = " "
        if i + 1 < row + self.w and self.ch[i + 1] == "" and c != "" and cwidth(c[0]) != 2:
            self.ch[i + 1] = " "
        self.ch[i], self.fg[i], self.bd[i] = c, fg, bold
        if bg is not None:
            self.bg[i] = bg

    def put(self, x, y, text, fg=None, bg=None, bold=False):
        fg = TEXT if fg is None else fg
        x0, y0, x1, y1 = self.clips[-1]
        if not y0 <= y < y1:
            return x + twidth(text)
        row = y * self.w
        for c in text:
            w = cwidth(c)
            if w == 0:
                if c >= " " and x0 < x <= x1:
                    self.ch[row + x - 1] += c
                continue
            if x0 <= x < x1:
                if w == 2 and x + 1 >= x1:
                    c, w = " ", 1
                self._set(row + x, row, c, fg, bg, bold)
                if w == 2:
                    self._set(row + x + 1, row, "", fg, bg, bold)
            x += w
        return x

    def fill(self, x, y, w, h, bg, c=" ", fg=None):
        fg = TEXT if fg is None else fg
        x0, y0, x1, y1 = self.clips[-1]
        for yy in range(max(y, y0), min(y + h, y1)):
            row = yy * self.w
            for xx in range(max(x, x0), min(x + w, x1)):
                self._set(row + xx, row, c, fg, bg, False)

    def tint(self, x, y, w, h, frm, to):
        x0, y0, x1, y1 = self.clips[-1]
        for yy in range(max(y, y0), min(y + h, y1)):
            row = yy * self.w
            for xx in range(max(x, x0), min(x + w, x1)):
                if self.bg[row + xx] == frm:
                    self.bg[row + xx] = to

    def hline(self, x, y, w, color, c="─"):
        self.put(x, y, c * max(0, w), color)

    def box(self, x, y, w, h, color):
        if w < 2 or h < 2:
            return
        self.put(x, y, "╭" + "─" * (w - 2) + "╮", color)
        for yy in range(y + 1, y + h - 1):
            self.put(x, yy, "│", color)
            self.put(x + w - 1, yy, "│", color)
        self.put(x, y + h - 1, "╰" + "─" * (w - 2) + "╯", color)

    def diff(self, prev, mode):
        out, cur, W = [], None, self.w
        full = prev is None or prev.w != self.w or prev.h != self.h
        if full:
            out.append("\x1b[0m\x1b[2J")
        style = lambda fg, bg, bold: sgr(fg, bg, bold, mode)

        for y in range(self.h):
            a, b = y * W, y * W + W
            if full:
                lo, hi = a, b - 1
            else:
                ch, fg, bg, bd = self.ch, self.fg, self.bg, self.bd
                pch, pfg, pbg, pbd = prev.ch, prev.fg, prev.bg, prev.bd
                lo = next((i for i in range(a, b) if ch[i] != pch[i] or fg[i] != pfg[i] or bg[i] != pbg[i]
                           or bd[i] != pbd[i]), None)
                if lo is None:
                    continue
                hi = next(i for i in range(b - 1, lo - 1, -1) if ch[i] != pch[i] or fg[i] != pfg[i] or
                          bg[i] != pbg[i] or bd[i] != pbd[i])
                if self.ch[lo] == "" and lo > a:
                    lo -= 1
                if hi + 1 < b and self.ch[hi + 1] == "":
                    hi += 1
            out.append("\x1b[%d;%dH" % (y + 1, lo - a + 1))
            i = lo
            while i <= hi:
                c = self.ch[i]
                st = (self.fg[i], self.bg[i], self.bd[i])
                if st != cur:
                    out.append(style(*st))
                    cur = st
                if c == "":
                    c = " "                     # an orphaned second half
                out.append(c)
                if c and cwidth(c[0]) == 2:
                    i += 1                      # the terminal drew both halves
                i += 1
        out.append("\x1b[0m")
        return "".join(out).encode("utf-8", "replace")

    def changed(self, prev, x, y, w, h):
        """Does any cell of the rectangle differ from prev?"""
        if prev is None or (prev.w, prev.h) != (self.w, self.h):
            return True
        for yy in range(y, y + h):
            a, b = yy * self.w + x, yy * self.w + x + w
            if self.ch[a:b] != prev.ch[a:b] or self.fg[a:b] != prev.fg[a:b] or self.bg[a:b] != prev.bg[a:b] or \
                    self.bd[a:b] != prev.bd[a:b]:
                return True
        return False

    def patch(self, x, y, w, h, mode, clear_bg):
        """The rectangle's cells again, except blank ones left on the terminal's background - written over a
        Sixel picture, with clear_bg(x, y) as the background where the cell has the terminal's."""
        out, cur = [], None
        for yy in range(y, y + h):
            row, i, end = yy * self.w, x, x + w
            while i < end:
                k = row + i
                if self.ch[k] == "" or (self.ch[k] == " " and self.bg[k] == CLEAR):
                    i += 1
                    continue
                out.append("\x1b[%d;%dH" % (yy + 1, i + 1))
                while i < end and not (self.ch[row + i] == " " and self.bg[row + i] == CLEAR):
                    k = row + i
                    if self.ch[k] != "":
                        st = sgr(self.fg[k], clear_bg(i, yy) if self.bg[k] == CLEAR else self.bg[k], self.bd[k], mode)
                        if st != cur:
                            out.append(st)
                            cur = st
                        out.append(self.ch[k])
                    i += 1
        out.append("\x1b[0m")
        return "".join(out).encode("utf-8", "replace")


# ---- the map as a picture ---------------------------------------------------------------------------------------
PIC_IDS = (4242, 4243)           # two image ids, so the new picture is placed before the old one goes


_SIX = bytes((v + 63) & 255 for v in range(256))     # a 6-pixel column's bits -> its sixel character
_RUN = re.compile(rb"(.)\1{3,}")


class Picture:
    """The map in real pixels, drawn the way their canvas is: filled squares, 1-pixel grid lines, anti-aliased
    circles. One byte a pixel, an index into a palette of up to 256 colours (what Sixel needs; kitty gets
    it back as RGB), painted with whole-row slices and bytes.translate, so plain Python keeps up with
    dragging. Edges are anti-aliased in eighth steps, which keeps the palette small."""

    def __init__(self, w, h, rgb):
        self.w, self.h = w, h
        self.pal, self.ids, self.mixes, self.tabs = [], {}, {}, {}
        self.px = bytearray(self.code(rgb) * (w * h))

    def copy(self):
        p = Picture.__new__(Picture)
        p.w, p.h, p.px = self.w, self.h, bytearray(self.px)
        p.pal, p.ids, p.mixes, p.tabs = list(self.pal), dict(self.ids), dict(self.mixes), {}
        return p

    def index(self, rgb):
        i = self.ids.get(rgb)
        if i is None:
            if len(self.pal) < 256:
                i = len(self.pal)
                self.pal.append(rgb)
            else:                                          # full: the nearest colour already in it
                r, g, b = rgb >> 16, (rgb >> 8) & 255, rgb & 255
                i = min(range(256), key=lambda k: ((self.pal[k] >> 16) - r) ** 2 + (((self.pal[k] >> 8) & 255) - g) ** 2 +
                        ((self.pal[k] & 255) - b) ** 2)
            self.ids[rgb] = i
        return i

    def code(self, rgb):
        """rgb as one pixel's byte, for building rows."""
        return bytes((self.index(rgb),))

    def blend(self, i, rgb, a):
        k = (i, rgb, a)
        j = self.mixes.get(k)
        if j is None:
            j = self.mixes[k] = self.index(mix(self.pal[i], rgb, a))
        return j

    def rows(self, y0, y1, data):
        """Copy one whole pixel row (bytes, w long) to rows y0 .. y1-1."""
        w = self.w
        for y in range(max(0, y0), min(self.h, y1)):
            self.px[y * w:(y + 1) * w] = data

    def rect(self, x0, y0, x1, y1, rgb):
        x0, x1, y0, y1 = max(0, x0), min(self.w, x1), max(0, y0), min(self.h, y1)
        if x0 >= x1:
            return
        seg, w = self.code(rgb) * (x1 - x0), self.w
        for y in range(y0, y1):
            self.px[y * w + x0:y * w + x1] = seg

    def tint(self, x0, y0, x1, y1, rgb, a):
        """rgb at opacity a over the rectangle; a 1-pixel-wide one is a line."""
        x0, x1, y0, y1 = max(0, x0), min(self.w, x1), max(0, y0), min(self.h, y1)
        if x0 >= x1 or y0 >= y1 or a <= 0:
            return
        k = (rgb, round(a * 255))
        t, done = self.tabs.get(k) or self.tabs.setdefault(k, (bytearray(range(256)), set()))
        w, px = self.w, self.px
        if x1 - x0 == 1:                                   # a column: one strided slice
            parts = [slice(y0 * w + x0, (y1 - 1) * w + x0 + 1, w)]
        elif x0 == 0 and x1 == w:                          # whole rows: one slice
            parts = [slice(y0 * w, y1 * w)]
        else:
            parts = [slice(y * w + x0, y * w + x1) for y in range(y0, y1)]
        for sl in parts:
            seg = px[sl]
            for i in set(seg) - done:                      # blend only the colours that are there
                t[i] = self.blend(i, rgb, k[1] / 255)
                done.add(i)
            px[sl] = seg.translate(t)

    def dot(self, x, y, rgb, a):
        a = round(min(1.0, a) * 8) / 8
        if 0 <= x < self.w and 0 <= y < self.h and a > 0:
            o = y * self.w + x
            self.px[o] = self.blend(self.px[o], rgb, a)

    def ring(self, cx, cy, r, width, rgb, dash=None):
        """An anti-aliased circle line like canvas arc() + stroke(), dashed (on, off pixels along it) if asked."""
        hw = width / 2
        ro, ri = r + hw + 1, max(0.0, r - hw - 1)
        for y in range(max(0, math.floor(cy - ro)), min(self.h, math.ceil(cy + ro) + 1)):
            dy = y + 0.5 - cy
            o2 = ro * ro - dy * dy
            if o2 <= 0:
                continue
            xo, i2 = math.sqrt(o2), ri * ri - dy * dy
            spans = [(cx - xo, cx + xo)] if i2 <= 0 else [(cx - xo, cx - math.sqrt(i2)), (cx + math.sqrt(i2), cx + xo)]
            for lo, hi in spans:
                for x in range(max(0, math.floor(lo - 0.5)), min(self.w, math.ceil(hi + 0.5))):
                    dx = x + 0.5 - cx
                    cov = min(1.0, hw + 0.5 - abs(math.sqrt(dx * dx + dy * dy) - r))
                    if cov > 0 and not (dash and (math.atan2(dy, dx) * r) % (dash[0] + dash[1]) >= dash[0]):
                        self.dot(x, y, rgb, cov)

    def disc(self, cx, cy, r, rgb):
        for y in range(math.floor(cy - r - 1), math.ceil(cy + r + 1)):
            for x in range(math.floor(cx - r - 1), math.ceil(cx + r + 1)):
                self.dot(x, y, rgb, r + 0.5 - math.hypot(x + 0.5 - cx, y + 0.5 - cy))

    def dashed_rect(self, x0, y0, x1, y1, rgb, a, on, off):
        """A 1-pixel rectangle outline from (x0, y0) to (x1, y1) inclusive, dashed like canvas setLineDash."""
        for x in range(x0, x1 + 1, on + off):
            self.tint(x, y0, min(x + on, x1 + 1), y0 + 1, rgb, a)
            self.tint(x, y1, min(x + on, x1 + 1), y1 + 1, rgb, a)
        for y in range(y0, y1 + 1, on + off):
            self.tint(x0, y, x0 + 1, min(y + on, y1 + 1), rgb, a)
            self.tint(x1, y, x1 + 1, min(y + on, y1 + 1), rgb, a)

    def rgb(self):
        """The pixels as RGB bytes."""
        pal = self.pal + [0] * (256 - len(self.pal))
        out = bytearray(3 * len(self.px))
        for c, shift in enumerate((16, 8, 0)):
            out[c::3] = self.px.translate(bytes((v >> shift) & 255 for v in pal))
        return out

    def kitty(self, img_id, cols, rows):
        """The picture as kitty graphics: zlib-compressed RGB in 4 KB base64 chunks, placed at the cursor over
        cols x rows cells, under every cell that has its own background (so overlays like the help box cover
        it) but over the terminal's own, which is what the map cells are left on. q=2: no replies."""
        data = base64.standard_b64encode(zlib.compress(bytes(self.rgb()), 1))
        parts = [data[i:i + 4096] for i in range(0, len(data), 4096)] or [b""]
        out = [b"\x1b_Ga=T,f=24,o=z,s=%d,v=%d,i=%d,p=1,c=%d,r=%d,C=1,q=2,z=-1073741825,m=%d;%s\x1b\\" % (
            self.w, self.h, img_id, cols, rows, len(parts) > 1, parts[0])]
        out += [b"\x1b_Gm=%d;%s\x1b\\" % (k < len(parts) - 1, part) for k, part in enumerate(parts[1:], 1)]
        return b"".join(out)

    def sixel(self):
        """The picture as Sixel (Windows Terminal, WezTerm, foot, iTerm2, ...): square pixels (raster attributes
        1;1), the palette in percent, then bands of 6 rows - per colour in the band, each column's 6 bits
        (masks by translate, the rows joined as one big-integer OR), as characters from '?', repeats as !n."""
        w, h, px = self.w, self.h, self.px
        out = [b'\x1bP0;1;0q"1;1;%d;%d' % (w, h)]
        out += [b"#%d;2;%d;%d;%d" % (i, round((c >> 16) * 100 / 255), round(((c >> 8) & 255) * 100 / 255),
                                     round((c & 255) * 100 / 255)) for i, c in enumerate(self.pal)]
        masks = {}
        for y in range(0, h, 6):
            rows = [px[(y + r) * w:(y + r + 1) * w] for r in range(min(6, h - y))]
            band = []
            for k in sorted(set(px[y * w:min(h, y + 6) * w])):
                acc = 0
                for r, row in enumerate(rows):
                    if k in row:
                        t = masks.get((k, r))
                        if t is None:
                            t = bytearray(256)
                            t[k] = 1 << r
                            t = masks[(k, r)] = bytes(t)
                        acc |= int.from_bytes(row.translate(t), "big")
                line = acc.to_bytes(w, "big").translate(_SIX).rstrip(b"?")
                band.append(b"#%d" % k + _RUN.sub(lambda m: b"!%d%s" % (len(m[0]), m[1]), line))
            out.append(b"$".join(band) + (b"-" if y + 6 < h else b""))
        out.append(b"\x1b\\")
        return b"".join(out)


# ---- the work, run in a background thread so the window keeps drawing -------------------------------------------
class Job:
    def __init__(self, name):
        self.name, self.progress, self.t0, self.tile_s, self.frac = name, "", time.time(), 0.0, None
        self.cancel = threading.Event()


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    """Through a temporary file, so a crash mid-write never leaves half a file behind."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".tmp", "w") as f:
            json.dump(data, f, separators=(",", ":"))
        os.replace(path + ".tmp", path)
    except OSError:
        pass


def search_key(seed, mode, rng, x, z, floor_y=None):
    """What makes a search's answer: the same key, the same answer - every tool is deterministic."""
    return "%d %s %d %d %d" % (seed, mode, floor_y if mode == "manual" else rng, x, z)


def tiles_path(seed):
    return os.path.join(TILES, "%d.json" % seed)


def tiles_for(rng):
    """slime_gpu calls covering +-rng blocks: (offsets, m_chunks). One call up to +-256,000, else an n x n grid
    of equal tiles (n = 4 at the full 1M - the same 16 calls as ./slime best-spot; 118 x 118 for the world)."""
    n = max(1, math.ceil(rng / (TILE_M * 16)))
    m = min(max(1, math.ceil(rng / n / 16)), EDGE // n)
    offs = [(2 * i - n + 1) * m * 16 for i in range(n)]
    return [(dx, dz) for dx in offs for dz in offs], m


def eta(secs):
    secs = max(0, int(round(secs)))
    if secs < 60:
        return "%d s" % max(1, secs)
    if secs < 3600:
        return "%d min" % round(secs / 60)
    return "%d h %02d min" % (secs // 3600, secs % 3600 // 60)


def raise_no_search():
    raise ToolError("no search tool works here - run ./build.sh, then ./slime doctor")


def gpu_tiles(job, seed, centers, m, known=None):
    """Many fixed-seed position searches through ONE --worker (slime_gpu, slime_cl or slime_cpu): the start-up
    (~0.3 s, nearly all of a lone tile's time on a GPU) is paid once, so the whole world's 13,924 tiles take
    minutes on a graphics card, not an hour.
    Each line is the exact CLI search ./slime best-spot runs. Stops early on cancel; returns what it has.
    known: {"m cx cz": [chunks, x, z]} from earlier scans of this seed - those tiles aren't run again, and
    every new one is added to it."""
    known = {} if known is None else known
    todo = [c for c in centers if "%d %d %d" % (m, c[0], c[1]) not in known]
    out = [tuple(known["%d %d %d" % (m, c[0], c[1])]) for c in centers if "%d %d %d" % (m, c[0], c[1]) in known]
    if not todo:
        return out
    name = searcher() or raise_no_search()
    p = subprocess.Popen([tool(name), "--worker"], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, bufsize=1)
    try:
        if not any(l.strip() == "WORKER READY" for l in p.stdout):     # (a graphics driver may print its own lines first)
            raise ToolError("%s --worker didn't start - ./slime doctor checks your setup" % name)
        t0 = time.time()
        for k, (cx, cz) in enumerate(todo):
            if job.cancel.is_set():
                break
            p.stdin.write("--seed %d --m-chunks %d --center-x %d --center-z %d\n" % (seed, m, cx, cz))
            p.stdin.flush()
            best, err = None, None
            for line in p.stdout:
                hit = re.match(r"Best: score=(\d+) at x=(-?\d+) z=(-?\d+)", line)
                if hit:
                    best = (int(hit.group(1)), int(hit.group(2)), int(hit.group(3)))
                elif line.startswith("[WORKER]"):
                    err = line[8:].strip()
                elif line.startswith("===SPOT-DONE==="):
                    break
            if best is None:
                raise ToolError("%s: %s" % (name, err or "stopped mid-scan"))
            out.append(best)
            known["%d %d %d" % (m, cx, cz)] = list(best)
            el = time.time() - t0
            job.tile_s = el / (k + 1)
            done = len(centers) - len(todo) + k + 1
            job.progress = "tiles %s of %s, %s left" % (fmt(done), fmt(len(centers)),
                                                           eta(job.tile_s * (len(todo) - k - 1)))
            job.frac = done / len(centers)
    finally:
        try:
            p.stdin.write("--quit\n")
            p.stdin.flush()
        except OSError:
            pass
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
    return out


def search_worker(cli, job, seed, mode, rng, x, z):
    tiles, m = tiles_for(rng)
    if len(tiles) == 1:
        job.progress = "searching on " + SEARCH_ON[searcher() or raise_no_search()]
        cands = [cli.gpu_best(seed, x, z, m)]
    else:
        known = load_json(tiles_path(seed), {})
        before = len(known)
        cands = gpu_tiles(job, seed, [(x + dx, z + dz) for dx, dz in tiles], m, known)
        if len(known) > before:
            save_json(tiles_path(seed), known)
        if len(tiles) >= 16 and len(known) - before >= 16:
            save_prefs(**{"studio_tile_s_" + searcher(): round(job.tile_s * (m / TILE_M) ** -2, 4)})   # this machine's speed, per full tile
    if not cands:
        return None
    partial = len(cands) < len(tiles)
    cands.sort(key=lambda c: (-c[0], (c[1] - x) ** 2 + (c[2] - z) ** 2))   # most chunks, then nearest
    chunks, bx, bz = cands[0]
    res = {"mode": mode, "ring_chunks": chunks}
    if mode == "best":
        # the chunk count is the coarse key, the exact score the real one: score the best few block by
        # block (./slime best-spot scores each tile's winner; the world gets its top 32)
        refined, top = [], cands[:4 if partial else 32]
        for i, (c, cx, cz) in enumerate(top):
            if refined and job.cancel.is_set() and not partial:
                break
            job.progress = "exact score" + (" %d/%d" % (i + 1, len(top)) if len(top) > 1 else "")
            refined.append(cli.refine([seed], cx, cz, tag="studio")[0])
        refined.sort(key=lambda r: (-float(r["cq"]), (int(r["x"]) - x) ** 2 + (int(r["z"]) - z) ** 2))
        best = refined[0]
        bx, bz = int(best["x"]), int(best["z"])
        res.update(cq=best["cq"], blocks=int(best["blocks"]), ring_chunks=int(best["chunks_at_best_blocks"]),
                   verdict=verdict(cli, best["cq"]),
                   top=[{"x": int(r["x"]), "z": int(r["z"]), "cq": r["cq"], "blocks": int(r["blocks"])} for r in refined[:5]])
        cli.remember_farm(seed, bx, bz)
    else:
        res["top"] = [{"x": cx, "z": cz, "chunks": c} for c, cx, cz in cands[:5]]
    save_prefs(seed=seed)
    res.update(x=bx, z=bz, center=(x, z), range=rng, distance=int(math.hypot(bx - x, bz - z)), tiles=len(tiles),
               scanned=len(cands), partial=partial)
    return res


def verdict(cli, cq):
    return cli.verdict(cq).replace("try ./slime best-spot for this seed", "try a bigger search range")


def score_worker(cli, job, seed, x, z, floor_y):
    """One exact AFK block standing on the floor - afk_rescan at that point only."""
    require_tools("afk_rescan")
    b = int(cli.height_sweep(seed, x, z, window=0, floor_y=floor_y)[0]["blocks_y0"])
    return {"mode": "manual", "x": x, "z": z, "blocks": b, "cq": "%.2f" % (b / 256), "verdict": verdict(cli, b / 256)}


def perimeter_worker(cli, job, seed, x, z, band, remember=True):
    path, _ = run_perimeter_gen(seed, x, z, band, PERIMETERS)
    if remember:
        save_prefs(seed=seed, studio_band=band, studio_center=[x, z])
    return parse_commands(path)


def height_worker(cli, job, seed, x, z, floor_y):
    require_tools("afk_rescan")
    rows = cli.height_sweep(seed, x, z, window=48, floor_y=floor_y)
    best = cli.best_height(rows)
    cli.remember_farm(seed, x, z, best)
    pick = lambda r: {"feet_y": int(r["feet_y"]), "x": int(r["best_x"]), "z": int(r["best_z"]),
                      "vanilla": int(r["blocks_vanilla"]), "carpet": int(r["blocks_carpet"])}
    return {"seed": seed, "at": (x, z), "best": pick(best), "floor": int(rows[0]["blocks_y0"]),
            "heights": [pick(r) for r in rows]}


def measured_worker(cli, job, seed, x, z, feet_y, ingame, floor_y):
    path = cli.save_measured(seed, x, z, ingame)
    return {"saved": os.path.relpath(path, ROOT), "estimate": cli.estimate_at(seed, x, z, feet_y, floor_y),
            "ingame": ingame}


SECTION_RE = re.compile(r"^--- (\d+)\. (.*?) ---$")


def parse_commands(path):
    with open(path) as f:
        text = f.read()
    lines = text.splitlines()
    head = re.search(r"(\d+) slime chunks of (\d+), (\d+) blocks of floor, (\d+) magma border blocks", text)
    fy = re.search(r"floor y (-?\d+)", lines[0])
    sections, cur = {}, None
    for l in lines:
        m = SECTION_RE.match(l)
        if m:
            cur = sections[int(m.group(1))] = {"title": m.group(2), "lines": [], "chars": None, "fills": None}
        elif cur is not None and l.strip():
            st = re.match(r"^\((\d+) characters, (\d+) fills", l)
            if st:
                cur["chars"], cur["fills"] = int(st.group(1)), int(st.group(2))
            else:
                cur["lines"].append(l)
    return {"path": path, "file": os.path.basename(path), "sections": sections, "slime": int(head.group(1)),
            "of": int(head.group(2)), "border_blocks": int(head.group(4)), "floor_y": int(fy.group(1)) if fy else -64}


# ---- the clipboard, opening a file, Minecraft ---------------------------------------------------------------------
def _pipe(cmd, text):
    r = subprocess.run(cmd, input=text.encode("utf-8"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    return r.returncode == 0


def _win_clipboard(text):
    import ctypes
    u, k = ctypes.windll.user32, ctypes.windll.kernel32
    k.GlobalAlloc.restype = k.GlobalLock.restype = ctypes.c_void_p
    k.GlobalLock.argtypes = k.GlobalUnlock.argtypes = [ctypes.c_void_p]
    u.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    data = text.encode("utf-16-le") + b"\0\0"
    if not u.OpenClipboard(None):
        return False
    try:
        u.EmptyClipboard()
        h = k.GlobalAlloc(0x0002, len(data))
        p = k.GlobalLock(h)
        ctypes.memmove(p, data, len(data))
        k.GlobalUnlock(h)
        return bool(u.SetClipboardData(13, h))       # CF_UNICODETEXT
    finally:
        u.CloseClipboard()


def copy_text(term, text):
    """The system clipboard when there is one here; always also OSC 52, which the terminal turns into a copy
    (Windows Terminal, iTerm2, kitty, WezTerm, Ghostty, foot, ... - and over SSH)."""
    ok = False
    try:
        if os.name == "nt":
            ok = _win_clipboard(text)
        elif sys.platform == "darwin":
            ok = _pipe(["pbcopy"], text)
        elif not os.environ.get("SSH_CONNECTION"):
            if os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-copy"):
                ok = _pipe(["wl-copy"], text)
            elif os.environ.get("DISPLAY") and shutil.which("xclip"):
                ok = _pipe(["xclip", "-selection", "clipboard"], text)
            elif os.environ.get("DISPLAY") and shutil.which("xsel"):
                ok = _pipe(["xsel", "-ib"], text)
    except (OSError, subprocess.SubprocessError):
        ok = False
    if not ok:
        term.write(b"\x1b]52;c;" + base64.b64encode(text.encode("utf-8")) + b"\x07")
    return ok


def open_file(path):
    try:
        if os.name == "nt":
            os.startfile(path)
            return True
        cmd = ["open"] if sys.platform == "darwin" else (
            ["xdg-open"] if (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) and shutil.which("xdg-open")
            and not os.environ.get("SSH_CONNECTION") else None)
        if cmd:
            subprocess.Popen(cmd + [path], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            return True
    except OSError:
        pass
    return False


def minecraft_running():
    """A java process whose command line mentions minecraft (every launcher's does). Heavy GPU work next to
    Minecraft can crash a laptop's GPU link - the window warns."""
    try:
        if os.path.isdir("/proc"):
            for pid in os.listdir("/proc"):
                if pid.isdigit():
                    try:
                        with open("/proc/%s/cmdline" % pid, "rb") as f:
                            a = f.read().split(b"\0")
                    except OSError:
                        continue
                    if a and os.path.basename(a[0]).startswith(b"java") and any(b"minecraft" in s.lower() for s in a[1:]):
                        return True
            return False
        if os.name == "nt":
            r = subprocess.run(["powershell", "-NoProfile", "-Command",
                                "(Get-CimInstance Win32_Process -Filter \"Name like 'java%'\").CommandLine"],
                               capture_output=True, text=True, timeout=20, creationflags=0x08000000)
            return "minecraft" in r.stdout.lower()
        r = subprocess.run(["ps", "-axww", "-o", "command="], capture_output=True, text=True, timeout=10)
        return any("java" in l and "minecraft" in l.lower() for l in r.stdout.splitlines())
    except (OSError, subprocess.SubprocessError):
        return False


# ---- the app ----------------------------------------------------------------------------------------------------------
class Field:
    def __init__(self, value="", numeric=False):
        self.value, self.cur, self.off, self.numeric = value, len(value), 0, numeric

    def set(self, value):
        self.value, self.cur, self.off = value, len(value), 0


class App:
    def __init__(self, term, cli):
        self.term, self.cli = term, cli
        self.q = queue.Queue()
        self.prev = None
        self.W, self.H = term.size()
        p = load_prefs()
        apply_theme(p.get("studio_theme", "light"))
        self.f = {"seed": Field(str(p["seed"]) if p.get("seed") is not None else "1"),
                  "range": Field("4000", True), "cx": Field("0", True), "cz": Field("0", True),
                  "m_x": Field("", True), "m_z": Field("", True), "m_y": Field("", True), "m_n": Field("", True)}
        band = p.get("studio_band")
        if band is None and p.get("version"):
            band = perimeter_band(str(p["version"]))
        self.band = band if isinstance(band, int) and 0 <= band <= OLD else 3
        self.menu = None                      # the open dropdown: {"x", "y", "w", "sel"}
        self.mode = "best"
        self.layers = {"slime": True, "ring": True, "peri": True, "coords": False}
        self.parse_seed()
        self.afk = (0, 0)
        farm = p.get("farm") or {}
        if farm and self.seed is not None and str(farm.get("seed")) == str(self.seed):
            self.afk = (int(farm.get("best_x", farm.get("x", 0))), int(farm.get("best_z", farm.get("z", 0))))
            self.f["cx"].set(str(self.afk[0]))
            self.f["cz"].set(str(self.afk[1]))
        self.result = None
        self.results = load_json(RESULTS, {})
        if not isinstance(self.results, dict):
            self.results = {}
        self.restore_result(keep_afk=bool(farm and self.seed is not None and str(farm.get("seed")) == str(self.seed)),
                            recenter=False)           # the view starts on self.afk just below
        self.peri, self.peri_key, self.peri_center = None, None, self.afk
        self.height, self.measure_msg = None, None
        self.view = [self.afk[0] + 0.5, self.afk[1] + 0.5, None]      # centre x, z; blocks per pixel (None = fit)
        self.view_auto = True                 # re-fit the map to the window until you zoom or pan yourself
        self.map_view = "chunks"              # the map card's tab: chunks, or the floor the commands build
        self.help, self.confirm_long, self.dense = False, False, False
        self.search = next((n for n in SEARCH_TOOLS if os.path.exists(tool(n))), None)   # what Find will use, if it runs
        self.tile_s = self.saved_tile_s(p)    # this machine's measured seconds per full tile, once a big scan ran
        self.tab, self.focus, self.focus_moved = "find", "seed", False
        self.scroll, self.copy_i = {}, {}
        self.status, self.toast, self.job = None, None, None
        self.drag, self.hover, self.mapgeo = None, None, None
        self.minecraft = False
        self.missing = [n for n in ("slime_refine", "afk_rescan") if not os.path.exists(tool(n))]
        if not self.search:
            self.missing.append("slime_cpu")
        if not os.path.exists(os.path.join(ROOT, "perimeter_gen", "perimeter_gen" + (".exe" if os.name == "nt" else ""))):
            self.missing.append("perimeter_gen")
        self.chunks, self.map_cache, self.floor_cache = {}, (None, None), (None, None)
        self.pic_req, self.pic_on, self.pic_sent, self.pic_cache = None, None, None, (None, None)
        self.dirty, self.running, self.pending = True, True, ""
        self.order, self.fpos, self.hits, self.actions, self.panels, self.fieldx = [], {}, [], {}, {}, {}

    # -- state ---------------------------------------------------------------------------------------------------
    def parse_seed(self):
        try:
            self.seed, self.seed_text = self.cli.parse_seed(self.f["seed"].value)
            self.seed_err = None
        except ValueError:
            self.seed, self.seed_text, self.seed_err = None, False, "type a seed - a number or any text"
        self.chunks = {}

    def num(self, fid):
        try:
            return int(self.f[fid].value.strip())
        except ValueError:
            return None

    def floor_y(self):
        return 0 if self.band in (0, OLD) else -64

    def stale(self):
        return self.peri is None or self.peri_key != (self.seed, self.band, self.peri_center)

    def flash(self, text, secs=3.0):
        self.toast = (text, time.time() + secs)

    def set_status(self, text, kind="info"):
        self.status = (text, kind)

    def set_afk(self, x, z, recenter=False):
        self.afk = (x, z)
        if recenter:
            self.view[0], self.view[1] = x + 0.5, z + 0.5

    def start(self, name, fn, done, *args):
        if self.job:
            self.flash("wait - %s is still running" % self.job.name)
            return
        job = self.job = Job(name)
        self.status = None

        def work():
            try:
                res, err = fn(self.cli, job, *args), None
            except ToolError as e:
                res, err = None, e.msg
            except Exception as e:                       # a bug, not a tool message - still show it
                res, err = None, "%s: %s" % (type(e).__name__, e)
            self.q.put((job, done, res, err))
        threading.Thread(target=work, daemon=True).start()

    def drain(self):
        while not self.q.empty():
            job, done, res, err = self.q.get()
            self.job = None
            self.dirty = True
            if job.cancel.is_set() and res is None and not err:
                self.set_status("cancelled", "info")
            elif err:
                self.set_status(err.strip().splitlines()[0][:300] if err.strip() else "failed", "err")
                self.flash("%s failed - see the left panel" % job.name if job.name == "search" else err.strip()[:120])
            else:
                done(res, time.time() - job.t0)

    # -- actions ---------------------------------------------------------------------------------------------------
    def do_find(self):
        if self.seed is None:
            return self.set_status("type a world seed first", "err")
        x, z = self.num("cx"), self.num("cz")
        if x is None or z is None or abs(x) > WORLD or abs(z) > WORLD:
            return self.set_status("Center X and Z are whole numbers inside the world (±30,000,000)", "err")
        if self.mode == "manual":
            self.set_afk(x, z, recenter=True)
            self.result = None
            key = search_key(self.seed, "manual", None, x, z, self.floor_y())
            if key in self.results:
                return self.on_result(dict(self.results[key]["res"]), self.results[key]["secs"], saved=True)
            return self.start("score", score_worker, lambda res, secs: self.on_result(res, secs, key=key),
                              self.seed, x, z, self.floor_y())
        rng = self.num("range")
        if rng is None or not 16 <= rng <= WORLD:
            return self.set_status("search range is 16 to 30,000,000 blocks - World covers all of it", "err")
        if rng >= WORLD_RANGE:
            rng, x, z = WORLD_RANGE, 0, 0                  # the world is centred on 0, 0
        elif max(abs(x), abs(z)) + rng > WORLD_RANGE:
            return self.set_status("±%s around %d, %d runs past the world border - lower it, or pick World" % (
                fmt(rng), x, z), "err")
        key = search_key(self.seed, self.mode, rng, x, z)
        if key in self.results:                            # searched before: the same answer, now
            return self.on_result(dict(self.results[key]["res"]), self.results[key]["secs"], saved=True)
        miss = [t for t in ("slime_cpu", "slime_refine") if t in self.missing]
        if miss:
            return self.set_status("%s not built - run %s first" % (", ".join(miss), self.build_cmd()), "err")
        if self.minecraft and len(tiles_for(rng)[0]) > 16 and not self.confirm_long:
            self.confirm_long = True
            return self.set_status("Minecraft is open. A long scan next to it can crash some laptops: close it, "
                                   "or press Find again to start anyway.", "err")
        self.confirm_long = False
        self.start("search", search_worker, lambda res, secs: self.on_result(res, secs, key=key),
                   self.seed, self.mode, rng, x, z)

    def on_result(self, res, secs, key=None, saved=False):
        self.result = res
        self.set_afk(res["x"], res["z"], recenter=True)
        took = eta(secs) if secs >= 60 else "%.1f s" % secs
        if key and not res.get("partial"):                 # remember it: this search never has to run again
            self.results[key] = {"seed": self.seed, "res": dict(res), "secs": secs, "t": time.time()}
            if len(self.results) > 300:
                for k in sorted(self.results, key=lambda k: self.results[k]["t"])[:len(self.results) - 300]:
                    del self.results[k]
            save_json(RESULTS, self.results)
        if saved:
            self.set_status("searched before - the saved answer (it took %s then)" % took, "ok")
        elif res["mode"] == "manual":
            self.set_status("scored in %s" % took, "ok")
        elif res.get("partial"):
            self.set_status("stopped after %s of %s tiles - the best of those" % (fmt(res["scanned"]), fmt(res["tiles"])))
        else:
            self.set_status("found in %s%s" % (took, " (%s tiles)" % fmt(res["tiles"]) if res["tiles"] > 1 else ""), "ok")
        if res.get("tiles", 0) >= 16:
            self.tile_s = self.saved_tile_s(load_prefs()) or self.tile_s

    def restore_result(self, keep_afk=False, recenter=True):
        """This seed's last finished search, with the inputs that made it, so Find gives it straight back."""
        if self.seed is None:
            return
        mine = [(e["t"], k) for k, e in self.results.items() if e.get("seed") == self.seed]
        if not mine:
            return
        k = max(mine)[1]
        res = dict(self.results[k]["res"])
        _, mode, rng, x, z = k.split(" ")
        self.mode = mode
        if mode != "manual":
            self.f["range"].set(rng)
        self.f["cx"].set(x)
        self.f["cz"].set(z)
        self.result = res
        if not keep_afk:
            self.set_afk(res["x"], res["z"], recenter=recenter)
            if recenter:
                self.view[2], self.view_auto = None, True

    def pick_top(self, i):
        """Show another of the search's top spots."""
        r = self.result
        t = r["top"][i]
        r.update(x=t["x"], z=t["z"], distance=int(math.hypot(t["x"] - r["center"][0], t["z"] - r["center"][1])))
        if "cq" in t:
            r.update(cq=t["cq"], blocks=t["blocks"], verdict=verdict(self.cli, t["cq"]))
        else:
            r["ring_chunks"] = t["chunks"]
        self.set_afk(t["x"], t["z"], recenter=True)

    def set_range(self, v):
        self.f["range"].set(str(v))

    def step_preset(self, d, wrap_around=False):
        cur = self.num("range")
        vals = [v for _, v in PRESETS]
        i = next((k for k, v in enumerate(vals) if cur is not None and (cur == v or (k == len(vals) - 1 and cur >= WORLD_RANGE))), None)
        if i is None:
            i = sum(1 for v in vals if cur is not None and v < cur) - (1 if d > 0 else 0)
        n = i + d
        self.set_range(vals[n % len(vals)] if wrap_around else vals[max(0, min(len(vals) - 1, n))])

    def saved_tile_s(self, prefs):
        return prefs.get("studio_tile_s_" + (self.search or "")) or (prefs.get("studio_tile_s") if self.search == "slime_gpu" else None)

    def estimate(self, rng):
        """Tiles and time for a search of +-rng: this machine's measured speed once a big scan ran here."""
        world = rng >= WORLD_RANGE
        tiles, m = tiles_for(WORLD_RANGE if world else rng)
        n = len(tiles)
        secs = 0.4 + (0 if n == 1 else n * (self.tile_s or TILE_S.get(self.search, 0.3)) * (m / TILE_M) ** 2) + 0.03 * min(n, 32)
        where = "" if n < 100 else (" on " + SEARCH_ON.get(self.search, "this machine") if self.tile_s else " on " + SEARCH_ON.get(self.search, "this machine") + " (a rough guess)")
        return "%s%s tile%s, about %s%s." % ("The whole world from 0, 0: " if world else "", fmt(n),
                                                "" if n == 1 else "s", eta(secs), where)

    def cancel(self):
        if self.job and self.job.name == "search" and not self.job.cancel.is_set():
            self.job.cancel.set()
            self.job.progress = "stopping - scoring the best so far"

    def use_center(self):
        self.peri_center = self.afk
        self.generate()

    def generate(self, remember=True):
        if self.seed is None:
            return self.set_status("type a world seed first", "err")
        if self.band == OLD:
            return self.flash("No commands for 1.12 and older - pick 1.13 or newer. The map and search work as is.")
        if "perimeter_gen" in self.missing:
            return self.flash("perimeter_gen isn't built - run %s first" % self.build_cmd())
        x, z = self.peri_center
        key = (self.seed, self.band, self.peri_center)

        def done(res, secs):
            self.peri, self.peri_key, self.copy_i = res, key, {}
            self.flash("saved %s" % os.path.relpath(res["path"], ROOT))
        self.start("perimeter", perimeter_worker, done, self.seed, x, z, self.band, remember)

    def copy(self, text, what=None):
        native = copy_text(self.term, text)
        short = text if len(text) <= 60 else text[:57] + "..."
        self.flash("copied%s: %s" % ("" if native else " (terminal clipboard)", what or short))

    def copy_section(self, n):
        if self.stale():
            return self.flash("Generate first - the commands don't match your inputs yet")
        lines = self.peri["sections"].get(n, {}).get("lines", [])
        if not lines:
            return
        i = self.copy_i.get(n, 0) % len(lines)
        what = "%d characters" % len(lines[i]) if len(lines[i]) > 60 else None
        if len(lines) > 1:
            what = "%d of %d, %s" % (i + 1, len(lines), what or lines[i])
        self.copy(lines[i], what)
        self.copy_i[n] = (i + 1) % len(lines)

    def open_txt(self):
        if not self.peri:
            return
        rel = os.path.relpath(self.peri["path"], ROOT)
        self.flash(("opened " if open_file(self.peri["path"]) else "it's here: ") + rel, 5)

    def find_height(self):
        if self.seed is None:
            return self.flash("type a world seed first")
        if "afk_rescan" in self.missing:
            return self.flash("afk_rescan isn't built - run %s first" % self.build_cmd())
        x, z = self.peri_center if self.peri else self.afk

        def done(res, secs):
            self.height = res
            b = res["best"]
            for fid, v in (("m_x", b["x"]), ("m_z", b["z"]), ("m_y", b["feet_y"])):
                if not self.f[fid].value:
                    self.f[fid].set(str(v))
        self.start("heights", height_worker, done, self.seed, x, z, self.floor_y())

    def save_reading(self):
        vals = [self.num(k) for k in ("m_x", "m_z", "m_y", "m_n")]
        if self.seed is None or None in vals:
            return self.flash("fill in X, Z, feet Y and the /perimeterinfo number")
        x, z, fy, n = vals
        if n < 0:
            return self.flash("the reading is a positive number")

        def done(res, secs):
            self.measure_msg = res
            self.flash("saved to %s" % res["saved"])
        self.start("save", measured_worker, done, self.seed, x, z, fy, n, self.floor_y())

    def build_cmd(self):
        return "build.ps1" if os.name == "nt" else "./build.sh"

    def set_mode(self, m):
        if m == self.mode:
            return
        self.mode = m
        self.status = None
        if m == "manual":
            self.f["cx"].set(str(self.afk[0]))
            self.f["cz"].set(str(self.afk[1]))

    def field_changed(self, fid):
        if fid == "seed":
            self.parse_seed()
            self.result, self.height = None, None
            self.restore_result()
        elif fid in ("cx", "cz"):
            if self.mode == "manual":
                x, z = self.num("cx"), self.num("cz")
                if x is not None and z is not None and abs(x) <= WORLD and abs(z) <= WORLD:
                    self.set_afk(x, z, recenter=True)
                    self.result = None

    def submit(self, fid):
        if fid.startswith("m_"):
            self.save_reading()
        else:
            self.do_find()

    def place(self, wx, wz):
        x, z = math.floor(wx), math.floor(wz)
        self.f["cx"].set(str(x))
        self.f["cz"].set(str(z))
        self.set_afk(x, z)
        self.result = None
        if self.seed is not None and not self.job and "afk_rescan" not in self.missing:
            self.start("score", score_worker, lambda r, s: setattr(self, "result", r), self.seed, x, z, self.floor_y())

    def zoom(self, factor, px=None, py=None):
        g = self.mapgeo
        if not g:
            return
        ix, iy, pw, ph, left, top, bpp, ar = g
        nb = min(400000.0, max(0.25, bpp * factor))
        self.view_auto = False
        if px is not None:              # keep the block under the pointer still
            wx, wz = left + px * bpp, top + py * bpp * ar
            self.view[0] = wx - (px - pw / 2) * nb
            self.view[1] = wz - (py - ph / 2) * nb * ar
        self.view[2] = nb

    # -- frame -----------------------------------------------------------------------------------------------------
    def render(self):
        for _ in range(3):
            self.frame()
            if not self.fix_scroll():
                break
        g = self.term.graphics
        if g == "sixel" and self.pic_on and (self.pic_req is None or self.pic_req[:4] != self.pic_sent[:4]):
            self.prev = None                   # a Sixel picture is part of the cells: a full repaint clears it
        prev = self.prev
        full = prev is None or (prev.w, prev.h) != (self.scr.w, self.scr.h)
        out = self.scr.diff(prev, self.term.colors)
        self.prev = self.scr
        if g == "kitty":
            out += self.send_picture(full)
        elif g == "sixel":
            out += self.send_sixel(full, prev)
        self.term.write(out)                   # one write, so the terminal never shows half a frame

    def frame(self):
        W, H = self.W, self.H
        S = self.scr = Screen(W, H)
        self.order, self.fpos, self.hits, self.actions, self.panels, self.fieldx = [], {}, [], {}, {}, {}
        self.cur_panel = None
        self.mapgeo, self.pic_req, self.vbox = None, None, None
        if W < 64 or H < 18:
            msg = "Make the window bigger: at least 64 x 18 (it's %d x %d)" % (W, H)
            S.put(max(0, (W - len(msg)) // 2), H // 2, msg[:W], MUTED)
            return
        self.compact = H < 40
        self.dense = H < 60                    # 1080p and smaller: tighter cards, so the right column fits
        top = self.header()
        bot = H - 1
        if self.tab == "find":
            self.find_tab(top, bot)
        elif self.tab == "commands":
            self.panel("commands", 0, top, W, bot - top, self.commands_content)
        else:
            self.panel("guide", 0, top, W, bot - top, self.guide_content)
        self.footer()
        if self.help:
            self.help_box()
        self.menu_box()

    def help_box(self):
        S = self.scr
        kw = max(len(k) for k, v in HELP) + 3
        w = min(self.W - 4, kw + max(len(v or "") for k, v in HELP) + 6)
        h = min(self.H - 2, len(HELP) + 6)
        x, y = (self.W - w) // 2, (self.H - h) // 2
        S.fill(x, y, w, h, CARD_BG)
        S.box(x, y, w, h, LINE)
        S.put(x + 2, y + 1, "All keys", TEXT, CARD_BG, bold=True)
        S.hline(x + 1, y + 2, w - 2, LINE)
        for i, (k, v) in enumerate(HELP[:h - 6]):
            if v is None:
                S.put(x + 3, y + 3 + i, k, GREEN, CARD_BG, bold=True)
            else:
                S.put(x + 3, y + 3 + i, k, TEXT, CARD_BG, bold=True)
                S.put(x + 3 + kw, y + 3 + i, v[:w - kw - 5], MUTED, CARD_BG)
        S.put(x + 3, y + h - 2, "Any key closes this.", MUTED, CARD_BG)

    # -- the registry: what's clickable, what takes focus ---------------------------------------------------------
    def hit(self, hid, x, y, w, h, act=None):
        x0, y0, x1, y1 = self.scr.clips[-1]
        a, b, c, d = max(x, x0), max(y, y0), min(x + w, x1), min(y + h, y1)
        if a < c and b < d:
            self.hits.append((hid, a, b, c, d))
        if act:
            self.actions[hid] = act

    def focusable(self, fid, y0, y1):
        if fid not in self.fpos:
            self.order.append(fid)
        self.fpos[fid] = (self.cur_panel, y0, y1)

    def kind(self, fid):
        if fid in self.f:
            return "text"
        return {"band": "select", "mode": "seg", "preset": "seg", "map": "map"}.get(fid, "button")

    def fix_scroll(self):
        """Keep the focused widget on screen after keyboard moves; returns True if a redraw is needed."""
        if not self.focus_moved:
            return False
        self.focus_moved = False
        pos = self.fpos.get(self.focus)
        if not pos or not pos[0] or pos[0] not in self.panels:
            return False
        name, y0, y1 = pos
        px, py, pw, ph, used = self.panels[name]
        top = self.scroll.get(name, 0)
        if y0 < py:
            self.scroll[name] = max(0, top - (py - y0) - 1)
        elif y1 > py + ph:
            self.scroll[name] = top + (y1 - py - ph) + 1
        else:
            return False
        return True

    def panel(self, name, x, y, w, h, content):
        S = self.scr
        top = self.scroll.get(name, 0)
        S.push(x, y, x + w, y + h)
        self.cur_panel = name
        used = content(x, y - top, w - 1)
        self.cur_panel = None
        S.pop()
        self.panels[name] = (x, y, w, h, used)
        if top > max(0, used - h):
            self.scroll[name] = max(0, used - h)
            self.dirty = True
        if used > h:                                       # a thin scrollbar
            th = max(1, h * h // used)
            ty = y + (h - th) * self.scroll.get(name, 0) // max(1, used - h)
            for yy in range(y, y + h):
                S.put(x + w - 1, yy, "┃" if ty <= yy < ty + th else "│", FIELD_EDGE if ty <= yy < ty + th else LINE)

    # -- widgets ---------------------------------------------------------------------------------------------------
    def label(self, x, y, text, color=None, bold=True):
        """A field's title: short, bold, sentence case."""
        self.scr.put(x, y, text, color or TEXT, bold=bold)

    def helptext(self, x, y, w, text, color=None):
        """The line of help under a field. Returns the rows it took."""
        color = MUTED if color is None else color
        n = 0
        for l in wrap(text, w):
            self.scr.put(x, y + n, l, color)
            n += 1
        return n

    def ih(self):
        return 1 if self.compact else 3

    def card(self, x, y, w, title, content, right=None):
        """A white card with a title bar: title on the left, right(x_end, y) may draw tabs or buttons at
        the right of the bar. content(ix, iy, iw) draws the body and returns the rows it used."""
        S = self.scr
        S.put(x + 2, y + 1, title, TEXT, bold=True)
        if right:
            right(x + w - 2, y + 1)
        S.hline(x + 1, y + 2, w - 2, LINE)
        used = content(x + 2, y + 3 + (0 if self.compact else 1), w - 4)
        h = used + 4 + (0 if self.compact else 2)
        S.tint(x + 1, y + 1, w - 2, h - 2, PAGE, CARD_BG)
        S.box(x, y, w, h, LINE)
        S.put(x, y + 2, "├", LINE)
        S.put(x + w - 1, y + 2, "┤", LINE)
        return h

    def note(self, x, y, w, text, kind="note"):
        """A tinted note box (note, warn or error), as on their page. Returns its height."""
        bg, fg, edge = {"note": (NOTE_BG, NOTE_TEXT, NOTE_EDGE), "warn": (WARN_BG, WARN_TEXT, WARN_EDGE),
                        "error": (ERR_BG, ERR_TEXT, ERR_EDGE)}[kind]
        lines = wrap(text, w - 4)
        S = self.scr
        S.fill(x, y, w, len(lines) + 2, bg)
        S.box(x, y, w, len(lines) + 2, edge)
        for i, l in enumerate(lines):
            S.put(x + 2, y + 1 + i, l, fg, bg)
        return len(lines) + 2

    def input(self, fid, x, y, w, disabled=False, prefix=""):
        """A white text box with a grey edge, green with focus."""
        S, foc = self.scr, self.focus == fid
        f = self.f[fid]
        bad = (fid == "seed" and self.seed_err is not None) or \
              (fid in ("range", "cx", "cz") and self.num(fid) is None and not disabled)
        edge = DANGER if bad else GREEN if foc else LINE if disabled else FIELD_EDGE
        if self.compact:
            S.fill(x + 1, y, w - 2, 1, CARD_BG)
            S.put(x, y, "▕", edge)
            S.put(x + w - 1, y, "▏", edge)
            tx, tw, ty, h = x + 2, w - 4, y, 1
        else:
            S.fill(x, y, w, 3, CARD_BG)
            S.box(x, y, w, 3, edge)
            tx, tw, ty, h = x + 2, w - 4, y + 1, 3
        if prefix:
            S.put(tx, ty, prefix, MUTED, CARD_BG)
            tx, tw = tx + len(prefix), tw - len(prefix)
        if f.cur < f.off:
            f.off = f.cur
        while twidth(f.value[f.off:f.cur]) > tw - 1:
            f.off += 1
        S.push(tx, ty, tx + tw, ty + 1)
        S.put(tx, ty, f.value[f.off:], MUTED if disabled else TEXT, CARD_BG)
        if foc:                                            # a green caret, as their caret-color
            cx = tx + twidth(f.value[f.off:f.cur])
            c = f.value[f.cur] if f.cur < len(f.value) else " "
            S.put(cx, ty, c if cwidth(c) == 1 else " ", ON_GREEN, GREEN)
        S.pop()
        self.fieldx[fid] = tx
        self.hit(fid, x, y, w, h)
        self.focusable(fid, y, y + h)
        return h

    def button(self, bid, x, y, w, text, act, primary=True, disabled=False, tall=None):
        """primary: solid forest green with white text; otherwise white with a grey edge. Darker with focus."""
        S, foc = self.scr, self.focus == bid and not disabled
        h = (1 if self.compact else 3) if tall is None else (3 if tall else 1)
        ty = y if h == 1 else y + 1
        t = text if twidth(text) <= w - 4 else text[:w - 5] + "…"
        if primary:
            bgc = TRACK if disabled else GREEN_DARK if foc else GREEN
            fg = MUTED if disabled else ON_GREEN
            if h == 3:
                S.put(x, y, "▄" * w, bgc)
                S.put(x, y + 2, "▀" * w, bgc)
            S.fill(x, ty, w, 1, bgc)
            S.put(x + (w - twidth(t)) // 2, ty, t, fg, bgc, bold=True)
        else:
            edge = GREEN if foc else LINE if disabled else BTN_EDGE
            bgc = BTN_HOVER if foc else CARD_BG
            fg = MUTED if disabled else GREEN_DARK if foc else TEXT
            if h == 3:
                S.fill(x, y, w, 3, bgc)
                S.box(x, y, w, 3, edge)
            else:
                S.fill(x + 1, ty, w - 2, 1, bgc)
                S.put(x, ty, "▕", edge)
                S.put(x + w - 1, ty, "▏", edge)
            S.put(x + (w - twidth(t)) // 2, ty, t, fg, bgc, bold=True)
        self.hit(bid, x, y, w, h, None if disabled else act)
        self.focusable(bid, y, y + h)
        return h

    def chip(self, cid, x, y, text, act, disabled=False, maxw=None, selected=False, w=None):
        """A small one-row button (Copy, a preset): pale, the selected one tinted with a green label."""
        S, foc = self.scr, self.focus == cid and not disabled
        t = text
        if maxw and len(t) + 2 > maxw:
            t = t[:max(1, maxw - 3)] + "…"
        w = w or len(t) + 2
        if disabled:
            bgc, fg = PANEL2, MUTED
        elif foc:
            bgc, fg = GREEN, ON_GREEN
        elif selected:
            bgc, fg = PICK_BG, GREEN
        else:
            bgc, fg = BTN_HOVER, TEXT
        S.fill(x, y, w, 1, bgc)
        S.put(x + (w - len(t)) // 2, y, t, fg, bgc, bold=selected or foc)
        self.hit(cid, x, y, w, 1, None if disabled else act)
        self.focusable(cid, y, y + 1)
        return w

    def radio(self, x, y, w):
        """The search type as their 'type choice' rows: the chosen one tinted, a small tag on the right."""
        S, foc = self.scr, self.focus == "mode"
        for i, (k, name, tag) in enumerate(MODES):
            on = self.mode == k
            if on:
                S.fill(x, y + i, w, 1, PICK_BG)
                S.put(x, y + i, "▕", PICK_EDGE, PICK_BG)
                S.put(x + w - 1, y + i, "▏", PICK_EDGE, PICK_BG)
            S.put(x + 2, y + i, "●" if on else "○", GREEN if on else MUTED)
            S.put(x + 4, y + i, name, GREEN_DARK if foc and on else TEXT, bold=on)
            S.put(x + w - 2 - len(tag), y + i, tag, MUTED)
            self.hit("mode:" + k, x, y + i, w, 1, (lambda k=k: self.set_mode(k)))
        self.focusable("mode", y, y + len(MODES))
        return len(MODES)

    def presets(self, x, y, w):
        cur, n = self.num("range"), len(PRESETS)
        sw, sx = (w - (n - 1)) // n, x
        foc = self.focus == "preset"
        for i, (name, v) in enumerate(PRESETS):
            on = cur is not None and (cur == v or (i == n - 1 and cur >= WORLD_RANGE))
            ww = sw if i < n - 1 else x + w - sx
            bgc, fg = (GREEN, ON_GREEN) if foc and on else (PICK_BG, GREEN) if on else (BTN_HOVER, TEXT)
            self.scr.fill(sx, y, ww, 1, bgc)
            self.scr.put(sx + (ww - len(name)) // 2, y, name, fg, bgc, bold=on)
            self.hit("preset:%d" % i, sx, y, ww, 1, (lambda v=v: self.set_range(v)))
            sx += ww + 1
        self.focusable("preset", y, y + 1)
        return 1

    def version_row(self, x, y, w):
        """The game version: it only changes the commands' syntax and floor height, never the slime chunks."""
        S, foc = self.scr, self.focus == "band"
        name = band_name(self.band)
        if self.compact:
            S.put(x, y, "Version", MUTED)
            t = "%s ▾" % name
            S.put(x + w - len(t), y, t, GREEN_DARK if foc else TEXT, bold=True)
            self.hit("band", x, y, w, 1)
            self.focusable("band", y, y + 1)
            self.vbox = self.on_screen(x, y, w, 1)
            return 1
        S.fill(x, y, w, 3, BTN_HOVER if foc else CARD_BG)
        S.box(x, y, w, 3, GREEN if foc else FIELD_EDGE)
        S.put(x + 2, y + 1, name, TEXT, BTN_HOVER if foc else CARD_BG)
        S.put(x + w - 4, y + 1, "▾", MUTED, BTN_HOVER if foc else CARD_BG)
        self.hit("band", x, y, w, 3)
        self.focusable("band", y, y + 3)
        self.vbox = self.on_screen(x, y, w, 3)
        return 3

    def on_screen(self, x, y, w, h):
        """The box if it's fully inside the panel it's drawn in (not scrolled out of view), else None."""
        x0, y0, x1, y1 = self.scr.clips[-1]
        return (x, y, w, h) if x0 <= x and x + w <= x1 and y0 <= y and y + h <= y1 else None

    def open_menu(self):
        self.menu = {"sel": next(i for i, (k, _, _) in enumerate(VERSIONS) if k == self.band), "hover": None}

    def pick_version(self, i):
        self.band = VERSIONS[i][0]
        self.menu = None
        save_prefs(studio_band=self.band)
        self.focus = "band"

    def menu_geo(self):
        """Where the open dropdown goes: under the box over whatever is there, above it when the screen ends
        first; two lines a row when there's room (the releases each covers), one when there isn't."""
        tall = 2 if self.H >= 30 else 1
        mh = len(VERSIONS) * tall + 2
        if self.vbox:
            x, y, w, h = self.vbox
            top = y + h if y + h + mh <= self.H - 1 else y - mh if y - mh >= 0 else (self.H - 1 - mh) // 2
        else:                                           # the box has scrolled off: the menu opens mid-screen
            w = min(38, self.W - 4)
            x, top = (self.W - w) // 2, (self.H - 1 - mh) // 2
        return x, max(0, top), w, mh, tall

    def menu_box(self):
        S = self.scr
        if not self.menu:
            return
        x, y, w, mh, tall = self.menu_geo()
        S.fill(x, y, w, mh, CARD_BG)
        S.box(x, y, w, mh, GREEN)
        for i, (k, name, covers) in enumerate(VERSIONS):
            ry = y + 1 + i * tall
            on, hov = k == self.band, i == self.menu["sel"]
            bgc = PICK_BG if hov else CARD_BG
            S.fill(x + 1, ry, w - 2, tall, bgc)
            S.put(x + 2, ry, "✓" if on else " ", GREEN, bgc, bold=True)
            S.put(x + 4, ry, name, GREEN_DARK if hov else TEXT, bgc, bold=on or hov)
            if tall == 2:
                S.put(x + 4, ry + 1, covers[:w - 6], MUTED, bgc)
            self.hit("vopt:%d" % i, x + 1, ry, w - 2, tall)

    def kv(self, x, y, w, left, right, rcolor=None):
        """Their key-value row: the name muted on the left, the value bold on the right."""
        self.scr.put(x, y, left, MUTED)
        self.scr.put(x + w - twidth(right), y, right, rcolor or TEXT, bold=True)

    row = kv

    def bar(self, x, y, w, frac, color=None):
        color = GREEN if color is None else color
        n = max(0, min(w, round(w * frac)))
        self.scr.put(x, y, "━" * n, DANGER if frac > 1 else color)
        self.scr.put(x + n, y, "━" * (w - n), TRACK)

    def coord_box(self, cid, x, y, w, text, copy_text=None):
        """Their green monospace coordinate box, with a Copy on the right when there is something to copy."""
        S = self.scr
        bw = w - (8 if copy_text else 0)
        S.fill(x, y, bw, 1, COORD_BG)
        S.put(x + 1, y, text[:bw - 2], COORD_TEXT, COORD_BG, bold=True)
        if copy_text:
            self.chip(cid, x + bw + 1, y, "Copy", (lambda: self.copy(copy_text)), w=7)
        return 1

    def stat_strip(self, x, y, w, stats):
        """Their three numbers in one tinted bar: a small label, the value, a small line under it."""
        S = self.scr
        S.fill(x + 1, y + 1, w - 2, 3, STAT_BG)
        S.box(x, y, w, 5, STAT_EDGE)
        cw = (w - 2) // len(stats)
        for i, (lab, val, sub, accent) in enumerate(stats):
            cx = x + 1 + i * cw
            if i:
                S.put(cx, y, "┬", STAT_EDGE)
                for r in range(1, 4):
                    S.put(cx, y + r, "│", STAT_EDGE, STAT_BG)
                S.put(cx, y + 4, "┴", STAT_EDGE)
            S.put(cx + 2, y + 1, lab[:cw - 3], STAT_LABEL, STAT_BG)
            S.put(cx + 2, y + 2, val[:cw - 3], STAT_ACCENT if accent else TEXT, STAT_BG, bold=True)
            S.put(cx + 2, y + 3, sub[:cw - 3], STAT_LABEL, STAT_BG)
        return 5

    # -- header & footer -------------------------------------------------------------------------------------------
    def header(self):
        S, W = self.scr, self.W
        y = 0 if self.compact else 1
        S.put(2, y, "▐█▌", SLIME)                           # a small slime block
        x = S.put(6, y, "SlimeByte", TEXT, bold=True)
        formula = "24² < ΔX² + ΔZ² ≤ 128²"
        ty = y if self.compact else y + 1
        tx = x + 4 if self.compact else 2
        tabs = (("find", "Find spot"), ("commands", "Perimeter commands"), ("guide", "Build guide"))
        if self.compact and W < 120:
            tabs = (("find", "Find"), ("commands", "Commands"), ("guide", "Guide"))
        S.hline(0, ty + 1, W, LINE)
        for k, name in tabs:
            on, tid = self.tab == k, "tab:" + k
            foc = self.focus == tid
            S.put(tx, ty, name, GREEN if on else GREEN_DARK if foc else MUTED, bold=on or foc)
            if on:
                S.put(tx, ty + 1, "━" * len(name), GREEN)
            self.hit(tid, tx, ty, len(name), 1, (lambda k=k: self.set_tab(k)))
            self.focusable(tid, 0, ty + 1)
            tx += len(name) + 4
        xx = W - 2
        for k, name in reversed((("light", "Light"), ("dark", "Dark"))):     # like the map's Chunks / Floor
            xx -= len(name)
            on, tid = THEME == k, "theme:" + k
            foc = self.focus == tid
            S.put(xx, y, name, GREEN if on else GREEN_DARK if foc else MUTED, bold=on or foc)
            self.hit(tid, xx, y, len(name), 1, (lambda k=k: self.set_theme(k)))
            self.focusable(tid, 0, y + 1)
            xx -= 3
        if xx - len(formula) - 2 > (x if not self.compact else tx):
            S.put(xx - len(formula) - 2, y, formula, MUTED)
        return ty + 2

    def set_theme(self, k):
        apply_theme(k)
        save_prefs(studio_theme=THEME)
        self.prev, self.map_cache, self.pic_cache = None, (None, None), (None, None)     # repaint it all

    def set_tab(self, k):
        self.tab = k
        self.focus = "tab:" + k          # never leave the keyboard on a field that isn't on screen

    def footer(self):
        """One quiet line: the keys that work right now, then what's running, or the last message."""
        S, W, y = self.scr, self.W, self.H - 1
        kind = self.kind(self.focus) if self.focus in self.fpos else None
        if kind == "text":
            keys = [("enter", "save" if self.focus.startswith("m_") else "run"), ("tab", "next field"), ("ctrl+c", "quit")]
        elif kind == "map":
            keys = [("drag", "move"), ("scroll", "zoom"), ("arrows", "move"), ("+ -", "zoom"), ("c", "back to the farm")]
            if self.mode == "manual":
                keys.append(("click", "place the AFK spot"))
            keys += [("tab", "next")]
        else:
            keys = [("f", "find"), ("g", "generate"), ("u", "build here"), ("1 2 3", "tabs"), ("?", "all keys"), ("q", "quit")]
        if self.job and self.job.name == "search":
            keys.insert(0, ("esc", "stop"))
        right, rbg = "", None
        if self.job:
            right = "%s %s: %s" % (SPIN[int(time.time() * 10) % len(SPIN)], self.job.name, self.job.progress or "working")
        elif self.toast:
            right, rbg = " %s " % self.toast[0], TOAST_BG
        right = right[:max(0, W - 6)]
        x, limit = 2, W - len(right) - 4
        for k, what in keys:
            if x + len(k) + len(what) + 4 > limit:
                break
            x = S.put(x, y, k, TEXT, bold=True)
            x = S.put(x + 1, y, what, MUTED) + 3
        if right:
            S.put(W - 2 - len(right), y, right, TOAST_TEXT if rbg else MUTED, rbg)

    # -- 1 · find spot -------------------------------------------------------------------------------------------
    def find_tab(self, top, bot):
        W, S = self.W, self.scr
        self.wide = W >= 150
        L, R = (36, 42) if self.wide else ((38 if W >= 100 else 34), 0)
        self.panel("left", 0, top, L, bot - top, self.left_content)
        mx = L + 1
        mw = W - L - R - 2 - (1 if R else 0)
        self.main_column(mx, top, mw, bot - top)
        if R:
            self.panel("right", W - R, top, R, bot - top, lambda x, y, w: self.cards(x, y, w - 1))

    def warnings(self):
        out = []
        if self.search == "slime_cpu":
            out.append("Searching on the CPU: fine up to ±1M blocks, slow for the whole world. A graphics card with OpenCL "
                       "(or an NVIDIA GPU with CUDA) is much faster.")
        if self.missing:
            out.append("Not built yet: %s. Run %s, then open this again." % (", ".join(self.missing), self.build_cmd()))
        if self.minecraft:
            out.append("Minecraft is running. Close it before big searches: heavy work next to it can crash "
                       "some laptops.")
        return out

    def left_content(self, x, y, w):
        return self.card(x + 2, y + 1, w - 2, "World and search", self.search_body) + 2

    def search_body(self, ix, iy, iw):
        S = self.scr
        gap = 0 if self.compact else 1
        cy = iy
        self.label(ix, cy, "World seed")
        cy += 1
        cy += self.input("seed", ix, cy, iw)
        if self.seed_err:
            cy += self.helptext(ix, cy, iw, self.seed_err, DANGER)
        elif self.seed_text:
            cy += self.helptext(ix, cy, iw, "Text seed, read as %d - the way the game reads it." % self.seed)
        elif not self.compact:
            cy += self.helptext(ix, cy, iw, "Numbers or text, the way the game reads them.")
        cy += gap
        self.label(ix, cy, "Search for")
        cy += 1
        cy += self.radio(ix, cy, iw)
        cy += self.helptext(ix, cy, iw, MODE_NOTE[self.mode]) + gap
        manual = self.mode == "manual"
        if not manual:
            self.label(ix, cy, "Search range ±")
            cy += 1
            cy += self.presets(ix, cy, iw)
            cy += self.input("range", ix, cy, iw)
            rng = self.num("range")
            if rng is not None and 16 <= rng <= WORLD:
                cy += self.helptext(ix, cy, iw, "Blocks each way in X and Z. " + self.estimate(rng))
            cy += gap
        hw = (iw - 2) // 2
        self.label(ix, cy, "AFK X" if manual else "Center X")
        self.label(ix + hw + 2, cy, "AFK Z" if manual else "Center Z")
        cy += 1
        self.input("cx", ix, cy, hw)
        cy += self.input("cz", ix + hw + 2, cy, iw - hw - 2) + gap
        for wtxt in self.warnings():
            cy += self.note(ix, cy, iw, wtxt, "warn") + gap
        busy = self.job is not None
        label = {"best": "Find the best spot", "cluster": "Find the best cluster", "manual": "Score this spot"}[self.mode]
        cy += self.button("find", ix, cy, iw, label, self.do_find, disabled=busy)
        if busy and self.job.name == "search":
            self.chip("cancel", ix + iw - 6, cy + gap, "Stop", self.cancel, w=6)
        if busy and self.job.frac is not None:                        # their thin progress bar
            self.bar(ix, cy + gap, iw - (7 if self.job.name == "search" else 0), self.job.frac)
        cy += gap + 1
        if busy:
            cy += self.helptext(ix, cy, iw, "%s: %s" % (self.job.name.capitalize(), self.job.progress or "working"))
        elif self.status:
            text, kind = self.status
            if kind == "err":
                cy += self.note(ix, cy, iw, text, "error")
            else:
                cy += self.helptext(ix, cy, iw, text, GREEN if kind == "ok" else MUTED)
        r = self.result
        if r and len(r.get("top") or []) > 1 and not busy:
            cy += gap
            self.label(ix, cy, "Top spots")
            cy += 1
            for i, t in enumerate(r["top"]):
                tid = "top:%d" % i
                on, foc = (t["x"], t["z"]) == self.afk, self.focus == tid
                score = "%s cq" % t["cq"] if "cq" in t else "%d chunks" % t["chunks"]
                txt = "%-9s %d, %d" % (score, t["x"], t["z"])
                dist = short_dist(math.hypot(t["x"] - r["center"][0], t["z"] - r["center"][1]))
                bgc = PICK_BG if on else None
                if on:
                    S.fill(ix, cy, iw, 1, PICK_BG)
                S.put(ix + 1, cy, txt[:iw - 2], GREEN_DARK if foc else GREEN if on else TEXT, bgc, bold=on or foc)
                if len(txt) + len(dist) + 3 <= iw:
                    S.put(ix + iw - len(dist) - 1, cy, dist, MUTED, bgc)
                self.hit(tid, ix, cy, iw, 1, (lambda i=i: self.pick_top(i)))
                self.focusable(tid, cy, cy + 1)
                cy += 1
        if not self.wide:
            cy += 2 + self.cards(ix - 2, cy, iw + 4)
        return cy - iy

    def floor_count(self):
        key = (self.seed, self.afk)
        if self.floor_cache[0] != key and self.seed is not None:
            x, z = self.afk
            cx0, cz0 = (x - RADIUS) // 16, (z - RADIUS) // 16
            nx, nz = (x + RADIUS) // 16 - cx0 + 1, (z + RADIUS) // 16 - cz0 + 1
            self.floor_cache = (key, (sum(sum(slime_row(self.seed, cx0, cz, nx)) for cz in range(cz0, cz0 + nz)), nx * nz))
        return self.floor_cache[1] if self.floor_cache[0] == key else None

    def cards(self, x, y, w):
        """The Perimeter and Commands cards: the right-hand column, or under the search card when narrow."""
        cy = y + 1
        cy += self.card(x, cy, w, "Perimeter", self.sec_perimeter) + 1
        cy += self.card(x, cy, w, "Commands", self.sec_commands)
        return cy - y + 1

    def main_column(self, x, y, w, h):
        """Their right-hand column: the three numbers, then the map card filling the rest."""
        S, r = self.scr, self.result
        cy = y + 1
        fc = self.floor_count()
        spaces = fmt(r["blocks"]) if r and "blocks" in r else "–"
        sub = "%s cq, standing on the floor" % r["cq"] if r and "cq" in r else (
            "%d slime chunks in the ring" % r["ring_chunks"] if r and r.get("mode") == "cluster" else "Find or score a spot")
        dist = "%s blocks from %d, %d" % (fmt(r["distance"]), *r["center"]) if r and r.get("center") else "The block you stand on"
        stats = [("Spawning spaces", spaces, sub, True),
                 ("AFK block X / Z", "%d / %d" % self.afk, dist, False),
                 ("Slime chunks in the floor", "%d of %d" % fc if fc else "–", "Within ±152 of the AFK block", False)]
        if not self.compact:
            cy += self.stat_strip(x, cy, w, stats) + 1
        else:
            line = "AFK %d / %d   floor %s" % (self.afk[0], self.afk[1], "%d of %d" % fc if fc else "–")
            if r and "blocks" in r:
                line = "%s spaces   %s" % (spaces, line)
            S.put(x + 1, cy, line[:w - 2], TEXT, bold=True)
            cy += 2
        self.map_card(x, cy, w, y + h - cy)

    def sec_perimeter(self, ix, iy, iw):
        S, p = self.scr, self.peri
        gap = 0 if self.dense else 1
        stale = self.stale()
        cy = iy
        cx, cz = self.peri_center
        self.kv(ix, cy, iw, "Centered on", "%d, %d" % (cx, cz))
        self.kv(ix, cy + 1, iw, "Radius / floor at", "%d / y %d" % (RADIUS, self.floor_y()))
        cy += 2 + gap
        self.label(ix, cy, "Game version")
        cy += 1
        cy += self.version_row(ix, cy, iw)
        if not self.compact:
            cy += self.helptext(ix, cy, iw, "Changes the commands' syntax and floor, never the slime chunks.")
        cy += gap
        for name, n in (("Floor command", 3), ("Border command", 4)):
            chars = p["sections"].get(n, {}).get("chars") if p else None
            self.kv(ix, cy, iw, name, "%s of %s" % (fmt(chars), fmt(LIMIT)) if chars else "–",
                    MUTED if stale else (DANGER if chars and chars > LIMIT else TEXT))
            self.bar(ix, cy + 1, iw, (chars or 0) / LIMIT if not stale else 0)
            cy += 2
        if p and stale:
            cy += gap + self.note(ix, cy + gap, iw, "Your inputs changed since these were made: generate again.", "warn")
        elif p and any((p["sections"].get(n, {}).get("chars") or 0) > LIMIT for n in (3, 4)):
            cy += gap + self.note(ix, cy + gap, iw, "Over the 32,500-character command block limit.", "error")
        cy += gap
        busy = self.job is not None
        bw = (iw - 1) // 2
        self.button("gen", ix, cy, bw, "Generate", self.generate, disabled=busy)
        cy += self.button("open", ix + bw + 1, cy, iw - bw - 1, "Open file", self.open_txt, primary=False, disabled=not p)
        cy += gap
        cy += self.button("use", ix, cy, iw, "Build at the AFK spot", self.use_center, primary=False,
                          disabled=busy, tall=False)
        return cy - iy

    def sec_commands(self, ix, iy, iw):
        S = self.scr
        cy = iy
        stale = self.stale()
        for n, name, tag in SECTIONS:
            lines = self.peri["sections"].get(n, {}).get("lines", []) if self.peri else []
            # a section of several chat lines copies them one at a time: the button names the one it copies
            heads = ["Copy " + l.split(" ")[0] for l in lines] if len(lines) > 1 else ["Copy"]
            t = heads[self.copy_i.get(n, 0) % len(heads)]
            cw = max(len(h) for h in heads) + 2                  # as wide as its longest, so it never jumps
            cx = ix + iw - cw
            x = S.put(ix, cy, str(n), MUTED)
            x = S.put(x + 2, cy, name, TEXT)
            if tag and x + 2 + len(tag) < cx - 1:                 # the mod it needs, when there's room
                S.put(x + 2, cy, tag, VIOLET)
            self.chip("copy:%d" % n, cx, cy, t, (lambda n=n: self.copy_section(n)), disabled=stale, w=cw)
            cy += 1 if self.dense else 2
        if not self.peri:
            cy += self.helptext(ix, cy, iw, "Generate first.")
        return cy - iy - (0 if self.dense else 1)

    # -- the map ---------------------------------------------------------------------------------------------------
    def map_card(self, x, y, w, h):
        S = self.scr
        view = self.map_view

        def tabs(xe, ty):
            xx = xe
            for k, name in reversed((("chunks", "Chunks"), ("floor", "Floor"))):
                xx -= len(name)
                on, tid = view == k, "view:" + k
                foc = self.focus == tid
                S.put(xx, ty, name, GREEN if on else GREEN_DARK if foc else MUTED, bold=on or foc)
                if on:
                    S.put(xx, ty + 1, "━" * len(name), GREEN)
                self.hit(tid, xx, ty, len(name), 1, (lambda k=k: setattr(self, "map_view", k)))
                self.focusable(tid, ty, ty + 1)
                xx -= 3

        def body(ix, iy, iw):
            my = iy
            mh = h - (my - y) - 1 - (2 if self.compact else 4)
            if mh >= 4:
                self.draw_map(ix - 1, my, iw + 2, mh)
            ly = my + max(mh, 0) + (0 if self.compact else 1)
            bx = ix + iw                                          # under the map, right: the two views of it
            r = self.result
            for bid, text, act, ok in (("range_fit", "Whole search range", self.fit_search, bool(r and r.get("range"))),
                                       ("farm_fit", "Back to the farm", self.back_to_farm, True)):
                bx -= len(text) + 4
                self.button(bid, bx, ly, len(text) + 4, text, act, primary=False, disabled=not ok, tall=False)
                bx -= 1
            items = ([("■", SLIME, "Slime chunk"), ("■", OBSIDIAN, "Obsidian")] if view == "chunks" else
                     [("■", OBSIDIAN, "Obsidian"), ("■", MAGMA, "Magma block"), ("■", GLASS, "Glass")]) + \
                [("●", MARK, "AFK spot")]                       # left: their legend, only what this view draws
            lx = ix
            for sw, col, name in items:
                if lx + len(sw) + len(name) + 1 > bx - 2:
                    break
                S.put(lx, ly, sw, col)
                lx = S.put(lx + len(sw) + 1, ly, name, MUTED) + 3
            hint = "Click the map to place the AFK spot."             # the one thing the footer can't say first
            if self.mode == "manual" and lx + len(hint) < bx - 2:
                S.put(lx, ly, hint, GREEN)
            return ly - iy + 1

        self.card(x, y, w, "Map", body, right=tabs)

    def back_to_farm(self):
        self.view, self.view_auto = [self.afk[0] + 0.5, self.afk[1] + 0.5, None], True

    def fit_search(self):
        r, g = self.result, self.mapgeo
        if not (r and r.get("range") and g):
            return
        (sx, sz), rng = r["center"], r["range"]
        self.view = [sx + 0.5, sz + 0.5, min(400000.0, max(2.1 * rng / g[2], 2.1 * rng / (g[3] * g[7])))]
        self.view_auto = False

    def info_lines(self):
        """Their map info box: which way is north, and the block under the mouse."""
        lines = ["North ↑ −Z    East → +X"]
        if self.seed is None:
            lines.append("No seed yet: type one on the left to see the slime chunks")
        pt = self.hover or ((self.view[0], self.view[1]) if self.focus == "map" else None)
        if pt:
            bx, bz = math.floor(pt[0]), math.floor(pt[1])
            cx, cz = bx // 16, bz // 16
            slime = self.seed is not None and self.slime_at([cx], cz)[0]
            d2 = (bx - self.afk[0]) ** 2 + (bz - self.afk[1]) ** 2          # the spawn rule's integer offsets
            where = "nothing spawns" if d2 <= 576 else "spawns" if d2 <= 16384 else "despawns"
            lines.append("Block %d, %d    chunk %d, %d%s" % (bx, bz, cx, cz, ", slime" if slime else ""))
            lines.append("%s blocks from the AFK spot: %s" % (fmt(math.sqrt(d2)), where))
            if self.map_view == "floor":
                m = floor_block(lambda a, b: self.slime_at([a], b)[0], self.afk[0], self.afk[1], bx, bz) \
                    if self.seed is not None else None
                lines.append("Floor: %s" % (m or "outside the cleared area"))
        return lines

    def draw_map(self, x, y, w, h):
        S = self.scr
        foc = self.focus == "map"
        ix, iy, cw, ch = x, y, w, h
        pw, ph = cw, ch * 2                # the character map's pixels: half a cell each
        size = None
        g = self.term.graphics             # the help box over a Sixel map: characters while it's open
        cell = self.term.cell_px() if g and not (g == "sixel" and (self.help or self.menu)) else None
        if cell:                           # a real picture: as many pixels as the cells have (kitty: up to
            k = min(1.0, 2400 / (cw * cell[0])) if g == "kitty" else 1.0     # 2400 wide, the terminal scales it)
            size = (max(1, round(cw * cell[0] * k)), max(1, round(ch * cell[1] * k)))
        ar = size[1] / ph / (size[0] / pw) if size else 1.0      # a half cell's height over its width
        if self.view[2] is None:          # fit the floor square
            span = 2 * RADIUS + 40
            self.view[2] = max(span / pw, span / (ph * ar))
        bpp = self.view[2]                 # blocks per half-cell pixel across (times ar down)
        left, top = self.view[0] - pw * bpp / 2, self.view[1] - ph * bpp * ar / 2
        self.mapgeo = (ix, iy, pw, ph, left, top, bpp, ar)
        self.hit("map", ix, iy, cw, ch)
        self.focusable("map", y, y + h)
        r = self.result
        sbox = None
        if r and r.get("range") and r["mode"] != "manual":            # where the last search looked
            (sx, sz), rng = r["center"], r["range"]
            sbox = (sx - rng, sz - rng, sx + rng, sz + rng)
        if size:
            return self.draw_map_picture(ix, iy, cw, ch, size, left, top, bpp, sbox, foc)
        key = (pw, ph, left, top, bpp, self.seed, self.afk, tuple(self.layers.values()), foc and self.mode == "manual",
               sbox, self.map_view)
        if self.map_cache[0] != key:
            self.map_cache = (key, self.map_cells(pw, ph, left, top, bpp, foc and self.mode == "manual", sbox))
        cells = self.map_cache[1]
        k = 0
        for rr in range(ch):
            row = (iy + rr) * S.w
            for c in range(cw):
                t, fg, bg = cells[k]
                S._set(row + ix + c, row, t, fg, bg, False)
                k += 1
        lines = self.info_lines()                                      # the info box, top left
        bw = min(cw - 4, max(len(l) for l in lines) + 4)
        if len(lines) + 2 <= ch // 4 and bw <= cw // 2:
            S.fill(ix + 2, iy + 1, bw, len(lines) + 2, INFO_BG)
            S.box(ix + 2, iy + 1, bw, len(lines) + 2, INFO_EDGE)
            for i, l in enumerate(lines):
                S.put(ix + 4, iy + 2 + i, l[:bw - 4], INFO_TEXT, INFO_BG)
        else:                                                          # a small map: one line, so it hides less
            l = " %s " % (lines[1] if len(lines) > 1 else "N ↑ −Z   E → +X")
            S.put(ix, iy, l[:cw], INFO_TEXT, INFO_BG)
        if foc:                                                        # focus: a green frame line under the map
            S.put(ix, iy + ch - 1, "▁" * cw, GREEN)

    def draw_map_picture(self, ix, iy, cw, ch, size, left, top, bpp, sbox, foc):
        """Their canvas as a picture under the map's cells. The cells are left on the terminal's own background,
        so the picture shows through them; the words - circle labels, rulers, compass, the info line - are
        ordinary text on top, in the app's font."""
        S = self.scr
        W, H = size
        s = W / (cw * bpp)                                       # picture pixels per block
        cpx, cpy = W / cw, H / ch                                # picture pixels per cell
        S.fill(ix, iy, cw, ch, CLEAR)
        ax, az = self.afk[0] + 0.5, self.afk[1] + 0.5
        X, Z = (lambda v: (v - left) * s), (lambda v: (v - top) * s)
        S.push(ix, iy, ix + cw, iy + ch)

        def text(px, py, t, fg, bold=False):
            """t with its left edge at picture x px, in the cell row holding picture y py - on a small plate of
            the map's own green with a space each side, so a slime chunk under it never cuts through it."""
            cx, cy = max(0, math.floor(px / cpx) - 1), math.floor(py / cpy)
            if 0 <= cy < ch and 0 <= cx and cx + len(t) + 2 <= cw:
                S.put(ix + cx, iy + cy, " %s " % t, fg, MAP_BG, bold=bold)
                return cx + len(t) + 1
            return None
        # rulers along the bottom and the left (their labelStep, wide enough for the longest number here)
        far = max(abs(int(left)), abs(int(left + W / s)), abs(int(top)), abs(int(top + H / s)))
        need = max(90, (len(str(far)) + 3) * cpx, 2.2 * cpy)
        step = max(16, 16 * 2 ** max(0, math.ceil(math.log2(need / (16 * s)))))
        v = math.ceil(left / step) * step
        while v < left + W / s:
            text(X(v) + 3, H - cpy / 2, str(v), AXIS)
            v += step
        v = math.ceil(top / step) * step
        while v < top + H / s:
            if 3 * cpy < Z(v) - 3 < H - cpy:
                text(4, Z(v) - 3 - cpy / 2, str(v), AXIS)
            v += step
        text(W - 12 * cpx, cpy * 0.5, "−Z north ↑", COMPASS)       # their compass, top right
        text(W - 12 * cpx, cpy * 1.5, "+X east  →", COMPASS)
        # the circle labels, right of each circle at the AFK spot's height, and the spot's own
        mx, mz = X(ax), Z(az)
        kx1 = (self.afk[0] + RADIUS) // 16
        end = -1
        for px, label, col in ((mx + 128 * s + 5, "128", RING128), (X((kx1 + 1) * 16) + 5, "floor", FLOOR_SQ)):
            if 128 * s > 20 and math.floor(px / cpx) > end:
                end = text(px, mz - 5 - cpy / 2, label, col) or end
        if 24 * s > 20:
            text(mx + 24 * s + 5, mz - 5 - cpy / 2, "24", RING24)
        text(mx - 10 - 3 * cpx, mz - 8 - cpy / 2, "AFK", MARK, bold=True)     # left of the cross: 24's label is right
        S.pop()
        # the info line, top left (their #mapInfo): what you're looking at, or the block under the mouse
        line = self.info_line()[:max(0, cw - 17)]                # clear of the compass
        strip = None
        if ch >= 6 and line:
            S.put(ix + 1, iy + 1, " %s " % line, INFO_TEXT, INFO_BG)
            strip = (round(1 * cpx) - 1, round(1 * cpy) - 1, round((len(line) + 3) * cpx), round(2 * cpy))
        hb = (math.floor(self.hover[0]), math.floor(self.hover[1])) if self.hover and s >= 2 else None
        base = (W, H, left, top, s, self.seed, self.afk, self.map_view, sbox, foc, foc and self.mode == "manual")
        self.pic_req = (ix, iy, cw, ch, (base, hb, strip), lambda: self.picture(base, hb, strip))

    def info_line(self):
        """One line, like theirs: the view and the spot, or the block under the mouse."""
        pt = self.hover or ((self.view[0], self.view[1]) if self.focus == "map" else None)
        if not pt and self.seed is None:
            return "No seed yet · type one on the left to see the slime chunks"
        if not pt:
            return "%s · AFK spot %d, %d" % ("Slime chunks" if self.map_view == "chunks" else
                                              "Floor at y %d" % self.floor_y(), self.afk[0], self.afk[1])
        bx, bz = math.floor(pt[0]), math.floor(pt[1])
        cx, cz = bx // 16, bz // 16
        slime = self.slime_at([cx], cz)[0]
        d2 = (bx - self.afk[0]) ** 2 + (bz - self.afk[1]) ** 2           # the spawn rule's integer offsets
        where = "nothing spawns" if d2 <= 576 else "spawns" if d2 <= 16384 else "despawns"
        out = "Block %d, %d · chunk %d, %d · %s%s from AFK, %s" % (
            bx, bz, cx, cz, "" if self.seed is None else "slime · " if slime else "normal · ", fmt(math.sqrt(d2)), where)
        if self.map_view == "floor" and self.seed is not None:
            out += " · %s" % (floor_block(lambda a, b: self.slime_at([a], b)[0], self.afk[0], self.afk[1], bx, bz)
                              or "not cleared")
        return out

    def picture(self, base, hb, strip):
        """The map picture: the painted base (cached), then the hover square and the info line's frame."""
        if self.pic_cache[0] != base:
            self.pic_cache = (base, self.paint_map(*base))
        p = self.pic_cache[1]
        if hb is None and strip is None:
            return p
        p = p.copy()
        W, H, left, top, s = base[:5]
        if hb:                                                   # their hover: a white square round the block
            x0, z0 = round((hb[0] - left) * s), round((hb[1] - top) * s)
            x1, z1 = round((hb[0] + 1 - left) * s) - 1, round((hb[1] + 1 - top) * s) - 1
            p.dashed_rect(x0, z0, x1, z1, WHITE, 0xaa / 255, 1 << 20, 0)
        if strip:
            p.dashed_rect(*strip, INFO_EDGE, 1.0, 1 << 20, 0)
        return p

    def paint_map(self, W, H, left, top, s, seed, afk, view, sbox, foc, manual):
        """RedenMC's draw(), in pixels: slime chunks (dark under the Floor view), the farm's layer (obsidian on
        the floor chunks; on the Floor view the glass, magma and obsidian the commands build), the chunk grid,
        the floor square in their dashed 160-circle style, the solid 128 and dashed 24 circles, the search
        range, and the AFK cross."""
        P = Picture(W, H, MAP_BG)
        X, Z = (lambda v: round((v - left) * s)), (lambda v: round((v - top) * s))
        floor_view = view == "floor"
        col = P.code(SLIME_DIM if floor_view else SLIME)
        ax, az = afk
        kx0, kx1, kz0, kz1 = (ax - RADIUS) // 16, (ax + RADIUS) // 16, (az - RADIUS) // 16, (az + RADIUS) // 16
        fl = [] if seed is None else [(a, b) for b in range(kz0, kz1 + 1)
                                      for a, v in zip(range(kx0, kx1 + 1), slime_row(seed, kx0, b, kx1 - kx0 + 1)) if v]
        cx0, cx1 = math.floor(left / 16), math.floor((left + W / s) / 16)
        cz0, cz1 = math.floor(top / 16), math.floor((top + H / s) / 16)
        bgrow = P.code(MAP_BG) * W
        if seed is None:                                         # no seed yet: an empty field, the rest as usual
            pass
        elif 16 * s >= 1.5:                                      # every chunk, a square
            xs = [min(W, max(0, X(c * 16))) for c in range(cx0, cx1 + 2)]
            for cz in range(cz0, cz1 + 1):
                flags = slime_row(seed, cx0, cz, cx1 - cx0 + 1)
                if not any(flags):
                    continue
                row = bytearray(bgrow)
                for i, f in enumerate(flags):
                    if f and xs[i + 1] > xs[i]:
                        row[xs[i]:xs[i + 1]] = col * (xs[i + 1] - xs[i])
                P.rows(Z(cz * 16), Z(cz * 16 + 16), row)
        else:                                                    # chunks under a pixel: like their chunkStep, one
            B = 3                                                # chunk sampled per 3-pixel square, so far out looks
            on, off = col * B, P.code(MAP_BG) * B                # like the dots a little closer in
            cxs = [math.floor((left + (i * B + B / 2) / s) / 16) for i in range(math.ceil(W / B))]
            for j in range(math.ceil(H / B)):
                flags = self.slime_at(cxs, math.floor((top + (j * B + B / 2) / s) / 16))
                if any(flags):
                    P.rows(j * B, j * B + B, b"".join(on if f else off for f in flags)[:W])
        if floor_view:                                           # glass over the cleared area, then magma, obsidian
            P.tint(X((kx0 - 1) * 16), Z((kz0 - 1) * 16), X((kx1 + 2) * 16), Z((kz1 + 2) * 16), GLASS_RGB, GLASS_A)
            for a, b in fl:                                      # the one-block border, at least a pixel wide
                P.rect(min(X(a * 16 - 1), X(a * 16) - 1), min(Z(b * 16 - 1), Z(b * 16) - 1),
                       max(X(a * 16 + 17), X(a * 16 + 16) + 1), max(Z(b * 16 + 17), Z(b * 16 + 16) + 1), MAGMA)
        for a, b in fl:
            P.rect(X(a * 16), Z(b * 16), max(X(a * 16 + 16), X(a * 16) + 1), max(Z(b * 16 + 16), Z(b * 16) + 1), OBSIDIAN)
        # the grid: every chunk (wider apart when tiny), every block too from 7 pixels a block
        step = max(16, 16 * 2 ** math.ceil(math.log2(24 / (16 * s)))) if s < 0.3 else 16
        for every, (gc, ga) in ((step, GRID_FINE if s > 2 else GRID_COARSE),) + (((1, GRID_BLOCK),) if s >= 7 else ()):
            v = math.ceil(left / every) * every
            while v <= left + W / s:
                if every == 1 and v % 16 == 0 and step == 16:
                    v += 1
                    continue
                x = math.floor((v - left) * s)
                P.tint(x, 0, x + 1, H, gc, ga)
                v += every
            v = math.ceil(top / every) * every
            while v <= top + H / s:
                if not (every == 1 and v % 16 == 0 and step == 16):
                    y = math.floor((v - top) * s)
                    P.tint(0, y, W, y + 1, gc, ga)
                v += every
        mx, mz = (ax + 0.5 - left) * s, (az + 0.5 - top) * s
        P.dashed_rect(X(kx0 * 16), Z(kz0 * 16), X((kx1 + 1) * 16), Z((kz1 + 1) * 16), FLOOR_SQ, 1.0, 7, 5)
        if 128 * s >= 2:
            P.ring(mx, mz, 128 * s, 1.8, RING128)
        if 24 * s >= 2:
            P.ring(mx, mz, 24 * s, 1.2, RING24, (4, 4))
        if sbox and not floor_view:
            P.dashed_rect(X(sbox[0]), Z(sbox[1]), X(sbox[2] + 1), Z(sbox[3] + 1), SEARCH_SQ, 0x99 / 255, 5, 5)
        cx_, cz_ = math.floor(mx), math.floor(mz)                # their cross: 1.5 px lines, 9 px arms, and a dot
        for a, w in ((1.0, 0), (0.25, -1), (0.25, 1)):
            P.tint(cx_ - 9, cz_ + w, cx_ + 10, cz_ + w + 1, MARK, a)
            P.tint(cx_ + w, cz_ - 9, cx_ + w + 1, cz_ + 10, MARK, a)
        P.disc(mx, mz, 3.5, MARK)
        if manual:                                               # where Enter places the spot
            c, d = W // 2, H // 2
            P.tint(c - 5, d, c + 6, d + 1, WHITE, 0.8)
            P.tint(c, d - 5, c + 1, d + 6, WHITE, 0.8)
        if foc:                                                  # keyboard focus: a green frame
            for x0, y0, x1, y1 in ((0, 0, W, 2), (0, H - 2, W, H), (0, 0, 2, H), (W - 2, 0, W, H)):
                P.rect(x0, y0, x1, y1, GREEN)
        return P

    def send_picture(self, full):
        """After the cells (kitty): place the new map picture if it changed, or take it away if the map isn't on
        screen. Returns the bytes to send."""
        req, old = self.pic_req, self.pic_on
        if req is None:
            self.pic_on, self.pic_sent = None, None
            return b"\x1b_Ga=d,d=I,i=%d,q=2\x1b\\" % old if old else b""
        ix, iy, cw, ch, key, build = req
        if old and not full and self.pic_sent == (ix, iy, cw, ch, key):
            return b""
        new = PIC_IDS[1] if old == PIC_IDS[0] else PIC_IDS[0]
        out = b"\x1b[%d;%dH" % (iy + 1, ix + 1) + build().kitty(new, cw, ch)
        if old:
            out += b"\x1b_Ga=d,d=I,i=%d,q=2\x1b\\" % old
        self.pic_on, self.pic_sent = new, (ix, iy, cw, ch, key)
        return out

    def send_sixel(self, full, prev):
        """Sixel: the picture is drawn into the cells, so after any change over the map it goes out again and
        the map's words are written back on top of it, each cell on the picture's own colour there."""
        req = self.pic_req
        if req is None:
            self.pic_on, self.pic_sent = None, None
            return b""
        ix, iy, cw, ch, key, build = req
        if self.pic_on and not full and self.pic_sent == (ix, iy, cw, ch, key) and \
                not self.scr.changed(prev, ix, iy, cw, ch):
            return b""
        self.pic_on, self.pic_sent = True, (ix, iy, cw, ch, key)
        pic = build()
        cpx, cpy = pic.w / cw, pic.h / ch

        def under(x, y):                                         # the commonest colour in the cell's pixels
            ps = [pic.px[min(pic.h - 1, int((y - iy + fy) * cpy)) * pic.w + min(pic.w - 1, int((x - ix + fx) * cpx))]
                  for fy in (0.25, 0.5, 0.75) for fx in (0.25, 0.5, 0.75)]
            return pic.pal[max(set(ps), key=ps.count)]
        return b"\x1b[%d;%dH" % (iy + 1, ix + 1) + pic.sixel() + self.scr.patch(ix, iy, cw, ch, self.term.colors, under)

    def slime_at(self, cxs, cz):
        """Flags for the given chunk columns in row cz, cached per seed."""
        if self.seed is None:
            return [0] * len(cxs)
        need = [c for c in cxs if (c, cz) not in self.chunks]
        if need:
            if len(self.chunks) > 1_500_000:
                self.chunks = {}
                need = cxs
            lo, hi = min(need), max(need)
            if hi - lo < 4 * len(need):
                for i, v in enumerate(slime_row(self.seed, lo, cz, hi - lo + 1)):
                    self.chunks[(lo + i, cz)] = v
            else:
                for c in set(need):
                    self.chunks[(c, cz)] = slime_row(self.seed, c, cz, 1)[0]
        return [self.chunks[(c, cz)] for c in cxs]

    def map_cells(self, pw, ph, left, top, bpp, crosshair, sbox):
        """The map as cells, two square pixels each (▀: fg = the top pixel, bg = the bottom one), crisp pixel
        art in their colours. Chunks view: slime chunks as squares while a chunk is 2+ pixels wide, below that
        the share of slime chunks under each pixel (single-chunk specks are just noise at that scale). Floor
        view: what the perimeter commands build, block by block (slime_common.floor_block). Circles, labels and
        the AFK cross only where they are big enough to read."""
        L = self.layers
        ax, az = self.afk[0] + 0.5, self.afk[1] + 0.5
        inv = 1.0 / bpp                                      # pixels per block
        xs = [left + (i + 0.5) * bpp for i in range(pw)]
        zs = [top + (j + 0.5) * bpp for j in range(ph)]
        cxs = [math.floor(v / 16) for v in xs]
        czs = [math.floor(v / 16) for v in zs]
        dxs = [v - ax for v in xs]
        grid = 16 * inv >= 6
        colb = [grid and i > 0 and cxs[i] != cxs[i - 1] for i in range(pw)]
        floor_view = self.map_view == "floor"
        shade = not floor_view and 16 * inv < 2
        if shade:
            q = bpp / 4
            sub = [math.floor((v - q) / 16) for v in xs] + [math.floor((v + q) / 16) for v in xs]
            dens = [mix(MAP_BG, SLIME, t) for t in (0, 0.35, 0.6, 0.82, 1.0)]
        R2, D2 = 128 * 128, 24 * 24
        line128 = 128 * inv >= 3
        line24 = 24 * inv >= 2.5
        near_r2, near_d2 = max(0, 128 - 1.5 * bpp) ** 2, max(0, 24 - 1.5 * bpp) ** 2

        def outline(dx, dz, r2, p=bpp):
            # inside the circle, with one of its 4 neighbours outside: a clean, connected one-pixel line
            return dx * dx + dz * dz <= r2 and ((dx + p) ** 2 + dz * dz > r2 or (dx - p) ** 2 + dz * dz > r2 or
                                               dx * dx + (dz + p) ** 2 > r2 or dx * dx + (dz - p) ** 2 > r2)
        # the floor square (chunks within +-152) and where the last search looked: snapped to pixels, dashed
        fx0, fz0 = ((self.afk[0] - RADIUS) // 16) * 16, ((self.afk[1] - RADIUS) // 16) * 16
        fx1, fz1 = ((self.afk[0] + RADIUS) // 16 + 1) * 16, ((self.afk[1] + RADIUS) // 16 + 1) * 16
        pxl = lambda v: math.floor((v - left) * inv)
        pzl = lambda v: math.floor((v - top) * inv)
        boxes = []
        for b in ([(fx0, fz0, fx1, fz1, FLOOR_SQ)] if not floor_view else []) + ([sbox + (SEARCH_SQ,)] if sbox else []):
            x0, z0, x1, z1 = pxl(b[0]), pzl(b[1]), pxl(b[2]), pzl(b[3])
            boxes.append((x0, z0, x1, z1, b[4], (x1 - x0) >= 12))
        mi, mj = math.floor((ax - left) * inv), math.floor((az - top) * inv)
        arm = 2 if 24 * inv >= 6 else 1                     # the AFK cross: arms of 2 pixels, 1 when small
        seed_ok = self.seed is not None
        slime_fn = lambda a, b: self.slime_at([a], b)[0]
        mat = {"obsidian": OBSIDIAN, "magma": MAGMA, "glass": GLASS}
        kx0, kx1 = (self.afk[0] - RADIUS) // 16, (self.afk[0] + RADIUS) // 16
        kz0, kz1 = (self.afk[1] - RADIUS) // 16, (self.afk[1] + RADIUS) // 16
        edge = floor_view and seed_ok and bpp > 1
        if edge:
            # a pixel wider than a block: the one-block magma border as the pixels around the obsidian ones, so it
            # shows on every side of a chunk instead of wherever the centre sample happens to land
            kx0, kx1 = (self.afk[0] - RADIUS) // 16, (self.afk[0] + RADIUS) // 16
            kz0, kz1 = (self.afk[1] - RADIUS) // 16, (self.afk[1] + RADIUS) // 16
            fset = {(a, b) for b in range(kz0, kz1 + 1) for a, v in zip(range(kx0, kx1 + 1),
                                                                         self.slime_at(list(range(kx0, kx1 + 1)), b)) if v}
            obs = [[(a, b) in fset for a in cxs] + [False] for b in czs] + [[False] * (pw + 1)]
        pix = []
        for j in range(ph):
            wz, cz = zs[j], czs[j]
            dz = wz - az
            dz2 = dz * dz
            rowb = grid and j > 0 and cz != czs[j - 1]
            counts = flags = None
            if seed_ok and shade:
                q = bpp / 4
                fa = self.slime_at(sub, math.floor((wz - q) / 16))
                fb = self.slime_at(sub, math.floor((wz + q) / 16))
                counts = [fa[i] + fa[i + pw] + fb[i] + fb[i + pw] for i in range(pw)]
            elif seed_ok:
                flags = self.slime_at(cxs, cz)
            hz = [(x0, x1, col, dash) for x0, z0, x1, z1, col, dash in boxes if j in (z0, z1)]
            vz = [(x0, x1, col) for x0, z0, x1, z1, col, dash in boxes if z0 <= j <= z1 and (not dash or (j - z0) % 5 < 3)]
            bz = math.floor(wz)
            out = []
            for i in range(pw):
                dx = dxs[i]
                d2 = dx * dx + dz2
                c = None
                if floor_view and seed_ok:
                    m = floor_block(slime_fn, self.afk[0], self.afk[1], math.floor(xs[i]), bz)
                    if edge and m != "obsidian" and any(obs[j + b][i + a] for a in (-1, 0, 1) for b in (-1, 0, 1)):
                        m = "magma"                                 # (index -1 is the all-False pad)
                    if m:
                        c = mat[m]
                if c is None:
                    if counts is not None:
                        c = dens[counts[i]]
                    elif flags and flags[i]:
                        c = SLIME_DIM if floor_view else OBSIDIAN if kx0 <= cxs[i] <= kx1 and kz0 <= cz <= kz1 else SLIME
                    else:
                        c = GRID if colb[i] or rowb else MAP_BG
                if line128 and near_r2 < d2 <= R2 and outline(dx, dz, R2):
                    c = RING128
                elif line24 and near_d2 < d2 <= D2 and outline(dx, dz, D2) and \
                        int((math.atan2(dz, dx) + math.pi) * 24 * inv / 2) % 2 == 0:
                    c = RING24
                for x0, x1, col, dash in hz:
                    if x0 <= i <= x1 and (not dash or (i - x0) % 5 < 3):
                        c = col
                for x0, x1, col in vz:
                    if i == x0 or i == x1:
                        c = col
                if (i == mi and abs(j - mj) <= arm) or (j == mj and abs(i - mi) <= arm):
                    c = MARK
                out.append(c)
            pix.append(out)
        cells = []
        for r in range(ph // 2):
            a, b = pix[2 * r], pix[2 * r + 1]
            for i in range(pw):
                cells.append((" ", a[i], a[i]) if a[i] == b[i] else ("▀", a[i], b[i]))
        cw, chh = pw, ph // 2

        def text(cx, cy, s, fg):
            for k, ch in enumerate(s):
                if 0 <= cx + k < cw and 0 <= cy < chh:
                    cells[cy * cw + cx + k] = (ch, fg, cells[cy * cw + cx + k][2])
        if not floor_view and L["coords"] and 16 * inv >= 9:              # chunk coordinates, when they fit
            for j in range(ph):
                if j == 0 or czs[j] != czs[j - 1]:
                    for i in range(pw):
                        if i == 0 or cxs[i] != cxs[i - 1]:
                            text(i + 1, (j + 1) // 2, "%d,%d" % (cxs[i], czs[j]), SLIME_LABEL)
        # coordinate numbers along the top and left edges, every 16 x 2^k blocks
        step = 16 * 2 ** max(0, math.ceil(math.log2(max(1e-9, 12 * bpp / 16))))
        v = math.ceil(left / step) * step
        while v < left + pw * bpp:
            i = math.floor((v - left) * inv)
            if 1 <= i < cw - 8:
                text(i, chh - 1, str(int(v)), AXIS)
            v += step
        zstep = 16 * 2 ** max(0, math.ceil(math.log2(max(1e-9, 6 * 2 * bpp / 16))))
        v = math.ceil(top / zstep) * zstep
        while v < top + ph * bpp:
            jj = math.floor((v - top) * inv) // 2
            if 0 <= jj < chh - 1:
                text(cw - len(str(int(v))) - 1, jj, str(int(v)), AXIS)
            v += zstep
        if 0 <= mi < pw and 0 <= mj < ph:
            text(mi + 3, mj // 2 - 1, "AFK", MARK)
            for rr, col in ((128, RING128), (24, RING24)):                # their circle labels, where they fit
                if rr * inv > 10:
                    text(mi + math.ceil(rr * inv) + 2, mj // 2 - 1, str(rr), col)
        if crosshair:
            text(pw // 2, ph // 4, "+", MARK)
        return cells

    # -- 2 · perimeter commands ---------------------------------------------------------------------------------
    def wide_head(self, ix, cy, iw, title, sub):
        S = self.scr
        S.put(ix, cy, title, TEXT, bold=True)
        cy += 1
        for l in wrap(sub, iw):
            S.put(ix, cy, l, MUTED)
            cy += 1
        return cy

    def commands_content(self, x, y, w):
        S, p = self.scr, self.peri
        iw = min(w - 4, 150)
        ix = x + (w - iw) // 2
        gap = 0 if self.compact else 1
        cy = y + 1
        cx, cz = self.peri_center

        def summary(bx, by, bw):
            yy = by
            yy += self.helptext(bx, yy, bw, "Seed %s, centered on %d, %d, %s, floor at y %d." % (
                self.seed, cx, cz, band_name(self.band), self.floor_y()))
            if p:
                yy += self.helptext(bx, yy, bw, "Saved as %s." % os.path.relpath(p["path"], ROOT))
            yy += gap
            busy = self.job is not None
            self.button("gen2", bx, yy, 16, "Generate", self.generate, disabled=busy)
            self.button("open2", bx + 17, yy, 16, "Open file", self.open_txt, primary=False, disabled=not p)
            vw = min(36, bw - 36)
            if vw > 16:
                self.version_row(bx + 36, yy, vw)
            yy += self.ih() + gap
            if not p:
                yy += self.note(bx, yy, bw, "Nothing generated yet. Press Generate: it uses the perimeter center "
                                            "from the first tab.")
                return yy - by
            if self.stale():
                yy += self.note(bx, yy, bw, "Your inputs changed since these were made. Generate again before "
                                            "copying.", "warn") + gap
            stats = [("Slime chunks in the floor", "%d of %d" % (p["slime"], p["of"]), "Chunks within ±152", True),
                     ("Floor command", "%s chars" % fmt(p["sections"][3]["chars"]), "%d fills, limit 32,500" %
                      p["sections"][3]["fills"], False),
                     ("Border command", "%s chars" % fmt(p["sections"][4]["chars"]), "%d fills, %s magma blocks" % (
                         p["sections"][4]["fills"], fmt(p["border_blocks"])), False)]
            yy += self.stat_strip(bx, yy, bw, stats)
            return yy - by

        cy += self.card(ix, cy, iw, "Perimeter commands", summary) + 1
        if p:
            stale = self.stale()
            for n, name, tag in SECTIONS:
                sec = p["sections"].get(n)
                if sec:
                    title = "%d  %s%s" % (n, name, "  (needs %s)" % tag if tag else "")
                    cy += self.card(ix, cy, iw, title, lambda bx, by, bw, n=n, sec=sec:
                                    self.section_block(bx, by, bw, n, sec, stale)) + 1
        return cy - y + 1

    def section_block(self, ix, iy, iw, n, sec, stale):
        S = self.scr
        cy = iy
        cy += self.helptext(ix, cy, iw - 30, SECTION_INFO[n])
        if sec["chars"]:
            S.put(ix + iw - len("%s characters, %d fills" % (fmt(sec["chars"]), sec["fills"])), iy,
                  "%s characters, %d fills" % (fmt(sec["chars"]), sec["fills"]), MUTED)
        cy += 0 if self.compact else 1
        codew = iw - 9
        for li, line in enumerate(sec["lines"]):
            rows = [line[i:i + codew - 2] for i in range(0, len(line), codew - 2)] or [""]
            if len(rows) > 4:
                rows = rows[:4]
                rows[-1] = rows[-1][:-1] + "…"
            for r, t in enumerate(rows):                        # their coordinate-box strips
                S.fill(ix, cy + r, codew, 1, COORD_BG)
                S.put(ix + 1, cy + r, t, COORD_TEXT, COORD_BG)
            self.chip("line:%d:%d" % (n, li), ix + iw - 7, cy, "Copy", (lambda t=line: self.copy(
                t, "%s characters" % fmt(len(t)) if len(t) > 60 else None)), disabled=stale, w=7)
            cy += len(rows)
        return cy - iy

    # -- 3 · build guide ------------------------------------------------------------------------------------------
    STEPS = [
        ("Make the world", None, "Create a world with seed {seed}. Superflat is easiest: slime chunks don't depend "
                                 "on terrain, and there's almost nothing to clear."),
        ("Go there", None, "Paste each line in chat. It takes you above the farm, turns mob spawning off, and /seed "
                           "confirms the world."),
        ("Clear the area", "WorldEdit", "Clears from the floor to 24 above it. //replace air only touches blocks "
                                        "that aren't air."),
        ("Build the slime floor", None, "Paste the command into one command block and power it with a button. It "
                                        "puts obsidian in every slime chunk, then cleans up after itself."),
        ("Add the magma border", None, "The same again, once the floor is done."),
        ("Lay the glass skirt", "WorldEdit", "Glass across the cleared area at floor level."),
        ("Measure", "Carpet", "Get the repeating command block, place it, stand at the AFK spot and read "
                              "/perimeterinfo. The teleport puts you at y {tp}: move to the best height first."),
    ]

    def guide_content(self, x, y, w):
        iw = min(w - 4, 160)
        ix = x + (w - iw) // 2
        two = iw >= 112
        side = 48 if two else iw
        sw = iw - side - 2 if two else iw
        cy = y + 1
        h1 = self.card(ix, cy, sw, "Build it in game", lambda bx, by, bw: self.steps(bx, by, bw))
        sx, sy = (ix + sw + 2, cy) if two else (ix, cy + h1 + 1)
        h2 = self.card(sx, sy, side, "Best standing height", self.sec_height) + 1
        h2 += self.card(sx, sy + h2, side, "Save your reading", self.sec_reading)
        return (max(h1, h2) if two else h1 + h2 + 1) + 2

    def steps(self, ix, iy, w):
        S, p = self.scr, self.peri
        cy = iy
        cy += self.helptext(ix, cy, w, "You need WorldEdit and Carpet. The commands are the ones on the second tab.")
        cy += 0 if self.compact else 1
        ready = p is not None and not self.stale()
        for n, (title, tag, desc) in enumerate(self.STEPS):
            S.put(ix, cy, " %d " % n, ON_GREEN, GREEN, bold=True)
            xx = S.put(ix + 5, cy, title, TEXT, bold=True)
            if tag:
                S.put(xx + 2, cy, "needs %s" % tag, VIOLET)
            cy += 1
            cy += self.helptext(ix + 5, cy, w - 5, desc.format(seed=self.seed, tp=self.floor_y() + 14))
            if n == 6 and self.height and self.height_for_peri():
                b = self.height["best"]
                cy += self.helptext(ix + 5, cy, w - 5, "For this farm: feet at y %d at %d, %d, %s spawning spaces." % (
                    b["feet_y"], b["x"], b["z"], fmt(b["vanilla"])), GREEN)
            if ready:
                lines = p["sections"].get(n, {}).get("lines", [])
                cx = ix + 5
                for li, line in enumerate(lines):
                    t = "Copy seed" if n == 0 else ("Copy command, %s characters" % fmt(len(line)) if len(line) > 60 else line)
                    tw = min(len(t) + 2, w - 5)
                    if cx + tw > ix + w and cx > ix + 5:
                        cx, cy = ix + 5, cy + 1
                    cx += self.chip("step:%d:%d" % (n, li), cx, cy, t, (lambda t=line: self.copy(
                        t, "%s characters" % fmt(len(t)) if len(t) > 60 else None)), maxw=w - 5) + 1
                cy += 1
            elif n == 1:
                cy += self.helptext(ix + 5, cy, w - 5, "Generate the commands first, on the first or second tab.")
            cy += 0 if self.compact else 1
        return cy - iy

    def height_for_peri(self):
        h = self.height
        return h and h["seed"] == self.seed and h["at"] == (self.peri_center if self.peri else self.afk)

    def sec_height(self, ix, iy, iw):
        S = self.scr
        gap = 0 if self.compact else 1
        cy = iy
        cy += self.helptext(ix, cy, iw, "Every feet height from the floor to 24 above it, with the best AFK point "
                                    "within 48 blocks at each.") + gap
        h = self.height if self.height_for_peri() else None
        if h:
            b = h["best"]
            cy += self.coord_box("copy_feet", ix, cy, iw, "X: %d   Y: %d   Z: %d" % (b["x"], b["feet_y"], b["z"]),
                                 "/tp @p %d %d %d" % (b["x"], b["feet_y"], b["z"])) + gap
            self.kv(ix, cy, iw, "Spawning spaces", fmt(b["vanilla"]))
            self.kv(ix, cy + 1, iw, "/perimeterinfo reads", fmt(b["carpet"]))
            self.kv(ix, cy + 2, iw, "Against standing on the floor", "%+d" % (b["vanilla"] - h["floor"]))
            cy += 3
            vals = [r["vanilla"] for r in h["heights"]]
            lo, hi = min(vals), max(vals)
            spark, n = "▁▂▃▄▅▆▇█", len(vals)
            for i, r in enumerate(h["heights"]):
                k = 0 if hi == lo else round((r["vanilla"] - lo) / (hi - lo) * 7)
                S.put(ix + i, cy + gap, spark[k], GREEN if r is h["heights"][vals.index(hi)] else PICK_EDGE)
            S.put(ix, cy + gap + 1, str(h["heights"][0]["feet_y"]), MUTED)
            S.put(ix + n - len(str(h["heights"][-1]["feet_y"])), cy + gap + 1, str(h["heights"][-1]["feet_y"]), MUTED)
            S.put(ix + n + 2, cy + gap, "feet y", MUTED)
            cy += 2 + 2 * gap
        else:
            x, z = self.peri_center if self.peri else self.afk
            cy += self.helptext(ix, cy, iw, "For the farm at %d, %d." % (x, z)) + gap
        cy += self.button("height", ix, cy, iw, "Find the best height", self.find_height, disabled=self.job is not None)
        return cy - iy

    def sec_reading(self, ix, iy, iw):
        S = self.scr
        gap = 0 if self.compact else 1
        cy = iy
        cy += self.helptext(ix, cy, iw, "What /perimeterinfo showed. Saved readings rank above the estimate everywhere "
                                    "else.") + gap
        tw = (iw - 4) // 3
        for k, name in enumerate(("X", "Z", "Feet Y")):
            self.label(ix + k * (tw + 2), cy, name)
        cy += 1
        for k, fid in enumerate(("m_x", "m_z", "m_y")):
            self.input(fid, ix + k * (tw + 2), cy, tw if k < 2 else iw - 2 * (tw + 2))
        cy += self.ih() + gap
        self.label(ix, cy, "/perimeterinfo said")
        cy += 1
        cy += self.input("m_n", ix, cy, iw) + gap
        cy += self.button("measure", ix, cy, iw, "Save reading", self.save_reading, disabled=self.job is not None)
        m = self.measure_msg
        if m:
            t = "Saved to %s." % m["saved"]
            if m["estimate"] is not None:
                t += " The estimate there was %s, %+d from your reading." % (fmt(m["estimate"]), m["ingame"] - m["estimate"])
            cy += gap + self.note(ix, cy + gap, iw, t)
        return cy - iy

    # -- input ----------------------------------------------------------------------------------------------------
    def handle(self, ev):
        self.dirty = True
        if self.help:                                   # any key or click closes the help
            if ev[0] in ("key", "char", "paste") or (ev[0] == "mouse" and ev[1] == "press"):
                self.help = False
            return
        if self.menu:                                   # an open dropdown takes the keys and clicks first
            return self.menu_event(ev)
        if ev[0] == "key":
            self.on_key(ev[1])
        elif ev[0] == "char":
            self.on_char(ev[1])
        elif ev[0] == "paste":
            if self.kind(self.focus) == "text":
                for c in ev[1].replace("\r", "").replace("\n", " "):
                    self.edit_char(c)
        elif ev[0] == "mouse":
            self.on_mouse(*ev[1:])

    def move_focus(self, d):
        if not self.order:
            return
        i = self.order.index(self.focus) if self.focus in self.order else -1
        self.focus = self.order[(i + d) % len(self.order)]
        self.focus_moved = True

    def activate(self, fid):
        if fid == "band":
            self.open_menu()
        elif fid == "mode":
            m = ["best", "cluster", "manual"]
            self.set_mode(m[(m.index(self.mode) + 1) % 3])
        elif fid == "preset":
            self.step_preset(1, wrap_around=True)
        elif fid in self.actions:
            self.actions[fid]()

    def menu_event(self, ev):
        m, n = self.menu, len(VERSIONS)
        if ev[0] == "key":
            k = ev[1]
            if k in ("up", "left", "btab"):
                m["sel"] = (m["sel"] - 1) % n
            elif k in ("down", "right", "tab"):
                m["sel"] = (m["sel"] + 1) % n
            elif k == "enter":
                self.pick_version(m["sel"])
            elif k in ("esc", "ctrl+c"):
                self.menu = None
        elif ev[0] == "char" and ev[1] == " ":
            self.pick_version(m["sel"])
        elif ev[0] == "mouse":
            _, kind, x, y, btn = ev
            hid = self.at(x, y)
            row = int(hid[5:]) if hid and hid.startswith("vopt:") else None
            if kind == "move" and row is not None:
                m["sel"] = row
            elif kind == "press" and btn == 0:
                if row is not None:
                    self.pick_version(row)
                else:
                    self.menu = None                    # a click anywhere else just closes it

    def on_key(self, k):
        kind = self.kind(self.focus)
        if k == "ctrl+c":
            if self.job and self.job.name == "search" and not self.job.cancel.is_set():
                self.cancel()
                return self.flash("cancelling the search - ctrl+c again to quit")
            self.running = False
            return
        if k == "esc":
            return self.cancel()
        if k == "tab":
            return self.move_focus(1)
        if k == "btab":
            return self.move_focus(-1)
        if k in ("pgup", "pgdn"):
            name = self.fpos.get(self.focus, (None,))[0] or {"find": "left", "commands": "commands", "guide": "guide"}[self.tab]
            if name in self.panels:
                self.scroll[name] = max(0, self.scroll.get(name, 0) + (-1 if k == "pgup" else 1) * max(1, self.panels[name][3] - 2))
            return
        if kind == "text":
            if k in ("up", "down"):
                return self.move_focus(-1 if k == "up" else 1)
            if k == "enter":
                return self.submit(self.focus)
            return self.edit_key(k)
        if kind == "map":
            g = self.mapgeo
            if g and k in ("up", "down", "left", "right"):
                step = g[6] * max(4, g[2] // 8)
                dx, dz = {"up": (0, -step), "down": (0, step), "left": (-step, 0), "right": (step, 0)}[k]
                self.view[0] += dx
                self.view[1] += dz
                self.hover, self.view_auto = None, False
            elif k == "enter" and self.mode == "manual":
                self.place(self.view[0], self.view[1])
            return
        if kind in ("select", "seg") and k in ("left", "right"):
            if kind == "select":
                i = next(n for n, (b, _, _) in enumerate(VERSIONS) if b == self.band)
                self.band = VERSIONS[(i + (1 if k == "right" else -1)) % len(VERSIONS)][0]
            elif self.focus == "preset":
                self.step_preset(1 if k == "right" else -1)
            else:
                m = ["best", "cluster", "manual"]
                self.set_mode(m[(m.index(self.mode) + (1 if k == "right" else -1)) % 3])
            return
        if k in ("up", "left"):
            return self.move_focus(-1)
        if k in ("down", "right"):
            return self.move_focus(1)
        if k == "enter":
            self.activate(self.focus)

    def on_char(self, c):
        kind = self.kind(self.focus)
        if kind == "text":
            return self.edit_char(c)
        c = c.lower()
        if c == "q":
            self.running = False
        elif c == "?":
            self.help = True
        elif c == "t":
            self.set_theme("dark" if THEME == "light" else "light")
        elif c in "123":
            self.set_tab({"1": "find", "2": "commands", "3": "guide"}[c])
        elif c == "f":
            if self.tab != "find":
                self.set_tab("find")
            self.do_find()
        elif c == "g":
            self.generate()
        elif c == "u":
            self.use_center()
        elif c == "c":
            self.view, self.view_auto = [self.afk[0] + 0.5, self.afk[1] + 0.5, None], True
        elif c in "+=-_":
            self.zoom(0.8 if c in "+=" else 1.25)
        elif c == " ":
            self.activate(self.focus)

    def edit_char(self, c):
        f = self.f[self.focus]
        if f.numeric and not (c.isdigit() or (c == "-" and f.cur == 0 and not f.value.startswith("-"))):
            return
        if ord(c) < 32:
            return
        f.value = f.value[:f.cur] + c + f.value[f.cur:]
        f.cur += 1
        self.field_changed(self.focus)

    def edit_key(self, k):
        f = self.f[self.focus]
        v, c = f.value, f.cur
        if k == "backspace" and c > 0:
            f.value, f.cur = v[:c - 1] + v[c:], c - 1
        elif k == "delete" and c < len(v):
            f.value = v[:c] + v[c + 1:]
        elif k == "left":
            f.cur = max(0, c - 1)
        elif k == "right":
            f.cur = min(len(v), c + 1)
        elif k in ("home", "ctrl+a"):
            f.cur = 0
        elif k in ("end", "ctrl+e"):
            f.cur = len(v)
        elif k == "ctrl+u":
            f.value, f.cur = v[c:], 0
        elif k == "ctrl+k":
            f.value = v[:c]
        elif k == "ctrl+w":
            s = v[:c].rstrip()
            s = s[:s.rfind(" ") + 1] if " " in s else ""
            f.value, f.cur = s + v[c:], len(s)
        else:
            return
        if f.value != v:
            self.field_changed(self.focus)

    def at(self, x, y):
        for hid, a, b, c, d in reversed(self.hits):
            if a <= x < c and b <= y < d:
                return hid
        return None

    def on_mouse(self, kind, x, y, btn):
        g = self.mapgeo
        in_map = g and g[0] <= x < g[0] + g[2] and g[1] <= y < g[1] + g[3] // 2
        if kind in ("wheelup", "wheeldown"):
            if in_map:
                return self.zoom(0.8 if kind == "wheelup" else 1.25, x - g[0] + 0.5, (y - g[1]) * 2 + 1)
            for name, (px, py, pw, ph, used) in self.panels.items():
                if px <= x < px + pw and py <= y < py + ph:
                    self.scroll[name] = max(0, self.scroll.get(name, 0) + (-3 if kind == "wheelup" else 3))
            return
        if kind == "move":
            hv = (g[4] + (x - g[0] + 0.5) * g[6], g[5] + ((y - g[1]) * 2 + 1) * g[6] * g[7]) if in_map else None
            if hv != self.hover:
                self.hover = hv
            else:
                self.dirty = False
            return
        if kind == "drag" and self.drag and btn == 0:
            sx, sy, vx, vz, _ = self.drag
            bpp = self.view[2]
            self.view[0] = vx - (x - sx) * bpp
            self.view[1] = vz - (y - sy) * 2 * bpp * (g[7] if g else 1.0)
            self.drag = (sx, sy, vx, vz, self.drag[4] or abs(x - sx) + abs(y - sy) > 0)
            self.hover, self.view_auto = None, False
            return
        if kind == "release":
            d, self.drag = self.drag, None
            if d and not d[4] and in_map and self.mode == "manual":
                self.place(g[4] + (x - g[0] + 0.5) * g[6], g[5] + ((y - g[1]) * 2 + 1) * g[6] * g[7])
            return
        if kind != "press" or btn != 0:
            return
        hid = self.at(x, y)
        if hid is None:
            return
        if hid == "map":
            self.focus = "map"
            self.drag = (x, y, self.view[0], self.view[1], False)
            return
        if hid.startswith("mode:"):
            self.focus = "mode"
            return self.actions[hid]()
        if hid in self.f:
            self.focus = hid
            f, tx = self.f[hid], self.fieldx.get(hid)
            if tx is not None:
                k, wsum = f.off, 0
                while k < len(f.value) and wsum + cwidth(f.value[k]) <= x - tx:
                    wsum += cwidth(f.value[k])
                    k += 1
                f.cur = k
            return
        if hid in self.order:
            self.focus = hid
        self.activate(hid)

    # -- loop -----------------------------------------------------------------------------------------------------
    def run(self):
        self.render()
        if self.seed is not None and "perimeter_gen" not in self.missing:
            self.generate(remember=False)  # real numbers in the cards from the start - but not "your" seed yet
        threading.Thread(target=self.watch_minecraft, daemon=True).start()
        last = 0.0
        while self.running:
            size = self.term.size()
            if size != (self.W, self.H):
                self.W, self.H = size
                self.prev = None
                self.dirty = True
                if self.view_auto:
                    self.view[2] = None           # re-fit the map to the new size
            self.drain()
            if self.toast and time.time() > self.toast[1]:
                self.toast = None
                self.dirty = True
            if self.job and time.time() - last > 0.1:
                self.dirty = True
            if self.dirty:
                self.dirty = False
                self.render()
                last = time.time()
            data = self.term.read(0.05 if self.job else 0.25)
            if self.pending and not data:
                data = self.term.read(0.03)
                if not data and self.pending == "\x1b":
                    self.pending = ""
                    self.handle(("key", "esc"))
                    continue
            if data:
                events, self.pending = parse_input(self.pending + data)
                for ev in events:
                    self.handle(ev)
                    if not self.running:
                        break

    def watch_minecraft(self):
        while self.running:
            mc = minecraft_running()
            if mc != self.minecraft:
                self.minecraft = mc
                self.dirty = True
            time.sleep(5 if os.path.isdir("/proc") else 20)


def main(argv=None, cli_module=None):
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("slime gui needs a terminal window to run in (it's a full-screen app).")
        return 1
    if cli_module is None:
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("slime_cli", os.path.join(ROOT, "slime"))
        cli_module = importlib.util.module_from_spec(importlib.util.spec_from_loader("slime_cli", loader))
        loader.exec_module(cli_module)
    os.chdir(ROOT)
    term = Term()
    app = App(term, cli_module)
    real_out, real_err = sys.stdout, sys.stderr
    sink = io.StringIO()
    term.start()
    try:
        sys.stdout = sys.stderr = sink           # stray prints from the tools must not scribble on the screen
        app.run()
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout, sys.stderr = real_out, real_err
        term.stop()
    if app.job:
        print("note: a %s was still running; any GPU process it started finishes on its own in seconds." % app.job.name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
