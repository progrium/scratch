//! Property tests: every format prints and parses back to the same value,
//! for many random values (port of uitreefs/crates/proto/tests/roundtrip.rs),
//! and a fuzz test on `ctl.parseWrite`.
//!
//! A small xorshift generator keeps it deterministic; set the seed in
//! `Rng.init` to reproduce a failure. Run the fuzzer with
//! `zig build test --fuzz`; plain `zig build test` runs the corpus and
//! a few thousand random writes.

const std = @import("std");
const tokenize = @import("tokenize.zig");
const err = @import("err.zig");
const ctl = @import("ctl.zig");
const style = @import("style.zig");
const event = @import("event.zig");
const doc = @import("doc.zig");
const lines = @import("lines.zig");

const Allocator = std.mem.Allocator;
const Attr = ctl.Attr;
const t = std.testing;

const cases = 2000;

const Rng = struct {
    s: u64,
    a: Allocator,

    fn init(a: Allocator) Rng {
        return .{ .s = 0x9e3779b97f4a7c15, .a = a };
    }
    fn next(r: *Rng) u64 {
        var x = r.s;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        r.s = x;
        return x;
    }
    fn below(r: *Rng, n: usize) usize {
        return @intCast(r.next() % n);
    }
    fn coin(r: *Rng) bool {
        return r.next() & 1 == 1;
    }
    fn pick(r: *Rng, comptime T: type, xs: []const T) T {
        return xs[r.below(xs.len)];
    }
    fn string(r: *Rng, alphabet: []const []const u8, min: usize, max: usize) []const u8 {
        const n = min + r.below(max - min + 1);
        var out: std.ArrayList(u8) = .empty;
        for (0..n) |_| out.appendSlice(r.a, r.pick([]const u8, alphabet)) catch @panic("oom");
        return out.items;
    }
    /// Anything at all: blanks, quotes, `=`, newlines, UTF-8.
    fn any(r: *Rng) []const u8 {
        return r.string(&any_chars, 0, 12);
    }
    /// One line of anything.
    fn single(r: *Rng) []const u8 {
        return r.string(&single_chars, 0, 10);
    }
    /// Text for a TSV field: no tab, no newline.
    fn field(r: *Rng) []const u8 {
        return r.string(&field_chars, 0, 10);
    }
    fn nonempty(r: *Rng) []const u8 {
        const s = r.field();
        return if (s.len == 0) "x" else s;
    }
    fn word(r: *Rng) []const u8 {
        return r.string(&word_chars, 1, 8);
    }
    fn ident(r: *Rng) []const u8 {
        return std.mem.concat(r.a, u8, &.{ r.string(&letter_chars, 1, 1), r.string(&ident_chars, 0, 8) }) catch @panic("oom");
    }
    fn bareWord(r: *Rng) []const u8 {
        return std.mem.concat(r.a, u8, &.{ r.string(&letter_chars, 1, 1), r.string(&.{ "a", "z", "-", "_", "0" }, 0, 6) }) catch @panic("oom");
    }
    fn num(r: *Rng) f32 {
        const n = (@as(f32, @floatFromInt(r.below(200000))) - 100000.0) / r.pick(f32, &.{ 1, 10, 100, 4 });
        return if (n == 0) 0 else n;
    }
    fn attrs(r: *Rng, value: *const fn (*Rng) []const u8) []const Attr {
        const out = r.a.alloc(Attr, r.below(4)) catch @panic("oom");
        for (out) |*x| x.* = .{ .key = r.ident(), .value = value(r) };
        return out;
    }
    fn list(r: *Rng, max: usize, f: *const fn (*Rng) []const u8) []const []const u8 {
        const out = r.a.alloc([]const u8, r.below(max)) catch @panic("oom");
        for (out) |*x| x.* = f(r);
        return out;
    }
};

const any_chars = [_][]const u8{ "a", "b", "Z", "0", " ", " ", "\t", "'", "'", "=", "<", "\n", "é", "日", "#", "-", ":" };
const single_chars = [_][]const u8{ "a", "b", "Z", "0", " ", "\t", "'", "'", "=", "<", "é", "日", "#", "-", ":" };
const field_chars = [_][]const u8{ "a", "b", "Z", "0", " ", "'", "=", "<", "é", "#", "-", ":" };
const word_chars = [_][]const u8{ "a", "b", "z", "0", "9", "-", "_", ":", "/", "." };
const letter_chars = [_][]const u8{ "a", "k", "z", "_" };
const ident_chars = [_][]const u8{ "a", "k", "z", "_", "0", ":", "." };

