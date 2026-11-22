# shell: the app's place on the desktop

**Layer:** `shell 1.0` (draft) · **Mount:** `$desk` · **Required:** no ·
**Conventions:** [README.md](README.md#shared-conventions)

The core layer draws what is inside a window. The shell layer manages
what is around it, as platform objects: native window features, the
app's identity, native dialogs, notifications, a tray icon, global
hotkeys, and facts about the machine. It is the file form of an
Electron-style app shell, after the toolkit-go desktop proposal.

`$desk` uses the core grammar unchanged: the same `ctl` commands by
path, the same event head, the same requests. Many root names are the
same as `$ui`'s and mean the same thing at a wider scope.

A host that serves only this layer, with web views as windows, is a
complete webview app host. With core and components beside it, a window
can mix native nodes and a `web` node.

## The tree

```text
$desk/
    version        shell 1.0 and features
    ctl            app verbs (below)
    events         every shell event
    focus          the focused window's name; write a name to focus it
    keys           global hotkeys: accel action, one per line
    displays       one display per line (read-only)
    power          one line of words (read-only)
    win/
        NAME/      one per window, the same names as $ui/win/NAME
            ctl    show hide focus reload close; set . prop=value
            title  bounds  inner  state  icon
            url  html  script     web content, for a window that is a web view
    tray/
        NAME/      icon  menu  title
    over/
        NAME/      native dialogs: ctl (open, close), value
```

A window is the same object in `$ui/win/NAME` and `$desk/win/NAME`: the
first holds its node tree, the second its platform properties. A window
made in either tree appears in both. `bounds`, `state` and `title` read
the same in both.

## Commands

The root `ctl` takes the core node commands (`set`, `delete` by path
from `$desk`) and these:

| Command | Meaning |
| --- | --- |
| `window NAME [prop=value ...]` | Make a window. With `url=` or `html=`, its content is a web view |
| `tray NAME [prop=value ...]` | Make a tray (menu bar extra) icon |
| `dialog NAME kind=K [prop=value ...]` | Make a native dialog; kinds `message`, `open`, `opens`, `folder`, `save` |
| `popup MENU [at=x,y]` | Show `$ui/menu/MENU` at the pointer or at a point |
| `notify title=T [sub=S] [body=B]` | A platform notification; fire and forget |
| `set . id=ID` | The app's identifier (`dev.example.app`), used for saved state |
| `set . agent` | Don't quit when the last window closes |
| `set . accessory` | No dock icon or app-switcher entry |
| `ask close quit` / `ask none` | As in core |
| `quit` | Quit |

A window's own `ctl` takes `show`, `hide`, `focus`, `reload`, `close` and
`set . prop=value`.

### Window props

Beyond core's `title`, `size`, `min`, `max`, `pos` and `resizable`:

| Prop | Meaning |
| --- | --- |
| `url=U`, `html=H`, `script=S` | Web content. `script` is run on every load. Shorthand for a window whose only child is a `web` node ([components.md](components.md#new-in-this-spec)) |
| `top` | Always on top |
| `frameless` | No title bar or border |
| `transparent` | Transparent background |
| `remember=KEY` | Save and restore bounds under the app `id` and this key |
| `icon` | The window's icon (PNG bytes in the `icon` file) |

### Window files

| File | Read | Write |
| --- | --- | --- |
| `bounds` | outer frame `x y w h` in screen points | `x y w h`; two words move only; `- - w h` resizes only |
| `inner` | content size `w h` | — |
| `state` | `normal`, `min`, `max`, `full` or `hidden` | any of them |
| `title` | the title | replaces it |
| `url` | the current URL | navigates |

## Events

The core head, with the window's name as the key and `win/NAME` as the
path (paths in `$desk` start at the mount).

```text
ready - .
create main win/main x=120 y=80 w=800 h=600
focus main win/main
blur main win/main
move main win/main x=200 y=80
resize main win/main w=1024 h=700
close main win/main                       a request, only after ask close
destroy main win/main
action save win/main via=menu
action quit tray/main via=tray
action summon - via=hotkey key=cmd-shift-space
action copy menu/ctx via=popup
action - menu/ctx via=popup               popup dismissed
answer pick over/pick n=2                 two paths in over/pick/value
answer confirm over/confirm               the button's name in over/confirm/value
```

`move`, `resize`, `focus` and `blur` are state events; the rest are
actions. Menu items, tray items, popup items and hotkeys all arrive as
`action ID ...`, with `via=` saying which, the same event as core's key
bindings.

## Dialogs

A native dialog is made with `dialog`, opened with `open` on its `ctl`,
and answered with an `answer` event. The answer is in its `value` file,
because paths and button labels can hold blanks.

```rc
echo 'dialog pick kind=open title=Import filter=''CSV:csv''' >$desk/ctl
echo open >$desk/over/pick/ctl
# answer pick over/pick n=1 seq=12
cat $desk/over/pick/value
```

Paths a native file dialog returns are in the **host's** filesystem. A
client in an h9 machine reads them through whatever the host maps there;
a host must say how in its own docs. Open question 2.

## Tray

```rc
echo tray main >$desk/ctl
cat icon.png >$desk/tray/main/icon
echo 'item show label=Show
sep
item quit label=Quit' >$desk/tray/main/menu
```

The menu file uses core's item grammar.

## Global hotkeys

`$desk/keys` holds bindings that fire when the app is not focused, in
core's keystroke syntax: `cmd-shift-space summon`. Rewriting the file
replaces the set. A binding arrives as `action summon - via=hotkey`.

## Machine facts

`displays` has one line per display: `name x y w h scale=2`. `power` is
one line: `battery charging percent=82`, or `ac`. Both are read-only;
a `displays` event follows a change.

## Open questions

1. **One mount or two.** Should `$desk` be served inside `$ui` (as
   `$ui/desk/`) so a client that can open one file still reaches it?
2. **Host paths.** A native file dialog returns host paths. Should the
   host copy or map the chosen files into the client's namespace, the
   way uitreefs does for drops?
3. **Saved state.** `remember=` stores bounds. Where a [session](session.md)
   with a metadata service exists, should it store there?
