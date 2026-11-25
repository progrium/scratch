# Gaps: where draft 0.2 doesn't pin what the goldens need

Each item says what the spec leaves open, what the goldens assume, which
scripts depend on it, and who decides. Items marked **(spec PR)** have
proposed text in `uitree/protocols/` in the same PR as this file; the rest
are host behavior the spec can leave alone, or are listed under that
layer's Open questions. Carried-over items from uitreefs's GAPS.md that
0.2 settled are listed at the end.

## Text on the wire

1. **Trailing newlines on read-back. (spec PR)** core.md § Node files
   says a one-line text value reads back "followed by one newline", but
   not whether a write drops one (so `echo x >text` stores `x` or `x\n`),
   what an empty value reads as, or whether computed files (`type`,
   `order`, `style`, `focus`, `state`, `bounds`, ...) follow the same
   rule. *Assumed:* one rule for every one-line file: a write drops one
   trailing newline, a read adds one, empty reads as nothing; data files
   are lines and follow the same rule; `clip` keeps its bytes. 02 to 28 all depend on it, through `val`.
2. **Here-value bodies. (spec PR)** Raised by W2 too. Whether the value
   ends in a newline, and in a document whether the body and the closing
   word are indented. "a line holding only `WORD`" suggests `WORD` at
   column 0. *Assumed:* lines joined with newlines, no trailing newline;
   body and `WORD` unindented. Also open: a node with several here-values
   on one printed line. *Assumed:* `columns=<<END  rows=<<END2`, bodies in
   order. 04, 16, 21, examples/csvview.
3. **Tree printing. (spec PR)** § Documents shows the format but not the
   order of words and props, the separator (the examples use two spaces),
   whether defaults, data files and booleans print, or the root's name.
   *Assumed:* README.md § Proposed. 03, 08 to 11, 13, 21, 28.
4. **Variant words: bare or style? (spec PR)** components.md makes
   `primary` a bare `word ... kind=variant`, and core.md § Commands uses
   it bare (`new button inc label=+1 primary`), but core.md § Documents
   puts it in the style (`: primary w-full`), and the error table says
   `unknown style word` covers a word "not valid on this type".
   *Assumed:* bare words only; the spec PR moves `primary` out of the
   style in the Documents example. 09, 21.
5. **`on=` with several events.** The `on` file is blank-separated words
   (like `order`), but core.md's list form for an attribute is `a,b`. Is
   `on=click,hover` the way to set two at creation? The goldens only set
   one with `on=`. Owner: W2, W3.
6. **A quoted `prop=value`.** uitreefs made `'text=x y'` a bare word (so
   `bad value`); Plan 9 tokenize, which the spec names, drops the quotes,
   so it is a prop. *Assumed:* the spec, a prop. 04. Owner: W2.
7. **Attribute order in events.** The spec says any order with `seq=`
   last, so the suite sorts attributes before comparing (`evnorm`) and
   checks only that `seq=` is last (14).

## Events

8. **`via=` on user-made state events. (spec PR)** § Events lists
   `via=user` and says client writes carry `via=ctl`, but its `change`
   example has no `via=`. *Assumed:* state events always carry `via=`
   (`user` or `ctl`, or `system` for the theme); the spec PR adds
   `via=user` to the example. 05, 09, 10, 12 to 14, 19, 22.
9. **Echoes for verbs.** "Events caused by the client's own writes carry
   `via=ctl`" doesn't say which verbs cause events. *Assumed:* `close` on
   a window and `click` on a button send their event with `via=ctl`;
   `open` and `close` on an overlay send nothing. 09, 15. Owner: W3.
10. **The window state event.** A window's `state` changes, but no event
    name or attribute is given for it. *Assumed:* `state - . value=V
    win=W`, a state event. 05. **(spec PR)**
