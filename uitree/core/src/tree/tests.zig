//! The tree's tests: uitreefs/crates/tree/src/tests.rs ported to spec 0.2
//! (client paths from `$ui`, dashed names, the 0.2 phrases and event
//! heads) and run against the real catalog (core/types) instead of a
//! stand-in, plus the conformance goldens' tree-level behavior.
//!
//! Where 0.2 changed a behavior the uitreefs test pinned, the test pins
//! 0.2's and says so.

const std = @import("std");
const tree = @import("root.zig");
const types = @import("../types/root.zig");
const proto = @import("../proto/root.zig");

const tt = std.testing;
const Tree = tree.Tree;
const Code = proto.Code;
const Handle = tree.Handle;

const R = "win/main";

/// A tree over the built-in catalog, with window `main` claimed, as the
/// uitreefs tests' `app()`: `window main title=Test size=400,300` and
/// `ask close quit`.
const Fx = struct {
    cat: types.Catalog,
    t: *Tree,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fx) !void {
        f.cat = try types.Catalog.builtin(tt.allocator);
        errdefer f.cat.deinit();
        f.t = try Tree.create(tt.allocator, tt.io, &f.cat, .{});
        f.arena = .init(tt.allocator);
    }

    fn app(f: *Fx) !void {
        try f.init();
        try f.ok("ctl", "window main title=Test size=400,300");
        try f.ok("ctl", "ask close quit");
    }

    fn deinit(f: *Fx) void {
        f.t.destroy();
        f.cat.deinit();
        f.arena.deinit();
    }

    fn a(f: *Fx) std.mem.Allocator {
        return f.arena.allocator();
    }

    fn write(f: *Fx, p: []const u8, data: []const u8) !void {
        return f.t.apply(.{ .write = .{ .session = 1, .path = p, .data = data } });
    }

    fn ok(f: *Fx, p: []const u8, data: []const u8) !void {
        f.write(p, data) catch |e| {
            std.debug.print("write {s} {s}: {s}\n", .{ p, data, f.t.lastError() });
            return e;
        };
    }

    /// The error code a write fails with.
    fn code(f: *Fx, p: []const u8, data: []const u8) !Code {
        f.write(p, data) catch |e| return Code.fromError(e) orelse e;
        std.debug.print("write {s} {s}: expected an error\n", .{ p, data });
        return error.TestExpectedError;
    }

    fn mkdir(f: *Fx, p: []const u8) !void {
        return f.t.apply(.{ .mkdir = .{ .session = 1, .path = p } });
    }

    fn remove(f: *Fx, p: []const u8) !void {
        return f.t.apply(.{ .remove = .{ .session = 1, .path = p } });
    }

    /// A file as a reader sees it now.
    fn read(f: *Fx, p: []const u8) ![]const u8 {
        try f.t.publish();
        const s = f.t.acquire();
        defer s.release();
        return s.read(f.a(), p) catch |e| {
            std.debug.print("read {s}: {s}\n", .{ p, @errorName(e) });
            return e;
        };
    }

    fn exists(f: *Fx, p: []const u8) !bool {
        try f.t.publish();
        const s = f.t.acquire();
        defer s.release();
        _ = s.resolve(f.a(), p, null) catch return false;
        return true;
    }

    fn expectRead(f: *Fx, p: []const u8, want: []const u8) !void {
        try tt.expectEqualStrings(want, try f.read(p));
    }

    fn node(f: *Fx, p: []const u8) ?Handle {
        const loc = tree.path.resolve(f.t.current(), &f.cat, f.a(), p, null) catch return null;
        return switch (loc) {
            .node => |h| h,
            else => null,
        };
    }

    /// Everything a stream has queued, as text.
    fn drain(f: *Fx, s: *tree.Stream) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var buf: [4096]u8 = undefined;
        while (s.tryRead(&buf)) |n| {
            if (n == 0) {
                try out.appendSlice(f.a(), "<eof>");
                break;
            }
            try out.appendSlice(f.a(), buf[0..n]);
        }
        return out.items;
    }

    /// Subscribes and eats the resync line.
    fn sub(f: *Fx, target: tree.Target) !*tree.Stream {
        const s = try f.t.bus.subscribe(target);
        const first = try f.drain(s);
        if (target != .trace) try tt.expect(std.mem.startsWith(u8, first, "resync - - seq="));
        return s;
    }

    fn subPath(f: *Fx, p: []const u8) !*tree.Stream {
        if (std.mem.eql(u8, p, "events")) return f.sub(.app);
        return f.sub(.{ .node = f.node(p).? });
    }

    /// What a trace reader opened now gets first.
    fn traceText(f: *Fx) ![]const u8 {
        const s = try f.t.bus.subscribe(.trace);
        defer s.close();
        return f.drain(s);
    }
};

