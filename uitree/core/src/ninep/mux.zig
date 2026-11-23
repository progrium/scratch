//! Mux: one `Fs` with others mounted on names in its root, the way the
//! headless host puts `debug/` beside the tree. A mounted name shadows
//! anything the inner `Fs` has by that name, and is added to the root's
//! listing.

const std = @import("std");
const fsmod = @import("fs.zig");

const Allocator = std.mem.Allocator;
const Fs = fsmod.Fs;
const ConnId = fsmod.ConnId;
const Err = fsmod.Err;

pub const Mount = struct {
    name: []const u8,
    fs: Fs,
};

pub const Mux = struct {
    inner: Fs,
    mounts: []const Mount,

    pub fn fs(m: *Mux) Fs {
        return .{ .ptr = m, .vt = &vt };
    }

    /// The mount `path` is in, and the path inside it.
    fn route(m: *Mux, path: []const u8) struct { Fs, []const u8 } {
        const first = if (std.mem.indexOfScalar(u8, path, '/')) |i| path[0..i] else path;
        for (m.mounts) |mt| if (std.mem.eql(u8, first, mt.name)) {
            const rest = if (path.len > first.len) path[first.len + 1 ..] else "";
            return .{ mt.fs, rest };
        };
        return .{ m.inner, path };
    }

    /// Whether `path` is inside a mount rather than the inner Fs.
    pub fn mounted(m: *Mux, path: []const u8) bool {
        return m.route(path)[0].ptr != m.inner.ptr;
    }

    fn self(p: *anyopaque) *Mux {
        return @ptrCast(@alignCast(p));
    }

    const vt: Fs.VTable = .{
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

    // A mounted Fs gets the inner Fs's connection id: mounts here are
    // stateless about connections (`debug/` is).
    fn connect(p: *anyopaque) ConnId {
        return self(p).inner.connect();
    }
    fn disconnect(p: *anyopaque, c: ConnId) void {
        self(p).inner.disconnect(c);
    }
    fn stat(p: *anyopaque, c: ConnId, path: []const u8) ?fsmod.Entry {
        const r = self(p).route(path);
        return r[0].stat(c, r[1]);
    }
    fn list(p: *anyopaque, c: ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const fsmod.DirEnt {
        const m = self(p);
        const r = m.route(path);
        const got = try r[0].list(c, r[1], arena, err);
        if (path.len != 0) return got;
        var out: std.ArrayList(fsmod.DirEnt) = .empty;
        outer: for (got) |d| {
            for (m.mounts) |mt| if (std.mem.eql(u8, d.name, mt.name)) continue :outer;
            try out.append(arena, d);
        }
        for (m.mounts) |mt| {
            const e = mt.fs.stat(c, "") orelse continue;
            try out.append(arena, .{ .name = mt.name, .entry = e });
        }
        return out.items;
    }
    fn open(p: *anyopaque, c: ConnId, path: []const u8, mode: fsmod.OpenMode, err: *Err) fsmod.Error!fsmod.Opened {
        const r = self(p).route(path);
        return r[0].open(c, r[1], mode, err);
    }
    fn read(p: *anyopaque, c: ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const u8 {
        const r = self(p).route(path);
        return r[0].read(c, r[1], arena, err);
    }
    fn commit(p: *anyopaque, c: ConnId, path: []const u8, token: u64, data: []const u8, err: *Err) fsmod.Error!void {
        const r = self(p).route(path);
        return r[0].commit(c, r[1], token, data, err);
    }
    fn line(p: *anyopaque, c: ConnId, path: []const u8, l: []const u8, err: *Err) fsmod.Error!void {
        const r = self(p).route(path);
        return r[0].line(c, r[1], l, err);
    }
    fn create(p: *anyopaque, c: ConnId, dir: []const u8, name: []const u8, is_dir: bool, err: *Err) fsmod.Error!fsmod.Entry {
        const m = self(p);
        if (dir.len == 0) for (m.mounts) |mt| if (std.mem.eql(u8, name, mt.name)) return err.set("in use");
        const r = m.route(dir);
        return r[0].create(c, r[1], name, is_dir, err);
    }
    fn remove(p: *anyopaque, c: ConnId, path: []const u8, err: *Err) fsmod.Error!void {
        const r = self(p).route(path);
        if (r[1].len == 0 and r[0].ptr != self(p).inner.ptr) return err.set("permission denied");
        return r[0].remove(c, r[1], err);
    }
};

test "a mount shadows and is listed" {
    const t = std.testing;
    var th: std.Io.Threaded = .init(t.allocator, .{});
    defer th.deinit();
    const MemFs = @import("memfs.zig").MemFs;
    var a: MemFs = .init(t.allocator, th.io());
    defer a.deinit();
    var b: MemFs = .init(t.allocator, th.io());
    defer b.deinit();
    try a.put("ctl", "a\n");
    try a.put("debug", "shadowed\n");
    try b.put("inject", "");
    var m: Mux = .{ .inner = a.fs(), .mounts = &.{.{ .name = "debug", .fs = b.fs() }} };
    const f = m.fs();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var err: Err = .{};
    const ents = try f.list(0, "", arena.allocator(), &err);
    try t.expectEqual(@as(usize, 2), ents.len);
    try t.expectEqualStrings("ctl", ents[0].name);
    try t.expectEqualStrings("debug", ents[1].name);
    try t.expectEqual(fsmod.Kind.dir, ents[1].entry.kind);
    try t.expect(f.stat(0, "debug/inject") != null);
    try t.expect(f.stat(0, "debug/ctl") == null);
}
