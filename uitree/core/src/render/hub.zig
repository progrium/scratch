//! The renderer tree (protocols/render.md): the core's second 9P tree,
//! for renderers. One `Hub` per core, made by the first
//! uit_render_listen, uit_render_serve_fd or uit_render_serve_conn.
//!
//! The owner thread does all the work, inside uit_pump: `runInput` applies
//! the `input` lines queued since the last pump (each the uit_* call it
//! names), and `afterPump` encodes what the pump changed once and appends
//! the bytes to every subscription. 9P threads only queue and copy bytes.
//! With nothing attached a pump costs one lock.
//!
//!     version     `uitree-render 0.1`
//!     hello       write `hello name=N role=primary|mirror|view`
//!     renderers   one line per attached renderer: NAME ROLE
//!     changes     a snapshot, then batches; one stream per open
//!     input       lines: /debug/inject's grammar, plus request, closed, drag
//!     asset/NAME  an asset's bytes, as of the last `asset NAME` record
//!     clip        the clipboard text the last `clip` record published
//!     stats       pump and encode times

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const proto = @import("../proto/root.zig");
const ninep = @import("../ninep/root.zig");
const treem = @import("../tree/root.zig");
const stream = @import("stream.zig");
const termrec = @import("term.zig");

const fsmod = ninep.fs;
const debug = ninep.debug;
const transport = ninep.transport;
const Err = fsmod.Err;
const ConnId = fsmod.ConnId;
const Allocator = std.mem.Allocator;
const UitStr = abi.UitStr;
const Core = abi.Core;
const Handle = treem.Handle;

pub const version = "uitree-render 0.1\n";

/// Past this many unread bytes a renderer is too slow: its queue is
/// dropped and it gets a fresh snapshot instead (render.md § Resync).
pub var max_queue: usize = 4 << 20;

/// uit_render_* flags. HOST_DRAWS: the host has a built-in renderer,
/// which is the primary, so no 9P renderer can be.
pub const HOST_DRAWS: u32 = 1;

pub const Role = enum { none, primary, mirror, view };

const Renderer = struct {
    conn: ConnId,
    name: []u8 = &.{},
    role: Role = .none,
};

const Sub = struct {
    h: *Hub,
    conn: ConnId,
    buf: std.ArrayList(u8) = .empty,
    off: usize = 0,
    need_snap: bool = true,
    intr: bool = false,
    resyncs: u32 = 0,
};

const Job = struct {
    conn: ConnId,
    line: []const u8,
    err: *Err,
    failed: bool = false,
    done: bool = false,
    next: ?*Job = null,
};

const Stats = struct {
    pumps: u64 = 0,
    batches: u64 = 0,
    bytes: u64 = 0,
    enc_ns: std.ArrayList(u64) = .empty,
    snaps: u64 = 0,
    snap_bytes: u64 = 0,
    snap_ns: u64 = 0,
};

