import AppKit

// Program start is already on the main thread, so asserting main-actor
// isolation here is safe and lets us touch the MainActor-isolated AppKit API.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // Menu-bar agent: no Dock icon, but windows still show on demand.
    app.setActivationPolicy(.accessory)
    app.run()
}
