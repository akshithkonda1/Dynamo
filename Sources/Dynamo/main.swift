import AppKit

// Entry point. NSApplicationDelegate callbacks run on the main thread;
// we hop onto the main actor before constructing UI-owned types.
autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
