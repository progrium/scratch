//! W7: the `canvas` node (DESIGN § Canvas).
//!
//! - `ops` is a retained display list, painted by GPUI every frame. Each
//!   item is `kind id geometry attrs` (`proto::lines::CanvasOp`); the tree
//!   applies `ctl` edits to it (`catalog::canvas::edit_ops`), so the host
//!   only ever paints the file.
//! - Colors are theme tokens or literals, resolved at paint time, so a
//!   drawing follows the theme. `hover:<attr>=` overrides an attribute while
//!   the pointer is over that item, with no round trip.
//! - `pixels` is raw RGBA at the canvas's size (its width from the last
//!   layout), drawn under the items.
//! - Pointer events follow `on`: `mouse_down`, `mouse_up` and `click` are
//!   actions, `move` and `drag` (motion with a button held) are coalesced.
//!   Each names the topmost item under the pointer (`item=`) and carries
//!   canvas-local `x=`/`y=`.
//!
//! Item attributes: `fill`, `stroke`, `width` (stroke width, default 1),
//! `border` (color) and `border_width` (default 1), `radius` (rect corners),
//! `cap=round` (round stroke ends and joins), `size` and `color` (text),
//! `weight` (text: `bold`, `semibold`, `medium` or a number), `src` (image:
//! `@asset`, a host path or an https URL) and `opacity` (0..1).
//! Text is placed by its top-left corner. Images are drawn by GPUI's `img`
//! in their place in the list, so they stack with the other items.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gpui::{
    AnyElement, App, AppContext as _, BorderStyle, Bounds, Corners, DispatchPhase, Edges, Entity,
    Font, FontWeight, Hitbox, HitboxBehavior, Hsla, Image, ImageFormat, ImageSource, IntoElement,
    MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, ParentElement, PathBuilder, Pixels,
    Point, SharedString, Styled, TextAlign, TextRun, Window, canvas, div, img, point, px, quad,
    size,
};
use proto::lines::{CanvasOp, OpKind};

use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(Canvas);
}

/// The pointer words a canvas sends itself, with `item=` and local coordinates.
const POINTER: &[&str] = &["mouse_down", "mouse_up", "click", "move", "drag"];

struct Canvas;

/// Per-node state: the parsed list (reused while `ops` is unchanged), the
/// hovered item and the pressed button.
pub(crate) struct CanvasState {
    parsed: Option<(tree::Bytes, Rc<Vec<CanvasOp>>)>,
    hovered: Option<String>,
    pressed: Option<MouseButton>,
    /// Width and height from the last layout, for `pixels`.
    size: (f32, f32),
}

impl CanvasState {
    fn items(&mut self, ops: tree::Bytes) -> Rc<Vec<CanvasOp>> {
        if let Some((b, v)) = &self.parsed
            && *b == ops
        {
            return v.clone();
        }
        let text = String::from_utf8_lossy(&ops);
        let v: Vec<CanvasOp> = text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| CanvasOp::parse(l).ok())
            .collect();
        let v = Rc::new(v);
        self.parsed = Some((ops, v.clone()));
        v
    }
}

