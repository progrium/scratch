# renderer/gpui

The GPUI host, in Rust. The only Rust in uitree (plus `tools/style-gen`,
a build tool).

It draws the committed tree and turns input into events. It reads the tree
in place through `uitcore.h` and never decides whether a write is valid:
a renderer change that adds a protocol error string is wrong.

Layout (the spike, W0, created it; W6 fills it). Status: see
[../../SPIKE.md](../../SPIKE.md).

```
Cargo.toml             workspace
crates/uitcore-sys/    hand-written bindings to ../../core/include/uitcore.h;
                       build.rs runs `zig build -Doptimize=ReleaseSafe` for
                       Cargo's target and links libuitcore.a
crates/uitcore/        the safe wrapper: borrowed reads, UitChanges, input
crates/host/           components, materialize, style dispatch (from uitreefs/crates/host)
crates/uitree/         ~50-line main: create the core, hand control to GPUI
tools/style-gen/       from uitreefs/crates/style/gen; emits the dispatch table
                       here and core/types/style-words, theme-tokens (W1)
```

Build and run (Linux needs `libxkbcommon-dev libxkbcommon-x11-dev`):

```
cargo test                                   # uitcore-sys, uitcore: no display needed
cargo build --release -p uitree
cd examples && H9ROOT=/path/to/9front/root ../target/release/uitree -t Counter rc counter.rc
../target/release/uitree --bench 2000        # FFI cost per frame
```
