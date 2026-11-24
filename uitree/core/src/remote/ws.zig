//! uitree-remote's `-W`: an HTTP listener that serves the browser renderer
//! (page.html) at `/` and carries the renderer tree's 9P over a WebSocket
//! at `/9p`. Each WebSocket becomes a UitConn (uitcore.h) that the owner
//! thread hands to uit_render_serve_conn: binary messages are 9P bytes.
//!
//! Enough of RFC 6455 for a browser on the same machine or LAN: no
//! extensions, no TLS. Text messages count as bytes too; pings are
//! answered; close ends the stream.

const std = @import("std");
const core = @import("uitcore");

const abi = core.abi;
const c = std.c;

pub const page = @embedFile("page.html");

/// Connections accepted, waiting for the owner thread.
pub const Inbox = struct {
    io: std.Io,
    mu: std.Io.Mutex = .init,
    list: std.ArrayList(abi.UitConn) = .empty,
    wake: *const fn (?*anyopaque) callconv(.c) void,
    wake_ctx: ?*anyopaque,

    fn put(b: *Inbox, k: abi.UitConn) void {
        b.mu.lockUncancelable(b.io);
        b.list.append(std.heap.c_allocator, k) catch {};
        b.mu.unlock(b.io);
        b.wake(b.wake_ctx);
    }

    /// Owner thread: the connections to serve.
    pub fn take(b: *Inbox, out: *std.ArrayList(abi.UitConn)) void {
        b.mu.lockUncancelable(b.io);
        defer b.mu.unlock(b.io);
        out.appendSlice(std.heap.c_allocator, b.list.items) catch {};
        b.list.clearRetainingCapacity();
    }
};

/// Listens on `tcp!HOST!PORT` (HOST may be `*`) and accepts on a thread.
/// Returns the port.
pub fn listen(addr: []const u8, inbox: *Inbox) !u16 {
    var it = std.mem.splitScalar(u8, addr, '!');
    const proto = it.next() orelse return error.BadAddress;
    if (!std.mem.eql(u8, proto, "tcp")) return error.BadAddress;
    const host = it.next() orelse return error.BadAddress;
    const port = std.fmt.parseInt(u16, it.next() orelse return error.BadAddress, 10) catch return error.BadAddress;
    var ip: u32 = 0x7f000001;
    if (std.mem.eql(u8, host, "*")) ip = 0 else if (!std.mem.eql(u8, host, "localhost")) {
        var parts = std.mem.splitScalar(u8, host, '.');
        ip = 0;
        for (0..4) |_| ip = (ip << 8) | (std.fmt.parseInt(u8, parts.next() orelse return error.BadAddress, 10) catch return error.BadAddress);
    }
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
    var sa: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, ip) };
    if (c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) != 0) return error.BindFailed;
    if (c.listen(fd, 16) != 0) return error.ListenFailed;
    var len: c.socklen_t = @sizeOf(c.sockaddr.in);
    _ = c.getsockname(fd, @ptrCast(&sa), &len);
    const t = try std.Thread.spawn(.{}, acceptLoop, .{ fd, inbox });
    t.detach();
    return std.mem.bigToNative(u16, sa.port);
}

fn acceptLoop(fd: c_int, inbox: *Inbox) void {
    while (true) {
        const k = c.accept(fd, null, null);
        if (k < 0) continue;
        const t = std.Thread.spawn(.{}, handshake, .{ k, inbox }) catch {
            _ = c.close(k);
            continue;
        };
        t.detach();
    }
}

