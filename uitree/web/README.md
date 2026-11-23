# uitree/web: uitree in the browser (spike)

![The counter on both renderers in one page: GPUI on the left, the terminal renderer in xterm.js on the right](screenshots/both-renderers.png)

Both renderers in a browser page, fully client-side: no server-side h9 and
no DOM renderer. `index.html` runs `counter.rc` twice, once on each
renderer.

```
page (main thread)                                   Worker, one per app
  GPUI renderer     uitree_web.wasm (wasm-bindgen)     h9's browser host, unchanged
    └ core          uitcore-shared.wasm, same memory     h9.wasm, its 386 CPU (h86)
  terminal renderer uitree-tui.wasm (core linked in)     rc counter.rc
    └ xterm.js                                            $ui = ws://uitree.invalid/ui
                          9P over postMessage  <──────────  (h9-worker.js's WebSocket)
```

## Build and run

```sh
cd uitree/third_party/hyper9 && scripts/fetch.sh iso386 &&
  zig build isoroot -- .local/9front/9front-11952.386.iso .local/9front/root386   # once
cargo install wasm-bindgen-cli --version 0.2.130                                   # Cargo.lock's
cd uitree/web && ./build.sh            # dist/: everything the page loads
cd dist && python3 -m http.server      # http://localhost:8000
```

Needs JavaScript Promise Integration: Chrome or Edge 137 or later (h9's own
requirement). `core-test.html` runs the core with no renderer and prints
the tree; `tui-test.html` is the terminal alone. `GPUI=0 ./build.sh` skips
the Rust build.

## How it fits together

- **h9** runs unmodified: `h9/worker.js`, `h9.wasm` and `root.h9a` are
  `zig build web`'s. `h9-worker.js` wraps its Worker with one addition: a
  `WebSocket` for `ws://uitree.invalid/...` that is a channel to the page.
  The app's `$ui` is an ordinary `--url ws://...:/mnt/ui` mount, so h9
  speaks 9P to it through `#ℓ` exactly as it does to the core's unix socket
  natively.
