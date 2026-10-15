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

    /// The same controls as the menu bar popover, in a small window. Used when the menu bar
    /// icon is hidden, and whenever Macinto is opened again while running (`open -a Macinto`).
    func showControlWindow() {
        if controlWindow == nil {
            let host = NSHostingController(rootView: makeMenuView(closeOnInstall: false))
            host.sizingOptions = .preferredContentSize
            let p = NSPanel(contentViewController: host)
            p.title = "Macinto"
            p.styleMask = [.titled, .closable, .utilityWindow]
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.center()
            controlWindow = p
        }
        NSApp.activate()
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if statusItemOnScreen, !popover.isShown {
            togglePopover(nil)
        } else {
            showControlWindow()
        }
        return false
    }

    private func makeMenuView(closeOnInstall: Bool) -> MenuView {
        MenuView(
            state: state,
            statusItemHidden: { [weak self] in !(self?.statusItemOnScreen ?? true) },
            installCLI: { [weak self] in
                if closeOnInstall { self?.popover.performClose(nil) }
                CLIInstaller.install()
            },
            openLog: { NSWorkspace.shared.open(Paths.log) },
            quit: { NSApp.terminate(nil) })
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
        let host = NSHostingController(rootView: makeMenuView(closeOnInstall: true))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        state.onEnabledChange = { [weak self] enabled in self?.enabledChanged(enabled) }
        updateIcon()

        let server = SocketServer(path: Paths.socket.path) { command, args, peer in
            await Commands.handle(command, args, peer)
        }
        do {
            try server.start()
            self.server = server
            ActionLog.shared.write(event: "started v\(Paths.version) pid \(getpid()), listening on \(Paths.socket.path)")
        } catch {
            ActionLog.shared.write(event: "could not start socket server: \(error)")
            let a = NSAlert()
            a.messageText = "Macinto could not start"
            a.informativeText = "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        // If macOS hid the menu bar icon (no room), open the control window so Macinto stays reachable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.statusItemOnScreen else { return }
            ActionLog.shared.write(event: "menu bar icon is hidden by macOS; showing control window")
            self.showControlWindow()
        }

        #if DEBUG
        // Dev builds only: `open build/debug/Macinto.app --args --enable-for-testing SECONDS`.
        // Compiled out of release builds; there is deliberately no way to enable over the socket.
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--enable-for-testing"), i + 1 < argv.count, let secs = Double(argv[i + 1]),
           secs > 0 {
            state.enable(for: min(secs, 3600))
            ActionLog.shared.write(event: "DEBUG: enabled by --enable-for-testing \(argv[i + 1])")
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
                    if let lines = try? await Recorder.shared.stop() {
                        ActionLog.shared.write(event: "recording stopped because macinto was disabled: \(lines.first ?? "")")
                    }
                }
            }
        }
    }

    private func updateIcon() {
        statusItem.button?.image = state.enabled ? enabledIcon : disabledIcon
        statusItem.button?.toolTip = state.enabled ? "macinto: enabled" : "macinto: disabled"
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
