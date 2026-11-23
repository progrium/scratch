//! zig build              libuitcore.a, include/uitcore.h, uitree-headless
//! zig build test         every module's unit tests
//! zig build -Dh9=true    link hyper9 (needs the third_party/hyper9 submodule)
//!
//! Needs Zig 0.16, the same pin as hyper9. No Rust.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Off in the scaffold so the core builds without the submodule. The
    // spike (W0) turns it on once machine/ calls h9.Machine.
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
        })) |h9| core.addImport("h9", h9.module("h9"));
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
    b.installArtifact(headless);

    const tests = b.addTest(.{ .root_module = core });
    const test_step = b.step("test", "Run the core's unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
