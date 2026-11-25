//! C4, the render stream's terminal records and input lines
//! (protocols/render.md § Terminals): the spelling, written and read here
//! so the encoder (stream.zig), the replica (replica.zig) and the input
//! parser agree. They carry what the C ABI's uit_term_* calls carry, in the
//! same structs.
//!
//! Owner: the terminal contracts (T1). Frozen: a change is a PR here, to
//! render.md and to render/tests.zig's golden, announced to the tree (T3)
//! and renderer (T4, T5) work. T3 calls these from the encoder and replica.
//!
//! Records, in a snapshot after the node's `new` line and in a batch after
//! the order fixes, before the host commands:
//!
//!     term PATH cols=C rows=R cursor=X,Y shape=S visible=on|off blink=on|off
//!     term-styles PATH first=N text=<<END
//!     FG BG UL [bold faint italic inverse strike blink invisible overline] [underline=K]
//!     END
//!     term-rows PATH text=<<END
//!     Y [COL:STYLE:WIDTH[:sel] TEXT]...
//!     END
//!
//! Input lines, as uit_term_resize, uit_term_mouse, uit_term_scroll,
//! uit_term_text and uit_term_paste (`term-resize` is primary-only):
//!
//!     term-resize win=W node=PATH cols=C rows=R cw=PX ch=PX
//!     term-mouse win=W node=PATH action=press|release|move button=none|left|middle|right col=C row=R [mods=shift,alt,ctrl,super] [clicks=N]
//!     term-scroll win=W node=PATH lines=N
//!     term-text win=W node=PATH text=V
//!     term-paste win=W node=PATH text=V

