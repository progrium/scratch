//! The server against MemFs over a socket pair: the 9P semantics core.md
//! leans on (write at close, errors at clunk, blocking event reads,
//! flush, line writes, directory reads, create and remove).

const std = @import("std");
const wire = @import("wire.zig");
const server = @import("server.zig");
const transport = @import("transport.zig");
const MemFs = @import("memfs.zig").MemFs;
const Client = @import("client.zig").Client;

const t = std.testing;
const p9 = wire.p9;

const Fixture = struct {
    threaded: std.Io.Threaded,
    mem: MemFs = undefined,
    srv: server.Server = undefined,
    cl: Client = undefined,
    root: u32 = 0,

    fn init(f: *Fixture) !void {
        f.threaded = .init(t.allocator, .{});
        const io = f.threaded.io();
        f.mem = .init(t.allocator, io);
        try f.mem.put("", "");
        try f.mem.put("ctl", "help\n");
        try f.mem.put("events", "");
        try f.mem.put("win/", "");
        try f.mem.put("win/main/", "");
        try f.mem.put("win/main/text", "hi\n");
        try f.mem.put("win/main/events", "");
        try f.mem.put("debug/", "");
        try f.mem.put("debug/lines", "");
        f.srv = .init(t.allocator, io, f.mem.fs());
        f.srv.on_error = .{ .ctx = f, .func = record };
        const p = try transport.pair();
        try f.srv.serve(p[0]);
        f.cl = try Client.init(t.allocator, p[1]);
        try f.cl.version();
        f.root = try f.cl.attach();
    }

    var last_loud: [256]u8 = undefined;
    var last_loud_len: usize = 0;
    fn record(_: *anyopaque, verb: []const u8, path: []const u8, text: []const u8) void {
        last_loud_len = if (std.fmt.bufPrint(&last_loud, "{s} {s}: {s}", .{ verb, path, text })) |x| x.len else |_| 0;
    }

    fn deinit(f: *Fixture) void {
        f.mem.hangup();
        f.cl.deinit();
        f.srv.deinit();
        f.mem.deinit();
        f.threaded.deinit();
    }
};

test "walk, read, write at close" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    const got = try f.cl.get(t.allocator, f.root, "win/main/text");
    defer t.allocator.free(got);
    try t.expectEqualStrings("hi\n", got);

    // Written in two pieces, applied once at clunk.
    const fid = try f.cl.walk(f.root, "win/main/text");
    try f.cl.open(fid, wire.OWRITE | wire.OTRUNC);
    _ = try f.cl.write(fid, 0, "hel");
    try t.expectEqualStrings("hi\n", f.mem.get("win/main/text").?);
    _ = try f.cl.write(fid, 3, "lo\n");
    try f.cl.clunk(fid);
    try t.expectEqualStrings("hello\n", f.mem.get("win/main/text").?);

    // An empty truncating write still commits (echo -n >file).
    try f.cl.put(f.root, "win/main/text", "");
    try t.expectEqualStrings("", f.mem.get("win/main/text").?);
}

test "a refused write fails the clunk with the Fs's text" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    try t.expectError(error.Rerror, f.cl.put(f.root, "win/main/text", "fail\n"));
    try t.expectEqualStrings("bad value: fail", f.cl.errText());
    try t.expectEqualStrings("write win/main/text: bad value: fail", Fixture.last_loud[0..Fixture.last_loud_len]);
    // The fid is gone even so.
    try t.expectError(error.Rerror, f.cl.put(f.root, "nope", "x"));
    try t.expectEqualStrings("not found", f.cl.errText());
}

