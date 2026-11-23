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

    fn writeAs(f: *Fx, session: tree.Session, p: []const u8, data: []const u8) !void {
        return f.t.apply(.{ .write = .{ .session = session, .path = p, .data = data } });
    }

    /// Children of window main's root in the state the renderer draws.
    fn drawnKids(f: *Fx) usize {
        const st = f.t.committed();
        return st.node(st.win("main").?.root).?.children.items.len;
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

/// 0.2: `gone - - seq=N`, then end of file.
fn expectGone(got: []const u8) !void {
    tt.expect(std.mem.startsWith(u8, got, "gone - - seq=") and std.mem.endsWith(u8, got, "\n<eof>")) catch |e| {
        std.debug.print("got: {s}\n", .{got});
        return e;
    };
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
    // input has only named slots; another child is a type it doesn't take
    // (conformance 27-descriptors: `child none`)
    try f.ok(R ++ "/ctl", "new input in");
    try f.ok(R ++ "/in/ctl", "new div prefix");
    try tt.expectEqual(Code.unknown_type, try f.code(R ++ "/in/ctl", "new div other"));
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

// ---------------------------------------------------------------- windows

test "windows and root verbs" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.t.clearChanges();
    try f.ok("ctl", "window prefs title=Settings size=600,400 kind=dialog");
    // 0.2: a window stays hidden, and the host isn't told, until it has
    // content or a `show`.
    try tt.expectEqual(@as(usize, 0), try cmdsOf(&f, .window));
    try f.ok("win/prefs/ctl", "show");
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .window));
    const W = "win/prefs";
    try f.expectRead(W ++ "/title", "Settings\n");
    // 0.2: window props are files; the window ctl takes the window verbs.
    try f.ok(W ++ "/title", "Again\n");
    try f.expectRead(W ++ "/title", "Again\n");
    f.t.clearChanges();
    try f.ok(W ++ "/ctl", "state max");
    try f.expectRead(W ++ "/state", "max\n");
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .window_ctl));
    try tt.expectEqual(Code.bad_value, try f.code(W ++ "/ctl", "state maximized"));
    try f.ok(W ++ "/ctl", "notify 'Saved draft' type=success");
    try tt.expectEqual(Code.bad_value, try f.code(W ++ "/ctl", "notify hi type=loud"));
    // focus
    try f.ok(W ++ "/ctl", "new input name");
    try f.ok(W ++ "/focus", "name\n");
    try f.expectRead(W ++ "/focus", "name\n");
    try tt.expectEqual(Code.not_found, try f.code(W ++ "/focus", "zz"));
    // app verbs
    // 0.2: `set ID` needs an action some key or menu item names.
    try tt.expectEqual(Code.not_found, try f.code("ctl", "set save enabled=off"));
    try f.ok("keys", "cmd-s save\n");
    f.t.clearChanges();
    try f.ok("ctl", "set save enabled=off check=on\ntheme mode dark");
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .set_action));
    try f.expectRead("theme/mode", "dark\n");
    try f.ok("theme/tokens", "primary #0b5cff\nradius 6\n");
    const toks = try f.read("theme/tokens");
    try tt.expect(std.mem.indexOf(u8, toks, "primary #0b5cff\n") != null);
    try tt.expect(std.mem.indexOf(u8, toks, "background ") != null);
    // destroy removes the window; its readers get gone, then EOF
    const ws = try f.subPath(W);
    defer ws.close();
    const ns = try f.subPath(W ++ "/name");
    defer ns.close();
    try f.ok(W ++ "/ctl", "destroy");
    try tt.expect(!try f.exists(W));
    try expectGone(try f.drain(ws));
    try expectGone(try f.drain(ns));
    // mkdir win/x makes a window
    try f.mkdir("win/x");
    try f.expectRead("win/x/type", "div\n");
}

test "component verbs" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    // 0.2's editor has no verbs (`save` is its event); console's `clear`
    // is a component verb the host runs.
    try f.ok(R ++ "/ctl", "new console src");
    f.t.clearChanges();
    try f.ok(R ++ "/src/ctl", "clear");
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .component_verb));
    try tt.expectEqual(Code.unknown_command, try f.code(R ++ "/src/ctl", "explode"));
    try tt.expect(std.mem.indexOf(u8, try f.read(R ++ "/src/ctl"), "clear") != null);
}

// ---------------------------------------------------------------- events

test "event lines and tags" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new button save label=Save tag=save\nnew select lang");
    const s = try f.sub(.app);
    defer s.close();
    const seq = try f.t.emit(.{ .name = "click", .node = f.node(R ++ "/save").? });
    _ = try f.t.emit(.{ .name = "change", .node = f.node(R ++ "/lang").?, .attrs = &.{.{ .key = "value", .value = "go" }} });
    _ = try f.t.emit(.{ .name = "close", .node = f.node(R).?, .kind = .action, .attrs = &.{.{ .key = "via", .value = "titlebar" }} });
    _ = try f.t.emit(.{ .name = "quit", .kind = .action });
    const want = try std.fmt.allocPrint(f.a(),
        \\click save save win=main seq={d}
        \\change - lang win=main value=go via=user seq={d}
        \\close - . win=main via=titlebar seq={d}
        \\quit - - seq={d}
        \\
    , .{ seq, seq + 1, seq + 2, seq + 3 });
    try tt.expectEqualStrings(want, try f.drain(s));
}

