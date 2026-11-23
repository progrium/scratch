//! Data-file line formats (protocols/components.md § Data file formats,
//! core.md § Keys, actions and menus), plus uitreefs's editor and
//! message-list formats for its host extras.
//!
//! Each format is a struct with `parse(arena, line, ?*Diag)` for one line
//! and `format(w)` for printing it without its newline. `parseLines` reads
//! a whole file of one format, skipping empty lines and a CR before each
//! LF; `printLines` writes one.
//!
//! Two families:
//!
//! - **Field lines** (`items`, `columns`, `rows`, `tree-items`,
//!   `desc-items`, `icon-items`, diagnostics, completions): a line with a
//!   tab is tab-separated fields, never quoted, and a line without one is
//!   Plan 9 words (`go Go`, `cob 'GnuCOBOL 3.2'`). So a script with no
//!   `printf` needs no tabs. `print` writes TSV, or words when a line has
//!   one field or would read as something else.
//! - **Word lines** (`menu`, `keys`, canvas `ops`): words in the one
//!   quoting rule, as on a `ctl` line, so `label='Open Recent'` works.

const std = @import("std");
const tokenize = @import("tokenize.zig");
const err = @import("err.zig");
const ctl = @import("ctl.zig");
const style = @import("style.zig");

const Allocator = std.mem.Allocator;
const Diag = err.Diag;
const Error = err.Error;
const Attr = ctl.Attr;
const Writer = std.Io.Writer;
const WErr = Writer.Error;

/// Every non-empty line of `text` as a `T`, all or nothing. The detail of
/// an error starts `line N` (1-based).
pub fn parseLines(comptime T: type, arena: Allocator, text: []const u8, d: ?*Diag) Error![]T {
    return parseLinesAt(T, arena, text, 1, d);
}

fn parseLinesAt(comptime T: type, arena: Allocator, text: []const u8, first: usize, d: ?*Diag) Error![]T {
    var out: std.ArrayList(T) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |raw| : (i += 1) {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len == 0) continue;
        const x = T.parse(arena, l, d) catch |e| {
            if (e != error.OutOfMemory) err.atLine(d, arena, i + first);
            return e;
        };
        try out.append(arena, x);
    }
    return out.toOwnedSlice(arena);
}

/// Each record, then a newline.
pub fn printLines(w: *Writer, recs: anytype) WErr!void {
    for (recs) |r| {
        try r.format(w);
        try w.writeByte('\n');
    }
}

/// A field-line file with each tab-free line of two or more words turned
/// into TSV. Group headers (`# `), separators (`-`) and one-word lines are
/// left alone. For a host that stores data files as TSV.
pub fn tabify(arena: Allocator, text: []const u8, d: ?*Diag) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 0;
    while (it.next()) |l| : (i += 1) {
        if (i > 0) try out.append(arena, '\n');
        const s = std.mem.trimEnd(u8, l, "\r");
        const trimmed = std.mem.trim(u8, s, " ");
        const needs = s.len > 0 and std.mem.indexOfScalar(u8, s, '\t') == null and
            !std.mem.startsWith(u8, s, "#") and !std.mem.eql(u8, trimmed, "-") and
            std.mem.indexOfAny(u8, trimmed, " '") != null;
        if (!needs) {
            try out.appendSlice(arena, l);
            continue;
        }
        const ws = ctl.tokens(arena, s, d) catch |e| {
            if (e != error.OutOfMemory) err.atLine(d, arena, i + 1);
            return e;
        };
        for (ws, 0..) |w, k| {
            if (k > 0) try out.append(arena, '\t');
            try out.appendSlice(arena, w.text);
        }
    }
    return out.toOwnedSlice(arena);
}

/// The fields of a field line: split on tabs if it has one, else Plan 9
/// words.
pub fn fields(arena: Allocator, line: []const u8, d: ?*Diag) Error![]const []const u8 {
    if (std.mem.indexOfScalar(u8, line, '\t') != null) {
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |f| try out.append(arena, f);
        return out.toOwnedSlice(arena);
    }
    const ts = try ctl.tokens(arena, line, d);
    const out = try arena.alloc([]const u8, ts.len);
    for (ts, out) |x, *o| o.* = x.text;
    return out;
}

/// Writes fields as TSV when there are two or more, else as a word. With
/// `groups`, a line whose first field would read as a group header or a
/// separator is written as words instead.
fn writeFields(w: *Writer, fs: []const []const u8, groups: bool) WErr!void {
    const first = if (fs.len > 0) fs[0] else "";
    const special = groups and (std.mem.eql(u8, first, "-") or std.mem.startsWith(u8, first, "# "));
    if (fs.len >= 2 and !special) {
        for (fs, 0..) |f, i| {
            if (i > 0) try w.writeByte('\t');
            try w.writeAll(f);
        }
        return;
    }
    for (fs, 0..) |f, i| {
        if (i > 0) try w.writeByte(' ');
        if (std.mem.eql(u8, f, "-")) try tokenize.quoteAlways(w, f) else try tokenize.quote(w, f);
    }
}

/// The rest of a field line from field `i`: as is in TSV; words joined by
/// one space otherwise.
fn rest(arena: Allocator, line: []const u8, fs: []const []const u8, i: usize) ![]const u8 {
    if (i >= fs.len) return "";
    if (std.mem.indexOfScalar(u8, line, '\t') != null) {
        var it = std.mem.splitScalar(u8, line, '\t');
        for (0..i) |_| _ = it.next();
        return it.rest();
    }
    return std.mem.join(arena, " ", fs[i..]);
}

fn needId(arena: Allocator, id: []const u8, what: []const u8, d: ?*Diag) Error![]const u8 {
    if (id.len == 0) return err.fail(d, arena, .bad_syntax, "{s} with no id", .{what});
    return id;
}

fn num(arena: Allocator, s: []const u8, d: ?*Diag) Error!f32 {
    return style.parseNumber(s) orelse err.fail(d, arena, .bad_value, "{s}", .{s});
}

// ---------------------------------------------------------------------------
// items: select, list, combobox, radio-group

