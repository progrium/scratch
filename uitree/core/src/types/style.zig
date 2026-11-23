//! Style words and theme tokens as data (core.md § Style, interface I7).
//!
//! `core/types/style-words` holds one `name argkind` line per word, and
//! `core/types/theme-tokens` one `name light dark` line per token. Both are
//! written by the GPUI renderer's style-gen tool
//! (renderer/gpui/tools/style-gen) from GPUI's own source, always in the
//! dashed spelling, so the core can check style without knowing GPUI.
//!
//! This file also holds the style word parser the checks use. It follows
//! core.md § Style; W2's `proto.style.parse` will replace `Word.parse` once
//! it lands, with the same result shape.

const std = @import("std");

/// What a style word's argument is.
pub const ArgKind = enum {
    /// No argument (`flex-col`).
    none,
    /// px, `%` or `rem` (`w=240`, `w=50%`).
    length,
    /// A bare number (`flex-grow=1`, `opacity=0.5`).
    number,
    /// A theme token or `#rrggbb[aa]`.
    color,
    /// One word (`font-family=monospace`).
    text,
    /// `x,y,blur,color` (`shadow=0,4,12,#0003`).
    shadow,
    /// A component variant word (`primary`), valid only on a type whose
    /// descriptor lists it as `kind=variant`.
    variant,
    /// A component size word (`sm`), valid only on a type with
    /// `kind=size` words.
    size,
};

pub const Entry = struct {
    name: []const u8,
    arg: ArgKind,
};

pub const Token = struct {
    name: []const u8,
    light: []const u8,
    dark: []const u8,
};

/// Parses `style-words` text into entries sorted by name. Blank lines and
/// `#` comments are skipped. Strings point into `text`.
pub fn parseWords(arena: std.mem.Allocator, text: []const u8) error{ BadSyntax, OutOfMemory }![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const name = f.next() orelse continue;
        const kind = f.next() orelse return error.BadSyntax;
        const arg = std.meta.stringToEnum(ArgKind, kind) orelse return error.BadSyntax;
        if (f.next() != null) return error.BadSyntax;
        try out.append(arena, .{ .name = name, .arg = arg });
    }
    std.mem.sortUnstable(Entry, out.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

/// Parses `theme-tokens` text, keeping its order.
pub fn parseTokens(arena: std.mem.Allocator, text: []const u8) error{ BadSyntax, OutOfMemory }![]Token {
    var out: std.ArrayList(Token) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const name = f.next() orelse continue;
        const light = f.next() orelse return error.BadSyntax;
        const dark = f.next() orelse return error.BadSyntax;
        if (f.next() != null) return error.BadSyntax;
        if (!isColor(light) or !isColor(dark)) return error.BadSyntax;
        try out.append(arena, .{ .name = name, .light = light, .dark = dark });
    }
    return out.toOwnedSlice(arena);
}

pub fn lookup(entries: []const Entry, name: []const u8) ?Entry {
    const i = std.sort.binarySearch(Entry, entries, name, struct {
        fn cmp(n: []const u8, e: Entry) std.math.Order {
            return std.mem.order(u8, n, e.name);
        }
    }.cmp) orelse return null;
    return entries[i];
}

// ---------------------------------------------------------------- words

/// The state a word applies in (`hover:bg=accent`).
pub const State = enum { hover, active, focus, disabled, @"drop-over" };

/// One style word, split but not checked against any table.
pub const Word = struct {
    state: ?State = null,
    /// `group-hover(NAME):word`: the group.
    group_hover: ?[]const u8 = null,
    /// `group:NAME` joins a group; `name` is then "group".
    group: ?[]const u8 = null,
    name: []const u8,
    /// The text after `=`, split at `,`. Empty for a word with no `=`.
    args: []const []const u8 = &.{},

    pub const ParseError = error{ BadSyntax, UnknownStyleWord, OutOfMemory };

    /// One blank-free word.
    pub fn parse(arena: std.mem.Allocator, word: []const u8) ParseError!Word {
        var rest = word;
        var w: Word = .{ .name = "" };
        if (std.mem.startsWith(u8, rest, "group-hover(")) {
            const r = rest["group-hover(".len..];
            const close = std.mem.indexOfScalar(u8, r, ')') orelse return error.BadSyntax;
            const g = r[0..close];
            if (!isName(g) or close + 1 >= r.len or r[close + 1] != ':') return error.BadSyntax;
            w.group_hover = g;
            rest = r[close + 2 ..];
        } else if (std.mem.indexOfScalar(u8, rest, ':')) |c| {
            const p = rest[0..c];
            const r = rest[c + 1 ..];
            if (std.mem.eql(u8, p, "group")) {
                if (!isName(r)) return error.BadSyntax;
                return .{ .name = "group", .group = r };
            }
            w.state = std.meta.stringToEnum(State, p) orelse return error.UnknownStyleWord;
            rest = r;
        }
        if (std.mem.indexOfScalar(u8, rest, '=')) |e| {
            w.name = rest[0..e];
            var args: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, rest[e + 1 ..], ',');
            while (it.next()) |a| {
                if (a.len == 0) return error.BadSyntax;
                try args.append(arena, a);
            }
            w.args = try args.toOwnedSlice(arena);
        } else w.name = rest;
        if (!isName(w.name)) return error.BadSyntax;
        return w;
    }
};

