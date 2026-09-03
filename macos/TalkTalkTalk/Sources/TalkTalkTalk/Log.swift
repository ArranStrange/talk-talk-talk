import Foundation

/// Appends to ~/Library/Logs/TalkTalkTalk.log. A menu bar app has nowhere to
/// print, and "it launched but nothing works" is otherwise unanswerable.
enum Log {
    private static let path = NSHomeDirectory() + "/Library/Logs/TalkTalkTalk.log"
    private static let queue = DispatchQueue(label: "ttt.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        queue.async {
            let line = "\(stamp.string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
