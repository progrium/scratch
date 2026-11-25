//! Terminal nodes' live side (components.md § terminal, T3): one engine
//! (term/engine.zig, C1) per `terminal` node, the bounded buffer its `out`
//! stream fills, the readers of its `keys` stream, and the values 9P reads
//! that only the engine knows (`screen`, `selection`, `cols`, `rows`,
//! `title`, `cwd`).
//!
//! None of it is tree state: an engine is a parser with a screen, not a
//! value an op can copy and swap. The tree makes a `Term` when a terminal
//! node comes into the state and drops it when the node leaves (Tree.diff),
//! applies verbs to it after their op commits, and feeds it once per pump
//! (Tree.pumpTerms). Like `Files`, 9P threads reach it directly.
//!
//! Threads. The engine and everything marked "owner" belong to the tree's
//! owner thread. The rest is under `Term.mu`: the `out` buffer, the keys
//! readers, and the cached values, which the owner refreshes each pump.
//!
//! `out` is a bounded buffer of `out_cap` bytes: a writer blocks while it
//! is full, and the owner takes it all at the next pump and feeds it in one
//! call. So a program that writes 50 MB never makes the host hold more
//! than `out_cap` of it, and a pump never feeds more than that.
//!
//! A 9P read of a cached value first waits for the pump that feeds what
//! was written before it (`sync`), so `echo hi >out; cat screen` reads
//! `hi` though the write returned as soon as its bytes were buffered.

