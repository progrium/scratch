//! The spike's throwaway tree: one window (`main`), `set`/`new`/`delete`
//! on any `ctl`, prop files, style words, `keys`, `menu/`, events with
//! subscriptions. Just enough for the counter. W3's `tree` replaces it;
//! nothing outside spike/ and abi.zig may import it.
//!
//! Single-threaded: only the owner thread changes it (in `uit_pump`).
//! The 9P threads read it under `Core.mu` instead of from a snapshot,
//! which is the shortcut W3 removes.

const std = @import("std");
const tokenize = @import("../proto/tokenize.zig");
const abi = @import("../abi.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ NotFound, InUse, BadValue, BadSyntax, UnknownStyleWord, OutOfMemory };

/// The protocol text of an error, written into `buf`.
pub fn errText(buf: []u8, e: Error, detail: []const u8) []const u8 {
    const code = switch (e) {
        error.NotFound => "not found",
        error.InUse => "in use",
        error.BadValue => "bad value",
        error.BadSyntax => "bad syntax",
        error.UnknownStyleWord => "unknown style word",
        error.OutOfMemory => "out of memory",
    };
    if (detail.len == 0) return std.fmt.bufPrint(buf, "{s}", .{code}) catch code;
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ code, detail }) catch code;
}

pub const Node = struct {
    id: u32,
    parent: u32,
    name: []u8,
    typ: []u8,
    /// Window-relative path; `.` for the root.
    path: []u8,
    /// Children in `order` order.
    kids: std.ArrayList(u32) = .empty,
    props: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// The parsed style, cached; rebuilt when `style` or the theme changes.
    style: []abi.UitStyleWord = &.{},
    style_arena: std.heap.ArenaAllocator,
    /// `kids` as a plain array for uit_children.
    alive: bool = true,

    pub fn prop(n: *const Node, name: []const u8) ?[]const u8 {
        return n.props.get(name);
    }
};

pub const Token = struct { name: []const u8, light: u32, dark: u32 };

/// One subscription to an `events` file.
pub const Sub = struct {
    /// 0: every event in the app; else that node and its descendants.
    node: u32,
    lines: std.ArrayList([]u8) = .empty,
    /// A partial line left over from a short read.
    partial: []u8 = &.{},
    partial_off: usize = 0,
    closed: bool = false,
    refs: u32 = 1,
};

pub const KeyBinding = struct { key: []u8, action: []u8, context: []u8, global: bool };

/// What a pump changed, for UitChanges. Cleared by `Tree.beginPump`.
pub const Changes = struct {
    created: std.ArrayList(u32) = .empty,
    removed: std.ArrayList(u32) = .empty,
    props: std.ArrayList(abi.UitPropChange) = .empty,
    cmds: std.ArrayList(abi.UitHostCmd) = .empty,
    dirty_main: bool = false,
};

