//! `macinto.sh mcp`: a Model Context Protocol server on stdin/stdout (newline-delimited JSON-RPC 2.0).
//!
//! Hand-rolled on purpose: the server needs initialize, ping, tools/list and tools/call, which is a
//! few hundred lines and avoids pulling an async runtime into a small CLI. Every tool call goes
//! through the same `actions::execute` as the CLI, so the app's enabled gate, permission checks and
//! request log apply unchanged. There is no tool (and no socket command) that enables Macinto.sh.

use crate::actions::{self, Action};
use crate::client::{Client, Error, Result};
use crate::files;
use crate::output;
use crate::protocol::Request;
use serde_json::{json, Map, Value};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

/// Protocol versions this server speaks, newest first.
pub const PROTOCOL_VERSIONS: &[&str] = &["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS: &str = "\
Macinto.sh drives this Mac (mouse, keyboard, accessibility tree, screenshots) through the \
Macinto.sh menu bar app, which is started automatically if it isn't running. A person must finish \
setup (permissions) and enable it in the app's window; until then every tool except status and keys \
fails with a 'setup' or 'disabled' error, and no tool can enable it. Coordinates are \
global points with the origin at the top-left of the main display. A typical loop: screenshot or ui \
to observe, then click/type/key/press to act, then observe again.";

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Ty {
    Number,
    Integer,
    String,
    Boolean,
    StringArray,
}

#[derive(Debug)]
pub struct Param {
    pub name: &'static str,
    pub ty: Ty,
    pub required: bool,
    pub desc: &'static str,
    pub choices: &'static [&'static str],
}

const fn p(name: &'static str, ty: Ty, required: bool, desc: &'static str) -> Param {
    Param { name, ty, required, desc, choices: &[] }
}

#[derive(Debug)]
pub struct Tool {
    pub name: &'static str,
    pub title: &'static str,
    pub desc: &'static str,
    pub params: Vec<Param>,
    pub read_only: bool,
}

const APP_PARAM: &str = "Target app: name (\"Safari\"), bundle id or pid. Default: the frontmost app.";

