#!/usr/bin/env python3
"""vanilla_parity.py - prove the slime-chunk math matches REAL Minecraft.

Every self-test in this project checks the tools against slime_core.h or
against SlimeFinder.jar - other programs. This checks them against the game
itself: vanilla_parity/GameOracle.java loads an actual Minecraft client jar
and calls the game's own WorldgenRandom.seedSlimeChunk(...).nextInt(10) - the
exact call Slime's spawn rule makes - and every answer is compared with this
toolchain's, bit for bit. Versions before 1.18 (1.12, the betas) have no such
static method: vanilla_parity/OldGameOracle.java calls their Chunk's own
getRandomWithSeed(987234911).nextInt(10) instead, on an empty chunk and world
with just the fields that method reads set (found in the jar's bytecode).

  1. core       slime_core.h isSlimeChunk, CPU and GPU builds, on 20M random
                (seed, chunk) pairs: near spawn, anywhere in the world border,
                any int32 (every overflow path), and special seeds
  2. maps       complete 1001x1001-chunk maps at both record spots, the
                origin, and both world-border corners
  3. slime_gpu  its optimized bit/score kernels END TO END: best score over
                801x801 centres vs the same score computed from the game's map
  4. perimeter  perimeter_setup's rig floor: every chunk it fills vs the game
  6. spawn rule the game's own NaturalSpawner bytecode: a spawn needs d^2 > 576
                (strict) - the rule slime_refine and afk_rescan's vanilla_* use.
                1.12 and the betas allow d^2 >= 576 (inclusive): there the
                Carpet count is the in-game one, and that's reported, not failed
  7. afk_rescan its Carpet (/perimeterinfo) and vanilla counts at feet heights
                dy 0/12/23/24, recounted independently from the game's map
  5. perimeter_gen  the Slime Chunk Perimeter Generator's obsidian floor AND
                magma border, block by block, vs the game's map (border
                recomputed independently from the game map, not from its code)
  8. studio map slime_common.slime_row - the formula SlimeByte
                (./slime gui) draws its map with: the same game maps and the
                first 2M random cases, bit for bit, its floor count vs the
                game map and perimeter_gen's own, and its Floor tab
                (slime_common.floor_block) vs the commands, block by block

For the commands themselves running in a real vanilla server, see
vanilla_world_test.py.

    ./vanilla_parity.py                   every jar found (Prism / .minecraft), betas included
    ./vanilla_parity.py --jar path/to/client.jar [--jar ...] [--cases 20000000]

Needs a JDK (javac) and ./build.sh to have been run.
"""
import argparse
import glob
import struct
import os
import re
import subprocess
import sys

from slime_common import ROOT, floor_block, perimeter_band, require_tools, run_perimeter_gen, say, slime_row, tool

PD = os.path.join(ROOT, "vanilla_parity")
BUILD = os.path.join(ROOT, "main", "work", "parity")

# (label, seed, centre chunk x, centre chunk z, run slime_gpu there?)
WINDOWS = [
    ("66.04 record spot", 9029506488461633794, 230, 436, True),
    ("66.21 record spot", -89761025938370956, 2548, 338, True),
    ("origin, seed 0", 0, 0, 0, True),
    ("+X+Z world border corner", 12345, 1874499, 1874499, False),
    ("-X-Z world border corner", -987654321, -1874500, -1874500, False),
]
JAVA = "java"
STUDIO_CASES = 2_000_000   # the case generator in pure Python: ~10 s for 2M
HALF = 500          # windows are (2*HALF+1)^2 chunks
GPU_M = 400         # slime_gpu --m-chunks inside a window (needs HALF >= M + 8)


def find_jars():
    pats = ["~/.local/share/PrismLauncher/libraries/com/mojang/minecraft/*/minecraft-*-client.jar",
            "~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/libraries/com/mojang/minecraft/*/minecraft-*-client.jar",
            "~/.local/share/multimc/libraries/com/mojang/minecraft/*/minecraft-*-client.jar",
            "~/.minecraft/versions/*/*.jar"]
    out = []
    for p in pats:
        out += glob.glob(os.path.expanduser(p))
    return sorted(set(out))


