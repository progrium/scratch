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
core/             Zig: libuitcore.a, include/uitcore.h, uitree-headless,
                  uitree-remote
  types/          the component catalog as descriptor files
renderer/gpui/    Rust: the GPUI host, linked against libuitcore.a
renderer/tui/     Zig: a terminal host on libvaxis and Yoga
renderer/toy-py/  Python: a toy renderer over the render layer's 9P tree
web/              both renderers and the core in the browser (wasm)
apps/topframe/    Topframe, a fullscreen web overlay, as a uitree app
tests/conformance the 0.2 conformance suite, run against uitree-headless
bench/latency/    counter-click latency across seven setups
tools/            zig-pin, ghostty-vt (libghostty-vt's build), linuxroot, gforth
third_party/      hyper9 (submodule)
```

## Building

```sh
git submodule update --init uitree/third_party/hyper9
tools/zig-pin                       # the Zig version (core/build.zig.zon), 0.16.0
cd uitree/core
zig build test                      # no Rust needed; the first build fetches
                                    # libghostty-vt (core/README.md), or -Dterminal=plain
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

Two more show the `terminal` node: `terminal` (rc starting Alpine's sh
in pty mode, where htop and Neovim run; flagged `linux` in the list, since
it needs `$LINUXROOT` at `#L`) and `go-repl` (a shell in Go in stream
mode). `renderer/tui/tools/shoot.sh terminal` and `repl` record them.

The hyper9 submodule is pinned at
[4253a11](https://github.com/progrium/hyper9/commit/4253a11dc9fe910a1c3da5b1966b9618d5222ca8),
on hyper9's `claude/project-thread-t4k14b` branch rather than its main:
that is [hyper9#303](https://github.com/progrium/hyper9/pull/303), the
pty pairs that the terminal node's pty mode needs, kept on Zig 0.16. It
moves back to hyper9's main once uitree moves to Zig 0.17.

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
- `.github/workflows/uitree-web.yml`: the browser build
  (`zig build web -Dterminal=ghostty` in `web/`) and its headless
  Chromium cases on both renderers ([web/README.md](web/README.md)).

Status: every workstream has landed on `main`, including the terminal
node's (T0 to T8). Conformance on
`uitree-headless`: 33 pass (the transfer layer: typed drags, file drops
as handles under `$ui/file/`, and the typed clipboard; tooltips; the
`terminal` node in stream mode, pty mode and its input). The terminal
node is integrated on all three renderers, with libghostty-vt as its
engine.
