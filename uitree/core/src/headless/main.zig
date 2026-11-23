//! uitree-headless: the core with no renderer. Serves `$ui` over 9P, runs
//! the app in h9, and answers like a host whose windows are never drawn.
//! The conformance suite runs against this binary
//! (tests/conformance/README.md § The host).
//!
//!     uitree-headless [-a ADDR] [-r ROOT] [-d SRC:DST]... [-e NAME=VALUE]... CMD [ARG...]
//!     uitree-headless -a ADDR
//!
//! It is a renderer like any other: it reaches the core only through
//! uitcore.h (declared below as externs), on its own owner thread, and
//! pumps when the core wakes it. What a drawing host would learn from the
//! platform (a click, a layout, a frame, the clock) it learns from lines
//! written to `$ui/debug/inject` (ninep/debug.zig), which it applies on
//! that same thread through the ABI's input calls.
//!
//! - `CMD ARG...` runs in h9 with `$ui` mounted and set, in the current
//!   directory. The exit status is the client's: 0 for an empty exit
//!   string, 1 for any other. With no CMD it serves until killed.
//! - `-a ADDR` also listens on ADDR (`tcp!HOST!PORT`, `HOST:PORT`,
//!   `unix!PATH`) and prints `uitree: listening on DIAL` to standard error.
//! - `-r ROOT` is h9's root: `builtin` (the default) or a 9front root
//!   directory; `$H9ROOT` sets it too.
//! - Failed writes are loud: `uitree: write PATH: phrase: detail` on
//!   standard error (ninep/host.zig).

const std = @import("std");
const core = @import("uitcore");

const abi = core.abi;
const ninep = core.ninep;
const debug = ninep.debug;
const UitStr = abi.UitStr;
const Core = abi.Core;
const Err = ninep.fs.Err;

// The C ABI, as any renderer sees it.
extern fn uit_create(cfg: ?*const abi.UitConfig, out: ?*?*Core) c_int;
extern fn uit_destroy(c: *Core) void;
extern fn uit_shutdown(c: *Core) void;
extern fn uit_last_error(c: *Core) UitStr;
extern fn uit_listen(c: *Core, addr: UitStr, dial: ?*UitStr) c_int;
extern fn uit_run_machine(c: *Core, args: ?*const abi.UitMachineArgs) c_int;
extern fn uit_pump(c: *Core, out: ?*abi.UitChanges) c_int;
extern fn uit_window_root(c: *Core, win: UitStr) abi.UitNode;
extern fn uit_children(c: *Core, node: abi.UitNode, out: ?*?[*]const abi.UitNode) usize;
extern fn uit_path(c: *Core, node: abi.UitNode) UitStr;
extern fn uit_emit(c: *Core, node: abi.UitNode, name: UitStr, attrs: ?[*]const abi.UitAttr, n: usize) c_int;
extern fn uit_mirror(c: *Core, node: abi.UitNode, file: UitStr, value: UitStr) c_int;
extern fn uit_bounds(c: *Core, node: abi.UitNode, x: f32, y: f32, w: f32, h: f32) c_int;
extern fn uit_frame_drawn(c: *Core, win: UitStr) c_int;
extern fn uit_key(c: *Core, win: UitStr, keystroke: UitStr, focused: abi.UitNode) c_int;
extern fn uit_menu_action(c: *Core, id: UitStr) c_int;
extern fn uit_system_dark(c: *Core, dark: u32) c_int;

const usage =
    \\usage: uitree-headless [-a ADDR] [-r ROOT] [-d SRC:DST]... [-e NAME=VALUE]... CMD [ARG...]
    \\       uitree-headless -a ADDR
    \\
;

const Options = struct {
    addrs: std.ArrayList([]const u8) = .empty,
    root: []const u8 = "",
    dirs: std.ArrayList(UitStr) = .empty,
    env: std.ArrayList(UitStr) = .empty,
    argv: []const []const u8 = &.{},
};

