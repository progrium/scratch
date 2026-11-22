//! Table-driven tests: every row of DESIGN § Errors and limits, the event
//! ordering rule, batches, requests, documents and snapshots. The registry
//! here is a small stand-in catalog, so these tests don't depend on what the
//! W5b/W6/W7 catalog modules hold.

use std::time::{Duration, Instant};

use catalog::{
    EventKind, EventSpec, LineFormat, PropKind, PropSpec, Slots, Tier, TypeSpec, VerbSpec,
};
use proto::ErrorKind;

use crate::*;

const fn p(name: &'static str, kind: PropKind) -> PropSpec {
    PropSpec {
        name,
        kind,
        default: None,
    }
}
const fn ev(name: &'static str, kind: EventKind) -> EventSpec {
    EventSpec { name, kind }
}
const fn spec(name: &'static str, props: &'static [PropSpec]) -> TypeSpec {
    TypeSpec {
        name,
        tier: Tier::Element,
        props,
        verbs: &[],
        events: &[],
        slots: Slots::Any,
        variants: &[],
        sizable: false,
    }
}

static DIV: TypeSpec = spec("div", &[]);
static TEXT: TypeSpec = TypeSpec {
    slots: Slots::None,
    ..spec(
        "text",
        &[p("text", PropKind::Text), p("flags", PropKind::Word)],
    )
};
static BUTTON: TypeSpec = TypeSpec {
    tier: Tier::Component,
    variants: &["primary", "ghost", "danger"],
    sizable: true,
    events: &[ev("click", EventKind::Action)],
    ..spec(
        "button",
        &[
            p("label", PropKind::Text),
            p("icon", PropKind::Word),
            p("disabled", PropKind::Bool),
        ],
    )
};
static INPUT: TypeSpec = TypeSpec {
    tier: Tier::Component,
    slots: Slots::Named(&["prefix", "suffix"]),
    events: &[
        ev("change", EventKind::State),
        ev("submit", EventKind::Action),
        ev("focus", EventKind::State),
    ],
    ..spec(
        "input",
        &[
            p("value", PropKind::Text),
            p("placeholder", PropKind::Text),
            p("flags", PropKind::Text),
        ],
    )
};
static CHECKBOX: TypeSpec = TypeSpec {
    tier: Tier::Component,
    events: &[ev("change", EventKind::State)],
    ..spec(
        "checkbox",
        &[
            p("label", PropKind::Text),
            PropSpec {
                name: "value",
                kind: PropKind::Enum(&["on", "off", "mixed"]),
                default: Some("off"),
            },
        ],
    )
};
static SLIDER: TypeSpec = TypeSpec {
    tier: Tier::Component,
    ..spec("slider", &[p("value", PropKind::Number)])
};
static SELECT: TypeSpec = TypeSpec {
    tier: Tier::Component,
    ..spec(
        "select",
        &[
            p("items", PropKind::Data(LineFormat::Items)),
            p("value", PropKind::Word),
        ],
    )
};
static TABLE: TypeSpec = TypeSpec {
    tier: Tier::Component,
    ..spec(
        "table",
        &[
            p("columns", PropKind::Data(LineFormat::Columns)),
            p("rows", PropKind::Data(LineFormat::Rows)),
            p("selected", PropKind::ReadOnly),
        ],
    )
};
static EDITOR: TypeSpec = TypeSpec {
    tier: Tier::Component,
    verbs: &[VerbSpec {
        name: "save",
        usage: "save",
    }],
    ..spec("editor", &[p("value", PropKind::Bytes)])
};
static FORM: TypeSpec = TypeSpec {
    slots: Slots::ChildTypes(&["field"]),
    ..spec("form", &[])
};
static FIELD: TypeSpec = spec("field", &[p("label", PropKind::Text)]);
static ALERT: TypeSpec = TypeSpec {
    tier: Tier::Overlay,
    ..spec(
        "alert-dialog",
        &[p("title", PropKind::Text), p("confirm", PropKind::Text)],
    )
};

fn reg() -> Registry {
    let mut r = Registry::new();
    for s in [
        &DIV, &TEXT, &BUTTON, &INPUT, &CHECKBOX, &SLIDER, &SELECT, &TABLE, &EDITOR, &FORM, &FIELD,
        &ALERT,
    ] {
        r.insert(s);
    }
    r
}

const S: SessionId = SessionId(1);
const S2: SessionId = SessionId(2);
const W: &str = "windows/main";
const R: &str = "windows/main/root";

fn write(t: &mut Tree, path: &str, data: &str) -> Result<Changes, proto::Error> {
    t.apply(
        S,
        Op::Write {
            path: FsPath::new(path),
            data: Bytes::copy_from_slice(data.as_bytes()),
        },
    )
}
fn write_as(t: &mut Tree, s: SessionId, path: &str, data: &str) -> Result<Changes, proto::Error> {
    t.apply(
        s,
        Op::Write {
            path: FsPath::new(path),
            data: Bytes::copy_from_slice(data.as_bytes()),
        },
    )
}
fn ok(t: &mut Tree, path: &str, data: &str) -> Changes {
    write(t, path, data).unwrap_or_else(|e| panic!("write {path} {data:?}: {e}"))
}
fn read(t: &Tree, path: &str) -> String {
    let b = t
        .snapshot()
        .read(&FsPath::new(path))
        .unwrap_or_else(|| panic!("read {path}: none"));
    String::from_utf8(b.to_vec()).unwrap()
}
fn kind(r: Result<Changes, proto::Error>) -> ErrorKind {
    match r {
        Ok(_) => panic!("expected an error"),
        Err(e) => e.kind,
    }
}
/// A tree with window `main`.
fn app() -> Tree {
    let mut t = Tree::new(reg());
    ok(&mut t, "ctl", "window main title=Test size=400,300");
    t
}
fn sub(t: &Tree, events: &str) -> Subscription {
    let mut s = t.bus().subscribe(&FsPath::new(events)).unwrap();
    let first = drain(&mut s);
    assert!(first.starts_with("resync seq="), "{first}");
    s
}
/// Everything queued, as text.
fn drain(s: &mut Subscription) -> String {
    match s.try_read(1 << 20) {
        Some(Ok(b)) => String::from_utf8(b.to_vec()).unwrap(),
        Some(Err(SubEnd::Eof)) => "<eof>".into(),
        Some(Err(SubEnd::ShortRead)) => "<short>".into(),
        None => String::new(),
    }
}
fn names(lines: &str) -> Vec<String> {
    lines
        .lines()
        .map(|l| l.split(' ').next().unwrap().to_string())
        .collect()
}
fn user(kind: EventKind, name: &str, node: &str) -> EventMsg {
    EventMsg::new(kind, name).win("main").node(node)
}

// ---- DESIGN § Errors and limits, one row each ----------------------------

