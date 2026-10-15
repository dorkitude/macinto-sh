import AppKit
import AVFoundation
import ImageIO
import MacintoGeometry
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshots via ScreenCaptureKit. Macinto's own windows (the apple overlay) are always excluded.
enum Capture {
    struct Failure: Error { let message: String }

    struct DisplayInfo {
        let index: Int
        let id: CGDirectDisplayID
        let frame: CGRect      // global points, top-left origin
        let scale: CGFloat
        let isMain: Bool
    }

    /// Active displays, main display first, then left to right.
    static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        let sorted = ids.sorted { a, b in
            if a == main { return true }
            if b == main { return false }
            return CGDisplayBounds(a).minX < CGDisplayBounds(b).minX
        }
        return sorted.enumerated().map { i, id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = mode.map { CGFloat($0.pixelWidth) / max(1, CGFloat($0.width)) } ?? 1
            return DisplayInfo(index: i, id: id, frame: bounds, scale: scale, isMain: id == main)
        }
    }

    static func displaysJSON() -> [JSON] {
        displays().map { d in
            ["index": .int(d.index), "id": .int(Int(d.id)), "x": .num(d.frame.minX), "y": .num(d.frame.minY),
             "width": .num(d.frame.width), "height": .num(d.frame.height), "scale": .num(d.scale), "main": .bool(d.isMain)]
        }
    }

    static func requirePermission() throws {
        guard Permissions.screenRecording else { throw Permissions.missing(.screenRecording) }
    }

    static func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Permissions.missing(.screenRecording, detail: "ScreenCaptureKit refused (\(error.localizedDescription))")
        }
    }

    /// Build a content filter for display N, optionally restricted to one app, excluding Macinto itself.
    static func filter(displayIndex: Int, appName: String?) async throws -> (SCContentFilter, DisplayInfo, SCDisplay) {
        let t = try await target(displayIndex: displayIndex, appName: appName)
        return (t.filter, t.info, t.display)
    }

    struct Target {
        let filter: SCContentFilter
        let info: DisplayInfo
        let display: SCDisplay
        /// With an app: its display name and the frames (global points) of its on-screen windows.
        let appName: String?
        let windowFrames: [CGRect]
    }

    static func target(displayIndex: Int, appName: String?) async throws -> Target {
        let infos = displays()
        guard displayIndex >= 0 && displayIndex < infos.count else {
            throw Failure(message: "no display \(displayIndex) (have 0...\(infos.count - 1); see 'macinto.sh status')")
        }
        let info = infos[displayIndex]
        let content = try await content()
        guard let display = content.displays.first(where: { $0.displayID == info.id }) else {
            throw Failure(message: "display \(displayIndex) is not capturable")
        }
        if let appName {
            guard let running = Apps.find(appName) else { throw Failure(message: "no running app matches '\(appName)'") }
            let name = running.localizedName ?? appName
            let pid = running.processIdentifier
            // Status-bar items are windows too; leave them out so a menu bar extra doesn't stretch the crop.
            let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
            let frames = content.windows
                .filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer != statusLevel }
                .map(\.frame)
                .filter { $0.width > 1 && $0.height > 1 }
            let apps = content.applications.filter { $0.processID == pid }
            guard !apps.isEmpty, !frames.isEmpty else { throw Failure(message: "\(name) has no visible windows to capture") }
            return Target(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []),
                          info: info, display: display, appName: name, windowFrames: frames)
        }
        let me = content.applications.filter { $0.processID == getpid() }
        return Target(filter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
                      info: info, display: display, appName: nil, windowFrames: [])
    }

    static func newCaptureURL(ext: String) throws -> URL {
        try Paths.ensurePrivateDir(Paths.captures)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "macinto-\(f.string(from: Date()))-\(UUID().uuidString.prefix(6)).\(ext)"
        return Paths.captures.appendingPathComponent(name)
    }

    /// A tiny throwaway capture of the main display, made once during setup. macOS asks the user to
    /// allow apps that capture directly (without the system window picker); doing one capture here
    /// makes that prompt appear in setup instead of during an agent's first screenshot.
    static func setupTestCapture() async -> String? {
        do {
            let (filter, _, _) = try await filter(displayIndex: 0, appName: nil)
            let config = SCStreamConfiguration()
            config.width = 64
            config.height = 40
            config.capturesAudio = false
            _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Capture a PNG. By default it is scaled to points so image pixels == click coordinates
    /// (offset by `origin`). With an app, the image is cropped to the union of that app's windows on
    /// the display plus a small margin. `maxWidth` > 0 scales the image down (keeping aspect) so it
    /// is at most that many pixels wide. Pixel (px, py) is clicked at origin + (px, py) / scale.
    static func screenshot(displayIndex: Int, appName: String?, nativeResolution: Bool, maxWidth: Int) async throws -> JSON {
        try requirePermission()
        let t = try await target(displayIndex: displayIndex, appName: appName)
        let info = t.info
        var rect = info.frame
        if let name = t.appName {
            guard let crop = CaptureGeometry.cropRect(windows: t.windowFrames, display: info.frame) else {
                throw Failure(message: "\(name) has no visible windows to capture on display \(displayIndex) (try --display)")
            }
            rect = crop
        }
        let scale = CaptureGeometry.scale(width: rect.width, native: nativeResolution, displayScale: info.scale, maxWidth: maxWidth)
        let size = CaptureGeometry.pixelSize(rect, scale: scale)
        let config = SCStreamConfiguration()
        if rect != info.frame {
            // sourceRect is in the display's own point space (top-left origin).
            config.sourceRect = rect.offsetBy(dx: -info.frame.minX, dy: -info.frame.minY)
        }
        config.width = size.width
        config.height = size.height
        config.showsCursor = true
        config.capturesAudio = false
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: t.filter, configuration: config)
        } catch {
            throw Failure(message: "screenshot failed: \(error.localizedDescription)")
        }
        let url = try newCaptureURL(ext: "png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "could not create \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "could not write \(url.path)") }
        // Image pixels per point, from the image actually returned.
        let actual = CGFloat(image.width) / max(1, rect.width)
        var o: [String: JSON] = [
            "path": .string(url.path),
            "width": .int(image.width),
            "height": .int(image.height),
            // Global top-left points of the image's top-left pixel. Click (origin.x + px/scale, origin.y + py/scale).
            "origin": ["x": .num(rect.minX), "y": .num(rect.minY)],
            "scale": .num(actual),
            "display": .int(displayIndex),
            "cropped": .bool(rect != info.frame),
            // Older name for scale.
            "pixels_per_point": .num(actual),
        ]
        if let name = t.appName { o["app"] = .string(name) }
        return .object(o)
    }
}

