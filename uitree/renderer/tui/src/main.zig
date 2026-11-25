//! uitree-tui: the uitree terminal host.
//!
//!     uitree-tui [-t TITLE] [--root DIR] [-d SRC[:DST]]... [-e NAME=VALUE]... [--log FILE] [--dark] [--colors truecolor|256|16] PROG [ARGS...]
//!     uitree-tui [-t TITLE] [--log FILE] [--dark] [--colors ...] --remote ADDR [--role primary|mirror|view]
//!
//! Starts the core (libuitcore, through uitcore.h), runs PROG in h9 with
//! $ui mounted, and draws the app's `main` window in the terminal with
//! libvaxis. Ctrl-C or Ctrl-Q closes the window. The app's own output and
//! the core's log go to --log (default /tmp/uitree-tui.log), not the
//! screen.
//!
//! --root is the 9front root for h9 (default $H9ROOT, else h9's built-in
//! root). -d adds an h9 mount: -d ALPINE:#L gives the app a Linux view,
//! where $ui is /9/mnt/ui. -e sets a variable in the app's environment.
//! --colors is the terminal's color depth (color.zig; default from
//! $COLORTERM). The host registers GPUI Kit's theme set (core/types/themes),
//! so an app's `theme/name` works here as on GPUI.
//!
//! --remote draws an app running elsewhere instead: it dials the renderer
//! tree (protocols/render.md) that `uitree-remote -R ADDR`, or a GPUI host
//! with UITREE_RENDER_LISTEN, serves at ADDR, as a 9P client. The core does
//! that (uit_render_dial), so the drawing code is the same either way.
//! --role defaults to primary, which a host that draws itself refuses: use
//! mirror there.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const types = @import("types");
const core = @import("core.zig");
const source = @import("source.zig");
const uimod = @import("ui.zig");
const gridmod = @import("grid.zig");
const colormod = @import("color.zig");

pub const panic = vaxis.panic_handler;

pub const std_options: std.Options = .{ .log_level = .warn };

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    /// A bracketed paste: its keys arrive between these.
    paste_start,
    paste_end,
    /// The core queued ops: pump.
    wake,
    /// A `tooltip` file's delay ran out (Ui.tipDue).
    tip: u32,
};

/// Sleeps the tip delay on its own thread, then posts `.tip`.
fn tipTimer(loop: *vaxis.Loop(Event), io: std.Io, gen: u32) void {
    io.sleep(.fromMilliseconds(uimod.tip_delay_ms), .awake) catch return;
    _ = loop.tryPostEvent(.{ .tip = gen }) catch {};
}

const App = struct {
    loop: *vaxis.Loop(Event),
    pending: std.atomic.Value(bool) = .init(false),

    fn wake(ctx: ?*anyopaque) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        // One queued wake is enough: the pump drains everything.
        if (app.pending.swap(true, .acq_rel)) return;
        _ = app.loop.tryPostEvent(.wake) catch {};
    }
};

