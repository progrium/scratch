//! The stand-in engine (engine.zig, C1): enough of a terminal for tests and
//! for renderer work before libghostty-vt is in the build.
//!
//! It handles printable text (UTF-8, every character one cell wide), CR,
//! LF, BS, tab stops every 8 columns, BEL and autowrap, keeps history for
//! scrollback and selection, and has one style, the default. Escape
//! sequences (CSI, OSC, two-byte ESC) are skipped whole, so colored output
//! reads as its text. Keys are plain bytes (xterm's for the named keys).
//!
//! A few modes are kept so the core's input paths (T7) can be tested
//! without libghostty-vt: DECSET mouse tracking (1000, 1002, 1003, with
//! 1006 for SGR reports), alternate scroll (1007, though there is no
//! alternate screen), focus reports (1004) and bracketed paste (2004).
//! OSC 52 clipboard writes are reported; reads (`?`) are refused.
//!
//! Owner: T1 wrote it; the engine backends (T2) may extend it.

const std = @import("std");
const engine = @import("engine.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Error = engine.Error;

const blank: u21 = 0;
const default_styles = [_]engine.Style{.{}};

pub const Plain = struct {
    gpa: Allocator,
    cols: u16,
    rows: u16,
    cell_w_px: u16 = 0,
    cell_h_px: u16 = 0,
    scrollback: u32,

    /// rows * cols cells, row-major; `blank` is an empty cell.
    screen: []u21,
    /// History lines, oldest first once `hist_head` is applied: a ring
    /// when full. Each line is as wide as the screen was when it left it.
    hist: std.ArrayList([]u21) = .empty,
    hist_head: usize = 0,
    /// Lines ever scrolled off the top: the screen's row 0 is absolute
    /// line `base`. Selections are kept in absolute lines.
    base: u64 = 0,
    /// Lines the view is scrolled back.
    offset: u32 = 0,

    x: u16 = 0,
    y: u16 = 0,
    pending_wrap: bool = false,

    parse: enum { ground, esc, csi, osc, osc_esc } = .ground,
    utf8: [4]u8 = undefined,
    utf8_have: u3 = 0,
    utf8_need: u3 = 0,

    dirty_rows: []bool,
    dirty_all: bool = true,
    dirty_size: bool = false,
    last_cursor: engine.Cursor = .{},

    sel: ?struct { a: Abs, b: Abs } = null,
    bell: u32 = 0,

    /// A CSI's parameter bytes, for DECSET and DECRST; longer ones are
    /// skipped.
    csi: [32]u8 = undefined,
    csi_len: u8 = 0,
    /// An OSC's body, up to `osc_cap`.
    osc: std.ArrayList(u8) = .empty,
    osc_over: bool = false,
    md: Md = .{},
    /// OSC 52 writes since the last takeEvents: targets and decoded text.
    clips: std.ArrayList(struct { target: u8, start: u32, len: u32 }) = .empty,
    clip_buf: std.ArrayList(u8) = .empty,

    const osc_cap = 1 << 20;

    const Md = struct {
        mouse: enum { off, normal, button, any } = .off,
        sgr: bool = false,
        alt_scroll: bool = false,
        focus: bool = false,
        paste: bool = false,
    };

    const Abs = struct { line: u64, col: u16 };

    pub fn init(gpa: Allocator, opts: engine.Opts) Error!Plain {
        const cols = @max(opts.cols, 1);
        const rows = @max(opts.rows, 1);
        const screen = try gpa.alloc(u21, @as(usize, cols) * rows);
        errdefer gpa.free(screen);
        @memset(screen, blank);
        const dirty = try gpa.alloc(bool, rows);
        @memset(dirty, false);
        return .{ .gpa = gpa, .cols = cols, .rows = rows, .scrollback = opts.scrollback, .screen = screen, .dirty_rows = dirty };
    }

    pub fn deinit(p: *Plain) void {
        p.clearHistory();
        p.hist.deinit(p.gpa);
        p.osc.deinit(p.gpa);
        p.clips.deinit(p.gpa);
        p.clip_buf.deinit(p.gpa);
        p.gpa.free(p.screen);
        p.gpa.free(p.dirty_rows);
        p.* = undefined;
    }

    fn clearHistory(p: *Plain) void {
        for (p.hist.items) |l| p.gpa.free(l);
        p.hist.clearRetainingCapacity();
        p.hist_head = 0;
    }

    // ------------------------------------------------------------ output

    pub fn feed(p: *Plain, bytes: []const u8) Error!void {
        if (p.offset != 0) {
            p.offset = 0;
            p.dirty_all = true;
        }
        for (bytes) |b| try p.byte(b);
    }

    fn byte(p: *Plain, b: u8) Error!void {
        switch (p.parse) {
            .esc => {
                p.parse = switch (b) {
                    '[' => .csi,
                    ']' => .osc,
                    else => .ground,
                };
                p.csi_len = 0;
                p.osc.clearRetainingCapacity();
                p.osc_over = false;
                return;
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7e) {
                    p.parse = .ground;
                    p.csiDone(b);
                } else if (p.csi_len < p.csi.len) {
                    p.csi[p.csi_len] = b;
                    p.csi_len += 1;
                } else p.csi_len = p.csi.len; // too long: ignored at the end
                return;
            },
            .osc => {
                if (b == 0x07 or b == 0x1b) {
                    p.parse = if (b == 0x07) .ground else .osc_esc;
                    try p.oscDone();
                } else if (!p.osc_over) {
                    if (p.osc.items.len >= osc_cap) {
                        p.osc_over = true;
                    } else try p.osc.append(p.gpa, b);
                }
                return;
            },
            .osc_esc => {
                p.parse = .ground;
                return;
            },
            .ground => {},
        }
        if (p.utf8_need > 0) {
            if (b & 0xc0 != 0x80) {
                p.utf8_need = 0;
                try p.print(std.unicode.replacement_character);
                return p.byte(b);
            }
            p.utf8[p.utf8_have] = b;
            p.utf8_have += 1;
            if (p.utf8_have < p.utf8_need) return;
            const cp = std.unicode.utf8Decode(p.utf8[0..p.utf8_have]) catch std.unicode.replacement_character;
            p.utf8_need = 0;
            return p.print(cp);
        }
        switch (b) {
            0x1b => p.parse = .esc,
            0x07 => p.bell += 1,
            0x08 => {
                p.pending_wrap = false;
                if (p.x > 0) p.x -= 1;
            },
            '\t' => {
                p.pending_wrap = false;
                p.x = @min(p.cols - 1, (p.x / 8 + 1) * 8);
            },
            '\n', 0x0b, 0x0c => try p.lineFeed(),
            '\r' => {
                p.pending_wrap = false;
                p.x = 0;
            },
            0x00...0x06, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
            0x20...0x7e => try p.print(b),
            0x80...0xff => {
                const n = std.unicode.utf8ByteSequenceLength(b) catch return p.print(std.unicode.replacement_character);
                p.utf8[0] = b;
                p.utf8_have = 1;
                p.utf8_need = @intCast(n);
            },
        }
    }

    /// DECSET and DECRST of the modes kept (above); every other CSI is
    /// skipped.
    fn csiDone(p: *Plain, final: u8) void {
        if (final != 'h' and final != 'l') return;
        if (p.csi_len == 0 or p.csi_len >= p.csi.len or p.csi[0] != '?') return;
        const on = final == 'h';
        var it = std.mem.splitScalar(u8, p.csi[1..p.csi_len], ';');
        while (it.next()) |f| {
            const n = std.fmt.parseInt(u16, f, 10) catch continue;
            switch (n) {
                1000 => p.md.mouse = if (on) .normal else .off,
                1002 => p.md.mouse = if (on) .button else .off,
                1003 => p.md.mouse = if (on) .any else .off,
                1006 => p.md.sgr = on,
                1007 => p.md.alt_scroll = on,
                1004 => p.md.focus = on,
                2004 => p.md.paste = on,
                else => {},
            }
        }
    }

    /// OSC 52 (`52;TARGETS;BASE64`): a clipboard write. Other OSCs are
    /// skipped.
    fn oscDone(p: *Plain) Error!void {
        defer p.osc.clearRetainingCapacity();
        if (p.osc_over) return;
        const body = p.osc.items;
        if (!std.mem.startsWith(u8, body, "52;")) return;
        const rest = body[3..];
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return;
        const targets = rest[0..semi];
        const data = rest[semi + 1 ..];
        if (std.mem.eql(u8, data, "?")) return;
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(data) catch return;
        const start = p.clip_buf.items.len;
        try p.clip_buf.resize(p.gpa, start + n);
        dec.decode(p.clip_buf.items[start..], data) catch {
            p.clip_buf.shrinkRetainingCapacity(start);
            return;
        };
        try p.clips.append(p.gpa, .{
            .target = if (targets.len > 0) targets[0] else 's',
            .start = @intCast(start),
            .len = @intCast(n),
        });
    }

    fn print(p: *Plain, cp: u21) Error!void {
        if (p.pending_wrap) {
            p.pending_wrap = false;
            p.x = 0;
            try p.lineFeed();
        }
        p.screen[@as(usize, p.y) * p.cols + p.x] = cp;
        p.dirty_rows[p.y] = true;
        if (p.x + 1 >= p.cols) p.pending_wrap = true else p.x += 1;
    }

    fn lineFeed(p: *Plain) Error!void {
        if (p.y + 1 < p.rows) {
            p.y += 1;
            return;
        }
        try p.scrollUp(1);
    }

    /// Moves the top `n` screen rows into history.
    fn scrollUp(p: *Plain, n: u16) Error!void {
        const cols: usize = p.cols;
        for (0..n) |i| try p.pushHistory(p.screen[i * cols ..][0..cols]);
        const keep = (@as(usize, p.rows) - n) * cols;
        std.mem.copyForwards(u21, p.screen[0..keep], p.screen[n * cols ..][0..keep]);
        @memset(p.screen[keep..], blank);
        p.base += n;
        p.dirty_all = true;
    }

    fn pushHistory(p: *Plain, cells: []const u21) Error!void {
        if (p.scrollback == 0) return;
        var end = cells.len;
        while (end > 0 and cells[end - 1] == blank) end -= 1;
        const copy = try p.gpa.dupe(u21, cells[0..end]);
        if (p.hist.items.len < p.scrollback) {
            p.hist.append(p.gpa, copy) catch |e| {
                p.gpa.free(copy);
                return e;
            };
            return;
        }
        p.gpa.free(p.hist.items[p.hist_head]);
        p.hist.items[p.hist_head] = copy;
        p.hist_head = (p.hist_head + 1) % p.hist.items.len;
    }

    /// The cells of absolute line `abs`: a screen row or a history line,
    /// shorter than `cols` for history; empty when it fell out of history.
    fn line(p: *const Plain, abs: u64) []const u21 {
        if (abs >= p.base) {
            const r = abs - p.base;
            if (r >= p.rows) return &.{};
            return p.screen[@as(usize, @intCast(r)) * p.cols ..][0..p.cols];
        }
        const back = p.base - abs; // 1 is the newest history line
        if (back > p.hist.items.len) return &.{};
        const i: usize = p.hist.items.len - @as(usize, @intCast(back));
        return p.hist.items[(p.hist_head + i) % p.hist.items.len];
    }

    /// The absolute line viewport row `y` shows.
    fn viewLine(p: *const Plain, y: u16) u64 {
        return p.base - p.offset + y;
    }

    // ------------------------------------------------------------ size

    pub fn resize(p: *Plain, s: engine.Size) Error!void {
        const cols = @max(s.cols, 1);
        const rows = @max(s.rows, 1);
        p.cell_w_px = s.cell_w_px;
        p.cell_h_px = s.cell_h_px;
        if (cols == p.cols and rows == p.rows) return;
        // Keep the cursor's row on screen: what falls off the top goes to
        // history, as when a terminal window gets shorter.
        if (p.y >= rows) {
            const n = p.y - rows + 1;
            try p.scrollUp(n);
            p.y -= n;
        }
        const screen = try p.gpa.alloc(u21, @as(usize, cols) * rows);
        @memset(screen, blank);
        const dirty = p.gpa.alloc(bool, rows) catch |e| {
            p.gpa.free(screen);
            return e;
        };
        @memset(dirty, false);
        for (0..@min(rows, p.rows)) |r| {
            const w = @min(cols, p.cols);
            @memcpy(screen[r * cols ..][0..w], p.screen[r * p.cols ..][0..w]);
        }
        p.gpa.free(p.screen);
        p.gpa.free(p.dirty_rows);
        p.screen = screen;
        p.dirty_rows = dirty;
        p.cols = cols;
        p.rows = rows;
        p.x = @min(p.x, cols - 1);
        p.y = @min(p.y, rows - 1);
        p.pending_wrap = false;
        p.dirty_all = true;
        p.dirty_size = true;
    }

    pub fn size(p: *const Plain) engine.Size {
        return .{ .cols = p.cols, .rows = p.rows, .cell_w_px = p.cell_w_px, .cell_h_px = p.cell_h_px };
    }

    pub fn reset(p: *Plain) void {
        @memset(p.screen, blank);
        p.clearHistory();
        p.base = 0;
        p.offset = 0;
        p.x = 0;
        p.y = 0;
        p.pending_wrap = false;
        p.parse = .ground;
        p.utf8_need = 0;
        p.sel = null;
        p.md = .{};
        p.csi_len = 0;
        p.osc.clearRetainingCapacity();
        p.dirty_all = true;
    }

    // ------------------------------------------------------------ reading

    pub fn takeDirty(p: *Plain, out: *engine.Dirty) Error!void {
        out.clear();
        if (p.dirty_all) {
            out.all = true;
        } else for (p.dirty_rows, 0..) |d, r| if (d) try out.rows.append(p.gpa, @intCast(r));
        @memset(p.dirty_rows, false);
        p.dirty_all = false;
        out.size = p.dirty_size;
        p.dirty_size = false;
        const c = p.cursor();
        out.cursor = out.all or !std.meta.eql(c, p.last_cursor);
        p.last_cursor = c;
    }

    pub fn row(p: *Plain, y: u16, out: *engine.Row) Error!void {
        out.clear();
        if (y >= p.rows) return;
        const abs = p.viewLine(y);
        const cells = p.line(abs);
        var end = cells.len;
        while (end > 0 and cells[end - 1] == blank) end -= 1;
        // A selection past the text still shows, as blank selected cells.
        if (p.selSpan(abs)) |s| end = @max(end, @min(@as(usize, s.hi) + 1, p.cols));
        var col: usize = 0;
        while (col < end) {
            const sel = p.isSelected(abs, @intCast(col));
            var stop = col + 1;
            while (stop < end and p.isSelected(abs, @intCast(stop)) == sel) stop += 1;
            var buf: [4]u8 = undefined;
            const start: u32 = @intCast(out.text.items.len);
            for (col..stop) |cx| {
                const cp = if (cx < cells.len and cells[cx] != blank) cells[cx] else ' ';
                try out.text.appendSlice(p.gpa, utf8(cp, &buf));
            }
            try out.runs.append(p.gpa, .{
                .col = @intCast(col),
                .width = @intCast(stop - col),
                .style = 0,
                .start = start,
                .len = @as(u32, @intCast(out.text.items.len)) - start,
                .selected = sel,
            });
            col = stop;
        }
    }

    pub fn styles(_: *Plain) []const engine.Style {
        return &default_styles;
    }

    pub fn cursor(p: *Plain) engine.Cursor {
        const vy = @as(u32, p.y) + p.offset;
        if (vy >= p.rows) return .{ .x = p.x, .y = 0, .visible = false };
        return .{ .x = p.x, .y = @intCast(vy) };
    }

    pub fn modes(p: *Plain) engine.Modes {
        return .{
            .mouse = p.md.mouse != .off,
            .alt_scroll = p.md.alt_scroll,
            .bracketed_paste = p.md.paste,
            .focus_reports = p.md.focus,
        };
    }

    // ------------------------------------------------------------ input

    pub fn encodeKey(_: *Plain, k: engine.Key, w: *Writer) Writer.Error!bool {
        if (k.mods.super) return false;
        switch (k.code) {
            .char => |cp| {
                var c = cp;
                if (k.mods.ctrl) c = ctrlOf(cp) orelse return false;
                if (k.mods.alt) try w.writeByte(0x1b);
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return false;
                try w.writeAll(buf[0..n]);
                return true;
            },
            .named => |n| {
                const m = k.mods;
                const mod_param: u8 = 1 + @as(u8, @intFromBool(m.shift)) + 2 * @as(u8, @intFromBool(m.alt)) + 4 * @as(u8, @intFromBool(m.ctrl));
                switch (n) {
                    .up, .down, .right, .left, .home, .end => {
                        const final: u8 = switch (n) {
                            .up => 'A',
                            .down => 'B',
                            .right => 'C',
                            .left => 'D',
                            .home => 'H',
                            .end => 'F',
                            else => unreachable,
                        };
                        if (mod_param == 1) try w.print("\x1b[{c}", .{final}) else try w.print("\x1b[1;{d}{c}", .{ mod_param, final });
                    },
                    .insert, .delete, .pageup, .pagedown, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => {
                        const code: u8 = switch (n) {
                            .insert => 2,
                            .delete => 3,
                            .pageup => 5,
                            .pagedown => 6,
                            .f5 => 15,
                            .f6 => 17,
                            .f7 => 18,
                            .f8 => 19,
                            .f9 => 20,
                            .f10 => 21,
                            .f11 => 23,
                            .f12 => 24,
                            else => unreachable,
                        };
                        if (mod_param == 1) try w.print("\x1b[{d}~", .{code}) else try w.print("\x1b[{d};{d}~", .{ code, mod_param });
                    },
                    .f1, .f2, .f3, .f4 => {
                        const final: u8 = 'P' + @as(u8, @intCast(@intFromEnum(n) - @intFromEnum(engine.NamedKey.f1)));
                        if (mod_param == 1) try w.print("\x1bO{c}", .{final}) else try w.print("\x1b[1;{d}{c}", .{ mod_param, final });
                    },
                    .enter, .escape, .space, .backspace => {
                        if (m.alt) try w.writeByte(0x1b);
                        try w.writeByte(switch (n) {
                            .enter => '\r',
                            .escape => 0x1b,
                            .space => if (m.ctrl) 0 else ' ',
                            .backspace => if (m.ctrl) 0x08 else 0x7f,
                            else => unreachable,
                        });
                    },
                    .tab => try w.writeAll(if (m.shift) "\x1b[Z" else "\t"),
                }
                return true;
            },
        }
    }

    pub fn encodeText(_: *Plain, text: []const u8, w: *Writer) Writer.Error!void {
        try w.writeAll(text);
    }

    /// xterm's reports: SGR (`ESC [ < B ; X ; Y M`) under 1006, else the
    /// X10 bytes. A move is reported only with a button held (1002) or
    /// always (1003); under 1000 it is taken but sends nothing.
    pub fn encodeMouse(p: *Plain, m: engine.Mouse, w: *Writer) Writer.Error!bool {
        const mode = p.md.mouse;
        if (mode == .off) return false;
        const wheel = m.button == .wheel_up or m.button == .wheel_down;
        switch (m.action) {
            .move => switch (mode) {
                .off, .normal => return true,
                .button => if (m.button == .none) return true,
                .any => {},
            },
            .release => if (wheel) return true,
            .press => {},
        }
        var cb: u32 = switch (m.button) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .none => 3,
            .wheel_up => 64,
            .wheel_down => 65,
        };
        if (m.action == .release and !p.md.sgr) cb = 3;
        if (m.action == .move) cb += 32;
        if (m.mods.shift) cb += 4;
        if (m.mods.alt) cb += 8;
        if (m.mods.ctrl) cb += 16;
        const x = @as(u32, m.col) + 1;
        const y = @as(u32, m.row) + 1;
        if (p.md.sgr) {
            try w.print("\x1b[<{d};{d};{d}{c}", .{ cb, x, y, @as(u8, if (m.action == .release) 'm' else 'M') });
        } else {
            try w.writeAll("\x1b[M");
            for ([_]u32{ cb, x, y }) |v| try w.writeByte(@intCast(@min(v + 32, 255)));
        }
        return true;
    }

    /// Bracketed under 2004, as is, with any end marker in the text taken
    /// out; otherwise newlines become CR, as a terminal sends Enter.
    pub fn encodePaste(p: *Plain, text: []const u8, w: *Writer) Writer.Error!void {
        if (p.md.paste) {
            try w.writeAll("\x1b[200~");
            var rest = text;
            while (std.mem.indexOf(u8, rest, "\x1b[201~")) |i| {
                try w.writeAll(rest[0..i]);
                rest = rest[i + 6 ..];
            }
            try w.writeAll(rest);
            return w.writeAll("\x1b[201~");
        }
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
            try w.writeByte(if (text[i] == '\n') '\r' else text[i]);
        }
    }

    pub fn encodeFocus(p: *Plain, in: bool, w: *Writer) Writer.Error!void {
        if (p.md.focus) try w.writeAll(if (in) "\x1b[I" else "\x1b[O");
    }

    // ------------------------------------------------------------ view

    pub fn scroll(p: *Plain, s: engine.Scroll) void {
        const max: i64 = @intCast(p.hist.items.len);
        const want: i64 = switch (s) {
            .top => max,
            .bottom => 0,
            .lines => |n| @as(i64, p.offset) - n,
        };
        const o: u32 = @intCast(std.math.clamp(want, 0, max));
        if (o != p.offset) p.dirty_all = true;
        p.offset = o;
    }

    pub fn select(p: *Plain, s: engine.Selection) void {
        if (p.sel != null) p.dirty_all = true;
        p.sel = null;
        const r = switch (s) {
            .none => return,
            .range => |r| r,
        };
        var a: Abs = .{ .line = p.viewLine(@min(r.start.row, p.rows - 1)), .col = @min(r.start.col, p.cols - 1) };
        var b: Abs = .{ .line = p.viewLine(@min(r.end.row, p.rows - 1)), .col = @min(r.end.col, p.cols - 1) };
        if (b.line < a.line or (b.line == a.line and b.col < a.col)) std.mem.swap(Abs, &a, &b);
        switch (r.unit) {
            .cells => {},
            .lines => {
                a.col = 0;
                b.col = p.cols - 1;
            },
            .words => {
                const la = p.line(a.line);
                while (a.col > 0 and isWord(at(la, a.col - 1)) and isWord(at(la, a.col))) a.col -= 1;
                const lb = p.line(b.line);
                while (b.col + 1 < p.cols and isWord(at(lb, b.col + 1)) and isWord(at(lb, b.col))) b.col += 1;
            },
        }
        p.sel = .{ .a = a, .b = b };
        p.dirty_all = true;
    }

    fn selSpan(p: *const Plain, abs: u64) ?struct { lo: u16, hi: u16 } {
        const s = p.sel orelse return null;
        if (abs < s.a.line or abs > s.b.line) return null;
        return .{ .lo = if (abs == s.a.line) s.a.col else 0, .hi = if (abs == s.b.line) s.b.col else p.cols - 1 };
    }

    fn isSelected(p: *const Plain, abs: u64, col: u16) bool {
        const s = p.selSpan(abs) orelse return false;
        return col >= s.lo and col <= s.hi;
    }

    pub fn screenText(p: *Plain, w: *Writer) Writer.Error!void {
        var last: ?u16 = null;
        for (0..p.rows) |y| {
            if (trimmed(p.line(p.viewLine(@intCast(y)))).len > 0) last = @intCast(y);
        }
        const n = if (last) |l| l + 1 else 0;
        for (0..n) |y| {
            try writeCells(w, trimmed(p.line(p.viewLine(@intCast(y)))));
            try w.writeByte('\n');
        }
    }

    pub fn selectionText(p: *Plain, w: *Writer) Writer.Error!void {
        const s = p.sel orelse return;
        var abs = s.a.line;
        while (abs <= s.b.line) : (abs += 1) {
            const cells = p.line(abs);
            const span = p.selSpan(abs).?;
            const lo = @min(span.lo, cells.len);
            const hi = @min(@as(usize, span.hi) + 1, cells.len);
            if (abs != s.a.line) try w.writeByte('\n');
            try writeCells(w, trimmed(cells[lo..@max(lo, hi)]));
        }
    }

    pub fn takeEvents(p: *Plain, out: *engine.Events) Error!void {
        out.clear();
        out.bell = p.bell;
        p.bell = 0;
        for (p.clips.items) |c| {
            const span = try out.put(p.gpa, p.clip_buf.items[c.start..][0..c.len]);
            try out.clips.append(p.gpa, .{ .target = c.target, .data = span });
        }
        p.clips.clearRetainingCapacity();
        p.clip_buf.clearRetainingCapacity();
    }
};

