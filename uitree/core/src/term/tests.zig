//! Tests every engine backend must pass (engine.zig, C1), run against each
//! one this core is built with: the plain stand-in always, libghostty-vt
//! with -Dterminal=ghostty. A test that needs more than the stand-in does
//! (styles, cursor addressing, modes) runs on libghostty-vt only.
//!
//! The byte streams in testdata/ are real programs' output on an 80x24
//! xterm-256color pty, recorded with testdata/record.py:
//!
//!   ls-color.vt   ls --color=always -F, in a directory of six entries
//!   vim.vt        vim -u NONE opening a two-line file
//!   htop.vt       htop's first frame
//!   less-open.vt  less on a 100-line file, one page down
//!   less.vt       the same, quit: the alternate screen is left

const std = @import("std");
const engine = @import("engine.zig");
const Plain = @import("plain.zig").Plain;

const tt = std.testing;
const Writer = std.Io.Writer;

const real = engine.backend != .plain;

/// The engines under test.
const engines = if (real) .{ Plain, engine.Engine } else .{Plain};

fn isPlain(comptime T: type) bool {
    return T == Plain;
}

fn Harness(comptime T: type) type {
    return struct {
        e: T,
        row: engine.Row = .{},
        dirty: engine.Dirty = .{},
        ev: engine.Events = .{},

        const H = @This();

        fn init(opts: engine.Opts) !H {
            return .{ .e = try T.init(tt.allocator, opts) };
        }
        fn deinit(h: *H) void {
            h.row.deinit(tt.allocator);
            h.dirty.deinit(tt.allocator);
            h.ev.deinit(tt.allocator);
            h.e.deinit();
        }
        fn screen(h: *H) ![]u8 {
            var aw: Writer.Allocating = .init(tt.allocator);
            errdefer aw.deinit();
            try h.e.screenText(&aw.writer);
            return aw.toOwnedSlice();
        }
        fn expectScreen(h: *H, want: []const u8) !void {
            const got = try h.screen();
            defer tt.allocator.free(got);
            tt.expectEqualStrings(want, got) catch |e| {
                std.debug.print("engine {s}\n", .{@typeName(T)});
                return e;
            };
        }
        fn selection(h: *H) ![]u8 {
            var aw: Writer.Allocating = .init(tt.allocator);
            errdefer aw.deinit();
            try h.e.selectionText(&aw.writer);
            return aw.toOwnedSlice();
        }
        fn expectSelection(h: *H, want: []const u8) !void {
            const got = try h.selection();
            defer tt.allocator.free(got);
            tt.expectEqualStrings(want, got) catch |e| {
                std.debug.print("engine {s}\n", .{@typeName(T)});
                return e;
            };
        }
        fn key(h: *H, stroke: []const u8) ![]u8 {
            var aw: Writer.Allocating = .init(tt.allocator);
            errdefer aw.deinit();
            if (!try h.e.encodeKey(engine.parseStroke(stroke, .ctrl).?, &aw.writer)) {
                aw.deinit();
                return error.NoBytes;
            }
            return aw.toOwnedSlice();
        }
        fn expectKey(h: *H, stroke: []const u8, want: []const u8) !void {
            const got = h.key(stroke) catch |e| {
                std.debug.print("engine {s}, key {s}: {t}\n", .{ @typeName(T), stroke, e });
                return e;
            };
            defer tt.allocator.free(got);
            tt.expectEqualStrings(want, got) catch |e| {
                std.debug.print("engine {s}, key {s}\n", .{ @typeName(T), stroke });
                return e;
            };
        }
        /// The run covering column `col` of row `y`.
        fn runAt(h: *H, y: u16, col: u16) !?engine.Run {
            try h.e.row(y, &h.row);
            for (h.row.runs.items) |r| if (col >= r.col and col < r.col + r.width) return r;
            return null;
        }
        fn styleAt(h: *H, y: u16, col: u16) !engine.Style {
            const r = (try h.runAt(y, col)) orelse return .{};
            return h.e.styles()[r.style];
        }
        /// The text of row `y` as its runs give it, blanks filled in.
        fn rowText(h: *H, y: u16, buf: []u8) ![]const u8 {
            try h.e.row(y, &h.row);
            var n: usize = 0;
            var col: u16 = 0;
            for (h.row.runs.items) |r| {
                while (col < r.col) : (col += 1) {
                    buf[n] = ' ';
                    n += 1;
                }
                const t = h.row.runText(r);
                @memcpy(buf[n..][0..t.len], t);
                n += t.len;
                col += r.width;
            }
            return buf[0..n];
        }
    };
}

