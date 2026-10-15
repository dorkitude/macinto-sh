import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var current: AppDelegate?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var server: SocketServer?
    let overlay = Overlay()
    private let state = AppState.shared

    private lazy var enabledIcon: NSImage = {
        let img = AppleImage.emoji(pointSize: 15, canvas: 20)
        img.isTemplate = false
        return img
    }()
    private lazy var disabledIcon: NSImage = {
        let img = AppleImage.dimmed(enabledIcon, alpha: 0.4)
        img.isTemplate = false
        return img
    }()

    /// False when macOS hides the item, e.g. a crowded menu bar on a notched display.
    var statusItemOnScreen: Bool {
        guard let item = statusItem, item.isVisible, let w = item.button?.window else { return false }
        return w.occlusionState.contains(.visible)
    }

    private var controlWindow: NSPanel?

    /// The same controls as the menu bar popover, in a small window. Used when the menu bar icon is
    /// hidden, and whenever Macinto.sh is opened again while running (`open -a Macinto.sh`).
    ///
    /// `explicit` is false when the window appears on its own (menu bar full at launch): it is then
    /// ordered front without activating the app or becoming key, so it never takes keyboard focus
    /// from whatever the user is typing into. Even when explicit, no button is first responder and
    /// none is bound to Return, so a stray keypress can't enable anything.
    func showControlWindow(explicit: Bool) {
        if controlWindow == nil {
            let host = NSHostingController(rootView: makeMenuView(closeOnInstall: false))
            host.sizingOptions = .preferredContentSize
            let p = NSPanel(contentViewController: host)
            p.title = Paths.displayName
            p.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView]
            // Tokyo Night: always dark, title bar blends into the content.
            p.appearance = NSAppearance(named: .darkAqua)
            p.backgroundColor = TN.nsBg
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.center()
            controlWindow = p
        }
        guard let p = controlWindow else { return }
        if explicit {
            NSApp.activate()
            p.orderFrontRegardless()
        } else {
            p.orderFrontRegardless()
        }
        p.makeFirstResponder(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if statusItemOnScreen, !popover.isShown {
            togglePopover(nil)
        } else {
            showControlWindow(explicit: true)
        }
        return false
    }

    private func makeMenuView(closeOnInstall: Bool) -> MenuView {
        MenuView(
            state: state,
            statusItemHidden: { [weak self] in !(self?.statusItemOnScreen ?? true) },
            installCLI: { [weak self] in
                if self?.state.isPreview == true { ActionLog.shared.write(event: "DEBUG: preview: Install CLI ignored"); return }
                if closeOnInstall { self?.popover.performClose(nil) }
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
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.imagePosition = .imageOnly

        popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: makeMenuView(closeOnInstall: true))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        state.onEnabledChange = { [weak self] enabled in self?.enabledChanged(enabled) }
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
            overlay.show()
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
        if !(popover?.isShown ?? false) { showControlWindow(explicit: false) }
    }

    private func updateIcon() {
        statusItem.button?.image = state.enabled ? enabledIcon : disabledIcon
        statusItem.button?.toolTip = state.enabled ? "\(Paths.displayName): enabled" : "\(Paths.displayName): disabled"
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            state.refreshPermissions()
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