const std = @import("std");
const engine = @import("../term/engine.zig");
const state = @import("state.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Handle = state.Handle;

/// The most `out` holds before a writer waits.
pub const out_cap: usize = 64 * 1024;
/// The most a `keys` reader holds unread; past it, new keys are dropped
/// for that reader (a program that stopped reading).
pub const keys_cap: usize = 1 << 20;

pub const type_name = "terminal";

/// The values 9P reads from the engine rather than the state.
pub const live_files = [_][]const u8{ "screen", "selection", "cols", "rows", "title", "cwd", "tty" };

pub fn isLive(name: []const u8) bool {
    for (live_files) |f| if (std.mem.eql(u8, f, name)) return true;
    return false;
}

pub const Error = error{ OutOfMemory, Gone };

pub const Term = struct {
    terms: *Terms,
    h: Handle,
    rc: std.atomic.Value(u32) = .init(1),

    // ---- owner
    eng: engine.Engine,
    dirty: engine.Dirty = .{},
    events: engine.Events = .{},
    row_buf: engine.Row = .{},
    /// Bytes taken from `out` for this pump's feed.
    feeding: std.ArrayList(u8) = .empty,
    /// The drag that is selecting (no mouse mode): where it began.
    drag_from: ?engine.Point = null,
    drag_unit: @FieldType(@FieldType(engine.Selection, "range"), "unit") = .cells,
    /// The pointer's last cell, for wheel reports.
    pointer: engine.Point = .{ .col = 0, .row = 0 },
    /// Whether a window's focus was on the node at the last pump, for
    /// focus reports (DECSET 1004).
    focused: bool = false,

    // ---- under mu
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    out: std.ArrayList(u8) = .empty,
    readers: std.ArrayList(*KeyReader) = .empty,
    /// The node left the tree, or the app quit: writers fail, readers
    /// read end of file.
    closed: bool = false,
    /// Bumped when something changes what the cached values say (bytes
    /// written, a verb); `have` is the bump the owner last caught up to.
    want: u64 = 0,
    have: u64 = 0,
    screen: std.ArrayList(u8) = .empty,
    selection: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    cwd: std.ArrayList(u8) = .empty,
    cols: u16 = 0,
    rows: u16 = 0,

    fn gpa(t: *const Term) Allocator {
        return t.terms.gpa;
    }
    fn io(t: *const Term) Io {
        return t.terms.io;
    }
    fn lock(t: *Term) void {
        t.mu.lockUncancelable(t.io());
    }
    fn unlock(t: *Term) void {
        t.mu.unlock(t.io());
    }

    pub fn ref(t: *Term) *Term {
        _ = t.rc.fetchAdd(1, .monotonic);
        return t;
    }

    /// Any thread. The last one frees what is left; the engine is gone
    /// already (the owner deinits it when the node leaves).
    pub fn unref(t: *Term) void {
        if (t.rc.fetchSub(1, .acq_rel) != 1) return;
        const g = t.gpa();
        t.out.deinit(g);
        t.readers.deinit(g);
        t.screen.deinit(g);
        t.selection.deinit(g);
        t.title.deinit(g);
        t.cwd.deinit(g);
        g.destroy(t);
    }

    // ------------------------------------------------------------ out

    /// Any thread but the owner: appends program output, blocking while
    /// the buffer is full. Returns once every byte is buffered.
    pub fn write(t: *Term, bytes: []const u8) Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            t.lock();
            while (!t.closed and t.out.items.len >= out_cap) t.cond.waitUncancelable(t.io(), &t.mu);
            if (t.closed) {
                t.unlock();
                return error.Gone;
            }
            const n = @min(rest.len, out_cap - t.out.items.len);
            t.out.appendSlice(t.gpa(), rest[0..n]) catch {
                t.unlock();
                return error.OutOfMemory;
            };
            t.want += 1;
            t.unlock();
            rest = rest[n..];
            t.terms.wakeOwner();
        }
    }

    /// Any thread but the owner: waits until the owner has fed everything
    /// written (and applied every verb) before the call, so the cached
    /// values say it.
    pub fn sync(t: *Term) void {
        t.lock();
        defer t.unlock();
        const target = t.want;
        if (t.have >= target or t.closed) return;
        t.terms.wakeOwner();
        while (t.have < target and !t.closed) t.cond.waitUncancelable(t.io(), &t.mu);
    }

    // ------------------------------------------------------------ cached

    /// Any thread: a live file's value, as 9P reads it (one line with its
    /// newline; `screen` and `selection` as the engine writes them). Null
    /// for a file that isn't live.
    pub fn readFile(t: *Term, a: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        const eq = std.mem.eql;
        t.lock();
        defer t.unlock();
        if (eq(u8, name, "screen")) return try a.dupe(u8, t.screen.items);
        if (eq(u8, name, "selection")) return try a.dupe(u8, t.selection.items);
        if (eq(u8, name, "cols")) return try std.fmt.allocPrint(a, "{d}\n", .{t.cols});
        if (eq(u8, name, "rows")) return try std.fmt.allocPrint(a, "{d}\n", .{t.rows});
        if (eq(u8, name, "title")) return try line(a, t.title.items);
        if (eq(u8, name, "cwd")) return try line(a, t.cwd.items);
        if (eq(u8, name, "tty")) return ""; // pty mode (T6) sets it
        return null;
    }

    fn line(a: Allocator, v: []const u8) Allocator.Error![]const u8 {
        if (v.len == 0) return "";
        return std.mem.concat(a, u8, &.{ v, "\n" });
    }

    // ------------------------------------------------------------ keys

    /// Owner: bytes for the program (an encoded key, a paste), to every
    /// open `keys` reader.
    pub fn sendKeys(t: *Term, bytes: []const u8) void {
        if (bytes.len == 0) return;
        t.lock();
        defer t.unlock();
        for (t.readers.items) |r| {
            if (r.buf.items.len - r.off + bytes.len > keys_cap) continue;
            r.buf.appendSlice(t.gpa(), bytes) catch continue;
        }
        t.cond.broadcast(t.io());
    }

    /// Any thread: a new reader of `keys`, which sees what is sent after
    /// this. Gone once the node is.
    pub fn openKeys(t: *Term) Error!*KeyReader {
        const r = try t.gpa().create(KeyReader);
        errdefer t.gpa().destroy(r);
        t.lock();
        defer t.unlock();
        if (t.closed) return error.Gone;
        try t.readers.append(t.gpa(), r);
        r.* = .{ .term = t.ref() };
        return r;
    }

    // ------------------------------------------------------------ owner

    /// Owner: takes what `out` holds for this pump. The writers waiting
    /// for room go on. Returns the `want` this catches up to.
    fn takeOut(t: *Term) u64 {
        t.lock();
        defer t.unlock();
        t.feeding.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(u8), &t.feeding, &t.out);
        // `out` keeps its full capacity for writers that don't allocate.
        if (t.out.capacity < out_cap) t.out.ensureTotalCapacityPrecise(t.gpa(), out_cap) catch {};
        t.cond.broadcast(t.io());
        return t.want;
    }

    /// Owner: refreshes the cached values from the engine and marks every
    /// bump up to `target` caught up.
    fn refresh(t: *Term, target: u64, text_too: bool) void {
        var scr: Writer.Allocating = .init(t.gpa());
        defer scr.deinit();
        var sel: Writer.Allocating = .init(t.gpa());
        defer sel.deinit();
        if (text_too) {
            t.eng.screenText(&scr.writer) catch {};
            t.eng.selectionText(&sel.writer) catch {};
        }
        const sz = t.eng.size();
        t.lock();
        defer t.unlock();
        if (text_too) {
            t.screen.clearRetainingCapacity();
            t.screen.appendSlice(t.gpa(), scr.written()) catch {};
            t.selection.clearRetainingCapacity();
            t.selection.appendSlice(t.gpa(), sel.written()) catch {};
        }
        t.cols = sz.cols;
        t.rows = sz.rows;
        t.have = target;
        t.cond.broadcast(t.io());
    }

    fn setText(t: *Term, which: *std.ArrayList(u8), v: []const u8) void {
        t.lock();
        defer t.unlock();
        which.clearRetainingCapacity();
        which.appendSlice(t.gpa(), v) catch {};
    }

    fn bump(t: *Term) void {
        t.lock();
        defer t.unlock();
        t.want += 1;
    }

    fn close(t: *Term) void {
        t.lock();
        defer t.unlock();
        t.closed = true;
        t.cond.broadcast(t.io());
    }

    fn deinitOwner(t: *Term) void {
        const g = t.gpa();
        t.eng.deinit();
        t.dirty.deinit(g);
        t.events.deinit(g);
        t.row_buf.deinit(g);
        t.feeding.deinit(g);
    }
};

