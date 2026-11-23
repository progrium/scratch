//! The browser as the core's platform (wasm32-wasi; web/README.md, "The
//! core's platform"). The core's threads are hyper9's web-host coroutines
//! (h9's src/web.zig: coroutines on JSPI) and its Io is h9's web Io,
//! whose blocking parks the calling coroutine. h9 itself isn't linked:
//! the app's machine is h9's stock browser host in a Worker, which the
//! page starts when the core asks (the `uit` imports below,
//! machine/web.zig), and whose `$ui` connections come back as UitConns.
//!
//! The page supplies these imports and nothing else; it reaches the core
//! only through uitcore.h. There are no exports here but the coroutines'
//! own (h9_coro_entry, h9_get_sp, h9_set_sp: the page needs them to run a
//! coroutine and keep the shadow stack pointer of whoever runs between
//! parks off the coroutines' stacks).
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

/// Calls `f` as a park, for anything that may be a Suspending import
/// (JSPI): the calling coroutine's per-thread state is saved around it.
/// Harmless when `f` doesn't suspend.
pub inline fn blocking(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    if (!enabled) unreachable;
    return h9web.coro.blocking(f, args);
}

/// The platform's imports (web/uit-web.js's `uit` module). Suspending ones
/// may only be called through `blocking`.
pub const platform = struct {
    /// Starts the app's machine with uitcore.h's UitMachineArgs (the page
    /// reads what it can use). A machine id, or negative.
    pub extern "uit" fn machine_start(args: *const anyopaque) i32;
    /// Suspending: the machine's next `$ui` connection, as a conn id; 0
    /// once the machine is gone; negative on error.
    pub extern "uit" fn machine_accept(id: i32) i32;
    /// Suspending: waits for the machine to end, puts its exit status
    /// (Plan 9's, empty for success) in buf and returns its length.
    pub extern "uit" fn machine_wait(id: i32, buf: [*]u8, n: usize) i32;
    /// A hangup: the page stops the machine. Any time, more than once.
    pub extern "uit" fn machine_hangup(id: i32) void;
    /// Suspending: as UitConn.read.
    pub extern "uit" fn conn_read(id: i32, buf: [*]u8, n: usize) i32;
    pub extern "uit" fn conn_write(id: i32, buf: [*]const u8, n: usize) i32;
    pub extern "uit" fn conn_hangup(id: i32) void;
    pub extern "uit" fn conn_release(id: i32) void;
};

extern "uit" fn wake(ctx: ?*anyopaque) void;

/// UitConfig.wake when the renderer gives none (a renderer in JS).
pub fn platformWake(ctx: ?*anyopaque) callconv(.c) void {
    wake(ctx);
}

comptime {
    if (enabled) @export(&h9_web_locals, .{ .name = "h9_web_locals" });
}

/// coro.c saves and restores h9's per-thread Zig state around a park.
/// The core has none (no threadlocals), so there's nothing to keep.
fn h9_web_locals(_: c_int, _: *[4]usize) callconv(.c) void {}
