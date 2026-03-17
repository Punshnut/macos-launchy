import SwiftUI
import AppKit

/// Maps modifier+key combinations to page indices so keyboard shortcuts can jump between pages.
enum LauncherPageShortcuts {
    /// Resolves Ctrl+number (main keyboard or keypad) into a zero-based page index.
    static func pageIndex(for event: NSEvent) -> Int? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let filteredModifiers = modifiers.subtracting([.numericPad, .function, .capsLock])
        guard filteredModifiers == [.control] else { return nil }
        return pageIndex(for: event.keyCode)
    }

    /// Maps known numeric key codes to page indexes.
    static func pageIndex(for keyCode: UInt16) -> Int? {
        let primary: [UInt16: Int] = [
            18: 0, // 1
            19: 1, // 2
            20: 2, // 3
            21: 3, // 4
            23: 4, // 5
            22: 5, // 6
            26: 6, // 7
            28: 7, // 8
            25: 8, // 9
            29: 9  // 0 -> page 10
        ]
        let keypad: [UInt16: Int] = [
            83: 0, // keypad 1
            84: 1, // keypad 2
            85: 2, // keypad 3
            86: 3, // keypad 4
            87: 4, // keypad 5
            88: 5, // keypad 6
            89: 6, // keypad 7
            91: 7, // keypad 8
            92: 8, // keypad 9
            82: 9  // keypad 0
        ]
        return primary[keyCode] ?? keypad[keyCode]
    }
}

/// Invisible AppKit host that captures scroll-wheel paging gestures.
struct ScrollWheelPagerOverlay: NSViewRepresentable {
    var isEnabled: Bool
    var pagingOrientation: PagingOrientation = .horizontal
    var onScrollProgress: (ScrollEvent) -> Void
    var onScrollEnd: () -> Void
    var onPreviousPage: () -> Void
    var onNextPage: () -> Void

    struct ScrollEvent {
        let deltaX: CGFloat
        let deltaY: CGFloat
        let phase: NSEvent.Phase
        let momentumPhase: NSEvent.Phase
        let isPrecise: Bool
    }

    /// Creates the AppKit coordinator that owns event monitors.
    func makeCoordinator() -> Coordinator {
        Coordinator(
            pagingOrientation: pagingOrientation,
            onScrollProgress: onScrollProgress,
            onScrollEnd: onScrollEnd,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage
        )
    }

    /// Creates a transparent host view used to scope event handling to this window.
    func makeNSView(context: Context) -> PagerPassthroughView {
        let view = PagerPassthroughView()
        view.coordinator = context.coordinator
        context.coordinator.hostView = view
        return view
    }

    /// Propagates SwiftUI state changes into the coordinator.
    func updateNSView(_ nsView: PagerPassthroughView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isEnabled = isEnabled
        context.coordinator.pagingOrientation = pagingOrientation
    }

    /// Tears down local monitors when the overlay leaves the hierarchy.
    static func dismantleNSView(_ nsView: PagerPassthroughView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    /// Owns the NSEvent monitor and maps scroll gestures from the hosting window into paging callbacks.
    @MainActor
    final class Coordinator {
        var isEnabled: Bool = true {
            didSet {
                if isEnabled == false {
                    resetState()
                }
            }
        }

        weak var hostView: NSView?
        var pagingOrientation: PagingOrientation

        private let onScrollProgress: (ScrollEvent) -> Void
        private let onScrollEnd: () -> Void
        private let onPreviousPage: () -> Void
        private let onNextPage: () -> Void
        private var scrollMonitor: EventMonitorToken?
        private var hasActivePagedScroll = false
        private var isIgnoringPreciseMomentum = false

        init(
            pagingOrientation: PagingOrientation,
            onScrollProgress: @escaping (ScrollEvent) -> Void,
            onScrollEnd: @escaping () -> Void,
            onPreviousPage: @escaping () -> Void,
            onNextPage: @escaping () -> Void
        ) {
            self.pagingOrientation = pagingOrientation
            self.onScrollProgress = onScrollProgress
            self.onScrollEnd = onScrollEnd
            self.onPreviousPage = onPreviousPage
            self.onNextPage = onNextPage
        }

        /// Installs a local scroll monitor once.
        func startMonitoringIfNeeded() {
            guard scrollMonitor == nil else { return }
            let token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event)
                return event
            }
            if let token {
                scrollMonitor = EventMonitorToken(token: token) { NSEvent.removeMonitor($0) }
            }
        }

        /// Removes installed monitors and resets gesture state.
        func stopMonitoring() {
            scrollMonitor?.invalidate()
            scrollMonitor = nil
            resetState()
        }

