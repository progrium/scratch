# gpuifs examples

Client programs for gpuifs, written against [DESIGN.md](../DESIGN.md). They
are also the end-to-end acceptance suite for the [plan](../PLAN.md): each
header says which milestone it needs, and W8 turns each one into a headless
test as soon as M1 lands.

Nothing here has run against a real gpuifs yet, since gpuifs doesn't exist.
The rc programs parse under Plan 9 rc (checked with 9base's rc), `hello.rc`
and `calc.rc` were run against a fake tree, the Go programs build for
`GOOS=plan9`, the awk viewer was run against a fake tree, and the Python
and shell scripts pass their languages' syntax checks.

## The programs

| Example | Language | What it is | Recreates or follows | Exercises | Needs |
| --- | --- | --- | --- | --- | --- |
| [rc/hello.rc](rc/hello.rc) | rc | Greeter: name in, greeting out | DESIGN.md's `Greeter` | tree document, input, button, submit, reading `value` | M3 |
| [rc/counter.rc](rc/counter.rc) | rc | Counter with + and − | the classic first app | element tier only, `on=click`, state styles, keymap, menu | M2 |
| [rc/confirm.rc](rc/confirm.rc) | rc | zenity-style yes/no box for scripts | `zenity --question` | exit status from the UI, Enter/Escape, begin/commit | M2 |
| [rc/todo.rc](rc/todo.rc) | rc | To-do list with filters, saved to a file | TodoMVC | `new`/`delete`, `order` as a filter, group-hover, checkbox, tabs, empty | M3 |
| [rc/calc.rc](rc/calc.rc) | rc | Pocket calculator | a common app type | grid, `col_span`, keymap and buttons sharing action names | M3 |
| [rc/signin.rc](rc/signin.rc) | rc | Sign-in form with validation | DESIGN.md § Atomic updates | form, field `error`, `flags=secret`, link, dialog footer slot | M3 |
| [rc/settings.rc](rc/settings.rc) | rc | Settings window with live theme changes | a common app type, in the gallery's style | sidebar, pages switched by `order`, switch, select, slider, radio, number-input, table, theme tokens | M3 |
| [rc/gallery.rc](rc/gallery.rc) | rc | The component gallery, 21 stories | GPUI Kit's story app | most of the catalog; screens as files in [rc/gallery/](rc/gallery/); overlays; event log | M3 |
| [rc/files.rc](rc/files.rc) | rc | File browser with previews | a common app type | tree, table, breadcrumb, resizable, context-menu, alert-dialog, sheet, img `data`, drop | M3, M4 |
| [rc/stocks.rc](rc/stocks.rc) | rc | Live quote board with a chart | GPUI Kit's real-time table story | rows rewritten every second, selection kept, chart, description-list, two rc procs | M3 |
| [rc/dock.rc](rc/dock.rc) | rc | IDE workspace with a command palette | GPUI Kit's dock story | dock, layout save/restore, title-bar, editor, diagnostics, palette, status bar | M4 |
| [rc/chat.rc](rc/chat.rc) | rc | Chat with an ELIZA in awk | a common app type | message-list, typing indicator, markdown, sheet | M3 |
| [rc/notes.rc](rc/notes.rc) | rc | Notes app | DESIGN.md § A complete client | list, editor, toolbar, keymap, menus, alert-dialog | M3 |
| [rc/paint.rc](rc/paint.rc) | rc | Finger painting | GPUI's `painting` example | canvas `ctl add`/`del`, drag events, ops as a file format | M4 |
| [go/greet](go/greet/main.go) | Go | Greeter | DESIGN.md's `GOOS=plan9` client | package `os` only, tokenize, 8 KiB reads | M3 |
| [go/clock](go/clock/main.go) | Go | Analog clock | — | canvas drawn once, hands moved with `set`, tokens follow dark mode | M4 |
| [c/life.c](c/life.c) | 9front C | Game of Life | — | libc `tokenize`, bio, `rfork(RFMEM)`, whole-board `ops` per frame | M4 |
| [awk/csvview.awk](awk/csvview.awk) | awk | CSV viewer | — | client with no libraries, generated columns, host sort, filter, sheet | M3 |
| [python/hn.py](python/hn.py) | Python | Hacker News reader | a common app type | row templates, paging, html, background threads, a Linux client (OQ8) | M3 |
| [sh/progress.sh](sh/progress.sh) | bash | Progress window for a long command | `zenity --progress` | host-side client over `gpuifs -a` with plan9port `9p` | M3 |

The GPUI Kit recreations (gallery, stocks, dock, paint) follow the
structure of GPUI Kit's story app and GPUI's examples from memory; they are
written fresh for gpuifs, not ported, and should be checked against the
pinned GPUI Kit rev when W0 picks one.

## Running them

```sh
cd examples/rc
gpuifs -t Todos rc todo.rc

cd examples/go/clock
GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o clock . && gpuifs -t Clock ./clock

gpuifs -t CSV awk -f examples/awk/csvview.awk examples/awk/planets.csv
examples/sh/progress.sh 'Sleeping' sh -c 'for i in 1 2 3 4 5; do echo step $i; sleep 1; done'
```

## Conventions

- **rc uses only the built-in root.** The rc programs need only the 44
  commands h9 ships inside its binary, so they run with `--root builtin`.
  There is no `printf`, `hoc` or `seq` there, so [rc/lib.rc](rc/lib.rc)
  has `tsv` (pipe-separated text to tab-separated) and `add`.
- **Events go through cat.** `read(1)` reads one byte at a time, which an
  `events` file refuses, so rc loops are `cat $k/events | while(ev=`{read})`.
- **Quote every `=` in rc arguments.** Plan 9's rc treats a bare `=` outside
  an assignment as a syntax error, so `has 'tag=save'`, never `has tag=save`.
  (Inside a quoted `ctl` command, `''` is a literal quote, which is also the
  gpuifs quoting rule.)
- **No here documents inside braces.** Plan 9's rc reads a here document's
  body only at the top level, so screens a function writes live in files
  (as in [rc/gallery/](rc/gallery/)) or are written with `echo`.
- **Tags and ids have no blanks**, so an event's words split cleanly. Values
  that can hold blanks are read from the node's `value` file instead.
