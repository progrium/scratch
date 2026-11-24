# uitreefs examples

Client programs for uitreefs, written against [DESIGN.md](../DESIGN.md). They
are also the end-to-end acceptance suite for the [plan](../PLAN.md): each
header says which milestone it needs, and
[tests/conformance/run-examples](../tests/conformance/run-examples) runs
the rc and awk ones headless and compares the trees they build with
goldens. Every example here was run under Xvfb and driven with xdotool to
make the captures in [screenshots/](screenshots/).

## The programs

| Example | Language | What it is | Recreates or follows | Exercises | Needs |
| --- | --- | --- | --- | --- | --- |
| [rc/hello.rc](rc/hello.rc) | rc | Greeter: name in, greeting out | DESIGN.md's `Greeter` | the `main` window, one ctl write, a tag on a container, reading `value` | M3 |
| [rc/counter.rc](rc/counter.rc) | rc | Counter with + and − | the classic first app | element tier only, `on=click`, state styles, keys and menu sharing the buttons' keys | M2 |
| [rc/confirm.rc](rc/confirm.rc) | rc | zenity-style yes/no box for scripts | `zenity --question` | exit status from the UI, Enter/Escape, one ctl write | M2 |
| [rc/todo.rc](rc/todo.rc) | rc | To-do list with filters, saved to a file | TodoMVC | `new`/`delete`, `order` as a filter, group-hover, checkbox, tabs, empty | M3 |
| [rc/calc.rc](rc/calc.rc) | rc | Pocket calculator | a common app type | grid, `col_span`, key bindings whose ids are the buttons' tags | M3 |
| [rc/signin.rc](rc/signin.rc) | rc | Sign-in form with validation | DESIGN.md § Atomic updates | form, field `error`, `secret`, link, dialog footer slot | M3 |
| [rc/settings.rc](rc/settings.rc) | rc | Settings window with live theme changes | a common app type, in the gallery's style | sidebar, pages switched by `order`, switch, select, slider, radio, number-input, table, theme tokens | M3 |
| [rc/gallery.rc](rc/gallery.rc) | rc | The component gallery, 21 stories | GPUI Kit's story app | most of the catalog; screens as files in [rc/gallery/](rc/gallery/); overlays; event log | M3 |
| [rc/files.rc](rc/files.rc) | rc | File browser with previews | a common app type | tree, table, breadcrumb, resizable, context-menu, alert-dialog, sheet, img `data`, drop | M3, M4 |
| [rc/stocks.rc](rc/stocks.rc) | rc | Live quote board with a chart | GPUI Kit's real-time table story | rows rewritten every second, selection kept, chart, description-list, two rc procs | M3 |
| [rc/dock.rc](rc/dock.rc) | rc | IDE workspace with a command palette | GPUI Kit's dock story | dock, layout save/restore, title-bar, editor, diagnostics, palette, status bar, `ask close quit` | M4 |
| [rc/chat.rc](rc/chat.rc) | rc | Chat with an ELIZA in awk | a common app type | message-list, typing indicator, markdown, sheet | M3 |
| [rc/notes.rc](rc/notes.rc) | rc | Notes app | DESIGN.md § A complete client | list, editor, toolbar, keys, menus, alert-dialog | M3 |
| [rc/paint.rc](rc/paint.rc) | rc | Finger painting | GPUI's `painting` example | canvas `ctl add`/`del`, drag events, ops as a file format | M4 |
| [go/greet](go/greet/main.go) | Go | Greeter | DESIGN.md's `GOOS=plan9` client | package `os` only, `strings.Fields` on events, 8 KiB reads | M3 |
| [go/clock](go/clock/main.go) | Go | Analog clock | — | canvas drawn once, hands moved with `set`, tokens follow dark mode | M4 |
| [c/life.c](c/life.c) | 9front C | Game of Life | — | libc `tokenize`, bio, `rfork(RFMEM)`, whole-board `ops` per frame | M4 |
| [awk/csvview.awk](awk/csvview.awk) | awk | CSV viewer | — | client with no libraries, generated columns, host sort, filter, sheet | M3 |
| [python/hn.py](python/hn.py) | Python | Hacker News reader | a common app type | row templates, paging, html here-values, background threads | M3 |
| [python/expenses.py](python/expenses.py) | Python | Expense tracker, saved to a file | a common app type | form with `labels=side`, field errors, select, table, chart and totals in one ctl write | M3 |
| [lua/mixer.lua](lua/mixer.lua) | Lua | Color mixer with a saved palette | a common app type | sliders, a tag inherited by three of them, `via=ctl` echoes, `set PATH : words`, swatches made with `new` | M3 |
| [node/jsonview.js](node/jsonview.js) | JavaScript (Node) | JSON explorer | a common app type | tree items as plain words, `expanded`, a cleanable filter, editor, description-list, status bar | M3 |
| [ruby/regex.rb](ruby/regex.rb) | Ruby | Regular-expression tester | regex101 and friends | styled-text `runs` for highlights, switches, field error, table of matches | M3 |
| [sh/progress.sh](sh/progress.sh) | bash | Progress window for a long command | `zenity --progress` | host-side client over `uitreefs -a` with plan9port `9p`, `read -r name key path` | M3 |
| [sed/counter.sed](sed/counter.sed) | sed (9front) | Counter, with the count in Roman numerals | the classic first app | sed's own `w` files as ctl writes, `-u` flushing, decimal arithmetic by substitution | M3 |
| [ps/stamps.ps](ps/stamps.ps) | PostScript (Ghostscript) | Stamp fractal trees, Koch snowflakes, spirographs and font glyphs onto a canvas | — | `file` operator for every write, PostScript paths and `charpath` turned into canvas paths with `pathforall` | M4 |
| [cobol/payroll.cob](cobol/payroll.cob) | COBOL (GnuCOBOL) | Weekly payroll: pay stub, register, overtime | a classic COBOL job | `SELECT ... ASSIGN` to run-time paths, the events file read as records, field errors, here-values, one ctl write per run | M3 |
| [jq/ttt.jq](jq/ttt.jq) | jq | Tic-tac-toe against an unbeatable jq | — | jq as a reducer (`foreach` over event lines), minimax, absolute layout computed in jq, one ctl write per frame | M3 |
| [forth/rpn.fs](forth/rpn.fs) | Forth (gforth) | RPN calculator whose stack is Forth's own data stack | HP's RPN calculators | keys whose tags are Forth source run with `evaluate`, `catch` for errors, `outfile-id` for output, a button-group that follows `BASE`, a key made with `new` for each word you define, the stack view as one `tree` document | M3 |
| [scheme/deriv.scm](scheme/deriv.scm) | Scheme (chibi-scheme) | Symbolic derivatives with a plot and a tangent that follows the pointer | SICP § 2.3.2 | `read` on the input's value, field errors, list `select`, a canvas drawn once per function, coalesced `move` events answered by moving items by id on the canvas `ctl` | M4 |