test "where to read" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok("ctl", "window other");
    try f.ok(R ++ "/ctl", "new button a\nnew button b");
    const app_s = try f.sub(.app);
    defer app_s.close();
    const win_s = try f.subPath(R);
    defer win_s.close();
    const a_s = try f.subPath(R ++ "/a");
    defer a_s.close();
    _ = try f.t.emit(.{ .name = "click", .node = f.node(R ++ "/a").? });
    _ = try f.t.emit(.{ .name = "click", .node = f.node(R ++ "/b").? });
    _ = try f.t.emit(.{ .name = "click", .node = f.node("win/other").? });
    _ = try f.t.emit(.{ .name = "quit", .kind = .action });
    try tt.expectEqualStrings("click click click quit", try names(f.a(), try f.drain(app_s)));
    try tt.expectEqualStrings("click click", try names(f.a(), try f.drain(win_s)));
    try tt.expectEqualStrings("click", try names(f.a(), try f.drain(a_s)));
    // The resync line carries the last seq.
    const late = try f.t.bus.subscribe(.app);
    defer late.close();
    try tt.expectEqualStrings(try std.fmt.allocPrint(f.a(), "resync - - seq={d}\n", .{f.t.bus.lastSeq()}), try f.drain(late));
    // Node removal: gone, then EOF.
    try f.ok(R ++ "/ctl", "delete a");
    try expectGone(try f.drain(a_s));
}

test "state events coalesce and never follow their submit" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new input in\nnew input other");
    const in = f.node(R ++ "/in").?;
    const other = f.node(R ++ "/other").?;
    const s = try f.sub(.app);
    defer s.close();
    _ = try f.t.emit(.{ .name = "change", .node = in });
    _ = try f.t.emit(.{ .name = "change", .node = other });
    _ = try f.t.emit(.{ .name = "change", .node = in });
    _ = try f.t.emit(.{ .name = "submit", .node = in });
    const got = try f.drain(s);
    var it = std.mem.splitScalar(u8, got, '\n');
    try tt.expect(std.mem.startsWith(u8, it.next().?, "change - other "));
    try tt.expect(std.mem.startsWith(u8, it.next().?, "change - in "));
    try tt.expect(std.mem.startsWith(u8, it.next().?, "submit"));
    // A change after the submit stays after it.
    _ = try f.t.emit(.{ .name = "change", .node = in });
    _ = try f.t.emit(.{ .name = "submit", .node = in });
    _ = try f.t.emit(.{ .name = "change", .node = in });
    try tt.expectEqualStrings("submit change", try names(f.a(), try f.drain(s)));
    // The coalesced event keeps the position of its newest copy.
    _ = try f.t.emit(.{ .name = "change", .node = in });
    _ = try f.t.emit(.{ .name = "submit", .node = in });
    _ = try f.t.emit(.{ .name = "focus", .node = in });
    const seq = try f.t.emit(.{ .name = "change", .node = in });
    const got2 = try f.drain(s);
    try tt.expectEqualStrings("submit focus change", try names(f.a(), got2));
    try tt.expect(std.mem.endsWith(u8, got2, try std.fmt.allocPrint(f.a(), "seq={d}\n", .{seq})));
}

// ---------------------------------------------------------------- requests

fn openCount(f: *Fx) usize {
    var buf: [16]u64 = undefined;
    return f.t.openRequests(&buf);
}

test "request default applies with no reader" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    f.t.clearChanges();
    const seq = try f.t.request(.{ .name = "close", .node = f.node(R).? }, "close");
    try tt.expectEqual(@as(u64, 0), seq);
    try tt.expectEqual(@as(usize, 0), openCount(&f));
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .answer));
}

