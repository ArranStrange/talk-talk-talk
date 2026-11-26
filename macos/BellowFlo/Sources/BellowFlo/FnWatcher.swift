import AppKit

/// Auto-pause while dictating: hold-Fn tools (Wispr Flow) take the mic, and
/// speech over the top of your own voice is useless. Pauses on Fn down and
/// resumes only if we were the one who paused.
final class FnWatcher {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private var autoPaused = false
    private let stateProvider: () -> String

    init(stateProvider: @escaping () -> String) { self.stateProvider = stateProvider }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<FnWatcher>.fromOpaque(userInfo).takeUnretainedValue()
            me.handle(event.flags.contains(.maskSecondaryFn))
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .listenOnly, eventsOfInterest: mask,
                                callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ fn: Bool) {
        guard fn != held else { return }
        held = fn
        if fn {
            if stateProvider() == "playing" {
                autoPaused = true
                Daemon.pause()
            }
        } else if autoPaused {
            autoPaused = false
            if stateProvider() == "paused" { Daemon.resume() }
        }
    }

    /// True while Fn is down, so a stream that starts mid-dictation can also
    /// be silenced rather than only one already playing.
    var isHeld: Bool { held }
    var didAutoPause: Bool {
        get { autoPaused }
        set { autoPaused = newValue }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}