impl Component for Canvas {
    fn spec(&self) -> &'static catalog::TypeSpec {
        &catalog::canvas::CANVAS
    }

    fn create(&self, _: &NodeView, _: &mut Window, cx: &mut App) -> Option<gpui::AnyEntity> {
        let e: Entity<CanvasState> = cx.new(|_| CanvasState {
            parsed: None,
            hovered: None,
            pressed: None,
            size: (0., 0.),
        });
        Some(e.into())
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&gpui::AnyEntity>,
        cmd: &proto::Command,
        _: &mut Window,
        _: &mut App,
    ) -> Result<(), proto::Error> {
        // `set add del raise lower` are applied to `ops` by the tree; the
        // next frame paints the result.
        if catalog::canvas::is_edit_verb(&cmd.verb) {
            Ok(())
        } else {
            Err(proto::Error::new(
                proto::ErrorKind::UnknownCommand,
                cmd.verb.clone(),
            ))
        }
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(state) = rcx.state::<CanvasState>(node) else {
            return rcx.element(node).into_any_element();
        };
        let ops = node.prop("ops").unwrap_or_default();
        let (items, hovered, csize) =
            state.update(rcx.cx(), |s, _| (s.items(ops), s.hovered.clone(), s.size));

        // Resolve every item's attributes now: theme tokens, hover:.
        let resolved: Vec<Paint> = {
            let toks = crate::theme::TokenView(rcx.cx_ref());
            items
                .iter()
                .map(|op| Paint::new(op, hovered.as_deref() == Some(op.id.as_str()), &toks))
                .collect()
        };

        let mut layers: Vec<AnyElement> = Vec::new();
        if let Some(px_data) = node.prop("pixels").filter(|d| !d.is_empty())
            && let Some((bmp, w, h)) = bmp_from_rgba(&px_data, csize.0)
        {
            let src: ImageSource = Arc::new(Image::from_bytes(ImageFormat::Bmp, bmp)).into();
            layers.push(
                img(src)
                    .absolute()
                    .left_0()
                    .top_0()
                    .w(px(w as f32))
                    .h(px(h as f32))
                    .into_any_element(),
            );
        }
        // Runs of vector items paint on one GPUI canvas each; an image
        // between them is its own element, so the stacking order holds.
        let mut run: Vec<Paint> = Vec::new();
        let flush = |run: &mut Vec<Paint>, layers: &mut Vec<AnyElement>| {
            if run.is_empty() {
                return;
            }
            let r = std::mem::take(run);
            layers.push(
                canvas(
                    |_, _, _| (),
                    move |b, _, window, cx| paint_all(&r, b, window, cx),
                )
                .absolute()
                .top_0()
                .left_0()
                .size_full()
                .into_any_element(),
            );
        };
        for p in resolved {
            if p.op.kind == OpKind::Image {
                flush(&mut run, &mut layers);
                if let Some(el) = image_layer(node, &p) {
                    layers.push(el);
                }
            } else {
                run.push(p);
            }
        }
        flush(&mut run, &mut layers);

        // The top layer takes pointer input and does the hit testing.
        let on = node.on_words();
        let wants: Rc<Vec<String>> = Rc::new(
            on.into_iter()
                .filter(|w| POINTER.contains(&w.as_str()))
                .collect(),
        );
        let track_hover = items
            .iter()
            .any(|o| o.props.iter().any(|(k, _)| k.starts_with("hover:")));
        let input = input_layer(node.emitter(), state, items, wants, track_hover);
        layers.push(input);

        rcx.element_except(node, div().relative().overflow_hidden(), POINTER)
            .children(layers)
            .into_any_element()
    }
}

// ---- painting --------------------------------------------------------------

/// One item with its attributes resolved.
struct Paint {
    op: CanvasOp,
    fill: Option<Hsla>,
    stroke: Option<Hsla>,
    border: Option<Hsla>,
    color: Option<Hsla>,
    width: f32,
    border_width: f32,
    radius: f32,
    size: f32,
    round: bool,
    weight: Option<FontWeight>,
    src: Option<String>,
}

impl Paint {
    fn new(op: &CanvasOp, hovered: bool, toks: &dyn crate::styling::Tokens) -> Paint {
        let get = |k: &str| -> Option<String> {
            if hovered && let Some(v) = op.prop(&format!("hover:{k}")) {
                return Some(v.to_string());
            }
            op.prop(k).map(str::to_string)
        };
        let opacity = get("opacity")
            .and_then(|v| v.parse::<f32>().ok())
            .unwrap_or(1.)
            .clamp(0., 1.);
        let color = |k: &str| {
            get(k)
                .and_then(|v| crate::styling::parse_color(&v, toks))
                .map(|c| c.opacity(c.a * opacity))
        };
        let numf = |k: &str| {
            get(k)
                .and_then(|v| v.parse::<f32>().ok())
                .filter(|f| f.is_finite())
        };
        let fg = || {
            toks.color("foreground")
                .unwrap_or(gpui::black())
                .opacity(opacity)
        };
        let mut stroke = color("stroke");
        let fill = color("fill");
        if matches!(op.kind, OpKind::Line | OpKind::Path) && stroke.is_none() && fill.is_none() {
            stroke = Some(fg());
        }
        let weight = get("weight").and_then(|w| match w.as_str() {
            "bold" => Some(FontWeight::BOLD),
            "semibold" => Some(FontWeight::SEMIBOLD),
            "medium" => Some(FontWeight::MEDIUM),
            "normal" => Some(FontWeight::NORMAL),
            n => n.parse().ok().map(FontWeight),
        });
        Paint {
            op: op.clone(),
            fill,
            stroke,
            border: color("border"),
            color: color("color").or_else(|| (op.kind == OpKind::Text).then(fg)),
            width: numf("width").unwrap_or(1.).max(0.),
            border_width: numf("border_width").unwrap_or(1.).max(0.),
            radius: numf("radius").unwrap_or(0.).max(0.),
            size: numf("size").unwrap_or(14.).max(1.),
            round: get("cap").as_deref() == Some("round"),
            weight,
            src: get("src"),
        }
    }
}

