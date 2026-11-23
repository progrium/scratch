//! W6b nav: tree validation (headless TypeSpec rules) and render tests on
//! GPUI's test platform.

use gpui::{Modifiers, TestAppContext, point, px};
use crate::testing::{ErrorKind, WriteError};

use super::part_bounds;
use crate::testing::Harness;

const W: &str = "win/main";
const R: &str = "win/main";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=800,600");
    h.ctl("win/main", "show");
    h.write(&format!("{R}/style"), "v-flex size-full p=8 gap=4");
    h
}

fn kind(r: Result<(), WriteError>) -> Option<ErrorKind> {
    r.err().map(|e| e.kind)
}

pub(crate) fn click_at(h: &mut Harness, win: &str, x: f32, y: f32) {
    let mut v = h.visual(win);
    let p = point(px(x), px(y));
    v.simulate_mouse_move(p, None, Modifiers::none());
    v.simulate_click(p, Modifiers::none());
    h.settle();
}

pub(crate) fn click_part(h: &mut Harness, key: &str) {
    // Parts are keyed by the renderer's path, `main/t/b#close`.
    let key = key.strip_prefix("win/").unwrap_or(key);
    let b = part_bounds(key).unwrap_or_else(|| panic!("no part {key}"));
    let c = b.center();
    let win = key.split('/').next().unwrap_or("main").to_string();
    click_at(h, &win, f32::from(c.x), f32::from(c.y));
}

/// Clicks along a line until an event starting with `name` arrives.
fn scan_click(
    h: &mut Harness,
    sub: &mut crate::testing::Subscription,
    from: (f32, f32),
    step: (f32, f32),
    n: usize,
    name: &str,
) -> Vec<String> {
    for i in 0..n {
        let (x, y) = (from.0 + step.0 * i as f32, from.1 + step.1 * i as f32);
        click_at(h, "main", x, y);
        let lines = h.events(sub);
        if lines.iter().any(|l| l.starts_with(name)) {
            return lines;
        }
    }
    panic!("no {name} event along the scan");
}

fn settings(h: &mut Harness) {
    h.write(&format!("{R}/style"), "h-flex size-full");
    h.ctl(R, "new sidebar nav\nnew div page : flex-1 p=24");
    h.ctl(&format!("{R}/nav"), "new sidebar-group g label=Settings");
    h.ctl(
        &format!("{R}/nav/g"),
        "new sidebar-item general label=General icon=settings active=on tag=page:general\n\
         new sidebar-item account label=Account icon=user tag=page:account\n\
         new sidebar-item keys label=Shortcuts icon=keyboard badge=3 tag=page:keys",
    );
}

#[gpui::test]
fn sidebar_slots_and_children(cx: &mut TestAppContext) {
    let mut h = window(cx);
    settings(&mut h);
    let nav = format!("{R}/nav");
    assert_eq!(kind(h.try_write(&format!("{nav}/ctl"), "new text stray")), Some(ErrorKind::UnknownType));
    h.ctl(&nav, "new text header text=App");
    h.ctl(&nav, "new text footer text=v1");
    assert_eq!(kind(h.try_write(&format!("{nav}/side"), "middle")), Some(ErrorKind::BadValue));
    assert_eq!(kind(h.try_write(&format!("{nav}/g/ctl"), "new div x")), Some(ErrorKind::UnknownType));
    let [_, _, w, hh] = h.bounds(&nav);
    assert!(w > 100. && hh > 100., "sidebar is drawn: {w}x{hh}");
}

#[gpui::test]
fn sidebar_item_click_sends_its_tag(cx: &mut TestAppContext) {
    let mut h = window(cx);
    settings(&mut h);
    let [x, y, _, _] = h.bounds(&format!("{R}/nav"));
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    let lines = scan_click(&mut h, &mut ev, (x + 60., y + 4.), (0., 4.), 60, "click ");
    let click = lines.iter().find(|l| l.starts_with("click ")).unwrap();
    assert!(click.contains(" nav/g/general win=") && click.contains(" page:general "), "{click}");
}

