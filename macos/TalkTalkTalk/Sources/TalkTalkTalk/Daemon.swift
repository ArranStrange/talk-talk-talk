import Foundation

/// Talks to the speech daemon over its unix socket directly.
///
/// The Lua version shelled out to `ktts` for every button press, which paid
/// Python interpreter startup (~120 ms) just to write one JSON line. Here a
/// click is a socket write, so the transport is no longer the slow part.
enum Daemon {
    private static let queue = DispatchQueue(label: "ttt.daemon")

    private static func connectFd() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Paths.socket
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                _ = strlcpy(dst, path, capacity)
            }
        }
        let connected = withUnsafePointer(to: &addr) { ap -> Bool in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !connected { close(fd); return nil }
        return fd
    }

    /// Start the daemon and wait for its socket to appear. Only ever called
    /// when a command needs a daemon that is not running.
    private static func startDaemon() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Paths.venvPython) else {
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.venvPython)
        p.arguments = [Paths.daemonScript]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        for _ in 0..<80 {                       // up to 8 s: first run loads the model
            if let fd = connectFd() { close(fd); return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Fire and forget. `boot` is false for commands that should not bring a
    /// daemon up just to be told there is nothing to do.
    static func send(_ request: [String: Any], boot: Bool = true) {
        queue.async {
            guard let data = try? JSONSerialization.data(withJSONObject: request)
            else { return }
            var fd = connectFd()
            if fd == nil {
                guard boot, startDaemon(), let retry = connectFd() else { return }
                fd = retry
            }
            guard let sock = fd else { return }
            defer { close(sock) }
            data.withUnsafeBytes { buf in
                _ = Darwin.send(sock, buf.baseAddress, buf.count, 0)
            }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = recv(sock, &buf, buf.count, 0)   // drained so the daemon can close
            // A refused command used to fail silently, which is how "nothing
            // happens" bugs stay unexplained. Record it instead.
            if n > 0,
               let reply = try? JSONSerialization.jsonObject(
                   with: Data(buf[0..<n])) as? [String: Any],
               reply["ok"] as? Bool == false {
                let cmd = request["cmd"] as? String ?? "?"
                Log.write("daemon refused \(cmd): \(reply["msg"] as? String ?? "")")
            }
        }
    }

    static func command(_ cmd: String, boot: Bool = true) {
        send(["cmd": cmd], boot: boot)
    }

    static func say(_ text: String) {
        let cfg = Config()
        send(["cmd": "say", "text": text, "voice": cfg.voice,
              "speed": cfg.speed, "lang": cfg.lang])
    }

    static func back(_ seconds: Double = 10) {
        send(["cmd": "back", "seconds": seconds])
    }

    static func stop()  { command("stop", boot: false) }
    static func quit()  { command("quit", boot: false) }
    static func toggle() { command("toggle") }
    static func pause() { command("pause", boot: false) }
    static func resume() { command("resume", boot: false) }
}
