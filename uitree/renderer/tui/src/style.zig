//! Style words to Yoga properties and terminal looks.
//!
//! The core hands every node's style already parsed and validated
//! (uit_style): dashed names, a state, and typed arguments with theme
//! tokens resolved to RGBA. This file only interprets them for a grid of
//! cells. Words that mean nothing in a terminal (shadows, cursors, font
//! families, text sizes) are accepted by the core and ignored here.
//!
//! **Units.** Styles are written in GPUI points. A terminal cell is taken
//! as 8 points wide and 16 tall, so `p=16` is two columns of padding on
//! the sides and one row on top and bottom. Tailwind scale words
//! (`p-4`, `gap-2`) are 4 points a step, as in GPUI. Yoga lays out in
//! cells, so every length is converted on the axis it applies to.

const std = @import("std");
const c = @import("c");
const core = @import("core.zig");

pub const cell_w: f32 = 8;
pub const cell_h: f32 = 16;

pub const Axis = enum { x, y };

/// Points to cells on one axis. Columns round to nearest; rows round
/// down unless at least three quarters of a row, so small vertical gaps
/// (8 points) collapse instead of doubling a form's height.
pub fn cells(pt: f32, axis: Axis) f32 {
    const neg = pt < 0;
    const a = @abs(pt);
    const v = switch (axis) {
        .x => @floor(a / cell_w + 0.5),
        .y => @floor(a / cell_h + 0.25),
    };
    return if (neg) -v else v;
}

pub const Len = union(enum) {
    auto,
    pt: f32,
    pct: f32,

    fn cellsOn(l: Len, axis: Axis) Len {
        return switch (l) {
            .pt => |p| .{ .pt = cells(p, axis) },
            else => l,
        };
    }
};

pub const Align = enum { start, center, end, stretch, baseline, between, around, evenly };

/// Everything a node's style says about its box, in cells.
pub const Layout = struct {
    display_none: bool = false,
    /// null: not set (a block: children stack vertically).
    dir: ?enum { row, col, row_rev, col_rev } = null,
    wrap: bool = false,
    items: ?Align = null,
    justify: ?Align = null,
    self: ?Align = null,
    content: ?Align = null,
    grow: ?f32 = null,
    shrink: ?f32 = null,
    basis: ?Len = null,
    w: ?Len = null,
    h: ?Len = null,
    min_w: ?Len = null,
    min_h: ?Len = null,
    max_w: ?Len = null,
    max_h: ?Len = null,
    /// top right bottom left
    pad: [4]?Len = .{ null, null, null, null },
    margin: [4]?Len = .{ null, null, null, null },
    pos: [4]?Len = .{ null, null, null, null },
    border: [4]bool = .{ false, false, false, false },
    gap_x: ?f32 = null,
    gap_y: ?f32 = null,
    absolute: bool = false,
    overflow: enum { visible, hidden, scroll } = .visible,
    aspect: ?f32 = null,
};

pub const TextAlign = enum { left, center, right };

/// What a node looks like, beyond its box.
pub const Look = struct {
    bg: ?u32 = null,
    fg: ?u32 = null,
    border_color: ?u32 = null,
    rounded: bool = false,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    strike: ?bool = null,
    dim: ?bool = null,
    text_align: ?TextAlign = null,
    invisible: ?bool = null,
    truncate: ?bool = null,
    nowrap: ?bool = null,
    opacity: ?f32 = null,
    /// A variant word (`primary`, `ghost`) for components that take one.
    variant: ?[]const u8 = null,
};

/// Which state prefixes apply to the node now.
pub const States = packed struct {
    hover: bool = false,
    active: bool = false,
    focus: bool = false,
    disabled: bool = false,
    drop_over: bool = false,
    /// The node's enclosing group is hovered (`group-hover(NAME):`).
    group_hover: bool = false,
};

