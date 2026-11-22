//! The design's own snippets, and every tree document and keymap in
//! `examples/`, parse.

use proto::lines::{
    self, CanvasOp, Column, Diagnostic, Item, KeyBinding, MenuKind, OpKind, TreeItem,
};
use proto::{
    Command, ErrorKind, Event, Rgba, StateSel, StyleArg, doc, parse_ctl, parse_style, quote,
    tokenize,
};
use std::path::{Path, PathBuf};

const SIGNIN: &str = "\
div root  style='v_flex size_full p=24 gap=16'
  text title  style='text_xl font_semibold'  text='Sign in'
  form f  layout=v
    field user  label=Email
      input in  placeholder=you@example.com
    field pass  label=Password
      input in  flags=secret
    field go
      button submit  label='Sign in'  style='primary w_full'  tag=login
  link help  label='Forgot password?'  href=https://example.com/reset
";

#[test]
fn signin_tree_round_trips() {
    let d = doc::parse(SIGNIN).unwrap();
    assert_eq!((d.ty.as_str(), d.name.as_str()), ("div", "root"));
    assert_eq!(d.prop("style"), Some("v_flex size_full p=24 gap=16"));
    assert_eq!(d.children.len(), 3);
    let title = d.child("title").unwrap();
    assert_eq!(title.prop("text"), Some("Sign in"));
    let submit = d
        .child("f")
        .unwrap()
        .child("go")
        .unwrap()
        .child("submit")
        .unwrap();
    assert_eq!(submit.ty, "button");
    assert_eq!(submit.prop("label"), Some("Sign in"));
    assert_eq!(submit.prop("tag"), Some("login"));
    assert_eq!(
        d.child("f")
            .unwrap()
            .child("pass")
            .unwrap()
            .child("in")
            .unwrap()
            .prop("flags"),
        Some("secret")
    );
    assert_eq!(
        d.child("help").unwrap().prop("href"),
        Some("https://example.com/reset")
    );
    // The design writes it canonically, so it prints back byte for byte.
    assert_eq!(doc::print(&d), SIGNIN);
}

const NOTES: &str = "\
div root  style='h_flex size_full'
  sidebar nav  style=w=220
    list notes  searchable=on  selectable=on  tag=pick
  div page  style='v_flex flex_1'
    toolbar bar
      button save  label=Save  icon=check  style='ghost sm'  tag=save
      button del   label=Delete  icon=trash  style='ghost sm danger'  tag=del
    editor body  style=flex_1  language=markdown  soft_wrap=on
";

#[test]
fn notes_tree_parses() {
    let d = doc::parse(NOTES).unwrap();
    assert_eq!(d.child("nav").unwrap().prop("style"), Some("w=220"));
    let bar = d.child("page").unwrap().child("bar").unwrap();
    assert_eq!(
        bar.children
            .iter()
            .map(|c| c.name.as_str())
            .collect::<Vec<_>>(),
        ["save", "del"]
    );
    // Not canonical (`del   label`), but stable once printed.
    let p = doc::print(&d);
    assert_eq!(doc::parse(&p).unwrap(), d);
    assert_eq!(doc::print(&doc::parse(&p).unwrap()), p);
}

#[test]
fn heredoc_blocks() {
    let src = "\
div root
  markdown m  text=<<END  style=p=4
# Title

Body with 'quotes' and  spaces.
END
  text t  text=short
";
    let d = doc::parse(src).unwrap();
    let m = d.child("m").unwrap();
    assert_eq!(
        m.prop("text"),
        Some("# Title\n\nBody with 'quotes' and  spaces.")
    );
    assert_eq!(m.prop("style"), Some("p=4"));
    let canonical = "\
div root
  markdown m  text=<<END  style=p=4
# Title

Body with 'quotes' and  spaces.
  END
  text t  text=short
";
    assert_eq!(doc::print(&d), canonical);
    assert_eq!(doc::parse(canonical).unwrap(), d);

    // A value with an END line gets another marker; trailing newline kept.
    let mut n = doc::DocNode::new("editor", "e");
    n.props.push(("value".into(), "a\nEND\n".into()));
    n.props.push(("x".into(), "<<END".into()));
    let p = doc::print(&n);
    assert_eq!(p, "editor e  value=<<END1  x='<<END'\na\nEND\n\nEND1\n");
    assert_eq!(doc::parse(&p).unwrap(), n);
}

