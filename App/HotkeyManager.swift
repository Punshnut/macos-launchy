import AppKit
import Carbon

/// Descriptor describing the key code/modifier combination for a global hotkey.
struct HotkeyDescriptor: Equatable {
    let keyCodeValue: UInt32
    let modifierOptions: NSEvent.ModifierFlags

    /// Default shortcut used to toggle the launcher until settings support lands.
    static let toggleLauncher = HotkeyDescriptor(
        keyCodeValue: UInt32(kVK_Space),
        modifierOptions: [.command, .shift]
    )

    /// Converts modern `NSEvent` modifiers to the Carbon bitmask expected by `RegisterEventHotKey`.
    var carbonModifierMask: UInt32 {
        var mask: UInt32 = 0
        if modifierOptions.contains(.command) {
            mask |= UInt32(cmdKey)
        }
        if modifierOptions.contains(.option) {
            mask |= UInt32(optionKey)
        }
        if modifierOptions.contains(.shift) {
            mask |= UInt32(shiftKey)
        }
        if modifierOptions.contains(.control) {
            mask |= UInt32(controlKey)
        }
        return mask
    }
}

/// Abstraction describing something that can register/unregister a global hotkey.
protocol HotkeyRegistering {
    func beginListening(descriptor: HotkeyDescriptor, handler: @escaping () -> Void) -> Bool
    func endListening()
}

/// Coordinates registering a system-wide hotkey and notifying observers when it fires.
@MainActor
final class HotkeyManager {
    private let hotkeyDescriptor: HotkeyDescriptor
    private let hotkeyRegistrar: HotkeyRegistering
    private var isListeningForEvents = false

    /// Invoked whenever the registered hotkey is pressed.
    var onHotkeyPressed: (() -> Void)?

    init(descriptor: HotkeyDescriptor = .toggleLauncher, registrar: HotkeyRegistering = CarbonHotkeyRegistrar()) {
        self.hotkeyDescriptor = descriptor
        self.hotkeyRegistrar = registrar
    }

    /// Attempts to register the configured hotkey, no-opping if already active.
    func activate() {
        guard isListeningForEvents == false else { return }
        let didRegisterHotkey = hotkeyRegistrar.beginListening(descriptor: hotkeyDescriptor) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onHotkeyPressed?()
            }
        }

        if didRegisterHotkey {
            isListeningForEvents = true
        } else {
            assertionFailure("Failed to register global hotkey.")
        }
    }

    /// Unregisters the hotkey so it is released back to the system.
    func deactivate() {
        guard isListeningForEvents else { return }
        hotkeyRegistrar.endListening()
        isListeningForEvents = false
    }
}

/// Carbon-backed registrar that wires a hotkey into the traditional macOS event system.
final class CarbonHotkeyRegistrar: HotkeyRegistering {
    private static let hotKeySignature: OSType = 0x4C59484B // 'LYHK'

    private var keyboardEventHandler: EventHandlerRef?
    private var registeredHotKey: EventHotKeyRef?
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

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        var localHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            descriptor.keyCodeValue,
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
        return true
    }

    func endListening() {
        if let registeredHotKey {
            UnregisterEventHotKey(registeredHotKey)
            self.registeredHotKey = nil
        }
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
                registrar.handleHotKeyEvent(event)
                return noErr
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
    private func handleHotKeyEvent(_ event: EventRef?) {
        guard let event else { return }
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

        guard status == noErr, hotKeyID.signature == Self.hotKeySignature else {
            return
        }

        registeredHandler?()
    }
}
