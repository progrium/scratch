//! The C ABI, include/uitcore.h. Owner: the spike (W0) writes and freezes
//! it; after the freeze a change needs a bump of UIT_ABI_VERSION and a note
//! to every renderer workstream.
//!
//! Rules (ARCHITECTURE.md § The ABI): one owner thread; the core wakes, the
//! renderer pumps; borrowed reads valid until the next uit_pump; no
//! callbacks into the renderer during a pump except wake; errors are
//! negative codes plus uit_last_error; panics abort, nothing unwinds.
//!
//! Version 1, backed by the tree (W3): the owner thread owns the `Tree`;
//! 9P threads reach it through ninep/ns.zig's `TreeFs`, the `OpQueue` and
//! published snapshots. Reads here come from the state the last pump
//! pinned, so input calls between pumps (which change the tree at once)
//! never invalidate what the renderer borrowed.

const std = @import("std");
const builtin = @import("builtin");
const treem = @import("tree/root.zig");
const types = @import("types/root.zig");
const proto = @import("proto/root.zig");
const machine = @import("machine/root.zig");
const ninep = @import("ninep/root.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Must match UIT_ABI_VERSION in include/uitcore.h.
pub const abi_version: u32 = 1;

// ---------------------------------------------------------------------
// The header's types. Keep in step with include/uitcore.h; the test at
// the bottom checks the constants, renderer/gpui's sizes test the layout.

pub const UitNode = u32;

pub const UitStr = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn of(s: []const u8) UitStr {
        return .{ .ptr = if (s.len == 0) null else s.ptr, .len = s.len };
    }
    pub fn lit(comptime s: []const u8) UitStr {
        return .{ .ptr = s.ptr, .len = s.len };
    }
    pub fn slice(s: UitStr) []const u8 {
        return if (s.ptr) |p| p[0..s.len] else "";
    }
};

pub const UitAttr = extern struct { name: UitStr = .{}, value: UitStr = .{} };

pub const UIT_OK: c_int = 0;
pub const UIT_EINVAL: c_int = -1;
pub const UIT_ENOMEM: c_int = -2;
pub const UIT_ENOTFOUND: c_int = -3;
pub const UIT_EINUSE: c_int = -4;
pub const UIT_EBADVALUE: c_int = -5;
pub const UIT_ETHREAD: c_int = -6;
pub const UIT_ENOTSUP: c_int = -7;
pub const UIT_EGONE: c_int = -8;
pub const UIT_EVERSION: c_int = -9;
pub const UIT_EIO: c_int = -10;
pub const UIT_ETYPES: c_int = -11;

pub const UitConfig = extern struct {
    abi_version: u32,
    types: UitStr,
    style_words: UitStr,
    theme_tokens: UitStr,
    system_dark: u32,
    wake: ?*const fn (?*anyopaque) callconv(.c) void,
    wake_ctx: ?*anyopaque,
};

pub const UitMachineArgs = extern struct {
    prog: UitStr,
    argv: ?[*]const UitStr,
    argc: usize,
    root: UitStr,
    cwd: UitStr,
    dirs: ?[*]const UitStr,
    n_dirs: usize,
    env: ?[*]const UitStr,
    n_env: usize,
    h9_flags: ?[*]const UitStr,
    n_h9_flags: usize,
    out_fd: c_int,
    err_fd: c_int,
};

pub const UitPropChange = extern struct { node: UitNode, file: UitStr };

pub const UIT_CMD_WINDOW: u32 = 1;
pub const UIT_CMD_WINDOW_CTL: u32 = 2;
pub const UIT_CMD_QUIT: u32 = 3;
pub const UIT_CMD_MENUS: u32 = 4;
pub const UIT_CMD_KEYMAP: u32 = 5;
pub const UIT_CMD_THEME: u32 = 6;
pub const UIT_CMD_SET_ACTION: u32 = 7;
pub const UIT_CMD_OVERLAY: u32 = 8;
pub const UIT_CMD_FOCUS: u32 = 9;
pub const UIT_CMD_CLIPBOARD: u32 = 10;
pub const UIT_CMD_COMPONENT_VERB: u32 = 11;
pub const UIT_CMD_ANSWER: u32 = 12;
pub const UIT_CMD_REDRAW: u32 = 13;
pub const UIT_CMD_THEME_LOAD: u32 = 14;

pub const UitCtl = extern struct {
    verb: UitStr = .{},
    args: ?[*]const UitStr = null,
    n_args: usize = 0,
    attrs: ?[*]const UitAttr = null,
    n_attrs: usize = 0,
};

pub const UitHostCmd = extern struct {
    tag: u32,
    win: UitStr = .{},
    node: UitNode = 0,
    name: UitStr = .{},
    ctl: UitCtl = .{},
    seq: u64 = 0,
    flag: i32 = 0,
    flag2: i32 = 0,
    answer: UitStr = .{},
};

pub const UitChanges = extern struct {
    dirty_windows: ?[*]const UitStr = null,
    n_dirty: usize = 0,
    created: ?[*]const UitNode = null,
    n_created: usize = 0,
    removed: ?[*]const UitNode = null,
    n_removed: usize = 0,
    props: ?[*]const UitPropChange = null,
    n_props: usize = 0,
    cmds: ?[*]const UitHostCmd = null,
    n_cmds: usize = 0,
    exited: i32 = 0,
    exit_status: UitStr = .{},
};

pub const UIT_ARG_NONE: u32 = 0;
pub const UIT_ARG_PX: u32 = 1;
pub const UIT_ARG_PERCENT: u32 = 2;
pub const UIT_ARG_REM: u32 = 3;
pub const UIT_ARG_NUMBER: u32 = 4;
pub const UIT_ARG_RGBA: u32 = 5;
pub const UIT_ARG_TEXT: u32 = 6;

pub const UitStyleArg = extern struct {
    kind: u32 = UIT_ARG_NONE,
    a: f32 = 0,
    rgba: u32 = 0,
    text: UitStr = .{},
};

pub const UIT_STATE_BASE: u32 = 0;
pub const UIT_STATE_HOVER: u32 = 1;
pub const UIT_STATE_ACTIVE: u32 = 2;
pub const UIT_STATE_FOCUS: u32 = 3;
pub const UIT_STATE_DISABLED: u32 = 4;
pub const UIT_STATE_DROP_OVER: u32 = 5;
pub const UIT_STATE_GROUP_HOVER: u32 = 6;

pub const UitStyleWord = extern struct {
    name: UitStr = .{},
    state: u32 = UIT_STATE_BASE,
    group: UitStr = .{},
    args: ?[*]const UitStyleArg = null,
    n_args: usize = 0,
};