fn fmt(a: Allocator, x: anytype) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    x.format(&aw.writer) catch @panic("oom");
    return aw.written();
}

test "quote and tokenize" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var r: Rng = .init(a);
    for (0..cases) |_| {
        const words = r.list(5, Rng.any);
        var aw: std.Io.Writer.Allocating = .init(a);
        const sep = if (r.coin()) " " else " \t ";
        for (words, 0..) |w, i| {
            if (i > 0) try aw.writer.writeAll(sep);
            try tokenize.quote(&aw.writer, w);
        }
        const toks = try tokenize.tokenize(a, aw.written());
        try t.expectEqual(words.len, toks.len);
        for (words, toks) |w, tk| try t.expectEqualStrings(w, tk.text);
    }
}

/// A here-value always ends in a newline.
fn hereSafe(r: *Rng) []const u8 {
    const v = r.any();
    if (std.mem.indexOfScalar(u8, v, '\n') == null or v[v.len - 1] == '\n') return v;
    return std.mem.concat(r.a, u8, &.{ v, "\n" }) catch @panic("oom");
}

fn randomCtl(r: *Rng) ctl.Ctl {
    return .{
        .verb = r.word(),
        .words = r.list(4, if (r.coin()) Rng.single else hereSafe),
        .attrs = r.attrs(if (r.coin()) Rng.single else hereSafe),
        .style = if (r.coin()) r.list(4, Rng.word) else null,
    };
}

test "ctl commands" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var r: Rng = .init(a);
    for (0..cases) |_| {
        const cmds = try a.alloc(ctl.Ctl, 1 + r.below(4));
        var aw: std.Io.Writer.Allocating = .init(a);
        for (cmds) |*c| {
            c.* = randomCtl(&r);
            try c.format(&aw.writer);
            try aw.writer.writeByte('\n');
        }
        const back = ctl.parseWrite(a, aw.written()) catch |e| {
            std.debug.print("{t} on {f}\n", .{ e, std.zig.fmtString(aw.written()) });
            return e;
        };
        try t.expectEqualDeep(@as([]const ctl.Ctl, cmds), @as([]const ctl.Ctl, back));
    }
}

fn styleArg(r: *Rng) style.Arg {
    return switch (r.below(5)) {
        0 => .{ .px = r.num() },
        1 => .{ .percent = r.num() },
        2 => .{ .rem = r.num() },
        3 => .{ .color = .{ .r = @truncate(r.next()), .g = @truncate(r.next()), .b = @truncate(r.next()), .a = if (r.coin()) 255 else @truncate(r.next()) } },
        else => blk: {
            const id = r.a.dupe(u8, r.ident()) catch @panic("oom");
            std.mem.replaceScalar(u8, id, ':', '_');
            break :blk .{ .token = id };
        },
    };
}

fn styleWord(r: *Rng) style.StyleWord {
    const name = r.string(&.{ "a", "b", "_", "1", "-" }, 1, 8);
    if (r.below(8) == 0) return .{ .group = name, .name = "group" };
    const state: ?style.State = switch (r.below(8)) {
        0 => .hover,
        1 => .active,
        2 => .focus,
        3 => .disabled,
        4 => .drop_over,
        5 => .{ .group_hover = r.string(&.{ "g", "r", "_", "-" }, 1, 5) },
        else => null,
    };
    const args = r.a.alloc(style.Arg, r.below(4)) catch @panic("oom");
    for (args) |*x| x.* = styleArg(r);
    return .{ .state = state, .name = name, .args = args };
}

test "style words" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var r: Rng = .init(a);
    for (0..cases) |_| {
        const words = try a.alloc(style.StyleWord, r.below(6));
        for (words) |*w| w.* = styleWord(&r);
        var aw: std.Io.Writer.Allocating = .init(a);
        try style.format(&aw.writer, words);
        try t.expectEqualDeep(@as([]const style.StyleWord, words), @as([]const style.StyleWord, try style.parse(a, aw.written())));
    }
}

