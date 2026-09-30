import AppKit
import Carbon.HIToolbox
import OSLog

/// A keyboard shortcut that works while any app is in front.
///
/// Carbon's `RegisterEventHotKey`, old as it is, because it is the one
/// system-wide shortcut API that needs no permission: an `NSEvent` global
/// monitor sees every keystroke and so needs Accessibility access, which is
/// one more TCC grant for a re-signed build to lose. A hot key is delivered
/// only to the app that registered it, and nothing else is visible.
///
/// The key is taken from every other app while this one runs, which is why
/// the combination has three modifiers. Registration fails if another app
/// already holds it; the caller keeps working without the shortcut.
@MainActor
final class GlobalHotKey {

    private static let log = Logger(subsystem: "com.loind.tsuyaku", category: "hotkey")
    /// "TSYK", so the hot key IDs are ours.
    private static let signature: OSType = 0x5453_594B
    private static var nextID: UInt32 = 1

    private let id: EventHotKeyID
    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Lives as long as the app: nothing here ever unregisters it.
    init?(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping @MainActor () -> Void) {
        id = EventHotKeyID(signature: Self.signature, id: Self.nextID)
        Self.nextID += 1
        self.action = action

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application-target events on the main thread.
            return MainActor.assumeIsolated {
                // Every handler on the app target sees every hot key; pass
                // on the ones that belong to another instance.
                guard read == noErr,
                      pressedID.signature == hotKey.id.signature,
                      pressedID.id == hotKey.id.id else { return OSStatus(eventNotHandledErr) }
                hotKey.action()
                return noErr
            }
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            Self.log.error("hot key handler not installed: \(installed)")
            return nil
        }

        let registered = RegisterEventHotKey(keyCode, Self.carbonModifiers(modifiers), id,
                                             GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            // eventHotKeyExistsErr: another app already owns the combination.
            Self.log.error("hot key not registered: \(registered)")
            RemoveEventHandler(handler)
            return nil
        }
    }

    /// Carbon's modifier bits for AppKit's flags. Only the four a hot key
    /// can use; anything else is ignored.
    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits = 0
        if flags.contains(.command) { bits |= cmdKey }
        if flags.contains(.option)  { bits |= optionKey }
        if flags.contains(.control) { bits |= controlKey }
        if flags.contains(.shift)   { bits |= shiftKey }
        return UInt32(bits)
    }
}
