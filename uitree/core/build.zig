//! zig build              libuitcore.a, include/uitcore.h, uitree-headless
//! zig build test         every module's unit tests
//! zig build -Dh9=true    link hyper9 (needs the third_party/hyper9 submodule)
//! zig build smoke        build libghostty-vt's smoke test (tests/vt-smoke.zig)
//!                        and run it natively; on wasm32-wasi, install
//!                        zig-out/web/vt-smoke.wasm for tests/vt-smoke.mjs
//!
//! -Dterminal=ghostty     the terminal engine is libghostty-vt (the default
//!                        but on Windows), built by ../tools/ghostty-vt with
//!                        its own Zig 0.17, or taken from -Dghostty-vt=PREFIX
//! -Dterminal=plain       the plain-text stand-in: no Zig 0.17, no download
//!
//! Needs Zig 0.16, the same pin as hyper9. No Rust.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Off by default so `zig build test` needs no submodule. Renderers
    // build with -Dh9=true (renderer/gpui's build.rs does), which links
    // h9.Machine into libuitcore.a and installs libkern.a beside it.
    const with_h9 = b.option(bool, "h9", "Link hyper9 for h9 sandboxes (default false)") orelse false;

    const core = b.addModule("uitcore", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.addAnonymousImport("uitcore.h", .{ .root_source_file = b.path("include/uitcore.h") });
    core.addIncludePath(b.path("include"));
    // W1: every descriptor in types/, compiled in (src/types/embedded.zig).
    core.addAnonymousImport("uit_types", .{ .root_source_file = b.path("types/embed.zig") });

    if (with_h9) {
        if (b.lazyDependency("h9", .{
            .target = target,
            .optimize = optimize,
            .gfx = @as([]const u8, "none"),
        })) |h9| {
            const h9mod = h9.module("h9");
            core.addImport("h9", h9mod);
            // A static library doesn't carry the libraries its modules
            // link, so install them for the renderer to link too (the
            // drawterm kern library, libkern.a).
            for (h9mod.link_objects.items) |lo| switch (lo) {
                .other_step => |step| b.installArtifact(step),
                else => {},
            };
        }
    }
    const opts = b.addOptions();
    opts.addOption(bool, "h9", with_h9);

    // The terminal engine (core/src/term/): libghostty-vt, or the
    // plain-text stand-in. build_options.terminal says which; with
    // ghostty, the module `ghostty_vt` is <ghostty/vt.h>, and
    // libghostty-vt goes into libuitcore.a as one more object, so a
    // renderer links nothing more. It needs no C++ library: its C++ (simdutf, Highway)
    // calls only libc.
    const terminal = b.option(Terminal, "terminal", "Terminal engine: ghostty (libghostty-vt) or plain (default ghostty, plain on Windows)") orelse
        if (target.result.os.tag == .windows) Terminal.plain else Terminal.ghostty;
    opts.addOption(Terminal, "terminal", terminal);
    core.addOptions("build_options", opts);
    const vt = if (terminal == .ghostty) ghosttyVt(b, target, optimize) else null;
    if (vt) |v| {
        core.addImport("ghostty_vt", v.module);
        core.addObjectFile(v.lib);
        if (target.result.cpu.arch.isWasm()) core.addCSourceFile(.{
            .file = b.addWriteFiles().add("vt_extxftf2.c", vt_extxftf2),
            .flags = &.{"-std=c11"},
        });
    }

    // The browser build (src/web.zig, web/README.md): on wasm32-wasi the
    // core's threads are hyper9's web-host coroutines, from the submodule's
    // src/web.zig and src/web/coro.c. h9 itself isn't linked.
    const is_web = target.result.os.tag == .wasi;
    var coro: ?*std.Build.Step.Compile = null;
    if (is_web) {
        if (with_h9) @panic("-Dh9 isn't for the web build: the app's machine runs in h9's own Worker");
        core.single_threaded = true;
        if (b.lazyDependency("h9", .{})) |h9| {
            core.addAnonymousImport("h9web", .{ .root_source_file = h9.path("src/web.zig") });
            coro = addCoroutines(b, core, h9);
        }
    }

    // libuitcore.a: the core as one static library for renderers in other
    // languages. Bundle our compiler builtins: Rust's don't have the f128
    // math (cosq, fabsq, ...) h9's emulator uses on MSVC. (W8: the
    // LNK1143 seen on Windows came from a windows-gnu build of this lib,
    // which uitcore-sys no longer makes for an MSVC target.)
    const lib = b.addLibrary(.{ .name = "uitcore", .linkage = .static, .root_module = core });
    lib.bundle_compiler_rt = true;
    b.installArtifact(lib);
    b.installFile("include/uitcore.h", "include/uitcore.h");

    if (is_web) {
        // uitcore.wasm: the core alone as a wasm reactor whose exports are
        // uitcore.h (and libc's malloc and free, for a renderer in JS), for
        // web/core-test.html. A renderer links libuitcore.a and
        // libh9coro.a instead: renderer/tui's web build, and GPUI's
        // through uitcore-sys. web/README.md, "The core's platform".
        const wasm = b.addExecutable(.{ .name = "uitcore-web", .root_module = core });
        configureWeb(wasm);
        wasm.root_module.export_symbol_names = &.{ "malloc", "free" };
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "web" }, "uitcore.wasm").step);

        // vt-smoke.wasm: libghostty-vt driven from a core coroutine, as a
        // reactor like uitcore.wasm, for tests/vt-smoke.mjs.
        if (vt) |v| {
            const smoke = b.addExecutable(.{ .name = "vt-smoke", .root_module = smokeModule(b, target, optimize, lib, v) });
            configureWeb(smoke);
            smoke.root_module.export_symbol_names = &.{ "malloc", "free" };
            if (coro) |c| smoke.root_module.linkLibrary(c);
            b.step("smoke", "Build zig-out/web/vt-smoke.wasm (run it with tests/vt-smoke.mjs)").dependOn(
                &b.addInstallFileWithDir(smoke.getEmittedBin(), .{ .custom = "web" }, "vt-smoke.wasm").step,
            );
        }
        return;
    }

    const headless = b.addExecutable(.{
        .name = "uitree-headless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/headless/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "uitcore", .module = core }},
        }),
    });
    // Zig can't supply an MSVC libc to link an exe; the library still
    // builds for x86_64-windows-msvc, which is what a Rust MSVC build links.
    if (target.result.abi != .msvc) {
        const install_headless = b.addInstallArtifact(headless, .{});
        b.getInstallStep().dependOn(&install_headless.step);
        // W8: on macOS, h9 runs on Hypervisor.framework, which a static
        // library can't carry, and HVF refuses hv_vm_create without the
        // hypervisor entitlement: link it and sign the installed binary
        // with hyper9's h9.entitlements, as hyper9's own build does for h9.
        if (with_h9 and target.result.os.tag == .macos) {
            headless.root_module.linkFramework("Hypervisor", .{});
            if (b.graph.host.result.os.tag == .macos) {
                const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
                sign.addFileArg(b.path("../third_party/hyper9/h9.entitlements"));
                sign.addArg(b.getInstallPath(.bin, headless.out_filename));
                sign.step.dependOn(&install_headless.step);
                b.getInstallStep().dependOn(&sign.step);
            }
        }
    }

    // A host with no renderer of its own, for 9P renderers and browsers
    // (protocols/render.md): `zig build remote`.
    // Not installed by default.
    const remote = b.addExecutable(.{
        .name = "uitree-remote",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/remote/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "uitcore", .module = core }},
        }),
    });
    const remote_step = b.step("remote", "Build uitree-remote, a host that only serves renderers");
    const install_remote = b.addInstallArtifact(remote, .{});
    remote_step.dependOn(&install_remote.step);
    // As for uitree-headless: HVF needs the framework and the entitlement.
    if (with_h9 and target.result.os.tag == .macos) {
        remote.root_module.linkFramework("Hypervisor", .{});
        if (b.graph.host.result.os.tag == .macos) {
            const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
            sign.addFileArg(b.path("../third_party/hyper9/h9.entitlements"));
            sign.addArg(b.getInstallPath(.bin, remote.out_filename));
            sign.step.dependOn(&install_remote.step);
            remote_step.dependOn(&sign.step);
        }
    }

    // W4: src/ninep/wire.zig is hyper9's dotl/wire.zig, vendored (see its
    // header). This fails when the submodule's copy has moved on.
    const check_wire = b.addSystemCommand(&.{ "sh", "-c", "tail -n +6 src/ninep/wire.zig | cmp -s - ../third_party/hyper9/src/dotl/wire.zig || { echo 'src/ninep/wire.zig differs from hyper9 src/dotl/wire.zig: re-vendor it' >&2; exit 1; }" });
    check_wire.setCwd(b.path("."));
    b.step("check-wire", "Check the vendored wire.zig matches the hyper9 submodule").dependOn(&check_wire.step);

    // The smoke test: libghostty-vt through libuitcore.a, on a core thread.
    const smoke_step = b.step("smoke", "Run libghostty-vt's smoke test (tests/vt-smoke.zig)");
    if (vt) |v| {
        if (target.result.abi != .msvc) {
            const smoke = b.addExecutable(.{ .name = "vt-smoke", .root_module = smokeModule(b, target, optimize, lib, v) });
            smoke_step.dependOn(&b.addRunArtifact(smoke).step);
        }
    } else smoke_step.dependOn(&b.addFail("zig build smoke needs -Dterminal=ghostty").step);

    const tests = b.addTest(.{ .root_module = core });
    const test_step = b.step("test", "Run the core's unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // W4: uitree-headless's own tests (argument parsing).
    const headless_tests = b.addTest(.{ .root_module = headless.root_module });
    test_step.dependOn(&b.addRunArtifact(headless_tests).step);
}

