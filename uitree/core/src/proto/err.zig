//! The error phrases of protocols/core.md § Errors, and how parsers report
//! them.
//!
//! A protocol error has a `Code`. On the wire it is a phrase (`not found`)
//! optionally followed by `: ` and detail for people; in an `error` event
//! it is the dashed name (`code=not-found`). The set is closed as of core
//! 1.0: a minor version never adds a phrase.
//!
//! Parsers return a Zig error from `Error` and, when given a `*Diag`, fill
//! it with the code and the detail text (allocated from the parser's
//! arena). `Code.fromError` maps the Zig error back to its code.

const std = @import("std");

pub const Code = enum {
    unknown_command,
    bad_syntax,
    bad_value,
    unknown_type,
    unknown_style_word,
    type_is_fixed,
    not_found,
    in_use,
    disabled,
    permission_denied,
    unsupported,
    too_large,
    no_batch,
    gone,
    app_gone,

    /// The phrase a 9P error starts with: `unknown style word`.
    pub fn phrase(c: Code) []const u8 {
        return switch (c) {
            inline else => |tag| comptime blk: {
                var s: [@tagName(tag).len]u8 = @tagName(tag).*;
                for (&s) |*b| if (b.* == '_') {
                    b.* = ' ';
                };
                const out = s;
                break :blk &out;
            },
        };
    }

    /// The dashed name an `error` event carries: `code=unknown-style-word`.
    pub fn name(c: Code) []const u8 {
        return switch (c) {
            inline else => |tag| comptime blk: {
                var s: [@tagName(tag).len]u8 = @tagName(tag).*;
                for (&s) |*b| if (b.* == '_') {
                    b.* = '-';
                };
                const out = s;
                break :blk &out;
            },
        };
    }

    pub fn fromPhrase(p: []const u8) ?Code {
        inline for (std.meta.fields(Code)) |f| {
            const c: Code = @enumFromInt(f.value);
            if (std.mem.eql(u8, p, c.phrase())) return c;
        }
        return null;
    }

    pub fn fromName(n: []const u8) ?Code {
        inline for (std.meta.fields(Code)) |f| {
            const c: Code = @enumFromInt(f.value);
            if (std.mem.eql(u8, n, c.name())) return c;
        }
        return null;
    }

    /// The Zig error for this code.
    pub fn err(c: Code) ProtoError {
        return switch (c) {
            .unknown_command => error.UnknownCommand,
            .bad_syntax => error.BadSyntax,
            .bad_value => error.BadValue,
            .unknown_type => error.UnknownType,
            .unknown_style_word => error.UnknownStyleWord,
            .type_is_fixed => error.TypeIsFixed,
            .not_found => error.NotFound,
            .in_use => error.InUse,
            .disabled => error.Disabled,
            .permission_denied => error.PermissionDenied,
            .unsupported => error.Unsupported,
            .too_large => error.TooLarge,
            .no_batch => error.NoBatch,
            .gone => error.Gone,
            .app_gone => error.AppGone,
        };
    }

    /// The code of a protocol error; null for any other error
    /// (`OutOfMemory`).
    pub fn fromError(e: anyerror) ?Code {
        return switch (e) {
            error.UnknownCommand => .unknown_command,
            error.BadSyntax => .bad_syntax,
            error.BadValue => .bad_value,
            error.UnknownType => .unknown_type,
            error.UnknownStyleWord => .unknown_style_word,
            error.TypeIsFixed => .type_is_fixed,
            error.NotFound => .not_found,
            error.InUse => .in_use,
            error.Disabled => .disabled,
            error.PermissionDenied => .permission_denied,
            error.Unsupported => .unsupported,
            error.TooLarge => .too_large,
            error.NoBatch => .no_batch,
            error.Gone => .gone,
            error.AppGone => .app_gone,
            else => null,
        };
    }
};

/// One Zig error per `Code`.
pub const ProtoError = error{
    UnknownCommand,
    BadSyntax,
    BadValue,
    UnknownType,
    UnknownStyleWord,
    TypeIsFixed,
    NotFound,
    InUse,
    Disabled,
    PermissionDenied,
    Unsupported,
    TooLarge,
    NoBatch,
    Gone,
    AppGone,
};

/// What every parser in proto can return.
pub const Error = ProtoError || error{OutOfMemory};

/// Writes `phrase` or `phrase: detail`, the text of a 9P error.
pub fn format(w: *std.Io.Writer, code: Code, detail: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(code.phrase());
    if (detail.len > 0) {
        try w.writeAll(": ");
        try w.writeAll(detail);
    }
}

