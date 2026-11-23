//! Plan 9 `tokenize` and `quote` (protocols/core.md § Words and quoting).
//!
//! Words split on blanks (space, tab, CR, LF). A `'` anywhere in a word
//! starts a quoted run, which ends at the next lone `'`; inside it, blanks
//! are ordinary and `''` is one literal quote. So `title='Sign in'`,
//! `'it''s'` and `''` (the empty word) all work as in Plan 9. Unlike Plan 9,
//! an unterminated quote is an error (`bad syntax`) rather than running to
//! the end of the line.
//!
//! This is shared by every workstream (proto, types, tree, ninep), so it
//! lands in the scaffold. Port of uitreefs/crates/proto/src/tok.rs.

const std = @import("std");

pub const Error = error{ UnterminatedQuote, OutOfMemory };

/// One word, with where its first unquoted `=` was and whether any of it
/// was quoted.
pub const Tok = struct {
    text: []const u8,
    /// Byte offset in `text` of the first `=` outside quotes.
    eq: ?usize = null,
    /// The word had a quote in it.
    quoted: bool = false,

    /// `key`, `value` if this word is a `name=value` attribute: an unquoted
    /// `=` after a key that starts with a letter or `_` and doesn't end in `-`.
    pub fn attr(self: Tok) ?struct { key: []const u8, value: []const u8 } {
        const i = self.eq orelse return null;
        const k = self.text[0..i];
        if (k.len == 0) return null;
        if (!(std.ascii.isAlphabetic(k[0]) or k[0] == '_' or k[0] >= 0x80)) return null;
        if (k[k.len - 1] == '-') return null;
        return .{ .key = k, .value = self.text[i + 1 ..] };
    }

    /// A lone, unquoted `:`, which starts a node's style.
    pub fn isStyleColon(self: Tok) bool {
        return !self.quoted and std.mem.eql(u8, self.text, ":");
    }
};

pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Splits `line` into words. Word text is allocated from `arena`; pass an
/// arena that lives as long as the tokens (an op's arena, in the tree).
pub fn tokenize(arena: std.mem.Allocator, line: []const u8) Error![]Tok {
    var out: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < line.len and isBlank(line[i])) i += 1;
        if (i >= line.len) return out.toOwnedSlice(arena);

        var text: std.ArrayList(u8) = .empty;
        var t: Tok = .{ .text = "" };
        var inq = false;
        while (i < line.len) {
            const c = line[i];
            if (inq) {
                i += 1;
                if (c == '\'') {
                    if (i < line.len and line[i] == '\'') {
                        i += 1;
                        try text.append(arena, '\'');
                    } else inq = false;
                } else try text.append(arena, c);
            } else {
                if (isBlank(c)) break;
                i += 1;
                if (c == '\'') {
                    inq = true;
                    t.quoted = true;
                } else {
                    if (c == '=' and t.eq == null) t.eq = text.items.len;
                    try text.append(arena, c);
                }
            }
        }
        if (inq) return error.UnterminatedQuote;
        t.text = try text.toOwnedSlice(arena);
        try out.append(arena, t);
    }
}

/// Whether `s` needs quoting: it is empty or has a blank, a control
/// character or a `'`.
pub fn needsQuote(s: []const u8) bool {
    if (s.len == 0) return true;
    for (s) |c| if (c <= ' ' or c == '\'') return true;
    return false;
}

/// Plan 9 `quote`: writes `s` unchanged when it needs no quoting.
pub fn quote(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (!needsQuote(s)) return w.writeAll(s);
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeByte('\'');
        try w.writeByte(c);
    }
    try w.writeByte('\'');
}

fn expectWords(line: []const u8, want: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), line);
    try std.testing.expectEqual(want.len, toks.len);
    for (want, toks) |w, t| try std.testing.expectEqualStrings(w, t.text);
}

test "blanks separate" {
    try expectWords("  new  button\tok \r\n", &.{ "new", "button", "ok" });
    try expectWords("", &.{});
    try expectWords(" \t\n", &.{});
}

test "quotes group, '' is a literal quote" {
    try expectWords("set title='Sign in'", &.{ "set", "title=Sign in" });
    try expectWords("'it''s'", &.{"it's"});
    try expectWords("''", &.{""});
    try expectWords("a'b c'd", &.{"ab cd"});
}

test "unterminated quote is an error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnterminatedQuote, tokenize(arena.allocator(), "set label='oops"));
}

test "attributes split at the first unquoted =" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), "label=a=b 'x=y' tag=open:42 -x=1 =v");
    const a = toks[0].attr().?;
    try std.testing.expectEqualStrings("label", a.key);
    try std.testing.expectEqualStrings("a=b", a.value);
    try std.testing.expect(toks[1].attr() == null); // the = was quoted
    try std.testing.expectEqualStrings("open:42", toks[2].attr().?.value);
    try std.testing.expect(toks[3].attr() == null);
    try std.testing.expect(toks[4].attr() == null);
}

test "style colon is a lone unquoted :" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const toks = try tokenize(arena.allocator(), "new div : flex-col ':' hover:bg=accent");
    try std.testing.expect(toks[2].isStyleColon());
    try std.testing.expect(!toks[4].isStyleColon());
    try std.testing.expect(!toks[5].isStyleColon());
}

test "quote round-trips" {
    const cases = [_][]const u8{ "plain", "", "two words", "it's", "tab\there", "'" };
    for (cases) |s| {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try quote(&w, s);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const toks = try tokenize(arena.allocator(), w.buffered());
        try std.testing.expectEqual(@as(usize, 1), toks.len);
        try std.testing.expectEqualStrings(s, toks[0].text);
    }
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try quote(&w, "plain");
    try std.testing.expectEqualStrings("plain", w.buffered());
}
