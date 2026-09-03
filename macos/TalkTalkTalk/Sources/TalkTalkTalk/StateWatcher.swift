import Foundation

/// Watches the engine's directory for state changes.
///
/// FSEvents with NoDefer and a 20 ms latency, rather than the 300 ms the Lua
/// path watcher coalesced at — that lag was visible as the read-along drawer
/// trailing the speech by a word.
final class StateWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start() {
        guard stream == nil else { return }
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<StateWatcher>.fromOpaque(info).takeUnretainedValue()
            // eventPaths is a CFArray of CFString only because UseCFTypes is
            // set below. Without that flag it is a raw char ** and casting it
            // to NSArray segfaults on the first event.
            let list = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
            let touchedState = list.isEmpty || list.contains {
                ($0 as NSString).lastPathComponent == "state"
            }
            if touchedState { DispatchQueue.main.async { me.onChange() } }
            _ = count
        }
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, callback, &ctx,
                                     [Paths.kokoroDir] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     0.02, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
