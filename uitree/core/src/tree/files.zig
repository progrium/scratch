//! files: file handles, `$ui/file/ID/` (transfer.md § Host files).
//!
//! A file from the host reaches the client only as a handle: a directory
//! that serves the file's name, info and bytes, never its host path.
//! Handles live here, outside `State`, because they are not tree state:
//! they outlive the drag that made them, their bytes are streamed from
//! the host file at each read (nothing needs to fit in memory), and 9P
//! threads read them without the owner thread.
//!
//! A handle is backed by a host path (a drop or a picker in a renderer)
//! or by bytes held here (`/debug/inject drag ... file=NAME`, and a
//! renderer whose platform hands it bytes rather than a path). Handles
//! from drops are read-only. A handle lives until the client writes
//! `release` to its `ctl`, its drop is refused, or the app quits.
//!
//! Every function may be called from any thread.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Backing = union(enum) {
    /// A host path, as the renderer gave it. Never shown to the client.
    host: []u8,
    /// Bytes held in memory.
    mem: []u8,
};

pub const Handle = struct {
    rc: std.atomic.Value(u32) = .init(1),
    id: u64,
    /// A file name, never a path.
    name: []u8,
    backing: Backing,
    rw: bool = false,
    /// Set (under `Files.mu`) when the handle is released; streams end.
    released: bool = false,
    /// Set (under `Files.mu`) when a read found the host file gone; the
    /// handle's `events` get one `gone` line.
    lost: bool = false,

    pub fn ref(h: *Handle) *Handle {
        _ = h.rc.fetchAdd(1, .monotonic);
        return h;
    }

    pub fn unref(h: *Handle, gpa: Allocator) void {
        if (h.rc.fetchSub(1, .acq_rel) != 1) return;
        gpa.free(h.name);
        switch (h.backing) {
            inline else => |b| gpa.free(b),
        }
        gpa.destroy(h);
    }

    /// `file/ID`, the way an offer's `item/N/file` names it.
    pub fn ref_path(h: *const Handle, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "file/{d}", .{h.id}) catch unreachable;
    }
};

/// What a handle's file (or a file under its `dir/`) is.
pub const Info = struct {
    dir: bool,
    size: u64,
    /// Seconds since 1970.
    mtime: i64,
};

pub const Ent = struct {
    name: []const u8,
    info: Info,
};

pub const Error = error{ NotFound, PermissionDenied, OutOfMemory, Io };