pub const UitLine = extern struct { fields: ?[*]const UitStr, n_fields: usize, indent: u32 };
pub const UitLines = extern struct { lines: ?[*]const UitLine, n: usize };

pub const UitKeyBinding = extern struct { keystroke: UitStr, action: UitStr, context: UitStr, global: u32 };

pub const UitMenuItem = extern struct {
    kind: u32,
    depth: u32,
    id: UitStr,
    label: UitStr,
    key: UitStr,
    icon: UitStr,
    role: UitStr,
    menu: UitStr,
    enabled: i32,
    check: i32,
};

pub const UitDragMsg = extern struct {
    kind: u32,
    drag: u64,
    node: UitNode,
    x: f32,
    y: f32,
    attrs: ?[*]const UitAttr,
    n_attrs: usize,
};

// ---------------------------------------------------------------------
// ---------------------------------------------------------------------
// The core

pub const Core = struct {
    gpa: Allocator,
    threaded: Io.Threaded,
    owner: std.Thread.Id,
    cat: types.Catalog,
    tree: *treem.Tree,
    queue: treem.OpQueue,
    tfs: ninep.ns.TreeFs = undefined,
    wake_fn: ?*const fn (?*anyopaque) callconv(.c) void,
    wake_ctx: ?*anyopaque,
    /// Set from any thread by uit_shutdown; the next pump tells the tree.
    gone: std.atomic.Value(bool) = .init(false),
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,
    /// The 9P server, listeners and mounts (W4), made on first use.
    host: ?*ninep.host.Host = null,
    runner: ?*machine.Runner = null,
    /// The machine's exit, from its thread, under `exit_mu`.
    exit_mu: Io.Mutex = .init,
    exited: bool = false,
    exit_status: ?[]u8 = null,
    /// Borrowed results of reads, freed at the next pump.
    reads: std.heap.ArenaAllocator,
    /// The state reads come from: what the renderer draws, pinned at the
    /// last pump.
    pinned: ?*treem.state.State = null,
    styles: std.AutoHashMapUnmanaged(treem.Handle, []const UitStyleWord) = .empty,
    next_drag: u64 = 1,
    /// Wakes the renderer while a batch or a request has a deadline.
    timer: ?std.Thread = null,
    timers_due: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn io(c: *Core) Io {
        return c.threaded.io();
    }

    pub fn wake(c: *Core) void {
        if (c.wake_fn) |f| f(c.wake_ctx);
    }

    fn wakeQueue(ctx: ?*anyopaque) void {
        const c: *Core = @ptrCast(@alignCast(ctx.?));
        c.wake();
    }

    /// The core's 9P host, serving the tree. A host (uitree-headless)
    /// mounts its own directories on it before anything connects.
    pub fn getHost(c: *Core) !*ninep.host.Host {
        if (c.host) |h| return h;
        c.tfs = .{ .gpa = c.gpa, .t = c.tree, .q = &c.queue };
        c.host = try ninep.host.Host.create(c.gpa, c.io(), c.tfs.fs());
        return c.host.?;
    }

    /// Moves the tree's clock forward (`/debug/inject tick`); runs what
    /// falls due. Owner thread.
    pub fn advanceClock(c: *Core, ns: u64) void {
        c.tree.advanceClock(ns) catch {};
        c.wake();
    }

    fn setText(c: *Core, s: []const u8) void {
        const n = @min(s.len, c.err_buf.len);
        @memcpy(c.err_buf[0..n], s[0..n]);
        c.err_len = n;
    }

    /// A tree error as a UitErr, with its text for uit_last_error.
    fn fail(c: *Core, e: anyerror) c_int {
        if (e == error.OutOfMemory) {
            c.setText("out of memory");
            return UIT_ENOMEM;
        }
        const code = proto.Code.fromError(e) orelse {
            c.setText(@errorName(e));
            return UIT_EINVAL;
        };
        const last = c.tree.lastError();
        c.setText(if (last.len > 0) last else code.phrase());
        return switch (code) {
            .not_found, .gone => UIT_ENOTFOUND,
            .in_use => UIT_EINUSE,
            .app_gone => UIT_EGONE,
            .unsupported => UIT_ENOTSUP,
            else => UIT_EBADVALUE,
        };
    }

    fn checkOwner(c: *Core) bool {
        if (builtin.mode == .Debug) std.debug.assert(std.Thread.getCurrentId() == c.owner);
        return std.Thread.getCurrentId() == c.owner;
    }

    fn st(c: *Core) *const treem.state.State {
        return c.pinned orelse c.tree.committed();
    }

    fn node(c: *Core, h: UitNode) ?*const treem.state.Node {
        return c.st().node(h);
    }

    fn timerLoop(c: *Core) void {
        while (!c.stopping.load(.acquire)) {
            c.io().sleep(.fromMilliseconds(100), .awake) catch {};
            if (c.timers_due.load(.acquire) and !c.stopping.load(.acquire)) c.wake();
        }
    }
};

fn monoNow(c: *Core) u64 {
    const ns = Io.Clock.awake.now(c.io()).nanoseconds;
    return if (ns < 0) 0 else @intCast(ns);
}

const gpa_default = std.heap.c_allocator;

// ---------------------------------------------------------------------
// Exports: lifecycle

export fn uit_abi_version() u32 {
    return abi_version;
}

export fn uit_create(cfg: ?*const UitConfig, out: ?*?*Core) c_int {
    const c_cfg = cfg orelse return UIT_EINVAL;
    const o = out orelse return UIT_EINVAL;
    if (c_cfg.abi_version != abi_version) return UIT_EVERSION;
    const gpa = gpa_default;
    const c = gpa.create(Core) catch return UIT_ENOMEM;
    c.* = .{
        .gpa = gpa,
        .threaded = .init(gpa, .{}),
        .owner = std.Thread.getCurrentId(),
        .cat = undefined,
        .tree = undefined,
        .queue = undefined,
        .wake_fn = c_cfg.wake,
        .wake_ctx = c_cfg.wake_ctx,
        .reads = .init(gpa),
    };
    const r = create(c, c_cfg);
    if (r != UIT_OK) {
        c.reads.deinit();
        c.threaded.deinit();
        gpa.destroy(c);
        return r;
    }
    o.* = c;
    return UIT_OK;
}

