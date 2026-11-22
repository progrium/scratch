# core: the tree, `ctl`, events

**Layer:** `core 1.0` (draft) · **Mount:** `$ui` · **Required:** yes ·
**Conventions:** [README.md](README.md#shared-conventions)

The core layer is what every host serves: an app directory, a directory
per window, a directory per node below it, one command grammar for every
`ctl` file, and one event line shape. A client that uses only this layer
and the [components](components.md) a host lists can build any UI that
host can draw.

## The tree

```text
$ui/
    version        layers, profiles and features (§ Version)
    ctl            app verbs, and node commands by path from the app root
    events         every event in the app
    trace          every applied write and every error, streamed
    keys           key bindings (§ Keys, actions and menus)
    menu/          the app's menus, one file per menu, and bar
    theme/         tokens, mode, name
    asset/         named files a node can refer to as @name
    types/         the component types this host builds (components.md)
    style/words    the style words this host accepts
    win/
        main/      the window named main, which is also its root node
            ctl  events  tree  type  style  order  tag ...   root node files
            title  bounds  state  focus                       window files
            over/  overlays: dialogs, sheets, popovers
            body/  a child node
                type  text  ...
```

A window **is** its root node: `$ui/win/main/` holds the root node's files
and children as well as the window's own files. A node's children are its
subdirectories; its `order` file gives their order.

### Paths

A path is written relative to its window everywhere a client sees one.
`f/emp/in` is the node at `$ui/win/main/f/emp/in`; it is the path in that
node's events, the path `focus` reads and takes, and the path in a `set`
line on the window's `ctl`. `.` is the window's root. An overlay's path
starts with `over/`. On the app `ctl`, paths start with the window:
`win/main/f/emp/in`.

`@name` in any path is the unique descendant named `name`. If two nodes
share the name, the walk fails with `in use: ambiguous: total (a/total,
b/total)`. A host must never pick one silently.

A node's path never changes while it exists. Moving a node is a delete
and a create.

**Reserved names.** `over` can't be a child's name. `title`, `state`,
`bounds` and `focus` can: a child with one of those names shadows the
window file, and the window's value stays reachable through the window's
`ctl` (`set . title=...`). Open question 3 asks whether to keep this.

### Node files

Every node has these files. Its type adds more ([components.md](components.md)).

| File | Read | Write |
| --- | --- | --- |
| `type` | the node's type | at creation only; later writes fail with `type is fixed` |
| `style` | style words | replaces them |
| `order` | child names in order, space-separated | reorders; a child not listed is not drawn |
| `tag` | the routing word | sets it |
| `ctl` | help: one `verb [class]` line per verb it takes | command lines (§ Commands) |
| `events` | this node's events | — |
| `tree` | the subtree as a document (§ Documents) | replaces the subtree |
| `bounds` | `x y w h` from the last layout, window-relative | — |
| `on` | the element events this node sends | sets them |

Text-valued properties (`text`, `value`, `label`, `placeholder`, `title`)
are files of their own. A write is the whole value, raw bytes, with no
quoting. A one-line value is read back followed by one newline, which is
not part of the value.

## Commands

### On any `ctl`

Every node's `ctl` and every window's `ctl` take these four commands.
`PATH` is relative to that `ctl`'s node; `.` is the node itself.

| Command | Meaning |
| --- | --- |
| `set PATH [word ...] [prop=value ...] [: style ...]` | Write property files of the node at PATH. Every file is a prop. A missing path fails with `not found`; `set` never creates |
| `new TYPE PATH [word ...] [prop=value ...] [: style ...]` | Make a node at PATH (its parent must exist), set its props, append it to the parent's `order`. `in use` if it exists |
| `delete PATH` | Remove the node and its subtree |
| `tree PATH <<END` … `END` | Replace the subtree at PATH with a document |

**All the lines in one write apply together or not at all.** A host
parses and checks every line, then applies them in order in one step, so
no frame shows half of them. A `ctl` written in several 9P writes (as
`cat` does) applies when the file is closed. A failed write returns the
first error and changes nothing.

**Here-values.** A line ending in `prop=<<WORD` takes the following
lines, up to a line holding only `WORD`, as that prop's value. This is
how multi-line values (`items`, `rows`, `text`) travel through a `ctl`.

```rc
m=$ui/win/main
echo 'set . title=Counter size=320,200 pos=center : v_flex items_center p=24 gap=12
new text n text=0 : text_3xl font_bold
new button inc label=+1 primary tag=inc
set list items=<<END
inbox Inbox
sent Sent
END' >$m/ctl
```

### On the app `ctl`

The app `ctl` takes the node commands with the window as the first path
elements (`set win/main/n text=5`), so a client that can open only one
file can still do everything. It also takes:

| Command | Meaning |
| --- | --- |
| `window NAME [prop=value ...]` | Make a window whose root is an empty `div`. Props are those of § Windows. `in use` if the name is taken, except the hidden default `main` |
| `set ID enabled=on\|off` / `set ID check=on\|off\|mixed` | Change every menu item, button and binding for action `ID`. A first word that isn't a path (doesn't start with `win/`) names an action |
| `ask close quit` / `ask none` | Opt into answering requests (§ Requests) |
| `begin` / `commit` / `abort` | A batch on this connection (§ Batches) |
| `theme load PATH` | Load a theme file in the host's format |
| `quit` | Quit now |