pub const Files = struct {
    gpa: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    next: u64 = 1,
    items: std.ArrayList(*Handle) = .empty,

    pub fn init(gpa: Allocator, io: Io) Files {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(f: *Files) void {
        for (f.items.items) |h| h.unref(f.gpa);
        f.items.deinit(f.gpa);
    }

    fn lock(f: *Files) void {
        f.mu.lockUncancelable(f.io);
    }
    fn unlock(f: *Files) void {
        f.mu.unlock(f.io);
    }

    fn add(f: *Files, name: []const u8, backing: Backing) Allocator.Error!*Handle {
        const h = try f.gpa.create(Handle);
        errdefer f.gpa.destroy(h);
        const nm = try f.gpa.dupe(u8, baseName(name));
        errdefer f.gpa.free(nm);
        f.lock();
        defer f.unlock();
        try f.items.ensureUnusedCapacity(f.gpa, 1);
        h.* = .{ .id = f.next, .name = nm, .backing = backing };
        f.next += 1;
        f.items.appendAssumeCapacity(h);
        return h;
    }

    /// A read-only handle on host file or directory `path`, which must
    /// exist. Its name is the path's last element.
    pub fn addHost(f: *Files, path: []const u8) Error!u64 {
        _ = try hostInfo(f.io, path);
        const p = try f.gpa.dupe(u8, path);
        errdefer f.gpa.free(p);
        const h = try f.add(path, .{ .host = p });
        return h.id;
    }

    /// A read-only handle holding `bytes`, named `name`.
    pub fn addMem(f: *Files, name: []const u8, bytes: []const u8) Error!u64 {
        if (baseName(name).len == 0) return error.NotFound;
        const b = try f.gpa.dupe(u8, bytes);
        errdefer f.gpa.free(b);
        const h = try f.add(name, .{ .mem = b });
        return h.id;
    }

    /// The handle with `id`, referenced; `unref` it when done.
    pub fn get(f: *Files, id: u64) ?*Handle {
        f.lock();
        defer f.unlock();
        for (f.items.items) |h| if (h.id == id) return h.ref();
        return null;
    }

    /// The handle named by an ID word (`3`).
    pub fn getWord(f: *Files, word: []const u8) ?*Handle {
        const id = std.fmt.parseInt(u64, word, 10) catch return null;
        return f.get(id);
    }

    /// Ends handle `id`: it leaves `$ui/file/` and its `events` end. False
    /// if there was none.
    pub fn release(f: *Files, id: u64) bool {
        f.lock();
        const h = for (f.items.items, 0..) |h, i| {
            if (h.id == id) {
                _ = f.items.orderedRemove(i);
                break h;
            }
        } else {
            f.unlock();
            return false;
        };
        h.released = true;
        f.cond.broadcast(f.io);
        f.unlock();
        h.unref(f.gpa);
        return true;
    }

    /// The live handles' IDs, in creation order, in `arena`.
    pub fn ids(f: *Files, arena: Allocator) Allocator.Error![]u64 {
        f.lock();
        defer f.unlock();
        const out = try arena.alloc(u64, f.items.items.len);
        for (f.items.items, out) |h, *o| o.* = h.id;
        return out;
    }

    /// Notes that `h`'s host file has gone; its `events` say so once.
    fn lose(f: *Files, h: *Handle) void {
        f.lock();
        defer f.unlock();
        if (h.lost) return;
        h.lost = true;
        f.cond.broadcast(f.io);
    }

    // ------------------------------------------------------------ reads

    /// What the handle's file, or `sub` under its `dir/` (`a/b.txt`), is.
    pub fn info(f: *Files, h: *Handle, sub: []const u8) Error!Info {
        switch (h.backing) {
            .mem => |b| {
                if (sub.len > 0) return error.NotFound;
                return .{ .dir = false, .size = b.len, .mtime = 0 };
            },
            .host => |p| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const full = try subPath(&buf, p, sub);
                return hostInfo(f.io, full) catch |e| {
                    if (e == error.NotFound and sub.len == 0) f.lose(h);
                    return e;
                };
            },
        }
    }

    /// The handle's `info` file: `size=N mtime=T [dir] [rw]`.
    pub fn infoLine(f: *Files, h: *Handle, arena: Allocator) Error![]const u8 {
        const in = try f.info(h, "");
        return std.fmt.allocPrint(arena, "size={d} mtime={d}{s}{s}\n", .{
            in.size,
            in.mtime,
            if (in.dir) " dir" else "",
            if (h.rw) " rw" else "",
        });
    }

    /// The entries of the handle's directory, or of `sub` under it, by
    /// name. Only for host directories.
    pub fn list(f: *Files, h: *Handle, sub: []const u8, arena: Allocator) Error![]Ent {
        const p = switch (h.backing) {
            .mem => return error.NotFound,
            .host => |p| p,
        };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = try subPath(&buf, p, sub);
        const io = f.io;
        var d = Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |e| return mapErr(e);
        defer d.close(io);
        var out: std.ArrayList(Ent) = .empty;
        var it = d.iterate();
        while (it.next(io) catch |e| return mapErr(e)) |e| {
            const st = d.statFile(io, e.name, .{}) catch continue;
            try out.append(arena, .{ .name = try arena.dupe(u8, e.name), .info = infoOf(st) });
        }
        std.mem.sort(Ent, out.items, {}, struct {
            fn lt(_: void, a: Ent, b: Ent) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        return out.items;
    }

    /// Opens the bytes of the handle's file (`sub` empty) or of a file
    /// under its `dir/`, for reads at any offset.
    pub fn openData(f: *Files, h: *Handle, sub: []const u8) Error!*Reader {
        const r = try f.gpa.create(Reader);
        errdefer f.gpa.destroy(r);
        r.* = .{ .files = f, .h = h.ref(), .file = null };
        errdefer h.unref(f.gpa);
        switch (h.backing) {
            .mem => if (sub.len > 0) return error.NotFound,
            .host => |p| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const full = try subPath(&buf, p, sub);
                const in = hostInfo(f.io, full) catch |e| {
                    if (e == error.NotFound and sub.len == 0) f.lose(h);
                    return e;
                };
                if (in.dir) return error.NotFound;
                r.file = Io.Dir.cwd().openFile(f.io, full, .{}) catch |e| return mapErr(e);
            },
        }
        return r;
    }

    /// Opens the handle's `events`: blocks until there is something to
    /// say (`gone - file/ID`), and ends when the handle is released.
    pub fn openEvents(f: *Files, h: *Handle) Allocator.Error!*Events {
        const e = try f.gpa.create(Events);
        e.* = .{ .files = f, .h = h.ref() };
        return e;
    }
};

/// An open `data` file.
pub const Reader = struct {
    files: *Files,
    h: *Handle,
    file: ?Io.File,

    /// Up to `buf.len` bytes at `off`; 0 at the end.
    pub fn pread(r: *Reader, off: u64, buf: []u8) Error!usize {
        if (r.file) |file| {
            return file.readPositional(r.files.io, &.{buf}, off) catch error.Io;
        }
        const b = r.h.backing.mem;
        if (off >= b.len) return 0;
        const n = @min(buf.len, b.len - @as(usize, @intCast(off)));
        @memcpy(buf[0..n], b[@intCast(off)..][0..n]);
        return n;
    }

    pub fn close(r: *Reader) void {
        const f = r.files;
        if (r.file) |file| file.close(f.io);
        r.h.unref(f.gpa);
        f.gpa.destroy(r);
    }
};

/// An open `events` file of one handle.
pub const Events = struct {
    files: *Files,
    h: *Handle,
    said_gone: bool = false,
    interrupted: bool = false,

    /// Blocks for a line; 0 once the handle is released.
    pub fn read(e: *Events, buf: []u8) error{Interrupted}!usize {
        const f = e.files;
        f.lock();
        defer f.unlock();
        while (true) {
            if (e.h.lost and !e.said_gone) {
                var tmp: [64]u8 = undefined;
                const line = std.fmt.bufPrint(&tmp, "gone - file/{d}\n", .{e.h.id}) catch unreachable;
                if (buf.len < line.len) return 0;
                @memcpy(buf[0..line.len], line);
                e.said_gone = true;
                return line.len;
            }
            if (e.h.released) return 0;
            if (e.interrupted) {
                e.interrupted = false;
                return error.Interrupted;
            }
            f.cond.waitUncancelable(f.io, &f.mu);
        }
    }

    pub fn interrupt(e: *Events) void {
        const f = e.files;
        f.lock();
        defer f.unlock();
        e.interrupted = true;
        f.cond.broadcast(f.io);
    }

    pub fn close(e: *Events) void {
        const f = e.files;
        e.h.unref(f.gpa);
        f.gpa.destroy(e);
    }
};

/// The last element of a host path, `/` and `\` both separating.
pub fn baseName(p: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/\\");
    const i = std.mem.lastIndexOfAny(u8, t, "/\\") orelse return t;
    return t[i + 1 ..];
}

/// `base/sub`, refusing `..` and empty elements in `sub` (a 9P walk never
/// has them, but a handle must not reach outside its directory).
fn subPath(buf: []u8, base: []const u8, sub: []const u8) Error![]const u8 {
    if (sub.len == 0) return base;
    var it = std.mem.splitScalar(u8, sub, '/');
    while (it.next()) |el| {
        if (el.len == 0 or std.mem.eql(u8, el, ".") or std.mem.eql(u8, el, "..")) return error.NotFound;
        if (std.mem.indexOfScalar(u8, el, '\\') != null) return error.NotFound;
    }
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), sub }) catch error.NotFound;
}

