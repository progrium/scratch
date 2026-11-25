# uitree

A uitree host split in two: a **core** in Zig that owns everything a
headless run needs, and **renderers** that only draw and turn input into
events. The protocol it serves is [protocols/](protocols/) (draft 0.2).
Apps run sandboxed in [hyper9](https://github.com/progrium/hyper9)'s h9.

This replaces [uitreefs](https://github.com/progrium/scratch/tree/562f8b757a3558900b14f21c515f878af0167ada/uitreefs), which was one Rust program and has
been removed from the repo (the link is its last version). The
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
tools/zig-pin                       # the Zig version (core/build.zig.zon), 0.16.0
cd uitree/core
zig build test                      # no Rust needed
zig build -Dh9=true                 # libuitcore.a, uitree-headless, apps in h9
cd ../tests/conformance && ./run    # needs $H9ROOT, a 9front root
cd ../../renderer/gpui
cargo test && cargo test -p host    # GPUI test platform, no display
cargo build --release -p uitree     # build.rs runs zig build for the core
tools/sign target/release/uitree    # macOS: h9.entitlements; elsewhere a no-op
tools/shoot-examples                # every example under Xvfb, screenshots
cd ../tui && zig build test         # the terminal renderer
tools/shoot-examples                # every example in xterm under Xvfb
```

The examples are uitreefs's, ported: 14 rc apps and clients in awk, C,
COBOL, Forth, Go, jq, Lua, JavaScript (Node), PostScript (Ghostscript),
Python, Ruby, Scheme, sed and sh, listed in
[tests/conformance/examples/list](tests/conformance/examples/list), which
`run-examples` and both renderers' `shoot-examples` read. The Plan 9 ones
run on a 9front root; the Linux ones (jq onward in the list) run with
`-d $LINUXROOT:#L`, an Alpine tree with the interpreters that
[tools/linuxroot](tools/linuxroot) (and [tools/gforth](tools/gforth) for
Forth) builds, and are skipped without it.

`H9ROOT` is a 9front root with `rc` in it: in `third_party/hyper9`,
`scripts/fetch.sh isoamd64`, then
`zig build isoroot -- .local/9front/9front-11952.amd64.iso .local/9front/root-amd64`.

## CI

- `.github/workflows/uitree-core.yml`: the Zig pin check
  (`tools/zig-pin check` fails if `renderer/tui` or hyper9 drift from
  `core/build.zig.zon`), `zig build test`, the conformance suite and the
  example clients on `uitree-headless` in h9 (Linux, no GPU), and the
  terminal renderer's tests.
- `.github/workflows/uitree-renderer.yml`: the GPUI renderer on Linux,
  macOS and Windows (`cargo build --release -p uitree` links h9 for each;
  host tests where the core serves 9P, which is not Windows yet), signed
  on macOS, then every example under Xvfb from the `uitree` binary with
  screenshots as an artifact.

Status: every workstream has landed on `uitree`. Conformance on
`uitree-headless`: 31 pass (the transfer layer: typed drags, file drops
as handles under `$ui/file/`, and the typed clipboard; tooltips; the
`terminal` node in stream mode).
