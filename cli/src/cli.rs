//! Command line definition (clap derive) and the mapping from parsed commands to actions.

use crate::actions::Action;
use crate::client::{Error, Result};
use crate::files;
use crate::protocol::Request;
use clap::{Args, Parser, Subcommand};
use serde_json::json;
use std::path::PathBuf;

const ABOUT: &str = "Drive this Mac through Macinto.sh.app: click, type, read the UI tree, take screenshots.";

const LONG_ABOUT: &str = "\
Drive this Mac through Macinto.sh.app: click, type, read the UI tree, take screenshots.

Macinto.sh.app must be set up and enabled from its window or menu bar icon;
'macinto.sh setup' opens that window (starting the app if needed).
If it isn't running, macinto.sh starts it and waits up to 10 seconds (turn this
off with --no-launch). Until setup is finished, requests fail with code
'setup'; while it is disabled every request except status, permissions,
screen list and keys fails with code 'disabled'. There is no command to enable
it.

Coordinates are global points with the origin at the top-left of the main
display. Screenshots are scaled to points by default, so a pixel at (x, y) in a
screenshot of display 0 is clicked with `macinto.sh click x y`.";

const AFTER_HELP: &str = "\
Exit codes: 0 ok, 1 error, 2 usage error.
Environment: MACINTO_SOCKET overrides the socket path (no auto-launch for other
sockets), MACINTO_NO_LAUNCH=1 is --no-launch, MACINTO_APP=/path/to/App.app picks
the app to launch.
Run 'macinto.sh <command> --help' for details on one command.";

#[derive(Parser, Debug)]
#[command(
    name = "macinto.sh",
    bin_name = "macinto.sh",
    version = env!("MACINTO_VERSION"),
    about = ABOUT,
    long_about = LONG_ABOUT,
    after_help = AFTER_HELP,
    propagate_version = true,
    disable_help_subcommand = false,
    subcommand_required = true,
    arg_required_else_help = true
)]
pub struct Cli {
    /// Print machine-readable JSON: {"ok": true, "data": {...}} or {"ok": false, "code": ..., "error": ...}
    #[arg(long, global = true)]
    pub json: bool,

    /// Socket path (default: ~/Library/Application Support/macinto/macinto.sock)
    #[arg(long, global = true, env = "MACINTO_SOCKET", value_name = "PATH", hide_env_values = true)]
    pub socket: Option<PathBuf>,

    /// Talk to the dev build, "Macinto.sh (Dev).app" (socket macinto-dev.sock)
    #[arg(long, global = true, conflicts_with = "socket")]
    pub dev: bool,

    /// Don't start Macinto.sh.app when it isn't running; fail with not_running instead
    #[arg(long, global = true, env = "MACINTO_NO_LAUNCH", value_parser = clap::builder::BoolishValueParser::new(), hide_env_values = true)]
    pub no_launch: bool,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand, Debug, PartialEq)]
pub enum Command {
    // ---- Setup
    /// Open the Macinto.sh window (starting the app if needed) to finish setup or enable it
    #[command(display_order = 0)]
    Setup,

    // ---- Info
    /// Show whether Macinto.sh is enabled, time left, permissions, displays
    #[command(display_order = 1)]
    Status,
    /// Show which macOS permissions Macinto.sh has
    #[command(display_order = 2)]
    Permissions,
    /// Displays and their frames in points
    #[command(display_order = 3, subcommand)]
    Screen(ScreenCmd),
    /// Print the current mouse position
    #[command(display_order = 4)]
    Location,
    /// List key names accepted by 'key'
    #[command(display_order = 5)]
    Keys,

    // ---- Input
    /// Click at a point
    #[command(display_order = 10, allow_negative_numbers = true)]
    Click(ClickArgs),
    /// Move the pointer
    #[command(display_order = 11, allow_negative_numbers = true)]
    Move(PointArgs),
    /// Left-button drag from one point to another
    #[command(display_order = 12, allow_negative_numbers = true)]
    Drag(DragArgs),
    /// Scroll by lines (positive DY scrolls up, negative scrolls down)
    #[command(display_order = 13, allow_negative_numbers = true)]
    Scroll(ScrollArgs),
    /// Type Unicode text into the focused element (newline = Return, tab = Tab)
    #[command(display_order = 14)]
    Type(TypeArgs),
    /// Press key combos, e.g. cmd+shift+g, return, escape, f5, left, cmd+plus
    #[command(display_order = 15, visible_alias = "hotkey")]
    Key(KeyArgs),