fn infoOf(st: Io.File.Stat) Info {
    return .{
        .dir = st.kind == .directory,
        .size = if (st.kind == .directory) 0 else st.size,
        .mtime = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s)),
    };
}

fn hostInfo(io: Io, path: []const u8) Error!Info {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |e| return mapErr(e);
    return infoOf(st);
}

fn mapErr(e: anyerror) Error {
    return switch (e) {
        error.FileNotFound, error.NotDir, error.NameTooLong, error.BadPathName => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.PermissionDenied,
        error.OutOfMemory, error.SystemResources => error.OutOfMemory,
        else => error.Io,
    };
}

test "memory handles: name, info, bytes, release" {
    const t = std.testing;
    var th: Io.Threaded = .init(t.allocator, .{});
    defer th.deinit();
    var f: Files = .init(t.allocator, th.io());
    defer f.deinit();
    const id = try f.addMem("notes/a.txt", "hello");
    const h = f.get(id).?;
    defer h.unref(t.allocator);
    try t.expectEqualStrings("a.txt", h.name);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("size=5 mtime=0\n", try f.infoLine(h, arena.allocator()));
    const r = try f.openData(h, "");
    defer r.close();
    var buf: [3]u8 = undefined;
    try t.expectEqual(@as(usize, 3), try r.pread(0, &buf));
    try t.expectEqualStrings("hel", &buf);
    try t.expectEqual(@as(usize, 2), try r.pread(3, &buf));
    try t.expectEqual(@as(usize, 0), try r.pread(5, &buf));
    try t.expectError(error.NotFound, f.openData(h, "x"));
    // The open reader keeps the bytes after a release.
    try t.expect(f.release(id));
    try t.expect(!f.release(id));
    try t.expect(f.get(id) == null);
    try t.expectEqual(@as(usize, 3), try r.pread(1, &buf));
}