#[test]
fn error_table() {
    type Case = (
        &'static str,
        &'static [(&'static str, &'static str)],
        ErrorKind,
    );
    let big = format!("new div x tag={}", "a".repeat(70 << 10));
    let cases: &[Case] = &[
        ("unknown command", &[(R, "frob")], ErrorKind::UnknownCommand),
        (
            "unknown root command",
            &[("", "frob")],
            ErrorKind::UnknownCommand,
        ),
        (
            "unknown window command",
            &[(W, "frob")],
            ErrorKind::UnknownCommand,
        ),
        ("bad quoting", &[(R, "new div 'x")], ErrorKind::BadSyntax),
        ("new without name", &[(R, "new div")], ErrorKind::BadSyntax),
        (
            "unknown style word",
            &[(R, "new div x style=flexx")],
            ErrorKind::UnknownStyleWord,
        ),
        (
            "variant on a div",
            &[(R, "new div x style=primary")],
            ErrorKind::UnknownStyleWord,
        ),
        (
            "size word on a div",
            &[(R, "new div x style=sm")],
            ErrorKind::UnknownStyleWord,
        ),
        (
            "unknown type",
            &[(R, "new widget x")],
            ErrorKind::UnknownType,
        ),
        (
            "in use",
            &[(R, "new div x"), (R, "new div x")],
            ErrorKind::InUse,
        ),
        ("window in use", &[("", "window main")], ErrorKind::InUse),
        (
            "not found: delete",
            &[(R, "delete nope")],
            ErrorKind::NotFound,
        ),
        (
            "not found: answer",
            &[(R, "close seq=99")],
            ErrorKind::NotFound,
        ),
        (
            "bad value: length",
            &[(R, "new div x style=w=wide")],
            ErrorKind::BadValue,
        ),
        (
            "bad value: number",
            &[(R, "new slider s value=abc")],
            ErrorKind::BadValue,
        ),
        (
            "bad value: enum",
            &[(R, "new checkbox c value=maybe")],
            ErrorKind::BadValue,
        ),
        (
            "bad value: on word",
            &[(R, "new div x on=wiggle")],
            ErrorKind::BadValue,
        ),
        (
            "bad value: window size",
            &[("", "window w2 size=big")],
            ErrorKind::BadValue,
        ),
        (
            "not found: window option",
            &[("", "window w2 colour=red")],
            ErrorKind::NotFound,
        ),
        (
            "not found: prop",
            &[(R, "new button b colour=red")],
            ErrorKind::NotFound,
        ),
        ("no batch: commit", &[(W, "commit")], ErrorKind::NoBatch),
        ("no batch: abort", &[("", "abort")], ErrorKind::NoBatch),
    ];
    for (what, writes, want) in cases {
        let mut t = app();
        let (last, setup) = writes.split_last().unwrap();
        for (dir, cmd) in setup {
            ok(&mut t, &ctl(dir), cmd);
        }
        let got = kind(write(&mut t, &ctl(last.0), last.1));
        assert_eq!(got, *want, "{what}");
    }
    // too large: one ctl write over 64 KiB
    let mut t = app();
    assert_eq!(kind(write(&mut t, &ctl(R), &big)), ErrorKind::TooLarge);
    // type is fixed
    let mut t = app();
    t.apply(
        S,
        Op::Mkdir {
            path: FsPath::new(format!("{R}/b")),
        },
    )
    .unwrap();
    ok(&mut t, &format!("{R}/b/type"), "button");
    t.frame_drawn("main");
    assert_eq!(
        kind(write(&mut t, &format!("{R}/b/type"), "text")),
        ErrorKind::TypeIsFixed
    );
    ok(&mut t, &format!("{R}/b/type"), "button\n"); // same type: fine
    // not found: a path
    assert_eq!(
        kind(write(&mut t, "windows/nope/ctl", "center")),
        ErrorKind::NotFound
    );
    assert_eq!(
        kind(write(&mut t, &format!("{R}/zzz/style"), "flex")),
        ErrorKind::NotFound
    );
    assert_eq!(
        kind(write(&mut t, &format!("{R}/b/nofile"), "x")),
        ErrorKind::NotFound
    );
    // short read
    let mut s = t.bus().subscribe(&FsPath::new("events")).unwrap();
    assert_eq!(s.try_read(4), Some(Err(SubEnd::ShortRead)));
    assert!(s.try_read(8192).unwrap().is_ok());
    // app gone
    t.app_gone();
    assert_eq!(s.try_read(8192), Some(Err(SubEnd::Eof)));
    assert_eq!(
        kind(write(&mut t, &ctl(R), "new div y")),
        ErrorKind::AppGone
    );
    assert_eq!(
        t.bus().subscribe(&FsPath::new("events")).unwrap_err().kind,
        ErrorKind::AppGone
    );
}

fn ctl(dir: &str) -> String {
    if dir.is_empty() {
        "ctl".into()
    } else {
        format!("{dir}/ctl")
    }
}

#[test]
fn error_display_has_phrase_and_detail() {
    let mut t = app();
    let e = write(&mut t, &ctl(R), "new div x style=flexx").unwrap_err();
    assert_eq!(e.to_string(), "unknown style word: flexx");
}

#[test]
fn ctl_write_is_all_or_nothing() {
    let mut t = app();
    let r = write(&mut t, &ctl(R), "new div a\nnew div b\nnew widget c");
    assert_eq!(kind(r), ErrorKind::UnknownType);
    assert!(t.node(&format!("{R}/a")).is_none());
    assert_eq!(read(&t, &format!("{R}/order")), "");
    // A failing prop inside `new` leaves nothing either.
    assert!(write(&mut t, &ctl(R), "new button b label=Hi style=flexx").is_err());
    assert!(t.node(&format!("{R}/b")).is_none());
    assert_eq!(
        read(&t, "trace"),
        "ctl path=ctl cmd='window main title=Test size=400,300'\n"
    );
}

#[test]
fn limits() {
    let mut t = app();
    // node depth 64
    let mut p = R.to_string();
    for i in 1..64 {
        ok(&mut t, &ctl(&p), &format!("new div d{i}"));
        p = format!("{p}/d{i}");
    }
    assert_eq!(
        kind(write(&mut t, &ctl(&p), "new div deep")),
        ErrorKind::TooLarge
    );
    // text property 16 MiB
    ok(&mut t, &ctl(R), "new text big");
    let huge = "x".repeat((16 << 20) + 1);
    assert_eq!(
        kind(write(&mut t, &format!("{R}/big/text"), &huge)),
        ErrorKind::TooLarge
    );
}

// ---- node files ------------------------------------------------------------

