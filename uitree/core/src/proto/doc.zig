//! Tree documents and `.ui` files (protocols/core.md § Documents).
//!
//! ```text
//! div root  : v-flex size-full p=24 gap=16
//!   text title  text='Sign in'  : text-xl font-semibold
//!   markdown help  text=<<END
//! # Help
//!
//! Some *markdown*.
//!   END
//! ```
//!
//! Each line is `TYPE NAME [word ...] [prop=value ...] [: style ...]`, two
//! spaces of indent per level below its parent, exactly one root at no
//! indent. Blank lines between nodes are ignored.
//!
//! A value written `prop=<<MARK` (unquoted, `MARK` of letters, digits and
//! `_`) is a block: the lines after the node line, verbatim, up to a line
//! holding only `MARK` (leading spaces allowed), joined with `\n`. A value
//! ending in a newline has an empty last line. Several blocks on one line
//! follow it in order.
//!
//! The canonical form, which `print` writes: `type name` with one space,
//! two spaces before each bare word, prop and the style, values quoted only
//! when needed, a block for every value holding a newline (marker `END`, or
//! `END1`, `END2`... if the text has such a line), the marker at the node's
//! indent. `parse(print(x)) == x`, and canonical input prints back byte for
//! byte.

const std = @import("std");
const tokenize = @import("tokenize.zig");
const err = @import("err.zig");
const ctl = @import("ctl.zig");

const Allocator = std.mem.Allocator;
const Diag = err.Diag;
const Error = err.Error;
const Attr = ctl.Attr;
const Ctl = ctl.Ctl;