test "host handles: a file and a directory, streamed, never outside it" {
    const t = std.testing;
    var th: Io.Threaded = .init(t.allocator, .{});
    defer th.deinit();
    const io = th.io();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "drop/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "drop/report.csv", .data = "a,b\n1,2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "drop/sub/x", .data = "x" });
    var pb: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/drop", .{tmp.sub_path});

    var f: Files = .init(t.allocator, io);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fb: [300]u8 = undefined;
    const fid = try f.addHost(try std.fmt.bufPrint(&fb, "{s}/report.csv", .{base}));
    const fh = f.get(fid).?;
    defer fh.unref(t.allocator);
    try t.expectEqualStrings("report.csv", fh.name);
    try t.expect(std.mem.startsWith(u8, try f.infoLine(fh, a), "size=8 mtime="));
    const r = try f.openData(fh, "");
    var buf: [4]u8 = undefined;
    try t.expectEqual(@as(usize, 4), try r.pread(4, &buf));
    try t.expectEqualStrings("1,2\n", &buf);
    r.close();

    const did = try f.addHost(base);
    const dh = f.get(did).?;
    defer dh.unref(t.allocator);
    try t.expectEqualStrings("drop", dh.name);
    try t.expect(std.mem.endsWith(u8, try f.infoLine(dh, a), " dir\n"));
    const ents = try f.list(dh, "", a);
    try t.expectEqual(@as(usize, 2), ents.len);
    try t.expectEqualStrings("report.csv", ents[0].name);
    try t.expectEqualStrings("sub", ents[1].name);
    try t.expect(ents[1].info.dir);
    const r2 = try f.openData(dh, "sub/x");
    try t.expectEqual(@as(usize, 1), try r2.pread(0, &buf));
    r2.close();
    try t.expectError(error.NotFound, f.openData(dh, "../report.csv"));
    try t.expectError(error.NotFound, f.openData(dh, "sub"));
    try t.expectError(error.NotFound, f.addHost("/no/such/file"));
}

test "events: gone once the host file goes, end at release" {
    const t = std.testing;
    var th: Io.Threaded = .init(t.allocator, .{});
    defer th.deinit();
    const io = th.io();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
    var pb: [256]u8 = undefined;
    const p = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/f", .{tmp.sub_path});
    var f: Files = .init(t.allocator, io);
    defer f.deinit();
    const id = try f.addHost(p);
    const h = f.get(id).?;
    defer h.unref(t.allocator);
    const ev = try f.openEvents(h);
    defer ev.close();
    try tmp.dir.deleteFile(io, "f");
    try t.expectError(error.NotFound, f.info(h, ""));
    var buf: [64]u8 = undefined;
    const n = try ev.read(&buf);
    try t.expectEqualStrings(try std.fmt.bufPrint(&pb, "gone - file/{d}\n", .{id}), buf[0..n]);
    _ = f.release(id);
    try t.expectEqual(@as(usize, 0), try ev.read(&buf));
}
