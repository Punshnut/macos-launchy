import AppKit

/// Discoverer that scans common application folders and prepares `AppItem` models.
final class AppDiscoveryService {
    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let applicationDirectories: [URL]
    private var iconCache: [String: NSImage] = [:]

    init(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        applicationDirectories: [URL]? = nil
    ) {
        self.fileManager = fileManager
        self.workspace = workspace
        if let applicationDirectories {
            self.applicationDirectories = applicationDirectories
        } else {
            self.applicationDirectories = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            ]
        }
    }

    /// Rebuilds the cached list of installed apps.
    func reloadApps() -> [AppItem] {
        var itemsByBundleId: [String: AppItem] = [:]

        for directory in applicationDirectories {
            for app in discoverApplications(in: directory) {
                itemsByBundleId[app.bundleIdentifier] = app
            }
        }

        return itemsByBundleId.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Returns the lazily-loaded icon for an app, caching results by bundle identifier.
    func icon(for app: AppItem) -> NSImage? {
        if let cached = iconCache[app.bundleIdentifier] {
            return cached
        }

        guard let appURL = app.url else { return nil }
        let icon = workspace.icon(forFile: appURL.path)
        iconCache[app.bundleIdentifier] = icon
        return icon
    }

    /// Produces a copy of the provided item with the icon field populated.
    func loadIcon(for app: AppItem) -> AppItem {
        guard app.icon == nil else { return app }
        return AppItem(
            id: app.id,
            name: app.name,
            bundleIdentifier: app.bundleIdentifier,
            icon: icon(for: app),
            url: app.url
        )
    }

    /// Clears the cached icons, forcing the next `icon(for:)` call to reload from disk.
    func clearIconCache() {
        iconCache.removeAll()
    }

    private func discoverApplications(in directory: URL) -> [AppItem] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "app" }
            .compactMap(makeAppItem)
    }

    private func makeAppItem(from bundleURL: URL) -> AppItem? {
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
            name: displayName,
            bundleIdentifier: bundleIdentifier,
            icon: nil,
            url: bundleURL
        )
    }
}