#[test]
fn creating_nodes_three_ways() {
    let mut t = app();
    // mkdir makes a div and appends it to order
    let ch = t
        .apply(
            S,
            Op::Mkdir {
                path: FsPath::new(format!("{R}/save")),
            },
        )
        .unwrap();
    assert_eq!(ch.created, vec![format!("{R}/save")]);
    assert_eq!(ch.dirty_windows, vec!["main".to_string()]);
    assert_eq!(read(&t, &format!("{R}/save/type")), "div");
    ok(&mut t, &format!("{R}/save/type"), "button\n");
    ok(&mut t, &format!("{R}/save/label"), "Save\n");
    // new
    ok(
        &mut t,
        &ctl(R),
        "new text title text='Hello there' style='text_xl font_semibold'",
    );
    // tree document
    ok(
        &mut t,
        &format!("{R}/tree"),
        "div root\n  button save  label=Save\n  text title  style='text_xl font_semibold'  text='Hello there'\n",
    );
    assert_eq!(read(&t, &format!("{R}/order")), "save title");
    assert_eq!(read(&t, &format!("{R}/save/label")), "Save");
    assert_eq!(read(&t, &format!("{R}/title/text")), "Hello there");
}

#[test]
fn text_files_drop_one_newline_bytes_keep_it() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new text t\nnew editor e");
    ok(&mut t, &format!("{R}/t/text"), "Hello\n");
    assert_eq!(read(&t, &format!("{R}/t/text")), "Hello");
    ok(&mut t, &format!("{R}/t/text"), "two\n\n");
    assert_eq!(read(&t, &format!("{R}/t/text")), "two\n");
    ok(&mut t, &format!("{R}/e/value"), "fn main() {}\n");
    assert_eq!(read(&t, &format!("{R}/e/value")), "fn main() {}\n");
}

#[test]
fn node_files_and_computed_reads() {
    let mut t = app();
    ok(
        &mut t,
        &ctl(R),
        "new button ok label=OK tag=save style='primary sm'",
    );
    let b = format!("{R}/ok");
    assert_eq!(read(&t, &format!("{b}/id")), "root/ok");
    assert_eq!(read(&t, &format!("{b}/tag")), "save");
    assert_eq!(read(&t, &format!("{b}/style")), "primary sm");
    assert_eq!(read(&t, &format!("{b}/bounds")), "0 0 0 0");
    t.report_bounds(&b, [10.0, 20.0, 80.5, 32.0]);
    assert_eq!(read(&t, &format!("{b}/bounds")), "10 20 80.5 32");
    assert_eq!(read(&t, &format!("{b}/disabled")), "");
    assert!(read(&t, "version").starts_with("gpuifs 0.1\n"));
    assert!(read(&t, &ctl(R)).contains("new type name"));
    assert!(read(&t, &ctl(W)).contains("notify text"));
    assert_eq!(read(&t, &format!("{W}/title")), "Test");
    assert_eq!(read(&t, &format!("{W}/state")), "normal");
    let snap = t.snapshot();
    let ls: Vec<String> = snap
        .readdir(&FsPath::new(&b))
        .unwrap()
        .into_iter()
        .map(|s| s.name)
        .collect();
    for f in [
        "type", "style", "order", "tag", "ctl", "events", "bounds", "id", "tree", "on", "label",
        "icon",
    ] {
        assert!(ls.contains(&f.to_string()), "{f} in {ls:?}");
    }
    let st = snap.stat(&FsPath::new(format!("{b}/ctl"))).unwrap();
    assert_eq!(st.kind, StatKind::Ctl);
    assert_eq!(
        snap.stat(&FsPath::new(format!("{b}/events"))).unwrap().kind,
        StatKind::Events
    );
    assert_eq!(
        snap.stat(&FsPath::new(format!("{b}/id"))).unwrap().kind,
        StatKind::ReadOnly
    );
    assert_eq!(snap.stat(&FsPath::new(&b)).unwrap().kind, StatKind::Dir);
    let root: Vec<String> = snap
        .readdir(&FsPath::new(""))
        .unwrap()
        .into_iter()
        .map(|s| s.name)
        .collect();
    assert_eq!(
        root,
        [
            "version",
            "ctl",
            "events",
            "trace",
            "keymap",
            "clipboard",
            "clipboard-files",
            "theme",
            "menus",
            "drags",
            "assets",
            "windows"
        ]
    );
    let win: Vec<String> = snap
        .readdir(&FsPath::new(W))
        .unwrap()
        .into_iter()
        .map(|s| s.name)
        .collect();
    assert_eq!(
        win,
        [
            "ctl", "events", "title", "bounds", "state", "focus", "overlays", "root"
        ]
    );
    // Read-only files
    assert_eq!(
        kind(write(&mut t, &format!("{b}/id"), "x")),
        ErrorKind::BadValue
    );
    assert_eq!(kind(write(&mut t, "version", "x")), ErrorKind::BadValue);
    // Versions move when a file changes
    let v1 = t
        .snapshot()
        .stat(&FsPath::new(format!("{b}/label")))
        .unwrap()
        .version;
    ok(&mut t, &format!("{b}/label"), "Okay");
    let v2 = t
        .snapshot()
        .stat(&FsPath::new(format!("{b}/label")))
        .unwrap()
        .version;
    assert_ne!(v1, v2);
    // A snapshot taken earlier still shows the old value.
    assert_eq!(snap.read(&FsPath::new(format!("{b}/label"))).unwrap(), "OK");
}

#[test]
fn slots_and_overlays() {
    let mut t = app();
    // text takes no children
    ok(&mut t, &ctl(R), "new text t");
    assert_eq!(
        kind(write(&mut t, &ctl(&format!("{R}/t")), "new div x")),
        ErrorKind::UnknownType
    );
    // input has named slots
    ok(&mut t, &ctl(R), "new input in");
    ok(&mut t, &ctl(&format!("{R}/in")), "new div prefix");
    assert_eq!(
        kind(write(&mut t, &ctl(&format!("{R}/in")), "new div other")),
        ErrorKind::BadValue
    );
    // form children are fields
    ok(&mut t, &ctl(R), "new form f");
    ok(&mut t, &ctl(&format!("{R}/f")), "new field name label=Name");
    assert_eq!(
        kind(write(&mut t, &ctl(&format!("{R}/f")), "new button b")),
        ErrorKind::UnknownType
    );
    // a child can't hide a node file
    assert_eq!(
        kind(write(&mut t, &ctl(R), "new div style")),
        ErrorKind::BadValue
    );
    // overlays live in overlays/
    assert_eq!(
        kind(write(&mut t, &ctl(R), "new alert-dialog d")),
        ErrorKind::UnknownType
    );
    let o = format!("{W}/overlays");
    assert_eq!(
        kind(write(&mut t, &ctl(&o), "new div d")),
        ErrorKind::UnknownType
    );
    ok(
        &mut t,
        &ctl(&o),
        "new alert-dialog confirm-del title='Delete 3 files?' confirm=Delete tag=del",
    );
    let ch = ok(&mut t, &ctl(&format!("{o}/confirm-del")), "open");
    assert_eq!(
        ch.host,
        vec![HostCmd::Overlay {
            win: "main".into(),
            name: "confirm-del".into(),
            open: true
        }]
    );
    assert_eq!(t.committed_overlays("main").len(), 1);
}

