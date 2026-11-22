//! Drag and drop tests on GPUI's test platform.

use std::time::{Duration, Instant};

use gpui::{ExternalPaths, FileDropEvent, Modifiers, MouseButton, TestAppContext, point, px};

use crate::testing::Harness;

const R: &str = "windows/main/root";

fn setup(cx: &mut TestAppContext, accept: &str) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=400,300");
    h.write(&format!("{R}/style"), "v_flex size_full gap=20 p=10");
    h.ctl(R, "new div card style='w=80 h=30' tag=card");
    h.write(&format!("{R}/card/on"), "drag");
    h.write(&format!("{R}/card/drag-type"), "note");
    h.ctl(
        R,
        "new div notes style='w=200 h=100 drop-over:bg=accent hover:border_1' tag=pick",
    );
    h.write(&format!("{R}/notes/drop"), accept);
    h
}

fn center(h: &Harness, node: &str) -> gpui::Point<gpui::Pixels> {
    let [x, y, w, hh] = h.bounds(&format!("{R}/{node}"));
    point(px(x + w / 2.), px(y + hh / 2.))
}

fn attr(line: &str, k: &str) -> Option<String> {
    line.split_whitespace()
        .find_map(|w| w.strip_prefix(&format!("{k}=")).map(str::to_string))
}

/// Presses on the card and drags it onto the notes node.
fn drag_card_to_notes(h: &mut Harness) {
    let from = center(h, "card");
    let to = center(h, "notes");
    let mut v = h.visual("main");
    v.simulate_mouse_move(from, None, Modifiers::none());
    v.simulate_mouse_down(from, MouseButton::Left, Modifiers::none());
    v.simulate_mouse_move(
        point(from.x + px(10.), from.y + px(10.)),
        MouseButton::Left,
        Modifiers::none(),
    );
    h.settle();
    let mut v = h.visual("main");
    v.simulate_mouse_move(to, MouseButton::Left, Modifiers::none());
    v.simulate_mouse_up(to, MouseButton::Left, Modifiers::none());
    h.settle();
}

#[gpui::test]
fn in_app_drag_is_accepted(cx: &mut TestAppContext) {
    let mut h = setup(cx, "files note");
    let mut ev = h.subscribe("windows/main/events");
    h.events(&mut ev);

    let from = center(&h, "card");
    let mut v = h.visual("main");
    v.simulate_mouse_move(from, None, Modifiers::none());
    v.simulate_mouse_down(from, MouseButton::Left, Modifiers::none());
    v.simulate_mouse_move(
        point(from.x + px(10.), from.y + px(10.)),
        MouseButton::Left,
        Modifiers::none(),
    );
    h.settle();
    let lines = h.events(&mut ev);
    let start = lines.iter().find(|l| l.starts_with("dragstart ")).cloned();
    let start = start.unwrap_or_else(|| panic!("no dragstart: {lines:?}"));
    assert!(start.contains("node=root/card tag=card"), "{start}");
    let n = attr(&start, "drag").unwrap();
    // The host made /drags/<n> before dragstart; the client fills it.
    assert_eq!(h.read(&format!("drags/{n}/data")).as_deref(), Some(""));
    h.write(&format!("drags/{n}/data"), "note-42\n");

    let to = center(&h, "notes");
    let mut v = h.visual("main");
    v.simulate_mouse_move(to, MouseButton::Left, Modifiers::none());
    v.simulate_mouse_up(to, MouseButton::Left, Modifiers::none());
    h.settle();
    let lines = h.events(&mut ev);
    let drop = lines.iter().find(|l| l.starts_with("drop ")).cloned();
    let drop = drop.unwrap_or_else(|| panic!("no drop: {lines:?}"));
    assert!(
        drop.starts_with(&format!(
            "drop win=main node=root/notes tag=pick type=note drag={n} pt="
        )),
        "{drop}"
    );
    assert!(
        !lines.iter().any(|l| l.starts_with("dragend")),
        "dragend waits for the answer"
    );
    assert_eq!(
        h.read(&format!("drags/{n}/data")).as_deref(),
        Some("note-42\n")
    );

    let seq = attr(&drop, "seq").unwrap();
    h.ctl(&format!("{R}/notes"), &format!("accept seq={seq}"));
    let lines = h.events(&mut ev);
    assert!(
        lines.iter().any(|l| l.starts_with(&format!(
            "dragend win=main node=root/card tag=card drag={n} result=dropped target=root/notes"
        ))),
        "{lines:?}"
    );
    assert!(
        h.read(&format!("drags/{n}/data")).is_none(),
        "/drags/{n} goes away"
    );
}

