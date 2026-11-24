//! The renderer tree's conformance check (protocols/render.md § Prototype
//! plan): encode every pump of a live tree, apply the stream to an empty
//! replica, and at the end compare the two as documents. Any encoding bug,
//! a record left out or a value spelled wrong, shows up as a difference.
//! `uitree-headless --check-render` runs it under every conformance script.

const std = @import("std");
const abi = @import("../abi.zig");
const types = @import("../types/root.zig");
const treem = @import("../tree/root.zig");
const stream = @import("stream.zig");
const replica = @import("replica.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const State = treem.state.State;
const Blob = treem.state.Blob;

pub const Checker = struct {
    gpa: Allocator,
    cat: *const types.Catalog,
    t: *treem.Tree,
    rep: replica.Replica,
    enc: stream.Encoder,
    started: bool = false,
    /// Stream bytes, for a report.
    bytes: u64 = 0,
    io: std.Io,
    /// $UITREE_RENDER_DUMP: a file to write the stream to.
    dump: ?std.Io.File = null,

    /// A replica over `cat`, the live tree's catalog.
    pub fn create(gpa: Allocator, io: std.Io, cat: *const types.Catalog) !*Checker {
        const k = try gpa.create(Checker);
        errdefer gpa.destroy(k);
        const t = try treem.Tree.create(gpa, io, cat, .{ .host = "uitree-replica" });
        k.* = .{ .gpa = gpa, .io = io, .cat = cat, .t = t, .rep = .{ .gpa = gpa, .t = t }, .enc = .{ .gpa = gpa } };
        if (std.c.getenv("UITREE_RENDER_DUMP")) |p| k.dump = std.Io.Dir.cwd().createFile(io, std.mem.span(p), .{}) catch null;
        return k;
    }

    pub fn destroy(k: *Checker) void {
        if (k.dump) |f| f.close(k.io);
        k.rep.deinit();
        k.enc.deinit();
        k.t.destroy();
        k.gpa.destroy(k);
    }

    /// After a pump of the live tree, before its changes are cleared: the
    /// first is a snapshot, the rest batches, as a renderer that attached
    /// at the start would get them.
    pub fn pump(k: *Checker, st: *const State, ch: treem.Changes) !void {
        var arena: std.heap.ArenaAllocator = .init(k.gpa);
        defer arena.deinit();
        var uch: abi.UitChanges = .{};
        try abi.fill(arena.allocator(), ch, &uch);
        var aw: Writer.Allocating = .init(k.gpa);
        defer aw.deinit();
        const src: stream.Source = .{ .st = st, .cat = k.cat };
        k.enc.seq += 1;
        if (!k.started) {
            try k.enc.snapshot(src, &aw.writer);
            k.started = true;
        } else _ = try k.enc.batch(src, &uch, 0, &aw.writer);
        if (k.dump) |f| f.writePositionalAll(k.io, aw.written(), k.bytes) catch {};
        k.bytes += aw.written().len;
        try k.rep.feed(aw.written());
        k.t.publish() catch {};
        k.t.clearChanges();
    }

    /// Compares the replica with `live`; writes each difference to `w`.
    /// True when they agree.
    pub fn compare(k: *Checker, live: *const State, w: *Writer) !bool {
        var arena: std.heap.ArenaAllocator = .init(k.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const rs = k.t.current();
        var ok = true;
        if (k.rep.errors.items.len > 0) {
            ok = false;
            try w.writeAll("replica writes refused:\n");
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, k.rep.errors.items, "\n"), '\n');
            while (it.next()) |l| try w.print("  {s}\n", .{l});
        }
        for (live.wins.items) |lw| {
            if (lw.hidden) continue;
            const name = lw.nameStr();
            const rw = rs.win(name) orelse {
                try w.print("win/{s}: missing\n", .{name});
                ok = false;
                continue;
            };
            ok = try same(w, try std.fmt.allocPrint(a, "win/{s}/tree", .{name}), try doc(a, live, lw.root), try doc(a, rs, rw.root)) and ok;
            if (lw.over != 0 or rw.over != 0)
                ok = try same(w, try std.fmt.allocPrint(a, "win/{s}/over/tree", .{name}), try doc(a, live, lw.over), try doc(a, rs, rw.over)) and ok;
            ok = try same(w, try std.fmt.allocPrint(a, "win/{s}/focus", .{name}), try focus(a, live, lw), try focus(a, rs, rw)) and ok;
            ok = try same(w, try std.fmt.allocPrint(a, "win/{s}/title", .{name}), if (lw.title) |x| x.bytes else "", if (rw.title) |x| x.bytes else "") and ok;
        }
        ok = try same(w, "keys", Blob.str(live.keys), Blob.str(rs.keys)) and ok;
        ok = try same(w, "menu/bar", Blob.str(live.bar), Blob.str(rs.bar)) and ok;
        for (live.menus.items) |m| {
            const r = rs.menu(m.name.bytes);
            ok = try same(w, try std.fmt.allocPrint(a, "menu/{s}", .{m.name.bytes}), m.val.bytes, if (r) |x| x.val.bytes else "") and ok;
        }
        ok = try same(w, "theme/name", Blob.str(live.theme_name), Blob.str(rs.theme_name)) and ok;
        ok = try same(w, "theme/mode", if (live.dark()) "dark" else "light", if (rs.dark()) "dark" else "light") and ok;
        return ok;
    }
};

fn doc(a: Allocator, st: *const State, h: treem.Handle) ![]const u8 {
    if (h == 0) return "";
    var aw: Writer.Allocating = .init(a);
    try treem.doc.print(&aw.writer, a, st, h);
    return aw.written();
}

fn focus(a: Allocator, st: *const State, w: *const treem.state.Win) ![]const u8 {
    if (w.focus == 0) return "";
    return st.relPathAlloc(a, w.focus);
}

fn same(w: *Writer, what: []const u8, live: []const u8, rep: []const u8) !bool {
    if (std.mem.eql(u8, live, rep)) return true;
    try w.print("{s} differs\n--- live\n{s}\n--- replica\n{s}\n", .{ what, live, rep });
    return false;
}
