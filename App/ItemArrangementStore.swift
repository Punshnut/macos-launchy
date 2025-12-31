import Foundation

/// Persists and restores the user-defined order of launcher items (apps and folders).
final class ItemArrangementStore {
    private struct Payload: Codable {
        var items: [PersistedItem]
        var pageSizes: [Int]?
    }

    private struct LegacyPayload: Codable {
        var bundleOrder: [String]
    }

    private struct FolderRecord: Codable {
        var id: UUID
        var name: String
        var bundleIDs: [String]
        var appCustomNames: [String: String]?

        init(id: UUID, name: String, bundleIDs: [String], appCustomNames: [String: String]? = nil) {
            self.id = id
            self.name = name
            self.bundleIDs = bundleIDs
            self.appCustomNames = appCustomNames
        }
    }

    private enum PersistedItem: Codable {
        case app(String, customName: String?)
        case folder(FolderRecord)

        private enum CodingKeys: String, CodingKey {
            case type
            case appBundleID
            case folder
            case customName
        }

        private enum ItemType: String, Codable {
            case app
            case folder
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(ItemType.self, forKey: .type)
            switch type {
            case .app:
                let bundleID = try container.decode(String.self, forKey: .appBundleID)
                let customName = try container.decodeIfPresent(String.self, forKey: .customName)
                self = .app(bundleID, customName: customName)
            case .folder:
                let folder = try container.decode(FolderRecord.self, forKey: .folder)
                self = .folder(folder)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .app(let bundleID, let customName):
                try container.encode(ItemType.app, forKey: .type)
                try container.encode(bundleID, forKey: .appBundleID)
                try container.encodeIfPresent(customName, forKey: .customName)
            case .folder(let record):
                try container.encode(ItemType.folder, forKey: .type)
                try container.encode(record, forKey: .folder)
            }
        }
    }

    private let fileManager: FileManager
    private let arrangementURL: URL
    private var cachedItems: [PersistedItem]
    private(set) var cachedPageSizes: [Int]

    /// Loads persisted arrangement data and prepares the Application Support directory.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appDirectory = baseDirectory.appendingPathComponent("Launchy", isDirectory: true)
        arrangementURL = appDirectory.appendingPathComponent("app-arrangement.json")
        cachedItems = []
        cachedPageSizes = []

