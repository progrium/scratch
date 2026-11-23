//! The terminal host's view of one window: builds a frame from the tree
//! (boxes laid out by Yoga), draws it into a Grid, and turns keys and
//! mouse events into the protocol's input calls (uit_emit, uit_mirror,
//! uit_key). It never parses `ctl`, never makes a protocol error, and
//! reads the tree only through `Source` (the C ABI in the app).
//!
//! Each component is drawn as a small arrangement of cells; see
//! README.md for how each type looks. A frame is rebuilt from scratch on
//! every redraw: terminal trees are small and Yoga is fast, and it keeps
//! the renderer free of a mirror of the tree.

const std = @import("std");
const c = @import("c");
const core = @import("core.zig");
const style = @import("style.zig");
const gridmod = @import("grid.zig");
const source = @import("source.zig");

const Grid = gridmod.Grid;
const Rect = gridmod.Rect;
const Pen = Grid.Pen;
const Node = core.Node;
const Source = source.Source;

pub const Kind = enum {
    div,
    text,
    styled_text,
    img,
    svg,
    icon,
    scroll,
    spacer,
    button,
    checkbox,
    radio_group,
    @"switch",
    select,
    input,
    textarea,
    number_input,
    slider,
    form,
    field,
    link,
    tabs,
    tab,
    empty,
    separator,
    badge,
    kbd,
    progress,
    spinner,
    alert,
    dialog,
    other,

    pub fn of(t: []const u8) Kind {
        const m = std.StaticStringMap(Kind).initComptime(.{
            .{ "div", .div },                   .{ "text", .text },               .{ "styled-text", .styled_text },
            .{ "img", .img },                   .{ "svg", .svg },                 .{ "icon", .icon },
            .{ "scroll", .scroll },             .{ "spacer", .spacer },           .{ "button", .button },
            .{ "checkbox", .checkbox },         .{ "radio-group", .radio_group }, .{ "switch", .@"switch" },
            .{ "select", .select },             .{ "input", .input },             .{ "textarea", .textarea },
            .{ "number-input", .number_input }, .{ "slider", .slider },           .{ "form", .form },
            .{ "field", .field },               .{ "link", .link },               .{ "tabs", .tabs },
            .{ "tab", .tab },                   .{ "empty", .empty },             .{ "separator", .separator },
            .{ "badge", .badge },               .{ "kbd", .kbd },                 .{ "progress", .progress },
            .{ "spinner", .spinner },           .{ "alert", .alert },             .{ "dialog", .dialog },
        });
        return m.get(t) orelse .other;
    }

    /// Takes keyboard focus (Tab moves between these).
    pub fn focusable(k: Kind) bool {
        return switch (k) {
            .button, .checkbox, .radio_group, .@"switch", .select, .input, .textarea, .number_input, .slider, .link, .tabs => true,
            else => false,
        };
    }

    /// Takes typed text, so printable keys don't reach uit_key.
    pub fn editable(k: Kind) bool {
        return k == .input or k == .textarea or k == .number_input;
    }
};

/// A synthetic piece of a component: a field's label, a radio item.
pub const Part = enum { none, label, item, field_label, field_desc, field_error, tab_header, tab_label, title, desc, dec, inc, count };

/// Text attributes children inherit, as GPUI's text style cascades.
pub const Ink = struct {
    fg: u32,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    dim: bool = false,
    text_align: style.TextAlign = .left,
    nowrap: bool = false,
    truncate: bool = false,

    fn pen(i: Ink) Pen {
        return .{ .fg = i.fg, .attrs = .{ .bold = i.bold, .italic = i.italic, .underline = i.underline, .strike = i.strike, .dim = i.dim } };
    }
};

pub const Box = struct {
    node: Node,
    kind: Kind,
    part: Part = .none,
    index: u32 = 0,
    yg: c.YGNodeRef,
    parent: ?*Box = null,
    kids: std.ArrayList(*Box) = .empty,
    st: style.Style = .{},
    ink: Ink,
    /// What a leaf shows (and is measured by).
    text: []const u8 = "",
    rect: Rect = .{},
    clip: Rect = .{},
    /// Scroll offset applied to this box's children.
    scroll_y: i32 = 0,
    content_h: i32 = 0,
    hidden: bool = false,
};

pub const Edit = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Byte offset of the caret.
    caret: usize = 0,
    /// First visible column (inputs scroll sideways).
    hscroll: usize = 0,
};

const NodeState = struct {
    scroll_y: i32 = 0,
    open: bool = false,
    hl: usize = 0,
};

const Hit = struct { rect: Rect, box: *Box };

/// A `tooltip` file's tip, as components.md § Tooltips times it with the
/// `tooltip` overlay's defaults (`placement=top open-delay=500`).
pub const Tip = struct {
    node: Node = 0,
    gen: u32 = 0,
    shown: bool = false,
    /// A timer is running for `gen`.
    scheduled: bool = false,
    /// A press on the node hides the tip until the pointer leaves it.
    suppressed: bool = false,
};

pub const tip_delay_ms = 500;

