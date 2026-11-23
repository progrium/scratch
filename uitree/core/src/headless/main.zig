//! uitree-headless: the core with no renderer. Serves `$ui` over 9P, runs
//! the app in h9, and answers like a host whose windows are never drawn.
//! The conformance suite runs against this binary
//! (tests/conformance/README.md § The host).
//!
//!     uitree-headless [-a ADDR] [-r ROOT] [-d SRC:DST]... [-e NAME=VALUE]... CMD [ARG...]
//!     uitree-headless -a ADDR
//!
//! It holds the tree on its own owner thread and pumps when a 9P thread
//! queues an op. What a drawing host would learn from the platform (a
//! click, a layout, a frame, the clock) it learns from lines written to
//! `$ui/debug/inject` (ninep/debug.zig), which it applies on that same
//! thread through the tree's inputs.
//!
//! - `CMD ARG...` runs in h9 with `$ui` mounted and set, in the current
//!   directory. The exit status is the client's: 0 for an empty exit
//!   string, 1 for any other. With no CMD it serves until killed.
//! - `-a ADDR` also listens on ADDR (`tcp!HOST!PORT`, `HOST:PORT`,
//!   `unix!PATH`) and prints `uitree: listening on DIAL` to standard error.
//! - `-r ROOT` is h9's root: `builtin` (the default) or a 9front root
//!   directory; `$H9ROOT` sets it too.
//! - Failed writes are loud: `uitree: write PATH: phrase: detail` on
//!   standard error (the tree prints them).

const std = @import("std");
const core = @import("uitcore");

const abi = core.abi;
const ninep = core.ninep;
const tree = core.tree;
const proto = core.proto;
const debug = ninep.debug;
const UitStr = abi.UitStr;
const Tree = tree.Tree;
const Handle = tree.Handle;
const Err = ninep.fs.Err;

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

