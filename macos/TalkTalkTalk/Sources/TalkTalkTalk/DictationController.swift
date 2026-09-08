import AppKit

/// Hold a modifier to dictate: record while it is down, then transcribe,
/// clean up and paste when it comes up. The Wispr Flow shape.
final class DictationController {
    enum Key: String, CaseIterable {
        case rightOption, fn, rightCommand, off
        var label: String {
            switch self {
            case .rightOption:  return "Hold Right ⌥"
            case .fn:           return "Hold Fn"
            case .rightCommand: return "Hold Right ⌘"
            case .off:          return "Off"
            }
        }
    }

    private let recorder = Recorder()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    /// We paused speech so the mic would not pick it up; resume it after.
    private var pausedSpeech = false
    private weak var coord: Coordinator?

    /// Ignore a tap shorter than this: it was a slip, not a sentence.
    private let minimumHold: TimeInterval = 0.4
    /// Modifier keys are ambiguous in the event; the key code disambiguates
    /// left from right.
    private let rightOptionCode: Int64 = 61, rightCommandCode: Int64 = 54

    init(coordinator: Coordinator) { self.coord = coordinator }

    static var key: Key {
        Key(rawValue: Config().raw["dictation_key"] as? String ?? "") ?? .rightOption
    }

    // MARK: key watching

    func start() {
        guard tap == nil, AXIsProcessTrusted(), DictationController.key != .off else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<DictationController>.fromOpaque(info).takeUnretainedValue()
            me.flagsChanged(event)
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
        Log.write("dictation: watching \(DictationController.key.label)")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        if recorder.isRecording { _ = recorder.stop(to: Paths.kokoroDir + "/dictation.wav") }
    }

    /// Restart after the key choice changes.
    func restart() { stop(); start() }

    private func flagsChanged(_ e: CGEvent) {
        let down: Bool
        switch DictationController.key {
        case .fn:
            down = e.flags.contains(.maskSecondaryFn)
        case .rightOption:
            guard e.getIntegerValueField(.keyboardEventKeycode) == rightOptionCode else { return }
            down = e.flags.contains(.maskAlternate)
        case .rightCommand:
            guard e.getIntegerValueField(.keyboardEventKeycode) == rightCommandCode else { return }
            down = e.flags.contains(.maskCommand)
        case .off:
            return
        }
        guard down != held else { return }
        held = down
        DispatchQueue.main.async { down ? self.keyDown() : self.keyUp() }
    }

    // MARK: the pipeline

    private func keyDown() {
        guard !recorder.isRecording else { return }
        guard Recorder.isAuthorized else {
            Recorder.requestAccess { ok in
                Hud.shared.show(ok ? "Microphone allowed — hold the key again to dictate"
                                   : "Talk Talk Talk needs microphone access to dictate",
                                seconds: 4)
            }
            return
        }
        // Load the models while the key is held, so the wait after release
        // is transcription alone.
        Daemon.command("dictation_warm")
        // Speech from the speakers would otherwise end up in the transcript.
        if coord?.state == "playing" {
            pausedSpeech = true
            Daemon.pause()
        }
        do {
            try recorder.start()
            coord?.dictationState("listening")
        } catch {
            Hud.shared.show("Could not start recording: \(error.localizedDescription)", seconds: 4)
        }
    }

    private func keyUp() {
        guard recorder.isRecording else { return }
        let path = Paths.kokoroDir + "/dictation.wav"
        guard let rec = recorder.stop(to: path), rec.seconds >= minimumHold else {
            finish(nil, silent: true)
            return
        }
        coord?.dictationState("transcribing")
        let cfg = Config()
        let context = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        Daemon.request(["cmd": "transcribe", "path": path,
                        "cleanup": cfg.raw["dictation_cleanup"] as? Bool ?? true,
                        "context": context]) { [weak self] reply in
            self?.finish(reply)
        }
    }

    private func finish(_ reply: [String: Any]?, silent: Bool = false) {
        if pausedSpeech {
            pausedSpeech = false
            Daemon.resume()               // the daemon writes "playing" itself
        } else {
            coord?.dictationFinished()
        }
        guard let reply, reply["ok"] as? Bool == true,
              let text = reply["text"] as? String, !text.isEmpty else {
            let why = reply?["msg"] as? String ?? "no reply from the engine"
            if !silent, why != "nothing was said" {
                Hud.shared.show("Dictation: \(why)", seconds: 4)
            }
            return
        }
        if let ms = reply["ms"] as? [String: Any] {
            Log.write("dictation: stt \(ms["stt"] ?? "?")ms cleanup \(ms["cleanup"] ?? "-")ms "
                      + "\(reply["seconds"] ?? "?")s of speech")
        }
        if Config().raw["dictation_paste"] as? Bool ?? true {
            paste(text)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Hud.shared.show("Copied", seconds: 1)
        }
    }

    /// Put the text where the cursor is, then give the pasteboard back.
    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9   // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let previous, pb.string(forType: .string) == text {
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
    }
}
