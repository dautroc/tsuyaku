import Foundation
import CoreAudio
import AVFoundation
import OSLog
import Synchronization

/// Captures another application's audio output via a Core Audio process tap.
///
/// Why taps rather than ScreenCaptureKit: the TCC prompt reads "would like
/// access to record your system audio" and the grant lands under
/// "System Audio Recording Only" -- no screen-recording language, no purple
/// menu-bar indicator, no periodic re-prompt, and no video pipeline to run and
/// throw away. macOS 26 added `bundleIDs` and `processRestoreEnabled`, so the
/// tap reattaches to the target app across relaunches.
///
/// The audio still reaches the speakers (`muteBehavior = .unmuted`); this is a
/// tap, not an interception.
///
/// ## Surviving device changes
///
/// The aggregate device needs a real output device as its clock, and if that
/// device goes away -- Bluetooth headphones walking out of range, a USB
/// interface unplugged -- the IOProc stops firing and capture goes silent with
/// no error and no callback.
///
/// The clock does not have to be the device the user is listening on. The
/// process tap captures upstream of any device, so the sub-device is little
/// more than a clock; measured, audio keeps flowing when the default output
/// switches away from it. So the graph is built on the Mac's built-in output
/// where there is one, and on the default output only where there is not.
///
/// A Bluetooth headset makes a poor clock. It sleeps when idle, it leaves, and
/// the moment any app opens its microphone -- a Meet call, Translate My Voice
/// -- it drops into the hands-free profile and changes rate and shape under
/// the aggregate. Built on HUAWEI FreeClip 2 with its microphone open, the
/// IOProc never fired again and the watchdog rebuilt every four seconds
/// without once getting audio back.
///
/// So the health signal is the audio itself. The IOProc fires continuously
/// while the graph is alive -- ~95 times a second, silence included -- so
/// "no buffers at all for `stallThreshold`" is an unambiguous death signal,
/// and it catches every cause rather than the one cause we predicted. The
/// device listener is a latency optimisation on top: when the device we built
/// on disappears we can rebuild at once instead of waiting for the stall to
/// be detected.
final class SystemAudioTap: @unchecked Sendable {

    /// What happened when the output device changed underneath us.
    enum RecoveryEvent: Sendable {
        case rebuilt(device: String)
        /// Capture is down and will not come back on its own.
        case failed(String)
    }

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "tap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: FormatConverter?

    /// Empty = tap all system audio except ourselves.
    private let bundleIDs: [String]
    private let outputFormat: AVAudioFormat
    private let onRecovery: (@Sendable (RecoveryEvent) -> Void)?

    /// Serializes every mutation of the audio graph: `start`, `stop`, and the
    /// device-change listener all run here, so a rebuild can never interleave
    /// with a teardown.
    private let queue = DispatchQueue(label: "com.loind.tsuyaku.tap")
    private var running = false
    /// Bumped on every device-change notification so that a burst of them
    /// collapses into one rebuild.
    private var rebuildGeneration = 0
    /// UID of the output device the current aggregate is built on, so the
    /// device listener can tell "my device vanished" from "something else
    /// changed".
    private var builtOnDeviceUID: String?
    /// `.failed` is reported once per outage, not once per retry.
    private var reportedFailure = false

    /// Uptime nanoseconds of the last buffer out of the IOProc. Written from a
    /// real-time thread, so it has to be lock-free -- and boxed in a class
    /// because `Atomic` is non-copyable and the IOProc closure captures it.
    private let lastBufferAt = BufferClock()
    private var watchdog: DispatchSourceTimer?

    /// The IOProc runs at roughly 95 Hz. Three seconds of complete silence
    /// from it is not a quiet room, it is a dead graph.
    private static let stallThreshold: UInt64 = 3_000_000_000
    private static let watchdogInterval: DispatchTimeInterval = .milliseconds(1000)

    /// Guards `listenerBlock` only. Registration has to happen off `queue`,
    /// because `AudioObjectRemovePropertyListenerBlock` may wait for in-flight
    /// callbacks to drain -- and those callbacks run on `queue`.
    private let listenerLock = NSLock()
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Emits buffers already converted to `outputFormat`.
    ///
    /// Survives a rebuild: only `stop()` ever finishes this stream, so the
    /// downstream `for await` loop stays alive across a device change.
    let buffers: AsyncStream<AudioChunk>
    private let yield: @Sendable (AudioChunk) -> Void
    private let finish: @Sendable () -> Void

