//! The browser target: `zig build web` (the default step) builds everything
//! the pages load into zig-out/ (README.md). Each part is built by its own
//! build, as on the desktop:
//!
//!   h9's browser host     third_party/hyper9's `zig build web`, its
//!                         h9.wasm stripped of DWARF by wasm-opt
//!   root.h9a              root.list's files from a 386 root tree
//!                         (-Droot386, made from the 9front ISO: README.md)
//!   the core              core's `zig build -Dtarget=wasm32-wasi`, with
//!                         libghostty-vt unless -Dterminal=plain
//!   terminal renderer     renderer/tui's, the same way
//!   GPUI renderer         crates/web on the pinned nightly (rust-nightly),
//!                         then wasm-bindgen, plus GPUI Kit's icons
//!
//! then the pages, the examples, sw.js stamped with the build's hash, and
//! .gz and .br copies of the big files (finish.sh).
//!
//!   zig build test        the browser tests (test/run.mjs) on zig-out/
//!
//! Needs, besides Zig: rustup (it installs the nightly on first use),
//! wasm-bindgen-cli at Cargo.lock's version, wasm-opt (binaryen), and
//! brotli if .br copies are wanted. -Dgpui=false skips the Rust build.

const std = @import("std");

/// The nightly the GPUI renderer builds with: gpui-kit turns on gpui_web's
/// `multithreaded` feature, whose wasm_thread needs nightly Rust (the
/// renderer runs gpui_web single-threaded all the same). CI reads the
/// same file.
const nightly = std.mem.trim(u8, @embedFile("rust-nightly"), " \t\r\n");

/// The pages and their scripts, copied as they are (sw.js is stamped).
const pages = [_][]const u8{
    "index.html",  "gpui.html",          "tui.html",   "core-test.html", "tui-test.html",
    "apps.js",     "cache.js",           "gpui.js",    "h9-worker.js",   "probe.js",
    "tree.js",     "tui.js",             "uit-web.js", "uitcore-imports.js",
};