The GPUI Kit recreations (gallery, stocks, dock, paint) follow the
structure of GPUI Kit's story app and GPUI's examples from memory; they are
written fresh for uitreefs, not ported.

## Running them

```sh
cd examples/rc
uitreefs -t Todos rc todo.rc

cd examples/go/clock
GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o clock . && uitreefs -t Clock ./clock

uitreefs -t CSV awk -f examples/awk/csvview.awk examples/awk/planets.csv
examples/sh/progress.sh 'Sleeping' sh -c 'for i in 1 2 3 4 5; do echo step $i; sleep 1; done'
cd examples/sed && uitreefs -t Counter sed -nuf counter.sed /mnt/ui/events
```

### Linux clients: Lua, Node, Python, Ruby, PostScript, COBOL, jq, Forth and Scheme

h9 runs Linux binaries in the same machine as 9front's. `--dir ALPINE:#L`
puts an Alpine tree under the Linux view, where the Plan 9 namespace is
under `/9`, and uitreefs sets `$ui` to `/9/mnt/ui` for it. Every client
goes through `$ui`, so the same code runs in either view.
[screenshots/tools/linuxroot.sh](screenshots/tools/linuxroot.sh) makes that
tree with `apk.static` from Alpine edge: chibi-scheme, ghostscript, gnucobol,
jq, lua5.4, nodejs, python3 and ruby. Alpine has no gforth, so
[screenshots/tools/gforth.sh](screenshots/tools/gforth.sh) builds gforth
0.7.3 into the same tree with its own gcc.

