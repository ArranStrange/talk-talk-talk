import AppKit

enum Destination { case speak, reader }

/// Owns the app's state and wires the pieces together — the part that was
/// the top half of init.lua.
final class Coordinator {
    static let shared = Coordinator()

    let pill = PillController()
    let reader = ReaderController()
    let tldr = Tldr()
    private var watcher: StateWatcher?
    private var fnWatcher: FnWatcher?
    private var readyTimer: Timer?
    private var trustTimer: Timer?
    private var menu: MenuBarController?

    private(set) var state = "idle"
    private var lastSeenState = "idle"
    private var autoPlayFired = false

    // MARK: lifecycle

    func start() {
        pill.onHit = { [weak self] in self?.handlePill($0) }

        menu = MenuBarController(coordinator: self)
        menu?.install()

        watcher = StateWatcher { [weak self] in self?.refresh() }
        watcher?.onWord = { [weak self] in self?.pill.wordFileChanged() }
        watcher?.start()

        let fn = FnWatcher { [weak self] in self?.state ?? "idle" }
        fn.start()
        fnWatcher = fn
        if !Selection.isTrusted { waitForAccessibility() }

        bindHotkeys()
        refresh()

        Log.write("started: hotkeys=\(Hotkeys.shared.count)/7 "
                  + "accessibility=\(Selection.isTrusted) "
                  + "engine=\(Paths.kokoroDir) "
                  + "menubar=\(menu != nil) state=\(state)")

        if !Selection.isTrusted {
            Hud.shared.show("Talk Talk Talk needs Accessibility permission\n"
                            + "to read the selected text", seconds: 5)
            Selection.requestTrust()
        }
    }

