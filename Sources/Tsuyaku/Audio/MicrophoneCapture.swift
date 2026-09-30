import AVFoundation
import OSLog

/// The user's own voice, from the default input device, converted to the
/// format the English recognizer negotiated.
///
/// The counterpart to `SystemAudioTap`, which hears everyone else. The two
/// are separate on purpose: the tap captures what the Mac *plays*, and a
/// meeting app never plays the user's own voice back to them.
///
/// `AVAudioEngine` rather than a Core Audio IOProc: the input side has none of
/// the tap's aggregate-device machinery to manage, and the engine already
/// follows the default input device -- it posts a configuration change when a
/// headset is plugged in, and this restarts on the new device and format.
///
/// No voice processing. Its echo cancellation would also duck the meeting's
/// own audio, which is exactly what the subtitle side is listening to; the
/// answer to echo is headphones.
final class MicrophoneCapture: @unchecked Sendable {

    enum CaptureError: Error, LocalizedError {
        case noInput
        var errorDescription: String? {
            switch self {
            case .noInput: "no microphone available"
            }
        }
    }

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "mic")
    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat

    /// Buffers already converted to `outputFormat`. Bounded like the tap's: a
    /// stalled recognizer drops its oldest audio rather than growing forever.
    let buffers: AsyncStream<AudioChunk>
    private let yield: @Sendable (AudioChunk) -> Void
    private let finishStream: @Sendable () -> Void

    /// Serialises start, stop and the configuration-change restart, which
    /// arrives on a thread of AppKit's choosing.
    private let lock = NSLock()
    private var running = false
    private var configObserver: NSObjectProtocol?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
        var c: AsyncStream<AudioChunk>.Continuation!
        buffers = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        let cont = c!
        yield = { cont.yield($0) }
        finishStream = { cont.finish() }
    }

    /// Asks once, then remembers: the TCC prompt appears on the first call
    /// only. `false` once the user has said no, until they change it in
    /// System Settings.
    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

    func start() throws {
        try lock.withLock {
            try startEngine()
            running = true
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.restart() }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        lock.withLock {
            running = false
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        finishStream()
    }

    /// The input format is read fresh every time: it is whatever the current
    /// default device delivers, and it changes with the device.
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        let converter = try FormatConverter(from: format, to: outputFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [yield] buffer, time in
            guard let out = converter.convert(buffer.audioBufferList) else { return }
            yield(AudioChunk(buffer: out, hostTime: time.hostTime))
        }
        engine.prepare()
        try engine.start()
        log.info("microphone capture at \(format.sampleRate)Hz x\(format.channelCount)")
    }

    /// The default input changed, or its format did. The engine has already
    /// stopped itself; start it again around the new device.
    private func restart() {
        lock.withLock {
            guard running else { return }
            engine.stop()
            do {
                try startEngine()
            } catch {
                log.error("microphone restart failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
