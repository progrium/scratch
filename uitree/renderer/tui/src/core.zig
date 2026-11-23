//! A thin Zig face on uitcore.h. Everything here is a direct call through
//! the C ABI; the renderer never imports the core's Zig modules.
//!
//! Borrowed reads (strings, node lists, style words) are valid until the
//! next `pump` or `destroy`, as the header says.

const std = @import("std");
const c = @import("c");

pub const Node = c.UitNode;
pub const StyleWord = c.UitStyleWord;
pub const StyleArg = c.UitStyleArg;
pub const Changes = c.UitChanges;
pub const HostCmd = c.UitHostCmd;

pub const Error = error{
    Invalid,
    OutOfMemory,
    NotFound,
    InUse,
    BadValue,
    WrongThread,
    NotSupported,
    Gone,
    Version,
    Io,
    Types,
    Unknown,
};

pub fn check(rc: c_int) Error!void {
    if (rc >= 0) return;
    return switch (rc) {
        c.UIT_EINVAL => error.Invalid,
        c.UIT_ENOMEM => error.OutOfMemory,
        c.UIT_ENOTFOUND => error.NotFound,
        c.UIT_EINUSE => error.InUse,
        c.UIT_EBADVALUE => error.BadValue,
        c.UIT_ETHREAD => error.WrongThread,
        c.UIT_ENOTSUP => error.NotSupported,
        c.UIT_EGONE => error.Gone,
        c.UIT_EVERSION => error.Version,
        c.UIT_EIO => error.Io,
        c.UIT_ETYPES => error.Types,
        else => error.Unknown,
    };
}

pub fn str(s: []const u8) c.UitStr {
    return .{ .ptr = if (s.len == 0) null else s.ptr, .len = s.len };
}

pub fn slice(s: c.UitStr) []const u8 {
    const p = s.ptr orelse return "";
    return p[0..s.len];
}

fn many(comptime T: type, p: [*c]const T, n: usize) []const T {
    if (n == 0 or p == null) return &.{};
    return p[0..n];
}

pub const Attr = struct { []const u8, []const u8 };

pub const Config = struct {
    types: []const u8,
    style_words: []const u8,
    theme_tokens: []const u8,
    system_dark: bool = false,
    wake: *const fn (?*anyopaque) callconv(.c) void,
    wake_ctx: ?*anyopaque,
};

pub const MachineArgs = struct {
    argv: []const []const u8,
    root: []const u8 = "",
    cwd: []const u8 = "",
    env: []const []const u8 = &.{},
    dirs: []const []const u8 = &.{},
    h9_flags: []const []const u8 = &.{},
    err_fd: c_int = -1,
    out_fd: c_int = -1,
};