test "request answered by seq" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new tabs tabs\nnew tab tabs/t1\nnew div other");
    const s = try f.sub(.app);
    defer s.close();
    const tab = f.node(R ++ "/tabs/t1").?;
    const seq = try f.t.request(.{ .name = "close", .node = tab }, "close");
    try tt.expect(seq != 0);
    try tt.expectEqual(@as(usize, 1), openCount(&f));
    const ans = try std.fmt.allocPrint(f.a(), "keep seq={d}", .{seq});
    // On the wrong node's ctl: not found.
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/other/ctl", ans));
    f.t.clearChanges();
    try f.ok(R ++ "/tabs/t1/ctl", ans);
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .answer));
    try tt.expect(f.node(R ++ "/tabs/t1") != null);
    // A late answer: not found.
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/tabs/t1/ctl", try std.fmt.allocPrint(f.a(), "close seq={d}", .{seq})));
    // 0.2: closing a tab removes it.
    const seq2 = try f.t.request(.{ .name = "close", .node = tab }, "close");
    try f.ok(R ++ "/tabs/t1/ctl", try std.fmt.allocPrint(f.a(), "close seq={d}", .{seq2}));
    try tt.expect(f.node(R ++ "/tabs/t1") == null);
    // Window and app requests are answered on their own ctl.
    const w = try f.t.request(.{ .name = "close", .node = f.node(R).? }, "close");
    try tt.expect(w != 0);
    try f.ok(R ++ "/ctl", try std.fmt.allocPrint(f.a(), "keep seq={d}", .{w}));
    try f.ok("ctl", "ask quit");
    const q = try f.t.request(.{ .name = "quit" }, "quit");
    try tt.expect(q != 0);
    try f.ok("ctl", try std.fmt.allocPrint(f.a(), "keep seq={d}", .{q}));
    try tt.expectEqual(@as(usize, 0), openCount(&f));
}

test "request times out to default" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok("ctl", "ask quit");
    const s = try f.sub(.app);
    defer s.close();
    const seq = try f.t.request(.{ .name = "quit" }, "quit");
    try f.t.advanceClock(tree.request_timeout_ns / 2);
    try tt.expectEqual(@as(usize, 1), openCount(&f));
    f.t.clearChanges();
    try f.t.advanceClock(tree.request_timeout_ns);
    try tt.expectEqual(@as(usize, 0), openCount(&f));
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .answer));
    // The default was quit, so the app is gone (uitreefs: not found).
    try tt.expectEqual(Code.app_gone, try f.code("ctl", try std.fmt.allocPrint(f.a(), "keep seq={d}", .{seq})));
}

test "drop request and drag data" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new div notes");
    try f.ok(R ++ "/notes/drop", "files text\n");
    try f.t.dragData(7, "/drag/7/files/a.txt\n");
    try f.expectRead("drag/7/data", "/drag/7/files/a.txt\n");
    const s = try f.sub(.app);
    defer s.close();
    const seq = try f.t.request(.{ .name = "drop", .node = f.node(R ++ "/notes").?, .attrs = &.{
        .{ .key = "type", .value = "files" },
        .{ .key = "drag", .value = "7" },
        .{ .key = "pt", .value = "40,212" },
    } }, "refuse");
    try f.ok(R ++ "/notes/ctl", try std.fmt.allocPrint(f.a(), "accept seq={d}", .{seq}));
    try tt.expect(!try f.exists("drag/7/data"));
    // A client-started drag: the client writes the payload.
    try f.t.dragData(8, "");
    try f.ok("drag/8/data", "note:42");
    try tt.expectEqualStrings("note:42", f.t.current().drag(8).?.val.bytes);
    try tt.expectEqual(Code.not_found, try f.code("drag/9/data", "x"));
}

// ---------------------------------------------------------------- batches

test "batch freezes then commits" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok("ctl", "begin");
    f.t.clearChanges();
    try f.ok(R ++ "/ctl", "new text a text=Hi");
    try tt.expectEqual(@as(usize, 0), (try f.t.changes()).dirty.len);
    // Reads show the write; the renderer still sees the old tree.
    try f.expectRead(R ++ "/a/text", "Hi\n");
    try tt.expectEqual(@as(usize, 0), f.drawnKids());
    // Another session's commit doesn't end this one.
    try tt.expectEqual(Code.no_batch, blk: {
        f.writeAs(2, "ctl", "commit") catch |e| break :blk Code.fromError(e).?;
        return error.TestExpectedError;
    });
    try tt.expectEqual(Code.in_use, try f.code("ctl", "begin"));
    f.t.clearChanges();
    try f.ok("ctl", "commit");
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .redraw));
    try tt.expectEqual(@as(usize, 1), f.drawnKids());
}

test "batch commit replays props" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new input in");
    try f.ok(R ++ "/in/value", "typed");
    try f.ok("ctl", "begin");
    try f.ok(R ++ "/in/value", "");
    f.t.clearChanges();
    try f.ok("ctl", "commit");
    const in = f.node(R ++ "/in").?;
    const ch = try f.t.changes();
    const found = for (ch.props) |p| {
        if (p.node == in and std.mem.eql(u8, p.file, "value")) break true;
    } else false;
    try tt.expect(found);
    try f.expectRead(R ++ "/in/value", "");
}

test "batch abort restores" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new text keep text=Old");
    try f.ok("ctl", "begin");
    try f.ok(R ++ "/ctl", "new text gone");
    const gone = f.node(R ++ "/gone").?;
    try f.ok(R ++ "/keep/text", "New");
    f.t.clearChanges();
    try f.ok("ctl", "abort");
    try tt.expectEqualSlices(Handle, &.{gone}, (try f.t.changes()).removed);
    try f.expectRead(R ++ "/keep/text", "Old\n");
    try tt.expect(f.node(R ++ "/gone") == null);
}

