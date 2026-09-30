//! Embeds the Windows icon and version resource into `remotecrab.exe`.
//!
//! Without this the binary is anonymous: Explorer shows a blank page, the
//! taskbar entry is an empty square, and `remotecrab --version` is the only
//! place a build can identify itself. For a program that injects input into
//! every process on the machine, "which build is this" is not a nicety — a
//! user reporting a bug has to be able to answer it from Explorer's
//! Properties dialog without running anything.
//!
//! The version string is taken from `CARGO_PKG_VERSION` rather than written
//! out here, so there is exactly one place a release number lives.
//!
//! This runs on the **host**, so it is gated on the *target* OS: cross-building
//! from a Mac to Windows must still produce the resource, and building the
//! same crate for macOS must not need the Windows tools at all.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }

    // `build.rs` runs with its working directory set to the crate root, so a
    // bare relative path would look in `crates/rc-app/assets/`. The icon lives
    // with the rest of the Windows artwork, and a *missing* icon is a release
    // defect rather than something to warn about and ship.
    let manifest = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let icon = std::path::Path::new(&manifest).join("../../assets/remotecrab.ico");
    println!("cargo:rerun-if-changed={}", icon.display());
    if !icon.exists() {
        panic!(
            "missing {}\nRun scripts/generate-windows-icon.py to build it.",
            icon.display()
        );
    }

    let version = std::env::var("CARGO_PKG_VERSION").expect("CARGO_PKG_VERSION");
    // `FileVersion` is a 4×16-bit integer: major.minor.build.patch. A
    // semver with a pre-release (`1.0.0-rc1`) has to be squeezed in or the
    // resource silently becomes 1.0.0 — two different builds claiming the
    // same version is the exact bug this file exists to prevent.
    let (file_version, product_version) = numeric_version(&version);

    let mut res = winres::WindowsResource::new();
    res.set_icon(icon.to_str().expect("icon path is not UTF-8"));
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("gnu") {
        // `winres` defaults to a *bare* `windres` / `ar`, which a MinGW-w64
        // install does not put on PATH — Homebrew ships only the
        // target-prefixed ones. So a GNU build from a Mac or a Linux CI box
        // finds no resource compiler and produces an icon-less, version-less
        // binary. Point it at the prefixed tools, falling back to the bare
        // names for a setup that does have them.
        let triple = std::env::var("TARGET").unwrap_or_default();
        res.set_windres_path(&tool("windres", &triple));
        res.set_ar_path(&tool("ar", &triple));
    }
    res.set("FileDescription", "RemoteCrab — iPhone as camera, mic, trackpad and keyboard");
    res.set("ProductName", "RemoteCrab");
    res.set("CompanyName", "Beijing VGO Co.,Ltd");
    res.set("Copyright", "Copyright (c) Beijing VGO Co.,Ltd");
    res.set("FileVersion", &file_version);
    res.set("ProductVersion", &product_version);
    // No `InternalName`: it is meant to be the original filename, and
    // Explorer shows it in some column layouts, where a crate name reads as a
    // packaging accident.
    if let Err(e) = res.compile() {
        // A missing icon must not fail the build on a machine that cannot
        // produce one, but it must be loud: a silently icon-less release is
        // exactly what this file is here to prevent.
        println!("cargo:warning=remotecrab: could not embed the Windows resource: {e}");
        return;
    }

    // `winres` finishes by archiving `resource.o` into `libresource.a` and
    // asking for `-l static=resource`. That does not work: a member of a
    // static archive is only pulled in when it resolves an undefined symbol,
    // and `resource.o` defines none — it contributes sections and nothing
    // else. The link therefore succeeds, silently, and ships a binary with no
    // icon and no version.
    //
    // Passing the object file itself forces it in. (Verified by looking for a
    // `.rsrc` section in the built .exe, because nothing warns about this.)
    let out = std::env::var("OUT_DIR").expect("OUT_DIR");
    let obj = std::path::Path::new(&out).join("resource.o");
    if !obj.exists() {
        panic!(
            "winres reported success but {} is missing — the .exe would ship \
             without an icon or a version",
            obj.display()
        );
    }
    println!("cargo:rustc-link-arg={}", obj.display());
}

