//! zig build              uitree-tui, the terminal host (zig-out/bin)
//! zig build test         the renderer's unit tests (no terminal, no h9)
//! zig build run -- ARGS  build and run uitree-tui
//!
//! Needs Zig 0.16, the same pin as the core and hyper9.
//!
//! The core is linked as libuitcore.a and seen only through
//! include/uitcore.h (translated with translate-c), never by importing the
//! core's Zig modules: the C ABI is the only boundary, as for GPUI.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // h9 on by default: a host without it can't run apps. Tests don't need it.
    const with_h9 = b.option(bool, "h9", "Link hyper9 into the core (default true)") orelse true;

    const uitcore = b.dependency("uitcore", .{ .target = target, .optimize = optimize, .h9 = with_h9 });
    const core_lib = uitcore.artifact("uitcore");

    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

    // Yoga: the C API (yoga/Yoga.h) over its C++ core, built from source.
    const yoga_src = b.dependency("yoga", .{});
    const yoga = b.addLibrary(.{
        .name = "yoga",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true }),
    });
    yoga.root_module.addIncludePath(yoga_src.path(""));
    yoga.root_module.addCSourceFiles(.{
        .root = yoga_src.path("yoga"),
        .files = &yoga_files,
        .flags = &.{ "-std=c++20", "-fno-exceptions", "-fno-rtti", "-Wno-everything" },
    });

    // uitcore.h and Yoga.h as one Zig module, `c`.
    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(uitcore.path("include"));
    c.addIncludePath(yoga_src.path(""));
    const c_mod = c.createModule();

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
            .{ .name = "vaxis", .module = vaxis.module("vaxis") },
        },
    });
    mod.addAnonymousImport("types", .{ .root_source_file = b.path("types/types.zig") });
    mod.linkLibrary(yoga);

    mod.linkLibrary(core_lib);

    // The browser build (uitree/web/README.md): uitree-tui.wasm, a wasm
    // reactor the page drives (src/web.zig), with the core's coroutines.
    if (target.result.os.tag == .wasi) {
        mod.root_source_file = b.path("src/web.zig");
        mod.single_threaded = true;
        mod.linkLibrary(uitcore.artifact("h9coro"));
        const wasm = b.addExecutable(.{ .name = "uitree-tui", .root_module = mod });
        wasm.entry = .disabled;
        wasm.wasi_exec_model = .reactor;
        wasm.rdynamic = true;
        wasm.export_table = true;
        wasm.stack_size = 1 << 20;
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "web" }, "uitree-tui.wasm").step);
        return;
    }
    const exe = b.addExecutable(.{ .name = "uitree-tui", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run uitree-tui").dependOn(&run.step);

    // The unit tests cover layout, style and drawing on an off-screen
    // grid, and one round trip through the real core.
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the renderer's unit tests").dependOn(&b.addRunArtifact(tests).step);
}

const yoga_files = [_][]const u8{
    "YGConfig.cpp",
    "YGEnums.cpp",
    "YGNode.cpp",
    "YGNodeLayout.cpp",
    "YGNodeStyle.cpp",
    "YGPixelGrid.cpp",
    "YGValue.cpp",
    "algorithm/AbsoluteLayout.cpp",
    "algorithm/Baseline.cpp",
    "algorithm/Cache.cpp",
    "algorithm/CalculateLayout.cpp",
    "algorithm/FlexLine.cpp",
    "algorithm/PixelGrid.cpp",
    "config/Config.cpp",
    "debug/AssertFatal.cpp",
    "debug/Log.cpp",
    "event/event.cpp",
    "node/LayoutResults.cpp",
    "node/Node.cpp",
};
