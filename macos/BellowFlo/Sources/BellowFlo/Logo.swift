import AppKit

/// The waveform mark, used for the menu bar item and the pill's status
/// indicator. Recoloured per state rather than redrawn, so the artwork
/// stays the single source of truth.
enum Logo {
    /// Loaded once. Nil if the bundle has no logo, in which case callers
    /// fall back to the text glyphs.
    private static let source: NSImage? = {
        guard let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }()

    /// The artwork is exported with transparent padding around the bars. At
    /// menu bar size that padding would eat most of the height, so the mark
    /// is trimmed to its ink once and the crop reused.
    private static let inkBounds: CGRect? = {
        guard let image = source,
              let tiff = image.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let data = bmp.bitmapData,
              bmp.samplesPerPixel == 4 else { return nil }
        let w = bmp.pixelsWide, h = bmp.pixelsHigh
        let rowBytes = bmp.bytesPerRow, pixelBytes = bmp.bitsPerPixel / 8
        var minX = w, minY = h, maxX = -1, maxY = -1
        // A straight memory scan: colorAt(x:y:) allocates per pixel and is
        // far too slow for a megapixel source.
        for y in 0..<h {
            let row = data + y * rowBytes
            for x in 0..<w where row[x * pixelBytes + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY,
                      width: maxX - minX + 1, height: maxY - minY + 1)
    }()

    /// Aspect ratio of the trimmed mark (width / height).
    static var aspect: CGFloat {
        guard let b = inkBounds, b.height > 0 else { return 1.26 }
        return b.width / b.height
    }

    static var isAvailable: Bool { source != nil && inkBounds != nil }

    private static var cache: [String: NSImage] = [:]

    /// The mark at `height` points, filled with `color`. Cached per
    /// height+colour, because the menu bar redraws on every state change.
    static func image(height: CGFloat, color: NSColor) -> NSImage? {
        guard let source, let ink = inkBounds else { return nil }
        let key = "\(Int(height * 2))-\(color.hashValue)"
        if let hit = cache[key] { return hit }

        let size = NSSize(width: (height * aspect).rounded(), height: height)
        let out = NSImage(size: size)
        out.lockFocus()
        defer { out.unlockFocus() }
        let rect = NSRect(origin: .zero, size: size)
        // Draw only the trimmed region, then flood the colour through the
        // artwork's own alpha so the shape keeps its rounded bar ends.
        source.draw(in: rect, from: ink, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        cache[key] = out
        return out
    }
}