/// An `items` line: `id label [icon=name] [disabled]`; `# text` is a group
/// header and a lone `-` a separator. Fields after the label other than
/// `icon=` and `disabled` are kept in order (a `list` row template's
/// columns).
pub const Item = union(enum) {
    entry: Entry,
    group: []const u8,
    separator,

    pub const Entry = struct {
        id: []const u8,
        /// Empty when the line has only an id.
        label: []const u8 = "",
        extra: []const []const u8 = &.{},
        icon: ?[]const u8 = null,
        disabled: bool = false,
    };

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!Item {
        if (std.mem.eql(u8, line, "-")) return .separator;
        if (std.mem.startsWith(u8, line, "# ")) return .{ .group = line[2..] };
        const fs = try fields(arena, line, d);
        var e: Entry = .{ .id = try needId(arena, if (fs.len > 0) fs[0] else "", "item", d) };
        if (fs.len > 1) e.label = fs[1];
        var extra: std.ArrayList([]const u8) = .empty;
        if (fs.len > 2) for (fs[2..]) |x| {
            if (std.mem.eql(u8, x, "disabled")) {
                e.disabled = true;
            } else if (e.icon == null and std.mem.startsWith(u8, x, "icon=")) {
                e.icon = x[5..];
            } else try extra.append(arena, x);
        };
        e.extra = try extra.toOwnedSlice(arena);
        return .{ .entry = e };
    }

    pub fn format(self: Item, w: *Writer) WErr!void {
        switch (self) {
            .separator => try w.writeByte('-'),
            .group => |g| try w.print("# {s}", .{g}),
            .entry => |e| {
                var buf: [64][]const u8 = undefined;
                var icon_buf: [256]u8 = undefined;
                var n: usize = 0;
                buf[n] = e.id;
                n += 1;
                buf[n] = e.label;
                n += 1;
                for (e.extra) |x| if (n < buf.len - 2) {
                    buf[n] = x;
                    n += 1;
                };
                if (e.icon) |ic| {
                    buf[n] = std.fmt.bufPrint(&icon_buf, "icon={s}", .{ic}) catch "icon=";
                    n += 1;
                }
                if (e.disabled) {
                    buf[n] = "disabled";
                    n += 1;
                }
                if (n == 2 and e.label.len == 0) n = 1;
                try writeFields(w, buf[0..n], true);
            },
        }
    }
};

// ---------------------------------------------------------------------------
// table columns and rows

pub const Align = enum { left, center, right };

/// A `columns` line: `id label [width] [sort] [fixed] [align=left|center|right]`.
/// The options may come in any order; `format` writes them in this one.
pub const Column = struct {
    id: []const u8,
    label: []const u8 = "",
    width: ?f32 = null,
    sort: bool = false,
    fixed: bool = false,
    @"align": ?Align = null,

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!Column {
        const fs = try fields(arena, line, d);
        var c: Column = .{ .id = try needId(arena, if (fs.len > 0) fs[0] else "", "column", d) };
        if (fs.len > 1) c.label = fs[1];
        if (fs.len > 2) for (fs[2..]) |x| {
            if (std.mem.eql(u8, x, "sort")) {
                c.sort = true;
            } else if (std.mem.eql(u8, x, "fixed")) {
                c.fixed = true;
            } else if (x.len == 0) {} else if (std.mem.startsWith(u8, x, "align=")) {
                c.@"align" = std.meta.stringToEnum(Align, x[6..]) orelse
                    return err.fail(d, arena, .bad_value, "{s}", .{x});
            } else if (c.width == null) {
                c.width = try num(arena, x, d);
            } else return err.fail(d, arena, .bad_value, "column option {s}", .{x});
        };
        return c;
    }

    pub fn format(self: Column, w: *Writer) WErr!void {
        var wb: [64]u8 = undefined;
        var buf: [6][]const u8 = undefined;
        var n: usize = 2;
        buf[0] = self.id;
        buf[1] = self.label;
        if (self.width) |x| {
            buf[n] = std.fmt.bufPrint(&wb, "{d}", .{x}) catch unreachable;
            n += 1;
        }
        if (self.sort) {
            buf[n] = "sort";
            n += 1;
        }
        if (self.fixed) {
            buf[n] = "fixed";
            n += 1;
        }
        if (self.@"align") |a| {
            buf[n] = switch (a) {
                .left => "align=left",
                .center => "align=center",
                .right => "align=right",
            };
            n += 1;
        }
        try writeFields(w, buf[0..n], false);
    }
};

/// A `rows` line: one field per column, in `columns` order; the first is
/// the row's id.
pub const Row = struct {
    id: []const u8,
    cells: []const []const u8 = &.{},

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!Row {
        const fs = try fields(arena, line, d);
        return .{ .id = try needId(arena, if (fs.len > 0) fs[0] else "", "row", d), .cells = if (fs.len > 1) fs[1..] else &.{} };
    }

    pub fn format(self: Row, w: *Writer) WErr!void {
        if (self.cells.len == 0) return writeFields(w, &.{self.id}, false);
        try w.writeAll(self.id);
        for (self.cells) |c| {
            try w.writeByte('\t');
            try w.writeAll(c);
        }
    }
};

// ---------------------------------------------------------------------------
// tree-items

/// A `tree-items` line: `id parent label [icon=name] [disabled]`, parent
/// `-` for a root.
pub const TreeItem = struct {
    id: []const u8,
    /// Null for a root.
    parent: ?[]const u8 = null,
    label: []const u8 = "",
    icon: ?[]const u8 = null,
    disabled: bool = false,

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!TreeItem {
        const fs = try fields(arena, line, d);
        const id = try needId(arena, if (fs.len > 0) fs[0] else "", "tree item", d);
        if (fs.len < 2 or fs[1].len == 0) return err.fail(d, arena, .bad_syntax, "tree item {s} has no parent (use -)", .{id});
        var ti: TreeItem = .{ .id = id, .parent = if (std.mem.eql(u8, fs[1], "-")) null else fs[1] };
        if (fs.len > 2) ti.label = fs[2];
        if (fs.len > 3) for (fs[3..]) |x| {
            if (std.mem.eql(u8, x, "disabled")) {
                ti.disabled = true;
            } else if (x.len == 0) {} else if (std.mem.startsWith(u8, x, "icon=")) {
                ti.icon = x[5..];
            } else return err.fail(d, arena, .bad_value, "tree item option {s}", .{x});
        };
        return ti;
    }

    pub fn format(self: TreeItem, w: *Writer) WErr!void {
        try w.print("{s}\t{s}\t{s}", .{ self.id, self.parent orelse "-", self.label });
        if (self.icon) |i| try w.print("\ticon={s}", .{i});
        if (self.disabled) try w.writeAll("\tdisabled");
    }
};

