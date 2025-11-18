import AppKit
import SwiftUI

final class LauncherWindowController: NSWindowController {
    private static let preferredSize = NSSize(width: 960, height: 720)

    convenience init(rootView: LauncherView) {
        let frame = Self.initialFrame(for: Self.preferredSize)
        let window = LauncherWindow(contentRect: frame)
        let hostingController = NSHostingController(rootView: rootView)
        window.contentViewController = hostingController
        self.init(window: window)
        window.center()
    }

    private static func initialFrame(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }

        let visible = screen.visibleFrame
        let width = min(size.width, visible.width * 0.9)
        let height = min(size.height, visible.height * 0.9)
        let x = visible.midX - width / 2
        let y = visible.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func present() {
        showWindow(nil)
        window?.orderFrontRegardless()
    }
}

final class LauncherWindow: NSPanel {
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

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
