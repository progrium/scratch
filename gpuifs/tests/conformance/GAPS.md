# Gaps and contradictions found while writing the suite

**Decided by W2 (fc024b5):** items 3 (a `trace` read returns the whole log,
the last 1 MiB, not a stream), 5 to 8, 14, 16, 17 and 18 follow this suite's
proposals. Echoes go out for client writes to `value` on types with a
`change` event (with `value=` unless it's text, bytes or secret), a window's
`state` and `focus`; none for verbs or for props set by `new` or a `tree`
document. A child in a named-slot position with a wrong name is
`bad value`, not `unknown type`.

**Decided by W3 (b9b16c7):** `/debug/inject` is as README.md proposes, plus
an optional `default=VERB` on request events; the tree also ticks in real
time every 16 ms. `/debug/log` reads back one line per host command. Item 1:
short files and Word/Bool/Number/Enum props apply per write; text and data
buffer to clunk. Item 2: a `ctl` write that fills an 8 KiB piece and doesn't
end in a newline keeps its partial last line until the next write or clunk,
so `cat cmds >ctl` works. Item 21: a failed walk answers `not found: NAME`;
what the 9front kernel passes on is still to check in h9.

W8's report (PLAN.md § W8, third bullet). Each item says where DESIGN.md or
PLAN.md is silent or inconsistent, what the suite's goldens assume for now
(details in [README.md](README.md) § Proposed), and who decides. The first
four change what clients can do, so they matter most.

## Behavior clients depend on

1. **Errors at clunk are invisible.** PLAN.md § Design questions 1 applies
   text and data files at clunk and fails the clunk on error. But `echo`,
   `cat` and rc all ignore errors from `close`, so `cat bad.ui >tree` or a
   malformed `items` file fails silently; only the trace and a read-back
   show it. *Assumed:* short files (`style`, `order`, `tag`, `on`, `type`,
   theme files, single-word props) apply per write, so their errors reach
   `echo`; only bulk text and data buffer. *Suggest:* fix that per-file list
   in PLAN.md, and give failed clunks a visible trail, such as an `error`
   event on the node's and window's `events` with the phrase, or a
   per-node `error` file. Owners: W2, W3.
2. **Multi-line `ctl` writes over 8 KiB from `cat`.** `cat cmds >ctl` is the
   natural rc idiom, but `cat` writes in 8 KiB pieces and `ctl` applies each
   write on arrival, so a long command file is split mid-line and the second
   piece is `bad syntax`. Only `echo` makes one big write, and h9's root has
   no `dd`. *Suggest:* a `ctl` write that doesn't end in a newline holds its
   last partial line until the next write or clunk, or document "use
   `begin`/`commit` and one command per line". Owners: W3, DESIGN.
3. **Reading `trace`.** DESIGN calls it "read-only, like `#τ/tkevents`",
   which is a blocking stream, so `cat trace` never ends. Is a read the
   whole log so far, or a stream from open, like `events`? The suite reads
   the headless trace from standard error instead. Owner: W2.
4. **Exit status after the app quits.** § Running a client in h9 step 4
   takes the exit code from the client's exit string; step 5 tears the
   machine down 2 seconds after `quit`. If the client exits within those 2
   seconds, does its status still decide gpuifs's? *Assumed:* yes
   (26-lifecycle expects `exit=1` from `exit failed`). Owner: W4.

## Formats DESIGN shows but doesn't pin

5. **Event attribute order.** The examples disagree: `click win=main
   node=... tag=save`, but `action id=save win=main focus=...`. *Assumed:*
   `name win= node= tag= <attrs> via= seq=`, as most examples show.
6. **`via=`.** § Events says changes carry `via=ctl` or `via=user`, but the
   example shows `close win=main via=titlebar` and its `click` has no
   `via`. *Assumed:* `via=` on state events (`ctl`|`user`) and on
   `close`/`quit` requests (`ctl`, `user`, `titlebar`, `menu`); none on other
   actions.
7. **`tag=''`.** The `change` example prints `tag=''` for an untagged node.
   *Assumed:* every event with `node=` carries `tag=`, empty or not.
8. **Echoes.** Which client writes send a `via=ctl` event? *Assumed:* a
   write to a file a state event reports (`value`, a window's `state`,
   `focus`); no echo for verbs such as an overlay's `open` and `close`.
9. **`resync seq=N`.** Is N the last seq before the subscription, or the
   next one? The goldens strip it.
10. **Coalescing for window and app events.** "Same name about the same
    node" doesn't cover window-level state events (`state`). *Assumed:* the
    window is the subject, so three `state` changes queued are one.
11. **`state` event attribute.** Unnamed. *Assumed:* `state win=main
    value=maximized`.
12. **`tree` printing.** The sign-in example puts `style` before `text` on
    one line and `label` before `style` on another, so there is no fixed
    prop order. *Assumed:* the order props were first set, two spaces before
    each, defaults omitted. Also open: whether data files (`items`, `rows`,
    `columns`) and input `value`s are printed (a saved screen would hold a
    `flags=secret` value); how several `<<END` blocks on one node are laid
    out; whether block lines are indented; what happens to a child that
    `order` doesn't list. Owner: W1 with W2.
13. **Completions answer format.** "Write `items` lines to the editor's
    `completions` file, tagged with the request's `seq=`": a first line
    `seq=N`, a `seq=` column, or a `ctl` verb? 13-editing-layout writes
    `seq=N` as a first line but checks nothing. Owner: W6d.
14. **Trace line format.** DESIGN gives only `value=<secret>` and `batch
    timeout`. The suite proposes event-style lines (README.md); 25-trace is
    the golden for it. Owner: W2.
15. **Trailing newlines on computed files** (`type`, `order`, `id`,
    `bounds`, `state`, `focus`). PLAN.md § Design questions 11 covers text
    files only. *Assumed:* no trailing newline. Also the clipboard: the
    suite keeps its bytes as written.
16. **`id`.** "The node's path": window-relative, like event `node=`, or from
    the root? *Assumed:* window-relative (`root/card`).

## Error phrases the table doesn't name

17. An unknown prop on `new` or the `window` verb (`colour=red`).
    *Assumed:* `not found`.
18. A child type a component doesn't take (a `text` in a `sidebar`, a
    `div` in `tabs`, a dialog in the node tree, a `div` in `overlays/`).
    *Assumed:* `unknown type`, though the type exists. A new phrase
    (`bad child`) might be clearer.
