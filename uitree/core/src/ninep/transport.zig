//! Transports for the 9P server: a connected fd (`uit_serve_fd`, a pipe
//! from a parent), a unix socket (`unix!PATH`, and the private socket h9
//! dials), TCP (`tcp!HOST!PORT`, for `-a`), and a connection the renderer
//! or the platform carries itself (`uit_serve_conn`'s UitConn: the
//! browser's).
//!
//! Sockets and fds are POSIX only for now. On Windows and in the browser
//! every socket constructor returns `error.Unsupported`; a winsock TCP
//! transport is the open item (the spike's SPIKE.md § Windows).

const std = @import("std");
const builtin = @import("builtin");

const c = std.c;
const web = @import("../web.zig");
/// Sockets and fds. Not on Windows (yet) and not in the browser (wasi),
/// where every connection is a UitConn.
const posix = builtin.os.tag != .windows and builtin.os.tag != .wasi;

/// uitcore.h's UitConn: a byte stream someone else carries.
pub const UitConn = extern struct {
    read: ?*const fn (ctx: ?*anyopaque, buf: [*]u8, n: usize) callconv(.c) isize = null,
    write: ?*const fn (ctx: ?*anyopaque, buf: [*]const u8, n: usize) callconv(.c) c_int = null,
    hangup: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,
    release: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,
    ctx: ?*anyopaque = null,
};

/// A UitConn being served: the callbacks, copied, and whether it has
/// been hung up (UitConn.hangup is called at most once).
pub const Ext = struct {
    gpa: std.mem.Allocator,
    cb: UitConn,
    hung: std.atomic.Value(bool) = .init(false),

    fn callRead(e: *Ext, buf: []u8) isize {
        return e.cb.read.?(e.cb.ctx, buf.ptr, buf.len);
    }

    fn read(e: *Ext, buf: []u8) !usize {
        // In the browser a read may be a Suspending import: park around it.
        const n = if (web.enabled) web.blocking(callRead, .{ e, buf }) else e.callRead(buf);
        if (n < 0) return error.ReadFailed;
        return @min(@as(usize, @intCast(n)), buf.len);
    }

    fn hangup(e: *Ext) void {
        if (e.hung.swap(true, .acq_rel)) return;
        if (e.cb.hangup) |f| f(e.cb.ctx);
    }

    fn release(e: *Ext) void {
        if (e.cb.release) |f| f(e.cb.ctx);
        e.gpa.destroy(e);
    }
};

