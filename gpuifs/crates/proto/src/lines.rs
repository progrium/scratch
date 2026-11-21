//! Line formats for data files (items, columns, TSV rows, tree items,
//! description-list items, radio items, menus, keymap, canvas ops,
//! diagnostics, message-list items, completions). Each type has `parse(&str)`
//! for one line and `Display` printing that line without its newline.
//! Fields are W1's to define; only the type names are contract.
//!
//! Two families:
//!
//! - **Tab-separated** (`items`, `columns`, `rows`, tree `items`,
//!   description-list `items`, radio `items`, `diagnostics`, `completions`):
//!   fields split on TAB, never quoted. Text can't hold a tab or newline.
//! - **Word lines** (`menu`, `keymap`, canvas `ops`): words in the one
//!   quoting rule, as on a `ctl` line, so `label='Open Recent'` works.
//!
//! [`parse_lines`] reads a whole file of one format, skipping blank lines
//! and dropping a CR before each LF. `message-list` items are records of
//! several lines and have their own [`parse_messages`].

use std::fmt;

use crate::tok::{self, quote, quote_word};
use crate::{Command, Error, ErrorKind, parse_number};

/// A format whose file is one record per line.
pub trait Line: Sized + fmt::Display {
    fn parse_line(line: &str) -> Result<Self, Error>;
}

/// Every non-blank line of `text` as `T`, all or nothing. Errors say which
/// line (1-based) failed.
pub fn parse_lines<T: Line>(text: &str) -> Result<Vec<T>, Error> {
    parse_lines_at(text, 1)
}

fn parse_lines_at<T: Line>(text: &str, first: usize) -> Result<Vec<T>, Error> {
    text.split('\n')
        .enumerate()
        .map(|(i, l)| (i, l.strip_suffix('\r').unwrap_or(l)))
        .filter(|(_, l)| !l.is_empty())
        .map(|(i, l)| T::parse_line(l).map_err(|e| e.at_line(i + first)))
        .collect()
}

/// Each record's line plus `\n`.
pub fn print_lines<T: Line>(recs: &[T]) -> String {
    let mut s = String::new();
    for r in recs {
        s.push_str(&r.to_string());
        s.push('\n');
    }
    s
}

macro_rules! line_impl {
    ($($t:ty),*) => {$(
        impl Line for $t {
            fn parse_line(line: &str) -> Result<Self, Error> { <$t>::parse(line) }
        }
    )*};
}
line_impl!(
    Item, Column, Row, TreeItem, DescItem, RadioItem, MenuLine, KeyBinding, CanvasOp, Diagnostic,
    Completion
);

fn syntax(d: impl Into<String>) -> Error {
    Error::new(ErrorKind::BadSyntax, d)
}

fn value(d: impl Into<String>) -> Error {
    Error::new(ErrorKind::BadValue, d)
}

fn need_id(id: &str, what: &str) -> Result<String, Error> {
    if id.is_empty() {
        Err(syntax(format!("{what} with no id")))
    } else {
        Ok(id.to_string())
    }
}

fn write_tsv(f: &mut fmt::Formatter<'_>, fields: &[&str]) -> fmt::Result {
    f.write_str(&fields.join("\t"))
}

// ---------------------------------------------------------------------------
// items: select, combobox, list, breadcrumb, stepper

/// One line of the select format (DESIGN § Buttons and form controls):
///
/// ```text
/// id<TAB>label[<TAB>icon=name][<TAB>disabled]
/// # a line starting with "# " is a group header; "-" alone is a separator
/// ```
///
/// A `list` with a `row` template carries more TSV columns after the label,
/// named by its `fields` file; those are `Entry::fields`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Item {
    Entry(Entry),
    Group(String),
    #[default]
    Separator,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Entry {
    pub id: String,
    /// Empty when the line has only an id.
    pub label: String,
    /// Further TSV columns, in order, other than `icon=` and `disabled`.
    pub fields: Vec<String>,
    pub icon: Option<String>,
    pub disabled: bool,
}

