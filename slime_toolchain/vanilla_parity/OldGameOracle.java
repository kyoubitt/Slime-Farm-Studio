// OldGameOracle.java - GameOracle for the versions before 1.18 (1.12, the betas), which have no static
// WorldgenRandom.seedSlimeChunk: there the slime check is an instance method on the chunk,
//
//     chunk.getRandomWithSeed(987234911L).nextInt(10) == 0      (Chunk.a(long) in the obfuscated jars)
//
// which reads the chunk's x and z and the world's seed through a chain of fields. vanilla_parity.py finds
// all of that in the jar's bytecode (the slime class's own call, the fields that method reads) and passes it
// in; this makes the objects without running any game code - an empty chunk, world and world info with only
// those fields set - and calls the GAME's method on them, so the formula is the jar's, not ours.
//
//   java OldGameOracle <client.jar> <libs dir> <owner> <method> <xField> <zField> <hops> cases <N> <out.bin>
//   java OldGameOracle <client.jar> <libs dir> <owner> <method> <xField> <zField> <hops> map <seed> <cx0> <cz0> <w> <h> <out.bin>
//
// hops: "class,field;class,field;..." from the chunk to the long seed field. Same output and case stream as
// GameOracle.
import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import java.util.zip.*;

public class OldGameOracle {
    static final long SALT = 987234911L;
    static sun.misc.Unsafe U;
    static Object chunk, seedHolder;
    static long xOff, zOff, seedOff;
    static Method seeder;
    static URLClassLoader cl;
    static String jar;

    static Class<?> concrete(Class<?> t) throws Exception {
        if (!Modifier.isAbstract(t.getModifiers()) && !t.isInterface()) return t;
        try (ZipFile z = new ZipFile(jar)) {                 // an abstract World: any concrete subclass in the jar
            for (Enumeration<? extends ZipEntry> e = z.entries(); e.hasMoreElements();) {
                String n = e.nextElement().getName();
                if (!n.endsWith(".class")) continue;
                try {
                    Class<?> c = Class.forName(n.replace('/', '.').replaceAll("\\.class$", ""), false, cl);
                    if (t.isAssignableFrom(c) && !Modifier.isAbstract(c.getModifiers()) && !c.isInterface()) return c;
                } catch (Throwable ignored) { }
            }
        }
        throw new IllegalStateException("no concrete " + t.getName());
    }

    static Field field(String cls, String name) throws Exception {
        for (Class<?> c = Class.forName(cls, false, cl); c != null; c = c.getSuperclass())
            for (Field f : c.getDeclaredFields()) if (f.getName().equals(name)) return f;
        throw new NoSuchFieldException(cls + "." + name);
    }

    static void setup(String[] a) throws Exception {
        jar = a[0];
        List<URL> urls = new ArrayList<>(List.of(new File(jar).toURI().toURL()));
        try (Stream<Path> s = Files.walk(Paths.get(a[1]))) {   // guava and friends, for the 1.12 classes' types
            for (Path p : s.filter(p -> p.toString().endsWith(".jar") && !p.toString().contains("com/mojang/minecraft/")).toList())
                urls.add(p.toUri().toURL());
        }
        cl = new URLClassLoader(urls.toArray(new URL[0]), OldGameOracle.class.getClassLoader());
        Field uf = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        uf.setAccessible(true);
        U = (sun.misc.Unsafe) uf.get(null);

        Class<?> owner = Class.forName(a[2], false, cl);
        chunk = U.allocateInstance(concrete(owner));
        for (Class<?> c = owner; c != null && seeder == null; c = c.getSuperclass())
            for (Method m : c.getDeclaredMethods())
                if (m.getName().equals(a[3]) && Arrays.equals(m.getParameterTypes(), new Class<?>[] { long.class })
                        && m.getReturnType() == Random.class) { seeder = m; m.setAccessible(true); }
        xOff = U.objectFieldOffset(field(a[2], a[4]));
        zOff = U.objectFieldOffset(field(a[2], a[5]));
        Object cur = chunk;                                    // chunk -> world -> world info -> the seed
        String[] hops = a[6].split(";");
        for (int i = 0; i < hops.length; i++) {
            String[] h = hops[i].split(",");
            Field f = field(h[0], h[1]);
            if (i == hops.length - 1) { seedHolder = cur; seedOff = U.objectFieldOffset(f); break; }
            Object next = U.allocateInstance(concrete(f.getType()));
            U.putObject(cur, U.objectFieldOffset(f), next);
            cur = next;
        }
        System.out.println("game method: " + seeder.getDeclaringClass().getName() + "." + seeder.getName()
            + "(long) on an empty " + chunk.getClass().getName() + ", seed at " + a[6]);
    }

    static boolean game(long seed, int x, int z) throws Exception {
        U.putInt(chunk, xOff, x);
        U.putInt(chunk, zOff, z);
        U.putLong(seedHolder, seedOff, seed);
        return ((Random) seeder.invoke(chunk, SALT)).nextInt(10) == 0;
    }

    public static void main(String[] a) throws Exception {
        setup(a);
        String[] r = Arrays.copyOfRange(a, 7, a.length);
        long t0 = System.nanoTime();
        if (r[0].equals("cases")) {
            long n = Long.parseLong(r[1]);
            GameOracle.sm = 0x5EEDL;
            GameOracle.writeBits(r[2], n, i -> { GameOracle.genCase(i); return game(GameOracle.cSeed, GameOracle.cX, GameOracle.cZ); });
            System.out.printf("asked the game about %,d chunks in %.1fs%n", n, (System.nanoTime() - t0) / 1e9);
        } else if (r[0].equals("map")) {
            long seed = Long.parseLong(r[1]);
            int cx0 = Integer.parseInt(r[2]), cz0 = Integer.parseInt(r[3]);
            int w = Integer.parseInt(r[4]), h = Integer.parseInt(r[5]);
            GameOracle.writeBits(r[6], (long) w * h, i -> game(seed, cx0 + (int) (i % w), cz0 + (int) (i / w)));
            System.out.printf("game map %dx%d chunks in %.1fs%n", w, h, (System.nanoTime() - t0) / 1e9);
        } else {
            throw new IllegalArgumentException("mode must be cases or map");
        }
    }
}
