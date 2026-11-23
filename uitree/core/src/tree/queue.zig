//! OpQueue: ops from any thread, applied on the owner thread.
//!
//! A 9P thread `push`es an op with an `Ack` and calls `Ack.wait`, which
//! blocks until the owner thread's `drain` (inside a pump) has applied it.
//! The ack then holds `""` for success or the error text (`not found:
//! win/main/x`) the 9P reply carries. `push` copies the op, so the caller's
//! buffers are free as soon as it returns.

const std = @import("std");
const treem = @import("tree.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Op = treem.Op;

pub const Ack = struct {
    done: bool = false,
    ok: bool = false,
    buf: [512]u8 = undefined,
    len: usize = 0,

    /// Empty on success; else `phrase[: detail]`.
    pub fn text(a: *const Ack) []const u8 {
        return a.buf[0..a.len];
    }

    fn set(a: *Ack, ok: bool, msg: []const u8) void {
        a.ok = ok;
        const n = @min(msg.len, a.buf.len);
        @memcpy(a.buf[0..n], msg[0..n]);
        a.len = n;
        a.done = true;
    }
};

const Item = struct {
    op: Op,
    /// The op's owned bytes (path and data).
    mem: []u8,
    ack: ?*Ack,
};

pub const OpQueue = struct {
    gpa: Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    items: std.ArrayList(Item) = .empty,
    closed: bool = false,
    /// Called (from the pushing thread) after each push: schedule a pump.
    wake: ?*const fn (?*anyopaque) void = null,
    wake_ctx: ?*anyopaque = null,

    pub fn init(gpa: Allocator, io: Io) OpQueue {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(q: *OpQueue) void {
        q.close();
        q.items.deinit(q.gpa);
    }

    /// Any thread. Copies the op; `ack`, if given, must live until it is
    /// done. After `close`, fails the ack with `app gone` at once.
    pub fn push(q: *OpQueue, op: Op, ack: ?*Ack) Allocator.Error!void {
        const it = try own(q.gpa, op);
        q.mu.lockUncancelable(q.io);
        if (q.closed) {
            q.mu.unlock(q.io);
            q.gpa.free(it.mem);
            if (ack) |a| {
                q.mu.lockUncancelable(q.io);
                a.set(false, "app gone");
                q.cond.broadcast(q.io);
                q.mu.unlock(q.io);
            }
            return;
        }
        q.items.append(q.gpa, .{ .op = it.op, .mem = it.mem, .ack = ack }) catch |e| {
            q.mu.unlock(q.io);
            q.gpa.free(it.mem);
            return e;
        };
        q.mu.unlock(q.io);
        if (q.wake) |w| w(q.wake_ctx);
    }

    /// Any thread: blocks until the op the ack was pushed with is applied.
    pub fn wait(q: *OpQueue, ack: *Ack) void {
        q.mu.lockUncancelable(q.io);
        defer q.mu.unlock(q.io);
        while (!ack.done) q.cond.waitUncancelable(q.io, &q.mu);
    }

    /// `push`, then `wait`: the error text, or "" on success.
    pub fn call(q: *OpQueue, op: Op, ack: *Ack) Allocator.Error![]const u8 {
        ack.* = .{};
        try q.push(op, ack);
        q.wait(ack);
        return ack.text();
    }

    /// Owner thread: applies every queued op in order and acks each.
    /// Returns how many ran.
    pub fn drain(q: *OpQueue, tree: *treem.Tree) usize {
        q.mu.lockUncancelable(q.io);
        var batch = q.items;
        q.items = .empty;
        q.mu.unlock(q.io);
        defer batch.deinit(q.gpa);
        for (batch.items) |it| {
            defer q.gpa.free(it.mem);
            const r = tree.apply(it.op);
            if (it.ack) |a| {
                q.mu.lockUncancelable(q.io);
                if (r) |_| a.set(true, "") else |e| a.set(false, if (e == error.OutOfMemory) "out of memory" else tree.lastError());
                q.cond.broadcast(q.io);
                q.mu.unlock(q.io);
            }
        }
        return batch.items.len;
    }

    /// No more ops: pending ones fail with `app gone`, and so do later
    /// pushes.
    pub fn close(q: *OpQueue) void {
        q.mu.lockUncancelable(q.io);
        defer q.mu.unlock(q.io);
        q.closed = true;
        for (q.items.items) |it| {
            if (it.ack) |a| a.set(false, "app gone");
            q.gpa.free(it.mem);
        }
        q.items.clearRetainingCapacity();
        q.cond.broadcast(q.io);
    }

    fn own(gpa: Allocator, op: Op) Allocator.Error!struct { op: Op, mem: []u8 } {
        switch (op) {
            .write, .append => |f| {
                const mem = try gpa.alloc(u8, f.path.len + f.data.len);
                @memcpy(mem[0..f.path.len], f.path);
                @memcpy(mem[f.path.len..], f.data);
                const g: Op.FileOp = .{ .session = f.session, .path = mem[0..f.path.len], .data = mem[f.path.len..] };
                return .{ .op = if (op == .write) .{ .write = g } else .{ .append = g }, .mem = mem };
            },
            .mkdir, .remove => |f| {
                const mem = try gpa.dupe(u8, f.path);
                const g: Op.PathOp = .{ .session = f.session, .path = mem };
                return .{ .op = if (op == .mkdir) .{ .mkdir = g } else .{ .remove = g }, .mem = mem };
            },
            .session_closed => return .{ .op = op, .mem = &.{} },
        }
    }
};
