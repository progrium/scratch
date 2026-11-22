//! W6a render tests on GPUI's test platform: every form type renders, user
//! input mirrors values and sends DESIGN's events, client writes reach the
//! GPUI Kit state without an echo, and `controlled=on` leaves `value` alone.

use gpui::TestAppContext;

use crate::testing::Harness;

const R: &str = "windows/main/root";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Forms size=600,800");
    h.write(&format!("{R}/style"), "v_flex size_full p=8 gap=8");
    h
}

fn has(lines: &[String], start: &str, parts: &[&str]) -> bool {
    lines
        .iter()
        .any(|l| l.starts_with(start) && parts.iter().all(|p| l.contains(p)))
}

#[track_caller]
fn assert_has(lines: &[String], start: &str, parts: &[&str]) {
    assert!(has(lines, start, parts), "no {start} {parts:?} in {lines:#?}");
}

#[gpui::test]
fn every_form_type_renders(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        &format!("{R}/tree"),
        "div root  style='v_flex size_full p=8 gap=8'
  button b  label=Save  icon=check  style='primary sm'
  button-group g  value=b
    button a  label=Day
    button b  label=Week
  dropdown-button more  label=More
  checkbox cb  label='Remember me'  value=mixed
  radio-group rg  value=m  dir=h
  switch sw  label=Wi-Fi  value=on
  toggle tg  label=B  style=outline
  slider sl  min=0  max=100  value='20 80'  style=w=200
  input in  placeholder=Name  flags=cleanable
    icon prefix  name=search
  textarea ta  placeholder=Notes  auto_grow=3,8
  number-input ni  value=3  min=0  max=10
  otp-input otp  length=4
  select sel  placeholder=Pick
  combobox cb2  placeholder=Tags  multiple=on
  date-picker dp  value=2026-11-21
  calendar cal  value=2026-11-21
  color-picker col  value=#0b5cffff
  rating r  max=5  value=3
  form f  layout=h  label_width=120
    field name  label=Name  required=on  error='Needed'
      input in
  field lone  label=Alone  description=Hint
    switch s
",
    );
    h.write(&format!("{R}/rg/items"), "s\tSmall\nm\tMedium\n");
    h.write(&format!("{R}/sel/items"), "# Fruit\napple\tApple\n-\nkiwi\tKiwi\tdisabled\n");
    h.write(&format!("{R}/more/menu"), "item copy label=Copy\nsep\nitem del label=Delete\n");
    for n in [
        "b", "g", "more", "cb", "rg", "sw", "tg", "sl", "in", "in/prefix", "ta", "ni", "otp", "sel",
        "cb2", "dp", "cal", "col", "r", "f", "f/name", "f/name/in", "lone", "lone/s",
    ] {
        let [_, _, w, hh] = h.bounds(&format!("{R}/{n}"));
        assert!(w > 0. && hh > 0., "{n}: {w}x{hh}");
    }
    // `w=200` sizes the slider's box.
    assert_eq!(h.bounds(&format!("{R}/sl"))[2], 200.);
}

#[gpui::test]
fn button_click(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new button save label=Save style=primary tag=save\nnew button off label=No disabled=on");
    let mut ev = h.subscribe("events");
    h.click(&format!("{R}/save"));
    h.click(&format!("{R}/off"));
    let lines = h.events(&mut ev);
    assert_has(&lines, "click ", &["node=root/save", "tag=save"]);
    assert!(!has(&lines, "click ", &["node=root/off"]), "{lines:?}");
}

#[gpui::test]
fn checkbox_switch_toggle_change(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new checkbox cb label=Remember\nnew switch sw label=Wifi value=on\nnew toggle tg label=B");
    let mut ev = h.subscribe("windows/main/events");
    h.click(&format!("{R}/cb"));
    h.click(&format!("{R}/sw"));
    h.click(&format!("{R}/tg"));
    let lines = h.events(&mut ev);
    assert_has(&lines, "change ", &["node=root/cb", "value=on", "via=user"]);
    assert_has(&lines, "change ", &["node=root/sw", "value=off", "via=user"]);
    assert_has(&lines, "change ", &["node=root/tg", "value=on", "via=user"]);
    assert_eq!(h.read(&format!("{R}/cb/value")).as_deref(), Some("on"));
    assert_eq!(h.read(&format!("{R}/sw/value")).as_deref(), Some("off"));
    assert_eq!(h.read(&format!("{R}/tg/value")).as_deref(), Some("on"));
    // A second click toggles back.
    h.click(&format!("{R}/cb"));
    assert_eq!(h.read(&format!("{R}/cb/value")).as_deref(), Some("off"));
}