pub const Tree = struct {
    gpa: Allocator,
    /// Index = handle. 0 is unused.
    nodes: std.ArrayList(?*Node) = .empty,
    main_root: u32 = 0,
    main_shown: bool = false,
    style_words: std.StringHashMapUnmanaged(void) = .empty,
    tokens: std.ArrayList(Token) = .empty,
    types: std.StringHashMapUnmanaged(void) = .empty,
    dark: bool = false,
    seq: u64 = 0,
    subs: std.ArrayList(*Sub) = .empty,
    keys: std.ArrayList(KeyBinding) = .empty,
    keys_text: []u8 = &.{},
    menus: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// Data that lives as long as the tree (config tables).
    arena: std.heap.ArenaAllocator,
    /// Per-pump scratch: event lines being built, ctl words.
    ch: Changes = .{},
    /// Freed at the start of each pump: whatever UitChanges points into.
    pump_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, style_words: []const u8, theme_tokens: []const u8, types: []const u8, dark: bool) !*Tree {
        const t = try gpa.create(Tree);
        t.* = .{ .gpa = gpa, .arena = .init(gpa), .pump_arena = .init(gpa), .dark = dark };
        const a = t.arena.allocator();
        try t.nodes.append(gpa, null);
        var it = std.mem.tokenizeAny(u8, style_words, "\r\n");
        while (it.next()) |line| {
            var w = std.mem.tokenizeAny(u8, line, " \t");
            const name = w.next() orelse continue;
            if (name[0] == '#') continue;
            try t.style_words.put(a, try a.dupe(u8, name), {});
        }
        var tk = std.mem.tokenizeAny(u8, theme_tokens, "\r\n");
        while (tk.next()) |line| {
            var w = std.mem.tokenizeAny(u8, line, " \t");
            const name = w.next() orelse continue;
            if (name[0] == '#') continue;
            const light = parseColor(w.next() orelse continue) orelse continue;
            const dark_c = if (w.next()) |d| parseColor(d) orelse light else light;
            try t.tokens.append(a, .{ .name = try a.dupe(u8, name), .light = light, .dark = dark_c });
        }
        var ty = std.mem.tokenizeAny(u8, types, "\r\n");
        while (ty.next()) |line| {
            var w = std.mem.tokenizeAny(u8, line, " \t");
            const kw = w.next() orelse continue;
            if (!std.mem.eql(u8, kw, "type")) continue;
            const name = w.next() orelse continue;
            try t.types.put(a, try a.dupe(u8, name), {});
        }
        t.main_root = try t.makeNode(0, ".", "div", ".");
        return t;
    }

    pub fn deinit(t: *Tree) void {
        for (t.nodes.items) |maybe| if (maybe) |n| t.freeNode(n);
        t.nodes.deinit(t.gpa);
        for (t.subs.items) |s| t.unref(s);
        t.subs.deinit(t.gpa);
        t.freeKeys();
        t.keys.deinit(t.gpa);
        var mi = t.menus.iterator();
        while (mi.next()) |e| {
            t.gpa.free(e.key_ptr.*);
            t.gpa.free(e.value_ptr.*);
        }
        t.menus.deinit(t.gpa);
        t.ch.created.deinit(t.gpa);
        t.ch.removed.deinit(t.gpa);
        t.ch.props.deinit(t.gpa);
        t.ch.cmds.deinit(t.gpa);
        t.pump_arena.deinit();
        t.arena.deinit();
        const gpa = t.gpa;
        gpa.destroy(t);
    }

    fn freeNode(t: *Tree, n: *Node) void {
        const gpa = t.gpa;
        gpa.free(n.name);
        gpa.free(n.typ);
        gpa.free(n.path);
        n.kids.deinit(gpa);
        var it = n.props.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        n.props.deinit(gpa);
        n.style_arena.deinit();
        gpa.destroy(n);
    }

    fn makeNode(t: *Tree, parent: u32, name: []const u8, typ: []const u8, path: []const u8) !u32 {
        const gpa = t.gpa;
        const n = try gpa.create(Node);
        const id: u32 = @intCast(t.nodes.items.len);
        n.* = .{
            .id = id,
            .parent = parent,
            .name = try gpa.dupe(u8, name),
            .typ = try gpa.dupe(u8, typ),
            .path = try gpa.dupe(u8, path),
            .style_arena = .init(gpa),
        };
        try t.nodes.append(gpa, n);
        return id;
    }

    pub fn get(t: *const Tree, id: u32) ?*Node {
        if (id == 0 or id >= t.nodes.items.len) return null;
        const n = t.nodes.items[id] orelse return null;
        return if (n.alive) n else null;
    }

    /// Resolves a window-relative path to a node.
    pub fn lookup(t: *const Tree, path: []const u8) ?u32 {
        var at = t.main_root;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |el| {
            if (std.mem.eql(u8, el, ".")) continue;
            at = t.child(at, el) orelse return null;
        }
        return at;
    }

    pub fn child(t: *const Tree, id: u32, name: []const u8) ?u32 {
        const n = t.get(id) orelse return null;
        for (n.kids.items) |k| {
            const c = t.get(k) orelse continue;
            if (std.mem.eql(u8, c.name, name)) return k;
        }
        return null;
    }

    pub fn beginPump(t: *Tree) void {
        _ = t.pump_arena.reset(.retain_capacity);
        t.ch.created.clearRetainingCapacity();
        t.ch.removed.clearRetainingCapacity();
        t.ch.props.clearRetainingCapacity();
        t.ch.cmds.clearRetainingCapacity();
        t.ch.dirty_main = false;
    }

    fn pstr(t: *Tree, s: []const u8) !abi.UitStr {
        return abi.UitStr.of(try t.pump_arena.allocator().dupe(u8, s));
    }

    fn propChanged(t: *Tree, id: u32, file: []const u8) !void {
        try t.ch.props.append(t.gpa, .{ .node = id, .file = try t.pstr(file) });
        t.ch.dirty_main = true;
    }

    pub fn cmd(t: *Tree, c: abi.UitHostCmd) !void {
        try t.ch.cmds.append(t.gpa, c);
    }

    // -----------------------------------------------------------------
    // ctl

    /// Applies one write to a ctl file. `base` is the ctl's node (0: the
    /// app ctl). All lines apply or none: the spike checks every line
    /// against a scratch copy of names first, then applies.
    pub fn ctl(t: *Tree, base: u32, text: []const u8, why: *[]const u8, why_buf: []u8) Error!void {
        var arena_state: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var lines: std.ArrayList([]const tokenize.Tok) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const toks = tokenize.tokenize(arena, line) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    why.* = "unterminated quote";
                    return error.BadSyntax;
                },
            };
            if (toks.len == 0) continue;
            try lines.append(arena, toks);
        }
        // Check pass: paths, verbs, style words. `new` lines may create
        // parents later lines use, so names made in this write count.
        var made: std.StringHashMapUnmanaged(void) = .empty;
        for (lines.items) |toks| try t.check(base, toks, arena, &made, why, why_buf);
        for (lines.items) |toks| try t.applyLine(base, toks, arena, why, why_buf);
    }

    const Parsed = struct {
        path: []const u8,
        typ: []const u8 = "",
        attrs: std.ArrayList(struct { k: []const u8, v: []const u8 }) = .empty,
        style: ?[]const u8 = null,
    };

    fn parseNodeLine(arena: Allocator, toks: []const tokenize.Tok, is_new: bool, why: *[]const u8) Error!Parsed {
        const need: usize = if (is_new) 3 else 2;
        if (toks.len < need) {
            why.* = toks[0].text;
            return error.BadSyntax;
        }
        var p: Parsed = .{ .path = toks[need - 1].text };
        if (is_new) p.typ = toks[1].text;
        var i = need;
        while (i < toks.len) : (i += 1) {
            const tk = toks[i];
            if (tk.isStyleColon()) {
                var sb: std.ArrayList(u8) = .empty;
                for (toks[i + 1 ..], 0..) |s, j| {
                    if (j > 0) try sb.append(arena, ' ');
                    try sb.appendSlice(arena, s.text);
                }
                p.style = sb.items;
                break;
            }
            if (tk.attr()) |a| {
                try p.attrs.append(arena, .{ .k = a.key, .v = a.value });
            } else {
                // A bare word: a flag or variant, `on`.
                try p.attrs.append(arena, .{ .k = tk.text, .v = "on" });
            }
        }
        return p;
    }

    /// The path a ctl line names, relative to the window. The app ctl
    /// takes `win/main/...`; a node's ctl is relative to that node.
    fn fullPath(t: *Tree, arena: Allocator, base: u32, p: []const u8, why: *[]const u8) Error![]const u8 {
        if (base == 0) {
            if (std.mem.eql(u8, p, "win/main")) return ".";
            if (std.mem.startsWith(u8, p, "win/main/")) return p["win/main/".len..];
            why.* = p;
            return error.NotFound;
        }
        const b = t.get(base) orelse return error.NotFound;
        if (std.mem.eql(u8, b.path, ".")) return p;
        if (std.mem.eql(u8, p, ".")) return b.path;
        return try std.fmt.allocPrint(arena, "{s}/{s}", .{ b.path, p });
    }

    fn check(t: *Tree, base: u32, toks: []const tokenize.Tok, arena: Allocator, made: *std.StringHashMapUnmanaged(void), why: *[]const u8, why_buf: []u8) Error!void {
        const verb = toks[0].text;
        if (std.mem.eql(u8, verb, "set") or std.mem.eql(u8, verb, "new")) {
            const is_new = verb[0] == 'n';
            const p = try parseNodeLine(arena, toks, is_new, why);
            const full = try t.fullPath(arena, base, p.path, why);
            if (is_new) {
                if (t.types.count() > 0 and !t.types.contains(p.typ)) {
                    why.* = try std.fmt.allocPrint(arena, "unknown type {s}", .{p.typ});
                    return error.BadValue;
                }
                if (t.lookup(full) != null or made.contains(full)) {
                    why.* = p.path;
                    return error.InUse;
                }
                const parent = std.fs.path.dirnamePosix(full) orelse ".";
                if (t.lookup(parent) == null and !made.contains(parent)) {
                    why.* = parent;
                    return error.NotFound;
                }
                try made.put(arena, full, {});
            } else if (t.lookup(full) == null and !made.contains(full)) {
                why.* = p.path;
                return error.NotFound;
            }
            if (p.style) |s| try t.checkStyle(s, why, why_buf);
            for (p.attrs.items) |a| if (std.mem.eql(u8, a.k, "style")) try t.checkStyle(a.v, why, why_buf);
            return;
        }
        if (std.mem.eql(u8, verb, "delete")) {
            if (toks.len < 2) return error.BadSyntax;
            const full = try t.fullPath(arena, base, toks[1].text, why);
            if (t.lookup(full) == null) {
                why.* = toks[1].text;
                return error.NotFound;
            }
            return;
        }
        // Window and app verbs the spike knows.
        const known = [_][]const u8{ "show", "activate", "quit", "ask", "begin", "commit", "abort" };
        for (known) |k| if (std.mem.eql(u8, verb, k)) return;
        why.* = try std.fmt.allocPrint(arena, "unknown verb {s}", .{verb});
        return error.BadValue;
    }

    fn applyLine(t: *Tree, base: u32, toks: []const tokenize.Tok, arena: Allocator, why: *[]const u8, why_buf: []u8) Error!void {
        const verb = toks[0].text;
        if (std.mem.eql(u8, verb, "set") or std.mem.eql(u8, verb, "new")) {
            const is_new = verb[0] == 'n';
            const p = try parseNodeLine(arena, toks, is_new, why);
            const full = try t.fullPath(arena, base, p.path, why);
            var id: u32 = undefined;
            if (is_new) {
                const parent_path = std.fs.path.dirnamePosix(full) orelse ".";
                const parent = t.lookup(parent_path) orelse return error.NotFound;
                const name = std.fs.path.basenamePosix(full);
                id = try t.makeNode(parent, name, p.typ, full);
                try t.get(parent).?.kids.append(t.gpa, id);
                try t.ch.created.append(t.gpa, id);
                try t.propChanged(parent, "order");
                if (parent == t.main_root and !t.main_shown) {
                    t.main_shown = true;
                    try t.cmd(.{ .tag = abi.UIT_CMD_WINDOW, .win = abi.UitStr.lit("main") });
                }
            } else id = t.lookup(full) orelse return error.NotFound;
            for (p.attrs.items) |a| try t.setProp(id, a.k, a.v, why, why_buf);
            if (p.style) |s| try t.setProp(id, "style", s, why, why_buf);
            return;
        }
        if (std.mem.eql(u8, verb, "delete")) {
            const full = try t.fullPath(arena, base, toks[1].text, why);
            const id = t.lookup(full) orelse return error.NotFound;
            try t.delete(id);
            return;
        }
        if (std.mem.eql(u8, verb, "quit")) {
            try t.cmd(.{ .tag = abi.UIT_CMD_QUIT });
            return;
        }
        if (std.mem.eql(u8, verb, "show") or std.mem.eql(u8, verb, "activate")) {
            if (!t.main_shown) {
                t.main_shown = true;
                try t.cmd(.{ .tag = abi.UIT_CMD_WINDOW, .win = abi.UitStr.lit("main") });
            }
            try t.cmd(.{ .tag = abi.UIT_CMD_WINDOW_CTL, .win = abi.UitStr.lit("main"), .ctl = .{ .verb = try t.pstr(verb) } });
            return;
        }
        // ask/begin/commit/abort: accepted and ignored by the spike.
    }

    fn delete(t: *Tree, id: u32) Error!void {
        const n = t.get(id) orelse return error.NotFound;
        if (id == t.main_root) return error.BadValue;
        const kids = try t.gpa.dupe(u32, n.kids.items);
        defer t.gpa.free(kids);
        for (kids) |k| try t.delete(k);
        if (t.get(n.parent)) |p| {
            for (p.kids.items, 0..) |k, i| if (k == id) {
                _ = p.kids.orderedRemove(i);
                break;
            };
            try t.propChanged(n.parent, "order");
        }
        n.alive = false;
        try t.ch.removed.append(t.gpa, id);
        // Subscriptions on the node end with `gone`.
        for (t.subs.items) |s| if (s.node == id) {
            try t.pushLine(s, try std.fmt.allocPrint(t.gpa, "gone - - seq={d}\n", .{t.nextSeq()}));
            s.closed = true;
        };
    }

    pub fn setProp(t: *Tree, id: u32, k: []const u8, v: []const u8, why: *[]const u8, why_buf: []u8) Error!void {
        const n = t.get(id) orelse return error.NotFound;
        if (std.mem.eql(u8, k, "type")) {
            why.* = "type is fixed";
            return error.BadValue;
        }
        if (std.mem.eql(u8, k, "style")) {
            try t.checkStyle(v, why, why_buf);
            n.style = &.{}; // reparsed on next uit_style
            _ = n.style_arena.reset(.retain_capacity);
            n.style = try t.parseStyle(n.style_arena.allocator(), v);
        }
        if (std.mem.eql(u8, k, "order")) {
            // Reorder: listed children first, in that order; the rest are not drawn.
            var next: std.ArrayList(u32) = .empty;
            var it = std.mem.tokenizeAny(u8, v, " \t\n");
            while (it.next()) |name| if (t.child(id, name)) |c| try next.append(t.gpa, c);
            n.kids.deinit(t.gpa);
            n.kids = next;
        }
        const gop = try n.props.getOrPut(t.gpa, k);
        if (gop.found_existing) {
            t.gpa.free(gop.value_ptr.*);
        } else gop.key_ptr.* = try t.gpa.dupe(u8, k);
        gop.value_ptr.* = try t.gpa.dupe(u8, v);
        try t.propChanged(id, k);
    }

    // -----------------------------------------------------------------
    // style

    fn stateOf(prefix: []const u8) ?u32 {
        const map = .{
            .{ "hover", abi.UIT_STATE_HOVER },
            .{ "active", abi.UIT_STATE_ACTIVE },
            .{ "focus", abi.UIT_STATE_FOCUS },
            .{ "disabled", abi.UIT_STATE_DISABLED },
            .{ "drop-over", abi.UIT_STATE_DROP_OVER },
        };
        inline for (map) |m| if (std.mem.eql(u8, prefix, m[0])) return m[1];
        return null;
    }

    fn splitWord(w: []const u8) struct { state: u32, name: []const u8, arg: ?[]const u8 } {
        var rest = w;
        var state: u32 = abi.UIT_STATE_BASE;
        if (std.mem.indexOfScalar(u8, rest, ':')) |c| {
            if (stateOf(rest[0..c])) |s| {
                state = s;
                rest = rest[c + 1 ..];
            }
        }
        if (std.mem.indexOfScalar(u8, rest, '=')) |eq| return .{ .state = state, .name = rest[0..eq], .arg = rest[eq + 1 ..] };
        return .{ .state = state, .name = rest, .arg = null };
    }

    pub fn checkStyle(t: *Tree, text: []const u8, why: *[]const u8, why_buf: []u8) Error!void {
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |w| {
            const sw = splitWord(w);
            if (t.style_words.count() > 0 and !t.style_words.contains(sw.name)) {
                why.* = std.fmt.bufPrint(why_buf, "{s}", .{sw.name}) catch sw.name;
                return error.UnknownStyleWord;
            }
            if (sw.arg) |a| if (a.len == 0) {
                why.* = std.fmt.bufPrint(why_buf, "{s}=", .{sw.name}) catch "";
                return error.BadValue;
            };
        }
    }

    pub fn token(t: *const Tree, name: []const u8) ?u32 {
        for (t.tokens.items) |tk| if (std.mem.eql(u8, tk.name, name)) return if (t.dark) tk.dark else tk.light;
        return null;
    }

    fn parseArg(t: *const Tree, a: Allocator, s: []const u8) !abi.UitStyleArg {
        if (s.len > 0 and s[0] == '#') {
            if (parseColor(s)) |c| return .{ .kind = abi.UIT_ARG_RGBA, .rgba = c };
        }
        if (t.token(s)) |c| return .{ .kind = abi.UIT_ARG_RGBA, .rgba = c, .text = abi.UitStr.of(try a.dupe(u8, s)) };
        if (std.mem.endsWith(u8, s, "%")) {
            if (std.fmt.parseFloat(f32, s[0 .. s.len - 1])) |f| return .{ .kind = abi.UIT_ARG_PERCENT, .a = f } else |_| {}
        }
        if (std.mem.endsWith(u8, s, "rem")) {
            if (std.fmt.parseFloat(f32, s[0 .. s.len - 3])) |f| return .{ .kind = abi.UIT_ARG_REM, .a = f } else |_| {}
        }
        if (std.mem.endsWith(u8, s, "px")) {
            if (std.fmt.parseFloat(f32, s[0 .. s.len - 2])) |f| return .{ .kind = abi.UIT_ARG_PX, .a = f } else |_| {}
        }
        if (std.fmt.parseFloat(f32, s)) |f| return .{ .kind = abi.UIT_ARG_PX, .a = f } else |_| {}
        return .{ .kind = abi.UIT_ARG_TEXT, .text = abi.UitStr.of(try a.dupe(u8, s)) };
    }

    pub fn parseStyle(t: *const Tree, a: Allocator, text: []const u8) ![]abi.UitStyleWord {
        var out: std.ArrayList(abi.UitStyleWord) = .empty;
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |w| {
            const sw = splitWord(w);
            var args: std.ArrayList(abi.UitStyleArg) = .empty;
            if (sw.arg) |arg| {
                var ai = std.mem.splitScalar(u8, arg, ',');
                while (ai.next()) |x| try args.append(a, try t.parseArg(a, x));
            }
            try out.append(a, .{
                .name = abi.UitStr.of(try a.dupe(u8, sw.name)),
                .state = sw.state,
                .args = if (args.items.len > 0) args.items.ptr else null,
                .n_args = args.items.len,
            });
        }
        return out.items;
    }

    /// Theme mode changed: every cached style is reparsed.
    pub fn setDark(t: *Tree, dark: bool) !void {
        if (t.dark == dark) return;
        t.dark = dark;
        for (t.nodes.items) |maybe| if (maybe) |n| if (n.alive) {
            _ = n.style_arena.reset(.retain_capacity);
            n.style = try t.parseStyle(n.style_arena.allocator(), n.prop("style") orelse "");
        };
        try t.cmd(.{ .tag = abi.UIT_CMD_THEME });
        try t.emitLine(0, "theme", "-", "-", &.{.{ "mode", if (dark) "dark" else "light" }}, "system");
        t.ch.dirty_main = true;
    }

    // -----------------------------------------------------------------
    // keys and menus

    fn freeKeys(t: *Tree) void {
        for (t.keys.items) |k| {
            t.gpa.free(k.key);
            t.gpa.free(k.action);
            t.gpa.free(k.context);
        }
        t.keys.clearRetainingCapacity();
        t.gpa.free(t.keys_text);
        t.keys_text = &.{};
    }

    pub fn setKeys(t: *Tree, text: []const u8) Error!void {
        t.freeKeys();
        t.keys_text = try t.gpa.dupe(u8, text);
        var it = std.mem.tokenizeAny(u8, text, "\r\n");
        while (it.next()) |line| {
            var w = std.mem.tokenizeAny(u8, line, " \t");
            const ks = w.next() orelse continue;
            const action = w.next() orelse continue;
            var ctx: []const u8 = "";
            var global = false;
            while (w.next()) |x| {
                if (std.mem.eql(u8, x, "global")) global = true else if (std.mem.startsWith(u8, x, "context=")) ctx = x[8..];
            }
            try t.keys.append(t.gpa, .{ .key = try t.gpa.dupe(u8, ks), .action = try t.gpa.dupe(u8, action), .context = try t.gpa.dupe(u8, ctx), .global = global });
        }
        try t.cmd(.{ .tag = abi.UIT_CMD_KEYMAP });
    }

    pub fn setMenu(t: *Tree, name: []const u8, text: []const u8) Error!void {
        const gop = try t.menus.getOrPut(t.gpa, name);
        if (gop.found_existing) t.gpa.free(gop.value_ptr.*) else gop.key_ptr.* = try t.gpa.dupe(u8, name);
        gop.value_ptr.* = try t.gpa.dupe(u8, text);
        try t.cmd(.{ .tag = abi.UIT_CMD_MENUS });
    }

    /// A keystroke from the renderer: an `action` event if it is bound.
    pub fn key(t: *Tree, keystroke: []const u8, focused: u32) Error!bool {
        for (t.keys.items) |k| {
            if (!std.mem.eql(u8, k.key, keystroke)) continue;
            const path = if (t.get(focused)) |n| n.path else ".";
            try t.emitLine(t.main_root, "action", k.action, path, &.{}, "key");
            return true;
        }
        return false;
    }

    // -----------------------------------------------------------------
    // events

    pub fn nextSeq(t: *Tree) u64 {
        t.seq += 1;
        return t.seq;
    }

    pub fn tagOf(t: *const Tree, id: u32) []const u8 {
        var at = id;
        while (t.get(at)) |n| {
            if (n.prop("tag")) |tag| if (tag.len > 0) return tag;
            at = n.parent;
        }
        return "-";
    }

    fn isUnder(t: *const Tree, id: u32, anc: u32) bool {
        var at = id;
        while (at != 0) {
            if (at == anc) return true;
            const n = t.get(at) orelse return false;
            at = n.parent;
        }
        return false;
    }

    pub fn pushLine(t: *Tree, s: *Sub, line: []u8) !void {
        _ = t;
        if (s.closed) return;
        try s.lines.append(std.heap.c_allocator, line);
    }

    /// Formats `name key path win=main attrs... [via=V] seq=N` and sends it
    /// to every subscription that sees `node` (0: app-level).
    pub fn emitLine(t: *Tree, node: u32, name: []const u8, key_: []const u8, path: []const u8, attrs: []const [2][]const u8, via: ?[]const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(t.gpa);
        try buf.print(t.gpa, "{s} {s} {s}", .{ name, key_, path });
        if (node != 0) try buf.appendSlice(t.gpa, " win=main");
        for (attrs) |a| try buf.print(t.gpa, " {s}={s}", .{ a[0], a[1] });
        if (via) |v| try buf.print(t.gpa, " via={s}", .{v});
        try buf.print(t.gpa, " seq={d}\n", .{t.nextSeq()});
        for (t.subs.items) |s| {
            if (s.node != 0 and (node == 0 or !t.isUnder(node, s.node))) continue;
            try t.pushLine(s, try std.heap.c_allocator.dupe(u8, buf.items));
        }
    }

    /// An event from the renderer about `id`.
    pub fn emit(t: *Tree, id: u32, name: []const u8, attrs: []const [2][]const u8) !void {
        const n = t.get(id) orelse return error.NotFound;
        try t.emitLine(id, name, t.tagOf(id), n.path, attrs, null);
    }

    /// A new subscription; its first line is `resync`.
    pub fn subscribe(t: *Tree, node: u32) !*Sub {
        const s = try std.heap.c_allocator.create(Sub);
        s.* = .{ .node = node };
        try s.lines.append(std.heap.c_allocator, try std.fmt.allocPrint(std.heap.c_allocator, "resync - - seq={d}\n", .{t.seq}));
        s.refs = 2; // the tree's and the reader's
        try t.subs.append(t.gpa, s);
        return s;
    }

    pub fn unsubscribe(t: *Tree, s: *Sub) void {
        for (t.subs.items, 0..) |x, i| if (x == s) {
            _ = t.subs.swapRemove(i);
            t.unref(s);
            break;
        };
    }

    pub fn closeAll(t: *Tree) void {
        for (t.subs.items) |s| s.closed = true;
    }

    pub fn unref(_: *Tree, s: *Sub) void {
        s.refs -= 1;
        if (s.refs > 0) return;
        const a = std.heap.c_allocator;
        for (s.lines.items) |l| a.free(l);
        s.lines.deinit(a);
        a.free(s.partial);
        a.destroy(s);
    }
};