pub const Node = struct {
    type: []const u8,
    name: []const u8,
    /// Bare words: booleans, flags, variants (`stripe`, `secret`, `primary`).
    words: []const []const u8 = &.{},
    attrs: []const Attr = &.{},
    /// The words after a lone `:`; null when there is none.
    style: ?[]const []const u8 = null,
    children: []const Node = &.{},

    pub fn attr(self: Node, k: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.key, k)) return a.value;
        return null;
    }

    pub fn child(self: Node, name: []const u8) ?*const Node {
        for (self.children) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

const Builder = struct {
    node: Node,
    children: std.ArrayList(Node) = .empty,

    fn finish(self: *Builder, arena: Allocator) !Node {
        var n = self.node;
        n.children = try self.children.toOwnedSlice(arena);
        return n;
    }
};

fn isBlankLine(l: []const u8) bool {
    for (l) |c| if (!tokenize.isBlank(c)) return false;
    return true;
}

fn isBareWord(w: []const u8) bool {
    if (w.len == 0 or !(std.ascii.isAlphabetic(w[0]) or w[0] == '_')) return false;
    for (w) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

pub fn parse(arena: Allocator, text: []const u8) Error!Node {
    return parseDiag(arena, text, null);
}

/// Errors are `bad syntax: line N: ...`, or `too large` past the depth
/// limit.
pub fn parseDiag(arena: Allocator, text: []const u8, d: ?*Diag) Error!Node {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(arena, l);
    const all = lines.items;

    // stack.items[k] is the open node at depth k.
    var stack: std.ArrayList(Builder) = .empty;
    var i: usize = 0;
    while (i < all.len) {
        const line = all[i];
        const n = i + 1;
        i += 1;
        if (isBlankLine(line)) continue;
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (line[indent] == '\t') return err.fail(d, arena, .bad_syntax, "line {d}: tab in indent", .{n});
        if (indent % 2 != 0) return err.fail(d, arena, .bad_syntax, "line {d}: odd indent", .{n});
        const depth = indent / 2;
        if (depth > stack.items.len) return err.fail(d, arena, .bad_syntax, "line {d}: indent skips a level", .{n});
        if (depth == 0 and stack.items.len > 0) return err.fail(d, arena, .bad_syntax, "line {d}: more than one root", .{n});
        if (depth + 1 > err.limits.node_depth)
            return err.fail(d, arena, .too_large, "line {d}: deeper than {d}", .{ n, err.limits.node_depth });

        const ts = tokenize.tokenize(arena, line) catch |e| switch (e) {
            error.UnterminatedQuote => return err.fail(d, arena, .bad_syntax, "line {d}: unterminated quote", .{n}),
            error.OutOfMemory => return error.OutOfMemory,
        };
        var end = ts.len;
        var style: ?[]const []const u8 = null;
        for (ts, 0..) |tk, k| if (tk.isStyleColon()) {
            const sw = try arena.alloc([]const u8, ts.len - k - 1);
            for (ts[k + 1 ..], sw) |x, *o| o.* = x.text;
            style = sw;
            end = k;
            break;
        };
        if (end < 2) return err.fail(d, arena, .bad_syntax, "line {d}: want type and name", .{n});
        for (ts[0..2]) |tk| if (tk.attr() != null)
            return err.fail(d, arena, .bad_syntax, "line {d}: want type and name before {s}", .{ n, tk.text });
        if (ts[0].text.len == 0 or ts[1].text.len == 0)
            return err.fail(d, arena, .bad_syntax, "line {d}: empty type or name", .{n});

        var words: std.ArrayList([]const u8) = .empty;
        var attrs: std.ArrayList(Attr) = .empty;
        const Block = struct { index: usize, marker: []const u8 };
        var blocks: std.ArrayList(Block) = .empty;
        for (ts[2..end]) |tk| {
            const a = tk.attr() orelse {
                if (tk.quoted or !isBareWord(tk.text))
                    return err.fail(d, arena, .bad_syntax, "line {d}: want prop=value or a flag, got {s}", .{ n, tk.text });
                try words.append(arena, tk.text);
                continue;
            };
            if (!tk.quoted) if (ctl.hereMarker(a.value)) |m| {
                try blocks.append(arena, .{ .index = attrs.items.len, .marker = m });
                try attrs.append(arena, .{ .key = a.key, .value = "" });
                continue;
            };
            try attrs.append(arena, .{ .key = a.key, .value = a.value });
        }
        for (blocks.items) |b| {
            const start = i;
            while (true) {
                if (i >= all.len) return err.fail(d, arena, .bad_syntax, "line {d}: no {s} line ends the block", .{ n, b.marker });
                i += 1;
                if (std.mem.eql(u8, std.mem.trimStart(u8, all[i - 1], " "), b.marker)) break;
            }
            attrs.items[b.index].value = try std.mem.join(arena, "\n", all[start .. i - 1]);
        }

        while (stack.items.len > depth) {
            var c = stack.pop().?;
            const done = try c.finish(arena);
            try stack.items[stack.items.len - 1].children.append(arena, done);
        }
        try stack.append(arena, .{ .node = .{
            .type = ts[0].text,
            .name = ts[1].text,
            .words = try words.toOwnedSlice(arena),
            .attrs = try attrs.toOwnedSlice(arena),
            .style = style,
        } });
    }
    while (stack.items.len > 1) {
        var c = stack.pop().?;
        const done = try c.finish(arena);
        try stack.items[stack.items.len - 1].children.append(arena, done);
    }
    var root = stack.pop() orelse return err.fail(d, arena, .bad_syntax, "empty document", .{});
    return root.finish(arena);
}

/// `END`, or `END1`, `END2`... if the value has a line that reads as one.
fn markerFor(buf: *[24]u8, v: []const u8) []const u8 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const m = if (i == 0) "END" else std.fmt.bufPrint(buf, "END{d}", .{i}) catch unreachable;
        var taken = false;
        var it = std.mem.splitScalar(u8, v, '\n');
        while (it.next()) |l| if (std.mem.eql(u8, std.mem.trimStart(u8, l, " "), m)) {
            taken = true;
        };
        if (!taken) return m;
    }
}

fn printNode(w: *std.Io.Writer, n: Node, depth: usize) std.Io.Writer.Error!void {
    for (0..depth) |_| try w.writeAll("  ");
    try tokenize.quoteWord(w, n.type);
    try w.writeByte(' ');
    try tokenize.quoteWord(w, n.name);
    for (n.words) |x| {
        try w.writeAll("  ");
        try tokenize.quoteWord(w, x);
    }
    var nblocks: usize = 0;
    for (n.attrs) |a| {
        try w.print("  {s}=", .{a.key});
        if (std.mem.indexOfScalar(u8, a.value, '\n') != null) {
            var buf: [24]u8 = undefined;
            try w.print("<<{s}", .{markerFor(&buf, a.value)});
            nblocks += 1;
        } else try tokenize.quoteValue(w, a.value);
    }
    if (n.style) |st| {
        try w.writeAll("  :");
        for (st) |x| {
            try w.writeByte(' ');
            try tokenize.quote(w, x);
        }
    }
    try w.writeByte('\n');
    if (nblocks > 0) for (n.attrs) |a| {
        if (std.mem.indexOfScalar(u8, a.value, '\n') == null) continue;
        var buf: [24]u8 = undefined;
        try w.writeAll(a.value);
        try w.writeByte('\n');
        for (0..depth) |_| try w.writeAll("  ");
        try w.writeAll(markerFor(&buf, a.value));
        try w.writeByte('\n');
    };
    for (n.children) |c| try printNode(w, c, depth + 1);
}

