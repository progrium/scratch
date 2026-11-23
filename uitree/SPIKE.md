# W0 spike: the counter through the Zig C ABI

**Go.** The counter runs end to end on Linux with the tree in Zig and the
window in Rust/GPUI, talking only through `uitcore.h`. Reading a
2,000-node tree through the ABI costs 0.5 ms a frame, half the 1 ms gate.
The core builds for `x86_64-windows-msvc` as a static library; a full
MSVC link with h9 in it could not be checked here and moves to W8's
Windows CI job. `uitcore.h` is frozen as **version 1**.

![the counter at 4, after three clicks on +, one on −, and two = keys](renderer/gpui/examples/screenshots/counter-after.png)

## What ran

`uitree -t Counter rc counter.rc` (the 0.2 spelling of uitreefs's
counter, in [renderer/gpui/examples/](renderer/gpui/examples/counter.rc)),
on Xvfb with lavapipe, rc running in h9 on the 9front 11952 amd64 root:

1. `uitree` (Rust, a 40-line `main`) calls `uit_create` with the types,
   style words and theme tokens it draws, then `uit_run_machine`.
2. The core (Zig) starts its 9P server on a private unix socket and runs
   `h9.Machine` on its own thread with that socket mounted on `/mnt/ui`.
   There is no h9 shim, no fd relay and no Rust wrapper around h9.
3. rc writes the `ctl`, `keys` and `menu/Counter`. The 9P thread queues
   each write and calls the renderer's `wake`; GPUI's main thread calls
   `uit_pump`, which applies it, acks the writer and returns
   `UIT_CMD_WINDOW main`. The host opens the window sized from the root's
   `size` prop and draws the tree by reading it through the ABI.
4. Clicks go back with `uit_emit` (`click inc inc win=main x=… y=…
   button=left seq=N`); the `=` key goes back with `uit_key`, which the
   core matches against `keys` (`action inc . win=main via=key seq=N`).
   rc counts and writes `set n text=N`.

Clicks on + and −, the hover and active styles and the `=` key all work:
[counter.png](renderer/gpui/examples/screenshots/counter.png),
[counter-after.png](renderer/gpui/examples/screenshots/counter-after.png),
[counter.gif](renderer/gpui/examples/screenshots/counter.gif).

The same path runs without a display in `cargo test -p uitcore`: a 9P
client thread writes a `ctl`, the test thread pumps, reads the node, its
style (a token already resolved to RGBA) and its props through the ABI,
emits a click, and the client reads it back from `events`.

## Numbers

`uitree --bench 2000`: a 9P client writes one `ctl` that builds 2,001
nodes (40 rows of 49 styled texts, each with `text`, `on`, `tag` and five
or six style words including a `hover:` one). Three runs on a 4-vCPU
container, release build, lavapipe:

| Measure | Result | Gate |
| --- | --- | --- |
| Pure ABI walk per frame: type, style words with their arguments, three props and the children of every node (12,006 calls) | **0.48 to 0.69 ms**, 40 to 57 ns a call | under 1 ms: **pass** |
| ABI reads inside a real GPUI render, copying every string out | 2.3 to 2.5 ms median, 3.1 to 3.3 ms p90 | (not a gate) |
| Whole element build for the frame (reads, style refinements, elements) | 8.7 to 9.8 ms median | (not a gate) |
| One 2,000-line `ctl` write over 9P, applied by a pump | 245 to 315 ms | (spike tree, see below) |

The gap between 0.5 ms and 2.3 ms is the host copying (`to_string` on
every type, path, word and text) and re-mapping dashed names to GPUI
calls each frame, not the boundary. The fallback the scoping doc names (a
renderer-side mirror fed by `UitChanges`) is not needed. W6 should read
borrowed `&str`s for the frame and cache each node's `StyleRefinement`,
invalidated by a `style` entry in `UitChanges.props` or `UIT_CMD_THEME`,
as uitreefs's host already does.

The 2,000-line write is slow because the spike's tree looks paths up by
scanning children; W3's tree replaces it.

## Windows

| Build | Result |
| --- | --- |
| `zig build -Dtarget=x86_64-windows-msvc` (core without h9) | **builds** `uitcore.lib`. Its undefined symbols are only ntdll and kernel32 calls, the MSVC CRT (`malloc`, `memcpy`, `__chkstk`, `__security_cookie`, `_fltused`) and `__divti3`, which Rust's compiler-builtins supplies. All 35 `uit_*` functions are exported |
| `cargo build --target x86_64-pc-windows-msvc -p uitcore-sys` against that lib | **compiles**; linking a test binary stops only at the missing Windows SDK import libraries (`kernel32.lib`, `ntdll.lib`, `ws2_32.lib`, ...), which this container can't download |
| `zig build -Dtarget=x86_64-windows-msvc -Dh9=true` | **fails here**: hyper9's drawterm `kern` is C, and Zig can't provide an MSVC libc to compile it without the Windows SDK. On a Windows machine with Visual Studio, Zig finds the SDK itself |
| `zig build -Dtarget=x86_64-windows-gnu -Dh9=true` | **builds and links** `uitcore.lib`, `kern.lib` and `uitree-headless.exe` |

