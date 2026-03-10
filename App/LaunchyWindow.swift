import AppKit
import SwiftUI

/// Configures and presents the right window type for the selected launcher mode.
final class LauncherWindowController: NSWindowController {
    private static let preferredFloatyContentSize = NSSize(width: 1040, height: 830)
    private let launcherContentHost: NSHostingController<LauncherView>
    private let launcherMode: LauncherMode
    private let entranceContentOffset: CGFloat = 32
    private let entranceAnimationDuration: TimeInterval = 0.34
    private let hideAnimationDuration: TimeInterval = 0.25
    private var entranceContentOrigin: NSPoint = .zero

    /// Wraps the provided SwiftUI content inside either a panel or fullscreen window.
    init(rootView: LauncherView, launcherMode: LauncherMode) {
        LaunchyLogger.log("LauncherWindowController init: mode=\(launcherMode)")
        launcherContentHost = NSHostingController(rootView: rootView)
        launcherContentHost.view.wantsLayer = true
        launcherContentHost.view.layer?.backgroundColor = NSColor.clear.cgColor
        launcherContentHost.view.autoresizingMask = [.width, .height]
        self.launcherMode = launcherMode
        let window: NSWindow
        let presentationScreen = ScreenProvider.screenUnderMouseOrMain()

        switch launcherMode {
        case .floaty:
            LaunchyLogger.log("LauncherWindowController init: building floaty window")
            let frame = Self.floatyFrame(for: Self.preferredFloatyContentSize, on: presentationScreen)
            let floatyPanel = FloatyLauncherWindow(contentRect: frame)
            floatyPanel.contentViewController = launcherContentHost
            floatyPanel.applyRoundedCorners(radius: 32)
            floatyPanel.setFrame(frame, display: false)
            window = floatyPanel
        case .fullscreen:
            LaunchyLogger.log("LauncherWindowController init: building fullscreen window")
            let frame = Self.fullscreenFrame(on: presentationScreen)
            let fullscreen = FullscreenLauncherWindow(contentRect: frame)
            fullscreen.contentViewController = launcherContentHost
            fullscreen.setFrame(frame, display: true)
            window = fullscreen
        }

        window.initialFirstResponder = launcherContentHost.view
        super.init(window: window)
        LaunchyLogger.log("LauncherWindowController init: done mode=\(launcherMode)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Centers the floaty panel window and constrains it to the visible screen area.
    private static let floatyTopExtension: CGFloat = 82

    /// Computes a centered floaty-panel frame clamped to the visible bounds of the target screen.
    private static func floatyFrame(for size: NSSize, on screen: NSScreen?) -> NSRect {
        guard let screen = screen ?? NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }

        let visible = screen.visibleFrame
        let contentSize = Self.scaledFloatyContentSize(for: size, on: screen)
        let width = min(contentSize.width, visible.width * 0.9)
        // Give floaty mode a bit more breathing room by borrowing ~10% of the screen height.
        let expandedHeight = contentSize.height + visible.height * 0.1
        let baseHeight = min(expandedHeight, visible.height * 0.9)
        let height = min(baseHeight + floatyTopExtension, visible.height * 0.94)
        let x = visible.midX - width / 2
        var y = visible.midY - baseHeight / 2
        if y + height > visible.maxY {
            y = visible.maxY - height
        }
        if y < visible.minY {
            y = visible.minY
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Adjusts the preferred floaty content size based on the currently targeted screen.
    private static func scaledFloatyContentSize(for baseSize: NSSize, on screen: NSScreen?) -> NSSize {
        guard let target = screen ?? NSScreen.main else {
            return baseSize
        }

        guard let primary = NSScreen.main, target !== primary else {
            return baseSize
        }

        let primaryVisible = primary.visibleFrame.size
        let targetVisible = target.visibleFrame.size

        guard primaryVisible.width > 0,
              primaryVisible.height > 0,
              targetVisible.width > 0,
              targetVisible.height > 0 else {
            return baseSize
        }

        let widthRatio = targetVisible.width / primaryVisible.width
        let heightRatio = targetVisible.height / primaryVisible.height
        let scale = min(widthRatio, heightRatio)
        let clampedScale = min(max(scale, 0.7), 1.25)

        return NSSize(
            width: baseSize.width * clampedScale,
            height: baseSize.height * clampedScale
        )
    }

    /// Determines the fullscreen frame, falling back to a 16:10 layout without a main screen.
    private static func fullscreenFrame(on screen: NSScreen?) -> NSRect {
        if let screen = screen ?? NSScreen.main {
            return screen.frame
        } else {
            return NSRect(x: 0, y: 0, width: 1440, height: 900)
        }
    }

    /// Presents launcher window on the active display and runs entrance behavior.
    func presentWindow(skipEntranceAnimation: Bool = false) {
        guard let window else { return }
        LaunchyLogger.log("LauncherWindowController presentWindow: start mode=\(launcherMode) visible=\(window.isVisible) skip=\(skipEntranceAnimation)")
        if launcherMode == .floaty && window.isVisible == false {
            // Avoid touching screen/size logic before the panel is on-screen.
        } else {
            updateFrameForPreferredScreenIfNeeded()
        }
        let originalFrame = window.frame
        // Floaty frequently failed to reappear when its entrance animation left alpha at 0, so skip animation there.
        let shouldAnimateEntrance = window.isVisible == false
            && skipEntranceAnimation == false
            && launcherMode == .fullscreen

        if shouldAnimateEntrance {
            prepareForEntranceAnimation(window: window, originalFrame: originalFrame)
        }

        bringWindowToFront(window)
        launcherContentHost.view.frame = window.contentView?.bounds ?? originalFrame
        if launcherMode == .floaty {
            window.applyRoundedCorners(radius: 32)
        }
        window.makeFirstResponder(launcherContentHost.view)
        NotificationCenter.default.post(name: .launcherShouldRefocusSearch, object: nil)
        DispatchQueue.main.async {
            window.makeFirstResponder(self.launcherContentHost.view)
            NotificationCenter.default.post(name: .launcherShouldRefocusSearch, object: nil)
        }
        if shouldAnimateEntrance && launcherMode == .fullscreen {
            NotificationCenter.default.post(name: .launcherShouldAnimateGridEntrance, object: nil)
        }

        if shouldAnimateEntrance {
            runEntranceAnimation(window: window, originalFrame: originalFrame)
        }
        LaunchyLogger.log("LauncherWindowController presentWindow: done mode=\(launcherMode)")
    }

    /// Brings the launcher onscreen while minimizing cross-display side effects in fullscreen mode.
    private func bringWindowToFront(_ window: NSWindow) {
        switch launcherMode {
        case .floaty:
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        case .fullscreen:
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    /// Replaces the hosted SwiftUI content while keeping the same window instance alive.
    func update(rootView: LauncherView) {
        launcherContentHost.rootView = rootView
    }

    /// Exposes the current launcher mode so callers can react to presentation failures.
    var mode: LauncherMode {
        launcherMode
    }

    /// Repositions window to the screen under the cursor before presentation.
    private func updateFrameForPreferredScreenIfNeeded() {
        guard let window else { return }
        let targetScreen = ScreenProvider.screenUnderMouseOrMain()
        LaunchyLogger.log("LauncherWindowController updateFrameForPreferredScreenIfNeeded: mode=\(launcherMode)")

        switch launcherMode {
        case .floaty:
            let targetFrame = Self.floatyFrame(for: Self.preferredFloatyContentSize, on: targetScreen)
            if window.frame != targetFrame {
                window.setFrame(targetFrame, display: false)
            }
        case .fullscreen:
            let targetFrame = Self.fullscreenFrame(on: targetScreen)
            if window.frame != targetFrame {
                window.setFrame(targetFrame, display: true)
            }
        }
    }

    /// Prepares the launcher window to animate in from a subtle offset.
    private func prepareForEntranceAnimation(window: NSWindow, originalFrame: NSRect) {
        window.alphaValue = 0
        window.setFrame(originalFrame, display: false)
        entranceContentOrigin = launcherContentHost.view.frame.origin

        let directionalOffset = launcherContentHost.view.isFlipped ? -entranceContentOffset : entranceContentOffset
        let startOrigin = NSPoint(
            x: entranceContentOrigin.x,
            y: entranceContentOrigin.y + directionalOffset
        )
        launcherContentHost.view.setFrameOrigin(startOrigin)
        launcherContentHost.view.alphaValue = 0
    }

    /// Animates the window back into place with a fade/fly-in effect.
    private func runEntranceAnimation(window: NSWindow, originalFrame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = entranceAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            self.launcherContentHost.view.animator().alphaValue = 1
            self.launcherContentHost.view.animator().setFrameOrigin(entranceContentOrigin)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                window.alphaValue = 1
                self.launcherContentHost.view.setFrameOrigin(self.entranceContentOrigin)
                self.launcherContentHost.view.alphaValue = 1
            }
        }
    }

    /// Fades the window out before ordering it offscreen so hides feel consistent across entry points.
    func fadeOutWindow(completion: @escaping @MainActor @Sendable () -> Void) {
        guard let window else {
            completion()
            return
        }
        guard window.isVisible else {
            completion()
            return
        }

        let contentView = window.contentView

        NSAnimationContext.runAnimationGroup { context in
            context.duration = hideAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 0
            contentView?.animator().alphaValue = 0
        } completionHandler: { [weak window, weak contentView] in
            Task { @MainActor in
                window?.orderOut(nil)
                window?.alphaValue = 1
                contentView?.alphaValue = 1
                completion()
            }
        }
    }
}

/// Non-activating floating panel for the "floaty" launcher mode.
final class FloatyLauncherWindow: NSPanel {
    static let entranceSlideOffset: CGFloat = 32

    /// Convenience initializer that applies the NSPanel style mask we need.
    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [
                .nonactivatingPanel,
                .fullSizeContentView,
                .borderless
            ],
            backing: .buffered,
            defer: false
        )
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )

        setupWindow()
    }

