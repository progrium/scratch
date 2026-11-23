//! Style syntax (protocols/core.md § Style). Syntax only: whether a word's
//! name exists, or fits its argument, is the catalog's `checkStyle` (W1).
//!
//! A style is words separated by blanks. Each word is
//!
//! ```text
//! [state:]name[=arg[,arg...]]
//! ```
//!
//! where an arg is `n` (pixels), `npx`, `n%`, `nrem`, `#rgb[a]`,
//! `#rrggbb[aa]` or a theme token, and a state is `hover:`, `active:`,
//! `focus:` or `disabled:` (the spec's), or uitreefs's `drop-over:` and
//! `group-hover(G):`. `group:G` puts the element in group `G`. Any other
//! prefix before a `:` is `unknown style word`.

const std = @import("std");
const tokenize = @import("tokenize.zig");
const err = @import("err.zig");

const Allocator = std.mem.Allocator;
const Diag = err.Diag;
const Error = err.Error;

pub const State = union(enum) {
    hover,
    active,
    focus,
    disabled,
    drop_over,
    group_hover: []const u8,

    fn fromPrefix(p: []const u8) ?State {
        if (std.mem.eql(u8, p, "hover")) return .hover;
        if (std.mem.eql(u8, p, "active")) return .active;
        if (std.mem.eql(u8, p, "focus")) return .focus;
        if (std.mem.eql(u8, p, "disabled")) return .disabled;
        if (std.mem.eql(u8, p, "drop-over")) return .drop_over;
        return null;
    }

    pub fn format(self: State, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .drop_over => try w.writeAll("drop-over"),
            .group_hover => |g| try w.print("group-hover({s})", .{g}),
            else => try w.writeAll(@tagName(self)),
        }
    }
};

/// `#rrggbb[aa]`, without any renderer type.
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
    pub fn parse(s: []const u8) ?Rgba {
        if (s.len < 1 or s[0] != '#') return null;
        const h = s[1..];
        for (h) |c| if (!std.ascii.isHex(c)) return null;
        const nib = struct {
            fn f(c: u8) u8 {
                return (std.fmt.charToDigit(c, 16) catch unreachable) * 17;
            }
        }.f;
        const byte = struct {
            fn f(x: []const u8) u8 {
                return std.fmt.parseInt(u8, x, 16) catch unreachable;
            }
        }.f;
        return switch (h.len) {
            3 => .{ .r = nib(h[0]), .g = nib(h[1]), .b = nib(h[2]) },
            4 => .{ .r = nib(h[0]), .g = nib(h[1]), .b = nib(h[2]), .a = nib(h[3]) },
            6 => .{ .r = byte(h[0..2]), .g = byte(h[2..4]), .b = byte(h[4..6]) },
            8 => .{ .r = byte(h[0..2]), .g = byte(h[2..4]), .b = byte(h[4..6]), .a = byte(h[6..8]) },
            else => null,
        };
    }

    /// `#rrggbb` when opaque, `#rrggbbaa` otherwise.
    pub fn format(self: Rgba, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
        if (self.a != 255) try w.print("{x:0>2}", .{self.a});
    }
};

/// One argument. A plain word (`wide`, `accent`) is a `token`; whether it
/// names a theme token, or fits the word, is the catalog's to say.
pub const Arg = union(enum) {
    px: f32,
    percent: f32,
    rem: f32,
    color: Rgba,
    token: []const u8,

    pub fn parse(arena: Allocator, s: []const u8, d: ?*Diag) Error!Arg {
        if (s.len == 0) return err.fail(d, arena, .bad_syntax, "empty style argument", .{});
        if (s[0] == '#') return .{ .color = Rgba.parse(s) orelse return err.fail(d, arena, .bad_value, "{s}", .{s}) };
        if (std.ascii.isDigit(s[0]) or s[0] == '-' or s[0] == '+' or s[0] == '.') {
            var num = s;
            var k: enum { px, percent, rem } = .px;
            if (std.mem.endsWith(u8, s, "%")) {
                num = s[0 .. s.len - 1];
                k = .percent;
            } else if (std.mem.endsWith(u8, s, "rem")) {
                num = s[0 .. s.len - 3];
                k = .rem;
            } else if (std.mem.endsWith(u8, s, "px")) {
                num = s[0 .. s.len - 2];
            }
            const n = parseNumber(num) orelse return err.fail(d, arena, .bad_value, "{s}", .{s});
            return switch (k) {
                .px => .{ .px = n },
                .percent => .{ .percent = n },
                .rem => .{ .rem = n },
            };
        }
        if (isToken(s)) return .{ .token = s };
        return err.fail(d, arena, .bad_syntax, "style argument {s}", .{s});
    }

    pub fn format(self: Arg, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .px => |n| try w.print("{d}", .{n}),
            .percent => |n| try w.print("{d}%", .{n}),
            .rem => |n| try w.print("{d}rem", .{n}),
            .color => |c| try c.format(w),
            .token => |x| try w.writeAll(x),
        }
    }
};