test "batch times out and session close aborts" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok("ctl", "begin");
    try f.ok(R ++ "/ctl", "new text a");
    try tt.expectEqual(@as(usize, 0), f.drawnKids());
    f.t.clearChanges();
    try f.t.advanceClock(tree.batch_timeout_ns + 1);
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .redraw));
    try tt.expectEqual(@as(usize, 1), f.drawnKids());
    try tt.expect(std.mem.endsWith(u8, try f.traceText(), "batch timeout\n"));
    // A session that goes away aborts its batch.
    try f.ok("ctl", "begin");
    try f.ok(R ++ "/ctl", "new text b");
    const b = f.node(R ++ "/b").?;
    f.t.clearChanges();
    try f.t.apply(.{ .session_closed = 1 });
    try tt.expectEqualSlices(Handle, &.{b}, (try f.t.changes()).removed);
    try tt.expect(f.node(R ++ "/b") == null);
    // begin and commit in one write cancel out.
    try f.ok("ctl", "begin\ncommit");
    try tt.expect(!f.t.batchOpen());
}

// ---------------------------------------------------------------- documents

/// core.md § Documents' sign-in document (conformance 21-tree-docs).
const signin =
    \\div root  : v-flex size-full p=24 gap=16
    \\  text title  text='Sign in'  : text-xl font-semibold
    \\  form f
    \\    field user  label=Email
    \\      input in  placeholder=you@example.com
    \\    field pass  label=Password
    \\      input in  secret
    \\    field go
    \\      button submit  primary  label='Sign in'  tag=login  : w-full
    \\  link help  label='Forgot password?'  href=https://example.com/reset
    \\
;

test "tree documents round trip" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/tree", signin);
    try f.expectRead(R ++ "/tree", signin);
    try f.expectRead(R ++ "/title/text", "Sign in\n");
    try f.expectRead(R ++ "/f/user/in/placeholder", "you@example.com\n");
    try f.expectRead(R ++ "/f/go/submit/tag", "login\n");
    try f.expectRead(R ++ "/order", "title f help\n");
    try f.expectRead(R ++ "/f/order", "user pass go\n");
    // A subtree reads on its own.
    try f.expectRead(R ++ "/f/user/tree", "field user  label=Email\n  input in  placeholder=you@example.com\n");
    // Other spacing and order read back the same.
    try f.ok(R ++ "/tree",
        \\div root : v-flex size-full p=24 gap=16
        \\  text title text='Sign in' : text-xl font-semibold
        \\  form f
        \\    field user label=Email
        \\      input in placeholder=you@example.com
        \\    field pass label=Password
        \\      input in secret=on
        \\    field go
        \\      button submit label='Sign in' primary tag=login : w-full
        \\  link help label='Forgot password?' href=https://example.com/reset
        \\
    );
    try f.expectRead(R ++ "/tree", signin);
    // A here-value.
    const notes =
        \\div root
        \\  text notes  text=<<END
        \\# Notes
        \\
        \\- one
        \\- two
        \\END
        \\
    ;
    try f.ok(R ++ "/tree", notes);
    try f.expectRead(R ++ "/notes/text", "# Notes\n\n- one\n- two\n");
    try f.expectRead(R ++ "/tree", notes);
    // Save and restore.
    const saved = try f.a().dupe(u8, try f.read(R ++ "/tree"));
    try f.ok(R ++ "/tree", saved);
    try f.expectRead(R ++ "/tree", saved);
}

test "tree write keeps children by name and type" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/tree", signin);
    const in = f.node(R ++ "/f/user/in").?;
    const pass = f.node(R ++ "/f/pass").?;
    const help = f.node(R ++ "/help").?;
    try f.ok(R ++ "/f/user/in/value", "Ada");
    try f.ok(R ++ "/focus", "f/user/in");
    f.t.clearChanges();
    try f.ok(R ++ "/tree",
        \\div root  : v-flex size-full p=24 gap=16
        \\  form f
        \\    field user  label='Your email'
        \\      input in  placeholder=you@example.com
        \\  text title  text='Welcome back'
        \\
    );
    // Kept: the input, with its state, and the focus on it.
    try tt.expectEqual(in, f.node(R ++ "/f/user/in").?);
    try f.expectRead(R ++ "/f/user/in/value", "Ada\n");
    try f.expectRead(R ++ "/focus", "f/user/in\n");
    try f.expectRead(R ++ "/order", "f title\n");
    try f.expectRead(R ++ "/f/user/label", "Your email\n");
    const ch = try f.t.changes();
    try tt.expect(std.mem.indexOfScalar(Handle, ch.removed, pass) != null);
    try tt.expect(std.mem.indexOfScalar(Handle, ch.removed, help) != null);
    try tt.expect(std.mem.indexOfScalar(Handle, ch.created, in) == null);
    // A child whose type changed is replaced, so its state goes.
    try f.ok(R ++ "/tree", "div root\n  form f\n    field user\n      textarea in\n");
    try f.expectRead(R ++ "/f/user/in/type", "textarea\n");
    try f.expectRead(R ++ "/f/user/in/value", "");
    // The root's style was left out, so it's back to empty.
    try f.expectRead(R ++ "/style", "");
    // A bad document changes nothing.
    const before = try f.a().dupe(u8, try f.read(R ++ "/tree"));
    try tt.expectEqual(Code.unknown_type, try f.code(R ++ "/tree", "div root\n  nosuchtype x\n"));
    try tt.expect(std.meta.isError(f.write(R ++ "/tree", "div root\n      text deep\n")));
    // The root line must match the node.
    try tt.expectEqual(Code.bad_value, try f.code(R ++ "/tree", "text root\n"));
    try tt.expectEqual(Code.bad_value, try f.code(R ++ "/tree", "div other\n"));
    try f.expectRead(R ++ "/tree", before);
    try f.expectRead(R ++ "/type", "div\n");
}

