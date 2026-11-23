//! W6d layout-group render tests on GPUI's test platform.

use gpui::{Modifiers, TestAppContext, point, px};

use super::dock::DockNode;
use crate::testing::Harness;

const R: &str = "windows/main/root";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=800,600");
    h.write(&format!("{R}/style"), "v_flex size_full p=8 gap=4");
    h
}

fn has(lines: &[String], start: &str, parts: &[&str]) -> bool {
    lines
        .iter()
        .any(|l| l.starts_with(start) && parts.iter().all(|p| l.contains(p)))
}

fn click_at(h: &mut Harness, x: f32, y: f32) {
    let mut v = h.visual("main");
    let p = point(px(x), px(y));
    v.simulate_mouse_move(p, None, Modifiers::none());
    v.simulate_click(p, Modifiers::none());
    h.settle();
}

#[gpui::test]
fn accordion_click_opens_an_item(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        &format!("{R}/tree"),
        "div root  style='v_flex size_full p=8'\n\
         \x20 accordion a  style=w=400\n\
         \x20   accordion-item one  title=One\n\
         \x20     text t  text=First\n\
         \x20   accordion-item two  title=Two\n\
         \x20     text t  text=Second\n",
    );
    let a = format!("{R}/a");
    let [x, y, w, hh] = h.bounds(&a);
    assert!(w > 0. && hh > 0.);
    // Both closed: two headers of equal height. Click the second.
    let mut ev = h.subscribe(&format!("{a}/events"));
    click_at(&mut h, x + w / 2., y + hh * 0.75);
    let lines = h.events(&mut ev);
    assert_eq!(
        h.read(&format!("{a}/value")).as_deref(),
        Some("two"),
        "{lines:?}"
    );
    assert!(
        has(&lines, "change ", &["value=two", "via=user"]),
        "{lines:?}"
    );
    // The open item's content is drawn.
    let [_, _, _, th] = h.bounds(&format!("{a}/two/t"));
    assert!(th > 0.);
    // A client write changes what is open, with no user event.
    h.write(&format!("{a}/value"), "one");
    let lines = h.events(&mut ev);
    assert!(!has(&lines, "change ", &["via=user"]), "{lines:?}");
    assert!(
        h.try_write(&format!("{a}/ctl"), "new text stray").is_err(),
        "children are items"
    );
}

#[gpui::test]
fn collapsible_trigger_toggles_open(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        &format!("{R}/tree"),
        "div root  style='v_flex size_full p=8'\n\
         \x20 collapsible more\n\
         \x20   div trigger  style='h=24 w=120'\n\
         \x20     text t  text=Details\n\
         \x20   div content  style=h=100\n\
         \x20     text t  text=Hidden\n",
    );
    let c = format!("{R}/more");
    let mut ev = h.subscribe(&format!("{c}/events"));
    h.click(&format!("{c}/trigger"));
    let lines = h.events(&mut ev);
    assert_eq!(
        h.read(&format!("{c}/open")).as_deref(),
        Some("on"),
        "{lines:?}"
    );
    assert!(has(&lines, "change ", &["value=on"]), "{lines:?}");
    let [_, _, _, hh] = h.bounds(&format!("{c}/content"));
    assert!(hh > 0.);
    h.click(&format!("{c}/trigger"));
    assert_eq!(h.read(&format!("{c}/open")).as_deref(), Some("off"));
}

#[gpui::test]
fn group_box_separator_and_grid_lay_out(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        &format!("{R}/tree"),
        "div root  style='v_flex size_full p=8 gap=8'\n\
         \x20 group-box g  title=Startup  style=outline\n\
         \x20   text t  text=Inside\n\
         \x20 separator s  label=or\n\
         \x20 div row  style='h_flex h=40'\n\
         \x20   text a  text=A\n\
         \x20   separator v  dir=v\n\
         \x20   text b  text=B\n\
         \x20 grid keys  cols=3  gap=4  style=w=300\n\
         \x20   div k1  style=h=20\n\
         \x20   div k2  style=h=20\n\
         \x20   div k3  style=h=20\n\
         \x20   div k4  style='h=20 col_span=2'\n",
    );
    let g = |n: &str| format!("{R}/{n}");
    assert!(h.bounds(&g("g"))[3] > 0.);
    assert!(h.bounds(&g("g/t"))[3] > 0.);
    assert!(h.bounds(&g("s"))[2] > 100.);
    assert!(h.bounds(&g("row/v"))[3] > 10.);
    let k1 = h.bounds(&g("keys/k1"));
    let k2 = h.bounds(&g("keys/k2"));
    let k4 = h.bounds(&g("keys/k4"));
    assert!(
        k2[0] > k1[0] && (k2[1] - k1[1]).abs() < 0.5,
        "{k1:?} {k2:?}"
    );
    assert!(k4[1] > k1[1], "fourth key wraps: {k4:?}");
    assert!(k4[2] > k1[2] * 1.5, "col_span=2: {k4:?}");
    assert!(h.try_write(&g("g/style"), "fill").is_ok());
    assert!(h.try_write(&g("g/style"), "primary").is_err());
}

