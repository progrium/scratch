//! Client paths (core.md § Paths) to what they name.
//!
//! Every path here is relative to `$ui`, with no leading slash:
//! `win/main/f/ok/label`, `keys`, `menu/bar`, `theme/tokens`. A window
//! directory is also its root node, so `win/main/style` is the root's
//! `style` and `win/main/title` the window's `title`, unless the root has a
//! child named `title`, which shadows it. `over` under a window is the
//! window's overlay directory, a node of kind `.over`. `@name` is the
//! unique descendant of the path so far with that name.

const std = @import("std");
const types = @import("../types/root.zig");
const proto = @import("../proto/root.zig");
const state = @import("state.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const Catalog = types.Catalog;
const State = state.State;
const Handle = state.Handle;
const Error = proto.Error;
const Diag = proto.Diag;

/// App-level directories.
pub const Dir = enum { root, menu, theme, asset, types, style, win, drag, clipdata, file };

/// App-level files.
pub const AppFile = enum {
    version,
    ctl,
    events,
    trace,
    keys,
    clip,
    theme_tokens,
    theme_name,
    theme_pref,
    theme_mode,
    style_words,
    /// `clipdata/types`.
    clip_types,
};

pub const Loc = union(enum) {
    dir: Dir,
    app: AppFile,
    /// `menu/NAME` (`bar` included), whether it exists or not.
    menu: []const u8,
    /// `asset/NAME`, whether it exists or not.
    asset: []const u8,
    /// `drag/N/`.
    drag: u64,
    /// `drag/N/types`.
    drag_types: u64,
    /// `drag/N/data/`.
    drag_data_dir: u64,
    /// `drag/N/data/TYPE`, whether it is written yet or not.
    drag_data: struct { n: u64, ty: []const u8 },
    /// `drag/N/item/`.
    drag_items: u64,
    /// `drag/N/item/I/`.
    drag_item: DragItem,
    /// `drag/N/item/I/file`.
    drag_item_file: DragItem,
    /// `clipdata/TYPE`, whether the clipboard holds it or not.
    clipdata: []const u8,
    type_dir: *const Type,
    /// `types/NAME/spec` or `types/NAME/version`.
    type_file: struct { ty: *const Type, name: []const u8 },
    /// A window's root, `over/`, or any node.
    node: Handle,
    /// One of a node's files. `name` is static: a catalog prop name or a
    /// common file name.
    file: struct { node: Handle, name: []const u8 },
    /// One of `state.window_files`, under the window with root `root`.
    win_file: struct { root: Handle, name: []const u8 },
};

pub const DragItem = struct { n: u64, i: usize };

pub const theme_files = [_][]const u8{ "tokens", "name", "pref", "mode" };

fn fail(d: ?*Diag, arena: Allocator, code: proto.Code, comptime fmt: []const u8, args: anytype) proto.err.ProtoError {
    return proto.err.fail(d, arena, code, fmt, args);
}

/// The static name of one of `node`'s files, or null if it has none
/// called `name`.
pub fn nodeFile(st: *const State, h: Handle, name: []const u8) ?[]const u8 {
    const n = st.node(h) orelse return null;
    if (n.kind == .over) {
        for ([_][]const u8{ "ctl", "events", "order", "tree" }) |f| if (std.mem.eql(u8, f, name)) return f;
        return null;
    }
    for (state.common_special) |f| if (std.mem.eql(u8, f, name)) return f;
    for (state.common_writable) |f| if (std.mem.eql(u8, f, name)) return f;
    if (n.ty.prop(name)) |p| return p.name;
    return null;
}

/// The window file `name` names (static), if it is one.
pub fn windowFile(name: []const u8) ?[]const u8 {
    for (state.window_files) |f| if (std.mem.eql(u8, f, name)) return f;
    return null;
}

/// Resolves a whole client path.
pub fn resolve(st: *const State, cat: *const Catalog, arena: Allocator, path_in: []const u8, d: ?*Diag) Error!Loc {
    const path = std.mem.trim(u8, path_in, "/");
    if (path.len == 0) return .{ .dir = .root };
    var it = std.mem.splitScalar(u8, path, '/');
    const first = it.next().?;
    const rest = it.rest();
    const nf = struct {
        fn f(dd: ?*Diag, a: Allocator, p: []const u8) proto.err.ProtoError {
            return fail(dd, a, .not_found, "{s}", .{p});
        }
    }.f;
    const one = rest.len == 0;
    const eq = std.mem.eql;
    if (eq(u8, first, "win")) {
        if (one) return .{ .dir = .win };
        return resolveWin(st, arena, rest, path, d);
    }
    if (one) {
        const app: ?AppFile = if (eq(u8, first, "version")) .version else if (eq(u8, first, "ctl")) .ctl else if (eq(u8, first, "events")) .events else if (eq(u8, first, "trace")) .trace else if (eq(u8, first, "keys")) .keys else if (eq(u8, first, "clip")) .clip else null;
        if (app) |a| return .{ .app = a };
        const dir: ?Dir = if (eq(u8, first, "menu")) .menu else if (eq(u8, first, "theme")) .theme else if (eq(u8, first, "asset")) .asset else if (eq(u8, first, "types")) .types else if (eq(u8, first, "style")) .style else if (eq(u8, first, "drag")) .drag else if (eq(u8, first, "clipdata")) .clipdata else if (eq(u8, first, "file")) .file else null;
        if (dir) |x| return .{ .dir = x };
        return nf(d, arena, path);
    }
    if (eq(u8, first, "menu")) {
        if (std.mem.indexOfScalar(u8, rest, '/') != null) return nf(d, arena, path);
        return .{ .menu = rest };
    }
    if (eq(u8, first, "asset")) {
        if (std.mem.indexOfScalar(u8, rest, '/') != null) return nf(d, arena, path);
        return .{ .asset = rest };
    }
    if (eq(u8, first, "theme")) {
        if (eq(u8, rest, "tokens")) return .{ .app = .theme_tokens };
        if (eq(u8, rest, "name")) return .{ .app = .theme_name };
        if (eq(u8, rest, "pref")) return .{ .app = .theme_pref };
        if (eq(u8, rest, "mode")) return .{ .app = .theme_mode };
        return nf(d, arena, path);
    }
    if (eq(u8, first, "style")) {
        if (eq(u8, rest, "words")) return .{ .app = .style_words };
        return nf(d, arena, path);
    }
    if (eq(u8, first, "types")) {
        var r = std.mem.splitScalar(u8, rest, '/');
        const name = r.next().?;
        const ty = cat.lookup(name) orelse return nf(d, arena, path);
        const f = r.next() orelse return .{ .type_dir = ty };
        if (r.next() != null) return nf(d, arena, path);
        if (eq(u8, f, "spec")) return .{ .type_file = .{ .ty = ty, .name = "spec" } };
        if (eq(u8, f, "version")) return .{ .type_file = .{ .ty = ty, .name = "version" } };
        return nf(d, arena, path);
    }
    if (eq(u8, first, "drag")) {
        var r = std.mem.splitScalar(u8, rest, '/');
        const n = std.fmt.parseInt(u64, r.next().?, 10) catch return nf(d, arena, path);
        const dg = st.drag(n) orelse return nf(d, arena, path);
        const f = r.next() orelse return .{ .drag = n };
        if (eq(u8, f, "types")) {
            if (r.next() != null) return nf(d, arena, path);
            return .{ .drag_types = n };
        }
        if (eq(u8, f, "data")) {
            const ty = r.next() orelse return .{ .drag_data_dir = n };
            if (r.next() != null or !typeId(ty)) return nf(d, arena, path);
            return .{ .drag_data = .{ .n = n, .ty = ty } };
        }
        if (eq(u8, f, "item")) {
            const is = r.next() orelse return .{ .drag_items = n };
            const i = std.fmt.parseInt(usize, is, 10) catch return nf(d, arena, path);
            if (i >= dg.offer.items.items.len) return nf(d, arena, path);
            const leaf = r.next() orelse return .{ .drag_item = .{ .n = n, .i = i } };
            if (r.next() != null or !eq(u8, leaf, "file")) return nf(d, arena, path);
            return .{ .drag_item_file = .{ .n = n, .i = i } };
        }
        return nf(d, arena, path);
    }
    if (eq(u8, first, "clipdata")) {
        if (std.mem.indexOfScalar(u8, rest, '/') != null) return nf(d, arena, path);
        if (eq(u8, rest, "types")) return .{ .app = .clip_types };
        if (!typeId(rest)) return nf(d, arena, path);
        return .{ .clipdata = rest };
    }
    return nf(d, arena, path);
}

/// A transfer type: lowercase letters, digits, `.` and `-` (transfer.md §
/// Types).
pub fn typeId(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| switch (c) {
        'a'...'z', '0'...'9', '.', '-' => {},
        else => return false,
    };
    return true;
}

/// `NAME[/rest]` under `win/`.
fn resolveWin(st: *const State, arena: Allocator, rel: []const u8, full: []const u8, d: ?*Diag) Error!Loc {
    const name, const rest = splitFirst(rel);
    const w = st.win(name) orelse return fail(d, arena, .not_found, "{s}", .{full});
    if (rest.len == 0) return .{ .node = w.root };
    // A window file, unless a child of the root shadows it.
    if (std.mem.indexOfScalar(u8, rest, '/') == null) {
        if (windowFile(rest)) |f| {
            const shadowed = state.inList(&state.shadowable, f) and st.child(w.root, f) != null;
            if (!shadowed) return .{ .win_file = .{ .root = w.root, .name = f } };
        }
    }
    return resolveUnder(st, arena, w.root, rest, full, d);
}

fn splitFirst(p: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, p, '/')) |i| return .{ p[0..i], p[i + 1 ..] };
    return .{ p, "" };
}

