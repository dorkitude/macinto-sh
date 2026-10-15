import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// ~/Library/Application Support/macinto (mode 0700)
    static let supportDir = home.appendingPathComponent("Library/Application Support/macinto", isDirectory: true)
    #if DEBUG
    /// Dev builds (bundle id com.dorkitude.macinto.sh.dev) use their own socket and log, so they can never be
    /// mistaken for the release app. Target them with `macinto.sh --dev`.
    static let socket = supportDir.appendingPathComponent("macinto-dev.sock")
    static let log = home.appendingPathComponent("Library/Logs/macinto-dev.log")
    static let displayName = "Macinto.sh (Dev)"
    /// The CLI command that opens this app's window (`open -a` can't find a name ending in ".sh").
    static let setupCommand = "macinto.sh --dev setup"
    #else
    static let socket = supportDir.appendingPathComponent("macinto.sock")
    static let log = home.appendingPathComponent("Library/Logs/macinto.log")
    static let displayName = "Macinto.sh"
    static let setupCommand = "macinto.sh setup"
    #endif
    /// Name shown in the setup screen and controls. Snapshot renders use the release name.
    nonisolated(unsafe) static var uiName = displayName
    /// `setupCommand` as shown in the UI. Snapshot renders use the release command.
    nonisolated(unsafe) static var uiSetupCommand = setupCommand
    /// Screenshots and recordings are written here first; the CLI moves them to their destination.
    static let captures = supportDir.appendingPathComponent("captures", isDirectory: true)

    /// The Rust CLI inside the bundle.
    static var bundledCLI: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macinto.sh") }

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
