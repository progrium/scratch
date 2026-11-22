//! W6b's TypeSpecs against the real tree, headless: the tree-level halves of
//! conformance scripts 10-navigation and 11-overlays, plus the `Child`,
//! `NodePath` and `Slots::NamedAnd` rules they need.

use proto::ErrorKind;
use tree::{FsPath, Op, Registry, SessionId, Tree};

const S: SessionId = SessionId(1);

fn tree() -> Tree {
    let mut t = Tree::new(Registry::from_catalog());
    w(&mut t, "ctl", "window main").unwrap();
    t
}

fn w(t: &mut Tree, path: &str, data: &str) -> Result<(), proto::Error> {
    t.apply(
        S,
        Op::Write {
            path: FsPath::new(path),
            data: data.as_bytes().to_vec().into(),
        },
    )
    .map(|_| ())
}

fn ok(t: &mut Tree, path: &str, data: &str) {
    if let Err(e) = w(t, path, data) {
        panic!("{path} <- {data:?}: {e}");
    }
}

fn kind(r: Result<(), proto::Error>) -> Option<ErrorKind> {
    r.err().map(|e| e.kind)
}

fn read(t: &Tree, path: &str) -> String {
    t.snapshot()
        .read(&FsPath::new(path))
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_else(|| panic!("no {path}"))
}

const R: &str = "windows/main/root";
const O: &str = "windows/main/overlays";

#[test]
fn settings_snippet() {
    let mut t = tree();
    ok(&mut t, &format!("{R}/style"), "h_flex size_full");
    ok(&mut t, &format!("{R}/ctl"), "new sidebar nav\nnew div page style='flex_1 p=24'");
    ok(&mut t, &format!("{R}/nav/ctl"), "new sidebar-group g label=Settings");
    ok(
        &mut t,
        &format!("{R}/nav/g/ctl"),
        "new sidebar-item general label=General icon=settings active=on tag=page:general\n\
         new sidebar-item account label=Account icon=user tag=page:account\n\
         new sidebar-item keys label=Shortcuts icon=keyboard tag=page:keys",
    );
    assert_eq!(
        read(&t, &format!("{R}/tree")),
        "div root  style='h_flex size_full'\n\
         \x20 sidebar nav\n\
         \x20   sidebar-group g  label=Settings\n\
         \x20     sidebar-item general  label=General  icon=settings  active=on  tag=page:general\n\
         \x20     sidebar-item account  label=Account  icon=user  tag=page:account\n\
         \x20     sidebar-item keys  label=Shortcuts  icon=keyboard  tag=page:keys\n\
         \x20 div page  style='flex_1 p=24'\n"
    );
    // Outside its header and footer slots, a sidebar takes sidebar-groups.
    assert_eq!(kind(w(&mut t, &format!("{R}/nav/ctl"), "new text stray")), Some(ErrorKind::UnknownType));
    ok(&mut t, &format!("{R}/nav/ctl"), "new text header text=App");
    ok(&mut t, &format!("{R}/nav/ctl"), "new div footer");
    assert_eq!(kind(w(&mut t, &format!("{R}/nav/g/ctl"), "new text x")), Some(ErrorKind::UnknownType));
    // Sub-items.
    ok(&mut t, &format!("{R}/nav/g/keys/ctl"), "new sidebar-item vim label=Vim");
    assert_eq!(kind(w(&mut t, &format!("{R}/nav/side"), "up")), Some(ErrorKind::BadValue));
}

#[test]
fn tabs_value_and_children() {
    let mut t = tree();
    ok(&mut t, &format!("{R}/ctl"), "new tabs t style=underline");
    let tb = format!("{R}/t");
    ok(&mut t, &format!("{tb}/ctl"), "new tab a label=One\nnew tab b label=Two closable=on");
    ok(&mut t, &format!("{tb}/a/ctl"), "new text body text='first panel'");
    ok(&mut t, &format!("{tb}/value"), "b");
    assert_eq!(read(&t, &format!("{tb}/value")), "b");
    assert_eq!(kind(w(&mut t, &format!("{tb}/value"), "c")), Some(ErrorKind::NotFound));
    assert_eq!(read(&t, &format!("{tb}/value")), "b");
    assert_eq!(kind(w(&mut t, &format!("{tb}/ctl"), "new div x")), Some(ErrorKind::UnknownType));
    assert_eq!(kind(w(&mut t, &format!("{tb}/style"), "pill")), None);
    assert_eq!(kind(w(&mut t, &format!("{tb}/style"), "sideways")), Some(ErrorKind::UnknownStyleWord));
    // A document sets value after making its children.
    ok(
        &mut t,
        &format!("{R}/tree"),
        "div root\n  tabs t2  value=two  style=segmented\n    tab one  label=One\n    tab two  label=Two\n",
    );
    assert_eq!(read(&t, &format!("{R}/t2/value")), "two");
}