test "ls --color: text, and its colors where the engine has styles" {
    inline for (engines) |T| {
        var h: Harness(T) = try .init(.{});
        defer h.deinit();
        try h.e.feed(@embedFile("testdata/ls-color.vt"));
        try h.expectScreen("README.md  build.sh*  docs/  link.txt@  notes.txt  src/\n");
        var buf: [128]u8 = undefined;
        try tt.expectEqualStrings("README.md  build.sh*  docs/  link.txt@  notes.txt  src/", try h.rowText(0, &buf));
        try tt.expectEqual(@as(u16, 0), h.e.cursor().x);
        try tt.expectEqual(@as(u16, 1), h.e.cursor().y);
        if (!isPlain(T)) {
            // README.md is plain, docs/ is bold blue (01;34), build.sh bold
            // green (01;32), and the classifier after each is plain again.
            try tt.expectEqual(@as(u32, 0), (try h.runAt(0, 0)).?.style);
            const docs = try h.styleAt(0, 22);
            try tt.expect(docs.flags.bold);
            try tt.expect(docs.fg != 0 and docs.fg & 0xff == 0xff);
            const build = try h.styleAt(0, 11);
            try tt.expect(build.flags.bold and build.fg != docs.fg);
            try tt.expectEqual(@as(u32, 0), (try h.runAt(0, 26)).?.style);
            try tt.expect(h.e.styles().len >= 4);
        }
    }
}

test "vim startup: the buffer, tildes, the status line, and its queries answered" {
    inline for (engines) |T| if (!isPlain(T)) {
        var h: Harness(T) = try .init(.{});
        defer h.deinit();
        try h.e.feed(@embedFile("testdata/vim.vt"));
        const got = try h.screen();
        defer tt.allocator.free(got);
        try tt.expect(std.mem.startsWith(u8, got, "hello from vim\nsecond line\n~\n~\n"));
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, got, "\n"), '\n');
        var n: usize = 0;
        var last: []const u8 = "";
        while (lines.next()) |l| : (n += 1) last = l;
        try tt.expectEqual(@as(usize, 24), n);
        try tt.expect(std.mem.indexOf(u8, last, "hello.txt") != null);
        try tt.expect(h.e.modes().alt_screen);
        try tt.expect(h.e.modes().bracketed_paste);
        try tt.expect(h.e.modes().app_cursor);
        const cur = h.e.cursor();
        try tt.expectEqual(@as(u16, 0), cur.x);
        try tt.expectEqual(@as(u16, 0), cur.y);
        // The tildes are colored (vim's NonText, 94m).
        try tt.expect((try h.styleAt(2, 0)).fg != 0);
        // vim asked for the cursor position (DSR) and the terminal's
        // version (DA2); the answers are for its input.
        try h.e.takeEvents(&h.ev);
        const reply = h.ev.str(h.ev.reply.?);
        try tt.expect(std.mem.indexOf(u8, reply, "R") != null);
        try tt.expect(std.mem.startsWith(u8, reply, "\x1b["));
        // DECCKM is on, so arrows are SS3.
        try h.expectKey("up", "\x1bOA");
    };
}

test "htop frame: meters, the inverse header row, the process list" {
    inline for (engines) |T| if (!isPlain(T)) {
        var h: Harness(T) = try .init(.{});
        defer h.deinit();
        try h.e.feed(@embedFile("testdata/htop.vt"));
        const got = try h.screen();
        defer tt.allocator.free(got);
        try tt.expect(h.e.modes().alt_screen);
        try tt.expect(std.mem.indexOf(u8, got, "Tasks:") != null);
        try tt.expect(std.mem.indexOf(u8, got, "Load average:") != null);
        var buf: [256]u8 = undefined;
        const header = try h.rowText(9, &buf);
        try tt.expect(std.mem.indexOf(u8, header, "PID USER") != null);
        try tt.expect((try h.styleAt(9, 2)).flags.inverse);
        try tt.expect((try h.styleAt(1, 4)).flags.bold or (try h.styleAt(1, 5)).flags.bold);
        try tt.expect(!h.e.cursor().visible);
    };
}

