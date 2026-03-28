import AppKit
import ApplicationServices

/// Watches the mouse cursor and triggers an action whenever the configured hot corner is entered.
@MainActor
final class HotCornerMonitor {
    private let trigger: () -> Void
    private let edgeThreshold: CGFloat = 28
    private let activationCooldown: TimeInterval = 1.0

    private var globalMouseMonitor: EventMonitorToken?
    private var localMouseMonitor: EventMonitorToken?
    private var screenChangeObserver: NSObjectProtocol?
    private var lastTriggerDate: Date?
    private var lastDetectedCorner: HotCornerPosition?
    private var configuredCorner: HotCornerPosition = .bottomRight
    private var hasPromptedForInputMonitoring = false
    private var isMonitoringEnabled = false
    private nonisolated(unsafe) var isEvalPending = false
    /// Pre-computed activation rects in screen coordinates, updated on screen/corner changes.
    /// Accessed from the background event thread — nonisolated(unsafe) is safe here because
    /// writes happen only on the main actor and reads only check geometry (no object graph).
    private nonisolated(unsafe) var cachedCornerRects: [CGRect] = []

    init(trigger: @escaping () -> Void) {
        self.trigger = trigger
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.stopMonitoring()
        }
    }

    /// Reconfigures the monitor with the latest enabled state and target corner.
    func update(enabled: Bool, corner: HotCornerPosition) {
        configuredCorner = corner
        lastDetectedCorner = nil
        let shouldPromptForAccess = enabled && isMonitoringEnabled == false
        isMonitoringEnabled = enabled
        if enabled {
            if shouldPromptForAccess {
                requestInputMonitoringPermissionIfNeeded()
            }
            updateCachedCornerRects()
            startMonitoringIfNeeded()
        } else {
            stopMonitoring()
        }
    }

    /// Ensures event monitoring is removed.
    func stopMonitoring() {
        globalMouseMonitor?.invalidate()
        localMouseMonitor?.invalidate()
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            screenChangeObserver = nil
        }
        cachedCornerRects = []
        lastDetectedCorner = nil
        lastTriggerDate = nil
        isMonitoringEnabled = false
    }

    /// Starts global and local mouse move monitors if they are not already active.
    private func startMonitoringIfNeeded() {
        updateCachedCornerRects()

        if screenChangeObserver == nil {
            screenChangeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateCachedCornerRects()
                }
            }
        }

        guard globalMouseMonitor == nil else { return }
        let globalToken = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self, !self.isEvalPending else { return }
            let location = NSEvent.mouseLocation
            let rects = self.cachedCornerRects
            guard rects.contains(where: { $0.contains(location) }) else { return }
            self.isEvalPending = true
            DispatchQueue.main.async { [weak self] in
                self?.isEvalPending = false
                self?.evaluateCursorLocation()
            }
        }
        if let token = globalToken {
            globalMouseMonitor = EventMonitorToken(token: token) { NSEvent.removeMonitor($0) }
        }

        guard localMouseMonitor == nil else { return }
        let localToken = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            if let self, !self.isEvalPending {
                let location = NSEvent.mouseLocation
                let rects = self.cachedCornerRects
                if rects.contains(where: { $0.contains(location) }) {
                    self.isEvalPending = true
                    DispatchQueue.main.async { [weak self] in
                        self?.isEvalPending = false
                        self?.evaluateCursorLocation()
                    }
                }
            }
            return event
        }
        if let token = localToken {
            localMouseMonitor = EventMonitorToken(token: token) { NSEvent.removeMonitor($0) }
        }
    }

    /// Recomputes the activation rect for the configured corner across all screens.
    private func updateCachedCornerRects() {
        let corner = configuredCorner
        let threshold = edgeThreshold
        cachedCornerRects = NSScreen.screens.map { screen in
            let frame = screen.frame
            let x: CGFloat
            let y: CGFloat
            switch corner {
            case .topLeft, .bottomLeft:
                x = frame.minX
            case .topRight, .bottomRight:
                x = frame.maxX - threshold
            }
            switch corner {
            case .topLeft, .topRight:
                y = frame.maxY - threshold
            case .bottomLeft, .bottomRight:
                y = frame.minY
            }
            return CGRect(x: x, y: y, width: threshold, height: threshold)
        }
    }

    /// Prompts for accessibility input monitoring when the feature is enabled.
    private func requestInputMonitoringPermissionIfNeeded() {
        guard hasPromptedForInputMonitoring == false else { return }
        hasPromptedForInputMonitoring = true
        guard let promptKey = CFStringCreateWithCString(
            nil,
            "AXTrustedCheckOptionPrompt",
            CFStringBuiltInEncodings.UTF8.rawValue
        ) else {
            return
        }
        let options = [promptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Detects whether the cursor sits inside the configured corner and debounces triggers.
    private func evaluateCursorLocation() {
        let currentLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(currentLocation) }) else {
            lastDetectedCorner = nil
            return
        }

        guard isPoint(currentLocation, in: configuredCorner, on: screen) else {
            lastDetectedCorner = nil
            return
        }

        guard lastDetectedCorner != configuredCorner else { return }
        let now = Date()
        if let last = lastTriggerDate, now.timeIntervalSince(last) < activationCooldown {
            return
        }

        lastDetectedCorner = configuredCorner
        lastTriggerDate = now
        trigger()
    }

    /// Tests whether a cursor point falls inside the configured corner activation rectangle.
    private func isPoint(_ point: CGPoint, in corner: HotCornerPosition, on screen: NSScreen) -> Bool {
        let frame = screen.frame
        let isWithinX: Bool
        let isWithinY: Bool

        switch corner {
        case .topLeft, .bottomLeft:
            isWithinX = point.x >= frame.minX && point.x <= frame.minX + edgeThreshold
        case .topRight, .bottomRight:
            isWithinX = point.x <= frame.maxX && point.x >= frame.maxX - edgeThreshold
        }

        switch corner {
        case .topLeft, .topRight:
            isWithinY = point.y <= frame.maxY && point.y >= frame.maxY - edgeThreshold
        case .bottomLeft, .bottomRight:
            isWithinY = point.y >= frame.minY && point.y <= frame.minY + edgeThreshold
        }

        return isWithinX && isWithinY
    }
}