fn paint_all(items: &[Paint], b: Bounds<Pixels>, window: &mut Window, cx: &mut App) {
    let o = b.origin;
    window.with_content_mask(Some(gpui::ContentMask { bounds: b }), |window| {
        for p in items {
            paint_one(p, o, window, cx);
        }
    });
}

fn at(o: Point<Pixels>, x: f32, y: f32) -> Point<Pixels> {
    point(o.x + px(x), o.y + px(y))
}

fn dot(window: &mut Window, c: Point<Pixels>, r: f32, color: Hsla) {
    let b = Bounds::new(
        point(c.x - px(r), c.y - px(r)),
        size(px(2. * r), px(2. * r)),
    );
    window.paint_quad(quad(
        b,
        px(r),
        color,
        px(0.),
        gpui::transparent_black(),
        BorderStyle::Solid,
    ));
}

fn paint_one(p: &Paint, o: Point<Pixels>, window: &mut Window, cx: &mut App) {
    let g = &p.op.geom;
    let box_quad = |window: &mut Window, b: Bounds<Pixels>, radius: f32| {
        let has_border = p.border.is_some();
        window.paint_quad(quad(
            b,
            Corners::all(px(radius)),
            p.fill.unwrap_or(gpui::transparent_black()),
            Edges::all(px(if has_border { p.border_width } else { 0. })),
            p.border.unwrap_or(gpui::transparent_black()),
            BorderStyle::Solid,
        ));
    };
    match p.op.kind {
        OpKind::Rect => {
            let b = Bounds::new(at(o, g[0], g[1]), size(px(g[2].max(0.)), px(g[3].max(0.))));
            box_quad(window, b, p.radius);
        }
        OpKind::Circle => {
            let r = g[2].max(0.);
            let b = Bounds::new(at(o, g[0] - r, g[1] - r), size(px(2. * r), px(2. * r)));
            box_quad(window, b, r);
        }
        OpKind::Line => {
            let pts = [(g[0], g[1]), (g[2], g[3])];
            let segs = vec![Seg::Move(pts[0]), Seg::Line(pts[1])];
            stroke_segs(&segs, p, o, window);
        }
        OpKind::Path => {
            let segs = absolute(&p.op);
            if let Some(f) = p.fill {
                let mut pb = PathBuilder::fill();
                build(&mut pb, &segs, o);
                if let Ok(path) = pb.build() {
                    window.paint_path(path, f);
                }
            }
            if p.stroke.is_some() {
                stroke_segs(&segs, p, o, window);
            }
        }
        OpKind::Text => {
            let text: SharedString =
                p.op.text
                    .clone()
                    .unwrap_or_default()
                    .replace('\n', " ")
                    .into();
            if text.is_empty() {
                return;
            }
            let mut font: Font = window.text_style().font();
            if let Some(w) = p.weight {
                font.weight = w;
            }
            let run = TextRun {
                len: text.len(),
                font,
                color: p.color.unwrap_or(gpui::black()),
                background_color: None,
                underline: None,
                strikethrough: None,
            };
            let fs = px(p.size);
            let line = window.text_system().shape_line(text, fs, &[run], None);
            let lh = px(p.size * 1.25);
            let _ = line.paint(at(o, g[0], g[1]), lh, TextAlign::Left, None, window, cx);
        }
        OpKind::Image => {}
    }
}

