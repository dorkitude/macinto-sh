//! Human-readable rendering of response data. `--json` bypasses all of this.

use serde_json::Value;

pub fn num(v: &Value) -> String {
    match v.as_f64() {
        Some(f) if f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", f as i64),
        Some(f) => format!("{:.1}", f),
        None => "-".into(),
    }
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}

fn granted(v: &Value) -> &'static str {
    if v.as_bool() == Some(true) {
        "granted"
    } else {
        "missing"
    }
}

fn clip(text: &str, n: usize) -> String {
    let flat: String = text.chars().map(|c| if c == '\n' { '⏎' } else if c == '"' { '\'' } else { c }).collect();
    if flat.chars().count() > n {
        flat.chars().take(n).collect::<String>() + "…"
    } else {
        flat
    }
}

/// Screenshot pixels per point, as text ("1", "2", "0.53"). Older apps only send pixels_per_point.
pub fn scale(d: &Value) -> Option<String> {
    let f = d["scale"].as_f64().or_else(|| d["pixels_per_point"].as_f64())?;
    let t = format!("{f:.2}");
    Some(t.trim_end_matches('0').trim_end_matches('.').to_string())
}

fn rect(f: &Value) -> String {
    format!("{},{} {}x{}", num(&f["x"]), num(&f["y"]), num(&f["width"]), num(&f["height"]))
}

pub fn display_line(d: &Value) -> String {
    format!(
        "display {}: origin {},{} size {}x{} scale {}{}",
        num(&d["index"]),
        num(&d["x"]),
        num(&d["y"]),
        num(&d["width"]),
        num(&d["height"]),
        num(&d["scale"]),
        if d["main"].as_bool() == Some(true) { " (main)" } else { "" }
    )
}

fn app_line(a: &Value) -> String {
    format!("{}\t{}\t{}", num(&a["pid"]), a["bundle_id"].as_str().unwrap_or("-"), a["name"].as_str().unwrap_or("?"))
}

/// One element of a `ui` dump: `  0.1 AXButton/AXCloseButton "title" @318,129 14x16 focused`.
pub fn element_line(e: &Value, indent: bool) -> String {
    let depth = if indent { e["depth"].as_u64().unwrap_or(0) as usize } else { 0 };
    let mut parts = vec![format!("{}{}", "  ".repeat(depth), s(e, "id"))];
    let mut role = s(e, "role").to_string();
    if let Some(sub) = e["subrole"].as_str() {
        role = format!("{role}/{sub}");
    }
    parts.push(role);
    if let Some(t) = e["title"].as_str() {
        parts.push(format!("\"{}\"", clip(t, 60)));
    }
    if let Some(t) = e["description"].as_str() {
        parts.push(format!("desc=\"{}\"", clip(t, 60)));
    }
    if let Some(t) = e["value"].as_str() {
        parts.push(format!("value=\"{}\"", clip(t, 60)));
    }
    if let Some(t) = e["help"].as_str() {
        parts.push(format!("help=\"{}\"", clip(t, 40)));
    }
    if e["frame"].is_object() {
        parts.push(format!("@{}", rect(&e["frame"])));
    }
    if e["enabled"].as_bool() == Some(false) {
        parts.push("disabled".into());
    }
    if e["focused"].as_bool() == Some(true) {
        parts.push("focused".into());
    }
    parts.join(" ")
}

/// `complete`, or what's left: `incomplete (accessibility missing, test capture not done)`.
fn setup_line(setup: &Value) -> String {
    if setup["complete"].as_bool() == Some(true) {
        return "complete".into();
    }
    let mut left = setup_left(setup);
    if left.is_empty() {
        left.push("finish it in the Macinto.sh window");
    }
    format!("incomplete ({})", left.join(", "))
}

/// Setup steps still missing, from the `setup` object.
fn setup_left(setup: &Value) -> Vec<&'static str> {
    let mut left = Vec::new();
    if setup["accessibility"].as_bool() == Some(false) {
        left.push("accessibility missing");
    }
    if setup["screen_recording"].as_bool() == Some(false) {
        left.push("screen recording missing");
    }
    if setup["test_capture"].as_bool() == Some(false) {
        left.push("test capture not done");
    }
    left
}

