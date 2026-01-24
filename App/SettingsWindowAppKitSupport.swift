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
        initialSorting: ArrangementResetSorting,
        onConfirm: @escaping @MainActor (ArrangementResetSorting) -> Void
    ) {
        if let window = hostingWindow as? NSWindow {
            presentSortingSheet(on: window, initialSorting: initialSorting) { sorting in
                guard let sorting else { return }
                presentResetSheet(on: window, sorting: sorting) { confirmed in
                    guard confirmed else { return }
                    onConfirm(sorting)
                }
            }
        } else {
            let sorting = presentSortingChoiceModal(initialSorting: initialSorting)
            guard let selectedSorting = sorting else { return }
            let confirmed = presentResetConfirmationModal(sorting: selectedSorting)
            if confirmed {
                onConfirm(selectedSorting)
            }
        }
    }

    /// First step (sheet): ask which sorting to use via two buttons.
    @MainActor
    private static func presentSortingSheet(
        on window: NSWindow,
        initialSorting: ArrangementResetSorting,
        completion: @escaping (ArrangementResetSorting?) -> Void
    ) {
        let alert = sortingAlert(initialSorting: initialSorting)
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                completion(.alphabetical)
            case .alertSecondButtonReturn:
                completion(.discovery)
            default:
                completion(nil)
            }
        }
    }

    /// Second step (sheet): confirm reset.
    @MainActor
    private static func presentResetSheet(
        on window: NSWindow,
        sorting: ArrangementResetSorting,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = resetAlert()
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    /// First step (modal fallback).
    @MainActor
    private static func presentSortingChoiceModal(
        initialSorting: ArrangementResetSorting
    ) -> ArrangementResetSorting? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "How should the grid be sorted after reset?")
        alert.informativeText = String(localized: "Choose Alphabetical (A → Z) or Discovery order (as Launchy finds apps).")
        alert.addButton(withTitle: ArrangementResetSorting.alphabetical.displayName)
        alert.addButton(withTitle: ArrangementResetSorting.discovery.displayName)
        alert.addButton(withTitle: String(localized: "Cancel"))

        let defaultIndex = initialSorting == .discovery ? 1 : 0
        alert.buttons[defaultIndex].keyEquivalent = "\r"

        let response = presentModalAlert(alert)

        switch response {
        case .alertFirstButtonReturn:
            return .alphabetical
        case .alertSecondButtonReturn:
            return .discovery
        default:
            return nil
        }
    }

    /// Second step (modal fallback): confirm the destructive reset.
    @MainActor
    private static func presentResetConfirmationModal(
        sorting: ArrangementResetSorting
    ) -> Bool {
        let alert = resetAlert()
        let response = presentModalAlert(alert)
        return response == .alertFirstButtonReturn
    }

    /// Shared reset alert contents.
    @MainActor
    private static func resetAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Reset icon arrangement?")
        alert.informativeText = String(localized: "This deletes your saved ordering, folders, and page layout. Custom app names and hidden apps will be kept.")
        alert.addButton(withTitle: String(localized: "Reset"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    /// Shared sorting alert contents.
    @MainActor
    private static func sortingAlert(initialSorting: ArrangementResetSorting) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "How should the grid be sorted after reset?")
        alert.informativeText = String(localized: "Choose Alphabetical (A → Z) or Discovery order (as Launchy finds apps).")
        alert.addButton(withTitle: ArrangementResetSorting.alphabetical.displayName)
        alert.addButton(withTitle: ArrangementResetSorting.discovery.displayName)
        alert.addButton(withTitle: String(localized: "Cancel"))

        let defaultIndex = initialSorting == .discovery ? 1 : 0
        alert.buttons[defaultIndex].keyEquivalent = "\r"
        return alert
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
    var cancelToken: Int
    var onChange: (HotkeyDescriptor?) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderTextField {
        let view = HotkeyRecorderTextField()
        view.placeholderText = placeholder
        view.onHotkeyChange = onChange
        view.hotkey = hotkey
        return view
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cancelToken: cancelToken)
    }

    func updateNSView(_ nsView: HotkeyRecorderTextField, context: Context) {
        nsView.placeholderText = placeholder
        nsView.hotkey = hotkey
        nsView.onHotkeyChange = onChange
        if context.coordinator.cancelToken != cancelToken {
            nsView.cancelRecording()
            context.coordinator.cancelToken = cancelToken
        }
    }

    final class Coordinator {
        var cancelToken: Int

        init(cancelToken: Int) {
            self.cancelToken = cancelToken
        }
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
    private var systemDefinedMonitor: Any?
    private var keyDownMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let success = super.becomeFirstResponder()
        if success {
            beginRecording()
        }
        return success
    }

    override func resignFirstResponder() -> Bool {
        endRecording(resignFirstResponder: false)
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        handleKeyEvent(event)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let deleteKeyCodes: Set<UInt16> = [
            UInt16(kVK_Delete),
            UInt16(kVK_ForwardDelete)
        ]
        let sanitizedModifiers = HotkeyDescriptor.sanitizedModifiers(for: event)
        let hasModifiers = !sanitizedModifiers.isEmpty

        if event.keyCode == UInt16(kVK_Escape), !hasModifiers {
            endRecording(resignFirstResponder: true)
            return
        }

        if deleteKeyCodes.contains(event.keyCode), !hasModifiers {
            hotkey = nil
            onHotkeyChange?(nil)
            endRecording(resignFirstResponder: true)
            return
        }

        guard let descriptor = HotkeyDescriptor(event: event) else {
            NSSound.beep()
            return
        }

        hotkey = descriptor
        onHotkeyChange?(descriptor)
        endRecording(resignFirstResponder: true)
    }

    func cancelRecording() {
        guard isRecording else { return }
        endRecording(resignFirstResponder: true)
    }

    private func beginRecording() {
        isRecording = true
        installKeyDownMonitorIfNeeded()
        installSystemDefinedMonitorIfNeeded()
        updateDisplay()
    }

    private func endRecording(resignFirstResponder: Bool) {
        isRecording = false
        removeSystemDefinedMonitor()
        removeKeyDownMonitor()
        if resignFirstResponder {
            window?.makeFirstResponder(nil)
        }
        updateDisplay()
    }

    private func installSystemDefinedMonitorIfNeeded() {
        guard systemDefinedMonitor == nil else { return }
        systemDefinedMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard let descriptor = HotkeyDescriptor(event: event) else {
                return event
            }
            self.hotkey = descriptor
            self.onHotkeyChange?(descriptor)
            self.endRecording(resignFirstResponder: true)
            return event
        }
    }

    private func removeSystemDefinedMonitor() {
        if let systemDefinedMonitor {
            NSEvent.removeMonitor(systemDefinedMonitor)
            self.systemDefinedMonitor = nil
        }
    }

    private func installKeyDownMonitorIfNeeded() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.handleKeyEvent(event)
            return nil
        }
    }

    private func removeKeyDownMonitor() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
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
