import AppKit

enum IconRenderQuality: String {
    case low
    case medium
    case high

    var cacheSuffix: String {
        switch self {
        case .low: return "l"
        case .medium: return "m"
        case .high: return "h"
        }
    }

    var pixelCap: Int {
        switch self {
        case .low: return 80
        case .medium: return 160
        case .high: return 200
        }
    }

    var imageInterpolation: NSImageInterpolation {
        switch self {
        case .low:
            return .low
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
    private let preferredLanguageCodes: [String]
    private let iconCache = NSCache<NSString, NSImage>()
    private let preparedIconCache = NSCache<NSString, NSImage>()
    private let metadataLock = NSLock()
    private var iconModificationDates: [String: Date] = [:]
    private var iconGenerations: [String: Int] = [:]
    private var preparedIconKeysByBundleID: [String: Set<String>] = [:]
    private let iconPreparationQueue = DispatchQueue(label: "com.launchy.icon-prep", qos: .userInitiated)
    private static let maximumIconDimension: CGFloat = 256
    private static let iconCacheCountLimit = 200
    private static let preparedIconCacheCountLimit = 260
    private static let iconCacheCostLimit = 12_000_000
    private static let preparedIconCacheCostLimit = 16_000_000

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

        preferredLanguageCodes = Self.buildPreferredLanguageCodes()
        configureIconCacheLimits()
    }

    /// Rebuilds the cached list of installed apps, optionally excluding hidden bundle identifiers.
    func reloadApps(
        includeUserApplicationsFolder: Bool = true,
        hiddenBundleIDs: Set<String> = []
    ) -> (main: [AppItem], userApplications: [AppItem]) {
        var appsByBundleID: [String: AppItem] = [:]

        LaunchyLogger.log("AppDiscovery: reload apps (includeUserApplicationsFolder=\(includeUserApplicationsFolder), hiddenCount=\(hiddenBundleIDs.count))")

        let directories = customApplicationDirectories
            ?? defaultApplicationDirectories(includeUserApplicationsFolder: includeUserApplicationsFolder)

        for directory in directories {
            LaunchyLogger.log("AppDiscovery: scanning directory \(directory.path)")
            for app in discoverApplications(in: directory) {
                appsByBundleID[app.bundleIdentifier] = app
            }
        }

        let sortedApps = appsByBundleID.values
            .sorted { $0.sortingName.localizedCaseInsensitiveCompare($1.sortingName) == .orderedAscending }

        let visibleApps = sortedApps.filter { hiddenBundleIDs.contains($0.bundleIdentifier) == false }
        let userApplications = visibleApps.filter { $0.isUserApplication }
        let mainApplications = visibleApps.filter { $0.isUserApplication == false }
        let userAppsToReturn = includeUserApplicationsFolder ? userApplications : []
        synchronizeIconMetadata(for: visibleApps)
        return (main: mainApplications, userApplications: userAppsToReturn)
    }

    /// Keeps cache metadata in sync with the current set of apps and evicts stale entries.
    func synchronizeIconMetadata(for apps: [AppItem]) {
        let bundleIDs = Set(apps.map(\.bundleIdentifier))
        evictMissingBundleCaches(keeping: bundleIDs)
        for app in apps {
            invalidateIfBundleUpdated(app)
        }
    }

    /// Returns the lazily-loaded icon for an app, caching results by bundle identifier.
    func resolveIcon(for app: AppItem) -> NSImage? {
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
    func clearIconCache() {
        iconCache.removeAllObjects()
        preparedIconCache.removeAllObjects()
        metadataLock.lock()
        iconModificationDates.removeAll()
        iconGenerations.removeAll()
        preparedIconKeysByBundleID.removeAll()
        metadataLock.unlock()
    }

    /// Drops prepared and base icon bitmaps to minimize memory while the launcher is hidden.
    func shrinkCachesForHiddenLauncher() {
        preparedIconCache.removeAllObjects()
        iconCache.removeAllObjects()
    }

    /// Returns an icon scaled to the exact dimension the grid needs, keeping memory usage bounded.
    func preparedIcon(
        for app: AppItem,
        targetDimension: CGFloat,
        quality: IconRenderQuality = .medium,
        screenScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    ) -> NSImage? {
        invalidateIfBundleUpdated(app)
        let pixelDimension = pixelDimension(for: targetDimension, quality: quality, screenScale: screenScale)
        let generation = iconGeneration(for: app.bundleIdentifier)
        let cacheKey = preparedIconCacheKey(
            for: app.bundleIdentifier,
            dimension: pixelDimension,
            quality: quality,
            generation: generation
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
    private func discoverApplications(in searchDirectory: URL) -> [AppItem] {
        guard let enumerator = fileSystem.enumerator(
            at: searchDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            LaunchyLogger.error("AppDiscovery: failed to enumerate \(searchDirectory.path)")
            return []
        }

        let discoveredApps = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "app" }
            .compactMap(buildAppItem)

        LaunchyLogger.log("AppDiscovery: found \(discoveredApps.count) app bundles in \(searchDirectory.lastPathComponent)")
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
    }

    private func cachePreparedIcon(_ icon: NSImage, forKey key: String, bundleIdentifier: String) {
        let cost = imageCost(icon)
        preparedIconCache.setObject(icon, forKey: key as NSString, cost: cost)
        metadataLock.lock()
        preparedIconKeysByBundleID[bundleIdentifier, default: []].insert(key)
        metadataLock.unlock()
    }

    private func configureIconCacheLimits() {
        iconCache.countLimit = Self.iconCacheCountLimit
        iconCache.totalCostLimit = Self.iconCacheCostLimit
        preparedIconCache.countLimit = Self.preparedIconCacheCountLimit
        preparedIconCache.totalCostLimit = Self.preparedIconCacheCostLimit
    }

    private func pixelDimension(
        for targetDimension: CGFloat,
        quality: IconRenderQuality,
        screenScale: CGFloat
    ) -> Int {
        let scaled = Int(ceil(max(targetDimension, 1) * max(screenScale, 1)))
        return min(max(scaled, 1), quality.pixelCap)
    }

    private func iconGeneration(for bundleIdentifier: String) -> Int {
        metadataLock.lock()
        let generation = iconGenerations[bundleIdentifier] ?? 0
        metadataLock.unlock()
        return generation
    }

    private func invalidateIfBundleUpdated(_ app: AppItem) {
        guard let bundleURL = app.bundleURL else { return }
        let bundleID = app.bundleIdentifier
        let modificationDate = bundleModificationDate(bundleURL)
        metadataLock.lock()
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

    private func evictMissingBundleCaches(keeping bundleIDs: Set<String>) {
        metadataLock.lock()
        let tracked = Set(iconModificationDates.keys).union(preparedIconKeysByBundleID.keys)
        let stale = tracked.subtracting(bundleIDs)
        for bundleID in stale {
            removeCachedIconsLocked(for: bundleID)
            iconModificationDates.removeValue(forKey: bundleID)
            iconGenerations.removeValue(forKey: bundleID)
        }
        metadataLock.unlock()
    }

    private func removeCachedIcons(for bundleIdentifier: String) {
        metadataLock.lock()
        removeCachedIconsLocked(for: bundleIdentifier)
        metadataLock.unlock()
    }

    private func removeCachedIconsLocked(for bundleIdentifier: String) {
        iconCache.removeObject(forKey: bundleIdentifier as NSString)
        if let keys = preparedIconKeysByBundleID[bundleIdentifier] {
            for key in keys {
                preparedIconCache.removeObject(forKey: key as NSString)
            }
        }
        preparedIconKeysByBundleID[bundleIdentifier] = nil
    }

    private func bundleModificationDate(_ bundleURL: URL) -> Date? {
        guard let values = try? bundleURL.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private func defaultApplicationDirectories(includeUserApplicationsFolder: Bool) -> [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]

        if includeUserApplicationsFolder {
            directories.append(userApplicationsDirectory)
        }

        return directories
    }

    private func preparedIconCacheKey(
        for bundleIdentifier: String,
        dimension: Int,
        quality: IconRenderQuality,
        generation: Int
    ) -> String {
        "\(bundleIdentifier)-\(dimension)-\(quality.cacheSuffix)-\(generation)"
    }

    private func imageCost(_ image: NSImage) -> Int {
        let size = image.size
        let pixels = Int(size.width * size.height)
        let bytesPerPixel = 4
        return max(pixels * bytesPerPixel, 1)
    }

    private func resizedIcon(_ icon: NSImage, pixelDimension: Int, quality: IconRenderQuality) -> NSImage {
        guard pixelDimension > 0 else { return icon }
        let targetSize = NSSize(width: pixelDimension, height: pixelDimension)
        return renderIcon(icon, targetSize: targetSize, quality: quality)
    }

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

    /// Converts a bundle on disk into an `AppItem`, extracting the display name and identifier.
    private func buildAppItem(from bundleURL: URL) -> AppItem? {
        guard let bundle = Bundle(url: bundleURL) else {
            LaunchyLogger.error("AppDiscovery: malformed bundle at \(bundleURL.path)")
            return nil
        }
        let bundleIdentifier = bundle.bundleIdentifier ?? bundleURL.path
        if bundle.bundleIdentifier == nil {
            LaunchyLogger.log("AppDiscovery: bundle at \(bundleURL.lastPathComponent) missing identifier, using path fallback")
        }

        let infoDictionary = bundle.infoDictionary ?? [:]
        let displayName = (infoDictionary["CFBundleDisplayName"] as? String)
            ?? (infoDictionary["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let localizedName = localizedDisplayName(for: bundle, bundleURL: bundleURL, fallback: displayName)

        return AppItem(
            id: UUID(),
            displayName: displayName,
            localizedDisplayName: localizedName,
            customName: nil,
            bundleIdentifier: bundleIdentifier,
            iconImage: nil,
            bundleURL: bundleURL,
            isUserApplication: isUserApplication(bundleURL)
        )
    }

    private func localizedDisplayName(for bundle: Bundle, bundleURL: URL, fallback: String) -> String? {
        if let infoPlistName = localizedNameFromInfoPlist(bundle: bundle, fallback: fallback) {
            return infoPlistName
        }

        if let loctableName = localizedNameFromLoctable(bundleURL: bundleURL, fallback: fallback) {
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

    private func localizedNameFromInfoPlist(bundle: Bundle, fallback: String) -> String? {
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

        for language in preferredLanguageCodes {
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

    private func localizedNameFromLoctable(bundleURL: URL, fallback: String) -> String? {
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

        for language in preferredLanguageCodes {
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

    private static func buildPreferredLanguageCodes() -> [String] {
        var ordered: [String] = []

        for language in Locale.preferredLanguages {
            let underscored = language.replacingOccurrences(of: "-", with: "_")
            let components = underscored.split(separator: "_")
            if components.isEmpty { continue }

            ordered.append(language)
            ordered.append(underscored)

            if let languageCode = components.first {
                ordered.append(String(languageCode))
            }
        }

        ordered.append("Base")

        return ordered.reduce(into: [String]()) { unique, code in
            if unique.contains(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) == false {
                unique.append(code)
            }
        }
    }
}

extension AppDiscoveryService: @unchecked Sendable {}
