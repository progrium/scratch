//! `editor`: GPUI Kit's code editor.
//!
//! The host keeps the text. Each user edit mirrors `value` (via=user) and
//! sends a `change` with no text; each caret or selection move mirrors
//! `selection` (`line col line col`, anchor then head, 1-based) and sends a
//! coalesced `cursor line= col=`.
//!
//! `save` comes from the client's own key binding: a `ClientAction` named
//! `save` that reaches the editor (for example `cmd-s save context=editor`
//! in `keymap`) becomes the editor's `save` event instead of an app
//! `action`. With no `save` binding at all, the platform save key
//! (`cmd-s`/`ctrl-s`) sends it.
//!
//! Completion and hover are opt-in: with `complete` (or `hover`) in the
//! node's `on` file, the editor sends `complete line= col= prefix=` (or
//! `hover line= col=`) as a request. The client answers by writing `seq=N`
//! and then completion lines to `completions` (or markdown to `hover`). Only
//! the newest request's answer is used; nothing waits for a client that
//! doesn't answer.

use std::cell::RefCell;
use std::rc::Rc;

use futures::channel::oneshot;
use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, Context, Entity, InteractiveElement as _,
    IntoElement, ParentElement as _, Styled as _, Subscription, Task, Window,
};
use gpui_component::input::{
    CompletionProvider, Editor, EditorState, HoverProvider, InputEvent, Position, Rope,
    RopeExt as _, TabSize,
};
use gpui_kit::base::input::{Diagnostic, DiagnosticSeverity};
use lsp_types::{
    CompletionContext, CompletionItem, CompletionItemKind, CompletionResponse, Hover,
    HoverContents, MarkupContent, MarkupKind,
};

use super::{entity, no_verb, number, raw_text, spec};
use crate::{ClientAction, Component, NodeView, RenderCx};

pub struct EditorComponent;

/// The answer channel of the newest `complete` and `hover` request.
#[derive(Default)]
pub(crate) struct Pending {
    pub(crate) complete: RefCell<Option<(u64, oneshot::Sender<Vec<proto::lines::Completion>>)>>,
    hover: RefCell<Option<(u64, oneshot::Sender<String>)>>,
}

/// The host-side state of one `editor` node.
pub struct EditorNode {
    pub state: Entity<EditorState>,
    node: NodeView,
    /// The text the tree holds (written by the client or mirrored).
    last_value: String,
    /// The `selection` the tree holds.
    last_selection: String,
    pub(crate) pending: Rc<Pending>,
    _subs: Vec<Subscription>,
}

fn tab_size(node: &NodeView) -> TabSize {
    TabSize {
        tab_size: number(node, "tab_size")
            .map(|n| n.max(1.) as usize)
            .unwrap_or(4),
        hard_tabs: false,
    }
}

impl EditorNode {
    fn new(node: &NodeView, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let value = raw_text(node, "value");
        let language = node.text("language").unwrap_or_else(|| "text".into());
        let line_numbers = node.flag("line_numbers");
        let soft_wrap = node.flag("soft_wrap");
        let tab = tab_size(node);
        let placeholder = node.text("placeholder").unwrap_or_default();
        let pending = Rc::new(Pending::default());
        let provider = Rc::new(Provider {
            node: node.clone(),
            pending: pending.clone(),
        });
        let state = cx.new(|cx| {
            let mut s = EditorState::new(window, cx)
                .language(language.trim().to_string())
                .line_number(line_numbers)
                .soft_wrap(soft_wrap)
                .tab_size(tab)
                .placeholder(placeholder)
                .default_value(value.clone());
            s.lsp_mut().completion_provider = Some(provider.clone());
            s.lsp_mut().hover_provider = Some(provider);
            s.set_readonly(node.flag("readonly"), cx);
            s
        });
        let subs = vec![
            cx.subscribe_in(&state, window, |this, _, ev: &InputEvent, _, cx| {
                if let InputEvent::Change = ev {
                    this.on_change(cx);
                }
            }),
            cx.observe(&state, |this, _, cx| this.on_notify(cx)),
        ];
        let mut me = EditorNode {
            state,
            node: node.clone(),
            last_value: value,
            last_selection: node.text("selection").unwrap_or_default(),
            pending,
            _subs: subs,
        };
        me.apply_diagnostics(cx);
        me
    }