/// One open of `keys`: what was sent since it opened, not yet read.
pub const KeyReader = struct {
    term: *Term,
    buf: std.ArrayList(u8) = .empty,
    off: usize = 0,
    interrupted: bool = false,

    /// Blocks until bytes arrive; 0 is end of file (the node is gone).
    pub fn read(r: *KeyReader, out: []u8) error{Interrupted}!usize {
        const t = r.term;
        t.lock();
        defer t.unlock();
        while (true) {
            if (r.off < r.buf.items.len) {
                const n = @min(out.len, r.buf.items.len - r.off);
                @memcpy(out[0..n], r.buf.items[r.off..][0..n]);
                r.off += n;
                if (r.off == r.buf.items.len) {
                    r.buf.clearRetainingCapacity();
                    r.off = 0;
                }
                return n;
            }
            if (t.closed) return 0;
            if (r.interrupted) {
                r.interrupted = false;
                return error.Interrupted;
            }
            t.cond.waitUncancelable(t.io(), &t.mu);
        }
    }

    pub fn interrupt(r: *KeyReader) void {
        const t = r.term;
        t.lock();
        defer t.unlock();
        r.interrupted = true;
        t.cond.broadcast(t.io());
    }

    pub fn close(r: *KeyReader) void {
        const t = r.term;
        const g = t.gpa();
        t.lock();
        for (t.readers.items, 0..) |x, i| if (x == r) {
            _ = t.readers.swapRemove(i);
            break;
        };
        t.unlock();
        r.buf.deinit(g);
        g.destroy(r);
        t.unref();
    }
};

/// What one terminal's pump changed, as uitcore.h's UitTermChange says it.
pub const Change = struct {
    node: Handle,
    /// UIT_TERM_* bits.
    what: u32,
    /// With `rows` and not `all`: viewport rows, ascending.
    rows: []const u32 = &.{},
};

pub const what_rows: u32 = 1;
pub const what_all: u32 = 2;
pub const what_cursor: u32 = 4;
pub const what_styles: u32 = 8;
pub const what_styles_reset: u32 = 16;
pub const what_size: u32 = 32;

