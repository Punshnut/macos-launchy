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
    private var lastTriggerDate: Date?
    private var lastDetectedCorner: HotCornerPosition?
    private var configuredCorner: HotCornerPosition = .bottomRight
    private var hasPromptedForInputMonitoring = false
    private var isMonitoringEnabled = false

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
            startMonitoringIfNeeded()
        } else {
            stopMonitoring()
        }
    }

    /// Ensures event monitoring is removed.
    func stopMonitoring() {
        globalMouseMonitor?.invalidate()
        localMouseMonitor?.invalidate()
        lastDetectedCorner = nil
        lastTriggerDate = nil
        isMonitoringEnabled = false
    }

    private func startMonitoringIfNeeded() {
        guard globalMouseMonitor == nil else { return }
        let globalToken = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateCursorLocation()
            }
        }
        if let token = globalToken {
            globalMouseMonitor = EventMonitorToken(token: token) { NSEvent.removeMonitor($0) }
        }

        guard localMouseMonitor == nil else { return }
        let localToken = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in
                self?.evaluateCursorLocation()
            }
            return event
        }
        if let token = localToken {
            localMouseMonitor = EventMonitorToken(token: token) { NSEvent.removeMonitor($0) }
        }
    }

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