fn create(c: *Core, cfg: *const UitConfig) c_int {
    c.cat = types.Catalog.builtin(c.gpa) catch return UIT_ENOMEM;
    // I6: every type the renderer draws must be one the core has.
    if (cfg.types.len > 0) {
        var d: types.Diag = .{};
        _ = c.cat.checkRegistered(c.gpa, cfg.types.slice(), &d) catch |e| {
            c.cat.deinit();
            return if (e == error.OutOfMemory) UIT_ENOMEM else UIT_ETYPES;
        };
    }
    if (cfg.style_words.len > 0) c.cat.loadStyleWords(cfg.style_words.slice()) catch {
        c.cat.deinit();
        return UIT_EBADVALUE;
    };
    if (cfg.theme_tokens.len > 0) c.cat.loadThemeTokens(cfg.theme_tokens.slice()) catch {
        c.cat.deinit();
        return UIT_EBADVALUE;
    };
    c.tree = treem.Tree.create(c.gpa, c.io(), &c.cat, .{ .system_dark = cfg.system_dark != 0 }) catch {
        c.cat.deinit();
        return UIT_ENOMEM;
    };
    c.queue = .init(c.gpa, c.io());
    c.queue.wake = Core.wakeQueue;
    c.queue.wake_ctx = c;
    c.tree.publish() catch {};
    c.timer = std.Thread.spawn(.{}, Core.timerLoop, .{c}) catch null;
    return UIT_OK;
}

export fn uit_serve_fd(c: *Core, fd: c_int) c_int {
    if (comptime builtin.os.tag == .windows) return UIT_ENOTSUP;
    const h = c.getHost() catch return UIT_ENOMEM;
    h.serveFd(fd) catch return UIT_EIO;
    return UIT_OK;
}

export fn uit_listen(c: *Core, addr: UitStr, dial: ?*UitStr) c_int {
    if (comptime builtin.os.tag == .windows) return UIT_ENOTSUP;
    if (!c.checkOwner()) return UIT_ETHREAD;
    const h = c.getHost() catch return UIT_ENOMEM;
    const ds = (if (addr.len == 0) h.privateDial() else h.listen(addr.slice())) catch |e| {
        c.err_len = if (std.fmt.bufPrint(&c.err_buf, "listen: {t}", .{e})) |m| m.len else |_| 0;
        return UIT_EIO;
    };
    if (dial) |d| d.* = UitStr.of(ds);
    return UIT_OK;
}

export fn uit_run_machine(c: *Core, args: ?*const UitMachineArgs) c_int {
    if (!c.checkOwner()) return UIT_ETHREAD;
    const a = args orelse return UIT_EINVAL;
    if (!machine.available) {
        c.setText("built without h9 (-Dh9=true)");
        return UIT_ENOTSUP;
    }
    if (c.runner != null) return UIT_EINUSE;
    const h = c.getHost() catch return UIT_ENOMEM;
    const sock = h.privatePath() catch return UIT_EIO;
    c.runner = machine.Runner.start(c.gpa, a, sock, @ptrCast(c), onExit) catch |e| {
        c.err_len = if (std.fmt.bufPrint(&c.err_buf, "machine: {t}", .{e})) |s| s.len else |_| 0;
        return UIT_EIO;
    };
    return UIT_OK;
}

/// From the machine's thread when the client ends.
fn onExit(ctx: *anyopaque, status: []const u8) void {
    const c: *Core = @ptrCast(@alignCast(ctx));
    c.exit_mu.lockUncancelable(c.io());
    if (c.exit_status) |s| c.gpa.free(s);
    c.exit_status = c.gpa.dupe(u8, status) catch null;
    c.exited = true;
    c.exit_mu.unlock(c.io());
    c.wake();
}

export fn uit_shutdown(c: *Core) void {
    if (c.gone.swap(true, .acq_rel)) return;
    c.queue.close();
    c.tree.bus.shutDown();
    if (c.runner) |r| r.hangup();
    c.wake();
}

export fn uit_destroy(c: *Core) void {
    uit_shutdown(c);
    c.stopping.store(true, .release);
    if (c.timer) |t| t.join();
    if (c.runner) |r| r.join();
    // Hangs up every connection and waits for them: nothing holds a
    // subscription or a snapshot after this.
    if (c.host) |h| h.destroy();
    c.queue.deinit();
    if (c.pinned) |p| p.unref(c.gpa);
    c.styles.deinit(c.gpa);
    c.tree.destroy();
    c.cat.deinit();
    if (c.exit_status) |s| c.gpa.free(s);
    c.reads.deinit();
    c.threaded.deinit();
    c.gpa.destroy(c);
}

export fn uit_last_error(c: *Core) UitStr {
    return UitStr.of(c.err_buf[0..c.err_len]);
}

export fn uit_wake_renderer(c: *Core) void {
    c.wake();
}

// ---------------------------------------------------------------------
// Pump

fn ptrOf(comptime T: type, s: []const T) ?[*]const T {
    return if (s.len > 0) s.ptr else null;
}

export fn uit_pump(c: *Core, out: ?*UitChanges) c_int {
    if (!c.checkOwner()) return UIT_ETHREAD;
    const o = out orelse return UIT_EINVAL;
    _ = c.reads.reset(.retain_capacity);
    c.styles.clearRetainingCapacity();
    const t = c.tree;
    if (c.gone.load(.acquire) and !t.current().gone) t.appGone();
    _ = c.queue.drain(t);
    t.tick(monoNow(c)) catch {};
    t.publish() catch {};
    var buf: [1]u64 = undefined;
    c.timers_due.store(t.batchOpen() or t.openRequests(&buf) > 0, .release);

    // Pin what the renderer draws until the next pump.
    const now: *treem.state.State = @constCast(t.committed());
    if (c.pinned != now) {
        if (c.pinned) |p| p.unref(c.gpa);
        c.pinned = now.ref();
    }

    o.* = .{};
    const r = fillChanges(c, o);
    t.clearChanges();
    if (r != UIT_OK) return r;
    c.exit_mu.lockUncancelable(c.io());
    defer c.exit_mu.unlock(c.io());
    if (c.exited) {
        c.exited = false;
        o.exited = 1;
        o.exit_status = UitStr.of(c.reads.allocator().dupe(u8, c.exit_status orelse "") catch "");
    }
    return UIT_OK;
}

fn dupStr(a: Allocator, s: []const u8) Allocator.Error!UitStr {
    return UitStr.of(try a.dupe(u8, s));
}

fn fillChanges(c: *Core, o: *UitChanges) c_int {
    const a = c.reads.allocator();
    const ch = c.tree.changes() catch return UIT_ENOMEM;
    fill(a, ch, o) catch return UIT_ENOMEM;
    return UIT_OK;
}

