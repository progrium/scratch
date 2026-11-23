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
            return .{ .write_mode = writeMode(n, snap, arena.allocator(), path, st.kind), .token = ownerOf(n, snap, arena.allocator(), path) };
        }
        return .{};
    }

    /// Text files and these apply each write, so `echo` sees their errors;
    /// data and bytes files are written whole at clunk.
    const per_write_names = [_][]const u8{
        "style",     "order", "tag",      "on",       "type",       "flags",  "drop", "drag-type", "drag-types", "context", "tooltip", "keys", "focus",
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

    /// The node a node file (or window file) belongs to, for `gone`.
    fn ownerOf(n: *TreeFs, snap: *tree.Snapshot, arena: Allocator, path: []const u8) u64 {
        const loc = tree.path.resolve(snap.st, n.t.cat, arena, std.mem.trim(u8, path, "/"), null) catch return 0;
        return switch (loc) {
            .file => |f| f.node,
            .win_file => |f| f.root,
            else => 0,
        };
    }

    fn commit(p: *anyopaque, c: fsmod.ConnId, path: []const u8, token: u64, data: []const u8, err: *Err) fsmod.Error!void {
        var op: tree.Op.FileOp = .{ .session = @intCast(c), .path = path, .data = data };
        // The tree says `gone` when the node the file was opened under has
        // been deleted since (FileOp.node).
        if (@hasField(tree.Op.FileOp, "node")) op.node = @intCast(token);
        return self(p).call(.{ .write = op }, err);
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


test "TreeFs: per-write ctl errors, reads after writes, text at clunk" {
    const t = std.testing;
    const types = @import("../types/root.zig");
    const server = @import("server.zig");
    const transport = @import("transport.zig");
    const Client = @import("client.zig").Client;
    const wire = @import("wire.zig");

    var th: std.Io.Threaded = .init(t.allocator, .{});
    defer th.deinit();
    const io = th.io();
    var cat = try types.Catalog.builtin(t.allocator);
    defer cat.deinit();
    const tr = try Tree.create(t.allocator, io, &cat, .{});
    defer tr.destroy();
    var q: tree.OpQueue = .init(t.allocator, io);
    defer q.deinit();

    // The owner thread: drain until told to stop.
    const Owner = struct {
        q: *tree.OpQueue,
        t: *Tree,
        stop: std.atomic.Value(bool) = .init(false),
        fn run(o: *@This()) void {
            while (!o.stop.load(.acquire)) {
                if (o.q.drain(o.t) == 0) std.Thread.yield() catch {};
            }
        }
    };
    var owner: Owner = .{ .q = &q, .t = tr };
    const thr = try std.Thread.spawn(.{}, Owner.run, .{&owner});

    var tfs: TreeFs = .{ .gpa = t.allocator, .t = tr, .q = &q };
    var srv: server.Server = .init(t.allocator, io, tfs.fs());
    const p = try transport.pair();
    try srv.serve(p[0]);
    var cl = try Client.init(t.allocator, p[1]);
    try cl.version();
    const root = try cl.attach();

    // A ctl write applies at the write, and its error comes back there.
    const f = try cl.walk(root, "win/main/ctl");
    try cl.open(f, wire.OWRITE);
    _ = try cl.write(f, 0, "new text a text=hi\n");
    try t.expectError(error.Rerror, cl.write(f, 0, "new nosuchtype b\n"));
    try cl.clunk(f);
    const got = try cl.get(t.allocator, root, "win/main/a/text");
    defer t.allocator.free(got);
    try t.expectEqualStrings("hi\n", got);

    // A text file written in one write applies then.
    try cl.put(root, "win/main/a/text", "there");
    const got2 = try cl.get(t.allocator, root, "win/main/a/text");
    defer t.allocator.free(got2);
    try t.expectEqualStrings("there\n", got2);

    cl.deinit();
    srv.deinit();
    q.close();
    owner.stop.store(true, .release);
    thr.join();
}
