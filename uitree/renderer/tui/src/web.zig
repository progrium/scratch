//! uitree-tui.wasm: the terminal host in the browser (uitree/web/README.md).
//!
//! The same Ui, grid and core as main.zig, but the page owns the terminal
//! (xterm.js) and the event loop: it calls these exports for input and on
//! the core's wake, and gets each frame as ANSI text through `term.write`.
//! There's no libvaxis Tty or Loop here (no tty, no threads): frames are
//! written as whole-screen SGR text, which xterm.js parses. The app runs
//! in h9's own Worker, which the core's platform starts when the page
//! calls uit_run_machine (web/uit-web.js's runApp).

const std = @import("std");
const types = @import("types");
const c = @import("c");
const core = @import("core.zig");
const source = @import("source.zig");
const uimod = @import("ui.zig");
const gridmod = @import("grid.zig");

pub const std_options: std.Options = .{ .log_level = .warn };

extern "tui" fn write(p: [*]const u8, n: usize) void;
extern "tui" fn wake() void;
extern "tui" fn title(p: [*]const u8, n: usize) void;
extern "tui" fn tip_timer(gen: u32, ms: u32) void;

const gpa = std.heap.c_allocator;

var k: core.Core = undefined;
var ui: uimod.Ui = undefined;
var grid: ?gridmod.Grid = null;
var started = false;
var first = true;
var out: std.Io.Writer.Allocating = undefined;
var out_ready = false;

fn onWake(_: ?*anyopaque) callconv(.c) void {
    wake();
}

/// Creates the core and the Ui. Returns the UitCore for the page's
/// runApp (uit_run_machine), or 0.
export fn tui_init(cols: u16, rows: u16, dark: bool) usize {
    k = core.Core.create(.{
        .types = types.descriptors,
        .style_words = types.style_words,
        .theme_tokens = types.theme_tokens,
        .system_dark = dark,
        .wake = onWake,
        .wake_ctx = null,
    }) catch return 0;
    k.themes(types.themes) catch return 0;
    ui = uimod.Ui.init(gpa, source.fromCore(k));
    grid = gridmod.Grid.init(gpa, cols, rows) catch return 0;
    started = true;
    return @intFromPtr(k.p);
}

export fn tui_resize(cols: u16, rows: u16) void {
    if (!started) return;
    if (grid) |*g| g.deinit(gpa);
    grid = gridmod.Grid.init(gpa, cols, rows) catch null;
    redraw(true);
}

/// The core's wake: one pump.
export fn tui_pump() i32 {
    if (!started) return -1;
    const ch = k.pump() catch return -1;
    for (many(core.HostCmd, ch.cmds, ch.n_cmds)) |cmd| switch (cmd.tag) {
        c.UIT_CMD_WINDOW => if (std.mem.eql(u8, core.slice(cmd.win), "main")) {
            ui.shown = true;
        },
        c.UIT_CMD_FOCUS => if (cmd.node != 0) ui.focus(cmd.node),
        else => {},
    };
    for (many(c.UitPropChange, ch.props, ch.n_props)) |p| ui.propChanged(p.node, core.slice(p.file));
    for (many(core.Node, ch.removed, ch.n_removed)) |n| ui.removed(n);
    // Every input call wakes the core, uit_frame_drawn included, so a
    // pump that changed nothing mustn't draw (and call it) again: main.zig
    // does, and spins at a pump per frame while idle.
    const changed = ch.n_dirty + ch.n_created + ch.n_removed + ch.n_props + ch.n_cmds > 0 or first;
    first = false;
    if (changed) redraw(false);
    return if (ch.exited != 0) 1 else 0;
}

var name_buf: [64]u8 = undefined;
var text_buf: [64]u8 = undefined;