        /// Filters scroll events to the hosting window and translates them into paging actions.
        private func handleScrollEvent(_ event: NSEvent) {
            guard isEnabled,
                  let view = hostView,
                  let hostWindow = view.window,
                  // Ignore scrolls coming from other windows (e.g. settings) so we don't page the launcher.
                  event.window === hostWindow else {
                return
            }

            let location = event.locationInWindow
            let localPoint = view.convert(location, from: nil)
            guard view.bounds.contains(localPoint) else {
                return
            }

            let isPrecise = event.hasPreciseScrollingDeltas
            if isPrecise, event.phase.contains(.began) {
                isIgnoringPreciseMomentum = false
            }
            if isPrecise, isIgnoringPreciseMomentum {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    isIgnoringPreciseMomentum = false
                }
                return
            }

            let primaryDelta = pagingOrientation == .vertical ? event.scrollingDeltaY : event.scrollingDeltaX
            if abs(primaryDelta) > 0.01 {
                hasActivePagedScroll = true
                onScrollProgress(
                    ScrollEvent(
                        deltaX: event.scrollingDeltaX,
                        deltaY: event.scrollingDeltaY,
                        phase: event.phase,
                        momentumPhase: event.momentumPhase,
                        isPrecise: isPrecise
                    )
                )
            }

            if isPrecise == false {
                processDiscretePagingScroll(delta: primaryDelta)
            }

            if isPrecise, event.phase.contains(.ended) {
                if hasActivePagedScroll {
                    onScrollEnd()
                }
                hasActivePagedScroll = false
                isIgnoringPreciseMomentum = true
                return
            }

            if event.phase.contains(.ended)
                || event.phase.contains(.cancelled)
                || event.momentumPhase.contains(.ended)
                || event.momentumPhase.contains(.cancelled) {
                if hasActivePagedScroll {
                    onScrollEnd()
                }
                hasActivePagedScroll = false
            }
        }

        /// Maps discrete scrolls (e.g. mouse wheel) to next/previous page triggers.
        private func processDiscretePagingScroll(delta: CGFloat) {
            guard abs(delta) >= 1 else { return }
            if delta <= -1 {
                trigger(.next)
            } else if delta >= 1 {
                trigger(.previous)
            }
        }

        /// Dispatches page navigation callback for resolved direction.
        private func trigger(_ direction: PageDirection) {
            switch direction {
            case .next:
                onNextPage()
            case .previous:
                onPreviousPage()
            }
        }

        /// Clears in-progress scroll gesture tracking.
        private func resetState() {
            hasActivePagedScroll = false
            isIgnoringPreciseMomentum = false
        }

        private enum PageDirection {
            case next
            case previous
        }
    }

    /// A transparent NSView that reports window changes to the coordinator.
    final class PagerPassthroughView: NSView {
        weak var coordinator: Coordinator?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Binds monitor lifetime to the host view's window attachment.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                coordinator?.hostView = self
                coordinator?.startMonitoringIfNeeded()
            } else {
                coordinator?.hostView = nil
                coordinator?.stopMonitoring()
            }
        }

        /// Allows pointer events to pass through to underlying content.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// Captures arrow keys for paging and optionally handles Escape.
struct KeyPressPagerOverlay: NSViewRepresentable {
    var isEnabled: Bool
    var shouldCaptureArrowKeys: () -> Bool = { true }
    var shouldHandleEscape: () -> Bool = { false }
    var onPreviousPage: () -> Void
    var onNextPage: () -> Void
    var onEscape: () -> Void = {}
    var onPageShortcut: ((Int) -> Void)?
    var onVerticalNavigation: ((VerticalArrowDirection) -> Void)?

    enum VerticalArrowDirection {
        case up
        case down
    }

