//! Property tests: every format prints and parses back to the same value,
//! for many random values. A tiny xorshift generator keeps the crate free of
//! dev-dependencies; set `PROTO_SEED` to reproduce a failure.

use proto::lines::{
    self, Align, CanvasOp, Column, Completion, DescItem, Diagnostic, Entry, Item, KeyBinding,
    MenuKind, MenuLine, Message, OpKind, PathSeg, RadioItem, Row, Severity, TreeItem,
};
use proto::{
    Command, Event, Rgba, StateSel, StyleArg, StyleWord, doc, parse_ctl, parse_style, quote,
    tokenize,
};

const CASES: usize = 2000;

struct Rng(u64);

impl Rng {
    fn new() -> Self {
        let seed = std::env::var("PROTO_SEED")
            .ok()
            .and_then(|s| s.parse().ok())
            .filter(|&s| s != 0)
            .unwrap_or(0x9e3779b97f4a7c15);
        Rng(seed)
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    fn coin(&mut self) -> bool {
        self.next() & 1 == 1
    }
    fn pick<'a, T>(&mut self, xs: &'a [T]) -> &'a T {
        &xs[self.below(xs.len())]
    }
    fn string(&mut self, alphabet: &[char], min: usize, max: usize) -> String {
        let n = min + self.below(max - min + 1);
        (0..n).map(|_| *self.pick(alphabet)).collect()
    }
    /// Anything at all, including blanks, quotes, `=`, newlines.
    fn any(&mut self) -> String {
        self.string(&ANY, 0, 12)
    }
    /// Text for a TSV field: no tab, no newline.
    fn field(&mut self) -> String {
        self.string(&FIELD, 0, 10)
    }
    fn word(&mut self) -> String {
        self.string(&WORD, 1, 8)
    }
    fn ident(&mut self) -> String {
        let mut s = self.string(&LETTER, 1, 1);
        s += &self.string(&IDENT, 0, 8);
        s
    }
    fn num(&mut self) -> f32 {
        let n = (self.below(200000) as f32 - 100000.0) / [1.0, 10.0, 100.0, 4.0][self.below(4)];
        if n == 0.0 { 0.0 } else { n }
    }
    fn props(&mut self) -> Vec<(String, String)> {
        (0..self.below(4))
            .map(|_| (self.ident(), self.single_line()))
            .collect()
    }
    fn single_line(&mut self) -> String {
        self.string(&SINGLE, 0, 10)
    }
}

const ANY: [char; 16] = [
    'a', 'b', 'Z', '0', ' ', ' ', '\t', '\'', '\'', '=', '<', '\n', 'é', '日', '#', '-',
];
const SINGLE: [char; 14] = [
    'a', 'b', 'Z', '0', ' ', '\t', '\'', '\'', '=', '<', 'é', '日', '#', '-',
];
const FIELD: [char; 12] = ['a', 'b', 'Z', '0', ' ', '\'', '=', '<', 'é', '#', '-', ':'];
const WORD: [char; 10] = ['a', 'b', 'z', '0', '9', '-', '_', ':', '/', '.'];
const LETTER: [char; 4] = ['a', 'k', 'z', '_'];
const IDENT: [char; 7] = ['a', 'k', 'z', '_', '0', ':', '.'];

#[test]
fn quote_tokenize() {
    let mut r = Rng::new();
    for _ in 0..CASES {
        let words: Vec<String> = (0..r.below(5)).map(|_| r.any()).collect();
        let line = words
            .iter()
            .map(|w| quote(w).into_owned())
            .collect::<Vec<_>>()
            .join(if r.coin() { " " } else { " \t " });
        assert_eq!(tokenize(&line).unwrap(), words, "{line:?}");
    }
}

fn command(r: &mut Rng) -> Command {
    Command {
        verb: r.word(),
        args: (0..r.below(4)).map(|_| r.single_line()).collect(),
        props: r.props(),
    }
}

#[test]
fn ctl_commands() {
    let mut r = Rng::new();
    for _ in 0..CASES {
        let cmds: Vec<Command> = (0..1 + r.below(4)).map(|_| command(&mut r)).collect();
        let write = cmds
            .iter()
            .map(|c| c.to_string())
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        assert_eq!(parse_ctl(write.as_bytes()).unwrap(), cmds, "{write:?}");
    }
}

fn style_arg(r: &mut Rng) -> StyleArg {
    match r.below(5) {
        0 => StyleArg::Px(r.num()),
        1 => StyleArg::Percent(r.num()),
        2 => StyleArg::Rem(r.num()),
        3 => StyleArg::Color(Rgba {
            r: r.next() as u8,
            g: r.next() as u8,
            b: r.next() as u8,
            a: if r.coin() { 255 } else { r.next() as u8 },
        }),
        _ => StyleArg::Token(r.ident().replace(':', "_")),
    }
}

