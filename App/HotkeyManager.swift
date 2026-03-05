import AppKit
import Carbon

/// Descriptor describing the key code/modifier combination for a global hotkey.
struct HotkeyDescriptor: Equatable, Hashable, Codable {
    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    let keyCode: UInt32
    private let modifierFlagsRawValue: UInt
    private let keyRepresentation: String?
    let mediaKey: MediaKey?

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifierFlagsRawValue
        case keyRepresentation
        case mediaKey
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
        self.mediaKey = nil
    }

    init(mediaKey: MediaKey, modifierFlags: NSEvent.ModifierFlags, keyRepresentation: String? = nil) {
        self.keyCode = 0
        self.modifierFlagsRawValue = HotkeyDescriptor.filtered(modifierFlags).rawValue
        self.keyRepresentation = keyRepresentation
        self.mediaKey = mediaKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let rawFlags = try container.decode(UInt.self, forKey: .modifierFlagsRawValue)
        modifierFlagsRawValue = HotkeyDescriptor.filtered(NSEvent.ModifierFlags(rawValue: rawFlags)).rawValue
        keyRepresentation = try container.decodeIfPresent(String.self, forKey: .keyRepresentation)
        mediaKey = try container.decodeIfPresent(MediaKey.self, forKey: .mediaKey)
    }

    /// Persists only sanitized fields so restored shortcuts always use supported modifiers.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifierFlagsRawValue, forKey: .modifierFlagsRawValue)
        try container.encodeIfPresent(keyRepresentation, forKey: .keyRepresentation)
        try container.encodeIfPresent(mediaKey, forKey: .mediaKey)
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
        if let mediaKey = HotkeyDescriptor.mediaKey(from: event) {
            self.init(
                mediaKey: mediaKey,
                modifierFlags: sanitizedModifiers,
                keyRepresentation: mediaKey.displayName
            )
            return
        }
        self.init(
            keyCode: UInt32(event.keyCode),
            modifierFlags: sanitizedModifiers,
            keyRepresentation: HotkeyDescriptor.displayNameForKey(event)
        )
    }

    /// Public helper for callers that need Launchy's canonical modifier filtering.
    static func sanitizedModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        filtered(event.modifierFlags)
    }

    /// Keeps only command/option/shift/control to avoid unstable device-specific flags.
    private static func filtered(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(relevantModifiers)
    }

    /// Builds localized modifier labels in display order for settings UI.
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

    /// Resolves the key text shown to users, including media key labels.
    private func keyDisplayText() -> String {
        if let mediaKey {
            return mediaKey.displayName
        }
        return keyRepresentation ?? Self.displayName(for: keyCode)
    }

    /// Derives a readable key name from a keyboard event, preserving "Space".
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

    /// Converts a key code into a stable fallback label when event characters are unavailable.
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

    /// Extracts a media-key press from `.systemDefined` events.
    static func mediaKey(from event: NSEvent) -> MediaKey? {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else {
            return nil
        }
        let data = UInt32(bitPattern: Int32(event.data1))
        let keyCode = UInt16((data >> 16) & 0xFFFF)
        let keyFlags = data & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = keyState == 0x0A
        guard isKeyDown else {
            return nil
        }
        return MediaKey(rawValue: keyCode)
    }

    /// Basic lookup table for readable key names.
    private static let keyCodeLabels: [UInt32: String] = [
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_ForwardDelete): "Forward Delete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Help): "Help",
        UInt32(kVK_Function): "Fn",
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

enum MediaKey: UInt16, Codable, CaseIterable {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case playPause = 16
    case nextTrack = 17
    case previousTrack = 18
    case fastForward = 19
    case rewind = 20
    case illuminationUp = 21
    case illuminationDown = 22
    case illuminationToggle = 23