test "walk failures and ..: partial walks and not found" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    try t.expectError(error.Rerror, f.cl.walk(f.root, "zzz"));
    try t.expectEqualStrings("not found", f.cl.errText());
    try t.expectError(error.NotFound, f.cl.walk(f.root, "win/zzz"));
    const fid = try f.cl.walk(f.root, "win/main/../main/text");
    try f.cl.clunk(fid);
    try t.expectError(error.NotFound, f.cl.walk(f.root, "ctl/x"));
    const ctl = try f.cl.walk(f.root, "ctl");
    try t.expectError(error.Rerror, f.cl.walk(ctl, "x"));
    try t.expectEqualStrings("not a directory", f.cl.errText());
    try f.cl.clunk(ctl);
}

test "directory reads return whole stat entries" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    const fid = try f.cl.walk(f.root, "win/main");
    try f.cl.open(fid, wire.OREAD);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(t.allocator);
    var off: u64 = 0;
    while (true) {
        // A small count forces several reads, one entry at a time.
        const d = try f.cl.read(fid, off, 70);
        if (d.len == 0) break;
        off += d.len;
        var at: usize = 0;
        while (at < d.len) {
            const pd = @import("dir.zig").Dir.parse(d[at..]).?;
            try names.appendSlice(t.allocator, pd[0].name);
            try names.append(t.allocator, ' ');
            at += pd[1];
        }
    }
    try f.cl.clunk(fid);
    try t.expectEqualStrings("text events ", names.items);
    const st = try f.cl.stat(f.root);
    try t.expect(st.mode & wire.DMDIR != 0);
}

test "events block until there is a line, and EOF at hangup" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    const fid = try f.cl.walk(f.root, "win/main/events");
    try f.cl.open(fid, wire.OREAD);
    try t.expectEqualStrings("resync - - seq=0\n", try f.cl.read(fid, 0, 8192));
    // Send the read, then the event.
    try f.cl.send(77, p9.Tread{ .fid = fid, .offset = 0, .count = 8192 });
    try f.mem.emit("click a a win=main seq=1\n");
    const r = try f.cl.recv();
    try t.expectEqual(@as(u16, 77), r.tag);
    try t.expectEqualStrings("click a a win=main seq=1\n", r.msg.Rread.data.bytes);
    // A short read splits a long line.
    try f.mem.emit("change - x win=main value=abcdef seq=2\n");
    try t.expectEqualStrings("change", try f.cl.read(fid, 0, 6));
    try t.expectEqualStrings(" - x win=main value=abcdef seq=2\n", try f.cl.read(fid, 0, 8192));
    f.mem.hangup();
    try t.expectEqualStrings("", try f.cl.read(fid, 0, 8192));
    try f.cl.clunk(fid);
}

test "flush interrupts a blocked events read and gets no Rread" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    const fid = try f.cl.walk(f.root, "events");
    try f.cl.open(fid, wire.OREAD);
    _ = try f.cl.read(fid, 0, 8192);
    try f.cl.send(5, p9.Tread{ .fid = fid, .offset = 0, .count = 8192 });
    try f.cl.send(6, p9.Tflush{ .oldtag = 5 });
    const r = try f.cl.recv();
    try t.expectEqual(@as(u16, 6), r.tag);
    try t.expect(r.msg == .Rflush);
    // The fid still works.
    try f.mem.emit("x - - seq=3\n");
    try t.expectEqualStrings("x - - seq=3\n", try f.cl.read(fid, 0, 8192));
    try f.cl.clunk(fid);
}

test "clunk of a fid with a blocked read" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    const fid = try f.cl.walk(f.root, "events");
    try f.cl.open(fid, wire.OREAD);
    _ = try f.cl.read(fid, 0, 8192);
    try f.cl.send(9, p9.Tread{ .fid = fid, .offset = 0, .count = 8192 });
    try f.cl.send(10, p9.Tclunk{ .fid = fid });
    // Both answer: the read fails as interrupted, the clunk succeeds.
    var saw_clunk = false;
    var saw_read = false;
    for (0..2) |_| {
        const r = try f.cl.recv();
        if (r.tag == 10) saw_clunk = r.msg == .Rclunk;
        if (r.tag == 9) saw_read = true;
    }
    try t.expect(saw_clunk and saw_read);
}