pub const Hub = struct {
    gpa: Allocator,
    io: std.Io,
    c: *Core,
    flags: u32,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    jobs: ?*Job = null,
    jobs_tail: ?*Job = null,
    subs: std.ArrayList(*Sub) = .empty,
    renderers: std.ArrayList(Renderer) = .empty,
    /// Under `mu` (a 64-bit atomic isn't on wasm32).
    next_conn: u64 = 1,
    /// The app is gone: streams end, input fails.
    finished: bool = false,
    /// Set from 9P threads when a subscription wants a snapshot.
    snap_wanted: bool = false,
    enc: stream.Encoder,
    stats: Stats = .{},
    /// Copies the 9P threads serve: assets by name, the clipboard.
    assets: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    clip: []u8 = &.{},
    srv: ninep.Server = undefined,
    listeners: std.ArrayList(*transport.Listener) = .empty,

    pub fn create(c: *Core, flags: u32) !*Hub {
        const h = try c.gpa.create(Hub);
        h.* = .{ .gpa = c.gpa, .io = c.io(), .c = c, .flags = flags, .enc = .{ .gpa = c.gpa } };
        h.srv = .init(c.gpa, h.io, h.fs());
        return h;
    }

    /// Ends every stream and hangs up every renderer. Owner thread, at
    /// uit_destroy.
    pub fn destroy(h: *Hub) void {
        h.end();
        for (h.listeners.items) |l| l.stop();
        h.listeners.deinit(h.gpa);
        h.srv.shutdown();
        h.srv.deinit();
        h.enc.deinit();
        for (h.renderers.items) |x| h.gpa.free(x.name);
        h.renderers.deinit(h.gpa);
        h.subs.deinit(h.gpa);
        for (h.assets.keys(), h.assets.values()) |k, v| {
            h.gpa.free(k);
            h.gpa.free(v);
        }
        h.assets.deinit(h.gpa);
        h.gpa.free(h.clip);
        h.stats.enc_ns.deinit(h.gpa);
        h.gpa.destroy(h);
    }

    /// The app is gone or the core is going: streams hit end of file,
    /// queued input fails.
    pub fn end(h: *Hub) void {
        h.lock();
        defer h.unlock();
        h.finished = true;
        var j = h.jobs;
        while (j) |x| : (j = x.next) {
            x.failed = true;
            x.err.note("app gone");
            x.done = true;
        }
        h.jobs = null;
        h.jobs_tail = null;
        h.cond.broadcast(h.io);
    }

    fn lock(h: *Hub) void {
        h.mu.lockUncancelable(h.io);
    }
    fn unlock(h: *Hub) void {
        h.mu.unlock(h.io);
    }

    pub fn fs(h: *Hub) fsmod.Fs {
        return .{ .ptr = h, .vt = &vt };
    }

    fn onConn(ctx: *anyopaque, k: transport.Conn) void {
        const h: *Hub = @ptrCast(@alignCast(ctx));
        h.srv.serve(k) catch {};
    }

    pub fn listen(h: *Hub, addr: []const u8) ![]const u8 {
        // Empty: a fresh unix socket in a private directory, as uit_listen.
        const l = if (addr.len == 0) try transport.listenPrivate(h.gpa, h.io) else try transport.listen(h.gpa, addr);
        errdefer l.stop();
        h.lock();
        defer h.unlock();
        try h.listeners.append(h.gpa, l);
        try l.start(h, onConn);
        return l.dial;
    }

    pub fn serve(h: *Hub, k: transport.Conn) !void {
        try h.srv.serve(k);
    }

    fn rendererOf(h: *Hub, conn: ConnId) ?*Renderer {
        for (h.renderers.items) |*x| if (x.conn == conn) return x;
        return null;
    }

    fn hasPrimary(h: *Hub) bool {
        for (h.renderers.items) |x| if (x.role == .primary) return true;
        return false;
    }

    // -----------------------------------------------------------------
    // Owner thread, inside uit_pump

    /// Applies the `input` lines queued since the last pump. They are
    /// marked done by `afterPump`, so a write returns once its effect is
    /// in the stream.
    pub fn runInput(h: *Hub) void {
        h.lock();
        const jobs = h.jobs;
        h.unlock();
        var j = jobs;
        while (j) |x| : (j = x.next) {
            if (x.done) continue;
            h.apply(x) catch |e| {
                x.failed = true;
                if (e == error.OutOfMemory) x.err.note("out of memory");
            };
        }
    }

    /// Encodes the pump's changes once and queues them for every
    /// subscription; snapshots for those that want one.
    pub fn afterPump(h: *Hub, o: *const abi.UitChanges) void {
        h.afterPumpInner(o) catch {
            // Out of memory mid-encode: the stream may now be wrong, so
            // everyone starts over.
            h.lock();
            for (h.subs.items) |s| s.need_snap = true;
            h.snap_wanted = true;
            h.unlock();
        };
    }

    fn afterPumpInner(h: *Hub, o: *const abi.UitChanges) !void {
        const c = h.c;
        h.enc.seq += 1;
        h.lock();
        const any_subs = h.subs.items.len > 0;
        // Not inside an app's batch: the state the stream reads is the
        // one from before it, and what the batch makes would be missed.
        const want_snap = h.snap_wanted and !c.tree.batchOpen();
        if (want_snap) h.snap_wanted = false;
        h.unlock();
        h.stats.pumps += 1;

        var out: std.Io.Writer.Allocating = .init(h.gpa);
        defer out.deinit();
        if (any_subs) {
            const t1 = now();
            const any = try h.enc.batch(stream.Source.ofCore(c), o, t1, &out.writer);
            if (o.exited == 1) {
                try out.writer.writeAll("exit ");
                try proto.tokenize.quoteWord(&out.writer, o.exit_status.slice());
                try out.writer.writeByte('\n');
            }
            if (any) {
                h.stats.batches += 1;
                h.stats.bytes += out.written().len;
                try h.stats.enc_ns.append(h.gpa, now() - t1);
            }
        }
        try h.copyOut(o, want_snap);

        var snap: ?[]u8 = null;
        defer if (snap) |s| h.gpa.free(s);
        if (want_snap) {
            const ts = now();
            var sw: std.Io.Writer.Allocating = .init(h.gpa);
            errdefer sw.deinit();
            try h.enc.snapshot(stream.Source.ofCore(c), &sw.writer);
            snap = try sw.toOwnedSlice();
            h.stats.snaps += 1;
            h.stats.snap_bytes = snap.?.len;
            h.stats.snap_ns = now() - ts;
        }

        h.lock();
        defer h.unlock();
        for (h.subs.items) |s| {
            if (s.need_snap) {
                if (snap) |b| {
                    s.buf.clearRetainingCapacity();
                    s.off = 0;
                    try s.buf.appendSlice(h.gpa, b);
                    s.need_snap = false;
                }
            } else if (out.written().len > 0) {
                if (s.buf.items.len - s.off + out.written().len > max_queue) {
                    s.need_snap = true;
                    s.resyncs += 1;
                    h.snap_wanted = true;
                } else try s.buf.appendSlice(h.gpa, out.written());
            }
        }
        var j = h.jobs;
        while (j) |x| : (j = x.next) x.done = true;
        h.jobs = null;
        h.jobs_tail = null;
        if (o.exited == 1) h.finished = true;
        h.cond.broadcast(h.io);
        // A resync is due at the next pump (or when the batch ends).
        if (h.snap_wanted and !c.tree.batchOpen()) c.wake();
    }

    /// The bytes `asset/` and `clip` serve, as of this pump.
    fn copyOut(h: *Hub, o: *const abi.UitChanges, all_assets: bool) !void {
        const st = h.c.state();
        const cmds = many(abi.UitHostCmd, o.cmds, o.n_cmds);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(h.gpa);
        if (all_assets) {
            for (st.assets.items) |m| try names.append(h.gpa, m.name.bytes);
        } else for (cmds) |hc| if (hc.tag == abi.UIT_CMD_ASSETS) try names.append(h.gpa, hc.name.slice());
        var clip: ?[]u8 = null;
        for (cmds) |hc| if (hc.tag == abi.UIT_CMD_CLIPBOARD) {
            if (clip) |x| h.gpa.free(x);
            clip = try h.gpa.dupe(u8, hc.answer.slice());
        };
        if (names.items.len == 0 and clip == null) return;
        h.lock();
        defer h.unlock();
        if (clip) |x| {
            h.gpa.free(h.clip);
            h.clip = x;
        }
        for (names.items) |n| {
            const m = st.asset(n);
            if (h.assets.fetchSwapRemove(n)) |kv| {
                h.gpa.free(kv.key);
                h.gpa.free(kv.value);
            }
            if (m) |x| {
                const k = try h.gpa.dupe(u8, n);
                errdefer h.gpa.free(k);
                const v = try h.gpa.dupe(u8, x.val.bytes);
                errdefer h.gpa.free(v);
                try h.assets.put(h.gpa, k, v);
            }
        }
    }

    fn node(h: *Hub, arena: Allocator, win: ?[]const u8, path: ?[]const u8, err: *Err) !Handle {
        const w = win orelse "main";
        const p = path orelse ".";
        const st = h.c.tree.current();
        const wn = st.win(w) orelse return err.print("not found: win/{s}", .{w});
        if (std.mem.eql(u8, p, ".")) return wn.root;
        return treem.path.resolveNode(st, arena, wn.root, p, null) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return err.print("not found: win/{s}/{s}", .{ w, p });
        };
    }

    fn check(h: *Hub, rc: c_int, err: *Err) !void {
        if (rc >= 0) return;
        return err.set(abi.uit_last_error(h.c).slice());
    }

    /// One `input` line, as the uit_* call it names.
    fn apply(h: *Hub, j: *Job) !void {
        var arena: std.heap.ArenaAllocator = .init(h.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const c = h.c;
        const err = j.err;
        h.lock();
        const role: Role = if (h.rendererOf(j.conn)) |x| x.role else .none;
        h.unlock();
        if (role == .view) return err.set("permission denied: a view renderer sends no input");
        // A connection that never said hello is a mirror.
        const primary = role == .primary;

        const cl = proto.ctl.parse(a, j.line) catch return err.set("bad syntax");
        if (std.mem.eql(u8, cl.verb, "request")) {
            if (cl.words.len != 1) return err.set("bad syntax: request NAME win= node= id= default=");
            const n = try h.node(a, cl.attr("win"), cl.attr("node"), err);
            const id = cl.attr("id") orelse return err.set("bad syntax: request needs id=");
            var attrs: std.ArrayList(abi.UitAttr) = .empty;
            for (cl.attrs) |at| {
                const own = [_][]const u8{ "win", "node", "id", "default" };
                const is_own = for (own) |o| {
                    if (std.mem.eql(u8, at.key, o)) break true;
                } else false;
                if (!is_own) try attrs.append(a, .{ .name = UitStr.of(at.key), .value = UitStr.of(at.value) });
            }
            const seq = abi.uit_request(c, n, UitStr.of(cl.words[0]), attrs.items.ptr, attrs.items.len, UitStr.of(cl.attr("default") orelse ""));
            if (seq == 0) return err.set(abi.uit_last_error(c).slice());
            try h.enc.requests.put(h.gpa, seq, try h.gpa.dupe(u8, id));
            return;
        }
        if (std.mem.eql(u8, cl.verb, "closed")) {
            if (!primary) return;
            return h.check(abi.uit_window_closed(c, UitStr.of(cl.attr("win") orelse "main")), err);
        }
        // `drag start|drop|end`: a renderer's own drags and drops. The
        // inject grammar's `drag n=` (a platform offer) stays headless's.
        if (std.mem.eql(u8, cl.verb, "drag") and cl.words.len > 0) return h.drag(a, cl, err);
        // `term-*`: a terminal's input (render.md § Terminals).
        if (std.mem.startsWith(u8, cl.verb, "term-")) {
            const in = (termrec.parseInput(cl) catch return err.set("bad syntax")) orelse return err.set("unknown command");
            switch (in) {
                .resize => |x| {
                    // The grid is the primary's, as layout is.
                    if (!primary) return;
                    const n = try h.node(a, x.win, x.node, err);
                    try h.check(abi.uit_term_resize(c, n, x.cols, x.rows, x.cell_w_px, x.cell_h_px), err);
                },
                .mouse => |x| {
                    const n = try h.node(a, x.win, x.node, err);
                    try h.check(abi.uit_term_mouse(c, n, &x.m), err);
                },
                .scroll => |x| {
                    const n = try h.node(a, x.win, x.node, err);
                    try h.check(abi.uit_term_scroll(c, n, x.lines), err);
                },
                .text => |x| {
                    const n = try h.node(a, x.win, x.node, err);
                    try h.check(abi.uit_term_text(c, n, UitStr.of(x.text)), err);
                },
                .paste => |x| {
                    const n = try h.node(a, x.win, x.node, err);
                    try h.check(abi.uit_term_paste(c, n, UitStr.of(x.text)), err);
                },
            }
            return;
        }

        const inj = try debug.parse(a, j.line, err);
        switch (inj) {
            .event => |ev| {
                const n = try h.node(a, ev.win, ev.node, err);
                const attrs = try a.alloc(abi.UitAttr, ev.attrs.len);
                for (ev.attrs, attrs) |x, *y| y.* = .{ .name = UitStr.of(x.key), .value = UitStr.of(x.value) };
                try h.check(abi.uit_emit(c, n, UitStr.of(ev.name), attrs.ptr, attrs.len), err);
            },
            .mirror => |m| {
                const n = try h.node(a, m.win, m.node, err);
                try h.check(abi.uit_mirror(c, n, UitStr.of(m.file), UitStr.of(m.value)), err);
            },
            // Layout and frames belong to the primary: a mirror lays out
            // for itself and its numbers aren't the app's.
            .bounds => |b| {
                if (!primary) return;
                const n = try h.node(a, b.win, b.node, err);
                try h.check(abi.uit_bounds(c, n, b.x, b.y, b.w, b.h), err);
            },
            .frame => |f| {
                if (!primary) return;
                try h.check(abi.uit_frame_drawn(c, UitStr.of(f.win orelse "main")), err);
            },
            .key => |k| {
                const n: Handle = if (k.node) |p| try h.node(a, k.win, p, err) else 0;
                try h.check(abi.uit_key(c, UitStr.of(k.win), UitStr.of(k.stroke), n), err);
            },
            .menu => |m| try h.check(abi.uit_menu_action(c, UitStr.of(m.item)), err),
            .appearance => |ap| {
                if (!primary) return;
                try h.check(abi.uit_system_dark(c, @intFromBool(ap.dark)), err);
            },
            .tick => return err.set("permission denied: tick is the headless host's"),
            .drag => return err.set("bad syntax: drag start|drop|end"),
            // `term-*` lines are taken above.
            .term => return err.set("bad syntax"),
        }
    }

    /// `drag start win= node= id=ID`: the stream says `dragging ID N`.
    /// `drag drop win= node= x= y= [drag=N] [id=ID] [TYPE=DATA ...]`: the
    /// answer comes back as `answer ID accept|refuse`. A drop from outside
    /// the app (no drag=) offers its TYPE=DATA attributes; `file=` isn't
    /// taken, since a host path on the renderer's machine means nothing
    /// to the core's.
    /// `drag end drag=N result=dropped|cancelled`.
    fn drag(h: *Hub, a: Allocator, cl: proto.ctl.Ctl, err: *Err) !void {
        const c = h.c;
        const kind = cl.words[0];
        const num = struct {
            fn f(s: ?[]const u8) f32 {
                return std.fmt.parseFloat(f32, s orelse return 0) catch 0;
            }
        }.f;
        var msg: abi.UitDragMsg = .{ .kind = 0, .drag = 0, .node = 0, .x = num(cl.attr("x")), .y = num(cl.attr("y")), .attrs = null, .n_attrs = 0 };
        if (cl.attr("drag")) |d| msg.drag = std.fmt.parseInt(u64, d, 10) catch return err.print("bad value: drag={s}", .{d});
        var out: u64 = 0;
        if (std.mem.eql(u8, kind, "start")) {
            msg.kind = abi.UIT_DRAG_START;
            msg.node = try h.node(a, cl.attr("win"), cl.attr("node"), err);
            try h.check(abi.uit_drag(c, &msg, &out), err);
            const id = cl.attr("id") orelse return;
            try h.enc.dragging.append(h.gpa, .{ .id = try h.gpa.dupe(u8, id), .n = out });
        } else if (std.mem.eql(u8, kind, "drop")) {
            msg.kind = abi.UIT_DRAG_DROP;
            msg.node = try h.node(a, cl.attr("win"), cl.attr("node"), err);
            var attrs: std.ArrayList(abi.UitAttr) = .empty;
            if (msg.drag == 0) for (cl.attrs) |at| {
                const skip = [_][]const u8{ "win", "node", "x", "y", "drag", "id", "file" };
                const is_skip = for (skip) |s| {
                    if (std.mem.eql(u8, at.key, s)) break true;
                } else false;
                if (is_skip) continue;
                try attrs.append(a, .{ .name = UitStr.of(at.key), .value = UitStr.of(at.value) });
            };
            msg.attrs = if (attrs.items.len > 0) attrs.items.ptr else null;
            msg.n_attrs = attrs.items.len;
            try h.check(abi.uit_drag(c, &msg, &out), err);
            if (out != 0) if (cl.attr("id")) |id| try h.enc.requests.put(h.gpa, out, try h.gpa.dupe(u8, id));
        } else if (std.mem.eql(u8, kind, "end")) {
            msg.kind = abi.UIT_DRAG_END;
            const res = cl.attr("result") orelse "cancelled";
            var attrs = [_]abi.UitAttr{.{ .name = UitStr.lit("result"), .value = UitStr.of(res) }};
            msg.attrs = &attrs;
            msg.n_attrs = 1;
            try h.check(abi.uit_drag(c, &msg, &out), err);
        } else return err.print("bad syntax: drag {s}", .{kind});
    }
};

