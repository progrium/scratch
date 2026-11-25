//! C1, the terminal engine interface: the only place the core touches a VT
//! library. Everything else in the core (the `terminal` node, the C ABI's
//! uit_term_* calls, the render stream's `term` records) calls this.
//!
//! Owner: the terminal contracts (T1). Frozen: a change is a PR to this
//! file, announced to the engine (T2), tree (T3) and renderer (T4, T5)
//! work, as uitcore.h's ABI bumps are.
//!
//! Two backends, picked at compile time:
//!
//!   plain.zig    a stand-in: printable text, CR, LF, BS, tab and BEL, one
//!                default style, keys as plain bytes. Builds anywhere.
//!   ghostty.zig  libghostty-vt's C API (ghostty/vt.h), T2.
//!
//! `-Dterminal=plain|ghostty` picks one, through `build_options.terminal`
//! (a string or an enum with those tag names). Without the option the core
//! builds with `plain`, so nothing here needs the second Zig toolchain.
//!
//! **Threads.** An engine belongs to the core's owner thread: every call
//! comes from it, in a pump. Nothing here blocks or does I/O.
//!
//! **Coordinates.** Columns and rows count from 0 at the top left of the
//! viewport: what the renderer draws, scrolled back or not. A row is
//! `0..rows-1` of that view. Selections take viewport points too, and the
//! engine pins them to the text, so they move with it as output scrolls.
//!
//! **Lifetimes.** Slices an engine returns (`styles`) are valid until its
//! next `feed`, `resize`, `reset` or `deinit`. Out-params (`Dirty`, `Row`,
//! `Events`) are the caller's: an engine clears them and fills them with
//! the allocator it was made with, and the caller frees them with the same
//! allocator (`deinit(gpa)`) when done.

const std = @import("std");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Backend = enum { plain, ghostty };

/// The backend this core is built with.
pub const backend: Backend = blk: {
    if (!@hasDecl(build_options, "terminal")) break :blk .plain;
    const v = build_options.terminal;
    const name: []const u8 = if (@typeInfo(@TypeOf(v)) == .@"enum") @tagName(v) else v;
    break :blk std.meta.stringToEnum(Backend, name) orelse
        @compileError("-Dterminal must be plain or ghostty, not " ++ name);
};

pub const plain = @import("plain.zig");

/// The engine type every caller uses.
pub const Engine = switch (backend) {
    .plain => plain.Plain,
    .ghostty => @import("ghostty.zig").Ghostty,
};

comptime {
    conform(plain.Plain);
    conform(Engine);
}

pub const Error = error{OutOfMemory};

// ---------------------------------------------------------------- types

pub const Opts = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    /// Lines of history kept above the screen (the node's `scrollback`).
    scrollback: u32 = 10_000,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
    /// One cell in device pixels, for programs that ask (XTWINOPS, kitty
    /// graphics). 0 when the renderer doesn't know (a text terminal).
    cell_w_px: u16 = 0,
    cell_h_px: u16 = 0,
};

/// 0xRRGGBBAA. 0 (alpha 0) means "the default": the theme's `foreground`
/// for `fg`, no fill (the node's own background shows) for `bg`, and the
/// cell's foreground for `underline_color`. The engine resolves the 256
/// palette and true color to RGBA; the renderer never sees an index.
pub const Rgba = u32;

pub const Underline = enum(u8) { none = 0, single = 1, double = 2, curly = 3, dotted = 4, dashed = 5 };

pub const Flags = packed struct(u16) {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    /// Swap fg and bg when drawing. The engine does not swap them itself.
    inverse: bool = false,
    strike: bool = false,
    blink: bool = false,
    /// Draw the background only.
    invisible: bool = false,
    overline: bool = false,
    _pad: u8 = 0,
};

/// One entry of a terminal's style table. Id 0 is always the default
/// style (all zero).
pub const Style = struct {
    fg: Rgba = 0,
    bg: Rgba = 0,
    underline_color: Rgba = 0,
    underline: Underline = .none,
    flags: Flags = .{},

    pub fn eql(a: Style, b: Style) bool {
        return a.fg == b.fg and a.bg == b.bg and a.underline_color == b.underline_color and
            a.underline == b.underline and @as(u16, @bitCast(a.flags)) == @as(u16, @bitCast(b.flags));
    }
};

pub const CursorShape = enum(u8) { block = 0, bar = 1, underline = 2, block_hollow = 3 };

pub const Cursor = struct {
    /// Viewport cell. Meaningless when `visible` is false.
    x: u16 = 0,
    y: u16 = 0,
    shape: CursorShape = .block,
    /// False when the program hid it (DECTCEM) or the view is scrolled
    /// back past it.
    visible: bool = true,
    blink: bool = false,
};

