//! Terminal colors: the core hands over 24-bit RGB with theme tokens
//! already resolved (the named theme's palette included), and this maps it
//! to what the terminal can show. `truecolor` sends it as is; `256` picks
//! the nearest xterm-256 color (the 6x6x6 cube or the gray ramp, never the
//! 16 the user's terminal theme redefines); `16` picks the nearest of the
//! 16 ANSI colors, with their xterm defaults. The depth comes from
//! `--colors`, else from COLORTERM (`truecolor` or `24bit` means 24-bit),
//! else 256.

const std = @import("std");

pub const Depth = enum { truecolor, @"256", @"16" };

/// What the terminal says it can do.
pub fn detect(colorterm: ?[]const u8) Depth {
    const v = colorterm orelse return .@"256";
    if (std.mem.eql(u8, v, "truecolor") or std.mem.eql(u8, v, "24bit")) return .truecolor;
    return .@"256";
}

pub fn parse(s: []const u8) ?Depth {
    return std.meta.stringToEnum(Depth, s);
}

/// A terminal color: 24-bit, or an index into the terminal's palette.
pub const Color = union(enum) { rgb: [3]u8, index: u8 };

pub fn map(depth: Depth, v: u32) Color {
    const r: u8 = @intCast((v >> 16) & 0xff);
    const g: u8 = @intCast((v >> 8) & 0xff);
    const b: u8 = @intCast(v & 0xff);
    return switch (depth) {
        .truecolor => .{ .rgb = .{ r, g, b } },
        .@"256" => .{ .index = to256(r, g, b) },
        .@"16" => .{ .index = to16(r, g, b) },
    };
}

/// The xterm cube's six levels.
const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };

fn dist(a: [3]u8, b: [3]u8) u32 {
    // Weighted for the eye (the "redmean" approximation, simplified).
    var d: u32 = 0;
    const w = [_]u32{ 3, 4, 2 };
    for (0..3) |i| {
        const x: i32 = @as(i32, a[i]) - @as(i32, b[i]);
        d += w[i] * @as(u32, @intCast(x * x));
    }
    return d;
}

fn nearestLevel(c: u8) u8 {
    var best: u8 = 0;
    for (levels, 0..) |l, i| {
        if (@abs(@as(i32, l) - @as(i32, c)) < @abs(@as(i32, levels[best]) - @as(i32, c))) best = @intCast(i);
    }
    return best;
}

/// The nearest of xterm's colors 16 to 255.
pub fn to256(r: u8, g: u8, b: u8) u8 {
    const want = [3]u8{ r, g, b };
    const ri = nearestLevel(r);
    const gi = nearestLevel(g);
    const bi = nearestLevel(b);
    const cube = [3]u8{ levels[ri], levels[gi], levels[bi] };
    const cube_i: u8 = 16 + 36 * ri + 6 * gi + bi;
    // The gray ramp: 232 + n is 8 + 10n.
    const avg: u32 = (@as(u32, r) + g + b) / 3;
    const n: u8 = if (avg < 8) 0 else @intCast(@min(23, (avg - 8 + 5) / 10));
    const gv: u8 = 8 + 10 * n;
    const gray = [3]u8{ gv, gv, gv };
    return if (dist(gray, want) < dist(cube, want)) 232 + n else cube_i;
}

/// xterm's default 16 colors.
const ansi = [16][3]u8{
    .{ 0, 0, 0 },       .{ 205, 0, 0 },     .{ 0, 205, 0 },   .{ 205, 205, 0 },
    .{ 0, 0, 238 },     .{ 205, 0, 205 },   .{ 0, 205, 205 }, .{ 229, 229, 229 },
    .{ 127, 127, 127 }, .{ 255, 0, 0 },     .{ 0, 255, 0 },   .{ 255, 255, 0 },
    .{ 92, 92, 255 },   .{ 255, 0, 255 },   .{ 0, 255, 255 }, .{ 255, 255, 255 },
};

pub fn to16(r: u8, g: u8, b: u8) u8 {
    const want = [3]u8{ r, g, b };
    var best: u8 = 0;
    for (ansi, 0..) |c, i| if (dist(c, want) < dist(ansi[best], want)) {
        best = @intCast(i);
    };
    return best;
}

test "depth from COLORTERM and --colors" {
    try std.testing.expectEqual(Depth.truecolor, detect("truecolor"));
    try std.testing.expectEqual(Depth.truecolor, detect("24bit"));
    try std.testing.expectEqual(Depth.@"256", detect(null));
    try std.testing.expectEqual(Depth.@"256", detect("yes"));
    try std.testing.expectEqual(Depth.@"16", parse("16").?);
    try std.testing.expect(parse("88") == null);
}

test "256: exact cube and gray colors map to themselves" {
    try std.testing.expectEqual(@as(u8, 16), to256(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 231), to256(255, 255, 255));
    try std.testing.expectEqual(@as(u8, 196), to256(255, 0, 0));
    try std.testing.expectEqual(@as(u8, 244), to256(128, 128, 128));
    // Catppuccin Mocha's base (#1e1e2e) is a near-black gray, not a blue.
    try std.testing.expectEqual(@as(u8, 235), to256(0x1e, 0x1e, 0x2e));
}

test "16: the nearest ANSI color" {
    try std.testing.expectEqual(@as(u8, 0), to16(10, 10, 20));
    try std.testing.expectEqual(@as(u8, 15), to16(250, 250, 250));
    try std.testing.expectEqual(@as(u8, 1), to16(200, 30, 30));
    try std.testing.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, map(.truecolor, 0x010203));
}
