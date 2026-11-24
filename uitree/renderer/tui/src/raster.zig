//! Canvas ops (components.md § Data file formats, `ops`) and charts,
//! rasterized for a terminal: a pixel is half a cell, 8×8 points, so a
//! cell shows two pixels with `▀` (the top in its foreground, the bottom
//! in its background). Fills and strokes land on whole pixels; text ops
//! are printed in cells over them. The geometry is in node points, as on
//! GPUI: `rect ID X Y W H`, `circle ID CX CY R`, `line ID X1 Y1 X2 Y2`,
//! `path ID SEG...` (SVG path letters, absolute and relative), and
//! `text ID X Y STRING`, with `fill=`, `stroke=`, `border=`, `color=`,
//! `width=`, `opacity=` and their `hover:` forms.

const std = @import("std");

/// Points per pixel on each axis.
pub const px_w: f32 = 8;
pub const px_h: f32 = 8;

pub const Pixmap = struct {
    w: usize,
    h: usize,
    /// RGBA per pixel, 0 where nothing was drawn.
    px: []u32,

    pub fn init(a: std.mem.Allocator, w: usize, h: usize) !Pixmap {
        const p = try a.alloc(u32, w * h);
        @memset(p, 0);
        return .{ .w = w, .h = h, .px = p };
    }

    pub fn get(p: *const Pixmap, x: usize, y: usize) u32 {
        return p.px[y * p.w + x];
    }

    /// Paints one pixel, blending a translucent color over what's there.
    pub fn plot(p: *Pixmap, x: i64, y: i64, rgba: u32) void {
        if (x < 0 or y < 0 or x >= p.w or y >= p.h) return;
        const i: usize = @intCast(y * @as(i64, @intCast(p.w)) + x);
        const a = rgba & 0xff;
        if (a == 0) return;
        // Over nothing, a translucent color is taken as opaque.
        p.px[i] = if (a == 0xff or p.px[i] == 0) rgba | 0xff else mix(p.px[i], rgba);
    }

    /// Fills the pixels whose centers fall in the rect (points).
    pub fn rect(p: *Pixmap, x: f32, y: f32, w: f32, h: f32, rgba: u32) void {
        const x0 = pix(x, px_w);
        const y0 = pix(y, px_h);
        var x1 = pix(x + w, px_w);
        var y1 = pix(y + h, px_h);
        if (x1 == x0 and w > 0) x1 = x0 + 1;
        if (y1 == y0 and h > 0) y1 = y0 + 1;
        var yy = y0;
        while (yy < y1) : (yy += 1) {
            var xx = x0;
            while (xx < x1) : (xx += 1) p.plot(xx, yy, rgba);
        }
    }

    /// The outline of a rect, one pixel wide.
    pub fn frame(p: *Pixmap, x: f32, y: f32, w: f32, h: f32, rgba: u32) void {
        const x0 = pix(x, px_w);
        const y0 = pix(y, px_h);
        const x1 = @max(x0, pix(x + w, px_w) - 1);
        const y1 = @max(y0, pix(y + h, px_h) - 1);
        var xx = x0;
        while (xx <= x1) : (xx += 1) {
            p.plot(xx, y0, rgba);
            p.plot(xx, y1, rgba);
        }
        var yy = y0;
        while (yy <= y1) : (yy += 1) {
            p.plot(x0, yy, rgba);
            p.plot(x1, yy, rgba);
        }
    }

    pub fn disc(p: *Pixmap, cx: f32, cy: f32, r: f32, rgba: u32) void {
        const x0 = pix(cx - r, px_w) - 1;
        const x1 = pix(cx + r, px_w) + 1;
        const y0 = pix(cy - r, px_h) - 1;
        const y1 = pix(cy + r, px_h) + 1;
        // A circle smaller than a pixel is still a dot.
        if (r * 2 < px_w) return p.plot(pix(cx, px_w), pix(cy, px_h), rgba);
        var yy = y0;
        while (yy <= y1) : (yy += 1) {
            var xx = x0;
            while (xx <= x1) : (xx += 1) {
                const dx = (@as(f32, @floatFromInt(xx)) + 0.5) * px_w - cx;
                const dy = (@as(f32, @floatFromInt(yy)) + 0.5) * px_h - cy;
                if (dx * dx + dy * dy <= r * r) p.plot(xx, yy, rgba);
            }
        }
    }

    pub fn ring(p: *Pixmap, cx: f32, cy: f32, r: f32, rgba: u32) void {
        const steps: usize = @max(16, @as(usize, @intFromFloat(r)));
        var prev: [2]f32 = .{ cx + r, cy };
        for (1..steps + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps)) * std.math.tau;
            const q: [2]f32 = .{ cx + r * @cos(t), cy + r * @sin(t) };
            p.line(prev[0], prev[1], q[0], q[1], rgba);
            prev = q;
        }
    }

    /// A line one pixel wide (Bresenham on the pixel grid).
    pub fn line(p: *Pixmap, ax: f32, ay: f32, bx: f32, by: f32, rgba: u32) void {
        var x0 = pix(ax, px_w);
        var y0 = pix(ay, px_h);
        const x1 = pix(bx, px_w);
        const y1 = pix(by, px_h);
        const dx: i64 = @intCast(@abs(x1 - x0));
        const dy: i64 = -@as(i64, @intCast(@abs(y1 - y0)));
        const sx: i64 = if (x0 < x1) 1 else -1;
        const sy: i64 = if (y0 < y1) 1 else -1;
        var err = dx + dy;
        var n: usize = 0;
        while (n < 100000) : (n += 1) {
            p.plot(x0, y0, rgba);
            if (x0 == x1 and y0 == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x0 += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y0 += sy;
            }
        }
    }

    /// Fills a polygon (even-odd), by pixel centers.
    pub fn polygon(p: *Pixmap, pts: []const [2]f32, rgba: u32) void {
        if (pts.len < 3) return;
        var ymin: f32 = pts[0][1];
        var ymax: f32 = pts[0][1];
        for (pts) |q| {
            ymin = @min(ymin, q[1]);
            ymax = @max(ymax, q[1]);
        }
        var yy = @max(0, pix(ymin, px_h));
        const yend = @min(@as(i64, @intCast(p.h)), pix(ymax, px_h) + 1);
        var xs: [256]f32 = undefined;
        while (yy < yend) : (yy += 1) {
            const sy = (@as(f32, @floatFromInt(yy)) + 0.5) * px_h;
            var n: usize = 0;
            var j = pts.len - 1;
            for (pts, 0..) |a, i| {
                const b = pts[j];
                j = i;
                if ((a[1] > sy) != (b[1] > sy) and n < xs.len) {
                    xs[n] = a[0] + (sy - a[1]) / (b[1] - a[1]) * (b[0] - a[0]);
                    n += 1;
                }
            }
            std.mem.sort(f32, xs[0..n], {}, std.sort.asc(f32));
            var k: usize = 0;
            while (k + 1 < n) : (k += 2) {
                var xx = pix(xs[k] + px_w / 2, px_w);
                const x1 = pix(xs[k + 1] + px_w / 2, px_w);
                while (xx < x1) : (xx += 1) p.plot(xx, yy, rgba);
            }
        }
    }
};

