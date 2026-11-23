//! The tree (interface I4): applying ops all or nothing, windows, ctl
//! verbs, documents, events, requests, batches and the changes a renderer
//! pumps.
//!
//! An op runs against a private copy of the current `State` (a `Tx`, with
//! an arena that dies with the op) and replaces it only when every line of
//! it succeeded, so a failed op changes nothing. Paths are client paths
//! from `$ui` (`win/main/f/ok/label`, `keys`, `theme/tokens`), and every
//! error's detail uses them.
//!
//! Choices the spec leaves to the host (conformance GAPS.md has the ones
//! the goldens pin):
//!
//! - Every one-line file (props, `type`, `order`, `tag`, `style`, `on`,
//!   window files, `theme/pref`, `theme/mode`) stores what was written less
//!   one trailing newline, and reads back with one. Data files follow the
//!   same rule. `bytes` props, `clip` and assets keep their bytes.
//! - A bare word naming a bool prop (`secret`, `stripe`) sets it on; a
//!   variant or size word replaces the node's earlier one in place.
//! - Batches belong to a session and freeze every window; `abort` puts the
//!   whole app back as it was at `begin`.
//! - A `tree` rewrite keeps a child whose name and type match. A prop the
//!   document leaves out goes back to its default, except `value`-like
//!   state props and files the renderer mirrored.
//! - The clock is the caller's: `tick(now_ns)` and `advanceClock`. Nothing
//!   here reads the wall clock, so headless can fake it.

