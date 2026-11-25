//! The libghostty-vt backend of engine.zig (C1), over ghostty/vt.h.
//!
//! libghostty-vt keeps the screen, history, modes and selection; this file
//! turns them into C1's shapes. Rows come from a render state, a copy of
//! the viewport libghostty-vt hands out for drawing, so reading cells never
//! walks the terminal's pages. Built rows are kept per viewport row and
//! rebuilt only when the render state says that row changed, so a pump that
//! changed one line costs one line.
//!
//! The pieces C1 has no word for are left at libghostty-vt's defaults, with
//! three exceptions: history is bounded by lines (Opts.scrollback) instead
//! of libghostty-vt's 10 KB default, the viewport snaps to the bottom on
//! output (C1's Scroll.bottom), and clipboard reads (OSC 52 `?`) are refused
//! by installing no read callback.
//!
//! Owner: the engine backends (T2).

const std = @import("std");
const engine = @import("engine.zig");
const c = @import("ghostty_vt");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Error = engine.Error;

/// The style table is rebuilt (StylesChange.reset) when it grows past this,
/// so a program cycling through true colors can't grow it without bound.
const max_styles = 1 << 14;

pub const Ghostty = struct {
    /// On the heap: libghostty-vt's callbacks hold its address, and an
    /// engine is returned by value.
    s: *State,

    pub fn init(gpa: Allocator, opts: engine.Opts) Error!Ghostty {
        const s = try gpa.create(State);
        errdefer gpa.destroy(s);
        try s.init(gpa, opts);
        return .{ .s = s };
    }

    pub fn deinit(g: *Ghostty) void {
        const gpa = g.s.gpa;
        g.s.deinit();
        gpa.destroy(g.s);
        g.* = undefined;
    }

    pub fn feed(g: *Ghostty, bytes: []const u8) Error!void {
        const s = g.s;
        if (bytes.len == 0) return;
        c.ghostty_terminal_vt_write(s.term, bytes.ptr, bytes.len);
        if (s.oom) {
            s.oom = false;
            return error.OutOfMemory;
        }
        // C1: output snaps the view back to the live screen.
        if (!s.viewportActive()) {
            var sv = std.mem.zeroes(c.GhosttyTerminalScrollViewport);
            sv.tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM;
            _ = c.ghostty_terminal_scroll_viewport(s.term, sv);
            s.invalidate();
        }
        s.stale = true;
    }

    pub fn resize(g: *Ghostty, sz: engine.Size) Error!void {
        const s = g.s;
        const cols = @max(sz.cols, 1);
        const rows = @max(sz.rows, 1);
        try check(c.ghostty_terminal_resize(s.term, cols, rows, sz.cell_w_px, sz.cell_h_px));
        s.cell_w_px = sz.cell_w_px;
        s.cell_h_px = sz.cell_h_px;
        if (cols != s.cols or rows != s.rows) {
            try s.setRows(rows);
            s.cols = cols;
            s.dirty_size = true;
        }
        s.invalidate();
    }

    pub fn size(g: *const Ghostty) engine.Size {
        const s = g.s;
        return .{ .cols = s.cols, .rows = s.rows, .cell_w_px = s.cell_w_px, .cell_h_px = s.cell_h_px };
    }

    pub fn reset(g: *Ghostty) void {
        const s = g.s;
        c.ghostty_terminal_reset(s.term);
        _ = c.ghostty_terminal_set(s.term, c.GHOSTTY_TERMINAL_OPT_SELECTION, null);
        s.resetStyles();
        s.buttons = 0;
        s.invalidate();
    }

    pub fn takeDirty(g: *Ghostty, out: *engine.Dirty) Error!void {
        const s = g.s;
        out.clear();
        try s.sync();
        if (s.styles.items.len > max_styles) {
            s.resetStyles();
            s.invalidate();
        }
        // Build what changed now, so the styles those rows add are in this
        // call's `styles`, and row() is a copy.
        try s.buildAll();
        if (s.dirty_all) {
            out.all = true;
        } else for (s.dirty_rows, 0..) |d, y| if (d) try out.rows.append(s.gpa, @intCast(y));
        @memset(s.dirty_rows, false);
        s.dirty_all = false;
        out.size = s.dirty_size;
        s.dirty_size = false;
        out.styles = s.styles_change;
        if (s.styles_change == .reset) out.all = true;
        s.styles_change = .same;
        const cur = s.cursorNow();
        out.cursor = out.all or !std.meta.eql(cur, s.last_cursor);
        s.last_cursor = cur;
        if (out.all) out.rows.clearRetainingCapacity();
    }

    pub fn row(g: *Ghostty, y: u16, out: *engine.Row) Error!void {
        const s = g.s;
        out.clear();
        try s.sync();
        if (y >= s.rows) return;
        if (!s.built[y]) try s.buildAll();
        const r = &s.cache[y];
        try out.text.appendSlice(s.gpa, r.text.items);
        try out.runs.appendSlice(s.gpa, r.runs.items);
    }

    pub fn styles(g: *Ghostty) []const engine.Style {
        return g.s.styles.items;
    }

    pub fn cursor(g: *Ghostty) engine.Cursor {
        const s = g.s;
        s.sync() catch return s.last_cursor;
        return s.cursorNow();
    }

    pub fn modes(g: *Ghostty) engine.Modes {
        const s = g.s;
        var mouse = false;
        _ = c.ghostty_terminal_get(s.term, c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, @ptrCast(&mouse));
        var screen: c.GhosttyTerminalScreen = c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        _ = c.ghostty_terminal_get(s.term, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, @ptrCast(&screen));
        return .{
            .mouse = mouse,
            .alt_screen = screen == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE,
            .alt_scroll = s.mode(1007),
            .bracketed_paste = s.mode(2004),
            .focus_reports = s.mode(1004),
            .app_cursor = s.mode(1),
        };
    }

    // ------------------------------------------------------------ input

    pub fn encodeKey(g: *Ghostty, k: engine.Key, w: *Writer) Writer.Error!bool {
        const s = g.s;
        // Super is the host's (cmd-c is copy): it reaches the program only
        // when kitty's keyboard protocol can say it was held.
        if (k.mods.super) {
            var kitty: u8 = 0;
            _ = c.ghostty_terminal_get(s.term, c.GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, @ptrCast(&kitty));
            if (kitty == 0) return false;
        }
        _ = c.ghostty_key_encoder_set_from_terminal(s.keys, s.term);
        const ev = s.key_ev;
        var mods: u16 = modBits(k.mods);
        var consumed: u16 = 0;
        var utf8: [4]u8 = undefined;
        var text: []const u8 = &.{};
        var key: c.GhosttyKey = c.GHOSTTY_KEY_UNIDENTIFIED;
        var unshifted: u32 = 0;
        switch (k.code) {
            .char => |cp| {
                const m = physical(cp);
                key = m.key;
                unshifted = m.unshifted;
                // The character already has shift applied ("A", "!"); say
                // so, as a keyboard would, so kitty's protocol reports it.
                if (m.shifted) {
                    mods |= c.GHOSTTY_MODS_SHIFT;
                    consumed |= c.GHOSTTY_MODS_SHIFT;
                }
                // The text is what the key types before ctrl or alt.
                if (cp >= 0x20 and cp != 0x7f) {
                    const n = std.unicode.utf8Encode(cp, &utf8) catch return false;
                    text = utf8[0..n];
                }
                if (unshifted == 0) unshifted = cp;
            },
            .named => |n| {
                key = namedKey(n);
                // Space types a character; the encoder needs it as text.
                if (n == .space) {
                    text = " ";
                    unshifted = ' ';
                }
            },
        }
        _ = c.ghostty_key_event_set_action(ev, c.GHOSTTY_KEY_ACTION_PRESS);
        _ = c.ghostty_key_event_set_key(ev, key);
        _ = c.ghostty_key_event_set_mods(ev, mods);
        _ = c.ghostty_key_event_set_consumed_mods(ev, consumed);
        _ = c.ghostty_key_event_set_unshifted_codepoint(ev, unshifted);
        _ = c.ghostty_key_event_set_utf8(ev, .{ .ptr = if (text.len > 0) text.ptr else null, .len = text.len });
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        const r = c.ghostty_key_encoder_encode(s.keys, ev, &buf, buf.len, &n);
        // The event borrows `utf8`; don't leave it pointing at our stack.
        _ = c.ghostty_key_event_set_utf8(ev, .{ .ptr = null, .len = 0 });
        if (r != c.GHOSTTY_SUCCESS or n == 0) return false;
        try w.writeAll(buf[0..n]);
        return true;
    }

    pub fn encodeText(_: *Ghostty, text: []const u8, w: *Writer) Writer.Error!void {
        try w.writeAll(text);
    }

    pub fn encodeMouse(g: *Ghostty, m: engine.Mouse, w: *Writer) Writer.Error!bool {
        const s = g.s;
        // Track the buttons held whether or not a program is listening, so
        // the encoder knows when tracking starts mid-drag.
        const bit: u8 = switch (m.button) {
            .left => 1,
            .middle => 2,
            .right => 4,
            else => 0,
        };
        switch (m.action) {
            .press => s.buttons |= bit,
            .release => s.buttons &= ~bit,
            .move => {},
        }
        if (!g.modes().mouse) return false;
        _ = c.ghostty_mouse_encoder_set_from_terminal(s.mouse, s.term);
        // libghostty-vt places events in pixels: give it a grid of cells
        // and the middle of the cell.
        const cw: u32 = if (s.cell_w_px > 0) s.cell_w_px else 8;
        const ch: u32 = if (s.cell_h_px > 0) s.cell_h_px else 16;
        var sz = std.mem.zeroes(c.GhosttyMouseEncoderSize);
        sz.size = @sizeOf(c.GhosttyMouseEncoderSize);
        sz.screen_width = cw * s.cols;
        sz.screen_height = ch * s.rows;
        sz.cell_width = cw;
        sz.cell_height = ch;
        _ = c.ghostty_mouse_encoder_set(s.mouse, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, @ptrCast(&sz));
        const held = s.buttons != 0;
        _ = c.ghostty_mouse_encoder_set(s.mouse, c.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, @ptrCast(&held));
        const ev = s.mouse_ev;
        _ = c.ghostty_mouse_event_set_action(ev, switch (m.action) {
            .press => c.GHOSTTY_MOUSE_ACTION_PRESS,
            .release => c.GHOSTTY_MOUSE_ACTION_RELEASE,
            .move => c.GHOSTTY_MOUSE_ACTION_MOTION,
        });
        switch (m.button) {
            .none => _ = c.ghostty_mouse_event_clear_button(ev),
            .left => _ = c.ghostty_mouse_event_set_button(ev, c.GHOSTTY_MOUSE_BUTTON_LEFT),
            .middle => _ = c.ghostty_mouse_event_set_button(ev, c.GHOSTTY_MOUSE_BUTTON_MIDDLE),
            .right => _ = c.ghostty_mouse_event_set_button(ev, c.GHOSTTY_MOUSE_BUTTON_RIGHT),
            .wheel_up => _ = c.ghostty_mouse_event_set_button(ev, c.GHOSTTY_MOUSE_BUTTON_FOUR),
            .wheel_down => _ = c.ghostty_mouse_event_set_button(ev, c.GHOSTTY_MOUSE_BUTTON_FIVE),
        }
        _ = c.ghostty_mouse_event_set_mods(ev, modBits(m.mods));
        _ = c.ghostty_mouse_event_set_position(ev, .{
            .x = @floatFromInt(@as(u32, m.col) * cw + cw / 2),
            .y = @floatFromInt(@as(u32, m.row) * ch + ch / 2),
        });
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        if (c.ghostty_mouse_encoder_encode(s.mouse, ev, &buf, buf.len, &n) == c.GHOSTTY_SUCCESS)
            try w.writeAll(buf[0..n]);
        return true;
    }

    /// libghostty-vt's paste encoding: unsafe control bytes become spaces,
    /// and the text is bracketed when the program asked, or has its
    /// newlines turned to CR when it didn't.
    pub fn encodePaste(g: *Ghostty, text: []const u8, w: *Writer) Writer.Error!void {
        const s = g.s;
        if (text.len == 0) return;
        const bracketed = s.mode(2004);
        const copy = s.gpa.dupe(u8, text) catch return error.WriteFailed;
        defer s.gpa.free(copy);
        var need: usize = 0;
        _ = c.ghostty_paste_encode(copy.ptr, copy.len, bracketed, null, 0, &need);
        const buf = s.gpa.alloc(u8, need) catch return error.WriteFailed;
        defer s.gpa.free(buf);
        var n: usize = 0;
        if (c.ghostty_paste_encode(copy.ptr, copy.len, bracketed, buf.ptr, buf.len, &n) != c.GHOSTTY_SUCCESS)
            return error.WriteFailed;
        try w.writeAll(buf[0..n]);
    }

    pub fn encodeFocus(g: *Ghostty, in: bool, w: *Writer) Writer.Error!void {
        if (!g.s.mode(1004)) return;
        var buf: [16]u8 = undefined;
        var n: usize = 0;
        if (c.ghostty_focus_encode(if (in) c.GHOSTTY_FOCUS_GAINED else c.GHOSTTY_FOCUS_LOST, &buf, buf.len, &n) == c.GHOSTTY_SUCCESS)
            try w.writeAll(buf[0..n]);
    }

    // ------------------------------------------------------------ view

    pub fn scroll(g: *Ghostty, sc: engine.Scroll) void {
        const s = g.s;
        var sv = std.mem.zeroes(c.GhosttyTerminalScrollViewport);
        switch (sc) {
            .top => sv.tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP,
            .bottom => sv.tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM,
            .lines => |n| {
                if (n == 0) return;
                sv.tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA;
                sv.value.delta = n;
            },
        }
        _ = c.ghostty_terminal_scroll_viewport(s.term, sv);
        s.invalidate();
    }

    pub fn select(g: *Ghostty, sel: engine.Selection) void {
        const s = g.s;
        s.invalidate();
        const r = switch (sel) {
            .none => {
                _ = c.ghostty_terminal_set(s.term, c.GHOSTTY_TERMINAL_OPT_SELECTION, null);
                return;
            },
            .range => |r| r,
        };
        var a = clampPoint(s, r.start);
        var b = clampPoint(s, r.end);
        if (b.row < a.row or (b.row == a.row and b.col < a.col)) std.mem.swap(engine.Point, &a, &b);
        var out = std.mem.zeroes(c.GhosttySelection);
        const ra = s.ref(a) orelse return;
        const rb = s.ref(b) orelse return;
        out.start = ra;
        out.end = rb;
        switch (r.unit) {
            .cells => {},
            .words => {
                if (s.word(ra)) |w| out.start = w.start;
                if (s.word(rb)) |w| out.end = w.end;
            },
            .lines => {
                // Whole rows, edge to edge, as the plain engine selects.
                out.start = s.ref(.{ .col = 0, .row = a.row }) orelse return;
                out.end = s.ref(.{ .col = s.cols - 1, .row = b.row }) orelse return;
            },
        }
        _ = c.ghostty_terminal_set(s.term, c.GHOSTTY_TERMINAL_OPT_SELECTION, @ptrCast(&out));
    }

    pub fn screenText(g: *Ghostty, w: *Writer) Writer.Error!void {
        const s = g.s;
        s.sync() catch return error.WriteFailed;
        var it = s.rowIterator() orelse return;
        // Rows are built into one buffer, and blank rows are held back
        // until a row with text follows them.
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(s.gpa);
        var blank_rows: usize = 0;
        while (c.ghostty_render_state_row_iterator_next(it)) {
            line.clearRetainingCapacity();
            s.rowText(&it, &line) catch return error.WriteFailed;
            if (line.items.len == 0) {
                blank_rows += 1;
                continue;
            }
            for (0..blank_rows) |_| try w.writeByte('\n');
            blank_rows = 0;
            try w.writeAll(line.items);
            try w.writeByte('\n');
        }
    }

    pub fn selectionText(g: *Ghostty, w: *Writer) Writer.Error!void {
        const s = g.s;
        var sel = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_terminal_get(s.term, c.GHOSTTY_TERMINAL_DATA_SELECTION, @ptrCast(&sel)) != c.GHOSTTY_SUCCESS) return;
        if (c.ghostty_formatter_set(s.fmt, c.GHOSTTY_FORMATTER_OPT_SELECTION, @ptrCast(&sel)) != c.GHOSTTY_SUCCESS) return;
        defer _ = c.ghostty_formatter_set(s.fmt, c.GHOSTTY_FORMATTER_OPT_SELECTION, null);
        var sink: Sink = .{ .w = w };
        if (c.ghostty_formatter_format(s.fmt, .{ .write = Sink.write, .userdata = &sink }) != c.GHOSTTY_SUCCESS)
            return error.WriteFailed;
    }

    pub fn takeEvents(g: *Ghostty, out: *engine.Events) Error!void {
        const s = g.s;
        out.clear();
        out.bell = s.bell;
        s.bell = 0;
        if (s.title_changed) {
            s.title_changed = false;
            out.title = try out.put(s.gpa, s.string(c.GHOSTTY_TERMINAL_DATA_TITLE));
        }
        if (s.pwd_changed) {
            s.pwd_changed = false;
            out.cwd = try out.put(s.gpa, s.string(c.GHOSTTY_TERMINAL_DATA_PWD));
        }
        for (s.clips.items) |clip| {
            const span = try out.put(s.gpa, s.clip_buf.items[clip.start..][0..clip.len]);
            try out.clips.append(s.gpa, .{ .target = clip.target, .data = span });
        }
        s.clips.clearRetainingCapacity();
        s.clip_buf.clearRetainingCapacity();
        if (s.replies.items.len > 0) {
            out.reply = try out.put(s.gpa, s.replies.items);
            s.replies.clearRetainingCapacity();
        }
    }
};

