//! W6b overlays: tree validation and render tests on GPUI's test platform.

use std::time::Duration;

use gpui::{Modifiers, MouseButton, TestAppContext, point, px};
use proto::ErrorKind;

use crate::components::nav::tests::{click_at, click_part, seq_of};
use crate::testing::Harness;

const W: &str = "windows/main";
const R: &str = "windows/main/root";
const O: &str = "windows/main/overlays";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=800,600");
    h.write(&format!("{R}/style"), "v_flex size_full p=8 gap=4");
    h
}

fn kind(r: Result<(), proto::Error>) -> Option<ErrorKind> {
    r.err().map(|e| e.kind)
}

fn open_file(h: &Harness, name: &str) -> String {
    h.read(&format!("{O}/{name}/open")).unwrap_or_default()
}

#[gpui::test]
fn overlays_live_in_overlays(cx: &mut TestAppContext) {
    let mut h = window(cx);
    assert_eq!(kind(h.try_write(&format!("{R}/ctl"), "new dialog d")), Some(ErrorKind::UnknownType));
    assert_eq!(kind(h.try_write(&format!("{O}/ctl"), "new div d")), Some(ErrorKind::UnknownType));
    assert_eq!(
        kind(h.try_write(&format!("{O}/ctl"), "new alert-dialog x variant=sideways")),
        Some(ErrorKind::BadValue)
    );
    h.ctl(R, "new div more style='w=60 h=24'");
    h.ctl(O, "new popover pop anchor=root/more placement=bottom-start trigger=click");
    assert_eq!(
        kind(h.try_write(&format!("{O}/ctl"), "new popover pop2 anchor=root/nope")),
        Some(ErrorKind::NotFound)
    );
    assert_eq!(
        kind(h.try_write(&format!("{O}/pop/placement"), "under")),
        Some(ErrorKind::BadValue)
    );
    let ctl = h.read(&format!("{O}/pop/ctl")).unwrap();
    assert!(ctl.contains("open\n") && ctl.contains("close\n"), "{ctl}");
}

#[gpui::test]
fn dialog_open_close_verbs(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(O, "new dialog about title=About width=420 modal=on keyboard=on");
    let d = format!("{O}/about");
    h.ctl(&d, "new text body text='gpuifs 0.1'\nnew div footer style='h_flex justify_end'");
    h.ctl(&format!("{d}/footer"), "new text ok text=OK tag=about-ok");
    assert_eq!(open_file(&h, "about"), "off");
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    // `open` in the same write as `new` works too.
    h.write(&format!("{d}/ctl"), "open");
    assert_eq!(open_file(&h, "about"), "on");
    let [_, _, w, hh] = h.bounds(&d);
    // `bounds` is the box inside the 1px border.
    assert!((w - 420.).abs() <= 2., "{w}");
    assert!(hh > 40.);
    assert!(h.bounds(&format!("{d}/footer/ok"))[2] > 0., "footer drawn");
    assert!(h.bounds(&format!("{d}/body"))[2] > 0., "body drawn");
    assert_eq!(h.read(&format!("{W}/focus")).as_deref(), Some("overlays/about"));
    h.write(&format!("{d}/ctl"), "close");
    assert_eq!(open_file(&h, "about"), "off");
    // Client verbs send no events.
    assert!(h.events(&mut ev).is_empty());
    // The tree document leaves out `open`.
    let doc = h.read(&format!("{d}/tree")).unwrap();
    assert!(!doc.contains("open"), "{doc}");
}

#[gpui::test]
fn new_then_open_in_one_write(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(O, "new dialog hi title=Welcome width=320");
    h.write(&format!("{O}/hi/ctl"), "open");
    assert_eq!(open_file(&h, "hi"), "on");
}

#[gpui::test]
fn dialog_escape_asks_to_close(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(O, "new dialog d title=Edit keyboard=on tag=dlg");
    let d = format!("{O}/d");
    h.write(&format!("{d}/ctl"), "open");
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    h.keys("main", "escape");
    let lines = h.events(&mut ev);
    let req = lines
        .iter()
        .find(|l| l.starts_with("close ") && l.contains("node=overlays/d") && l.contains("tag=dlg"))
        .unwrap_or_else(|| panic!("{lines:?}"))
        .clone();
    h.ctl(&d, &format!("keep seq={}", seq_of(&req)));
    assert_eq!(open_file(&h, "d"), "on");
    // The close button asks too; this time answer close.
    click_part(&mut h, &format!("{d}#close"));
    let lines = h.events(&mut ev);
    let req = lines.iter().find(|l| l.starts_with("close ")).unwrap_or_else(|| panic!("{lines:?}"));
    h.ctl(&d, &format!("close seq={}", seq_of(req)));
    assert_eq!(open_file(&h, "d"), "off");
}