const std = @import("std");
const proto = @import("../proto/root.zig");
const types = @import("../types/root.zig");
const state = @import("state.zig");
const bus_mod = @import("bus.zig");
const pathm = @import("path.zig");
const trace = @import("trace.zig");
const doc = @import("doc.zig");
const filesm = @import("files.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Catalog = types.Catalog;
const Type = types.Type;
const State = state.State;
const Node = state.Node;
const Win = state.Win;
const Blob = state.Blob;
const Bus = bus_mod.Bus;
const Attr = proto.Attr;
const Ctl = proto.Ctl;
const Loc = pathm.Loc;

pub const Handle = state.Handle;
pub const Code = proto.Code;
pub const Error = proto.Error;
pub const EventKind = types.EventKind;

/// A 9P connection, or another source of ops. Batches belong to one.
pub const Session = u32;

pub const ns_per_s: u64 = std.time.ns_per_s;
/// A batch left open this long is committed (core.md § Batches).
pub const batch_timeout_ns: u64 = 2 * ns_per_s;
/// A request unanswered this long gets its default (core.md § Requests).
pub const request_timeout_ns: u64 = 5 * ns_per_s;
pub const max_depth = proto.limits.node_depth;

/// Event names that are state events whatever the type says (core.md § Two
/// kinds of event).
pub const state_events = [_][]const u8{ "change", "select", "cursor", "resize", "layout", "move", "scroll", "hover", "focus", "blur", "state", "theme" };

/// Props holding component state: a `tree` rewrite that keeps the node
/// keeps them unless the document names them.
pub const state_props = [_][]const u8{ "value", "selection", "expanded", "layout", "open", "collapsed", "page", "query", "sizes", "checked" };

/// Window placement hints `pos=` takes besides `x,y`.
pub const pos_hints = [_][]const u8{ "center", "top-left", "top-right", "bottom-left", "bottom-right", "tray" };

/// The modifiers a keystroke takes (core.md § Keys, actions and menus).
pub const modifiers = [_][]const u8{ "cmd", "ctrl", "alt", "shift", "super", "fn" };

/// One op, as a 9P server or the renderer queues it. Every slice is
/// borrowed for the call.
pub const Op = union(enum) {
    /// A whole file write: a `ctl` write, or a text or data file at clunk.
    write: FileOp,
    /// Adds to the end of a file (a write at an offset past the start).
    append: FileOp,
    mkdir: PathOp,
    remove: PathOp,
    /// The connection went away: its batch is aborted.
    session_closed: Session,

    pub const FileOp = struct {
        session: Session = 0,
        path: []const u8,
        data: []const u8,
        /// The node the file was opened under, or 0. If it was removed
        /// since (even if the path names a new node now), the write fails
        /// with `gone` (conformance 23-errors).
        node: Handle = 0,
    };
    pub const PathOp = struct { session: Session = 0, path: []const u8 };
};

/// Tags match uitcore.h's UIT_CMD_*.
pub const CmdTag = enum(u32) {
    window = 1,
    window_ctl = 2,
    quit = 3,
    menus = 4,
    keymap = 5,
    theme = 6,
    set_action = 7,
    overlay = 8,
    focus = 9,
    clipboard = 10,
    component_verb = 11,
    answer = 12,
    redraw = 13,
    theme_load = 14,
    /// An `asset/NAME` was written or removed: re-read it with uit_asset.
    assets = 15,
};

/// A command for the renderer (uitcore.h's UitHostCmd). Which fields are
/// set depends on `tag`; strings live until `clearChanges`.
pub const HostCmd = struct {
    tag: CmdTag,
    win: []const u8 = "",
    node: Handle = 0,
    name: []const u8 = "",
    ctl: Ctl = .{ .verb = "" },
    seq: u64 = 0,
    flag: i32 = 0,
    flag2: i32 = 0,
    answer: []const u8 = "",
};

pub const PropChange = struct { node: Handle, file: []const u8 };

/// What changed since the last `clearChanges` (uitcore.h's UitChanges).
pub const Changes = struct {
    dirty: []const []const u8 = &.{},
    created: []const Handle = &.{},
    removed: []const Handle = &.{},
    props: []const PropChange = &.{},
    cmds: []const HostCmd = &.{},
};

/// An event from the UI, or an echo. See `Tree.emit`.
pub const EventIn = struct {
    name: []const u8,
    /// The node it is about: a window's root for the window itself, 0 for
    /// an app-level event.
    node: Handle = 0,
    /// Null: the type's descriptor says, else `state_events`, else action.
    kind: ?EventKind = null,
    /// The routing word; null takes the node's inherited tag.
    key: ?[]const u8 = null,
    /// The head's path when `node` is 0 (`error - theme/tokens`), with
    /// `win` for a window-relative one.
    path: ?[]const u8 = null,
    win: ?[]const u8 = null,
    attrs: []const Attr = &.{},
    via: ?[]const u8 = null,
};

/// What readers on other threads see live, outside the snapshot.
pub const Shared = struct {
    mu: Io.Mutex = .init,
    /// `x y w h` from the last layout, by node (a window's root: the
    /// window's).
    bounds: std.AutoHashMapUnmanaged(Handle, [4]i64) = .empty,

    pub fn get(s: *Shared, io: Io, h: Handle) ?[4]i64 {
        s.mu.lockUncancelable(io);
        defer s.mu.unlock(io);
        return s.bounds.get(h);
    }
};

const Batch = struct {
    session: Session,
    frozen: *State,
    started: u64,
};

const Request = struct {
    seq: u64,
    /// The node whose ctl answers it (a window's root for a window
    /// request); 0 for the app ctl.
    target: Handle,
    default: []const u8,
    deadline: u64,
    drag: ?u64 = null,
    /// A window close: answering `close` removes the window.
    closes: Handle = 0,
    /// A dialog close: answering `close` closes the overlay.
    overlay: Handle = 0,
    /// Any other node's close (a tab, a dock panel): answering `close`
    /// removes the node.
    removes: Handle = 0,
};

/// Changes since the last `clearChanges`.
const Log = struct {
    arena: std.heap.ArenaAllocator,
    dirty: std.ArrayList([]const u8) = .empty,
    created: std.ArrayList(Handle) = .empty,
    removed: std.ArrayList(Handle) = .empty,
    props: std.ArrayList(PropChange) = .empty,
    cmds: std.ArrayList(HostCmd) = .empty,
    /// Created and removed in the same pump: neither.
    view_created: std.ArrayList(Handle) = .empty,
    view_removed: std.ArrayList(Handle) = .empty,
};

pub const Config = struct {
    /// `version`'s `cmdkey`: `cmd`, `ctrl` or `super`.
    cmdkey: []const u8 = "ctrl",
    host: []const u8 = "uitree-core 0.2",
    system_dark: bool = false,
    /// Where loud errors go (`uitree: write PATH: ...`), besides trace and
    /// the `error` event. Null: nowhere.
    stderr: ?*Writer = null,
};

pub const Tree = struct {
    gpa: Allocator,
    io: Io,
    cat: *const Catalog,
    cfg: Config,
    st: *State,
    bus: Bus,
    /// In `mirror`: changes aren't reported in `changes().props`.
    mirroring: bool = false,
    /// Actions `set ID enabled=off` turned off: their bindings send
    /// nothing (core.md § Keys, actions and menus).
    disabled: std.StringHashMapUnmanaged(void) = .empty,
    shared: Shared = .{},
    batches: std.ArrayList(Batch) = .empty,
    requests: std.ArrayList(Request) = .empty,
    log: Log,
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,
    /// The clock the caller last gave `tick`, plus every `advanceClock`.
    now_ns: u64 = 0,
    skew_ns: u64 = 0,
    /// The snapshot 9P readers get, and its lock.
    snap: ?*Snapshot = null,
    snap_mu: Io.Mutex = .init,
    /// File handles, `$ui/file/ID/` (transfer.md § Host files). Not tree
    /// state: 9P threads read them directly.
    files: filesm.Files,
    /// The next drag number the tree gives out.
    next_drag: u64 = 1,
    /// The `op=` a drop's target accepted with, by drag, for `dragend`.
    drag_ops: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,

    /// A tree with the default `main` window, hidden. The tree must not
    /// move: streams point at its bus.
    pub fn create(gpa: Allocator, io: Io, cat: *const Catalog, cfg: Config) Error!*Tree {
        const t = try gpa.create(Tree);
        errdefer gpa.destroy(t);
        t.* = .{
            .gpa = gpa,
            .io = io,
            .cat = cat,
            .cfg = cfg,
            .st = try State.create(gpa),
            .bus = .init(gpa, io),
            .log = .{ .arena = .init(gpa) },
            .files = .init(gpa, io),
        };
        t.st.system_dark = cfg.system_dark;
        errdefer t.destroyParts();
        try t.defaultWindow();
        t.clearChanges();
        try t.publish();
        return t;
    }

    fn destroyParts(t: *Tree) void {
        if (t.snap) |s| s.release();
        t.snap = null;
        for (t.batches.items) |b| b.frozen.unref(t.gpa);
        t.batches.deinit(t.gpa);
        for (t.requests.items) |r| t.gpa.free(r.default);
        t.requests.deinit(t.gpa);
        t.st.unref(t.gpa);
        t.bus.deinit();
        t.shared.bounds.deinit(t.gpa);
        t.log.arena.deinit();
        t.files.deinit();
        t.drag_ops.deinit(t.gpa);
    }

    /// Frees the tree. Every snapshot must be released and every stream
    /// closed first.
    pub fn destroy(t: *Tree) void {
        var it = t.disabled.keyIterator();
        while (it.next()) |k| t.gpa.free(k.*);
        t.disabled.deinit(t.gpa);
        t.destroyParts();
        t.gpa.destroy(t);
    }

    fn defaultWindow(t: *Tree) Error!void {
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        var d: proto.Diag = .{};
        const st = try t.st.clone(t.gpa);
        var tx: Tx = .{ .t = t, .a = arena.allocator(), .st = st, .d = &d, .session = 0, .gen = st.gen +% 1 };
        st.gen = tx.gen;
        tx.makeWindow("main", &.{}) catch |e| {
            tx.st.unref(t.gpa);
            return e;
        };
        const w = tx.st.win("main").?;
        w.default = true;
        const old = t.st;
        t.st = tx.st;
        defer old.unref(t.gpa);
        var it = t.st.nodes.keyIterator();
        while (it.next()) |h| try t.bus.addLive(h.*);
    }

    // ------------------------------------------------------------ ops

    /// Applies one op whole or not at all. A failed write is loud: a line
    /// on `cfg.stderr`, an `error` trace line and an `error` event; its
    /// text is `lastError()`.
    pub fn apply(t: *Tree, op: Op) Error!void {
        t.err_len = 0;
        if (t.st.gone) return t.setErr(.app_gone, "");
        if (op == .session_closed) return t.closeSession(op.session_closed);
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        var d: proto.Diag = .{};
        const st = try t.st.clone(t.gpa);
        var tx: Tx = .{ .t = t, .a = arena.allocator(), .st = st, .d = &d, .session = 0, .gen = st.gen +% 1 };
        st.gen = tx.gen;
        const verb: []const u8, const p: []const u8 = switch (op) {
            .write, .append => |f| .{ "write", f.path },
            .mkdir => |f| .{ "mkdir", f.path },
            .remove => |f| .{ "remove", f.path },
            .session_closed => unreachable,
        };
        const r = switch (op) {
            .write => |f| blk: {
                tx.session = f.session;
                if (f.node != 0 and st.node(f.node) == null) break :blk tx.fail(.gone, "{s}", .{f.path});
                break :blk tx.write(f.path, f.data, false);
            },
            .append => |f| blk: {
                tx.session = f.session;
                if (f.node != 0 and st.node(f.node) == null) break :blk tx.fail(.gone, "{s}", .{f.path});
                break :blk tx.write(f.path, f.data, true);
            },
            .mkdir => |f| blk: {
                tx.session = f.session;
                break :blk tx.mkdir(f.path);
            },
            .remove => |f| blk: {
                tx.session = f.session;
                break :blk tx.remove(f.path);
            },
            .session_closed => unreachable,
        };
        r catch |e| {
            tx.st.unref(t.gpa);
            if (e == error.OutOfMemory) return e;
            const code = Code.fromError(e) orelse .bad_value;
            t.loud(verb, p, code, d.detail);
            return e;
        };
        tx.showReady() catch |e| {
            tx.st.unref(t.gpa);
            return e;
        };
        try t.commit(&tx);
    }

    /// The text of the last failed `apply`: `phrase` or `phrase: detail`.
    pub fn lastError(t: *const Tree) []const u8 {
        return t.err_buf[0..t.err_len];
    }

    fn setErr(t: *Tree, code: Code, detail: []const u8) Error {
        t.noteErr(code, detail);
        return code.err();
    }

    fn noteErr(t: *Tree, code: Code, detail: []const u8) void {
        var w: Writer = .fixed(&t.err_buf);
        proto.err.format(&w, code, detail) catch {};
        t.err_len = w.end;
    }

    /// core.md § Errors: standard error, trace, and an `error` event.
    fn loud(t: *Tree, verb: []const u8, p_in: []const u8, code: Code, detail: []const u8) void {
        t.noteErr(code, detail);
        const p = std.mem.trim(u8, p_in, "/");
        if (t.cfg.stderr) |w| {
            w.print("uitree: {s} {s}: {s}\n", .{ verb, p, t.lastError() }) catch {};
            w.flush() catch {};
        }
        var buf: [1024]u8 = undefined;
        var w: Writer = .fixed(&buf);
        trace.err(&w, p, code, detail) catch {};
        t.traceLine(w.buffered());
        const ep = pathm.eventPath(p);
        _ = t.emit(.{
            .name = "error",
            .kind = .action,
            .path = ep.path,
            .win = ep.win,
            .key = "-",
            .attrs = &.{.{ .key = "code", .value = code.name() }},
        }) catch {};
    }

    fn traceLine(t: *Tree, line: []const u8) void {
        t.bus.deliverTrace(line) catch {};
    }

    /// Swaps in a successful op's state and hands out what it did.
    fn commit(t: *Tree, tx: *Tx) Error!void {
        const old = t.st;
        t.st = tx.st;
        defer old.unref(t.gpa);
        for (tx.answered.items) |seq| t.dropRequest(seq);
        var ended: ?*State = null;
        defer if (ended) |f| f.unref(t.gpa);
        for (tx.batch_ops.items) |b| switch (b) {
            .begin => {
                try t.batches.append(t.gpa, .{ .session = tx.session, .frozen = old.ref(), .started = t.now() });
            },
            .end => {
                for (t.batches.items, 0..) |x, i| if (x.session == tx.session) {
                    if (ended) |f| f.unref(t.gpa);
                    ended = x.frozen;
                    _ = t.batches.orderedRemove(i);
                    break;
                };
            },
        };
        for (tx.trace.items) |l| t.traceLine(l);
        try t.diff(old, t.st, false);
        for (tx.cmds.items) |c| {
            if (c.tag == .set_action and c.flag != -1) try t.setEnabled(c.name, c.flag == 1);
            try t.pushCmd(c);
        }
        if (ended) |f| try t.batchEnded(f);
        for (tx.events.items) |ev| {
            if (ev.request) |dflt| {
                _ = try t.request(ev.ev, dflt);
            } else _ = try t.emit(ev.ev);
        }
        if (tx.quit) {
            t.st.gone = true;
            t.bus.shutDown();
        }
    }

    /// A batch ended: redraw every window, and hand the renderer every prop
    /// that differs from what it drew while the batch was open.
    fn batchEnded(t: *Tree, frozen: *State) Error!void {
        if (t.batches.items.len > 0) return;
        try t.diff(frozen, t.st, true);
        for (t.st.wins.items) |w| if (!w.hidden) {
            try t.pushCmd(.{ .tag = .redraw, .win = w.nameStr() });
            try t.addDirty(w.nameStr());
        };
    }

    fn closeSession(t: *Tree, s: Session) Error!void {
        var i: usize = 0;
        while (i < t.batches.items.len) {
            const b = t.batches.items[i];
            if (b.session != s) {
                i += 1;
                continue;
            }
            _ = t.batches.orderedRemove(i);
            defer b.frozen.unref(t.gpa);
            const restored = try b.frozen.clone(t.gpa);
            restored.gen = t.st.gen +% 1;
            const old = t.st;
            t.st = restored;
            defer old.unref(t.gpa);
            try t.diff(old, t.st, false);
            if (t.batches.items.len == 0) for (t.st.wins.items) |w| if (!w.hidden) {
                try t.pushCmd(.{ .tag = .redraw, .win = w.nameStr() });
            };
        }
    }

    pub fn now(t: *const Tree) u64 {
        return t.now_ns + t.skew_ns;
    }

    /// Moves the tree's clock forward by `d` and runs what falls due.
    pub fn advanceClock(t: *Tree, d: u64) Error!void {
        t.skew_ns += d;
        try t.runTimers();
    }

    /// The caller's clock (any monotonic nanoseconds): batch and request
    /// timeouts that fall due run now.
    pub fn tick(t: *Tree, now_ns: u64) Error!void {
        if (now_ns > t.now_ns) t.now_ns = now_ns;
        try t.runTimers();
    }

    fn runTimers(t: *Tree) Error!void {
        const n = t.now();
        var i: usize = 0;
        while (i < t.requests.items.len) {
            const r = t.requests.items[i];
            if (r.deadline > n) {
                i += 1;
                continue;
            }
            _ = t.requests.orderedRemove(i);
            defer t.gpa.free(r.default);
            try t.resolveDefault(r);
        }
        i = 0;
        while (i < t.batches.items.len) {
            const b = t.batches.items[i];
            if (b.started + batch_timeout_ns > n) {
                i += 1;
                continue;
            }
            _ = t.batches.orderedRemove(i);
            defer b.frozen.unref(t.gpa);
            t.traceLine("batch timeout");
            try t.batchEnded(b.frozen);
        }
    }

    // ------------------------------------------------------------ changes

    /// What changed since the last `clearChanges`. Slices live until then.
    pub fn changes(t: *Tree) Error!Changes {
        const a = t.log.arena.allocator();
        const l = &t.log;
        l.view_created.clearRetainingCapacity();
        l.view_removed.clearRetainingCapacity();
        for (l.created.items) |h| if (std.mem.indexOfScalar(Handle, l.removed.items, h) == null) try l.view_created.append(a, h);
        for (l.removed.items) |h| if (std.mem.indexOfScalar(Handle, l.created.items, h) == null) try l.view_removed.append(a, h);
        std.mem.sort(Handle, l.view_created.items, {}, std.sort.asc(Handle));
        std.mem.sort(Handle, l.view_removed.items, {}, std.sort.asc(Handle));
        var dirty: std.ArrayList([]const u8) = .empty;
        for (l.dirty.items) |w| if (t.st.win(w) != null) try dirty.append(a, w);
        var props: std.ArrayList(PropChange) = .empty;
        for (l.props.items) |p| if (t.st.node(p.node) != null) try props.append(a, p);
        return .{
            .dirty = dirty.items,
            .created = l.view_created.items,
            .removed = l.view_removed.items,
            .props = props.items,
            .cmds = l.cmds.items,
        };
    }

    pub fn clearChanges(t: *Tree) void {
        _ = t.log.arena.reset(.retain_capacity);
        t.log = .{ .arena = t.log.arena };
    }

    fn addDirty(t: *Tree, w: []const u8) Error!void {
        if (t.batches.items.len > 0) return;
        for (t.log.dirty.items) |x| if (std.mem.eql(u8, x, w)) return;
        const a = t.log.arena.allocator();
        try t.log.dirty.append(a, try a.dupe(u8, w));
    }

    fn setEnabled(t: *Tree, id: []const u8, on: bool) Error!void {
        if (on) {
            if (t.disabled.fetchRemove(id)) |kv| t.gpa.free(kv.key);
        } else if (!t.disabled.contains(id)) {
            const k = try t.gpa.dupe(u8, id);
            errdefer t.gpa.free(k);
            try t.disabled.put(t.gpa, k, {});
        }
    }

    fn addProp(t: *Tree, h: Handle, file: []const u8) Error!void {
        // The renderer's own mirrors aren't reported back to it.
        if (t.mirroring) return;
        for (t.log.props.items) |p| if (p.node == h and std.mem.eql(u8, p.file, file)) return;
        try t.log.props.append(t.log.arena.allocator(), .{ .node = h, .file = file });
    }

    fn pushCmd(t: *Tree, c: HostCmd) Error!void {
        const a = t.log.arena.allocator();
        var x = c;
        x.win = try a.dupe(u8, c.win);
        x.name = try a.dupe(u8, c.name);
        x.answer = try a.dupe(u8, c.answer);
        x.ctl = try dupeCtl(a, c.ctl);
        try t.log.cmds.append(a, x);
    }

    /// Records what changed from `old` to `new`: created and removed nodes,
    /// changed files, and windows to redraw.
    fn diff(t: *Tree, old: *const State, new: *const State, props_only: bool) Error!void {
        const a = t.log.arena.allocator();
        var removed: std.ArrayList(Handle) = .empty;
        defer removed.deinit(t.gpa);
        var it = new.nodes.iterator();
        while (it.next()) |e| {
            const h = e.key_ptr.*;
            const nn = e.value_ptr.*;
            const on = old.nodes.get(h) orelse {
                if (props_only) continue;
                try t.log.created.append(a, h);
                try t.bus.addLive(h);
                if (new.winOfRoot(nn.root)) |w| try t.addDirty(w.nameStr());
                continue;
            };
            if (on == nn) continue;
            var any = false;
            if (on.ty != nn.ty) {
                try t.addProp(h, "type");
                any = true;
            }
            if (!std.mem.eql(Handle, on.order.items, nn.order.items)) {
                try t.addProp(h, "order");
                any = true;
            }
            if (!wordsEql(on, nn)) {
                try t.addProp(h, "style");
                any = true;
            }
            for (nn.files.items) |f| {
                const of = on.file(f.name);
                if (of == null or of.?.val != f.val) {
                    try t.addProp(h, f.name);
                    any = true;
                }
            }
            for (on.files.items) |f| if (nn.file(f.name) == null) {
                try t.addProp(h, f.name);
                any = true;
            };
            if (!std.mem.eql(Handle, on.children.items, nn.children.items)) any = true;
            if (any and !props_only) if (new.winOfRoot(nn.root)) |w| try t.addDirty(w.nameStr());
        }
        if (!props_only) {
            var oit = old.nodes.iterator();
            while (oit.next()) |e| {
                if (new.nodes.contains(e.key_ptr.*)) continue;
                try removed.append(t.gpa, e.key_ptr.*);
                try t.log.removed.append(a, e.key_ptr.*);
                if (new.winOfRoot(e.value_ptr.*.root)) |w| try t.addDirty(w.nameStr());
            }
            if (removed.items.len > 0) {
                t.bus.removeLive(removed.items);
                t.shared.mu.lockUncancelable(t.io);
                defer t.shared.mu.unlock(t.io);
                for (removed.items) |h| _ = t.shared.bounds.remove(h);
            }
        }
        for (new.wins.items) |w| {
            const ow = for (old.wins.items) |x| {
                if (x.id == w.id) break x;
            } else continue;
            if (ow == w) continue;
            if (ow.title != w.title) try t.addProp(w.root, "title");
            if (ow.state != w.state or ow.hidden != w.hidden) try t.addProp(w.root, "state");
            if (ow.focus != w.focus) try t.addProp(w.root, "focus");
            for (w.props.items) |p| {
                const before = for (ow.props.items) |q| {
                    if (std.mem.eql(u8, q.key, p.key)) break q.val;
                } else null;
                if (before != p.val) try t.addProp(w.root, p.key);
            }
        }
    }

    fn wordsEql(a: *const Node, b: *const Node) bool {
        if (a.words.items.len != b.words.items.len) return false;
        for (a.words.items, b.words.items) |x, y| if (!std.mem.eql(u8, x.name, y.name)) return false;
        return true;
    }

    // ------------------------------------------------------------ reading

    /// The state the renderer draws: frozen while a batch is open.
    pub fn committed(t: *const Tree) *const State {
        if (t.batches.items.len > 0) return t.batches.items[0].frozen;
        return t.st;
    }

    /// The state as it is now, batch or not.
    pub fn current(t: *const Tree) *const State {
        return t.st;
    }

    pub fn catalog(t: *const Tree) *const Catalog {
        return t.cat;
    }

    pub fn batchOpen(t: *const Tree) bool {
        return t.batches.items.len > 0;
    }

    /// Requests still waiting for an answer, by seq.
    pub fn openRequests(t: *const Tree, out: []u64) usize {
        const n = @min(out.len, t.requests.items.len);
        for (t.requests.items[0..n], out[0..n]) |r, *o| o.* = r.seq;
        return n;
    }

    // ------------------------------------------------------------ snapshots

    /// Makes the current state what `acquire` hands out. Call once per pump,
    /// after the ops.
    pub fn publish(t: *Tree) Error!void {
        if (t.snap) |s| if (s.st == t.st) return;
        const s = try Snapshot.create(t.gpa, t.st.ref(), t);
        t.snap_mu.lockUncancelable(t.io);
        const old = t.snap;
        t.snap = s;
        t.snap_mu.unlock(t.io);
        if (old) |o| o.release();
    }

    /// Any thread: the last published snapshot. Release it when done.
    pub fn acquire(t: *Tree) *Snapshot {
        t.snap_mu.lockUncancelable(t.io);
        defer t.snap_mu.unlock(t.io);
        return t.snap.?.retain();
    }

    // ------------------------------------------------------------ events

    /// Sends an event and returns its seq: the head (`name key path`), the
    /// attributes, `win=`, `via=` on state events (`user` unless given),
    /// and `seq=`. Delivered to the app's `events`, the window's, and those
    /// of the node and each ancestor.
    pub fn emit(t: *Tree, ev: EventIn) Error!u64 {
        const st = t.st;
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const n = st.node(ev.node);
        // A design state name (`hover`, `focus`, ...) coalesces even when
        // the host calls it an action.
        var kind: EventKind = ev.kind orelse kindOf(n, ev.name);
        if (kind == .action and state.inList(&state_events, ev.name)) kind = .state;
        var attrs: std.ArrayList(Attr) = .empty;
        var win_name: ?[]const u8 = ev.win;
        var path: []const u8 = ev.path orelse "-";
        var chain: std.ArrayList(Handle) = .empty;
        if (n) |node| {
            if (st.winOfRoot(node.root)) |w| win_name = w.nameStr();
            path = try st.relPathAlloc(a, node.id);
            var cur = node.id;
            while (st.node(cur)) |x| {
                try chain.append(a, cur);
                cur = x.parent;
            }
        } else if (ev.win) |wn| if (st.win(wn)) |w| try chain.append(a, w.root);
        var route: []const u8 = ev.key orelse (if (n) |nd| inheritedTag(st, nd.id) else null) orelse "-";
        // `win=` first (core.md § Events' examples), `via=` last.
        if (win_name) |w| try attrs.append(a, .{ .key = "win", .value = w });
        var via_at: ?Attr = null;
        for (ev.attrs) |x| {
            // `key=` given as an attribute is the routing word, except on
            // a `key` event, where it is the keystroke.
            if (std.mem.eql(u8, x.key, "key") and !std.mem.eql(u8, ev.name, "key")) {
                route = x.value;
            } else if (std.mem.eql(u8, x.key, "via")) {
                via_at = x;
            } else try attrs.append(a, x);
        }
        if (via_at) |x| try attrs.append(a, x);
        const has_via = for (ev.attrs) |x| {
            if (std.mem.eql(u8, x.key, "via")) break true;
        } else false;
        if (!has_via) {
            if (ev.via) |v| {
                try attrs.append(a, .{ .key = "via", .value = v });
            } else if (kind == .state or kind == .request) try attrs.append(a, .{ .key = "via", .value = "user" });
        }
        const seq = t.bus.nextSeq();
        var aw: Writer.Allocating = .init(a);
        const line: proto.Event = .{ .name = ev.name, .key = if (route.len == 0) "-" else route, .path = path, .attrs = attrs.items, .seq = seq };
        proto.event.format(&aw.writer, line) catch return error.OutOfMemory;
        const coalesce: Handle = if (n) |node| node.id else if (chain.items.len > 0) chain.items[0] else 0;
        try t.bus.deliver(aw.written(), ev.name.len, kind, coalesce, chain.items);
        return seq;
    }

    /// A request (core.md § Requests): sent, and answered on the ctl of the
    /// node it is about (a window's for a window, the app's for `quit`)
    /// with `seq=`, or given `default` after `request_timeout_ns`. With no
    /// reader, or for a window `close` or `quit` the client didn't `ask`
    /// for, the default applies at once and this returns 0.
    pub fn request(t: *Tree, ev_in: EventIn, default: []const u8) Error!u64 {
        var ev = ev_in;
        ev.kind = .request;
        const n = t.st.node(ev.node);
        const is_win = n != null and n.?.parent == 0;
        var asked = true;
        if (std.mem.eql(u8, ev.name, "quit")) {
            asked = t.st.asks.quit;
        } else if (std.mem.eql(u8, ev.name, "close") and is_win) {
            const w = t.st.winOfRoot(ev.node).?;
            asked = switch (w.ask) {
                .close => true,
                .none => false,
                .inherit => t.st.asks.close,
            };
        }
        var chain: [max_depth + 2]Handle = undefined;
        var cn: usize = 0;
        var cur = ev.node;
        while (t.st.node(cur)) |x| : (cur = x.parent) {
            if (cn == chain.len) break;
            chain[cn] = cur;
            cn += 1;
        }
        const reader = asked and t.bus.hasReader(chain[0..cn]);
        var r: Request = .{ .seq = 0, .target = ev.node, .default = default, .deadline = t.now() + request_timeout_ns };
        if (std.mem.eql(u8, ev.name, "close")) {
            if (is_win) {
                r.closes = ev.node;
            } else if (n) |nd| {
                if (nd.ty.tier == .overlay) r.overlay = ev.node else r.removes = ev.node;
            }
        }
        if (std.mem.eql(u8, ev.name, "drop")) {
            for (ev.attrs) |x| if (std.mem.eql(u8, x.key, "drag")) {
                r.drag = std.fmt.parseInt(u64, x.value, 10) catch null;
            };
        }
        // Not asked for: the default applies and no event goes out
        // (15-requests).
        if (asked) r.seq = try t.emit(ev);
        if (reader) {
            r.default = try t.gpa.dupe(u8, default);
            errdefer t.gpa.free(r.default);
            try t.requests.append(t.gpa, r);
            return r.seq;
        }
        try t.resolveDefault(r);
        return 0;
    }

    fn dropRequest(t: *Tree, seq: u64) void {
        for (t.requests.items, 0..) |r, i| if (r.seq == seq) {
            t.gpa.free(r.default);
            _ = t.requests.orderedRemove(i);
            return;
        };
    }

    /// A request's default answer applies: the window closes, the overlay
    /// closes, the drag goes, and the renderer hears the answer.
    fn resolveDefault(t: *Tree, r: Request) Error!void {
        try t.pushCmd(.{ .tag = .answer, .seq = r.seq, .answer = r.default, .node = r.target });
        if (std.mem.eql(u8, r.default, "quit")) return t.quitNow();
        if (!std.mem.eql(u8, r.default, "close") and r.drag == null) return;
        if (t.st.gone) return;
        if (r.drag) |dn| if (std.mem.eql(u8, r.default, "refuse")) t.releaseOffer(dn);
        try t.mutate(struct {
            fn f(tx: *Tx, rr: Request) Error!void {
                if (rr.drag) |dn| tx.dropDrag(dn);
                if (!std.mem.eql(u8, rr.default, "close")) return;
                if (rr.closes != 0 and tx.st.node(rr.closes) != null) try tx.closeWindow(rr.closes);
                if (rr.overlay != 0 and tx.st.node(rr.overlay) != null) try tx.overlayOpen(rr.overlay, false);
                if (rr.removes != 0 and tx.st.node(rr.removes) != null) try tx.removeSubtree(rr.removes);
            }
        }.f, r);
    }

    fn quitNow(t: *Tree) Error!void {
        try t.pushCmd(.{ .tag = .quit });
        t.st.gone = true;
        t.bus.shutDown();
    }

    /// Runs `f(tx, arg)` as an op that no client made: nothing is traced.
    fn mutate(t: *Tree, comptime f: anytype, arg: anytype) Error!void {
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        var d: proto.Diag = .{};
        const st = try t.st.clone(t.gpa);
        var tx: Tx = .{ .t = t, .a = arena.allocator(), .st = st, .d = &d, .session = 0, .gen = st.gen +% 1, .quiet = 1 };
        st.gen = tx.gen;
        f(&tx, arg) catch |e| {
            tx.st.unref(t.gpa);
            return e;
        };
        try t.commit(&tx);
    }

    // ------------------------------------------------------------ inputs

    /// The renderer (or `/debug/inject mirror`) changed a file the
    /// component owns, as when the user types: no event, no trace, and
    /// a `tree` rewrite keeps it. A window's root takes `focus`, `state`
    /// and `title`.
    pub fn mirror(t: *Tree, h: Handle, file: []const u8, value: []const u8) Error!void {
        const n = t.st.node(h) orelse return t.setErr(.not_found, "node");
        t.mirroring = true;
        defer t.mirroring = false;
        if (n.parent == 0 and pathm.windowFile(file) != null) {
            return t.mutate(struct {
                fn f(tx: *Tx, x: struct { Handle, []const u8, []const u8 }) Error!void {
                    try tx.mirrorWin(x[0], x[1], x[2]);
                }
            }.f, .{ h, file, value });
        }
        const name = pathm.nodeFile(t.st, h, file) orelse return t.setErr(.not_found, file);
        return t.mutate(struct {
            fn f(tx: *Tx, x: struct { Handle, []const u8, []const u8 }) Error!void {
                const nn = try tx.mutNode(x[0]);
                try nn.putFile(tx.t.gpa, x[1], try Blob.create(tx.t.gpa, chomp(x[2])), tx.gen);
                nn.fileMut(x[1]).?.mirrored = true;
            }
        }.f, .{ h, name, value });
    }

    /// `x y w h` from the last layout, window space; a window's root:
    /// the window's.
    pub fn setBounds(t: *Tree, h: Handle, b: [4]i64) Error!void {
        if (t.st.node(h) == null) return t.setErr(.not_found, "node");
        t.shared.mu.lockUncancelable(t.io);
        defer t.shared.mu.unlock(t.io);
        try t.shared.bounds.put(t.gpa, h, b);
    }

    /// A frame of the window (null: every window) was drawn: its nodes'
    /// types are fixed.
    pub fn frameDrawn(t: *Tree, win: ?[]const u8) Error!void {
        const drawn = t.committed();
        var todo: std.ArrayList(Handle) = .empty;
        defer todo.deinit(t.gpa);
        var it = t.st.nodes.iterator();
        while (it.next()) |e| {
            const n = e.value_ptr.*;
            if (n.fixed or !drawn.nodes.contains(n.id)) continue;
            if (win) |wn| {
                const w = t.st.winOfRoot(n.root) orelse continue;
                if (!std.mem.eql(u8, w.nameStr(), wn)) continue;
            }
            try todo.append(t.gpa, n.id);
        }
        if (todo.items.len == 0) return;
        // Not an op: the state changes in place for the renderer's sake
        // only, so the 9P snapshot needn't move. Copy on write as ever.
        const st = try t.st.clone(t.gpa);
        errdefer st.unref(t.gpa);
        for (todo.items) |h| {
            const slot = st.nodes.getPtr(h).?;
            const c = try slot.*.dupe(t.gpa);
            c.fixed = true;
            slot.*.unref(t.gpa);
            slot.* = c;
        }
        const old = t.st;
        t.st = st;
        old.unref(t.gpa);
    }

    /// The user closed the window and the renderer already did it.
    pub fn windowClosed(t: *Tree, win: []const u8) Error!void {
        const w = t.st.win(win) orelse return t.setErr(.not_found, win);
        return t.mutate(struct {
            fn f(tx: *Tx, root: Handle) Error!void {
                try tx.closeWindow(root);
            }
        }.f, w.root);
    }

    /// The OS appearance changed. With `theme/pref` at `system`, the mode
    /// in effect follows, and a `theme` event says so.
    pub fn systemDark(t: *Tree, dark: bool) Error!void {
        if (t.st.system_dark == dark) return;
        return t.mutate(struct {
            fn f(tx: *Tx, dk: bool) Error!void {
                const before = tx.st.dark();
                tx.st.system_dark = dk;
                if (before != tx.st.dark()) {
                    tx.st.theme_ver = tx.gen;
                    tx.st.tokens_ver = tx.gen;
                    try tx.themeEvent("system");
                    try tx.cmd(.{ .tag = .theme });
                }
            }
        }.f, dark);
    }

    /// A keystroke the renderer's widgets didn't take, in window `win` with
    /// `focused` (0: none) focused. Sends `action ID PATH via=key win=W`
    /// and returns true if a binding in `keys` matched.
    pub fn key(t: *Tree, win: []const u8, stroke: []const u8, focused: Handle) Error!bool {
        const w = t.st.win(win) orelse return t.setErr(.not_found, win);
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = Blob.str(t.st.keys);
        const binds = proto.lines.parseLines(proto.lines.KeyBinding, a, text, null) catch return false;
        const at: Handle = if (focused != 0) focused else if (w.focus != 0) w.focus else w.root;
        // The innermost context wins: walk up from the focused node.
        var best: ?proto.lines.KeyBinding = null;
        var best_depth: usize = std.math.maxInt(usize);
        for (binds) |b| {
            if (b.keys.len != 1 or !std.mem.eql(u8, b.keys[0], stroke)) continue;
            const ctx = b.context() orelse {
                if (best == null) best = b;
                continue;
            };
            var dpt: usize = 0;
            var cur = at;
            while (t.st.node(cur)) |n| : (cur = n.parent) {
                if (std.mem.eql(u8, n.value("context"), ctx)) break;
                dpt += 1;
            } else continue;
            if (best == null or best.?.context() == null or dpt < best_depth) {
                best = b;
                best_depth = dpt;
            }
        }
        const b = best orelse return false;
        // A disabled action's binding is taken but sends nothing.
        if (t.disabled.contains(b.action)) return true;
        _ = try t.emit(.{ .name = "action", .node = at, .key = b.action, .via = "key", .kind = .action });
        return true;
    }

    /// A menu item was chosen: `action ID - via=menu`.
    pub fn menuAction(t: *Tree, id: []const u8) Error!void {
        if (t.disabled.contains(id)) return;
        _ = try t.emit(.{ .name = "action", .key = id, .via = "menu", .kind = .action });
    }

    // ------------------------------------------------------------ drags

    /// A drag number for a new drag: `n`, or the next free one if 0.
    fn dragNumber(t: *Tree, n: u64) u64 {
        const got = if (n == 0) t.next_drag else n;
        if (got >= t.next_drag) t.next_drag = got + 1;
        return got;
    }

    /// Sets type `ty` of drag N's offer to `data`, making the drag if
    /// needed (N 0: a new one). A host's drop, `/debug/inject drag`.
    /// Returns the drag's number.
    pub fn dragData(t: *Tree, n: u64, ty: []const u8, data: []const u8) Error!u64 {
        if (!pathm.typeId(ty)) return error.BadValue;
        const dn = t.dragNumber(n);
        try t.mutate(struct {
            fn f(tx: *Tx, x: struct { u64, []const u8, []const u8 }) Error!void {
                const o = try tx.mutDrag(x[0], 0);
                try o.setRep(tx.gpa(), x[1], x[2], tx.gen);
            }
        }.f, .{ dn, ty, data });
        return dn;
    }

    /// Adds file handle `id` (files.zig) to drag N's offer as the next
    /// item of type `file`, making the drag if needed (N 0: a new one).
    /// Returns the drag's number. The offer releases the handle if its
    /// drop is refused.
    pub fn dragFile(t: *Tree, n: u64, id: u64) Error!u64 {
        const h = t.files.get(id) orelse return error.NotFound;
        defer h.unref(t.gpa);
        const in = t.files.info(h, "") catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.NotFound,
        };
        var aw: Writer.Allocating = .init(t.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("file name=") catch return error.OutOfMemory;
        proto.tokenize.quoteValue(w, h.name) catch return error.OutOfMemory;
        if (in.dir) w.writeAll(" dir") catch return error.OutOfMemory else w.print(" size={d}", .{in.size}) catch return error.OutOfMemory;
        w.writeByte('\n') catch return error.OutOfMemory;
        const dn = t.dragNumber(n);
        try t.mutate(struct {
            fn f(tx: *Tx, x: struct { u64, u64, []const u8 }) Error!void {
                const o = try tx.mutDrag(x[0], 0);
                const old = if (o.rep("file")) |r| r.val.bytes else "";
                const list = try std.mem.concat(tx.a, u8, &.{ old, x[2] });
                try o.setRep(tx.gpa(), "file", list, tx.gen);
                try o.addItem(tx.gpa(), x[1]);
            }
        }.f, .{ dn, id, aw.written() });
        return dn;
    }

    /// A drag starts from client node `source` (`on` has `drag`): drag N
    /// (0: a new one) offers the node's `drag-types`, and the client
    /// writes their bytes to `drag/N/data/TYPE`. Returns the number.
    pub fn dragStart(t: *Tree, n: u64, source: Handle) Error!u64 {
        const dn = t.dragNumber(n);
        try t.mutate(struct {
            fn f(tx: *Tx, x: struct { u64, Handle }) Error!void {
                const o = try tx.mutDrag(x[0], x[1]);
                const nd = tx.st.node(x[1]) orelse return;
                const list = nd.stored("drag-types") orelse return;
                var it = std.mem.tokenizeAny(u8, list, " \t\n,");
                while (it.next()) |ty| if (pathm.typeId(ty)) try o.addType(tx.gpa(), ty);
            }
        }.f, .{ dn, source });
        return dn;
    }

    /// Drag N's offered types, comma-separated, for a drop's `types=`.
    pub fn dragTypes(t: *Tree, a: Allocator, n: u64) Error![]const u8 {
        const dg = t.st.drag(n) orelse return "";
        var out: std.ArrayList(u8) = .empty;
        for (dg.offer.types.items, 0..) |b, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, b.bytes);
        }
        return out.items;
    }

    /// The op a drop of drag N was accepted with, once; null if none.
    pub fn takeDragOp(t: *Tree, n: u64) ?[]const u8 {
        const kv = t.drag_ops.fetchRemove(n) orelse return null;
        return kv.value;
    }

    /// Releases the file handles drag N's offer made (its drop was
    /// refused).
    fn releaseOffer(t: *Tree, n: u64) void {
        const dg = t.st.drag(n) orelse return;
        for (dg.offer.handles.items) |id| _ = t.files.release(id);
    }

    pub fn dragDone(t: *Tree, n: u64) Error!void {
        if (t.st.drag(n) == null) return;
        return t.mutate(struct {
            fn f(tx: *Tx, dn: u64) Error!void {
                tx.dropDrag(dn);
            }
        }.f, n);
    }

    /// The app quit: events readers get end of file, every later op fails
    /// with `app gone`.
    pub fn appGone(t: *Tree) void {
        t.st.gone = true;
        t.bus.shutDown();
    }
};

