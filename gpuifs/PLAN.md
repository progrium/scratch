# gpuifs implementation plan

Nov 21, 2026 · Draft v0.1 · implements [DESIGN.md](DESIGN.md) (gpuifs: GPUI Kit as files, v0.1)

This plan splits gpuifs into workstreams that separate threads can build at the
same time. Each workstream owns a set of directories, codes against the
interfaces in [§ Contracts](#contracts), and has its own acceptance test. The
[examples](examples/) double as the end-to-end acceptance suite.

## Shape of the code

gpuifs is a Cargo workspace in this directory. Everything that does not need
GPUI is a plain Rust crate that builds and tests on any machine with no display.
Only `host` links GPUI.

```text
gpuifs/
    DESIGN.md  PLAN.md
    Cargo.toml                 workspace, pinned gpui + gpui-component revs     (W0)
    crates/
        proto/                 quoting, ctl, style syntax, line formats, tree docs,
                               event lines, error phrases          (pure)        W1
        style/                 the style word table and theme token names (pure) W5a
        tree/                  nodes, type registry, ops, snapshot, batches,
                               event bus, requests                  (pure)       W2
        catalog/               a TypeSpec for every element and component (pure) W6a-d, W7
            src/{elements,forms,nav,overlays,data,edit,layout,canvas}.rs
        ninep/                 9P2000 server over an FsBackend, plus the headless
                               backend and `gpuifs-headless` binary (pure)        W3
        h9sys/                 Zig C-ABI shim, build.rs, safe Rust wrapper        W4
        host/                  GPUI: app, windows, root view, materialize,
                               style application, theme, actions, menus           W5b
            src/components/{forms,nav,overlays,data,edit,layout}/                 W6a-d
            src/canvas/  src/dnd/  src/clipboard.rs                               W7
        gpuifs/                the `gpuifs` binary: CLI, lifecycle wiring         W4 + W5b
    tests/conformance/         rc scripts + golden traces against headless       W8
    examples/                  client programs in rc, Go, C, awk, Python, sh      W8
```

The split follows the design's own seams. The tree is the whole truth (§ Goals
5), so the tree, its type rules and its event queues are pure data structures
that run without GPUI. The 9P server only ever sees an `FsBackend`. GPUI sees
only the tree on the main thread. That gives three things for free:

1. **A headless gpuifs** (`ninep` + `tree` with no renderer) that runs every
   client and every conformance test in CI with no GPU.
2. **Catalog work that starts before rendering exists.** A component's files,
   props, verbs and events are a `TypeSpec` in `catalog`, so the tree validates
   writes to it and examples can run against it headless.
3. **Render threads that never touch protocol code.** A component thread writes
   one `TypeSpec` and one `Component` impl.

## Workstreams

| ID | Workstream | Owns | Depends on | Size |
| --- | --- | --- | --- | --- |
| W0 | Skeleton and contracts | `Cargo.toml`, every crate's `lib.rs` signatures, CI | — | S, first |
| W1 | Protocol text formats | `crates/proto` | W0 | M |
| W2 | Tree, registry, events | `crates/tree` | W0 (W1 types via stubs) | L |
| W3 | 9P server and headless | `crates/ninep` | W0 (W2 via `FsBackend`) | M |
| W4 | h9 embedding and CLI | `crates/h9sys`, `crates/gpuifs` (CLI, lifecycle) | W0 | M |
| W5a | Style table and theme data | `crates/style` | W0 | M |
| W5b | GPUI host core | `crates/host` (minus component, canvas, dnd dirs) | W0; W2, W5a APIs | L |
| W6a | Forms | `catalog/forms.rs`, `host/components/forms/` | W5b core render | M |
| W6b | Navigation and overlays | `catalog/{nav,overlays}.rs`, `host/components/{nav,overlays}/` | W5b | L |
| W6c | Data display | `catalog/data.rs`, `host/components/data/` | W5b | L |
| W6d | Editing, rich text, layout, dock | `catalog/{edit,layout}.rs`, `host/components/{edit,layout}/` | W5b | L |
| W7 | Canvas, drag and drop, clipboard | `catalog/canvas.rs`, `host/{canvas,dnd}/`, `host/clipboard.rs` | W5b | M |
| W8 | Conformance suite and examples | `tests/conformance`, `examples/` | W3 + W4 for runs; nothing to start | M, runs all along |

