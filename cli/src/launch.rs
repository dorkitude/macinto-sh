//! Finding and starting Macinto.sh.app when its socket isn't answering.
//!
//! Lookup order for the app bundle:
//!   1. MACINTO_APP (a .app path; if it doesn't exist the app counts as not installed)
//!   2. the bundle this binary lives in (<bundle>/Contents/Helpers/macinto.sh), symlinks resolved,
//!      when its bundle id matches the target
//!   3. /Applications/<name>.app and ~/Applications/<name>.app
//!   4. Spotlight: mdfind kMDItemCFBundleIdentifier == <bundle id>
//!   5. LaunchServices by bundle id (`open -b`), which also covers apps Spotlight doesn't index

use crate::client::{Error, Result};
use crate::protocol::{Request, Response};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Which app to start: the release build or the dev build (`--dev`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Target {
    pub name: &'static str,
    pub bundle_id: &'static str,
    pub dev: bool,
}

pub const RELEASE: Target = Target { name: "Macinto.sh", bundle_id: "com.dorkitude.macinto.sh", dev: false };
pub const DEV: Target = Target { name: "Macinto.sh (Dev)", bundle_id: "com.dorkitude.macinto.sh.dev", dev: true };

pub const BREW_INSTALL: &str = "brew install --cask dorkitude/tap/macinto-sh";
pub const RELEASES_URL: &str = "https://github.com/dorkitude/macinto-sh/releases/latest";

/// How long to wait for the socket after launching.
pub const WAIT: Duration = Duration::from_secs(10);

impl Target {
    pub fn for_dev(dev: bool) -> Target {
        if dev {
            DEV
        } else {
            RELEASE
        }
    }

    pub fn not_installed_message(&self) -> String {
        if self.dev {
            format!("{} is not installed (no app with bundle id {}). Build it with: make dev-app", self.name, self.bundle_id)
        } else {
            format!("{} is not installed. Install it with: {BREW_INSTALL} (or download it from {RELEASES_URL})", self.name)
        }
    }
}

/// Where the app was found.
#[derive(Debug, Clone, PartialEq)]
pub enum Located {
    Path(PathBuf),
    /// Not found on disk; let LaunchServices try the bundle id.
    BundleId,
}

/// `<bundle>.app` when `exe` is `<bundle>.app/Contents/Helpers/<file>` (after resolving symlinks).
pub fn enclosing_bundle(exe: &Path) -> Option<PathBuf> {
    let exe = exe.canonicalize().ok()?;
    let helpers = exe.parent()?;
    let contents = helpers.parent()?;
    let app = contents.parent()?;
    let is_app = app.extension().is_some_and(|e| e == "app");
    (helpers.file_name()? == "Helpers" && contents.file_name()? == "Contents" && is_app).then(|| app.to_path_buf())
}

/// CFBundleIdentifier from <app>/Contents/Info.plist. Reads XML plists directly; falls back to plutil.
pub fn bundle_id(app: &Path) -> Option<String> {
    let plist = app.join("Contents/Info.plist");
    if let Ok(text) = std::fs::read_to_string(&plist) {
        if let Some(id) = xml_plist_string(&text, "CFBundleIdentifier") {
            return Some(id);
        }
    }
    let out = Command::new("/usr/bin/plutil")
        .args(["-extract", "CFBundleIdentifier", "raw", "-o", "-"])
        .arg(&plist)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let id = String::from_utf8(out.stdout).ok()?.trim().to_string();
    (out.status.success() && !id.is_empty()).then_some(id)
}

fn xml_plist_string(text: &str, key: &str) -> Option<String> {
    let after = &text[text.find(&format!("<key>{key}</key>"))? + key.len() + 11..];
    let start = after.find("<string>")? + 8;
    // Only the value right after the key.
    if !after[..start - 8].trim().is_empty() {
        return None;
    }
    let end = after[start..].find("</string>")?;
    Some(after[start..start + end].trim().to_string())
}

fn matches(app: &Path, t: &Target) -> bool {
    app.is_dir() && bundle_id(app).as_deref() == Some(t.bundle_id)
}

/// Find the app bundle for `t`. `override_path` is MACINTO_APP, `exe` this binary's path.
pub fn locate(t: &Target, override_path: Option<&Path>, exe: Option<&Path>, spotlight: bool) -> Result<Located> {
    if let Some(p) = override_path {
        return if p.is_dir() { Ok(Located::Path(p.to_path_buf())) } else { Err(Error::NotInstalled(t.not_installed_message())) };
    }
    if let Some(app) = exe.and_then(enclosing_bundle) {
        if matches(&app, t) {
            return Ok(Located::Path(app));
        }
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mut candidates = vec![PathBuf::from("/Applications").join(format!("{}.app", t.name))];
    if let Some(h) = &home {
        candidates.push(h.join("Applications").join(format!("{}.app", t.name)));
    }
    if let Some(app) = candidates.into_iter().find(|a| matches(a, t)) {
        return Ok(Located::Path(app));
    }
    if spotlight {
        if let Some(app) = mdfind(t) {
            return Ok(Located::Path(app));
        }
    }
    Ok(Located::BundleId)
}

fn mdfind(t: &Target) -> Option<PathBuf> {
    let out = Command::new("/usr/bin/mdfind")
        .arg(format!("kMDItemCFBundleIdentifier == '{}'", t.bundle_id))
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    let mut found: Vec<PathBuf> =
        text.lines().map(PathBuf::from).filter(|p| !p.starts_with("/Volumes") && matches(p, t)).collect();
    // Prefer an installed copy over one in a build folder.
    found.sort_by_key(|p| !p.starts_with("/Applications"));
    found.into_iter().next()
}

/// Launch the app (user-initiated, so it may come forward), then wait for `socket` to accept.
pub fn launch_and_wait(t: &Target, socket: &Path, override_path: Option<&Path>) -> Result<PathBuf> {
    let exe = std::env::current_exe().ok();
    let located = locate(t, override_path, exe.as_deref(), true)?;
    let mut open = Command::new("/usr/bin/open");
    let shown = match &located {
        Located::Path(p) => {
            open.arg("-a").arg(p);
            p.clone()
        }
        Located::BundleId => {
            open.arg("-b").arg(t.bundle_id);
            PathBuf::from(t.bundle_id)
        }
    };
    let out = open
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .output()
        .map_err(|e| Error::Local(format!("could not run /usr/bin/open: {e}")))?;
    if !out.status.success() {
        if located == Located::BundleId {
            return Err(Error::NotInstalled(t.not_installed_message()));
        }
        let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(Error::Local(format!("could not launch {}: {msg}", shown.display())));
    }
    eprintln!("macinto.sh: {} was not running; launched {}", t.name, shown.display());
    let deadline = Instant::now() + WAIT;
    loop {
        if answers(socket) {
            return Ok(shown);
        }
        if Instant::now() >= deadline {
            return Err(Error::LaunchTimedOut { app: t.name.to_string(), socket: socket.to_path_buf() });
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// True once the app answers a `ping` (a bare connect could succeed before the app is ready).
fn answers(socket: &Path) -> bool {
    let Ok(mut s) = UnixStream::connect(socket) else { return false };
    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(2)));
    let mut buf = Vec::new();
    s.write_all(&Request::new("ping").encode()).is_ok()
        && s.read_to_end(&mut buf).is_ok()
        && Response::decode(&buf).is_ok_and(|r| r.ok)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("macinto-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn fake_bundle(root: &Path, name: &str, id: &str) -> PathBuf {
        let app = root.join(format!("{name}.app"));
        std::fs::create_dir_all(app.join("Contents/Helpers")).unwrap();
        std::fs::write(
            app.join("Contents/Info.plist"),
            format!(
                "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict>\n\t<key>CFBundleName</key>\n\t<string>{name}</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>{id}</string>\n</dict></plist>\n"
            ),
        )
        .unwrap();
        std::fs::write(app.join("Contents/Helpers/macinto.sh"), b"").unwrap();
        app
    }

    #[test]
    fn reads_bundle_id_from_xml_plist() {
        let root = temp("plist");
        let app = fake_bundle(&root, "Macinto.sh", "com.dorkitude.macinto.sh");
        assert_eq!(bundle_id(&app).as_deref(), Some("com.dorkitude.macinto.sh"));
        assert_eq!(xml_plist_string("<key>A</key><string>x</string><key>B</key>", "B"), None);
    }

    #[test]
    fn finds_enclosing_bundle_through_symlink() {
        let root = temp("enclosing");
        let app = fake_bundle(&root, "Macinto.sh", "com.dorkitude.macinto.sh");
        let link = root.join("bin-macinto.sh");
        std::os::unix::fs::symlink(app.join("Contents/Helpers/macinto.sh"), &link).unwrap();
        assert_eq!(enclosing_bundle(&link), Some(app.canonicalize().unwrap()));
        // Not inside a bundle.
        assert_eq!(enclosing_bundle(&root.join("bin-macinto.sh").with_file_name("nope")), None);
        let loose = root.join("loose");
        std::fs::write(&loose, b"").unwrap();
        assert_eq!(enclosing_bundle(&loose), None);
    }

    #[test]
    fn prefers_own_bundle_when_id_matches() {
        let root = temp("own");
        let app = fake_bundle(&root, "Macinto.sh (Dev)", DEV.bundle_id);
        let exe = app.join("Contents/Helpers/macinto.sh");
        assert_eq!(locate(&DEV, None, Some(&exe), false).unwrap(), Located::Path(app.canonicalize().unwrap()));
        // The release target doesn't launch the dev bundle it happens to live in.
        if let Ok(Located::Path(p)) = locate(&RELEASE, None, Some(&exe), false) {
            assert_ne!(p, app.canonicalize().unwrap());
        }
    }

    #[test]
    fn missing_override_is_not_installed() {
        let e = locate(&RELEASE, Some(Path::new("/nonexistent/Macinto.sh.app")), None, false).unwrap_err();
        assert_eq!(e.code(), "not_installed");
        assert_eq!(e.exit_code(), 1);
        let m = e.message();
        assert!(m.contains(BREW_INSTALL), "{m}");
        assert!(m.contains(RELEASES_URL), "{m}");
        let dev = locate(&DEV, Some(Path::new("/nonexistent/x.app")), None, false).unwrap_err();
        assert!(dev.message().contains("make dev-app"));
    }

    #[test]
    fn existing_override_is_used() {
        let root = temp("override");
        let app = fake_bundle(&root, "Whatever", "x.y");
        assert_eq!(locate(&RELEASE, Some(&app), None, false).unwrap(), Located::Path(app));
    }
}
