import SwiftUI

struct MenuView: View {
    @ObservedObject var state: AppState
    var statusItemHidden: () -> Bool = { false }
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
        VStack(alignment: .leading, spacing: 12) {
            header
            if statusItemHidden() {
                Text("macOS is hiding the \(Paths.displayName) menu bar icon because the menu bar is full. Run `open -a '\(Paths.displayName)'` to bring this window back, or free up menu bar space.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            duration
            Divider()
            permissions
            Divider()
            recent
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("🍎").font(.title2).opacity(state.enabled ? 1 : 0.35).saturation(state.enabled ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.enabled ? "Enabled" : "Disabled")
                    .font(.headline)
                    .foregroundStyle(state.enabled ? Color.red : Color.secondary)
                Text(state.enabled
                     ? (state.remainingSeconds == nil ? "On until you turn it off" : "Time remaining: \(state.remainingText)")
                     : "CLI requests are refused")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if state.enabled {
                Button("Disable now") { state.disable(reason: "menu") }
            } else {
                // Deliberately no keyboard shortcut / default-button binding: enabling takes a click
                // (or Tab to the button and Space), never a stray Return.
                Button("Enable for \(durationLabel)") { state.enable(for: state.selectedDuration) }
            }
        }
    }

    private var duration: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Duration")
                Spacer()
                Text(durationLabel).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(state.durationIndex) },
                                  set: { state.durationIndex = Int($0.rounded()) }),
                   in: 0...Double(AppState.durations.count - 1), step: 1) {
                EmptyView()
            } minimumValueLabel: {
                Text("5m").font(.caption2)
            } maximumValueLabel: {
                Text("∞").font(.caption2)
            }
            if state.selectedDuration == nil {
                Text("Infinite? Bold. Anything running as you can drive this Mac until you turn it off.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if state.enabled {
                Button("Restart timer with \(durationLabel)") { state.enable(for: state.selectedDuration) }
                    .controlSize(.small)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow("Accessibility", granted: state.accessibilityGranted, note: "click, type, key, ui") {
                Permissions.promptAccessibility()
            }
            permissionRow("Screen Recording", granted: state.screenRecordingGranted, note: "screenshot, record") {
                Permissions.promptScreenRecording()
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool, note: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Grant…", action: action).controlSize(.small)
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent actions").font(.subheadline).foregroundStyle(.secondary)
            if state.recent.isEmpty {
                Text("None yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(state.recent) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.timeFormat.string(from: r.time)).monospacedDigit().foregroundStyle(.secondary)
                        // verbatim: a plain Int interpolated into Text is localized ("2,110").
                        Text(verbatim: "\(r.caller)[\(String(r.pid))]").lineLimit(1)
                        Text(r.command).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(r.ok ? Color.primary : Color.red)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Install command line tool…", action: installCLI)
            Button("Log", action: openLog)
            Spacer()
            Button("Quit", action: quit)
        }
        .controlSize(.small)
    }
}
