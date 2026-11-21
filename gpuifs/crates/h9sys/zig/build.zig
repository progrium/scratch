//! Builds shim.zig into libh9sys.a against a hyper9 checkout, for build.rs.
//!
//! build.rs copies this file and shim.zig into its OUT_DIR, writes a
//! build.zig.zon whose `h9` dependency is a path to the checkout, and runs
//! `zig build`. The install step puts `libh9sys.a` and the drawterm kern
//! library it needs (`libkern.a`) in `zig-out/lib`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const emu = b.option([]const u8, "emu", "h9's emulator backend: hcpu (default) or none") orelse "hcpu";

    const h9 = b.dependency("h9", .{
        .target = target,
        .optimize = optimize,
        .emu = emu,
        .gfx = @as([]const u8, "none"),
    });
    const h9mod = h9.module("h9");

    const lib = b.addLibrary(.{
        .name = "h9sys",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("shim.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Rust links its own compiler builtins.
            .imports = &.{.{ .name = "h9", .module = h9mod }},
        }),
    });
    lib.bundle_compiler_rt = true;
    b.installArtifact(lib);

    // The kern library the h9 module links: a static library doesn't carry
    // the libraries its modules link, so the Rust side links it too.
    for (h9mod.link_objects.items) |lo| switch (lo) {
        .other_step => |step| b.installArtifact(step),
        else => {},
    };
}