/// One connected byte stream: an fd, or a UitConn (`ext`).
pub const Conn = struct {
    fd: c_int = -1,
    ext: ?*Ext = null,

    pub fn read(k: Conn, buf: []u8) !usize {
        if (k.ext) |e| return e.read(buf);
        if (!posix) return error.Unsupported;
        while (true) {
            const n = c.read(k.fd, buf.ptr, buf.len);
            if (n >= 0) return @intCast(n);
            if (std.posix.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
    }

    pub fn writeAll(k: Conn, b: []const u8) !void {
        if (k.ext) |e| {
            if (e.cb.write.?(e.cb.ctx, b.ptr, b.len) < 0) return error.WriteFailed;
            return;
        }
        if (!posix) return error.Unsupported;
        var off: usize = 0;
        while (off < b.len) {
            const n = c.write(k.fd, b.ptr + off, b.len - off);
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    /// Ends both directions so a blocked reader sees end of file, without
    /// freeing the fd (the reader still closes it).
    pub fn shutdown(k: Conn) void {
        if (k.ext) |e| return e.hangup();
        if (!posix) return;
        _ = c.shutdown(k.fd, 2);
    }

    pub fn close(k: Conn) void {
        if (k.ext) |e| return e.release();
        if (!posix) return;
        _ = c.close(k.fd);
    }
};

/// Takes a UitConn: copies it, and owns it from here (release is called
/// even when this fails). error.Invalid without read or write.
pub fn fromUitConn(gpa: std.mem.Allocator, cb: UitConn) !Conn {
    if (cb.read == null or cb.write == null) {
        if (cb.release) |f| f(cb.ctx);
        return error.Invalid;
    }
    const e = gpa.create(Ext) catch |err| {
        if (cb.release) |f| f(cb.ctx);
        return err;
    };
    e.* = .{ .gpa = gpa, .cb = cb };
    return .{ .ext = e };
}

pub fn fromFd(fd: c_int) Conn {
    return .{ .fd = fd };
}

/// A listening socket, served until `stop`.
pub const Listener = struct {
    gpa: std.mem.Allocator,
    fd: c_int,
    /// What a client dials: `unix!PATH` or `tcp!HOST!PORT`.
    dial: []u8,
    /// The socket's path for a unix listener (unlinked at stop).
    path: ?[:0]u8 = null,
    /// A private directory made for the socket (removed at stop).
    dir: ?[:0]u8 = null,
    port: u16 = 0,
    thread: ?web.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),

    /// Accepts on a thread of its own, handing each connection to
    /// `on_conn(ctx, conn)`, which owns it.
    pub fn start(l: *Listener, ctx: *anyopaque, on_conn: *const fn (*anyopaque, Conn) void) !void {
        if (!posix) return error.Unsupported;
        l.thread = try web.Thread.spawn(.{}, acceptLoop, .{ l, ctx, on_conn });
    }

    fn acceptLoop(l: *Listener, ctx: *anyopaque, on_conn: *const fn (*anyopaque, Conn) void) void {
        if (!posix) return;
        while (!l.stopping.load(.acquire)) {
            const fd = c.accept(l.fd, null, null);
            if (fd < 0) {
                if (l.stopping.load(.acquire)) return;
                const e = std.posix.errno(fd);
                if (e == .INTR or e == .AGAIN or e == .CONNABORTED) continue;
                return;
            }
            if (l.stopping.load(.acquire)) {
                _ = c.close(fd);
                return;
            }
            on_conn(ctx, .{ .fd = fd });
        }
    }

    pub fn stop(l: *Listener) void {
        if (!posix) return;
        l.stopping.store(true, .release);
        // Wakes the accept: shutdown on a listening socket makes accept
        // fail on Linux; elsewhere, connect to ourselves.
        _ = c.shutdown(l.fd, 2);
        if (l.thread) |th| {
            if (builtin.os.tag != .linux) l.poke();
            th.join();
        }
        _ = c.close(l.fd);
        if (l.path) |p| {
            _ = c.unlink(p);
            l.gpa.free(p);
        }
        if (l.dir) |d| {
            _ = c.rmdir(d);
            l.gpa.free(d);
        }
        l.gpa.free(l.dial);
        l.gpa.destroy(l);
    }

    fn poke(l: *Listener) void {
        if (!posix) return;
        if (l.path) |p| {
            const w = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
            if (w < 0) return;
            defer _ = c.close(w);
            var addr = unixAddr(p) catch return;
            _ = c.connect(w, @ptrCast(&addr), @sizeOf(c.sockaddr.un));
        } else {
            const w = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
            if (w < 0) return;
            defer _ = c.close(w);
            var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, l.port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
            _ = c.connect(w, @ptrCast(&addr), @sizeOf(c.sockaddr.in));
        }
    }
};

fn unixAddr(path: []const u8) !c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// Listens on the unix socket at `path`.
pub fn listenUnix(gpa: std.mem.Allocator, path: []const u8) !*Listener {
    if (!posix) return error.Unsupported;
    const p = try gpa.dupeZ(u8, path);
    errdefer gpa.free(p);
    var addr = try unixAddr(p);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return error.BindFailed;
    if (c.listen(fd, 16) != 0) return error.ListenFailed;
    const l = try gpa.create(Listener);
    l.* = .{ .gpa = gpa, .fd = fd, .dial = try std.fmt.allocPrint(gpa, "unix!{s}", .{p}), .path = p };
    return l;
}

/// Listens on a unix socket `ui` in a new private directory under $TMPDIR
/// (or /tmp), mode 0700, so only this user can dial it. This is what h9
/// mounts.
pub fn listenPrivate(gpa: std.mem.Allocator, io: std.Io) !*Listener {
    if (!posix) return error.Unsupported;
    const tmp = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    var n: u32 = 0;
    const dir = while (true) : (n += 1) {
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const d = try std.fmt.allocPrintSentinel(gpa, "{s}/uitree-{x}", .{ std.mem.trimEnd(u8, tmp, "/"), &rnd }, 0);
        if (c.mkdir(d, 0o700) == 0) break d;
        gpa.free(d);
        if (n > 8) return error.MkdirFailed;
    };
    errdefer {
        _ = c.rmdir(dir);
        gpa.free(dir);
    }
    const path = try std.fmt.allocPrint(gpa, "{s}/ui", .{dir});
    defer gpa.free(path);
    const l = try listenUnix(gpa, path);
    l.dir = dir;
    return l;
}

/// Listens on TCP. `addr` is `tcp!HOST!PORT`, `HOST:PORT` or `:PORT`;
/// HOST is a dotted IPv4 address (default 127.0.0.1) or `*` for every
/// interface. Port 0 picks one; `dial` says which.
pub fn listenTcp(gpa: std.mem.Allocator, addr: []const u8) !*Listener {
    if (!posix) return error.Unsupported;
    const hp = try parseTcp(addr);
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
    var sa: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, hp.port), .addr = std.mem.nativeToBig(u32, hp.host) };
    if (c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) != 0) return error.BindFailed;
    if (c.listen(fd, 16) != 0) return error.ListenFailed;
    var len: c.socklen_t = @sizeOf(c.sockaddr.in);
    _ = c.getsockname(fd, @ptrCast(&sa), &len);
    const port = std.mem.bigToNative(u16, sa.port);
    const h = hp.host;
    const l = try gpa.create(Listener);
    l.* = .{
        .gpa = gpa,
        .fd = fd,
        .port = port,
        .dial = try std.fmt.allocPrint(gpa, "tcp!{d}.{d}.{d}.{d}!{d}", .{ h >> 24, (h >> 16) & 255, (h >> 8) & 255, h & 255, port }),
    };
    return l;
}

