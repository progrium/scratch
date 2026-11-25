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
        try f.t.pumpTerms();
        try abi.fill(arena.allocator(), try f.t.changes(), &uch);
        var aw: std.Io.Writer.Allocating = .init(tt.allocator);
        errdefer aw.deinit();
        const src: stream.Source = .{ .st = f.t.committed(), .cat = &f.cat, .terms = &f.t.terms };
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

// ---- Terminals (render.md § Terminals, the terminal contracts' C4): their
// spelling, that they read back as the C ABI structs they came from, and
// the encoder's use of them.

const term = @import("term.zig");
const ctl = @import("../proto/ctl.zig");

test "terminal records: term, term-styles, term-rows" {
    var aw: std.Io.Writer.Allocating = .init(tt.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    const cur: abi.UitTermCursor = .{ .x = 3, .y = 1, .shape = 1, .visible = 1, .blink = 1, .cols = 80, .rows = 24 };
    const styles = [_]abi.UitTermStyle{
        .{},
        .{ .fg = 0xcd3131ff, .flags = abi.UIT_TERM_BOLD | abi.UIT_TERM_ITALIC },
        .{ .bg = 0x1e1e1eff, .underline_color = 0xffcc00ff, .underline = 3, .flags = abi.UIT_TERM_INVERSE },
    };
    const r0 = [_]abi.UitTermRun{
        .{ .col = 0, .width = 2, .style = 1, .text = abi.UitStr.lit("$ ") },
        .{ .col = 2, .width = 6, .style = 0, .selected = 1, .text = abi.UitStr.lit("ls -la") },
        .{ .col = 10, .width = 4, .style = 2, .text = abi.UitStr.lit("日本") },
        .{ .col = 15, .width = 3, .style = 0, .text = abi.UitStr.lit("it's") },
    };
    const rows = [_]abi.UitTermRow{
        .{ .y = 0, .runs = &r0, .n_runs = r0.len },
        .{ .y = 1 },
    };
    try term.writeTerm(w, "win/main/sh", cur);
    try term.writeStyles(w, "win/main/sh", 0, &styles);
    try term.writeRows(w, "win/main/sh", &rows);
    try term.writeStyles(w, "win/main/sh", 3, &.{});
    try term.writeRows(w, "win/main/sh", &.{});
    try tt.expectEqualStrings(
        \\term win/main/sh cols=80 rows=24 cursor=3,1 shape=bar visible=on blink=on
        \\term-styles win/main/sh first=0 text=<<END
        \\- - -
        \\#cd3131ff - - bold italic
        \\- #1e1e1eff #ffcc00ff inverse underline=curly
        \\END
        \\term-rows win/main/sh text=<<END
        \\0 0:1:2 '$ ' 2:0:6:sel 'ls -la' 10:2:4 日本 15:0:3 'it''s'
        \\1
        \\END
        \\
    , aw.written());

    // They read back as what they were made from.
    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmds = try ctl.parseWrite(a, aw.written());
    try tt.expectEqual(@as(usize, 3), cmds.len);
    try tt.expectEqualStrings("term", cmds[0].verb);
    try tt.expectEqualStrings("win/main/sh", cmds[0].words[0]);
    try tt.expectEqual(cur, try term.parseTerm(cmds[0]));
    try tt.expectEqualStrings("0", cmds[1].attr("first").?);
    var lines = std.mem.splitScalar(u8, cmds[1].attr("text").?, '\n');
    for (styles) |s| try tt.expectEqual(s, try term.parseStyleLine(lines.next().?));
    lines = std.mem.splitScalar(u8, cmds[2].attr("text").?, '\n');
    const back = try term.parseRowLine(a, lines.next().?);
    try tt.expectEqual(@as(u32, 0), back.y);
    try tt.expectEqual(r0.len, back.n_runs);
    for (r0, back.runs.?[0..back.n_runs]) |want, got| {
        try tt.expectEqual(want.col, got.col);
        try tt.expectEqual(want.width, got.width);
        try tt.expectEqual(want.style, got.style);
        try tt.expectEqual(want.selected, got.selected);
        try tt.expectEqualStrings(want.text.slice(), got.text.slice());
    }
    const blank = try term.parseRowLine(a, lines.next().?);
    try tt.expectEqual(@as(u32, 1), blank.y);
    try tt.expectEqual(@as(usize, 0), blank.n_runs);
    try tt.expectError(error.BadSyntax, term.parseRowLine(a, "0 1:0:1"));
    try tt.expectError(error.BadSyntax, term.parseStyleLine("#fff - -"));
}

test "terminal input lines: term-resize, term-mouse, term-scroll, term-text, term-paste" {
    var aw: std.Io.Writer.Allocating = .init(tt.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    const ins = [_]term.Input{
        .{ .resize = .{ .win = "main", .node = "sh", .cols = 80, .rows = 24, .cell_w_px = 16, .cell_h_px = 34 } },
        .{ .mouse = .{ .win = "main", .node = "sh", .m = .{ .action = abi.UIT_TERM_PRESS, .button = abi.UIT_TERM_BUTTON_LEFT, .col = 4, .row = 2, .mods = abi.UIT_TERM_MOD_SHIFT | abi.UIT_TERM_MOD_CTRL, .clicks = 2 } } },
        .{ .mouse = .{ .win = "main", .node = "sh", .m = .{ .action = abi.UIT_TERM_MOVE, .col = 5, .row = 2 } } },
        .{ .scroll = .{ .win = "main", .node = "sh", .lines = -3 } },
        .{ .text = .{ .win = "main", .node = "sh", .text = "日本語" } },
        .{ .text = .{ .win = "main", .node = "sh", .text = "two\nlines" } },
        .{ .paste = .{ .win = "main", .node = "sh", .text = "ls -l" } },
    };
    for (ins) |in| try term.writeInput(w, in);
    try tt.expectEqualStrings(
        \\term-resize win=main node=sh cols=80 rows=24 cw=16 ch=34
        \\term-mouse win=main node=sh action=press button=left col=4 row=2 mods=shift,ctrl clicks=2
        \\term-mouse win=main node=sh action=move button=none col=5 row=2
        \\term-scroll win=main node=sh lines=-3
        \\term-text win=main node=sh text=日本語
        \\term-text win=main node=sh text=<<END
        \\two
        \\lines
        \\END
        \\term-paste win=main node=sh text='ls -l'
        \\
    , aw.written());

    var arena: std.heap.ArenaAllocator = .init(tt.allocator);
    defer arena.deinit();
    const cmds = try ctl.parseWrite(arena.allocator(), aw.written());
    try tt.expectEqual(ins.len, cmds.len);
    for (ins, cmds) |want, c| {
        const got = (try term.parseInput(c)).?;
        try tt.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
        switch (want) {
            .resize => |r| try tt.expectEqual(r.cell_h_px, got.resize.cell_h_px),
            .mouse => |m| try tt.expectEqual(m.m, got.mouse.m),
            .scroll => |s| try tt.expectEqual(s.lines, got.scroll.lines),
            .text => |t| try tt.expectEqualStrings(t.text, got.text.text),
            .paste => |t| try tt.expectEqualStrings(t.text, got.paste.text),
        }
    }
    try tt.expectEqual(@as(?term.Input, null), try term.parseInput(try ctl.parse(arena.allocator(), "key win=main stroke=a")));
    try tt.expectError(error.BadSyntax, term.parseInput(try ctl.parse(arena.allocator(), "term-mouse win=main node=sh action=hover col=1 row=1")));
}

test "a terminal in the stream: whole when made, then what changed" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.ok("win/main/ctl", "new terminal sh");
    const t = f.t.terms.get(f.t.terms.handles()[0]).?;
    defer t.unref();
    try t.write("$ ls\r\n");
    try f.expect(
        \\batch 2 x.t=0
        \\window main title=Test size=400,300 state=normal
        \\new div win/main
        \\new terminal win/main/sh
        \\term win/main/sh cols=80 rows=24 cursor=0,1 shape=block visible=on blink=off
        \\term-styles win/main/sh first=0 text=<<END
        \\- - -
        \\END
        \\term-rows win/main/sh text=<<END
        \\0 0:0:4 '$ ls'
        \\END
        \\end 2
        \\
    );
    // One row changed; the cursor moved.
    try t.write("a  b");
    try f.expect(
        \\batch 3 x.t=0
        \\term win/main/sh cols=80 rows=24 cursor=4,1 shape=block visible=on blink=off
        \\term-rows win/main/sh text=<<END
        \\1 0:0:4 'a  b'
        \\END
        \\end 3
        \\
    );
    // A verb on its ctl draws too; nothing changed is nothing sent.
    try f.ok("win/main/sh/ctl", "write !");
    try f.expect(
        \\batch 4 x.t=0
        \\term win/main/sh cols=80 rows=24 cursor=5,1 shape=block visible=on blink=off
        \\term-rows win/main/sh text=<<END
        \\1 0:0:5 'a  b!'
        \\END
        \\end 4
        \\
    );
    const none = try f.pump();
    defer tt.allocator.free(none);
    try tt.expectEqualStrings("", none);
}

test "the checker replays a terminal to the same screen" {
    const check = @import("check.zig");
    var cat = try types.Catalog.builtin(tt.allocator);
    defer cat.deinit();
    const live = try treem.Tree.create(tt.allocator, tt.io, &cat, .{});
    defer live.destroy();
    const k = try check.Checker.create(tt.allocator, tt.io, &cat);
    defer k.destroy();
    const Step = struct {
        fn pump(kk: *check.Checker, lt: *treem.Tree) !void {
            try lt.pumpTerms();
            lt.publish() catch {};
            try kk.pump(lt.committed(), try lt.changes(), &lt.terms);
            lt.clearChanges();
        }
    };
    try live.apply(.{ .write = .{ .session = 1, .path = "win/main/ctl", .data = "set . title=T\nnew text x text=1" } });
    try Step.pump(k, live);
    try live.apply(.{ .write = .{ .session = 1, .path = "win/main/ctl", .data = "new terminal sh" } });
    try Step.pump(k, live);
    const h = live.committed().win("main").?.root;
    var sh: treem.Handle = 0;
    for (live.committed().node(h).?.children.items) |c| {
        if (std.mem.eql(u8, live.committed().node(c).?.ty.name, "terminal")) sh = c;
    }
    const t = live.terms.get(sh).?;
    defer t.unref();
    try t.write("one\r\ntwo\r\n");
    try Step.pump(k, live);
    try t.write("three");
    try live.apply(.{ .write = .{ .session = 1, .path = "win/main/sh/ctl", .data = "scroll top" } });
    try Step.pump(k, live);

    var aw: std.Io.Writer.Allocating = .init(tt.allocator);
    defer aw.deinit();
    const ok = try k.compare(live.committed(), &live.terms, &aw.writer);
    if (!ok) std.debug.print("{s}\n", .{aw.written()});
    try tt.expect(ok);
    // The replica made no engine of its own; its view says the screen.
    try tt.expectEqual(@as(usize, 0), k.t.terms.count());
    try tt.expectEqual(@as(usize, 1), k.rep.views.map.count());
    var sw: std.Io.Writer.Allocating = .init(tt.allocator);
    defer sw.deinit();
    try k.rep.views.map.values()[0].screenText(&sw.writer);
    try tt.expectEqualStrings("one\ntwo\nthree\n", sw.written());
}