// ---------------------------------------------------------------------------
// desc-items

/// A `desc-items` line: `label value`. The value is the rest of the line:
/// further tabs in TSV, the remaining words joined by one space otherwise.
pub const DescItem = struct {
    label: []const u8,
    value: []const u8 = "",

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!DescItem {
        if (std.mem.indexOfScalar(u8, line, '\t')) |i| return .{ .label = line[0..i], .value = line[i + 1 ..] };
        const fs = try fields(arena, line, d);
        if (fs.len == 0) return .{ .label = "" };
        return .{ .label = fs[0], .value = try rest(arena, line, fs, 1) };
    }

    pub fn format(self: DescItem, w: *Writer) WErr!void {
        try w.print("{s}\t{s}", .{ self.label, self.value });
    }
};

// ---------------------------------------------------------------------------
// icon-items (new in 0.2)

pub const Point = struct { x: i32, y: i32 };

/// An `icon-items` line: `id label=text icon=name pos=x,y [selected]`.
/// Other `name=value` fields are kept in `extra`; readers ignore them.
pub const IconItem = struct {
    id: []const u8,
    label: []const u8 = "",
    icon: ?[]const u8 = null,
    pos: ?Point = null,
    selected: bool = false,
    extra: []const []const u8 = &.{},

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!IconItem {
        const fs = try fields(arena, line, d);
        var it: IconItem = .{ .id = try needId(arena, if (fs.len > 0) fs[0] else "", "icon item", d) };
        var extra: std.ArrayList([]const u8) = .empty;
        if (fs.len > 1) for (fs[1..]) |x| {
            if (std.mem.startsWith(u8, x, "label=")) {
                it.label = x[6..];
            } else if (std.mem.startsWith(u8, x, "icon=")) {
                it.icon = x[5..];
            } else if (std.mem.startsWith(u8, x, "pos=")) {
                it.pos = parsePoint(x[4..]) orelse return err.fail(d, arena, .bad_value, "{s}", .{x});
            } else if (std.mem.eql(u8, x, "selected")) {
                it.selected = true;
            } else if (x.len > 0) try extra.append(arena, x);
        };
        it.extra = try extra.toOwnedSlice(arena);
        return it;
    }

    pub fn format(self: IconItem, w: *Writer) WErr!void {
        try tokenize.quoteWord(w, self.id);
        try w.writeAll(" label=");
        try tokenize.quoteValue(w, self.label);
        if (self.icon) |i| {
            try w.writeAll(" icon=");
            try tokenize.quoteValue(w, i);
        }
        if (self.pos) |p| try w.print(" pos={d},{d}", .{ p.x, p.y });
        if (self.selected) try w.writeAll(" selected");
        for (self.extra) |x| {
            try w.writeByte(' ');
            try tokenize.quote(w, x);
        }
    }
};

/// `x,y` in whole numbers (core.md § Coordinates).
pub fn parsePoint(s: []const u8) ?Point {
    const i = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    const x = std.fmt.parseInt(i32, s[0..i], 10) catch return null;
    const y = std.fmt.parseInt(i32, s[i + 1 ..], 10) catch return null;
    return .{ .x = x, .y = y };
}

// ---------------------------------------------------------------------------
// menus

pub const MenuKind = enum { item, sep, sub };

/// A menu line (core.md § Keys, actions and menus):
///
/// ```text
/// item new    label=New      key=cmd-n
/// sep
/// sub recent  label='Open Recent'
///   item r1   label=notes.txt
/// item quit   role=quit
/// ```
///
/// A `sub`'s items are the lines after it indented one level deeper (two
/// spaces, or a tab, per level); `parseMenu` checks the nesting. An item
/// id of `-` has no action of its own.
pub const MenuLine = struct {
    depth: usize = 0,
    kind: MenuKind = .item,
    /// The action id (`item`) or submenu name (`sub`); empty for `sep`.
    id: []const u8 = "",
    attrs: []const Attr = &.{},

    pub fn attr(self: MenuLine, k: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.key, k)) return a.value;
        return null;
    }

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!MenuLine {
        var depth: usize = 0;
        var r = line;
        while (true) {
            if (std.mem.startsWith(u8, r, "  ")) {
                r = r[2..];
            } else if (std.mem.startsWith(u8, r, "\t")) {
                r = r[1..];
            } else break;
            depth += 1;
        }
        if (std.mem.startsWith(u8, r, " ")) return err.fail(d, arena, .bad_syntax, "odd indent", .{});
        const ts = try ctl.tokens(arena, r, d);
        const c = (try ctl.build(arena, ts, false, d)).ctl;
        const kind = std.meta.stringToEnum(MenuKind, c.verb) orelse
            return err.fail(d, arena, .unknown_command, "{s}", .{c.verb});
        if (kind == .sep) {
            if (c.words.len > 0 or c.attrs.len > 0) return err.fail(d, arena, .bad_syntax, "sep takes nothing", .{});
            return .{ .depth = depth, .kind = .sep };
        }
        if (c.words.len == 0) return err.fail(d, arena, .bad_syntax, "{s} needs an id", .{c.verb});
        if (c.words.len > 1) return err.fail(d, arena, .bad_syntax, "unexpected {s}", .{c.words[1]});
        return .{ .depth = depth, .kind = kind, .id = c.words[0], .attrs = c.attrs };
    }

    pub fn format(self: MenuLine, w: *Writer) WErr!void {
        for (0..self.depth) |_| try w.writeAll("  ");
        try w.writeAll(@tagName(self.kind));
        if (self.kind == .sep) return;
        try w.writeByte(' ');
        try tokenize.quoteWord(w, self.id);
        for (self.attrs) |a| {
            try w.print(" {s}=", .{a.key});
            try tokenize.quoteValue(w, a.value);
        }
    }
};

