#!/usr/bin/env python3
"""vanilla_world_test.py - run the perimeter commands in a REAL vanilla server
and check the world they actually build, block by block.

vanilla_parity.py proves the slime MATH matches the game. This proves the
COMMANDS do what they claim in the game itself, per version:

  * a headless vanilla dedicated server (official jar from Mojang, sha1-checked,
    cached in ~/.cache/slime_toolchain/servers) on a superflat world with the seed
  * perimeter_gen's floor and border one-command monoliths run exactly as a
    player would: pasted into a command block and powered from the side
  * the save files are then read back (Anvil region parser below) and the
    floor layer compared, block by block, with what THAT server's own
    seedSlimeChunk says it must be: obsidian on every slime chunk, magma on
    every border block, air everywhere else
  * the contraptions must clean up after themselves (no rail, no redstone
    block, no command block minecarts left over)
  * the chat commands (gamerule, tp, give) must parse on that version -
    including perimeter_setup's, so a renamed gamerule shows up here

WorldEdit and Carpet sections are not vanilla and are not run; the test clears
the floor layer with vanilla /fill instead of //replace air.

    ./vanilla_world_test.py                       one version per perimeter_gen band
    ./vanilla_world_test.py --version 1.21.11 [--version 26.1.2 ...]

The test servers are throwaway folders under main/work/world_test/ and need
eula=true to start - this sets it there, nowhere else (Minecraft EULA:
https://aka.ms/MinecraftEULA).
"""
import argparse
import glob
import hashlib
import json
import os
import queue
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request
import zipfile
import zlib

from slime_common import ROOT, perimeter_band, run_perimeter_gen, say, tool
import vanilla_parity as vp

CACHE = os.path.expanduser("~/.cache/slime_toolchain/servers")
WORK = os.path.join(ROOT, "main", "work", "world_test")
MANIFEST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
# one per perimeter_gen version band, plus the newest release
DEFAULT_VERSIONS = ["1.16.5", "1.20.4", "1.20.6", "1.21.11", "26.1.2"]
SEED = 9029506488461633794          # the 66.04 record seed
CENTER = (-3603, 7107)              # mixed signs and off the chunk grid on purpose
CENTER_B = (4211, -2877)            # perimeter_setup's farm: the other two signs, also off-grid