fn fill(a: Allocator, ch: treem.Changes, o: *UitChanges) Allocator.Error!void {
    const dirty = try a.alloc(UitStr, ch.dirty.len);
    for (ch.dirty, dirty) |d, *x| x.* = try dupStr(a, d);
    const created = try a.dupe(UitNode, ch.created);
    const removed = try a.dupe(UitNode, ch.removed);
    const props = try a.alloc(UitPropChange, ch.props.len);
    for (ch.props, props) |p, *x| x.* = .{ .node = p.node, .file = try dupStr(a, p.file) };
    const cmds = try a.alloc(UitHostCmd, ch.cmds.len);
    for (ch.cmds, cmds) |hc, *x| {
        const args = try a.alloc(UitStr, hc.ctl.words.len);
        for (hc.ctl.words, args) |w, *y| y.* = try dupStr(a, w);
        const attrs = try a.alloc(UitAttr, hc.ctl.attrs.len);
        for (hc.ctl.attrs, attrs) |at, *y| y.* = .{ .name = try dupStr(a, at.key), .value = try dupStr(a, at.value) };
        x.* = .{
            .tag = @intFromEnum(hc.tag),
            .win = try dupStr(a, hc.win),
            .node = hc.node,
            .name = try dupStr(a, hc.name),
            .ctl = .{
                .verb = try dupStr(a, hc.ctl.verb),
                .args = ptrOf(UitStr, args),
                .n_args = args.len,
                .attrs = ptrOf(UitAttr, attrs),
                .n_attrs = attrs.len,
            },
            .seq = hc.seq,
            .flag = hc.flag,
            .flag2 = hc.flag2,
            .answer = try dupStr(a, hc.answer),
        };
    }
    o.dirty_windows = ptrOf(UitStr, dirty);
    o.n_dirty = dirty.len;
    o.created = ptrOf(UitNode, created);
    o.n_created = created.len;
    o.removed = ptrOf(UitNode, removed);
    o.n_removed = removed.len;
    o.props = ptrOf(UitPropChange, props);
    o.n_props = props.len;
    o.cmds = ptrOf(UitHostCmd, cmds);
    o.n_cmds = cmds.len;
}

// ---------------------------------------------------------------------
// Tree reads: from the state pinned at the last pump

export fn uit_windows(c: *Core, out: ?*?[*]const UitStr) usize {
    const s = c.st();
    var names: std.ArrayList(UitStr) = .empty;
    for (s.wins.items) |w| if (!w.hidden) names.append(c.reads.allocator(), UitStr.of(w.nameStr())) catch return 0;
    if (out) |o| o.* = ptrOf(UitStr, names.items);
    return names.items.len;
}

export fn uit_window_root(c: *Core, win: UitStr) UitNode {
    const w = c.st().win(win.slice()) orelse return 0;
    return w.root;
}

export fn uit_children(c: *Core, h: UitNode, out: ?*?[*]const UitNode) usize {
    const n = c.node(h) orelse return 0;
    // `order`: a child it leaves out is not drawn (core.md § Nodes).
    if (out) |o| o.* = ptrOf(UitNode, n.order.items);
    return n.order.items.len;
}

export fn uit_overlays(c: *Core, win: UitStr, out: ?*?[*]const UitNode) usize {
    const w = c.st().win(win.slice()) orelse return 0;
    if (out) |o| o.* = ptrOf(UitNode, w.open.items);
    return w.open.items.len;
}

export fn uit_type(c: *Core, h: UitNode) UitStr {
    const n = c.node(h) orelse return .{};
    return UitStr.of(n.ty.name);
}

export fn uit_path(c: *Core, h: UitNode) UitStr {
    _ = c.node(h) orelse return .{};
    const p = c.st().relPathAlloc(c.reads.allocator(), h) catch return .{};
    return UitStr.of(p);
}

export fn uit_window_of(c: *Core, h: UitNode) UitStr {
    const w = c.st().winOf(h) orelse return .{};
    return UitStr.of(w.nameStr());
}

export fn uit_prop(c: *Core, h: UitNode, file: UitStr, out: ?*UitStr) c_int {
    const n = c.node(h) orelse return UIT_EINVAL;
    const name = file.slice();
    const v: ?[]const u8 = n.stored(name) orelse wordProp(n, name) orelse winProp(c, n, name);
    const val = v orelse return 0;
    if (out) |o| o.* = UitStr.of(val);
    return 1;
}

/// `variant` and `size`: the node's bare word of that kind (`primary`).
fn wordProp(n: *const treem.state.Node, name: []const u8) ?[]const u8 {
    const kind: types.WordKind = if (std.mem.eql(u8, name, "variant")) .variant else if (std.mem.eql(u8, name, "size")) .size else return null;
    for (n.words.items) |w| if (w.kind == kind) return w.name;
    return null;
}

/// A window's props read through its root (`title`, `size`, `state`,
/// `focus`), unless the root has its own file of that name.
fn winProp(c: *Core, n: *const treem.state.Node, name: []const u8) ?[]const u8 {
    if (n.parent != 0) return null;
    const w = c.st().winOfRoot(n.id) orelse return null;
    if (std.mem.eql(u8, name, "state")) return @tagName(w.shownState());
    if (std.mem.eql(u8, name, "focus")) {
        if (w.focus == 0) return null;
        return c.st().relPathAlloc(c.reads.allocator(), w.focus) catch null;
    }
    return w.prop(name);
}

// ---- style

fn parseColor(s: []const u8) ?u32 {
    if (s.len < 2 or s[0] != '#') return null;
    const hex = s[1..];
    var v: u32 = switch (hex.len) {
        6, 8 => std.fmt.parseInt(u32, hex, 16) catch return null,
        3, 4 => blk: {
            var x: u32 = 0;
            for (hex) |ch| {
                const d = std.fmt.charToDigit(ch, 16) catch return null;
                x = (x << 8) | (d * 17);
            }
            break :blk x;
        },
        else => return null,
    };
    if (hex.len == 6 or hex.len == 3) v = (v << 8) | 0xff;
    return v;
}

/// A theme token's value for the mode in effect: the app's `theme/tokens`
/// first, then the catalog's.
fn tokenText(c: *Core, name: []const u8) ?[]const u8 {
    const s = c.st();
    if (s.token(name)) |v| return v;
    for (c.cat.theme_tokens) |t| if (std.mem.eql(u8, t.name, name)) return if (s.dark()) t.dark else t.light;
    return null;
}

