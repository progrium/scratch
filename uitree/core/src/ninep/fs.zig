//! fs: what the 9P server needs from whatever owns `$ui`, as one vtable.
//!
//! The server (server.zig) owns the wire: fids, tags, flush, threads,
//! buffering writes until close, splitting stream reads. Everything about
//! what a path *is* goes through `Fs`: the tree (W3) implements it over a
//! published `Snapshot`, the `OpQueue` and `Bus` (ARCHITECTURE.md I4);
//! `Mux` (mux.zig) puts `/debug` in front of it; tests use `MemFs`.
//!
//! Paths are the elements below `$ui` joined with `/`, with no leading
//! slash: `""` is `$ui` itself, `win/main/ctl` a window's `ctl`. They are
//! what `trace` and the loud error lines print. A path handed to `Fs` has
//! been walked element by element, so `.` and `..` never appear in it.
//!
//! Every call may run on any 9P thread, several at once. Calls that change
//! the tree (`commit`, `create`, `remove`, `line`) block until the owner
//! thread has applied them, and report the protocol's error text in
//! `Err`. Reads come from one consistent state (a snapshot) per call.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    dir,
    /// A file read whole at open and written whole at close: props, `ctl`,
    /// `type`, `version`.
    file,
    /// A file whose reads block for more: `events`, `trace`.
    stream,
};

/// When writes to an open file take effect.
pub const WriteMode = enum {
    /// Buffered and handed to `commit` when the fid is clunked (core.md §
    /// Commands: "a `ctl` written in several 9P writes applies when the
    /// file is closed").
    at_close,
    /// Each complete line is handed to `line` as it arrives; a write may
    /// end mid-line (`/debug/inject`).
    lines,
};

pub const Entry = struct {
    kind: Kind,
    /// Stable for the life of what it names; a new node at an old path gets
    /// a new one. Directories and files of one node must differ.
    qid: u64,
    /// Bumped when the contents change, if known.
    vers: u32 = 0,
    /// Permission bits (0o444, 0o666, 0o222, 0o777...), without DMDIR.
    perm: u32 = 0o666,
    /// Read length for stat; 0 is fine for generated files.
    length: u64 = 0,
};

/// A directory entry for `list`.
pub const DirEnt = struct {
    name: []const u8,
    entry: Entry,
};

/// The text of a failed call: a core.md phrase, optionally `: detail`
/// (`not found: x`). Filled by the `Fs`, sent as the Rerror.
pub const Err = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn text(e: *const Err) []const u8 {
        return e.buf[0..e.len];
    }

    /// Sets the text and returns `error.Failed`: `return err.set("...")`.
    pub fn set(e: *Err, s: []const u8) error{Failed} {
        e.note(s);
        return error.Failed;
    }

    /// Sets the text.
    pub fn note(e: *Err, s: []const u8) void {
        const n = @min(s.len, e.buf.len);
        @memcpy(e.buf[0..n], s[0..n]);
        e.len = n;
    }

    pub fn print(e: *Err, comptime fmt: []const u8, args: anytype) error{Failed} {
        e.len = if (std.fmt.bufPrint(&e.buf, fmt, args)) |s| s.len else |_| e.buf.len;
        return error.Failed;
    }
};

pub const Error = error{ Failed, OutOfMemory };

/// One 9P connection, as `Fs` sees it. Batches and request opt-ins belong
/// to a connection (core.md § Batches, § Requests).
pub const ConnId = u64;

/// How a file was opened.
pub const OpenMode = struct {
    read: bool,
    write: bool,
    trunc: bool = false,
};

/// What `open` returns for a file.
pub const Opened = struct {
    /// For a `stream`: where reads come from. Null for a `file`, whose
    /// contents come from `read`.
    stream: ?Stream = null,
    write_mode: WriteMode = .at_close,
};

/// A blocking source of bytes: an `events` subscription, `trace`.
pub const Stream = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        /// Copies up to `buf.len` bytes into `buf`, blocking until there
        /// is at least one. Returns 0 at end of file (`gone`, the app
        /// quit). Whole lines when they fit; a longer line comes back
        /// over several reads. Returns `error.Interrupted` once `interrupt`
        /// has been called for this read.
        read: *const fn (ptr: *anyopaque, buf: []u8) error{Interrupted}!usize,
        /// Any thread: makes a blocked `read` (or the next one) return
        /// `error.Interrupted`. Used by Tflush.
        interrupt: *const fn (ptr: *anyopaque) void,
        /// Ends the subscription. Called once, with no read in progress.
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn read(s: Stream, buf: []u8) error{Interrupted}!usize {
        return s.vt.read(s.ptr, buf);
    }
    pub fn interrupt(s: Stream) void {
        s.vt.interrupt(s.ptr);
    }
    pub fn close(s: Stream) void {
        s.vt.close(s.ptr);
    }
};

