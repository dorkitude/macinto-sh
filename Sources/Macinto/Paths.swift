import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// ~/Library/Application Support/macinto (mode 0700)
    static let supportDir = home.appendingPathComponent("Library/Application Support/macinto", isDirectory: true)
    static let socket = supportDir.appendingPathComponent("macinto.sock")
    /// Screenshots and recordings are written here first; the CLI moves them to their destination.
    static let captures = supportDir.appendingPathComponent("captures", isDirectory: true)
    static let log = home.appendingPathComponent("Library/Logs/macinto.log")

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Create a directory (and parents) and force it to mode 0700.
    static func ensurePrivateDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
