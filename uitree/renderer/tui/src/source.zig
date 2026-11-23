//! What the UI reads the tree from and sends input to. In the app this is
//! the core through uitcore.h (`fromCore`); in tests it is `Fake`, a
//! small in-memory tree, so layout and drawing are tested without h9.

const std = @import("std");
const c = @import("c");
const core = @import("core.zig");

pub const Node = core.Node;
pub const Attr = core.Attr;

pub const Source = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        windowRoot: *const fn (*anyopaque, []const u8) Node,
        children: *const fn (*anyopaque, Node) []const Node,
        overlays: *const fn (*anyopaque, []const u8) []const Node,
        typeOf: *const fn (*anyopaque, Node) []const u8,
        path: *const fn (*anyopaque, Node) []const u8,
        prop: *const fn (*anyopaque, Node, []const u8) ?[]const u8,
        style: *const fn (*anyopaque, Node) []const core.StyleWord,
        lines: *const fn (*anyopaque, std.mem.Allocator, Node, []const u8) anyerror![]core.Core.Line,
        token: *const fn (*anyopaque, []const u8) ?u32,
        emit: *const fn (*anyopaque, Node, []const u8, []const Attr) void,
        mirror: *const fn (*anyopaque, Node, []const u8, []const u8) void,
        key: *const fn (*anyopaque, []const u8, []const u8, Node) bool,
        bounds: *const fn (*anyopaque, Node, [4]f32) void,
    };

    pub fn windowRoot(s: Source, win: []const u8) Node {
        return s.vt.windowRoot(s.ptr, win);
    }
    pub fn children(s: Source, n: Node) []const Node {
        return s.vt.children(s.ptr, n);
    }
    pub fn overlays(s: Source, win: []const u8) []const Node {
        return s.vt.overlays(s.ptr, win);
    }
    pub fn typeOf(s: Source, n: Node) []const u8 {
        return s.vt.typeOf(s.ptr, n);
    }
    pub fn path(s: Source, n: Node) []const u8 {
        return s.vt.path(s.ptr, n);
    }
    pub fn prop(s: Source, n: Node, file: []const u8) ?[]const u8 {
        return s.vt.prop(s.ptr, n, file);
    }
    pub fn style(s: Source, n: Node) []const core.StyleWord {
        return s.vt.style(s.ptr, n);
    }
    pub fn lines(s: Source, a: std.mem.Allocator, n: Node, file: []const u8) ![]core.Core.Line {
        return s.vt.lines(s.ptr, a, n, file);
    }
    pub fn token(s: Source, name: []const u8) ?u32 {
        return s.vt.token(s.ptr, name);
    }
    pub fn emit(s: Source, n: Node, name: []const u8, attrs: []const Attr) void {
        s.vt.emit(s.ptr, n, name, attrs);
    }
    pub fn mirror(s: Source, n: Node, file: []const u8, value: []const u8) void {
        s.vt.mirror(s.ptr, n, file, value);
    }
    pub fn key(s: Source, win: []const u8, ks: []const u8, focused: Node) bool {
        return s.vt.key(s.ptr, win, ks, focused);
    }

    pub fn bounds(s: Source, n: Node, x: f32, y: f32, w: f32, h: f32) void {
        s.vt.bounds(s.ptr, n, .{ x, y, w, h });
    }

    /// Text of a prop with one trailing newline dropped (files end in one).
    pub fn text(s: Source, n: Node, file: []const u8) []const u8 {
        const v = s.prop(n, file) orelse return "";
        return std.mem.trimEnd(u8, v, "\n");
    }

    pub fn flag(s: Source, n: Node, file: []const u8, default: bool) bool {
        const v = std.mem.trim(u8, s.prop(n, file) orelse return default, " \t\r\n");
        if (v.len == 0) return default;
        return std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "true");
    }

    pub fn number(s: Source, n: Node, file: []const u8) ?f64 {
        const v = s.prop(n, file) orelse return null;
        return std.fmt.parseFloat(f64, std.mem.trim(u8, v, " \t\r\n")) catch null;
    }
};