impl Item {
    pub fn parse(line: &str) -> Result<Self, Error> {
        if line == "-" {
            return Ok(Item::Separator);
        }
        if let Some(g) = line.strip_prefix("# ") {
            return Ok(Item::Group(g.to_string()));
        }
        let mut f = line.split('\t');
        let mut e = Entry {
            id: need_id(f.next().unwrap(), "item")?,
            ..Default::default()
        };
        e.label = f.next().unwrap_or("").to_string();
        for x in f {
            if x == "disabled" {
                e.disabled = true;
            } else if let (Some(i), None) = (x.strip_prefix("icon="), &e.icon) {
                e.icon = Some(i.to_string());
            } else {
                e.fields.push(x.to_string());
            }
        }
        Ok(Item::Entry(e))
    }

    pub fn entry(&self) -> Option<&Entry> {
        if let Item::Entry(e) = self {
            Some(e)
        } else {
            None
        }
    }
}

/// `id label fields... icon=x disabled`, the label left out only when it
/// is empty and nothing follows it.
impl fmt::Display for Item {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Item::Separator => f.write_str("-"),
            Item::Group(g) => write!(f, "# {g}"),
            Item::Entry(e) => {
                let icon = e.icon.as_ref().map(|i| format!("icon={i}"));
                let mut v: Vec<&str> = vec![&e.id, &e.label];
                v.extend(e.fields.iter().map(|s| s.as_str()));
                v.extend(icon.as_deref());
                if e.disabled {
                    v.push("disabled");
                }
                if v.len() == 2 && e.label.is_empty() {
                    v.pop();
                }
                write_tsv(f, &v)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// table columns and rows

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Align {
    #[default]
    Left,
    Center,
    Right,
}

impl Align {
    fn word(self) -> &'static str {
        match self {
            Align::Left => "left",
            Align::Center => "center",
            Align::Right => "right",
        }
    }
}

/// A table `columns` line: `id<TAB>label[<TAB>width][<TAB>sort][<TAB>fixed][<TAB>align=right]`.
/// The options after the label may come in any order; `print` writes them
/// in this one.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Column {
    pub id: String,
    pub label: String,
    pub width: Option<f32>,
    pub sort: bool,
    pub fixed: bool,
    pub align: Option<Align>,
}

impl Column {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let mut f = line.split('\t');
        let mut c = Column {
            id: need_id(f.next().unwrap(), "column")?,
            ..Default::default()
        };
        c.label = f.next().unwrap_or("").to_string();
        for x in f {
            match x {
                "sort" => c.sort = true,
                "fixed" => c.fixed = true,
                "" => {}
                _ if x.starts_with("align=") => {
                    c.align = Some(match &x[6..] {
                        "left" => Align::Left,
                        "center" => Align::Center,
                        "right" => Align::Right,
                        _ => return Err(value(x.to_string())),
                    })
                }
                _ if c.width.is_none() => c.width = Some(parse_number(x)?),
                _ => return Err(value(format!("column option {x}"))),
            }
        }
        Ok(c)
    }
}

impl fmt::Display for Column {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}\t{}", self.id, self.label)?;
        if let Some(w) = self.width {
            write!(f, "\t{w}")?;
        }
        if self.sort {
            f.write_str("\tsort")?;
        }
        if self.fixed {
            f.write_str("\tfixed")?;
        }
        if let Some(a) = self.align {
            write!(f, "\talign={}", a.word())?;
        }
        Ok(())
    }
}

/// A table `rows` line: TSV, the first field is the row ID.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Row {
    pub id: String,
    pub cells: Vec<String>,
}

impl Row {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let mut f = line.split('\t');
        let id = need_id(f.next().unwrap(), "row")?;
        Ok(Row {
            id,
            cells: f.map(String::from).collect(),
        })
    }
}

impl fmt::Display for Row {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.id)?;
        for c in &self.cells {
            write!(f, "\t{c}")?;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// tree items

/// A `tree` `items` line: `id<TAB>parent<TAB>label[<TAB>icon=name][<TAB>disabled]`,
/// with parent `-` for a root.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TreeItem {
    pub id: String,
    pub parent: Option<String>,
    pub label: String,
    pub icon: Option<String>,
    pub disabled: bool,
}