def version_of(jar):
    m = re.search(r"minecraft-(.+)-client\.jar$", jar) or re.search(r"versions/([^/]+)/", jar)
    return m.group(1) if m else os.path.basename(jar)


def run(args, **kw):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, **kw)


def build():
    os.makedirs(BUILD, exist_ok=True)
    r = run(["javac", "-nowarn", "-d", BUILD, os.path.join(PD, "GameOracle.java"), os.path.join(PD, "OldGameOracle.java")])
    if r.returncode:
        say(r.stdout + r.stderr, "red")
        sys.exit("javac failed (need a JDK: sudo pacman -S jdk21-openjdk)")
    nvcc = next((c for c in [os.environ.get("NVCC"), "/opt/cuda/bin/nvcc", "/usr/local/cuda/bin/nvcc", "nvcc"]
                 if c and (os.path.exists(c) or c == "nvcc")), "nvcc")
    flags = ["-O2", "-std=c++17"] + (["-ccbin", os.environ["NVCC_CCBIN"]] if os.environ.get("NVCC_CCBIN") else [])
    r = run([nvcc] + flags + ["-arch=" + os.environ.get("CUDA_ARCH", "native"),
                              os.path.join(PD, "parity.cu"), "-o", os.path.join(BUILD, "parity")])
    if r.returncode:
        say(r.stdout + r.stderr, "red")
        sys.exit("nvcc failed on parity.cu")


def java_bin():
    """Newest installed java: 26.1+ jars are class-file version 69 (Java 25),
    which an older default java refuses with UnsupportedClassVersionError."""
    best = None
    for d in glob.glob("/usr/lib/jvm/*/bin/java") + glob.glob(os.path.expanduser("~/.local/share/PrismLauncher/java/*/bin/java")):
        m = re.search(r"(?:java|jdk|jre)-?(\d+)", d)
        if m and (best is None or int(m.group(1)) > best[0]):
            best = (int(m.group(1)), d)
    return os.environ.get("JAVA") or (best[1] if best else "java")


def oracle(jar, *args):
    r = run([JAVA, "-cp", BUILD, "GameOracle", jar] + [str(a) for a in args])
    if r.returncode:
        # the exception line itself, not the last "... 5 more" of its trace
        lines = [l for l in r.stderr.splitlines() if l.strip() and not l.startswith(("\tat ", "\t..."))]
        msg = lines[-1] if lines else "?"
        return None, re.sub(r"^.*?(Exception|Error): ", "", msg)
    return r.stdout.splitlines(), None