// ---------------------------------------------------------------------
// The real core

fn K(p: *anyopaque) core.Core {
    return .{ .p = @ptrCast(@alignCast(p)) };
}

const core_vt: Source.VTable = .{
    .windowRoot = struct {
        fn f(p: *anyopaque, w: []const u8) Node {
            return K(p).windowRoot(w);
        }
    }.f,
    .children = struct {
        fn f(p: *anyopaque, n: Node) []const Node {
            return K(p).children(n);
        }
    }.f,
    .overlays = struct {
        fn f(p: *anyopaque, w: []const u8) []const Node {
            return K(p).overlays(w);
        }
    }.f,
    .typeOf = struct {
        fn f(p: *anyopaque, n: Node) []const u8 {
            return K(p).typeOf(n);
        }
    }.f,
    .path = struct {
        fn f(p: *anyopaque, n: Node) []const u8 {
            return K(p).path(n);
        }
    }.f,
    .prop = struct {
        fn f(p: *anyopaque, n: Node, file: []const u8) ?[]const u8 {
            return K(p).prop(n, file);
        }
    }.f,
    .style = struct {
        fn f(p: *anyopaque, n: Node) []const core.StyleWord {
            return K(p).style(n);
        }
    }.f,
    .lines = struct {
        fn f(p: *anyopaque, a: std.mem.Allocator, n: Node, file: []const u8) anyerror![]core.Core.Line {
            return K(p).lines(a, n, file);
        }
    }.f,
    .token = struct {
        fn f(p: *anyopaque, name: []const u8) ?u32 {
            return K(p).token(name);
        }
    }.f,
    .emit = struct {
        fn f(p: *anyopaque, n: Node, name: []const u8, attrs: []const Attr) void {
            K(p).emit(n, name, attrs) catch |e| std.log.warn("emit {s}: {t}", .{ name, e });
        }
    }.f,
    .mirror = struct {
        fn f(p: *anyopaque, n: Node, file: []const u8, v: []const u8) void {
            K(p).mirror(n, file, v) catch |e| std.log.warn("mirror {s}: {t}", .{ file, e });
        }
    }.f,
    .key = struct {
        fn f(p: *anyopaque, w: []const u8, ks: []const u8, n: Node) bool {
            return K(p).key(w, ks, n);
        }
    }.f,
    .bounds = struct {
        fn f(p: *anyopaque, n: Node, r: [4]f32) void {
            K(p).bounds(n, r[0], r[1], r[2], r[3]);
        }
    }.f,
};

pub fn fromCore(k: core.Core) Source {
    return .{ .ptr = k.p, .vt = &core_vt };
}

// ---------------------------------------------------------------------
// A fake tree for tests

