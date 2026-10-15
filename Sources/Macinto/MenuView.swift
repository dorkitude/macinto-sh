import SwiftUI

/// Root of the control window: onboarding until both permissions are on,
/// then the one-time tutorial, then the controls.
struct MenuView: View {
    @ObservedObject var state: AppState
    var statusItemHidden: () -> Bool = { false }
    var installCLI: () -> Void
    var openLog: () -> Void
    var relaunch: () -> Void
    var quit: () -> Void

    var body: some View {
        Group {
            switch state.screen {
            case .onboarding: OnboardingView(state: state, relaunch: relaunch, quit: quit)
            case .tutorial: TutorialView(state: state)
            case .control:
                ControlView(state: state, statusItemHidden: statusItemHidden, installCLI: installCLI,
                            openLog: openLog, quit: quit)
            }
        }
        .foregroundStyle(TN.text)
        .background(TN.bg)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.25), value: state.screen)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var state: AppState
    var relaunch: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("🍎").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Paths.uiName).font(.system(size: 17, weight: .bold))
                    Text("Setup").font(TN.mono(11)).foregroundStyle(TN.muted)
                }
            }
            Text("This app is a bridge between the Macinto.sh CLI/MCP and your actual Mac. For it to function, you'll need to turn on these permissions:")
                .font(.system(size: 13)).foregroundStyle(TN.text2)
                .fixedSize(horizontal: false, vertical: true)

            PermissionButton(title: "Accessibility", detail: "click, type, read UI", symbol: "cursorarrow.click.2",
                             accent: TN.blue, granted: state.accessibilityGranted) {
                if state.isPreview { ActionLog.shared.write(event: "DEBUG: preview: Accessibility button ignored"); return }
                guard state.setupClickAllowed() else { return }
                Permissions.promptAccessibility(firstAttempt: !state.accessibilityRequested)
                state.accessibilityRequested = true
            }
            PermissionButton(title: "Screen Recording", detail: "screenshots, recordings",
                             symbol: "rectangle.dashed.badge.record", accent: TN.purple,
                             granted: state.screenRecordingGranted) {
                if state.isPreview { ActionLog.shared.write(event: "DEBUG: preview: Screen Recording button ignored"); return }
                guard state.setupClickAllowed(), !state.setupRequestInFlight else { return }
                let first = !state.screenRecordingRequested
                state.screenRecordingRequested = true
                state.setupRequestInFlight = true
                Permissions.promptScreenRecording(firstAttempt: first) { state.setupRequestInFlight = false }
            }

            if state.permissionsOK && !state.directCaptureChecked {
                HStack(alignment: .center, spacing: 10) {
                    if let err = state.directCaptureError {
                        Text("Test capture failed: \(err)")
                            .font(.system(size: 12)).foregroundStyle(TN.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Try again") { state.runDirectCaptureCheck() }
                            .buttonStyle(PrimaryButtonStyle(colors: [TN.purple, TN.magenta]))
                    } else {
                        Text("macOS may ask once more to let Macinto.sh capture the screen directly. Click Allow.")
                            .font(.system(size: 12)).foregroundStyle(TN.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .card(padding: 10)
            } else if state.permissionsOK {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(TN.green)
                    Text("All set. Opening the controls…").font(.system(size: 12)).foregroundStyle(TN.green)
                }
            } else if state.screenRecordingRequested && !state.screenRecordingGranted {
                HStack(alignment: .center, spacing: 10) {
                    Text("macOS applies Screen Recording after a relaunch.")
                        .font(.system(size: 12)).foregroundStyle(TN.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Relaunch \(Paths.uiName)", action: relaunch)
                        .buttonStyle(PrimaryButtonStyle(colors: [TN.purple, TN.magenta]))
                }
                .card(padding: 10)
            }

            HStack {
                Text("Macinto.sh stays disabled until both are on.").font(.system(size: 11)).foregroundStyle(TN.muted)
                Spacer()
                Button("Quit", action: quit).buttonStyle(GhostButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { state.setupShownAt = Date() }
    }
}

struct PermissionButton: View {
    let title: String
    let detail: String
    let symbol: String
    let accent: Color
    let granted: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: { if !granted { action() } }) {
            HStack(spacing: 14) {
                HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(granted ? 0.08 : 0.16))
                    Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(accent)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(TN.text)
                    Text(detail).font(TN.mono(11)).foregroundStyle(TN.text2)
                }
                }
                // Faded when done; the checkmark below stays bright.
                .opacity(granted ? 0.45 : 1)
                Spacer()
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(TN.green)
                        .shadow(color: TN.green.opacity(0.6), radius: 6)
                } else {
                    Text("Turn on").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TN.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(granted ? TN.green.opacity(0.35) : (hover ? accent : TN.borderHi), lineWidth: 1))
            .shadow(color: accent.opacity(granted || !hover ? 0 : 0.3), radius: 10)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        // Not .disabled(): that also dims the checkmark. A granted button just ignores clicks.
        .allowsHitTesting(!granted)
        .onHover { hover = $0 }
        .accessibilityLabel(granted ? "\(title): on" : "Turn on \(title)")
    }
}

// MARK: - Tutorial