pub const Ui = struct {
    gpa: std.mem.Allocator,
    src: Source,
    win: []const u8 = "main",
    title: []const u8 = "",
    shown: bool = false,
    /// `radius 0`: square corners everywhere, read each frame.
    square: bool = false,

    /// The frame: boxes and their text live here until the next build.
    arena: std.heap.ArenaAllocator,
    root: ?*Box = null,
    overlay_roots: std.ArrayList(*Box) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    focus_order: std.ArrayList(Node) = .empty,
    /// A select's open list, drawn last: its rect and items.
    popup: ?struct { node: Node, rect: Rect, items: []core.Core.Line } = null,

    focused: Node = 0,
    /// What had focus before a modal overlay took it, given back on close.
    modal_prev: Node = 0,
    /// Nodes under the pointer, innermost first.
    hover: std.ArrayList(Node) = .empty,
    pressed: Node = 0,
    pressed_box: ?struct { node: Node, part: Part, index: u32 } = null,
    mouse: ?struct { x: i32, y: i32 } = null,
    /// The `tooltip` file the pointer rests on (core.md § Overlays): the
    /// innermost hovered node that has one. The host shows it after
    /// `tip_delay_ms` (main.zig's timer posts `tipDue`), hides it when the
    /// pointer leaves or presses, and sends nothing to the client.
    tip: Tip = .{},

    edits: std.AutoHashMapUnmanaged(Node, Edit) = .empty,
    states: std.AutoHashMapUnmanaged(Node, NodeState) = .empty,
    yg_config: c.YGConfigRef,
    spin: u8 = 0,

    pub fn init(gpa: std.mem.Allocator, src: Source) Ui {
        const cfg = c.YGConfigNew();
        c.YGConfigSetPointScaleFactor(cfg, 1);
        return .{ .gpa = gpa, .src = src, .arena = .init(gpa), .yg_config = cfg };
    }

    pub fn deinit(ui: *Ui) void {
        var it = ui.edits.valueIterator();
        while (it.next()) |e| e.buf.deinit(ui.gpa);
        ui.edits.deinit(ui.gpa);
        ui.states.deinit(ui.gpa);
        ui.hover.deinit(ui.gpa);
        ui.arena.deinit();
        c.YGConfigFree(ui.yg_config);
    }

    fn tok(ui: *Ui, name: []const u8, fallback: u32) u32 {
        return ui.src.token(name) orelse fallback;
    }

    fn state(ui: *Ui, n: Node) *NodeState {
        const gop = ui.states.getOrPut(ui.gpa, n) catch return &dummy_state;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    // -----------------------------------------------------------------
    // Changes from the core

    /// A prop changed (UitChanges.props). Keeps an input's edit buffer in
    /// step when the client writes its value.
    pub fn propChanged(ui: *Ui, n: Node, file: []const u8) void {
        if (!std.mem.eql(u8, file, "value")) return;
        const e = ui.edits.getPtr(n) orelse return;
        const v = ui.src.text(n, "value");
        if (std.mem.eql(u8, v, e.buf.items)) return;
        e.buf.clearRetainingCapacity();
        e.buf.appendSlice(ui.gpa, v) catch return;
        e.caret = e.buf.items.len;
    }

    /// A node is gone (UitChanges.removed).
    pub fn removed(ui: *Ui, n: Node) void {
        if (ui.edits.fetchRemove(n)) |kv| {
            var e = kv.value;
            e.buf.deinit(ui.gpa);
        }
        _ = ui.states.remove(n);
        if (ui.focused == n) ui.focused = 0;
        if (ui.modal_prev == n) ui.modal_prev = 0;
        if (ui.pressed == n) ui.pressed = 0;
        if (ui.tip.node == n) ui.tip = .{ .gen = ui.tip.gen +% 1 };
        if (ui.popup) |p| if (p.node == n) {
            ui.popup = null;
        };
    }

    /// A window-relative path (`f/user/in`) to its node.
    pub fn lookup(ui: *Ui, path: []const u8) ?Node {
        var at = ui.src.windowRoot(ui.win);
        var it = std.mem.tokenizeAny(u8, std.mem.trim(u8, path, " \n"), "/");
        while (it.next()) |el| {
            if (std.mem.eql(u8, el, ".")) continue;
            var next: ?Node = null;
            for (ui.src.children(at)) |k| {
                if (std.mem.eql(u8, std.fs.path.basenamePosix(ui.src.path(k)), el)) next = k;
            }
            at = next orelse return null;
        }
        return at;
    }

    fn edit(ui: *Ui, n: Node) *Edit {
        const gop = ui.edits.getOrPut(ui.gpa, n) catch return &dummy_edit;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            gop.value_ptr.buf.appendSlice(ui.gpa, ui.src.text(n, "value")) catch {};
            gop.value_ptr.caret = gop.value_ptr.buf.items.len;
        }
        return gop.value_ptr;
    }

    // -----------------------------------------------------------------
    // Building a frame

    fn isHovered(ui: *Ui, n: Node) bool {
        for (ui.hover.items) |h| if (h == n) return true;
        return false;
    }

    fn statesOf(ui: *Ui, n: Node) style.States {
        return .{
            .hover = ui.isHovered(n),
            .active = ui.pressed == n and ui.isHovered(n),
            .focus = ui.focused == n,
            .disabled = ui.src.flag(n, "disabled", false),
        };
    }

    fn newBox(ui: *Ui, n: Node, kind: Kind, parent: ?*Box, ink: Ink) !*Box {
        const a = ui.arena.allocator();
        const b = try a.create(Box);
        b.* = .{ .node = n, .kind = kind, .yg = c.YGNodeNewWithConfig(ui.yg_config), .parent = parent, .ink = ink };
        c.YGNodeSetContext(b.yg, b);
        if (parent) |p| {
            c.YGNodeInsertChild(p.yg, b.yg, c.YGNodeGetChildCount(p.yg));
            try p.kids.append(a, b);
        }
        return b;
    }

    /// A leaf that shows text, measured by Yoga through `measure`.
    fn leaf(ui: *Ui, n: Node, kind: Kind, part: Part, parent: *Box, ink: Ink, text: []const u8) !*Box {
        const b = try ui.newBox(n, kind, parent, ink);
        b.part = part;
        b.text = text;
        c.YGNodeStyleSetFlexShrink(b.yg, 1);
        c.YGNodeSetMeasureFunc(b.yg, measure);
        return b;
    }

    fn inkFor(ui: *Ui, parent: Ink, look: style.Look) Ink {
        _ = ui;
        var i = parent;
        if (look.fg) |f| i.fg = f;
        if (look.bold) |v| i.bold = v;
        if (look.italic) |v| i.italic = v;
        if (look.underline) |v| i.underline = v;
        if (look.strike) |v| i.strike = v;
        if (look.dim) |v| i.dim = v;
        if (look.text_align) |v| i.text_align = v;
        if (look.nowrap) |v| i.nowrap = v;
        if (look.truncate) |v| i.truncate = v;
        return i;
    }

    /// Builds the frame for the window, lays it out in w×h cells and
    /// draws it into g (which must be w wide and h+1 tall: row 0 is the
    /// title bar).
    /// The look tokens a terminal can show: `spacing` (points per scale
    /// step, so `p-4` is wider or narrower) and `radius` (0 squares every
    /// rounded corner). Font size and family and shadows mean nothing in a
    /// cell grid.
    fn readLook(ui: *Ui) void {
        const num = struct {
            fn f(s: ?[]const u8) ?f32 {
                return std.fmt.parseFloat(f32, std.mem.trim(u8, s orelse return null, " \n")) catch null;
            }
        }.f;
        style.step = num(ui.src.tokenText("spacing")) orelse 4;
        ui.square = if (num(ui.src.tokenText("radius"))) |r| r == 0 else false;
    }

    pub fn frame(ui: *Ui, g: *Grid) !void {
        const before = ui.focused;
        try ui.frameOnce(g);
        // A modal overlay opening or closing moved focus: draw again so the
        // caret and focus marks match.
        if (ui.focused != before) try ui.frameOnce(g);
    }

    fn frameOnce(ui: *Ui, g: *Grid) !void {
        _ = ui.arena.reset(.retain_capacity);
        ui.readLook();
        ui.root = null;
        ui.overlay_roots = .empty;
        ui.hits = .empty;
        ui.focus_order = .empty;
        ui.popup = if (ui.popup) |p| p else null;

        const bg = ui.tok("background", 0xffffffff);
        const fg = ui.tok("foreground", 0x0a0a0aff);
        g.clear(gridmod.blend(fg, bg >> 8), bg >> 8);

        const root_node = ui.src.windowRoot(ui.win);
        ui.drawTitle(g);
        if (root_node == 0 or !ui.shown) return;

        const body: Rect = .{ .x = 0, .y = 1, .w = g.w, .h = @as(i32, g.h) - 1 };
        const ink: Ink = .{ .fg = fg };
        const root = try ui.build(root_node, null, ink);
        // The window's root fills the window, whatever its style says.
        c.YGNodeStyleSetWidth(root.yg, @floatFromInt(body.w));
        c.YGNodeStyleSetHeight(root.yg, @floatFromInt(body.h));
        c.YGNodeCalculateLayout(root.yg, @floatFromInt(body.w), @floatFromInt(body.h), c.YGDirectionLTR);
        ui.root = root;
        ui.place(root, body.x, body.y, body);
        c.YGNodeFreeRecursive(root.yg);
        ui.draw(g, root);

        // Overlays: dialogs, centered, over a scrim.
        var modal = false;
        for (ui.src.overlays(ui.win)) |ov| {
            if (!ui.src.flag(ov, "open", true)) continue;
            const first = ui.focus_order.items.len;
            const ob = try ui.build(ov, null, ink);
            if (ui.src.flag(ov, "modal", true)) {
                // A modal overlay keeps focus and the caret inside it.
                modal = true;
                const k = ui.focus_order.items.len - first;
                std.mem.copyForwards(Node, ui.focus_order.items, ui.focus_order.items[first..]);
                ui.focus_order.shrinkRetainingCapacity(k);
                const mine = ui.focus_order.items;
                g.cursor = null;
                if (std.mem.indexOfScalar(Node, mine, ui.focused) == null) {
                    if (ui.modal_prev == 0) ui.modal_prev = ui.focused;
                    if (mine.len > 0) ui.focus(mine[0]) else ui.blur();
                }
            }
            const want_w: f32 = if (ui.src.number(ov, "width")) |pw| style.cells(@floatCast(pw), .x) else @min(60, @as(f32, @floatFromInt(body.w)) - 4);
            c.YGNodeStyleSetWidth(ob.yg, @min(want_w, @as(f32, @floatFromInt(body.w))));
            c.YGNodeStyleSetMaxHeight(ob.yg, @floatFromInt(body.h));
            c.YGNodeCalculateLayout(ob.yg, c.YGUndefined, c.YGUndefined, c.YGDirectionLTR);
            const ow: i32 = @intFromFloat(c.YGNodeLayoutGetWidth(ob.yg));
            const oh: i32 = @intFromFloat(c.YGNodeLayoutGetHeight(ob.yg));
            if (ui.src.flag(ov, "modal", true)) g.fill(body, body, 0x00000060);
            const ox = body.x + @divTrunc(body.w - ow, 2);
            const oy = body.y + @max(0, @divTrunc(body.h - oh, 3));
            ui.place(ob, ox, oy, body);
            c.YGNodeFreeRecursive(ob.yg);
            // A modal overlay takes every hit below it.
            ui.hits.clearRetainingCapacity();
            ui.draw(g, ob);
            try ui.overlay_roots.append(ui.arena.allocator(), ob);
        }

        if (!modal and ui.modal_prev != 0) {
            const prev = ui.modal_prev;
            ui.modal_prev = 0;
            if (std.mem.indexOfScalar(Node, ui.focus_order.items, prev) != null) ui.focus(prev);
        }

        if (ui.popup) |p| ui.drawPopup(g, p.node, p.rect, body);
        ui.drawTip(g, body);
    }

    fn drawTitle(ui: *Ui, g: *Grid) void {
        const bar: Rect = .{ .x = 0, .y = 0, .w = g.w, .h = 1 };
        const bg = ui.tok("title-bar", ui.tok("muted", 0xf5f5f5ff));
        g.fill(bar, bar, bg);
        const t = if (ui.title.len > 0) ui.title else "uitree";
        const tw: i32 = gridmod.width(t);
        const x = @max(0, @divTrunc(@as(i32, g.w) - tw, 2));
        _ = g.print(x, 0, bar, t, .{ .fg = ui.tok("foreground", 0x0a0a0aff), .attrs = .{ .bold = true } });
    }

    fn build(ui: *Ui, n: Node, parent: ?*Box, pink: Ink) anyerror!*Box {
        const kind = Kind.of(ui.src.typeOf(n));
        const words = ui.src.style(n);
        var st = style.resolve(words, ui.statesOf(n));
        ui.defaults(kind, n, &st);
        const ink = ui.inkFor(pink, st.look);
        const b = try ui.newBox(n, kind, parent, ink);
        b.st = st;
        style.toYoga(b.yg, st.layout);
        if ((st.look.invisible orelse false) or st.layout.display_none) b.hidden = true;
        if (parent) |p| if (p.hidden) {
            b.hidden = true;
        };
        if (kind.focusable() and !ui.src.flag(n, "disabled", false) and !b.hidden)
            try ui.focus_order.append(ui.arena.allocator(), n);
        try ui.content(b);
        return b;
    }

    /// Layout a component has unless its style says otherwise.
    fn defaults(ui: *Ui, kind: Kind, n: Node, st: *style.Style) void {
        const L = &st.layout;
        // A border is a whole cell in a terminal: a bordered box written
        // 40 points tall (2 rows) gets a row inside its border anyway.
        if (L.border[0] and L.border[2]) {
            if (L.h) |h| if (h == .pt and h.pt < 3) {
                L.h = .{ .pt = 3 };
            };
        }
        if (L.border[1] and L.border[3]) {
            if (L.w) |w| if (w == .pt and w.pt < 3) {
                L.w = .{ .pt = 3 };
            };
        }
        switch (kind) {
            .button => {
                if (L.dir == null) L.dir = .row;
                if (L.items == null) L.items = .center;
                if (L.justify == null) L.justify = .center;
                if (L.pad[1] == null) L.pad[1] = .{ .pt = 1 };
                if (L.pad[3] == null) L.pad[3] = .{ .pt = 1 };
                if (L.gap_x == null) L.gap_x = 1;
                L.shrink = L.shrink orelse 0;
            },
            .form => {
                if (L.dir == null) L.dir = if (std.mem.eql(u8, ui.src.text(n, "dir"), "row")) .row else .col;
                if (L.gap_y == null) L.gap_y = 1;
                if (L.gap_x == null) L.gap_x = 2;
            },
            .field => {
                if (L.dir == null) L.dir = .col;
            },
            .radio_group => {
                if (L.dir == null) L.dir = if (std.mem.eql(u8, ui.src.text(n, "dir"), "row")) .row else .col;
                if (L.gap_x == null) L.gap_x = 2;
            },
            .tabs => {
                if (L.dir == null) L.dir = .col;
            },
            .spacer => {
                if (L.grow == null) L.grow = 1;
            },
            .scroll => {
                if (L.overflow == .visible) L.overflow = .scroll;
                if (L.grow == null) L.grow = 1;
            },
            .empty => {
                if (L.dir == null) L.dir = .col;
                if (L.items == null) L.items = .center;
                if (L.justify == null) L.justify = .center;
                if (L.pad[0] == null) L.pad = .{ .{ .pt = 1 }, .{ .pt = 2 }, .{ .pt = 1 }, .{ .pt = 2 } };
            },
            .alert => {
                L.border = .{ true, true, true, true };
                if (L.pad[1] == null) L.pad[1] = .{ .pt = 1 };
                if (L.pad[3] == null) L.pad[3] = .{ .pt = 1 };
                st.look.rounded = true;
            },
            .dialog => {
                L.border = .{ true, true, true, true };
                L.dir = L.dir orelse .col;
                if (L.pad[1] == null) L.pad = .{ .{ .pt = 0 }, .{ .pt = 2 }, .{ .pt = 0 }, .{ .pt = 2 } };
                if (L.gap_y == null) L.gap_y = 1;
                st.look.rounded = true;
                if (st.look.bg == null) st.look.bg = ui.tok("popover", ui.tok("background", 0xffffffff));
            },
            .input, .select, .number_input => {
                if (L.h == null) L.h = .{ .pt = 1 };
                if (L.min_w == null) L.min_w = .{ .pt = 12 };
            },
            .textarea => {
                const rows = ui.src.number(n, "rows") orelse 3;
                if (L.h == null) L.h = .{ .pt = @floatCast(rows) };
                if (L.min_w == null) L.min_w = .{ .pt = 20 };
            },
            .slider, .progress => {
                if (L.h == null) L.h = .{ .pt = 1 };
                if (L.min_w == null) L.min_w = .{ .pt = 10 };
            },
            .separator => {
                if (std.mem.eql(u8, ui.src.text(n, "dir"), "col")) {
                    if (L.w == null) L.w = .{ .pt = 1 };
                    L.self = L.self orelse .stretch;
                } else {
                    if (L.h == null) L.h = .{ .pt = 1 };
                    L.self = L.self orelse .stretch;
                }
            },
            else => {},
        }
    }

    /// The component's own pieces and its children.
    fn content(ui: *Ui, b: *Box) !void {
        const n = b.node;
        const src = ui.src;
        const a = ui.arena.allocator();
        const ink = b.ink;
        switch (b.kind) {
            .text, .styled_text => {
                b.text = src.text(n, "text");
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .img, .svg => {
                const s = src.text(n, "src");
                b.text = try std.fmt.allocPrint(a, "[{s}{s}{s}]", .{ if (b.kind == .img) "image" else "svg", if (s.len > 0) " " else "", std.fs.path.basename(s) });
                b.ink.dim = true;
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .icon => {
                b.text = iconGlyph(src.text(n, "name"));
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .spinner => {
                b.text = spinner_frames[ui.spin % spinner_frames.len];
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .kbd => {
                b.text = try std.fmt.allocPrint(a, " {s} ", .{src.text(n, "key")});
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .checkbox, .@"switch" => {
                const label = src.text(n, "label");
                b.text = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ if (b.kind == .checkbox) "[x]" else "━━●", if (label.len > 0) " " else "", label });
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .link => {
                const label = src.text(n, "label");
                b.text = if (label.len > 0) label else src.text(n, "href");
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .input, .textarea, .number_input, .slider, .progress, .separator => {
                // Drawn to whatever size layout gives; no children.
                c.YGNodeSetMeasureFunc(b.yg, measureFixed);
            },
            .select => {
                b.text = ui.selectLabel(n) catch "";
                c.YGNodeSetMeasureFunc(b.yg, measureSelect);
            },
            .button => {
                if (src.flag(n, "loading", false)) _ = try ui.leaf(n, .text, .none, b, ink, spinner_frames[ui.spin % spinner_frames.len]);
                if (src.prop(n, "icon")) |ic| _ = try ui.leaf(n, .text, .none, b, ink, iconGlyph(std.mem.trim(u8, ic, " \n")));
                var prefix: ?Node = null;
                var suffix: ?Node = null;
                for (src.children(n)) |k| {
                    const p = src.path(k);
                    const name = std.fs.path.basenamePosix(p);
                    if (std.mem.eql(u8, name, "prefix")) prefix = k else if (std.mem.eql(u8, name, "suffix")) suffix = k;
                }
                if (prefix) |k| _ = try ui.build(k, b, ink);
                const label = src.text(n, "label");
                if (label.len > 0) _ = try ui.leaf(n, .text, .label, b, ink, label);
                for (src.children(n)) |k| if (k != prefix and k != suffix) {
                    _ = try ui.build(k, b, ink);
                };
                if (suffix) |k| _ = try ui.build(k, b, ink);
                // A button with nothing in it still has a cell to click.
                if (b.kids.items.len == 0) _ = try ui.leaf(n, .text, .label, b, ink, " ");
            },
            .radio_group => {
                const items = try src.lines(a, n, "items");
                for (items, 0..) |it, i| {
                    if (it.fields.len == 0) continue;
                    const label = if (it.fields.len > 1) it.fields[1] else it.fields[0];
                    const t = try std.fmt.allocPrint(a, "( ) {s}", .{label});
                    const lb = try ui.leaf(n, .radio_group, .item, b, ink, t);
                    lb.index = @intCast(i);
                }
            },
            .field => {
                const label = src.text(n, "label");
                if (label.len > 0) {
                    const t = if (src.flag(n, "required", false)) try std.fmt.allocPrint(a, "{s} *", .{label}) else label;
                    var li = ink;
                    li.bold = true;
                    _ = try ui.leaf(n, .text, .field_label, b, li, t);
                }
                for (src.children(n)) |k| _ = try ui.build(k, b, ink);
                const desc = src.text(n, "description");
                if (desc.len > 0) {
                    var di = ink;
                    di.fg = ui.tok("muted-foreground", 0x737373ff);
                    _ = try ui.leaf(n, .text, .field_desc, b, di, desc);
                }
                const err = src.text(n, "error");
                if (err.len > 0) {
                    var ei = ink;
                    ei.fg = ui.tok("danger", 0xef4444ff);
                    _ = try ui.leaf(n, .text, .field_error, b, ei, err);
                }
            },
            .tabs => {
                const hdr = try ui.newBox(n, .tabs, b, ink);
                hdr.part = .tab_header;
                c.YGNodeStyleSetFlexDirection(hdr.yg, c.YGFlexDirectionRow);
                c.YGNodeStyleSetAlignSelf(hdr.yg, c.YGAlignFlexStart);
                const sel = ui.selectedTab(n);
                var i: u32 = 0;
                for (src.children(n)) |k| {
                    if (Kind.of(src.typeOf(k)) != .tab) continue;
                    var label = src.text(k, "label");
                    if (label.len == 0) label = std.fs.path.basenamePosix(src.path(k));
                    const lb = try ui.leaf(k, .tab, .tab_label, hdr, ink, try std.fmt.allocPrint(a, " {s} ", .{label}));
                    lb.index = i;
                    i += 1;
                }
                if (sel != 0) for (src.children(sel)) |k| {
                    _ = try ui.build(k, b, ink);
                };
            },
            .empty => {
                const ic = src.text(n, "icon");
                if (ic.len > 0) {
                    var mi = ink;
                    mi.fg = ui.tok("muted-foreground", 0x737373ff);
                    _ = try ui.leaf(n, .text, .none, b, mi, iconGlyph(ic));
                }
                const title = src.text(n, "title");
                if (title.len > 0) {
                    var ti = ink;
                    ti.bold = true;
                    _ = try ui.leaf(n, .text, .title, b, ti, title);
                }
                const desc = src.text(n, "description");
                if (desc.len > 0) {
                    var di = ink;
                    di.fg = ui.tok("muted-foreground", 0x737373ff);
                    _ = try ui.leaf(n, .text, .desc, b, di, desc);
                }
                for (src.children(n)) |k| _ = try ui.build(k, b, ink);
            },
            .alert => {
                var ti = ink;
                ti.bold = true;
                ti.fg = ui.variantColor(n, b.st.look, ink.fg);
                const title = src.text(n, "title");
                if (title.len > 0) _ = try ui.leaf(n, .text, .title, b, ti, try std.fmt.allocPrint(a, "{s} {s}", .{ iconGlyph(alertIcon(src.text(n, "variant"))), title }));
                const t = src.text(n, "text");
                if (t.len > 0) _ = try ui.leaf(n, .text, .desc, b, ink, t);
            },
            .badge => {
                for (src.children(n)) |k| _ = try ui.build(k, b, ink);
                c.YGNodeStyleSetFlexDirection(b.yg, c.YGFlexDirectionRow);
                const count = src.number(n, "count");
                const dot = src.flag(n, "dot", false);
                if (count != null or dot or b.kids.items.len == 0) {
                    const max = src.number(n, "max") orelse 99;
                    const t = if (dot) "●" else if (count) |cn| (if (cn > max) try std.fmt.allocPrint(a, " {d}+ ", .{@as(i64, @intFromFloat(max))}) else try std.fmt.allocPrint(a, " {d} ", .{@as(i64, @intFromFloat(cn))})) else " ";
                    _ = try ui.leaf(n, .text, .count, b, ink, t);
                }
            },
            .dialog => {
                var ti = ink;
                ti.bold = true;
                const title = src.text(n, "title");
                if (title.len > 0) _ = try ui.leaf(n, .text, .title, b, ti, title);
                const desc = src.text(n, "description");
                if (desc.len > 0) {
                    var di = ink;
                    di.fg = ui.tok("muted-foreground", 0x737373ff);
                    _ = try ui.leaf(n, .text, .desc, b, di, desc);
                }
                var footer: ?Node = null;
                for (src.children(n)) |k| {
                    if (std.mem.eql(u8, std.fs.path.basenamePosix(src.path(k)), "footer")) {
                        footer = k;
                        continue;
                    }
                    _ = try ui.build(k, b, ink);
                }
                if (footer) |k| _ = try ui.build(k, b, ink);
            },
            .tab => for (src.children(n)) |k| {
                _ = try ui.build(k, b, ink);
            },
            else => for (src.children(n)) |k| {
                _ = try ui.build(k, b, ink);
            },
        }
    }

    fn selectedTab(ui: *Ui, n: Node) Node {
        const v = std.mem.trim(u8, ui.src.text(n, "value"), " ");
        var first: Node = 0;
        for (ui.src.children(n)) |k| {
            if (Kind.of(ui.src.typeOf(k)) != .tab) continue;
            if (first == 0) first = k;
            if (std.mem.eql(u8, std.fs.path.basenamePosix(ui.src.path(k)), v)) return k;
        }
        return first;
    }

    fn selectLabel(ui: *Ui, n: Node) ![]const u8 {
        const v = std.mem.trim(u8, ui.src.text(n, "value"), " ");
        const items = try ui.src.lines(ui.arena.allocator(), n, "items");
        for (items) |it| {
            if (it.fields.len == 0) continue;
            if (std.mem.eql(u8, it.fields[0], v)) return if (it.fields.len > 1) it.fields[1] else it.fields[0];
        }
        return "";
    }

    fn variantColor(ui: *Ui, n: Node, look: style.Look, default: u32) u32 {
        var v = ui.src.text(n, "variant");
        if (look.variant) |lv| v = lv;
        for ([_][]const u8{ "danger", "error", "destructive" }) |x| if (std.mem.eql(u8, v, x)) return ui.tok("danger", 0xef4444ff);
        if (std.mem.eql(u8, v, "success")) return ui.tok("success", 0x22c55eff);
        if (std.mem.eql(u8, v, "warning")) return ui.tok("warning", 0xeab308ff);
        if (std.mem.eql(u8, v, "info")) return ui.tok("info", 0x06b6d4ff);
        return default;
    }

    /// Absolute rects from Yoga's results; clips for overflow.
    fn place(ui: *Ui, b: *Box, x: i32, y: i32, clip: Rect) void {
        const l = c.YGNodeLayoutGetLeft(b.yg);
        const t = c.YGNodeLayoutGetTop(b.yg);
        const w = c.YGNodeLayoutGetWidth(b.yg);
        const h = c.YGNodeLayoutGetHeight(b.yg);
        b.rect = .{
            .x = x + @as(i32, @intFromFloat(@round(if (b.parent == null) 0 else l))),
            .y = y + @as(i32, @intFromFloat(@round(if (b.parent == null) 0 else t))),
            .w = @intFromFloat(@round(w)),
            .h = @intFromFloat(@round(h)),
        };
        b.clip = clip;
        var kid_clip = clip;
        if (b.st.layout.overflow != .visible) {
            const inner = innerRect(b);
            kid_clip = clip.intersect(inner);
            // Content height for scrolling.
            var bottom: i32 = 0;
            for (b.kids.items) |k| {
                const kb: i32 = @intFromFloat(@round(c.YGNodeLayoutGetTop(k.yg) + c.YGNodeLayoutGetHeight(k.yg)));
                bottom = @max(bottom, kb);
            }
            b.content_h = bottom + @as(i32, @intFromFloat(c.YGNodeLayoutGetPadding(b.yg, c.YGEdgeBottom)));
            if (b.st.layout.overflow == .scroll) {
                const s = ui.state(b.node);
                const max = @max(0, b.content_h - b.rect.h);
                s.scroll_y = std.math.clamp(s.scroll_y, 0, max);
                b.scroll_y = s.scroll_y;
            }
        }
        for (b.kids.items) |k| ui.place(k, b.rect.x, b.rect.y - b.scroll_y, kid_clip);
    }

    // -----------------------------------------------------------------
    // Drawing

    fn draw(ui: *Ui, g: *Grid, b: *Box) void {
        if (b.hidden) return;
        const vis = b.rect.intersect(b.clip);
        const a = ui.arena.allocator();
        if (!vis.empty() or b.kids.items.len > 0) ui.hits.append(a, .{ .rect = vis, .box = b }) catch {};
        if (b.st.look.bg) |bg| {
            // An opaque box hides what's under it, glyphs included.
            if (bg & 0xff == 0xff) g.blank(b.rect, b.clip);
            g.fill(b.rect, b.clip, bg);
        }
        ui.drawBorder(g, b);
        ui.drawContent(g, b);
        for (b.kids.items) |k| ui.draw(g, k);
        ui.bounds(b);
    }

    /// Reports a node's layout for its `bounds` file, in window points
    /// (a cell is 8×16; the window starts under the title bar).
    fn bounds(ui: *Ui, b: *Box) void {
        if (b.part != .none or b.hidden) return;
        const r = b.rect;
        ui.src.bounds(b.node, @floatFromInt(r.x * 8), @floatFromInt((r.y - 1) * 16), @floatFromInt(r.w * 8), @floatFromInt(r.h * 16));
    }

    fn drawBorder(ui: *Ui, g: *Grid, b: *Box) void {
        const br = b.st.layout.border;
        if (!(br[0] or br[1] or br[2] or br[3])) return;
        const col = b.st.look.border_color orelse ui.tok("border", 0xe5e5e5ff);
        // A light border on a light background disappears in a terminal;
        // use the ring color, one step darker, for the line glyphs.
        const pen: Pen = .{ .fg = darker(col, ui) };
        const r = b.rect;
        const x1 = r.x + r.w - 1;
        const y1 = r.y + r.h - 1;
        const rounded = b.st.look.rounded and !ui.square;
        var x = r.x;
        while (x <= x1) : (x += 1) {
            if (br[0]) g.put(x, r.y, b.clip, "─", pen);
            if (br[2]) g.put(x, y1, b.clip, "─", pen);
        }
        var y = r.y;
        while (y <= y1) : (y += 1) {
            if (br[3]) g.put(r.x, y, b.clip, "│", pen);
            if (br[1]) g.put(x1, y, b.clip, "│", pen);
        }
        if (br[0] and br[3]) g.put(r.x, r.y, b.clip, if (rounded) "╭" else "┌", pen);
        if (br[0] and br[1]) g.put(x1, r.y, b.clip, if (rounded) "╮" else "┐", pen);
        if (br[2] and br[3]) g.put(r.x, y1, b.clip, if (rounded) "╰" else "└", pen);
        if (br[2] and br[1]) g.put(x1, y1, b.clip, if (rounded) "╯" else "┘", pen);
    }

    fn drawText(ui: *Ui, g: *Grid, b: *Box, text: []const u8, pen: Pen) void {
        const inner = innerRect(b);
        const clip = b.clip.intersect(b.rect);
        const a = ui.arena.allocator();
        const ls = wrap(a, text, if (b.ink.nowrap) std.math.maxInt(u16) else @intCast(@max(1, inner.w))) catch return;
        for (ls, 0..) |line, i| {
            const y = inner.y + @as(i32, @intCast(i));
            if (y >= inner.y + inner.h) break;
            var s = line;
            var lw: i32 = gridmod.width(s);
            if (lw > inner.w and b.ink.truncate) {
                s = truncate(s, @intCast(@max(1, inner.w - 1)));
                lw = gridmod.width(s) + 1;
            }
            const x = switch (b.ink.text_align) {
                .left => inner.x,
                .center => inner.x + @divTrunc(inner.w - lw, 2),
                .right => inner.x + inner.w - lw,
            };
            const end = g.print(x, y, clip, s, pen);
            if (s.len < line.len) _ = g.print(end, y, clip, "…", pen);
        }
    }

    fn drawContent(ui: *Ui, g: *Grid, b: *Box) void {
        const n = b.node;
        const src = ui.src;
        var pen = b.ink.pen();
        const focused = ui.focused == n and b.part == .none;
        switch (b.kind) {
            .text, .styled_text, .img, .svg, .icon, .spinner => {
                if (b.part == .label and ui.focused == n) pen.attrs.underline = true;
                ui.drawText(g, b, b.text, pen);
            },
            .kbd => {
                pen.bg = ui.tok("muted", 0xf5f5f5ff);
                ui.drawText(g, b, b.text, pen);
            },
            .link => {
                pen.fg = ui.tok("link", ui.tok("primary", 0x171717ff));
                pen.attrs.underline = true;
                if (focused) pen.attrs.bold = true;
                pen.link = src.text(n, "href");
                ui.drawText(g, b, b.text, pen);
            },
            .checkbox => {
                const v = std.mem.trim(u8, src.text(n, "value"), " ");
                const mark: []const u8 = if (std.mem.eql(u8, v, "on")) "[x]" else if (std.mem.eql(u8, v, "mixed")) "[-]" else "[ ]";
                const r = innerRect(b);
                var bp = pen;
                if (std.mem.eql(u8, v, "on")) bp.fg = ui.tok("primary", pen.fg);
                bp.attrs.bold = true;
                const x = g.print(r.x, r.y, b.clip, mark, bp);
                var lp = pen;
                if (focused) lp.attrs.underline = true;
                if (src.flag(n, "disabled", false)) lp.attrs.dim = true;
                const label = src.text(n, "label");
                if (label.len > 0) _ = g.print(x + 1, r.y, b.clip.intersect(b.rect), label, lp);
            },
            .@"switch" => {
                const on = src.flag(n, "value", false);
                const r = innerRect(b);
                var tp = pen;
                tp.fg = if (on) ui.tok("primary", pen.fg) else ui.tok("muted-foreground", 0x737373ff);
                tp.attrs.bold = true;
                const x = g.print(r.x, r.y, b.clip, if (on) "━━●" else "●──", tp);
                var lp = pen;
                if (focused) lp.attrs.underline = true;
                const label = src.text(n, "label");
                if (label.len > 0) _ = g.print(x + 1, r.y, b.clip.intersect(b.rect), label, lp);
            },
            .radio_group => if (b.part == .item) {
                const items = src.lines(ui.arena.allocator(), n, "items") catch return;
                if (b.index >= items.len) return;
                const it = items[b.index];
                const v = std.mem.trim(u8, src.text(n, "value"), " ");
                const on = it.fields.len > 0 and std.mem.eql(u8, it.fields[0], v);
                const r = innerRect(b);
                var mp = pen;
                if (on) mp.fg = ui.tok("primary", pen.fg);
                mp.attrs.bold = true;
                const x = g.print(r.x, r.y, b.clip, if (on) "(•)" else "( )", mp);
                var lp = pen;
                if (ui.focused == n and ui.state(n).hl == b.index) lp.attrs.underline = true;
                _ = g.print(x + 1, r.y, b.clip.intersect(b.rect), if (it.fields.len > 1) it.fields[1] else it.fields[0], lp);
            },
            .button => if (b.part == .none) ui.drawButton(g, b),
            .input, .number_input => ui.drawInput(g, b),
            .textarea => ui.drawTextarea(g, b),
            .select => ui.drawSelect(g, b),
            .slider => {
                const r = innerRect(b);
                const min = src.number(n, "min") orelse 0;
                const max = src.number(n, "max") orelse 100;
                const v = std.math.clamp(src.number(n, "value") orelse min, min, max);
                const frac = if (max > min) (v - min) / (max - min) else 0;
                const pos: i32 = @intFromFloat(@round(frac * @as(f64, @floatFromInt(@max(0, r.w - 1)))));
                var x = r.x;
                while (x < r.x + r.w) : (x += 1) {
                    const before = x - r.x < pos;
                    const pp: Pen = .{ .fg = if (before) ui.tok("primary", pen.fg) else ui.tok("border", 0xe5e5e5ff) };
                    g.put(x, r.y, b.clip, if (x - r.x == pos) "●" else if (before) "━" else "─", if (x - r.x == pos) Pen{ .fg = ui.tok("primary", pen.fg), .attrs = .{ .bold = focused } } else pp);
                }
            },
            .progress => {
                const r = innerRect(b);
                const v = std.math.clamp(src.number(n, "value") orelse 0, 0, 100);
                const fill: i32 = @intFromFloat(@round(v / 100 * @as(f64, @floatFromInt(r.w))));
                var x = r.x;
                while (x < r.x + r.w) : (x += 1) {
                    const on = x - r.x < fill;
                    g.put(x, r.y, b.clip, if (on) "█" else "░", .{ .fg = if (on) ui.tok("progress-bar", ui.tok("primary", pen.fg)) else ui.tok("border", 0xe5e5e5ff) });
                }
            },
            .separator => {
                const r = innerRect(b);
                const sp: Pen = .{ .fg = darker(ui.tok("border", 0xe5e5e5ff), ui) };
                if (r.h > r.w) {
                    var y = r.y;
                    while (y < r.y + r.h) : (y += 1) g.put(r.x, y, b.clip, "│", sp);
                } else {
                    var x = r.x;
                    while (x < r.x + r.w) : (x += 1) g.put(x, r.y, b.clip, "─", sp);
                    const label = src.text(n, "label");
                    if (label.len > 0) {
                        const lw: i32 = gridmod.width(label);
                        const lx = r.x + @divTrunc(r.w - lw - 2, 2);
                        _ = g.print(lx, r.y, b.clip, " ", pen);
                        _ = g.print(g.print(lx + 1, r.y, b.clip, label, .{ .fg = ui.tok("muted-foreground", pen.fg) }), r.y, b.clip, " ", pen);
                    }
                }
            },
            .tab => if (b.part == .tab_label) {
                const tabs = b.parent.?.node;
                const sel = ui.selectedTab(tabs);
                var tp = pen;
                if (sel == n) {
                    tp.bg = ui.tok("background", 0xffffffff);
                    tp.attrs.bold = true;
                } else tp.fg = ui.tok("muted-foreground", 0x737373ff);
                if (ui.focused == tabs and sel == n) tp.attrs.underline = true;
                ui.drawText(g, b, b.text, tp);
            },
            .tabs => if (b.part == .tab_header) {
                g.fill(b.rect, b.clip, ui.tok("muted", 0xf5f5f5ff));
            },
            .badge => if (b.part == .count) {
                pen.bg = if (src.flag(n, "dot", false)) null else ui.tok("danger", 0xef4444ff);
                pen.fg = if (src.flag(n, "dot", false)) ui.tok("danger", 0xef4444ff) else ui.tok("danger-foreground", 0xfafafaff);
                ui.drawText(g, b, b.text, pen);
            },
            .field, .empty, .alert, .dialog => if (b.part != .none) ui.drawText(g, b, b.text, pen),
            else => {},
        }
    }

    fn buttonColors(ui: *Ui, b: *Box) struct { bg: ?u32, fg: u32 } {
        const n = b.node;
        var v: []const u8 = "";
        if (b.st.look.variant) |lv| v = lv;
        for ([_][]const u8{ "primary", "secondary", "danger", "info", "success", "warning", "ghost", "link", "outline" }) |name|
            if (ui.src.flag(n, name, false)) {
                v = name;
            };
        const st = ui.statesOf(n);
        const sfx: []const u8 = if (st.active) "-active" else if (st.hover) "-hover" else "";
        var nb: [64]u8 = undefined;
        var nf: [64]u8 = undefined;
        if (std.mem.eql(u8, v, "ghost") or std.mem.eql(u8, v, "link")) {
            const hb = if (st.hover) ui.tok("accent", 0xf5f5f5ff) else null;
            return .{ .bg = hb, .fg = if (std.mem.eql(u8, v, "link")) ui.tok("link", b.ink.fg) else b.ink.fg };
        }
        const base = if (v.len == 0 or std.mem.eql(u8, v, "outline")) "button" else std.fmt.bufPrint(&nb, "button-{s}", .{v}) catch "button";
        const bgname = std.fmt.bufPrint(&nf, "{s}{s}", .{ base, sfx }) catch base;
        const bg = ui.src.token(bgname) orelse ui.src.token(base) orelse ui.tok("secondary", 0xe5e5e5ff);
        var fgb: [64]u8 = undefined;
        const fgname = std.fmt.bufPrint(&fgb, "{s}-foreground", .{base}) catch "foreground";
        const fg = ui.src.token(fgname) orelse b.ink.fg;
        // The default button is white on white in the light theme: give
        // it the secondary fill so it reads as a button in a terminal.
        if (v.len == 0 or std.mem.eql(u8, v, "outline")) {
            return .{ .bg = ui.tok(if (st.active) "secondary-active" else if (st.hover) "secondary-hover" else "secondary", bg), .fg = fg };
        }
        return .{ .bg = bg, .fg = fg };
    }

    fn drawButton(ui: *Ui, g: *Grid, b: *Box) void {
        const col = ui.buttonColors(b);
        if (b.st.look.bg == null) if (col.bg) |bg| g.fill(b.rect, b.clip, bg);
        // Labels inside draw with the button's foreground.
        const disabled = ui.src.flag(b.node, "disabled", false);
        for (b.kids.items) |k| if (k.node == b.node) {
            if (b.st.look.fg == null) k.ink.fg = col.fg;
            if (disabled) k.ink.dim = true;
            if (ui.src.flag(b.node, "selected", false)) k.ink.bold = true;
        };
        if (ui.focused == b.node) {
            g.put(b.rect.x, b.rect.y + @divTrunc(b.rect.h, 2), b.clip, "›", .{ .fg = col.fg, .attrs = .{ .bold = true } });
        }
    }

    /// A field's fill: the `input` token (GPUI's input border color),
    /// which reads as a well on both themes; darker while focused.
    fn fieldBg(ui: *Ui, focused: bool) u32 {
        const base = ui.tok("input", 0xe5e5e5ff);
        if (!focused) return base;
        const ring = ui.tok("ring", 0xa3a3a3ff);
        return (gridmod.blend((ring & 0xffffff00) | 0x50, base >> 8) << 8) | 0xff;
    }

    fn drawInput(ui: *Ui, g: *Grid, b: *Box) void {
        const n = b.node;
        const src = ui.src;
        const focused = ui.focused == n;
        const r = b.rect;
        if (b.st.look.bg == null) g.fill(r, b.clip, ui.fieldBg(focused));
        const pen = b.ink.pen();
        const clip = b.clip.intersect(r);
        const y = r.y + @divTrunc(r.h - 1, 2);
        var x0 = r.x + 1;
        var w = r.w - 2;
        if (b.kind == .number_input) {
            _ = g.print(r.x, y, clip, "−", .{ .fg = ui.tok("muted-foreground", pen.fg) });
            _ = g.print(r.x + r.w - 1, y, clip, "+", .{ .fg = ui.tok("muted-foreground", pen.fg) });
            x0 = r.x + 2;
            w = r.w - 4;
        }
        if (w <= 0) return;
        const e = ui.edit(n);
        const text = e.buf.items;
        if (text.len == 0 and !focused) {
            _ = g.print(x0, y, clip, src.text(n, "placeholder"), .{ .fg = ui.tok("muted-foreground", 0x737373ff) });
            return;
        }
        if (text.len == 0) {
            _ = g.print(x0, y, clip, src.text(n, "placeholder"), .{ .fg = ui.tok("muted-foreground", 0x737373ff) });
        }
        const secret = src.flag(n, "secret", false);
        // Columns before the caret; scroll so the caret is visible.
        const caret_col = displayCols(text[0..e.caret], secret);
        if (caret_col < e.hscroll) e.hscroll = caret_col;
        if (caret_col >= e.hscroll + @as(usize, @intCast(w))) e.hscroll = caret_col - @as(usize, @intCast(w)) + 1;
        var col: usize = 0;
        var x = x0;
        var it = @import("vaxis").unicode.GraphemeIterator.init(text);
        while (it.next()) |gr| {
            const ch = if (secret) "•" else gr.bytes(text);
            const cw: usize = if (secret) 1 else gridmod.width(ch);
            if (col >= e.hscroll) {
                if (x + @as(i32, @intCast(cw)) > x0 + w) break;
                g.put(x, y, clip, ch, pen);
                x += @intCast(cw);
            }
            col += cw;
        }
        if (focused) {
            const cx = x0 + @as(i32, @intCast(caret_col - e.hscroll));
            if (clip.contains(cx, y)) g.cursor = .{ .x = @intCast(cx), .y = @intCast(y) };
        }
    }

    fn drawTextarea(ui: *Ui, g: *Grid, b: *Box) void {
        const n = b.node;
        const focused = ui.focused == n;
        const r = b.rect;
        if (b.st.look.bg == null) g.fill(r, b.clip, ui.fieldBg(focused));
        const inner: Rect = .{ .x = r.x + 1, .y = r.y, .w = r.w - 2, .h = r.h };
        const clip = b.clip.intersect(inner);
        const e = ui.edit(n);
        const pen = b.ink.pen();
        if (e.buf.items.len == 0) {
            _ = g.print(inner.x, inner.y, clip, ui.src.text(n, "placeholder"), .{ .fg = ui.tok("muted-foreground", 0x737373ff) });
        }
        // Hard lines only (no soft wrap), scrolled so the caret's line shows.
        var line_no: i32 = 0;
        var caret_line: i32 = 0;
        var caret_col: i32 = 0;
        var start: usize = 0;
        for (e.buf.items, 0..) |ch, i| {
            if (i == e.caret) {
                caret_line = line_no;
                caret_col = gridmod.width(e.buf.items[start..i]);
            }
            if (ch == '\n') {
                line_no += 1;
                start = i + 1;
            }
        }
        if (e.caret == e.buf.items.len) {
            caret_line = line_no;
            caret_col = gridmod.width(e.buf.items[start..]);
        }
        const st = ui.state(n);
        if (caret_line < st.scroll_y) st.scroll_y = caret_line;
        if (caret_line >= st.scroll_y + inner.h) st.scroll_y = caret_line - inner.h + 1;
        var it = std.mem.splitScalar(u8, e.buf.items, '\n');
        var ln: i32 = 0;
        while (it.next()) |line| : (ln += 1) {
            const y = inner.y + ln - st.scroll_y;
            _ = g.print(inner.x, y, clip, line, pen);
        }
        if (focused) {
            const cx = inner.x + caret_col;
            const cy = inner.y + caret_line - st.scroll_y;
            if (clip.contains(cx, cy)) g.cursor = .{ .x = @intCast(cx), .y = @intCast(cy) };
        }
    }

    fn drawSelect(ui: *Ui, g: *Grid, b: *Box) void {
        const n = b.node;
        const focused = ui.focused == n;
        const r = b.rect;
        if (b.st.look.bg == null) g.fill(r, b.clip, ui.fieldBg(focused));
        const clip = b.clip.intersect(r);
        const y = r.y + @divTrunc(r.h - 1, 2);
        var pen = b.ink.pen();
        if (focused) pen.attrs.underline = true;
        if (b.text.len > 0) {
            _ = g.print(r.x + 1, y, clip.intersect(.{ .x = r.x, .y = r.y, .w = r.w - 2, .h = r.h }), b.text, pen);
        } else {
            _ = g.print(r.x + 1, y, clip, ui.src.text(n, "placeholder"), .{ .fg = ui.tok("muted-foreground", 0x737373ff) });
        }
        _ = g.print(r.x + r.w - 2, y, clip, "▾", .{ .fg = ui.tok("muted-foreground", 0x737373ff) });
        if (ui.state(n).open) {
            const items = ui.src.lines(ui.arena.allocator(), n, "items") catch return;
            var w: i32 = r.w;
            for (items) |it| if (it.fields.len > 0) {
                w = @max(w, @as(i32, gridmod.width(if (it.fields.len > 1) it.fields[1] else it.fields[0])) + 4);
            };
            ui.popup = .{ .node = n, .rect = .{ .x = r.x, .y = r.y + r.h, .w = w, .h = @intCast(items.len + 2) }, .items = items };
        }
    }

    fn drawPopup(ui: *Ui, g: *Grid, n: Node, r0: Rect, screen: Rect) void {
        var r = r0;
        if (r.y + r.h > screen.y + screen.h) r.y = @max(screen.y, r.y - r.h - 1);
        ui.popup.?.rect = r;
        const items = ui.popup.?.items;
        g.blank(r, screen);
        g.fill(r, screen, ui.tok("popover", ui.tok("background", 0xffffffff)));
        const fake: Box = .{ .node = n, .kind = .div, .yg = undefined, .ink = .{ .fg = 0 }, .rect = r, .clip = screen, .st = .{ .layout = .{ .border = .{ true, true, true, true } }, .look = .{ .rounded = true } } };
        var fb = fake;
        ui.drawBorder(g, &fb);
        const fg = ui.tok("popover-foreground", ui.tok("foreground", 0x0a0a0aff));
        const v = std.mem.trim(u8, ui.src.text(n, "value"), " ");
        const hl = ui.state(n).hl;
        for (items, 0..) |it, i| {
            if (it.fields.len == 0) continue;
            const y = r.y + 1 + @as(i32, @intCast(i));
            const row: Rect = .{ .x = r.x + 1, .y = y, .w = r.w - 2, .h = 1 };
            if (i == hl) g.fill(row, screen, ui.tok("list-active", ui.tok("accent", 0xf5f5f5ff)));
            const on = std.mem.eql(u8, it.fields[0], v);
            _ = g.print(row.x, y, row, if (on) "✓ " else "  ", .{ .fg = fg });
            _ = g.print(row.x + 2, y, row, if (it.fields.len > 1) it.fields[1] else it.fields[0], .{ .fg = fg, .attrs = .{ .bold = on } });
        }
    }

    // -----------------------------------------------------------------
    // Hit testing

    fn hitAt(ui: *Ui, x: i32, y: i32) ?*Box {
        var i = ui.hits.items.len;
        while (i > 0) {
            i -= 1;
            const h = ui.hits.items[i];
            if (h.rect.contains(x, y)) return h.box;
        }
        return null;
    }

    fn setHover(ui: *Ui, x: i32, y: i32) bool {
        var next: std.ArrayList(Node) = .empty;
        defer next.deinit(ui.gpa);
        if (ui.hitAt(x, y)) |b0| {
            var b: ?*Box = b0;
            while (b) |bb| : (b = bb.parent) {
                if (next.items.len == 0 or next.items[next.items.len - 1] != bb.node) next.append(ui.gpa, bb.node) catch {};
            }
        }
        if (std.mem.eql(Node, next.items, ui.hover.items)) return false;
        ui.hover.clearRetainingCapacity();
        ui.hover.appendSlice(ui.gpa, next.items) catch {};
        _ = ui.retip();
        return true;
    }

    /// The innermost hovered node with a non-empty `tooltip` file.
    fn tipNode(ui: *Ui) Node {
        for (ui.hover.items) |n| {
            if (std.mem.trim(u8, ui.src.text(n, "tooltip"), " \t\r\n").len > 0) return n;
        }
        return 0;
    }

    /// Follows the pointer to a new tip node; returns whether a shown tip
    /// went away.
    fn retip(ui: *Ui) bool {
        const t = ui.tipNode();
        if (t == ui.tip.node) return false;
        const was = ui.tip.shown;
        ui.tip = .{ .node = t, .gen = ui.tip.gen +% 1 };
        return was;
    }

    /// A tip that wants a timer: its generation, once. main.zig sleeps
    /// `tip_delay_ms` and hands it back to `tipDue`.
    pub fn tipPending(ui: *Ui) ?u32 {
        if (ui.tip.node == 0 or ui.tip.shown or ui.tip.suppressed or ui.tip.scheduled) return null;
        ui.tip.scheduled = true;
        return ui.tip.gen;
    }

    /// The timer for `gen` ran out: shows the tip if the pointer is still
    /// on the same node. Returns whether to redraw.
    pub fn tipDue(ui: *Ui, gen: u32) bool {
        if (gen != ui.tip.gen or ui.tip.node == 0 or ui.tip.suppressed or ui.tip.shown) return false;
        ui.tip.shown = true;
        return true;
    }

    /// The tip as one row of popover colors above its node (below when the
    /// node is on the top row), clipped to the window.
    fn drawTip(ui: *Ui, g: *Grid, screen: Rect) void {
        if (!ui.tip.shown) return;
        const b = ui.boxOf(ui.tip.node) orelse return;
        const text = std.mem.trim(u8, ui.src.text(ui.tip.node, "tooltip"), " \t\r\n");
        if (text.len == 0) return;
        const line = if (std.mem.indexOfScalar(u8, text, '\n')) |i| text[0..i] else text;
        const w: i32 = @min(@as(i32, gridmod.width(line)) + 2, screen.w);
        var x = b.rect.x + @divTrunc(b.rect.w - w, 2);
        x = @max(screen.x, @min(x, screen.x + screen.w - w));
        const y = if (b.rect.y - 1 >= screen.y) b.rect.y - 1 else b.rect.y + b.rect.h;
        const r: Rect = .{ .x = x, .y = y, .w = w, .h = 1 };
        g.blank(r, screen);
        g.fill(r, screen, ui.tok("popover", ui.tok("background", 0xffffffff)));
        const fg = ui.tok("popover-foreground", ui.tok("foreground", 0x0a0a0aff));
        _ = g.print(x + 1, y, screen.intersect(.{ .x = x + 1, .y = y, .w = w - 2, .h = 1 }), line, .{ .fg = fg });
    }

    /// Nearest box (from b up) that acts on a click.
    fn clickTarget(ui: *Ui, b0: *Box) ?*Box {
        var b: ?*Box = b0;
        while (b) |bb| : (b = bb.parent) {
            if (bb.part == .item or bb.part == .tab_label) return bb;
            if (bb.kind.focusable() and bb.part == .none) return bb;
            if (bb.kind == .button) return bb;
            if (ui.src.prop(bb.node, "on")) |on| if (std.mem.indexOf(u8, on, "click") != null and bb.part == .none) return bb;
        }
        return null;
    }

    fn clickAttrs(ui: *Ui, b: *Box, x: i32, y: i32, buf: *[2][16]u8) [3]core.Attr {
        _ = ui;
        _ = b;
        // Window space in points, as GPUI sends: a cell is 8×16.
        const xs = std.fmt.bufPrint(&buf[0], "{d}", .{x * 8}) catch "0";
        const ys = std.fmt.bufPrint(&buf[1], "{d}", .{(y - 1) * 16}) catch "0";
        return .{ .{ "x", xs }, .{ "y", ys }, .{ "button", "left" } };
    }

    // -----------------------------------------------------------------
    // Input

    pub const Mouse = struct {
        x: i32,
        y: i32,
        kind: enum { press, release, motion, drag, wheel_up, wheel_down },
    };

    /// Returns true if the frame should be redrawn.
    pub fn onMouse(ui: *Ui, m: Mouse) bool {
        ui.mouse = .{ .x = m.x, .y = m.y };
        var redraw = ui.setHover(m.x, m.y);
        switch (m.kind) {
            .motion, .drag => {
                if (m.kind == .drag and ui.pressed != 0) {
                    if (ui.boxOf(ui.pressed)) |b| if (b.kind == .slider) ui.sliderTo(b, m.x, false);
                    redraw = true;
                }
            },
            .wheel_up, .wheel_down => {
                var b = ui.hitAt(m.x, m.y);
                while (b) |bb| : (b = bb.parent) {
                    if (bb.st.layout.overflow == .scroll) {
                        const s = ui.state(bb.node);
                        s.scroll_y += if (m.kind == .wheel_up) -2 else 2;
                        return true;
                    }
                }
            },
            .press => {
                if (ui.tip.node != 0) {
                    if (ui.tip.shown) redraw = true;
                    ui.tip.shown = false;
                    ui.tip.suppressed = true;
                }
                // A click outside an open select closes it.
                if (ui.popup) |p| {
                    if (p.rect.contains(m.x, m.y)) {
                        const i: i32 = m.y - p.rect.y - 1;
                        if (i >= 0 and i < p.items.len) ui.choose(p.node, @intCast(i));
                        ui.closePopup();
                        return true;
                    }
                    ui.closePopup();
                    redraw = true;
                }
                const hit = ui.hitAt(m.x, m.y) orelse return redraw;
                const t = ui.clickTarget(hit) orelse {
                    if (ui.focused != 0) {
                        ui.blur();
                        redraw = true;
                    }
                    return redraw;
                };
                ui.pressed = t.node;
                ui.pressed_box = .{ .node = t.node, .part = t.part, .index = t.index };
                if (t.kind.focusable() and t.part == .none) ui.focus(t.node);
                if (t.kind == .slider) ui.sliderTo(t, m.x, false);
                if (t.kind.editable()) ui.caretTo(t, m.x, m.y);
                redraw = true;
            },
            .release => {
                const pb = ui.pressed_box orelse return redraw;
                ui.pressed = 0;
                ui.pressed_box = null;
                redraw = true;
                const hit = ui.hitAt(m.x, m.y) orelse return redraw;
                const t = ui.clickTarget(hit) orelse return redraw;
                if (t.node != pb.node or t.part != pb.part or t.index != pb.index) return redraw;
                ui.activate(t, m.x, m.y);
            },
        }
        return redraw;
    }

    fn boxOf(ui: *Ui, n: Node) ?*Box {
        for (ui.hits.items) |h| if (h.box.node == n and h.box.part == .none) return h.box;
        return null;
    }

    fn caretTo(ui: *Ui, b: *Box, x: i32, y: i32) void {
        _ = y;
        if (b.kind == .number_input) {
            if (x == b.rect.x) return ui.step(b.node, -1);
            if (x == b.rect.x + b.rect.w - 1) return ui.step(b.node, 1);
        }
        if (b.kind != .input) return;
        const e = ui.edit(b.node);
        const want: usize = @intCast(@max(0, x - (b.rect.x + 1)) + @as(i32, @intCast(e.hscroll)));
        var col: usize = 0;
        var it = @import("vaxis").unicode.GraphemeIterator.init(e.buf.items);
        e.caret = e.buf.items.len;
        while (it.next()) |gr| {
            if (col >= want) {
                e.caret = gr.start;
                break;
            }
            col += gridmod.width(gr.bytes(e.buf.items));
        }
    }

    /// A click (or Enter/Space) on a target.
    fn activate(ui: *Ui, t: *Box, x: i32, y: i32) void {
        const n = t.node;
        const src = ui.src;
        if (src.flag(n, "disabled", false)) return;
        switch (t.kind) {
            .button, .link => {
                var buf: [2][16]u8 = undefined;
                const attrs = ui.clickAttrs(t, x, y, &buf);
                src.emit(n, "click", &attrs);
            },
            .checkbox => {
                const on = std.mem.eql(u8, std.mem.trim(u8, src.text(n, "value"), " "), "on");
                ui.userChange(n, if (on) "off" else "on");
            },
            .@"switch" => ui.userChange(n, if (src.flag(n, "value", false)) "off" else "on"),
            .radio_group => if (t.part == .item) {
                ui.state(n).hl = t.index;
                ui.choose(n, t.index);
            },
            .tab => if (t.part == .tab_label) {
                const tabs = t.parent.?.node;
                const name = std.fs.path.basenamePosix(src.path(n));
                ui.focus(tabs);
                if (!std.mem.eql(u8, std.mem.trim(u8, src.text(tabs, "value"), " "), name)) ui.userChange(tabs, name);
            },
            .select => {
                const s = ui.state(n);
                s.open = !s.open;
                if (!s.open) ui.popup = null;
            },
            .slider => {
                var buf: [32]u8 = undefined;
                src.emit(n, "commit", &.{.{ "value", std.fmt.bufPrint(&buf, "{d}", .{src.number(n, "value") orelse 0}) catch "0" }});
            },
            else => {
                var buf: [2][16]u8 = undefined;
                const attrs = ui.clickAttrs(t, x, y, &buf);
                src.emit(n, "click", &attrs);
            },
        }
    }

    /// The user changed a value the component owns: mirror it (unless
    /// the client controls it) and send `change value=`.
    fn userChange(ui: *Ui, n: Node, v: []const u8) void {
        if (!ui.src.flag(n, "controlled", false)) ui.src.mirror(n, "value", v);
        ui.src.emit(n, "change", &.{.{ "value", v }});
    }

    /// Picks item i of a radio group or select.
    fn choose(ui: *Ui, n: Node, i: usize) void {
        const items = ui.src.lines(ui.arena.allocator(), n, "items") catch return;
        if (i >= items.len or items[i].fields.len == 0) return;
        const id = items[i].fields[0];
        if (std.mem.eql(u8, std.mem.trim(u8, ui.src.text(n, "value"), " "), id)) return;
        ui.userChange(n, id);
    }

    fn closePopup(ui: *Ui) void {
        if (ui.popup) |p| ui.state(p.node).open = false;
        ui.popup = null;
    }

    fn sliderTo(ui: *Ui, b: *Box, x: i32, commit: bool) void {
        const n = b.node;
        const min = ui.src.number(n, "min") orelse 0;
        const max = ui.src.number(n, "max") orelse 100;
        const stp = ui.src.number(n, "step") orelse 1;
        const r = innerRect(b);
        const frac = std.math.clamp(@as(f64, @floatFromInt(x - r.x)) / @as(f64, @floatFromInt(@max(1, r.w - 1))), 0, 1);
        var v = min + frac * (max - min);
        if (stp > 0) v = @round((v - min) / stp) * stp + min;
        ui.setNumber(n, std.math.clamp(v, min, max), commit);
    }

    fn setNumber(ui: *Ui, n: Node, v: f64, commit: bool) void {
        var buf: [32]u8 = undefined;
        const s = fmtNum(&buf, v);
        if (!std.mem.eql(u8, std.mem.trim(u8, ui.src.text(n, "value"), " \n"), s)) ui.userChange(n, s);
        if (commit) ui.src.emit(n, "commit", &.{.{ "value", s }});
    }

    fn step(ui: *Ui, n: Node, dir: f64) void {
        const stp = ui.src.number(n, "step") orelse 1;
        var v = (ui.src.number(n, "value") orelse 0) + dir * stp;
        if (ui.src.number(n, "min")) |m| v = @max(v, m);
        if (ui.src.number(n, "max")) |m| v = @min(v, m);
        if (Kind.of(ui.src.typeOf(n)) == .number_input) {
            var buf: [32]u8 = undefined;
            const s = fmtNum(&buf, v);
            const e = ui.edit(n);
            e.buf.clearRetainingCapacity();
            e.buf.appendSlice(ui.gpa, s) catch {};
            e.caret = e.buf.items.len;
        }
        ui.setNumber(n, v, Kind.of(ui.src.typeOf(n)) == .slider);
    }

    pub fn focus(ui: *Ui, n: Node) void {
        if (ui.focused == n) return;
        ui.blur();
        ui.focused = n;
        const k = Kind.of(ui.src.typeOf(n));
        if (k == .input or k == .textarea or k == .number_input or k == .button) ui.src.emit(n, "focus", &.{});
    }

    fn blur(ui: *Ui) void {
        const n = ui.focused;
        if (n == 0) return;
        ui.focused = 0;
        const k = Kind.of(ui.src.typeOf(n));
        if (k == .input or k == .textarea or k == .number_input or k == .button) ui.src.emit(n, "blur", &.{});
        if (ui.popup) |p| if (p.node == n) ui.closePopup();
    }

    fn focusNext(ui: *Ui, dir: i32) void {
        const order = ui.focus_order.items;
        if (order.len == 0) return;
        var i: i32 = -1;
        for (order, 0..) |n, j| if (n == ui.focused) {
            i = @intCast(j);
        };
        const len: i32 = @intCast(order.len);
        const next: i32 = if (i < 0) (if (dir > 0) 0 else len - 1) else @mod(i + dir, len);
        ui.focus(order[@intCast(next)]);
    }

    pub const Key = struct {
        /// A named key (`enter`, `left`, `f5`) or the typed text.
        name: []const u8,
        /// Text the key types, if any.
        text: []const u8 = "",
        ctrl: bool = false,
        alt: bool = false,
        shift: bool = false,
        super: bool = false,
    };

    /// The keystroke as `$ui/keys` spells it: `ctrl-shift-p`, `enter`, `=`.
    pub fn keystroke(k: Key, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        if (k.ctrl) w.writeAll("ctrl-") catch {};
        if (k.alt) w.writeAll("alt-") catch {};
        // Shift is in the text of a printable key already (`+`, `A`).
        if (k.shift and (k.text.len == 0 or k.ctrl or k.alt)) w.writeAll("shift-") catch {};
        if (k.super) w.writeAll("cmd-") catch {};
        if (k.text.len > 0 and !k.ctrl and !k.alt) {
            w.writeAll(if (std.mem.eql(u8, k.text, " ")) "space" else k.text) catch {};
        } else w.writeAll(k.name) catch {};
        return w.buffered();
    }

    pub const KeyResult = enum { handled, unhandled, quit };

    pub fn onKey(ui: *Ui, k: Key) KeyResult {
        const plain = !k.ctrl and !k.alt and !k.super;
        if ((k.ctrl and (std.mem.eql(u8, k.name, "c") or std.mem.eql(u8, k.name, "q")))) return .quit;

        // An open select takes the arrows, Enter and Escape.
        if (ui.popup) |p| {
            const s = ui.state(p.node);
            if (eq(k.name, "down")) s.hl = @min(s.hl + 1, p.items.len -| 1) else if (eq(k.name, "up")) s.hl -|= 1 else if (eq(k.name, "enter") or eq(k.name, "space")) {
                ui.choose(p.node, s.hl);
                ui.closePopup();
            } else if (eq(k.name, "escape")) ui.closePopup() else return .handled;
            return .handled;
        }

        if (eq(k.name, "tab") and !k.ctrl and !k.alt) {
            ui.focusNext(if (k.shift) -1 else 1);
            return .handled;
        }

        const n = ui.focused;
        if (n != 0) {
            const kind = Kind.of(ui.src.typeOf(n));
            if (plain and ui.focusedKey(n, kind, k)) return .handled;
        }
        if (eq(k.name, "escape") and n != 0) {
            ui.blur();
            return .handled;
        }
        var buf: [64]u8 = undefined;
        if (ui.src.key(ui.win, keystroke(k, &buf), n)) return .handled;
        return .unhandled;
    }

    fn focusedKey(ui: *Ui, n: Node, kind: Kind, k: Key) bool {
        const activate_key = eq(k.name, "enter") or eq(k.name, "space") or eq(k.text, " ");
        const b = ui.boxOf(n);
        switch (kind) {
            .button, .link, .checkbox, .@"switch" => if (activate_key) {
                if (b) |bb| ui.activate(bb, bb.rect.x, bb.rect.y);
                return true;
            },
            .radio_group => {
                const items = ui.src.lines(ui.arena.allocator(), n, "items") catch return false;
                const s = ui.state(n);
                if (eq(k.name, "down") or eq(k.name, "right")) {
                    s.hl = @min(s.hl + 1, items.len -| 1);
                    ui.choose(n, s.hl);
                    return true;
                }
                if (eq(k.name, "up") or eq(k.name, "left")) {
                    s.hl -|= 1;
                    ui.choose(n, s.hl);
                    return true;
                }
                if (activate_key) {
                    ui.choose(n, s.hl);
                    return true;
                }
            },
            .tabs => {
                var names: [64]Node = undefined;
                var cnt: usize = 0;
                var cur: usize = 0;
                const sel = ui.selectedTab(n);
                for (ui.src.children(n)) |t| if (Kind.of(ui.src.typeOf(t)) == .tab and cnt < names.len) {
                    if (t == sel) cur = cnt;
                    names[cnt] = t;
                    cnt += 1;
                };
                if (cnt == 0) return false;
                const next: ?usize = if (eq(k.name, "right")) @min(cur + 1, cnt - 1) else if (eq(k.name, "left")) cur -| 1 else null;
                if (next) |i| {
                    if (i != cur) ui.userChange(n, std.fs.path.basenamePosix(ui.src.path(names[i])));
                    return true;
                }
            },
            .select => if (activate_key or eq(k.name, "down")) {
                const s = ui.state(n);
                s.open = true;
                return true;
            },
            .slider => {
                if (eq(k.name, "right") or eq(k.name, "up")) {
                    ui.step(n, 1);
                    return true;
                }
                if (eq(k.name, "left") or eq(k.name, "down")) {
                    ui.step(n, -1);
                    return true;
                }
            },
            .number_input => {
                if (eq(k.name, "up")) {
                    ui.step(n, 1);
                    return true;
                }
                if (eq(k.name, "down")) {
                    ui.step(n, -1);
                    return true;
                }
                return ui.editKey(n, kind, k);
            },
            .input, .textarea => return ui.editKey(n, kind, k),
            else => {},
        }
        return false;
    }

    fn editKey(ui: *Ui, n: Node, kind: Kind, k: Key) bool {
        if (ui.src.flag(n, "readonly", false) and k.text.len > 0) return true;
        const e = ui.edit(n);
        var changed = false;
        if (eq(k.name, "enter")) {
            if (kind == .textarea and !k.shift) {
                e.buf.insert(ui.gpa, e.caret, '\n') catch {};
                e.caret += 1;
                changed = true;
            } else {
                if (changed) ui.edited(n, kind, e);
                ui.submit(n);
                return true;
            }
        } else if (eq(k.name, "backspace")) {
            if (e.caret > 0) {
                const p = prevBoundary(e.buf.items, e.caret);
                e.buf.replaceRangeAssumeCapacity(p, e.caret - p, "");
                e.caret = p;
                changed = true;
            }
        } else if (eq(k.name, "delete")) {
            if (e.caret < e.buf.items.len) {
                const nx = nextBoundary(e.buf.items, e.caret);
                e.buf.replaceRangeAssumeCapacity(e.caret, nx - e.caret, "");
                changed = true;
            }
        } else if (eq(k.name, "left")) {
            e.caret = prevBoundary(e.buf.items, e.caret);
        } else if (eq(k.name, "right")) {
            e.caret = nextBoundary(e.buf.items, e.caret);
        } else if (eq(k.name, "home")) {
            e.caret = if (kind == .textarea) lineStart(e.buf.items, e.caret) else 0;
        } else if (eq(k.name, "end")) {
            e.caret = if (kind == .textarea) lineEnd(e.buf.items, e.caret) else e.buf.items.len;
        } else if (kind == .textarea and (eq(k.name, "up") or eq(k.name, "down"))) {
            e.caret = vertical(e.buf.items, e.caret, eq(k.name, "up"));
        } else if (k.text.len > 0) {
            const max = ui.src.number(n, "max-len");
            if (max) |m| if (std.unicode.utf8CountCodepoints(e.buf.items) catch 0 >= @as(usize, @intFromFloat(m))) return true;
            e.buf.insertSlice(ui.gpa, e.caret, k.text) catch {};
            e.caret += k.text.len;
            changed = true;
        } else return false;
        if (changed) ui.edited(n, kind, e);
        return true;
    }

    fn edited(ui: *Ui, n: Node, kind: Kind, e: *Edit) void {
        const v = e.buf.items;
        if (kind == .number_input) {
            if (std.fmt.parseFloat(f64, std.mem.trim(u8, v, " ")) catch null) |_| ui.userChange(n, v);
            return;
        }
        if (!ui.src.flag(n, "controlled", false)) ui.src.mirror(n, "value", v);
        if (ui.src.flag(n, "secret", false))
            ui.src.emit(n, "change", &.{})
        else
            ui.src.emit(n, "change", &.{.{ "value", v }});
    }

    /// Enter in a field: the enclosing form's `submit`, or the field's.
    fn submit(ui: *Ui, n: Node) void {
        var b = ui.boxOf(n);
        while (b) |bb| : (b = bb.parent) {
            if (bb.kind == .form and bb.part == .none) {
                ui.src.emit(bb.node, "submit", &.{});
                return;
            }
        }
        ui.src.emit(n, "submit", &.{});
    }
};

var dummy_state: NodeState = .{};
var dummy_edit: Edit = .{};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn innerRect(b: *const Box) Rect {
    const br = b.st.layout.border;
    var r = b.rect;
    // Padding is inside Yoga's box too; text sits inside padding.
    const pad = b.st.layout.pad;
    const pl: i32 = (if (br[3]) @as(i32, 1) else 0) + padCells(pad[3]);
    const pr: i32 = (if (br[1]) @as(i32, 1) else 0) + padCells(pad[1]);
    const pt: i32 = (if (br[0]) @as(i32, 1) else 0) + padCells(pad[0]);
    const pb: i32 = (if (br[2]) @as(i32, 1) else 0) + padCells(pad[2]);
    r.x += pl;
    r.y += pt;
    r.w = @max(0, r.w - pl - pr);
    r.h = @max(0, r.h - pt - pb);
    return r;
}

fn padCells(l: ?style.Len) i32 {
    const v = l orelse return 0;
    return switch (v) {
        .pt => |p| @intFromFloat(p),
        else => 0,
    };
}

fn darker(rgba: u32, ui: *Ui) u32 {
    // Borders: GPUI's are hairlines; in cells, a light gray line is too
    // faint on white. Use the ring token when the border is very light.
    const r = (rgba >> 24) & 0xff;
    const g = (rgba >> 16) & 0xff;
    const b = (rgba >> 8) & 0xff;
    const lum = (r * 3 + g * 6 + b) / 10;
    const bg = ui.tok("background", 0xffffffff);
    const bl = (((bg >> 24) & 0xff) * 3 + ((bg >> 16) & 0xff) * 6 + ((bg >> 8) & 0xff)) / 10;
    if (bl > 128 and lum > 200) return ui.tok("ring", 0xa3a3a3ff);
    if (bl <= 128 and lum < 60) return ui.tok("ring", 0x737373ff);
    return rgba;
}

pub const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Icon names (Lucide's, as GPUI Kit has them) to terminal glyphs.
pub fn iconGlyph(name: []const u8) []const u8 {
    const m = std.StaticStringMap([]const u8).initComptime(.{
        .{ "close", "×" },
        .{ "x", "×" },
        .{ "check", "✓" },
        .{ "plus", "+" },
        .{ "minus", "−" },
        .{ "search", "⌕" },
        .{ "inbox", "▭" },
        .{ "info", "ℹ" },
        .{ "circle-check", "✓" },
        .{ "triangle-alert", "⚠" },
        .{ "circle-x", "×" },
        .{ "settings", "⚙" },
        .{ "star", "★" },
        .{ "heart", "♥" },
        .{ "folder", "▤" },
        .{ "file", "▢" },
        .{ "chevron-right", "›" },
        .{ "chevron-left", "‹" },
        .{ "chevron-down", "⌄" },
        .{ "chevron-up", "⌃" },
        .{ "arrow-right", "→" },
        .{ "arrow-left", "←" },
        .{ "arrow-up", "↑" },
        .{ "arrow-down", "↓" },
        .{ "user", "☺" },
        .{ "bell", "♪" },
        .{ "calendar", "▦" },
        .{ "trash", "⌫" },
        .{ "menu", "≡" },
        .{ "ellipsis", "…" },
        .{ "copy", "⧉" },
        .{ "loader", "⠿" },
        .{ "sun", "☼" },
        .{ "moon", "☾" },
        .{ "globe", "◍" },
        .{ "mail", "✉" },
    });
    return m.get(name) orelse "•";
}

fn alertIcon(variant: []const u8) []const u8 {
    if (eq(variant, "success")) return "circle-check";
    if (eq(variant, "warning")) return "triangle-alert";
    if (eq(variant, "error")) return "circle-x";
    return "info";
}

fn fmtNum(buf: []u8, v: f64) []const u8 {
    if (v == @round(v) and @abs(v) < 1e15) return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(v))}) catch "0";
    const s = std.fmt.bufPrint(buf, "{d:.4}", .{v}) catch return "0";
    return std.mem.trimEnd(u8, std.mem.trimEnd(u8, s, "0"), ".");
}

fn displayCols(s: []const u8, secret: bool) usize {
    if (!secret) return gridmod.width(s);
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn prevBoundary(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var p = i - 1;
    while (p > 0 and (s[p] & 0xc0) == 0x80) p -= 1;
    return p;
}

fn nextBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var p = i + 1;
    while (p < s.len and (s[p] & 0xc0) == 0x80) p += 1;
    return p;
}

fn lineStart(s: []const u8, i: usize) usize {
    var p = i;
    while (p > 0 and s[p - 1] != '\n') p -= 1;
    return p;
}

fn lineEnd(s: []const u8, i: usize) usize {
    var p = i;
    while (p < s.len and s[p] != '\n') p += 1;
    return p;
}

fn vertical(s: []const u8, i: usize, up: bool) usize {
    const ls = lineStart(s, i);
    const col = i - ls;
    if (up) {
        if (ls == 0) return 0;
        const pls = lineStart(s, ls - 1);
        return @min(pls + col, ls - 1);
    }
    const le = lineEnd(s, i);
    if (le >= s.len) return s.len;
    const nle = lineEnd(s, le + 1);
    return @min(le + 1 + col, nle);
}

/// The longest prefix of s that fits in w columns.
fn truncate(s: []const u8, w: usize) []const u8 {
    var cols: usize = 0;
    var it = @import("vaxis").unicode.GraphemeIterator.init(s);
    while (it.next()) |gr| {
        const cw = gridmod.width(gr.bytes(s));
        if (cols + cw > w) return s[0..gr.start];
        cols += cw;
    }
    return s;
}

/// Greedy word wrap to w columns; hard newlines kept; long words split.
pub fn wrap(a: std.mem.Allocator, text: []const u8, w: u16) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var hard = std.mem.splitScalar(u8, text, '\n');
    while (hard.next()) |para| {
        if (gridmod.width(para) <= w) {
            try out.append(a, para);
            continue;
        }
        var start: usize = 0;
        while (start < para.len) {
            // Skip leading blanks on a wrapped line.
            while (start < para.len and para[start] == ' ') start += 1;
            if (start >= para.len) break;
            var cols: usize = 0;
            var last_space: ?usize = null;
            var end = start;
            var it = @import("vaxis").unicode.GraphemeIterator.init(para[start..]);
            while (it.next()) |gr| {
                const ch = gr.bytes(para[start..]);
                const cw = gridmod.width(ch);
                if (cols + cw > w) break;
                cols += cw;
                end = start + gr.start + gr.len;
                if (ch[0] == ' ') last_space = start + gr.start;
            }
            if (end >= para.len) {
                try out.append(a, para[start..]);
                break;
            }
            if (last_space) |sp| if (sp > start) {
                try out.append(a, para[start..sp]);
                start = sp + 1;
                continue;
            };
            if (end == start) end = nextBoundary(para, start);
            try out.append(a, para[start..end]);
            start = end;
        }
    }
    return out.items;
}

fn measure(node: c.YGNodeConstRef, w: f32, wmode: c.YGMeasureMode, h: f32, hmode: c.YGMeasureMode) callconv(.c) c.YGSize {
    _ = h;
    _ = hmode;
    const b: *Box = @ptrCast(@alignCast(c.YGNodeGetContext(node)));
    var buf: [16 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const limit: u16 = if (wmode == c.YGMeasureModeUndefined or b.ink.nowrap) std.math.maxInt(u16) else @intFromFloat(@max(1, @floor(w)));
    const ls = wrap(fba.allocator(), b.text, limit) catch return .{ .width = @floatFromInt(gridmod.width(b.text)), .height = 1 };
    var mw: u16 = 0;
    for (ls) |l| mw = @max(mw, gridmod.width(l));
    var width: f32 = @floatFromInt(mw);
    if (wmode == c.YGMeasureModeExactly) width = w;
    if (wmode == c.YGMeasureModeAtMost) width = @min(width, w);
    return .{ .width = width, .height = @floatFromInt(@max(1, ls.len)) };
}

fn measureFixed(node: c.YGNodeConstRef, w: f32, wmode: c.YGMeasureMode, h: f32, hmode: c.YGMeasureMode) callconv(.c) c.YGSize {
    _ = node;
    return .{
        .width = if (wmode == c.YGMeasureModeExactly) w else if (wmode == c.YGMeasureModeAtMost) @min(w, 20) else 20,
        .height = if (hmode == c.YGMeasureModeExactly) h else 1,
    };
}

fn measureSelect(node: c.YGNodeConstRef, w: f32, wmode: c.YGMeasureMode, h: f32, hmode: c.YGMeasureMode) callconv(.c) c.YGSize {
    _ = h;
    _ = hmode;
    const b: *Box = @ptrCast(@alignCast(c.YGNodeGetContext(node)));
    var want: f32 = @floatFromInt(gridmod.width(b.text) + 4);
    want = @max(want, 12);
    return .{ .width = if (wmode == c.YGMeasureModeExactly) w else if (wmode == c.YGMeasureModeAtMost) @min(w, want) else want, .height = 1 };
}

// ---------------------------------------------------------------------
// Tests: a fake tree, laid out and drawn off-screen.

const testing = std.testing;

fn render(f: *source.Fake, w: u16, h: u16, ui: *Ui, g: *Grid) !void {
    _ = f;
    g.* = try Grid.init(testing.allocator, w, h);
    ui.shown = true;
    try ui.frame(g);
}

fn rowText(g: *const Grid, y: usize) ![]u8 {
    return g.row(testing.allocator, y);
}

test "wrap breaks on blanks and splits long words" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ls = try wrap(arena.allocator(), "the quick brown fox\nabcdefghij", 6);
    try testing.expectEqual(@as(usize, 6), ls.len);
    try testing.expectEqualStrings("the", ls[0]);
    try testing.expectEqualStrings("quick", ls[1]);
    try testing.expectEqualStrings("brown", ls[2]);
    try testing.expectEqualStrings("fox", ls[3]);
    try testing.expectEqualStrings("abcdef", ls[4]);
    try testing.expectEqualStrings("ghij", ls[5]);
}

test "the counter lays out centered, and a click reaches the div" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try source.Fake.init(arena.allocator());
    try f.set(".", "style", "h-flex size-full items-center justify-center gap=20 bg=background");
    const b = "size=40 flex items-center justify-center rounded-full border-1 border-color=border hover:bg=accent";
    _ = try f.new("div", "dec", &.{ .{ "tag", "dec" }, .{ "on", "click" } }, b);
    _ = try f.new("text", "n", &.{.{ "text", "0" }}, "text-3xl font-semibold w=72 text-center");
    _ = try f.new("div", "inc", &.{ .{ "tag", "inc" }, .{ "on", "click" } }, b);
    _ = try f.new("text", "dec/t", &.{.{ "text", "−" }}, "");
    _ = try f.new("text", "inc/t", &.{.{ "text", "+" }}, "");
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    ui.title = "Counter";
    var g: Grid = undefined;
    try render(f, 40, 8, &ui, &g);
    defer g.deinit(testing.allocator);
    const r0 = try rowText(&g, 0);
    defer testing.allocator.free(r0);
    try testing.expect(std.mem.indexOf(u8, r0, "Counter") != null);
    // Rows 1..7 are the window; the buttons are 3 rows tall (a border
    // needs a row above and below), centered in 7 rows: rows 3..5.
    const top = try rowText(&g, 3);
    defer testing.allocator.free(top);
    try testing.expect(std.mem.indexOf(u8, top, "╭───╮") != null);
    const mid = try rowText(&g, 4);
    defer testing.allocator.free(mid);
    try testing.expect(std.mem.indexOf(u8, mid, "│ − │") != null);
    try testing.expect(std.mem.indexOf(u8, mid, "0") != null);
    try testing.expect(std.mem.indexOf(u8, mid, "│ + │") != null);
    // Click on the "+": press and release on the same target.
    const plus = std.mem.indexOf(u8, mid, "+").?;
    // Columns are graphemes; count them up to the byte offset.
    const col: i32 = @intCast(std.unicode.utf8CountCodepoints(mid[0..plus]) catch 0);
    _ = ui.onMouse(.{ .x = col, .y = 4, .kind = .press });
    _ = ui.onMouse(.{ .x = col, .y = 4, .kind = .release });
    try testing.expect(std.mem.startsWith(u8, f.log.items, "emit click inc "));
}

test "look tokens: spacing scales the Tailwind steps, radius 0 squares corners" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try source.Fake.init(arena.allocator());
    try f.set(".", "style", "v-flex size-full");
    _ = try f.new("div", "box", &.{}, "w-4 h-8 border-1 rounded-md");
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    defer style.step = 4;
    var g: Grid = undefined;
    // The default 4 points a step: w-4 is 16 points, 2 columns, drawn 3
    // wide since a border needs a cell each side.
    try render(f, 20, 8, &ui, &g);
    var r = try rowText(&g, 1);
    try testing.expect(std.mem.indexOf(u8, r, "╭─╮ ") != null);
    testing.allocator.free(r);
    g.deinit(testing.allocator);
    // spacing 8: 32 points, 4 columns; radius 0: square.
    try f.texts.put(f.a, "spacing", "8");
    try f.texts.put(f.a, "radius", "0");
    try render(f, 20, 8, &ui, &g);
    defer g.deinit(testing.allocator);
    r = try rowText(&g, 1);
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "┌──┐ ") != null);
}