/// A path below node `base`: nodes, then perhaps one of the last node's
/// files.
pub fn resolveUnder(st: *const State, arena: Allocator, base: Handle, rel: []const u8, full: []const u8, d: ?*Diag) Error!Loc {
    var cur = base;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |el| {
        if (el.len == 0 or std.mem.eql(u8, el, ".")) continue;
        const last = it.peek() == null;
        if (step(st, arena, cur, el, d)) |h| {
            cur = h;
            continue;
        } else |e| {
            if (e != error.NotFound) return e;
            if (last) if (nodeFile(st, cur, el)) |f| return .{ .file = .{ .node = cur, .name = f } };
            return fail(d, arena, .not_found, "{s}", .{full});
        }
    }
    return .{ .node = cur };
}

/// One path element below `cur`: a child, or `@name`.
fn step(st: *const State, arena: Allocator, cur: Handle, el: []const u8, d: ?*Diag) Error!Handle {
    if (el[0] == '@' and el.len > 1) return findNamed(st, arena, cur, el[1..], d);
    return st.child(cur, el) orelse error.NotFound;
}

/// A node path relative to node `base` (`.` is `base`), as `set`, `new`,
/// `delete`, `focus=` and `anchor=` take it. No files.
pub fn resolveNode(st: *const State, arena: Allocator, base: Handle, rel_in: []const u8, d: ?*Diag) Error!Handle {
    const rel = std.mem.trim(u8, rel_in, " \t");
    var cur = base;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, rel, "/"), '/');
    while (it.next()) |el| {
        if (el.len == 0 or std.mem.eql(u8, el, ".")) continue;
        cur = step(st, arena, cur, el, d) catch |e| switch (e) {
            error.NotFound => return fail(d, arena, .not_found, "{s}", .{rel}),
            else => return e,
        };
    }
    return cur;
}

