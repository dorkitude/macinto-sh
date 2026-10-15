import Darwin
import Foundation

/// Line protocol over a Unix domain socket. One request per connection:
///   request:  `<command> <base64 arg> <base64 arg> ...\n`   ("-" encodes an empty argument)
///   response: `ok\n<payload lines>` or `error <message>\n`
final class SocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ command: String, _ args: [String], _ peer: PeerInfo) async -> Response

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private static let maxRequestBytes = 4 * 1024 * 1024

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    enum StartError: Error, CustomStringConvertible {
        case alreadyRunning, sys(String)
        var description: String {
            switch self {
            case .alreadyRunning: return "another Macinto instance is already listening on the socket"
            case .sys(let s): return s
            }
        }
    }

    func start() throws {
        try Paths.ensurePrivateDir(Paths.supportDir)

        if FileManager.default.fileExists(atPath: path) {
            if Self.canConnect(path) { throw StartError.alreadyRunning }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.sys("socket(): \(String(cString: strerror(errno)))") }
        var addr = try Self.address(path)

        // Create the socket node with 0600 from the start (no window where it is group/world accessible).
        let oldMask = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard rc == 0 else {
            close(fd)
            throw StartError.sys("bind(\(path)): \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw StartError.sys("listen(): \(String(cString: strerror(errno)))")
        }
        listenFD = fd

        let thread = Thread { [self] in acceptLoop() }
        thread.name = "macinto.accept"
        thread.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Only the user who owns this app may talk to it (the 0600 socket mode already enforces this).
        guard PeerInfo.peerUID(socket: fd) == getuid() else {
            Self.send(fd, Response.error("permission denied"))
            close(fd)
            return
        }
        let peer = PeerInfo.of(socket: fd)

        guard let line = Self.readLine(fd) else {
            Self.send(fd, .error("bad request: expected one line terminated by a newline"))
            close(fd)
            return
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let command = parts.first else {
            Self.send(fd, .error("bad request: empty command"))
            close(fd)
            return
        }
        var args: [String] = []
        for p in parts.dropFirst() {
            if p == "-" { args.append(""); continue }
            guard let d = Data(base64Encoded: p), let s = String(data: d, encoding: .utf8) else {
                Self.send(fd, .error("bad request: arguments must be base64-encoded UTF-8"))
                close(fd)
                return
            }
            args.append(s)
        }

        let handler = self.handler
        Task.detached {
            let response = await handler(command, args, peer)
            Self.send(fd, response)
            close(fd)
        }
    }

    private static func readLine(_ fd: Int32) -> String? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while data.count < maxRequestBytes {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if let nl = data.firstIndex(of: 0x0A) {
                return String(data: data[data.startIndex..<nl], encoding: .utf8)
            }
        }
        return nil
    }

    private static func send(_ fd: Int32, _ r: Response) {
        let bytes = Array(r.serialized.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            off += n
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { throw StartError.sys("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = try? address(path) else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}

struct Response: Sendable {
    var ok: Bool
    var message: String
    var lines: [String]

    static func ok(_ lines: [String] = []) -> Response { Response(ok: true, message: "", lines: lines) }
    static func error(_ message: String) -> Response { Response(ok: false, message: message, lines: []) }

    var serialized: String {
        if ok {
            return (["ok"] + lines).joined(separator: "\n") + "\n"
        }
        let msg = message.replacingOccurrences(of: "\n", with: " ")
        return "error \(msg)\n"
    }

    var summary: String { ok ? "ok" : "error: \(message)" }
}
