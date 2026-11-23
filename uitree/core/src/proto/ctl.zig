//! `ctl` lines (protocols/core.md § Commands, § Words and quoting).
//!
//! A line is a verb, then words: positional words, `name=value`
//! attributes, and everything after a lone unquoted `:` as style words.
//!
//! ```text
//! new button inc label=+1 primary tag=inc : w=64 hover:bg=accent
//! ```
//!
//! is `verb=new`, `words={button, inc, primary}`, `attrs={label=+1,
//! tag=inc}`, `style={w=64, hover:bg=accent}`. Which positional words are
//! a path, a type or a bare word depends on the verb (`Ctl.bare`). Nothing
//! here checks a verb, a type or a value: that is the tree's and the
//! catalog's job.
//!
//! A write (`parseWrite`) is one command per line, all or nothing, with
//! here-values: a word `prop=<<WORD`, or a bare `<<WORD` (`tree PATH
//! <<END`), takes the lines that follow, up to a line holding only `WORD`,
//! as its value: the lines joined with `\n`, with no trailing newline (so
//! a value ending in a newline has an empty last line). The marker line is
//! exactly `WORD` (a CR before its LF is allowed).

const std = @import("std");
const tokenize = @import("tokenize.zig");
const err = @import("err.zig");

const Allocator = std.mem.Allocator;
const Diag = err.Diag;
const Error = err.Error;

/// A `name=value` word.
pub const Attr = struct {
    key: []const u8,
    value: []const u8,
};

/// The verbs the spec defines on some `ctl`: the four node commands, the
/// app verbs, the window verbs and the request answers. A verb a type adds
/// (`append`, `eval`) is `.other`.
pub const Verb = enum {
    // Any ctl.
    set,
    new,
    delete,
    tree,
    // The app ctl.
    window,
    ask,
    begin,
    commit,
    abort,
    theme,
    quit,
    // A window's ctl.
    show,
    activate,
    close,
    destroy,
    state,
    notify,
    // Request answers.
    keep,
    accept,
    refuse,
    other,

    pub fn of(verb: []const u8) Verb {
        const v = std.meta.stringToEnum(Verb, verb) orelse return .other;
        return if (v == .other) .other else v;
    }

    /// How many positional words come before the bare words: `set PATH`,
    /// `new TYPE PATH`, `delete PATH`, `tree PATH BODY`, `window NAME`.
    /// For other verbs every word is positional.
    pub fn arity(v: Verb) ?usize {
        return switch (v) {
            .set, .delete, .window => 1,
            .new, .tree => 2,
            else => null,
        };
    }
};

pub const Ctl = struct {
    verb: []const u8,
    /// Positional words after the verb, in order: paths, types, bare words,
    /// and the body of a bare here-value.
    words: []const []const u8 = &.{},
    attrs: []const Attr = &.{},
    /// The words after a lone `:`. Null when the line has no `:`; empty
    /// when it ends in one (which sets an empty style).
    style: ?[]const []const u8 = null,

    pub fn kind(self: Ctl) Verb {
        return Verb.of(self.verb);
    }

    /// The first value of `key=`, if any.
    pub fn attr(self: Ctl, key: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
        return null;
    }

    pub fn word(self: Ctl, i: usize) ?[]const u8 {
        return if (i < self.words.len) self.words[i] else null;
    }

    /// The bare words (booleans, flags, variants) of a node command or
    /// `window`: the words after its positional ones. Empty for any other
    /// verb, and when the line is short (the tree reports that).
    pub fn bare(self: Ctl) []const []const u8 {
        const n = self.kind().arity() orelse return &.{};
        return if (self.words.len > n) self.words[n..] else &.{};
    }

    /// The canonical form: `verb words... attrs... [: style...]`, quoted as
    /// needed. A value holding a newline is written as a here-value, so
    /// the output can be several lines, and `parseWrite` reads it back.
    /// Otherwise it is one line, with no newline at the end.
    pub fn format(self: Ctl, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [24]u8 = undefined;
        var k: usize = 0;
        try tokenize.quoteWord(w, self.verb);
        for (self.words) |x| {
            try w.writeByte(' ');
            if (hasNewline(x)) {
                try w.print("<<{s}", .{markerFor(&buf, x, k)});
                k += 1;
            } else try tokenize.quoteWord(w, x);
        }
        for (self.attrs) |a| {
            try w.writeByte(' ');
            try tokenize.quoteWord(w, a.key);
            try w.writeByte('=');
            if (hasNewline(a.value)) {
                try w.print("<<{s}", .{markerFor(&buf, a.value, k)});
                k += 1;
            } else try tokenize.quoteValue(w, a.value);
        }
        if (self.style) |st| {
            try w.writeAll(" :");
            for (st) |x| {
                try w.writeByte(' ');
                try tokenize.quote(w, x);
            }
        }
        // The bodies, in the order their markers appear on the line.
        k = 0;
        for (self.words) |x| if (hasNewline(x)) {
            try writeBody(w, x, markerFor(&buf, x, k));
            k += 1;
        };
        for (self.attrs) |a| if (hasNewline(a.value)) {
            try writeBody(w, a.value, markerFor(&buf, a.value, k));
            k += 1;
        };
    }
};