/// Screen recording via SCRecordingOutput (macOS 15+). One recording at a time.
@MainActor
final class Recorder: NSObject {
    static let shared = Recorder()

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private(set) var fileURL: URL?
    private(set) var destination: String = ""
    private(set) var force = false
    private(set) var startedAt: Date?
    private(set) var lastFinished: (url: URL, dest: String, force: Bool)?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var finished = false
    private var failure: String?

    var isRecording: Bool { stream != nil }

    func start(displayIndex: Int, destination: String, force: Bool) async throws -> JSON {
        guard !isRecording else { throw Capture.Failure(message: "already recording (run 'macinto.sh record stop')") }
        try Capture.requirePermission()
        let (filter, info, _) = try await Capture.filter(displayIndex: displayIndex, appName: nil)
        let config = SCStreamConfiguration()
        config.width = Int(info.frame.width * info.scale)
        config.height = Int(info.frame.height * info.scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.queueDepth = 6

        let url = try Capture.newCaptureURL(ext: "mov")
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mov
        rc.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: rc, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            throw Capture.Failure(message: "could not start recording: \(error.localizedDescription)")
        }
        self.stream = stream
        self.output = output
        self.fileURL = url
        self.destination = destination
        self.force = force
        self.startedAt = Date()
        self.finished = false
        self.failure = nil
        AppState.shared.recordingActive = true
        return ["recording": true, "path": .string(url.path), "dest": .string(destination)]
    }

    /// Stop and finalize. Returns the temporary file path plus where the CLI should move it.
    func stop() async throws -> JSON {
        guard let stream, let url = fileURL else { throw Capture.Failure(message: "not recording") }
        let started = startedAt ?? Date()
        do { try await stream.stopCapture() } catch {
            // Stream may already have stopped (e.g. display went away); continue to finalize.
        }
        if !finished {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                finishWaiters.append(c)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self.resumeWaiters()
                }
            }
        }
        if let o = output { try? stream.removeRecordingOutput(o) }
        let result = (url: url, dest: destination, force: force)
        lastFinished = result
        reset()
        if let failure { throw Capture.Failure(message: "recording failed: \(failure)") }
        return [
            "path": .string(url.path),
            "dest": .string(result.dest),
            "force": .bool(result.force),
            "duration": .num(Date().timeIntervalSince(started)),
        ]
    }

    func status() -> JSON {
        var o: [String: JSON] = ["recording": .bool(isRecording)]
        if isRecording, let url = fileURL, let s = startedAt {
            o["elapsed"] = .num(Date().timeIntervalSince(s))
            o["path"] = .string(url.path)
            o["dest"] = .string(destination)
        } else if let last = lastFinished {
            o["last"] = ["path": .string(last.url.path), "dest": .string(last.dest)]
        }
        return .object(o)
    }

    private func reset() {
        stream = nil
        output = nil
        fileURL = nil
        startedAt = nil
        AppState.shared.recordingActive = false
    }

    private func resumeWaiters() {
        finished = true
        let w = finishWaiters
        finishWaiters = []
        w.forEach { $0.resume() }
    }
}

extension Recorder: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeWaiters() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            self.failure = msg
            self.resumeWaiters()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            ActionLog.shared.write(event: "recording stream stopped: \(msg)")
            if self.isRecording { _ = try? await self.stop() }
        }
    }
}
