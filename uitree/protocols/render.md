# render: renderers as 9P clients

**Layer:** `render 0.1` (draft) · **Mount:** `$render`, never in
the app's namespace · **Required:** no ·
**Conventions:** [README.md](README.md#shared-conventions)

Today a renderer links the core through the C ABI
([`uitcore.h`](../core/include/uitcore.h)): the core queues changes and
wakes it, the renderer pumps on its main thread and reads nodes in place.
This layer adds a second way in. The core serves a **renderer tree**, and
any 9P client that mounts it can draw the app: a renderer written in any
language, in another process or on another machine, or in a browser across
a WebSocket.

The C ABI stays. GPUI and the terminal keep linking the core, and the
renderer tree is a thin layer over the same calls: one encoding of each
pump, fanned out as bytes to whoever is attached. It is in the core
([`core/src/render/`](../core/src/render/)) behind ABI 7's
`uit_render_listen`, and has three clients: a browser DOM renderer
(`uitree-remote -W`), the terminal renderer (`uitree-tui --remote`,
through the core's own `uit_render_dial`), and a toy in Python
([`renderer/toy-py/render.py`](../renderer/toy-py/render.py)). Numbers are
in [§ Latency](#latency); what's built is in [§ Status](#status).

## In one picture

```text
 app (rc, Go, ...)              uitree core                     renderers
 ─────────────────              ───────────                     ─────────
  $ui/win/main/ctl ──9P──▶  OpQueue ─▶ pump ─▶ UitChanges ──C ABI──▶ GPUI, TUI (in process)
  $ui/events ◀──────9P───   events      │                   ◀─C ABI── uit_emit, uit_bounds, ...
                                        ▼
                                  encode once ─▶ changes ──9P──▶ any client: Python, a browser, ...
                                  input ◀───────────────────9P── clicks, keys, layout, frames
```

Two trees, two audiences. `$ui` is the author's tree, for the app. The
renderer tree is the display's, for renderers. They are served on
different listeners (or attach names), and the app's namespace never has
the renderer tree in it, so an app can't forge clicks.

## Who does layout

**The renderer, as today.** GPUI lays out with Taffy and the terminal
with Yoga; each measures its own text with its own fonts. The core never
measures text and never computes a position. A renderer reports what it
laid out as `bounds` input lines, exactly as it calls `uit_bounds` now,
and the core serves them from each node's `bounds` file.

So a 9P renderer doesn't need text measurement or layout queries from the
core. What it needs is everything that decides what to draw: types,
props, style words, the theme's tokens, order, overlays, focus. That is
what the change stream carries. The scoping note that suggested the core
would have to "write out text layout and measurement queries" assumed the
core does layout. It doesn't, and this layer keeps it that way.

Two consequences:

- **Bounds come from one renderer.** With several attached, only the
  primary's layout reaches `bounds` and `pt=` ([§ Several renderers](#several-renderers)).
- **Canvas hits and text input stay in the renderer.** It hit-tests its
  own layout and sends the event; it edits its own input fields and sends
  `mirror` with the new value, as `uit_mirror` does.

## The tree

```text
$render/
    version      `uitree-render 0.1`, then layer and feature lines
    hello        write: who this renderer is and what it draws
    renderers    one line per attached renderer: NAME ROLE
    changes      a snapshot, then batches; one stream per open
    input        write: lines, each one thing the user or platform did
    asset/NAME   an asset's bytes, read when the stream names it
    clip         the clipboard to publish, read when the stream says so
```

A renderer's whole session is: write `hello`, open `changes` and `input`,
read `changes` forever, write `input` as things happen. Two fids, one
connection.

**Transport.** Anything that carries 9P2000: a unix socket, TCP, an fd
pair, or the browser channel the web port uses (`uit_web_serve` in PR 21;
the renderer tree would be served on such a channel the same way). The
core serves the renderer tree on its own listener, or on the same one
under attach name `render`, never under the app's attach.

## hello

One line, written before anything else on the connection:

```text
hello name=web role=primary types=div,text,button,input profiles=core,form features=overlays,windows
```

| Attribute | Meaning |
| --- | --- |
| `name` | for people and `renderers`; any word |
| `role` | `primary`, `mirror` or `view` ([§ Several renderers](#several-renderers)); default `mirror` |
| `types` | the types it draws; default: all of `$ui/types` |
| `profiles` | the component profiles it claims ([components.md](components.md#profiles)) |
| `features` | `windows` (more than one window), `overlays`, `popups`, `menus`, `drag`, `clip`, `themes` |

`hello role=primary` fails with `in use` while another primary is
attached. A connection that never says hello is a `mirror` named
`renderer`.

**Types a renderer doesn't draw.** The app's catalog doesn't change when
a renderer attaches, because the app may have started before any
renderer did. So a renderer can meet a type it didn't list. It draws it
as a `div` (its style and children, none of its props), which is the
fallback rule every closed set in the spec has. The core should log a
`trace` line `render NAME lacks TYPE` once per type, so the author can
see it. `types` and `profiles` are advisory in 0.1; a later version may
let the core refuse an app's `new` of a type no attached renderer draws.

## The change stream

`changes` is a stream ([core.md](core.md#subscriptions)): reads block,
any read size works, and each open is its own subscription with its own
queue. What it carries is text in the `ctl` grammar: `tokenize` words,
`name=value` attributes, a lone `:` before style words, and here-values
(`text=<<END`) for anything with a newline.

### Framing

```text
snap 4                       a whole tree: throw away yours
theme mode=light tokens=<<END
background #ffffff
...
END
window main title=Counter size=300,180 pos=center state=normal
new div win/main : h-flex size-full items-center justify-center gap=20 bg=background
new div win/main/dec tag=dec on=click : size=40 flex items-center ...
new text win/main/dec/t text=−
new text win/main/n text=0 : text-3xl font-semibold w=72 text-center
new div win/main/inc tag=inc on=click : size=40 flex items-center ...
new text win/main/inc/t text=+
end 4
batch 6                      what one pump changed
set win/main/n text=1
end 6
```

That is the counter's stream, verbatim from the spike. Every record
between `snap N` or `batch N` and `end N` applies as one step: a renderer
applies them all, then draws one frame. `N` is the pump number; it only
grows. A batch carries nothing for a pump that changed nothing a renderer
draws.

### Records

| Record | Meaning | C ABI source |
| --- | --- | --- |
| `window NAME prop=value ... state=S` | a window and its props (title, size, min, max, pos, kind, titlebar, resizable, state) | `UIT_CMD_WINDOW`, a window's prop files |
| `window-ctl NAME VERB ...` | a window verb: show, activate, close, destroy, ... | `UIT_CMD_WINDOW_CTL` |
| `new TYPE PATH words props : style` | a node, its set props and style; appended to its parent's order | `UitChanges.created` + `uit_prop`, `uit_style` |
| `set PATH [words] prop=value ... [: style]` | props that changed; with `:`, the node's words and style as they now are; `order=` reorders | `UitChanges.props` |
| `mirror PATH prop=value ...` | a renderer's input (typing, a toggle): apply it, but a renderer may skip its own echo | `UitChanges.mirrors` (ABI 7) |
| `delete PATH` | the node and its subtree; out of its parent's order | `UitChanges.removed` |
| `overlay open\|close PATH` | an overlay opened or closed | `UIT_CMD_OVERLAY` |
| `focus WIN PATH` | key focus moved (`-` for none) | `UIT_CMD_FOCUS` |
| `verb PATH VERB ...` | a component verb: `scroll-to 3`, `select-all` | `UIT_CMD_COMPONENT_VERB` |
| `theme mode=M name=N tokens=<<END` | the mode, the theme's name (empty: none) and every token's value | `UIT_CMD_THEME`, `uit_token_text` |
| `keys text=<<END` | the key bindings, as `$ui/keys` reads | `UIT_CMD_KEYMAP`, `uit_keys` |
| `menu NAME text=<<END` / `menu-bar NAME ...` | a menu's lines, the bar's names | `UIT_CMD_MENUS`, `uit_menu` |
| `action ID enabled=0\|1 check=-1\|0\|1\|2` | an action's state changed | `UIT_CMD_SET_ACTION` |
| `asset NAME` | `asset/NAME` changed: read it again | `UIT_CMD_ASSETS` |
| `clip text=V` | publish V (also readable as `clip`) | `UIT_CMD_CLIPBOARD` |
| `dragging ID N` | the renderer's `drag start ... id=ID` is drag N | `uit_drag` |
| `answer ID VALUE` | the app answered request `ID` | `UIT_CMD_ANSWER` |
| `redraw WIN` | a batch committed: draw now even if nothing else changed | `UIT_CMD_REDRAW` |
| `quit` / `exit STATUS` | the app quit / the h9 client exited | `UIT_CMD_QUIT`, `UitChanges.exited` |
| `term PATH cols=C rows=R cursor=X,Y ...` | a terminal's size and cursor ([§ Terminals](#terminals)) | `UitChanges.terms` + `uit_term_cursor` (ABI 9) |
| `term-styles PATH first=N text=<<END` | terminal style table entries from id N | `uit_term_styles` |
| `term-rows PATH text=<<END` | terminal rows that changed, as runs | `uit_term_rows` |

A renderer ignores a record it doesn't know, as readers do everywhere in
the spec. Asset bodies stay out of the stream: `asset NAME` says read
`asset/NAME`.

### Encoding rules

- **Paths, not handles.** A node is named by its path from `$ui`
  (`win/main/f/ok`; an overlay `win/main/over/x`), the same path the
  app's `ctl` takes. A path never changes while its node exists
  ([core.md](core.md#paths)); moving a node is a delete and a new, and a
  rewrite that makes a new node at an old path sends `delete` first. The
  core keeps the handle map; the renderer never sees a handle.
- **Values as written.** Props travel as their file's text, data files
  (`items`, `rows`) included, with here-values for newlines. The renderer
  parses data lines by the type's format, as `uit_lines` does today.
- **Style as written, tokens once.** `new` and `set` carry style words as
  the app wrote them (`bg=accent`), and `theme` carries the token table.
  The renderer looks names up in it. A theme switch is then one `theme`
  record, not every node's style again. (The C ABI resolves tokens per
  node in `uit_style`; that's cheap in process and wasteful on a wire.)
- **Order is a delta.** `new` appends to the parent's order and `delete`
  takes the node out, as they do on a `ctl`. `set PATH order=...` is sent
  only when the tree's order isn't what those imply. The spike first sent
  every parent's whole order on every change, which made a 1,000-row list
  built one write at a time cost 2.7 MB of stream; with deltas it's
  258 KB, linear in the rows.
- **A window arrives when it shows.** A window made hidden is not in the
  stream; the batch where it first shows has its `window` line and then
  everything it holds, as a snapshot would say it. A window's own files
  (`state`, `title`, `size`, ...) travel as `window` and `window-ctl`, never
  as `set` on its root.
- **A type change is a remake.** `mkdir` then a write to `type` turns a
  div into something else; the stream says `delete PATH` and `new` lines
  for the node and its subtree.
- **An app's batch waits.** Between the app's `begin` and `commit` the
  stream reads the state from before the batch, as a built-in renderer
  does; nodes made and removed inside it are held back and go out with the
  commit's batch. A resync asked for meanwhile waits for the commit too.
- **Words go with style.** A node's flag and variant words change with its
  style, so a `set` with `:` carries the words as they now are as well.
- **Within a batch:** `window` lines (with any newly shown window's
  content), then deletes (only the top of each removed subtree), then
  remakes and news (parents first), then sets, then mirrors, then order
  fixes, then terminal records, then the host commands in the order the
  core issued them.

### Terminals

A `terminal` node's screen is the core's ([components.md](components.md#new-in-this-spec)),
so the stream carries its cells: what `uit_term_cursor`, `uit_term_styles`
and `uit_term_rows` hand a renderer in process, encoded once per pump. A
renderer draws them as they are and never parses program output. The
spelling is pinned by [`render/tests.zig`](../core/src/render/tests.zig)
and written and read by [`render/term.zig`](../core/src/render/term.zig).

```text
term win/main/sh cols=80 rows=24 cursor=3,1 shape=bar visible=on blink=on
term-styles win/main/sh first=0 text=<<END
- - -
#cd3131ff - - bold italic
- #1e1e1eff #ffcc00ff inverse underline=curly
END
term-rows win/main/sh text=<<END
0 0:1:2 '$ ' 2:0:6:sel 'ls -la' 10:2:4 日本 15:0:3 'it''s'
1
END
```

- **`term`** gives the grid's size and the cursor: its cell, `shape`
  (`block`, `bar`, `underline`, `block-hollow`), `visible` and `blink`. It
  follows the node's `new` line and comes again whenever any of them
  change.
- **`term-styles`** gives the style table, one style per line from id
  `first`: foreground, background and underline color as `#rrggbbaa` or
  `-` for the default (the theme's `foreground`; no fill; the cell's
  foreground), then the attribute words `bold faint italic inverse strike
  blink invisible overline` and `underline=single|double|curly|dotted|dashed`.
  Id 0 is the default style. `first=0` replaces the table, which happens
  in a snapshot and when the core renumbers it; any other `first` appends.
  It is sent only when the table changes.
- **`term-rows`** gives rows as runs. A line is the viewport row, then one
  `COL:STYLE:WIDTH` word per run (`:sel` added inside the selection)
  followed by the run's text as one quoted word. Cells no run covers are
  blank in style 0; a line with only the row number is a blank row. A
  batch lists every row the pump changed; a snapshot lists the rows that
  aren't blank.
- A renderer ignores attribute words and records it doesn't know, as
  everywhere in the stream.

Terminal input goes on `input` as these lines, which mirror the C ABI's
calls. Keys need no line of their own: `key` with the terminal focused
reaches it, as `uit_key` does.

```text
term-resize win=main node=sh cols=80 rows=24 cw=16 ch=34
term-mouse win=main node=sh action=press button=left col=4 row=2 mods=shift,ctrl clicks=2
term-scroll win=main node=sh lines=-3
term-text win=main node=sh text=日本語
```

## Snapshot and resync

- **Every open starts with a snapshot.** The core builds it on its owner
  thread right after a pump, from the same pinned state a built-in
  renderer reads, and queues it ahead of the next batch. So snapshot and
  batches join without a gap or an overlap; there is no seq to compare.
- **A slow renderer gets a new snapshot instead of a backlog.** A
  subscription's queue is bounded (the spike: 4 MiB unread). Past it, the
  core drops the queue and sends `snap` again at the next pump. A
  renderer that sees `snap` throws its tree away. In an early run of the
  spike (before order deltas) a Python renderer fell 71 MB behind,
  recovered this way 13 times, and ended with the right counter.
- **Attaching later is the same thing.** A renderer that attaches while
  the app runs gets the app as it is now. In the spike a second renderer
  attached to a running 15,000-node app and had it 204 ms later; the
  core's share of that was 27 ms to encode 744 KB, the rest was Python
  parsing it.
- **End of file** on `changes` means the app is gone.

## Input

`input` takes lines, applied in order, each on the core's owner thread as
the matching `uit_*` call. A write returns when its lines are applied, or
fails with the protocol's error text for the first bad one. The grammar
is `/debug/inject`'s ([`ninep/debug.zig`](../core/src/ninep/debug.zig)),
which is already the C ABI's input calls written as lines, so the
headless host and the renderer tree share one parser:

| Line | C ABI call |
| --- | --- |
| `event NAME win=W node=PATH [attr=value ...]` | `uit_emit` |
| `mirror win=W node=PATH file=F value=V` | `uit_mirror` |
| `bounds win=W node=PATH value='x y w h'` | `uit_bounds` (primary only) |
| `frame win=W` | `uit_frame_drawn` (primary only) |
| `key win=W stroke=cmd-s` | `uit_key` |
| `menu item=ID` | `uit_menu_action` |
| `appearance mode=light\|dark` | `uit_system_dark` (primary only) |
| `request NAME win=W node=PATH id=ID [default=X]` | `uit_request`; the answer comes back as `answer ID VALUE` |
| `closed win=W` | `uit_window_closed` (primary only) |
| `drag ...` | `uit_drag`; the inject grammar plus `start`/`drop`/`end` |
| `term-resize win=W node=PATH cols=C rows=R cw=PX ch=PX` | `uit_term_resize` (primary only) |
| `term-mouse win=W node=PATH action=A button=B col=C row=R [mods=M] [clicks=N]` | `uit_term_mouse` |
| `term-scroll win=W node=PATH lines=N` | `uit_term_scroll` |
| `term-text win=W node=PATH text=V` | `uit_term_text` |

`node=` is window-relative with `win=`, as in events. `request` takes an
`id` the renderer picks, because a write can't return the seq the C ABI
call returns.

## Several renderers

Any number can attach. Each has a role:

| Role | Gets the stream | Sends input | Its layout and frames count |
| --- | --- | --- | --- |
| `primary` | yes | yes | yes: `bounds`, `frame`, `closed`, `appearance` |
| `mirror` | yes | yes, except the primary-only lines, which are dropped | no |
| `view` | yes | no: `input` fails with `permission denied` | no |

- **One primary at most.** It owns the app's geometry: node `bounds`,
  `pt=`, window size and position, and the frame that ends a batch's
  wait. A second renderer lays out for itself (a phone-sized mirror of a
  desktop app is fine) but its numbers would contradict the primary's, so
  they're dropped. With no primary, nothing reports bounds, as in the
  headless host.
- **Shared state is the core's.** Focus, open overlays, input values,
  selection and the theme are in the tree, so every renderer sees the
  same. A click on a mirror is a click.
- **Local state is the renderer's.** Hover, pressed, scroll offsets,
  text caret and IME composition stay in each renderer. Two people typing
  in the same field from two renderers is last `mirror` wins.
- **The primary leaving** frees the role; the next `hello role=primary`
  takes it. 0.1 doesn't promote a mirror on its own.
- **Requests** go to the app as today; the answer comes back on every
  renderer's stream as `answer ID VALUE`, with the id the asking
  renderer gave.

The built-in renderer, when there is one, is the primary. A 9P renderer
then can only be a mirror or a view, which is the shape of "show this
app in a browser too" and of assistive tools.

## Latency

Measured with the spike in this container (Linux x86-64, release build,
unix socket, h9's native backend), clicking the counter's `+` from the
Python renderer:

| | p50 | p90 |
| --- | --- | --- |
| Encode one batch (counter) | 4 µs | 5 µs |
| Pump (counter, the same with the C ABI) | 42 µs | 68 µs |
| Batch encoded → applied by the Python renderer | 0.22 ms | 0.28 ms |
| Input line written → applied and pumped (one 9P write) | 0.67 ms | 0.85 ms |
| Click → new text applied (whole round trip, through rc in h9) | 11.7 ms | 12.8 ms |

| Snapshot | bytes | core encode | Python applies |
| --- | --- | --- | --- |
| counter, 7 nodes | 4.9 KB | 0.13 ms | 1.2 ms |
| 1,000 rows, 3,005 nodes | 148 KB | 3.5 ms | 38 ms |
| 5,000 rows, 15,005 nodes | 744 KB | 27 ms | 204 ms |

Compared with the C ABI, a 9P renderer pays the encode (microseconds),
one socket hop each way (well under a millisecond with a Python client,
less in Zig or Rust) and its own parsing. The core's pump is the same
either way. The round trip is dominated by the app, which already talks
9P to the core: here, rc in h9 reading `events` and writing `ctl`. So a
9P renderer adds about a millisecond to a 12 ms click, which is not
noticeable; for comparison, PR 21 measured 28 to 50 ms for the same
click in the browser.

On an M3 Max (macOS, 120 Hz display), [bench/latency](../bench/latency/README.md)
put the same click next to a native GPUI app. Times are p50 from the
click handler: **state** is the new text in the renderer's hands,
**frame** the next frame starting after it was drawn
([results-mac.txt](../bench/latency/results-mac.txt)):

| Renderer | App | state | frame |
| --- | --- | --- | --- |
| native GPUI, no uitree | in process | 0.04 ms | 14.2 ms |
| built-in (C ABI) | Go on the host, 9P | 0.42 ms | 16.1 ms |
| built-in (C ABI) | Go in h9 | 1.21 ms | 16.0 ms |
| built-in (C ABI) | `counter.rc` in h9 | 31.7 ms | 41.7 ms |
| 9P (Python, no drawing) | Go on the host | 0.71 ms | |
| 9P (Python, no drawing) | Go in h9 | 1.20 ms | |
| 9P (Python, no drawing) | `counter.rc` in h9 | 6.2 ms | |

With a compiled app, uitree, 9P and h9 together cost under a frame over
native GPUI, and a 9P renderer adds about 0.3 ms to the state point on
top of the C ABI. The rc rows differed (31.7 ms behind the built-in
renderer, 7.8 ms behind the 9P one) because of the build, not the
renderer: GPUI's uitcore-sys builds the core ReleaseSafe and the bench
built `uitree-remote` ReleaseFast, and h9 in ReleaseSafe starts guest
processes several times slower (the `awk` that `counter.rc` runs per
click: 24 ms vs 4 ms). The bench now links GPUI to the same core.

What would hurt is a big rewrite on a slow renderer: a 15,000-node
snapshot is 744 KB, and parsing is the renderer's cost, not the wire's.
That is the case resync and order deltas are for.

## Relation to the C ABI

The renderer tree is built on the C ABI's own calls: its input lines are
the `uit_*` input calls, and the encoder reads what a renderer reads. ABI
7 ([`uitcore.h`](../core/include/uitcore.h)) adds:

- **Encoding inside `uit_pump`** when anything is attached, so a built-in
  renderer and 9P renderers share one pump. With nothing attached it
  costs nothing. 9P renderers' input runs at the start of the pump, as a
  built-in renderer's calls would.
- **`uit_render_listen(core, addr, flags, &dial)`**,
  **`uit_render_serve_fd`** and **`uit_render_serve_conn`**, as
  `uit_listen`, `uit_serve_fd` and `uit_serve_conn`. `UIT_RENDER_HOST_DRAWS`
  says the host draws the app itself, so 9P renderers can be mirrors or
  views but not the primary. GPUI serves it when `UITREE_RENDER_LISTEN`
  is set.
- **`uit_render_dial(core, addr, name, role)`**, the other end: instead of
  running a machine, the core dials a renderer tree, keeps its tree from
  the stream ([`render/dial.zig`](../core/src/render/dial.zig) over
  [`render/replica.zig`](../core/src/render/replica.zig)) and sends
  `uit_emit`, `uit_request`, `uit_mirror`, `uit_bounds`, `uit_frame_drawn`,
  `uit_window_closed`, `uit_key`, `uit_menu_action` and `uit_system_dark`
  back as input lines. A host over the C ABI draws a remote app through
  the calls it already makes: that is all `uitree-tui --remote` is.
  `uit_drag` isn't carried yet (`UIT_ENOTSUP`).
- **`UitChanges.mirrors`**: files a renderer changed through `uit_mirror`.
  They aren't `props` (the renderer that typed has them), but other
  renderers need them; the stream says them as `mirror` records.
- **`uit_node_props`**: a node's set props in the order they were set,
  which the encoder needs for `new` lines and an inspector would want too.

ABI 9 adds the terminal calls the `term` records and `term-*` input lines
carry ([§ Terminals](#terminals)): `uit_term_rows`, `uit_term_styles`,
`uit_term_cursor`, `uit_term_resize`, `uit_term_mouse`, `uit_term_scroll`,
`uit_term_text` and `UitChanges.terms`.

Nothing in `$ui` changes.

## Status

Built (`zig build remote` in `core/` for `uitree-remote`):

- **In the core** ([`core/src/render/`](../core/src/render/)): the encoder
  (`stream.zig`), the tree and its fan-out (`hub.zig`), the replica
  (`replica.zig`), the dialing side (`dial.zig`).
- **The conformance check**: `uitree-headless --check-render` encodes
  every pump of a run, replays the stream into an empty tree, and compares
  the two as documents (every window's `tree` and `over/`, focus, title,
  keys, menus, theme) at the end. `tests/conformance/run -r` runs it under
  all 30 scripts, in CI, and all 30 agree. `$UITREE_RENDER_DUMP=FILE`
  keeps the stream. [`render/tests.zig`](../core/src/render/tests.zig)
  pins the stream's spelling, and one test has a core draw another
  core's app over a real socket.
- **`uitree-remote`**: a host with no renderer of its own, over uitcore.h
  only. `-R ADDR` serves the renderer tree; `-W tcp!HOST!PORT` serves a
  browser renderer at `http://HOST:PORT/`
  ([`remote/page.html`](../core/src/remote/page.html): a 9P client over a
  WebSocket at `/9p`, a DOM for the common types and style words, clicks,
  typing, Enter, toggles and tabs as input), with each WebSocket handed to
  `uit_render_serve_conn`.
- **The terminal renderer as a 9P client**: `uitree-tui --remote ADDR
  [--role R]` draws an app `uitree-remote` (or GPUI with
  `UITREE_RENDER_LISTEN`) runs.
- **The toy in Python**: `render.py ADDR [--draw] [--bench N] [--once]`.

Checked by hand here: the TUI and the browser each drew the counter and
the to-do example running in `uitree-remote`; keys, clicks and typing
reached the app (the to-do file had the items).

Not yet: drags from a dialing core, GPUI mirroring checked on a display,
a browser renderer that lays out the way GPUI does, and the browser build
(PR 21's) dialing a renderer tree from inside the page.

## Open questions

1. **Separate listener or attach name?** A listener is simplest to keep
   out of the app's namespace; an attach name needs one socket. 9/UX
   would want `/mnt/render` beside `/mnt/ui`, served by the same process.
2. **Should a `view` see `secret` values?** Documents already leave them
   out; the stream sends input values so a mirror can draw them. A view
   for assistive tools probably shouldn't get them by default.
3. **Should the app be told who's watching?** An `$ui/renderers` file, or
   events on attach, would let an app adapt (a phone mirror). It also
   leaks who is watching to the app.
4. **Binary assets on the wire.** 0.1 reads `asset/NAME` on demand. A
   browser renderer might rather have a URL.
6. **A mirror's own echo.** `mirror` records go to every renderer,
   including the one that typed. A renderer that applies its own echo
   while the user keeps typing can lose keystrokes on a slow link. The
   terminal keeps its own edit buffer for the focused field, and the
   browser page skips the echo for it. Should the stream
   leave it out for the sender instead (a per-subscriber filter)?
5. **Per-renderer window geometry.** A mirror with a smaller screen lays
   out differently but the app sees only the primary's `bounds`. Is that
   right, or should a mirror's window size be visible somewhere?
