//! The tree's storage. A `State` is one version of the whole app: nodes by
//! handle, windows, and the app-level files. A published State is never
//! changed again: an op copies it (`clone`, which copies maps of pointers),
//! changes the copy, and swaps it in only when the whole op succeeded. Nodes
//! and windows are reference counted and copied on first write in a copy
//! (`Tx.mutNode`), so an op costs what it touches plus one copy of the maps,
//! and older States (snapshots 9P readers hold, the frozen State of a batch)
//! keep sharing everything nobody changed.
//!
//! Reference counts are atomic: the owner thread makes and changes States,
//! but the last release of a snapshot can come from a 9P thread.

const std = @import("std");
const types = @import("../types/root.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;

pub const Handle = u32;

/// An immutable byte string shared between States.
pub const Blob = struct {
    rc: std.atomic.Value(u32) = .init(1),
    bytes: []u8,

    pub fn create(gpa: Allocator, s: []const u8) Allocator.Error!*Blob {
        const b = try gpa.create(Blob);
        errdefer gpa.destroy(b);
        b.* = .{ .bytes = try gpa.dupe(u8, s) };
        return b;
    }

    /// Takes ownership of `s`.
    pub fn own(gpa: Allocator, s: []u8) Allocator.Error!*Blob {
        const b = try gpa.create(Blob);
        b.* = .{ .bytes = s };
        return b;
    }

    pub fn ref(b: *Blob) *Blob {
        _ = b.rc.fetchAdd(1, .monotonic);
        return b;
    }

    pub fn unref(b: *Blob, gpa: Allocator) void {
        if (b.rc.fetchSub(1, .acq_rel) != 1) return;
        gpa.free(b.bytes);
        gpa.destroy(b);
    }

    pub fn str(b: ?*const Blob) []const u8 {
        return if (b) |x| x.bytes else "";
    }
};

pub fn refOpt(b: ?*Blob) ?*Blob {
    return if (b) |x| x.ref() else null;
}

pub fn unrefOpt(b: ?*Blob, gpa: Allocator) void {
    if (b) |x| x.unref(gpa);
}

/// One written node file. `name` is a catalog prop name or one of the
/// common file names, so it outlives every State.
pub const File = struct {
    name: []const u8,
    val: *Blob,
    /// The State generation that last wrote it (the 9P qid version).
    ver: u32,
    /// The order files were first written in, for printing documents.
    first: u32,
    /// The renderer wrote it (component state a `tree` rewrite keeps).
    mirrored: bool = false,
};

pub const NodeKind = enum { node, over };

/// A variant or size word on a node. `name` is the catalog's.
pub const NodeWord = struct { name: []const u8, kind: types.WordKind, first: u32 };

pub const Node = struct {
    rc: std.atomic.Value(u32) = .init(1),
    id: Handle,
    /// 0 for a window's root. A window's `over/` container has the root as
    /// its parent, but isn't one of its children.
    parent: Handle,
    /// The window's root node.
    root: Handle,
    kind: NodeKind = .node,
    name: *Blob,
    ty: *const Type,
    files: std.ArrayList(File) = .empty,
    /// Variant and size words. A new variant replaces the old one in
    /// place (its `first`), as does a new size.
    words: std.ArrayList(NodeWord) = .empty,
    /// Children in creation order.
    children: std.ArrayList(Handle) = .empty,
    /// What gets drawn, in order. `new` and `mkdir` append.
    order: std.ArrayList(Handle) = .empty,
    next_first: u32 = 0,
    /// Set when a frame showing the node was drawn: `type` can no longer
    /// change.
    fixed: bool = false,
    /// Bumped when the type, children, `order` or words change.
    ver: u32 = 0,

    pub fn nameStr(n: *const Node) []const u8 {
        return n.name.bytes;
    }

    pub fn file(n: *const Node, name: []const u8) ?*const File {
        for (n.files.items) |*f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    pub fn fileMut(n: *Node, name: []const u8) ?*File {
        for (n.files.items) |*f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    /// A file's stored bytes, or null when it was never written.
    pub fn stored(n: *const Node, name: []const u8) ?[]const u8 {
        return if (n.file(name)) |f| f.val.bytes else null;
    }

    /// A prop's value: as written, or its default, or empty.
    pub fn value(n: *const Node, name: []const u8) []const u8 {
        if (n.stored(name)) |v| return v;
        if (n.ty.prop(name)) |p| return p.default orelse "";
        return "";
    }

    /// A bool prop is on.
    pub fn isOn(n: *const Node, name: []const u8) bool {
        return std.mem.eql(u8, std.mem.trim(u8, n.value(name), " \t\r\n"), "on");
    }

    pub fn hasWord(n: *const Node, w: []const u8) bool {
        for (n.words.items) |x| if (std.mem.eql(u8, x.name, w)) return true;
        return false;
    }

    /// Sets a variant or size word, replacing the node's word of the same
    /// kind in place.
    pub fn setWord(n: *Node, gpa: Allocator, name: []const u8, kind: types.WordKind) Allocator.Error!void {
        for (n.words.items) |*x| if (x.kind == kind) {
            x.name = name;
            return;
        };
        try n.words.append(gpa, .{ .name = name, .kind = kind, .first = n.next_first });
        n.next_first += 1;
    }

    pub fn childIndex(list: []const Handle, h: Handle) ?usize {
        return std.mem.indexOfScalar(Handle, list, h);
    }

    /// A copy with its own lists, sharing the blobs.
    pub fn dupe(n: *const Node, gpa: Allocator) Allocator.Error!*Node {
        const c = try gpa.create(Node);
        errdefer gpa.destroy(c);
        c.* = n.*;
        c.rc = .init(1);
        c.files = .empty;
        c.words = .empty;
        c.children = .empty;
        c.order = .empty;
        errdefer c.freeLists(gpa);
        try c.files.appendSlice(gpa, n.files.items);
        try c.words.appendSlice(gpa, n.words.items);
        try c.children.appendSlice(gpa, n.children.items);
        try c.order.appendSlice(gpa, n.order.items);
        for (c.files.items) |f| _ = f.val.ref();
        _ = c.name.ref();
        return c;
    }

    fn freeLists(n: *Node, gpa: Allocator) void {
        n.files.deinit(gpa);
        n.words.deinit(gpa);
        n.children.deinit(gpa);
        n.order.deinit(gpa);
    }

    pub fn ref(n: *Node) *Node {
        _ = n.rc.fetchAdd(1, .monotonic);
        return n;
    }

    pub fn unref(n: *Node, gpa: Allocator) void {
        if (n.rc.fetchSub(1, .acq_rel) != 1) return;
        for (n.files.items) |f| f.val.unref(gpa);
        n.name.unref(gpa);
        n.freeLists(gpa);
        gpa.destroy(n);
    }

    /// Stores a file, keeping its first-write position. Takes `val`.
    pub fn putFile(n: *Node, gpa: Allocator, name: []const u8, val: *Blob, ver: u32) Allocator.Error!void {
        if (n.fileMut(name)) |f| {
            f.val.unref(gpa);
            f.val = val;
            f.ver = ver;
            f.mirrored = false;
            return;
        }
        try n.files.append(gpa, .{ .name = name, .val = val, .ver = ver, .first = n.next_first });
        n.next_first += 1;
    }

    pub fn dropFile(n: *Node, gpa: Allocator, name: []const u8) bool {
        for (n.files.items, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) {
            f.val.unref(gpa);
            _ = n.files.orderedRemove(i);
            return true;
        };
        return false;
    }
};

/// The window states core.md § Windows names; `hidden` until shown.
pub const WinState = enum { normal, min, max, full, hidden };

pub const WinAsk = enum { inherit, close, none };

/// A window prop (core.md § Windows): one of `win_props`, so the key
/// outlives every State.
pub const WinProp = struct { key: []const u8, val: *Blob };

pub const win_props = [_][]const u8{ "title", "size", "min", "max", "pos", "kind", "titlebar", "resizable" };

pub const Win = struct {
    rc: std.atomic.Value(u32) = .init(1),
    /// Unique for the life of the tree; a window made again with the same
    /// name gets a new one.
    id: u32,
    name: *Blob,
    root: Handle,
    over: Handle,
    title: ?*Blob = null,
    title_ver: u32 = 0,
    /// The props it was made or set with, except title (above).
    props: std.ArrayList(WinProp) = .empty,
    /// Made but not shown yet: until its root has content or `show`.
    hidden: bool = true,
    /// The default `main` window, made before the client ran, not yet
    /// claimed by a `window main`.
    default: bool = false,
    state: WinState = .normal,
    state_ver: u32 = 0,
    /// The focused node, 0 for none.
    focus: Handle = 0,
    focus_ver: u32 = 0,
    ask: WinAsk = .inherit,
    /// Open overlays, bottom first.
    open: std.ArrayList(Handle) = .empty,
    ver: u32 = 0,

    pub fn nameStr(w: *const Win) []const u8 {
        return w.name.bytes;
    }

    pub fn prop(w: *const Win, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "title")) return if (w.title) |t| t.bytes else null;
        for (w.props.items) |p| if (std.mem.eql(u8, p.key, key)) return p.val.bytes;
        return null;
    }

    /// The state a reader sees: `hidden` until the window is shown.
    pub fn shownState(w: *const Win) WinState {
        return if (w.hidden) .hidden else w.state;
    }

    pub fn dupe(w: *const Win, gpa: Allocator) Allocator.Error!*Win {
        const c = try gpa.create(Win);
        errdefer gpa.destroy(c);
        c.* = w.*;
        c.rc = .init(1);
        c.props = .empty;
        c.open = .empty;
        errdefer {
            c.props.deinit(gpa);
            c.open.deinit(gpa);
        }
        try c.props.appendSlice(gpa, w.props.items);
        try c.open.appendSlice(gpa, w.open.items);
        for (c.props.items) |p| _ = p.val.ref();
        _ = c.name.ref();
        _ = refOpt(c.title);
        return c;
    }

    pub fn ref(w: *Win) *Win {
        _ = w.rc.fetchAdd(1, .monotonic);
        return w;
    }

    pub fn unref(w: *Win, gpa: Allocator) void {
        if (w.rc.fetchSub(1, .acq_rel) != 1) return;
        for (w.props.items) |p| p.val.unref(gpa);
        w.props.deinit(gpa);
        w.open.deinit(gpa);
        w.name.unref(gpa);
        unrefOpt(w.title, gpa);
        gpa.destroy(w);
    }

    pub fn setProp(w: *Win, gpa: Allocator, key: []const u8, val: []const u8) Allocator.Error!void {
        const b = try Blob.create(gpa, val);
        if (std.mem.eql(u8, key, "title")) {
            unrefOpt(w.title, gpa);
            w.title = b;
            return;
        }
        const k = for (win_props) |p| {
            if (std.mem.eql(u8, p, key)) break p;
        } else unreachable;
        for (w.props.items) |*p| if (std.mem.eql(u8, p.key, k)) {
            p.val.unref(gpa);
            p.val = b;
            return;
        };
        w.props.append(gpa, .{ .key = k, .val = b }) catch |e| {
            b.unref(gpa);
            return e;
        };
    }
};

/// A named app file (`menu/NAME`, `asset/NAME`).
pub const Named = struct { name: *Blob, val: *Blob, ver: u32 };

/// One representation of an offer: a type and its bytes.
pub const Rep = struct { ty: *Blob, val: *Blob, ver: u32 };

/// Typed data (transfer.md): a drag's offer or the clipboard's contents.
/// Shared between States like a node; `dupe` before changing a shared one.
pub const Offer = struct {
    rc: std.atomic.Value(u32) = .init(1),
    /// The offered types, richest first. A client drag lists its
    /// `drag-types` here before it writes their bytes.
    types: std.ArrayList(*Blob) = .empty,
    /// The representations written so far.
    reps: std.ArrayList(Rep) = .empty,
    /// For type `file`: item N's handle, as `file/ID`.
    items: std.ArrayList(*Blob) = .empty,
    /// The handles this offer made (files.zig), released if it is refused.
    handles: std.ArrayList(u64) = .empty,

    pub fn create(gpa: Allocator) Allocator.Error!*Offer {
        const o = try gpa.create(Offer);
        o.* = .{};
        return o;
    }

    pub fn ref(o: *Offer) *Offer {
        _ = o.rc.fetchAdd(1, .monotonic);
        return o;
    }

    pub fn unref(o: *Offer, gpa: Allocator) void {
        if (o.rc.fetchSub(1, .acq_rel) != 1) return;
        o.freeParts(gpa);
        gpa.destroy(o);
    }

    fn freeParts(o: *Offer, gpa: Allocator) void {
        for (o.types.items) |b| b.unref(gpa);
        o.types.deinit(gpa);
        for (o.reps.items) |r| {
            r.ty.unref(gpa);
            r.val.unref(gpa);
        }
        o.reps.deinit(gpa);
        for (o.items.items) |b| b.unref(gpa);
        o.items.deinit(gpa);
        o.handles.deinit(gpa);
    }

    pub fn dupe(o: *const Offer, gpa: Allocator) Allocator.Error!*Offer {
        const c = try create(gpa);
        errdefer c.unref(gpa);
        try c.types.ensureTotalCapacity(gpa, o.types.items.len);
        for (o.types.items) |b| c.types.appendAssumeCapacity(b.ref());
        try c.reps.ensureTotalCapacity(gpa, o.reps.items.len);
        for (o.reps.items) |r| c.reps.appendAssumeCapacity(.{ .ty = r.ty.ref(), .val = r.val.ref(), .ver = r.ver });
        try c.items.ensureTotalCapacity(gpa, o.items.items.len);
        for (o.items.items) |b| c.items.appendAssumeCapacity(b.ref());
        try c.handles.appendSlice(gpa, o.handles.items);
        return c;
    }

    pub fn rep(o: *const Offer, ty: []const u8) ?*const Rep {
        for (o.reps.items) |*r| if (std.mem.eql(u8, r.ty.bytes, ty)) return r;
        return null;
    }

    pub fn hasType(o: *const Offer, ty: []const u8) bool {
        for (o.types.items) |b| if (std.mem.eql(u8, b.bytes, ty)) return true;
        return false;
    }

    /// Lists `ty`, if it isn't yet.
    pub fn addType(o: *Offer, gpa: Allocator, ty: []const u8) Allocator.Error!void {
        if (o.hasType(ty)) return;
        const b = try Blob.create(gpa, ty);
        o.types.append(gpa, b) catch |e| {
            b.unref(gpa);
            return e;
        };
    }

    /// Sets the bytes of type `ty`, listing it if needed.
    pub fn setRep(o: *Offer, gpa: Allocator, ty: []const u8, val: []const u8, ver: u32) Allocator.Error!void {
        try o.addType(gpa, ty);
        const b = try Blob.create(gpa, val);
        for (o.reps.items) |*r| if (std.mem.eql(u8, r.ty.bytes, ty)) {
            r.val.unref(gpa);
            r.val = b;
            r.ver = ver;
            return;
        };
        errdefer b.unref(gpa);
        const tb = try Blob.create(gpa, ty);
        o.reps.append(gpa, .{ .ty = tb, .val = b, .ver = ver }) catch |e| {
            tb.unref(gpa);
            return e;
        };
    }

    /// Adds item N's handle name, `file/ID`.
    pub fn addItem(o: *Offer, gpa: Allocator, id: u64) Allocator.Error!void {
        var buf: [32]u8 = undefined;
        const b = try Blob.create(gpa, std.fmt.bufPrint(&buf, "file/{d}", .{id}) catch unreachable);
        o.items.append(gpa, b) catch |e| {
            b.unref(gpa);
            return e;
        };
        try o.handles.append(gpa, id);
    }

    /// The `types` file: one type per line.
    pub fn writeTypes(o: *const Offer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (o.types.items) |b| try w.print("{s}\n", .{b.bytes});
    }
};

/// `drag/N/`: one drag's offer.
pub const Drag = struct {
    n: u64,
    offer: *Offer,
    ver: u32,
    /// The node a client-started drag came from; 0 for a host's drag.
    source: Handle = 0,
};

/// A theme token the client set (`theme/tokens`), on top of the catalog's.
pub const Token = struct { name: *Blob, val: *Blob };

pub const Pref = enum { system, light, dark };

/// The requests the client said it answers (`ask close quit open`).
pub const Asks = struct { close: bool = false, quit: bool = false, open: bool = false };

/// A child's key in `State.kids`: its parent and name. `name` points into
/// the child's name blob, which every copy of the child shares.
pub const Key = struct { parent: Handle, name: []const u8 };

const KeyCtx = struct {
    pub fn hash(_: KeyCtx, k: Key) u64 {
        var h = std.hash.Wyhash.init(k.parent);
        h.update(k.name);
        return h.final();
    }
    pub fn eql(_: KeyCtx, a: Key, b: Key) bool {
        return a.parent == b.parent and std.mem.eql(u8, a.name, b.name);
    }
};

pub const KidMap = std.HashMapUnmanaged(Key, Handle, KeyCtx, std.hash_map.default_max_load_percentage);

pub const State = struct {
    rc: std.atomic.Value(u32) = .init(1),
    /// Bumped once per applied op; file versions come from it.
    gen: u32 = 0,
    /// Handles are never reused: the next one to give out.
    next_handle: Handle = 1,
    next_win: u32 = 1,
    nodes: std.AutoHashMapUnmanaged(Handle, *Node) = .empty,
    kids: KidMap = .empty,
    /// In creation order.
    wins: std.ArrayList(*Win) = .empty,
    keys: ?*Blob = null,
    keys_ver: u32 = 0,
    /// `menu/bar`.
    bar: ?*Blob = null,
    bar_ver: u32 = 0,
    /// `menu/NAME`, in creation order.
    menus: std.ArrayList(Named) = .empty,
    assets: std.ArrayList(Named) = .empty,
    /// `clip`: the clipboard as text (transfer.md § Clipboard).
    clip: ?*Blob = null,
    clip_ver: u32 = 0,
    /// `clipdata/`: every representation; null until a typed copy.
    clipdata: ?*Offer = null,
    /// The clipboard's generation, bumped by every change.
    clip_gen: u64 = 0,
    drags: std.ArrayList(Drag) = .empty,
    tokens: std.ArrayList(Token) = .empty,
    tokens_ver: u32 = 0,
    pref: Pref = .system,
    system_dark: bool = false,
    theme_name: ?*Blob = null,
    /// What `theme_name` selected (catalog palettes, which outlive every
    /// State). Both null: the catalog's defaults.
    theme: types.ThemePick = .{},
    theme_ver: u32 = 0,
    asks: Asks = .{},
    /// The app quit: every later op fails with `app gone`.
    gone: bool = false,

    pub fn create(gpa: Allocator) Allocator.Error!*State {
        const s = try gpa.create(State);
        s.* = .{};
        return s;
    }

    pub fn ref(s: *State) *State {
        _ = s.rc.fetchAdd(1, .monotonic);
        return s;
    }

    pub fn unref(s: *State, gpa: Allocator) void {
        if (s.rc.fetchSub(1, .acq_rel) != 1) return;
        s.freeAll(gpa);
        gpa.destroy(s);
    }

    fn freeAll(s: *State, gpa: Allocator) void {
        var it = s.nodes.valueIterator();
        while (it.next()) |n| n.*.unref(gpa);
        s.nodes.deinit(gpa);
        s.kids.deinit(gpa);
        for (s.wins.items) |w| w.unref(gpa);
        s.wins.deinit(gpa);
        unrefOpt(s.keys, gpa);
        unrefOpt(s.bar, gpa);
        for (s.menus.items) |m| freeNamed(gpa, m);
        s.menus.deinit(gpa);
        for (s.assets.items) |m| freeNamed(gpa, m);
        s.assets.deinit(gpa);
        unrefOpt(s.clip, gpa);
        if (s.clipdata) |o| o.unref(gpa);
        for (s.drags.items) |d| d.offer.unref(gpa);
        s.drags.deinit(gpa);
        for (s.tokens.items) |t| {
            t.name.unref(gpa);
            t.val.unref(gpa);
        }
        s.tokens.deinit(gpa);
        unrefOpt(s.theme_name, gpa);
    }

    /// A private copy sharing every node, window and blob.
    pub fn clone(s: *const State, gpa: Allocator) Allocator.Error!*State {
        const c = try gpa.create(State);
        errdefer gpa.destroy(c);
        c.* = s.*;
        c.rc = .init(1);
        c.nodes = .empty;
        c.kids = .empty;
        c.wins = .empty;
        c.menus = .empty;
        c.assets = .empty;
        c.drags = .empty;
        c.tokens = .empty;
        // Refs first, so a failure below can free the copy like any State.
        _ = refOpt(c.keys);
        _ = refOpt(c.bar);
        _ = refOpt(c.clip);
        if (c.clipdata) |o| _ = o.ref();
        _ = refOpt(c.theme_name);
        errdefer c.freeAll(gpa);
        c.nodes = try s.nodes.clone(gpa);
        var it = c.nodes.valueIterator();
        while (it.next()) |n| _ = n.*.ref();
        c.kids = try s.kids.clone(gpa);
        try c.wins.ensureTotalCapacity(gpa, s.wins.items.len);
        for (s.wins.items) |w| c.wins.appendAssumeCapacity(w.ref());
        try c.menus.ensureTotalCapacity(gpa, s.menus.items.len);
        for (s.menus.items) |m| c.menus.appendAssumeCapacity(refNamed(m));
        try c.assets.ensureTotalCapacity(gpa, s.assets.items.len);
        for (s.assets.items) |m| c.assets.appendAssumeCapacity(refNamed(m));
        try c.drags.ensureTotalCapacity(gpa, s.drags.items.len);
        for (s.drags.items) |d| c.drags.appendAssumeCapacity(.{ .n = d.n, .offer = d.offer.ref(), .ver = d.ver, .source = d.source });
        try c.tokens.ensureTotalCapacity(gpa, s.tokens.items.len);
        for (s.tokens.items) |t| c.tokens.appendAssumeCapacity(.{ .name = t.name.ref(), .val = t.val.ref() });
        return c;
    }

    // ------------------------------------------------------------ lookups

    pub fn node(s: *const State, h: Handle) ?*Node {
        if (h == 0) return null;
        return s.nodes.get(h);
    }

    pub fn child(s: *const State, parent: Handle, name: []const u8) ?Handle {
        return s.kids.get(.{ .parent = parent, .name = name });
    }

    pub fn win(s: *const State, name: []const u8) ?*Win {
        for (s.wins.items) |w| if (std.mem.eql(u8, w.nameStr(), name)) return w;
        return null;
    }

    pub fn winIndex(s: *const State, name: []const u8) ?usize {
        for (s.wins.items, 0..) |w, i| if (std.mem.eql(u8, w.nameStr(), name)) return i;
        return null;
    }

    /// The window whose root is `root`.
    pub fn winOfRoot(s: *const State, root: Handle) ?*Win {
        for (s.wins.items) |w| if (w.root == root) return w;
        return null;
    }

    /// The window a node is in.
    pub fn winOf(s: *const State, h: Handle) ?*Win {
        const n = s.node(h) orelse return null;
        return s.winOfRoot(n.root);
    }

    pub fn menu(s: *const State, name: []const u8) ?*const Named {
        for (s.menus.items) |*m| if (std.mem.eql(u8, m.name.bytes, name)) return m;
        return null;
    }

    pub fn asset(s: *const State, name: []const u8) ?*const Named {
        for (s.assets.items) |*m| if (std.mem.eql(u8, m.name.bytes, name)) return m;
        return null;
    }

    pub fn drag(s: *const State, n: u64) ?*const Drag {
        for (s.drags.items) |*d| if (d.n == n) return d;
        return null;
    }

    pub fn token(s: *const State, name: []const u8) ?[]const u8 {
        for (s.tokens.items) |t| if (std.mem.eql(u8, t.name.bytes, name)) return t.val.bytes;
        return null;
    }

    /// The mode in effect: the preference's, unless the named theme has a
    /// palette only for the other mode.
    pub fn dark(s: *const State) bool {
        const want = switch (s.pref) {
            .system => s.system_dark,
            .light => false,
            .dark => true,
        };
        if (want and s.theme.dark == null and s.theme.light != null) return false;
        if (!want and s.theme.light == null and s.theme.dark != null) return true;
        return want;
    }

    /// The named theme drawn now, if any.
    pub fn palette(s: *const State) ?*const types.style.Theme {
        return if (s.dark()) s.theme.dark else s.theme.light;
    }

    /// A value token's value now (`radius`, `font-family`): the client's,
    /// then the named theme's, then the default.
    pub fn valueTokenValue(s: *const State, v: types.style.ValueToken) []const u8 {
        if (s.token(v.name)) |x| return x;
        if (s.palette()) |p| if (p.token(v.name)) |x| return x;
        return v.value;
    }

    /// A catalog token's value now: the client's `theme/tokens`, then the
    /// named theme's palette, then the catalog's default for the mode.
    pub fn tokenValue(s: *const State, t: types.style.Token) []const u8 {
        if (s.token(t.name)) |v| return v;
        const dk = s.dark();
        if (if (dk) s.theme.dark else s.theme.light) |p| if (p.token(t.name)) |v| return v;
        return if (dk) t.dark else t.light;
    }

    /// Whether `a` is `h` or one of its ancestors.
    pub fn isAncestor(s: *const State, a: Handle, h: Handle) bool {
        var cur = h;
        while (cur != 0) {
            if (cur == a) return true;
            const n = s.node(cur) orelse return false;
            cur = n.parent;
        }
        return false;
    }

    /// Depth below the window directory: the root is 0, `over` is 1.
    pub fn depth(s: *const State, h: Handle) usize {
        var d: usize = 0;
        var cur = h;
        while (s.node(cur)) |n| {
            if (n.parent == 0) break;
            d += 1;
            cur = n.parent;
        }
        return d;
    }

    /// The window-relative path of a node: `.` for the root, `f/ok` for a
    /// node in it, `over` and `over/x` for overlays.
    pub fn relPath(s: *const State, w: *std.Io.Writer, h: Handle) std.Io.Writer.Error!void {
        const n = s.node(h) orelse return;
        if (n.parent == 0) return w.writeAll(".");
        try s.relPathInner(w, h);
    }

    fn relPathInner(s: *const State, w: *std.Io.Writer, h: Handle) std.Io.Writer.Error!void {
        const n = s.node(h) orelse return;
        if (n.parent == 0) return;
        const p = s.node(n.parent).?;
        if (p.parent != 0) {
            try s.relPathInner(w, n.parent);
            try w.writeByte('/');
        }
        try w.writeAll(n.nameStr());
    }

    pub fn relPathAlloc(s: *const State, gpa: Allocator, h: Handle) Allocator.Error![]u8 {
        var a: std.Io.Writer.Allocating = .init(gpa);
        defer a.deinit();
        s.relPath(&a.writer, h) catch return error.OutOfMemory;
        return a.toOwnedSlice() catch error.OutOfMemory;
    }

    /// The path from `$ui`: `win/main` for a root, `win/main/f/ok`.
    pub fn fullPath(s: *const State, w: *std.Io.Writer, h: Handle) std.Io.Writer.Error!void {
        const n = s.node(h) orelse return;
        const win_ = s.winOfRoot(n.root) orelse return;
        try w.print("win/{s}", .{win_.nameStr()});
        if (n.parent == 0) return;
        try w.writeByte('/');
        try s.relPathInner(w, h);
    }

    /// The node and every descendant (overlays included for a root),
    /// parents first.
    pub fn subtree(s: *const State, gpa: Allocator, h: Handle, out: *std.ArrayList(Handle)) Allocator.Error!void {
        const n = s.node(h) orelse return;
        try out.append(gpa, h);
        for (n.children.items) |c| try s.subtree(gpa, c, out);
        if (n.parent == 0) {
            if (s.winOfRoot(h)) |w| if (w.over != 0 and w.over != h) try s.subtree(gpa, w.over, out);
        }
    }
};

fn refNamed(m: Named) Named {
    return .{ .name = m.name.ref(), .val = m.val.ref(), .ver = m.ver };
}

fn freeNamed(gpa: Allocator, m: Named) void {
    m.name.unref(gpa);
    m.val.unref(gpa);
}

// ---------------------------------------------------------------- files

/// Files every node has (core.md § Node files), beyond its type's props.
/// The writable ones hold text the tree checks; the rest are computed.
pub const common_writable = [_][]const u8{ "style", "tag", "on", "context", "tooltip", "drop", "drag-types" };
pub const common_special = [_][]const u8{ "type", "order", "ctl", "events", "tree", "bounds" };

/// Files under a window directory that are the window's (core.md § Windows).
pub const window_files = [_][]const u8{ "title", "bounds", "inner", "state", "focus" };
/// Window files a child of the root may shadow (core.md § Paths).
pub const shadowable = [_][]const u8{ "title", "state", "bounds", "focus" };

pub fn isCommon(name: []const u8) bool {
    return inList(&common_writable, name) or inList(&common_special, name);
}

pub fn commonName(name: []const u8) ?[]const u8 {
    for (common_writable) |c| if (std.mem.eql(u8, c, name)) return c;
    return null;
}

pub fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Child names that would hide a node file of a `ty` node, or (`over`) a
/// window's own directory.
pub fn isReserved(ty: *const Type, name: []const u8, is_root: bool) bool {
    if (isCommon(name)) return true;
    if (ty.prop(name) != null) return true;
    if (is_root and std.mem.eql(u8, name, "over")) return true;
    if (is_root and inList(&window_files, name) and !inList(&shadowable, name)) return true;
    return false;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (name[0] == '@') return false;
    for (name) |c| {
        if (c == '/' or c == '\'' or c < 0x20 or c == 0x7f or c == ' ' or c == '\t') return false;
    }
    return std.unicode.utf8ValidateSlice(name);
}

/// The type of a window's `over/` directory: not in the catalog, so no
/// client can make one.
pub const over_type: Type = .{ .name = "over", .tier = .element, .child = .any };

test "blob, node and state copies share and free" {
    const gpa = std.testing.allocator;
    const s = try State.create(gpa);
    defer s.unref(gpa);
    const n = try gpa.create(Node);
    n.* = .{ .id = 1, .parent = 0, .root = 1, .name = try Blob.create(gpa, "root"), .ty = &over_type };
    try n.putFile(gpa, "tag", try Blob.create(gpa, "x"), 1);
    try s.nodes.put(gpa, 1, n);
    const c = try s.clone(gpa);
    const d = try n.dupe(gpa);
    try d.putFile(gpa, "tag", try Blob.create(gpa, "y"), 2);
    c.nodes.getPtr(1).?.*.unref(gpa);
    c.nodes.getPtr(1).?.* = d;
    try std.testing.expectEqualStrings("x", s.node(1).?.value("tag"));
    try std.testing.expectEqualStrings("y", c.node(1).?.value("tag"));
    c.unref(gpa);
}