impl TreeItem {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let mut f = line.split('\t');
        let id = need_id(f.next().unwrap(), "tree item")?;
        let parent = match f.next() {
            None | Some("") => return Err(syntax(format!("tree item {id} has no parent (use -)"))),
            Some("-") => None,
            Some(p) => Some(p.to_string()),
        };
        let mut t = TreeItem {
            id,
            parent,
            label: f.next().unwrap_or("").to_string(),
            ..Default::default()
        };
        for x in f {
            match x {
                "disabled" => t.disabled = true,
                "" => {}
                _ if x.starts_with("icon=") => t.icon = Some(x[5..].to_string()),
                _ => return Err(value(format!("tree item option {x}"))),
            }
        }
        Ok(t)
    }
}

impl fmt::Display for TreeItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}\t{}\t{}",
            self.id,
            self.parent.as_deref().unwrap_or("-"),
            self.label
        )?;
        if let Some(i) = &self.icon {
            write!(f, "\ticon={i}")?;
        }
        if self.disabled {
            f.write_str("\tdisabled")?;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// description-list and radio items

/// A `description-list` `items` line: `label<TAB>value`. The value is the
/// rest of the line and may hold further tabs.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DescItem {
    pub label: String,
    pub value: String,
}

impl DescItem {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let (l, v) = line.split_once('\t').unwrap_or((line, ""));
        Ok(DescItem {
            label: l.to_string(),
            value: v.to_string(),
        })
    }
}

impl fmt::Display for DescItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}\t{}", self.label, self.value)
    }
}

/// A `radio-group` `items` line: `id<TAB>label[<TAB>disabled]`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RadioItem {
    pub id: String,
    pub label: String,
    pub disabled: bool,
}

impl RadioItem {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let mut f = line.split('\t');
        let mut r = RadioItem {
            id: need_id(f.next().unwrap(), "radio item")?,
            ..Default::default()
        };
        r.label = f.next().unwrap_or("").to_string();
        for x in f {
            match x {
                "disabled" => r.disabled = true,
                "" => {}
                _ => return Err(value(format!("radio item option {x}"))),
            }
        }
        Ok(r)
    }
}

impl fmt::Display for RadioItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}\t{}", self.id, self.label)?;
        if self.disabled {
            f.write_str("\tdisabled")?;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// menus

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MenuKind {
    #[default]
    Item,
    Sep,
    Sub,
}

/// A menu line (DESIGN § Actions, keymaps and menus), uxkit's grammar:
///
/// ```text
/// item new    label=New      key=cmd-n
/// sep
/// sub recent  label='Open Recent'
///   item r1   label=notes.txt
/// item quit   label=Quit     key=cmd-q
/// ```
///
/// A `sub`'s items are the lines after it indented one level deeper (two
/// spaces, or one tab, per level); [`parse_menu`] checks the nesting.
/// Common props: `label`, `key`, `enabled`, `check`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MenuLine {
    pub depth: usize,
    pub kind: MenuKind,
    /// The action id (`item`) or submenu name (`sub`); empty for `sep`.
    pub id: String,
    pub props: Vec<(String, String)>,
}

impl MenuLine {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let mut depth = 0;
        let mut rest = line;
        loop {
            if let Some(r) = rest.strip_prefix("  ") {
                rest = r;
            } else if let Some(r) = rest.strip_prefix('\t') {
                rest = r;
            } else {
                break;
            }
            depth += 1;
        }
        if rest.starts_with(' ') {
            return Err(syntax("odd indent"));
        }
        let c = Command::parse(rest)?;
        let kind = match c.verb.as_str() {
            "item" => MenuKind::Item,
            "sep" => MenuKind::Sep,
            "sub" => MenuKind::Sub,
            v => return Err(Error::new(ErrorKind::UnknownCommand, v.to_string())),
        };
        let id = match (kind, c.args.as_slice()) {
            (MenuKind::Sep, []) => String::new(),
            (MenuKind::Sep, _) => return Err(syntax("sep takes nothing")),
            (_, [id]) => id.clone(),
            (_, []) => return Err(syntax(format!("{} needs an id", c.verb))),
            (_, [_, x, ..]) => return Err(syntax(format!("unexpected {x}"))),
        };
        if kind == MenuKind::Sep && !c.props.is_empty() {
            return Err(syntax("sep takes nothing"));
        }
        Ok(MenuLine {
            depth,
            kind,
            id,
            props: c.props,
        })
    }

    pub fn prop(&self, k: &str) -> Option<&str> {
        self.props
            .iter()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.as_str())
    }
}