/// Event lines without `seq=`, attributes sorted, as the conformance
/// suite's evnorm prints them.
fn norm(a: std.mem.Allocator, lines: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        var words: std.ArrayList([]const u8) = .empty;
        var ts = try proto.tokenize.tokenize(a, l);
        _ = &ts;
        // Re-split on blanks outside quotes, keeping quotes.
        var i: usize = 0;
        var start: usize = 0;
        var q = false;
        while (i <= l.len) : (i += 1) {
            const c: u8 = if (i < l.len) l[i] else ' ';
            if (c == '\'') q = !q;
            if (c == ' ' and !q) {
                if (i > start) try words.append(a, l[start..i]);
                start = i + 1;
            }
        }
        var kept: std.ArrayList([]const u8) = .empty;
        for (words.items, 0..) |w, k| {
            if (k > 2 and std.mem.startsWith(u8, w, "seq=")) continue;
            try kept.append(a, w);
        }
        if (kept.items.len > 3) std.mem.sort([]const u8, kept.items[3..], {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        for (kept.items, 0..) |w, k| {
            if (k > 0) try out.append(a, ' ');
            try out.appendSlice(a, w);
        }
        try out.append(a, '\n');
    }
    return out.items;
}

fn names(a: std.mem.Allocator, lines: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, l[0 .. std.mem.indexOfScalar(u8, l, ' ') orelse l.len]);
    }
    return out.items;
}

// ---------------------------------------------------------------- errors

