//! The spike's 9P2000 server for `$ui`: walk, open, create, read, write,
//! clunk, stat, flush. Thread per connection, plus a thread per request
//! that can block (an `events` read, a `ctl` clunk waiting for its pump).
//! Writes to `ctl`, `keys`, `menu/NAME` and prop files apply when the
//! file is closed, as core.md § Commands says. POSIX only.
//!
//! W4 replaces this with a server on hyper9's dotl/wire.zig.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const treemod = @import("tree.zig");

const c = std.c;
const Core = abi.Core;
const gpa = std.heap.c_allocator;

const max_msize: u32 = 64 << 10;

/// Connections being served, across every core (uit_destroy checks it).
pub var live: std.atomic.Value(u32) = .init(0);

const T = struct {
    const version = 100;
    const auth = 102;
    const attach = 104;
    const flush = 108;
    const walk = 110;
    const open = 112;
    const create = 114;
    const read = 116;
    const write = 118;
    const clunk = 120;
    const remove = 122;
    const stat = 124;
    const wstat = 126;
};
const Rerror = 107;

const QTDIR: u8 = 0x80;
const DMDIR: u32 = 0x80000000;

// ---------------------------------------------------------------------
// What a path names

const Kind = union(enum) {
    root,
    app_ctl,
    app_events,
    keys,
    version,
    menu_dir,
    menu_file: []const u8,
    win_dir,
    node_dir: u32,
    node_file: struct { node: u32, name: []const u8 },
};

fn isDir(k: Kind) bool {
    return switch (k) {
        .root, .menu_dir, .win_dir, .node_dir => true,
        else => false,
    };
}

/// Resolves a path (elements joined by `/`, "" the root). Called with
/// core.mu held.
fn resolve(t: *treemod.Tree, path: []const u8) ?Kind {
    if (path.len == 0) return .root;
    var it = std.mem.splitScalar(u8, path, '/');
    const first = it.next().?;
    const rest = it.rest();
    const top = std.StaticStringMap(Kind).initComptime(.{
        .{ "ctl", .app_ctl },  .{ "events", .app_events }, .{ "keys", .keys },
        .{ "version", .version }, .{ "menu", .menu_dir }, .{ "win", .win_dir },
    });
    const k = top.get(first) orelse return null;
    if (rest.len == 0 and std.mem.indexOfScalar(u8, path, '/') == null) return k;
    switch (k) {
        .menu_dir => return if (std.mem.indexOfScalar(u8, rest, '/') == null) .{ .menu_file = rest } else null,
        .win_dir => {
            var wi = std.mem.splitScalar(u8, rest, '/');
            if (!std.mem.eql(u8, wi.next().?, "main")) return null;
            var at = t.main_root;
            while (wi.next()) |el| {
                if (t.child(at, el)) |ch| {
                    at = ch;
                    continue;
                }
                // Not a child: a node file, which must be the last element.
                if (wi.peek() != null) return null;
                return .{ .node_file = .{ .node = at, .name = el } };
            }
            return .{ .node_dir = at };
        },
        else => return null,
    }
}

const node_files = [_][]const u8{ "ctl", "events", "type", "style", "order", "tag", "on" };

/// A file's contents at open, for reads.
fn contents(t: *treemod.Tree, a: std.mem.Allocator, k: Kind) ![]u8 {
    switch (k) {
        .version => return a.dupe(u8, "core 1.0\nspike\n"),
        .keys => return a.dupe(u8, t.keys_text),
        .menu_file => |name| return a.dupe(u8, t.menus.get(name) orelse ""),
        .node_file => |f| {
            const n = t.get(f.node) orelse return error.NotFound;
            if (std.mem.eql(u8, f.name, "type")) return std.fmt.allocPrint(a, "{s}\n", .{n.typ});
            if (std.mem.eql(u8, f.name, "order")) {
                var b: std.ArrayList(u8) = .empty;
                for (n.kids.items, 0..) |kid, i| {
                    if (i > 0) try b.append(a, ' ');
                    try b.appendSlice(a, t.get(kid).?.name);
                }
                try b.append(a, '\n');
                return b.items;
            }
            if (std.mem.eql(u8, f.name, "ctl")) return a.dupe(u8, "set\nnew\ndelete\n");
            const v = n.prop(f.name) orelse return a.dupe(u8, "");
            if (std.mem.indexOfScalar(u8, v, '\n') == null) return std.fmt.allocPrint(a, "{s}\n", .{v});
            return a.dupe(u8, v);
        },
        .app_ctl => return a.dupe(u8, "window\nquit\n"),
        else => return a.dupe(u8, ""),
    }
}

