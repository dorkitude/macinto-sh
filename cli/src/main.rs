//! macinto.sh: command line client and MCP server for Macinto.sh.app.
//! https://github.com/dorkitude/macinto-sh (MIT License)

mod actions;
mod cli;
mod client;
mod files;
mod mcp;
mod output;
mod protocol;

use clap::Parser;
use client::Client;
use std::process::ExitCode;

fn main() -> ExitCode {
    let raw: Vec<String> = std::env::args().collect();
    let json_requested = raw.iter().skip(1).any(|a| a == "--json");
    let parsed = match cli::Cli::try_parse_from(&raw) {
        Ok(c) => c,
        Err(e) => {
            use clap::error::ErrorKind;
            let is_info = matches!(e.kind(), ErrorKind::DisplayHelp | ErrorKind::DisplayVersion);
            if json_requested && !is_info {
                let msg = e.render().to_string();
                // clap's message without the trailing "Usage: ..." / "For more information" lines.
                let text: Vec<&str> = msg
                    .lines()
                    .take_while(|l| !l.starts_with("Usage:"))
                    .map(str::trim)
                    .filter(|l| !l.is_empty())
                    .collect();
                let text = text.join(" ");
                let text = text.trim_start_matches("error: ");
                println!("{}", serde_json::json!({"ok": false, "code": "usage", "error": text}));
                return ExitCode::from(2);
            }
            let _ = e.print();
            // Help/version go to stdout with 0; usage errors (and bare `macinto.sh`) exit 2.
            return ExitCode::from(if is_info { 0 } else { 2 });
        }
    };

    let client = Client::new(parsed.socket.clone().or_else(|| parsed.dev.then(client::dev_socket)));
    if parsed.command == cli::Command::Mcp {
        return ExitCode::from(mcp::serve(&client) as u8);
    }

    let result = cli::to_action(&parsed.command).and_then(|a| actions::execute(&client, &a).map(|d| (a, d)));
    match result {
        Ok((action, data)) => {
            if parsed.json {
                println!("{}", serde_json::json!({"ok": true, "data": data}));
            } else {
                let text = output::render(&action.kind(), &data);
                if !text.is_empty() {
                    println!("{text}");
                }
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            if parsed.json {
                println!("{}", e.to_json());
            } else {
                eprintln!("macinto.sh: {}", e.message());
                if e.exit_code() == 2 {
                    eprintln!("Run 'macinto.sh --help' for usage.");
                }
            }
            ExitCode::from(e.exit_code() as u8)
        }
    }
}