def old_spec(jar):
    """For a jar before 1.18: what OldGameOracle needs, read from the bytecode with javap - the slime class's
    own call (ldc2_w 987234911 / invokevirtual <chunk>.<m>(J)Random / bipush 10 / nextInt / ifne), the two int
    fields that method squares (x first: x*x*4987142), and the fields it reads the world seed through."""
    import zipfile
    cache = {}

    def javap(c):
        if c not in cache:
            cache[c] = run(["javap", "-c", "-p", "-cp", jar, c]).stdout
        return cache[c]

    def method(c, sig):
        while c:                                       # declared here or in a superclass
            t = javap(c)
            m = re.search(r"\n  [^\n]*?" + sig + r";\n    Code:\n(.*?)\n\n", t, re.S)
            if m:
                return [l.split("//")[-1].strip() if "//" in l else l.split(":", 1)[1].strip()
                        for l in m.group(1).splitlines()]
            sup = re.search(r"class \S+ extends (\S+)", t)
            c = sup.group(1) if sup and not sup.group(1).startswith("java.") else None
        return None

    def hops(c, code):
        """The fields a getter chain reads from `this` until a long: [(class, field, type)]."""
        out, cur = [], c
        for l in code:
            m = re.match(r"Field (?:(\S+)\.)?(\S+):(\S+)", l)
            if m:
                out.append((m.group(1) or cur, m.group(2), m.group(3)))
                if m.group(3) == "J":
                    return out
                cur = m.group(3)[1:-1].replace("/", ".") if m.group(3).startswith("L") else None
                continue
            m = re.match(r"Method (?:(\S+)\.)?(\S+):\(\)(\S+)", l)
            if m:
                sub = hops(m.group(1) or cur, method(m.group(1) or cur, r" %s\(\)" % re.escape(m.group(2))) or [])
                out += sub
                if sub and sub[-1][2] == "J":
                    return out
                cur = sub[-1][2][1:-1].replace("/", ".") if sub else None
        return out
    salt = bytes([5]) + struct.pack(">q", 987234911)
    with zipfile.ZipFile(jar) as z:
        users = [n[:-6].replace("/", ".") for n in z.namelist() if n.endswith(".class") and salt in z.read(n)]
    for u in users:
        m = re.search(r"long 987234911l\n\s+\d+: invokevirtual\s+#\d+\s+// Method (\S+)\.(\S+):\(J\)Ljava/util/Random;"
                      r"\n\s+\d+: bipush\s+10\n\s+\d+: invokevirtual\s+#\d+\s+// Method java/util/Random\.nextInt:\(I\)I"
                      r"\n\s+\d+: ifne", javap(u))
        if m:
            owner, name = m.group(1).replace("/", "."), m.group(2)
            code = method(owner, r"java\.util\.Random %s\(long\)" % re.escape(name))
            seed = hops(owner, code[:next(i for i, l in enumerate(code) if l.endswith("()J")) + 1])
            ints = [re.match(r"Field (\S+):I", l).group(1) for l in code if re.match(r"Field \S+:I", l)]
            return [owner, name, ints[0], next(f for f in ints if f != ints[0]),
                    ";".join("%s,%s" % (c, f) for c, f, _ in seed)], u
    return None, None


def old_oracle(jar, spec, *args):
    libs = os.path.join(os.path.dirname(jar), *[".."] * 4)          # .../libraries, for 1.12's guava
    r = run([JAVA, "--sun-misc-unsafe-memory-access=allow", "-cp", BUILD, "OldGameOracle", jar, os.path.normpath(libs)]
            + spec + [str(a) for a in args])
    if r.returncode:
        lines = [l for l in r.stderr.splitlines() if l.strip() and not l.startswith(("\tat ", "\t...", "WARNING"))]
        return None, re.sub(r"^.*?(Exception|Error): ", "", lines[-1] if lines else "?")
    return [l for l in r.stdout.splitlines() if l.startswith(("game ", "asked "))], None


def parity(*args):
    r = run([os.path.join(BUILD, "parity")] + [str(a) for a in args])
    return r.returncode, r.stdout.rstrip("\n") + (("\n" + r.stderr.rstrip()) if r.stderr.strip() else "")


def floor16(v):
    return v // 16   # python // is floor division, same as perimeter_setup's floorDiv16


RECT = re.compile(r'Command:"fill (-?\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+) (\w+)( replace air)?"')


def parse_perimeter(path):
    """{section number: text} from a perimeter_gen commands file."""
    secs, cur = {}, None
    with open(path) as f:
        for line in f:
            m = re.match(r"--- (\d+)\. ", line)
            if m:
                cur = int(m.group(1)); secs[cur] = ""
            elif cur is not None:
                secs[cur] += line
    return secs


PERIMETER_RADIUS = 152   # perimeter_gen/src/Perimeter.c RADIUS


