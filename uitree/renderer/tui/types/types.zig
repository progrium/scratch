//! The descriptors of the types uitree-tui draws, copied from
//! core/types/ (interface I6), and the style words and theme tokens it
//! registers (I7). Written by gen.sh; do not edit.

pub const names = [_][]const u8{
    "div",
    "text",
    "styled-text",
    "img",
    "svg",
    "icon",
    "scroll",
    "spacer",
    "button",
    "checkbox",
    "radio-group",
    "switch",
    "select",
    "input",
    "textarea",
    "number-input",
    "slider",
    "form",
    "field",
    "link",
    "tabs",
    "tab",
    "empty",
    "separator",
    "badge",
    "kbd",
    "progress",
    "spinner",
    "alert",
    "dialog",
};

pub const descriptors = "" ++ @embedFile("div/spec") ++ @embedFile("text/spec") ++ @embedFile("styled-text/spec") ++ @embedFile("img/spec") ++ @embedFile("svg/spec") ++ @embedFile("icon/spec") ++ @embedFile("scroll/spec") ++ @embedFile("spacer/spec") ++ @embedFile("button/spec") ++ @embedFile("checkbox/spec") ++ @embedFile("radio-group/spec") ++ @embedFile("switch/spec") ++ @embedFile("select/spec") ++ @embedFile("input/spec") ++ @embedFile("textarea/spec") ++ @embedFile("number-input/spec") ++ @embedFile("slider/spec") ++ @embedFile("form/spec") ++ @embedFile("field/spec") ++ @embedFile("link/spec") ++ @embedFile("tabs/spec") ++ @embedFile("tab/spec") ++ @embedFile("empty/spec") ++ @embedFile("separator/spec") ++ @embedFile("badge/spec") ++ @embedFile("kbd/spec") ++ @embedFile("progress/spec") ++ @embedFile("spinner/spec") ++ @embedFile("alert/spec") ++ @embedFile("dialog/spec");

pub const style_words = @embedFile("style-words");
pub const theme_tokens = @embedFile("theme-tokens");
pub const themes = @embedFile("themes");
