//! The descriptor grammar (components.md § The descriptor): `type`, `prop`,
//! `word`, `verb`, `event`, `slot`, `child` and `file` lines, tokenized
//! like any other protocol line. Unknown line keywords and unknown
//! attributes are ignored, so a newer descriptor still parses (README.md
//! § Ignore what you don't know). Blank lines and `#` lines are skipped.

const std = @import("std");
const tokenize = @import("../proto/tokenize.zig");
const types = @import("root.zig");

const Type = types.Type;
const Diag = types.Diag;

pub const ParseError = error{ BadSyntax, OutOfMemory };

/// Splits text holding one or more descriptors into one slice per
/// descriptor, each starting at its `type` line.
pub fn split(arena: std.mem.Allocator, text: []const u8) ParseError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: ?usize = null;
    var i: usize = 0;
    while (i < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = std.mem.trimStart(u8, text[i..end], " \t");
        if (std.mem.startsWith(u8, line, "type") and line.len > 4 and (line[4] == ' ' or line[4] == '\t')) {
            if (start) |s| try out.append(arena, text[s..i]);
            start = i;
        } else if (start == null and std.mem.trim(u8, line, " \t\r").len > 0 and line[0] != '#') {
            return error.BadSyntax;
        }
        i = end + 1;
    }
    if (start) |s| try out.append(arena, text[s..]);
    return out.toOwnedSlice(arena);
}