#[gpui::test]
fn controlled_checkbox_waits_for_the_client(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new checkbox cb label=Remember controlled=on");
    let mut ev = h.subscribe("events");
    h.click(&format!("{R}/cb"));
    let lines = h.events(&mut ev);
    assert_has(&lines, "change ", &["node=root/cb", "value=on"]);
    assert_eq!(h.read(&format!("{R}/cb/value")).as_deref(), Some("off"));
    h.write(&format!("{R}/cb/value"), "on");
    let lines = h.events(&mut ev);
    assert_has(&lines, "change ", &["node=root/cb", "value=on", "via=ctl"]);
}

#[gpui::test]
fn disabled_checkbox_sends_nothing(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new checkbox cb label=Off disabled=on");
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    h.click(&format!("{R}/cb"));
    assert!(!has(&h.events(&mut ev), "change ", &[]));
    assert_eq!(h.read(&format!("{R}/cb/value")).as_deref(), Some("off"));
}

#[gpui::test]
fn input_typing_mirrors_value_without_text_in_events(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new form f");
    h.ctl(&format!("{R}/f"), "new field name label=Name");
    h.ctl(&format!("{R}/f/name"), "new input in tag=name style=w=200");
    let mut ev = h.subscribe("events");
    h.click(&format!("{R}/f/name/in"));
    h.keys("main", "A d a");
    assert_eq!(h.read(&format!("{R}/f/name/in/value")).as_deref(), Some("Ada"));
    h.keys("main", "enter");
    let lines = h.events(&mut ev);
    assert_has(&lines, "change ", &["node=root/f/name/in", "tag=name", "via=user"]);
    assert!(!lines.iter().any(|l| l.contains("Ada")), "{lines:?}");
    assert_has(&lines, "submit ", &["node=root/f/name/in"]);
    assert_has(&lines, "submit ", &["node=root/f "]);
}

#[gpui::test]
fn client_value_write_reaches_the_input(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new input in style=w=200");
    h.write(&format!("{R}/in/value"), "Grace\n");
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    // Typing goes after the client's text: the state has it.
    h.click(&format!("{R}/in"));
    h.keys("main", "end !");
    assert_eq!(h.read(&format!("{R}/in/value")).as_deref(), Some("Grace!"));
    // A client write is no user change.
    h.events(&mut ev);
    h.write(&format!("{R}/in/value"), "Hopper");
    let lines = h.events(&mut ev);
    assert!(!has(&lines, "change ", &["via=user"]), "{lines:?}");
    assert_has(&lines, "change ", &["node=root/in", "via=ctl"]);
    assert_eq!(h.read(&format!("{R}/in/value")).as_deref(), Some("Hopper"));
}

#[gpui::test]
fn secret_input_value_stays_out_of_the_trace(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new input pw flags=secret style=w=200");
    h.click(&format!("{R}/pw"));
    h.keys("main", "s 3 c r 3 t");
    assert_eq!(h.read(&format!("{R}/pw/value")).as_deref(), Some("s3cr3t"));
    h.write(&format!("{R}/pw/value"), "hunter2");
    let trace = h.read("trace").unwrap_or_default();
    assert!(!trace.contains("hunter2") && !trace.contains("s3cr3t"), "{trace}");
}

#[gpui::test]
fn number_input_change_has_value(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new number-input n value=3 min=0 max=10 style=w=200");
    let mut ev = h.subscribe("events");
    h.click(&format!("{R}/n"));
    h.keys("main", "end 5");
    let lines = h.events(&mut ev);
    assert_eq!(h.read(&format!("{R}/n/value")).as_deref(), Some("35"));
    assert_has(&lines, "change ", &["node=root/n", "value=35"]);
}

#[gpui::test]
fn textarea_keeps_newlines(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new textarea t rows=3 style=w=200");
    h.write(&format!("{R}/t/value"), "one\ntwo\n");
    assert_eq!(h.read(&format!("{R}/t/value")).as_deref(), Some("one\ntwo\n"));
    h.click(&format!("{R}/t"));
    h.keys("main", "x");
    let v = h.read(&format!("{R}/t/value")).unwrap_or_default();
    assert!(v.contains('x') && v.contains("one\ntwo"), "{v:?}");
}

