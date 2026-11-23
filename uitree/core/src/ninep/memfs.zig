//! MemFs: a small in-memory `Fs` for the server's tests. Files hold bytes
//! (a commit replaces them), `events` files are streams fed by `emit`,
//! and a file named `lines` takes `line` writes. A commit of `fail` to any
//! file fails with `bad value: fail`.

const std = @import("std");
const fsmod = @import("fs.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const MemFs = struct {
    gpa: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// path -> contents; a path ending in `/` is a directory.
    files: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    subs: std.ArrayList(*Sub) = .empty,
    lines: std.ArrayList([]u8) = .empty,
    next_conn: fsmod.ConnId = 1,
    disconnects: u32 = 0,
    closed: bool = false,

    pub const Sub = struct {
        fs: *MemFs,
        q: std.ArrayList(u8) = .empty,
        interrupted: bool = false,
        eof: bool = false,
    };

    pub fn init(gpa: Allocator, io: Io) MemFs {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(m: *MemFs) void {
        for (m.files.keys(), m.files.values()) |k, v| {
            m.gpa.free(k);
            m.gpa.free(v);
        }
        m.files.deinit(m.gpa);
        for (m.lines.items) |l| m.gpa.free(l);
        m.lines.deinit(m.gpa);
        m.subs.deinit(m.gpa);
    }

    pub fn put(m: *MemFs, path: []const u8, data: []const u8) !void {
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        try m.putLocked(path, data);
    }

    fn putLocked(m: *MemFs, path: []const u8, data: []const u8) !void {
        const v = try m.gpa.dupe(u8, data);
        const gop = try m.files.getOrPut(m.gpa, path);
        if (gop.found_existing) {
            m.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try m.gpa.dupe(u8, path);
        }
        gop.value_ptr.* = v;
    }

    pub fn get(m: *MemFs, path: []const u8) ?[]const u8 {
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        return m.files.get(path);
    }

    /// Queues `line` on every open events stream.
    pub fn emit(m: *MemFs, ev: []const u8) !void {
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        for (m.subs.items) |s| try s.q.appendSlice(m.gpa, ev);
        m.cond.broadcast(m.io);
    }

    /// Ends every stream with end of file.
    pub fn hangup(m: *MemFs) void {
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        m.closed = true;
        for (m.subs.items) |s| s.eof = true;
        m.cond.broadcast(m.io);
    }

    pub fn fs(m: *MemFs) fsmod.Fs {
        return .{ .ptr = m, .vt = &vt };
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

    fn self(p: *anyopaque) *MemFs {
        return @ptrCast(@alignCast(p));
    }

    fn connect(p: *anyopaque) fsmod.ConnId {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        m.next_conn += 1;
        return m.next_conn - 1;
    }

    fn disconnect(p: *anyopaque, _: fsmod.ConnId) void {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        m.disconnects += 1;
    }

    fn entryOf(m: *MemFs, path: []const u8) ?fsmod.Entry {
        if (path.len == 0) return .{ .kind = .dir, .qid = fsmod.qidOf(""), .perm = 0o777 };
        var buf: [256]u8 = undefined;
        const as_dir = std.fmt.bufPrint(&buf, "{s}/", .{path}) catch return null;
        if (m.files.contains(as_dir)) return .{ .kind = .dir, .qid = fsmod.qidOf(path), .perm = 0o777 };
        const v = m.files.get(path) orelse return null;
        const base = fsmod.baseName(path);
        const kind: fsmod.Kind = if (std.mem.eql(u8, base, "events")) .stream else .file;
        return .{ .kind = kind, .qid = fsmod.qidOf(path), .length = v.len };
    }

    fn stat(p: *anyopaque, _: fsmod.ConnId, path: []const u8) ?fsmod.Entry {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        if (m.closed) return null;
        return m.entryOf(path);
    }

    fn list(p: *anyopaque, _: fsmod.ConnId, path: []const u8, arena: Allocator, err: *fsmod.Err) fsmod.Error![]const fsmod.DirEnt {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        var out: std.ArrayList(fsmod.DirEnt) = .empty;
        const prefix = if (path.len == 0) "" else try std.fmt.allocPrint(arena, "{s}/", .{path});
        for (m.files.keys()) |k| {
            if (!std.mem.startsWith(u8, k, prefix) or k.len == prefix.len) continue;
            var rest = k[prefix.len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |sl| {
                if (sl != rest.len - 1) continue;
                rest = rest[0..sl];
            }
            const full = try fsmod.join(arena, path, rest);
            try out.append(arena, .{ .name = try arena.dupe(u8, rest), .entry = m.entryOf(full) orelse return err.set("gone") });
        }
        return out.items;
    }

    fn open(p: *anyopaque, _: fsmod.ConnId, path: []const u8, mode: fsmod.OpenMode, err: *fsmod.Err) fsmod.Error!fsmod.Opened {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        const e = m.entryOf(path) orelse return err.set("not found");
        if (std.mem.eql(u8, fsmod.baseName(path), "lines")) return .{ .write_mode = .lines };
        if (e.kind == .stream) {
            if (mode.write) return err.set("permission denied");
            const s = try m.gpa.create(Sub);
            s.* = .{ .fs = m, .eof = m.closed };
            try s.q.appendSlice(m.gpa, "resync - - seq=0\n");
            try m.subs.append(m.gpa, s);
            return .{ .stream = .{ .ptr = s, .vt = &stream_vt } };
        }
        return .{};
    }

    fn read(p: *anyopaque, _: fsmod.ConnId, path: []const u8, arena: Allocator, err: *fsmod.Err) fsmod.Error![]const u8 {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        const v = m.files.get(path) orelse return err.set("not found");
        return arena.dupe(u8, v);
    }

    fn commit(p: *anyopaque, _: fsmod.ConnId, path: []const u8, _: u64, data: []const u8, err: *fsmod.Err) fsmod.Error!void {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        if (std.mem.eql(u8, std.mem.trimEnd(u8, data, "\n"), "fail")) return err.set("bad value: fail");
        if (!m.files.contains(path)) return err.set("not found");
        try m.putLocked(path, data);
    }

    fn line(p: *anyopaque, _: fsmod.ConnId, _: []const u8, l: []const u8, err: *fsmod.Err) fsmod.Error!void {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        if (std.mem.eql(u8, l, "fail")) return err.set("bad syntax: fail");
        try m.lines.append(m.gpa, try m.gpa.dupe(u8, l));
    }

    fn create(p: *anyopaque, _: fsmod.ConnId, dir: []const u8, name: []const u8, is_dir: bool, err: *fsmod.Err) fsmod.Error!fsmod.Entry {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        var buf: [256]u8 = undefined;
        const full = if (dir.len == 0) name else std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return err.set("too large");
        if (m.entryOf(full) != null) return err.set("in use");
        if (is_dir) {
            var b2: [260]u8 = undefined;
            try m.putLocked(std.fmt.bufPrint(&b2, "{s}/", .{full}) catch return err.set("too large"), "");
        } else try m.putLocked(full, "");
        return m.entryOf(full).?;
    }

    fn remove(p: *anyopaque, _: fsmod.ConnId, path: []const u8, err: *fsmod.Err) fsmod.Error!void {
        const m = self(p);
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        const kv = m.files.fetchSwapRemove(path) orelse return err.set("not found");
        m.gpa.free(kv.key);
        m.gpa.free(kv.value);
    }

    const stream_vt: fsmod.Stream.VTable = .{ .read = sRead, .interrupt = sInterrupt, .close = sClose };

    fn sub(p: *anyopaque) *Sub {
        return @ptrCast(@alignCast(p));
    }

    fn sRead(p: *anyopaque, buf: []u8) error{Interrupted}!usize {
        const s = sub(p);
        const m = s.fs;
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        while (true) {
            if (s.interrupted) {
                s.interrupted = false;
                return error.Interrupted;
            }
            if (s.q.items.len > 0) {
                // Whole lines that fit, or part of a long first line.
                var n: usize = 0;
                while (std.mem.indexOfScalarPos(u8, s.q.items, n, '\n')) |nl| {
                    if (nl + 1 > buf.len) break;
                    n = nl + 1;
                }
                if (n == 0) n = @min(buf.len, s.q.items.len);
                @memcpy(buf[0..n], s.q.items[0..n]);
                s.q.replaceRangeAssumeCapacity(0, n, &.{});
                return n;
            }
            if (s.eof) return 0;
            m.cond.waitUncancelable(m.io, &m.mu);
        }
    }

    fn sInterrupt(p: *anyopaque) void {
        const s = sub(p);
        const m = s.fs;
        m.mu.lockUncancelable(m.io);
        defer m.mu.unlock(m.io);
        s.interrupted = true;
        m.cond.broadcast(m.io);
    }

    fn sClose(p: *anyopaque) void {
        const s = sub(p);
        const m = s.fs;
        m.mu.lockUncancelable(m.io);
        for (m.subs.items, 0..) |x, i| if (x == s) {
            _ = m.subs.swapRemove(i);
            break;
        };
        m.mu.unlock(m.io);
        s.q.deinit(m.gpa);
        m.gpa.destroy(s);
    }
};