pub const Core = struct {
    p: *c.UitCore,

    pub fn abiVersion() u32 {
        return c.uit_abi_version();
    }

    pub fn create(cfg: Config) Error!Core {
        const ccfg: c.UitConfig = .{
            .abi_version = c.UIT_ABI_VERSION,
            .types = str(cfg.types),
            .style_words = str(cfg.style_words),
            .theme_tokens = str(cfg.theme_tokens),
            .system_dark = @intFromBool(cfg.system_dark),
            .wake = cfg.wake,
            .wake_ctx = cfg.wake_ctx,
        };
        var out: ?*c.UitCore = null;
        try check(c.uit_create(&ccfg, &out));
        return .{ .p = out.? };
    }

    pub fn destroy(k: Core) void {
        c.uit_destroy(k.p);
    }

    pub fn shutdown(k: Core) void {
        c.uit_shutdown(k.p);
    }

    pub fn lastError(k: Core) []const u8 {
        return slice(c.uit_last_error(k.p));
    }

    pub fn wakeRenderer(k: Core) void {
        c.uit_wake_renderer(k.p);
    }

    pub fn listen(k: Core, addr: []const u8) Error![]const u8 {
        var dial: c.UitStr = .{};
        try check(c.uit_listen(k.p, str(addr), &dial));
        return slice(dial);
    }

    /// Starts the app in h9. Copies every string before it returns.
    pub fn runMachine(k: Core, gpa: std.mem.Allocator, args: MachineArgs) Error!void {
        const conv = struct {
            fn list(a: std.mem.Allocator, xs: []const []const u8) ![]c.UitStr {
                const out = try a.alloc(c.UitStr, xs.len);
                for (xs, out) |x, *o| o.* = str(x);
                return out;
            }
        };
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const argv = conv.list(a, args.argv) catch return error.OutOfMemory;
        const env = conv.list(a, args.env) catch return error.OutOfMemory;
        const dirs = conv.list(a, args.dirs) catch return error.OutOfMemory;
        const flags = conv.list(a, args.h9_flags) catch return error.OutOfMemory;
        const m: c.UitMachineArgs = .{
            .prog = str(args.argv[0]),
            .argv = argv.ptr,
            .argc = argv.len,
            .root = str(args.root),
            .cwd = str(args.cwd),
            .dirs = dirs.ptr,
            .n_dirs = dirs.len,
            .env = env.ptr,
            .n_env = env.len,
            .h9_flags = flags.ptr,
            .n_h9_flags = flags.len,
            .out_fd = args.out_fd,
            .err_fd = args.err_fd,
        };
        try check(c.uit_run_machine(k.p, &m));
    }

    pub fn pump(k: Core) Error!Changes {
        var ch: Changes = std.mem.zeroes(Changes);
        try check(c.uit_pump(k.p, &ch));
        return ch;
    }

    // -- reads -----------------------------------------------------------

    pub fn windows(k: Core) []const c.UitStr {
        var out: [*c]const c.UitStr = null;
        const n = c.uit_windows(k.p, &out);
        return many(c.UitStr, out, n);
    }

    pub fn windowRoot(k: Core, win: []const u8) Node {
        return c.uit_window_root(k.p, str(win));
    }

    pub fn children(k: Core, n: Node) []const Node {
        var out: [*c]const Node = null;
        const len = c.uit_children(k.p, n, &out);
        return many(Node, out, len);
    }

    pub fn overlays(k: Core, win: []const u8) []const Node {
        var out: [*c]const Node = null;
        const len = c.uit_overlays(k.p, str(win), &out);
        return many(Node, out, len);
    }

    pub fn typeOf(k: Core, n: Node) []const u8 {
        return slice(c.uit_type(k.p, n));
    }

    pub fn path(k: Core, n: Node) []const u8 {
        return slice(c.uit_path(k.p, n));
    }

    pub fn windowOf(k: Core, n: Node) []const u8 {
        return slice(c.uit_window_of(k.p, n));
    }

    /// A prop file's value, or null when unset.
    pub fn prop(k: Core, n: Node, file: []const u8) ?[]const u8 {
        var out: c.UitStr = .{};
        const rc = c.uit_prop(k.p, n, str(file), &out);
        if (rc != 1) return null;
        return slice(out);
    }

    /// A bool prop: `on` is true; unset is `default`.
    pub fn flag(k: Core, n: Node, file: []const u8, default: bool) bool {
        const v = k.prop(n, file) orelse return default;
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len == 0) return default;
        return std.mem.eql(u8, t, "on") or std.mem.eql(u8, t, "true");
    }

    pub fn number(k: Core, n: Node, file: []const u8) ?f64 {
        const v = k.prop(n, file) orelse return null;
        return std.fmt.parseFloat(f64, std.mem.trim(u8, v, " \t\r\n")) catch null;
    }

    pub fn style(k: Core, n: Node) []const StyleWord {
        var out: [*c]const StyleWord = null;
        var len: usize = 0;
        if (c.uit_style(k.p, n, &out, &len) < 0) return &.{};
        return many(StyleWord, out, len);
    }

    pub const Line = struct { fields: []const []const u8 };

    /// A data file's lines (`items`). The spike core answers
    /// UIT_ENOTSUP, so until W3 lands this falls back to splitting the
    /// prop's text: tab-separated fields, or blank-separated words with
    /// Plan 9 quotes. Remove the fallback when uit_lines is real.
    pub fn lines(k: Core, a: std.mem.Allocator, n: Node, file: []const u8) ![]Line {
        var out: c.UitLines = .{};
        const rc = c.uit_lines(k.p, n, str(file), &out);
        var res: std.ArrayList(Line) = .empty;
        if (rc >= 0) {
            for (many(c.UitLine, out.lines, out.n)) |ln| {
                const fs = try a.alloc([]const u8, ln.n_fields);
                for (many(c.UitStr, ln.fields, ln.n_fields), fs) |f, *d| d.* = slice(f);
                try res.append(a, .{ .fields = fs });
            }
            return res.items;
        }
        const text = k.prop(n, file) orelse return &.{};
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.trim(u8, line, " \t").len == 0) continue;
            var fs: std.ArrayList([]const u8) = .empty;
            if (std.mem.indexOfScalar(u8, line, '\t') != null) {
                var f = std.mem.splitScalar(u8, line, '\t');
                while (f.next()) |x| try fs.append(a, x);
            } else try splitWords(a, line, &fs);
            try res.append(a, .{ .fields = fs.items });
        }
        return res.items;
    }

    pub fn themeDark(k: Core) bool {
        return c.uit_theme_dark(k.p) != 0;
    }

    pub fn token(k: Core, name: []const u8) ?u32 {
        var rgba: u32 = 0;
        if (c.uit_token(k.p, str(name), &rgba) != 1) return null;
        return rgba;
    }

    // -- input -----------------------------------------------------------

    pub fn emit(k: Core, n: Node, name: []const u8, attrs: []const Attr) Error!void {
        var buf: [8]c.UitAttr = undefined;
        const m = @min(attrs.len, buf.len);
        for (attrs[0..m], buf[0..m]) |a, *b| b.* = .{ .name = str(a[0]), .value = str(a[1]) };
        try check(c.uit_emit(k.p, n, str(name), &buf, m));
    }

    pub fn mirror(k: Core, n: Node, file: []const u8, value: []const u8) Error!void {
        try check(c.uit_mirror(k.p, n, str(file), str(value)));
    }

    /// 1 if a binding matched (an `action` event follows).
    pub fn key(k: Core, win: []const u8, keystroke: []const u8, focused: Node) bool {
        return c.uit_key(k.p, str(win), str(keystroke), focused) == 1;
    }

    pub fn bounds(k: Core, n: Node, x: f32, y: f32, w: f32, h: f32) void {
        _ = c.uit_bounds(k.p, n, x, y, w, h);
    }

    pub fn frameDrawn(k: Core, win: []const u8) void {
        _ = c.uit_frame_drawn(k.p, str(win));
    }

    pub fn windowClosed(k: Core, win: []const u8) void {
        _ = c.uit_window_closed(k.p, str(win));
    }

    pub fn menuAction(k: Core, id: []const u8) void {
        _ = c.uit_menu_action(k.p, str(id));
    }

    pub fn request(k: Core, n: Node, name: []const u8, default_answer: []const u8) u64 {
        return c.uit_request(k.p, n, str(name), null, 0, str(default_answer));
    }
};

/// Plan 9 words: blanks separate, '' quotes, '' inside quotes is one '.
pub fn splitWords(a: std.mem.Allocator, line: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        var w: std.ArrayList(u8) = .empty;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') {
            if (line[i] == '\'') {
                i += 1;
                while (i < line.len) {
                    if (line[i] == '\'') {
                        if (i + 1 < line.len and line[i + 1] == '\'') {
                            try w.append(a, '\'');
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    try w.append(a, line[i]);
                    i += 1;
                }
            } else {
                try w.append(a, line[i]);
                i += 1;
            }
        }
        try out.append(a, w.items);
    }
}

test "splitWords takes Plan 9 quotes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try splitWords(arena.allocator(), "all 'All items' it''s 'don''t'", &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings("All items", out.items[1]);
    try std.testing.expectEqualStrings("its", out.items[2]);
    try std.testing.expectEqualStrings("don't", out.items[3]);
}