pub fn tools() -> Vec<Tool> {
    use Ty::*;
    let t = |name, title, desc, params, read_only| Tool { name, title, desc, params, read_only };
    vec![
        t("status", "Status",
          "Whether Macinto.sh is enabled and for how long, which permissions it has (accessibility, screen_recording), \
           and the displays (index, origin and size in global points, scale). Works while disabled.",
          vec![], true),
        t("click", "Click",
          "Click at a point. Coordinates are global points, origin at the top-left of the main display; \
           for display 0 these equal pixel coordinates in a default screenshot. Needs Accessibility.",
          vec![p("x", Number, true, "X in global points"), p("y", Number, true, "Y in global points"),
               Param { name: "button", ty: String, required: false, desc: "Mouse button (default left)", choices: &["left", "right"] },
               p("count", Integer, false, "1 = single click (default), 2 = double click, 3 = triple click")], false),
        t("move", "Move pointer", "Move the mouse pointer to a point (global points, top-left origin). Needs Accessibility.",
          vec![p("x", Number, true, "X in global points"), p("y", Number, true, "Y in global points")], false),
        t("drag", "Drag", "Left-button drag from (x1, y1) to (x2, y2) in global points. Needs Accessibility.",
          vec![p("x1", Number, true, "Start X"), p("y1", Number, true, "Start Y"),
               p("x2", Number, true, "End X"), p("y2", Number, true, "End Y")], false),
        t("scroll", "Scroll", "Scroll at the current pointer position by lines. Move the pointer over the target first. Needs Accessibility.",
          vec![p("dx", Integer, false, "Horizontal lines"), p("dy", Integer, false, "Vertical lines; positive scrolls up, negative scrolls down")], false),
        t("type", "Type text",
          "Type Unicode text into whatever has keyboard focus. Newlines press Return, tabs press Tab. \
           The text is written (truncated) to the request log, so don't type secrets. Needs Accessibility.",
          vec![p("text", String, true, "Text to type")], false),
        t("key", "Press keys",
          "Press key combos in order, e.g. [\"cmd+shift+g\"], [\"return\"], [\"cmd+a\", \"delete\"]. Modifiers: cmd, shift, opt, ctrl, fn. \
           See the keys tool for key names. Needs Accessibility.",
          vec![p("combos", StringArray, true, "Combos to press, in order")], false),
        t("keys", "Key names", "List key names accepted by the key tool. Works while disabled.", vec![], true),
        t("open", "Open app", "Activate an app by name, bundle id or .app path, launching it if needed.",
          vec![p("app", String, true, "App name, bundle id or path")], false),
        t("apps", "Running apps", "List running regular apps with pid, bundle id, name and which one is frontmost.", vec![], true),
        t("location", "Pointer location", "Current mouse position in global points.", vec![], true),
        t("ui", "UI tree",
          "Dump the accessibility tree of an app's focused window: one element per entry with an id, role, title, \
           value and frame in global points. Ids are index paths like 0.3.1, re-resolved on every call, so call ui \
           again after the UI changes. Use the ids with press, focus and set_value. Needs Accessibility.",
          vec![p("app", String, false, APP_PARAM), p("depth", Integer, false, "Maximum depth below the window (default 12)")], true),
        t("press", "Press element", "Perform AXPress (like a click) on an element id from ui. Needs Accessibility.",
          vec![p("id", String, true, "Element id from ui, like 0.3.1"), p("app", String, false, APP_PARAM)], false),
        t("focus", "Focus element", "Give keyboard focus to an element id from ui. Needs Accessibility.",
          vec![p("id", String, true, "Element id from ui"), p("app", String, false, APP_PARAM)], false),
        t("set_value", "Set element value", "Set the value of an element id from ui, e.g. a text field. Needs Accessibility.",
          vec![p("id", String, true, "Element id from ui"), p("value", String, true, "New value"), p("app", String, false, APP_PARAM)], false),
        t("screenshot", "Screenshot",
          "Capture a display as PNG and return it inline. By default the image is scaled to points, so a pixel (x, y) \
           in a screenshot of display 0 is clicked at (x, y); for other displays add the display origin. With max_width \
           or native the scale changes: divide pixel coordinates by pixels_per_point (in the result) first. \
           The file stays in Macinto.sh's captures folder unless path is given. Needs Screen Recording.",
          vec![p("display", Integer, false, "Display index from status (default 0, the main display)"),
               p("app", String, false, "Capture only this app's windows"),
               p("max_width", Integer, false, "Scale the image down to at most this many pixels wide (keeps aspect ratio)"),
               p("native", Boolean, false, "Full Retina resolution instead of points"),
               p("path", String, false, "Absolute .png path to save the file to"),
               p("force", Boolean, false, "Overwrite path if it exists")], true),
        t("record_start", "Start recording",
          "Start a screen recording (.mov) of a display. Stop it with record_stop. Needs Screen Recording.",
          vec![p("display", Integer, false, "Display index (default 0)"),
               p("path", String, false, "Absolute .mov path to move the recording to when it stops"),
               p("force", Boolean, false, "Overwrite path if it exists")], false),
        t("record_stop", "Stop recording", "Stop the recording and return the file path.", vec![], false),
        t("record_status", "Recording status", "Whether a recording is running, and the last recording's path.", vec![], true),
        t("wait", "Wait", "Sleep for some seconds (0 to 3600) without touching the Mac, e.g. after opening an app.",
          vec![p("seconds", Number, true, "Seconds, fractions allowed")], true),
    ]
}

pub fn schema(tool: &Tool) -> Value {
    let mut props = Map::new();
    for prm in &tool.params {
        let mut s = match prm.ty {
            Ty::Number => json!({"type": "number"}),
            Ty::Integer => json!({"type": "integer"}),
            Ty::String => json!({"type": "string"}),
            Ty::Boolean => json!({"type": "boolean"}),
            Ty::StringArray => json!({"type": "array", "items": {"type": "string"}, "minItems": 1}),
        };
        s["description"] = json!(prm.desc);
        if !prm.choices.is_empty() {
            s["enum"] = json!(prm.choices);
        }
        props.insert(prm.name.to_string(), s);
    }
    let required: Vec<&str> = tool.params.iter().filter(|p| p.required).map(|p| p.name).collect();
    let mut s = json!({"type": "object", "properties": props, "additionalProperties": false});
    if !required.is_empty() {
        s["required"] = json!(required);
    }
    s
}

