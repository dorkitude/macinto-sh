import AppKit

/// Parsed command arguments: positionals plus --flags (with or without values).
struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]

    /// `valued` lists flags that take a value (e.g. --app NAME).
    init(_ raw: [String], valued: Set<String> = []) throws {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") && a.count > 2 {
                let name = String(a.dropFirst(2))
                if valued.contains(name) {
                    guard i + 1 < raw.count else { throw Commands.Usage(message: "--\(name) needs a value") }
                    flags[name] = raw[i + 1]
                    i += 2
                    continue
                }
                flags[name] = ""
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func has(_ f: String) -> Bool { flags[f] != nil }

    func int(_ f: String, default d: Int) throws -> Int {
        guard let v = flags[f] else { return d }
        guard let n = Int(v) else { throw Commands.Usage(message: "--\(f) expects an integer, got '\(v)'") }
        return n
    }
}

enum Commands {
    struct Usage: Error { let message: String }

    /// Commands that work while disabled (read-only, no screen or input access).
    static let allowedWhileDisabled: Set<String> = ["status", "version", "ping"]

    static func handle(_ command: String, _ rawArgs: [String], _ peer: PeerInfo) async -> Response {
        let response = await dispatch(command, rawArgs)
        let logged = ([command] + rawArgs.map { AXTree.clip($0, 80) }).joined(separator: " ")
        ActionLog.shared.write(pid: peer.pid, chain: peer.chainDescription, command: logged, result: response.summary)
        if command != "status" && command != "ping" {
            let caller = peer.caller
            await MainActor.run {
                AppState.shared.record(ActionRecord(time: Date(), caller: caller.name, pid: caller.pid,
                                                    command: AXTree.clip(logged, 60), ok: response.ok))
            }
        }
        return response
    }

