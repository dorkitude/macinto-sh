// Version comes from the repo's VERSION file so the app and the CLI always agree.
fn main() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../VERSION");
    println!("cargo:rerun-if-changed={path}");
    let v = std::fs::read_to_string(path).unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rustc-env=MACINTO_VERSION={}", v.trim());
}