test "alternate screen: less shows a page, and quitting restores the screen" {
    inline for (engines) |T| if (!isPlain(T)) {
        {
            var h: Harness(T) = try .init(.{});
            defer h.deinit();
            try h.e.feed(@embedFile("testdata/less-open.vt"));
            try tt.expect(h.e.modes().alt_screen);
            var want: std.ArrayList(u8) = .empty;
            defer want.deinit(tt.allocator);
            for (24..47) |i| try want.print(tt.allocator, "line {d}\n", .{i});
            try want.appendSlice(tt.allocator, ":\n");
            try h.expectScreen(want.items);
            // The alternate screen has no history to scroll into.
            h.e.scroll(.top);
            try h.expectScreen(want.items);
        }
        {
            var h: Harness(T) = try .init(.{});
            defer h.deinit();
            try h.e.feed(@embedFile("testdata/less.vt"));
            try tt.expect(!h.e.modes().alt_screen);
            try h.expectScreen("before less\nafter less\n");
        }
    };
}

test "selection: cells, words, lines, and the selected runs" {
    inline for (engines) |T| {
        var h: Harness(T) = try .init(.{ .cols = 20, .rows = 3 });
        defer h.deinit();
        try h.e.feed("hello big world\r\nsecond line");
        h.e.select(.{ .range = .{ .start = .{ .col = 8, .row = 0 }, .end = .{ .col = 1, .row = 0 } } });
        try h.expectSelection("ello big");

        try h.e.row(0, &h.row);
        const runs = h.row.runs.items;
        try tt.expectEqual(@as(usize, 3), runs.len);
        try tt.expectEqualStrings("h", h.row.runText(runs[0]));
        try tt.expect(!runs[0].selected and runs[1].selected and !runs[2].selected);
        try tt.expectEqual(@as(u16, 1), runs[1].col);
        try tt.expectEqual(@as(u16, 8), runs[1].width);
        try tt.expectEqualStrings("ello big", h.row.runText(runs[1]));
        try tt.expectEqualStrings(" world", h.row.runText(runs[2]));

        h.e.select(.{ .range = .{ .start = .{ .col = 7, .row = 0 }, .end = .{ .col = 2, .row = 1 }, .unit = .words } });
        try h.expectSelection("big world\nsecond");
        h.e.select(.{ .range = .{ .start = .{ .col = 3, .row = 1 }, .end = .{ .col = 3, .row = 1 }, .unit = .lines } });
        try h.expectSelection("second line");

        // Pinned to the text as it scrolls up.
        try h.e.feed("\r\n\r\nnew");
        try h.expectSelection("second line");
        h.e.select(.none);
        try h.expectSelection("");
    }
}

test "scrollback: scrolled views, the cursor, and output snapping back" {
    inline for (engines) |T| {
        var h: Harness(T) = try .init(.{ .cols = 10, .rows = 3, .scrollback = 1000 });
        defer h.deinit();
        try h.e.feed("1\r\n2\r\n3\r\n4\r\n5\r\n6");
        try h.expectScreen("4\n5\n6\n");
        h.e.scroll(.top);
        try h.expectScreen("1\n2\n3\n");
        try tt.expect(!h.e.cursor().visible);
        h.e.scroll(.{ .lines = 1 });
        try h.expectScreen("2\n3\n4\n");
        h.e.scroll(.{ .lines = -100 });
        try h.expectScreen("1\n2\n3\n");
        h.e.scroll(.bottom);
        try h.expectScreen("4\n5\n6\n");
        h.e.scroll(.{ .lines = -2 });
        try h.e.feed("7");
        try h.expectScreen("4\n5\n67\n");
        try tt.expect(h.e.cursor().visible);
    }
}