/// Every terminal node's `Term`, by handle.
pub const Terms = struct {
    gpa: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    map: std.AutoArrayHashMapUnmanaged(Handle, *Term) = .empty,
    /// Schedules a pump: the OpQueue's wake, set by whoever pumps.
    wake: ?*const fn (?*anyopaque) void = null,
    wake_ctx: ?*anyopaque = null,
    /// The app is gone: no new terminals.
    down: bool = false,
    /// False in a replica's tree (render/replica.zig): its terminals are
    /// drawn from the stream's records, not parsed here.
    enabled: bool = true,

    pub fn init(gpa: Allocator, io: Io) Terms {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(ts: *Terms) void {
        for (ts.map.values()) |t| {
            t.close();
            t.deinitOwner();
            t.unref();
        }
        ts.map.deinit(ts.gpa);
    }

    fn wakeOwner(ts: *Terms) void {
        if (ts.wake) |w| w(ts.wake_ctx);
    }

    /// Any thread: the node's terminal, referenced (`unref` when done), or
    /// null if `h` isn't a terminal.
    pub fn get(ts: *Terms, h: Handle) ?*Term {
        ts.mu.lockUncancelable(ts.io);
        defer ts.mu.unlock(ts.io);
        const t = ts.map.get(h) orelse return null;
        return t.ref();
    }

    /// Owner: the node's terminal, not referenced.
    pub fn owned(ts: *Terms, h: Handle) ?*Term {
        return ts.map.get(h);
    }

    pub fn count(ts: *const Terms) usize {
        return ts.map.count();
    }

    pub fn handles(ts: *const Terms) []const Handle {
        return ts.map.keys();
    }

    /// Owner: a terminal node came into the tree.
    pub fn add(ts: *Terms, h: Handle, opts: engine.Opts) Allocator.Error!void {
        if (ts.map.contains(h) or ts.down or !ts.enabled) return;
        const t = try ts.gpa.create(Term);
        errdefer ts.gpa.destroy(t);
        t.* = .{ .terms = ts, .h = h, .eng = try engine.Engine.init(ts.gpa, opts) };
        errdefer t.eng.deinit();
        try t.out.ensureTotalCapacityPrecise(ts.gpa, out_cap);
        errdefer t.out.deinit(ts.gpa);
        t.refresh(0, true);
        ts.mu.lockUncancelable(ts.io);
        defer ts.mu.unlock(ts.io);
        try ts.map.put(ts.gpa, h, t);
    }

    /// Owner: a terminal node left the tree. Its writers fail with `gone`
    /// and its readers read end of file.
    pub fn remove(ts: *Terms, h: Handle) void {
        ts.mu.lockUncancelable(ts.io);
        const kv = ts.map.fetchSwapRemove(h);
        ts.mu.unlock(ts.io);
        const t = (kv orelse return).value;
        t.close();
        t.deinitOwner();
        t.unref();
    }

    /// Owner: the app is gone. Every stream ends; the engines stay for the
    /// renderer to draw until the tree goes.
    pub fn shutDown(ts: *Terms) void {
        ts.down = true;
        for (ts.map.values()) |t| t.close();
    }

    // ------------------------------------------------------------ pump

    /// Owner, once per pump: feeds each terminal what its `out` holds and
    /// collects what changed. `emit` is called for the node events the
    /// output caused (`title`, `bell`); `changes` gets one entry per
    /// terminal that changed, allocated in `a`.
    pub fn pump(ts: *Terms, a: Allocator, ctx: anytype, changes: *std.ArrayList(Change)) !void {
        for (ts.map.values()) |t| {
            const target = t.takeOut();
            if (t.feeding.items.len > 0) try t.eng.feed(t.feeding.items);
            t.feeding.clearRetainingCapacity();
            try t.eng.takeEvents(&t.events);
            if (t.events.title) |s| {
                t.setText(&t.title, t.events.str(s));
                try ctx.termEvent(t.h, "title", &.{});
            }
            if (t.events.cwd) |s| t.setText(&t.cwd, t.events.str(s));
            // OSC 52: the program copies. The tree puts it on the
            // clipboard as it would a client's `clip` write.
            for (t.events.clips.items) |cl| try ctx.termClip(t.h, cl.target, t.events.str(cl.data));
            // Focus reports: the program hears when a window's focus
            // comes to or leaves the node (it asked with DECSET 1004).
            const f = ctx.termFocused(t.h);
            if (f != t.focused) {
                t.focused = f;
                var aw: Writer.Allocating = .init(ts.gpa);
                defer aw.deinit();
                t.eng.encodeFocus(f, &aw.writer) catch return error.OutOfMemory;
                t.sendKeys(aw.written());
            }
            // One `bell` event per pump: a program ringing in a loop
            // shouldn't flood the event stream.
            if (t.events.bell > 0) try ctx.termEvent(t.h, "bell", &.{});
            // What the program asked the terminal to answer (DA, DSR, ...)
            // goes back to it as input. `reply` is T2's addition to the
            // engine contract; until it lands there is nothing to send.
            if (@hasField(engine.Events, "reply")) {
                if (t.events.reply) |s| t.sendKeys(t.events.str(s));
            }
            try t.eng.takeDirty(&t.dirty);
            const d = &t.dirty;
            if (d.any() or target != t.have) t.refresh(target, d.any());
            if (!d.any()) continue;
            var c: Change = .{ .node = t.h, .what = 0 };
            if (d.all) c.what |= what_rows | what_all;
            if (d.rows.items.len > 0 and !d.all) {
                c.what |= what_rows;
                const rows = try a.alloc(u32, d.rows.items.len);
                for (d.rows.items, rows) |r, *o| o.* = r;
                c.rows = rows;
            }
            if (d.cursor) c.what |= what_cursor;
            switch (d.styles) {
                .same => {},
                .grew => c.what |= what_styles,
                .reset => c.what |= what_styles | what_styles_reset | what_rows | what_all,
            }
            if (d.size) c.what |= what_size;
            try changes.append(a, c);
        }
    }

    // ------------------------------------------------------------ verbs

    /// Owner: a verb on the node's ctl, after its op committed.
    pub fn verb(ts: *Terms, h: Handle, act: Act) Allocator.Error!void {
        const t = ts.owned(h) orelse return;
        switch (act) {
            .write => |s| {
                // What `out` holds came first.
                const target = t.takeOut();
                if (t.feeding.items.len > 0) try t.eng.feed(t.feeding.items);
                t.feeding.clearRetainingCapacity();
                try t.eng.feed(s);
                // Fed, but not yet refreshed: the pump catches the cache up.
                _ = target;
            },
            .paste => |s| try ts.pasteTo(t, s),
            .reset => {
                t.eng.reset();
                t.setText(&t.title, "");
                t.setText(&t.cwd, "");
            },
            .scroll => |s| t.eng.scroll(s),
        }
        t.bump();
    }

    /// Owner: encodes a keystroke for the terminal's program. False if the
    /// engine has no bytes for it.
    pub fn key(ts: *Terms, h: Handle, k: engine.Key) Allocator.Error!bool {
        const t = ts.owned(h) orelse return false;
        var aw: Writer.Allocating = .init(ts.gpa);
        defer aw.deinit();
        const ok = t.eng.encodeKey(k, &aw.writer) catch return error.OutOfMemory;
        if (!ok) return false;
        t.sendKeys(aw.written());
        // Typing snaps the view back to the live screen.
        t.eng.scroll(.bottom);
        return true;
    }

    /// Owner: a paste from the user (the renderer's clipboard), as the
    /// `paste` verb sends it: bracketed when the program asked.
    pub fn paste(ts: *Terms, h: Handle, s: []const u8) Allocator.Error!void {
        const t = ts.owned(h) orelse return;
        try ts.pasteTo(t, s);
        t.bump();
    }

    fn pasteTo(ts: *Terms, t: *Term, s: []const u8) Allocator.Error!void {
        var aw: Writer.Allocating = .init(ts.gpa);
        defer aw.deinit();
        t.eng.encodePaste(s, &aw.writer) catch return error.OutOfMemory;
        t.sendKeys(aw.written());
        // Like typing, a paste snaps the view back to the live screen.
        t.eng.scroll(.bottom);
    }

    /// Owner: the selection's text, in `a`; empty with none.
    pub fn selectionText(ts: *Terms, a: Allocator, h: Handle) Allocator.Error![]const u8 {
        const t = ts.owned(h) orelse return "";
        var aw: Writer.Allocating = .init(a);
        t.eng.selectionText(&aw.writer) catch return error.OutOfMemory;
        return aw.written();
    }

    /// Owner: committed text (IME, a typed character).
    pub fn text(ts: *Terms, h: Handle, s: []const u8) Allocator.Error!void {
        const t = ts.owned(h) orelse return;
        var aw: Writer.Allocating = .init(ts.gpa);
        defer aw.deinit();
        t.eng.encodeText(s, &aw.writer) catch return error.OutOfMemory;
        t.sendKeys(aw.written());
        t.eng.scroll(.bottom);
    }

    /// Owner: the renderer's grid. True if the size changed.
    pub fn resize(ts: *Terms, h: Handle, sz: engine.Size) Allocator.Error!bool {
        const t = ts.owned(h) orelse return false;
        const before = t.eng.size();
        try t.eng.resize(sz);
        const after = t.eng.size();
        t.bump();
        return before.cols != after.cols or before.rows != after.rows;
    }

    /// Owner: a press, release or move. True when the program took it
    /// (a mouse mode); otherwise a left drag selects.
    pub fn mouse(ts: *Terms, h: Handle, m: engine.Mouse) Allocator.Error!bool {
        const t = ts.owned(h) orelse return false;
        t.pointer = .{ .col = m.col, .row = m.row };
        var aw: Writer.Allocating = .init(ts.gpa);
        defer aw.deinit();
        const took = t.eng.encodeMouse(m, &aw.writer) catch return error.OutOfMemory;
        if (took) {
            t.sendKeys(aw.written());
            return true;
        }
        const at: engine.Point = .{ .col = m.col, .row = m.row };
        switch (m.action) {
            .press => if (m.button == .left) {
                t.drag_unit = switch (m.clicks) {
                    0, 1 => .cells,
                    2 => .words,
                    else => .lines,
                };
                t.drag_from = at;
                // A single click clears; a double or triple selects at once.
                t.eng.select(if (t.drag_unit == .cells) .none else .{ .range = .{ .start = at, .end = at, .unit = t.drag_unit } });
                t.bump();
            },
            .move => if (t.drag_from) |from| {
                if (m.button == .left) {
                    t.eng.select(.{ .range = .{ .start = from, .end = at, .unit = t.drag_unit } });
                    t.bump();
                }
            },
            .release => if (m.button == .left) {
                if (t.drag_from) |from| if (t.drag_unit != .cells or from.col != at.col or from.row != at.row) {
                    t.eng.select(.{ .range = .{ .start = from, .end = at, .unit = t.drag_unit } });
                    t.bump();
                };
                t.drag_from = null;
            },
        }
        return false;
    }

    /// Owner: the wheel, in lines. Reported to the program under a mouse
    /// mode, arrow keys in the alternate screen with alternate scroll on,
    /// else the view moves. True when the program got it.
    pub fn wheel(ts: *Terms, h: Handle, lines: i32) Allocator.Error!bool {
        const t = ts.owned(h) orelse return false;
        if (lines == 0) return false;
        const md = t.eng.modes();
        const n: u32 = @min(@abs(lines), 100);
        if (md.mouse) {
            var aw: Writer.Allocating = .init(ts.gpa);
            defer aw.deinit();
            const btn: engine.MouseButton = if (lines < 0) .wheel_up else .wheel_down;
            for (0..n) |_| _ = t.eng.encodeMouse(.{ .action = .press, .button = btn, .col = t.pointer.col, .row = t.pointer.row }, &aw.writer) catch return error.OutOfMemory;
            t.sendKeys(aw.written());
            return true;
        }
        if (md.alt_screen and md.alt_scroll) {
            var aw: Writer.Allocating = .init(ts.gpa);
            defer aw.deinit();
            const k: engine.Key = .{ .code = .{ .named = if (lines < 0) .up else .down } };
            for (0..n) |_| _ = t.eng.encodeKey(k, &aw.writer) catch return error.OutOfMemory;
            t.sendKeys(aw.written());
            return true;
        }
        t.eng.scroll(.{ .lines = lines });
        t.bump();
        return false;
    }
};

/// A verb on a terminal's ctl (components.md § terminal), applied after
/// its op commits.
pub const Act = union(enum) {
    write: []const u8,
    paste: []const u8,
    reset,
    scroll: engine.Scroll,
};
