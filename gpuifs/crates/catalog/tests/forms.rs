//! W6a headless TypeSpec tests: DESIGN § Buttons and form controls against
//! the real tree, with no renderer (the shapes conformance 09-forms checks).

use bytes::Bytes;
use proto::ErrorKind;
use tree::{FsPath, Op, Registry, SessionId, Subscription, Tree};

const S: SessionId = SessionId(1);
const R: &str = "windows/main/root";

fn app() -> Tree {
    let mut t = Tree::new(Registry::from_catalog());
    ok(&mut t, "ctl", "window main");
    t
}
fn write(t: &mut Tree, path: &str, data: &str) -> Result<(), proto::Error> {
    t.apply(
        S,
        Op::Write {
            path: FsPath::new(path),
            data: Bytes::copy_from_slice(data.as_bytes()),
        },
    )
    .map(drop)
}
#[track_caller]
fn ok(t: &mut Tree, path: &str, data: &str) {
    write(t, path, data).unwrap_or_else(|e| panic!("write {path} {data:?}: {e}"))
}
#[track_caller]
fn fails(t: &mut Tree, path: &str, data: &str) -> ErrorKind {
    match write(t, path, data) {
        Ok(()) => panic!("write {path} {data:?} should fail"),
        Err(e) => e.kind,
    }
}
fn read(t: &Tree, path: &str) -> String {
    let b = t.snapshot().read(&FsPath::new(path)).unwrap_or_else(|| panic!("read {path}"));
    String::from_utf8(b.to_vec()).unwrap()
}
fn ctl(t: &mut Tree, dir: &str, line: &str) {
    ok(t, &format!("{dir}/ctl"), line);
}
fn sub(t: &Tree, f: &str) -> Subscription {
    let mut s = t.bus().subscribe(&FsPath::new(f)).unwrap();
    drain(&mut s);
    s
}
fn drain(s: &mut Subscription) -> String {
    let mut out = String::new();
    while let Some(Ok(b)) = s.try_read(64 * 1024) {
        out.push_str(&String::from_utf8_lossy(&b));
    }
    out
}

#[test]
fn every_form_type_is_a_component() {
    for n in [
        "button", "button-group", "dropdown-button", "checkbox", "radio-group", "switch",
        "toggle", "slider", "input", "textarea", "number-input", "otp-input", "select",
        "combobox", "date-picker", "calendar", "color-picker", "rating", "form", "field",
    ] {
        let s = catalog::get(n).unwrap_or_else(|| panic!("no spec {n}"));
        assert_eq!(s.tier, catalog::Tier::Component, "{n}");
        assert!(catalog::forms::SPECS.iter().any(|x| x.name == n));
    }
}

#[test]
fn design_form_snippet_builds() {
    let mut t = app();
    let w = R;
    ctl(&mut t, w, "new form prefs layout=v");
    ctl(&mut t, &format!("{w}/prefs"), "new field name label=Name\nnew field lang label=Language\nnew field ok");
    ctl(&mut t, &format!("{w}/prefs/name"), "new input in placeholder='Your name'");
    ctl(&mut t, &format!("{w}/prefs/lang"), "new select in searchable=on");
    ok(&mut t, &format!("{w}/prefs/lang/in/items"), "rs\tRust\ngo\tGo\nc\tC\n");
    ctl(&mut t, &format!("{w}/prefs/ok"), "new button save label=Save style=primary tag=save");
    let doc = read(&t, &format!("{w}/prefs/tree"));
    for line in [
        "form prefs  layout=v\n",
        "  field name  label=Name\n",
        "    input in  placeholder='Your name'\n",
        "  field lang  label=Language\n",
        "    select in  searchable=on",
        "  field ok\n",
        "    button save  label=Save  style=primary  tag=save\n",
    ] {
        assert!(doc.contains(line), "{line:?} in {doc}");
    }
    // A form holds fields only.
    assert_eq!(
        write(&mut t, &format!("{w}/prefs/ctl"), "new button x").unwrap_err().kind,
        ErrorKind::UnknownType
    );
}