const Terminal = enum { ghostty, plain };

const Vt = struct {
    /// <ghostty/vt.h>, translated.
    module: *std.Build.Module,
    /// libghostty-vt.a's objects as one (tools/ghostty-vt).
    lib: std.Build.LazyPath,
};

/// libghostty-vt for the core's target: from -Dghostty-vt=PREFIX (an
/// install prefix with include/ and lib/libghostty-vt.a, such as
/// tools/ghostty-vt makes), or built by tools/ghostty-vt, which fetches
/// Ghostty's release and the Zig 0.17 it needs and keeps both, and what it
/// built, in uitree/.local. Debug and ReleaseSafe cores get a ReleaseFast
/// engine: it is a dependency, not code being debugged, and one fewer build.
fn ghosttyVt(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Vt {
    const prefix: std.Build.LazyPath = if (b.option([]const u8, "ghostty-vt", "A prebuilt libghostty-vt: an OUT from tools/ghostty-vt build")) |p|
        .{ .cwd_relative = b.pathFromRoot(p) }
    else blk: {
        const run = b.addSystemCommand(&.{"sh"});
        run.addFileArg(b.path("../tools/ghostty-vt"));
        run.addArgs(&.{
            "build",
            target.query.zigTriple(b.allocator) catch @panic("OOM"),
            if (optimize == .ReleaseSmall) "ReleaseSmall" else "ReleaseFast",
        });
        // Run every build, so a change to the script or its environment
        // is seen: its own cache (uitree/.local) makes a rerun a copy, and
        // the same bytes don't rebuild the core.
        run.has_side_effects = true;
        run.setName("libghostty-vt (tools/ghostty-vt)");
        break :blk run.addOutputDirectoryArg("ghostty-vt");
    };
    const h = b.addWriteFiles().add("ghostty_vt.h", "#include <ghostty/vt.h>\n");
    const tc = b.addTranslateC(.{ .root_source_file = h, .target = target, .optimize = optimize });
    tc.addIncludePath(prefix.path(b, "include"));
    // libghostty-vt.a as one object: Zig puts an archive given to a static
    // library in it whole (with LLVM), as a member a linker can't read.
    return .{ .module = tc.createModule(), .lib = prefix.path(b, "lib/ghostty-vt.o") };
}

/// libghostty-vt's wasm object calls this for compiler_rt's __extendxftf2
/// (f80 to f128), with Zig 0.17's signature: the result's address, then the
/// f80's (tools/ghostty-vt renames the call). The two formats share their
/// sign, 15-bit exponent and bias, so it is bit moves: drop the f80's
/// explicit integer bit and left-align the fraction.
const vt_extxftf2 =
    \\#include <stdint.h>
    \\typedef struct { uint64_t mant; uint16_t se; } f80;
    \\void __vt_extxftf2(uint64_t out[2], const f80 *x) {
    \\    out[0] = x->mant << 49;
    \\    out[1] = ((uint64_t)x->se << 48) | ((x->mant & 0x7fffffffffffffffull) >> 15);
    \\}
    \\
;

/// tests/vt-smoke.zig, linking libuitcore.a as a renderer does, with
/// <ghostty/vt.h> to call the engine by.
fn smokeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, lib: *std.Build.Step.Compile, vt: Vt) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("tests/vt-smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ghostty_vt", .module = vt.module }},
    });
    if (target.result.os.tag == .wasi) m.single_threaded = true;
    m.linkLibrary(lib);
    return m;
}

