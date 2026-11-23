# h9build

A proof of concept: build an app from its source into layers that
[h9](https://github.com/progrium/hyper9) runs, using tools that already exist
rather than a builder of our own.

```sh
h9build -o ./myapp.h9 ./myapp   # detect, install runtimes and deps, build
./myapp.h9/run                  # run it on h9
./myapp.h9/run node -v          # or anything else in it
```

| Job | Done by |
| --- | --- |
| Detecting the language, versions, and commands | [Railpack](https://github.com/railwayapp/railpack)'s `railpack plan`, without its BuildKit backend |
| Installing runtimes | [mise](https://mise.jdx.dev), at the version Railpack pins, as Railpack's own builds do |
| Installing deps and building | The plan's commands (`npm ci`, `uv sync`, ...), as written |
| The roots | [Wolfi](https://wolfi.dev) packages: glibc, certificates, busybox, and for building, compilers and headers |
| Running every step, sandboxed | h9's Linux personality |
| Keeping each step's changes as a layer | h9's [up layers](https://github.com/progrium/hyper9/blob/main/design/upper-layers.md) (`--dir DIR:#L:up`) |

The host needs only h9, `curl`, `tar`, and a POSIX shell. Nothing runs on the
host's own OS: Railpack, mise, apk, and the package managers all run inside h9
machines, so the same script works on macOS and Linux.

## What it makes

```
myapp.h9/
  layers/runtime -> $cache/runtimes/KEY   what the plan's packages steps changed: mise's runtimes in /mise, shared by every app with the same ones
  layers/deps/...              what its install steps changed: node_modules, a venv, gems
  layers/app/...               what its build steps changed, pruned to what the plan deploys
  layers/*.key                 each layer's inputs, hashed; a layer whose key is unchanged is kept
  plan.json                    Railpack's plan
  plan.key                     the source's files, Railpack, and plan.sh, hashed; a plan whose key is unchanged is kept
  env                          the run environment: PATH, the plan's variables, the start command
  layers.txt                   the layers the run stacks: those holding something the plan deploys
  run                          h9 with the layers stacked on #L over the base root
  cache/                       per-app package manager caches, kept between builds
```

Each layer is an OCI layer, rooted at `/`, with `.wh.` whiteouts for what its
steps removed, so `run` stacks them in order with `--dir LAYER:#L` over the
base root, and they'd stack the same in any container tool. The roots are
shared by every app and live in the cache: *base*, which apps run on (about
40 MB), and *builder*, which every step runs on. So are the runtime layers:
one for each set of tools and versions, in `$cache/runtimes`.

## How it works

1. **Bootstrap.** h9build downloads Alpine's minirootfs and Railpack's static
   binary once. Alpine's `apk` is the only package manager h9build needs to
   start: it reads Wolfi's repository just as well.
2. **Roots.** In an h9 machine on the Alpine root, `apk --root` installs Wolfi
   packages into a root directory in the cache, keyed by the package set,
   which the machine has as an up layer. *base* has what Railpack's runtime
   image has: glibc, `libstdc++`, OpenSSL, zlib, certificates, `tzdata`,
   busybox, and bash, which mise's Node uses for its `npm` wrapper. *builder*
   adds what Railpack's builder image has for building: gcc, make, cmake, the
   autotools, git, jq, and the usual headers (OpenSSL, zlib, readline,
   SQLite, libffi, libyaml, ICU, ...).
3. **Plan.** In a machine on the builder root, `railpack plan` reads the source
   and writes `plan.json`, and `guest/plan.sh` reads it into plain text the
   host side acts on: which layer each step builds in, each layer's key, the
   paths the plan deploys, and its apt packages. The plan is kept with a key
   of every source file, Railpack, and `plan.sh`, and Railpack runs again only
   when the key changes, as planning is most of a build with nothing changed.
   A kept plan keeps the versions Railpack resolved, until the source changes
   or `H9BUILD_REPLAN=1`.
4. **Packages.** The plan's apt steps name Debian packages for Railpack's
   Debian images (`libjemalloc2`, `libyaml-dev`, `libatomic1`). h9build maps
   them to Wolfi's names, with a table for the common ones and guesses for the
   rest (the name without its version or its `lib`), and adds the build ones
   to the builder root and the runtime ones to the base root.
5. **Layers.** The steps build in three layers, in order: *runtime* (the
   `packages:` steps, mise's), *deps* (`install`), and *app* (the rest). Each
   is its own machine, on the builder root with the layers below it stacked
   over it, and the new layer's directory as the up layer on top, so whatever
   its steps change anywhere in the root lands there and nothing below is
   touched. `guest/build.sh` carries out the layer's steps as Railpack's
   BuildKit backend would, with the earlier layers' variables and PATH. Each
   layer builds in `LAYER.tmp` and takes its name when its steps succeed.
   The runtime layer is shared between apps (below), so the files its steps
   copy from the source (a `mise.toml`) are left out of it and copied in the
   deps layer instead.
6. **Caching.** A layer's key hashes its steps and the source files they copy
   in, chained with the keys below it. When it matches the last build's, the
   layer is kept, so changing the app's code rebuilds only the app layer, and
   a build with nothing changed takes a few seconds. The runtime layer is
   kept in the cache rather than the output, under a key of the builder root
   and the plan's runtime steps: the mise config with Railpack's resolved
   versions, and any `mise.toml` the steps copy in, but not idiomatic version
   files such as `.nvmrc` or a `Gemfile`, whose versions the plan has already
   resolved. Every app with the same tools at the same versions uses the
   same layer, so a runtime is installed once per machine.
7. **Pruning.** The app layer keeps only the paths the plan deploys from it,
   less their excludes, with a whiteout for an exclude a layer below holds
   (Rust's `target`). The run stacks the runtime layer only when the plan
   deploys from a packages step (a Go binary doesn't need its toolchain), and
   the deps layer only when it holds a path the plan deploys. When what the
   app deploys from the deps layer is small (Rust's `Cargo.lock`, Go's
   `go.sum`), it's copied into the app layer instead, so the run doesn't
   stack hundreds of MB of `target` for it.
8. **Run.** `run` stacks the layers read-only over the base root, with the
   plan's variables and start command.

## Where it stands

Tried on x86\_64 Linux with h9's native backend (`H9_FLAGS=--backend native`)
on Railpack's own example apps. The build times are with the roots and
downloads in the cache; *rebuilt* is a second build with nothing changed.

| Example | Build | Rebuilt | Layers run | Run |
| --- | --- | --- | --- | --- |
| `go-mod` | 2 min | 4 s | app 2.1 MB (no runtime: the plan doesn't deploy Go) | prints its test's expected output |
| `node-lts-npm-native-deps` (bcrypt, better-sqlite3, canvas, sharp) | 90 s | 3 s | runtime 208 MB, deps 92 MB, app 60 KB | prints its test's expected output |
| `node-npm` | 90 s | 3 s | runtime 195 MB, deps 25 MB, app 32 KB | prints its test's expected output |
| `node-bun` | 50 s | 3 s | runtime 311 MB, deps 27 MB, app 36 KB | prints its test's expected output |
| `python-uv` (Flask on gunicorn) | 30 s | 10 s | runtime 126 MB, deps 7 MB (the venv), app 48 KB | serves "Hello from Python UV!" |
| `deno-2` | 30 s | 2 s | runtime 123 MB, app 328 KB (its `deno cache`) | prints its test's expected output |
| `ruby-latest` (Ruby 4) | 100 s | 3 s | runtime 420 MB, deps 3.5 MB (gems), app 32 KB | prints its test's expected output |
| `cpp-cmake` | 40 s | 4 s | app 268 KB | prints its test's expected output |
| `gleam` (Erlang from Hex) | 25 s | 1 s | runtime 204 MB (Erlang and Gleam), app 328 KB | prints its test's expected output |
| `elixir-latest` (a Mix release) | 50 s | 1 s | app 67 MB (the release carries Erlang) | prints its test's expected output |
| `rust-rocket` | 4.5 min | 1 s | app 5.2 MB (no runtime, and not the deps layer's 480 MB of `target` and cargo registry) | "Rocket has launched" |
| `zig` | 4.5 min | 1 s | app 3.9 MB | prints its test's expected output |
| `dotnet-cli` (.NET 6) | 40 s | 1 s | runtime 498 MB, app 180 KB | prints its test's expected output |
| `dotnet-api` (ASP.NET 8) | 90 s | 1 s | runtime 569 MB, app 4 MB | serves `/WeatherForecast` |

With the plan kept and the runtime layers shared, a build with nothing changed
takes about half a second (0.4 to 0.7 s for six of the examples above, down from 2 to
2.6 s), and a second app on runtimes another app already installed skips
installing them: on copies of the examples, Ruby built in 7 s rather than 70 s,
Python in 7 s rather than 25 s, and Node in 24 s rather than 47 s. Go's build
is mostly `go build` itself, so it went from 105 s to 67 s.

What doesn't build yet, and why:

- **Ruby, older versions:** h9build has mise use its precompiled Ruby
  (`MISE_RUBY_COMPILE=false`), which mise has for recent versions only.
  `ruby-sinatra` pins 3.1.2, which would be built from source by ruby-build,
  and that hung in h9 after 25 minutes. `H9BUILD_RUBY_COMPILE=1` tries it.
- **PHP:** Railpack's PHP plans build on FrankenPHP's container image, which
  h9build doesn't fetch.
- **Java:** not tried: mise's Java versions list didn't download here.

Also seen: uv's bytecode compiling (`UV_COMPILE_BYTECODE=1`, which Railpack's
Python plans set) now and then panics with "failed to wake I/O driver: Bad
file descriptor", or hangs, in h9. A rebuild usually gets past it.

Erlang comes from Hex's prebuilt OTP for Ubuntu 24.04 (builds.hex.pm), put
where mise would install it, so mise takes it as installed and installs
Elixir or Gleam over it. mise would build Erlang from source with kerl,
which takes minutes natively and didn't finish in h9. Hex's `crypto` NIF is
linked against Ubuntu's libcrypto, which has SM4 (`EVP_sm4_cbc`), and Wolfi's
leaves SM4 out, so the NIF wouldn't load and Mix couldn't fetch Hex over TLS.
h9build gives it Ubuntu 24.04's libcrypto in `/usr/lib/x86_64-linux-gnu`, the
first place the NIF's RUNPATH looks and a place nothing else does. That's in
the runtime layer, and it goes into the app layer when the run doesn't stack
the runtime, as with a Mix release, which carries Erlang and its `crypto`.

The venv is in the deps layer, and its `python` is an absolute link into the
runtime layer (`/mise/installs/python/...`): that resolves because h9 follows
a Linux program's links from its root
([linux-symlinks](https://github.com/progrium/hyper9/blob/main/design/linux-symlinks.md)).

h9build needs an h9 with up layers
([upper-layers](https://github.com/progrium/hyper9/blob/main/design/upper-layers.md)),
including [progrium/hyper9#254](https://github.com/progrium/hyper9/pull/254), which
makes a working directory from below a layer see what's changed in it since: the
build steps run in `/app`, which is usually below. Rust, Zig, and .NET need
the Linux fixes these examples turned up:

| Fix | Needed by |
| --- | --- |
| [#257](https://github.com/progrium/hyper9/pull/257): `lseek(SEEK_END)` on long names, `mremap` over joined mappings | rustup's downloads; `zig build` |
| [#258](https://github.com/progrium/hyper9/pull/258): `sched_getparam` | MSBuild, which `dotnet restore` hung in |
| [#263](https://github.com/progrium/hyper9/pull/263): edge-triggered epoll sees a host socket's next data | NuGet's downloads through a proxy |
| [#264](https://github.com/progrium/hyper9/pull/264): a signal breaks a pipe read waiting behind another; `getsockname` before `listen` | cargo's jobserver; Kestrel (`dotnet-api`) |

Not tried yet: arm64 and macOS.

These runs were in a sandbox behind an HTTPS proxy, which took two things a
normal machine doesn't need. The first was a Railpack built with a patch that
passes the proxy settings through to the mise it runs, as the release clears
them (`H9BUILD_RAILPACK` names it). The second was
`H9_FLAGS="--env MISE_GITHUB_ATTESTATIONS=false --env MISE_AQUA_COSIGN=false
--env MISE_AQUA_SLSA=false"`, as the proxy refused the GitHub API and
Sigstore calls that mise makes to check what it downloads. That breaks
`ruby-3-precompiled`, whose `mise.lock` requires them.

What it leaves out, for now:

- **A tighter sandbox.** The build machines can write only the output
  directory, or a new runtime layer in the cache, but they have the network
  with `--net enable`, because Mix listens on 127.0.0.1 for its lock and
  `--net outbound` refuses any listen. An h9 mode for outbound connections
  plus loopback listens would fit better, and `--net-allow` for the
  registries a plan uses would close it further.
- **Pruning dev dependencies.** Railpack's plans keep them unless told
  otherwise (`RAILPACK_PRUNE_DEPS`).
- **Caching the source.** The plan's key and the app layer's key hash every
  source file, so any change plans again and rebuilds the app layer, as it
  should; a large tree is hashed on every build.
- **Cleaning the cache.** Runtime layers nothing uses any more stay in
  `$cache/runtimes` until removed by hand.

## What h9 still needs worked around

- **apk's scripts** need `chroot`, which h9 doesn't have, so apk runs with
  `--no-scripts`, and h9build makes busybox's applet links itself. And since
  Alpine's apk keeps its database in `/lib/apk`, roots.sh makes the root's
  `/lib -> usr/lib` link first, so the database lands in `/usr/lib/apk`.
- **mise's shims** are links to the mise binary, which only the builder has,
  and would run every command through mise. h9build puts the runtimes' own
  bin directories on `PATH` instead, and keeps the shims in `/tmp`.
- **inotify**, which h9 doesn't have, is how .NET watches its config
  files, and ASP.NET fails to start without it. The run sets
  `DOTNET_USE_POLLING_FILE_WATCHER=1` for a .NET plan, so it polls instead.
- **Package manager caches** are pointed at the output's `cache/`
  (`npm_config_cache`, `UV_CACHE_DIR`, `GOMODCACHE`, ...), over the plan's own
  cache directories. Left where the plan puts them, they'd land in the layers.

The workarounds before up layers are gone. Those were: `/mise` and `/app` as
`--bind`s, because a writable `#L` member refused renames across directories
with `EXDEV`; the roots built in memory and tarred out, because apk's
symlinks couldn't be made in a host tree; and moving the deps out of `/app`
after the build.

## Environment

| Variable | |
| --- | --- |
| `H9` | The h9 binary (default `h9` on `PATH`) |
| `H9_FLAGS` | Extra flags for every h9 run, such as `--backend native` |
| `H9BUILD_CACHE` | The cache (default `${XDG_CACHE_HOME:-~/.cache}/h9build`) |
| `H9BUILD_BASE_PACKAGES` | More Wolfi packages for the base root |
| `H9BUILD_BUILD_PACKAGES` | More Wolfi packages for the builder root |
| `H9BUILD_MEMORY` | Guest memory for the build machines (default `4G`) |
| `H9BUILD_RAILPACK` | A Railpack binary to use instead of the release |
| `H9BUILD_RUBY_COMPILE` | `1` builds Ruby from source rather than using mise's precompiled one |
| `H9BUILD_REPLAN` | `1` runs Railpack's planner even when the source hasn't changed |
| `HTTPS_PROXY`, `SSL_CERT_FILE` | Passed into the guest when set |
