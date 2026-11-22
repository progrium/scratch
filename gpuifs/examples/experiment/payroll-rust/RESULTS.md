# Payroll in Rust (gpui + gpui-component): timed build

**Wall time: 3 min 6 s** — start `2026-11-22T04:57:34Z`, end `2026-11-22T05:00:40Z` (`date -u`).

The clock started before reading any gpui-component API (form, input, table,
description list, theme) and stopped when the capture of the spec's reference
run showed every expected number.

## Numbers

| | |
| --- | --- |
| Wall time | 3:06 |
| Compile/run iterations | 8 launches: 2 app builds, 4 `cargo test` runs, 3 runs of the app (one crashed at startup, one looked at the layout, one was the capture) |
| Bugs hit | 2 (below); 0 arithmetic or behavior bugs, the first capture matched the spec |
| Lines | 376 Rust (261 `main.rs` UI, 115 `lib.rs` arithmetic and its test), 350 non-blank; plus a 27-line capture script and a 15-line Cargo.toml |

## Bugs hit

1. **rustc fell over on `cargo test`.** With the unit test inside the binary
   crate, the test build hit "recursion limit reached" (the deep gpui element
   types in `render`), then with `#![recursion_limit = "256"]` rustc itself
   segfaulted, then with a bigger stack it wanted 512. The plain binary build
   was fine. Moving the money code and its test into `lib.rs` and running
   `cargo test --lib` fixed it. Three of the four test runs went to this.
2. **`secondary-enter` panics.** `KeyBinding::new("secondary-enter", ...)`
   isn't a keystroke gpui-pre 0.3.12 accepts, so the app panicked on launch.
   Fixed by binding `cmd-enter` on macOS and `ctrl-enter` elsewhere.

## What was untimed (Phase 0)

- A standalone Cargo project with the gpuifs pins (`gpui-pre =0.3.12`,
  gpui-component and gpui-kit at rev `cf945af`), and the same Cargo.lock;
  release dependencies prebuilt.
- A hello-world window (one Button) built and shown on Xvfb with lavapipe, to
  prove the environment. That taught the startup boilerplate
  (`gpui_kit::application()`, `gpui_kit::init`, `gpui_kit::open_window`), so
  that part wasn't learned on the clock.
- xdotool installed, Xvfb on :99, SPEC.md written from payroll.cob.

## Checked after the clock stopped

Ctrl-Enter runs payroll from the Rate field; `$1,250.00` parses as an amount;
200 hours shows "There are 168 hours in a week" and the inputs keep their text
.

## Files

- [src/main.rs](src/main.rs), [src/lib.rs](src/lib.rs), [Cargo.toml](Cargo.toml)
- [capture.sh](capture.sh): the reference run under Xvfb + xdotool
- [payroll.gif](screenshots/payroll.gif) (no cursor), [payroll-errors.png](screenshots/payroll-errors.png), [payroll.png](screenshots/payroll.png)

Reproduction: `cargo build --release`, start `Xvfb :99 -screen 0 1440x900x24`,
then `./capture.sh`.