    private static func dispatch(_ command: String, _ rawArgs: [String]) async -> Response {
        let enabled = await MainActor.run { AppState.shared.enabled }
        if !enabled && !allowedWhileDisabled.contains(command) {
            return .error("macinto is disabled — enable it from the menu bar")
        }
        do {
            return try await run(command, rawArgs)
        } catch let e as Usage {
            return .error("usage: \(e.message)")
        } catch let e as Input.Failure {
            return .error(e.message)
        } catch let e as AXTree.Failure {
            return .error(e.message)
        } catch let e as Apps.Failure {
            return .error(e.message)
        } catch let e as Capture.Failure {
            return .error(e.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func requireAX() throws {
        guard Permissions.accessibility else { throw Input.Failure(message: Permissions.accessibilityError) }
    }

    private static func point(_ p: [String], _ at: Int, usage: String) throws -> CGPoint {
        guard p.count >= at + 2, let x = Double(p[at]), let y = Double(p[at + 1]) else { throw Usage(message: usage) }
        return CGPoint(x: x, y: y)
    }

    private static func run(_ command: String, _ raw: [String]) async throws -> Response {
        switch command {
        case "ping":
            return .ok(["pong"])

        case "version":
            return .ok([Paths.version])

        case "status":
            return .ok(await statusLines())

        case "click":
            let a = try Args(raw)
            let p = try point(a.positional, 0, usage: "click X Y [--right] [--double]")
            try requireAX()
            try Input.click(at: p, right: a.has("right"), count: a.has("double") ? 2 : 1)
            return .ok([String(format: "clicked %.0f,%.0f", p.x, p.y)])

        case "move":
            let a = try Args(raw)
            let p = try point(a.positional, 0, usage: "move X Y")
            try requireAX()
            try Input.move(to: p)
            return .ok()

        case "drag":
            let a = try Args(raw)
            let p1 = try point(a.positional, 0, usage: "drag X1 Y1 X2 Y2")
            let p2 = try point(a.positional, 2, usage: "drag X1 Y1 X2 Y2")
            try requireAX()
            try Input.drag(from: p1, to: p2)
            return .ok()

        case "scroll":
            let a = try Args(raw)
            guard a.positional.count == 2, let dx = Int32(a.positional[0]), let dy = Int32(a.positional[1]) else {
                throw Usage(message: "scroll DX DY (lines; positive DY scrolls up, negative scrolls down)")
            }
            try requireAX()
            try Input.scroll(dx: dx, dy: dy)
            return .ok()

        case "location":
            let p = Input.mouseLocation
            return .ok([String(format: "%.0f %.0f", p.x, p.y)])

        case "type":
            guard raw.count == 1 else { throw Usage(message: "type TEXT (quote it as one argument)") }
            try requireAX()
            try Input.type(raw[0])
            return .ok(["typed \(raw[0].count) characters"])

        case "key":
            guard !raw.isEmpty else { throw Usage(message: "key COMBO [COMBO ...], e.g. cmd+shift+g, return, f5, left") }
            let parsed = try raw.map { try Input.parseCombo($0) }
            try requireAX()
            for (code, flags) in parsed { try Input.key(code: code, flags: flags) }
            return .ok()

        case "keys":
            return .ok(Keys.names)

        case "open":
            guard raw.count == 1 else { throw Usage(message: "open APP (name, bundle id, or .app path)") }
            let a = try await Apps.open(raw[0])
            return .ok(["\(a.processIdentifier)\t\(a.bundleIdentifier ?? "-")\t\(a.localizedName ?? "?")"])

        case "apps":
            return .ok(Apps.listLines())

        case "ui":
            let a = try Args(raw, valued: ["app", "depth"])
            try requireAX()
            return .ok(try AXTree.dump(appName: a.flags["app"], maxDepth: try a.int("depth", default: 12)))

        case "press", "focus":
            let a = try Args(raw, valued: ["app"])
            guard a.positional.count == 1 else { throw Usage(message: "\(command) ID [--app NAME]") }
            try requireAX()
            let id = a.positional[0]
            let line = command == "press" ? try AXTree.press(id, appName: a.flags["app"])
                                          : try AXTree.focus(id, appName: a.flags["app"])
            return .ok([line])

        case "setvalue":
            let a = try Args(raw, valued: ["app"])
            guard a.positional.count == 2 else { throw Usage(message: "setvalue ID TEXT [--app NAME]") }
            try requireAX()
            return .ok([try AXTree.setValue(a.positional[0], a.positional[1], appName: a.flags["app"])])

        case "screenshot":
            let a = try Args(raw, valued: ["display", "app"])
            return .ok(try await Capture.screenshot(displayIndex: try a.int("display", default: 0),
                                                    appName: a.flags["app"], nativeResolution: a.has("native")))

        case "record":
            let a = try Args(raw, valued: ["display", "dest"])
            switch a.positional.first {
            case "start":
                return .ok(try await Recorder.shared.start(displayIndex: try a.int("display", default: 0),
                                                           destination: a.flags["dest"] ?? "",
                                                           force: a.has("force")))
            case "stop":
                return .ok(try await Recorder.shared.stop())
            case "status":
                return .ok(await Recorder.shared.statusLines())
            default:
                throw Usage(message: "record start [-o FILE.mov] [--display N] | record stop | record status")
            }

        default:
            return .error("unknown command '\(command)' (run 'macinto.sh help')")
        }
    }

    @MainActor
    static func statusLines() -> [String] {
        let s = AppState.shared
        s.refreshPermissions()
        var lines = [
            "enabled: \(s.enabled ? "yes" : "no")",
            "remaining: \(s.enabled ? (s.remainingSeconds.map(String.init) ?? "∞") : "-")",
            "accessibility: \(s.accessibilityGranted ? "granted" : "missing")",
            "screen_recording: \(s.screenRecordingGranted ? "granted" : "missing")",
            "version: \(Paths.version)",
            "recording: \(Recorder.shared.isRecording ? "yes" : "no")",
        ]
        if let d = AppDelegate.current {
            lines.append("status_item: \(d.statusItemDescription)")
            lines.append("overlay: \(d.overlay.isVisible ? "visible" : "hidden")\(d.overlay.isVisible ? " at \(d.overlay.frameDescription)" : "")")
        }
        lines += Capture.displayLines()
        return lines
    }
}
