# uitree architecture and workstreams

This is the contract the parallel workstreams build against. The reasons
behind the split are in the scoping doc,
[Zig core + Rust renderer](https://claude.ai/artifact/9VdAkMLrAEzaWoWf56za5i).
If you need to change anything in this file, say so in your PR description
and tell the workstreams it affects.

## The boundary

- **The core (Zig, `core/`)** owns the tree, the line grammar, the type
  catalog, the 9P server, events and requests, trace, `/debug`, the CLI
  and h9. Everything a headless run needs to pass conformance is core.
- **A renderer** (`renderer/gpui` in Rust, `renderer/tui` in Zig) draws
  the committed tree and posts input. It never parses `ctl`, never
  produces a protocol error, and never decides whether a write is valid.
- **The core never sees a GPUI or terminal type.** Its only knowledge of a
  renderer is descriptor text: the types the renderer registers at
  `uit_create`.
- **Spec 0.2 is the target**, not uitreefs's current behavior. Where
  uitreefs and [protocols/](protocols/) differ, follow the spec and note
  it in the PR. Port tests, then code.
- **Apps run in h9.** The core calls hyper9's `h9.Machine` directly as a
  Zig dependency. No C shim, no Rust wrapper.

## Threads and ownership (the ABI rules)

1. **One owner thread.** Every `uit_*` call except `uit_wake_*` and
   `uit_shutdown` comes from the thread that called `uit_create`. The core
   asserts it in debug builds. Only that thread touches a `Tree`.
2. **The core wakes, the renderer pumps.** 9P threads push ops on a queue
   and call the renderer's `wake`. The renderer calls `uit_pump` on its
   main thread, which applies every queued op in order, publishes the
   snapshot 9P readers use, acks the writers, and returns `UitChanges`.
3. **Borrowed reads.** Strings and node handles the core returns are valid
   until the next `uit_pump` or `uit_destroy`. Inputs are copied.
4. **No callbacks during a pump** except `wake`. No re-entrancy.
5. **Errors** are negative `UitErr` codes plus `uit_last_error` (the
   protocol's text, `bad value: read-only`). Panics abort on both sides.

## Layout and who owns it

Each directory has one owning workstream. Touch another's directory only
through a PR it reviews, or a one-line change you call out in yours.
`core/build.zig` is shared: add your own module or step, don't restructure.

| Path | Owner | What |
| --- | --- | --- |
| `core/include/uitcore.h`, `core/src/abi.zig` | W0 spike, then W3 | The C ABI and its implementation |
| `core/src/proto/` | W2 proto | Tokenizer (in the scaffold), `ctl`, style syntax, event lines, errors, documents, data-line formats |
| `core/src/types/`, `core/types/` | W1 types | Descriptor parser, `Catalog`, every type's `spec`, `style-words`, `theme-tokens` |
| `core/src/tree/` | W3 tree | Nodes, handles, ops, batches, snapshots, bus, requests, trace, the op queue |
| `core/src/ninep/`, `core/src/headless/` | W4 serve | 9P server, transports, `/debug`, `uitree-headless`, CLI |
| `core/src/machine/` | W0 spike, then W4 | h9 lifecycle: start, mount `$ui`, exit status, hangup |
| `core/src/spike/` | W0 spike | Throwaway minimal tree; deleted when W3 lands |
| `renderer/gpui/` | W0 spike, then W6 | The GPUI host (Rust) |
| `renderer/gpui/tools/style-gen/` | W1 types | Generator for the style dispatch table and `style-words` |
| `renderer/tui/` | W7 tui | The terminal host (Zig, libvaxis + Yoga) |
| `tests/conformance/` | W5 conformance | The 0.2 suite and its runner |
| `.github/workflows/uitree-*.yml` | W8 integration | CI |

## Interfaces between workstreams

Each is owned by the workstream named first. Land the interface (types
and signatures, with stubs) in your first PR so consumers can build
against it, then fill it in.

**I1. `uitcore.h` v1 (W0 → W3, W6, W7).** The full header from the
scoping doc's sketch: lifecycle, pump, tree reads, input, host commands.
The spike implements what the counter needs and makes the rest return
`UIT_ENOTSUP`. Once frozen, a change bumps `UIT_ABI_VERSION` and is
announced to W3, W6 and W7.

**I2. `proto` (W2 → W1, W3, W4).** Parsers take an arena and a line and
return plain structs, with no global state. Each fallible parser also has
a `parseDiag(..., ?*proto.Diag)` form that reports the error's code and
detail; errors are `proto.Error` (one Zig error per code, plus
`OutOfMemory`), mapped back with `proto.Code.fromError`.

- `proto.tokenize` (done): `tokenize(arena, line) ![]Tok`, `quote(w, s)`,
  `quoteWord`, `quoteValue`.
- `proto.ctl.parse(arena, line) !Ctl` for one line, `parseWrite(arena,
  bytes) ![]Ctl` for a whole write (all or nothing, here-values,
  `prop=<<END`). `Ctl{verb, words, attrs, style}`: positional words,
  attributes, the words after a lone `:`; `Ctl.kind()` is a `Verb`,
  `Ctl.bare()` the bare words of `set`/`new`/`delete`/`tree`/`window`.
  Covers the node commands and the app `ctl` verbs. Validation against
  types is not here.
- `proto.style.parse(arena, text) ![]StyleWord`: name, optional state
  prefix (`hover:`), arguments. Unvalidated.
- `proto.event`: `Event{ name, key, path, attrs, seq }`, `format(w, ev)`,
  `parse`.
- `proto.err`: `Code` (the 0.2 codes, `phrase()` and dashed `name()`),
  `format(w, code, detail)`, `Diag`, `limits`.
- `proto.doc`: `.ui` documents to a `Node` tree, `print`, and
  `toCtls(arena, node, path)` for the list of `new` commands.
- `proto.lines`: the data-file formats of components.md (`Item`,
  `Column`, `Row`, `TreeItem`, `DescItem`, `IconItem`, `MenuLine`,
  `KeyBinding`, `CanvasOp`) and uitreefs's extras, with `parseLines`.

**I3. `types.Catalog` (W1 → W3, W4, W6, W7).**
`Catalog.parse(gpa, descriptor_text) !Catalog`; `lookup(name) ?*const Type`;
`Type` exposes props (form, default, file, readonly), words (flag, variant,
size), verbs (args, class), events (kind, attrs), slots, child rule, data
files (format). `Catalog.checkProp(type, name, value) !void` and
`checkStyle(words) !void` return `proto.err` codes. `Catalog.specText(name)`
gives the text `$ui/types/NAME/spec` serves. Style words and theme tokens
are separate tables parsed from `core/types/style-words` and
`theme-tokens`. Named themes are a third, `core/types/themes`, loaded by
`Catalog.loadThemes` when a renderer registers them (`uit_themes`).

**I4. `tree` (W3 → W4, abi).**
- `Tree.init(gpa, *const Catalog)`; `apply(op) !Changes` on the owner
  thread, all or nothing.
- `OpQueue`: `push(op, *Ack)` from any thread, `drain(tree)` on the owner.
  `Ack` is waited on by the 9P writer and carries the error, if any.
- `Snapshot`: immutable, reference counted, published after each drain;
  9P reads of state files come only from a snapshot.
- `Bus`: `subscribe(path, filter) *Stream`; `Stream.read(buf)` blocks on a
  condition variable until an event, `resync` or hangup.
- `Requests`: post, answer, default answer on timeout or close.
- Node handles are `u32`, never reused, `0` is none.

**I5. Conformance (W5 → everyone).** `tests/conformance/run [-u] [NAME...]`
against `$UITREE_HEADLESS` (default `../../core/zig-out/bin/uitree-headless`).
A workstream's PR says which scripts it makes pass.

**I6. Types ↔ renderers (W1 ↔ W6, W7).** A renderer passes, in
`UitConfig.types`, the descriptors of the types it draws, copied from
`core/types/`. `uit_create` fails if it registers a type the core doesn't
have; the renderer fails at startup if the core sends a type it doesn't
draw.

**I7. Style words (W1 → W2, W6).** `style-gen` reads GPUI and writes
`core/types/style-words` (`name argkind`, dashed) and the renderer's
dispatch table from the same list, so the two cannot drift. It also
writes `theme-tokens` and `themes`: every theme in GPUI Kit's set,
resolved as GPUI Kit applies it, as a renderer-neutral palette (the
tokens that differ from the mode's default).

**I8. Named themes (W1 → W6, W7).** A renderer registers the palettes it
draws with `uit_themes` after `uit_create` and before serving. The core
owns the selection: `theme/name` takes the registered names and family
names, `theme/names` lists them, and `uit_token` (so `uit_style`'s colors
and `theme/tokens`) resolves through the selected palette. A renderer
needs no theme logic of its own: on `UIT_CMD_THEME` it re-reads the mode
and tokens. Both renderers register all of `core/types/themes`. The
look tokens (`radius`, `radius-lg`, `font-size`, `font-family`,
`spacing`, `shadow`) are `types.style.value_tokens`; renderers read
them as text with `uit_token_text` (ABI 5) and map them to their own
units.

## Working on a workstream

- Branch from `uitree`, open PRs into `uitree`. Keep them small and land
  often; rebase on `uitree` before each PR.
- `zig build test` in `core/` must pass on every PR (CI runs it).
- If you are blocked on another workstream's interface, stub it in your
  own directory behind the agreed signature and say so in the PR.