pub const StyleWord = struct {
    state: ?State = null,
    /// `group:G`: the element joins group `G`. Then `name` is `group`.
    group: ?[]const u8 = null,
    name: []const u8,
    args: []const Arg = &.{},

    /// The word as written (`hover:bg=accent`), with numbers in their
    /// shortest form.
    pub fn format(self: StyleWord, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.state) |s| {
            try s.format(w);
            try w.writeByte(':');
        }
        if (self.group) |g| if (self.args.len == 0) return w.print("{s}:{s}", .{ self.name, g });
        try w.writeAll(self.name);
        for (self.args, 0..) |a, i| {
            try w.writeByte(if (i == 0) '=' else ',');
            try a.format(w);
        }
    }
};

/// A style method or prefix name: ASCII letters, digits, `_` and `-`.
fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

/// A theme token or word argument: starts with a letter or `_`; then
/// letters, digits, `_`, `-` and `.`.
fn isToken(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return true;
}

/// A decimal number: an optional sign, digits, an optional fraction. No
/// exponent, `inf` or `nan`.
pub fn parseNumber(s: []const u8) ?f32 {
    var body = s;
    if (body.len > 0 and (body[0] == '-' or body[0] == '+')) body = body[1..];
    var dot = false;
    var digit = false;
    for (body) |c| switch (c) {
        '0'...'9' => digit = true,
        '.' => {
            if (dot) return null;
            dot = true;
        },
        else => return null,
    };
    if (!digit) return null;
    const n = std.fmt.parseFloat(f32, s) catch return null;
    return if (std.math.isFinite(n)) n else null;
}

/// One blank-free word.
pub fn parseWord(arena: Allocator, word: []const u8, d: ?*Diag) Error!StyleWord {
    var rest = word;
    var state: ?State = null;
    if (std.mem.startsWith(u8, rest, "group-hover(")) {
        const r = rest["group-hover(".len..];
        const close = std.mem.indexOfScalar(u8, r, ')') orelse return err.fail(d, arena, .bad_syntax, "{s}", .{word});
        const g = r[0..close];
        if (close + 1 >= r.len or r[close + 1] != ':' or !isName(g))
            return err.fail(d, arena, .bad_syntax, "{s}", .{word});
        state = .{ .group_hover = g };
        rest = r[close + 2 ..];
    } else if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        const p = rest[0..i];
        const r = rest[i + 1 ..];
        if (std.mem.eql(u8, p, "group")) {
            if (!isName(r)) return err.fail(d, arena, .bad_syntax, "{s}", .{word});
            return .{ .group = r, .name = "group" };
        }
        state = State.fromPrefix(p) orelse return err.fail(d, arena, .unknown_style_word, "{s}", .{word});
        rest = r;
    }
    var name = rest;
    var args: []Arg = &.{};
    if (std.mem.indexOfScalar(u8, rest, '=')) |i| {
        name = rest[0..i];
        const n = std.mem.count(u8, rest[i + 1 ..], ",") + 1;
        args = try arena.alloc(Arg, n);
        var it = std.mem.splitScalar(u8, rest[i + 1 ..], ',');
        var k: usize = 0;
        while (it.next()) |x| : (k += 1) {
            args[k] = Arg.parse(arena, x, d) catch |e| switch (e) {
                error.BadSyntax => return err.fail(d, arena, .bad_syntax, "{s}", .{word}),
                else => return e,
            };
        }
    }
    if (!isName(name)) return err.fail(d, arena, .bad_syntax, "{s}", .{word});
    return .{ .state = state, .name = name, .args = args };
}

/// Style words separated by blanks. Fails on the first bad word.
pub fn parse(arena: Allocator, text: []const u8) Error![]StyleWord {
    return parseDiag(arena, text, null);
}

pub fn parseDiag(arena: Allocator, text: []const u8, d: ?*Diag) Error![]StyleWord {
    var out: std.ArrayList(StyleWord) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| try out.append(arena, try parseWord(arena, w, d));
    return out.toOwnedSlice(arena);
}

/// The words of a `ctl` line's style (`Ctl.style`), parsed.
pub fn parseWords(arena: Allocator, words: []const []const u8, d: ?*Diag) Error![]StyleWord {
    const out = try arena.alloc(StyleWord, words.len);
    for (words, out) |w, *o| o.* = try parseWord(arena, w, d);
    return out;
}