fn many(comptime T: type, p: ?[*]const T, n: usize) []const T {
    if (n == 0) return &.{};
    return (p orelse return &.{})[0..n];
}

fn now() u64 {
    // CLOCK_MONOTONIC, as the spike's renderers stamp with; none on wasi or Windows.
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows) return 0;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------
// The renderer tree, as an Fs

const files = [_][]const u8{ "version", "hello", "renderers", "changes", "input", "asset", "clip", "stats" };

fn entryOf(name: []const u8) ?fsmod.Entry {
    for (files, 0..) |f, i| if (std.mem.eql(u8, f, name)) {
        const kind: fsmod.Kind = if (std.mem.eql(u8, f, "changes")) .stream else if (std.mem.eql(u8, f, "asset")) .dir else .file;
        const perm: u32 = if (std.mem.eql(u8, f, "input") or std.mem.eql(u8, f, "hello")) 0o222 else if (kind == .dir) 0o555 else 0o444;
        return .{ .kind = kind, .qid = 0x7265_6e64_0000_0010 + @as(u64, i), .perm = perm };
    };
    return null;
}

fn assetEntry(i: usize) fsmod.Entry {
    return .{ .kind = .file, .qid = 0x7265_6e64_0001_0000 + @as(u64, i), .perm = 0o444 };
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

fn self(p: *anyopaque) *Hub {
    return @ptrCast(@alignCast(p));
}

fn connect(p: *anyopaque) ConnId {
    const h = self(p);
    h.lock();
    defer h.unlock();
    const id = h.next_conn;
    h.next_conn += 1;
    h.renderers.append(h.gpa, .{ .conn = id }) catch {};
    return id;
}

fn disconnect(p: *anyopaque, conn: ConnId) void {
    const h = self(p);
    h.lock();
    defer h.unlock();
    for (h.renderers.items, 0..) |x, i| if (x.conn == conn) {
        h.gpa.free(x.name);
        _ = h.renderers.orderedRemove(i);
        break;
    };
}

fn assetName(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "asset/")) return null;
    const n = path["asset/".len..];
    if (n.len == 0 or std.mem.indexOfScalar(u8, n, '/') != null) return null;
    return n;
}