pub fn tool_list() -> Value {
    let list: Vec<Value> = tools()
        .iter()
        .map(|t| {
            json!({
                "name": t.name,
                "title": t.title,
                "description": t.desc,
                "inputSchema": schema(t),
                "annotations": {"readOnlyHint": t.read_only, "destructiveHint": false, "openWorldHint": false},
            })
        })
        .collect();
    json!({ "tools": list })
}

fn type_ok(ty: Ty, v: &Value) -> bool {
    match ty {
        Ty::Number => v.is_number(),
        Ty::Integer => v.as_i64().is_some() || v.as_f64().is_some_and(|f| f.fract() == 0.0),
        Ty::String => v.is_string(),
        Ty::Boolean => v.is_boolean(),
        Ty::StringArray => v.as_array().is_some_and(|a| !a.is_empty() && a.iter().all(Value::is_string)),
    }
}

fn type_name(ty: Ty) -> &'static str {
    match ty {
        Ty::Number => "a number",
        Ty::Integer => "an integer",
        Ty::String => "a string",
        Ty::Boolean => "true or false",
        Ty::StringArray => "a non-empty array of strings",
    }
}

/// Validate tool arguments against the tool's params.
pub fn validate(tool: &Tool, args: &Map<String, Value>) -> Result<Map<String, Value>> {
    for k in args.keys() {
        if !tool.params.iter().any(|p| p.name == k) {
            let known: Vec<&str> = tool.params.iter().map(|p| p.name).collect();
            return Err(Error::Usage(format!("{}: unknown argument '{k}' (accepted: {})", tool.name, known.join(", "))));
        }
    }
    let mut out = Map::new();
    for prm in &tool.params {
        match args.get(prm.name) {
            None | Some(Value::Null) if prm.required => {
                return Err(Error::Usage(format!("{}: missing required argument '{}'", tool.name, prm.name)))
            }
            None | Some(Value::Null) => {}
            Some(v) if !type_ok(prm.ty, v) => {
                return Err(Error::Usage(format!("{}: '{}' must be {}", tool.name, prm.name, type_name(prm.ty))))
            }
            Some(Value::String(s)) if !prm.choices.is_empty() && !prm.choices.contains(&s.as_str()) => {
                return Err(Error::Usage(format!("{}: '{}' must be one of {}", tool.name, prm.name, prm.choices.join(", "))))
            }
            Some(v) => {
                out.insert(prm.name.to_string(), v.clone());
            }
        }
    }
    Ok(out)
}

fn abs_path(v: Option<&Value>, what: &str) -> Result<Option<PathBuf>> {
    match v.and_then(Value::as_str) {
        None => Ok(None),
        Some(s) if Path::new(s).is_absolute() => Ok(Some(PathBuf::from(s))),
        Some(_) => Err(Error::Usage(format!("{what}: 'path' must be an absolute path"))),
    }
}

/// Map a tool call to the same Action the CLI would run.
pub fn to_action(name: &str, args: &Map<String, Value>) -> Result<Action> {
    let all = tools();
    let tool = all.iter().find(|t| t.name == name).ok_or_else(|| Error::Usage(format!("unknown tool '{name}'")))?;
    let mut a = validate(tool, args)?;
    let force = a.get("force").and_then(Value::as_bool).unwrap_or(false);
    Ok(match name {
        "wait" => Action::Wait(a["seconds"].as_f64().unwrap_or(-1.0)),
        "record_stop" => Action::RecordStop,
        "screenshot" => {
            let dest = match abs_path(a.get("path"), name)? {
                Some(p) => Some(files::prepare_dest(Some(&p), "png", force)?),
                None => None,
            };
            a.remove("path");
            a.remove("force");
            Action::Screenshot { req: Request { cmd: name.into(), args: a }, dest, force }
        }
        "record_start" => {
            let dest = match abs_path(a.get("path"), name)? {
                Some(p) => files::prepare_dest(Some(&p), "mov", force)?.to_string_lossy().to_string(),
                None => String::new(),
            };
            a.remove("path");
            a.insert("dest".into(), json!(dest));
            Action::RecordStart(Request { cmd: name.into(), args: a })
        }
        _ => Action::Call(Request { cmd: name.into(), args: a }),
    })
}

fn text(t: impl Into<String>) -> Value {
    json!({"type": "text", "text": t.into()})
}

