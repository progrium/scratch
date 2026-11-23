# conformance (spec draft 0.2)

The suite every uitree host must pass: rc scripts that run as a client
in h9 against `uitree-headless`, with golden output. Workstream W5,
interface I5 in [ARCHITECTURE.md](../../ARCHITECTURE.md). Ported from
[uitreefs/tests/conformance](../../../uitreefs/tests/conformance) to
[draft 0.2](../../protocols/): dashed names, the 0.2 error phrases and
`code=` words, the `name key path` event head, `$ui/types`, and the
0.2 forms of windows, requests, batches, theme, keys, menus and transfer.

None of it has run yet: the host doesn't exist. The goldens are written
from the spec, and where the spec doesn't pin the text they follow the
proposals below. [GAPS.md](GAPS.md) lists every one of those places. When
`uitree-headless` first runs the suite, expect a round of diffs that are
the suite's mistakes, the host's, or a gap being decided, and settle each
on purpose: fix the golden, the host, or the spec.

```sh
cd uitree/core && zig build            # zig-out/bin/uitree-headless
cd ../tests/conformance
./run                                   # every script
./run 14-events 15-requests             # some
./run -u 14-events                      # rewrite a golden from this run; review the diff
UITREE_HEADLESS=/path/to/host ./run     # another binary
./run-examples                          # the example clients' tree-building phase
```

`run` executes `$UITREE_HEADLESS rc ./NN-name.rc` in this directory,
appends `exit=N`, removes `seq=`, and diffs against `NN-name.out`. If
`NN-name.err` exists it also diffs the `uitree: ` lines the host wrote to
standard error, cut after the error phrase. A script whose first line is
`skip: ...` is counted as skipped: it needs a layer or profile the host
doesn't claim in `version`. Results go to `out/`, which git ignores. Each
PR into `uitree` says which scripts it makes pass.

## The scripts

| Script | Spec | Needs |
| --- | --- | --- |
| 01-root | core § The tree, § Version | |
| 02-node-files | core § Node files, § Paths (`@name`) | |
| 03-create | core § Creating nodes | |
| 04-quoting | README § Tokens, core § Words and quoting, § Commands (here-values, all or nothing) | |
| 05-windows | core § Windows | |
| 06-style | core § Style (portable words, forms, `style/words`) | |
| 07-theme | core § Style (theme: tokens, pref, mode, the `theme` event) | |
| 08-elements | components § Profiles (core), core § Making an element send events | |
| 09-forms | components § Profiles (form), § The descriptor (words, verbs) | profile form |
| 10-navigation | components § Profiles (nav) | profile nav |
| 11-overlays | core § Overlays, components § Profiles (overlay) | profile overlay |
| 12-data | components § Data file formats, § Profiles (data) | profile data |
| 13-layout | components § Profiles (layout) | profile layout |
| 14-events | core § Events, § Subscriptions, § Two kinds of event | |
| 15-requests | core § Requests | |
| 16-transfer | transfer.md (drag and drop, `clipdata/`, `copy`) | layer transfer |
| 17-clipboard | core § Clipboard | |
| 18-keys-menus | core § Keys, actions and menus | |
| 19-focus | core § Windows (`focus`) | |
| 20-batches | core § Batches | |
| 21-tree-docs | core § Documents | profiles form, nav |
| 22-canvas | components § Profiles (canvas), `ops` | profile canvas |
| 23-errors | core § Errors (phrases, detail, loud) | |
| 24-limits | core § Limits (the minimums only) | |
| 25-trace | core § Trace | profile form |
| 26-lifecycle | core § Commands (`quit`), the host's exit status | |
| 27-descriptors | components § The descriptor, § Profiles: the host accepts and refuses exactly what its descriptors say | |
| 28-feedback | components § Profiles (feedback) | profile feedback |
| 29-file-drops | transfer.md § Host files (file drops as handles: `item/N/file`, `$ui/file/ID/`, release) | layer transfer |
| 30-tooltips | core § Node files, § Overlays (tooltips), components § Tooltips | profile overlay |

01 to 26 keep uitreefs's numbers and topics. Three changed shape:
13 was editor, markdown and dock, which are uitreefs extras the spec
doesn't define, so it is now the `layout` profile; 16 is now the whole
transfer layer; 27 to 30 are new. The extras' own behavior (editor
completions, the dock's JSON layout) isn't specified by 0.2, so this
suite doesn't test it beyond what 27 checks from their descriptors.