/// h9's web-host coroutines (h9's src/web/coro.c, design/epoch-0/browser-host.md
/// in hyper9): coro.c, the shadow-stack accessors, and wasi-libc's
/// setjmp/longjmp runtime on wasm exception handling, which coro.c's exit
/// path uses.
fn addCoroutines(b: *std.Build, m: *std.Build.Module, h9: *std.Build.Dependency) *std.Build.Step.Compile {
    // Only these objects get exception handling, as in hyper9's own web
    // build (its kern library): wasi-libc and Zig code are built without.
    const t = m.resolved_target.?;
    var q = t.query;
    q.cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling});
    const lib = b.addLibrary(.{ .name = "h9coro", .linkage = .static, .root_module = b.createModule(.{
        .target = b.resolveTargetQuery(q),
        .optimize = .ReleaseFast,
        .link_libc = true,
    }) });
    const flags: []const []const u8 = &.{ "-mllvm", "-wasm-enable-sjlj" };
    lib.root_module.addCSourceFiles(.{ .root = h9.path("src/web"), .files = &.{"coro.c"}, .flags = flags });
    lib.root_module.addAssemblyFile(h9.path("src/web/stack.S"));
    lib.root_module.addCSourceFile(.{
        .file = .{ .cwd_relative = b.pathJoin(&.{ b.graph.zig_lib_directory.path orelse ".", "libc/wasi/libc-top-half/musl/src/setjmp/wasm32/rt.c" }) },
        .flags = flags,
    });
    m.linkLibrary(lib);
    b.installArtifact(lib);
    return lib;
}

/// A wasm reactor: no _start, every export kept, and room for the
/// coroutines' stacks (each its own allocation; this is the first's).
pub fn configureWeb(exe: *std.Build.Step.Compile) void {
    exe.entry = .disabled;
    exe.wasi_exec_model = .reactor;
    exe.rdynamic = true;
    exe.stack_size = 1 << 20;
    // The page grows the function table for nothing, but h9-web.js-style
    // hosts expect it exported.
    exe.export_table = true;
}
