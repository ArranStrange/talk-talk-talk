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
    // MARK: recent dictations

    struct Dictation: Codable, Equatable {
        let text: String
        /// The transcript before cleanup, when it differed.
        let raw: String?
        let date: Date
    }
    static let recentLimit = 10

    static var recentDictations: [Dictation] {
        get {
            guard let data = d.data(forKey: "recentDictations"),
                  let list = try? JSONDecoder().decode([Dictation].self, from: data)
            else { return [] }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue.prefix(recentLimit))) {
                d.set(data, forKey: "recentDictations")
            }
        }
    }

    /// Most recent first. Dictating the same thing again moves it to the top
    /// rather than listing it twice.
    static func remember(_ text: String, raw: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = recentDictations.filter { $0.text != t }
        list.insert(Dictation(text: t, raw: raw == t ? nil : raw, date: Date()), at: 0)
        recentDictations = list
    }

    static func clearRecentDictations() { d.removeObject(forKey: "recentDictations") }

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
