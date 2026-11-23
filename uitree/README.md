# uitree

A uitree host split in two: a **core** in Zig that owns everything a
headless run needs, and **renderers** that only draw and turn input into
events. The protocol it serves is [protocols/](protocols/) (draft 0.2).
Apps run sandboxed in [hyper9](https://github.com/progrium/hyper9)'s h9.

This replaces [uitreefs](../uitreefs), which is one Rust program. The
reasons and the estimate are in the scoping doc,
[Zig core + Rust renderer](https://claude.ai/artifact/9VdAkMLrAEzaWoWf56za5i).
How the work is split is in [ARCHITECTURE.md](ARCHITECTURE.md).

```
protocols/        the spec, draft 0.2
core/             Zig: libuitcore.a, include/uitcore.h, uitree-headless
  types/          the component catalog as descriptor files
renderer/gpui/    Rust: the GPUI host, linked against libuitcore.a
renderer/tui/     Zig: a terminal host on libvaxis and Yoga
tests/conformance the 0.2 conformance suite, run against uitree-headless
third_party/      hyper9 (submodule)
```

## Building

```sh
git submodule update --init uitree/third_party/hyper9
cd uitree/core
zig build test          # Zig 0.16, no Rust needed
zig build               # zig-out/lib/libuitcore.a, zig-out/bin/uitree-headless
```

The GPUI renderer builds with `cargo build` in `renderer/gpui` once the
spike lands it; its `build.rs` runs `zig build` for the core.

Status: scaffold. Nothing past the tokenizer is implemented.
