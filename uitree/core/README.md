# core

The uitree core in Zig: `libuitcore.a`, `include/uitcore.h` and
`uitree-headless`. [../README.md](../README.md) has the build commands and
[../ARCHITECTURE.md](../ARCHITECTURE.md) how the parts fit.

## The terminal engine

The `terminal` node keeps its VT state in the core, on
[libghostty-vt](https://github.com/ghostty-org/ghostty) 1.0.2, Ghostty's
terminal emulation as a C library. `-Dterminal` picks the engine:

| | What the core links | Needs |
| --- | --- | --- |
| `-Dterminal=ghostty` (the default, but on Windows) | libghostty-vt, inside `libuitcore.a` | a first build that downloads Ghostty's release and Zig 0.17, or `-Dghostty-vt=DIR` |
| `-Dterminal=plain` | a plain-text stand-in in `src/term/` | nothing more |

`build_options.terminal` tells the core's code which it has. With
`ghostty`, the module `ghostty_vt` is `<ghostty/vt.h>`.

### How libghostty-vt is built

libghostty-vt 1.0.2 needs Zig 0.17, and the core is on Zig 0.16 (the pin in
`tools/zig-pin`). So `core/build.zig` runs
[`../tools/ghostty-vt`](../tools/ghostty-vt), which:

1. downloads Zig 0.17.1 from ziglang.org, and Ghostty's source and
   dependency tarballs from `release.files.ghostty.org`, each checked
   against a sha256 pinned in the script;
2. builds the static library offline (`--system` on the dependency
   tarball), as Ghostty's `PACKAGING-LIBGHOSTTY.md` says: `ReleaseFast`
   for native targets at the target's baseline CPU, and `ReleaseSmall`
   for `wasm32-freestanding` when the core is built `ReleaseSmall`;
3. turns the archive into one relocatable object, `lib/ghostty-vt.o`
   (`ld.lld -r` on ELF, Apple's `ld -r` on macOS, the archive's only
   member on wasm), and takes out Zig's compiler_rt, since
   `libuitcore.a` bundles its own.

Everything goes in `uitree/.local` (or `$UITREE_CACHE`), so the build
runs once per target and mode; after that it is a copy. CI caches the
directory, keyed on the script. Set `ZIG17` to use a Zig 0.17 you
have.

Why one object: Zig puts an archive given to a static library in it as a
single member when it links with LLVM (Debug builds happen to flatten it),
and no linker reads an archive inside an archive. An object goes into
`libuitcore.a` like the core's own, so a renderer's link line doesn't
change: Cargo's, `uitree-tui`'s and the web build's all link
`libuitcore.a` as before. libghostty-vt's C++ (simdutf, Highway) calls
only libc, so no C++ library is needed either.

On wasm, the core is wasm32-wasi but libghostty-vt is built for
`wasm32-freestanding` (its wasi build is broken upstream); the object
links into the wasi module with no imports of its own. One wrinkle: Zig
0.17 passes an f80 to compiler_rt's `__extendxftf2` by pointer, and the
core's Zig 0.16 compiler_rt takes it by value, which wasm-ld won't link.
The script renames the object's call to `__vt_extxftf2`, and
`core/build.zig` defines that with 0.17's signature (a few bit moves).

Windows defaults to `plain`: Ghostty builds libghostty-vt for the gnu ABI,
and the GPUI renderer links the core into an MSVC binary.

Without network access to those hosts, point `GHOSTTY_VT_SRC` at an
unpacked source tree (a `vt-1.0.2` checkout works) and `GHOSTTY_VT_SYSTEM`
at its packages; `GHOSTTY_VT_FLAGS` adds flags to its build, such as
`-Dvt-features=-kitty_graphics` when wuffs can't be fetched.

### The smoke test

`zig build smoke` links `tests/vt-smoke.zig` against `libuitcore.a`, as a
renderer would, and calls libghostty-vt on a thread: it checks the screen
text, the styled cells, the cursor, and the up arrow encoded under DECCKM.
On wasm32-wasi it builds `zig-out/web/vt-smoke.wasm` instead, a reactor
like `uitcore.wasm` in which the test runs on one of the core's coroutines
(h9's `coro.c`) and yields to the event loop halfway.
`tests/vt-smoke.mjs` runs it in Node 24 and in headless Chromium:

```sh
zig build smoke                                            # native
zig build smoke -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
node tests/vt-smoke.mjs                                    # Node and Chromium
```

### Size and speed

Measured on x86_64 Linux (a 2.1 GHz Xeon VM) on Nov 25, 2026, with
libghostty-vt built without Kitty graphics, since wuffs couldn't be
fetched there. CI's builds include it and are slightly larger.

| | `-Dterminal=plain` | `-Dterminal=ghostty` | |
| --- | --- | --- | --- |
| `ghostty-vt.o`, x86_64 ReleaseFast | | 4.8 MB | |
| `libuitcore.a`, x86_64 ReleaseFast | 15.5 MB | 20.4 MB | +4.8 MB |
| `uitree-headless`, x86_64 ReleaseFast | 9.7 MB | 11.1 MB | +1.4 MB |
| `ghostty-vt.o`, wasm32 ReleaseSmall | | 1.19 MB | |
| `uitcore.wasm`, ReleaseSmall | 656 KB | 1545 KB | +889 KB |
| `uitcore.wasm`, gzip -9 | 243 KB | 536 KB | +293 KB |

`uitcore.wasm` exports every symbol (`rdynamic`), so it keeps all of
libghostty-vt's C API. A renderer's module keeps what the core calls, and
until the engine calls it (workstream T2), `uitree-tui.wasm` is the same
size with either engine.

Parse throughput in wasm (`vt_bench`: 16 MB of `ls --color`-style lines,
SGR colors and plain text, into one 80x24 terminal, after a 1 MB warm-up):

| | MB/s |
| --- | --- |
| Node 24.22 | 106 to 110 |
| Chromium 158 | 135 to 166 |

That is libghostty-vt's wasm build, which has no simdutf or Highway (its
SIMD parser is native only) but is compiled with wasm's `simd128`. It is
far more than a terminal node needs: a busy `cat` is a few MB/s, and the
node feeds at most one buffer per pump.
