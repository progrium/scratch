//! A minimal synchronous 9P2000 client: enough for the server's tests and
//! for `uitree-headless` to talk to its own server. One request at a time
//! unless `send`/`recv` are used directly.

const std = @import("std");
const wire = @import("wire.zig");
const Dir = @import("dir.zig").Dir;
const transport = @import("transport.zig");

const p9 = wire.p9;
const Allocator = std.mem.Allocator;

pub const Client = struct {
    gpa: Allocator,
    t: transport.Conn,
    msize: u32 = 64 << 10,
    buf: []u8,
    next_tag: u16 = 1,
    next_fid: u32 = 1,
    /// The last Rerror's text.
    err: [256]u8 = undefined,
    err_len: usize = 0,

    pub fn init(gpa: Allocator, t: transport.Conn) !Client {
        return .{ .gpa = gpa, .t = t, .buf = try gpa.alloc(u8, 256 << 10) };
    }

    pub fn deinit(c: *Client) void {
        c.gpa.free(c.buf);
        c.t.close();
    }

    pub fn errText(c: *const Client) []const u8 {
        return c.err[0..c.err_len];
    }

    pub fn send(c: *Client, tag: u16, msg: anytype) !void {
        var out: [70 << 10]u8 = undefined;
        try c.t.writeAll(try wire.encode(&out, tag, msg, null));
    }

    /// Reads one reply frame into `buf`.
    pub fn recv(c: *Client) !wire.Frame(p9.R) {
        var have: usize = 0;
        while (have < 4) {
            const n = try c.t.read(c.buf[have..4]);
            if (n == 0) return error.EndOfStream;
            have += n;
        }
        const size = std.mem.readInt(u32, c.buf[0..4], .little);
        if (size > c.buf.len or size < 7) return error.Malformed;
        while (have < size) {
            const n = try c.t.read(c.buf[have..size]);
            if (n == 0) return error.EndOfStream;
            have += n;
        }
        return wire.decode(p9.R, c.buf[0..size], @intCast(c.buf.len), false);
    }

    fn rpc(c: *Client, msg: anytype) !p9.R {
        const tag = c.next_tag;
        c.next_tag +%= 1;
        if (c.next_tag == wire.notag) c.next_tag = 1;
        try c.send(tag, msg);
        const f = try c.recv();
        if (f.tag != tag) return error.WrongTag;
        if (f.msg == .Rerror) {
            const e = f.msg.Rerror.ename;
            c.err_len = @min(e.len, c.err.len);
            @memcpy(c.err[0..c.err_len], e[0..c.err_len]);
            return error.Rerror;
        }
        return f.msg;
    }

    pub fn version(c: *Client) !void {
        const r = try c.rpc(p9.Tversion{ .msize = c.msize, .version = wire.version_9p });
        c.msize = r.Rversion.msize;
    }

    /// Attaches; returns the root fid.
    pub fn attach(c: *Client) !u32 {
        const fid = c.newFid();
        _ = try c.rpc(p9.Tattach{ .fid = fid, .afid = wire.nofid, .uname = "test", .aname = "" });
        return fid;
    }

    pub fn newFid(c: *Client) u32 {
        c.next_fid += 1;
        return c.next_fid - 1;
    }

    /// Walks from `root` along `path` (slash-separated) to a new fid.
    pub fn walk(c: *Client, root: u32, path: []const u8) !u32 {
        var names: [wire.max_welem][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |el| : (n += 1) names[n] = el;
        const fid = c.newFid();
        const r = try c.rpc(p9.Twalk{ .fid = root, .newfid = fid, .wnames = wire.Names.init(names[0..n]) });
        if (r.Rwalk.wqids.n != n) return error.NotFound;
        return fid;
    }

    pub fn open(c: *Client, fid: u32, mode: u8) !void {
        _ = try c.rpc(p9.Topen{ .fid = fid, .mode = mode });
    }

    pub fn create(c: *Client, fid: u32, name: []const u8, perm: u32, mode: u8) !void {
        _ = try c.rpc(p9.Tcreate{ .fid = fid, .name = name, .perm = perm, .mode = mode });
    }

    /// One Tread; the data points into the client's buffer.
    pub fn read(c: *Client, fid: u32, off: u64, count: u32) ![]const u8 {
        const r = try c.rpc(p9.Tread{ .fid = fid, .offset = off, .count = count });
        return r.Rread.data.bytes;
    }

    /// Reads to end of file.
    pub fn readAll(c: *Client, a: Allocator, fid: u32) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        while (true) {
            const d = try c.read(fid, out.items.len, 8192);
            if (d.len == 0) break;
            try out.appendSlice(a, d);
        }
        return out.toOwnedSlice(a);
    }

    pub fn write(c: *Client, fid: u32, off: u64, data: []const u8) !u32 {
        const r = try c.rpc(p9.Twrite{ .fid = fid, .offset = off, .data = .{ .bytes = data } });
        return r.Rwrite.count;
    }

    pub fn clunk(c: *Client, fid: u32) !void {
        _ = try c.rpc(p9.Tclunk{ .fid = fid });
    }

    /// Clunks after a failure, keeping the failure's text.
    pub fn clunkKeepErr(c: *Client, fid: u32) void {
        const save = c.err;
        const n = c.err_len;
        c.clunk(fid) catch {};
        c.err = save;
        c.err_len = n;
    }

    pub fn remove(c: *Client, fid: u32) !void {
        _ = try c.rpc(p9.Tremove{ .fid = fid });
    }

    pub fn stat(c: *Client, fid: u32) !Dir {
        const r = try c.rpc(p9.Tstat{ .fid = fid });
        const d = Dir.parse(r.Rstat.stat.bytes) orelse return error.Malformed;
        return d[0];
    }

    /// Walks, opens for writing (with OTRUNC), writes `data` and clunks:
    /// what `echo data >path` does.
    pub fn put(c: *Client, root: u32, path: []const u8, data: []const u8) !void {
        const fid = try c.walk(root, path);
        c.open(fid, wire.OWRITE | wire.OTRUNC) catch |e| {
            c.clunkKeepErr(fid);
            return e;
        };
        if (data.len > 0) _ = c.write(fid, 0, data) catch |e| {
            c.clunkKeepErr(fid);
            return e;
        };
        try c.clunk(fid);
    }

    /// What `cat path` reads.
    pub fn get(c: *Client, a: Allocator, root: u32, path: []const u8) ![]u8 {
        const fid = try c.walk(root, path);
        defer c.clunk(fid) catch {};
        try c.open(fid, wire.OREAD);
        return c.readAll(a, fid);
    }
};