        bootstrapDirectoryIfNeeded(at: appDirectory)
        let payload = loadPersistedPayload()
        cachedItems = payload.items
        cachedPageSizes = payload.pageSizes ?? []
    }

    /// Returns items sorted using the persisted order while inserting any new discoveries.
    func arrangedItems(
        from discoveredApps: [AppItem],
        pageCapacity: Int,
        fillsGapsAutomatically: Bool,
        preferredCustomNames: [String: String] = [:]
    ) -> ([LauncherItem], [Int]) {
        var lookup: [String: AppItem] = Dictionary(
            uniqueKeysWithValues: discoveredApps.map { ($0.bundleIdentifier, $0) }
        )

        var orderedItems: [LauncherItem] = []
        for entry in cachedItems {
            switch entry {
            case .app(let bundleID, let customName):
                guard var app = lookup.removeValue(forKey: bundleID) else { continue }
                app.customName = preferredCustomNames[bundleID] ?? customName
                orderedItems.append(.app(app))
            case .folder(let folderRecord):
                let resolvedApps = folderRecord.bundleIDs.compactMap { bundleID -> AppItem? in
                    guard var app = lookup.removeValue(forKey: bundleID) else { return nil }
                    if let custom = preferredCustomNames[bundleID] ?? folderRecord.appCustomNames?[bundleID] {
                        app.customName = custom
                    }
                    return app
                }
                guard resolvedApps.isEmpty == false else { continue }
                let folder = FolderItem(id: folderRecord.id, name: folderRecord.name, apps: resolvedApps)
                orderedItems.append(.folder(folder))
            }
        }

        guard lookup.isEmpty == false else {
            cachedItems = orderedItems.map(persistedItem(from:))
            cachedPageSizes = resolvedPageSizes(
                storedSizes: cachedPageSizes,
                itemCount: orderedItems.count,
                pageCapacity: pageCapacity,
                fillsGapsAutomatically: fillsGapsAutomatically
            )
            saveItems()
            return (orderedItems, cachedPageSizes)
        }

        let remainingApps = lookup.values.sorted { lhs, rhs in
            lhs.sortingName.localizedCaseInsensitiveCompare(rhs.sortingName) == .orderedAscending
        }

        var workingPageSizes: [Int] = []
        if fillsGapsAutomatically == false {
            workingPageSizes = normalizePageSizes(
                cachedPageSizes,
                itemCount: orderedItems.count,
                pageCapacity: pageCapacity
            )
            if workingPageSizes.isEmpty, orderedItems.isEmpty == false {
                workingPageSizes = densePageSizes(for: orderedItems.count, pageCapacity: pageCapacity)
            }
        }

        for app in remainingApps {
            var renamed = app
            if let custom = preferredCustomNames[app.bundleIdentifier] {
                renamed.customName = custom
            }
            if fillsGapsAutomatically {
                let insertIndex = lastPageInsertionIndex(
                    currentItems: orderedItems,
                    pageCapacity: pageCapacity
                )
                orderedItems.insert(.app(renamed), at: insertIndex)
            } else {
                let insertIndex = orderedItems.count
                orderedItems.insert(.app(renamed), at: insertIndex)
                appendNewItem(atEndOf: &workingPageSizes, pageCapacity: pageCapacity)
            }
        }

        cachedItems = orderedItems.map(persistedItem(from:))
        if fillsGapsAutomatically {
            cachedPageSizes = densePageSizes(for: orderedItems.count, pageCapacity: pageCapacity)
        } else {
            cachedPageSizes = normalizePageSizes(
                workingPageSizes,
                itemCount: orderedItems.count,
                pageCapacity: pageCapacity
            )
        }
        saveItems()
        return (orderedItems, cachedPageSizes)
    }

    /// Saves a new linear order of items including folders and their contents.
    func saveOrderedItems(_ items: [LauncherItem], pageSizes: [Int]) {
        cachedItems = items.map(persistedItem(from:))
        cachedPageSizes = normalizePageSizes(pageSizes, itemCount: items.count, pageCapacity: LauncherGridConfiguration.pageCapacity)
        saveItems()
    }

    /// Returns the insertion index that keeps new apps on the last page (or creates a new page).
    private func lastPageInsertionIndex(currentItems: [LauncherItem], pageCapacity: Int) -> Int {
        guard pageCapacity > 0 else { return currentItems.count }
        return currentItems.count
    }

    private func persistedItem(from item: LauncherItem) -> PersistedItem {
        switch item {
        case .app(let app):
            return .app(app.bundleIdentifier, customName: app.customName)
        case .folder(let folder):
            let customNames = Dictionary(uniqueKeysWithValues: folder.apps.compactMap { app -> (String, String)? in
                guard let custom = app.customName else { return nil }
                return (app.bundleIdentifier, custom)
            })

            let folderRecord = FolderRecord(
                id: folder.id,
                name: folder.name,
                bundleIDs: folder.apps.map(\.bundleIdentifier),
                appCustomNames: customNames.isEmpty ? nil : customNames
            )
            return .folder(folderRecord)
        }
    }

    private func bootstrapDirectoryIfNeeded(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) == false else { return }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func loadPersistedPayload() -> Payload {
        guard let data = try? Data(contentsOf: arrangementURL) else { return Payload(items: [], pageSizes: nil) }
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return payload
        }

        if let legacy = try? JSONDecoder().decode(LegacyPayload.self, from: data) {
            return Payload(items: legacy.bundleOrder.map { PersistedItem.app($0, customName: nil) }, pageSizes: nil)
        }

        return Payload(items: [], pageSizes: nil)
    }

    private func saveItems() {
        let payload = Payload(items: cachedItems, pageSizes: cachedPageSizes)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: arrangementURL, options: .atomic)
    }

    /// Deletes the persisted arrangement and clears in-memory caches.
    func resetArrangement() {
        try? fileManager.removeItem(at: arrangementURL)
        cachedItems = []
        cachedPageSizes = []
    }

    private func resolvedPageSizes(
        storedSizes: [Int],
        itemCount: Int,
        pageCapacity: Int,
        fillsGapsAutomatically: Bool
    ) -> [Int] {
        guard fillsGapsAutomatically == false else {
            return densePageSizes(for: itemCount, pageCapacity: pageCapacity)
        }

        let normalized = normalizePageSizes(storedSizes, itemCount: itemCount, pageCapacity: pageCapacity)
        return normalized.isEmpty ? densePageSizes(for: itemCount, pageCapacity: pageCapacity) : normalized
    }

    private func densePageSizes(for itemCount: Int, pageCapacity: Int) -> [Int] {
        guard itemCount > 0, pageCapacity > 0 else { return [] }
        var remaining = itemCount
        var sizes: [Int] = []
        while remaining > 0 {
            let count = min(pageCapacity, remaining)
            sizes.append(count)
            remaining -= count
        }
        return sizes
    }

    private func appendNewItem(atEndOf pageSizes: inout [Int], pageCapacity: Int) {
        guard pageCapacity > 0 else {
            if pageSizes.isEmpty {
                pageSizes = [1]
            } else {
                pageSizes[pageSizes.count - 1] += 1
            }
            return
        }

        if pageSizes.isEmpty {
            pageSizes = [1]
        } else if let last = pageSizes.last, last < pageCapacity {
            pageSizes[pageSizes.count - 1] = last + 1
        } else {
            pageSizes.append(1)
        }
    }

    private func normalizePageSizes(_ sizes: [Int], itemCount: Int, pageCapacity: Int) -> [Int] {
        guard itemCount > 0, pageCapacity > 0 else { return [] }

        var normalized = sizes.compactMap { value -> Int? in
            let bounded = min(max(value, 0), pageCapacity)
            return bounded > 0 ? bounded : nil
        }
        if normalized.isEmpty {
            normalized.append(min(itemCount, pageCapacity))
        }

        let total = normalized.reduce(0, +)
        if total < itemCount {
            var remaining = itemCount - total
            while remaining > 0 {
                let portion = min(pageCapacity, remaining)
                normalized.append(portion)
                remaining -= portion
            }
        } else if total > itemCount {
            var surplus = total - itemCount
            for index in stride(from: normalized.count - 1, through: 0, by: -1) where surplus > 0 {
                let reduction = min(normalized[index], surplus)
                normalized[index] -= reduction
                surplus -= reduction
            }

            while let last = normalized.last, last == 0 {
                normalized.removeLast()
            }
        }

        return normalized
    }
}
