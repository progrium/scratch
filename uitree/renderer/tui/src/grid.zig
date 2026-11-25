//! An off-screen grid of terminal cells. Every frame is drawn here first
//! and then copied to libvaxis's screen, so drawing is testable without a
//! terminal and a frame can be dumped as text.
//!
//! Colors are 0xRRGGBB. Translucent colors (the core's 0xRRGGBBAA) are
//! blended over what is already in the cell, so a `bg=muted/50` hover
//! looks right over any background.

const std = @import("std");
const unicode = @import("vaxis").unicode;
const gwidth = @import("vaxis").gwidth;

pub const Attrs = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    reverse: bool = false,
    blink: bool = false,
    /// The underline's look when `underline` is set (a terminal node's
    /// cells; everything else draws single).
    ul_style: UlStyle = .single,
    _pad: u6 = 0,
};

pub const UlStyle = enum(u3) { single, double, curly, dotted, dashed };

/// The terminal cursor's look (a terminal node's own cursor; an input's
/// caret is a blinking bar).
pub const CursorShape = enum { bar, block, underline };

pub const Cell = struct {
    /// The grapheme; "" for the right half of a wide character.
    ch: []const u8 = " ",
    fg: u32 = 0x000000,
    bg: u32 = 0xffffff,
    attrs: Attrs = .{},
    /// A hyperlink target (link's href), or "".
    link: []const u8 = "",
    /// The underline's color (0xRRGGBB), when not the glyph's.
    ul_color: ?u32 = null,
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
    }

    pub fn empty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }
};

/// 0xRRGGBBAA over 0xRRGGBB.
pub fn blend(over: u32, under: u32) u32 {
    const a: u32 = over & 0xff;
    const rgb = over >> 8;
    if (a == 0xff) return rgb;
    if (a == 0) return under;
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const o = (rgb >> sh) & 0xff;
        const u = (under >> sh) & 0xff;
        const v = (o * a + u * (255 - a) + 127) / 255;
        out |= v << sh;
    }
    return out;
}

/// Display width of a string in cells.
pub fn width(s: []const u8) u16 {
    return gwidth.gwidth(s, .unicode);
}

