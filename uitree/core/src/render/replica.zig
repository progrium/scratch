//! A replica: a change stream (protocols/render.md) applied to a local
//! tree, as the app's own writes. What the stream says is `$ui` as the app
//! made it, so replaying it into an empty tree must give the same
//! documents: that is the checker (`uitree-headless --check-render`), and
//! with a 9P client in front of it, a renderer that draws a remote app
//! through the C ABI it already speaks.
//!
//! Records become writes to the local tree, each the write that makes it:
//! `new TYPE win/W/a/b ...` is `new TYPE a/b ...` on `win/W/ctl`, `set` and
//! `delete` the same, `mirror` the tree's own mirror (what uit_mirror does), `window` the root `ctl`'s `window`, `theme`, `keys`
//! and `menu` their files. What only a renderer acts on (`answer`,
//! `redraw`, `quit`, `exit`, `dragging`, `verb`, `window-ctl`, `action`)
//! goes
//! to the host's `record` callback instead.

const std = @import("std");
const proto = @import("../proto/root.zig");
const treem = @import("../tree/root.zig");
const termview = @import("termview.zig");
const termrec = @import("term.zig");

const Allocator = std.mem.Allocator;
const Ctl = proto.ctl.Ctl;
const Writer = std.Io.Writer;

pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// `asset NAME`: the asset's bytes, or null to skip it.
    asset: ?*const fn (ctx: ?*anyopaque, a: Allocator, name: []const u8) ?[]const u8 = null,
    /// A record the replica doesn't apply to the tree.
    record: ?*const fn (ctx: ?*anyopaque, rec: *const Ctl) void = null,
};

