//! Reading a node's `tree` file: the subtree as a document (core.md
//! § Documents). Writing one is `Tx.writeDoc` in tree.zig.
//!
//! The printed form is the one conformance README.md § Proposed pins:
//! `TYPE NAME`, then bare words (flags that are on, variant and size words)
//! in the order first set, then every other set prop as `prop=value` in the
//! order first set, then `: style`. Props at their default don't print;
//! data files do, as here-values. A window's root is named `root`.

const std = @import("std");
const proto = @import("../proto/root.zig");
const types = @import("../types/root.zig");
const state = @import("state.zig");

const Allocator = std.mem.Allocator;
const State = state.State;
const Node = state.Node;
const Handle = state.Handle;

/// Whether a prop's stored value is what it would read as unset.
pub fn isDefault(p: *const types.Prop, v: []const u8) bool {
    if (p.default) |d| return std.mem.eql(u8, d, v);
    if (p.form == .bool) return v.len == 0 or std.mem.eql(u8, v, "off");
    return v.len == 0;
}

/// Whether a bool prop set on prints as a bare word: the type takes it as
/// a flag word.
fn isFlag(ty: *const types.Type, name: []const u8) bool {
    const w = ty.word(name) orelse return false;
    return w.kind == .flag;
}

const Item = struct { first: u32, word: ?[]const u8 = null, attr: ?proto.Attr = null };

fn byFirst(_: void, a: Item, b: Item) bool {
    return a.first < b.first;
}

/// The document node for `h` and its subtree, in `arena`.
pub fn toDoc(arena: Allocator, st: *const State, h: Handle) Allocator.Error!proto.doc.Node {
    const n = st.node(h).?;
    var items: std.ArrayList(Item) = .empty;
    var style: ?[]const []const u8 = null;
    for (n.words.items) |w| try items.append(arena, .{ .first = w.first, .word = w.name });
    for (n.files.items) |f| {
        const v = f.val.bytes;
        if (std.mem.eql(u8, f.name, "style")) {
            var ws: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, v, " \t\r\n");
            while (it.next()) |x| try ws.append(arena, x);
            if (ws.items.len > 0) style = ws.items;
            continue;
        }
        if (state.commonName(f.name) != null) {
            if (v.len > 0) try items.append(arena, .{ .first = f.first, .attr = .{ .key = f.name, .value = v } });
            continue;
        }
        const p = n.ty.prop(f.name) orelse continue;
        if (p.readonly or isDefault(p, v)) continue;
        if (p.form == .bool and std.mem.eql(u8, v, "on") and isFlag(n.ty, f.name)) {
            try items.append(arena, .{ .first = f.first, .word = f.name });
        } else try items.append(arena, .{ .first = f.first, .attr = .{ .key = f.name, .value = v } });
    }
    std.mem.sort(Item, items.items, {}, byFirst);
    var words: std.ArrayList([]const u8) = .empty;
    var attrs: std.ArrayList(proto.Attr) = .empty;
    for (items.items) |x| {
        if (x.word) |w| try words.append(arena, w);
        if (x.attr) |a| try attrs.append(arena, a);
    }
    if (!std.mem.eql(Handle, n.order.items, n.children.items)) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        for (n.order.items, 0..) |c, i| {
            if (i > 0) aw.writer.writeByte(' ') catch return error.OutOfMemory;
            aw.writer.writeAll(st.node(c).?.nameStr()) catch return error.OutOfMemory;
        }
        try attrs.append(arena, .{ .key = "order", .value = aw.written() });
    }
    const kids = try arena.alloc(proto.doc.Node, n.children.items.len);
    for (n.children.items, kids) |c, *k| k.* = try toDoc(arena, st, c);
    return .{ .type = n.ty.name, .name = n.nameStr(), .words = words.items, .attrs = attrs.items, .style = style, .children = kids };
}

/// Writes the document for `h`'s subtree. `over/` prints each overlay in
/// turn.
pub fn print(w: *std.Io.Writer, arena: Allocator, st: *const State, h: Handle) (std.Io.Writer.Error || Allocator.Error)!void {
    const n = st.node(h) orelse return;
    if (n.kind == .over) {
        for (n.children.items) |c| try proto.doc.print(w, try toDoc(arena, st, c));
        return;
    }
    try proto.doc.print(w, try toDoc(arena, st, h));
}