test "events" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var r: Rng = .init(a);
    for (0..cases) |_| {
        var attrs: std.ArrayList(Attr) = .empty;
        for (0..r.below(5)) |_| {
            const k = r.ident();
            if (std.mem.eql(u8, k, "seq")) continue;
            try attrs.append(a, .{ .key = k, .value = r.any() });
        }
        var ev: event.Event = .{ .name = r.word(), .key = r.ident(), .path = r.ident(), .attrs = attrs.items, .seq = r.next() >> 12 };
        var aw: std.Io.Writer.Allocating = .init(a);
        try event.format(&aw.writer, ev);
        const l = aw.written();
        // Always exactly one line; newlines in values become spaces.
        try t.expect(l[l.len - 1] == '\n' and std.mem.indexOfScalar(u8, l[0 .. l.len - 1], '\n') == null);
        for (attrs.items) |*x| {
            const v = try a.dupe(u8, x.value);
            std.mem.replaceScalar(u8, v, '\n', ' ');
            x.value = v;
        }
        ev.attrs = attrs.items;
        try t.expectEqualDeep(ev, try event.parse(a, l));
    }
}

fn docValue(r: *Rng) []const u8 {
    return switch (r.below(4)) {
        0 => r.any(),
        1 => std.mem.concat(r.a, u8, &.{ "<<", r.word() }) catch @panic("oom"),
        else => r.single(),
    };
}

fn docNode(r: *Rng, depth: usize) doc.Node {
    var n: doc.Node = .{
        .type = r.word(),
        .name = r.word(),
        .words = r.list(3, Rng.bareWord),
        .attrs = r.attrs(docValue),
        .style = if (r.coin()) r.list(4, Rng.word) else null,
    };
    if (depth < 4) {
        const cs = r.a.alloc(doc.Node, r.below(4)) catch @panic("oom");
        for (cs) |*c| c.* = docNode(r, depth + 1);
        n.children = cs;
    }
    return n;
}

test "tree documents" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var r: Rng = .init(a);
    for (0..cases / 4) |_| {
        const n = docNode(&r, 0);
        const p = fmtDoc(a, n);
        const back = doc.parse(a, p) catch |e| {
            std.debug.print("{t} on {f}\n", .{ e, std.zig.fmtString(p) });
            return e;
        };
        try t.expectEqualDeep(n, back);
        try t.expectEqualStrings(p, fmtDoc(a, back));
    }
}

fn fmtDoc(a: Allocator, n: doc.Node) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    doc.print(&aw.writer, n) catch @panic("oom");
    return aw.written();
}

fn check(comptime T: type, a: Allocator, recs: []const T) !void {
    var aw: std.Io.Writer.Allocating = .init(a);
    try lines.printLines(&aw.writer, recs);
    const back = lines.parseLines(T, a, aw.written(), null) catch |e| {
        std.debug.print("{t} on {f}\n", .{ e, std.zig.fmtString(aw.written()) });
        return e;
    };
    t.expectEqualDeep(recs, @as([]const T, back)) catch |e| {
        std.debug.print("text: {f}\n", .{std.zig.fmtString(aw.written())});
        return e;
    };
}

fn prefixed(r: *Rng, p: []const u8) []const u8 {
    return std.mem.concat(r.a, u8, &.{ p, r.field() }) catch @panic("oom");
}