/// The canonical document, ending in a newline.
pub fn print(w: *std.Io.Writer, root: Node) std.Io.Writer.Error!void {
    return printNode(w, root, 0);
}

fn joinPath(arena: Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return name;
    if (base[base.len - 1] == '/') return std.mem.concat(arena, u8, &.{ base, name });
    return std.mem.concat(arena, u8, &.{ base, "/", name });
}

fn emit(arena: Allocator, out: *std.ArrayList(Ctl), n: Node, path: []const u8) !void {
    const words = try arena.alloc([]const u8, 2 + n.words.len);
    words[0] = n.type;
    words[1] = path;
    @memcpy(words[2..], n.words);
    try out.append(arena, .{ .verb = "new", .words = words, .attrs = n.attrs, .style = n.style });
    for (n.children) |c| try emit(arena, out, c, try joinPath(arena, path, c.name));
}

/// The document as `new` commands, parents first: the root becomes
/// `new TYPE PATH ...` at `path`, and each child is made under its
/// parent's path. Applying them in one write builds the same subtree.
pub fn toCtls(arena: Allocator, root: Node, path: []const u8) Error![]Ctl {
    var out: std.ArrayList(Ctl) = .empty;
    try emit(arena, &out, root, path);
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// tests: uitreefs/crates/proto/tests/snippets.rs (signin_tree_round_trips,
// notes_tree_parses, heredoc_blocks, doc_errors, docs_bare_words_and_style),
// renamed to 0.2.

const t = std.testing;

fn printed(a: Allocator, n: Node) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try print(&aw.writer, n);
    return aw.written();
}

/// The spec's own document (core.md § Documents) plus a link.
const signin =
    \\div root  : v-flex size-full p=24 gap=16
    \\  text title  text='Sign in'  : text-xl font-semibold
    \\  form f  tag=login
    \\    field user  label=Email
    \\      input in  placeholder=you@example.com
    \\    field pass  label=Password
    \\      input in  secret
    \\    field go
    \\      button submit  label='Sign in'  tag=login  : primary w-full
    \\  link help  label='Forgot password?'  href=https://example.com/reset
    \\
;

fn expectStrs(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |x, y| try t.expectEqualStrings(x, y);
}

test "signin round-trips byte for byte" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const d = try parse(a, signin);
    try t.expectEqualStrings("div", d.type);
    try t.expectEqualStrings("root", d.name);
    try expectStrs(&.{ "v-flex", "size-full", "p=24", "gap=16" }, d.style.?);
    try t.expectEqual(@as(usize, 3), d.children.len);
    try t.expectEqualStrings("Sign in", d.child("title").?.attr("text").?);
    const submit = d.child("f").?.child("go").?.child("submit").?;
    try t.expectEqualStrings("button", submit.type);
    try t.expectEqualStrings("Sign in", submit.attr("label").?);
    try t.expectEqualStrings("login", d.child("f").?.attr("tag").?);
    try expectStrs(&.{"secret"}, d.child("f").?.child("pass").?.child("in").?.words);
    try t.expectEqualStrings("https://example.com/reset", d.child("help").?.attr("href").?);
    try t.expectEqualStrings(signin, try printed(a, d));
}

test "non-canonical input is stable once printed" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const notes =
        \\div root  : h-flex size-full
        \\  sidebar nav  : w=220
        \\    list notes  searchable  selectable  tag=pick
        \\
        \\  div page  : v-flex flex-1
        \\    toolbar bar
        \\      button save  label=Save  icon=check  tag=save  : ghost sm
        \\      button del   label=Delete  icon=trash  tag=del  : ghost sm danger
        \\    editor body  language=markdown  soft-wrap  : flex-1
    ;
    const d = try parse(a, notes);
    try expectStrs(&.{"w=220"}, d.child("nav").?.style.?);
    const bar = d.child("page").?.child("bar").?;
    try t.expectEqualStrings("save", bar.children[0].name);
    try t.expectEqualStrings("del", bar.children[1].name);
    const p = try printed(a, d);
    try t.expectEqualDeep(d, try parse(a, p));
    try t.expectEqualStrings(p, try printed(a, try parse(a, p)));
}

