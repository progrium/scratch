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
    core.addOptions("build_options", opts);

    // libuitcore.a: the core as one static library for renderers in other
    // languages. Bundle our compiler builtins (Rust links its own too).
    const lib = b.addLibrary(.{ .name = "uitcore", .linkage = .static, .root_module = core });
    // Not for MSVC: link.exe rejects Zig's compiler_rt object (LNK1143, no
    // symbol for a COMDAT section), and Rust's compiler-builtins covers what
    // the core needs there (__divti3, SPIKE.md).
    lib.bundle_compiler_rt = target.result.abi != .msvc;
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

    // W4: src/ninep/wire.zig is hyper9's dotl/wire.zig, vendored (see its
    // header). This fails when the submodule's copy has moved on.
    const check_wire = b.addSystemCommand(&.{ "sh", "-c", "tail -n +6 src/ninep/wire.zig | cmp -s - ../third_party/hyper9/src/dotl/wire.zig || { echo 'src/ninep/wire.zig differs from hyper9 src/dotl/wire.zig: re-vendor it' >&2; exit 1; }" });
    check_wire.setCwd(b.path("."));
    b.step("check-wire", "Check the vendored wire.zig matches the hyper9 submodule").dependOn(&check_wire.step);

    const tests = b.addTest(.{ .root_module = core });
    const test_step = b.step("test", "Run the core's unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // W4: uitree-headless's own tests (argument parsing).
    const headless_tests = b.addTest(.{ .root_module = headless.root_module });
    test_step.dependOn(&b.addRunArtifact(headless_tests).step);
}
