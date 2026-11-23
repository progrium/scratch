//! W6d edit-group render tests on GPUI's test platform.

use gpui::TestAppContext;

use super::editor::EditorNode;
use crate::testing::Harness;

const R: &str = "windows/main/root";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=640,480");
    h.write(&format!("{R}/style"), "v_flex size_full p=8 gap=4");
    h
}

fn has(lines: &[String], start: &str, parts: &[&str]) -> bool {
    lines
        .iter()
        .any(|l| l.starts_with(start) && parts.iter().all(|p| l.contains(p)))
}

fn editor(h: &Harness, path: &str) -> gpui::Entity<EditorNode> {
    let n = h.node(path);
    let st = n
        .host
        .states
        .borrow()
        .get(path)
        .and_then(|s| s.entity.clone());
    super::entity::<EditorNode>(st.as_ref()).expect("editor state")
}

fn editor_text(h: &mut Harness, path: &str) -> String {
    let e = editor(h, path);
    h.cx.update(|cx| e.read(cx).state.read(cx).text().to_string())
}

#[gpui::test]
fn editor_renders_with_its_files(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(
        R,
        "new editor e language=rust line_numbers=on tab_size=2 style='h=200 w_full'",
    );
    let e = format!("{R}/e");
    h.write(
        &format!("{e}/value"),
        "fn main() {\n    println!(\"hi\");\n}\n",
    );
    let [_, _, w, hh] = h.bounds(&e);
    assert!(w > 100. && (hh - 200.).abs() < 1., "{w}x{hh}");
    assert_eq!(
        editor_text(&mut h, &e),
        "fn main() {\n    println!(\"hi\");\n}\n"
    );
    // Multi-line values keep their bytes.
    assert_eq!(
        h.read(&format!("{e}/value")).unwrap(),
        "fn main() {\n    println!(\"hi\");\n}\n"
    );
    h.write(
        &format!("{e}/diagnostics"),
        "2\t5\t7\terror\tunknown macro\n",
    );
    assert!(
        h.try_write(&format!("{e}/diagnostics"), "two\t5\n")
            .is_err()
    );
    h.write(&format!("{e}/language"), "go");
    h.write(&format!("{e}/soft_wrap"), "on");
    h.write(&format!("{e}/readonly"), "on");
}

#[gpui::test]
fn editor_typing_mirrors_value_and_sends_change_and_cursor(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new editor e style='h=200 w_full'");
    let e = format!("{R}/e");
    h.write(&format!("{e}/value"), "hello");
    let mut ev = h.subscribe(&format!("{e}/events"));
    h.events(&mut ev);
    h.click(&e);
    h.keys("main", "end x y");
    let lines = h.events(&mut ev);
    let text = editor_text(&mut h, &e);
    assert!(text.contains("xy"), "{text:?}");
    assert_eq!(h.read(&format!("{e}/value")).unwrap(), text);
    assert!(has(&lines, "change ", &["via=user"]), "{lines:?}");
    assert!(
        !lines
            .iter()
            .any(|l| l.starts_with("change ") && l.contains("value=")),
        "{lines:?}"
    );
    assert!(has(&lines, "cursor ", &["line=1", "col="]), "{lines:?}");
    let sel = h.read(&format!("{e}/selection")).unwrap();
    assert_eq!(sel.split_whitespace().count(), 4, "{sel:?}");
}

#[gpui::test]
fn editor_client_writes_are_not_user_changes(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new editor e style='h=200 w_full'");
    let e = format!("{R}/e");
    let mut ev = h.subscribe(&format!("{e}/events"));
    h.write(&format!("{e}/value"), "one\ntwo\nthree\n");
    h.write(&format!("{e}/selection"), "2 1 2 4");
    let lines = h.events(&mut ev);
    assert!(!has(&lines, "change ", &["via=user"]), "{lines:?}");
    assert!(!has(&lines, "cursor ", &[]), "{lines:?}");
    let ed = editor(&h, &e);
    let sel =
        h.cx.update(|cx| ed.read(cx).state.read(cx).selected_range());
    assert_eq!(sel, 4..7);
}

#[gpui::test]
fn editor_save_comes_from_the_client_binding(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new editor e style='h=200 w_full' context=editor");
    let e = format!("{R}/e");
    h.write("keymap", "ctrl-s save context=editor\n");
    let mut ev = h.subscribe("events");
    h.click(&e);
    h.keys("main", "ctrl-s");
    let lines = h.events(&mut ev);
    assert!(has(&lines, "save ", &[" e win="]), "{lines:?}");
    assert!(!has(&lines, "action ", &["id=save"]), "{lines:?}");
}

#[gpui::test]
fn editor_save_falls_back_to_the_platform_key(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new editor e style='h=200 w_full'");
    let e = format!("{R}/e");
    let mut ev = h.subscribe("events");
    h.click(&e);
    h.keys("main", "ctrl-s");
    let lines = h.events(&mut ev);
    assert!(has(&lines, "save ", &[" e win="]), "{lines:?}");
}

