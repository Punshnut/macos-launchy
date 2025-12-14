import SwiftUI
import AppKit

/// Maps modifier+key combinations to page indices so keyboard shortcuts can jump between pages.
enum LauncherPageShortcuts {
    static func pageIndex(for event: NSEvent) -> Int? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let filteredModifiers = modifiers.subtracting([.numericPad, .function, .capsLock])
        guard filteredModifiers == [.control] else { return nil }
        return pageIndex(for: event.keyCode)
    }

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

/// Invisible AppKit host that captures scroll wheel events so users can page through the launcher with gestures.
struct ScrollWheelPagerOverlay: NSViewRepresentable {
    var isEnabled: Bool
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

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScrollProgress: onScrollProgress,
            onScrollEnd: onScrollEnd,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage
        )
    }

    func makeNSView(context: Context) -> PagerPassthroughView {
        let view = PagerPassthroughView()
        view.coordinator = context.coordinator
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(_ nsView: PagerPassthroughView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_ nsView: PagerPassthroughView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    /// Keeps track of the AppKit event monitor and translates deltas into paging requests.
    @MainActor
    /// Keeps track of the AppKit event monitor and translates deltas into paging requests.
    final class Coordinator {
        var isEnabled: Bool = true {
            didSet {
                if isEnabled == false {
                    resetState()
                }
            }
        }

        weak var hostView: NSView?

        private let onScrollProgress: (ScrollEvent) -> Void
        private let onScrollEnd: () -> Void
        private let onPreviousPage: () -> Void
        private let onNextPage: () -> Void
        private var scrollMonitor: EventMonitorToken?
        private var hasActiveHorizontalScroll = false

        init(
            onScrollProgress: @escaping (ScrollEvent) -> Void,
            onScrollEnd: @escaping () -> Void,
            onPreviousPage: @escaping () -> Void,
            onNextPage: @escaping () -> Void
        ) {
            self.onScrollProgress = onScrollProgress
            self.onScrollEnd = onScrollEnd
            self.onPreviousPage = onPreviousPage
            self.onNextPage = onNextPage
        }

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

            if abs(event.scrollingDeltaX) > 0.01 {
                hasActiveHorizontalScroll = true
                onScrollProgress(
                    ScrollEvent(
                        deltaX: event.scrollingDeltaX,
                        deltaY: event.scrollingDeltaY,
                        phase: event.phase,
                        momentumPhase: event.momentumPhase,
                        isPrecise: event.hasPreciseScrollingDeltas
                    )
                )
            }

            if event.hasPreciseScrollingDeltas == false {
                processDiscreteVerticalScroll(delta: event.scrollingDeltaY)
            }

            if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
                if hasActiveHorizontalScroll {
                    onScrollEnd()
                }
                hasActiveHorizontalScroll = false
            }
        }

        /// Maps discrete vertical scrolls (e.g. mouse wheel) to next/previous page triggers.
        private func processDiscreteVerticalScroll(delta: CGFloat) {
            guard abs(delta) >= 1 else { return }
            if delta <= -1 {
                trigger(.next)
            } else if delta >= 1 {
                trigger(.previous)
            }
        }

        private func trigger(_ direction: PageDirection) {
            switch direction {
            case .next:
                onNextPage()
            case .previous:
                onPreviousPage()
            }
        }

        private func resetState() {
            hasActiveHorizontalScroll = false
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

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// Captures left/right arrow key presses (when not typing) to trigger page changes and optionally swallows Escape.
struct KeyPressPagerOverlay: NSViewRepresentable {
    var isEnabled: Bool
    var shouldCaptureArrowKeys: () -> Bool = { true }
    var shouldHandleEscape: () -> Bool = { false }
    var onPreviousPage: () -> Void
    var onNextPage: () -> Void
    var onEscape: () -> Void = {}
    var onPageShortcut: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldCaptureArrowKeys: shouldCaptureArrowKeys,
            shouldHandleEscape: shouldHandleEscape,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage,
            onEscape: onEscape,
            onPageShortcut: onPageShortcut
        )
    }

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.coordinator = context.coordinator
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_ nsView: KeyCaptureView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        var isEnabled: Bool = true {
            didSet {
                if isEnabled == false {
                    stopRepeating()
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
        private let repeatInterval: TimeInterval = 0.5 // Hold-to-repeat cadence.
        private var keyDownMonitor: EventMonitorToken?
        private var keyUpMonitor: EventMonitorToken?
        private var repeatTimer: Timer?
        private var repeatingDirection: ArrowDirection?

        init(
            shouldCaptureArrowKeys: @escaping () -> Bool,
            shouldHandleEscape: @escaping () -> Bool,
            onPreviousPage: @escaping () -> Void,
            onNextPage: @escaping () -> Void,
            onEscape: @escaping () -> Void,
            onPageShortcut: ((Int) -> Void)?
        ) {
            self.shouldCaptureArrowKeys = shouldCaptureArrowKeys
            self.shouldHandleEscape = shouldHandleEscape
            self.onPreviousPage = onPreviousPage
            self.onNextPage = onNextPage
            self.onEscape = onEscape
            self.onPageShortcut = onPageShortcut
        }

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

        func stopMonitoring() {
            keyDownMonitor?.invalidate()
            keyUpMonitor?.invalidate()
            keyDownMonitor = nil
            keyUpMonitor = nil
            stopRepeating()
        }

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
                stopRepeating()
                onEscape()
                return nil
            }

            guard let direction = ArrowDirection(keyCode: event.keyCode) else { return event }
            guard shouldCaptureArrowKeys() else { return event }

            if event.isARepeat {
                return nil
            }

            beginRepeating(direction)
            return nil
        }

        private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
            if event.keyCode == Self.escapeKeyCode {
                guard shouldHandleEscape() else { return event }
                stopRepeating()
                return nil
            }

            guard let direction = ArrowDirection(keyCode: event.keyCode) else { return event }
            guard shouldCaptureArrowKeys() else { return event }
            stopRepeating(for: direction)
            return nil
        }

        private func beginRepeating(_ direction: ArrowDirection) {
            stopRepeating()
            trigger(direction)
            repeatingDirection = direction
            startTimer()
        }

        private func trigger(_ direction: ArrowDirection) {
            switch direction {
            case .previous:
                onPreviousPage()
            case .next:
                onNextPage()
            }
        }

        private func startTimer() {
            let timer = Timer(timeInterval: repeatInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fireRepeat()
                }
            }
            repeatTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func fireRepeat() {
            guard isEnabled, let direction = repeatingDirection else {
                stopRepeating()
                return
            }
            trigger(direction)
        }

        private func stopRepeating(for direction: ArrowDirection? = nil) {
            if let direction, repeatingDirection != direction {
                return
            }
            repeatTimer?.invalidate()
            repeatTimer = nil
            repeatingDirection = nil
        }

        private enum ArrowDirection {
            case previous
            case next

            init?(keyCode: UInt16) {
                switch keyCode {
                case 123:
                    self = .previous
                case 124:
                    self = .next
                default:
                    return nil
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

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