```sh
L=third_party/hyper9/.local/linux/edge-tools   # from screenshots/tools/linuxroot.sh
cd examples/lua && uitreefs -t Mixer --dir $L:'#L' lua5.4 mixer.lua
cd examples/node && uitreefs -t JSON --dir $L:'#L' node jsonview.js sample.json
cd examples/python && uitreefs -t Expenses --dir $L:'#L' python3 expenses.py
cd examples/ruby && uitreefs -t Regex --dir $L:'#L' ruby regex.rb
cd examples/ps && uitreefs -t Stamps --dir $L:'#L' sh -c 'exec gs -q -dNODISPLAY -sui="$ui" --permit-file-all="$ui/*" stamps.ps <$ui/events'
cd examples/cobol && uitreefs --headless --dir $L:'#L' cobc -x payroll.cob   # cobc and gcc, in h9
uitreefs -t Payroll --dir $L:'#L' ./payroll
cd examples/jq && uitreefs -t Tic-tac-toe --dir $L:'#L' sh -c 'jq -nRj --unbuffered -f ttt.jq <$ui/events >$ui/win/main/ctl'
cd examples/forth && uitreefs -t RPN --dir $L:'#L' gforth rpn.fs
cd examples/scheme && uitreefs -t Derivatives --dir $L:'#L' chibi-scheme deriv.scm
```

The Lua, Node, Python and Ruby clients use only their standard libraries.
Each is the same shape: open `$ui/events`, split each line on blanks, and
answer with one write of `set` lines to `$ui/win/main/ctl`.

The rest keep the language doing the work, with as little shell as
possible. Each file's header says what the shell does, and why.

- **sed** is 9front's. It reads the events file as its input and writes
  ctl files with `w`. `-u` flushes the `w` files before each read, so one
  event's output is one ctl write. The `main` window exists before any
  client runs, so sed can open its ctl at start and the launch is just sed.
- **Ghostscript** opens every file it writes with `file`. It reads events
  from `%stdin`, because gs reads named files with `fread`, which waits for
  a full buffer, so the shell redirects `events` to stdin and does nothing
  else.
- **COBOL** opens everything itself. Data files take Plan 9 words as well
  as tabs, so its `LINE SEQUENTIAL` records hold no tabs and GnuCOBOL's
  validation needs no switch.
- **Forth** (gforth) opens `events` with `open-file` and writes every ctl
  itself. The client keeps nothing on the data stack between events, so
  the stack the user sees is the real one: a key is a word passed to
  `evaluate`, and the stack view is `depth` and `pick`.
- **Scheme** (chibi) uses R7RS small's file ports and nothing else. The
  input's text goes through `read`, so the expression is a list from the
  start, and differentiating, simplifying and printing are walks over it.
- **jq** can't open files, so a shell line wires events in and the window's
  ctl out. jq can only write that one ctl, so it lays the board out with
  absolute positions it computes.

## Conventions

- **rc uses only the built-in root.** The rc programs need only the
  commands h9 ships inside its binary, so they run with `--root builtin`.
  There is no `printf`, `hoc` or `seq` there, so [rc/lib.rc](rc/lib.rc)
  has `attr` (one `name=value` from the current event) and `add`.
- **Every event starts `name key path`.** `$ev(2)` is the routing key (the
  nearest tag, or the action id of a key or menu item), so most loops are
  one `switch($ev(1)^:^$ev(2))`. Attributes follow as `name=value`.
- **Events go through cat** in rc, because `read(1)` reads a byte at a
  time: `cat $ui/events | while(ev=`{read})`. Other languages read the file
  with any buffer size.
- **One ctl write per update.** A ctl applies all its lines at close, in
  one frame, so a client sends `set`, `new` and `delete` lines together
  rather than writing prop files one by one.
- **Quote every `=` in rc arguments.** Plan 9's rc treats a bare `=` outside
  an assignment as a syntax error. (Inside a quoted ctl command, `''` is a
  literal quote, which is also the uitreefs quoting rule.)
- **No here documents inside braces.** Plan 9's rc reads a here document's
  body only at the top level, so screens a function writes live in files
  (as in [rc/gallery/](rc/gallery/)) or are written with `echo`.
- **Data files are Plan 9 words.** Lines of a table's `rows`, a tree's
  `items` and the like may use tabs or quoted words, so no example needs a
  tab character.