/// A GhosttyWriter onto a std.Io.Writer.
const Sink = struct {
    w: *Writer,
    fn write(ud: ?*anyopaque, data: [*c]const u8, n: usize) callconv(.c) bool {
        const self: *Sink = @ptrCast(@alignCast(ud.?));
        self.w.writeAll(data[0..n]) catch return false;
        return true;
    }
};

const State = struct {
    gpa: Allocator,
    term: c.GhosttyTerminal = null,
    rs: c.GhosttyRenderState = null,
    rows_it: c.GhosttyRenderStateRowIterator = null,
    cells: c.GhosttyRenderStateRowCells = null,
    fmt: c.GhosttyFormatter = null,
    keys: c.GhosttyKeyEncoder = null,
    key_ev: c.GhosttyKeyEvent = null,
    mouse: c.GhosttyMouseEncoder = null,
    mouse_ev: c.GhosttyMouseEvent = null,

    cols: u16,
    rows: u16,
    cell_w_px: u16 = 0,
    cell_h_px: u16 = 0,

    /// The terminal changed since the render state was last updated.
    stale: bool = true,
    /// Per viewport row: the runs as C1 hands them out, and whether they
    /// are current.
    cache: []engine.Row = &.{},
    built: []bool = &.{},
    palette: [256]c.GhosttyColorRgb = undefined,

    dirty_rows: []bool = &.{},
    dirty_all: bool = true,
    dirty_size: bool = false,
    last_cursor: engine.Cursor = .{},

    styles: std.ArrayList(engine.Style) = .empty,
    style_ids: std.HashMapUnmanaged(engine.Style, u32, StyleCtx, 80) = .empty,
    styles_change: engine.StylesChange = .same,

    /// Mouse buttons held: 1 left, 2 middle, 4 right.
    buttons: u8 = 0,

    bell: u32 = 0,
    title_changed: bool = false,
    pwd_changed: bool = false,
    clips: std.ArrayList(struct { target: u8, start: u32, len: u32 }) = .empty,
    clip_buf: std.ArrayList(u8) = .empty,
    replies: std.ArrayList(u8) = .empty,
    /// A callback couldn't allocate; feed reports it.
    oom: bool = false,

    fn init(s: *State, gpa: Allocator, opts: engine.Opts) Error!void {
        const cols = @max(opts.cols, 1);
        const rows = @max(opts.rows, 1);
        s.* = .{ .gpa = gpa, .cols = cols, .rows = rows };
        errdefer s.deinit();
        try check(c.ghostty_terminal_new(null, &s.term, cols, rows));
        try check(c.ghostty_render_state_new(null, &s.rs));
        try check(c.ghostty_render_state_row_iterator_new(null, &s.rows_it));
        try check(c.ghostty_render_state_row_cells_new(null, &s.cells));
        try check(c.ghostty_formatter_terminal_new(null, &s.fmt, s.term));
        try check(c.ghostty_key_encoder_new(null, &s.keys));
        try check(c.ghostty_key_event_new(null, &s.key_ev));
        try check(c.ghostty_mouse_encoder_new(null, &s.mouse));
        try check(c.ghostty_mouse_event_new(null, &s.mouse_ev));
        const track = true;
        _ = c.ghostty_mouse_encoder_set(s.mouse, c.GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, @ptrCast(&track));
        // Selected text as Ghostty copies it: trimmed, rows as they wrap.
        const trim = true;
        _ = c.ghostty_formatter_set(s.fmt, c.GHOSTTY_FORMATTER_OPT_TRIM, @ptrCast(&trim));

        const t = s.term;
        _ = c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_USERDATA, s);
        _ = c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&onWritePty));
        _ = c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_BELL, @ptrCast(&onBell));
        _ = c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @ptrCast(&onTitle));
        _ = c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_PWD_CHANGED, @ptrCast(&onPwd));
        _ = c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, @ptrCast(&onClipboardWrite));
        // History by lines, as the node's `scrollback` says, not by
        // libghostty-vt's default of 10 KB.
        const unlimited: usize = std.math.maxInt(usize);
        _ = c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, @ptrCast(&unlimited));
        const lines: usize = opts.scrollback;
        if (lines == 0) {
            const zero: usize = 0;
            _ = c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, @ptrCast(&zero));
        } else _ = c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, @ptrCast(&lines));

        try s.styles.append(gpa, .{});
        try s.style_ids.put(gpa, .{}, 0);
        try s.setRows(rows);
    }

    fn deinit(s: *State) void {
        c.ghostty_mouse_event_free(s.mouse_ev);
        c.ghostty_mouse_encoder_free(s.mouse);
        c.ghostty_key_event_free(s.key_ev);
        c.ghostty_key_encoder_free(s.keys);
        c.ghostty_formatter_free(s.fmt);
        c.ghostty_render_state_row_cells_free(s.cells);
        c.ghostty_render_state_row_iterator_free(s.rows_it);
        c.ghostty_render_state_free(s.rs);
        c.ghostty_terminal_free(s.term);
        s.freeRows();
        s.styles.deinit(s.gpa);
        s.style_ids.deinit(s.gpa);
        s.clips.deinit(s.gpa);
        s.clip_buf.deinit(s.gpa);
        s.replies.deinit(s.gpa);
    }

    fn freeRows(s: *State) void {
        for (s.cache) |*r| r.deinit(s.gpa);
        s.gpa.free(s.cache);
        s.gpa.free(s.built);
        s.gpa.free(s.dirty_rows);
        s.cache = &.{};
        s.built = &.{};
        s.dirty_rows = &.{};
    }

    fn setRows(s: *State, rows: u16) Error!void {
        const cache = try s.gpa.alloc(engine.Row, rows);
        errdefer s.gpa.free(cache);
        const built = try s.gpa.alloc(bool, rows);
        errdefer s.gpa.free(built);
        const dirty = try s.gpa.alloc(bool, rows);
        s.freeRows();
        for (cache) |*r| r.* = .{};
        @memset(built, false);
        @memset(dirty, false);
        s.cache = cache;
        s.built = built;
        s.dirty_rows = dirty;
        s.rows = rows;
    }

    /// Everything on screen must be redrawn and rebuilt.
    fn invalidate(s: *State) void {
        s.stale = true;
        s.dirty_all = true;
        @memset(s.built, false);
    }

    fn resetStyles(s: *State) void {
        s.styles.shrinkRetainingCapacity(1);
        s.style_ids.clearRetainingCapacity();
        s.style_ids.putAssumeCapacity(.{}, 0);
        s.styles_change = .reset;
    }

    fn mode(s: *State, n: u15) bool {
        var mc: c.GhosttyTerminalModeConfig = .{ .mode = n, .value = false };
        if (c.ghostty_terminal_get(s.term, c.GHOSTTY_TERMINAL_DATA_MODE, @ptrCast(&mc)) != c.GHOSTTY_SUCCESS) return false;
        return mc.value;
    }

    fn viewportActive(s: *State) bool {
        var active = true;
        _ = c.ghostty_terminal_get(s.term, c.GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, @ptrCast(&active));
        return active;
    }

    fn string(s: *State, data: c.GhosttyTerminalData) []const u8 {
        var str: c.GhosttyString = .{ .ptr = null, .len = 0 };
        if (c.ghostty_terminal_get(s.term, data, @ptrCast(&str)) != c.GHOSTTY_SUCCESS or str.len == 0) return "";
        return str.ptr[0..str.len];
    }

    /// Brings the render state up to the terminal, and folds what it says
    /// changed into our dirty rows and row cache.
    fn sync(s: *State) Error!void {
        if (!s.stale) return;
        try check(c.ghostty_render_state_update(s.rs, s.term));
        s.stale = false;
        var colors = std.mem.zeroes(c.GhosttyRenderStateColors);
        colors.size = @sizeOf(c.GhosttyRenderStateColors);
        if (c.ghostty_render_state_get(s.rs, c.GHOSTTY_RENDER_STATE_DATA_COLORS, @ptrCast(&colors)) == c.GHOSTTY_SUCCESS)
            s.palette = colors.palette;
        var dirty: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = c.ghostty_render_state_get(s.rs, c.GHOSTTY_RENDER_STATE_DATA_DIRTY, @ptrCast(&dirty));
        if (dirty == c.GHOSTTY_RENDER_STATE_DIRTY_FULL) {
            s.dirty_all = true;
            @memset(s.built, false);
        } else if (dirty == c.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL) {
            if (s.rowIterator()) |it| {
                var y: u16 = 0;
                while (c.ghostty_render_state_row_iterator_next_dirty(it, &y)) {
                    if (y >= s.rows) continue;
                    s.dirty_rows[y] = true;
                    s.built[y] = false;
                }
            }
        }
        _ = c.ghostty_render_state_clean(s.rs);
    }

    fn rowIterator(s: *State) ?c.GhosttyRenderStateRowIterator {
        if (c.ghostty_render_state_get(s.rs, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&s.rows_it)) != c.GHOSTTY_SUCCESS) return null;
        return s.rows_it;
    }

    fn cursorNow(s: *State) engine.Cursor {
        var cur = std.mem.zeroes(c.GhosttyRenderStateCursor);
        cur.size = @sizeOf(c.GhosttyRenderStateCursor);
        if (c.ghostty_render_state_get(s.rs, c.GHOSTTY_RENDER_STATE_DATA_CURSOR, @ptrCast(&cur)) != c.GHOSTTY_SUCCESS)
            return .{ .visible = false };
        const shape: engine.CursorShape = switch (cur.visual_style) {
            c.GHOSTTY_CURSOR_STYLE_BAR => .bar,
            c.GHOSTTY_CURSOR_STYLE_UNDERLINE => .underline,
            c.GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW => .block_hollow,
            else => .block,
        };
        if (!cur.viewport_has_value) return .{ .visible = false, .shape = shape, .blink = cur.blinking };
        return .{
            .x = cur.viewport_x,
            .y = cur.viewport_y,
            .shape = shape,
            .visible = cur.visible,
            .blink = cur.blinking,
        };
    }

    /// Builds the rows not yet built into the cache, in one walk down
    /// the render state.
    fn buildAll(s: *State) Error!void {
        var it = s.rowIterator() orelse return error.OutOfMemory;
        var y: u16 = 0;
        while (y < s.rows) : (y += 1) {
            if (!c.ghostty_render_state_row_iterator_next(it)) {
                for (y..s.rows) |r| if (!s.built[r]) {
                    s.cache[r].clear();
                    s.built[r] = true;
                };
                return;
            }
            if (s.built[y]) continue;
            try s.buildRow(&it, &s.cache[y]);
            s.built[y] = true;
        }
    }

    const Cell = struct {
        text: []const u8,
        width: u16,
        style: u32,
        selected: bool,
        /// Not a blank cell in the default style.
        content: bool,
    };

    /// Reads cell `x` of the row `cells` is on into `buf`.
    fn readCell(s: *State, x: u16, sel: ?[2]u16, buf: *[64]u8) Error!?Cell {
        if (c.ghostty_render_state_row_cells_select(s.cells, x) != c.GHOSTTY_SUCCESS) return null;
        var raw: c.GhosttyCell = 0;
        _ = c.ghostty_render_state_row_cells_get(s.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw));
        var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
        _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
        if (wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL) return null;
        var gb: c.GhosttyBuffer = .{ .ptr = buf, .cap = buf.len, .len = 0 };
        var text: []const u8 = " ";
        if (wide != c.GHOSTTY_CELL_WIDE_SPACER_HEAD and
            c.ghostty_render_state_row_cells_get(s.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, @ptrCast(&gb)) == c.GHOSTTY_SUCCESS and
            gb.len > 0) text = buf[0..gb.len];
        const style = try s.cellStyle();
        const selected = if (sel) |r| x >= r[0] and x <= r[1] else false;
        return .{
            .text = text,
            .width = if (wide == c.GHOSTTY_CELL_WIDE_WIDE) 2 else 1,
            .style = style,
            .selected = selected,
            .content = selected or style != 0 or !std.mem.eql(u8, text, " "),
        };
    }

    fn rowSelection(it: *c.GhosttyRenderStateRowIterator) ?[2]u16 {
        var rsel = std.mem.zeroes(c.GhosttyRenderStateRowSelection);
        rsel.size = @sizeOf(c.GhosttyRenderStateRowSelection);
        if (c.ghostty_render_state_row_get(it.*, c.GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, @ptrCast(&rsel)) != c.GHOSTTY_SUCCESS) return null;
        return .{ rsel.start_x, rsel.end_x };
    }

    fn buildRow(s: *State, it: *c.GhosttyRenderStateRowIterator, out: *engine.Row) Error!void {
        out.clear();
        if (c.ghostty_render_state_row_get(it.*, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&s.cells)) != c.GHOSTTY_SUCCESS) return;
        const sel = rowSelection(it);
        var buf: [64]u8 = undefined;
        var open: ?engine.Run = null;
        // Where the row stood after its last cell with content: trailing
        // blank default cells get no run, so they are cut back to here.
        var mark: struct { runs: usize = 0, text: usize = 0, open: ?engine.Run = null } = .{};
        var x: u16 = 0;
        while (x < s.cols) {
            const cell = (try s.readCell(x, sel, &buf)) orelse {
                x += 1;
                continue;
            };
            merge: {
                if (open) |*r| {
                    if (r.style == cell.style and r.selected == cell.selected and r.col + r.width == x) {
                        try out.text.appendSlice(s.gpa, cell.text);
                        r.width += cell.width;
                        r.len += @intCast(cell.text.len);
                        break :merge;
                    }
                    try out.runs.append(s.gpa, r.*);
                }
                const start: u32 = @intCast(out.text.items.len);
                try out.text.appendSlice(s.gpa, cell.text);
                open = .{ .col = x, .width = cell.width, .style = cell.style, .start = start, .len = @intCast(cell.text.len), .selected = cell.selected };
            }
            if (cell.content) mark = .{ .runs = out.runs.items.len, .text = out.text.items.len, .open = open };
            x += cell.width;
        }
        out.runs.shrinkRetainingCapacity(mark.runs);
        out.text.shrinkRetainingCapacity(mark.text);
        if (mark.open) |r| try out.runs.append(s.gpa, r);
    }

    /// The plain text of the row `it` is on, trailing blanks trimmed.
    fn rowText(s: *State, it: *c.GhosttyRenderStateRowIterator, out: *std.ArrayList(u8)) Error!void {
        if (c.ghostty_render_state_row_get(it.*, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&s.cells)) != c.GHOSTTY_SUCCESS) return;
        var buf: [64]u8 = undefined;
        var keep: usize = 0;
        var x: u16 = 0;
        while (x < s.cols) : (x += 1) {
            if (c.ghostty_render_state_row_cells_select(s.cells, x) != c.GHOSTTY_SUCCESS) break;
            var raw: c.GhosttyCell = 0;
            _ = c.ghostty_render_state_row_cells_get(s.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw));
            var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, @ptrCast(&wide));
            if (wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL) continue;
            var gb: c.GhosttyBuffer = .{ .ptr = &buf, .cap = buf.len, .len = 0 };
            if (wide != c.GHOSTTY_CELL_WIDE_SPACER_HEAD and
                c.ghostty_render_state_row_cells_get(s.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, @ptrCast(&gb)) == c.GHOSTTY_SUCCESS and
                gb.len > 0)
            {
                try out.appendSlice(s.gpa, buf[0..gb.len]);
                if (!(gb.len == 1 and buf[0] == ' ')) keep = out.items.len;
            } else try out.append(s.gpa, ' ');
        }
        out.shrinkRetainingCapacity(keep);
    }

    /// The current cell's style, resolved to RGBA and interned.
    fn cellStyle(s: *State) Error!u32 {
        var has = false;
        _ = c.ghostty_render_state_row_cells_get(s.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, @ptrCast(&has));
        var raw: c.GhosttyCell = 0;
        _ = c.ghostty_render_state_row_cells_get(s.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, @ptrCast(&raw));
        var tag: c.GhosttyCellContentTag = c.GHOSTTY_CELL_CONTENT_CODEPOINT;
        _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_CONTENT_TAG, @ptrCast(&tag));
        // A cell with only a background color (erased in a colored SGR)
        // has no styling but does have a color.
        if (!has and tag != c.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE and tag != c.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) return 0;
        var gs = std.mem.zeroes(c.GhosttyStyle);
        _ = c.ghostty_render_state_row_cells_get(s.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, @ptrCast(&gs));
        var st: engine.Style = .{};
        var rgb: c.GhosttyColorRgb = undefined;
        if (c.ghostty_render_state_row_cells_get(s.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, @ptrCast(&rgb)) == c.GHOSTTY_SUCCESS) st.fg = rgba(rgb);
        if (c.ghostty_render_state_row_cells_get(s.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, @ptrCast(&rgb)) == c.GHOSTTY_SUCCESS) st.bg = rgba(rgb);
        st.underline_color = switch (gs.underline_color.tag) {
            c.GHOSTTY_STYLE_COLOR_PALETTE => rgba(s.palette[gs.underline_color.value.palette]),
            c.GHOSTTY_STYLE_COLOR_RGB => rgba(gs.underline_color.value.rgb),
            else => 0,
        };
        const f: u16 = gs.flags;
        st.underline = std.enums.fromInt(engine.Underline, (f >> 8) & 7) orelse .single;
        st.flags = .{
            .bold = f & c.GHOSTTY_STYLE_FLAG_BOLD != 0,
            .italic = f & c.GHOSTTY_STYLE_FLAG_ITALIC != 0,
            .faint = f & c.GHOSTTY_STYLE_FLAG_FAINT != 0,
            .blink = f & c.GHOSTTY_STYLE_FLAG_BLINK != 0,
            .inverse = f & c.GHOSTTY_STYLE_FLAG_INVERSE != 0,
            .invisible = f & c.GHOSTTY_STYLE_FLAG_INVISIBLE != 0,
            .strike = f & c.GHOSTTY_STYLE_FLAG_STRIKETHROUGH != 0,
            .overline = f & c.GHOSTTY_STYLE_FLAG_OVERLINE != 0,
        };
        return s.intern(st);
    }

    fn intern(s: *State, st: engine.Style) Error!u32 {
        const gop = try s.style_ids.getOrPut(s.gpa, st);
        if (gop.found_existing) return gop.value_ptr.*;
        const id: u32 = @intCast(s.styles.items.len);
        s.styles.append(s.gpa, st) catch |e| {
            _ = s.style_ids.remove(st);
            return e;
        };
        gop.value_ptr.* = id;
        if (s.styles_change == .same) s.styles_change = .grew;
        return id;
    }

    /// A grid reference to viewport point `p`.
    fn ref(s: *State, p: engine.Point) ?c.GhosttyGridRef {
        var pt = std.mem.zeroes(c.GhosttyPoint);
        pt.tag = c.GHOSTTY_POINT_TAG_VIEWPORT;
        pt.value.coordinate = .{ .x = p.col, .y = p.row };
        var r = std.mem.zeroes(c.GhosttyGridRef);
        if (c.ghostty_terminal_grid_ref(s.term, pt, &r) != c.GHOSTTY_SUCCESS) return null;
        return r;
    }

    /// The word under `r`, by libghostty-vt's rules; null on a blank.
    fn word(s: *State, r: c.GhosttyGridRef) ?c.GhosttySelection {
        var o = std.mem.zeroes(c.GhosttyTerminalSelectWordOptions);
        o.size = @sizeOf(c.GhosttyTerminalSelectWordOptions);
        o.ref = r;
        var w = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_terminal_select_word(s.term, &o, &w) != c.GHOSTTY_SUCCESS) return null;
        var ordered = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_terminal_selection_ordered(s.term, &w, c.GHOSTTY_SELECTION_ORDER_FORWARD, &ordered) != c.GHOSTTY_SUCCESS) return w;
        return ordered;
    }

    // ------------------------------------------------------------ callbacks

    fn of(ud: ?*anyopaque) *State {
        return @ptrCast(@alignCast(ud.?));
    }

    fn onWritePty(_: c.GhosttyTerminal, ud: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const s = of(ud);
        s.replies.appendSlice(s.gpa, data[0..len]) catch {
            s.oom = true;
        };
    }

    fn onBell(_: c.GhosttyTerminal, ud: ?*anyopaque) callconv(.c) void {
        of(ud).bell +|= 1;
    }

    fn onTitle(_: c.GhosttyTerminal, ud: ?*anyopaque) callconv(.c) void {
        of(ud).title_changed = true;
    }

    fn onPwd(_: c.GhosttyTerminal, ud: ?*anyopaque) callconv(.c) void {
        of(ud).pwd_changed = true;
    }

    /// OSC 52 (and its kin): the text representation, for the core to put
    /// on the clipboard once its policy allows. The program is told it
    /// worked; OSC 52 has no reply anyway.
    fn onClipboardWrite(_: c.GhosttyTerminal, ud: ?*anyopaque, wr: [*c]const c.GhosttyClipboardWrite) callconv(.c) void {
        const s = of(ud);
        const req = &wr[0];
        const target: u8 = switch (req.location) {
            c.GHOSTTY_CLIPBOARD_LOCATION_SELECTION => 's',
            c.GHOSTTY_CLIPBOARD_LOCATION_PRIMARY => 'p',
            else => 'c',
        };
        var data: []const u8 = "";
        var found = req.contents_len == 0;
        for (0..req.contents_len) |i| {
            const ct = req.contents[i];
            const mime: []const u8 = if (ct.mime.len > 0) ct.mime.ptr[0..ct.mime.len] else "";
            if (std.mem.startsWith(u8, mime, "text/plain") or (!found and std.mem.startsWith(u8, mime, "text/"))) {
                data = if (ct.data.len > 0) ct.data.ptr[0..ct.data.len] else "";
                found = true;
                if (std.mem.startsWith(u8, mime, "text/plain")) break;
            }
        }
        var reply = std.mem.zeroes(c.GhosttyClipboardWriteReply);
        reply.size = @sizeOf(c.GhosttyClipboardWriteReply);
        reply.result = c.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
        if (found) ok: {
            const start: u32 = @intCast(s.clip_buf.items.len);
            s.clip_buf.appendSlice(s.gpa, data) catch {
                s.oom = true;
                break :ok;
            };
            s.clips.append(s.gpa, .{ .target = target, .start = start, .len = @intCast(data.len) }) catch {
                s.oom = true;
                break :ok;
            };
            reply.result = c.GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
        }
        if (req.reply) |f| f(wr, &reply);
    }
};

