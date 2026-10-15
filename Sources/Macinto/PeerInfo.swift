import Darwin
import Foundation

/// Who is on the other end of a socket connection, as reported by the kernel.
struct PeerInfo {
    struct Proc { let pid: pid_t; let name: String }

    let pid: pid_t
    /// The peer process and up to three distinct ancestors, nearest first (e.g. nc, macinto.sh, claude, zsh).
    let chain: [Proc]

    /// Process names that are plumbing rather than the real caller.
    private static let plumbing: Set<String> = ["nc", "macinto.sh", "bash", "sh", "zsh", "env"]

    /// The first ancestor that is not nc/bash/macinto.sh, for the menu's action list.
    var caller: Proc {
        chain.first { !Self.plumbing.contains($0.name) } ?? chain.last ?? Proc(pid: pid, name: "?")
    }

    var chainDescription: String {
        chain.map { "\($0.name)[\($0.pid)]" }.joined(separator: " <- ")
    }

    static func of(socket fd: Int32) -> PeerInfo {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0 { pid = -1 }
        var chain: [Proc] = []
        var cur = pid
        var steps = 0
        // Walk up to 12 ancestors; collapse runs of the same name (bash subshells), keep 4 entries.
        while cur > 1 && chain.count < 4 && steps < 12 {
            steps += 1
            let name = displayName(cur)
            if chain.last?.name != name { chain.append(Proc(pid: cur, name: name)) }
            guard let parent = parentPID(cur), parent != cur else { break }
            cur = parent
        }
        return PeerInfo(pid: pid, chain: chain)
    }

    static func peerUID(socket fd: Int32) -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Process name; for script interpreters, the script's file name instead (bash running macinto.sh -> "macinto.sh").
    static func displayName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        let name = n > 0 ? String(cString: buf) : "?"
        let interpreters: Set<String> = ["bash", "sh", "zsh", "dash", "python", "python3", "node", "ruby", "perl"]
        if interpreters.contains(name), let args = arguments(pid), args.count >= 2 {
            if let script = args.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                let base = (script as NSString).lastPathComponent
                if !base.isEmpty { return base }
            }
        }
        return name
    }

    /// argv of another process via KERN_PROCARGS2 (same user only).
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while i < size && args.count < Int(argc) {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }
}