#[gpui::test]
fn sidebar_toggle_collapses(cx: &mut TestAppContext) {
    let mut h = window(cx);
    settings(&mut h);
    let nav = format!("{R}/nav");
    let w0 = h.bounds(&nav)[2];
    h.write(&format!("{nav}/collapsed"), "on");
    h.cx.executor().advance_clock(std::time::Duration::from_millis(500));
    h.settle();
    let w1 = h.bounds(&nav)[2];
    assert!(w1 < w0, "collapsed is narrower: {w0} -> {w1}");
}

#[gpui::test]
fn tabs_value_names_a_tab(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new tabs t underline");
    let t = format!("{R}/t");
    h.ctl(&t, "new tab a label=One\nnew tab b label=Two closable=on");
    assert_eq!(kind(h.try_write(&format!("{t}/ctl"), "new div x")), Some(ErrorKind::UnknownType));
    h.write(&format!("{t}/value"), "b");
    assert_eq!(h.read(&format!("{t}/value")).as_deref(), Some("b"));
    assert_eq!(kind(h.try_write(&format!("{t}/value"), "c")), Some(ErrorKind::NotFound));
    assert_eq!(h.read(&format!("{t}/value")).as_deref(), Some("b"));
    // `new tabs ... value=` before any tab exists is fine.
    h.ctl(R, "new tabs t2 value=x");
}

#[gpui::test]
fn tabs_draw_only_the_selected_panel(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new tabs t");
    let t = format!("{R}/t");
    h.ctl(&t, "new tab a label=One\nnew tab b label=Two");
    h.ctl(&format!("{t}/a"), "new text body text='first panel'");
    h.ctl(&format!("{t}/b"), "new text body text='second panel'");
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    let a = h.bounds(&format!("{t}/a"));
    assert!(a[2] > 0., "first tab's panel is drawn");
    // Click the second tab's header.
    click_part(&mut h, &format!("{t}/b#header"));
    let lines = h.events(&mut ev);
    assert!(
        lines.iter().any(|l| l.starts_with("change ") && l.contains(" t win=") && l.contains("value=b") && l.contains("via=user")),
        "{lines:?}"
    );
    assert_eq!(h.read(&format!("{t}/value")).as_deref(), Some("b"));
    let b = h.bounds(&format!("{t}/b/body"));
    assert!(b[2] > 0., "second panel drawn");
    // Clicking the selected tab again sends nothing.
    click_part(&mut h, &format!("{t}/b#header"));
    assert!(!h.events(&mut ev).iter().any(|l| l.starts_with("change")));
    // A client write moves the selection, with a via=ctl echo.
    h.write(&format!("{t}/value"), "a");
    let lines = h.events(&mut ev);
    assert!(lines.iter().any(|l| l.starts_with("change ") && l.contains("via=ctl")), "{lines:?}");
}

#[gpui::test]
fn tab_close_request_keep_and_close(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new tabs t");
    let t = format!("{R}/t");
    h.ctl(&t, "new tab a label=A closable=on\nnew tab b label=B closable=on");
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    click_part(&mut h, &format!("{t}/b#close"));
    let lines = h.events(&mut ev);
    let req = lines
        .iter()
        .find(|l| l.starts_with("close ") && l.contains(" t/b win="))
        .unwrap_or_else(|| panic!("{lines:?}"))
        .clone();
    let seq = seq_of(&req);
    h.ctl(&format!("{t}/b"), &format!("keep seq={seq}"));
    assert!(h.read(&format!("{t}/b/type")).is_some(), "kept");
    click_part(&mut h, &format!("{t}/b#close"));
    let lines = h.events(&mut ev);
    let seq = seq_of(lines.iter().find(|l| l.starts_with("close ")).unwrap());
    h.ctl(&format!("{t}/b"), &format!("close seq={seq}"));
    h.settle();
    assert!(h.read(&format!("{t}/b/type")).is_none(), "closed tab is gone");
    assert_eq!(h.read(&format!("{t}/order")).as_deref(), Some("a"));
}

#[gpui::test]
fn tab_close_with_no_reader_closes(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new tabs t");
    let t = format!("{R}/t");
    h.ctl(&t, "new tab a label=A closable=on\nnew tab b label=B closable=on");
    click_part(&mut h, &format!("{t}/a#close"));
    h.settle();
    assert!(h.read(&format!("{t}/a/type")).is_none());
}