/// A whole menu file, with nesting checked: a line is at most one level
/// deeper than the one before, and only a `sub` takes deeper lines.
pub fn parseMenu(arena: Allocator, text: []const u8, d: ?*Diag) Error![]MenuLine {
    const ls = try parseLines(MenuLine, arena, text, d);
    for (ls, 0..) |l, i| {
        const max: usize = if (i == 0) 0 else if (ls[i - 1].kind == .sub) ls[i - 1].depth + 1 else ls[i - 1].depth;
        if (l.depth > max) return err.fail(d, arena, .bad_syntax, "menu line {d}: indented under a non-sub", .{i + 1});
    }
    return ls;
}

// ---------------------------------------------------------------------------
// keys

/// A `keys` line: `keystroke... action [global] [context=name]`. The last
/// positional word is the action, and the words before it are keystrokes
/// (more than one for a sequence, `cmd-k cmd-s`). A trailing `global`
/// after an action, or after the attributes, is the global flag.
pub const KeyBinding = struct {
    keys: []const []const u8,
    action: []const u8,
    global: bool = false,
    attrs: []const Attr = &.{},

    pub fn context(self: KeyBinding) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.key, "context")) return a.value;
        return null;
    }

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!KeyBinding {
        const ts = try ctl.tokens(arena, line, d);
        var pos: std.ArrayList([]const u8) = .empty;
        var attrs: std.ArrayList(Attr) = .empty;
        var global = false;
        for (ts) |tk| {
            if (tk.attr()) |a| {
                try attrs.append(arena, .{ .key = a.key, .value = a.value });
            } else if (attrs.items.len > 0) {
                if (!tk.quoted and std.mem.eql(u8, tk.text, "global")) {
                    global = true;
                } else return err.fail(d, arena, .bad_syntax, "{s} after an attribute", .{tk.text});
            } else try pos.append(arena, tk.text);
        }
        if (!global and pos.items.len >= 3 and std.mem.eql(u8, pos.items[pos.items.len - 1], "global") and !ts[pos.items.len - 1].quoted) {
            global = true;
            _ = pos.pop();
        }
        if (pos.items.len < 2) return err.fail(d, arena, .bad_syntax, "want keystroke and action", .{});
        const action = pos.pop().?;
        return .{ .keys = try pos.toOwnedSlice(arena), .action = action, .global = global, .attrs = try attrs.toOwnedSlice(arena) };
    }

    pub fn format(self: KeyBinding, w: *Writer) WErr!void {
        for (self.keys) |k| {
            try tokenize.quoteWord(w, k);
            try w.writeByte(' ');
        }
        // A quoted action reads back as the action even when it is
        // `global`.
        if (std.mem.eql(u8, self.action, "global")) try tokenize.quoteAlways(w, self.action) else try tokenize.quoteWord(w, self.action);
        if (self.global) try w.writeAll(" global");
        for (self.attrs) |a| {
            try w.print(" {s}=", .{a.key});
            try tokenize.quoteValue(w, a.value);
        }
    }
};

// ---------------------------------------------------------------------------
// canvas ops

pub const OpKind = enum {
    /// `rect id x y w h`
    rect,
    /// `circle id cx cy r`
    circle,
    /// `line id x1 y1 x2 y2`
    line,
    /// `path id M20,200 L60,180 ...`
    path,
    /// `text id x y 'string'`
    text,
    /// `image id x y w h`
    image,

    /// How many numbers the geometry takes (none for `path`).
    pub fn arity(k: OpKind) usize {
        return switch (k) {
            .rect, .line, .image => 4,
            .circle => 3,
            .text => 2,
            .path => 0,
        };
    }
};

/// One SVG-style path segment: `M20,200`, `L60,180`, `C1,2,3,4,5,6`, `Z`.
/// Commands `M L H V C S Q T A Z`, lowercase for relative; several sets of
/// numbers may follow one letter (`L1,2,3,4` is two lines).
pub const PathSeg = struct {
    cmd: u8,
    args: []const f32 = &.{},

    pub fn parse(arena: Allocator, w: []const u8, d: ?*Diag) Error!PathSeg {
        if (w.len == 0) return err.fail(d, arena, .bad_syntax, "empty path segment", .{});
        const n: usize = switch (std.ascii.toUpper(w[0])) {
            'M', 'L', 'T' => 2,
            'H', 'V' => 1,
            'C' => 6,
            'S', 'Q' => 4,
            'A' => 7,
            'Z' => 0,
            else => return err.fail(d, arena, .bad_syntax, "path segment {s}", .{w}),
        };
        var args: std.ArrayList(f32) = .empty;
        if (w.len > 1) {
            var it = std.mem.splitScalar(u8, w[1..], ',');
            while (it.next()) |x| try args.append(arena, try num(arena, x, d));
        }
        const k = args.items.len;
        const ok = if (n == 0) k == 0 else k > 0 and k % n == 0;
        if (!ok) return err.fail(d, arena, .bad_value, "path segment {s}", .{w});
        return .{ .cmd = w[0], .args = try args.toOwnedSlice(arena) };
    }

    pub fn format(self: PathSeg, w: *Writer) WErr!void {
        try w.writeByte(self.cmd);
        for (self.args, 0..) |a, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{d}", .{a});
        }
    }
};

