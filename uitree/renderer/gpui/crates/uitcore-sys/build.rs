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
const ABI_VERSION: u32 = 6;

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

    if env::var("CARGO_CFG_TARGET_FAMILY").unwrap() == "wasm" {
        return web(&core);
    }
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
            // Rust builds for the target's baseline CPU, and so does this:
            // `native` alone would use the build machine's CPU features, and
            // a cached build then dies with SIGILL on an older runner.
            .arg("-Dcpu=baseline")
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
    // members. So on macOS unpack each one (unpack_archive) and archive the objects
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
            // Not `ar -x`: kern's archive has members with the same name
            // (draw.o from libdraw and libmemdraw), and extracting by name
            // keeps only the last. Number each member instead.
            let members = unpack_archive(&src, &objs);
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
                // hyper9's kern C uses POSIX names (strdup, memccpy, read,
                // write); MSVC's oldnames.lib maps them to _strdup etc.
                println!("cargo:rustc-link-lib=oldnames");
                println!("cargo:rustc-link-lib=WinHvPlatform");
            }
        }
        _ => {}
    }
}

/// The browser (uitree/web/README.md): the core is linked into this
/// module as on the desktop, built for wasm32-wasi, with h9's web-host
/// coroutines (libh9coro.a) and wasi-libc, whose malloc is then the one
/// allocator for Rust and the core (src/lib.rs). The page supplies the
/// core's platform imports (`h9`, `uit`, `wasi_snapshot_preview1`).
fn web(core: &std::path::Path) {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".into());
    let optimize = env::var("UITCORE_OPTIMIZE").unwrap_or_else(|_| "ReleaseSmall".into());
    let lib = if let Some(dir) = env::var_os("UITCORE_LIB_DIR") {
        PathBuf::from(dir)
    } else {
        let prefix = out.join("zig-out");
        let st = Command::new(&zig)
            .current_dir(core)
            .args(["build", "-Dtarget=wasm32-wasi", &format!("-Doptimize={optimize}")])
            .arg("--prefix")
            .arg(&prefix)
            .arg("--cache-dir")
            .arg(out.join("zig-cache"))
            .status()
            .unwrap_or_else(|e| panic!("uitcore-sys: running {zig}: {e} (needs Zig 0.16)"));
        assert!(st.success(), "uitcore-sys: zig build -Dtarget=wasm32-wasi failed in {}", core.display());
        prefix.join("lib")
    };
    // The C library, as Zig gives a wasm32-wasi program: wasi-libc's C
    // (libc.a, which Zig builds when it links one: link an empty program
    // and take the archive its link line names) and Zig's own libc in Zig
    // (lib/c.zig: malloc, the string functions, ...), which Zig puts in an
    // executable's compilation unit and so has to be built here.
    let libc = out.join("wasi-libc");
    std::fs::create_dir_all(&libc).unwrap();
    let empty = libc.join("empty.zig");
    std::fs::write(&empty, "").unwrap();
    let cache = out.join("zig-cache");
    let run = |args: &[&std::ffi::OsStr]| {
        let o = Command::new(&zig)
            .current_dir(&libc)
            .args(args)
            .arg("--cache-dir")
            .arg(&cache)
            .output()
            .unwrap_or_else(|e| panic!("uitcore-sys: running {zig}: {e}"));
        let text = String::from_utf8_lossy(&o.stderr).into_owned();
        assert!(o.status.success(), "uitcore-sys: zig {:?} failed: {text}", args);
        text
    };
    let os = |s: &str| std::ffi::OsString::from(s);
    let link = run(&[
        &os("build-exe"), &os("-target"), &os("wasm32-wasi"), &os("-lc"), &os("-fno-entry"),
        &os("-mexec-model=reactor"), &os("-OReleaseSmall"), &os("--verbose-link"), empty.as_os_str(),
    ]);
    let archive = link
        .split_whitespace()
        .find(|w| w.ends_with("/libc.a") || w.ends_with("\\libc.a"))
        .unwrap_or_else(|| panic!("uitcore-sys: no libc.a in zig's link line: {link}"));
    std::fs::copy(archive, libc.join("libwasi-c.a")).unwrap();
    let env_out = Command::new(&zig).arg("env").output().expect("uitcore-sys: zig env");
    let env_text = String::from_utf8_lossy(&env_out.stdout);
    let lib_dir = env_text
        .lines()
        .find_map(|l| l.trim().strip_prefix(".lib_dir = \"").or_else(|| l.trim().strip_prefix("\"lib_dir\": \"")))
        .and_then(|r| r.split('"').next())
        .unwrap_or_else(|| panic!("uitcore-sys: no lib_dir in zig env: {env_text}"));
    let zigc = PathBuf::from(lib_dir).join("c.zig");
    let mut root = os("-Mroot=");
    root.push(&zigc);
    let mut emit = os("-femit-bin=");
    emit.push(libc.join("libzigc.a"));
    run(&[&os("build-lib"), &os("-target"), &os("wasm32-wasi"), &os("-lc"), &os("-OReleaseSmall"), &emit, &root]);
    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-search=native={}", libc.display());
    // Not bundled into the rlib: rustc's bundling keeps one archive member
    // per name, and wasi-libc has many with the same name.
    for l in ["uitcore", "h9coro", "wasi-c", "zigc"] {
        println!("cargo:rustc-link-lib=static:-bundle={l}");
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

/// Writes every object in a BSD or GNU `ar` archive to `dir` as
/// `NNNN-name`, skipping symbol tables, and returns their paths in order.
fn unpack_archive(src: &std::path::Path, dir: &std::path::Path) -> Vec<PathBuf> {
    let data = std::fs::read(src).unwrap();
    assert!(data.starts_with(b"!<arch>\n"), "uitcore-sys: {} is not an archive", src.display());
    let field = |b: &[u8]| String::from_utf8_lossy(b).trim().to_string();
    let mut gnu_names: &[u8] = &[];
    let mut out = Vec::new();
    let mut off = 8;
    while off + 60 <= data.len() {
        let h = &data[off..off + 60];
        let raw = field(&h[0..16]);
        let size: usize = field(&h[48..58]).parse().expect("uitcore-sys: archive member size");
        let mut body = &data[off + 60..off + 60 + size];
        let name = if let Some(n) = raw.strip_prefix("#1/") {
            let n: usize = n.parse().unwrap();
            let nm = String::from_utf8_lossy(&body[..n]).trim_end_matches('\0').to_string();
            body = &body[n..];
            nm
        } else if raw == "//" {
            gnu_names = body;
            String::new()
        } else if let Some(i) = raw.strip_prefix('/').and_then(|i| i.parse::<usize>().ok()) {
            let rest = &gnu_names[i..];
            let end = rest.iter().position(|&c| c == b'\n').unwrap_or(rest.len());
            String::from_utf8_lossy(&rest[..end]).trim_end_matches('/').to_string()
        } else {
            raw.trim_end_matches('/').to_string()
        };
        off += 60 + size + (size & 1);
        if name.is_empty() || name.starts_with("__.SYMDEF") || name == "/" || name == "/SYM64/" {
            continue;
        }
        let base = std::path::Path::new(&name).file_name().unwrap().to_string_lossy().into_owned();
        let p = dir.join(format!("{:04}-{base}", out.len()));
        std::fs::write(&p, body).unwrap();
        out.push(p);
    }
    out
}
