//! Trace lines (core.md § Trace, and the formats conformance README.md
//! § Proposed pins): one per applied `ctl` command and file write, and one
//! per error. Paths are from `$ui`. A value with a newline, or over 64
//! bytes, shows as `len=N`; a secret value as `value=<secret>`.

const std = @import("std");
const proto = @import("../proto/root.zig");

const Writer = std.Io.Writer;
const quote = proto.tokenize.quote;

/// Values longer than this show as their length.
pub const value_cut: usize = 64;

/// `write path=P value=V`, `value` as stored (one newline already dropped).
pub fn write(w: *Writer, path: []const u8, value: []const u8, secret: bool) Writer.Error!void {
    try w.print("write path={s}", .{path});
    if (secret) return w.writeAll(" value=<secret>");
    try showValue(w, "value", value);
}

/// ` key=V`, or ` len=N` for a long or multi-line value.
fn showValue(w: *Writer, key: []const u8, v: []const u8) Writer.Error!void {
    if (std.mem.indexOfScalar(u8, v, '\n') != null or v.len > value_cut) {
        return w.print(" len={d}", .{v.len});
    }
    try w.print(" {s}=", .{key});
    try quote(w, v);
}

/// `ctl path=P cmd='C'` for one command of a `ctl` write. With `secret`,
/// a `value=` in it shows as `<secret>`. A `tree` command shows its
/// document's size.
pub fn ctl(w: *Writer, path: []const u8, c: proto.Ctl, secret: bool) Writer.Error!void {
    var buf: [512]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    showCtl(&fw, c, secret) catch {
        // Long: cut it.
        try w.print("ctl path={s} cmd=", .{path});
        return quote(w, fw.buffered());
    };
    try w.print("ctl path={s} cmd=", .{path});
    try quote(w, fw.buffered());
}

fn showCtl(w: *Writer, c: proto.Ctl, secret: bool) Writer.Error!void {
    try proto.tokenize.quoteWord(w, c.verb);
    if (std.mem.eql(u8, c.verb, "tree") and c.words.len > 1) {
        try w.writeByte(' ');
        try proto.tokenize.quoteWord(w, c.words[0]);
        var n: usize = 0;
        for (c.words[1..]) |x| n += x.len;
        return w.print(" len={d}", .{n});
    }
    for (c.words) |x| {
        try w.writeByte(' ');
        if (std.mem.indexOfScalar(u8, x, '\n') != null) {
            try w.print("<len={d}>", .{x.len});
        } else try proto.tokenize.quoteWord(w, x);
    }
    for (c.attrs) |a| {
        try w.writeByte(' ');
        try proto.tokenize.quoteWord(w, a.key);
        try w.writeByte('=');
        if (secret and std.mem.eql(u8, a.key, "value")) {
            try w.writeAll("<secret>");
        } else if (std.mem.indexOfScalar(u8, a.value, '\n') != null) {
            try w.print("<len={d}>", .{a.value.len});
        } else try proto.tokenize.quoteValue(w, a.value);
    }
    if (c.style) |st| {
        try w.writeAll(" :");
        for (st) |x| {
            try w.writeByte(' ');
            try quote(w, x);
        }
    }
}

/// `error path=P err='phrase: detail'`.
pub fn err(w: *Writer, path: []const u8, code: proto.Code, detail: []const u8) Writer.Error!void {
    var buf: [600]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    proto.err.format(&fw, code, detail) catch {};
    try w.print("error path={s} err=", .{path});
    try proto.tokenize.quoteAlways(w, fw.buffered());
}

test "trace lines" {
    const tt = std.testing;
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(&w, "win/main/a/text", "Hello", false);
    try tt.expectEqualStrings("write path=win/main/a/text value=Hello", w.buffered());
    w = .fixed(&buf);
    try write(&w, "win/main/a/text", "line one\nline two", false);
    try tt.expectEqualStrings("write path=win/main/a/text len=17", w.buffered());
    w = .fixed(&buf);
    try ctl(&w, "win/main/ctl", .{ .verb = "new", .words = &.{ "input", "pin", "secret" }, .attrs = &.{.{ .key = "value", .value = "1234" }} }, true);
    try tt.expectEqualStrings("ctl path=win/main/ctl cmd='new input pin secret value=<secret>'", w.buffered());
    w = .fixed(&buf);
    try err(&w, "win/main/a/style", .unknown_style_word, "flexx");
    try tt.expectEqualStrings("error path=win/main/a/style err='unknown style word: flexx'", w.buffered());
}