#[gpui::test]
fn dialog_overlay_click_with_no_reader_closes(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(O, "new dialog d title=Edit width=300");
    h.write(&format!("{O}/d/ctl"), "open");
    // The backdrop, well away from the panel.
    click_at(&mut h, "main", 790., 590.);
    h.settle();
    assert_eq!(open_file(&h, "d"), "off");
}

#[gpui::test]
fn dialog_overlay_closable_off(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(O, "new dialog d title=Edit width=300 overlay_closable=off");
    h.write(&format!("{O}/d/ctl"), "open");
    click_at(&mut h, "main", 790., 590.);
    h.settle();
    assert_eq!(open_file(&h, "d"), "on");
}

#[gpui::test]
fn alert_dialog_confirm_and_cancel(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(
        O,
        "new alert-dialog confirm-del title='Delete 3 files?' description='This cannot be undone.' confirm=Delete cancel=Keep variant=danger tag=del",
    );
    let a = format!("{O}/confirm-del");
    let doc = h.read(&format!("{a}/tree")).unwrap();
    assert_eq!(
        doc.trim_end(),
        "alert-dialog confirm-del  title='Delete 3 files?'  description='This cannot be undone.'  confirm=Delete  cancel=Keep  variant=danger  tag=del"
    );
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    h.write(&format!("{a}/ctl"), "open");
    click_part(&mut h, &format!("{a}#confirm"));
    let lines = h.events(&mut ev);
    assert!(
        lines.iter().any(|l| l.starts_with("confirm win=main node=overlays/confirm-del tag=del")),
        "{lines:?}"
    );
    assert_eq!(open_file(&h, "confirm-del"), "off");
    h.write(&format!("{a}/ctl"), "open");
    click_part(&mut h, &format!("{a}#cancel"));
    let lines = h.events(&mut ev);
    assert!(lines.iter().any(|l| l.starts_with("cancel ")), "{lines:?}");
    // Esc cancels.
    h.write(&format!("{a}/ctl"), "open");
    h.keys("main", "escape");
    let lines = h.events(&mut ev);
    assert!(lines.iter().any(|l| l.starts_with("cancel ")), "{lines:?}");
    assert_eq!(open_file(&h, "confirm-del"), "off");
}

#[gpui::test]
fn sheet_sides_and_close(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(O, "new sheet s side=right size=360 title=Filters");
    let s = format!("{O}/s");
    h.ctl(&s, "new text body text=hello");
    h.write(&format!("{s}/ctl"), "open");
    let [x, _, w, hh] = h.bounds(&s);
    assert!((x - 440.).abs() <= 1. && (w - 360.).abs() <= 1. && hh == 600., "{x} {w} {hh}");
    h.write(&format!("{s}/side"), "bottom");
    h.settle();
    let [x, y, w, hh] = h.bounds(&s);
    assert!(x == 0. && (y - 240.).abs() <= 1. && w == 800. && (hh - 360.).abs() <= 1., "{x} {y} {w} {hh}");
    // Overlay click asks; with no reader the default closes.
    click_at(&mut h, "main", 400., 20.);
    h.settle();
    assert_eq!(open_file(&h, "s"), "off");
}