def expected_perimeter(slime_at, bx, bz):
    """What perimeter_gen's floor and border MUST be, derived only from a
    slime map (slime_at(cx, cz) -> 0/1, from the game). Returns
    (floor chunk set, border block set): the border is every block of the
    1-block-padded box that is not slime floor but touches it, diagonals
    included."""
    R = PERIMETER_RADIUS
    cx_min, cx_max, cz_min, cz_max = floor16(bx - R), floor16(bx + R), floor16(bz - R), floor16(bz + R)
    chunks = {(cx, cz) for cx in range(cx_min, cx_max + 1) for cz in range(cz_min, cz_max + 1) if slime_at(cx, cz)}
    X0, Z0 = cx_min * 16 - 1, cz_min * 16 - 1
    X1, Z1 = (cx_max + 1) * 16, (cz_max + 1) * 16
    is_floor = lambda X, Z: (floor16(X), floor16(Z)) in chunks
    border = set()
    for X in range(X0, X1 + 1):
        for Z in range(Z0, Z1 + 1):
            if is_floor(X, Z):
                continue
            if any(is_floor(X + dx, Z + dz) for dx in (-1, 0, 1) for dz in (-1, 0, 1)
                   if (dx or dz) and X0 <= X + dx <= X1 and Z0 <= Z + dz <= Z1):
                border.add((X, Z))
    return chunks, border


def check_perimeter_gen(bits, cx0, cz0, w, seed, bx, bz, band):
    """Rebuild what the floor and border MUST be from the game's own map and
    compare with the fills perimeter_gen emitted. Returns (ok, message)."""
    path, _ = run_perimeter_gen(seed, bx, bz, band, os.path.join(BUILD, "perimeters"))
    secs = parse_perimeter(path)
    floor_y = 0 if band == 0 else -64
    slime_at = lambda cx, cz: (bits[((cz - cz0) * w + (cx - cx0)) >> 3] >> (((cz - cz0) * w + (cx - cx0)) & 7)) & 1
    want_chunks, want_border = expected_perimeter(slime_at, bx, bz)
    problems = []

    got_chunks = set()
    for m in RECT.finditer(secs.get(3, "")):
        x0, y0, z0, x1, y1, z1, blk = int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5]), int(m[6]), m[7]
        if blk != "obsidian" or y0 != floor_y or y1 != floor_y or x0 % 16 or z0 % 16 or x1 != x0 + 15 or z1 != z0 + 15:
            problems.append("bad floor fill %s" % m[0])
        got_chunks.add((x0 // 16, z0 // 16))
    if got_chunks != want_chunks:
        problems.append("floor: %d chunks differ from the game" % len(got_chunks ^ want_chunks))

    got_border, area = set(), 0
    for m in RECT.finditer(secs.get(4, "")):
        x0, y0, z0, x1, y1, z1, blk = int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5]), int(m[6]), m[7]
        if blk != "magma_block" or not m[8] or y0 != floor_y or y1 != floor_y:
            problems.append("bad border fill %s" % m[0])
        area += (x1 - x0 + 1) * (z1 - z0 + 1)
        got_border.update((X, Z) for X in range(x0, x1 + 1) for Z in range(z0, z1 + 1))
    if area != len(got_border):
        problems.append("border fills overlap (%d blocks filled twice)" % (area - len(got_border)))
    if got_border != want_border:
        problems.append("border: %d blocks differ from the game-derived border" % len(got_border ^ want_border))
    for name, sec in ((3, "floor"), (4, "border")):
        cmd = next((l for l in secs.get(name, "").splitlines() if l.startswith("summon")), "")
        if len(cmd) > 32500:
            problems.append("%s command is %d chars, over the 32500 command-block limit" % (sec, len(cmd)))
    # SlimeByte's "slime chunks in floor": the same box and count as the game map and the generator
    R = PERIMETER_RADIUS
    cx0b, cz0b = floor16(bx - R), floor16(bz - R)
    nx, nz = floor16(bx + R) - cx0b + 1, floor16(bz + R) - cz0b + 1
    mine = sum(sum(slime_row(seed, cx0b, cz, nx)) for cz in range(cz0b, cz0b + nz))
    with open(path) as f:
        hm = re.search(r"(\d+) slime chunks of (\d+)", f.read(400))
    want = (len(want_chunks), nx * nz)
    if (mine, nx * nz) != want or not hm or (int(hm[1]), int(hm[2])) != want:
        problems.append("studio floor count %d/%d, game %d/%d, perimeter_gen %s" % (
            (mine, nx * nz) + want + (hm and hm[1] + "/" + hm[2],)))
    # SlimeByte's Floor tab (slime_common.floor_block), block by block over the //pos box of the glass
    # skirt and a chunk past it: obsidian where the floor fills put it, magma where the border fills do, glass on
    # the rest of the box (//replace air glass), nothing outside
    off = None
    pos = [(int(m[1]), int(m[3])) for m in re.finditer(r"//pos[12] (-?\d+),(-?\d+),(-?\d+)", secs.get(5, ""))]
    if len(pos) != 2:
        problems.append("glass skirt: no //pos1 //pos2")
    else:
        gx0, gx1 = sorted(q[0] for q in pos)
        gz0, gz1 = sorted(q[1] for q in pos)
        obsidian = {(X, Z) for cx, cz in got_chunks for X in range(cx * 16, cx * 16 + 16) for Z in range(cz * 16, cz * 16 + 16)}
        off = 0
        for X in range(gx0 - 16, gx1 + 17):
            for Z in range(gz0 - 16, gz1 + 17):
                exp = None if not (gx0 <= X <= gx1 and gz0 <= Z <= gz1) else \
                    "obsidian" if (X, Z) in obsidian else "magma" if (X, Z) in got_border else "glass"
                off += floor_block(slime_at, bx, bz, X, Z) != exp
        if off:
            problems.append("studio Floor tab: %d blocks differ from the commands" % off)
    msg = "%d floor chunks, %d border blocks, studio floor count %d/%d, Floor tab %s" % (
        len(got_chunks), len(got_border), mine, nx * nz, "-" if off is None else "%d blocks off" % off)
    return not problems, msg + ("" if not problems else " | " + "; ".join(problems[:4]))