test "keys, in the program's default modes" {
    inline for (engines) |T| {
        var h: Harness(T) = try .init(.{});
        defer h.deinit();
        const cases = .{
            .{ "a", "a" },            .{ "A", "A" },               .{ "ctrl-c", "\x03" },
            .{ "alt-x", "\x1bx" },    .{ "enter", "\r" },          .{ "backspace", "\x7f" },
            .{ "up", "\x1b[A" },      .{ "ctrl-up", "\x1b[1;5A" }, .{ "shift-tab", "\x1b[Z" },
            .{ "pageup", "\x1b[5~" }, .{ "f1", "\x1bOP" },         .{ "f5", "\x1b[15~" },
            .{ "é", "é" },
            .{ "escape", "\x1b" },    .{ "tab", "\t" },            .{ "!", "!" },
            .{ "space", " " },
        };
        inline for (cases) |c| try h.expectKey(c[0], c[1]);
        try tt.expectError(error.NoBytes, h.key("super-c"));
        var aw: Writer.Allocating = .init(tt.allocator);
        defer aw.deinit();
        try h.e.encodeText("日本", &aw.writer);
        try tt.expectEqualStrings("日本", aw.written());
    }
}

test "keys follow the program's modes: DECCKM and kitty's protocol" {
    inline for (engines) |T| if (!isPlain(T)) {
        var h: Harness(T) = try .init(.{});
        defer h.deinit();
        try h.e.feed("\x1b[?1h");
        try tt.expect(h.e.modes().app_cursor);
        try h.expectKey("up", "\x1bOA");
        try h.expectKey("left", "\x1bOD");
        try h.e.feed("\x1b[?1l\x1b[>1u");
        try h.expectKey("up", "\x1b[A");
        try h.expectKey("ctrl-c", "\x1b[99;5u");
        try h.expectKey("escape", "\x1b[27u");
    };
}

test "mouse: none without a mouse mode, SGR when the program asks" {
    inline for (engines) |T| {
        var h: Harness(T) = try .init(.{});
        defer h.deinit();
        var aw: Writer.Allocating = .init(tt.allocator);
        defer aw.deinit();
        try tt.expect(!try h.e.encodeMouse(.{ .action = .press, .button = .left, .col = 2, .row = 3 }, &aw.writer));
        try tt.expect(!h.e.modes().mouse);
        {
            try h.e.feed("\x1b[?1000h\x1b[?1006h");
            try tt.expect(h.e.modes().mouse);
            try tt.expect(try h.e.encodeMouse(.{ .action = .press, .button = .left, .col = 2, .row = 3 }, &aw.writer));
            try tt.expect(try h.e.encodeMouse(.{ .action = .release, .button = .left, .col = 2, .row = 3 }, &aw.writer));
            try tt.expect(try h.e.encodeMouse(.{ .action = .press, .button = .wheel_up, .col = 0, .row = 0, .mods = .{ .ctrl = true } }, &aw.writer));
            // Normal tracking doesn't report plain motion, but the event
            // still belongs to the program.
            try tt.expect(try h.e.encodeMouse(.{ .action = .move, .col = 5, .row = 5 }, &aw.writer));
            try tt.expectEqualStrings("\x1b[<0;3;4M\x1b[<0;3;4m\x1b[<80;1;1M", aw.written());
        }
    }
}

test "paste and focus" {
    inline for (engines) |T| {
        var h: Harness(T) = try .init(.{});
        defer h.deinit();
        var aw: Writer.Allocating = .init(tt.allocator);
        defer aw.deinit();
        try h.e.encodePaste("ls\nrm", &aw.writer);
        try tt.expectEqualStrings("ls\rrm", aw.written());
        aw.clearRetainingCapacity();
        try h.e.encodeFocus(true, &aw.writer);
        try tt.expectEqualStrings("", aw.written());
        {
            try h.e.feed("\x1b[?2004h\x1b[?1004h");
            try tt.expect(h.e.modes().bracketed_paste and h.e.modes().focus_reports);
            try h.e.encodePaste("ls\nrm", &aw.writer);
            try tt.expectEqualStrings("\x1b[200~ls\nrm\x1b[201~", aw.written());
            aw.clearRetainingCapacity();
            try h.e.encodeFocus(true, &aw.writer);
            try h.e.encodeFocus(false, &aw.writer);
            try tt.expectEqualStrings("\x1b[I\x1b[O", aw.written());
        }
    }
}

