import Foundation

/// Runs tldr.py. Kept cancellable because a provider can take tens of
/// seconds, and a wait you cannot call off reads as a hang.
final class Tldr {
    /// Not Swift's Result: the failure here is a message to show, not an
    /// Error, and an empty message means "cancelled, say nothing".
    enum Outcome {
        case summary(String)
        case failed(String)
    }

    private var task: Process?
    var isRunning: Bool { task != nil }

    /// True when the text is short enough that summarising it would cost a
    /// provider call to hand back roughly what went in.
    static func tooShort(_ path: String) -> Bool {
        let text = Paths.read(path)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return words < Config().tldrMinWords
    }

    func run(inputPath: String, done: @escaping (Outcome) -> Void) {
        guard task == nil else { return }
        guard let input = FileHandle(forReadingAtPath: inputPath) else {
            done(.failed("could not read the staged text"))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.tldrScript)
        p.standardInput = input
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.terminationHandler = { proc in
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.task = nil
                let summary = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 && !summary.isEmpty {
                    done(.summary(summary))
                } else if proc.terminationReason == .uncaughtSignal {
                    done(.failed(""))           // cancelled on purpose
                } else {
                    done(.failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
        do { try p.run() } catch {
            done(.failed(error.localizedDescription))
            return
        }
        task = p
    }

    func cancel() {
        task?.terminate()
        task = nil
    }
}
