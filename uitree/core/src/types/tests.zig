//! Catalog tests over the real descriptors in core/types, including the
//! catalog-level half of uitreefs's crates/catalog/tests/forms.rs. The
//! other half of that file runs the tree (writes, reads, events) and moves
//! to W3's tree tests.

const std = @import("std");
const types = @import("root.zig");
const Catalog = types.Catalog;
const Diag = types.Diag;

fn builtin() !Catalog {
    return Catalog.builtin(std.testing.allocator);
}

test "every embedded descriptor parses and is named after its directory" {
    var c = try builtin();
    defer c.deinit();
    try std.testing.expectEqual(types.embedded.specs.len, c.all().len);
    for (types.embedded.specs) |s| {
        const t = c.lookup(s.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(s.text, c.specText(s.name).?);
        try std.testing.expectEqualStrings(s.name, t.name);
    }
    // In name order, as `ls $ui/types` lists them.
    for (c.all()[1..], c.all()[0 .. c.all().len - 1]) |b, a|
        try std.testing.expect(std.mem.order(u8, a.name, b.name) == .lt);
}

test "names use dashes" {
    var c = try builtin();
    defer c.deinit();
    for (c.all()) |t| {
        try std.testing.expect(std.mem.indexOfScalar(u8, t.name, '_') == null);
        for (t.props) |p| try std.testing.expect(std.mem.indexOfScalar(u8, p.name, '_') == null);
        for (t.events) |e| try std.testing.expect(std.mem.indexOfScalar(u8, e.name, '_') == null);
    }
    for (c.style_words) |w| try std.testing.expect(std.mem.indexOfScalar(u8, w.name, '_') == null);
    for (c.theme_tokens) |w| try std.testing.expect(std.mem.indexOfScalar(u8, w.name, '_') == null);
}

test "profile types are tagged with their profile" {
    var c = try builtin();
    defer c.deinit();
    for (types.profiles) |p| for (p.types) |n| {
        const t = c.lookup(n) orelse continue;
        std.testing.expectEqualStrings(p.name, t.profile orelse "") catch |e| {
            std.debug.print("{s}: profile {?s}, want {s}\n", .{ n, t.profile, p.name });
            return e;
        };
    };
    // Every type that claims a profile is in that profile's list.
    for (c.all()) |t| if (t.profile) |pn| {
        var found = false;
        for (types.profiles) |p| if (std.mem.eql(u8, p.name, pn)) {
            for (p.types) |n| found = found or std.mem.eql(u8, n, t.name);
        };
        try std.testing.expect(found);
    };
}

test "profiles the builtin catalog claims" {
    var c = try builtin();
    defer c.deinit();
    for ([_][]const u8{ "core", "canvas", "form", "data", "overlay", "nav", "layout", "feedback", "web" }) |p|
        try std.testing.expect(c.claims(p));
    try std.testing.expect(c.claims("overlay"));
    // No file-chooser yet (see core/types/README.md).
    try std.testing.expect(!c.claims("desktop"));
    try std.testing.expect(!c.claims("nonsense"));
}

test "the portable style words are all there" {
    var c = try builtin();
    defer c.deinit();
    const portable =
        \\flex flex-row flex-col v-flex h-flex flex-1 flex-wrap flex-none
        \\items-start items-center items-end items-stretch items-baseline
        \\justify-start justify-center justify-end justify-between
        \\gap= p= px= py= pt= pb= pl= pr= m= mx= my=
        \\w= h= min-w= min-h= max-w= max-h= size-full w-full h-full
        \\absolute relative top= left= right= bottom=
        \\overflow-hidden overflow-y-scroll overflow-x-scroll
        \\bg= text-color= border-1 border-color= rounded-sm rounded-md rounded-lg
        \\text-xs text-sm text-base text-lg text-xl font-semibold font-bold
        \\text-left text-center text-right truncate
    ;
    var it = std.mem.tokenizeAny(u8, portable, " \n");
    while (it.next()) |w| {
        const name = std.mem.trimEnd(u8, w, "=");
        const e = c.styleWord(name) orelse {
            std.debug.print("missing portable word {s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(name.len != w.len, e.arg != .none);
    }
}

// ---------------------------------------------------------------- forms.rs

test "every form type is a component" {
    var c = try builtin();
    defer c.deinit();
    for ([_][]const u8{
        "button",   "button-group", "dropdown-button", "checkbox",     "radio-group", "switch",
        "toggle",   "slider",       "input",           "textarea",     "number-input", "otp-input",
        "select",   "combobox",     "date-picker",     "calendar",     "color-picker", "rating",
        "form",     "field",
    }) |n| {
        const t = c.lookup(n) orelse {
            std.debug.print("no spec {s}\n", .{n});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(types.Tier.component, t.tier);
    }
}

test "a form holds fields only, slots take their names" {
    var c = try builtin();
    defer c.deinit();
    var d: Diag = .{};
    const form = c.lookup("form").?;
    try c.checkChild(form, "field", "name", &d);
    try std.testing.expectError(error.UnknownType, c.checkChild(form, "button", "x", &d));
    const input = c.lookup("input").?;
    try c.checkChild(input, "icon", "prefix", &d);
    try c.checkChild(input, "text", "suffix", &d);
    try std.testing.expectError(error.BadValue, c.checkChild(input, "text", "middle", &d));
    const group = c.lookup("button-group").?;
    try c.checkChild(group, "button", "a", &d);
    try std.testing.expectError(error.UnknownType, c.checkChild(group, "checkbox", "c", &d));
    try std.testing.expectError(error.UnknownType, c.checkChild(c.lookup("dropdown-button").?, "div", "x", &d));
    try c.checkChild(c.lookup("field").?, "input", "in", &d);
    try std.testing.expectError(error.UnknownType, c.checkChild(c.lookup("div").?, "gizmo", "g", &d));
    // A sidebar's named slots, plus sidebar-group children under any name.
    const sb = c.lookup("sidebar").?;
    try c.checkChild(sb, "div", "header", &d);
    try c.checkChild(sb, "sidebar-group", "main", &d);
    try std.testing.expectError(error.UnknownType, c.checkChild(sb, "div", "main", &d));
}

test "checkbox, switch, rating, slider and number values" {
    var c = try builtin();
    defer c.deinit();
    var d: Diag = .{};
    const cb = c.lookup("checkbox").?;
    try std.testing.expectEqualStrings("off", cb.prop("value").?.default.?);
    for ([_][]const u8{ "on", "mixed", "off", "" }) |v| try c.checkProp(cb, "value", v, &d);
    try std.testing.expectError(error.BadValue, c.checkProp(cb, "value", "yes", &d));
    try std.testing.expectEqualStrings("value: one of on off mixed", d.detail());
    try c.checkProp(cb, "controlled", "on", &d);
    try std.testing.expectError(error.BadValue, c.checkProp(cb, "controlled", "maybe", &d));
    try std.testing.expectEqualStrings("controlled: on or off", d.detail());

    try std.testing.expectError(error.BadValue, c.checkProp(c.lookup("switch").?, "value", "maybe", &d));
    try std.testing.expectError(error.BadValue, c.checkProp(c.lookup("rating").?, "value", "lots", &d));
    const sl = c.lookup("slider").?;
    try c.checkProp(sl, "value", "40", &d);
    try c.checkProp(sl, "value", "20 80", &d);
    try std.testing.expectError(error.BadValue, c.checkProp(sl, "value", "loud", &d));
    try std.testing.expectError(error.BadValue, c.checkProp(c.lookup("number-input").?, "value", "three", &d));
    try std.testing.expectError(error.NotFound, c.checkProp(sl, "volume", "1", &d));
}

test "number bounds: progress takes 0 to 100, or empty" {
    var c = try builtin();
    defer c.deinit();
    var d: Diag = .{};
    const p = c.lookup("progress").?;
    for ([_][]const u8{ "0", "40", "100", "", "40\n" }) |v| try c.checkProp(p, "value", v, &d);
    try std.testing.expectError(error.BadValue, c.checkProp(p, "value", "140", &d));
    try std.testing.expectEqualStrings("value: 140 out of range", d.detail());
    try std.testing.expectError(error.BadValue, c.checkProp(p, "value", "-1", &d));
    try std.testing.expectError(error.BadValue, c.checkProp(p, "value", "half", &d));
}

test "date, color and readonly values" {
    var c = try builtin();
    defer c.deinit();
    var d: Diag = .{};
    try c.checkProp(c.lookup("date-picker").?, "value", "2026-11-01 2026-11-30", &d);
    try c.checkProp(c.lookup("color-picker").?, "value", "#0b5cffff", &d);
    try std.testing.expectError(error.BadValue, c.checkProp(c.lookup("combobox").?, "query", "x", &d));
    try std.testing.expectEqualStrings("read-only: query", d.detail());
    try std.testing.expectError(error.BadValue, c.checkProp(c.lookup("dialog").?, "open", "on", &d));
}

test "bare words: flags, variants, sizes" {
    var c = try builtin();
    defer c.deinit();
    var d: Diag = .{};
    const sel = c.lookup("select").?;
    try std.testing.expectEqual(types.WordKind.flag, (try c.checkWord(sel, "searchable", &d)).kind);
    const input = c.lookup("input").?;
    try std.testing.expectEqual(types.WordKind.flag, (try c.checkWord(input, "secret", &d)).kind);
    const b = c.lookup("button").?;
    try std.testing.expectEqual(types.WordKind.variant, (try c.checkWord(b, "primary", &d)).kind);
    try std.testing.expectEqual(types.WordKind.size, (try c.checkWord(b, "lg", &d)).kind);
    try std.testing.expectError(error.BadValue, c.checkWord(b, "sparkly", &d));
    try std.testing.expectError(error.BadValue, c.checkWord(c.lookup("div").?, "primary", &d));
}

test "variant and size words in style" {
    var c = try builtin();
    defer c.deinit();
    var d: Diag = .{};
    const b = c.lookup("button").?;
    for ([_][]const u8{ "primary", "outline sm", "danger ghost", "link xs", "success lg w-full" }) |s|
        try c.checkStyle(b, s, &d);
    try c.checkStyle(c.lookup("select").?, "sm w=200", &d);
    try c.checkStyle(c.lookup("toggle").?, "outline", &d);
    try std.testing.expectError(error.UnknownStyleWord, c.checkStyle(c.lookup("toggle").?, "primary", &d));
    try std.testing.expectEqualStrings("primary", d.detail());
    try std.testing.expectError(error.UnknownStyleWord, c.checkStyle(c.lookup("select").?, "primary", &d));
    try std.testing.expectError(error.UnknownStyleWord, c.checkStyle(c.lookup("div").?, "primary", &d));
    try std.testing.expectError(error.UnknownStyleWord, c.checkStyle(c.lookup("div").?, "sm", &d));
    try std.testing.expectError(error.UnknownStyleWord, c.checkStyle(null, "primary", &d));
    // `border` is a variant of nothing here and a length style word.
    try c.checkStyle(c.lookup("div").?, "border=2", &d);
}

test "style words, arguments and theme tokens" {
    var c = try builtin();
    defer c.deinit();
    var d: Diag = .{};
    const div = c.lookup("div").?;
    try c.checkStyle(div, "v-flex items-center p=24 gap=12 w=50% h=2rem bg=muted hover:bg=#ff000080 text-color=muted-foreground", &d);
    try c.checkStyle(div, "shadow=0,4,12,#0003 group:card group-hover(card):bg=accent opacity=0.5", &d);
    try std.testing.expectError(error.UnknownStyleWord, c.checkStyle(div, "flex_col", &d));
    try std.testing.expectError(error.UnknownStyleWord, c.checkStyle(div, "flex-col wobble", &d));
    try std.testing.expectEqualStrings("wobble", d.detail());
    try std.testing.expectError(error.BadValue, c.checkStyle(div, "bg=nosuchtoken", &d));
    try std.testing.expectError(error.BadValue, c.checkStyle(div, "flex-col=3", &d));
    try std.testing.expectError(error.BadValue, c.checkStyle(div, "w=wide", &d));
    try std.testing.expectError(error.UnknownStyleWord, c.checkStyle(div, "wobble:bg=red", &d));
    try std.testing.expectError(error.BadSyntax, c.checkStyle(div, "w=", &d));
    // A token the app defined in theme/tokens.
    const Mine = struct {
        fn ok(_: void, name: []const u8) bool {
            return std.mem.eql(u8, name, "brand");
        }
    };
    try std.testing.expectError(error.BadValue, c.checkStyle(div, "bg=brand", &d));
    try c.checkStyleWith(div, "bg=brand", &d, {}, Mine.ok);
}

test "data props have formats, types have specs" {
    var c = try builtin();
    defer c.deinit();
    try std.testing.expectEqualStrings("items", c.lookup("select").?.format("items").?);
    try std.testing.expectEqualStrings("columns", c.lookup("table").?.format("columns").?);
    try std.testing.expectEqualStrings("tree-items", c.lookup("tree").?.format("items").?);
    try std.testing.expectEqualStrings("ops", c.lookup("canvas").?.format("ops").?);
    try std.testing.expectEqualStrings("icon-items", c.lookup("icon-view").?.format("items").?);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("table 1.0\n", c.lookup("table").?.version(&buf));
    try std.testing.expect(c.specText("gizmo") == null);
}

test "overlays take open and close; events have kinds" {
    var c = try builtin();
    defer c.deinit();
    for (c.all()) |t| if (t.tier == .overlay) {
        try std.testing.expect(t.verb("open") != null);
        try std.testing.expect(t.verb("close") != null);
    };
    const ev = struct {
        fn k(cat: *const Catalog, t: []const u8, e: []const u8) ?types.EventKind {
            return if (cat.lookup(t).?.event(e)) |x| x.kind else null;
        }
    }.k;
    try std.testing.expectEqual(types.EventKind.state, ev(&c, "list", "select").?);
    try std.testing.expectEqual(types.EventKind.action, ev(&c, "list", "scrolled-to-end").?);
    try std.testing.expectEqual(types.EventKind.request, ev(&c, "tab", "close").?);
    try std.testing.expectEqual(types.EventKind.request, ev(&c, "dialog", "close").?);
    try std.testing.expectEqual(types.EventKind.state, ev(&c, "chart", "select").?);
}

test "I6: a renderer's registered types must be the core's" {
    var c = try builtin();
    defer c.deinit();
    var d: Diag = .{};
    const n = try c.checkRegistered(std.testing.allocator, types.embedded.specs[0].text ++ types.embedded.specs[1].text, &d);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectError(error.UnknownType, c.checkRegistered(std.testing.allocator, "type gizmo tier=element\n", &d));
    try std.testing.expectEqualStrings("gizmo", d.detail());
}

test "Catalog.parse takes several descriptors and refuses duplicates" {
    var d: Diag = .{};
    var c = try Catalog.parse(std.testing.allocator, "type b tier=element\nchild any\n\ntype a tier=element\n", &d);
    defer c.deinit();
    try std.testing.expectEqualStrings("a", c.all()[0].name);
    try std.testing.expect(c.lookup("b").?.child == .any);
    try std.testing.expectError(error.BadSyntax, Catalog.parse(std.testing.allocator, "type a tier=element\ntype a tier=element\n", &d));
    try std.testing.expectError(error.BadSyntax, Catalog.parse(std.testing.allocator, "child any\n", &d));
}

test "the terminal descriptor (the terminal contracts, C2)" {
    var c = try builtin();
    defer c.deinit();
    const t = c.lookup("terminal").?;
    try std.testing.expectEqualStrings("desktop", t.profile.?);
    try std.testing.expect(t.child == .none);
    // Stream mode's two files: out is written, keys only the host writes.
    try std.testing.expect(t.file("out").?.stream and !t.prop("out").?.readonly);
    try std.testing.expect(t.file("keys").?.stream and t.prop("keys").?.readonly);
    for ([_][]const u8{ "screen", "selection" }) |n| try std.testing.expect(t.prop(n).?.file and t.prop(n).?.readonly);
    for ([_][]const u8{ "tty", "cols", "rows", "title", "cwd" }) |n| try std.testing.expect(t.prop(n).?.readonly);
    try std.testing.expectEqualStrings("off", t.prop("pty").?.default.?);
    try std.testing.expectEqualStrings("10000", t.prop("scrollback").?.default.?);
    try std.testing.expectEqual(types.Class.keys, t.verb("paste").?.class.?);
    try std.testing.expectEqual(types.Class.edit, t.verb("write").?.class.?);
    try std.testing.expectEqual(types.EventKind.action, t.event("hangup").?.kind);
    try std.testing.expectEqualStrings("rows", t.event("resize").?.attrs[1]);
}