    init(bundleIDs: [String],
         outputFormat: AVAudioFormat,
         onRecovery: (@Sendable (RecoveryEvent) -> Void)? = nil) {
        self.bundleIDs = bundleIDs
        self.outputFormat = outputFormat
        self.onRecovery = onRecovery
        var c: AsyncStream<AudioChunk>.Continuation!
        // .bufferingNewest keeps the real-time IOProc from ever blocking: if the
        // transcriber stalls we drop the oldest audio rather than the audio thread.
        self.buffers = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        let cont = c!
        self.yield = { cont.yield($0) }
        self.finish = { cont.finish() }
    }

    deinit { try? stop() }

    // MARK: - Lifecycle

    func start() throws {
        try queue.sync {
            guard !running else { return }
            try buildGraph()
            running = true
            startWatchdog()
        }
        addDefaultDeviceListener()
    }

    func stop() throws {
        removeDefaultDeviceListener()
        queue.sync {
            watchdog?.cancel()
            watchdog = nil
            teardownGraph()
            running = false
        }
        finish()
    }

    // MARK: - Graph

    /// Everything from the tap to a started IOProc. Called on `queue`.
    private func buildGraph() throws {
        try createTap()
        let tapFormat = try tapStreamFormat()
        log.info("tap format: \(tapFormat.sampleRate)Hz ch=\(tapFormat.channelCount)")
        converter = try FormatConverter(from: tapFormat, to: outputFormat)
        try createAggregateDevice()
        try installIOProc()
        try CA.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        // Give the new graph a full grace period before the watchdog judges it.
        lastBufferAt.stamp()
    }