fn stroke_segs(segs: &[Seg], p: &Paint, o: Point<Pixels>, window: &mut Window) {
    let Some(color) = p.stroke else {
        return;
    };
    let mut pb = PathBuilder::stroke(px(p.width));
    build(&mut pb, segs, o);
    if let Ok(path) = pb.build() {
        window.paint_path(path, color);
    }
    if p.round && p.width > 1. {
        for pt in vertices(segs) {
            dot(window, at(o, pt.0, pt.1), p.width / 2., color);
        }
    }
}

fn image_layer(node: &NodeView, p: &Paint) -> Option<AnyElement> {
    let g = &p.op.geom;
    let src = p.src.clone()?;
    let source: ImageSource = if let Some(name) = src.strip_prefix('@') {
        let b = node.host_root_file(&format!("assets/{name}"))?.to_vec();
        Arc::new(Image::from_bytes(image_format(&b), b)).into()
    } else {
        src.into()
    };
    Some(
        img(source)
            .absolute()
            .left(px(g[0]))
            .top(px(g[1]))
            .w(px(g[2].max(0.)))
            .h(px(g[3].max(0.)))
            .into_any_element(),
    )
}

fn image_format(b: &[u8]) -> ImageFormat {
    if b.starts_with(&[0xff, 0xd8]) {
        ImageFormat::Jpeg
    } else if b.starts_with(b"GIF8") {
        ImageFormat::Gif
    } else if b.starts_with(b"BM") {
        ImageFormat::Bmp
    } else if b.starts_with(b"<svg") || b.starts_with(b"<?xml") {
        ImageFormat::Svg
    } else if b.len() > 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        ImageFormat::Webp
    } else {
        ImageFormat::Png
    }
}

/// Raw RGBA rows at `width` (px) as a 32-bit top-down BMP with alpha.
/// Returns `(bmp, width, height)`; `None` if the bytes don't fill whole rows.
pub(crate) fn bmp_from_rgba(rgba: &[u8], width: f32) -> Option<(Vec<u8>, u32, u32)> {
    let w = width.round() as u32;
    if w == 0 || !rgba.len().is_multiple_of(4 * w as usize) {
        return None;
    }
    let h = (rgba.len() / (4 * w as usize)) as u32;
    let header = 14 + 108; // BITMAPFILEHEADER + BITMAPV4HEADER
    let mut out = Vec::with_capacity(header + rgba.len());
    let le32 = |o: &mut Vec<u8>, v: u32| o.extend_from_slice(&v.to_le_bytes());
    out.extend_from_slice(b"BM");
    le32(&mut out, (header + rgba.len()) as u32);
    le32(&mut out, 0);
    le32(&mut out, header as u32);
    le32(&mut out, 108);
    le32(&mut out, w);
    le32(&mut out, (-(h as i32)) as u32); // top-down
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    le32(&mut out, 3); // BI_BITFIELDS
    le32(&mut out, rgba.len() as u32);
    le32(&mut out, 2835);
    le32(&mut out, 2835);
    le32(&mut out, 0);
    le32(&mut out, 0);
    // R G B A masks for little-endian RGBA bytes.
    le32(&mut out, 0x0000_00ff);
    le32(&mut out, 0x0000_ff00);
    le32(&mut out, 0x00ff_0000);
    le32(&mut out, 0xff00_0000);
    out.extend_from_slice(b"BGRs"); // LCS_WINDOWS_COLOR_SPACE, little-endian 'sRGB'
    out.extend_from_slice(&[0u8; 36 + 12]); // endpoints, gamma
    out.extend_from_slice(rgba);
    Some((out, w, h))
}

// ---- geometry ----------------------------------------------------------------

/// A path segment in absolute canvas coordinates.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Seg {
    Move((f32, f32)),
    Line((f32, f32)),
    Quad((f32, f32), (f32, f32)),
    Cubic((f32, f32), (f32, f32), (f32, f32)),
    Arc {
        r: (f32, f32),
        rot: f32,
        large: bool,
        sweep: bool,
        to: (f32, f32),
    },
    Close,
}

