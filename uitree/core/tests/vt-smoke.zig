//! libghostty-vt's smoke test (`zig build smoke`; README.md, "The terminal
//! engine"). It links libuitcore.a as a renderer does and calls
//! libghostty-vt, which comes in with it, from one of the core's threads:
//! a std.Thread natively, and in the browser a core coroutine (h9's
//! coro.c, from libh9coro.a) that yields to the event loop halfway, so
//! the engine's state lives across a park. It checks the screen text,
//! styled cells, the cursor, and a key encoded under DECCKM.
//!
//! Natively this is a program. On wasm32-wasi it is a reactor like
//! uitcore.wasm, driven by tests/vt-smoke.mjs in Node and in Chromium:
//! vt_smoke_start(), then vt_smoke_result() until it isn't pending; and
//! vt_bench() for the parse throughput in README.md.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("ghostty_vt");

const web = builtin.os.tag == .wasi;

// From libuitcore.a: the C ABI's version, to be sure the core is linked.
extern fn uit_abi_version() u32;

// h9's coroutines (libh9coro.a), the core's threads in the browser.
const coro = struct {
    extern fn h9_coro_spawn(name: [*:0]const u8, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque, stk: c_ulong) ?*anyopaque;
    extern fn h9_coro_yield() void;
};

/// The screen the smoke test expects, as libghostty-vt's plain formatter
/// gives it.
const want_screen = "Hello, world!\nunderlined text\norange\n\n         placed";

const Sink = struct {
    buf: []u8,
    len: usize = 0,
    fn write(ud: ?*anyopaque, data: [*c]const u8, n: usize) callconv(.c) bool {
        const self: *Sink = @ptrCast(@alignCast(ud.?));
        if (self.len + n > self.buf.len) return false;
        @memcpy(self.buf[self.len..][0..n], data[0..n]);
        self.len += n;
        return true;
    }
};

const Failure = error{ Ghostty, Screen, Styles, Cursor, Key, Abi };

fn ok(r: c.GhosttyResult) Failure!void {
    if (r != c.GHOSTTY_SUCCESS) return error.Ghostty;
}

/// Lets everything else run: the event loop in the browser.
fn pause() void {
    if (web) coro.h9_coro_yield() else std.Thread.yield() catch {};
}

/// The test. Writes the screen text to `out` and returns its length.
fn run(out: []u8) Failure!usize {
    if (uit_abi_version() == 0) return error.Abi;
    var term: c.GhosttyTerminal = null;
    try ok(c.ghostty_terminal_new(null, &term, 40, 6));
    defer c.ghostty_terminal_free(term);

    const part1 = "Hello, \x1b[1;32mworld\x1b[0m!\r\n\x1b[4munderlined\x1b[0m text\r\n";
    const part2 = "\x1b[38;2;255;128;0morange\x1b[0m\r\n\x1b[5;10Hplaced\x1b]0;smoke\x07";
    c.ghostty_terminal_vt_write(term, part1, part1.len);
    pause();
    c.ghostty_terminal_vt_write(term, part2, part2.len);

    // The screen as plain text: what the node's `screen` file will serve.
    var fmt: c.GhosttyFormatter = null;
    try ok(c.ghostty_formatter_terminal_new(null, &fmt, term));
    defer c.ghostty_formatter_free(fmt);
    var sink: Sink = .{ .buf = out };
    try ok(c.ghostty_formatter_format(fmt, .{ .write = Sink.write, .userdata = &sink }));
    const text = std.mem.trimEnd(u8, out[0..sink.len], "\n ");
    if (!std.mem.eql(u8, text, want_screen)) return error.Screen;

    // The render state: styled cells and the cursor, what renderers draw.
    var rs: c.GhosttyRenderState = null;
    try ok(c.ghostty_render_state_new(null, &rs));
    defer c.ghostty_render_state_free(rs);
    try ok(c.ghostty_render_state_update(rs, term));
    var cursor = std.mem.zeroes(c.GhosttyRenderStateCursor);
    cursor.size = @sizeOf(c.GhosttyRenderStateCursor);
    try ok(c.ghostty_render_state_get(rs, c.GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor));
    if (cursor.viewport_x != 15 or cursor.viewport_y != 4) return error.Cursor;

    var rows: c.GhosttyRenderStateRowIterator = null;
    try ok(c.ghostty_render_state_row_iterator_new(null, &rows));
    defer c.ghostty_render_state_row_iterator_free(rows);
    try ok(c.ghostty_render_state_get(rs, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&rows)));
    var cells: c.GhosttyRenderStateRowCells = null;
    try ok(c.ghostty_render_state_row_cells_new(null, &cells));
    defer c.ghostty_render_state_row_cells_free(cells);
    var styled: usize = 0;
    while (c.ghostty_render_state_row_iterator_next(rows)) {
        try ok(c.ghostty_render_state_row_get(rows, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&cells)));
        while (c.ghostty_render_state_row_cells_next(cells)) {
            var style = std.mem.zeroes(c.GhosttyStyle);
            try ok(c.ghostty_render_state_row_cells_get(cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style));
            if (style.flags != 0 or style.fg_color.tag != c.GHOSTTY_STYLE_COLOR_NONE) styled += 1;
        }
    }
    // "world" (bold, green), "underlined" and "orange" (24-bit).
    if (styled != 5 + 10 + 6) return error.Styles;

    // The up arrow under DECCKM is ESC O A.
    const decckm = "\x1b[?1h";
    c.ghostty_terminal_vt_write(term, decckm, decckm.len);
    var enc: c.GhosttyKeyEncoder = null;
    try ok(c.ghostty_key_encoder_new(null, &enc));
    defer c.ghostty_key_encoder_free(enc);
    try ok(c.ghostty_key_encoder_set_from_terminal(enc, term));
    var ev: c.GhosttyKeyEvent = null;
    try ok(c.ghostty_key_event_new(null, &ev));
    defer c.ghostty_key_event_free(ev);
    try ok(c.ghostty_key_event_set_action(ev, c.GHOSTTY_KEY_ACTION_PRESS));
    try ok(c.ghostty_key_event_set_key(ev, c.GHOSTTY_KEY_ARROW_UP));
    var key: [32]u8 = undefined;
    var n: usize = 0;
    try ok(c.ghostty_key_encoder_encode(enc, ev, &key, key.len, &n));
    if (!std.mem.eql(u8, key[0..n], "\x1bOA")) return error.Key;

    return sink.len;
}