11. **Error event paths.** core.md's example `error - x/text win=main` is
    window-relative, as the path rule says; uitreefs sent
    `win/main/ctl`. *Assumed:* the rule: `ctl` with `win=main` for the
    window's ctl, `theme/tokens` with no `win=` for app files. 05, 07, 12,
    14, 18, 22, 23. Also open: whether the error reaches a node's own
    `events` (the suite reads window and app files only).
12. **`resync seq=N`.** The last seq before the subscription, or the
    next? The goldens strip it.
13. **Canvas pointer attributes.** Canvas hits are in node space, but
    the attribute names aren't given (`pt=` is window space). *Assumed:*
    uitreefs's `item= x= y= button=`. 22. Owner: W1.
14. **Clipboard generation.** `clipdata/types` holds "the types ... and
    its generation" with no format. The suite ignores any line starting
    `gen`. 16. Owner: transfer.md.

## Behavior

15. **`window main` twice.** "`in use` if the name is taken, except the
    hidden default `main`": the goldens assume the first `window main`
    claims it and a second is `in use`. 01, 05.
16. **The first line of `version`.** The example says `uitree 1.0`
    while the spec is draft 0.2. *Assumed:* `uitree 1.0`, the version of
    the protocol the layers make up. 01.
17. **The headless system appearance.** Headless has no OS, so `system`
    must resolve to something. *Assumed:* `light`, until `/debug/inject
    appearance`. 07. Owner: W4.
18. **Menus on a headless host.** Which kind of host is it? *Assumed:*
    one with no app menu bar: `menu/bar` empty, no default menus. 18.
19. **What a refused write at close leaves.** A data file write that
    fails at close: the old content stays (the goldens check that), but
    a menu file that didn't exist was already created by the open. The
    suite doesn't check whether it exists. 12, 18.
20. **`set ID` for an unknown action.** Is an action "known" only if a
    binding, menu item or button names it? *Assumed:* yes, otherwise `not
    found`. 18.
21. **Answering requests.** "On the node's or app's `ctl`": a window's
    `close` on the window `ctl`, `quit` on the app `ctl`, a drop on the
    target node's `ctl`. An answer to a request that never existed, was
    answered, or timed out is `not found`. How a dialog opts in ("dialog
    `ask`") isn't spelled out, so the suite doesn't test dialog requests.
    15, 16.
22. **What survives a document rewrite.** Children whose name and type
    match are kept, "so focus, scroll and editor state survive", but are
    props the new document doesn't mention reset or kept? The suite
    checks only an input's `value` and the window's `focus`. 21.
23. **The `trace` history.** "Recent history first": how much? 25 reads
    between two marker writes and assumes the history reaches back to the
    first marker. **(spec PR)** proposes "at least the last 1,000 lines".
24. **Trace line format.** Only `error path= err=`, `value=<secret>` and
    `batch timeout` are given. *Assumed:* README.md § Proposed. 25.
    **(spec PR)**
25. **Batch timeout with no window.** Batches are per connection now, so
    `batch timeout` has no `win=`. 25.
26. **Phrases for cases the table doesn't name.** Unknown props,
    children a parent can't hold, `begin` twice, unknown answers,
    readonly props, wrong slot names: README.md § Proposed. 02, 05, 08 to
    13, 15, 20, 27.
27. **Variant replacement in print order.** A variant word replacing
    another takes its place among the bare words. 09.
28. **Prop names the spec doesn't give.** Most types' props (`labels`,
    `searchable`, `variant` on `alert-dialog`, `cols` on `grid`, `count`
    on `badge`, ...) come from uitreefs's catalog renamed, which is what W1
    is porting. W1's descriptors are the authority: where they differ,
    fix the golden. 09 to 13, 22, 28.

29a. **Ranges in descriptors.** Settled by W1 (PR 6): `prop NAME number
    min=N max=N`, in components.md's prop line; `progress` value is 0 to
    100. 27 checks max+1 and min-1 are refused; 28 checks 140.
29b. **Toolbar slots.** uitreefs's `toolbar` takes any child (its slotted
    one is `status-bar`, a host extra), so 10 tests no slot names, and 27
    checks slots from whatever descriptors say.

