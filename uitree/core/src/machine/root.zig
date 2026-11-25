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
const term = @import("../tree/term.zig");
const engine = @import("../term/engine.zig");

pub const available = build_options.h9;
const h9 = if (available) @import("h9") else struct {};

const gpa = std.heap.c_allocator;

/// Where the machine mounts the tree.
pub const mount_point = "/mnt/ui";
/// Where $ui is in the Linux view, when the app has one (a mount at #L).
pub const linux_mount_point = "/9" ++ mount_point;

pub const OnExit = *const fn (ctx: *anyopaque, status: []const u8) void;

/// One client run on its own thread.
pub const Runner = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    thread: Thread = undefined,
    signals: if (available) h9.Machine.Signals else void = if (available) .{} else {},
    /// Terminal nodes' pty mode: pairs in this machine whose masters the
    /// core holds (h9's host ptys, `ptyHost`).
    ptys: if (available) h9.Machine.Ptys else void = undefined,
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
        r.ptys = .init(gpa, r.io());
        errdefer {
            r.ptys.deinit();
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
        // A Linux view (a mount at #L) puts the Plan 9 namespace under
        // /9, so $ui is /9/mnt/ui then, as uitreefs did, unless the
        // caller's env says otherwise.
        var linux = false;
        for (try list(ar, args.dirs, args.n_dirs)) |d| {
            var why: []const u8 = "";
            var mt = h9.Mount.parse(ar, .dir, d, &why) catch return error.BadDir;
            mt.src = try r.real(mt.src);
            if (std.mem.eql(u8, mt.dst, "#L") or std.mem.startsWith(u8, mt.dst, "#L/")) linux = true;
            try mounts.append(ar, mt);
        }
        // h9 dials the core's own 9P socket: no fd relay, no shim.
        try mounts.append(ar, .{ .kind = .url, .src = try std.fmt.allocPrint(ar, "unix://{s}", .{sock}), .dst = mount_point });
        opts.mounts = mounts.items;
        const cwd = args.cwd.slice();
        opts.cwd = if (cwd.len > 0) try r.real(cwd) else try r.real(".");
        var env: std.ArrayList(h9.EnvVar) = .empty;
        var ui_given = false;
        for (try list(ar, args.env, args.n_env)) |e| {
            const eq = std.mem.indexOfScalar(u8, e, '=') orelse return error.BadEnv;
            if (std.mem.eql(u8, e[0..eq], "ui")) ui_given = true;
            try env.append(ar, .{ .name = e[0..eq], .value = e[eq + 1 ..] });
        }
        if (!ui_given) try env.append(ar, .{ .name = "ui", .value = if (linux) linux_mount_point else mount_point });
        opts.env = env.items;
        // h9's sandbox flags, as h9 spells them. The network ones for now:
        // `--net=enable` lets a client serve (a local web server for a web
        // view, as Topframe's client does), `--net-allow=PATTERN` limits
        // dials. Anything else is refused rather than ignored.
        var allow: std.ArrayList([]const u8) = .empty;
        const NetMode = @typeInfo(@TypeOf(opts.policy.net)).optional.child;
        for (try list(ar, args.h9_flags, args.n_h9_flags)) |f| {
            if (std.mem.startsWith(u8, f, "--net=")) {
                opts.policy.net = std.meta.stringToEnum(NetMode, f["--net=".len..]) orelse return error.BadFlag;
            } else if (std.mem.startsWith(u8, f, "--net-allow=")) {
                try allow.append(ar, f["--net-allow=".len..]);
            } else return error.BadFlag;
        }
        if (allow.items.len > 0) opts.policy.net_allow = allow.items;
        // Host fds for the guest's output; on Windows the core's own.
        const posix = @import("builtin").os.tag != .windows;
        const outf: std.Io.File = if (posix and args.out_fd >= 0) .{ .handle = args.out_fd, .flags = .{ .nonblocking = false } } else std.Io.File.stdout();
        const errf: std.Io.File = if (posix and args.err_fd >= 0) .{ .handle = args.err_fd, .flags = .{ .nonblocking = false } } else std.Io.File.stderr();
        r.out = outf.writerStreaming(r.io(), &.{});
        r.err = errf.writerStreaming(r.io(), &.{});
        opts.stdio = .{ .out = &r.out.interface, .err = &r.err.interface };
        opts.signals = &r.signals;
        opts.ptys = &r.ptys;
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
        if (available) r.ptys.deinit();
        r.arena.deinit();
        r.threaded.deinit();
        gpa.destroy(r);
    }

    // ---------------------------------------------------------------- pty mode

    /// For term.zig's pty mode: opens pairs in this machine. Owner thread;
    /// valid until `join`, and the core closes every pair before that.
    pub fn ptyHost(r: *Runner) term.PtyHost {
        return .{ .ctx = r, .open = ptyOpen };
    }

    /// One open pair, as the terminal holds it.
    const Pair = struct {
        pty: if (available) *h9.Machine.Pty else void,
        tty_buf: [32]u8 = undefined,
        tty_len: usize = 0,
    };

    fn ptyOpen(ctx: *anyopaque, sink: term.PtySink, size: engine.Size) anyerror!term.PtyConn {
        if (comptime !available) return error.Unsupported;
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const pr = try gpa.create(Pair);
        errdefer gpa.destroy(pr);
        pr.pty = try r.ptys.open(.{ .ctx = sink.ctx, .data = sink.data, .hangup = sink.hangup, .release = sink.release }, winsize(size));
        // The Linux view's name for it (#τ/N in the Plan 9 view).
        pr.tty_len = (std.fmt.bufPrint(&pr.tty_buf, "/dev/pts/{d}", .{pr.pty.n}) catch unreachable).len;
        return .{ .ctx = pr, .tty = pr.tty_buf[0..pr.tty_len], .write = ptyWrite, .resize = ptyResize, .close = ptyClose };
    }

    const Winsize = if (available) h9.hostpty.Winsize else void;

    fn winsize(sz: engine.Size) Winsize {
        if (comptime !available) return {};
        return .{
            .rows = sz.rows,
            .cols = sz.cols,
            .xpixel = std.math.lossyCast(u16, @as(u32, sz.cols) * sz.cell_w_px),
            .ypixel = std.math.lossyCast(u16, @as(u32, sz.rows) * sz.cell_h_px),
        };
    }

    fn ptyWrite(ctx: *anyopaque, bytes: []const u8) void {
        if (comptime !available) return;
        const pr: *Pair = @ptrCast(@alignCast(ctx));
        // Gone (the program's machine ended) or Full (it stopped
        // reading): dropped, as `keys` drops for a reader that stopped.
        pr.pty.write(bytes) catch {};
    }

    fn ptyResize(ctx: *anyopaque, size: engine.Size) void {
        if (comptime !available) return;
        const pr: *Pair = @ptrCast(@alignCast(ctx));
        pr.pty.resize(winsize(size));
    }

    fn ptyClose(ctx: *anyopaque) void {
        if (comptime !available) return;
        const pr: *Pair = @ptrCast(@alignCast(ctx));
        pr.pty.close();
        gpa.destroy(pr);
    }
};

test {
    std.testing.refAllDecls(@This());
}