    var displayName: String {
        switch self {
        case .volumeUp:
            return "Volume Up"
        case .volumeDown:
            return "Volume Down"
        case .brightnessUp:
            return "Brightness Up"
        case .brightnessDown:
            return "Brightness Down"
        case .mute:
            return "Mute"
        case .playPause:
            return "Play/Pause"
        case .nextTrack:
            return "Next Track"
        case .previousTrack:
            return "Previous Track"
        case .fastForward:
            return "Fast Forward"
        case .rewind:
            return "Rewind"
        case .illuminationUp:
            return "Keyboard Brightness Up"
        case .illuminationDown:
            return "Keyboard Brightness Down"
        case .illuminationToggle:
            return "Keyboard Brightness Toggle"
        }
    }
}

/// Abstraction describing something that can register/unregister a global hotkey.
protocol HotkeyRegistering {
    /// Starts listening for the supplied descriptor and invokes `handler` on trigger.
    func beginListening(descriptor: HotkeyDescriptor, handler: @escaping () -> Void) -> Bool
    /// Stops listening and releases any installed hooks/monitors.
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

    init(descriptor: HotkeyDescriptor? = .toggleLauncher, registrar: HotkeyRegistering = CompositeHotkeyRegistrar()) {
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

    /// Stops and immediately re-registers the hotkey after a descriptor change.
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

    /// Registers a Carbon global hotkey and stores the callback.
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

    /// Unregisters active Carbon hotkey and drops stored callback.
    func endListening() {
        if let registeredHotKey {
            UnregisterEventHotKey(registeredHotKey)
            self.registeredHotKey = nil
        }
        isHotKeyRegistered = false
        registeredHandler = nil
    }

    /// Installs the Carbon event handler once to respond to presses.
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

/// Registers media keys using a global/local event monitor instead of Carbon.
final class MediaHotkeyRegistrar: HotkeyRegistering {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var registeredDescriptor: HotkeyDescriptor?
    private var registeredHandler: (() -> Void)?

    /// Registers media-key monitoring using local/global `.systemDefined` event taps.
    func beginListening(descriptor: HotkeyDescriptor, handler: @escaping () -> Void) -> Bool {
        guard descriptor.mediaKey != nil else {
            return false
        }
        endListening()
        registeredDescriptor = descriptor
        registeredHandler = handler
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handle(event)
            return event
        }
        if globalMonitor == nil && localMonitor == nil {
            endListening()
            return false
        }
        return true
    }

    /// Removes installed media-key monitors and clears registration state.
    func endListening() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        registeredDescriptor = nil
        registeredHandler = nil
    }

    /// Validates media key + modifiers then invokes the registered callback.
    private func handle(_ event: NSEvent) {
        guard let registeredDescriptor,
              let expectedMediaKey = registeredDescriptor.mediaKey else {
            return
        }
        guard let mediaKey = HotkeyDescriptor.mediaKey(from: event),
              mediaKey == expectedMediaKey else {
            return
        }
        let sanitizedModifiers = HotkeyDescriptor.sanitizedModifiers(for: event)
        guard sanitizedModifiers == registeredDescriptor.modifierFlags else {
            return
        }
        registeredHandler?()
    }
}

/// Routes standard hotkeys to Carbon and media keys to a monitor-based registrar.
final class CompositeHotkeyRegistrar: HotkeyRegistering {
    private let carbonRegistrar = CarbonHotkeyRegistrar()
    private let mediaRegistrar = MediaHotkeyRegistrar()
    private var isUsingMediaRegistrar = false

    /// Delegates registration to media or Carbon registrar depending on descriptor.
    func beginListening(descriptor: HotkeyDescriptor, handler: @escaping () -> Void) -> Bool {
        endListening()
        if descriptor.mediaKey != nil {
            isUsingMediaRegistrar = true
            return mediaRegistrar.beginListening(descriptor: descriptor, handler: handler)
        }
        isUsingMediaRegistrar = false
        return carbonRegistrar.beginListening(descriptor: descriptor, handler: handler)
    }

    /// Unregisters whichever registrar is currently active.
    func endListening() {
        if isUsingMediaRegistrar {
            mediaRegistrar.endListening()
        } else {
            carbonRegistrar.endListening()
        }
        isUsingMediaRegistrar = false
    }
}