fn stateOn(s: States, st: u32) bool {
    return switch (st) {
        c.UIT_STATE_BASE => true,
        c.UIT_STATE_HOVER => s.hover,
        c.UIT_STATE_ACTIVE => s.active,
        c.UIT_STATE_FOCUS => s.focus,
        c.UIT_STATE_DISABLED => s.disabled,
        c.UIT_STATE_DROP_OVER => s.drop_over,
        c.UIT_STATE_GROUP_HOVER => s.group_hover,
        else => false,
    };
}

/// Does the style have words for this state? (A node with `hover:` words
/// is redrawn when the pointer enters it.)
pub fn hasState(words: []const core.StyleWord, st: u32) bool {
    for (words) |w| if (w.state == st) return true;
    return false;
}

pub const Style = struct {
    layout: Layout = .{},
    look: Look = .{},
};

/// Applies every word whose state is on, in order: later words win, and
/// state words come after base words in the file, as GPUI refines them.
pub fn resolve(words: []const core.StyleWord, states: States) Style {
    var s: Style = .{};
    // Base first, then each state in a fixed order, so `hover:bg` beats
    // `bg` wherever it is written.
    const order = [_]u32{ c.UIT_STATE_BASE, c.UIT_STATE_GROUP_HOVER, c.UIT_STATE_HOVER, c.UIT_STATE_FOCUS, c.UIT_STATE_ACTIVE, c.UIT_STATE_DROP_OVER, c.UIT_STATE_DISABLED };
    for (order) |st| {
        if (!stateOn(states, st)) continue;
        for (words) |w| if (w.state == st) apply(&s, w);
    }
    return s;
}

fn args(w: core.StyleWord) []const core.StyleArg {
    if (w.n_args == 0 or w.args == null) return &.{};
    return w.args[0..w.n_args];
}

fn argLen(a: core.StyleArg) ?Len {
    return switch (a.kind) {
        c.UIT_ARG_PX, c.UIT_ARG_NUMBER => .{ .pt = a.a },
        c.UIT_ARG_PERCENT => .{ .pct = a.a },
        c.UIT_ARG_REM => .{ .pt = a.a * step * 4 },
        c.UIT_ARG_TEXT => blk: {
            const t = core.slice(a.text);
            if (std.mem.eql(u8, t, "auto")) break :blk .auto;
            if (std.mem.eql(u8, t, "full")) break :blk .{ .pct = 100 };
            break :blk null;
        },
        else => null,
    };
}

fn argColor(a: core.StyleArg) ?u32 {
    return if (a.kind == c.UIT_ARG_RGBA) a.rgba else null;
}

/// Points per step of the Tailwind scale: the `spacing` look token, which
/// the Ui sets before each frame. A rem is four steps.
pub var step: f32 = 4;

/// A Tailwind scale suffix: `4` (4 steps, 16 points by default), `0p5`,
/// `px`, `full`, `1-2` (50%), `auto`, `neg-4`.
pub fn scale(suffix: []const u8) ?Len {
    var s = suffix;
    var sign: f32 = 1;
    if (std.mem.startsWith(u8, s, "neg-")) {
        sign = -1;
        s = s[4..];
    }
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "full")) return .{ .pct = 100 * sign };
    if (std.mem.eql(u8, s, "px")) return .{ .pt = sign };
    if (std.mem.indexOfScalar(u8, s, '-')) |d| {
        const n = std.fmt.parseFloat(f32, s[0..d]) catch return null;
        const m = std.fmt.parseFloat(f32, s[d + 1 ..]) catch return null;
        if (m == 0) return null;
        return .{ .pct = sign * 100 * n / m };
    }
    var buf: [16]u8 = undefined;
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    if (std.mem.indexOf(u8, s, "p5")) |i| {
        buf[i] = '.';
        buf[i + 1] = '5';
    }
    const n = std.fmt.parseFloat(f32, buf[0..s.len]) catch return null;
    return .{ .pt = sign * n * step };
}

const Side = enum(u2) { t = 0, r = 1, b = 2, l = 3 };

