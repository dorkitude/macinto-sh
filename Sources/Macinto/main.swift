import AppKit

MainActor.assumeIsolated {
    #if DEBUG
    Snapshot.runIfRequested() // exits when --snapshot is given
    #endif
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // Accessory apps show no menu bar, but the main menu's key equivalents still work while one of
    // the app's windows is key: ⌘Q quits, ⌘W closes, ⌘H hides, and the Edit shortcuts work in fields.
    app.mainMenu = MainMenu.make()
    withExtendedLifetime(delegate) { app.run() }
}