/// A run of cells in one row with one style, in column order. Runs never
/// overlap. Cells no run covers are blank in style 0; a row's trailing
/// blank default cells have no run.
pub const Run = struct {
    col: u16,
    /// Cells the run covers. A wide character counts 2; its text is still
    /// one character. Equal to the text's character count for narrow text.
    width: u16,
    style: u32,
    /// The run's UTF-8 text: `Row.text[start..][0..len]`.
    start: u32,
    len: u32,
    /// Inside the selection. The engine splits runs at its edges.
    selected: bool = false,
};

pub const Row = struct {
    runs: std.ArrayList(Run) = .empty,
    text: std.ArrayList(u8) = .empty,

    pub fn clear(r: *Row) void {
        r.runs.clearRetainingCapacity();
        r.text.clearRetainingCapacity();
    }
    pub fn deinit(r: *Row, gpa: Allocator) void {
        r.runs.deinit(gpa);
        r.text.deinit(gpa);
    }
    pub fn runText(r: *const Row, run: Run) []const u8 {
        return r.text.items[run.start..][0..run.len];
    }
    /// Appends a run of `text` (copied) at `col`.
    pub fn append(r: *Row, gpa: Allocator, col: u16, width: u16, style: u32, text: []const u8, selected: bool) Error!void {
        const start: u32 = @intCast(r.text.items.len);
        try r.text.appendSlice(gpa, text);
        try r.runs.append(gpa, .{ .col = col, .width = width, .style = style, .start = start, .len = @intCast(text.len), .selected = selected });
    }
};

pub const StylesChange = enum(u8) {
    /// The table is as it was.
    same,
    /// Entries were appended; ids already handed out still mean the same.
    grew,
    /// The table was rebuilt and ids renumbered: re-read it and every row.
    /// `Dirty.all` is set too.
    reset,
};

/// What changed since the last `takeDirty`.
pub const Dirty = struct {
    /// Viewport rows whose runs changed, ascending, no repeats.
    rows: std.ArrayList(u16) = .empty,
    /// Every row changed (scroll, resize, clear, a reset): `rows` is empty.
    all: bool = false,
    cursor: bool = false,
    styles: StylesChange = .same,
    /// cols or rows changed.
    size: bool = false,

    pub fn clear(d: *Dirty) void {
        d.rows.clearRetainingCapacity();
        d.all = false;
        d.cursor = false;
        d.styles = .same;
        d.size = false;
    }
    pub fn deinit(d: *Dirty, gpa: Allocator) void {
        d.rows.deinit(gpa);
    }
    pub fn any(d: *const Dirty) bool {
        return d.rows.items.len > 0 or d.all or d.cursor or d.styles != .same or d.size;
    }
};

pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    _pad: u4 = 0,

    pub fn none(m: Mods) bool {
        return @as(u8, @bitCast(m)) == 0;
    }
};