/// Run one tool call; failures become isError results with the same message the CLI prints.
pub fn call_tool(client: &Client, name: &str, args: &Map<String, Value>) -> Value {
    let action = match to_action(name, args) {
        Ok(a) => a,
        Err(e) => return json!({"content": [text(e.message())], "isError": true}),
    };
    match actions::execute(client, &action) {
        Err(e) => json!({"content": [text(e.message())], "isError": true, "structuredContent": e.to_json()}),
        Ok(data) => {
            let mut content = Vec::new();
            if name == "screenshot" {
                match data["path"].as_str().map(std::fs::read) {
                    Some(Ok(png)) => content.push(json!({"type": "image", "mimeType": "image/png", "data": base64(&png)})),
                    _ => content.push(text("(could not read the screenshot file back)")),
                }
                content.push(text(format!(
                    "saved {} ({}x{} px, display {} origin {},{}, {} pixels per point)",
                    data["path"].as_str().unwrap_or("?"),
                    output::num(&data["width"]),
                    output::num(&data["height"]),
                    output::num(&data["display"]),
                    output::num(&data["origin"]["x"]),
                    output::num(&data["origin"]["y"]),
                    data["pixels_per_point"].as_f64().map(|f| format!("{f:.2}")).unwrap_or("?".into()),
                )));
            } else {
                let mut t = output::render(&action.kind(), &data);
                if t.is_empty() {
                    t = "ok".into();
                }
                content.push(text(t));
            }
            let mut r = json!({"content": content, "isError": false});
            if data.is_object() {
                r["structuredContent"] = data;
            }
            r
        }
    }
}

pub fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