// ---------------------------------------------------------------- trace

test "trace matches the conformance golden" {
    // tests/conformance/25-trace, against the tree alone.
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    const start = (try f.traceText()).len;
    try f.ok(R ++ "/ctl", "new text a text=hi\nnew input pass secret");
    try f.mkdir(R ++ "/b");
    try f.ok(R ++ "/a/text", "Hello\n");
    try f.ok(R ++ "/a/text", "line one\nline two\n");
    try f.ok(R ++ "/pass/value", "hunter2\n");
    try f.ok(R ++ "/ctl", "new input pin secret value=1234");
    try f.ok(R ++ "/ctl", "set pass value=swordfish");
    try f.ok("ctl", "set win/main/pin value=0000");
    try tt.expect(std.meta.isError(f.write(R ++ "/a/style", "flexx\n")));
    // rm -r: the files (which log nothing), then the directory
    for ([_][]const u8{ R ++ "/b/type", R ++ "/b/style", R ++ "/b" }) |p| try f.remove(p);
    try f.ok("ctl", "begin");
    try f.t.advanceClock(2 * std.time.ns_per_s);
    try tt.expectEqualStrings(
        \\ctl path=win/main/ctl cmd='new text a text=hi'
        \\ctl path=win/main/ctl cmd='new input pass secret'
        \\mkdir path=win/main/b
        \\write path=win/main/a/text value=Hello
        \\write path=win/main/a/text len=17
        \\write path=win/main/pass/value value=<secret>
        \\ctl path=win/main/ctl cmd='new input pin secret value=<secret>'
        \\ctl path=win/main/ctl cmd='set pass value=<secret>'
        \\ctl path=ctl cmd='set win/main/pin value=<secret>'
        \\error path=win/main/a/style err='unknown style word: flexx'
        \\remove path=win/main/b
        \\ctl path=ctl cmd=begin
        \\batch timeout
        \\
    , (try f.traceText())[start..]);
}

test "trace hides secrets in documents" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new input name");
    try f.ok(R ++ "/name/value", "Jo\n");
    try f.ok(R ++ "/tree", "div root\n  input pw  secret  value=hunter4\n");
    const tr = try f.traceText();
    try tt.expect(std.mem.indexOf(u8, tr, "write path=win/main/name/value value=Jo\n") != null);
    try tt.expect(std.mem.indexOf(u8, tr, "hunter") == null);
    // A tree write logs one line, not its props.
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, tr, "\n"), '\n');
    try tt.expect(std.mem.startsWith(u8, lines.next().?, "write path=win/main/tree len="));
}

// ---------------------------------------------------------------- changes

test "changes report props" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new button b");
    try f.ok(R ++ "/ctl", "show");
    f.t.clearChanges();
    try f.ok(R ++ "/b/label", "Go");
    var ch = try f.t.changes();
    try tt.expectEqual(@as(usize, 1), ch.props.len);
    try tt.expectEqual(f.node(R ++ "/b").?, ch.props[0].node);
    try tt.expectEqualStrings("label", ch.props[0].file);
    try tt.expectEqual(@as(usize, 1), ch.dirty.len);
    try tt.expectEqualStrings("main", ch.dirty[0]);
    f.t.clearChanges();
    try f.ok(R ++ "/title", "T2");
    ch = try f.t.changes();
    try tt.expectEqual(@as(usize, 1), ch.props.len);
    try tt.expectEqual(f.node(R).?, ch.props[0].node);
    try tt.expectEqualStrings("title", ch.props[0].file);
}

test "mkdir then type before first frame" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new form f");
    // mkdir under a form makes a div, which may become a field
    try f.mkdir(R ++ "/f/name");
    try tt.expectEqual(Code.unknown_type, try f.code(R ++ "/f/name/type", "button"));
    try f.ok(R ++ "/f/name/type", "field");
    try tt.expectError(error.InUse, f.mkdir(R ++ "/f/name"));
    // Changing type drops files the new type doesn't have.
    try f.ok(R ++ "/ctl", "new button b label=Hi tag=x");
    try f.ok(R ++ "/b/type", "text");
    try tt.expect(!try f.exists(R ++ "/b/label"));
    try f.expectRead(R ++ "/b/tag", "x\n");
}

