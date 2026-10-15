import Foundation

/// Appends one tab-separated line per request to ~/Library/Logs/macinto.log.
final class ActionLog: @unchecked Sendable {
    static let shared = ActionLog()
    private let queue = DispatchQueue(label: "sh.macinto.log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func write(pid: pid_t, chain: String, command: String, result: String) {
        append([String(pid), chain, command, result])
    }

    func write(event: String) {
        append(["-", "macinto", "event", event])
    }

    private func append(_ fields: [String]) {
        let ts = formatter.string(from: Date())
        let line = ([ts] + fields.map(Self.clean)).joined(separator: "\t") + "\n"
        queue.async {
            let url = Paths.log
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