// ---------------------------------------------------------------------
// Wire helpers

const Enc = struct {
    buf: []u8,
    n: usize = 7,

    fn u8_(e: *Enc, v: u8) void {
        e.buf[e.n] = v;
        e.n += 1;
    }
    fn u16_(e: *Enc, v: u16) void {
        std.mem.writeInt(u16, e.buf[e.n..][0..2], v, .little);
        e.n += 2;
    }
    fn u32_(e: *Enc, v: u32) void {
        std.mem.writeInt(u32, e.buf[e.n..][0..4], v, .little);
        e.n += 4;
    }
    fn u64_(e: *Enc, v: u64) void {
        std.mem.writeInt(u64, e.buf[e.n..][0..8], v, .little);
        e.n += 8;
    }
    fn str(e: *Enc, s: []const u8) void {
        e.u16_(@intCast(s.len));
        @memcpy(e.buf[e.n..][0..s.len], s);
        e.n += s.len;
    }
    fn qid(e: *Enc, q: Qid) void {
        e.u8_(q.typ);
        e.u32_(0);
        e.u64_(q.path);
    }
    fn finish(e: *Enc, typ: u8, tag: u16) []u8 {
        std.mem.writeInt(u32, e.buf[0..4], @intCast(e.n), .little);
        e.buf[4] = typ;
        std.mem.writeInt(u16, e.buf[5..7], tag, .little);
        return e.buf[0..e.n];
    }
};

const Dec = struct {
    b: []const u8,
    n: usize = 7,

    fn u8_(d: *Dec) !u8 {
        if (d.n + 1 > d.b.len) return error.Short;
        d.n += 1;
        return d.b[d.n - 1];
    }
    fn u16_(d: *Dec) !u16 {
        if (d.n + 2 > d.b.len) return error.Short;
        defer d.n += 2;
        return std.mem.readInt(u16, d.b[d.n..][0..2], .little);
    }
    fn u32_(d: *Dec) !u32 {
        if (d.n + 4 > d.b.len) return error.Short;
        defer d.n += 4;
        return std.mem.readInt(u32, d.b[d.n..][0..4], .little);
    }
    fn u64_(d: *Dec) !u64 {
        if (d.n + 8 > d.b.len) return error.Short;
        defer d.n += 8;
        return std.mem.readInt(u64, d.b[d.n..][0..8], .little);
    }
    fn str(d: *Dec) ![]const u8 {
        const l = try d.u16_();
        if (d.n + l > d.b.len) return error.Short;
        defer d.n += l;
        return d.b[d.n..][0..l];
    }
};

const Qid = struct { typ: u8, path: u64 };

fn qidOf(path: []const u8, dir: bool) Qid {
    return .{ .typ = if (dir) QTDIR else 0, .path = std.hash.Wyhash.hash(0, path) };
}

fn packStat(out: []u8, name: []const u8, path: []const u8, dir: bool) ?[]u8 {
    const need = 2 + 2 + 4 + 13 + 4 + 4 + 4 + 8 + (2 + name.len) + 3 * (2 + 2);
    if (out.len < need) return null;
    var e: Enc = .{ .buf = out, .n = 0 };
    e.u16_(@intCast(need - 2));
    e.u16_(0);
    e.u32_(0);
    e.qid(qidOf(path, dir));
    e.u32_(if (dir) DMDIR | 0o555 else 0o666);
    e.u32_(0);
    e.u32_(0);
    e.u64_(0);
    e.str(name);
    e.str("ui");
    e.str("ui");
    e.str("ui");
    return out[0..need];
}

// ---------------------------------------------------------------------
// Connections

const Fid = struct {
    path: []u8,
    open: bool = false,
    write: bool = false,
    wbuf: std.ArrayList(u8) = .empty,
    data: []u8 = &.{},
    sub: ?*treemod.Sub = null,
};

