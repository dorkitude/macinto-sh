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

    /// Which screen the control window and popover show.
    enum Screen: Equatable { case onboarding, tutorial, control }
    @Published private(set) var screen: Screen = .onboarding
    /// Set once the user clicks the Screen Recording button; shows the Relaunch button.
    /// Persisted, so after a relaunch a click opens System Settings instead of prompting again.
    @Published var screenRecordingRequested = UserDefaults.standard.bool(forKey: "screenRecordingRequested") {
        didSet { UserDefaults.standard.set(screenRecordingRequested, forKey: "screenRecordingRequested") }
    }
    /// Set once the user clicks the Accessibility button (macOS prompts only the first time).
    @Published var accessibilityRequested = UserDefaults.standard.bool(forKey: "accessibilityRequested") {
        didSet { UserDefaults.standard.set(accessibilityRequested, forKey: "accessibilityRequested") }
    }
    /// A permission request is waiting on macOS; further clicks are ignored until it returns.
    var setupRequestInFlight = false
    /// When the setup screen last appeared. Clicks in the first second are ignored, so a click
    /// meant for something else (e.g. a double-click on Relaunch) can't land on a permission button.
    var setupShownAt = Date.distantPast
    private var lastSetupClick = Date.distantPast

    func setupClickAllowed() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(setupShownAt) >= 1.0, now.timeIntervalSince(lastSetupClick) >= 1.0 else {
            ActionLog.shared.write(event: "setup: click ignored (too soon)")
            return false
        }
        lastSetupClick = now
        return true
    }

    var permissionsOK: Bool { accessibilityGranted && screenRecordingGranted }

    /// Called after every enable/disable so the status item, overlay and recorder can react.
    var onEnabledChange: ((Bool) -> Void)?
    /// Called when a permission goes missing after onboarding (the delegate re-shows the window).
    var onPermissionsLost: (() -> Void)?

    private static let tutorialSeenKey = "tutorialSeen"
    private var tutorialSeen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.tutorialSeenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tutorialSeenKey) }
    }
    /// Pending switch from onboarding (both checkmarks shown) to the next screen.
    private var advanceWork: DispatchWorkItem?

    /// The one-time setup capture (see Capture.setupTestCapture) has run on this Mac.
    @Published private(set) var directCaptureChecked = UserDefaults.standard.bool(forKey: "directCaptureChecked") {
        didSet { UserDefaults.standard.set(directCaptureChecked, forKey: "directCaptureChecked") }
    }
    @Published private(set) var directCaptureRunning = false
    @Published private(set) var directCaptureError: String?

    func runDirectCaptureCheck() {
        guard !directCaptureRunning else { return }
        directCaptureRunning = true
        directCaptureError = nil
        ActionLog.shared.write(event: "setup: test capture (macOS may ask to allow direct screen capture)")
        Task { @MainActor in
            let error = await Capture.setupTestCapture()
            ActionLog.shared.write(event: "setup: test capture \(error.map { "failed: \($0)" } ?? "ok")")
            directCaptureRunning = false
            directCaptureError = error
            if error == nil { directCaptureChecked = true }
            updateScreen()
        }
    }

    #if DEBUG
    /// `--snapshot STATE OUT.png` (dev builds only): fake permission state and a fixed screen, rendered
    /// offscreen to a PNG. Grants nothing; see Snapshot.swift.
    enum Preview: String, CaseIterable {
        case onboardingNone = "onboarding-none", onboardingAX = "onboarding-ax",
             onboardingRelaunch = "onboarding-relaunch", onboardingBoth = "onboarding-both",
             tutorial, control, controlEnabled = "control-enabled"
    }
    private(set) var preview: Preview?
    /// True in preview mode: every button that would change anything real is a no-op.
    var isPreview: Bool { preview != nil }

    func startPreview(_ p: Preview) {
        preview = p
        enabled = false
        expiresAt = nil
        recent = []
        let ax = p != .onboardingNone
        let sr = ![.onboardingNone, .onboardingAX, .onboardingRelaunch].contains(p)
        accessibilityGranted = ax
        screenRecordingGranted = sr
        screenRecordingRequested = p == .onboardingRelaunch
        switch p {
        case .onboardingNone, .onboardingAX, .onboardingRelaunch, .onboardingBoth: screen = .onboarding
        case .tutorial: screen = .tutorial
        case .control, .controlEnabled: screen = .control
        }
        if p == .controlEnabled {
            now = Date()
            expiresAt = now.addingTimeInterval(23 * 60 + 41)
            enabled = true
            let t = Date()
            recent = [
                ActionRecord(time: t.addingTimeInterval(-2), caller: "claude", pid: 48211, command: "screenshot --max-width 1280", ok: true),
                ActionRecord(time: t.addingTimeInterval(-5), caller: "claude", pid: 48211, command: "click 812 440", ok: true),
                ActionRecord(time: t.addingTimeInterval(-9), caller: "macinto.sh", pid: 48190, command: "ui app=Safari depth=3", ok: true),
                ActionRecord(time: t.addingTimeInterval(-14), caller: "python3", pid: 47702, command: "record start", ok: false),
                ActionRecord(time: t.addingTimeInterval(-31), caller: "claude", pid: 48211, command: "type text=\"hello 🍎\"", ok: true),
            ]
        }
    }
    #else
    var isPreview: Bool { false }
    #endif

    private var timer: Timer?

    private init() {
        refreshPermissions()
        advanceWork?.cancel()
        advanceWork = nil
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
        #if DEBUG
        if preview != nil { ActionLog.shared.write(event: "DEBUG: preview: Enable ignored"); return }
        #endif
        // Can't be enabled until both permissions are on (i.e. during onboarding).
        guard permissionsOK, screen == .control else {
            ActionLog.shared.write(event: "enable refused: permissions missing or setup not finished")
            return
        }
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
        #if DEBUG
        if preview != nil { return }
        #endif
        let ax = Permissions.accessibility
        let sc = Permissions.screenRecording
        if ax != accessibilityGranted { accessibilityGranted = ax }
        if sc != screenRecordingGranted { screenRecordingGranted = sc }
        updateScreen()
    }

    /// Initial screen at launch: straight to the controls (or the one-time tutorial) when both
    /// permissions are already on, otherwise onboarding.
    func chooseLaunchScreen() {
        #if DEBUG
        if preview != nil { return }
        #endif
        screen = permissionsOK ? (tutorialSeen ? .control : .tutorial) : .onboarding
    }

    private func updateScreen() {
        if !permissionsOK {
            advanceWork?.cancel()
            advanceWork = nil
            if screen != .onboarding {
                screen = .onboarding
                ActionLog.shared.write(event: "permission missing (accessibility: \(accessibilityGranted), screen recording: \(screenRecordingGranted)); back to setup")
                disable(reason: "permission revoked")
                onPermissionsLost?()
            }
            return
        }
        if screen == .onboarding, !directCaptureChecked {
            // One test capture first, so macOS's "allow direct screen capture" prompt shows up here.
            if !directCaptureRunning, directCaptureError == nil { runDirectCaptureCheck() }
            return
        }
        if screen == .onboarding, advanceWork == nil {
            // Both checkmarks stay up for 3 s, then the tutorial (first time only) or the controls.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.permissionsOK, self.screen == .onboarding else { return }
                    self.advanceWork = nil
                    self.screen = self.tutorialSeen ? .control : .tutorial
                }
            }
            advanceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    func finishTutorial() {
        #if DEBUG
        if preview != nil { ActionLog.shared.write(event: "DEBUG: preview: Got it ignored"); return }
        #endif
        tutorialSeen = true
        screen = .control
    }

    func record(_ r: ActionRecord) {
        recent.insert(r, at: 0)
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
    }
}
