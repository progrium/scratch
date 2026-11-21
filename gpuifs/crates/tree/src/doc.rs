//! `tree` files: reading prints a subtree document, writing replaces the
//! subtree, keeping each child whose name and type match (DESIGN § Atomic
//! updates, PLAN § Design questions 8).

use std::collections::HashSet;

use bytes::Bytes;
use catalog::PropKind;
use proto::doc::DocNode;
use proto::{Error, ErrorKind};

use crate::Registry;
use crate::apply::{Tx, err};
use crate::state::*;

/// The document for the subtree at `path`.
pub(crate) fn print_subtree(st: &State, reg: &Registry, path: &str) -> String {
    match to_doc(st, reg, path) {
        Some(d) => proto::doc::print(&d),
        None => String::new(),
    }
}

fn to_doc(st: &State, reg: &Registry, path: &str) -> Option<DocNode> {
    let n = st.node(path)?;
    let spec = reg.spec_of(&n.ty)?;
    let text = |b: &[u8]| String::from_utf8_lossy(b).into_owned();
    let mut files: Vec<(&String, &NodeFile)> = n.files.iter().collect();
    files.sort_by_key(|(_, f)| f.first);
    let mut props = Vec::new();
    for (name, f) in files {
        if COMMON_WRITABLE.contains(&name.as_str()) {
            if !f.data.is_empty() {
                props.push((name.clone(), text(&f.data)));
            }
            continue;
        }
        let Some(p) = spec.props.iter().find(|p| p.name == name) else {
            continue;
        };
        if p.kind == PropKind::ReadOnly {
            continue;
        }
        let is_default = p
            .default
            .map(|d| d.as_bytes() == &f.data[..])
            .unwrap_or(f.data.is_empty());
        if !is_default {
            props.push((name.clone(), text(&f.data)));
        }
    }
    if n.order != n.children {
        props.push(("order".to_string(), n.order.join(" ")));
    }
    let children = n
        .children
        .iter()
        .filter_map(|c| to_doc(st, reg, &format!("{path}/{c}")))
        .collect();
    Some(DocNode {
        ty: n.ty.clone(),
        name: n.name.clone(),
        props,
        children,
    })
}

impl Tx<'_> {
    pub(crate) fn write_doc(&mut self, path: &str, data: &[u8]) -> Result<(), Error> {
        let s = std::str::from_utf8(data).map_err(|_| err(ErrorKind::BadValue, "not utf-8"))?;
        let d = proto::doc::parse(s)?;
        let n = self
            .st
            .node(path)
            .ok_or_else(|| err(ErrorKind::NotFound, path))?;
        if d.name != n.name {
            return Err(err(
                ErrorKind::BadValue,
                format!(
                    "tree: the document's root is {}, the node is {}",
                    d.name, n.name
                ),
            ));
        }
        self.apply_doc(path, &d)
    }

    fn apply_doc(&mut self, path: &str, d: &DocNode) -> Result<(), Error> {
        let mut seen = HashSet::new();
        for c in &d.children {
            if !seen.insert(c.name.as_str()) {
                return Err(err(ErrorKind::InUse, format!("{path}/{}", c.name)));
            }
        }
        let cur_ty = self.st.node(path).unwrap().ty.clone();
        if d.ty != cur_ty {
            if path.ends_with("/overlays") && win_relative(path) == Some("overlays") {
                return Err(err(ErrorKind::TypeIsFixed, path));
            }
            self.set_type_doc(path, &d.ty)?;
        }
        // Files the document leaves out go back to their defaults, except
        // component state the host mirrored.
        let named: HashSet<&str> = d.props.iter().map(|(k, _)| k.as_str()).collect();
        {
            let g = self.st.generation;
            let n = self.st.node_mut(path).unwrap();
            let before = n.files.len();
            let mirrored = n.mirrored.clone();
            n.files
                .retain(|f, _| named.contains(f.as_str()) || mirrored.contains(f));
            if n.files.len() != before {
                n.version = g;
            }
        }
        // Children: drop those not in the document, or of another type.
        let existing: Vec<String> = self.st.node(path).unwrap().children.clone();
        for c in existing {
            let cp = format!("{path}/{c}");
            let keep = d
                .children
                .iter()
                .any(|dc| dc.name == c && self.st.node(&cp).is_some_and(|n| n.ty == dc.ty));
            if !keep {
                self.st.remove_subtree(&cp);
            }
        }
        for dc in &d.children {
            let cp = format!("{path}/{}", dc.name);
            if !self.st.nodes.contains_key(&cp) {
                self.create_child(path, &dc.ty, &dc.name, &[], false)?;
            }
            self.apply_doc(&cp, dc)?;
        }
        {
            let g = self.st.generation;
            let n = self.st.node_mut(path).unwrap();
            let names: Vec<String> = d.children.iter().map(|c| c.name.clone()).collect();
            if n.children != names || n.order != names {
                n.children = names.clone();
                n.order = names;
                n.version = g;
            }
        }
        let mut order = None;
        for (k, v) in &d.props {
            match k.as_str() {
                "order" => order = Some(v),
                "type" => {
                    return Err(err(
                        ErrorKind::BadSyntax,
                        "type is the first word of a line",
                    ));
                }
                _ => self.set_file(path, k, Bytes::copy_from_slice(v.as_bytes()), false)?,
            }
        }
        if let Some(o) = order {
            self.set_file(path, "order", Bytes::copy_from_slice(o.as_bytes()), false)?;
        }
        Ok(())
    }

    fn set_type_doc(&mut self, path: &str, ty: &str) -> Result<(), Error> {
        self.set_file(path, "type", Bytes::copy_from_slice(ty.as_bytes()), false)
    }
}