    // ---- Apps
    /// Running apps, and opening apps. With no subcommand: same as 'setup'
    #[command(display_order = 20)]
    App(AppGroup),
    /// List running apps (same as 'app list')
    #[command(display_order = 21)]
    Apps,
    /// Open or activate an app (same as 'app open')
    #[command(display_order = 22)]
    Open(OpenArgs),

    // ---- UI tree
    /// Dump the accessibility tree of an app's focused window, with element ids
    #[command(display_order = 30)]
    Ui(UiArgs),
    /// Perform AXPress on an element (ids come from 'ui')
    #[command(display_order = 31)]
    Press(ElementArgs),
    /// Focus an element
    #[command(display_order = 32)]
    Focus(ElementArgs),
    /// Set an element's value (e.g. a text field)
    #[command(display_order = 33, visible_alias = "setvalue")]
    SetValue(SetValueArgs),

    // ---- Capture
    /// Save a PNG of a display (default ./macinto-YYYYmmdd-HHMMSS.png)
    #[command(display_order = 40, visible_alias = "image")]
    Screenshot(ScreenshotArgs),
    /// Screen recording: start, stop, status
    #[command(display_order = 41, subcommand)]
    Record(RecordCmd),

    // ---- Other
    /// Sleep (runs in the CLI, no app involved)
    #[command(display_order = 50)]
    Wait(WaitArgs),
    /// Run an MCP server on stdin/stdout exposing these commands as tools
    #[command(display_order = 51)]
    Mcp,
}

#[derive(Subcommand, Debug, PartialEq)]
pub enum ScreenCmd {
    /// List displays: index, origin and size in points, scale
    List,
}

#[derive(Args, Debug, PartialEq)]
pub struct AppGroup {
    #[command(subcommand)]
    pub cmd: Option<AppCmd>,
}

#[derive(Subcommand, Debug, PartialEq)]
pub enum AppCmd {
    /// List running apps: "*" marks the frontmost; pid, bundle id, name
    List,
    /// Activate an app by name, bundle id or .app path, launching it if needed
    Open(OpenArgs),
}

#[derive(Subcommand, Debug, PartialEq)]
pub enum RecordCmd {
    /// Start recording a display to a .mov
    Start(RecordStartArgs),
    /// Stop and move the movie to its -o path
    Stop,
    /// Is a recording running?
    Status,
}

#[derive(Args, Debug, PartialEq)]
pub struct PointArgs {
    /// X in global points
    pub x: f64,
    /// Y in global points (top-left origin)
    pub y: f64,
}

#[derive(Args, Debug, PartialEq)]
pub struct ClickArgs {
    #[command(flatten)]
    pub at: PointArgs,
    /// Right-click
    #[arg(long)]
    pub right: bool,
    /// Double-click
    #[arg(long)]
    pub double: bool,
}

#[derive(Args, Debug, PartialEq)]
pub struct DragArgs {
    pub x1: f64,
    pub y1: f64,
    pub x2: f64,
    pub y2: f64,
}

#[derive(Args, Debug, PartialEq)]
pub struct ScrollArgs {
    /// Horizontal lines
    pub dx: i32,
    /// Vertical lines (positive scrolls up)
    pub dy: i32,
}

#[derive(Args, Debug, PartialEq)]
pub struct TypeArgs {
    /// Text to type. Several arguments are joined with spaces.
    #[arg(required = true, num_args = 1.., allow_hyphen_values = true)]
    pub text: Vec<String>,
}

#[derive(Args, Debug, PartialEq)]
pub struct KeyArgs {
    /// One or more combos, pressed in order
    #[arg(required = true, num_args = 1.., value_name = "COMBO")]
    pub combos: Vec<String>,
}

