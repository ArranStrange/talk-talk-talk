import AppKit

/// Replaces hs.alert: a centred, self-dismissing message panel.
final class Hud {
    static let shared = Hud()
    private var panel: NSPanel?
    private var dismiss: DispatchWorkItem?

    func show(_ message: String, seconds: Double = 1.6) {
        DispatchQueue.main.async { self.present(message, seconds) }
    }

    private func present(_ message: String, _ seconds: Double) {
        dismiss?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 460
        let text = label.fittingSize
        let size = NSSize(width: min(max(text.width + 40, 150), 500),
                          height: text.height + 28)

        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let rect = NSRect(x: f.midX - size.width / 2,
                          y: f.minY + f.height * 0.22,
                          width: size.width, height: size.height)

        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        label.frame = NSRect(x: 20, y: 14, width: size.width - 40, height: text.height)
        bg.addSubview(label)
        p.contentView = bg
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
        panel = p

        let work = DispatchWorkItem { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
