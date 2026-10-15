//! Wire protocol: newline-delimited JSON, one request per connection.
//!
//! request:  {"cmd": "click", "args": {"x": 10, "y": 20}}\n
//! response: {"ok": true, "data": {...}}\n
//!           {"ok": false, "code": "disabled", "error": "...", "permission": "accessibility"}\n

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub cmd: String,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub args: Map<String, Value>,
}

impl Request {
    pub fn new(cmd: &str) -> Self {
        Request { cmd: cmd.to_string(), args: Map::new() }
    }

    /// Add an argument; `None` values are left out.
    pub fn arg(mut self, key: &str, value: impl Into<Value>) -> Self {
        let v = value.into();
        if !v.is_null() {
            self.args.insert(key.to_string(), v);
        }
        self
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = serde_json::to_vec(self).expect("request serializes");
        out.push(b'\n');
        out
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<String>,
}

impl Response {
    pub fn decode(bytes: &[u8]) -> Result<Response, String> {
        let line = bytes.split(|&b| b == b'\n').find(|l| !l.is_empty()).unwrap_or(&[]);
        if line.is_empty() {
            return Err("empty response".into());
        }
        serde_json::from_slice(line).map_err(|e| format!("malformed response: {e}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn encodes_one_line_with_args() {
        let r = Request::new("click").arg("x", 10.5).arg("y", 20).arg("button", "right");
        let bytes = r.encode();
        assert_eq!(*bytes.last().unwrap(), b'\n');
        assert_eq!(bytes.iter().filter(|&&b| b == b'\n').count(), 1);
        let v: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(v, json!({"cmd": "click", "args": {"x": 10.5, "y": 20, "button": "right"}}));
    }

    #[test]
    fn omits_empty_args_and_nulls() {
        let r = Request::new("status").arg("app", Value::Null);
        assert_eq!(r.encode(), b"{\"cmd\":\"status\"}\n");
    }

    #[test]
    fn newlines_in_text_stay_escaped() {
        let r = Request::new("type").arg("text", "a\nb");
        let bytes = r.encode();
        assert_eq!(bytes.iter().filter(|&&b| b == b'\n').count(), 1);
        let back: Request = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(back.args["text"], "a\nb");
    }

    #[test]
    fn decodes_ok_and_error() {
        let ok = Response::decode(b"{\"ok\":true,\"data\":{\"x\":1}}\n").unwrap();
        assert!(ok.ok);
        assert_eq!(ok.data.unwrap()["x"], 1);
        let err = Response::decode(
            br#"{"ok":false,"code":"permission","error":"Accessibility permission is missing.","permission":"accessibility"}"#,
        )
        .unwrap();
        assert!(!err.ok);
        assert_eq!(err.code.as_deref(), Some("permission"));
        assert_eq!(err.permission.as_deref(), Some("accessibility"));
    }

    #[test]
    fn rejects_garbage() {
        assert!(Response::decode(b"").is_err());
        assert!(Response::decode(b"ok\n").is_err());
    }
}