fn ctrlOf(cp: u21) ?u21 {
    return switch (cp) {
        'a'...'z' => cp - 'a' + 1,
        'A'...'Z' => cp - 'A' + 1,
        '@', ' ', '2' => 0,
        '[', '3' => 0x1b,
        '\\', '4' => 0x1c,
        ']', '5' => 0x1d,
        '^', '6' => 0x1e,
        '_', '-', '7' => 0x1f,
        '?', '8' => 0x7f,
        else => null,
    };
}

fn at(cells: []const u21, col: u16) u21 {
    return if (col < cells.len) cells[col] else blank;
}

fn isWord(cp: u21) bool {
    return cp != blank and cp != ' ' and cp != '\t';
}

fn trimmed(cells: []const u21) []const u21 {
    var end = cells.len;
    while (end > 0 and (cells[end - 1] == blank or cells[end - 1] == ' ')) end -= 1;
    return cells[0..end];
}

fn writeCells(w: *Writer, cells: []const u21) Writer.Error!void {
    var buf: [4]u8 = undefined;
    for (cells) |cp| try w.writeAll(utf8(if (cp == blank) ' ' else cp, &buf));
}

fn utf8(cp: u21, buf: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(cp, buf) catch return "\u{fffd}";
    return buf[0..n];
}

