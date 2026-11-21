//! gpuifs's C ABI over `h9.Machine` (DESIGN.md § Embedding h9).
//!
//! The ABI is in `h9sys.h`. The shim keeps a copy of the config, because
//! `h9.Machine.Options` must outlive the machine and because the program's
//! architecture (read from a host a.out's header) is only known at `h9_run`.
//! So `h9_new` checks the config by compiling its namespace plan, and
//! `h9_run` makes the machine, runs the program and frees the machine.
//!
//! `h9_hangup` and `h9_stop` only set flags. A hangup that comes before
//! the run starts is remembered, so the run ends at once with the same
//! note h9 gives a hung-up machine.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");

const gpa = std.heap.c_allocator;

pub const H9Config = extern struct {
    root: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    dirs: ?[*]const ?[*:0]const u8,
    ninep_fd: c_int,
    ninep_dst: ?[*:0]const u8,
    env: ?[*]const ?[*:0]const u8,
    out_fd: c_int,
    err_fd: c_int,
    profile: ?[*:0]const u8,
    policy_flags: ?[*]const ?[*:0]const u8,
};

const H9Machine = struct {
    arena_state: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    opts: h9.Machine.Options,
    signals: h9.Machine.Signals = .{},
    out: std.Io.File.Writer,
    err: std.Io.File.Writer,
    /// A hangup or stop asked for before or between runs.
    early: std.atomic.Value(u8) = .init(0),
    running: std.atomic.Value(bool) = .init(false),
    /// Set once a run ended stuck: the machine's memory is never freed.
    stuck: bool = false,

    fn io(m: *H9Machine) std.Io {
        return m.threaded.io();
    }
};

const early_hangup = 1;
const early_stop = 2;

fn span(p: ?[*:0]const u8) []const u8 {
    return if (p) |s| std.mem.span(s) else "";
}

fn list(arena: std.mem.Allocator, p: ?[*]const ?[*:0]const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const items = p orelse return out.items;
    var i: usize = 0;
    while (items[i]) |s| : (i += 1) try out.append(arena, try arena.dupe(u8, std.mem.span(s)));
    return out.items;
}

fn setErr(buf: ?[*]u8, len: usize, comptime fmt: []const u8, args: anytype) void {
    const b = buf orelse return;
    if (len == 0) return;
    const out = std.fmt.bufPrint(b[0 .. len - 1], fmt, args) catch b[0 .. len - 1];
    b[out.len] = 0;
}

fn copyOut(buf: ?[*]u8, len: usize, s: []const u8) void {
    const b = buf orelse return;
    if (len == 0) return;
    const n = @min(s.len, len - 1);
    @memcpy(b[0..n], s[0..n]);
    b[n] = 0;
}

const ConfigError = error{ Usage, OutOfMemory };

/// Resolves a host path the way h9's CLI does: absolute, symlinks resolved.
fn real(m: *H9Machine, arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(m.io(), p, arena) catch error.NotFound;
}

