import Foundation

/// A JSON value, used for request arguments and response data on the socket.
enum JSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d.isFinite ? d : 0)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral v: String) { self = .string(v) }
    init(integerLiteral v: Int) { self = .int(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(floatLiteral v: Double) { self = .double(v) }
    init(arrayLiteral v: JSON...) { self = .array(v) }
    init(dictionaryLiteral v: (String, JSON)...) { self = .object(Dictionary(v, uniquingKeysWith: { $1 })) }
    init(nilLiteral: ()) { self = .null }
}

extension JSON {
    static func str(_ s: String?) -> JSON { s.map { .string($0) } ?? .null }
    static func num(_ d: CGFloat) -> JSON {
        let r = (Double(d) * 100).rounded() / 100
        return r == r.rounded() && abs(r) < 1e15 ? .int(Int(r)) : .double(r)
    }
    static func rect(_ r: CGRect) -> JSON {
        ["x": num(r.minX), "y": num(r.minY), "width": num(r.width), "height": num(r.height)]
    }
    static func point(_ p: CGPoint) -> JSON { ["x": num(p.x), "y": num(p.y)] }
}

/// One request per connection: `{"cmd": "click", "args": {"x": 10, "y": 20}}` followed by a newline.
struct Request: Decodable {
    let cmd: String
    let args: [String: JSON]?
}

/// `{"ok": true, "data": {...}}` or `{"ok": false, "code": "disabled", "error": "..."}`.
struct Response: Encodable, Sendable {
    var ok: Bool
    var data: JSON?
    var code: String?
    var error: String?
    /// For code "permission": "accessibility" or "screen_recording".
    var permission: String?

    static func ok(_ data: JSON = .object([:])) -> Response { Response(ok: true, data: data) }
    static func error(_ message: String, code: String = "failed", permission: String? = nil) -> Response {
        Response(ok: false, code: code, error: message, permission: permission)
    }

    var serialized: Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var d = (try? enc.encode(self)) ?? Data(#"{"ok":false,"code":"failed","error":"could not encode response"}"#.utf8)
        d.append(0x0A)
        return d
    }

    var summary: String { ok ? "ok" : "error(\(code ?? "?")): \(error ?? "")" }
}

/// Error with a protocol error code. Codes: usage, disabled, permission, not_found, bad_request, failed.
struct CommandError: Error {
    let code: String
    let message: String
    var permission: String? = nil

    static func usage(_ m: String) -> CommandError { CommandError(code: "usage", message: m) }
    static func notFound(_ m: String) -> CommandError { CommandError(code: "not_found", message: m) }
    static func failed(_ m: String) -> CommandError { CommandError(code: "failed", message: m) }
}

/// Typed access to request arguments. Wrong types are usage errors.
struct Args {
    let raw: [String: JSON]
    init(_ raw: [String: JSON]?) { self.raw = raw ?? [:] }

    func optDouble(_ k: String) throws -> Double? {
        guard let v = raw[k], v != .null else { return nil }
        guard let d = v.doubleValue else { throw CommandError.usage("'\(k)' must be a number") }
        return d
    }
    func double(_ k: String) throws -> Double {
        guard let d = try optDouble(k) else { throw CommandError.usage("missing '\(k)'") }
        return d
    }
    func int(_ k: String, default d: Int) throws -> Int {
        guard let v = try optDouble(k) else { return d }
        guard v == v.rounded(), abs(v) < 1e9 else { throw CommandError.usage("'\(k)' must be an integer") }
        return Int(v)
    }
    func optString(_ k: String) throws -> String? {
        guard let v = raw[k], v != .null else { return nil }
        guard case .string(let s) = v else { throw CommandError.usage("'\(k)' must be a string") }
        return s
    }
    func string(_ k: String) throws -> String {
        guard let s = try optString(k) else { throw CommandError.usage("missing '\(k)'") }
        return s
    }
    func bool(_ k: String) throws -> Bool {
        guard let v = raw[k], v != .null else { return false }
        guard case .bool(let b) = v else { throw CommandError.usage("'\(k)' must be true or false") }
        return b
    }
    func strings(_ k: String) throws -> [String] {
        guard let v = raw[k], v != .null else { return [] }
        guard case .array(let a) = v else { throw CommandError.usage("'\(k)' must be an array of strings") }
        return try a.map {
            guard case .string(let s) = $0 else { throw CommandError.usage("'\(k)' must be an array of strings") }
            return s
        }
    }
    func point(_ xk: String = "x", _ yk: String = "y") throws -> CGPoint {
        CGPoint(x: try double(xk), y: try double(yk))
    }

    /// Short form for the log and the menu: `x=10 y=20 text="hi"`.
    var logDescription: String {
        raw.keys.sorted().map { k in
            let v: String
            switch raw[k]! {
            case .string(let s): v = "\"\(s)\""
            case .int(let i): v = String(i)
            case .double(let d): v = String(d)
            case .bool(let b): v = String(b)
            case .null: v = "null"
            case .array(let a): v = "[\(a.count)]"
            case .object: v = "{…}"
            }
            return "\(k)=\(AXTree.clip(v, 80))"
        }.joined(separator: " ")
    }
}
