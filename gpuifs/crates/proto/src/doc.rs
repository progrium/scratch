//! Subtree documents (DESIGN § Atomic updates): two-space indent,
//! `text=<<END` blocks. `print(parse(x)) == x` for canonical input.
#![allow(unused_variables, dead_code)]

use crate::Error;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DocNode {
    pub ty: String,
    pub name: String,
    pub props: Vec<(String, String)>,
    pub children: Vec<DocNode>,
}

pub fn parse(s: &str) -> Result<DocNode, Error> {
    todo!("W1")
}

pub fn print(n: &DocNode) -> String {
    todo!("W1")
}
