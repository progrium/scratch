//! `web` on GPUI's test platform. Its windows have no native handle, so
//! no page engine can attach: these check the node, its layout and the
//! placeholder path, and the bridge's message and result handling.

use gpui::TestAppContext;

use super::{Sink, WebNode};
use crate::testing::Harness;

const R: &str = "win/main";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=640,480");
    h.ctl("win/main", "show");
    h.write(&format!("{R}/style"), "v-flex size-full");
    h
}

fn sink(h: &Harness, path: &str) -> Sink {
    let n = h.node(path);
    let ent = n.host.states.borrow().get(&n.node()).and_then(|s| s.entity.clone()).expect("web state");
    let ent = ent.downcast::<WebNode>().ok().expect("WebNode");
    h.cx.update(|cx| ent.read(cx).sink.clone())
}

#[gpui::test]
fn web_fills_its_parent_and_reads_back(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new web view url=https://example.com/");
    let v = format!("{R}/view");
    let [_, _, w, hh] = h.bounds(&v);
    assert!((w - 640.).abs() < 1. && (hh - 480.).abs() < 1., "{w}x{hh}");
    assert_eq!(h.read(&format!("{v}/url")).unwrap().trim(), "https://example.com/");
    assert_eq!(h.read(&format!("{v}/type")).unwrap().trim(), "web");
}

#[gpui::test]
fn eval_with_no_page_answers_not_ok(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new web view html='<p>hi</p>'");
    let mut sub = h.subscribe(&format!("{R}/events"));
    h.ctl(&format!("{R}/view"), "eval n=7 script=document.title");
    h.settle();
    let ev = h.events(&mut sub);
    assert!(ev.iter().any(|l| l.starts_with("result - view") && l.contains("n=7") && !l.contains("ok=")), "{ev:?}");
}

#[gpui::test]
fn bridge_messages_and_results(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new web view");
    let v = format!("{R}/view");
    let s = sink(&h, &v);
    let mut sub = h.subscribe(&format!("{R}/events"));
    s.ipc(r#"{"k":"message","body":"hello page"}"#);
    s.ipc(r#"{"k":"message","body":"again"}"#);
    s.ipc(r#"{"k":"result","n":"3","ok":true,"body":"Title"}"#);
    s.loaded();
    s.title("Title");
    h.settle();
    let ev = h.events(&mut sub);
    assert!(ev.iter().any(|l| l.starts_with("message - view") && l.contains("n=1")), "{ev:?}");
    assert!(ev.iter().any(|l| l.starts_with("message - view") && l.contains("n=2")), "{ev:?}");
    assert!(ev.iter().any(|l| l.starts_with("result - view") && l.contains("n=3") && l.contains("ok=on")), "{ev:?}");
    assert!(ev.iter().any(|l| l.starts_with("load - view") && l.contains("ok=on")), "{ev:?}");
    assert!(ev.iter().any(|l| l.starts_with("title - view") && l.contains("value=Title")), "{ev:?}");
    assert_eq!(h.read(&format!("{v}/message")).unwrap().trim(), "again");
    assert_eq!(h.read(&format!("{v}/result")).unwrap().trim(), "Title");
}

#[test]
fn eval_wrapper_quotes_the_script() {
    let w = super::eval_wrapper("(s=>0)", Some("7"), "'a'+\"b\"\n");
    assert!(w.contains(r#"(0,eval)("'a'+\"b\"\n")"#), "{w}");
    assert!(w.contains(r#"const n="7""#), "{w}");
    assert_eq!(super::eval_wrapper("(s=>0)", None, "x"), r#"(0,eval)("x");"#);
}
