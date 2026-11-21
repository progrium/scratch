use super::*;
use std::path::{Path, PathBuf};

#[test]
fn table_is_sorted_and_unique() {
    for w in TABLE.windows(2) {
        assert!(w[0].name < w[1].name, "{} before {}", w[0].name, w[1].name);
    }
    for w in VARIANT_WORDS.windows(2) {
        assert!(w[0].0 < w[1].0);
    }
    assert!(TABLE.len() > 1000, "reflection table looks empty: {}", TABLE.len());
}

#[test]
fn design_examples_resolve() {
    // DESIGN § Style language table.
    for (word, arg, kit) in [
        ("flex_col", ArgKind::None, false),
        ("items_center", ArgKind::None, false),
        ("size_full", ArgKind::None, false),
        ("rounded_md", ArgKind::None, false),
        ("overflow_y_scroll", ArgKind::None, false),
        ("cursor_pointer", ArgKind::None, false),
        ("w", ArgKind::Length, false),
        ("gap", ArgKind::Length, false),
        ("p", ArgKind::Length, false),
        ("px", ArgKind::Length, false),
        ("text_size", ArgKind::Length, false),
        ("bg", ArgKind::Color, false),
        ("text_color", ArgKind::Color, false),
        ("border_color", ArgKind::Color, false),
        ("v_flex", ArgKind::None, true),
        ("h_flex", ArgKind::None, true),
        ("font_semibold", ArgKind::None, true),
        ("font_family", ArgKind::Text, false),
        ("col_span", ArgKind::Number, false),
        ("xs", ArgKind::None, true),
        ("lg", ArgKind::None, true),
        ("primary", ArgKind::None, true),
        ("ghost", ArgKind::None, true),
        ("outline", ArgKind::None, true),
        ("danger", ArgKind::None, true),
        ("link", ArgKind::None, true),
    ] {
        let e = lookup(word).unwrap_or_else(|| panic!("{word} missing"));
        assert_eq!((e.arg, e.kit), (arg, kit), "{word}");
    }
    assert!(matches!(lookup("shadow").unwrap().arg, ArgKind::Many(a) if a.len() == 4));
    assert!(lookup("flex_coll").is_none());
    assert!(lookup("").is_none());
}

#[test]
fn kit_words() {
    assert_eq!(SIZE_WORDS, &["xs", "sm", "md", "lg"]);
    assert!(is_size_word("sm"));
    assert!(variant_owners("primary").contains(&"ButtonVariants"));
    assert!(variant_owners("underline").contains(&"TabVariant"));
    assert!(variant_owners("pill").contains(&"TabVariant"));
    assert!(variant_owners("segmented").contains(&"TabVariant"));
    assert!(variant_owners("flex_col").is_empty());
    // `underline` is also gpui's text decoration; the table keeps that entry.
    assert!(!lookup("underline").unwrap().kit);
}

#[test]
fn theme_data() {
    for t in ["background", "foreground", "primary", "muted", "muted_foreground", "accent", "border", "ring"] {
        assert!(is_theme_token(t), "{t}");
    }
    for mode in [Mode::Light, Mode::Dark] {
        let d = default_theme(mode);
        assert_eq!(d.len(), THEME_TOKENS.len());
        for ((t, v), name) in d.iter().zip(THEME_TOKENS) {
            assert_eq!(t, name);
            assert!(v.starts_with('#') && (v.len() == 7 || v.len() == 9), "{t} {v}");
            assert!(v[1..].chars().all(|c| c.is_ascii_hexdigit()), "{t} {v}");
        }
    }
    assert_eq!(default_token(Mode::Light, "background"), Some("#ffffff"));
    assert_ne!(default_token(Mode::Light, "background"), default_token(Mode::Dark, "background"));
    assert_eq!(find_theme("Tokyo Night"), Some(("Tokyo Night", Mode::Dark)));
    assert_eq!(find_theme("Catppuccin").map(|t| t.0), Some("Catppuccin Latte"));
    assert_eq!(find_theme("Default Dark"), Some(("Default Dark", Mode::Dark)));
    assert!(find_theme("Nope").is_none());
}

// ---- every style word in DESIGN.md and examples/

