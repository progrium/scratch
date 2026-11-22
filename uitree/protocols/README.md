# uitree protocols

**Status:** draft 0.1 · 22 November 2026 · nothing here is final

This directory specifies the uitree file protocol: how a program builds,
runs and observes a graphical user interface by reading and writing files
served over 9P. The spec is meant to have more than one host:

- **uitreefs** ([`../../uitreefs`](../../uitreefs)), a GPUI Kit host for
  macOS, Linux and Windows. Its use is an Electron alternative: an app is
  a client in any language plus a host that provides the components.
- **9/UX** ([progrium/9ux](https://github.com/progrium/9ux)), a
  Macintosh-style desktop for 9front, where libux would be the host and
  rio, uxd and clipd serve the session-wide layers.

Neither host is the reference. Where this spec and a host differ, the
host has a bug or the spec has an open question. uitreefs's
[DESIGN.md](../../uitreefs/DESIGN.md) is the closest existing
implementation, and most of the grammar comes from it.

## Layers

The spec is split into layers. Every host implements the first two. The
rest are optional, and a host says which it implements in `version`
([core.md](core.md#version)).

| Layer | Document | Mount | Required | Holds |
| --- | --- | --- | --- | --- |
| Core | [core.md](core.md) | `$ui` | yes | The tree, node files, the `ctl` grammar, events, requests, keys and menus, tree documents, errors, `version` |
| Components | [components.md](components.md) | `$ui/types` | yes | The type descriptor, how a host publishes its types, the standard profiles |
| Shell | [shell.md](shell.md) | `$desk` | no | One app's windows as platform objects: bounds and state, native dialogs, notifications, tray, global hotkeys, displays, power |
| Session | [session.md](session.md) | `$desk` (session level) | no | Every app's windows, focus across apps, the shared menu bar, the desktop layer, chrome, launching |
| Policy | [policy.md](policy.md) | `/mnt/ux` | no | A public view of an app's tree, rights per verb, grants, redaction, a broker that aggregates apps |
| Transfer | [transfer.md](transfer.md) | `$ui/drag`, `$ui/clip*` | no | Typed drag and drop and a typed clipboard, bytes not paths |

Which hosts are expected to implement what:

| Layer | uitreefs (Electron alternative) | 9/UX (libux on 9front) |
| --- | --- | --- |
| Core | yes | yes |
| Components | `core` `canvas` `form` `data` `overlay` `web` profiles, plus extras | `core` `canvas` `form` `desktop`, then `data` and `overlay` |
| Shell | yes, through toolkit-go | windows, dialogs, notify; no tray |
| Session | no: the platform window manager does it | yes, served by the rio fork |
| Policy | optional: off for one client, on when a second attaches | yes, through uxd |
| Transfer | within the app | across apps, brokered by rio |

Core and Components are what make a client or a `.ui` document
portable: an rc script that uses only those layers and the `form`
profile runs on any host that claims them.

## Shared conventions

These hold in every layer. A layer may tighten one, and says so where it
does.

- **Words.** must, must not, should and may mean what RFC 2119 says. A
  **host** serves the files; a **client** opens them. The **author** is
  the client that builds an app's UI; other clients observe or drive it.
- **Text.** Everything is UTF-8 with no NUL bytes. A line ends in one
  `\n`. Binary data (images, icons) lives in files of its own and is
  never mixed with text.
- **Tokens.** A line splits into words by Plan 9 `tokenize(2)`: blanks
  separate, single quotes group, `''` is a literal quote. The first word
  of a `ctl` line is a verb; the first word of an event is its name.
  `name=value` words are attributes, split at the first `=`. Attribute
  names are lowercase ASCII (`[a-z][a-z0-9-]*`).
- **Names use dashes.** Every name the spec defines is lowercase words
  joined by `-`: types (`alert-dialog`), props (`max-len`), style words
  (`flex-col`, `items-center`), theme tokens (`muted-foreground`), events
  (`mouse-down`), verbs, error codes (`not-found`). No underscores and no
  camel case, so a name is one shell word with nothing to quote and reads
  the same in rc, awk and a URL. A host whose toolkit spells names
  otherwise (GPUI's `flex_col`) maps them; the spelling on the wire is
  always the dashed one.
- **Ignore what you don't know.** Readers ignore unknown attributes and
  unknown events. Writers send only attributes the spec defines, except
  names starting `x.` (`x.myapp.foo=1`), which are free for experiments.
- **Snapshots, then events.** State files are read whole from offset 0
  and give a consistent snapshot as of the open. `events` files are
  streams (core.md § Events). To follow something, open its `events`,
  read the `resync` line, read the state files, then apply events.
- **Paths, never IDs that need translating.** A path that appears in an
  event, in `trace`, or in an error is one the client can write to.
- **Bytes, not paths, across namespaces.** Two processes may see
  different files at the same path. Anything that crosses from one app
  to another (a drop, a paste) carries bytes or file names, never a path
  to open ([transfer.md](transfer.md)).
- **Mounts.** `$ui` names the core tree (`/mnt/ui` on Plan 9). `$desk`
  names the shell and session tree (`/mnt/desk`). A client always goes
  through the variable and never spells the path.

## Versions

Each layer has its own `major.minor` version. A minor version adds files,
verbs, attributes, events, types or profiles, and never changes what an
existing one means. A major version may break. A client that doesn't know
a layer's major version must not use that layer.

## Conformance

Each layer will get a conformance suite: scripts that attach to a host
over 9P and check the files, verbs, events and errors this spec
describes, and a fake host for testing clients, following 9/UX's rule of
a fake per protocol. Neither exists yet.

## Prior art and sources

- uitreefs [DESIGN.md](../../uitreefs/DESIGN.md), v0.2: the core grammar
  and the component catalog.
- 9/UX's [protocol conventions](https://github.com/progrium/9ux/blob/main/docs/protocols/README.md),
  [ux.md](https://github.com/progrium/9ux/blob/main/docs/protocols/ux.md)
  and [devux.md](https://github.com/progrium/9ux/blob/main/docs/protocols/devux.md):
  rights, the public view, the session, drag brokering.
- The uxkit draft ([9ux PR #23](https://github.com/progrium/9ux/pull/23)):
  author and public views of one tree, request events, coalesced queues.
- The toolkit-go desktop filesystem proposal: the `$desk` shell layer.
- Inferno Tk and acme: text commands to a toolkit, windows as directories.
