//! zig build              libuitcore.a, include/uitcore.h, uitree-headless
//! zig build test         every module's unit tests
//! zig build -Dh9=true    link hyper9 (needs the third_party/hyper9 submodule)
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
    core.addOptions("build_options", opts);

    // libuitcore.a: the core as one static library for renderers in other
    // languages. Rust links its own compiler builtins, so bundle ours.
    const lib = b.addLibrary(.{ .name = "uitcore", .linkage = .static, .root_module = core });
    lib.bundle_compiler_rt = true;
    b.installArtifact(lib);
    b.installFile("include/uitcore.h", "include/uitcore.h");

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
    if (target.result.abi != .msvc) b.installArtifact(headless);

    const tests = b.addTest(.{ .root_module = core });
    const test_step = b.step("test", "Run the core's unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
