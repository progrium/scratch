//! The event bus: one queue per open `events` or `trace` file (core.md
//! § Subscriptions, § Two kinds of event, § Trace).
//!
//! A subscription's target is the app (every event), a node (that node and
//! its descendants; a window is its root node), or the trace. The tree
//! formats each event once and delivers it with the chain of nodes it is
//! about, so a node's subscribers see its descendants' events too.
//!
//! State events coalesce: a new one replaces a queued one with the same name
//! about the same node and moves to the back. Action events and requests are
//! never dropped; past `action_cap` queued, the reader gets `lost - - n=N`
//! instead. The first line of every events subscription is `resync - -
//! seq=N`, N the last seq handed out; a `trace` subscription starts with the
//! recent history instead.
//!
//! Thread-safe: the owner thread delivers, 9P threads read. `Stream.read`
//! blocks on the bus's condition variable until a line, the end, or an
//! `interrupt` (a 9P Tflush).

const std = @import("std");
const types = @import("../types/root.zig");
const state = @import("state.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Blob = state.Blob;
const Handle = state.Handle;

pub const EventKind = types.EventKind;

/// Queued action events per subscription before `lost` (core.md § Limits).
pub const action_cap: usize = 4096;
/// `trace` keeps at least this much recent history for a new reader.
pub const trace_cap_bytes: usize = 1 << 20;
pub const trace_min_lines: usize = 1000;

pub const Target = union(enum) {
    /// `$ui/events`.
    app,
    /// A node's (or a window's root's) `events`.
    node: Handle,
    /// `$ui/trace`.
    trace,
};

const Entry = struct {
    line: *Blob,
    kind: EventKind,
    /// The coalescing key: the event name and the node it's about (0 with
    /// `win` for a window-level or app-level event).
    name: []const u8,
    node: Handle,
    /// Counts against the action cap.
    counted: bool = false,
};

pub const ReadError = error{Interrupted};

pub const Stream = struct {
    bus: *Bus,
    target: Target,
    entries: std.ArrayList(Entry) = .empty,
    head: usize = 0,
    /// Action lines queued.
    actions: usize = 0,
    /// `lost` count waiting to be queued after the actions drain.
    lost: u64 = 0,
    /// No more entries: end of file once the queue drains.
    ended: bool = false,
    interrupted: bool = false,
    /// The rest of a line an earlier short read cut.
    partial: std.ArrayList(u8) = .empty,
    partial_off: usize = 0,

    fn queued(s: *const Stream) []Entry {
        return s.entries.items[s.head..];
    }

    fn push(s: *Stream, gpa: Allocator, e: Entry) Allocator.Error!void {
        if (s.ended) return;
        if (e.kind == .state) {
            const q = s.queued();
            for (q, 0..) |x, i| {
                if (x.kind == .state and x.node == e.node and std.mem.eql(u8, x.name, e.name)) {
                    x.line.unref(gpa);
                    _ = s.entries.orderedRemove(s.head + i);
                    break;
                }
            }
        }
        const counted = e.kind != .state and e.counted;
        if (counted) {
            if (s.actions >= action_cap) {
                s.lost += 1;
                return;
            }
            s.actions += 1;
        }
        try s.entries.append(gpa, .{ .line = e.line.ref(), .kind = e.kind, .name = e.name, .node = e.node, .counted = counted });
    }

    /// A line outside the event stream (resync, history, lost, gone): never
    /// coalesced, and not counted against the cap.
    fn pushLine(s: *Stream, gpa: Allocator, text: []const u8) Allocator.Error!void {
        const b = try Blob.create(gpa, text);
        defer b.unref(gpa);
        try s.entries.append(gpa, .{ .line = b.ref(), .kind = .action, .name = "", .node = 0 });
    }

    fn pop(s: *Stream, gpa: Allocator) void {
        const e = s.entries.items[s.head];
        if (e.counted) s.actions -= 1;
        e.line.unref(gpa);
        s.head += 1;
        if (s.head == s.entries.items.len) {
            s.entries.clearRetainingCapacity();
            s.head = 0;
        } else if (s.head > 64 and s.head * 2 > s.entries.items.len) {
            const rest = s.entries.items.len - s.head;
            std.mem.copyForwards(Entry, s.entries.items[0..rest], s.entries.items[s.head..]);
            s.entries.shrinkRetainingCapacity(rest);
            s.head = 0;
        }
    }

    /// `lost - - n=N` once the reader has room again.
    fn flushLost(s: *Stream, gpa: Allocator) void {
        if (s.lost == 0 or s.actions >= action_cap) return;
        var buf: [64]u8 = undefined;
        const seq = s.bus.nextSeqLocked();
        const line = std.fmt.bufPrint(&buf, "lost - - n={d} seq={d}\n", .{ s.lost, seq }) catch unreachable;
        s.lost = 0;
        s.pushLine(gpa, line) catch {};
    }

    /// Whole lines, as many as fit in `buf`; a line longer than `buf`
    /// comes back over several reads. Blocks until there is something to
    /// read. 0 is end of file.
    pub fn read(s: *Stream, buf: []u8) ReadError!usize {
        const b = s.bus;
        b.lock();
        defer b.unlock();
        while (true) {
            if (s.takeLocked(buf)) |n| return n;
            if (s.interrupted) {
                s.interrupted = false;
                return error.Interrupted;
            }
            b.cond.waitUncancelable(b.io, &b.mu);
        }
    }

    /// As `read`, without waiting: null when nothing is queued.
    pub fn tryRead(s: *Stream, buf: []u8) ?usize {
        s.bus.lock();
        defer s.bus.unlock();
        return s.takeLocked(buf);
    }

    fn takeLocked(s: *Stream, buf: []u8) ?usize {
        const gpa = s.bus.gpa;
        if (buf.len == 0) return 0;
        if (s.partial_off < s.partial.items.len) {
            const rest = s.partial.items[s.partial_off..];
            const n = @min(rest.len, buf.len);
            @memcpy(buf[0..n], rest[0..n]);
            s.partial_off += n;
            if (s.partial_off == s.partial.items.len) {
                s.partial.clearRetainingCapacity();
                s.partial_off = 0;
            }
            return n;
        }
        s.flushLost(gpa);
        if (s.queued().len == 0) return if (s.ended) 0 else null;
        const first = s.queued()[0].line.bytes;
        if (first.len > buf.len) {
            @memcpy(buf, first[0..buf.len]);
            s.partial.clearRetainingCapacity();
            s.partial.appendSlice(gpa, first[buf.len..]) catch {};
            s.partial_off = 0;
            s.pop(gpa);
            return buf.len;
        }
        var n: usize = 0;
        while (s.queued().len > 0) {
            const l = s.queued()[0].line.bytes;
            if (n + l.len > buf.len) break;
            @memcpy(buf[n..][0..l.len], l);
            n += l.len;
            s.pop(gpa);
            s.flushLost(gpa);
        }
        return n;
    }

    /// Wakes a blocked `read`, which returns `error.Interrupted` (a 9P
    /// Tflush). Any thread.
    pub fn interrupt(s: *Stream) void {
        const b = s.bus;
        b.lock();
        defer b.unlock();
        s.interrupted = true;
        b.cond.broadcast(b.io);
    }

    /// The file was clunked: forget the subscription. Any thread; the
    /// stream must not be used again.
    pub fn close(s: *Stream) void {
        const b = s.bus;
        b.lock();
        defer b.unlock();
        for (b.streams.items, 0..) |x, i| if (x == s) {
            _ = b.streams.swapRemove(i);
            break;
        };
        s.freeLocked();
    }

    fn freeLocked(s: *Stream) void {
        const gpa = s.bus.gpa;
        for (s.queued()) |e| e.line.unref(gpa);
        s.entries.deinit(gpa);
        s.partial.deinit(gpa);
        gpa.destroy(s);
    }

    fn matches(s: *const Stream, chain: []const Handle) bool {
        return switch (s.target) {
            .app => true,
            .trace => false,
            .node => |h| std.mem.indexOfScalar(Handle, chain, h) != null,
        };
    }
};

/// A ring of the newest `trace` lines.
const TraceBuf = struct {
    lines: std.ArrayList([]u8) = .empty,
    head: usize = 0,
    bytes: usize = 0,

    fn push(t: *TraceBuf, gpa: Allocator, line: []const u8) Allocator.Error!void {
        const l = try gpa.dupe(u8, line);
        errdefer gpa.free(l);
        try t.lines.append(gpa, l);
        t.bytes += l.len + 1;
        while (t.bytes > trace_cap_bytes and t.lines.items.len - t.head > trace_min_lines) {
            const old = t.lines.items[t.head];
            t.bytes -= old.len + 1;
            gpa.free(old);
            t.head += 1;
        }
        if (t.head > 1024 and t.head * 2 > t.lines.items.len) {
            const rest = t.lines.items.len - t.head;
            std.mem.copyForwards([]u8, t.lines.items[0..rest], t.lines.items[t.head..]);
            t.lines.shrinkRetainingCapacity(rest);
            t.head = 0;
        }
    }

    fn all(t: *const TraceBuf) []const []u8 {
        return t.lines.items[t.head..];
    }

    fn clear(t: *TraceBuf, gpa: Allocator) void {
        for (t.all()) |l| gpa.free(l);
        t.lines.clearRetainingCapacity();
        t.head = 0;
        t.bytes = 0;
    }

    fn deinit(t: *TraceBuf, gpa: Allocator) void {
        t.clear(gpa);
        t.lines.deinit(gpa);
    }
};

pub const Bus = struct {
    gpa: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// The last seq handed out.
    seq: u64 = 0,
    streams: std.ArrayList(*Stream) = .empty,
    /// Nodes that exist, so a subscription can't start on a removed one.
    live: std.AutoHashMapUnmanaged(Handle, void) = .empty,
    trace: TraceBuf = .{},
    /// The app quit: every reader gets end of file, new subscriptions fail.
    gone: bool = false,

    pub fn init(gpa: Allocator, io: Io) Bus {
        return .{ .gpa = gpa, .io = io };
    }

    /// Frees every stream still open; their readers must be gone.
    pub fn deinit(b: *Bus) void {
        for (b.streams.items) |s| s.freeLocked();
        b.streams.deinit(b.gpa);
        b.live.deinit(b.gpa);
        b.trace.deinit(b.gpa);
    }

    pub fn lock(b: *Bus) void {
        b.mu.lockUncancelable(b.io);
    }
    pub fn unlock(b: *Bus) void {
        b.mu.unlock(b.io);
    }

    pub const SubscribeError = error{ AppGone, NotFound, OutOfMemory };

    /// One subscription per open of an `events` or `trace` file.
    pub fn subscribe(b: *Bus, target: Target) SubscribeError!*Stream {
        b.lock();
        defer b.unlock();
        if (b.gone) return error.AppGone;
        switch (target) {
            .node => |h| if (!b.live.contains(h)) return error.NotFound,
            else => {},
        }
        const s = try b.gpa.create(Stream);
        s.* = .{ .bus = b, .target = target };
        errdefer s.freeLocked();
        if (target == .trace) {
            for (b.trace.all()) |l| {
                const text = try std.mem.concat(b.gpa, u8, &.{ l, "\n" });
                defer b.gpa.free(text);
                try s.pushLine(b.gpa, text);
            }
        } else {
            var buf: [64]u8 = undefined;
            try s.pushLine(b.gpa, std.fmt.bufPrint(&buf, "resync - - seq={d}\n", .{b.seq}) catch unreachable);
        }
        try b.streams.append(b.gpa, s);
        return s;
    }

    pub fn lastSeq(b: *Bus) u64 {
        b.lock();
        defer b.unlock();
        return b.seq;
    }

    pub fn nextSeq(b: *Bus) u64 {
        b.lock();
        defer b.unlock();
        return b.nextSeqLocked();
    }

    fn nextSeqLocked(b: *Bus) u64 {
        b.seq += 1;
        return b.seq;
    }

    /// Whether an open events file would see an event about `chain` (the
    /// node and its ancestors, empty for an app-level event).
    pub fn hasReader(b: *Bus, chain: []const Handle) bool {
        b.lock();
        defer b.unlock();
        for (b.streams.items) |s| if (!s.ended and s.matches(chain)) return true;
        return false;
    }

    /// Queues one formatted line (with its seq and newline) for every
    /// reader of the app and of each node in `chain`. `node` is the
    /// coalescing key.
    pub fn deliver(b: *Bus, line: []const u8, name_len: usize, kind: EventKind, node: Handle, chain: []const Handle) Allocator.Error!void {
        b.lock();
        defer b.unlock();
        if (b.gone) return;
        const blob = try Blob.create(b.gpa, line);
        defer blob.unref(b.gpa);
        const e: Entry = .{ .line = blob, .kind = kind, .name = blob.bytes[0..name_len], .node = node, .counted = true };
        for (b.streams.items) |s| if (s.matches(chain)) try s.push(b.gpa, e);
        b.cond.broadcast(b.io);
    }

    /// One `trace` line (no newline), to the history and every reader.
    pub fn deliverTrace(b: *Bus, line: []const u8) Allocator.Error!void {
        b.lock();
        defer b.unlock();
        try b.trace.push(b.gpa, line);
        if (b.gone) return;
        var any = false;
        for (b.streams.items) |s| if (s.target == .trace) {
            any = true;
            break;
        };
        if (!any) return;
        const text = try std.mem.concat(b.gpa, u8, &.{ line, "\n" });
        defer b.gpa.free(text);
        for (b.streams.items) |s| if (s.target == .trace) {
            const blob = try Blob.create(b.gpa, text);
            defer blob.unref(b.gpa);
            try s.push(b.gpa, .{ .line = blob, .kind = .action, .name = "", .node = 0, .counted = true });
        };
        b.cond.broadcast(b.io);
    }

    /// Forgets the trace history (the host's own start-up writes).
    pub fn clearTrace(b: *Bus) void {
        b.lock();
        defer b.unlock();
        b.trace.clear(b.gpa);
    }

    pub fn addLive(b: *Bus, h: Handle) Allocator.Error!void {
        b.lock();
        defer b.unlock();
        try b.live.put(b.gpa, h, {});
    }

    /// The nodes went away: their readers get `gone - - seq=N`, then end of
    /// file.
    pub fn removeLive(b: *Bus, hs: []const Handle) void {
        b.lock();
        defer b.unlock();
        for (hs) |h| _ = b.live.remove(h);
        for (b.streams.items) |s| switch (s.target) {
            .node => |h| if (std.mem.indexOfScalar(Handle, hs, h) != null and !s.ended) {
                var buf: [48]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "gone - - seq={d}\n", .{b.nextSeqLocked()}) catch unreachable;
                s.pushLine(b.gpa, line) catch {};
                s.ended = true;
            },
            else => {},
        };
        b.cond.broadcast(b.io);
    }

    /// The app quit: every reader gets end of file, and new subscriptions
    /// fail with `app gone`.
    pub fn shutDown(b: *Bus) void {
        b.lock();
        defer b.unlock();
        b.gone = true;
        for (b.streams.items) |s| s.ended = true;
        b.cond.broadcast(b.io);
    }
};