#[gpui::test]
fn editor_complete_is_a_request_answered_through_a_file(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new editor e style='h=200 w_full'");
    let e = format!("{R}/e");
    // Without `complete` in `on`, typing asks nothing.
    let mut ev = h.subscribe(&format!("{e}/events"));
    h.click(&e);
    h.keys("main", "p");
    assert!(!has(&h.events(&mut ev), "complete ", &[]));

    h.write(&format!("{e}/on"), "complete hover");
    h.keys("main", "r");
    let lines = h.events(&mut ev);
    let line = lines
        .iter()
        .find(|l| l.starts_with("complete "))
        .unwrap_or_else(|| panic!("{lines:?}"));
    assert!(
        line.contains("line=1") && line.contains("col=3") && line.contains("prefix=pr"),
        "{line}"
    );
    let seq: u64 = line
        .split_whitespace()
        .find_map(|w| w.strip_prefix("seq="))
        .unwrap()
        .parse()
        .unwrap();
    // A stale answer is dropped; the right one is taken.
    h.write(
        &format!("{e}/completions"),
        &format!("seq={}\nprintln\n", seq + 100),
    );
    h.write(
        &format!("{e}/completions"),
        &format!("seq={seq}\nprintln\tprintln!\tkind=function\tdetail=macro\nprint\n"),
    );
    let ed = editor(&h, &e);
    let taken =
        h.cx.update(|cx| ed.read(cx).pending.complete.borrow().is_none());
    assert!(taken, "the answer resolved the request");
    assert!(
        h.try_write(&format!("{e}/completions"), "println\n")
            .is_err(),
        "seq= is required"
    );
}

#[gpui::test]
fn markdown_and_html_render(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(
        R,
        "new markdown m selectable=on style=w_full\nnew html x style=w_full",
    );
    h.write(
        &format!("{R}/m/text"),
        "# Title\n\nSome *text* and a [link](https://example.com).\n\n- one\n- two\n",
    );
    h.write(
        &format!("{R}/x/text"),
        "<p>Hello <b>world</b> <a href='/a'>a</a></p>",
    );
    let [_, _, w, hh] = h.bounds(&format!("{R}/m"));
    assert!(w > 0. && hh > 40., "markdown {w}x{hh}");
    let [_, _, w, hh] = h.bounds(&format!("{R}/x"));
    assert!(w > 0. && hh > 0., "html {w}x{hh}");
}

#[gpui::test]
fn diff_from_old_and_new_and_from_a_patch(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new diff d path=src/a.rs style='h=200 w_full'");
    let d = format!("{R}/d");
    h.write(&format!("{d}/old"), "a\nb\nc\n");
    h.write(&format!("{d}/new"), "a\nB\nc\nd\n");
    let [_, _, w, hh] = h.bounds(&d);
    assert!(w > 0. && (hh - 200.).abs() < 1.);
    h.write(&format!("{d}/view"), "split");
    h.write(
        &format!("{d}/patch"),
        "--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n",
    );
    h.write(&format!("{d}/patch"), "not a patch at all\n");
    assert!(h.try_write(&format!("{d}/view"), "sideways").is_err());
}

#[test]
fn unified_patch_from_texts() {
    let p = super::diff::unified("f", "a\nb\n", "a\nc\n");
    assert!(p.starts_with("--- a/f\n+++ b/f\n@@"), "{p}");
    assert!(p.contains("-b\n") && p.contains("+c\n"), "{p}");
}

#[gpui::test]
fn message_list_and_bubble_render(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(
        R,
        "new message-list msgs style='h=300 w_full'\nnew bubble b role=user text=Hi style=filled",
    );
    let m = format!("{R}/msgs");
    h.write(
        &format!("{m}/items"),
        "1 user 10:00\nHello there\n\n2 assistant 10:01\nHi! **How** can I help?\n\n",
    );
    let [_, _, w, hh] = h.bounds(&m);
    assert!(w > 0. && (hh - 300.).abs() < 1.);
    // Streaming: the last message grows, then a new one arrives.
    h.write(
        &format!("{m}/items"),
        "1 user 10:00\nHello there\n\n2 assistant 10:01\nHi! **How** can I help you today?\n\n3 user 10:02\nThanks\n\n",
    );
    assert!(
        h.try_write(&format!("{m}/items"), "no header here\n")
            .is_err()
    );
    let [_, _, w, hh] = h.bounds(&format!("{R}/b"));
    assert!(w > 0. && hh > 0.);
    assert!(h.try_write(&format!("{R}/b/role"), "robot").is_err());
    assert!(h.try_write(&format!("{R}/b/style"), "primary").is_err());
}
