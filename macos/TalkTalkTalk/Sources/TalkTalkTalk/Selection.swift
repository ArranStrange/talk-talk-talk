import AppKit

/// Grabs the frontmost app's selection by synthesising ⌘C and reading the
/// pasteboard, then putting back what was there before.
///
/// This is the one part that needs Accessibility permission: posting a key
/// event to another application is exactly what that permission governs.
enum Selection {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Calls back on the main queue with the selection, or nil if there
    /// wasn't one. The 0.25 s wait is for the target app to service the copy.
    static func capture(_ done: @escaping (String?) -> Void) {
        guard isTrusted else {
            Hud.shared.show("Talk Talk Talk needs Accessibility permission\n"
                            + "to read the selection", seconds: 4)
            requestTrust()
            done(nil)
            return
        }
        let pb = NSPasteboard.general
        let before = pb.string(forType: .string)
        let changeCount = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let c: CGKeyCode = 8   // kVK_ANSI_C
        let down = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            var selection: String?
            if pb.changeCount != changeCount {
                selection = pb.string(forType: .string)
                if let before { pb.clearContents(); pb.setString(before, forType: .string) }
            }
            if let s = selection, !s.isEmpty { done(s) } else {
                Hud.shared.show("No text selected")
                done(nil)
            }
        }
    }
}