### Phases

```text
Phase 0   W0 ──────────────┐   (hours: signatures compile, CI green, nothing works)
                            │
Phase 1   W1  W2  W3  W4  W5a  W5b  W8      (all in parallel, against W0 stubs)
             └──┬──┘  │          │
          M1 headless ┘          │          W2+W3+W4: rc clients run, no window
                                 │
          M2 first window ───────┘          W5b+W5a: element tier on screen
                                 │
Phase 2   W6a  W6b  W6c  W6d  W7            (all in parallel, one per component group)
          M3 catalog, M4 canvas/dock
```

W6 and W7 can start their `catalog` half (TypeSpecs, headless tests) in phase
1; only their `host` half waits for M2.

### Milestones

| Milestone | Proves | Examples that must pass |
| --- | --- | --- |
| **M1 headless** | Protocol, tree, events, 9P, h9 launch. `gpuifs --headless rc x.rc` runs with `trace` on stderr | every example's tree-building phase (headless asserts `cat tree` output) |
| **M2 first window** | Element tier, style words, theme, windows, `on` events, batches, `tree` docs, keymap, menus | `counter.rc`, `signin.rc` (input/button can be stand-in divs), `confirm.rc` |
| **M3 catalog** | All of DESIGN § Component catalog except the M4 rows | `hello.rc`, `greet.go`, `todo.rc`, `calc.rc`, `settings.rc`, `gallery.rc`, `notes.rc`, `chat.rc`, `files.rc`, `stocks.rc`, `csvview.awk`, `hn.py`, `progress.sh` |
| **M4 full** | Canvas, drag and drop, dock | `paint.rc`, `clock.go`, `life.c`, `dock.rc`, `files.rc` drop |

---

### W0 · Skeleton and contracts