/// A `path` item's SVG-style segments, made absolute (`m l h v c s q t a z`
/// relative forms included; `S` and `T` reflect the last control point).
pub(crate) fn absolute(op: &CanvasOp) -> Vec<Seg> {
    let mut out = Vec::new();
    let mut cur = (0f32, 0f32);
    let mut start = cur;
    let mut last_c2: Option<(f32, f32)> = None; // cubic
    let mut last_q: Option<(f32, f32)> = None; // quadratic
    for s in &op.path {
        let rel = s.cmd.is_ascii_lowercase();
        let up = s.cmd.to_ascii_uppercase();
        let base =
            |cur: (f32, f32), x: f32, y: f32| if rel { (cur.0 + x, cur.1 + y) } else { (x, y) };
        let n = match up {
            'M' | 'L' | 'T' => 2,
            'H' | 'V' => 1,
            'C' => 6,
            'S' | 'Q' => 4,
            'A' => 7,
            _ => 0,
        };
        if up == 'Z' {
            out.push(Seg::Close);
            cur = start;
            last_c2 = None;
            last_q = None;
            continue;
        }
        for (i, a) in s.args.chunks(n).enumerate() {
            if a.len() < n {
                break;
            }
            let (mut c2, mut q) = (None, None);
            match up {
                'M' => {
                    let p = base(cur, a[0], a[1]);
                    // Extra pairs after a moveto are linetos.
                    out.push(if i == 0 { Seg::Move(p) } else { Seg::Line(p) });
                    if i == 0 {
                        start = p;
                    }
                    cur = p;
                }
                'L' => {
                    cur = base(cur, a[0], a[1]);
                    out.push(Seg::Line(cur));
                }
                'H' => {
                    cur = (if rel { cur.0 + a[0] } else { a[0] }, cur.1);
                    out.push(Seg::Line(cur));
                }
                'V' => {
                    cur = (cur.0, if rel { cur.1 + a[0] } else { a[0] });
                    out.push(Seg::Line(cur));
                }
                'C' => {
                    let c1 = base(cur, a[0], a[1]);
                    let cc = base(cur, a[2], a[3]);
                    let p = base(cur, a[4], a[5]);
                    out.push(Seg::Cubic(c1, cc, p));
                    c2 = Some(cc);
                    cur = p;
                }
                'S' => {
                    let c1 = last_c2
                        .map(|c| (2. * cur.0 - c.0, 2. * cur.1 - c.1))
                        .unwrap_or(cur);
                    let cc = base(cur, a[0], a[1]);
                    let p = base(cur, a[2], a[3]);
                    out.push(Seg::Cubic(c1, cc, p));
                    c2 = Some(cc);
                    cur = p;
                }
                'Q' => {
                    let c = base(cur, a[0], a[1]);
                    let p = base(cur, a[2], a[3]);
                    out.push(Seg::Quad(c, p));
                    q = Some(c);
                    cur = p;
                }
                'T' => {
                    let c = last_q
                        .map(|c| (2. * cur.0 - c.0, 2. * cur.1 - c.1))
                        .unwrap_or(cur);
                    let p = base(cur, a[0], a[1]);
                    out.push(Seg::Quad(c, p));
                    q = Some(c);
                    cur = p;
                }
                'A' => {
                    let p = base(cur, a[5], a[6]);
                    out.push(Seg::Arc {
                        r: (a[0].abs(), a[1].abs()),
                        rot: a[2],
                        large: a[3] != 0.,
                        sweep: a[4] != 0.,
                        to: p,
                    });
                    cur = p;
                }
                _ => {}
            }
            last_c2 = c2;
            last_q = q;
        }
    }
    out
}

fn build(pb: &mut PathBuilder, segs: &[Seg], o: Point<Pixels>) {
    let mut open = false;
    for s in segs {
        match *s {
            Seg::Move(p) => {
                pb.move_to(at(o, p.0, p.1));
                open = true;
            }
            _ if !open => {
                pb.move_to(o);
                open = true;
                build(pb, std::slice::from_ref(s), o);
            }
            Seg::Line(p) => pb.line_to(at(o, p.0, p.1)),
            Seg::Quad(c, p) => pb.curve_to(at(o, p.0, p.1), at(o, c.0, c.1)),
            Seg::Cubic(c1, c2, p) => {
                pb.cubic_bezier_to(at(o, p.0, p.1), at(o, c1.0, c1.1), at(o, c2.0, c2.1))
            }
            Seg::Arc {
                r,
                rot,
                large,
                sweep,
                to,
            } => pb.arc_to(
                point(px(r.0), px(r.1)),
                px(rot),
                large,
                sweep,
                at(o, to.0, to.1),
            ),
            Seg::Close => {
                pb.close();
                open = false;
            }
        }
    }
}

