//! The browser build (wasm32-wasi, `zig build web`). The core's threads
//! are hyper9's web-host coroutines (h9's src/web.zig: coroutines on
//! JSPI) and its Io is h9's web Io, whose blocking parks the calling
//! coroutine. h9 itself isn't linked: the app's machine runs in a Worker
//! of its own (h9's stock browser host), and its `$ui` mount is a
//! WebSocket that the page hands to the core as a channel
//! (`uit_web_serve`). See web/README.md.
//!
//! Everywhere else `enabled` is false and this is std.Thread.

const std = @import("std");
const builtin = @import("builtin");

pub const enabled = builtin.os.tag == .wasi;

const h9web = if (enabled) @import("h9web") else struct {};

/// A host thread: a coroutine in the browser.
pub const Thread = if (enabled) h9web.Thread else std.Thread;

/// The browser's Io (h9's web Io). Only in the web build.
pub fn io() std.Io {
    if (!enabled) unreachable;
    return h9web.io();
}

// The page's channels (web/uit-web.js): one per 9P connection. recv is a
// Suspending import: it parks the calling coroutine until bytes come.
extern "uit" fn chan_recv(id: i32, p: [*]u8, n: usize) i32;
extern "uit" fn chan_send(id: i32, p: [*]const u8, n: usize) i32;
extern "uit" fn chan_close(id: i32) void;

/// Reads what the channel has, parking until it has something. 0 at end.
pub fn recv(id: i32, buf: []u8) !usize {
    if (!enabled) unreachable;
    const n = h9web.coro.blocking(chan_recv, .{ id, buf.ptr, buf.len });
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

pub fn send(id: i32, b: []const u8) !void {
    if (!enabled) unreachable;
    if (chan_send(id, b.ptr, b.len) < 0) return error.WriteFailed;
}

pub fn close(id: i32) void {
    if (!enabled) unreachable;
    chan_close(id);
}

extern "uit" fn wake(ctx: ?*anyopaque) void;

/// UitConfig.wake for the page: tells uit-web.js to schedule a pump.
fn webWake(ctx: ?*anyopaque) callconv(.c) void {
    wake(ctx);
}

/// The page's side of the ABI: what uit-web.js needs that uitcore.h
/// doesn't give a JS host (memory to pass inputs in, a wake function).
fn uit_web_alloc(n: usize) callconv(.c) ?[*]u8 {
    const s = std.heap.c_allocator.alloc(u8, @max(n, 1)) catch return null;
    return s.ptr;
}
fn uit_web_free(p: [*]u8, n: usize) callconv(.c) void {
    std.heap.c_allocator.free(p[0..@max(n, 1)]);
}
fn uit_web_wake_fn() callconv(.c) usize {
    return @intFromPtr(&webWake);
}

comptime {
    if (enabled) {
        @export(&h9_web_locals, .{ .name = "h9_web_locals" });
        @export(&uit_web_alloc, .{ .name = "uit_web_alloc" });
        @export(&uit_web_free, .{ .name = "uit_web_free" });
        @export(&uit_web_wake_fn, .{ .name = "uit_web_wake_fn" });
    }
}

/// coro.c saves and restores h9's per-thread Zig state around a park.
/// The core has none (no threadlocals), so there's nothing to keep.
fn h9_web_locals(_: c_int, _: *[4]usize) callconv(.c) void {}