/// `\n`, the body, `\n`, the marker: no indent and no trailing newline.
pub fn writeBody(w: *std.Io.Writer, body: []const u8, marker: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('\n');
    try w.writeAll(body);
    try w.writeByte('\n');
    try w.writeAll(marker);
}

pub fn hasNewline(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\n') != null;
}

/// Whether `line` ends a here-value marked `marker`: it is exactly the
/// marker, allowing a CR before the LF.
pub fn isEndLine(line: []const u8, marker: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), marker);
}

/// The marker for the `k`-th here-value on a line (from 0): `END`, then
/// `END2`, `END3`..., skipping any that a line of the body already is.
pub fn markerFor(buf: *[24]u8, body: []const u8, k: usize) []const u8 {
    var i: usize = k + 1;
    while (true) : (i += 1) {
        const m = if (i == 1) "END" else std.fmt.bufPrint(buf, "END{d}", .{i}) catch unreachable;
        var used = false;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |l| {
            if (isEndLine(l, m)) used = true;
        }
        if (!used) return m;
    }
}

/// The `WORD` of `<<WORD`: letters, digits and `_`.
pub fn hereMarker(s: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, "<<")) return null;
    const m = s[2..];
    if (m.len == 0) return null;
    for (m) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return null;
    return m;
}

/// Where a here-value goes once its body is read.
const Here = struct {
    marker: []const u8,
    /// Index into words, or into attrs.
    index: usize,
    is_attr: bool,
};

const Built = struct {
    ctl: Ctl,
    heres: []Here,
};

/// Splits tokens into a command. `style` says whether a lone `:` starts
/// the style (on `ctl` lines and documents; not in menus, keys or ops).
pub fn build(arena: Allocator, ts: []const tokenize.Tok, style: bool, d: ?*Diag) Error!Built {
    if (ts.len == 0) return err.fail(d, arena, .bad_syntax, "empty command", .{});
    if (ts[0].attr() != null)
        return err.fail(d, arena, .bad_syntax, "missing verb before {s}", .{ts[0].text});
    var words: std.ArrayList([]const u8) = .empty;
    var attrs: std.ArrayList(Attr) = .empty;
    var heres: std.ArrayList(Here) = .empty;
    var st: ?[]const []const u8 = null;
    for (ts[1..], 1..) |tk, i| {
        if (style and tk.isStyleColon()) {
            const sw = try arena.alloc([]const u8, ts.len - i - 1);
            for (ts[i + 1 ..], sw) |x, *o| o.* = x.text;
            st = sw;
            break;
        }
        if (tk.attr()) |a| {
            if (!tk.quoted) if (hereMarker(a.value)) |m|
                try heres.append(arena, .{ .marker = m, .index = attrs.items.len, .is_attr = true });
            try attrs.append(arena, .{ .key = a.key, .value = a.value });
        } else {
            if (!tk.quoted) if (hereMarker(tk.text)) |m|
                try heres.append(arena, .{ .marker = m, .index = words.items.len, .is_attr = false });
            try words.append(arena, tk.text);
        }
    }
    return .{
        .ctl = .{
            .verb = ts[0].text,
            .words = try words.toOwnedSlice(arena),
            .attrs = try attrs.toOwnedSlice(arena),
            .style = st,
        },
        .heres = try heres.toOwnedSlice(arena),
    };
}

