# Example captures

Every example in [examples/](..) run for real on uitreefs 0.2: built in
release mode with GPUI and h9 linked in (Zig 0.16, hyper9 at the pinned
submodule), rc and awk clients running inside an h9 machine on the 9front
11952 amd64 root (`--root`/`$H9ROOT`, emulated CPU since the container has
no KVM), Linux clients in the same machine on an Alpine edge tree, windows
on Xvfb with Mesa's lavapipe as the Vulkan driver, driven with xdotool.
GIFs are recorded without the pointer. Linux rendering only; nothing here
says how the macOS host looks.

[tools/all.sh](tools/all.sh) remakes the rc, Go, C and awk captures;
`tools/inter.sh calc` remakes one. Start `Xvfb :99 -screen 0 1440x900x24`
first. The sed, PostScript, COBOL, jq, Lua, Node, Python, Ruby, Forth and
Scheme captures are [tools/more.sh](tools/more.sh) (`more.sh all`, or one by
name); all but sed run Linux programs in h9 on an Alpine tree that
[tools/linuxroot.sh](tools/linuxroot.sh) makes, with gforth built into it by
[tools/gforth.sh](tools/gforth.sh).

## What ran

| Example | Result | Captures |
| --- | --- | --- |
| [rc/counter.rc](../rc/counter.rc) | clicks and the `=` key both count | [counter.png](counter.png), [counter-after.png](counter-after.png), [counter.gif](counter.gif) |
| [rc/confirm.rc](../rc/confirm.rc) | Delete exits 0 | [confirm.png](confirm.png), [confirm.gif](confirm.gif) |
| [rc/hello.rc](../rc/hello.rc) | greets | [hello.png](hello.png), [hello-greeted.png](hello-greeted.png), [hello.gif](hello.gif) |
| [rc/signin.rc](../rc/signin.rc) | field errors, then the Welcome dialog | [signin.png](signin.png), [signin-after.png](signin-after.png), [signin.gif](signin.gif) |
| [rc/todo.rc](../rc/todo.rc) | adds tasks | [todo.png](todo.png), [todo-items.png](todo-items.png), [todo.gif](todo.gif) |
| [rc/calc.rc](../rc/calc.rc) | 12×3=36, +7=43 | [calc.png](calc.png), [calc-result.png](calc-result.png), [calc.gif](calc.gif) |
| [rc/chat.rc](../rc/chat.rc) | Eliza answers | [chat.png](chat.png), [chat-reply.png](chat-reply.png), [chat.gif](chat.gif) |
| [rc/settings.rc](../rc/settings.rc) | four pages, live dark mode | [settings.png](settings.png), [settings-appearance.png](settings-appearance.png), [settings-account.png](settings-account.png), [settings-shortcuts.png](settings-shortcuts.png), [settings-dark.png](settings-dark.png), [settings.gif](settings.gif), [settings-dark.gif](settings-dark.gif) |
| [rc/gallery.rc](../rc/gallery.rc) | stories switch, Dark switch works | [gallery.png](gallery.png), [gallery-input.png](gallery-input.png), [gallery-slider.png](gallery-slider.png), [gallery-table.png](gallery-table.png), [gallery-chart.png](gallery-chart.png), [gallery-dialog.png](gallery-dialog.png), [gallery-dark.png](gallery-dark.png), [gallery.gif](gallery.gif) |
| [rc/files.rc](../rc/files.rc) | tree, table, folder expands | [files.png](files.png), [files-browse.png](files-browse.png), [files.gif](files.gif) |
| [rc/stocks.rc](../rc/stocks.rc) | rows update every second, picked symbol charted | [stocks.png](stocks.png), [stocks-nvda.png](stocks-nvda.png), [stocks.gif](stocks.gif) |
| [rc/dock.rc](../rc/dock.rc) | panels, file tree, Ctrl-Shift-P palette | [dock.png](dock.png), [dock-palette.png](dock-palette.png), [dock.gif](dock.gif) |
| [rc/notes.rc](../rc/notes.rc) | Ctrl-N makes a note, the editor takes markdown | [notes.png](notes.png), [notes-new.png](notes-new.png), [notes.gif](notes.gif) |
| [rc/paint.rc](../rc/paint.rc) | strokes in three colors | [paint.png](paint.png), [paint-drawn.png](paint-drawn.png), [paint.gif](paint.gif) |
| [go/greet](../go/greet/main.go) | `GOOS=plan9` binary in h9 | [go-greet.png](go-greet.png), [go-greet-done.png](go-greet-done.png), [go-greet.gif](go-greet.gif) |
| [go/clock](../go/clock/main.go) | ticks | [go-clock.png](go-clock.png), [go-clock.gif](go-clock.gif) |
| [c/life.c](../c/life.c) | built with 9front's `mk`/6c inside h9, run there | [c-life-running.png](c-life-running.png), [c-life.gif](c-life.gif) |
| [awk/csvview.awk](../awk/csvview.awk) | table with sorting | [awk-csvview.png](awk-csvview.png) |
| [sed/counter.sed](../sed/counter.sed) | 9front sed in h9: +, −, Reset and the = key; 2026 presses of = come to MMXXVI | [sed-counter.png](sed-counter.png), [sed-counter-2026.png](sed-counter-2026.png), [sed-counter.gif](sed-counter.gif) |
| [ps/stamps.ps](../ps/stamps.ps) | Ghostscript 10.08 on Alpine, in h9: trees at two details, a snowflake, a spirograph, glyphs, undo | [ps-stamps.png](ps-stamps.png), [ps-stamps.gif](ps-stamps.gif) |
| [cobol/payroll.cob](../cobol/payroll.cob) | GnuCOBOL 3.2 on Alpine, built and run in h9: field errors, then three employees paid | [cobol-payroll.png](cobol-payroll.png), [cobol-payroll.gif](cobol-payroll.gif) |
| [jq/ttt.jq](../jq/ttt.jq) | jq 1.8 on Alpine, in h9: a draw, then jq wins | [jq-ttt-draw.png](jq-ttt-draw.png), [jq-ttt.png](jq-ttt.png), [jq-ttt.gif](jq-ttt.gif) |
| [forth/rpn.fs](../forth/rpn.fs) | gforth 0.7.3 on Alpine, in h9: 6 7 * is 42, a new `sq` key, HEX, a loop that prints, then a stack underflow | [forth-rpn.png](forth-rpn.png), [forth-rpn-hex.png](forth-rpn-hex.png), [forth-rpn-error.png](forth-rpn-error.png), [forth-rpn.gif](forth-rpn.gif) |
| [scheme/deriv.scm](../scheme/deriv.scm) | chibi-scheme 0.12 on Alpine, in h9: four functions differentiated and plotted, the tangent following the pointer, an unknown operator refused | [scheme-deriv.png](scheme-deriv.png), [scheme-deriv-tangent.png](scheme-deriv-tangent.png), [scheme-deriv-error.png](scheme-deriv-error.png), [scheme-deriv.gif](scheme-deriv.gif) |
| [lua/mixer.lua](../lua/mixer.lua) | Lua 5.4 on Alpine, in h9: sliders, a typed hex color, Random, a palette of saved swatches | [lua-mixer.png](lua-mixer.png), [lua-mixer-palette.png](lua-mixer-palette.png), [lua-mixer.gif](lua-mixer.gif) |
| [node/jsonview.js](../node/jsonview.js) | Node 26 on Alpine, in h9: picking values, filtering the tree | [node-jsonview.png](node-jsonview.png), [node-jsonview-filter.png](node-jsonview-filter.png), [node-jsonview.gif](node-jsonview.gif) |
| [python/expenses.py](../python/expenses.py) | CPython 3.14 on Alpine, in h9: five expenses in four categories, table, chart and totals in step | [python-expenses.png](python-expenses.png), [python-expenses-added.png](python-expenses-added.png), [python-expenses.gif](python-expenses.gif) |
| [ruby/regex.rb](../ruby/regex.rb) | Ruby on Alpine, in h9: highlights and a groups table as the pattern is typed | [ruby-regex.png](ruby-regex.png), [ruby-regex-groups.png](ruby-regex-groups.png), [ruby-regex.gif](ruby-regex.gif) |
| [python/hn.py](../python/hn.py) | not run: the capture sandbox blocks the HN API host | — |
| [sh/progress.sh](../sh/progress.sh) | not run: needs plan9port's `9p` | — |