impl fmt::Display for MenuLine {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&"  ".repeat(self.depth))?;
        match self.kind {
            MenuKind::Sep => return f.write_str("sep"),
            MenuKind::Item => write!(f, "item {}", quote_word(&self.id))?,
            MenuKind::Sub => write!(f, "sub {}", quote_word(&self.id))?,
        }
        for (k, v) in &self.props {
            write!(f, " {}={}", k, quote(v))?;
        }
        Ok(())
    }
}

/// A whole menu file, with nesting checked: a line is at most one level
/// deeper than the one before it, and only a `sub` takes deeper lines.
pub fn parse_menu(text: &str) -> Result<Vec<MenuLine>, Error> {
    let lines: Vec<MenuLine> = parse_lines(text)?;
    let mut prev: Option<&MenuLine> = None;
    for (i, l) in lines.iter().enumerate() {
        let max = match prev {
            None => 0,
            Some(p) if p.kind == MenuKind::Sub => p.depth + 1,
            Some(p) => p.depth,
        };
        if l.depth > max {
            return Err(syntax(format!(
                "menu line {}: indented under a non-sub",
                i + 1
            )));
        }
        prev = Some(l);
    }
    Ok(lines)
}

// ---------------------------------------------------------------------------
// keymap

/// A `keymap` line: `keystroke... action [context=name]`, in GPUI keystroke
/// syntax. The last positional word is the action, and the words before it
/// are the keystrokes (more than one for a sequence like `cmd-k cmd-s`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct KeyBinding {
    pub keys: Vec<String>,
    pub action: String,
    pub props: Vec<(String, String)>,
}

impl KeyBinding {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let toks = tok::tokens(line)?;
        let mut pos = Vec::new();
        let mut props = Vec::new();
        for t in toks {
            match t.into_prop() {
                Ok(p) => props.push(p),
                Err(w) => {
                    if !props.is_empty() {
                        return Err(syntax(format!("{w} after a prop")));
                    }
                    pos.push(w)
                }
            }
        }
        if pos.len() < 2 {
            return Err(syntax("want keystroke and action"));
        }
        let action = pos.pop().unwrap();
        Ok(KeyBinding {
            keys: pos,
            action,
            props,
        })
    }

    pub fn context(&self) -> Option<&str> {
        self.props
            .iter()
            .find(|(k, _)| k == "context")
            .map(|(_, v)| v.as_str())
    }

    /// The keystrokes joined by spaces, as GPUI's `KeyBinding::new` takes them.
    pub fn keystrokes(&self) -> String {
        self.keys.join(" ")
    }
}

impl fmt::Display for KeyBinding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for k in &self.keys {
            write!(f, "{} ", quote_word(k))?;
        }
        f.write_str(&quote_word(&self.action))?;
        for (k, v) in &self.props {
            write!(f, " {}={}", k, quote(v))?;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// canvas ops

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OpKind {
    /// `rect id x y w h`
    #[default]
    Rect,
    /// `circle id cx cy r`
    Circle,
    /// `line id x1 y1 x2 y2`
    Line,
    /// `path id M20,200 L60,180 ...`
    Path,
    /// `text id x y 'string'`
    Text,
    /// `image id x y w h`
    Image,
}

impl OpKind {
    pub fn from_word(w: &str) -> Option<Self> {
        Some(match w {
            "rect" => OpKind::Rect,
            "circle" => OpKind::Circle,
            "line" => OpKind::Line,
            "path" => OpKind::Path,
            "text" => OpKind::Text,
            "image" => OpKind::Image,
            _ => return None,
        })
    }

    pub fn word(self) -> &'static str {
        match self {
            OpKind::Rect => "rect",
            OpKind::Circle => "circle",
            OpKind::Line => "line",
            OpKind::Path => "path",
            OpKind::Text => "text",
            OpKind::Image => "image",
        }
    }

    /// How many numbers the geometry takes (none for `path`).
    pub fn arity(self) -> usize {
        match self {
            OpKind::Rect | OpKind::Line | OpKind::Image => 4,
            OpKind::Circle => 3,
            OpKind::Text => 2,
            OpKind::Path => 0,
        }
    }
}

