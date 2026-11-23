//! The app's machine in the browser: h9's own browser host in a Worker,
//! which the page starts and stops for the core (web.zig's `platform`).
//! The same Runner shape as root.zig's native one: start, hangup, join,
//! and an exit through `on_exit`. Its `$ui` connections are served as
//! UitConns whose callbacks are the page's `conn_*` imports.

const std = @import("std");
const abi = @import("../abi.zig");
const web = @import("../web.zig");
const transport = @import("../ninep/transport.zig");

const gpa = std.heap.c_allocator;
const p = web.platform;

pub const OnExit = *const fn (ctx: *anyopaque, status: []const u8) void;
/// Takes a connection (it owns it from here).
pub const OnConn = *const fn (ctx: *anyopaque, conn: transport.Conn) void;

pub const Runner = struct {
    id: i32,
    ctx: *anyopaque,
    on_exit: OnExit,
    on_conn: OnConn,
    acceptor: web.Thread = undefined,
    waiter: web.Thread = undefined,
    hung_up: std.atomic.Value(bool) = .init(false),
    status: [256]u8 = undefined,

    pub fn start(args: *const abi.UitMachineArgs, ctx: *anyopaque, on_exit: OnExit, on_conn: OnConn) !*Runner {
        const id = p.machine_start(args);
        if (id <= 0) return error.MachineFailed;
        const r = try gpa.create(Runner);
        r.* = .{ .id = id, .ctx = ctx, .on_exit = on_exit, .on_conn = on_conn };
        r.acceptor = web.Thread.spawn(.{}, accept, .{r}) catch |e| {
            p.machine_hangup(id);
            gpa.destroy(r);
            return e;
        };
        r.waiter = web.Thread.spawn(.{}, wait, .{r}) catch |e| {
            // The accept loop ends once the machine is gone.
            p.machine_hangup(id);
            r.acceptor.join();
            gpa.destroy(r);
            return e;
        };
        return r;
    }

    fn accept(r: *Runner) void {
        while (true) {
            const conn = web.blocking(p.machine_accept, .{r.id});
            if (conn <= 0) return;
            const k = transport.fromUitConn(gpa, .{
                .read = connRead,
                .write = connWrite,
                .hangup = connHangup,
                .release = connRelease,
                .ctx = @ptrFromInt(@as(usize, @intCast(conn))),
            }) catch continue;
            r.on_conn(r.ctx, k);
        }
    }

    fn wait(r: *Runner) void {
        const n = web.blocking(p.machine_wait, .{ r.id, &r.status, r.status.len });
        r.on_exit(r.ctx, r.status[0..@intCast(std.math.clamp(n, 0, r.status.len))]);
    }

    /// Any thread: the page stops the machine.
    pub fn hangup(r: *Runner) void {
        if (r.hung_up.swap(true, .acq_rel)) return;
        p.machine_hangup(r.id);
    }

    pub fn join(r: *Runner) void {
        r.waiter.join();
        r.acceptor.join();
        gpa.destroy(r);
    }
};

fn connId(ctx: ?*anyopaque) i32 {
    return @intCast(@intFromPtr(ctx));
}

fn connRead(ctx: ?*anyopaque, buf: [*]u8, n: usize) callconv(.c) isize {
    // transport.Ext.read parks around this call.
    return p.conn_read(connId(ctx), buf, n);
}

fn connWrite(ctx: ?*anyopaque, buf: [*]const u8, n: usize) callconv(.c) c_int {
    return if (p.conn_write(connId(ctx), buf, n) < 0) -1 else 0;
}

fn connHangup(ctx: ?*anyopaque) callconv(.c) void {
    p.conn_hangup(connId(ctx));
}

fn connRelease(ctx: ?*anyopaque) callconv(.c) void {
    p.conn_release(connId(ctx));
}
