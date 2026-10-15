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
    if left.is_empty() {
        left.push("finish it in the Macinto.sh window");
    }
    format!("incomplete ({})", left.join(", "))
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
                out.push("Turn on missing permissions from the Macinto.sh setup screen (open -a Macinto.sh), or in System Settings > Privacy & Security.".into());
            }
        }
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
        "screenshot" => out.push(format!("{} {}x{}", s(d, "path"), num(&d["width"]), num(&d["height"]))),
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
                       "version": "0.1.101", "recording": false, "displays": []});
        let t = render("status", &d);
        assert!(t.contains("remaining: ∞"));
        assert!(t.contains("accessibility: missing"));
        assert!(t.contains("screen_recording: granted"));
    }

    #[test]
    fn status_setup_state() {
        let d = json!({"state": "setup", "enabled": false,
                       "setup": {"complete": false, "accessibility": false, "screen_recording": true, "test_capture": false},
                       "permissions": {"accessibility": false, "screen_recording": true}, "version": "0.1.101"});
        let t = render("status", &d);
        assert!(t.starts_with("state: setup needed\n"), "{t}");
        assert!(t.contains("setup: incomplete (accessibility missing, test capture not done)"), "{t}");
        let done = json!({"state": "disabled", "setup": {"complete": true}});
        let t = render("status", &done);
        assert!(t.contains("state: disabled") && t.contains("setup: complete"), "{t}");
    }
}