#[gpui::test]
fn select_follows_value_and_items(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new select lang searchable=on style=w=200");
    h.write(&format!("{R}/lang/items"), "rs\tRust\ngo\tGo\n");
    h.write(&format!("{R}/lang/value"), "go");
    let n = h.node(&format!("{R}/lang"));
    let s = h
        .cx
        .update(|cx| {
            let st = n.host.states.borrow();
            let e = st.get(n.path()).and_then(|s| s.entity.clone())?;
            let e = e.downcast::<gpui_component::select::SelectState<super::pickers::Items>>().ok()?;
            e.read(cx).selected_value().map(|v| v.to_string())
        });
    assert_eq!(s.as_deref(), Some("go"));
    assert!(h.try_write(&format!("{R}/lang/value"), "fortran").is_err());
}

#[gpui::test]
fn slider_client_write_and_range(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new slider v min=0 max=100 step=5 value=40 style=w=200");
    h.write(&format!("{R}/v/value"), "60");
    let n = h.node(&format!("{R}/v"));
    let v = h.cx.update(|cx| {
        let st = n.host.states.borrow();
        let e = st.get(n.path()).and_then(|s| s.entity.clone())?;
        let e = e.downcast::<gpui_component::slider::SliderState>().ok()?;
        Some(e.read(cx).value().end())
    });
    assert_eq!(v, Some(60.));
    // A new range rebuilds the state from the files.
    h.write(&format!("{R}/v/max"), "200");
    let [_, _, w, _] = h.bounds(&format!("{R}/v"));
    assert_eq!(w, 200.);
}

#[gpui::test]
fn radio_and_rating_clicks(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new radio-group size style=w=200\nnew rating r max=5");
    h.write(&format!("{R}/size/items"), "s\tSmall\n");
    let mut ev = h.subscribe("events");
    // One item fills the group, so its middle is that radio.
    h.click(&format!("{R}/size"));
    // The first star is at the rating's left edge.
    let [x, y, _, hh] = h.bounds(&format!("{R}/r"));
    let mut v = h.visual("main");
    let p = gpui::point(gpui::px(x + 6.), gpui::px(y + hh / 2.));
    v.simulate_mouse_move(p, None, gpui::Modifiers::none());
    v.simulate_click(p, gpui::Modifiers::none());
    h.settle();
    let lines = h.events(&mut ev);
    assert_has(&lines, "change ", &["node=root/size", "value=s"]);
    assert_eq!(h.read(&format!("{R}/size/value")).as_deref(), Some("s"));
    assert_has(&lines, "change ", &["node=root/r", "value=1"]);
    assert_eq!(h.read(&format!("{R}/r/value")).as_deref(), Some("1"));
}

#[gpui::test]
fn button_group_and_dropdown(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new button-group g value=a\nnew dropdown-button more label=More tag=more");
    h.ctl(&format!("{R}/g"), "new button a label=Day");
    h.write(&format!("{R}/more/menu"), "item copy label=Copy\n");
    let mut ev = h.subscribe("events");
    h.click(&format!("{R}/g"));
    // The dropdown's left part is its button.
    let [x, y, _, hh] = h.bounds(&format!("{R}/more"));
    let mut v = h.visual("main");
    let p = gpui::point(gpui::px(x + 6.), gpui::px(y + hh / 2.));
    v.simulate_mouse_move(p, None, gpui::Modifiers::none());
    v.simulate_click(p, gpui::Modifiers::none());
    h.settle();
    let lines = h.events(&mut ev);
    // A single-choice group keeps its one choice.
    assert_has(&lines, "change ", &["node=root/g", "value=a"]);
    assert_has(&lines, "click ", &["node=root/more", "tag=more"]);
}

/// The gallery's form stories render on screen (examples/rc/gallery).
#[gpui::test]
fn gallery_form_stories_render(cx: &mut TestAppContext) {
    let mut h = window(cx);
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples/rc/gallery");
    for story in ["button", "toggles", "input", "select", "slider", "date"] {
        let doc = std::fs::read_to_string(format!("{dir}/{story}/tree")).unwrap();
        h.ctl(R, &format!("new scroll {story}"));
        let doc = doc.replacen("scroll story", &format!("scroll {story}"), 1);
        h.write(&format!("{R}/{story}/tree"), &doc);
        let [_, _, w, hh] = h.bounds(&format!("{R}/{story}"));
        assert!(w > 0. && hh > 0., "{story}");
        h.remove(&format!("{R}/{story}")).unwrap();
    }
}
