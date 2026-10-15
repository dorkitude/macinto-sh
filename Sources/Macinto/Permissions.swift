import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

enum Permissions {
    enum Kind: String { case accessibility, screenRecording = "screen_recording" }

    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func promptAccessibility() {
        ActionLog.shared.write(event: "setup: accessibility button clicked")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openSettings("Privacy_Accessibility")
    }

    static func promptScreenRecording() {
        ActionLog.shared.write(event: "setup: screen recording button clicked")
        // On current macOS, CGRequestScreenCaptureAccess alone doesn't reliably add the app to the
        // Screen & System Audio Recording list; a real ScreenCaptureKit request does. Make one so the
        // app shows up there (and macOS shows its prompt), then open the pane.
        _ = CGRequestScreenCaptureAccess()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, error in
            ActionLog.shared.write(event: "setup: ScreenCaptureKit registration request: \(error.map { "\($0.localizedDescription)" } ?? "ok")")
            DispatchQueue.main.async { openSettings("Privacy_ScreenCapture") }
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
        "Accessibility permission is missing. Grant it in System Settings > Privacy & Security > Accessibility (enable Macinto.sh), or open Macinto.sh and use its setup screen."
    static let screenRecordingError =
        "Screen Recording permission is missing. Grant it in System Settings > Privacy & Security > Screen & System Audio Recording (enable Macinto.sh), then relaunch Macinto.sh."
}