fn styleArg(c: *Core, kind: types.style.ArgKind, x: []const u8) UitStyleArg {
    if (parseColor(x)) |v| return .{ .kind = UIT_ARG_RGBA, .rgba = v };
    if (kind == .color or kind == .shadow) if (tokenText(c, x)) |tv| {
        if (parseColor(tv)) |v| return .{ .kind = UIT_ARG_RGBA, .rgba = v, .text = UitStr.of(x) };
    };
    if (kind == .text or kind == .variant or kind == .size) return .{ .kind = UIT_ARG_TEXT, .text = UitStr.of(x) };
    if (std.mem.endsWith(u8, x, "%")) {
        if (std.fmt.parseFloat(f32, x[0 .. x.len - 1])) |f| return .{ .kind = UIT_ARG_PERCENT, .a = f } else |_| {}
    }
    if (std.mem.endsWith(u8, x, "rem")) {
        if (std.fmt.parseFloat(f32, x[0 .. x.len - 3])) |f| return .{ .kind = UIT_ARG_REM, .a = f } else |_| {}
    }
    if (std.mem.endsWith(u8, x, "px")) {
        if (std.fmt.parseFloat(f32, x[0 .. x.len - 2])) |f| return .{ .kind = UIT_ARG_PX, .a = f } else |_| {}
    }
    if (std.fmt.parseFloat(f32, x)) |f| return .{ .kind = if (kind == .number) UIT_ARG_NUMBER else UIT_ARG_PX, .a = f } else |_| {}
    // A length token (`radius`).
    if (tokenText(c, x)) |tv| if (std.fmt.parseFloat(f32, tv)) |f| return .{ .kind = UIT_ARG_PX, .a = f, .text = UitStr.of(x) } else |_| {};
    return .{ .kind = UIT_ARG_TEXT, .text = UitStr.of(x) };
}

/// The node's variant and size words (`primary`, `sm`) first, as
/// base-state words with no args, then its `style` file's words.
fn buildStyle(c: *Core, n: *const treem.state.Node) ![]const UitStyleWord {
    const a = c.reads.allocator();
    const words = try types.style.parse(a, n.value("style"));
    var nw: usize = 0;
    for (n.words.items) |w| if (w.kind != .flag) {
        nw += 1;
    };
    const all = try a.alloc(UitStyleWord, nw + words.len);
    var i: usize = 0;
    for (n.words.items) |w| if (w.kind != .flag) {
        all[i] = .{ .name = UitStr.of(w.name) };
        i += 1;
    };
    const out = all[nw..];
    for (words, out) |w, *o| {
        const kind: types.style.ArgKind = if (c.cat.styleWord(w.name)) |e| e.arg else .length;
        const args = try a.alloc(UitStyleArg, w.args.len);
        for (w.args, args) |x, *y| y.* = styleArg(c, kind, x);
        var state: u32 = UIT_STATE_BASE;
        if (w.state) |s| state = switch (s) {
            .hover => UIT_STATE_HOVER,
            .active => UIT_STATE_ACTIVE,
            .focus => UIT_STATE_FOCUS,
            .disabled => UIT_STATE_DISABLED,
            .@"drop-over" => UIT_STATE_DROP_OVER,
        };
        var group: []const u8 = w.group orelse "";
        if (w.group_hover) |g| {
            state = UIT_STATE_GROUP_HOVER;
            group = g;
        }
        o.* = .{ .name = UitStr.of(w.name), .state = state, .group = UitStr.of(group), .args = ptrOf(UitStyleArg, args), .n_args = args.len };
    }
    return all;
}

export fn uit_style(c: *Core, h: UitNode, out: ?*?[*]const UitStyleWord, n_out: ?*usize) c_int {
    const n = c.node(h) orelse return UIT_EINVAL;
    const ws = c.styles.get(h) orelse blk: {
        const built = buildStyle(c, n) catch |e| return if (e == error.OutOfMemory) UIT_ENOMEM else UIT_EBADVALUE;
        c.styles.put(c.gpa, h, built) catch return UIT_ENOMEM;
        break :blk built;
    };
    if (out) |o| o.* = ptrOf(UitStyleWord, ws);
    if (n_out) |k| k.* = ws.len;
    return UIT_OK;
}

// ---- data files, keys, menus, theme

export fn uit_lines(c: *Core, h: UitNode, file: UitStr, out: ?*UitLines) c_int {
    const n = c.node(h) orelse return UIT_EINVAL;
    const a = c.reads.allocator();
    var lines: std.ArrayList(UitLine) = .empty;
    var it = std.mem.splitScalar(u8, n.value(file.slice()), '\n');
    while (it.next()) |raw| {
        var l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len == 0) continue;
        var indent: u32 = 0;
        while (true) {
            if (std.mem.startsWith(u8, l, "  ")) {
                l = l[2..];
            } else if (l[0] == '\t' and std.mem.indexOfScalar(u8, l[1..], '\t') == null and l.len > 1 and l[1] == '\t') {
                l = l[1..];
            } else break;
            indent += 1;
            if (l.len == 0) break;
        }
        const fs = proto.lines.fields(a, l, null) catch |e| return if (e == error.OutOfMemory) UIT_ENOMEM else UIT_EBADVALUE;
        const strs = a.alloc(UitStr, fs.len) catch return UIT_ENOMEM;
        for (fs, strs) |f, *s| s.* = UitStr.of(f);
        lines.append(a, .{ .fields = ptrOf(UitStr, strs), .n_fields = strs.len, .indent = indent }) catch return UIT_ENOMEM;
    }
    if (out) |o| o.* = .{ .lines = ptrOf(UitLine, lines.items), .n = lines.items.len };
    return UIT_OK;
}

export fn uit_keys(c: *Core, out: ?*?[*]const UitKeyBinding, n: ?*usize) c_int {
    const a = c.reads.allocator();
    var ks: std.ArrayList(UitKeyBinding) = .empty;
    var it = std.mem.splitScalar(u8, treem.state.Blob.str(c.st().keys), '\n');
    while (it.next()) |l| {
        if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
        const b = proto.lines.KeyBinding.parse(a, l, null) catch continue;
        const stroke = std.mem.join(a, " ", b.keys) catch return UIT_ENOMEM;
        ks.append(a, .{ .keystroke = UitStr.of(stroke), .action = UitStr.of(b.action), .context = UitStr.of(b.context() orelse ""), .global = @intFromBool(b.global) }) catch return UIT_ENOMEM;
    }
    if (out) |o| o.* = ptrOf(UitKeyBinding, ks.items);
    if (n) |x| x.* = ks.items.len;
    return UIT_OK;
}

export fn uit_menu_bar(c: *Core, out: ?*?[*]const UitStr) usize {
    const a = c.reads.allocator();
    var names: std.ArrayList(UitStr) = .empty;
    var it = std.mem.tokenizeAny(u8, treem.state.Blob.str(c.st().bar), " \t\r\n");
    while (it.next()) |w| names.append(a, UitStr.of(w)) catch return 0;
    if (out) |o| o.* = ptrOf(UitStr, names.items);
    return names.items.len;
}