const tt = std.testing;

test "resync, coalescing, lost, short reads, gone" {
    var b = Bus.init(tt.allocator, tt.io);
    defer b.deinit();
    try b.addLive(7);
    const s = try b.subscribe(.app);
    const n = try b.subscribe(.{ .node = 7 });
    var buf: [256]u8 = undefined;
    try tt.expectEqualStrings("resync - - seq=0\n", buf[0..s.tryRead(&buf).?]);
    try b.deliver("change - a seq=1\n", 6, .state, 7, &.{7});
    try b.deliver("click - b seq=2\n", 5, .action, 8, &.{8});
    try b.deliver("change - a seq=3\n", 6, .state, 7, &.{7});
    try tt.expectEqualStrings("click - b seq=2\nchange - a seq=3\n", buf[0..s.tryRead(&buf).?]);
    try tt.expect(s.tryRead(&buf) == null);
    // A read shorter than the line.
    try tt.expectEqual(@as(usize, 4), n.tryRead(buf[0..4]).?);
    try tt.expectEqualStrings("resy", buf[0..4]);
    try tt.expectEqualStrings("nc - - seq=0\n", buf[0..n.tryRead(&buf).?]);
    try tt.expectEqualStrings("change - a seq=3\n", buf[0..n.tryRead(&buf).?]);
    b.removeLive(&.{7});
    const g = buf[0..n.tryRead(&buf).?];
    try tt.expect(std.mem.startsWith(u8, g, "gone - - seq="));
    try tt.expectEqual(@as(usize, 0), n.tryRead(&buf).?);
    n.close();
    try tt.expectError(error.NotFound, b.subscribe(.{ .node = 7 }));
    s.close();
}

