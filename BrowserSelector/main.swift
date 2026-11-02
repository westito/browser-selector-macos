import AppKit

// `NSApplication.delegate` is weak, so the delegate is held by a global for the process lifetime.
// Top-level code runs on the main thread but is nonisolated, hence the explicit main actor entry.
let appDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