/// A canvas `ops` line: `kind id geometry attrs`.
///
/// ```text
/// rect   card    20 20 160 90  fill=muted radius=8 border=border
/// path   spark   M20,200 L60,180 L100,190  stroke=primary width=2
/// text   lbl     28 44         'Revenue'  size=13 color=muted-foreground
/// ```
///
/// Attributes are kept as written (`fill`, `hover:fill`); the canvas checks
/// their values. Ops are in node space, where decimals are allowed.
pub const CanvasOp = struct {
    kind: OpKind = .rect,
    id: []const u8,
    /// `kind.arity()` numbers; empty for `path`.
    geom: []const f32 = &.{},
    /// A `path`'s segments.
    path: []const PathSeg = &.{},
    /// A `text`'s string.
    text: ?[]const u8 = null,
    attrs: []const Attr = &.{},

    pub fn attr(self: CanvasOp, k: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.key, k)) return a.value;
        return null;
    }

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!CanvasOp {
        const ts = try ctl.tokens(arena, line, d);
        const c = (try ctl.build(arena, ts, false, d)).ctl;
        return fromParts(arena, c.verb, c.words, c.attrs, d);
    }

    /// From an already split line, as for `add KIND ID ...` on a canvas
    /// `ctl` (pass the words after `add`'s kind).
    pub fn fromParts(arena: Allocator, kind_word: []const u8, args: []const []const u8, attrs: []const Attr, d: ?*Diag) Error!CanvasOp {
        const kind = std.meta.stringToEnum(OpKind, kind_word) orelse
            return err.fail(d, arena, .bad_value, "canvas op {s}", .{kind_word});
        if (args.len == 0) return err.fail(d, arena, .bad_syntax, "{s} needs an id", .{@tagName(kind)});
        var op: CanvasOp = .{ .kind = kind, .id = args[0], .attrs = attrs };
        const geo = args[1..];
        if (kind == .path) {
            if (geo.len == 0) return err.fail(d, arena, .bad_syntax, "path needs segments", .{});
            const segs = try arena.alloc(PathSeg, geo.len);
            for (geo, segs) |x, *s| s.* = try PathSeg.parse(arena, x, d);
            op.path = segs;
            return op;
        }
        const want = kind.arity() + @intFromBool(kind == .text);
        if (geo.len != want)
            return err.fail(d, arena, .bad_syntax, "{s} {s} wants {d} values, got {d}", .{ @tagName(kind), op.id, want, geo.len });
        const g = try arena.alloc(f32, kind.arity());
        for (geo[0..kind.arity()], g) |x, *o| o.* = try num(arena, x, d);
        op.geom = g;
        if (kind == .text) op.text = geo[2];
        return op;
    }

    pub fn format(self: CanvasOp, w: *Writer) WErr!void {
        try w.writeAll(@tagName(self.kind));
        try w.writeByte(' ');
        try tokenize.quoteWord(w, self.id);
        for (self.geom) |g| try w.print(" {d}", .{g});
        for (self.path) |p| {
            try w.writeByte(' ');
            try p.format(w);
        }
        if (self.text) |x| {
            try w.writeByte(' ');
            try tokenize.quoteWord(w, x);
        }
        for (self.attrs) |a| {
            try w.print(" {s}=", .{a.key});
            try tokenize.quoteValue(w, a.value);
        }
    }
};

// ---------------------------------------------------------------------------
// editor diagnostics (uitreefs host extra)

pub const Severity = enum { @"error", warning, info, hint };

/// A `diagnostics` line: `line col len severity message`, 1-based; the
/// message is the rest of the line.
pub const Diagnostic = struct {
    line: u32,
    col: u32,
    len: u32,
    severity: Severity = .@"error",
    message: []const u8 = "",

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!Diagnostic {
        const fs = try fields(arena, line, d);
        if (fs.len < 4) return err.fail(d, arena, .bad_syntax, "want line col len severity message", .{});
        var out: Diagnostic = .{ .line = 0, .col = 0, .len = 0 };
        inline for (.{ "line", "col", "len" }, 0..) |f, i| {
            @field(out, f) = std.fmt.parseInt(u32, fs[i], 10) catch
                return err.fail(d, arena, .bad_value, "diagnostic number {s}", .{fs[i]});
        }
        out.severity = std.meta.stringToEnum(Severity, fs[3]) orelse
            return err.fail(d, arena, .bad_value, "severity {s}", .{fs[3]});
        out.message = try rest(arena, line, fs, 4);
        return out;
    }

    pub fn format(self: Diagnostic, w: *Writer) WErr!void {
        try w.print("{d}\t{d}\t{d}\t{s}\t{s}", .{ self.line, self.col, self.len, @tagName(self.severity), self.message });
    }
};

// ---------------------------------------------------------------------------
// completions (uitreefs host extra), and the seq= header of request answers

/// A `completions` line: `text [label] [kind=k] [detail=d]`. `text` is
/// inserted; `label` is what the popup shows when it differs.
pub const Completion = struct {
    text: []const u8,
    label: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    detail: ?[]const u8 = null,

    pub fn parse(arena: Allocator, line: []const u8, d: ?*Diag) Error!Completion {
        const fs = try fields(arena, line, d);
        var c: Completion = .{ .text = try needId(arena, if (fs.len > 0) fs[0] else "", "completion", d) };
        if (fs.len > 1) for (fs[1..], 0..) |x, i| {
            if (std.mem.startsWith(u8, x, "kind=")) {
                c.kind = x[5..];
            } else if (std.mem.startsWith(u8, x, "detail=")) {
                c.detail = x[7..];
            } else if (i == 0) {
                c.label = x;
            } else return err.fail(d, arena, .bad_value, "completion field {s}", .{x});
        };
        return c;
    }

    pub fn format(self: Completion, w: *Writer) WErr!void {
        var kb: [256]u8 = undefined;
        var db: [256]u8 = undefined;
        var buf: [4][]const u8 = undefined;
        var n: usize = 1;
        buf[0] = self.text;
        if (self.label) |l| {
            buf[n] = l;
            n += 1;
        }
        if (self.kind) |k| {
            buf[n] = std.fmt.bufPrint(&kb, "kind={s}", .{k}) catch "kind=";
            n += 1;
        }
        if (self.detail) |x| {
            buf[n] = std.fmt.bufPrint(&db, "detail={s}", .{x}) catch "detail=";
            n += 1;
        }
        try writeFields(w, buf[0..n], false);
    }
};

