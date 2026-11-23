//! Snapshots: an immutable, reference-counted view of the tree that 9P
//! threads read without the owner thread (interface I4's read side).
//!
//! `Tree.publish` makes one per pump; `Tree.acquire` hands it out from any
//! thread. A snapshot holds its `State` alive however many ops follow, so a
//! reader sees one consistent tree. Bounds are the exception: they are
//! layout results, read live under a lock.
//!
//! Paths are client paths from `$ui`, as in path.zig. Every one-line file
//! reads back as its value and one newline; an empty value reads as
//! nothing. `bytes` props, `clip`, assets and drag data read exactly.

const std = @import("std");
const proto = @import("../proto/root.zig");
const types = @import("../types/root.zig");
const state = @import("state.zig");
const pathm = @import("path.zig");
const docm = @import("doc.zig");
const treem = @import("tree.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const State = state.State;
const Handle = state.Handle;
const Blob = state.Blob;
const Error = proto.Error;
const Loc = pathm.Loc;

/// What a file is, for its 9P mode and how a server treats opens.
pub const Kind = enum {
    dir,
    /// Command lines, applied together at each write (or at clunk).
    ctl,
    /// A one-line or multi-line text file, written whole at clunk.
    text,
    /// A data file: lines, written whole at clunk.
    data,
    /// Raw bytes, written whole at clunk.
    bytes,
    /// An event stream (`events`): subscribe at open.
    events,
    /// The trace stream: subscribe at open.
    trace,
    /// Read only.
    readonly,
};

pub const Stat = struct {
    name: []const u8,
    kind: Kind,
    len: u64,
    /// Bumped when the file changes, for the 9P qid version.
    ver: u32,
};

pub const Snapshot = struct {
    rc: std.atomic.Value(u32) = .init(1),
    gpa: Allocator,
    st: *State,
    tree: *treem.Tree,

    pub fn create(gpa: Allocator, st: *State, tree: *treem.Tree) Allocator.Error!*Snapshot {
        const s = gpa.create(Snapshot) catch |e| {
            st.unref(gpa);
            return e;
        };
        s.* = .{ .gpa = gpa, .st = st, .tree = tree };
        return s;
    }

    pub fn retain(s: *Snapshot) *Snapshot {
        _ = s.rc.fetchAdd(1, .monotonic);
        return s;
    }

    /// Any thread.
    pub fn release(s: *Snapshot) void {
        if (s.rc.fetchSub(1, .acq_rel) != 1) return;
        s.st.unref(s.gpa);
        s.gpa.destroy(s);
    }

    /// The app quit: every access should fail with `app gone`.
    pub fn gone(s: *const Snapshot) bool {
        return s.st.gone;
    }

    /// The state generation, bumped by every applied op.
    pub fn generation(s: *const Snapshot) u32 {
        return s.st.gen;
    }

    pub fn state_(s: *const Snapshot) *const State {
        return s.st;
    }

    pub fn resolve(s: *const Snapshot, arena: Allocator, p: []const u8, d: ?*proto.Diag) Error!Loc {
        if (s.st.gone) return error.AppGone;
        return pathm.resolve(s.st, s.tree.cat, arena, p, d);
    }

    /// The bus target an open of `p` subscribes to, if it is an `events`
    /// or `trace` file. A server calls `tree.bus.subscribe` with it.
    pub fn streamTarget(s: *const Snapshot, arena: Allocator, p: []const u8) Error!?@import("bus.zig").Target {
        const loc = try s.resolve(arena, p, null);
        return switch (loc) {
            .app => |f| switch (f) {
                .events => .app,
                .trace => .trace,
                else => null,
            },
            .file => |f| if (std.mem.eql(u8, f.name, "events")) .{ .node = f.node } else null,
            else => null,
        };
    }

    pub fn stat(s: *const Snapshot, arena: Allocator, p_in: []const u8) Error!Stat {
        const p = std.mem.trim(u8, p_in, "/");
        const loc = try s.resolve(arena, p, null);
        const base = if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else if (p.len == 0) "/" else p;
        return s.statLoc(arena, loc, base);
    }

    fn statLoc(s: *const Snapshot, arena: Allocator, loc: Loc, name: []const u8) Error!Stat {
        const k = s.kindOf(loc);
        const len: u64 = switch (k) {
            .dir, .events, .trace => 0,
            else => blk: {
                if (loc == .file and std.mem.eql(u8, loc.file.name, "tree")) break :blk 0;
                const empty: []const u8 = "";
                break :blk (s.readLoc(arena, loc) catch empty).len;
            },
        };
        return .{ .name = name, .kind = k, .len = len, .ver = s.verOf(loc) };
    }

    pub fn kindOf(s: *const Snapshot, loc: Loc) Kind {
        return switch (loc) {
            .dir, .drag, .type_dir, .node => .dir,
            .app => |f| switch (f) {
                .ctl => .ctl,
                .events => .events,
                .trace => .trace,
                .version, .style_words, .theme_names => .readonly,
                .keys, .theme_tokens => .data,
                .clip => .bytes,
                else => .text,
            },
            .menu => .data,
            .asset, .drag_data => .bytes,
            .type_file => .readonly,
            .win_file => |f| if (std.mem.eql(u8, f.name, "bounds") or std.mem.eql(u8, f.name, "inner")) .readonly else .text,
            .file => |f| blk: {
                const eq = std.mem.eql;
                if (eq(u8, f.name, "ctl")) break :blk .ctl;
                if (eq(u8, f.name, "events")) break :blk .events;
                if (eq(u8, f.name, "bounds")) break :blk .readonly;
                if (eq(u8, f.name, "tree")) break :blk .data;
                const n = s.st.node(f.node).?;
                const p = n.ty.prop(f.name) orelse break :blk .text;
                if (p.readonly) break :blk .readonly;
                break :blk switch (p.form) {
                    .data => .data,
                    .bytes => .bytes,
                    else => .text,
                };
            },
        };
    }

    fn verOf(s: *const Snapshot, loc: Loc) u32 {
        const st = s.st;
        return switch (loc) {
            .node => |h| st.node(h).?.ver,
            .file => |f| blk: {
                const n = st.node(f.node).?;
                break :blk if (n.file(f.name)) |x| x.ver else n.ver;
            },
            .win_file => |f| blk: {
                const w = st.winOfRoot(f.root).?;
                const eq = std.mem.eql;
                break :blk if (eq(u8, f.name, "title")) w.title_ver else if (eq(u8, f.name, "state")) w.state_ver else if (eq(u8, f.name, "focus")) w.focus_ver else w.ver;
            },
            .app => |f| switch (f) {
                .keys => st.keys_ver,
                .clip => st.clip_ver,
                .theme_tokens => st.tokens_ver,
                .theme_name, .theme_pref, .theme_mode => st.theme_ver,
                .theme_names => 0,
                .ctl, .events, .trace, .version, .style_words => 0,
            },
            .menu => |m| if (std.mem.eql(u8, m, "bar")) st.bar_ver else if (st.menu(m)) |x| x.ver else 0,
            .asset => |m| if (st.asset(m)) |x| x.ver else 0,
            .drag, .drag_data => |n| if (st.drag(n)) |x| x.ver else 0,
            else => 0,
        };
    }

    /// A directory's entries.
    pub fn list(s: *const Snapshot, arena: Allocator, p_in: []const u8) Error![]Stat {
        const p = std.mem.trim(u8, p_in, "/");
        const loc = try s.resolve(arena, p, null);
        const st = s.st;
        var names: std.ArrayList([]const u8) = .empty;
        switch (loc) {
            .dir => |d| switch (d) {
                .root => {
                    try names.appendSlice(arena, &.{ "version", "ctl", "events", "trace", "keys", "clip", "menu", "theme", "asset", "types", "style", "win" });
                    if (st.drags.items.len > 0) try names.append(arena, "drag");
                },
                .menu => {
                    try names.append(arena, "bar");
                    for (st.menus.items) |m| try names.append(arena, m.name.bytes);
                },
                .theme => try names.appendSlice(arena, &pathm.theme_files),
                .asset => for (st.assets.items) |m| try names.append(arena, m.name.bytes),
                .types => for (s.tree.cat.all()) |t| try names.append(arena, t.name),
                .style => try names.append(arena, "words"),
                .win => for (st.wins.items) |w| try names.append(arena, w.nameStr()),
                .drag => for (st.drags.items) |dg| try names.append(arena, try std.fmt.allocPrint(arena, "{d}", .{dg.n})),
            },
            .drag => try names.append(arena, "data"),
            .type_dir => try names.appendSlice(arena, &.{ "spec", "version" }),
            .node => |h| {
                const n = st.node(h).?;
                if (n.kind == .node) {
                    try names.appendSlice(arena, &state.common_special);
                    try names.appendSlice(arena, &state.common_writable);
                    for (n.ty.props) |pr| try names.append(arena, pr.name);
                    if (n.parent == 0) {
                        for (state.window_files) |f| if (st.child(h, f) == null) try names.append(arena, f);
                        try names.append(arena, "over");
                    }
                }
                for (n.children.items) |c| try names.append(arena, st.node(c).?.nameStr());
            },
            else => return error.BadValue,
        }
        const out = try arena.alloc(Stat, names.items.len);
        for (names.items, out) |name, *o| {
            const child = if (p.len == 0) name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ p, name });
            const cl = try s.resolve(arena, child, null);
            o.* = try s.statLoc(arena, cl, name);
        }
        return out;
    }

    /// A file's whole contents, in `arena`.
    pub fn read(s: *const Snapshot, arena: Allocator, p: []const u8) Error![]const u8 {
        return s.readLoc(arena, try s.resolve(arena, p, null));
    }

    fn line(arena: Allocator, v: []const u8) Allocator.Error![]const u8 {
        if (v.len == 0) return "";
        return std.mem.concat(arena, u8, &.{ v, "\n" });
    }

    pub fn readLoc(s: *const Snapshot, arena: Allocator, loc: Loc) Error![]const u8 {
        const st = s.st;
        const t = s.tree;
        var aw: Writer.Allocating = .init(arena);
        const w = &aw.writer;
        const W = error{OutOfMemory};
        const out = struct {
            fn f(e: Writer.Error) W {
                return switch (e) {
                    error.WriteFailed => error.OutOfMemory,
                };
            }
        }.f;
        switch (loc) {
            .dir, .drag, .type_dir, .node => return error.BadValue,
            .app => |f| switch (f) {
                .version => {
                    w.print("uitree 1.0\nhost {s}\nlayer core 1.0\nlayer components 1.0\n", .{t.cfg.host}) catch |e| return out(e);
                    for (types.profiles) |pr| if (t.cat.claims(pr.name)) w.print("profile {s}\n", .{pr.name}) catch |e| return out(e);
                    w.print("cmdkey {s}\nfeature batch\n", .{t.cfg.cmdkey}) catch |e| return out(e);
                },
                .ctl => return app_ctl_help,
                .events, .trace => return "",
                .keys => return line(arena, Blob.str(st.keys)),
                .clip => return Blob.str(st.clip),
                .theme_tokens => {
                    for (t.cat.theme_tokens) |tk|
                        w.print("{s} {s}\n", .{ tk.name, st.tokenValue(tk) }) catch |e| return out(e);
                    for (treem.length_tokens) |l| w.print("{s} {s}\n", .{ l.name, st.token(l.name) orelse l.value }) catch |e| return out(e);
                    if (t.cat.theme_tokens.len == 0) for (st.tokens.items) |tk| {
                        if (state.inList(&.{ "radius", "radius-lg" }, tk.name.bytes)) continue;
                        w.print("{s} {s}\n", .{ tk.name.bytes, tk.val.bytes }) catch |e| return out(e);
                    };
                },
                .theme_name => return line(arena, Blob.str(st.theme_name)),
                .theme_names => for (t.cat.themes) |th| {
                    proto.tokenize.quoteWord(w, th.name) catch |e| return out(e);
                    w.print(" mode={s}", .{if (th.dark) "dark" else "light"}) catch |e| return out(e);
                    if (th.family.len > 0) {
                        w.writeAll(" family=") catch |e| return out(e);
                        proto.tokenize.quoteValue(w, th.family) catch |e| return out(e);
                    }
                    w.writeByte('\n') catch |e| return out(e);
                },
                .theme_pref => return line(arena, @tagName(st.pref)),
                .theme_mode => return line(arena, if (st.dark()) "dark" else "light"),
                .style_words => t.cat.writeStyleWords(w) catch |e| return out(e),
            },
            .menu => |m| {
                if (std.mem.eql(u8, m, "bar")) return line(arena, Blob.str(st.bar));
                const x = st.menu(m) orelse return error.NotFound;
                return line(arena, x.val.bytes);
            },
            .asset => |m| return (st.asset(m) orelse return error.NotFound).val.bytes,
            .drag_data => |n| return (st.drag(n) orelse return error.NotFound).val.bytes,
            .type_file => |f| {
                if (std.mem.eql(u8, f.name, "spec")) return f.ty.spec;
                var buf: [128]u8 = undefined;
                return arena.dupe(u8, f.ty.version(&buf));
            },
            .win_file => |f| {
                const win = st.winOfRoot(f.root).?;
                const eq = std.mem.eql;
                if (eq(u8, f.name, "title")) return line(arena, Blob.str(win.title));
                if (eq(u8, f.name, "state")) return line(arena, @tagName(win.shownState()));
                if (eq(u8, f.name, "focus")) {
                    if (win.focus == 0 or st.node(win.focus) == null) return "";
                    st.relPath(w, win.focus) catch |e| return out(e);
                    w.writeByte('\n') catch |e| return out(e);
                } else if (eq(u8, f.name, "bounds")) {
                    s.writeBounds(w, f.root) catch |e| return out(e);
                } else if (eq(u8, f.name, "inner")) {
                    if (t.shared.get(t.io, f.root)) |b| {
                        w.print("{d} {d}\n", .{ b[2], b[3] }) catch |e| return out(e);
                    } else if (win.prop("size")) |sz| {
                        const i = std.mem.indexOfScalar(u8, sz, ',') orelse return line(arena, sz);
                        w.print("{s} {s}\n", .{ sz[0..i], sz[i + 1 ..] }) catch |e| return out(e);
                    } else return "0 0\n";
                }
            },
            .file => |f| return s.readNodeFile(arena, f.node, f.name),
        }
        return aw.written();
    }

    fn writeBounds(s: *const Snapshot, w: *Writer, h: Handle) Writer.Error!void {
        const b = s.tree.shared.get(s.tree.io, h) orelse [4]i64{ 0, 0, 0, 0 };
        try w.print("{d} {d} {d} {d}\n", .{ b[0], b[1], b[2], b[3] });
    }

    fn readNodeFile(s: *const Snapshot, arena: Allocator, h: Handle, name: []const u8) Error![]const u8 {
        const st = s.st;
        const n = st.node(h).?;
        const eq = std.mem.eql;
        var aw: Writer.Allocating = .init(arena);
        const w = &aw.writer;
        if (eq(u8, name, "type")) return line(arena, n.ty.name);
        if (eq(u8, name, "events")) return "";
        if (eq(u8, name, "ctl")) {
            if (n.kind == .over) return over_ctl_help;
            w.writeAll(node_ctl_help) catch return error.OutOfMemory;
            if (n.parent == 0) w.writeAll(window_ctl_help) catch return error.OutOfMemory;
            for (n.ty.verbs) |v| {
                w.writeAll(v.name) catch return error.OutOfMemory;
                if (v.args.len > 0) w.print(" {s}", .{v.args}) catch return error.OutOfMemory;
                if (v.class) |c| w.print(" {s}", .{@tagName(c)}) catch return error.OutOfMemory;
                w.writeByte('\n') catch return error.OutOfMemory;
            }
            return aw.written();
        }
        if (eq(u8, name, "order")) {
            for (n.order.items, 0..) |c, i| {
                if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
                w.writeAll(st.node(c).?.nameStr()) catch return error.OutOfMemory;
            }
            if (n.order.items.len > 0) w.writeByte('\n') catch return error.OutOfMemory;
            return aw.written();
        }
        if (eq(u8, name, "bounds")) {
            s.writeBounds(w, h) catch return error.OutOfMemory;
            return aw.written();
        }
        if (eq(u8, name, "tree")) {
            docm.print(w, arena, st, h) catch return error.OutOfMemory;
            return aw.written();
        }
        if (n.ty.prop(name)) |p| if (p.form == .bytes) return n.value(name);
        return line(arena, n.value(name));
    }
};

pub const node_ctl_help =
    \\set PATH [word ...] [prop=value ...] [: style ...]
    \\new TYPE PATH [word ...] [prop=value ...] [: style ...]
    \\delete PATH
    \\tree PATH <<END
    \\
;

pub const window_ctl_help =
    \\show
    \\activate
    \\close
    \\destroy
    \\state normal|min|max|full|hidden
    \\notify text [type=info|success|warning|error]
    \\ask close|none
    \\
;

pub const over_ctl_help =
    \\new TYPE NAME [word ...] [prop=value ...] [: style ...]
    \\delete NAME
    \\
;

pub const app_ctl_help =
    \\window NAME [prop=value ...]
    \\set win/NAME/PATH [word ...] [prop=value ...] [: style ...]
    \\new TYPE win/NAME/PATH [word ...] [prop=value ...] [: style ...]
    \\delete win/NAME/PATH
    \\tree win/NAME/PATH <<END
    \\set ID [enabled=on|off] [check=on|off|mixed]
    \\ask close|quit|open|none ...
    \\begin
    \\commit
    \\abort
    \\theme load PATH
    \\quit
    \\
;