/// One line for `setup`: the window is open, and what the person still has to do in it.
fn setup_result(d: &Value) -> String {
    let name = d["name"].as_str().filter(|n| !n.is_empty()).unwrap_or("Macinto.sh");
    let started = if d["launched"].as_bool() == Some(true) { " (started it)" } else { "" };
    let next = match d["state"].as_str() {
        Some("setup") => {
            let left = setup_left(&d["setup"]);
            let left = if left.is_empty() { String::new() } else { format!(" ({})", left.join(", ")) };
            format!("Finish setup in its window{left}, then enable it.")
        }
        Some("enabled") => {
            let left = if d["remaining_seconds"].is_null() { "until turned off".to_string() } else { format!("{} s left", num(&d["remaining_seconds"])) };
            format!("It is enabled ({left}).")
        }
        Some("disabled") => "Enable it in its window.".into(),
        _ => "Finish setup / enable it in its window.".into(),
    };
    format!("{name} is open{started}. {next}")
}

/// Text for a successful result. Empty string means print nothing.
pub fn render(kind: &str, d: &Value) -> String {
    let mut out: Vec<String> = Vec::new();
    match kind {
        "status" => {
            let remaining = if d["enabled"].as_bool() != Some(true) {
                "-".to_string()
            } else if d["unlimited"].as_bool() == Some(true) {
                "∞".to_string()
            } else {
                num(&d["remaining_seconds"])
            };
            if let Some(state) = d["state"].as_str() {
                out.push(format!("state: {}", if state == "setup" { "setup needed" } else { state }));
            }
            out.push(format!("enabled: {}", if d["enabled"].as_bool() == Some(true) { "yes" } else { "no" }));
            out.push(format!("remaining: {remaining}"));
            out.push(format!("accessibility: {}", granted(&d["permissions"]["accessibility"])));
            out.push(format!("screen_recording: {}", granted(&d["permissions"]["screen_recording"])));
            if d["setup"].is_object() {
                out.push(format!("setup: {}", setup_line(&d["setup"])));
            }
            out.push(format!("version: {}", s(d, "version")));
            out.push(format!("recording: {}", if d["recording"].as_bool() == Some(true) { "yes" } else { "no" }));
            if let Some(si) = d["status_item"].as_str() {
                out.push(format!("status_item: {si}"));
            }
            if d["overlay"].is_object() {
                let o = &d["overlay"];
                if o["visible"].as_bool() == Some(true) && o["frame"].is_object() {
                    out.push(format!("overlay: visible at {}", rect(&o["frame"])));
                } else {
                    out.push("overlay: hidden".into());
                }
            }
            for disp in d["displays"].as_array().into_iter().flatten() {
                out.push(display_line(disp));
            }
        }
        "permissions" => {
            out.push(format!("accessibility: {}", granted(&d["accessibility"])));
            out.push(format!("screen_recording: {}", granted(&d["screen_recording"])));
            if d["accessibility"].as_bool() != Some(true) || d["screen_recording"].as_bool() != Some(true) {
                out.push("Turn on missing permissions from the Macinto.sh setup screen (run: macinto.sh setup), or in System Settings > Privacy & Security.".into());
            }
        }
        "setup" | "show_window" => out.push(setup_result(d)),
        "displays" => {
            for disp in d["displays"].as_array().into_iter().flatten() {
                out.push(display_line(disp));
            }
        }
        "click" => out.push(format!("clicked {},{}", num(&d["x"]), num(&d["y"]))),
        "type" => out.push(format!("typed {} characters", num(&d["characters"]))),
        "location" => out.push(format!("{} {}", num(&d["x"]), num(&d["y"]))),
        "keys" => {
            for k in d["keys"].as_array().into_iter().flatten() {
                out.push(k.as_str().unwrap_or("").to_string());
            }
        }
        "open" => out.push(app_line(d)),
        "apps" => {
            for a in d["apps"].as_array().into_iter().flatten() {
                let mark = if a["frontmost"].as_bool() == Some(true) { "*" } else { " " };
                out.push(format!("{mark} {}", app_line(a)));
            }
        }
        "ui" => {
            if let Some(note) = d["note"].as_str() {
                out.push(format!("note: {note}"));
            }
            let a = &d["app"];
            out.push(format!(
                "app: {} ({}, pid {})",
                a["name"].as_str().unwrap_or("?"),
                a["bundle_id"].as_str().unwrap_or("-"),
                num(&a["pid"])
            ));
            for e in d["elements"].as_array().into_iter().flatten() {
                out.push(element_line(e, true));
            }
            if d["truncated"].as_bool() == Some(true) {
                out.push(format!("(truncated at {} elements; use --depth to limit)", num(&d["max_elements"])));
            }
        }
        "press" | "focus" | "set_value" => out.push(element_line(&d["element"], false)),
        "screenshot" => {
            let mut line = format!("{} {}x{}", s(d, "path"), num(&d["width"]), num(&d["height"]));
            if d["origin"].is_object() {
                line.push_str(&format!(" origin {},{}", num(&d["origin"]["x"]), num(&d["origin"]["y"])));
            }
            if let Some(scale) = scale(d) {
                line.push_str(&format!(" scale {scale}"));
            }
            out.push(line);
        }
        "record_start" => {
            let dest = s(d, "dest");
            let target = if dest.is_empty() { s(d, "path") } else { dest };
            out.push(format!("recording to {target} (stop with: macinto.sh record stop)"));
        }
        "record_stop" => out.push(format!("{} ({}s)", s(d, "path"), num(&d["duration"]))),
        "record_status" => {
            out.push(format!("recording: {}", if d["recording"].as_bool() == Some(true) { "yes" } else { "no" }));
            if d["recording"].as_bool() == Some(true) {
                out.push(format!("elapsed: {}", num(&d["elapsed"])));
                out.push(format!("path: {}", s(d, "path")));
                out.push(format!("dest: {}", s(d, "dest")));
            } else if d["last"].is_object() {
                out.push(format!("last: {}", s(&d["last"], "path")));
                out.push(format!("last_dest: {}", s(&d["last"], "dest")));
            }
        }
        // move, drag, scroll, key, wait: silent on success, like cp(1).
        _ => {}
    }
    out.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn numbers() {
        assert_eq!(num(&json!(12)), "12");
        assert_eq!(num(&json!(12.0)), "12");
        assert_eq!(num(&json!(1.26)), "1.3");
        assert_eq!(num(&Value::Null), "-");
    }

    #[test]
    fn element() {
        let e = json!({"id": "0.1", "depth": 1, "role": "AXButton", "subrole": "AXCloseButton",
                       "title": null, "frame": {"x": 318, "y": 129, "width": 14, "height": 16},
                       "enabled": true, "focused": false});
        assert_eq!(element_line(&e, true), "  0.1 AXButton/AXCloseButton @318,129 14x16");
    }

    #[test]
    fn status_infinite() {
        let d = json!({"enabled": true, "unlimited": true, "remaining_seconds": null,
                       "permissions": {"accessibility": false, "screen_recording": true},
                       "version": "0.1.103", "recording": false, "displays": []});
        let t = render("status", &d);
        assert!(t.contains("remaining: ∞"));
        assert!(t.contains("accessibility: missing"));
        assert!(t.contains("screen_recording: granted"));
    }

    #[test]
    fn setup_lines() {
        let d = json!({"shown": true, "name": "Macinto.sh", "state": "setup", "launched": true,
                       "setup": {"complete": false, "accessibility": false, "screen_recording": true, "test_capture": false}});
        assert_eq!(
            render("setup", &d),
            "Macinto.sh is open (started it). Finish setup in its window (accessibility missing, test capture not done), then enable it."
        );
        let d = json!({"name": "Macinto.sh (Dev)", "state": "disabled", "launched": false, "setup": {"complete": true}});
        assert_eq!(render("setup", &d), "Macinto.sh (Dev) is open. Enable it in its window.");
        let d = json!({"name": "Macinto.sh", "state": "enabled", "remaining_seconds": 90});
        assert_eq!(render("setup", &d), "Macinto.sh is open. It is enabled (90 s left).");
        let d = json!({"name": "Macinto.sh", "state": "enabled", "remaining_seconds": null});
        assert_eq!(render("setup", &d), "Macinto.sh is open. It is enabled (until turned off).");
        assert_eq!(render("setup", &json!({})), "Macinto.sh is open. Finish setup / enable it in its window.");
    }

    #[test]
    fn permissions_hint_names_setup_command() {
        let t = render("permissions", &json!({"accessibility": false, "screen_recording": true}));
        assert!(t.contains("macinto.sh setup"), "{t}");
    }

    #[test]
    fn status_setup_state() {
        let d = json!({"state": "setup", "enabled": false,
                       "setup": {"complete": false, "accessibility": false, "screen_recording": true, "test_capture": false},
                       "permissions": {"accessibility": false, "screen_recording": true}, "version": "0.1.103"});
        let t = render("status", &d);
        assert!(t.starts_with("state: setup needed\n"), "{t}");
        assert!(t.contains("setup: incomplete (accessibility missing, test capture not done)"), "{t}");
        let done = json!({"state": "disabled", "setup": {"complete": true}});
        let t = render("status", &done);
        assert!(t.contains("state: disabled") && t.contains("setup: complete"), "{t}");
    }

    #[test]
    fn ui_without_windows_prints_note_first() {
        let d = json!({"app": {"name": "TextEdit", "bundle_id": "com.apple.TextEdit", "pid": 42},
                       "windows": 0, "note": "TextEdit has no open windows; showing the app and its menu bar",
                       "elements": [{"id": "0", "depth": 0, "role": "AXApplication", "title": "TextEdit"},
                                    {"id": "0.0", "depth": 1, "role": "AXMenuBar"}],
                       "truncated": false});
        let t = render("ui", &d);
        let lines: Vec<&str> = t.lines().collect();
        assert_eq!(lines[0], "note: TextEdit has no open windows; showing the app and its menu bar");
        assert_eq!(lines[1], "app: TextEdit (com.apple.TextEdit, pid 42)");
        assert_eq!(lines[2], "0 AXApplication \"TextEdit\"");
        assert_eq!(lines[3], "  0.0 AXMenuBar");
        let with_window = json!({"app": {"name": "TextEdit", "pid": 42}, "windows": 1, "elements": []});
        assert!(!render("ui", &with_window).contains("note:"));
    }

    #[test]
    fn screenshot_line_has_origin_and_scale() {
        let d = json!({"path": "/tmp/a.png", "width": 416, "height": 316, "origin": {"x": 92, "y": 192},
                       "scale": 1, "pixels_per_point": 1, "display": 0, "cropped": true, "app": "TextEdit"});
        assert_eq!(render("screenshot", &d), "/tmp/a.png 416x316 origin 92,192 scale 1");
        let d = json!({"path": "/tmp/b.png", "width": 800, "height": 520, "origin": {"x": -1920, "y": 0}, "scale": 0.5208333});
        assert_eq!(render("screenshot", &d), "/tmp/b.png 800x520 origin -1920,0 scale 0.52");
        // An app older than 0.1.103 sends pixels_per_point only.
        let d = json!({"path": "/tmp/c.png", "width": 3024, "height": 1964, "origin": {"x": 0, "y": 0}, "pixels_per_point": 2.0});
        assert_eq!(render("screenshot", &d), "/tmp/c.png 3024x1964 origin 0,0 scale 2");
        assert_eq!(render("screenshot", &json!({"path": "/tmp/d.png", "width": 1, "height": 1})), "/tmp/d.png 1x1");
    }
}
