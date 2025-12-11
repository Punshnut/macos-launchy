import AppKit
import Carbon

/// Descriptor describing the key code/modifier combination for a global hotkey.
struct HotkeyDescriptor: Equatable, Hashable, Codable {
    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    let keyCode: UInt32
    private let modifierFlagsRawValue: UInt
    private let keyRepresentation: String?

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifierFlagsRawValue
        case keyRepresentation
    }

    /// Modern modifier flags.
    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    /// Default shortcut used to toggle the launcher when no preference is stored.
    static let toggleLauncher = HotkeyDescriptor(
        keyCode: UInt32(kVK_Space),
        modifierFlags: [.command, .shift],
        keyRepresentation: "Space"
    )

    init(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags, keyRepresentation: String? = nil) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = HotkeyDescriptor.filtered(modifierFlags).rawValue
        self.keyRepresentation = keyRepresentation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let rawFlags = try container.decode(UInt.self, forKey: .modifierFlagsRawValue)
        modifierFlagsRawValue = HotkeyDescriptor.filtered(NSEvent.ModifierFlags(rawValue: rawFlags)).rawValue
        keyRepresentation = try container.decodeIfPresent(String.self, forKey: .keyRepresentation)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifierFlagsRawValue, forKey: .modifierFlagsRawValue)
        try container.encodeIfPresent(keyRepresentation, forKey: .keyRepresentation)
    }

    /// Converts modern `NSEvent` modifiers to the Carbon bitmask expected by `RegisterEventHotKey`.
    var carbonModifierMask: UInt32 {
        var mask: UInt32 = 0
        if modifierFlags.contains(.command) {
            mask |= UInt32(cmdKey)
        }
        if modifierFlags.contains(.option) {
            mask |= UInt32(optionKey)
        }
        if modifierFlags.contains(.shift) {
            mask |= UInt32(shiftKey)
        }
        if modifierFlags.contains(.control) {
            mask |= UInt32(controlKey)
        }
        return mask
    }

    /// User-facing description for display inside the settings UI.
    var displayString: String {
        let parts = modifierDisplayParts()
        let keyText = keyDisplayText().isEmpty ? "Key \(keyCode)" : keyDisplayText()
        return (parts + [keyText]).joined(separator: " + ")
    }

    /// Creates a descriptor from a key event, filtering unsupported modifiers.
    init?(event: NSEvent) {
        let sanitizedModifiers = HotkeyDescriptor.filtered(event.modifierFlags)
        self.init(
            keyCode: UInt32(event.keyCode),
            modifierFlags: sanitizedModifiers,
            keyRepresentation: HotkeyDescriptor.displayNameForKey(event)
        )
    }

    private static func filtered(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(relevantModifiers)
    }

    private func modifierDisplayParts() -> [String] {
        var parts: [String] = []
        if modifierFlags.contains(.command) {
            parts.append("Cmd")
        }
        if modifierFlags.contains(.option) {
            parts.append("Option")
        }
        if modifierFlags.contains(.shift) {
            parts.append("Shift")
        }
        if modifierFlags.contains(.control) {
            parts.append("Ctrl")
        }
        return parts
    }

    private func keyDisplayText() -> String {
        keyRepresentation ?? Self.displayName(for: keyCode)
    }

    private static func displayNameForKey(_ event: NSEvent) -> String {
        let trimmed = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return displayName(for: UInt32(event.keyCode))
        }
        if trimmed == " " {
            return "Space"
        }
        return trimmed.uppercased()
    }

    private static func displayName(for keyCode: UInt32) -> String {
        if let known = keyCodeLabels[keyCode] {
            return known
        }

        if keyCode >= UInt32(kVK_F1) && keyCode <= UInt32(kVK_F20) {
            let functionIndex = Int(keyCode - UInt32(kVK_F1)) + 1
            return "F\(functionIndex)"
        }

        return "Key \(keyCode)"
    }

    /// Basic lookup table for readable key names.
    private static let keyCodeLabels: [UInt32: String] = [
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_LeftArrow): "Left Arrow",
        UInt32(kVK_RightArrow): "Right Arrow",
        UInt32(kVK_UpArrow): "Up Arrow",
        UInt32(kVK_DownArrow): "Down Arrow",
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_ANSI_Keypad0): "Keypad 0",
        UInt32(kVK_ANSI_Keypad1): "Keypad 1",
        UInt32(kVK_ANSI_Keypad2): "Keypad 2",
        UInt32(kVK_ANSI_Keypad3): "Keypad 3",
        UInt32(kVK_ANSI_Keypad4): "Keypad 4",
        UInt32(kVK_ANSI_Keypad5): "Keypad 5",
        UInt32(kVK_ANSI_Keypad6): "Keypad 6",
        UInt32(kVK_ANSI_Keypad7): "Keypad 7",
        UInt32(kVK_ANSI_Keypad8): "Keypad 8",
        UInt32(kVK_ANSI_Keypad9): "Keypad 9",
        UInt32(kVK_JIS_KeypadComma): "Keypad ,",
        UInt32(kVK_ANSI_KeypadDecimal): "Keypad .",
        UInt32(kVK_ANSI_KeypadEnter): "Keypad Enter",
        UInt32(kVK_ANSI_KeypadPlus): "Keypad +",
        UInt32(kVK_ANSI_KeypadMinus): "Keypad -",
        UInt32(kVK_ANSI_KeypadMultiply): "Keypad *",
        UInt32(kVK_ANSI_KeypadDivide): "Keypad /",
        UInt32(kVK_ANSI_KeypadEquals): "Keypad ="
    ]
}

