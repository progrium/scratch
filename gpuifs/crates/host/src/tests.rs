//! Render tests for the host core and the element tier, on GPUI's test platform.

use gpui::TestAppContext;

use crate::testing::Harness;

const W: &str = "windows/main";
const R: &str = "windows/main/root";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=400,300");
    assert!(h.has_window("main"));
    h.write(&format!("{R}/style"), "v_flex size_full p=8 gap=4");
    h
}

#[gpui::test]
fn window_renders_root_and_reports_bounds(cx: &mut TestAppContext) {
    let h = window(cx);
    let [_, _, w, hh] = h.bounds(R);
    assert_eq!((w, hh), (400., 300.));
    assert_eq!(h.read(&format!("{W}/state")).as_deref(), Some("normal"));
}

#[gpui::test]
fn every_element_type_renders(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(
        R,
        "new div box style='w=40 h=20 bg=primary hover:bg=accent rounded_md'\n\
         new text t text=Hello style='text_sm font_semibold'\n\
         new styled-text st text='let x = 1'\n\
         new img pic style='size=16'\n\
         new svg vec style='size=16 text_color=primary'\n\
         new icon ic name=search style='sm text_color=muted_foreground'\n\
         new scroll sc style='h=50 w=100'\n\
         new spacer sp",
    );
    h.write(&format!("{R}/st/runs"), "0 3 text_color=primary font_bold\n");
    h.ctl(&format!("{R}/sc"), "new text a text=one style=h=40\nnew text b text=two style=h=40");
    for n in ["box", "t", "st", "pic", "vec", "ic", "sc", "sp", "sc/a"] {
        let [_, _, w, hh] = h.bounds(&format!("{R}/{n}"));
        assert!(w >= 0. && hh >= 0., "{n}");
    }
    assert_eq!(h.bounds(&format!("{R}/box"))[2..], [40., 20.]);
    let [_, _, tw, th] = h.bounds(&format!("{R}/t"));
    assert!(tw > 0. && th > 0., "text has a size");
    assert_eq!(h.bounds(&format!("{R}/pic"))[2..], [16., 16.]);
}

#[gpui::test]
fn click_and_hover_send_events_with_tag(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div card style='w=100 h=40' tag=open:42");
    h.write(&format!("{R}/card/on"), "click hover");
    let mut ev = h.subscribe("events");
    h.click(&format!("{R}/card"));
    let lines = h.events(&mut ev);
    assert!(
        lines
            .iter()
            .any(|l| l.starts_with("click ") && l.contains("node=root/card") && l.contains("tag=open:42")),
        "{lines:?}"
    );
    assert!(lines.iter().any(|l| l.starts_with("hover ") && l.contains("value=on")), "{lines:?}");
}

#[gpui::test]
fn nodes_without_on_send_nothing(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div card style='w=100 h=40'");
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    h.click(&format!("{R}/card"));
    let lines = h.events(&mut ev);
    assert!(!lines.iter().any(|l| l.starts_with("click")), "{lines:?}");
}

#[gpui::test]
fn key_events_and_focus_file(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div k style='w=100 h=40'");
    h.write(&format!("{R}/k/on"), "key focus click");
    let mut ev = h.subscribe("events");
    h.click(&format!("{R}/k"));
    assert_eq!(h.read(&format!("{W}/focus")).as_deref(), Some("root/k"));
    h.keys("main", "a");
    let lines = h.events(&mut ev);
    assert!(lines.iter().any(|l| l.starts_with("focus ")), "{lines:?}");
    assert!(lines.iter().any(|l| l.starts_with("key ") && l.contains("key=a")), "{lines:?}");
}

#[gpui::test]
fn focus_file_write_moves_focus(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div a style='w=10 h=10'\nnew div b style='w=10 h=10'");
    h.write(&format!("{R}/b/on"), "focus");
    h.write(&format!("{W}/focus"), "root/b");
    assert_eq!(h.read(&format!("{W}/focus")).as_deref(), Some("root/b"));
}

#[gpui::test]
fn keymap_binding_sends_action(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write("keymap", "ctrl-s save\n");
    let mut ev = h.subscribe("events");
    h.keys("main", "ctrl-s");
    let lines = h.events(&mut ev);
    assert!(
        lines.iter().any(|l| l.starts_with("action ") && l.contains("id=save") && l.contains("win=main")),
        "{lines:?}"
    );
}