/// One SVG-style path segment: `M20,200`, `L60,180`, `C1,2,3,4,5,6`, `Z`.
/// Commands `M L H V C S Q T A Z`, lowercase for relative. Several sets of
/// numbers may follow one letter (`L1,2,3,4` is two lines).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PathSeg {
    pub cmd: char,
    pub args: Vec<f32>,
}

impl PathSeg {
    pub fn parse(w: &str) -> Result<Self, Error> {
        let mut cs = w.chars();
        let cmd = cs.next().ok_or_else(|| syntax("empty path segment"))?;
        let n = match cmd.to_ascii_uppercase() {
            'M' | 'L' | 'T' => 2,
            'H' | 'V' => 1,
            'C' => 6,
            'S' | 'Q' => 4,
            'A' => 7,
            'Z' => 0,
            _ => return Err(syntax(format!("path segment {w}"))),
        };
        let rest = cs.as_str();
        let args = if rest.is_empty() {
            vec![]
        } else {
            rest.split(',')
                .map(parse_number)
                .collect::<Result<Vec<_>, _>>()?
        };
        let ok = if n == 0 {
            args.is_empty()
        } else {
            !args.is_empty() && args.len() % n == 0
        };
        if !ok {
            return Err(value(format!("path segment {w}")));
        }
        Ok(PathSeg { cmd, args })
    }
}

impl fmt::Display for PathSeg {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.cmd)?;
        for (i, a) in self.args.iter().enumerate() {
            if i > 0 {
                f.write_str(",")?;
            }
            write!(f, "{a}")?;
        }
        Ok(())
    }
}

/// A canvas `ops` line (DESIGN § Canvas): `kind id geometry attrs`.
///
/// ```text
/// rect   card    20 20 160 90  fill=muted radius=8 border=border
/// path   spark   M20,200 L60,180 L100,190  stroke=primary width=2
/// text   lbl     28 44         'Revenue'  size=13 color=muted_foreground
/// ```
///
/// Attributes are kept as written (`fill`, `stroke`, `hover:fill`, ...);
/// their values are for the canvas to check.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CanvasOp {
    pub kind: OpKind,
    pub id: String,
    /// The numbers, `kind.arity()` of them; empty for `path`.
    pub geom: Vec<f32>,
    /// The segments of a `path`.
    pub path: Vec<PathSeg>,
    /// The string of a `text`.
    pub text: Option<String>,
    pub props: Vec<(String, String)>,
}

impl CanvasOp {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let c = Command::parse(line)?;
        Self::from_parts(&c.verb, &c.args, c.props)
    }

    /// Build from an already split line, as for `add kind id ...` on a
    /// canvas `ctl` (pass the words after `add`).
    pub fn from_parts(
        kind: &str,
        args: &[String],
        props: Vec<(String, String)>,
    ) -> Result<Self, Error> {
        let kind = OpKind::from_word(kind).ok_or_else(|| value(format!("canvas op {kind}")))?;
        let (id, geo) = args
            .split_first()
            .ok_or_else(|| syntax(format!("{} needs an id", kind.word())))?;
        let mut op = CanvasOp {
            kind,
            id: id.clone(),
            props,
            ..Default::default()
        };
        if kind == OpKind::Path {
            if geo.is_empty() {
                return Err(syntax("path needs segments"));
            }
            op.path = geo
                .iter()
                .map(|w| PathSeg::parse(w))
                .collect::<Result<_, _>>()?;
            return Ok(op);
        }
        let want = kind.arity() + usize::from(kind == OpKind::Text);
        if geo.len() != want {
            return Err(syntax(format!(
                "{} {} wants {} values, got {}",
                kind.word(),
                op.id,
                want,
                geo.len()
            )));
        }
        op.geom = geo[..kind.arity()]
            .iter()
            .map(|w| parse_number(w))
            .collect::<Result<_, _>>()?;
        if kind == OpKind::Text {
            op.text = Some(geo[2].clone());
        }
        Ok(op)
    }

    pub fn prop(&self, k: &str) -> Option<&str> {
        self.props
            .iter()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.as_str())
    }
}

