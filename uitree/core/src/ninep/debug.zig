//! `/debug`: the headless host's debug directory (tests/conformance/
//! README.md § `/debug/inject`). Its one file, `inject`, takes lines in
//! the `ctl` syntax, each applied as soon as it is complete, and each
//! standing for something a user or the platform did:
//!
//! ```text
//! event NAME [win=W] [node=PATH] [key=K] [attr=value ...]
//! mirror [win=W] [node=PATH] file=NAME value=TEXT
//! bounds win=W node=PATH value='x y w h'
//! frame [win=W]
//! tick SECONDS
//! drag n=N type=TYPE data=TEXT
//! key win=W stroke=KEYS
//! menu item=ID
//! appearance mode=light|dark
//! ```
//!
//! This file parses the lines into `Inject` and hands each to an
//! `Injector`, which the host implements on its owner thread (the ABI's
//! input calls, plus the fake clock). Nothing here reaches `trace`.

const std = @import("std");
const proto = @import("../proto/root.zig");
const fsmod = @import("fs.zig");

const Allocator = std.mem.Allocator;
const Err = fsmod.Err;

pub const Inject = union(enum) {
    event: struct {
        name: []const u8,
        win: ?[]const u8 = null,
        node: ?[]const u8 = null,
        key: ?[]const u8 = null,
        /// Every other attribute, in order.
        attrs: []const proto.Attr = &.{},
    },
    mirror: struct {
        win: ?[]const u8 = null,
        node: ?[]const u8 = null,
        file: []const u8,
        value: []const u8,
    },
    bounds: struct {
        win: []const u8,
        node: []const u8,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    },
    frame: struct { win: ?[]const u8 = null },
    tick: struct { ns: u64 },
    drag: struct { n: u64, type: []const u8, data: []const u8 },
    key: struct { win: []const u8, stroke: []const u8 },
    menu: struct { item: []const u8 },
    appearance: struct { dark: bool },
};

