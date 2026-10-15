import AppKit

/// Symlinks the bundled macinto.sh into /opt/homebrew/bin (if writable) or /usr/local/bin (admin prompt).
@MainActor
enum CLIInstaller {
    static func install() {
        guard let script = Bundle.main.url(forResource: "macinto", withExtension: "sh") else {
            alert("macinto.sh is missing from the app bundle.", style: .critical)
            return
        }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            alert("Move Macinto.app to /Applications first, then open it from there and try again. (macOS is running it from a temporary read-only location.)", style: .warning)
            return
        }
        let fm = FileManager.default
        let brew = "/opt/homebrew/bin"
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: brew, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: brew) {
            let link = brew + "/macinto.sh"
            do {
                try replaceLink(at: link, to: script.path)
                alert("Installed \(link)\n→ \(script.path)", style: .informational)
            } catch {
                alert("Could not create \(link): \(error.localizedDescription)", style: .critical)
            }
            return
        }
        let link = "/usr/local/bin/macinto.sh"
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link), dest == script.path {
            alert("Already installed: \(link)", style: .informational)
            return
        }
        let shell = "mkdir -p /usr/local/bin && ln -sfn \(quote(script.path)) \(quote(link))"
        let source = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            alert("Could not run osascript: \(error.localizedDescription)", style: .critical)
            return
        }
        if p.terminationStatus == 0 {
            alert("Installed \(link)\n→ \(script.path)", style: .informational)
        } else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            alert("Install cancelled or failed. \(msg)", style: .warning)
        }
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