pub const Replica = struct {
    gpa: Allocator,
    t: *treem.Tree,
    host: Host = .{},
    /// Bytes not yet a whole record.
    buf: std.ArrayList(u8) = .empty,
    /// The pump the last `end` closed.
    seq: u64 = 0,
    /// Frames applied (`end` records seen).
    frames: u64 = 0,
    /// Writes the local tree refused, as `PATH: DATA: error` lines; for
    /// the checker. Cleared by the caller.
    errors: std.ArrayList(u8) = .empty,
    /// Terminal nodes' cells, from `term`, `term-styles` and `term-rows`
    /// (render.md § Terminals). The local tree makes no engines for them.
    views: termview.Views = .{},

    pub fn deinit(r: *Replica) void {
        r.buf.deinit(r.gpa);
        r.errors.deinit(r.gpa);
        r.views.deinit(r.gpa);
    }

    /// The terminal node at a stream path, in the local tree.
    fn termAt(r: *Replica, a: Allocator, path: []const u8) ?treem.Handle {
        const at = split(path) orelse return null;
        const st = r.t.current();
        const wn = st.win(at.win) orelse return null;
        const h = if (at.rel.len == 0) wn.root else treem.path.resolveNode(st, a, wn.root, at.rel, null) catch return null;
        const n = st.node(h) orelse return null;
        if (!std.mem.eql(u8, n.ty.name, treem.term.type_name)) return null;
        return h;
    }

    /// `term`, `term-styles`, `term-rows`.
    fn termRecord(r: *Replica, a: Allocator, c: *const Ctl) !void {
        if (c.words.len < 1) return;
        const h = r.termAt(a, c.words[0]) orelse return;
        r.views.prune(r.gpa, r.t.current());
        const v = try r.views.getOrMake(r.gpa, h);
        const eq = std.mem.eql;
        const res = if (eq(u8, c.verb, "term"))
            v.setTerm(termrec.parseTerm(c.*) catch return r.refuse(a, c))
        else if (eq(u8, c.verb, "term-styles"))
            v.setStyles(std.fmt.parseInt(u32, c.attr("first") orelse "0", 10) catch return r.refuse(a, c), c.attr("text") orelse "")
        else
            v.setRows(c.attr("text") orelse "");
        res catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return r.refuse(a, c);
        };
    }

    fn refuse(r: *Replica, a: Allocator, c: *const Ctl) !void {
        try r.errors.appendSlice(r.gpa, try std.fmt.allocPrint(a, "{s} {s}: bad syntax\n", .{ c.verb, if (c.words.len > 0) c.words[0] else "" }));
    }

    /// Appends stream bytes and applies every whole record in them.
    /// Owner thread of the local tree.
    pub fn feed(r: *Replica, bytes: []const u8) !void {
        try r.buf.appendSlice(r.gpa, bytes);
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        var pos: usize = 0;
        while (true) {
            _ = arena.reset(.retain_capacity);
            const got = try nextRecord(arena.allocator(), r.buf.items, pos) orelse break;
            pos = got.next;
            try r.apply(arena.allocator(), &got.rec);
        }
        // Keep what's left.
        const rest = r.buf.items.len - pos;
        std.mem.copyForwards(u8, r.buf.items[0..rest], r.buf.items[pos..]);
        r.buf.shrinkRetainingCapacity(rest);
    }

    fn write(r: *Replica, a: Allocator, path: []const u8, data: []const u8) !void {
        r.t.apply(.{ .write = .{ .session = 1, .path = path, .data = data } }) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            const msg = try std.fmt.allocPrint(a, "{s}: {s}: {s}\n", .{ path, firstLine(data), r.t.lastError() });
            try r.errors.appendSlice(r.gpa, msg);
        };
    }

    fn writeCtl(r: *Replica, a: Allocator, path: []const u8, c: Ctl) !void {
        var aw: Writer.Allocating = .init(a);
        try c.format(&aw.writer);
        try r.write(a, path, aw.written());
    }

    /// A `new` or `set` on the window's ctl. A value too big for one ctl
    /// write (the app wrote the file itself) goes to its file after.
    fn nodeCtl(r: *Replica, a: Allocator, at: At, c: Ctl) !void {
        const big = 32 * 1024;
        var small: std.ArrayList(proto.ctl.Attr) = .empty;
        var later: std.ArrayList(proto.ctl.Attr) = .empty;
        for (c.attrs) |x| try (if (x.value.len > big) &later else &small).append(a, x);
        var cc = c;
        cc.attrs = small.items;
        try r.writeCtl(a, try winCtl(a, at.win), cc);
        for (later.items) |x| {
            const p = if (at.rel.len == 0)
                try std.fmt.allocPrint(a, "win/{s}/{s}", .{ at.win, x.key })
            else
                try std.fmt.allocPrint(a, "win/{s}/{s}/{s}", .{ at.win, at.rel, x.key });
            try r.write(a, p, x.value);
        }
    }

    fn apply(r: *Replica, a: Allocator, c: *const Ctl) !void {
        const v = c.verb;
        const eq = std.mem.eql;
        if (eq(u8, v, "snap")) {
            r.views.clear(r.gpa);
            return r.clear(a);
        }
        if (eq(u8, v, "term") or eq(u8, v, "term-styles") or eq(u8, v, "term-rows")) return r.termRecord(a, c);
        if (eq(u8, v, "batch")) return;
        if (eq(u8, v, "end")) {
            if (c.words.len > 0) r.seq = std.fmt.parseInt(u64, c.words[0], 10) catch r.seq;
            r.frames += 1;
            return;
        }
        if (eq(u8, v, "new")) {
            if (c.words.len < 2) return;
            const at = split(c.words[1]) orelse return;
            if (at.rel.len == 0) {
                // The window's root: it exists with the window.
                var words = try a.alloc([]const u8, c.words.len - 1);
                words[0] = ".";
                @memcpy(words[1..], c.words[2..]);
                return r.nodeCtl(a, at, .{ .verb = "set", .words = words, .attrs = c.attrs, .style = c.style });
            }
            var words = try a.dupe([]const u8, c.words);
            words[1] = at.rel;
            return r.nodeCtl(a, at, .{ .verb = "new", .words = words, .attrs = c.attrs, .style = c.style });
        }
        if (eq(u8, v, "set") or eq(u8, v, "delete")) {
            if (c.words.len < 1) return;
            const at = split(c.words[0]) orelse return;
            // A window's root deleted is the window gone.
            if (at.rel.len == 0 and eq(u8, v, "delete")) return r.write(a, try winCtl(a, at.win), "destroy");
            var words = try a.dupe([]const u8, c.words);
            words[0] = if (at.rel.len == 0) "." else at.rel;
            return r.nodeCtl(a, at, .{ .verb = v, .words = words, .attrs = c.attrs, .style = c.style });
        }
        if (eq(u8, v, "mirror")) {
            // Another renderer's input: as uit_mirror, not an app write.
            if (c.words.len < 1) return;
            const at = split(c.words[0]) orelse return;
            const st = r.t.current();
            const wn = st.win(at.win) orelse return;
            const h = if (at.rel.len == 0) wn.root else treem.path.resolveNode(st, a, wn.root, at.rel, null) catch return;
            for (c.attrs) |x| r.t.mirror(h, x.key, x.value) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                try r.errors.appendSlice(r.gpa, try std.fmt.allocPrint(a, "mirror {s} {s}: {s}\n", .{ c.words[0], x.key, r.t.lastError() }));
            };
            return;
        }
        if (eq(u8, v, "window")) {
            if (c.words.len < 1) return;
            var attrs: std.ArrayList(proto.ctl.Attr) = .empty;
            var state: []const u8 = "normal";
            for (c.attrs) |x| {
                if (eq(u8, x.key, "state")) state = x.value else try attrs.append(a, x);
            }
            if (r.t.current().win(c.words[0]) == null)
                try r.writeCtl(a, "ctl", .{ .verb = "window", .words = c.words[0..1], .attrs = attrs.items })
            else if (attrs.items.len > 0)
                try r.writeCtl(a, try winCtl(a, c.words[0]), .{ .verb = "set", .words = &.{"."}, .attrs = attrs.items });
            return r.writeCtl(a, try winCtl(a, c.words[0]), .{ .verb = "state", .words = &[_][]const u8{state} });
        }
        if (eq(u8, v, "window-ctl")) {
            // What changes the window as the app sees it is applied; all
            // of it goes to the host too, which acts on the rest (notify,
            // ask, ...).
            if (r.host.record) |f| f(r.host.ctx, c);
            if (c.words.len < 2) return;
            const win = c.words[0];
            const cv = c.words[1];
            if (r.t.current().win(win) == null) return;
            if (eq(u8, cv, "set")) {
                var words = try a.alloc([]const u8, c.words.len - 1);
                words[0] = ".";
                @memcpy(words[1..], c.words[2..]);
                return r.writeCtl(a, try winCtl(a, win), .{ .verb = "set", .words = words, .attrs = c.attrs });
            }
            if (eq(u8, cv, "state") or eq(u8, cv, "destroy"))
                return r.writeCtl(a, try winCtl(a, win), .{ .verb = cv, .words = c.words[2..], .attrs = c.attrs });
            return;
        }
        if (eq(u8, v, "overlay")) {
            if (c.words.len < 2) return;
            const at = split(c.words[1]) orelse return;
            const p = try std.fmt.allocPrint(a, "win/{s}/{s}/ctl", .{ at.win, at.rel });
            return r.write(a, p, c.words[0]);
        }
        if (eq(u8, v, "focus")) {
            if (c.words.len < 2) return;
            const at = split(c.words[1]);
            const p = try std.fmt.allocPrint(a, "win/{s}/focus", .{c.words[0]});
            return r.write(a, p, if (at) |x| x.rel else "");
        }
        if (eq(u8, v, "theme")) {
            if (c.attr("name")) |n| try r.write(a, "theme/name", n);
            if (c.attr("mode")) |m| try r.write(a, "theme/mode", m);
            return;
        }
        if (eq(u8, v, "clip")) return r.write(a, "clip", c.attr("text") orelse "");
        if (eq(u8, v, "keys")) return r.write(a, "keys", c.attr("text") orelse "");
        if (eq(u8, v, "menu-bar")) return r.write(a, "menu/bar", try std.mem.join(a, " ", c.words));
        if (eq(u8, v, "menu")) {
            if (c.words.len < 1) return;
            return r.write(a, try std.fmt.allocPrint(a, "menu/{s}", .{c.words[0]}), c.attr("text") orelse "");
        }
        if (eq(u8, v, "asset")) {
            if (c.words.len < 1) return;
            const f = r.host.asset orelse return;
            const bytes = f(r.host.ctx, a, c.words[0]) orelse return;
            return r.write(a, try std.fmt.allocPrint(a, "asset/{s}", .{c.words[0]}), bytes);
        }
        if (r.host.record) |f| f(r.host.ctx, c);
    }

    /// `snap`: the stream is about to say the whole tree. Every window's
    /// content goes; windows the snapshot names again come back.
    fn clear(r: *Replica, a: Allocator) !void {
        const st = r.t.current();
        for (st.wins.items) |w| {
            const root = st.node(w.root) orelse continue;
            for (root.order.items) |h| {
                const n = st.node(h) orelse continue;
                const p = try winCtl(a, w.nameStr());
                var aw: Writer.Allocating = .init(a);
                try aw.writer.writeAll("delete ");
                try proto.tokenize.quoteWord(&aw.writer, n.nameStr());
                try r.write(a, p, aw.written());
            }
        }
    }
};

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

