//! The C ABI, include/uitcore.h. Owner: the spike (W0) writes and freezes
//! it; after the freeze a change needs a bump of UIT_ABI_VERSION and a note
//! to every renderer workstream.
//!
//! Rules (ARCHITECTURE.md § The ABI): one owner thread; the core wakes, the
//! renderer pumps; borrowed reads valid until the next uit_pump; no
//! callbacks into the renderer during a pump except wake; errors are
//! negative codes plus uit_last_error; panics abort, nothing unwinds.
//!
//! Status: version 1. The spike implements what the counter needs on its
//! throwaway tree (spike/); the rest returns UIT_ENOTSUP. W3 rewires these
//! exports onto `tree` and replaces spike/.

const std = @import("std");
const builtin = @import("builtin");
const spike = @import("spike/root.zig");
const machine = @import("machine/root.zig");

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
// The core

/// An op from another thread (or from the renderer's input calls),
/// applied by the next pump.
pub const Op = struct {
    kind: Kind,
    node: u32 = 0,
    name: []u8 = &.{},
    text: []u8 = &.{},
    attrs: [][2][]const u8 = &.{},
    flag: u32 = 0,
    ack: ?*Ack = null,

    pub const Kind = enum { ctl, keys, menu, prop, emit, system_dark, exited, menu_action };
};

/// What a 9P writer waits on.
pub const Ack = struct {
    done: bool = false,
    /// The protocol error text, or empty.
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,
    pub fn err(a: *const Ack) []const u8 {
        return a.err_buf[0..a.err_len];
    }
};

pub const Core = struct {
    gpa: Allocator,
    threaded: Io.Threaded,
    owner: std.Thread.Id,
    /// Guards `queue`, the tree for 9P readers, subscriptions, acks.
    mu: Io.Mutex = .init,
    /// Broadcast when an op is acked, an event is queued, or the core
    /// hangs up.
    cond: Io.Condition = .init,
    wake_fn: ?*const fn (?*anyopaque) callconv(.c) void,
    wake_ctx: ?*anyopaque,
    tree: *spike.Tree,
    queue: std.ArrayList(*Op) = .empty,
    gone: std.atomic.Value(bool) = .init(false),
    err_buf: [512]u8 = undefined,
    err_len: usize = 0,
    server: ?*spike.ninep.Server = null,
    runner: ?*machine.Runner = null,
    exit_status: ?[]u8 = null,
    /// Borrowed results of tree reads, freed at the next pump.
    reads: std.heap.ArenaAllocator,
    pump_dirty: [1]UitStr = .{UitStr.lit("main")},

    pub fn io(c: *Core) Io {
        return c.threaded.io();
    }

    pub fn lock(c: *Core) void {
        c.mu.lockUncancelable(c.io());
    }
    pub fn unlock(c: *Core) void {
        c.mu.unlock(c.io());
    }

    pub fn wake(c: *Core) void {
        if (c.wake_fn) |f| f(c.wake_ctx);
    }

    /// Queues `op`; the caller holds no lock.
    pub fn push(c: *Core, op: *Op) !void {
        c.lock();
        defer c.unlock();
        try c.queue.append(c.gpa, op);
    }

    /// Queues `op`, wakes the renderer and waits for the pump to apply
    /// it. Returns the error text, empty on success (in ack).
    pub fn submit(c: *Core, op: *Op, ack: *Ack) void {
        op.ack = ack;
        c.lock();
        defer c.unlock();
        c.queue.append(c.gpa, op) catch {
            ack.err_len = setText(&ack.err_buf, "out of memory");
            return;
        };
        c.wake();
        while (!ack.done) {
            if (c.gone.load(.acquire)) {
                ack.err_len = setText(&ack.err_buf, "app gone");
                return;
            }
            c.cond.waitUncancelable(c.io(), &c.mu);
        }
    }

    fn setErr(c: *Core, comptime fmt: []const u8, args: anytype) c_int {
        c.err_len = if (std.fmt.bufPrint(&c.err_buf, fmt, args)) |s| s.len else |_| 0;
        return UIT_EBADVALUE;
    }

    fn checkOwner(c: *Core) bool {
        if (builtin.mode == .Debug) std.debug.assert(std.Thread.getCurrentId() == c.owner);
        return std.Thread.getCurrentId() == c.owner;
    }
};

