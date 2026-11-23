//! `tree`: GPUI Kit's `TreeState`, built from `items` lines (`id parent
//! label [icon=]`, parent `-` for roots) and the `expanded` IDs. The user's
//! expanding and collapsing goes out as `expand id= value=on|off` and is
//! mirrored to `expanded`; selection as `select value=` and `value`.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, ClickEvent, Entity, IntoElement, ParentElement,
    SharedString, Styled, Subscription, Window, px,
};
use gpui_component::{
    IconName, h_flex,
    list::ListItem,
    tree::{TreeEvent, TreeItem as KitItem, TreeState, tree},
};
use crate::data_lines::TreeItem;

use super::{Watch, icon, id_set, lines, no_verbs, spec};
use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(TreeComp);
}

#[derive(Default)]
pub(crate) struct Meta {
    icons: HashMap<String, String>,
    pub(crate) expanded: Vec<String>,
    /// The selection as mirrored to `value`.
    pub(crate) value: Vec<String>,
    selectable: bool,
    multiple: bool,
    /// The Kit selection last seen, to notice the user's clicks.
    last_kit: Option<SharedString>,
    w_items: Watch,
    w_expanded: Watch,
    w_value: Watch,
}

pub(crate) struct TreeHolder {
    pub(crate) state: Entity<TreeState>,
    pub(crate) meta: Rc<RefCell<Meta>>,
    _subs: Vec<Subscription>,
}

/// Builds Kit items from lines; unknown parents make an item a root.
fn build(items: &[TreeItem], expanded: &HashSet<&str>) -> Vec<KitItem> {
    let ids: HashSet<&str> = items.iter().map(|i| i.id.as_str()).collect();
    let mut kids: HashMap<&str, Vec<&TreeItem>> = HashMap::new();
    let mut roots = vec![];
    for it in items {
        match it.parent.as_deref().filter(|p| ids.contains(p) && *p != it.id) {
            Some(p) => kids.entry(p).or_default().push(it),
            None => roots.push(it),
        }
    }
    fn make(
        it: &TreeItem,
        kids: &HashMap<&str, Vec<&TreeItem>>,
        exp: &HashSet<&str>,
        depth: usize,
    ) -> KitItem {
        let mut k = KitItem::new(it.id.clone(), it.label.clone())
            .expanded(exp.contains(it.id.as_str()))
            .disabled(it.disabled);
        if depth < 64
            && let Some(cs) = kids.get(it.id.as_str())
        {
            k = k.children(cs.iter().map(|c| make(c, kids, exp, depth + 1)));
        }
        k
    }
    roots.iter().map(|r| make(r, &kids, expanded, 0)).collect()
}

fn select(meta: &Rc<RefCell<Meta>>, node: &NodeView, ids: Vec<String>) {
    let mut m = meta.borrow_mut();
    if m.value == ids {
        return;
    }
    m.value = ids;
    let v = m.value.join(" ");
    drop(m);
    let em = node.emitter();
    em.mirror("value", v.clone().into_bytes());
    em.event("select", &[("value", &v)]);
}

struct TreeComp;