test "a form: field labels, an input that types, Enter submits the form" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try source.Fake.init(arena.allocator());
    try f.set(".", "style", "v-flex size-full p=8 gap=8");
    _ = try f.new("form", "f", &.{.{ "tag", "login" }}, "");
    _ = try f.new("field", "f/user", &.{ .{ "label", "Email" }, .{ "required", "on" } }, "");
    _ = try f.new("input", "f/user/in", &.{.{ "placeholder", "you@example.com" }}, "");
    _ = try f.new("field", "f/pass", &.{ .{ "label", "Password" }, .{ "error", "Enter your password" } }, "");
    _ = try f.new("input", "f/pass/in", &.{.{ "secret", "on" }}, "");
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    var g: Grid = undefined;
    try render(f, 30, 12, &ui, &g);
    defer g.deinit(testing.allocator);
    var dump: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dump.deinit();
    try g.dump(&dump.writer);
    const s = dump.written();
    try testing.expect(std.mem.indexOf(u8, s, "Email *") != null);
    try testing.expect(std.mem.indexOf(u8, s, "you@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Enter your password") != null);
    // Tab focuses the first input; typing mirrors value and sends change.
    try testing.expectEqual(Ui.KeyResult.handled, ui.onKey(.{ .name = "tab" }));
    for ("bob") |ch| _ = ui.onKey(.{ .name = &.{ch}, .text = &.{ch} });
    _ = ui.onKey(.{ .name = "tab" });
    for ("pw") |ch| _ = ui.onKey(.{ .name = &.{ch}, .text = &.{ch} });
    _ = ui.onKey(.{ .name = "enter" });
    const log = f.log.items;
    try testing.expect(std.mem.indexOf(u8, log, "mirror f/user/in value bob\n") != null);
    try testing.expect(std.mem.indexOf(u8, log, "emit change f/user/in value=bob\n") != null);
    // A secret input's change carries no value.
    try testing.expect(std.mem.indexOf(u8, log, "emit change f/pass/in\n") != null);
    try testing.expect(std.mem.endsWith(u8, log, "emit submit f\n"));
    // Drawn again: the password shows as dots.
    try ui.frame(&g);
    dump.clearRetainingCapacity();
    try g.dump(&dump.writer);
    try testing.expect(std.mem.indexOf(u8, dump.written(), "••") != null);
}

