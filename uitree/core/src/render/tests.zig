//! The change stream's goldens (protocols/render.md § The change stream):
//! app writes to a tree over the built-in catalog, one pump at a time, and
//! the exact text the encoder makes of each. The conformance suite under
//! `run -r` checks that the stream is complete; these pin its spelling.

const std = @import("std");
const abi = @import("../abi.zig");
const types = @import("../types/root.zig");
const treem = @import("../tree/root.zig");
const stream = @import("stream.zig");
const replica = @import("replica.zig");

const tt = std.testing;

const Fx = struct {
    cat: types.Catalog,
    t: *treem.Tree,
    enc: stream.Encoder,
    started: bool = false,

    fn init(f: *Fx) !void {
        f.cat = try types.Catalog.builtin(tt.allocator);
        errdefer f.cat.deinit();
        f.t = try treem.Tree.create(tt.allocator, tt.io, &f.cat, .{});
        f.enc = .{ .gpa = tt.allocator };
        try f.ok("ctl", "window main title=Test size=400,300");
        // The snapshot a renderer attaching now gets: the window is
        // hidden until it has content, so only the theme.
        const snap = try f.pump();
        defer tt.allocator.free(snap);
        try tt.expect(std.mem.startsWith(u8, snap, "snap 1\ntheme mode=light name='' tokens=<<END\n"));
        try tt.expect(std.mem.endsWith(u8, snap, "\nEND\nend 1\n"));
    }

    fn deinit(f: *Fx) void {
        f.enc.deinit();
        f.t.destroy();
        f.cat.deinit();
    }

    fn ok(f: *Fx, p: []const u8, data: []const u8) !void {
        f.t.apply(.{ .write = .{ .session = 1, .path = p, .data = data } }) catch |e| {
            std.debug.print("write {s} {s}: {s}\n", .{ p, data, f.t.lastError() });
            return e;
        };
    }

    /// One pump: what the stream says of it, caller frees.
    fn pump(f: *Fx) ![]u8 {
        var arena: std.heap.ArenaAllocator = .init(tt.allocator);
        defer arena.deinit();
        var uch: abi.UitChanges = .{};
        try abi.fill(arena.allocator(), try f.t.changes(), &uch);
        var aw: std.Io.Writer.Allocating = .init(tt.allocator);
        errdefer aw.deinit();
        const src: stream.Source = .{ .st = f.t.committed(), .cat = &f.cat };
        f.enc.seq += 1;
        if (!f.started) {
            try f.enc.snapshot(src, &aw.writer);
            f.started = true;
        } else _ = try f.enc.batch(src, &uch, 0, &aw.writer);
        f.t.clearChanges();
        return aw.toOwnedSlice();
    }

    fn expect(f: *Fx, want: []const u8) !void {
        const got = try f.pump();
        defer tt.allocator.free(got);
        try tt.expectEqualStrings(want, got);
    }
};

test "a window shows with what it holds; sets and deletes after" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.ok("win/main/ctl", "new text a text=hi\nnew button b label=Go primary : p=4");
    try f.expect(
        \\batch 2 x.t=0
        \\window main title=Test size=400,300 state=normal
        \\new div win/main
        \\new text win/main/a text=hi
        \\new button win/main/b primary label=Go : p=4
        \\end 2
        \\
    );
    try f.ok("win/main/ctl", "set a text='bye now'");
    try f.ok("win/main/ctl", "set b ghost");
    try f.expect(
        \\batch 3 x.t=0
        \\set win/main/a text='bye now'
        \\set win/main/b ghost : p=4
        \\end 3
        \\
    );
    try f.ok("win/main/ctl", "delete a");
    try f.expect(
        \\batch 4 x.t=0
        \\delete win/main/a
        \\end 4
        \\
    );
}

test "a renderer's typing is a mirror record, not a set" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.ok("win/main/ctl", "new input name");
    tt.allocator.free(try f.pump());
    const st = f.t.committed();
    const h = try treem.path.resolveNode(st, tt.allocator, st.win("main").?.root, "name", null);
    try f.t.mirror(h, "value", "Ada");
    try f.expect(
        \\batch 3 x.t=0
        \\mirror win/main/name value=Ada
        \\end 3
        \\
    );
}

test "what an app's batch makes waits for its commit" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.ok("win/main/ctl", "new text a text=one");
    const first = try f.pump();
    tt.allocator.free(first);
    try f.ok("ctl", "begin");
    try f.ok("win/main/ctl", "new text b text=two");
    try f.ok("win/main/ctl", "delete a");
    try f.expect(
        \\batch 3 x.t=0
        \\end 3
        \\
    );
    try f.ok("ctl", "commit");
    try f.expect(
        \\batch 4 x.t=0
        \\delete win/main/a
        \\new text win/main/b text=two
        \\redraw main
        \\end 4
        \\
    );
}