    /// A user edit: mirror the text, then say it changed.
    fn on_change(&mut self, cx: &mut Context<Self>) {
        let text = self.state.read(cx).text().to_string();
        if text == self.last_value {
            return;
        }
        let em = self.node.emitter();
        em.mirror("value", text.clone().into_bytes());
        em.event("change", &[]);
        self.last_value = text;
    }

    /// Any state change: report a caret or selection move.
    fn on_notify(&mut self, cx: &mut Context<Self>) {
        let s = self.state.read(cx);
        let range = s.selected_range();
        let head = s.cursor();
        let anchor = if head == range.start {
            range.end
        } else {
            range.start
        };
        let text = s.text();
        let a = text.offset_to_position(anchor);
        let h = text.offset_to_position(head);
        let sel = format!(
            "{} {} {} {}",
            a.line + 1,
            a.character + 1,
            h.line + 1,
            h.character + 1
        );
        if sel == self.last_selection {
            return;
        }
        let em = self.node.emitter();
        em.mirror("selection", sel.clone().into_bytes());
        em.event(
            "cursor",
            &[
                ("line", &(h.line + 1).to_string()),
                ("col", &(h.character + 1).to_string()),
            ],
        );
        self.last_selection = sel;
    }

    /// `diagnostics` lines into the editor's diagnostic set.
    fn apply_diagnostics(&mut self, cx: &mut Context<Self>) {
        let text = self.node.text("diagnostics").unwrap_or_default();
        let diags: Vec<Diagnostic> = text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| proto::lines::Diagnostic::parse(l).ok())
            .map(|d| {
                let line = d.line.saturating_sub(1);
                let col = d.col.saturating_sub(1);
                let sev = match d.severity {
                    proto::lines::Severity::Error => DiagnosticSeverity::Error,
                    proto::lines::Severity::Warning => DiagnosticSeverity::Warning,
                    proto::lines::Severity::Info => DiagnosticSeverity::Info,
                    proto::lines::Severity::Hint => DiagnosticSeverity::Hint,
                };
                Diagnostic::new(
                    Position::new(line, col)..Position::new(line, col + d.len.max(1)),
                    d.message,
                )
                .with_severity(sev)
            })
            .collect();
        self.state.update(cx, |s, cx| {
            if let Some(set) = s.diagnostics_mut() {
                set.clear();
                for d in diags {
                    set.push(d);
                }
            }
            cx.notify();
        });
    }

    /// The client wrote `value`.
    fn set_value(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let value = raw_text(&self.node, "value");
        if value == self.state.read(cx).text().to_string() {
            self.last_value = value;
            return;
        }
        self.last_value = value.clone();
        self.state
            .update(cx, |s, cx| s.set_value(value, window, cx));
        // The old diagnostics were for the old text.
        self.apply_diagnostics(cx);
    }

    /// The client wrote `selection`: `line col line col` (or `line col`).
    fn set_selection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let sel = self.node.text("selection").unwrap_or_default();
        let n: Vec<u32> = sel
            .split_whitespace()
            .filter_map(|x| x.parse().ok())
            .collect();
        let (a, h) = match n[..] {
            [l, c] => ((l, c), (l, c)),
            [l1, c1, l2, c2] => ((l1, c1), (l2, c2)),
            _ => return,
        };
        let pos = |(l, c): (u32, u32)| Position::new(l.saturating_sub(1), c.saturating_sub(1));
        self.last_selection = sel;
        self.state.update(cx, |s, cx| {
            let ao = s.text().position_to_offset(&pos(a));
            let ho = s.text().position_to_offset(&pos(h));
            s.set_cursor_position(pos(h), window, cx);
            if ao != ho {
                s.set_selected_range(ao.min(ho)..ao.max(ho), cx);
            }
        });
    }

    /// The client answered a `complete` request.
    fn answer_completions(&mut self) {
        let text = raw_text(&self.node, "completions");
        let Ok((seq, items)) = proto::lines::parse_completions(&text) else {
            return;
        };
        let mut p = self.pending.complete.borrow_mut();
        if p.as_ref().is_some_and(|(s, _)| *s == seq) {
            let (_, tx) = p.take().unwrap();
            let _ = tx.send(items);
        }
    }

    /// The client answered a `hover` request.
    fn answer_hover(&mut self) {
        let text = raw_text(&self.node, "hover");
        let Ok((seq, body)) = proto::lines::split_seq(&text) else {
            return;
        };
        let mut p = self.pending.hover.borrow_mut();
        if p.as_ref().is_some_and(|(s, _)| *s == seq) {
            let (_, tx) = p.take().unwrap();
            let _ = tx.send(body.to_string());
        }
    }
}

