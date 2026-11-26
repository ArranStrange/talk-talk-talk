import Foundation

/// Where the Python speech engine lives. install.sh records the real path in
/// our defaults; the fallback is the location it has always used, so a hand
/// build still works without configuration.
enum Paths {
    /// The engine: code and, in a source checkout, its venv. Never written.
    static let kokoroDir: String = {
        if let d = UserDefaults.standard.string(forKey: "kokoroDir"),
           FileManager.default.fileExists(atPath: d) {
            return d
        }
        return NSHomeDirectory() + "/.claude/kokoro"
    }()

    /// Everything that changes: config, dictionary, the state and word files,
    /// staged text, the daemon's socket and log, model weights. Must match
    /// bf_paths.py, because the agent hooks find it without our help.
    static let dataDir: String = {
        if let d = ProcessInfo.processInfo.environment["BELLOWFLO_DATA"], !d.isEmpty {
            return d
        }
        return NSHomeDirectory() + "/Library/Application Support/Bellow Flo"
    }()

    /// Create the data folder, and on the first run after the code/data
    /// split carry the user's own files over from the engine folder, where
    /// they used to live. Copies, never moves; never overwrites.
    static func ensureDataDir() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dataDir + "/models",
                                withIntermediateDirectories: true)
        for name in ["config.json", "dictionary.txt", "notify_forward.json"] {
            let src = kokoroDir + "/" + name, dst = dataDir + "/" + name
            if fm.fileExists(atPath: src) && !fm.fileExists(atPath: dst) {
                try? fm.copyItem(atPath: src, toPath: dst)
            }
        }
    }

    static var socket: String { dataDir + "/daemon.sock" }
    static var state: String { dataDir + "/state" }
    static var word: String { dataDir + "/word" }
    static var pending: String { dataDir + "/pending.txt" }
    static var selection: String { dataDir + "/selection.txt" }
    static var config: String { dataDir + "/config.json" }
    static var dictionary: String { dataDir + "/dictionary.txt" }
    static var dictation: String { dataDir + "/dictation.wav" }
    static var daemonLog: String { dataDir + "/daemon.log" }
    static var tldrScript: String { kokoroDir + "/tldr.py" }
    static var daemonScript: String { kokoroDir + "/daemon.py" }
    static var venvPython: String { kokoroDir + "/venv/bin/python" }

    static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    @discardableResult
    static func write(_ text: String, to path: String) -> Bool {
        (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
}