pub const Fake = struct {
    const over: Node = 2;
    a: std.mem.Allocator,
    nodes: std.ArrayList(FNode) = .empty,
    tokens: std.StringHashMapUnmanaged(u32) = .empty,
    /// What the UI sent, one line per call: `emit click inc`, `mirror n value x`.
    log: std.ArrayList(u8) = .empty,

    pub const FNode = struct {
        name: []const u8,
        path: []const u8,
        typ: []const u8,
        parent: Node,
        kids: std.ArrayList(Node) = .empty,
        props: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
        style: []core.StyleWord = &.{},
        /// What the UI last reported for the node's `bounds` file.
        bounds: ?[4]f32 = null,
    };

    /// Use an arena: nothing is freed one by one.
    pub fn init(a: std.mem.Allocator) !*Fake {
        const f = try a.create(Fake);
        f.* = .{ .a = a };
        try f.nodes.append(a, .{ .name = "", .path = "", .typ = "", .parent = 0 });
        try f.nodes.append(a, .{ .name = ".", .path = ".", .typ = "div", .parent = 0 });
        // `over/`: overlays made under it are the window's overlays. It
        // isn't one of the root's children.
        try f.nodes.append(a, .{ .name = "over", .path = "over", .typ = "", .parent = 1 });
        for ([_]struct { []const u8, u32 }{
            .{ "background", 0xffffffff },       .{ "foreground", 0x0a0a0aff }, .{ "muted", 0xf5f5f5ff },
            .{ "muted-foreground", 0x737373ff }, .{ "primary", 0x171717ff },    .{ "primary-foreground", 0xfafafaff },
            .{ "border", 0xe5e5e5ff },           .{ "accent", 0xf5f5f5ff },     .{ "danger", 0xef4444ff },
            .{ "input", 0xe5e5e5ff },            .{ "ring", 0xa3a3a3ff },
        }) |t| try f.tokens.put(a, t[0], t[1]);
        return f;
    }

    pub fn lookup(f: *Fake, path: []const u8) ?Node {
        for (f.nodes.items, 0..) |n, i| if (i > 0 and std.mem.eql(u8, n.path, path)) return @intCast(i);
        return null;
    }

    /// `new TYPE PATH k=v... [: style words]`, one per call. Values may
    /// be quoted with '…'.
    pub fn new(f: *Fake, typ: []const u8, path: []const u8, props: []const [2][]const u8, style_text: []const u8) !Node {
        const parent_path = std.fs.path.dirnamePosix(path) orelse ".";
        const parent = f.lookup(parent_path) orelse return error.NotFound;
        const id: Node = @intCast(f.nodes.items.len);
        try f.nodes.append(f.a, .{ .name = std.fs.path.basenamePosix(path), .path = path, .typ = typ, .parent = parent });
        try f.nodes.items[parent].kids.append(f.a, id);
        for (props) |p| try f.nodes.items[id].props.put(f.a, p[0], p[1]);
        f.nodes.items[id].style = try f.parseStyle(style_text);
        return id;
    }

    pub fn set(f: *Fake, path: []const u8, k: []const u8, v: []const u8) !void {
        const id = f.lookup(path) orelse return error.NotFound;
        if (std.mem.eql(u8, k, "style")) {
            f.nodes.items[id].style = try f.parseStyle(v);
            return;
        }
        try f.nodes.items[id].props.put(f.a, k, v);
    }

    fn parseStyle(f: *Fake, text: []const u8) ![]core.StyleWord {
        var out: std.ArrayList(core.StyleWord) = .empty;
        var it = std.mem.tokenizeAny(u8, text, " \t\n");
        while (it.next()) |w0| {
            var w = w0;
            var state: u32 = c.UIT_STATE_BASE;
            inline for (.{ .{ "hover:", c.UIT_STATE_HOVER }, .{ "active:", c.UIT_STATE_ACTIVE }, .{ "focus:", c.UIT_STATE_FOCUS } }) |p| {
                if (std.mem.startsWith(u8, w, p[0])) {
                    state = p[1];
                    w = w[p[0].len..];
                }
            }
            var name = w;
            var args: std.ArrayList(core.StyleArg) = .empty;
            if (std.mem.indexOfScalar(u8, w, '=')) |eq| {
                name = w[0..eq];
                var ai = std.mem.splitScalar(u8, w[eq + 1 ..], ',');
                while (ai.next()) |x| {
                    var arg: core.StyleArg = .{ .kind = c.UIT_ARG_TEXT, .a = 0, .rgba = 0, .text = core.str(x) };
                    if (f.tokens.get(x)) |rgba| {
                        arg.kind = c.UIT_ARG_RGBA;
                        arg.rgba = rgba;
                    } else if (x.len == 7 and x[0] == '#') {
                        arg.kind = c.UIT_ARG_RGBA;
                        arg.rgba = ((std.fmt.parseInt(u32, x[1..], 16) catch 0) << 8) | 0xff;
                    } else if (std.mem.endsWith(u8, x, "%")) {
                        arg.kind = c.UIT_ARG_PERCENT;
                        arg.a = std.fmt.parseFloat(f32, x[0 .. x.len - 1]) catch 0;
                    } else if (std.fmt.parseFloat(f32, x)) |v| {
                        arg.kind = c.UIT_ARG_PX;
                        arg.a = v;
                    } else |_| {}
                    try args.append(f.a, arg);
                }
            }
            try out.append(f.a, .{
                .name = core.str(name),
                .state = state,
                .group = .{},
                .args = if (args.items.len > 0) args.items.ptr else null,
                .n_args = args.items.len,
            });
        }
        return out.items;
    }

    pub fn source(f: *Fake) Source {
        return .{ .ptr = f, .vt = &fake_vt };
    }

    fn F(p: *anyopaque) *Fake {
        return @ptrCast(@alignCast(p));
    }

    const fake_vt: Source.VTable = .{
        .windowRoot = struct {
            fn f(_: *anyopaque, w: []const u8) Node {
                return if (std.mem.eql(u8, w, "main")) 1 else 0;
            }
        }.f,
        .children = struct {
            fn f(p: *anyopaque, n: Node) []const Node {
                return F(p).nodes.items[n].kids.items;
            }
        }.f,
        .overlays = struct {
            fn f(p: *anyopaque, _: []const u8) []const Node {
                return F(p).nodes.items[over].kids.items;
            }
        }.f,
        .typeOf = struct {
            fn f(p: *anyopaque, n: Node) []const u8 {
                return F(p).nodes.items[n].typ;
            }
        }.f,
        .path = struct {
            fn f(p: *anyopaque, n: Node) []const u8 {
                return F(p).nodes.items[n].path;
            }
        }.f,
        .prop = struct {
            fn f(p: *anyopaque, n: Node, file: []const u8) ?[]const u8 {
                return F(p).nodes.items[n].props.get(file);
            }
        }.f,
        .style = struct {
            fn f(p: *anyopaque, n: Node) []const core.StyleWord {
                return F(p).nodes.items[n].style;
            }
        }.f,
        .lines = struct {
            fn f(p: *anyopaque, a: std.mem.Allocator, n: Node, file: []const u8) anyerror![]core.Core.Line {
                const text = F(p).nodes.items[n].props.get(file) orelse return &.{};
                var res: std.ArrayList(core.Core.Line) = .empty;
                var it = std.mem.tokenizeScalar(u8, text, '\n');
                while (it.next()) |line| {
                    var fs: std.ArrayList([]const u8) = .empty;
                    try core.splitWords(a, line, &fs);
                    try res.append(a, .{ .fields = fs.items });
                }
                return res.items;
            }
        }.f,
        .token = struct {
            fn f(p: *anyopaque, name: []const u8) ?u32 {
                return F(p).tokens.get(name);
            }
        }.f,
        .emit = struct {
            fn f(p: *anyopaque, n: Node, name: []const u8, attrs: []const Attr) void {
                const fk = F(p);
                fk.log.print(fk.a, "emit {s} {s}", .{ name, fk.nodes.items[n].path }) catch {};
                for (attrs) |at| fk.log.print(fk.a, " {s}={s}", .{ at[0], at[1] }) catch {};
                fk.log.append(fk.a, '\n') catch {};
            }
        }.f,
        .mirror = struct {
            fn f(p: *anyopaque, n: Node, file: []const u8, v: []const u8) void {
                const fk = F(p);
                fk.log.print(fk.a, "mirror {s} {s} {s}\n", .{ fk.nodes.items[n].path, file, v }) catch {};
                fk.nodes.items[n].props.put(fk.a, fk.a.dupe(u8, file) catch return, fk.a.dupe(u8, v) catch return) catch {};
            }
        }.f,
        .key = struct {
            fn f(p: *anyopaque, _: []const u8, ks: []const u8, _: Node) bool {
                const fk = F(p);
                fk.log.print(fk.a, "key {s}\n", .{ks}) catch {};
                return false;
            }
        }.f,
        .bounds = struct {
            fn f(p: *anyopaque, n: Node, r: [4]f32) void {
                F(p).nodes.items[n].bounds = r;
            }
        }.f,
    };
};
