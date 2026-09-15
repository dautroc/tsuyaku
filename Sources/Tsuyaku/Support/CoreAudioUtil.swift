import Foundation
import CoreAudio

/// Thin typed wrappers over the AudioObject property API, which is otherwise
/// a wall of `withUnsafeMutablePointer` at every call site.
enum CA {

    struct Err: Error, CustomStringConvertible {
        let status: OSStatus
        let op: String
        var description: String {
            let c = withUnsafeBytes(of: status.bigEndian) { raw in
                String(bytes: raw.filter { $0 >= 32 && $0 < 127 }, encoding: .ascii) ?? ""
            }
            return "\(op) failed: \(status)\(c.count == 4 ? " '\(c)'" : "")"
        }
    }

    static func check(_ status: OSStatus, _ op: String) throws {
        guard status == noErr else { throw Err(status: status, op: op) }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func dataSize(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> UInt32 {
        var size: UInt32 = 0
        var a = addr
        try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "GetPropertyDataSize")
        return size
    }

    /// Read a fixed-layout value (CFTypeRef, AudioObjectID, AudioStreamBasicDescription, ...).
    static func value<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default def: T) throws -> T {
        var a = addr
        var out = def
        var size = UInt32(MemoryLayout<T>.size)
        // Form the raw pointer explicitly: `&out` on a generic T makes the
        // compiler warn that T might hold an object reference. It sometimes
        // does -- CFString -- and writing the CFStringRef into it is exactly
        // what the CoreAudio API expects.
        try withUnsafeMutablePointer(to: &out) { p in
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size,
                                                 UnsafeMutableRawPointer(p)), "GetPropertyData")
        }
        return out
    }

    /// Read a variable-length array property (device lists, process lists, ...).
    static func array<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of: T.Type) throws -> [T] {
        let size = try dataSize(object, addr)
        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        var a = addr
        var buf = [T](unsafeUninitializedCapacity: count) { _, c in c = count }
        var sz = size
        try buf.withUnsafeMutableBufferPointer { p in
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &sz, p.baseAddress!), "GetPropertyData[]")
        }
        return buf
    }

    static func string(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> String {
        let cf: CFString = try value(object, addr, default: "" as CFString)
        return cf as String
    }

    // MARK: - Convenience

    static var defaultOutputDevice: AudioObjectID {
        get throws {
            try value(AudioObjectID(kAudioObjectSystemObject),
                      address(kAudioHardwarePropertyDefaultOutputDevice),
                      default: AudioObjectID(kAudioObjectUnknown))
        }
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        try string(device, address(kAudioDevicePropertyDeviceUID))
    }

    /// Human-readable device name, for status messages. The UID is stable but
    /// unreadable ("BuiltInSpeakerDevice"), which is no use in the panel.
    static func deviceName(_ device: AudioObjectID) -> String {
        (try? string(device, address(kAudioObjectPropertyName))) ?? "unknown device"
    }

    /// Resolve a bundle identifier to its AudioObjectID, if that process is
    /// currently running and known to the HAL.
    static func processObject(forBundleID bundleID: String) throws -> AudioObjectID? {
        let processes = try array(AudioObjectID(kAudioObjectSystemObject),
                                  address(kAudioHardwarePropertyProcessObjectList),
                                  of: AudioObjectID.self)
        for p in processes {
            let bid = try? string(p, address(kAudioProcessPropertyBundleID))
            if let bid, bid == bundleID { return p }
        }
        return nil
    }

    static func runningOutputBundleIDs() throws -> [String] {
        let processes = try array(AudioObjectID(kAudioObjectSystemObject),
                                  address(kAudioHardwarePropertyProcessObjectList),
                                  of: AudioObjectID.self)
        return processes.compactMap { p in
            guard let bid = try? string(p, address(kAudioProcessPropertyBundleID)), !bid.isEmpty
            else { return nil }
            let running: UInt32 = (try? value(p, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0
            return running != 0 ? bid : nil
        }
    }
}