#[test]
fn order_and_delete() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new div a\nnew div b\nnew div c");
    assert_eq!(read(&t, &format!("{R}/order")), "a b c");
    ok(&mut t, &format!("{R}/order"), "c a\n");
    let kids: Vec<&str> = t
        .committed("main")
        .unwrap()
        .children()
        .iter()
        .map(|n| n.name())
        .collect();
    assert_eq!(kids, ["c", "a"]);
    assert_eq!(
        kind(write(&mut t, &format!("{R}/order"), "a zz")),
        ErrorKind::NotFound
    );
    let ch = ok(&mut t, &ctl(R), "delete a");
    assert_eq!(ch.removed, vec![format!("{R}/a")]);
    assert_eq!(read(&t, &format!("{R}/order")), "c");
    // rm -r: files first (no-ops), then the directory
    ok(&mut t, &ctl(&format!("{R}/c")), "new div inner");
    for f in ["inner/style", "inner", "style", "type"] {
        t.apply(
            S,
            Op::Remove {
                path: FsPath::new(format!("{R}/c/{f}")),
            },
        )
        .unwrap();
    }
    assert!(t.node(&format!("{R}/c/inner")).is_none());
    let ch = t
        .apply(
            S,
            Op::Remove {
                path: FsPath::new(format!("{R}/c")),
            },
        )
        .unwrap();
    assert_eq!(ch.removed, vec![format!("{R}/c")]);
    assert_eq!(
        kind(t.apply(
            S,
            Op::Remove {
                path: FsPath::new(format!("{R}/c"))
            }
        )),
        ErrorKind::NotFound
    );
}

#[test]
fn style_words() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new div card\nnew button b");
    let c = format!("{R}/card/style");
    ok(
        &mut t,
        &c,
        "h_flex gap=8 p=12 rounded_lg bg=muted hover:bg=accent cursor_pointer\n",
    );
    ok(
        &mut t,
        &c,
        "w=50% px=1.5rem bg=#1e1e2e shadow=0,4,12,#0003 group:card group-hover(card):bg=accent",
    );
    assert_eq!(
        kind(write(&mut t, &c, "bg=nosuchtoken")),
        ErrorKind::BadValue
    );
    assert_eq!(kind(write(&mut t, &c, "flex_col=3")), ErrorKind::BadValue);
    ok(&mut t, &format!("{R}/b/style"), "ghost sm danger");
    // The failed writes left the last good value.
    assert!(read(&t, &c).starts_with("w=50%"));
}

#[test]
fn data_files_are_checked() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new select s\nnew table tb");
    ok(
        &mut t,
        &format!("{R}/s/items"),
        "rs\tRust\ngo\tGo\n# Group\n-\nc\tC\n",
    );
    ok(
        &mut t,
        &format!("{R}/tb/columns"),
        "name\tName\t280\tsort\nsize\tSize\t90\tsort\talign=right\n",
    );
    ok(&mut t, &format!("{R}/tb/rows"), "1\ta\t10\n");
    // append adds rows
    t.apply(
        S,
        Op::Write {
            path: FsPath::new(format!("{R}/tb/append")),
            data: Bytes::from_static(b"2\tb\t20\n"),
        },
    )
    .unwrap();
    t.apply(
        S,
        Op::Append {
            path: FsPath::new(format!("{R}/tb/append")),
            data: Bytes::from_static(b"3\tc\t30\n"),
        },
    )
    .unwrap();
    assert_eq!(
        read(&t, &format!("{R}/tb/rows")),
        "1\ta\t10\n2\tb\t20\n3\tc\t30\n"
    );
    assert_eq!(read(&t, &format!("{R}/tb/append")), "");
    // read-only prop
    assert_eq!(
        kind(write(&mut t, &format!("{R}/tb/selected"), "1")),
        ErrorKind::BadValue
    );
    // keymap and menus
    ok(
        &mut t,
        "keymap",
        "cmd-s save\ncmd-shift-p  palette\nescape dismiss context=editor\n",
    );
    let ch = ok(
        &mut t,
        "menus/File",
        "item new label=New key=cmd-n\nsep\nsub recent label='Open Recent'\n",
    );
    assert_eq!(ch.host, vec![HostCmd::Menus]);
    assert_eq!(t.menus()[0].0, "File");
    assert!(write(&mut t, "menus/Edit", "bogus line here").is_err());
    assert_eq!(t.menus().len(), 1);
}

#[test]
fn windows_and_root_verbs() {
    let mut t = Tree::new(reg());
    let ch = ok(
        &mut t,
        "ctl",
        "window prefs title=Settings size=600,400 kind=dialog",
    );
    assert_eq!(
        ch.created,
        vec![
            "windows/prefs",
            "windows/prefs/overlays",
            "windows/prefs/root"
        ]
    );
    assert!(matches!(&ch.host[0], HostCmd::Window(w) if w.name == "prefs"));
    let ch = ok(
        &mut t,
        "windows/prefs/ctl",
        "title 'New title'\nsize 800,600\nstate maximized",
    );
    assert_eq!(ch.host.len(), 3);
    assert_eq!(read(&t, "windows/prefs/title"), "New title");
    assert_eq!(read(&t, "windows/prefs/state"), "maximized");
    ok(&mut t, "windows/prefs/title", "Again\n");
    assert_eq!(read(&t, "windows/prefs/title"), "Again");
    ok(
        &mut t,
        "windows/prefs/ctl",
        "notify 'Saved draft' type=success",
    );
    assert!(write(&mut t, "windows/prefs/ctl", "notify hi type=loud").is_err());
    // focus
    ok(&mut t, "windows/prefs/root/ctl", "new input name");
    let ch = ok(&mut t, "windows/prefs/focus", "root/name\n");
    assert_eq!(
        ch.host,
        vec![HostCmd::Focus {
            win: "prefs".into(),
            node: "root/name".into()
        }]
    );
    assert_eq!(
        kind(write(&mut t, "windows/prefs/focus", "root/zz")),
        ErrorKind::NotFound
    );
    // root verbs
    let theme = std::env::temp_dir().join(format!("gpuifs-tree-test-{}.json", std::process::id()));
    std::fs::write(&theme, "{}").unwrap();
    let theme = theme.to_str().unwrap().to_string();
    assert_eq!(
        kind(write(&mut t, "ctl", "theme load /nonexistent/theme.json")),
        ErrorKind::NotFound
    );
    let ch = ok(
        &mut t,
        "ctl",
        &format!("set save enabled=off check=on\ntheme load {theme}\ntheme mode dark\nquit"),
    );
    assert_eq!(
        ch.host,
        vec![
            HostCmd::SetAction {
                id: "save".into(),
                enabled: Some(false),
                check: Some(true)
            },
            HostCmd::ThemeLoad {
                path: theme.clone()
            },
            HostCmd::Theme,
            HostCmd::Quit
        ]
    );
    assert_eq!(read(&t, "theme/mode"), "dark");
    ok(&mut t, "theme/tokens", "primary #0b5cff\nradius 6\n");
    assert!(read(&t, "theme/tokens").contains("primary #0b5cff\n"));
    assert!(read(&t, "theme/tokens").contains("background "));
    // destroy removes the window; its subscribers get gone
    let mut ws = sub(&t, "windows/prefs/events");
    let mut ns = sub(&t, "windows/prefs/root/name/events");
    let ch = ok(&mut t, "windows/prefs/ctl", "destroy");
    assert!(ch.removed.contains(&"windows/prefs".to_string()));
    assert!(t.windows().is_empty());
    assert_eq!(drain(&mut ws), "gone\n");
    assert_eq!(drain(&mut ws), "<eof>");
    assert_eq!(drain(&mut ns), "gone\n");
    // mkdir windows/x makes a window
    t.apply(
        S,
        Op::Mkdir {
            path: FsPath::new("windows/x"),
        },
    )
    .unwrap();
    assert_eq!(read(&t, "windows/x/root/type"), "div");
}