/// The MinGW-w64 tool prefix for a Rust target.
///
/// A Rust triple (`x86_64-pc-windows-gnu`) is **not** a MinGW prefix
/// (`x86_64-w64-mingw32`), and building the name from the triple — which is
/// the obvious thing to do — produces `x86_64-pc-windows-gnu-windres`, which
/// exists nowhere. The two naming schemes genuinely differ, so the mapping is
/// spelled out rather than derived.
fn mingw_prefix(triple: &str) -> Option<String> {
    let arch = triple.split('-').next()?;
    let name = match arch {
        "i686" | "i586" => "i686",
        "x86_64" => "x86_64",
        "aarch64" => "aarch64",
        _ => return None,
    };
    Some(format!("{name}-w64-mingw32"))
}

/// `x86_64-w64-mingw32-windres` if it exists, else plain `windres`.
///
/// Tried in order: the correct MinGW prefix, then the raw triple (some setups
/// symlink it that way), then the bare name. Checked rather than assumed — a
/// hardcoded path breaks every machine that does not have that exact layout.
fn tool(name: &str, triple: &str) -> String {
    let mut candidates: Vec<String> = Vec::new();
    if let Some(prefix) = mingw_prefix(triple) {
        candidates.push(format!("{prefix}-{name}"));
    }
    if !triple.is_empty() {
        candidates.push(format!("{triple}-{name}"));
    }
    candidates.push(name.to_string());
    candidates
        .into_iter()
        .find(|c| which(c))
        .unwrap_or_else(|| name.to_string())
}

/// The smallest `which` that does not need a dependency: ask `PATH` directly.
fn which(exe: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|dir| {
        let candidate = if cfg!(windows) {
            dir.join(format!("{exe}.exe"))
        } else {
            dir.join(exe)
        };
        candidate.is_file()
    })
}

/// `"1.2.3-rc1"` → `("1.2.3.0", "1.2.3")` for `FileVersion` / `ProductVersion`.
///
/// `FileVersion` is fixed-width and numeric, so a pre-release suffix cannot go
/// in it; the suffix is dropped rather than rounded, and a build that is not
/// 1.0.0 never claims to be 1.0.0.
fn numeric_version(version: &str) -> (String, String) {
    let core = version.split(['-', '+']).next().unwrap_or(version);
    let mut parts = core.split('.').map(|p| p.parse::<u64>().unwrap_or(0));
    let major = parts.next().unwrap_or(0);
    let minor = parts.next().unwrap_or(0);
    let patch = parts.next().unwrap_or(0);
    let build = parts.next().unwrap_or(0);
    (format!("{major}.{minor}.{patch}.{build}"), format!("{major}.{minor}.{patch}"))
}

#[cfg(test)]
mod tests {
    use super::numeric_version;

    #[test]
    fn plain_semver_gets_a_zero_build_component() {
        assert_eq!(
            numeric_version("1.0.0"),
            ("1.0.0.0".to_string(), "1.0.0".to_string())
        );
    }

    #[test]
    fn a_prerelease_never_rounds_up_to_the_release() {
        // The failure this prevents: two different binaries both reporting
        // "1.0.0" in Properties, one of which is a release candidate.
        assert_eq!(
            numeric_version("1.0.0-rc.1"),
            ("1.0.0.0".to_string(), "1.0.0".to_string())
        );
    }

    #[test]
    fn a_four_component_version_passes_through() {
        assert_eq!(
            numeric_version("1.2.3.4"),
            ("1.2.3.4".to_string(), "1.2.3".to_string())
        );
    }

    /// A build that understands more components than the resource has must not
    /// silently drop the ones that matter.
    #[test]
    fn junk_becomes_zero_rather_than_panicking() {
        assert_eq!(
            numeric_version("not-a-version"),
            ("0.0.0.0".to_string(), "0.0.0".to_string())
        );
    }
}