/// Splits a `style` file's text into words.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Word.ParseError![]Word {
    var out: std.ArrayList(Word) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| try out.append(arena, try Word.parse(arena, w));
    return out.toOwnedSlice(arena);
}

/// A style or group name: ASCII letters, digits, `-` and `_`. Only dashed
/// lowercase names are in any table, so `flex_col` parses and then fails
/// as an unknown style word.
pub fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

// ---------------------------------------------------------------- arguments

pub const Arg = enum { px, percent, rem, color, token, bad };

/// Classifies one argument: `12`, `50%`, `1.5rem`, `#rrggbb[aa]`, a token.
pub fn classify(a: []const u8) Arg {
    if (a.len == 0) return .bad;
    if (a[0] == '#') return if (isColor(a)) .color else .bad;
    if (std.mem.endsWith(u8, a, "%")) return if (isNumber(a[0 .. a.len - 1])) .percent else .bad;
    if (std.mem.endsWith(u8, a, "rem")) return if (isNumber(a[0 .. a.len - 3])) .rem else .bad;
    if (isNumber(a)) return .px;
    if (isToken(a)) return .token;
    return .bad;
}

/// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
pub fn isColor(s: []const u8) bool {
    if (s.len < 2 or s[0] != '#') return false;
    const h = s[1..];
    switch (h.len) {
        3, 4, 6, 8 => {},
        else => return false,
    }
    for (h) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// A decimal: optional sign, digits, optional fraction. No exponent, no
/// `inf`, no `nan`.
pub fn isNumber(s: []const u8) bool {
    var b = s;
    if (b.len > 0 and (b[0] == '-' or b[0] == '+')) b = b[1..];
    var digit = false;
    var dot = false;
    for (b) |c| switch (c) {
        '0'...'9' => digit = true,
        '.' => {
            if (dot) return false;
            dot = true;
        },
        else => return false,
    };
    return digit;
}

/// A theme token or word argument: a letter, then letters, digits, `-`,
/// `_` or `.`.
pub fn isToken(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

/// Whether `args` fit `kind`. `token_ok` says whether a token names a
/// theme token (for color arguments).
pub fn argsOk(kind: ArgKind, args: []const []const u8, ctx: anytype, comptime token_ok: fn (@TypeOf(ctx), []const u8) bool) bool {
    return switch (kind) {
        .none, .variant, .size => args.len == 0,
        .shadow => args.len == 4 and
            argOk(.length, args[0], ctx, token_ok) and
            argOk(.length, args[1], ctx, token_ok) and
            argOk(.length, args[2], ctx, token_ok) and
            argOk(.color, args[3], ctx, token_ok),
        else => args.len == 1 and argOk(kind, args[0], ctx, token_ok),
    };
}

fn argOk(kind: ArgKind, a: []const u8, ctx: anytype, comptime token_ok: fn (@TypeOf(ctx), []const u8) bool) bool {
    const c = classify(a);
    return switch (kind) {
        .length => c == .px or c == .percent or c == .rem,
        .number => c == .px,
        .color => c == .color or (c == .token and token_ok(ctx, a)),
        .text => c == .token,
        else => false,
    };
}

test "parse words" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ws = try parse(a, "flex-col  w=240 hover:bg=accent shadow=0,4,12,#0003 group:card group-hover(card):bg=muted");
    try std.testing.expectEqual(@as(usize, 6), ws.len);
    try std.testing.expectEqualStrings("flex-col", ws[0].name);
    try std.testing.expectEqualStrings("240", ws[1].args[0]);
    try std.testing.expectEqual(State.hover, ws[2].state.?);
    try std.testing.expectEqual(@as(usize, 4), ws[3].args.len);
    try std.testing.expectEqualStrings("card", ws[4].group.?);
    try std.testing.expectEqualStrings("card", ws[5].group_hover.?);
    try std.testing.expectError(error.UnknownStyleWord, Word.parse(a, "wobble:bg=red"));
    try std.testing.expectError(error.BadSyntax, Word.parse(a, "w="));
    try std.testing.expectError(error.BadSyntax, Word.parse(a, "flex.col"));
}

test "classify arguments" {
    try std.testing.expectEqual(Arg.px, classify("-12.5"));
    try std.testing.expectEqual(Arg.percent, classify("50%"));
    try std.testing.expectEqual(Arg.rem, classify("1.5rem"));
    try std.testing.expectEqual(Arg.color, classify("#0b5cffff"));
    try std.testing.expectEqual(Arg.token, classify("muted-foreground"));
    try std.testing.expectEqual(Arg.bad, classify("#zz"));
    try std.testing.expectEqual(Arg.bad, classify("1e3"));
}

test "words and tokens tables" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ws = try parseWords(arena.allocator(), "w length\n# c\nflex-col none\n\nbg color\n");
    try std.testing.expectEqualStrings("bg", ws[0].name);
    try std.testing.expectEqual(ArgKind.length, lookup(ws, "w").?.arg);
    try std.testing.expect(lookup(ws, "nope") == null);
    try std.testing.expectError(error.BadSyntax, parseWords(arena.allocator(), "w furlongs\n"));
    const ts = try parseTokens(arena.allocator(), "background #ffffff #0a0a0a\n");
    try std.testing.expectEqualStrings("#0a0a0a", ts[0].dark);
    try std.testing.expectError(error.BadSyntax, parseTokens(arena.allocator(), "x white black\n"));
}
