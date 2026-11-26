import Foundation

/// Where the Python speech engine lives. install.sh records the real path in
/// our defaults; the fallback is the location it has always used, so a hand
/// build still works without configuration.
enum Paths {
    static let kokoroDir: String = {
        if let d = UserDefaults.standard.string(forKey: "kokoroDir"),
           FileManager.default.fileExists(atPath: d) {
            return d
        }
        return NSHomeDirectory() + "/.claude/kokoro"
    }()

    static var socket: String { kokoroDir + "/daemon.sock" }
    static var state: String { kokoroDir + "/state" }
    static var word: String { kokoroDir + "/word" }
    static var pending: String { kokoroDir + "/pending.txt" }
    static var selection: String { kokoroDir + "/selection.txt" }
    static var config: String { kokoroDir + "/config.json" }
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