/// Words joined by one blank.
pub fn format(w: *std.Io.Writer, words: []const StyleWord) std.Io.Writer.Error!void {
    for (words, 0..) |x, i| {
        if (i > 0) try w.writeByte(' ');
        try x.format(w);
    }
}

// ---------------------------------------------------------------------------
// tests: uitreefs/crates/proto/tests/snippets.rs (style_snippets), renamed
// to 0.2's dashed words.

const t = std.testing;

fn roundTrip(a: Allocator, s: []const u8) !void {
    const words = try parse(a, s);
    var aw: std.Io.Writer.Allocating = .init(a);
    try format(&aw.writer, words);
    try t.expectEqualDeep(words, try parse(a, aw.written()));
}

test "style snippets" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{
        "v-flex size-full p=4 gap=3",
        "flex-col items-center size-full rounded-md overflow-y-scroll cursor-pointer",
        "w=240 gap=12 p=16 text-size=13 w=50% px=1.5rem",
        "bg=primary text-color=muted-foreground border-color=border bg=#1e1e2e",
        "shadow=0,4,12,#0003 hover:bg=accent focus:border-color=ring",
        "h-flex gap=8 p=12 rounded-lg bg=muted hover:bg=accent cursor-pointer",
        "group:row group-hover(row):visible drop-over:bg=accent disabled:opacity=0.5 active:bg=muted",
    }) |s| try roundTrip(a, s);

    var w = (try parse(a, "shadow=0,4,12,#0003"))[0];
    try t.expectEqualDeep(&[_]Arg{ .{ .px = 0 }, .{ .px = 4 }, .{ .px = 12 }, .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 0x33 } } }, w.args);
    try t.expectEqualDeep(&[_]Arg{.{ .rem = 1.5 }}, (try parse(a, "px=1.5rem"))[0].args);
    try t.expectEqualDeep(&[_]Arg{.{ .percent = 50 }}, (try parse(a, "w=50%"))[0].args);
    try t.expectEqualDeep(&[_]Arg{.{ .px = 12 }}, (try parse(a, "w=12px"))[0].args);
    w = (try parse(a, "hover:bg=accent"))[0];
    try t.expectEqual(State.hover, w.state.?);
    try t.expectEqualStrings("bg", w.name);
    try t.expectEqualStrings("accent", w.args[0].token);
    w = (try parse(a, "group-hover(card):text-color=primary"))[0];
    try t.expectEqualStrings("card", w.state.?.group_hover);
    w = (try parse(a, "group:card"))[0];
    try t.expectEqualStrings("group", w.name);
    try t.expectEqualStrings("card", w.group.?);

    var aw: std.Io.Writer.Allocating = .init(a);
    try w.format(&aw.writer);
    try t.expectEqualStrings("group:card", aw.written());
    aw = .init(a);
    try format(&aw.writer, try parse(a, "bg=#1e1e2e bg=#fff8"));
    try t.expectEqualStrings("bg=#1e1e2e bg=#ffffff88", aw.written());

    var d: Diag = .{};
    try t.expectError(error.BadValue, parse(a, "w=12x"));
    try t.expectError(error.BadValue, parse(a, "bg=#12345"));
    try t.expectError(error.UnknownStyleWord, parseDiag(a, "hovr:bg=accent", &d));
    aw = .init(a);
    try d.format(&aw.writer);
    try t.expectEqualStrings("unknown style word: hovr:bg=accent", aw.written());
    try t.expectError(error.BadSyntax, parse(a, "w="));
    try t.expectError(error.BadSyntax, parse(a, "shadow=1,,2"));
    try t.expectError(error.BadSyntax, parse(a, "a=b!"));
    try t.expectError(error.BadSyntax, parse(a, "group-hover(x)bg"));
    try t.expectError(error.BadSyntax, parse(a, "group:"));
    // `w=wide` is syntactically a token; the catalog rejects it.
    try t.expectEqualStrings("wide", (try parse(a, "w=wide"))[0].args[0].token);
    try t.expectEqual(@as(usize, 0), (try parse(a, "  \t ")).len);
}

test "numbers" {
    try t.expectEqual(@as(f32, -12.5), parseNumber("-12.5").?);
    try t.expectEqual(@as(f32, 0.5), parseNumber(".5").?);
    try t.expectEqual(@as(f32, 3), parseNumber("+3").?);
    for ([_][]const u8{ "", "-", ".", "1e3", "inf", "nan", "1.2.3", "0x10", "1 " }) |s|
        try t.expect(parseNumber(s) == null);
}
