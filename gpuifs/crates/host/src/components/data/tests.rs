//! W6c render tests: the data display group on GPUI's test platform.

use gpui::{Modifiers, MouseButton, MouseDownEvent, MouseUpEvent, TestAppContext, point, px};

use crate::testing::Harness;

const R: &str = "windows/main/root";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=600,1400");
    h.write(&format!("{R}/style"), "v_flex size_full p=8 gap=4");
    h
}

fn tsv(s: &str) -> String {
    s.replace('|', "\t")
}

fn has(lines: &[String], start: &str, parts: &[&str]) -> bool {
    lines
        .iter()
        .any(|l| l.starts_with(start) && parts.iter().all(|p| l.contains(p)))
}

/// Clicks a window point (`count` 2 for a double click).
fn click_at(h: &mut Harness, x: f32, y: f32, count: usize) {
    let mut v = h.visual("main");
    let p = point(px(x), px(y));
    v.simulate_mouse_move(p, None, Modifiers::none());
    for n in 1..=count {
        v.simulate_event(MouseDownEvent {
            position: p,
            modifiers: Modifiers::none(),
            button: MouseButton::Left,
            click_count: n,
            first_mouse: false,
        });
        v.simulate_event(MouseUpEvent {
            position: p,
            modifiers: Modifiers::none(),
            button: MouseButton::Left,
            click_count: n,
        });
    }
    h.settle();
}

#[gpui::test]
fn every_data_type_renders(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(
        R,
        "new list l selectable=on style=h=80\n\
         new virtual-list vl style=h=60\n\
         new table t style=h=80\n\
         new tree tr style=h=60\n\
         new description-list dl bordered=on\n\
         new badge bd count=3\n\
         new tag tg label=New style='primary sm'\n\
         new avatar av name='Ada Lovelace' style=sm\n\
         new avatar-group ag max=2\n\
         new kbd kb key=cmd-shift-p\n\
         new progress p value=40\n\
         new progress pc variant=circle\n\
         new spinner sp style=sm\n\
         new skeleton sk style='h=10 w=100'\n\
         new shimmer sh text=Loading\n\
         new empty em title=Nothing icon=inbox\n\
         new alert al title=Hi text=There variant=success\n\
         new chart ch kind=bar x=m y=v style=h=80",
    );
    h.write(&format!("{R}/l/items"), &tsv("a|Apple\nb|Banana\n"));
    h.write(&format!("{R}/vl/items"), &tsv("a|Apple\n"));
    h.write(&format!("{R}/t/columns"), &tsv("n|Name|100\n"));
    h.write(&format!("{R}/t/rows"), &tsv("1|x\n"));
    h.write(&format!("{R}/tr/items"), &tsv("a|-|A\n"));
    h.write(&format!("{R}/dl/items"), &tsv("Name|gpuifs\n"));
    h.ctl(&format!("{R}/bd"), "new icon i name=bell style=size=16");
    h.ctl(&format!("{R}/ag"), "new avatar a name=Ken\nnew avatar b name=Rob\nnew avatar c name=Russ");
    h.ctl(&format!("{R}/em"), "new div act");
    h.write(&format!("{R}/ch/data"), &tsv("m|v\nJan|3\nFeb|5\n"));
    for n in [
        "l", "vl", "t", "tr", "dl", "bd", "tg", "av", "ag", "kb", "p", "pc", "sp", "sk", "sh", "em",
        "al", "ch",
    ] {
        let [_, _, w, hh] = h.bounds(&format!("{R}/{n}"));
        assert!(w > 0. && hh > 0., "{n} has no size: {w}x{hh}");
    }
    for k in ["line", "area", "pie"] {
        h.write(&format!("{R}/ch/kind"), k);
        let [_, _, w, _] = h.bounds(&format!("{R}/ch"));
        assert!(w > 0., "{k}");
    }
}