def spawn_rule(jar):
    """The distance rule straight from the game's NaturalSpawner bytecode, found without names
    (obfuscated jars too): the class holding the double 576.0 whose code compares a distance with
    it as  ldc2_w 576.0 / dcmpg / ifgt  - i.e. "if d^2 > 576 carry on, else no spawn" (strict).
    Returns (class, 'strict' | 'inclusive' | None)."""
    import zipfile
    pats = (bytes([6]) + struct.pack(">d", 576.0), bytes([4]) + struct.pack(">f", 576.0))   # betas: a float
    with zipfile.ZipFile(jar) as z:
        cands = [n[:-6].replace("/", ".") for n in z.namelist()
                 if n.endswith(".class") and any(p in z.read(n) for p in pats)]
    for c in cands:
        r = run(["javap", "-c", "-p", "-cp", jar, c])
        lines = [l.strip() for l in r.stdout.splitlines()]
        for i, l in enumerate(lines[:-2]):
            if ("double 576.0d" in l or "float 576.0f" in l) and lines[i + 1].endswith(("dcmpg", "fcmpg")):
                op = lines[i + 2].split()[1] if len(lines[i + 2].split()) > 1 else ""
                if op == "ifgt":
                    return c, "strict"      # spawn only when d^2 > 576
                if op in ("iflt", "ifge"):  # 1.12 / betas: "if d^2 >= 576 go on to spawn, else skip"
                    return c, "inclusive"   # spawn when d^2 >= 576
    return None, None