// ---------------------------------------------------------------- echoes, close, theme

fn noSeq(a: std.mem.Allocator, got: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        const i = std.mem.lastIndexOf(u8, l, " seq=") orelse l.len;
        try out.appendSlice(a, l[0..i]);
        try out.append(a, '\n');
    }
    return out.items;
}

test "client writes echo with via=ctl" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new checkbox cb label='Remember me'\nnew input in\nnew button b");
    const s = try f.subPath(R);
    defer s.close();
    try f.ok(R ++ "/cb/value", "off\n");
    try f.ok(R ++ "/in/value", "typed\n");
    try f.ok(R ++ "/b/label", "no echo for labels");
    try f.ok(R ++ "/ctl", "state min");
    try f.ok(R ++ "/focus", "b");
    try tt.expectEqualStrings(
        \\change - cb win=main value=off via=ctl
        \\change - in win=main via=ctl
        \\state - . win=main value=min via=ctl
        \\focus - b win=main via=ctl
        \\
    , try noSeq(f.a(), try f.drain(s)));
    // Props set by `new` or by a tree document send no echo.
    try f.ok(R ++ "/ctl", "new checkbox cb2 value=on");
    try f.ok(R ++ "/cb2/tree", "checkbox cb2  value=mixed\n");
    try tt.expectEqualStrings("", try f.drain(s));
}

fn lastSeq(got: []const u8) !u64 {
    const t = std.mem.trimEnd(u8, got, "\n");
    const i = std.mem.lastIndexOf(u8, t, "seq=").?;
    return std.fmt.parseInt(u64, t[i + 4 ..], 10);
}

test "window close verb is a request" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    const s = try f.sub(.app);
    f.t.clearChanges();
    try f.ok(R ++ "/ctl", "close");
    try tt.expectEqual(@as(usize, 0), (try f.t.changes()).cmds.len);
    var got = try f.drain(s);
    try tt.expect(std.mem.startsWith(u8, got, "close - . win=main via=ctl seq="));
    // keep: the window stays
    try f.ok(R ++ "/ctl", try std.fmt.allocPrint(f.a(), "keep seq={d}", .{try lastSeq(got)}));
    try tt.expect(f.t.current().win("main") != null);
    // close: the window goes
    try f.ok(R ++ "/ctl", "close");
    got = try f.drain(s);
    try f.ok(R ++ "/ctl", try std.fmt.allocPrint(f.a(), "close seq={d}", .{try lastSeq(got)}));
    try tt.expect(f.t.current().win("main") == null);
    // With no reader, the default closes at once.
    s.close();
    try f.ok("ctl", "window two");
    try f.ok("win/two/ctl", "close");
    try tt.expect(f.t.current().win("two") == null);
}

test "theme tokens, pref, mode and name" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.ok("theme/tokens", "primary #0b5cff");
    try f.ok("theme/tokens", "radius 6\naccent #445566\n");
    const toks = try f.read("theme/tokens");
    for ([_][]const u8{ "primary #0b5cff\n", "radius 6\n", "accent #445566\n" }) |x|
        try tt.expect(std.mem.indexOf(u8, toks, x) != null);
    const s = try f.sub(.app);
    defer s.close();
    try tt.expectEqual(Code.not_found, try f.code("theme/tokens", "no-such-token #ffffff"));
    try tt.expectEqual(Code.bad_value, try f.code("theme/tokens", "primary blue"));
    try tt.expectEqual(Code.bad_value, try f.code("theme/tokens", "accent #000000\nprimary blue"));
    try tt.expect(std.mem.indexOf(u8, try f.read("theme/tokens"), "accent #445566\n") != null);
    try tt.expectEqualStrings(
        \\error - theme/tokens code=not-found
        \\error - theme/tokens code=bad-value
        \\error - theme/tokens code=bad-value
        \\
    , try noSeq(f.a(), try norm(f.a(), try f.drain(s))));
    // The preference starts at system; the system is light.
    try f.expectRead("theme/pref", "system\n");
    try f.expectRead("theme/mode", "light\n");
    try f.ok("theme/pref", "dark");
    try f.expectRead("theme/mode", "dark\n");
    // (Read now: theme events coalesce like any state event.)
    try tt.expectEqualStrings("theme - - mode=dark via=ctl\n", try noSeq(f.a(), try f.drain(s)));
    // Writing mode sets the preference.
    try f.ok("theme/mode", "light");
    try f.expectRead("theme/pref", "light\n");
    try f.ok("theme/mode", "system");
    try f.expectRead("theme/pref", "system\n");
    try f.expectRead("theme/mode", "light\n");
    try tt.expectEqual(Code.bad_value, try f.code("theme/mode", "sepia"));
    try tt.expectEqual(Code.bad_value, try f.code("theme/pref", "sepia"));
    try tt.expectEqualStrings(
        \\theme - - mode=light via=ctl
        \\error - theme/mode code=bad-value
        \\error - theme/pref code=bad-value
        \\
    , try noSeq(f.a(), try norm(f.a(), try f.drain(s))));
    // The system changes while pref is system, and while it is light.
    try f.t.systemDark(true);
    try f.expectRead("theme/mode", "dark\n");
    try tt.expectEqualStrings("theme - - mode=dark via=system\n", try noSeq(f.a(), try f.drain(s)));
    try f.ok("theme/pref", "light");
    try tt.expectEqualStrings("theme - - mode=light via=ctl\n", try noSeq(f.a(), try f.drain(s)));
    try f.t.systemDark(false);
    try f.t.systemDark(true);
    try tt.expectEqualStrings("", try f.drain(s));
    // Names.
    try tt.expectEqual(Code.not_found, try f.code("theme/name", "No Such Theme"));
    try tt.expectEqual(Code.not_found, try f.code("ctl", "theme load /nonexistent/theme.json"));
}

