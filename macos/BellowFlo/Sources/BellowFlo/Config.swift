import Foundation

/// The engine's config.json, shared with the Python side. Held as a raw
/// dictionary rather than a struct on purpose: the hook and tldr.py write
/// keys this app does not know about, and a Codable round-trip would erase
/// them on the next menu click.
struct Config {
    private(set) var raw: [String: Any]

    init() {
        let data = FileManager.default.contents(atPath: Paths.config) ?? Data()
        raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    var voice: String { raw["voice"] as? String ?? "af_heart" }
    var lang: String { raw["lang"] as? String ?? "en-us" }
    var speed: Double { (raw["speed"] as? NSNumber)?.doubleValue ?? 1.1 }
    var tldrOn: Bool { raw["tldr_replies"] as? Bool ?? false }
    var tldrProvider: String { raw["tldr_provider"] as? String ?? "claude-cli" }
    var tldrModel: String? { raw["tldr_model"] as? String }
    var tldrSentences: Int { (raw["tldr_sentences"] as? NSNumber)?.intValue ?? 3 }
    var tldrMinWords: Int { (raw["tldr_min_words"] as? NSNumber)?.intValue ?? 70 }
    var workspaceId: String? { raw["anthropic_workspace_id"] as? String }

    /// Read-modify-write, so two quick menu clicks cannot lose each other's key.
    static func update(_ change: (inout [String: Any]) -> Void) {
        var raw = Config().raw
        change(&raw)
        guard let data = try? JSONSerialization.data(withJSONObject: raw,
                                                     options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.config), options: .atomic)
    }

    static func set(_ key: String, _ value: Any?) {
        update { $0[key] = value }
    }
}