fn pix(v: f32, unit: f32) i64 {
    if (!std.math.isFinite(v)) return 0;
    return @intFromFloat(@floor(std.math.clamp(v / unit, -1e6, 1e6)));
}

/// `over` blended onto `under`, both RGBA.
pub fn mix(under: u32, over: u32) u32 {
    const a: u32 = over & 0xff;
    var out: u32 = 0;
    inline for (.{ 24, 16, 8 }) |sh| {
        const u = (under >> sh) & 0xff;
        const o = (over >> sh) & 0xff;
        out |= ((o * a + u * (255 - a)) / 255) << sh;
    }
    return out | 0xff;
}

// ---------------------------------------------------------------------
// Ops

pub const Kind = enum { rect, circle, line, path, text, image, other };

pub const Op = struct {
    kind: Kind,
    id: []const u8,
    geom: [4]f32 = .{ 0, 0, 0, 0 },
    /// A path's segment words, or a text's string.
    words: []const []const u8 = &.{},
    text: []const u8 = "",
    attrs: []const []const u8 = &.{},

    pub fn attr(o: Op, name: []const u8, hovered: bool) ?[]const u8 {
        if (hovered) {
            for (o.attrs) |w| if (std.mem.startsWith(u8, w, "hover:")) {
                const r = w["hover:".len..];
                if (r.len > name.len and r[name.len] == '=' and std.mem.startsWith(u8, r, name)) return r[name.len + 1 ..];
            };
        }
        for (o.attrs) |w| if (w.len > name.len and w[name.len] == '=' and std.mem.startsWith(u8, w, name)) return w[name.len + 1 ..];
        return null;
    }
};

