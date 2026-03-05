import Foundation

/// File format used to export and restore Launchy settings and grid layout.
struct LauncherBackupPayload: Codable {
    static let currentVersion = 1

    let version: Int
    let createdAt: Date
    let settings: LauncherSettings
    let arrangement: Arrangement

    /// Linearized launcher grid captured during export.
    struct Arrangement: Codable {
        let items: [Item]
        let pageSizes: [Int]
    }

    /// Individual item (app or folder) persisted in a backup file.
    struct Item: Codable {
        enum Kind: String, Codable {
            case app
            case folder
        }

        let kind: Kind
        let bundleID: String?
        let customName: String?
        let folderID: UUID?
        let folderName: String?
        let appBundleIDs: [String]?
        let appCustomNames: [String: String]?
    }
}

/// Shared helpers to keep imported page sizes compact and gap-free.
enum LauncherBackupLayoutResolver {
    /// Returns page sizes that avoid half-empty trailing pages.
    static func resolvedPageSizes(
        preferredSizes: [Int],
        itemCount: Int,
        pageCapacity: Int,
        fillsGapsAutomatically: Bool
    ) -> [Int] {
        guard itemCount > 0, pageCapacity > 0 else { return [] }
        if fillsGapsAutomatically {
            return densePageSizes(for: itemCount, pageCapacity: pageCapacity)
        }

        let normalized = normalize(preferredSizes, itemCount: itemCount, pageCapacity: pageCapacity)
        return normalized.isEmpty ? densePageSizes(for: itemCount, pageCapacity: pageCapacity) : normalized
    }

    /// Produces fully packed page sizes without intentional gaps.
    private static func densePageSizes(for itemCount: Int, pageCapacity: Int) -> [Int] {
        var remaining = itemCount
        var sizes: [Int] = []
        while remaining > 0 {
            let count = min(pageCapacity, remaining)
            sizes.append(count)
            remaining -= count
        }
        return sizes
    }

    /// Normalizes imported page sizes so totals match item count and each page respects capacity.
    private static func normalize(_ sizes: [Int], itemCount: Int, pageCapacity: Int) -> [Int] {
        var normalized = sizes.compactMap { value -> Int? in
            let bounded = min(max(value, 0), pageCapacity)
            return bounded > 0 ? bounded : nil
        }

        if normalized.isEmpty {
            normalized.append(min(itemCount, pageCapacity))
        }

        var total = normalized.reduce(0, +)
        if total < itemCount {
            var remaining = itemCount - total
            for index in stride(from: normalized.count - 1, through: 0, by: -1) where remaining > 0 {
                let headroom = max(pageCapacity - normalized[index], 0)
                guard headroom > 0 else { continue }
                let added = min(headroom, remaining)
                normalized[index] += added
                remaining -= added
                total += added
            }

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