fn writeAll(fd: c_int, b: []const u8) bool {
    var off: usize = 0;
    while (off < b.len) {
        const n = c.write(fd, b.ptr + off, b.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn readFull(fd: c_int, b: []u8) bool {
    var off: usize = 0;
    while (off < b.len) {
        const n = c.read(fd, b.ptr + off, b.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn header(req: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, req, "\r\n");
    _ = it.next();
    while (it.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[0..colon], " "), name)) return std.mem.trim(u8, l[colon + 1 ..], " ");
    }
    return null;
}

/// One HTTP request: the page, or the WebSocket upgrade.
fn handshake(fd: c_int, inbox: *Inbox) void {
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    const end = while (n < buf.len) {
        const r = c.read(fd, buf[n..].ptr, buf.len - n);
        if (r <= 0) {
            _ = c.close(fd);
            return;
        }
        n += @intCast(r);
        if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n")) |e| break e;
    } else {
        _ = c.close(fd);
        return;
    };
    const req = buf[0..end];
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse req.len;
    var words = std.mem.tokenizeScalar(u8, req[0..line_end], ' ');
    _ = words.next();
    const path = words.next() orelse "/";
    if (std.mem.startsWith(u8, path, "/9p")) {
        const key = header(req, "Sec-WebSocket-Key") orelse {
            _ = writeAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
            _ = c.close(fd);
            return;
        };
        var h = std.crypto.hash.Sha1.init(.{});
        h.update(key);
        h.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [20]u8 = undefined;
        h.final(&digest);
        var acc: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&acc, &digest);
        var resp: [256]u8 = undefined;
        const r = std.fmt.bufPrint(&resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{acc}) catch unreachable;
        if (!writeAll(fd, r)) {
            _ = c.close(fd);
            return;
        }
        const ws = std.heap.c_allocator.create(Ws) catch {
            _ = c.close(fd);
            return;
        };
        ws.* = .{ .fd = fd, .io = inbox.io };
        inbox.put(.{ .read = Ws.read, .write = Ws.write, .hangup = Ws.hangup, .release = Ws.release, .ctx = ws });
        return;
    }
    var hb: [256]u8 = undefined;
    const hd = std.fmt.bufPrint(&hb, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{page.len}) catch unreachable;
    if (writeAll(fd, hd)) _ = writeAll(fd, page);
    _ = c.close(fd);
}

/// A WebSocket as a UitConn.
const Ws = struct {
    fd: c_int,
    io: std.Io,
    wmu: std.Io.Mutex = .init,
    /// The current message's bytes not yet read.
    left: u64 = 0,
    mask: [4]u8 = .{ 0, 0, 0, 0 },
    masked: bool = false,
    pos: u64 = 0,
    closed: bool = false,

    fn of(ctx: ?*anyopaque) *Ws {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn read(ctx: ?*anyopaque, buf: [*]u8, n: usize) callconv(.c) isize {
        const w = of(ctx);
        while (w.left == 0) {
            if (w.closed) return 0;
            var h: [2]u8 = undefined;
            if (!readFull(w.fd, &h)) return 0;
            const op = h[0] & 0x0f;
            w.masked = h[1] & 0x80 != 0;
            var len: u64 = h[1] & 0x7f;
            if (len == 126) {
                var e: [2]u8 = undefined;
                if (!readFull(w.fd, &e)) return 0;
                len = std.mem.readInt(u16, &e, .big);
            } else if (len == 127) {
                var e: [8]u8 = undefined;
                if (!readFull(w.fd, &e)) return 0;
                len = std.mem.readInt(u64, &e, .big);
            }
            if (w.masked and !readFull(w.fd, &w.mask)) return 0;
            w.pos = 0;
            switch (op) {
                0x0, 0x1, 0x2 => w.left = len,
                0x8 => {
                    w.closed = true;
                    return 0;
                },
                0x9, 0xa => {
                    // A control frame: at most 125 bytes. Pings get a pong.
                    var body: [125]u8 = undefined;
                    const b = body[0..@min(len, 125)];
                    if (!readFull(w.fd, b)) return 0;
                    if (w.masked) for (b, 0..) |*x, i| {
                        x.* ^= w.mask[i % 4];
                    };
                    if (op == 0x9) w.frame(0x8a, b);
                },
                else => return -1,
            }
        }
        const want: usize = @intCast(@min(@as(u64, n), w.left));
        const got = c.read(w.fd, buf, want);
        if (got <= 0) return 0;
        const g: usize = @intCast(got);
        if (w.masked) for (buf[0..g], 0..) |*x, i| {
            x.* ^= w.mask[@intCast((w.pos + i) % 4)];
        };
        w.pos += g;
        w.left -= g;
        return @intCast(g);
    }

    fn frame(w: *Ws, first: u8, b: []const u8) void {
        w.wmu.lockUncancelable(w.io);
        defer w.wmu.unlock(w.io);
        var h: [10]u8 = undefined;
        h[0] = first;
        var hl: usize = 2;
        if (b.len < 126) {
            h[1] = @intCast(b.len);
        } else if (b.len <= 0xffff) {
            h[1] = 126;
            std.mem.writeInt(u16, h[2..4], @intCast(b.len), .big);
            hl = 4;
        } else {
            h[1] = 127;
            std.mem.writeInt(u64, h[2..10], b.len, .big);
            hl = 10;
        }
        if (writeAll(w.fd, h[0..hl])) _ = writeAll(w.fd, b);
    }

    fn write(ctx: ?*anyopaque, buf: [*]const u8, n: usize) callconv(.c) c_int {
        const w = of(ctx);
        w.frame(0x82, buf[0..n]);
        return 0;
    }

    fn hangup(ctx: ?*anyopaque) callconv(.c) void {
        _ = c.shutdown(of(ctx).fd, 2);
    }

    fn release(ctx: ?*anyopaque) callconv(.c) void {
        const w = of(ctx);
        _ = c.close(w.fd);
        std.heap.c_allocator.destroy(w);
    }
};