/// The owner thread's state, shared with 9P threads (wake, inject) and
/// the machine thread (exit).
const Headless = struct {
    io: std.Io,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    woken: bool = false,
    jobs: ?*Job = null,
    jobs_tail: ?*Job = null,
    /// The client has exited: inject answers `app gone` from now on.
    finished: bool = false,
    /// The client's exit string, once it has exited.
    status: ?[]const u8 = null,
    status_buf: [256]u8 = undefined,
    t: *Tree = undefined,

    fn lock(h: *Headless) void {
        h.mu.lockUncancelable(h.io);
    }
    fn unlock(h: *Headless) void {
        h.mu.unlock(h.io);
    }

    /// OpQueue.wake: any thread.
    fn wake(ctx: ?*anyopaque) void {
        const h: *Headless = @ptrCast(@alignCast(ctx.?));
        h.lock();
        h.woken = true;
        h.cond.broadcast(h.io);
        h.unlock();
    }

    /// machine.Runner's on_exit: the machine thread.
    fn onExit(ctx: *anyopaque, status: []const u8) void {
        const h: *Headless = @ptrCast(@alignCast(ctx));
        h.lock();
        const n = @min(status.len, h.status_buf.len);
        @memcpy(h.status_buf[0..n], status[0..n]);
        // A status that didn't fit is still not empty.
        h.status = h.status_buf[0..n];
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

    /// A tree input's error as the inject write's.
    fn treeErr(h: *Headless, err: *Err, e: anyerror) error{ Failed, OutOfMemory } {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        const txt = h.t.lastError();
        if (txt.len > 0) return err.set(txt);
        if (proto.Code.fromError(e)) |c| return err.set(c.phrase());
        return err.set("bad value");
    }

    /// The node at window-relative `path` in window `win`.
    fn node(h: *Headless, arena: std.mem.Allocator, win: []const u8, path: []const u8, err: *Err) error{ Failed, OutOfMemory }!Handle {
        const st = h.t.current();
        const w = st.win(win) orelse return err.print("not found: win/{s}", .{win});
        return tree.path.resolveNode(st, arena, w.root, path, null) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return err.print("not found: win/{s}/{s}", .{ win, path });
        };
    }

    /// The default answer to request `name` about node `n`, or null if
    /// `name` is no request (core.md § Requests).
    fn requestDefault(h: *Headless, name: []const u8, n: Handle) ?[]const u8 {
        const eq = std.mem.eql;
        if (eq(u8, name, "close")) return "close";
        if (eq(u8, name, "quit")) return "quit";
        if (eq(u8, name, "open")) return "accept";
        if (eq(u8, name, "drop")) {
            const nd = h.t.current().node(n) orelse return "refuse";
            return if (nd.stored("drop") != null) "accept" else "refuse";
        }
        return null;
    }

    fn runInject(h: *Headless, inj: *const debug.Inject, err: *Err) error{ Failed, OutOfMemory }!void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const t = h.t;
        switch (inj.*) {
            .event => |e| {
                // `node=` defaults to `.` with `win=`, `-` (the app) without.
                var n: Handle = 0;
                if (e.win != null or e.node != null) {
                    const p = e.node orelse ".";
                    if (!std.mem.eql(u8, p, "-")) n = try h.node(a, e.win orelse "main", p, err);
                }
                const ev: tree.EventIn = .{ .name = e.name, .node = n, .key = e.key, .win = e.win, .attrs = e.attrs };
                if (h.requestDefault(e.name, n)) |def| {
                    _ = t.request(ev, def) catch |x| return h.treeErr(err, x);
                } else {
                    _ = t.emit(ev) catch |x| return h.treeErr(err, x);
                }
            },
            .mirror => |m| {
                const n = try h.node(a, m.win orelse "main", m.node orelse ".", err);
                t.mirror(n, m.file, m.value) catch |x| return h.treeErr(err, x);
            },
            .bounds => |b| {
                const n = try h.node(a, b.win, b.node, err);
                const r: [4]i64 = .{ @intFromFloat(b.x), @intFromFloat(b.y), @intFromFloat(b.w), @intFromFloat(b.h) };
                t.setBounds(n, r) catch |x| return h.treeErr(err, x);
            },
            .frame => |f| t.frameDrawn(f.win) catch |x| return h.treeErr(err, x),
            .tick => |k| t.advanceClock(k.ns) catch |x| return h.treeErr(err, x),
            .drag => |d| t.dragData(d.n, d.data) catch |x| return h.treeErr(err, x),
            .key => |k| _ = t.key(k.win, k.stroke, 0) catch |x| return h.treeErr(err, x),
            .menu => |m| t.menuAction(m.item) catch |x| return h.treeErr(err, x),
            .appearance => |ap| t.systemDark(ap.dark) catch |x| return h.treeErr(err, x),
        }
    }

    /// One pump: queued ops, then inject lines, each published before it
    /// is answered. The renderer's side (changes) has no one to draw it.
    fn pump(h: *Headless, q: *tree.OpQueue, jobs: ?*Job, gone: bool) void {
        _ = ninep.ns.drainPublish(q, h.t);
        var j = jobs;
        while (j) |x| : (j = x.next) {
            if (gone) {
                x.err.note("app gone");
                x.failed = true;
            } else {
                h.runInject(x.inj, x.err) catch |e| {
                    if (e == error.OutOfMemory) x.err.note("out of memory");
                    x.failed = true;
                };
            }
        }
        h.t.publish() catch {};
        h.t.clearChanges();
        h.finishJobs(jobs);
    }
};

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("uitree-headless: " ++ fmt ++ "\n", args);
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var opts = parseArgs(arena, args) catch {
        std.debug.print(usage, .{});
        return 2;
    };
    if (opts.root.len == 0) opts.root = init.environ_map.get("H9ROOT") orelse "";

    var h: Headless = .{ .io = io };

    var cat = core.types.Catalog.builtin(gpa) catch |e| return fail("types: {t}", .{e});
    var errw = std.Io.File.stderr().writerStreaming(io, &.{});
    // README.md § The host: light until `appearance` changes it.
    const t = Tree.create(gpa, io, &cat, .{
        .host = "uitree-headless 0.2",
        .system_dark = false,
        .stderr = &errw.interface,
    }) catch |e| return fail("tree: {t}", .{e});
    h.t = t;

    var q: tree.OpQueue = .init(gpa, io);
    q.wake = Headless.wake;
    q.wake_ctx = &h;
    var tfs: ninep.ns.TreeFs = .{ .gpa = gpa, .t = t, .q = &q };

    // The tree prints its own loud lines.
    ninep.host.Host.loud_fd = null;
    const host = ninep.host.Host.create(gpa, io, tfs.fs()) catch |e| return fail("serve: {t}", .{e});
    var dbg: debug.Debug = .{ .injector = .{ .ptr = &h, .apply = Headless.apply } };
    host.mount("debug", dbg.fs()) catch |e| return fail("serve: {t}", .{e});

    for (opts.addrs.items) |addr| {
        const dial = host.listen(addr) catch |e| return fail("listen {s}: {t}", .{ addr, e });
        std.debug.print("uitree: listening on {s}\n", .{dial});
    }

    var runner: ?*core.machine.Runner = null;
    if (opts.argv.len > 0) {
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
        const sock = host.privatePath() catch |e| return fail("serve: {t}", .{e});
        runner = core.machine.Runner.start(gpa, &margs, sock, &h, Headless.onExit) catch |e|
            return fail("{s}: {t}", .{ opts.argv[0], e });
    }

    // The owner loop: pump when woken or when inject lines wait, until the
    // client exits.
    var status: ?[]const u8 = null;
    while (status == null) {
        h.lock();
        while (!h.woken and h.jobs == null and h.status == null) h.cond.waitUncancelable(h.io, &h.mu);
        h.woken = false;
        const jobs = h.takeJobs();
        status = h.status;
        h.unlock();
        h.pump(&q, jobs, false);
    }

    // The client is gone: no more ops or inject lines, readers get EOF.
    h.lock();
    h.finished = true;
    const late = h.takeJobs();
    h.unlock();
    q.close();
    t.appGone();
    h.pump(&q, late, true);
    host.destroy();
    if (runner) |r| r.join();
    t.destroy();
    cat.deinit();
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
