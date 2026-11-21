//! Reading the tree: `stat`, `readdir` and `read` for every path, including
//! the computed files (`id`, `ctl` listings, `tree`, `bounds`, `version`,
//! `trace`, `theme/tokens`).

use std::sync::Arc;

use bytes::Bytes;
use catalog::{PropKind, Tier};

use crate::state::*;
use crate::{FsPath, Registry, Shared, Stat, StatKind};

const VERSION: &str = "gpuifs 0.1\ntree\nbatch\nrequests\ndrag\ncanvas\n";

const ROOT_CTL: &str = "window name [title=text] [size=w,h] [min=w,h] [pos=x,y|center] [kind=normal|dialog|popup] [titlebar=system|custom|none] [resizable=on|off]
set id [enabled=on|off] [check=on|off]
theme load path
theme mode light|dark
theme name name
begin
commit
abort
quit
";

const WINDOW_CTL: &str = "title text
size w,h
move x,y
center
state normal|minimized|maximized|fullscreen
activate
close
destroy
notify text [type=info|success|warning|error]
begin
commit
abort
";

/// An immutable view of the tree after a batch of ops. `Send + Sync`.
#[derive(Debug, Default)]
pub struct Snapshot {
    st: Arc<State>,
    reg: Arc<Registry>,
    shared: Arc<Shared>,
}

impl Snapshot {
    pub(crate) fn new(st: Arc<State>, reg: Arc<Registry>, shared: Arc<Shared>) -> Self {
        Snapshot { st, reg, shared }
    }

    fn view(&self) -> View<'_> {
        View::new(&self.st, &self.reg, Some(&self.shared))
    }

    pub fn stat(&self, p: &FsPath) -> Option<Stat> {
        self.view().stat(p.as_str())
    }

    pub fn readdir(&self, p: &FsPath) -> Option<Vec<Stat>> {
        self.view().readdir(p.as_str())
    }

    pub fn read(&self, p: &FsPath) -> Option<Bytes> {
        self.view().read(p.as_str())
    }

    /// Whether the app has quit (every access should fail with `app gone`).
    pub fn is_gone(&self) -> bool {
        self.st.gone
    }

    /// The state generation, bumped by every applied op.
    pub fn generation(&self) -> u32 {
        self.st.generation
    }
}

pub(crate) struct View<'a> {
    st: &'a State,
    reg: &'a Registry,
    shared: Option<&'a Shared>,
}

impl<'a> View<'a> {
    pub fn new(st: &'a State, reg: &'a Registry, shared: Option<&'a Shared>) -> Self {
        View { st, reg, shared }
    }

    /// Kind and version, without computing contents.
    pub fn kind_of(&self, path: &str) -> Option<(StatKind, u32)> {
        let g = self.st.generation;
        let path = path.trim_matches('/');
        Some(match path {
            "" | "theme" | "menus" | "drags" | "assets" | "windows" => (StatKind::Dir, g),
            "version" | "trace" => (StatKind::ReadOnly, g),
            "ctl" => (StatKind::Ctl, 0),
            "events" => (StatKind::Events, 0),
            "keymap" => (StatKind::Data, self.root_version("keymap")),
            "clipboard" | "clipboard-files" => (StatKind::Text, self.root_version(path)),
            "theme/tokens" => (StatKind::Data, self.st.tokens_version),
            "theme/mode" | "theme/name" => (StatKind::Text, self.root_version(path)),
            _ => {
                if let Some(m) = path.strip_prefix("menus/") {
                    let (_, v) = self.st.menus.iter().find(|(n, _)| n == m)?;
                    return Some((StatKind::Data, v.version));
                }
                if let Some(a) = path.strip_prefix("assets/") {
                    return Some((StatKind::Data, self.st.assets.get(a)?.version));
                }
                if let Some(d) = path.strip_prefix("drags/") {
                    let (n, rest) = d.split_once('/').unwrap_or((d, ""));
                    let v = self.st.drags.get(&n.parse::<u64>().ok()?)?;
                    return match rest {
                        "" => Some((StatKind::Dir, v.version)),
                        "data" => Some((StatKind::Data, v.version)),
                        _ => None,
                    };
                }
                if let Some(r) = path.strip_prefix("windows/") {
                    let (w, rest) = r.split_once('/').unwrap_or((r, ""));
                    let win = self.st.windows.get(w)?;
                    if rest.is_empty() {
                        return Some((StatKind::Dir, win.version));
                    }
                    if WINDOW_FILES.contains(&rest) {
                        let v = win
                            .files
                            .get(rest)
                            .map(|f| f.version)
                            .unwrap_or(win.version);
                        return Some((
                            match rest {
                                "ctl" => StatKind::Ctl,
                                "events" => StatKind::Events,
                                "bounds" => StatKind::ReadOnly,
                                _ => StatKind::Text,
                            },
                            v,
                        ));
                    }
                }
                if let Some(n) = self.st.nodes.get(path) {
                    return Some((StatKind::Dir, n.version));
                }
                let (node, file) = path.rsplit_once('/')?;
                let n = self.st.nodes.get(node)?;
                let spec = self.reg.spec_of(&n.ty)?;
                let fv = n.files.get(file).map(|f| f.version).unwrap_or(n.version);
                match file {
                    "ctl" => (StatKind::Ctl, 0),
                    "events" => (StatKind::Events, 0),
                    "id" | "bounds" => (StatKind::ReadOnly, n.version),
                    "tree" => (StatKind::Data, g),
                    "type" | "order" => (StatKind::Text, n.version),
                    f if COMMON_WRITABLE.contains(&f) => (StatKind::Text, fv),
                    f if is_append_file(spec, f) => (StatKind::Data, fv),
                    f => match prop_spec(spec, f)?.kind {
                        PropKind::ReadOnly => (StatKind::ReadOnly, fv),
                        k if kind_is_data(k) => (StatKind::Data, fv),
                        _ => (StatKind::Text, fv),
                    },
                }
            }
        })
    }