test "error table: one row per phrase" {
    const Case = struct { what: []const u8, setup: []const [2][]const u8 = &.{}, p: []const u8, cmd: []const u8, want: Code };
    const big = "new div x tag=" ++ "a" ** (70 << 10);
    const cases = [_]Case{
        .{ .what = "unknown command", .p = R ++ "/ctl", .cmd = "frob", .want = .unknown_command },
        .{ .what = "unknown app command", .p = "ctl", .cmd = "frob", .want = .unknown_command },
        .{ .what = "unknown node command", .setup = &.{.{ R ++ "/ctl", "new div x" }}, .p = R ++ "/x/ctl", .cmd = "frob", .want = .unknown_command },
        .{ .what = "bad quoting", .p = R ++ "/ctl", .cmd = "new div 'x", .want = .bad_syntax },
        .{ .what = "new without name", .p = R ++ "/ctl", .cmd = "new div", .want = .bad_syntax },
        .{ .what = "unknown style word", .p = R ++ "/ctl", .cmd = "new div x : flexx", .want = .unknown_style_word },
        // 0.2: variant and size words are bare words, never style words.
        .{ .what = "variant in a style", .p = R ++ "/ctl", .cmd = "new button x : primary", .want = .unknown_style_word },
        .{ .what = "size word on a div", .p = R ++ "/ctl", .cmd = "new div x : sm", .want = .unknown_style_word },
        .{ .what = "variant word a div lacks", .p = R ++ "/ctl", .cmd = "new div x primary", .want = .bad_value },
        .{ .what = "unknown type", .p = R ++ "/ctl", .cmd = "new widget x", .want = .unknown_type },
        .{ .what = "in use", .setup = &.{.{ R ++ "/ctl", "new div x" }}, .p = R ++ "/ctl", .cmd = "new div x", .want = .in_use },
        .{ .what = "window in use", .p = "ctl", .cmd = "window main", .want = .in_use },
        .{ .what = "not found: delete", .p = R ++ "/ctl", .cmd = "delete nope", .want = .not_found },
        .{ .what = "not found: answer", .p = R ++ "/ctl", .cmd = "close seq=99", .want = .not_found },
        .{ .what = "bad value: length", .p = R ++ "/ctl", .cmd = "new div x : w=wide", .want = .bad_value },
        .{ .what = "bad value: number", .p = R ++ "/ctl", .cmd = "new slider s value=abc", .want = .bad_value },
        .{ .what = "bad value: choice", .p = R ++ "/ctl", .cmd = "new checkbox c value=maybe", .want = .bad_value },
        .{ .what = "bad value: on word", .p = R ++ "/ctl", .cmd = "new div x on=wiggle", .want = .bad_value },
        .{ .what = "bad value: window size", .p = "ctl", .cmd = "window w2 size=big", .want = .bad_value },
        .{ .what = "not found: window prop", .p = "ctl", .cmd = "window w2 colour=red", .want = .not_found },
        .{ .what = "not found: prop", .p = R ++ "/ctl", .cmd = "new button b colour=red", .want = .not_found },
        // 0.2: batches are on the app ctl only.
        .{ .what = "unknown command: begin on a window", .p = R ++ "/ctl", .cmd = "begin", .want = .unknown_command },
        .{ .what = "no batch: commit", .p = "ctl", .cmd = "commit", .want = .no_batch },
        .{ .what = "no batch: abort", .p = "ctl", .cmd = "abort", .want = .no_batch },
        .{ .what = "in use: begin twice", .setup = &.{.{ "ctl", "begin" }}, .p = "ctl", .cmd = "begin", .want = .in_use },
        .{ .what = "too large: one ctl write over 64 KiB", .p = R ++ "/ctl", .cmd = big, .want = .too_large },
        .{ .what = "disabled", .setup = &.{.{ R ++ "/ctl", "new button b label=B disabled" }}, .p = R ++ "/b/ctl", .cmd = "click", .want = .disabled },
    };
    for (cases) |c| {
        var f: Fx = undefined;
        try f.app();
        defer f.deinit();
        for (c.setup) |s| try f.ok(s[0], s[1]);
        const got = try f.code(c.p, c.cmd);
        if (got != c.want) {
            std.debug.print("{s}: got {s}, want {s} ({s})\n", .{ c.what, got.phrase(), c.want.phrase(), f.t.lastError() });
            return error.TestUnexpectedResult;
        }
    }
}

test "type is fixed after a frame; paths that don't exist; app gone" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.mkdir(R ++ "/b");
    try f.ok(R ++ "/b/type", "button");
    try f.t.frameDrawn("main");
    try tt.expectEqual(Code.type_is_fixed, try f.code(R ++ "/b/type", "text"));
    try f.ok(R ++ "/b/type", "button\n"); // the same type: fine
    try tt.expectEqual(Code.not_found, try f.code("win/nope/ctl", "show"));
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/zzz/style", "flex"));
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/b/nofile", "x"));

    const s = try f.t.bus.subscribe(.app);
    defer s.close();
    var small: [4]u8 = undefined;
    try tt.expectEqualStrings("resy", small[0..s.tryRead(&small).?]);
    f.t.appGone();
    _ = try f.drain(s);
    try tt.expectEqual(Code.app_gone, try f.code(R ++ "/ctl", "new div y"));
    try tt.expectError(error.AppGone, f.t.bus.subscribe(.app));
}

test "an error's text is phrase and detail" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    _ = try f.code(R ++ "/ctl", "new div x : flexx");
    try tt.expectEqualStrings("unknown style word: flexx", f.t.lastError());
}