fn setSides(arr: *[4]?Len, which: []const u8, v: Len) void {
    // which: "" all, "x", "y", "t", "r", "b", "l"
    const all = [_]Side{ .t, .r, .b, .l };
    const sides: []const Side = if (which.len == 0) &all else switch (which[0]) {
        'x' => &.{ .r, .l },
        'y' => &.{ .t, .b },
        't' => &.{.t},
        'r' => &.{.r},
        'b' => &.{.b},
        'l' => &.{.l},
        else => &.{},
    };
    for (sides) |sd| {
        const axis: Axis = if (sd == .t or sd == .b) .y else .x;
        arr[@intFromEnum(sd)] = v.cellsOn(axis);
    }
}

fn borderSides(l: *Layout, which: []const u8, on: bool) void {
    const all = [_]Side{ .t, .r, .b, .l };
    const sides: []const Side = if (which.len == 0) &all else switch (which[0]) {
        'x' => &.{ .r, .l },
        'y' => &.{ .t, .b },
        't' => &.{.t},
        'r' => &.{.r},
        'b' => &.{.b},
        'l' => &.{.l},
        else => &.{},
    };
    for (sides) |sd| l.border[@intFromEnum(sd)] = on;
}

const box_prefixes = [_][]const u8{ "p", "px", "py", "pt", "pr", "pb", "pl", "m", "mx", "my", "mt", "mr", "mb", "ml" };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// One word with its arguments, or a scale word (`p-4`) with none.
fn apply(s: *Style, w: core.StyleWord) void {
    const name = core.slice(w.name);
    const as = args(w);
    const L = &s.layout;
    const K = &s.look;

    // name=arg forms first.
    if (as.len > 0) {
        const a = as[0];
        if (eql(name, "bg")) {
            K.bg = argColor(a);
        } else if (eql(name, "text-color")) {
            K.fg = argColor(a);
        } else if (eql(name, "border-color")) {
            K.border_color = argColor(a);
        } else if (eql(name, "opacity")) {
            K.opacity = a.a;
        } else if (eql(name, "flex-grow")) {
            L.grow = a.a;
        } else if (eql(name, "flex-shrink")) {
            L.shrink = a.a;
        } else if (eql(name, "aspect-ratio")) {
            L.aspect = a.a;
        } else if (argLen(a)) |v| {
            lenWord(s, name, v, as);
        }
        return;
    }

    // Bare words.
    const flags = std.StaticStringMap(*const fn (*Style) void).initComptime(.{
        .{ "flex", struct {
            fn f(x: *Style) void {
                x.layout.dir = .row;
            }
        }.f },
        .{ "flex-row", struct {
            fn f(x: *Style) void {
                x.layout.dir = .row;
            }
        }.f },
        .{ "flex-col", struct {
            fn f(x: *Style) void {
                x.layout.dir = .col;
            }
        }.f },
        .{ "flex-row-reverse", struct {
            fn f(x: *Style) void {
                x.layout.dir = .row_rev;
            }
        }.f },
        .{ "flex-col-reverse", struct {
            fn f(x: *Style) void {
                x.layout.dir = .col_rev;
            }
        }.f },
        .{ "h-flex", struct {
            fn f(x: *Style) void {
                x.layout.dir = .row;
                x.layout.items = .center;
            }
        }.f },
        .{ "v-flex", struct {
            fn f(x: *Style) void {
                x.layout.dir = .col;
            }
        }.f },
        .{ "flex-wrap", struct {
            fn f(x: *Style) void {
                x.layout.wrap = true;
            }
        }.f },
        .{ "flex-nowrap", struct {
            fn f(x: *Style) void {
                x.layout.wrap = false;
            }
        }.f },
        .{ "flex-1", struct {
            fn f(x: *Style) void {
                x.layout.grow = 1;
                x.layout.shrink = 1;
                x.layout.basis = .{ .pct = 0 };
            }
        }.f },
        .{ "flex-auto", struct {
            fn f(x: *Style) void {
                x.layout.grow = 1;
                x.layout.shrink = 1;
                x.layout.basis = .auto;
            }
        }.f },
        .{ "flex-initial", struct {
            fn f(x: *Style) void {
                x.layout.grow = 0;
                x.layout.shrink = 1;
                x.layout.basis = .auto;
            }
        }.f },
        .{ "flex-none", struct {
            fn f(x: *Style) void {
                x.layout.grow = 0;
                x.layout.shrink = 0;
            }
        }.f },
        .{ "flex-grow", struct {
            fn f(x: *Style) void {
                x.layout.grow = 1;
            }
        }.f },
        .{ "flex-shrink", struct {
            fn f(x: *Style) void {
                x.layout.shrink = 1;
            }
        }.f },
        .{ "flex-shrink-0", struct {
            fn f(x: *Style) void {
                x.layout.shrink = 0;
            }
        }.f },
        .{ "flex-grow-0", struct {
            fn f(x: *Style) void {
                x.layout.grow = 0;
            }
        }.f },
        .{ "size-full", struct {
            fn f(x: *Style) void {
                x.layout.w = .{ .pct = 100 };
                x.layout.h = .{ .pct = 100 };
            }
        }.f },
        .{ "hidden", struct {
            fn f(x: *Style) void {
                x.layout.display_none = true;
            }
        }.f },
        .{ "block", struct {
            fn f(x: *Style) void {
                x.layout.display_none = false;
            }
        }.f },
        .{ "absolute", struct {
            fn f(x: *Style) void {
                x.layout.absolute = true;
            }
        }.f },
        .{ "relative", struct {
            fn f(x: *Style) void {
                x.layout.absolute = false;
            }
        }.f },
        .{ "overflow-hidden", struct {
            fn f(x: *Style) void {
                x.layout.overflow = .hidden;
            }
        }.f },
        .{ "overflow-x-hidden", struct {
            fn f(x: *Style) void {
                x.layout.overflow = .hidden;
            }
        }.f },
        .{ "overflow-y-hidden", struct {
            fn f(x: *Style) void {
                x.layout.overflow = .hidden;
            }
        }.f },
        .{ "overflow-scroll", struct {
            fn f(x: *Style) void {
                x.layout.overflow = .scroll;
            }
        }.f },
        .{ "overflow-y-scroll", struct {
            fn f(x: *Style) void {
                x.layout.overflow = .scroll;
            }
        }.f },
        .{ "overflow-x-scroll", struct {
            fn f(x: *Style) void {
                x.layout.overflow = .scroll;
            }
        }.f },
        .{ "font-semibold", struct {
            fn f(x: *Style) void {
                x.look.bold = true;
            }
        }.f },
        .{ "font-bold", struct {
            fn f(x: *Style) void {
                x.look.bold = true;
            }
        }.f },
        .{ "font-extrabold", struct {
            fn f(x: *Style) void {
                x.look.bold = true;
            }
        }.f },
        .{ "font-black", struct {
            fn f(x: *Style) void {
                x.look.bold = true;
            }
        }.f },
        .{ "font-normal", struct {
            fn f(x: *Style) void {
                x.look.bold = false;
                x.look.dim = false;
            }
        }.f },
        .{ "font-medium", struct {
            fn f(x: *Style) void {
                x.look.bold = false;
                x.look.dim = false;
            }
        }.f },
        .{ "font-light", struct {
            fn f(x: *Style) void {
                x.look.dim = true;
            }
        }.f },
        .{ "font-thin", struct {
            fn f(x: *Style) void {
                x.look.dim = true;
            }
        }.f },
        .{ "font-extralight", struct {
            fn f(x: *Style) void {
                x.look.dim = true;
            }
        }.f },
        .{ "italic", struct {
            fn f(x: *Style) void {
                x.look.italic = true;
            }
        }.f },
        .{ "not-italic", struct {
            fn f(x: *Style) void {
                x.look.italic = false;
            }
        }.f },
        .{ "underline", struct {
            fn f(x: *Style) void {
                x.look.underline = true;
            }
        }.f },
        .{ "line-through", struct {
            fn f(x: *Style) void {
                x.look.strike = true;
            }
        }.f },
        .{ "text-left", struct {
            fn f(x: *Style) void {
                x.look.text_align = .left;
            }
        }.f },
        .{ "text-center", struct {
            fn f(x: *Style) void {
                x.look.text_align = .center;
            }
        }.f },
        .{ "text-right", struct {
            fn f(x: *Style) void {
                x.look.text_align = .right;
            }
        }.f },
        .{ "truncate", struct {
            fn f(x: *Style) void {
                x.look.truncate = true;
                x.look.nowrap = true;
            }
        }.f },
        .{ "text-ellipsis", struct {
            fn f(x: *Style) void {
                x.look.truncate = true;
            }
        }.f },
        .{ "whitespace-nowrap", struct {
            fn f(x: *Style) void {
                x.look.nowrap = true;
            }
        }.f },
        .{ "whitespace-normal", struct {
            fn f(x: *Style) void {
                x.look.nowrap = false;
            }
        }.f },
        .{ "invisible", struct {
            fn f(x: *Style) void {
                x.look.invisible = true;
            }
        }.f },
        .{ "visible", struct {
            fn f(x: *Style) void {
                x.look.invisible = false;
            }
        }.f },
        .{ "rounded", struct {
            fn f(x: *Style) void {
                x.look.rounded = true;
            }
        }.f },
    });
    if (flags.get(name)) |f| return f(s);

    // items-*, justify-*, self-*, content-*
    inline for (.{ .{ "items-", "items" }, .{ "justify-", "justify" }, .{ "self-", "self" }, .{ "content-", "content" } }) |p| {
        if (std.mem.startsWith(u8, name, p[0])) {
            if (alignOf(name[p[0].len..])) |al| @field(L, p[1]) = al;
            return;
        }
    }

    // border, border-2, border-t, border-t-0
    if (std.mem.startsWith(u8, name, "border") and !std.mem.startsWith(u8, name, "border-color") and !eql(name, "border-dashed")) {
        var rest = name["border".len..];
        var which: []const u8 = "";
        if (rest.len > 0 and rest[0] == '-') rest = rest[1..];
        if (rest.len > 0 and std.mem.indexOfScalar(u8, "xytrbl", rest[0]) != null and (rest.len == 1 or rest[1] == '-')) {
            which = rest[0..1];
            rest = if (rest.len > 1) rest[2..] else "";
        }
        const on = !(rest.len > 0 and eql(rest, "0"));
        borderSides(L, which, on);
        return;
    }

    if (std.mem.startsWith(u8, name, "rounded")) {
        K.rounded = !std.mem.endsWith(u8, name, "-none") and !std.mem.endsWith(u8, name, "-0");
        return;
    }

    // Scale words: PREFIX-SUFFIX for every length word.
    if (std.mem.lastIndexOfScalar(u8, name, '-')) |_| {
        var i: usize = 0;
        // Try each '-' as the split, longest prefix first is wrong for
        // `neg-`, so scan from the left: the prefix is a known length word.
        while (std.mem.indexOfScalarPos(u8, name, i, '-')) |d| : (i = d + 1) {
            const pre = name[0..d];
            if (!isLenWord(pre)) continue;
            if (scale(name[d + 1 ..])) |v| {
                lenWord(s, pre, v, &.{});
                return;
            }
        }
    }

    // Variants and sizes are for components (button `: primary`).
    const variants = [_][]const u8{ "primary", "secondary", "danger", "destructive", "info", "success", "warning", "ghost", "link", "outline", "text", "muted", "error" };
    for (variants) |v| if (eql(name, v)) {
        K.variant = v;
        return;
    };
}

