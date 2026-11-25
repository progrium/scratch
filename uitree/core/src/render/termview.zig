//! A terminal's cells as the render stream says them (render.md §
//! Terminals): what a replica keeps for each `terminal` node from the
//! `term`, `term-styles` and `term-rows` records, so a core that draws a
//! remote app (uit_render_dial) answers uit_term_rows, uit_term_styles and
//! uit_term_cursor from it, and the checker (--check-render) can compare
//! its screen text with the live engine's.
//!
//! Owner: the tree glue (T3).

const std = @import("std");
const abi = @import("../abi.zig");
const treem = @import("../tree/root.zig");
const term = @import("term.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Handle = treem.Handle;

pub const View = struct {
    gpa: Allocator,
    cur: abi.UitTermCursor = .{},
    styles: std.ArrayList(abi.UitTermStyle) = .empty,
    /// One per viewport row; `cur.rows` of them.
    rows: std.ArrayList(Row) = .empty,
    /// UIT_TERM_* since the last `take`.
    what: u32 = 0,
    dirty: std.ArrayList(u32) = .empty,

    pub const Run = struct { col: u32, width: u32, style: u32, selected: u32, start: u32, len: u32 };
    pub const Row = struct {
        runs: std.ArrayList(Run) = .empty,
        text: std.ArrayList(u8) = .empty,

        fn deinit(r: *Row, gpa: Allocator) void {
            r.runs.deinit(gpa);
            r.text.deinit(gpa);
        }
        fn clear(r: *Row) void {
            r.runs.clearRetainingCapacity();
            r.text.clearRetainingCapacity();
        }
    };

    pub fn deinit(v: *View) void {
        for (v.rows.items) |*r| r.deinit(v.gpa);
        v.rows.deinit(v.gpa);
        v.styles.deinit(v.gpa);
        v.dirty.deinit(v.gpa);
    }

    fn mark(v: *View, y: u32) !void {
        v.what |= abi.UIT_TERM_ROWS;
        if (v.what & abi.UIT_TERM_ALL != 0) return;
        if (std.mem.indexOfScalar(u32, v.dirty.items, y) == null) try v.dirty.append(v.gpa, y);
    }

    /// A `term` record.
    pub fn setTerm(v: *View, c: abi.UitTermCursor) !void {
        const old = v.cur;
        v.cur = c;
        if (old.cols != c.cols or old.rows != c.rows) {
            v.what |= abi.UIT_TERM_SIZE | abi.UIT_TERM_ROWS | abi.UIT_TERM_ALL;
            if (c.rows < v.rows.items.len) {
                for (v.rows.items[c.rows..]) |*r| r.deinit(v.gpa);
                v.rows.shrinkRetainingCapacity(c.rows);
            }
            while (v.rows.items.len < c.rows) try v.rows.append(v.gpa, .{});
        }
        if (!std.meta.eql(old, c)) v.what |= abi.UIT_TERM_CURSOR;
    }

    /// A `term-styles` record's body, from id `first`.
    pub fn setStyles(v: *View, first: u32, body: []const u8) !void {
        if (first == 0) {
            if (v.styles.items.len > 0) v.what |= abi.UIT_TERM_STYLES_RESET | abi.UIT_TERM_ALL | abi.UIT_TERM_ROWS;
            v.styles.clearRetainingCapacity();
        } else if (first != v.styles.items.len) return error.BadSyntax;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |l| {
            if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
            try v.styles.append(v.gpa, try term.parseStyleLine(l));
        }
        v.what |= abi.UIT_TERM_STYLES;
    }

    /// A `term-rows` record's body.
    pub fn setRows(v: *View, body: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(v.gpa);
        defer arena.deinit();
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |l| {
            if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
            _ = arena.reset(.retain_capacity);
            const r = try term.parseRowLine(arena.allocator(), l);
            if (r.y >= v.rows.items.len) continue;
            const row = &v.rows.items[r.y];
            row.clear();
            const runs: []const abi.UitTermRun = if (r.runs) |p| p[0..r.n_runs] else &.{};
            for (runs) |x| {
                const start: u32 = @intCast(row.text.items.len);
                try row.text.appendSlice(v.gpa, x.text.slice());
                try row.runs.append(v.gpa, .{ .col = x.col, .width = x.width, .style = x.style, .selected = x.selected, .start = start, .len = @intCast(x.text.len) });
            }
            try v.mark(r.y);
        }
    }

    /// Rows `first .. first+n-1`, clipped, as the C ABI hands them, in `a`.
    pub fn rowsOut(v: *const View, a: Allocator, first: u32, n: u32) ![]abi.UitTermRow {
        const total: u32 = @intCast(v.rows.items.len);
        const lo = @min(first, total);
        const hi: u32 = @intCast(@min(@as(u64, first) + n, total));
        const out = try a.alloc(abi.UitTermRow, hi - lo);
        for (out, lo..) |*o, y| {
            const row = &v.rows.items[y];
            const runs = try a.alloc(abi.UitTermRun, row.runs.items.len);
            for (row.runs.items, runs) |x, *r| r.* = .{
                .col = x.col,
                .width = x.width,
                .style = x.style,
                .selected = x.selected,
                .text = abi.UitStr.of(row.text.items[x.start..][0..x.len]),
            };
            o.* = .{ .y = @intCast(y), .runs = if (runs.len > 0) runs.ptr else null, .n_runs = runs.len };
        }
        return out;
    }

    /// The `screen` file the runs say: one line per row, trailing blanks
    /// and trailing blank rows left out (engine.zig's screenText).
    pub fn screenText(v: *const View, w: *Writer) Writer.Error!void {
        var lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (lines.items) |l| v.gpa.free(l);
            lines.deinit(v.gpa);
        }
        var last: usize = 0;
        for (v.rows.items, 0..) |*row, y| {
            var aw: Writer.Allocating = .init(v.gpa);
            defer aw.deinit();
            var col: u32 = 0;
            for (row.runs.items) |x| {
                while (col < x.col) : (col += 1) try aw.writer.writeByte(' ');
                try aw.writer.writeAll(row.text.items[x.start..][0..x.len]);
                col = x.col + x.width;
            }
            const t = std.mem.trimEnd(u8, aw.written(), " ");
            lines.append(v.gpa, v.gpa.dupe(u8, t) catch return error.WriteFailed) catch return error.WriteFailed;
            if (t.len > 0) last = y + 1;
        }
        for (lines.items[0..last]) |l| {
            try w.writeAll(l);
            try w.writeByte('\n');
        }
    }

    /// What changed since the last call, as a UitTermChange's bits and
    /// rows (in `a`); clears it.
    pub fn take(v: *View, a: Allocator) !struct { what: u32, rows: []const u32 } {
        const what = v.what;
        var rows: []const u32 = &.{};
        if (what & abi.UIT_TERM_ROWS != 0 and what & abi.UIT_TERM_ALL == 0) {
            std.mem.sort(u32, v.dirty.items, {}, std.sort.asc(u32));
            rows = try a.dupe(u32, v.dirty.items);
        }
        v.what = 0;
        v.dirty.clearRetainingCapacity();
        return .{ .what = what, .rows = rows };
    }
};