test "a node whose type changes is remade" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.ok("win/main/ctl", "new text a text=x");
    const first = try f.pump();
    tt.allocator.free(first);
    // mkdir makes a div; the type written next pump makes it a text.
    try f.t.apply(.{ .mkdir = .{ .session = 1, .path = "win/main/box" } });
    try f.expect(
        \\batch 3 x.t=0
        \\new div win/main/box
        \\end 3
        \\
    );
    try f.ok("win/main/box/type", "text");
    try f.expect(
        \\batch 4 x.t=0
        \\delete win/main/box
        \\new text win/main/box
        \\end 4
        \\
    );
}

test "keys travel as a here-value and a replica reads them back" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.ok("keys", "cmd-s save\nescape dismiss\n");
    const got = try f.pump();
    defer tt.allocator.free(got);
    try tt.expectEqualStrings(
        \\batch 2 x.t=0
        \\keys text=<<END
        \\cmd-s save
        \\escape dismiss
        \\END
        \\end 2
        \\
    , got);

    // The same bytes into a replica give the same keys file.
    const rt = try treem.Tree.create(tt.allocator, tt.io, &f.cat, .{});
    defer rt.destroy();
    var rep: replica.Replica = .{ .gpa = tt.allocator, .t = rt };
    defer rep.deinit();
    try rep.feed(got[0..20]);
    try tt.expectEqual(@as(u64, 0), rep.frames);
    try rep.feed(got[20..]);
    try tt.expectEqual(@as(u64, 1), rep.frames);
    try tt.expectEqual(@as(usize, 0), rep.errors.items.len);
    try tt.expectEqualStrings(treem.state.Blob.str(f.t.committed().keys), treem.state.Blob.str(rt.current().keys));
}

test "a core draws another core's app through uit_render_dial" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const cfg: abi.UitConfig = .{ .abi_version = abi.abi_version, .types = .{}, .style_words = .{}, .theme_tokens = .{}, .system_dark = 0, .wake = null, .wake_ctx = null };
    var ap: ?*abi.Core = null;
    var rp: ?*abi.Core = null;
    try tt.expectEqual(abi.UIT_OK, abi.uit_create(&cfg, &ap));
    const app = ap.?;
    defer abi.uit_destroy(app);
    try tt.expectEqual(abi.UIT_OK, abi.uit_create(&cfg, &rp));
    const rend = rp.?;
    defer abi.uit_destroy(rend);

    var dial: abi.UitStr = .{};
    try tt.expectEqual(abi.UIT_OK, abi.uit_render_listen(app, .{}, 0, &dial));
    // The app's side: a counter, as an app's writes.
    try app.tree.apply(.{ .write = .{ .session = 1, .path = "win/main/ctl", .data = "set . title=Counter\nnew text n text=0\nnew input in placeholder=Name" } });
    try tt.expectEqual(abi.UIT_OK, abi.uit_render_dial(rend, dial, abi.UitStr.lit("test"), abi.UitStr.lit("primary")));

    const Both = struct {
        fn pump(x: *abi.Core, y: *abi.Core) void {
            var ch: abi.UitChanges = .{};
            _ = abi.uit_pump(x, &ch);
            _ = abi.uit_pump(y, &ch);
            x.io().sleep(.fromMilliseconds(2), .awake) catch {};
        }
        fn text(c: *abi.Core, path: []const u8) ?[]const u8 {
            const st = c.tree.current();
            const w = st.win("main") orelse return null;
            var buf: [256]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            const h = treem.path.resolveNode(st, fba.allocator(), w.root, path, null) catch return null;
            const n = st.node(h) orelse return null;
            return if (std.mem.eql(u8, path, "n")) n.value("text") else n.value("value");
        }
    };
    var tries: usize = 0;
    while (Both.text(rend, "n") == null and tries < 2000) : (tries += 1) Both.pump(app, rend);
    try tt.expectEqualStrings("0", Both.text(rend, "n").?);
    try tt.expectEqualStrings("Counter", treem.state.Blob.str(rend.tree.current().win("main").?.title));

    // The app writes; the renderer's tree follows.
    try app.tree.apply(.{ .write = .{ .session = 1, .path = "win/main/ctl", .data = "set n text=1" } });
    tries = 0;
    while (!std.mem.eql(u8, Both.text(rend, "n") orelse "", "1") and tries < 2000) : (tries += 1) Both.pump(app, rend);
    try tt.expectEqualStrings("1", Both.text(rend, "n").?);

    // The renderer types; the app's tree has it, as uit_mirror would.
    const st = rend.tree.current();
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const field = try treem.path.resolveNode(st, fba.allocator(), st.win("main").?.root, "in", null);
    try tt.expectEqual(abi.UIT_OK, abi.uit_mirror(rend, field, abi.UitStr.lit("value"), abi.UitStr.lit("Ada")));
    tries = 0;
    while (!std.mem.eql(u8, Both.text(app, "in") orelse "", "Ada") and tries < 2000) : (tries += 1) Both.pump(app, rend);
    try tt.expectEqualStrings("Ada", Both.text(app, "in").?);
}