fn setText(buf: []u8, s: []const u8) usize {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

fn freeOp(gpa: Allocator, op: *Op) void {
    gpa.free(op.name);
    gpa.free(op.text);
    for (op.attrs) |a| {
        gpa.free(a[0]);
        gpa.free(a[1]);
    }
    gpa.free(op.attrs);
    gpa.destroy(op);
}

pub fn newOp(gpa: Allocator, kind: Op.Kind, node: u32, name: []const u8, text: []const u8) !*Op {
    const op = try gpa.create(Op);
    op.* = .{ .kind = kind, .node = node, .name = try gpa.dupe(u8, name), .text = try gpa.dupe(u8, text) };
    return op;
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
    const tree = spike.Tree.init(gpa, c_cfg.style_words.slice(), c_cfg.theme_tokens.slice(), c_cfg.types.slice(), c_cfg.system_dark != 0) catch {
        gpa.destroy(c);
        return UIT_ENOMEM;
    };
    c.* = .{
        .gpa = gpa,
        .threaded = .init(gpa, .{}),
        .owner = std.Thread.getCurrentId(),
        .wake_fn = c_cfg.wake,
        .wake_ctx = c_cfg.wake_ctx,
        .tree = tree,
        .reads = .init(gpa),
    };
    o.* = c;
    return UIT_OK;
}

export fn uit_serve_fd(c: *Core, fd: c_int) c_int {
    if (comptime builtin.os.tag == .windows) return UIT_ENOTSUP;
    spike.ninep.serveFd(c, fd) catch return UIT_EIO;
    return UIT_OK;
}

export fn uit_listen(c: *Core, addr: UitStr, dial: ?*UitStr) c_int {
    if (comptime builtin.os.tag == .windows) return UIT_ENOTSUP;
    if (!c.checkOwner()) return UIT_ETHREAD;
    if (addr.len != 0) {
        c.err_len = setText(&c.err_buf, "spike: only a private unix socket");
        return UIT_ENOTSUP;
    }
    if (c.server == null) c.server = spike.ninep.Server.start(c) catch return UIT_EIO;
    if (dial) |d| d.* = UitStr.of(c.server.?.dial);
    return UIT_OK;
}

export fn uit_run_machine(c: *Core, args: ?*const UitMachineArgs) c_int {
    if (!c.checkOwner()) return UIT_ETHREAD;
    const a = args orelse return UIT_EINVAL;
    if (!machine.available) {
        c.err_len = setText(&c.err_buf, "built without h9 (-Dh9=true)");
        return UIT_ENOTSUP;
    }
    if (c.runner != null) return UIT_EINUSE;
    if (c.server == null) c.server = spike.ninep.Server.start(c) catch return UIT_EIO;
    c.runner = machine.Runner.start(c.gpa, a, c.server.?.path, @ptrCast(c), onExit) catch |e| {
        c.err_len = if (std.fmt.bufPrint(&c.err_buf, "machine: {t}", .{e})) |s| s.len else |_| 0;
        return UIT_EIO;
    };
    return UIT_OK;
}

/// From the machine's thread when the client ends.
fn onExit(ctx: *anyopaque, status: []const u8) void {
    const c: *Core = @ptrCast(@alignCast(ctx));
    const op = newOp(c.gpa, .exited, 0, "", status) catch return;
    c.push(op) catch return;
    c.wake();
}

export fn uit_shutdown(c: *Core) void {
    c.gone.store(true, .release);
    c.lock();
    c.tree.closeAll();
    c.cond.broadcast(c.io());
    c.unlock();
    if (c.runner) |r| r.hangup();
}

export fn uit_destroy(c: *Core) void {
    uit_shutdown(c);
    if (c.runner) |r| r.join();
    if (c.server) |s| s.stop();
    c.lock();
    for (c.queue.items) |op| {
        if (op.ack) |a| a.done = true;
        freeOp(c.gpa, op);
    }
    c.queue.deinit(c.gpa);
    c.unlock();
    // Connections still open hold subscriptions; the spike leaks the tree
    // rather than free it under them when any are left.
    if (spike.ninep.live.load(.acquire) == 0) c.tree.deinit();
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

export fn uit_pump(c: *Core, out: ?*UitChanges) c_int {
    if (!c.checkOwner()) return UIT_ETHREAD;
    const o = out orelse return UIT_EINVAL;
    _ = c.reads.reset(.retain_capacity);
    const t = c.tree;
    c.lock();
    defer c.unlock();
    t.beginPump();
    var exited = false;
    for (c.queue.items) |op| {
        var why: []const u8 = "";
        var why_buf: [256]u8 = undefined;
        const r: spike.Error!void = switch (op.kind) {
            .ctl => t.ctl(op.node, op.text, &why, &why_buf),
            .keys => t.setKeys(op.text),
            .menu => t.setMenu(op.name, op.text),
            .prop => t.setProp(op.node, op.name, op.text, &why, &why_buf),
            .emit => t.emit(op.node, op.name, op.attrs) catch |e| switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.NotFound,
            },
            .menu_action => t.emitLine(t.main_root, "action", op.name, "-", &.{}, "menu"),
            .system_dark => t.setDark(op.flag != 0),
            .exited => blk: {
                exited = true;
                if (c.exit_status) |s| c.gpa.free(s);
                c.exit_status = c.gpa.dupe(u8, op.text) catch null;
                break :blk {};
            },
        };
        if (op.ack) |a| {
            if (r) |_| {} else |e| {
                var eb: [256]u8 = undefined;
                const txt = spike.tree.errText(&eb, e, why);
                @memcpy(a.err_buf[0..txt.len], txt);
                a.err_len = txt.len;
            }
            a.done = true;
        }
        freeOp(c.gpa, op);
    }
    c.queue.clearRetainingCapacity();
    c.cond.broadcast(c.io());

    o.* = .{};
    const ch = &t.ch;
    if (ch.dirty_main) {
        o.dirty_windows = &c.pump_dirty;
        o.n_dirty = 1;
    }
    o.created = if (ch.created.items.len > 0) ch.created.items.ptr else null;
    o.n_created = ch.created.items.len;
    o.removed = if (ch.removed.items.len > 0) ch.removed.items.ptr else null;
    o.n_removed = ch.removed.items.len;
    o.props = if (ch.props.items.len > 0) ch.props.items.ptr else null;
    o.n_props = ch.props.items.len;
    o.cmds = if (ch.cmds.items.len > 0) ch.cmds.items.ptr else null;
    o.n_cmds = ch.cmds.items.len;
    if (exited) {
        o.exited = 1;
        o.exit_status = UitStr.of(c.exit_status orelse "");
    }
    return UIT_OK;
}

// ---------------------------------------------------------------------
// Tree reads (owner thread; the owner is the only writer, so no lock)

var main_name = [_]UitStr{UitStr.lit("main")};

export fn uit_windows(c: *Core, out: ?*?[*]const UitStr) usize {
    _ = c;
    if (out) |o| o.* = &main_name;
    return 1;
}

export fn uit_window_root(c: *Core, win: UitStr) UitNode {
    if (!std.mem.eql(u8, win.slice(), "main")) return 0;
    return c.tree.main_root;
}

export fn uit_children(c: *Core, node: UitNode, out: ?*?[*]const UitNode) usize {
    const n = c.tree.get(node) orelse return 0;
    if (out) |o| o.* = if (n.kids.items.len > 0) n.kids.items.ptr else null;
    return n.kids.items.len;
}

export fn uit_overlays(c: *Core, win: UitStr, out: ?*?[*]const UitNode) usize {
    _ = c;
    _ = win;
    if (out) |o| o.* = null;
    return 0;
}

export fn uit_type(c: *Core, node: UitNode) UitStr {
    const n = c.tree.get(node) orelse return .{};
    return UitStr.of(n.typ);
}

export fn uit_path(c: *Core, node: UitNode) UitStr {
    const n = c.tree.get(node) orelse return .{};
    return UitStr.of(n.path);
}

export fn uit_window_of(c: *Core, node: UitNode) UitStr {
    _ = c.tree.get(node) orelse return .{};
    return UitStr.lit("main");
}

export fn uit_prop(c: *Core, node: UitNode, file: UitStr, out: ?*UitStr) c_int {
    const n = c.tree.get(node) orelse return UIT_EINVAL;
    const v = n.prop(file.slice()) orelse return 0;
    if (out) |o| o.* = UitStr.of(v);
    return 1;
}

export fn uit_style(c: *Core, node: UitNode, out: ?*?[*]const UitStyleWord, n_out: ?*usize) c_int {
    const n = c.tree.get(node) orelse return UIT_EINVAL;
    if (out) |o| o.* = if (n.style.len > 0) n.style.ptr else null;
    if (n_out) |k| k.* = n.style.len;
    return UIT_OK;
}

export fn uit_lines(c: *Core, node: UitNode, file: UitStr, out: ?*UitLines) c_int {
    _ = c;
    _ = node;
    _ = file;
    if (out) |o| o.* = .{ .lines = null, .n = 0 };
    return UIT_ENOTSUP;
}

export fn uit_keys(c: *Core, out: ?*?[*]const UitKeyBinding, n: ?*usize) c_int {
    const a = c.reads.allocator();
    const ks = a.alloc(UitKeyBinding, c.tree.keys.items.len) catch return UIT_ENOMEM;
    for (c.tree.keys.items, ks) |k, *o| o.* = .{ .keystroke = UitStr.of(k.key), .action = UitStr.of(k.action), .context = UitStr.of(k.context), .global = @intFromBool(k.global) };
    if (out) |o| o.* = if (ks.len > 0) ks.ptr else null;
    if (n) |x| x.* = ks.len;
    return UIT_OK;
}

export fn uit_menu_bar(c: *Core, out: ?*?[*]const UitStr) usize {
    _ = c;
    if (out) |o| o.* = null;
    return 0;
}

export fn uit_menu(c: *Core, name: UitStr, out: ?*?[*]const UitMenuItem, n: ?*usize) c_int {
    _ = c;
    _ = name;
    if (out) |o| o.* = null;
    if (n) |x| x.* = 0;
    return UIT_ENOTSUP;
}

export fn uit_theme_dark(c: *Core) u32 {
    return @intFromBool(c.tree.dark);
}

export fn uit_token(c: *Core, name: UitStr, rgba: ?*u32) c_int {
    const v = c.tree.token(name.slice()) orelse return 0;
    if (rgba) |r| r.* = v;
    return 1;
}

// ---------------------------------------------------------------------
// Input

fn queueInput(c: *Core, op: *Op) c_int {
    c.push(op) catch {
        freeOp(c.gpa, op);
        return UIT_ENOMEM;
    };
    c.wake();
    return UIT_OK;
}

export fn uit_emit(c: *Core, node: UitNode, name: UitStr, attrs: ?[*]const UitAttr, n: usize) c_int {
    if (!c.checkOwner()) return UIT_ETHREAD;
    if (c.gone.load(.acquire)) return UIT_EGONE;
    if (c.tree.get(node) == null) return UIT_EINVAL;
    const op = newOp(c.gpa, .emit, node, name.slice(), "") catch return UIT_ENOMEM;
    if (n > 0) {
        const list = c.gpa.alloc([2][]const u8, n) catch {
            freeOp(c.gpa, op);
            return UIT_ENOMEM;
        };
        for (attrs.?[0..n], list) |a, *l| l.* = .{
            c.gpa.dupe(u8, a.name.slice()) catch "",
            c.gpa.dupe(u8, a.value.slice()) catch "",
        };
        op.attrs = list;
    }
    return queueInput(c, op);
}

export fn uit_request(c: *Core, node: UitNode, name: UitStr, attrs: ?[*]const UitAttr, n: usize, default_answer: UitStr) u64 {
    _ = c;
    _ = node;
    _ = name;
    _ = attrs;
    _ = n;
    _ = default_answer;
    return 0; // the spike applies every default at once
}

export fn uit_mirror(c: *Core, node: UitNode, file: UitStr, value: UitStr) c_int {
    if (!c.checkOwner()) return UIT_ETHREAD;
    const op = newOp(c.gpa, .prop, node, file.slice(), value.slice()) catch return UIT_ENOMEM;
    return queueInput(c, op);
}

export fn uit_bounds(c: *Core, node: UitNode, x: f32, y: f32, w: f32, h: f32) c_int {
    _ = .{ c, node, x, y, w, h };
    return UIT_ENOTSUP;
}

export fn uit_frame_drawn(c: *Core, win: UitStr) c_int {
    _ = .{ c, win };
    return UIT_OK;
}

export fn uit_window_closed(c: *Core, win: UitStr) c_int {
    _ = win;
    // Closing the last window quits.
    c.lock();
    c.tree.cmd(.{ .tag = UIT_CMD_QUIT }) catch {};
    c.unlock();
    uit_shutdown(c);
    return UIT_OK;
}

export fn uit_key(c: *Core, win: UitStr, keystroke: UitStr, focused: UitNode) c_int {
    _ = win;
    if (!c.checkOwner()) return UIT_ETHREAD;
    // Matching reads the committed keymap; the event goes out now (the
    // owner is the only writer of the tree, and subscriptions are locked).
    c.lock();
    defer c.unlock();
    const hit = c.tree.key(keystroke.slice(), focused) catch return UIT_ENOMEM;
    if (hit) c.cond.broadcast(c.io());
    return @intFromBool(hit);
}

export fn uit_menu_action(c: *Core, id: UitStr) c_int {
    const op = newOp(c.gpa, .menu_action, 0, id.slice(), "") catch return UIT_ENOMEM;
    return queueInput(c, op);
}

export fn uit_system_dark(c: *Core, dark: u32) c_int {
    const op = newOp(c.gpa, .system_dark, 0, "", "") catch return UIT_ENOMEM;
    op.flag = dark;
    return queueInput(c, op);
}

export fn uit_drag(c: *Core, msg: ?*const UitDragMsg, drag: ?*u64) c_int {
    _ = .{ c, msg, drag };
    return UIT_ENOTSUP;
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

test "a pump applies queued ops and reports what changed" {
    var c: ?*Core = null;
    const cfg: UitConfig = .{ .abi_version = abi_version, .types = .{}, .style_words = .{}, .theme_tokens = .{}, .system_dark = 0, .wake = null, .wake_ctx = null };
    try std.testing.expectEqual(UIT_OK, uit_create(&cfg, &c));
    defer uit_destroy(c.?);
    const core = c.?;
    try core.push(try newOp(core.gpa, .ctl, core.tree.main_root, "", "new text n text=0 : text-3xl"));
    var ch: UitChanges = .{};
    try std.testing.expectEqual(UIT_OK, uit_pump(core, &ch));
    try std.testing.expectEqual(@as(usize, 1), ch.n_created);
    try std.testing.expectEqual(UIT_CMD_WINDOW, ch.cmds.?[0].tag);
    var kids: ?[*]const UitNode = null;
    try std.testing.expectEqual(@as(usize, 1), uit_children(core, uit_window_root(core, UitStr.lit("main")), &kids));
    var v: UitStr = .{};
    try std.testing.expectEqual(@as(c_int, 1), uit_prop(core, kids.?[0], UitStr.lit("text"), &v));
    try std.testing.expectEqualStrings("0", v.slice());
    try std.testing.expectEqualStrings("text", uit_type(core, kids.?[0]).slice());
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
