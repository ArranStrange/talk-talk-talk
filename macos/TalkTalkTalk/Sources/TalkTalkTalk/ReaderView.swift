import AppKit

/// The full-screen reading surface: dim ground, one word, anchor guides,
/// a progress hairline, and the speed chip.
final class ReaderView: NSView {
    override var isFlipped: Bool { true }

    var word: String = ""
    var progress: CGFloat = 0
    var chipText: String = ""
    var chipAlpha: CGFloat = 0

    static let dim = NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 0.94)
    private static let accent = NSColor(srgbRed: 1, green: 0.36, blue: 0.30, alpha: 0.85)

    override func draw(_ dirty: NSRect) {
        let f = bounds
        ReaderView.dim.setFill()
        f.fill()

        let anchorX = f.width * Rsvp.anchorFraction
        let midY = f.height / 2

        if !word.isEmpty,
           let l = Rsvp.layout(word, baseSize: 64, minSize: 20,
                               leftRoom: anchorX - 40,
                               rightRoom: f.width - anchorX - 40) {
            l.attributed.draw(at: NSPoint(x: anchorX - l.anchorOffset,
                                          y: midY - l.size * 0.72))
            NSColor(white: 1, alpha: 0.3).setFill()
            NSBezierPath(rect: NSRect(x: anchorX - 1, y: midY - l.size * 0.95,
                                      width: 2, height: 14)).fill()
            NSBezierPath(rect: NSRect(x: anchorX - 1, y: midY + l.size * 0.62,
                                      width: 2, height: 14)).fill()
        }

        ReaderView.accent.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: f.height - 3,
                                  width: f.width * progress, height: 3)).fill()

        if chipAlpha > 0 {
            let w: CGFloat = 116, h: CGFloat = 34
            let r = NSRect(x: (f.width - w) / 2, y: f.height - 110, width: w, height: h)
            NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15,
                    alpha: 0.85 * chipAlpha).setFill()
            NSBezierPath(roundedRect: r, xRadius: 17, yRadius: 17).fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let s = NSAttributedString(string: chipText, attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(white: 1, alpha: 0.85 * chipAlpha),
                .paragraphStyle: style,
            ])
            s.draw(in: NSRect(x: r.minX, y: r.minY + 8, width: w, height: 20))
        }
    }
}

/// Borderless but focusable, so the reader gets ordinary key events instead
/// of needing a global event tap to steal them.
final class ReaderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