/// The points a path passes through, for round joins and hit testing.
fn vertices(segs: &[Seg]) -> Vec<(f32, f32)> {
    polylines(segs).into_iter().flatten().collect()
}

/// Each subpath flattened to points (curves sampled, arcs as chords).
fn polylines(segs: &[Seg]) -> Vec<Vec<(f32, f32)>> {
    let mut out: Vec<Vec<(f32, f32)>> = Vec::new();
    let mut cur: Vec<(f32, f32)> = Vec::new();
    let mut start = (0., 0.);
    let last = |v: &Vec<(f32, f32)>| v.last().copied().unwrap_or((0., 0.));
    for s in segs {
        match *s {
            Seg::Move(p) => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
                cur.push(p);
                start = p;
            }
            Seg::Line(p) | Seg::Arc { to: p, .. } => {
                if cur.is_empty() {
                    cur.push((0., 0.));
                }
                cur.push(p)
            }
            Seg::Quad(c, p) => {
                let a = last(&cur);
                for i in 1..=8 {
                    let t = i as f32 / 8.;
                    let u = 1. - t;
                    cur.push((
                        u * u * a.0 + 2. * u * t * c.0 + t * t * p.0,
                        u * u * a.1 + 2. * u * t * c.1 + t * t * p.1,
                    ));
                }
            }
            Seg::Cubic(c1, c2, p) => {
                let a = last(&cur);
                for i in 1..=12 {
                    let t = i as f32 / 12.;
                    let u = 1. - t;
                    cur.push((
                        u * u * u * a.0
                            + 3. * u * u * t * c1.0
                            + 3. * u * t * t * c2.0
                            + t * t * t * p.0,
                        u * u * u * a.1
                            + 3. * u * u * t * c1.1
                            + 3. * u * t * t * c2.1
                            + t * t * t * p.1,
                    ));
                }
            }
            Seg::Close => {
                cur.push(start);
                out.push(std::mem::take(&mut cur));
            }
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn seg_dist(p: (f32, f32), a: (f32, f32), b: (f32, f32)) -> f32 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let l2 = dx * dx + dy * dy;
    let t = if l2 == 0. {
        0.
    } else {
        (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / l2).clamp(0., 1.)
    };
    let (x, y) = (a.0 + t * dx, a.1 + t * dy);
    ((p.0 - x).powi(2) + (p.1 - y).powi(2)).sqrt()
}

fn inside_poly(p: (f32, f32), poly: &[(f32, f32)]) -> bool {
    let mut inside = false;
    let n = poly.len();
    if n < 3 {
        return false;
    }
    let mut j = n - 1;
    for i in 0..n {
        let (a, b) = (poly[i], poly[j]);
        if (a.1 > p.1) != (b.1 > p.1) && p.0 < (b.0 - a.0) * (p.1 - a.1) / (b.1 - a.1) + a.0 {
            inside = !inside;
        }
        j = i;
    }
    inside
}

/// Whether canvas-local point `p` is on the item.
pub(crate) fn hits(op: &CanvasOp, p: (f32, f32)) -> bool {
    let g = &op.geom;
    let width = op
        .prop("width")
        .and_then(|w| w.parse::<f32>().ok())
        .unwrap_or(1.);
    let slack = width / 2. + 2.;
    match op.kind {
        OpKind::Rect | OpKind::Image => {
            p.0 >= g[0] && p.0 <= g[0] + g[2] && p.1 >= g[1] && p.1 <= g[1] + g[3]
        }
        OpKind::Circle => ((p.0 - g[0]).powi(2) + (p.1 - g[1]).powi(2)).sqrt() <= g[2],
        OpKind::Line => seg_dist(p, (g[0], g[1]), (g[2], g[3])) <= slack,
        OpKind::Path => {
            let lines = polylines(&absolute(op));
            let filled = op.prop("fill").is_some();
            lines.iter().any(|l| {
                l.windows(2).any(|w| seg_dist(p, w[0], w[1]) <= slack)
                    || (l.len() == 1 && seg_dist(p, l[0], l[0]) <= slack)
                    || (filled && inside_poly(p, l))
            })
        }
        OpKind::Text => {
            let size = op
                .prop("size")
                .and_then(|s| s.parse::<f32>().ok())
                .unwrap_or(14.);
            let n = op.text.as_deref().map(|t| t.chars().count()).unwrap_or(0) as f32;
            let (w, h) = (n * size * 0.6, size * 1.25);
            p.0 >= g[0] && p.0 <= g[0] + w && p.1 >= g[1] && p.1 <= g[1] + h
        }
    }
}

/// The topmost item under canvas-local `p`.
pub(crate) fn hit(items: &[CanvasOp], p: (f32, f32)) -> Option<&CanvasOp> {
    items.iter().rev().find(|op| hits(op, p))
}

// ---- input -------------------------------------------------------------------

fn num(v: f32) -> String {
    if v.fract() == 0.0 {
        format!("{}", v as i64)
    } else {
        format!("{v:.1}")
    }
}

fn button_word(b: MouseButton) -> &'static str {
    match b {
        MouseButton::Left => "left",
        MouseButton::Right => "right",
        MouseButton::Middle => "middle",
        _ => "other",
    }
}

