//! What a command does once its arguments are parsed. Shared by the CLI and the MCP server, so
//! both go through the same socket client (and the app's enabled gate, permission checks, logging).

use crate::client::{Client, Error, Result};
use crate::files;
use crate::protocol::Request;
use serde_json::{json, Value};
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// One request; the response data is the result.
    Call(Request),
    /// Screenshot, then move the capture to `dest` (None: leave it in the captures folder).
    Screenshot { req: Request, dest: Option<PathBuf>, force: bool },
    /// The app remembers `dest`/`force` (sent in the request) until `record stop`.
    RecordStart(Request),
    RecordStop,
    /// Client-side sleep.
    Wait(f64),
    /// `setup`: start the app if needed, then `show_window` (bring its window forward).
    Setup,
    /// Derived from `status`.
    Permissions,
    Displays,
}

impl Action {
    /// Key used to pick the human-readable renderer.
    pub fn kind(&self) -> String {
        match self {
            Action::Call(r) => r.cmd.clone(),
            Action::Screenshot { .. } => "screenshot".into(),
            Action::RecordStart(_) => "record_start".into(),
            Action::RecordStop => "record_stop".into(),
            Action::Wait(_) => "wait".into(),
            Action::Setup => "setup".into(),
            Action::Permissions => "permissions".into(),
            Action::Displays => "displays".into(),
        }
    }
}

pub fn execute(client: &Client, action: &Action) -> Result<Value> {
    match action {
        Action::Call(req) => client.call(req),
        Action::Screenshot { req, dest, force } => {
            let mut data = client.call(req)?;
            if let Some(dest) = dest {
                let src = path_field(&data, "path")?;
                files::deliver(&src, dest, *force)?;
                data["path"] = json!(dest.to_string_lossy());
            }
            Ok(data)
        }
        Action::RecordStart(req) => client.call(req),
        Action::RecordStop => {
            let mut data = client.call(&Request::new("record_stop"))?;
            let dest = data.get("dest").and_then(Value::as_str).unwrap_or("").to_string();
            if !dest.is_empty() {
                let src = path_field(&data, "path")?;
                let force = data.get("force").and_then(Value::as_bool).unwrap_or(false);
                files::deliver(&src, std::path::Path::new(&dest), force)?;
                data["path"] = json!(dest);
            }
            Ok(data)
        }
        Action::Wait(secs) => {
            if !(secs.is_finite() && *secs >= 0.0 && *secs <= 3600.0) {
                return Err(Error::Usage("wait takes 0 to 3600 seconds".into()));
            }
            std::thread::sleep(std::time::Duration::from_secs_f64(*secs));
            Ok(json!({"waited": secs}))
        }
        Action::Setup => {
            let (mut data, launched) = match client.call_tracked(&Request::new("show_window")) {
                // An app older than this CLI (before 0.1.102) has no show_window: it answers
                // bad_request, or setup/disabled from its gate (show_window itself is never gated).
                // Open it again instead, which shows its window (the reopen event), and report status.
                Err(Error::App { code, .. })
                    if matches!(code.as_str(), "bad_request" | "setup" | "disabled") && client.auto_launch =>
                {
                    crate::launch::open_app(&client.target, client.app_override.as_deref())?;
                    let mut s = client.call(&Request::new("status"))?;
                    s["name"] = json!(client.target.name);
                    (s, false)
                }
                other => other?,
            };
            if data.is_object() {
                data["launched"] = json!(launched);
            }
            Ok(data)
        }
        Action::Permissions => {
            let s = client.call(&Request::new("status"))?;
            Ok(json!({
                "accessibility": s["permissions"]["accessibility"],
                "screen_recording": s["permissions"]["screen_recording"],
            }))
        }
        Action::Displays => {
            let s = client.call(&Request::new("status"))?;
            Ok(json!({"displays": s["displays"]}))
        }
    }
}

fn path_field(data: &Value, key: &str) -> Result<PathBuf> {
    data.get(key)
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or_else(|| Error::Local(format!("Macinto.sh did not return '{key}'")))
}
