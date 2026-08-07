#if os(macOS)
    import AppKit
    import Carbon.HIToolbox
    import SwiftUI

    /// A user-recorded key combination for the microphone mute shortcut.
    struct HotkeyCombo: Codable, Equatable, Sendable {
        /// Hardware key code (`kVK_*`), independent of keyboard layout.
        var keyCode: UInt16
        /// Raw `NSEvent.ModifierFlags`, limited to ⌘⌥⌃⇧.
        var modifiers: UInt
        /// Layout-resolved base character, lowercased — drives the menu key
        /// equivalent and the display string for ordinary keys.
        var character: String

        static let `default` = HotkeyCombo(
            keyCode: UInt16(kVK_ANSI_M),
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            character: "m")

        private static let comboFlags: NSEvent.ModifierFlags = [
            .command, .option, .control, .shift,
        ]

        /// Build from a recorder key-down. Returns nil for unusable combos:
        /// bare keys would fire while typing, so ⌘, ⌃, or ⌥ is required
        /// (function keys may stand alone).
        init?(recording event: NSEvent) {
            let flags = event.modifierFlags.intersection(Self.comboFlags)
            let isFunctionKey = Self.functionKeyNames[event.keyCode] != nil
            guard isFunctionKey || !flags.isDisjoint(with: [.command, .option, .control])
            else { return nil }
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty
            else { return nil }
            keyCode = event.keyCode
            modifiers = flags.rawValue
            character = characters.lowercased()
        }

        init(keyCode: UInt16, modifiers: UInt, character: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.character = character
        }

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

        var carbonModifiers: UInt32 {
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            return carbon
        }

        /// Menu key equivalent; nil for keys that don't map to one character.
        var keyEquivalent: KeyEquivalent? {
            guard character.count == 1, let first = character.first else { return nil }
            return KeyEquivalent(first)
        }

        var eventModifiers: SwiftUI.EventModifiers {
            var mods: SwiftUI.EventModifiers = []
            if flags.contains(.command) { mods.insert(.command) }
            if flags.contains(.option) { mods.insert(.option) }
            if flags.contains(.control) { mods.insert(.control) }
            if flags.contains(.shift) { mods.insert(.shift) }
            return mods
        }

        var displayString: String {
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            return text + keyName
        }

        private var keyName: String {
            if let name = Self.functionKeyNames[keyCode] ?? Self.specialKeyNames[keyCode] {
                return name
            }
            return character.uppercased()
        }

        private static let functionKeyNames: [UInt16: String] = [
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
            UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
            UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
        ]

        private static let specialKeyNames: [UInt16: String] = [
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Return): "Return",
            UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Delete): "Delete",
            UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_LeftArrow): "←",
            UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑",
            UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Home): "Home",
            UInt16(kVK_End): "End",
            UInt16(kVK_PageUp): "Page Up",
            UInt16(kVK_PageDown): "Page Down",
        ]

        var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

        static func decode(_ data: Data) -> HotkeyCombo? {
            try? JSONDecoder().decode(HotkeyCombo.self, from: data)
        }
    }

    /// FourCharCode "HmVo" — tags our hotkey in the Carbon callback.
    private let muteHotkeySignature: FourCharCode = 0x486D_566F

    /// Owns the mute-shortcut settings (persisted to UserDefaults) and the
    /// system-wide Carbon hotkey registration. In-app handling rides the
    /// Conversation menu's key equivalent; Carbon covers the global scope and
    /// consumes the key before the menu sees it, so the two never double-fire.
    /// Carbon hotkeys work in the sandbox with no accessibility permission.
    @MainActor
    @Observable
    final class MuteHotkeyManager {
        /// Fired on the main actor when the global hotkey is pressed.
        @ObservationIgnored var onToggleMute: (() -> Void)?

        var enabled: Bool { didSet { persistAndApply() } }
        var isGlobal: Bool { didSet { persistAndApply() } }
        var combo: HotkeyCombo { didSet { persistAndApply() } }

        @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
        @ObservationIgnored private var handlerRef: EventHandlerRef?

        private static let enabledKey = "muteHotkeyEnabled"
        private static let globalKey = "muteHotkeyGlobal"
        private static let comboKey = "muteHotkeyCombo"

        init() {
            let defaults = UserDefaults.standard
            enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
            isGlobal = defaults.bool(forKey: Self.globalKey)
            combo = defaults.data(forKey: Self.comboKey).flatMap(HotkeyCombo.decode) ?? .default
            applyRegistration()
        }

        private func persistAndApply() {
            let defaults = UserDefaults.standard
            defaults.set(enabled, forKey: Self.enabledKey)
            defaults.set(isGlobal, forKey: Self.globalKey)
            defaults.set(combo.encoded, forKey: Self.comboKey)
            applyRegistration()
        }

        private func applyRegistration() {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
                self.hotKeyRef = nil
            }
            guard enabled, isGlobal else { return }
            installHandlerIfNeeded()
            let hotKeyID = EventHotKeyID(signature: muteHotkeySignature, id: 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(combo.keyCode), combo.carbonModifiers, hotKeyID,
                GetEventDispatcherTarget(), 0, &ref)
            // Registration fails when another app owns the combo; the menu
            // key equivalent still covers in-app use.
            if status == noErr { hotKeyRef = ref }
        }

        /// One handler for the app's lifetime. `userData` is an unretained
        /// pointer back to this manager, which the app never deallocates.
        private func installHandlerIfNeeded() {
            guard handlerRef == nil else { return }
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetEventDispatcherTarget(),
                { _, event, userData in
                    guard let event, let userData else {
                        return OSStatus(eventNotHandledErr)
                    }
                    var hotKeyID = EventHotKeyID()
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                    guard hotKeyID.signature == muteHotkeySignature else {
                        return OSStatus(eventNotHandledErr)
                    }
                    // Carbon dispatches hotkey events on the main run loop.
                    MainActor.assumeIsolated {
                        Unmanaged<MuteHotkeyManager>.fromOpaque(userData)
                            .takeUnretainedValue()
                            .onToggleMute?()
                    }
                    return noErr
                },
                1, &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &handlerRef)
        }
    }
#endif
