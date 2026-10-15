import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openSettings("Privacy_Accessibility")
    }

    static func promptScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openSettings("Privacy_ScreenCapture")
        }
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static let accessibilityError =
        "Accessibility permission is missing. Grant it in System Settings > Privacy & Security > Accessibility (enable Macinto), or use the Grant button in the Macinto menu."
    static let screenRecordingError =
        "Screen Recording permission is missing. Grant it in System Settings > Privacy & Security > Screen & System Audio Recording (enable Macinto), then quit and reopen Macinto."
}