const At = struct { win: []const u8, rel: []const u8 };

/// `win/W/a/b` -> (W, a/b); `win/W` -> (W, "").
fn split(path: []const u8) ?At {
    if (!std.mem.startsWith(u8, path, "win/")) return null;
    const rest = path["win/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .{ .win = rest, .rel = "" };
    return .{ .win = rest[0..slash], .rel = rest[slash + 1 ..] };
}

fn winCtl(a: Allocator, win: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "win/{s}/ctl", .{win});
}

const Got = struct { rec: Ctl, next: usize };

/// The record starting at `pos`, with its here-values read, and where the
/// next one starts; null while the bytes don't hold all of it.
pub fn nextRecord(a: Allocator, buf: []const u8, pos_in: usize) !?Got {
    var pos = pos_in;
    while (true) {
        const nl = std.mem.indexOfScalarPos(u8, buf, pos, '\n') orelse return null;
        const line = buf[pos..nl];
        pos = nl + 1;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        const ts = proto.ctl.tokens(a, line, null) catch return error.BadStream;
        const b = proto.ctl.build(a, ts, true, null) catch return error.BadStream;
        var c = b.ctl;
        if (b.heres.len > 0) {
            const words = try a.dupe([]const u8, c.words);
            const attrs = try a.dupe(proto.ctl.Attr, c.attrs);
            for (b.heres) |h| {
                var lines: std.ArrayList([]const u8) = .empty;
                while (true) {
                    const e = std.mem.indexOfScalarPos(u8, buf, pos, '\n') orelse return null;
                    const l = buf[pos..e];
                    pos = e + 1;
                    if (proto.ctl.isEndLine(l, h.marker)) break;
                    try lines.append(a, l);
                }
                const body = try std.mem.join(a, "\n", lines.items);
                if (h.is_attr) attrs[h.index].value = body else words[h.index] = body;
            }
            c.words = words;
            c.attrs = attrs;
        }
        return .{ .rec = c, .next = pos };
    }
}

test "nextRecord waits for a whole here-value" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = "keys text=<<END\n= inc\n- dec\nEND\nend 3\n";
    try t.expect(try nextRecord(a, s[0..20], 0) == null);
    const g = (try nextRecord(a, s, 0)).?;
    try t.expectEqualStrings("keys", g.rec.verb);
    try t.expectEqualStrings("= inc\n- dec", g.rec.attr("text").?);
    const g2 = (try nextRecord(a, s, g.next)).?;
    try t.expectEqualStrings("end", g2.rec.verb);
    try t.expectEqual(s.len, g2.next);
}
