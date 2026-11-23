//! The 9P2000 server for `$ui`, on hyper9's `dotl/wire.zig` framing.
//!
//! One reader thread per connection decodes frames and answers what can't
//! block (version, attach, walk, open, stat, file and directory reads,
//! buffered writes) inline. Anything that waits on the owner thread or on
//! an event runs on a thread of its own: a stream read (`events`,
//! `trace`), a clunk that commits a buffered write, a `lines` write, a
//! create, a remove. Tflush interrupts a stream read and waits for any
//! other request to finish before answering, so the client never sees a
//! reply to a flushed read.
//!
//! What a path is, and every protocol error, comes from `Fs` (fs.zig).
//! The server only decides 9P's own failures (an unknown fid, a read on a
//! fid that isn't open), and those are never core.md phrases.

const std = @import("std");
const wire = @import("wire.zig");
const Dir = @import("dir.zig").Dir;
const fsmod = @import("fs.zig");
const transport = @import("transport.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const p9 = wire.p9;
const Fs = fsmod.Fs;
const Entry = fsmod.Entry;
const Err = fsmod.Err;

/// The largest message we accept: one 64 KiB `ctl` write (core.md §
/// Limits) plus the header, with room to spare.
pub const max_msize: u32 = (128 << 10) + wire.io_header;

/// A ctl write this long or longer is a piece of a bigger one (`cat`).
pub const ctl_piece = 8192;
/// The most a buffered write may grow to before it fails `too large`: a
/// data file is at least 16 MiB (core.md § Limits).
pub const max_write: usize = 32 << 20;

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    fs: Fs,
    /// Connections being served.
    live: std.atomic.Value(u32) = .init(0),
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    conns: std.ArrayList(*Conn) = .empty,
    /// Called for every failed write, create or remove, with the verb
    /// (`write`, `mkdir`, `create`, `remove`), the path and the error text:
    /// core.md § Errors says they're loud. Any thread.
    on_error: ?OnError = null,

    pub const OnError = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, verb: []const u8, path: []const u8, text: []const u8) void,
    };

    fn loud(s: *Server, verb: []const u8, path: []const u8, text: []const u8) void {
        if (s.on_error) |o| o.func(o.ctx, verb, path, text);
    }

    pub fn init(gpa: Allocator, io: Io, fs: Fs) Server {
        return .{ .gpa = gpa, .io = io, .fs = fs };
    }

    /// Serves `t` on a thread of its own until the peer hangs up. Takes
    /// ownership of `t` (closes it when done), even on error.
    pub fn serve(s: *Server, t: transport.Conn) !void {
        const cn = s.gpa.create(Conn) catch |e| {
            t.close();
            return e;
        };
        cn.* = .{ .srv = s, .t = t };
        s.mu.lockUncancelable(s.io);
        s.conns.append(s.gpa, cn) catch |e| {
            s.mu.unlock(s.io);
            t.close();
            s.gpa.destroy(cn);
            return e;
        };
        _ = s.live.fetchAdd(1, .acq_rel);
        s.mu.unlock(s.io);
        const th = std.Thread.spawn(.{}, Conn.run, .{cn}) catch |e| {
            cn.unref();
            return e;
        };
        th.detach();
    }

    /// Hangs up every connection (their reader threads see end of file)
    /// and waits for them to finish. The `Fs` must already have ended its
    /// streams (or be about to), or a blocked read keeps a connection.
    pub fn shutdown(s: *Server) void {
        s.mu.lockUncancelable(s.io);
        for (s.conns.items) |cn| cn.t.shutdown();
        while (s.live.load(.acquire) != 0) s.cond.waitUncancelable(s.io, &s.mu);
        s.mu.unlock(s.io);
    }

    pub fn deinit(s: *Server) void {
        s.shutdown();
        s.conns.deinit(s.gpa);
    }

    fn connDone(s: *Server, cn: *Conn) void {
        s.mu.lockUncancelable(s.io);
        for (s.conns.items, 0..) |c, i| if (c == cn) {
            _ = s.conns.swapRemove(i);
            break;
        };
        _ = s.live.fetchSub(1, .acq_rel);
        s.cond.broadcast(s.io);
        s.mu.unlock(s.io);
    }
};

