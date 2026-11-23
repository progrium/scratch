//! Event lines (protocols/core.md § Events).
//!
//! ```text
//! name  key  path  attr=value ...  seq=N
//! ```
//!
//! The head is three positional words, forever: the event name, the
//! routing key (a tag, or an action's ID; `-` for none) and the path (`.`
//! the window, `over/x` an overlay, `-` app-level). Attributes follow in any
//! order, then `seq=` last. An attribute value is always one word on the
//! wire: a newline in one is written as a space.

const std = @import("std");
const tokenize = @import("tokenize.zig");
const err = @import("err.zig");
const ctl = @import("ctl.zig");

const Allocator = std.mem.Allocator;
const Diag = err.Diag;
const Error = err.Error;
pub const Attr = ctl.Attr;

pub const Event = struct {
    name: []const u8,
    key: []const u8 = "-",
    path: []const u8 = "-",
    attrs: []const Attr = &.{},
    /// Given by the host when the event is queued; null before.
    seq: ?u64 = null,

    pub fn attr(self: Event, k: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.key, k)) return a.value;
        return null;
    }

    /// The line without its newline: `name key path k=v ... [seq=N]`.
    pub fn format(self: Event, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try headWord(w, self.name);
        try w.writeByte(' ');
        try headWord(w, self.key);
        try w.writeByte(' ');
        try headWord(w, self.path);
        for (self.attrs) |a| {
            try w.print(" {s}=", .{a.key});
            try oneLine(w, a.value);
        }
        if (self.seq) |n| try w.print(" seq={d}", .{n});
    }
};

fn headWord(w: *std.Io.Writer, s: []const u8) !void {
    if (s.len == 0) return w.writeByte('-');
    if (std.mem.indexOfAny(u8, s, "\r\n") == null) return tokenize.quoteWord(w, s);
    var buf: [256]u8 = undefined;
    if (s.len <= buf.len) {
        @memcpy(buf[0..s.len], s);
        for (buf[0..s.len]) |*c| if (c.* == '\n' or c.* == '\r') {
            c.* = ' ';
        };
        return tokenize.quoteWord(w, buf[0..s.len]);
    }
    // Long head words with newlines don't happen; quote what we can.
    return tokenize.quoteAlways(w, s);
}

/// Quotes `v` as `quote` does, with each CR or LF written as a space.
fn oneLine(w: *std.Io.Writer, v: []const u8) !void {
    const nl = std.mem.indexOfAny(u8, v, "\r\n") != null;
    if (!nl) return tokenize.quoteValue(w, v);
    try w.writeByte('\'');
    for (v) |c| switch (c) {
        '\r', '\n' => try w.writeByte(' '),
        '\'' => try w.writeAll("''"),
        else => try w.writeByte(c),
    };
    try w.writeByte('\'');
}

/// Writes the whole event line, `seq=` included when set, and its newline.
pub fn format(w: *std.Io.Writer, ev: Event) std.Io.Writer.Error!void {
    try ev.format(w);
    try w.writeByte('\n');
}

/// Reads one event line back; a trailing newline is allowed. The first
/// `seq=` becomes `seq`; anything else is an attribute.
pub fn parse(arena: Allocator, line: []const u8) Error!Event {
    return parseDiag(arena, line, null);
}

pub fn parseDiag(arena: Allocator, line: []const u8, d: ?*Diag) Error!Event {
    const l = std.mem.trimEnd(u8, line, "\n");
    const ts = try ctl.tokens(arena, l, d);
    const b = try ctl.build(arena, ts, false, d);
    const c = b.ctl;
    if (c.words.len != 2) return err.fail(d, arena, .bad_syntax, "event head: name key path", .{});
    var ev: Event = .{ .name = c.verb, .key = c.words[0], .path = c.words[1] };
    var attrs: std.ArrayList(Attr) = .empty;
    for (c.attrs) |a| {
        if (ev.seq == null and std.mem.eql(u8, a.key, "seq")) {
            ev.seq = std.fmt.parseInt(u64, a.value, 10) catch
                return err.fail(d, arena, .bad_value, "seq={s}", .{a.value});
        } else try attrs.append(arena, a);
    }
    ev.attrs = try attrs.toOwnedSlice(arena);
    return ev;
}

// ---------------------------------------------------------------------------
// tests: uitreefs/crates/proto/tests/snippets.rs (event_lines), and the
// spec's own examples.

const t = std.testing;

fn evLine(a: Allocator, ev: Event) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try format(&aw.writer, ev);
    return aw.written();
}

test "event lines" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    try t.expectEqualStrings("click save prefs/ok/save win=main seq=118\n", try evLine(a, .{
        .name = "click",
        .key = "save",
        .path = "prefs/ok/save",
        .attrs = &.{.{ .key = "win", .value = "main" }},
        .seq = 118,
    }));
    try t.expectEqualStrings("change - prefs/lang/in win=main value=go seq=120\n", try evLine(a, .{
        .name = "change",
        .path = "prefs/lang/in",
        .attrs = &.{ .{ .key = "win", .value = "main" }, .{ .key = "value", .value = "go" } },
        .seq = 120,
    }));
    try t.expectEqualStrings("select - - value='Tokyo Night' seq=1\n", try evLine(a, .{
        .name = "select",
        .attrs = &.{.{ .key = "value", .value = "Tokyo Night" }},
        .seq = 1,
    }));
    // A newline in a value is a space; no seq, no seq=.
    try t.expectEqualStrings("error - x/text win=main code=not-found msg='a b'\n", try evLine(a, .{
        .name = "error",
        .path = "x/text",
        .attrs = &.{ .{ .key = "win", .value = "main" }, .{ .key = "code", .value = err.Code.not_found.name() }, .{ .key = "msg", .value = "a\nb" } },
    }));

    const back = try parse(a, "action save src win=main via=key seq=119\n");
    try t.expectEqual(@as(u64, 119), back.seq.?);
    try t.expectEqualStrings("action", back.name);
    try t.expectEqualStrings("save", back.key);
    try t.expectEqualStrings("src", back.path);
    try t.expectEqualStrings("key", back.attr("via").?);
    try t.expect(back.attr("seq") == null);

    try t.expectEqualDeep(Event{ .name = "resync", .seq = 42 }, try parse(a, "resync - - seq=42"));
    try t.expectEqualDeep(Event{ .name = "gone" }, try parse(a, "gone - -"));

    // The spec's examples (core.md § Paths, § Events).
    for ([_][]const u8{
        "move - . win=main x=200 y=80 display=1 seq=119",
        "action quit tray/main via=tray seq=120",
        "answer pick over/pick n=2 seq=122",
        "open - open/3 n=1 via=file seq=123",
        "close - . win=main via=titlebar seq=121",
        "theme - - mode=dark via=system seq=7",
        "click del list/t3 win=main arg=t3 seq=9",
    }) |s| {
        const ev = try parse(a, s);
        var aw: std.Io.Writer.Allocating = .init(a);
        try ev.format(&aw.writer);
        try t.expectEqualStrings(s, aw.written());
    }

    try t.expectError(error.BadSyntax, parse(a, "click save"));
    try t.expectError(error.BadSyntax, parse(a, "click a b c"));
    try t.expectError(error.BadValue, parse(a, "click - - seq=x"));
    try t.expectError(error.BadSyntax, parse(a, ""));
}