#[derive(Args, Debug, PartialEq)]
pub struct OpenArgs {
    /// App name ("Safari"), bundle id ("com.apple.Safari") or path
    pub app: String,
}

#[derive(Args, Debug, PartialEq)]
pub struct UiArgs {
    /// App name, bundle id or pid (default: frontmost app)
    #[arg(long, value_name = "APP")]
    pub app: Option<String>,
    /// Maximum depth below the window
    #[arg(long, default_value_t = 12, value_name = "N")]
    pub depth: u32,
}

#[derive(Args, Debug, PartialEq)]
pub struct ElementArgs {
    /// Element id from 'ui', like 0.3.1. Re-resolved on every call.
    pub id: String,
    /// App name, bundle id or pid (default: frontmost app)
    #[arg(long, value_name = "APP")]
    pub app: Option<String>,
}

#[derive(Args, Debug, PartialEq)]
pub struct SetValueArgs {
    /// Element id from 'ui'
    pub id: String,
    /// New value
    #[arg(allow_hyphen_values = true)]
    pub value: String,
    /// App name, bundle id or pid (default: frontmost app)
    #[arg(long, value_name = "APP")]
    pub app: Option<String>,
}

#[derive(Args, Debug, PartialEq)]
pub struct ScreenshotArgs {
    /// Output file (default ./macinto-YYYYmmdd-HHMMSS.png)
    #[arg(short = 'o', long = "output", value_name = "FILE")]
    pub output: Option<PathBuf>,
    /// Overwrite the output file if it exists
    #[arg(short = 'f', long)]
    pub force: bool,
    /// Display index from 'screen list'
    #[arg(long, default_value_t = 0, value_name = "N")]
    pub display: u32,
    /// Keep only this app's windows
    #[arg(long, value_name = "APP")]
    pub app: Option<String>,
    /// Full Retina resolution instead of points
    #[arg(long)]
    pub native: bool,
    /// Scale down to at most this many pixels wide
    #[arg(long, value_name = "PX")]
    pub max_width: Option<u32>,
}

#[derive(Args, Debug, PartialEq)]
pub struct RecordStartArgs {
    /// Output file (default ./macinto-YYYYmmdd-HHMMSS.mov)
    #[arg(short = 'o', long = "output", value_name = "FILE")]
    pub output: Option<PathBuf>,
    /// Overwrite the output file if it exists
    #[arg(short = 'f', long)]
    pub force: bool,
    /// Display index from 'screen list'
    #[arg(long, default_value_t = 0, value_name = "N")]
    pub display: u32,
}

#[derive(Args, Debug, PartialEq)]
pub struct WaitArgs {
    /// Seconds, fractions allowed (max 3600)
    pub seconds: f64,
}

fn element(cmd: &str, a: &ElementArgs) -> Request {
    Request::new(cmd).arg("id", a.id.as_str()).arg("app", a.app.as_deref())
}

