//! The tree's storage: nodes keyed by full path, windows, and the app-level
//! files. `State` is cloned before every op and swapped in only on success,
//! so an op never half-applies. Nodes sit behind `Arc`, so a clone copies
//! pointers and untouched nodes stay shared with older snapshots.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use bytes::Bytes;
use catalog::{PropKind, Slots, Tier, TypeSpec};

use crate::Registry;

/// One stored file value and the state generation that last wrote it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FileVal {
    pub data: Bytes,
    pub version: u32,
}

/// A node file: its value, plus when it was first written, so a `tree`
/// document prints props in the order they were set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct NodeFile {
    pub data: Bytes,
    pub version: u32,
    pub first: u32,
}

#[derive(Debug, Clone)]
pub(crate) struct Node {
    /// Unique for the life of the tree: a node deleted and made again at
    /// the same path gets a new one.
    pub uid: u64,
    pub ty: String,
    pub name: String,
    /// Prop and common files that have been written. Unwritten files read
    /// as the spec default, or empty.
    pub files: BTreeMap<String, NodeFile>,
    /// Counter for `NodeFile::first`.
    pub next_first: u32,
    /// Child names in creation order.
    pub children: Vec<String>,
    /// What gets drawn, in order. `new` and `mkdir` append.
    pub order: Vec<String>,
    /// Set by `frame_drawn`: `type` can no longer change.
    pub fixed: bool,
    /// Files the host wrote through `mirror`: component state that a `tree`
    /// rewrite keeps unless the document names it.
    pub mirrored: BTreeSet<String>,
    /// Bumped when children, `order` or `type` change.
    pub version: u32,
}

impl Node {
    pub fn new(uid: u64, ty: &str, name: &str, version: u32) -> Self {
        Node {
            uid,
            next_first: 0,
            ty: ty.to_string(),
            name: name.to_string(),
            files: BTreeMap::new(),
            children: Vec::new(),
            order: Vec::new(),
            fixed: false,
            mirrored: BTreeSet::new(),
            version,
        }
    }

    /// Stores a file, keeping its first-write position.
    pub fn put_file(&mut self, name: &str, data: Bytes, version: u32) {
        match self.files.get_mut(name) {
            Some(f) => {
                f.data = data;
                f.version = version;
            }
            None => {
                let first = self.next_first;
                self.next_first += 1;
                self.files.insert(name.to_string(), NodeFile { data, version, first });
            }
        }
    }
}

#[derive(Debug, Clone, Default)]
pub(crate) struct Win {
    pub name: String,
    /// `title`, `state`, `focus`.
    pub files: BTreeMap<String, FileVal>,
    /// The `window` verb's options as given.
    pub props: Vec<(String, String)>,
    pub version: u32,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct State {
    /// Bumped once per applied op; file versions come from it.
    pub generation: u32,
    pub nodes: BTreeMap<String, Arc<Node>>,
    pub windows: BTreeMap<String, Arc<Win>>,
    /// `keymap`, `clipboard`, `clipboard-files`, `theme/mode`, `theme/name`.
    pub root_files: BTreeMap<String, FileVal>,
    /// `theme/tokens` overrides on top of the mode's defaults.
    pub tokens: BTreeMap<String, String>,
    pub tokens_version: u32,
    /// `menus/<name>` in creation order (the menu bar's order).
    pub menus: Vec<(String, FileVal)>,
    pub assets: BTreeMap<String, FileVal>,
    /// `drags/<n>/data`.
    pub drags: BTreeMap<u64, FileVal>,
    /// Set once the app has quit: every later op fails with `app gone`.
    pub gone: bool,
    /// The next `Node::uid`.
    pub next_uid: u64,
}

/// Files every node has, beyond its type's props.
pub(crate) const COMMON_WRITABLE: &[&str] =
    &["style", "tag", "on", "context", "tooltip", "drop", "drag-type"];
/// Files every node has that are computed or structural.
pub(crate) const COMMON_SPECIAL: &[&str] = &["type", "order", "ctl", "events", "bounds", "id", "tree"];

/// Event names an `on` file may list, beyond the type's own events.
pub(crate) const ON_WORDS: &[&str] = &[
    "click", "hover", "mouse_down", "mouse_up", "scroll", "key", "focus", "blur", "move", "drag",
    "drop",
];

/// The files directly under a window directory.
pub(crate) const WINDOW_FILES: &[&str] = &["ctl", "events", "title", "bounds", "state", "focus"];

pub(crate) const ROOT_FILES: &[&str] =
    &["version", "ctl", "events", "trace", "keymap", "clipboard", "clipboard-files"];
pub(crate) const ROOT_DIRS: &[&str] = &["theme", "menus", "drags", "assets", "windows"];

pub(crate) const SIZE_WORDS: &[&str] = &["xs", "sm", "md", "lg"];

/// `div` is always known, even before `catalog::elements` is filled in.
pub(crate) static DIV_FALLBACK: TypeSpec = TypeSpec {
    name: "div",
    tier: Tier::Element,
    props: &[],
    verbs: &[],
    events: &[],
    slots: Slots::Any,
    variants: &[],
    sizable: false,
};

/// The type of a window's `overlays/` directory. Not in the registry, so a
/// client can't make one.
pub(crate) static OVERLAYS_SPEC: TypeSpec = TypeSpec {
    name: "overlays",
    tier: Tier::Element,
    props: &[],
    verbs: &[],
    events: &[],
    slots: Slots::Any,
    variants: &[],
    sizable: false,
};

pub(crate) const MAX_DEPTH: usize = 64;
pub(crate) const MAX_CTL: usize = 64 << 10;
pub(crate) const MAX_TEXT: usize = 16 << 20;
pub(crate) const MAX_DATA: usize = 64 << 20;
pub(crate) const MAX_BYTES: usize = 16 << 20;

impl Registry {
    pub(crate) fn spec_of(&self, ty: &str) -> Option<&'static TypeSpec> {
        if ty == "overlays" {
            return Some(&OVERLAYS_SPEC);
        }
        self.get(ty).or(if ty == "div" { Some(&DIV_FALLBACK) } else { None })
    }