/// Splits the `seq=N` first line off a request answer (`completions`,
/// `hover`): the seq and the rest of the text.
pub fn splitSeq(arena: Allocator, text: []const u8, d: ?*Diag) Error!struct { seq: u64, rest: []const u8 } {
    const i = std.mem.indexOfScalar(u8, text, '\n');
    const first = std.mem.trim(u8, if (i) |k| text[0..k] else text, " \t\r");
    const r = if (i) |k| text[k + 1 ..] else "";
    if (!std.mem.startsWith(u8, first, "seq=")) return err.fail(d, arena, .bad_syntax, "want seq=N first, got {s}", .{first});
    const seq = std.fmt.parseInt(u64, first[4..], 10) catch return err.fail(d, arena, .bad_value, "{s}", .{first});
    return .{ .seq = seq, .rest = r };
}

/// A whole `completions` write: `seq=N`, then completion lines.
pub fn parseCompletions(arena: Allocator, text: []const u8, d: ?*Diag) Error!struct { seq: u64, items: []Completion } {
    const s = try splitSeq(arena, text, d);
    return .{ .seq = s.seq, .items = try parseLinesAt(Completion, arena, s.rest, 2, d) };
}

// ---------------------------------------------------------------------------
// message-list items (uitreefs host extra)

/// The roles a message header may name.
pub const roles = [_][]const u8{ "user", "assistant", "system", "tool" };

/// One `message-list` item: an `id role [time]` header line, then
/// markdown, ended by a blank line. Markdown has blank lines of its own, so
/// a blank line ends the message only when the next non-blank line is
/// another header (two or three words, the second a role) or the file ends.
pub const Message = struct {
    id: []const u8,
    role: []const u8,
    time: []const u8 = "",
    /// Lines joined by `\n`, with no trailing blank lines.
    body: []const u8 = "",

    /// `id role [time]`, then the body on the following lines. No blank
    /// line after; `printMessages` adds it.
    pub fn format(self: Message, w: *Writer) WErr!void {
        try w.print("{s} {s}", .{ self.id, self.role });
        if (self.time.len > 0) try w.print(" {s}", .{self.time});
        if (self.body.len > 0) try w.print("\n{s}", .{self.body});
    }
};

const Header = struct { id: []const u8, role: []const u8, time: []const u8 };

fn header(line: []const u8) ?Header {
    var ws: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |w| {
        if (n == ws.len) return null;
        ws[n] = w;
        n += 1;
    }
    if (n < 2 or n > 3) return null;
    for (roles) |r| if (std.mem.eql(u8, r, ws[1])) return .{ .id = ws[0], .role = ws[1], .time = if (n == 3) ws[2] else "" };
    return null;
}

fn blankLine(l: []const u8) bool {
    return std.mem.trim(u8, l, " \t\r").len == 0;
}

pub fn parseMessages(arena: Allocator, text: []const u8, d: ?*Diag) Error![]Message {
    var ls: std.ArrayList([]const u8) = .empty;
    var sp = std.mem.splitScalar(u8, text, '\n');
    while (sp.next()) |l| try ls.append(arena, std.mem.trimEnd(u8, l, "\r"));
    const lines = ls.items;
    var out: std.ArrayList(Message) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        if (blankLine(lines[i])) {
            i += 1;
            continue;
        }
        const h = header(lines[i]) orelse
            return err.fail(d, arena, .bad_syntax, "line {d}: want id role time, got {s}", .{ i + 1, lines[i] });
        i += 1;
        const start = i;
        var end = i;
        while (i < lines.len) {
            if (blankLine(lines[i])) {
                var j = i;
                while (j < lines.len and blankLine(lines[j])) j += 1;
                if (j == lines.len) {
                    i = j;
                    break;
                }
                i = j;
                if (header(lines[j]) != null) break;
            } else {
                i += 1;
                end = i;
            }
        }
        try out.append(arena, .{ .id = h.id, .role = h.role, .time = h.time, .body = try std.mem.join(arena, "\n", lines[start..end]) });
    }
    return out.toOwnedSlice(arena);
}

/// Each message, then a blank line.
pub fn printMessages(w: *Writer, msgs: []const Message) WErr!void {
    for (msgs) |m| {
        try m.format(w);
        try w.writeAll("\n\n");
    }
}

// ---------------------------------------------------------------------------
// tests: uitreefs/crates/proto/tests/snippets.rs (canvas_ops, menu_lines,
// keymap_lines, tsv_lines, tabify_lines, messages), renamed to 0.2.

const t = std.testing;

fn str(a: Allocator, x: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try x.format(&aw.writer);
    return aw.written();
}

fn printed(a: Allocator, recs: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try printLines(&aw.writer, recs);
    return aw.written();
}

test "canvas ops" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const ops_text =
        \\rect   bg      0 0 400 300   fill=background
        \\rect   card    20 20 160 90  fill=muted radius=8 border=border
        \\path   spark   M20,200 L60,180 L100,190 L140,150  stroke=primary width=2
        \\circle dot     140 150 4     fill=primary
        \\text   lbl     28 44         'Revenue'  size=13 color=muted-foreground
        \\image  logo    360 12 24 24  src=@logo
        \\
    ;
    const ops = try parseLines(CanvasOp, a, ops_text, null);
    try t.expectEqual(@as(usize, 6), ops.len);
    try t.expectEqualSlices(f32, &.{ 20, 20, 160, 90 }, ops[1].geom);
    try t.expectEqualStrings("8", ops[1].attr("radius").?);
    try t.expectEqual(OpKind.path, ops[2].kind);
    try t.expectEqual(@as(usize, 4), ops[2].path.len);
    try t.expectEqualStrings("M20,200", try str(a, ops[2].path[0]));
    try t.expectEqualSlices(f32, &.{ 140, 150, 4 }, ops[3].geom);
    try t.expectEqualStrings("Revenue", ops[4].text.?);
    try t.expectEqualStrings("@logo", ops[5].attr("src").?);
    try t.expectEqualStrings("text lbl 28 44 Revenue size=13 color=muted-foreground", try str(a, ops[4]));
    try t.expectEqualDeep(ops, try parseLines(CanvasOp, a, try printed(a, ops), null));

    var op = try CanvasOp.parse(a, "path tick3 M120.5,10.0 L120.5,22.0 stroke=muted-foreground width=2 cap=round", null);
    try t.expectEqualSlices(f32, &.{ 120.5, 22 }, op.path[1].args);
    op = try CanvasOp.parse(a, "rect c1_2 12 24 11 11 fill=primary radius=2 hover:fill=accent", null);
    try t.expectEqualStrings("accent", op.attr("hover:fill").?);

    try t.expectError(error.BadValue, CanvasOp.parse(a, "blob x 1 2", null));
    try t.expectError(error.BadSyntax, CanvasOp.parse(a, "rect x 1 2 3", null));
    try t.expectError(error.BadValue, CanvasOp.parse(a, "rect x 1 2 3 wide", null));
    try t.expectError(error.BadValue, CanvasOp.parse(a, "path p M1", null));
    try t.expectError(error.BadSyntax, CanvasOp.parse(a, "path p", null));
    try t.expectError(error.BadSyntax, CanvasOp.parse(a, "path p X1", null));
}