export fn uit_menu(c: *Core, name: UitStr, out: ?*?[*]const UitMenuItem, n: ?*usize) c_int {
    const a = c.reads.allocator();
    const m = c.st().menu(name.slice()) orelse return UIT_ENOTFOUND;
    const ls = proto.lines.parseMenu(a, m.val.bytes, null) catch |e| return if (e == error.OutOfMemory) UIT_ENOMEM else UIT_EBADVALUE;
    const items = a.alloc(UitMenuItem, ls.len) catch return UIT_ENOMEM;
    for (ls, items) |l, *o| {
        const check: i32 = if (l.attr("check")) |v|
            (if (std.mem.eql(u8, v, "on")) 1 else if (std.mem.eql(u8, v, "mixed")) 2 else 0)
        else
            -1;
        const off = if (l.attr("enabled")) |v| std.mem.eql(u8, v, "off") else false;
        o.* = .{
            .kind = switch (l.kind) {
                .item => UIT_MENU_ITEM,
                .sep => UIT_MENU_SEP,
                .sub => UIT_MENU_SUB,
            },
            .depth = @intCast(l.depth),
            .id = UitStr.of(if (l.kind == .sub) "-" else if (l.id.len == 0) "-" else l.id),
            .label = UitStr.of(l.attr("label") orelse ""),
            .key = UitStr.of(l.attr("key") orelse ""),
            .icon = UitStr.of(l.attr("icon") orelse ""),
            .role = UitStr.of(l.attr("role") orelse ""),
            .menu = UitStr.of(if (l.kind == .sub) l.attr("menu") orelse l.id else ""),
            .enabled = @intFromBool(!off),
            .check = check,
        };
    }
    if (out) |o| o.* = ptrOf(UitMenuItem, items);
    if (n) |x| x.* = items.len;
    return UIT_OK;
}

pub const UIT_MENU_ITEM: u32 = 0;
pub const UIT_MENU_SEP: u32 = 1;
pub const UIT_MENU_SUB: u32 = 2;

export fn uit_theme_dark(c: *Core) u32 {
    return @intFromBool(c.st().dark());
}

export fn uit_token(c: *Core, name: UitStr, rgba: ?*u32) c_int {
    const v = parseColor(tokenText(c, name.slice()) orelse return 0) orelse return 0;
    if (rgba) |r| r.* = v;
    return 1;
}

// ---------------------------------------------------------------------
// Input: applied to the tree at once (reads stay on the pinned state);
// what changed is reported by the next pump.

fn input(c: *Core) ?c_int {
    if (!c.checkOwner()) return UIT_ETHREAD;
    if (c.gone.load(.acquire) or c.tree.current().gone) return UIT_EGONE;
    return null;
}

fn done(c: *Core, r: anyerror!void) c_int {
    r catch |e| return c.fail(e);
    c.wake();
    return UIT_OK;
}

fn attrsOf(a: Allocator, attrs: ?[*]const UitAttr, n: usize) Allocator.Error![]proto.ctl.Attr {
    const out = try a.alloc(proto.ctl.Attr, n);
    if (n > 0) for (attrs.?[0..n], out) |x, *o| {
        o.* = .{ .key = x.name.slice(), .value = x.value.slice() };
    };
    return out;
}

export fn uit_emit(c: *Core, h: UitNode, name: UitStr, attrs: ?[*]const UitAttr, n: usize) c_int {
    if (input(c)) |r| return r;
    if (h != 0 and c.tree.current().node(h) == null) return UIT_EINVAL;
    const as = attrsOf(c.gpa, attrs, n) catch return UIT_ENOMEM;
    defer c.gpa.free(as);
    _ = c.tree.emit(.{ .name = name.slice(), .node = h, .attrs = as }) catch |e| return c.fail(e);
    return UIT_OK;
}

export fn uit_request(c: *Core, h: UitNode, name: UitStr, attrs: ?[*]const UitAttr, n: usize, default_answer: UitStr) u64 {
    if (input(c) != null) return 0;
    const as = attrsOf(c.gpa, attrs, n) catch return 0;
    defer c.gpa.free(as);
    const seq = c.tree.request(.{ .name = name.slice(), .node = h, .attrs = as }, default_answer.slice()) catch |e| {
        _ = c.fail(e);
        return 0;
    };
    c.wake();
    return seq;
}

export fn uit_mirror(c: *Core, h: UitNode, file: UitStr, value: UitStr) c_int {
    if (input(c)) |r| return r;
    return done(c, c.tree.mirror(h, file.slice(), value.slice()));
}

export fn uit_bounds(c: *Core, h: UitNode, x: f32, y: f32, w: f32, hh: f32) c_int {
    if (input(c)) |r| return r;
    const b: [4]i64 = .{ @intFromFloat(@round(x)), @intFromFloat(@round(y)), @intFromFloat(@round(w)), @intFromFloat(@round(hh)) };
    c.tree.setBounds(h, b) catch |e| return c.fail(e);
    return UIT_OK;
}

export fn uit_frame_drawn(c: *Core, win: UitStr) c_int {
    if (input(c)) |r| return r;
    return done(c, c.tree.frameDrawn(if (win.len == 0) null else win.slice()));
}

export fn uit_window_closed(c: *Core, win: UitStr) c_int {
    if (input(c)) |r| return r;
    return done(c, c.tree.windowClosed(win.slice()));
}

export fn uit_key(c: *Core, win: UitStr, keystroke: UitStr, focused: UitNode) c_int {
    if (input(c)) |r| return r;
    const hit = c.tree.key(win.slice(), keystroke.slice(), focused) catch |e| return c.fail(e);
    return @intFromBool(hit);
}

export fn uit_menu_action(c: *Core, id: UitStr) c_int {
    if (input(c)) |r| return r;
    return done(c, c.tree.menuAction(id.slice()));
}

export fn uit_system_dark(c: *Core, dark: u32) c_int {
    if (input(c)) |r| return r;
    return done(c, c.tree.systemDark(dark != 0));
}

pub const UIT_DRAG_START: u32 = 0;
pub const UIT_DRAG_OVER: u32 = 1;
pub const UIT_DRAG_DROP: u32 = 2;
pub const UIT_DRAG_END: u32 = 3;

