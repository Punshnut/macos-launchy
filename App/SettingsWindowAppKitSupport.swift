import AppKit
import Carbon
import SwiftUI

extension NSWindow {
    func applyRoundedCorners(radius: CGFloat) {
        guard let contentView else { return }
        let targetView = contentView.superview ?? contentView
        targetView.wantsLayer = true
        targetView.layer?.backgroundColor = NSColor.clear.cgColor
        targetView.layer?.cornerRadius = radius
        targetView.layer?.cornerCurve = .continuous
        targetView.layer?.masksToBounds = true
    }
}

// MARK: - Window Hosting Helpers

/// Bridges SwiftUI's settings window into AppKit so we can resize and control the host window directly.
@MainActor
enum SettingsWindowHostManager {
    /// Applies shared chrome customizations (transparency/opacity) to the hosting window.
    static func applyConfiguration(to hostingWindow: AnyObject?) {
        guard let window = hostingWindow as? NSWindow else { return }
        updateWindowChrome(for: window)
    }

    /// Resizes the settings window to the target tab height while keeping the title bar anchored.
    static func resize(window hostingWindow: AnyObject?, for tab: SettingsTab, animated: Bool) {
        guard let window = hostingWindow as? NSWindow else { return }
        resizeWindow(for: tab, in: window, animated: animated)
    }

    /// Mirrors the close/minimize/zoom controls inside SwiftUI buttons.
    static func performWindowAction(_ kind: WindowControlKind, on hostingWindow: AnyObject?) {
        guard let window = hostingWindow as? NSWindow else { return }
        switch kind {
        case .close:
            window.performClose(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .zoom:
            window.performZoom(nil)
        }
    }

    private static func resizeWindow(for tab: SettingsTab, in window: NSWindow, animated: Bool) {
        let currentFrame = window.frame
        let currentContentRect = window.contentRect(forFrameRect: currentFrame)
        let targetContentHeight = SettingsWindowMetrics.preferredContentHeight(for: tab)

        guard abs(currentContentRect.height - targetContentHeight) > 0.5 else { return }

        let targetContentSize = NSSize(
            width: currentContentRect.width,
            height: targetContentHeight
        )
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        ).size

        let anchorPoint = NSPoint(x: currentFrame.midX, y: currentFrame.maxY)
        let newOrigin = NSPoint(
            x: anchorPoint.x - targetFrameSize.width / 2,
            y: anchorPoint.y - targetFrameSize.height
        )
        let newFrame = NSRect(origin: newOrigin, size: targetFrameSize)
        window.setFrame(newFrame, display: true, animate: animated)
    }

    private static func updateWindowChrome(for window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.applyRoundedCorners(radius: 32)
    }
}

/// Tiny shim that exposes AppKit-only helpers back to SwiftUI.
@MainActor
enum SettingsWindowAppKitBridge {
    static func applicationIconImage() -> Image? {
        guard let icon = NSApp.applicationIconImage else {
            return nil
        }
        return Image(nsImage: icon)
    }

    static func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Alert Presentation Helpers

final class SettingsWindowAlertPresenter {
    @MainActor
    static func confirmArrangementReset(
        hostingWindow: AnyObject?,
        onConfirm: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Reset icon arrangement?")
        alert.informativeText = String(localized: "This deletes your saved ordering, folders, and page layout. Type RESET to continue.")

        let confirmationField = NSTextField(string: "")
        confirmationField.placeholderString = String(localized: "RESET")
        confirmationField.frame = NSRect(x: 0, y: 0, width: 220, height: 22)
        alert.accessoryView = confirmationField

        alert.addButton(withTitle: String(localized: "Reset"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        if let window = hostingWindow as? NSWindow {
            NSApp.activate(ignoringOtherApps: true)
            alert.beginSheetModal(for: window) { response in
                handleArrangementResetResponse(
                    response,
                    typedValue: confirmationField.stringValue,
                    onConfirm: onConfirm
                )
            }
            DispatchQueue.main.async {
                window.makeFirstResponder(confirmationField)
            }
        } else {
            let response = presentModalAlert(alert)
            handleArrangementResetResponse(
                response,
                typedValue: confirmationField.stringValue,
                onConfirm: onConfirm
            )
        }
    }

    @MainActor
    private static func handleArrangementResetResponse(
        _ response: NSApplication.ModalResponse,
        typedValue: String,
        onConfirm: @escaping @MainActor () -> Void
    ) {
        let normalized = typedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn,
              normalized.caseInsensitiveCompare(String(localized: "RESET")) == .orderedSame else { return }
        onConfirm()
    }

    @MainActor
    private static func presentModalAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alertWindow = alert.window
        alertWindow.level = .statusBar
        alertWindow.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllSpaces])
        alertWindow.makeKeyAndOrderFront(nil)
        alertWindow.orderFrontRegardless()

