//! Moving captures out of the app's private captures folder to where the user asked.

use crate::client::{Error, Result};
use std::path::{Path, PathBuf};

/// `./macinto-YYYYmmdd-HHMMSS.<ext>` in local time.
pub fn default_name(ext: &str) -> PathBuf {
    PathBuf::from(format!("macinto-{}.{ext}", local_stamp()))
}

fn local_stamp() -> String {
    // libc localtime_r without a libc crate dependency.
    #[repr(C)]
    struct Tm {
        sec: i32,
        min: i32,
        hour: i32,
        mday: i32,
        mon: i32,
        year: i32,
        wday: i32,
        yday: i32,
        isdst: i32,
        gmtoff: i64,
        zone: *const i8,
    }
    extern "C" {
        fn time(t: *mut i64) -> i64;
        fn localtime_r(t: *const i64, out: *mut Tm) -> *mut Tm;
    }
    let mut tm = Tm { sec: 0, min: 0, hour: 0, mday: 0, mon: 0, year: 0, wday: 0, yday: 0, isdst: 0, gmtoff: 0, zone: std::ptr::null() };
    // SAFETY: both calls only write into the locals passed by pointer.
    unsafe {
        let now = time(std::ptr::null_mut());
        localtime_r(&now, &mut tm);
    }
    format!("{:04}{:02}{:02}-{:02}{:02}{:02}", tm.year + 1900, tm.mon + 1, tm.mday, tm.hour, tm.min, tm.sec)
}

/// Absolute destination, checked before capturing: the directory exists and the file does not
/// (unless `force`).
pub fn prepare_dest(out: Option<&Path>, ext: &str, force: bool) -> Result<PathBuf> {
    let p = out.map(Path::to_path_buf).unwrap_or_else(|| default_name(ext));
    let abs = if p.is_absolute() {
        p
    } else {
        std::env::current_dir().map_err(|e| Error::Local(format!("no current directory: {e}")))?.join(p)
    };
    let dir = abs.parent().unwrap_or(Path::new("/"));
    if !dir.is_dir() {
        return Err(Error::Local(format!("directory does not exist: {}", dir.display())));
    }
    if abs.is_dir() {
        return Err(Error::Local(format!("{} is a directory", abs.display())));
    }
    if !force && abs.symlink_metadata().is_ok() {
        return Err(Error::Local(format!("{} already exists (use --force to overwrite)", abs.display())));
    }
    Ok(abs)
}

/// Move `src` to `dest`. Without `force`, never replaces an existing file.
pub fn deliver(src: &Path, dest: &Path, force: bool) -> Result<()> {
    if !src.is_file() {
        return Err(Error::Local(format!("Macinto.sh did not leave a file at {}", src.display())));
    }
    let left = |what: String| Error::Local(format!("{what}; capture left at {}", src.display()));
    if force {
        if std::fs::rename(src, dest).is_ok() {
            return Ok(());
        }
        std::fs::copy(src, dest).map_err(|e| left(format!("could not write {}: {e}", dest.display())))?;
    } else {
        // hard_link fails if dest exists, so this can't clobber a file that appeared meanwhile.
        match std::fs::hard_link(src, dest) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                return Err(left(format!("{} already exists", dest.display())));
            }
            Err(_) => {
                // Different volume: copy into a new file.
                use std::io::Write;
                let mut f = std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(dest)
                    .map_err(|e| left(format!("could not create {}: {e}", dest.display())))?;
                let bytes = std::fs::read(src).map_err(|e| left(format!("could not read capture: {e}")))?;
                f.write_all(&bytes).map_err(|e| left(format!("could not write {}: {e}", dest.display())))?;
            }
        }
    }
    let _ = std::fs::remove_file(src);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("macinto-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn default_name_shape() {
        let n = default_name("png").to_string_lossy().to_string();
        assert!(n.starts_with("macinto-") && n.ends_with(".png"), "{n}");
        assert_eq!(n.len(), "macinto-20261014-201500.png".len());
    }

    #[test]
    fn refuses_existing_without_force() {
        let d = tmpdir("exists");
        let f = d.join("a.png");
        std::fs::write(&f, b"x").unwrap();
        assert!(prepare_dest(Some(&f), "png", false).is_err());
        assert!(prepare_dest(Some(&f), "png", true).is_ok());
        assert!(prepare_dest(Some(&d.join("nope/a.png")), "png", false).is_err());
    }

    #[test]
    fn deliver_moves_and_never_clobbers() {
        let d = tmpdir("deliver");
        let src = d.join("src.png");
        let dest = d.join("dest.png");
        std::fs::write(&src, b"one").unwrap();
        deliver(&src, &dest, false).unwrap();
        assert!(!src.exists());
        assert_eq!(std::fs::read(&dest).unwrap(), b"one");

        std::fs::write(&src, b"two").unwrap();
        assert!(deliver(&src, &dest, false).is_err());
        assert!(src.exists(), "capture is kept when refusing");
        deliver(&src, &dest, true).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"two");
    }
}