test "a ctl write is all or nothing" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try tt.expectEqual(Code.unknown_type, try f.code(R ++ "/ctl", "new div a\nnew div b\nnew widget c"));
    try tt.expect(f.node(R ++ "/a") == null);
    try f.expectRead(R ++ "/order", "");
    // A failing prop inside `new` leaves nothing either.
    try tt.expectEqual(Code.unknown_style_word, try f.code(R ++ "/ctl", "new button b label=Hi : flexx"));
    try tt.expect(f.node(R ++ "/b") == null);
    try tt.expectEqualStrings(
        \\ctl path=ctl cmd='window main title=Test size=400,300'
        \\ctl path=ctl cmd='ask close quit'
        \\error path=win/main/ctl err='unknown type: widget'
        \\error path=win/main/ctl err='unknown style word: flexx'
        \\
    , try f.traceText());
}

test "limits: depth 64, text 1 MiB per ctl attr, data files" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    var p: std.ArrayList(u8) = .empty;
    try p.appendSlice(f.a(), R);
    var i: usize = 1;
    while (i < 64) : (i += 1) {
        const ctl = try std.fmt.allocPrint(f.a(), "{s}/ctl", .{p.items});
        try f.ok(ctl, try std.fmt.allocPrint(f.a(), "new div d{d}", .{i}));
        try p.appendSlice(f.a(), try std.fmt.allocPrint(f.a(), "/d{d}", .{i}));
    }
    const ctl = try std.fmt.allocPrint(f.a(), "{s}/ctl", .{p.items});
    try tt.expectEqual(Code.too_large, try f.code(ctl, "new div deep"));
    try f.ok(R ++ "/ctl", "new text big");
    const huge = try f.a().alloc(u8, (16 << 20) + 1);
    @memset(huge, 'x');
    try tt.expectEqual(Code.too_large, try f.code(R ++ "/big/text", huge));
}

// ---------------------------------------------------------------- nodes

test "creating nodes three ways" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    f.t.clearChanges();
    try f.mkdir(R ++ "/save");
    const ch = try f.t.changes();
    try tt.expectEqual(@as(usize, 1), ch.created.len);
    try tt.expectEqual(f.node(R ++ "/save").?, ch.created[0]);
    try tt.expectEqual(@as(usize, 1), ch.dirty.len);
    try tt.expectEqualStrings("main", ch.dirty[0]);
    try f.expectRead(R ++ "/save/type", "div\n");
    try f.ok(R ++ "/save/type", "button\n");
    try f.ok(R ++ "/save/label", "Save\n");
    try f.ok(R ++ "/ctl", "new text title text='Hello there' : text-xl font-semibold");
    try f.ok(R ++ "/tree",
        \\div root
        \\  button save  label=Save
        \\  text title  text='Hello there'  : text-xl font-semibold
        \\
    );
    try f.expectRead(R ++ "/order", "save title\n");
    try f.expectRead(R ++ "/save/label", "Save\n");
    try f.expectRead(R ++ "/title/text", "Hello there\n");
    try f.expectRead(R ++ "/title/style", "text-xl font-semibold\n");
}

test "one-line files drop one newline and read back with one; bytes keep theirs" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new text t\nnew editor e");
    try f.ok(R ++ "/t/text", "Hello\n");
    try f.expectRead(R ++ "/t/text", "Hello\n");
    try f.ok(R ++ "/t/text", "two\n\n");
    try f.expectRead(R ++ "/t/text", "two\n\n");
    try f.ok(R ++ "/t/text", "");
    try f.expectRead(R ++ "/t/text", "");
    try f.ok(R ++ "/e/value", "fn main() {}\n");
    try f.expectRead(R ++ "/e/value", "fn main() {}\n");
}

fn cmdsOf(f: *Fx, tag: tree.CmdTag) !usize {
    const ch = try f.t.changes();
    var n: usize = 0;
    for (ch.cmds) |c| if (c.tag == tag) {
        n += 1;
    };
    return n;
}