/// One line of `ops`, already split into words by the core.
pub fn parseOp(fields: []const []const u8) ?Op {
    if (fields.len < 2) return null;
    const kinds = std.StaticStringMap(Kind).initComptime(.{
        .{ "rect", .rect }, .{ "circle", .circle }, .{ "line", .line }, .{ "path", .path }, .{ "text", .text }, .{ "image", .image },
    });
    var o: Op = .{ .kind = kinds.get(fields[0]) orelse .other, .id = fields[1] };
    const rest = fields[2..];
    var nattr: usize = rest.len;
    // Attributes are the trailing name=value words.
    while (nattr > 0 and isAttr(rest[nattr - 1])) nattr -= 1;
    o.attrs = rest[nattr..];
    const geo = rest[0..nattr];
    switch (o.kind) {
        .path => o.words = geo,
        .text => {
            if (geo.len < 3) return null;
            o.geom[0] = num(geo[0]);
            o.geom[1] = num(geo[1]);
            o.text = geo[2];
        },
        else => {
            for (geo, 0..) |w, k| if (k < 4) {
                o.geom[k] = num(w);
            };
        },
    }
    return o;
}

fn isAttr(w: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, w, '=') orelse return false;
    if (eq == 0) return false;
    for (w[0..eq]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == ':' or ch == '_')) return false;
    return true;
}

pub fn num(w: []const u8) f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, w, " ,")) catch 0;
}

/// A path's segment words (`M10,10 L20,25`, `C1,2,3,4,5,6`, `Z`) as
/// polylines in absolute points, curves flattened.
pub fn polylines(a: std.mem.Allocator, words: []const []const u8) ![]const []const [2]f32 {
    var out: std.ArrayList([]const [2]f32) = .empty;
    var cur: std.ArrayList([2]f32) = .empty;
    // Numbers and letters, as one stream: `M10,10` and `M 10 10` alike.
    var toks: std.ArrayList([]const u8) = .empty;
    for (words) |w| {
        var i: usize = 0;
        while (i < w.len) {
            const ch = w[i];
            if (std.ascii.isAlphabetic(ch) and ch != 'e' and ch != 'E') {
                try toks.append(a, w[i .. i + 1]);
                i += 1;
            } else if (ch == ',' or ch == ' ') {
                i += 1;
            } else {
                var j = i + 1;
                while (j < w.len and (std.ascii.isDigit(w[j]) or w[j] == '.' or w[j] == 'e' or w[j] == 'E' or ((w[j] == '-' or w[j] == '+') and (w[j - 1] == 'e' or w[j - 1] == 'E')))) j += 1;
                try toks.append(a, w[i..j]);
                i = j;
            }
        }
    }
    var pos: [2]f32 = .{ 0, 0 };
    var start: [2]f32 = .{ 0, 0 };
    var cmd: u8 = 'M';
    var k: usize = 0;
    const next = struct {
        fn f(t: []const []const u8, kk: *usize) ?f32 {
            if (kk.* >= t.len) return null;
            const s = t[kk.*];
            if (s.len == 1 and std.ascii.isAlphabetic(s[0])) return null;
            kk.* += 1;
            return num(s);
        }
    }.f;
    while (k < toks.items.len) {
        const t = toks.items[k];
        if (t.len == 1 and std.ascii.isAlphabetic(t[0])) {
            cmd = t[0];
            k += 1;
            if (cmd == 'Z' or cmd == 'z') {
                if (cur.items.len > 0) try cur.append(a, start);
                pos = start;
                continue;
            }
        }
        const rel = std.ascii.isLower(cmd);
        const base: [2]f32 = if (rel) pos else .{ 0, 0 };
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = next(toks.items, &k) orelse break;
                const y = next(toks.items, &k) orelse break;
                if (cur.items.len > 1) try out.append(a, try cur.toOwnedSlice(a)) else cur.clearRetainingCapacity();
                pos = .{ base[0] + x, base[1] + y };
                start = pos;
                try cur.append(a, pos);
                cmd = if (rel) 'l' else 'L';
            },
            'L', 'T' => {
                const x = next(toks.items, &k) orelse break;
                const y = next(toks.items, &k) orelse break;
                pos = .{ base[0] + x, base[1] + y };
                try cur.append(a, pos);
            },
            'H' => {
                const x = next(toks.items, &k) orelse break;
                pos[0] = base[0] + x;
                try cur.append(a, pos);
            },
            'V' => {
                const y = next(toks.items, &k) orelse break;
                pos[1] = (if (rel) pos[1] else 0) + y;
                try cur.append(a, pos);
            },
            'C', 'S', 'Q' => {
                const n: usize = if (std.ascii.toUpper(cmd) == 'C') 6 else 4;
                var v: [6]f32 = undefined;
                for (0..n) |q| v[q] = next(toks.items, &k) orelse return out.toOwnedSlice(a);
                const p0 = pos;
                const end: [2]f32 = .{ base[0] + v[n - 2], base[1] + v[n - 1] };
                for (1..9) |s| {
                    const tt = @as(f32, @floatFromInt(s)) / 8;
                    const u = 1 - tt;
                    var q: [2]f32 = undefined;
                    if (n == 6) {
                        const c1: [2]f32 = .{ base[0] + v[0], base[1] + v[1] };
                        const c2: [2]f32 = .{ base[0] + v[2], base[1] + v[3] };
                        for (0..2) |d| q[d] = u * u * u * p0[d] + 3 * u * u * tt * c1[d] + 3 * u * tt * tt * c2[d] + tt * tt * tt * end[d];
                    } else {
                        const c1: [2]f32 = .{ base[0] + v[0], base[1] + v[1] };
                        for (0..2) |d| q[d] = u * u * p0[d] + 2 * u * tt * c1[d] + tt * tt * end[d];
                    }
                    try cur.append(a, q);
                }
                pos = end;
            },
            'A' => {
                var v: [7]f32 = undefined;
                for (0..7) |q| v[q] = next(toks.items, &k) orelse return out.toOwnedSlice(a);
                pos = .{ base[0] + v[5], base[1] + v[6] };
                try cur.append(a, pos);
            },
            else => k += 1,
        }
    }
    if (cur.items.len > 0) try out.append(a, try cur.toOwnedSlice(a));
    return out.toOwnedSlice(a);
}