/// `#rrggbb` or `#rrggbbaa` to 0xRRGGBBAA.
pub fn parseColor(s: []const u8) ?u32 {
    if (s.len < 1 or s[0] != '#') return null;
    const h = s[1..];
    if (h.len == 6) {
        const v = std.fmt.parseInt(u32, h, 16) catch return null;
        return (v << 8) | 0xff;
    }
    if (h.len == 8) return std.fmt.parseInt(u32, h, 16) catch null;
    return null;
}

const testing = std.testing;

test "the counter's ctl builds the tree and validates style words" {
    const t = try Tree.init(testing.allocator, "size\nflex\nh-flex\nbg\ntext-3xl\n", "background #ffffff #000000\naccent #f0f0f0 #303030\n", "", false);
    defer t.deinit();
    t.beginPump();
    var why: []const u8 = "";
    var wb: [256]u8 = undefined;
    try t.ctl(t.main_root, "set . title=Counter size=300,180 : h-flex bg=background\nnew div inc tag=inc on=click : size=40 flex hover:bg=accent\nnew text inc/t text=+", &why, &wb);
    const inc = t.lookup("inc").?;
    try testing.expectEqualStrings("inc", t.get(inc).?.prop("tag").?);
    try testing.expectEqualStrings("+", t.get(t.lookup("inc/t").?).?.prop("text").?);
    const st = t.get(inc).?.style;
    try testing.expectEqual(@as(usize, 3), st.len);
    try testing.expectEqual(abi.UIT_ARG_PX, st[0].args.?[0].kind);
    try testing.expectEqual(abi.UIT_STATE_HOVER, st[2].state);
    try testing.expectEqual(@as(u32, 0xf0f0f0ff), st[2].args.?[0].rgba);
    // The main window shows with its first child.
    try testing.expectEqual(abi.UIT_CMD_WINDOW, t.ch.cmds.items[0].tag);
    // All or nothing: the bad word fails the whole write.
    try testing.expectError(error.UnknownStyleWord, t.ctl(t.main_root, "new text n text=0\nset n : text-9xl", &why, &wb));
    try testing.expect(t.lookup("n") == null);
    try testing.expectError(error.InUse, t.ctl(t.main_root, "new div inc", &why, &wb));
    try testing.expectError(error.NotFound, t.ctl(t.main_root, "set nope text=1", &why, &wb));
}

test "events route by tag and reach subscriptions" {
    const t = try Tree.init(testing.allocator, "", "", "", false);
    defer t.deinit();
    t.beginPump();
    var why: []const u8 = "";
    var wb: [256]u8 = undefined;
    try t.ctl(0, "new div win/main/inc tag=inc on=click\nnew text win/main/inc/t text=+", &why, &wb);
    const s = try t.subscribe(0);
    defer {
        t.unsubscribe(s);
        t.unref(s);
    }
    try t.emit(t.lookup("inc/t").?, "click", &.{});
    try t.setKeys("=      inc\n");
    try testing.expect(try t.key("=", 0));
    try testing.expectEqualStrings("resync - - seq=0\n", s.lines.items[0]);
    try testing.expectEqualStrings("click inc inc/t win=main seq=1\n", s.lines.items[1]);
    try testing.expectEqualStrings("action inc . win=main via=key seq=2\n", s.lines.items[2]);
}