test "here-value blocks" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\div root
        \\  markdown m  text=<<END  : p=4
        \\# Title
        \\
        \\Body with 'quotes' and  spaces.
        \\END
        \\  text t  text=short
        \\
    ;
    const d = try parse(a, src);
    const m = d.child("m").?;
    try t.expectEqualStrings("# Title\n\nBody with 'quotes' and  spaces.", m.attr("text").?);
    try expectStrs(&.{"p=4"}, m.style.?);
    const canonical =
        \\div root
        \\  markdown m  text=<<END  : p=4
        \\# Title
        \\
        \\Body with 'quotes' and  spaces.
        \\  END
        \\  text t  text=short
        \\
    ;
    try t.expectEqualStrings(canonical, try printed(a, d));
    try t.expectEqualDeep(d, try parse(a, canonical));

    // A value with an END line gets another marker; a trailing newline is
    // kept as an empty last line; a value starting << is quoted.
    const n: Node = .{ .type = "editor", .name = "e", .attrs = &.{
        .{ .key = "value", .value = "a\nEND\n" },
        .{ .key = "x", .value = "<<END" },
    } };
    const p = try printed(a, n);
    try t.expectEqualStrings("editor e  value=<<END1  x='<<END'\na\nEND\n\nEND1\n", p);
    try t.expectEqualDeep(n, try parse(a, p));
}

test "document errors" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_]struct { []const u8, []const u8 }{
        .{ "", "empty document" },
        .{ "div a\ndiv b\n", "more than one root" },
        .{ "div a\n    div b\n", "indent skips a level" },
        .{ "div a\n div b\n", "odd indent" },
        .{ "div a\n\tdiv b\n", "tab in indent" },
        .{ "div\n", "want type and name" },
        .{ "div a 'b'\n", "want prop=value" },
        .{ "div a  text=<<END\nno end\n", "no END line" },
        .{ "div a  x='open\n", "unterminated quote" },
        .{ "  div a\n", "indent skips a level" },
        .{ "div x=1\n", "want type and name before x=1" },
        .{ "div a : p=4\n  text\n", "line 2: want type and name" },
    };
    for (bad) |b| {
        var d: Diag = .{};
        try t.expectError(error.BadSyntax, parseDiag(a, b[0], &d));
        if (std.mem.indexOf(u8, d.detail, b[1]) == null) {
            std.debug.print("{f}: got {s}\n", .{ std.zig.fmtString(b[0]), d.detail });
            return error.TestUnexpectedResult;
        }
    }
    // Deeper than the node depth limit.
    var deep: std.Io.Writer.Allocating = .init(a);
    for (0..65) |k| {
        for (0..k) |_| try deep.writer.writeAll("  ");
        try deep.writer.writeAll("div d\n");
    }
    try t.expectError(error.TooLarge, parse(a, deep.written()));
}

test "bare words and style" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const d = try parse(a, "table t  stripe  selectable=row  sortable  alt=list : flex-1\n");
    try expectStrs(&.{ "stripe", "sortable" }, d.words);
    try t.expectEqualStrings("row", d.attr("selectable").?);
    try t.expectEqualStrings("list", d.attr("alt").?);
    try expectStrs(&.{"flex-1"}, d.style.?);
    try t.expectEqualStrings("table t  stripe  sortable  selectable=row  alt=list  : flex-1\n", try printed(a, d));
}

test "toCtls" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const d = try parse(a, signin);
    const cs = try toCtls(a, d, "win/main/screen");
    try t.expectEqual(@as(usize, 10), cs.len);
    var aw: std.Io.Writer.Allocating = .init(a);
    for (cs) |c| {
        try c.format(&aw.writer);
        try aw.writer.writeByte('\n');
    }
    try t.expectEqualStrings(
        \\new div win/main/screen : v-flex size-full p=24 gap=16
        \\new text win/main/screen/title text='Sign in' : text-xl font-semibold
        \\new form win/main/screen/f tag=login
        \\new field win/main/screen/f/user label=Email
        \\new input win/main/screen/f/user/in placeholder=you@example.com
        \\new field win/main/screen/f/pass label=Password
        \\new input win/main/screen/f/pass/in secret
        \\new field win/main/screen/f/go
        \\new button win/main/screen/f/go/submit label='Sign in' tag=login : primary w-full
        \\new link win/main/screen/help label='Forgot password?' href=https://example.com/reset
        \\
    , aw.written());
    try expectStrs(&.{"secret"}, cs[6].bare());
    // Relative to a ctl's own node, "." puts the children at bare names.
    const rel = try toCtls(a, d, ".");
    try expectStrs(&.{ "text", "title" }, rel[1].words);
}