#[test]
fn component_verbs() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new editor src");
    let ch = ok(&mut t, &ctl(&format!("{R}/src")), "save");
    assert!(
        matches!(&ch.host[..], [HostCmd::ComponentVerb { node, cmd }] if node == &format!("{R}/src") && cmd.verb == "save")
    );
    assert_eq!(
        kind(write(&mut t, &ctl(&format!("{R}/src")), "explode")),
        ErrorKind::UnknownCommand
    );
    assert!(read(&t, &ctl(&format!("{R}/src"))).contains("save\n"));
}

// ---- events ------------------------------------------------------------------

#[test]
fn event_lines_and_tags() {
    let mut t = app();
    ok(
        &mut t,
        &ctl(R),
        "new button save label=Save tag=save\nnew select lang",
    );
    let mut s = sub(&t, "events");
    let seq = t.emit(user(EventKind::Action, "click", "root/save"));
    t.emit(user(EventKind::State, "change", "root/lang").attr("value", "go"));
    t.emit(
        EventMsg::new(EventKind::Action, "close")
            .win("main")
            .attr("via", "titlebar"),
    );
    t.emit(EventMsg::new(EventKind::Action, "quit"));
    let got = drain(&mut s);
    let want = format!(
        "click win=main node=root/save tag=save seq={seq}\n\
         change win=main node=root/lang tag='' value=go via=user seq={}\n\
         close win=main via=titlebar seq={}\n\
         quit seq={}\n",
        seq + 1,
        seq + 2,
        seq + 3
    );
    assert_eq!(got, want);
    // a full node path works too
    t.emit(EventMsg::new(EventKind::Action, "click").node(&format!("{R}/save")));
    assert!(drain(&mut s).starts_with("click win=main node=root/save tag=save"));
}

#[test]
fn where_to_read() {
    let mut t = app();
    ok(&mut t, "ctl", "window other");
    ok(&mut t, &ctl(R), "new button a\nnew button b");
    let mut app_s = sub(&t, "events");
    let mut win_s = sub(&t, &format!("{W}/events"));
    let mut a_s = sub(&t, &format!("{R}/a/events"));
    t.emit(user(EventKind::Action, "click", "root/a"));
    t.emit(user(EventKind::Action, "click", "root/b"));
    t.emit(
        EventMsg::new(EventKind::Action, "click")
            .win("other")
            .node("root"),
    );
    t.emit(EventMsg::new(EventKind::Action, "quit"));
    assert_eq!(
        names(&drain(&mut app_s)),
        ["click", "click", "click", "quit"]
    );
    assert_eq!(drain(&mut win_s).lines().count(), 2);
    assert_eq!(drain(&mut a_s).lines().count(), 1);
    // the resync line carries the last seq
    let mut late = t.bus().subscribe(&FsPath::new("events")).unwrap();
    assert_eq!(
        drain(&mut late),
        format!("resync seq={}\n", t.bus().last_seq())
    );
    // missing targets
    assert_eq!(
        t.bus()
            .subscribe(&FsPath::new(format!("{R}/zz/events")))
            .unwrap_err()
            .kind,
        ErrorKind::NotFound
    );
    // node removal: gone, then EOF
    ok(&mut t, &ctl(R), "delete a");
    assert_eq!(drain(&mut a_s), "gone\n");
    assert_eq!(drain(&mut a_s), "<eof>");
}

#[test]
fn state_events_coalesce_and_never_follow_their_submit() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new input in\nnew input other");
    let mut s = sub(&t, "events");
    t.emit(user(EventKind::State, "change", "root/in"));
    t.emit(user(EventKind::State, "change", "root/other"));
    t.emit(user(EventKind::State, "change", "root/in"));
    t.emit(user(EventKind::Action, "submit", "root/in"));
    let got = drain(&mut s);
    let lines: Vec<&str> = got.lines().collect();
    // other's change, then in's newest change, then the submit
    assert_eq!(lines.len(), 3, "{got}");
    assert!(lines[0].contains("node=root/other"));
    assert!(lines[1].starts_with("change") && lines[1].contains("node=root/in"));
    assert!(lines[2].starts_with("submit"));
    // A change after the submit stays after it, and replaces nothing before it.
    t.emit(user(EventKind::State, "change", "root/in"));
    t.emit(user(EventKind::Action, "submit", "root/in"));
    t.emit(user(EventKind::State, "change", "root/in"));
    assert_eq!(names(&drain(&mut s)), ["submit", "change"]);
    // The coalesced event keeps the position of its newest copy.
    t.emit(user(EventKind::State, "change", "root/in"));
    t.emit(user(EventKind::Action, "submit", "root/in"));
    t.emit(user(EventKind::State, "focus", "root/in"));
    let seq = t.emit(user(EventKind::State, "change", "root/in"));
    let got = drain(&mut s);
    assert_eq!(names(&got), ["submit", "focus", "change"]);
    assert!(got.ends_with(&format!("seq={seq}\n")));
}

#[test]
fn action_queue_cap_then_lost() {
    let mut t = app();
    let mut s = sub(&t, "events");
    for _ in 0..ACTION_CAP + 3 {
        t.emit(EventMsg::new(EventKind::Action, "key"));
    }
    t.emit(EventMsg::new(EventKind::State, "move"));
    let got = drain(&mut s);
    let lines: Vec<&str> = got.lines().collect();
    assert_eq!(lines.len(), ACTION_CAP + 2);
    assert_eq!(lines[ACTION_CAP], "lost n=3");
    assert!(lines[ACTION_CAP + 1].starts_with("move"));
    // Room again after reading.
    t.emit(EventMsg::new(EventKind::Action, "key"));
    assert_eq!(names(&drain(&mut s)), ["key"]);
}