test "checkbox, tabs and keystrokes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try source.Fake.init(arena.allocator());
    try f.set(".", "style", "v-flex size-full");
    _ = try f.new("checkbox", "done", &.{ .{ "label", "Milk" }, .{ "value", "off" } }, "");
    _ = try f.new("tabs", "filter", &.{.{ "value", "all" }}, "");
    _ = try f.new("tab", "filter/all", &.{.{ "label", "All" }}, "");
    _ = try f.new("tab", "filter/done", &.{.{ "label", "Done" }}, "");
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    var g: Grid = undefined;
    try render(f, 30, 6, &ui, &g);
    defer g.deinit(testing.allocator);
    const r1 = try rowText(&g, 1);
    defer testing.allocator.free(r1);
    try testing.expect(std.mem.startsWith(u8, r1, "[ ] Milk"));
    _ = ui.onKey(.{ .name = "tab" });
    _ = ui.onKey(.{ .name = "space", .text = " " });
    _ = ui.onKey(.{ .name = "tab" });
    _ = ui.onKey(.{ .name = "right" });
    // An unbound key goes to the core's keymap.
    _ = ui.onKey(.{ .name = "escape" });
    _ = ui.onKey(.{ .name = "=", .text = "=" });
    _ = ui.onKey(.{ .name = "p", .text = "p", .ctrl = true, .shift = true });
    try testing.expectEqualStrings(
        \\mirror done value on
        \\emit change done value=on
        \\mirror filter value done
        \\emit change filter value=done
        \\key =
        \\key ctrl-shift-p
        \\
    , f.log.items);
    try ui.frame(&g);
    const r1b = try rowText(&g, 1);
    defer testing.allocator.free(r1b);
    try testing.expect(std.mem.startsWith(u8, r1b, "[x] Milk"));
}

