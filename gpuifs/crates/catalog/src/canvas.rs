//! W7: canvas (DESIGN § Canvas).
//!
//! A `canvas` is an element with a retained display list in `ops` (one
//! `proto::lines::CanvasOp` per line) and a `pixels` file of raw RGBA at the
//! canvas's size. Its `ctl` edits the list by item id: `set`, `add`, `del`,
//! `raise`, `lower`. [`edit_ops`] is that edit as a pure function, so the
//! tree applies it the same way headless and in the GPUI host.
//!
//! Pointer events come from the `on` file as for any element; a canvas adds
//! `item=` (the topmost item under the pointer) and canvas-local `x=`/`y=`.
//! `drag` on a canvas is pointer motion with a button held, coalesced like
//! `move`.
use crate::*;

use proto::lines::{CanvasOp, OpKind, PathSeg};
use proto::{Command, Error, ErrorKind};

const fn p(name: &'static str, kind: PropKind) -> PropSpec {
    PropSpec {
        name,
        kind,
        default: None,
    }
}

const fn ev(name: &'static str, kind: EventKind) -> EventSpec {
    EventSpec { name, kind }
}

pub static CANVAS: TypeSpec = TypeSpec {
    name: "canvas",
    tier: Tier::Element,
    props: &[
        p("ops", PropKind::Data(LineFormat::CanvasOps)),
        p("pixels", PropKind::Bytes),
    ],
    verbs: &[
        VerbSpec {
            name: "set",
            usage: "set id geometry... [attr=value ...]",
        },
        VerbSpec {
            name: "add",
            usage: "add kind id geometry... [attr=value ...]",
        },
        VerbSpec {
            name: "del",
            usage: "del id...",
        },
        VerbSpec {
            name: "raise",
            usage: "raise id",
        },
        VerbSpec {
            name: "lower",
            usage: "lower id",
        },
    ],
    events: &[
        ev("mouse_down", EventKind::Action),
        ev("mouse_up", EventKind::Action),
        ev("click", EventKind::Action),
        ev("move", EventKind::State),
        ev("drag", EventKind::State),
    ],
    slots: Slots::None,
    variants: &[],
    sizable: false,
};

pub static SPECS: &[TypeSpec] = &[CANVAS];

/// Whether `verb` is one of the canvas `ctl` verbs that edit `ops`.
pub fn is_edit_verb(verb: &str) -> bool {
    matches!(verb, "set" | "add" | "del" | "raise" | "lower")
}

fn not_found(id: &str) -> Error {
    Error::new(ErrorKind::NotFound, format!("item {id}"))
}

/// One line of `ops`, kept as written until an edit touches it.
struct Line {
    id: String,
    text: String,
}

fn lines_of(ops: &str) -> Result<Vec<Line>, Error> {
    let mut out = Vec::new();
    for (i, l) in ops.split('\n').enumerate() {
        let l = l.strip_suffix('\r').unwrap_or(l);
        if l.trim().is_empty() {
            continue;
        }
        let op = CanvasOp::parse(l).map_err(|e| e.at_line(i + 1))?;
        out.push(Line {
            id: op.id,
            text: l.to_string(),
        });
    }
    Ok(out)
}

fn print(lines: &[Line]) -> Vec<u8> {
    let mut s = String::new();
    for l in lines {
        s.push_str(&l.text);
        s.push('\n');
    }
    s.into_bytes()
}

/// Applies one canvas `ctl` verb to an `ops` list and returns the new list.
///
/// - `set id geometry... [attr=value ...]` replaces the item's leading
///   geometry numbers (a `path` takes new segments, a `text` may take a new
///   string after its two numbers) and sets the attributes given.
/// - `add kind id geometry... [attrs]` appends a new item (`in use` if the
///   id exists).
/// - `del id...` removes items.
/// - `raise id` / `lower id` move an item to the top (drawn last) or the
///   bottom (drawn first) of the list.
///
/// Unknown ids are `not found`. Untouched lines keep their bytes.
pub fn edit_ops(ops: &[u8], c: &Command) -> Result<Vec<u8>, Error> {
    let src =
        std::str::from_utf8(ops).map_err(|_| Error::new(ErrorKind::BadValue, "ops: not utf-8"))?;
    let mut lines = lines_of(src)?;
    let find = |lines: &[Line], id: &str| lines.iter().position(|l| l.id == id);
    match c.verb.as_str() {
        "add" => {
            let Some((kind, rest)) = c.args.split_first() else {
                return Err(Error::new(ErrorKind::BadSyntax, "add kind id geometry..."));
            };
            let op = CanvasOp::from_parts(kind, rest, c.props.clone())?;
            if find(&lines, &op.id).is_some() {
                return Err(Error::new(ErrorKind::InUse, format!("item {}", op.id)));
            }
            lines.push(Line {
                id: op.id.clone(),
                text: op.to_string(),
            });
        }
        "set" => {
            let Some((id, geo)) = c.args.split_first() else {
                return Err(Error::new(ErrorKind::BadSyntax, "set id geometry..."));
            };
            let i = find(&lines, id).ok_or_else(|| not_found(id))?;
            let mut op = CanvasOp::parse(&lines[i].text)?;
            set_geometry(&mut op, geo)?;
            for (k, v) in &c.props {
                match op.props.iter_mut().find(|(n, _)| n == k) {
                    Some(slot) => slot.1 = v.clone(),
                    None => op.props.push((k.clone(), v.clone())),
                }
            }
            lines[i].text = op.to_string();
        }
        "del" => {
            if c.args.is_empty() {
                return Err(Error::new(ErrorKind::BadSyntax, "del id..."));
            }
            for id in &c.args {
                let i = find(&lines, id).ok_or_else(|| not_found(id))?;
                lines.remove(i);
            }
        }
        "raise" | "lower" => {
            let [id] = &c.args[..] else {
                return Err(Error::new(ErrorKind::BadSyntax, format!("{} id", c.verb)));
            };
            let i = find(&lines, id).ok_or_else(|| not_found(id))?;
            let l = lines.remove(i);
            if c.verb == "raise" {
                lines.push(l);
            } else {
                lines.insert(0, l);
            }
        }
        v => return Err(Error::new(ErrorKind::UnknownCommand, v.to_string())),
    }
    Ok(print(&lines))
}