const Fid = struct {
    path: []u8,
    entry: Entry,
    refs: u32 = 1,
    /// Serializes requests on this fid (writes stay in order, one stream
    /// read at a time).
    mu: Io.Mutex = .init,
    open: bool = false,
    mode: fsmod.OpenMode = .{ .read = false, .write = false },
    /// A readable file's contents at open, or a directory's packed stats.
    data: []u8 = &.{},
    /// Buffered writes (`at_close`), or a partial line (`lines`).
    wbuf: std.ArrayList(u8) = .empty,
    wrote: bool = false,
    write_mode: fsmod.WriteMode = .at_close,
    token: u64 = 0,
    stream: ?fsmod.Stream = null,
    random: ?fsmod.Random = null,
};

const Pending = struct {
    tag: u16,
    /// The fid's stream, if this is a stream read Tflush may interrupt.
    stream: ?fsmod.Stream = null,
    flushed: bool = false,
    done: bool = false,
};

const Conn = struct {
    srv: *Server,
    t: transport.Conn,
    id: fsmod.ConnId = 0,
    attached: bool = false,
    msize: u32 = 8192 + wire.io_header,
    /// Guards fids, pending, refs, and the write side of `t`.
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    wmu: Io.Mutex = .init,
    fids: std.AutoHashMapUnmanaged(u32, *Fid) = .empty,
    pending: std.ArrayList(*Pending) = .empty,
    /// The reader thread holds one; each worker thread holds one.
    refs: u32 = 1,

    fn io(cn: *Conn) Io {
        return cn.srv.io;
    }
    fn gpa(cn: *Conn) Allocator {
        return cn.srv.gpa;
    }
    fn lock(cn: *Conn) void {
        cn.mu.lockUncancelable(cn.io());
    }
    fn unlock(cn: *Conn) void {
        cn.mu.unlock(cn.io());
    }

    fn ref(cn: *Conn) void {
        cn.lock();
        cn.refs += 1;
        cn.unlock();
    }

    fn unref(cn: *Conn) void {
        cn.lock();
        cn.refs -= 1;
        const last = cn.refs == 0;
        cn.unlock();
        if (!last) return;
        var it = cn.fids.iterator();
        while (it.next()) |e| cn.dropFid(e.value_ptr.*);
        cn.fids.deinit(cn.gpa());
        cn.pending.deinit(cn.gpa());
        if (cn.attached) cn.srv.fs.disconnect(cn.id);
        cn.t.close();
        const srv = cn.srv;
        srv.gpa.destroy(cn);
        srv.connDone(cn);
    }

    // -----------------------------------------------------------------
    // Fids

    fn getFid(cn: *Conn, fid: u32) ?*Fid {
        cn.lock();
        defer cn.unlock();
        const f = cn.fids.get(fid) orelse return null;
        f.refs += 1;
        return f;
    }

    fn putFid(cn: *Conn, f: *Fid) void {
        cn.lock();
        f.refs -= 1;
        const last = f.refs == 0;
        cn.unlock();
        if (last) cn.freeFid(f);
    }

    /// Removes `fid` from the table; the caller holds the returned ref.
    fn takeFid(cn: *Conn, fid: u32) ?*Fid {
        cn.lock();
        defer cn.unlock();
        const kv = cn.fids.fetchRemove(fid) orelse return null;
        return kv.value;
    }

    fn addFid(cn: *Conn, fid: u32, path: []const u8, entry: Entry) !bool {
        const f = try cn.gpa().create(Fid);
        f.* = .{ .path = try cn.gpa().dupe(u8, path), .entry = entry };
        cn.lock();
        defer cn.unlock();
        const gop = try cn.fids.getOrPut(cn.gpa(), fid);
        if (gop.found_existing) {
            cn.freeFid(f);
            return false;
        }
        gop.value_ptr.* = f;
        return true;
    }

    /// Drops the table's reference (on hangup).
    fn dropFid(cn: *Conn, f: *Fid) void {
        if (f.stream) |s| s.interrupt();
        f.refs -= 1;
        if (f.refs == 0) cn.freeFid(f);
    }

    fn freeFid(cn: *Conn, f: *Fid) void {
        if (f.stream) |s| s.close();
        if (f.random) |r| r.close();
        cn.gpa().free(f.path);
        cn.gpa().free(f.data);
        f.wbuf.deinit(cn.gpa());
        cn.gpa().destroy(f);
    }

    // -----------------------------------------------------------------
    // Replies

    fn send(cn: *Conn, frame: []const u8) void {
        cn.wmu.lockUncancelable(cn.io());
        defer cn.wmu.unlock(cn.io());
        cn.t.writeAll(frame) catch {};
    }

    fn reply(cn: *Conn, tag: u16, msg: anytype) void {
        var buf: [256]u8 = undefined;
        const frame = wire.encode(&buf, tag, msg, null) catch return;
        cn.send(frame);
    }

    fn fail(cn: *Conn, tag: u16, text: []const u8) void {
        cn.reply(tag, p9.Rerror{ .ename = text[0..@min(text.len, 200)] });
    }

    /// Sends an Rread with `data`, which may be up to msize.
    fn replyRead(cn: *Conn, tag: u16, data: []const u8) void {
        const buf = cn.gpa().alloc(u8, wire.header_size + 4 + data.len) catch return cn.fail(tag, "out of memory");
        defer cn.gpa().free(buf);
        const frame = wire.encode(buf, tag, p9.Rread{ .data = .{ .bytes = data } }, null) catch return;
        cn.send(frame);
    }

    // -----------------------------------------------------------------
    // Pending requests, for Tflush

    fn addPending(cn: *Conn, tag: u16, stream: ?fsmod.Stream) !*Pending {
        const p = try cn.gpa().create(Pending);
        p.* = .{ .tag = tag, .stream = stream };
        cn.lock();
        defer cn.unlock();
        cn.pending.append(cn.gpa(), p) catch |e| {
            cn.gpa().destroy(p);
            return e;
        };
        return p;
    }

    /// Marks `p` done and removes it. Returns whether it was flushed, in
    /// which case its reply must not be sent if it was interrupted.
    fn endPending(cn: *Conn, p: *Pending) bool {
        cn.lock();
        defer cn.unlock();
        for (cn.pending.items, 0..) |q, i| if (q == p) {
            _ = cn.pending.swapRemove(i);
            break;
        };
        p.done = true;
        const flushed = p.flushed;
        cn.cond.broadcast(cn.io());
        // A flusher waiting on it frees it.
        if (!flushed) cn.gpa().destroy(p);
        return flushed;
    }

    fn flush(cn: *Conn, tag: u16, old: u16) void {
        cn.lock();
        var found: ?*Pending = null;
        for (cn.pending.items) |p| if (p.tag == old and !p.flushed) {
            found = p;
            break;
        };
        if (found) |p| {
            p.flushed = true;
            if (p.stream) |s| s.interrupt();
            while (!p.done) cn.cond.waitUncancelable(cn.io(), &cn.mu);
            cn.gpa().destroy(p);
        }
        cn.unlock();
        cn.reply(tag, p9.Rflush{});
    }

    // -----------------------------------------------------------------
    // The reader

    fn run(cn: *Conn) void {
        defer cn.unref();
        const buf = cn.gpa().alloc(u8, max_msize) catch return;
        defer cn.gpa().free(buf);
        var have: usize = 0;
        while (true) {
            // Frame by frame: read the header, then the rest.
            while (have < 4) {
                const n = cn.t.read(buf[have..]) catch return;
                if (n == 0) return;
                have += n;
            }
            const size = std.mem.readInt(u32, buf[0..4], .little);
            if (size < wire.header_size or size > cn.msize and size > max_msize) return;
            if (size > buf.len) return;
            while (have < size) {
                const n = cn.t.read(buf[have..]) catch return;
                if (n == 0) return;
                have += n;
            }
            cn.handle(buf[0..size]);
            std.mem.copyForwards(u8, buf[0 .. have - size], buf[size..have]);
            have -= size;
        }
    }

    fn handle(cn: *Conn, frame: []const u8) void {
        const tag = std.mem.readInt(u16, frame[5..7], .little);
        const f = wire.decode(p9.T, frame, max_msize, false) catch {
            return cn.fail(tag, "bad message");
        };
        cn.dispatch(f.tag, f.msg) catch |e| switch (e) {
            error.OutOfMemory => cn.fail(tag, "out of memory"),
        };
    }

    fn dispatch(cn: *Conn, tag: u16, msg: p9.T) error{OutOfMemory}!void {
        const fs = cn.srv.fs;
        switch (msg) {
            .Tversion => |m| {
                // A new session: forget the old one's fids.
                cn.lock();
                var it = cn.fids.iterator();
                while (it.next()) |e| cn.dropFid(e.value_ptr.*);
                cn.fids.clearRetainingCapacity();
                cn.unlock();
                cn.msize = @max(@min(m.msize, max_msize), 256);
                const ok = std.mem.startsWith(u8, m.version, "9P2000");
                cn.reply(tag, p9.Rversion{ .msize = cn.msize, .version = if (ok) wire.version_9p else "unknown" });
            },
            .Tauth => cn.fail(tag, "no authentication required"),
            .Tattach => |m| {
                if (!cn.attached) {
                    cn.id = fs.connect();
                    cn.attached = true;
                }
                const e = fs.stat(cn.id, "") orelse return cn.fail(tag, "app gone");
                if (!try cn.addFid(m.fid, "", e)) return cn.fail(tag, "fid in use");
                cn.reply(tag, p9.Rattach{ .qid = qidOf(e) });
            },
            .Tflush => |m| cn.flush(tag, m.oldtag),
            .Twalk => |m| try cn.walk(tag, m.fid, m.newfid, m.wnames.slice()),
            .Topen => |m| try cn.openFid(tag, m.fid, m.mode),
            .Tcreate => |m| {
                if (m.name.len == 0 or std.mem.eql(u8, m.name, ".") or std.mem.eql(u8, m.name, "..") or std.mem.indexOfScalar(u8, m.name, '/') != null)
                    return cn.fail(tag, "bad value: name");
                const f = cn.getFid(m.fid) orelse return cn.fail(tag, "unknown fid");
                if (f.open or f.entry.kind != .dir) {
                    cn.putFid(f);
                    return cn.fail(tag, "not a directory");
                }
                const name = try cn.gpa().dupe(u8, m.name);
                cn.spawn(tag, null, workCreate, .{ cn, tag, f, name, m.perm, m.mode });
            },
            .Tread => |m| try cn.readFid(tag, m.fid, m.offset, m.count),
            .Twrite => |m| try cn.writeFid(tag, m.fid, m.offset, m.data.bytes),
            .Tclunk => |m| {
                const f = cn.takeFid(m.fid) orelse return cn.fail(tag, "unknown fid");
                if (f.stream) |s| s.interrupt();
                if (pendingAtClose(f)) {
                    cn.spawn(tag, null, workCommit, .{ cn, tag, f, false });
                    return;
                }
                cn.putFid(f);
                cn.reply(tag, p9.Rclunk{});
            },
            .Tremove => |m| {
                const f = cn.takeFid(m.fid) orelse return cn.fail(tag, "unknown fid");
                if (f.stream) |s| s.interrupt();
                cn.spawn(tag, null, workCommit, .{ cn, tag, f, true });
            },
            .Tstat => |m| {
                const f = cn.getFid(m.fid) orelse return cn.fail(tag, "unknown fid");
                defer cn.putFid(f);
                const e = fs.stat(cn.id, f.path) orelse return cn.fail(tag, "gone");
                var sb: [512]u8 = undefined;
                const st = packDir(&sb, fsmod.baseName(f.path), e) orelse return cn.fail(tag, "name too long");
                var out: [600]u8 = undefined;
                const frame = wire.encode(&out, tag, p9.Rstat{ .stat = .{ .bytes = st } }, null) catch return cn.fail(tag, "name too long");
                cn.send(frame);
            },
            // Truncating and renaming aren't how the tree changes; accept
            // a wstat that changes nothing else so `>file` and touch work.
            .Twstat => |m| {
                const f = cn.getFid(m.fid) orelse return cn.fail(tag, "unknown fid");
                cn.putFid(f);
                if (Dir.parse(m.stat.bytes)) |pd| {
                    const d = pd[0];
                    if (d.name.len != 0 and !std.mem.eql(u8, d.name, fsmod.baseName(f.path))) return cn.fail(tag, "permission denied: rename");
                }
                cn.reply(tag, p9.Rwstat{});
            },
        }
    }

    /// Runs `func(args)` on its own thread, holding a conn ref, as a
    /// pending request `tag` (so Tflush waits for it).
    fn spawn(cn: *Conn, tag: u16, stream: ?fsmod.Stream, comptime func: anytype, args: anytype) void {
        const p = cn.addPending(tag, stream) catch return cn.fail(tag, "out of memory");
        cn.ref();
        const Args = @TypeOf(args);
        const Wrap = struct {
            fn go(c: *Conn, pp: *Pending, a: Args) void {
                defer c.unref();
                @call(.auto, func, a ++ .{pp});
            }
        };
        const th = std.Thread.spawn(.{}, Wrap.go, .{ cn, p, args }) catch {
            _ = cn.endPending(p);
            cn.unref();
            return cn.fail(tag, "out of memory");
        };
        th.detach();
    }

    fn walk(cn: *Conn, tag: u16, fid: u32, newfid: u32, names: []const []const u8) !void {
        const fs = cn.srv.fs;
        const from = cn.getFid(fid) orelse return cn.fail(tag, "unknown fid");
        defer cn.putFid(from);
        if (from.open) return cn.fail(tag, "fid open");
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(cn.gpa());
        try path.appendSlice(cn.gpa(), from.path);
        var qids: [wire.max_welem]wire.Qid = undefined;
        var entry = from.entry;
        var got: usize = 0;
        var why: []const u8 = "not found";
        for (names) |name| {
            if (entry.kind != .dir) {
                why = "not a directory";
                break;
            }
            const save = path.items.len;
            if (std.mem.eql(u8, name, "..")) {
                if (std.mem.lastIndexOfScalar(u8, path.items, '/')) |sl| path.shrinkRetainingCapacity(sl) else path.clearRetainingCapacity();
            } else if (!std.mem.eql(u8, name, ".")) {
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) break;
                if (path.items.len > 0) try path.append(cn.gpa(), '/');
                try path.appendSlice(cn.gpa(), name);
            }
            const e = fs.stat(cn.id, path.items) orelse {
                path.shrinkRetainingCapacity(save);
                break;
            };
            entry = e;
            qids[got] = qidOf(e);
            got += 1;
        }
        if (got == 0 and names.len > 0) return cn.fail(tag, why);
        if (got == names.len) {
            if (newfid == fid) {
                const np = try cn.gpa().dupe(u8, path.items);
                cn.lock();
                cn.gpa().free(from.path);
                from.path = np;
                from.entry = entry;
                cn.unlock();
            } else if (!try cn.addFid(newfid, path.items, entry)) {
                return cn.fail(tag, "fid in use");
            }
        }
        cn.reply(tag, p9.Rwalk{ .wqids = wire.Qids.init(qids[0..got]) });
    }

    fn openMode(mode: u8) fsmod.OpenMode {
        return switch (mode & 3) {
            wire.OREAD, wire.OEXEC => .{ .read = true, .write = false, .trunc = mode & wire.OTRUNC != 0 },
            wire.OWRITE => .{ .read = false, .write = true, .trunc = mode & wire.OTRUNC != 0 },
            else => .{ .read = true, .write = true, .trunc = mode & wire.OTRUNC != 0 },
        };
    }

    /// Opens `f` (already resolved). On error returns the text to send.
    fn doOpen(cn: *Conn, f: *Fid, mode: u8, err: *Err) error{ Failed, OutOfMemory }!void {
        const fs = cn.srv.fs;
        if (f.open) return err.set("fid already open");
        const om = openMode(mode);
        if (f.entry.kind == .dir) {
            if (om.write) return err.set("permission denied: is a directory");
            f.mode = om;
            f.open = true;
            return;
        }
        const opened = try fs.open(cn.id, f.path, om, err);
        f.stream = opened.stream;
        f.random = opened.random;
        f.write_mode = opened.write_mode;
        f.token = opened.token;
        f.mode = om;
        if (f.entry.kind == .file and om.read and opened.stream == null and opened.random == null and !om.trunc) {
            var arena: std.heap.ArenaAllocator = .init(cn.gpa());
            defer arena.deinit();
            const data = fs.read(cn.id, f.path, arena.allocator(), err) catch |e| {
                if (f.stream) |s| s.close();
                f.stream = null;
                return e;
            };
            f.data = try cn.gpa().dupe(u8, data);
        }
        f.open = true;
    }

    fn openFid(cn: *Conn, tag: u16, fid: u32, mode: u8) !void {
        const f = cn.getFid(fid) orelse return cn.fail(tag, "unknown fid");
        defer cn.putFid(f);
        f.mu.lockUncancelable(cn.io());
        defer f.mu.unlock(cn.io());
        var err: Err = .{};
        cn.doOpen(f, mode, &err) catch |e| switch (e) {
            error.Failed => return cn.fail(tag, err.text()),
            error.OutOfMemory => return error.OutOfMemory,
        };
        cn.reply(tag, p9.Ropen{ .qid = qidOf(f.entry), .iounit = cn.msize - wire.io_header });
    }

    fn readFid(cn: *Conn, tag: u16, fid: u32, off: u64, count: u32) !void {
        const f = cn.getFid(fid) orelse return cn.fail(tag, "unknown fid");
        if (!f.open or !f.mode.read) {
            cn.putFid(f);
            return cn.fail(tag, "fid not open for reading");
        }
        const cap: usize = @min(count, cn.msize - wire.io_header);
        if (f.stream) |s| {
            // Blocks: a thread of its own, interruptible by Tflush.
            cn.spawn(tag, s, workStream, .{ cn, tag, f, cap });
            return;
        }
        defer cn.putFid(f);
        f.mu.lockUncancelable(cn.io());
        defer f.mu.unlock(cn.io());
        if (f.entry.kind == .dir) {
            if (off == 0) {
                cn.gpa().free(f.data);
                f.data = &.{};
                var err: Err = .{};
                f.data = cn.dirData(f.path, &err) catch |e| switch (e) {
                    error.Failed => return cn.fail(tag, err.text()),
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            // Whole entries only.
            const start: usize = @intCast(@min(off, f.data.len));
            var end = start;
            while (end + 2 <= f.data.len) {
                const sz = @as(usize, std.mem.readInt(u16, f.data[end..][0..2], .little)) + 2;
                if (end + sz - start > cap) break;
                end += sz;
            }
            return cn.replyRead(tag, f.data[start..end]);
        }
        if (f.random) |r| {
            const buf = try cn.gpa().alloc(u8, cap);
            defer cn.gpa().free(buf);
            var err: Err = .{};
            const n = r.pread(off, buf, &err) catch |e| switch (e) {
                error.Failed => return cn.fail(tag, err.text()),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return cn.replyRead(tag, buf[0..n]);
        }
        const start: usize = @intCast(@min(off, f.data.len));
        const end = @min(start + cap, f.data.len);
        cn.replyRead(tag, f.data[start..end]);
    }

    fn dirData(cn: *Conn, path: []const u8, err: *Err) error{ Failed, OutOfMemory }![]u8 {
        var arena: std.heap.ArenaAllocator = .init(cn.gpa());
        defer arena.deinit();
        const ents = try cn.srv.fs.list(cn.id, path, arena.allocator(), err);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(cn.gpa());
        var sb: [512]u8 = undefined;
        for (ents) |d| {
            const st = packDir(&sb, d.name, d.entry) orelse continue;
            try out.appendSlice(cn.gpa(), st);
        }
        return out.toOwnedSlice(cn.gpa());
    }

    fn writeFid(cn: *Conn, tag: u16, fid: u32, off: u64, data: []const u8) !void {
        const f = cn.getFid(fid) orelse return cn.fail(tag, "unknown fid");
        if (!f.open or !f.mode.write) {
            cn.putFid(f);
            return cn.fail(tag, "fid not open for writing");
        }
        switch (f.write_mode) {
            .lines => {
                const copy = try cn.gpa().dupe(u8, data);
                cn.spawn(tag, null, workLines, .{ cn, tag, f, copy });
                return;
            },
            .ctl, .per_write => {
                if (data.len + f.wbuf.items.len > max_write) {
                    cn.putFid(f);
                    return cn.fail(tag, "too large");
                }
                const copy = try cn.gpa().dupe(u8, data);
                const piece = data.len >= ctl_piece or data.len == cn.msize - wire.io_header;
                cn.spawn(tag, null, workNow, .{ cn, tag, f, copy, piece });
                return;
            },
            .at_close => {},
        }
        defer cn.putFid(f);
        f.mu.lockUncancelable(cn.io());
        defer f.mu.unlock(cn.io());
        const at: usize = @intCast(@min(off, f.wbuf.items.len));
        if (at + data.len > max_write) return cn.fail(tag, "too large");
        // Writes past what we have append; an overlapping write replaces.
        const keep = @min(f.wbuf.items.len, at + data.len);
        if (keep > at) {
            @memcpy(f.wbuf.items[at..keep], data[0 .. keep - at]);
            try f.wbuf.appendSlice(cn.gpa(), data[keep - at ..]);
        } else {
            try f.wbuf.appendSlice(cn.gpa(), data);
        }
        f.wrote = true;
        cn.reply(tag, p9.Rwrite{ .count = @intCast(data.len) });
    }

    // -----------------------------------------------------------------
    // Workers: each owns one ref on the conn and `f`, and its Pending.

    fn workStream(cn: *Conn, tag: u16, f: *Fid, cap: usize, p: *Pending) void {
        defer cn.putFid(f);
        f.mu.lockUncancelable(cn.io());
        const buf = cn.gpa().alloc(u8, cap) catch {
            f.mu.unlock(cn.io());
            _ = cn.endPending(p);
            return cn.fail(tag, "out of memory");
        };
        defer cn.gpa().free(buf);
        // A flush that got here first has already interrupted the stream,
        // so this read returns at once (and consumes the interrupt).
        const r: error{Interrupted}!usize = if (f.stream) |s| s.read(buf) else 0;
        f.mu.unlock(cn.io());
        const flushed = cn.endPending(p);
        if (r) |n| {
            // Answered before the flush took effect: send it anyway; the
            // client sees it before Rflush, which 9P allows.
            cn.replyRead(tag, buf[0..n]);
        } else |_| {
            if (!flushed) cn.fail(tag, "interrupted");
        }
    }

    fn workCommit(cn: *Conn, tag: u16, f: *Fid, remove: bool, p: *Pending) void {
        const fs = cn.srv.fs;
        // Wait for a stream read the clunk interrupted.
        f.mu.lockUncancelable(cn.io());
        var err: Err = .{};
        var failed = false;
        if (pendingAtClose(f)) {
            fs.commit(cn.id, f.path, f.token, f.wbuf.items, &err) catch |e| {
                failed = true;
                if (e == error.OutOfMemory) err.note("out of memory");
            };
        }
        if (remove and !failed) {
            fs.remove(cn.id, f.path, &err) catch |e| {
                failed = true;
                if (e == error.OutOfMemory) err.note("out of memory");
            };
        }
        if (failed) cn.srv.loud(if (remove and f.wbuf.items.len == 0) "remove" else "write", f.path, err.text());
        f.mu.unlock(cn.io());
        cn.putFid(f);
        _ = cn.endPending(p);
        if (failed) return cn.fail(tag, err.text());
        if (remove) cn.reply(tag, p9.Rremove{}) else cn.reply(tag, p9.Rclunk{});
    }

    /// Whether a clunk of `f` has something to commit: a buffered value
    /// (or a truncate with no write), or a ctl's held partial line.
    fn pendingAtClose(f: *const Fid) bool {
        if (!f.open or !f.mode.write) return false;
        return switch (f.write_mode) {
            .at_close => f.wrote or f.mode.trunc,
            .ctl => f.wbuf.items.len > 0,
            .per_write => f.wbuf.items.len > 0 or (!f.wrote and f.mode.trunc),
            .lines => false,
        };
    }

    /// A `ctl` or `per_write` write, committed now.
    fn workNow(cn: *Conn, tag: u16, f: *Fid, data: []u8, piece: bool, p: *Pending) void {
        const fs = cn.srv.fs;
        defer cn.gpa().free(data);
        defer cn.putFid(f);
        f.mu.lockUncancelable(cn.io());
        var err: Err = .{};
        var failed = false;
        f.wrote = true;
        var buf: []const u8 = data;
        if (f.write_mode == .ctl) blk: {
            const held = f.wbuf.items.len > 0;
            if (held) {
                f.wbuf.appendSlice(cn.gpa(), data) catch {
                    failed = true;
                    err.note("out of memory");
                    break :blk;
                };
                buf = f.wbuf.items;
            }
            if (!std.mem.endsWith(u8, buf, "\n") and (held or piece)) {
                // Keep the partial last line for the next write or the clunk.
                const cut = if (std.mem.lastIndexOfScalar(u8, buf, '\n')) |i| i + 1 else 0;
                if (buf.len - cut > max_write) {
                    failed = true;
                    err.note("too large");
                    break :blk;
                }
                const tail = cn.gpa().dupe(u8, buf[cut..]) catch {
                    failed = true;
                    err.note("out of memory");
                    break :blk;
                };
                defer cn.gpa().free(tail);
                const head = cn.gpa().dupe(u8, buf[0..cut]) catch {
                    failed = true;
                    err.note("out of memory");
                    break :blk;
                };
                defer cn.gpa().free(head);
                f.wbuf.clearRetainingCapacity();
                f.wbuf.appendSlice(cn.gpa(), tail) catch unreachable; // capacity held
                if (head.len > 0) fs.commit(cn.id, f.path, f.token, head, &err) catch |e| {
                    failed = true;
                    if (e == error.OutOfMemory) err.note("out of memory");
                };
                break :blk;
            }
            fs.commit(cn.id, f.path, f.token, buf, &err) catch |e| {
                failed = true;
                if (e == error.OutOfMemory) err.note("out of memory");
            };
            f.wbuf.clearRetainingCapacity();
        } else blk: {
            // The whole value, unless it is one piece of a bigger one.
            f.wbuf.appendSlice(cn.gpa(), data) catch {
                failed = true;
                err.note("out of memory");
                break :blk;
            };
            if (piece) break :blk;
            fs.commit(cn.id, f.path, f.token, f.wbuf.items, &err) catch |e| {
                failed = true;
                if (e == error.OutOfMemory) err.note("out of memory");
            };
            f.wbuf.clearRetainingCapacity();
        }
        if (failed) cn.srv.loud("write", f.path, err.text());
        f.mu.unlock(cn.io());
        _ = cn.endPending(p);
        if (failed) return cn.fail(tag, err.text());
        cn.reply(tag, p9.Rwrite{ .count = @intCast(data.len) });
    }

    fn workLines(cn: *Conn, tag: u16, f: *Fid, data: []u8, p: *Pending) void {
        const fs = cn.srv.fs;
        defer cn.gpa().free(data);
        defer cn.putFid(f);
        f.mu.lockUncancelable(cn.io());
        var err: Err = .{};
        var failed = false;
        var rest: []const u8 = data;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            var l = rest[0..nl];
            rest = rest[nl + 1 ..];
            var joined: ?[]u8 = null;
            if (f.wbuf.items.len > 0) {
                f.wbuf.appendSlice(cn.gpa(), l) catch {
                    failed = true;
                    err.note("out of memory");
                    break;
                };
                joined = f.wbuf.items;
                l = joined.?;
            }
            const line = std.mem.trimEnd(u8, l, "\r");
            const r = if (line.len == 0) {} else fs.line(cn.id, f.path, line, &err);
            f.wbuf.clearRetainingCapacity();
            r catch |e| {
                failed = true;
                if (e == error.OutOfMemory) err.note("out of memory");
                break;
            };
        }
        if (!failed) {
            if (f.wbuf.items.len + rest.len > max_write) {
                failed = true;
                err.note("too large");
            } else f.wbuf.appendSlice(cn.gpa(), rest) catch {
                failed = true;
                err.note("out of memory");
            };
        }
        if (failed) cn.srv.loud("write", f.path, err.text());
        f.mu.unlock(cn.io());
        _ = cn.endPending(p);
        if (failed) return cn.fail(tag, err.text());
        cn.reply(tag, p9.Rwrite{ .count = @intCast(data.len) });
    }

    fn workCreate(cn: *Conn, tag: u16, f: *Fid, name: []u8, perm: u32, mode: u8, p: *Pending) void {
        const fs = cn.srv.fs;
        defer cn.gpa().free(name);
        defer cn.putFid(f);
        f.mu.lockUncancelable(cn.io());
        var err: Err = .{};
        const r = cn.doCreate(f, name, perm, mode, &err);
        if (r) |_| {} else |_| {
            const full = fsmod.join(cn.gpa(), f.path, name) catch null;
            defer if (full) |x| cn.gpa().free(x);
            cn.srv.loud(if (perm & wire.DMDIR != 0) "mkdir" else "create", full orelse name, err.text());
        }
        f.mu.unlock(cn.io());
        _ = fs;
        _ = cn.endPending(p);
        if (r) |e| {
            cn.reply(tag, p9.Rcreate{ .qid = qidOf(e), .iounit = cn.msize - wire.io_header });
        } else |e| switch (e) {
            error.Failed => cn.fail(tag, err.text()),
            error.OutOfMemory => cn.fail(tag, "out of memory"),
        }
    }

    fn doCreate(cn: *Conn, f: *Fid, name: []const u8, perm: u32, mode: u8, err: *Err) error{ Failed, OutOfMemory }!Entry {
        const fs = cn.srv.fs;
        const is_dir = perm & wire.DMDIR != 0;
        const e = try fs.create(cn.id, f.path, name, is_dir, err);
        const np = try fsmod.join(cn.gpa(), f.path, name);
        // The fid now names the new file, opened.
        cn.lock();
        cn.gpa().free(f.path);
        f.path = np;
        f.entry = e;
        cn.unlock();
        // A create opens what exists now; contents start empty, so a
        // readable create reads what the file holds.
        try cn.doOpen(f, mode | if (is_dir) 0 else wire.OTRUNC, err);
        return e;
    }
};

fn qidOf(e: Entry) wire.Qid {
    return .{
        .type = switch (e.kind) {
            .dir => wire.QTDIR,
            .stream => wire.QTAPPEND,
            .file => wire.QTFILE,
        },
        .vers = e.vers,
        .path = e.qid,
    };
}

fn packDir(out: []u8, name: []const u8, e: Entry) ?[]u8 {
    const q = qidOf(e);
    const d: Dir = .{
        .qid = q,
        .mode = e.perm | switch (e.kind) {
            .dir => wire.DMDIR,
            .stream => wire.DMAPPEND,
            .file => 0,
        },
        .length = if (e.kind == .file) e.length else 0,
        .name = name,
        .uid = "ui",
        .gid = "ui",
        .muid = "ui",
    };
    return d.pack(out) catch null;
}

test {
    std.testing.refAllDecls(@This());
}