fn parseArgs(a: std.mem.Allocator, args: []const []const u8) !Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.eql(u8, s, "--")) {
            i += 1;
            break;
        }
        if (s.len < 2 or s[0] != '-') break;
        if (std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) return error.Usage;
        if (i + 1 >= args.len) return error.Usage;
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, s, "-a")) {
            try o.addrs.append(a, v);
        } else if (std.mem.eql(u8, s, "-r")) {
            o.root = v;
        } else if (std.mem.eql(u8, s, "-d")) {
            try o.dirs.append(a, UitStr.of(v));
        } else if (std.mem.eql(u8, s, "-e")) {
            if (std.mem.indexOfScalar(u8, v, '=') == null) return error.Usage;
            try o.env.append(a, UitStr.of(v));
        } else return error.Usage;
    }
    o.argv = args[i..];
    if (o.argv.len == 0 and o.addrs.items.len == 0) return error.Usage;
    return o;
}

/// One inject line waiting for the owner thread.
const Job = struct {
    inj: *const debug.Inject,
    err: *Err,
    failed: bool = false,
    done: bool = false,
    next: ?*Job = null,
};

/// The owner thread's state, shared with 9P threads (wake, inject).
const Headless = struct {
    io: std.Io,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    woken: bool = false,
    jobs: ?*Job = null,
    jobs_tail: ?*Job = null,
    /// The client has exited: inject answers `app gone` from now on.
    finished: bool = false,
    core: *Core = undefined,
    clock_ns: u64 = 0,

    fn lock(h: *Headless) void {
        h.mu.lockUncancelable(h.io);
    }
    fn unlock(h: *Headless) void {
        h.mu.unlock(h.io);
    }

    /// UitConfig.wake: any thread.
    fn wake(ctx: ?*anyopaque) callconv(.c) void {
        const h: *Headless = @ptrCast(@alignCast(ctx.?));
        h.lock();
        h.woken = true;
        h.cond.broadcast(h.io);
        h.unlock();
    }

    /// Injector.apply: a 9P thread. Queues the line for the owner thread
    /// and waits for it.
    fn apply(ctx: *anyopaque, inj: *const debug.Inject, err: *Err) ninep.fs.Error!void {
        const h: *Headless = @ptrCast(@alignCast(ctx));
        var job: Job = .{ .inj = inj, .err = err };
        h.lock();
        defer h.unlock();
        if (h.finished) return err.set("app gone");
        if (h.jobs_tail) |t| t.next = &job else h.jobs = &job;
        h.jobs_tail = &job;
        h.cond.broadcast(h.io);
        while (!job.done) h.cond.waitUncancelable(h.io, &h.mu);
        if (job.failed) return error.Failed;
    }

    /// Owner thread: takes every queued job.
    fn takeJobs(h: *Headless) ?*Job {
        const j = h.jobs;
        h.jobs = null;
        h.jobs_tail = null;
        return j;
    }

    fn finishJobs(h: *Headless, first: ?*Job) void {
        h.lock();
        var j = first;
        while (j) |x| {
            j = x.next;
            x.done = true;
        }
        h.cond.broadcast(h.io);
        h.unlock();
    }

    /// Runs one job on the owner thread.
    fn run(h: *Headless, j: *Job) void {
        h.runInject(j.inj, j.err) catch {
            j.failed = true;
        };
    }

    fn check(h: *Headless, rc: c_int, err: *Err) error{Failed}!void {
        if (rc >= 0) return;
        const txt = uit_last_error(h.core).slice();
        if (txt.len > 0) return err.set(txt);
        return err.set(switch (rc) {
            abi.UIT_ENOTFOUND => "not found",
            abi.UIT_EINUSE => "in use",
            abi.UIT_EBADVALUE, abi.UIT_EINVAL => "bad value",
            abi.UIT_ENOTSUP => "unsupported",
            abi.UIT_EGONE => "app gone",
            abi.UIT_ENOMEM => "too large",
            else => "unsupported",
        });
    }

    /// A window-relative path to a node handle, walking children by name
    /// through the ABI as a renderer would. Null: not found.
    fn lookup(h: *Headless, win: []const u8, path: []const u8) ?abi.UitNode {
        var at = uit_window_root(h.core, UitStr.of(win));
        if (at == 0) return null;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |el| {
            if (std.mem.eql(u8, el, ".")) continue;
            var kids: ?[*]const abi.UitNode = null;
            const n = uit_children(h.core, at, &kids);
            var found: abi.UitNode = 0;
            for (if (n > 0) kids.?[0..n] else &[_]abi.UitNode{}) |k| {
                const p = uit_path(h.core, k).slice();
                const base = if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
                if (std.mem.eql(u8, base, el)) {
                    found = k;
                    break;
                }
            }
            if (found == 0) return null;
            at = found;
        }
        return at;
    }

    fn node(h: *Headless, win: ?[]const u8, path: ?[]const u8, err: *Err) error{Failed}!abi.UitNode {
        const w = win orelse "main";
        const p = path orelse ".";
        return h.lookup(w, p) orelse err.print("not found: {s}", .{p});
    }

    fn runInject(h: *Headless, inj: *const debug.Inject, err: *Err) error{ Failed, OutOfMemory }!void {
        const c = h.core;
        switch (inj.*) {
            .event => |e| {
                const n = try h.node(e.win, e.node, err);
                var attrs: [64]abi.UitAttr = undefined;
                var k: usize = 0;
                if (e.key) |key| {
                    attrs[k] = .{ .name = UitStr.lit("key"), .value = UitStr.of(key) };
                    k += 1;
                }
                for (e.attrs) |a| {
                    if (k == attrs.len) return err.set("too large");
                    attrs[k] = .{ .name = UitStr.of(a.key), .value = UitStr.of(a.value) };
                    k += 1;
                }
                try h.check(uit_emit(c, n, UitStr.of(e.name), &attrs, k), err);
            },
            .mirror => |m| {
                const n = try h.node(m.win, m.node, err);
                try h.check(uit_mirror(c, n, UitStr.of(m.file), UitStr.of(m.value)), err);
            },
            .bounds => |b| {
                const n = try h.node(b.win, b.node, err);
                try h.check(uit_bounds(c, n, b.x, b.y, b.w, b.h), err);
            },
            .frame => |f| try h.check(uit_frame_drawn(c, UitStr.of(f.win orelse "")), err),
            .tick => |t| {
                h.clock_ns += t.ns;
                // The tree's fake clock (W3): batch and request deadlines.
                if (@hasDecl(Core, "advanceClock")) c.advanceClock(t.ns);
            },
            .drag => return err.set("unsupported: drag offers need the transfer layer"),
            .key => |k| {
                const rc = uit_key(c, UitStr.of(k.win), UitStr.of(k.stroke), 0);
                try h.check(rc, err);
            },
            .menu => |m| try h.check(uit_menu_action(c, UitStr.of(m.item)), err),
            .appearance => |a| try h.check(uit_system_dark(c, @intFromBool(a.dark)), err),
        }
    }
};

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("uitree-headless: " ++ fmt ++ "\n", args);
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var opts = parseArgs(arena, args) catch {
        std.debug.print(usage, .{});
        return 2;
    };
    if (opts.root.len == 0) opts.root = init.environ_map.get("H9ROOT") orelse "";

    var h: Headless = .{ .io = init.io };

    // Every type the core has, as the descriptors a renderer would register.
    var types: std.ArrayList(u8) = .empty;
    for (core.types.embedded.specs) |s| {
        try types.appendSlice(arena, s.text);
        try types.append(arena, '\n');
    }
    const cfg: abi.UitConfig = .{
        .abi_version = abi.abi_version,
        .types = UitStr.of(types.items),
        .style_words = UitStr.of(core.types.embedded.style_words),
        .theme_tokens = UitStr.of(core.types.embedded.theme_tokens),
        // README.md § The host: light until `appearance` changes it.
        .system_dark = 0,
        .wake = Headless.wake,
        .wake_ctx = &h,
    };
    var cp: ?*Core = null;
    const rc = uit_create(&cfg, &cp);
    if (rc != abi.UIT_OK) return fail("uit_create: {d}", .{rc});
    const c = cp.?;
    h.core = c;

    // /debug/inject, beside the tree.
    var dbg: debug.Debug = .{ .injector = .{ .ptr = &h, .apply = Headless.apply } };
    const host = c.getHost() catch |e| return fail("serve: {t}", .{e});
    host.mount("debug", dbg.fs()) catch |e| return fail("serve: {t}", .{e});

    for (opts.addrs.items) |addr| {
        var dial: UitStr = .{};
        if (uit_listen(c, UitStr.of(addr), &dial) != abi.UIT_OK)
            return fail("listen {s}: {s}", .{ addr, uit_last_error(c).slice() });
        std.debug.print("uitree: listening on {s}\n", .{dial.slice()});
    }

    const running = opts.argv.len > 0;
    if (running) {
        const argv = try arena.alloc(UitStr, opts.argv.len);
        for (opts.argv, argv) |s, *o| o.* = UitStr.of(s);
        const margs: abi.UitMachineArgs = .{
            .prog = argv[0],
            .argv = argv.ptr,
            .argc = argv.len,
            .root = UitStr.of(opts.root),
            .cwd = .{},
            .dirs = opts.dirs.items.ptr,
            .n_dirs = opts.dirs.items.len,
            .env = opts.env.items.ptr,
            .n_env = opts.env.items.len,
            .h9_flags = null,
            .n_h9_flags = 0,
            .out_fd = -1,
            .err_fd = -1,
        };
        if (uit_run_machine(c, &margs) != abi.UIT_OK) return fail("{s}: {s}", .{ opts.argv[0], uit_last_error(c).slice() });
    }

    // The owner loop: pump when woken, apply inject lines, until the
    // client exits.
    var status: ?[]const u8 = null;
    while (status == null) {
        h.lock();
        while (!h.woken and h.jobs == null) h.cond.waitUncancelable(h.io, &h.mu);
        h.woken = false;
        const jobs = h.takeJobs();
        h.unlock();

        var ch: abi.UitChanges = .{};
        if (uit_pump(c, &ch) == abi.UIT_OK and ch.exited != 0)
            status = try arena.dupe(u8, ch.exit_status.slice());

        var j = jobs;
        while (j) |x| : (j = x.next) {
            if (status != null) {
                x.err.note("app gone");
                x.failed = true;
            } else h.run(x);
        }
        h.finishJobs(jobs);
        // An inject queues input for the next pump: do it now, so the
        // events are out before the inject write returns.
        if (jobs != null and status == null) {
            var ch2: abi.UitChanges = .{};
            if (uit_pump(c, &ch2) == abi.UIT_OK and ch2.exited != 0)
                status = try arena.dupe(u8, ch2.exit_status.slice());
        }
    }

    h.lock();
    h.finished = true;
    const late = h.takeJobs();
    var j = late;
    while (j) |x| : (j = x.next) {
        x.err.note("app gone");
        x.failed = true;
    }
    h.unlock();
    h.finishJobs(late);

    uit_shutdown(c);
    uit_destroy(c);
    return if (status.?.len == 0) 0 else 1;
}

test "parse args" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try parseArgs(a, &.{ "uitree-headless", "-r", "/r", "-a", ":0", "rc", "-c", "x" });
    try t.expectEqualStrings("/r", o.root);
    try t.expectEqual(@as(usize, 3), o.argv.len);
    try t.expectEqualStrings("-c", o.argv[1]);
    try t.expectError(error.Usage, parseArgs(a, &.{"uitree-headless"}));
    _ = try parseArgs(a, &.{ "uitree-headless", "-a", ":0" });
    try t.expectError(error.Usage, parseArgs(a, &.{ "uitree-headless", "-e", "nope", "rc" }));
}