19. `begin` inside an open batch. *Assumed:* `in use`.
20. Writes to read-only files (`id`, `bounds`, `trace`). These fail at
    open, with a permission error from 9P, not one of the phrases. The
    suite doesn't test them.
21. *(Confirmed in h9: the 9front kernel turns a failed walk into
    `file does not exist: '...'`, so lib.rc reads that as `not found`, and
    rc's own open error can't be redirected; see lib.rc `_write`.)*
    Errors on open go through the kernel. A walk that fails may reach the
    client as `'/mnt/gpui/x' file does not exist`, not `not found`, when the
    9front kernel rewrites the error. Worth checking in h9 (W3, W4).

## Structure

22. **`overlays/ctl`.** § Overlays writes `new` to `overlays/ctl`, but the
    tree diagram lists `overlays/` with nothing in it. W2 makes `overlays/`
    a node-like directory (`bounds ctl events id order tree type`).
23. **mkdir and `order`.** Does `mkdir` append the new node to its parent's
    `order`, as `new` does? Otherwise a mkdir'd node is never drawn.
    *Assumed:* it appends.
24. **What `ls` shows on a node.** Every prop file the type has, set or not,
    or only those set? The suite tests files with `test -e` and doesn't
    golden a node listing.
25. **Node depth 64.** Counted from where? *Assumed:* the window's root is
    depth 0, so 64 `n` levels fit and the 65th is `too large`.
26. **Answering requests.** "On the node's `ctl`" needs spelling out for
    requests with no node: a window `close` is answered on the window's
    `ctl`, and `quit` on the root `ctl`. PLAN.md § Design questions 2 covers
    windows; the same `seq=` rule should cover overlay, tab and dock-panel
    `close`, which also have a client-side `close` verb.
27. **`alert-dialog` events.** It lists `confirm` and `cancel` only, so no
    `open`/`close`. Fine, but it means its Esc key and overlay click send
    `cancel`, which DESIGN should say.
28. **Canvas `raise`/`lower`.** To the top and bottom, or one step? The
    suite assumes top and bottom.
29. **`/drags/<n>` for `dragstart`.** Who makes the directory the client
    writes `data` into, and when? The suite assumes the host makes it
    before sending `dragstart`.

## Against hyper9 as it is today

30. **`--root` is gone from h9.** hyper9 `spec/cli.md` makes `--root` and
    `--root-*` exit 2, replaced by mount flags (`--builtin[=MODE]`, `--dir`,
    `$H9ROOT`). DESIGN's `gpuifs --root builtin|DIR` and `H9Config.root` can
    keep their meaning, but the CLI text and the flags passed through should
    match h9's current names. Owner: W4.
31. **42 commands, not 44.** h9's built-in root
    (`design/epoch-0/builtin-root.md`, `src/9box/slim`) has 42 commands:
    `rc echo cat ls cp mv rm mkdir pwd test date sleep touch chmod du
    basename read walk wc sort uniq tr sed awk grep cmp diff tail tee xargs
    mc tar gzip gunzip unzip bind mount unmount ns ps srv srvfs exportfs
    ramfs`. No `dd`, `head` or `kill` either. PLAN.md § Design questions 9
    and examples/README.md say 44.

## Fixed in the examples

32. `rc/gallery/chart/tree` used `grid_cols_2` (now `grid_cols=2`) and
    `rc/calc.rc` used `text_4xl` (now `text_3xl`, gpui's largest), found by
    W5a's style table. Removed a stray `examples/python/__pycache__/`.
33. **`radius` in `theme/tokens`.** DESIGN's tokens example has `radius 6`,
    but `radius` is a `Theme` field, not a `ThemeColor` one. 07-theme
    assumes `tokens` carries it anyway. Owner: W5a.
