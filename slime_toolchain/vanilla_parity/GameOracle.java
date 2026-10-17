// GameOracle.java - asks a REAL Minecraft jar which chunks are slime chunks.
//
// Nothing here re-implements the formula. It loads the game's own class and
// calls the game's own method - the one Slime's spawn rule calls:
//
//     WorldgenRandom.seedSlimeChunk(chunkX, chunkZ, worldSeed, 987234911L).nextInt(10) == 0
//
// Obfuscated jars (1.21.11 and older) are handled without mappings: the class
// is found by the 4987142 constant only that method uses, the method by its
// (int,int,long,long) shape, and nextInt(int) by behaviour (the one (I)I method
// whose answers for 10 always land in 0..9). What was picked is printed so it
// can be checked against `javap -c` of the Slime class.
//
//   java GameOracle <client.jar> cases <N> <out.bin>
//   java GameOracle <client.jar> map <seed> <cx0> <cz0> <w> <h> <out.bin>
//
// Output is one bit per chunk (LSB-first within each byte). The case stream is
// a SplitMix64 sequence reproduced bit-for-bit by parity.cu - see genCase().
import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.util.*;
import java.util.zip.*;

public class GameOracle {
    static final long SALT = 987234911L;
    static Method seedFn, nextInt;

    // ---- the same case generator as parity.cu --------------------------------
    static long sm;
    static long next() {
        long z = (sm += 0x9E3779B97F4A7C15L);
        z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
        z = (z ^ (z >>> 27)) * 0x94D049BB133111EBL;
        return z ^ (z >>> 31);
    }
    static final long[] SPECIAL = { 0L, -1L, Long.MIN_VALUE, Long.MAX_VALUE,
        9029506488461633794L, -89761025938370956L, -3918692359804081918L,
        1L << 48, (1L << 48) - 1, 1L << 47 };
    static long cSeed; static int cX, cZ;
    static void genCase(long i) {
        int k = (int) (i & 3);
        cSeed = next();
        if (k == 3) cSeed = SPECIAL[(int) Long.remainderUnsigned(next(), SPECIAL.length)];
        if (k == 0) {            // near spawn
            cX = (int) Long.remainderUnsigned(next(), 4001) - 2000;
            cZ = (int) Long.remainderUnsigned(next(), 4001) - 2000;
        } else if (k == 2) {     // any int at all - every overflow path in the formula
            cX = (int) next();
            cZ = (int) next();
        } else {                 // anywhere inside the world border
            cX = (int) Long.remainderUnsigned(next(), 3750001) - 1875000;
            cZ = (int) Long.remainderUnsigned(next(), 3750001) - 1875000;
        }
    }

    static boolean game(long seed, int x, int z) throws Exception {
        Object rnd = seedFn.invoke(null, x, z, seed, SALT);
        return ((Integer) nextInt.invoke(rnd, 10)) == 0;
    }

    // ---- locate the game's method in an obfuscated or named jar ----------------
    static boolean hasIntConst(byte[] b, int v) {
        byte[] n = { 3, (byte) (v >> 24), (byte) (v >> 16), (byte) (v >> 8), (byte) v };
        outer:
        for (int i = 0; i + n.length <= b.length; i++) {
            for (int j = 0; j < n.length; j++) if (b[i + j] != n[j]) continue outer;
            return true;
        }
        return false;
    }

    static void resolve(String jar) throws Exception {
        URLClassLoader cl = new URLClassLoader(new URL[] { new File(jar).toURI().toURL() },
                                               GameOracle.class.getClassLoader());
        List<String> owners = new ArrayList<>();
        try (ZipFile z = new ZipFile(jar)) {
            for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements();) {
                ZipEntry en = e.nextElement();
                if (!en.getName().endsWith(".class")) continue;
                if (hasIntConst(z.getInputStream(en).readAllBytes(), 4987142))
                    owners.add(en.getName().replace('/', '.').replaceAll("\\.class$", ""));
            }
        }
        for (String o : owners) {
            Class<?> c = Class.forName(o, false, cl);
            for (Method m : c.getDeclaredMethods()) {
                Class<?>[] p = m.getParameterTypes();
                if (Modifier.isStatic(m.getModifiers()) && p.length == 4 && p[0] == int.class
                        && p[1] == int.class && p[2] == long.class && p[3] == long.class
                        && !m.getReturnType().isPrimitive()) {
                    m.setAccessible(true);
                    seedFn = m;
                }
            }
        }
        if (seedFn == null)
            throw new IllegalStateException("no static (int,int,long,long) slime-chunk seeder in "
                + owners + " - this version predates WorldgenRandom.seedSlimeChunk (1.18+)");

        // nextInt(int): the (I)I method on the returned RNG whose answers for 10
        // stay in 0..9 for every seed tried (next(bits) etc. would not).
        Class<?> rt = seedFn.getReturnType();
        for (Method m : rt.getMethods()) {
            if (m.getReturnType() != int.class || m.getParameterCount() != 1
                    || m.getParameterTypes()[0] != int.class) continue;
            boolean ok = true; Set<Integer> seen = new HashSet<>();
            for (int s = 0; s < 500 && ok; s++) {
                Object r = seedFn.invoke(null, s, -s, s * 7919L, SALT);
                int v = (Integer) m.invoke(r, 10);
                ok = v >= 0 && v < 10; seen.add(v);
            }
            if (ok && seen.size() == 10) {
                if (nextInt != null) throw new IllegalStateException("two nextInt candidates: " + nextInt + ", " + m);
                nextInt = m;
            }
        }
        if (nextInt == null) throw new IllegalStateException("no nextInt(int) on " + rt);
        System.out.println("game method: " + seedFn.getDeclaringClass().getName() + "." + seedFn.getName()
            + "(int,int,long,long) -> " + rt.getName() + "." + nextInt.getName() + "(int)");
    }

    // ---- bit output --------------------------------------------------------------
    static void writeBits(String path, long n, BitSource src) throws Exception {
        byte[] buf = new byte[(int) ((n + 7) / 8)];
        for (long i = 0; i < n; i++) if (src.get(i)) buf[(int) (i >> 3)] |= (byte) (1 << (i & 7));
        try (FileOutputStream f = new FileOutputStream(path)) { f.write(buf); }
    }
    interface BitSource { boolean get(long i) throws Exception; }

    public static void main(String[] a) throws Exception {
        resolve(a[0]);
        long t0 = System.nanoTime();
        if (a[1].equals("cases")) {
            long n = Long.parseLong(a[2]);
            sm = 0x5EEDL;
            writeBits(a[3], n, i -> { genCase(i); return game(cSeed, cX, cZ); });
            System.out.printf("asked the game about %,d chunks in %.1fs%n", n, (System.nanoTime() - t0) / 1e9);
        } else if (a[1].equals("map")) {
            long seed = Long.parseLong(a[2]);
            int cx0 = Integer.parseInt(a[3]), cz0 = Integer.parseInt(a[4]);
            int w = Integer.parseInt(a[5]), h = Integer.parseInt(a[6]);
            writeBits(a[7], (long) w * h, i -> game(seed, cx0 + (int) (i % w), cz0 + (int) (i / w)));
            System.out.printf("game map %dx%d chunks in %.1fs%n", w, h, (System.nanoTime() - t0) / 1e9);
        } else {
            throw new IllegalArgumentException("mode must be cases or map");
        }
    }
}