test "events: bell, title, cwd, OSC 52" {
    inline for (engines) |T| {
        var h: Harness(T) = try .init(.{});
        defer h.deinit();
        try h.e.feed("a\x07\x07");
        try h.e.takeEvents(&h.ev);
        try tt.expectEqual(@as(u32, 2), h.ev.bell);
        try h.e.takeEvents(&h.ev);
        try tt.expect(!h.ev.any());
        // OSC 52, which the stand-in keeps too.
        try h.e.feed("\x1b]52;c;aGVsbG8=\x07\x1b]52;c;?\x07");
        try h.e.takeEvents(&h.ev);
        try tt.expectEqual(@as(usize, 1), h.ev.clips.items.len);
        try tt.expectEqual(@as(u8, 'c'), h.ev.clips.items[0].target);
        try tt.expectEqualStrings("hello", h.ev.str(h.ev.clips.items[0].data));
        try h.e.takeEvents(&h.ev);
        try tt.expect(!h.ev.any());
        if (!isPlain(T)) {
            try h.e.feed("\x1b]0;first\x07\x1b]2;my title\x1b\\\x1b]7;file://host/tmp/x\x07");
            try h.e.takeEvents(&h.ev);
            try tt.expectEqualStrings("my title", h.ev.str(h.ev.title.?));
            try tt.expectEqualStrings("file://host/tmp/x", h.ev.str(h.ev.cwd.?));
            try h.e.takeEvents(&h.ev);
            try tt.expect(!h.ev.any());
            // A device attributes query is answered.
            try h.e.feed("\x1b[c");
            try h.e.takeEvents(&h.ev);
            try tt.expect(std.mem.startsWith(u8, h.ev.str(h.ev.reply.?), "\x1b[?"));
        }
    }
}

test "dirty rows, cursor, size, styles" {
    inline for (engines) |T| {
        var h: Harness(T) = try .init(.{ .cols = 10, .rows = 3 });
        defer h.deinit();
        try h.e.takeDirty(&h.dirty);
        try tt.expect(h.dirty.all and h.dirty.cursor);
        try h.e.takeDirty(&h.dirty);
        try tt.expect(!h.dirty.any());
        try h.e.feed("\r\nx");
        try h.e.takeDirty(&h.dirty);
        // Row 1 changed. An engine may list the row the cursor left too.
        try tt.expect(!h.dirty.all);
        try tt.expect(std.mem.indexOfScalar(u16, h.dirty.rows.items, 1) != null);
        try tt.expect(std.mem.indexOfScalar(u16, h.dirty.rows.items, 2) == null);
        try tt.expect(h.dirty.cursor and h.dirty.styles == .same);
        try h.e.resize(.{ .cols = 5, .rows = 2, .cell_w_px = 8, .cell_h_px = 16 });
        try h.e.takeDirty(&h.dirty);
        try tt.expect(h.dirty.all and h.dirty.size);
        try tt.expectEqual(engine.Size{ .cols = 5, .rows = 2, .cell_w_px = 8, .cell_h_px = 16 }, h.e.size());
        try tt.expect(h.e.styles()[0].eql(.{}));
        if (!isPlain(T)) {
            try h.e.takeDirty(&h.dirty);
            try h.e.feed("\x1b[31;1mR\x1b[0m");
            try h.e.takeDirty(&h.dirty);
            try tt.expectEqual(engine.StylesChange.grew, h.dirty.styles);
            const st = try h.styleAt(1, 1);
            try tt.expect(st.flags.bold and st.fg != 0 and st.bg == 0);
            // The same style again reuses its id.
            const n = h.e.styles().len;
            try h.e.feed("\x1b[31;1mS\x1b[0m");
            try h.e.takeDirty(&h.dirty);
            try tt.expectEqual(engine.StylesChange.same, h.dirty.styles);
            try tt.expectEqual(n, h.e.styles().len);
            // True color resolves to RGBA as given.
            try h.e.feed("\r\n\x1b[38;2;255;128;0;48;2;1;2;3mo\x1b[m");
            const o = try h.styleAt(1, 0);
            try tt.expectEqual(@as(u32, 0xff8000ff), o.fg);
            try tt.expectEqual(@as(u32, 0x010203ff), o.bg);
        }
    }
}

