//! types: the component catalog as data (protocols/components.md § The
//! descriptor). Interface I3 in ARCHITECTURE.md.
//!
//! Owner: workstream W1 (types). Parses `types/NAME/spec` descriptor text
//! into a Catalog the tree validates `new`, `set`, verbs and events
//! against, and serves at `$ui/types`. Also parses `style-words` and
//! `theme-tokens`. Knows nothing about any renderer.
//!
//! Everything a Catalog returns (types, names, spec text) lives in the
//! Catalog's own arena and is valid until `deinit`. A Catalog is immutable
//! after it is built, so any thread may read it without locking.
//!
//! Errors are the protocol's phrases (core.md § Errors) as a Zig error set,
//! `Error`, with the detail text in an optional `Diag`. They map one to one
//! onto `proto.err.Code` (W2) by name: `BadValue` is `bad-value`.

const std = @import("std");

pub const descriptor = @import("descriptor.zig");
pub const style = @import("style.zig");
pub const embedded = @import("embedded.zig");

test {
    _ = @import("tests.zig");
}

const Catalog_ = @import("catalog.zig");
pub const Catalog = Catalog_.Catalog;
pub const ThemePick = Catalog_.ThemePick;

// ---------------------------------------------------------------- errors

/// The protocol errors a catalog check can return. Names match
/// `proto.err.Code` (core.md § Errors): `BadValue` is `bad value`.
pub const Error = error{
    /// A value of the wrong form, a bare word the type doesn't take, a
    /// write to a readonly prop (`bad value: read-only`).
    BadValue,
    /// A type not in the catalog, or a child its parent can't hold.
    UnknownType,
    /// A style word not in `style-words`, or not valid on this type.
    UnknownStyleWord,
    /// A prop, verb, slot or event the type doesn't have.
    NotFound,
    /// A value over the size limit for its form.
    TooLarge,
    /// A style word or descriptor line that doesn't parse.
    BadSyntax,
    OutOfMemory,
};

/// Where a check writes its detail, the text after `PHRASE: `. Optional:
/// pass `null` when the caller only wants the code.
pub const Diag = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn detail(d: *const Diag) []const u8 {
        return d.buf[0..d.len];
    }

    /// Sets the detail, truncating to the buffer.
    pub fn set(d: ?*Diag, comptime fmt: []const u8, args: anytype) void {
        const self = d orelse return;
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            break :blk self.buf[0..];
        };
        self.len = s.len;
    }
};

// ---------------------------------------------------------------- the model

pub const Tier = enum { element, component, overlay };

/// A prop's value form (components.md § Prop forms).
pub const Form = union(enum) {
    /// Any text, raw in its file.
    text,
    /// One token.
    word,
    /// `on` or `off` (empty clears).
    bool,
    /// Decimal; a list of them separated by blanks or `,` (`20 80`).
    number,
    /// One of the listed words (empty clears).
    choice: []const []const u8,
    /// A node path in the same window.
    path,
    /// The name of one of the node's children.
    child,
    /// A data file; its format is the type's `file` line of the same name.
    data,
    /// Binary, or raw text the type doesn't parse.
    bytes,
};

pub const Prop = struct {
    name: []const u8,
    form: Form,
    default: ?[]const u8 = null,
    /// Also a file under the node (`file` on the prop line).
    file: bool = false,
    /// Only the host writes it.
    readonly: bool = false,
    /// Bounds on a `number` prop (`min=0 max=100`), checked for every
    /// number in the value.
    min: ?f64 = null,
    max: ?f64 = null,
};

pub const WordKind = enum { flag, variant, size };

/// A bare word the type takes in `new` lines and documents.
pub const Word = struct {
    name: []const u8,
    kind: WordKind,
};

/// The right a verb needs (policy.md § Rights).
pub const Class = enum { activate, edit, keys, author };

pub const Verb = struct {
    name: []const u8,
    /// The argument synopsis as the descriptor writes it (`ID x,y`), or "".
    args: []const u8 = "",
    class: ?Class = null,
};

pub const EventKind = enum { state, action, request };