test "the action cap, then lost" {
    var b = Bus.init(tt.allocator, tt.io);
    defer b.deinit();
    const s = try b.subscribe(.app);
    defer s.close();
    var big: [1 << 18]u8 = undefined;
    _ = s.tryRead(&big);
    for (0..action_cap + 3) |_| try b.deliver("key - - seq=1\n", 3, .action, 0, &.{});
    try b.deliver("move - - seq=2\n", 4, .state, 0, &.{});
    const got = big[0..s.tryRead(&big).?];
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, got, "\n"), '\n');
    var i: usize = 0;
    var lost: ?[]const u8 = null;

    while (lines.next()) |l| : (i += 1) {
        if (std.mem.startsWith(u8, l, "lost")) lost = l;

    }
    try tt.expect(std.mem.startsWith(u8, lost.?, "lost - - n=3 seq="));
    try tt.expectEqual(action_cap + 2, i);

}

test "a blocked read wakes on an event, and on interrupt" {
    var b = Bus.init(tt.allocator, tt.io);
    defer b.deinit();
    const s = try b.subscribe(.app);
    defer s.close();
    var buf: [128]u8 = undefined;
    _ = s.tryRead(&buf);
    const R = struct {
        fn run(st: *Stream, out: *[128]u8, n: *usize) void {
            n.* = st.read(out) catch 999;
        }
    };
    var out: [128]u8 = undefined;
    var n: usize = 0;
    const th = try std.Thread.spawn(.{}, R.run, .{ s, &out, &n });
    try b.deliver("click - - seq=1\n", 5, .action, 0, &.{});
    th.join();
    try tt.expectEqualStrings("click - - seq=1\n", out[0..n]);
    const th2 = try std.Thread.spawn(.{}, R.run, .{ s, &out, &n });
    s.interrupt();
    th2.join();
    // Either the interrupt landed while blocked, or before the read began.
    try tt.expect(n == 999 or n == 0);
}
