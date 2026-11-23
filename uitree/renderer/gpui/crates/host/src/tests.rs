//! Render tests for the host and the element tier, on GPUI's test platform,
//! against the real core over 9P (spec 0.2 spelling).
//!
//! The uitreefs host tests, ported; the component groups have their own.

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

#[gpui::test]
fn click_and_hover_send_events_with_tag(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div card tag=open:42 : w=100 h=40");
    h.write(&format!("{M}/card/on"), "click hover");
    let mut ev = h.subscribe("events");
    h.click(&format!("{M}/card"));
    let lines = h.events(&mut ev);
    assert!(
        lines
            .iter()
            .any(|l| l.starts_with("click open:42 card win=main ")),
        "{lines:?}"
    );
    assert!(lines.iter().any(|l| l.starts_with("hover ") && l.contains("value=on")), "{lines:?}");
}

#[gpui::test]
fn key_events_and_focus_file(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div k : w=100 h=40");
    h.write(&format!("{M}/k/on"), "key focus click");
    let mut ev = h.subscribe("events");
    h.click(&format!("{M}/k"));
    assert_eq!(h.read(&format!("{M}/focus")).as_deref(), Some("k"));
    h.keys("main", "a");
    let lines = h.events(&mut ev);
    assert!(lines.iter().any(|l| l.starts_with("focus ")), "{lines:?}");
    assert!(lines.iter().any(|l| l.starts_with("key - k win=main") && l.contains(" key=a")), "{lines:?}");
}

#[gpui::test]
fn focus_file_write_moves_focus(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div a : w=10 h=10\nnew div b : w=10 h=10");
    h.write(&format!("{M}/b/on"), "focus");
    h.write(&format!("{M}/focus"), "b");
    assert_eq!(h.read(&format!("{M}/focus")).as_deref(), Some("b"));
}

#[gpui::test]
fn keymap_context_limits_binding(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new div ed : w=50 h=50\nnew div other : w=50 h=50");
    h.write(&format!("{M}/ed/context"), "editor");
    h.write(&format!("{M}/ed/on"), "key focus");
    h.write(&format!("{M}/other/on"), "key focus");
    h.write("keys", "ctrl-e escape-ed context=editor\n");
    let mut ev = h.subscribe("events");
    h.write(&format!("{M}/focus"), "other");
    h.keys("main", "ctrl-e");
    assert!(!h.events(&mut ev).iter().any(|l| l.starts_with("action escape-ed ")));
    h.write(&format!("{M}/focus"), "ed");
    h.keys("main", "ctrl-e");
    let lines = h.events(&mut ev);
    assert!(
        lines.iter().any(|l| l.starts_with("action escape-ed ed win=main")),
        "{lines:?}"
    );
}

#[gpui::test]
fn disabled_action_sends_nothing(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write("keys", "ctrl-s save\n");
    h.ctl("", "set save enabled=off");
    let mut ev = h.subscribe("events");
    h.keys("main", "ctrl-s");
    assert!(!h.events(&mut ev).iter().any(|l| l.starts_with("action save ")));
}

#[gpui::test]
fn window_close_without_reader_closes(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl("", "window other");
    // A new window stays hidden until it has content or is shown.
    h.ctl("win/other", "show");
    assert!(h.has_window("other"));
    h.ctl("win/other", "close");
    h.settle();
    assert!(!h.has_window("other"));
    assert!(h.has_window("main"));
}

#[gpui::test]
fn window_destroy(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl("", "window other");
    h.ctl("win/other", "show");
    assert!(h.has_window("other"));
    h.ctl("win/other", "destroy");
    assert!(!h.has_window("other"));
}

#[gpui::test]
fn window_verbs_dont_panic(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "set . title=Renamed size=500,400");
    h.ctl(M, "notify 'Saved draft' type=success");
    h.ctl(M, "activate");
}

#[gpui::test]
fn theme_mode_and_tokens(cx: &mut TestAppContext) {
    use gpui_component::ActiveTheme as _;
    let mut h = window(cx);
    h.write("theme/mode", "dark");
    assert!(h.cx.update(|cx| cx.theme().mode.is_dark()));
    h.write("theme/tokens", "primary #ff0000\n");
    let c = h.cx.update(|cx| crate::theme::token(cx, "primary")).unwrap();
    let rgba: gpui::Rgba = c.into();
    assert!(rgba.r > 0.99 && rgba.g < 0.01, "{rgba:?}");
}

#[gpui::test]
fn tree_document_renders(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        &format!("{M}/tree"),
        "div root : v-flex size-full p=24 gap=16\n  text title  text='Sign in' : text-xl font-semibold\n  div row : h-flex gap=8\n    text a  text=A\n",
    );
    let [_, _, w, hh] = h.bounds(&format!("{M}/title"));
    assert!(w > 0. && hh > 0.);
    h.bounds(&format!("{M}/row/a"));
}

#[gpui::test]
fn scroll_origin_round_trips(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(M, "new scroll sc : h=40 w=100 overflow-y-scroll");
    h.ctl(&format!("{M}/sc"), "new div a : h=200 w=100");
    h.write(&format!("{M}/sc/origin"), "0 30");
    let o = h.read(&format!("{M}/sc/origin")).unwrap_or_default();
    assert_eq!(o.trim(), "0 30");
}
