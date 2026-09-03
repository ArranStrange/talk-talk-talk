import Foundation

/// UI preferences that are ours alone — the engine never reads these.
enum Prefs {
    private static let d = UserDefaults.standard

    static var autoRead: Bool {
        get { d.bool(forKey: "autoRead") }
        set { d.set(newValue, forKey: "autoRead") }
    }
    static var readAlong: Bool {
        get { d.bool(forKey: "readAlong") }
        set { d.set(newValue, forKey: "readAlong") }
    }
    static var readerWpm: Int {
        get { d.object(forKey: "readerWpm") == nil ? 350 : d.integer(forKey: "readerWpm") }
        set { d.set(newValue, forKey: "readerWpm") }
    }
    /// The pill's top-right corner. Stored rather than the origin because
    /// the pill keeps its right edge fixed while its width changes with the
    /// label, so an origin would drift every time the state changed.
    static var pillAnchor: CGPoint? {
        get {
            guard let a = d.array(forKey: "pillAnchor") as? [Double], a.count == 2
            else { return nil }
            return CGPoint(x: a[0], y: a[1])
        }
        set {
            if let p = newValue { d.set([p.x, p.y], forKey: "pillAnchor") }
            else { d.removeObject(forKey: "pillAnchor") }
        }
    }
}