const std = @import("std");
const abi = @import("../abi.zig");
const tokenize = @import("../proto/tokenize.zig");
const ctl = @import("../proto/ctl.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Error = error{ BadSyntax, OutOfMemory };

const shapes = [_][]const u8{ "block", "bar", "underline", "block-hollow" };
const flag_words = [_][]const u8{ "bold", "faint", "italic", "inverse", "strike", "blink", "invisible", "overline" };
const underlines = [_][]const u8{ "none", "single", "double", "curly", "dotted", "dashed" };
const actions = [_][]const u8{ "press", "release", "move" };
const buttons = [_][]const u8{ "none", "left", "middle", "right" };
const mod_words = [_][]const u8{ "shift", "alt", "ctrl", "super" };

fn onOff(b: bool) []const u8 {
    return if (b) "on" else "off";
}

fn indexOf(list: []const []const u8, s: []const u8) ?u32 {
    for (list, 0..) |x, i| if (std.mem.eql(u8, x, s)) return @intCast(i);
    return null;
}

// ---------------------------------------------------------------- records

/// `term PATH ...`: the grid's size and the cursor. Sent with the node's
/// `new` and whenever either changes.
pub fn writeTerm(w: *Writer, path: []const u8, c: abi.UitTermCursor) Writer.Error!void {
    try w.writeAll("term ");
    try tokenize.quoteWord(w, path);
    try w.print(" cols={d} rows={d} cursor={d},{d} shape={s} visible={s} blink={s}\n", .{
        c.cols,                                                 c.rows,                c.x,                 c.y,
        if (c.shape < shapes.len) shapes[c.shape] else "block", onOff(c.visible != 0), onOff(c.blink != 0),
    });
}

/// `term-styles PATH first=N`: style ids `first` and up. `first=0` replaces
/// the table (a snapshot, or UIT_TERM_STYLES_RESET); otherwise the entries
/// are appended. Nothing is written for no styles.
pub fn writeStyles(w: *Writer, path: []const u8, first: u32, styles: []const abi.UitTermStyle) Writer.Error!void {
    if (styles.len == 0) return;
    try w.writeAll("term-styles ");
    try tokenize.quoteWord(w, path);
    try w.print(" first={d} text=<<END\n", .{first});
    for (styles) |s| try writeStyleLine(w, s);
    try w.writeAll("END\n");
}

fn writeColor(w: *Writer, c: u32) Writer.Error!void {
    if (c == 0) return w.writeByte('-');
    try w.print("#{x:0>8}", .{c});
}

pub fn writeStyleLine(w: *Writer, s: abi.UitTermStyle) Writer.Error!void {
    try writeColor(w, s.fg);
    try w.writeByte(' ');
    try writeColor(w, s.bg);
    try w.writeByte(' ');
    try writeColor(w, s.underline_color);
    for (flag_words, 0..) |f, i| if (s.flags & (@as(u32, 1) << @intCast(i)) != 0) try w.print(" {s}", .{f});
    if (s.underline != 0 and s.underline < underlines.len) try w.print(" underline={s}", .{underlines[s.underline]});
    try w.writeByte('\n');
}

/// `term-rows PATH`: one line per row, its runs as `COL:STYLE:WIDTH` (and
/// `:sel` inside the selection) followed by the text, quoted as a word. A
/// row with no runs is blank. A batch lists every row it changed; a
/// snapshot leaves out blank rows. Nothing is written for no rows.
pub fn writeRows(w: *Writer, path: []const u8, rows: []const abi.UitTermRow) Writer.Error!void {
    if (rows.len == 0) return;
    try w.writeAll("term-rows ");
    try tokenize.quoteWord(w, path);
    try w.writeAll(" text=<<END\n");
    for (rows) |r| try writeRowLine(w, r);
    try w.writeAll("END\n");
}

pub fn writeRowLine(w: *Writer, r: abi.UitTermRow) Writer.Error!void {
    try w.print("{d}", .{r.y});
    const runs: []const abi.UitTermRun = if (r.runs) |p| p[0..r.n_runs] else &.{};
    for (runs) |run| {
        try w.print(" {d}:{d}:{d}{s} ", .{ run.col, run.style, run.width, if (run.selected != 0) ":sel" else "" });
        try tokenize.quoteWord(w, run.text.slice());
    }
    try w.writeByte('\n');
}

fn parseColor(s: []const u8) Error!u32 {
    if (std.mem.eql(u8, s, "-")) return 0;
    if (s.len != 9 or s[0] != '#') return error.BadSyntax;
    return std.fmt.parseInt(u32, s[1..], 16) catch error.BadSyntax;
}

/// One line of a `term-styles` body.
pub fn parseStyleLine(line: []const u8) Error!abi.UitTermStyle {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    var s: abi.UitTermStyle = .{
        .fg = try parseColor(it.next() orelse return error.BadSyntax),
        .bg = try parseColor(it.next() orelse return error.BadSyntax),
        .underline_color = try parseColor(it.next() orelse return error.BadSyntax),
    };
    while (it.next()) |word| {
        if (std.mem.startsWith(u8, word, "underline=")) {
            s.underline = indexOf(&underlines, word["underline=".len..]) orelse return error.BadSyntax;
        } else if (indexOf(&flag_words, word)) |i| {
            s.flags |= @as(u32, 1) << @intCast(i);
        }
        // Any other word is from a newer spelling: ignored.
    }
    return s;
}

/// One line of a `term-rows` body. Run text is allocated in `arena`.
pub fn parseRowLine(arena: Allocator, line: []const u8) Error!abi.UitTermRow {
    const toks = tokenize.tokenize(arena, line) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnterminatedQuote => error.BadSyntax,
    };
    if (toks.len == 0 or toks.len % 2 != 1) return error.BadSyntax;
    const y = std.fmt.parseInt(u32, toks[0].text, 10) catch return error.BadSyntax;
    const runs = try arena.alloc(abi.UitTermRun, toks.len / 2);
    for (runs, 0..) |*run, i| {
        var f = std.mem.splitScalar(u8, toks[1 + 2 * i].text, ':');
        run.* = .{
            .col = std.fmt.parseInt(u32, f.next() orelse return error.BadSyntax, 10) catch return error.BadSyntax,
            .style = std.fmt.parseInt(u32, f.next() orelse return error.BadSyntax, 10) catch return error.BadSyntax,
            .width = std.fmt.parseInt(u32, f.next() orelse return error.BadSyntax, 10) catch return error.BadSyntax,
            .text = abi.UitStr.of(toks[2 + 2 * i].text),
        };
        if (f.next()) |x| run.selected = @intFromBool(std.mem.eql(u8, x, "sel"));
    }
    return .{ .y = y, .runs = if (runs.len > 0) runs.ptr else null, .n_runs = runs.len };
}

/// A `term` record's attributes, from a parsed line.
pub fn parseTerm(c: ctl.Ctl) Error!abi.UitTermCursor {
    var cur: abi.UitTermCursor = .{
        .cols = try num(u32, c.attr("cols")),
        .rows = try num(u32, c.attr("rows")),
        .visible = @intFromBool(!std.mem.eql(u8, c.attr("visible") orelse "on", "off")),
        .blink = @intFromBool(std.mem.eql(u8, c.attr("blink") orelse "off", "on")),
    };
    if (c.attr("cursor")) |xy| {
        const comma = std.mem.indexOfScalar(u8, xy, ',') orelse return error.BadSyntax;
        cur.x = try num(u32, xy[0..comma]);
        cur.y = try num(u32, xy[comma + 1 ..]);
    }
    if (c.attr("shape")) |s| cur.shape = indexOf(&shapes, s) orelse 0;
    return cur;
}

fn num(comptime T: type, s: ?[]const u8) Error!T {
    return std.fmt.parseInt(T, s orelse return error.BadSyntax, 10) catch error.BadSyntax;
}

// ---------------------------------------------------------------- input