pub const Grid = struct {
    w: u16,
    h: u16,
    cells: []Cell,
    /// Where the terminal cursor goes (an input's caret, a terminal
    /// node's cursor), if anywhere.
    cursor: ?struct { x: u16, y: u16, shape: CursorShape = .bar, blink: bool = true } = null,

    pub fn init(a: std.mem.Allocator, w: u16, h: u16) !Grid {
        const cells = try a.alloc(Cell, @as(usize, w) * h);
        @memset(cells, .{});
        return .{ .w = w, .h = h, .cells = cells };
    }

    pub fn deinit(g: *Grid, a: std.mem.Allocator) void {
        a.free(g.cells);
    }

    pub fn bounds(g: *const Grid) Rect {
        return .{ .w = g.w, .h = g.h };
    }

    pub fn at(g: *Grid, x: i32, y: i32) ?*Cell {
        if (x < 0 or y < 0 or x >= g.w or y >= g.h) return null;
        return &g.cells[@as(usize, @intCast(y)) * g.w + @as(usize, @intCast(x))];
    }

    pub fn clear(g: *Grid, fg: u32, bg: u32) void {
        @memset(g.cells, .{ .fg = fg, .bg = bg });
        g.cursor = null;
    }

    /// Paints a background (0xRRGGBBAA) over r ∩ clip, keeping glyphs.
    pub fn fill(g: *Grid, r: Rect, clip: Rect, rgba: u32) void {
        const q = r.intersect(clip).intersect(g.bounds());
        var y = q.y;
        while (y < q.y + q.h) : (y += 1) {
            var x = q.x;
            while (x < q.x + q.w) : (x += 1) {
                const cell = g.at(x, y).?;
                cell.bg = blend(rgba, cell.bg);
            }
        }
    }

    /// Clears glyphs in r ∩ clip (an opaque box drawn over text).
    pub fn blank(g: *Grid, r: Rect, clip: Rect) void {
        const q = r.intersect(clip).intersect(g.bounds());
        var y = q.y;
        while (y < q.y + q.h) : (y += 1) {
            var x = q.x;
            while (x < q.x + q.w) : (x += 1) {
                const cell = g.at(x, y).?;
                cell.ch = " ";
                cell.attrs = .{};
                cell.link = "";
                cell.ul_color = null;
            }
        }
    }

    pub const Pen = struct {
        fg: u32 = 0x000000ff,
        attrs: Attrs = .{},
        link: []const u8 = "",
        /// Override the background under the glyph (0xRRGGBBAA), if set.
        bg: ?u32 = null,
        /// The underline's color (0xRRGGBBAA), when not the glyph's.
        ul_color: ?u32 = null,
    };

    /// Puts one grapheme at (x, y) if it lies inside clip.
    pub fn put(g: *Grid, x: i32, y: i32, clip: Rect, ch: []const u8, pen: Pen) void {
        if (!clip.contains(x, y)) return;
        const cell = g.at(x, y) orelse return;
        // Overwriting the right half of a wide glyph: blank its left half.
        if (cell.ch.len == 0) if (g.at(x - 1, y)) |l| {
            l.ch = " ";
        };
        if (pen.bg) |bg| cell.bg = blend(bg, cell.bg);
        cell.ch = ch;
        cell.fg = blend(pen.fg, cell.bg);
        cell.attrs = pen.attrs;
        cell.link = pen.link;
        cell.ul_color = if (pen.ul_color) |u| blend(u, cell.bg) else null;
        const wd = width(ch);
        if (wd == 2) {
            if (clip.contains(x + 1, y)) if (g.at(x + 1, y)) |r| {
                if (pen.bg) |bg| r.bg = blend(bg, r.bg);
                r.ch = "";
                r.attrs = pen.attrs;
            } else {
                cell.ch = " ";
            };
        }
    }

    /// Prints s from (x, y) on one row, clipped; returns the next column.
    pub fn print(g: *Grid, x: i32, y: i32, clip: Rect, s: []const u8, pen: Pen) i32 {
        var cx = x;
        var it = unicode.GraphemeIterator.init(s);
        while (it.next()) |gr| {
            const ch = gr.bytes(s);
            if (ch[0] == '\n' or ch[0] == '\r') continue;
            const wd: i32 = if (ch[0] == '\t') 1 else width(ch);
            if (wd == 0) continue;
            g.put(cx, y, clip, if (ch[0] == '\t') " " else ch, pen);
            cx += wd;
        }
        return cx;
    }

    /// The grid as plain text, one line per row, trailing blanks kept.
    pub fn dump(g: *const Grid, w: *std.Io.Writer) !void {
        var y: usize = 0;
        while (y < g.h) : (y += 1) {
            for (g.cells[y * g.w .. (y + 1) * g.w]) |cell| try w.writeAll(cell.ch);
            try w.writeByte('\n');
        }
    }

    pub fn row(g: *const Grid, a: std.mem.Allocator, y: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (g.cells[y * g.w .. (y + 1) * g.w]) |cell| try out.appendSlice(a, cell.ch);
        return out.toOwnedSlice(a);
    }
};

test "blend mixes a translucent color over the cell" {
    try std.testing.expectEqual(@as(u32, 0xffffff), blend(0xffffffff, 0x000000));
    try std.testing.expectEqual(@as(u32, 0x000000), blend(0xffffff00, 0x000000));
    try std.testing.expectEqual(@as(u32, 0x808080), blend(0xffffff80, 0x000000));
}

test "print clips and keeps wide characters whole" {
    var g = try Grid.init(std.testing.allocator, 6, 1);
    defer g.deinit(std.testing.allocator);
    const end = g.print(0, 0, .{ .w = 5, .h = 1 }, "a界b—cdef", .{});
    try std.testing.expectEqual(@as(i32, 9), end);
    const r = try g.row(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a界b— ", r);
}