fn listNames(f: *Fx, p: []const u8) ![]const u8 {
    try f.t.publish();
    const s = f.t.acquire();
    defer s.release();
    var out: std.ArrayList(u8) = .empty;
    for (try s.list(f.a(), p)) |st| {
        if (out.items.len > 0) try out.append(f.a(), ' ');
        try out.appendSlice(f.a(), st.name);
    }
    return out.items;
}

test "node files and computed reads" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    // 0.2: variant and size words are bare words.
    try f.ok(R ++ "/ctl", "new button ok label=OK tag=save primary sm : rounded-md");
    const b = R ++ "/ok";
    try f.expectRead(b ++ "/tag", "save\n");
    try f.expectRead(b ++ "/style", "rounded-md\n");
    try f.expectRead(b ++ "/bounds", "0 0 0 0\n");
    try f.t.setBounds(f.node(b).?, .{ 10, 20, 80, 32 });
    try f.expectRead(b ++ "/bounds", "10 20 80 32\n");
    try f.expectRead(b ++ "/disabled", "off\n");
    try f.expectRead(b ++ "/selected", "");
    try tt.expect(std.mem.startsWith(u8, try f.read("version"), "uitree 1.0\n"));
    try tt.expect(std.mem.indexOf(u8, try f.read(b ++ "/ctl"), "new TYPE PATH") != null);
    try tt.expect(std.mem.indexOf(u8, try f.read(b ++ "/ctl"), "click activate") != null);
    try tt.expect(std.mem.indexOf(u8, try f.read(R ++ "/ctl"), "notify text") != null);
    try f.expectRead(R ++ "/title", "Test\n");
    try f.expectRead(R ++ "/state", "normal\n");
    try f.expectRead(R ++ "/type", "div\n");

    try f.t.publish();
    const snap = f.t.acquire();
    defer snap.release();
    const ls = try listNames(&f, b);
    inline for (.{ "type", "style", "order", "tag", "ctl", "events", "bounds", "tree", "on", "label", "icon", "disabled" }) |name| {
        if (std.mem.indexOf(u8, ls, name) == null) {
            std.debug.print("{s} not in {s}\n", .{ name, ls });
            return error.TestUnexpectedResult;
        }
    }
    try tt.expectEqual(tree.Kind.ctl, (try snap.stat(f.a(), b ++ "/ctl")).kind);
    try tt.expectEqual(tree.Kind.events, (try snap.stat(f.a(), b ++ "/events")).kind);
    try tt.expectEqual(tree.Kind.readonly, (try snap.stat(f.a(), b ++ "/bounds")).kind);
    try tt.expectEqual(tree.Kind.dir, (try snap.stat(f.a(), b)).kind);
    try tt.expectEqualStrings("version ctl events trace keys clip menu theme asset types style win", try listNames(&f, ""));
    try tt.expectEqualStrings("type order ctl events tree bounds style tag on context drop drag-types title bounds inner state focus over ok", try listNames(&f, R));
    try tt.expectEqualStrings("main", try listNames(&f, "win"));
    // 0.2: over/ lists only its overlays.
    try tt.expectEqualStrings("", try listNames(&f, R ++ "/over"));
    // Read-only files.
    try tt.expectEqual(Code.bad_value, try f.code(b ++ "/bounds", "x"));
    try tt.expectEqual(Code.bad_value, try f.code("version", "x"));
    // Versions move when a file changes.
    const v1 = (try snap.stat(f.a(), b ++ "/label")).ver;
    try f.ok(b ++ "/label", "Okay");
    try f.t.publish();
    const snap2 = f.t.acquire();
    defer snap2.release();
    try tt.expect(v1 != (try snap2.stat(f.a(), b ++ "/label")).ver);
    // A snapshot taken earlier still shows the old value.
    try tt.expectEqualStrings("OK\n", try snap.read(f.a(), b ++ "/label"));
    try tt.expectEqualStrings("Okay\n", try snap2.read(f.a(), b ++ "/label"));
}