const Pending = struct {
    flushed: bool = false,
    done: bool = false,
};

const Conn = struct {
    core: *Core,
    fd: c_int,
    wmu: std.Io.Mutex = .init,
    /// Guards fids and pending (taken inside core.mu when both are).
    fmu: std.Io.Mutex = .init,
    fids: std.AutoHashMapUnmanaged(u32, *Fid) = .empty,
    pending: std.AutoHashMapUnmanaged(u16, *Pending) = .empty,
    msize: u32 = 8192,
    refs: std.atomic.Value(u32) = .init(1),

    fn io(cn: *Conn) std.Io {
        return cn.core.io();
    }

    fn unref(cn: *Conn) void {
        if (cn.refs.fetchSub(1, .acq_rel) != 1) return;
        var it = cn.fids.iterator();
        while (it.next()) |e| cn.dropFid(e.value_ptr.*);
        cn.fids.deinit(gpa);
        cn.pending.deinit(gpa);
        _ = c.close(cn.fd);
        _ = live.fetchSub(1, .acq_rel);
        gpa.destroy(cn);
    }

    fn dropFid(cn: *Conn, f: *Fid) void {
        if (f.sub) |s| {
            cn.core.lock();
            cn.core.tree.unsubscribe(s);
            cn.core.tree.unref(s);
            cn.core.unlock();
        }
        gpa.free(f.path);
        f.wbuf.deinit(gpa);
        gpa.free(f.data);
        gpa.destroy(f);
    }

    fn send(cn: *Conn, msg: []const u8) void {
        cn.wmu.lockUncancelable(cn.io());
        defer cn.wmu.unlock(cn.io());
        var off: usize = 0;
        while (off < msg.len) {
            const w = c.write(cn.fd, msg.ptr + off, msg.len - off);
            if (w <= 0) return;
            off += @intCast(w);
        }
    }

    fn sendErr(cn: *Conn, tag: u16, msg: []const u8) void {
        var b: [512]u8 = undefined;
        var e: Enc = .{ .buf = &b };
        e.str(msg[0..@min(msg.len, 400)]);
        cn.send(e.finish(Rerror, tag));
    }

    fn getFid(cn: *Conn, fid: u32) ?*Fid {
        cn.fmu.lockUncancelable(cn.io());
        defer cn.fmu.unlock(cn.io());
        return cn.fids.get(fid);
    }

    fn putFid(cn: *Conn, fid: u32, f: *Fid) !void {
        cn.fmu.lockUncancelable(cn.io());
        defer cn.fmu.unlock(cn.io());
        try cn.fids.put(gpa, fid, f);
    }

    fn takeFid(cn: *Conn, fid: u32) ?*Fid {
        cn.fmu.lockUncancelable(cn.io());
        defer cn.fmu.unlock(cn.io());
        const kv = cn.fids.fetchRemove(fid) orelse return null;
        return kv.value;
    }
};

