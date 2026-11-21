# gpuifs: GPUI Kit as files

Nov 21, 2026 · @Jeff Lindsay · Draft v0.1

## Summary

gpuifs is a GPUI Kit host that serves a writable 9P file tree. A client program builds and runs a native GPUI application by reading and writing files in that tree. It needs no Rust, no bindings and no library.

GPUI elements are values that are rebuilt every frame. A client cannot hold one. GPUI Kit's own `gpui-shell` hit the same wall and solved it with a retained *description* that Rust replays into fresh elements on every frame ([gpui-shell.md §8](https://github.com/longbridge/gpui-kit/blob/main/docs/gpui-shell.md)). gpuifs makes that description a file tree. Every node is a directory, the host's one root view walks the tree in `render`, and a write marks the tree dirty and calls `cx.notify()`. GPUI already rebuilds everything, so no reconciler is needed.

The rest is lessons from earlier filesystem GUI work ([docs/uxkit.md](https://github.com/progrium/9ux/pull/23)) and Inferno Tk:

- A text protocol over 9P, with one quoting rule and one command per write.
- Fast interaction (typing, scrolling, resizing, dock drags) stays in the host. The client sees only semantic events.
- Action events are never dropped. State events are coalesced.
- Nodes carry an author-chosen `tag=` so the client routes events in its own vocabulary.
- A canvas is the escape hatch for custom drawing.

```rc
gpuifs -t Greeter ./greet      # run ./greet in an h9 machine with the tree at /mnt/gpui
```

## Goals and non-goals

**Goals**

1. Any language that can do file I/O over 9P can build a GPUI Kit application.
2. Two tiers, both first-class: GPUI's raw elements (`div`, `text`, `img`, `svg`) with its full style vocabulary, and the styled `gpui-component` catalog.
3. Anything that happens many times a second runs in the host. The client stays out of the frame loop, except on a canvas.
4. No event that the client must act on is ever lost.
5. The tree is the whole truth. `cat` shows what is on screen, and a `trace` file logs every change.
6. Names, style words and component options follow GPUI Kit's Rust spelling, so its docs carry over.

**Non-goals**

- Host mounting. gpuifs speaks 9P2000 on a socket or a pipe. The standard client runs in an embedded h9 machine that mounts the tree itself. A host-side client attaching to `-a addr` brings its own 9P library or mount.
- Script callbacks. There is no expression language and no code inside the tree. Logic stays in the client, as in Inferno Tk, but the host carries enough built-in behavior that common UI needs no round trip.
- Exposing every Rust type. Components whose interface is closures over Rust data (custom `TableDelegate`s, render callbacks) are reached through a file-shaped model instead.
- Remote display performance. A remote client works over any 9P transport, but this design does not tune for it.

## Why a file server

| Option | For | Against |
| --- | --- | --- |
| **Bindings per language** (Go, Python, ... over GPUI's Rust API) | Native speed, no extra hop | One binding per language, each chasing GPUI's API, which changes often. Closures, lifetimes and the per-frame rebuild don't map cleanly to most languages |
| **gpui-shell's JavaScript** | Exists, maintained by the GPUI Kit authors, in-process | One language. The UI can't be inspected or driven from outside the script, and no other process can share it |
| **gpuifs**: one host per app, serving 9P | Any language with file I/O. The UI is inspectable with `cat` and scriptable from any process the client chooses to share it with. The host is one Rust program that tracks GPUI | Every client change crosses 9P, a few tens of microseconds locally. The client can't run code inside a frame, so anything per-frame needs a built-in (§ What runs where) |

The cost is acceptable because the design keeps the client out of the frame loop: it acts once per user action, not once per frame.

## Architecture

gpuifs is one GPUI Kit process per client application. It serves one 9P2000 connection, on a Unix socket, a pipe it hands to a command it starts, or stdin and stdout. Normally the other end is mounted in the client's h9 machine (§ Running a client in h9).

&#91;embedded content: gpuifs host · one process, two threads\]

- **One root view per window.** Each window's root is a GPUI `Render` view whose `render` walks that window's node tree and builds `div`s and `gpui-component` elements from it. This is gpui-shell's materialize step with a tree as its input instead of a script arena.
- **The tree lives on the main thread.** GPUI state is single-threaded. The 9P server runs on the background executor, parses each write into an op, and sends it to the main thread through a channel. The main thread applies it inside an `update` and calls `cx.notify()` on the affected window, so GPUI redraws on its next frame. Many writes between frames cost one redraw.
- **Reads never wait for the UI.** After each batch of ops the main thread publishes an immutable snapshot of the tree (an `Arc`, swapped in place). The 9P thread serves `cat` and `ls` from it, so a busy frame doesn't stall a reader. A read just after a write sees that write, because the 9P thread waits for the op's acknowledgement before it answers the write.
- **Component state is GPUI's.** Stateful components (`InputState`, `SelectState`, `TableState`, `DockArea`) are `Entity`s held in a map keyed by node path, created when the node is created and dropped when it is removed. Their values are mirrored into the snapshot when they change.
- **Element IDs are paths.** GPUI needs a stable `ElementId` for hover, scroll and focus state. The node's path is that ID, so state survives every frame and is dropped when the node goes away.
- **Events flow back through queues.** GPUI listeners on the built elements (`on_click`, a component's `on_change`, action handlers) push events into per-subscription queues that the 9P thread drains when a client reads `events`.

## Running a client in h9

gpuifs is a standalone program for macOS, Linux and Windows. It runs its client inside an **h9 machine**: a small Plan 9 machine that h9 runs in-process, on the host's hypervisor. The client is a 9front program (rc, awk, a C program, a `GOOS=plan9` Go binary) or a static Linux binary, and it sees the tree as ordinary files at `/mnt/gpui`. Nothing on the host needs a 9P client, FUSE or a mount, and the client behaves the same on every platform.

```text
gpuifs [-t title] [-k] [--root builtin|DIR] [--dir HOSTDIR[:DST]]... [h9 sandbox flags] cmd [arg...]
gpuifs [-t title] -a addr          # no machine: serve 9P on addr, for tests and outside clients
```

`cmd` follows h9's rule: `./prog` or any path with a slash is a host file loaded into the machine, and a bare name (`rc`) is looked up on the machine's `$path`. With `--root builtin` (the default) the machine has h9's built-in root, which includes rc and the common 9front commands. `--root DIR` uses a full 9front tree. The host's current directory is the machine's working directory, read-write, as in `h9`.

```rc
gpuifs -t Notes rc ./notes.rc        # an rc client
gpuifs -t Greeter ./greet            # a GOOS=plan9 Go binary built on the host
```

1. gpuifs starts GPUI on the main thread and makes a socket pair. Its 9P server takes one end.
2. On a worker thread it creates an `h9.Machine` with the other end as an `.fd` mount on `/mnt/gpui`, sets `$gpuifs=/mnt/gpui` in the guest environment, and calls `Machine.run` with `cmd`. The machine attaches to the tree once, before the client starts, so the client's first `open` finds it ready.
3. The client creates windows and reads events. gpuifs shows nothing until the first `window` verb. The client's standard output and error go to gpuifs's own, and its standard input reads end of file.
4. **When the client exits**, `run` returns its exit string. gpuifs closes its windows and exits, with code 0 for an empty string and 1 otherwise. `-k` keeps the app running on host defaults instead, for a one-shot script that builds a UI and leaves.
5. **When the app quits** (`quit` on the root `ctl`, or the user quits and the client doesn't answer the request), gpuifs calls `Signals.hangup`. Every blocked `events` read returns end of file, later file access fails with `app gone`, and h9 tears the machine down after 2 seconds.
6. With `-a addr` and no `cmd`, gpuifs makes no machine and serves 9P on `addr`, so a test harness or a client on the host can attach with any 9P library.

### Embedding h9

h9 is a Zig library ([docs/embedding.md](https://github.com/progrium/hyper9/blob/main/docs/embedding.md)) and GPUI is Rust, so gpuifs links h9 through a small C ABI shim. The shim is a Zig file in the gpuifs repository, built as a static library by `build.rs` (which runs `zig build` against a path dependency on a hyper9 checkout). It wraps `h9.Machine` and nothing else:

```c
typedef struct H9Machine H9Machine;

typedef struct {
    const char *root;        /* "builtin", or an absolute host path to a 9front tree */
    const char *cwd;         /* absolute host path, bound at /mnt/term/cwd */
    const char *const *dirs; /* extra --dir mounts, "SRC:DST[:OPTS]" */
    int ninep_fd;            /* the guest end of the socket pair */
    const char *ninep_dst;   /* "/mnt/gpui" */
    const char *const *env;  /* "name=value", with gpuifs=/mnt/gpui */
    int out_fd, err_fd;      /* the client's stdout and stderr */
    const char *profile;     /* h9 policy profile, plus the flags below */
    const char *const *policy_flags; /* --net, --write, --timeout, ... as h9 parses them */
} H9Config;

int  h9_new(const H9Config *cfg, H9Machine **m, char *err, size_t errlen);
int  h9_run(H9Machine *m, const char *prog, const char *const *argv,
            char *status, size_t statuslen);  /* blocks until the client exits */
void h9_hangup(H9Machine *m);                 /* any thread */
void h9_stop(H9Machine *m);                   /* any thread */
void h9_free(H9Machine *m);
```

`h9_run` returns 0 with `exits` text in `status`, or 1 with a kill note (`h9: timeout`), or a negative error with `err` filled in. The shim copies status and error text out before returning, so the Rust side never holds pointers into the machine.

**Threads.** GPUI owns the main thread, which macOS requires for AppKit. `h9_run` blocks, so it runs on a dedicated `std::thread`, never on GPUI's executors. When it returns, that thread sends the status to the main thread through GPUI's async channel. gpuifs doesn't use h9's `gfx` option, so h9 never needs the main thread. `h9_hangup` and `h9_stop` only set a flag, so the main thread can call them when the app quits.

**One client per process.** h9 allows one HVF machine per process on macOS. gpuifs runs one app per process anyway, so this costs nothing. A second client is a second gpuifs process.

**The 9P server.** The socket pair's host end is served by gpuifs's Rust 9P server on its background executor, as in § Architecture. It is the same server that `-a addr` puts on a socket. Only the transport differs.

### Platforms

| Host | h9 backend | Notes |
| --- | --- | --- |
| macOS, Apple Silicon | HVF, arm64 guests | The binary must be signed with the hypervisor entitlement, as h9's build does |
| Linux x86\_64 | KVM, or the native backend (5.11+) for a trusted client | Needs an amd64 root tree for `--root DIR` |
| Linux arm64 | KVM | Built in h9, but not yet run on an arm64 KVM host |
| Windows x86\_64 | WHP, with the Windows Hypervisor Platform feature | Needs an amd64 root tree |
| Windows on ARM, or no hypervisor | hcpu, h9's own emulator | MIT, built into `h9`, so it ships in gpuifs too. Slower than a hypervisor |

Go clients are built on the host with `GOOS=plan9 GOARCH=arm64` (or `amd64`), matching the machine's architecture, and run unchanged on every platform with that architecture.

## Who can reach the tree

The tree is the app. Anyone attached to it can read every field, including `flags=secret` inputs, and can rebuild or quit the app. So:

- The default service is a socket pair mounted only in the client's h9 machine. Nothing on the host can reach it, and inside the machine only the client and programs it starts see /mnt/gpui. The h9 sandbox flags limit what the client itself can reach: by default the cwd and outbound network, as in h9's default profile.
- `-a unix!path` creates the socket mode 0600. `-a tcp!...` is refused unless `-insecure` is also given. gpuifs does no authentication of its own, so remote use belongs behind something that does (an ssh tunnel, a 9P `auth` file in a later version).
- Every attach gets the same, full view. There is no separate read-only or public view in v1. Open question 4 asks whether there should be.
- Secret values are readable, because the reader is the app. They never appear in `trace`, which logs `value=<secret>` instead.

## The tree

The tree has one app directory, a directory per window, and a directory per node below that. A node's children are its subdirectories, and the node's `order` file sets their order.

```text
/                         the root of the 9P service
    version               gpuifs 0.1, then one feature word per line
    ctl                   app verbs: window, menu, keymap, theme, set, quit, begin/commit
    events                every event in the app
    trace                 every applied write, one line each (read-only, like #τ/tkevents)
    theme/                tokens (read/write), mode (light|dark), name
    menus/  keymap        app menus (§9), key bindings (§9)
    clipboard  clipboard-files   the platform clipboard
    drags/<n>/data        payloads of drags in progress
    assets/               files a node can name with @name: icons, images, fonts
    windows/
        <win>/            the client's name for the window
            ctl  events  title  bounds  state  focus
            overlays/     dialogs, sheets, popovers
            root/         the window's root node
                type      div
                style     v_flex size_full p_4 gap_3
                order     header body
                header/
                    type  text
                    text  Hello
                body/ ...
```

### Node files

Every node has these files. A component adds its own (§7).

| File | Read | Write |
| --- | --- | --- |
| `type` | the node's type | once, at creation; later writes fail with `type is fixed` |
| `style` | style words (§5) | replaces them |
| `order` | child names in order, space-separated | reorders; a child not listed is not drawn |
| `tag` | the author's routing word | sets it; copied into every event about the node |
| `ctl` | the verbs this node takes, one per line | one verb per write |
| `events` | this node's events only | — |
| `bounds` | `x y w h` from the last layout, window-relative | — |
| `id` | the node's path, which is also its GPUI `ElementId` | — |

Text-valued properties (`text`, `value`, `placeholder`, `label`) are files of their own. A write is the whole value, raw bytes, no quoting. That removes Inferno Tk's quoting problem for the cases that matter most, which are user text and labels.

### Creating nodes

There are three ways to create a node. All of them produce the same tree.

1. **mkdir**: `mkdir root/save` makes an empty `div`. Write `type` before the first frame or it stays a `div`.
2. **A ctl verb**: `new <type> <name> [prop=value ...]` on the parent's `ctl` makes the node, sets its properties and appends it to `order`, all in one write.
3. **A document**: write a whole subtree as text to a node's `tree` file (§10).

`rm -r` on a node, or `delete <name>` on its parent's `ctl`, removes it. A node's path never changes while it exists. A rename is a delete and a create, so GPUI drops its element state (scroll offset, hover).

### Quoting

There is one rule, Plan 9's `tokenize`/`quote`: words split on blanks, and single quotes group a word, with `''` for a literal quote. It applies to every `ctl` write and every `prop=value` pair. Text files are never parsed. A `ctl` write holds one command per line, and all the lines in one write apply together or not at all. A change that spans several writes or files goes between `begin` and `commit` (§10).

### Windows

The root `ctl` makes windows. A window's own `ctl` changes it.

| Verb | On | Meaning |
| --- | --- | --- |
| `window name [title=text] [size=w,h] [min=w,h] [pos=x,y\|center] [kind=normal\|dialog\|popup] [titlebar=system\|custom\|none] [resizable=on\|off]` | root `ctl` | Make a window, with an empty `div` as its `root`. `in use` if the name is taken. `kind=dialog` is modal to the app's first window and has no minimize or maximize |
| `title text` | window `ctl` | Set the title. The `title` file does the same |
| `size w,h` / `move x,y` / `center` | window `ctl` | Resize or move. `bounds` reads `x y w h` back, in screen points |
| `state normal\|minimized\|maximized\|fullscreen` | window `ctl` | Change the state. The `state` file reads it back, and a `state` event follows every change, user-made ones included |
| `activate` | window `ctl` | Bring to front and take key focus |
| `close` | window `ctl` | Ask to close, as the close button does. This sends a `close` request (§ Requests) |
| `destroy` | window `ctl` | Close now, without asking |
| `notify text [type=...]` | window `ctl` | A toast (§ Overlays) |

Closing the last window doesn't quit the app. That is the client's call, made on the `close` request, as on macOS. `quit` on the root `ctl` quits now. A `quit` request comes from the app menu or the platform, and the default answer is to quit.

If no `events` file is open, closing the last window also quits, so a `-k` script's app doesn't linger with no windows.

## Style language

A `style` file holds GPUI `Styled` method names, one word per call, separated by blanks. The host looks each word up in the same reflection table gpui-shell uses for its `NullaryStyle` and `ParamStyle` ops. A word that isn't in the table fails the write with `unknown style word`. A write never half-applies.

| Form | Meaning | Examples |
| --- | --- | --- |
| `name` | a method with no argument | `flex_col` `items_center` `size_full` `rounded_md` `overflow_y_scroll` `cursor_pointer` |
| `name=n` | one number, in pixels | `w=240` `gap=12` `p=16` `text_size=13` |
| `name=n%` / `name=nrem` | a relative length | `w=50%` `px=1.5rem` |
| `name=token` | a theme token (`theme/tokens`) | `bg=primary` `text_color=muted_foreground` `border_color=border` |
| `name=#rrggbb[aa]` | a literal color | `bg=#1e1e2e` |
| `name=a,b` | several arguments | `shadow=0,4,12,#0003` |
| `hover:word` `active:word` `focus:word` `disabled:word` | a state style, resolved by GPUI with no round trip | `hover:bg=accent` `focus:border_color=ring` |
| `group:name` / `group-hover(name):word` | GPUI groups | a card that lights its title on hover |

GPUI Kit's own layout helpers are words too: `v_flex` and `h_flex` mean `flex flex_col` and `flex flex_row` with `items_center` where GPUI Kit sets it. Size words (`xs` `sm` `md` `lg`) set a component's `Sizable` size. Variant words (`primary` `ghost` `outline` `danger` `link`) set a component's variant when the component has one. On a raw `div` those words fail, which keeps a typo visible.

```rc
echo 'h_flex gap=8 p=12 rounded_lg bg=muted hover:bg=accent cursor_pointer' >root/card/style
```

### Theme

`theme/tokens` is `name value` lines: `background #ffffff`, `primary #0b5cff`, `radius 6` and so on, using `gpui-component`'s `ThemeColor` field names. Writing a line changes one token everywhere at once, since every style that names a token re-resolves on the next frame. `theme/mode` takes `light` or `dark`. `theme/name` loads a theme from GPUI Kit's theme registry (`Catppuccin`, `Tokyo Night`, ...), and `ctl` takes `theme load path` for a JSON theme in GPUI Kit's format.

## Element tier

The element tier is GPUI itself: unstyled boxes and text, laid out by Taffy (flexbox and grid) from the style words. Use it to build a design of your own, or to place and compose catalog components.

| Type | Files beyond the common set | Notes |
| --- | --- | --- |
| `div` | — | The universal box. Any `div` with `on=click` (below) becomes interactive |
| `text` | `text` | A styled run. Long text wraps by the parent's width. `flags` takes `selectable` and `truncate` |
| `styled-text` | `text`, `runs` | Text plus `start len style...` highlight lines, for syntax colors or search hits |
| `img` | `src` | `@asset`, a file path the host can read, or an `https` URL. Writing raw image bytes to `data` also works |
| `svg` | `src` | An icon or vector file. `text_color` tints it |
| `icon` | `name` | A GPUI Kit `IconName` (`search`, `chevron-down`, ...). It is `svg` with the kit's icon set |
| `scroll` | `origin` | A scrolling div. `style` picks the axes (`overflow_y_scroll`). `origin` reads and writes `x y` |
| `spacer` | — | `flex_1`, for pushing siblings apart |
| `canvas` | `ops` | Custom drawing (§11) |

### Making an element interactive

A raw element sends nothing unless asked. Write the names of the events it should send to its `on` file:

```rc
echo 'click hover drop' >root/card/on    # also: mouse_down mouse_up scroll key focus blur
```

Those events map to GPUI's `on_click`, `on_hover`, `on_drop` and the other listeners, which the host registers on the element it builds each frame. Pointer motion is available (`move`) but coalesced, as in §8.

```rc
# A clickable card from raw elements
n=root/list
echo 'new div card1 style=''v_flex gap=4 p=12 rounded_md border_1 border_color=border hover:bg=accent cursor_pointer'' tag=open:42' >$n/ctl
echo 'new text title style=''text_sm font_semibold''' >$n/card1/ctl
echo 'Quarterly report' >$n/card1/title/text
echo click >$n/card1/on
```

## Component catalog

A component is a node whose `type` names a `gpui-component` component. It takes style words like any node, plus its own property files and `ctl` verbs. The host owns each component's GPUI state (an `InputState`, `SelectState`, `TableState` entity), keyed by the node's path, so it lives exactly as long as the node does.

Three rules apply to every component:

- **Uncontrolled by default.** A checkbox toggles itself, and a select changes its own value, then the host sends the event. The client never has to echo state back. Writing `controlled=on` makes the component wait for the client to write its `value`, as GPUI Kit's controlled API does.
- **Children are slots.** Where a component takes elements (a button's content, a dialog's footer, a tab's panel), the child directories are those elements. Where it takes named slots, the child names are the slot names: `prefix`, `suffix`, `header`, `footer`, `trigger`, `content`.
- **Items are files.** Lists, tables, trees and selects take their data as a line-oriented file, never as one directory per row. The host virtualizes them.

### Buttons and form controls

| Type | Properties (files or `prop=`) | Events |
| --- | --- | --- |
| `button` | `label`, `icon`, `loading`, `disabled`, `selected`; variant and size words in `style` | `click` |
| `button-group` | `multiple=on`, `value` (selected child names) | `change value=` |
| `dropdown-button` | `label`; a `menu` child (§9 grammar) | `click`, `action id=` |
| `checkbox` | `label`, `value` (`on`, `off`, `mixed`) | `change value=` |
| `radio-group` | `items` (`id label` lines), `value`, `dir=h\|v` | `change value=` |
| `switch` / `toggle` | `label`, `value` | `change value=` |
| `slider` | `min` `max` `step` `value` (one number, or `lo hi` for a range), `dir` | `change value=` (coalesced while dragging), `commit value=` on release |
| `input` | `value`, `placeholder`, `mask`, `max_len`, `flags` (`secret`, `cleanable`, `readonly`); `prefix`/`suffix` slots | `change` (coalesced, carries no text), `submit`, `focus`, `blur` |
| `textarea` | as `input`, plus `rows`, `auto_grow=min,max` | as `input` |
| `number-input` | `value`, `min`, `max`, `step` | `change value=` |
| `otp-input` | `length`, `value`, `flags=secret` | `change`, `complete value=` |
| `select` | `items`, `value`, `placeholder`, `searchable=on` | `change value=` |
| `combobox` | `items`, `value`, `multiple=on`; `query` is readable | `change value=`, `query` (coalesced, for a client that filters items itself) |
| `date-picker` | `value` (ISO date, or `start end`), `range=on`, `min`, `max`, `presets` | `change value=` |
| `calendar` | as `date-picker`, shown inline | `change value=` |
| `color-picker` | `value` (`#rrggbbaa`), `swatches` | `change value=` (coalesced), `commit` |
| `rating` | `max`, `value` | `change value=` |
| `form` | `layout=v\|h`, `label_width`; children are `field` nodes | `submit` |
| `field` | `label`, `description`, `error`, `required`; one control child | — |

The text of an `input` changes on every keystroke, so its `change` event says only that it changed. A client that needs the text reads the `value` file. That keeps the event stream small and makes a slow client see the newest text, never a backlog. `select` and `combobox` items use one format, shared with lists:

```text
id<TAB>label[<TAB>icon=name][<TAB>disabled]
# a line starting with "# " is a group header; "-" alone is a separator
```

```rc
w=windows/main/root
echo 'new form prefs layout=v' >$w/ctl
echo 'new field name label=Name
new field lang label=Language
new field ok' >$w/prefs/ctl
echo 'new input in placeholder=''Your name''' >$w/prefs/name/ctl
echo 'new select in searchable=on' >$w/prefs/lang/ctl
printf 'rs\tRust\ngo\tGo\nc\tC\n' >$w/prefs/lang/in/items
echo 'new button save label=Save style=primary tag=save' >$w/prefs/ok/ctl
```

### Navigation

| Type | Properties | Events |
| --- | --- | --- |
| `tabs` | `value` (selected tab name), variant words (`underline`, `pill`, `segmented`); children are `tab` nodes | `change value=` |
| `tab` | `label`, `icon`, `closable=on`; its children are the panel, drawn only while selected | `close` (a request, §8) |
| `sidebar` | `collapsed`, `side=left\|right`, `collapsible=icon\|off`; `header`, `footer` slots; children are `sidebar-group` nodes | `collapse value=` |
| `sidebar-group` | `label`; children are `sidebar-item` nodes | — |
| `sidebar-item` | `label`, `icon`, `active`, `badge`; children are sub-items | `click` |
| `breadcrumb` | `items` (`id label` lines) | `click id=` |
| `pagination` | `page`, `total`, `per_page` | `change page=` |
| `stepper` | `items`, `value`, `dir` | `change value=` |
| `title-bar` | `title`; children fill the bar. Writing it makes the window draw its own title bar, as GPUI Kit's `TitleBar` does | `action` from window controls |
| `toolbar` | children are buttons and separators | — |
| `status-bar` | `left`, `center`, `right` slots | — |
| `link` | `label`, `href` | `click` (the host opens `https` links itself unless `on` lists `click`) |

```rc
# A settings window: sidebar on the left, the page on the right
r=windows/settings/root
echo 'h_flex size_full' >$r/style
echo 'new sidebar nav
new div page style=''flex_1 p=24''' >$r/ctl
echo 'new sidebar-group g label=Settings' >$r/nav/ctl
echo 'new sidebar-item general label=General icon=settings active=on tag=page:general
new sidebar-item account label=Account icon=user tag=page:account
new sidebar-item keys label=Shortcuts icon=keyboard tag=page:keys' >$r/nav/g/ctl
```

### Overlays

Overlays live in their window's `overlays/` directory, not in the node tree, because GPUI Kit draws them in the window's `Root` layer above everything. Each overlay is still a node with children. Writing `open` to its `ctl` shows it, and `close` hides it. An overlay can also be bound to a trigger node, which opens it with no round trip.

| Type | Properties | Events |
| --- | --- | --- |
| `dialog` | `title`, `description`, `width`, `modal=on`, `overlay_closable`, `keyboard=on` (Esc closes); `footer` slot | `open`, `close` (a request) |
| `alert-dialog` | `title`, `description`, `confirm`, `cancel` (button labels), `variant=danger` | `confirm`, `cancel` |
| `sheet` | `side=left\|right\|top\|bottom`, `size`, `title`; `footer` slot | `close` (a request) |
| `popover` | `anchor=<node path>`, `placement` (`bottom-start` ...), `trigger=click\|hover` | `open`, `close` |
| `hover-card` | as `popover`, with `trigger=hover` and open and close delays | — |
| `tooltip` | a `tooltip` file on any node, or `key=` for a shortcut hint | — |
| `context-menu` | `anchor=<node path>`; a menu body (§9) | `action id=` |

Notifications don't need a node. The window `ctl` takes them as a verb, and GPUI Kit stacks and expires them:

```rc
echo 'notify ''Saved draft'' type=success' >windows/main/ctl
echo 'notify ''Upload failed'' type=error sticky=on action=retry:''Try again''' >windows/main/ctl
```

A confirm-before-delete flow:

```rc
o=windows/main/overlays
echo 'new alert-dialog confirm-del title=''Delete 3 files?'' description=''This cannot be undone.'' confirm=Delete cancel=Keep variant=danger tag=del' >$o/ctl
echo open >$o/confirm-del/ctl
# events gives: confirm win=main ctl=overlays/confirm-del tag=del
```

### Data display

These components need the items-are-files rule most. GPUI Kit's `List`, `Table` and `Tree` take a Rust delegate that answers how many rows there are and renders row n. In gpuifs the host supplies that delegate, and it reads from a file the client wrote.

| Type | Properties | Events |
| --- | --- | --- |
| `list` | `items` (the select format) or a `row` template child; `selectable`, `multiple`, `searchable`, `loading` | `select value=`, `open id=`, `scrolled_to_end` |
| `table` | `columns` (`id label width [sort] [fixed] [align=right]` lines), `rows` (TSV, first field is the row ID); `stripe`, `selectable=row\|cell`, `resizable`, `sortable` | `select row= col=`, `sort col= dir=`, `open row=`, `scrolled_to_end` |
| `tree` | `items` (`id parent label [icon=]` lines, parent `-` for roots), `expanded` (IDs); `selectable`, `multiple` | `select value=`, `expand id= value=`, `open id=` |
| `description-list` | `items` (`label<TAB>value` lines), `columns`, `bordered` | — |
| `badge` | `count` or `dot=on`, `max`; one child it decorates | — |
| `tag` | `label`; variant and color words | `close` if `closable=on` |
| `avatar` / `avatar-group` | `src`, `name` (initials fallback), `max` | — |
| `kbd` | `key` in GPUI keystroke syntax (`cmd-shift-p`), drawn for the platform | — |
| `progress` | `value` 0 to 100, or empty for indeterminate; `variant=bar\|circle` | — |
| `spinner`, `skeleton`, `shimmer` | size words | — |
| `empty` | `title`, `description`, `icon`; children are actions | — |
| `alert` | `title`, `text`, `variant=info\|success\|warning\|error`, `closable` | `close` |
| `chart` | `kind=line\|bar\|area\|pie`, `data` (TSV with a header row), `x`, `y` (column names) | `select x=` |

**Sorting stays in the client.** A `sort` event says which column and direction the user asked for. The client rewrites `rows`, or writes `sorted=on` to let the host sort the column as text or numbers. Because `rows` is written whole, a large table can be fed in pages instead. The `append` file adds lines to the end, and a `scrolled_to_end` event asks for more.

**Templated rows.** For rows richer than text, a `list` takes a `row` child, an ordinary subtree whose text files can hold `{field}` placeholders. The host stamps it once per visible item, filling fields from the item's TSV columns, named by a `fields` file. It is the template idea that gpui-shell's design sketches in §20.7, and it keeps 100k rows as one file.

```rc
t=windows/main/root/files
echo 'new table files stripe=on selectable=row sortable=on' >windows/main/root/ctl
printf 'name\tName\t280\tsort\nsize\tSize\t90\tsort\talign=right\nmod\tModified\t160\tsort\n' >$t/columns
ls -l | awk '{print NR "\t" $9 "\t" $5 "\t" $6" "$7" "$8}' >$t/rows
```

### Editing and rich content

| Type | Properties | Events |
| --- | --- | --- |
| `editor` | `value`, `language` (a Tree-sitter grammar name), `line_numbers`, `soft_wrap`, `tab_size`, `readonly`; `diagnostics` (`line col len severity message` lines); `selection` (read/write `line col line col`) | `change` (coalesced), `save` (the bound key), `cursor line= col=` (coalesced), `hover line= col=` and `complete line= col= prefix=` (requests) |
| `markdown` | `text`, `selectable` | `link href=` |
| `html` | `text` (a safe HTML subset, as GPUI Kit's `TextView` renders it) | `link href=` |
| `diff` | `old` and `new`, or `patch` (unified); `layout=split\|unified` | — |
| `message-list` | `items` (an `id role time` header line, then markdown, ended by a blank line); `stick_to_bottom` | `scrolled_to_top` |
| `bubble` | `role=user\|assistant`, `text` (markdown), `avatar` | — |

The `editor` is the clearest case of keeping fast work in the host. A 200k-line file is written once to `value`. Typing, selection, highlighting and scrolling all run in GPUI Kit's editor. The client gets coalesced `change` events and reads `value` when it wants the text, for example to save it.

LSP features become requests the client can answer. A `complete` event asks for completions. The client answers by writing `items` lines to the editor's `completions` file, tagged with the request's `seq=`, so a late answer to an old request is dropped. `hover` is answered the same way through `hover`. A client that doesn't answer gets no popup, and nothing waits on it.

```rc
e=windows/main/root/src
echo 'new editor src language=rust line_numbers=on' >windows/main/root/ctl
cat main.rs >$e/value
printf '12\t5\t3\terror\tmismatched types\n' >$e/diagnostics
```

### Layout

| Type | Properties | Events |
| --- | --- | --- |
| `accordion` | `multiple`, `value` (open item names); children are `accordion-item` nodes with `title` | `change value=` |
| `collapsible` | `open`; a `trigger` slot and a `content` slot | `change value=` |
| `group-box` | `title`, variant words | — |
| `separator` | `dir`, `label` | — |
| `resizable` | `dir=h\|v`; children are `panel` nodes with `size`, `min`, `max` | `resize sizes=` (on release) |
| `grid` | `cols`, `rows`, `gap`; children take `col_span` and `row_span` style words | — |
| `dock` | `layout` (read/write, GPUI Kit's serialized `DockArea` JSON); children are `dock-panel` nodes | `layout` (on change, coalesced), `panel-close id=` (a request) |
| `dock-panel` | `title`, `icon`, `zone=center\|left\|right\|bottom`, `closable`, `zoomable` | `activate`, `close` |
| `virtual-list` | as `list`, with `item_height`, or `measure=on` for mixed heights | as `list` |

The dock shows why file state beats events. A user can drag tabs between docks, split, resize and zoom, all inside GPUI Kit. The client doesn't track any of it. To restore a layout on the next launch, it does `cat $d/layout >layout.json` at quit and writes the file back at start.

```rc
d=windows/main/root/ws
echo 'new dock ws style=size_full' >windows/main/root/ctl
echo 'new dock-panel files title=Files icon=folder zone=left
new dock-panel src title=main.rs zone=center
new dock-panel log title=Output zone=bottom' >$d/ctl
test -f ~/.app/layout.json && cat ~/.app/layout.json >$d/layout
```

### Not in v1

- **Raw `Render` views and delegates as code.** Anything that needs a Rust closure per row or per frame goes through a data file or a template.
- **`webview`.** It is a separate crate with its own process model. It could be a node with a `url` file later.
- **`speech`, `touch_selection`, `inspector`, `fps`.** These are platform or developer tools, not application UI.
- **The `gpui-base` unstyled layer as its own tier.** The element tier plus style words already gives full visual control, so a third tier would add little.

## Events

Events are text lines on `events` files, the same shape everywhere: the event name, then `key=value` attributes in the one quoting style.

```text
click win=main node=root/prefs/ok/save tag=save seq=118
change win=main node=root/prefs/lang/in tag='' value=go seq=119
close win=main via=titlebar seq=120
```

- **Where to read.** The app `events` file has every event, each window's `events` has that window's, and each node's `events` has that node's. A client picks the grain that suits it. Each open of an `events` file is its own subscription, starting with a `resync seq=N` line. When the window or node goes away, the stream ends with `gone`, then end of file.
- **Routing by tag.** `tag=` is the node's `tag` file, copied into every event about the node. A client that writes `tag=open:42` gets `click ... tag=open:42` back, and doesn't need to parse paths.
- **Echoes.** Changes the client made itself carry `via=ctl`. Changes the user made carry `via=user`.
- **Short reads.** A read returns whole lines only. A read buffer smaller than the next line fails with `short read`, so clients should read at least 8 KiB.

### Two kinds of event

A click can't be reread later, but a value can. So events come in two kinds, and they are queued differently.

| Kind | Examples | When the reader is slow |
| --- | --- | --- |
| **State** | `change`, `select`, `cursor`, `resize`, `layout`, `move`, `scroll`, `hover` | **Coalesced.** A new event replaces a queued one with the same name about the same node, and moves to the back of the queue. The newest state always arrives, and the queue can't grow without bound |
| **Action** | `click`, `submit`, `open`, `action`, `confirm`, `cancel`, `close`, `quit`, `key`, `drop`, requests | **Never dropped.** Queued in order, up to 4,096 per subscription. Past that, the reader gets `lost n=N` and the host treats it as not answering |

Order is kept between the two. A coalesced event takes the position of its newest copy, so a client never sees a `change` after the `submit` that came from it.

### Requests

Some events ask the client to decide: closing a window, quitting, closing a dialog, tab or dock panel, completing in an editor, or accepting a drop. If no `events` file is open, the host applies the default answer (close, quit, refuse the drop). If one is open, the host waits for the client to answer on the node's `ctl` (`close`, `keep`, `accept`, `refuse`) with the request's `seq=`. After 5 seconds with no answer, the host applies the default. A script that never reads events still gets a window that closes.

### Drag and drop

GPUI drags carry a typed value inside the app and paths from the platform (`ExternalPaths`). gpuifs exposes both through files, so the dragged data never has to fit in an event line.

**Receiving.** A node becomes a drop target with a `drop` file listing what it accepts: `files`, `text`, `uri`, or a client-chosen type such as `note`. While a drag hovers over it, its `hover:` and `drop-over:` style words apply with no round trip. A drop sends a request event:

```text
drop win=main node=root/nav/notes tag=pick type=files drag=7 pt=40,212 seq=301
```

The payload is in `/drags/7/data`: one path per line for `files`, the text for `text`. The client answers with `accept seq=301` or `refuse seq=301` on the node's `ctl`. With no answer, the drop is refused. `/drags/7` disappears once the request is answered.

**Starting a drag.** A node with `drag` in its `on` file and a `drag-type` file starts a drag in the host when the user presses and moves on it, with no round trip. The host sends `dragstart node=... drag=8`. The client writes the payload to `/drags/8/data`, which can happen after the drag begins, since the payload is only read at the drop. When it ends, a `dragend drag=8 result=dropped|cancelled target=<node>` event follows. Drags between gpuifs apps, or out to the platform, use `files` and `text` only.

### Clipboard

The root `clipboard` file is the platform clipboard, as text. Reading it returns the current text. Writing replaces it. `clipboard-files` does the same for paths. Copy and paste inside inputs and editors are built in and never involve the client.

## Actions, keymaps and menus

GPUI routes keys through named actions: a keystroke matches a binding in a `key_context`, the binding names an action, and the action is dispatched up the focus path. gpuifs keeps that model and lets the client name the actions.

**Keymap.** The root `keymap` file holds one binding per line, in GPUI keystroke syntax:

```text
cmd-s        save
cmd-shift-p  palette
escape       dismiss      context=editor
ctrl-tab     next-tab     context=workspace
```

A node's `context` file sets its GPUI `key_context`, so `context=editor` binds only while focus is inside a node with that context. Built-in GPUI Kit actions (an input's `select-all`, a list's `select-next`) keep working and are not reported. An action named in the keymap that no built-in handles comes to the client as `action id=save win=main focus=root/src`.

**Menus.** The root `menus/` directory sets the app menu bar (GPUI's `App::set_menus`, a native menu on macOS). Each menu is a file of item lines, which is uxkit's grammar:

```text
item new    label=New      key=cmd-n
item open   label=Open…    key=cmd-o
sep
sub recent  label='Open Recent'
item quit   label=Quit     key=cmd-q
```

Choosing an item sends the same `action id=` event as its key. `set id enabled=off` and `set id check=on` on the root `ctl` change every item, button or binding for that action at once, the way GPUI disables an action that has no handler. Context menus and `dropdown-button` menus use the same item grammar in their `menu` file.

**Focus.** The window `focus` file reads the focused node's path. Writing a path moves focus there (GPUI's `FocusHandle::focus`). `focus` and `blur` events are state events.

## Atomic updates and subtree documents

GPUI draws whenever it likes, so a client building a form one file at a time could show half a form. There are two ways to prevent that.

**Batches.** `begin` on a window's `ctl` freezes what that window draws. Writes still apply to the tree, and reads show them, but the frame keeps drawing the last committed tree. `commit` makes everything visible in one frame, and `abort` throws it all away. Batches are per client connection (per 9P session), so two clients can't commit each other's work. A batch left open for 2 seconds is committed, and the trace logs `batch timeout`, so a crashed client can't freeze a window.

**Subtree documents.** Every node has a `tree` file. Reading it prints the subtree as indented text. Writing it replaces the subtree in one step, and the host keeps any child whose name and type match, so focus, scroll and editor state survive. That makes a whole screen one `cat`:

```text
div root  style='v_flex size_full p=24 gap=16'
  text title  style='text_xl font_semibold'  text='Sign in'
  form f  layout=v
    field user  label=Email
      input in  placeholder=you@example.com
    field pass  label=Password
      input in  flags=secret
    field go
      button submit  label='Sign in'  style='primary w_full'  tag=login
  link help  label='Forgot password?'  href=https://example.com/reset
```

Each line is `type name prop=value...`, with two spaces of indent per level. Text properties fit inline when they are short. Longer text goes in a heredoc-style block: `text=<<END`, the lines, then `END`. The reader prints the same format, so `cat tree >screen.ui` saves a screen and writing it back restores it. A client that likes the document model can work only in `tree` files and never touch directories. The directory view is still there for scripts that want to change one label.

## Canvas

A `canvas` node holds a retained display list in its `ops` file. GPUI paints the list on the GPU every frame, so the client only writes when the picture changes.

```text
rect   bg      0 0 400 300   fill=background
rect   card    20 20 160 90  fill=muted radius=8 border=border
path   spark   M20,200 L60,180 L100,190 L140,150  stroke=primary width=2
circle dot     140 150 4     fill=primary
text   lbl     28 44         'Revenue'  size=13 color=muted_foreground
image  logo    360 12 24 24  src=@logo
```

Each line is `kind id geometry attrs`. Colors are theme tokens or literals. Writing `ops` replaces the list. The `ctl` file changes items by ID: `set dot 150 140`, `add`, `del`, `raise`, `lower`. So moving one item costs one short write, not a new picture. A `pixels` file takes raw RGBA at the canvas's size, for clients that render images themselves.

Pointer input follows the `on` file, as for any element: `mouse_down`, `mouse_up` and `click` are action events, and `move` and `drag` are coalesced. Events name the item under the pointer: `mouse_down node=root/chart item=dot x=141 y=150 button=left`. Hit testing runs in the host, so an item can have `hover:fill=accent` with no round trip.

## A complete client

A small notes app in rc: a sidebar list of notes, an editor, a toolbar with save and delete, a keymap and a menu. Notes are files in `$home/notes`.

```rc
#!/bin/rc
k=/mnt/gpui                         # wherever the client has the 9P service
n=$home/notes

echo 'window main title=Notes size=900,600' >$k/ctl
w=$k/windows/main

cat >$w/root/tree <<'EOF'
div root  style='h_flex size_full'
  sidebar nav  style=w=220
    list notes  searchable=on  selectable=on  tag=pick
  div page  style='v_flex flex_1'
    toolbar bar
      button save  label=Save  icon=check  style='ghost sm'  tag=save
      button del   label=Delete  icon=trash  style='ghost sm danger'  tag=del
    editor body  style=flex_1  language=markdown  soft_wrap=on
EOF

printf 'cmd-s save\ncmd-n new\n' >$k/keymap
printf 'item new label=New key=cmd-n\nitem save label=Save key=cmd-s\nsep\nitem quit label=Quit key=cmd-q\n' >$k/menus/File

fn refresh { ls $n | awk -F/ '{print $NF "\t" $NF}' >$w/root/nav/notes/items }
refresh
cur=''

cat $k/events | while(ev=`{read}){
	switch($ev(1)){
	case select
		cur=`{echo $ev | sed 's/.*value=([^ ]*).*/\1/'}
		cat $n/$cur >$w/root/page/body/value
	case click action
		if(~ $ev *tag=save* *id=save*) {
			cat $w/root/page/body/value >$n/$cur
			echo 'notify Saved type=success' >$w/ctl
		}
		if(~ $ev *id=new*) { cur=untitled-`{date -n}; touch $n/$cur; refresh }
		if(~ $ev *tag=del*) { rm $n/$cur; refresh }
		if(~ $ev *id=quit*) echo quit >$k/ctl
	case quit
		echo quit >$k/ctl
	}
}
```

The client handles about eight kinds of event. Everything else runs in the host: typing, search in the list, sidebar resize, markdown highlighting, focus, the notification, and the native menu.

Run it with `gpuifs -t Notes rc ./notes.rc`. The same program in Go is a `GOOS=plan9` binary that uses only package `os` on `/mnt/gpui`. It opens `events` with an 8 KiB `bufio` reader and writes the same strings.

## What runs where

The client acts once per user action. Everything that happens many times a second stays in the host.

| Interaction | Runs in | The client sees |
| --- | --- | --- |
| Typing, selecting and editing text, undo | GPUI Kit input and editor | coalesced `change`, then reads `value` |
| Scrolling, scroll bars, virtualized lists and tables | GPUI Kit | `scrolled_to_end`, if it asked |
| Hover, press and focus styles | GPUI state styles | nothing |
| Opening and tracking menus, selects, popovers, tooltips | GPUI Kit | one `action` or `change` |
| Resizing panels, columns and dock splits, dragging dock tabs | GPUI Kit | one `resize` or `layout` on release |
| Key bindings and focus movement | GPUI's keymap and focus | `action` only for client-named actions |
| Drag and drop | GPUI and the platform | `dragstart`, `drop`, `dragend` |
| Toasts, dialog open and close animation | GPUI Kit | `close` and `confirm` requests |
| Drawing on a canvas | the client writes items, GPUI paints | coalesced `move` and `drag`, item hits |

Only the canvas puts the client near the frame loop, which is why its motion events are coalesced and why it takes a retained item list, not frames.

## Errors and limits

A failed write returns a 9P error whose text is one of a fixed set of phrases, followed by detail after a colon: `unknown style word: flexx`.

| Error | When |
| --- | --- |
| `unknown command` | a `ctl` verb the node doesn't take |
| `bad syntax` | quoting or `prop=value` that doesn't parse |
| `unknown style word` | a style word not in the table, or not valid for this type |
| `unknown type` | a `type` or `new` that names no element or component |
| `type is fixed` | writing `type` after the first frame |
| `in use` | `new` or `window` with a name that exists |
| `not found` | a path, node or item ID that doesn't exist |
| `bad value` | a value of the wrong kind (`w=wide`) or out of range |
| `too large` | over a limit below |
| `short read` | an `events` read with a buffer smaller than the next line |
| `no batch` | `commit` or `abort` with no `begin` |
| `app gone` | any access after the app quit |

| Limit | Value |
| --- | --- |
| One `ctl` write | 64 KiB |
| A text property file (`value`, `text`) | 16 MiB |
| A data file (`items`, `rows`, `ops`) | 64 MiB |
| An image or `pixels` write | 16 MiB |
| Queued action events per subscription | 4,096 |
| Node depth | 64, as in gpui-shell |
| An open batch | 2 seconds |
| A request waiting for an answer | 5 seconds |

## Open questions

1. **Directory names vs. order.** Child names are IDs and `order` gives the order. Should a name like `10-header` also sort, so `ls` shows the order with no `order` file?
2. **Request timeout.** Five seconds before the default answer to a request is a guess. Should it be per request type, or set by the client?
3. **Templates beyond lists.** Row templates cover lists. Should tables and trees take a cell or item template too, or is text enough there?
4. **Multiple clients.** One app tree per client is the simple model. Should a second client be able to attach to a running app, as 9/UX's public view allows, and with what rights?
5. **Style word coverage.** The reflection table is GPUI's `Styled` methods plus GPUI Kit's helpers. Arbitrary GPUI `Style` fields with no method (grid templates, for one) need a `name=value` escape. Is that worth adding in v1?
6. **`tree` diffing.** Keeping children by name and type is simple. Is it enough to keep editor and input state across a rewrite, or do some components need a stable `key=`?
7. **Accessibility.** GPUI Kit has AccessKit roles built in. Should `label` and `role` files be required on raw-element widgets, so a client-built button is still announced as a button?

8) **Linux clients.** h9 also runs static Linux binaries in the same machine. If its Linux ABI shows `/mnt/gpui` like any other path, Python or Node in an Alpine tree could be clients too. That needs checking against h9's Linux file interface.
9) **The browser.** h9 has a WebAssembly host, and GPUI Kit builds for `wasm32`. A gpuifs in a browser tab, with the client in an h9 machine beside it, may be possible. It is out of scope for the prototype.