test "select opens a list, radio and slider take arrows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try source.Fake.init(arena.allocator());
    try f.set(".", "style", "v-flex size-full gap=16");
    _ = try f.new("select", "size", &.{ .{ "items", "s Small\nm Medium\nl Large" }, .{ "value", "m" } }, "");
    _ = try f.new("radio-group", "dir", &.{ .{ "items", "h Horizontal\nv Vertical" }, .{ "value", "h" } }, "");
    _ = try f.new("slider", "vol", &.{ .{ "value", "50" }, .{ "step", "10" } }, "w=160");
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    var g: Grid = undefined;
    try render(f, 30, 12, &ui, &g);
    defer g.deinit(testing.allocator);
    var dump: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dump.deinit();
    try g.dump(&dump.writer);
    try testing.expect(std.mem.indexOf(u8, dump.written(), " Medium") != null);
    try testing.expect(std.mem.indexOf(u8, dump.written(), "(•) Horizontal") != null);
    try testing.expect(std.mem.indexOf(u8, dump.written(), "●") != null);
    _ = ui.onKey(.{ .name = "tab" });
    _ = ui.onKey(.{ .name = "enter" });
    try ui.frame(&g);
    dump.clearRetainingCapacity();
    try g.dump(&dump.writer);
    try testing.expect(std.mem.indexOf(u8, dump.written(), "✓ Medium") != null);
    _ = ui.onKey(.{ .name = "down" });
    _ = ui.onKey(.{ .name = "down" });
    _ = ui.onKey(.{ .name = "enter" });
    _ = ui.onKey(.{ .name = "tab" });
    _ = ui.onKey(.{ .name = "down" });
    _ = ui.onKey(.{ .name = "tab" });
    _ = ui.onKey(.{ .name = "right" });
    try testing.expectEqualStrings(
        \\mirror size value l
        \\emit change size value=l
        \\mirror dir value v
        \\emit change dir value=v
        \\mirror vol value 60
        \\emit change vol value=60
        \\emit commit vol value=60
        \\
    , f.log.items);
}