### Batches

`begin` freezes what the client's windows draw. Writes still apply and
reads show them; `commit` makes them visible in one frame and `abort`
discards them. A batch belongs to one 9P connection. A batch left open
for 2 seconds is committed and `trace` logs `batch timeout`. Most updates
should be one `ctl` write instead.

### Creating nodes

There are four ways, and all produce the same tree: `mkdir` (an empty
`div`; write `type` before the next frame to change it), `new` on any
`ctl`, writing a document to `tree`, or `tree PATH <<END` on a `ctl`.
`rm -r` on a node, or `delete PATH`, removes it.

## Words and quoting

There is one quoting rule, `tokenize`. Three conventions keep quotes
rare in `new` lines, `set` lines and documents:

- **A lone `:` starts the style.** Everything after it is style words,
  unquoted. A `:` inside a word (`tag=open:42`, `hover:bg=accent`) is
  not the separator.
- **A bare word is a boolean, a flag or a variant.** `stripe` means
  `stripe=on`; `secret` sets an input's flag; `primary` sets a button's
  variant. Which bare words a type takes is in its descriptor. Any other
  bare word fails with `bad value`.
- **Data lines need no tabs.** In data files (`items`, `rows`, ...), a
  line with a tab is tab-separated fields; a line without one is words.

Value forms used across the spec:

| Form | Written as | Example |
| --- | --- | --- |
| Boolean | `on` / `off`, or a bare word for `on` | `enabled=off`, `stripe` |
| Number | decimal, optional `-` and fraction | `w=240`, `x=-12` |
| Point, size | `a,b` | `pos=40,12`, `size=800,600` |
| Rectangle in a file | `x y w h` | a `bounds` file |
| Rectangle in an attribute | `x,y,w,h` | `rect=0,20,1024,748` |
| List | values joined by `,`, no spaces | `sel=a,b` |

## Style

A `style` file holds style words separated by blanks: `name`, `name=n`
(pixels), `name=n%`, `name=nrem`, `name=token` (a theme token),
`name=#rrggbb[aa]`, `name=a,b`, and state forms `hover:word`,
`active:word`, `focus:word`, `disabled:word`. The vocabulary is the
host's and is listed in `$ui/style/words`; an unknown word fails the
write with `unknown style word`, and a style write never half-applies.

Every host must accept the **portable words**, which are enough to lay
out any screen:

```text
flex flex_row flex_col v_flex h_flex flex_1 flex_wrap flex_none
items_start items_center items_end items_stretch items_baseline
justify_start justify_center justify_end justify_between
gap= p= px= py= pt= pb= pl= pr= m= mx= my=
w= h= min_w= min_h= max_w= max_h= size_full w_full h_full
absolute relative top= left= right= bottom=
overflow_hidden overflow_y_scroll overflow_x_scroll
bg= text_color= border_1 border_color= rounded_sm rounded_md rounded_lg
text_xs text_sm text_base text_lg text_xl font_semibold font_bold
text_left text_center text_right truncate
```

`absolute` with `left=` and `top=` places a node by coordinates, so
rectangle-based layouts (classic dialog resources) still have a form.
A host may accept many more words (GPUI's whole `Styled` vocabulary, for
uitreefs).

**Theme.** `theme/tokens` holds `name value` lines; writing a line
changes one token everywhere at once. `theme/mode` is `light` or `dark`.
`theme/name` selects a named theme the host has. The portable token names
are `background foreground muted muted_foreground primary
primary_foreground accent accent_foreground border ring danger success
warning radius`.

## Windows

The `main` window exists before the client runs, hidden until its root
has content or it gets `show`, so a client that can open only fixed
files needs no setup. **Closing the last window quits** the app, unless
the client asked to answer `close` (§ Requests).

Window props, on `window NAME ...` or `set . ...` on the window's `ctl`:
`title=text`, `size=w,h`, `min=w,h`, `max=w,h`, `pos=x,y|center`,
`kind=normal|dialog`, `resizable=on|off`, `focus=PATH`.

Window `ctl` verbs, beyond the node commands:

| Verb | Meaning |
| --- | --- |
| `show` | Show a hidden window now |
| `activate` | Bring to front and take key focus |
| `close` | Close as the close button would; a `close` request if asked |
| `destroy` | Close now, without asking |
| `state normal\|min\|max\|full` | Change the state |
| `notify text [type=info\|success\|warning\|error]` | A transient notification inside the window |
| `ask close` / `ask none` | Opt this window in or out of `close` requests |