// ---------------------------------------------------------------- tests

const tt = std.testing;

fn screenOf(p: *Plain) ![]u8 {
    var aw: Writer.Allocating = .init(tt.allocator);
    errdefer aw.deinit();
    try p.screenText(&aw.writer);
    return aw.toOwnedSlice();
}

fn expectScreen(p: *Plain, want: []const u8) !void {
    const got = try screenOf(p);
    defer tt.allocator.free(got);
    try tt.expectEqualStrings(want, got);
}

fn keyBytes(p: *Plain, stroke: []const u8) ![]u8 {
    var aw: Writer.Allocating = .init(tt.allocator);
    errdefer aw.deinit();
    if (!try p.encodeKey(engine.parseStroke(stroke, .ctrl).?, &aw.writer)) {
        aw.deinit();
        return error.NoBytes;
    }
    return aw.toOwnedSlice();
}

test "text, CR, LF, BS, tab" {
    var p: Plain = try .init(tt.allocator, .{ .cols = 20, .rows = 4 });
    defer p.deinit();
    try p.feed("hi\r\nthere\x08\x08ir\r\na\tb\r\n");
    try expectScreen(&p, "hi\ntheir\na       b\n");
    try tt.expectEqual(@as(u16, 0), p.cursor().x);
    try tt.expectEqual(@as(u16, 3), p.cursor().y);
}

