# session: many apps, one desktop

**Layer:** `session 1.0` (draft) · **Mount:** `$desk` at session level ·
**Required:** no · **Conventions:** [README.md](README.md#shared-conventions)

The shell layer is one app's view of its own windows. The session layer
is the window system's view of **every** app's windows: who has focus,
whose menus the shared menu bar shows, which window is the desktop, and
how a document is launched. It is the file form of 9/UX's `/dev/ux`
([devux.md](https://github.com/progrium/9ux/blob/main/docs/protocols/devux.md)),
restated in the core grammar.

A host serves this layer only where it is the window system. On 9/UX the
rio fork serves it. On macOS, Linux and Windows the platform window
manager does this job, and a uitree host does not serve it.

## Where it is

The session tree is served by the window system and mounted at
`$desk` in every app's namespace, beside (or in place of) the app's own
shell tree. App-level files from [shell.md](shell.md) appear under
`apps/APPID/`; the session-level files are at the root.

```text
$desk/
    version        session 1.0, shell 1.0, features
    ctl            mode, cmdkey, clock, chrome, launch
    events         every window-system change
    focus          the focused window's id
    bar            the foreground app, then its menu names in order
    win/
        ID/        every window in the session, by window id
            title  bounds  state  app  ctl
    desktop/
        ctl        claim, release
        state      the claimed window's id and the desktop rectangle
    apps/
        APPID/     each registered app's shell tree (shell.md)
            menu/  its menus, item lines; bar order in menu/bar
    register       app registration (below)
```

Window ids are the window system's (rio's `winid` on 9/UX). An app's
own name for a window (`main`) is in that app's `$ui`; `win/ID/app` and
`win/ID/name` give the mapping.

## Registration

An app opens `register` and writes `register NAME [title=T]`, then
`window ID [name=N]` for each of its windows. A read of the same fid
returns the app id (`sketch-1`). The registration lives as long as the
fid stays open; closing it removes the app's windows from the bar and
its menus from `apps/`. A uitree host on a session does this for its
client, so the client never sees it.

## Commands

| Command | Meaning |
| --- | --- |
| `mode on\|off` | Session presentation on or off (on 9/UX: the 9/UX mode of rio) |
| `cmdkey super\|alt\|ctrl\|none` | The command modifier for every app's `cmd` bindings |
| `clock on\|off\|at TEXT` | The menu bar clock; `at` freezes it for tests |
| `set win/ID chrome=on\|off\|edge` | Classic window chrome drawn by the window system |
| `set win/ID state=hidden\|normal` and `set win/ID top` | Hide, show, raise any window |
| `launch PATH [with=APP] [workspace=W]` | Open a document or app through the session's launcher (on 9/UX: uxmeta, then the plumber) |
| `invoke APPID ACTION [win=ID]` | Fire an app's action as if chosen from the bar |

`desktop/ctl` takes `claim [ID]` and `release`. The claim belongs to the
fid. While a window holds it, the window system keeps it behind every
other window, sizes it to the screen minus the bar, and gives it the
pointer wherever nothing else is hit.

## Menu bar

The bar shows the session's own menu, the foreground app's title, and
that app's menus from `apps/APPID/menu/`, in `menu/bar` order. The
foreground app is the one owning the focused window. A window with no
app gets only the session menu.

An app's menu files are the same item grammar as `$ui/menu/`; a uitree
host copies its client's `$ui/menu/` there. Choosing an item sends
`action ID - win=NAME via=menu` to the app's `$ui/events`. The app never
sees the clicks.

Shortcuts typed with the command modifier are matched against the
foreground app's items first, and only those; legacy windows keep every
other key.

## Events

```text
new 9 win/9 rect=100,100,400,300 app=sketch-1
focus 9 win/9 app=sketch-1
rect 9 win/9 rect=120,100,400,300
top 9 win/9
hide 9 win/9
close 9 win/9 via=chrome
app 9 win/9 app=sketch-1
delete 9 win/9
desktop 3 desktop win=3
register sketch-1 apps/sketch-1 name=sketch
unregister sketch-1 apps/sketch-1
screen - . rect=0,0,1024,768
mode - . ux=on
```

The key is the window id (or app id), so an rc loop switches on
`$ev(2)` as it does for `$ui`. `focus`, `rect` and `screen` are state
events; the rest are actions. `close` from chrome is a request to the
owning app, delivered to it as core's `close - . win=NAME`; a window with
no app is deleted.

## Pointer routing

Where the session draws a bar and chrome, a pointer event goes to the
first of: the bar, an active drag ([transfer.md](transfer.md)), window
chrome, the topmost window under the pointer, the claimed desktop
window, the window system's background.

## Legacy programs

A window system that serves this layer must keep its existing programs
working. On 9/UX that means rio's own files (`/dev/wctl`, `/dev/mouse`,
`/dev/snarf`) keep their meaning, and windows that never register look
and behave as they always have.

## Open questions

1. **`$desk` or `$wm`.** Session files in `$desk` mean an app's shell tree
   and the session share a root. A separate `$wm` keeps a per-app
   `$desk` from ever seeing other apps' windows.
2. **Launch.** Is `launch` part of the session, or a separate service
   (the plumber, uxmeta) that this layer only names?
3. **Rights.** devux gives every client of rio full power, as `wctl`
   does. Should session verbs carry right classes too, for remote
   sessions?