test "slots and overlays" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    // text takes no children
    try f.ok(R ++ "/ctl", "new text t");
    try tt.expectEqual(Code.unknown_type, try f.code(R ++ "/t/ctl", "new div x"));
    // input has only named slots
    try f.ok(R ++ "/ctl", "new input in");
    try f.ok(R ++ "/in/ctl", "new div prefix");
    try tt.expectEqual(Code.bad_value, try f.code(R ++ "/in/ctl", "new div other"));
    // form children are fields
    try f.ok(R ++ "/ctl", "new form fm");
    try f.ok(R ++ "/fm/ctl", "new field name label=Name");
    try tt.expectEqual(Code.unknown_type, try f.code(R ++ "/fm/ctl", "new button b"));
    // a child can't hide a node file, nor be called over
    try tt.expectEqual(Code.bad_value, try f.code(R ++ "/ctl", "new div style"));
    try tt.expectEqual(Code.bad_value, try f.code(R ++ "/ctl", "new div over"));
    // overlays live in over/
    try tt.expectEqual(Code.unknown_type, try f.code(R ++ "/ctl", "new alert-dialog d"));
    try tt.expectEqual(Code.unknown_type, try f.code(R ++ "/over/ctl", "new div d"));
    try f.ok(R ++ "/over/ctl", "new alert-dialog confirm-del title='Delete 3 files?' confirm=Delete tag=del");
    try f.ok(R ++ "/ctl", "new alert-dialog over/two");
    f.t.clearChanges();
    try f.ok(R ++ "/over/confirm-del/ctl", "open");
    const ch = try f.t.changes();
    try tt.expectEqual(@as(usize, 1), ch.cmds.len);
    try tt.expectEqual(tree.CmdTag.overlay, ch.cmds[0].tag);
    try tt.expectEqualStrings("main", ch.cmds[0].win);
    try tt.expectEqualStrings("confirm-del", ch.cmds[0].name);
    try tt.expectEqual(@as(i32, 1), ch.cmds[0].flag);
    try tt.expectEqual(@as(usize, 1), f.t.current().win("main").?.open.items.len);
    try f.expectRead(R ++ "/over/confirm-del/open", "on\n");
    try tt.expectEqualStrings("confirm-del two", try listNames(&f, R ++ "/over"));
    try f.expectRead(R ++ "/over/confirm-del/tree",
        \\alert-dialog confirm-del  title='Delete 3 files?'  confirm=Delete  tag=del
        \\
    );
    // A bad variant value: the prop is a choice.
    try tt.expectEqual(Code.bad_value, try f.code(R ++ "/over/ctl", "new alert-dialog x variant=sideways"));
    try f.ok(R ++ "/over/confirm-del/ctl", "close");
    try tt.expectEqual(@as(usize, 0), f.t.current().win("main").?.open.items.len);
    try f.ok(R ++ "/ctl", "delete over/two");
    try tt.expect(!try f.exists(R ++ "/over/two"));
}

test "order and delete" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new div a\nnew div b\nnew div c");
    try f.expectRead(R ++ "/order", "a b c\n");
    try f.ok(R ++ "/order", "c a\n");
    const root = f.t.committed().node(f.node(R).?).?;
    try tt.expectEqual(@as(usize, 2), root.order.items.len);
    try tt.expectEqual(f.node(R ++ "/c").?, root.order.items[0]);
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/order", "a zz"));
    try f.expectRead(R ++ "/order", "c a\n");
    const a = f.node(R ++ "/a").?;
    f.t.clearChanges();
    try f.ok(R ++ "/ctl", "delete a");
    var ch = try f.t.changes();
    try tt.expectEqualSlices(Handle, &.{a}, ch.removed);
    try f.expectRead(R ++ "/order", "c\n");
    // rm -r: files first (no-ops), then the directory
    try f.ok(R ++ "/c/ctl", "new div inner");
    for ([_][]const u8{ "inner/style", "inner", "style", "type" }) |x| {
        try f.remove(try std.fmt.allocPrint(f.a(), R ++ "/c/{s}", .{x}));
    }
    try tt.expect(f.node(R ++ "/c/inner") == null);
    const c = f.node(R ++ "/c").?;
    f.t.clearChanges();
    try f.remove(R ++ "/c");
    ch = try f.t.changes();
    try tt.expectEqualSlices(Handle, &.{c}, ch.removed);
    try tt.expectError(error.NotFound, f.remove(R ++ "/c"));
    // Handles are never reused.
    try f.ok(R ++ "/ctl", "new div c");
    try tt.expect(f.node(R ++ "/c").? > c);
}