#[test]
fn reads_return_whole_lines() {
    let mut t = app();
    let mut s = sub(&t, "events");
    t.emit(EventMsg::new(EventKind::Action, "aaaa"));
    t.emit(EventMsg::new(EventKind::Action, "bbbb"));
    let one = s.try_read(15).unwrap().unwrap();
    assert_eq!(one, "aaaa seq=1\n");
    let rest = futures::executor::block_on(s.read(8192)).unwrap();
    assert_eq!(rest, "bbbb seq=2\n");
    assert!(s.try_read(8192).is_none());
}

#[test]
fn blocked_read_wakes_on_event() {
    let mut t = app();
    let mut s = sub(&t, "events");
    let h = std::thread::spawn(move || futures::executor::block_on(s.read(8192)));
    std::thread::sleep(Duration::from_millis(50));
    t.emit(EventMsg::new(EventKind::Action, "click"));
    assert_eq!(h.join().unwrap().unwrap(), "click seq=1\n");
}

// ---- requests ------------------------------------------------------------------

#[test]
fn request_default_applies_with_no_reader() {
    let mut t = app();
    let seq = t.open_request(
        EventMsg::new(EventKind::Request, "close").win("main"),
        Answer::verb("close"),
        REQUEST_TIMEOUT,
    );
    assert_eq!(
        t.tick(Instant::now()),
        vec![HostCmd::Answer {
            seq,
            answer: Answer::verb("close")
        }]
    );
    assert!(t.open_requests().is_empty());
}

#[test]
fn request_answered_by_seq() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new div tabs\nnew div other");
    let _s = sub(&t, "events");
    let seq = t.open_request(
        user(EventKind::Request, "close", "root/tabs"),
        Answer::verb("close"),
        REQUEST_TIMEOUT,
    );
    assert!(t.tick(Instant::now()).is_empty());
    // On the wrong node's ctl: not found.
    assert_eq!(
        kind(write(
            &mut t,
            &ctl(&format!("{R}/other")),
            &format!("keep seq={seq}")
        )),
        ErrorKind::NotFound
    );
    let ch = ok(
        &mut t,
        &ctl(&format!("{R}/tabs")),
        &format!("keep seq={seq}"),
    );
    assert!(
        matches!(&ch.host[..], [HostCmd::Answer { seq: s, answer }] if *s == seq && answer.0.verb == "keep")
    );
    // A late answer: not found.
    assert_eq!(
        kind(write(
            &mut t,
            &ctl(&format!("{R}/tabs")),
            &format!("close seq={seq}")
        )),
        ErrorKind::NotFound
    );
    // Window and app requests are answered on their own ctl.
    let w = t.open_request(
        EventMsg::new(EventKind::Request, "close").win("main"),
        Answer::verb("close"),
        REQUEST_TIMEOUT,
    );
    ok(&mut t, &ctl(W), &format!("close seq={w}"));
    let q = t.open_request(
        EventMsg::new(EventKind::Request, "quit"),
        Answer::verb("quit"),
        REQUEST_TIMEOUT,
    );
    ok(&mut t, "ctl", &format!("keep seq={q}"));
}

#[test]
fn request_times_out_to_default() {
    let mut t = app();
    let _s = sub(&t, "events");
    let seq = t.open_request(
        EventMsg::new(EventKind::Request, "quit"),
        Answer::verb("quit"),
        REQUEST_TIMEOUT,
    );
    assert!(t.tick(Instant::now()).is_empty());
    let later = Instant::now() + REQUEST_TIMEOUT + Duration::from_millis(10);
    assert_eq!(
        t.tick(later),
        vec![HostCmd::Answer {
            seq,
            answer: Answer::verb("quit")
        }]
    );
    assert_eq!(
        kind(write(&mut t, "ctl", &format!("keep seq={seq}"))),
        ErrorKind::NotFound
    );
}

#[test]
fn drop_request_and_drag_data() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new div notes");
    ok(&mut t, &format!("{R}/notes/drop"), "files text\n");
    t.mirror(
        "drags/7",
        "data",
        Bytes::from_static(b"/drags/7/files/a.txt\n"),
        Via::User,
    );
    assert_eq!(read(&t, "drags/7/data"), "/drags/7/files/a.txt\n");
    let _s = sub(&t, "events");
    let seq = t.open_request(
        user(EventKind::Request, "drop", "root/notes")
            .attr("type", "files")
            .attr("drag", "7")
            .attr("pt", "40,212"),
        Answer::verb("refuse"),
        REQUEST_TIMEOUT,
    );
    ok(
        &mut t,
        &ctl(&format!("{R}/notes")),
        &format!("accept seq={seq}"),
    );
    assert!(t.snapshot().read(&FsPath::new("drags/7/data")).is_none());
    // a client-started drag: the client writes the payload
    t.mirror("drags/8", "data", Bytes::new(), Via::User);
    ok(&mut t, "drags/8/data", "note:42");
    assert_eq!(t.drag_data(8).unwrap(), "note:42");
    assert_eq!(
        kind(write(&mut t, "drags/9/data", "x")),
        ErrorKind::NotFound
    );
}

// ---- batches --------------------------------------------------------------------

#[test]
fn batch_freezes_then_commits() {
    let mut t = app();
    ok(&mut t, &ctl(W), "begin");
    let ch = ok(&mut t, &ctl(R), "new text a text=Hi");
    assert!(ch.dirty_windows.is_empty(), "frozen windows aren't dirty");
    // Reads show the write; the renderer still sees the old tree.
    assert_eq!(read(&t, &format!("{R}/a/text")), "Hi");
    assert!(t.committed("main").unwrap().children().is_empty());
    // Another session's commit doesn't end this one.
    assert_eq!(
        kind(write_as(&mut t, S2, &ctl(W), "commit")),
        ErrorKind::NoBatch
    );
    assert_eq!(kind(write(&mut t, &ctl(W), "begin")), ErrorKind::InUse);
    let ch = ok(&mut t, &ctl(W), "commit");
    assert_eq!(ch.host, vec![HostCmd::Redraw { win: "main".into() }]);
    assert_eq!(t.committed("main").unwrap().children().len(), 1);
}

#[test]
fn batch_abort_restores() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new text keep text=Old");
    ok(&mut t, &ctl(W), "begin");
    ok(&mut t, &ctl(R), "new text gone");
    ok(&mut t, &format!("{R}/keep/text"), "New");
    let ch = ok(&mut t, &ctl(W), "abort");
    assert_eq!(ch.removed, vec![format!("{R}/gone")]);
    assert_eq!(read(&t, &format!("{R}/keep/text")), "Old");
    assert!(t.node(&format!("{R}/gone")).is_none());
}