#[gpui::test]
fn resizable_panels_take_sizes(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        &format!("{R}/tree"),
        "div root  style='v_flex size_full p=8'\n\
         \x20 resizable r  dir=h  style='h=200 w=600'\n\
         \x20   panel a  size=150  min=100\n\
         \x20     div x  style='size_full bg=muted'\n\
         \x20   panel b\n\
         \x20     text t  text=Right\n",
    );
    let r = format!("{R}/r");
    let a = h.bounds(&format!("{r}/a"));
    let b = h.bounds(&format!("{r}/b"));
    assert!((a[2] - 150.).abs() < 2., "{a:?}");
    assert!(b[0] >= a[0] + a[2] - 1. && b[2] > 300., "{b:?}");
    let mut ev = h.subscribe(&format!("{r}/events"));
    h.write(&format!("{r}/a/size"), "220");
    h.settle();
    let a = h.bounds(&format!("{r}/a"));
    assert!((a[2] - 220.).abs() < 2., "{a:?}");
    let lines = h.events(&mut ev);
    assert!(!has(&lines, "resize ", &[]), "{lines:?}");
    assert!(h.try_write(&format!("{r}/ctl"), "new div stray").is_err());
}

const DOCK: &str = "div root  style='v_flex size_full'\n\
    \x20 dock ws  style=flex_1\n\
    \x20   dock-panel files  title=Files  icon=folder  zone=left\n\
    \x20     text t  text=tree\n\
    \x20   dock-panel src  title=main.rs  zone=center\n\
    \x20     editor e  style=size_full\n\
    \x20   dock-panel out  title=Output  zone=bottom  closable=on\n\
    \x20     text t  text=log\n";

fn dock(h: &Harness) -> gpui::Entity<DockNode> {
    let p = format!("{R}/ws");
    let n = h.node(&p);
    let st = n
        .host
        .states
        .borrow()
        .get(&p)
        .and_then(|s| s.entity.clone());
    super::entity::<DockNode>(st.as_ref()).expect("dock state")
}

#[gpui::test]
fn dock_shows_panels_and_mirrors_layout(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(&format!("{R}/tree"), DOCK);
    let d = format!("{R}/ws");
    let layout = h.read(&format!("{d}/layout")).unwrap();
    assert!(layout.contains("uitreefs.dock-panel"), "{layout}");
    for id in ["files", "src", "out"] {
        assert!(
            layout.contains(&format!("\"id\":\"{id}\"")),
            "{id}: {layout}"
        );
    }
    // Every panel's content is drawn through the host.
    for p in ["files/t", "src/e", "out/t"] {
        let [_, _, w, hh] = h.bounds(&format!("{d}/{p}"));
        assert!(w > 0. && hh > 0., "{p}");
    }
    let [fx, _, _, _] = h.bounds(&format!("{d}/files/t"));
    let [sx, _, _, _] = h.bounds(&format!("{d}/src/e"));
    assert!(fx < sx, "files dock is left of the center");

    // Writing the layout back restores it as it was.
    h.write(&format!("{d}/layout"), &layout);
    assert_eq!(h.read(&format!("{d}/layout")).unwrap(), layout);
    assert!(h.bounds(&format!("{d}/src/e"))[2] > 0.);
    // A bad layout is ignored.
    assert!(h.try_write(&format!("{d}/layout"), "{not json").is_err());
    assert_eq!(h.read(&format!("{d}/layout")).unwrap(), layout);
    // An empty layout resets to the zones.
    h.write(&format!("{d}/layout"), "");
    assert!(
        h.read(&format!("{d}/layout"))
            .unwrap()
            .contains("\"id\":\"out\"")
    );
}

#[gpui::test]
fn dock_adds_and_drops_panels_with_the_tree(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(&format!("{R}/tree"), DOCK);
    let d = format!("{R}/ws");
    h.ctl(&d, "new dock-panel more title=More zone=right");
    h.ctl(&format!("{d}/more"), "new text t text=extra");
    h.settle();
    assert!(
        h.read(&format!("{d}/layout"))
            .unwrap()
            .contains("\"id\":\"more\"")
    );
    assert!(h.bounds(&format!("{d}/more/t"))[2] > 0.);
    h.ctl(&d, "delete files");
    h.settle();
    assert!(
        !h.read(&format!("{d}/layout"))
            .unwrap()
            .contains("\"id\":\"files\"")
    );
}