struct TutorialView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("When Macinto.sh is enabled, you'll see a flashing red Apple like this:")
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(TN.bgDeep)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TN.border))
                PulsingApple()
            }
            .frame(width: 130, height: 120)
            Text("in the top-right of your screen. We recommend enabling only for short periods of time, unless this machine is purely meant for your agent.")
                .font(.system(size: 13)).foregroundStyle(TN.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Got it") { state.finishTutorial() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(22)
        .frame(width: 340)
    }
}

// MARK: - Controls

struct ControlView: View {
    @ObservedObject var state: AppState
    var statusItemHidden: () -> Bool
    var installCLI: () -> Void
    var openLog: () -> Void
    var quit: () -> Void

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var durationLabel: String { AppState.label(for: state.selectedDuration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            status
            duration
            appleSetting
            recent
            if statusItemHidden() {
                Text("Menu bar icon hidden by macOS (menu bar full). `open -a '\(Paths.uiName)'` reopens this window.")
                    .font(.system(size: 10)).foregroundStyle(TN.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(12)
        .frame(width: 368)
    }

    private var status: some View {
        HStack(spacing: 10) {
            ZStack {
                if state.enabled {
                    PulsingApple(size: 30, glow: 5)
                } else {
                    Image(nsImage: AppleImage.dimmed(AppleImage.emoji(pointSize: 22, canvas: 28), alpha: 0.45))
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.enabled ? "Enabled" : "Disabled")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(state.enabled ? TN.red : TN.text2)
                Text(state.enabled
                     ? (state.remainingSeconds == nil ? "until you turn it off" : "\(state.remainingText) left")
                     : "refusing requests")
                    .font(TN.mono(11)).foregroundStyle(state.enabled ? TN.text : TN.muted)
                    .lineLimit(1).fixedSize()
            }
            Spacer()
            if state.enabled {
                Button("Disable") { state.disable(reason: "menu") }
                    .buttonStyle(OutlineButtonStyle(color: TN.red))
            } else {
                // Deliberately no keyboard shortcut / default-button binding: enabling takes a click
                // (or Tab to the button and Space), never a stray Return.
                Button("Enable for \(durationLabel)") { state.enable(for: state.selectedDuration) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .card(padding: 10)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(state.enabled ? TN.red.opacity(0.45) : .clear, lineWidth: 1))
    }

    private var duration: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Duration").font(.system(size: 11, weight: .semibold)).foregroundStyle(TN.text2)
                Spacer()
                Text(durationLabel).font(TN.mono(11, .semibold))
                    .foregroundStyle(state.selectedDuration == nil ? TN.orange : TN.cyan)
            }
            HStack(spacing: 8) {
                Text("5m").font(TN.mono(10)).foregroundStyle(TN.muted)
                NotchSlider(index: $state.durationIndex, count: AppState.durations.count) {
                    AppState.label(for: AppState.durations[$0])
                }
                Text("∞").font(TN.mono(11)).foregroundStyle(TN.muted)
            }
            if state.selectedDuration == nil {
                Text("Infinite? Bold. Anything running as you can drive this Mac until you turn it off.")
                    .font(.system(size: 11)).foregroundStyle(TN.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.enabled {
                Button("Restart timer with \(durationLabel)") { state.enable(for: state.selectedDuration) }
                    .buttonStyle(OutlineButtonStyle(color: TN.blue, small: true))
            }
        }
        .padding(.horizontal, 4)
    }

    private var appleSetting: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $state.showOverlay) {
                Text("Show the red apple while enabled").font(.system(size: 12)).foregroundStyle(TN.text)
            }
            .toggleStyle(TNSwitchStyle())
            if !state.showOverlay {
                if statusItemHidden() {
                    Text("Your menu bar icon is hidden by macOS, so nothing on screen will show that Macinto.sh is on.")
                        .font(.system(size: 10)).foregroundStyle(TN.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Only the menu bar 🍎 shows when Macinto.sh is on.")
                        .font(.system(size: 10)).foregroundStyle(TN.muted)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Recent activity").font(.system(size: 11, weight: .semibold)).foregroundStyle(TN.text2)
            if state.recent.isEmpty {
                Text("No requests yet").font(TN.mono(11)).foregroundStyle(TN.muted)
            } else {
                ForEach(state.recent) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(r.ok ? TN.green : TN.red).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                        Text(Self.timeFormat.string(from: r.time)).foregroundStyle(TN.muted)
                        // verbatim: a plain Int interpolated into Text is localized ("2,110").
                        Text(verbatim: "\(r.caller)[\(String(r.pid))]").foregroundStyle(TN.purple).lineLimit(1)
                            .layoutPriority(1)
                        Text(r.command).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(r.ok ? TN.text : TN.red)
                    }
                    .font(TN.mono(10.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Install CLI", action: installCLI).buttonStyle(GhostButtonStyle())
            Button("Log", action: openLog).buttonStyle(GhostButtonStyle())
            Spacer()
            Text(verbatim: "v\(Paths.version)").font(TN.mono(10)).foregroundStyle(TN.muted)
            Button("Quit", action: quit).buttonStyle(GhostButtonStyle())
        }
    }
}