/// Transfer layer. START makes `drag/N` (its data from a `data=` attr);
/// DROP sends the `drop` request to the node, answered `accept` or
/// `refuse` (default) by UIT_CMD_ANSWER; END drops `drag/N`. OVER is the
/// renderer's own business (`drop-over` style).
export fn uit_drag(c: *Core, msg: ?*const UitDragMsg, drag: ?*u64) c_int {
    if (input(c)) |r| return r;
    const m = msg orelse return UIT_EINVAL;
    const as = attrsOf(c.gpa, m.attrs, m.n_attrs) catch return UIT_ENOMEM;
    defer c.gpa.free(as);
    switch (m.kind) {
        UIT_DRAG_START => {
            const n = c.next_drag;
            c.next_drag += 1;
            var data: []const u8 = "";
            for (as) |x| if (std.mem.eql(u8, x.key, "data")) {
                data = x.value;
            };
            c.tree.dragData(n, data) catch |e| return c.fail(e);
            if (drag) |d| d.* = n;
        },
        UIT_DRAG_DROP => {
            var all: std.ArrayList(proto.ctl.Attr) = .empty;
            defer all.deinit(c.gpa);
            var nb: [24]u8 = undefined;
            var pb: [48]u8 = undefined;
            all.append(c.gpa, .{ .key = "drag", .value = std.fmt.bufPrint(&nb, "{d}", .{m.drag}) catch "" }) catch return UIT_ENOMEM;
            all.append(c.gpa, .{ .key = "pt", .value = std.fmt.bufPrint(&pb, "{d},{d}", .{ @as(i64, @intFromFloat(@round(m.x))), @as(i64, @intFromFloat(@round(m.y))) }) catch "" }) catch return UIT_ENOMEM;
            all.appendSlice(c.gpa, as) catch return UIT_ENOMEM;
            const seq = c.tree.request(.{ .name = "drop", .node = m.node, .attrs = all.items }, "refuse") catch |e| return c.fail(e);
            if (drag) |d| d.* = seq;
        },
        UIT_DRAG_END => c.tree.dragDone(m.drag) catch |e| return c.fail(e),
        UIT_DRAG_OVER => {},
        else => return UIT_EINVAL,
    }
    c.wake();
    return UIT_OK;
}

// ---------------------------------------------------------------------

test "header and abi.zig agree on the version and the constants" {
    const h = @embedFile("uitcore.h");
    try std.testing.expect(std.mem.indexOf(u8, h, std.fmt.comptimePrint("#define UIT_ABI_VERSION {d}u", .{abi_version})) != null);
    const consts = .{
        .{ "UIT_EINVAL = -1", UIT_EINVAL },           .{ "UIT_ENOTSUP = -7", UIT_ENOTSUP },
        .{ "UIT_ETYPES = -11", UIT_ETYPES },          .{ "UIT_CMD_WINDOW = 1", UIT_CMD_WINDOW },
        .{ "UIT_CMD_THEME_LOAD = 14", UIT_CMD_THEME_LOAD }, .{ "UIT_ARG_TEXT = 6", UIT_ARG_TEXT },
        .{ "UIT_STATE_GROUP_HOVER = 6", UIT_STATE_GROUP_HOVER },
    };
    inline for (consts) |k| {
        try std.testing.expect(std.mem.indexOf(u8, h, k[0]) != null);
        try std.testing.expectEqual(std.fmt.parseInt(i64, k[0][std.mem.lastIndexOfScalar(u8, k[0], ' ').? + 1 ..], 10) catch unreachable, @as(i64, k[1]));
    }
}


fn testCore() !*Core {
    var c: ?*Core = null;
    const cfg: UitConfig = .{ .abi_version = abi_version, .types = .{}, .style_words = .{}, .theme_tokens = .{}, .system_dark = 0, .wake = null, .wake_ctx = null };
    try std.testing.expectEqual(UIT_OK, uit_create(&cfg, &c));
    return c.?;
}

fn write(c: *Core, path: []const u8, data: []const u8) !void {
    var ack: treem.Ack = .{};
    try c.queue.push(.{ .write = .{ .session = 1, .path = path, .data = data } }, &ack);
    var ch: UitChanges = .{};
    try std.testing.expectEqual(UIT_OK, uit_pump(c, &ch));
    try std.testing.expect(ack.done);
    if (!ack.ok) {
        std.debug.print("{s}: {s}\n", .{ path, ack.text() });
        return error.TestUnexpectedResult;
    }
}

test "a pump applies queued ops and reports what changed" {
    const core = try testCore();
    defer uit_destroy(core);
    try core.queue.push(.{ .write = .{ .session = 1, .path = "win/main/ctl", .data = "new text n text=0 : text-3xl" } }, null);
    var ch: UitChanges = .{};
    try std.testing.expectEqual(UIT_OK, uit_pump(core, &ch));
    try std.testing.expectEqual(@as(usize, 1), ch.n_created);
    try std.testing.expectEqual(UIT_CMD_WINDOW, ch.cmds.?[0].tag);
    try std.testing.expectEqualStrings("main", ch.cmds.?[0].win.slice());
    var kids: ?[*]const UitNode = null;
    try std.testing.expectEqual(@as(usize, 1), uit_children(core, uit_window_root(core, UitStr.lit("main")), &kids));
    var v: UitStr = .{};
    try std.testing.expectEqual(@as(c_int, 1), uit_prop(core, kids.?[0], UitStr.lit("text"), &v));
    try std.testing.expectEqualStrings("0", v.slice());
    try std.testing.expectEqualStrings("text", uit_type(core, kids.?[0]).slice());
    try std.testing.expectEqualStrings("n", uit_path(core, kids.?[0]).slice());
    var ws: ?[*]const UitStyleWord = null;
    var nw: usize = 0;
    try std.testing.expectEqual(UIT_OK, uit_style(core, kids.?[0], &ws, &nw));
    try std.testing.expectEqual(@as(usize, 1), nw);
    try std.testing.expectEqualStrings("text-3xl", ws.?[0].name.slice());
    // Variant and size words come first, and read as props.
    try write(core, "win/main/ctl", "new button go label=Greet primary : w-full");
    _ = uit_children(core, uit_window_root(core, UitStr.lit("main")), &kids);
    try std.testing.expectEqual(UIT_OK, uit_style(core, kids.?[1], &ws, &nw));
    try std.testing.expectEqual(@as(usize, 2), nw);
    try std.testing.expectEqualStrings("primary", ws.?[0].name.slice());
    try std.testing.expectEqual(@as(usize, 0), ws.?[0].n_args);
    try std.testing.expectEqualStrings("w-full", ws.?[1].name.slice());
    try std.testing.expectEqual(@as(c_int, 1), uit_prop(core, kids.?[1], UitStr.lit("variant"), &v));
    try std.testing.expectEqualStrings("primary", v.slice());
}

test "reads stay on the pinned state while input changes the tree" {
    const core = try testCore();
    defer uit_destroy(core);
    try write(core, "win/main/ctl", "new input in\nnew div d");
    const root = uit_window_root(core, UitStr.lit("main"));
    var kids: ?[*]const UitNode = null;
    _ = uit_children(core, root, &kids);
    const in = kids.?[0];
    try std.testing.expectEqual(UIT_OK, uit_mirror(core, in, UitStr.lit("value"), UitStr.lit("typed")));
    var v: UitStr = .{};
    try std.testing.expectEqual(@as(c_int, 0), uit_prop(core, in, UitStr.lit("value"), &v));
    var ch: UitChanges = .{};
    try std.testing.expectEqual(UIT_OK, uit_pump(core, &ch));
    // The renderer's own mirror isn't reported back to it.
    try std.testing.expectEqual(@as(usize, 0), ch.n_props);
    try std.testing.expectEqual(@as(c_int, 1), uit_prop(core, in, UitStr.lit("value"), &v));
    try std.testing.expectEqualStrings("typed", v.slice());
    // order leaves d out: not drawn
    try write(core, "win/main/order", "in");
    try std.testing.expectEqual(@as(usize, 1), uit_children(core, root, &kids));
}