impl fmt::Display for CanvasOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.kind.word(), quote_word(&self.id))?;
        for g in &self.geom {
            write!(f, " {g}")?;
        }
        for p in &self.path {
            write!(f, " {p}")?;
        }
        if let Some(t) = &self.text {
            write!(f, " {}", quote_word(t))?;
        }
        for (k, v) in &self.props {
            write!(f, " {}={}", k, quote(v))?;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// editor diagnostics

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Severity {
    #[default]
    Error,
    Warning,
    Info,
    Hint,
}

impl Severity {
    pub fn word(self) -> &'static str {
        match self {
            Severity::Error => "error",
            Severity::Warning => "warning",
            Severity::Info => "info",
            Severity::Hint => "hint",
        }
    }

    pub fn from_word(w: &str) -> Option<Self> {
        Some(match w {
            "error" => Severity::Error,
            "warning" => Severity::Warning,
            "info" => Severity::Info,
            "hint" => Severity::Hint,
            _ => return None,
        })
    }
}

/// An editor `diagnostics` line: `line<TAB>col<TAB>len<TAB>severity<TAB>message`.
/// Lines and columns are 1-based as the client writes them; the message is
/// the rest of the line.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Diagnostic {
    pub line: u32,
    pub col: u32,
    pub len: u32,
    pub severity: Severity,
    pub message: String,
}

impl Diagnostic {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let f: Vec<&str> = line.splitn(5, '\t').collect();
        if f.len() < 4 {
            return Err(syntax("want line col len severity message"));
        }
        let num = |s: &str| {
            s.parse::<u32>()
                .map_err(|_| value(format!("diagnostic number {s}")))
        };
        Ok(Diagnostic {
            line: num(f[0])?,
            col: num(f[1])?,
            len: num(f[2])?,
            severity: Severity::from_word(f[3])
                .ok_or_else(|| value(format!("severity {}", f[3])))?,
            message: f.get(4).unwrap_or(&"").to_string(),
        })
    }
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}\t{}\t{}\t{}\t{}",
            self.line,
            self.col,
            self.len,
            self.severity.word(),
            self.message
        )
    }
}

// ---------------------------------------------------------------------------
// message-list items

/// The roles a message header may name.
pub const ROLES: &[&str] = &["user", "assistant", "system", "tool"];

/// One `message-list` item (DESIGN § Editing and rich content): an
/// `id role [time]` header line, then markdown, ended by a blank line.
///
/// Markdown has blank lines of its own, so a blank line ends the message
/// only when the next non-blank line is another header (two or three words,
/// the second one of [`ROLES`]) or the file ends. A body can't hold a blank
/// line followed by a line that reads as a header.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Message {
    pub id: String,
    pub role: String,
    pub time: String,
    /// Markdown, lines joined by `\n`, with no trailing blank lines.
    pub body: String,
}

fn header(line: &str) -> Option<(String, String, String)> {
    let w: Vec<&str> = line.split([' ', '\t']).filter(|w| !w.is_empty()).collect();
    if !(2..=3).contains(&w.len()) || !ROLES.contains(&w[1]) {
        return None;
    }
    Some((
        w[0].into(),
        w[1].into(),
        w.get(2).copied().unwrap_or("").into(),
    ))
}

impl Message {
    /// One record: a header line, then the body.
    pub fn parse(record: &str) -> Result<Self, Error> {
        let mut v = parse_messages(record)?;
        match v.len() {
            1 => Ok(v.pop().unwrap()),
            0 => Err(syntax("empty message")),
            _ => Err(syntax("more than one message")),
        }
    }
}