/// Every terminal's view in a replica, by the replica tree's handle.
pub const Views = struct {
    map: std.AutoArrayHashMapUnmanaged(Handle, *View) = .empty,

    pub fn deinit(vs: *Views, gpa: Allocator) void {
        vs.clear(gpa);
        vs.map.deinit(gpa);
    }

    pub fn get(vs: *const Views, h: Handle) ?*View {
        return vs.map.get(h);
    }

    pub fn getOrMake(vs: *Views, gpa: Allocator, h: Handle) !*View {
        if (vs.map.get(h)) |v| return v;
        const v = try gpa.create(View);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa };
        try vs.map.put(gpa, h, v);
        return v;
    }

    /// Drops the views of nodes `st` no longer has.
    pub fn prune(vs: *Views, gpa: Allocator, st: *const treem.state.State) void {
        var i: usize = 0;
        while (i < vs.map.count()) {
            const h = vs.map.keys()[i];
            if (st.node(h) != null) {
                i += 1;
                continue;
            }
            const v = vs.map.values()[i];
            v.deinit();
            gpa.destroy(v);
            vs.map.swapRemoveAt(i);
        }
    }

    pub fn clear(vs: *Views, gpa: Allocator) void {
        for (vs.map.values()) |v| {
            v.deinit();
            gpa.destroy(v);
        }
        vs.map.clearRetainingCapacity();
    }
};