/// Parses one descriptor. Every string in the result is allocated in
/// `arena`, and `spec` is a copy of `text`.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: ?*Diag) ParseError!Type {
    var t: Type = .{ .name = "", .tier = .element, .spec = try arena.dupe(u8, text) };
    var props: std.ArrayList(types.Prop) = .empty;
    var words: std.ArrayList(types.Word) = .empty;
    var verbs: std.ArrayList(types.Verb) = .empty;
    var events: std.ArrayList(types.Event) = .empty;
    var slots: std.ArrayList(types.Slot) = .empty;
    var files: std.ArrayList(types.DataFile) = .empty;
    var have_type = false;
    var have_child = false;

    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t.spec, '\n');
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const toks = tokenize.tokenize(arena, line) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnterminatedQuote => return fail(diag, n, "unterminated quote"),
        };
        const kw = toks[0].text;
        const args = toks[1..];
        if (!have_type) {
            if (!std.mem.eql(u8, kw, "type")) return fail(diag, n, "first line must be type");
        }
        if (std.mem.eql(u8, kw, "type")) {
            if (have_type) return fail(diag, n, "second type line");
            have_type = true;
            const name = positional(args, 0) orelse return fail(diag, n, "type: no name");
            if (!isName(name)) return fail(diag, n, "type: bad name");
            t.name = name;
            const tier = attr(args, "tier") orelse return fail(diag, n, "type: no tier=");
            t.tier = std.meta.stringToEnum(types.Tier, tier) orelse return fail(diag, n, "type: bad tier");
            t.profile = attr(args, "profile");
            if (attr(args, "since")) |s| t.since = s;
        } else if (std.mem.eql(u8, kw, "prop")) {
            const name = positional(args, 0) orelse return fail(diag, n, "prop: no name");
            if (!isName(name)) return fail(diag, n, "prop: bad name");
            const form_tok = if (args.len > 1) args[1] else return fail(diag, n, "prop: no form");
            var p: types.Prop = .{ .name = name, .form = .text };
            if (form_tok.attr()) |a| {
                if (!std.mem.eql(u8, a.key, "enum")) return fail(diag, n, "prop: bad form");
                p.form = .{ .choice = try splitList(arena, a.value) };
                if (p.form.choice.len == 0) return fail(diag, n, "prop: empty enum");
            } else {
                p.form = formOf(form_tok.text) orelse return fail(diag, n, "prop: bad form");
            }
            for (args[2..]) |a| {
                if (a.attr()) |kv| {
                    if (std.mem.eql(u8, kv.key, "default")) {
                        p.default = kv.value;
                    } else if (std.mem.eql(u8, kv.key, "min") or std.mem.eql(u8, kv.key, "max")) {
                        const x = std.fmt.parseFloat(f64, kv.value) catch return fail(diag, n, "prop: bad bound");
                        if (std.mem.eql(u8, kv.key, "min")) p.min = x else p.max = x;
                    }
                } else if (std.mem.eql(u8, a.text, "file")) {
                    p.file = true;
                } else if (std.mem.eql(u8, a.text, "readonly")) {
                    p.readonly = true;
                }
            }
            if ((p.min != null or p.max != null) and p.form != .number) return fail(diag, n, "prop: bounds on a non-number");
            for (props.items) |q| if (std.mem.eql(u8, q.name, name)) return fail(diag, n, "prop: duplicate");
            try props.append(arena, p);
        } else if (std.mem.eql(u8, kw, "word")) {
            const kind_s = attr(args, "kind") orelse return fail(diag, n, "word: no kind=");
            const kind = std.meta.stringToEnum(types.WordKind, kind_s) orelse return fail(diag, n, "word: bad kind");
            var any = false;
            for (args) |a| {
                if (a.attr() != null) continue;
                if (!isName(a.text)) return fail(diag, n, "word: bad word");
                for (words.items) |w| if (std.mem.eql(u8, w.name, a.text)) return fail(diag, n, "word: duplicate");
                try words.append(arena, .{ .name = a.text, .kind = kind });
                any = true;
            }
            if (!any) return fail(diag, n, "word: no words");
        } else if (std.mem.eql(u8, kw, "verb")) {
            const name = positional(args, 0) orelse return fail(diag, n, "verb: no name");
            if (!isName(name)) return fail(diag, n, "verb: bad name");
            var v: types.Verb = .{ .name = name };
            var synopsis: std.ArrayList(u8) = .empty;
            for (args[1..]) |a| {
                if (a.attr()) |kv| if (std.mem.eql(u8, kv.key, "class")) {
                    v.class = std.meta.stringToEnum(types.Class, kv.value) orelse return fail(diag, n, "verb: bad class");
                    continue;
                };
                if (synopsis.items.len > 0) try synopsis.append(arena, ' ');
                try synopsis.appendSlice(arena, a.text);
            }
            v.args = try synopsis.toOwnedSlice(arena);
            for (verbs.items) |q| if (std.mem.eql(u8, q.name, name)) return fail(diag, n, "verb: duplicate");
            try verbs.append(arena, v);
        } else if (std.mem.eql(u8, kw, "event")) {
            const name = positional(args, 0) orelse return fail(diag, n, "event: no name");
            if (!isName(name)) return fail(diag, n, "event: bad name");
            const kind_s = attr(args, "kind") orelse return fail(diag, n, "event: no kind=");
            const kind = std.meta.stringToEnum(types.EventKind, kind_s) orelse return fail(diag, n, "event: bad kind");
            const attrs = if (attr(args, "attrs")) |s| try splitList(arena, s) else &.{};
            for (events.items) |q| if (std.mem.eql(u8, q.name, name)) return fail(diag, n, "event: duplicate");
            try events.append(arena, .{ .name = name, .kind = kind, .attrs = attrs });
        } else if (std.mem.eql(u8, kw, "slot")) {
            const name = positional(args, 0) orelse return fail(diag, n, "slot: no name");
            if (!isName(name)) return fail(diag, n, "slot: bad name");
            const acc = if (attr(args, "accepts")) |s| try splitList(arena, s) else &.{};
            for (slots.items) |q| if (std.mem.eql(u8, q.name, name)) return fail(diag, n, "slot: duplicate");
            try slots.append(arena, .{ .name = name, .accepts = acc });
        } else if (std.mem.eql(u8, kw, "child")) {
            if (have_child) return fail(diag, n, "second child line");
            have_child = true;
            const rule = positional(args, 0) orelse return fail(diag, n, "child: no rule");
            if (std.mem.eql(u8, rule, "any")) {
                t.child = .any;
            } else if (std.mem.eql(u8, rule, "none")) {
                t.child = .none;
            } else {
                t.child = .{ .types = try splitList(arena, rule) };
            }
        } else if (std.mem.eql(u8, kw, "file")) {
            const name = positional(args, 0) orelse return fail(diag, n, "file: no name");
            if (!isName(name)) return fail(diag, n, "file: bad name");
            const fmt = attr(args, "format") orelse return fail(diag, n, "file: no format=");
            var f: types.DataFile = .{ .name = name, .format = fmt };
            for (args[1..]) |a| if (a.attr() == null) {
                if (std.mem.eql(u8, a.text, "stream")) f.stream = true else if (std.mem.eql(u8, a.text, "readonly")) f.readonly = true;
            };
            if (f.stream and !std.mem.eql(u8, fmt, "bytes")) return fail(diag, n, "file: stream needs format=bytes");
            for (files.items) |q| if (std.mem.eql(u8, q.name, name)) return fail(diag, n, "file: duplicate");
            try files.append(arena, f);
        }
        // Any other keyword is from a newer spec: ignored.
    }
    if (!have_type) return fail(diag, 0, "no type line");

    // A `file` line with no prop of its name (icon-view's `items`, web's
    // `message`) is still a file under the node: a data prop, or bytes.
    for (files.items) |f| {
        const have = for (props.items) |q| {
            if (std.mem.eql(u8, q.name, f.name)) break true;
        } else false;
        if (!have) try props.append(arena, .{ .name = f.name, .form = if (std.mem.eql(u8, f.format, "bytes")) .bytes else .data, .file = true, .readonly = f.readonly });
    }
    t.props = try props.toOwnedSlice(arena);
    t.words = try words.toOwnedSlice(arena);
    t.verbs = try verbs.toOwnedSlice(arena);
    t.events = try events.toOwnedSlice(arena);
    t.slots = try slots.toOwnedSlice(arena);
    t.files = try files.toOwnedSlice(arena);

    // Cross-line rules.
    for (t.props) |p| if (p.form == .data and t.file(p.name) == null) {
        Diag.set(diag, "{s}: prop {s}: data with no file line", .{ t.name, p.name });
        return error.BadSyntax;
    };
    for (t.words) |w| if (w.kind == .flag) {
        const p = t.prop(w.name);
        if (p == null or p.?.form != .bool) {
            Diag.set(diag, "{s}: flag {s} names no bool prop", .{ t.name, w.name });
            return error.BadSyntax;
        }
    };
    return t;
}