#[gpui::test]
fn popover_toggles_on_its_anchor(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div more style='w=60 h=24 bg=primary'");
    h.write(&format!("{R}/more/on"), "click");
    h.ctl(O, "new popover pop anchor=root/more placement=bottom-start trigger=click tag=pop");
    h.ctl(&format!("{O}/pop"), "new text t text='Hello from a popover'");
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    h.click(&format!("{R}/more"));
    let lines = h.events(&mut ev);
    assert!(lines.iter().any(|l| l.starts_with("click ") && l.contains("node=root/more")), "anchor keeps its click: {lines:?}");
    assert!(lines.iter().any(|l| l.starts_with("open ") && l.contains("node=overlays/pop") && l.contains("tag=pop")), "{lines:?}");
    assert_eq!(open_file(&h, "pop"), "on");
    // Placed below the anchor, left edges aligned.
    let [ax, ay, _, ah] = h.bounds(&format!("{R}/more"));
    let [px_, py, pw, _] = h.bounds(&format!("{O}/pop"));
    assert_eq!(px_, ax);
    assert!(py >= ay + ah, "{py} below {ay}+{ah}");
    assert!(pw > 0.);
    // A click inside the panel keeps it open; outside closes it.
    h.click(&format!("{O}/pop/t"));
    assert_eq!(open_file(&h, "pop"), "on");
    click_at(&mut h, "main", 700., 500.);
    let lines = h.events(&mut ev);
    assert!(lines.iter().any(|l| l.starts_with("close ") && l.contains("node=overlays/pop")), "{lines:?}");
    assert_eq!(open_file(&h, "pop"), "off");
    // The anchor toggles: open, then closed.
    h.click(&format!("{R}/more"));
    assert_eq!(open_file(&h, "pop"), "on");
    h.click(&format!("{R}/more"));
    assert_eq!(open_file(&h, "pop"), "off");
}

#[gpui::test]
fn popover_escape_closes(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div more style='w=60 h=24'");
    h.ctl(O, "new popover pop anchor=root/more");
    h.write(&format!("{O}/pop/ctl"), "open");
    assert_eq!(open_file(&h, "pop"), "on");
    h.keys("main", "escape");
    assert_eq!(open_file(&h, "pop"), "off");
}

#[gpui::test]
fn hover_card_opens_after_its_delay(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div who style='w=80 h=24'\nnew div away style='w=80 h=24'");
    h.ctl(O, "new hover-card card anchor=root/who open_delay=200 close_delay=100");
    h.ctl(&format!("{O}/card"), "new text t text='@progrium'");
    // GPUI's test scheduler runs timers once nothing else is ready, so the
    // delay itself isn't observable here; the timer path is.
    h.hover(&format!("{R}/who"));
    h.cx.executor().advance_clock(Duration::from_millis(250));
    h.settle();
    assert_eq!(open_file(&h, "card"), "on");
    // Away from both the anchor and the card (which covers `away`).
    {
        let mut v = h.visual("main");
        v.simulate_mouse_move(point(px(700.), px(500.)), None, Modifiers::none());
    }
    h.settle();
    h.cx.executor().advance_clock(Duration::from_millis(150));
    h.settle();
    assert_eq!(open_file(&h, "card"), "off");
}

#[gpui::test]
fn context_menu_on_right_click(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div list style='w=300 h=200'");
    h.ctl(O, "new context-menu menu anchor=root/list tag=ctx");
    let m = format!("{O}/menu");
    h.write(
        &format!("{m}/menu"),
        "item open label=Open key=enter\nitem rename label=Rename\nsep\nsub more label=More\n  item dup label=Duplicate\nitem del label=Delete\n",
    );
    h.ctl("", "set rename enabled=off");
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    let [x, y, _, _] = h.bounds(&format!("{R}/list"));
    {
        let mut v = h.visual("main");
        let p = point(px(x + 30.), px(y + 40.));
        v.simulate_mouse_move(p, None, Modifiers::none());
        v.simulate_mouse_down(p, MouseButton::Right, Modifiers::none());
        v.simulate_mouse_up(p, MouseButton::Right, Modifiers::none());
    }
    h.settle();
    assert_eq!(open_file(&h, "menu"), "on");
    let [mx, my, _, _] = h.bounds(&m);
    assert_eq!((mx, my), (x + 30., y + 40.), "the menu opens at the pointer");
    // A disabled item does nothing.
    click_part(&mut h, &format!("{m}#item:rename"));
    assert_eq!(open_file(&h, "menu"), "on");
    click_part(&mut h, &format!("{m}#item:dup"));
    let lines = h.events(&mut ev);
    assert!(
        lines.iter().any(|l| l.starts_with("action win=main node=overlays/menu tag=ctx id=dup")),
        "{lines:?}"
    );
    assert_eq!(open_file(&h, "menu"), "off");
}