#[test]
fn batch_times_out_and_session_close_aborts() {
    let mut t = app();
    ok(&mut t, "ctl", "begin");
    ok(&mut t, &ctl(R), "new text a");
    assert!(t.committed("main").unwrap().children().is_empty());
    assert!(t.tick(Instant::now()).is_empty());
    let later = Instant::now() + BATCH_TIMEOUT + Duration::from_millis(10);
    assert_eq!(t.tick(later), vec![HostCmd::Redraw { win: "main".into() }]);
    assert_eq!(t.committed("main").unwrap().children().len(), 1);
    assert!(read(&t, "trace").ends_with("batch timeout\n"));
    // A session that goes away aborts its batch.
    ok(&mut t, &ctl(W), "begin");
    ok(&mut t, &ctl(R), "new text b");
    let ch = t.apply(S, Op::SessionClosed).unwrap();
    assert_eq!(ch.removed, vec![format!("{R}/b")]);
    assert!(t.node(&format!("{R}/b")).is_none());
    // begin and commit in one write cancel out.
    ok(&mut t, &ctl(W), "begin\ncommit");
    assert!(t.committed("main").is_some() && t.tick(Instant::now()).is_empty());
}

// ---- documents -----------------------------------------------------------------

const SIGNIN: &str = "div root  style='v_flex size_full p=24 gap=16'
  text title  style='text_xl font_semibold'  text='Sign in'
  form f
    field user  label=Email
      input in  placeholder=you@example.com
    field pass  label=Password
      input in  flags=secret
    field go
      button submit  label='Sign in'  style='primary w_full'  tag=login
";

#[test]
fn tree_documents_round_trip() {
    let mut t = app();
    ok(&mut t, &format!("{R}/tree"), SIGNIN);
    assert_eq!(read(&t, &format!("{R}/tree")), SIGNIN);
    assert_eq!(read(&t, &format!("{R}/f/go/submit/label")), "Sign in");
    // A subtree reads on its own.
    assert_eq!(
        read(&t, &format!("{R}/f/user/tree")),
        "field user  label=Email\n  input in  placeholder=you@example.com\n"
    );
    // Multi-line text uses a block.
    ok(&mut t, &format!("{R}/title/text"), "Sign\nin\n");
    let doc = read(&t, &format!("{R}/tree"));
    assert!(
        doc.contains("text=<<END\nSign\nin\n  END\n") || doc.contains("text=<<END"),
        "{doc}"
    );
    ok(&mut t, &format!("{R}/tree"), &doc);
    assert_eq!(read(&t, &format!("{R}/tree")), doc);
}

#[test]
fn tree_write_keeps_children_by_name_and_type() {
    let mut t = app();
    ok(&mut t, &format!("{R}/tree"), SIGNIN);
    // The user typed into the email input.
    t.mirror(
        &format!("{R}/f/user/in"),
        "value",
        Bytes::from_static(b"me@x.org"),
        Via::User,
    );
    t.frame_drawn("main");
    let doc = "div root\n  form f\n    field user  label=E-mail\n      input in\n    field go\n      text submit  text=Go\n";
    let ch = ok(&mut t, &format!("{R}/tree"), doc);
    // kept: the input, with its state; replaced: submit (button -> text)
    assert_eq!(read(&t, &format!("{R}/f/user/in/value")), "me@x.org");
    assert_eq!(read(&t, &format!("{R}/f/user/in/placeholder")), "");
    assert_eq!(read(&t, &format!("{R}/f/user/label")), "E-mail");
    assert!(ch.removed.contains(&format!("{R}/title")));
    assert!(ch.removed.contains(&format!("{R}/f/pass")));
    assert!(ch.created.contains(&format!("{R}/f/go/submit")));
    assert_eq!(read(&t, &format!("{R}/f/go/submit/type")), "text");
    assert!(!ch.created.contains(&format!("{R}/f/user/in")));
    // The root's style was left out, so it's back to empty.
    assert_eq!(read(&t, &format!("{R}/style")), "");
    // A bad document changes nothing.
    let before = read(&t, &format!("{R}/tree"));
    assert!(write(&mut t, &format!("{R}/tree"), "div root\n  widget w\n").is_err());
    assert!(write(&mut t, &format!("{R}/tree"), "div other\n").is_err());
    assert_eq!(read(&t, &format!("{R}/tree")), before);
    // The root's type is fixed after the frame.
    assert_eq!(
        kind(write(&mut t, &format!("{R}/tree"), "text root\n")),
        ErrorKind::TypeIsFixed
    );
}

// ---- trace --------------------------------------------------------------------

#[test]
fn trace_hides_secrets() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new input pw flags=secret value=hunter2");
    ok(&mut t, &format!("{R}/pw/value"), "hunter3\n");
    ok(&mut t, &ctl(R), "new input name");
    ok(&mut t, &format!("{R}/name/value"), "Jo\n");
    let tr = read(&t, "trace");
    assert!(!tr.contains("hunter"), "{tr}");
    assert!(
        tr.contains(&format!(
            "ctl path={R}/ctl cmd='new input pw flags=secret value=<secret>'"
        )),
        "{tr}"
    );
    assert!(
        tr.contains(&format!("write path={R}/pw/value value=<secret>")),
        "{tr}"
    );
    assert!(
        tr.contains(&format!("write path={R}/name/value value=Jo")),
        "{tr}"
    );
    // tree writes log one line, not their props
    ok(
        &mut t,
        &format!("{R}/tree"),
        "div root\n  input pw  flags=secret  value=hunter4\n",
    );
    let tr = read(&t, "trace");
    assert!(!tr.contains("hunter4"));
    assert!(
        tr.lines()
            .last()
            .unwrap()
            .starts_with(&format!("write path={R}/tree len="))
    );
}

#[test]
fn changes_report_props() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new button b");
    let ch = ok(&mut t, &format!("{R}/b/label"), "Go");
    assert_eq!(ch.props, vec![(format!("{R}/b"), "label".to_string())]);
    assert_eq!(ch.dirty_windows, vec!["main".to_string()]);
    let ch = ok(&mut t, &format!("{W}/title"), "T2");
    assert_eq!(ch.props, vec![(W.to_string(), "title".to_string())]);
}

#[test]
fn mkdir_then_type_before_first_frame() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new form f");
    // mkdir under a form makes a div, which may become a field
    t.apply(
        S,
        Op::Mkdir {
            path: FsPath::new(format!("{R}/f/name")),
        },
    )
    .unwrap();
    assert_eq!(
        kind(write(&mut t, &format!("{R}/f/name/type"), "button")),
        ErrorKind::UnknownType
    );
    ok(&mut t, &format!("{R}/f/name/type"), "field");
    assert_eq!(
        kind(t.apply(
            S,
            Op::Mkdir {
                path: FsPath::new(format!("{R}/f/name"))
            }
        )),
        ErrorKind::InUse
    );
    // changing type drops files the new type doesn't have
    ok(&mut t, &ctl(R), "new button b label=Hi tag=x");
    ok(&mut t, &format!("{R}/b/type"), "text");
    assert_eq!(t.node(&format!("{R}/b")).unwrap().prop("label"), None);
    assert_eq!(read(&t, &format!("{R}/b/tag")), "x");
}