test "lines files apply each line as it completes" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    const fid = try f.cl.walk(f.root, "debug/lines");
    try f.cl.open(fid, wire.OWRITE);
    _ = try f.cl.write(fid, 0, "one\ntw");
    try t.expectEqual(@as(usize, 1), f.mem.lines.items.len);
    _ = try f.cl.write(fid, 0, "o\n\nthree\n");
    try t.expectEqual(@as(usize, 3), f.mem.lines.items.len);
    try t.expectEqualStrings("two", f.mem.lines.items[1]);
    try t.expectError(error.Rerror, f.cl.write(fid, 0, "fail\n"));
    try t.expectEqualStrings("bad syntax: fail", f.cl.errText());
    try f.cl.clunk(fid);
}

test "create and remove go through the Fs" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    const dir = try f.cl.walk(f.root, "win/main");
    try f.cl.create(dir, "b", wire.DMDIR | 0o777, wire.OREAD);
    try f.cl.clunk(dir);
    const b = try f.cl.walk(f.root, "win/main/b");
    try f.cl.create(b, "label", 0o666, wire.OWRITE);
    _ = try f.cl.write(b, 0, "ok\n");
    try f.cl.clunk(b);
    try t.expectEqualStrings("ok\n", f.mem.get("win/main/b/label").?);
    const l = try f.cl.walk(f.root, "win/main/b/label");
    try f.cl.remove(l);
    try t.expect(f.mem.get("win/main/b/label") == null);
    const again = try f.cl.walk(f.root, "win/main");
    try t.expectError(error.Rerror, f.cl.create(again, "b", wire.DMDIR | 0o777, wire.OREAD));
    try t.expectEqualStrings("in use", f.cl.errText());
    try f.cl.clunk(again);
}

test "hangup disconnects the connection from the Fs" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    f.cl.t.shutdown();
    f.srv.shutdown();
    try t.expectEqual(@as(u32, 1), f.mem.disconnects);
    f.deinit();
}

test "bad frames get Rerror, not a hangup" {
    var f: Fixture = .{ .threaded = undefined };
    try f.init();
    defer f.deinit();
    // A Tread with trailing bytes.
    var b: [32]u8 = undefined;
    const frame = try wire.encode(&b, 3, p9.Tclunk{ .fid = 1 }, null);
    var bad: [32]u8 = undefined;
    @memcpy(bad[0..frame.len], frame);
    bad[frame.len] = 0;
    std.mem.writeInt(u32, bad[0..4], @intCast(frame.len + 1), .little);
    try f.cl.t.writeAll(bad[0 .. frame.len + 1]);
    const r = try f.cl.recv();
    try t.expect(r.msg == .Rerror);
    // Still serving.
    const got = try f.cl.get(t.allocator, f.root, "ctl");
    defer t.allocator.free(got);
    try t.expectEqualStrings("help\n", got);
}

fn fuzzFrames(_: void, smith: *t.Smith) anyerror!void {
    var raw: [2048]u8 = undefined;
    const input = raw[0..smith.slice(&raw)];
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    var mem: MemFs = .init(t.allocator, threaded.io());
    defer mem.deinit();
    try mem.put("", "");
    try mem.put("ctl", "x\n");
    try mem.put("events", "");
    var srv: server.Server = .init(t.allocator, threaded.io(), mem.fs());
    const p = try transport.pair();
    try srv.serve(p[0]);
    // Version and attach first so the input reaches every handler.
    var cl = try Client.init(t.allocator, p[1]);
    try cl.version();
    _ = try cl.attach();
    cl.t.writeAll(input) catch {};
    cl.t.shutdown();
    mem.hangup();
    srv.deinit();
    cl.deinit();
}

test "fuzz the framing" {
    // Under `zig build test --fuzz` this explores; otherwise one pass.
    try t.fuzz({}, fuzzFrames, .{});
}