impl Component for TreeComp {
    fn spec(&self) -> &'static crate::Spec {
        spec("tree")
    }

    fn create(&self, node: &NodeView, _: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let state = cx.new(|cx| TreeState::new(cx));
        let meta = Rc::new(RefCell::new(Meta::default()));
        let (m1, n1) = (meta.clone(), node.clone());
        let expand = cx.subscribe(&state, move |_, ev: &TreeEvent, _| {
            let (id, on) = match ev {
                TreeEvent::Expanded(id) => (id.to_string(), true),
                TreeEvent::Collapsed(id) => (id.to_string(), false),
            };
            let mut m = m1.borrow_mut();
            m.expanded.retain(|x| *x != id);
            if on {
                m.expanded.push(id.clone());
            }
            let file = m.expanded.join(" ");
            drop(m);
            let em = n1.emitter();
            em.mirror("expanded", file.into_bytes());
            em.event("expand", &[("id", &id), ("value", if on { "on" } else { "off" })]);
        });
        let (m2, n2) = (meta.clone(), node.clone());
        let observe = cx.observe(&state, move |state, cx| {
            let id = state.read(cx).selected_item().map(|i| i.id.clone());
            let mut m = m2.borrow_mut();
            if id == m.last_kit {
                return;
            }
            m.last_kit = id.clone();
            let (selectable, multiple) = (m.selectable, m.multiple);
            let mut ids = m.value.clone();
            drop(m);
            let Some(id) = id.filter(|_| selectable) else {
                return;
            };
            let id = id.to_string();
            if multiple {
                if let Some(p) = ids.iter().position(|x| *x == id) {
                    ids.remove(p);
                } else {
                    ids.push(id);
                }
            } else {
                ids = vec![id];
            }
            select(&m2, &n2, ids);
        });
        let h = TreeHolder {
            state,
            meta,
            _subs: vec![expand, observe],
        };
        Some(cx.new(|_| h).into())
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &crate::Ctl,
        _: &mut Window,
        _: &mut App,
    ) -> crate::VerbResult {
        no_verbs(cmd)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(holder) = rcx.state::<TreeHolder>(node) else {
            return rcx.element(node).into_any_element();
        };
        let (state, meta) = {
            let h = holder.read(rcx.cx_ref());
            (h.state.clone(), h.meta.clone())
        };
        sync(&state, &meta, node, rcx.cx());
        let (m, em) = (meta.clone(), node.emitter());
        let view = tree(&state, move |ix, entry, _selected, _, _| {
            let item = entry.item();
            let m = m.borrow();
            let id = item.id.to_string();
            let mut row = h_flex()
                .gap_1()
                .items_center()
                .pl(px(16. * entry.depth() as f32));
            row = row.child(if entry.is_folder() {
                gpui_component::Icon::new(if entry.is_expanded() {
                    IconName::ChevronDown
                } else {
                    IconName::ChevronRight
                })
                .into_any_element()
            } else {
                gpui::div().w(px(16.)).into_any_element()
            });
            if let Some(i) = m.icons.get(&id) {
                row = row.child(icon(i));
            }
            row = row.child(item.label.clone());
            let em = em.clone();
            let open_id = id.clone();
            ListItem::new(("tree-item", ix))
                .confirmed(m.multiple && m.value.contains(&id))
                .child(row)
                .on_click(move |ev: &ClickEvent, _, _| {
                    if ev.click_count() >= 2 {
                        em.event("open", &[("id", &open_id)]);
                    }
                })
        });
        rcx.element(node)
            .flex()
            .flex_col()
            .child(view.size_full())
            .into_any_element()
    }
}

fn sync(state: &Entity<TreeState>, meta: &Rc<RefCell<Meta>>, node: &NodeView, cx: &mut App) {
    let mut m = meta.borrow_mut();
    m.selectable = node.flag("selectable");
    m.multiple = node.flag("multiple");
    let items_changed = m.w_items.changed(node, "items");
    let exp_changed = m.w_expanded.changed(node, "expanded");
    let value_changed = m.w_value.changed(node, "value");
    if exp_changed {
        m.expanded = id_set(&node.text("expanded").unwrap_or_default());
    }
    if value_changed {
        m.value = id_set(&node.text("value").unwrap_or_default());
    }
    if !(items_changed || exp_changed || value_changed) {
        return;
    }
    let items = lines::<TreeItem>(node, "items");
    m.icons = items
        .iter()
        .filter_map(|i| i.icon.clone().map(|ic| (i.id.clone(), ic)))
        .collect();
    let expanded: HashSet<&str> = m.expanded.iter().map(|s| s.as_str()).collect();
    let kit = build(&items, &expanded);
    let want: Option<SharedString> = m.value.last().map(|s| s.clone().into());
    m.last_kit = want.clone();
    drop(m);
    state.update(cx, |s, cx| {
        s.set_items(kit, cx);
        if let Some(id) = &want
            && let Some(ix) = s.index_of(id)
        {
            s.set_selected_index(Some(ix), cx);
        }
    });
}