const HostPort = struct { host: u32, port: u16 };

pub fn parseTcp(addr_in: []const u8) !HostPort {
    var addr = addr_in;
    var host_s: []const u8 = "";
    var port_s: []const u8 = "";
    if (std.mem.startsWith(u8, addr, "tcp!")) {
        addr = addr[4..];
        const bang = std.mem.lastIndexOfScalar(u8, addr, '!') orelse return error.BadAddress;
        host_s = addr[0..bang];
        port_s = addr[bang + 1 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.BadAddress;
        host_s = addr[0..colon];
        port_s = addr[colon + 1 ..];
    }
    const port = std.fmt.parseInt(u16, port_s, 10) catch return error.BadAddress;
    if (host_s.len == 0 or std.mem.eql(u8, host_s, "localhost")) return .{ .host = 0x7f000001, .port = port };
    if (std.mem.eql(u8, host_s, "*")) return .{ .host = 0, .port = port };
    var it = std.mem.splitScalar(u8, host_s, '.');
    var h: u32 = 0;
    var parts: usize = 0;
    while (it.next()) |p| : (parts += 1) {
        if (parts == 4) return error.BadAddress;
        h = (h << 8) | (std.fmt.parseInt(u8, p, 10) catch return error.BadAddress);
    }
    if (parts != 4) return error.BadAddress;
    return .{ .host = h, .port = port };
}

/// Listens on `addr`: `unix!PATH`, a path starting with `/` or `./`, or a
/// TCP address (`parseTcp`).
pub fn listen(gpa: std.mem.Allocator, addr: []const u8) !*Listener {
    if (std.mem.startsWith(u8, addr, "unix!")) return listenUnix(gpa, addr[5..]);
    if (std.mem.startsWith(u8, addr, "/") or std.mem.startsWith(u8, addr, "./")) return listenUnix(gpa, addr);
    return listenTcp(gpa, addr);
}

/// Dials a listener's `dial` string (tests, and `uitree-headless -c`).
pub fn dial(d: []const u8) !Conn {
    if (!posix) return error.Unsupported;
    if (std.mem.startsWith(u8, d, "unix!")) {
        var buf: [256]u8 = undefined;
        if (d.len - 5 >= buf.len) return error.NameTooLong;
        var addr = try unixAddr(d[5..]);
        _ = &buf;
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) {
            _ = c.close(fd);
            return error.ConnectFailed;
        }
        return .{ .fd = fd };
    }
    const hp = try parseTcp(d);
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var sa: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, hp.port), .addr = std.mem.nativeToBig(u32, if (hp.host == 0) 0x7f000001 else hp.host) };
    if (c.connect(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) != 0) {
        _ = c.close(fd);
        return error.ConnectFailed;
    }
    return .{ .fd = fd };
}

/// A connected pair (tests).
pub fn pair() ![2]Conn {
    if (!posix) return error.Unsupported;
    var fds: [2]c_int = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketFailed;
    return .{ .{ .fd = fds[0] }, .{ .fd = fds[1] } };
}

test "parseTcp" {
    const t = std.testing;
    try t.expectEqual(HostPort{ .host = 0x7f000001, .port = 564 }, try parseTcp("tcp!127.0.0.1!564"));
    try t.expectEqual(HostPort{ .host = 0x7f000001, .port = 9 }, try parseTcp(":9"));
    try t.expectEqual(HostPort{ .host = 0, .port = 9 }, try parseTcp("*:9"));
    try t.expectEqual(HostPort{ .host = 0x0a000001, .port = 80 }, try parseTcp("10.0.0.1:80"));
    try t.expectError(error.BadAddress, parseTcp("nope"));
    try t.expectError(error.BadAddress, parseTcp("1.2.3:4"));
}