/// Map a parsed command to what it does. `Mcp` is handled by the caller.
pub fn to_action(cmd: &Command) -> Result<Action> {
    Ok(match cmd {
        Command::Setup | Command::App(AppGroup { cmd: None }) => Action::Setup,
        Command::Status => Action::Call(Request::new("status")),
        Command::Permissions => Action::Permissions,
        Command::Screen(ScreenCmd::List) => Action::Displays,
        Command::Location => Action::Call(Request::new("location")),
        Command::Keys => Action::Call(Request::new("keys")),
        Command::Click(a) => Action::Call(
            Request::new("click")
                .arg("x", a.at.x)
                .arg("y", a.at.y)
                .arg("button", if a.right { "right" } else { "left" })
                .arg("count", if a.double { 2 } else { 1 }),
        ),
        Command::Move(p) => Action::Call(Request::new("move").arg("x", p.x).arg("y", p.y)),
        Command::Drag(d) => {
            Action::Call(Request::new("drag").arg("x1", d.x1).arg("y1", d.y1).arg("x2", d.x2).arg("y2", d.y2))
        }
        Command::Scroll(s) => Action::Call(Request::new("scroll").arg("dx", s.dx).arg("dy", s.dy)),
        Command::Type(t) => Action::Call(Request::new("type").arg("text", t.text.join(" "))),
        Command::Key(k) => Action::Call(Request::new("key").arg("combos", json!(k.combos))),
        Command::App(AppGroup { cmd: Some(AppCmd::List) }) | Command::Apps => Action::Call(Request::new("apps")),
        Command::App(AppGroup { cmd: Some(AppCmd::Open(o)) }) | Command::Open(o) => {
            Action::Call(Request::new("open").arg("app", o.app.as_str()))
        }
        Command::Ui(u) => Action::Call(Request::new("ui").arg("app", u.app.as_deref()).arg("depth", u.depth)),
        Command::Press(e) => Action::Call(element("press", e)),
        Command::Focus(e) => Action::Call(element("focus", e)),
        Command::SetValue(s) => Action::Call(
            Request::new("set_value").arg("id", s.id.as_str()).arg("value", s.value.as_str()).arg("app", s.app.as_deref()),
        ),
        Command::Screenshot(s) => {
            let dest = files::prepare_dest(s.output.as_deref(), "png", s.force)?;
            Action::Screenshot {
                req: Request::new("screenshot")
                    .arg("display", s.display)
                    .arg("app", s.app.as_deref())
                    .arg("native", s.native)
                    .arg("max_width", s.max_width),
                dest: Some(dest),
                force: s.force,
            }
        }
        Command::Record(RecordCmd::Start(r)) => {
            let dest = files::prepare_dest(r.output.as_deref(), "mov", r.force)?;
            Action::RecordStart(
                Request::new("record_start")
                    .arg("display", r.display)
                    .arg("dest", dest.to_string_lossy().as_ref())
                    .arg("force", r.force),
            )
        }
        Command::Record(RecordCmd::Stop) => Action::RecordStop,
        Command::Record(RecordCmd::Status) => Action::Call(Request::new("record_status")),
        Command::Wait(w) => {
            if !(w.seconds.is_finite() && (0.0..=3600.0).contains(&w.seconds)) {
                return Err(Error::Usage("wait takes 0 to 3600 seconds".into()));
            }
            Action::Wait(w.seconds)
        }
        Command::Mcp => return Err(Error::Usage("mcp is not a socket command".into())),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    fn parse(args: &[&str]) -> std::result::Result<Cli, clap::Error> {
        Cli::try_parse_from(std::iter::once("macinto.sh").chain(args.iter().copied()))
    }

    fn req(args: &[&str]) -> Request {
        match to_action(&parse(args).unwrap().command).unwrap() {
            Action::Call(r) => r,
            other => panic!("expected a plain call, got {other:?}"),
        }
    }

    #[test]
    fn clap_definition_is_valid() {
        Cli::command().debug_assert();
    }

    #[test]
    fn program_name_in_help() {
        let help = Cli::command().render_help().to_string();
        assert!(help.contains("Usage: macinto.sh"), "{help}");
    }

    #[test]
    fn click_variants() {
        let r = req(&["click", "10", "20.5"]);
        assert_eq!(r.args["x"], 10.0);
        assert_eq!(r.args["y"], 20.5);
        assert_eq!(r.args["button"], "left");
        assert_eq!(r.args["count"], 1);
        let r = req(&["click", "--right", "--double", "1", "2"]);
        assert_eq!(r.args["button"], "right");
        assert_eq!(r.args["count"], 2);
    }

    #[test]
    fn negative_coordinates_and_scroll() {
        let r = req(&["click", "-100", "50"]);
        assert_eq!(r.args["x"], -100.0);
        let r = req(&["scroll", "0", "-5"]);
        assert_eq!(r.args["dy"], -5);
    }

    #[test]
    fn type_joins_words_and_keeps_dashes() {
        let r = req(&["type", "hello", "--world"]);
        assert_eq!(r.args["text"], "hello --world");
    }

    #[test]
    fn key_and_alias() {
        let r = req(&["hotkey", "cmd+shift+g", "return"]);
        assert_eq!(r.cmd, "key");
        assert_eq!(r.args["combos"], json!(["cmd+shift+g", "return"]));
    }

    #[test]
    fn app_shortcuts_match_group() {
        assert_eq!(req(&["apps"]), req(&["app", "list"]));
        assert_eq!(req(&["open", "Finder"]), req(&["app", "open", "Finder"]));
    }

    #[test]
    fn setup_and_app_alias() {
        for args in [&["setup"][..], &["app"], &["--dev", "setup"], &["app", "--no-launch"], &["--json", "setup"]] {
            let cli = parse(args).unwrap();
            assert_eq!(to_action(&cli.command).unwrap(), Action::Setup, "{args:?}");
        }
        assert!(parse(&["--dev", "--no-launch", "setup"]).unwrap().dev);
        assert!(parse(&["setup", "--dev", "--no-launch"]).unwrap().no_launch);
        // 'app' with a subcommand still means the app group.
        assert_eq!(req(&["app", "list"]).cmd, "apps");
        assert_eq!(req(&["app", "open", "Finder"]).cmd, "open");
        assert!(parse(&["setup", "extra"]).is_err());
        assert!(parse(&["app", "bogus"]).is_err());
        let help = Cli::command().render_help().to_string();
        assert!(help.contains("setup"), "{help}");
    }

    #[test]
    fn ui_and_elements() {
        let r = req(&["ui", "--app", "TextEdit", "--depth", "3"]);
        assert_eq!(r.args["app"], "TextEdit");
        assert_eq!(r.args["depth"], 3);
        let r = req(&["ui"]);
        assert!(!r.args.contains_key("app"));
        let r = req(&["setvalue", "0.1", "-x-", "--app", "Notes"]);
        assert_eq!(r.cmd, "set_value");
        assert_eq!(r.args["value"], "-x-");
    }

    #[test]
    fn screenshot_defaults() {
        let cli = parse(&["screenshot", "--max-width", "800"]).unwrap();
        match to_action(&cli.command).unwrap() {
            Action::Screenshot { req, dest, force } => {
                assert_eq!(req.args["display"], 0);
                assert_eq!(req.args["max_width"], 800);
                assert_eq!(req.args["native"], false);
                assert!(!force);
                let d = dest.unwrap();
                assert!(d.is_absolute());
                assert!(d.file_name().unwrap().to_string_lossy().starts_with("macinto-"));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn usage_errors() {
        for bad in [
            &["click", "10"][..],
            &["click", "x", "y"],
            &["type"],
            &["key"],
            &["scroll", "1.5", "2"],
            &["record"],
            &["record", "pause"],
            &["nonsense"],
            &["wait"],
        ] {
            let e = parse(bad).expect_err(&format!("{bad:?} should fail"));
            assert_eq!(e.exit_code(), 2, "{bad:?}");
        }
        let cli = parse(&["wait", "99999"]).unwrap();
        assert_eq!(to_action(&cli.command).unwrap_err().exit_code(), 2);
    }

    #[test]
    fn dev_flag() {
        assert!(parse(&["--dev", "status"]).unwrap().dev);
        assert!(parse(&["status", "--dev"]).unwrap().dev);
        assert!(!parse(&["status"]).unwrap().dev);
    }

    #[test]
    fn no_launch_flag_and_env() {
        assert!(parse(&["--no-launch", "status"]).unwrap().no_launch);
        assert!(parse(&["apps", "--no-launch", "--dev"]).unwrap().no_launch);
        // The only test that touches MACINTO_NO_LAUNCH.
        std::env::remove_var("MACINTO_NO_LAUNCH");
        assert!(!parse(&["status"]).unwrap().no_launch);
        for (val, want) in [("1", true), ("true", true), ("yes", true), ("0", false), ("false", false)] {
            std::env::set_var("MACINTO_NO_LAUNCH", val);
            assert_eq!(parse(&["status"]).unwrap().no_launch, want, "MACINTO_NO_LAUNCH={val}");
        }
        std::env::remove_var("MACINTO_NO_LAUNCH");
    }

    #[test]
    fn global_json_flag_anywhere() {
        assert!(parse(&["--json", "status"]).unwrap().json);
        assert!(parse(&["status", "--json"]).unwrap().json);
    }
}