/// Style words in a file: values of `style=` props, and what is written to a
/// `.../style` file (`echo '...' >x/style`, `put(x+"/style", "...")`,
/// `put $x/style word`).
fn style_values(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines() {
        let mut rest = line;
        while let Some(at) = rest.find("style=") {
            let before = &rest[..at];
            let v = &rest[at + 6..];
            rest = &v[v.len().min(1)..];
            // `variant=`, `runs style` etc. are not the prop; require a word boundary.
            if before.ends_with(|c: char| c.is_alphanumeric() || c == '_' || c == '-') {
                continue;
            }
            let value = if let Some(q) = v.strip_prefix("''") {
                q.split("''").next().unwrap_or("")
            } else if let Some(q) = v.strip_prefix('\'') {
                q.split('\'').next().unwrap_or("")
            } else if let Some(q) = v.strip_prefix('"') {
                q.split('"').next().unwrap_or("")
            } else {
                v.split(|c: char| c.is_whitespace() || c == '\'' || c == '"' || c == '\\')
                    .next()
                    .unwrap_or("")
            };
            out.push(value.to_string());
        }
        if let Some(at) = line.find("/style") {
            let after = &line[at + 6..];
            if after.starts_with(|c: char| c.is_alphanumeric() || c == '_') {
                continue;
            }
            if line[..at].contains("echo") {
                // rc: echo 'words' >path/style   or   echo word >path/style
                let e = line.find("echo").unwrap();
                let arg = line[e + 4..at].trim();
                let arg = arg.rsplit_once('>').map(|(a, _)| a).unwrap_or(arg).trim();
                out.push(arg.trim_matches('\'').to_string());
            } else if let Some(q) = after.split('"').nth(2) {
                // Go: put(r+"/style", "words")
                out.push(q.to_string());
            } else {
                // sh: put $r/x/style words
                out.push(after.trim().to_string());
            }
        }
    }
    out
}

/// The method name of one style word, with state and group prefixes removed.
/// `None` for `group:name`, which names a group rather than calling a method.
fn word_name(word: &str) -> Option<&str> {
    let mut w = word;
    loop {
        if let Some(r) = w.strip_prefix("group-hover(") {
            w = r.split_once("):").map(|(_, r)| r)?;
            continue;
        }
        if w.starts_with("group:") {
            return None;
        }
        let mut stripped = false;
        for p in ["hover:", "active:", "focus:", "disabled:", "drop-over:"] {
            if let Some(r) = w.strip_prefix(p) {
                w = r;
                stripped = true;
            }
        }
        if !stripped {
            break;
        }
    }
    Some(w.split('=').next().unwrap())
}

fn files(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            if p.file_name().is_some_and(|n| n == "__pycache__") {
                continue;
            }
            files(&p, out);
        } else if p.extension().is_none_or(|x| x != "pyc" && x != "csv") {
            out.push(p);
        }
    }
}

#[test]
fn every_style_word_in_design_and_examples_is_in_the_table() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut paths = vec![root.join("DESIGN.md")];
    files(&root.join("examples"), &mut paths);
    let mut seen = 0;
    let mut missing = Vec::new();
    for p in paths {
        let Ok(text) = std::fs::read_to_string(&p) else { continue };
        for value in style_values(&text) {
            for word in value.split_whitespace() {
                let Some(name) = word_name(word) else { continue };
                if name.is_empty() || name.contains('$') || name.contains('%') {
                    continue;
                }
                seen += 1;
                if lookup(name).is_none() {
                    missing.push(format!("{}: {word}", p.strip_prefix(&root).unwrap_or(&p).display()));
                }
            }
        }
    }
    assert!(seen > 200, "extractor found only {seen} words");
    // Known gaps in files W5a doesn't own; see PLAN W5a notes.
    missing.retain(|m| !KNOWN_GAPS.iter().any(|g| m.ends_with(g)));
    assert!(missing.is_empty(), "style words not in the table:\n{}", missing.join("\n"));
}

/// Words the examples use that gpui does not have. Each is reported to the
/// owning thread; remove the entry when the example is fixed.
const KNOWN_GAPS: &[&str] = &[
    // gpui has `grid grid_cols=2` (a number), not a `grid_cols_2` word.
    "examples/rc/gallery/chart/tree: grid_cols_2",
    // gpui's text sizes stop at `text_3xl`; `text_size=36` is the 4xl size.
    "examples/rc/calc.rc: text_4xl",
];

#[test]
fn extractor() {
    let v = style_values(
        "echo 'new div c style=''v_flex gap=4 hover:bg=accent'' tag=x' >$n/ctl\n\
         echo 'h_flex size_full' >$r/style\n\
         if not echo flex_1 >$L/$1/label/style\n\
         put(r+\"/out/style\", \"text_lg font_semibold\")\n\
         put $r/foot/cancel/style primary\n\
         new button b variant=danger style=primary\n",
    );
    assert_eq!(
        v,
        ["v_flex gap=4 hover:bg=accent", "h_flex size_full", "flex_1", "text_lg font_semibold", "primary", "primary"]
    );
    assert_eq!(word_name("group-hover(row):visible"), Some("visible"));
    assert_eq!(word_name("hover:bg=accent"), Some("bg"));
    assert_eq!(word_name("drop-over:bg=accent"), Some("bg"));
    assert_eq!(word_name("group:row"), None);
}