    /// Creates the keyboard coordinator handling arrow/page shortcut events.
    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldCaptureArrowKeys: shouldCaptureArrowKeys,
            shouldHandleEscape: shouldHandleEscape,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage,
            onEscape: onEscape,
            onPageShortcut: onPageShortcut,
            onVerticalNavigation: onVerticalNavigation
        )
    }

    /// Creates an invisible AppKit view used to scope keyboard interception.
    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.coordinator = context.coordinator
        context.coordinator.hostView = view
        return view
    }

    /// Updates coordinator wiring and enabled state from SwiftUI.
    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isEnabled = isEnabled
    }

    /// Stops key monitors when SwiftUI tears down the representable.
    static func dismantleNSView(_ nsView: KeyCaptureView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        var isEnabled: Bool = true {
            didSet {
                if isEnabled == false {
                    stopMonitoring()
                } else {
                    startMonitoringIfNeeded()
                }
            }
        }

        weak var hostView: NSView?

        private static let escapeKeyCode: UInt16 = 53
        private let onPreviousPage: () -> Void
        private let onNextPage: () -> Void
        private let shouldCaptureArrowKeys: () -> Bool
        private let shouldHandleEscape: () -> Bool
        private let onEscape: () -> Void
        private let onPageShortcut: ((Int) -> Void)?
        private let onVerticalNavigation: ((VerticalArrowDirection) -> Void)?
        private var keyDownMonitor: EventMonitorToken?
        private var keyUpMonitor: EventMonitorToken?

        init(
            shouldCaptureArrowKeys: @escaping () -> Bool,
            shouldHandleEscape: @escaping () -> Bool,
            onPreviousPage: @escaping () -> Void,
            onNextPage: @escaping () -> Void,
            onEscape: @escaping () -> Void,
            onPageShortcut: ((Int) -> Void)?,
            onVerticalNavigation: ((VerticalArrowDirection) -> Void)?
        ) {
            self.shouldCaptureArrowKeys = shouldCaptureArrowKeys
            self.shouldHandleEscape = shouldHandleEscape
            self.onPreviousPage = onPreviousPage
            self.onNextPage = onNextPage
            self.onEscape = onEscape
            self.onPageShortcut = onPageShortcut
            self.onVerticalNavigation = onVerticalNavigation
        }

        /// Installs key down/up local monitors once.
        func startMonitoringIfNeeded() {
            if keyDownMonitor == nil {
                let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handleKeyDown(event) ?? event
                }
                if let token {
                    keyDownMonitor = EventMonitorToken(token: token) { NSEvent.removeMonitor($0) }
                }
            }
            if keyUpMonitor == nil {
                let token = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                    self?.handleKeyUp(event) ?? event
                }
                if let token {
                    keyUpMonitor = EventMonitorToken(token: token) { NSEvent.removeMonitor($0) }
                }
            }
        }

        /// Removes key monitors.
        func stopMonitoring() {
            keyDownMonitor?.invalidate()
            keyUpMonitor?.invalidate()
            keyDownMonitor = nil
            keyUpMonitor = nil
        }

        /// Handles page shortcuts, arrow navigation, and Escape capture.
        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard isEnabled else { return event }
            guard let view = hostView, view.window != nil else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if let pageIndex = LauncherPageShortcuts.pageIndex(for: event),
               let onPageShortcut = onPageShortcut {
                onPageShortcut(pageIndex)
                return nil
            }

            let arrowModifiers = modifiers.subtracting([.numericPad, .function])
            guard arrowModifiers.isEmpty else { return event }

            if event.keyCode == Self.escapeKeyCode {
                guard shouldHandleEscape() else { return event }
                onEscape()
                return nil
            }

            guard let direction = ArrowDirection(keyCode: event.keyCode) else { return event }
            if direction.isVertical && onVerticalNavigation == nil {
                return event
            }
            guard shouldCaptureArrowKeys() else { return event }

            trigger(direction)
            return nil
        }

        /// Swallows key-up events for captured navigation keys.
        private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
            if event.keyCode == Self.escapeKeyCode {
                guard shouldHandleEscape() else { return event }
                return nil
            }

            guard let direction = ArrowDirection(keyCode: event.keyCode) else { return event }
            if direction.isVertical && onVerticalNavigation == nil {
                return event
            }
            guard shouldCaptureArrowKeys() else { return event }
            return nil
        }

        /// Routes directional input to horizontal/vertical navigation callbacks.
        private func trigger(_ direction: ArrowDirection) {
            switch direction {
            case .previous:
                onPreviousPage()
            case .next:
                onNextPage()
            case .up:
                onVerticalNavigation?(.up)
            case .down:
                onVerticalNavigation?(.down)
            }
        }

        private enum ArrowDirection {
            case previous
            case next
            case up
            case down

            init?(keyCode: UInt16) {
                switch keyCode {
                case 123:
                    self = .previous
                case 124:
                    self = .next
                case 125:
                    self = .down
                case 126:
                    self = .up
                default:
                    return nil
                }
            }

            var isVertical: Bool {
                switch self {
                case .up, .down:
                    return true
                default:
                    return false
                }
            }
        }
    }

    /// Transparent host view that keeps the coordinator tied to the active window.
    final class KeyCaptureView: NSView {
        weak var coordinator: Coordinator?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Starts/stops keyboard monitoring with window attachment lifecycle.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                coordinator?.hostView = self
                coordinator?.startMonitoringIfNeeded()
            } else {
                coordinator?.hostView = nil
                coordinator?.stopMonitoring()
            }
        }

        /// Keeps this overlay non-interactive for pointer hit-testing.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