    /// Applies the visual styling and behavior toggles that make this panel feel like a HUD.
    private func setupWindow() {
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
            .transient,
            .ignoresCycle
        ]
        level = .floating
        animationBehavior = .utilityWindow
        isFloatingPanel = true
        worksWhenModal = true
        becomesKeyOnlyIfNeeded = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        titlebarSeparatorStyle = .none
        LaunchyLogger.log("FloatyLauncherWindow setupWindow: configured")
    }

    /// Allow buttons inside the panel to receive focus when needed.
    override var canBecomeKey: Bool {
        true
    }

    /// Panels should never become the main window, so always return false.
    override var canBecomeMain: Bool {
        false
    }

    /// Prevent the default beep that occurs when ESC is pressed without being handled.
    override func cancelOperation(_ sender: Any?) {
        // Intentionally blank to swallow the cancel operation request.
    }

    /// Arrow keys trigger paging; swallow them here so macOS does not emit the error tone.
    override func keyDown(with event: NSEvent) {
        if LauncherPageShortcuts.pageIndex(for: event) != nil {
            return
        }
        guard event.keyCode == 123 || event.keyCode == 124 else {
            super.keyDown(with: event)
            return
        }
    }

    /// Consumes page shortcut equivalents so NSPanel does not emit default error beeps.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if LauncherPageShortcuts.pageIndex(for: event) != nil {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Borderless fullscreen window backing the immersive launcher presentation.
