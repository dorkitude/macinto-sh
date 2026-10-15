import AppKit

MainActor.assumeIsolated {
    #if DEBUG
    Snapshot.runIfRequested() // exits when --snapshot is given
    #endif
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