#[gpui::test]
fn dock_close_is_a_request_and_keep_brings_it_back(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(&format!("{R}/tree"), DOCK);
    let d = format!("{R}/ws");
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    // The user closes the Output tab.
    let e = dock(&h);
    h.cx.update(|cx| {
        let area = e.read(cx).area.clone();
        let p = e.read(cx).shared_panel("out").unwrap();
        let win = h.window("main");
        win.update(cx, |_, window, cx| {
            area.update(cx, |a, cx| a.remove_panel(p, window, cx));
        })
        .unwrap();
    });
    h.settle();
    let lines = h.events(&mut ev);
    let line = lines
        .iter()
        .find(|l| l.starts_with("panel-close "))
        .unwrap_or_else(|| panic!("{lines:?}"));
    assert!(
        line.contains(" ws win=") && line.contains("id=out"),
        "{line}"
    );
    assert!(
        !h.read(&format!("{d}/layout"))
            .unwrap()
            .contains("\"id\":\"out\"")
    );
    let seq = line
        .split_whitespace()
        .find_map(|w| w.strip_prefix("seq="))
        .unwrap()
        .to_string();
    h.ctl(&d, &format!("keep seq={seq}"));
    h.settle();
    assert!(
        h.read(&format!("{d}/layout"))
            .unwrap()
            .contains("\"id\":\"out\"")
    );
    // A late answer to the same request fails.
    assert!(
        h.try_write(&format!("{d}/ctl"), &format!("close seq={seq}"))
            .is_err()
    );
}

#[gpui::test]
fn dock_panel_activate_reopens(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(&format!("{R}/tree"), DOCK);
    let d = format!("{R}/ws");
    // No events reader: a user close applies its default at once.
    let e = dock(&h);
    h.cx.update(|cx| {
        let area = e.read(cx).area.clone();
        let p = e.read(cx).shared_panel("out").unwrap();
        h.window("main")
            .update(cx, |_, window, cx| {
                area.update(cx, |a, cx| a.remove_panel(p, window, cx))
            })
            .unwrap();
    });
    h.settle();
    assert!(
        !h.read(&format!("{d}/layout"))
            .unwrap()
            .contains("\"id\":\"out\"")
    );
    h.ctl(&format!("{d}/out"), "activate");
    h.settle();
    assert!(
        h.read(&format!("{d}/layout"))
            .unwrap()
            .contains("\"id\":\"out\"")
    );
    assert!(h.try_write(&format!("{d}/out/zone"), "top").is_err());
}

#[gpui::test]
fn resizable_drag_sends_one_resize(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        &format!("{R}/tree"),
        "div root  style='v_flex size_full p=8'\n\
         \x20 resizable r  dir=h  style='h=200 w=600'\n\
         \x20   panel a  size=150\n\
         \x20   panel b\n",
    );
    let r = format!("{R}/r");
    let a = h.bounds(&format!("{r}/a"));
    let mut ev = h.subscribe(&format!("{r}/events"));
    let (x, y) = (a[0] + a[2], a[1] + a[3] / 2.);
    let mut v = h.visual("main");
    v.simulate_mouse_move(point(px(x), px(y)), None, Modifiers::none());
    v.simulate_mouse_down(
        point(px(x), px(y)),
        gpui::MouseButton::Left,
        Modifiers::none(),
    );
    for dx in [10., 30., 50.] {
        v.simulate_mouse_move(
            point(px(x + dx), px(y)),
            Some(gpui::MouseButton::Left),
            Modifiers::none(),
        );
    }
    v.simulate_mouse_up(
        point(px(x + 50.), px(y)),
        gpui::MouseButton::Left,
        Modifiers::none(),
    );
    h.settle();
    let lines = h.events(&mut ev);
    let a2 = h.bounds(&format!("{r}/a"));
    assert!(a2[2] > a[2] + 20., "{a:?} -> {a2:?} {lines:?}");
    assert_eq!(
        lines.iter().filter(|l| l.starts_with("resize ")).count(),
        1,
        "{lines:?}"
    );
    assert!(has(&lines, "resize ", &["sizes="]), "{lines:?}");
    let size: f32 = h.read(&format!("{r}/a/size")).unwrap().parse().unwrap();
    assert!((size - a2[2]).abs() < 2., "{size} vs {a2:?}");
}

/// The gallery stories for this group build under the tree's rules.
#[gpui::test]
fn gallery_stories_load(cx: &mut TestAppContext) {
    let mut h = window(cx);
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples/rc/gallery");
    h.ctl(R, "new scroll story");
    for story in ["accordion", "resizable", "editor", "markdown"] {
        let doc = std::fs::read_to_string(format!("{dir}/{story}/tree")).unwrap();
        h.write(&format!("{R}/story/tree"), &doc);
        let [_, _, w, hh] = h.bounds(&format!("{R}/story"));
        assert!(w > 0. && hh > 0., "{story}");
    }
}

#[gpui::test]
fn dock_user_edits_send_layout(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(&format!("{R}/tree"), DOCK);
    let d = format!("{R}/ws");
    let before = h.read(&format!("{d}/layout")).unwrap();
    let mut ev = h.subscribe(&format!("{d}/events"));
    h.events(&mut ev);
    // The user collapses the bottom dock.
    let e = dock(&h);
    h.cx.update(|cx| {
        let area = e.read(cx).area.clone();
        h.window("main")
            .update(cx, |_, window, cx| {
                area.update(cx, |a, cx| {
                    a.toggle_dock(gpui_component::dock::DockPlacement::Bottom, window, cx)
                })
            })
            .unwrap();
    });
    h.settle();
    let lines = h.events(&mut ev);
    assert!(has(&lines, "layout ", &["via=user"]), "{lines:?}");
    assert_ne!(h.read(&format!("{d}/layout")).unwrap(), before);
}
