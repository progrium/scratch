# h9sys

gpuifs's link to [hyper9](https://github.com/progrium/hyper9): `zig/shim.zig`
wraps `h9.Machine` in the C ABI of DESIGN.md § Embedding h9
([`zig/h9sys.h`](zig/h9sys.h)), and `src/lib.rs` is the safe Rust side
(`Machine`, `Config`, `Status`, `Signals`).

## Building

`build.rs` runs `zig build` (Zig 0.16) against a hyper9 checkout and links
`libh9sys.a` and drawterm's `libkern.a`:

```sh
git submodule update --init gpuifs/third_party/hyper9   # or: export HYPER9_DIR=~/src/hyper9
cargo build -p gpuifs
crates/h9sys/sign-macos.sh target/debug/gpuifs           # macOS: HVF needs the entitlement
```

Without Zig or a checkout the crate builds as a stub (`cfg(h9sys_stub)`,
with a cargo warning) and `Machine::new` fails, so the pure crates and
`gpuifs -a` still build anywhere. `H9SYS_REQUIRE=1` makes that an error,
`H9SYS_STUB=1` forces the stub, `H9SYS_OPTIMIZE` picks Zig's mode
(ReleaseSafe by default) and `H9SYS_EMU=none` leaves hcpu out. Zig's global
cache defaults to the checkout's `.local/cache/zig`, as hyper9's
`scripts/env.sh` sets it.

## Testing

`tests/run.rs` and `tests/mount.rs` (and `crates/gpuifs/tests/headless.rs`)
run real machines when `H9SYS_TEST_ROOT` names a 9front root for the host's
architecture, such as the one hyper9 makes:

```sh
cd third_party/hyper9 && scripts/fetch.sh isoamd64 &&
  zig build isoroot -- .local/9front/9front-11952.amd64.iso .local/9front/rootamd64
H9SYS_TEST_ROOT=$PWD/.local/9front/rootamd64 cargo test -p h9sys -p gpuifs --no-default-features
```

`gpuifs` itself takes the same root with `--root DIR` or `$H9ROOT`. With
`--root builtin` (the default) the machine has h9's built-in root, whose
commands exist only if hyper9 was built with its `zig build slim` trees.

## Notes on h9 as it is

- **The `/mnt/gpui` mount.** `Machine.Options.mounts`' `.fd` kind takes a
  descriptor in h9's own kernel fd table (devdotl's `fd N`), not a host fd,
  and an embedder can't make one. So the shim relays the socket pair
  through a unix socket in a private 0700 directory under `$TMPDIR`, which
  h9 mounts as a `unix://` URL. Nothing else can connect in practice, but a
  host fd mount in h9 (devlfd's `lfdfd` on a dup of the fd, before
  `dotlConv`) would remove the relay and the socket.
- **One run per `h9_run`.** The machine's architecture comes from a host
  program's header, so the shim checks the config in `h9_new` (by compiling
  the namespace plan) and makes the `h9.Machine` in `h9_run`.
- **A hangup before the run** is remembered and ends the run at once with
  `hangup`; one that races the run's start is re-posted while it runs.
- **POSIX only** for now: the relay and the Rust side use unix fds.