#[test]
fn doc_errors() {
    let bad = [
        ("", "empty document"),
        ("div a\ndiv b\n", "more than one root"),
        ("div a\n    div b\n", "indent skips a level"),
        ("div a\n div b\n", "odd indent"),
        ("div a\n\tdiv b\n", "tab in indent"),
        ("div\n", "want type and name"),
        ("div a b\n", "want prop=value"),
        ("div a  text=<<END\nno end\n", "no END line"),
        ("div a  x='open\n", "unterminated quote"),
        ("  div a\n", "indent skips a level"),
    ];
    for (src, want) in bad {
        let e = doc::parse(src).unwrap_err();
        assert_eq!(e.kind, ErrorKind::BadSyntax, "{src:?}");
        assert!(e.detail.contains(want), "{src:?}: {e}");
    }
}

#[test]
fn quoting_rule() {
    assert_eq!(tokenize("a  b\tc").unwrap(), ["a", "b", "c"]);
    assert_eq!(tokenize("'it''s'").unwrap(), ["it's"]);
    assert_eq!(tokenize("''").unwrap(), [""]);
    assert_eq!(
        tokenize("title='Sign in' x").unwrap(),
        ["title=Sign in", "x"]
    );
    assert_eq!(tokenize("a'b c'd").unwrap(), ["ab cd"]);
    assert_eq!(tokenize("   ").unwrap(), Vec::<String>::new());
    assert_eq!(tokenize("'open").unwrap_err().kind, ErrorKind::BadSyntax);
    assert_eq!(quote("go"), "go");
    assert_eq!(quote(""), "''");
    assert_eq!(quote("Sign in"), "'Sign in'");
    assert_eq!(quote("it's"), "'it''s'");
    assert_eq!(quote("a=b"), "a=b");
}

