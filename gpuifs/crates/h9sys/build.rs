//! Builds `zig/shim.zig` into a static library with `zig build`, against a
//! hyper9 checkout, and links it.
//!
//! The checkout is `$HYPER9_DIR`, or the `third_party/hyper9` submodule of
//! the gpuifs workspace. Zig 0.16 must be on `$PATH` (or `$ZIG`).
//!
//! When either is missing the crate still builds, with `cfg(h9sys_stub)`:
//! `Machine::new` then fails with "h9 is not built in", so the pure crates
//! and `--headless -a` keep working on machines without Zig. Set
//! `H9SYS_REQUIRE=1` to make a missing toolchain a build error instead.
//!
//! Other knobs: `H9SYS_OPTIMIZE` (Debug, ReleaseSafe (default), ReleaseFast,
//! ReleaseSmall), `H9SYS_EMU` (`hcpu` (default) or `none`).

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rustc-check-cfg=cfg(h9sys_stub)");
    for v in ["HYPER9_DIR", "ZIG", "H9SYS_REQUIRE", "H9SYS_OPTIMIZE", "H9SYS_EMU", "H9SYS_STUB"] {
        println!("cargo:rerun-if-env-changed={v}");
    }
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    println!("cargo:rerun-if-changed={}", manifest.join("zig").display());

    let require = env::var("H9SYS_REQUIRE").is_ok_and(|v| v == "1");
    let stub = |why: String| {
        if require {
            panic!("h9sys: {why}");
        }
        println!("cargo:warning=h9sys: {why}; building without h9 (Machine::new will fail)");
        println!("cargo:rustc-cfg=h9sys_stub");
    };
    if env::var("H9SYS_STUB").is_ok_and(|v| v == "1") {
        return stub("H9SYS_STUB=1".into());
    }

    let hyper9 = match env::var_os("HYPER9_DIR") {
        Some(d) => PathBuf::from(d),
        None => manifest.join("../../third_party/hyper9"),
    };
    if !hyper9.join("build.zig").is_file() {
        return stub(format!(
            "no hyper9 checkout at {} (set HYPER9_DIR or run git submodule update --init)",
            hyper9.display()
        ));
    }
    let hyper9 = fs::canonicalize(&hyper9).unwrap();
    // h9's own sources; cargo walks the directory for changes.
    println!("cargo:rerun-if-changed={}", hyper9.join("src").display());
    println!("cargo:rerun-if-changed={}", hyper9.join("build.zig").display());

    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".into());
    match Command::new(&zig).arg("version").output() {
        Ok(o) if o.status.success() => {
            let v = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !v.starts_with("0.16.") {
                println!("cargo:warning=h9sys: hyper9 wants Zig 0.16, found {v}");
            }
        }
        _ => return stub(format!("{zig} not found (hyper9 needs Zig 0.16)")),
    }

    // A Zig package in OUT_DIR: our build.zig and shim.zig, and a zon whose
    // `h9` dependency points at the checkout through a symlink.
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let pkg = out.join("zigpkg");
    fs::create_dir_all(&pkg).unwrap();
    for f in ["build.zig", "shim.zig"] {
        copy_if_changed(&manifest.join("zig").join(f), &pkg.join(f));
    }
    let link = pkg.join("hyper9");
    let _ = fs::remove_file(&link);
    symlink_dir(&hyper9, &link);
    let zon = format!(
        ".{{\n    .name = .h9sys,\n    .version = \"0.1.0\",\n    .fingerprint = {FINGERPRINT},\n    .minimum_zig_version = \"0.16.0\",\n    .dependencies = .{{ .h9 = .{{ .path = \"hyper9\" }} }},\n    .paths = .{{ \"build.zig\", \"build.zig.zon\", \"shim.zig\" }},\n}}\n"
    );
    write_if_changed(&pkg.join("build.zig.zon"), &zon);

    let optimize = env::var("H9SYS_OPTIMIZE").unwrap_or_else(|_| "ReleaseSafe".into());
    let emu = env::var("H9SYS_EMU").unwrap_or_else(|_| "hcpu".into());
    let target = zig_target(&env::var("TARGET").unwrap(), &env::var("HOST").unwrap());
    let prefix = out.join("zig-out");
    let mut cmd = Command::new(&zig);
    cmd.current_dir(&pkg)
        .arg("build")
        .arg(format!("-Doptimize={optimize}"))
        .arg(format!("-Demu={emu}"))
        .arg(format!("-Dtarget={target}"))
        .arg("--prefix")
        .arg(&prefix)
        .arg("--cache-dir")
        .arg(out.join("zig-cache"));
    // hyper9's scripts/env.sh keeps Zig's global cache in the checkout.
    if env::var_os("ZIG_GLOBAL_CACHE_DIR").is_none() {
        cmd.env("ZIG_GLOBAL_CACHE_DIR", hyper9.join(".local/cache/zig"));
    }
    if target.contains("macos") && env::var_os("SDKROOT").is_none() {
        if let Ok(o) = Command::new("xcrun").arg("--show-sdk-path").output() {
            cmd.env("SDKROOT", String::from_utf8_lossy(&o.stdout).trim());
        }
    }
    let status = cmd.status().expect("running zig build");
    if !status.success() {
        panic!("h9sys: zig build failed in {}", pkg.display());
    }

    let lib = prefix.join("lib");
    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=static=h9sys");
    println!("cargo:rustc-link-lib=static=kern");
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    match os.as_str() {
        "macos" => {
            println!("cargo:rustc-link-lib=framework=Hypervisor");
            // HVF refuses to make a VM without the hypervisor entitlement;
            // `sign-macos.sh` signs a built gpuifs with this file.
            let ent = out.join("h9.entitlements");
            fs::copy(hyper9.join("h9.entitlements"), &ent).unwrap();
            println!("cargo:entitlements={}", ent.display());
        }
        "windows" => {
            println!("cargo:rustc-link-lib=ws2_32");
            println!("cargo:rustc-link-lib=advapi32");
            println!("cargo:rustc-link-lib=WinHvPlatform");
        }
        _ => {}
    }
}

/// The fingerprint Zig derives for the package name `h9sys`.
const FINGERPRINT: &str = "0x8305488abb480051";

fn zig_target(target: &str, host: &str) -> String {
    if target == host {
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
        panic!("h9sys: no Zig target for {target}");
    };
    format!("{arch}-{os}")
}

fn copy_if_changed(from: &Path, to: &Path) {
    let data = fs::read(from).unwrap();
    if fs::read(to).ok().as_deref() != Some(&data[..]) {
        fs::write(to, data).unwrap();
    }
}

fn write_if_changed(to: &Path, data: &str) {
    if fs::read_to_string(to).ok().as_deref() != Some(data) {
        fs::write(to, data).unwrap();
    }
}

#[cfg(unix)]
fn symlink_dir(from: &Path, to: &Path) {
    std::os::unix::fs::symlink(from, to).unwrap();
}

#[cfg(windows)]
fn symlink_dir(from: &Path, to: &Path) {
    std::os::windows::fs::symlink_dir(from, to).unwrap();
}