/// The h9 sandbox flags gpuifs passes through, as h9 spells them:
/// `--name value` or `--name=value`.
fn applyFlags(m: *H9Machine, arena: std.mem.Allocator, flags: []const []const u8, why: *[]const u8) !void {
    var pol = &m.opts.policy;
    var readable: std.ArrayList([]const u8) = .empty;
    var writable: std.ArrayList([]const u8) = .empty;
    var read_deny: std.ArrayList([]const u8) = .empty;
    var net_allow: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < flags.len) : (i += 1) {
        const a = flags[i];
        if (std.mem.eql(u8, a, "--host-fs")) {
            pol.host_fs = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-guest-tools")) {
            m.opts.guest_tools = false;
            continue;
        }
        const name, const val = blk: {
            if (std.mem.indexOfScalar(u8, a, '=')) |eq| break :blk .{ a[0..eq], a[eq + 1 ..] };
            if (i + 1 >= flags.len) {
                why.* = try std.fmt.allocPrint(arena, "{s} needs a value", .{a});
                return error.Usage;
            }
            i += 1;
            break :blk .{ a, flags[i] };
        };
        const bad = error.Usage;
        if (std.mem.eql(u8, name, "--profile")) {
            pol.profile = std.meta.stringToEnum(h9.policy.Profile, val) orelse return bad;
        } else if (std.mem.eql(u8, name, "--sandbox")) {
            m.opts.cwd = try real(m, arena, val);
            pol.cwd_writable = true;
            pol.profile = .tight;
        } else if (std.mem.eql(u8, name, "--readable")) {
            try readable.append(arena, try real(m, arena, val));
        } else if (std.mem.eql(u8, name, "--writable")) {
            try writable.append(arena, try real(m, arena, val));
        } else if (std.mem.eql(u8, name, "--read-deny")) {
            try read_deny.append(arena, real(m, arena, val) catch val);
        } else if (std.mem.eql(u8, name, "--write")) {
            pol.write = std.meta.stringToEnum(h9.policy.WriteMode, val) orelse return bad;
        } else if (std.mem.eql(u8, name, "--net")) {
            pol.net = std.meta.stringToEnum(h9.policy.NetMode, val) orelse return bad;
        } else if (std.mem.eql(u8, name, "--net-allow")) {
            try net_allow.append(arena, val);
        } else if (std.mem.eql(u8, name, "--memory")) {
            pol.memory = h9.policy.parseSize(val) orelse return bad;
        } else if (std.mem.eql(u8, name, "--timeout")) {
            pol.timeout_ns = h9.policy.parseDuration(val) orelse return bad;
            if (pol.timeout_ns == 0) return bad;
        } else if (std.mem.eql(u8, name, "--pids")) {
            pol.pids = std.fmt.parseInt(u32, val, 10) catch return bad;
        } else if (std.mem.eql(u8, name, "--cpus")) {
            pol.cpus = std.fmt.parseInt(u32, val, 10) catch return bad;
        } else if (std.mem.eql(u8, name, "--backend")) {
            m.opts.backend = std.meta.stringToEnum(h9.vmm.BackendKind, val) orelse return bad;
        } else if (std.mem.eql(u8, name, "--arch")) {
            m.opts.arch = std.meta.stringToEnum(h9.vmm.Arch, val) orelse return bad;
        } else {
            why.* = try std.fmt.allocPrint(arena, "unknown h9 flag {s}", .{name});
            return error.Usage;
        }
    }
    pol.readable = readable.items;
    pol.writable = writable.items;
    pol.read_deny = read_deny.items;
    pol.net_allow = net_allow.items;
}

