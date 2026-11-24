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
    menu/          bar, the host's default menus (app edit window), and the app's own
    theme/         mode  pref  tokens  name  names
    asset/         named files a node can refer to as @name
    types/         the component types this host builds (components.md)
    style/words    the style words this host accepts
    win/
        main/      the window named main, which is also its root node
            ctl  events  tree  type  style  order  tag ...   root node files
            title  bounds  inner  state  focus               window files
            over/  in-window overlays: dialogs, sheets, popovers
            body/  a child node
                type  text  ...

    clip  clipdata/  drag/N/  file/ID/                     transfer layer
    app/  sys/  tray/NAME/  over/NAME/  open/N/              shell layer
```

The last two lines are served only by hosts that implement those optional
layers ([transfer.md](transfer.md), [shell.md](shell.md)); `version` says
which. Everything an app's author touches is in this one tree.

A window **is** its root node: `$ui/win/main/` holds the root node's files
and children as well as the window's own files. A node's children are its
subdirectories; its `order` file gives their order.

### Paths

**One rule decides what a path is relative to: with `win=`, a path is
relative to that window; without it, a path is relative to `$ui`.** This
holds in events, in `trace` and in errors.

```text
click save f/ok/save win=main seq=118          a node in window main
move - . win=main x=200 y=80 display=1 seq=119 the window itself
action quit tray/main via=tray seq=120         a tray item (shell)
answer pick over/pick n=2 seq=122              a native dialog (shell)
open - open/3 n=1 via=file seq=123             a document handed to the app (shell)
```

Inside a window, then, a path is written relative to that window.
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
| `bounds` | `x y w h` from the last layout, in window space (§ Coordinates) | — |
| `on` | the element events this node sends | sets them |
| `tooltip` | the node's tooltip text; empty for none | sets it; empty removes it (§ Overlays) |

Text-valued properties (`text`, `value`, `label`, `placeholder`, `title`)
are files of their own. A write is the whole value, raw bytes, with no
quoting. A one-line value is read back followed by one newline, which is
not part of the value, and a write drops one trailing newline, so `echo x
>text` stores `x`. An empty value reads as nothing. Every file that holds
one line follows the same rule: `type`, `order`, `tag`, `style`, `on`,
and the window's `title`, `state`, `focus`, `bounds` and `inner`. Data
files are lines and follow it too.

## Coordinates

Every position and size is in **logical points** (AppKit points, CSS
pixels, GPUI `Pixels`), as a **whole number**, in one of three named
spaces. Device pixels appear only as a `scale` factor. Each file and
attribute is in one fixed space, so a client converts only if it wants
to.

| Space | Origin | Used by |
| --- | --- | --- |
| Desktop | top-left of the primary display; negative values are left of and above it | `sys/displays`, a window's `bounds`, `move` events, `popup at=` (shell) |
| Window | top-left of the window's content area, below a system title bar; with `titlebar=custom` or `none`, the top of the window | node `bounds`, `pt=` on pointer and drop events |
| Node | top-left of the node | canvas ops and canvas hits only |

In every space x grows right and y grows down.

**Whole numbers.** Hosts round to whole points everywhere except canvas
ops, which take decimals. A host must not send `12.5` in `bounds` or
`pt=`. This keeps arithmetic in rc and awk exact.

**Scale.** A display has a `scale` (device pixels per point), listed in
`sys/displays` by hosts with the shell layer. `move` and `resize` events
on a window carry `display=` and `scale=`, so a client that draws bitmaps
knows when to redraw. An image's logical size is its pixel size divided
by its `scale` (default 1): `img src=@logo scale=2`.

**Positions the platform hides.** Some platforms (Wayland) neither report
nor accept a window's position. There, `bounds` reads `- - w h`, `move`
events are not sent, writes to x and y are accepted and ignored, and
`pos=` hints are passed to the compositor. A host that knows positions
lists `feature position` in `version`.

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
lines, up to a line holding only `WORD`, as that prop's value: the lines
joined with newlines, with no trailing newline. In a document the value's
lines and `WORD` are not indented, and a line with several here-values
takes their bodies in order (`columns=<<END rows=<<END2`). This is how
multi-line values (`items`, `rows`, `text`) travel through a `ctl`.

```rc
m=$ui/win/main
echo 'set . title=Counter size=320,200 pos=center : v-flex items-center p=24 gap=12
new text n text=0 : text-3xl font-bold
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
| `ask close quit open` / `ask none` | Opt into answering requests (§ Requests); `open` is defined by the shell layer |
| `begin` / `commit` / `abort` | A batch on this connection (§ Batches) |
| `theme name NAME` | The same as writing `NAME` to `theme/name` |
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
flex flex-row flex-col v-flex h-flex flex-1 flex-wrap flex-none
items-start items-center items-end items-stretch items-baseline
justify-start justify-center justify-end justify-between
gap= p= px= py= pt= pb= pl= pr= m= mx= my=
w= h= min-w= min-h= max-w= max-h= size-full w-full h-full
absolute relative top= left= right= bottom=
overflow-hidden overflow-y-scroll overflow-x-scroll
bg= text-color= border-1 border-color= rounded-sm rounded-md rounded-lg
text-xs text-sm text-base text-lg text-xl font-semibold font-bold
text-left text-center text-right truncate
```

`absolute` with `left=` and `top=` places a node by coordinates, so
rectangle-based layouts (classic dialog resources) still have a form.
A host may accept many more words (GPUI's whole `Styled` vocabulary, for
uitreefs), always in the dashed spelling: uitreefs maps `flex-col` to GPUI's
`flex_col`. The portable words follow Tailwind's class names where one
exists.

**Theme.** `theme/tokens` holds `name value` lines; writing a line
changes one token everywhere at once. Light and dark are split into what
the app asked for and what is drawn:

| File | Read | Write |
| --- | --- | --- |
| `theme/pref` | `system`, `light` or `dark` | the same |
| `theme/mode` | the mode in effect: `light` or `dark` (may grow; fallback `light`) | `light`, `dark` or `system`, which sets `pref` |

**The default preference is `system`**, so an app follows the OS
appearance unless it writes `light` or `dark`. A `theme - - mode=dark
via=system seq=N` event follows every change to the effective mode,
whether the user changed the OS setting (`via=system`) or the client
wrote `pref` (`via=ctl`); it is a state event. Other OS appearance
settings may appear later as read-only tokens (`system-accent`,
`reduced-motion`, `high-contrast`). The portable token names
are `background foreground muted muted-foreground primary
primary-foreground accent accent-foreground border ring danger success
warning radius`.

**Look tokens.** Besides colors, every host has six tokens for the rest of
the look, in `theme/tokens` like the colors and written the same way:

| Token | Value | Default | |
| --- | --- | --- | --- |
| `radius` | points | `6` | corner radius of controls; `0` squares them |
| `radius-lg` | points | `8` | corner radius of large surfaces (dialogs, notifications) |
| `font-size` | points | `16` | the base text size |
| `font-family` | one line of text | `system` | the UI font; `system` is the host's own |
| `spacing` | points | `4` | one step of the spacing scale: `p-4` is 4 steps, so 16 points by default |
| `shadow` | `on` or `off` | `on` | whether controls and surfaces draw shadows |

A value of the wrong kind fails the write with `bad value`. `spacing`
scales the scale words (`p-4`, `gap-2`, `w-8`) and `rem` lengths, as a
rem is four steps; lengths written in points (`p=16`) don't change. Each
host maps these to its own units and shows what it can: the terminal host
turns `spacing` into cells and squares its box corners at `radius 0`,
and has no use for font or shadow. A named theme may set look tokens too
(several GPUI Kit themes turn `shadow` off).

**Named themes.** A named theme is a palette: a value for some of the
color tokens, for one mode. The host lists the ones it has in
`theme/names`, read-only, one line per theme: its name (quoted when it
has blanks), then `mode=light` or `mode=dark`, then `family=NAME` when it
belongs to a family, a set of themes that go together.

```text
'Catppuccin Latte' mode=light family=Catppuccin
'Catppuccin Mocha' mode=dark family=Catppuccin
'Tokyo Night' mode=dark family=Tokyo
```

Writing a theme's name or a family's name to `theme/name` selects it;
writing nothing goes back to the host's default look. A name that is
neither is refused with `not found` and changes nothing. Reading
`theme/name` gives what was written.

- A **family** name picks the family's first theme for each mode, and
  follows `theme/mode`: `Catppuccin` draws Latte in light mode and Frappe
  in dark.
- A **theme** name picks that theme whatever the preference.
- If what was picked has no theme for the preferred mode (`Tokyo Night`,
  or `Tokyo`, while `pref` is `light`), the mode in effect becomes the one
  it has. `theme/mode` reads that mode, the `theme` event follows as for
  any change to the mode in effect (`via=ctl`), and `theme/pref` keeps
  what the app asked for, so going back to the default restores it.

A token's value is, first, what the app wrote to `theme/tokens`; then the
named theme's; then the host's default for the mode. `theme/tokens`
reads the values in effect, so an app reads a theme's colors there. The
names are the host's: hosts that share a theme set (the GPUI and terminal
hosts both have GPUI Kit's) share its names, and an app written for one
runs on the other. A host with no named themes has an empty
`theme/names`, and `theme/name` takes only the empty name.

## Windows

The `main` window exists before the client runs, hidden until its root
has content or it gets `show`, so a client that can open only fixed
files needs no setup. **Closing the last window quits** the app, unless
the client asked to answer `close` (§ Requests).

Window props, on `window NAME ...` or `set . ...` on the window's `ctl`:
`title=text`, `size=w,h`, `min=w,h`, `max=w,h` (points), `pos=x,y` (desktop
space) or a placement hint (`center`, `top-right`, `tray`, `display:2`)
the host resolves, `kind=normal|dialog` (fallback `normal`),
`titlebar=system|custom|none`, `resizable=on|off`, `focus=PATH`, and the
shell layer's `transparent=on|off|blur` and `click-through=on|off`
([shell.md](shell.md#window-props)).

Window `ctl` verbs, beyond the node commands:

| Verb | Meaning |
| --- | --- |
| `show` | Show a hidden window now |
| `activate` | Bring to front and take key focus |
| `close` | Close as the close button would; a `close` request if asked |
| `destroy` | Close now, without asking |
| `state normal\|min\|max\|full\|hidden` | Change the state. `state` may grow; a reader treats an unknown value as `normal` |
| `notify text [type=info\|success\|warning\|error]` | A transient notification inside the window |
| `ask close` / `ask none` | Opt this window in or out of `close` requests |

Window files: `title` (read and write); `bounds`, the outer frame `x y w
h` in desktop space (writable with the shell layer: two words move, `- -
w h` resizes); `inner`, the content size `w h`; `state` (read); `focus`
(the focused node's path; write a path to move focus).

A change of `state` sends `state - . win=main value=max via=V`, a state
event, with `via=ctl` when the client caused it.

The [shell layer](shell.md) adds platform window features (frameless,
always on top, tray, native dialogs) in this same tree.

## Overlays

Overlays live in their window's `over/` directory, because they draw
above the node tree. Each is still a node, made with `new` on
`over/ctl` or the window's `ctl` (`new alert-dialog over/confirm ...`).
Writing `open` to its `ctl` shows it and `close` hides it. Which overlay
types exist is up to the host's `overlay` profile ([components.md](components.md#profiles)).

**Tooltips.** Any node can have a tooltip without an overlay: its
`tooltip` file holds the text, and the host shows it when the pointer
rests on the node, with no round trip to the client.

```rc
echo 'Save file' >$ui/win/main/save/tooltip
echo 'new button open label=Open tooltip=''Open a file''' >$ui/win/main/ctl
```

A `tooltip` file is the same as a `tooltip` overlay anchored to the node
with its defaults (`placement=top open-delay=500`), and a host draws the
two alike. A client that wants another placement or delay, or wants to
open and close the tip itself, makes the overlay instead
([components.md § Tooltips](components.md#tooltips)). Both kinds send no
events: the host opens a tip on hover and closes it when the pointer
leaves or presses the anchor. A host without the `overlay` profile still
keeps the file, and may draw it any way it can or not at all.

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
change - prefs/lang/in win=main value=go via=user seq=119
action save src win=main via=key seq=120
close - . win=main via=titlebar seq=121
```