pub const Input = union(enum) {
    resize: struct { win: []const u8, node: []const u8, cols: u32, rows: u32, cell_w_px: u32 = 0, cell_h_px: u32 = 0 },
    mouse: struct { win: []const u8, node: []const u8, m: abi.UitTermMouse },
    scroll: struct { win: []const u8, node: []const u8, lines: i32 },
    text: struct { win: []const u8, node: []const u8, text: []const u8 },
    paste: struct { win: []const u8, node: []const u8, text: []const u8 },
};

fn writeTarget(w: *Writer, verb: []const u8, win: []const u8, node: []const u8) Writer.Error!void {
    try w.print("{s} win=", .{verb});
    try tokenize.quoteValue(w, win);
    try w.writeAll(" node=");
    try tokenize.quoteValue(w, node);
}

/// One input line, with its newline. `term-text` with a newline in it is a
/// here-value.
pub fn writeInput(w: *Writer, in: Input) Writer.Error!void {
    switch (in) {
        .resize => |r| {
            try writeTarget(w, "term-resize", r.win, r.node);
            try w.print(" cols={d} rows={d} cw={d} ch={d}\n", .{ r.cols, r.rows, r.cell_w_px, r.cell_h_px });
        },
        .mouse => |x| {
            try writeTarget(w, "term-mouse", x.win, x.node);
            const m = x.m;
            try w.print(" action={s} button={s} col={d} row={d}", .{
                if (m.action < actions.len) actions[m.action] else "move",
                if (m.button < buttons.len) buttons[m.button] else "none",
                m.col,
                m.row,
            });
            if (m.mods != 0) {
                try w.writeAll(" mods=");
                var first = true;
                for (mod_words, 0..) |name, i| if (m.mods & (@as(u32, 1) << @intCast(i)) != 0) {
                    if (!first) try w.writeByte(',');
                    try w.writeAll(name);
                    first = false;
                };
            }
            if (m.clicks > 1) try w.print(" clicks={d}", .{m.clicks});
            try w.writeByte('\n');
        },
        .scroll => |s| {
            try writeTarget(w, "term-scroll", s.win, s.node);
            try w.print(" lines={d}\n", .{s.lines});
        },
        inline .text, .paste => |t, tag| {
            try writeTarget(w, if (tag == .text) "term-text" else "term-paste", t.win, t.node);
            if (ctl.hasNewline(t.text)) {
                var buf: [24]u8 = undefined;
                const m = ctl.markerFor(&buf, t.text, 0);
                try w.print(" text=<<{s}", .{m});
                try ctl.writeBody(w, t.text, m);
            } else {
                try w.writeAll(" text=");
                try tokenize.quoteValue(w, t.text);
            }
            try w.writeByte('\n');
        },
    }
}

/// A `term-*` input line, parsed by the caller (here-values read). Null for
/// any other verb.
pub fn parseInput(c: ctl.Ctl) Error!?Input {
    const win = c.attr("win") orelse "";
    const node = c.attr("node") orelse "";
    if (std.mem.eql(u8, c.verb, "term-resize")) return .{ .resize = .{
        .win = win,
        .node = node,
        .cols = try num(u32, c.attr("cols")),
        .rows = try num(u32, c.attr("rows")),
        .cell_w_px = try num(u32, c.attr("cw") orelse "0"),
        .cell_h_px = try num(u32, c.attr("ch") orelse "0"),
    } };
    if (std.mem.eql(u8, c.verb, "term-mouse")) {
        var m: abi.UitTermMouse = .{
            .action = indexOf(&actions, c.attr("action") orelse return error.BadSyntax) orelse return error.BadSyntax,
            .button = indexOf(&buttons, c.attr("button") orelse "none") orelse return error.BadSyntax,
            .col = try num(u32, c.attr("col")),
            .row = try num(u32, c.attr("row")),
            .clicks = try num(u32, c.attr("clicks") orelse "1"),
        };
        if (c.attr("mods")) |ms| {
            var it = std.mem.tokenizeScalar(u8, ms, ',');
            while (it.next()) |name| m.mods |= @as(u32, 1) << @intCast(indexOf(&mod_words, name) orelse return error.BadSyntax);
        }
        return .{ .mouse = .{ .win = win, .node = node, .m = m } };
    }
    if (std.mem.eql(u8, c.verb, "term-scroll")) return .{ .scroll = .{ .win = win, .node = node, .lines = try num(i32, c.attr("lines")) } };
    if (std.mem.eql(u8, c.verb, "term-text")) return .{ .text = .{ .win = win, .node = node, .text = c.attr("text") orelse "" } };
    if (std.mem.eql(u8, c.verb, "term-paste")) return .{ .paste = .{ .win = win, .node = node, .text = c.attr("text") orelse "" } };
    return null;
}