test "escape sequences are skipped, UTF-8 is decoded" {
    var p: Plain = try .init(tt.allocator, .{ .cols = 20, .rows = 2 });
    defer p.deinit();
    try p.feed("\x1b[1;31mred\x1b[0m \x1b]0;title\x07caf\xc3\xa9 \x1b]2;t\x1b\\ok\x1b=");
    try expectScreen(&p, "red café ok\n");
    var row: engine.Row = .{};
    defer row.deinit(tt.allocator);
    try p.row(0, &row);
    try tt.expectEqual(@as(usize, 1), row.runs.items.len);
    try tt.expectEqual(@as(u16, 11), row.runs.items[0].width);
    try tt.expectEqualStrings("red café ok", row.runText(row.runs.items[0]));
}

test "autowrap, scrolling into history, and scrollback" {
    var p: Plain = try .init(tt.allocator, .{ .cols = 4, .rows = 2, .scrollback = 2 });
    defer p.deinit();
    try p.feed("abcdefgh\r\n1\r\n2\r\n3");
    try expectScreen(&p, "2\n3\n");
    try tt.expectEqual(@as(usize, 2), p.hist.items.len);
    p.scroll(.top);
    try expectScreen(&p, "efgh\n1\n");
    try tt.expect(!p.cursor().visible);
    p.scroll(.{ .lines = 1 });
    try expectScreen(&p, "1\n2\n");
    p.scroll(.{ .lines = -10 });
    try expectScreen(&p, "efgh\n1\n");
    try p.feed("4");
    try expectScreen(&p, "2\n34\n");
    try tt.expect(p.cursor().visible);
}

