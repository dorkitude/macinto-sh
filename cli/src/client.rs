//! Socket client and the error type shared by the CLI and the MCP server.

use crate::launch::{self, Target};
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
    /// No socket, or nothing listening (and auto-launch is off or not applicable).
    NotRunning(PathBuf),
    /// The app isn't installed; the message says how to install it.
    NotInstalled(String),
    /// The app was launched but its socket didn't answer in time.
    LaunchTimedOut { app: String, socket: PathBuf },
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
            Error::NotRunning(_) | Error::LaunchTimedOut { .. } => "not_running",
            Error::NotInstalled(_) => "not_installed",
            Error::App { code, .. } => code,
            Error::Local(_) => "failed",
        }
    }

    pub fn message(&self) -> String {
        match self {
            Error::Usage(m) | Error::Local(m) | Error::NotInstalled(m) => m.clone(),
            Error::LaunchTimedOut { app, socket } => format!(
                "launched {app}, but nothing answered at {} within {} s. Check the {app} window, or ~/Library/Logs/macinto.log",
                socket.display(),
                launch::WAIT.as_secs()
            ),
            Error::NotRunning(p) if p.ends_with("macinto-dev.sock") => format!(
                "{APP} (Dev) is not running (nothing listening at {}). Start it with: macinto.sh --dev setup",
                p.display()
            ),
            Error::NotRunning(p) => format!(
                "{APP} is not running (nothing listening at {}). Start it with: macinto.sh setup",
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

/// Human text for the `setup` error code (the app's own message is shorter).
pub fn setup_message(name: &str) -> String {
    format!("{name} needs setup: finish it in the {name} window (it's open now), then enable it.")
}

pub struct Client {
    pub socket: PathBuf,
    /// Which app this socket belongs to (release or dev): used for messages and auto-launch.
    pub target: Target,
    /// Start the app when nothing is listening.
    pub auto_launch: bool,
    /// MACINTO_APP: launch this .app instead of looking one up.
    pub app_override: Option<PathBuf>,
}

impl Client {
    /// A client that never launches anything.
    #[cfg(test)]
    pub fn new(socket: Option<PathBuf>) -> Self {
        Client { socket: socket.unwrap_or_else(default_socket), target: launch::RELEASE, auto_launch: false, app_override: None }
    }

    /// The client the CLI and MCP server use. Auto-launch applies only to the target app's own
    /// socket: an explicit --socket / MACINTO_SOCKET elsewhere has no app we could start for it.
    pub fn for_cli(socket: Option<PathBuf>, dev: bool, no_launch: bool, app_override: Option<PathBuf>) -> Self {
        let target = Target::for_dev(dev);
        let own = if dev { dev_socket() } else { default_socket() };
        let socket = socket.unwrap_or_else(|| own.clone());
        let auto_launch = !no_launch && socket == own;
        Client { socket, target, auto_launch, app_override }
    }

    /// Send one request and return `data` from a successful response.
    pub fn call(&self, req: &Request) -> Result<Value> {
        self.call_tracked(req).map(|(data, _)| data)
    }

    /// Like `call`, and also says whether the app had to be launched first.
    pub fn call_tracked(&self, req: &Request) -> Result<(Value, bool)> {
        let (resp, launched) = match self.round_trip(req) {
            Err(Error::NotRunning(_)) if self.auto_launch => {
                launch::launch_and_wait(&self.target, &self.socket, self.app_override.as_deref())?;
                (self.round_trip(req)?, true)
            }
            other => (other?, false),
        };
        self.interpret(resp).map(|d| (d, launched))
    }

    fn interpret(&self, resp: Response) -> Result<Value> {
        if resp.ok {
            return Ok(resp.data.unwrap_or(Value::Object(Default::default())));
        }
        let code = resp.code.unwrap_or_else(|| "failed".into());
        let message = if code == "setup" {
            setup_message(self.target.name)
        } else {
            resp.error.unwrap_or_else(|| "request failed".into())
        };
        Err(Error::App { code, message, permission: resp.permission })
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
        assert!(e.message().contains("Start it with: macinto.sh setup"), "{}", e.message());
        let dev = Error::NotRunning(dev_socket());
        assert!(dev.message().contains("Start it with: macinto.sh --dev setup"), "{}", dev.message());
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
    fn not_installed_and_timeout_codes() {
        let e = Error::NotInstalled(launch::RELEASE.not_installed_message());
        assert_eq!(e.code(), "not_installed");
        assert_eq!(e.to_json()["code"], "not_installed");
        let t = Error::LaunchTimedOut { app: "Macinto.sh".into(), socket: PathBuf::from("/x.sock") };
        assert_eq!(t.code(), "not_running");
        assert!(t.message().contains("within 10 s"));
    }

    #[test]
    fn auto_launch_only_for_own_socket() {
        assert!(Client::for_cli(None, false, false, None).auto_launch);
        assert!(Client::for_cli(None, true, false, None).auto_launch);
        assert_eq!(Client::for_cli(None, true, false, None).socket, dev_socket());
        assert!(!Client::for_cli(None, false, true, None).auto_launch);
        assert!(!Client::for_cli(Some(PathBuf::from("/tmp/other.sock")), false, false, None).auto_launch);
        assert!(Client::for_cli(Some(default_socket()), false, false, None).auto_launch);
        // No launch: a missing socket stays not_running.
        let c = Client::for_cli(Some(PathBuf::from("/nonexistent/m.sock")), false, false, None);
        assert_eq!(c.call(&Request::new("status")).unwrap_err().code(), "not_running");
    }

    /// One-shot fake app: answers every connection with `reply`.
    fn fake_app(name: &str, reply: &'static str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("macinto-{}-{name}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let l = std::os::unix::net::UnixListener::bind(&path).unwrap();
        std::thread::spawn(move || {
            for mut s in l.incoming().flatten() {
                let mut line = String::new();
                let _ = std::io::BufRead::read_line(&mut std::io::BufReader::new(&mut s), &mut line);
                let _ = s.write_all(reply.as_bytes());
            }
        });
        path
    }

    #[test]
    fn setup_code_gets_human_message() {
        let sock = fake_app("setup", "{\"ok\":false,\"code\":\"setup\",\"error\":\"Finish setup in the Macinto.sh window (permissions), then enable it.\"}\n");
        let mut c = Client::new(Some(sock.clone()));
        let e = c.call(&Request::new("apps")).unwrap_err();
        assert_eq!(e.code(), "setup");
        assert_eq!(e.exit_code(), 1);
        assert_eq!(e.message(), "Macinto.sh needs setup: finish it in the Macinto.sh window (it's open now), then enable it.");
        assert_eq!(e.to_json()["code"], "setup");
        c.target = launch::DEV;
        assert!(c.call(&Request::new("apps")).unwrap_err().message().starts_with("Macinto.sh (Dev) needs setup"));
        let _ = std::fs::remove_file(sock);
    }

    #[test]
    fn disabled_code_keeps_app_message() {
        let sock = fake_app("disabled", "{\"ok\":false,\"code\":\"disabled\",\"error\":\"Macinto.sh is disabled.\"}\n");
        let e = Client::new(Some(sock.clone())).call(&Request::new("apps")).unwrap_err();
        assert_eq!(e.code(), "disabled");
        assert_eq!(e.message(), "Macinto.sh is disabled.");
        let _ = std::fs::remove_file(sock);
    }

    #[test]
    fn setup_action_reports_shown_window() {
        use crate::actions::{execute, Action};
        let sock = fake_app("show", "{\"ok\":true,\"data\":{\"shown\":true,\"name\":\"Macinto.sh\",\"state\":\"disabled\",\"enabled\":false}}\n");
        let d = execute(&Client::new(Some(sock.clone())), &Action::Setup).unwrap();
        assert_eq!(d["shown"], true);
        assert_eq!(d["launched"], false);
        assert_eq!(crate::output::render("setup", &d), "Macinto.sh is open. Enable it in its window.");
        let _ = std::fs::remove_file(sock);
        // Not running and no auto-launch (--no-launch): not_running.
        let e = execute(&Client::new(Some(PathBuf::from("/nonexistent/m.sock"))), &Action::Setup).unwrap_err();
        assert_eq!(e.code(), "not_running");
        // An older app's gate (no show_window) without auto-launch: its error passes through.
        let sock = fake_app("show-old", "{\"ok\":false,\"code\":\"disabled\",\"error\":\"Macinto.sh is disabled.\"}\n");
        assert_eq!(execute(&Client::new(Some(sock.clone())), &Action::Setup).unwrap_err().code(), "disabled");
        let _ = std::fs::remove_file(sock);
    }

    #[test]
    fn error_json_carries_permission() {
        let e = Error::App { code: "permission".into(), message: "m".into(), permission: Some("accessibility".into()) };
        let j = e.to_json();
        assert_eq!(j["ok"], false);
        assert_eq!(j["permission"], "accessibility");
    }
}