const StyleCtx = struct {
    pub fn hash(_: StyleCtx, st: engine.Style) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&st.fg));
        h.update(std.mem.asBytes(&st.bg));
        h.update(std.mem.asBytes(&st.underline_color));
        h.update(&.{@intFromEnum(st.underline)});
        h.update(std.mem.asBytes(&@as(u16, @bitCast(st.flags))));
        return h.final();
    }
    pub fn eql(_: StyleCtx, a: engine.Style, b: engine.Style) bool {
        return a.eql(b);
    }
};

fn check(r: c.GhosttyResult) Error!void {
    if (r == c.GHOSTTY_SUCCESS) return;
    // Every failure here is an allocation, or a bug in this file.
    return error.OutOfMemory;
}

fn rgba(rgb: c.GhosttyColorRgb) engine.Rgba {
    return @as(u32, rgb.r) << 24 | @as(u32, rgb.g) << 16 | @as(u32, rgb.b) << 8 | 0xff;
}

fn clampPoint(s: *State, p: engine.Point) engine.Point {
    return .{ .col = @min(p.col, s.cols - 1), .row = @min(p.row, s.rows - 1) };
}

fn modBits(m: engine.Mods) u16 {
    var b: u16 = 0;
    if (m.shift) b |= c.GHOSTTY_MODS_SHIFT;
    if (m.ctrl) b |= c.GHOSTTY_MODS_CTRL;
    if (m.alt) b |= c.GHOSTTY_MODS_ALT;
    if (m.super) b |= c.GHOSTTY_MODS_SUPER;
    return b;
}

