import AppKit

/// Puts the bundled CLI (Contents/Helpers/macinto.sh) on PATH as a symlink.
///
/// Homebrew installs (`brew install --cask dorkitude/tap/macinto-sh`) already link it into
/// Homebrew's bin; the footer then shows "CLI installed ✓". Otherwise Install CLI links
/// /usr/local/bin/macinto.sh with one admin prompt, or ~/.local/bin/macinto.sh if that's cancelled.
/// It never writes into /opt/homebrew (that tree belongs to Homebrew).
@MainActor
enum CLIInstaller {
    static let systemLink = "/usr/local/bin/macinto.sh"
    static var userBin: String { Paths.home.appendingPathComponent(".local/bin").path }

    /// Places where a `macinto.sh` on PATH usually lives.
    static var searchedLinks: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", userBin, Paths.home.appendingPathComponent("bin").path]
            .map { $0 + "/macinto.sh" }
    }

    /// The first of `searchedLinks` that resolves (through symlinks) to this bundle's CLI.
    static func installedLink() -> String? {
        let target = Paths.bundledCLI.resolvingSymlinksInPath().path
        return searchedLinks.first { link in
            FileManager.default.fileExists(atPath: link)
                && URL(fileURLWithPath: link).resolvingSymlinksInPath().path == target
        }
    }

    static func install() {
        let cli = Paths.bundledCLI
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            alert("macinto.sh is missing from the app bundle (\(cli.path)).", style: .critical)
            return
        }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            alert("Move Macinto.sh.app to /Applications first, then open it from there and try again. (macOS is running it from a temporary read-only location.)", style: .warning)
            return
        }
        defer { AppState.shared.refreshCLIInstalled() }
        if let link = installedLink() {
            alert("Already installed: \(link)\n→ \(cli.path)", style: .informational)
            return
        }

        let shell = "mkdir -p /usr/local/bin && ln -sfn \(quote(cli.path)) \(quote(systemLink))"
        let source = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", source])
        if result.status == 0 {
            ActionLog.shared.write(event: "CLI installed: \(systemLink)")
            alert("Installed \(systemLink)\n→ \(cli.path)", style: .informational)
            return
        }
        // Cancelled (osascript error -128) or failed: link into ~/.local/bin instead, no password needed.
        let cancelled = result.stderr.contains("-128")
        ActionLog.shared.write(event: "CLI install to \(systemLink) \(cancelled ? "cancelled" : "failed: \(result.stderr)"); using \(userBin)")
        let link = userBin + "/macinto.sh"
        do {
            try FileManager.default.createDirectory(atPath: userBin, withIntermediateDirectories: true)
            try replaceLink(at: link, to: cli.path)
        } catch {
            alert("Could not create \(link): \(error.localizedDescription)", style: .critical)
            return
        }
        ActionLog.shared.write(event: "CLI installed: \(link)")
        var text = "Installed \(link)\n→ \(cli.path)"
        if !(loginShellPath()?.split(separator: ":").contains { $0 == userBin || $0 == "~/.local/bin" } ?? false) {
            text += "\n\n~/.local/bin is not on your PATH. Add it, e.g. for zsh:\necho 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"
        }
        alert(text, style: .informational)
    }

    /// PATH as the user's login shell sets it (apps don't inherit it). nil if it can't be read in 3 s.
    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__MACINTO_PATH__"
        let r = run(shell, ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 3)
        guard r.status == 0, let a = r.stdout.range(of: marker),
              let b = r.stdout.range(of: marker, range: a.upperBound..<r.stdout.endIndex) else { return nil }
        return String(r.stdout[a.upperBound..<b.lowerBound])
    }

    private struct RunResult { var status: Int32; var stdout: String; var stderr: String }

    private static func run(_ exe: String, _ args: [String], timeout: TimeInterval? = nil) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return RunResult(status: -1, stdout: "", stderr: error.localizedDescription) }
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate(); return RunResult(status: -1, stdout: "", stderr: "timed out") }
        }
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RunResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                         stderr: String(decoding: e, as: UTF8.self))
    }

    private static func replaceLink(at link: String, to target: String) throws {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: link) {
            guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw NSError(domain: "macinto", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(link) exists and is not a symlink; remove it first"])
            }
            try fm.removeItem(atPath: link)
        }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func alert(_ text: String, style: NSAlert.Style) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Command line tool"
        a.informativeText = text
        a.alertStyle = style
        a.runModal()
    }
}