fn configure(m: *H9Machine, cfg: *const H9Config, why: *[]const u8) !void {
    const arena = m.arena_state.allocator();
    var mounts: std.ArrayList(h9.Mount) = .empty;

    // The root: h9's built-in root, or a host tree on `/`.
    const root = span(cfg.root);
    if (root.len == 0 or std.mem.eql(u8, root, "builtin")) {
        try mounts.append(arena, .{ .kind = .builtin, .order = .after });
    } else {
        try mounts.append(arena, .{ .kind = .dir, .src = real(m, arena, root) catch {
            why.* = try std.fmt.allocPrint(arena, "--root {s}: not found", .{root});
            return error.Usage;
        } });
    }
    for (try list(arena, cfg.dirs)) |d| {
        var mw: []const u8 = "";
        var mt = h9.Mount.parse(arena, .dir, d, &mw) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                why.* = try std.fmt.allocPrint(arena, "--dir {s}: {s}", .{ d, mw });
                return error.Usage;
            },
        };
        mt.src = real(m, arena, mt.src) catch {
            why.* = try std.fmt.allocPrint(arena, "--dir {s}: not found", .{mt.src});
            return error.Usage;
        };
        try mounts.append(arena, mt);
    }
    // An empty destination mounts nothing (h9sys's own tests).
    const dst = span(cfg.ninep_dst);
    if (cfg.ninep_fd >= 0 and dst.len > 0) {
        try mounts.append(arena, .{ .kind = .fd, .fd = cfg.ninep_fd, .dst = try arena.dupe(u8, dst) });
    }
    m.opts.mounts = mounts.items;

    const cwd = span(cfg.cwd);
    if (cwd.len > 0) m.opts.cwd = real(m, arena, cwd) catch {
        why.* = try std.fmt.allocPrint(arena, "cwd {s}: not found", .{cwd});
        return error.Usage;
    };

    var env: std.ArrayList(h9.EnvVar) = .empty;
    for (try list(arena, cfg.env)) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse {
            why.* = try std.fmt.allocPrint(arena, "env {s}: not name=value", .{e});
            return error.Usage;
        };
        try env.append(arena, .{ .name = e[0..eq], .value = e[eq + 1 ..] });
    }
    m.opts.env = env.items;

    const profile = span(cfg.profile);
    if (profile.len > 0) m.opts.policy.profile = std.meta.stringToEnum(h9.policy.Profile, profile) orelse {
        why.* = try std.fmt.allocPrint(arena, "unknown profile {s}", .{profile});
        return error.Usage;
    };
    applyFlags(m, arena, try list(arena, cfg.policy_flags), why) catch |e| {
        if (why.len == 0) why.* = "bad h9 flag";
        return e;
    };

    // The same check `init` makes, without making a VM.
    var conflict: []const u8 = "";
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    _ = h9.Machine.compilePlan(scratch.allocator(), m.opts, &conflict) catch |e| {
        why.* = try std.fmt.allocPrint(arena, "{s}", .{if (conflict.len > 0) conflict else @errorName(e)});
        return error.Usage;
    };
}

export fn h9_new(cfg: *const H9Config, out: *?*H9Machine, err: ?[*]u8, errlen: usize) c_int {
    out.* = null;
    const m = gpa.create(H9Machine) catch {
        setErr(err, errlen, "out of memory", .{});
        return -1;
    };
    m.* = .{
        .arena_state = .init(gpa),
        .threaded = .init(gpa, .{}),
        .opts = .{ .stdio = undefined },
        .out = undefined,
        .err = undefined,
    };
    const fileOf = struct {
        fn f(fd: c_int) std.Io.File {
            return .{ .handle = fd, .flags = .{ .nonblocking = false } };
        }
    }.f;
    m.out = fileOf(if (cfg.out_fd >= 0) cfg.out_fd else 1).writerStreaming(m.io(), &.{});
    m.err = fileOf(if (cfg.err_fd >= 0) cfg.err_fd else 2).writerStreaming(m.io(), &.{});
    m.opts.stdio = .{ .out = &m.out.interface, .err = &m.err.interface };
    m.opts.signals = &m.signals;
    m.opts.tmp_dir = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";

    var why: []const u8 = "";
    configure(m, cfg, &why) catch |e| {
        setErr(err, errlen, "{s}", .{if (why.len > 0) why else @errorName(e)});
        h9_free(m);
        return -1;
    };
    out.* = m;
    return 0;
}