#[test]
fn ctl_snippets() {
    let w = b"new form prefs layout=v";
    let c = parse_ctl(w).unwrap();
    assert_eq!(
        c,
        [Command {
            verb: "new".into(),
            args: vec!["form".into(), "prefs".into()],
            props: vec![("layout".into(), "v".into())]
        }]
    );

    let c = parse_ctl(b"new field name label=Name\nnew field lang label=Language\nnew field ok\n")
        .unwrap();
    assert_eq!(c.len(), 3);
    assert_eq!(c[2].args, ["field", "ok"]);

    let c = parse_ctl(b"new input in placeholder='Your name'").unwrap();
    assert_eq!(c[0].prop("placeholder"), Some("Your name"));

    let c = parse_ctl(b"new div card1 style='v_flex gap=4 p=12 rounded_md border_1 border_color=border hover:bg=accent cursor_pointer' tag=open:42").unwrap();
    assert_eq!(
        c[0].prop("style"),
        Some(
            "v_flex gap=4 p=12 rounded_md border_1 border_color=border hover:bg=accent cursor_pointer"
        )
    );
    assert_eq!(c[0].prop("tag"), Some("open:42"));

    let c =
        parse_ctl(b"notify 'Upload failed' type=error sticky=on action=retry:'Try again'").unwrap();
    assert_eq!(c[0].args, ["Upload failed"]);
    assert_eq!(c[0].prop("action"), Some("retry:Try again"));

    let c = parse_ctl(b"window main title=Notes size=900,600").unwrap();
    assert_eq!((c[0].verb.as_str(), c[0].arg(0)), ("window", Some("main")));
    assert_eq!(c[0].prop("size"), Some("900,600"));

    let c = parse_ctl(b"new alert-dialog confirm-del title='Delete 3 files?' description='This cannot be undone.' confirm=Delete cancel=Keep variant=danger tag=del").unwrap();
    assert_eq!(c[0].prop("title"), Some("Delete 3 files?"));
    assert_eq!(c[0].prop("variant"), Some("danger"));

    let c =
        parse_ctl(b"set save enabled=off\nclose seq=120\nnew button eq label== style='primary lg'")
            .unwrap();
    assert_eq!(c[0].args, ["save"]);
    assert_eq!(c[1].prop("seq"), Some("120"));
    assert_eq!(c[2].prop("label"), Some("="));

    // A quoted = stays positional, and prints back quoted.
    let c = Command::parse("notify 'a=b'").unwrap();
    assert_eq!(c.args, ["a=b"]);
    assert_eq!(c.to_string(), "notify 'a=b'");

    // All or nothing.
    let e = parse_ctl(b"new div a\nnew div 'b\n").unwrap_err();
    assert_eq!(e.kind, ErrorKind::BadSyntax);
    assert!(e.detail.starts_with("line 2"), "{e}");
    assert_eq!(parse_ctl(&[0xff]).unwrap_err().kind, ErrorKind::BadSyntax);
    assert_eq!(
        parse_ctl(&vec![b'a'; 64 * 1024 + 1]).unwrap_err().kind,
        ErrorKind::TooLarge
    );
    assert_eq!(parse_ctl(b"x=1").unwrap_err().kind, ErrorKind::BadSyntax);
    assert!(parse_ctl(b"\n\n").unwrap().is_empty());
}

#[test]
fn style_snippets() {
    for s in [
        "v_flex size_full p_4 gap_3",
        "flex_col items_center size_full rounded_md overflow_y_scroll cursor_pointer",
        "w=240 gap=12 p=16 text_size=13 w=50% px=1.5rem",
        "bg=primary text_color=muted_foreground border_color=border bg=#1e1e2e",
        "shadow=0,4,12,#0003 hover:bg=accent focus:border_color=ring",
        "h_flex gap=8 p=12 rounded_lg bg=muted hover:bg=accent cursor_pointer",
        "group:row group-hover(row):visible drop-over:bg=accent disabled:opacity=0.5 active:bg=muted",
    ] {
        let words = parse_style(s).unwrap_or_else(|e| panic!("{s}: {e}"));
        let back = words
            .iter()
            .map(|w| w.to_string())
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(parse_style(&back).unwrap(), words);
    }
    let w = parse_style("shadow=0,4,12,#0003").unwrap().remove(0);
    assert_eq!(
        w.args,
        [
            StyleArg::Px(0.0),
            StyleArg::Px(4.0),
            StyleArg::Px(12.0),
            StyleArg::Color(Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0x33
            })
        ]
    );
    let w = parse_style("px=1.5rem").unwrap().remove(0);
    assert_eq!(w.args, [StyleArg::Rem(1.5)]);
    let w = parse_style("w=50%").unwrap().remove(0);
    assert_eq!(w.args, [StyleArg::Percent(50.0)]);
    let w = parse_style("hover:bg=accent").unwrap().remove(0);
    assert_eq!(
        (w.state, w.name.as_str(), w.args),
        (
            Some(StateSel::Hover),
            "bg",
            vec![StyleArg::Token("accent".into())]
        )
    );
    let w = parse_style("group-hover(card):text_color=primary")
        .unwrap()
        .remove(0);
    assert_eq!(w.state, Some(StateSel::GroupHover("card".into())));
    let w = parse_style("group:card").unwrap().remove(0);
    assert_eq!(
        (w.name.as_str(), w.group.as_deref()),
        ("group", Some("card"))
    );
    assert_eq!(w.to_string(), "group:card");
    assert_eq!(
        parse_style("bg=#1e1e2e").unwrap()[0].to_string(),
        "bg=#1e1e2e"
    );

    assert_eq!(parse_style("w=12x").unwrap_err().kind, ErrorKind::BadValue);
    assert_eq!(
        parse_style("bg=#12345").unwrap_err().kind,
        ErrorKind::BadValue
    );
    assert_eq!(
        parse_style("hovr:bg=accent").unwrap_err().to_string(),
        "unknown style word: hovr:bg=accent"
    );
    assert_eq!(parse_style("w=").unwrap_err().kind, ErrorKind::BadSyntax);
    assert_eq!(
        parse_style("shadow=1,,2").unwrap_err().kind,
        ErrorKind::BadSyntax
    );
    assert_eq!(parse_style("a=b!").unwrap_err().kind, ErrorKind::BadSyntax);
    // `w=wide` is syntactically a token; the style table rejects it.
    assert_eq!(
        parse_style("w=wide").unwrap()[0].args,
        [StyleArg::Token("wide".into())]
    );
}

