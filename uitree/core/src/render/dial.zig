//! The renderer's end of the renderer tree (protocols/render.md): a core
//! dials one another core serves (uit_render_dial), applies its change
//! stream to its own tree through a Replica, and sends its host's input
//! calls back as `input` lines. A host over uitcore.h then draws a remote
//! app exactly as it draws a local one, through the calls it already makes.
//!
//! One 9P connection, as the hello is per connection: a reader thread
//! keeps one Tread on `changes` outstanding and takes every reply; a
//! writer thread sends what the owner thread queued for `input`, one
//! Twrite at a time. The owner thread applies the stream in uit_pump.

const std = @import("std");
const abi = @import("../abi.zig");
const proto = @import("../proto/root.zig");
const treem = @import("../tree/root.zig");
const ninep = @import("../ninep/root.zig");
const replica = @import("replica.zig");

const Allocator = std.mem.Allocator;
const Ctl = proto.ctl.Ctl;
const Handle = treem.Handle;
const Client = ninep.client.Client;
const wire = ninep.wire;
const tokenize = proto.tokenize;

const tag_changes: u16 = 1;
const tag_input: u16 = 2;

pub const Remote = struct {
    gpa: Allocator,
    c: *abi.Core,
    cl: Client,
    changes: u32 = 0,
    input: u32 = 0,
    rep: replica.Replica,
    primary: bool,

    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    send_mu: std.Io.Mutex = .init,
    /// Stream bytes read, not yet applied.
    inbox: std.ArrayList(u8) = .empty,
    /// The stream ended (the app is gone or the connection broke).
    ended: bool = false,
    /// Input lines not yet sent.
    outbox: std.ArrayList(u8) = .empty,
    /// Twrite in flight; its reply clears it.
    writing: bool = false,
    stopping: bool = false,
    /// The last refused input write, for the log.
    input_err: std.ArrayList(u8) = .empty,
    reader: ?std.Thread = null,
    writer: ?std.Thread = null,
    /// Request ids handed out by `request`; answers come back by id.
    next_request: u64 = 1,
    /// Set on the owner thread once the stream's `exit` or end was seen.
    exit_told: bool = false,

    fn io(r: *Remote) std.Io {
        return r.c.io();
    }

    /// Dials `addr`, says hello and starts reading. `role` is primary,
    /// mirror or view.
    pub fn create(gpa: Allocator, c: *abi.Core, addr: []const u8, name: []const u8, role: []const u8) !*Remote {
        const k = try ninep.transport.dial(addr);
        var cl = Client.init(gpa, k) catch |e| {
            k.close();
            return e;
        };
        errdefer cl.deinit();
        try cl.version();
        const root = try cl.attach();
        {
            var buf: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try w.writeAll("hello name=");
            try tokenize.quoteValue(&w, name);
            try w.print(" role={s}\n", .{role});
            try cl.put(root, "hello", w.buffered());
        }
        const changes = try cl.walk(root, "changes");
        try cl.open(changes, wire.OREAD);
        const input = try cl.walk(root, "input");
        try cl.open(input, wire.OWRITE);

        const r = try gpa.create(Remote);
        errdefer gpa.destroy(r);
        r.* = .{
            .gpa = gpa,
            .c = c,
            .cl = cl,
            .changes = changes,
            .input = input,
            .rep = .{ .gpa = gpa, .t = c.tree },
            .primary = std.mem.eql(u8, role, "primary"),
        };
        r.rep.host = .{ .ctx = r, .record = onRecord };
        try r.sendRead(0);
        r.reader = try std.Thread.spawn(.{}, readLoop, .{r});
        r.writer = try std.Thread.spawn(.{}, writeLoop, .{r});
        return r;
    }

    pub fn destroy(r: *Remote) void {
        r.mu.lockUncancelable(r.io());
        r.stopping = true;
        r.cond.broadcast(r.io());
        r.mu.unlock(r.io());
        r.cl.t.shutdown();
        if (r.writer) |t| t.join();
        if (r.reader) |t| t.join();
        r.cl.deinit();
        r.rep.deinit();
        r.inbox.deinit(r.gpa);
        r.outbox.deinit(r.gpa);
        r.input_err.deinit(r.gpa);
        r.gpa.destroy(r);
    }

    fn sendRead(r: *Remote, off: u64) !void {
        r.send_mu.lockUncancelable(r.io());
        defer r.send_mu.unlock(r.io());
        try r.cl.send(tag_changes, wire.p9.Tread{ .fid = r.changes, .offset = off, .count = r.cl.msize - 24 });
    }

    fn readLoop(r: *Remote) void {
        var off: u64 = 0;
        while (true) {
            const f = r.cl.recv() catch break;
            switch (f.tag) {
                tag_changes => {
                    const data: []const u8 = switch (f.msg) {
                        .Rread => |x| x.data.bytes,
                        else => "",
                    };
                    if (data.len == 0) break; // end of file, or Rerror
                    r.mu.lockUncancelable(r.io());
                    r.inbox.appendSlice(r.gpa, data) catch {};
                    r.mu.unlock(r.io());
                    r.c.wake();
                    off += data.len;
                    r.sendRead(off) catch break;
                },
                tag_input => {
                    r.mu.lockUncancelable(r.io());
                    if (f.msg == .Rerror) {
                        r.input_err.clearRetainingCapacity();
                        r.input_err.appendSlice(r.gpa, f.msg.Rerror.ename) catch {};
                        std.log.warn("uit_render_dial: input: {s}", .{f.msg.Rerror.ename});
                    }
                    r.writing = false;
                    r.cond.broadcast(r.io());
                    r.mu.unlock(r.io());
                },
                else => {},
            }
        }
        r.mu.lockUncancelable(r.io());
        r.ended = true;
        r.writing = false;
        r.cond.broadcast(r.io());
        r.mu.unlock(r.io());
        r.c.wake();
    }

    fn writeLoop(r: *Remote) void {
        var chunk: std.ArrayList(u8) = .empty;
        defer chunk.deinit(r.gpa);
        const max = r.cl.msize - 24;
        while (true) {
            r.mu.lockUncancelable(r.io());
            while (!r.stopping and !r.ended and (r.writing or r.outbox.items.len == 0)) r.cond.waitUncancelable(r.io(), &r.mu);
            if (r.stopping or r.ended) {
                r.mu.unlock(r.io());
                return;
            }
            // Whole lines, as many as fit one Twrite.
            const all = r.outbox.items;
            const n = if (all.len <= max) all.len else if (std.mem.lastIndexOfScalar(u8, all[0..max], '\n')) |nl| nl + 1 else max;
            chunk.clearRetainingCapacity();
            chunk.appendSlice(r.gpa, all[0..n]) catch {};
            const rest = r.outbox.items.len - chunk.items.len;
            std.mem.copyForwards(u8, r.outbox.items[0..rest], r.outbox.items[chunk.items.len..]);
            r.outbox.shrinkRetainingCapacity(rest);
            r.writing = true;
            r.mu.unlock(r.io());

            r.send_mu.lockUncancelable(r.io());
            r.cl.send(tag_input, wire.p9.Twrite{ .fid = r.input, .offset = 0, .data = .{ .bytes = chunk.items } }) catch {
                r.send_mu.unlock(r.io());
                return;
            };
            r.send_mu.unlock(r.io());
        }
    }

    // -----------------------------------------------------------------
    // Owner thread

    /// Applies what the stream said since the last pump.
    pub fn pump(r: *Remote) void {
        r.mu.lockUncancelable(r.io());
        const bytes = r.inbox.toOwnedSlice(r.gpa) catch &.{};
        const ended = r.ended;
        r.mu.unlock(r.io());
        defer r.gpa.free(bytes);
        if (bytes.len > 0) r.rep.feed(bytes) catch |e| {
            std.log.warn("uit_render_dial: stream: {t}", .{e});
        };
        if (r.rep.errors.items.len > 0) {
            std.log.warn("uit_render_dial: {s}", .{std.mem.trimEnd(u8, r.rep.errors.items, "\n")});
            r.rep.errors.clearRetainingCapacity();
        }
        if (ended and !r.exit_told) r.exited("");
    }

    fn exited(r: *Remote, status: []const u8) void {
        r.exit_told = true;
        abi.setExit(r.c, status);
    }

    fn onRecord(ctx: ?*anyopaque, rec: *const Ctl) void {
        const r: *Remote = @ptrCast(@alignCast(ctx.?));
        r.record(rec) catch |e| std.log.warn("uit_render_dial: {s}: {t}", .{ rec.verb, e });
    }

    /// What the replica doesn't apply as a write: the host hears it as the
    /// command a local app would have made.
    fn record(r: *Remote, rec: *const Ctl) !void {
        const t = r.c.tree;
        const eq = std.mem.eql;
        const v = rec.verb;
        if (eq(u8, v, "answer")) {
            if (rec.words.len < 2) return;
            const seq = std.fmt.parseInt(u64, rec.words[0], 10) catch return;
            return t.hostCmd(.{ .tag = .answer, .seq = seq, .answer = rec.words[1] });
        }
        if (eq(u8, v, "redraw")) return t.hostCmd(.{ .tag = .redraw, .win = if (rec.words.len > 0) rec.words[0] else "main" });
        if (eq(u8, v, "quit")) return t.hostCmd(.{ .tag = .quit });
        if (eq(u8, v, "exit")) return r.exited(if (rec.words.len > 0) rec.words[0] else "");
        if (eq(u8, v, "action")) {
            if (rec.words.len < 1) return;
            const num = struct {
                fn f(s: ?[]const u8) i32 {
                    return std.fmt.parseInt(i32, s orelse return -1, 10) catch -1;
                }
            }.f;
            return t.hostCmd(.{ .tag = .set_action, .name = rec.words[0], .flag = num(rec.attr("enabled")), .flag2 = num(rec.attr("check")) });
        }
        if (eq(u8, v, "verb")) {
            if (rec.words.len < 2) return;
            const h = r.nodeAt(rec.words[0]) orelse return;
            return t.hostCmd(.{ .tag = .component_verb, .node = h, .ctl = .{ .verb = rec.words[1], .words = rec.words[2..], .attrs = rec.attrs } });
        }
        if (eq(u8, v, "window-ctl")) {
            // state, set and destroy came in as writes and made their own.
            if (rec.words.len < 2) return;
            const cv = rec.words[1];
            if (eq(u8, cv, "state") or eq(u8, cv, "set") or eq(u8, cv, "destroy")) return;
            return t.hostCmd(.{ .tag = .window_ctl, .win = rec.words[0], .ctl = .{ .verb = cv, .words = rec.words[2..], .attrs = rec.attrs } });
        }
        // dragging: the drag's number, for `drag end`; not used yet.
    }

    fn nodeAt(r: *Remote, path: []const u8) ?Handle {
        if (!std.mem.startsWith(u8, path, "win/")) return null;
        const rest = path["win/".len..];
        const st = r.c.tree.current();
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const wn = st.win(rest[0 .. slash orelse rest.len]) orelse return null;
        const rel = if (slash) |s| rest[s + 1 ..] else return wn.root;
        var buf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        return treem.path.resolveNode(st, fba.allocator(), wn.root, rel, null) catch null;
    }

    // -----------------------------------------------------------------
    // Input: the C ABI's calls as lines

    /// A line for `input`, queued for the writer.
    pub const Line = struct {
        r: *Remote,
        aw: std.Io.Writer.Allocating,

        pub fn attr(l: *Line, k: []const u8, v: []const u8) !void {
            try l.aw.writer.print(" {s}=", .{k});
            try tokenize.quoteValue(&l.aw.writer, v);
        }

        /// `win=W node=PATH` for `h`, window-relative. False when the node
        /// isn't in a window.
        pub fn at(l: *Line, h: Handle) !bool {
            const st = l.r.c.tree.current();
            const n = st.node(h) orelse return false;
            const w = st.winOfRoot(n.root) orelse return false;
            try l.attr("win", w.nameStr());
            if (h == n.root) {
                try l.attr("node", ".");
                return true;
            }
            const p = try st.relPathAlloc(l.r.gpa, h);
            defer l.r.gpa.free(p);
            try l.attr("node", p);
            return true;
        }

        pub fn send(l: *Line) !void {
            defer l.aw.deinit();
            try l.aw.writer.writeByte('\n');
            const r = l.r;
            r.mu.lockUncancelable(r.io());
            defer r.mu.unlock(r.io());
            try r.outbox.appendSlice(r.gpa, l.aw.written());
            r.cond.broadcast(r.io());
        }

        pub fn drop(l: *Line) void {
            l.aw.deinit();
        }
    };

    pub fn line(r: *Remote, verb: []const u8) !Line {
        var l: Line = .{ .r = r, .aw = .init(r.gpa) };
        try l.aw.writer.writeAll(verb);
        return l;
    }

    pub fn emit(r: *Remote, h: Handle, name: []const u8, attrs: []const abi.UitAttr) !void {
        var l = try r.line("event ");
        errdefer l.drop();
        try tokenize.quoteWord(&l.aw.writer, name);
        if (!try l.at(h)) return error.NotFound;
        for (attrs) |x| try l.attr(x.name.slice(), x.value.slice());
        try l.send();
    }

    pub fn request(r: *Remote, h: Handle, name: []const u8, attrs: []const abi.UitAttr, default: []const u8) !u64 {
        var l = try r.line("request ");
        errdefer l.drop();
        try tokenize.quoteWord(&l.aw.writer, name);
        if (!try l.at(h)) return error.NotFound;
        const id = r.next_request;
        r.next_request += 1;
        try l.aw.writer.print(" id={d}", .{id});
        try l.attr("default", default);
        for (attrs) |x| try l.attr(x.name.slice(), x.value.slice());
        try l.send();
        return id;
    }

    pub fn mirror(r: *Remote, h: Handle, file: []const u8, value: []const u8) !void {
        var l = try r.line("mirror");
        errdefer l.drop();
        if (!try l.at(h)) return error.NotFound;
        try l.attr("file", file);
        try l.attr("value", value);
        try l.send();
    }

    pub fn bounds(r: *Remote, h: Handle, b: [4]i64) !void {
        if (!r.primary) return;
        var l = try r.line("bounds");
        errdefer l.drop();
        if (!try l.at(h)) return l.drop();
        try l.aw.writer.print(" value='{d} {d} {d} {d}'", .{ b[0], b[1], b[2], b[3] });
        try l.send();
    }

    pub fn winLine(r: *Remote, verb: []const u8, win: []const u8) !void {
        var l = try r.line(verb);
        errdefer l.drop();
        try l.attr("win", win);
        try l.send();
    }

    pub fn key(r: *Remote, win: []const u8, stroke: []const u8) !void {
        var l = try r.line("key");
        errdefer l.drop();
        try l.attr("win", win);
        try l.attr("stroke", stroke);
        try l.send();
    }

    pub fn menu(r: *Remote, id: []const u8) !void {
        var l = try r.line("menu");
        errdefer l.drop();
        try l.attr("item", id);
        try l.send();
    }

    pub fn appearance(r: *Remote, dark: bool) !void {
        if (!r.primary) return;
        var l = try r.line("appearance");
        errdefer l.drop();
        try l.attr("mode", if (dark) "dark" else "light");
        try l.send();
    }
};
