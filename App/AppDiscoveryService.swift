import AppKit

/// Discoverer that scans common application folders and prepares `AppItem` models.
final class AppDiscoveryService {
    private let fileSystem: FileManager
    private let workspaceInterface: NSWorkspace
    private let customApplicationDirectories: [URL]?
    private let userApplicationsDirectory: URL
    private var iconCacheByBundleID: [String: NSImage] = [:]
    private let preferredLanguageCodes: [String]

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
    }

    /// Rebuilds the cached list of installed apps, optionally excluding hidden bundle identifiers.
    func reloadApps(
        includeUserApplicationsFolder: Bool = true,
        hiddenBundleIDs: Set<String> = []
    ) -> (main: [AppItem], userApplications: [AppItem]) {
        var appsByBundleID: [String: AppItem] = [:]

        let directories = customApplicationDirectories
            ?? defaultApplicationDirectories(includeUserApplicationsFolder: includeUserApplicationsFolder)

        for directory in directories {
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
        return (main: mainApplications, userApplications: userAppsToReturn)
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
            localizedDisplayName: app.localizedDisplayName,
            customName: app.customName,
            bundleIdentifier: app.bundleIdentifier,
            iconImage: resolveIcon(for: app),
            bundleURL: app.bundleURL,
            isUserApplication: app.isUserApplication
        )
    }

    /// Clears the cached icons, forcing the next `resolveIcon(for:)` call to reload from disk.
    func clearIconCache() {
        iconCacheByBundleID.removeAll()
    }

    /// Lists `.app` bundles inside the provided directory.
    private func discoverApplications(in searchDirectory: URL) -> [AppItem] {
        guard let enumerator = fileSystem.enumerator(
            at: searchDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "app" }
            .compactMap(buildAppItem)
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

    /// Converts a bundle on disk into an `AppItem`, extracting the display name and identifier.
    private func buildAppItem(from bundleURL: URL) -> AppItem? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        let bundleIdentifier = bundle.bundleIdentifier ?? bundleURL.path

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
