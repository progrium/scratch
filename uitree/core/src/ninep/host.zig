//! Host: everything that serves one core's `$ui`: the 9P server, the
//! `Mux` that mounts `debug/` (or anything else a host adds) beside the
//! tree, and the listeners. `abi.zig` keeps one per core; `uitree-headless`
//! mounts its `/debug` on it.

const std = @import("std");
const fsmod = @import("fs.zig");
const server = @import("server.zig");
const transport = @import("transport.zig");
const muxmod = @import("mux.zig");

const Allocator = std.mem.Allocator;

pub const max_mounts = 4;

pub const Host = struct {
    gpa: Allocator,
    io: std.Io,
    mux: muxmod.Mux,
    mount_buf: [max_mounts]muxmod.Mount = undefined,
    srv: server.Server,
    /// The private socket h9 dials, made on first use.
    private: ?*transport.Listener = null,
    listeners: std.ArrayList(*transport.Listener) = .empty,
    mu: std.Io.Mutex = .init,

    pub fn create(gpa: Allocator, io: std.Io, tree: fsmod.Fs) !*Host {
        const h = try gpa.create(Host);
        h.* = .{ .gpa = gpa, .io = io, .mux = .{ .inner = tree, .mounts = &.{} }, .srv = undefined };
        h.srv = .init(gpa, io, h.mux.fs());
        h.srv.on_error = .{ .ctx = h, .func = loud };
        return h;
    }

    /// Where loud error lines go; null for nowhere. Default stderr.
    pub var loud_fd: ?c_int = 2;

    /// core.md § Errors: `uitree: write PATH: phrase: detail` on standard
    /// error, for writes to the tree (not to a mounted `debug/`).
    fn loud(ctx: *anyopaque, verb: []const u8, path: []const u8, text: []const u8) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const fd = loud_fd orelse return;
        if (h.mux.mounted(path)) return;
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "uitree: {s} {s}: {s}\n", .{ verb, path, text }) catch return;
        transport.fromFd(fd).writeAll(line) catch {};
    }

    /// Mounts `fs` at `$ui/NAME`. Call before serving.
    pub fn mount(h: *Host, name: []const u8, fs: fsmod.Fs) !void {
        const n = h.mux.mounts.len;
        if (n == max_mounts) return error.TooManyMounts;
        h.mount_buf[n] = .{ .name = name, .fs = fs };
        h.mux.mounts = h.mount_buf[0 .. n + 1];
    }

    fn onConn(ctx: *anyopaque, c: transport.Conn) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.srv.serve(c) catch {};
    }

    /// Serves a connected fd.
    pub fn serveFd(h: *Host, fd: c_int) !void {
        try h.srv.serve(transport.fromFd(fd));
    }

    /// The private unix socket's path, listening on first call.
    pub fn privatePath(h: *Host) ![]const u8 {
        h.mu.lockUncancelable(h.io);
        defer h.mu.unlock(h.io);
        if (h.private == null) {
            const l = try transport.listenPrivate(h.gpa, h.io);
            errdefer l.stop();
            try l.start(h, onConn);
            h.private = l;
        }
        return h.private.?.path.?;
    }

    /// The private socket's dial string (`unix!PATH`).
    pub fn privateDial(h: *Host) ![]const u8 {
        _ = try h.privatePath();
        return h.private.?.dial;
    }

    /// Listens on `addr` (transport.listen); returns the dial string.
    pub fn listen(h: *Host, addr: []const u8) ![]const u8 {
        const l = try transport.listen(h.gpa, addr);
        errdefer l.stop();
        h.mu.lockUncancelable(h.io);
        defer h.mu.unlock(h.io);
        try h.listeners.append(h.gpa, l);
        try l.start(h, onConn);
        return l.dial;
    }

    /// Connections being served.
    pub fn live(h: *Host) u32 {
        return h.srv.live.load(.acquire);
    }

    /// Stops listening and hangs up every connection, waiting for them.
    /// The tree's streams must already be ended (uit_shutdown does).
    pub fn shutdown(h: *Host) void {
        h.mu.lockUncancelable(h.io);
        if (h.private) |l| l.stop();
        h.private = null;
        for (h.listeners.items) |l| l.stop();
        h.listeners.clearRetainingCapacity();
        h.mu.unlock(h.io);
        h.srv.shutdown();
    }

    pub fn destroy(h: *Host) void {
        h.shutdown();
        h.srv.deinit();
        h.listeners.deinit(h.gpa);
        h.gpa.destroy(h);
    }
};

test "a host serves its tree and mounts over a private socket and tcp" {
    const t = std.testing;
    const MemFs = @import("memfs.zig").MemFs;
    const Client = @import("client.zig").Client;
    var th: std.Io.Threaded = .init(t.allocator, .{});
    defer th.deinit();
    var tree: MemFs = .init(t.allocator, th.io());
    defer tree.deinit();
    try tree.put("version", "uitree 1.0\n");
    var dbg: MemFs = .init(t.allocator, th.io());
    defer dbg.deinit();
    try dbg.put("inject", "");
    const h = try Host.create(t.allocator, th.io(), tree.fs());
    defer h.destroy();
    try h.mount("debug", dbg.fs());
    for ([_][]const u8{ try h.privateDial(), try h.listen("tcp!127.0.0.1!0") }) |d| {
        var cl = try Client.init(t.allocator, try transport.dial(d));
        defer cl.deinit();
        try cl.version();
        const root = try cl.attach();
        const v = try cl.get(t.allocator, root, "version");
        defer t.allocator.free(v);
        try t.expectEqualStrings("uitree 1.0\n", v);
        const f = try cl.walk(root, "debug/inject");
        try cl.clunk(f);
    }
}
