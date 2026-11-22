# gpuifs conformance suite

W8 of [PLAN.md](../../PLAN.md). One rc script per section of
[DESIGN.md](../../DESIGN.md), run headless, with golden output. None of it
has run yet: gpuifs doesn't exist past its W0 stubs. The goldens are written
by hand from DESIGN.md, and where DESIGN.md doesn't pin the exact text they
follow the proposals below. [GAPS.md](GAPS.md) lists every one of those
places. When M1 lands, expect a first round of diffs that are the suite's
mistakes, the implementation's, or a gap being decided, and settle each one
on purpose.

```sh
# from gpuifs/, with Zig 0.16 on PATH and a 9front amd64 root (crates/h9sys/README.md)
cargo build -p gpuifs --no-default-features
export H9ROOT=$PWD/third_party/hyper9/.local/9front/rootamd64
tests/conformance/run                     # every script
tests/conformance/run -m M1               # only what M1 should pass
tests/conformance/run 14-events 15-requests
tests/conformance/run -u 14-events        # rewrite a golden from this run, then review the diff
tests/conformance/run-examples            # the examples' tree-building phase
```

`run` executes `gpuifs --headless rc ./NN-name.rc` in this directory, appends
`exit=N`, removes `seq=` attributes (their numbering isn't fixed), and diffs
against `NN-name.out`. If `NN-name.trace` exists it diffs the headless trace
(standard error) too. Each script's header names the milestone it needs and
the workstreams it exercises. Results go to `out/`, which is ignored by git.

## The scripts

| Script | DESIGN section | Milestone |
| --- | --- | --- |
| 01-root | The tree | M1 |
| 02-node-files | Node files | M1 |
| 03-create | Creating nodes | M1 |
| 04-quoting | Quoting | M1 |
| 05-windows | Windows | M1 |
| 06-style | Style language | M1 (W5a, W6a TypeSpecs) |
| 07-theme | Theme | M1 |
| 08-elements | Element tier, Making an element interactive | M1 |
| 09-forms | Buttons and form controls | M1 (W6a TypeSpecs) |
| 10-navigation | Navigation | M1 (W6b TypeSpecs) |
| 11-overlays | Overlays | M1 (W6b TypeSpecs) |
| 12-data | Data display | M1 (W6c TypeSpecs) |
| 13-editing-layout | Editing and rich content, Layout | M1 (W6d TypeSpecs) |
| 14-events | Events, Two kinds of event | M1 |
| 15-requests | Requests | M1 |
| 16-drag-drop | Drag and drop | M4 |
| 17-clipboard | Clipboard | M1 |
| 18-keymap-menus | Actions, keymaps and menus | M1 |
| 19-focus | Focus | M1 |
| 20-batches | Batches | M1 |
| 21-tree-docs | Subtree documents | M1 |
| 22-canvas | Canvas | M1 (W7 TypeSpec) |
| 23-errors | Errors and limits (phrases) | M1 |
| 24-limits | Errors and limits (limits) | M1 |
| 25-trace | The tree (trace), Who can reach the tree | M1 |
| 26-lifecycle | Running a client in h9 | M1 |

"M1 (W6a TypeSpecs)" means the script is headless but needs that stream's
`catalog` half, which PLAN.md lets start in phase 1.

Not covered here, because a headless rc client can't see them: what a window
draws while a batch is open, focus and hover styles, and anything about
pixels. Those belong in W5b's `TestAppContext` harness. Two sessions sharing
a tree (batches are per session) need a second 9P client; that is a
follow-up once `-a` works, driven from the host with plan9port's `9p`.

## Writing a script

[lib.rc](lib.rc) has the helpers. The rules of PLAN.md § Design questions
14 apply: only h9's built-in root (no `printf`, `head`, `dd`, `hoc`, `seq`
or `kill`), events read in blocks, every `=` in an rc argument quoted, and
here documents only at the top level.

- `w file words...` writes and prints `ok` or the DESIGN error phrase. `wd`
  prints the detail after the colon as well. `wq` prints only on failure.
- `val file` prints the bytes then `|`, so a golden shows whether a trailing
  newline is stored.
- Events: open the file on fd 3 around a block, so the subscription exists
  before the events, then `evs` with the attributes of a sync event that
  reaches that file:

  ```rc
  {
  	inj event click 'win=main' 'node=root/a'
  	evs 'win=main'
  } <[3]$k/windows/main/events
  ```

  `evs` injects `sync`, prints every line before it with `seq=` removed, and
  stops. `evraw` keeps `seq=`, for answering requests (`seqof name` reads it
  back from `/tmp/ev`).