So the core and the ABI are fine on MSVC; the open item is linking
hyper9's C into an MSVC binary, which needs a Windows runner. W8: add a
`windows-latest` job that runs `cargo build -p uitree` (which runs
`zig build -Dtarget=x86_64-windows-msvc -Dh9=true`). The 9P server in the
spike is POSIX only (`uit_listen` returns `UIT_ENOTSUP` on Windows); W4's
server needs a Windows transport.

macOS was not run: there is no Mac here.

## uitcore.h v1: what changed from the scoping sketch

The five groups are as sketched. Added, because the counter or a
renderer needs them and the sketch left them out:

- `UitConfig.abi_version` (checked by `uit_create`) and
  `UitConfig.system_dark`.
- `uit_listen` (a private unix socket, or an address), alongside
  `uit_serve_fd`. `uit_run_machine` serves the machine on its own socket.
- `uit_wake_renderer`, for tests.
- Reads: `uit_windows`, `uit_window_of`, `uit_keys`, `uit_menu_bar`,
  `uit_menu`, `uit_theme_dark`, `uit_token`.
- Input: `uit_key` (a keystroke the renderer's widgets didn't take; the
  core matches `keys`, so the renderer never learns the binding grammar),
  `uit_menu_action`, `uit_system_dark`. `uit_drag` returns the drag's
  number.
- `UitHostCmd` is one flat struct with a `tag`, not a union: each tag
  documents which fields it sets. A renderer ignores tags it doesn't know.
- `UitStyleArg` is `{kind, a, rgba, text}`; a theme token arrives as
  `UIT_ARG_RGBA` already resolved for the current mode, with the token
  name in `text`. A `name=a,b` word has two args.
- `UitErr` has `UIT_EVERSION` and `UIT_ETYPES`; the protocol's own codes
  stay in `uit_last_error`'s text.

Adding a `UIT_CMD_*` tag, a `UIT_ARG_*` kind or an error code is not a
version change. Anything else is: bump `UIT_ABI_VERSION`, update
`uitcore-sys`, and tell W3, W6 and W7.

Layouts are checked on both sides: `abi.zig`'s test and `uitcore-sys`'s
`layouts` test assert the struct sizes `zig cc` gives the header.

## What the spike implements, and what it fakes

Implemented in `abi.zig` for real: create, destroy, last error, pump with
every `UitChanges` field, children, type, path, prop, style, keys, theme,
token, emit, mirror, key, menu action, system dark, window closed,
listen, serve fd, run machine, shutdown.

Returns `UIT_ENOTSUP` or nothing yet: `uit_lines`, `uit_menu_bar`,
`uit_menu`, `uit_overlays` (always empty), `uit_bounds`, `uit_drag`;
`uit_request` applies the default at once (returns 0).

Shortcuts in `core/src/spike/` that W3 and W4 replace (delete the
directory when W3 lands):

- **One mutex, no snapshot.** 9P reads take `Core.mu` and read the live
  tree; only the owner thread writes it. W3 publishes a `Snapshot`.
- **One window**, `main`. No overlays, batches, requests, coalescing, or
  `tree`/documents.
- **Validation is names only.** `new TYPE` checks the type name against
  the registered descriptors; style words are checked by name against
  `style_words`. Props aren't checked (W1's `Catalog`).
- **Keys match exactly.** `cmd` isn't mapped to the platform's command
  key yet, and `context=` is ignored.
- **`uit_key` emits outside a pump**, under the core's lock. W3 should
  queue it like `uit_emit`.
- **The 9P server** is hand-rolled (no `dotl/wire.zig`), POSIX only,
  applies `ctl`, `keys`, `menu/NAME` and prop writes when the file is
  closed, and supports walk, open, create (files only), read, write,
  clunk, stat and flush.
- **Events** are `name key path win=main attrs… [via=…] seq=N`, with
  `resync` first and `gone` when a node goes; no `lost`.

## Spec 0.2 differences resolved

- The counter uses dashed style words (`items-center`, `rounded-full`)
  and the 0.2 `$ui/win/main` paths; uitreefs's `windows/main/root` is gone.
- An event's path is window-relative with `win=` (core.md § Paths):
  `click inc inc win=main …`. A click carries `x=`, `y=` and `button=`,
  as uitreefs's host sends.
- `version` reads `core 1.0` and `spike`; the real `version` file is W4's.

## Build

- `zig build test` in `core/` needs no submodule (h9 is off by default).
- `zig build -Dh9=true` links `h9.Machine` into `libuitcore.a` and now
  installs `libkern.a` beside it (a static library doesn't carry the
  libraries its modules link).
- `cargo build -p uitree` in `renderer/gpui/`: `uitcore-sys/build.rs`
  runs `zig build -Doptimize=ReleaseSafe -Dh9=true` for Cargo's target
  (`UITCORE_OPTIMIZE`, `UITCORE_LIB_DIR` and `ZIG` override it), links
  `libuitcore.a` and `libkern.a`, and asserts the header's
  `UIT_ABI_VERSION`. The GPUI pins are uitreefs's, and so is
  `Cargo.lock`, so the two share a target directory.
- Linux needs `libxkbcommon-dev` and `libxkbcommon-x11-dev` to link GPUI.
- To run: `H9ROOT=<9front root> uitree -t Counter rc counter.rc` from
  `renderer/gpui/examples/`, or `uitree --bench 2000`.