fn stat(p: *anyopaque, _: ConnId, path: []const u8) ?fsmod.Entry {
    if (path.len == 0) return .{ .kind = .dir, .qid = 0x7265_6e64_0000_0001, .perm = 0o555 };
    if (assetName(path)) |n| {
        const h = self(p);
        h.lock();
        defer h.unlock();
        const i = h.assets.getIndex(n) orelse return null;
        return assetEntry(i);
    }
    return entryOf(path);
}

fn list(p: *anyopaque, _: ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const fsmod.DirEnt {
    if (std.mem.eql(u8, path, "asset")) {
        const h = self(p);
        h.lock();
        defer h.unlock();
        const out = try arena.alloc(fsmod.DirEnt, h.assets.count());
        for (h.assets.keys(), out, 0..) |k, *d, i| d.* = .{ .name = try arena.dupe(u8, k), .entry = assetEntry(i) };
        return out;
    }
    if (path.len != 0) return err.set("not found");
    const out = try arena.alloc(fsmod.DirEnt, files.len);
    for (files, out) |f, *d| d.* = .{ .name = f, .entry = entryOf(f).? };
    return out;
}

fn open(p: *anyopaque, conn: ConnId, path: []const u8, mode: fsmod.OpenMode, err: *Err) fsmod.Error!fsmod.Opened {
    const h = self(p);
    if (assetName(path) != null) {
        if (mode.write) return err.set("permission denied: read-only");
        if (stat(p, conn, path) == null) return err.set("not found");
        return .{};
    }
    const e = entryOf(path) orelse return err.set("not found");
    if (mode.write and e.perm & 0o222 == 0) return err.set("permission denied: read-only");
    if (mode.read and e.perm & 0o444 == 0) return err.set("permission denied: write-only");
    if (std.mem.eql(u8, path, "input")) return .{ .write_mode = .lines };
    if (std.mem.eql(u8, path, "changes")) {
        const s = try h.gpa.create(Sub);
        s.* = .{ .h = h, .conn = conn };
        h.lock();
        defer h.unlock();
        h.subs.append(h.gpa, s) catch {
            h.gpa.destroy(s);
            return error.OutOfMemory;
        };
        h.snap_wanted = true;
        h.c.wake();
        return .{ .stream = .{ .ptr = s, .vt = &sub_vt } };
    }
    return .{};
}

fn read(p: *anyopaque, _: ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const u8 {
    const h = self(p);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    if (assetName(path)) |n| {
        h.lock();
        defer h.unlock();
        const v = h.assets.get(n) orelse return err.set("not found");
        return arena.dupe(u8, v);
    }
    if (std.mem.eql(u8, path, "version")) {
        w.writeAll(version) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, path, "renderers")) {
        h.lock();
        defer h.unlock();
        if (h.flags & HOST_DRAWS != 0) w.writeAll("host primary\n") catch return error.OutOfMemory;
        for (h.renderers.items) |x| {
            if (x.role == .none) continue;
            w.print("{s} {t}\n", .{ x.name, x.role }) catch return error.OutOfMemory;
        }
    } else if (std.mem.eql(u8, path, "clip")) {
        h.lock();
        defer h.unlock();
        return arena.dupe(u8, h.clip);
    } else if (std.mem.eql(u8, path, "stats")) {
        h.lock();
        defer h.unlock();
        const s = &h.stats;
        w.print("pumps {d}\nbatches {d}\nbytes {d}\n", .{ s.pumps, s.batches, s.bytes }) catch return error.OutOfMemory;
        w.print("snapshots {d} last_bytes={d} last_us={d}\n", .{ s.snaps, s.snap_bytes, s.snap_ns / 1000 }) catch return error.OutOfMemory;
        pct(arena, w, "encode", s.enc_ns.items) catch return error.OutOfMemory;
        for (h.subs.items) |x| if (x.resyncs > 0) w.print("resyncs conn={d} n={d}\n", .{ x.conn, x.resyncs }) catch return error.OutOfMemory;
    } else return err.set("permission denied: write-only");
    return aw.written();
}

fn commit(p: *anyopaque, conn: ConnId, path: []const u8, _: u64, data: []const u8, err: *Err) fsmod.Error!void {
    const h = self(p);
    if (!std.mem.eql(u8, path, "hello")) return;
    var arena: std.heap.ArenaAllocator = .init(h.gpa);
    defer arena.deinit();
    const cl = proto.ctl.parse(arena.allocator(), std.mem.trim(u8, data, " \t\r\n")) catch return err.set("bad syntax");
    if (!std.mem.eql(u8, cl.verb, "hello")) return err.set("bad syntax: hello name=N role=R");
    const name: []const u8 = cl.attr("name") orelse "renderer";
    const rs = cl.attr("role") orelse "mirror";
    const role = std.meta.stringToEnum(Role, rs) orelse return err.print("bad value: role={s}", .{rs});
    if (role == .none) return err.print("bad value: role={s}", .{rs});
    h.lock();
    defer h.unlock();
    const x = h.rendererOf(conn) orelse return err.set("gone");
    if (role == .primary and x.role != .primary) {
        if (h.flags & HOST_DRAWS != 0) return err.set("in use: the host draws");
        if (h.hasPrimary()) return err.set("in use: a primary is attached");
    }
    const nm = h.gpa.dupe(u8, name) catch return error.OutOfMemory;
    h.gpa.free(x.name);
    x.name = nm;
    x.role = role;
}

fn line(p: *anyopaque, conn: ConnId, _: []const u8, l: []const u8, err: *Err) fsmod.Error!void {
    const h = self(p);
    const copy = h.gpa.dupe(u8, l) catch return error.OutOfMemory;
    defer h.gpa.free(copy);
    var job: Job = .{ .conn = conn, .line = copy, .err = err };
    h.lock();
    defer h.unlock();
    if (h.finished) return err.set("app gone");
    if (h.jobs_tail) |t| t.next = &job else h.jobs = &job;
    h.jobs_tail = &job;
    h.c.wake();
    while (!job.done) h.cond.waitUncancelable(h.io, &h.mu);
    if (job.failed) return error.Failed;
}

fn create(_: *anyopaque, _: ConnId, _: []const u8, _: []const u8, _: bool, err: *Err) fsmod.Error!fsmod.Entry {
    return err.set("permission denied");
}
fn remove(_: *anyopaque, _: ConnId, _: []const u8, err: *Err) fsmod.Error!void {
    return err.set("permission denied");
}

fn pct(a: Allocator, w: *std.Io.Writer, name: []const u8, xs: []const u64) !void {
    if (xs.len == 0) return;
    const s = try a.dupe(u64, xs);
    std.mem.sort(u64, s, {}, std.sort.asc(u64));
    const at = struct {
        fn f(v: []const u64, q: f64) f64 {
            const i: usize = @intFromFloat(@as(f64, @floatFromInt(v.len - 1)) * q);
            return @as(f64, @floatFromInt(v[i])) / 1000.0;
        }
    }.f;
    try w.print("{s}_us n={d} p50={d:.1} p90={d:.1} max={d:.1}\n", .{ name, s.len, at(s, 0.5), at(s, 0.9), at(s, 1.0) });
}

const sub_vt: fsmod.Stream.VTable = .{ .read = subRead, .interrupt = subInterrupt, .close = subClose };

fn subRead(p: *anyopaque, buf: []u8) error{Interrupted}!usize {
    const s: *Sub = @ptrCast(@alignCast(p));
    const h = s.h;
    h.lock();
    defer h.unlock();
    while (true) {
        if (s.intr) {
            s.intr = false;
            return error.Interrupted;
        }
        if (!s.need_snap and s.off < s.buf.items.len) {
            const n = @min(buf.len, s.buf.items.len - s.off);
            @memcpy(buf[0..n], s.buf.items[s.off..][0..n]);
            s.off += n;
            if (s.off == s.buf.items.len) {
                s.buf.clearRetainingCapacity();
                s.off = 0;
            }
            return n;
        }
        if (h.finished) return 0;
        h.cond.waitUncancelable(h.io, &h.mu);
    }
}

fn subInterrupt(p: *anyopaque) void {
    const s: *Sub = @ptrCast(@alignCast(p));
    s.h.lock();
    defer s.h.unlock();
    s.intr = true;
    s.h.cond.broadcast(s.h.io);
}

fn subClose(p: *anyopaque) void {
    const s: *Sub = @ptrCast(@alignCast(p));
    const h = s.h;
    h.lock();
    for (h.subs.items, 0..) |x, i| if (x == s) {
        _ = h.subs.orderedRemove(i);
        break;
    };
    h.unlock();
    s.buf.deinit(h.gpa);
    h.gpa.destroy(s);
}