#[gpui::test]
fn keymap_context_limits_binding(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div ed style='w=50 h=50'\nnew div other style='w=50 h=50'");
    h.write(&format!("{R}/ed/context"), "editor");
    h.write(&format!("{R}/ed/on"), "key focus");
    h.write(&format!("{R}/other/on"), "key focus");
    h.write("keymap", "ctrl-e escape-ed context=editor\n");
    let mut ev = h.subscribe("events");
    h.write(&format!("{W}/focus"), "root/other");
    h.keys("main", "ctrl-e");
    assert!(!h.events(&mut ev).iter().any(|l| l.contains("id=escape-ed")));
    h.write(&format!("{W}/focus"), "root/ed");
    h.keys("main", "ctrl-e");
    let lines = h.events(&mut ev);
    assert!(
        lines.iter().any(|l| l.contains("id=escape-ed") && l.contains("focus=root/ed")),
        "{lines:?}"
    );
}

#[gpui::test]
fn disabled_action_sends_nothing(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write("keymap", "ctrl-s save\n");
    h.ctl("", "set save enabled=off");
    let mut ev = h.subscribe("events");
    h.keys("main", "ctrl-s");
    assert!(!h.events(&mut ev).iter().any(|l| l.contains("id=save")));
}

#[gpui::test]
fn menus_build(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        "menus/File",
        "item new label=New key=ctrl-n\nsep\nsub recent label='Open Recent'\n  item r1 label=One\nitem quit label=Quit\n",
    );
    let mut ev = h.subscribe("events");
    h.keys("main", "ctrl-n");
    assert!(h.events(&mut ev).iter().any(|l| l.contains("id=new")));
}

#[gpui::test]
fn window_close_without_reader_closes(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl("", "window other");
    assert!(h.has_window("other"));
    h.ctl("windows/other", "close");
    h.settle();
    assert!(!h.has_window("other"));
    assert!(h.has_window("main"));
}

#[gpui::test]
fn window_destroy(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl("", "window other");
    h.ctl("windows/other", "destroy");
    assert!(!h.has_window("other"));
}

#[gpui::test]
fn window_verbs_dont_panic(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(W, "title Renamed");
    h.ctl(W, "size 500,400");
    h.ctl(W, "notify 'Saved draft' type=success");
    h.ctl(W, "activate");
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
fn rewriting_style_relayouts(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div b style='w=10 h=10'");
    assert_eq!(h.bounds(&format!("{R}/b"))[2], 10.);
    h.write(&format!("{R}/b/style"), "w=30 h=10");
    assert_eq!(h.bounds(&format!("{R}/b"))[2], 30.);
}

#[gpui::test]
fn removing_nodes_drops_them(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new div b style='w=10 h=10'");
    h.ctl(R, "delete b");
    assert!(h.read(&format!("{R}/b/type")).is_none());
}

#[gpui::test]
fn tree_document_renders(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        &format!("{R}/tree"),
        "div root  style='v_flex size_full p=24 gap=16'\n  text title  style='text_xl font_semibold'  text='Sign in'\n  div row  style='h_flex gap=8'\n    text a  text=A\n",
    );
    let [_, _, w, hh] = h.bounds(&format!("{R}/title"));
    assert!(w > 0. && hh > 0.);
    h.bounds(&format!("{R}/row/a"));
}

#[gpui::test]
fn batch_freezes_then_commit_shows(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(W, "begin");
    h.ctl(R, "new div late style='w=10 h=10'");
    // Written, readable, not drawn yet.
    assert!(h.read(&format!("{R}/late/type")).is_some());
    assert!(h.read(&format!("{R}/late/bounds")).is_none_or(|b| b.trim().is_empty() || b.starts_with("0 0 0 0")));
    h.ctl(W, "commit");
    assert_eq!(h.bounds(&format!("{R}/late"))[2], 10.);
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
fn scroll_origin_round_trips(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new scroll sc style='h=40 w=100 overflow_y_scroll'");
    h.ctl(&format!("{R}/sc"), "new div a style='h=200 w=100'");
    h.write(&format!("{R}/sc/origin"), "0 30");
    let o = h.read(&format!("{R}/sc/origin")).unwrap_or_default();
    assert_eq!(o.trim(), "0 30");
}