#[test]
fn event_lines() {
    let e = Event::new("click")
        .attr("win", "main")
        .attr("node", "root/prefs/ok/save")
        .attr("tag", "save");
    assert_eq!(
        e.to_line(118),
        "click win=main node=root/prefs/ok/save tag=save seq=118\n"
    );
    let e = Event::new("change")
        .attr("win", "main")
        .attr("node", "root/prefs/lang/in")
        .attr("tag", "")
        .attr("value", "go");
    assert_eq!(
        e.to_line(119),
        "change win=main node=root/prefs/lang/in tag='' value=go seq=119\n"
    );
    let e = Event::new("select").attr("value", "Tokyo Night");
    assert_eq!(e.to_line(1), "select value='Tokyo Night' seq=1\n");
    let (back, seq) =
        Event::parse_line("change win=main node=root/prefs/lang/in tag='' value=go seq=119\n")
            .unwrap();
    assert_eq!(seq, Some(119));
    assert_eq!(back.get("tag"), Some(""));
    assert_eq!(
        Event::parse_line("resync seq=42").unwrap(),
        (Event::new("resync"), Some(42))
    );
    assert_eq!(
        Event::parse_line("gone").unwrap(),
        (Event::new("gone"), None)
    );
}

#[test]
fn error_phrases() {
    let table = [
        (ErrorKind::UnknownCommand, "unknown command"),
        (ErrorKind::BadSyntax, "bad syntax"),
        (ErrorKind::UnknownStyleWord, "unknown style word"),
        (ErrorKind::UnknownType, "unknown type"),
        (ErrorKind::TypeIsFixed, "type is fixed"),
        (ErrorKind::InUse, "in use"),
        (ErrorKind::NotFound, "not found"),
        (ErrorKind::BadValue, "bad value"),
        (ErrorKind::TooLarge, "too large"),
        (ErrorKind::ShortRead, "short read"),
        (ErrorKind::NoBatch, "no batch"),
        (ErrorKind::AppGone, "app gone"),
    ];
    for (k, p) in table {
        assert_eq!(k.phrase(), p);
        assert_eq!(ErrorKind::from_phrase(p), Some(k));
    }
    let e = proto::Error::new(ErrorKind::UnknownStyleWord, "flexx");
    assert_eq!(e.to_string(), "unknown style word: flexx");
    assert_eq!(proto::Error::parse("unknown style word: flexx"), Some(e));
    assert_eq!(
        proto::Error::new(ErrorKind::NoBatch, "").to_string(),
        "no batch"
    );
    assert_eq!(
        proto::Error::parse("no batch"),
        Some(proto::Error::new(ErrorKind::NoBatch, ""))
    );
}

const OPS: &str = "\
rect   bg      0 0 400 300   fill=background
rect   card    20 20 160 90  fill=muted radius=8 border=border
path   spark   M20,200 L60,180 L100,190 L140,150  stroke=primary width=2
circle dot     140 150 4     fill=primary
text   lbl     28 44         'Revenue'  size=13 color=muted_foreground
image  logo    360 12 24 24  src=@logo
";