fn readFull(fd: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.read(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn serveConn(cn: *Conn) void {
    defer cn.unref();
    const in = gpa.alloc(u8, max_msize) catch return;
    defer gpa.free(in);
    while (true) {
        if (!readFull(cn.fd, in[0..4])) return;
        const size = std.mem.readInt(u32, in[0..4], .little);
        if (size < 7 or size > max_msize) return;
        if (!readFull(cn.fd, in[4..size])) return;
        handle(cn, in[0..size]) catch |e| {
            const tag = std.mem.readInt(u16, in[5..7], .little);
            cn.sendErr(tag, @errorName(e));
        };
    }
}

/// Serves a connected fd on its own thread.
pub fn serveFd(core: *Core, fd: c_int) !void {
    if (comptime builtin.os.tag == .windows) return error.Unsupported;
    const cn = try gpa.create(Conn);
    cn.* = .{ .core = core, .fd = fd };
    _ = live.fetchAdd(1, .acq_rel);
    const th = std.Thread.spawn(.{}, serveConn, .{cn}) catch |e| {
        _ = live.fetchSub(1, .acq_rel);
        gpa.destroy(cn);
        return e;
    };
    th.detach();
}

fn handle(cn: *Conn, msg: []const u8) !void {
    var d: Dec = .{ .b = msg };
    const typ = msg[4];
    const tag = std.mem.readInt(u16, msg[5..7], .little);
    var out_buf: [8192]u8 = undefined;
    var e: Enc = .{ .buf = &out_buf };
    const core = cn.core;
    switch (typ) {
        T.version => {
            const ms = try d.u32_();
            const v = try d.str();
            cn.msize = @min(ms, max_msize);
            e.u32_(cn.msize);
            e.str(if (std.mem.startsWith(u8, v, "9P2000")) "9P2000" else "unknown");
            cn.send(e.finish(T.version + 1, tag));
        },
        T.auth => cn.sendErr(tag, "no authentication required"),
        T.attach => {
            const fid = try d.u32_();
            if (core.gone.load(.acquire)) return cn.sendErr(tag, "app gone");
            const f = try gpa.create(Fid);
            f.* = .{ .path = try gpa.dupe(u8, "") };
            try cn.putFid(fid, f);
            e.qid(qidOf("", true));
            cn.send(e.finish(T.attach + 1, tag));
        },
        T.flush => {
            const old = try d.u16_();
            core.lock();
            cn.fmu.lockUncancelable(cn.io());
            const p = cn.pending.get(old);
            cn.fmu.unlock(cn.io());
            if (p) |pp| {
                pp.flushed = true;
                core.cond.broadcast(core.io());
                while (!pp.done) core.cond.waitUncancelable(core.io(), &core.mu);
                gpa.destroy(pp);
            }
            core.unlock();
            cn.send(e.finish(T.flush + 1, tag));
        },
        T.walk => {
            const fid = try d.u32_();
            const newfid = try d.u32_();
            const n = try d.u16_();
            const from = cn.getFid(fid) orelse return cn.sendErr(tag, "unknown fid");
            var path: std.ArrayList(u8) = .empty;
            defer path.deinit(gpa);
            try path.appendSlice(gpa, from.path);
            var qids: [16]Qid = undefined;
            var got: usize = 0;
            core.lock();
            var i: usize = 0;
            while (i < n and i < 16) : (i += 1) {
                const name = try d.str();
                const save = path.items.len;
                if (std.mem.eql(u8, name, "..")) {
                    if (std.mem.lastIndexOfScalar(u8, path.items, '/')) |sl| path.shrinkRetainingCapacity(sl) else path.clearRetainingCapacity();
                } else {
                    if (path.items.len > 0) try path.append(gpa, '/');
                    try path.appendSlice(gpa, name);
                }
                const k = resolve(core.tree, path.items) orelse {
                    path.shrinkRetainingCapacity(save);
                    break;
                };
                qids[got] = qidOf(path.items, isDir(k));
                got += 1;
            }
            core.unlock();
            if (got == 0 and n > 0) return cn.sendErr(tag, "not found");
            if (got == n) {
                if (newfid == fid) {
                    gpa.free(from.path);
                    from.path = try gpa.dupe(u8, path.items);
                } else {
                    const f = try gpa.create(Fid);
                    f.* = .{ .path = try gpa.dupe(u8, path.items) };
                    try cn.putFid(newfid, f);
                }
            }
            e.u16_(@intCast(got));
            for (qids[0..got]) |q| e.qid(q);
            cn.send(e.finish(T.walk + 1, tag));
        },
        T.open, T.create => {
            const fid = try d.u32_();
            const f = cn.getFid(fid) orelse return cn.sendErr(tag, "unknown fid");
            if (typ == T.create) {
                const name = try d.str();
                const perm = try d.u32_();
                if (perm & DMDIR != 0) return cn.sendErr(tag, "spike: mkdir not supported");
                const np = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ f.path, if (f.path.len > 0) "/" else "", name });
                gpa.free(f.path);
                f.path = np;
            }
            const mode: u8 = if (typ == T.create) blk: {
                break :blk try d.u8_();
            } else try d.u8_();
            if (core.gone.load(.acquire)) return cn.sendErr(tag, "app gone");
            core.lock();
            const k = resolve(core.tree, f.path);
            var dir = false;
            var err: ?[]const u8 = null;
            if (k) |kk| {
                dir = isDir(kk);
                f.write = (mode & 3) == 1 or (mode & 3) == 2;
                switch (kk) {
                    .app_events => f.sub = core.tree.subscribe(0) catch null,
                    .node_file => |nf| {
                        if (std.mem.eql(u8, nf.name, "events")) f.sub = core.tree.subscribe(nf.node) catch null;
                    },
                    else => {},
                }
                if (!dir and f.sub == null and (mode & 3) != 1) f.data = contents(core.tree, gpa, kk) catch &.{};
            } else err = "not found";
            core.unlock();
            if (err) |m| return cn.sendErr(tag, m);
            f.open = true;
            e.qid(qidOf(f.path, dir));
            e.u32_(0);
            cn.send(e.finish(typ + 1, tag));
        },
        T.read => {
            const fid = try d.u32_();
            const off = try d.u64_();
            const count = try d.u32_();
            const f = cn.getFid(fid) orelse return cn.sendErr(tag, "unknown fid");
            if (!f.open) return cn.sendErr(tag, "fid not open");
            const cap = @min(count, cn.msize - 11);
            if (f.sub != null) {
                const p = try gpa.create(Pending);
                p.* = .{};
                cn.fmu.lockUncancelable(cn.io());
                try cn.pending.put(gpa, tag, p);
                cn.fmu.unlock(cn.io());
                _ = cn.refs.fetchAdd(1, .acq_rel);
                const th = try std.Thread.spawn(.{}, readEvents, .{ cn, f, tag, cap, p });
                th.detach();
                return;
            }
            core.lock();
            const k = resolve(core.tree, f.path);
            if (k != null and isDir(k.?) and off == 0) {
                gpa.free(f.data);
                f.data = dirData(core.tree, f.path, k.?) catch &.{};
            }
            core.unlock();
            const start = @min(off, f.data.len);
            const end = @min(start + cap, f.data.len);
            var big = try gpa.alloc(u8, 11 + (end - start));
            defer gpa.free(big);
            var re: Enc = .{ .buf = big };
            re.u32_(@intCast(end - start));
            @memcpy(big[11..][0 .. end - start], f.data[start..end]);
            re.n = 11 + (end - start);
            cn.send(re.finish(T.read + 1, tag));
        },
        T.write => {
            const fid = try d.u32_();
            _ = try d.u64_();
            const count = try d.u32_();
            const f = cn.getFid(fid) orelse return cn.sendErr(tag, "unknown fid");
            if (!f.open or !f.write) return cn.sendErr(tag, "not open for writing");
            if (d.n + count > msg.len) return cn.sendErr(tag, "short write");
            try f.wbuf.appendSlice(gpa, msg[d.n..][0..count]);
            e.u32_(count);
            cn.send(e.finish(T.write + 1, tag));
        },
        T.clunk, T.remove => {
            const fid = try d.u32_();
            const f = cn.takeFid(fid) orelse return cn.sendErr(tag, "unknown fid");
            if (f.write and f.open and (f.wbuf.items.len > 0 or typ == T.clunk)) {
                _ = cn.refs.fetchAdd(1, .acq_rel);
                const th = try std.Thread.spawn(.{}, applyWrite, .{ cn, f, tag, typ });
                th.detach();
                return;
            }
            cn.dropFid(f);
            if (typ == T.remove) return cn.sendErr(tag, "spike: remove not supported");
            cn.send(e.finish(T.clunk + 1, tag));
        },
        T.stat => {
            const fid = try d.u32_();
            const f = cn.getFid(fid) orelse return cn.sendErr(tag, "unknown fid");
            core.lock();
            const k = resolve(core.tree, f.path);
            core.unlock();
            const name = if (std.mem.lastIndexOfScalar(u8, f.path, '/')) |i| f.path[i + 1 ..] else if (f.path.len == 0) "/" else f.path;
            var sb: [512]u8 = undefined;
            const st = packStat(&sb, name, f.path, if (k) |kk| isDir(kk) else false) orelse return cn.sendErr(tag, "name too long");
            e.str(st);
            cn.send(e.finish(T.stat + 1, tag));
        },
        T.wstat => cn.send(e.finish(T.wstat + 1, tag)),
        else => cn.sendErr(tag, "bad message"),
    }
}