/// The examples (apps.js): each in apps/NAME/ with the files it reads,
/// from tests/conformance/examples, or web/ for the tour.
const App = struct { name: []const u8, files: []const []const u8 };
const apps = [_]App{
    .{ .name = "counter", .files = &.{ "rc/counter.rc", "rc/lib.rc" } },
    .{ .name = "hello", .files = &.{ "rc/hello.rc", "rc/lib.rc" } },
    .{ .name = "confirm", .files = &.{ "rc/confirm.rc", "rc/lib.rc" } },
    .{ .name = "signin", .files = &.{ "rc/signin.rc", "rc/lib.rc" } },
    .{ .name = "settings", .files = &.{ "rc/settings.rc", "rc/lib.rc" } },
    .{ .name = "files", .files = &.{ "rc/files.rc", "rc/lib.rc" } },
    .{ .name = "csvview", .files = &.{ "awk/csvview.awk", "awk/planets.csv" } },
    .{ .name = "tour", .files = &.{ "@tour/tour.rc", "@tour/notes.md", "@tour/pic.png", "rc/lib.rc" } },
    // The page shows main.go; the program itself is built below.
    .{ .name = "repl", .files = &.{"go/repl/main.go"} },
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Zig parts' optimize mode (default ReleaseSmall)") orelse .ReleaseSmall;
    const gpui = b.option(bool, "gpui", "Build the GPUI renderer (Rust; default true)") orelse true;
    const root386 = b.option([]const u8, "root386", "386 root tree for root.h9a (default third_party/hyper9/.local/9front/root386)") orelse
        b.pathFromRoot("../third_party/hyper9/.local/9front/root386");
    // The core's terminal engine (core/README.md): ghostty, its default,
    // or plain, which needs no Zig 0.17. Passed to all three core builds.
    const terminal = b.option([]const u8, "terminal", "The core's terminal engine: ghostty or plain (core/build.zig's default)");
    const opt = b.fmt("-Doptimize={s}", .{@tagName(optimize)});
    const zig = b.graph.zig_exe;
    const dir = struct {
        fn at(bb: *std.Build, rel: []const u8) std.Build.LazyPath {
            return .{ .cwd_relative = bb.pathFromRoot(rel) };
        }
    }.at;

    const web = b.step("web", "Build the browser target into zig-out/ (README.md)");
    b.default_step = web;
    const install = b.getInstallStep();

    // h9's browser host, unchanged. Its own root archive is left out
    // (-Dweb-root names no tree): root.h9a is built from root.list below.
    const h9 = b.addSystemCommand(&.{ zig, "build", "web", "-Doptimize=ReleaseFast", "-Dweb-root=/nonexistent", "--prefix" });
    h9.setCwd(dir(b, "../third_party/hyper9"));
    h9.has_side_effects = true;
    const h9_out = h9.addOutputDirectoryArg("h9");
    for ([_][]const u8{ "h9-web.js", "worker.js", "wasi-mem.js", "statictree.js" }) |f|
        install.dependOn(&b.addInstallFileWithDir(h9_out.path(b, b.fmt("web/{s}", .{f})), .prefix, b.fmt("h9/{s}", .{f})).step);
    // h9.wasm without its DWARF, which is 12.9 of its 17.5 MB (README.md, Size).
    const strip = b.addSystemCommand(&.{ "wasm-opt", "--all-features", "--strip-debug", "--strip-producers" });
    strip.addFileArg(h9_out.path(b, "web/h9.wasm"));
    strip.addArg("-o");
    install.dependOn(&b.addInstallFileWithDir(strip.addOutputFileArg("h9.wasm"), .prefix, "h9/h9.wasm").step);

    // The root: only what the examples run (root.list), from the 386 tree.
    const root = b.addSystemCommand(&.{ zig, "run", "-OReleaseSafe", "tools/webroot.zig", "--", root386 });
    root.setCwd(dir(b, "../third_party/hyper9"));
    root.addFileArg(b.path("root.list"));
    install.dependOn(&b.addInstallFileWithDir(root.addOutputFileArg("root.h9a"), .prefix, "h9/root.h9a").step);

    // The core alone (core-test.html) and the terminal renderer with the
    // core linked in, each as a wasm32-wasi reactor.
    const zig_parts = [_]struct { dir: []const u8, file: []const u8, extra: []const []const u8 }{
        .{ .dir = "../core", .file = "uitcore.wasm", .extra = &.{} },
        .{ .dir = "../renderer/tui", .file = "uitree-tui.wasm", .extra = &.{"-Dh9=false"} },
    };
    for (zig_parts) |p| {
        const run = b.addSystemCommand(&.{ zig, "build", "-Dtarget=wasm32-wasi", opt });
        run.addArgs(p.extra);
        if (terminal) |t| run.addArg(b.fmt("-Dterminal={s}", .{t}));
        run.setCwd(dir(b, p.dir));
        run.has_side_effects = true;
        run.addArg("--prefix");
        const out = run.addOutputDirectoryArg("out");
        install.dependOn(&b.addInstallFileWithDir(out.path(b, b.fmt("web/{s}", .{p.file})), .prefix, p.file).step);
    }

    // The GPUI renderer: crates/web on the pinned nightly, with the core
    // linked in (uitcore-sys builds it for wasm32-wasi), through
    // wasm-bindgen; and GPUI Kit's icons, which it fetches one by one from
    // assets/icons/NAME.svg beside the page.
    if (gpui) {
        const target_dir = b.graph.environ_map.get("CARGO_TARGET_DIR") orelse b.pathFromRoot("../renderer/gpui/target");
        const cargo = b.addSystemCommand(&.{
            "cargo",                b.fmt("+{s}", .{nightly}), "build",       "-p",                 "uitree-web",
            "--target",             "wasm32-unknown-unknown",  "--profile",   "web",                "--target-dir",
            target_dir,
        });
        cargo.setCwd(dir(b, "../renderer/gpui"));
        cargo.setEnvironmentVariable("UITCORE_OPTIMIZE", @tagName(optimize));
        if (terminal) |t| cargo.setEnvironmentVariable("UITCORE_TERMINAL", t);
        cargo.setEnvironmentVariable("RUSTFLAGS", "--cfg getrandom_backend=\"wasm_js\"");
        cargo.has_side_effects = true;
        const bindgen = b.addSystemCommand(&.{
            "wasm-bindgen", b.pathJoin(&.{ target_dir, "wasm32-unknown-unknown/web/uitree_web.wasm" }),
            "--target",     "web",
            "--no-typescript", "--remove-name-section",
            "--out-dir",
        });
        bindgen.step.dependOn(&cargo.step);
        bindgen.has_side_effects = true;
        install.dependOn(&b.addInstallDirectory(.{ .source_dir = bindgen.addOutputDirectoryArg("gpui"), .install_dir = .prefix, .install_subdir = "gpui" }).step);

        const icons = b.addSystemCommand(&.{ "sh", b.pathFromRoot("kit-icons.sh") });
        icons.setCwd(dir(b, "../renderer/gpui"));
        icons.has_side_effects = true;
        install.dependOn(&b.addInstallDirectory(.{ .source_dir = icons.addOutputDirectoryArg("icons"), .install_dir = .prefix, .install_subdir = "assets/icons" }).step);
    }

    for (pages) |f| install.dependOn(&b.addInstallFileWithDir(b.path(f), .prefix, f).step);
    for (apps) |a| for (a.files) |f| {
        const src = if (std.mem.startsWith(u8, f, "@")) b.path(f[1..]) else dir(b, b.fmt("../tests/conformance/examples/{s}", .{f}));
        install.dependOn(&b.addInstallFileWithDir(src, .prefix, b.fmt("apps/{s}/{s}", .{ a.name, std.fs.path.basename(f) })).step);
    };
    // repl, the terminal node's stream-mode demo (examples/go/repl), is a
    // Go program: built for the 386 CPU h9 emulates in the browser.
    // -Drepl=false skips it, for a machine without go.
    if (b.option(bool, "repl", "Build the Go repl example (needs go; default true)") orelse true) {
        const go = b.addSystemCommand(&.{ "go", "build", "-trimpath", "-o" });
        go.setCwd(dir(b, "../tests/conformance/examples/go/repl"));
        go.setEnvironmentVariable("GOOS", "plan9");
        go.setEnvironmentVariable("GOARCH", "386");
        go.setEnvironmentVariable("CGO_ENABLED", "0");
        const exe = go.addOutputFileArg("repl");
        go.addArg(".");
        go.has_side_effects = true;
        install.dependOn(&b.addInstallFileWithDir(exe, .prefix, "apps/repl/repl").step);
    }

    // sw.js with the build's hash, and the .gz and .br copies.
    const finish = b.addSystemCommand(&.{ "sh", b.pathFromRoot("finish.sh"), b.install_prefix });
    finish.addFileArg(b.path("sw.js"));
    finish.step.dependOn(install);
    finish.has_side_effects = true;
    web.dependOn(&finish.step);

    // The browser tests on what web built (README.md, Tests).
    const t = b.addSystemCommand(&.{ "node", "test/run.mjs", "--dir", b.install_prefix });
    t.setCwd(b.path("."));
    t.has_side_effects = true;
    if (b.args) |args| t.addArgs(args);
    t.step.dependOn(web);
    b.step("test", "Run the browser tests on zig-out/ (test/run.mjs; args after --)").dependOn(&t.step);
}