**Attribute values are always one word.** Text that can hold blanks is
read from its file. So splitting on blanks is always correct: `$ev(2)` in
rc, `$2` in awk, `strings.Fields(line)[1]` in Go.

Attributes every host sends where they apply: `win=` (the window, which
also makes `path` window-relative), `via=` (where it came from: `user`,
`key`, `menu`, `ctl`, `titlebar`, ...; an unknown value means an unknown
origin), `seq=` (last).

The head is three words and stays three words. A routing word that needs
an argument puts it in an attribute (`click del list/t3 win=main arg=t3`) or in the
tag itself (`del:t3`), never in a fourth positional word. Events caused by the client's own writes carry `via=ctl`, so a
client can skip its echoes.

### Subscriptions

- `$ui/events` carries every event in the app, a window's `events` that
  window's, a node's `events` that node and its descendants.
- **Each open is its own subscription**, with its own queue. Two readers
  see the same lines.
- The first line of every subscription is `resync - - seq=N`.
- **Held events.** An `open` event ([shell.md](shell.md#opening-documents-and-urls))
  that arrives while no subscription is open is held, and delivered right
  after `resync` to the first subscription. This is the one exception to
  "a subscription sees only what happens after it opens"; without it, the
  documents of a first launch would be lost.
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
element events to send: `click`, `hover`, `mouse-down`, `mouse-up`,
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
| `open - open/N via=instance\|reopen` | the host shows and activates `main` ([shell.md](shell.md#opening-documents-and-urls)) |

## Keys, actions and menus

**Actions** are named intents. A key binding, a menu item and a button
tagged with the same word all arrive as the same key in word 2, so one
branch handles all of them.

**`keys`** holds one binding per line:

```text
cmd-s            save
cmd-shift-p      palette
escape           dismiss   context=editor
cmd-shift-space  summon    global
```

Keystrokes are modifiers joined by `-` and a key: `cmd ctrl alt shift`
and `super`, then a character or a key name (`enter escape tab space
backspace delete up down left right home end pageup pagedown f1`…`f12`).
**`cmd` names the host's command modifier**, which the host states in
`version` (`cmdkey super` on 9/UX, `cmdkey cmd` on macOS, `cmdkey ctrl`
elsewhere). A node's `context` file sets a key context, so `context=`
bindings apply only while focus is inside it.

A binding no built-in behavior handles comes to the client as
`action ID PATH via=key win=NAME`, where `PATH` is the focused node. A
binding with the word `global` fires even when the app is not focused,
on hosts with the shell layer, and arrives as `action ID - via=hotkey`.

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
`label`, `key`, `enabled`, `check` (`on`, `off`, `mixed`), `icon`,
`role`. Choosing an item sends `action ID - via=menu`. Context menus and
menu buttons take the same grammar in their `menu` file. An item whose ID
is `-` has no action of its own.

### Default menus

**The host writes its default menus into `menu/` at start**, so they show
in the tree like everything else, and the client keeps, edits or replaces
them. On a host with an app menu bar (macOS, and 9/UX through the
session):

```text
menu/bar      app edit window

menu/app      item - role=about
              sep
              item - role=services
              sep
              item - role=hide
              item - role=hide-others
              item - role=show-all
              sep
              item quit role=quit

menu/edit     item - role=undo
              item - role=redo
              sep
              item - role=cut
              item - role=copy
              item - role=paste
              item - role=select-all

menu/window   item - role=minimize
              item - role=zoom
              sep
              item - role=front
```

On hosts where menus belong to windows and most apps have none (Windows,
Linux), `menu/bar` starts empty. Edit roles still work from the keyboard,
because roles are bound to keys whether or not a menu shows them.

- Writing `menu/bar` replaces the bar. On macOS the app menu always comes
  first whatever `bar` says, because the OS requires it; the client edits
  `menu/app` to add items, such as Preferences after About.
- **Roles are performed by the host and send no event.** The set for 1.0
  is `about services hide hide-others show-all quit undo redo cut copy
  paste paste-plain delete select-all minimize zoom fullscreen close
  front window-list help-search`. An unknown role is `bad value`; a role
  the platform lacks is ignored, so one menu file works everywhere.
- `role=quit` goes through the `quit` request and `role=close` through
  `close`, so `ask quit` and `ask close` still get to confirm.
- An item with both an ID and a role (`item quit role=quit`) can be
  enabled, disabled and checked by ID like any other item.
- Edit roles act on the focused input, editor or `web` node.

## Documents

Every node has a `tree` file. Reading it prints the subtree as an
indented document; writing it replaces the subtree in one step. A host
keeps any child whose name and type match, so focus, scroll and editor
state survive a rewrite.

```text
div root  : v-flex size-full p=24 gap=16
  text title  text='Sign in'  : text-xl font-semibold
  form f
    field user  label=Email
      input in  placeholder=you@example.com
    field go
      button submit  primary  label='Sign in'  tag=login  : w-full
```

Each line is `TYPE NAME [word ...] [prop=value ...] [: style ...]`, two
spaces of indent per level, with here-values for long text. Reading a
`tree` gives back the same format, so `cat tree >screen.ui` saves a
screen and writing it back restores it. A `.ui` file is this format.

A host prints a node as `TYPE NAME`, then its bare words (booleans that
are on, flags, variant and size words) in the order they were first set,
then every other prop not at its default as `prop=value` in the order it
was first set, data files included as here-values, then `: style`, with
two spaces between groups. A window's root is named `root`. Printing the
same tree twice gives the same text, so a saved screen compares with
`cmp`.

## Clipboard

`$ui/clip` is the platform clipboard as text: read it to paste, write it
to copy. Copying and pasting inside inputs is built in and never
involves the client. The [transfer layer](transfer.md) adds typed
representations.

## Trace

`trace` streams every applied write and every error: a reader gets
recent history first, then each new line as it happens. It is the main
debugging tool. Values of `secret` inputs are logged as `value=<secret>`.
A reader gets at least the last 1,000 lines of history.

Each line has the event-line style, with paths from `$ui`:

```text
ctl path=win/main/ctl cmd='new text a text=hi'   one per command line of a ctl write
write path=win/main/a/text value=Hello          a file write
mkdir path=win/main/b
remove path=win/main/b
batch timeout
error path=win/main/a/style err='unknown style word: flexx'
```

A value with a newline, or over 64 bytes, is written `len=N` instead. A
secret value is `value=<secret>`, in a `write` and inside `cmd=`.

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
| `permission denied` | the connection's rights don't allow it ([policy.md](policy.md)), or the host's own policy or the user's choice does not: notifications turned off, autostart blocked, a sandbox without host access. A client must expect it from any shell verb |
| `unsupported` | the host serves the layer but can't do this on this platform: a tray on stock GNOME, window position on Wayland, a badge on Linux. Unlike `unknown command`, the verb is real |
| `too large` | over a limit |
| `no batch` | `commit` or `abort` with no `begin` |
| `gone` | the object was removed while the file was open |
| `app gone` | any access after the app quit |

**Errors are loud.** A failed write also goes to three places a script
will see, because awk, COBOL and shell redirections often drop write
errors: the host's standard error (`uitree: write win/main/x/text: not
found: x`), `trace` (`error path=... err='...'`), and an `error` event
(`error - x/text win=main code=not-found seq=40`).

**Refusals that come later.** A verb that needs the user's consent (the
first `notify`, `autostart`, a global hotkey that clashes) returns at once
and reports a later refusal as an `error` event with `code=permission-denied`
or `code=unsupported`, which also goes to standard error and `trace`.

The phrase set is complete as of 1.0: a minor version never adds a
phrase, so a client's error handling can be exhaustive. Detail after the
colon may grow.

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
feature position
```

The first line is the protocol name and spec version. Then lines of
`kind value`: `host` (name and version, for people), `layer` (each layer
served and its version), `profile` (each component profile claimed;
[components.md](components.md#profiles)), `cmdkey`, and `feature` for
optional behavior inside a layer (`position`: the host knows and accepts
window positions in desktop space). Readers ignore kinds they don't know.

## Open questions

1. **Request timeout.** 5 seconds is a guess. Per request type, or set
   by the client?
2. ~~Tags with an argument.~~ Settled: the head never grows a fourth
   word; an argument goes in the tag (`del:t3`) or an attribute.
3. **Shadowed window files.** A child named `title` hides the window's
   `title` file. Is a `.win/` directory cleaner?
4. **`@name` and `@asset`.** The same sigil names a node and an asset.
5. **Portable style words.** Is the list above enough to lay out the 24
   uitreefs examples on a libdraw host?
6. **Echoes from verbs.** Which client verbs send their event with
   `via=ctl` (a window's `close` does; a button's `click`?), and which
   send none (an overlay's `open` and `close`)? The conformance suite
   assumes the first two do and the last doesn't.
7. **Phrases the table doesn't name.** An unknown prop (`not found`?), a
   child the parent can't hold (`unknown type`, though the type exists),
   `begin` inside a batch (`in use`?), an answer to no request (`not
   found`?), a readonly prop (`bad value: read-only`?). The suite's
   assumptions are in tests/conformance/GAPS.md item 26.
8. **`on=` with several events.** The `on` file is blank-separated; is
   `on=click,hover` (the list form) how to set two at creation?