#[test]
fn canvas_ops() {
    let ops: Vec<CanvasOp> = lines::parse_lines(OPS).unwrap();
    assert_eq!(ops.len(), 6);
    assert_eq!(ops[1].geom, [20.0, 20.0, 160.0, 90.0]);
    assert_eq!(ops[1].prop("radius"), Some("8"));
    assert_eq!(ops[2].kind, OpKind::Path);
    assert_eq!(ops[2].path.len(), 4);
    assert_eq!(ops[2].path[0].to_string(), "M20,200");
    assert_eq!(ops[3].geom, [140.0, 150.0, 4.0]);
    assert_eq!(ops[4].text.as_deref(), Some("Revenue"));
    assert_eq!(ops[5].prop("src"), Some("@logo"));
    assert_eq!(
        ops[4].to_string(),
        "text lbl 28 44 Revenue size=13 color=muted_foreground"
    );
    let back: Vec<CanvasOp> = lines::parse_lines(&lines::print_lines(&ops)).unwrap();
    assert_eq!(back, ops);

    // From the examples: hover: attrs, %.1f numbers, cap=round.
    let op = CanvasOp::parse(
        "path tick3 M120.5,10.0 L120.5,22.0 stroke=muted_foreground width=2 cap=round",
    )
    .unwrap();
    assert_eq!(op.path[1].args, [120.5, 22.0]);
    let op =
        CanvasOp::parse("rect c1_2 12 24 11 11 fill=primary radius=2 hover:fill=accent").unwrap();
    assert_eq!(op.prop("hover:fill"), Some("accent"));

    assert_eq!(
        CanvasOp::parse("blob x 1 2").unwrap_err().kind,
        ErrorKind::BadValue
    );
    assert_eq!(
        CanvasOp::parse("rect x 1 2 3").unwrap_err().kind,
        ErrorKind::BadSyntax
    );
    assert_eq!(
        CanvasOp::parse("rect x 1 2 3 wide").unwrap_err().kind,
        ErrorKind::BadValue
    );
    assert_eq!(
        CanvasOp::parse("path p M1").unwrap_err().kind,
        ErrorKind::BadValue
    );
}

const MENU: &str = "\
item new    label=New      key=cmd-n
item open   label=Open…    key=cmd-o
sep
sub recent  label='Open Recent'
item quit   label=Quit     key=cmd-q
";

#[test]
fn menu_lines() {
    let m = lines::parse_menu(MENU).unwrap();
    assert_eq!(m.len(), 5);
    assert_eq!(
        (m[0].kind, m[0].id.as_str(), m[0].prop("key")),
        (MenuKind::Item, "new", Some("cmd-n"))
    );
    assert_eq!(m[1].prop("label"), Some("Open…"));
    assert_eq!(m[2].kind, MenuKind::Sep);
    assert_eq!(
        (m[3].kind, m[3].prop("label")),
        (MenuKind::Sub, Some("Open Recent"))
    );
    assert_eq!(m[3].to_string(), "sub recent label='Open Recent'");

    let nested =
        "sub recent label='Open Recent'\n  item r1 label=a.txt\n  sep\nitem quit label=Quit\n";
    let m = lines::parse_menu(nested).unwrap();
    assert_eq!(m[1].depth, 1);
    assert_eq!(lines::print_lines(&m), nested);
    assert!(lines::parse_menu("item a\n  item b\n").is_err());
    assert_eq!(
        lines::parse_menu("itme a\n").unwrap_err().kind,
        ErrorKind::UnknownCommand
    );

    // counter.rc: key== binds the = key.
    let m = lines::parse_menu(
        "item inc    label=Increment  key==\nitem dec    label=Decrement  key=-\n",
    )
    .unwrap();
    assert_eq!(m[0].prop("key"), Some("="));
}

