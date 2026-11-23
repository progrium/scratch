# renderer/gpui

The GPUI host, in Rust. The only Rust in uitree (plus `tools/style-gen`,
a build tool).

It draws the committed tree and turns input into events. It reads the tree
in place through `uitcore.h` and never decides whether a write is valid:
a renderer change that adds a protocol error string is wrong.

Planned layout (the spike, W0, creates it; W6 fills it):

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