fn isLenWord(p: []const u8) bool {
    const words = [_][]const u8{
        "w",   "h",    "size",  "min-w",  "min-h", "max-w",      "max-h", "min-size", "max-size", "gap", "gap-x", "gap-y",
        "top", "left", "right", "bottom", "inset", "flex-basis",
    };
    for (words) |w| if (eql(w, p)) return true;
    for (box_prefixes) |w| if (eql(w, p)) return true;
    return false;
}

fn alignOf(s: []const u8) ?Align {
    const m = std.StaticStringMap(Align).initComptime(.{
        .{ "start", .start },   .{ "flex-start", .start }, .{ "end", .end },           .{ "flex-end", .end },
        .{ "center", .center }, .{ "stretch", .stretch },  .{ "baseline", .baseline }, .{ "between", .between },
        .{ "around", .around }, .{ "evenly", .evenly },    .{ "normal", .start },
    });
    return m.get(s);
}

fn lenWord(s: *Style, name: []const u8, v: Len, as: []const core.StyleArg) void {
    const L = &s.layout;
    if (eql(name, "w")) {
        L.w = v.cellsOn(.x);
    } else if (eql(name, "h")) {
        L.h = v.cellsOn(.y);
    } else if (eql(name, "size")) {
        L.w = v.cellsOn(.x);
        L.h = (if (as.len > 1) argLen(as[1]) orelse v else v).cellsOn(.y);
    } else if (eql(name, "min-w")) {
        L.min_w = v.cellsOn(.x);
    } else if (eql(name, "min-h")) {
        L.min_h = v.cellsOn(.y);
    } else if (eql(name, "max-w")) {
        L.max_w = v.cellsOn(.x);
    } else if (eql(name, "max-h")) {
        L.max_h = v.cellsOn(.y);
    } else if (eql(name, "min-size")) {
        L.min_w = v.cellsOn(.x);
        L.min_h = v.cellsOn(.y);
    } else if (eql(name, "max-size")) {
        L.max_w = v.cellsOn(.x);
        L.max_h = v.cellsOn(.y);
    } else if (eql(name, "flex-basis")) {
        L.basis = v;
    } else if (eql(name, "gap")) {
        if (v == .pt) {
            L.gap_x = cells(v.pt, .x);
            L.gap_y = cells(v.pt, .y);
        }
    } else if (eql(name, "gap-x")) {
        if (v == .pt) L.gap_x = cells(v.pt, .x);
    } else if (eql(name, "gap-y")) {
        if (v == .pt) L.gap_y = cells(v.pt, .y);
    } else if (eql(name, "inset")) {
        setSides(&L.pos, "", v);
    } else if (eql(name, "top")) {
        setSides(&L.pos, "t", v);
    } else if (eql(name, "right")) {
        setSides(&L.pos, "r", v);
    } else if (eql(name, "bottom")) {
        setSides(&L.pos, "b", v);
    } else if (eql(name, "left")) {
        setSides(&L.pos, "l", v);
    } else if (eql(name, "border") or (name.len == 8 and std.mem.startsWith(u8, name, "border-"))) {
        const on = switch (v) {
            .pt => |p| p > 0,
            else => true,
        };
        borderSides(L, if (name.len > 6) name[7..] else "", on);
    } else if (eql(name, "rounded") or std.mem.startsWith(u8, name, "rounded-")) {
        s.look.rounded = switch (v) {
            .pt => |p| p > 0,
            else => true,
        };
    } else if (name.len >= 1 and (name[0] == 'p' or name[0] == 'm') and name.len <= 2) {
        const arr = if (name[0] == 'p') &L.pad else &L.margin;
        setSides(arr, name[1..], v);
    }
}