/// A key, as main.zig's translateKey makes it. mods: 1 ctrl, 2 alt,
/// 4 shift, 8 super. Returns 1 if the page should close the window.
export fn tui_key(np: [*]const u8, nn: usize, tp: [*]const u8, tn: usize, mods: u32) i32 {
    if (!started) return 0;
    const r = ui.onKey(.{
        .name = np[0..@min(nn, name_buf.len)],
        .text = tp[0..@min(tn, text_buf.len)],
        .ctrl = mods & 1 != 0,
        .alt = mods & 2 != 0,
        .shift = mods & 4 != 0,
        .super = mods & 8 != 0,
    });
    if (r == .quit) {
        k.windowClosed("main");
        return 1;
    }
    redraw(false);
    return 0;
}

/// kind: 0 press, 1 release, 2 motion, 3 drag, 4 wheel up, 5 wheel down.
export fn tui_mouse(x: i32, y: i32, kind: u32) void {
    if (!started) return;
    const kd: @FieldType(uimod.Ui.Mouse, "kind") = switch (kind) {
        0 => .press,
        1 => .release,
        2 => .motion,
        3 => .drag,
        4 => .wheel_up,
        else => .wheel_down,
    };
    const changed = ui.onMouse(.{ .x = x, .y = y, .kind = kd });
    if (ui.tipPending()) |gen| tip_timer(gen, uimod.tip_delay_ms);
    if (changed) redraw(false);
}

export fn tui_tip(gen: u32) void {
    if (started and ui.tipDue(gen)) redraw(false);
}

/// A scratch buffer for the page to pass key names in.
export fn tui_buf() [*]u8 {
    return &name_buf;
}
export fn tui_buf2() [*]u8 {
    return &text_buf;
}

fn redraw(_: bool) void {
    const g = &(grid orelse return);
    const root = k.windowRoot("main");
    if (root != 0) if (k.prop(root, "title")) |t| {
        ui.title = std.mem.trimEnd(u8, t, "\n");
        title(ui.title.ptr, ui.title.len);
    };
    ui.frame(g) catch return;
    emit(g) catch return;
    const b = out.written();
    write(b.ptr, b.len);
    k.frameDrawn("main");
}

/// The whole grid as ANSI: home, then each row with 24-bit SGR runs.
fn emit(g: *const gridmod.Grid) !void {
    if (!out_ready) {
        out = .init(gpa);
        out_ready = true;
    }
    out.clearRetainingCapacity();
    const w = &out.writer;
    try w.writeAll("\x1b[?25l\x1b[H");
    var last: ?gridmod.Cell = null;
    var y: u16 = 0;
    while (y < g.h) : (y += 1) {
        if (y > 0) try w.print("\x1b[{d};1H", .{y + 1});
        var x: u16 = 0;
        while (x < g.w) : (x += 1) {
            const cell = g.cells[@as(usize, y) * g.w + x];
            if (cell.ch.len == 0) continue; // right half of a wide glyph
            if (last == null or !sameStyle(last.?, cell)) {
                const a = cell.attrs;
                try w.print("\x1b[0;38;2;{d};{d};{d};48;2;{d};{d};{d}", .{
                    (cell.fg >> 16) & 0xff, (cell.fg >> 8) & 0xff, cell.fg & 0xff,
                    (cell.bg >> 16) & 0xff, (cell.bg >> 8) & 0xff, cell.bg & 0xff,
                });
                if (a.bold) try w.writeAll(";1");
                if (a.dim) try w.writeAll(";2");
                if (a.italic) try w.writeAll(";3");
                if (a.underline) try w.writeAll(";4");
                if (a.reverse) try w.writeAll(";7");
                if (a.strike) try w.writeAll(";9");
                try w.writeAll("m");
                last = cell;
            }
            try w.writeAll(cell.ch);
        }
    }
    try w.writeAll("\x1b[0m");
    if (g.cursor) |cur| try w.print("\x1b[{d};{d}H\x1b[5 q\x1b[?25h", .{ cur.y + 1, cur.x + 1 });
}

fn sameStyle(a: gridmod.Cell, b: gridmod.Cell) bool {
    return a.fg == b.fg and a.bg == b.bg and @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
}

fn many(comptime T: type, p: [*c]const T, n: usize) []const T {
    if (n == 0 or p == null) return &.{};
    return p[0..n];
}