#[gpui::test]
fn data_files_validate(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new list l\nnew table t\nnew tree tr\nnew progress p\nnew tag g");
    h.write(&format!("{R}/l/items"), &tsv("# Fruit\napple|Apple|icon=apple\n-\nleek|Leek\n"));
    assert!(h.try_write(&format!("{R}/l/items"), &tsv("|Nameless\n")).is_err());
    assert_eq!(h.read(&format!("{R}/l/items")).unwrap().lines().count(), 4);
    assert!(h.try_write(&format!("{R}/t/columns"), &tsv("a|A|wide\n")).is_err());
    h.write(&format!("{R}/t/rows"), &tsv("1|a\n2|b\n"));
    h.write(&format!("{R}/t/append"), &tsv("3|c\n"));
    assert_eq!(h.read(&format!("{R}/t/rows")).unwrap().lines().count(), 3);
    assert!(h.try_write(&format!("{R}/t/selectable"), "column").is_err());
    assert!(h.try_write(&format!("{R}/tr/items"), "a\n").is_err());
    h.write(&format!("{R}/p/value"), "40");
    assert!(h.try_write(&format!("{R}/p/value"), "140").is_err());
    assert!(h.try_write(&format!("{R}/p/value"), "-1").is_err());
    h.write(&format!("{R}/p/value"), "");
    h.write(&format!("{R}/g/style"), "danger outline");
    assert!(h.try_write(&format!("{R}/g/style"), "ghost").is_err());
    assert!(h.try_write(&format!("{R}/l/ctl"), "new text x").is_err());
    h.ctl(&format!("{R}/l"), "new div row");
}

#[gpui::test]
fn list_click_selects_and_double_click_opens(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new list l selectable=on style=h=200 tag=pick");
    h.write(&format!("{R}/l/items"), &tsv("a|Apple\nb|Banana\nc|Cherry\n"));
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    let [x, y, w, _] = h.bounds(&format!("{R}/l"));
    // Items are the same height; the second one is below the first.
    click_at(&mut h, x + w / 2., y + 10., 1);
    let lines = h.events(&mut ev);
    assert!(has(&lines, "select ", &["node=root/l", "value=a", "tag=pick", "via=user"]), "{lines:?}");
    assert_eq!(h.read(&format!("{R}/l/value")).as_deref(), Some("a"));
    click_at(&mut h, x + w / 2., y + 10., 2);
    let lines = h.events(&mut ev);
    assert!(has(&lines, "open ", &["id=a"]), "{lines:?}");
}

#[gpui::test]
fn list_value_write_selects_without_an_event(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new list l selectable=on style=h=200");
    h.write(&format!("{R}/l/items"), &tsv("a|Apple\nb|Banana\n"));
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    h.write(&format!("{R}/l/value"), "b");
    let lines = h.events(&mut ev);
    assert!(!lines.iter().any(|l| l.starts_with("select")), "{lines:?}");
    let state = h.node(&format!("{R}/l"));
    let holder = state
        .host
        .states
        .borrow()
        .get(state.path())
        .and_then(|s| s.entity.clone())
        .unwrap()
        .downcast::<super::list::ListHolder>()
        .unwrap();
    let sel = h.cx.update(|cx| {
        let s = holder.read(cx).state.read(cx);
        (s.selected_index().map(|i| i.row), s.delegate().selected.clone())
    });
    assert_eq!(sel, (Some(1), vec!["b".to_string()]));
}

#[gpui::test]
fn list_row_template_stamps_fields(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new list l selectable=on style=h=200");
    h.ctl(&format!("{R}/l"), "new div row style='v_flex gap=2'");
    h.ctl(&format!("{R}/l/row"), "new text title text={title}\nnew text meta text='{score} by {by}'");
    h.write(&format!("{R}/l/fields"), "title\tscore\tby\n");
    h.write(&format!("{R}/l/items"), &tsv("1|Hello|10|ada\n2|World|20|ken\n"));
    // The template is stamped (so it is laid out) and never drawn as a child.
    let [_, _, w, hh] = h.bounds(&format!("{R}/l/row/title"));
    assert!(w > 0. && hh > 0.);
    let vals = std::collections::HashMap::from([("title", "Hello"), ("score", "10"), ("by", "ada")]);
    assert_eq!(super::substitute("{score} by {by} {nope}", &vals), "10 by ada {nope}");
}

