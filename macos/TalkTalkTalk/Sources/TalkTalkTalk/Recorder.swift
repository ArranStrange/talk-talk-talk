import AVFoundation

/// Captures the microphone as 16 kHz mono 16-bit PCM and writes a WAV.
///
/// Recording lives in the app rather than the daemon because microphone
/// permission is granted per application, and a Python child process is
/// an awkward thing to grant it to.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private let queue = DispatchQueue(label: "ttt.recorder")
    private(set) var startedAt: Date?

    static let sampleRate: Double = 16000

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { done(ok) }
        }
    }

    var isRecording: Bool { startedAt != nil }

    func start() throws {
        guard startedAt == nil else { return }
        pcm = Data()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: Recorder.sampleRate,
                                            channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "ttt", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no audio converter"])
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            self?.convert(buf, to: outFormat)
        }
        engine.prepare()
        try engine.start()
        startedAt = Date()
    }

    private func convert(_ buf: AVAudioPCMBuffer, to outFormat: AVAudioFormat) {
        guard let conv = converter else { return }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
        else { return }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.int16ChannelData else { return }
        let bytes = Int(out.frameLength) * 2
        let chunk = Data(bytes: ch[0], count: bytes)
        queue.sync { pcm.append(chunk) }
    }

    /// Stops and writes the WAV. Returns the file path and its duration.
    func stop(to path: String) -> (path: String, seconds: Double)? {
        guard let began = startedAt else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startedAt = nil
        converter = nil
        let data: Data = queue.sync { pcm }
        let seconds = Double(data.count / 2) / Recorder.sampleRate
        guard Recorder.writeWav(data, to: path) else { return nil }
        _ = began
        return (path, seconds)
    }

    static func writeWav(_ pcm: Data, to path: String) -> Bool {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + pcm.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!)
        u32(UInt32(pcm.count))
        d.append(pcm)
        return (try? d.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