const KEYMAP: &str = "\
cmd-s        save
cmd-shift-p  palette
escape       dismiss      context=editor
ctrl-tab     next-tab     context=workspace
";

#[test]
fn keymap_lines() {
    let k: Vec<KeyBinding> = lines::parse_lines(KEYMAP).unwrap();
    assert_eq!(k[0].keys, ["cmd-s"]);
    assert_eq!(k[0].action, "save");
    assert_eq!(k[2].context(), Some("editor"));
    assert_eq!(k[3].to_string(), "ctrl-tab next-tab context=workspace");
    let k = KeyBinding::parse("cmd-k cmd-s save-all").unwrap();
    assert_eq!(k.keystrokes(), "cmd-k cmd-s");
    // calc.rc and counter.rc bind = itself.
    assert_eq!(KeyBinding::parse("=          k:eq").unwrap().keys, ["="]);
    assert_eq!(KeyBinding::parse("cmd-= zoom-in").unwrap().keys, ["cmd-="]);
    assert!(KeyBinding::parse("save").is_err());
}

#[test]
fn tsv_lines() {
    let items: Vec<Item> =
        lines::parse_lines("rs\tRust\ngo\tGo\n# Systems\nc\tC\ticon=cpu\tdisabled\n-\n").unwrap();
    assert_eq!(items.len(), 5);
    assert_eq!(items[0].entry().unwrap().label, "Rust");
    assert_eq!(items[2], Item::Group("Systems".into()));
    let c = items[3].entry().unwrap();
    assert_eq!((c.icon.as_deref(), c.disabled), (Some("cpu"), true));
    assert_eq!(items[4], Item::Separator);
    assert_eq!(
        lines::print_lines(&items),
        "rs\tRust\ngo\tGo\n# Systems\nc\tC\ticon=cpu\tdisabled\n-\n"
    );
    // hn.py: extra fields for a row template.
    let it = Item::parse("4211\tShow HN: x\t120\tpg\t33\texample.com").unwrap();
    assert_eq!(
        it.entry().unwrap().fields,
        ["120", "pg", "33", "example.com"]
    );

    let cols: Vec<Column> = lines::parse_lines(
        "name\tName\t280\tsort\nsize\tSize\t90\tsort\talign=right\nmod\tModified\t160\tsort\n",
    )
    .unwrap();
    assert_eq!(cols[1].width, Some(90.0));
    assert_eq!(cols[1].align, Some(lines::Align::Right));
    assert_eq!(cols[1].to_string(), "size\tSize\t90\tsort\talign=right");
    let c = Column::parse("sym\tSymbol\t90\tsort\tfixed").unwrap();
    assert!(c.fixed && c.sort);
    assert_eq!(
        Column::parse("a\tA\twide").unwrap_err().kind,
        ErrorKind::BadValue
    );

    let t = TreeItem::parse("src/main\tsrc\tmain.rs\ticon=file").unwrap();
    assert_eq!(
        (t.parent.as_deref(), t.icon.as_deref()),
        (Some("src"), Some("file"))
    );
    assert_eq!(
        TreeItem::parse("src\t-\tsrc\ticon=folder").unwrap().parent,
        None
    );

    let d = Diagnostic::parse("12\t5\t3\terror\tmismatched types").unwrap();
    assert_eq!(
        (d.line, d.col, d.len, d.message.as_str()),
        (12, 5, 3, "mismatched types")
    );
    assert_eq!(d.to_string(), "12\t5\t3\terror\tmismatched types");
    assert_eq!(
        Diagnostic::parse("x\t5\t3\terror\tm").unwrap_err().kind,
        ErrorKind::BadValue
    );

    let (seq, cs) =
        lines::parse_completions("seq=301\nprintln!\tprintln!(…)\tkind=macro\nprint\n").unwrap();
    assert_eq!(seq, 301);
    assert_eq!(cs[0].kind.as_deref(), Some("macro"));
    assert_eq!(cs[1].label, None);
    assert!(lines::parse_completions("println\n").is_err());
}