## Fixed while capturing (0.2)

- **Enter in a form sent two submits.** An input inside a form sent its own
  `submit` and then the form's. In 0.1 the input usually had no tag, so a
  client keyed on the tag saw one; in 0.2 the input inherits the form's
  tag, so payroll.cob and expenses.py ran twice and the second run, on the
  cleared form, drew "required" errors. Inside a form, Enter now sends only
  the form's `submit`.
- **`$ui` for Linux clients.** h9's Linux `/mnt` holds only its own mount
  points, so the link uitreefs put there never showed. With a Linux root,
  `$ui` is now `/9/mnt/ui`, and stamps.ps takes it as `-sui=$ui`, since gs
  in SAFER mode has no `getenv`.
- **rc carets after a subscript.** `$m/$ev(3)/value` is two words in Plan 9
  rc; settings.rc and dock.rc now say `$m/$ev(3)^/value`.
- **counter.sed** reset only the first line of its multi-line screen to 0,
  so the first click did arithmetic on the screen text.
- **expenses.py and mixer.lua** named nodes by the wrong paths.
- **jsonview.js** expanded ids that a filter had hidden.

## Fixed while capturing (0.1)

- **Layouts.** `h_flex` carries GPUI Kit's `items_center`, so the two-pane
  roots of settings, gallery and notes centered their panes instead of
  filling the window (notes collapsed to a strip), and stocks' chart had no
  height. Those rows now say `items_stretch`, as do DESIGN.md's two
  sidebar-and-page snippets.
