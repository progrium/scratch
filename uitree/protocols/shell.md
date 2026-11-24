# shell: the app's place on the desktop

**Layer:** `shell 1.0` (draft) · **Mount:** `$ui` · **Required:** no ·
**Conventions:** [README.md](README.md#shared-conventions)

The core layer draws what is inside a window. The shell layer manages
what is around it, as platform objects: the app's identity, native
window features, native dialogs, notifications, a tray icon, global
hotkeys, documents and URLs handed to the app, and facts about the
machine. It is the file form of an Electron or Tauri app shell, after
the toolkit-go desktop proposal.

Shell has no mount of its own. Its files live in the author's one tree,
`$ui`, beside core's, and use core's grammar unchanged: the same `ctl`
commands by path, the same event head, the same requests, the same
[path rule](core.md#paths) (with `win=` a path is relative to that
window, without it relative to `$ui`). A host lists `layer shell 1.0` in
`version` when it serves these files.

## The tree

```text
$ui/
    app/            id  name  version  icon  agent  accessory  multi  autostart
    sys/            displays  power  os                       (read-only)
    keyring/NAME    secrets kept by the OS, one file each
    tray/NAME/      icon  title  tooltip  menu
    over/NAME/      native dialogs: ctl  value  item/N/
    open/N/         documents and URLs handed to the app
    keys            core's file; lines with the word global are hotkeys
    win/NAME/       core's window directory, plus:
        icon        the window's icon (PNG bytes)
        url  html  script   web content, for a window that is a web view
```

`over/` at the root holds **native** dialogs, which belong to the app;
`win/NAME/over/` holds core's in-window overlays. Events tell them apart
by `win=`: an in-window overlay's events carry it and a native dialog's
don't, even when the dialog is shown as a sheet on a window.

## The app

App-level props are set on the `app` pseudo-node through the app `ctl`,
and each is also a file in `app/`, as core requires of every prop:

```rc
echo 'set app id=dev.example.notes name=Notes agent' >$ui/ctl
cat $ui/app/id
```

| Prop | Meaning |
| --- | --- |
| `id` | The app's identifier. Keys saved state and the single-instance rule (§ Opening documents) |
| `name`, `version` | For the about box and the OS |
| `icon` | The app icon (PNG bytes in `app/icon`) |
| `agent` | Don't quit when the last window closes |
| `accessory` | No dock icon or app-switcher entry |
| `multi` | Allow several running instances for one `id` |
| `autostart` | Start at login. Needs consent: may be refused later with `permission-denied` |

## Commands

The app `ctl` takes core's commands, and these:

| Command | Meaning |
| --- | --- |
| `tray NAME [prop=value ...]` | Make a tray (menu bar extra) icon |
| `dialog NAME kind=K [parent=win/NAME] [prop=value ...]` | Make a native dialog: `message`, `open`, `folder` or `save` (fallback: refused with `bad value`) |
| `popup MENU [at=x,y]` | Show `menu/MENU` at the pointer, or at a point in desktop space |
| `notify NAME title=T [sub=S] [body=B] [action=ID]` | A platform notification. Clicking it sends `action ID - via=notify`, or `action NAME - via=notify` without `action=`. The first `notify` may be refused later with `permission-denied` ([core.md](core.md#errors)) |
| `open URL` | Open a URL in the host's default handler (the browser, a mail client). May fail with `permission denied` or `unsupported` |
| `reveal file/ID` | Show a handle's file in Finder, Explorer or the file manager. May fail with `permission denied` or `unsupported` |
| `delete tray/NAME` / `delete over/NAME` | Remove one |

A window's `ctl` also takes `hide`, `reload` (web content) and `set .
prop=value` with the props below.

### Window props

Beyond core's window props:

| Prop | Meaning |
| --- | --- |
| `url=U`, `html=H`, `script=S` | Web content, run on every load. Shorthand for a window whose only child is a `web` node ([components.md](components.md#new-in-this-spec)) |
| `top` | Always on top |
| `frameless` | No title bar or border (the same as `titlebar=none`) |
| `transparent=on\|off\|blur` | The window paints no background of its own, so whatever the tree leaves unpainted shows the desktop behind it; `blur` blurs what shows through where the platform can (fallback: `on`). A root or node with its own `bg` still paints. Settable on a shown window. With `titlebar=none`, a chromeless overlay |
| `click-through=on\|off` | The whole window ignores the pointer: clicks, scrolls and hover go to whatever is behind it. Keys are unchanged. Settable on a shown window, so an overlay can turn input back on |
| `remember=KEY` | Save and restore bounds under the app `id` and this key |

Writing a window's `bounds` takes desktop space; two words move only and
`- - w h` resizes only. On hosts without `feature position`, x and y are
accepted and ignored and `bounds` reads `- - w h` ([core.md](core.md#coordinates)).

## Events

Window events carry `win=` and the path `.`; app-level events carry no
`win=` and a path relative to `$ui`.

```text
create - . win=main x=120 y=80 w=800 h=600
focus - . win=main
blur - . win=main
move - . win=main x=200 y=80 display=1 scale=2
resize - . win=main w=1024 h=700 display=1 scale=2
destroy - . win=main
action save - via=menu win=main
action quit tray/main via=tray
action summon - via=hotkey
action copy menu/ctx via=popup
action - menu/ctx via=popup                  popup dismissed
action report - via=notify                   a click on notify NAME action=report
answer pick over/pick n=2                    two handles in over/pick/item/
answer confirm over/confirm                  the button's name in over/confirm/value
open - open/3 n=1 via=file
displays - sys
```

`move`, `resize`, `focus`, `blur` and `displays` are state events; the
rest are actions. Menu items, tray items, popup items, notifications and
hotkeys all arrive as `action ID ...` with `via=` saying which, the same
event as core's key bindings.

## Dialogs

A native dialog is made with `dialog`, opened with `open` on its `ctl`,
and answered with an `answer` event.

- `kind=message` takes `title=`, `body=`, `level=info|warning|error` and
  `buttons=ok|okcancel|yesno|yesnocancel`. The chosen button's name is in
  `value`.
- `kind=open` takes `title=`, `filter='Name:ext,ext'`, `multiple`, and
  `access=rw` for a writable handle (a document editor needs it to save
  back). The answer's `n=` is the number of files; each is a **file
  handle** at `over/NAME/item/N/file`, a line holding `file/ID`
  ([transfer.md](transfer.md#host-files)). `n=0` means cancelled.
- `kind=folder` gives one handle whose `dir/` holds the folder.
- `kind=save` takes `title=` and `file=` (a suggested name) and gives one
  handle that is new, empty and writable: the client writes its `data`,
  and the host creates the file when it is closed.

```rc
echo 'dialog pick kind=open title=Import filter=''CSV:csv''' >$ui/ctl
echo open >$ui/over/pick/ctl
# answer pick over/pick n=1 seq=12
h=`{cat $ui/over/pick/item/0/file}
cat $ui/$h/data
```

The client never sees a host path, so the same code works for a client
in an h9 machine, in a Linux view, or attached remotely.

`parent=win/NAME` shows the dialog as a sheet on that window where the
platform has sheets. Its events still carry no `win=`.

## Opening documents and URLs

Every document or URL the OS hands to the app arrives as one action
event, `open`, with the payload in an offer under `$ui/open/N/`. That
includes the first launch, so an app has one code path for both.

```text
open - open/3 n=2 via=file seq=40

$ui/open/3/
    types        file, or uri
    data/uri     one URI per line, for via=link
    item/N/file  file/ID handles, for via=file
    argv         the launching command's arguments, for via=instance
```

| `via=` | When |
| --- | --- |
| `file` | the OS opened a document with this app (double-click, Open With, a drop on the dock icon) |
| `link` | a URL in a registered scheme was opened |
| `instance` | the app was launched again while running; `n=0` with only `argv` if it carried no documents |
| `reopen` | the dock icon was clicked while no window is visible (macOS) |

An unknown `via` is an `open` from an unknown source.

- **Held until read.** An `open` that arrives before any client has an
  `events` file open is held, and delivered after `resync` to the first
  subscription ([core.md](core.md#subscriptions)).
- **Defaults.** For `instance` and `reopen`, the host shows and
  activates `main` unless the client has written `ask open`. `file` and
  `link` have no default. `open/N` is removed once every subscription has
  read past its event.
- **One instance per app id.** When `app/id` is set, a second launch is
  delivered to the running app as `open via=instance`, and no second
  client starts. `set app multi` opts out. Without an `id`, each launch
  is separate.
- **argv stays the client's.** Arguments typed on a command line go to
  the client as its argv. Documents and URLs from the OS never do. File
  types and URL schemes are declared in the app's packaging, not at run
  time, because the OS reads them at install.

## Tray

```rc
echo tray main >$ui/ctl
cat icon.png >$ui/tray/main/icon
echo 'item show label=Show
sep
item quit label=Quit' >$ui/tray/main/menu
```

The menu file uses core's item grammar, roles included. On a platform
without tray icons, `tray` fails with `unsupported`.

## Global hotkeys

Global hotkeys are lines in core's `keys` file with the word `global`:
`cmd-shift-space summon global`. They fire when the app is not focused
and arrive as `action summon - via=hotkey`. A hotkey the OS refuses (it
clashes, or needs consent) is reported as an `error` event.

## Keyring

`$ui/keyring/NAME` holds secrets in the OS's credential store (the macOS
Keychain, Windows Credential Manager, the Secret Service on Linux),
filed under the app `id`. Writing a file stores the secret, reading it
returns it, and `rm` deletes it. `ls` lists the names.

Keyring values are always secret: never written to `trace` (which logs
`value=<secret>`), and empty in the public view. It is where a token from
a browser sign-in goes, after arriving through `open via=link`, instead
of a plain file in the client's machine. A host without a credential
store fails writes with `unsupported`.

## Machine facts

`sys/displays` has one line per display, in desktop space:

```text
1  0 0 1512 982       scale=2 work=0,38,1512,944 primary name='Built-in Retina Display'
2  1512 -200 2560 1440 scale=1 work=1512,-200,2560,1415 name=DELL
```

The first word is a display id, stable while the display is attached.
`x y w h` place it in desktop space. `work=` is the area left after the
menu bar, dock or taskbar. When displays have different scales, the host
keeps each display's size in that display's own points, so desktop space
can show small gaps or overlaps; a point belongs to the first display
listed whose rectangle contains it. A `displays - sys` event follows any
change.

`sys/power` is one line: `battery charging percent=82`, or `ac`.

`sys/os` is one line of attributes:
`platform=macos arch=arm64 version=15.2 locale=en-US`. `platform` may
grow (fallback: unknown platform). A `sys - sys` event follows a change
of locale. Dates, numbers and shortcut labels depend on these.

## Rights

Under the [policy layer](policy.md), shell verbs carry right classes like
any other: `notify`, `popup`, `open` and a window's `hide` are
`activate`. `tray`, `dialog`, `reveal`, `delete` of either, every `app`
prop and `keyring/` are author-only, so the public view can watch them
but never change them. `keyring/` reads empty in the public view.

## Next, additive

Not needed for 1.0, and each can be added in a minor version:

- `app/badge` and `app/progress` on the dock or taskbar icon, and an
  `attention` verb that bounces or flashes it, for chat-style apps.
- `power` events (`sleep`, `wake`, `lock`) and `set app awake` to keep
  the machine awake, for apps that sync or play media.
- Updates matter as much as anything here, but belong to the launcher
  and packaging, not the protocol.

## Open questions

1. **Keeping file access.** Should a handle's `ctl` take `keep`, to keep
   access across launches (macOS security-scoped bookmarks, Tauri's
   persisted scope)? IDs are already opaque, so it can be added later.
2. **Saved state.** `remember=` stores bounds. Where a [session](session.md)
   with a metadata service exists, should it store there?