final class FullscreenLauncherWindow: NSPanel {
    /// Initializes the window with the minimal chrome needed for fullscreen content.
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        setupWindow()
    }

    /// Fullscreen mode still needs keyboard focus for search, so allow key status.
    override var canBecomeKey: Bool {
        true
    }

    /// The fullscreen window should not be considered the app's main window.
    override var canBecomeMain: Bool {
        false
    }

    /// Swallow ESC cancel requests so we don't hear the default system beep.
    override func cancelOperation(_ sender: Any?) {
        // No-op; escape handling is performed elsewhere.
    }

    /// Prevent the arrow key beep the same way as in floaty mode.
    override func keyDown(with event: NSEvent) {
        if LauncherPageShortcuts.pageIndex(for: event) != nil {
            return
        }
        guard event.keyCode == 123 || event.keyCode == 124 else {
            super.keyDown(with: event)
            return
        }
    }

    /// Consumes page shortcut equivalents so fullscreen mode behaves like floaty mode.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if LauncherPageShortcuts.pageIndex(for: event) != nil {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Sets up window appearance so the SwiftUI view takes over the full display.
    private func setupWindow() {
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        worksWhenModal = true
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [
            // Keep fullscreen launcher on the invoking space/display instead of cloning across spaces.
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .stationary,
            .transient,
            .ignoresCycle
        ]
        level = .mainMenu
        animationBehavior = .default
    }
}