#[test]
fn breadcrumb_pagination_link() {
    let mut t = tree();
    ok(&mut t, &format!("{R}/ctl"), "new breadcrumb crumbs");
    ok(&mut t, &format!("{R}/crumbs/items"), "home\tHome\ndocs\tDocs\n");
    assert_eq!(read(&t, &format!("{R}/crumbs/items")), "home\tHome\ndocs\tDocs\n");
    ok(&mut t, &format!("{R}/ctl"), "new pagination pg total=120 per_page=20");
    ok(&mut t, &format!("{R}/pg/page"), "3");
    assert_eq!(kind(w(&mut t, &format!("{R}/pg/page"), "three")), Some(ErrorKind::BadValue));
    ok(&mut t, &format!("{R}/ctl"), "new link help label=Help href=https://example.com/help");
    assert_eq!(read(&t, &format!("{R}/help/href")), "https://example.com/help");
    ok(&mut t, &format!("{R}/ctl"), "new stepper s dir=v");
    ok(&mut t, &format!("{R}/s/items"), "cart\tCart\npay\tPayment\n");
    ok(&mut t, &format!("{R}/ctl"), "new status-bar sb");
    assert_eq!(kind(w(&mut t, &format!("{R}/sb/ctl"), "new text middle")), Some(ErrorKind::BadValue));
    ok(&mut t, &format!("{R}/sb/ctl"), "new text left\nnew text center\nnew text right");
    ok(&mut t, &format!("{R}/ctl"), "new title-bar tb title=Workspace\nnew toolbar bar");
}

#[test]
fn overlays_directory() {
    let mut t = tree();
    assert_eq!(kind(w(&mut t, &format!("{R}/ctl"), "new dialog d")), Some(ErrorKind::UnknownType));
    assert_eq!(kind(w(&mut t, &format!("{O}/ctl"), "new div d")), Some(ErrorKind::UnknownType));
    ok(
        &mut t,
        &format!("{O}/ctl"),
        "new alert-dialog confirm-del title='Delete 3 files?' description='This cannot be undone.' confirm=Delete cancel=Keep variant=danger tag=del",
    );
    assert_eq!(
        read(&t, &format!("{O}/confirm-del/tree")),
        "alert-dialog confirm-del  title='Delete 3 files?'  description='This cannot be undone.'  confirm=Delete  cancel=Keep  variant=danger  tag=del\n"
    );
    ok(&mut t, &format!("{O}/confirm-del/ctl"), "open");
    ok(&mut t, &format!("{O}/confirm-del/ctl"), "close");
    assert_eq!(kind(w(&mut t, &format!("{O}/ctl"), "new alert-dialog x variant=sideways")), Some(ErrorKind::BadValue));
    ok(&mut t, &format!("{O}/ctl"), "new dialog about title=About width=420 modal=on keyboard=on");
    ok(&mut t, &format!("{O}/about/ctl"), "new text body text='gpuifs 0.1'\nnew div footer style='h_flex justify_end'");
    assert_eq!(
        read(&t, &format!("{O}/about/tree")),
        "dialog about  title=About  width=420  modal=on  keyboard=on\n\
         \x20 text body  text='gpuifs 0.1'\n\
         \x20 div footer  style='h_flex justify_end'\n"
    );
    // `open` is read back, never written.
    assert_eq!(read(&t, &format!("{O}/about/open")), "off");
    assert!(w(&mut t, &format!("{O}/about/open"), "on").is_err());
    ok(&mut t, &format!("{R}/ctl"), "new div more");
    ok(&mut t, &format!("{O}/ctl"), "new popover pop anchor=root/more placement=bottom-start trigger=click");
    assert_eq!(kind(w(&mut t, &format!("{O}/ctl"), "new popover pop2 anchor=root/nope")), Some(ErrorKind::NotFound));
    assert_eq!(kind(w(&mut t, &format!("{O}/pop/anchor"), "root/gone")), Some(ErrorKind::NotFound));
    assert_eq!(kind(w(&mut t, &format!("{O}/pop/trigger"), "focus")), Some(ErrorKind::BadValue));
    ok(&mut t, &format!("{O}/ctl"), "new hover-card card anchor=root/more open_delay=200");
    ok(&mut t, &format!("{O}/ctl"), "new context-menu menu anchor=root/more");
    ok(&mut t, &format!("{O}/menu/menu"), "item open label=Open\nsep\nsub more label=More\n  item dup label=Duplicate\n");
    ok(&mut t, &format!("{O}/ctl"), "new sheet sh side=right size=360 title=Filters");
    assert_eq!(kind(w(&mut t, &format!("{O}/sh/side"), "middle")), Some(ErrorKind::BadValue));
    let ctl = read(&t, &format!("{O}/sh/ctl"));
    assert!(ctl.contains("open\n") && ctl.contains("close\n"), "{ctl}");
}

#[test]
fn every_w6b_type_is_in_the_catalog() {
    for ty in [
        "tabs", "tab", "sidebar", "sidebar-group", "sidebar-item", "breadcrumb", "pagination",
        "stepper", "title-bar", "toolbar", "status-bar", "link", "dialog", "alert-dialog", "sheet",
        "popover", "hover-card", "context-menu",
    ] {
        assert!(catalog::get(ty).is_some(), "{ty}");
    }
}
