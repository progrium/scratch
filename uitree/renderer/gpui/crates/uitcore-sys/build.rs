//! Builds libuitcore.a with `zig build` in uitree/core for the target Cargo
//! is building, and links it. Bindings are hand-written in src/lib.rs (no
//! bindgen, so no libclang); this script checks the header's version
//! constant against them.
//!
//! Environment: `ZIG` (default `zig`, 0.16), `UITCORE_OPTIMIZE` (default
//! ReleaseSafe), `UITCORE_LIB_DIR` (skip zig build and link a prebuilt
//! libuitcore.a and libkern.a from there).

use std::env;
use std::path::PathBuf;
use std::process::Command;

/// Must equal UIT_ABI_VERSION in uitcore.h and ABI_VERSION in src/lib.rs.
const ABI_VERSION: u32 = 2;

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let core = manifest.join("../../../../core").canonicalize().expect("uitree/core");
    let header = core.join("include/uitcore.h");
    println!("cargo:rerun-if-changed={}", header.display());
    println!("cargo:rerun-if-env-changed=ZIG");
    println!("cargo:rerun-if-env-changed=UITCORE_OPTIMIZE");
    println!("cargo:rerun-if-env-changed=UITCORE_LIB_DIR");
    for d in ["src", "build.zig", "build.zig.zon", "types"] {
        println!("cargo:rerun-if-changed={}", core.join(d).display());
    }

    let h = std::fs::read_to_string(&header).unwrap();
    let want = format!("#define UIT_ABI_VERSION {ABI_VERSION}u");
    assert!(h.contains(&want), "uitcore-sys: header is not ABI {ABI_VERSION}; update src/lib.rs and build.rs");

    let h9 = env::var_os("CARGO_FEATURE_H9").is_some();
    let lib = if let Some(dir) = env::var_os("UITCORE_LIB_DIR") {
        PathBuf::from(dir)
    } else {
        let out = PathBuf::from(env::var("OUT_DIR").unwrap());
        let prefix = out.join("zig-out");
        let target = zig_target(&env::var("TARGET").unwrap(), &env::var("HOST").unwrap());
        let optimize = env::var("UITCORE_OPTIMIZE").unwrap_or_else(|_| "ReleaseSafe".into());
        let zig = env::var("ZIG").unwrap_or_else(|_| "zig".into());
        let mut cmd = Command::new(&zig);
        cmd.current_dir(&core)
            .arg("build")
            .arg(format!("-Doptimize={optimize}"))
            .arg(format!("-Dtarget={target}"))
            .arg(format!("-Dh9={h9}"))
            .arg("--prefix")
            .arg(&prefix)
            .arg("--cache-dir")
            .arg(out.join("zig-cache"));
        let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();
        if target_os == "macos" && env::var_os("SDKROOT").is_none() {
            if let Ok(o) = Command::new("xcrun").arg("--show-sdk-path").output() {
                cmd.env("SDKROOT", String::from_utf8_lossy(&o.stdout).trim());
            }
        }
        let st = cmd.status().unwrap_or_else(|e| panic!("uitcore-sys: running {zig}: {e} (needs Zig 0.16)"));
        assert!(st.success(), "uitcore-sys: zig build failed in {}", core.display());
        prefix.join("lib")
    };
    // Apple's ld refuses Zig's archives ("64-bit mach-o member ... not
    // 8-byte aligned"), and libtool copying the archive whole drops those
    // members. So on macOS unpack each one with ar and archive the objects
    // again with libtool, which aligns them, and link the copies.
    let lib = if env::var("CARGO_CFG_TARGET_OS").unwrap() == "macos" {
        let dir = PathBuf::from(env::var("OUT_DIR").unwrap()).join("lib-macos");
        std::fs::create_dir_all(&dir).unwrap();
        for name in ["libuitcore.a", "libkern.a"] {
            let src = lib.join(name);
            if !src.exists() {
                continue;
            }
            let objs = dir.join(format!("{name}.objs"));
            let _ = std::fs::remove_dir_all(&objs);
            std::fs::create_dir_all(&objs).unwrap();
            let st = Command::new("ar").arg("-x").arg(&src).current_dir(&objs).status()
                .unwrap_or_else(|e| panic!("uitcore-sys: running ar: {e}"));
            assert!(st.success(), "uitcore-sys: ar -x failed on {}", src.display());
            let mut members: Vec<PathBuf> = std::fs::read_dir(&objs).unwrap()
                .map(|e| e.unwrap().path())
                .filter(|p| p.extension().is_some_and(|x| x == "o"))
                .collect();
            members.sort();
            // Zig writes members with mode 0, which ar keeps: make them readable.
            #[cfg(unix)]
            for m in &members {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(m, std::fs::Permissions::from_mode(0o644)).unwrap();
            }
            assert!(!members.is_empty(), "uitcore-sys: no objects in {}", src.display());
            let out = dir.join(name);
            let _ = std::fs::remove_file(&out);
            let st = Command::new("libtool").args(["-static", "-o"]).arg(&out).args(&members).status()
                .unwrap_or_else(|e| panic!("uitcore-sys: running libtool: {e}"));
            assert!(st.success(), "uitcore-sys: libtool -static failed for {name}");
            if name == "libuitcore.a" {
                let o = Command::new("nm").arg("-g").arg(&out).output().expect("uitcore-sys: running nm");
                let syms = String::from_utf8_lossy(&o.stdout);
                assert!(
                    syms.contains(" T _uit_abi_version"),
                    "uitcore-sys: {} has no _uit_abi_version after re-archiving; members {:?}; nm: {}",
                    out.display(),
                    members,
                    String::from_utf8_lossy(&o.stderr)
                );
            }
        }
        dir
    } else {
        lib
    };
    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=static=uitcore");
    if h9 {
        println!("cargo:rustc-link-lib=static=kern");
    }
    match env::var("CARGO_CFG_TARGET_OS").unwrap().as_str() {
        "macos" if h9 => println!("cargo:rustc-link-lib=framework=Hypervisor"),
        "windows" => {
            println!("cargo:rustc-link-lib=ws2_32");
            println!("cargo:rustc-link-lib=advapi32");
            println!("cargo:rustc-link-lib=ntdll");
            if h9 {
                println!("cargo:rustc-link-lib=WinHvPlatform");
            }
        }
        _ => {}
    }
}

/// Cargo's target triple as Zig spells it; `native` for the host.
fn zig_target(target: &str, host: &str) -> String {
    // Zig's native ABI on Windows is gnu, so an MSVC build always names
    // its target: a gnu libuitcore in an MSVC link brings a compiler_rt
    // that link.exe rejects (LNK1143).
    if target == host && !target.ends_with("msvc") {
        return "native".into();
    }
    let arch = target.split('-').next().unwrap();
    let os = if target.contains("apple-darwin") {
        "macos"
    } else if target.contains("windows") {
        if target.ends_with("msvc") { "windows-msvc" } else { "windows-gnu" }
    } else if target.contains("linux-musl") {
        "linux-musl"
    } else if target.contains("linux") {
        "linux-gnu"
    } else {
        panic!("uitcore-sys: no Zig target for {target}");
    };
    format!("{arch}-{os}")
}