/// Runs `prog` to completion: 0 with the exits string in `status`, 1 with
/// a kill note, or a negative error with `status` holding why.
export fn h9_run(m: *H9Machine, prog_z: [*:0]const u8, argv_z: ?[*]const ?[*:0]const u8, status: ?[*]u8, statuslen: usize) c_int {
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    // A stuck run may still touch argv and the program bytes; leak them then.
    defer if (!m.stuck) run_arena.deinit();
    const arena = run_arena.allocator();

    const prog_arg = std.mem.span(prog_z);
    const argv = list(arena, argv_z) catch return oom(status, statuslen);
    const argv_full: []const []const u8 = if (argv.len > 0) argv else &.{prog_arg};

    var opts = m.opts;
    const prog: h9.Program = if (std.mem.startsWith(u8, prog_arg, "./") or std.mem.startsWith(u8, prog_arg, "../")) blk: {
        const bytes = std.Io.Dir.cwd().readFileAlloc(m.io(), prog_arg, arena, .limited(1 << 30)) catch |e| {
            setErr(status, statuslen, "{s}: {t}", .{ prog_arg, e });
            return -2;
        };
        if (h9.linux_elf.machineArch(bytes)) |a| {
            if (opts.arch == null) opts.arch = a;
            break :blk .{ .bytes = bytes };
        }
        const hdr = h9.aout.parse(bytes) catch |e| {
            setErr(status, statuslen, "{s}: not a 9front executable: {t}", .{ prog_arg, e });
            return -3;
        };
        if (opts.arch == null) opts.arch = hdr.arch;
        break :blk .{ .bytes = bytes };
    } else .{ .guest = prog_arg };

    var machine = h9.Machine.init(gpa, m.io(), opts) catch |e| {
        setErr(status, statuslen, "cannot create machine: {t}", .{e});
        return -4;
    };
    m.running.store(true, .release);
    // A hangup or stop that came before the run: deliver it now. Notes
    // posted before `run` starts are dropped, so this is checked once more
    // just after, from a watcher.
    const early = m.early.swap(0, .acq_rel);
    if (early != 0) {
        m.running.store(false, .release);
        machine.deinit();
        copyOut(status, statuslen, if (early & early_stop != 0) "h9: stopped" else "hangup");
        return 1;
    }
    const watcher = std.Thread.spawn(.{}, watchEarly, .{m}) catch null;
    const st = machine.run(prog, argv_full);
    m.running.store(false, .release);
    if (watcher) |w| w.join();
    const result: c_int = if (st) |s| switch (s) {
        .exited => |msg| blk: {
            copyOut(status, statuslen, msg);
            break :blk 0;
        },
        .killed => |msg| blk: {
            copyOut(status, statuslen, msg);
            break :blk 1;
        },
    } else |e| blk: {
        setErr(status, statuslen, "{s}: {s}", .{ prog_arg, if (machine.err_msg.len > 0) machine.err_msg else @errorName(e) });
        break :blk switch (e) {
            error.NotFound => -2,
            error.NotExecutable => -3,
            else => -5,
        };
    };
    if (machine.stuck) {
        // Its process may still be in a host call: free nothing.
        m.stuck = true;
    } else machine.deinit();
    return result;
}

/// Re-posts a hangup or stop that raced the start of `run`, while it runs.
fn watchEarly(m: *H9Machine) void {
    var waited: u32 = 0;
    while (m.running.load(.acquire) and waited < 200) : (waited += 1) {
        const e = m.early.swap(0, .acq_rel);
        if (e & early_stop != 0) m.signals.stop(m.io()) else if (e & early_hangup != 0) m.signals.hangup(m.io());
        std.Io.sleep(m.io(), .fromMilliseconds(10), .awake) catch {};
    }
}

fn oom(status: ?[*]u8, len: usize) c_int {
    setErr(status, len, "out of memory", .{});
    return -1;
}

export fn h9_hangup(m: *H9Machine) void {
    _ = m.early.fetchOr(early_hangup, .acq_rel);
    if (m.running.load(.acquire)) m.signals.hangup(m.io());
}

export fn h9_stop(m: *H9Machine) void {
    _ = m.early.fetchOr(early_stop, .acq_rel);
    if (m.running.load(.acquire)) m.signals.stop(m.io());
}

export fn h9_free(m: *H9Machine) void {
    // After a stuck run the machine's process may still read the config.
    if (m.stuck) return;
    m.arena_state.deinit();
    m.threaded.deinit();
    gpa.destroy(m);
}