        let response = alert.runModal()

        return response
    }
}

// MARK: - Hotkey Recorder

struct HotkeyRecorderField: NSViewRepresentable {
    var hotkey: HotkeyDescriptor?
    var placeholder: String
    var onChange: (HotkeyDescriptor?) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderTextField {
        let view = HotkeyRecorderTextField()
        view.placeholderText = placeholder
        view.onHotkeyChange = onChange
        view.hotkey = hotkey
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderTextField, context: Context) {
        nsView.placeholderText = placeholder
        nsView.hotkey = hotkey
        nsView.onHotkeyChange = onChange
    }
}

final class HotkeyRecorderTextField: NSTextField {
    var hotkey: HotkeyDescriptor? {
        didSet { updateDisplay() }
    }

    var placeholderText: String = String(localized: "Click to record") {
        didSet { updateDisplay() }
    }

    var onHotkeyChange: ((HotkeyDescriptor?) -> Void)?

    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = true
        isEditable = false
        isSelectable = false
        drawsBackground = true
        backgroundColor = .controlBackgroundColor
        focusRingType = .default
        alignment = .center
        font = .systemFont(ofSize: NSFont.systemFontSize)
        cell?.wraps = false
        cell?.isScrollable = true
        updateDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let success = super.becomeFirstResponder()
        isRecording = true
        updateDisplay()
        return success
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        updateDisplay()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        updateDisplay()
    }

    override func keyDown(with event: NSEvent) {
        handleKeyEvent(event)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let deleteKeyCodes: Set<UInt16> = [
            UInt16(kVK_Delete),
            UInt16(kVK_ForwardDelete)
        ]

        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            updateDisplay()
            return
        }

        if deleteKeyCodes.contains(event.keyCode) {
            hotkey = nil
            onHotkeyChange?(nil)
            isRecording = false
            window?.makeFirstResponder(nil)
            updateDisplay()
            return
        }

        guard let descriptor = HotkeyDescriptor(event: event) else {
            NSSound.beep()
            return
        }

        hotkey = descriptor
        onHotkeyChange?(descriptor)
        isRecording = false
        window?.makeFirstResponder(nil)
        updateDisplay()
    }

    private func updateDisplay() {
        if isRecording {
            stringValue = ""
            placeholderString = String(localized: "Press shortcut...")
            return
        }

        if let hotkey {
            stringValue = hotkey.displayString
            placeholderString = placeholderText
        } else {
            stringValue = ""
            placeholderString = placeholderText
        }
    }
}

// MARK: - Hosting Infrastructure

struct HostingWindowFinder: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

struct FrostedBackgroundView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        view.isEmphasized = true
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
    }
}

// MARK: - Settings Window Controller

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator = SettingsWindowCoordinator()
    private let hostingController: NSHostingController<SettingsWindow>
    @MainActor
    var onClose: (() -> Void)?

    init() {
        let view = SettingsWindow(coordinator: coordinator)
        hostingController = NSHostingController(rootView: view)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        let defaultContentSize = SettingsWindowMetrics.defaultContentSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultContentSize.width, height: defaultContentSize.height),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Launchy Settings")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentMinSize = SettingsWindowMetrics.minimumContentSize
        window.center()
        window.contentViewController = hostingController
        window.applyRoundedCorners(radius: 32)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Brings the settings window to the front and activates the app if needed.
    func showWindowAndActivate() {
        guard let window else { return }
        centerWindowOnPreferredScreen()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showWindowAndActivate(selecting tab: SettingsTab) {
        coordinator.selectTab(tab)
        showWindowAndActivate()
    }

    private func centerWindowOnPreferredScreen() {
        guard let window else { return }
        guard let screen = ScreenProvider.screenUnderMouseOrMain() else { return }

        let contentSize = window.frame.size
        let visible = screen.visibleFrame
        let targetX = visible.midX - contentSize.width / 2
        let targetY = visible.midY - contentSize.height / 2

        let clampedX = min(
            max(targetX, visible.minX),
            max(visible.maxX - contentSize.width, visible.minX)
        )
        let clampedY = min(
            max(targetY, visible.minY),
            max(visible.maxY - contentSize.height, visible.minY)
        )

        window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            onClose?()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.applyRoundedCorners(radius: 32)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.applyRoundedCorners(radius: 32)
    }
}
