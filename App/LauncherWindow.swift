import AppKit
import SwiftUI

/// Configures and presents the right window type for the selected launcher mode.
final class LauncherWindowController: NSWindowController {
    private static let preferredFloatyContentSize = NSSize(width: 960, height: 830)
    private let launcherContentHost: NSHostingController<LauncherView>
    private let entranceContentOffset: CGFloat = 32
    private let entranceAnimationDuration: TimeInterval = 0.34
    private var entranceContentOrigin: NSPoint = .zero

    /// Wraps the provided SwiftUI content inside either a panel or fullscreen window.
    init(rootView: LauncherView, launcherMode: LauncherMode) {
        launcherContentHost = NSHostingController(rootView: rootView)
        let window: NSWindow

        switch launcherMode {
        case .floaty:
            let frame = Self.initialFloatyFrame(for: Self.preferredFloatyContentSize)
            launcherContentHost.preferredContentSize = frame.size
            let floatyPanel = FloatyLauncherWindow(contentRect: frame)
            floatyPanel.contentViewController = launcherContentHost
            floatyPanel.setFrame(frame, display: false)
            floatyPanel.center()
            window = floatyPanel
        case .fullscreenOldMac:
            let frame = Self.fullscreenFrame()
            launcherContentHost.preferredContentSize = frame.size
            let fullscreen = FullscreenLauncherWindow(contentRect: frame)
            fullscreen.contentViewController = launcherContentHost
            fullscreen.setFrame(frame, display: true)
            window = fullscreen
        }

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Centers the floaty panel window and constrains it to the visible screen area.
    private static func initialFloatyFrame(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }

        let visible = screen.visibleFrame
        let width = min(size.width, visible.width * 0.9)
        // Give floaty mode a bit more breathing room by borrowing ~10% of the screen height.
        let expandedHeight = size.height + visible.height * 0.1
        let height = min(expandedHeight, visible.height * 0.9)
        let x = visible.midX - width / 2
        let y = visible.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Determines the fullscreen frame, falling back to a 16:10 layout without a main screen.
    private static func fullscreenFrame() -> NSRect {
        if let screen = NSScreen.main {
            return screen.frame
        } else {
            return NSRect(x: 0, y: 0, width: 1440, height: 900)
        }
    }

    /// Presents the window using the right ordering semantics for panels vs regular windows.
    func presentWindow() {
        guard let window else { return }
        let originalFrame = window.frame
        let shouldAnimateEntrance = window.isVisible == false

        if shouldAnimateEntrance {
            prepareForEntranceAnimation(window: window, originalFrame: originalFrame)
        }

        showWindow(nil)
        if window is FloatyLauncherWindow {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
        }

        if shouldAnimateEntrance {
            runEntranceAnimation(window: window, originalFrame: originalFrame)
        }
    }

    /// Replaces the hosted SwiftUI content while keeping the same window instance alive.
    func update(rootView: LauncherView) {
        launcherContentHost.rootView = rootView
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
}

/// Non-activating floating panel used for the "floaty" launcher mode.
final class FloatyLauncherWindow: NSPanel {
    static let entranceSlideOffset: CGFloat = 32

    /// Convenience initializer that applies the NSPanel style mask we need.
    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [
                .nonactivatingPanel,
                .fullSizeContentView,
                .titled
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
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        becomesKeyOnlyIfNeeded = true
    }

    /// Allow buttons inside the panel to receive focus when needed.
    override var canBecomeKey: Bool {
        true
    }

    /// Panels should never become the main window, so always return false.
    override var canBecomeMain: Bool {
        false
    }
}

/// Borderless fullscreen window backing the "old Mac" presentation.
final class FullscreenLauncherWindow: NSWindow {
    /// Initializes the window with the minimal chrome needed for fullscreen content.
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .borderless,
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

    /// Sets up window appearance so the SwiftUI view takes over the full display.
    private func setupWindow() {
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenPrimary,
            .stationary
        ]
        level = .mainMenu
        animationBehavior = .default
    }
}