Make the workspace and every crate with the public types and trait signatures
in [§ Contracts](#contracts), bodies `todo!()`. Pin `gpui` and
`gpui-component` to one git rev each and record them in `Cargo.toml`. Add CI:
`cargo test` for the pure crates on Linux, `cargo check -p host` on macOS and
Linux. Create `host/src/components/mod.rs` with one `register` call per group,
already wired, so W6 threads never edit a shared file.

**Done when** `cargo check --workspace` passes and each later workstream can
start without editing a crate it doesn't own. Changes to `lib.rs` contracts
after W0 go through the [contract change rule](#working-rules).

### W1 · Protocol text formats (`proto`)

Every text format in the design, parsed and printed, with no knowledge of the
tree:

- Plan 9 `tokenize`/`quote` (DESIGN § Quoting), including `''`.
- `ctl` writes: one `Command` per line, `prop=value` pairs split from
  positional args. A write's lines parse all-or-nothing.
- Style syntax (DESIGN § Style language): `name`, `name=n`, `n%`, `nrem`,
  `#rrggbb[aa]`, tokens, `a,b`, state prefixes, `group:` and
  `group-hover(name):`. Syntax only; whether a word exists is W5a's table.
- Line formats: items (`id<TAB>label[<TAB>icon=..][<TAB>disabled]`, `# ` groups,
  `-`), columns, TSV rows, tree items, description-list items, radio items,
  diagnostics, menus (`item`/`sep`/`sub`), keymap, canvas ops, message-list
  items, completions.
- Subtree documents (DESIGN § Atomic updates): parse and print, two-space
  indent, `text=<<END` blocks. `print(parse(x)) == x` for canonical input.
- Event lines: `Event::to_line(seq)` with values quoted only when needed.
- `ErrorKind` with the exact phrases of DESIGN § Errors and limits.

**Done when** property tests round-trip every format and the doc's own
snippets (the sign-in tree, the canvas ops, the menu, the keymap) parse.

### W2 · Tree, registry, events (`tree`)

The model the whole system shares.

- `Node` storage keyed by path. Names, `order`, `type` fixed after first
  frame (the host tells the tree when a frame was drawn), `tag`, `on`,
  `context`, `tooltip`, `drop`, `drag-type`, and each type's prop files.
- `Registry` of `TypeSpec`s (filled by `catalog`), used to validate every
  write: unknown type, unknown prop, bad value, unknown verb, which children
  are slots.
- `Tree::apply(session, Op)` for every op in DESIGN: `mkdir`, `rm -r`,
  node `ctl` (`new`, `delete`, component verbs), root `ctl` (`window`, `set`,
  `theme`, `quit`, `begin`/`commit`/`abort`), file writes, `tree` documents
  with keep-by-name-and-type diffing. Returns `Changes` and `HostCmd`s for
  the host to act on. Never half-applies.
- Snapshots: an immutable `Arc<Snapshot>` after each batch of ops. Serves
  `stat`, `readdir`, `read` for every file, including computed ones (`id`,
  `ctl` listing verbs, `tree`, `bounds` the host reported, `version`).
- Batches per session with the 2 s timeout, and a committed view per window
  for the renderer (the frozen tree while a batch is open).
- `EventBus`: subscriptions per app, window and node; `resync seq=N`;
  state-event coalescing (same name, same node, moves to back); action queue
  cap 4,096 then `lost n=N`; `gone` then EOF; tags copied in; `via=ctl` vs
  `via=user`.
- `Requests`: open, answer by `seq=` on the node's `ctl`, default after 5 s or
  immediately when no `events` file is open.
- `trace`: one line per applied write, `value=<secret>` for secret inputs.

**Done when** a table-driven test suite covers every row of DESIGN's error
table and the event ordering rule ("never a `change` after the `submit` that
came from it"), with no GPUI linked.

### W3 · 9P server and headless (`ninep`)

- A 9P2000 server written for this (the protocol is small; existing Rust crates
  target 9P2000.L). Runtime-agnostic: `serve(io: impl AsyncRead + AsyncWrite,
  backend)` over `futures` traits, so the host runs it on GPUI's background
  executor and headless runs it on `smol`.
- Transports: a socket pair fd (h9), `-a unix!path` (mode 0600),
  `-a tcp!host!port` only with `-insecure`, and stdin/stdout.
- File semantics, which the design leaves implicit and this plan fixes:
  - `ctl` files: **each write is applied on arrival**, and the write's reply
    waits for the op's ack (DESIGN § Architecture).
  - Text and data files (`value`, `text`, `items`, `rows`, `ops`, `tree`,
    `layout`, ...): **writes buffer from open to clunk, and the whole value
    is applied at clunk**, so `cat big.rs >value` works across many 8 KiB
    writes. An error at clunk fails the clunk. `append` applies per write.
  - `events` files: each open is a subscription; reads block until whole
    lines are ready; `Tflush` cancels a blocked read; `short read` below the
    next line's size.
  - `mkdir` creates a node, `remove` deletes one (`rm -r` works bottom-up).
- `HeadlessBackend`: a `Tree` on its own thread behind the `FsBackend` trait,
  with a fake frame clock so `type is fixed` and batches behave. Clicks and
  other user events can be injected through a debug file, `/debug/inject`,
  present only in headless mode, so the conformance suite can drive a client.
- `gpuifs-headless -a unix!/tmp/g.sock` binary.

**Done when** plan9port's `9p` tool and a 9front `mount` (in h9) both drive
the headless server through the doc's examples, and the 9P fuzz test
(random T-messages) never panics.

### W4 · h9 embedding and CLI (`h9sys`, `gpuifs` binary)

- `h9sys/shim.zig`: the C ABI in DESIGN § Embedding h9, wrapping
  `h9.Machine` (`docs/embedding.md` in hyper9: `.fd` mount on `/mnt/gpui`,
  `cwd`, `env`, `stdio`, `signals`, `policy`).
- `build.rs` runs `zig build` against a hyper9 checkout found at
  `$HYPER9_DIR`, defaulting to a git submodule at `third_party/hyper9`;
  links the backend libraries (Hypervisor.framework on macOS) and the
  entitlement signing step.
- Safe wrapper: `Machine::new`, `run` on a dedicated `std::thread`,
  a `Send + Clone` `Signals` handle for `hangup` and `stop`.
- The `gpuifs` CLI: `-t`, `-k`, `--root`, `--dir`, h9 sandbox flags passed
  through, `-a addr`, `-insecure`, plus a development-only `--headless`
  that swaps the GPUI host for `HeadlessBackend` (trace to stderr).
- Lifecycle: exit code from the client's exit string; `-k`; app quit calls
  `hangup`, blocked reads get EOF, later access gets `app gone`, teardown
  after 2 s.
- Windows: the socket pair is `AF_UNIX` on Windows 10+; confirm `h9`'s
  `.fd` mount accepts a SOCKET handle there, or add a pipe path.

**Done when** `gpuifs --headless rc examples/rc/hello.rc` builds the hello
tree in an h9 machine on macOS and Linux, and its exit status comes back.

### W5a · Style table and theme data (`style`)

The reflection table of DESIGN § Style language as data, with no GPUI types:
every `Styled` method name gpui exposes at the pinned rev, its argument kinds,
and GPUI Kit's helpers (`v_flex`, `h_flex`, size words, variant words).
Generate it from gpui's source at the pinned rev with a script checked in
beside it, so a rev bump regenerates it. Also the `ThemeColor` token names and
default light and dark values, and the theme registry names.

W5b turns each table entry into a call on a GPUI `Styled` value with one
generated `match`. The table is what the tree uses to reject `unknown style
word` without GPUI.

**Done when** every style word used in DESIGN.md and in `examples/` is in the
table, and the generator is reproducible.

### W5b · GPUI host core (`host`)

- App startup on the main thread; the op channel from the 9P thread; apply
  ops inside `update`; publish snapshots; `cx.notify()` per dirty window.
- `HostCmd` handling: windows (`window` verb options, `title`, `size`,
  `move`, `center`, `state`, `activate`, `close` as a request, `destroy`,
  `notify` toasts), `quit`, theme tokens/mode/name/`theme load`, menus
  (`App::set_menus`), keymap and `context`, `set id enabled= check=`,
  focus, clipboard text.
- The root view and `materialize`: walk the committed tree, build elements,
  `ElementId` = path, apply style words (W5a table), state styles,
  `group`, `on` listeners for `click hover mouse_down mouse_up scroll key
  focus blur move` emitting events, `bounds` reported after layout, the
  `tooltip` file.
- The element tier: `div`, `text`, `styled-text`, `img`, `svg`, `icon`,
  `scroll`, `spacer`.
- `ComponentRegistry` and `RenderCx` (see Contracts) so W6 threads plug in.
- `gpui::TestAppContext` harness: build a tree with ops, render, simulate
  input, assert events. W6/W7 reuse it.

**Done when** `counter.rc` and `signin.rc` run on screen and the harness has
a passing test for each element type.

### W6a · Forms

`button`, `button-group`, `dropdown-button`, `checkbox`, `radio-group`,
`switch`/`toggle`, `slider`, `input`, `textarea`, `number-input`,
`otp-input`, `select`, `combobox`, `date-picker`, `calendar`,
`color-picker`, `rating`, `form`, `field`. Uncontrolled by default,
`controlled=on`, coalesced `change` with no text for `input`, `prefix`/`suffix`
slots, `flags=secret` with trace redaction.

### W6b · Navigation and overlays

`tabs`, `tab` (`close` request), `sidebar`, `sidebar-group`, `sidebar-item`,
`breadcrumb`, `pagination`, `stepper`, `title-bar`, `toolbar`,
`status-bar`, `link`; and the `overlays/` directory: `dialog`,
`alert-dialog`, `sheet`, `popover` (with `anchor=` trigger binding),
`hover-card`, `context-menu`, plus `notify` rendering if W5b hasn't.

### W6c · Data display

`list` (items and `row` templates with `{field}` stamping via `fields`),
`virtual-list`, `table` (columns, TSV rows, `sorted=on`, `append`,
`scrolled_to_end`, resize), `tree`, `description-list`, `badge`, `tag`,
`avatar`/`avatar-group`, `kbd`, `progress`, `spinner`, `skeleton`,
`shimmer`, `empty`, `alert`, `chart`. The host-supplied delegates that read
items from files live here.

### W6d · Editing, rich text, layout, dock

`editor` (language, diagnostics, selection, `save`, `complete`/`hover`
requests answered through `completions`/`hover` files by `seq=`),
`markdown`, `html`, `diff`, `message-list`, `bubble`; `accordion`,
`collapsible`, `group-box`, `separator`, `resizable`/`panel`, `grid`,
`dock`/`dock-panel` with `layout` read/write.

### W7 · Canvas, drag and drop, clipboard

The `canvas` node (`ops` display list, `ctl` `set`/`add`/`del`/`raise`/`lower`,
`pixels`, host hit testing with `item=`, `hover:fill=`), drag and drop
(`drop` accept lists, `drop-over:` styles, `/drags/<n>/data`, `drop`
requests, `dragstart`/`dragend`, `ExternalPaths`), and `clipboard` /
`clipboard-files`.

Each W6/W7 stream is **done when** its components' rows in DESIGN pass
headless `TypeSpec` tests and `TestAppContext` render tests, and its
milestone examples run.

### W8 · Conformance suite and examples

- `tests/conformance/*.rc`: one script per DESIGN section, run with
  `gpuifs --headless rc`, comparing `cat tree`, `trace` and `events` output
  to golden files; `/debug/inject` drives user events.
- Keep `examples/` runnable: each example has a header comment saying which
  milestone it needs. Turn each into a headless test of its tree-building
  phase as soon as M1 lands.
- Report every place the examples hit a gap or contradiction in DESIGN.md
  (see [§ Design questions](#design-questions-this-plan-answers)).

W8 can start today: the examples are already written against the design, and
the conformance scripts need only the text in DESIGN.md.

---

## Contracts

These are W0's signatures. They are the only shared surface between
workstreams. Names follow the design's spelling.

### `proto`

```rust
pub fn tokenize(s: &str) -> Result<Vec<String>, Error>;
pub fn quote(s: &str) -> Cow<'_, str>;

pub struct Command { pub verb: String, pub args: Vec<String>, pub props: Vec<(String, String)> }
pub fn parse_ctl(write: &[u8]) -> Result<Vec<Command>, Error>;      // one per line, all or nothing

pub struct StyleWord { pub state: Option<StateSel>, pub group: Option<String>,
                       pub name: String, pub args: Vec<StyleArg> }
pub enum StateSel { Hover, Active, Focus, Disabled, DropOver, GroupHover(String) }
pub enum StyleArg { Px(f32), Percent(f32), Rem(f32), Color(Rgba), Token(String) }
pub fn parse_style(s: &str) -> Result<Vec<StyleWord>, Error>;

pub mod doc   { pub struct DocNode { pub ty: String, pub name: String,
                                     pub props: Vec<(String, String)>, pub children: Vec<DocNode> }
                pub fn parse(s: &str) -> Result<DocNode, Error>;  pub fn print(n: &DocNode) -> String; }
pub mod lines { /* Item, Column, Row, TreeItem, DescItem, MenuLine, KeyBinding, CanvasOp,
                   Diagnostic, Message, Completion: each with parse(&str) and Display */ }

pub struct Event { pub name: String, pub attrs: Vec<(String, String)> }
impl Event { pub fn to_line(&self, seq: u64) -> String; }

pub enum ErrorKind { UnknownCommand, BadSyntax, UnknownStyleWord, UnknownType, TypeIsFixed,
                     InUse, NotFound, BadValue, TooLarge, ShortRead, NoBatch, AppGone }
pub struct Error { pub kind: ErrorKind, pub detail: String }   // Display: "phrase: detail"
```

### `style`

```rust
pub enum ArgKind { None, Length, Number, Color, Many(&'static [ArgKind]) }
pub struct StyleEntry { pub name: &'static str, pub arg: ArgKind, pub kit: bool }
pub static TABLE: &[StyleEntry];
pub fn lookup(name: &str) -> Option<&'static StyleEntry>;
pub static THEME_TOKENS: &[&'static str];                     // ThemeColor field names
pub fn default_theme(mode: Mode) -> &'static [(&'static str, &'static str)];
```

### `catalog` (data the tree validates against)

```rust
pub enum Tier { Element, Component, Overlay }
pub enum PropKind { Text, Word, Bool, Number, Enum(&'static [&'static str]),
                    Data(LineFormat), Bytes, ReadOnly }
pub struct PropSpec  { pub name: &'static str, pub kind: PropKind, pub default: Option<&'static str> }
pub struct VerbSpec  { pub name: &'static str, pub usage: &'static str }
pub enum EventKind   { State, Action, Request }
pub struct EventSpec { pub name: &'static str, pub kind: EventKind }
pub enum Slots { None, Any, Named(&'static [&'static str]), ChildTypes(&'static [&'static str]) }
pub struct TypeSpec {
    pub name: &'static str, pub tier: Tier,
    pub props: &'static [PropSpec], pub verbs: &'static [VerbSpec],
    pub events: &'static [EventSpec], pub slots: Slots,
    pub variants: &'static [&'static str], pub sizable: bool,
}
pub fn all() -> impl Iterator<Item = &'static TypeSpec>;     // elements + every group module
```

### `tree`

```rust
pub struct SessionId(pub u32);
pub struct FsPath(String);                              // "windows/main/root/prefs/ok/save/label"

pub enum Op {
    Write { path: FsPath, data: Bytes },               // ctl: one write; text/data: whole value at clunk
    Append { path: FsPath, data: Bytes },
    Mkdir { path: FsPath },
    Remove { path: FsPath },
    SessionClosed,                                     // aborts that session's batches
}

pub struct Tree { /* main-thread only */ }
impl Tree {
    pub fn new(reg: Registry) -> Self;
    pub fn apply(&mut self, s: SessionId, op: Op) -> Result<Changes, proto::Error>;
    pub fn snapshot(&self) -> Arc<Snapshot>;
    pub fn committed(&self, win: &str) -> Option<NodeRef<'_>>;    // what to render (batch-frozen)
    pub fn frame_drawn(&mut self, win: &str);                     // fixes types, closes timeouts
    pub fn mirror(&mut self, node: &str, file: &str, value: Bytes, via: Via); // component state -> files
    pub fn report_bounds(&mut self, node: &str, b: [f32; 4]);
    pub fn emit(&mut self, ev: EventMsg) -> u64;                  // returns seq; fills tag, win
    pub fn open_request(&mut self, ev: EventMsg, default: Answer, timeout: Duration) -> u64;
    pub fn tick(&mut self, now: Instant) -> Vec<HostCmd>;         // batch + request timeouts
    pub fn bus(&self) -> &EventBus;
}

pub struct Changes { pub dirty_windows: Vec<String>, pub created: Vec<String>,
                     pub removed: Vec<String>, pub props: Vec<(String, String)>,
                     pub host: Vec<HostCmd> }
pub enum HostCmd { Window(WindowSpec), WindowCtl { win: String, cmd: proto::Command },
                   Quit, Menus, Keymap, Theme, SetAction { id: String, enabled: Option<bool>, check: Option<bool> },
                   Overlay { win: String, name: String, open: bool }, Focus { win: String, node: String },
                   Clipboard, ComponentVerb { node: String, cmd: proto::Command },
                   Answer { seq: u64, answer: Answer } }

pub struct EventMsg { pub kind: catalog::EventKind, pub name: String, pub win: Option<String>,
                      pub node: Option<String>, pub attrs: Vec<(String, String)>, pub via: Via }

pub struct Snapshot { /* immutable */ }
impl Snapshot {
    pub fn stat(&self, p: &FsPath) -> Option<Stat>;     // Stat.kind: Dir | Ctl | Text | Data | Events | ReadOnly
    pub fn readdir(&self, p: &FsPath) -> Option<Vec<Stat>>;
    pub fn read(&self, p: &FsPath) -> Option<Bytes>;
}

pub struct Subscription { /* Send */ }
impl Subscription { pub async fn read(&mut self, max: usize) -> Result<Bytes, SubEnd>; } // whole lines; Eof after `gone`
```

### `ninep`

```rust
#[async_trait]
pub trait FsBackend: Send + Sync + 'static {
    fn snapshot(&self) -> Arc<tree::Snapshot>;
    async fn apply(&self, s: tree::SessionId, op: tree::Op) -> Result<(), proto::Error>; // waits for ack
    fn subscribe(&self, events_file: &tree::FsPath) -> Result<tree::Subscription, proto::Error>;
    fn new_session(&self) -> tree::SessionId;
    // Additive (W3), with defaults: files outside the tree (headless /debug) and quit state.
    fn extra_stat(&self, p: &tree::FsPath) -> Option<tree::Stat> { None }
    fn extra_readdir(&self, p: &tree::FsPath) -> Vec<tree::Stat> { vec![] }
    fn extra_read(&self, p: &tree::FsPath) -> Option<Bytes> { None }
    fn is_gone(&self) -> bool { false }                 // then every access but an events read fails `app gone`
}
pub async fn serve<T: AsyncRead + AsyncWrite + Unpin>(io: T, b: Arc<dyn FsBackend>) -> io::Result<()>;
pub struct HeadlessBackend;  impl HeadlessBackend { pub fn new(reg: tree::Registry) -> Arc<Self>; }
```

### `h9sys`

The C ABI is DESIGN § Embedding h9, unchanged. The Rust side:

```rust
pub struct Config { pub root: String, pub cwd: PathBuf, pub dirs: Vec<String>, pub ninep_fd: OwnedFd,
                    pub ninep_dst: String, pub env: Vec<String>, pub out_fd: RawFd, pub err_fd: RawFd,
                    pub profile: String, pub policy_flags: Vec<String> }
pub enum Status { Exited(String), Killed(String) }
pub struct Machine;     // !Send while running; lives on its own thread
impl Machine { pub fn new(c: Config) -> Result<Self, String>;
               pub fn run(&mut self, prog: &str, argv: &[String]) -> Result<Status, String>;
               pub fn signals(&self) -> Signals; }
#[derive(Clone)] pub struct Signals;  impl Signals { pub fn hangup(&self); pub fn stop(&self); } // Send
```

### `host` component interface (for W6, W7)

```rust
pub trait Component: 'static {
    fn spec(&self) -> &'static catalog::TypeSpec;
    /// Make the GPUI state entity for a new node (InputState, SelectState, ...). None if stateless.
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> { None }
    /// A prop file changed from the client side: push it into the entity.
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str,
                    window: &mut Window, cx: &mut App) {}
    /// A component verb on the node's ctl, already parsed and validated against the spec.
    fn verb(&self, node: &NodeView, state: Option<&AnyEntity>, cmd: &proto::Command,
            window: &mut Window, cx: &mut App) -> Result<(), proto::Error>;
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement;
}

impl RenderCx<'_> {
    pub fn children(&mut self, node: &NodeView) -> Vec<AnyElement>;     // non-slot children, in order
    pub fn slot(&mut self, node: &NodeView, name: &str) -> Option<AnyElement>;
    pub fn styled<E: Styled>(&self, el: E, node: &NodeView) -> E;      // style words + state styles
    pub fn emitter(&self, node: &NodeView) -> Emitter;                 // 'static + Clone, for listeners
    pub fn state<T: 'static>(&self, node: &NodeView) -> Option<Entity<T>>;
    pub fn window(&mut self) -> &mut Window;  pub fn cx(&mut self) -> &mut App;
}
impl Emitter { pub fn event(&self, name: &str, attrs: &[(&str, &str)]);   // kind from the spec
               pub fn request(&self, name: &str, attrs: &[(&str, &str)], default: Answer);
               pub fn mirror(&self, file: &str, value: impl Into<Bytes>); }

pub fn register(reg: &mut ComponentRegistry);   // one per group module; W0 wires all of them
```

## Working rules

- **Branches.** Each workstream works on `gpuifs-<id>-<name>` (for example
  `gpuifs-w2-tree`) off `gpuifs`, and opens a PR into `gpuifs`. Small PRs,
  merged often; phase 1 streams rebase on each other's merged stubs.
- **Ownership.** A thread edits only the paths its row owns. Anything else
  is a request to the owning thread.
- **Contract change rule.** Changing a signature in § Contracts means a PR
  that edits both the code and this section, and a message to every thread
  that depends on it. Additive changes (a new `HostCmd` variant, a new
  `ErrorKind` detail) don't need the message.
- **Spelling.** Type names, prop names, style words and event names follow
  DESIGN.md exactly, which follows GPUI Kit's Rust spelling.
- **Tests first where it's cheap.** Pure crates get table tests from the
  design's own snippets before the code.

## Design questions this plan answers

Writing the examples surfaced places where DESIGN.md is silent or
inconsistent. The plan picks an answer for each so threads don't diverge;
any of them can be revisited.

1. **Multi-write text files.** `cat big.rs >value` makes many writes. Text
   and data files buffer until clunk and apply once; `ctl` applies per write
   (W3).
2. **Answering a `close` request vs asking to close.** `close` on a window
   `ctl` asks to close; `close seq=N` answers a request. Presence of `seq=`
   decides.
3. **Overlay event attribute.** The alert-dialog example shows
   `ctl=overlays/confirm-del`; everywhere else it is `node=`. The plan uses
   `node=overlays/confirm-del`.
4. **Event `node=` paths are window-relative** (`root/prefs/ok/save`), as in
   the § Events examples. App-level events (`quit`, menu `action`) carry no
   `node=`.
5. **Late answers.** Answering a request after its default was applied fails
   with `not found`.
6. **OQ1 order.** Names don't sort; `order` is the only order. `new` appends.
7. **OQ5 style escape.** Not in v1; W5a's generator lists the `Style` fields
   with no method so the question can be decided with data.
8. **OQ6 `tree` diffing.** Keep by name and type only in v1.
9. **Tools in the guest.** The rc examples use only the 44 commands in h9's
   built-in root (no `printf`, `hoc` or `seq`), so they run with
   `--root builtin`. Tab-separated data is written with a small `awk`
   helper in [examples/rc/lib.rc](examples/rc/lib.rc).
10. **OQ8 Linux clients.** `examples/python/hn.py` assumes h9's Linux ABI
    sees `/mnt/gpui`. It is the test case for that question; until it is
    answered, it runs against `-a` with a 9P mount instead.
11. **Trailing newlines in text files.** `echo Hello >text` is the design's
    own idiom and writes `Hello\n`. Text files (`text`, `label`, `title`,
    `value` of single-line inputs, ...) drop one trailing newline on write;
    multi-line values (`editor`, `textarea`, `markdown`) keep the bytes as
    written. Reads return what is stored, with no newline added.
12. **Dropped files are host paths.** A platform drop gives host paths the
    guest can't open. The host serves each dropped file read-only at
    `/drags/<n>/files/<name>`, and `/drags/<n>/data` lists those guest
    paths. (`-a` clients get the same paths over 9P.)
13. **Go clients on Apple Silicon.** DESIGN.md says `GOOS=plan9
    GOARCH=arm64`, but Go has no `plan9/arm64` port. Go clients are built
    `GOOS=plan9 GOARCH=amd64` and run on h9's amd64 emulator on an arm64
    Mac (hyper9 `spec/abi-plan9.md`), or `GOOS=linux GOARCH=arm64` through
    the Linux ABI once OQ8 is settled. DESIGN.md's text should change.
14. **rc constraints worth knowing.** Plan 9's `read(1)` reads a byte at a
    time, so an rc client must pipe `events` through `cat` (the 8 KiB
    `short read` rule otherwise bites); a bare `=` in an argument is a
    syntax error in Plan 9 rc (DESIGN.md's notes client has `~ $ev
    *tag=save*`); and here documents don't work inside braces. The examples
    follow all three; W8's conformance scripts should too.

## Examples

[examples/README.md](examples/README.md) lists every example, what it
recreates, which features it exercises, and which milestone it needs. In
short:

- **14 rc programs**: hello (the Greeter), counter, todo, calculator,
  sign-in, settings, the GPUI Kit component gallery (21 stories as tree
  files), file browser, live stock table (GPUI Kit's real-time table story),
  IDE dock workspace (GPUI Kit's dock story), chat, notes (DESIGN.md's
  complete client), a zenity-style confirm box, and a canvas paint program.
- **2 Go** (`GOOS=plan9`): the greeter and an analog clock on a canvas.
- **1 C** (9front): Game of Life on a canvas.
- **1 awk**: a CSV viewer.
- **1 Python** (a Linux client, OQ8): a Hacker News reader.
- **1 bash** over plan9port `9p` and `gpuifs -a`: a progress window for any
  long command.

None has run against gpuifs, which doesn't exist yet. The rc programs parse
under Plan 9 rc, `hello.rc`, `calc.rc` and the awk viewer ran against a fake
tree, and the Go programs build for `GOOS=plan9 GOARCH=amd64`.