fn input_layer(
    em: crate::Emitter,
    state: Entity<CanvasState>,
    items: Rc<Vec<CanvasOp>>,
    wants: Rc<Vec<String>>,
    track_hover: bool,
) -> AnyElement {
    canvas(
        |b, window, _| window.insert_hitbox(b, HitboxBehavior::Normal),
        move |b: Bounds<Pixels>, hitbox: Hitbox, window: &mut Window, cx: &mut App| {
            let size = (f32::from(b.size.width), f32::from(b.size.height));
            let resized = state.update(cx, |s, _| std::mem::replace(&mut s.size, size) != size);
            if resized {
                // `pixels` is laid out at the canvas's width.
                window.refresh();
            }
            let want = {
                let w = wants.clone();
                move |x: &str| w.iter().any(|v| v == x)
            };
            let local =
                move |p: Point<Pixels>| (f32::from(p.x - b.origin.x), f32::from(p.y - b.origin.y));
            let attrs = {
                let items = items.clone();
                move |p: (f32, f32)| -> Vec<(String, String)> {
                    let mut v = Vec::new();
                    if let Some(op) = hit(&items, p) {
                        v.push(("item".to_string(), op.id.clone()));
                    }
                    v.push(("x".into(), num(p.0)));
                    v.push(("y".into(), num(p.1)));
                    v
                }
            };
            let send = {
                let em = em.clone();
                move |name: &str, a: Vec<(String, String)>| {
                    let r: Vec<(&str, &str)> =
                        a.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
                    em.event(name, &r);
                }
            };
            let pressed_at: Rc<RefCell<Option<(f32, f32)>>> = Rc::new(RefCell::new(None));
            {
                let (state, hitbox, attrs, send, want) = (
                    state.clone(),
                    hitbox.clone(),
                    attrs.clone(),
                    send.clone(),
                    want.clone(),
                );
                let pressed_at = pressed_at.clone();
                window.on_mouse_event(move |ev: &MouseDownEvent, phase, window, cx| {
                    if phase != DispatchPhase::Bubble || !hitbox.is_hovered(window) {
                        return;
                    }
                    let p = local(ev.position);
                    state.update(cx, |s, _| s.pressed = Some(ev.button));
                    *pressed_at.borrow_mut() = Some(p);
                    if want("mouse_down") {
                        let mut a = attrs(p);
                        a.push(("button".into(), button_word(ev.button).into()));
                        send("mouse_down", a);
                    }
                });
            }
            {
                let (state, hitbox, attrs, send, want) = (
                    state.clone(),
                    hitbox.clone(),
                    attrs.clone(),
                    send.clone(),
                    want.clone(),
                );
                window.on_mouse_event(move |ev: &MouseUpEvent, phase, window, cx| {
                    if phase != DispatchPhase::Bubble {
                        return;
                    }
                    let was = state.update(cx, |s, _| s.pressed.take());
                    if was.is_none() {
                        return;
                    }
                    let p = local(ev.position);
                    if want("mouse_up") {
                        let mut a = attrs(p);
                        a.push(("button".into(), button_word(ev.button).into()));
                        send("mouse_up", a);
                    }
                    if want("click") && was == Some(ev.button) && hitbox.is_hovered(window) {
                        let mut a = attrs(p);
                        a.push(("button".into(), button_word(ev.button).into()));
                        send("click", a);
                    }
                });
            }
            {
                let (state, hitbox, items) = (state.clone(), hitbox.clone(), items.clone());
                window.on_mouse_event(move |ev: &MouseMoveEvent, phase, window, cx| {
                    if phase != DispatchPhase::Bubble {
                        return;
                    }
                    let p = local(ev.position);
                    let over = hitbox.is_hovered(window);
                    let pressed = state.read(cx).pressed.is_some();
                    if pressed && want("drag") {
                        send("drag", attrs(p));
                    } else if over && want("move") {
                        send("move", attrs(p));
                    }
                    if track_hover {
                        let now = if over {
                            hit(&items, p).map(|o| o.id.clone())
                        } else {
                            None
                        };
                        let changed = state.update(cx, |s, _| {
                            if s.hovered != now {
                                s.hovered = now;
                                true
                            } else {
                                false
                            }
                        });
                        if changed {
                            window.refresh();
                        }
                    }
                });
            }
        },
    )
    .absolute()
    .top_0()
    .left_0()
    .size_full()
    .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn op(l: &str) -> CanvasOp {
        CanvasOp::parse(l).unwrap()
    }

    #[test]
    fn hit_testing_picks_the_topmost_item() {
        let items = vec![
            op("rect bg 0 0 400 300 fill=background"),
            op("rect card 20 20 160 90 fill=muted"),
            op("circle dot 140 150 4 fill=primary"),
            op("path spark M20,200 L60,180 stroke=primary width=2"),
            op("line l 300 0 300 100"),
            op("text lbl 28 44 Revenue size=13"),
        ];
        let id = |x, y| hit(&items, (x, y)).map(|o| o.id.as_str());
        assert_eq!(id(141., 150.), Some("dot"));
        assert_eq!(id(30., 30.), Some("card"));
        assert_eq!(id(350., 10.), Some("bg"));
        assert_eq!(id(301., 50.), Some("l"));
        assert_eq!(id(40., 190.), Some("spark"));
        assert_eq!(id(30., 50.), Some("lbl"));
        assert_eq!(id(500., 500.), None);
    }

    #[test]
    fn relative_paths_become_absolute() {
        let o = op("path p m10,10 l5,0 h5 v5 z");
        assert_eq!(
            absolute(&o),
            vec![
                Seg::Move((10., 10.)),
                Seg::Line((15., 10.)),
                Seg::Line((20., 10.)),
                Seg::Line((20., 15.)),
                Seg::Close
            ]
        );
        let o = op("path q M0,0 Q5,5,10,0 T20,0");
        assert_eq!(absolute(&o)[2], Seg::Quad((15., -5.), (20., 0.)));
        let f = op("path tri M0,0 L10,0 L0,10 Z fill=primary");
        assert!(hits(&f, (2., 2.)));
        assert!(!hits(&f, (9., 9.)));
    }

    #[test]
    fn pixels_become_a_bmp() {
        let rgba = vec![255u8; 4 * 3 * 2];
        let (bmp, w, h) = bmp_from_rgba(&rgba, 3.).unwrap();
        assert_eq!((w, h), (3, 2));
        assert_eq!(&bmp[..2], b"BM");
        assert_eq!(bmp.len(), 14 + 108 + rgba.len());
        assert!(bmp_from_rgba(&rgba[..5], 3.).is_none());
        assert!(bmp_from_rgba(&rgba, 0.).is_none());
    }
}

#[cfg(test)]
mod render_tests;