Not covered, because a headless client can't see it: what a window draws
while a batch is open, hover and focus styles, `drop-over:` styles,
pixels. Those are renderer tests. Not covered yet: two 9P connections
(batches are per connection), the shell, session and policy layers, host
file handles (`file/ID`), and the `web`, `desktop` profiles.

## Writing a script

[lib.rc](lib.rc) has the helpers. Use only h9's built-in root (no
`printf`, `head`, `dd`, `hoc`, `seq` or `kill`), read events in blocks,
quote every `=` in an rc argument, and keep here documents at the top
level.

- `w file words...` writes and prints `ok` or the core.md error phrase.
  `wq` prints only on failure. `wd` prints `phrase: detail` when the host
  gave detail, without the detail's text (it may grow). `wn file word
  words...` also prints `names word` when the detail names it.
- `val file` prints the bytes then `|`, so a golden shows the trailing
  newline. A one-line value reads back with one newline; empty reads as
  nothing.
- `need profile form` / `need layer transfer` skips the script if the host
  doesn't claim it.
- Events: open the file on fd 3 around a block, so the subscription exists
  before the events, then `evs` with the attributes of a sync event that
  reaches that file:

  ```rc
  {
  	inj event click 'win=main' 'node=a'
  	evs 'win=main'
  } <[3]$k/win/main/events
  ```

  `evs` injects `sync`, then prints every line before it through
  `evnorm`: `seq=` removed and the attributes after the three-word head
  sorted, because core.md lets them come in any order. So goldens show
  `change - cb value=off via=ctl win=main`. `evraw` keeps the host's
  lines, for answering requests (`seqof name` reads `seq=` back from
  `/tmp/ev`).
- Errors from an rc redirection (opening a file that isn't there) can't
  be caught in a script, so absence is checked with `exists`, and open
  errors with `rd`.
- Writes to text and data files apply at close, where `echo` and `cat`
  can't see the error. Scripts check those with the `error` event core.md
  § Errors requires, and by reading the file back.

## The host: what the suite needs from `uitree-headless` (W4)

- **Command line.** `uitree-headless CMD [ARG...]` starts an h9 machine
  with the current directory as the client's working directory, `$ui`
  mounted and set, runs `CMD ARG...` in it, and exits with the client's
  exit status (1 for any non-empty exit string), or 0 if the app quit
  first and the client then exited cleanly. The suite runs `rc ./NN.rc`.
- **No drawing.** Windows are never drawn. `inner` equals the window's
  `size`. The system appearance is `light` until `/debug/inject
  appearance` changes it. There is no app menu bar: `menu/bar` starts
  empty and no default menus are written.
- **What it claims.** `version` lists `layer core` and `layer
  components`, every profile whose types it has descriptors for, and
  `layer transfer` if it serves it. The suite skips what isn't claimed.
- **Standard error** carries the loud error lines of core.md § Errors,
  `uitree: write PATH: phrase: detail`, with PATH from `$ui`.
- **A fake clock.** Batch and request timeouts run on a clock only
  `tick` moves, so scripts never sleep.

### `/debug/inject`

The headless host's debug file. Each line written is one command in the
`ctl` syntax, applied when its line is complete (a write may end
mid-line; the rest arrives in the next write), so `cat file >$inject`
works for any size. Nothing written here appears in `trace`. A bad line
fails the write with the usual phrases.

| Line | Does |
| --- | --- |
| `event NAME [win=W] [node=PATH] [key=K] [attr=value ...]` | Send event NAME as if the user caused it. `dragstart` with `drag=N` first makes drag N from the node's `drag-types`, so the client can write its offer; `dragend` with `drag=N` drops it after. `node=` is window-relative (default `.` with `win=`, `-` without). The host fills the key from the tag (inherited from the nearest tagged ancestor) unless `key=` gives it, and fills `seq=`. It adds `via=user` to state events unless the line gives `via=`. If NAME is a request the client asked for (core.md § Requests, transfer.md), it is sent and waits for an answer like a real one, and its default applies on the same rules. A name the spec doesn't list (the suite uses `sync`) is an action event |
| `mirror [win=W] [node=PATH] file=NAME value=TEXT` | The component's own state changed this file, as when the user types: no event, no trace. With no `node=`, `file` is a window file (`focus`) |
| `bounds win=W node=PATH value='x y w h'` | The last layout put the node there |
| `frame [win=W]` | A frame was drawn, for one window or all. Until one is, a node's `type` stays writable |
| `tick SECONDS` | Advance the fake clock and run what falls due: batch timeouts, request defaults |
| `drag n=N type=TYPE data=TEXT` | Add representation TYPE, holding TEXT, to the offer at `$ui/drag/N/`, making it if needed, as a platform drag would before a `drop` names `drag=N` |
| `drag n=N type=file name=NAME data=BYTES` | Add a file item to drag N's offer, as a platform file drop would: a read-only file handle under `$ui/file/` holding BYTES (in memory), a `file name=NAME size=N` line in `data/file`, and its handle's name in `item/I/file` |
| `drag n=N type=file path=PATH` | The same for a host file or directory, PATH relative to the directory the host runs in (the suite uses `fixtures/drop`): the handle serves the host file's bytes, or for a directory its tree under `dir/` |
| `key win=W stroke=KEYS` | The user pressed KEYS in window W: the host resolves `keys` with the focused node's contexts and sends `action ID PATH via=key win=W`, or nothing if no binding applies |
| `menu item=ID` | The user chose the menu item with that ID: `action ID - via=menu`, or the item's role |
| `appearance mode=light\|dark` | The operating system's appearance changed |

## Proposed: formats the spec leaves open

These are what the goldens assume. Each is in [GAPS.md](GAPS.md) with
the reason, and the ones that need spec text are proposed in
`protocols/` in the same PR.

- **Read-back of one-line files.** Every file holding one line (props,
  `type`, `order`, `tag`, `style`, `on`, `focus`, `title`, `state`,
  `bounds`, `inner`, `theme/pref`, `theme/mode`) reads as the value and
  one newline; an empty value reads as nothing. A write drops one trailing
  newline, so `echo x >file` stores `x`. Multi-line text keeps inner
  newlines. Data files are lines, so they follow the same rule and read
  back as written. `clip` keeps its bytes exactly.
- **Here-values** are the lines between `prop=<<WORD` and `WORD` joined
  with newlines, with no trailing newline; `WORD` is at column 0 even in
  a document, where the value's lines are not indented either. A printed
  node with several here-values uses `END`, `END2`, `END3`... in order,
  and their bodies follow the line in that order.
- **Event attributes.** `via=` is on state events (`ctl` or `user`), on
  requests (`ctl`, `user`, `titlebar`, `menu`), and on `action` from keys
  and menus; not on other actions. A client verb that causes an event
  (`close` on a window, `click` on a button) sends it with `via=ctl`.
  Echoes go out for client writes to files a state event reports (`value`,
  a window's `state` and `focus`, `theme/pref` and `theme/mode` when the
  mode in effect changes); not for `open` and `close` on overlays.
- **The window state event** is `state - . value=V win=W` (a state event).
- **Error events.** `error - PATH code=CODE`, PATH the file written:
  window-relative with `win=`, or from `$ui` without it. CODE is the
  phrase with dashes (`not-found`).
- **`tree` printing.** `TYPE NAME`, then bare words (flags and boolean
  props that are on, variant and size words) in the order first set, then
  each other set prop as `prop=value` in the order first set, then `:
  style`, groups separated by two spaces. Props at their default are not
  printed; data files are, as here-values. A window's root is named
  `root`.
- **Variant and size words** are bare words (`new button b primary`), not
  style words; `primary` in a style is `unknown style word`.
- **Trace lines.** `ctl path=P cmd=C` per command line of an applied
  `ctl` write, `write path=P value=V` per applied file write, `mkdir path=P`,
  `remove path=P`, `batch timeout`, and `error path=P err=E` per failure.
  P is from `$ui`. A value with a newline, or over 64 bytes, is `len=N`.
  A secret value is `value=<secret>`, in a `write` and inside `cmd=`.
- **Error phrases for cases the table doesn't name.** An unknown prop or
  window prop is `not found`; a child the parent can't hold, and any
  overlay outside `over/`, is `unknown type`; `begin` inside a batch is
  `in use`; an answer to a request that doesn't exist (never made, or
  already answered or timed out) is `not found`; a readonly prop is `bad
  value`. An unnamed child of a `child none` type is `unknown type`.