## Transfer

29c. **Item numbers.** transfer.md names `item/N/file` without saying
    where N starts. *Assumed:* 0, in `data/file` order. 29.
29d. **A refused drop's handles.** A handle "lives until the client writes
    `release` ... or the app quits", but a client that refuses a drop never
    learns its handles. *Assumed:* a refused drop (answered or by timeout)
    releases the handles it made; an accepted one leaves them to the
    client. **(spec PR)** 29.
29e. **`via=` on a drop.** Requests carry `via=user` like other user
    events (15), so the drop golden in 16 does too.
29f. **Handle `events`.** Only `gone - file/ID`, sent once a read finds the
    host file gone, then end of file at release. `change` needs a platform
    file watcher, which no host has yet.

## Terminals

29g. **Stream mode has no tty**, so nothing turns `\n` into `\r\n`: a
    bare LF moves down a row and keeps the column, as on any terminal.
    31 writes CR LF with awk's `printf`.
29h. **Bells.** One `bell` event per pump however many BELs the program
    sent in it, so a program ringing in a loop can't flood `events`.
29i. **`write TEXT` and `paste TEXT`.** TEXT is the verb's words joined
    by blanks, or `text=` (a here-value for newlines). 31.
29j. **Which terminal gets a key on a headless host.** Headless has no
    focus of its own, so `/debug/inject`'s `key` takes `node=PATH`, the
    focused node, as uit_key's `focused` does. 31.
29k. **`title`, `cwd` and the `title` event** come from OSC 0, 2 and 7,
    which the `plain` engine skips; 31 leaves them to the libghostty-vt
    build. `resize` needs a renderer's layout (uit_term_resize), which
    headless has none of.
29l. **Terminal input (33).** Pointer input has no file of its own: the
    suite drives it with render.md's `term-*` lines on `/debug/inject`.
    The copy keystroke is `ctrl-shift-c` (and `cmd-c` on hosts whose
    command key is super); `ctrl-c` stays the program's. Focus reports
    follow the window's `focus` file, since headless has no window focus
    of its own. OSC 52 takes `c` and `s` and drops `p` (no primary
    selection), and its trace line is `osc52 path=P len=N`.

## Against hyper9 and h9

29. **The 9front kernel rewrites failed walks** to `file does not
    exist`, so `lib.rc` reads that as `not found` (uitreefs GAPS 21).
30. **h9's built-in root** has 42 commands and no `dd`, `head`, `kill`
    or `printf` (uitreefs GAPS 31), so 24 builds large writes with awk.
31. **No h9 sandbox flags yet.** uitreefs passed h9's policy flags
    (`--profile`, `--net`, `--net-allow`, `--memory`, `--writable`,
    `--timeout`, ...) through to the machine. uitree's ABI has
    `UitMachineArgs.h9_flags` for them, but `core/src/machine/root.zig`
    refuses any (`error.FlagsNotInSpike`) and no CLI takes them, so every
    app runs under h9's default policy. uitreefs's flag list and its
    mapping are in its last version's
    [crates/h9sys](https://github.com/progrium/scratch/tree/562f8b757a3558900b14f21c515f878af0167ada/uitreefs/crates/h9sys)
    and [cli.rs](https://github.com/progrium/scratch/blob/562f8b757a3558900b14f21c515f878af0167ada/uitreefs/crates/uitreefs/src/cli.rs).
    Owner: core.

## Settled by 0.2 (uitreefs GAPS.md items now closed)

- Event head and attribute order (uitreefs 5): `name key path`, then any
  order, `seq=` last.
- `tag=''` (7): gone; the key is `-`.
- `id` file (16): gone from 0.2's node files.
- Reading `trace` (3): a stream with recent history first.
- `over/ctl` (22): core.md § Overlays names it.
- Request answers (26): `close keep accept refuse` with `seq=`.
- Short read (24-limits): any read size works, and the phrase is gone.
- `begin`/`commit`/`abort` moved from the window `ctl` to the app `ctl`.