/// A code and its detail: what a parser reports, or a 9P error string
/// read back.
pub const Diag = struct {
    code: Code = .bad_syntax,
    detail: []const u8 = "",

    /// Reads `phrase[: detail]` back; null if it starts with no phrase.
    pub fn parse(s: []const u8) ?Diag {
        if (std.mem.indexOf(u8, s, ": ")) |i| {
            if (Code.fromPhrase(s[0..i])) |c| return .{ .code = c, .detail = s[i + 2 ..] };
        }
        const c = Code.fromPhrase(s) orelse return null;
        return .{ .code = c };
    }

    pub fn format(self: Diag, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return @import("err.zig").format(w, self.code, self.detail);
    }
};

/// Records `code` and a formatted detail in `d`, if given, and returns the
/// code's error. The detail lives in `arena`.
pub fn fail(d: ?*Diag, arena: std.mem.Allocator, code: Code, comptime fmt: []const u8, args: anytype) ProtoError {
    if (d) |x| {
        x.code = code;
        x.detail = std.fmt.allocPrint(arena, fmt, args) catch "";
    }
    return code.err();
}

/// Prefixes the detail in `d` with `line N` (1-based), for errors in
/// multi-line input.
pub fn atLine(d: ?*Diag, arena: std.mem.Allocator, n: usize) void {
    const x = d orelse return;
    x.detail = if (x.detail.len == 0)
        std.fmt.allocPrint(arena, "line {d}", .{n}) catch x.detail
    else
        std.fmt.allocPrint(arena, "line {d}: {s}", .{ n, x.detail }) catch x.detail;
}

/// The text limits of core.md § Limits (the minimums a host accepts).
pub const limits = struct {
    /// One `ctl` write.
    pub const ctl_write: usize = 64 * 1024;
    /// A text property.
    pub const text_prop: usize = 1024 * 1024;
    /// A data file (`items`, `rows`, `ops`).
    pub const data_file: usize = 16 * 1024 * 1024;
    /// Queued action events per subscription.
    pub const action_queue: usize = 4096;
    /// Node depth.
    pub const node_depth: usize = 64;
};

const t = std.testing;

test "phrases and names" {
    const table = [_]struct { Code, []const u8, []const u8 }{
        .{ .unknown_command, "unknown command", "unknown-command" },
        .{ .bad_syntax, "bad syntax", "bad-syntax" },
        .{ .bad_value, "bad value", "bad-value" },
        .{ .unknown_type, "unknown type", "unknown-type" },
        .{ .unknown_style_word, "unknown style word", "unknown-style-word" },
        .{ .type_is_fixed, "type is fixed", "type-is-fixed" },
        .{ .not_found, "not found", "not-found" },
        .{ .in_use, "in use", "in-use" },
        .{ .disabled, "disabled", "disabled" },
        .{ .permission_denied, "permission denied", "permission-denied" },
        .{ .unsupported, "unsupported", "unsupported" },
        .{ .too_large, "too large", "too-large" },
        .{ .no_batch, "no batch", "no-batch" },
        .{ .gone, "gone", "gone" },
        .{ .app_gone, "app gone", "app-gone" },
    };
    try t.expectEqual(std.meta.fields(Code).len, table.len);
    for (table) |row| {
        try t.expectEqualStrings(row[1], row[0].phrase());
        try t.expectEqualStrings(row[2], row[0].name());
        try t.expectEqual(row[0], Code.fromPhrase(row[1]).?);
        try t.expectEqual(row[0], Code.fromName(row[2]).?);
        try t.expectEqual(row[0], Code.fromError(row[0].err()).?);
    }
    try t.expect(Code.fromPhrase("short read") == null);
    try t.expect(Code.fromError(error.OutOfMemory) == null);
}

test "format and parse back" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format(&w, .unknown_style_word, "flexx");
    try t.expectEqualStrings("unknown style word: flexx", w.buffered());
    const d = Diag.parse(w.buffered()).?;
    try t.expectEqual(Code.unknown_style_word, d.code);
    try t.expectEqualStrings("flexx", d.detail);

    w = .fixed(&buf);
    try format(&w, .no_batch, "");
    try t.expectEqualStrings("no batch", w.buffered());
    try t.expectEqual(Code.no_batch, Diag.parse("no batch").?.code);
    try t.expectEqualStrings("in use: ambiguous: total (a/total, b/total)", blk: {
        w = .fixed(&buf);
        const x = Diag.parse("in use: ambiguous: total (a/total, b/total)").?;
        try w.print("{f}", .{x});
        break :blk w.buffered();
    });
    try t.expect(Diag.parse("nonsense: x") == null);
}

test "fail and atLine" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    const e = fail(&d, arena.allocator(), .bad_value, "seq={s}", .{"x"});
    try t.expectEqual(error.BadValue, e);
    atLine(&d, arena.allocator(), 3);
    try t.expectEqualStrings("line 3: seq=x", d.detail);
    try t.expectEqual(error.BadValue, fail(null, arena.allocator(), .bad_value, "ignored", .{}));
}