fn dirData(t: *treemod.Tree, path: []const u8, k: Kind) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var dirs: std.ArrayList(bool) = .empty;
    defer dirs.deinit(gpa);
    switch (k) {
        .root => {
            for ([_][]const u8{ "ctl", "events", "keys", "version", "menu", "win" }, [_]bool{ false, false, false, false, true, true }) |n, isd| {
                try names.append(gpa, n);
                try dirs.append(gpa, isd);
            }
        },
        .menu_dir => {
            for (t.menus.keys()) |n| {
                try names.append(gpa, n);
                try dirs.append(gpa, false);
            }
        },
        .win_dir => {
            try names.append(gpa, "main");
            try dirs.append(gpa, true);
        },
        .node_dir => |id| {
            const n = t.get(id).?;
            for (node_files) |f| {
                try names.append(gpa, f);
                try dirs.append(gpa, false);
            }
            for (n.props.keys()) |p| {
                var dup = false;
                for (node_files) |f| dup = dup or std.mem.eql(u8, f, p);
                if (dup) continue;
                try names.append(gpa, p);
                try dirs.append(gpa, false);
            }
            for (n.kids.items) |kid| {
                try names.append(gpa, t.get(kid).?.name);
                try dirs.append(gpa, true);
            }
        },
        else => {},
    }
    var sb: [512]u8 = undefined;
    for (names.items, dirs.items) |n, isd| {
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ path, n });
        defer gpa.free(full);
        try out.appendSlice(gpa, packStat(&sb, n, full, isd) orelse continue);
    }
    return out.toOwnedSlice(gpa);
}

