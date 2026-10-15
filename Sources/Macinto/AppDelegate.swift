import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var current: AppDelegate?

    private var statusItem: NSStatusItem!
    private var server: SocketServer?
    let overlay = Overlay()
    private let state = AppState.shared

    private lazy var enabledIcon: NSImage = {
        // Full color with a red glow while enabled.
        let img = AppleImage.glowing(pointSize: 13, canvas: 22, glow: 5)
        img.isTemplate = false
        return img
    }()
    private lazy var disabledIcon: NSImage = {
        let img = AppleImage.dimmed(AppleImage.emoji(pointSize: 14, canvas: 22), alpha: 0.4)
        img.isTemplate = false
        return img
    }()

    /// False when macOS hides the item, e.g. a crowded menu bar on a notched display.
    var statusItemOnScreen: Bool {
        guard let item = statusItem, item.isVisible, let w = item.button?.window else { return false }
        return w.occlusionState.contains(.visible)
    }

    private var controlWindow: NSWindow?

    /// The single control window. Opened by clicking the menu bar icon, the overlay apple, the Dock
    /// icon, `macinto.sh setup` (socket command `show_window`), or opening the app again while it
    /// runs (`open /Applications/Macinto.sh.app`, the reopen event) (all `explicit`), and on its
    /// own when setup is needed at launch or macOS hides the menu bar icon.
    ///
    /// `explicit` is false when the window appears on its own: it is then ordered front without
    /// activating the app or becoming key, so it never takes keyboard focus from whatever the user
    /// is typing into. When explicit, the app activates and the window comes to the front as key;
    /// an already open window just stays in front. Even then, no button is first responder and
    /// none is bound to Return, so a stray keypress can't enable anything.
    func showControlWindow(explicit: Bool) {
        if controlWindow == nil {
            let host = NSHostingController(rootView: makeMenuView())
            host.sizingOptions = .preferredContentSize
            // A normal window, not a floating panel: it doesn't stay on top of other apps, and
            // clicking it activates Macinto.sh so the main menu's shortcuts (⌘Q, ⌘W) work.
            let p = NSWindow(contentViewController: host)
            p.title = Paths.displayName
            p.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            // Tokyo Night: always dark, title bar blends into the content.
            p.appearance = NSAppearance(named: .darkAqua)
            p.backgroundColor = TN.nsBg
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isReleasedWhenClosed = false
            p.center()
            // Closing the window drops back to a menu-bar-only app (no Dock icon, not in ⌘Tab).
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
            controlWindow = p
        }
        guard let p = controlWindow else { return }
        // While the window is open, Macinto.sh is a regular app: it has a Dock icon and shows up in
        // ⌘Tab, so it can be found again after other windows cover it. This doesn't activate it.
        if NSApp.activationPolicy() != .regular { _ = NSApp.setActivationPolicy(.regular) }
        if explicit {
            state.refreshPermissions()
            // Since macOS 14, activate() is cooperative: it is ignored unless the active app yields,
            // which a socket request (`macinto.sh setup`) can't arrange. A person asked for this
            // window, so activate regardless, and order it front even if activation is refused.
            (NSApp as LegacyActivation).activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
            p.orderFrontRegardless()
        } else {
            p.orderFrontRegardless()
        }
        p.makeFirstResponder(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow(explicit: true)
        return false
    }

    private func makeMenuView() -> MenuView {
        MenuView(
            state: state,
            statusItemHidden: { [weak self] in !(self?.statusItemOnScreen ?? true) },
            installCLI: { [weak self] in
                if self?.state.isPreview == true { ActionLog.shared.write(event: "DEBUG: preview: Install CLI ignored"); return }
                CLIInstaller.install()
            },
            openLog: { NSWorkspace.shared.open(Paths.log) },
            relaunch: { [weak self] in
                if self?.state.isPreview == true { ActionLog.shared.write(event: "DEBUG: preview: Relaunch ignored"); return }
                AppDelegate.relaunch()
            },
            quit: { NSApp.terminate(nil) })
    }

    /// Start a fresh copy of this app once this process has exited (Screen Recording is often only
    /// reported as granted to a new process).
    static func relaunch() {
        ActionLog.shared.write(event: "relaunching (screen recording setup)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"",
                       "sh", String(getpid()), Bundle.main.bundleURL.path]
        do {
            try p.run()
        } catch {
            ActionLog.shared.write(event: "relaunch failed: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    var statusItemDescription: String {
        guard let item = statusItem, let button = item.button else { return "missing" }
        let which = button.image === enabledIcon ? "apple (full color)" : "apple (dimmed)"
        var frame = ""
        if let w = button.window, let screen = NSScreen.screens.first {
            let f = w.frame
            frame = String(format: " at %.0f,%.0f %.0fx%.0f", f.minX, screen.frame.maxY - f.maxY, f.width, f.height)
        }
        return "\(statusItemOnScreen ? "visible" : "hidden by macOS (menu bar full)") \(which)\(frame)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.imagePosition = .imageOnly

        state.onEnabledChange = { [weak self] enabled in self?.enabledChanged(enabled) }
        overlay.onClick = { [weak self] in self?.showControlWindow(explicit: true) }
        state.onOverlayPreferenceChange = { [weak self] in
            guard let self else { return }
            if self.state.enabled && self.state.showOverlay { self.overlay.show() } else { self.overlay.hide() }
        }
        state.onPermissionsLost = { [weak self] in self?.permissionsLost() }
        updateIcon()

        state.chooseLaunchScreen()

        let server = SocketServer(path: Paths.socket.path) { request, peer in
            await Commands.handle(request, peer)
        }
        do {
            try server.start()
            self.server = server
            ActionLog.shared.write(event: "started v\(Paths.version) pid \(getpid()), listening on \(Paths.socket.path)")
        } catch {
            ActionLog.shared.write(event: "could not start socket server: \(error)")
            let a = NSAlert()
            a.messageText = "\(Paths.displayName) could not start"
            a.informativeText = "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        // Setup needed: show it right away, without taking focus.
        if state.screen != .control {
            showControlWindow(explicit: false)
        }

        // If macOS hid the menu bar icon (no room), open the control window so Macinto stays reachable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.statusItemOnScreen else { return }
            ActionLog.shared.write(event: "menu bar icon is hidden by macOS; showing control window")
            self.showControlWindow(explicit: false)
        }

        #if DEBUG
        // Dev builds only: `open "build/debug/Macinto.sh (Dev).app" --args --enable-for-testing SECONDS`.
        // Compiled out of release builds; there is deliberately no way to enable over the socket.
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--enable-for-testing"), i + 1 < argv.count, let secs = Double(argv[i + 1]),
           secs > 0 {
            // Same rule as the Enable button: refused until both permissions are on.
            state.enable(for: min(secs, 3600))
            ActionLog.shared.write(event: "DEBUG: --enable-for-testing \(argv[i + 1]): \(state.enabled ? "enabled" : "refused (setup not finished)")")
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        ActionLog.shared.write(event: "quit")
    }

    private func enabledChanged(_ enabled: Bool) {
        updateIcon()
        if enabled {
            if state.showOverlay { overlay.show() }
        } else {
            overlay.hide()
            if Recorder.shared.isRecording {
                Task { @MainActor in
                    if case .object(let o)? = try? await Recorder.shared.stop(), case .string(let path)? = o["path"] {
                        ActionLog.shared.write(event: "recording stopped because macinto was disabled: \(path)")
                    }
                }
            }
        }
    }

    /// A permission was revoked after setup: the state is already disabled and back on onboarding.
    private func permissionsLost() {
        if Recorder.shared.isRecording {
            Task { @MainActor in
                _ = try? await Recorder.shared.stop()
                ActionLog.shared.write(event: "recording stopped because a permission was revoked")
            }
        }
        // Re-show without activating or taking key focus.
        showControlWindow(explicit: false)
    }

    private func updateIcon() {
        statusItem.button?.image = state.enabled ? enabledIcon : disabledIcon
        statusItem.button?.toolTip = state.enabled ? "\(Paths.displayName): enabled" : "\(Paths.displayName): disabled"
    }

    /// Menu bar icon click: bring the control window to the front and focus it. Never closes it.
    @objc private func statusItemClicked(_ sender: Any?) {
        showControlWindow(explicit: true)
    }
}

/// `NSApplication.activate(ignoringOtherApps:)` is deprecated (macOS 14) but still the only call that
/// activates without the active app's cooperation. Calling it through a protocol avoids the warning.
@MainActor
private protocol LegacyActivation {
    func activate(ignoringOtherApps flag: Bool)
}
extension NSApplication: LegacyActivation {}
