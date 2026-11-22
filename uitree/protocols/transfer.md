# transfer: typed drag and drop, typed clipboard

**Layer:** `transfer 1.0` (draft) · **Mount:** `$ui/drag`, `$ui/clipdata` ·
**Required:** no · **Conventions:** [README.md](README.md#shared-conventions)

Core has a text clipboard. This layer moves richer data: several typed
representations of one copied or dragged thing, inside an app and
between apps. Its rule comes from 9/UX: **bytes cross, paths don't.** Two
processes can see different files at one path, so a target asks for the
bytes of a type, and the source (or a broker holding them) answers.

## Types

A type is an ID: lowercase letters, digits, `.` and `-`. These are
defined; others are agreed between programs, with `x.` for experiments.

| Type | Bytes |
| --- | --- |
| `text` | UTF-8 text |
| `file` | a list, one line per item: `file name=NAME [size=N] [dir] [mode=M]`. `name` is a file name, never a path. Item `n`'s contents are fetched as item `n` |
| `image` | an image; the host's format (`image(6)` on Plan 9, PNG elsewhere), named in `version` |
| `uri` | one URI per line |
| `ui.icon` | icons dragged out of an `icon-view`: `icon id=ID [label=T]` per line |

## Dragging

### Receiving

A node becomes a drop target with a `drop` file listing the types it
takes. While a drag is over it, its `drop-over:` style words apply with
no round trip. A drop is a request:

```text
drop pick nav/notes win=main drag=7 types=file,text pt=40,212 seq=301
```

The drag's offer is under `$ui/drag/7/`:

```text
$ui/drag/7/
    types          the offered types, richest first
    data/TYPE      the bytes of one representation, fetched on open
    item/N/TYPE    item N of a multi-item type (file contents)
```

The client reads what it wants, then answers `accept seq=301 [op=copy|move]`
or `refuse seq=301` on the node's `ctl`. With no answer, the drop is
refused. `drag/7` goes away once the request is answered and the reads
are done.

### Starting

A node with `drag` in its `on` file and a `drag-types` file starts a drag
in the host when the user presses and moves on it. The host sends
`dragstart KEY PATH drag=8`. The client writes the representations it
offers to `$ui/drag/8/data/TYPE` (and `item/N/TYPE`), which may happen
after the drag begins, since bytes are only fetched at the drop. When it
ends: `dragend KEY PATH drag=8 result=dropped|cancelled op=copy|move`. A
`move` tells the source it may delete its original.

### Between apps

Inside one host, the host is the broker. Across apps, the window system
is ([session.md](session.md)): on 9/UX, rio's drag broker carries the
offer from the source host to the target host, and each side sees only
its own `$ui/drag/N/`. A host without a session layer offers only `file`
(as host files it maps in), `text` and `uri` to the platform.

## Clipboard

```text
$ui/clip             text, as in core (on 9/UX, kept in step with snarf)
$ui/clipdata/
    types            the types the clipboard holds, and its generation
    TYPE             the bytes of one representation
```

Writing `clip` or one `clipdata/TYPE` file makes the clipboard exactly
that one representation, with a new generation. To copy several
representations of one thing, write them inside one `ctl` write:

```rc
echo 'copy text=<<END
Quarterly report
END
copy x.myapp.card=<<END
card id=42
END' >$ui/ctl
```

All `copy` lines in one write make one clipboard. A `clip` event
(`clip - - gen=12`) follows every change, from any app. Reading `clip`
always gives text, converted by the host where it can (a `file` list
gives its names).

## Open questions

1. **Large payloads.** Here-values in `ctl` are capped at 64 KiB per 9P
   write. Large copies should write `clipdata/TYPE` directly; can that
   join a multi-type copy?
2. **Image format.** One format for every host (PNG), or the host's
   native one?
3. **Promises.** Should a source be able to offer a type and produce its
   bytes only when a target asks, as rio's broker allows?