#[gpui::test]
fn list_scrolled_to_end_once_per_page(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new list l style=h=100");
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    let page: String = (0..3).map(|i| format!("{i}\tItem {i}\n")).collect();
    h.write(&format!("{R}/l/items"), &page);
    h.settle();
    let n = h.events(&mut ev).iter().filter(|l| l.starts_with("scrolled_to_end")).count();
    assert_eq!(n, 1);
    h.settle();
    let n = h.events(&mut ev).iter().filter(|l| l.starts_with("scrolled_to_end")).count();
    assert_eq!(n, 0, "not again for the same page");
    h.write(&format!("{R}/l/loading"), "on");
    let more: String = (0..6).map(|i| format!("{i}\tItem {i}\n")).collect();
    h.write(&format!("{R}/l/items"), &more);
    h.write(&format!("{R}/l/loading"), "off");
    h.settle();
    let n = h.events(&mut ev).iter().filter(|l| l.starts_with("scrolled_to_end")).count();
    assert_eq!(n, 1, "again for the next page");
}

fn table(h: &mut Harness) {
    h.ctl(R, "new table t stripe=on selectable=row sortable=on style=h=300 tag=files");
    h.write(
        &format!("{R}/t/columns"),
        &tsv("name|Name|200|sort\nsize|Size|90|sort|align=right\n"),
    );
    h.write(&format!("{R}/t/rows"), &tsv("1|b.txt|300\n2|a.txt|12\n3|c.txt|7\n"));
}

#[gpui::test]
fn table_click_selects_row_and_sorted_on_sorts(cx: &mut TestAppContext) {
    let mut h = window(cx);
    table(&mut h);
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    let [x, y, _, _] = h.bounds(&format!("{R}/t"));
    // Header, then rows of the same height: click inside the first row.
    let row_h = 32.;
    click_at(&mut h, x + 50., y + row_h * 1.5, 1);
    let lines = h.events(&mut ev);
    assert!(has(&lines, "select ", &["node=root/t", "row=1", "tag=files"]), "{lines:?}");
    assert_eq!(h.read(&format!("{R}/t/value")).as_deref(), Some("1"));
    click_at(&mut h, x + 50., y + row_h * 1.5, 2);
    let lines = h.events(&mut ev);
    assert!(has(&lines, "open ", &["row=1"]), "{lines:?}");

    // The client's sort, drawn by the host.
    h.write(&format!("{R}/t/sorted"), "on");
    h.write(&format!("{R}/t/sort"), "size asc");
    let order = order_of(&mut h);
    assert_eq!(order, ["3", "2", "1"]);
    h.write(&format!("{R}/t/sort"), "name desc");
    assert_eq!(order_of(&mut h), ["3", "1", "2"]);
    // Selection follows the row, not the position.
    assert_eq!(h.read(&format!("{R}/t/value")).as_deref(), Some("1"));
}

fn order_of(h: &mut Harness) -> Vec<String> {
    let n = h.node(&format!("{R}/t"));
    let e = n
        .host
        .states
        .borrow()
        .get(n.path())
        .and_then(|s| s.entity.clone())
        .unwrap()
        .downcast::<super::table::TableHolder>()
        .unwrap();
    h.cx.update(|cx| {
        let d = e.read(cx).state.read(cx).delegate();
        d.order.iter().map(|i| d.rows[*i].id.clone()).collect()
    })
}