fn style_word(r: &mut Rng) -> StyleWord {
    let name = r.string(&['a', 'b', '_', '1', '-'], 1, 8);
    if r.below(8) == 0 {
        return StyleWord {
            state: None,
            group: Some(name),
            name: "group".into(),
            args: vec![],
        };
    }
    let state = match r.below(8) {
        0 => Some(StateSel::Hover),
        1 => Some(StateSel::Active),
        2 => Some(StateSel::Focus),
        3 => Some(StateSel::Disabled),
        4 => Some(StateSel::DropOver),
        5 => Some(StateSel::GroupHover(r.string(&['g', 'r', '_', '-'], 1, 5))),
        _ => None,
    };
    let args = (0..r.below(4)).map(|_| style_arg(r)).collect();
    StyleWord {
        state,
        group: None,
        name,
        args,
    }
}

#[test]
fn style_words() {
    let mut r = Rng::new();
    for _ in 0..CASES {
        let words: Vec<StyleWord> = (0..r.below(6)).map(|_| style_word(&mut r)).collect();
        let s = words
            .iter()
            .map(|w| w.to_string())
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(parse_style(&s).unwrap(), words, "{s:?}");
    }
}

#[test]
fn events() {
    let mut r = Rng::new();
    for _ in 0..CASES {
        let mut e = Event {
            name: r.word(),
            attrs: (0..r.below(5))
                .map(|_| (r.ident(), r.any()))
                .filter(|(k, _)| k != "seq")
                .collect(),
        };
        let seq = r.next() >> 12;
        let line = e.to_line(seq);
        // Always exactly one line; newlines in values become spaces.
        assert!(
            line.ends_with('\n') && !line[..line.len() - 1].contains('\n'),
            "{line:?}"
        );
        for (_, v) in &mut e.attrs {
            *v = v.replace('\n', " ");
        }
        assert_eq!(
            Event::parse_line(&line).unwrap(),
            (e, Some(seq)),
            "{line:?}"
        );
    }
}

fn doc_node(r: &mut Rng, depth: usize) -> doc::DocNode {
    let mut n = doc::DocNode::new(r.word(), r.word());
    for _ in 0..r.below(4) {
        let v = match r.below(4) {
            0 => r.any(),
            1 => format!("<<{}", r.word()),
            _ => r.single_line(),
        };
        n.props.push((r.ident(), v));
    }
    if depth < 4 {
        for _ in 0..r.below(4) {
            n.children.push(doc_node(r, depth + 1));
        }
    }
    n
}

#[test]
fn tree_documents() {
    let mut r = Rng::new();
    for _ in 0..CASES / 4 {
        let n = doc_node(&mut r, 0);
        let p = doc::print(&n);
        assert_eq!(doc::parse(&p).unwrap(), n, "{p}");
        assert_eq!(doc::print(&doc::parse(&p).unwrap()), p);
    }
}

fn check<T: lines::Line + PartialEq + std::fmt::Debug>(recs: Vec<T>) {
    let s = lines::print_lines(&recs);
    assert_eq!(lines::parse_lines::<T>(&s).unwrap(), recs, "{s:?}");
}

fn nonempty(r: &mut Rng) -> String {
    let mut s = r.field();
    if s.is_empty() {
        s.push('x');
    }
    s
}

