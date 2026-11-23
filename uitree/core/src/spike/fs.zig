//! The spike's `$ui` as a `ninep.Fs`, so W4's 9P server serves the spike
//! tree until W3's lands (then ninep/ns.zig does this over a Snapshot and
//! this file goes with the rest of spike/). Reads take `Core.mu` and read
//! the live tree; writes go through the core's op queue and wait for the
//! pump. Writes to `ctl`, `keys`, `menu/NAME` and prop files apply when the
//! file is closed, as core.md § Commands says.

const std = @import("std");
const abi = @import("../abi.zig");
const treemod = @import("tree.zig");
const fsmod = @import("../ninep/fs.zig");

const Core = abi.Core;
const gpa = std.heap.c_allocator;
const Allocator = std.mem.Allocator;
const Err = fsmod.Err;

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

fn entryOf(k: Kind, path: []const u8) fsmod.Entry {
    return .{
        .kind = if (isDir(k)) .dir else switch (k) {
            .app_events => .stream,
            .node_file => |nf| if (std.mem.eql(u8, nf.name, "events")) .stream else .file,
            else => .file,
        },
        .qid = fsmod.qidOf(path),
        .perm = if (isDir(k)) 0o777 else 0o666,
    };
}

/// The spike's Fs: one per core.
pub const SpikeFs = struct {
    core: *Core,

    pub fn fs(s: *SpikeFs) fsmod.Fs {
        return .{ .ptr = s, .vt = &vt };
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

    fn coreOf(p: *anyopaque) *Core {
        const s: *SpikeFs = @ptrCast(@alignCast(p));
        return s.core;
    }

    fn connect(_: *anyopaque) fsmod.ConnId {
        return 1;
    }
    fn disconnect(_: *anyopaque, _: fsmod.ConnId) void {}

    fn stat(p: *anyopaque, _: fsmod.ConnId, path: []const u8) ?fsmod.Entry {
        const c = coreOf(p);
        if (c.gone.load(.acquire)) return if (path.len == 0) entryOf(.root, "") else null;
        c.lock();
        defer c.unlock();
        const k = resolve(c.tree, path) orelse return null;
        return entryOf(k, path);
    }

    fn list(p: *anyopaque, _: fsmod.ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const fsmod.DirEnt {
        const c = coreOf(p);
        if (c.gone.load(.acquire)) return err.set("app gone");
        c.lock();
        defer c.unlock();
        const k = resolve(c.tree, path) orelse return err.set("gone");
        var out: std.ArrayList(fsmod.DirEnt) = .empty;
        const t = c.tree;
        switch (k) {
            .root => for ([_][]const u8{ "ctl", "events", "keys", "version", "menu", "win" }) |n| {
                try out.append(arena, .{ .name = n, .entry = entryOf(resolve(t, n).?, n) });
            },
            .menu_dir => for (t.menus.keys()) |n| {
                try out.append(arena, .{ .name = try arena.dupe(u8, n), .entry = .{ .kind = .file, .qid = fsmod.qidOf(n) } });
            },
            .win_dir => try out.append(arena, .{ .name = "main", .entry = entryOf(.{ .node_dir = t.main_root }, "win/main") }),
            .node_dir => |id| {
                const n = t.get(id).?;
                for (node_files) |f| {
                    const full = try fsmod.join(arena, path, f);
                    try out.append(arena, .{ .name = f, .entry = entryOf(.{ .node_file = .{ .node = id, .name = f } }, full) });
                }
                prop: for (n.props.keys()) |pn| {
                    for (node_files) |f| if (std.mem.eql(u8, f, pn)) continue :prop;
                    const full = try fsmod.join(arena, path, pn);
                    try out.append(arena, .{ .name = try arena.dupe(u8, pn), .entry = entryOf(.{ .node_file = .{ .node = id, .name = pn } }, full) });
                }
                for (n.kids.items) |kid| {
                    const kn = t.get(kid).?;
                    const full = try fsmod.join(arena, path, kn.name);
                    try out.append(arena, .{ .name = try arena.dupe(u8, kn.name), .entry = entryOf(.{ .node_dir = kid }, full) });
                }
            },
            else => return err.set("not a directory"),
        }
        return out.items;
    }

    fn open(p: *anyopaque, _: fsmod.ConnId, path: []const u8, mode: fsmod.OpenMode, err: *Err) fsmod.Error!fsmod.Opened {
        const c = coreOf(p);
        if (c.gone.load(.acquire)) return err.set("app gone");
        c.lock();
        defer c.unlock();
        const k = resolve(c.tree, path) orelse return err.set("not found");
        const node: ?u32 = switch (k) {
            .app_events => 0,
            .node_file => |nf| if (std.mem.eql(u8, nf.name, "events")) nf.node else null,
            else => null,
        };
        if (node) |n| {
            if (mode.write) return err.set("permission denied: read-only");
            const st = try gpa.create(Stream);
            errdefer gpa.destroy(st);
            st.* = .{ .core = c, .sub = try c.tree.subscribe(n) };
            return .{ .stream = .{ .ptr = st, .vt = &Stream.vt } };
        }
        return .{};
    }

    fn read(p: *anyopaque, _: fsmod.ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const u8 {
        const c = coreOf(p);
        if (c.gone.load(.acquire)) return err.set("app gone");
        c.lock();
        defer c.unlock();
        const k = resolve(c.tree, path) orelse return err.set("gone");
        return contents(c.tree, arena, k) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => err.set("gone"),
        };
    }

    fn commit(p: *anyopaque, _: fsmod.ConnId, path: []const u8, data: []const u8, err: *Err) fsmod.Error!void {
        const c = coreOf(p);
        if (c.gone.load(.acquire)) return err.set("app gone");
        var text = data;
        c.lock();
        const k = resolve(c.tree, path);
        c.unlock();
        const kk = k orelse return err.set("gone");
        const op: *abi.Op = switch (kk) {
            .app_ctl => try abi.newOp(gpa, .ctl, 0, "", text),
            .keys => try abi.newOp(gpa, .keys, 0, "", text),
            .menu_file => |name| try abi.newOp(gpa, .menu, 0, name, text),
            .node_file => |nf| blk: {
                if (std.mem.eql(u8, nf.name, "ctl")) break :blk try abi.newOp(gpa, .ctl, nf.node, "", text);
                // A one-line value written with its newline: drop it.
                if (text.len > 0 and text[text.len - 1] == '\n' and std.mem.indexOfScalar(u8, text[0 .. text.len - 1], '\n') == null) text = text[0 .. text.len - 1];
                break :blk try abi.newOp(gpa, .prop, nf.node, nf.name, text);
            },
            // Writing a read-only file (events, version): ignored.
            else => return,
        };
        var ack: abi.Ack = .{};
        c.submit(op, &ack);
        if (ack.err_len > 0) return err.set(ack.err());
    }

    fn line(_: *anyopaque, _: fsmod.ConnId, _: []const u8, _: []const u8, err: *Err) fsmod.Error!void {
        return err.set("unsupported");
    }

    fn create(p: *anyopaque, _: fsmod.ConnId, dir: []const u8, name: []const u8, is_dir: bool, err: *Err) fsmod.Error!fsmod.Entry {
        const c = coreOf(p);
        if (c.gone.load(.acquire)) return err.set("app gone");
        if (is_dir) return err.set("unsupported: the spike has no mkdir");
        const full = try fsmod.join(gpa, dir, name);
        defer gpa.free(full);
        c.lock();
        defer c.unlock();
        const k = resolve(c.tree, full) orelse return err.set("not found");
        return entryOf(k, full);
    }

    fn remove(_: *anyopaque, _: fsmod.ConnId, _: []const u8, err: *Err) fsmod.Error!void {
        return err.set("unsupported: the spike has no remove");
    }
};

/// An `events` subscription read through the core's lock and condition.
const Stream = struct {
    core: *Core,
    sub: *treemod.Sub,
    interrupted: bool = false,

    const vt: fsmod.Stream.VTable = .{ .read = sRead, .interrupt = sInterrupt, .close = sClose };

    fn of(p: *anyopaque) *Stream {
        return @ptrCast(@alignCast(p));
    }

    fn sRead(p: *anyopaque, buf: []u8) error{Interrupted}!usize {
        const st = of(p);
        const c = st.core;
        const s = st.sub;
        c.lock();
        defer c.unlock();
        while (true) {
            if (st.interrupted) {
                st.interrupted = false;
                return error.Interrupted;
            }
            if (s.partial_off < s.partial.len) {
                const k = @min(buf.len, s.partial.len - s.partial_off);
                @memcpy(buf[0..k], s.partial[s.partial_off..][0..k]);
                s.partial_off += k;
                return k;
            }
            if (s.lines.items.len > 0) {
                var n: usize = 0;
                while (s.lines.items.len > 0) {
                    const l = s.lines.items[0];
                    if (n + l.len > buf.len) {
                        if (n == 0) {
                            // A line longer than the read: the rest comes next.
                            @memcpy(buf[0..buf.len], l[0..buf.len]);
                            gpa.free(s.partial);
                            s.partial = l;
                            s.partial_off = buf.len;
                            _ = s.lines.orderedRemove(0);
                            n = buf.len;
                        }
                        break;
                    }
                    @memcpy(buf[n..][0..l.len], l);
                    n += l.len;
                    gpa.free(l);
                    _ = s.lines.orderedRemove(0);
                }
                return n;
            }
            if (s.closed or c.gone.load(.acquire)) return 0;
            c.cond.waitUncancelable(c.io(), &c.mu);
        }
    }

    fn sInterrupt(p: *anyopaque) void {
        const st = of(p);
        st.core.lock();
        defer st.core.unlock();
        st.interrupted = true;
        st.core.cond.broadcast(st.core.io());
    }

    fn sClose(p: *anyopaque) void {
        const st = of(p);
        const c = st.core;
        c.lock();
        c.tree.unsubscribe(st.sub);
        c.tree.unref(st.sub);
        c.unlock();
        gpa.destroy(st);
    }
};