- Errors from an rc redirection (opening a file that isn't there) can't be
  caught reliably in a script, so absence is checked with `exists`, and
  open errors with `rd`, which lets `cat` report them.
- Writes to text and data files apply at clunk (PLAN.md § Design questions
  1), so their errors are invisible to `echo` and `cat` (see GAPS.md 1).
  Scripts check those by reading the file back.

## Proposed: `/debug/inject` (W3, headless only)

The headless backend's debug file. Each write is one or more lines in the
`ctl` syntax, applied in order. Nothing written here appears in `trace`.

| Line | Does |
| --- | --- |
| `event NAME [win=W] [node=PATH] [attr=value ...]` | `Tree::emit` (or `open_request` if the node's TypeSpec, or the window/app, says `NAME` is a request), as if the user did it. `node=` is window-relative. The tree fills `tag=` and `seq=`; it adds `via=user` to state events unless the line gives `via=`. A name the spec doesn't list (the suite uses `sync`) is an action event with no `via=` |
| `mirror [win=W] [node=PATH] file=NAME value=TEXT` | `Tree::mirror(..., Via::User)`: the component's state changed this file. It sends no event; scripts inject the event separately, since a controlled component sends one without the other. With no `node=`, `file` is a window file (`focus`) |
| `bounds win=W node=PATH value='x y w h'` | `Tree::report_bounds` |
| `frame [win=W]` | `Tree::frame_drawn` for one window or all. Headless draws no frame on its own, so `type` stays writable until a script says a frame happened |
| `tick SECONDS` | Advances the fake clock and runs `Tree::tick`, for batch and request timeouts without sleeping |
| `drag n=N type=TYPE data=TEXT` | Makes `/drags/N/data` hold `TEXT`, as a platform drag would, before a `drop` event names `drag=N` |

## Proposed: formats DESIGN leaves open

These are what the goldens assume. Each is in GAPS.md with the reason.

- **Event lines.** `name win= node= tag= <the event's own attrs> via= seq=`.
  `tag=` is present (`tag=''` when empty) whenever `node=` is. `via=` is on
  state events (`ctl` or `user`) and on `close` and `quit` requests (`ctl`,
  `user`, `titlebar`, `menu`). Values are quoted with `proto::quote`, so
  only blanks, quotes and empty values are quoted.
- **Echoes.** A client write to a file that a state event reports (`value`,
  `state`, `focus`, a window's `state`) sends that event with `via=ctl`.
  `ctl` verbs (`open`, `close` on an overlay) send no echo.
- **`tree` printing.** `type name`, then each set property as
  `  prop=value` (two spaces before each), in the order the properties were
  first set, child lines indented two more spaces, in `order` order.
  Properties at their default aren't printed. A multi-line value is
  `prop=<<END`, then its lines unindented, then `END` at the node's indent;
  the lines are joined with newlines, so a value ending in a newline shows a
  blank last line (W1's canonical form, `crates/proto/src/doc.rs`). This makes
  `print(parse(x)) == x` hold for DESIGN's own sign-in document.
- **Computed files** (`type`, `order`, `id`, `bounds`, `title`, `state`,
  `focus`, `tag`, `style`) read back with no trailing newline. `id` and
  event `node=` are window-relative (`root/card`).
- **Error phrases** for cases the table doesn't name: an unknown prop or
  window option is `not found` (it names a file that isn't there); a child
  type a component doesn't take is `unknown type`; `begin` inside a batch is
  `in use`; an answer to a request that was never made, or already answered,
  is `not found`.
- **Trace lines.** One per applied change, in the event-line style:
  `ctl path=P cmd=C` (one per command line of the write),
  `write path=P value=V`, `mkdir path=P`, `remove path=P`,
  `batch timeout win=W`. Paths are from the root with no leading slash. A
  value with a newline, or over 64 bytes, is written `len=N` instead. A
  secret value is `value=<secret>`, in a `write` and inside a `cmd=`.
  Failed writes are not traced.
- **Write timing per file.** `ctl`, `style`, `order`, `tag`, `on`, `type`,
  `flags`, `drop`, `drag-type`, `context`, `theme/*`, `keymap`, `menus/*`,
  `focus`, and props that hold a word or a few numbers (`value` of a
  checkbox, select, slider or progress; `page`; `expanded`; `origin`;
  `selection`; `controlled`; `sorted`; `on`-style flags) apply per
  write, so `echo` sees their errors. Text and data files (`text`, `label`,
  an input's or editor's `value`, `items`, `rows`, `columns`, `ops`, `tree`,
  `layout`, `diagnostics`, `completions`) buffer to clunk.