/// Tokenizes, turning an unterminated quote into `bad syntax`.
pub fn tokens(arena: Allocator, line: []const u8, d: ?*Diag) Error![]tokenize.Tok {
    return tokenize.tokenize(arena, line) catch |e| switch (e) {
        error.UnterminatedQuote => err.fail(d, arena, .bad_syntax, "unterminated quote", .{}),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// One line, with no here-values (a `<<WORD` stays as written). A blank
/// line is `bad syntax: empty command`.
pub fn parse(arena: Allocator, line: []const u8) Error!Ctl {
    return parseDiag(arena, line, null);
}

pub fn parseDiag(arena: Allocator, line: []const u8, d: ?*Diag) Error!Ctl {
    const ts = try tokens(arena, line, d);
    return (try build(arena, ts, true, d)).ctl;
}

fn isBlankLine(l: []const u8) bool {
    for (l) |c| if (!tokenize.isBlank(c)) return false;
    return true;
}

/// A whole `ctl` write: one command per line, blank lines skipped,
/// here-values read. All or nothing: the first error fails the write and,
/// when the write has more than one line, its detail starts `line N`.
/// Over `limits.ctl_write` is `too large`; bytes that aren't UTF-8, or a
/// NUL, are `bad syntax`.
pub fn parseWrite(arena: Allocator, write: []const u8) Error![]Ctl {
    return parseWriteDiag(arena, write, null);
}

pub fn parseWriteDiag(arena: Allocator, write: []const u8, d: ?*Diag) Error![]Ctl {
    if (write.len > err.limits.ctl_write)
        return err.fail(d, arena, .too_large, "ctl write of {d} bytes", .{write.len});
    if (!std.unicode.utf8ValidateSlice(write)) return err.fail(d, arena, .bad_syntax, "not UTF-8", .{});
    if (std.mem.indexOfScalar(u8, write, 0) != null) return err.fail(d, arena, .bad_syntax, "NUL byte", .{});

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, write, '\n');
    var nonblank: usize = 0;
    while (it.next()) |l| {
        try lines.append(arena, l);
        if (!isBlankLine(l)) nonblank += 1;
    }
    const many = nonblank > 1;
    const all = lines.items;

    var out: std.ArrayList(Ctl) = .empty;
    var i: usize = 0;
    while (i < all.len) {
        const l = all[i];
        const n = i + 1;
        i += 1;
        if (isBlankLine(l)) continue;
        const b = blk: {
            const ts = tokens(arena, l, d) catch |e| return lineErr(e, d, arena, many, n);
            break :blk build(arena, ts, true, d) catch |e| return lineErr(e, d, arena, many, n);
        };
        if (b.heres.len > 0) {
            const words = try arena.dupe([]const u8, b.ctl.words);
            const attrs = try arena.dupe(Attr, b.ctl.attrs);
            for (b.heres) |h| {
                const start = i;
                while (true) {
                    if (i >= all.len) {
                        const e = err.fail(d, arena, .bad_syntax, "no {s} line ends the value", .{h.marker});
                        return lineErr(e, d, arena, many, n);
                    }
                    i += 1;
                    if (isEndLine(all[i - 1], h.marker)) break;
                }
                const body = try std.mem.join(arena, "\n", all[start .. i - 1]);
                if (h.is_attr) attrs[h.index].value = body else words[h.index] = body;
            }
            var c = b.ctl;
            c.words = words;
            c.attrs = attrs;
            try out.append(arena, c);
        } else try out.append(arena, b.ctl);
    }
    return out.toOwnedSlice(arena);
}

fn lineErr(e: Error, d: ?*Diag, arena: Allocator, many: bool, n: usize) Error {
    if (e != error.OutOfMemory and many) err.atLine(d, arena, n);
    return e;
}

// ---------------------------------------------------------------------------
// tests: uitreefs/crates/proto/tests/snippets.rs (ctl_snippets,
// ctl_here_values_and_style), renamed to 0.2.

const t = std.testing;

fn one(arena: Allocator, line: []const u8) !Ctl {
    const cs = try parseWrite(arena, line);
    try t.expectEqual(@as(usize, 1), cs.len);
    return cs[0];
}

fn expectStrs(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |a, b| try t.expectEqualStrings(a, b);
}

fn formatted(arena: Allocator, c: Ctl) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try c.format(&aw.writer);
    return aw.written();
}

