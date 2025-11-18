import AppKit

/// Discoverer that scans common application folders and prepares `AppItem` models.
final class AppDiscoveryService {
    private let fileSystem: FileManager
    private let workspaceInterface: NSWorkspace
    private let applicationSearchDirectories: [URL]
    private var iconCacheByBundleID: [String: NSImage] = [:]

    /// Configures the service with dependencies mainly to aid testing.
    init(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        applicationDirectories: [URL]? = nil
    ) {
        self.fileSystem = fileManager
        self.workspaceInterface = workspace
        if let applicationDirectories {
            self.applicationSearchDirectories = applicationDirectories
        } else {
            self.applicationSearchDirectories = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                fileSystem.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            ]
        }
    }

    /// Rebuilds the cached list of installed apps, optionally excluding hidden bundle identifiers.
    func reloadApps(hiddenBundleIDs: Set<String> = []) -> [AppItem] {
        var appsByBundleID: [String: AppItem] = [:]

        for directory in applicationSearchDirectories {
            for app in discoverApplications(in: directory) {
                appsByBundleID[app.bundleIdentifier] = app
            }
        }

        let sortedApps = appsByBundleID.values
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        guard hiddenBundleIDs.isEmpty == false else { return sortedApps }
        return sortedApps.filter { hiddenBundleIDs.contains($0.bundleIdentifier) == false }
    }

    /// Returns the lazily-loaded icon for an app, caching results by bundle identifier.
    func resolveIcon(for app: AppItem) -> NSImage? {
        if let cached = iconCacheByBundleID[app.bundleIdentifier] {
            return cached
        }

        guard let appURL = app.bundleURL else { return nil }
        let icon = workspaceInterface.icon(forFile: appURL.path)
        iconCacheByBundleID[app.bundleIdentifier] = icon
        return icon
    }

    /// Produces a copy of the provided item with the icon field populated.
    func loadIcon(for app: AppItem) -> AppItem {
        guard app.iconImage == nil else { return app }
        return AppItem(
            id: app.id,
            displayName: app.displayName,
            bundleIdentifier: app.bundleIdentifier,
            iconImage: resolveIcon(for: app),
            bundleURL: app.bundleURL
        )
    }

    /// Clears the cached icons, forcing the next `resolveIcon(for:)` call to reload from disk.
    func clearIconCache() {
        iconCacheByBundleID.removeAll()
    }

    /// Lists `.app` bundles inside the provided directory.
    private func discoverApplications(in searchDirectory: URL) -> [AppItem] {
        guard let directoryContents = try? fileSystem.contentsOfDirectory(
            at: searchDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directoryContents
            .filter { $0.pathExtension == "app" }
            .compactMap(buildAppItem)
    }

    /// Converts a bundle on disk into an `AppItem`, extracting the display name and identifier.
    private func buildAppItem(from bundleURL: URL) -> AppItem? {
        guard
            let bundle = Bundle(url: bundleURL),
            let bundleIdentifier = bundle.bundleIdentifier
        else {
            return nil
        }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent

        return AppItem(
            id: UUID(),
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            iconImage: nil,
            bundleURL: bundleURL
        )
    }
}

extension AppDiscoveryService: @unchecked Sendable {}