fn namedKey(n: engine.NamedKey) c.GhosttyKey {
    return switch (n) {
        .enter => c.GHOSTTY_KEY_ENTER,
        .escape => c.GHOSTTY_KEY_ESCAPE,
        .tab => c.GHOSTTY_KEY_TAB,
        .space => c.GHOSTTY_KEY_SPACE,
        .backspace => c.GHOSTTY_KEY_BACKSPACE,
        .delete => c.GHOSTTY_KEY_DELETE,
        .insert => c.GHOSTTY_KEY_INSERT,
        .up => c.GHOSTTY_KEY_ARROW_UP,
        .down => c.GHOSTTY_KEY_ARROW_DOWN,
        .left => c.GHOSTTY_KEY_ARROW_LEFT,
        .right => c.GHOSTTY_KEY_ARROW_RIGHT,
        .home => c.GHOSTTY_KEY_HOME,
        .end => c.GHOSTTY_KEY_END,
        .pageup => c.GHOSTTY_KEY_PAGE_UP,
        .pagedown => c.GHOSTTY_KEY_PAGE_DOWN,
        .f1 => c.GHOSTTY_KEY_F1,
        .f2 => c.GHOSTTY_KEY_F2,
        .f3 => c.GHOSTTY_KEY_F3,
        .f4 => c.GHOSTTY_KEY_F4,
        .f5 => c.GHOSTTY_KEY_F5,
        .f6 => c.GHOSTTY_KEY_F6,
        .f7 => c.GHOSTTY_KEY_F7,
        .f8 => c.GHOSTTY_KEY_F8,
        .f9 => c.GHOSTTY_KEY_F9,
        .f10 => c.GHOSTTY_KEY_F10,
        .f11 => c.GHOSTTY_KEY_F11,
        .f12 => c.GHOSTTY_KEY_F12,
    };
}

