import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

enum Permissions {
    enum Kind: String { case accessibility, screenRecording = "screen_recording" }

    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// First click: macOS's own prompt (it has an "Open System Settings" button), nothing else.
    /// Later clicks: just open the pane. Never both at once.
    static func promptAccessibility(firstAttempt: Bool) {
        ActionLog.shared.write(event: "setup: accessibility button clicked (\(firstAttempt ? "prompt" : "open settings"))")
        if firstAttempt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        } else {
            openSettings("Privacy_Accessibility")
        }
    }

    /// First click: one ScreenCaptureKit request. That is what adds Macinto.sh to the Screen & System
    /// Audio Recording list on current macOS, and macOS shows its own prompt with an "Open System
    /// Settings" button. (ScreenCaptureKit reports "declined" right away while that prompt is still
    /// up, so the result is only logged.) Later clicks: just open the pane. Never both at once.
    @MainActor static func promptScreenRecording(firstAttempt: Bool, done: @escaping @MainActor () -> Void) {
        ActionLog.shared.write(event: "setup: screen recording button clicked (\(firstAttempt ? "request" : "open settings"))")
        guard firstAttempt else {
            openSettings("Privacy_ScreenCapture")
            done()
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, error in
            ActionLog.shared.write(event: "setup: ScreenCaptureKit request returned: \(error.map { $0.localizedDescription } ?? "ok")")
            Task { @MainActor in done() }
        }
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func missing(_ kind: Kind, detail: String? = nil) -> CommandError {
        let msg = kind == .accessibility ? accessibilityError : screenRecordingError
        return CommandError(code: "permission", message: detail.map { "\($0). \(msg)" } ?? msg, permission: kind.rawValue)
    }

    static let accessibilityError =
        "Accessibility permission is missing. Grant it in System Settings > Privacy & Security > Accessibility (enable Macinto.sh), or run `macinto.sh setup` and use its setup screen."
    static let screenRecordingError =
        "Screen Recording permission is missing. Grant it in System Settings > Privacy & Security > Screen & System Audio Recording (enable Macinto.sh), then relaunch Macinto.sh."
}
