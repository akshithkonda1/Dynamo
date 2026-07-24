import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys (Carbon) so Dynamo stays useful without the menu open.
///
/// Defaults (Control + Option):
/// - D → Show / expand notch
/// - P → Play / Pause
/// - M → Mute / Unmute
/// - S → Focus File Shelf
/// - C → Focus Calendar
///
/// Not MainActor-isolated: Carbon installs from AppDelegate property init.
final class GlobalHotKeys: @unchecked Sendable {
    enum Action: UInt32, Sendable, CaseIterable {
        case showNotch = 1
        case playPause = 2
        case mute = 3
        case focusShelf = 4
        case focusCalendar = 5
        case focusToggle = 6
    }

    /// Called on the main actor.
    var onAction: (@MainActor (Action) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private let signature: OSType = 0x444E4D4F // 'DNMO'
    /// Actions that failed to register (shortcut conflict).
    private(set) var failedActions: [Action] = []

    var registrationSummary: String {
        if failedActions.isEmpty {
            return "All hotkeys registered (⌃⌥ D/P/M/S/C/F)."
        }
        let names = failedActions.map(\.label).joined(separator: ", ")
        return "Some hotkeys unavailable (conflict): \(names)."
    }

    func install() {
        uninstall()
        failedActions = []

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, let action = Action(rawValue: hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let callback = manager.onAction
            Task { @MainActor in
                callback?(action)
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let err = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPtr,
            &ref
        )
        guard err == noErr else { return }
        handlerRef = ref

        let mods = UInt32(controlKey | optionKey)
        register(keyCode: UInt32(kVK_ANSI_D), id: .showNotch, modifiers: mods)
        register(keyCode: UInt32(kVK_ANSI_P), id: .playPause, modifiers: mods)
        register(keyCode: UInt32(kVK_ANSI_M), id: .mute, modifiers: mods)
        register(keyCode: UInt32(kVK_ANSI_S), id: .focusShelf, modifiers: mods)
        register(keyCode: UInt32(kVK_ANSI_C), id: .focusCalendar, modifiers: mods)
        register(keyCode: UInt32(kVK_ANSI_F), id: .focusToggle, modifiers: mods)
    }

    func uninstall() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit {
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
    }

    private func register(keyCode: UInt32, id: Action, modifiers: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id.rawValue)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            hotKeyRefs.append(hotKeyRef)
        } else {
            failedActions.append(id)
        }
    }
}

extension GlobalHotKeys.Action {
    var label: String {
        switch self {
        case .showNotch: return "⌃⌥D"
        case .playPause: return "⌃⌥P"
        case .mute: return "⌃⌥M"
        case .focusShelf: return "⌃⌥S"
        case .focusCalendar: return "⌃⌥C"
        case .focusToggle: return "⌃⌥F"
        }
    }

    var actionName: String {
        switch self {
        case .showNotch: return "Show Notch"
        case .playPause: return "Play / Pause"
        case .mute: return "Mute / Unmute"
        case .focusShelf: return "Focus Shelf"
        case .focusCalendar: return "Focus Calendar"
        case .focusToggle: return "Toggle Focus Mode"
        }
    }
}
