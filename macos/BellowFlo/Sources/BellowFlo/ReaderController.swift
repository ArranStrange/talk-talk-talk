import AppKit

/// Silent RSVP reader. Holding R advances; nothing is spoken.
final class ReaderController: NSObject {
    private var panel: ReaderPanel?
    private var view: ReaderView?
    private var dimmers: [NSPanel] = []
    private var words: [String] = []
    private var index = 0
    private var advanceTimer: Timer?
    private var chipHold: DispatchWorkItem?
    private var chipFade: Timer?
    private var held = false
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?

    var isOpen: Bool { panel != nil }

    var status: String {
        guard isOpen else { return "closed" }
        return "open \(index + 1)/\(words.count): \(words.indices.contains(index) ? words[index] : "")"
    }

    // MARK: opening

    func open(text: String) {
        let list = Rsvp.words(text)
        guard !list.isEmpty else {
            Hud.shared.show("Nothing to read")
            return
        }
        close()
        words = list
        index = 0
        build()
        render()
    }

    private func build() {
        let active = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let active else { return }

        // dim every other display too, so nothing bright pulls the eye away
        for screen in NSScreen.screens where screen != active {
            let d = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            d.isOpaque = false
            d.backgroundColor = ReaderView.dim
            d.level = .modalPanel
            d.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                    .fullScreenAuxiliary]
            d.ignoresMouseEvents = true
            d.orderFrontRegardless()
            dimmers.append(d)
        }

        let v = ReaderView(frame: NSRect(origin: .zero, size: active.frame.size))
        let p = ReaderPanel(contentRect: active.frame,
                            styleMask: [.borderless],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .modalPanel
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                .fullScreenAuxiliary]
        p.contentView = v
        p.hidesOnDeactivate = false
        panel = p
        view = v

        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)

        // Key handling as a local monitor rather than a global tap: it only
        // sees events routed to us, so nothing can be swallowed system-wide
        // if the reader ever fails to close.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            guard let self, self.isOpen else { return event }
            return self.handle(event) ? nil : event
        }
    }

    // MARK: keys

    private enum Key {
        static let r = 15, escape = 53, up = 126, down = 125
        static let equals = 24, minus = 27, left = 123, right = 124
    }

    /// Returns true when the reader consumed the event. Every key it claims
    /// is claimed on both down and up, so a held key cannot leak a stray
    /// keyUp into the app underneath.
    private func handle(_ event: NSEvent) -> Bool {
        let code = Int(event.keyCode)
        let isDown = event.type == .keyDown

        if code == Key.r {
            if isDown {
                if !event.isARepeat, !held { held = true; startAdvancing() }
            } else {
                held = false
                stopAdvancing()
            }
            return true
        }

        let claimed = [Key.escape, Key.up, Key.down, Key.equals,
                       Key.minus, Key.left, Key.right]
        guard claimed.contains(code) else { return false }
        guard isDown else { return true }

        switch code {
        case Key.escape: close()
        case Key.up, Key.equals: changeSpeed(+25)
        case Key.down, Key.minus: changeSpeed(-25)
        case Key.left:
            index = max(0, index - 1)
            render()
        case Key.right:
            index = min(words.count - 1, index + 1)
            render()
        default: break
        }
        return true
    }

    private func changeSpeed(_ delta: Int) {
        Prefs.readerWpm = min(1200, max(100, Prefs.readerWpm + delta))
        showChip()
    }

    // MARK: advancing

    /// Per-word dwell: longer words need longer and punctuation earns a beat.
    /// The factors average near 1, so the stated WPM stays roughly honest.
    private func delay(for word: String) -> TimeInterval {
        let base = 60.0 / Double(Prefs.readerWpm)
        let lengthFactor = max(0.7, min(1.8, 0.7 + Double(word.count) / 12))
        var punct = 1.0
        let trimmed = word.hasSuffix("\"") || word.hasSuffix("'")
            ? String(word.dropLast()) : word
        if let last = trimmed.last {
            if ".!?".contains(last) { punct = 2.0 }
            else if ",;:".contains(last) { punct = 1.4 }
        }
        return base * lengthFactor * punct
    }

    private func startAdvancing() {
        guard advanceTimer == nil, isOpen, index < words.count - 1 else { return }
        schedule()
    }

    private func schedule() {
        let next = min(index + 1, words.count - 1)
        advanceTimer = Timer.scheduledTimer(withTimeInterval: delay(for: words[next]),
                                            repeats: false) { [weak self] _ in
            self?.advance()
        }
    }

    private func advance() {
        advanceTimer = nil
        guard isOpen, index < words.count - 1 else { return }
        index += 1
        render()
        if held { schedule() }
    }

    private func stopAdvancing() {
        advanceTimer?.invalidate()
        advanceTimer = nil
    }

    // MARK: rendering

    private func render() {
        guard let v = view, words.indices.contains(index) else { return }
        v.word = words[index]
        v.progress = CGFloat(index + 1) / CGFloat(max(words.count, 1))
        v.needsDisplay = true
    }

    private func showChip() {
        guard let v = view else { return }
        chipHold?.cancel()
        chipFade?.invalidate()
        chipFade = nil
        v.chipText = "\(Prefs.readerWpm) wpm"
        v.chipAlpha = 1
        v.needsDisplay = true

        let work = DispatchWorkItem { [weak self] in
            guard let self, let v = self.view else { return }
            var step = 0
            self.chipFade = Timer.scheduledTimer(withTimeInterval: 0.035,
                                                 repeats: true) { t in
                step += 1
                let a = 1 - CGFloat(step) / 12
                if a <= 0 {
                    t.invalidate()
                    v.chipAlpha = 0
                } else {
                    v.chipAlpha = a
                }
                v.needsDisplay = true
            }
        }
        chipHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: closing

    func close() {
        chipHold?.cancel(); chipHold = nil
        chipFade?.invalidate(); chipFade = nil
        stopAdvancing()
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        view = nil
        dimmers.forEach { $0.orderOut(nil) }
        dimmers.removeAll()
        held = false
        // hand focus back to whatever was in front before the reader opened
        previousApp?.activate()
        previousApp = nil
    }

    var position: (Int, Int) { (index + 1, words.count) }
}