/// The physical key that types `cp` on a US layout, its unshifted
/// character, and whether shift was needed. Characters off that layout
/// are UNIDENTIFIED and go by their text alone.
fn physical(cp: u21) struct { key: c.GhosttyKey, unshifted: u32 = 0, shifted: bool = false } {
    const shifted_digits = ")!@#$%^&*(";
    const punct = [_]struct { u8, u8, c.GhosttyKey }{
        .{ '`', '~', c.GHOSTTY_KEY_BACKQUOTE },    .{ '\\', '|', c.GHOSTTY_KEY_BACKSLASH },
        .{ '[', '{', c.GHOSTTY_KEY_BRACKET_LEFT }, .{ ']', '}', c.GHOSTTY_KEY_BRACKET_RIGHT },
        .{ ',', '<', c.GHOSTTY_KEY_COMMA },        .{ '=', '+', c.GHOSTTY_KEY_EQUAL },
        .{ '-', '_', c.GHOSTTY_KEY_MINUS },        .{ '.', '>', c.GHOSTTY_KEY_PERIOD },
        .{ '\'', '"', c.GHOSTTY_KEY_QUOTE },       .{ ';', ':', c.GHOSTTY_KEY_SEMICOLON },
        .{ '/', '?', c.GHOSTTY_KEY_SLASH },
    };
    switch (cp) {
        'a'...'z' => return .{ .key = keyAt(c.GHOSTTY_KEY_A, cp - 'a'), .unshifted = cp },
        'A'...'Z' => return .{ .key = keyAt(c.GHOSTTY_KEY_A, cp - 'A'), .unshifted = cp - 'A' + 'a', .shifted = true },
        '0'...'9' => return .{ .key = keyAt(c.GHOSTTY_KEY_DIGIT_0, cp - '0'), .unshifted = cp },
        ' ' => return .{ .key = c.GHOSTTY_KEY_SPACE, .unshifted = ' ' },
        else => {},
    }
    if (cp < 0x80) {
        if (std.mem.indexOfScalar(u8, shifted_digits, @intCast(cp))) |i|
            return .{ .key = keyAt(c.GHOSTTY_KEY_DIGIT_0, i), .unshifted = '0' + @as(u32, @intCast(i)), .shifted = true };
        for (punct) |p| {
            if (cp == p[0]) return .{ .key = p[2], .unshifted = p[0] };
            if (cp == p[1]) return .{ .key = p[2], .unshifted = p[0], .shifted = true };
        }
    }
    return .{ .key = c.GHOSTTY_KEY_UNIDENTIFIED };
}

fn keyAt(base: c_int, off: anytype) c.GhosttyKey {
    return @intCast(base + @as(c_int, @intCast(off)));
}