test "field formats" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var r: Rng = .init(a);
    for (0..cases / 4) |_| {
        const items = try a.alloc(lines.Item, r.below(6));
        for (items) |*it| it.* = switch (r.below(6)) {
            0 => .separator,
            1 => .{ .group = r.field() },
            else => .{ .entry = .{
                .id = r.nonempty(),
                .label = r.field(),
                .extra = blk: {
                    const xs = try a.alloc([]const u8, r.below(3));
                    for (xs) |*x| x.* = prefixed(&r, "f");
                    break :blk xs;
                },
                .icon = if (r.coin()) r.word() else null,
                .disabled = r.coin(),
            } },
        };
        try check(lines.Item, a, items);

        const cols = try a.alloc(lines.Column, r.below(5));
        for (cols) |*c| c.* = .{
            .id = r.nonempty(),
            .label = r.field(),
            .width = if (r.coin()) r.num() else null,
            .sort = r.coin(),
            .fixed = r.coin(),
            .@"align" = r.pick(?lines.Align, &.{ null, .left, .center, .right }),
        };
        try check(lines.Column, a, cols);

        const rows = try a.alloc(lines.Row, r.below(5));
        for (rows) |*x| x.* = .{ .id = r.nonempty(), .cells = r.list(5, Rng.field) };
        try check(lines.Row, a, rows);

        const tis = try a.alloc(lines.TreeItem, r.below(5));
        for (tis) |*x| x.* = .{
            .id = r.nonempty(),
            .parent = if (r.coin()) prefixed(&r, "p") else null,
            .label = r.field(),
            .icon = if (r.coin()) r.word() else null,
            .disabled = r.coin(),
        };
        try check(lines.TreeItem, a, tis);

        const ds = try a.alloc(lines.DescItem, r.below(5));
        for (ds) |*x| x.* = .{ .label = r.field(), .value = try std.mem.concat(a, u8, &.{ r.field(), "\t", r.field() }) };
        try check(lines.DescItem, a, ds);

        const dgs = try a.alloc(lines.Diagnostic, r.below(5));
        for (dgs) |*x| x.* = .{
            .line = @truncate(r.next()),
            .col = @truncate(r.next()),
            .len = @intCast(r.below(100)),
            .severity = r.pick(lines.Severity, &.{ .@"error", .warning, .info, .hint }),
            .message = try std.mem.concat(a, u8, &.{ r.field(), "\t", r.field() }),
        };
        try check(lines.Diagnostic, a, dgs);

        const cs = try a.alloc(lines.Completion, r.below(5));
        for (cs) |*x| x.* = .{
            .text = r.nonempty(),
            .label = if (r.coin()) prefixed(&r, "l") else null,
            .kind = if (r.coin()) r.field() else null,
            .detail = if (r.coin()) r.field() else null,
        };
        try check(lines.Completion, a, cs);

        const icons = try a.alloc(lines.IconItem, r.below(5));
        for (icons) |*x| x.* = .{
            .id = r.word(),
            .label = r.single(),
            .icon = if (r.coin()) r.word() else null,
            .pos = if (r.coin()) .{ .x = @as(i32, @intCast(r.below(4000))) - 2000, .y = @intCast(r.below(4000)) } else null,
            .selected = r.coin(),
            .extra = blk: {
                const xs = try a.alloc([]const u8, r.below(2));
                for (xs) |*e| e.* = try std.mem.concat(a, u8, &.{ "x.", r.word(), "=", r.word() });
                break :blk xs;
            },
        };
        // A label with a tab would make the line TSV; labels are one line
        // of text without tabs.
        for (icons) |*x| {
            const l = try a.dupe(u8, x.label);
            std.mem.replaceScalar(u8, l, '\t', ' ');
            x.label = l;
        }
        try check(lines.IconItem, a, icons);
    }
}

test "word formats" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var r: Rng = .init(a);
    for (0..cases / 4) |_| {
        // Menus: a valid nesting.
        var menu: std.ArrayList(lines.MenuLine) = .empty;
        var depth: usize = 0;
        for (0..r.below(8)) |_| {
            const kind = r.pick(lines.MenuKind, &.{ .item, .item, .sep, .sub });
            try menu.append(a, if (kind == .sep)
                .{ .depth = depth, .kind = .sep }
            else
                .{ .depth = depth, .kind = kind, .id = r.single(), .attrs = r.attrs(Rng.single) });
            depth = if (kind == .sub) depth + 1 else r.below(depth + 1);
        }
        var aw: std.Io.Writer.Allocating = .init(a);
        try lines.printLines(&aw.writer, menu.items);
        try t.expectEqualDeep(@as([]const lines.MenuLine, menu.items), @as([]const lines.MenuLine, try lines.parseMenu(a, aw.written(), null)));

        const keys = try a.alloc(lines.KeyBinding, r.below(5));
        for (keys) |*k| k.* = .{
            .keys = blk: {
                const xs = try a.alloc([]const u8, 1 + r.below(2));
                for (xs) |*x| x.* = r.single();
                break :blk xs;
            },
            .action = if (r.below(8) == 0) "global" else r.single(),
            .global = r.coin(),
            .attrs = r.attrs(Rng.single),
        };
        try check(lines.KeyBinding, a, keys);

        const ops = try a.alloc(lines.CanvasOp, r.below(5));
        for (ops) |*op| {
            const kind = r.pick(lines.OpKind, &.{ .rect, .circle, .line, .path, .text, .image });
            op.* = .{ .kind = kind, .id = r.single(), .attrs = r.attrs(Rng.single) };
            if (kind == .path) {
                const segs = try a.alloc(lines.PathSeg, 1 + r.below(4));
                for (segs) |*s| {
                    const c = r.pick(struct { u8, usize }, &.{ .{ 'M', 2 }, .{ 'l', 2 }, .{ 'H', 1 }, .{ 'C', 6 }, .{ 'q', 4 }, .{ 'A', 7 }, .{ 'Z', 0 } });
                    const sets: usize = if (c[1] == 0) 0 else 1 + r.below(2);
                    const args = try a.alloc(f32, c[1] * sets);
                    for (args) |*x| x.* = r.num();
                    s.* = .{ .cmd = c[0], .args = args };
                }
                op.path = segs;
            } else {
                const g = try a.alloc(f32, kind.arity());
                for (g) |*x| x.* = r.num();
                op.geom = g;
            }
            if (kind == .text) op.text = r.single();
        }
        try check(lines.CanvasOp, a, ops);
    }
}

