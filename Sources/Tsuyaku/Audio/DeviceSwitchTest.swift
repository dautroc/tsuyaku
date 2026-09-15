import Foundation
import CoreAudio
import AVFoundation

/// Exercises `SystemAudioTap`'s recovery for real, in two parts:
///
///  1. **Device switch.** Move the system default output to another device and
///     back. This is the case that turns out *not* to break a process tap --
///     the test asserts capture is undisturbed, so that if some future change
///     starts tearing the graph down here, it shows up.
///  2. **Capture loss.** Kill the audio graph outright, exactly as an
///     unplugged device does, and assert the watchdog rebuilds it. This is the
///     failure that actually happens in a meeting.
///
/// Run with `Tsuyaku --device-switch-test` **with audio playing**; without a
/// signal to measure the test can only report INCONCLUSIVE.
///
/// Part 1 changes a real system setting. The original device is restored on
/// every exit path, including a thrown error partway through.
enum DeviceSwitchTest {

    static func run(seconds phase: Double = 4) async {
        print("=== device-change recovery test ===")

        guard let original = try? CA.defaultOutputDevice, original != kAudioObjectUnknown else {
            print("no default output device; cannot test"); return
        }
        guard let other = alternateOutputDevice(excluding: original) else {
            print("only one output device on this machine; cannot test a switch")
            print("plug in headphones or a monitor and try again")
            return
        }

        print("  default output : \(CA.deviceName(original))")
        print("  will switch to : \(CA.deviceName(other))")
        print("")

        // Recovery notifications arrive on the tap's queue; funnel them here.
        let events = Recorder()
        let tap = SystemAudioTap(bundleIDs: [], outputFormat: analyzerFormat()) { event in
            events.record(event)
        }

        do {
            try tap.start()
        } catch {
            print("could not start capture: \(error)")
            print("(if this is a permissions error, run the signed app bundle, not .build/)")
            return
        }
        defer {
            try? tap.stop()
            // Only undo our own change. If something else moved the default
            // meanwhile -- headphones connecting mid-test, say -- leave it
            // alone rather than yanking the user back to the old device.
            if (try? CA.defaultOutputDevice) == other { setDefaultOutput(original) }
        }

        let counter = Counter()
        let pump = Task { for await chunk in tap.buffers { counter.add(chunk) } }
        defer { pump.cancel() }

        let baseline = await measure("baseline", phase, counter)

        print("")
        print("--- part 1: default output device switch ---")
        print("  -> switching default output to \(CA.deviceName(other))")
        guard setDefaultOutput(other) else {
            print("  could not set default output device; aborting"); return
        }
        let afterSwitch = await measure("after switch", phase, counter)

        print("  -> restoring default output to \(CA.deviceName(original))")
        if (try? CA.defaultOutputDevice) == other { setDefaultOutput(original) }
        let afterRestore = await measure("after restore", phase, counter)

        print("")
        print("--- part 2: capture loss (the unplugged-headphones case) ---")
        print("  -> killing the audio graph")
        tap.simulateCaptureLoss()
        // The watchdog needs stallThreshold (3s) to notice, plus a rebuild.
        let duringOutage = await measure("during outage", 2, counter)
        let afterRecovery = await measure("after recovery", 6, counter)

        print("")
        let log = events.drain()
        if log.isEmpty { print("  (no recovery events)") }
        for line in log { print("  event: \(line)") }
        print("")

        // Baseline can legitimately be zero if nothing is playing, in which
        // case the test proves nothing -- say so rather than passing silently.
        guard baseline > 0 else {
            print("verdict: INCONCLUSIVE -- no audio captured even before the switch.")
            print("Play something (afplay /tmp/ja-meeting.aiff &) and re-run.")
            return
        }

        // A phase counts as capturing only if a decent share of its chunks
        // carried signal; a handful could just be the tail of a fade-out.
        let floor = max(3, baseline / 10)
        var failures: [String] = []
        if afterSwitch < floor  { failures.append("capture died on the device switch") }
        if afterRestore < floor { failures.append("capture died on the device restore") }
        // The whole point of part 2: the graph must be dead, then come back.
        if duringOutage >= floor {
            failures.append("simulated capture loss did not actually stop the audio, "
                            + "so the recovery below proves nothing")
        }
        if afterRecovery < floor { failures.append("the watchdog did not recover capture") }

        if failures.isEmpty {
            print("verdict: PASS -- survived a device switch, and recovered from capture loss")
        } else {
            print("verdict: FAIL")
            for f in failures { print("  - \(f)") }
            print("  (a phase needed >= \(floor) chunks with signal to count as capturing)")
        }
    }

