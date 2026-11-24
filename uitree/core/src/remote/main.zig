//! uitree-remote: a host with no renderer of its own (protocols/render.md).
//! It runs the app in h9, serves `$ui` to it as usual, and serves the
//! renderer tree to any renderer that dials ADDR.
//!
//!     uitree-remote -R ADDR [-a ADDR] [-r ROOT] [CMD [ARG...]]
//!
//! `-a ADDR` also serves `$ui` on ADDR, for an app on the host that dials
//! it (`$UI_DIAL`) instead of one in h9. It is a host over uitcore.h and
//! nothing else: the core encodes inside uit_pump, so all this does is
//! pump when woken.

const std = @import("std");
const core = @import("uitcore");
const uit = @import("uit.zig");

const abi = core.abi;
const UitStr = abi.UitStr;

const usage = "usage: uitree-remote -R ADDR [-a ADDR] [-r ROOT] [CMD [ARG...]]\n";

const Waker = struct {
    io: std.Io,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    woken: bool = true,

    fn wake(ctx: ?*anyopaque) callconv(.c) void {
        const w: *Waker = @ptrCast(@alignCast(ctx.?));
        w.mu.lockUncancelable(w.io);
        w.woken = true;
        w.cond.broadcast(w.io);
        w.mu.unlock(w.io);
    }

    fn wait(w: *Waker) void {
        w.mu.lockUncancelable(w.io);
        while (!w.woken) w.cond.waitUncancelable(w.io, &w.mu);
        w.woken = false;
        w.mu.unlock(w.io);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var raddr: ?[]const u8 = null;
    var aaddr: ?[]const u8 = null;
    var root: []const u8 = "";
    if (init.environ_map.get("H9ROOT")) |v| root = v;
    var i: usize = 1;
    while (i + 1 < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 2) {
        if (std.mem.eql(u8, args[i], "-R")) raddr = args[i + 1] else if (std.mem.eql(u8, args[i], "-a")) aaddr = args[i + 1] else if (std.mem.eql(u8, args[i], "-r")) root = args[i + 1] else {
            std.debug.print(usage, .{});
            std.process.exit(2);
        }
    }
    const argv = args[i..];
    if (raddr == null or (argv.len == 0 and aaddr == null)) {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var waker: Waker = .{ .io = threaded.io() };

    const cfg: abi.UitConfig = .{
        .abi_version = abi.abi_version,
        .types = .{},
        .style_words = .{},
        .theme_tokens = .{},
        .system_dark = 0,
        .wake = Waker.wake,
        .wake_ctx = &waker,
    };
    var cp: ?*abi.Core = null;
    if (uit.uit_create(&cfg, &cp) != abi.UIT_OK) return error.Create;
    const c = cp.?;
    _ = uit.uit_themes(c, UitStr.of(core.types.embedded.themes));

    var dial: UitStr = .{};
    if (uit.uit_render_listen(c, UitStr.of(raddr.?), 0, &dial) != abi.UIT_OK) {
        std.debug.print("uitree-remote: listen {s}: {s}\n", .{ raddr.?, uit.uit_last_error(c).slice() });
        return error.Listen;
    }
    std.debug.print("uitree-remote: renderers dial {s}\n", .{dial.slice()});

    if (aaddr) |aa| {
        var adial: UitStr = .{};
        if (uit.uit_listen(c, UitStr.of(aa), &adial) != abi.UIT_OK) {
            std.debug.print("uitree-remote: listen {s}: {s}\n", .{ aa, uit.uit_last_error(c).slice() });
            return error.Listen;
        }
        std.debug.print("uitree-remote: apps dial {s}\n", .{adial.slice()});
    }

    if (argv.len > 0) {
        const uargv = try init.arena.allocator().alloc(UitStr, argv.len);
        for (argv, uargv) |x, *y| y.* = UitStr.of(x);
        const margs: abi.UitMachineArgs = .{
            .prog = uargv[0],
            .argv = uargv.ptr,
            .argc = uargv.len,
            .root = UitStr.of(root),
            .cwd = .{},
            .dirs = null,
            .n_dirs = 0,
            .env = null,
            .n_env = 0,
            .h9_flags = null,
            .n_h9_flags = 0,
            .out_fd = -1,
            .err_fd = -1,
        };
        if (uit.uit_run_machine(c, &margs) != abi.UIT_OK) {
            std.debug.print("uitree-remote: {s}\n", .{uit.uit_last_error(c).slice()});
            return error.Machine;
        }
    }

    // The owner thread: pump when woken, until the app exits.
    var status: []const u8 = "";
    while (true) {
        waker.wait();
        var ch: abi.UitChanges = .{};
        _ = uit.uit_pump(c, &ch);
        if (ch.exited == 1) {
            status = try gpa.dupe(u8, ch.exit_status.slice());
            break;
        }
    }
    // Let renderers read the last batch and the end of file.
    threaded.io().sleep(.fromMilliseconds(200), .awake) catch {};
    if (status.len > 0) std.debug.print("uitree-remote: {s}\n", .{status});
    std.process.exit(if (status.len == 0) 0 else 1);
}