/// Completion and hover lookups, as requests to the client.
struct Provider {
    node: NodeView,
    pub(crate) pending: Rc<Pending>,
}

impl Provider {
    fn wants(&self, word: &str) -> bool {
        self.node.on_words().iter().any(|w| w == word)
    }

    /// Sends a request now (its seq is the answer's tag).
    fn request(&self, name: &str, attrs: Vec<(String, String)>) -> u64 {
        self.node
            .host
            .emit_node_event(self.node.path(), name, attrs)
    }
}

/// The identifier characters before `offset`.
fn prefix_before(text: &Rope, offset: usize) -> String {
    let mut p: Vec<char> = text
        .chars_at(offset)
        .reversed()
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    p.reverse();
    p.into_iter().collect()
}

fn completion_kind(k: &str) -> Option<CompletionItemKind> {
    Some(match k {
        "text" => CompletionItemKind::TEXT,
        "method" => CompletionItemKind::METHOD,
        "function" | "fn" | "func" => CompletionItemKind::FUNCTION,
        "constructor" => CompletionItemKind::CONSTRUCTOR,
        "field" => CompletionItemKind::FIELD,
        "variable" | "var" => CompletionItemKind::VARIABLE,
        "class" => CompletionItemKind::CLASS,
        "interface" => CompletionItemKind::INTERFACE,
        "module" => CompletionItemKind::MODULE,
        "property" => CompletionItemKind::PROPERTY,
        "unit" => CompletionItemKind::UNIT,
        "value" => CompletionItemKind::VALUE,
        "enum" => CompletionItemKind::ENUM,
        "keyword" => CompletionItemKind::KEYWORD,
        "snippet" => CompletionItemKind::SNIPPET,
        "color" => CompletionItemKind::COLOR,
        "file" => CompletionItemKind::FILE,
        "folder" => CompletionItemKind::FOLDER,
        "constant" | "const" => CompletionItemKind::CONSTANT,
        "struct" => CompletionItemKind::STRUCT,
        "event" => CompletionItemKind::EVENT,
        "operator" => CompletionItemKind::OPERATOR,
        "type" => CompletionItemKind::TYPE_PARAMETER,
        _ => return None,
    })
}

fn completion_item(c: proto::lines::Completion) -> CompletionItem {
    CompletionItem {
        label: c.label.clone().unwrap_or_else(|| c.text.clone()),
        insert_text: Some(c.text),
        kind: c.kind.as_deref().and_then(completion_kind),
        detail: c.detail,
        ..Default::default()
    }
}

impl CompletionProvider for Provider {
    fn completions(
        &self,
        text: &Rope,
        offset: usize,
        _trigger: CompletionContext,
        _window: &mut Window,
        cx: &mut App,
    ) -> Task<anyhow::Result<CompletionResponse>> {
        if !self.wants("complete") {
            return Task::ready(Ok(CompletionResponse::Array(vec![])));
        }
        let pos = text.offset_to_position(offset);
        let seq = self.request(
            "complete",
            vec![
                ("line".into(), (pos.line + 1).to_string()),
                ("col".into(), (pos.character + 1).to_string()),
                ("prefix".into(), prefix_before(text, offset)),
            ],
        );
        let (tx, rx) = oneshot::channel();
        // Dropping the previous sender ends the previous lookup with nothing.
        *self.pending.complete.borrow_mut() = Some((seq, tx));
        cx.spawn(async move |_| {
            let items = rx.await.unwrap_or_default();
            Ok(CompletionResponse::Array(
                items.into_iter().map(completion_item).collect(),
            ))
        })
    }

    fn is_completion_trigger(&self, _offset: usize, new_text: &str, _cx: &mut App) -> bool {
        self.wants("complete")
            && new_text
                .chars()
                .any(|c| c.is_alphanumeric() || matches!(c, '_' | '.' | ':'))
    }
}

