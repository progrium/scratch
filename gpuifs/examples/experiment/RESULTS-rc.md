# Payroll in rc on gpuifs: timed build

Built to SPEC.md (in the project files) (the Rust thread's spec, used unchanged).

| | |
| --- | --- |
| Start | 2026-11-22T05:01:43Z |
| End | 2026-11-22T05:07:53Z |
| **Wall time** | **6 min 10 s** |
| gpuifs launches (build/run iterations) | 9, plus 1 host-side check of the awk arithmetic |
| Lines | payroll.rc 66 (57 non-blank, non-comment), payroll.awk 66 (59) — 132 total (116) |
| gpuifs bugs hit | none; no time spent fixing gpuifs |

## What the timer covered

Everything after a working environment: reading gpuifs's DESIGN.md and two
rc examples (lib.rc, signin.rc, part of todo.rc) to learn the API, writing the
app, and every run until a capture of the spec's reference run matched the
expected numbers. Not timed: building gpuifs (Zig 0.16, h9, the 9front amd64
root), installing xdotool/ImageMagick and two missing `-dev` libraries,
starting Xvfb, a smoke run of counter.rc, and reading SPEC.md.

There's no compile step: an iteration is one launch of
`gpuifs -t Payroll rc payroll.rc` in h9 (emulated CPU, no KVM here) under
Xvfb, driven by xdotool. Each launch took about 30 to 40 seconds including the
window wait and the scripted input, so roughly 5 of the 6 minutes were
launches.

## Bugs hit (all app bugs)

1. **rc syntax**: `~ $ev *tag=run*` — a bare `=` is a syntax error in rc.
   Quoted it as `*tag'='run*`. (1 launch)
2. **Form layout**: `form layout=h` puts each label beside its input, not
   the four fields side by side, and style words on the form only wrap
   GPUI Kit's Form. Replaced the form with a `h_flex` div of `field`s, with
   `tag=run` on each input so Enter (input `submit`) runs payroll. (2 launches)
3. **Wrong node path** for the total line (`reg/total` instead of
   `reg/foot/total`): awk aborted on the redirect after appending the row, so
   the inputs weren't cleared and the total didn't change. (1 launch to see it,
   1 with a trace and stderr to diagnose)
4. **Wrong node path** for the pay stub (`body/stub/items` instead of
   `body/stub/stub/items`). (1 launch)

Rough edges in gpuifs noticed but not fixed (and not counted): an awk
redirect to a missing node failed silently (nothing on the client's stderr in
the log), and a `cat $k/trace` started by the client only showed the writes
from before it opened, not later ones. Neither was investigated.

## Result

All spec behaviors checked in the capture: the three field errors on an empty
run; Grace Hopper, Alan Turing and Ada Lovelace paid with the spec's exact
numbers; the final stub (Regular 40.00 h $3,520.00, Overtime 12.00 h
$1,584.00, Net $3,650.66); the total `3 paid. Gross $10,780.25, net
$7,763.90.`; inputs cleared and focus back on Employee after each run; and
Ctrl-Enter on an empty form showing the errors again while keeping the
register.

- payroll-rc.gif (project files) — the reference run, no cursor
- payroll-rc-errors.png, payroll-rc-final.png, payroll-rc-ctrl-enter.png (project files)
- [payroll.rc](payroll.rc), [payroll.awk](payroll.awk)

## Differences from the spec

- The four fields are a row of `field`s in a div, not a GPUI Kit `form`
  (see bug 2); Enter in any input still runs payroll.
- The subtitle says "computed in rc" (the arithmetic is actually awk, called
  from rc, in integer cents).
- Past 99 rows the stub still updates but the register stops growing.
