import AppKit

enum Commands {
    /// Commands that work while disabled (read-only, no screen or input access).
    static let allowedWhileDisabled: Set<String> = ["status", "version", "ping", "keys"]

    static func handle(_ request: Request, _ peer: PeerInfo) async -> Response {
        let args = Args(request.args)
        let response = await dispatch(request.cmd, args)
        // `type` text is logged truncated (see README).
        let logged = ([request.cmd] + (args.raw.isEmpty ? [] : [args.logDescription])).joined(separator: " ")
        ActionLog.shared.write(pid: peer.pid, chain: peer.chainDescription, command: logged, result: response.summary)
        if !["status", "ping", "version", "keys"].contains(request.cmd) {
            let caller = peer.caller
            await MainActor.run {
                AppState.shared.record(ActionRecord(time: Date(), caller: caller.name, pid: caller.pid,
                                                    command: AXTree.clip(logged, 60), ok: response.ok))
            }
        }
        return response
    }

    private static func dispatch(_ command: String, _ args: Args) async -> Response {
        let enabled = await MainActor.run { AppState.shared.enabled }
        if !enabled && !allowedWhileDisabled.contains(command) {
            return .error("\(Paths.displayName) is disabled. Enable it from the \(Paths.displayName) menu bar icon (or its control window: open -a '\(Paths.displayName)').",
                          code: "disabled")
        }
        do {
            return .ok(try await run(command, args))
        } catch let e as CommandError {
            return .error(e.message, code: e.code, permission: e.permission)
        } catch let e as Input.Failure {
            return .error(e.message)
        } catch let e as AXTree.Failure {
            return .error(e.message, code: "not_found")
        } catch let e as Apps.Failure {
            return .error(e.message, code: "not_found")
        } catch let e as Capture.Failure {
            return .error(e.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func requireAX() throws {
        guard Permissions.accessibility else { throw Permissions.missing(.accessibility) }
    }

    private static func run(_ command: String, _ a: Args) async throws -> JSON {
        switch command {
        case "ping":
            return ["pong": true]

        case "version":
            return ["version": .string(Paths.version)]

        case "status":
            return await status()

        case "click":
            let p = try a.point()
            let right = try a.optString("button") == "right"
            let count = try a.int("count", default: 1)
            guard (1...3).contains(count) else { throw CommandError.usage("'count' must be 1, 2 or 3") }
            try requireAX()
            try Input.click(at: p, right: right, count: count)
            return ["x": .num(p.x), "y": .num(p.y), "button": right ? "right" : "left", "count": .int(count)]

        case "move":
            let p = try a.point()
            try requireAX()
            try Input.move(to: p)
            return .point(p)

        case "drag":
            let p1 = try a.point("x1", "y1"), p2 = try a.point("x2", "y2")
            try requireAX()
            try Input.drag(from: p1, to: p2)
            return ["from": .point(p1), "to": .point(p2)]

        case "scroll":
            let dx = try a.int("dx", default: 0), dy = try a.int("dy", default: 0)
            guard abs(dx) <= 10_000, abs(dy) <= 10_000 else { throw CommandError.usage("scroll amounts must be within ±10000 lines") }
            try requireAX()
            try Input.scroll(dx: Int32(dx), dy: Int32(dy))
            return ["dx": .int(dx), "dy": .int(dy)]

        case "location":
            return .point(Input.mouseLocation)

        case "type":
            let text = try a.string("text")
            try requireAX()
            try Input.type(text)
            return ["characters": .int(text.count)]

        case "key":
            let combos = try a.strings("combos")
            guard !combos.isEmpty else { throw CommandError.usage("key needs at least one combo, e.g. cmd+shift+g, return, f5, left") }
            let parsed = try combos.map { try Input.parseCombo($0) }
            try requireAX()
            for (code, flags) in parsed { try Input.key(code: code, flags: flags) }
            return ["combos": .array(combos.map { .string($0) })]

        case "keys":
            return ["keys": .array(Keys.names.map { .string($0) })]

        case "open":
            let a = try await Apps.open(try a.string("app"))
            return Apps.json(a, frontmost: true)

        case "apps":
            return ["apps": .array(Apps.list())]

        case "ui":
            try requireAX()
            let depth = try a.int("depth", default: 12)
            guard depth >= 0 else { throw CommandError.usage("'depth' must be >= 0") }
            return try AXTree.dump(appName: try a.optString("app"), maxDepth: depth)

        case "press", "focus":
            let id = try a.string("id")
            try requireAX()
            let el = command == "press" ? try AXTree.press(id, appName: try a.optString("app"))
                                        : try AXTree.focus(id, appName: try a.optString("app"))
            return ["element": el]

        case "set_value":
            let id = try a.string("id"), value = try a.string("value")
            try requireAX()
            return ["element": try AXTree.setValue(id, value, appName: try a.optString("app"))]

        case "screenshot":
            let maxWidth = try a.int("max_width", default: 0)
            guard maxWidth >= 0 else { throw CommandError.usage("'max_width' must be >= 0") }
            return try await Capture.screenshot(displayIndex: try a.int("display", default: 0),
                                                appName: try a.optString("app"),
                                                nativeResolution: try a.bool("native"),
                                                maxWidth: maxWidth)

        case "record_start":
            return try await Recorder.shared.start(displayIndex: try a.int("display", default: 0),
                                                   destination: try a.optString("dest") ?? "",
                                                   force: try a.bool("force"))
        case "record_stop":
            return try await Recorder.shared.stop()
        case "record_status":
            return await Recorder.shared.status()

        default:
            throw CommandError(code: "bad_request", message: "unknown command '\(command)' (is the CLI newer than the app?)")
        }
    }

    @MainActor
    static func status() -> JSON {
        let s = AppState.shared
        s.refreshPermissions()
        var o: [String: JSON] = [
            "enabled": .bool(s.enabled),
            "unlimited": .bool(s.enabled && s.remainingSeconds == nil),
            "remaining_seconds": s.remainingSeconds.map { .int($0) } ?? .null,
            "permissions": ["accessibility": .bool(s.accessibilityGranted),
                            "screen_recording": .bool(s.screenRecordingGranted)],
            "version": .string(Paths.version),
            "recording": .bool(Recorder.shared.isRecording),
            "displays": .array(Capture.displaysJSON()),
        ]
        if let d = AppDelegate.current {
            o["status_item"] = .string(d.statusItemDescription)
            o["overlay"] = ["visible": .bool(d.overlay.isVisible),
                            "frame": d.overlay.isVisible ? d.overlay.frameJSON : .null]
        }
        return .object(o)
    }
}