- **Icons.** The host registered GPUI Kit's default icon bundle, which only
  holds the icons its own components use; it now registers `AllAssets`, the
  whole Lucide set, so `send`, `trash`, `keyboard` and the rest draw.
- **Sidebar width.** A sidebar's `w=` sized only the box around GPUI Kit's
  Sidebar, which drew at its own 255px over the page beside it. The width
  now reaches the Sidebar.
- **`cmd-` keys off macOS.** GPUI reads `cmd` as Super on Linux and
  Windows, so every `cmd-` binding was out of reach there. The host now
  binds `cmd` as GPUI's `secondary` (Cmd on macOS, Ctrl elsewhere).
- **paint.rc.** Plan 9 rc adds no free caret after a subscript, so
  `'M'$last(1)','$last(2)` was two words and every stroke was refused; and
  "Blue" was the `primary` token, near-black in the default theme. It is
  `info` now.
- **csvview.awk.** Numeric columns were 100px whatever their header; they
  now widen to fit it.

- **Values written inside begin/commit.** While a batch is open the host
  renders the frozen tree, so a prop written then reached its component as
  the frozen value: clearing an input's `value` between `begin` and
  `commit` left the old text in the field. The commit now hands components
  every prop that differs from the frozen tree. (Found by payroll.cob,
  which clears its form inside the batch that shows the pay stub.)
- **The `focus` file and text inputs.** Writing an input's path to a
  window's `focus` focused the node's own handle, not the text field
  inside, so typing went nowhere. Components with a field of their own
  (input, textarea, number-input) now focus it.

## Still open

- The dock's command palette doesn't take the typed query in the capture
  (the search field shows its placeholder), and the notes list stays empty
  beside a new note. Both were so in 0.1 too.

- The stocks chart's line looks nearly flat, likely because its y axis
  starts at zero, so a few dollars on a price of 140 barely moves it (not
  checked).
- Times inside h9 follow the 9front root's `/adm/timezone/local` (CET on
  the release ISO), not the host's zone.
- In the release profile, `host`'s `every_table_word_resolves` test fails
  on `debug`/`debug_below`, which GPUI only has in debug builds.
