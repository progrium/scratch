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
const raster = @import("raster.zig");

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
    grid,
    toolbar,
    button_group,
    toggle,
    status_bar,
    title_bar,
    table,
    list,
    tree,
    canvas,
    chart,
    description_list,
    sidebar,
    sidebar_group,
    sidebar_item,
    group_box,
    avatar,
    editor,
    markdown,
    sheet,
    alert_dialog,
    resizable,
    panel,
    dock,
    dock_panel,
    message_list,
    collapsible,
    accordion,
    accordion_item,
    breadcrumb,
    dropdown_button,
    tag,
    web,
    terminal,
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
            .{ "grid", .grid },                 .{ "toolbar", .toolbar },         .{ "button-group", .button_group },
            .{ "toggle", .toggle },             .{ "status-bar", .status_bar },   .{ "title-bar", .title_bar },
            .{ "table", .table },               .{ "list", .list },               .{ "tree", .tree },
            .{ "canvas", .canvas },             .{ "chart", .chart },             .{ "description-list", .description_list },
            .{ "sidebar", .sidebar },           .{ "sidebar-group", .sidebar_group }, .{ "sidebar-item", .sidebar_item },
            .{ "group-box", .group_box },       .{ "avatar", .avatar },           .{ "editor", .editor },
            .{ "markdown", .markdown },         .{ "sheet", .sheet },             .{ "alert-dialog", .alert_dialog },
            .{ "resizable", .resizable },       .{ "panel", .panel },             .{ "dock", .dock },
            .{ "dock-panel", .dock_panel },     .{ "message-list", .message_list }, .{ "collapsible", .collapsible },
            .{ "accordion", .accordion },       .{ "accordion-item", .accordion_item }, .{ "breadcrumb", .breadcrumb },
            .{ "dropdown-button", .dropdown_button }, .{ "tag", .tag },
            .{ "web", .web },                   .{ "terminal", .terminal },
        });
        return m.get(t) orelse .other;
    }

    /// Takes keyboard focus (Tab moves between these).
    pub fn focusable(k: Kind) bool {
        return switch (k) {
            .button, .checkbox, .radio_group, .@"switch", .select, .input, .textarea, .number_input, .slider, .link, .tabs, .toggle, .editor, .table, .list, .tree, .dropdown_button, .terminal => true,
            else => false,
        };
    }

    /// Takes typed text, so printable keys don't reach uit_key.
    pub fn editable(k: Kind) bool {
        return k == .input or k == .textarea or k == .number_input or k == .editor;
    }

    /// Takes text a line at a time, as a textarea does.
    pub fn multiline(k: Kind) bool {
        return k == .textarea or k == .editor;
    }
};

/// A synthetic piece of a component: a field's label, a radio item.
pub const Part = enum {
    none,
    label,
    item,
    field_label,
    field_desc,
    field_error,
    tab_header,
    tab_label,
    title,
    desc,
    dec,
    inc,
    count,
    /// A data view's row (index: the item's line), and its cells.
    row,
    cell,
    /// A table's header row and its cells (index: the column).
    header,
    /// An alert dialog's buttons.
    confirm,
    cancel,
    /// A dock zone's tab for one panel (node: the panel).
    zone_tab,
    /// What opens and closes a collapsible or an accordion item.
    trigger,
    /// A breadcrumb item (index: its line).
    crumb,
    /// A box a component adds to arrange its parts.
    frame,
};

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
    /// A data view row's item id.
    id: []const u8 = "",
};