pub const NamedKey = enum {
    enter,
    escape,
    tab,
    space,
    backspace,
    delete,
    insert,
    up,
    down,
    left,
    right,
    home,
    end,
    pageup,
    pagedown,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// A keystroke, from core.md's grammar (`ctrl-c`, `shift-up`, `a`, `é`).
/// The renderer sends it with uit_key; the core parses it with
/// `parseStroke` and asks the engine for the bytes.
pub const Key = struct {
    code: union(enum) {
        /// The character the key produced, shift already applied (`A`).
        char: u21,
        named: NamedKey,
    },
    mods: Mods = .{},
};

/// Parses a core.md keystroke: modifiers (`cmd ctrl alt shift super`)
/// joined by `-`, then one character or a key name. `cmd` becomes `cmd_is`
/// (the host's command key, from `version`'s `cmdkey`). Null for anything
/// else, including text of more than one character.
pub fn parseStroke(s: []const u8, cmd_is: enum { super, ctrl }) ?Key {
    var k: Key = .{ .code = .{ .char = 0 } };
    var rest = s;
    while (true) {
        // A trailing `-` is the key itself (`ctrl--`), not a separator.
        const dash = std.mem.indexOfScalar(u8, rest, '-') orelse break;
        if (dash == 0 or dash == rest.len - 1) break;
        const m = rest[0..dash];
        if (std.mem.eql(u8, m, "shift")) k.mods.shift = true else if (std.mem.eql(u8, m, "alt")) k.mods.alt = true else if (std.mem.eql(u8, m, "ctrl")) k.mods.ctrl = true else if (std.mem.eql(u8, m, "super")) k.mods.super = true else if (std.mem.eql(u8, m, "cmd")) switch (cmd_is) {
            .super => k.mods.super = true,
            .ctrl => k.mods.ctrl = true,
        } else return null;
        rest = rest[dash + 1 ..];
    }
    if (rest.len == 0) return null;
    if (std.meta.stringToEnum(NamedKey, rest)) |n| {
        k.code = .{ .named = n };
        return k;
    }
    const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch return null;
    if (n != rest.len) return null;
    const cp = std.unicode.utf8Decode(rest) catch return null;
    k.code = .{ .char = cp };
    return k;
}

pub const MouseAction = enum(u8) { press = 0, release = 1, move = 2 };

pub const MouseButton = enum(u8) { none = 0, left = 1, middle = 2, right = 3, wheel_up = 4, wheel_down = 5 };

pub const Mouse = struct {
    action: MouseAction,
    /// The button pressed or released; for `move`, the one held (`none`
    /// for a plain move).
    button: MouseButton = .none,
    col: u16,
    row: u16,
    mods: Mods = .{},
    /// 1, 2 or 3 for a single, double or triple press (word and line
    /// selection when no mouse mode is on).
    clicks: u8 = 1,
};

pub const Scroll = union(enum) {
    /// The oldest line of history.
    top,
    /// The live screen. Output from the program also snaps back here.
    bottom,
    /// Lines: negative scrolls back into history, positive toward the live
    /// screen. Clamped at both ends.
    lines: i32,
};

pub const Point = struct { col: u16, row: u16 };

pub const Selection = union(enum) {
    none,
    /// `start` is where the drag began and `end` where it is; either may
    /// come first. `cells` takes the cells between, in reading order;
    /// `words` and `lines` widen both ends to a word or line boundary.
    range: struct { start: Point, end: Point, unit: enum { cells, words, lines } = .cells },
};

/// The program's mode bits the core decides by.
pub const Modes = struct {
    /// Any mouse reporting (X10, normal, button or any-event tracking).
    mouse: bool = false,
    alt_screen: bool = false,
    /// DECSET 1007: the wheel sends arrow keys in the alternate screen.
    alt_scroll: bool = false,
    bracketed_paste: bool = false,
    focus_reports: bool = false,
    /// DECCKM.
    app_cursor: bool = false,
};

/// A byte range in `Events.buf`.
pub const Span = struct {
    start: u32,
    len: u32,
};

pub const Clip = struct {
    /// OSC 52's selection letter: `c` clipboard, `p` primary, `s`...
    target: u8,
    /// The bytes to put there, already base64-decoded.
    data: Span,
};

/// What the program said since the last `takeEvents`.
pub const Events = struct {
    /// OSC 0 or 2, when it changed. The latest wins.
    title: ?Span = null,
    /// OSC 7, when it changed: the URL the program sent (`file://host/path`).
    cwd: ?Span = null,
    /// BEL count.
    bell: u32 = 0,
    /// OSC 52 writes, in order. Reads (`?`) are refused and not listed.
    clips: std.ArrayList(Clip) = .empty,
    /// Bytes the program asked the terminal to send back, in order: answers
    /// to device attribute, cursor position and mode queries (DA, DSR,
    /// DECRQM, XTVERSION). They go to the program's input, the `keys`
    /// stream, as if typed. Programs such as vim wait for some of them.
    reply: ?Span = null,
    buf: std.ArrayList(u8) = .empty,

    pub fn clear(e: *Events) void {
        e.title = null;
        e.cwd = null;
        e.bell = 0;
        e.reply = null;
        e.clips.clearRetainingCapacity();
        e.buf.clearRetainingCapacity();
    }
    pub fn deinit(e: *Events, gpa: Allocator) void {
        e.clips.deinit(gpa);
        e.buf.deinit(gpa);
    }
    pub fn str(e: *const Events, s: Span) []const u8 {
        return e.buf.items[s.start..][0..s.len];
    }
    pub fn put(e: *Events, gpa: Allocator, s: []const u8) Error!Span {
        const start: u32 = @intCast(e.buf.items.len);
        try e.buf.appendSlice(gpa, s);
        return .{ .start = start, .len = @intCast(s.len) };
    }
    pub fn any(e: *const Events) bool {
        return e.title != null or e.cwd != null or e.bell > 0 or e.clips.items.len > 0 or e.reply != null;
    }
};

// ---------------------------------------------------------------- the interface

/// Checks at compile time that `T` is an engine: every declaration below,
/// with exactly this signature. A backend that drifts fails to build.
///
///   init(gpa, Opts) Error!T
///   deinit(*T) void
///   feed(*T, bytes) Error!void          parse program output
///   resize(*T, Size) Error!void         from the renderer's layout
///   size(*const T) Size
///   reset(*T) void                      RIS: clear screen, history, modes
///   takeDirty(*T, *Dirty) Error!void    what changed since the last call
///   row(*T, y, *Row) Error!void         a viewport row's runs
///   styles(*T) []const Style            the style table; [0] is default
///   cursor(*T) Cursor
///   modes(*T) Modes
///   encodeKey(*T, Key, *Writer) !bool   false: no bytes for this key
///   encodeText(*T, text, *Writer) !void committed text (IME, a typed char)
///   encodeMouse(*T, Mouse, *Writer) !bool  false: no mouse mode; the core
///                                       selects or scrolls instead
///   encodePaste(*T, text, *Writer) !void   bracketed when the program asked
///   encodeFocus(*T, in, *Writer) !void  nothing unless focus reports are on
///   scroll(*T, Scroll) void             move the viewport in history
///   select(*T, Selection) void
///   screenText(*T, *Writer) !void       the `screen` file (below)
///   selectionText(*T, *Writer) !void    the `selection` file
///   takeEvents(*T, *Events) Error!void  title, cwd, bell, OSC 52, replies
///
/// `screenText` is the viewport as plain text: one line per row, each
/// ending in `\n`, trailing blanks of each row and trailing blank rows left
/// out, wide characters once. `selectionText` is the selection the same
/// way, rows joined by `\n` with no final newline; empty with none.
pub fn conform(comptime T: type) void {
    const W = Writer.Error;
    const want = .{
        .{ "init", fn (Allocator, Opts) Error!T },
        .{ "deinit", fn (*T) void },
        .{ "feed", fn (*T, []const u8) Error!void },
        .{ "resize", fn (*T, Size) Error!void },
        .{ "size", fn (*const T) Size },
        .{ "reset", fn (*T) void },
        .{ "takeDirty", fn (*T, *Dirty) Error!void },
        .{ "row", fn (*T, u16, *Row) Error!void },
        .{ "styles", fn (*T) []const Style },
        .{ "cursor", fn (*T) Cursor },
        .{ "modes", fn (*T) Modes },
        .{ "encodeKey", fn (*T, Key, *Writer) W!bool },
        .{ "encodeText", fn (*T, []const u8, *Writer) W!void },
        .{ "encodeMouse", fn (*T, Mouse, *Writer) W!bool },
        .{ "encodePaste", fn (*T, []const u8, *Writer) W!void },
        .{ "encodeFocus", fn (*T, bool, *Writer) W!void },
        .{ "scroll", fn (*T, Scroll) void },
        .{ "select", fn (*T, Selection) void },
        .{ "screenText", fn (*T, *Writer) W!void },
        .{ "selectionText", fn (*T, *Writer) W!void },
        .{ "takeEvents", fn (*T, *Events) Error!void },
    };
    inline for (want) |w| {
        if (!@hasDecl(T, w[0])) @compileError(@typeName(T) ++ " has no " ++ w[0]);
        if (@TypeOf(@field(T, w[0])) != w[1])
            @compileError(@typeName(T) ++ "." ++ w[0] ++ " is " ++ @typeName(@TypeOf(@field(T, w[0]))) ++ ", want " ++ @typeName(w[1]));
    }
}

// ---------------------------------------------------------------- tests

test {
    _ = plain;
    _ = @import("tests.zig");
    if (backend == .ghostty) _ = @import("ghostty.zig");
}

test "parseStroke" {
    const t = std.testing;
    const a = parseStroke("a", .ctrl).?;
    try t.expectEqual(@as(u21, 'a'), a.code.char);
    try t.expect(a.mods.none());
    const cc = parseStroke("ctrl-c", .ctrl).?;
    try t.expect(cc.mods.ctrl and !cc.mods.shift);
    const su = parseStroke("shift-up", .ctrl).?;
    try t.expectEqual(NamedKey.up, su.code.named);
    try t.expect(su.mods.shift);
    try t.expect(parseStroke("cmd-s", .super).?.mods.super);
    try t.expect(parseStroke("cmd-s", .ctrl).?.mods.ctrl);
    try t.expectEqual(@as(u21, 'é'), parseStroke("alt-é", .ctrl).?.code.char);
    try t.expectEqual(@as(u21, '-'), parseStroke("ctrl--", .ctrl).?.code.char);
    try t.expectEqual(@as(u21, '-'), parseStroke("-", .ctrl).?.code.char);
    try t.expectEqual(NamedKey.f12, parseStroke("f12", .ctrl).?.code.named);
    try t.expect(parseStroke("hyper-a", .ctrl) == null);
    try t.expect(parseStroke("ab", .ctrl) == null);
    try t.expect(parseStroke("", .ctrl) == null);
}
