//! Render tests for the host and the element tier, on GPUI's test platform,
//! against the real core over 9P (spec 0.2 spelling).
//!
//! These cover what the core serves today (the W0 spike's tree: `ctl`
//! with `new`/`set`/`delete`/`quit`, prop files, `keys`, `menu/NAME`, the
//! app `events`). The uitreefs host tests for windows other than `main`,
//! `focus` and `bounds` files, `tree` documents, batches, key contexts and
//! theme files come back as W3 lands those parts of the core.

use gpui::TestAppContext;

use crate::testing::Harness;

const M: &str = "win/main";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    // `main` stays hidden until its root has a child or it is shown.
    h.ctl(M, "set . title=Test size=400,300 : v-flex size-full p=8 gap=4\nshow");
    assert!(h.has_window("main"));
    h
}

#[gpui::test]
fn window_opens_with_its_size(cx: &mut TestAppContext) {
    let h = window(cx);
    let [_, _, w, hh] = h.bounds(M);
    assert_eq!((w, hh), (400., 300.));
}

#[gpui::test]
fn every_element_type_renders(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(
        M,
        "new div box : w=40 h=20 bg=primary hover:bg=accent rounded-md\n\
         new text t text=Hello : text-sm font-semibold\n\
         new img pic : size=16\n\
         new svg vec : size=16 text-color=primary\n\
         new icon ic name=search : text-color=muted-foreground\n\
         new scroll sc : h=50 w=100\n\
         new spacer sp\n\
         new text sc/a text=one : h=40\n\
         new text sc/b text=two : h=40",
    );
    for n in ["box", "t", "pic", "vec", "ic", "sc", "sp", "sc/a"] {
        let [_, _, w, hh] = h.bounds(&format!("{M}/{n}"));
        assert!(w >= 0. && hh >= 0., "{n}");
    }
    assert_eq!(h.bounds(&format!("{M}/box"))[2..], [40., 20.]);
    let [_, _, tw, th] = h.bounds(&format!("{M}/t"));
    assert!(tw > 0. && th > 0., "text has a size");
    assert_eq!(h.bounds(&format!("{M}/pic"))[2..], [16., 16.]);
}

#[gpui::test]
fn click_sends_click_with_tag(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div card tag=open on=click : w=100 h=40");
    let mut ev = h.subscribe("events");
    h.click(&format!("{M}/card"));
    let lines = h.events(&mut ev);
    assert!(lines.iter().any(|l| l.starts_with("click open card win=main ")), "{lines:?}");
}

#[gpui::test]
fn nodes_without_on_send_nothing(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div card : w=100 h=40");
    let mut ev = h.subscribe("events");
    h.click(&format!("{M}/card"));
    let lines = h.events(&mut ev);
    assert!(!lines.iter().any(|l| l.starts_with("click")), "{lines:?}");
}

#[gpui::test]
fn prop_file_write_redraws(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div row : h-flex\nnew text row/n text=0");
    let w0 = h.bounds(&format!("{M}/row/n"))[2];
    h.write(&format!("{M}/row/n/text"), "a much longer label");
    assert_eq!(h.read(&format!("{M}/row/n/text")).as_deref(), Some("a much longer label"));
    assert!(h.bounds(&format!("{M}/row/n"))[2] > w0);
}

#[gpui::test]
fn keys_binding_sends_action(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write("keys", "ctrl-s save\n");
    let mut ev = h.subscribe("events");
    h.keys("main", "ctrl-s");
    let lines = h.events(&mut ev);
    assert!(lines.iter().any(|l| l.starts_with("action save . win=main")), "{lines:?}");
}

#[gpui::test]
fn menu_key_sends_action(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write("menu/File", "item new label=New key=ctrl-n\nsep\nitem quit label=Quit\n");
    h.write("keys", "ctrl-n new\n");
    let mut ev = h.subscribe("events");
    h.keys("main", "ctrl-n");
    assert!(h.events(&mut ev).iter().any(|l| l.starts_with("action new ")));
}

#[gpui::test]
fn restyling_relayouts(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div b : w=10 h=10");
    assert_eq!(h.bounds(&format!("{M}/b"))[2], 10.);
    h.ctl(M, "set b : w=30 h=10");
    assert_eq!(h.bounds(&format!("{M}/b"))[2], 30.);
}

#[gpui::test]
fn deleting_nodes_drops_them(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div b : w=10 h=10");
    h.ctl(M, "delete b");
    assert!(h.inner().node_at("main/b").is_none());
}

#[gpui::test]
fn bordered_bounds_include_the_border(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div b : w=40 h=20 border-1 border-color=border\nnew div c : w=40 h=20 border-2 border-l=4");
    assert_eq!(h.bounds(&format!("{M}/b"))[2..], [40., 20.]);
    assert_eq!(h.bounds(&format!("{M}/c"))[2..], [40., 20.]);
    assert_eq!(h.bounds(&format!("{M}/b"))[0], h.bounds(&format!("{M}/c"))[0]);
}

#[gpui::test]
fn quit_ends_the_app(cx: &mut TestAppContext) {
    let mut h = window(cx);
    let mut ev = h.subscribe("events");
    h.ctl("", "quit");
    assert!(h.quit_called());
    assert!(h.events(&mut ev).contains(&"<eof>".to_string()));
}