test "wide characters span two cells but are one character" {
    inline for (engines) |T| if (!isPlain(T)) {
        var h: Harness(T) = try .init(.{ .cols = 10, .rows = 2 });
        defer h.deinit();
        try h.e.feed("a中b");
        try h.expectScreen("a中b\n");
        try h.e.row(0, &h.row);
        try tt.expectEqual(@as(usize, 1), h.row.runs.items.len);
        try tt.expectEqual(@as(u16, 4), h.row.runs.items[0].width);
        try tt.expectEqualStrings("a中b", h.row.runText(h.row.runs.items[0]));
        try tt.expectEqual(@as(u16, 4), h.e.cursor().x);
    };
}

test "cursor shape and visibility" {
    inline for (engines) |T| if (!isPlain(T)) {
        var h: Harness(T) = try .init(.{});
        defer h.deinit();
        try h.e.feed("\x1b[6 q\x1b[3;5H");
        var cur = h.e.cursor();
        try tt.expectEqual(engine.CursorShape.bar, cur.shape);
        try tt.expectEqual(@as(u16, 4), cur.x);
        try tt.expectEqual(@as(u16, 2), cur.y);
        try h.e.feed("\x1b[?25l");
        try tt.expect(!h.e.cursor().visible);
        try h.e.feed("\x1b[?25h\x1b[4 q");
        cur = h.e.cursor();
        try tt.expect(cur.visible);
        try tt.expectEqual(engine.CursorShape.underline, cur.shape);
    };
}

test "reset clears screen, history and modes" {
    inline for (engines) |T| {
        var h: Harness(T) = try .init(.{ .cols = 10, .rows = 2 });
        defer h.deinit();
        try h.e.feed("a\r\nb\r\nc\x1b[?2004h");
        h.e.reset();
        try h.expectScreen("");
        try tt.expectEqual(@as(u16, 0), h.e.cursor().x);
        try tt.expect(!h.e.modes().bracketed_paste);
        h.e.scroll(.top);
        try h.expectScreen("");
        try h.e.takeDirty(&h.dirty);
        try tt.expect(h.dirty.all);
    }
}

test "the stand-in's modes: X10 reports, button and any-event tracking, paste end markers" {
    var p = try Plain.init(tt.allocator, .{});
    defer p.deinit();
    var aw: Writer.Allocating = .init(tt.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    // X10 bytes without 1006: release is button 3.
    try p.feed("\x1b[?1000h");
    try tt.expect(try p.encodeMouse(.{ .action = .press, .button = .left, .col = 0, .row = 1 }, w));
    try tt.expect(try p.encodeMouse(.{ .action = .release, .button = .left, .col = 0, .row = 1 }, w));
    try tt.expectEqualStrings("\x1b[M !\"\x1b[M#!\"", aw.written());
    aw.clearRetainingCapacity();
    // 1002 reports drags; 1003 every move.
    try p.feed("\x1b[?1002;1006h");
    try tt.expect(try p.encodeMouse(.{ .action = .move, .col = 1, .row = 1 }, w));
    try tt.expect(try p.encodeMouse(.{ .action = .move, .button = .right, .col = 1, .row = 1 }, w));
    try p.feed("\x1b[?1003h");
    try tt.expect(try p.encodeMouse(.{ .action = .move, .col = 2, .row = 1, .mods = .{ .shift = true } }, w));
    try tt.expectEqualStrings("\x1b[<34;2;2M\x1b[<39;3;2M", aw.written());
    aw.clearRetainingCapacity();
    try p.feed("\x1b[?1003l");
    try tt.expect(!try p.encodeMouse(.{ .action = .press, .button = .left, .col = 0, .row = 0 }, w));
    // A paste can't end the bracket early.
    try p.feed("\x1b[?2004h");
    try p.encodePaste("a\x1b[201~b", w);
    try tt.expectEqualStrings("\x1b[200~ab\x1b[201~", aw.written());
}
