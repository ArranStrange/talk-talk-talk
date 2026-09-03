import AppKit

/// Colours and labels, kept identical to the Lua version so the thing looks
/// the same after the port.
enum Look {
    static let dot: [String: NSColor] = [
        "loading":      NSColor(srgbRed: 0.95, green: 0.60, blue: 0.10, alpha: 1),
        "synthesizing": NSColor(srgbRed: 0.95, green: 0.60, blue: 0.10, alpha: 1),
        "playing":      NSColor(srgbRed: 0.25, green: 0.80, blue: 0.35, alpha: 1),
        "paused":       NSColor(srgbRed: 0.95, green: 0.85, blue: 0.20, alpha: 1),
        "ready":        NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 1),
        "summarising":  NSColor(srgbRed: 0.62, green: 0.45, blue: 0.95, alpha: 1),
    ]
    static let label: [String: String] = [
        "loading": "Loading model…", "synthesizing": "Preparing…",
        "playing": "Speaking", "paused": "Paused",
        "ready": "Agent replied", "summarising": "Summarising…",
    ]
    static let on = NSColor(srgbRed: 0.25, green: 0.80, blue: 0.35, alpha: 0.95)
    static let off = NSColor(white: 1, alpha: 0.30)
    static let barColor = NSColor(srgbRed: 0.25, green: 0.80, blue: 0.35, alpha: 0.95)
}

enum PillHit: String { case bg, auto, tldr, back, toggle, stop, rsvp, close }

/// Flipped so every rect below is the same top-left geometry the canvas used.
final class PillView: NSView {
    override var isFlipped: Bool { true }

    var state = "idle"
    var autoRead = false
    var tldrOn = false
    var readAlong = false
    var waveHeights: [CGFloat] = Array(repeating: 8, count: 5)
    var word: String = ""

    var onHit: ((PillHit) -> Void)?
    var onDragStart: (() -> Void)?

    private var hitRects: [(PillHit, NSRect)] = []
    private(set) var drawerOpen = false

    static let barCount = 5
    static let pillHeight: CGFloat = 36
    static let drawerHeight: CGFloat = 92

    // MARK: layout

    /// Returns the width the pill wants for the current content, and records
    /// the button rects for hit testing. Mirrors layoutPill().
    func computeLayout() -> CGSize {
        let labelWidth: CGFloat = state == "playing"
            ? 46
            : floor(CGFloat((Look.label[state] ?? state).count) * 7.2) + 8
        let autoX  = 36 + labelWidth + 4
        let tldrX  = autoX + 46
        let backX  = tldrX + 48
        let togX   = backX + 30
        let stopX  = togX + 32
        let rsvpX  = stopX + 30
        let closeX = rsvpX + 22
        let w      = closeX + 22 + 8

        self.labelRect = NSRect(x: 36, y: 8, width: labelWidth, height: 20)
        hitRects = [
            (.auto,   NSRect(x: autoX, y: 11, width: 42, height: 16)),
            (.tldr,   NSRect(x: tldrX, y: 11, width: 44, height: 16)),
            (.back,   NSRect(x: backX, y: 6, width: 30, height: 26)),
            (.toggle, NSRect(x: togX, y: 5, width: 32, height: 26)),
            (.stop,   NSRect(x: stopX, y: 5, width: 32, height: 26)),
            (.rsvp,   NSRect(x: rsvpX, y: 7, width: 22, height: 22)),
            (.close,  NSRect(x: closeX, y: 8, width: 22, height: 20)),
        ]
        drawerOpen = readAlong && (state == "playing" || state == "paused")
        return CGSize(width: w,
                      height: drawerOpen ? PillView.drawerHeight : PillView.pillHeight)
    }

    private var labelRect = NSRect.zero
    private func rect(_ h: PillHit) -> NSRect {
        hitRects.first { $0.0 == h }?.1 ?? .zero
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        let w = bounds.width
        let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height),
                              xRadius: 18, yRadius: 18)
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 0.92).setFill()
        bg.fill()

        (Look.dot[state] ?? Look.dot["playing"]!).setFill()
        NSBezierPath(ovalIn: NSRect(x: 21 - 5.5, y: 18 - 5.5, width: 11, height: 11)).fill()

        if state == "playing" {
            Look.barColor.setFill()
            for i in 0..<PillView.barCount {
                let bh = waveHeights[i]
                NSBezierPath(roundedRect: NSRect(x: 40 + CGFloat(i) * 8, y: 18 - bh / 2,
                                                 width: 4.5, height: bh),
                             xRadius: 2, yRadius: 2).fill()
            }
        } else {
            draw(Look.label[state] ?? state, in: labelRect, size: 13,
                 color: NSColor(white: 1, alpha: 0.95), align: .left)
        }

        let controls = (state == "playing" || state == "paused" || state == "ready")
        draw("AUTO", in: rect(.auto), size: 11,
             color: autoRead ? Look.on : Look.off, align: .center)
        draw("TL;DR", in: rect(.tldr), size: 10,
             color: tldrOn ? Look.on : Look.off, align: .center)
        draw("⏪\u{FE0E}", in: rect(.back), size: 18,
             color: NSColor(white: 1, alpha: (state == "playing" || state == "paused") ? 0.95 : 0.25),
             align: .center)
        draw((state == "paused" || state == "ready") ? "▶" : "⏸", in: rect(.toggle), size: 18,
             color: NSColor(white: 1, alpha: controls ? 0.95 : 0.25), align: .center)
        draw("⏹", in: rect(.stop), size: 18,
             color: NSColor(white: 1, alpha: state != "loading" ? 0.95 : 0.25), align: .center)
        draw("▾", in: rect(.rsvp), size: 15,
             color: readAlong ? Look.on : Look.off, align: .center)
        draw("✕", in: rect(.close), size: 13,
             color: NSColor(white: 1, alpha: 0.45), align: .center)

        if drawerOpen { drawDrawer(width: w) }
    }

    /// The read-along word, its anchor letter pinned to a fixed x so the eye
    /// never travels between words.
    private func drawDrawer(width w: CGFloat) {
        guard !word.isEmpty else { return }
        let left: CGFloat = 14, right = w - 14, y: CGFloat = 46
        let anchorX = left + (right - left) * Rsvp.anchorFraction
        guard let l = Rsvp.layout(word, baseSize: 26, minSize: 12,
                                  leftRoom: anchorX - left,
                                  rightRoom: right - anchorX,
                                  dimmed: state == "paused") else { return }
        l.attributed.draw(at: NSPoint(x: anchorX - l.anchorOffset, y: y))
        NSColor(white: 1, alpha: 0.25).setFill()
        NSBezierPath(rect: NSRect(x: anchorX - 0.75, y: y - 7, width: 1.5, height: 6)).fill()
        NSBezierPath(rect: NSRect(x: anchorX - 0.75, y: y + 36, width: 1.5, height: 6)).fill()
    }

    private func draw(_ text: String, in r: NSRect, size: CGFloat,
                      color: NSColor, align: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        // vertically centre inside the slot, which text frames in the canvas
        // model did implicitly
        let h = s.size().height
        let box = NSRect(x: r.minX, y: r.minY + (r.height - h) / 2,
                         width: r.width, height: h)
        s.draw(in: box)
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hitRects.first(where: { $0.1.contains(p) })?.0 {
            onHit?(hit)
        } else {
            onDragStart?()
        }
    }
}