#[test]
fn messages() {
    // chat.rc's transcript, with a markdown reply that has blank lines.
    let log = "m1 assistant 10:01\nHello, I'm **Eliza**.\n\nm2 user 10:02\ntell me about rc\n\nm3 assistant 10:02\nAh, a person of taste:\n\n```rc\necho hi\n```\n\n";
    let m = lines::parse_messages(log).unwrap();
    assert_eq!(m.len(), 3);
    assert_eq!(m[0].body, "Hello, I'm **Eliza**.");
    assert_eq!(
        (m[1].id.as_str(), m[1].role.as_str(), m[1].time.as_str()),
        ("m2", "user", "10:02")
    );
    assert_eq!(m[2].body, "Ah, a person of taste:\n\n```rc\necho hi\n```");
    assert_eq!(lines::print_messages(&m), log);
    assert!(lines::parse_messages("not a header at all here\n").is_err());
}

fn examples() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../examples")
}

/// Bodies of `cat >...<<'END'` here documents whose target ends in `suffix`.
fn heredocs(src: &str, suffix: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut lines = src.lines();
    while let Some(l) = lines.next() {
        let l = l.trim();
        if l.starts_with("cat >") && l.contains(suffix) && l.ends_with("<<'END'") {
            let target = l.split_whitespace().nth(1).unwrap();
            if !target.ends_with(suffix) {
                continue;
            }
            let body: Vec<&str> = lines.by_ref().take_while(|l| *l != "END").collect();
            out.push(body.join("\n") + "\n");
        }
    }
    out
}

#[test]
fn example_documents_parse() {
    let mut n = 0;
    let rc = examples().join("rc");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&rc)
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    files.push(examples().join("python/hn.py"));
    files.sort();
    for f in &files {
        if f.extension().is_none_or(|e| e != "rc" && e != "py") {
            continue;
        }
        let src = std::fs::read_to_string(f).unwrap();
        for d in heredocs(&src, "/tree") {
            let node = doc::parse(&d).unwrap_or_else(|e| panic!("{}: {e}\n{d}", f.display()));
            let p = doc::print(&node);
            assert_eq!(doc::parse(&p).unwrap(), node, "{}", f.display());
            n += 1;
        }
        for k in heredocs(&src, "/keymap") {
            let _: Vec<KeyBinding> =
                lines::parse_lines(&k).unwrap_or_else(|e| panic!("{}: {e}", f.display()));
        }
    }
    for e in std::fs::read_dir(rc.join("gallery")).unwrap() {
        let t = e.unwrap().path().join("tree");
        let src = std::fs::read_to_string(&t).unwrap();
        doc::parse(&src).unwrap_or_else(|e| panic!("{}: {e}", t.display()));
        n += 1;
    }
    assert!(n >= 30, "only {n} documents found");
}

#[test]
fn example_tsv_files_parse() {
    let g = examples().join("rc/gallery");
    let tsv = |p: &str| std::fs::read_to_string(g.join(p)).unwrap();
    // The gallery's tree items are written with `tsv` (" | " to tabs).
    let detab = |s: String| {
        s.lines()
            .map(|l| {
                l.split('|')
                    .map(|f| f.trim())
                    .collect::<Vec<_>>()
                    .join("\t")
            })
            .collect::<Vec<_>>()
            .join("\n")
    };
    let items: Vec<TreeItem> = lines::parse_lines(&detab(tsv("treeview/t/items.tsv"))).unwrap();
    assert!(items.iter().any(|i| i.parent.is_none()));
    let _: Vec<Column> = lines::parse_lines(&detab(tsv("table/t/columns.tsv"))).unwrap();
    let _: Vec<lines::Row> = lines::parse_lines(&detab(tsv("table/t/rows.tsv"))).unwrap();
}