/// Abstraction describing something that can register/unregister a global hotkey.
protocol HotkeyRegistering {
    func beginListening(descriptor: HotkeyDescriptor, handler: @escaping () -> Void) -> Bool
    func endListening()
}

/// Coordinates registering a system-wide hotkey and notifying observers when it fires.
@MainActor
final class HotkeyManager {
    private var registeredHotkey: HotkeyDescriptor?
    private let hotkeyRegistrar: HotkeyRegistering
    private var isHotkeyActive = false

    /// Invoked whenever the registered hotkey is pressed.
    var onHotkeyPressed: (() -> Void)?

    init(descriptor: HotkeyDescriptor? = .toggleLauncher, registrar: HotkeyRegistering = CarbonHotkeyRegistrar()) {
        self.registeredHotkey = descriptor
        self.hotkeyRegistrar = registrar
    }

    /// Updates the hotkey descriptor and restarts listening if needed.
    func update(descriptor: HotkeyDescriptor?) {
        guard registeredHotkey != descriptor else { return }
        registeredHotkey = descriptor
        restart()
    }

    /// Attempts to register the configured hotkey, no-opping if already active.
    func activate() {
        guard isHotkeyActive == false else { return }
        guard let registeredHotkey else { return }

        let didRegisterHotkey = hotkeyRegistrar.beginListening(descriptor: registeredHotkey) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onHotkeyPressed?()
            }
        }

        if didRegisterHotkey {
            isHotkeyActive = true
        } else {
            assertionFailure("Failed to register global hotkey.")
        }
    }

    /// Unregisters the hotkey so it is released back to the system.
    func deactivate() {
        guard isHotkeyActive else { return }
        hotkeyRegistrar.endListening()
        isHotkeyActive = false
    }

    private func restart() {
        deactivate()
        activate()
    }
}

/// Carbon-backed registrar that wires a hotkey into the traditional macOS event system.
final class CarbonHotkeyRegistrar: HotkeyRegistering {
    private static let hotKeySignature: OSType = 0x4C59484B // 'LYHK'

    private var keyboardEventHandler: EventHandlerRef?
    private var registeredHotKey: EventHotKeyRef?
    private var isHotKeyRegistered = false
    private lazy var hotKeyID: EventHotKeyID = {
        let rawID = UInt32(truncatingIfNeeded: ObjectIdentifier(self).hashValue)
        return EventHotKeyID(signature: Self.hotKeySignature, id: rawID | 1)
    }()
    private var registeredHandler: (() -> Void)?

    deinit {
        endListening()
        if let handler = keyboardEventHandler {
            RemoveEventHandler(handler)
        }
    }

    func beginListening(descriptor: HotkeyDescriptor, handler: @escaping () -> Void) -> Bool {
        endListening()
        self.registeredHandler = handler

        guard ensureEventHandlerInstalled() else {
            self.registeredHandler = nil
            return false
        }

        var localHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.carbonModifierMask,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &localHotKeyRef
        )

        guard status == noErr, let localHotKeyRef else {
            self.registeredHandler = nil
            return false
        }

        registeredHotKey = localHotKeyRef
        isHotKeyRegistered = true
        return true
    }

    func endListening() {
        if let registeredHotKey {
            UnregisterEventHotKey(registeredHotKey)
            self.registeredHotKey = nil
        }
        isHotKeyRegistered = false
        registeredHandler = nil
    }

    /// Installs the Carbon event handler once so we can respond to presses.
    private func ensureEventHandlerInstalled() -> Bool {
        guard keyboardEventHandler == nil else { return true }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                return registrar.handleHotKeyEvent(event)
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &keyboardEventHandler
        )

        if status != noErr {
            keyboardEventHandler = nil
            return false
        }

        return true
    }

    /// Invokes the stored handler when the registered hotkey ID is fired.
    private func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event, isHotKeyRegistered else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == self.hotKeyID.signature,
              hotKeyID.id == self.hotKeyID.id else {
            return OSStatus(eventNotHandledErr)
        }

        registeredHandler?()
        return noErr
    }
}