// ---------------------------------------------------------------------
// Yoga

fn ygLen(set: anytype, set_pct: anytype, set_auto: anytype, n: c.YGNodeRef, v: Len) void {
    switch (v) {
        .pt => |p| set(n, p),
        .pct => |p| set_pct(n, p),
        .auto => if (@TypeOf(set_auto) != @TypeOf(null)) set_auto(n),
    }
}

fn ygAlign(a: Align) c.YGAlign {
    return switch (a) {
        .start => c.YGAlignFlexStart,
        .center => c.YGAlignCenter,
        .end => c.YGAlignFlexEnd,
        .stretch => c.YGAlignStretch,
        .baseline => c.YGAlignBaseline,
        .between => c.YGAlignSpaceBetween,
        .around => c.YGAlignSpaceAround,
        .evenly => c.YGAlignSpaceEvenly,
    };
}

fn ygJustify(a: Align) c.YGJustify {
    return switch (a) {
        .start, .stretch, .baseline => c.YGJustifyFlexStart,
        .center => c.YGJustifyCenter,
        .end => c.YGJustifyFlexEnd,
        .between => c.YGJustifySpaceBetween,
        .around => c.YGJustifySpaceAround,
        .evenly => c.YGJustifySpaceEvenly,
    };
}

const edges = [4]c.YGEdge{ c.YGEdgeTop, c.YGEdgeRight, c.YGEdgeBottom, c.YGEdgeLeft };

