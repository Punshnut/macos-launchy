import AppKit
import CoreGraphics
import Darwin

enum HardwareClass: String, Equatable {
    case appleSilicon
    case intel
}

struct PerformanceCapability: Equatable {
    let hardwareClass: HardwareClass
    let screenScale: CGFloat
    let pixelSize: CGSize
    let refreshRate: Double?
    let hasExternalDisplay: Bool
    let isExternalDisplay: Bool

    var pixelArea: CGFloat {
        pixelSize.width * pixelSize.height
    }
}

struct PerformanceTuning: Equatable {
    let highQualityIconCacheLimit: Int
    let highQualityRequestDelay: TimeInterval
    let searchInputDebounceNanoseconds: UInt64
    let searchMetadataDebounceNanoseconds: UInt64
    let visiblePagesDebounceNanoseconds: UInt64
    let folderPreviewCacheCountLimit: Int
    let folderPreviewCacheCostLimit: Int
}

final class PerformanceCapabilityLayer: @unchecked Sendable {
    static let shared = PerformanceCapabilityLayer()

    private let lock = NSLock()
    private var cachedCapability: (screenID: CGDirectDisplayID?, capability: PerformanceCapability)?
    private var cachedTuning: (screenID: CGDirectDisplayID?, tuning: PerformanceTuning)?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateCache()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func capabilities(for screen: NSScreen?) -> PerformanceCapability {
        let screenID = displayID(for: screen)
        lock.lock()
        if let cached = cachedCapability, cached.screenID == screenID {
            lock.unlock()
            return cached.capability
        }
        lock.unlock()

        let capability = buildCapabilities(for: screen, screenID: screenID)
        lock.lock()
        cachedCapability = (screenID, capability)
        cachedTuning = nil
        lock.unlock()
        return capability
    }

    func tuning(for screen: NSScreen?) -> PerformanceTuning {
        let screenID = displayID(for: screen)
        lock.lock()
        if let cached = cachedTuning, cached.screenID == screenID {
            lock.unlock()
            return cached.tuning
        }
        lock.unlock()

        let capability = capabilities(for: screen)
        let tuning = buildTuning(for: capability)
        lock.lock()
        cachedTuning = (screenID, tuning)
        lock.unlock()
        return tuning
    }

    func screenScale(for screen: NSScreen?) -> CGFloat {
        capabilities(for: screen).screenScale
    }

    func currentScreenScale() -> CGFloat {
        let screen = Thread.isMainThread ? ScreenProvider.screenUnderMouseOrMain() : NSScreen.main
        return screenScale(for: screen)
    }

    private func invalidateCache() {
        lock.lock()
        cachedCapability = nil
        cachedTuning = nil
        lock.unlock()
    }

    private func buildCapabilities(for screen: NSScreen?, screenID: CGDirectDisplayID?) -> PerformanceCapability {
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelSize = pixelSize(for: screen, screenID: screenID, fallbackScale: scale)
        let refreshRate = refreshRate(for: screen, screenID: screenID)
        let hasExternalDisplay = Self.anyExternalDisplayPresent()
        let isExternalDisplay = Self.isExternalDisplay(screenID: screenID)

        return PerformanceCapability(
            hardwareClass: Self.detectHardwareClass(),
            screenScale: scale,
            pixelSize: pixelSize,
            refreshRate: refreshRate,
            hasExternalDisplay: hasExternalDisplay,
            isExternalDisplay: isExternalDisplay
        )
    }

    private func buildTuning(for capability: PerformanceCapability) -> PerformanceTuning {
        let pixelArea = capability.pixelArea
        let isLargePixelArea = pixelArea >= 7_000_000
        let isHugePixelArea = pixelArea >= 12_000_000
        let isIntel = capability.hardwareClass == .intel
        let hasExternal = capability.hasExternalDisplay || capability.isExternalDisplay
        let refreshRate = capability.refreshRate ?? 60

        let baseHighQualityIconCacheLimit = 90
        let baseHighQualityRequestDelay: TimeInterval = 0.28
        let baseSearchInputDebounce: UInt64 = 35_000_000
        let baseSearchMetadataDebounce: UInt64 = 120_000_000
        let baseVisiblePagesDebounce: UInt64 = 16_000_000
        let baseFolderPreviewCacheCountLimit = 120
        let baseFolderPreviewCacheCostLimit = 18 * 1024 * 1024

        var highQualityIconCacheLimit = baseHighQualityIconCacheLimit
        var visiblePagesDebounce = baseVisiblePagesDebounce
        var folderPreviewCacheCountLimit = baseFolderPreviewCacheCountLimit
        var folderPreviewCacheCostLimit = baseFolderPreviewCacheCostLimit

        if isLargePixelArea || hasExternal {
            highQualityIconCacheLimit = 110
            visiblePagesDebounce = 20_000_000
            folderPreviewCacheCountLimit = 140
            folderPreviewCacheCostLimit = 24 * 1024 * 1024
        }

        if isHugePixelArea {
            highQualityIconCacheLimit = 120
            visiblePagesDebounce = 24_000_000
            folderPreviewCacheCountLimit = 160
            folderPreviewCacheCostLimit = 30 * 1024 * 1024
        }

        if isIntel || refreshRate >= 90 {
            visiblePagesDebounce = max(visiblePagesDebounce, 24_000_000)
        }

        return PerformanceTuning(
            highQualityIconCacheLimit: highQualityIconCacheLimit,
            highQualityRequestDelay: baseHighQualityRequestDelay,
            searchInputDebounceNanoseconds: baseSearchInputDebounce,
            searchMetadataDebounceNanoseconds: baseSearchMetadataDebounce,
            visiblePagesDebounceNanoseconds: visiblePagesDebounce,
            folderPreviewCacheCountLimit: folderPreviewCacheCountLimit,
            folderPreviewCacheCostLimit: folderPreviewCacheCostLimit
        )
    }

    private func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private func pixelSize(
        for screen: NSScreen?,
        screenID: CGDirectDisplayID?,
        fallbackScale: CGFloat
    ) -> CGSize {
        if let screenID,
           let mode = CGDisplayCopyDisplayMode(screenID) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let frameSize = screen?.frame.size ?? NSScreen.main?.frame.size ?? .zero
        return CGSize(width: frameSize.width * fallbackScale, height: frameSize.height * fallbackScale)
    }

    private func refreshRate(for screen: NSScreen?, screenID: CGDirectDisplayID?) -> Double? {
        if let screenID,
           let mode = CGDisplayCopyDisplayMode(screenID) {
            let rate = mode.refreshRate
            if rate > 0 {
                return rate
            }
        }
        if #available(macOS 12.0, *) {
            if let maxRate = screen?.maximumFramesPerSecond, maxRate > 0 {
                return Double(maxRate)
            }
        }
        return nil
    }

    private static func anyExternalDisplayPresent() -> Bool {
        NSScreen.screens.contains { screen in
            guard let screenID = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(screenID) == 0
        }
    }

    private static func isExternalDisplay(screenID: CGDirectDisplayID?) -> Bool {
        guard let screenID else { return false }
        return CGDisplayIsBuiltin(screenID) == 0
    }

    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private static func detectHardwareClass() -> HardwareClass {
        #if arch(arm64)
        return .appleSilicon
        #else
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        if result == 0 && value == 1 {
            return .appleSilicon
        }
        return .intel
        #endif
    }
}