fn fail(diag: ?*Diag, line: usize, what: []const u8) ParseError {
    Diag.set(diag, "line {d}: {s}", .{ line, what });
    return error.BadSyntax;
}

/// The i'th word that is not an attribute.
fn positional(toks: []const tokenize.Tok, i: usize) ?[]const u8 {
    var k: usize = 0;
    for (toks) |t| {
        if (t.attr() != null) continue;
        if (k == i) return t.text;
        k += 1;
    }
    return null;
}

fn attr(toks: []const tokenize.Tok, key: []const u8) ?[]const u8 {
    for (toks) |t| if (t.attr()) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
    return null;
}

fn splitList(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |x| if (x.len > 0) try out.append(arena, x);
    return out.toOwnedSlice(arena);
}

fn formOf(s: []const u8) ?types.Form {
    const map = [_]struct { []const u8, types.Form }{
        .{ "text", .text },   .{ "word", .word }, .{ "bool", .bool },   .{ "number", .number },
        .{ "path", .path },   .{ "child", .child }, .{ "data", .data }, .{ "bytes", .bytes },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], s)) return m[1];
    return null;
}

/// A spec name: lowercase words joined by `-`, or an `x.` extension name.
pub fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '.' => {},
        else => return false,
    };
    return std.ascii.isLower(s[0]);
}

const button =
    \\type    button  tier=component  profile=form  since=1.0
    \\prop    label     text
    \\prop    icon      word
    \\prop    loading   bool  default=off
    \\prop    disabled  bool  default=off
    \\word    primary secondary danger ghost link outline   kind=variant
    \\word    xs sm md lg                                   kind=size
    \\verb    click                                         class=activate
    \\event   click   kind=action
    \\event   focus   kind=state
    \\event   blur    kind=state
    \\slot    prefix  accepts=icon,svg,text
    \\slot    suffix  accepts=icon,svg,text
    \\child   any
    \\
;