// ---------------------------------------------------------------- odds and ends

test "design state names coalesce even as actions" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new div card");
    const s = try f.sub(.app);
    defer s.close();
    const card = f.node(R ++ "/card").?;
    _ = try f.t.emit(.{ .name = "hover", .node = card, .kind = .action, .attrs = &.{.{ .key = "value", .value = "on" }} });
    _ = try f.t.emit(.{ .name = "hover", .node = card, .kind = .action, .attrs = &.{.{ .key = "value", .value = "off" }} });
    const got = try f.drain(s);
    try tt.expectEqual(@as(usize, 1), std.mem.count(u8, got, "\n"));
    try tt.expect(std.mem.indexOf(u8, got, "value=off") != null);
}

test "keystrokes are checked" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok("keys", "cmd-s save\ncmd-shift-p palette\nescape dismiss context=editor\nctrl-tab next-tab\nctrl-- zoom-out\n-      dec\nshift-= plus\n");
    try tt.expectEqual(Code.bad_value, try f.code("keys", "cmd-s save\ncmd-wibble-q quit\n"));
    try tt.expect(std.mem.startsWith(u8, try f.read("keys"), "cmd-s save\ncmd-shift-p"));
}

test "advanced clock stamps batches and requests" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.t.advanceClock(10 * std.time.ns_per_s);
    try f.ok("ctl", "begin\nask quit");
    const s = try f.sub(.app);
    defer s.close();
    _ = try f.t.request(.{ .name = "quit" }, "quit");
    f.t.clearChanges();
    try f.t.tick(0);
    try tt.expectEqual(@as(usize, 0), (try f.t.changes()).cmds.len);
    try f.t.advanceClock(tree.batch_timeout_ns);
    try tt.expect(!f.t.batchOpen());
    try tt.expectEqual(@as(usize, 1), openCount(&f));
    try f.t.advanceClock(tree.request_timeout_ns);
    try tt.expectEqual(@as(usize, 0), openCount(&f));
    try tt.expectEqual(@as(usize, 1), try cmdsOf(&f, .answer));
}

test "border is a style word, not a variant" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new div card : border=3 border-color=border");
    try f.ok(R ++ "/card/style", "border=1");
    try tt.expectEqual(Code.unknown_style_word, try f.code(R ++ "/card/style", "primary"));
}

test "tree rewrite keeps a client-written value" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/tree", signin);
    try f.ok(R ++ "/f/user/in/value", "Ada\n");
    try f.ok(R ++ "/tree", signin);
    try f.expectRead(R ++ "/f/user/in/value", "Ada\n");
    // Naming it in the document sets it.
    try f.ok(R ++ "/f/user/tree", "field user  label=Email\n  input in  value=Bob\n");
    try f.expectRead(R ++ "/f/user/in/value", "Bob\n");
}

test "tree expanded ids must be items" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new tree files");
    try f.ok(R ++ "/files/items", "src\t-\tsrc\nmain\tsrc\tmain.rs\n");
    try f.ok(R ++ "/files/expanded", "src\n");
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/files/expanded", "src nope"));
    try f.expectRead(R ++ "/files/expanded", "src\n");
}

// ---------------------------------------------------------------- threads