/// Sets a Yoga node's style from a resolved Layout.
pub fn toYoga(n: c.YGNodeRef, l: Layout) void {
    c.YGNodeStyleSetFlexShrink(n, 1);
    if (l.display_none) c.YGNodeStyleSetDisplay(n, c.YGDisplayNone);
    if (l.dir) |d| {
        c.YGNodeStyleSetFlexDirection(n, switch (d) {
            .row => c.YGFlexDirectionRow,
            .col => c.YGFlexDirectionColumn,
            .row_rev => c.YGFlexDirectionRowReverse,
            .col_rev => c.YGFlexDirectionColumnReverse,
        });
    } else {
        // A block: children stack and fill the width, as GPUI's divs do.
        c.YGNodeStyleSetFlexDirection(n, c.YGFlexDirectionColumn);
    }
    if (l.wrap) c.YGNodeStyleSetFlexWrap(n, c.YGWrapWrap);
    if (l.items) |a| c.YGNodeStyleSetAlignItems(n, ygAlign(a));
    if (l.justify) |a| c.YGNodeStyleSetJustifyContent(n, ygJustify(a));
    if (l.self) |a| c.YGNodeStyleSetAlignSelf(n, ygAlign(a));
    if (l.content) |a| c.YGNodeStyleSetAlignContent(n, ygAlign(a));
    if (l.grow) |g| c.YGNodeStyleSetFlexGrow(n, g);
    if (l.shrink) |g| c.YGNodeStyleSetFlexShrink(n, g);
    if (l.basis) |b| ygLen(c.YGNodeStyleSetFlexBasis, c.YGNodeStyleSetFlexBasisPercent, c.YGNodeStyleSetFlexBasisAuto, n, b);
    if (l.w) |v| ygLen(c.YGNodeStyleSetWidth, c.YGNodeStyleSetWidthPercent, c.YGNodeStyleSetWidthAuto, n, v);
    if (l.h) |v| ygLen(c.YGNodeStyleSetHeight, c.YGNodeStyleSetHeightPercent, c.YGNodeStyleSetHeightAuto, n, v);
    if (l.min_w) |v| ygLen(c.YGNodeStyleSetMinWidth, c.YGNodeStyleSetMinWidthPercent, null, n, v);
    if (l.min_h) |v| ygLen(c.YGNodeStyleSetMinHeight, c.YGNodeStyleSetMinHeightPercent, null, n, v);
    if (l.max_w) |v| ygLen(c.YGNodeStyleSetMaxWidth, c.YGNodeStyleSetMaxWidthPercent, null, n, v);
    if (l.max_h) |v| ygLen(c.YGNodeStyleSetMaxHeight, c.YGNodeStyleSetMaxHeightPercent, null, n, v);
    for (edges, 0..) |e, i| {
        if (l.pad[i]) |v| switch (v) {
            .pt => |p| c.YGNodeStyleSetPadding(n, e, p),
            .pct => |p| c.YGNodeStyleSetPaddingPercent(n, e, p),
            .auto => {},
        };
        if (l.margin[i]) |v| switch (v) {
            .pt => |p| c.YGNodeStyleSetMargin(n, e, p),
            .pct => |p| c.YGNodeStyleSetMarginPercent(n, e, p),
            .auto => c.YGNodeStyleSetMarginAuto(n, e),
        };
        if (l.pos[i]) |v| switch (v) {
            .pt => |p| c.YGNodeStyleSetPosition(n, e, p),
            .pct => |p| c.YGNodeStyleSetPositionPercent(n, e, p),
            .auto => {},
        };
        if (l.border[i]) c.YGNodeStyleSetBorder(n, e, 1);
    }
    if (l.gap_x) |g| c.YGNodeStyleSetGap(n, c.YGGutterColumn, g);
    if (l.gap_y) |g| c.YGNodeStyleSetGap(n, c.YGGutterRow, g);
    if (l.absolute) c.YGNodeStyleSetPositionType(n, c.YGPositionTypeAbsolute);
    if (l.overflow != .visible) c.YGNodeStyleSetOverflow(n, if (l.overflow == .scroll) c.YGOverflowScroll else c.YGOverflowHidden);
    if (l.aspect) |a| c.YGNodeStyleSetAspectRatio(n, a);
}

