import AppKit

enum Apps {
    struct Failure: Error { let message: String }

    static var regular: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    /// Match a running app by name (case-insensitive), bundle id, or pid.
    static func find(_ query: String) -> NSRunningApplication? {
        let q = query.lowercased()
        let all = NSWorkspace.shared.runningApplications
        if let pid = Int32(query), let a = all.first(where: { $0.processIdentifier == pid }) { return a }
        return all.first { $0.bundleIdentifier?.lowercased() == q }
            ?? regular.first { $0.localizedName?.lowercased() == q }
            ?? all.first { $0.localizedName?.lowercased() == q }
            ?? regular.first { $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == q }
    }

    static func json(_ a: NSRunningApplication, frontmost: Bool) -> JSON {
        ["pid": .int(Int(a.processIdentifier)), "bundle_id": .str(a.bundleIdentifier),
         "name": .str(a.localizedName), "frontmost": .bool(frontmost)]
    }

    static func list() -> [JSON] {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return regular.map { json($0, frontmost: $0.processIdentifier == front) }
    }

    /// Locate an application bundle by bundle id or name.
    static func url(for query: String) -> URL? {
        let ws = NSWorkspace.shared
        if query.contains("."), let u = ws.urlForApplication(withBundleIdentifier: query) { return u }
        if let running = find(query), let u = running.bundleURL { return u }
        let name = query.hasSuffix(".app") ? query : query + ".app"
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", "/System/Library/CoreServices",
                    NSHomeDirectory() + "/Applications"]
        let fm = FileManager.default
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
            // case-insensitive pass
            if let items = try? fm.contentsOfDirectory(atPath: d),
               let hit = items.first(where: { $0.lowercased() == name.lowercased() }) {
                return URL(fileURLWithPath: (d as NSString).appendingPathComponent(hit))
            }
        }
        if query.hasPrefix("/"), fm.fileExists(atPath: query) { return URL(fileURLWithPath: query) }
        return nil
    }

    /// Launch (if needed) and activate an app. Returns the running app.
    static func open(_ query: String) async throws -> NSRunningApplication {
        guard let url = url(for: query) else {
            throw Failure(message: "no application found for '\(query)' (try the exact app name or bundle id)")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            throw Failure(message: "could not open \(url.path): \(error.localizedDescription)")
        }
    }
}