test "ctl snippets" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    var c = try one(a, "new form prefs layout=v");
    try t.expectEqualStrings("new", c.verb);
    try t.expectEqual(Verb.new, c.kind());
    try expectStrs(&.{ "form", "prefs" }, c.words);
    try t.expectEqualStrings("v", c.attr("layout").?);
    try t.expect(c.style == null);

    const cs = try parseWrite(a, "new field name label=Name\nnew field lang label=Language\nnew field ok\n");
    try t.expectEqual(@as(usize, 3), cs.len);
    try expectStrs(&.{ "field", "ok" }, cs[2].words);

    c = try one(a, "new input in placeholder='Your name'");
    try t.expectEqualStrings("Your name", c.attr("placeholder").?);

    // 0.2 puts style after a lone `:`; a `style=` attribute is still just
    // an attribute (the style file is a prop like any other).
    c = try one(a, "new div card1 tag=open:42 : v-flex gap=4 p=12 rounded-md border-1 border-color=border hover:bg=accent cursor-pointer");
    try expectStrs(&.{ "v-flex", "gap=4", "p=12", "rounded-md", "border-1", "border-color=border", "hover:bg=accent", "cursor-pointer" }, c.style.?);
    try t.expectEqualStrings("open:42", c.attr("tag").?);
    try t.expect(c.attr("style") == null);
    c = try one(a, "new div x style='flex-col p=4'");
    try t.expectEqualStrings("flex-col p=4", c.attr("style").?);

    c = try one(a, "notify 'Upload failed' type=error sticky=on action=retry:'Try again'");
    try expectStrs(&.{"Upload failed"}, c.words);
    try t.expectEqualStrings("retry:Try again", c.attr("action").?);
    try t.expectEqual(Verb.notify, c.kind());

    c = try one(a, "window main title=Notes size=900,600");
    try t.expectEqual(Verb.window, c.kind());
    try t.expectEqualStrings("main", c.word(0).?);
    try t.expectEqualStrings("900,600", c.attr("size").?);

    c = try one(a, "new alert-dialog over/confirm-del title='Delete 3 files?' description='This cannot be undone.' confirm=Delete cancel=Keep variant=danger tag=del");
    try t.expectEqualStrings("Delete 3 files?", c.attr("title").?);
    try t.expectEqualStrings("danger", c.attr("variant").?);

    const cs2 = try parseWrite(a, "set save enabled=off\nclose seq=120\nnew button eq label== : primary lg");
    try expectStrs(&.{"save"}, cs2[0].words);
    try t.expectEqualStrings("120", cs2[1].attr("seq").?);
    try t.expectEqual(Verb.close, cs2[1].kind());
    try t.expectEqualStrings("=", cs2[2].attr("label").?);

    // A quoted = stays positional, and prints back quoted.
    c = try parse(a, "notify 'a=b'");
    try expectStrs(&.{"a=b"}, c.words);
    try t.expectEqualStrings("notify 'a=b'", try formatted(a, c));

    try t.expectEqual(@as(usize, 0), (try parseWrite(a, "\n\n")).len);
}

test "errors are all or nothing" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diag = .{};
    try t.expectError(error.BadSyntax, parseWriteDiag(a, "new div a\nnew div 'b\n", &d));
    try t.expectEqualStrings("line 2: unterminated quote", d.detail);
    d = .{};
    try t.expectError(error.BadSyntax, parseWriteDiag(a, "new div 'b", &d));
    try t.expectEqualStrings("unterminated quote", d.detail);
    try t.expectError(error.BadSyntax, parseWrite(a, &.{0xff}));
    try t.expectError(error.BadSyntax, parseWrite(a, "set x text=a\x00b"));
    const big = try a.alloc(u8, 64 * 1024 + 1);
    @memset(big, 'a');
    try t.expectError(error.TooLarge, parseWrite(a, big));
    d = .{};
    try t.expectError(error.BadSyntax, parseWriteDiag(a, "x=1", &d));
    try t.expectEqualStrings("missing verb before x=1", d.detail);
    try t.expectError(error.BadSyntax, parse(a, "   "));
    d = .{};
    try t.expectError(error.BadSyntax, parseWriteDiag(a, "set a\nset l items=<<END\nx\n", &d));
    try t.expectEqualStrings("line 2: no END line ends the value", d.detail);
    try t.expectEqual(@as(usize, 0), (try parseWrite(a, "\n \t\n")).len);
}