/// Parses one inject line. Strings point into `arena` (or `line`).
pub fn parse(arena: Allocator, line: []const u8, err: *Err) fsmod.Error!Inject {
    var d: proto.Diag = .{};
    const c = proto.ctl.parseDiag(arena, line, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err.print("{s}{s}{s}", .{ d.code.phrase(), if (d.detail.len > 0) ": " else "", d.detail }),
    };
    if (c.style != null) return err.set("bad syntax: no style in inject");
    const verb = c.verb;
    if (std.mem.eql(u8, verb, "event")) {
        if (c.words.len != 1) return err.set("bad syntax: event NAME [attr=value ...]");
        var rest: std.ArrayList(proto.Attr) = .empty;
        var ev: Inject = .{ .event = .{ .name = c.words[0] } };
        for (c.attrs) |a| {
            if (std.mem.eql(u8, a.key, "win")) ev.event.win = a.value else if (std.mem.eql(u8, a.key, "node")) ev.event.node = a.value else if (std.mem.eql(u8, a.key, "key")) ev.event.key = a.value else try rest.append(arena, a);
        }
        ev.event.attrs = rest.items;
        if (ev.event.attrs.len > 0) for (ev.event.attrs) |a| {
            if (std.mem.eql(u8, a.key, "seq")) return err.set("bad value: seq is the host's");
        };
        return ev;
    }
    if (c.words.len > 0 and !std.mem.eql(u8, verb, "tick")) return err.print("bad syntax: {s} takes only attributes", .{verb});
    if (std.mem.eql(u8, verb, "mirror")) {
        return .{ .mirror = .{
            .win = c.attr("win"),
            .node = c.attr("node"),
            .file = c.attr("file") orelse return err.set("bad syntax: mirror needs file="),
            .value = c.attr("value") orelse return err.set("bad syntax: mirror needs value="),
        } };
    }
    if (std.mem.eql(u8, verb, "bounds")) {
        const v = c.attr("value") orelse return err.set("bad syntax: bounds needs value=");
        var it = std.mem.tokenizeAny(u8, v, " \t");
        var n: [4]f32 = undefined;
        for (&n) |*x| {
            const w = it.next() orelse return err.set("bad value: bounds is x y w h");
            x.* = std.fmt.parseFloat(f32, w) catch return err.print("bad value: {s}", .{w});
        }
        if (it.next() != null) return err.set("bad value: bounds is x y w h");
        return .{ .bounds = .{
            .win = c.attr("win") orelse return err.set("bad syntax: bounds needs win="),
            .node = c.attr("node") orelse return err.set("bad syntax: bounds needs node="),
            .x = n[0],
            .y = n[1],
            .w = n[2],
            .h = n[3],
        } };
    }
    if (std.mem.eql(u8, verb, "frame")) return .{ .frame = .{ .win = c.attr("win") } };
    if (std.mem.eql(u8, verb, "tick")) {
        if (c.words.len != 1 or c.attrs.len != 0) return err.set("bad syntax: tick SECONDS");
        const s = std.fmt.parseFloat(f64, c.words[0]) catch return err.print("bad value: {s}", .{c.words[0]});
        if (!(s >= 0) or s > 1e9) return err.print("bad value: {s}", .{c.words[0]});
        return .{ .tick = .{ .ns = @intFromFloat(s * std.time.ns_per_s) } };
    }
    if (std.mem.eql(u8, verb, "drag")) {
        const ns = c.attr("n") orelse return err.set("bad syntax: drag needs n=");
        return .{ .drag = .{
            .n = std.fmt.parseInt(u64, ns, 10) catch return err.print("bad value: {s}", .{ns}),
            .type = c.attr("type") orelse return err.set("bad syntax: drag needs type="),
            .data = c.attr("data") orelse "",
        } };
    }
    if (std.mem.eql(u8, verb, "key")) {
        return .{ .key = .{
            .win = c.attr("win") orelse return err.set("bad syntax: key needs win="),
            .stroke = c.attr("stroke") orelse return err.set("bad syntax: key needs stroke="),
        } };
    }
    if (std.mem.eql(u8, verb, "menu")) {
        return .{ .menu = .{ .item = c.attr("item") orelse return err.set("bad syntax: menu needs item=") } };
    }
    if (std.mem.eql(u8, verb, "appearance")) {
        const m = c.attr("mode") orelse return err.set("bad syntax: appearance needs mode=");
        if (std.mem.eql(u8, m, "light")) return .{ .appearance = .{ .dark = false } };
        if (std.mem.eql(u8, m, "dark")) return .{ .appearance = .{ .dark = true } };
        return err.print("bad value: {s}", .{m});
    }
    return err.print("unknown command: {s}", .{verb});
}

/// What applies an inject line: the host, on its owner thread.
pub const Injector = struct {
    ptr: *anyopaque,
    /// Blocks until applied. Errors are core.md phrases in `err`.
    apply: *const fn (ptr: *anyopaque, inj: *const Inject, err: *Err) fsmod.Error!void,
};