    fn root_version(&self, name: &str) -> u32 {
        self.st.root_files.get(name).map(|f| f.version).unwrap_or(0)
    }

    pub fn stat(&self, path: &str) -> Option<Stat> {
        let path = path.trim_matches('/');
        let (kind, version) = self.kind_of(path)?;
        let name = if path.is_empty() {
            "/".to_string()
        } else {
            base_of(path).to_string()
        };
        let skip = matches!(kind, StatKind::Dir | StatKind::Events)
            || path == "trace"
            || path.ends_with("/tree");
        let len = if skip {
            0
        } else {
            self.read(path).map(|b| b.len() as u64).unwrap_or(0)
        };
        Some(Stat {
            name,
            kind,
            len,
            version,
        })
    }

    pub fn readdir(&self, path: &str) -> Option<Vec<Stat>> {
        let path = path.trim_matches('/');
        let (kind, _) = self.kind_of(path)?;
        if kind != StatKind::Dir {
            return None;
        }
        let join = |n: &str| {
            if path.is_empty() {
                n.to_string()
            } else {
                format!("{path}/{n}")
            }
        };
        let names: Vec<String> = match path {
            "" => ROOT_FILES
                .iter()
                .chain(ROOT_DIRS)
                .map(|s| s.to_string())
                .collect(),
            "theme" => vec!["tokens".into(), "mode".into(), "name".into()],
            "menus" => self.st.menus.iter().map(|(n, _)| n.clone()).collect(),
            "assets" => self.st.assets.keys().cloned().collect(),
            "drags" => self.st.drags.keys().map(|n| n.to_string()).collect(),
            "windows" => self.st.windows.keys().cloned().collect(),
            _ if path.starts_with("drags/") => vec!["data".into()],
            _ if path.starts_with("windows/") && !path["windows/".len()..].contains('/') => {
                let mut v: Vec<String> = WINDOW_FILES.iter().map(|s| s.to_string()).collect();
                v.push("overlays".into());
                v.push("root".into());
                v
            }
            _ => {
                let n = self.st.nodes.get(path)?;
                let spec = self.reg.spec_of(&n.ty)?;
                let mut v: Vec<String> = COMMON_SPECIAL.iter().map(|s| s.to_string()).collect();
                if spec.name != "overlays" {
                    v.extend(COMMON_WRITABLE.iter().map(|s| s.to_string()));
                    v.extend(spec.props.iter().map(|p| p.name.to_string()));
                    if is_append_file(spec, "append") {
                        v.push("append".into());
                    }
                }
                v.extend(n.children.iter().cloned());
                v
            }
        };
        Some(names.iter().filter_map(|n| self.stat(&join(n))).collect())
    }