test "menu lines" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const menu =
        \\item new    label=New      key=cmd-n
        \\item open   label=Open…    key=cmd-o
        \\sep
        \\sub recent  label='Open Recent'
        \\item quit   role=quit
        \\
    ;
    var m = try parseMenu(a, menu, null);
    try t.expectEqual(@as(usize, 5), m.len);
    try t.expectEqual(MenuKind.item, m[0].kind);
    try t.expectEqualStrings("new", m[0].id);
    try t.expectEqualStrings("cmd-n", m[0].attr("key").?);
    try t.expectEqualStrings("Open…", m[1].attr("label").?);
    try t.expectEqual(MenuKind.sep, m[2].kind);
    try t.expectEqual(MenuKind.sub, m[3].kind);
    try t.expectEqualStrings("Open Recent", m[3].attr("label").?);
    try t.expectEqualStrings("sub recent label='Open Recent'", try str(a, m[3]));
    try t.expectEqualStrings("quit", m[4].attr("role").?);

    const nested = "sub recent label='Open Recent'\n  item r1 label=a.txt\n  sep\nitem quit label=Quit\n";
    m = try parseMenu(a, nested, null);
    try t.expectEqual(@as(usize, 1), m[1].depth);
    try t.expectEqualStrings(nested, try printed(a, m));
    try t.expectError(error.BadSyntax, parseMenu(a, "item a\n  item b\n", null));
    try t.expectError(error.UnknownCommand, parseMenu(a, "itme a\n", null));
    try t.expectError(error.BadSyntax, parseMenu(a, "sep x\n", null));
    try t.expectError(error.BadSyntax, parseMenu(a, "item\n", null));
    try t.expectError(error.BadSyntax, parseMenu(a, " item a\n", null));

    // key== binds the = key; an item id of - has no action (the default
    // menus).
    m = try parseMenu(a, "item inc    label=Increment  key==\nitem - role=about\n", null);
    try t.expectEqualStrings("=", m[0].attr("key").?);
    try t.expectEqualStrings("-", m[1].id);
}

test "keys" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // core.md § Keys, actions and menus.
    const keys =
        \\cmd-s            save
        \\cmd-shift-p      palette
        \\escape           dismiss   context=editor
        \\cmd-shift-space  summon    global
        \\ctrl-tab         next-tab  context=workspace
        \\
    ;
    const k = try parseLines(KeyBinding, a, keys, null);
    try t.expectEqualStrings("cmd-s", k[0].keys[0]);
    try t.expectEqualStrings("save", k[0].action);
    try t.expectEqualStrings("editor", k[2].context().?);
    try t.expect(k[3].global);
    try t.expectEqualStrings("summon", k[3].action);
    try t.expectEqual(@as(usize, 1), k[3].keys.len);
    try t.expectEqualStrings("ctrl-tab next-tab context=workspace", try str(a, k[4]));
    try t.expectEqualStrings("cmd-shift-space summon global", try str(a, k[3]));

    var b = try KeyBinding.parse(a, "cmd-k cmd-s save-all", null);
    try t.expectEqual(@as(usize, 2), b.keys.len);
    b = try KeyBinding.parse(a, "=          k:eq", null);
    try t.expectEqualStrings("=", b.keys[0]);
    b = try KeyBinding.parse(a, "cmd-= zoom-in", null);
    try t.expectEqualStrings("cmd-=", b.keys[0]);
    b = try KeyBinding.parse(a, "escape dismiss context=editor global", null);
    try t.expect(b.global);
    // An action named global needs no flag when there's one keystroke.
    b = try KeyBinding.parse(a, "cmd-g global", null);
    try t.expectEqualStrings("global", b.action);
    try t.expect(!b.global);
    try t.expectError(error.BadSyntax, KeyBinding.parse(a, "save", null));
    try t.expectError(error.BadSyntax, KeyBinding.parse(a, "a b x=1 c", null));
}