test "dirty rows, cursor and size" {
    var p: Plain = try .init(tt.allocator, .{ .cols = 10, .rows = 3 });
    defer p.deinit();
    var d: engine.Dirty = .{};
    defer d.deinit(tt.allocator);
    try p.takeDirty(&d);
    try tt.expect(d.all and d.cursor);
    try p.takeDirty(&d);
    try tt.expect(!d.any());
    try p.feed("\r\nx");
    try p.takeDirty(&d);
    try tt.expectEqualSlices(u16, &.{1}, d.rows.items);
    try tt.expect(d.cursor and !d.all and d.styles == .same);
    try p.resize(.{ .cols = 5, .rows = 2, .cell_w_px = 8, .cell_h_px = 16 });
    try p.takeDirty(&d);
    try tt.expect(d.all and d.size);
    try tt.expectEqual(engine.Size{ .cols = 5, .rows = 2, .cell_w_px = 8, .cell_h_px = 16 }, p.size());
    try expectScreen(&p, "\nx\n");
}

test "shrinking keeps the cursor row on screen" {
    var p: Plain = try .init(tt.allocator, .{ .cols = 10, .rows = 4 });
    defer p.deinit();
    try p.feed("a\r\nb\r\nc\r\nd");
    try p.resize(.{ .cols = 10, .rows = 2 });
    try expectScreen(&p, "c\nd\n");
    p.scroll(.top);
    try expectScreen(&p, "a\nb\n");
}

