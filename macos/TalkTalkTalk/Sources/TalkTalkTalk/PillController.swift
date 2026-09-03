import AppKit

/// The floating status pill: window management, the waveform animation, and
/// the read-along word poll.
final class PillController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var view: PillView?
    private var waveTimer: Timer?
    private var wordTimer: Timer?
    private var lastWord: String?
    private var idleHide: DispatchWorkItem?

    /// ✕ was clicked: stay away until something genuinely new happens.
    var hidden = false

    var onHit: ((PillHit) -> Void)?

    private func build() {
        let v = PillView()
        v.onHit = { [weak self] hit in
            if hit == .close {
                self?.hidden = true
                self?.hide()
            } else {
                self?.onHit?(hit)
            }
        }
        v.onDragStart = { [weak self] in
            guard let p = self?.panel, let e = NSApp.currentEvent else { return }
            p.performDrag(with: e)
        }

        let size = NSSize(width: 272, height: PillView.pillHeight)
        let origin = PillController.origin(for: size)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.contentView = v
        p.delegate = self
        p.alphaValue = 0
        panel = p
        view = v
        Log.write("pill built: \(facts)")
    }

    /// Bottom-left origin for a pill of `size`, honouring the remembered
    /// top-right anchor, clamped back onto a screen that still exists.
    private static func origin(for size: NSSize) -> CGPoint {
        if let a = Prefs.pillAnchor,
           NSScreen.screens.contains(where: { $0.frame.contains(a) }) {
            return CGPoint(x: a.x - size.width, y: a.y - size.height)
        }
        return defaultOrigin(for: size)
    }

    private static func defaultOrigin(for size: NSSize) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return CGPoint(x: 100, y: 100) }
        return CGPoint(x: f.maxX - size.width - 14, y: f.maxY - size.height - 10)
    }

    func windowDidMove(_ notification: Notification) {
        guard let p = panel, p.alphaValue > 0 else { return }
        Prefs.pillAnchor = CGPoint(x: p.frame.maxX, y: p.frame.maxY)
    }

    // MARK: state

    func update(state: String, autoRead: Bool, tldrOn: Bool, readAlong: Bool) {
        if panel == nil { build() }
        guard let p = panel, let v = view else { return }
        idleHide?.cancel()

        v.state = state
        v.autoRead = autoRead
        v.tldrOn = tldrOn
        v.readAlong = readAlong

        let size = v.computeLayout()
        resize(p, to: size)
        Log.write("pill \(state): \(facts)")

        if state == "playing" {
            startWave()
        } else {
            stopWave()
        }
        if v.drawerOpen { startWordPoll() } else { stopWordPoll() }
        v.needsDisplay = true
        show()
    }

    /// Right edge stays put as the width changes, and the drawer grows
    /// downward so the control row never moves under the cursor.
    private func resize(_ p: NSPanel, to size: CGSize) {
        let old = p.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5
        else { return }
        let origin = CGPoint(x: old.maxX - size.width, y: old.maxY - size.height)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func show() {
        guard let p = panel, !hidden else { return }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        stopWave()
        stopWordPoll()
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { [weak p] in p?.orderOut(nil) })
    }

    /// Recovery for a pill dragged off-screen or onto a display that has
    /// since been unplugged: forget the saved position and show it resting.
    func bringToFront(currentState: String, autoRead: Bool, tldrOn: Bool,
                      readAlong: Bool) {
        hidden = false
        if panel == nil { build() }
        guard let p = panel, let v = view else { return }
        v.state = currentState == "idle" ? "idle" : currentState
        v.autoRead = autoRead; v.tldrOn = tldrOn; v.readAlong = readAlong
        let size = v.computeLayout()
        let origin = PillController.defaultOrigin(for: size)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        Prefs.pillAnchor = CGPoint(x: origin.x + size.width,
                                   y: origin.y + size.height)
        p.level = .screenSaver
        v.needsDisplay = true
        show()
        if currentState == "idle" {
            // long enough to actually find once the menu has closed
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            idleHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        }
        Hud.shared.show("Pill is at the top right", seconds: 2)
    }

    // MARK: animation

    private func startWave() {
        guard waveTimer == nil else { return }
        waveTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let v = self?.view else { return }
            v.waveHeights = (0..<PillView.barCount).map { _ in CGFloat.random(in: 5...24) }
            v.needsDisplay = true
        }
    }

    private func stopWave() {
        waveTimer?.invalidate()
        waveTimer = nil
    }

    /// Polled rather than watched: the word file changes at speech pace and
    /// filesystem notifications coalesce too slowly to keep up.
    private func startWordPoll() {
        guard wordTimer == nil else { return }
        wordTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self, let v = self.view else { return }
            let w = Paths.read(Paths.word).trimmingCharacters(in: .whitespacesAndNewlines)
            guard w != self.lastWord else { return }
            self.lastWord = w
            v.word = w
            v.needsDisplay = true
        }
    }

    private func stopWordPoll() {
        wordTimer?.invalidate()
        wordTimer = nil
        lastWord = nil
    }

    func teardown() {
        stopWave()
        stopWordPoll()
        idleHide?.cancel()
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    var facts: String {
        guard let p = panel else { return "pill=nil" }
        return String(format: "frame=%.0f,%.0f %.0fx%.0f alpha=%.2f hidden=%@",
                      p.frame.origin.x, p.frame.origin.y, p.frame.width,
                      p.frame.height, p.alphaValue, hidden ? "true" : "false")
    }
}
