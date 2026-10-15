import AppKit
import Combine

struct ActionRecord: Identifiable {
    let id = UUID()
    let time: Date
    let caller: String
    let pid: pid_t
    let command: String
    let ok: Bool
}

/// The one piece of mutable app state: whether macinto is enabled, until when, and what it did recently.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Durations offered by the slider. `nil` is the "∞" notch.
    static let durations: [TimeInterval?] = [5 * 60, 10 * 60, 15 * 60, 30 * 60, 60 * 60,
                                             2 * 3600, 4 * 3600, 8 * 3600, nil]
    static let defaultDurationIndex = 3 // 30 min

    @Published private(set) var enabled = false
    /// When enabled: the expiry time, or nil for "until turned off".
    @Published private(set) var expiresAt: Date?
    @Published var durationIndex = AppState.defaultDurationIndex
    @Published private(set) var now = Date()
    @Published private(set) var recent: [ActionRecord] = []
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenRecordingGranted = false
    @Published var recordingActive = false

    /// Called after every enable/disable so the status item, overlay and recorder can react.
    var onEnabledChange: ((Bool) -> Void)?

    private var timer: Timer?

    private init() {
        refreshPermissions()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var selectedDuration: TimeInterval? {
        Self.durations[min(max(durationIndex, 0), Self.durations.count - 1)]
    }

    var remainingSeconds: Int? {
        guard enabled, let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
    }

    var remainingText: String {
        guard enabled else { return "-" }
        guard let s = remainingSeconds else { return "∞" }
        return Self.format(seconds: s)
    }

    static func label(for duration: TimeInterval?) -> String {
        guard let d = duration else { return "∞" }
        let m = Int(d) / 60
        return m < 60 ? "\(m) min" : "\(m / 60) h"
    }

    static func format(seconds s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    func enable(for duration: TimeInterval?) {
        now = Date()
        expiresAt = duration.map { now.addingTimeInterval($0) }
        enabled = true
        let desc = duration.map { "for \(Int($0))s" } ?? "until turned off"
        ActionLog.shared.write(event: "enabled \(desc)")
        onEnabledChange?(true)
    }

    func disable(reason: String) {
        guard enabled else { return }
        enabled = false
        expiresAt = nil
        ActionLog.shared.write(event: "disabled (\(reason))")
        onEnabledChange?(false)
    }

    func tick() {
        now = Date()
        if enabled, let expiresAt, now >= expiresAt {
            disable(reason: "timer expired")
        }
        refreshPermissions()
    }

    func refreshPermissions() {
        let ax = Permissions.accessibility
        let sc = Permissions.screenRecording
        if ax != accessibilityGranted { accessibilityGranted = ax }
        if sc != screenRecordingGranted { screenRecordingGranted = sc }
    }

    func record(_ r: ActionRecord) {
        recent.insert(r, at: 0)
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
    }
}