test "style words" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new div card\nnew button b");
    const c = R ++ "/card/style";
    try f.ok(c, "h-flex gap=8 p=12 rounded-lg bg=muted hover:bg=accent cursor-pointer\n");
    try f.ok(c, "w=50% px=1.5rem bg=#1e1e2e");
    try tt.expectEqual(Code.bad_value, try f.code(c, "bg=nosuchtoken"));
    try tt.expectEqual(Code.bad_value, try f.code(c, "flex-col=3"));
    try tt.expectEqual(Code.bad_value, try f.code(c, "bg=#12"));
    try tt.expectEqual(Code.unknown_style_word, try f.code(c, "flexx"));
    try tt.expectEqual(Code.unknown_style_word, try f.code(c, "sideways:bg=accent"));
    // 0.2: a variant in a style is an unknown style word.
    try tt.expectEqual(Code.unknown_style_word, try f.code(R ++ "/b/style", "ghost"));
    // The failed writes left the last good value.
    try f.expectRead(c, "w=50% px=1.5rem bg=#1e1e2e\n");
    // A token the app defined is a color.
    try f.ok("theme/tokens", "accent #445566");
    try f.ok(c, "bg=accent");
    // Empty clears.
    try f.ok(c, "");
    try f.expectRead(c, "");
    // `new` with a bad style word makes nothing.
    try tt.expectEqual(Code.unknown_style_word, try f.code(R ++ "/ctl", "new div bad : flexx"));
    try tt.expect(f.node(R ++ "/bad") == null);
}

test "data files are checked" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new select s\nnew table tb");
    try f.ok(R ++ "/s/items", "rs\tRust\ngo\tGo\n# Group\n-\nc\tC\n");
    try f.expectRead(R ++ "/s/items", "rs\tRust\ngo\tGo\n# Group\n-\nc\tC\n");
    try f.ok(R ++ "/s/value", "go");
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/s/value", "zig"));
    try f.ok(R ++ "/tb/columns", "name\tName\t280\tsort\nsize\tSize\t90\tsort\talign=right\n");
    try f.ok(R ++ "/tb/rows", "1\ta\t10\n2\tb\t20\n");
    // An append (a write past the start) adds rows.
    try f.t.apply(.{ .append = .{ .session = 1, .path = R ++ "/tb/rows", .data = "3\tc\t30\n" } });
    try f.expectRead(R ++ "/tb/rows", "1\ta\t10\n2\tb\t20\n3\tc\t30\n");
    // keys and menus
    try f.ok("keys", "cmd-s save\ncmd-shift-p  palette\nescape dismiss context=editor\n");
    try tt.expectEqual(Code.bad_value, try f.code("keys", "hyper-x boom\n"));
    f.t.clearChanges();
    try f.ok("menu/file", "item new label=New key=cmd-n\nsep\nsub recent label='Open Recent'\n");
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .menus));
    try tt.expectEqualStrings("file", f.t.current().menus.items[0].name.bytes);
    try tt.expect(std.meta.isError(f.write("menu/edit", "bogus line here")));
    try tt.expectEqual(@as(usize, 1), f.t.current().menus.items.len);
    try tt.expectEqual(Code.bad_value, try f.code("menu/edit", "item x role=fly"));
    try f.ok("menu/bar", "file\n");
    try f.expectRead("menu/bar", "file\n");
    try tt.expectEqualStrings("bar file", try listNames(&f, "menu"));
}