test "a modal dialog hides what's under it and keeps focus" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try source.Fake.init(arena.allocator());
    try f.set(".", "style", "v-flex size-full");
    for (0..6) |i| _ = try f.new("text", try std.fmt.allocPrint(arena.allocator(), "t{d}", .{i}), &.{.{ "text", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }}, "");
    const in = try f.new("input", "in", &.{}, "");
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    var g: Grid = undefined;
    try render(f, 30, 10, &ui, &g);
    defer g.deinit(testing.allocator);
    // Its bounds file gets window points: the seventh row, full width.
    try testing.expectEqual([4]f32{ 0, 6 * 16, 30 * 8, 16 }, f.nodes.items[in].bounds.?);
    ui.focus(in);

    _ = try f.new("dialog", "over/hi", &.{ .{ "title", "Welcome" }, .{ "open", "on" } }, "");
    _ = try f.new("div", "over/hi/footer", &.{}, "");
    const ok = try f.new("button", "over/hi/footer/ok", &.{.{ "label", "OK" }}, "");
    try ui.frame(&g);
    var dump: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dump.deinit();
    try g.dump(&dump.writer);
    // The dialog's rows show its own text, not the x's under it (two
    // columns of the scrim show at each side).
    var lines = std.mem.splitScalar(u8, dump.written(), '\n');
    var saw = false;
    while (lines.next()) |l| if (std.mem.indexOf(u8, l, "Welcome") != null) {
        saw = true;
        try testing.expect(std.mem.indexOf(u8, l, "xxx") == null);
    };
    try testing.expect(saw);
    try testing.expectEqual(ok, ui.focused);
    try testing.expect(g.cursor == null);
    // Tab stays inside the dialog.
    _ = ui.onKey(.{ .name = "tab" });
    try testing.expectEqual(ok, ui.focused);

    // Closed, focus goes back where it was.
    try f.set("over/hi", "open", "off");
    try ui.frame(&g);
    try testing.expectEqual(in, ui.focused);
    try testing.expect(g.cursor != null);
}

