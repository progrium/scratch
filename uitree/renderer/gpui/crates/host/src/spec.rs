//! The descriptors of the types this renderer draws (I6), embedded from
//! `uitree/core/types/` at build time.
//!
//! The core owns the catalog and does every check. The renderer reads its
//! own copy only for what drawing needs: slot names (which children a
//! component places itself), variant and size words (a bare `primary` on a
//! `new` line arrives as the prop `primary=on`), and prop and event names.
//! It never refuses anything based on them.

use std::collections::HashMap;
use std::sync::OnceLock;

include!(concat!(env!("OUT_DIR"), "/descriptors.rs"));

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    State,
    Action,
    Request,
}

#[derive(Debug, Default)]
pub struct Spec {
    pub name: &'static str,
    /// The descriptor text, as registered with the core.
    pub text: &'static str,
    pub props: Vec<&'static str>,
    /// `default=` values, by prop.
    pub defaults: Vec<(&'static str, &'static str)>,
    pub verbs: Vec<&'static str>,
    pub events: Vec<(&'static str, EventKind)>,
    pub slots: Vec<&'static str>,
    pub flags: Vec<&'static str>,
    pub variants: Vec<&'static str>,
    pub sizes: Vec<&'static str>,
}

impl Spec {
    fn parse(name: &'static str, text: &'static str) -> Spec {
        let mut s = Spec { name, text, ..Default::default() };
        for line in text.lines() {
            let w: Vec<&'static str> = line.split_whitespace().collect();
            let Some((&head, rest)) = w.split_first() else { continue };
            let attr = |k: &str| rest.iter().find_map(|x| x.strip_prefix(k).and_then(|v| v.strip_prefix('=')));
            let bare: Vec<&'static str> = rest.iter().copied().filter(|x| !x.contains('=')).collect();
            match head {
                "prop" => {
                    if let Some(n) = bare.first() {
                        s.props.push(n);
                        if let Some(d) = attr("default") {
                            s.defaults.push((n, d));
                        }
                    }
                }
                "verb" => s.verbs.extend(bare.first()),
                "slot" => s.slots.extend(bare.first()),
                "event" => {
                    let kind = match attr("kind") {
                        Some("action") => EventKind::Action,
                        Some("request") => EventKind::Request,
                        _ => EventKind::State,
                    };
                    if let Some(n) = bare.first() {
                        s.events.push((n, kind));
                    }
                }
                "word" => match attr("kind") {
                    Some("variant") => s.variants.extend(bare),
                    Some("size") => s.sizes.extend(bare),
                    _ => s.flags.extend(bare),
                },
                _ => {}
            }
        }
        s
    }

    pub fn has_prop(&self, p: &str) -> bool {
        self.props.iter().any(|x| *x == p)
    }

    pub fn default(&self, p: &str) -> Option<&'static str> {
        self.defaults.iter().find(|(n, _)| *n == p).map(|(_, d)| *d)
    }

    pub fn event(&self, e: &str) -> Option<EventKind> {
        self.events.iter().find(|(n, _)| *n == e).map(|(_, k)| *k)
    }
}

fn all() -> &'static HashMap<&'static str, Spec> {
    static M: OnceLock<HashMap<&'static str, Spec>> = OnceLock::new();
    M.get_or_init(|| DESCRIPTORS.iter().map(|(n, t)| (*n, Spec::parse(n, t))).collect())
}

/// A type's descriptor, if core/types has it.
pub fn get(name: &str) -> Option<&'static Spec> {
    all().get(name)
}

/// As [`get`], for a component's own type, which must exist.
pub fn must(name: &str) -> &'static Spec {
    get(name).unwrap_or_else(|| panic!("no descriptor for {name} in uitree/core/types"))
}

/// The descriptors of `names`, concatenated, for `UitConfig.types`.
pub fn registration(names: &[&str]) -> String {
    let mut out = String::new();
    for n in names {
        if let Some(s) = get(n) {
            out.push_str(s.text.trim_end());
            out.push('\n');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn button_descriptor_reads() {
        let b = super::must("button");
        assert!(b.variants.contains(&"primary"));
        assert_eq!(b.sizes, ["xs", "sm", "md", "lg"]);
        assert!(b.slots.contains(&"prefix"));
        assert_eq!(b.event("click"), Some(super::EventKind::Action));
    }
}