#[gpui::test]
fn refused_and_unaccepted_drags_are_cancelled(cx: &mut TestAppContext) {
    let mut h = setup(cx, "note");
    let mut ev = h.subscribe("windows/main/events");
    h.events(&mut ev);
    drag_card_to_notes(&mut h);
    let lines = h.events(&mut ev);
    let drop = lines
        .iter()
        .find(|l| l.starts_with("drop "))
        .cloned()
        .unwrap();
    let n = attr(&drop, "drag").unwrap();
    h.ctl(
        &format!("{R}/notes"),
        &format!("refuse seq={}", attr(&drop, "seq").unwrap()),
    );
    let lines = h.events(&mut ev);
    assert!(
        lines
            .iter()
            .any(|l| l.contains("dragend") && l.contains(&format!("drag={n} result=cancelled"))),
        "{lines:?}"
    );

    // A target that doesn't list the type gets no drop.
    h.write(&format!("{R}/notes/drop"), "files");
    drag_card_to_notes(&mut h);
    let lines = h.events(&mut ev);
    assert!(!lines.iter().any(|l| l.starts_with("drop ")), "{lines:?}");
    assert!(
        lines
            .iter()
            .any(|l| l.starts_with("dragend") && l.contains("result=cancelled")),
        "{lines:?}"
    );
}

#[gpui::test]
fn unanswered_drop_is_refused_after_the_timeout(cx: &mut TestAppContext) {
    let mut h = setup(cx, "note");
    let mut ev = h.subscribe("windows/main/events");
    h.events(&mut ev);
    drag_card_to_notes(&mut h);
    let lines = h.events(&mut ev);
    let drop = lines
        .iter()
        .find(|l| l.starts_with("drop "))
        .cloned()
        .unwrap();
    let n = attr(&drop, "drag").unwrap();
    // Request deadlines are wall-clock; run the tree's tick as if 6 s passed.
    let inner = h.inner().clone();
    h.cx.update(|cx| {
        let cmds = inner
            .tree
            .borrow_mut()
            .tick(Instant::now() + Duration::from_secs(6));
        inner.publish();
        for c in cmds {
            crate::runtime::host_cmd(&inner, c, cx);
        }
    });
    let lines = h.events(&mut ev);
    assert!(
        lines
            .iter()
            .any(|l| l.starts_with("dragend") && l.contains("result=cancelled")),
        "{lines:?}"
    );
    assert!(h.read(&format!("drags/{n}/data")).is_none());
}

#[gpui::test]
fn platform_files_are_served_under_drags(cx: &mut TestAppContext) {
    let mut h = setup(cx, "files");
    let dir = std::env::temp_dir().join(format!("gpuifs-dnd-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let f = dir.join("hello.txt");
    std::fs::write(&f, "hi there\n").unwrap();

    let mut ev = h.subscribe("windows/main/events");
    h.events(&mut ev);
    let to = center(&h, "notes");
    let mut v = h.visual("main");
    v.simulate_event(FileDropEvent::Entered {
        position: to,
        paths: ExternalPaths(vec![f.clone()].into()),
    });
    v.simulate_event(FileDropEvent::Pending { position: to });
    v.simulate_event(FileDropEvent::Submit { position: to });
    h.settle();
    let lines = h.events(&mut ev);
    let drop = lines.iter().find(|l| l.starts_with("drop ")).cloned();
    let drop = drop.unwrap_or_else(|| panic!("no drop: {lines:?}"));
    assert!(
        drop.contains("node=root/notes tag=pick type=files"),
        "{drop}"
    );
    let n = attr(&drop, "drag").unwrap();
    assert_eq!(
        h.read(&format!("drags/{n}/data")).unwrap(),
        format!("/mnt/gpui/drags/{n}/files/hello.txt\n")
    );
    let served = h.inner().dnd.served.clone();
    let p = tree::FsPath::new(format!("drags/{n}/files/hello.txt"));
    assert_eq!(served.read(&p).as_deref(), Some(&b"hi there\n"[..]));
    assert_eq!(served.stat(&p).unwrap().len, 9);
    let names: Vec<String> = served
        .readdir(&tree::FsPath::new(format!("drags/{n}/files")))
        .into_iter()
        .map(|s| s.name)
        .collect();
    assert_eq!(names, ["hello.txt"]);
    assert_eq!(
        served
            .readdir(&tree::FsPath::new(format!("drags/{n}")))
            .len(),
        1
    );

    h.ctl(
        &format!("{R}/notes"),
        &format!("accept seq={}", attr(&drop, "seq").unwrap()),
    );
    assert!(served.read(&p).is_none(), "served files go with the drag");
    assert!(h.read(&format!("drags/{n}/data")).is_none());
    let _ = std::fs::remove_dir_all(&dir);
}

#[gpui::test]
fn with_no_reader_the_drop_is_refused_at_once(cx: &mut TestAppContext) {
    let mut h = setup(cx, "note");
    drag_card_to_notes(&mut h);
    h.settle();
    assert!(h.inner().dnd.served.drags().is_empty());
    let snap = h.inner().snapshot.lock().unwrap().clone();
    let drags = snap.readdir(&tree::FsPath::new("drags")).unwrap();
    assert!(drags.is_empty(), "{drags:?}");
}