test "a tooltip file shows above its node after the delay, and a press hides it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try source.Fake.init(arena.allocator());
    try f.set(".", "style", "v-flex size-full items-center justify-center");
    _ = try f.new("button", "save", &.{ .{ "label", "Save" }, .{ "tooltip", "Save file" } }, "");
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    var g: Grid = undefined;
    try render(f, 40, 10, &ui, &g);
    defer g.deinit(testing.allocator);
    // Find the button's label row.
    var row: usize = 0;
    var col: i32 = 0;
    for (1..g.h) |y| {
        const t = try rowText(&g, y);
        defer testing.allocator.free(t);
        if (std.mem.indexOf(u8, t, "Save")) |i| {
            row = y;
            col = @intCast(std.unicode.utf8CountCodepoints(t[0..i]) catch 0);
        }
    }
    try testing.expect(row > 2);
    try testing.expectEqual(@as(?u32, null), ui.tipPending());
    _ = ui.onMouse(.{ .x = col, .y = @intCast(row), .kind = .motion });
    const gen = ui.tipPending().?;
    // One timer per hover.
    try testing.expectEqual(@as(?u32, null), ui.tipPending());
    try testing.expect(ui.tipDue(gen));
    try ui.frame(&g);
    var above: bool = false;
    for (1..row) |y| {
        const t = try rowText(&g, y);
        defer testing.allocator.free(t);
        if (std.mem.indexOf(u8, t, "Save file") != null) above = true;
    }
    try testing.expect(above);
    // A press hides it, and it stays hidden while the pointer is there.
    _ = ui.onMouse(.{ .x = col, .y = @intCast(row), .kind = .press });
    try testing.expect(!ui.tip.shown);
    try testing.expectEqual(@as(?u32, null), ui.tipPending());
    // Leaving and coming back shows it again, after a new delay; a stale
    // timer does nothing.
    _ = ui.onMouse(.{ .x = 0, .y = 1, .kind = .motion });
    _ = ui.onMouse(.{ .x = col, .y = @intCast(row), .kind = .motion });
    try testing.expect(!ui.tipDue(gen));
    try testing.expect(ui.tipDue(ui.tipPending().?));
}