fn kindOf(n: ?*const Node, name: []const u8) EventKind {
    if (n) |node| if (node.ty.event(name)) |e| return e.kind;
    if (state.inList(&state_events, name)) return .state;
    return .action;
}

/// The node's tag, or its nearest tagged ancestor's in the window.
fn inheritedTag(st: *const State, h: Handle) ?[]const u8 {
    var cur = h;
    while (st.node(cur)) |n| : (cur = n.parent) {
        if (n.stored("tag")) |tg| if (tg.len > 0) return tg;
    }
    return null;
}

pub fn dupeCtl(a: Allocator, c: Ctl) Allocator.Error!Ctl {
    const words = try a.alloc([]const u8, c.words.len);
    for (c.words, words) |x, *o| o.* = try a.dupe(u8, x);
    const attrs = try a.alloc(Attr, c.attrs.len);
    for (c.attrs, attrs) |x, *o| o.* = .{ .key = try a.dupe(u8, x.key), .value = try a.dupe(u8, x.value) };
    var style: ?[]const []const u8 = null;
    if (c.style) |s| {
        const out = try a.alloc([]const u8, s.len);
        for (s, out) |x, *o| o.* = try a.dupe(u8, x);
        style = out;
    }
    return .{ .verb = try a.dupe(u8, c.verb), .words = words, .attrs = attrs, .style = style };
}