/// A row template's values by field name (list.rs's item_values).
pub const Vals = std.StringHashMapUnmanaged([]const u8);

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
    /// A terminal's grid as last sent with uit_term_resize: cols, rows and
    /// the cell's pixel size.
    term: [4]u32 = .{ 0, 0, 0, 0 },
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
    /// Opens a link's `href`, where the host can (the browser build: a new
    /// tab). Null in a terminal, where a link only sends its click.
    open_url: ?*const fn ([]const u8) void = null,
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
    /// While a list stamps its row template: the item's values by name.
    vals: ?*const Vals = null,
    /// The canvas a button went down on, for mouse-up, click and drag.
    canvas_pressed: Node = 0,
    /// The row-like part under the pointer, to redraw when it changes.
    mouse_row: ?*Box = null,
    /// The terminal a button went down on: its drag and release go there.
    term_pressed: Node = 0,
    /// One cell's size in device pixels, when the terminal says (vaxis's
    /// winsize); terminal nodes pass it on with uit_term_resize.
    cell_px: [2]u32 = .{ 0, 0 },

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
        if (ui.term_pressed == n) ui.term_pressed = 0;
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
            const bw: f32 = @floatFromInt(body.w);
            const bh: f32 = @floatFromInt(body.h);
            const sheet = ob.kind == .sheet;
            const side = std.mem.trim(u8, ui.src.text(ov, "side"), " \n");
            const across = eq(side, "top") or eq(side, "bottom");
            if (sheet) {
                // A sheet is a side of the window: the full height (or
                // width) and `size` points across.
                const sz: f32 = @floatCast(ui.src.number(ov, "size") orelse 350);
                if (across) {
                    c.YGNodeStyleSetWidth(ob.yg, bw);
                    c.YGNodeStyleSetHeight(ob.yg, @min(bh, @max(3, style.cells(sz, .y))));
                } else {
                    c.YGNodeStyleSetWidth(ob.yg, @min(bw, @max(10, style.cells(sz, .x))));
                    c.YGNodeStyleSetHeight(ob.yg, bh);
                }
            } else {
                const want_w: f32 = if (ui.src.number(ov, "width")) |pw| style.cells(@floatCast(pw), .x) else @min(60, bw - 4);
                c.YGNodeStyleSetWidth(ob.yg, @min(want_w, bw));
                c.YGNodeStyleSetMaxHeight(ob.yg, bh);
            }
            c.YGNodeCalculateLayout(ob.yg, c.YGUndefined, c.YGUndefined, c.YGDirectionLTR);
            const ow: i32 = @intFromFloat(c.YGNodeLayoutGetWidth(ob.yg));
            const oh: i32 = @intFromFloat(c.YGNodeLayoutGetHeight(ob.yg));
            if (ui.src.flag(ov, "modal", true)) g.fill(body, body, 0x00000060);
            var ox = body.x + @divTrunc(body.w - ow, 2);
            var oy = body.y + @max(0, @divTrunc(body.h - oh, 3));
            if (sheet) {
                ox = if (eq(side, "left") or across) body.x else body.x + body.w - ow;
                oy = if (eq(side, "bottom")) body.y + body.h - oh else body.y;
            }
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
            .web => {
                // No page engine in a terminal: a bordered box naming the page.
                L.border = .{ true, true, true, true };
                if (L.grow == null) L.grow = 1;
                if (L.dir == null) L.dir = .col;
                if (L.items == null) L.items = .center;
                if (L.justify == null) L.justify = .center;
                st.look.rounded = true;
            },
            .terminal => {
                // The screen fills what it is given; the program learns the
                // grid from uit_term_resize. Across its parent's axis it
                // stretches too, even in an `h-flex` that centers.
                if (L.h == null and L.grow == null) L.grow = 1;
                L.self = L.self orelse .stretch;
                if (L.min_w == null) L.min_w = .{ .pt = 10 };
                if (L.min_h == null) L.min_h = .{ .pt = 3 };
                if (L.overflow == .visible) L.overflow = .hidden;
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
            .toolbar, .button_group, .breadcrumb, .title_bar => {
                if (L.dir == null) L.dir = if (kind == .button_group and eq(ui.src.text(n, "dir"), "col")) .col else .row;
                if (L.items == null) L.items = .center;
                if (L.gap_x == null) L.gap_x = 1;
                // A bar keeps its height when the content below overflows
                // (Yoga would stretch its buttons across instead).
                L.shrink = L.shrink orelse 0;
                if (kind == .title_bar) {
                    if (L.pad[1] == null) L.pad[1] = .{ .pt = 1 };
                    if (L.pad[3] == null) L.pad[3] = .{ .pt = 1 };
                    if (st.look.bg == null) st.look.bg = ui.tok("title-bar", ui.tok("muted", 0xf5f5f5ff));
                }
            },
            .status_bar => {
                if (L.dir == null) L.dir = .row;
                if (L.items == null) L.items = .center;
                if (L.justify == null) L.justify = .between;
                if (L.gap_x == null) L.gap_x = 2;
                if (L.pad[1] == null) L.pad[1] = .{ .pt = 1 };
                if (L.pad[3] == null) L.pad[3] = .{ .pt = 1 };
                L.shrink = L.shrink orelse 0;
                if (st.look.bg == null) st.look.bg = ui.tok("muted", 0xf5f5f5ff);
            },
            .toggle, .dropdown_button => {
                if (L.dir == null) L.dir = .row;
                if (L.items == null) L.items = .center;
                if (L.pad[1] == null) L.pad[1] = .{ .pt = 1 };
                if (L.pad[3] == null) L.pad[3] = .{ .pt = 1 };
                if (L.gap_x == null) L.gap_x = 1;
                L.shrink = L.shrink orelse 0;
            },
            .grid => {
                L.dir = .col;
                const gp: f32 = @floatCast(ui.src.number(n, "gap") orelse 0);
                // A gap keeps rows of buttons apart, even under a row tall.
                if (L.gap_y == null) L.gap_y = if (gp > 0) @max(1, style.cells(gp, .y)) else 0;
                if (L.gap_x == null) L.gap_x = style.cells(gp, .x);
            },
            .table, .list, .tree, .message_list => {
                if (L.dir == null) L.dir = .col;
                if (L.overflow == .visible) L.overflow = .scroll;
                if (L.h == null and L.grow == null and L.max_h == null) L.grow = 1;
                if (L.min_h == null) L.min_h = .{ .pt = 2 };
                if (kind == .message_list and L.gap_y == null) L.gap_y = 1;
            },
            .canvas => {
                if (L.h == null and L.grow == null) L.grow = 1;
                if (L.min_h == null) L.min_h = .{ .pt = 2 };
                L.shrink = L.shrink orelse 0;
            },
            .chart => {
                if (L.h == null and L.grow == null) L.h = .{ .pt = 10 };
                if (L.min_w == null) L.min_w = .{ .pt = 16 };
            },
            .description_list => {
                L.dir = .col;
                if (L.gap_y == null) L.gap_y = 1;
            },
            .sidebar => {
                if (L.dir == null) L.dir = .col;
                if (L.w == null) L.w = .{ .pt = if (ui.src.flag(n, "collapsed", false)) 5 else 28 };
                L.shrink = L.shrink orelse 0;
                if (L.overflow == .visible) L.overflow = .scroll;
                if (L.pad[0] == null) L.pad = .{ .{ .pt = 1 }, .{ .pt = 1 }, .{ .pt = 1 }, .{ .pt = 1 } };
                if (L.gap_y == null) L.gap_y = 1;
                L.border[if (eq(ui.src.text(n, "side"), "right")) 3 else 1] = true;
                if (st.look.bg == null) st.look.bg = ui.tok("sidebar", ui.tok("muted", 0xf5f5f5ff));
            },
            .sidebar_group, .sidebar_item, .markdown, .dock_panel, .collapsible, .accordion => {
                if (L.dir == null) L.dir = .col;
            },
            .group_box => {
                L.border = .{ true, true, true, true };
                if (L.dir == null) L.dir = .col;
                if (L.pad[1] == null) L.pad[1] = .{ .pt = 1 };
                if (L.pad[3] == null) L.pad[3] = .{ .pt = 1 };
                st.look.rounded = true;
            },
            .avatar => {
                L.shrink = L.shrink orelse 0;
            },
            .editor => {
                if (L.h == null and L.grow == null) L.grow = 1;
                if (L.min_h == null) L.min_h = .{ .pt = 3 };
                if (L.min_w == null) L.min_w = .{ .pt = 20 };
            },
            .sheet, .alert_dialog => {
                L.border = .{ true, true, true, true };
                L.dir = L.dir orelse .col;
                if (L.pad[1] == null) L.pad = .{ .{ .pt = 0 }, .{ .pt = 2 }, .{ .pt = 0 }, .{ .pt = 2 } };
                if (L.gap_y == null) L.gap_y = 1;
                st.look.rounded = kind == .alert_dialog;
                if (st.look.bg == null) st.look.bg = ui.tok("popover", ui.tok("background", 0xffffffff));
            },
            .resizable => {
                if (L.dir == null) L.dir = if (eq(ui.src.text(n, "dir"), "col")) .col else .row;
                if (L.grow == null and L.h == null) L.grow = 1;
            },
            .panel => {
                if (L.dir == null) L.dir = .col;
                if (L.overflow == .visible) L.overflow = .hidden;
            },
            .accordion_item => {
                if (L.dir == null) L.dir = .col;
                L.border[2] = true;
            },
            .dock => {
                if (L.dir == null) L.dir = .row;
                if (L.grow == null and L.h == null) L.grow = 1;
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
                if (ui.vals) |v| b.text = try substitute(a, b.text, v);
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .img, .svg => {
                const s = src.text(n, "src");
                b.text = try std.fmt.allocPrint(a, "[{s}{s}{s}]", .{ if (b.kind == .img) "image" else "svg", if (s.len > 0) " " else "", std.fs.path.basename(s) });
                b.ink.dim = true;
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .icon => {
                const name = src.text(n, "name");
                b.text = iconGlyph(if (ui.vals) |v| try substitute(a, name, v) else name);
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
            .input, .textarea, .number_input, .slider, .progress, .separator, .editor => {
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
            .web => {
                var wi = ink;
                wi.dim = true;
                const url = std.mem.trim(u8, src.text(n, "url"), " \t\n");
                const t = if (src.text(n, "html").len > 0) "[web: inline html]" else if (url.len > 0) try std.fmt.allocPrint(a, "[web {s}]", .{url}) else "[web]";
                _ = try ui.leaf(n, .text, .none, b, wi, t);
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
            .grid => {
                const cols: usize = @intFromFloat(@max(1, @min(64, src.number(n, "cols") orelse 2)));
                var row: ?*Box = null;
                var at: usize = 0;
                for (src.children(n)) |k| {
                    const span = @min(cols, ui.colSpan(k, cols));
                    if (row != null and at + span > cols) {
                        while (at < cols) : (at += 1) gridCell(try ui.frameBox(n, .grid, .frame, row.?, ink, false, 0), 1);
                        at = 0;
                    }
                    if (at == 0) {
                        row = try ui.frameBox(n, .grid, .frame, b, ink, true, b.st.layout.gap_x orelse 0);
                        // Rows share a grid that is given a height.
                        c.YGNodeStyleSetFlexGrow(row.?.yg, 1);
                    }
                    gridCell(try ui.build(k, row.?, ink), span);
                    at += span;
                    if (at >= cols) at = 0;
                }
                if (row) |r| if (at > 0) while (at < cols) : (at += 1) {
                    gridCell(try ui.frameBox(n, .grid, .frame, r, ink, false, 0), 1);
                };
            },
            .status_bar => for ([_][]const u8{ "left", "center", "right" }) |slot| {
                if (ui.childNamed(n, slot)) |k| _ = try ui.build(k, b, ink) else _ = try ui.frameBox(n, .status_bar, .frame, b, ink, true, 0);
            },
            .title_bar => {
                const t = src.text(n, "title");
                if (t.len > 0) {
                    var ti = ink;
                    ti.bold = true;
                    _ = try ui.leaf(n, .text, .title, b, ti, t);
                }
                for (src.children(n)) |k| _ = try ui.build(k, b, ink);
            },
            .breadcrumb => {
                const items = try src.lines(a, n, "items");
                for (items, 0..) |it, i| {
                    const e = entryOf(it.fields) orelse continue;
                    if (i > 0) _ = try ui.leaf(n, .text, .frame, b, ui.mutedInk(ink), "›");
                    var ci = if (i + 1 == items.len) ink else ui.mutedInk(ink);
                    ci.bold = i + 1 == items.len;
                    const lb = try ui.leaf(n, .breadcrumb, .crumb, b, ci, e.label);
                    lb.index = @intCast(i);
                    lb.id = e.id;
                }
            },
            .toggle, .dropdown_button => {
                if (src.prop(n, "icon")) |ic| _ = try ui.leaf(n, .text, .frame, b, ink, iconGlyph(std.mem.trim(u8, ic, " \n")));
                const label = src.text(n, "label");
                if (label.len > 0) _ = try ui.leaf(n, .text, .label, b, ink, label);
                if (b.kind == .dropdown_button) _ = try ui.leaf(n, .text, .frame, b, ink, "▾");
                if (b.kids.items.len == 0) _ = try ui.leaf(n, .text, .label, b, ink, " ");
            },
            .table => try ui.buildTable(b),
            .list => try ui.buildList(b),
            .tree => {
                const items = try src.lines(a, n, "items");
                try ui.treeRows(b, items, src.text(n, "expanded"), "-", 0);
            },
            .description_list => {
                const items = try src.lines(a, n, "items");
                const cols: usize = @intFromFloat(@max(1, @min(16, src.number(n, "columns") orelse 3)));
                const top = eq(std.mem.trim(u8, src.text(n, "labels"), " \n"), "top");
                var row: ?*Box = null;
                var i: usize = 0;
                for (items) |it| {
                    if (it.fields.len == 0) continue;
                    if (i % cols == 0) row = try ui.frameBox(n, .description_list, .frame, b, ink, true, 2);
                    const cell = try ui.frameBox(n, .description_list, .frame, row.?, ink, !top, 1);
                    gridCell(cell, 1);
                    var li = ui.mutedInk(ink);
                    li.nowrap = true;
                    const lb = try ui.leaf(n, .text, .frame, cell, li, it.fields[0]);
                    c.YGNodeStyleSetFlexShrink(lb.yg, 0);
                    if (src.number(n, "label-width")) |lw| c.YGNodeStyleSetWidth(lb.yg, style.cells(@floatCast(lw), .x));
                    _ = try ui.leaf(n, .text, .frame, cell, ink, try std.mem.join(a, " ", it.fields[1..]));
                    i += 1;
                }
                if (row) |r| while (i % cols != 0) : (i += 1) {
                    gridCell(try ui.frameBox(n, .description_list, .frame, r, ink, false, 0), 1);
                };
            },
            .sidebar => {
                const hdr = ui.childNamed(n, "header");
                const ftr = ui.childNamed(n, "footer");
                if (hdr) |k| _ = try ui.build(k, b, ink);
                for (src.children(n)) |k| if (k != hdr and k != ftr) {
                    _ = try ui.build(k, b, ink);
                };
                if (ftr) |k| {
                    c.YGNodeStyleSetFlexGrow((try ui.frameBox(n, .sidebar, .frame, b, ink, false, 0)).yg, 1);
                    _ = try ui.build(k, b, ink);
                }
            },
            .sidebar_group => {
                const label = src.text(n, "label");
                if (label.len > 0) {
                    var li = ui.mutedInk(ink);
                    li.bold = true;
                    _ = try ui.leaf(n, .text, .frame, b, li, label);
                }
                for (src.children(n)) |k| _ = try ui.build(k, b, ink);
            },
            .sidebar_item => {
                var ri = ink;
                if (src.flag(n, "active", false)) ri.bold = true;
                if (src.flag(n, "disabled", false)) ri.dim = true;
                const rb = try ui.frameBox(n, .sidebar_item, .row, b, ri, true, 1);
                c.YGNodeStyleSetPadding(rb.yg, c.YGEdgeHorizontal, 1);
                if (src.prop(n, "icon")) |ic| _ = try ui.leaf(n, .text, .frame, rb, ri, iconGlyph(std.mem.trim(u8, ic, " \n")));
                ri.nowrap = true;
                ri.truncate = true;
                const lb = try ui.leaf(n, .text, .frame, rb, ri, src.text(n, "label"));
                c.YGNodeStyleSetFlexGrow(lb.yg, 1);
                const badge = src.text(n, "badge");
                if (badge.len > 0) _ = try ui.leaf(n, .text, .frame, rb, ui.mutedInk(ink), badge);
                if (src.children(n).len > 0) {
                    const sub = try ui.frameBox(n, .sidebar_item, .frame, b, ink, false, 0);
                    c.YGNodeStyleSetPadding(sub.yg, c.YGEdgeLeft, 2);
                    for (src.children(n)) |k| _ = try ui.build(k, sub, ink);
                }
            },
            .group_box, .sheet => {
                const title = src.text(n, "title");
                if (title.len > 0) {
                    var ti = ink;
                    ti.bold = true;
                    _ = try ui.leaf(n, .text, .title, b, ti, title);
                }
                for (src.children(n)) |k| _ = try ui.build(k, b, ink);
            },
            .avatar => {
                b.text = try initials(a, src.text(n, "name"));
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .tag => {
                b.text = try std.fmt.allocPrint(a, " {s}{s} ", .{ src.text(n, "label"), if (src.flag(n, "closable", false)) " ×" else "" });
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .markdown => {
                b.text = try mdPlain(a, src.text(n, "text"));
                c.YGNodeSetMeasureFunc(b.yg, measure);
            },
            .alert_dialog => {
                var ti = ink;
                ti.bold = true;
                const title = src.text(n, "title");
                if (title.len > 0) _ = try ui.leaf(n, .text, .title, b, ti, title);
                const desc = src.text(n, "description");
                if (desc.len > 0) _ = try ui.leaf(n, .text, .desc, b, ui.mutedInk(ink), desc);
                for (src.children(n)) |k| _ = try ui.build(k, b, ink);
                const foot = try ui.frameBox(n, .alert_dialog, .frame, b, ink, true, 2);
                c.YGNodeStyleSetJustifyContent(foot.yg, c.YGJustifyFlexEnd);
                const cancel = std.mem.trim(u8, src.text(n, "cancel"), " \n");
                if (cancel.len > 0) _ = try ui.leaf(n, .alert_dialog, .cancel, foot, ink, try std.fmt.allocPrint(a, " {s} ", .{cancel}));
                var confirm = std.mem.trim(u8, src.text(n, "confirm"), " \n");
                if (confirm.len == 0) confirm = "OK";
                _ = try ui.leaf(n, .alert_dialog, .confirm, foot, ink, try std.fmt.allocPrint(a, " {s} ", .{confirm}));
            },
            .resizable => {
                const row = !eq(std.mem.trim(u8, src.text(n, "dir"), " \n"), "col");
                for (src.children(n), 0..) |k, i| {
                    if (i > 0) {
                        const sp = try ui.newBox(n, .separator, b, ink);
                        sp.part = .frame;
                        if (row) c.YGNodeStyleSetWidth(sp.yg, 1) else c.YGNodeStyleSetHeight(sp.yg, 1);
                        c.YGNodeStyleSetFlexShrink(sp.yg, 0);
                        c.YGNodeStyleSetAlignSelf(sp.yg, c.YGAlignStretch);
                    }
                    const pb = try ui.build(k, b, ink);
                    if (Kind.of(src.typeOf(k)) != .panel) continue;
                    if (src.number(k, "size")) |sz| {
                        c.YGNodeStyleSetFlexBasis(pb.yg, style.cells(@floatCast(sz), if (row) .x else .y));
                        if (pb.st.layout.grow == null) c.YGNodeStyleSetFlexGrow(pb.yg, 0);
                        c.YGNodeStyleSetFlexShrink(pb.yg, 1);
                    } else {
                        if (pb.st.layout.grow == null) c.YGNodeStyleSetFlexGrow(pb.yg, 1);
                        c.YGNodeStyleSetFlexBasis(pb.yg, 0);
                    }
                }
            },
            .dock => {
                const zones = [_][]const u8{ "left", "center", "bottom", "right" };
                var have = [_]bool{ false, false, false, false };
                for (src.children(n)) |k| have[zoneOf(src, k)] = true;
                if (have[0]) c.YGNodeStyleSetWidth((try ui.dockZone(b, b, zones[0])).yg, 28);
                const mid = try ui.frameBox(n, .dock, .frame, b, ink, false, 0);
                c.YGNodeStyleSetFlexGrow(mid.yg, 1);
                c.YGNodeStyleSetFlexBasis(mid.yg, 0);
                if (have[1] or !have[2]) c.YGNodeStyleSetFlexGrow((try ui.dockZone(b, mid, zones[1])).yg, 1);
                if (have[2]) c.YGNodeStyleSetHeight((try ui.dockZone(b, mid, zones[2])).yg, 10);
                if (have[3]) c.YGNodeStyleSetWidth((try ui.dockZone(b, b, zones[3])).yg, 28);
            },
            .message_list => {
                const msgs = try parseMessages(a, src.text(n, "items"));
                for (msgs, 0..) |m, i| {
                    const user = eq(m.role, "user");
                    const mb = try ui.frameBox(n, .message_list, .row, b, ink, false, 0);
                    mb.index = @intCast(i);
                    mb.id = m.role;
                    c.YGNodeStyleSetPadding(mb.yg, c.YGEdgeHorizontal, 1);
                    c.YGNodeStyleSetFlexShrink(mb.yg, 0);
                    c.YGNodeStyleSetMaxWidthPercent(mb.yg, 85);
                    c.YGNodeStyleSetAlignSelf(mb.yg, if (user) c.YGAlignFlexEnd else c.YGAlignFlexStart);
                    const head = if (m.time.len > 0) try std.fmt.allocPrint(a, "{s} · {s}", .{ m.role, m.time }) else m.role;
                    _ = try ui.leaf(n, .text, .frame, mb, ui.mutedInk(ink), head);
                    _ = try ui.leaf(n, .text, .frame, mb, ink, try mdPlain(a, m.body));
                }
                const st = ui.state(n);
                if (src.flag(n, "stick-to-bottom", true) and !st.open) st.scroll_y = 1 << 20;
            },
            .collapsible => {
                if (ui.childNamed(n, "trigger")) |t| _ = try ui.build(t, try ui.frameBox(n, .collapsible, .trigger, b, ink, false, 0), ink);
                if (src.flag(n, "open", false)) if (ui.childNamed(n, "content")) |k| {
                    _ = try ui.build(k, b, ink);
                };
            },
            .accordion_item => {
                const acc = if (b.parent) |p| p.node else 0;
                const open = hasWord(src.text(acc, "value"), std.fs.path.basenamePosix(src.path(n)));
                var ti = ink;
                ti.bold = true;
                if (src.flag(n, "disabled", false)) ti.dim = true;
                _ = try ui.leaf(n, .accordion_item, .trigger, b, ti, try std.fmt.allocPrint(a, "{s} {s}", .{ if (open) "▾" else "▸", src.text(n, "title") }));
                if (open) {
                    const body = try ui.frameBox(n, .accordion_item, .frame, b, ink, false, 0);
                    c.YGNodeStyleSetPadding(body.yg, c.YGEdgeLeft, 2);
                    for (src.children(n)) |k| _ = try ui.build(k, body, ink);
                }
            },
            .canvas, .chart => {},
            else => for (src.children(n)) |k| {
                _ = try ui.build(k, b, ink);
            },
        }
    }

    /// A box a component adds to arrange its parts (a table row, a grid
    /// row), as a row or a column with `gap` cells between its children.
    fn frameBox(ui: *Ui, n: Node, kind: Kind, part: Part, parent: *Box, ink: Ink, row: bool, gap: f32) !*Box {
        const f = try ui.newBox(n, kind, parent, ink);
        f.part = part;
        f.hidden = parent.hidden;
        c.YGNodeStyleSetFlexDirection(f.yg, if (row) c.YGFlexDirectionRow else c.YGFlexDirectionColumn);
        if (gap > 0) c.YGNodeStyleSetGap(f.yg, if (row) c.YGGutterColumn else c.YGGutterRow, gap);
        return f;
    }

    /// A grid child's `col-span` (`col-span-full`: every column).
    fn colSpan(ui: *Ui, k: Node, cols: usize) usize {
        for (ui.src.style(k)) |w| {
            const name = core.slice(w.name);
            if (eq(name, "col-span-full")) return cols;
            if (eq(name, "col-span") and w.n_args > 0) return @intFromFloat(@max(1, @min(64, w.args[0].a)));
        }
        return 1;
    }

    fn childNamed(ui: *Ui, n: Node, name: []const u8) ?Node {
        for (ui.src.children(n)) |k| if (eq(std.fs.path.basenamePosix(ui.src.path(k)), name)) return k;
        return null;
    }

    fn mutedInk(ui: *Ui, ink: Ink) Ink {
        var i = ink;
        i.fg = ui.tok("muted-foreground", 0x737373ff);
        return i;
    }

    /// A table: a header row (cells part `title`, index the column) and a
    /// row per `rows` line (part `row`): its id, then a cell per column.
    fn buildTable(ui: *Ui, b: *Box) !void {
        const n = b.node;
        const a = ui.arena.allocator();
        const cols = try ui.src.lines(a, n, "columns");
        const rows = try ui.src.lines(a, n, "rows");
        var ci = b.ink;
        ci.nowrap = true;
        ci.truncate = true;
        var hi = ci;
        hi.bold = true;
        const sort = std.mem.trim(u8, ui.src.text(n, "sort"), " \n");
        const hdr = try ui.frameBox(n, .table, .header, b, hi, true, 1);
        c.YGNodeStyleSetFlexShrink(hdr.yg, 0);
        c.YGNodeStyleSetPadding(hdr.yg, c.YGEdgeHorizontal, 1);
        for (cols, 0..) |col, j| {
            if (col.fields.len == 0) continue;
            var label = if (col.fields.len > 1) col.fields[1] else col.fields[0];
            var sw = std.mem.tokenizeScalar(u8, sort, ' ');
            if (sw.next()) |sc| if (eq(sc, col.fields[0])) {
                label = try std.fmt.allocPrint(a, "{s} {s}", .{ label, if (eq(sw.next() orelse "asc", "desc")) "↓" else "↑" });
            };
            const cell = try ui.leaf(n, .table, .title, hdr, colInk(hi, col.fields), label);
            cell.index = @intCast(j);
            colWidth(cell, col.fields);
        }
        for (rows, 0..) |r, i| {
            if (r.fields.len == 0) continue;
            const rb = try ui.frameBox(n, .table, .row, b, ci, true, 1);
            rb.index = @intCast(i);
            rb.id = r.fields[0];
            c.YGNodeStyleSetFlexShrink(rb.yg, 0);
            c.YGNodeStyleSetPadding(rb.yg, c.YGEdgeHorizontal, 1);
            for (cols, 0..) |col, j| {
                if (col.fields.len == 0) continue;
                const cell = try ui.leaf(n, .table, .cell, rb, colInk(ci, col.fields), if (j + 1 < r.fields.len) r.fields[j + 1] else "");
                cell.index = @intCast(j);
                colWidth(cell, col.fields);
            }
        }
        if (rows.len == 0 and ui.src.flag(n, "loading", false)) _ = try ui.leaf(n, .text, .frame, b, ui.mutedInk(b.ink), "Loading…");
    }

    /// A list: a row per item, the `row` template stamped with the item's
    /// values when there is one, else its icon and label.
    fn buildList(ui: *Ui, b: *Box) !void {
        const n = b.node;
        const a = ui.arena.allocator();
        const items = try ui.src.lines(a, n, "items");
        const tmpl = ui.childNamed(n, "row");
        var names: std.ArrayList([]const u8) = .empty;
        var fw = std.mem.tokenizeAny(u8, ui.src.text(n, "fields"), " \t\n");
        while (fw.next()) |w| try names.append(a, w);
        const q = std.mem.trim(u8, ui.src.text(n, "query"), " \n");
        var ri = b.ink;
        ri.nowrap = true;
        ri.truncate = true;
        for (items, 0..) |it, i| {
            if (it.fields.len == 0) continue;
            if (eq(it.fields[0], "#")) {
                var hi = ui.mutedInk(b.ink);
                hi.bold = true;
                _ = try ui.leaf(n, .text, .frame, b, hi, try std.mem.join(a, " ", it.fields[1..]));
                continue;
            }
            if (eq(it.fields[0], "-") and it.fields.len == 1) continue;
            const e = entryOf(it.fields) orelse continue;
            if (q.len > 0 and std.ascii.indexOfIgnoreCase(e.label, q) == null) continue;
            const rb = try ui.frameBox(n, .list, .row, b, if (e.disabled) dimmed(ri) else ri, true, 1);
            rb.index = @intCast(i);
            rb.id = e.id;
            c.YGNodeStyleSetFlexShrink(rb.yg, 0);
            c.YGNodeStyleSetPadding(rb.yg, c.YGEdgeHorizontal, 1);
            if (tmpl) |t| {
                var vals: Vals = .empty;
                try vals.put(a, "id", e.id);
                try vals.put(a, "label", e.label);
                for (names.items, 0..) |name, k| {
                    const v = if (k == 0) e.label else if (k - 1 < e.rest.len) e.rest[k - 1] else "";
                    try vals.put(a, name, v);
                }
                if (e.icon) |ic| try vals.put(a, "icon", ic);
                ui.vals = &vals;
                defer ui.vals = null;
                const tb = try ui.build(t, rb, b.ink);
                c.YGNodeStyleSetFlexGrow(tb.yg, 1);
                c.YGNodeStyleSetFlexShrink(tb.yg, 1);
            } else {
                if (e.icon) |ic| _ = try ui.leaf(n, .text, .frame, rb, ri, iconGlyph(ic));
                const lb = try ui.leaf(n, .list, .cell, rb, rb.ink, e.label);
                c.YGNodeStyleSetFlexGrow(lb.yg, 1);
            }
        }
        if (items.len == 0 and ui.src.flag(n, "loading", false)) _ = try ui.leaf(n, .text, .frame, b, ui.mutedInk(b.ink), "Loading…");
    }

    /// A tree's visible rows under `parent`, depth first.
    fn treeRows(ui: *Ui, b: *Box, items: []const core.Core.Line, expanded: []const u8, parent: []const u8, depth: usize) !void {
        const a = ui.arena.allocator();
        for (items, 0..) |it, i| {
            if (it.fields.len < 2 or !eq(it.fields[1], parent)) continue;
            const id = it.fields[0];
            var label: []const u8 = id;
            var icon: ?[]const u8 = null;
            for (it.fields[2..], 0..) |f, k| {
                if (std.mem.startsWith(u8, f, "icon=")) icon = f[5..] else if (k == 0) label = f;
            }
            const kids = hasChildren(items, id);
            const open = kids and hasWord(expanded, id);
            const indent = try a.alloc(u8, depth * 2);
            @memset(indent, ' ');
            const t = try std.fmt.allocPrint(a, "{s}{s} {s}{s}{s}", .{ indent, if (!kids) " " else if (open) "▾" else "▸", if (icon) |ic| iconGlyph(ic) else "", if (icon != null) " " else "", label });
            var ri = b.ink;
            ri.nowrap = true;
            ri.truncate = true;
            const rb = try ui.leaf(b.node, .tree, .row, b, ri, t);
            c.YGNodeStyleSetFlexShrink(rb.yg, 0);
            c.YGNodeStyleSetPadding(rb.yg, c.YGEdgeHorizontal, 1);
            rb.index = @intCast(i);
            rb.id = id;
            if (open and depth < 32) try ui.treeRows(b, items, expanded, id, depth + 1);
        }
    }

    /// The panels of one dock zone: a tab per panel and the active one.
    fn dockZone(ui: *Ui, dock: *Box, parent: *Box, zone: []const u8) !*Box {
        const n = dock.node;
        const ink = dock.ink;
        const z = try ui.frameBox(n, .dock, .frame, parent, ink, false, 0);
        z.st.layout.border = .{ true, true, true, true };
        z.st.look.rounded = true;
        c.YGNodeStyleSetBorder(z.yg, c.YGEdgeAll, 1);
        c.YGNodeStyleSetOverflow(z.yg, c.YGOverflowHidden);
        z.st.layout.overflow = .hidden;
        const hdr = try ui.frameBox(n, .dock, .header, z, ink, true, 0);
        c.YGNodeStyleSetFlexShrink(hdr.yg, 0);
        const active = ui.dockActive(n, zone);
        const zi = zoneIndex(zone);
        for (ui.src.children(n)) |k| {
            if (zoneOf(ui.src, k) != zi) continue;
            var title = ui.src.text(k, "title");
            if (title.len == 0) title = std.fs.path.basenamePosix(ui.src.path(k));
            var ti = ink;
            ti.nowrap = true;
            if (k == active) ti.bold = true else ti = ui.mutedInk(ti);
            _ = try ui.leaf(k, .dock_panel, .zone_tab, hdr, ti, try std.fmt.allocPrint(ui.arena.allocator(), " {s} ", .{title}));
        }
        if (active != 0) {
            const pb = try ui.build(active, z, ink);
            if (pb.st.layout.grow == null) c.YGNodeStyleSetFlexGrow(pb.yg, 1);
            c.YGNodeStyleSetFlexBasis(pb.yg, 0);
        }
        return z;
    }

    fn dockActive(ui: *Ui, n: Node, zone: []const u8) Node {
        var first: Node = 0;
        const zi = zoneIndex(zone);
        for (ui.src.children(n)) |k| {
            if (zoneOf(ui.src, k) != zi) continue;
            if (first == 0) first = k;
            if (ui.state(k).open) return k;
        }
        return first;
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
            .table, .list, .tree => switch (b.part) {
                .header => g.fill(b.rect, b.clip, ui.tok("muted", 0xf5f5f5ff)),
                .row => {
                    ui.drawRow(g, b);
                    if (b.text.len > 0) ui.drawText(g, b, b.text, pen);
                },
                else => if (b.text.len > 0) ui.drawText(g, b, b.text, pen),
            },
            .sidebar_item => if (b.part == .row) {
                if (src.flag(n, "active", false))
                    g.fill(b.rect, b.clip, ui.tok("sidebar-accent", ui.tok("accent", 0xf5f5f5ff)))
                else if (ui.under(b))
                    g.fill(b.rect, b.clip, ui.tok("accent", 0xf5f5f5ff));
            },
            .dock => if (b.part == .header) g.fill(b.rect, b.clip, ui.tok("muted", 0xf5f5f5ff)),
            .dock_panel => if (b.part == .zone_tab) {
                if (b.ink.bold) pen.bg = ui.tok("background", 0xffffffff);
                ui.drawText(g, b, b.text, pen);
            },
            .message_list => if (b.part == .row) {
                g.fill(b.rect, b.clip, if (eq(b.id, "user")) ui.tok("secondary", 0xf5f5f5ff) else ui.tok("muted", 0xf5f5f5ff));
            },
            .alert_dialog => switch (b.part) {
                .confirm => {
                    const danger = eq(std.mem.trim(u8, src.text(n, "variant"), " \n"), "danger");
                    pen.bg = if (danger) ui.tok("button-danger", ui.tok("danger", 0xef4444ff)) else ui.tok("button-primary", ui.tok("primary", 0x171717ff));
                    pen.fg = if (danger) ui.tok("button-danger-foreground", 0xfafafaff) else ui.tok("button-primary-foreground", ui.tok("primary-foreground", 0xfafafaff));
                    if (ui.under(b)) pen.attrs.bold = true;
                    ui.drawText(g, b, b.text, pen);
                },
                .cancel => {
                    pen.bg = ui.tok("secondary", 0xe5e5e5ff);
                    if (ui.under(b)) pen.attrs.bold = true;
                    ui.drawText(g, b, b.text, pen);
                },
                else => if (b.part != .none) ui.drawText(g, b, b.text, pen),
            },
            .breadcrumb => if (b.part == .crumb) {
                if (ui.under(b)) pen.attrs.underline = true;
                ui.drawText(g, b, b.text, pen);
            },
            .toggle => ui.drawToggle(g, b),
            .dropdown_button => if (b.part == .none) ui.drawButton(g, b),
            .avatar => {
                g.fill(b.rect, b.clip, ui.tok("secondary", ui.tok("muted", 0xf5f5f5ff)));
                pen.attrs.bold = true;
                ui.drawText(g, b, b.text, pen);
            },
            .markdown => ui.drawText(g, b, b.text, pen),
            .tag => {
                const v = b.st.look.variant orelse "";
                pen.bg = if (eq(v, "") or eq(v, "secondary") or eq(v, "outline")) ui.tok("secondary", 0xe5e5e5ff) else ui.variantColor(n, b.st.look, ui.tok("primary", 0x171717ff));
                if (!(eq(v, "") or eq(v, "secondary") or eq(v, "outline"))) pen.fg = ui.tok("primary-foreground", 0xfafafaff);
                ui.drawText(g, b, b.text, pen);
            },
            .editor => ui.drawTextarea(g, b),
            .canvas => ui.drawCanvas(g, b),
            .terminal => ui.drawTerminal(g, b),
            .chart => ui.drawChart(g, b),
            .accordion_item => if (b.part == .trigger) {
                if (ui.under(b)) pen.attrs.underline = true;
                ui.drawText(g, b, b.text, pen);
            },
            else => if (b.part != .none and b.text.len > 0) ui.drawText(g, b, b.text, pen),
        }
    }

    /// Whether the pointer is over the box now (rows of one node).
    fn under(ui: *Ui, b: *const Box) bool {
        const m = ui.mouse orelse return false;
        return b.rect.intersect(b.clip).contains(m.x, m.y);
    }

    /// A data view row: selected, striped or under the pointer.
    fn drawRow(ui: *Ui, g: *Grid, b: *Box) void {
        const n = b.node;
        const v = ui.src.text(n, "value");
        var sel = false;
        if (b.kind == .table) {
            var it = std.mem.tokenizeAny(u8, v, " \n");
            if (it.next()) |r| sel = eq(r, b.id);
        } else sel = hasWord(v, b.id);
        if (sel) {
            g.fill(b.rect, b.clip, ui.tok("list-active", ui.tok("accent", 0xf5f5f5ff)));
            if (ui.focused == n) g.put(b.rect.x, b.rect.y, b.clip, "›", .{ .fg = ui.tok("primary", b.ink.fg), .attrs = .{ .bold = true } });
        } else if (ui.under(b)) {
            g.fill(b.rect, b.clip, ui.tok("list-hover", ui.tok("accent", 0xf5f5f5ff)));
        } else if (b.kind == .table and b.index % 2 == 1 and ui.src.flag(n, "stripe", false)) {
            g.fill(b.rect, b.clip, ui.tok("table-even", ui.tok("muted", 0xf5f5f5ff)));
        }
    }

    fn drawToggle(ui: *Ui, g: *Grid, b: *Box) void {
        if (b.part != .none) return;
        const on = ui.src.flag(b.node, "value", false);
        if (b.st.look.bg == null) {
            if (on) g.fill(b.rect, b.clip, ui.tok("accent", 0xf5f5f5ff)) else if (ui.under(b)) g.fill(b.rect, b.clip, ui.tok("muted", 0xf5f5f5ff));
        }
        for (b.kids.items) |k| if (k.node == b.node) {
            k.ink.bold = on;
            if (!on) k.ink.fg = ui.tok("muted-foreground", k.ink.fg);
            if (ui.src.flag(b.node, "disabled", false)) k.ink.dim = true;
        };
        if (ui.focused == b.node) g.put(b.rect.x, b.rect.y + @divTrunc(b.rect.h, 2), b.clip, "›", .{ .fg = b.ink.fg, .attrs = .{ .bold = true } });
    }

    /// A canvas or chart color: a theme token, `#rgb`, `#rrggbb`,
    /// `#rrggbbaa` or a few names; null for `none`.
    fn colorOf(ui: *Ui, s0: []const u8, opacity: f32) ?u32 {
        const s = std.mem.trim(u8, s0, " ");
        var v: u32 = 0;
        if (s.len > 0 and s[0] == '#') {
            const h = s[1..];
            const x = std.fmt.parseInt(u32, h, 16) catch return null;
            v = switch (h.len) {
                3 => (((x >> 8) & 0xf) * 0x11) << 24 | (((x >> 4) & 0xf) * 0x11) << 16 | ((x & 0xf) * 0x11) << 8 | 0xff,
                6 => x << 8 | 0xff,
                8 => x,
                else => return null,
            };
        } else if (ui.src.token(s)) |t| {
            v = t;
        } else {
            const names = std.StaticStringMap(u32).initComptime(.{
                .{ "white", 0xffffffff }, .{ "black", 0x000000ff },  .{ "red", 0xef4444ff },
                .{ "green", 0x22c55eff }, .{ "blue", 0x3b82f6ff },   .{ "yellow", 0xeab308ff },
                .{ "orange", 0xf97316ff }, .{ "purple", 0xa855f7ff }, .{ "gray", 0x737373ff },
                .{ "grey", 0x737373ff },
            });
            v = names.get(s) orelse return null;
        }
        if (opacity < 1) {
            const a: f32 = @floatFromInt(v & 0xff);
            v = (v & 0xffffff00) | @as(u32, @intFromFloat(std.math.clamp(a * opacity, 0, 255)));
        }
        if (v & 0xff == 0) return null;
        return v;
    }

    /// Two pixels a cell: the top in the glyph `▀`, the bottom behind it.
    fn blit(g: *Grid, pm: *const raster.Pixmap, x0: i32, y0: i32, clip: Rect) void {
        var cy: usize = 0;
        while (cy * 2 < pm.h) : (cy += 1) {
            var cx: usize = 0;
            while (cx < pm.w) : (cx += 1) {
                const x = x0 + @as(i32, @intCast(cx));
                const y = y0 + @as(i32, @intCast(cy));
                if (!clip.contains(x, y)) continue;
                const top = pm.get(cx, cy * 2);
                const bot = if (cy * 2 + 1 < pm.h) pm.get(cx, cy * 2 + 1) else 0;
                if (top == 0 and bot == 0) continue;
                const cell = g.at(x, y) orelse continue;
                const t = if (top != 0) top >> 8 else cell.bg;
                const bo = if (bot != 0) bot >> 8 else cell.bg;
                cell.attrs = .{};
                cell.link = "";
                if (t == bo) {
                    cell.ch = " ";
                    cell.bg = t;
                } else {
                    cell.ch = "▀";
                    cell.fg = t;
                    cell.bg = bo;
                }
            }
        }
    }

    fn canvasOps(ui: *Ui, n: Node) []const core.Core.Line {
        return ui.src.lines(ui.arena.allocator(), n, "ops") catch &.{};
    }

    fn drawCanvas(ui: *Ui, g: *Grid, b: *Box) void {
        const a = ui.arena.allocator();
        const r = b.rect;
        if (r.w <= 0 or r.h <= 0) return;
        var pm = raster.Pixmap.init(a, @intCast(r.w), @intCast(r.h * 2)) catch return;
        const hov = ui.state(b.node).hl;
        const fg = ui.tok("foreground", 0x0a0a0aff);
        var texts: std.ArrayList(raster.Op) = .empty;
        for (ui.canvasOps(b.node), 0..) |ln, i| {
            const o = raster.parseOp(ln.fields) orelse continue;
            const h = hov == i + 1;
            const op = if (o.attr("opacity", h)) |v| raster.num(v) else 1;
            const fill = if (o.attr("fill", h)) |v| ui.colorOf(v, op) else null;
            const stroke = if (o.attr("stroke", h) orelse o.attr("border", h)) |v| ui.colorOf(v, op) else null;
            const gm = o.geom;
            switch (o.kind) {
                .rect => {
                    if (fill) |cl| pm.rect(gm[0], gm[1], gm[2], gm[3], cl);
                    if (stroke) |cl| pm.frame(gm[0], gm[1], gm[2], gm[3], cl);
                },
                .circle => {
                    if (fill) |cl| pm.disc(gm[0], gm[1], gm[2], cl);
                    if (stroke) |cl| pm.ring(gm[0], gm[1], gm[2], cl);
                },
                .line => pm.line(gm[0], gm[1], gm[2], gm[3], stroke orelse fill orelse fg),
                .path => {
                    const ls = raster.polylines(a, o.words) catch continue;
                    for (ls) |l| {
                        if (fill) |cl| if (l.len > 2) pm.polygon(l, cl);
                        if (stroke orelse (if (fill == null) fg else null)) |cl| for (1..l.len) |k| {
                            pm.line(l[k - 1][0], l[k - 1][1], l[k][0], l[k][1], cl);
                        };
                    }
                },
                .text => texts.append(a, o) catch {},
                .image => pm.frame(gm[0], gm[1], gm[2], gm[3], ui.tok("border", 0xe5e5e5ff)),
                .other => {},
            }
        }
        const clip = b.clip.intersect(r);
        blit(g, &pm, r.x, r.y, clip);
        for (texts.items) |o| {
            const tx = r.x + @as(i32, @intFromFloat(style.cells(o.geom[0], .x)));
            const ty = r.y + @as(i32, @intFromFloat(@floor(o.geom[1] / style.cell_h)));
            const col = if (o.attr("color", false) orelse o.attr("fill", false)) |v| ui.colorOf(v, 1) orelse fg else fg;
            const w = o.attr("weight", false) orelse "";
            _ = g.print(tx, ty, clip, o.text, .{ .fg = col, .attrs = .{ .bold = eq(w, "bold") or eq(w, "semibold") } });
        }
    }

    /// The terminal's grid in cells: what its box holds inside border and
    /// padding.
    fn termGrid(b: *const Box) Rect {
        return innerRect(b);
    }

    /// A terminal node (components.md § terminal): the core's cells copied
    /// into the box, colors and attributes from its style table, and its
    /// cursor. The grid is whatever fits inside the box, which the core
    /// hears about with uit_term_resize when it changes.
    fn drawTerminal(ui: *Ui, g: *Grid, b: *Box) void {
        const n = b.node;
        const r = termGrid(b);
        if (r.w <= 0 or r.h <= 0) return;
        const cols: u32 = @intCast(r.w);
        const rows: u32 = @intCast(r.h);
        const st = ui.state(n);
        const want: [4]u32 = .{ cols, rows, ui.cell_px[0], ui.cell_px[1] };
        if (!std.mem.eql(u32, &st.term, &want)) {
            st.term = want;
            ui.src.termResize(n, cols, rows, want[2], want[3]);
        }

        const clip = b.clip.intersect(r);
        const styles = ui.src.termStyles(n);
        const sel = ui.tok("selection", 0x55a0fc4d);
        for (ui.src.termRows(n, 0, rows)) |row| {
            if (row.y >= rows) continue;
            const y = r.y + @as(i32, @intCast(row.y));
            const runs: []const core.TermRun = if (row.runs == null or row.n_runs == 0) &.{} else row.runs[0..row.n_runs];
            for (runs) |run| {
                if (run.col >= cols) continue;
                const x = r.x + @as(i32, @intCast(run.col));
                const span: Rect = .{ .x = x, .y = y, .w = @intCast(run.width), .h = 1 };
                const ts: core.TermStyle = if (run.style < styles.len) styles[run.style] else std.mem.zeroes(core.TermStyle);
                const pen = termPen(ts, b.ink.fg, g, x, y);
                if (pen.bg) |bg| g.fill(span, clip, bg);
                if (ts.flags & c.UIT_TERM_INVISIBLE == 0) {
                    var p = pen;
                    p.bg = null;
                    _ = g.print(x, y, clip, core.slice(run.text), p);
                }
                if (run.selected != 0) g.fill(span, clip, sel);
            }
        }

        const cur = ui.src.termCursor(n) orelse return;
        if (cur.visible == 0 or cur.x >= cols or cur.y >= rows) return;
        const cx = r.x + @as(i32, @intCast(cur.x));
        const cy = r.y + @as(i32, @intCast(cur.y));
        if (!clip.contains(cx, cy)) return;
        if (ui.focused == n) {
            g.cursor = .{
                .x = @intCast(cx),
                .y = @intCast(cy),
                .shape = switch (cur.shape) {
                    c.UIT_TERM_CURSOR_BAR => .bar,
                    c.UIT_TERM_CURSOR_UNDERLINE => .underline,
                    else => .block,
                },
                .blink = cur.blink != 0,
            };
        } else if (g.at(cx, cy)) |cell| {
            // Without focus the terminal has no hardware cursor: show
            // where it is as a reversed cell, as a hollow block would.
            cell.attrs.reverse = !cell.attrs.reverse;
        }
    }

    fn drawChart(ui: *Ui, g: *Grid, b: *Box) void {
        const a = ui.arena.allocator();
        const n = b.node;
        const r = innerRect(b);
        if (r.w < 4 or r.h < 3) return;
        var yw = std.mem.tokenizeAny(u8, ui.src.text(n, "y"), " \t\n");
        const pts = chartPoints(a, ui.src.text(n, "data"), std.mem.trim(u8, ui.src.text(n, "x"), " \n"), yw.next() orelse "") catch return;
        if (pts.len == 0) return;
        const kind = std.mem.trim(u8, ui.src.text(n, "kind"), " \n");
        const plot_h = r.h - 1;
        var pm = raster.Pixmap.init(a, @intCast(r.w), @intCast(plot_h * 2)) catch return;
        const W: f32 = @floatFromInt(r.w * 8);
        const H: f32 = @floatFromInt(plot_h * 16);
        var hi: f64 = 0;
        var lo: f64 = 0;
        var sum: f64 = 0;
        for (pts) |p| {
            hi = @max(hi, p.y);
            lo = @min(lo, p.y);
            sum += @max(0, p.y);
        }
        if (hi == lo) hi = lo + 1;
        var pal: [5]u32 = undefined;
        for (&pal, 0..) |*p, i| {
            var nb: [16]u8 = undefined;
            p.* = ui.tok(std.fmt.bufPrint(&nb, "chart-{d}", .{i + 1}) catch "chart-1", ui.tok("primary", 0x3b82f6ff));
        }
        const band = W / @as(f32, @floatFromInt(pts.len));
        const yOf = struct {
            fn f(v: f64, l: f64, h: f64, hh: f32) f32 {
                return hh - @as(f32, @floatCast((v - l) / (h - l))) * (hh - 4);
            }
        }.f;
        if (eq(kind, "pie")) {
            const cx = W / 2;
            const cy = H / 2;
            const rad = @min(W, H) / 2 - 2;
            var py: usize = 0;
            while (py < pm.h) : (py += 1) {
                var px: usize = 0;
                while (px < pm.w) : (px += 1) {
                    const dx = (@as(f32, @floatFromInt(px)) + 0.5) * raster.px_w - cx;
                    const dy = (@as(f32, @floatFromInt(py)) + 0.5) * raster.px_h - cy;
                    if (dx * dx + dy * dy > rad * rad or sum <= 0) continue;
                    var ang = std.math.atan2(dx, -dy);
                    if (ang < 0) ang += std.math.tau;
                    const frac = ang / std.math.tau;
                    var acc: f64 = 0;
                    for (pts, 0..) |p, i| {
                        acc += @max(0, p.y) / sum;
                        if (frac <= acc) {
                            pm.plot(@intCast(px), @intCast(py), pal[i % pal.len]);
                            break;
                        }
                    }
                }
            }
        } else if (eq(kind, "bar")) {
            for (pts, 0..) |p, i| {
                const x = @as(f32, @floatFromInt(i)) * band + band * 0.2;
                const top = yOf(@max(p.y, 0), lo, hi, H);
                const base = yOf(0, lo, hi, H);
                pm.rect(x, @min(top, base), @max(band * 0.6, 8), @abs(base - top), pal[0]);
            }
        } else {
            var poly: std.ArrayList([2]f32) = .empty;
            for (pts, 0..) |p, i| poly.append(a, .{ @as(f32, @floatFromInt(i)) * band + band / 2, yOf(p.y, lo, hi, H) }) catch return;
            if (eq(kind, "area") and poly.items.len > 1) {
                var area: std.ArrayList([2]f32) = .empty;
                area.appendSlice(a, poly.items) catch return;
                area.append(a, .{ poly.items[poly.items.len - 1][0], H }) catch return;
                area.append(a, .{ poly.items[0][0], H }) catch return;
                pm.polygon(area.items, (pal[0] & 0xffffff00) | 0x60);
            }
            for (1..poly.items.len) |i| pm.line(poly.items[i - 1][0], poly.items[i - 1][1], poly.items[i][0], poly.items[i][1], pal[0]);
            if (poly.items.len == 1) pm.disc(poly.items[0][0], poly.items[0][1], 4, pal[0]);
        }
        const clip = b.clip.intersect(b.rect);
        blit(g, &pm, r.x, r.y, clip);
        // The x labels under the plot, as many as fit.
        const mp: Pen = .{ .fg = ui.tok("muted-foreground", 0x737373ff) };
        const bw = band / 8;
        var every: usize = 1;
        var widest: f32 = 1;
        for (pts) |p| widest = @max(widest, @as(f32, @floatFromInt(gridmod.width(p.x))) + 1);
        while (bw * @as(f32, @floatFromInt(every)) < widest and every < pts.len) every += 1;
        if (eq(kind, "pie")) {
            var x = r.x;
            for (pts, 0..) |p, i| {
                x = g.print(x, r.y + plot_h, clip, "■", .{ .fg = pal[i % pal.len] });
                x = g.print(x + 1, r.y + plot_h, clip, p.x, mp) + 2;
            }
            return;
        }
        for (pts, 0..) |p, i| {
            if (i % every != 0) continue;
            const cx = r.x + @as(i32, @intFromFloat((@as(f32, @floatFromInt(i)) + 0.5) * bw));
            const lw: i32 = gridmod.width(p.x);
            _ = g.print(cx - @divTrunc(lw, 2), r.y + plot_h, clip, p.x, mp);
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
        var col = ui.buttonColors(b);
        if (b.parent) |p| if (p.kind == .button_group and p.part == .none and hasWord(ui.src.text(p.node, "value"), std.fs.path.basenamePosix(ui.src.path(b.node)))) {
            col = .{ .bg = ui.tok("button-primary", ui.tok("primary", 0x171717ff)), .fg = ui.tok("button-primary-foreground", ui.tok("primary-foreground", 0xfafafaff)) };
        };
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
            switch (bb.part) {
                .confirm, .cancel, .zone_tab, .trigger, .crumb => return bb,
                .row => if (bb.kind != .message_list) return bb,
                .title => if (bb.kind == .table) return bb,
                else => {},
            }
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
        /// 2 or 3 for a double or triple press (a terminal selects a word
        /// or a line).
        clicks: u8 = 1,
    };

    /// Returns true if the frame should be redrawn.
    pub fn onMouse(ui: *Ui, m: Mouse) bool {
        ui.mouse = .{ .x = m.x, .y = m.y };
        var redraw = ui.setHover(m.x, m.y);
        if (ui.termMouseEvent(m)) |r| return r or redraw;
        switch (m.kind) {
            .motion, .drag => {
                if (ui.canvas_pressed != 0) {
                    if (ui.boxOf(ui.canvas_pressed)) |cb| ui.canvasEvent(cb, "drag", m.x, m.y, false);
                } else if (ui.hitAt(m.x, m.y)) |hb| if (hb.kind == .canvas and hb.part == .none) {
                    ui.canvasEvent(hb, "move", m.x, m.y, false);
                };
                if (ui.canvasHover(m.x, m.y)) redraw = true;
                // Rows and parts light up under the pointer.
                if (ui.mouse_row != ui.rowAt(m.x, m.y)) {
                    ui.mouse_row = ui.rowAt(m.x, m.y);
                    redraw = true;
                }
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
                        if (bb.kind == .message_list) s.open = s.scroll_y < bb.content_h - bb.rect.h;
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
                if (hit.kind == .canvas and hit.part == .none) {
                    if (ui.focused != 0) ui.blur();
                    ui.canvas_pressed = hit.node;
                    ui.canvasEvent(hit, "mouse-down", m.x, m.y, true);
                    return true;
                }
                const t = ui.clickTarget(hit) orelse {
                    if (ui.focused != 0) {
                        ui.blur();
                        redraw = true;
                    }
                    return redraw;
                };
                ui.pressed = t.node;
                ui.pressed_box = .{ .node = t.node, .part = t.part, .index = t.index };
                if (t.kind.focusable() and (t.part == .none or t.part == .row)) ui.focus(t.node);
                if (t.kind == .slider) ui.sliderTo(t, m.x, false);
                if (t.kind.editable()) ui.caretTo(t, m.x, m.y);
                redraw = true;
            },
            .release => {
                if (ui.canvas_pressed != 0) {
                    const cn = ui.canvas_pressed;
                    ui.canvas_pressed = 0;
                    if (ui.boxOf(cn)) |cb| {
                        ui.canvasEvent(cb, "mouse-up", m.x, m.y, true);
                        if (cb.rect.intersect(cb.clip).contains(m.x, m.y)) ui.canvasEvent(cb, "click", m.x, m.y, true);
                    }
                    return true;
                }
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

    /// The mouse over a terminal node, or dragging from one, goes to the
    /// core (uit_term_mouse, uit_term_scroll): it reports it to the program
    /// under a mouse mode, and selects or scrolls history otherwise.
    /// Null when no terminal is involved, else whether to redraw.
    fn termMouseEvent(ui: *Ui, m: Mouse) ?bool {
        if (ui.term_pressed != 0) {
            const tb = ui.boxOf(ui.term_pressed) orelse {
                ui.term_pressed = 0;
                return null;
            };
            switch (m.kind) {
                .drag, .motion => ui.termMouse(tb, c.UIT_TERM_MOVE, c.UIT_TERM_BUTTON_LEFT, m.x, m.y, m.clicks),
                .release => {
                    ui.termMouse(tb, c.UIT_TERM_RELEASE, c.UIT_TERM_BUTTON_LEFT, m.x, m.y, m.clicks);
                    ui.term_pressed = 0;
                },
                else => return null,
            }
            return false;
        }
        if (ui.popup != null) return null;
        const hit = ui.hitAt(m.x, m.y) orelse return null;
        if (hit.kind != .terminal or hit.part != .none) return null;
        if (!termGrid(hit).contains(m.x, m.y) and m.kind != .wheel_up and m.kind != .wheel_down) return null;
        switch (m.kind) {
            .press => {
                if (ui.tip.node != 0) {
                    ui.tip.shown = false;
                    ui.tip.suppressed = true;
                }
                ui.focus(hit.node);
                ui.term_pressed = hit.node;
                ui.termMouse(hit, c.UIT_TERM_PRESS, c.UIT_TERM_BUTTON_LEFT, m.x, m.y, m.clicks);
            },
            .motion => {
                ui.termMouse(hit, c.UIT_TERM_MOVE, c.UIT_TERM_BUTTON_NONE, m.x, m.y, 1);
                return false;
            },
            .wheel_up => ui.src.termScroll(hit.node, -3),
            .wheel_down => ui.src.termScroll(hit.node, 3),
            .release, .drag => return null,
        }
        return true;
    }

    fn boxOf(ui: *Ui, n: Node) ?*Box {
        for (ui.hits.items) |h| if (h.box.node == n and h.box.part == .none) return h.box;
        return null;
    }

    fn rowAt(ui: *Ui, x: i32, y: i32) ?*Box {
        var b = ui.hitAt(x, y);
        while (b) |bb| : (b = bb.parent) switch (bb.part) {
            .row, .confirm, .cancel, .crumb, .trigger => return bb,
            else => if (bb.kind == .toggle and bb.part == .none) return bb,
        };
        return null;
    }

    /// The canvas op under the pointer, for `hover:` attributes.
    fn canvasHover(ui: *Ui, x: i32, y: i32) bool {
        var changed = false;
        for (ui.hits.items) |h| {
            const cb = h.box;
            if (cb.kind != .canvas or cb.part != .none) continue;
            const st = ui.state(cb.node);
            const now: usize = if (cb.rect.intersect(cb.clip).contains(x, y)) ui.canvasHit(cb, x, y) else 0;
            if (now != st.hl) {
                st.hl = now;
                changed = true;
            }
        }
        return changed;
    }

    fn canvasPoint(cb: *const Box, x: i32, y: i32) [2]f32 {
        return .{ @floatFromInt((x - cb.rect.x) * 8 + 4), @floatFromInt((y - cb.rect.y) * 16 + 8) };
    }

    /// 1 + the index of the topmost op under the cell, or 0.
    fn canvasHit(ui: *Ui, cb: *const Box, x: i32, y: i32) usize {
        const a = ui.arena.allocator();
        const q = canvasPoint(cb, x, y);
        const ops = ui.canvasOps(cb.node);
        var i = ops.len;
        while (i > 0) {
            i -= 1;
            const o = raster.parseOp(ops[i].fields) orelse continue;
            if (raster.hits(a, o, q)) return i + 1;
        }
        return 0;
    }

    /// A pointer event the canvas's `on` asks for: `item=` (the topmost op
    /// under the pointer), canvas-local `x=` `y=` in points, `button=`.
    fn canvasEvent(ui: *Ui, cb: *Box, name: []const u8, x: i32, y: i32, button: bool) void {
        if (!hasWord(ui.src.text(cb.node, "on"), name)) return;
        const q = canvasPoint(cb, x, y);
        var xb: [16]u8 = undefined;
        var yb: [16]u8 = undefined;
        var attrs: [4]core.Attr = undefined;
        var k: usize = 0;
        const hit = ui.canvasHit(cb, x, y);
        if (hit > 0) {
            const ops = ui.canvasOps(cb.node);
            if (hit - 1 < ops.len and ops[hit - 1].fields.len > 1) {
                attrs[k] = .{ "item", ops[hit - 1].fields[1] };
                k += 1;
            }
        }
        attrs[k] = .{ "x", std.fmt.bufPrint(&xb, "{d}", .{@max(0, q[0])}) catch "0" };
        attrs[k + 1] = .{ "y", std.fmt.bufPrint(&yb, "{d}", .{@max(0, q[1])}) catch "0" };
        k += 2;
        if (button) {
            attrs[k] = .{ "button", "left" };
            k += 1;
        }
        ui.src.emit(cb.node, name, attrs[0..k]);
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
            .button => if (t.parent != null and t.parent.?.kind == .button_group and t.parent.?.part == .none) {
                ui.groupPick(t.parent.?.node, n);
            } else {
                var buf: [2][16]u8 = undefined;
                const attrs = ui.clickAttrs(t, x, y, &buf);
                src.emit(n, "click", &attrs);
            },
            .table => switch (t.part) {
                .row => if (!eq(std.mem.trim(u8, src.text(n, "selectable"), " \n"), "off")) {
                    var it = std.mem.tokenizeAny(u8, src.text(n, "value"), " \n");
                    if (!eq(it.next() orelse "", t.id)) {
                        src.emit(n, "select", &.{.{ "row", t.id }});
                        src.mirror(n, "value", t.id);
                    }
                },
                .title => if (src.flag(n, "sortable", false)) {
                    const cols = src.lines(ui.arena.allocator(), n, "columns") catch return;
                    if (t.index >= cols.len or cols[t.index].fields.len == 0) return;
                    const col = cols[t.index].fields[0];
                    var it = std.mem.tokenizeAny(u8, src.text(n, "sort"), " \n");
                    const cur = it.next() orelse "";
                    const dir: []const u8 = if (eq(cur, col) and eq(it.next() orelse "asc", "asc")) "desc" else "asc";
                    src.emit(n, "sort", &.{ .{ "col", col }, .{ "dir", dir } });
                    const v = std.fmt.allocPrint(ui.arena.allocator(), "{s} {s}", .{ col, dir }) catch return;
                    src.mirror(n, "sort", v);
                },
                else => {},
            },
            .list => if (t.part == .row and src.flag(n, "selectable", false)) ui.pickIn(n, t.id, src.flag(n, "multiple", false)),
            .tree => if (t.part == .row) {
                const items = src.lines(ui.arena.allocator(), n, "items") catch return;
                if (hasChildren(items, t.id)) {
                    const exp = src.text(n, "expanded");
                    const on = !hasWord(exp, t.id);
                    var out: std.ArrayList(u8) = .empty;
                    const a = ui.arena.allocator();
                    var it = std.mem.tokenizeAny(u8, exp, " \t\n");
                    while (it.next()) |w| if (!eq(w, t.id)) {
                        if (out.items.len > 0) out.append(a, ' ') catch {};
                        out.appendSlice(a, w) catch {};
                    };
                    if (on) {
                        if (out.items.len > 0) out.append(a, ' ') catch {};
                        out.appendSlice(a, t.id) catch {};
                    }
                    src.mirror(n, "expanded", out.items);
                    src.emit(n, "expand", &.{ .{ "id", t.id }, .{ "value", if (on) "on" else "off" } });
                }
                if (src.flag(n, "selectable", false)) ui.pickIn(n, t.id, src.flag(n, "multiple", false));
            },
            .sidebar_item => if (t.part == .row) src.emit(n, "click", &.{}),
            .alert_dialog => switch (t.part) {
                .confirm => src.emit(n, "confirm", &.{}),
                .cancel => src.emit(n, "cancel", &.{}),
                else => {},
            },
            .dock_panel => if (t.part == .zone_tab) {
                const dock = t.parent.?.parent.?.node;
                const zi = zoneOf(src, n);
                for (src.children(dock)) |k| if (zoneOf(src, k) == zi) {
                    ui.state(k).open = k == n;
                };
                src.emit(n, "activate", &.{});
            },
            .collapsible => if (t.part == .trigger) {
                const v: []const u8 = if (src.flag(n, "open", false)) "off" else "on";
                src.mirror(n, "open", v);
                src.emit(n, "change", &.{.{ "value", v }});
            },
            .accordion_item => if (t.part == .trigger) {
                const acc = (t.parent orelse return).parent orelse return;
                if (src.flag(n, "disabled", false)) return;
                const name = std.fs.path.basenamePosix(src.path(n));
                const a = ui.arena.allocator();
                const cur = src.text(acc.node, "value");
                const open = hasWord(cur, name);
                var out: std.ArrayList(u8) = .empty;
                if (src.flag(acc.node, "multiple", false)) {
                    var it = std.mem.tokenizeAny(u8, cur, " \t\n");
                    while (it.next()) |w| if (!eq(w, name)) {
                        if (out.items.len > 0) out.append(a, ' ') catch {};
                        out.appendSlice(a, w) catch {};
                    };
                }
                if (!open) {
                    if (out.items.len > 0) out.append(a, ' ') catch {};
                    out.appendSlice(a, name) catch {};
                }
                ui.userChange(acc.node, out.items);
            },
            .breadcrumb => if (t.part == .crumb) src.emit(n, "click", &.{.{ "id", t.id }}),
            .toggle => ui.userChange(n, if (src.flag(n, "value", false)) "off" else "on"),
            .dropdown_button, .editor, .canvas, .chart => {},
            .link => {
                var buf: [2][16]u8 = undefined;
                const attrs = ui.clickAttrs(t, x, y, &buf);
                src.emit(n, "click", &attrs);
                if (t.kind == .link) if (ui.open_url) |open| {
                    const href = std.mem.trim(u8, src.text(n, "href"), " \n");
                    if (href.len > 0) open(href);
                };
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
            // A press on a text field puts the caret there (onMouse); it
            // isn't a click, as on GPUI, so a tag the field inherits (a
            // form's) doesn't fire as if its button were pressed.
            .input, .textarea => {},
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

    /// A click on a button in a button group: its name becomes the value
    /// (toggled in and out of it with `multiple`).
    fn groupPick(ui: *Ui, group: Node, btn: Node) void {
        const name = std.fs.path.basenamePosix(ui.src.path(btn));
        if (!ui.src.flag(group, "multiple", false)) {
            if (!eq(std.mem.trim(u8, ui.src.text(group, "value"), " \n"), name)) ui.userChange(group, name);
            return;
        }
        ui.userChange(group, toggled(ui.arena.allocator(), ui.src.text(group, "value"), name) catch return);
    }

    /// A list or tree selection: id alone, or toggled with `multiple`.
    fn pickIn(ui: *Ui, n: Node, id: []const u8, multiple: bool) void {
        const v = if (multiple) toggled(ui.arena.allocator(), ui.src.text(n, "value"), id) catch return else id;
        if (eq(std.mem.trim(u8, ui.src.text(n, "value"), " \n"), v)) return;
        ui.src.mirror(n, "value", v);
        ui.src.emit(n, "select", &.{.{ "value", v }});
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
        // A focused terminal's program gets Ctrl-C (and Tab and Escape);
        // Ctrl-Q still closes the window.
        const term = ui.focused != 0 and Kind.of(ui.src.typeOf(ui.focused)) == .terminal;
        if (k.ctrl and (eq(k.name, "q") or (eq(k.name, "c") and !term))) return .quit;
        if (term and ui.popup == null) {
            ui.termKey(ui.focused, k);
            return .handled;
        }

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
        // Escape asks the top overlay to close; Enter confirms an alert.
        const ovs = ui.src.overlays(ui.win);
        if (ovs.len > 0 and plain) {
            const ov = ovs[ovs.len - 1];
            switch (Kind.of(ui.src.typeOf(ov))) {
                .sheet, .dialog => if (eq(k.name, "escape")) {
                    ui.src.emit(ov, "close", &.{});
                    return .handled;
                },
                .alert_dialog => if (eq(k.name, "escape")) {
                    ui.src.emit(ov, "cancel", &.{});
                    return .handled;
                } else if (eq(k.name, "enter") and n == 0) {
                    ui.src.emit(ov, "confirm", &.{});
                    return .handled;
                },
                else => {},
            }
        }
        if (eq(k.name, "escape") and n != 0) {
            ui.blur();
            return .handled;
        }
        var buf: [64]u8 = undefined;
        if (ui.src.key(ui.win, keystroke(k, &buf), n)) return .handled;
        return .unhandled;
    }

    /// A key for a focused terminal: through uit_key, which tries the
    /// app's bindings and then encodes it for the program. Text of more
    /// than one character (an IME commit) is sent as text.
    fn termKey(ui: *Ui, n: Node, k: Key) void {
        if (k.text.len > 0 and !k.ctrl and !k.alt and !k.super) {
            const one = std.unicode.utf8ByteSequenceLength(k.text[0]) catch 0;
            if (one != k.text.len) {
                ui.src.termText(n, k.text);
                return;
            }
        }
        var buf: [64]u8 = undefined;
        const ks = keystroke(k, &buf);
        if (ks.len == 0) return;
        _ = ui.src.key(ui.win, ks, n);
    }

    /// The terminal cell under (x, y), clamped to the grid, for a press,
    /// drag or release.
    fn termCell(b: *const Box, x: i32, y: i32) [2]u32 {
        const r = termGrid(b);
        return .{
            @intCast(std.math.clamp(x - r.x, 0, @max(0, r.w - 1))),
            @intCast(std.math.clamp(y - r.y, 0, @max(0, r.h - 1))),
        };
    }

    fn termMouse(ui: *Ui, b: *const Box, action: u32, button: u32, x: i32, y: i32, clicks: u8) void {
        const cell = termCell(b, x, y);
        _ = ui.src.termMouse(b.node, .{ .action = action, .button = button, .col = cell[0], .row = cell[1], .mods = 0, .clicks = clicks });
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
            .input, .textarea, .editor => return ui.editKey(n, kind, k),
            else => {},
        }
        return false;
    }

    fn editKey(ui: *Ui, n: Node, kind: Kind, k: Key) bool {
        if (ui.src.flag(n, "readonly", false) and (k.text.len > 0 or (eq(k.name, "enter") and kind.multiline()) or eq(k.name, "backspace") or eq(k.name, "delete"))) return true;
        const e = ui.edit(n);
        var changed = false;
        if (eq(k.name, "enter")) {
            if (kind.multiline() and !k.shift) {
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
            e.caret = if (kind.multiline()) lineStart(e.buf.items, e.caret) else 0;
        } else if (eq(k.name, "end")) {
            e.caret = if (kind.multiline()) lineEnd(e.buf.items, e.caret) else e.buf.items.len;
        } else if (kind.multiline() and (eq(k.name, "up") or eq(k.name, "down"))) {
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
        if (ui.src.flag(n, "secret", false) or kind == .editor)
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

/// How a terminal cell in style ts draws. Colors are 0xRRGGBBAA; 0 is
/// the default (`fg`, the ink's color; no fill; the glyph's color for the
/// underline). Inverse swaps the colors here, as the core leaves it to
/// the renderer; with no fill, the cell's current background is what
/// swaps in.
fn termPen(ts: core.TermStyle, fg: u32, g: *Grid, x: i32, y: i32) Pen {
    var f = if (ts.fg != 0) ts.fg else fg;
    var bg: ?u32 = if (ts.bg != 0) ts.bg else null;
    if (ts.flags & c.UIT_TERM_INVERSE != 0) {
        const under: u32 = bg orelse if (g.at(x, y)) |cell| (cell.bg << 8) | 0xff else 0xffffffff;
        bg = gridmod.blend(f, under >> 8) << 8 | 0xff;
        f = under;
    }
    return .{
        .fg = f,
        .bg = bg,
        .ul_color = if (ts.underline_color != 0) ts.underline_color else null,
        .attrs = .{
            .bold = ts.flags & c.UIT_TERM_BOLD != 0,
            .dim = ts.flags & c.UIT_TERM_FAINT != 0,
            .italic = ts.flags & c.UIT_TERM_ITALIC != 0,
            .strike = ts.flags & c.UIT_TERM_STRIKE != 0,
            .blink = ts.flags & c.UIT_TERM_BLINK != 0,
            .underline = ts.underline != c.UIT_TERM_UNDERLINE_NONE,
            .ul_style = switch (ts.underline) {
                c.UIT_TERM_UNDERLINE_DOUBLE => .double,
                c.UIT_TERM_UNDERLINE_CURLY => .curly,
                c.UIT_TERM_UNDERLINE_DOTTED => .dotted,
                c.UIT_TERM_UNDERLINE_DASHED => .dashed,
                else => .single,
            },
        },
    };
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

/// A grid cell (or a description-list item) shares its row evenly.
fn gridCell(b: *Box, span: usize) void {
    if (b.st.layout.w != null or b.st.layout.basis != null) return;
    if (b.st.layout.grow == null) c.YGNodeStyleSetFlexGrow(b.yg, @floatFromInt(span));
    c.YGNodeStyleSetFlexBasis(b.yg, 0);
    c.YGNodeStyleSetFlexShrink(b.yg, 1);
    c.YGNodeStyleSetMinWidth(b.yg, 0);
}

/// A table column's width (`columns`: `id label width ...`, in points).
fn colWidth(cell: *Box, fields: []const []const u8) void {
    const w: f32 = if (fields.len > 2) std.fmt.parseFloat(f32, fields[2]) catch 0 else 0;
    if (w > 0) {
        c.YGNodeStyleSetWidth(cell.yg, @max(3, style.cells(w, .x)));
        c.YGNodeStyleSetFlexShrink(cell.yg, 1);
        c.YGNodeStyleSetMinWidth(cell.yg, 3);
    } else {
        c.YGNodeStyleSetFlexGrow(cell.yg, 1);
        c.YGNodeStyleSetFlexBasis(cell.yg, 0);
    }
}

fn colInk(ink: Ink, fields: []const []const u8) Ink {
    var i = ink;
    for (fields) |f| {
        if (eq(f, "align=right")) i.text_align = .right;
        if (eq(f, "align=center")) i.text_align = .center;
    }
    return i;
}

fn dimmed(ink: Ink) Ink {
    var i = ink;
    i.dim = true;
    return i;
}

const Entry = struct {
    id: []const u8,
    label: []const u8,
    rest: []const []const u8,
    icon: ?[]const u8 = null,
    disabled: bool = false,
};

/// An `items` line: `id label [icon=name] [disabled]`, tab-separated
/// lines carrying more fields after the label.
fn entryOf(fields: []const []const u8) ?Entry {
    if (fields.len == 0) return null;
    var e: Entry = .{ .id = fields[0], .label = fields[0], .rest = &.{} };
    if (fields.len > 1 and !std.mem.startsWith(u8, fields[1], "icon=")) {
        e.label = fields[1];
        e.rest = fields[2..];
    } else e.rest = fields[1..];
    var keep: usize = e.rest.len;
    while (keep > 0) : (keep -= 1) {
        const f = e.rest[keep - 1];
        if (std.mem.startsWith(u8, f, "icon=")) e.icon = f[5..] else if (eq(f, "disabled")) e.disabled = true else break;
    }
    e.rest = e.rest[0..keep];
    return e;
}

fn hasChildren(items: []const core.Core.Line, id: []const u8) bool {
    for (items) |o| if (o.fields.len > 1 and eq(o.fields[1], id)) return true;
    return false;
}

/// The words of s with w added, or taken out if it was there.
fn toggled(a: std.mem.Allocator, s: []const u8, w: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\n");
    var had = false;
    while (it.next()) |x| {
        if (eq(x, w)) {
            had = true;
            continue;
        }
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, x);
    }
    if (!had) {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, w);
    }
    return out.items;
}

fn hasWord(s: []const u8, w: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, s, " \t\n");
    while (it.next()) |x| if (eq(x, w)) return true;
    return false;
}

const zone_names = [_][]const u8{ "left", "center", "bottom", "right" };

fn zoneIndex(z: []const u8) usize {
    for (zone_names, 0..) |name, i| if (eq(name, z)) return i;
    return 1;
}

fn zoneOf(src: Source, k: Node) usize {
    return zoneIndex(std.mem.trim(u8, src.text(k, "zone"), " \n"));
}

/// Up to two initials of a name, padded: ` AL `.
fn initials(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, ' ');
    var it = std.mem.tokenizeAny(u8, name, " \t\n");
    var k: usize = 0;
    while (it.next()) |w| : (k += 1) {
        if (k == 2) break;
        try out.append(a, std.ascii.toUpper(w[0]));
    }
    if (k == 0) try out.appendSlice(a, "?");
    try out.append(a, ' ');
    return out.items;
}

/// Markdown as plain text for a cell grid: heading marks, emphasis and
/// code ticks dropped, list bullets drawn as `•`.
pub fn mdPlain(a: std.mem.Allocator, md: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, md, "\n"), '\n');
    var first = true;
    while (lines.next()) |l0| {
        if (!first) try out.append(a, '\n');
        first = false;
        var l = l0;
        if (std.mem.startsWith(u8, l, "```")) continue;
        while (l.len > 0 and l[0] == '#') l = l[1..];
        if (l.len < l0.len) l = std.mem.trimStart(u8, l, " ");
        const lead = l.len - std.mem.trimStart(u8, l, " ").len;
        const rest = l[lead..];
        if (std.mem.startsWith(u8, rest, "- ") or std.mem.startsWith(u8, rest, "* ")) {
            try out.appendSlice(a, l[0..lead]);
            try out.appendSlice(a, "• ");
            l = rest[2..];
        }
        var i: usize = 0;
        while (i < l.len) : (i += 1) {
            if (l[i] == '`') continue;
            if (i + 1 < l.len and (l[i] == '*' or l[i] == '_') and l[i + 1] == l[i]) {
                i += 1;
                continue;
            }
            try out.append(a, l[i]);
        }
    }
    return out.items;
}

/// `{name}` in s replaced by the item's value.
fn substitute(a: std.mem.Allocator, s: []const u8, vals: *const Vals) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '{') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '{') if (std.mem.indexOfScalarPos(u8, s, i, '}')) |j| {
            if (vals.get(s[i + 1 .. j])) |v| {
                try out.appendSlice(a, v);
                i = j + 1;
                continue;
            }
        };
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

const ChartPoint = struct { x: []const u8, y: f64 };

/// chart.rs's points: `data` is TSV with a header row; `x` and `y` name
/// columns (the first two by default); rows without a number are skipped.
fn chartPoints(a: std.mem.Allocator, data: []const u8, x: []const u8, y: []const u8) ![]ChartPoint {
    var out: std.ArrayList(ChartPoint) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    const head = lines.next() orelse return out.items;
    var xi: ?usize = if (x.len == 0) 0 else null;
    var yi: ?usize = if (y.len == 0) 1 else null;
    var hs = std.mem.splitScalar(u8, head, '\t');
    var k: usize = 0;
    while (hs.next()) |h| : (k += 1) {
        const t = std.mem.trim(u8, h, " \r");
        if (x.len > 0 and eq(t, x)) xi = k;
        if (y.len > 0 and eq(t, y)) yi = k;
    }
    const xc = xi orelse return out.items;
    const yc = yi orelse return out.items;
    while (lines.next()) |l| {
        if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
        var f: [64][]const u8 = undefined;
        var nf: usize = 0;
        var it = std.mem.splitScalar(u8, l, '\t');
        while (it.next()) |v| : (nf += 1) {
            if (nf == f.len) break;
            f[nf] = std.mem.trim(u8, v, " \r");
        }
        if (yc >= nf) continue;
        var buf: [64]u8 = undefined;
        var bl: usize = 0;
        for (f[yc]) |ch| if (ch != ',' and bl < buf.len) {
            buf[bl] = ch;
            bl += 1;
        };
        const v = std.fmt.parseFloat(f64, buf[0..bl]) catch continue;
        try out.append(a, .{ .x = if (xc < nf) f[xc] else "", .y = v });
    }
    return out.items;
}

const Message = struct { role: []const u8, time: []const u8, body: []const u8 };

fn msgHeader(line: []const u8) ?[3][]const u8 {
    var w: [4][]const u8 = undefined;
    var k: usize = 0;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |x| {
        if (k == 4) return null;
        w[k] = x;
        k += 1;
    }
    if (k < 2 or k > 3) return null;
    for ([_][]const u8{ "user", "assistant", "system", "tool" }) |r| if (eq(w[1], r)) return .{ w[0], w[1], if (k == 3) w[2] else "" };
    return null;
}

/// The `messages` format: a header line `id role [time]`, then the body
/// up to a blank line followed by the next header.
fn parseMessages(a: std.mem.Allocator, text: []const u8) ![]Message {
    var out: std.ArrayList(Message) = .empty;
    var ls: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try ls.append(a, std.mem.trimEnd(u8, l, "\r"));
    const L = ls.items;
    var i: usize = 0;
    const blank = struct {
        fn f(l: []const u8) bool {
            return std.mem.trim(u8, l, " \t").len == 0;
        }
    }.f;
    while (i < L.len) {
        if (blank(L[i])) {
            i += 1;
            continue;
        }
        const h = msgHeader(L[i]) orelse {
            i += 1;
            continue;
        };
        i += 1;
        const start = i;
        var end = i;
        while (i < L.len) {
            if (blank(L[i])) {
                var j = i;
                while (j < L.len and blank(L[j])) j += 1;
                if (j >= L.len) {
                    i = L.len;
                    break;
                }
                if (msgHeader(L[j]) != null) {
                    i = j;
                    break;
                }
                i = j;
            } else {
                i += 1;
                end = i;
            }
        }
        try out.append(a, .{ .role = h[1], .time = h[2], .body = try std.mem.join(a, "\n", L[start..end]) });
    }
    return out.items;
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

test {
    _ = raster;
}



// ---------------------------------------------------------------------
// Terminal nodes

/// A sidebar 10 columns wide and a terminal filling the rest: in a 40×8
/// grid (the title bar on row 0), the terminal's grid is 30×7 at (10, 1).
fn termSplit(a: std.mem.Allocator) !*source.Fake {
    const f = try source.Fake.init(a);
    try f.set(".", "style", "h-flex size-full");
    _ = try f.new("div", "side", &.{}, "w=80 v-flex self-start");
    _ = try f.new("text", "side/t", &.{.{ "text", "files" }}, "");
    _ = try f.new("terminal", "sh", &.{}, "flex-1");
    return f;
}

fn termText(g: *const Grid, x: usize, y: usize, w: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (g.cells[y * g.w + x .. y * g.w + x + w]) |cell| try out.appendSlice(testing.allocator, cell.ch);
    return out.toOwnedSlice(testing.allocator);
}

test "a terminal in a split layout draws its cells and cursor, and sends its grid" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try termSplit(arena.allocator());
    // A fixed screen as the plain engine hands it over: one default style,
    // trailing blanks left out, the cursor after the prompt.
    try f.term("sh", "$ echo hi\nhi\n$ ", &.{}, 2, 2, 80, 24);
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    var g: Grid = undefined;
    try render(f, 40, 8, &ui, &g);
    defer g.deinit(testing.allocator);

    try testing.expectEqualStrings("term-resize sh 30 7 0 0\n", f.log.items);
    const want = [_][]const u8{
        "$ echo hi                     ",
        "hi                            ",
        "$                             ",
        "                              ",
    };
    for (want, 0..) |w, i| {
        const got = try termText(&g, 10, 1 + i, 30);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(w, got);
    }
    const side = try termText(&g, 0, 1, 10);
    defer testing.allocator.free(side);
    try testing.expectEqualStrings("files     ", side);
    // Default cells take the theme's foreground on the node's background.
    try testing.expectEqual(@as(u32, 0x0a0a0a), g.at(10, 1).?.fg);
    try testing.expectEqual(@as(u32, 0xffffff), g.at(10, 1).?.bg);
    // Not focused: no hardware cursor, the cursor's cell reversed.
    try testing.expectEqual(@as(@TypeOf(g.cursor), null), g.cursor);
    try testing.expect(g.at(12, 3).?.attrs.reverse);

    // The same size again sends nothing; a wider window sends the new grid.
    try ui.frame(&g);
    try testing.expectEqualStrings("term-resize sh 30 7 0 0\n", f.log.items);
    g.deinit(testing.allocator);
    ui.cell_px = .{ 9, 18 };
    try render(f, 50, 10, &ui, &g);
    try testing.expectEqualStrings("term-resize sh 30 7 0 0\nterm-resize sh 40 9 9 18\n", f.log.items);
}

test "a terminal's styles: colors, attributes, inverse, selection, wide text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try termSplit(arena.allocator());
    try f.term("sh", "", &.{
        .{ .fg = 0xcd3131ff, .bg = 0, .underline_color = 0, .flags = c.UIT_TERM_BOLD | c.UIT_TERM_ITALIC, .underline = 0 },
        .{ .fg = 0, .bg = 0x1e1e1eff, .underline_color = 0xffcc00ff, .flags = 0, .underline = c.UIT_TERM_UNDERLINE_CURLY },
        .{ .fg = 0x00ff00ff, .bg = 0, .underline_color = 0, .flags = c.UIT_TERM_INVERSE, .underline = 0 },
        .{ .fg = 0, .bg = 0x0000ffff, .underline_color = 0, .flags = c.UIT_TERM_INVISIBLE, .underline = 0 },
    }, 0, 0, 30, 7);
    try f.termRow("sh", 0, &.{
        .{ .col = 0, .width = 3, .style = 1, .selected = 0, .text = core.str("red") },
        .{ .col = 4, .width = 4, .style = 2, .selected = 0, .text = core.str("dark") },
        .{ .col = 9, .width = 3, .style = 3, .selected = 0, .text = core.str("inv") },
        .{ .col = 13, .width = 3, .style = 4, .selected = 0, .text = core.str("pwd") },
        .{ .col = 17, .width = 4, .style = 0, .selected = 1, .text = core.str("日本") },
    });
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    var g: Grid = undefined;
    try render(f, 40, 8, &ui, &g);
    defer g.deinit(testing.allocator);

    const row = try termText(&g, 10, 1, 22);
    defer testing.allocator.free(row);
    // Invisible text draws its background only; a wide character takes
    // two cells (the right half is "").
    try testing.expectEqualStrings("red dark inv     日本 ", row);
    const red = g.at(10, 1).?;
    try testing.expectEqual(@as(u32, 0xcd3131), red.fg);
    try testing.expect(red.attrs.bold and red.attrs.italic and !red.attrs.underline);
    const dark = g.at(14, 1).?;
    try testing.expectEqual(@as(u32, 0x1e1e1e), dark.bg);
    try testing.expectEqual(@as(u32, 0x0a0a0a), dark.fg);
    try testing.expect(dark.attrs.underline and dark.attrs.ul_style == .curly);
    try testing.expectEqual(@as(?u32, 0xffcc00), dark.ul_color);
    // Inverse with no fill: the fg becomes the fill, the node's
    // background becomes the glyph.
    const inv = g.at(19, 1).?;
    try testing.expectEqual(@as(u32, 0x00ff00), inv.bg);
    try testing.expectEqual(@as(u32, 0xffffff), inv.fg);
    try testing.expectEqual(@as(u32, 0x0000ff), g.at(23, 1).?.bg);
    // The selection tints the cells it covers.
    try testing.expect(g.at(27, 1).?.bg != 0xffffff);
    try testing.expectEqual(@as(u32, 0xffffff), g.at(31, 1).?.bg);
}

test "a focused terminal gets keys through uit_key, the mouse and the wheel" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try termSplit(arena.allocator());
    try f.term("sh", "$ ", &.{}, 2, 0, 30, 7);
    try f.termCursorAt("sh", .{ .x = 2, .y = 0, .shape = c.UIT_TERM_CURSOR_BAR, .visible = 1, .blink = 1, .cols = 30, .rows = 7 });
    var ui = Ui.init(testing.allocator, f.source());
    defer ui.deinit();
    var g: Grid = undefined;
    try render(f, 40, 8, &ui, &g);
    defer g.deinit(testing.allocator);
    f.log.clearRetainingCapacity();

    // A press focuses it and goes to the core as a cell of its grid.
    try testing.expect(ui.onMouse(.{ .x = 15, .y = 3, .kind = .press }));
    _ = ui.onMouse(.{ .x = 18, .y = 3, .kind = .drag });
    _ = ui.onMouse(.{ .x = 50, .y = 3, .kind = .release });
    try testing.expectEqual(ui.lookup("sh").?, ui.focused);
    try ui.frame(&g);
    try testing.expectEqual(@as(u16, 12), g.cursor.?.x);
    try testing.expectEqual(@as(u16, 1), g.cursor.?.y);
    try testing.expectEqual(gridmod.CursorShape.bar, g.cursor.?.shape);

    _ = ui.onMouse(.{ .x = 15, .y = 3, .kind = .wheel_up });
    _ = ui.onMouse(.{ .x = 15, .y = 3, .kind = .wheel_down });

    // Every key goes to the program, Tab, Escape and Ctrl-C included;
    // Ctrl-Q still closes the window.
    try testing.expectEqual(Ui.KeyResult.handled, ui.onKey(.{ .name = "a", .text = "a" }));
    try testing.expectEqual(Ui.KeyResult.handled, ui.onKey(.{ .name = "tab" }));
    try testing.expectEqual(Ui.KeyResult.handled, ui.onKey(.{ .name = "escape" }));
    try testing.expectEqual(Ui.KeyResult.handled, ui.onKey(.{ .name = "c", .ctrl = true }));
    try testing.expectEqual(Ui.KeyResult.handled, ui.onKey(.{ .name = "up", .shift = true }));
    try testing.expectEqual(Ui.KeyResult.handled, ui.onKey(.{ .name = "日本", .text = "日本" }));
    try testing.expectEqual(ui.lookup("sh").?, ui.focused);
    try testing.expectEqual(Ui.KeyResult.quit, ui.onKey(.{ .name = "q", .ctrl = true }));

    try testing.expectEqualStrings(
        \\term-mouse sh press 1 5,2 clicks=1
        \\term-mouse sh move 1 8,2 clicks=1
        \\term-mouse sh release 1 29,2 clicks=1
        \\term-scroll sh -3
        \\term-scroll sh 3
        \\key a
        \\key tab
        \\key escape
        \\key ctrl-c
        \\key shift-up
        \\term-text sh 日本
        \\
    , f.log.items);

    // A click outside takes focus away; Ctrl-C quits again.
    _ = ui.onMouse(.{ .x = 2, .y = 1, .kind = .press });
    _ = ui.onMouse(.{ .x = 2, .y = 1, .kind = .release });
    try testing.expect(ui.focused != ui.lookup("sh").?);
    try testing.expectEqual(Ui.KeyResult.quit, ui.onKey(.{ .name = "c", .ctrl = true }));
}
