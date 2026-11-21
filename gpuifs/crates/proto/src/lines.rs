//! Line formats for data files (items, columns, TSV rows, tree items,
//! description-list items, radio items, menus, keymap, canvas ops,
//! diagnostics, message-list items, completions). Each type has `parse(&str)`
//! for one line and `Display` printing that line without its newline.
//! Fields are W1's to define; only the type names are contract.
#![allow(unused_variables, dead_code)]

use std::fmt;

use crate::Error;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Item {}

impl Item {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for Item {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Column {}

impl Column {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for Column {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Row {}

impl Row {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for Row {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct TreeItem {}

impl TreeItem {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for TreeItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct DescItem {}

impl DescItem {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for DescItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct RadioItem {}

impl RadioItem {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for RadioItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct MenuLine {}

impl MenuLine {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for MenuLine {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct KeyBinding {}

impl KeyBinding {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for KeyBinding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct CanvasOp {}

impl CanvasOp {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for CanvasOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Diagnostic {}

impl Diagnostic {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Message {}

impl Message {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for Message {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Completion {}

impl Completion {
    pub fn parse(line: &str) -> Result<Self, Error> {
        todo!("W1")
    }
}

impl fmt::Display for Completion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        todo!("W1")
    }
}
