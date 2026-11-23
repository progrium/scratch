//! machine: running the app inside an h9 sandbox (hyper9's h9.Machine),
//! with `$ui` mounted into its namespace. Replaces uitreefs's h9sys crate
//! and its C shim: the core calls h9.Machine directly.
//!
//! Owner: the spike (W0) lands the first version; W4 (serve) owns it after.
//! Built only with -Dh9=true; otherwise `available` is false and
//! uit_run_machine returns UIT_ENOTSUP.

const std = @import("std");
const build_options = @import("build_options");
const abi = @import("../abi.zig");
const Thread = @import("../web.zig").Thread;

pub const available = build_options.h9;
const h9 = if (available) @import("h9") else struct {};

const gpa = std.heap.c_allocator;

/// Where the machine mounts the tree.
pub const mount_point = "/mnt/ui";

pub const OnExit = *const fn (ctx: *anyopaque, status: []const u8) void;

/// One client run on its own thread.
pub const Runner = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    thread: Thread = undefined,
    signals: if (available) h9.Machine.Signals else void = if (available) .{} else {},
    running: std.atomic.Value(bool) = .init(true),
    hung_up: std.atomic.Value(bool) = .init(false),
    out: std.Io.File.Writer = undefined,
    err: std.Io.File.Writer = undefined,
    opts: if (available) h9.Machine.Options else void = undefined,
    prog: []const u8 = "",
    argv: []const []const u8 = &.{},
    ctx: *anyopaque,
    on_exit: OnExit,
    status: []const u8 = "",

    fn io(r: *Runner) std.Io {
        return r.threaded.io();
    }

    /// Starts `args.prog` with the 9P server at unix socket `sock`
    /// mounted on /mnt/ui. Returns once the thread is running.
    pub fn start(a: std.mem.Allocator, args: *const abi.UitMachineArgs, sock: []const u8, ctx: *anyopaque, on_exit: OnExit) !*Runner {
        _ = a;
        if (!available) return error.Unsupported;
        const r = try gpa.create(Runner);
        r.* = .{ .arena = .init(gpa), .threaded = .init(gpa, .{}), .ctx = ctx, .on_exit = on_exit };
        errdefer {
            r.arena.deinit();
            r.threaded.deinit();
            gpa.destroy(r);
        }
        try r.configure(args, sock);
        r.thread = try Thread.spawn(.{}, run, .{r});
        return r;
    }

    fn list(ar: std.mem.Allocator, p: ?[*]const abi.UitStr, n: usize) ![]const []const u8 {
        const out = try ar.alloc([]const u8, n);
        if (n > 0) for (p.?[0..n], out) |s, *o| {
            o.* = try ar.dupe(u8, s.slice());
        };
        return out;
    }

    fn real(r: *Runner, p: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().realPathFileAlloc(r.io(), p, r.arena.allocator()) catch error.NotFound;
    }

    fn configure(r: *Runner, args: *const abi.UitMachineArgs, sock: []const u8) !void {
        const ar = r.arena.allocator();
        var opts: h9.Machine.Options = .{ .stdio = undefined };
        var mounts: std.ArrayList(h9.Mount) = .empty;
        const root = args.root.slice();
        if (root.len == 0 or std.mem.eql(u8, root, "builtin")) {
            try mounts.append(ar, .{ .kind = .builtin, .order = .after });
        } else {
            try mounts.append(ar, .{ .kind = .dir, .src = try r.real(root) });
        }
        for (try list(ar, args.dirs, args.n_dirs)) |d| {
            var why: []const u8 = "";
            var mt = h9.Mount.parse(ar, .dir, d, &why) catch return error.BadDir;
            mt.src = try r.real(mt.src);
            try mounts.append(ar, mt);
        }
        // h9 dials the core's own 9P socket: no fd relay, no shim.
        try mounts.append(ar, .{ .kind = .url, .src = try std.fmt.allocPrint(ar, "unix://{s}", .{sock}), .dst = mount_point });
        opts.mounts = mounts.items;
        const cwd = args.cwd.slice();
        opts.cwd = if (cwd.len > 0) try r.real(cwd) else try r.real(".");
        var env: std.ArrayList(h9.EnvVar) = .empty;
        try env.append(ar, .{ .name = "ui", .value = mount_point });
        for (try list(ar, args.env, args.n_env)) |e| {
            const eq = std.mem.indexOfScalar(u8, e, '=') orelse return error.BadEnv;
            try env.append(ar, .{ .name = e[0..eq], .value = e[eq + 1 ..] });
        }
        opts.env = env.items;
        if (args.n_h9_flags > 0) return error.FlagsNotInSpike;
        // Host fds for the guest's output; on Windows the core's own.
        const posix = @import("builtin").os.tag != .windows;
        const outf: std.Io.File = if (posix and args.out_fd >= 0) .{ .handle = args.out_fd, .flags = .{ .nonblocking = false } } else std.Io.File.stdout();
        const errf: std.Io.File = if (posix and args.err_fd >= 0) .{ .handle = args.err_fd, .flags = .{ .nonblocking = false } } else std.Io.File.stderr();
        r.out = outf.writerStreaming(r.io(), &.{});
        r.err = errf.writerStreaming(r.io(), &.{});
        opts.stdio = .{ .out = &r.out.interface, .err = &r.err.interface };
        opts.signals = &r.signals;
        opts.tmp_dir = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
        r.opts = opts;
        r.prog = try ar.dupe(u8, args.prog.slice());
        r.argv = try list(ar, args.argv, args.argc);
        if (r.argv.len == 0) r.argv = try ar.dupe([]const u8, &.{r.prog});
    }

    fn run(r: *Runner) void {
        const ar = r.arena.allocator();
        var opts = r.opts;
        const prog: h9.Program = if (std.mem.startsWith(u8, r.prog, "./") or std.mem.startsWith(u8, r.prog, "../")) blk: {
            const bytes = std.Io.Dir.cwd().readFileAlloc(r.io(), r.prog, ar, .limited(1 << 30)) catch {
                return r.finish("h9: cannot read program");
            };
            if (h9.linux_elf.machineArch(bytes)) |arch| {
                if (opts.arch == null) opts.arch = arch;
            } else if (h9.aout.parse(bytes)) |hdr| {
                if (opts.arch == null) opts.arch = hdr.arch;
            } else |_| return r.finish("h9: not an executable");
            break :blk .{ .bytes = bytes };
        } else .{ .guest = r.prog };
        var m = h9.Machine.init(gpa, r.io(), opts) catch |e| {
            return r.finish(std.fmt.allocPrint(ar, "h9: cannot create machine: {t}", .{e}) catch "h9: cannot create machine");
        };
        const st = m.run(prog, r.argv);
        const msg: []const u8 = if (st) |s| switch (s) {
            .exited => |x| ar.dupe(u8, x) catch "",
            .killed => |x| ar.dupe(u8, x) catch "killed",
        } else |e| std.fmt.allocPrint(ar, "{s}: {s}", .{ r.prog, if (m.err_msg.len > 0) m.err_msg else @errorName(e) }) catch "h9 failed";
        if (!m.stuck) m.deinit();
        r.finish(msg);
    }

    fn finish(r: *Runner, status: []const u8) void {
        r.status = status;
        r.running.store(false, .release);
        r.on_exit(r.ctx, status);
    }

    /// Any thread: a hangup note to the client.
    pub fn hangup(r: *Runner) void {
        if (r.hung_up.swap(true, .acq_rel)) return;
        if (!available) return;
        if (r.running.load(.acquire)) r.signals.hangup(r.io());
    }

    pub fn join(r: *Runner) void {
        r.thread.join();
        r.arena.deinit();
        r.threaded.deinit();
        gpa.destroy(r);
    }
};

test {
    std.testing.refAllDecls(@This());
}
