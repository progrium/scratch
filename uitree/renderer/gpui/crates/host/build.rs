//! Embeds the type descriptors (`uitree/core/types/NAME/spec`, W1) so the
//! renderer can register the ones it draws (I6) and read slot, word and
//! event names from them.

use std::path::PathBuf;

fn main() {
    let dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../../../core/types");
    let dir = dir.canonicalize().expect("uitree/core/types");
    println!("cargo:rerun-if-changed={}", dir.display());
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().join("spec").is_file())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let mut out = String::from("/// `(type, descriptor text)` for every type in core/types.\npub static DESCRIPTORS: &[(&str, &str)] = &[\n");
    for n in &names {
        let p = dir.join(n).join("spec");
        println!("cargo:rerun-if-changed={}", p.display());
        out.push_str(&format!("    ({n:?}, include_str!({:?})),\n", p.display().to_string()));
    }
    out.push_str("];\n");
    for f in ["style-words", "theme-tokens"] {
        let p = dir.join(f);
        println!("cargo:rerun-if-changed={}", p.display());
        let id = f.replace('-', "_").to_uppercase();
        out.push_str(&format!("pub static {id}: &str = include_str!({:?});\n", p.display().to_string()));
    }
    let o = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("descriptors.rs");
    std::fs::write(o, out).unwrap();
}