test "window props, lines, overlays, menus, keys, tokens" {
    const core = try testCore();
    defer uit_destroy(core);
    try write(core, "ctl", "window main title=Hello size=640,480");
    const root = uit_window_root(core, UitStr.lit("main"));
    var v: UitStr = .{};
    try std.testing.expectEqual(@as(c_int, 1), uit_prop(core, root, UitStr.lit("title"), &v));
    try std.testing.expectEqualStrings("Hello", v.slice());
    try write(core, "win/main/ctl", "new table t\nnew dialog over/dlg title=Hi");
    try write(core, "win/main/t/rows", "1\ta\t10\n2\tb\t20\n");
    var kids: ?[*]const UitNode = null;
    _ = uit_children(core, root, &kids);
    var ls: UitLines = undefined;
    try std.testing.expectEqual(UIT_OK, uit_lines(core, kids.?[0], UitStr.lit("rows"), &ls));
    try std.testing.expectEqual(@as(usize, 2), ls.n);
    try std.testing.expectEqual(@as(usize, 3), ls.lines.?[1].n_fields);
    try std.testing.expectEqualStrings("b", ls.lines.?[1].fields.?[1].slice());
    var ov: ?[*]const UitNode = null;
    try std.testing.expectEqual(@as(usize, 0), uit_overlays(core, UitStr.lit("main"), &ov));
    try write(core, "win/main/over/dlg/ctl", "open");
    try std.testing.expectEqual(@as(usize, 1), uit_overlays(core, UitStr.lit("main"), &ov));
    try std.testing.expectEqualStrings("dialog", uit_type(core, ov.?[0]).slice());
    try write(core, "keys", "cmd-s save context=editor\n");
    var kb: ?[*]const UitKeyBinding = null;
    var nk: usize = 0;
    try std.testing.expectEqual(UIT_OK, uit_keys(core, &kb, &nk));
    try std.testing.expectEqual(@as(usize, 1), nk);
    try std.testing.expectEqualStrings("editor", kb.?[0].context.slice());
    try write(core, "menu/file", "item save label=Save key=cmd-s\nsep\nsub recent label=Recent\n  item r1 label=a.txt\n");
    try write(core, "menu/bar", "file\n");
    var bar: ?[*]const UitStr = null;
    try std.testing.expectEqual(@as(usize, 1), uit_menu_bar(core, &bar));
    var mi: ?[*]const UitMenuItem = null;
    var nm: usize = 0;
    try std.testing.expectEqual(UIT_OK, uit_menu(core, UitStr.lit("file"), &mi, &nm));
    try std.testing.expectEqual(@as(usize, 4), nm);
    try std.testing.expectEqual(UIT_MENU_SUB, mi.?[2].kind);
    try std.testing.expectEqual(@as(u32, 1), mi.?[3].depth);
    try write(core, "theme/tokens", "primary #0b5cff");
    var rgba: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 1), uit_token(core, UitStr.lit("primary"), &rgba));
    try std.testing.expectEqual(@as(u32, 0x0b5cffff), rgba);
}

test "requests: a tab close answered by the client" {
    const core = try testCore();
    defer uit_destroy(core);
    try write(core, "win/main/ctl", "new tabs tabs\nnew tab tabs/a");
    const s = try core.tree.bus.subscribe(.app);
    defer s.close();
    const tabs = core.tree.current().child(uit_window_root(core, UitStr.lit("main")), "tabs").?;
    const a = core.tree.current().child(tabs, "a").?;
    const seq = uit_request(core, a, UitStr.lit("close"), null, 0, UitStr.lit("close"));
    try std.testing.expect(seq != 0);
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "close seq={d}", .{seq});
    try write(core, "win/main/tabs/a/ctl", line);
    try std.testing.expect(core.tree.current().child(tabs, "a") == null);
}

test "extern layouts match the header's (64-bit)" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    // The sizes `zig cc` gives uitcore.h; renderer/gpui's uitcore-sys
    // checks the same numbers on the Rust side.
    const want = .{
        .{ UitStr, 16 },        .{ UitAttr, 32 },      .{ UitConfig, 80 },      .{ UitMachineArgs, 120 },
        .{ UitPropChange, 24 }, .{ UitCtl, 48 },       .{ UitHostCmd, 128 },    .{ UitChanges, 104 },
        .{ UitStyleArg, 32 },   .{ UitStyleWord, 56 }, .{ UitLine, 24 },        .{ UitKeyBinding, 56 },
        .{ UitMenuItem, 112 },  .{ UitDragMsg, 48 },
    };
    inline for (want) |w| try std.testing.expectEqual(@as(usize, w[1]), @sizeOf(w[0]));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(UitConfig, "wake"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(UitHostCmd, "seq"));
}

test "a 9P client writes and reads through the ABI's pump" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const core = try testCore();
    defer uit_destroy(core);
    var dial: UitStr = .{};
    try std.testing.expectEqual(UIT_OK, uit_listen(core, .{}, &dial));
    const Cl = struct {
        done: std.atomic.Value(bool) = .init(false),
        got: [64]u8 = undefined,
        n: usize = 0,
        failed: bool = false,
        fn run(s: *@This(), d: []const u8) void {
            defer s.done.store(true, .release);
            s.go(d) catch {
                s.failed = true;
            };
        }
        fn go(s: *@This(), d: []const u8) !void {
            const a = std.heap.page_allocator;
            var cl = try ninep.Client.init(a, try ninep.transport.dial(d));
            defer cl.deinit();
            try cl.version();
            const root = try cl.attach();
            try cl.put(root, "win/main/ctl", "new text a text=hi\n");
            const v = try cl.get(a, root, "win/main/a/text");
            defer a.free(v);
            @memcpy(s.got[0..v.len], v);
            s.n = v.len;
        }
    };
    var cl: Cl = .{};
    const th = try std.Thread.spawn(.{}, Cl.run, .{ &cl, dial.slice() });
    var ch: UitChanges = .{};
    while (!cl.done.load(.acquire)) {
        _ = uit_pump(core, &ch);
        core.io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    th.join();
    try std.testing.expect(!cl.failed);
    try std.testing.expectEqualStrings("hi\n", cl.got[0..cl.n]);
}