const usage =
    \\usage: uitree-tui [-t TITLE] [--root DIR] [-d SRC[:DST]] [-e NAME=VALUE] [--log FILE] [--dark] [--colors truecolor|256|16] PROG [ARGS...]
    \\       uitree-tui [-t TITLE] [--log FILE] [--dark] [--colors ...] --remote ADDR [--role primary|mirror|view]
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var title: []const u8 = "";
    var root: []const u8 = init.environ_map.get("H9ROOT") orelse "";
    var log_path: []const u8 = "/tmp/uitree-tui.log";
    var dark = false;
    var depth = colormod.detect(init.environ_map.get("COLORTERM"));
    var remote: ?[]const u8 = null;
    var role: []const u8 = "primary";
    var dirs: std.ArrayList([]const u8) = .empty;
    var env: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-t") and i + 1 < args.len) {
            i += 1;
            title = args[i];
        } else if (std.mem.eql(u8, a, "--root") and i + 1 < args.len) {
            i += 1;
            root = args[i];
        } else if ((std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--dir")) and i + 1 < args.len) {
            i += 1;
            try dirs.append(init.arena.allocator(), args[i]);
        } else if ((std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--env")) and i + 1 < args.len) {
            i += 1;
            try env.append(init.arena.allocator(), args[i]);
        } else if (std.mem.eql(u8, a, "--log") and i + 1 < args.len) {
            i += 1;
            log_path = args[i];
        } else if (std.mem.eql(u8, a, "--remote") and i + 1 < args.len) {
            i += 1;
            remote = args[i];
        } else if (std.mem.eql(u8, a, "--role") and i + 1 < args.len) {
            i += 1;
            role = args[i];
        } else if (std.mem.eql(u8, a, "--dark")) {
            dark = true;
        } else if (std.mem.eql(u8, a, "--colors") and i + 1 < args.len) {
            i += 1;
            depth = colormod.parse(args[i]) orelse {
                std.debug.print("{s}", .{usage});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else break;
    }
    if (i >= args.len and remote == null) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const argv: []const []const u8 = @ptrCast(args[i..]);

    if (core.Core.abiVersion() != @import("c").UIT_ABI_VERSION) {
        std.debug.print("uitree-tui: libuitcore is ABI {d}, this host wants {d}\n", .{ core.Core.abiVersion(), @import("c").UIT_ABI_VERSION });
        return 1;
    }

    // The app's output and every log line go to the log file: the
    // terminal belongs to the UI.
    const log_fd = openLog(log_path);

    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();
    const writer = tty.writer();
    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, tty.writer());
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    var app: App = .{ .loop = &loop };

    const k = core.Core.create(.{
        .types = types.descriptors,
        .style_words = types.style_words,
        .theme_tokens = types.theme_tokens,
        .system_dark = dark,
        .wake = App.wake,
        .wake_ctx = &app,
    }) catch |e| {
        std.debug.print("uitree-tui: uit_create: {t}\n", .{e});
        return 1;
    };
    defer k.destroy();
    k.themes(types.themes) catch |e| {
        std.debug.print("uitree-tui: uit_themes: {t} {s}\n", .{ e, k.lastError() });
        return 1;
    };

    var ui = uimod.Ui.init(gpa, source.fromCore(k));
    defer ui.deinit();
    ui.title = title;

    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(writer);
    try vx.queryTerminal(writer, .fromSeconds(1));
    // A terminal without in-band resize reports a new size with SIGWINCH
    // only: without this handler the window never resized there (xterm,
    // tmux 3.4).
    const signal_resize = !vx.state.in_band_resize;
    if (signal_resize) try loop.installResizeHandler();
    defer if (signal_resize) loop.uninstallResizeHandler();
    try vx.setMouseMode(writer, true);
    // Pastes arrive bracketed, so a terminal node gets them whole.
    try vx.setBracketedPaste(writer, true);
    if (log_fd >= 0) redirectStderr(log_fd);

    if (remote) |addr| k.renderDial(addr, "uitree-tui", role) catch |e| {
        exitUi(&vx, writer);
        std.debug.print("uitree-tui: {s}: {t} {s}\n", .{ addr, e, k.lastError() });
        return 1;
    } else k.runMachine(gpa, .{ .argv = argv, .root = root, .dirs = dirs.items, .env = env.items, .out_fd = log_fd, .err_fd = log_fd }) catch |e| {
        exitUi(&vx, writer);
        std.debug.print("uitree-tui: {s}: {t} {s}\n", .{ argv[0], e, k.lastError() });
        return 1;
    };

    var grid: ?gridmod.Grid = null;
    defer if (grid) |*g| g.deinit(gpa);
    var clicks: Clicks = .{};
    // The text of a bracketed paste in progress, null outside one.
    var pasting: ?std.ArrayList(u8) = null;
    defer if (pasting) |*b| b.deinit(gpa);
    var status: u8 = 0;
    var exit_text: []const u8 = "";
    var exit_buf: [256]u8 = undefined;

    main: while (true) {
        var ev = try loop.nextEvent();
        var redraw = false;
        while (true) {
            switch (ev) {
                .winsize => |ws| {
                    try vx.resize(gpa, writer, ws);
                    if (grid) |*g| g.deinit(gpa);
                    grid = try gridmod.Grid.init(gpa, ws.cols, ws.rows);
                    // A terminal node tells its program the cell's size
                    // in pixels, when the terminal reports one.
                    ui.cell_px = if (ws.cols > 0 and ws.rows > 0 and ws.x_pixel > 0 and ws.y_pixel > 0)
                        .{ ws.x_pixel / ws.cols, ws.y_pixel / ws.rows }
                    else
                        .{ 0, 0 };
                    redraw = true;
                },
                .paste_start => pasting = .empty,
                .paste_end => if (pasting) |*b| {
                    ui.onPaste(b.items);
                    b.deinit(gpa);
                    pasting = null;
                    redraw = true;
                },
                .key_press => |key| if (pasting) |*b| {
                    pasteKey(gpa, b, key);
                } else switch (ui.onKey(translateKey(key))) {
                    .quit => {
                        k.windowClosed("main");
                        break :main;
                    },
                    else => redraw = true,
                },
                .mouse => |m| {
                    if (translateMouse(m)) |mm0| {
                        var mm = mm0;
                        if (mm.kind == .press) mm.clicks = clicks.press(io, mm.x, mm.y);
                        if (ui.onMouse(mm)) redraw = true;
                    }
                    if (ui.tipPending()) |gen| {
                        if (std.Thread.spawn(.{}, tipTimer, .{ &loop, io, gen })) |t| t.detach() else |e| std.log.warn("tip timer: {t}", .{e});
                    }
                },
                .tip => |gen| {
                    if (ui.tipDue(gen)) redraw = true;
                },
                .wake => {
                    app.pending.store(false, .release);
                    const ch = k.pump() catch |e| {
                        std.log.warn("pump: {t}", .{e});
                        continue;
                    };
                    for (many(core.HostCmd, ch.cmds, ch.n_cmds)) |cmd| switch (cmd.tag) {
                        @import("c").UIT_CMD_WINDOW => if (std.mem.eql(u8, core.slice(cmd.win), "main")) {
                            ui.shown = true;
                        },
                        @import("c").UIT_CMD_QUIT => break :main,
                        // The app's clipboard (a `clip` write, a terminal's
                        // copy or OSC 52) goes to the outer terminal's, as
                        // OSC 52.
                        @import("c").UIT_CMD_CLIPBOARD => vx.copyToSystemClipboard(writer, core.slice(cmd.answer), gpa) catch |e| std.log.warn("clipboard: {t}", .{e}),
                        @import("c").UIT_CMD_FOCUS => if (cmd.node != 0) ui.focus(cmd.node),
                        else => {},
                    };
                    for (many(@import("c").UitPropChange, ch.props, ch.n_props)) |p| ui.propChanged(p.node, core.slice(p.file));
                    for (many(core.Node, ch.removed, ch.n_removed)) |n| ui.removed(n);
                    if (ch.exited != 0) {
                        const s = core.slice(ch.exit_status);
                        if (s.len > 0) {
                            status = 1;
                            exit_text = std.fmt.bufPrint(&exit_buf, "{s}", .{s}) catch s;
                        }
                        break :main;
                    }
                    // Every input call wakes the core, uit_frame_drawn
                    // included, so a pump that changed nothing mustn't
                    // draw (and call it) again, or the host spins at a
                    // pump per frame while idle. The first frame comes
                    // from the winsize event.
                    if (ch.n_dirty + ch.n_created + ch.n_removed + ch.n_props + ch.n_cmds + ch.n_terms > 0) redraw = true;
                },
                else => {},
            }
            ev = (try loop.tryEvent()) orelse break;
        }
        if (!redraw) continue;
        const g = &(grid orelse continue);
        // The window's title comes from its root's `title` prop.
        const root_node = k.windowRoot("main");
        if (root_node != 0) if (k.prop(root_node, "title")) |t| {
            ui.title = std.mem.trimEnd(u8, t, "\n");
        };
        ui.frame(g) catch |e| std.log.warn("frame: {t}", .{e});
        blit(&vx, g, depth);
        try vx.render(writer);
        try writer.flush();
        k.frameDrawn("main");
    }

    exitUi(&vx, writer);
    k.shutdown();
    if (exit_text.len > 0) std.debug.print("uitree-tui: {s}: {s}\n", .{ if (remote) |x| x else argv[0], exit_text });
    return status;
}

/// Counts presses on one cell within the double-click time: 1, 2, 3, then
/// 1 again (a terminal selects a word on 2 and a line on 3).
const Clicks = struct {
    at: ?std.Io.Timestamp = null,
    x: i32 = 0,
    y: i32 = 0,
    n: u8 = 0,

    fn press(c: *Clicks, io: std.Io, x: i32, y: i32) u8 {
        const now = std.Io.Clock.awake.now(io);
        const quick = if (c.at) |t| t.durationTo(now).toMilliseconds() < 400 else false;
        c.n = if (quick and x == c.x and y == c.y and c.n < 3) c.n + 1 else 1;
        c.at = now;
        c.x = x;
        c.y = y;
        return c.n;
    }
};

fn many(comptime T: type, p: [*c]const T, n: usize) []const T {
    if (n == 0 or p == null) return &.{};
    return p[0..n];
}

fn exitUi(vx: *vaxis.Vaxis, w: *std.Io.Writer) void {
    vx.setMouseMode(w, false) catch {};
    vx.exitAltScreen(w) catch {};
    w.flush() catch {};
}

fn openLog(path: []const u8) c_int {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return -1;
    const fd = std.c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    return if (fd < 0) -1 else fd;
}

fn redirectStderr(fd: c_int) void {
    _ = std.c.dup2(fd, 2);
}

/// Copies the grid to vaxis's screen.
fn blit(vx: *vaxis.Vaxis, g: *const gridmod.Grid, depth: colormod.Depth) void {
    const win = vx.window();
    win.clear();
    var y: u16 = 0;
    while (y < g.h and y < win.height) : (y += 1) {
        var x: u16 = 0;
        while (x < g.w and x < win.width) : (x += 1) {
            const cell = g.cells[@as(usize, y) * g.w + x];
            if (cell.ch.len == 0) continue; // right half of a wide glyph
            const w = gridmod.width(cell.ch);
            win.writeCell(x, y, .{
                .char = .{ .grapheme = cell.ch, .width = @intCast(@max(1, w)) },
                .style = .{
                    .fg = termColor(depth, cell.fg),
                    .bg = termColor(depth, cell.bg),
                    .bold = cell.attrs.bold,
                    .dim = cell.attrs.dim,
                    .italic = cell.attrs.italic,
                    .ul = if (cell.ul_color) |u| termColor(depth, (u << 8) | 0xff) else .default,
                    .ul_style = if (!cell.attrs.underline) .off else switch (cell.attrs.ul_style) {
                        .single => .single,
                        .double => .double,
                        .curly => .curly,
                        .dotted => .dotted,
                        .dashed => .dashed,
                    },
                    .blink = cell.attrs.blink,
                    .strikethrough = cell.attrs.strike,
                    .reverse = cell.attrs.reverse,
                },
                .link = .{ .uri = cell.link },
            });
        }
    }
    if (g.cursor) |cur| {
        win.showCursor(cur.x, cur.y);
        win.setCursorShape(switch (cur.shape) {
            .bar => if (cur.blink) .beam_blink else .beam,
            .block => if (cur.blink) .block_blink else .block,
            .underline => if (cur.blink) .underline_blink else .underline,
        });
    } else win.hideCursor();
}

fn termColor(depth: colormod.Depth, v: u32) vaxis.Color {
    return switch (colormod.map(depth, v)) {
        .rgb => |x| .{ .rgb = x },
        .index => |n| .{ .index = n },
    };
}

fn translateMouse(m: vaxis.Mouse) ?uimod.Ui.Mouse {
    const x: i32 = m.col;
    const y: i32 = m.row;
    return switch (m.button) {
        .wheel_up => .{ .x = x, .y = y, .kind = .wheel_up },
        .wheel_down => .{ .x = x, .y = y, .kind = .wheel_down },
        .left => switch (m.type) {
            .press => .{ .x = x, .y = y, .kind = .press },
            .release => .{ .x = x, .y = y, .kind = .release },
            .drag => .{ .x = x, .y = y, .kind = .drag },
            .motion => .{ .x = x, .y = y, .kind = .motion },
        },
        .none => .{ .x = x, .y = y, .kind = if (m.type == .release) .release else .motion },
        else => null,
    };
}

var key_name_buf: [8]u8 = undefined;

/// One key of a bracketed paste, as the text it stands for.
fn pasteKey(gpa: std.mem.Allocator, b: *std.ArrayList(u8), k: vaxis.Key) void {
    const K = vaxis.Key;
    if (k.text) |t| {
        b.appendSlice(gpa, t) catch {};
        return;
    }
    const cp: u21 = switch (k.codepoint) {
        K.enter => '\n',
        K.tab => '\t',
        K.space => ' ',
        else => k.codepoint,
    };
    if (cp > 0x10ffff or (cp < 0x20 and cp != '\n' and cp != '\t')) return;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    b.appendSlice(gpa, buf[0..n]) catch {};
}

fn translateKey(k: vaxis.Key) uimod.Ui.Key {
    const K = vaxis.Key;
    const named = std.StaticStringMap(void).initComptime(.{});
    _ = named;
    const name: []const u8 = switch (k.codepoint) {
        K.enter => "enter",
        K.tab => "tab",
        K.escape => "escape",
        K.backspace => "backspace",
        K.space => "space",
        K.delete => "delete",
        K.insert => "insert",
        K.left => "left",
        K.right => "right",
        K.up => "up",
        K.down => "down",
        K.home => "home",
        K.end => "end",
        K.page_up => "pageup",
        K.page_down => "pagedown",
        K.f1 => "f1",
        K.f1 + 1 => "f2",
        K.f1 + 2 => "f3",
        K.f1 + 3 => "f4",
        K.f1 + 4 => "f5",
        K.f1 + 5 => "f6",
        K.f1 + 6 => "f7",
        K.f1 + 7 => "f8",
        K.f1 + 8 => "f9",
        K.f1 + 9 => "f10",
        K.f1 + 10 => "f11",
        K.f1 + 11 => "f12",
        else => blk: {
            const cp = if (k.mods.shift) k.shifted_codepoint orelse k.codepoint else k.codepoint;
            const n = std.unicode.utf8Encode(if (k.mods.ctrl or k.mods.alt) std.ascii.toLower(@intCast(@min(cp, 127))) else cp, &key_name_buf) catch break :blk "";
            break :blk key_name_buf[0..n];
        },
    };
    var text: []const u8 = k.text orelse "";
    if (k.codepoint == K.space and text.len == 0 and !k.mods.ctrl and !k.mods.alt) text = " ";
    // Enter, Tab and Backspace type no text here.
    if (k.codepoint == K.enter or k.codepoint == K.tab or k.codepoint == K.backspace or k.codepoint == K.escape) text = "";
    return .{
        .name = name,
        .text = text,
        .ctrl = k.mods.ctrl,
        .alt = k.mods.alt,
        .shift = k.mods.shift,
        .super = k.mods.super,
    };
}

test {
    _ = @import("grid.zig");
    _ = @import("color.zig");
    _ = @import("style.zig");
    _ = @import("core.zig");
    _ = @import("ui.zig");
}

test "the core accepts the descriptors, words and tokens this host registers" {
    const S = struct {
        fn wake(_: ?*anyopaque) callconv(.c) void {}
    };
    const k = try core.Core.create(.{
        .types = types.descriptors,
        .style_words = types.style_words,
        .theme_tokens = types.theme_tokens,
        .wake = S.wake,
        .wake_ctx = null,
    });
    defer k.destroy();
    try k.themes(types.themes);
    try std.testing.expect(k.windowRoot("main") != 0);
    try std.testing.expectEqual(@as(u32, 0xffffffff), k.token("background").?);
    _ = builtin;
}
