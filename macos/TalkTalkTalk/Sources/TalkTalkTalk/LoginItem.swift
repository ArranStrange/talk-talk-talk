import ServiceManagement

/// Start at login. Hammerspoon was providing this before; without it the app
/// would not come back after a restart.
enum LoginItem {
    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns a message to show, or nil on success. Registration can be
    /// refused (an unsigned or quarantined bundle, or the user having
    /// disabled it in System Settings), and silently failing here would look
    /// like the checkmark simply not sticking.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Could not \(on ? "enable" : "disable") start at login: "
                 + error.localizedDescription
        }
    }
}
