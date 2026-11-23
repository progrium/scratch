//! Canvas render tests on GPUI's test platform.

use gpui::{Modifiers, MouseButton, TestAppContext, point, px};

use crate::testing::Harness;

const R: &str = "win/main";
const C: &str = "win/main/c";

const OPS: &str = "rect   bg      0 0 400 300   fill=background
rect   card    20 20 160 90  fill=muted radius=8 border=border
path   spark   M20,200 L60,180 L100,190 L140,150  stroke=primary width=2 cap=round
circle dot     140 150 4     fill=primary hover:fill=accent
text   lbl     28 44         'Revenue'  size=13 color=muted-foreground weight=bold
image  logo    360 12 24 24  src=@logo
line   axis    0 290 400 290 stroke=#ff000080
path   blob    M300,200 C310,180,330,180,340,200 S370,220,380,200 Q390,190,395,200 T399,200 A5,5,0,0,1,390,210 Z fill=accent
";

fn canvas(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=500,400");
    h.ctl("win/main", "show");
    h.write(&format!("{R}/style"), "v-flex size-full");
    h.ctl(R, "new canvas c : w=400 h=300");
    h
}

/// Window coordinates of a canvas-local point.
fn at(h: &Harness, x: f32, y: f32) -> gpui::Point<gpui::Pixels> {
    let [bx, by, _, _] = h.bounds(C);
    point(px(bx + x), px(by + y))
}

#[gpui::test]
fn ops_render_and_ctl_edits_them(cx: &mut TestAppContext) {
    let mut h = canvas(cx);
    h.write(
        "asset/logo",
        "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'/>",
    );
    h.write(&format!("{C}/ops"), OPS);
    assert_eq!(h.bounds(C)[2..], [400., 300.]);
    h.ctl(C, "update dot 150 140");
    h.ctl(C, "add circle dot2 10 10 3 fill=accent");
    h.ctl(C, "del card");
    h.ctl(C, "raise bg");
    h.ctl(C, "lower dot2");
    let ops = h.read(&format!("{C}/ops")).unwrap();
    let ids: Vec<&str> = ops
        .lines()
        .map(|l| l.split_whitespace().nth(1).unwrap())
        .collect();
    assert_eq!(
        ids,
        ["dot2", "spark", "dot", "lbl", "logo", "axis", "blob", "bg"]
    );
    assert!(ops.contains("circle dot 150 140 4"), "{ops}");
    let e = h
        .try_write(&format!("{C}/ctl"), "update nope 1 1")
        .unwrap_err();
    assert_eq!(e.kind, crate::testing::ErrorKind::NotFound);
    let e = h
        .try_write(&format!("{C}/ctl"), "add rect dot 0 0 1 1")
        .unwrap_err();
    assert_eq!(e.kind, crate::testing::ErrorKind::InUse);
    // Rendering after the edits still works.
    h.settle();
    assert_eq!(h.bounds(C)[2..], [400., 300.]);
}

#[gpui::test]
fn pointer_events_name_the_item(cx: &mut TestAppContext) {
    let mut h = canvas(cx);
    h.write(&format!("{C}/ops"), OPS);
    h.write(&format!("{C}/on"), "mouse-down mouse-up click move drag");
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    let mut v = h.visual("main");
    let p = at(&h, 141., 150.);
    v.simulate_mouse_move(p, None, Modifiers::none());
    v.simulate_mouse_down(p, MouseButton::Left, Modifiers::none());
    let q = at(&h, 200., 250.);
    v.simulate_mouse_move(q, MouseButton::Left, Modifiers::none());
    v.simulate_mouse_up(q, MouseButton::Left, Modifiers::none());
    v.simulate_mouse_down(p, MouseButton::Left, Modifiers::none());
    v.simulate_mouse_up(p, MouseButton::Left, Modifiers::none());
    let lines = h.events(&mut ev);
    let has = |pre: &str| lines.iter().any(|l| l.starts_with(pre));
    assert!(
        has("mouse-down - c win=main item=dot x=141 y=150 button=left"),
        "{lines:?}"
    );
    assert!(
        has("move - c win=main item=dot x=141 y=150"),
        "{lines:?}"
    );
    assert!(
        has("drag - c win=main item=bg x=200 y=250"),
        "{lines:?}"
    );
    assert!(
        has("mouse-up - c win=main item=bg x=200 y=250 button=left"),
        "{lines:?}"
    );
    assert!(
        has("click - c win=main item=dot x=141 y=150 button=left"),
        "{lines:?}"
    );
    // The element-tier listeners don't also fire (no second, item-less copy).
    assert!(
        !lines
            .iter()
            .any(|l| l.starts_with("mouse-down") && !l.contains("item=")),
        "{lines:?}"
    );
}

#[gpui::test]
fn hover_tracks_the_item_under_the_pointer(cx: &mut TestAppContext) {
    let mut h = canvas(cx);
    h.write(&format!("{C}/ops"), OPS);
    let mut v = h.visual("main");
    v.simulate_mouse_move(at(&h, 140., 150.), None, Modifiers::none());
    h.settle();
    let cn = h.node(C).node();
    let st = h
        .inner()
        .states
        .borrow()
        .get(&cn)
        .and_then(|s| s.entity.clone())
        .unwrap();
    let st = st.downcast::<super::CanvasState>().ok().unwrap();
    let hov = h.cx.read(|cx| st.read(cx).hovered.clone());
    assert_eq!(hov.as_deref(), Some("dot"));
    v.simulate_mouse_move(at(&h, 300., 10.), None, Modifiers::none());
    h.settle();
    let hov = h.cx.read(|cx| st.read(cx).hovered.clone());
    assert_eq!(hov.as_deref(), Some("bg"));
}

#[gpui::test]
fn pixels_draw_at_the_canvas_width(cx: &mut TestAppContext) {
    let mut h = canvas(cx);
    let px_data = vec![128u8; 400 * 300 * 4];
    h.try_write_bytes(&format!("{C}/pixels"), &px_data).unwrap();
    h.settle();
    assert_eq!(h.bounds(C)[2..], [400., 300.]);
}

#[gpui::test]
fn a_bad_ops_write_keeps_the_list(cx: &mut TestAppContext) {
    let mut h = canvas(cx);
    h.write(&format!("{C}/ops"), OPS);
    assert!(h.try_write(&format!("{C}/ops"), "blob x 1 2\n").is_err());
    assert_eq!(h.read(&format!("{C}/ops")).unwrap(), OPS);
}