fn set_geometry(op: &mut CanvasOp, geo: &[String]) -> Result<(), Error> {
    if geo.is_empty() {
        return Ok(());
    }
    if op.kind == OpKind::Path {
        op.path = geo
            .iter()
            .map(|w| PathSeg::parse(w))
            .collect::<Result<_, _>>()?;
        return Ok(());
    }
    let arity = op.kind.arity();
    let (nums, rest) = geo.split_at(geo.len().min(arity));
    match (op.kind, rest) {
        (_, []) => {}
        (OpKind::Text, [s]) if nums.len() == arity => op.text = Some(s.clone()),
        _ => {
            return Err(Error::new(
                ErrorKind::BadSyntax,
                format!(
                    "{} {} takes at most {} values",
                    op.kind.word(),
                    op.id,
                    arity
                ),
            ));
        }
    }
    for (i, w) in nums.iter().enumerate() {
        op.geom[i] = w
            .parse::<f32>()
            .ok()
            .filter(|f| f.is_finite())
            .ok_or_else(|| Error::new(ErrorKind::BadValue, w.clone()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const OPS: &str = "rect   bg      0 0 400 300   fill=background
rect   card    20 20 160 90  fill=muted radius=8 border=border
path   spark   M20,200 L60,180 L100,190 L140,150  stroke=primary width=2
circle dot     140 150 4     fill=primary
text   lbl     28 44         'Revenue'  size=13 color=muted_foreground
image  logo    360 12 24 24  src=@logo
";

    fn ed(ops: &str, line: &str) -> Result<String, Error> {
        let c = Command::parse(line).unwrap();
        edit_ops(ops.as_bytes(), &c).map(|b| String::from_utf8(b).unwrap())
    }

    fn ids(ops: &str) -> Vec<String> {
        ops.lines()
            .map(|l| l.split_whitespace().nth(1).unwrap().to_string())
            .collect()
    }

    #[test]
    fn spec_is_in_the_catalog() {
        let s = crate::get("canvas").unwrap();
        assert_eq!(s.tier, Tier::Element);
        assert!(s.props.iter().any(|p| p.name == "ops"));
        for v in ["set", "add", "del", "raise", "lower"] {
            assert!(s.verbs.iter().any(|x| x.name == v), "{v}");
            assert!(is_edit_verb(v));
        }
    }

    #[test]
    fn designs_sequence() {
        let o = ed(OPS, "set dot 150 140").unwrap();
        assert!(o.contains("circle dot 150 140 4 fill=primary"), "{o}");
        // untouched lines keep their bytes
        assert!(o.starts_with("rect   bg      0 0 400 300   fill=background\n"));
        let o = ed(&o, "add circle dot2 10 10 3 fill=accent").unwrap();
        let o = ed(&o, "del card").unwrap();
        let o = ed(&o, "raise bg").unwrap();
        let o = ed(&o, "lower dot2").unwrap();
        assert_eq!(ids(&o), ["dot2", "spark", "dot", "lbl", "logo", "bg"]);
    }

    #[test]
    fn errors() {
        assert_eq!(
            ed(OPS, "set nope 1 1").unwrap_err().kind,
            ErrorKind::NotFound
        );
        assert_eq!(
            ed(OPS, "add rect dot 0 0 1 1").unwrap_err().kind,
            ErrorKind::InUse
        );
        assert_eq!(ed(OPS, "del nope").unwrap_err().kind, ErrorKind::NotFound);
        assert_eq!(ed(OPS, "raise").unwrap_err().kind, ErrorKind::BadSyntax);
        assert_eq!(
            ed(OPS, "add blob x 1 2").unwrap_err().kind,
            ErrorKind::BadValue
        );
        assert_eq!(ed(OPS, "set dot a").unwrap_err().kind, ErrorKind::BadValue);
        assert_eq!(
            ed(OPS, "set dot 1 2 3 4").unwrap_err().kind,
            ErrorKind::BadSyntax
        );
    }

    #[test]
    fn set_paths_text_and_attrs() {
        let o = ed(OPS, "set spark M0,0 L10,10").unwrap();
        assert!(
            o.contains("path spark M0,0 L10,10 stroke=primary width=2"),
            "{o}"
        );
        let o = ed(OPS, "set lbl 1 2 Profit").unwrap();
        assert!(o.contains("text lbl 1 2 Profit size=13"), "{o}");
        let o = ed(OPS, "set dot fill=danger hover:fill=accent").unwrap();
        assert!(
            o.contains("circle dot 140 150 4 fill=danger hover:fill=accent"),
            "{o}"
        );
    }

    #[test]
    fn add_to_empty_and_from_empty_ops() {
        let o = ed("", "add rect a 0 0 1 1").unwrap();
        assert_eq!(o, "rect a 0 0 1 1\n");
        let o = ed(&o, "del a").unwrap();
        assert_eq!(o, "");
    }
}
