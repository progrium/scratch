//! stat(5)'s Dir: packed for Rstat and directory reads, parsed for
//! Twstat and the client. (hyper9's attr.zig has the same, but it imports
//! wire.zig itself, and a file can belong to only one module.)

const std = @import("std");
const wire = @import("wire.zig");

pub const Dir = struct {
    qid: wire.Qid = .{},
    mode: u32 = 0,
    atime: u32 = 0,
    mtime: u32 = 0,
    length: u64 = 0,
    name: []const u8 = "",
    uid: []const u8 = "",
    gid: []const u8 = "",
    muid: []const u8 = "",

    /// Packs with its size prefix at the start of `out`.
    pub fn pack(d: *const Dir, out: []u8) wire.Error![]u8 {
        var w: wire.Writer = .{ .b = out, .at = 2 };
        if (out.len < 2) return error.NoSpace;
        try w.int(u16, 0); // type
        try w.int(u32, 0); // dev
        try w.qid(d.qid);
        try w.int(u32, d.mode);
        try w.int(u32, d.atime);
        try w.int(u32, d.mtime);
        try w.int(u64, d.length);
        for ([_][]const u8{ d.name, d.uid, d.gid, d.muid }) |s| try w.str(s);
        if (w.at - 2 > std.math.maxInt(u16)) return error.NoSpace;
        std.mem.writeInt(u16, out[0..2], @intCast(w.at - 2), .little);
        return out[0..w.at];
    }

    /// Parses one Dir from the start of `b`; returns it and its size.
    pub fn parse(b: []const u8) ?struct { Dir, usize } {
        if (b.len < 2) return null;
        const size = @as(usize, std.mem.readInt(u16, b[0..2], .little)) + 2;
        if (size > b.len) return null;
        var r: wire.Reader = .{ .b = b[2..size] };
        var d: Dir = .{};
        _ = r.int(u16) catch return null;
        _ = r.int(u32) catch return null;
        d.qid = r.qid() catch return null;
        d.mode = r.int(u32) catch return null;
        d.atime = r.int(u32) catch return null;
        d.mtime = r.int(u32) catch return null;
        d.length = r.int(u64) catch return null;
        d.name = r.str() catch return null;
        d.uid = r.str() catch return null;
        d.gid = r.str() catch return null;
        d.muid = r.str() catch "";
        return .{ d, size };
    }
};

test "pack and parse" {
    var buf: [128]u8 = undefined;
    const d: Dir = .{ .qid = .{ .type = 0x80, .path = 7 }, .mode = 0x800001ed, .name = "win", .uid = "ui", .gid = "ui" };
    const b = try d.pack(&buf);
    const p = Dir.parse(b).?;
    try std.testing.expectEqual(b.len, p[1]);
    try std.testing.expectEqualStrings("win", p[0].name);
    try std.testing.expectEqual(@as(u64, 7), p[0].qid.path);
}