#[test]
fn select_and_radio_values_are_item_ids() {
    let mut t = app();
    ctl(&mut t, R, "new select s\nnew radio-group r\nnew combobox c multiple=on");
    // No items yet: any id is kept.
    ok(&mut t, &format!("{R}/s/value"), "later");
    ok(&mut t, &format!("{R}/s/items"), "rs\tRust\n# Other\ngo\tGo\n-\nc\tC\tdisabled\n");
    ok(&mut t, &format!("{R}/s/value"), "go");
    assert_eq!(read(&t, &format!("{R}/s/value")), "go");
    assert_eq!(fails(&mut t, &format!("{R}/s/value"), "fortran"), ErrorKind::NotFound);
    assert_eq!(read(&t, &format!("{R}/s/value")), "go");
    ok(&mut t, &format!("{R}/s/value"), "");

    ok(&mut t, &format!("{R}/r/items"), "s\tSmall\nm\tMedium\n");
    ok(&mut t, &format!("{R}/r/value"), "m");
    assert_eq!(fails(&mut t, &format!("{R}/r/value"), "xl"), ErrorKind::NotFound);

    ok(&mut t, &format!("{R}/c/items"), "bug\tbug\ndocs\tdocs\n");
    ok(&mut t, &format!("{R}/c/value"), "bug docs");
    assert_eq!(fails(&mut t, &format!("{R}/c/value"), "bug nope"), ErrorKind::NotFound);
}

#[test]
fn checkbox_values_and_echo() {
    let mut t = app();
    ctl(&mut t, R, "new checkbox cb label='Remember me'");
    assert_eq!(read(&t, &format!("{R}/cb/value")), "off");
    ok(&mut t, &format!("{R}/cb/value"), "on");
    ok(&mut t, &format!("{R}/cb/value"), "mixed");
    assert_eq!(fails(&mut t, &format!("{R}/cb/value"), "yes"), ErrorKind::BadValue);
    let mut ev = sub(&t, "windows/main/events");
    ok(&mut t, &format!("{R}/cb/value"), "off");
    let got = drain(&mut ev);
    assert!(got.contains("change win=main node=root/cb tag='' value=off via=ctl"), "{got}");
    ok(&mut t, &format!("{R}/cb/controlled"), "on");
    assert_eq!(fails(&mut t, &format!("{R}/cb/controlled"), "maybe"), ErrorKind::BadValue);
}

#[test]
fn switch_toggle_rating_and_numbers() {
    let mut t = app();
    ctl(&mut t, R, "new switch sw label=Wi-Fi value=on\nnew toggle tg icon=bold style=ghost\nnew rating r max=5 value=3");
    assert_eq!(read(&t, &format!("{R}/sw/value")), "on");
    assert_eq!(read(&t, &format!("{R}/tg/value")), "off");
    assert_eq!(fails(&mut t, &format!("{R}/sw/value"), "maybe"), ErrorKind::BadValue);
    assert_eq!(fails(&mut t, &format!("{R}/r/value"), "lots"), ErrorKind::BadValue);
    ctl(&mut t, R, "new slider vol min=0 max=100 step=5");
    ok(&mut t, &format!("{R}/vol/value"), "40");
    ok(&mut t, &format!("{R}/vol/value"), "20 80");
    assert_eq!(read(&t, &format!("{R}/vol/value")), "20 80");
    assert_eq!(fails(&mut t, &format!("{R}/vol/value"), "loud"), ErrorKind::BadValue);
    ctl(&mut t, R, "new number-input n value=3 min=0 max=10\nnew otp-input otp length=6");
    assert_eq!(fails(&mut t, &format!("{R}/n/value"), "three"), ErrorKind::BadValue);
}