#[gpui::test]
fn table_header_click_sends_sort(cx: &mut TestAppContext) {
    let mut h = window(cx);
    table(&mut h);
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    // The sort button sits at the right end of the header cell.
    let [x, y, _, _] = h.bounds(&format!("{R}/t"));
    let mut lines = vec![];
    for dx in (100..240).step_by(4) {
        click_at(&mut h, x + dx as f32, y + 16., 1);
        lines = h.events(&mut ev);
        if lines.iter().any(|l| l.starts_with("sort ")) {
            break;
        }
    }
    assert!(has(&lines, "sort ", &["col=name", "dir=desc"]), "{lines:?}");
    assert_eq!(h.read(&format!("{R}/t/sort")).as_deref(), Some("name desc"));
    // The client sorts: rows stay as written.
    assert_eq!(order_of(&mut h), ["1", "2", "3"]);
}

#[gpui::test]
fn table_append_adds_rows(cx: &mut TestAppContext) {
    let mut h = window(cx);
    table(&mut h);
    h.write(&format!("{R}/t/append"), &tsv("4|d.txt|9\n"));
    assert_eq!(order_of(&mut h), ["1", "2", "3", "4"]);
}

#[gpui::test]
fn tree_click_expands_and_selects(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new tree tr selectable=on style=h=200");
    h.write(&format!("{R}/tr/items"), &tsv("src|-|src|icon=folder\nmain|src|main.rs\ndocs|-|docs\n"));
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    let [x, y, _, _] = h.bounds(&format!("{R}/tr"));
    click_at(&mut h, x + 40., y + 10., 1);
    let lines = h.events(&mut ev);
    assert!(has(&lines, "expand ", &["id=src", "value=on"]), "{lines:?}");
    assert!(has(&lines, "select ", &["value=src"]), "{lines:?}");
    assert_eq!(h.read(&format!("{R}/tr/expanded")).as_deref(), Some("src"));
    assert_eq!(h.read(&format!("{R}/tr/value")).as_deref(), Some("src"));
}

#[gpui::test]
fn tree_expanded_file_expands(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new tree tr style=h=200");
    h.write(&format!("{R}/tr/items"), &tsv("src|-|src\nmain|src|main.rs\ndocs|-|docs\n"));
    let n = h.node(&format!("{R}/tr"));
    let count = |h: &mut Harness| {
        let e = n
            .host
            .states
            .borrow()
            .get(n.path())
            .and_then(|s| s.entity.clone())
            .unwrap()
            .downcast::<super::tree::TreeHolder>()
            .unwrap();
        h.cx.update(|cx| {
            let s = e.read(cx).state.read(cx);
            (0..10).take_while(|i| s.entry(*i).is_some()).count()
        })
    };
    assert_eq!(count(&mut h), 2);
    h.write(&format!("{R}/tr/expanded"), "src");
    assert_eq!(count(&mut h), 3);
}

#[gpui::test]
fn tag_and_alert_close(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(
        R,
        "new tag g label=Closable closable=on style=danger\n\
         new alert a title=Oops text=Bad variant=error closable=on",
    );
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    // The tag's close icon is at its right end.
    let [x, y, w, hh] = h.bounds(&format!("{R}/g"));
    let mut lines = vec![];
    for dx in 1..(w as i32) {
        click_at(&mut h, x + w - dx as f32, y + hh / 2., 1);
        lines = h.events(&mut ev);
        if lines.iter().any(|l| l.starts_with("close ")) {
            break;
        }
    }
    assert!(has(&lines, "close ", &["node=root/g"]), "{lines:?}");
    // The alert's close button is at its top right.
    let [x, y, w, _] = h.bounds(&format!("{R}/a"));
    let before = h.bounds(&format!("{R}/a"));
    for dx in [12., 16., 20., 24., 28.] {
        click_at(&mut h, x + w - dx, y + 16., 1);
        if h.events(&mut ev).iter().any(|l| l.starts_with("close ") && l.contains("node=root/a")) {
            // Hidden now; a write shows it again.
            h.write(&format!("{R}/a/text"), "Again");
            assert_eq!(h.bounds(&format!("{R}/a"))[3], before[3]);
            return;
        }
    }
    panic!("no alert close");
}