test "message lists" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var r: Rng = .init(a);
    for (0..cases / 4) |_| {
        const msgs = try a.alloc(lines.Message, r.below(4));
        for (msgs) |*m| {
            // Body lines never read as headers, and the body has no
            // leading or trailing blank lines.
            const n = r.below(5);
            const body = try a.alloc([]const u8, n);
            for (body, 0..) |*b, i| b.* = if (i > 0 and i + 1 < n and r.below(3) == 0) "" else try std.mem.concat(a, u8, &.{ "> ", r.field() });
            m.* = .{
                .id = r.word(),
                .role = r.pick([]const u8, &lines.roles),
                .time = if (r.coin()) r.word() else "",
                .body = try std.mem.join(a, "\n", body),
            };
        }
        var aw: std.Io.Writer.Allocating = .init(a);
        try lines.printMessages(&aw.writer, msgs);
        try t.expectEqualDeep(@as([]const lines.Message, msgs), @as([]const lines.Message, try lines.parseMessages(a, aw.written(), null)));
    }
}

// ---------------------------------------------------------------------------
// Fuzzing ctl.parseWrite: any bytes either fail with a protocol error, or
// parse to commands that format and parse back to the same commands.

fn checkWrite(input: []const u8) !void {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d: err.Diag = .{};
    const cmds = ctl.parseWriteDiag(a, input, &d) catch |e| {
        if (e == error.OutOfMemory) return e;
        // Every failure is a protocol error with its code set.
        try t.expectEqual(err.Code.fromError(e).?, d.code);
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    for (cmds) |c| {
        try c.format(&aw.writer);
        try aw.writer.writeByte('\n');
    }
    const back = ctl.parseWrite(a, aw.written()) catch |e| {
        std.debug.print("{t}: {f} formatted as {f}\n", .{ e, std.zig.fmtString(input), std.zig.fmtString(aw.written()) });
        return e;
    };
    t.expectEqualDeep(@as([]const ctl.Ctl, cmds), @as([]const ctl.Ctl, back)) catch |e| {
        std.debug.print("{f} formatted as {f}\n", .{ std.zig.fmtString(input), std.zig.fmtString(aw.written()) });
        return e;
    };
}

fn fuzzOne(_: void, smith: *t.Smith) !void {
    var buf: [512]u8 = undefined;
    const n = smith.sliceWeightedBytes(&buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 'a', 'z', 6),
        .value(u8, ' ', 6),
        .value(u8, '\t', 2),
        .value(u8, '\n', 4),
        .value(u8, '\r', 1),
        .value(u8, '\'', 4),
        .value(u8, '=', 4),
        .value(u8, ':', 3),
        .value(u8, '<', 4),
        .value(u8, 'E', 2),
        .value(u8, 'N', 2),
        .value(u8, 'D', 2),
    });
    try checkWrite(buf[0..n]);
}

const corpus = [_][]const u8{
    "new button inc label=+1 primary tag=inc : w=64 hover:bg=accent\n",
    "set list items=<<END\ninbox Inbox\nsent Sent\nEND\n",
    "tree f <<EOF\ndiv f\n  text t\nEOF\n",
    "set x a=<<A b='<<B' c=<<C\none\nA\ntwo\n  C  \n",
    "notify 'Upload failed' type=error action=retry:'Try again'\n",
    "set x 'a b'=c 'k='=v x-=1 =v :\n",
    "set x text=':' ':' : ':' ''\n",
    "set x v=<<END\nEND1\n END\n",
    "set x v=<<END\n\nEND\n",
    "ask close quit\nbegin\ncommit\n",
    "x=1\n",
    "set x 'open\n",
};

test "fuzz ctl.parseWrite" {
    try t.fuzz({}, fuzzOne, .{ .corpus = &corpus });
}

test "ctl.parseWrite on the corpus and random writes" {
    for (corpus) |c| try checkWrite(c);
    // Random writes from a skewed alphabet, for runs without --fuzz.
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    var r: Rng = .init(ar.allocator());
    const alphabet = [_][]const u8{ "a", "b", "E", "N", "D", " ", " ", "\t", "\n", "\n", "'", "'", "=", "=", ":", "<<", "<<END", "\nEND\n", "\r", "é", "\x00", "\xff", "-" };
    for (0..cases * 5) |_| try checkWrite(r.string(&alphabet, 0, 40));
}