    /// Whether any known type uses `word` as a variant.
    pub(crate) fn is_variant_word(&self, word: &str) -> bool {
        self.iter().any(|t| t.variants.contains(&word))
    }
}

pub(crate) fn prop_spec(spec: &'static TypeSpec, file: &str) -> Option<&'static catalog::PropSpec> {
    spec.props.iter().find(|p| p.name == file)
}

/// Whether `file` is the `append` pseudo-file of a type with `rows`.
pub(crate) fn is_append_file(spec: &'static TypeSpec, file: &str) -> bool {
    file == "append"
        && prop_spec(spec, "append").is_none()
        && prop_spec(spec, "rows").is_some()
}

/// Child names that would hide a node file.
pub(crate) fn is_reserved(spec: &TypeSpec, name: &str) -> bool {
    COMMON_WRITABLE.contains(&name)
        || COMMON_SPECIAL.contains(&name)
        || name == "append"
        || spec.props.iter().any(|p| p.name == name)
}

pub(crate) fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.contains('/')
        && !name.chars().any(|c| c.is_whitespace() || c == '\'' || c.is_control())
}

/// `windows/<w>/...` -> `w`.
pub(crate) fn window_of(path: &str) -> Option<&str> {
    let rest = path.strip_prefix("windows/")?;
    Some(rest.split('/').next().unwrap_or(rest)).filter(|w| !w.is_empty())
}

/// `windows/<w>/root/a/b` -> `root/a/b`.
pub(crate) fn win_relative(path: &str) -> Option<&str> {
    let rest = path.strip_prefix("windows/")?;
    let i = rest.find('/')?;
    Some(&rest[i + 1..])
}

pub(crate) fn parent_of(path: &str) -> Option<&str> {
    path.rfind('/').map(|i| &path[..i])
}

pub(crate) fn base_of(path: &str) -> &str {
    path.rfind('/').map(|i| &path[i + 1..]).unwrap_or(path)
}

/// Node depth below the window directory (`root` is 1).
pub(crate) fn depth_of(path: &str) -> usize {
    win_relative(path).map(|r| r.split('/').count()).unwrap_or(0)
}

impl State {
    pub fn new_node(&mut self, ty: &str, name: &str) -> Node {
        self.next_uid += 1;
        Node::new(self.next_uid, ty, name, self.generation)
    }

    pub fn node(&self, path: &str) -> Option<&Arc<Node>> {
        self.nodes.get(path)
    }

    pub fn node_mut(&mut self, path: &str) -> Option<&mut Node> {
        self.nodes.get_mut(path).map(Arc::make_mut)
    }

    /// The path and every descendant, children before parents.
    pub fn subtree_paths(&self, path: &str) -> Vec<String> {
        let mut out = Vec::new();
        fn walk(st: &State, p: &str, out: &mut Vec<String>) {
            if let Some(n) = st.nodes.get(p) {
                for c in &n.children {
                    walk(st, &format!("{p}/{c}"), out);
                }
                out.push(p.to_string());
            }
        }
        walk(self, path, &mut out);
        out
    }

    /// Removes a node and its descendants, and unlinks it from its parent.
    pub fn remove_subtree(&mut self, path: &str) {
        for p in self.subtree_paths(path) {
            self.nodes.remove(&p);
        }
        let generation = self.generation;
        if let Some(parent) = parent_of(path).and_then(|p| self.node_mut(p)) {
            let name = base_of(path);
            parent.children.retain(|c| c != name);
            parent.order.retain(|c| c != name);
            parent.version = generation;
        }
    }

    /// A file's stored bytes, or the spec default, or empty.
    pub fn node_file<'a>(&'a self, reg: &Registry, path: &str, file: &str) -> Option<&'a [u8]> {
        let n = self.nodes.get(path)?;
        if let Some(v) = n.files.get(file) {
            return Some(&v.data);
        }
        let spec = reg.spec_of(&n.ty)?;
        if let Some(p) = prop_spec(spec, file) {
            return Some(p.default.unwrap_or("").as_bytes());
        }
        if COMMON_WRITABLE.contains(&file) {
            return Some(b"");
        }
        None
    }

    pub fn is_secret(&self, reg: &Registry, path: &str) -> bool {
        self.node_file(reg, path, "flags")
            .map(|f| String::from_utf8_lossy(f).split_whitespace().any(|w| w == "secret"))
            .unwrap_or(false)
    }

    pub fn root_file(&self, name: &str) -> &[u8] {
        self.root_files.get(name).map(|v| &v.data[..]).unwrap_or(b"")
    }

    pub fn win_file(&self, win: &str, name: &str) -> Option<&[u8]> {
        let w = self.windows.get(win)?;
        Some(match w.files.get(name) {
            Some(v) => &v.data,
            None if name == "state" => b"normal",
            None => b"",
        })
    }
}

/// Kind of a prop for the purposes of `Stat`.
pub(crate) fn kind_is_data(k: PropKind) -> bool {
    matches!(k, PropKind::Data(_) | PropKind::Bytes)
}