    /// Called on `queue`. Must be safe to call when the graph is already down,
    /// because a failed rebuild leaves it half-built.
    private func teardownGraph() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
        builtOnDeviceUID = nil
    }

    // MARK: - Recovery

    /// The catch-all health check: if no audio has come out of the IOProc for
    /// `stallThreshold`, the graph is dead whatever killed it.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.watchdogInterval,
                       repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        watchdog = timer
        timer.resume()
    }

    /// Runs on `queue`.
    private func checkForStall() {
        guard running else { return }
        let last = lastBufferAt.last
        let elapsed = DispatchTime.now().uptimeNanoseconds &- last
        guard elapsed > Self.stallThreshold else { return }
        log.notice("no audio for \(elapsed / 1_000_000)ms; rebuilding capture")
        rebuild(attempt: 0)
    }

    /// Faster path for the common case: the device we built on was removed.
    /// Purely an optimisation -- the watchdog would catch it a moment later.
    private func addDefaultDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.devicesChanged()
        }
        var addr = CA.address(kAudioHardwarePropertyDevices)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        guard status == noErr else {
            // Not fatal: the watchdog still covers this, just less promptly.
            log.error("could not observe the device list: \(status)")
            return
        }
        listenerLock.lock()
        listenerBlock = block
        listenerLock.unlock()
    }

    private func removeDefaultDeviceListener() {
        listenerLock.lock()
        let block = listenerBlock
        listenerBlock = nil
        listenerLock.unlock()
        guard let block else { return }
        var addr = CA.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
    }

    /// Runs on `queue`.
    private func devicesChanged() {
        guard running, let builtOn = builtOnDeviceUID else { return }
        guard !deviceExists(uid: builtOn) else { return }   // still there: nothing to do

        // A removal can fire this more than once as the HAL settles, and each
        // rebuild tears down a graph. Coalesce.
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self, self.running, generation == self.rebuildGeneration else { return }
            self.log.notice("capture device removed; rebuilding")
            self.rebuild(attempt: 0)
        }
    }

    private func deviceExists(uid: String) -> Bool {
        let all = (try? CA.array(AudioObjectID(kAudioObjectSystemObject),
                                 CA.address(kAudioHardwarePropertyDevices),
                                 of: AudioObjectID.self)) ?? []
        return all.contains { (try? CA.deviceUID($0)) == uid }
    }

    /// Runs on `queue`.
    ///
    /// Rebuilds the tap as well as the aggregate: the replacement output
    /// device can have a different sample rate or channel count, so the tap's
    /// own format -- and therefore the converter -- may change too.
    private func rebuild(attempt: Int) {
        guard running else { return }
        teardownGraph()
        do {
            try buildGraph()
            let name = CA.deviceName((try? CA.defaultOutputDevice) ?? AudioObjectID(kAudioObjectUnknown))
            log.info("capture graph rebuilt on \(name, privacy: .public)")
            reportedFailure = false
            onRecovery?(.rebuilt(device: name))
        } catch {
            // Device transitions are racy: the HAL can report a device before
            // it will host an aggregate, so early failures are worth retrying.
            let message = String(describing: error)
            if attempt < Self.maxRebuildAttempts {
                log.notice("rebuild attempt \(attempt + 1) failed (\(message, privacy: .public)); retrying")
                queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                    self?.rebuild(attempt: attempt + 1)
                }
            } else {
                // Give up this round but leave the watchdog running: headphones
                // come back, and a later tick should reconnect. Report once.
                log.error("capture rebuild gave up: \(message, privacy: .public)")
                if !reportedFailure {
                    reportedFailure = true
                    onRecovery?(.failed(message))
                }
                lastBufferAt.stamp()
            }
        }
    }

    private static let maxRebuildAttempts = 3

    // MARK: - Testing

    /// Kills the audio graph without clearing `running`, exactly as an
    /// unplugged device does: the IOProc simply stops. Used by
    /// `--device-switch-test` to prove the watchdog actually recovers.
    func simulateCaptureLoss() {
        queue.sync {
            guard running else { return }
            log.notice("simulating capture loss")
            teardownGraph()
        }
    }

    // MARK: - Steps

    private func createTap() throws {
        // Empty process list + bundleIDs: the HAL resolves the bundle IDs itself
        // and, with processRestoreEnabled, re-resolves them when the app relaunches.
        let desc: CATapDescription
        if bundleIDs.isEmpty {
            // Global tap: everything except this process, so our own UI sounds
            // never feed back into the transcriber.
            let selfObject = (try? CA.processObject(forBundleID: Bundle.main.bundleIdentifier ?? "")) ?? nil
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: selfObject.map { [$0] } ?? [])
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: [])
            desc.bundleIDs = bundleIDs
        }
        desc.name = "Tsuyaku Tap"
        desc.isProcessRestoreEnabled = true
        desc.isPrivate = true          // don't advertise this tap to other apps
        desc.muteBehavior = .unmuted   // the user must still hear the meeting
        try CA.check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")
        guard tapID != kAudioObjectUnknown else {
            throw CA.Err(status: -1, op: "process tap returned kAudioObjectUnknown")
        }
    }

    private func tapStreamFormat() throws -> AVAudioFormat {
        let asbd: AudioStreamBasicDescription = try CA.value(
            tapID, CA.address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
        var mutable = asbd
        guard let fmt = AVAudioFormat(streamDescription: &mutable) else {
            throw CA.Err(status: -1, op: "AVAudioFormat from tap ASBD")
        }
        return fmt
    }

    private func tapUID() throws -> String {
        try CA.string(tapID, CA.address(kAudioTapPropertyUID))
    }

    /// The aggregate needs a real output device as its main sub-device, with the
    /// tap attached under kAudioAggregateDeviceTapListKey as a *sub-tap*.
    /// Adding the tap as a sub-*device* is the classic mistake here and silently
    /// produces an aggregate that yields no audio.
    private func createAggregateDevice() throws {
        let clock = try CA.builtInOutputDevice ?? CA.defaultOutputDevice
        let outputUID = try CA.deviceUID(clock)
        builtOnDeviceUID = outputUID
        log.info("capture clocked on \(CA.deviceName(clock), privacy: .public)")
        let tapUID = try tapUID()
        let uid = "com.loind.tsuyaku.aggregate.\(UUID().uuidString)"

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey:        "Tsuyaku Capture",
            kAudioAggregateDeviceUIDKey:         uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey:   true,
            kAudioAggregateDeviceIsStackedKey:   false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        try CA.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "AudioHardwareCreateAggregateDevice")
    }

    private func installIOProc() throws {
        let converter = self.converter!
        let yield = self.yield

        // This block runs on a real-time audio thread. It must not allocate
        // unboundedly, lock, or call into Swift concurrency. FormatConverter
        // reuses preallocated buffers; AsyncStream.yield with a bounded
        // .bufferingNewest policy is non-blocking.
        let clock = self.lastBufferAt
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, nil
        ) { _, inInputData, inInputTime, _, _ in
            // Stamped before conversion: a converter failure is still proof
            // that the graph is alive, and the watchdog only asks that.
            clock.stamp()
            guard let out = converter.convert(inInputData) else { return }
            yield(AudioChunk(buffer: out, hostTime: inInputTime.pointee.mHostTime))
        }
        try CA.check(status, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
    }
}

/// A lock-free timestamp shared between the real-time IOProc and the watchdog.
private final class BufferClock: Sendable {
    private let value = Atomic<UInt64>(0)
    /// Safe to call from a real-time audio thread: no locks, no allocation.
    func stamp() { value.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed) }
    var last: UInt64 { value.load(ordering: .relaxed) }
}
