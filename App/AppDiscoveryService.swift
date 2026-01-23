import AppKit
import Accelerate
import ImageIO
import UniformTypeIdentifiers

enum IconRenderQuality: String {
    case low
    case balanced
    case medium
    case high

    var cacheSuffix: String {
        switch self {
        case .low: return "l"
        case .balanced: return "b"
        case .medium: return "m"
        case .high: return "h"
        }
    }

    var pixelCap: Int {
        switch self {
        case .low: return 80
        case .balanced: return 120
        case .medium: return 160
        case .high: return 200
        }
    }

    var imageInterpolation: NSImageInterpolation {
        switch self {
        case .low:
            return .low
        case .balanced:
            return .medium
        case .medium:
            return .medium
        case .high:
            return .high
        }
    }
}

/// Discoverer that scans common application folders and prepares `AppItem` models.
final class AppDiscoveryService {
    private let fileSystem: FileManager
    private let workspaceInterface: NSWorkspace
    private let customApplicationDirectories: [URL]?
    private let userApplicationsDirectory: URL
    private let coreServicesDirectory = URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
    private let iconCache = NSCache<NSString, NSImage>()
    private let preparedIconCache = NSCache<NSString, NSImage>()
    private let metadataLock = NSLock()
    private var iconCacheKeys: Set<String> = []
    private var iconModificationDates: [String: Date] = [:]
    private var iconGenerations: [String: Int] = [:]
    private var lastIconValidationDates: [String: Date] = [:]
    private var preparedIconKeysByBundleID: [String: Set<String>] = [:]
    private var lastIconAccessDate = Date()
    private var appearanceCacheToken: String
    private let iconPreparationQueue = DispatchQueue(label: "com.launchy.icon-prep", qos: .userInitiated)
    private let cacheReleaseQueue = DispatchQueue(label: "com.launchy.cache-release", qos: .utility)
    private var preparedCacheReleaseTask: Task<Void, Never>?
    private var iconCacheReleaseTask: Task<Void, Never>?
    private let appCachePersistenceQueue = DispatchQueue(label: "com.launchy.app-cache-persistence", qos: .utility)
    private let appCacheURL: URL
    private var cachedAppsByBundleID: [String: CachedAppRecord]
    private lazy var defaultApplicationIconData: Data? = {
        let icon: NSImage
        if #available(macOS 12.0, *) {
            icon = workspaceInterface.icon(for: UTType.applicationBundle)
        } else {
            icon = workspaceInterface.icon(forFileType: "app")
        }
        return normalizedIconData(for: icon)
    }()
    /// Global scale applied to icon bitmaps to reduce peak memory usage without changing layout sizes.
    private static let iconResolutionScale: CGFloat = 0.65
    private static let maximumIconDimension: CGFloat = CGFloat(256) * iconResolutionScale
    private static let iconCacheCountLimit = 200
    private static let preparedIconCacheCountLimit = 260
    private static let iconCacheCostLimit = 12_000_000
    private static let preparedIconCacheCostLimit = 16_000_000
    private static let preparedIconCacheIdleReleaseInterval: TimeInterval = 65
    private static let iconCacheIdleReleaseInterval: TimeInterval = 300
    private static let iconValidationInterval: TimeInterval = 900
    private static let missingAppRetentionInterval: TimeInterval = 70

    /// Configures the service with dependencies mainly to aid testing.
    init(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        applicationDirectories: [URL]? = nil
    ) {
        self.fileSystem = fileManager
        self.workspaceInterface = workspace
        self.customApplicationDirectories = applicationDirectories
        self.userApplicationsDirectory = fileSystem
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let supportDirectory = Self.applicationSupportDirectory(fileManager: fileSystem)
        self.appCacheURL = supportDirectory.appendingPathComponent("app-catalog.json")
        self.cachedAppsByBundleID = Self.loadCachedApps(from: appCacheURL)
        self.appearanceCacheToken = Self.appearanceToken(for: nil)

        configureIconCacheLimits()
    }

    /// Rebuilds the cached list of installed apps, optionally excluding hidden bundle identifiers.
    func reloadApps(
        includeUserApplicationsFolder: Bool = true,
        hiddenBundleIDs: Set<String> = [],
        sorting: ArrangementResetSorting = .alphabetical
    ) -> (main: [AppItem], userApplications: [AppItem], allVisible: [AppItem]) {
        var appsByBundleID: [String: AppItem] = [:]
        var discoveryOrder: [String] = []
        let now = Date()

        LaunchyLogger.log("AppDiscovery: reload apps (includeUserApplicationsFolder=\(includeUserApplicationsFolder), hiddenCount=\(hiddenBundleIDs.count))")

        let directories = customApplicationDirectories
            ?? defaultApplicationDirectories(includeUserApplicationsFolder: includeUserApplicationsFolder)

        for directory in directories {
            LaunchyLogger.log("AppDiscovery: scanning directory \(directory.path)")
            let isCoreServicesDirectory = directory.standardizedFileURL == coreServicesDirectory.standardizedFileURL
            for app in discoverApplications(in: directory, isCoreServicesDirectory: isCoreServicesDirectory) {
                let bundleID = app.bundleIdentifier
                if appsByBundleID[bundleID] == nil {
                    discoveryOrder.append(bundleID)
                }
                appsByBundleID[bundleID] = app
            }
        }

        let restoredApps = restoredAppsFromCache(
            existingApps: appsByBundleID,
            referenceDate: now,
            includeUserApplicationsFolder: includeUserApplicationsFolder
        )
        if restoredApps.isEmpty == false {
            LaunchyLogger.log("AppDiscovery: restoring \(restoredApps.count) cached apps missing from scan")
            for app in restoredApps {
                let bundleID = app.bundleIdentifier
                if appsByBundleID[bundleID] == nil {
                    discoveryOrder.append(bundleID)
                }
                appsByBundleID[bundleID] = app
            }
        }
        updateCachedApps(with: appsByBundleID, seenAt: now)

        let orderedApps: [AppItem]
        if sorting == .alphabetical {
            orderedApps = appsByBundleID.values
                .sorted { $0.sortingName.localizedCaseInsensitiveCompare($1.sortingName) == .orderedAscending }
        } else {
            let orderedByDiscovery = discoveryOrder
                .compactMap { appsByBundleID[$0] }
            // Append any stragglers that weren't captured in discoveryOrder (safety for future changes).
            let remaining = appsByBundleID.keys
                .filter { discoveryOrder.contains($0) == false }
                .compactMap { appsByBundleID[$0] }
            orderedApps = orderedByDiscovery + remaining
        }

        let visibleApps = orderedApps.filter { hiddenBundleIDs.contains($0.bundleIdentifier) == false }
        let userApplications = visibleApps.filter { $0.isUserApplication }
        let mainApplications = visibleApps.filter { $0.isUserApplication == false }
        let userAppsToReturn = includeUserApplicationsFolder ? userApplications : []
        synchronizeIconMetadata(for: visibleApps)
        return (main: mainApplications, userApplications: userAppsToReturn, allVisible: visibleApps)
    }

    /// Keeps cache metadata in sync with the current set of apps and evicts stale entries.
    func synchronizeIconMetadata(for apps: [AppItem]) {
        let bundleIDs = Set(apps.map(\.bundleIdentifier))
        evictMissingBundleCaches(keeping: bundleIDs)
        for app in apps {
            invalidateIfBundleUpdated(app, force: true)
        }
    }

    /// Returns the lazily-loaded icon for an app, caching results by bundle identifier.
    func resolveIcon(for app: AppItem) -> NSImage? {
        recordIconAccess()
        invalidateIfBundleUpdated(app)
        if let cached = iconCache.object(forKey: app.bundleIdentifier as NSString) {
            return cached
        }

        guard let appURL = app.bundleURL else { return nil }
        let icon = workspaceInterface.icon(forFile: appURL.path)
        let scaledIcon = scaledIconIfNeeded(icon)
        cacheIcon(scaledIcon, for: app.bundleIdentifier)
        return scaledIcon
    }

    /// Clears the cached icons, forcing the next `resolveIcon(for:)` call to reload from disk.
    func clearIconCache(cancelIdleRelease: Bool = true) {
        if cancelIdleRelease {
            cancelIdleCacheRelease()
        }
        iconCache.removeAllObjects()
        clearPreparedIconCaches()
        metadataLock.lock()
        iconModificationDates.removeAll()
        iconGenerations.removeAll()
        lastIconValidationDates.removeAll()
        iconCacheKeys.removeAll()
        metadataLock.unlock()
    }

    /// Rebuilds appearance-sensitive icon caches when the system toggles light/dark mode.
    func handleAppearanceChange(_ appearance: NSAppearance?) {
        let newToken = Self.appearanceToken(for: appearance)
        var didChange = false

        metadataLock.lock()
        if appearanceCacheToken != newToken {
            appearanceCacheToken = newToken
            didChange = true
        }
        metadataLock.unlock()

        guard didChange else { return }
        clearPreparedIconCaches()
    }

    /// Drops prepared and base icon bitmaps to minimize memory while the launcher is hidden.
    func shrinkCachesForHiddenLauncher() {
        cancelIdleCacheRelease()
        clearPreparedIconCaches()
        iconCache.removeAllObjects()
        metadataLock.lock()
        iconModificationDates.removeAll()
        iconGenerations.removeAll()
        lastIconValidationDates.removeAll()
        iconCacheKeys.removeAll()
        metadataLock.unlock()
    }

    /// Releases cached icons that are not part of the preferred keep set, respecting recent activity.
    func trimCaches(
        keeping bundleIdentifiersToKeep: Set<String>,
        aggressively: Bool = false,
        idleOnlyAfter idleInterval: TimeInterval = 90
    ) {
        let now = Date()
        metadataLock.lock()
        let lastAccess = lastIconAccessDate
        metadataLock.unlock()

        if aggressively == false && now.timeIntervalSince(lastAccess) < idleInterval {
            return
        }

        let trackedBundles: Set<String>
        metadataLock.lock()
        trackedBundles = iconCacheKeys.union(preparedIconKeysByBundleID.keys)
        metadataLock.unlock()

        if aggressively {
            clearPreparedIconCaches()
        }

        let removable = trackedBundles.subtracting(bundleIdentifiersToKeep)
        guard removable.isEmpty == false else { return }

        for bundleID in removable {
            removeCachedIcons(for: bundleID)
        }

        metadataLock.lock()
        for bundleID in removable {
            iconModificationDates.removeValue(forKey: bundleID)
            iconGenerations.removeValue(forKey: bundleID)
            lastIconValidationDates.removeValue(forKey: bundleID)
        }
        metadataLock.unlock()
    }

    /// Returns an icon scaled to the exact dimension the grid needs, keeping memory usage bounded.
    func preparedIcon(
        for app: AppItem,
        targetDimension: CGFloat,
        quality: IconRenderQuality = .medium,
        screenScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    ) -> NSImage? {
        recordIconAccess()
        invalidateIfBundleUpdated(app)
        let pixelDimension = pixelDimension(for: targetDimension, quality: quality, screenScale: screenScale)
        let generation = iconGeneration(for: app.bundleIdentifier)
        let appearanceToken = currentAppearanceCacheToken()
        let cacheKey = preparedIconCacheKey(
            for: app.bundleIdentifier,
            dimension: pixelDimension,
            quality: quality,
            generation: generation,
            appearanceToken: appearanceToken
        )
        if let cached = preparedIconCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        guard let baseIcon = resolveIcon(for: app) else { return nil }
        let sized = resizedIcon(baseIcon, pixelDimension: pixelDimension, quality: quality)
        cachePreparedIcon(sized, forKey: cacheKey, bundleIdentifier: app.bundleIdentifier)
        return sized
    }

    /// Warms a bounded number of icons on a background queue so the grid renders without stalls.
    func preheatIcons(
        for apps: [AppItem],
        targetDimension: CGFloat,
        qualities: [IconRenderQuality] = [.low, .medium],
        screenScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2,
        limit: Int = 80
    ) {
        guard apps.isEmpty == false else { return }
        let slice = Array(apps.prefix(limit))
        let resolvedScale = max(screenScale, 1)
        let dimension = targetDimension

        iconPreparationQueue.async { [weak self] in
            guard let self else { return }
            for app in slice {
                autoreleasepool {
                    for quality in qualities {
                        _ = self.preparedIcon(
                            for: app,
                            targetDimension: dimension,
                            quality: quality,
                            screenScale: resolvedScale
                        )
                    }
                }
            }
        }
    }

    /// Lists `.app` bundles inside the provided directory.
    private func discoverApplications(in searchDirectory: URL, isCoreServicesDirectory: Bool = false) -> [AppItem] {
        guard let enumerator = fileSystem.enumerator(
            at: searchDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            LaunchyLogger.error("AppDiscovery: failed to enumerate \(searchDirectory.path)")
            return []
        }

        var missingIdentifierCount = 0
        let discoveredApps = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "app" }
            .compactMap { bundleURL in
                buildAppItem(
                    from: bundleURL,
                    isCoreService: isCoreServicesDirectory,
                    onMissingIdentifier: { _ in missingIdentifierCount += 1 }
                )
            }

        let directoryName = searchDirectory.lastPathComponent
        if missingIdentifierCount > 0 {
            LaunchyLogger.log("AppDiscovery: found \(discoveredApps.count) app bundles in \(directoryName) (missingIDs=\(missingIdentifierCount))")
        } else {
            LaunchyLogger.log("AppDiscovery: found \(discoveredApps.count) app bundles in \(directoryName)")
        }
        return discoveredApps
    }

    /// Ensures the cached icon never exceeds the largest size we actually display.
    private func scaledIconIfNeeded(_ icon: NSImage) -> NSImage {
        let maxSide = max(icon.size.width, icon.size.height)
        guard maxSide > Self.maximumIconDimension else {
            return icon
        }

        let scale = Self.maximumIconDimension / maxSide
        let targetSize = NSSize(
            width: icon.size.width * scale,
            height: icon.size.height * scale
        )

        return renderIcon(icon, targetSize: targetSize, quality: .high)
    }

    private func cacheIcon(_ icon: NSImage, for bundleIdentifier: String) {
        let cost = imageCost(icon)
        iconCache.setObject(icon, forKey: bundleIdentifier as NSString, cost: cost)
        metadataLock.lock()
        iconCacheKeys.insert(bundleIdentifier)
        metadataLock.unlock()
    }

    private func cachePreparedIcon(_ icon: NSImage, forKey key: String, bundleIdentifier: String) {
        let cost = imageCost(icon)
        preparedIconCache.setObject(icon, forKey: key as NSString, cost: cost)
        metadataLock.lock()
        preparedIconKeysByBundleID[bundleIdentifier, default: []].insert(key)
        metadataLock.unlock()
    }

    /// Sets cache limits tuned for icon sizes Launchy requests.
    private func configureIconCacheLimits() {
        applyCacheLimitScaling(Self.iconResolutionScale)
    }

    /// Dynamically scales the cache limits without fully clearing caches.
    func applyCacheLimitScaling(_ scale: Double) {
        let clamped = max(0.25, min(scale, 1.0))
        let preparedScale = max(0.35, min(scale, 1.0))
        iconCache.countLimit = Int(Double(Self.iconCacheCountLimit) * clamped)
        iconCache.totalCostLimit = Int(Double(Self.iconCacheCostLimit) * clamped)
        preparedIconCache.countLimit = Int(Double(Self.preparedIconCacheCountLimit) * preparedScale)
        preparedIconCache.totalCostLimit = Int(Double(Self.preparedIconCacheCostLimit) * preparedScale)
    }

    private func clearPreparedIconCaches() {
        preparedIconCache.removeAllObjects()
        metadataLock.lock()
        preparedIconKeysByBundleID.removeAll()
        metadataLock.unlock()
    }

    private func recordIconAccess() {
        metadataLock.lock()
        lastIconAccessDate = Date()
        metadataLock.unlock()
        scheduleIdleCacheRelease()
    }

    private func scheduleIdleCacheRelease() {
        let preparedDelay = UInt64(Self.preparedIconCacheIdleReleaseInterval * 1_000_000_000)
        let iconDelay = UInt64(Self.iconCacheIdleReleaseInterval * 1_000_000_000)

        let preparedTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: preparedDelay)
            } catch {
                return
            }
            self.clearPreparedIconCaches()
            self.cacheReleaseQueue.sync {
                self.preparedCacheReleaseTask = nil
            }
        }
        let iconTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: iconDelay)
            } catch {
                return
            }
            self.clearIconCache(cancelIdleRelease: false)
            self.cacheReleaseQueue.sync {
                self.iconCacheReleaseTask = nil
            }
        }

        cacheReleaseQueue.sync {
            preparedCacheReleaseTask?.cancel()
            iconCacheReleaseTask?.cancel()
            preparedCacheReleaseTask = preparedTask
            iconCacheReleaseTask = iconTask
        }
    }

    private func cancelIdleCacheRelease() {
        cacheReleaseQueue.sync {
            preparedCacheReleaseTask?.cancel()
            iconCacheReleaseTask?.cancel()
            preparedCacheReleaseTask = nil
            iconCacheReleaseTask = nil
        }
    }

    /// Resolves the pixel size for a requested icon based on target dimension, scale, and quality.
    private func pixelDimension(
        for targetDimension: CGFloat,
        quality: IconRenderQuality,
        screenScale: CGFloat
    ) -> Int {
        let scaledTarget = max(targetDimension, 1) * max(screenScale, 1) * Self.iconResolutionScale
        let scaled = Int(ceil(scaledTarget))
        return min(max(scaled, 1), Self.scaledPixelCap(for: quality))
    }

    private static func scaledPixelCap(for quality: IconRenderQuality) -> Int {
        let scaledCap = Int((Double(quality.pixelCap) * Double(iconResolutionScale)).rounded(.toNearestOrAwayFromZero))
        return max(scaledCap, 1)
    }

    /// Returns the current generation counter for a bundle so prepared icons can be invalidated.
    private func iconGeneration(for bundleIdentifier: String) -> Int {
        metadataLock.lock()
        let generation = iconGenerations[bundleIdentifier] ?? 0
        metadataLock.unlock()
        return generation
    }

    private func invalidateIfBundleUpdated(_ app: AppItem, force: Bool = false) {
        guard let bundleURL = app.bundleURL else { return }
        let bundleID = app.bundleIdentifier
        guard shouldValidateBundle(bundleID: bundleID, force: force) else { return }
        let modificationDate = bundleModificationDate(bundleURL)
        metadataLock.lock()
        lastIconValidationDates[bundleID] = Date()
        let previous = iconModificationDates[bundleID]
        if let modificationDate {
            iconModificationDates[bundleID] = modificationDate
        } else {
            iconModificationDates.removeValue(forKey: bundleID)
        }
        let changed = previous != modificationDate
        if changed {
            iconGenerations[bundleID, default: 0] += 1
            removeCachedIconsLocked(for: bundleID)
        }
        metadataLock.unlock()
    }

    private func shouldValidateBundle(bundleID: String, force: Bool) -> Bool {
        guard force == false else { return true }
        let now = Date()
        metadataLock.lock()
        defer { metadataLock.unlock() }
        if let lastCheck = lastIconValidationDates[bundleID],
           now.timeIntervalSince(lastCheck) < Self.iconValidationInterval {
            return false
        }
        return true
    }

    /// Removes cache entries for bundles no longer present in the current scan.
    private func evictMissingBundleCaches(keeping bundleIDs: Set<String>) {
        metadataLock.lock()
        let tracked = Set(iconModificationDates.keys)
            .union(preparedIconKeysByBundleID.keys)
            .union(iconCacheKeys)
        let stale = tracked.subtracting(bundleIDs)
        for bundleID in stale {
            removeCachedIconsLocked(for: bundleID)
            iconModificationDates.removeValue(forKey: bundleID)
            iconGenerations.removeValue(forKey: bundleID)
            lastIconValidationDates.removeValue(forKey: bundleID)
        }
        metadataLock.unlock()
    }

    /// Clears caches for a specific bundle identifier, thread-safe.
    private func removeCachedIcons(for bundleIdentifier: String) {
        metadataLock.lock()
        removeCachedIconsLocked(for: bundleIdentifier)
        metadataLock.unlock()
    }

    /// Internal helper that removes cached icons and prepared variants for a bundle.
    private func removeCachedIconsLocked(for bundleIdentifier: String) {
        iconCache.removeObject(forKey: bundleIdentifier as NSString)
        iconCacheKeys.remove(bundleIdentifier)
        if let keys = preparedIconKeysByBundleID[bundleIdentifier] {
            for key in keys {
                preparedIconCache.removeObject(forKey: key as NSString)
            }
        }
        preparedIconKeysByBundleID[bundleIdentifier] = nil
    }

    /// Returns the modification date of the app bundle if available.
    private func bundleModificationDate(_ bundleURL: URL) -> Date? {
        guard let values = try? bundleURL.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    /// Directories scanned when discovering applications, optionally including ~/Applications.
    private func defaultApplicationDirectories(includeUserApplicationsFolder: Bool) -> [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]

        let cryptexPaths = [
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "/System/Cryptexes/App/System/Applications"
        ]
        for path in cryptexPaths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if fileSystem.fileExists(atPath: url.path) {
                directories.append(url)
            }
        }

        directories.append(coreServicesDirectory)

        if includeUserApplicationsFolder {
            directories.append(userApplicationsDirectory)
        }

        return uniqueDirectories(from: directories)
    }

    private func uniqueDirectories(from directories: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for directory in directories {
            let standardized = directory.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            unique.append(standardized)
        }
        return unique
    }

    private func preparedIconCacheKey(
        for bundleIdentifier: String,
        dimension: Int,
        quality: IconRenderQuality,
        generation: Int,
        appearanceToken: String
    ) -> String {
        "\(bundleIdentifier)-\(dimension)-\(quality.cacheSuffix)-\(generation)-\(appearanceToken)"
    }

    /// Rough cost estimate used to bound NSCache memory usage for icons.
    private func imageCost(_ image: NSImage) -> Int {
        let size = image.size
        let pixels = Int(size.width * size.height)
        let bytesPerPixel = 4
        return max(pixels * bytesPerPixel, 1)
    }

    private func hasCustomIcon(for bundleURL: URL) -> Bool {
        guard let defaultData = defaultApplicationIconData else { return true }
        let icon = workspaceInterface.icon(forFile: bundleURL.path)
        guard let iconData = normalizedIconData(for: icon) else { return true }
        return iconData != defaultData
    }

    private func resizedIcon(_ icon: NSImage, pixelDimension: Int, quality: IconRenderQuality) -> NSImage {
        guard pixelDimension > 0 else { return icon }
        if let downsampled = downsampledIcon(icon, pixelDimension: pixelDimension) {
            return downsampled
        }
        let targetSize = NSSize(width: pixelDimension, height: pixelDimension)
        return renderIcon(icon, targetSize: targetSize, quality: quality)
    }

    /// Renders an icon bitmap at a precise size with the requested interpolation quality.
    private func renderIcon(_ icon: NSImage, targetSize: NSSize, quality: IconRenderQuality) -> NSImage {
        let rendered = NSImage(size: targetSize)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = quality.imageInterpolation
        let rect = NSRect(origin: .zero, size: targetSize)
        if let rep = icon.bestRepresentation(for: rect, context: nil, hints: nil) {
            rep.draw(in: rect)
        } else {
            icon.draw(in: rect, from: NSRect(origin: .zero, size: icon.size), operation: .copy, fraction: 1)
        }
        rendered.unlockFocus()
        rendered.size = targetSize
        rendered.isTemplate = icon.isTemplate
        return rendered
    }

    /// Uses vImage to generate a pre-sized icon without inflating large bitmaps.
    private func downsampledIcon(_ icon: NSImage, pixelDimension: Int) -> NSImage? {
        guard pixelDimension > 0 else { return nil }
        let targetSize = NSSize(width: pixelDimension, height: pixelDimension)
        guard let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        // When the source is already close to the target size, defer to the standard renderer to avoid blur.
        if cgImage.width <= pixelDimension * 2 && cgImage.height <= pixelDimension * 2 {
            return nil
        }

        var format = vImage_CGImageFormat(cgImage: cgImage)
            ?? vImage_CGImageFormat(
                bitsPerComponent: UInt32(cgImage.bitsPerComponent),
                bitsPerPixel: UInt32(cgImage.bitsPerPixel),
                colorSpace: Unmanaged.passUnretained(cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()),
                bitmapInfo: cgImage.bitmapInfo,
                version: 0,
                decode: nil,
                renderingIntent: cgImage.renderingIntent
            )

        var sourceBuffer = vImage_Buffer()
        defer { free(sourceBuffer.data) }

        let initError = vImageBuffer_InitWithCGImage(
            &sourceBuffer,
            &format,
            nil,
            cgImage,
            vImage_Flags(kvImageNoFlags)
        )
        guard initError == kvImageNoError else { return nil }

        var destinationBuffer = vImage_Buffer()
        destinationBuffer.width = vImagePixelCount(pixelDimension)
        destinationBuffer.height = vImagePixelCount(pixelDimension)
        destinationBuffer.rowBytes = pixelDimension * 4
        destinationBuffer.data = malloc(Int(destinationBuffer.rowBytes) * Int(destinationBuffer.height))
        guard destinationBuffer.data != nil else { return nil }
        var shouldFreeDestination = true
        defer {
            if shouldFreeDestination {
                free(destinationBuffer.data)
            }
        }

        let scaleError = vImageScale_ARGB8888(
            &sourceBuffer,
            &destinationBuffer,
            /* tempBuffer: */ nil,
            vImage_Flags(kvImageHighQualityResampling)
        )
        guard scaleError == kvImageNoError else { return nil }

        guard let scaledImage = vImageCreateCGImageFromBuffer(
            &destinationBuffer,
            &format,
            nil,
            nil,
            vImage_Flags(kvImageNoFlags),
            nil
        )?.takeRetainedValue() else {
            return nil
        }
        shouldFreeDestination = false

        let downsampled = NSImage(cgImage: scaledImage, size: targetSize)
        downsampled.isTemplate = icon.isTemplate
        return downsampled
    }

    private func normalizedIconData(for icon: NSImage) -> Data? {
        let target = renderIcon(icon, targetSize: NSSize(width: 128, height: 128), quality: .high)
        return target.tiffRepresentation
    }

    /// Restores apps from the last cache when they disappear briefly (e.g., external drives).
    private func restoredAppsFromCache(
        existingApps: [String: AppItem],
        referenceDate: Date,
        includeUserApplicationsFolder: Bool
    ) -> [AppItem] {
        guard cachedAppsByBundleID.isEmpty == false else { return [] }
        let installed = Set(existingApps.keys)
        var restored: [AppItem] = []
        for record in cachedAppsByBundleID.values {
            guard installed.contains(record.bundleIdentifier) == false else { continue }
            if includeUserApplicationsFolder == false, record.isUserApplication {
                continue
            }
            guard shouldRestore(record: record, now: referenceDate) else { continue }
            if let rebuilt = rebuildApp(from: record) {
                restored.append(rebuilt)
            } else {
                restored.append(appItem(from: record))
            }
        }
        return restored
    }

    private func shouldRestore(record: CachedAppRecord, now: Date) -> Bool {
        let age = now.timeIntervalSince(record.lastSeen)
        if age <= Self.missingAppRetentionInterval {
            return true
        }
        return fileSystem.fileExists(atPath: record.bundlePath)
    }

    /// Updates and persists the on-disk cache with the latest discovered apps.
    private func updateCachedApps(with apps: [String: AppItem], seenAt: Date) {
        var updated: [String: CachedAppRecord] = [:]
        for app in apps.values {
            guard let record = cachedRecord(from: app, seenAt: seenAt) else { continue }
            updated[app.bundleIdentifier] = record
        }
        cachedAppsByBundleID = updated
        persistCachedApps()
    }

    private func cachedRecord(from app: AppItem, seenAt: Date) -> CachedAppRecord? {
        guard let bundleURL = app.bundleURL else { return nil }
        return CachedAppRecord(
            id: app.id,
            displayName: app.displayName,
            localizedDisplayName: app.localizedDisplayName,
            bundleIdentifier: app.bundleIdentifier,
            bundlePath: bundleURL.path,
            isUserApplication: app.isUserApplication,
            isCoreServiceApplication: app.isCoreServiceApplication,
            hasCustomIcon: app.hasCustomIcon,
            lastSeen: seenAt
        )
    }

    private func appItem(from record: CachedAppRecord) -> AppItem {
        AppItem(
            id: record.id,
            displayName: record.displayName,
            localizedDisplayName: record.localizedDisplayName,
            customName: nil,
            bundleIdentifier: record.bundleIdentifier,
            iconImage: nil,
            bundleURL: URL(fileURLWithPath: record.bundlePath, isDirectory: true),
            isUserApplication: record.isUserApplication,
            isCoreServiceApplication: record.isCoreServiceApplication,
            hasCustomIcon: record.hasCustomIcon
        )
    }

    private func rebuildApp(from record: CachedAppRecord) -> AppItem? {
        let bundleURL = URL(fileURLWithPath: record.bundlePath, isDirectory: true)
        guard fileSystem.fileExists(atPath: bundleURL.path) else { return nil }
        guard let rebuilt = buildAppItem(from: bundleURL, isCoreService: record.isCoreServiceApplication) else {
            return nil
        }
        return AppItem(
            id: record.id,
            displayName: rebuilt.displayName,
            localizedDisplayName: rebuilt.localizedDisplayName,
            customName: rebuilt.customName,
            bundleIdentifier: rebuilt.bundleIdentifier,
            iconImage: rebuilt.iconImage,
            bundleURL: rebuilt.bundleURL,
            isUserApplication: rebuilt.isUserApplication,
            isCoreServiceApplication: rebuilt.isCoreServiceApplication,
            hasCustomIcon: rebuilt.hasCustomIcon
        )
    }

    /// Persists the cached app map asynchronously to disk.
    private func persistCachedApps() {
        let records = cachedAppsByBundleID
        appCachePersistenceQueue.async { [records, appCacheURL] in
            guard let data = try? JSONEncoder().encode(records) else { return }
            try? data.write(to: appCacheURL, options: .atomic)
        }
    }

    private static func loadCachedApps(from url: URL) -> [String: CachedAppRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let records = try? JSONDecoder().decode([String: CachedAppRecord].self, from: data) else {
            return [:]
        }
        return records
    }

    private static func applicationSupportDirectory(fileManager: FileManager) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appDirectory = baseDirectory.appendingPathComponent("Launchy", isDirectory: true)
        if fileManager.fileExists(atPath: appDirectory.path) == false {
            try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }
        return appDirectory
    }

    /// Converts a bundle on disk into an `AppItem`, extracting the display name and identifier.
    private func buildAppItem(
        from bundleURL: URL,
        isCoreService: Bool,
        onMissingIdentifier: ((URL) -> Void)? = nil
    ) -> AppItem? {
        guard let bundle = Bundle(url: bundleURL) else {
            LaunchyLogger.error("AppDiscovery: malformed bundle at \(bundleURL.path)")
            return nil
        }
        let bundleIdentifier = bundle.bundleIdentifier ?? bundleURL.path
        if bundle.bundleIdentifier == nil {
            onMissingIdentifier?(bundleURL)
        }

        let infoDictionary = bundle.infoDictionary ?? [:]
        let displayName = (infoDictionary["CFBundleDisplayName"] as? String)
            ?? (infoDictionary["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let localizedName = localizedDisplayName(for: bundle, bundleURL: bundleURL, fallback: displayName)
        let stableID = cachedAppsByBundleID[bundleIdentifier]?.id ?? UUID()

        return AppItem(
            id: stableID,
            displayName: displayName,
            localizedDisplayName: localizedName,
            customName: nil,
            bundleIdentifier: bundleIdentifier,
            iconImage: nil,
            bundleURL: bundleURL,
            isUserApplication: isUserApplication(bundleURL),
            isCoreServiceApplication: isCoreService,
            hasCustomIcon: hasCustomIcon(for: bundleURL)
        )
    }

    private func localizedDisplayName(for bundle: Bundle, bundleURL: URL, fallback: String) -> String? {
        let preferredCodes = preferredLocalizationCodes(for: bundle)
        if let infoPlistName = localizedNameFromInfoPlist(
            bundle: bundle,
            fallback: fallback,
            preferredLocalizationCodes: preferredCodes
        ) {
            return infoPlistName
        }

        if let loctableName = localizedNameFromLoctable(
            bundleURL: bundleURL,
            fallback: fallback,
            preferredLocalizationCodes: preferredCodes
        ) {
            return loctableName
        }

        if let values = try? bundleURL.resourceValues(forKeys: [.localizedNameKey]),
           let localizedName = values.localizedName,
           let resolved = sanitizedLocalizedName(localizedName, fallback: fallback) {
            return resolved
        }

        let finderName = fileSystem.displayName(atPath: bundleURL.path)
        return sanitizedLocalizedName(finderName, fallback: fallback)
    }

    private func sanitizedLocalizedName(_ raw: String?, fallback: String) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let withoutAppSuffix: String
        if trimmed.lowercased().hasSuffix(".app") {
            withoutAppSuffix = String(trimmed.dropLast(4))
        } else {
            withoutAppSuffix = trimmed
        }

        if withoutAppSuffix.compare(fallback, options: .caseInsensitive) == .orderedSame {
            return nil
        }

        return withoutAppSuffix
    }

    private func localizedNameFromInfoPlist(
        bundle: Bundle,
        fallback: String,
        preferredLocalizationCodes: [String]
    ) -> String? {
        if let localizedInfo = bundle.localizedInfoDictionary {
            if let name = localizedInfo["CFBundleDisplayName"] as? String,
               let resolved = sanitizedLocalizedName(name, fallback: fallback) {
                return resolved
            }

            if let name = localizedInfo["CFBundleName"] as? String,
               let resolved = sanitizedLocalizedName(name, fallback: fallback) {
                return resolved
            }
        }

        for language in preferredLocalizationCodes {
            guard let stringsURL = bundle.url(
                forResource: "InfoPlist",
                withExtension: "strings",
                subdirectory: nil,
                localization: language
            ) else {
                continue
            }

            guard let strings = NSDictionary(contentsOf: stringsURL) as? [String: Any] else { continue }

            if let name = strings["CFBundleDisplayName"] as? String,
               let resolved = sanitizedLocalizedName(name, fallback: fallback) {
                return resolved
            }

            if let name = strings["CFBundleName"] as? String,
               let resolved = sanitizedLocalizedName(name, fallback: fallback) {
                return resolved
            }
        }

        return nil
    }

    private func localizedNameFromLoctable(
        bundleURL: URL,
        fallback: String,
        preferredLocalizationCodes: [String]
    ) -> String? {
        let loctableURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("InfoPlist.loctable", isDirectory: false)

        guard fileSystem.fileExists(atPath: loctableURL.path) else { return nil }

        guard
            let data = try? Data(contentsOf: loctableURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return nil
        }

        for language in preferredLocalizationCodes {
            guard let entry = dictionary[language] as? [String: Any] else { continue }
            if let name = entry["CFBundleDisplayName"] as? String,
               let resolved = sanitizedLocalizedName(name, fallback: fallback) {
                return resolved
            }

            if let name = entry["CFBundleName"] as? String,
               let resolved = sanitizedLocalizedName(name, fallback: fallback) {
                return resolved
            }
        }

        return nil
    }

    private func isUserApplication(_ bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let folderPath = userApplicationsDirectory.path
        guard bundleURL.path.hasPrefix(folderPath) else { return false }
        return bundleURL.path == folderPath
            ? false
            : bundleURL.path.dropFirst(folderPath.count).hasPrefix("/")
    }

    private func preferredLocalizationCodes(for bundle: Bundle) -> [String] {
        var ordered: [String] = []
        if let primary = bundle.preferredLocalizations.first {
            ordered.append(primary)
        } else if let development = bundle.developmentLocalization {
            ordered.append(development)
        }
        ordered.append("Base")

        return ordered.reduce(into: [String]()) { unique, code in
            if unique.contains(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) == false {
                unique.append(code)
            }
        }
    }

    private func currentAppearanceCacheToken() -> String {
        metadataLock.lock()
        let token = appearanceCacheToken
        metadataLock.unlock()
        return token
    }

    private static func appearanceToken(for appearance: NSAppearance?) -> String {
        if let match = appearance?.bestMatch(from: [.darkAqua, .aqua]) {
            return match.rawValue
        }
        if let name = appearance?.name.rawValue {
            return name
        }
        return "unspecified"
    }
}

private struct CachedAppRecord: Codable {
    var id: UUID
    var displayName: String
    var localizedDisplayName: String?
    var bundleIdentifier: String
    var bundlePath: String
    var isUserApplication: Bool
    var isCoreServiceApplication: Bool
    var hasCustomIcon: Bool
    var lastSeen: Date
}

extension AppDiscoveryService: @unchecked Sendable {}