// ---------------------------------------------------------------------

const testing = std.testing;

fn word(name: []const u8, st: u32, a: []const core.StyleArg) core.StyleWord {
    return .{ .name = core.str(name), .state = st, .group = .{}, .args = if (a.len > 0) a.ptr else null, .n_args = a.len };
}

test "points become cells on each axis" {
    try testing.expectEqual(@as(f32, 2), cells(16, .x));
    try testing.expectEqual(@as(f32, 1), cells(16, .y));
    try testing.expectEqual(@as(f32, 0), cells(8, .y));
    try testing.expectEqual(@as(f32, 1), cells(12, .y));
    try testing.expectEqual(@as(f32, 3), cells(20, .x));
}

test "scale words follow Tailwind's 4-point steps" {
    try testing.expectEqual(Len{ .pt = 16 }, scale("4").?);
    try testing.expectEqual(Len{ .pt = 2 }, scale("0p5").?);
    try testing.expectEqual(Len{ .pct = 50 }, scale("1-2").?);
    try testing.expectEqual(Len{ .pt = -8 }, scale("neg-2").?);
    try testing.expectEqual(Len.auto, scale("auto").?);
    try testing.expect(scale("xl") == null);
}

test "resolve applies base words, then state words over them" {
    const px40 = [_]core.StyleArg{.{ .kind = c.UIT_ARG_PX, .a = 40, .rgba = 0, .text = .{} }};
    const red = [_]core.StyleArg{.{ .kind = c.UIT_ARG_RGBA, .a = 0, .rgba = 0xff0000ff, .text = .{} }};
    const blue = [_]core.StyleArg{.{ .kind = c.UIT_ARG_RGBA, .a = 0, .rgba = 0x0000ffff, .text = .{} }};
    const ws = [_]core.StyleWord{
        word("bg", c.UIT_STATE_HOVER, &blue),
        word("h-flex", c.UIT_STATE_BASE, &.{}),
        word("size", c.UIT_STATE_BASE, &px40),
        word("bg", c.UIT_STATE_BASE, &red),
        word("p-4", c.UIT_STATE_BASE, &.{}),
        word("border-1", c.UIT_STATE_BASE, &.{}),
        word("font-semibold", c.UIT_STATE_BASE, &.{}),
        word("primary", c.UIT_STATE_BASE, &.{}),
    };
    const base = resolve(&ws, .{});
    try testing.expectEqual(@as(u32, 0xff0000ff), base.look.bg.?);
    try testing.expectEqual(Len{ .pt = 5 }, base.layout.w.?);
    try testing.expectEqual(Len{ .pt = 2 }, base.layout.h.?);
    try testing.expectEqual(Len{ .pt = 2 }, base.layout.pad[3].?);
    try testing.expectEqual(Len{ .pt = 1 }, base.layout.pad[0].?);
    try testing.expect(base.layout.border[0] and base.layout.border[3]);
    try testing.expectEqual(Align.center, base.layout.items.?);
    try testing.expect(base.look.bold.?);
    try testing.expectEqualStrings("primary", base.look.variant.?);
    const hov = resolve(&ws, .{ .hover = true });
    try testing.expectEqual(@as(u32, 0x0000ffff), hov.look.bg.?);
}