Window files: `title` (read and write), `bounds` (`x y w h`, read), `state`
(read), `focus` (the focused node's path; write a path to move focus).

The [shell layer](shell.md) adds platform window features (frameless,
always on top, tray, native dialogs) under `$desk`.

## Overlays

Overlays live in their window's `over/` directory, because they draw
above the node tree. Each is still a node, made with `new` on
`over/ctl` or the window's `ctl` (`new alert-dialog over/confirm ...`).
Writing `open` to its `ctl` shows it and `close` hides it. Which overlay
types exist is up to the host's `overlay` profile ([components.md](components.md#profiles)).

## Events

Events are lines on `events` files. Every line starts with three
positional words, then attributes, then `seq=`:

```text
name  key  path  attr=value ...  seq=N
```

| Word | Meaning |
| --- | --- |
| `name` | the event: `click`, `change`, `action`, `close`, ... |
| `key` | the routing word: the node's `tag`, inherited from the nearest tagged ancestor; for `action`, the action ID; `-` if none |
| `path` | the node's path relative to its window; `.` the window; `over/x` an overlay; `-` app-level |

```text
click save f/ok/save win=main seq=118
change - prefs/lang/in win=main value=go seq=119
action save src win=main via=key seq=120
close - . win=main via=titlebar seq=121
```

**Attribute values are always one word.** Text that can hold blanks is
read from its file. So splitting on blanks is always correct: `$ev(2)` in
rc, `$2` in awk, `strings.Fields(line)[1]` in Go.

Attributes every host sends where they apply: `win=` (the window), `via=`
(where it came from: `user`, `key`, `menu`, `ctl`, `titlebar`), `seq=`
(last). Events caused by the client's own writes carry `via=ctl`, so a
client can skip its echoes.

### Subscriptions

- `$ui/events` carries every event in the app, a window's `events` that
  window's, a node's `events` that node and its descendants.
- **Each open is its own subscription**, with its own queue. Two readers
  see the same lines.
- The first line of every subscription is `resync - - seq=N`.
- When the window or node goes away: `gone - - seq=N`, then end of file.
  When the app quits, every subscription ends with end of file.
- **Any read size works.** A read returns as many whole lines as fit; a
  line longer than the read comes back over several reads. rc's `read`
  and awk's `getline <file` read `events` directly.
- `seq` comes from one counter per host and increases by at least one
  per event, so the same event has the same `seq` in every file it
  appears in, and lines from several files can be merged.

### Two kinds of event

| Kind | Examples | When the reader is slow |
| --- | --- | --- |
| **State** | `change`, `select`, `focus`, `blur`, `resize`, `move`, `scroll`, `hover` | **Coalesced.** A new event replaces a queued one with the same name about the same node and moves to the back. The queue can't grow without bound |
| **Action** | `click`, `submit`, `open`, `action`, `confirm`, `cancel`, `close`, `quit`, `key`, `drop`, `error`, requests | **Never dropped.** Queued in order, at least 4,096 per subscription. Past that the reader gets `lost - - n=N` and is treated as not answering |

A coalesced event takes the position of its newest copy, so a client
never sees a `change` after the `submit` that came from it. Each type's
descriptor says which kind each of its events is.

### Making an element send events

A raw element sends nothing unless asked. Its `on` file lists the
element events to send: `click`, `hover`, `mouse_down`, `mouse_up`,
`move`, `scroll`, `key`, `focus`, `blur`, `drop`, `drag`. `on=` sets it
at creation.

## Requests

Some events ask the client to decide: closing a window, quitting,
closing a dialog, accepting a drop. **Requests are opt-in.** By default
the host applies the default answer at once.

A client that wants to answer writes `ask close quit` to the app `ctl`
(or `ask close` to a window's). Then, while that client has an `events`
file open, the host sends the request and waits for an answer on the
node's or app's `ctl`: `close`, `keep`, `accept` or `refuse`, with
`seq=` of the request. After 5 seconds with no answer, or at once when no
`events` file is open, the host applies the default.

| Request | Default |
| --- | --- |
| `close - . win=main` | the window closes |
| `quit - -` | the app quits |
| `close - over/x` (dialog `ask`) | the overlay closes |
| `drop KEY PATH drag=N` | refused unless the node has a `drop` file ([transfer.md](transfer.md)) |

## Keys, actions and menus

**Actions** are named intents. A key binding, a menu item and a button
tagged with the same word all arrive as the same key in word 2, so one
branch handles all of them.

**`keys`** holds one binding per line:

```text
cmd-s        save
cmd-shift-p  palette
escape       dismiss   context=editor
```

Keystrokes are modifiers joined by `-` and a key: `cmd ctrl alt shift`
and `super`, then a character or a key name (`enter escape tab space
backspace delete up down left right home end pageup pagedown f1`…`f12`).
**`cmd` names the host's command modifier**, which the host states in
`version` (`cmdkey super` on 9/UX, `cmdkey cmd` on macOS, `cmdkey ctrl`
elsewhere). A node's `context` file sets a key context, so `context=`
bindings apply only while focus is inside it.

A binding no built-in behavior handles comes to the client as
`action ID PATH via=key`, where `PATH` is the focused node.

**`menu/`** sets the app's menus. `menu/bar` lists menu names in order;
each `menu/NAME` file holds item lines:

```text
item new    label=New      key=cmd-n
item open   label=Open…    key=cmd-o
sep
sub recent  label='Open Recent'
  item a    label=a.txt
sub share   label=Share    menu=share
item quit   label=Quit     key=cmd-q   enabled=off
```

`sep` is a separator. `sub` opens a submenu, either the indented items
under it or another menu file named by `menu=`. Item attributes:
`label`, `key`, `enabled`, `check` (`on`, `off`, `mixed`), `icon`.
Choosing an item sends `action ID - via=menu`. Context menus and menu
buttons take the same grammar in their `menu` file.

## Documents

Every node has a `tree` file. Reading it prints the subtree as an
indented document; writing it replaces the subtree in one step. A host
keeps any child whose name and type match, so focus, scroll and editor
state survive a rewrite.

```text
div root  : v_flex size_full p=24 gap=16
  text title  text='Sign in'  : text_xl font_semibold
  form f
    field user  label=Email
      input in  placeholder=you@example.com
    field go
      button submit  label='Sign in'  tag=login  : primary w_full
```

Each line is `TYPE NAME [word ...] [prop=value ...] [: style ...]`, two
spaces of indent per level, with here-values for long text. Reading a
`tree` gives back the same format, so `cat tree >screen.ui` saves a
screen and writing it back restores it. A `.ui` file is this format.

## Clipboard

`$ui/clip` is the platform clipboard as text: read it to paste, write it
to copy. Copying and pasting inside inputs is built in and never
involves the client. The [transfer layer](transfer.md) adds typed
representations.

## Trace

`trace` streams every applied write and every error: a reader gets
recent history first, then each new line as it happens. It is the main
debugging tool. Values of `secret` inputs are logged as `value=<secret>`.

## Errors

A failed write, open or read returns a 9P error starting with one of
these phrases, optionally followed by `: ` and detail for people.
Programs match on the phrase.

| Phrase | When |
| --- | --- |
| `unknown command` | a verb this `ctl` doesn't take |
| `bad syntax` | quoting, a here-value, or `prop=value` that doesn't parse |
| `bad value` | a value of the wrong form or out of range; a bare word the type doesn't take |
| `unknown type` | a type not in `types/`, or a child the parent can't hold |
| `unknown style word` | a word not in `style/words`, or not valid on this type |
| `type is fixed` | writing `type` after creation |
| `not found` | a path, node, action or item that doesn't exist |
| `in use` | a name that exists; an ambiguous `@name` |
| `disabled` | the target is disabled |
| `permission denied` | the connection's rights don't allow it ([policy.md](policy.md)) |
| `too large` | over a limit |
| `no batch` | `commit` or `abort` with no `begin` |
| `gone` | the object was removed while the file was open |
| `app gone` | any access after the app quit |

**Errors are loud.** A failed write also goes to three places a script
will see, because awk, COBOL and shell redirections often drop write
errors: the host's standard error (`uitree: write win/main/x/text: not
found: x`), `trace` (`error path=... err='...'`), and an `error` event
(`error - x/text win=main code=not_found seq=40`).

## Limits

Hosts must accept at least these. A host may allow more.

| Limit | Minimum |
| --- | --- |
| One `ctl` write | 64 KiB per 9P write; a `ctl` written in pieces applies at close |
| A text property | 1 MiB |
| A data file | 16 MiB |
| Queued action events per subscription | 4,096 |
| Node depth | 64 |

## Version

`$ui/version` describes the host:

```text
uitree 1.0
host uitreefs 0.3
layer core 1.0
layer components 1.0
layer shell 1.0
layer transfer 1.0
profile core
profile form
profile data
cmdkey cmd
feature batch
```

The first line is the protocol name and spec version. Then lines of
`kind value`: `host` (name and version, for people), `layer` (each layer
served and its version), `profile` (each component profile claimed;
[components.md](components.md#profiles)), `cmdkey`, and `feature` for
optional behavior inside a layer. Readers ignore kinds they don't know.

## Open questions

1. **Request timeout.** 5 seconds is a guess. Per request type, or set
   by the client?
2. **Tags with an argument.** `del:t3` in one key word works; should the
   head grow a fourth word?
3. **Shadowed window files.** A child named `title` hides the window's
   `title` file. Is a `.win/` directory cleaner?
4. **`@name` and `@asset`.** The same sigil names a node and an asset.
5. **Portable style words.** Is the list above enough to lay out the 24
   uitreefs examples on a libdraw host?