/// Natively: the test on a thread of its own, as the core's would be.
pub fn main() !void {
    if (web) return;
    var buf: [4096]u8 = undefined;
    var result: Failure!usize = error.Ghostty;
    const t = try std.Thread.spawn(.{}, struct {
        fn f(b: []u8, r: *Failure!usize) void {
            r.* = run(b);
        }
    }.f, .{ &buf, &result });
    t.join();
    const n = result catch |e| {
        std.debug.print("vt-smoke: FAIL: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("vt-smoke: ok, libghostty-vt {s} through libuitcore.a (ABI {d})\n{s}\n", .{
        c.GHOSTTY_VT_VERSION, uit_abi_version(), buf[0..n],
    });
}

// The browser: started on a coroutine, then polled.
var web_buf: [4096]u8 = undefined;
var web_state: i32 = -1; // -1 pending, else the screen's length, or -2 and an error name

fn webEntry(_: ?*anyopaque) callconv(.c) void {
    if (run(&web_buf)) |n| {
        web_state = @intCast(n);
    } else |e| {
        const name = @errorName(e);
        @memcpy(web_buf[0..name.len], name);
        web_state = -2 - @as(i32, @intCast(name.len));
    }
}

/// Starts the test on a core coroutine. 0, or -1 if it couldn't.
fn vtSmokeStart() callconv(.c) i32 {
    web_state = -1;
    return if (coro.h9_coro_spawn("vt-smoke", webEntry, null, 320 * 1024) != null) 0 else -1;
}

/// -1 while it runs. Then the screen text's length (in vt_smoke_buf()),
/// or -2 - n for a failure whose name is the buffer's first n bytes.
fn vtSmokeResult() callconv(.c) i32 {
    return web_state;
}

fn vtSmokeBuf() callconv(.c) [*]u8 {
    return &web_buf;
}

/// Parses `n` bytes of a typical colored-output stream through one
/// 80x24 terminal; the page times it. 0, or -1 on failure.
fn vtBench(n: usize) callconv(.c) i32 {
    var term: c.GhosttyTerminal = null;
    if (c.ghostty_terminal_new(null, &term, 80, 24) != c.GHOSTTY_SUCCESS) return -1;
    defer c.ghostty_terminal_free(term);
    const line = "\x1b[1;34mdrwxr-xr-x\x1b[0m  2 user staff  4096 Nov 25 05:20 \x1b[32mbuild.zig\x1b[0m and some plain text\r\n";
    var left = n;
    while (left > 0) {
        const k = @min(left, line.len);
        c.ghostty_terminal_vt_write(term, line, k);
        left -= k;
    }
    return 0;
}

comptime {
    if (web) {
        @export(&vtSmokeStart, .{ .name = "vt_smoke_start" });
        @export(&vtSmokeResult, .{ .name = "vt_smoke_result" });
        @export(&vtSmokeBuf, .{ .name = "vt_smoke_buf" });
        @export(&vtBench, .{ .name = "vt_bench" });
    }
}