/// A blocking read of an events file, on its own thread.
fn readEvents(cn: *Conn, f: *Fid, tag: u16, cap: u32, p: *Pending) void {
    defer cn.unref();
    const core = cn.core;
    const s = f.sub.?;
    var buf = gpa.alloc(u8, 11 + cap) catch return;
    defer gpa.free(buf);
    var n: usize = 0;
    core.lock();
    while (true) {
        if (p.flushed) break;
        if (s.partial_off < s.partial.len) {
            const k = @min(cap, s.partial.len - s.partial_off);
            @memcpy(buf[11..][0..k], s.partial[s.partial_off..][0..k]);
            s.partial_off += k;
            n = k;
            break;
        }
        if (s.lines.items.len > 0) {
            while (s.lines.items.len > 0) {
                const l = s.lines.items[0];
                if (n + l.len > cap) {
                    if (n == 0) {
                        // A line longer than the read: the rest comes next.
                        @memcpy(buf[11..][0..cap], l[0..cap]);
                        gpa.free(s.partial);
                        s.partial = l;
                        s.partial_off = cap;
                        _ = s.lines.orderedRemove(0);
                        n = cap;
                    }
                    break;
                }
                @memcpy(buf[11..][n..][0..l.len], l);
                n += l.len;
                gpa.free(l);
                _ = s.lines.orderedRemove(0);
            }
            break;
        }
        if (s.closed or core.gone.load(.acquire)) break;
        core.cond.waitUncancelable(core.io(), &core.mu);
    }
    const flushed = p.flushed;
    p.done = true;
    cn.fmu.lockUncancelable(cn.io());
    _ = cn.pending.remove(tag);
    cn.fmu.unlock(cn.io());
    // A flush that found it frees it once it sees `done`.
    if (!flushed) gpa.destroy(p);
    core.cond.broadcast(core.io());
    core.unlock();
    if (flushed) return;
    var e: Enc = .{ .buf = buf };
    e.u32_(@intCast(n));
    e.n = 11 + n;
    cn.send(e.finish(T.read + 1, tag));
}