test "field lines" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const items_text = "rs\tRust\ngo\tGo\n# Systems\nc\tC\ticon=cpu\tdisabled\n-\n";
    const items = try parseLines(Item, a, items_text, null);
    try t.expectEqual(@as(usize, 5), items.len);
    try t.expectEqualStrings("Rust", items[0].entry.label);
    try t.expectEqualStrings("Systems", items[2].group);
    try t.expectEqualStrings("cpu", items[3].entry.icon.?);
    try t.expect(items[3].entry.disabled);
    try t.expect(items[4] == .separator);
    try t.expectEqualStrings(items_text, try printed(a, items));
    // Extra fields for a row template.
    const it = try Item.parse(a, "4211\tShow HN: x\t120\tpg\t33\texample.com", null);
    try t.expectEqual(@as(usize, 4), it.entry.extra.len);

    // 0.2: a line with no tab is words (components.md § Data file formats).
    const words = try parseLines(Item, a, "inbox Inbox\ncob 'GnuCOBOL 3.2' icon=cpu disabled\nsolo\n", null);
    try t.expectEqualStrings("Inbox", words[0].entry.label);
    try t.expectEqualStrings("GnuCOBOL 3.2", words[1].entry.label);
    try t.expectEqualStrings("cpu", words[1].entry.icon.?);
    try t.expect(words[1].entry.disabled);
    try t.expectEqualStrings("solo", words[2].entry.id);
    try t.expectEqualStrings("", words[2].entry.label);
    try t.expectEqualStrings("inbox\tInbox\ncob\tGnuCOBOL 3.2\ticon=cpu\tdisabled\nsolo\n", try printed(a, words));
    // A one-field line that would read as a separator, or one with a
    // blank, is written as a quoted word.
    try t.expectEqualStrings("'-'", try str(a, Item{ .entry = .{ .id = "-" } }));
    try t.expectEqualStrings("'a b'", try str(a, Item{ .entry = .{ .id = "a b" } }));
    try t.expectEqualStrings("'# x' y", try str(a, Item{ .entry = .{ .id = "# x", .label = "y" } }));
    try t.expectError(error.BadSyntax, Item.parse(a, "\tlabel", null));

    const cols = try parseLines(Column, a, "name\tName\t280\tsort\nsize\tSize\t90\tsort\talign=right\nmod Modified 160 sort\n", null);
    try t.expectEqual(@as(f32, 90), cols[1].width.?);
    try t.expectEqual(Align.right, cols[1].@"align".?);
    try t.expectEqualStrings("size\tSize\t90\tsort\talign=right", try str(a, cols[1]));
    try t.expectEqual(@as(f32, 160), cols[2].width.?);
    const c = try Column.parse(a, "sym\tSymbol\t90\tsort\tfixed", null);
    try t.expect(c.fixed and c.sort);
    try t.expectError(error.BadValue, Column.parse(a, "a\tA\twide", null));
    try t.expectError(error.BadValue, Column.parse(a, "a\tA\talign=up", null));

    const row = try Row.parse(a, "r1 Ada 38 'London, UK'", null);
    try t.expectEqualStrings("London, UK", row.cells[2]);

    var ti = try TreeItem.parse(a, "src/main\tsrc\tmain.rs\ticon=file", null);
    try t.expectEqualStrings("src", ti.parent.?);
    try t.expectEqualStrings("file", ti.icon.?);
    ti = try TreeItem.parse(a, "src - src icon=folder", null);
    try t.expect(ti.parent == null);
    try t.expectError(error.BadSyntax, TreeItem.parse(a, "orphan", null));

    var di = try DescItem.parse(a, "Name\tAda\tLovelace", null);
    try t.expectEqualStrings("Ada\tLovelace", di.value);
    di = try DescItem.parse(a, "Born 1815 London", null);
    try t.expectEqualStrings("1815 London", di.value);

    const dg = try Diagnostic.parse(a, "12\t5\t3\terror\tmismatched types", null);
    try t.expectEqual(@as(u32, 12), dg.line);
    try t.expectEqualStrings("mismatched types", dg.message);
    try t.expectEqualStrings("12\t5\t3\terror\tmismatched types", try str(a, dg));
    try t.expectError(error.BadValue, Diagnostic.parse(a, "x\t5\t3\terror\tm", null));
    try t.expectError(error.BadValue, Diagnostic.parse(a, "1\t5\t3\tfatal\tm", null));

    const cs = try parseCompletions(a, "seq=301\nprintln!\tprintln!(…)\tkind=macro\nprint\n", null);
    try t.expectEqual(@as(u64, 301), cs.seq);
    try t.expectEqualStrings("macro", cs.items[0].kind.?);
    try t.expect(cs.items[1].label == null);
    try t.expectError(error.BadSyntax, parseCompletions(a, "println\n", null));
}

test "icon items" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\readme label='Read Me' icon=doc pos=40,12 selected
        \\trash label=Trash icon=trash pos=-8,300 x.finder.tint=red
        \\
    ;
    const its = try parseLines(IconItem, a, text, null);
    try t.expectEqualStrings("Read Me", its[0].label);
    try t.expectEqual(Point{ .x = 40, .y = 12 }, its[0].pos.?);
    try t.expect(its[0].selected);
    try t.expectEqual(@as(i32, -8), its[1].pos.?.x);
    try t.expectEqualStrings("x.finder.tint=red", its[1].extra[0]);
    try t.expectEqualStrings(text, try printed(a, its));
    // Whole numbers only (core.md § Coordinates).
    try t.expectError(error.BadValue, IconItem.parse(a, "a pos=1.5,2", null));
    try t.expectError(error.BadValue, IconItem.parse(a, "a pos=1", null));
}

test "tabify" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("rs\tRust\ngo\tGo\ncob\tGnuCOBOL 3.2\n", try tabify(a, "rs Rust\ngo Go\ncob 'GnuCOBOL 3.2'\n", null));
    try t.expectEqualStrings("a\tb c\n# Group\n-\none\n", try tabify(a, "a\tb c\n# Group\n-\none\n", null));
    var d: Diag = .{};
    try t.expectError(error.BadSyntax, tabify(a, "ok fine\nbad 'quote\n", &d));
    try t.expectEqualStrings("line 2: unterminated quote", d.detail);
}

test "line numbers in errors" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d: Diag = .{};
    try t.expectError(error.BadValue, parseLines(Column, a, "a\tA\n\nb\tB\twide\n", &d));
    try t.expectEqualStrings("line 3: wide", d.detail);
}

test "messages" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const log = "m1 assistant 10:01\nHello, I'm **Eliza**.\n\nm2 user 10:02\ntell me about rc\n\nm3 assistant 10:02\nAh, a person of taste:\n\n```rc\necho hi\n```\n\n";
    const m = try parseMessages(a, log, null);
    try t.expectEqual(@as(usize, 3), m.len);
    try t.expectEqualStrings("Hello, I'm **Eliza**.", m[0].body);
    try t.expectEqualStrings("m2", m[1].id);
    try t.expectEqualStrings("user", m[1].role);
    try t.expectEqualStrings("10:02", m[1].time);
    try t.expectEqualStrings("Ah, a person of taste:\n\n```rc\necho hi\n```", m[2].body);
    var aw: std.Io.Writer.Allocating = .init(a);
    try printMessages(&aw.writer, m);
    try t.expectEqualStrings(log, aw.written());
    try t.expectError(error.BadSyntax, parseMessages(a, "not a header at all here\n", null));
}
