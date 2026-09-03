import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey.
///
/// Chosen over a CGEvent tap deliberately: RegisterEventHotKey needs no
/// Accessibility permission and cannot drop keystrokes under load, because
/// the window server does the matching rather than our process.
final class Hotkeys {
    static let shared = Hotkeys()
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private static let ctrlAlt = UInt32(controlKey | optionKey)

    func install() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            me.actions[id.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// `key` is a kVK_* virtual key code.
    func bind(_ key: Int, _ action: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        actions[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x54545454), id: id)  // 'TTTT'
        let err = RegisterEventHotKey(UInt32(key), Hotkeys.ctrlAlt, hkID,
                                      GetApplicationEventTarget(), 0, &ref)
        if err == noErr, let ref { refs.append(ref) } else { actions[id] = nil }
    }

    var count: Int { refs.count }

    func releaseAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }

    enum Key {
        static let s = kVK_ANSI_S, p = kVK_ANSI_P, x = kVK_ANSI_X
        static let a = kVK_ANSI_A, r = kVK_ANSI_R, t = kVK_ANSI_T
        static let left = kVK_LeftArrow
    }
}
