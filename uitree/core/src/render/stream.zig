//! The change stream of the renderer tree (protocols/render.md § The
//! change stream): what a pump changed, as text lines a renderer in any
//! language applies to its copy of the tree.
//!
//! It encodes from the pump's `UitChanges` plus the state pinned at the
//! pump, on the owner thread at the end of `uit_pump` (render/hub.zig),
//! exactly where a built-in renderer reads the same nodes in place. One
//! encoding per pump, fanned out as bytes to every attached renderer.
//!
//!     snap 7
//!     theme mode=light tokens=<<END ... END
//!     window main title=Counter size=300,180 state=normal
//!     new div win/main order='dec n inc' : h-flex size-full ...
//!     new text win/main/n text=0 : text-3xl font-semibold
//!     end 7
//!     batch 8
//!     set win/main/n text=1
//!     redraw main
//!     end 8

const std = @import("std");
const abi = @import("../abi.zig");
const proto = @import("../proto/root.zig");
const types = @import("../types/root.zig");
const treem = @import("../tree/root.zig");
const termrec = @import("term.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const State = treem.state.State;
const Node = treem.state.Node;
const Handle = treem.Handle;
const tokenize = proto.tokenize;
const ctl = proto.ctl;

/// What the encoder reads: a pinned state and the catalog it was made
/// with. The core's at the end of uit_pump; any tree's in the checker.
pub const Source = struct {
    st: *const State,
    cat: *const types.Catalog,
    /// The live terminals the `term` records read (render.md § Terminals).
    /// Owner thread.
    terms: ?*treem.term.Terms = null,

    pub fn ofCore(c: *abi.Core) Source {
        return .{ .st = c.state(), .cat = &c.cat, .terms = &c.tree.terms };
    }
};

pub const Encoder = struct {
    gpa: Allocator,
    /// handle -> `win/main/f/ok`, for nodes the stream has made. A removed
    /// handle's path is only known from here.
    paths: std.AutoHashMapUnmanaged(Handle, []u8) = .empty,
    /// The reverse, for input lines that name a node by path. Keys are the
    /// same slices as `paths`' values.
    handles: std.StringHashMapUnmanaged(Handle) = .empty,
    /// The child order each node has as the renderer sees it: what the
    /// `new` lines appended and the `delete` lines took out, or the last
    /// `order=` sent. A batch sends `order=` only when the tree's differs,
    /// so a list that grows by one child costs one `new` line, not the
    /// whole list again (the first spike sent it every time: 71 MB for
    /// 5,000 rows built one write at a time).
    orders: std.AutoHashMapUnmanaged(Handle, std.ArrayList(Handle)) = .empty,
    parents: std.AutoHashMapUnmanaged(Handle, Handle) = .empty,
    /// uit_request seq -> the id= the renderer gave it, for `answer`.
    requests: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    /// `drag start ... id=ID` lines since the last batch: the stream
    /// tells the renderer the drag's number as `dragging ID N`.
    dragging: std.ArrayList(Dragging) = .empty,
    /// Pump number: every snapshot and batch carries the one it is as of.
    seq: u64 = 0,
    /// Made or removed inside an app's batch (core.md § Batches): the
    /// state the stream reads is the one from before the batch until it
    /// ends, so these wait for it.
    pend_created: std.ArrayList(Handle) = .empty,
    pend_removed: std.ArrayList(Handle) = .empty,
    /// Terminal styles the renderer has, by node: a batch sends the ones
    /// after these (`term-styles first=N`).
    term_styles: std.AutoHashMapUnmanaged(Handle, usize) = .empty,

    pub const Dragging = struct { id: []u8, n: u64 };

    pub fn deinit(e: *Encoder) void {
        var it = e.paths.valueIterator();
        while (it.next()) |p| e.gpa.free(p.*);
        e.paths.deinit(e.gpa);
        e.handles.deinit(e.gpa);
        e.clearOrders();
        e.orders.deinit(e.gpa);
        e.parents.deinit(e.gpa);
        var rit = e.requests.valueIterator();
        while (rit.next()) |v| e.gpa.free(v.*);
        e.requests.deinit(e.gpa);
        for (e.dragging.items) |d| e.gpa.free(d.id);
        e.dragging.deinit(e.gpa);
        e.pend_created.deinit(e.gpa);
        e.pend_removed.deinit(e.gpa);
        e.term_styles.deinit(e.gpa);
    }

    // -----------------------------------------------------------------
    // Terminals (render.md § Terminals)

    /// A terminal as a renderer that just learned of it needs it: `term`,
    /// the whole style table, and its rows that aren't blank.
    fn termFull(e: *Encoder, a: Allocator, src: Source, h: Handle, path: []const u8, w: *Writer) !void {
        const ts = src.terms orelse return;
        const t = ts.owned(h) orelse return;
        try termrec.writeTerm(w, path, abi.termCursor(t));
        const styles = try abi.termStyles(a, t, 0);
        try termrec.writeStyles(w, path, 0, styles);
        try e.term_styles.put(e.gpa, h, styles.len);
        const rows = try abi.termRows(a, t, 0, std.math.maxInt(u32));
        var kept: std.ArrayList(abi.UitTermRow) = .empty;
        for (rows) |r| if (r.n_runs > 0) try kept.append(a, r);
        try termrec.writeRows(w, path, kept.items);
    }

    /// What a pump changed in a terminal the renderer has.
    fn termChange(e: *Encoder, a: Allocator, src: Source, tc: abi.UitTermChange, path: []const u8, w: *Writer) !void {
        const ts = src.terms orelse return;
        const t = ts.owned(tc.node) orelse return;
        if (tc.what & (abi.UIT_TERM_CURSOR | abi.UIT_TERM_SIZE) != 0) try termrec.writeTerm(w, path, abi.termCursor(t));
        if (tc.what & (abi.UIT_TERM_STYLES | abi.UIT_TERM_STYLES_RESET) != 0) {
            const reset = tc.what & abi.UIT_TERM_STYLES_RESET != 0;
            const have = if (reset) 0 else e.term_styles.get(tc.node) orelse 0;
            const styles = try abi.termStyles(a, t, have);
            try termrec.writeStyles(w, path, @intCast(have), styles);
            try e.term_styles.put(e.gpa, tc.node, have + styles.len);
        }
        if (tc.what & abi.UIT_TERM_ALL != 0) {
            try termrec.writeRows(w, path, try abi.termRows(a, t, 0, std.math.maxInt(u32)));
        } else if (tc.what & abi.UIT_TERM_ROWS != 0 and tc.n_rows > 0) {
            var rows: std.ArrayList(abi.UitTermRow) = .empty;
            for (tc.rows.?[0..tc.n_rows]) |y| try rows.appendSlice(a, try abi.termRows(a, t, y, 1));
            try termrec.writeRows(w, path, rows.items);
        }
    }

    fn isTerm(n: *const Node) bool {
        return std.mem.eql(u8, n.ty.name, treem.term.type_name);
    }

    /// Forgets every path: a snapshot remakes them from the state.
    fn clearPaths(e: *Encoder) void {
        var it = e.paths.valueIterator();
        while (it.next()) |p| e.gpa.free(p.*);
        e.paths.clearRetainingCapacity();
        e.handles.clearRetainingCapacity();
    }

    fn clearOrders(e: *Encoder) void {
        var it = e.orders.valueIterator();
        while (it.next()) |l| l.deinit(e.gpa);
        e.orders.clearRetainingCapacity();
        e.parents.clearRetainingCapacity();
    }

    /// The renderer appended `h` to its parent's order (a `new` line).
    fn appended(e: *Encoder, h: Handle, parent: Handle) !void {
        try e.parents.put(e.gpa, h, parent);
        try e.orders.put(e.gpa, h, .empty);
        if (e.orders.getPtr(parent)) |l| try l.append(e.gpa, h);
    }

    /// The renderer dropped `h` (a `delete` line, or under one).
    fn dropped(e: *Encoder, h: Handle) void {
        if (e.parents.fetchRemove(h)) |kv| if (e.orders.getPtr(kv.value)) |l| {
            if (std.mem.indexOfScalar(Handle, l.items, h)) |i| _ = l.orderedRemove(i);
        };
        if (e.orders.fetchRemove(h)) |kv| {
            var l = kv.value;
            l.deinit(e.gpa);
        }
    }

    /// `set PATH order=...` if the tree's order for `h` isn't the one the
    /// renderer has.
    fn fixOrder(e: *Encoder, a: Allocator, st: *const State, h: Handle, w: *Writer) !void {
        const n = st.node(h) orelse return;
        const l = e.orders.getPtr(h) orelse return;
        if (std.mem.eql(Handle, l.items, n.order.items)) return;
        const path = e.paths.get(h) orelse return;
        try w.writeAll("set ");
        try tokenize.quoteWord(w, path);
        var bodies: Bodies = .{};
        try bodies.attr(a, w, "order", try orderText(a, st, n));
        try w.writeByte('\n');
        l.clearRetainingCapacity();
        try l.appendSlice(e.gpa, n.order.items);
    }

    pub fn lookup(e: *Encoder, path: []const u8) ?Handle {
        return e.handles.get(path);
    }

    fn remember(e: *Encoder, h: Handle, path: []const u8) !void {
        if (e.paths.get(h) != null) return;
        // A new node at an old path (a `tree` rewrite) takes the path over.
        if (e.handles.fetchRemove(path)) |old| {
            if (e.paths.fetchRemove(old.value)) |kv| e.gpa.free(kv.value);
        }
        const p = try e.gpa.dupe(u8, path);
        try e.paths.put(e.gpa, h, p);
        try e.handles.put(e.gpa, p, h);
    }

    fn forget(e: *Encoder, h: Handle) void {
        const kv = e.paths.fetchRemove(h) orelse return;
        if (e.handles.get(kv.value)) |cur| if (cur == h) {
            _ = e.handles.remove(kv.value);
        };
        e.gpa.free(kv.value);
    }

    // -----------------------------------------------------------------
    // Snapshot

    /// The whole committed tree, for a renderer that just attached or fell
    /// behind: `snap N` ... `end N`. Resets the path maps from the state.
    pub fn snapshot(e: *Encoder, src: Source, w: *Writer) !void {
        var arena: std.heap.ArenaAllocator = .init(e.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const st = src.st;
        e.clearOrders();
        e.clearPaths();
        e.term_styles.clearRetainingCapacity();
        try w.print("snap {d}\n", .{e.seq});
        try theme(src, w);
        if (treem.state.Blob.str(st.keys).len > 0) try keys(st, w);
        if (treem.state.Blob.str(st.bar).len > 0 or st.menus.items.len > 0) try menus(st, w);
        for (st.assets.items) |m| {
            try w.writeAll("asset ");
            try tokenize.quoteWord(w, m.name.bytes);
            try w.writeByte('\n');
        }
        for (st.wins.items) |win| {
            if (win.hidden) continue;
            try windowLine(st, win, w);
            var all: std.ArrayList(Handle) = .empty;
            try st.subtree(a, win.root, &all);
            for (all.items) |h| {
                const n = st.node(h) orelse continue;
                if (n.kind == .over) continue;
                const path = try fullPath(a, st, h);
                try e.remember(h, path);
                try nodeLine(a, n, path, w);
                try e.appended(h, n.parent);
                if (isTerm(n)) try e.termFull(a, src, h, path, w);
            }
            for (all.items) |h| try e.fixOrder(a, st, h, w);
            for (win.open.items) |h| try w.print("overlay open {s}\n", .{e.paths.get(h) orelse continue});
            if (win.focus != 0) try w.print("focus {s} {s}\n", .{ win.nameStr(), e.paths.get(win.focus) orelse "-" });
        }
        try w.print("end {d}\n", .{e.seq});
    }

    // -----------------------------------------------------------------
    // Batch

    /// What one pump changed, or nothing if it changed nothing a renderer
    /// draws. `x.t=` is CLOCK_MONOTONIC at the encode, in ns, for the
    /// spike's latency numbers.
    pub fn batch(e: *Encoder, src: Source, ch: *const abi.UitChanges, t_ns: u64, w: *Writer) !bool {
        const new_created = many(Handle, ch.created, ch.n_created);
        const new_removed = many(Handle, ch.removed, ch.n_removed);
        const props = many(abi.UitPropChange, ch.props, ch.n_props);
        const cmds = many(abi.UitHostCmd, ch.cmds, ch.n_cmds);
        const mirrors = many(abi.UitPropChange, ch.mirrors, ch.n_mirrors);
        const terms = many(abi.UitTermChange, ch.terms, ch.n_terms);
        if (new_created.len == 0 and new_removed.len == 0 and props.len == 0 and cmds.len == 0 and mirrors.len == 0 and terms.len == 0 and e.dragging.items.len == 0) return false;

        var arena: std.heap.ArenaAllocator = .init(e.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const st = src.st;

        // What the state doesn't show yet waits; what it shows goes now.
        var created: std.ArrayList(Handle) = .empty;
        var removed: std.ArrayList(Handle) = .empty;
        {
            var cand_c: std.ArrayList(Handle) = .empty;
            try cand_c.appendSlice(a, e.pend_created.items);
            try cand_c.appendSlice(a, new_created);
            var cand_r: std.ArrayList(Handle) = .empty;
            try cand_r.appendSlice(a, e.pend_removed.items);
            try cand_r.appendSlice(a, new_removed);
            e.pend_created.clearRetainingCapacity();
            e.pend_removed.clearRetainingCapacity();
            for (cand_r.items) |h| {
                if (st.node(h) == null) {
                    if (std.mem.indexOfScalar(Handle, removed.items, h) == null) try removed.append(a, h);
                } else if (std.mem.indexOfScalar(Handle, cand_c.items, h) == null) {
                    // Still there as the stream reads it (a batch is open).
                    if (e.paths.contains(h)) try e.pend_removed.append(e.gpa, h);
                }
            }
            for (cand_c.items) |h| {
                if (std.mem.indexOfScalar(Handle, created.items, h) != null) continue;
                if (e.paths.contains(h)) continue; // already sent: a batch aborted
                if (st.node(h) != null) {
                    try created.append(a, h);
                } else if (std.mem.indexOfScalar(Handle, cand_r.items, h) == null) {
                    try e.pend_created.append(e.gpa, h);
                }
            }
            std.mem.sort(Handle, created.items, {}, std.sort.asc(Handle));
        }

        try w.print("batch {d} x.t={d}\n", .{ e.seq, t_ns });

        // Windows first: a node line names its window. A window reaches
        // the stream when it first shows, with all it holds by then, as a
        // snapshot would say it; until then its nodes aren't sent.
        var made: std.AutoHashMapUnmanaged(Handle, void) = .empty;
        var reorder: std.AutoArrayHashMapUnmanaged(Handle, void) = .empty;
        var wins: std.AutoArrayHashMapUnmanaged(*treem.state.Win, void) = .empty;
        for (created.items) |h| if (st.winOfRoot(h)) |win| if (!win.hidden) try wins.put(a, win, {});
        for (cmds) |hc| if (hc.tag == abi.UIT_CMD_WINDOW) {
            if (st.win(hc.win.slice())) |win| try wins.put(a, win, {});
        };
        for (wins.keys()) |win| {
            try windowLine(st, win, w);
            if (e.paths.contains(win.root)) continue;
            var all: std.ArrayList(Handle) = .empty;
            try st.subtree(a, win.root, &all);
            for (all.items) |h| {
                const n = st.node(h) orelse continue;
                if (n.kind == .over) continue;
                const path = try fullPath(a, st, h);
                try e.remember(h, path);
                try nodeLine(a, n, path, w);
                try e.appended(h, n.parent);
                try made.put(a, h, {});
                try reorder.put(a, h, {});
            }
        }

        // Deletes: only the top of each removed subtree.
        var gone: std.AutoHashMapUnmanaged(Handle, void) = .empty;
        for (removed.items) |h| try gone.put(a, h, {});
        for (removed.items) |h| {
            const p = e.paths.get(h) orelse continue;
            if (!underRemoved(e, &gone, h, p)) try w.print("delete {s}\n", .{p});
        }
        for (removed.items) |h| {
            e.dropped(h);
            e.forget(h);
        }

        // News, parents first (the order the tree made them in).
        // A node whose type changed (`mkdir` then a write to `type`) is
        // remade: a renderer can't turn a div into a text in place.
        for (props) |pc| {
            if (!std.mem.eql(u8, pc.file.slice(), "type")) continue;
            if (made.contains(pc.node)) continue;
            const n = st.node(pc.node) orelse continue;
            if (!e.paths.contains(n.root)) continue; // window not sent yet
            if (e.paths.get(pc.node)) |p| {
                try w.print("delete {s}\n", .{p});
                e.dropped(pc.node);
                e.forget(pc.node);
            }
            var sub: std.ArrayList(Handle) = .empty;
            try st.subtree(a, pc.node, &sub);
            for (sub.items) |x| {
                const xn = st.node(x) orelse continue;
                if (xn.kind == .over) continue;
                if (x != pc.node) {
                    e.dropped(x);
                    e.forget(x);
                }
                const path = try fullPath(a, st, x);
                try e.remember(x, path);
                try nodeLine(a, xn, path, w);
                try e.appended(x, xn.parent);
                try made.put(a, x, {});
                try reorder.put(a, xn.parent, {});
            }
        }
        for (created.items) |h| {
            if (made.contains(h)) continue;
            const n = st.node(h) orelse continue;
            if (n.kind == .over) continue;
            if (!e.paths.contains(n.root) and h != n.root) continue; // window not sent yet
            if (h == n.root and (st.winOfRoot(h) orelse continue).hidden) continue;
            const path = try fullPath(a, st, h);
            try e.remember(h, path);
            try nodeLine(a, n, path, w);
            try e.appended(h, n.parent);
            try made.put(a, h, {});
            try reorder.put(a, n.parent, {});
        }

        // Sets: one line per node, its changed files as attributes.
        var by_node: std.AutoArrayHashMapUnmanaged(Handle, std.ArrayList([]const u8)) = .empty;
        for (props) |pc| {
            if (made.contains(pc.node)) continue;
            const f = pc.file.slice();
            if (std.mem.eql(u8, f, "type")) continue;
            if (isOverlayOpen(st, pc.node, f)) continue;
            if (isWindowFile(st, pc.node, f)) continue;
            if (std.mem.eql(u8, f, "order")) {
                try reorder.put(a, pc.node, {});
                continue;
            }
            const gop = try by_node.getOrPut(a, pc.node);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, f);
        }
        var bodies: Bodies = .{};
        for (by_node.keys(), by_node.values()) |h, files| {
            const n = st.node(h) orelse continue;
            const path = e.paths.get(h) orelse continue;
            try w.writeAll("set ");
            try tokenize.quoteWord(w, path);
            for (files.items) |f| if (std.mem.eql(u8, f, "style")) for (n.words.items) |x| {
                try w.writeByte(' ');
                try tokenize.quoteWord(w, x.name);
            };
            var style: ?[]const u8 = null;
            for (files.items) |f| {
                if (std.mem.eql(u8, f, "style")) {
                    // Words and the style text change together: say both.
                    style = n.value("style");
                    continue;
                }
                try bodies.attr(a, w, f, try propValue(a, st, n, f));
            }
            if (style) |s| {
                try w.writeAll(" :");
                if (s.len > 0) {
                    try w.writeByte(' ');
                    try w.writeAll(std.mem.trim(u8, s, " \t\r\n"));
                }
            }
            try bodies.flush(w);
            try w.writeByte('\n');
        }
        // What a renderer typed: `mirror`, not `set`, so the one that
        // typed it can tell its own echo from the app's write.
        var mirrored: std.AutoArrayHashMapUnmanaged(Handle, std.ArrayList([]const u8)) = .empty;
        for (mirrors) |pc| {
            if (made.contains(pc.node)) continue;
            const gop = try mirrored.getOrPut(a, pc.node);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, pc.file.slice());
        }
        for (mirrored.keys(), mirrored.values()) |h, files| {
            const n = st.node(h) orelse continue;
            const path = e.paths.get(h) orelse continue;
            try w.writeAll("mirror ");
            try tokenize.quoteWord(w, path);
            for (files.items) |f| try bodies.attr(a, w, f, try propValue(a, st, n, f));
            try bodies.flush(w);
            try w.writeByte('\n');
        }

        // Orders last, once every new and delete is in: only where the
        // tree's isn't what those imply. A removed child's parent comes
        // through as an `order` prop change.
        for (created.items) |h| try reorder.put(a, h, {});
        for (reorder.keys()) |h| try e.fixOrder(a, st, h, w);

        // Terminals: the ones just made whole, then what changed in the
        // others.
        for (removed.items) |h| _ = e.term_styles.remove(h);
        var made_it = made.keyIterator();
        var made_terms: std.ArrayList(Handle) = .empty;
        while (made_it.next()) |h| if (st.node(h.*)) |n| if (isTerm(n)) try made_terms.append(a, h.*);
        std.mem.sort(Handle, made_terms.items, {}, std.sort.asc(Handle));
        for (made_terms.items) |h| try e.termFull(a, src, h, e.paths.get(h) orelse continue, w);
        for (terms) |tc| {
            if (made.contains(tc.node)) continue;
            const path = e.paths.get(tc.node) orelse continue;
            try e.termChange(a, src, tc, path, w);
        }

        // Host commands, in order.
        for (cmds) |hc| try e.cmdLine(src, &hc, w);
        for (e.dragging.items) |d| {
            try w.writeAll("dragging ");
            try tokenize.quoteWord(w, d.id);
            try w.print(" {d}\n", .{d.n});
            e.gpa.free(d.id);
        }
        e.dragging.clearRetainingCapacity();

        try w.print("end {d}\n", .{e.seq});
        return true;
    }

    fn cmdLine(e: *Encoder, src: Source, hc: *const abi.UitHostCmd, w: *Writer) !void {
        const st = src.st;
        const win = hc.win.slice();
        switch (hc.tag) {
            abi.UIT_CMD_WINDOW => {}, // above
            abi.UIT_CMD_WINDOW_CTL => {
                try w.print("window-ctl {s} ", .{win});
                try ctlWords(w, &hc.ctl);
                try w.writeByte('\n');
            },
            abi.UIT_CMD_QUIT => try w.writeAll("quit\n"),
            abi.UIT_CMD_MENUS => try menus(st, w),
            abi.UIT_CMD_KEYMAP => try keys(st, w),
            abi.UIT_CMD_THEME => try theme(src, w),
            abi.UIT_CMD_SET_ACTION => try w.print("action {s} enabled={d} check={d}\n", .{ hc.name.slice(), hc.flag, hc.flag2 }),
            abi.UIT_CMD_OVERLAY => try w.print("overlay {s} {s}\n", .{ if (hc.flag == 1) "open" else "close", e.paths.get(hc.node) orelse "-" }),
            abi.UIT_CMD_FOCUS => try w.print("focus {s} {s}\n", .{ win, e.paths.get(hc.node) orelse "-" }),
            abi.UIT_CMD_CLIPBOARD => {
                try w.writeAll("clip");
                var bodies: Bodies = .{};
                try bodies.attr(undefined, w, "text", hc.answer.slice());
                try bodies.flush(w);
                try w.writeByte('\n');
            },
            abi.UIT_CMD_COMPONENT_VERB => {
                try w.print("verb {s} ", .{e.paths.get(hc.node) orelse "-"});
                try ctlWords(w, &hc.ctl);
                try w.writeByte('\n');
            },
            abi.UIT_CMD_ANSWER => {
                if (e.requests.fetchRemove(hc.seq)) |kv| {
                    defer e.gpa.free(kv.value);
                    try w.writeAll("answer ");
                    try tokenize.quoteWord(w, kv.value);
                    try w.writeByte(' ');
                } else try w.print("answer {d} ", .{hc.seq});
                try tokenize.quoteWord(w, hc.answer.slice());
                try w.writeByte('\n');
            },
            abi.UIT_CMD_REDRAW => try w.print("redraw {s}\n", .{win}),
            abi.UIT_CMD_THEME_LOAD => {
                try w.writeAll("theme-load ");
                try tokenize.quoteWord(w, hc.name.slice());
                try w.writeByte('\n');
            },
            abi.UIT_CMD_ASSETS => {
                try w.writeAll("asset ");
                try tokenize.quoteWord(w, hc.name.slice());
                try w.writeByte('\n');
            },
            else => {},
        }
    }
};

fn many(comptime T: type, p: ?[*]const T, n: usize) []const T {
    if (n == 0) return &.{};
    return (p orelse return &.{})[0..n];
}

fn underRemoved(e: *Encoder, gone: *std.AutoHashMapUnmanaged(Handle, void), self: Handle, path: []const u8) bool {
    var it = gone.keyIterator();
    while (it.next()) |g| {
        if (g.* == self) continue;
        const gp = e.paths.get(g.*) orelse continue;
        if (path.len > gp.len and std.mem.startsWith(u8, path, gp) and path[gp.len] == '/') return true;
    }
    return false;
}

fn fullPath(a: Allocator, st: *const State, h: Handle) ![]u8 {
    var aw: Writer.Allocating = .init(a);
    st.fullPath(&aw.writer, h) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn ctlWords(w: *Writer, c: *const abi.UitCtl) !void {
    try tokenize.quoteWord(w, c.verb.slice());
    for (many(abi.UitStr, c.args, c.n_args)) |x| {
        try w.writeByte(' ');
        try tokenize.quoteWord(w, x.slice());
    }
    for (many(abi.UitAttr, c.attrs, c.n_attrs)) |x| {
        try w.print(" {s}=", .{x.name.slice()});
        try tokenize.quoteValue(w, x.value.slice());
    }
}

/// Here-values for one line: attributes print `key=<<END` and the bodies
/// follow the line, in order.
const Bodies = struct {
    list: [16][]const u8 = undefined,
    markers: [16][24]u8 = undefined,
    mlen: [16]usize = undefined,
    n: usize = 0,

    fn attr(b: *Bodies, a: Allocator, w: *Writer, key: []const u8, v: []const u8) !void {
        _ = a;
        try w.print(" {s}=", .{key});
        if (ctl.hasNewline(v) and b.n < b.list.len) {
            const m = ctl.markerFor(&b.markers[b.n], v, b.n);
            // markerFor may return a static string; keep a copy.
            @memcpy(b.markers[b.n][0..m.len], m);
            b.mlen[b.n] = m.len;
            try w.print("<<{s}", .{m});
            b.list[b.n] = v;
            b.n += 1;
        } else try tokenize.quoteValue(w, v);
    }

    fn flush(b: *Bodies, w: *Writer) !void {
        for (0..b.n) |i| try ctl.writeBody(w, b.list[i], b.markers[i][0..b.mlen[i]]);
        b.n = 0;
    }
};

/// A file's value as uit_prop reads it, empty when unset.
fn propValue(a: Allocator, st: *const State, n: *const Node, f: []const u8) ![]const u8 {
    if (std.mem.eql(u8, f, "order")) return orderText(a, st, n);
    return abi.propOf(st, a, n, f) orelse "";
}

fn orderText(a: Allocator, st: *const State, n: *const Node) ![]const u8 {
    var aw: Writer.Allocating = .init(a);
    for (n.order.items, 0..) |ch, i| {
        if (i > 0) try aw.writer.writeByte(' ');
        try aw.writer.writeAll((st.node(ch) orelse continue).nameStr());
    }
    return aw.toOwnedSlice();
}

/// `window NAME prop=value ...`: the window's own props and state.
fn windowLine(st: *const State, win: *const treem.state.Win, w: *Writer) !void {
    try w.writeAll("window ");
    try tokenize.quoteWord(w, win.nameStr());
    if (win.title) |t| {
        try w.writeAll(" title=");
        try tokenize.quoteValue(w, t.bytes);
    }
    for (win.props.items) |p| {
        try w.print(" {s}=", .{p.key});
        try tokenize.quoteValue(w, p.val.bytes);
    }
    try w.print(" state={s}\n", .{@tagName(win.shownState())});
    _ = st;
}

/// A window's own file on its root: `window` and `window-ctl` say it.
fn isWindowFile(st: *const State, h: Handle, f: []const u8) bool {
    if (st.winOfRoot(h) == null) return false;
    if (std.mem.eql(u8, f, "state") or std.mem.eql(u8, f, "focus")) return true;
    return treem.state.inList(&treem.state.win_props, f);
}

fn isFlag(ty: *const types.Type, name: []const u8) bool {
    const x = ty.word(name) orelse return false;
    return x.kind == .flag;
}

const Item = struct { first: u32, word: ?[]const u8 = null, key: []const u8 = "", val: []const u8 = "" };

fn byFirst(_: void, x: Item, y: Item) bool {
    return x.first < y.first;
}

/// `new TYPE PATH words props : style`: one node, as tree/doc.zig prints
/// it in a document. Like `new` on a `ctl`, it appends the node to its
/// parent's order; `order` itself comes as a `set` when it differs.
fn nodeLine(a: Allocator, n: *const Node, path: []const u8, w: *Writer) !void {
    var items: std.ArrayList(Item) = .empty;
    var style: []const u8 = "";
    for (n.words.items) |x| try items.append(a, .{ .first = x.first, .word = x.name });
    for (n.files.items) |f| {
        const v = f.val.bytes;
        if (std.mem.eql(u8, f.name, "style")) {
            style = std.mem.trim(u8, v, " \t\r\n");
            continue;
        }
        if (std.mem.eql(u8, f.name, "order")) continue;
        // An overlay's `open` travels as `overlay open|close`.
        if (n.ty.tier == .overlay and std.mem.eql(u8, f.name, "open")) continue;
        if (treem.state.commonName(f.name) != null) {
            if (v.len > 0) try items.append(a, .{ .first = f.first, .key = f.name, .val = v });
            continue;
        }
        const p = n.ty.prop(f.name) orelse continue;
        if (p.readonly or treem.doc.isDefault(p, v)) continue;
        if (p.form == .bool and std.mem.eql(u8, v, "on") and isFlag(n.ty, f.name)) {
            try items.append(a, .{ .first = f.first, .word = f.name });
        } else try items.append(a, .{ .first = f.first, .key = f.name, .val = v });
    }
    std.mem.sort(Item, items.items, {}, byFirst);

    try w.writeAll("new ");
    try tokenize.quoteWord(w, n.ty.name);
    try w.writeByte(' ');
    try tokenize.quoteWord(w, path);
    for (items.items) |x| if (x.word) |word| {
        try w.writeByte(' ');
        try tokenize.quoteWord(w, word);
    };
    var bodies: Bodies = .{};
    for (items.items) |x| if (x.word == null) try bodies.attr(a, w, x.key, x.val);
    if (style.len > 0) {
        try w.writeAll(" : ");
        try w.writeAll(style);
    }
    try bodies.flush(w);
    try w.writeByte('\n');
}

/// `theme mode=light|dark tokens=<<END`: every token's value for the mode
/// in effect, as theme/tokens reads. Styles stay as written and the
/// renderer resolves names through this table, so a theme switch is one
/// record instead of every node's style again.
fn theme(src: Source, w: *Writer) !void {
    var aw: Writer.Allocating = .init(std.heap.c_allocator);
    defer aw.deinit();
    for (src.cat.theme_tokens) |t| try tokenLine(src, &aw.writer, t.name);
    for (types.style.value_tokens) |t| try tokenLine(src, &aw.writer, t.name);
    const body = std.mem.trimEnd(u8, aw.written(), "\n");
    try w.print("theme mode={s}", .{if (src.st.dark()) "dark" else "light"});
    const name = treem.state.Blob.str(src.st.theme_name);
    try w.writeAll(" name=");
    try tokenize.quoteValue(w, name);
    try w.writeAll(" tokens=<<END");
    try ctl.writeBody(w, body, "END");
    try w.writeByte('\n');
}

fn tokenLine(src: Source, w: *Writer, name: []const u8) !void {
    const v = abi.tokenOf(src.st, src.cat, name) orelse return;
    try w.print("{s} ", .{name});
    try tokenize.quote(w, v);
    try w.writeByte('\n');
}

/// `keys text=<<END`: the key bindings, as `$ui/keys` reads.
fn keys(st: *const State, w: *Writer) !void {
    try w.writeAll("keys");
    var bodies: Bodies = .{};
    try bodies.attr(undefined, w, "text", treem.state.Blob.str(st.keys));
    try bodies.flush(w);
    try w.writeByte('\n');
}

/// `menu-bar NAME...`, then `menu NAME text=<<END` for every menu, as
/// `$ui/menu/` reads. A menu change resends them all: menus are small.
fn menus(st: *const State, w: *Writer) !void {
    try w.writeAll("menu-bar");
    var it = std.mem.tokenizeAny(u8, treem.state.Blob.str(st.bar), " \t\r\n");
    while (it.next()) |name| {
        try w.writeByte(' ');
        try tokenize.quoteWord(w, name);
    }
    try w.writeByte('\n');
    for (st.menus.items) |m| {
        try w.writeAll("menu ");
        try tokenize.quoteWord(w, m.name.bytes);
        var bodies: Bodies = .{};
        try bodies.attr(undefined, w, "text", m.val.bytes);
        try bodies.flush(w);
        try w.writeByte('\n');
    }
}

fn isOverlayOpen(st: *const State, h: Handle, f: []const u8) bool {
    if (!std.mem.eql(u8, f, "open")) return false;
    const n = st.node(h) orelse return false;
    return n.ty.tier == .overlay;
}