// ---- echoes, window close, theme ----------------------------------------------

#[test]
fn client_writes_echo_with_via_ctl() {
    let mut t = app();
    ok(
        &mut t,
        &ctl(R),
        "new checkbox cb label='Remember me'\nnew input in\nnew button b",
    );
    let mut s = sub(&t, &format!("{W}/events"));
    ok(&mut t, &format!("{R}/cb/value"), "off\n");
    ok(&mut t, &format!("{R}/in/value"), "typed\n");
    ok(&mut t, &format!("{R}/b/label"), "no echo for labels");
    ok(&mut t, &ctl(W), "state minimized");
    ok(&mut t, &format!("{W}/focus"), "root/b");
    let got = drain(&mut s);
    let lines: Vec<String> = got
        .lines()
        .map(|l| l.rsplit_once(" seq=").unwrap().0.to_string())
        .collect();
    assert_eq!(
        lines,
        [
            "change win=main node=root/cb tag='' value=off via=ctl",
            "change win=main node=root/in tag='' via=ctl",
            "state win=main value=minimized via=ctl",
            "focus win=main node=root/b tag='' via=ctl",
        ]
    );
    // Props set by new or by a tree document send no echo.
    ok(&mut t, &ctl(R), "new checkbox cb2 value=on");
    ok(
        &mut t,
        &format!("{R}/cb2/tree"),
        "checkbox cb2  value=mixed\n",
    );
    assert_eq!(drain(&mut s), "");
}

#[test]
fn window_close_verb_is_a_request() {
    let mut t = app();
    let mut s = sub(&t, "events");
    let ch = ok(&mut t, &ctl(W), "close");
    assert!(ch.host.is_empty());
    let got = drain(&mut s);
    assert!(got.starts_with("close win=main via=ctl seq="), "{got}");
    let seq: u64 = got.trim().rsplit_once("seq=").unwrap().1.parse().unwrap();
    // keep: the window stays
    ok(&mut t, &ctl(W), &format!("keep seq={seq}"));
    assert_eq!(t.windows(), ["main"]);
    // close: the window goes
    ok(&mut t, &ctl(W), "close");
    let got = drain(&mut s);
    let seq: u64 = got.trim().rsplit_once("seq=").unwrap().1.parse().unwrap();
    let ch = ok(&mut t, &ctl(W), &format!("close seq={seq}"));
    assert!(ch.removed.contains(&W.to_string()));
    assert!(t.windows().is_empty());
    // With no reader, the default closes at once.
    drop(s);
    ok(&mut t, "ctl", "window two");
    ok(&mut t, "windows/two/ctl", "close");
    assert!(t.windows().is_empty());
}

#[test]
fn theme_tokens_mode_and_name() {
    let mut t = app();
    ok(&mut t, "theme/tokens", "primary #0b5cff");
    ok(&mut t, "theme/tokens", "radius 6\naccent #445566\n");
    let toks = read(&t, "theme/tokens");
    assert!(
        toks.contains("primary #0b5cff\n")
            && toks.contains("radius 6\n")
            && toks.contains("accent #445566\n")
    );
    assert_eq!(
        kind(write(&mut t, "theme/tokens", "no_such_token #ffffff")),
        ErrorKind::NotFound
    );
    assert_eq!(
        kind(write(&mut t, "theme/tokens", "primary blue")),
        ErrorKind::BadValue
    );
    assert!(read(&t, "theme/tokens").contains("primary #0b5cff\n"));
    assert_eq!(
        kind(write(&mut t, "theme/mode", "sepia")),
        ErrorKind::BadValue
    );
    assert_eq!(read(&t, "theme/mode"), "light");
    ok(&mut t, "theme/name", "Tokyo Night\n");
    assert_eq!(
        kind(write(&mut t, "theme/name", "No Such Theme")),
        ErrorKind::NotFound
    );
    assert_eq!(read(&t, "theme/name"), "Tokyo Night");
}

#[test]
fn trace_matches_the_conformance_golden() {
    // tests/conformance/25-trace.rc, against this crate alone.
    let mut t = Tree::new(reg());
    ok(&mut t, "ctl", "window main title=Conformance size=640,480");
    ok(
        &mut t,
        &ctl(R),
        "new text a text=hi\nnew input pass flags=secret",
    );
    t.apply(
        S,
        Op::Mkdir {
            path: FsPath::new(format!("{R}/b")),
        },
    )
    .unwrap();
    ok(&mut t, &format!("{R}/a/text"), "Hello\n");
    ok(&mut t, &format!("{R}/a/text"), "line one\nline two\n");
    ok(&mut t, &format!("{R}/pass/value"), "hunter2\n");
    ok(&mut t, &ctl(R), "new input pin flags=secret value=1234");
    assert!(write(&mut t, &format!("{R}/a/style"), "flexx").is_err());
    for f in ["type", "style", "b"] {
        let p = if f == "b" {
            format!("{R}/b")
        } else {
            format!("{R}/b/{f}")
        };
        t.apply(
            S,
            Op::Remove {
                path: FsPath::new(p),
            },
        )
        .unwrap();
    }
    ok(&mut t, &ctl(W), "begin");
    t.tick(Instant::now() + BATCH_TIMEOUT);
    let want = "ctl path=ctl cmd='window main title=Conformance size=640,480'
ctl path=windows/main/root/ctl cmd='new text a text=hi'
ctl path=windows/main/root/ctl cmd='new input pass flags=secret'
mkdir path=windows/main/root/b
write path=windows/main/root/a/text value=Hello
write path=windows/main/root/a/text len=18
write path=windows/main/root/pass/value value=<secret>
ctl path=windows/main/root/ctl cmd='new input pin flags=secret value=<secret>'
remove path=windows/main/root/b
ctl path=windows/main/ctl cmd=begin
batch timeout win=main
";
    assert_eq!(read(&t, "trace"), want);
}

#[test]
fn design_state_names_coalesce_even_as_actions() {
    let mut t = app();
    ok(&mut t, &ctl(R), "new div card");
    let mut s = sub(&t, "events");
    t.emit(user(EventKind::Action, "hover", "root/card").attr("value", "on"));
    t.emit(user(EventKind::Action, "hover", "root/card").attr("value", "off"));
    let got = drain(&mut s);
    assert_eq!(got.lines().count(), 1, "{got}");
    assert!(got.contains("value=off via=user"), "{got}");
}

#[test]
fn keymap_keystrokes_are_checked() {
    let mut t = app();
    ok(
        &mut t,
        "keymap",
        "cmd-s save\ncmd-shift-p palette\nescape dismiss context=editor\nctrl-tab next-tab\nctrl-- zoom-out\n",
    );
    assert_eq!(
        kind(write(&mut t, "keymap", "cmd-s save\ncmd-wibble-q quit\n")),
        ErrorKind::BadValue
    );
    assert!(read(&t, "keymap").starts_with("cmd-s save\ncmd-shift-p"));
}
