import AppKit

/// Shared RSVP maths: which letter the eye lands on, and how wide text is.
/// Used by both the pill's read-along drawer and the full-screen reader, so
/// the anchor sits in the same place in each.
enum Rsvp {
    static let font = "Helvetica-Bold"
    static let orpColor = NSColor(srgbRed: 1, green: 0.36, blue: 0.30, alpha: 1)
    static let anchorFraction: CGFloat = 0.42

    /// Spritz-style pivot, 1-indexed, matching the original table exactly.
    static func orpIndex(_ length: Int) -> Int {
        if length <= 1 { return 1 }
        if length <= 5 { return 2 }
        if length <= 9 { return 3 }
        if length <= 13 { return 4 }
        return 5
    }

    /// NSFont(name:size:) goes through the font registry every call; the
    /// drawer asked for it four times per word, on every redraw.
    private static var fonts: [CGFloat: NSFont] = [:]
    static func font(_ size: CGFloat) -> NSFont {
        if let f = fonts[size] { return f }
        let f = NSFont(name: font, size: size) ?? .boldSystemFont(ofSize: size)
        fonts[size] = f
        return f
    }

    static func measure(_ s: String, size: CGFloat) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        return (s as NSString).size(withAttributes: [.font: font(size)]).width
    }

    /// The word split around its anchor letter, with the size shrunk only as
    /// far as needed to fit inside the room either side of the anchor.
    struct Layout {
        let attributed: NSAttributedString
        /// Distance from the string's left edge to the centre of the anchor.
        let anchorOffset: CGFloat
        let size: CGFloat
    }

    static func layout(_ word: String, baseSize: CGFloat, minSize: CGFloat,
                       leftRoom: CGFloat, rightRoom: CGFloat,
                       dimmed: Bool = false) -> Layout? {
        guard !word.isEmpty else { return nil }
        let chars = Array(word)
        let orp = min(orpIndex(chars.count), chars.count)
        let pre = String(chars[0..<(orp - 1)])
        let anchor = String(chars[orp - 1])

        var size = baseSize
        let leftNeed = measure(pre, size: size) + measure(anchor, size: size) / 2
        let rightNeed = measure(word, size: size) - leftNeed
        var scale: CGFloat = 1
        if leftNeed > 0 { scale = min(scale, leftRoom / leftNeed) }
        if rightNeed > 0 { scale = min(scale, rightRoom / rightNeed) }
        if scale < 1 { size = max(minSize, floor(size * scale)) }

        let f = font(size)
        let base = NSColor(white: 1, alpha: dimmed ? 0.5 : 0.97)
        let s = NSMutableAttributedString(string: word,
                                          attributes: [.font: f, .foregroundColor: base])
        let anchorRange = NSRange(location: pre.utf16.count, length: anchor.utf16.count)
        s.addAttribute(.foregroundColor,
                       value: orpColor.withAlphaComponent(dimmed ? 0.5 : 1),
                       range: anchorRange)
        let offset = measure(pre, size: size) + measure(anchor, size: size) / 2
        return Layout(attributed: s, anchorOffset: offset, size: size)
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
