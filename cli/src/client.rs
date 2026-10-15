//! Socket client and the error type shared by the CLI and the MCP server.

use crate::protocol::{Request, Response};
use serde_json::Value;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const APP: &str = "Macinto.sh";

#[derive(Debug, Clone, PartialEq)]
pub enum Error {
    /// Bad command line or arguments (exit 2).
    Usage(String),
    /// No socket, or nothing listening.
    NotRunning(PathBuf),
    /// The app refused: code from the protocol (disabled, permission, not_found, failed, ...).
    App { code: String, message: String, permission: Option<String> },
    /// Local failure (I/O, files).
    Local(String),
}

impl Error {
    pub fn exit_code(&self) -> i32 {
        match self {
            Error::Usage(_) => 2,
            Error::App { code, .. } if code == "usage" => 2,
            _ => 1,
        }
    }

    pub fn code(&self) -> &str {
        match self {
            Error::Usage(_) => "usage",
            Error::NotRunning(_) => "not_running",
            Error::App { code, .. } => code,
            Error::Local(_) => "failed",
        }
    }

    pub fn message(&self) -> String {
        match self {
            Error::Usage(m) | Error::Local(m) => m.clone(),
            Error::NotRunning(p) if p.ends_with("macinto-dev.sock") => format!(
                "{APP} (Dev) is not running (nothing listening at {}). Start it with: open \"build/debug/Macinto.sh (Dev).app\"",
                p.display()
            ),
            Error::NotRunning(p) => format!(
                "{APP} is not running (nothing listening at {}). Start it with: open -a {APP}",
                p.display()
            ),
            Error::App { message, .. } => message.clone(),
        }
    }

    pub fn to_json(&self) -> Value {
        let mut o = serde_json::json!({"ok": false, "code": self.code(), "error": self.message()});
        if let Error::App { permission: Some(p), .. } = self {
            o["permission"] = Value::String(p.clone());
        }
        o
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

pub fn default_socket() -> PathBuf {
    support_dir().join("macinto.sock")
}

/// The dev build's socket (`--dev`).
pub fn dev_socket() -> PathBuf {
    support_dir().join("macinto-dev.sock")
}

fn support_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"));
    home.join("Library/Application Support/macinto")
}

pub struct Client {
    pub socket: PathBuf,
}

impl Client {
    pub fn new(socket: Option<PathBuf>) -> Self {
        Client { socket: socket.unwrap_or_else(default_socket) }
    }

    /// Send one request and return `data` from a successful response.
    pub fn call(&self, req: &Request) -> Result<Value> {
        let resp = self.round_trip(req)?;
        if resp.ok {
            return Ok(resp.data.unwrap_or(Value::Object(Default::default())));
        }
        Err(Error::App {
            code: resp.code.unwrap_or_else(|| "failed".into()),
            message: resp.error.unwrap_or_else(|| "request failed".into()),
            permission: resp.permission,
        })
    }

    fn round_trip(&self, req: &Request) -> Result<Response> {
        let mut s = connect(&self.socket)?;
        // Long enough for `open` of a slow app and finalizing a recording.
        let _ = s.set_read_timeout(Some(Duration::from_secs(120)));
        let _ = s.set_write_timeout(Some(Duration::from_secs(10)));
        s.write_all(&req.encode())
            .map_err(|e| Error::Local(format!("could not send request to {APP}: {e}")))?;
        let mut buf = Vec::new();
        s.read_to_end(&mut buf).map_err(|e| match e.kind() {
            ErrorKind::WouldBlock | ErrorKind::TimedOut => Error::Local(format!("timed out waiting for {APP}")),
            _ => Error::Local(format!("could not read response from {APP}: {e}")),
        })?;
        if buf.is_empty() {
            return Err(Error::Local(format!("{APP} closed the connection without answering")));
        }
        Response::decode(&buf).map_err(|e| Error::Local(format!("{e} (is the app older than the CLI?)")))
    }
}

fn connect(path: &Path) -> Result<UnixStream> {
    UnixStream::connect(path).map_err(|e| match e.kind() {
        ErrorKind::NotFound | ErrorKind::ConnectionRefused => Error::NotRunning(path.to_path_buf()),
        ErrorKind::PermissionDenied => {
            Error::Local(format!("permission denied on {} (the socket belongs to another user?)", path.display()))
        }
        _ => Error::Local(format!("could not connect to {}: {e}", path.display())),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_socket_is_not_running() {
        let c = Client::new(Some(PathBuf::from("/nonexistent/macinto-test.sock")));
        let e = c.call(&Request::new("status")).unwrap_err();
        assert!(matches!(e, Error::NotRunning(_)));
        assert!(e.message().contains("open -a Macinto.sh"));
        assert_eq!(e.exit_code(), 1);
    }

    #[test]
    fn exit_codes() {
        assert_eq!(Error::Usage("x".into()).exit_code(), 2);
        let app_usage = Error::App { code: "usage".into(), message: "x".into(), permission: None };
        assert_eq!(app_usage.exit_code(), 2);
        let disabled = Error::App { code: "disabled".into(), message: "x".into(), permission: None };
        assert_eq!(disabled.exit_code(), 1);
    }

    #[test]
    fn error_json_carries_permission() {
        let e = Error::App { code: "permission".into(), message: "m".into(), permission: Some("accessibility".into()) };
        let j = e.to_json();
        assert_eq!(j["ok"], false);
        assert_eq!(j["permission"], "accessibility");
    }
}
