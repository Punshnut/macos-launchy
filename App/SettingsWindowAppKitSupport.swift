import AppKit
import Carbon
import SwiftUI

extension NSWindow {
    /// Applies rounded clipping to backing views for translucent windows.
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

/// Bridges SwiftUI settings UI with AppKit window controls.
@MainActor
enum SettingsWindowHostManager {
    /// Applies shared chrome settings to the host window.
    static func applyConfiguration(to hostingWindow: AnyObject?) {
        guard let window = hostingWindow as? NSWindow else { return }
        updateWindowChrome(for: window)
    }

    /// Resizes settings window for target tab height.
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

    /// Recomputes frame for target tab.
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

        let anchorPoint = NSPoint(x: currentFrame.midX, y: currentFrame.midY)
        let newOrigin = NSPoint(
            x: anchorPoint.x - targetFrameSize.width / 2,
            y: anchorPoint.y - targetFrameSize.height / 2
        )
        let newFrame = NSRect(origin: newOrigin, size: targetFrameSize)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.36
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: true, animate: false)
        }
    }

    /// Applies shared visual styling for the settings host window.
    private static func updateWindowChrome(for window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.applyRoundedCorners(radius: 32)
    }
}

/// Tiny shim that exposes AppKit-only helpers back to SwiftUI.
@MainActor
enum SettingsWindowAppKitBridge {
    /// Returns the current app icon as a SwiftUI image.
    static func applicationIconImage() -> Image? {
        guard let icon = NSApp.applicationIconImage else {
            return nil
        }
        return Image(nsImage: icon)
    }

    /// Opens an external URL through NSWorkspace.
    static func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Fires a short alignment haptic pulse for tab selection feedback.
    static func performTabSelectionHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}

// MARK: - Alert Presentation Helpers

final class SettingsWindowAlertPresenter {
    @MainActor
    /// Starts two-step arrangement reset confirmation flow.
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

    /// Presents sorting choice as a sheet.
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

    /// Presents reset confirmation as a sheet.
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

    /// Presents sorting choice as modal fallback when no host window exists.
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

    /// Presents reset confirmation as modal fallback.
    @MainActor
    private static func presentResetConfirmationModal(
        sorting: ArrangementResetSorting
    ) -> Bool {
        let alert = resetAlert()
        let response = presentModalAlert(alert)
        return response == .alertFirstButtonReturn
    }

    /// Creates reset confirmation alert contents.
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

    /// Creates sorting-choice alert contents.
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

    /// Presents alert above launcher windows and returns modal response.
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

    /// Creates the AppKit recorder text field bridged into SwiftUI.
    func makeNSView(context: Context) -> HotkeyRecorderTextField {
        let view = HotkeyRecorderTextField()
        view.placeholderText = placeholder
        view.onHotkeyChange = onChange
        view.hotkey = hotkey
        return view
    }

    /// Tracks cancellation token changes between SwiftUI updates.
    func makeCoordinator() -> Coordinator {
        Coordinator(cancelToken: cancelToken)
    }

    /// Synchronizes binding values and cancels recording when token changes.
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

    /// Allows single-click activation without requiring prior window focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Enter recording mode as soon as the field gains first responder.
    override func becomeFirstResponder() -> Bool {
        let success = super.becomeFirstResponder()
        if success {
            beginRecording()
        }
        return success
    }

    /// Leaves recording mode when focus is lost.
    override func resignFirstResponder() -> Bool {
        endRecording(resignFirstResponder: false)
        return super.resignFirstResponder()
    }

    /// Click-to-record behavior for hotkey capture.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    /// Routes key events to the recorder while active.
    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        handleKeyEvent(event)
    }

    /// Handles Escape, delete-clear, and standard hotkey capture semantics.
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

    /// Public cancellation hook for SwiftUI token updates.
    func cancelRecording() {
        guard isRecording else { return }
        endRecording(resignFirstResponder: true)
    }

    /// Arms monitors and updates placeholder text for capture state.
    private func beginRecording() {
        isRecording = true
        installKeyDownMonitorIfNeeded()
        installSystemDefinedMonitorIfNeeded()
        updateDisplay()
    }

    /// Tears down monitors and optionally resigns first responder.
    private func endRecording(resignFirstResponder: Bool) {
        isRecording = false
        removeSystemDefinedMonitor()
        removeKeyDownMonitor()
        if resignFirstResponder {
            window?.makeFirstResponder(nil)
        }
        updateDisplay()
    }

    /// Installs a local monitor for media/system-defined keys.
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

    /// Removes media/system-defined key monitor if installed.
    private func removeSystemDefinedMonitor() {
        if let systemDefinedMonitor {
            NSEvent.removeMonitor(systemDefinedMonitor)
            self.systemDefinedMonitor = nil
        }
    }

    /// Installs local key-down monitor for regular keyboard shortcuts.
    private func installKeyDownMonitorIfNeeded() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.handleKeyEvent(event)
            return nil
        }
    }

    /// Removes local key-down monitor if present.
    private func removeKeyDownMonitor() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
    }

    /// Updates visible text/placeholder according to capture state and selected hotkey.
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

    /// Emits an empty NSView and asynchronously resolves its owning window.
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    /// Re-resolves host window when SwiftUI updates this representable.
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

struct FrostedBackgroundView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    /// Creates a frosted AppKit background view for glass styling.
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        view.isEmphasized = true
        view.wantsLayer = true
        return view
    }

    /// Keeps frosted material/state in sync with SwiftUI state.
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

    /// Selects a tab before presenting and activating the settings window.
    func showWindowAndActivate(selecting tab: SettingsTab) {
        coordinator.selectTab(tab)
        showWindowAndActivate()
    }

    /// Centers the window on the screen under the cursor, clamped to visible bounds.
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

    /// Forwards close events to observers on the main actor.
    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            onClose?()
        }
    }

    /// Reapplies corner masking after moves that can reset backing view layers.
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.applyRoundedCorners(radius: 32)
    }

    /// Reapplies corner masking after frame changes.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.applyRoundedCorners(radius: 32)
    }
}