/// One trailing newline dropped.
pub fn chomp(s: []const u8) []const u8 {
    if (std.mem.endsWith(u8, s, "\r\n")) return s[0 .. s.len - 2];
    if (std.mem.endsWith(u8, s, "\n")) return s[0 .. s.len - 1];
    return s;
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn isOnOff(v: []const u8) ?bool {
    if (std.mem.eql(u8, v, "on")) return true;
    if (std.mem.eql(u8, v, "off")) return false;
    return null;
}

/// `a,b`, both numbers.
fn isPair(v: []const u8) bool {
    const i = std.mem.indexOfScalar(u8, v, ',') orelse return false;
    return types.style.isNumber(v[0..i]) and types.style.isNumber(v[i + 1 ..]);
}

// ---------------------------------------------------------------- Tx

const PendingEvent = struct { ev: EventIn, request: ?[]const u8 = null };
const BatchOp = enum { begin, end };

/// One op in progress: a private copy of the state, and what to do once
/// it is in.
const Tx = struct {
    t: *Tree,
    a: Allocator,
    st: *State,
    d: *proto.Diag,
    session: Session,
    gen: u32,
    trace: std.ArrayList([]const u8) = .empty,
    events: std.ArrayList(PendingEvent) = .empty,
    cmds: std.ArrayList(HostCmd) = .empty,
    batch_ops: std.ArrayList(BatchOp) = .empty,
    answered: std.ArrayList(u64) = .empty,
    /// Above zero inside a `new`, a document, or an op nobody wrote:
    /// those writes are traced as the one line that made them, and send
    /// no echoes.
    quiet: u32 = 0,
    quit: bool = false,

    fn gpa(tx: *Tx) Allocator {
        return tx.t.gpa;
    }

    fn cat(tx: *Tx) *const Catalog {
        return tx.t.cat;
    }

    fn fail(tx: *Tx, code: Code, comptime fmt: []const u8, args: anytype) proto.err.ProtoError {
        return proto.err.fail(tx.d, tx.a, code, fmt, args);
    }

    /// A catalog check's error, with its detail.
    fn typesErr(tx: *Tx, e: types.Error, td: *const types.Diag) Error {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        tx.d.code = Code.fromError(e) orelse .bad_value;
        tx.d.detail = tx.a.dupe(u8, td.detail()) catch "";
        return e;
    }

    fn log(tx: *Tx, comptime fmt: []const u8, args: anytype) Error!void {
        if (tx.quiet > 0) return;
        try tx.trace.append(tx.a, try std.fmt.allocPrint(tx.a, fmt, args));
    }

    fn logWrite(tx: *Tx, p: []const u8, value: []const u8, secret: bool) Error!void {
        if (tx.quiet > 0) return;
        var aw: Writer.Allocating = .init(tx.a);
        trace.write(&aw.writer, p, value, secret) catch return error.OutOfMemory;
        try tx.trace.append(tx.a, aw.written());
    }

    fn logCtl(tx: *Tx, p: []const u8, c: Ctl, secret: bool) Error!void {
        if (tx.quiet > 0) return;
        var aw: Writer.Allocating = .init(tx.a);
        trace.ctl(&aw.writer, p, c, secret) catch return error.OutOfMemory;
        try tx.trace.append(tx.a, aw.written());
    }

    fn cmd(tx: *Tx, c: HostCmd) Error!void {
        try tx.cmds.append(tx.a, c);
    }

    /// A state event echoing a client write, `via=ctl`.
    fn echo(tx: *Tx, ev: EventIn) Error!void {
        if (tx.quiet > 0) return;
        var e = ev;
        e.via = "ctl";
        if (e.kind == null) e.kind = .state;
        try tx.events.append(tx.a, .{ .ev = e });
    }

    fn event(tx: *Tx, ev: EventIn) Error!void {
        try tx.events.append(tx.a, .{ .ev = ev });
    }

    fn fullPath(tx: *Tx, h: Handle) Error![]const u8 {
        var aw: Writer.Allocating = .init(tx.a);
        tx.st.fullPath(&aw.writer, h) catch return error.OutOfMemory;
        return aw.written();
    }

    fn filePath(tx: *Tx, h: Handle, name: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(tx.a, "{s}/{s}", .{ try tx.fullPath(h), name });
    }

    fn relPath(tx: *Tx, h: Handle) Error![]const u8 {
        return tx.st.relPathAlloc(tx.a, h);
    }

    fn node(tx: *Tx, h: Handle) *Node {
        return tx.st.node(h).?;
    }

    /// The node, copied first if an older State shares it.
    fn mutNode(tx: *Tx, h: Handle) Error!*Node {
        const slot = tx.st.nodes.getPtr(h).?;
        const n = slot.*;
        if (n.rc.load(.acquire) == 1) return n;
        const c = try n.dupe(tx.gpa());
        n.unref(tx.gpa());
        slot.* = c;
        return c;
    }

    fn winOf(tx: *Tx, h: Handle) *Win {
        return tx.st.winOfRoot(tx.node(h).root).?;
    }

    fn mutWin(tx: *Tx, root: Handle) Error!*Win {
        for (tx.st.wins.items) |*slot| if (slot.*.root == root) {
            const w = slot.*;
            if (w.rc.load(.acquire) == 1) return w;
            const c = try w.dupe(tx.gpa());
            w.unref(tx.gpa());
            slot.* = c;
            return c;
        };
        unreachable;
    }

    fn blob(tx: *Tx, s: []const u8) Error!*Blob {
        return Blob.create(tx.gpa(), s);
    }

    fn isSecret(tx: *Tx, h: Handle) bool {
        const n = tx.st.node(h) orelse return false;
        return n.ty.prop("secret") != null and n.isOn("secret");
    }

    // ---------------------------------------------------------- dispatch

    fn write(tx: *Tx, p_in: []const u8, data_in: []const u8, append: bool) Error!void {
        const p = std.mem.trim(u8, p_in, "/");
        const loc = try pathm.resolve(tx.st, tx.cat(), tx.a, p, tx.d);
        var data = data_in;
        const is_ctl = switch (loc) {
            .app => |f| f == .ctl,
            .file => |f| std.mem.eql(u8, f.name, "ctl"),
            else => false,
        };
        if (append and !is_ctl) {
            const cur = try tx.currentBytes(loc);
            data = try std.mem.concat(tx.a, u8, &.{ cur, data_in });
        }
        switch (loc) {
            .dir, .node, .drag, .drag_data_dir, .drag_items, .drag_item, .type_dir => return tx.fail(.bad_value, "{s}: a directory", .{p}),
            .drag_types, .drag_item_file => return tx.fail(.bad_value, "read-only: {s}", .{p}),
            .type_file => return tx.fail(.bad_value, "read-only: {s}", .{p}),
            .app => |f| switch (f) {
                .ctl => return tx.ctlApp(data),
                .version, .events, .trace, .style_words, .theme_names, .clip_types => return tx.fail(.bad_value, "read-only: {s}", .{p}),
                .keys => return tx.writeKeys(data),
                .clip => {
                    if (data.len > proto.limits.text_prop) return tx.fail(.too_large, "clip", .{});
                    try tx.logWrite("clip", data, false);
                    return tx.setClipboard(&.{.{ .ty = "text", .val = data }});
                },
                .theme_tokens => return tx.writeTokens(data),
                .theme_name => return tx.writeThemeName(chomp(data)),
                .theme_pref, .theme_mode => return tx.writePref(f, trimmed(data)),
            },
            .menu => |name| return tx.writeMenu(name, data),
            .asset => |name| return tx.writeAsset(name, data),
            .drag_data => |x| {
                const dg = tx.st.drag(x.n) orelse return tx.fail(.not_found, "{s}", .{p});
                // A host's offer is read-only; a client drag's source
                // writes its bytes.
                if (dg.source == 0) return tx.fail(.permission_denied, "read-only: {s}", .{p});
                try tx.logWrite(p, data, false);
                const o = try tx.mutDrag(x.n, dg.source);
                try o.setRep(tx.gpa(), x.ty, data, tx.gen);
            },
            .clipdata => |ty| {
                try tx.logWrite(p, data, false);
                return tx.setClipboard(&.{.{ .ty = ty, .val = data }});
            },
            .file => |f| return tx.writeNodeFile(f.node, f.name, data),
            .win_file => |f| return tx.writeWinFile(f.root, f.name, data),
        }
    }

    const ClipRep = struct { ty: []const u8, val: []const u8 };

    /// The clipboard becomes exactly `reps`, with a new generation; `clip`
    /// reads as their text, and a `clip` event follows.
    fn setClipboard(tx: *Tx, reps: []const ClipRep) Error!void {
        const g = tx.gpa();
        const o = try state.Offer.create(g);
        errdefer o.unref(g);
        var text: []const u8 = "";
        for (reps) |r| try o.setRep(g, r.ty, r.val, tx.gen);
        if (o.rep("text")) |r| {
            text = r.val.bytes;
        } else if (o.rep("file")) |r| {
            // A file list reads as its names, one per line.
            var out: std.ArrayList(u8) = .empty;
            var it = std.mem.splitScalar(u8, r.val.bytes, '\n');
            while (it.next()) |ln| {
                const toks = proto.tokenize.tokenize(tx.a, ln) catch continue;
                for (toks) |tk| if (tk.attr()) |kv| if (std.mem.eql(u8, kv.key, "name")) {
                    try out.appendSlice(tx.a, kv.value);
                    try out.append(tx.a, '\n');
                };
            }
            text = out.items;
        } else if (o.rep("uri")) |r| {
            text = r.val.bytes;
        }
        const tb = try tx.blob(text);
        if (tx.st.clipdata) |old| old.unref(g);
        tx.st.clipdata = o;
        state.unrefOpt(tx.st.clip, g);
        tx.st.clip = tb;
        tx.st.clip_ver = tx.gen;
        tx.st.clip_gen += 1;
        const attrs = try tx.a.alloc(Attr, 1);
        attrs[0] = .{ .key = "gen", .value = try std.fmt.allocPrint(tx.a, "{d}", .{tx.st.clip_gen}) };
        try tx.event(.{ .name = "clip", .kind = .action, .key = "-", .attrs = attrs });
        return tx.cmd(.{ .tag = .clipboard });
    }

    /// Drag N's offer, private to this State, making the drag (from
    /// `source`, 0 for the host) if there is none.
    fn mutDrag(tx: *Tx, n: u64, source: Handle) Error!*state.Offer {
        const g = tx.gpa();
        for (tx.st.drags.items) |*dg| if (dg.n == n) {
            dg.ver = tx.gen;
            if (dg.offer.rc.load(.acquire) != 1) {
                const c = try dg.offer.dupe(g);
                dg.offer.unref(g);
                dg.offer = c;
            }
            return dg.offer;
        };
        const o = try state.Offer.create(g);
        tx.st.drags.append(g, .{ .n = n, .offer = o, .ver = tx.gen, .source = source }) catch |e| {
            o.unref(g);
            return e;
        };
        return o;
    }

    /// What a file holds now, for an append.
    fn currentBytes(tx: *Tx, loc: Loc) Error![]const u8 {
        return switch (loc) {
            .app => |f| switch (f) {
                .keys => Blob.str(tx.st.keys),
                .clip => Blob.str(tx.st.clip),
                else => "",
            },
            .menu => |name| if (std.mem.eql(u8, name, "bar")) Blob.str(tx.st.bar) else if (tx.st.menu(name)) |m| m.val.bytes else "",
            .asset => |name| if (tx.st.asset(name)) |m| m.val.bytes else "",
            .file => |f| blk: {
                const n = tx.node(f.node);
                const v = n.stored(f.name) orelse break :blk "";
                const bytes = if (n.ty.prop(f.name)) |pp| pp.form == .bytes else false;
                if (bytes or v.len == 0) break :blk v;
                break :blk try std.mem.concat(tx.a, u8, &.{ v, "\n" });
            },
            else => "",
        };
    }

    fn mkdir(tx: *Tx, p_in: []const u8) Error!void {
        const p = std.mem.trim(u8, p_in, "/");
        const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return tx.fail(.bad_value, "mkdir: {s}", .{p});
        const parent_p = p[0..i];
        const name = p[i + 1 ..];
        // `mkdir win/NAME` makes a window.
        if (std.mem.eql(u8, parent_p, "win")) {
            try tx.log("mkdir path={s}", .{p});
            if (tx.st.win(name) != null) return tx.fail(.in_use, "{s}", .{p});
            return tx.makeWindow(name, &.{});
        }
        if (std.mem.eql(u8, parent_p, "menu") or std.mem.eql(u8, parent_p, "asset") or std.mem.eql(u8, parent_p, "drag") or std.mem.eql(u8, parent_p, "clipdata") or std.mem.eql(u8, parent_p, "file"))
            return tx.fail(.bad_value, "mkdir: {s}", .{p});
        const loc = pathm.resolve(tx.st, tx.cat(), tx.a, parent_p, tx.d) catch |e| {
            if (e == error.NotFound) return tx.fail(.not_found, "{s}", .{p});
            return e;
        };
        const parent = switch (loc) {
            .node => |h| h,
            else => return tx.fail(.bad_value, "mkdir: {s}", .{p}),
        };
        if (tx.st.child(parent, name) != null) return tx.fail(.in_use, "{s}", .{p});
        try tx.log("mkdir path={s}", .{p});
        const div = tx.cat().lookup("div") orelse return tx.fail(.unknown_type, "div", .{});
        _ = try tx.createChild(parent, div, name, true);
    }

    fn remove(tx: *Tx, p_in: []const u8) Error!void {
        const p = std.mem.trim(u8, p_in, "/");
        const loc = try pathm.resolve(tx.st, tx.cat(), tx.a, p, tx.d);
        switch (loc) {
            .menu => |name| {
                if (std.mem.eql(u8, name, "bar")) {
                    state.unrefOpt(tx.st.bar, tx.gpa());
                    tx.st.bar = null;
                    tx.st.bar_ver = tx.gen;
                } else {
                    const i = for (tx.st.menus.items, 0..) |m, i| {
                        if (std.mem.eql(u8, m.name.bytes, name)) break i;
                    } else return tx.fail(.not_found, "{s}", .{p});
                    const m = tx.st.menus.orderedRemove(i);
                    m.name.unref(tx.gpa());
                    m.val.unref(tx.gpa());
                }
                try tx.log("remove path={s}", .{p});
                return tx.cmd(.{ .tag = .menus });
            },
            .asset => |name| {
                const i = for (tx.st.assets.items, 0..) |m, i| {
                    if (std.mem.eql(u8, m.name.bytes, name)) break i;
                } else return tx.fail(.not_found, "{s}", .{p});
                const m = tx.st.assets.orderedRemove(i);
                try tx.cmd(.{ .tag = .assets, .name = try tx.a.dupe(u8, name) });
                m.name.unref(tx.gpa());
                m.val.unref(tx.gpa());
                return tx.log("remove path={s}", .{p});
            },
            .node => |h| {
                const n = tx.node(h);
                if (n.kind == .over) return; // `rm -r` of a window reaches it; it goes with the window.
                try tx.log("remove path={s}", .{p});
                if (n.parent == 0) {
                    try tx.cmd(.{ .tag = .window_ctl, .win = try tx.a.dupe(u8, tx.winOf(h).nameStr()), .ctl = .{ .verb = "destroy" } });
                    return tx.removeWindow(h);
                }
                return tx.removeSubtree(h);
            },
            // A node's own file, as `rm -r` removes them before the
            // directory: nothing to do.
            .file, .win_file => return,
            else => return tx.fail(.bad_value, "remove: {s}", .{p}),
        }
    }

    // ---------------------------------------------------------- app files

    fn writeKeys(tx: *Tx, data_in: []const u8) Error!void {
        const data = chomp(data_in);
        if (data.len > proto.limits.data_file) return tx.fail(.too_large, "keys", .{});
        const binds = try proto.lines.parseLines(proto.lines.KeyBinding, tx.a, data, tx.d);
        for (binds) |b| for (b.keys) |k| try tx.checkKeystroke(k);
        try tx.logWrite("keys", data, false);
        state.unrefOpt(tx.st.keys, tx.gpa());
        tx.st.keys = try tx.blob(data);
        tx.st.keys_ver = tx.gen;
        try tx.cmd(.{ .tag = .keymap });
    }

    /// Modifiers joined by `-`, then a key (`cmd-shift-p`, `ctrl--`).
    fn checkKeystroke(tx: *Tx, k: []const u8) Error!void {
        var mods: []const u8 = "";
        var keyname: []const u8 = k;
        if (std.mem.endsWith(u8, k, "--")) {
            mods = k[0 .. k.len - 2];
            keyname = "-";
        } else if (!std.mem.eql(u8, k, "-")) {
            if (std.mem.lastIndexOfScalar(u8, k, '-')) |i| {
                mods = k[0..i];
                keyname = k[i + 1 ..];
            }
        }
        if (keyname.len == 0) return tx.fail(.bad_value, "keystroke: {s}", .{k});
        if (mods.len > 0) {
            var it = std.mem.splitScalar(u8, mods, '-');
            while (it.next()) |m| if (!state.inList(&modifiers, m)) return tx.fail(.bad_value, "keystroke: {s}", .{k});
        }
    }

    fn writeMenu(tx: *Tx, name: []const u8, data_in: []const u8) Error!void {
        const data = chomp(data_in);
        if (data.len > proto.limits.data_file) return tx.fail(.too_large, "menu/{s}", .{name});
        if (!state.validName(name)) return tx.fail(.bad_value, "menu name: {s}", .{name});
        const p = try std.fmt.allocPrint(tx.a, "menu/{s}", .{name});
        if (std.mem.eql(u8, name, "bar")) {
            var it = std.mem.tokenizeAny(u8, data, " \t\n");
            while (it.next()) |m| if (!state.validName(m)) return tx.fail(.bad_value, "menu name: {s}", .{m});
            try tx.logWrite(p, data, false);
            state.unrefOpt(tx.st.bar, tx.gpa());
            tx.st.bar = try tx.blob(data);
            tx.st.bar_ver = tx.gen;
            return tx.cmd(.{ .tag = .menus });
        }
        const lines = try proto.lines.parseMenu(tx.a, data, tx.d);
        for (lines) |l| if (l.attr("role")) |r| if (!state.inList(&menu_roles, r)) return tx.fail(.bad_value, "role: {s}", .{r});
        try tx.logWrite(p, data, false);
        const val = try tx.blob(data);
        for (tx.st.menus.items) |*m| if (std.mem.eql(u8, m.name.bytes, name)) {
            m.val.unref(tx.gpa());
            m.val = val;
            m.ver = tx.gen;
            return tx.cmd(.{ .tag = .menus });
        };
        errdefer val.unref(tx.gpa());
        const nb = try tx.blob(name);
        errdefer nb.unref(tx.gpa());
        try tx.st.menus.append(tx.gpa(), .{ .name = nb, .val = val, .ver = tx.gen });
        try tx.cmd(.{ .tag = .menus });
    }

    fn writeAsset(tx: *Tx, name: []const u8, data: []const u8) Error!void {
        if (!state.validName(name)) return tx.fail(.bad_value, "asset name: {s}", .{name});
        if (data.len > proto.limits.data_file) return tx.fail(.too_large, "asset/{s}", .{name});
        try tx.logWrite(try std.fmt.allocPrint(tx.a, "asset/{s}", .{name}), data, false);
        try tx.cmd(.{ .tag = .assets, .name = try tx.a.dupe(u8, name) });
        const val = try tx.blob(data);
        for (tx.st.assets.items) |*m| if (std.mem.eql(u8, m.name.bytes, name)) {
            m.val.unref(tx.gpa());
            m.val = val;
            m.ver = tx.gen;
            return;
        };
        errdefer val.unref(tx.gpa());
        const nb = try tx.blob(name);
        errdefer nb.unref(tx.gpa());
        try tx.st.assets.append(tx.gpa(), .{ .name = nb, .val = val, .ver = tx.gen });
    }

    fn writeTokens(tx: *Tx, data: []const u8) Error!void {
        const Set = struct { name: []const u8, value: []const u8 };
        var set: std.ArrayList(Set) = .empty;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = trimmed(raw);
            if (line.len == 0) continue;
            const sp = std.mem.indexOfAny(u8, line, " \t") orelse return tx.fail(.bad_syntax, "tokens: {s}", .{line});
            const name = line[0..sp];
            const value = trimmed(line[sp..]);
            if (types.style.valueToken(name)) |vt| {
                if (!types.style.checkValue(vt.kind, value)) return tx.fail(.bad_value, "{s}: {s}", .{ name, switch (vt.kind) {
                    .length => "a number, 0 or more",
                    .text => "one line of text",
                    .flag => "on or off",
                } });
            } else if (tx.cat().theme_tokens.len == 0 or tx.cat().isThemeToken(name)) {
                if (!types.style.isColor(value)) return tx.fail(.bad_value, "{s}: a color", .{name});
            } else return tx.fail(.not_found, "token: {s}", .{name});
            try set.append(tx.a, .{ .name = name, .value = value });
        }
        try tx.logWrite("theme/tokens", chomp(data), false);
        for (set.items) |s| {
            const vb = try tx.blob(s.value);
            const have = for (tx.st.tokens.items) |*tk| {
                if (std.mem.eql(u8, tk.name.bytes, s.name)) break tk;
            } else null;
            if (have) |tk| {
                tk.val.unref(tx.gpa());
                tk.val = vb;
                continue;
            }
            errdefer vb.unref(tx.gpa());
            const nb = try tx.blob(s.name);
            errdefer nb.unref(tx.gpa());
            try tx.st.tokens.append(tx.gpa(), .{ .name = nb, .val = vb });
        }
        tx.st.tokens_ver = tx.gen;
        try tx.cmd(.{ .tag = .theme });
    }

    fn writeThemeName(tx: *Tx, name: []const u8) Error!void {
        const pick = try tx.pickTheme(name);
        try tx.logWrite("theme/name", name, false);
        try tx.setTheme(name, pick);
    }

    /// A theme or family name the renderer registered; empty is none.
    fn pickTheme(tx: *Tx, name: []const u8) Error!types.ThemePick {
        if (name.len == 0) return .{};
        return tx.t.cat.pickTheme(name) orelse return tx.fail(.not_found, "theme: {s}", .{name});
    }

    /// Selects a named theme. The mode in effect may change with it (a
    /// theme with only a dark palette), and a `theme` event says so.
    fn setTheme(tx: *Tx, name: []const u8, pick: types.ThemePick) Error!void {
        const before = tx.st.dark();
        state.unrefOpt(tx.st.theme_name, tx.gpa());
        tx.st.theme_name = if (name.len > 0) try tx.blob(name) else null;
        tx.st.theme = pick;
        tx.st.theme_ver = tx.gen;
        tx.st.tokens_ver = tx.gen;
        if (before != tx.st.dark()) try tx.themeEvent("ctl");
        try tx.cmd(.{ .tag = .theme });
    }

    /// `theme/pref` takes `system light dark`; `theme/mode` takes the same
    /// and sets the preference.
    fn writePref(tx: *Tx, f: pathm.AppFile, v: []const u8) Error!void {
        const pref = std.meta.stringToEnum(state.Pref, v) orelse
            return tx.fail(.bad_value, "{s}: system, light or dark", .{if (f == .theme_pref) "pref" else "mode"});
        try tx.logWrite(if (f == .theme_pref) "theme/pref" else "theme/mode", v, false);
        try tx.setPref(pref);
    }

    fn setPref(tx: *Tx, pref: state.Pref) Error!void {
        const before = tx.st.dark();
        tx.st.pref = pref;
        tx.st.theme_ver = tx.gen;
        if (before != tx.st.dark()) {
            tx.st.tokens_ver = tx.gen;
            try tx.themeEvent("ctl");
            try tx.cmd(.{ .tag = .theme });
        }
    }

    fn themeEvent(tx: *Tx, via: []const u8) Error!void {
        const attrs = try tx.a.alloc(Attr, 1);
        attrs[0] = .{ .key = "mode", .value = if (tx.st.dark()) "dark" else "light" };
        try tx.event(.{ .name = "theme", .kind = .state, .attrs = attrs, .via = via, .key = "-" });
    }

    // ---------------------------------------------------------- ctl

    fn parseCtl(tx: *Tx, data: []const u8) Error![]Ctl {
        return proto.ctl.parseWriteDiag(tx.a, data, tx.d);
    }

    /// Whether a command's `value=` must stay out of the trace: it makes a
    /// secret input, or sets the value of one.
    fn ctlSecret(tx: *Tx, base: Handle, c: Ctl) bool {
        for (c.words) |w| if (std.mem.eql(u8, w, "secret")) return true;
        if (c.attr("secret")) |v| if (std.mem.eql(u8, v, "on")) return true;
        if (!std.mem.eql(u8, c.verb, "set") or c.words.len == 0) return false;
        const target: ?Handle = if (base == 0) blk: {
            const ap = pathm.splitAppPath(c.words[0]) orelse break :blk null;
            const w = tx.st.win(ap.win) orelse break :blk null;
            break :blk pathm.resolveNode(tx.st, tx.a, w.root, ap.rel, null) catch null;
        } else pathm.resolveNode(tx.st, tx.a, base, c.words[0], null) catch null;
        return if (target) |h| tx.isSecret(h) else false;
    }

    fn isAnswer(c: Ctl) bool {
        return c.attr("seq") != null and state.inList(&answers, c.verb);
    }

    fn ctlApp(tx: *Tx, data: []const u8) Error!void {
        // Every `copy` line of one write makes one clipboard.
        var copies: std.ArrayList(ClipRep) = .empty;
        try tx.ctlAppLines(data, &copies);
        if (copies.items.len > 0) try tx.setClipboard(copies.items);
    }

    fn ctlAppLines(tx: *Tx, data: []const u8, copies: *std.ArrayList(ClipRep)) Error!void {
        for (try tx.parseCtl(data)) |c| {
            try tx.logCtl("ctl", c, tx.ctlSecret(0, c));
            if (isAnswer(c)) {
                try tx.answer(0, c);
                continue;
            }
            if (std.mem.eql(u8, c.verb, "copy")) {
                if (c.words.len > 0 or c.attrs.len == 0) return tx.fail(.bad_syntax, "copy TYPE=VALUE ...", .{});
                for (c.attrs) |x| {
                    if (!pathm.typeId(x.key)) return tx.fail(.bad_value, "type {s}", .{x.key});
                    try copies.append(tx.a, .{ .ty = x.key, .val = x.value });
                }
                continue;
            }
            switch (c.kind()) {
                .window => {
                    if (c.words.len != 1) return tx.fail(.bad_syntax, "window NAME [prop=value ...]", .{});
                    try tx.windowVerb(c.words[0], c.attrs);
                },
                .set, .new, .delete, .tree => {
                    const i: usize = if (c.kind() == .new) 1 else 0;
                    const target = c.word(i) orelse return tx.fail(.bad_syntax, "{s}: want a path", .{c.verb});
                    if (pathm.splitAppPath(target)) |ap| {
                        const w = tx.st.win(ap.win) orelse return tx.fail(.not_found, "win/{s}", .{ap.win});
                        var cc = c;
                        const words = try tx.a.dupe([]const u8, c.words);
                        words[i] = if (ap.rel.len == 0) "." else ap.rel;
                        cc.words = words;
                        try tx.nodeCmd(w.root, cc);
                    } else if (c.kind() == .set) {
                        try tx.setAction(c);
                    } else return tx.fail(.not_found, "{s}", .{target});
                },
                .ask => try tx.ask(0, c),
                .begin => {
                    if (c.words.len > 0) return tx.fail(.bad_syntax, "begin takes no arguments", .{});
                    if (tx.batchOpen()) return tx.fail(.in_use, "batch already open", .{});
                    try tx.batch_ops.append(tx.a, .begin);
                },
                .commit, .abort => {
                    if (c.words.len > 0) return tx.fail(.bad_syntax, "{s} takes no arguments", .{c.verb});
                    if (!tx.batchOpen()) return tx.fail(.no_batch, "", .{});
                    if (c.kind() == .abort) try tx.abortBatch();
                    // A begin in this same write: they cancel out.
                    if (tx.batch_ops.items.len > 0 and tx.batch_ops.items[tx.batch_ops.items.len - 1] == .begin) {
                        _ = tx.batch_ops.pop();
                    } else try tx.batch_ops.append(tx.a, .end);
                },
                .theme => try tx.themeVerb(c),
                .quit => {
                    if (c.words.len > 0) return tx.fail(.bad_syntax, "quit takes no arguments", .{});
                    try tx.cmd(.{ .tag = .quit });
                    tx.quit = true;
                },
                else => return tx.fail(.unknown_command, "{s}", .{c.verb}),
            }
        }
    }

    /// Whether this session has a batch open, counting this write's own
    /// `begin` and `commit` lines.
    fn batchOpen(tx: *Tx) bool {
        var open = false;
        for (tx.t.batches.items) |b| if (b.session == tx.session) {
            open = true;
        };
        for (tx.batch_ops.items) |b| open = b == .begin;
        return open;
    }

    /// Puts everything back as it was at `begin`.
    fn abortBatch(tx: *Tx) Error!void {
        const frozen: *const State = blk: {
            if (tx.batch_ops.items.len > 0 and tx.batch_ops.items[tx.batch_ops.items.len - 1] == .begin) break :blk tx.t.st;
            for (tx.t.batches.items) |b| if (b.session == tx.session) break :blk b.frozen;
            unreachable;
        };
        const c = try frozen.clone(tx.gpa());
        c.gen = tx.gen;
        tx.st.unref(tx.gpa());
        tx.st = c;
    }

    /// `set ID enabled=on|off check=on|off|mixed`.
    fn setAction(tx: *Tx, c: Ctl) Error!void {
        if (c.words.len != 1) return tx.fail(.bad_syntax, "set ID [enabled=on|off] [check=on|off|mixed]", .{});
        const id = c.words[0];
        if (!tx.actionKnown(id)) return tx.fail(.not_found, "action {s}", .{id});
        var enabled: i32 = -1;
        var check: i32 = -1;
        for (c.attrs) |at| {
            if (std.mem.eql(u8, at.key, "enabled")) {
                const b = isOnOff(at.value) orelse return tx.fail(.bad_value, "enabled={s}", .{at.value});
                enabled = @intFromBool(b);
            } else if (std.mem.eql(u8, at.key, "check")) {
                check = if (std.mem.eql(u8, at.value, "mixed")) 2 else @intFromBool(isOnOff(at.value) orelse return tx.fail(.bad_value, "check={s}", .{at.value}));
            } else return tx.fail(.not_found, "set: {s}", .{at.key});
        }
        try tx.cmd(.{ .tag = .set_action, .name = id, .flag = enabled, .flag2 = check });
    }

    /// An action is known if a binding, a menu item, or a node's tag names
    /// it.
    fn actionKnown(tx: *Tx, id: []const u8) bool {
        const binds = proto.lines.parseLines(proto.lines.KeyBinding, tx.a, Blob.str(tx.st.keys), null) catch &.{};
        for (binds) |b| if (std.mem.eql(u8, b.action, id)) return true;
        for (tx.st.menus.items) |m| {
            const ls = proto.lines.parseMenu(tx.a, m.val.bytes, null) catch continue;
            for (ls) |l| if (l.kind == .item and std.mem.eql(u8, l.id, id)) return true;
        }
        var it = tx.st.nodes.valueIterator();
        while (it.next()) |n| {
            if (n.*.stored("tag")) |tg| if (std.mem.eql(u8, tg, id)) return true;
            // A node's own menu (context-menu, dropdown-button).
            if (n.*.ty.format("menu")) |f| if (std.mem.eql(u8, f, "menu")) {
                const ls = proto.lines.parseMenu(tx.a, n.*.value("menu"), null) catch continue;
                for (ls) |l| if (l.kind == .item and std.mem.eql(u8, l.id, id)) return true;
            };
        }
        return false;
    }

    fn themeVerb(tx: *Tx, c: Ctl) Error!void {
        const usage = "theme load PATH | mode light|dark|system | name NAME";
        if (c.words.len != 2) return tx.fail(.bad_syntax, usage, .{});
        const sub = c.words[0];
        const arg = c.words[1];
        if (std.mem.eql(u8, sub, "load")) {
            std.Io.Dir.cwd().access(tx.t.io, arg, .{}) catch return tx.fail(.not_found, "{s}", .{arg});
            return tx.cmd(.{ .tag = .theme_load, .name = arg });
        }
        if (std.mem.eql(u8, sub, "mode") or std.mem.eql(u8, sub, "pref")) {
            const pref = std.meta.stringToEnum(state.Pref, arg) orelse return tx.fail(.bad_value, "mode: {s}", .{arg});
            return tx.setPref(pref);
        }
        if (std.mem.eql(u8, sub, "name")) return tx.setTheme(arg, try tx.pickTheme(arg));
        return tx.fail(.bad_syntax, usage, .{});
    }

    /// `ask close quit open` / `ask none` on the app; `ask close` / `ask
    /// none` on a window (`root`).
    fn ask(tx: *Tx, root: Handle, c: Ctl) Error!void {
        if (c.words.len == 0) return tx.fail(.bad_syntax, "ask close|quit|open|none ...", .{});
        for (c.words) |w| {
            const eq = std.mem.eql;
            if (root == 0) {
                if (eq(u8, w, "none")) tx.st.asks = .{} else if (eq(u8, w, "close")) tx.st.asks.close = true else if (eq(u8, w, "quit")) tx.st.asks.quit = true else if (eq(u8, w, "open")) tx.st.asks.open = true else return tx.fail(.bad_value, "ask: {s}", .{w});
            } else {
                const win = try tx.mutWin(root);
                if (eq(u8, w, "none")) win.ask = .none else if (eq(u8, w, "close")) win.ask = .close else return tx.fail(.bad_value, "ask: {s}", .{w});
            }
        }
    }

    /// `VERB seq=N` on the ctl of `target` (0: the app) answers request N.
    fn answer(tx: *Tx, target: Handle, c: Ctl) Error!void {
        const s = c.attr("seq").?;
        const seq = std.fmt.parseInt(u64, s, 10) catch return tx.fail(.bad_value, "seq={s}", .{s});
        const r = for (tx.t.requests.items) |r| {
            if (r.seq == seq) break r;
        } else return tx.fail(.not_found, "request {d}", .{seq});
        if (r.target != target or std.mem.indexOfScalar(u64, tx.answered.items, seq) != null)
            return tx.fail(.not_found, "request {d}", .{seq});
        if (r.drag) |dn| {
            if (std.mem.eql(u8, c.verb, "refuse")) tx.t.releaseOffer(dn);
            if (std.mem.eql(u8, c.verb, "accept")) {
                const op = c.attr("op") orelse "copy";
                if (!std.mem.eql(u8, op, "copy") and !std.mem.eql(u8, op, "move")) return tx.fail(.bad_value, "op={s}", .{op});
                // Kept for the source's dragend; a host's drag has none.
                const client = if (tx.st.drag(dn)) |dg| dg.source != 0 else false;
                if (client) try tx.t.drag_ops.put(tx.gpa(), dn, if (std.mem.eql(u8, op, "move")) "move" else "copy");
            }
            tx.dropDrag(dn);
        }
        if (std.mem.eql(u8, c.verb, "close")) {
            if (r.closes != 0 and tx.st.node(r.closes) != null) try tx.closeWindow(r.closes);
            if (r.overlay != 0 and tx.st.node(r.overlay) != null) try tx.overlayOpen(r.overlay, false);
            if (r.removes != 0 and tx.st.node(r.removes) != null) try tx.removeSubtree(r.removes);
        }
        if (std.mem.eql(u8, c.verb, "accept") and std.mem.eql(u8, r.default, "quit")) {
            try tx.cmd(.{ .tag = .quit });
            tx.quit = true;
        }
        try tx.answered.append(tx.a, seq);
        try tx.cmd(.{ .tag = .answer, .seq = seq, .answer = c.verb, .node = target });
    }

    fn dropDrag(tx: *Tx, n: u64) void {
        for (tx.st.drags.items, 0..) |dg, i| if (dg.n == n) {
            dg.offer.unref(tx.gpa());
            _ = tx.st.drags.orderedRemove(i);
            return;
        };
    }

    /// A node's ctl. On a window's root it is the window's ctl, which also
    /// takes the window verbs.
    fn ctlNode(tx: *Tx, h: Handle, data: []const u8) Error!void {
        const ctl_path = try tx.filePath(h, "ctl");
        const n = tx.node(h);
        const is_root = n.parent == 0;
        for (try tx.parseCtl(data)) |c| {
            try tx.logCtl(ctl_path, c, tx.ctlSecret(h, c) or tx.isSecret(h));
            if (isAnswer(c)) {
                try tx.answer(h, c);
                continue;
            }
            if (is_root) if (try tx.windowCtlVerb(h, c)) continue;
            try tx.nodeCmd(h, c);
        }
    }

    /// The window verbs of a window's ctl; false for any other verb.
    fn windowCtlVerb(tx: *Tx, root: Handle, c: Ctl) Error!bool {
        const win = tx.winOf(root);
        const name = try tx.a.dupe(u8, win.nameStr());
        switch (c.kind()) {
            .show => {
                try noArgs(tx, c);
                try tx.showWindow(root);
            },
            .activate => {
                try noArgs(tx, c);
                try tx.cmd(.{ .tag = .window_ctl, .win = name, .ctl = c });
            },
            .close => {
                try noArgs(tx, c);
                try tx.events.append(tx.a, .{ .ev = .{ .name = "close", .node = root, .via = "ctl", .key = "-" }, .request = "close" });
            },
            .destroy => {
                try noArgs(tx, c);
                try tx.cmd(.{ .tag = .window_ctl, .win = name, .ctl = c });
                try tx.removeWindow(root);
            },
            .state => {
                if (c.words.len != 1) return tx.fail(.bad_syntax, "state normal|min|max|full|hidden", .{});
                try tx.setWinState(root, c.words[0]);
            },
            .notify => {
                if (c.words.len != 1) return tx.fail(.bad_syntax, "notify text [type=info|success|warning|error]", .{});
                for (c.attrs) |at| {
                    if (!std.mem.eql(u8, at.key, "type")) return tx.fail(.not_found, "notify: {s}", .{at.key});
                    if (!state.inList(&.{ "info", "success", "warning", "error" }, at.value)) return tx.fail(.bad_value, "type={s}", .{at.value});
                }
                try tx.cmd(.{ .tag = .window_ctl, .win = name, .ctl = c });
            },
            .ask => try tx.ask(root, c),
            else => return false,
        }
        return true;
    }

    fn setWinState(tx: *Tx, root: Handle, v: []const u8) Error!void {
        const s = std.meta.stringToEnum(state.WinState, v) orelse return tx.fail(.bad_value, "state: {s}", .{v});
        const w = try tx.mutWin(root);
        if (s == .hidden) {
            w.hidden = true;
        } else {
            w.state = s;
            if (w.hidden) try tx.showWindow(root);
        }
        w.state_ver = tx.gen;
        const attrs = try tx.a.alloc(Attr, 1);
        attrs[0] = .{ .key = "value", .value = @tagName(s) };
        try tx.echo(.{ .name = "state", .node = root, .attrs = attrs, .key = "-" });
        var words = try tx.a.alloc([]const u8, 1);
        words[0] = @tagName(s);
        try tx.cmd(.{ .tag = .window_ctl, .win = try tx.a.dupe(u8, w.nameStr()), .ctl = .{ .verb = "state", .words = words } });
    }

    // ---------------------------------------------------------- windows

    fn checkWinProp(tx: *Tx, k: []const u8, v: []const u8) Error!void {
        const eq = std.mem.eql;
        const ok = if (eq(u8, k, "title"))
            true
        else if (eq(u8, k, "size") or eq(u8, k, "min") or eq(u8, k, "max"))
            isPair(v)
        else if (eq(u8, k, "pos"))
            isPair(v) or state.inList(&pos_hints, v) or std.mem.startsWith(u8, v, "display:")
        else if (eq(u8, k, "kind"))
            state.inList(&.{ "normal", "dialog" }, v)
        else if (eq(u8, k, "titlebar"))
            state.inList(&.{ "system", "custom", "none" }, v)
        else if (eq(u8, k, "resizable"))
            isOnOff(v) != null
        else
            return tx.fail(.not_found, "window prop: {s}", .{k});
        if (!ok) return tx.fail(.bad_value, "{s}={s}", .{ k, v });
    }

    /// `window NAME [prop=value ...]` on the app ctl.
    fn windowVerb(tx: *Tx, name: []const u8, attrs: []const Attr) Error!void {
        if (!state.validName(name)) return tx.fail(.bad_value, "window name: {s}", .{name});
        for (attrs) |at| try tx.checkWinProp(at.key, at.value);
        if (tx.st.win(name)) |w| {
            // The default main, not claimed yet: these are its props.
            if (!w.default) return tx.fail(.in_use, "win/{s}", .{name});
            const mw = try tx.mutWin(w.root);
            mw.default = false;
            for (attrs) |at| try tx.setWinProp(w.root, at.key, at.value);
            return;
        }
        try tx.makeWindow(name, attrs);
    }

    fn makeWindow(tx: *Tx, name: []const u8, attrs: []const Attr) Error!void {
        const div = tx.cat().lookup("div") orelse return tx.fail(.unknown_type, "div", .{});
        const root = try tx.newNode(0, div, "root", .node);
        const over = try tx.newNode(root, &state.over_type, "over", .over);
        const w = try tx.gpa().create(Win);
        w.* = .{ .id = tx.st.next_win, .name = undefined, .root = root, .over = over, .ver = tx.gen };
        w.name = Blob.create(tx.gpa(), name) catch |e| {
            tx.gpa().destroy(w);
            return e;
        };
        tx.st.wins.append(tx.gpa(), w) catch |e| {
            w.unref(tx.gpa());
            return e;
        };
        tx.st.next_win += 1;
        for (attrs) |at| try tx.setWinProp(root, at.key, at.value);
    }

    /// One window prop, checked already. After the window shows, the
    /// renderer hears it as `set` on the window.
    fn setWinProp(tx: *Tx, root: Handle, k: []const u8, v: []const u8) Error!void {
        const w = try tx.mutWin(root);
        try w.setProp(tx.gpa(), k, v);
        if (std.mem.eql(u8, k, "title")) w.title_ver = tx.gen;
        w.ver = tx.gen;
        if (w.hidden) return;
        const attrs = try tx.a.alloc(Attr, 1);
        attrs[0] = .{ .key = k, .value = v };
        try tx.cmd(.{ .tag = .window_ctl, .win = try tx.a.dupe(u8, w.nameStr()), .ctl = .{ .verb = "set", .attrs = attrs } });
    }

    fn showWindow(tx: *Tx, root: Handle) Error!void {
        if (!tx.winOf(root).hidden) return;
        const w = try tx.mutWin(root);
        w.hidden = false;
        w.default = false;
        w.state_ver = tx.gen;
        try tx.cmd(.{ .tag = .window, .win = try tx.a.dupe(u8, w.nameStr()), .node = root });
    }

    /// Hidden windows whose root now has content are shown.
    fn showReady(tx: *Tx) Error!void {
        for (tx.st.wins.items) |w| {
            if (!w.hidden or w.state == .hidden) continue;
            if (tx.node(w.root).children.items.len > 0) try tx.showWindow(w.root);
        }
    }

    /// A window close went through: the window goes, and closing the last
    /// one quits unless the client answers `close` itself.
    fn closeWindow(tx: *Tx, root: Handle) Error!void {
        const name = try tx.a.dupe(u8, tx.winOf(root).nameStr());
        try tx.cmd(.{ .tag = .window_ctl, .win = name, .ctl = .{ .verb = "destroy" } });
        try tx.removeWindow(root);
        if (tx.st.wins.items.len == 0 and !tx.st.asks.close) {
            try tx.cmd(.{ .tag = .quit });
            tx.quit = true;
        }
    }

    fn removeWindow(tx: *Tx, root: Handle) Error!void {
        var list: std.ArrayList(Handle) = .empty;
        try tx.st.subtree(tx.a, root, &list);
        for (tx.st.wins.items, 0..) |w, i| if (w.root == root) {
            _ = tx.st.wins.orderedRemove(i);
            w.unref(tx.gpa());
            break;
        };
        try tx.dropNodes(list.items);
    }

    fn writeWinFile(tx: *Tx, root: Handle, name: []const u8, data: []const u8) Error!void {
        const p = try tx.filePath(root, name);
        const eq = std.mem.eql;
        if (eq(u8, name, "title")) {
            const v = chomp(data);
            try tx.logWrite(p, v, false);
            return tx.setWinProp(root, "title", v);
        }
        if (eq(u8, name, "state")) {
            try tx.logWrite(p, trimmed(data), false);
            return tx.setWinState(root, trimmed(data));
        }
        if (eq(u8, name, "focus")) {
            try tx.logWrite(p, trimmed(data), false);
            return tx.setFocus(root, trimmed(data));
        }
        return tx.fail(.bad_value, "read-only: {s}", .{p});
    }

    fn setFocus(tx: *Tx, root: Handle, rel: []const u8) Error!void {
        const target: Handle = if (rel.len == 0) 0 else try pathm.resolveNode(tx.st, tx.a, root, rel, tx.d);
        const w = try tx.mutWin(root);
        w.focus = target;
        w.focus_ver = tx.gen;
        const name = try tx.a.dupe(u8, w.nameStr());
        if (target != 0) try tx.echo(.{ .name = "focus", .node = target });
        try tx.cmd(.{ .tag = .focus, .win = name, .node = target });
    }

    fn mirrorWin(tx: *Tx, root: Handle, file: []const u8, value: []const u8) Error!void {
        const v = trimmed(value);
        const eq = std.mem.eql;
        if (eq(u8, file, "focus")) {
            const target: Handle = if (v.len == 0) 0 else try pathm.resolveNode(tx.st, tx.a, root, v, tx.d);
            const w = try tx.mutWin(root);
            w.focus = target;
            w.focus_ver = tx.gen;
        } else if (eq(u8, file, "state")) {
            const s = std.meta.stringToEnum(state.WinState, v) orelse return tx.fail(.bad_value, "state: {s}", .{v});
            const w = try tx.mutWin(root);
            w.state = s;
            w.state_ver = tx.gen;
        } else if (eq(u8, file, "title")) {
            const w = try tx.mutWin(root);
            try w.setProp(tx.gpa(), "title", chomp(value));
            w.title_ver = tx.gen;
        } else return tx.fail(.bad_value, "read-only: {s}", .{file});
    }

    // ---------------------------------------------------------- nodes

    fn newNode(tx: *Tx, parent: Handle, ty: *const Type, name: []const u8, kind: state.NodeKind) Error!Handle {
        const h = tx.st.next_handle;
        const nb = try tx.blob(name);
        const n = tx.gpa().create(Node) catch |e| {
            nb.unref(tx.gpa());
            return e;
        };
        const root: Handle = if (parent == 0) h else tx.node(parent).root;
        n.* = .{ .id = h, .parent = parent, .root = root, .kind = kind, .name = nb, .ty = ty, .ver = tx.gen };
        tx.st.nodes.put(tx.gpa(), h, n) catch |e| {
            n.unref(tx.gpa());
            return e;
        };
        tx.st.next_handle += 1;
        if (parent != 0) try tx.st.kids.put(tx.gpa(), .{ .parent = parent, .name = nb.bytes }, h);
        return h;
    }

    /// A new child, checked against its parent: name, type, slot, depth.
    /// `new` and `mkdir` append it to the parent's `order`.
    fn createChild(tx: *Tx, parent: Handle, ty: *const Type, name: []const u8, at_mkdir: bool) Error!Handle {
        const pn = tx.node(parent);
        if (!state.validName(name)) return tx.fail(.bad_value, "name: {s}", .{name});
        if (pn.kind == .node and state.isReserved(pn.ty, name, pn.parent == 0))
            return tx.fail(.bad_value, "name: {s} is a file of {s}", .{ name, pn.ty.name });
        if (tx.st.child(parent, name) != null) return tx.fail(.in_use, "{s}/{s}", .{ try tx.fullPath(parent), name });
        if (tx.st.depth(parent) + 2 > max_depth) return tx.fail(.too_large, "depth: {s}", .{name});
        try tx.checkSlot(parent, ty, name, at_mkdir);
        const h = try tx.newNode(parent, ty, name, .node);
        const p = try tx.mutNode(parent);
        try p.children.append(tx.gpa(), h);
        try p.order.append(tx.gpa(), h);
        p.ver = tx.gen;
        return h;
    }

    /// Whether a `ty` child named `name` may go under `parent`. Overlays
    /// go in `over/` and nowhere else.
    fn checkSlot(tx: *Tx, parent: Handle, ty: *const Type, name: []const u8, at_mkdir: bool) Error!void {
        const pn = tx.node(parent);
        if (pn.kind == .over) {
            if (at_mkdir) return tx.fail(.bad_value, "over: use new TYPE NAME", .{});
            if (ty.tier != .overlay) return tx.fail(.unknown_type, "{s}: not an overlay", .{ty.name});
            return;
        }
        if (ty.tier == .overlay) return tx.fail(.unknown_type, "{s}: belongs in over/", .{ty.name});
        var td: types.Diag = .{};
        tx.cat().checkChild(pn.ty, ty.name, name, &td) catch |e| {
            // mkdir makes a div first and a type write follows: a parent
            // that takes only certain types still takes the div for now.
            if (at_mkdir and e == error.UnknownType) return;
            // A type that takes only its slots refuses any other child as
            // a type it doesn't take (27-descriptors: `child none`).
            if (e == error.BadValue and pn.ty.child == .none) return tx.fail(.unknown_type, "{s}", .{td.detail()});
            return tx.typesErr(e, &td);
        };
    }

    fn lookupType(tx: *Tx, name: []const u8) Error!*const Type {
        return tx.cat().lookup(name) orelse tx.fail(.unknown_type, "{s}", .{name});
    }

    /// The four node commands, and the type's verbs.
    fn nodeCmd(tx: *Tx, h: Handle, c: Ctl) Error!void {
        const n = tx.node(h);
        if (n.ty.format("ops")) |f| if (std.mem.eql(u8, f, "ops")) {
            if (try tx.canvasCmd(h, c)) return;
        };
        switch (c.kind()) {
            .set => {
                const p = c.word(0) orelse return tx.fail(.bad_syntax, "set PATH [word ...] [prop=value ...] [: style ...]", .{});
                const target = try pathm.resolveNode(tx.st, tx.a, h, p, tx.d);
                try tx.setProps(target, c.bare(), c.attrs, c.style);
            },
            .new => {
                if (c.words.len < 2) return tx.fail(.bad_syntax, "new TYPE PATH [word ...] [prop=value ...] [: style ...]", .{});
                const p = std.mem.trim(u8, c.words[1], "/");
                if (p.len == 0 or std.mem.eql(u8, p, ".")) return tx.fail(.bad_syntax, "new TYPE PATH", .{});
                const parent, const name = if (std.mem.lastIndexOfScalar(u8, p, '/')) |i|
                    .{ try pathm.resolveNode(tx.st, tx.a, h, p[0..i], tx.d), p[i + 1 ..] }
                else
                    .{ h, p };
                const ty = try tx.lookupType(c.words[0]);
                const child = try tx.createChild(parent, ty, name, false);
                tx.quiet += 1;
                defer tx.quiet -= 1;
                try tx.setProps(child, c.bare(), c.attrs, c.style);
            },
            .delete => {
                if (c.words.len != 1) return tx.fail(.bad_syntax, "delete PATH", .{});
                const target = try pathm.resolveNode(tx.st, tx.a, h, c.words[0], tx.d);
                const tn = tx.node(target);
                if (target == h or tn.parent == 0 or tn.kind == .over) return tx.fail(.bad_value, "delete: {s}", .{c.words[0]});
                try tx.removeSubtree(target);
            },
            .tree => {
                if (c.words.len != 2) return tx.fail(.bad_syntax, "tree PATH <<END", .{});
                const target = try pathm.resolveNode(tx.st, tx.a, h, c.words[0], tx.d);
                tx.quiet += 1;
                defer tx.quiet -= 1;
                try tx.writeDoc(target, c.words[1]);
            },
            else => {
                if (n.kind == .over) return tx.fail(.unknown_command, "{s}", .{c.verb});
                const v = n.ty.verb(c.verb) orelse return tx.fail(.unknown_command, "{s}", .{c.verb});
                return tx.typeVerb(h, v.name, c);
            },
        }
    }

    /// A verb from the type's descriptor.
    /// A canvas's edit verbs on its `ops` by item id (22-canvas): `set`
    /// (or `update`) ID GEOMETRY... [ATTR=VALUE...], `add KIND ID ...`,
    /// `del ID...`, `raise ID` (to the top), `lower ID` (to the bottom).
    /// False when `c` isn't one of them.
    fn canvasCmd(tx: *Tx, h: Handle, c: Ctl) Error!bool {
        const L = proto.lines;
        const eq = std.mem.eql;
        const v = c.verb;
        const verbs = [_][]const u8{ "set", "update", "add", "del", "raise", "lower" };
        if (!state.inList(&verbs, v)) return false;
        const a = tx.a;
        var ops: std.ArrayList(L.CanvasOp) = .empty;
        try ops.appendSlice(a, L.parseLines(L.CanvasOp, a, tx.node(h).value("ops"), null) catch &.{});
        const find = struct {
            fn f(list: []const L.CanvasOp, id: []const u8) ?usize {
                for (list, 0..) |o, i| if (std.mem.eql(u8, o.id, id)) return i;
                return null;
            }
        }.f;
        if (eq(u8, v, "set") or eq(u8, v, "update")) {
            const id = c.word(0) orelse return tx.fail(.bad_syntax, "{s} ID GEOMETRY... [ATTR=VALUE...]", .{v});
            const i = find(ops.items, id) orelse return tx.fail(.not_found, "item {s}", .{id});
            const old = ops.items[i];
            var words: std.ArrayList([]const u8) = .empty;
            try words.append(a, id);
            const new = c.words[1..];
            if (old.kind == .path) {
                if (new.len > 0) {
                    try words.appendSlice(a, new);
                } else for (old.path) |seg| try words.append(a, try std.fmt.allocPrint(a, "{f}", .{seg}));
            } else {
                // New numbers replace the first ones (`set dot 150 140`
                // moves a circle and keeps its radius).
                const k = old.kind.arity();
                try words.appendSlice(a, new[0..@min(new.len, k)]);
                if (new.len < k) for (old.geom[new.len..]) |g| try words.append(a, try std.fmt.allocPrint(a, "{d}", .{g}));
                if (new.len > k) try words.appendSlice(a, new[k..]) else if (old.text) |t| try words.append(a, t);
            }
            var attrs: std.ArrayList(Attr) = .empty;
            for (old.attrs) |x| if (c.attr(x.key) == null) try attrs.append(a, x);
            try attrs.appendSlice(a, c.attrs);
            ops.items[i] = L.CanvasOp.fromParts(a, @tagName(old.kind), words.items, attrs.items, tx.d) catch |e| return tx.dataErr(e);
        } else if (eq(u8, v, "add")) {
            if (c.words.len < 2) return tx.fail(.bad_syntax, "add KIND ID GEOMETRY... [ATTR=VALUE...]", .{});
            if (find(ops.items, c.words[1]) != null) return tx.fail(.in_use, "item {s}", .{c.words[1]});
            try ops.append(a, L.CanvasOp.fromParts(a, c.words[0], c.words[1..], c.attrs, tx.d) catch |e| return tx.dataErr(e));
        } else if (eq(u8, v, "del")) {
            if (c.words.len == 0) return tx.fail(.bad_syntax, "del ID...", .{});
            for (c.words) |id| {
                const i = find(ops.items, id) orelse return tx.fail(.not_found, "item {s}", .{id});
                _ = ops.orderedRemove(i);
            }
        } else {
            if (c.words.len != 1) return tx.fail(.bad_syntax, "{s} ID", .{v});
            const i = find(ops.items, c.words[0]) orelse return tx.fail(.not_found, "item {s}", .{c.words[0]});
            const o = ops.orderedRemove(i);
            if (eq(u8, v, "raise")) try ops.append(a, o) else try ops.insert(a, 0, o);
        }
        var aw: Writer.Allocating = .init(a);
        proto.lines.printLines(&aw.writer, ops.items) catch return error.OutOfMemory;
        tx.quiet += 1;
        defer tx.quiet -= 1;
        try tx.writeNodeFile(h, "ops", aw.written());
        return true;
    }

    fn dataErr(tx: *Tx, e: Error) Error {
        if (e == error.BadSyntax) return tx.fail(.bad_value, "{s}", .{tx.d.detail});
        return e;
    }

    fn typeVerb(tx: *Tx, h: Handle, verb: []const u8, c: Ctl) Error!void {
        const n = tx.node(h);
        if (n.ty.prop("disabled") != null and n.isOn("disabled")) return tx.fail(.disabled, "{s}", .{try tx.relPath(h)});
        const eq = std.mem.eql;
        if (n.ty.tier == .overlay and (eq(u8, verb, "open") or eq(u8, verb, "close"))) {
            try noArgs(tx, c);
            return tx.overlayOpen(h, eq(u8, verb, "open"));
        }
        // A verb that is also the type's action event (`click` on a
        // button) sends it, as the user would.
        if (n.ty.event(verb)) |e| if (e.kind == .action) {
            try tx.event(.{ .name = verb, .node = h, .via = "ctl", .attrs = try tx.a.dupe(Attr, c.attrs) });
        };
        try tx.cmd(.{ .tag = .component_verb, .node = h, .ctl = c });
    }

    /// An overlay opens or closes: its `open` prop, the window's list, and
    /// the renderer.
    fn overlayOpen(tx: *Tx, h: Handle, open: bool) Error!void {
        const n = try tx.mutNode(h);
        if (n.ty.prop("open") != null) {
            try n.putFile(tx.gpa(), "open", try tx.blob(if (open) "on" else "off"), tx.gen);
            n.fileMut("open").?.mirrored = true;
        }
        const w = try tx.mutWin(n.root);
        if (std.mem.indexOfScalar(Handle, w.open.items, h)) |i| _ = w.open.orderedRemove(i);
        if (open) try w.open.append(tx.gpa(), h);
        try tx.cmd(.{ .tag = .overlay, .win = try tx.a.dupe(u8, w.nameStr()), .node = h, .name = try tx.a.dupe(u8, n.nameStr()), .flag = @intFromBool(open) });
    }

    /// A word `'key=value'` that was quoted: still a prop.
    fn quotedAttr(w: []const u8) ?Attr {
        const i = std.mem.indexOfScalar(u8, w, '=') orelse return null;
        const k = w[0..i];
        if (k.len == 0 or !std.ascii.isAlphabetic(k[0]) or k[k.len - 1] == '-') return null;
        for (k) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return null;
        return .{ .key = k, .value = w[i + 1 ..] };
    }

    /// `set PATH [word ...] [prop=value ...] [: style ...]`: each a file
    /// write. On a window's root, window props go to the window.
    fn setProps(tx: *Tx, h: Handle, bare: []const []const u8, attrs: []const Attr, style: ?[]const []const u8) Error!void {
        const n = tx.node(h);
        const is_root = n.parent == 0;
        // tokenize drops quotes, so a quoted `'text=a b'` is still a prop
        // (conformance 04-quoting).
        var all: std.ArrayList(Attr) = .empty;
        for (bare) |w| {
            if (quotedAttr(w)) |at| try all.append(tx.a, at) else try tx.setWord(h, w);
        }
        try all.appendSlice(tx.a, attrs);
        for (all.items) |at| {
            if (is_root) {
                if (std.mem.eql(u8, at.key, "focus")) {
                    try tx.setFocus(h, at.value);
                    continue;
                }
                if (state.inList(&state.win_props, at.key)) {
                    try tx.checkWinProp(at.key, at.value);
                    try tx.setWinProp(h, at.key, at.value);
                    continue;
                }
            }
            if (std.mem.eql(u8, at.key, "type")) return tx.fail(.bad_syntax, "type is the first word of new", .{});
            const name = pathm.nodeFile(tx.st, h, at.key) orelse return tx.fail(.not_found, "{s}/{s}", .{ try tx.fullPath(h), at.key });
            tx.quiet += 1;
            defer tx.quiet -= 1;
            try tx.writeNodeFile(h, name, at.value);
        }
        if (style) |s| {
            const text = try std.mem.join(tx.a, " ", s);
            tx.quiet += 1;
            defer tx.quiet -= 1;
            try tx.writeNodeFile(h, "style", text);
        }
    }

    /// A bare word: a flag turns its bool prop on; a variant or size word
    /// replaces the node's earlier one.
    fn setWord(tx: *Tx, h: Handle, w: []const u8) Error!void {
        const n = tx.node(h);
        var td: types.Diag = .{};
        const word = tx.cat().checkWord(n.ty, w, &td) catch |e| return tx.typesErr(e, &td);
        switch (word.kind) {
            .flag => {
                if (n.ty.prop(word.name)) |p| {
                    tx.quiet += 1;
                    defer tx.quiet -= 1;
                    return tx.writeNodeFile(h, p.name, "on");
                }
                const m = try tx.mutNode(h);
                try m.setWord(tx.gpa(), word.name, .flag);
                m.ver = tx.gen;
            },
            .variant, .size => {
                const m = try tx.mutNode(h);
                try m.setWord(tx.gpa(), word.name, word.kind);
                m.ver = tx.gen;
            },
        }
    }

    /// Writes one node file, after checking it.
    fn writeNodeFile(tx: *Tx, h: Handle, name: []const u8, data: []const u8) Error!void {
        const eq = std.mem.eql;
        const n = tx.node(h);
        if (eq(u8, name, "ctl")) return tx.ctlNode(h, data);
        const p = try tx.filePath(h, name);
        if (eq(u8, name, "tree")) {
            if (data.len > proto.limits.data_file) return tx.fail(.too_large, "tree", .{});
            try tx.logWrite(p, chomp(data), false);
            tx.quiet += 1;
            defer tx.quiet -= 1;
            return tx.writeDoc(h, data);
        }
        if (eq(u8, name, "events") or eq(u8, name, "bounds")) return tx.fail(.bad_value, "read-only: {s}", .{p});
        if (eq(u8, name, "type")) {
            const v = trimmed(data);
            try tx.setType(h, v);
            return tx.logWrite(p, v, false);
        }
        if (eq(u8, name, "order")) {
            try tx.setOrder(h, data);
            return tx.logWrite(p, trimmed(data), false);
        }
        if (n.kind == .over) return tx.fail(.not_found, "{s}", .{p});
        var value = chomp(data);
        if (eq(u8, name, "style")) {
            var td: types.Diag = .{};
            const Ctx = struct {
                st: *const State,
                fn ok(c: @This(), tok: []const u8) bool {
                    return c.st.token(tok) != null;
                }
            };
            if (value.len > proto.limits.text_prop) return tx.fail(.too_large, "style", .{});
            // No type: variant and size words are bare words in 0.2, so a
            // style refuses them on every type.
            tx.cat().checkStyleWith(null, value, &td, Ctx{ .st = tx.st }, Ctx.ok) catch |e| return tx.typesErr(e, &td);
            value = trimmed(value);
        } else if (eq(u8, name, "on")) {
            var it = std.mem.tokenizeAny(u8, value, " \t,");
            while (it.next()) |w| if (!state.inList(&types.element_events, w) and n.ty.event(w) == null)
                return tx.fail(.bad_value, "on: {s}", .{w});
            value = trimmed(value);
        } else if (state.commonName(name) != null) {
            if (value.len > proto.limits.text_prop) return tx.fail(.too_large, "{s}", .{name});
            if (eq(u8, name, "tag") or eq(u8, name, "context")) {
                value = trimmed(value);
                if (std.mem.indexOfAny(u8, value, " \t\n") != null) return tx.fail(.bad_value, "{s}: one word", .{name});
            }
        } else {
            const prop = n.ty.prop(name).?;
            if (prop.form == .bytes) value = data;
            var td: types.Diag = .{};
            tx.cat().checkProp(n.ty, name, value, &td) catch |e| return tx.typesErr(e, &td);
            switch (prop.form) {
                .word, .bool, .number, .choice, .child, .path => value = trimmed(value),
                else => {},
            }
            try tx.checkValue(h, prop, value);
        }
        const secret = eq(u8, name, "value") and tx.isSecret(h);
        try tx.logWrite(p, value, secret);
        const m = try tx.mutNode(h);
        try m.putFile(tx.gpa(), name, try tx.blob(value), tx.gen);
        // A write to a file a state event reports is echoed, via=ctl.
        if (eq(u8, name, "value")) if (n.ty.event("change")) |e| if (e.kind == .state) {
            const short = switch (n.ty.prop("value").?.form) {
                .text, .bytes, .data => false,
                else => true,
            };
            var attrs: []Attr = &.{};
            if (short and !secret) {
                attrs = try tx.a.alloc(Attr, 1);
                attrs[0] = .{ .key = "value", .value = try tx.a.dupe(u8, value) };
            }
            try tx.echo(.{ .name = "change", .node = h, .attrs = attrs });
        };
    }

    /// Checks beyond the form: data files parse in their format, a path
    /// names a node, a child names a child, a value names an item.
    fn checkValue(tx: *Tx, h: Handle, prop: *const types.Prop, value: []const u8) Error!void {
        const n = tx.node(h);
        switch (prop.form) {
            .data => if (n.ty.format(prop.name)) |f| try tx.checkFormat(f, value),
            .path => if (value.len > 0) {
                _ = try pathm.resolveNode(tx.st, tx.a, n.root, value, tx.d);
            },
            .child => if (value.len > 0 and n.children.items.len > 0) {
                if (tx.st.child(h, value) == null) return tx.fail(.not_found, "{s}", .{value});
            },
            else => {},
        }
        // A text `value` on a type whose children are of set types (an
        // accordion's open items) names children (13-layout).
        if (prop.form == .text and value.len > 0 and std.mem.eql(u8, prop.name, "value") and n.ty.child == .types and n.children.items.len > 0) {
            var ws = std.mem.tokenizeAny(u8, value, " \t\n,");
            while (ws.next()) |w| if (tx.st.child(h, w) == null) return tx.fail(.not_found, "{s}", .{w});
        }
        if (value.len > 0 and (std.mem.eql(u8, prop.name, "expanded") or std.mem.eql(u8, prop.name, "value"))) if (n.ty.format("items")) |f| if (std.mem.eql(u8, f, "tree-items")) {
            const items = proto.lines.parseLines(proto.lines.TreeItem, tx.a, n.value("items"), null) catch return;
            if (items.len == 0) return;
            var ws = std.mem.tokenizeAny(u8, value, " \t\n,");
            while (ws.next()) |w| {
                for (items) |it| {
                    if (std.mem.eql(u8, it.id, w)) break;
                } else return tx.fail(.not_found, "item {s}", .{w});
            }
            return;
        };
        if (std.mem.eql(u8, prop.name, "value") and value.len > 0) if (n.ty.format("items")) |f| {
            if (!std.mem.eql(u8, f, "items")) return;
            const items = proto.lines.parseLines(proto.lines.Item, tx.a, n.value("items"), null) catch return;
            var any = false;
            for (items) |it| if (it == .entry) {
                any = true;
            };
            if (!any) return;
            var ws = std.mem.tokenizeAny(u8, value, " \t,");
            while (ws.next()) |w| {
                for (items) |it| switch (it) {
                    .entry => |e| if (std.mem.eql(u8, e.id, w)) break,
                    else => {},
                } else return tx.fail(.not_found, "item {s}", .{w});
            }
        };
    }

    /// A data file that doesn't parse is `bad value` (conformance
    /// 12-data): it is a value, not a command line.
    fn checkFormat(tx: *Tx, f: []const u8, text: []const u8) Error!void {
        tx.checkFormatInner(f, text) catch |e| {
            if (e == error.BadSyntax) return tx.fail(.bad_value, "{s}", .{if (tx.d.detail.len > 0) tx.d.detail else f});
            return e;
        };
        if (std.mem.eql(u8, f, "tree-items")) {
            // Every parent is an item.
            const items = try proto.lines.parseLines(proto.lines.TreeItem, tx.a, text, null);
            for (items) |it| if (it.parent) |par| {
                const found = for (items) |o| {
                    if (std.mem.eql(u8, o.id, par)) break true;
                } else false;
                if (!found) return tx.fail(.not_found, "parent {s}", .{par});
            };
        }
    }

    fn checkFormatInner(tx: *Tx, f: []const u8, text: []const u8) Error!void {
        const L = proto.lines;
        const eq = std.mem.eql;
        const a = tx.a;
        const d = tx.d;
        if (eq(u8, f, "items")) {
            _ = try L.parseLines(L.Item, a, text, d);
        } else if (eq(u8, f, "columns")) {
            _ = try L.parseLines(L.Column, a, text, d);
        } else if (eq(u8, f, "rows")) {
            _ = try L.parseLines(L.Row, a, text, d);
        } else if (eq(u8, f, "tree-items")) {
            _ = try L.parseLines(L.TreeItem, a, text, d);
        } else if (eq(u8, f, "desc-items")) {
            _ = try L.parseLines(L.DescItem, a, text, d);
        } else if (eq(u8, f, "icon-items")) {
            _ = try L.parseLines(L.IconItem, a, text, d);
        } else if (eq(u8, f, "menu")) {
            _ = try L.parseMenu(a, text, d);
        } else if (eq(u8, f, "ops")) {
            _ = try L.parseLines(L.CanvasOp, a, text, d);
        } else if (eq(u8, f, "diagnostics")) {
            _ = try L.parseLines(L.Diagnostic, a, text, d);
        } else if (eq(u8, f, "selection")) {
            if (trimmed(text).len > 0) _ = try L.Selection.parse(a, trimmed(text), d);
        } else if (eq(u8, f, "completions")) {
            if (trimmed(text).len > 0) _ = try L.parseCompletions(a, text, d);
        } else if (eq(u8, f, "messages")) {
            _ = try L.parseMessages(a, text, d);
        } else if (eq(u8, f, "json")) {
            if (trimmed(text).len > 0 and !(std.json.validate(a, text) catch false)) return tx.fail(.bad_value, "not JSON", .{});
        }
    }

    fn setType(tx: *Tx, h: Handle, name: []const u8) Error!void {
        const n = tx.node(h);
        if (std.mem.eql(u8, n.ty.name, name)) return;
        if (n.fixed or n.kind == .over) return tx.fail(.type_is_fixed, "{s}", .{try tx.relPath(h)});
        const ty = try tx.lookupType(name);
        if (n.parent != 0) try tx.checkSlot(n.parent, ty, n.nameStr(), false);
        for (n.children.items) |c| {
            const cn = tx.node(c);
            if (state.isReserved(ty, cn.nameStr(), n.parent == 0)) return tx.fail(.bad_value, "{s}: a child's name is one of its files", .{name});
            var td: types.Diag = .{};
            tx.cat().checkChild(ty, cn.ty.name, cn.nameStr(), &td) catch |e| return tx.typesErr(e, &td);
        }
        const m = try tx.mutNode(h);
        m.ty = ty;
        m.ver = tx.gen;
        // Files the new type doesn't have go.
        var i: usize = 0;
        while (i < m.files.items.len) {
            const f = m.files.items[i];
            if (state.commonName(f.name) != null) {
                i += 1;
            } else if (ty.prop(f.name)) |p| {
                m.files.items[i].name = p.name;
                i += 1;
            } else _ = m.dropFile(tx.gpa(), f.name);
        }
        m.words.clearRetainingCapacity();
    }

    fn setOrder(tx: *Tx, h: Handle, data: []const u8) Error!void {
        const n = tx.node(h);
        var list: std.ArrayList(Handle) = .empty;
        var it = std.mem.tokenizeAny(u8, data, " \t\r\n");
        while (it.next()) |name| {
            const c = tx.st.child(h, name) orelse return tx.fail(.not_found, "{s}", .{name});
            if (n.kind == .node and n.parent == 0 and c == tx.winOf(h).over) return tx.fail(.not_found, "{s}", .{name});
            if (std.mem.indexOfScalar(Handle, list.items, c) != null) return tx.fail(.bad_value, "order: {s} twice", .{name});
            try list.append(tx.a, c);
        }
        const m = try tx.mutNode(h);
        m.order.clearRetainingCapacity();
        try m.order.appendSlice(tx.gpa(), list.items);
        m.ver = tx.gen;
    }

    // ---------------------------------------------------------- documents

    /// Replaces `h`'s subtree with a document whose root line names `h`
    /// (its type and name). A child whose name and type match is kept.
    fn writeDoc(tx: *Tx, h: Handle, text: []const u8) Error!void {
        const d = try proto.doc.parseDiag(tx.a, text, tx.d);
        const n = tx.node(h);
        if (n.kind == .over) return tx.fail(.bad_value, "tree: write each overlay's own tree", .{});
        if (!std.mem.eql(u8, d.name, n.nameStr()) or !std.mem.eql(u8, d.type, n.ty.name))
            return tx.fail(.bad_value, "tree: the document's root is {s} {s}, the node is {s} {s}", .{ d.type, d.name, n.ty.name, n.nameStr() });
        try tx.applyDoc(h, d);
    }

    fn applyDoc(tx: *Tx, h: Handle, d: proto.doc.Node) Error!void {
        for (d.children, 0..) |c, i| for (d.children[0..i]) |b| if (std.mem.eql(u8, b.name, c.name))
            return tx.fail(.in_use, "{s}/{s}", .{ try tx.fullPath(h), c.name });
        // Files the document leaves out go back to their defaults, except
        // component state: state props and files the renderer mirrored.
        {
            const m = try tx.mutNode(h);
            var i: usize = 0;
            while (i < m.files.items.len) {
                const f = m.files.items[i];
                const named = for (d.attrs) |at| {
                    if (std.mem.eql(u8, at.key, f.name)) break true;
                } else for (d.words) |w| {
                    if (std.mem.eql(u8, w, f.name)) break true;
                } else (std.mem.eql(u8, f.name, "style") and d.style != null);
                if (named or f.mirrored or state.inList(&state_props, f.name)) {
                    i += 1;
                } else _ = m.dropFile(tx.gpa(), f.name);
            }
            m.words.clearRetainingCapacity();
            m.ver = tx.gen;
        }
        // Children: drop those not in the document, or of another type.
        const existing = try tx.a.dupe(Handle, tx.node(h).children.items);
        for (existing) |c| {
            const cn = tx.node(c);
            const keep = for (d.children) |dc| {
                if (std.mem.eql(u8, dc.name, cn.nameStr()) and std.mem.eql(u8, dc.type, cn.ty.name)) break true;
            } else false;
            if (!keep) try tx.removeSubtree(c);
        }
        var order: std.ArrayList(Handle) = .empty;
        for (d.children) |dc| {
            const c = tx.st.child(h, dc.name) orelse try tx.createChild(h, try tx.lookupType(dc.type), dc.name, false);
            try tx.applyDoc(c, dc);
            try order.append(tx.a, c);
        }
        {
            const m = try tx.mutNode(h);
            m.children.clearRetainingCapacity();
            try m.children.appendSlice(tx.gpa(), order.items);
            m.order.clearRetainingCapacity();
            try m.order.appendSlice(tx.gpa(), order.items);
        }
        var attrs: std.ArrayList(Attr) = .empty;
        var order_attr: ?[]const u8 = null;
        for (d.attrs) |at| {
            if (std.mem.eql(u8, at.key, "order")) order_attr = at.value else try attrs.append(tx.a, at);
        }
        try tx.setProps(h, d.words, attrs.items, d.style);
        if (order_attr) |o| try tx.setOrder(h, o);
    }

    /// Removes a node and its subtree.
    fn removeSubtree(tx: *Tx, h: Handle) Error!void {
        const n = tx.node(h);
        var list: std.ArrayList(Handle) = .empty;
        try tx.st.subtree(tx.a, h, &list);
        const p = try tx.mutNode(n.parent);
        if (std.mem.indexOfScalar(Handle, p.children.items, h)) |i| _ = p.children.orderedRemove(i);
        if (std.mem.indexOfScalar(Handle, p.order.items, h)) |i| _ = p.order.orderedRemove(i);
        p.ver = tx.gen;
        // The window forgets them: focus, open overlays.
        if (tx.st.winOfRoot(n.root)) |w| {
            var touch = std.mem.indexOfScalar(Handle, list.items, w.focus) != null;
            for (w.open.items) |o| if (std.mem.indexOfScalar(Handle, list.items, o) != null) {
                touch = true;
            };
            if (touch) {
                const mw = try tx.mutWin(w.root);
                if (std.mem.indexOfScalar(Handle, list.items, mw.focus) != null) {
                    mw.focus = 0;
                    mw.focus_ver = tx.gen;
                }
                var i: usize = 0;
                while (i < mw.open.items.len) {
                    if (std.mem.indexOfScalar(Handle, list.items, mw.open.items[i]) != null) {
                        _ = mw.open.orderedRemove(i);
                    } else i += 1;
                }
            }
        }
        try tx.dropNodes(list.items);
    }

    /// Takes the nodes out of the maps.
    fn dropNodes(tx: *Tx, list: []const Handle) Error!void {
        for (list) |x| {
            const kv = tx.st.nodes.fetchRemove(x) orelse continue;
            const xn = kv.value;
            if (xn.parent != 0) _ = tx.st.kids.remove(.{ .parent = xn.parent, .name = xn.nameStr() });
            xn.unref(tx.gpa());
        }
    }
};

fn noArgs(tx: *Tx, c: Ctl) Error!void {
    if (c.words.len > 0 or c.attrs.len > 0) return tx.fail(.bad_syntax, "{s} takes no arguments", .{c.verb});
}

/// The request answers (core.md § Requests).
pub const answers = [_][]const u8{ "close", "keep", "accept", "refuse" };

/// Menu roles for 1.0 (core.md § Default menus).
pub const menu_roles = [_][]const u8{
    "about",  "services", "hide",      "hide-others", "show-all",   "quit",   "undo",        "redo",
    "cut",    "copy",     "paste",     "paste-plain", "delete",     "select-all", "minimize", "zoom",
    "fullscreen", "close", "front", "window-list", "help-search",
};

pub const Snapshot = @import("snapshot.zig").Snapshot;

// The doc module needs these.
pub const TxApi = Tx;