#[gpui::test]
fn chart_click_selects_band(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new chart c kind=bar x=m y=v style='h=100 w=200'");
    h.write(&format!("{R}/c/data"), &tsv("m|v\nJan|3\nFeb|5\n"));
    let mut ev = h.subscribe("events");
    h.events(&mut ev);
    let [x, y, w, _] = h.bounds(&format!("{R}/c"));
    click_at(&mut h, x + w * 0.75, y + 50., 1);
    let lines = h.events(&mut ev);
    assert!(has(&lines, "select ", &["x=Feb"]), "{lines:?}");
    assert_eq!(
        super::chart::points("m\tv\nJan\t3\nx\tnope\nFeb\t1,000\n", "m", "v"),
        vec![("Jan".to_string(), 3.), ("Feb".to_string(), 1000.)]
    );
}

#[gpui::test]
fn tree_document_with_data_types(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.write(
        &format!("{R}/tree"),
        "div root  style='v_flex size_full'\n\
         \x20 badge b  count=120  max=99\n\
         \x20   icon i  name=inbox  style=size=20\n\
         \x20 avatar-group g  max=3\n\
         \x20   avatar a  name='Ken Thompson'\n\
         \x20 progress p  value=72  variant=circle\n",
    );
    let [_, _, w, _] = h.bounds(&format!("{R}/b/i"));
    assert!(w > 0.);
}

/// The gallery example's data stories (examples/rc/gallery), written as
/// gallery.rc does: the story's `tree` document into the story node, then
/// its files at the same relative paths (`.tsv` through `tsv`).
#[gpui::test]
fn gallery_data_stories_render(cx: &mut TestAppContext) {
    macro_rules! g {
        ($p:literal) => {
            include_str!(concat!("../../../../../examples/rc/gallery/", $p))
        };
    }
    fn tsv_of(s: &str) -> String {
        s.lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| l.split('|').map(str::trim).collect::<Vec<_>>().join("\t") + "\n")
            .collect()
    }
    type Files = &'static [(&'static str, &'static str, bool)];
    let stories: &[(&str, &str, Files)] = &[
        ("badge", g!("badge/tree"), &[]),
        ("progress", g!("progress/tree"), &[]),
        ("avatar", g!("avatar/tree"), &[]),
        ("kbd", g!("kbd/tree"), &[]),
        (
            "chart",
            g!("chart/tree"),
            &[
                ("v/line/data", g!("chart/v/line/data.tsv"), true),
                ("v/bar/data", g!("chart/v/bar/data.tsv"), true),
                ("v/area/data", g!("chart/v/area/data.tsv"), true),
                ("v/pie/data", g!("chart/v/pie/data.tsv"), true),
            ],
        ),
        (
            "table",
            g!("table/tree"),
            &[
                ("t/columns", g!("table/t/columns.tsv"), true),
                ("t/rows", g!("table/t/rows.tsv"), true),
            ],
        ),
        (
            "tree",
            g!("treeview/tree"),
            &[
                ("t/items", g!("treeview/t/items.tsv"), true),
                ("t/expanded", g!("treeview/t/expanded"), false),
            ],
        ),
    ];
    let mut h = window(cx);
    h.ctl(R, "new scroll story style='flex_1 overflow_y_scroll p=24'");
    let s = format!("{R}/story");
    for (name, doc, files) in stories {
        if let Err(e) = h.try_write(&format!("{s}/tree"), doc) {
            panic!("{name}/tree: {e}");
        }
        for (f, body, is_tsv) in files.iter() {
            let body = if *is_tsv { tsv_of(body) } else { body.to_string() };
            if let Err(e) = h.try_write(&format!("{s}/{f}"), &body) {
                panic!("{name}/{f}: {e}");
            }
        }
        let [_, _, w, hh] = h.bounds(&s);
        assert!(w > 0. && hh > 0., "{name}");
    }
}