test "the components.md button parses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), button, null);
    try std.testing.expectEqualStrings("button", t.name);
    try std.testing.expectEqual(types.Tier.component, t.tier);
    try std.testing.expectEqualStrings("form", t.profile.?);
    try std.testing.expectEqual(@as(usize, 4), t.props.len);
    try std.testing.expectEqualStrings("off", t.prop("loading").?.default.?);
    try std.testing.expectEqual(types.WordKind.size, t.word("lg").?.kind);
    try std.testing.expectEqual(types.Class.activate, t.verb("click").?.class.?);
    try std.testing.expectEqual(types.EventKind.state, t.event("blur").?.kind);
    try std.testing.expectEqual(@as(usize, 3), t.slot("prefix").?.accepts.len);
    try std.testing.expect(t.child == .any);
    try std.testing.expectEqualStrings(button, t.spec);
}

test "enum forms, file lines, verb synopses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\type    icon-view  tier=component  profile=desktop  since=1.0
        \\file    items  format=icon-items
        \\prop    selection  text  readonly
        \\prop    arrange    enum=free,grid,list  default=free
        \\prop    zoom       number  min=0.5 max=4
        \\prop    items      data  file
        \\verb    move     ID x,y                 class=edit
        \\verb    eval     n=N script=TEXT        class=author
        \\event   drop     kind=request attrs=drag,item
        \\x-new   ignored  by=old-readers
    , null);
    try std.testing.expectEqual(@as(usize, 3), t.prop("arrange").?.form.choice.len);
    try std.testing.expect(t.prop("selection").?.readonly);
    try std.testing.expectEqual(@as(f64, 4), t.prop("zoom").?.max.?);
    try std.testing.expect(t.prop("items").?.file);
    try std.testing.expectEqualStrings("icon-items", t.format("items").?);
    try std.testing.expectEqualStrings("ID x,y", t.verb("move").?.args);
    try std.testing.expectEqualStrings("n=N script=TEXT", t.verb("eval").?.args);
    try std.testing.expectEqual(types.Class.author, t.verb("eval").?.class.?);
    try std.testing.expectEqualStrings("item", t.event("drop").?.attrs[1]);
    try std.testing.expect(t.child == .none);
}

test "stream files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\type    terminal  tier=component  profile=desktop  since=1.0
        \\file    out   format=bytes  stream
        \\file    keys  format=bytes  stream  readonly
        \\file    log   format=bytes
    , null);
    try std.testing.expect(t.file("out").?.stream and !t.file("out").?.readonly);
    try std.testing.expect(t.file("keys").?.stream and t.file("keys").?.readonly);
    try std.testing.expect(!t.file("log").?.stream);
    // Each is a bytes file under the node; keys only the host writes.
    try std.testing.expect(t.prop("out").?.form == .bytes and t.prop("out").?.file);
    try std.testing.expect(t.prop("keys").?.readonly and !t.prop("out").?.readonly);
    var d: Diag = .{};
    try std.testing.expectError(error.BadSyntax, parse(arena.allocator(), "type x tier=element\nfile f format=items stream\n", &d));
    try std.testing.expectEqualStrings("line 2: file: stream needs format=bytes", d.detail());
}

test "bad descriptors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const bad = [_][]const u8{
        "prop x text\n",
        "type x\n",
        "type x tier=gadget\n",
        "type x tier=element\nprop y\n",
        "type x tier=element\nprop y colour\n",
        "type x tier=element\nprop y text\nprop y word\n",
        "type x tier=element\nword a\n",
        "type x tier=element\nword a kind=flag\n",
        "type x tier=element\nprop d data\n",
        "type x tier=element\nevent e kind=sometimes\n",
        "type x tier=element\nverb v class=root\n",
        "type x tier=element\nprop t text default='oops\n",
        "type X tier=element\n",
        "type x tier=element\nprop t text min=1\n",
        "type x tier=element\nprop n number max=lots\n",
    };
    for (bad) |s| {
        if (parse(a, s, &d)) |_| {
            std.debug.print("accepted: {s}\n", .{s});
            return error.TestUnexpectedResult;
        } else |e| try std.testing.expectEqual(error.BadSyntax, e);
    }
    _ = parse(a, "type x tier=element\nprop y colour\n", &d) catch {};
    try std.testing.expectEqualStrings("line 2: prop: bad form", d.detail());
}

test "split" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parts = try split(arena.allocator(), "# x\ntype a tier=element\nchild any\ntype b tier=element\n");
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("type a tier=element\nchild any\n", parts[0]);
    try std.testing.expectError(error.BadSyntax, split(arena.allocator(), "child any\ntype a tier=element\n"));
}