def check_afk_rescan(bits, cx0, cz0, w, seed, ax, az):
    """afk_rescan's sweep vs a direct count from the game map: Carpet /perimeterinfo counts
    576 <= d^2 <= 16384, vanilla spawning 576 < d^2 <= 16384, d^2 = a^2 + b^2 + dy^2."""
    slime = lambda X, Z: (lambda i: (bits[i >> 3] >> (i & 7)) & 1)((floor16(Z) - cz0) * w + (floor16(X) - cx0))
    def count(X, Z, dy, inclusive):
        n = 0
        for b in range(-128, 129):
            for a in range(-128, 129):
                d2 = a * a + b * b + dy * dy
                if d2 > 16384 or d2 < 576 or (d2 == 576 and not inclusive):
                    continue
                n += slime(X + a, Z + b)
        return n
    fin = os.path.join(BUILD, "afk_in.csv"); fout = os.path.join(BUILD, "afk_out.csv")
    with open(fin, "w") as f:
        f.write("seed,x,z\n%d,%d,%d\n" % (seed, ax, az))
    run([tool("afk_rescan"), "--in", fin, "--out", fout, "--dy-from", "0", "--dy-to", "24", "--window", "4"])
    import csv as _csv
    rows = {int(r["dy"]): r for r in _csv.DictReader(open(fout))} if os.path.exists(fout) else {}
    bad, shown = [], []
    for dy in (0, 12, 23, 24):
        r = rows.get(dy)
        if not r:
            bad.append("no row for dy %d" % dy); continue
        X, Z = int(r["best_x"]), int(r["best_z"])
        c, v = count(X, Z, dy, True), count(X, Z, dy, False)
        if (int(r["blocks_carpet"]), int(r["blocks_vanilla"])) != (c, v):
            bad.append("dy %d: tool %s/%s, game map %d/%d" % (dy, r["blocks_carpet"], r["blocks_vanilla"], c, v))
        shown.append("dy%d %d/%d" % (dy, c, v))
    y0 = count(ax, az, 0, False)
    if rows and int(rows[0]["blocks_y0"]) != y0:
        bad.append("floor-level %s vs game map %d" % (rows[0]["blocks_y0"], y0))
    return not bad, "perimeterinfo/vanilla " + ", ".join(shown) + ("" if not bad else " | " + "; ".join(bad))


def studio_map(seed, cx0, cz0, w, h, path):
    """slime_common.slime_row (SlimeByte's map) vs a GameOracle map, bit for bit; 1 on a mismatch."""
    with open(path, "rb") as f:
        game = f.read()
    bad = slime = 0
    for j in range(h):
        row = slime_row(seed, cx0, cz0 + j, w)
        for i in range(w):
            k = j * w + i
            slime += row[i]
            bad += row[i] != (game[k >> 3] >> (k & 7)) & 1
    ok = bad == 0
    say("    studio map %dx%d: %d slime chunks, %d differ from the game  -> %s" % (w, h, slime, bad, "OK" if ok else "FAIL"),
        None if ok else "red")
    return 0 if ok else 1