/// Applies a closed file's writes through the pump, on its own thread.
fn applyWrite(cn: *Conn, f: *Fid, tag: u16, typ: u8) void {
    defer cn.unref();
    defer cn.dropFid(f);
    const core = cn.core;
    var ack: abi.Ack = .{};
    var text = f.wbuf.items;
    core.lock();
    const k = resolve(core.tree, f.path);
    core.unlock();
    const op: ?*abi.Op = if (k) |kk| switch (kk) {
        .app_ctl => abi.newOp(gpa, .ctl, 0, "", text) catch null,
        .keys => abi.newOp(gpa, .keys, 0, "", text) catch null,
        .menu_file => |name| abi.newOp(gpa, .menu, 0, name, text) catch null,
        .node_file => |nf| blk: {
            if (std.mem.eql(u8, nf.name, "ctl")) break :blk abi.newOp(gpa, .ctl, nf.node, "", text) catch null;
            // A one-line value written with its newline: drop it.
            if (text.len > 0 and text[text.len - 1] == '\n' and std.mem.indexOfScalar(u8, text[0 .. text.len - 1], '\n') == null) text = text[0 .. text.len - 1];
            break :blk abi.newOp(gpa, .prop, nf.node, nf.name, text) catch null;
        },
        else => null,
    } else null;
    var e_buf: [64]u8 = undefined;
    var e: Enc = .{ .buf = &e_buf };
    const o = op orelse {
        if (k == null) return cn.sendErr(tag, "not found");
        // Writing a read-only file (events, version): ignored by the spike.
        cn.send(e.finish(typ + 1, tag));
        return;
    };
    core.submit(o, &ack);
    if (ack.err_len > 0) return cn.sendErr(tag, ack.err());
    if (typ == T.remove) return cn.sendErr(tag, "spike: remove not supported");
    cn.send(e.finish(typ + 1, tag));
}

// ---------------------------------------------------------------------
// Listening

/// A unix socket in a private directory, served until `stop`. POSIX only:
/// on Windows `start` fails and uit_listen returns UIT_ENOTSUP.
pub const Server = if (builtin.os.tag == .windows) struct {
    dial: []u8 = &.{},
    path: [:0]u8 = undefined,
    pub fn start(core: *Core) !*Server {
        _ = core;
        return error.Unsupported;
    }
    pub fn stop(s: *Server) void {
        _ = s;
    }
} else PosixServer;

const PosixServer = struct {

    core: *Core,
    fd: c_int,
    dir: [:0]u8,
    path: [:0]u8,
    /// `unix!PATH`
    dial: []u8,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn start(core: *Core) !*PosixServer {
        if (comptime builtin.os.tag == .windows) return error.Unsupported;
        const tmp = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
        var n: u32 = 0;
        const dir = while (true) : (n += 1) {
            var rnd: [6]u8 = undefined;
            core.io().random(&rnd);
            const d = try std.fmt.allocPrintSentinel(gpa, "{s}/uitree-{x}", .{ std.mem.trimEnd(u8, tmp, "/"), &rnd }, 0);
            if (c.mkdir(d, 0o700) == 0) break d;
            gpa.free(d);
            if (n > 8) return error.MkdirFailed;
        };
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/ui", .{dir}, 0);
        var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return error.BindFailed;
        if (c.listen(fd, 16) != 0) return error.ListenFailed;
        const s = try gpa.create(PosixServer);
        s.* = .{ .core = core, .fd = fd, .dir = dir, .path = path, .dial = try std.fmt.allocPrint(gpa, "unix!{s}", .{path}), .thread = undefined };
        s.thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
        return s;
    }

    fn acceptLoop(s: *PosixServer) void {
        while (!s.stopping.load(.acquire)) {
            const conn = c.accept(s.fd, null, null);
            if (conn < 0) {
                if (s.stopping.load(.acquire)) return;
                continue;
            }
            if (s.stopping.load(.acquire)) {
                _ = c.close(conn);
                return;
            }
            serveFd(s.core, conn) catch {
                _ = c.close(conn);
            };
        }
    }

    pub fn stop(s: *PosixServer) void {
        s.stopping.store(true, .release);
        // Wake the accept with a connection of our own.
        const w = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..s.path.len], s.path);
        _ = c.connect(w, @ptrCast(&addr), @sizeOf(c.sockaddr.un));
        s.thread.join();
        _ = c.close(w);
        _ = c.close(s.fd);
        _ = c.unlink(s.path);
        _ = c.rmdir(s.dir);
        gpa.free(s.dial);
        gpa.free(s.path);
        gpa.free(s.dir);
        gpa.destroy(s);
    }
};