pub const Event = struct {
    name: []const u8,
    kind: EventKind,
    /// The attributes it carries (`attrs=a,b`).
    attrs: []const []const u8 = &.{},
};

pub const Slot = struct {
    name: []const u8,
    /// Types it accepts; empty means any.
    accepts: []const []const u8 = &.{},
};

/// What unnamed children may be (the `child` line).
pub const ChildRule = union(enum) {
    any,
    none,
    types: []const []const u8,
};

/// A data file and its line format (the `file` line).
pub const DataFile = struct {
    name: []const u8,
    format: []const u8,
};

pub const Type = struct {
    name: []const u8,
    tier: Tier,
    /// The profile that defines it; null for a host extra.
    profile: ?[]const u8 = null,
    since: []const u8 = "1.0",
    props: []const Prop = &.{},
    words: []const Word = &.{},
    verbs: []const Verb = &.{},
    events: []const Event = &.{},
    slots: []const Slot = &.{},
    child: ChildRule = .none,
    files: []const DataFile = &.{},
    /// The descriptor text it was parsed from: what `types/NAME/spec` serves.
    spec: []const u8 = "",

    pub fn prop(t: *const Type, name: []const u8) ?*const Prop {
        for (t.props) |*p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
    pub fn word(t: *const Type, name: []const u8) ?Word {
        for (t.words) |w| if (std.mem.eql(u8, w.name, name)) return w;
        return null;
    }
    pub fn verb(t: *const Type, name: []const u8) ?*const Verb {
        for (t.verbs) |*v| if (std.mem.eql(u8, v.name, name)) return v;
        return null;
    }
    pub fn event(t: *const Type, name: []const u8) ?*const Event {
        for (t.events) |*e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
    pub fn slot(t: *const Type, name: []const u8) ?*const Slot {
        for (t.slots) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }
    pub fn file(t: *const Type, name: []const u8) ?*const DataFile {
        for (t.files) |*f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }
    /// The format of the data file behind a `data` prop or a `file` line.
    pub fn format(t: *const Type, name: []const u8) ?[]const u8 {
        return if (t.file(name)) |f| f.format else null;
    }
    /// Whether the type takes variant (or size) words at all.
    pub fn hasWordKind(t: *const Type, kind: WordKind) bool {
        for (t.words) |w| if (w.kind == kind) return true;
        return false;
    }
    /// `NAME major.minor`, what `types/NAME/version` serves.
    pub fn version(t: *const Type, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s} {s}\n", .{ t.name, t.since }) catch t.name;
    }
};

/// The events any element sends when its `on` file lists them (core.md
/// § Making an element send events). Not in descriptors: every node takes
/// them.
pub const element_events = [_][]const u8{
    "click", "hover", "mouse-down", "mouse-up", "move", "scroll", "key", "focus", "blur", "drop", "drag",
};

/// The profiles of components.md § Profiles and the types in each.
pub const profiles = [_]struct { name: []const u8, types: []const []const u8 }{
    .{ .name = "core", .types = &.{ "div", "text", "styled-text", "img", "svg", "icon", "scroll", "spacer" } },
    .{ .name = "canvas", .types = &.{"canvas"} },
    .{ .name = "form", .types = &.{ "button", "checkbox", "radio-group", "switch", "select", "input", "textarea", "number-input", "slider", "form", "field" } },
    .{ .name = "data", .types = &.{ "list", "table", "tree", "description-list" } },
    .{ .name = "overlay", .types = &.{ "dialog", "alert-dialog", "sheet", "popover", "tooltip", "context-menu" } },
    .{ .name = "nav", .types = &.{ "tabs", "tab", "sidebar", "sidebar-group", "sidebar-item", "breadcrumb", "toolbar", "link" } },
    .{ .name = "layout", .types = &.{ "grid", "resizable", "panel", "separator", "group-box", "accordion", "accordion-item", "collapsible" } },
    .{ .name = "feedback", .types = &.{ "progress", "spinner", "badge", "alert", "empty", "kbd", "tag" } },
    .{ .name = "desktop", .types = &.{ "icon-view", "console", "file-chooser" } },
    .{ .name = "web", .types = &.{"web"} },
};

test {
    std.testing.refAllDecls(@This());
}