test "here-values and style" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    var cs = try parseWrite(a, "set n text=5\nset @reg append=<<END\nGrace\t40\nAda\t38\nEND\nset . title=Hi\n");
    try t.expectEqual(@as(usize, 3), cs.len);
    try t.expectEqualStrings("Grace\t40\nAda\t38", cs[1].attr("append").?);
    try t.expectEqualStrings("Hi", cs[2].attr("title").?);

    cs = try parseWrite(a, "tree f <<EOF\ndiv f\n  text t\nEOF\n");
    try expectStrs(&.{ "f", "div f\n  text t" }, cs[0].words);
    try t.expectEqual(Verb.tree, cs[0].kind());

    // The spec's own example (core.md § Commands).
    cs = try parseWrite(a,
        \\set . title=Counter size=320,200 pos=center : v-flex items-center p=24 gap=12
        \\new text n text=0 : text-3xl font-bold
        \\new button inc label=+1 primary tag=inc
        \\set list items=<<END
        \\inbox Inbox
        \\sent Sent
        \\END
    );
    try t.expectEqual(@as(usize, 4), cs.len);
    try expectStrs(&.{ "v-flex", "items-center", "p=24", "gap=12" }, cs[0].style.?);
    try expectStrs(&.{"primary"}, cs[2].bare());
    try expectStrs(&.{ "button", "inc", "primary" }, cs[2].words);
    try t.expectEqualStrings("inbox Inbox\nsent Sent", cs[3].attr("items").?);

    // Two here-values on one line follow it in order; a quoted <<END is a
    // plain value; the marker line is exactly the marker (CRLF allowed), so
    // an indented one is part of the body.
    cs = try parseWrite(a, "set x a=<<A b='<<B' c=<<C\none\nA\r\ntwo\n  C\n\nC\n");
    try t.expectEqualStrings("one", cs[0].attr("a").?);
    try t.expectEqualStrings("<<B", cs[0].attr("b").?);
    try t.expectEqualStrings("two\n  C\n", cs[0].attr("c").?);
    // An empty body is an empty value.
    cs = try parseWrite(a, "set x a=<<END\nEND\n");
    try t.expectEqualStrings("", cs[0].attr("a").?);

    var c = try parse(a, "new div dec tag=dec on=click : lg w=64 hover:bg=accent");
    try expectStrs(&.{ "div", "dec" }, c.words);
    try expectStrs(&.{ "lg", "w=64", "hover:bg=accent" }, c.style.?);
    try t.expectEqualStrings("dec", c.attr("tag").?);
    try t.expectEqual(@as(usize, 0), c.bare().len);

    // A quoted ':' is a word, not the separator; a trailing one is an empty
    // style.
    c = try parse(a, "set x text=':'");
    try t.expectEqualStrings(":", c.attr("text").?);
    try t.expect(c.style == null);
    c = try parse(a, "set x ':' y");
    try expectStrs(&.{ "x", ":", "y" }, c.words);
    c = try parse(a, "set x :");
    try t.expectEqual(@as(usize, 0), c.style.?.len);
}

test "format is canonical and reads back" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c: Ctl = .{
        .verb = "set",
        .words = &.{ "list", "a b", "<<x", ":" },
        .attrs = &.{
            .{ .key = "items", .value = "inbox Inbox\nEND\n" },
            .{ .key = "text", .value = "it's" },
            .{ .key = "v", .value = "<<END" },
        },
        .style = &.{ "p=4", "hover:bg=accent" },
    };
    const s = try formatted(a, c);
    try t.expectEqualStrings("set list 'a b' '<<x' ':' items=<<END2 text='it''s' v='<<END' : p=4 hover:bg=accent\ninbox Inbox\nEND\n\nEND2", s);
    // Several here-values on a line are END, END2, ...
    const two: Ctl = .{ .verb = "set", .words = &.{"t"}, .attrs = &.{ .{ .key = "columns", .value = "a A\nb B" }, .{ .key = "rows", .value = "1\tx\n2\ty" } } };
    const s2 = try formatted(a, two);
    try t.expectEqualStrings("set t columns=<<END rows=<<END2\na A\nb B\nEND\n1\tx\n2\ty\nEND2", s2);
    try t.expectEqualDeep(two, (try parseWrite(a, s2))[0]);
    const back = try parseWrite(a, s);
    try t.expectEqual(@as(usize, 1), back.len);
    try t.expectEqualDeep(c, back[0]);
}
