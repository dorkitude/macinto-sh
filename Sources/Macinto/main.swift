import AppKit

// A client that disconnects before its reply is written must not kill the app. SO_NOSIGPIPE is set
// per connection, but setsockopt can fail on a socket whose peer is already gone, and the write that
// follows would then raise SIGPIPE (default action: terminate, with no crash report).
signal(SIGPIPE, SIG_IGN)

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