/// `win/NAME[/path]` on the app ctl: the window's root and the path below.
pub fn splitAppPath(p: []const u8) ?struct { win: []const u8, rel: []const u8 } {
    const t = std.mem.trim(u8, p, "/");
    if (!std.mem.startsWith(u8, t, "win/")) return null;
    const name, const rest = splitFirst(t[4..]);
    if (name.len == 0) return null;
    return .{ .win = name, .rel = rest };
}

/// The unique node named `name` below `scope`.
pub fn findNamed(st: *const State, arena: Allocator, scope: Handle, name: []const u8, d: ?*Diag) Error!Handle {
    var all: std.ArrayList(Handle) = .empty;
    try st.subtree(arena, scope, &all);
    var found: std.ArrayList(Handle) = .empty;
    for (all.items[1..]) |h| {
        const n = st.node(h).?;
        if (n.kind == .node and std.mem.eql(u8, n.nameStr(), name)) try found.append(arena, h);
    }
    switch (found.items.len) {
        1 => return found.items[0],
        0 => return fail(d, arena, .not_found, "@{s}", .{name}),
        else => {
            var aw: std.Io.Writer.Allocating = .init(arena);
            for (found.items, 0..) |h, i| {
                if (i > 0) aw.writer.writeAll(", ") catch return error.OutOfMemory;
                st.relPath(&aw.writer, h) catch return error.OutOfMemory;
            }
            return fail(d, arena, .in_use, "ambiguous: {s} ({s})", .{ name, aw.written() });
        },
    }
}

/// Splits a client path into the window it is in and the path below the
/// window, for error events: `win/main/a/text` is `a/text` with `main`.
pub fn eventPath(p: []const u8) struct { win: ?[]const u8, path: []const u8 } {
    if (splitAppPath(p)) |x| return .{ .win = x.win, .path = if (x.rel.len == 0) "." else x.rel };
    return .{ .win = null, .path = std.mem.trim(u8, p, "/") };
}