- **The core** (`core/src/web.zig`, `zig build -Dtarget=wasm32-wasi`) runs
  its threads as hyper9's web-host coroutines (h9's `src/web.zig`, coroutines
  on JSPI) and its `std.Io` is h9's web Io. Threads were already few
  (`server.zig`'s per-connection reader and blocking requests, the timer),
  so the change is a `Thread` alias and a channel transport. The page hands
  each connection to `uit_web_serve`. There is no `uit_run_machine` in the
  core here: the page starts the Worker instead (`uit-web.js`'s `runApp`).
- **The terminal renderer** (`renderer/tui/src/web.zig`) is main.zig's
  loop turned inside out: the page calls `tui_key`, `tui_mouse` and
  `tui_pump`, and gets each frame as ANSI through an import. libvaxis's
  Tty and Loop aren't used (no tty, no threads); frames are whole-screen
  SGR text. Yoga (C++) builds for wasm32-wasi as is.
- **The GPUI renderer** is the host crate unchanged but for `run`
  (`gpui_web`'s single-threaded platform, `run_embedded`, bundled fonts)
  plus `crates/web`, a wasm-bindgen cdylib. The core is a second module,
  `uitcore-shared.wasm`, that imports the renderer's memory and lives above
  256 MiB in it (`-Dweb-base`), so every `uitcore.h` pointer means the same
  thing on both sides and `uitcore-sys`'s functions are imports forwarded
  as is (`uitcore-imports.js`). Only the wake function pointer and
  `uit_run_machine` are adjusted. This is the same shared-memory trick h9's
  browser host used with v86.

## What broke, and the workarounds

- **gpui-kit forces gpui_web's `multithreaded` feature** (through
  gpui-pre-platform's defaults), and `wasm_thread` needs nightly. The build
  uses `RUSTC_BOOTSTRAP=1`; the app uses `single_threaded_web()`, so no
  worker threads start. GPUI Kit's own story-web pins a nightly instead.
- **No system fonts in the browser.** gpui_web resolves `.SystemUIFont` to
  IBM Plex Sans and panics without it, so the host bundles IBM Plex Sans and
  JetBrains Mono (OFL, from story-web) under `crates/web/fonts`.
- **`AllAssets` is a different type on wasm** (it fetches icons on demand):
  the one compile error in the host crate.
- **getrandom** needs `--cfg getrandom_backend="wasm_js"`.
- **wasi-libc's malloc** claims all memory above its heap base on its first
  call, so with a shared memory the order is fixed (gpui.js): renderer,
  grow, core, the core's first malloc, then the renderer's start.
- **The terminal renderer spun while idle**: every input call wakes the
  core, `uit_frame_drawn` included, and main.zig redraws on every wake, so
  it pumps and draws in a loop. The web build only draws when a pump
  changed something. main.zig has the same loop (not fixed here).
- **Events before the app subscribes are lost** (by design): a click in
  the first few hundred ms after the tree appears, before `cat
  $ui/events` opens, does nothing.

## Every example, and the tests

`index.html` runs any example on both renderers (`?app=NAME`), and
`gpui.html?app=NAME` and `tui.html?app=NAME` run one, filling the page.
`apps.js` lists them: the conformance examples (counter, hello, confirm,
signin, settings, csvview, files) and `tour/tour.rc`, which uses what
none of them does (tabs, checkbox, textarea, the clipboard, a link, a
tooltip, a toast, a popover, markdown, an editor, an image, a file drop
and a menu bar).

`test/run.mjs` drives them in headless Chromium on both renderers:

```sh
cd dist && python3 -m http.server 8765 &
cd .. && node test/run.mjs        # --only APP,... --renderer gpui|tui --shots DIR
```

`probe.js` is a 9P client of the page's core, a connection of its own
beside the app's: a case finds a node by its `bounds` file, acts with
the real mouse and keyboard, and checks the tree (`test/cases.mjs`).
23 cases pass: clicks, key bindings, typing, Enter, exit status, field
errors, a secret input, dialogs, sidebar pages, switch, number-input,
the select popup, radio-group, slider, theme mode and name, table
filter, sheet, context menu, alert dialog, checkbox, textarea, the
clipboard both ways, tabs, markdown, editor and image, popover, toast,
tooltip, links, and the menu bar. The terminal renderer draws a subset
of the components (no tables, sheets, sidebars or menus), so the cases
for those run on GPUI only.

What the tests found, and fixed:

- **GPUI on the web sent Enter twice** when a key binding took it:
  gpui_web turns an Enter that wasn't cancelled into a second one. A
  binding's key now stops propagation (host `window.rs`).
- **`cmd-` bindings never matched** on Linux, Windows or the web: hosts
  send their command key as itself (`ctrl-2`). The core now reads `cmd`
  in a binding as the host's `cmdkey` (native too).
- **The terminal renderer sent `click` for a press on an input**, so a
  form's tag fired as a submit (hello said "Hello, stranger!" when you
  clicked its field). A press only places the caret now (native too).
- **GPUI Kit's icons** are fetched one by one when drawn, from
  `assets/icons/`; `build.sh` copies them and the page passes the URL.
- **No menu bar in the browser**: GPUI Kit's AppMenuBar now draws the
  app's menus at the top of the window, on the web only.
- **Links on the terminal renderer** open in a new tab (`tui.open`).
- **files.rc needs `walk`**, which h9's browser root leaves out
  (`root.list`).

Still not working, or not covered:

- **File drops on GPUI** (files.rc, tour's Drop tab): gpui_web makes no
  file drops, since a browser drop has no paths. The way in is for the
  page to put the dropped files in the core's WASI file system and give
  the host a FileDropEvent with those paths; the core already reads them
  through its Io. That waits on how the core is instantiated settling
  (it's moving into the GPUI module).
- **Nodes drawn from data have no bounds**: sidebar items, menu items
  and context-menu items aren't nodes, so the tests press their keys or
  click where they're drawn (native too).
- More than one window (gpui_web has one canvas: `WindowKind::Floating`
  and second windows fail), IME composition, and pasting from the
  system clipboard into the app (`$ui/clip` holds what the app wrote).

## Size and speed

From this build (ReleaseSmall Zig, release Rust, names stripped), headless
Chromium 153 with SwiftShader (WebGPU found no adapter there, so gpui_web
fell back to WebGL2):

| File | Raw | gzip |
| --- | --- | --- |
| `gpui/uitree_web_bg.wasm` (GPUI + gpui-component + host) | 28.6 MB | 9.1 MB |
| `uitcore-shared.wasm` / `uitcore.wasm` (the core) | 0.56 MB | 0.21 MB |
| `uitree-tui.wasm` (terminal renderer + core + Yoga + libc++) | 1.1 MB | 0.33 MB |
| `h9/h9.wasm` (h9, unchanged) | 17.5 MB | 5.1 MB |
| `h9/root.h9a` (386 root: rc, awk, sed, ...) | 4.3 MB | 1.9 MB |

The GPUI module is 23 MB of code and 5.5 MB of data (fonts, syntect's
syntaxes); wasm-opt and dropping syntect are the obvious cuts.

- Instantiating the GPUI module takes about 200 ms after download; the
  core 4 ms; the terminal module with its core 50 to 70 ms.
- The counter's tree is up about 300 ms after the h9 Worker starts (h9
  boots, rc runs `counter.rc`'s writes).
- Click to redrawn number on the terminal renderer: 28 to 50 ms. That is
  the whole round trip: the event read in h9's emulated rc, `awk` forked
  for the addition, the `ctl` write back over the bridge, a pump and a
  frame. A pump is about 0.5 ms.
- The core's memory sits at 256 MiB in the GPUI module's memory, which is
  address space, not resident memory.