/// `id role time`, then the body on the next lines. No blank line after;
/// [`print_messages`] adds it.
impl fmt::Display for Message {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.id, self.role)?;
        if !self.time.is_empty() {
            write!(f, " {}", self.time)?;
        }
        if !self.body.is_empty() {
            write!(f, "\n{}", self.body)?;
        }
        Ok(())
    }
}

pub fn parse_messages(text: &str) -> Result<Vec<Message>, Error> {
    let lines: Vec<&str> = text
        .split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .collect();
    let blank = |l: &str| l.trim().is_empty();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        if blank(lines[i]) {
            i += 1;
            continue;
        }
        let (id, role, time) = header(lines[i]).ok_or_else(|| {
            Error::new(
                ErrorKind::BadSyntax,
                format!("line {}: want id role time, got {}", i + 1, lines[i]),
            )
        })?;
        i += 1;
        let start = i;
        let mut end = i;
        while i < lines.len() {
            if blank(lines[i]) {
                let next = lines[i..].iter().position(|l| !blank(l)).map(|p| i + p);
                match next {
                    None => {
                        i = lines.len();
                        break;
                    }
                    Some(j) if header(lines[j]).is_some() => {
                        i = j;
                        break;
                    }
                    Some(j) => i = j,
                }
            } else {
                i += 1;
                end = i;
            }
        }
        out.push(Message {
            id,
            role,
            time,
            body: lines[start..end].join("\n"),
        });
    }
    Ok(out)
}

/// Each message, then a blank line.
pub fn print_messages(msgs: &[Message]) -> String {
    let mut s = String::new();
    for m in msgs {
        s.push_str(&m.to_string());
        s.push_str("\n\n");
    }
    s
}

// ---------------------------------------------------------------------------
// completions (and the seq= header of request answers)

/// An editor `completions` line: `text[<TAB>label][<TAB>kind=k][<TAB>detail=d]`.
/// `text` is what gets inserted; `label` is what the popup shows when it
/// differs.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Completion {
    pub text: String,
    pub label: Option<String>,
    pub kind: Option<String>,
    pub detail: Option<String>,
}

impl Completion {
    pub fn parse(line: &str) -> Result<Self, Error> {
        let mut f = line.split('\t');
        let mut c = Completion {
            text: need_id(f.next().unwrap(), "completion")?,
            ..Default::default()
        };
        for (i, x) in f.enumerate() {
            if let Some(k) = x.strip_prefix("kind=") {
                c.kind = Some(k.to_string());
            } else if let Some(d) = x.strip_prefix("detail=") {
                c.detail = Some(d.to_string());
            } else if i == 0 {
                c.label = Some(x.to_string());
            } else {
                return Err(value(format!("completion field {x}")));
            }
        }
        Ok(c)
    }
}

impl fmt::Display for Completion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text)?;
        if let Some(l) = &self.label {
            write!(f, "\t{l}")?;
        }
        if let Some(k) = &self.kind {
            write!(f, "\tkind={k}")?;
        }
        if let Some(d) = &self.detail {
            write!(f, "\tdetail={d}")?;
        }
        Ok(())
    }
}

/// Split the `seq=N` first line off a request answer file (`completions`,
/// `hover`): DESIGN § Editing says the answer is "tagged with the request's
/// `seq=`". Returns the seq and the rest of the text.
pub fn split_seq(text: &str) -> Result<(u64, &str), Error> {
    let (first, rest) = text.split_once('\n').unwrap_or((text, ""));
    let first = first.trim();
    let n = first
        .strip_prefix("seq=")
        .ok_or_else(|| syntax(format!("want seq=N first, got {first}")))?;
    let seq = n.parse().map_err(|_| value(format!("seq={n}")))?;
    Ok((seq, rest))
}

/// A whole `completions` write: `seq=N`, then completion lines.
pub fn parse_completions(text: &str) -> Result<(u64, Vec<Completion>), Error> {
    let (seq, rest) = split_seq(text)?;
    Ok((seq, parse_lines_at(rest, 2)?))
}