impl HoverProvider for Provider {
    fn hover(
        &self,
        text: &Rope,
        offset: usize,
        _window: &mut Window,
        cx: &mut App,
    ) -> Task<anyhow::Result<Option<Hover>>> {
        if !self.wants("hover") {
            return Task::ready(Ok(None));
        }
        let pos = text.offset_to_position(offset);
        let seq = self.request(
            "hover",
            vec![
                ("line".into(), (pos.line + 1).to_string()),
                ("col".into(), (pos.character + 1).to_string()),
            ],
        );
        let (tx, rx) = oneshot::channel();
        *self.pending.hover.borrow_mut() = Some((seq, tx));
        cx.spawn(async move |_| {
            let body = rx.await.unwrap_or_default();
            if body.trim().is_empty() {
                return Ok(None);
            }
            Ok(Some(Hover {
                contents: HoverContents::Markup(MarkupContent {
                    kind: MarkupKind::Markdown,
                    value: body,
                }),
                range: None,
            }))
        })
    }
}

/// Whether the client's keymap or menus bind an action named `save`.
fn save_is_bound(node: &NodeView) -> bool {
    let keymap = node
        .host_root_file("keymap")
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    keymap
        .lines()
        .any(|l| l.split_whitespace().nth(1) == Some("save"))
}

impl Component for EditorComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("editor")
    }

    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        Some(cx.new(|cx| EditorNode::new(node, window, cx)).into_any())
    }

    fn prop_changed(
        &self,
        node: &NodeView,
        state: Option<&AnyEntity>,
        prop: &str,
        window: &mut Window,
        cx: &mut App,
    ) {
        let Some(e) = entity::<EditorNode>(state) else {
            return;
        };
        e.update(cx, |me, cx| {
            let st = me.state.clone();
            match prop {
                "value" => me.set_value(window, cx),
                "selection" => me.set_selection(window, cx),
                "diagnostics" => me.apply_diagnostics(cx),
                "completions" => me.answer_completions(),
                "hover" => me.answer_hover(),
                "language" => {
                    let l = node.text("language").unwrap_or_else(|| "text".into());
                    st.update(cx, |s, cx| s.set_highlighter(l.trim().to_string(), cx));
                }
                "line_numbers" => {
                    let v = node.flag("line_numbers");
                    st.update(cx, |s, cx| s.set_line_number(v, window, cx));
                }
                "soft_wrap" => {
                    let v = node.flag("soft_wrap");
                    st.update(cx, |s, cx| s.set_soft_wrap(v, window, cx));
                }
                "tab_size" => {
                    let t = tab_size(node);
                    st.update(cx, |s, cx| s.set_tab_size(t, cx));
                }
                "readonly" => {
                    let v = node.flag("readonly");
                    st.update(cx, |s, cx| s.set_readonly(v, cx));
                }
                "placeholder" => {
                    let p = node.text("placeholder").unwrap_or_default();
                    st.update(cx, |s, cx| s.set_placeholder(p, window, cx));
                }
                _ => {}
            }
        });
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &proto::Command,
        _: &mut Window,
        _: &mut App,
    ) -> Result<(), proto::Error> {
        no_verb(cmd)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(e) = rcx.state::<EditorNode>(node) else {
            return rcx.element(node).into_any_element();
        };
        let state = e.read(rcx.cx_ref()).state.clone();
        let readonly = node.flag("readonly");
        let em = node.emitter();
        let em2 = em.clone();
        let fallback = !save_is_bound(node);
        rcx.element(node)
            .flex()
            .flex_col()
            .on_action(move |a: &ClientAction, _, cx| {
                if a.id.as_ref() == "save" {
                    em.event("save", &[]);
                } else {
                    cx.propagate();
                }
            })
            .on_key_down(move |ev, _, cx| {
                let k = &ev.keystroke;
                if fallback && k.modifiers.secondary(cx) && k.key == "s" && !k.modifiers.shift {
                    em2.event("save", &[]);
                    cx.stop_propagation();
                }
            })
            .child(
                Editor::new(&state)
                    .bordered(false)
                    .readonly(readonly)
                    .size_full()
                    .flex_1(),
            )
            .into_any_element()
    }
}