#[test]
fn tsv_formats() {
    let mut r = Rng::new();
    for _ in 0..CASES / 4 {
        check(
            (0..r.below(6))
                .map(|_| match r.below(6) {
                    0 => Item::Separator,
                    1 => Item::Group(r.field()),
                    _ => {
                        let mut id = nonempty(&mut r);
                        if id == "-" || id.starts_with("# ") {
                            id.insert(0, 'i');
                        }
                        let mut e = Entry {
                            id,
                            label: r.field(),
                            ..Default::default()
                        };
                        e.fields = (0..r.below(3)).map(|_| format!("f{}", r.field())).collect();
                        e.icon = r.coin().then(|| r.word());
                        e.disabled = r.coin();
                        Item::Entry(e)
                    }
                })
                .collect(),
        );
        check(
            (0..r.below(5))
                .map(|_| Column {
                    id: nonempty(&mut r),
                    label: r.field(),
                    width: r.coin().then(|| r.num()),
                    sort: r.coin(),
                    fixed: r.coin(),
                    align: [
                        None,
                        Some(Align::Left),
                        Some(Align::Center),
                        Some(Align::Right),
                    ][r.below(4)],
                })
                .collect(),
        );
        check(
            (0..r.below(5))
                .map(|_| Row {
                    id: nonempty(&mut r),
                    cells: (0..r.below(5)).map(|_| r.field()).collect(),
                })
                .collect(),
        );
        check(
            (0..r.below(5))
                .map(|_| TreeItem {
                    id: nonempty(&mut r),
                    parent: r.coin().then(|| format!("p{}", r.field())),
                    label: r.field(),
                    icon: r.coin().then(|| r.word()),
                    disabled: r.coin(),
                })
                .collect(),
        );
        check(
            (0..r.below(5))
                .map(|_| DescItem {
                    label: r.field(),
                    value: format!("{}\t{}", r.field(), r.field()),
                })
                .collect(),
        );
        check(
            (0..r.below(5))
                .map(|_| RadioItem {
                    id: nonempty(&mut r),
                    label: r.field(),
                    disabled: r.coin(),
                })
                .collect(),
        );
        check(
            (0..r.below(5))
                .map(|_| Diagnostic {
                    line: r.next() as u32,
                    col: r.next() as u32,
                    len: r.below(100) as u32,
                    severity: *r.pick(&[
                        Severity::Error,
                        Severity::Warning,
                        Severity::Info,
                        Severity::Hint,
                    ]),
                    message: format!("{}\t{}", r.field(), r.field()),
                })
                .collect(),
        );
        check(
            (0..r.below(5))
                .map(|_| Completion {
                    text: nonempty(&mut r),
                    label: r.coin().then(|| format!("l{}", r.field())),
                    kind: r.coin().then(|| r.field()),
                    detail: r.coin().then(|| r.field()),
                })
                .collect(),
        );
    }
}

#[test]
fn word_formats() {
    let mut r = Rng::new();
    for _ in 0..CASES / 4 {
        // Menus: a valid nesting.
        let mut menu = Vec::new();
        let mut depth = 0;
        for _ in 0..r.below(8) {
            let kind = *r.pick(&[MenuKind::Item, MenuKind::Item, MenuKind::Sep, MenuKind::Sub]);
            let (id, props) = if kind == MenuKind::Sep {
                (String::new(), vec![])
            } else {
                (r.single_line(), r.props())
            };
            menu.push(MenuLine {
                depth,
                kind,
                id,
                props,
            });
            depth = if kind == MenuKind::Sub {
                depth + 1
            } else {
                r.below(depth + 1)
            };
        }
        let s = lines::print_lines(&menu);
        assert_eq!(lines::parse_menu(&s).unwrap(), menu, "{s}");

        check(
            (0..r.below(5))
                .map(|_| KeyBinding {
                    keys: (0..1 + r.below(2)).map(|_| r.single_line()).collect(),
                    action: r.single_line(),
                    props: r.props(),
                })
                .collect(),
        );

        check(
            (0..r.below(5))
                .map(|_| {
                    let kind = *r.pick(&[
                        OpKind::Rect,
                        OpKind::Circle,
                        OpKind::Line,
                        OpKind::Path,
                        OpKind::Text,
                        OpKind::Image,
                    ]);
                    let mut op = CanvasOp {
                        kind,
                        id: r.single_line(),
                        props: r.props(),
                        ..Default::default()
                    };
                    if kind == OpKind::Path {
                        op.path = (0..1 + r.below(4))
                            .map(|_| {
                                let (c, n) = *r.pick(&[
                                    ('M', 2),
                                    ('l', 2),
                                    ('H', 1),
                                    ('C', 6),
                                    ('q', 4),
                                    ('A', 7),
                                    ('Z', 0),
                                ]);
                                let sets = if n == 0 { 0 } else { 1 + r.below(2) };
                                PathSeg {
                                    cmd: c,
                                    args: (0..n * sets).map(|_| r.num()).collect(),
                                }
                            })
                            .collect();
                    } else {
                        op.geom = (0..kind.arity()).map(|_| r.num()).collect();
                    }
                    if kind == OpKind::Text {
                        op.text = Some(r.single_line());
                    }
                    op
                })
                .collect(),
        );
    }
}

#[test]
fn message_lists() {
    let mut r = Rng::new();
    for _ in 0..CASES / 4 {
        let msgs: Vec<Message> = (0..r.below(4))
            .map(|_| {
                // Body lines never read as headers, and the body has no
                // leading or trailing blank lines.
                let n = r.below(5);
                let body: Vec<String> = (0..n)
                    .map(|i| {
                        if i > 0 && i + 1 < n && r.below(3) == 0 {
                            String::new()
                        } else {
                            format!("> {}", r.field())
                        }
                    })
                    .collect();
                Message {
                    id: r.word(),
                    role: r.pick(lines::ROLES).to_string(),
                    time: if r.coin() { r.word() } else { String::new() },
                    body: body.join("\n"),
                }
            })
            .collect();
        let s = lines::print_messages(&msgs);
        assert_eq!(lines::parse_messages(&s).unwrap(), msgs, "{s:?}");
    }
}
