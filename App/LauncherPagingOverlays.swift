import SwiftUI
import AppKit

/// Invisible AppKit host that captures scroll wheel events so users can page through the launcher with gestures.
struct ScrollWheelPagerOverlay: NSViewRepresentable {
    var isEnabled: Bool
    var onPreviousPage: () -> Void
    var onNextPage: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPreviousPage: onPreviousPage, onNextPage: onNextPage)
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
    final class Coordinator {
        var isEnabled: Bool = true {
            didSet {
                if isEnabled == false {
                    resetAccumulators()
                }
            }
        }

        weak var hostView: NSView?

        private let onPreviousPage: () -> Void
        private let onNextPage: () -> Void
        private var scrollMonitorToken: Any?
        private var horizontalDeltaAccumulator: CGFloat = 0
        private let precisionThreshold: CGFloat = 60

        init(onPreviousPage: @escaping () -> Void, onNextPage: @escaping () -> Void) {
            self.onPreviousPage = onPreviousPage
            self.onNextPage = onNextPage
        }

        func startMonitoringIfNeeded() {
            guard scrollMonitorToken == nil else { return }
            scrollMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event)
                return event
            }
        }

        func stopMonitoring() {
            if let scrollMonitorToken {
                NSEvent.removeMonitor(scrollMonitorToken)
            }
            scrollMonitorToken = nil
            resetAccumulators()
        }

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

            if event.phase.contains(.began) {
                horizontalDeltaAccumulator = 0
            }

            if processHorizontalScroll(delta: event.scrollingDeltaX, isPrecise: event.hasPreciseScrollingDeltas) {
                if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
                    horizontalDeltaAccumulator = 0
                }
                return
            }

            if event.hasPreciseScrollingDeltas == false {
                processDiscreteVerticalScroll(delta: event.scrollingDeltaY)
            }

            if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
                horizontalDeltaAccumulator = 0
            }
        }

        @discardableResult
        private func processHorizontalScroll(delta: CGFloat, isPrecise: Bool) -> Bool {
            guard abs(delta) > 0.01 else { return false }

            let threshold = isPrecise ? precisionThreshold : 3
            horizontalDeltaAccumulator += delta

            if horizontalDeltaAccumulator <= -threshold {
                trigger(.next)
                horizontalDeltaAccumulator = 0
                return true
            } else if horizontalDeltaAccumulator >= threshold {
                trigger(.previous)
                horizontalDeltaAccumulator = 0
                return true
            }

            return false
        }

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

        private func resetAccumulators() {
            horizontalDeltaAccumulator = 0
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

/// Captures left/right arrow key presses (when not typing) to trigger page changes.
struct KeyPressPagerOverlay: NSViewRepresentable {
    var isEnabled: Bool
    var onPreviousPage: () -> Void
    var onNextPage: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPreviousPage: onPreviousPage, onNextPage: onNextPage)
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
                    stopMonitoring()
                } else {
                    startMonitoringIfNeeded()
                }
            }
        }

        weak var hostView: NSView?

        private let onPreviousPage: () -> Void
        private let onNextPage: () -> Void
        private var keyMonitorToken: Any?

        init(onPreviousPage: @escaping () -> Void, onNextPage: @escaping () -> Void) {
            self.onPreviousPage = onPreviousPage
            self.onNextPage = onNextPage
        }

        func startMonitoringIfNeeded() {
            guard keyMonitorToken == nil else { return }
            keyMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyEvent(event)
                return event
            }
        }

        func stopMonitoring() {
            if let keyMonitorToken {
                NSEvent.removeMonitor(keyMonitorToken)
            }
            keyMonitorToken = nil
        }

        private func handleKeyEvent(_ event: NSEvent) {
            guard isEnabled else { return }
            guard let view = hostView, view.window != nil else { return }

            if let responder = event.window?.firstResponder, responder is NSTextView {
                return
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty else { return }

            switch event.keyCode {
            case 123: // left arrow
                onPreviousPage()
            case 124: // right arrow
                onNextPage()
            default:
                break
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