    // MARK: -

    /// Returns the number of chunks in this phase that carried actual signal.
    ///
    /// Counting chunks alone proves nothing: the IOProc keeps firing at the
    /// device's rate whether or not any audio is reaching the tap, so a broken
    /// capture still produces a full complement of silent buffers. Only
    /// amplitude distinguishes "capturing" from "connected to nothing".
    private static func measure(_ label: String, _ seconds: Double, _ c: Counter) async -> Int {
        let before = c.snapshot()
        try? await Task.sleep(for: .seconds(seconds))
        let after = c.snapshot()
        let chunks = after.chunks - before.chunks
        let loud = after.loud - before.loud
        let peak = c.peakSince(before)
        print("  \(label.padding(toLength: 14, withPad: " ", startingAt: 0)): "
              + "\(chunks) chunks, \(loud) with signal, peak \(String(format: "%.3f", peak))")
        return loud
    }

    /// The analyzer's format is 16 kHz mono Int16; hardcoded here so the test
    /// doesn't need the speech model installed just to move audio.
    private static func analyzerFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                      channels: 1, interleaved: true)!
    }

    private static func alternateOutputDevice(excluding current: AudioObjectID) -> AudioObjectID? {
        let all = (try? CA.array(AudioObjectID(kAudioObjectSystemObject),
                                 CA.address(kAudioHardwarePropertyDevices),
                                 of: AudioObjectID.self)) ?? []
        return all.first { id in
            guard id != current else { return false }
            // Output devices only: something with at least one output stream.
            let size = try? CA.dataSize(id, CA.address(kAudioDevicePropertyStreams,
                                                       kAudioObjectPropertyScopeOutput))
            return (size ?? 0) > 0
        }
    }

    @discardableResult
    private static func setDefaultOutput(_ device: AudioObjectID) -> Bool {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value)
        return status == noErr
    }

    /// Buffers arrive on a real-time thread and recovery events on the tap's
    /// queue, so both need somewhere thread-safe to land.
    private final class Counter: @unchecked Sendable {
        struct Snapshot { let chunks: Int; let loud: Int; let peakLog: [Float] }

        /// RMS below this is silence, in the 0...1 normalised scale. Meeting
        /// speech sits two orders of magnitude above it.
        private static let silenceFloor: Float = 0.002

        private let lock = NSLock()
        private var chunks = 0
        private var loud = 0
        private var peaks: [Float] = []

        func add(_ chunk: AudioChunk) {
            let rms = Self.rms(chunk.buffer)
            lock.lock()
            chunks += 1
            if rms > Self.silenceFloor { loud += 1 }
            peaks.append(rms)
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return Snapshot(chunks: chunks, loud: loud, peakLog: peaks)
        }

        /// Loudest chunk seen since the given snapshot.
        func peakSince(_ s: Snapshot) -> Float {
            lock.lock(); defer { lock.unlock() }
            return peaks.dropFirst(s.peakLog.count).max() ?? 0
        }

        private static func rms(_ b: AVAudioPCMBuffer) -> Float {
            guard let data = b.int16ChannelData, b.frameLength > 0 else { return 0 }
            let n = Int(b.frameLength)
            var sum: Double = 0
            for i in 0..<n {
                let v = Double(data[0][i]) / 32768.0
                sum += v * v
            }
            return Float((sum / Double(n)).squareRoot())
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func record(_ e: SystemAudioTap.RecoveryEvent) {
            let text: String
            switch e {
            case .rebuilt(let d): text = "rebuilt on \(d)"
            case .failed(let m):  text = "FAILED: \(m)"
            }
            lock.lock(); items.append(text); lock.unlock()
        }
        func drain() -> [String] {
            lock.lock(); defer { items.removeAll(); lock.unlock() }; return items
        }
    }
}
