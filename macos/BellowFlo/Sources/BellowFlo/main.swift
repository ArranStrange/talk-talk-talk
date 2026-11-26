import AppKit

/// Menu bar app, no Dock presence of its own (LSUIElement). The .app in
/// ~/Applications is still clickable from the Dock to launch it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Coordinator.shared.start()
    }

    /// Clicking the Dock icon while already running: put the pill back
    /// rather than doing nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        Coordinator.shared.bringPillToFront()
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