/// The `debug/` directory as an `Fs`, to mount with `Mux`.
pub const Debug = struct {
    injector: Injector,

    pub fn fs(d: *Debug) fsmod.Fs {
        return .{ .ptr = d, .vt = &vt };
    }

    const dir_entry: fsmod.Entry = .{ .kind = .dir, .qid = 0xdeb0_0000_0000_0001, .perm = 0o555 };
    const inject_entry: fsmod.Entry = .{ .kind = .file, .qid = 0xdeb0_0000_0000_0002, .perm = 0o222 };

    const vt: fsmod.Fs.VTable = .{
        .connect = connect,
        .disconnect = disconnect,
        .stat = stat,
        .list = list,
        .open = open,
        .read = read,
        .commit = commit,
        .line = line,
        .create = create,
        .remove = remove,
    };

    fn self(p: *anyopaque) *Debug {
        return @ptrCast(@alignCast(p));
    }
    fn connect(_: *anyopaque) fsmod.ConnId {
        return 0;
    }
    fn disconnect(_: *anyopaque, _: fsmod.ConnId) void {}
    fn stat(_: *anyopaque, _: fsmod.ConnId, path: []const u8) ?fsmod.Entry {
        if (path.len == 0) return dir_entry;
        if (std.mem.eql(u8, path, "inject")) return inject_entry;
        return null;
    }
    fn list(_: *anyopaque, _: fsmod.ConnId, path: []const u8, arena: Allocator, err: *Err) fsmod.Error![]const fsmod.DirEnt {
        if (path.len != 0) return err.set("not found");
        const out = try arena.alloc(fsmod.DirEnt, 1);
        out[0] = .{ .name = "inject", .entry = inject_entry };
        return out;
    }
    fn open(_: *anyopaque, _: fsmod.ConnId, path: []const u8, mode: fsmod.OpenMode, err: *Err) fsmod.Error!fsmod.Opened {
        if (!std.mem.eql(u8, path, "inject")) return err.set("not found");
        if (mode.read) return err.set("permission denied: write-only");
        return .{ .write_mode = .lines };
    }
    fn read(_: *anyopaque, _: fsmod.ConnId, _: []const u8, _: Allocator, err: *Err) fsmod.Error![]const u8 {
        return err.set("permission denied: write-only");
    }
    fn commit(_: *anyopaque, _: fsmod.ConnId, _: []const u8, _: u64, _: []const u8, _: *Err) fsmod.Error!void {}
    fn line(p: *anyopaque, _: fsmod.ConnId, _: []const u8, l: []const u8, err: *Err) fsmod.Error!void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        const inj = try parse(arena.allocator(), l, err);
        const d = self(p);
        return d.injector.apply(d.injector.ptr, &inj, err);
    }
    fn create(_: *anyopaque, _: fsmod.ConnId, _: []const u8, _: []const u8, _: bool, err: *Err) fsmod.Error!fsmod.Entry {
        return err.set("permission denied");
    }
    fn remove(_: *anyopaque, _: fsmod.ConnId, _: []const u8, err: *Err) fsmod.Error!void {
        return err.set("permission denied");
    }
};

test "parse inject lines" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: Err = .{};

    const ev = try parse(a, "event click win=main node=f/ok x=3 button=left", &err);
    try t.expectEqualStrings("click", ev.event.name);
    try t.expectEqualStrings("main", ev.event.win.?);
    try t.expectEqualStrings("f/ok", ev.event.node.?);
    try t.expect(ev.event.key == null);
    try t.expectEqual(@as(usize, 2), ev.event.attrs.len);
    try t.expectEqualStrings("button", ev.event.attrs[1].key);

    const b = try parse(a, "bounds win=main node=a value='10 20 300 40'", &err);
    try t.expectEqual(@as(f32, 300), b.bounds.w);

    const tk = try parse(a, "tick 2.5", &err);
    try t.expectEqual(@as(u64, 2_500_000_000), tk.tick.ns);

    const m = try parse(a, "mirror node=in file=value value='a b'", &err);
    try t.expectEqualStrings("a b", m.mirror.value);

    try t.expect((try parse(a, "appearance mode=dark", &err)).appearance.dark);
    try t.expectEqual(@as(u64, 3), (try parse(a, "drag n=3 type=text/plain data=hi", &err)).drag.n);
    try t.expectEqualStrings("cmd-s", (try parse(a, "key win=main stroke=cmd-s", &err)).key.stroke);
    try t.expectEqualStrings("save", (try parse(a, "menu item=save", &err)).menu.item);
    _ = try parse(a, "frame", &err);

    try t.expectError(error.Failed, parse(a, "warp x=1", &err));
    try t.expectEqualStrings("unknown command: warp", err.text());
    try t.expectError(error.Failed, parse(a, "appearance mode=blue", &err));
    try t.expectEqualStrings("bad value: blue", err.text());
    try t.expectError(error.Failed, parse(a, "bounds win=main node=a value='1 2 3'", &err));
    try t.expect(std.mem.startsWith(u8, err.text(), "bad value"));
    try t.expectError(error.Failed, parse(a, "event click 'win=main", &err));
    try t.expect(std.mem.startsWith(u8, err.text(), "bad syntax"));
    try t.expectError(error.Failed, parse(a, "tick -1", &err));
}