    pub fn read(&self, path: &str) -> Option<Bytes> {
        let path = path.trim_matches('/');
        let stat = |s: &'static str| Some(Bytes::from_static(s.as_bytes()));
        match path {
            "version" => return stat(VERSION),
            "ctl" => return stat(ROOT_CTL),
            "events" => return Some(Bytes::new()),
            "trace" => {
                return Some(
                    self.shared
                        .map(|s| s.trace.lock().unwrap().contents())
                        .unwrap_or_default(),
                );
            }
            "keymap" | "clipboard" | "clipboard-files" | "theme/name" => {
                return Some(Bytes::copy_from_slice(self.st.root_file(path)));
            }
            "theme/mode" => {
                let m = self.st.root_file(path);
                return Some(if m.is_empty() {
                    Bytes::from_static(b"light")
                } else {
                    Bytes::copy_from_slice(m)
                });
            }
            "theme/tokens" => return Some(self.tokens()),
            _ => {}
        }
        let (kind, _) = self.kind_of(path)?;
        if kind == StatKind::Dir {
            return None;
        }
        if let Some(m) = path.strip_prefix("menus/") {
            return self
                .st
                .menus
                .iter()
                .find(|(n, _)| n == m)
                .map(|(_, v)| v.data.clone());
        }
        if let Some(a) = path.strip_prefix("assets/") {
            return self.st.assets.get(a).map(|v| v.data.clone());
        }
        if let Some(d) = path.strip_prefix("drags/") {
            let n: u64 = d.split('/').next()?.parse().ok()?;
            return self.st.drags.get(&n).map(|v| v.data.clone());
        }
        let (dir, file) = path.rsplit_once('/')?;
        if let Some(w) = dir.strip_prefix("windows/").filter(|w| !w.contains('/')) {
            return Some(match file {
                "ctl" => Bytes::from_static(WINDOW_CTL.as_bytes()),
                "events" => Bytes::new(),
                "bounds" => self.bounds(dir),
                f => Bytes::copy_from_slice(self.st.win_file(w, f)?),
            });
        }
        let n = self.st.nodes.get(dir)?;
        let spec = self.reg.spec_of(&n.ty)?;
        Some(match file {
            "type" => Bytes::copy_from_slice(n.ty.as_bytes()),
            "order" => Bytes::from(n.order.join(" ")),
            "ctl" => Bytes::from(node_ctl(spec)),
            "events" => Bytes::new(),
            "bounds" => self.bounds(dir),
            "id" => Bytes::copy_from_slice(win_relative(dir).unwrap_or(dir).as_bytes()),
            "tree" => Bytes::from(crate::doc::print_subtree(self.st, self.reg, dir)),
            "append" if is_append_file(spec, "append") => Bytes::new(),
            f => match n.files.get(f) {
                Some(v) => v.data.clone(),
                None => Bytes::copy_from_slice(self.st.node_file(self.reg, dir, f)?),
            },
        })
    }

    fn bounds(&self, path: &str) -> Bytes {
        let b = self
            .shared
            .and_then(|s| s.bounds.lock().unwrap().get(path).copied())
            .unwrap_or([0.0; 4]);
        Bytes::from(format!("{} {} {} {}", b[0], b[1], b[2], b[3]))
    }

    fn tokens(&self) -> Bytes {
        let mode = if self.st.root_file("theme/mode") == b"dark" {
            style::Mode::Dark
        } else {
            style::Mode::Light
        };
        let mut all: std::collections::BTreeMap<String, String> = style::default_theme(mode)
            .iter()
            .chain(LENGTH_TOKENS)
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        for (k, v) in &self.st.tokens {
            all.insert(k.clone(), v.clone());
        }
        let mut out = String::new();
        for (k, v) in all {
            out.push_str(&k);
            out.push(' ');
            out.push_str(&v);
            out.push('\n');
        }
        Bytes::from(out)
    }
}

fn node_ctl(spec: &catalog::TypeSpec) -> String {
    let mut out = String::new();
    if spec.name == "overlays" {
        out.push_str("new type name [prop=value ...]\ndelete name\n");
        return out;
    }
    if !matches!(spec.slots, catalog::Slots::None) {
        out.push_str("new type name [prop=value ...]\ndelete name\n");
    }
    for v in spec.verbs {
        out.push_str(if v.usage.is_empty() { v.name } else { v.usage });
        out.push('\n');
    }
    if spec.tier == Tier::Overlay && !spec.verbs.iter().any(|v| v.name == "open") {
        out.push_str("open\nclose\n");
    }
    out
}