test "keys as plain bytes" {
    var p: Plain = try .init(tt.allocator, .{});
    defer p.deinit();
    const cases = .{
        .{ "a", "a" },            .{ "A", "A" },               .{ "ctrl-c", "\x03" },
        .{ "alt-x", "\x1bx" },    .{ "enter", "\r" },          .{ "backspace", "\x7f" },
        .{ "up", "\x1b[A" },      .{ "ctrl-up", "\x1b[1;5A" }, .{ "shift-tab", "\x1b[Z" },
        .{ "pageup", "\x1b[5~" }, .{ "f1", "\x1bOP" },         .{ "f5", "\x1b[15~" },
        .{ "é", "é" },
        .{ "space", " " },        .{ "ctrl-space", "\x00" },
    };
    inline for (cases) |c| {
        const got = try keyBytes(&p, c[0]);
        defer tt.allocator.free(got);
        tt.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("key {s}\n", .{c[0]});
            return e;
        };
    }
    try tt.expectError(error.NoBytes, keyBytes(&p, "super-c"));
    try tt.expectError(error.NoBytes, keyBytes(&p, "ctrl-é"));
    var aw: Writer.Allocating = .init(tt.allocator);
    defer aw.deinit();
    try tt.expect(!try p.encodeMouse(.{ .action = .press, .button = .left, .col = 0, .row = 0 }, &aw.writer));
    try p.encodePaste("a\nb\r\nc", &aw.writer);
    try tt.expectEqualStrings("a\rb\rc", aw.written());
}

