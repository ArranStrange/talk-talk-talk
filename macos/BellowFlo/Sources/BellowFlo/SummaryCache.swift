import CryptoKit
import Foundation

/// Remembers summaries for a few minutes so the same text is not summarised
/// twice.
///
/// The case that matters: send a selection to the reader with TL;DR on, read
/// it, then decide you want to hear it as well. Without this, the second
/// shortcut spends another provider call — and another wait — to produce a
/// summary you already have. Worse, a fresh call can word it differently, so
/// what you hear would not match what you just read.
enum SummaryCache {
    /// Deliberately short. This exists to join up two actions on one piece of
    /// text, not to be a general cache — text edited in the meantime should
    /// get a fresh summary, and a stale summary is worse than a slow one.
    static let ttl: TimeInterval = 5 * 60
    private static let maxEntries = 8

    private struct Entry {
        let summary: String
        let at: Date
    }

    private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()

    /// Settings that change the wording are part of the identity, so flipping
    /// provider or summary length is not served from the cache.
    private static func key(for text: String) -> String {
        let cfg = Config()
        let digest = SHA256.hash(data: Data(text.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
        return [digest, cfg.tldrProvider, cfg.tldrModel ?? "",
                String(cfg.tldrSentences)].joined(separator: "|")
    }

    static func lookup(_ text: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        prune()
        return entries[key(for: text)]?.summary
    }

    static func store(_ summary: String, for text: String) {
        lock.lock(); defer { lock.unlock() }
        entries[key(for: text)] = Entry(summary: summary, at: Date())
        prune()
    }

    /// Called under the lock.
    private static func prune() {
        let cutoff = Date().addingTimeInterval(-ttl)
        entries = entries.filter { $0.value.at > cutoff }
        if entries.count > maxEntries {
            let oldest = entries.sorted { $0.value.at < $1.value.at }
                .prefix(entries.count - maxEntries)
            for (k, _) in oldest { entries.removeValue(forKey: k) }
        }
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