    /// Accessibility is usually granted a moment after first launch, and the
    /// Fn watcher's event tap can only be created once it is. Polling for it
    /// beats telling someone to quit and reopen the app.
    private func waitForAccessibility() {
        var attempts = 0
        trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) {
            [weak self] timer in
            attempts += 1
            guard let self else { timer.invalidate(); return }
            if Selection.isTrusted {
                timer.invalidate()
                self.trustTimer = nil
                self.fnWatcher?.start()
                Log.write("accessibility granted; dictation watcher started")
                Hud.shared.show("Accessibility granted — everything is live")
            } else if attempts > 100 {      // ~5 minutes, then stop asking
                timer.invalidate()
                self.trustTimer = nil
            }
        }
    }

    private func bindHotkeys() {
        let hk = Hotkeys.shared
        hk.install()
        hk.bind(Hotkeys.Key.s) { [weak self] in self?.readSelection(.speak) }
        hk.bind(Hotkeys.Key.r) { [weak self] in self?.readerHotkey() }
        hk.bind(Hotkeys.Key.p) { [weak self] in self?.playOrPause() }
        hk.bind(Hotkeys.Key.x) { [weak self] in self?.stopOrDismiss() }
        hk.bind(Hotkeys.Key.a) { [weak self] in self?.toggleAutoRead() }
        hk.bind(Hotkeys.Key.t) { [weak self] in self?.toggleTldr() }
        hk.bind(Hotkeys.Key.left) { Daemon.back() }
    }

    // MARK: state

    private func writeState(_ s: String) { Paths.write(s, to: Paths.state) }

    func refresh() {
        let raw = Paths.read(Paths.state)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let next = raw.isEmpty ? "idle" : raw

        // something genuinely new un-hides a pill that was dismissed with ✕
        if pill.hidden, next != lastSeenState,
           next == "ready" || next == "synthesizing" {
            pill.hidden = false
        }
        lastSeenState = next
        state = next

        readyTimer?.invalidate()
        readyTimer = nil
        menu?.updateGlyph(state: state)

        if state == "idle" {
            pill.hidden = false
            pill.hide()
            autoPlayFired = false
            return
        }
        if pill.hidden {
            pill.hide()
            return
        }

        // dictation in progress: stay quiet until Fn comes back up
        if state == "playing", let fn = fnWatcher, fn.isHeld, !fn.didAutoPause {
            fn.didAutoPause = true
            Daemon.pause()
        }

        pill.update(state: state, autoRead: Prefs.autoRead,
                    tldrOn: Config().tldrOn, readAlong: Prefs.readAlong)

        if state == "ready" {
            if Prefs.autoRead {
                if !autoPlayFired {
                    autoPlayFired = true
                    playPending(.speak)
                }
            } else {
                readyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) {
                    [weak self] _ in self?.dismissReady()
                }
            }
        } else {
            autoPlayFired = false
        }
    }

    func dismissReady() { writeState("idle") }

    // MARK: delivery

    private func deliver(_ text: String, to destination: Destination) {
        guard !text.isEmpty else { return }
        switch destination {
        case .speak: Daemon.say(text)
        case .reader: reader.open(text: text)
        }
    }

    /// TLDR decides whether the text is summarised; the caller decides where
    /// it lands. That split is what lets one shortcut serve both modes.
    func deliverFile(_ path: String, to destination: Destination) {
        let raw = Paths.read(path)
        if !Config().tldrOn || Tldr.tooShort(path) {
            deliver(raw.trimmingCharacters(in: .whitespacesAndNewlines),
                    to: destination)
            return
        }
        // Already summarised this text a moment ago — reuse it, so reading it
        // and then hearing it costs one call and gives identical wording.
        if let cached = SummaryCache.lookup(raw) {
            Log.write("summary reused from cache")
            deliver(cached, to: destination)
            return
        }
        guard !tldr.isRunning else { return }
        writeState("summarising")
        refresh()
        tldr.run(inputPath: path) { [weak self] result in
            guard let self else { return }
            switch result {
            case .summary(let summary):
                self.writeState("idle")
                SummaryCache.store(summary, for: raw)
                self.deliver(summary, to: destination)
            case .failed(let message):
                self.writeState("idle")
                self.refresh()
                if !message.isEmpty {
                    Hud.shared.show("TLDR failed: \(message)", seconds: 4)
                }
            }
        }
    }

    func playPending(_ destination: Destination = .speak) {
        deliverFile(Paths.pending, to: destination)
    }

    func cancelSummarise() {
        tldr.cancel()
        writeState("idle")
    }

    func readSelection(_ destination: Destination) {
        Selection.capture { [weak self] text in
            guard let self, let text else { return }
            guard Paths.write(text, to: Paths.selection) else {
                Hud.shared.show("Could not stage the selection")
                return
            }
            self.deliverFile(Paths.selection, to: destination)
        }
    }

    func speakClipboard(_ destination: Destination) {
        guard let clip = NSPasteboard.general.string(forType: .string),
              !clip.isEmpty else {
            Hud.shared.show("Clipboard is empty")
            return
        }
        guard Paths.write(clip, to: Paths.selection) else { return }
        deliverFile(Paths.selection, to: destination)
    }

    // MARK: actions

    func playOrPause() {
        if state == "ready" { playPending(.speak) } else { Daemon.toggle() }
    }

    func stopOrDismiss() {
        switch state {
        case "summarising": cancelSummarise()
        case "ready": dismissReady()
        default: Daemon.stop()
        }
    }

    private func readerHotkey() {
        if reader.isOpen { reader.close() } else { readSelection(.reader) }
    }

    func toggleAutoRead() {
        Prefs.autoRead.toggle()
        Hud.shared.show(Prefs.autoRead ? "Auto-read: ON" : "Auto-read: OFF")
        refresh()
        if Prefs.autoRead, state == "ready" { playPending(.speak) }
    }

    func toggleTldr() {
        let now = !Config().tldrOn
        Config.set("tldr_replies", now)
        Hud.shared.show(now ? "TLDR: ON" : "TLDR: OFF")
        refresh()
    }

    func toggleReadAlong() {
        Prefs.readAlong.toggle()
        Hud.shared.show(Prefs.readAlong ? "Read-along: ON" : "Read-along: OFF")
        refresh()
    }

    func bringPillToFront() {
        pill.bringToFront(currentState: state, autoRead: Prefs.autoRead,
                          tldrOn: Config().tldrOn, readAlong: Prefs.readAlong)
    }

    private func handlePill(_ hit: PillHit) {
        switch hit {
        case .auto:   toggleAutoRead()
        case .rsvp:   toggleReadAlong()
        case .tldr:   toggleTldr()
        case .back:   Daemon.back()
        case .toggle: playOrPause()
        case .stop:   stopOrDismiss()
        case .close, .bg: break        // handled in the view
        }
    }

    // MARK: quit

    func quit() {
        Log.write("quit requested")
        Daemon.quit()
        Hotkeys.shared.releaseAll()
        readyTimer?.invalidate()
        trustTimer?.invalidate()
        watcher?.stop()
        fnWatcher?.stop()
        tldr.cancel()
        reader.close()
        pill.teardown()
        menu?.remove()
        NSApp.terminate(nil)
    }
}