pub(crate) fn seq_of(line: &str) -> u64 {
    line.split_whitespace()
        .find_map(|w| w.strip_prefix("seq="))
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| panic!("no seq in {line}"))
}

#[gpui::test]
fn breadcrumb_click_sends_id(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new breadcrumb crumbs");
    let c = format!("{R}/crumbs");
    h.write(&format!("{c}/items"), "home\tHome\ndocs\tDocs\napi\tAPI\n");
    assert_eq!(h.read(&format!("{c}/items")).as_deref(), Some("home\tHome\ndocs\tDocs\napi\tAPI\n"));
    let [x, y, _, hh] = h.bounds(&c);
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    let lines = scan_click(&mut h, &mut ev, (x + 2., y + hh / 2.), (3., 0.), 60, "click ");
    let l = lines.iter().find(|l| l.starts_with("click ")).unwrap();
    assert!(l.contains(" crumbs win=") && l.contains("id=home"), "{l}");
}

#[gpui::test]
fn pagination_pages(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new pagination pg total=120 per-page=20");
    let p = format!("{R}/pg");
    h.write(&format!("{p}/page"), "3");
    assert_eq!(h.read(&format!("{p}/page")).as_deref(), Some("3"));
    assert_eq!(kind(h.try_write(&format!("{p}/page"), "three")), Some(ErrorKind::BadValue));
    let [x, y, w, hh] = h.bounds(&p);
    assert!(w > 0. && hh > 0.);
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    let lines = scan_click(&mut h, &mut ev, (x + 2., y + hh / 2.), (4., 0.), 120, "change ");
    let l = lines.iter().find(|l| l.starts_with("change ")).unwrap();
    let page = l
        .split_whitespace()
        .find_map(|w| w.strip_prefix("page="))
        .unwrap_or_else(|| panic!("{l}"));
    assert_ne!(page, "3");
    assert_eq!(h.read(&format!("{p}/page")).as_deref(), Some(page));
}

#[gpui::test]
fn stepper_changes_value(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new stepper s : w=600");
    let s = format!("{R}/s");
    h.write(&format!("{s}/items"), "cart\tCart\nship\tShipping\npay\tPayment\n");
    let [x, y, w, hh] = h.bounds(&s);
    assert!(w > 0. && hh > 0.);
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    let lines = scan_click(&mut h, &mut ev, (x + w - 4., y + 12.), (-8., 0.), 70, "change ");
    let l = lines.iter().find(|l| l.starts_with("change ")).unwrap();
    assert!(l.contains("value=pay") || l.contains("value=ship"), "{l}");
}

#[gpui::test]
fn link_click_once(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new link help label=Help href=https://example.com/help tag=help");
    let l = format!("{R}/help");
    assert_eq!(h.read(&format!("{l}/href")).as_deref(), Some("https://example.com/help"));
    h.write(&format!("{l}/on"), "click");
    let mut ev = h.subscribe(&format!("{W}/events"));
    h.events(&mut ev);
    h.click(&l);
    let lines = h.events(&mut ev);
    let n = lines.iter().filter(|x| x.starts_with("click ")).count();
    assert_eq!(n, 1, "{lines:?}");
    assert!(lines[0..].iter().any(|x| x.contains(" help ")));
}

#[gpui::test]
fn bars_render(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new title-bar tb title=Gallery\nnew toolbar tools\nnew status-bar sb");
    h.ctl(&format!("{R}/tools"), "new text b1 text=Bold\nnew text b2 text=Italic");
    h.ctl(&format!("{R}/sb"), "new text left text='Ln 1'\nnew text center text=ok\nnew text right text=UTF-8");
    assert_eq!(
        kind(h.try_write(&format!("{R}/sb/ctl"), "new text middle")),
        // core.md § Errors: a child the parent can't hold.
        Some(ErrorKind::UnknownType)
    );
    for n in ["tb", "tools", "sb", "sb/left", "sb/right", "sb/center"] {
        let [_, _, w, hh] = h.bounds(&format!("{R}/{n}"));
        assert!(w > 0. && hh > 0., "{n}: {w}x{hh}");
    }
}
