import Foundation

/// Persists and restores the user-defined order of launcher items.
final class AppArrangementStore {
    private struct Payload: Codable {
        var bundleOrder: [String]
    }

    private let fileManager: FileManager
    private let arrangementURL: URL
    private var cachedBundleOrder: [String]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appDirectory = baseDirectory.appendingPathComponent("Launchy", isDirectory: true)
        arrangementURL = appDirectory.appendingPathComponent("app-arrangement.json")
        cachedBundleOrder = []

        bootstrapDirectoryIfNeeded(at: appDirectory)
        cachedBundleOrder = loadBundleOrder()
    }

    /// Returns apps sorted using the persisted order while inserting any new discoveries.
    func arrangedApps(from discoveredApps: [AppItem], appsPerPage: Int) -> [AppItem] {
        var lookup: [String: AppItem] = Dictionary(
            uniqueKeysWithValues: discoveredApps.map { ($0.bundleIdentifier, $0) }
        )

        var orderedApps: [AppItem] = []
        for bundleID in cachedBundleOrder {
            guard let app = lookup.removeValue(forKey: bundleID) else { continue }
            orderedApps.append(app)
        }

        guard lookup.isEmpty == false else {
            cachedBundleOrder = orderedApps.map(\.bundleIdentifier)
            saveBundleOrder()
            return orderedApps
        }

        let remainingApps = lookup.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        for app in remainingApps {
            let insertIndex = firstAvailableInsertionIndex(currentCount: orderedApps.count, appsPerPage: appsPerPage)
            orderedApps.insert(app, at: insertIndex)
        }

        cachedBundleOrder = orderedApps.map(\.bundleIdentifier)
        saveBundleOrder()
        return orderedApps
    }

    /// Saves a new linear order of bundle identifiers.
    func saveOrderedApps(_ apps: [AppItem]) {
        cachedBundleOrder = apps.map(\.bundleIdentifier)
        saveBundleOrder()
    }

    private func firstAvailableInsertionIndex(currentCount: Int, appsPerPage: Int) -> Int {
        guard appsPerPage > 0 else { return currentCount }
        if currentCount < appsPerPage {
            return currentCount
        }

        let remainder = currentCount % appsPerPage
        if remainder == 0 {
            return currentCount
        } else {
            return currentCount
        }
    }

    private func bootstrapDirectoryIfNeeded(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) == false else { return }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func loadBundleOrder() -> [String] {
        guard let data = try? Data(contentsOf: arrangementURL) else { return [] }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return payload.bundleOrder
        } catch {
            return []
        }
    }

    private func saveBundleOrder() {
        let payload = Payload(bundleOrder: cachedBundleOrder)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: arrangementURL, options: .atomic)
    }
}
