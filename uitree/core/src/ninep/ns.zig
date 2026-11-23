//! ns: `$ui` as an `Fs` over W3's tree (interface I4). Reads come from
//! the last published `Snapshot`, `events` and `trace` opens subscribe on
//! the tree's `Bus`, and every change goes through the `OpQueue` to the
//! owner thread, which applies it and acks with the protocol's error text.
//!
//! The tree decides what a path is, what each file holds and every error;
//! this file only maps it onto 9P's open/read/clunk shapes. The tree also
//! does the loud side of a failed write (stderr, `trace`, the `error`
//! event), so the host's own loud lines are off when this is the `Fs`.

const std = @import("std");
const tree = @import("../tree/root.zig");
const proto = @import("../proto/root.zig");
const fsmod = @import("fs.zig");

const Allocator = std.mem.Allocator;
const Err = fsmod.Err;
const Tree = tree.Tree;

pub const TreeFs = struct {
    gpa: Allocator,
    t: *Tree,
    q: *tree.OpQueue,
    next_session: std.atomic.Value(u32) = .init(1),

    pub fn fs(n: *TreeFs) fsmod.Fs {
        return .{ .ptr = n, .vt = &vt };
    }

    const vt: fsmod.Fs.VTable = .{
        .connect = connect,
        .disconnect = disconnect,
        .stat = stat,
        .list = list,
        .open = open,
        .read = read,
        .commit = commit,
        .line = line,
        .create = create,
        .remove = remove,
    };

    fn self(p: *anyopaque) *TreeFs {
        return @ptrCast(@alignCast(p));
    }

    fn connect(p: *anyopaque) fsmod.ConnId {
        return self(p).next_session.fetchAdd(1, .monotonic);
    }

    fn disconnect(p: *anyopaque, c: fsmod.ConnId) void {
        const n = self(p);
        n.q.push(.{ .session_closed = @intCast(c) }, null) catch {};
    }

    /// The text of a tree error.
    fn errText(err: *Err, e: anyerror) fsmod.Error {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        const code = proto.Code.fromError(e) orelse return err.set("bad value");
        return err.set(code.phrase());
    }

    fn entryOf(path: []const u8, st: tree.Stat) fsmod.Entry {
        return .{
            .kind = switch (st.kind) {
                .dir => .dir,
                .events, .trace => .stream,
                else => .file,
            },
            .qid = fsmod.qidOf(path),
            .vers = st.ver,
            .perm = switch (st.kind) {
                .dir => 0o777,
                .readonly, .events, .trace => 0o444,
                else => 0o666,
            },
            .length = st.len,
        };
    }

    /// After quit every path walks, so the open is what fails, with `app
    /// gone` (a failed walk would read as `not found`).
    const gone_entry: fsmod.Entry = .{ .kind = .file, .qid = 0x6f6e_6567_0000_0001, .perm = 0o666 };

    fn stat(p: *anyopaque, _: fsmod.ConnId, path: []const u8) ?fsmod.Entry {
        const n = self(p);
        const snap = n.t.acquire();
        defer snap.release();
        if (snap.gone()) return if (path.len == 0) .{ .kind = .dir, .qid = fsmod.qidOf(""), .perm = 0o777 } else gone_entry;
        var arena: std.heap.ArenaAllocator = .init(n.gpa);
        defer arena.deinit();
        const st = snap.stat(arena.allocator(), path) catch return null;
        return entryOf(path, st);
    }

    fn list(p: *anyopaque, _: fsmod.ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const fsmod.DirEnt {
        const n = self(p);
        const snap = n.t.acquire();
        defer snap.release();
        if (snap.gone()) return err.set("app gone");
        const sts = snap.list(arena, path) catch |e| return errText(err, e);
        const out = try arena.alloc(fsmod.DirEnt, sts.len);
        for (sts, out) |st, *o| {
            const full = try fsmod.join(arena, path, st.name);
            o.* = .{ .name = try arena.dupe(u8, st.name), .entry = entryOf(full, st) };
        }
        return out;
    }

    fn open(p: *anyopaque, _: fsmod.ConnId, path: []const u8, mode: fsmod.OpenMode, err: *Err) fsmod.Error!fsmod.Opened {
        const n = self(p);
        const snap = n.t.acquire();
        defer snap.release();
        if (snap.gone()) return err.set("app gone");
        var arena: std.heap.ArenaAllocator = .init(n.gpa);
        defer arena.deinit();
        const target = snap.streamTarget(arena.allocator(), path) catch |e| {
            // A file being created (a prop not set yet): it exists once
            // the write at clunk applies.
            if (e == error.NotFound and mode.write and !mode.read) return .{};
            return errText(err, e);
        };
        if (target) |tg| {
            if (mode.write) return err.set("permission denied: read-only");
            const s = n.t.bus.subscribe(tg) catch |e| return switch (e) {
                error.AppGone => err.set("app gone"),
                error.NotFound => err.set("gone"),
                error.OutOfMemory => error.OutOfMemory,
            };
            return .{ .stream = .{ .ptr = s, .vt = &stream_vt } };
        }
        if (mode.write) {
            const st = snap.stat(arena.allocator(), path) catch |e| return errText(err, e);
            if (st.kind == .readonly) return err.set("permission denied: read-only");
            return .{ .write_mode = writeMode(n, snap, arena.allocator(), path, st.kind) };
        }
        return .{};
    }

    /// Text files and these apply each write, so `echo` sees their errors;
    /// data and bytes files are written whole at clunk.
    const per_write_names = [_][]const u8{
        "style",     "order", "tag",      "on",       "type",       "flags",  "drop", "drag-type", "drag-types", "context", "keys", "focus",
        "page",      "expanded", "origin", "selection", "controlled", "sorted", "state", "mode",
    };

    fn writeMode(n: *TreeFs, snap: *tree.Snapshot, arena: Allocator, path_in: []const u8, kind: tree.Kind) fsmod.WriteMode {
        switch (kind) {
            .ctl => return .ctl,
            .text => return .per_write,
            else => {},
        }
        const path = std.mem.trim(u8, path_in, "/");
        const name = fsmod.baseName(path);
        for (per_write_names) |w| if (std.mem.eql(u8, w, name)) return .per_write;
        if (std.mem.startsWith(u8, path, "theme/") or std.mem.startsWith(u8, path, "menu/")) return .per_write;
        const loc = tree.path.resolve(snap.st, n.t.cat, arena, path, null) catch return .at_close;
        if (loc != .file) return .at_close;
        const nd = snap.st.node(loc.file.node) orelse return .at_close;
        const p = nd.ty.prop(loc.file.name) orelse return .at_close;
        return switch (p.form) {
            .word, .bool, .number, .choice, .path, .child => .per_write,
            else => .at_close,
        };
    }

    fn read(p: *anyopaque, _: fsmod.ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const u8 {
        const n = self(p);
        const snap = n.t.acquire();
        defer snap.release();
        if (snap.gone()) return err.set("app gone");
        return snap.read(arena, path) catch |e| errText(err, e);
    }

    fn call(n: *TreeFs, op: tree.Op, err: *Err) fsmod.Error!void {
        var ack: tree.Ack = .{};
        const txt = try n.q.call(op, &ack);
        if (!ack.ok) return err.set(if (txt.len > 0) txt else "bad value");
    }

    fn commit(p: *anyopaque, c: fsmod.ConnId, path: []const u8, data: []const u8, err: *Err) fsmod.Error!void {
        return self(p).call(.{ .write = .{ .session = @intCast(c), .path = path, .data = data } }, err);
    }

    fn line(_: *anyopaque, _: fsmod.ConnId, _: []const u8, _: []const u8, err: *Err) fsmod.Error!void {
        return err.set("unsupported");
    }

    fn create(p: *anyopaque, c: fsmod.ConnId, dir: []const u8, name: []const u8, is_dir: bool, err: *Err) fsmod.Error!fsmod.Entry {
        const n = self(p);
        const full = try fsmod.join(n.gpa, dir, name);
        defer n.gpa.free(full);
        if (is_dir) {
            try n.call(.{ .mkdir = .{ .session = @intCast(c), .path = full } }, err);
            return .{ .kind = .dir, .qid = fsmod.qidOf(full), .perm = 0o777 };
        }
        // A file: it comes into being when its write applies at clunk.
        return .{ .kind = .file, .qid = fsmod.qidOf(full), .perm = 0o666 };
    }

    fn remove(p: *anyopaque, c: fsmod.ConnId, path: []const u8, err: *Err) fsmod.Error!void {
        return self(p).call(.{ .remove = .{ .session = @intCast(c), .path = path } }, err);
    }

    const stream_vt: fsmod.Stream.VTable = .{ .read = sRead, .interrupt = sInterrupt, .close = sClose };

    fn sRead(p: *anyopaque, buf: []u8) error{Interrupted}!usize {
        const s: *tree.Stream = @ptrCast(@alignCast(p));
        return s.read(buf);
    }
    fn sInterrupt(p: *anyopaque) void {
        const s: *tree.Stream = @ptrCast(@alignCast(p));
        s.interrupt();
    }
    fn sClose(p: *anyopaque) void {
        const s: *tree.Stream = @ptrCast(@alignCast(p));
        s.close();
    }
};

/// Owner thread: `OpQueue.drain`, except that the state the ops made is
/// published before any of them is acked, so a client that reads right
/// after its write (or its clunk) sees it. Returns how many ran.
pub fn drainPublish(q: *tree.OpQueue, t: *Tree) usize {
    q.mu.lockUncancelable(q.io);
    var batch = q.items;
    q.items = .empty;
    q.mu.unlock(q.io);
    defer batch.deinit(q.gpa);
    if (batch.items.len == 0) return 0;
    for (batch.items) |it| {
        defer q.gpa.free(it.mem);
        const r = t.apply(it.op);
        const a = it.ack orelse continue;
        const msg: []const u8 = if (r) |_| "" else |e| if (e == error.OutOfMemory) "out of memory" else t.lastError();
        a.ok = if (r) |_| true else |_| false;
        const n = @min(msg.len, a.buf.len);
        @memcpy(a.buf[0..n], msg[0..n]);
        a.len = n;
    }
    t.publish() catch {};
    q.mu.lockUncancelable(q.io);
    for (batch.items) |it| if (it.ack) |a| {
        a.done = true;
    };
    q.cond.broadcast(q.io);
    q.mu.unlock(q.io);
    return batch.items.len;
}