test "selection: cells, words, lines, and the text" {
    var p: Plain = try .init(tt.allocator, .{ .cols = 20, .rows = 3 });
    defer p.deinit();
    try p.feed("hello big world\r\nsecond line");
    p.select(.{ .range = .{ .start = .{ .col = 8, .row = 0 }, .end = .{ .col = 1, .row = 0 } } });
    var aw: Writer.Allocating = .init(tt.allocator);
    defer aw.deinit();
    try p.selectionText(&aw.writer);
    try tt.expectEqualStrings("ello big", aw.written());

    var row: engine.Row = .{};
    defer row.deinit(tt.allocator);
    try p.row(0, &row);
    try tt.expectEqual(@as(usize, 3), row.runs.items.len);
    try tt.expectEqualStrings("h", row.runText(row.runs.items[0]));
    try tt.expect(row.runs.items[1].selected);
    try tt.expectEqual(@as(u16, 1), row.runs.items[1].col);
    try tt.expectEqual(@as(u16, 8), row.runs.items[1].width);
    try tt.expectEqualStrings(" world", row.runText(row.runs.items[2]));

    p.select(.{ .range = .{ .start = .{ .col = 7, .row = 0 }, .end = .{ .col = 2, .row = 1 }, .unit = .words } });
    aw.clearRetainingCapacity();
    try p.selectionText(&aw.writer);
    try tt.expectEqualStrings("big world\nsecond", aw.written());

    p.select(.{ .range = .{ .start = .{ .col = 3, .row = 1 }, .end = .{ .col = 3, .row = 1 }, .unit = .lines } });
    aw.clearRetainingCapacity();
    try p.selectionText(&aw.writer);
    try tt.expectEqualStrings("second line", aw.written());

    // The selection is pinned to the text as it scrolls.
    try p.feed("\r\n\r\nnew");
    aw.clearRetainingCapacity();
    try p.selectionText(&aw.writer);
    try tt.expectEqualStrings("second line", aw.written());

    p.select(.none);
    aw.clearRetainingCapacity();
    try p.selectionText(&aw.writer);
    try tt.expectEqualStrings("", aw.written());
}

test "bell, reset" {
    var p: Plain = try .init(tt.allocator, .{ .cols = 10, .rows = 2 });
    defer p.deinit();
    try p.feed("a\x07\x07");
    var ev: engine.Events = .{};
    defer ev.deinit(tt.allocator);
    try p.takeEvents(&ev);
    try tt.expectEqual(@as(u32, 2), ev.bell);
    try p.takeEvents(&ev);
    try tt.expect(!ev.any());
    p.reset();
    try expectScreen(&p, "");
    try tt.expectEqual(@as(u16, 0), p.cursor().x);
}