test "OpQueue: a 9P thread's write is applied on the owner thread and acked" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    var q: tree.OpQueue = .init(tt.allocator, tt.io);
    defer q.deinit();
    const W = struct {
        fn run(qq: *tree.OpQueue, out: *[2][64]u8, lens: *[2]usize) void {
            var ack: tree.Ack = .{};
            var path_buf: [32]u8 = undefined;
            const p = std.fmt.bufPrint(&path_buf, "win/main/ctl", .{}) catch unreachable;
            const ok_text = qq.call(.{ .write = .{ .session = 2, .path = p, .data = "new text t text=hi" } }, &ack) catch "oom";
            @memcpy(out[0][0..ok_text.len], ok_text);
            lens[0] = ok_text.len;
            const bad = qq.call(.{ .write = .{ .session = 2, .path = "win/main/zz/text", .data = "x" } }, &ack) catch "oom";
            @memcpy(out[1][0..bad.len], bad);
            lens[1] = bad.len;
        }
    };
    var out: [2][64]u8 = undefined;
    var lens: [2]usize = .{ 99, 99 };
    const th = try std.Thread.spawn(.{}, W.run, .{ &q, &out, &lens });
    var ran: usize = 0;
    while (ran < 2) ran += q.drain(f.t);
    th.join();
    try tt.expectEqualStrings("", out[0][0..lens[0]]);
    try tt.expect(std.mem.startsWith(u8, out[1][0..lens[1]], "not found"));
    try f.expectRead(R ++ "/t/text", "hi\n");
    // After close, a push fails at once with `app gone`.
    q.close();
    var ack: tree.Ack = .{};
    try tt.expectEqualStrings("app gone", try q.call(.{ .mkdir = .{ .session = 2, .path = R ++ "/x" } }, &ack));
}

test "snapshots: readers keep the version they acquired" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new text t text=one");
    try f.t.publish();
    const old = f.t.acquire();
    defer old.release();
    try f.ok(R ++ "/t/text", "two");
    try f.t.publish();
    const new = f.t.acquire();
    defer new.release();
    try tt.expectEqualStrings("one\n", try old.read(f.a(), R ++ "/t/text"));
    try tt.expectEqualStrings("two\n", try new.read(f.a(), R ++ "/t/text"));
    // A reader on another thread.
    const T = struct {
        fn run(s: *tree.Snapshot, out: *[16]u8, n: *usize) void {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            const v = s.read(arena.allocator(), R ++ "/t/text") catch "err";
            @memcpy(out[0..v.len], v);
            n.* = v.len;
        }
    };
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    const th = try std.Thread.spawn(.{}, T.run, .{ new.retain(), &buf, &n });
    th.join();
    new.release();
    try tt.expectEqualStrings("two\n", buf[0..n]);
}

test "a write to a file whose node went away is gone" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    try f.ok(R ++ "/ctl", "new text a");
    const a = f.node(R ++ "/a").?;
    try f.ok(R ++ "/ctl", "delete a\nnew text a");
    try tt.expectError(error.Gone, f.t.apply(.{ .write = .{ .session = 1, .path = R ++ "/a/text", .data = "x", .node = a } }));
    try f.t.apply(.{ .write = .{ .session = 1, .path = R ++ "/a/text", .data = "x", .node = f.node(R ++ "/a").? } });
}

test "conformance fixes: quoting, secret, data, accordion, canvas" {
    var f: Fx = undefined;
    try f.app();
    defer f.deinit();
    // 04: a quoted prop=value is still a prop
    try f.ok(R ++ "/ctl", "new text b 'text=also grouped'");
    try f.expectRead(R ++ "/b/text", "also grouped\n");
    // 09: a secret input's value stays out of its document
    try f.ok(R ++ "/ctl", "new input pass secret");
    try f.ok(R ++ "/pass/value", "hunter2\n");
    try f.expectRead(R ++ "/pass/tree", "input pass  secret\n");
    // 12: a malformed data file is bad value; a missing tree parent not found
    try f.ok(R ++ "/ctl", "new list l\nnew tree tr");
    try tt.expectEqual(Code.bad_value, try f.code(R ++ "/l/items", "\tNameless\n"));
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/tr/items", "a\tnope\tA\n"));
    // 13: an accordion's value names its items
    try f.ok(R ++ "/ctl", "new accordion acc\nnew accordion-item acc/a title=One\nnew accordion-item acc/b title=Two");
    try f.ok(R ++ "/acc/value", "a b");
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/acc/value", "a zz"));
    // 22: canvas edit verbs by item id
    try f.ok(R ++ "/ctl", "new canvas c");
    try f.ok(R ++ "/c/ops", "rect bg 0 0 400 300 fill=background\nrect card 20 20 160 90\ncircle dot 140.5 150 4 fill=primary\n");
    try f.ok(R ++ "/c/ctl", "set dot 150 140");
    try f.ok(R ++ "/c/ctl", "add circle dot2 10 10 3 fill=accent");
    try f.ok(R ++ "/c/ctl", "del card");
    try f.ok(R ++ "/c/ctl", "raise bg");
    try f.ok(R ++ "/c/ctl", "lower dot2");
    try f.expectRead(R ++ "/c/ops", "circle dot2 10 10 3 fill=accent\ncircle dot 150 140 4 fill=primary\nrect bg 0 0 400 300 fill=background\n");
    try tt.expectEqual(Code.not_found, try f.code(R ++ "/c/ctl", "set nope 1 1"));
    try tt.expectEqual(Code.in_use, try f.code(R ++ "/c/ctl", "add rect dot 0 0 1 1"));
}