# ---- server jars ------------------------------------------------------------------
def fetch_json(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def server_jar(version):
    """(server.jar path, required java major) - downloaded once, sha1-verified."""
    d = os.path.join(CACHE, version)
    meta_path = os.path.join(d, "version.json")
    if not os.path.exists(meta_path):
        man = fetch_json(MANIFEST)
        entry = next((v for v in man["versions"] if v["id"] == version), None)
        if not entry:
            raise RuntimeError("no such Minecraft version in Mojang's manifest: " + version)
        os.makedirs(d, exist_ok=True)
        meta = fetch_json(entry["url"])
        with open(meta_path, "w") as f:
            json.dump(meta, f)
    with open(meta_path) as f:
        meta = json.load(f)
    dl = meta["downloads"]["server"]
    jar = os.path.join(d, "server.jar")
    if not os.path.exists(jar) or sha1(jar) != dl["sha1"]:
        say("  downloading %s server.jar (%.0f MB) from Mojang..." % (version, dl["size"] / 1e6), "darkgray")
        tmp = jar + ".part"
        urllib.request.urlretrieve(dl["url"], tmp)
        if sha1(tmp) != dl["sha1"]:
            os.remove(tmp)
            raise RuntimeError("sha1 mismatch on the downloaded server jar")
        os.replace(tmp, jar)
    return jar, meta.get("javaVersion", {}).get("majorVersion", 8)


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def game_classes_jar(jar, version):
    """1.18+ server jars are a bundler; the game classes are an inner jar."""
    with zipfile.ZipFile(jar) as z:
        inner = [n for n in z.namelist() if n.startswith("META-INF/versions/") and n.endswith(".jar")]
        if not inner:
            return jar
        out = os.path.join(CACHE, version, "game.jar")
        if not os.path.exists(out):
            with z.open(inner[0]) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
        return out


def java_for(major):
    """Exact major if installed, else the closest newer one."""
    found = {}
    for d in glob.glob("/usr/lib/jvm/*/bin/java"):
        m = re.search(r"java-(\d+)", d)
        if m:
            found[int(m.group(1))] = d
    if major in found:
        return found[major]
    newer = sorted(k for k in found if k > major)
    if newer:
        return found[newer[0]]
    raise RuntimeError("needs Java %d+ (sudo pacman -S jdk%d-openjdk)" % (major, major))


# ---- the server --------------------------------------------------------------------
class Server:
    ERR = re.compile(r"Unknown or incomplete command|Incorrect argument|Unknown game ?rule|<--\[HERE\]|"
                     r"Expected |Invalid |Unknown block|Unknown entity|Could not set the block|"
                     r"That position is not loaded|Cannot place blocks|Too many blocks")

    def __init__(self, folder, jar, java, version):
        self.lines = queue.Queue()
        self.log = []
        self.proc = subprocess.Popen([java, "-Xmx2G", "-jar", jar, "nogui"], cwd=folder,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, bufsize=1, errors="replace")
        threading.Thread(target=self._read, daemon=True).start()
        self._n = 0
        if not self.wait_for(r"Done \(", 300):
            raise RuntimeError("server did not start:\n" + "\n".join(self.log[-15:]))

    def _read(self):
        for l in self.proc.stdout:
            l = l.rstrip("\n")
            self.log.append(l)
            self.lines.put(l)

    def wait_for(self, pattern, timeout):
        end = time.time() + timeout
        while time.time() < end:
            try:
                l = self.lines.get(timeout=0.5)
            except queue.Empty:
                if self.proc.poll() is not None:
                    return None
                continue
            if re.search(pattern, l):
                return l
        return None

    def cmd(self, command, settle=0.0):
        """Run a console command; return the log lines it produced."""
        self._n += 1
        mark = "ZZMARK%d" % self._n
        self.proc.stdin.write(command.lstrip("/") + "\n")
        if settle:
            self.proc.stdin.flush()
            time.sleep(settle)
        self.proc.stdin.write("say %s\n" % mark)
        self.proc.stdin.flush()
        out = []
        end = time.time() + 120
        while time.time() < end:
            try:
                l = self.lines.get(timeout=1)
            except queue.Empty:
                continue
            if mark in l:
                return out
            out.append(re.sub(r"^\[[^\]]*\] \[[^\]]*\]: ", "", l))
        raise RuntimeError("no response to: " + command[:120])

    def stop(self):
        try:
            self.proc.stdin.write("stop\n")
            self.proc.stdin.flush()
            self.proc.wait(120)
        except Exception:
            self.proc.kill()
            self.proc.wait()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def vtuple(v):
    return tuple(int(p) for p in v.split("."))


# ---- Anvil region reader (just enough for one layer of blocks) -----------------------
def nbt(buf, i=0):
    """Parse one named root tag -> (value, next index)."""
    tag = buf[i]; i += 1
    if tag == 0:
        return None, i
    n = struct.unpack_from(">H", buf, i)[0]; i += 2 + n
    return nbt_payload(buf, i, tag)


def nbt_payload(b, i, t):
    if t == 1: return b[i] if b[i] < 128 else b[i] - 256, i + 1
    if t == 2: return struct.unpack_from(">h", b, i)[0], i + 2
    if t == 3: return struct.unpack_from(">i", b, i)[0], i + 4
    if t == 4: return struct.unpack_from(">q", b, i)[0], i + 8
    if t == 5: return struct.unpack_from(">f", b, i)[0], i + 4
    if t == 6: return struct.unpack_from(">d", b, i)[0], i + 8
    if t == 7:
        n = struct.unpack_from(">i", b, i)[0]; return b[i + 4:i + 4 + n], i + 4 + n
    if t == 8:
        n = struct.unpack_from(">H", b, i)[0]; return b[i + 2:i + 2 + n].decode("utf-8", "replace"), i + 2 + n
    if t == 9:
        et = b[i]; n = struct.unpack_from(">i", b, i + 1)[0]; i += 5
        out = []
        for _ in range(n):
            v, i = nbt_payload(b, i, et); out.append(v)
        return out, i
    if t == 10:
        d = {}
        while True:
            et = b[i]; i += 1
            if et == 0:
                return d, i
            n = struct.unpack_from(">H", b, i)[0]; name = b[i + 2:i + 2 + n].decode("utf-8", "replace"); i += 2 + n
            d[name], i = nbt_payload(b, i, et)
    if t == 11:
        n = struct.unpack_from(">i", b, i)[0]; return list(struct.unpack_from(">%di" % n, b, i + 4)), i + 4 + 4 * n
    if t == 12:
        n = struct.unpack_from(">i", b, i)[0]; return list(struct.unpack_from(">%dq" % n, b, i + 4)), i + 4 + 8 * n
    raise ValueError("bad NBT tag %d" % t)


class World:
    def __init__(self, folder):
        # 26.1+ keeps the overworld under world/dimensions/minecraft/overworld/; older versions in world/region
        self.region = os.path.join(folder, "world", "region")
        newer = os.path.join(folder, "world", "dimensions", "minecraft", "overworld", "region")
        if os.path.isdir(newer):
            self.region = newer
        self.cache = {}

    def chunk(self, cx, cz):
        key = (cx, cz)
        if key in self.cache:
            return self.cache[key]
        path = os.path.join(self.region, "r.%d.%d.mca" % (cx >> 5, cz >> 5))
        data = None
        if os.path.exists(path):
            with open(path, "rb") as f:
                hdr = f.read(4096)
                loc = struct.unpack_from(">I", hdr, 4 * ((cx & 31) + (cz & 31) * 32))[0]
                off, cnt = loc >> 8, loc & 0xFF
                if off:
                    f.seek(off * 4096)
                    n, comp = struct.unpack(">IB", f.read(5))
                    raw = f.read(n - 1)
                    raw = zlib.decompress(raw) if comp == 2 else (zlib.decompress(raw, 16 + 15) if comp == 1 else raw)
                    data = nbt(raw)[0]
        self.cache[key] = data
        return data

    def block(self, x, y, z):
        c = self.chunk(x >> 4, z >> 4)
        if c is None:
            return "<not generated>"
        lvl = c.get("Level", c)                       # pre-1.18 wraps everything in Level
        for s in lvl.get("sections", lvl.get("Sections", [])):
            if s.get("Y") != (y >> 4):
                continue
            if "block_states" in s:                   # 1.18+
                pal, data = s["block_states"]["palette"], s["block_states"].get("data")
            else:                                     # 1.16 / 1.17
                pal, data = s.get("Palette"), s.get("BlockStates")
                if pal is None:
                    return "minecraft:air"
            if len(pal) == 1 or not data:
                return pal[0]["Name"]
            bits = max(4, (len(pal) - 1).bit_length())
            idx = ((y & 15) << 8) | ((z & 15) << 4) | (x & 15)
            per = 64 // bits
            word = data[idx // per] & 0xFFFFFFFFFFFFFFFF
            return pal[(word >> ((idx % per) * bits)) & ((1 << bits) - 1)]["Name"]
        return "minecraft:air"


# ---- one version ---------------------------------------------------------------------
def region_of(gx, gz, margin=2):
    R = vp.PERIMETER_RADIUS
    return (vp.floor16(gx - R) - margin, vp.floor16(gx + R) + margin,
            vp.floor16(gz - R) - margin, vp.floor16(gz + R) + margin)


def snbt_single(text):
    """A command as a single-quoted SNBT string (the monoliths carry double quotes and \\\")."""
    return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"


def test_version(version):
    say("\n=== vanilla %s server ===" % version, "cyan")
    band = perimeter_band(version)
    jar, jmajor = server_jar(version)
    java = java_for(jmajor)
    say("  java %d: %s" % (jmajor, java), "darkgray")
    fails = []
    floor_y = 0 if band == 0 else -64
    vp.JAVA = vp.java_bin()          # oracle: newest java (old game classes load fine on it)
    vp.build()
    game_jar = game_classes_jar(jar, version)

    # two farms in one world: A = perimeter_gen (floor + magma border), B = perimeter_setup (floor)
    farms = {"A": CENTER, "B": CENTER_B}
    maps = {}
    for key, (gx, gz) in farms.items():
        cx_min, cx_max, cz_min, cz_max = region_of(gx, gz)
        w, h = cx_max - cx_min + 1, cz_max - cz_min + 1
        mf = os.path.join(vp.BUILD, "world_%s_%s.bin" % (version, key))
        out, err = vp.oracle(game_jar, "map", SEED, cx_min, cz_min, w, h, mf)
        if out is None:
            raise RuntimeError("oracle on the server jar failed: " + err)
        with open(mf, "rb") as f:
            bits = f.read()
        maps[key] = (lambda b, x0, z0, ww: lambda cx, cz: (b[((cz - z0) * ww + (cx - x0)) >> 3] >> (((cz - z0) * ww + (cx - x0)) & 7)) & 1)(bits, cx_min, cz_min, w)
    say("  " + out[0], "darkgray")

    path, _ = run_perimeter_gen(SEED, CENTER[0], CENTER[1], band, os.path.join(WORK, "perimeters"))
    secs = vp.parse_perimeter(path)
    gen_mono = lambda k: next(l for l in secs[k].splitlines() if l.startswith("summon"))
    ps_out = subprocess.run([tool("perimeter_setup"), "--seed", str(SEED), "--center-x", str(CENTER_B[0]),
                             "--center-z", str(CENTER_B[1]), "--game-version", version],
                            capture_output=True, text=True).stdout
    ps_secs = {}
    cur = None
    for line in ps_out.splitlines():
        m = re.match(r"--- (\d+)\. ", line)
        if m:
            cur = int(m.group(1)); ps_secs[cur] = []
        elif cur is not None:
            ps_secs[cur].append(line)

    folder = os.path.join(WORK, version)
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    with open(os.path.join(folder, "eula.txt"), "w") as f:
        f.write("eula=true\n")
    flat = "minecraft:flat" if vtuple(version) >= (1, 19) else "flat"
    props = {"level-seed": str(SEED), "level-type": flat, "enable-command-block": "true",
             "online-mode": "false", "server-port": str(free_port()), "spawn-protection": "0",
             "view-distance": "4", "simulation-distance": "4", "max-tick-time": "-1",
             "generate-structures": "false", "sync-chunk-writes": "true", "difficulty": "peaceful"}
    with open(os.path.join(folder, "server.properties"), "w") as f:
        f.write("".join("%s=%s\n" % kv for kv in props.items()))

    t0 = time.time()
    srv = Server(folder, jar, java, version)
    say("  server up in %.0fs" % (time.time() - t0), "darkgray")
    try:
        def expect_ok(label, lines, must=None):
            bad = [l for l in lines if Server.ERR.search(l)]
            if bad or (must and not any(re.search(must, l) for l in lines)):
                fails.append("%s: %s" % (label, (bad or lines or ["no output"])[0][:160]))
                say("  %-52s FAIL  %s" % (label, (bad or lines or ["no output"])[0][:100]), "red")
            else:
                say("  %-52s ok    %s" % (label, (lines or [""])[0][:64]))

        expect_ok("/seed is the requested seed", srv.cmd("seed"), r"\[%d\]" % SEED)
        for who, lines in (("perimeter_gen", secs[1].splitlines() + secs[6].splitlines()),
                           ("perimeter_setup", ps_secs.get(1, []) + ps_secs.get(4, []))):
            for line in lines:
                if line.startswith("/gamerule"):
                    expect_ok("%s %s" % (who, line), srv.cmd(line), r"(?i)now set to|set to: false")
                elif line.startswith("/tp"):
                    expect_ok("%s /tp parses (no player online)" % who, srv.cmd(line), r"No (player|entity) was found")
                elif line.startswith("/give"):
                    expect_ok("%s /give parses (no player online)" % who, srv.cmd(line), r"No player was found")

        # load and clear both floor layers (stands in for the WorldEdit void step)
        for key, (gx, gz) in farms.items():
            cx_min, cx_max, cz_min, cz_max = region_of(gx, gz)
            for cz in range(cz_min, cz_max + 1):
                srv.cmd("forceload add %d %d %d %d" % (cx_min * 16, cz * 16, cx_max * 16, cz * 16))
        time.sleep(4)
        for attempt in range(3):
            notloaded = False
            for key, (gx, gz) in farms.items():
                cx_min, cx_max, cz_min, cz_max = region_of(gx, gz)
                X0, X1, Z0, Z1 = cx_min * 16, cx_max * 16 + 15, cz_min * 16, cz_max * 16 + 15
                for x in range(X0, X1 + 1, 128):
                    for z in range(Z0, Z1 + 1, 128):
                        r = srv.cmd("fill %d %d %d %d %d %d air" % (x, floor_y, z, min(x + 127, X1), floor_y, min(z + 127, Z1)))
                        notloaded |= any("not loaded" in l for l in r)
            if not notloaded:
                break
            time.sleep(5)

        # the monoliths, exactly as a player runs them: pasted into ONE command
        # block, powered from the side. Then the cleanup must have left nothing.
        def run_monolith(label, cb, mono):
            srv.cmd("setblock %d %d %d air" % cb)
            expect_ok(label + " fits a command block",
                      srv.cmd("setblock %d %d %d command_block{Command:%s}" % (cb + (snbt_single(mono),))),
                      r"(?i)changed the block")
            srv.cmd("setblock %d %d %d redstone_block" % (cb[0] + 1, cb[1], cb[2]), settle=6)
            srv.cmd("setblock %d %d %d air" % (cb[0] + 1, cb[1], cb[2]))
            expect_ok(label + ": no minecarts left",
                      srv.cmd("execute if entity @e[type=command_block_minecart]"), r"Test failed")
            for etype in ("item", "armor_stand"):
                expect_ok(label + ": no %s entities left" % etype,
                          srv.cmd("execute if entity @e[type=%s]" % etype), r"Test failed")
            expect_ok(label + ": your command block kept",
                      srv.cmd("execute if block %d %d %d command_block" % cb), r"Test passed")
            for dy, what in ((1, "redstone block"), (2, "rail"), (3, "cleanup block")):
                expect_ok(label + ": %s gone (cb+%d is air)" % (what, dy),
                          srv.cmd("execute if block %d %d %d air" % (cb[0], cb[1] + dy, cb[2])), r"Test passed")

        cbA = (CENTER[0], floor_y + 40, CENTER[1])
        run_monolith("perimeter_gen section 3 (floor)", cbA, gen_mono(3))
        run_monolith("perimeter_gen section 4 (border)", cbA, gen_mono(4))
        cbB = (CENTER_B[0], floor_y + 40, CENTER_B[1])
        run_monolith("perimeter_setup section 3 (floor)", cbB,
                     next(l for l in ps_secs[3] if l.startswith("summon")))
        srv.cmd("save-all flush", settle=2)
    finally:
        srv.stop()

    # read both floor layers back out of the save and compare, block by block
    world = World(folder)
    for key, (gx, gz) in farms.items():
        slime_at = maps[key]
        if key == "A":
            want_chunks, want_border = vp.expected_perimeter(slime_at, gx, gz)
            who = "perimeter_gen"
        else:
            R = vp.PERIMETER_RADIUS
            want_chunks = {(cx, cz) for cx in range(vp.floor16(gx - R), vp.floor16(gx + R) + 1)
                           for cz in range(vp.floor16(gz - R), vp.floor16(gz + R) + 1) if slime_at(cx, cz)}
            want_border = set()
            who = "perimeter_setup"
        cx_min, cx_max, cz_min, cz_max = region_of(gx, gz)
        counts, wrong = {}, []
        for X in range(cx_min * 16, cx_max * 16 + 16):
            for Z in range(cz_min * 16, cz_max * 16 + 16):
                b = world.block(X, floor_y, Z)
                counts[b] = counts.get(b, 0) + 1
                if (vp.floor16(X), vp.floor16(Z)) in want_chunks:
                    want = "minecraft:obsidian"
                elif (X, Z) in want_border:
                    want = "minecraft:magma_block"
                else:
                    want = "minecraft:air"
                if b != want:
                    wrong.append((X, Z, b, want))
        summary = ", ".join("%s %d" % (k.replace("minecraft:", ""), v) for k, v in sorted(counts.items(), key=lambda kv: -kv[1]))
        ok = not wrong
        say("  %s world floor y=%d (%d blocks read from the save): %s" % (who, floor_y, sum(counts.values()), summary))
        say("  %s vs this server's own slime chunks: %d obsidian chunks + %d magma blocks expected, %d blocks wrong  -> %s"
            % (who, len(want_chunks), len(want_border), len(wrong), "OK" if ok else "FAIL"), None if ok else "red")
        for X, Z, b, want in wrong[:6]:
            say("    (%d,%d,%d): world has %s, should be %s" % (X, floor_y, Z, b, want), "red")
        if wrong:
            fails.append("%s: %d floor-layer blocks wrong" % (who, len(wrong)))
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="append", help="Minecraft release to test (repeatable)")
    ap.add_argument("--keep", action="store_true", help="keep the test worlds under main/work/world_test/")
    o = ap.parse_args()
    versions = o.version or DEFAULT_VERSIONS
    results = {}
    for v in versions:
        if perimeter_band(v) is None:
            say("\n%s: perimeter_gen supports 1.13+, skipped" % v, "yellow")
            continue
        try:
            results[v] = test_version(v)
        except Exception as e:
            results[v] = ["error: %s" % e]
            say("  ERROR: %s" % e, "red")
        if not o.keep:
            shutil.rmtree(os.path.join(WORK, v), ignore_errors=True)
    say("\n=== SUMMARY ===", "cyan")
    for v, f in results.items():
        say("  %-8s %s" % (v, "PASS - built 1:1 with the game" if not f else "FAIL: " + "; ".join(f)[:200]),
            "green" if not f else "red")
    return 1 if any(results.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
