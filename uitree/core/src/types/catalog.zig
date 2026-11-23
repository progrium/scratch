//! Catalog: every type a host builds, its style words and theme tokens,
//! and the checks the tree runs against them (interface I3).

const std = @import("std");
const types = @import("root.zig");
const descriptor = @import("descriptor.zig");
const style = @import("style.zig");
const embedded = @import("embedded.zig");

const Type = types.Type;
const Diag = types.Diag;
const Error = types.Error;

/// Size limits for a prop value, by form (uitreefs's tree limits).
pub const max_text: usize = 16 << 20;
pub const max_data: usize = 64 << 20;
pub const max_bytes: usize = 16 << 20;

/// A `theme/name` selection: the palette for each mode, either may be
/// null (the mode then falls to the one the selection has).
pub const ThemePick = struct {
    light: ?*const style.Theme = null,
    dark: ?*const style.Theme = null,
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    /// Types in name order. Pointers are stable until `deinit`.
    types: std.ArrayList(*const Type) = .empty,
    /// Sorted by name.
    style_words: []const style.Entry = &.{},
    /// In file order.
    theme_tokens: []const style.Token = &.{},
    /// The named themes the renderer registered (`uit_themes`), in its
    /// order. `theme/name` takes their names and family names.
    themes: []const style.Theme = &.{},

    /// An empty catalog.
    pub fn init(gpa: std.mem.Allocator) Catalog {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(c: *Catalog) void {
        c.arena.deinit();
        c.* = undefined;
    }

    /// A catalog of the descriptors in `text` (one or more, each starting
    /// at its `type` line). No style words or theme tokens: add them with
    /// `loadStyleWords` and `loadThemeTokens`.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8, diag: ?*Diag) Error!Catalog {
        var c = init(gpa);
        errdefer c.deinit();
        const parts = descriptor.split(c.arena.allocator(), text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadSyntax => {
                Diag.set(diag, "text before the first type line", .{});
                return error.BadSyntax;
            },
        };
        for (parts) |p| _ = try c.add(p, diag);
        return c;
    }

    /// Every descriptor in core/types, with style-words and theme-tokens:
    /// what uitree-headless serves.
    pub fn builtin(gpa: std.mem.Allocator) Error!Catalog {
        var c = init(gpa);
        errdefer c.deinit();
        var d: Diag = .{};
        for (embedded.specs) |s| _ = c.add(s.text, &d) catch |e| {
            std.log.err("types/{s}/spec: {s}", .{ s.name, d.detail() });
            return e;
        };
        try c.loadStyleWords(embedded.style_words);
        try c.loadThemeTokens(embedded.theme_tokens);
        return c;
    }

    /// Adds one descriptor. `BadSyntax` if it doesn't parse or the name is
    /// taken.
    pub fn add(c: *Catalog, text: []const u8, diag: ?*Diag) Error!*const Type {
        const a = c.arena.allocator();
        const t = try a.create(Type);
        t.* = descriptor.parse(a, text, diag) catch |e| return e;
        const at = c.index(t.name);
        if (at.found) {
            Diag.set(diag, "{s}: type defined twice", .{t.name});
            return error.BadSyntax;
        }
        try c.types.insert(a, at.i, t);
        return t;
    }

    pub fn loadStyleWords(c: *Catalog, text: []const u8) Error!void {
        const a = c.arena.allocator();
        c.style_words = try style.parseWords(a, try a.dupe(u8, text));
    }

    pub fn loadThemeTokens(c: *Catalog, text: []const u8) Error!void {
        const a = c.arena.allocator();
        c.theme_tokens = try style.parseTokens(a, try a.dupe(u8, text));
    }

    /// Replaces the named themes with those in `text` (style.parseThemes).
    /// `BadSyntax` if it doesn't parse, a name is given twice, or a theme
    /// sets a token the catalog doesn't have.
    pub fn loadThemes(c: *Catalog, text: []const u8, diag: ?*Diag) Error!void {
        const a = c.arena.allocator();
        const ts = style.parseThemes(a, try a.dupe(u8, text)) catch |e| {
            if (e == error.BadSyntax) Diag.set(diag, "themes: bad syntax", .{});
            return e;
        };
        for (ts, 0..) |t, i| {
            for (ts[0..i]) |u| if (std.mem.eql(u8, u.name, t.name)) {
                Diag.set(diag, "themes: {s}: named twice", .{t.name});
                return error.BadSyntax;
            };
            if (c.theme_tokens.len > 0) for (t.tokens) |p| if (!c.isThemeToken(p.name)) {
                Diag.set(diag, "themes: {s}: no token {s}", .{ t.name, p.name });
                return error.BadSyntax;
            };
        }
        c.themes = ts;
    }

    /// What `theme/name NAME` selects: a theme's own name picks that theme,
    /// whatever the mode; a family name picks the family's first light
    /// theme and its first dark one, and the mode chooses between them.
    /// Null: no theme or family has that name.
    pub fn pickTheme(c: *const Catalog, name: []const u8) ?ThemePick {
        for (c.themes) |*t| if (std.mem.eql(u8, t.name, name))
            return if (t.dark) .{ .dark = t } else .{ .light = t };
        var p: ThemePick = .{};
        for (c.themes) |*t| if (t.family.len > 0 and std.mem.eql(u8, t.family, name)) {
            if (t.dark) {
                if (p.dark == null) p.dark = t;
            } else if (p.light == null) p.light = t;
        };
        return if (p.light == null and p.dark == null) null else p;
    }

    fn index(c: *const Catalog, name: []const u8) struct { i: usize, found: bool } {
        var lo: usize = 0;
        var hi: usize = c.types.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            switch (std.mem.order(u8, c.types.items[mid].name, name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{ .i = mid, .found = true },
            }
        }
        return .{ .i = lo, .found = false };
    }

    // ------------------------------------------------------------ reads

    pub fn lookup(c: *const Catalog, name: []const u8) ?*const Type {
        const at = c.index(name);
        return if (at.found) c.types.items[at.i] else null;
    }

    /// Every type, in name order: what `ls $ui/types` lists.
    pub fn all(c: *const Catalog) []const *const Type {
        return c.types.items;
    }

    /// The text `$ui/types/NAME/spec` serves.
    pub fn specText(c: *const Catalog, name: []const u8) ?[]const u8 {
        return if (c.lookup(name)) |t| t.spec else null;
    }

    /// Whether the catalog builds every type of `profile`, so `version`
    /// may list it (components.md § Profiles).
    pub fn claims(c: *const Catalog, profile: []const u8) bool {
        for (types.profiles) |p| if (std.mem.eql(u8, p.name, profile)) {
            for (p.types) |n| if (c.lookup(n) == null) return false;
            return true;
        };
        return false;
    }

    pub fn styleWord(c: *const Catalog, name: []const u8) ?style.Entry {
        return style.lookup(c.style_words, name);
    }

    pub fn isThemeToken(c: *const Catalog, name: []const u8) bool {
        for (c.theme_tokens) |t| if (std.mem.eql(u8, t.name, name)) return true;
        return false;
    }

    /// Writes `$ui/style/words`: every style word the host accepts, one per
    /// line, in name order.
    pub fn writeStyleWords(c: *const Catalog, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (c.style_words) |e| {
            try w.writeAll(e.name);
            try w.writeByte('\n');
        }
    }

    // ------------------------------------------------------------ checks

    /// Checks a value written to prop `name` of a node of type `t`, by its
    /// form. The value is the bytes of a `set`/`new` attribute or a file
    /// write; the tree normalizes (trims a trailing newline) after.
    ///
    /// - `NotFound` if the type has no such prop.
    /// - `BadValue` (`read-only: NAME`) for a readonly prop.
    /// - `TooLarge` over the form's limit.
    /// - `BadValue` for a value of the wrong form. Empty clears any prop.
    ///
    /// `child` and `path` are checked for shape only (one word): whether the
    /// child or node exists is the tree's to decide. `data` is checked for
    /// UTF-8 only until proto.lines (W2) lands.
    pub fn checkProp(c: *const Catalog, t: *const Type, name: []const u8, value: []const u8, diag: ?*Diag) Error!void {
        _ = c;
        const p = t.prop(name) orelse {
            Diag.set(diag, "{s}", .{name});
            return error.NotFound;
        };
        if (p.readonly) {
            Diag.set(diag, "read-only: {s}", .{name});
            return error.BadValue;
        }
        return checkValue(p, value, diag);
    }

    /// The form and bounds check for a prop, without the readonly check
    /// (for the host's own writes).
    pub fn checkValue(p: *const types.Prop, value: []const u8, diag: ?*Diag) Error!void {
        try checkForm(p.form, p.name, value, diag);
        if (p.form != .number or (p.min == null and p.max == null)) return;
        var it = std.mem.tokenizeAny(u8, value, " \t\r\n,");
        while (it.next()) |x| {
            const f = std.fmt.parseFloat(f64, x) catch unreachable; // checkForm passed
            if ((p.min != null and f < p.min.?) or (p.max != null and f > p.max.?)) {
                Diag.set(diag, "{s}: {s} out of range", .{ p.name, x });
                return error.BadValue;
            }
        }
    }

    /// The form check alone, for callers that already hold the prop.
    pub fn checkForm(form: types.Form, name: []const u8, value: []const u8, diag: ?*Diag) Error!void {
        const limit: usize = switch (form) {
            .data => max_data,
            .bytes => max_bytes,
            else => max_text,
        };
        if (value.len > limit) {
            Diag.set(diag, "{s}", .{name});
            return error.TooLarge;
        }
        const v = std.mem.trim(u8, value, " \t\r\n");
        const bad = struct {
            fn f(d: ?*Diag, n: []const u8, what: []const u8) Error {
                Diag.set(d, "{s}: {s}", .{ n, what });
                return error.BadValue;
            }
        }.f;
        switch (form) {
            .text, .bytes => {},
            .data => if (!std.unicode.utf8ValidateSlice(value)) return bad(diag, name, "not utf-8"),
            .word, .child, .path => if (std.mem.indexOfAny(u8, v, " \t\r\n") != null) return bad(diag, name, "one word"),
            .bool => if (v.len > 0 and !isBool(v)) return bad(diag, name, "on or off"),
            .number => if (!isNumberList(v)) return bad(diag, name, "a number"),
            .choice => |opts| if (v.len > 0) {
                for (opts) |o| if (std.mem.eql(u8, o, v)) return;
                Diag.set(diag, "{s}: one of {f}", .{ name, Joined{ .items = opts } });
                return error.BadValue;
            },
        }
    }

    /// Checks a bare word in a `new` line or document line (core.md § Words
    /// and quoting) and returns what it is. Any other bare word is
    /// `bad value`.
    pub fn checkWord(c: *const Catalog, t: *const Type, word: []const u8, diag: ?*Diag) Error!types.Word {
        _ = c;
        if (t.word(word)) |w| return w;
        Diag.set(diag, "{s}: {s} takes no word {s}", .{ word, t.name, word });
        return error.BadValue;
    }

    /// Checks that a node of type `child_type` named `child_name` may be a
    /// child of a `parent` node: a slot of that name takes it, or the
    /// type's `child` rule does. `UnknownType` otherwise (core.md: "a child
    /// the parent can't hold"); also for a child type the catalog lacks.
    pub fn checkChild(c: *const Catalog, parent: *const Type, child_type: []const u8, child_name: []const u8, diag: ?*Diag) Error!void {
        if (c.lookup(child_type) == null) {
            Diag.set(diag, "{s}", .{child_type});
            return error.UnknownType;
        }
        if (parent.slot(child_name)) |s| {
            if (s.accepts.len == 0 or contains(s.accepts, child_type)) return;
            Diag.set(diag, "{s}: slot {s} takes {f}", .{ child_type, child_name, Joined{ .items = s.accepts, .sep = "," } });
            return error.UnknownType;
        }
        switch (parent.child) {
            .any => return,
            .none => {
                if (parent.slots.len > 0) {
                    // Only named slots: a name that isn't one is the error.
                    Diag.set(diag, "{s}: {s} has no slot {s}", .{ child_name, parent.name, child_name });
                    return error.BadValue;
                }
                Diag.set(diag, "{s}: {s} takes no children", .{ child_type, parent.name });
                return error.UnknownType;
            },
            .types => |ts| {
                if (contains(ts, child_type)) return;
                Diag.set(diag, "{s}: {s} takes {f}", .{ child_type, parent.name, Joined{ .items = ts, .sep = "," } });
                return error.UnknownType;
            },
        }
    }

    /// Checks a `style` file's text for a node of type `t` (null: a check
    /// with no type, which refuses every variant and size word). A style
    /// write never half-applies, so the first bad word fails the whole.
    ///
    /// - A size word (`sm`) needs a type with `kind=size` words.
    /// - A variant word (`primary`) is valid on a type that lists it. A word
    ///   that is both a variant and a style word with an argument
    ///   (`border`) is the style word wherever the variant doesn't apply.
    /// - Any other word must be in `style-words`, with arguments that fit
    ///   its kind. Color arguments take `#rrggbb[aa]` or a theme token.
    ///
    /// With no style words loaded, every word passes the table check.
    pub fn checkStyle(c: *const Catalog, t: ?*const Type, text: []const u8, diag: ?*Diag) Error!void {
        return c.checkStyleWith(t, text, diag, {}, struct {
            fn f(_: void, _: []const u8) bool {
                return false;
            }
        }.f);
    }

    /// `checkStyle` where `extra_token(ctx, name)` also accepts tokens the
    /// app defined in `theme/tokens`.
    pub fn checkStyleWith(
        c: *const Catalog,
        t: ?*const Type,
        text: []const u8,
        diag: ?*Diag,
        ctx: anytype,
        comptime extra_token: fn (@TypeOf(ctx), []const u8) bool,
    ) Error!void {
        var buf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        var arena: std.heap.ArenaAllocator = .init(if (text.len < 512) fba.allocator() else c.arena.child_allocator);
        defer arena.deinit();
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |raw| {
            const w = style.Word.parse(arena.allocator(), raw) catch |e| {
                Diag.set(diag, "{s}", .{raw});
                return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.BadSyntax => error.BadSyntax,
                    error.UnknownStyleWord => error.UnknownStyleWord,
                };
            };
            try c.checkStyleWord(t, w, raw, diag, ctx, extra_token);
        }
    }

    fn checkStyleWord(
        c: *const Catalog,
        t: ?*const Type,
        w: style.Word,
        raw: []const u8,
        diag: ?*Diag,
        ctx: anytype,
        comptime extra_token: fn (@TypeOf(ctx), []const u8) bool,
    ) Error!void {
        const unknown = struct {
            fn f(d: ?*Diag, n: []const u8) Error {
                Diag.set(d, "{s}", .{n});
                return error.UnknownStyleWord;
            }
        }.f;
        if (w.group != null) return;
        const entry = c.styleWord(w.name);
        const tw: ?types.Word = if (t) |ty| ty.word(w.name) else null;

        // Size words.
        if ((tw != null and tw.?.kind == .size) or (entry != null and entry.?.arg == .size)) {
            if (tw == null or tw.?.kind != .size or w.args.len > 0) return unknown(diag, w.name);
            return;
        }
        // Variant words, unless an argument makes it the style word.
        const style_word = entry != null and entry.?.arg != .variant and entry.?.arg != .size;
        if (tw != null and tw.?.kind == .variant and (w.args.len == 0 or !style_word)) {
            if (w.args.len > 0) {
                Diag.set(diag, "{s}", .{raw});
                return error.BadValue;
            }
            return;
        }
        if (c.style_words.len == 0) return;
        const e = entry orelse return unknown(diag, w.name);
        if (e.arg == .variant) return unknown(diag, w.name);
        const Ctx = struct {
            cat: *const Catalog,
            inner: @TypeOf(ctx),
            fn ok(self: @This(), name: []const u8) bool {
                return self.cat.theme_tokens.len == 0 or self.cat.isThemeToken(name) or extra_token(self.inner, name);
            }
        };
        if (!style.argsOk(e.arg, w.args, Ctx{ .cat = c, .inner = ctx }, Ctx.ok)) {
            Diag.set(diag, "style: {s}", .{raw});
            return error.BadValue;
        }
    }

    /// I6: checks the descriptors a renderer registers at `uit_create`
    /// against this catalog. Every type it registers must be one the core
    /// has (`UnknownType` otherwise). Returns how many it registered.
    pub fn checkRegistered(c: *const Catalog, gpa: std.mem.Allocator, text: []const u8, diag: ?*Diag) Error!usize {
        var theirs = try parse(gpa, text, diag);
        defer theirs.deinit();
        for (theirs.all()) |t| if (c.lookup(t.name) == null) {
            Diag.set(diag, "{s}", .{t.name});
            return error.UnknownType;
        };
        return theirs.all().len;
    }
};

fn isBool(v: []const u8) bool {
    return std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "off");
}

/// One or more decimals separated by blanks or `,` (`20 80`, `1,2`).
fn isNumberList(v: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, v, " \t,");
    var any = false;
    while (it.next()) |x| {
        if (!style.isNumber(x)) return false;
        any = true;
    }
    return any or v.len == 0;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

const Joined = struct {
    items: []const []const u8,
    sep: []const u8 = " ",
    pub fn format(j: Joined, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (j.items, 0..) |x, i| {
            if (i > 0) try w.writeAll(j.sep);
            try w.writeAll(x);
        }
    }
};