/// Whether point q (node points) is on the op, for `item=` on pointer
/// events: inside a rect or circle, near a line or path, on a text.
pub fn hits(a: std.mem.Allocator, o: Op, q: [2]f32) bool {
    const g = o.geom;
    const slack: f32 = 6;
    switch (o.kind) {
        .rect, .image => return q[0] >= g[0] and q[1] >= g[1] and q[0] <= g[0] + g[2] and q[1] <= g[1] + g[3],
        .circle => return (q[0] - g[0]) * (q[0] - g[0]) + (q[1] - g[1]) * (q[1] - g[1]) <= g[2] * g[2],
        .line => return segDist(q, .{ g[0], g[1] }, .{ g[2], g[3] }) <= slack,
        .text => return q[0] >= g[0] and q[1] >= g[1] - 4 and q[0] <= g[0] + @as(f32, @floatFromInt(o.text.len)) * 8 and q[1] <= g[1] + 18,
        .path => {
            const ls = polylines(a, o.words) catch return false;
            for (ls) |l| {
                if (l.len > 2 and o.attr("fill", false) != null and inside(q, l)) return true;
                for (1..l.len) |i| if (segDist(q, l[i - 1], l[i]) <= slack) return true;
            }
            return false;
        },
        .other => return false,
    }
}

fn segDist(p: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const l2 = dx * dx + dy * dy;
    var t: f32 = if (l2 == 0) 0 else ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2;
    t = std.math.clamp(t, 0, 1);
    const ex = a[0] + t * dx - p[0];
    const ey = a[1] + t * dy - p[1];
    return @sqrt(ex * ex + ey * ey);
}

fn inside(p: [2]f32, poly: []const [2]f32) bool {
    var in = false;
    var j = poly.len - 1;
    for (poly, 0..) |a, i| {
        const b = poly[j];
        j = i;
        if ((a[1] > p[1]) != (b[1] > p[1]) and p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]) in = !in;
    }
    return in;
}

const testing = std.testing;

test "ops parse with trailing attributes" {
    const o = parseOp(&.{ "rect", "bg", "0", "0", "40", "16", "fill=muted", "hover:fill=accent" }).?;
    try testing.expectEqual(Kind.rect, o.kind);
    try testing.expectEqual(@as(f32, 40), o.geom[2]);
    try testing.expectEqualStrings("muted", o.attr("fill", false).?);
    try testing.expectEqualStrings("accent", o.attr("fill", true).?);
    const t = parseOp(&.{ "text", "t", "4", "8", "hi there", "size=11" }).?;
    try testing.expectEqualStrings("hi there", t.text);
}

test "paths flatten, relative and absolute" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ls = try polylines(arena.allocator(), &.{ "M10,10", "L20,25", "l5,5", "Z" });
    try testing.expectEqual(@as(usize, 1), ls.len);
    try testing.expectEqual(@as(usize, 4), ls[0].len);
    try testing.expectEqual(@as(f32, 25), ls[0][2][0]);
    try testing.expect(hits(arena.allocator(), parseOp(&.{ "path", "p", "M0,0", "L100,0" }).?, .{ 50, 3 }));
}

test "a rect fills the pixels it covers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p = try Pixmap.init(arena.allocator(), 4, 4);
    p.rect(8, 8, 16, 8, 0xff0000ff);
    try testing.expectEqual(@as(u32, 0), p.get(0, 1));
    try testing.expectEqual(@as(u32, 0xff0000ff), p.get(1, 1));
    try testing.expectEqual(@as(u32, 0xff0000ff), p.get(2, 1));
    try testing.expectEqual(@as(u32, 0), p.get(1, 2));
}