def studio_cases(n, path):
    """The same against GameOracle's random cases (any int32 chunk, special seeds): the first n, regenerated
    with parity.cu's genCase - the same SplitMix64 sequence."""
    M64 = (1 << 64) - 1
    special = [0, -1, -(1 << 63), (1 << 63) - 1, 9029506488461633794, -89761025938370956, -3918692359804081918,
               1 << 48, (1 << 48) - 1, 1 << 47]
    st = [0x5EED]

    def nxt():
        st[0] = z = (st[0] + 0x9E3779B97F4A7C15) & M64
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        return z ^ (z >> 31)

    signed = lambda v, b: v - (1 << b) if v >> (b - 1) else v
    with open(path, "rb") as f:
        game = f.read((n + 7) // 8)
    bad = 0
    for i in range(n):
        k = i & 3
        seed = signed(nxt(), 64)
        if k == 3:
            seed = special[nxt() % len(special)]
        if k == 0:
            x, z = nxt() % 4001 - 2000, nxt() % 4001 - 2000
        elif k == 2:
            x, z = signed(nxt() & 0xFFFFFFFF, 32), signed(nxt() & 0xFFFFFFFF, 32)
        else:
            x, z = nxt() % 3750001 - 1875000, nxt() % 3750001 - 1875000
        bad += slime_row(seed, x, z, 1)[0] != (game[i >> 3] >> (i & 7)) & 1
    ok = bad == 0
    say("  studio map: %s random cases (any int32 chunk, special seeds), %d differ from the game  -> %s" % (
        format(n, ","), bad, "OK" if ok else "FAIL"), None if ok else "red")
    return 0 if ok else 1


def test_jar(jar, ncases):
    v = version_of(jar)
    say("\n=== Minecraft %s ===" % v, "cyan")
    fails = 0
    cls, rule = spawn_rule(jar)
    if rule == "strict":
        say("  spawn rule (%s bytecode): no spawn at d^2 <= 576 - strict, as slime_refine / afk_rescan vanilla_* assume  -> OK" % cls)
    elif rule == "inclusive":
        say("  spawn rule (%s bytecode): spawns at d^2 >= 576 - inclusive, like Carpet's /perimeterinfo: in this "
            "version the carpet count is the in-game one, the vanilla_* columns one shell short  -> NOTE" % cls, "yellow")
    else:
        say("  spawn rule: not found (%s) - the vanilla_* columns assume strict  -> FAIL" % cls, "red")
        fails += 1
    binf = os.path.join(BUILD, "cases_%s.bin" % v)
    ask = oracle
    out, err = oracle(jar, "cases", ncases, binf)
    if out is None:                                  # before 1.18: the chunk's own instance method
        spec, slime_cls = old_spec(jar)
        if spec is None:
            say("  skipped: no slime check found (%s)" % err, "yellow")
            return None
        say("  slime check: %s calls %s.%s(987234911).nextInt(10) == 0, x/z fields %s/%s" % (
            slime_cls, spec[0], spec[1], spec[2], spec[3]), "darkgray")
        ask = lambda j, *a: old_oracle(j, spec, *a)
        out, err = ask(jar, "cases", ncases, binf)
    if out is None:
        say("  skipped: %s" % err, "yellow")
        return None
    for l in out:
        say("  " + l, "darkgray")
    rc, txt = parity("cases", ncases, binf)
    say(txt, "red" if rc else None)
    fails += rc != 0
    fails += studio_cases(min(ncases, STUDIO_CASES), binf)

    for label, seed, ccx, ccz, do_gpu in WINDOWS:
        cx0, cz0, w = ccx - HALF, ccz - HALF, 2 * HALF + 1
        mf = os.path.join(BUILD, "map_%s_%d_%d.bin" % (v, ccx, ccz))
        out, err = ask(jar, "map", seed, cx0, cz0, w, w, mf)
        if out is None:
            say("  %s: oracle failed: %s" % (label, err), "red")
            fails += 1
            continue
        rc, txt = parity("map", seed, cx0, cz0, w, w, mf)
        say(txt.replace("map %dx%d" % (w, w), label + ","), "red" if rc else None)
        fails += rc != 0
        fails += studio_map(seed, cx0, cz0, w, w, mf)

        if do_gpu:
            # slime_gpu's own optimized kernels, end to end, vs the game's map
            r = run([tool("slime_gpu"), "--seed", str(seed), "--center-x", str(ccx * 16),
                     "--center-z", str(ccz * 16), "--m-chunks", str(GPU_M)])
            m = re.search(r"Best: score=(\d+) at x=-?\d+ z=-?\d+ \(chunk (-?\d+),(-?\d+)\)", r.stdout)
            if not m:
                say("    slime_gpu gave no result: %s" % (r.stdout + r.stderr).strip()[-200:], "red")
                fails += 1
            else:
                g, gx, gz = int(m.group(1)), int(m.group(2)), int(m.group(3))
                rc, txt = parity("score", cx0, cz0, w, w, mf, ccx, ccz, GPU_M, gx, gz)
                best, at = (int(t) for t in txt.split()[:2]) if rc == 0 else (-1, -1)
                where = " ".join(txt.split()[2:]) if rc == 0 else ""
                ok = g == best == at
                say("    slime_gpu best over %dx%d centres: %d chunks at chunk (%d,%d) | from game map: best %d, "
                    "that spot %d  -> %s" % (2 * GPU_M + 1, 2 * GPU_M + 1, g, gx, gz, best, at,
                                             "OK" if ok else "FAIL  (game-map best at %s)" % where),
                    None if ok else "red")
                fails += not ok

            # perimeter_setup: the exact chunks the in-game rig floors (its section 3 monolith)
            bx, bz = ccx * 16 + 8, ccz * 16 + 8
            pargs = [tool("perimeter_setup"), "--seed", str(seed), "--center-x", str(bx), "--center-z", str(bz),
                     "--radius", "152"]
            if perimeter_band(v) is not None:
                pargs += ["--game-version", v]
            r = run(pargs)
            sec = r.stdout.split("--- 3.")[1].split("--- 4.")[0] if "--- 3." in r.stdout else ""
            got = {(int(a) // 16, int(c) // 16) for a, c in
                   re.findall(r'Command:"fill (-?\d+) -?\d+ (-?\d+) ', sec)}
            with open(mf, "rb") as f:
                bits = f.read()
            want = set()
            for cz in range(floor16(bz - 152), floor16(bz + 152) + 1):
                for cx in range(floor16(bx - 152), floor16(bx + 152) + 1):
                    i = (cz - cz0) * w + (cx - cx0)
                    if (bits[i >> 3] >> (i & 7)) & 1:
                        want.add((cx, cz))
            ok = got == want and len(want) > 0
            say("    perimeter_setup floor: %d chunks filled, game says %d slime chunks there, %d differ  -> %s"
                % (len(got), len(want), len(got ^ want), "OK" if ok else "FAIL"), None if ok else "red")
            fails += not ok

            # afk_rescan: Carpet and vanilla counts at four feet heights, recounted here from the
            # GAME's map with each rule written out directly
            ok, msg = check_afk_rescan(bits, cx0, cz0, w, seed, ccx * 16, ccz * 16 + 13)
            say("    afk_rescan at (%d,%d): %s  -> %s" % (ccx * 16, ccz * 16 + 13, msg, "OK" if ok else "FAIL"),
                None if ok else "red")
            fails += not ok

        # perimeter_gen: chunk-aligned centre and an off-grid one, both inside
        # the window, at this jar's own version band
        band = perimeter_band(v)
        if band is not None:
            with open(mf, "rb") as f:
                bits = f.read()
            for bx, bz in ((ccx * 16 + 8, ccz * 16 + 8), (ccx * 16 - 77, ccz * 16 + 131)):
                ok, msg = check_perimeter_gen(bits, cx0, cz0, w, seed, bx, bz, band)
                say("    perimeter_gen at (%d,%d): %s  -> %s" % (bx, bz, msg, "OK" if ok else "FAIL"),
                    None if ok else "red")
                fails += not ok
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jar", action="append", help="Minecraft client jar (repeatable); default: auto-find")
    ap.add_argument("--cases", type=int, default=20_000_000)
    o = ap.parse_args()
    require_tools("slime_gpu", "perimeter_setup", "afk_rescan")
    jars = o.jar or find_jars()
    if not jars:
        sys.exit("no Minecraft client jar found - pass --jar path/to/client.jar")
    global JAVA
    JAVA = java_bin()
    say("java: " + JAVA, "darkgray")
    build()
    results = {}
    for j in jars:
        results[version_of(j)] = test_jar(j, o.cases)
    say("\n=== SUMMARY ===", "cyan")
    tested = {k: v for k, v in results.items() if v is not None}
    for k, v in results.items():
        say("  %-12s %s" % (k, "skipped (no slime check found)" if v is None else
                            ("PASS - 1:1 with the game" if v == 0 else "FAIL (%d checks)" % v)),
            "darkgray" if v is None else ("green" if v == 0 else "red"))
    if not tested:
        sys.exit("nothing tested")
    return 1 if any(tested.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