fn rpc_result(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn rpc_error(id: &Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

/// Handle one JSON-RPC message. Returns None for notifications.
pub fn handle(client: &Client, msg: &Value) -> Option<Value> {
    let method = msg.get("method").and_then(Value::as_str);
    // No id: a notification (notifications/initialized, cancelled, ...) or a stray response. Never answered.
    let id = msg.get("id").cloned()?;
    let Some(method) = method else { return Some(rpc_error(&id, -32600, "invalid request: no method")) };
    let params = msg.get("params").cloned().unwrap_or(json!({}));
    Some(match method {
        "initialize" => {
            let asked = params.get("protocolVersion").and_then(Value::as_str).unwrap_or("");
            let version = PROTOCOL_VERSIONS.iter().find(|v| **v == asked).copied().unwrap_or(PROTOCOL_VERSIONS[0]);
            rpc_result(
                &id,
                json!({
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": false}},
                    "serverInfo": {"name": "macinto.sh", "title": "Macinto.sh", "version": env!("MACINTO_VERSION")},
                    "instructions": INSTRUCTIONS,
                }),
            )
        }
        "ping" => rpc_result(&id, json!({})),
        "tools/list" => rpc_result(&id, tool_list()),
        "tools/call" => {
            let Some(name) = params.get("name").and_then(Value::as_str) else {
                return Some(rpc_error(&id, -32602, "tools/call needs params.name"));
            };
            if !tools().iter().any(|t| t.name == name) {
                return Some(rpc_error(&id, -32602, &format!("unknown tool '{name}'")));
            }
            let empty = Map::new();
            let args = match params.get("arguments") {
                None | Some(Value::Null) => &empty,
                Some(Value::Object(m)) => m,
                Some(_) => return Some(rpc_error(&id, -32602, "params.arguments must be an object")),
            };
            rpc_result(&id, call_tool(client, name, args))
        }
        _ => rpc_error(&id, -32601, &format!("method not found: {method}")),
    })
}

pub fn serve(client: &Client) -> i32 {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Err(e) => Some(rpc_error(&Value::Null, -32700, &format!("parse error: {e}"))),
            Ok(Value::Array(_)) => Some(rpc_error(&Value::Null, -32600, "batches are not supported")),
            Ok(msg) => handle(client, &msg),
        };
        if let Some(r) = reply {
            let mut s = serde_json::to_string(&r).expect("serializes");
            s.push('\n');
            if stdout.write_all(s.as_bytes()).and_then(|_| stdout.flush()).is_err() {
                break;
            }
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    #[test]
    fn every_command_is_a_tool() {
        let names: Vec<&str> = tools().iter().map(|t| t.name).collect();
        for want in [
            "status", "click", "move", "drag", "scroll", "type", "key", "keys", "open", "apps", "location", "ui",
            "press", "focus", "set_value", "screenshot", "record_start", "record_stop", "record_status", "wait",
        ] {
            assert!(names.contains(&want), "missing tool {want}");
        }
        let mut sorted = names.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), names.len(), "duplicate tool names");
    }

    #[test]
    fn schemas_are_well_formed() {
        for t in tools() {
            let s = schema(&t);
            assert_eq!(s["type"], "object", "{}", t.name);
            let props = s["properties"].as_object().unwrap();
            for r in s["required"].as_array().into_iter().flatten() {
                assert!(props.contains_key(r.as_str().unwrap()), "{}: required {r} not in properties", t.name);
            }
            for (k, v) in props {
                assert!(v["description"].as_str().is_some_and(|d| !d.is_empty()), "{}.{k} has no description", t.name);
            }
            assert!(t.desc.len() > 20, "{} needs a real description", t.name);
        }
        let click = tools().into_iter().find(|t| t.name == "click").unwrap();
        let s = schema(&click);
        assert_eq!(s["required"], json!(["x", "y"]));
        assert_eq!(s["properties"]["button"]["enum"], json!(["left", "right"]));
    }

    #[test]
    fn maps_click_like_the_cli() {
        let a = to_action("click", &args(json!({"x": 10, "y": 20.5, "button": "right", "count": 2}))).unwrap();
        let cli = crate::cli::to_action(
            &<crate::cli::Cli as clap::Parser>::try_parse_from(["macinto.sh", "click", "--right", "--double", "10", "20.5"])
                .unwrap()
                .command,
        )
        .unwrap();
        // Same command and values (the CLI sends floats for coordinates).
        match (a, cli) {
            (Action::Call(m), Action::Call(c)) => {
                assert_eq!(m.cmd, c.cmd);
                assert_eq!(m.args["x"].as_f64(), c.args["x"].as_f64());
                assert_eq!(m.args["button"], c.args["button"]);
                assert_eq!(m.args["count"], c.args["count"]);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn rejects_bad_arguments() {
        assert!(to_action("click", &args(json!({"x": 1}))).is_err());
        assert!(to_action("click", &args(json!({"x": "1", "y": 2}))).is_err());
        assert!(to_action("click", &args(json!({"x": 1, "y": 2, "button": "middle"}))).is_err());
        assert!(to_action("click", &args(json!({"x": 1, "y": 2, "bogus": 1}))).is_err());
        assert!(to_action("key", &args(json!({"combos": []}))).is_err());
        assert!(to_action("screenshot", &args(json!({"path": "relative.png"}))).is_err());
        assert!(to_action("nope", &Map::new()).is_err());
    }

    #[test]
    fn screenshot_without_path_stays_in_captures() {
        match to_action("screenshot", &args(json!({"max_width": 640}))).unwrap() {
            Action::Screenshot { req, dest, .. } => {
                assert_eq!(req.cmd, "screenshot");
                assert_eq!(req.args["max_width"], 640);
                assert!(dest.is_none());
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn record_start_sends_dest() {
        match to_action("record_start", &Map::new()).unwrap() {
            Action::RecordStart(r) => assert_eq!(r.args["dest"], ""),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn base64_matches_rfc4648() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn json_rpc_basics() {
        let c = Client::new(Some(PathBuf::from("/nonexistent/macinto-test.sock")));
        let init = handle(&c, &json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                      "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}}))
            .unwrap();
        assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
        assert!(init["result"]["capabilities"]["tools"].is_object());
        assert!(handle(&c, &json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).is_none());
        let unknown_version = handle(&c, &json!({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}})).unwrap();
        assert_eq!(unknown_version["result"]["protocolVersion"], PROTOCOL_VERSIONS[0]);
        let list = handle(&c, &json!({"jsonrpc": "2.0", "id": 3, "method": "tools/list"})).unwrap();
        assert!(list["result"]["tools"].as_array().unwrap().len() >= 20);
        let missing = handle(&c, &json!({"jsonrpc": "2.0", "id": 4, "method": "nope"})).unwrap();
        assert_eq!(missing["error"]["code"], -32601);
        // App not running: a tool result with isError, not a protocol error.
        let call = handle(&c, &json!({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "status", "arguments": {}}})).unwrap();
        assert_eq!(call["result"]["isError"], true);
        assert!(call["result"]["content"][0]["text"].as_str().unwrap().contains("open -a Macinto.sh"));
        let bad_tool = handle(&c, &json!({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "enable"}})).unwrap();
        assert_eq!(bad_tool["error"]["code"], -32602);
    }
}