#[test]
fn input_change_echo_has_no_text_and_secret_is_redacted() {
    let mut t = app();
    ctl(&mut t, R, "new input name\nnew input pass flags=secret");
    let mut ev = sub(&t, "windows/main/events");
    ok(&mut t, &format!("{R}/name/value"), "Ada\n");
    assert_eq!(read(&t, &format!("{R}/name/value")), "Ada");
    let got = drain(&mut ev);
    assert!(got.contains("change win=main node=root/name tag='' via=ctl"), "{got}");
    assert!(!got.contains("Ada"), "{got}");
    ok(&mut t, &format!("{R}/pass/value"), "hunter2");
    assert_eq!(read(&t, &format!("{R}/pass/value")), "hunter2");
    assert!(!read(&t, "trace").contains("hunter2"));
}

#[test]
fn slots_and_children() {
    let mut t = app();
    ctl(&mut t, R, "new input search flags=cleanable");
    ctl(&mut t, &format!("{R}/search"), "new icon prefix name=search\nnew text suffix text=⌘K");
    assert_eq!(fails(&mut t, &format!("{R}/search/ctl"), "new text middle"), ErrorKind::BadValue);
    ctl(&mut t, R, "new button-group g value=b");
    ctl(&mut t, &format!("{R}/g"), "new button a label=Day\nnew button b label=Week");
    assert_eq!(fails(&mut t, &format!("{R}/g/ctl"), "new checkbox c"), ErrorKind::UnknownType);
    ctl(&mut t, R, "new dropdown-button more label=More");
    ok(&mut t, &format!("{R}/more/menu"), "item copy label=Copy key=cmd-c\nsep\nitem del label=Delete\n");
    assert_eq!(fails(&mut t, &format!("{R}/more/ctl"), "new div x"), ErrorKind::UnknownType);
    ctl(&mut t, R, "new field f label=Name required=on");
    ctl(&mut t, &format!("{R}/f"), "new input in");
}

#[test]
fn variant_and_size_words() {
    let mut t = app();
    ctl(&mut t, R, "new button b label=Go\nnew div box\nnew select s\nnew toggle t");
    for s in ["primary", "outline sm", "danger ghost", "link xs", "success lg w_full"] {
        ok(&mut t, &format!("{R}/b/style"), s);
    }
    ok(&mut t, &format!("{R}/s/style"), "sm w=200");
    ok(&mut t, &format!("{R}/t/style"), "outline");
    assert_eq!(fails(&mut t, &format!("{R}/t/style"), "primary"), ErrorKind::UnknownStyleWord);
    assert_eq!(fails(&mut t, &format!("{R}/s/style"), "primary"), ErrorKind::UnknownStyleWord);
    assert_eq!(fails(&mut t, &format!("{R}/box/style"), "primary"), ErrorKind::UnknownStyleWord);
}

#[test]
fn date_and_color_values() {
    let mut t = app();
    ctl(&mut t, R, "new date-picker one value=2026-11-21\nnew date-picker range range=on value='2026-11-01 2026-11-30' presets=on\nnew calendar cal value=2026-11-21\nnew color-picker col value=#0b5cffff");
    assert_eq!(read(&t, &format!("{R}/range/value")), "2026-11-01 2026-11-30");
    assert_eq!(read(&t, &format!("{R}/col/value")), "#0b5cffff");
    ctl(&mut t, R, "new combobox tags placeholder=Tags multiple=on");
    assert_eq!(fails(&mut t, &format!("{R}/tags/query"), "x"), ErrorKind::BadValue);
}

/// The GPUI Kit gallery stories made of form controls load as `tree`
/// documents (examples/rc/gallery/<story>/tree).
#[test]
fn gallery_form_stories_load() {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples/rc/gallery");
    for story in ["button", "toggles", "input", "select", "slider", "date"] {
        let doc = std::fs::read_to_string(format!("{dir}/{story}/tree")).unwrap();
        let mut t = app();
        ctl(&mut t, R, "new scroll story");
        if let Err(e) = write(&mut t, &format!("{R}/story/tree"), &doc) {
            panic!("{story}: {e}");
        }
        assert_eq!(read(&t, &format!("{R}/story/tree")).lines().count(), doc.lines().count(), "{story}");
    }
}