pub const Fs = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        /// A new connection was attached.
        connect: *const fn (ptr: *anyopaque) ConnId,
        /// The connection ended: abort its batch, drop its requests.
        disconnect: *const fn (ptr: *anyopaque, conn: ConnId) void,
        /// What `path` names, or null. Walks call it once per element.
        stat: *const fn (ptr: *anyopaque, conn: ConnId, path: []const u8) ?Entry,
        /// A directory's entries, from one consistent state. Names live in
        /// `arena`.
        list: *const fn (ptr: *anyopaque, conn: ConnId, path: []const u8, arena: Allocator, err: *Err) Error![]const DirEnt,
        /// Checks that `path` can be opened this way and sets up what the
        /// open needs (a subscription for a stream).
        open: *const fn (ptr: *anyopaque, conn: ConnId, path: []const u8, mode: OpenMode, err: *Err) Error!Opened,
        /// A file's contents as of now, read once at open for a readable
        /// `file`. Lives in `arena`.
        read: *const fn (ptr: *anyopaque, conn: ConnId, path: []const u8, arena: Allocator, err: *Err) Error![]const u8,
        /// The bytes written to an `at_close` file, at clunk. Blocks until
        /// applied (or refused). Called even when nothing was written if
        /// the file was opened with `trunc` (`echo -n >file`).
        commit: *const fn (ptr: *anyopaque, conn: ConnId, path: []const u8, data: []const u8, err: *Err) Error!void,
        /// One complete line (without its newline) written to a `lines`
        /// file. Blocks until applied.
        line: *const fn (ptr: *anyopaque, conn: ConnId, path: []const u8, line: []const u8, err: *Err) Error!void,
        /// Tcreate: `mkdir` a node (dir) or create a file in `dir`.
        create: *const fn (ptr: *anyopaque, conn: ConnId, dir: []const u8, name: []const u8, is_dir: bool, err: *Err) Error!Entry,
        /// Tremove.
        remove: *const fn (ptr: *anyopaque, conn: ConnId, path: []const u8, err: *Err) Error!void,
    };

    pub fn connect(f: Fs) ConnId {
        return f.vt.connect(f.ptr);
    }
    pub fn disconnect(f: Fs, c: ConnId) void {
        f.vt.disconnect(f.ptr, c);
    }
    pub fn stat(f: Fs, c: ConnId, path: []const u8) ?Entry {
        return f.vt.stat(f.ptr, c, path);
    }
    pub fn list(f: Fs, c: ConnId, path: []const u8, arena: Allocator, err: *Err) Error![]const DirEnt {
        return f.vt.list(f.ptr, c, path, arena, err);
    }
    pub fn open(f: Fs, c: ConnId, path: []const u8, mode: OpenMode, err: *Err) Error!Opened {
        return f.vt.open(f.ptr, c, path, mode, err);
    }
    pub fn read(f: Fs, c: ConnId, path: []const u8, arena: Allocator, err: *Err) Error![]const u8 {
        return f.vt.read(f.ptr, c, path, arena, err);
    }
    pub fn commit(f: Fs, c: ConnId, path: []const u8, data: []const u8, err: *Err) Error!void {
        return f.vt.commit(f.ptr, c, path, data, err);
    }
    pub fn line(f: Fs, c: ConnId, path: []const u8, l: []const u8, err: *Err) Error!void {
        return f.vt.line(f.ptr, c, path, l, err);
    }
    pub fn create(f: Fs, c: ConnId, dir: []const u8, name: []const u8, is_dir: bool, err: *Err) Error!Entry {
        return f.vt.create(f.ptr, c, dir, name, is_dir, err);
    }
    pub fn remove(f: Fs, c: ConnId, path: []const u8, err: *Err) Error!void {
        return f.vt.remove(f.ptr, c, path, err);
    }
};

/// A stable qid path for a path string, for an `Fs` with no handles of its
/// own (the spike, MemFs, `/debug`). A tree with node handles should use
/// `(handle << 16) | file index` instead, so a recreated node differs.
pub fn qidOf(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0x75697472, path);
}

/// The last element of a path, `/` for the root.
pub fn baseName(path: []const u8) []const u8 {
    if (path.len == 0) return "/";
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

/// `dir/name`, or `name` when dir is the root.
pub fn join(a: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

test "baseName and join" {
    try std.testing.expectEqualStrings("/", baseName(""));
    try std.testing.expectEqualStrings("ctl", baseName("ctl"));
    try std.testing.expectEqualStrings("text", baseName("win/main/a/text"));
    const j = try join(std.testing.allocator, "", "win");
    defer std.testing.allocator.free(j);
    try std.testing.expectEqualStrings("win", j);
}
