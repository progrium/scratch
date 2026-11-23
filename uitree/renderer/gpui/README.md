# renderer/gpui

The GPUI host, in Rust. The only Rust in uitree (plus `tools/style-gen`,
a build tool).

It draws the committed tree and turns input into events. It reads the tree
in place through `uitcore.h` and never decides whether a write is valid:
a renderer change that adds a protocol error string is wrong.

Layout (the spike, W0, created it; W6 fills it). Status: below, and
[../../SPIKE.md](../../SPIKE.md) for the spike.

```
Cargo.toml             workspace
crates/uitcore-sys/    hand-written bindings to ../../core/include/uitcore.h;
                       build.rs runs `zig build -Doptimize=ReleaseSafe` for
                       Cargo's target and links libuitcore.a
crates/uitcore/        the safe wrapper: borrowed reads, UitChanges, input
crates/host/           components, materialize, style dispatch (from uitreefs/crates/host);
                       build.rs embeds core/types/*/spec, style-words, theme-tokens
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

`H9ROOT` is a 9front root with `rc` in it: in `third_party/hyper9`,
`scripts/fetch.sh isoamd64` then
`zig build isoroot -- .local/9front/9front-11952.amd64.iso .local/9front/root-amd64`.
With no KVM, h9 uses its native backend.

## How the host reads the tree

Every component reads its node through `NodeView` (`crates/host/src/lib.rs`),
which reads the core through `uitcore`: props, parsed lines, children, the
parsed style. `runtime::Inner` keeps one cache entry per node (props, lines
and the mapped `ParsedStyle`), dropped when a pump says the prop changed,
so a frame reads each value from the core once. Input goes back as
`uit_emit`, `uit_request` and `uit_mirror`, queued by listeners and handed
to the core in order on the main thread. Host commands from the pump
(`UIT_CMD_*`) open windows, run window and component verbs, set menus,
keys and the theme. The renderer holds no protocol error strings and no
ctl parser: `Ctl` is the core's already-parsed command.

Style: the core hands over parsed words (`uit_style`), tokens already
resolved to RGBA. `styling.rs` maps them with the dispatch table that
`tools/style-gen` generates (W1); `every_table_word_resolves` checks that
every word in the table has a mapping.

Types: the host registers the descriptors of the components it draws
(`spec::registration`), from `core/types/NAME/spec`.

## Tests

```
cargo test -p host       # GPUI test platform, no display needed
```

`testing::Harness` runs the real core: it listens on a private socket, a
9P client on another thread writes `$ui` as an app would, and the test
thread pumps until the write is acked, then draws. Events come back by
reading `events` over 9P. Paths are 0.2 (`win/main/f/ok`).

`tests.rs` covers what the core serves today (the spike's tree: `ctl`
`new`/`set`/`delete`/`quit`/`show`, prop files, `keys`, `menu/NAME`, the
app `events`). The per-group render tests from uitreefs
(`components/*/tests.rs`, `canvas/render_tests.rs`) are still in the
uitreefs spelling and need core features the spike does not have (other
windows, node `events`, `bounds`/`focus` files, `tree` documents,
requests, drags); they are kept out of the build with `#[cfg(any())]`
and get ported group by group as W3 lands those parts.

## What the core does not offer yet

Each of these has a stopgap in the renderer, marked in the code, that
goes when the core has it:

- `uit_lines` returns `UIT_ENOTSUP`: `uitcore::Core::lines` splits the
  prop text itself (`fallback_lines`).
- `uit_bounds` returns `UIT_ENOTSUP`: bounds are kept host-side
  (`Inner::bounds`) and not visible to clients.
- Window files (`state`, `bounds`, `focus`) have no ABI call; the host
  mirrors them on the window's root node with `uit_mirror`.
- App-level files (`assets/`, the clipboard read back, `theme/name`) have
  no ABI; `NodeView::asset` returns nothing and the clipboard is
  write-only.
- `uit_request` returns 0 (default applied) with no `UIT_CMD_ANSWER`; the
  host applies the default answer itself, so a tab or dock panel close
  that the core should do (remove the node) does nothing yet.
- `uit_drag` and `uit_menu` return `UIT_ENOTSUP`: drag sources and drop
  targets are wired to `uit_drag` but nothing reaches the client.
- Key contexts are not in the spike's matcher.
- The `message-list`, diagnostics and completion line formats are not in
  components.md 0.2; the host still parses them from the prop text as
  uitreefs did.
